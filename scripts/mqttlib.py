#!/usr/bin/env python3
"""Minimal MQTT 3.1.1 client - no dependencies.

Enough of the protocol for the E17 tooling: CONNECT, SUBSCRIBE, PUBLISH at
QoS 0 and 1 (waiting for the PUBACK), PINGREQ keepalive and DISCONNECT.  The
wire format matches smolmqtt.h, which is what the lab already runs.

    m = MQTT("192.168.3.2", client_id="e17-tool")
    m.subscribe("m68k/e17/serial/rx")
    m.publish("m68k/e17/serial/tx", b"\\r")
    for topic, payload in m.messages(timeout=10):
        ...

`messages()` yields (None, None) once a second while idle so callers can
implement their own timeouts without blocking forever.
"""
import os
import socket
import time

CONNECT, CONNACK = 0x10, 0x20
PUBLISH, PUBACK = 0x30, 0x40
SUBSCRIBE, SUBACK = 0x82, 0x90
PINGREQ, PINGRESP = 0xC0, 0xD0
DISCONNECT = 0xE0


def _rlen(n):
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


class MQTTError(Exception):
    pass


class MQTT:
    def __init__(self, broker, port=1883, client_id=None, keepalive=60):
        self.sock = socket.create_connection((broker, port), timeout=20)
        self.sock.settimeout(1.0)
        self.buf = b""
        self.pid = 0
        self.keepalive = keepalive
        self.last_tx = time.time()
        cid = client_id or f"mqttlib-{os.getpid()}"
        var = _str("MQTT") + bytes([4, 0x02]) + keepalive.to_bytes(2, "big")
        self._send(CONNECT, var + _str(cid))
        t, body = self._packet(10)
        if t != CONNACK:
            raise MQTTError("no CONNACK")
        if len(body) > 1 and body[1] != 0:
            raise MQTTError(f"connection refused, code {body[1]}")

    # ---- wire ----------------------------------------------------------

    def _send(self, byte1, body):
        self.sock.sendall(bytes([byte1]) + _rlen(len(body)) + body)
        self.last_tx = time.time()

    def _packet(self, timeout):
        """Return (type, body), or (None, None) if nothing arrived in time."""
        deadline = time.time() + timeout
        while True:
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
                    t, body = self.buf[0], self.buf[i:i + val]
                    self.buf = self.buf[i + val:]
                    return t, body
            left = deadline - time.time()
            if left <= 0:
                return None, None
            self.sock.settimeout(min(left, 1.0))
            try:
                d = self.sock.recv(65536)
            except socket.timeout:
                if time.time() >= deadline:
                    return None, None
                continue
            if not d:
                raise MQTTError("broker closed the connection")
            self.buf += d

    # ---- operations ----------------------------------------------------

    def subscribe(self, topic, qos=0):
        self.pid = (self.pid + 1) & 0xFFFF
        self._send(SUBSCRIBE,
                   self.pid.to_bytes(2, "big") + _str(topic) + bytes([qos]))
        t, _ = self._packet(10)
        if t is None or t & 0xF0 != SUBACK:
            raise MQTTError("no SUBACK")

    def publish(self, topic, payload, qos=0):
        if isinstance(payload, str):
            payload = payload.encode()
        if qos == 0:
            self._send(PUBLISH, _str(topic) + payload)
            return
        self.pid = (self.pid + 1) & 0xFFFF
        self._send(PUBLISH | 0x02,
                   _str(topic) + self.pid.to_bytes(2, "big") + payload)
        deadline = time.time() + 15
        while time.time() < deadline:
            t, body = self._packet(deadline - time.time())
            if t is None:
                break
            if t & 0xF0 == PUBACK and int.from_bytes(body[0:2], "big") == self.pid:
                return
        raise MQTTError("no PUBACK")

    def ping(self):
        self._send(PINGREQ, b"")

    def messages(self, timeout=None):
        """Yield (topic, payload); (None, None) roughly once a second idle."""
        deadline = None if timeout is None else time.time() + timeout
        while deadline is None or time.time() < deadline:
            if time.time() - self.last_tx > self.keepalive / 2:
                self.ping()
            slice_ = 1.0 if deadline is None else min(1.0, deadline - time.time())
            t, body = self._packet(max(0.05, slice_))
            if t is None:
                yield None, None
                continue
            if t & 0xF0 != PUBLISH:
                continue
            tl = int.from_bytes(body[0:2], "big")
            topic = body[2:2 + tl].decode("latin1")
            off = 2 + tl
            qos = (t >> 1) & 3
            if qos:
                pid = int.from_bytes(body[off:off + 2], "big")
                off += 2
                if qos == 1:
                    self._send(PUBACK, pid.to_bytes(2, "big"))
            yield topic, body[off:]

    def close(self):
        try:
            self._send(DISCONNECT, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass
