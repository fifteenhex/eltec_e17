#!/usr/bin/env python3
"""Talk to the EUROCOM-17's serial console over MQTT.

The board's console is bridged by smolmqtt's serial2mqtt:

    serial2mqtt -b 9600 -c 8N1 /dev/ttyUSB1 <broker> m68k/e17/serial

which publishes everything the board says to <topic>/rx and writes anything
published to <topic>/tx out of the serial port.  This script is a dependency-
free MQTT 3.1.1 client (enough of it: CONNECT, SUBSCRIBE, PUBLISH QoS 0,
PINGREQ) wrapped in a few console-shaped commands.

    e17con.py listen [seconds]        dump the console
    e17con.py send "text"             send text, no newline
    e17con.py cmd "db fec20468 20"    send text + CR, print the reply
    e17con.py raw 0d0a                send raw bytes (hex)
    e17con.py expect "e17 =>" [secs]  wait for a string, print what arrives

Options:
    --broker IP     default $E17_BROKER or 192.168.3.2
    --topic BASE    default $E17_TOPIC  or m68k/e17/serial
    --quiet-for S   'cmd' stops when the board has been silent for S seconds
                    (default 1.5)
    --timeout S     hard limit for 'cmd'/'expect' (default 20)

Nothing here writes to the board on its own - you have to ask.  Remember that
some accesses are dangerous (see the README: a read of 0xfec54000 watchdog-
resets the whole VME crate).
"""
import argparse
import os
import socket
import sys
import time

DEFAULT_BROKER = os.environ.get("E17_BROKER", "192.168.3.2")
DEFAULT_TOPIC = os.environ.get("E17_TOPIC", "m68k/e17/serial")


def _rlen(n):
    """MQTT remaining-length encoding."""
    out = b""
    while True:
        b = n % 128
        n //= 128
        out += bytes([b | (0x80 if n else 0)])
        if not n:
            return out


def _str(s):
    b = s.encode() if isinstance(s, str) else s
    return len(b).to_bytes(2, "big") + b


class MQTT:
    def __init__(self, broker, port=1883, client_id=None):
        self.sock = socket.create_connection((broker, port), timeout=10)
        self.buf = b""
        cid = client_id or f"e17con-{os.getpid()}"
        payload = _str(cid)
        var = _str("MQTT") + bytes([4, 0x02]) + (60).to_bytes(2, "big")
        self._send(0x10, var + payload)
        if self._packet(timeout=10)[0] != 0x20:
            raise RuntimeError("no CONNACK")
        self.pid = 0

    def _send(self, byte1, body):
        self.sock.sendall(bytes([byte1]) + _rlen(len(body)) + body)

    def _fill(self, timeout):
        self.sock.settimeout(timeout)
        try:
            d = self.sock.recv(65536)
        except socket.timeout:
            return False
        if not d:
            raise RuntimeError("broker closed the connection")
        self.buf += d
        return True

    def _packet(self, timeout):
        """Return (type_byte, body) or (None, None) on timeout."""
        deadline = time.time() + timeout
        while True:
            # Do we already have a whole packet buffered?
            if len(self.buf) >= 2:
                mult, val, i = 1, 0, 1
                while i < len(self.buf):
                    b = self.buf[i]
                    val += (b & 0x7F) * mult
                    mult *= 128
                    i += 1
                    if not b & 0x80:
                        break
                else:
                    val = None
                if val is not None and len(self.buf) >= i + val:
                    t = self.buf[0]
                    body = self.buf[i:i + val]
                    self.buf = self.buf[i + val:]
                    return t, body
            left = deadline - time.time()
            if left <= 0 or not self._fill(min(left, 1.0)):
                if time.time() >= deadline:
                    return None, None

    def subscribe(self, topic):
        self.pid += 1
        body = self.pid.to_bytes(2, "big") + _str(topic) + b"\x00"
        self._send(0x82, body)
        t, _ = self._packet(timeout=10)
        if t is None or t & 0xF0 != 0x90:
            raise RuntimeError("no SUBACK")

    def publish(self, topic, payload):
        self._send(0x30, _str(topic) + payload)

    def ping(self):
        self._send(0xC0, b"")

    def messages(self, timeout):
        """Yield payloads of incoming PUBLISHes until timeout expires."""
        deadline = time.time() + timeout
        last_ping = time.time()
        while time.time() < deadline:
            if time.time() - last_ping > 30:
                self.ping()
                last_ping = time.time()
            t, body = self._packet(timeout=min(1.0, deadline - time.time()))
            if t is None:
                yield None            # idle tick, lets callers time out
                continue
            if t & 0xF0 != 0x30:
                continue
            tl = int.from_bytes(body[0:2], "big")
            off = 2 + tl
            if (t >> 1) & 3:          # QoS > 0 carries a packet id
                off += 2
            yield body[off:]

    def close(self):
        try:
            self._send(0xE0, b"")
        except OSError:
            pass
        self.sock.close()


def out(data):
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--broker", default=DEFAULT_BROKER)
    ap.add_argument("--topic", default=DEFAULT_TOPIC)
    ap.add_argument("--quiet-for", type=float, default=1.5)
    ap.add_argument("--timeout", type=float, default=20.0)
    ap.add_argument("-h", "--help", action="store_true")
    ap.add_argument("action", nargs="?")
    ap.add_argument("arg", nargs="*")
    a = ap.parse_args()

    if a.help or not a.action:
        print(__doc__)
        return 0

    rx, tx = a.topic + "/rx", a.topic + "/tx"
    m = MQTT(a.broker)
    try:
        if a.action in ("listen", "cmd", "expect"):
            m.subscribe(rx)

        if a.action == "listen":
            secs = float(a.arg[0]) if a.arg else 10.0
            for payload in m.messages(secs):
                if payload:
                    out(payload)
            return 0

        if a.action == "send":
            m.publish(tx, " ".join(a.arg).encode())
            time.sleep(0.3)
            return 0

        if a.action == "raw":
            m.publish(tx, bytes.fromhex("".join(a.arg)))
            time.sleep(0.3)
            return 0

        if a.action == "cmd":
            # Drain anything already in flight so the reply is not mixed with
            # leftovers from a previous command.
            for _ in m.messages(0.3):
                pass
            m.publish(tx, (" ".join(a.arg)).encode() + b"\r")
            last = time.time()
            for payload in m.messages(a.timeout):
                if payload:
                    out(payload)
                    last = time.time()
                elif time.time() - last >= a.quiet_for:
                    break
            out(b"\n")
            return 0

        if a.action == "expect":
            want = a.arg[0].encode()
            secs = float(a.arg[1]) if len(a.arg) > 1 else a.timeout
            seen = b""
            for payload in m.messages(secs):
                if payload:
                    out(payload)
                    seen += payload
                    if want in seen:
                        out(b"\n[matched]\n")
                        return 0
            out(b"\n[no match]\n")
            return 1

        sys.exit(f"unknown action '{a.action}' (see --help)")
    finally:
        m.close()


if __name__ == "__main__":
    sys.exit(main())
