#!/usr/bin/env python3
"""Telnet into the E17 and run commands, handling smolutils' auth.

smolutils (master) authenticates a telnet login - and `su` - by printing a
random code on the "securetty" (the E17 serial console) and asking for it back.
We can read that console over MQTT (scripts/e17-conlog.py writes it to
build/console.log), so this client watches the log for the freshest
"code <hex>" line and types it when prompted.  That is the supported way in and
the supported way to root on this board.

    e17-telnet.py "uname -a" "cat /proc/uptime"     run commands as the login user
    e17-telnet.py --root "id" "devmem 0xfec20000"   su to root first, then run

Options: --host/--port, --log (securetty capture), --timeout.
"""
import argparse
import os
import re
import socket
import sys
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240
CODE_RE = re.compile(rb"code ([0-9a-f]{6})")


def newest_code(logpath, after):
    """Return the most recent auth code written to the securetty after `after`."""
    try:
        if os.path.getmtime(logpath) < after - 1:
            return None
        with open(logpath, "rb") as f:
            data = f.read()
    except OSError:
        return None
    m = CODE_RE.findall(data)
    return m[-1] if m else None


class Telnet:
    def __init__(self, host, port, timeout):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.settimeout(1.0)

    def _filter(self, data):
        out, resp, i = b"", b"", 0
        while i < len(data):
            if data[i] == IAC and i + 1 < len(data):
                cmd = data[i + 1]
                if cmd in (WILL, WONT) and i + 2 < len(data):
                    resp += bytes([IAC, DONT, data[i + 2]]); i += 3; continue
                if cmd in (DO, DONT) and i + 2 < len(data):
                    resp += bytes([IAC, WONT, data[i + 2]]); i += 3; continue
                if cmd == SB:
                    j = data.find(bytes([IAC, SE]), i)
                    i = len(data) if j < 0 else j + 2; continue
                i += 2; continue
            out += data[i:i + 1]; i += 1
        if resp:
            self.s.sendall(resp)
        return out

    def read(self, secs):
        out, end = b"", time.time() + secs
        while time.time() < end:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                continue
            if not d:
                break
            out += self._filter(d)
        return out

    def send(self, s):
        self.s.sendall(s.encode() if isinstance(s, str) else s)


def answer_auth(t, log, started, seen, wait=12.0):
    """If the peer asks (or is about to ask) for a code, read it from the
    securetty and send it.  getty can be slow to print the prompt under load,
    so wait for "code:" to appear rather than giving up on the first read."""
    end = time.time() + wait
    while b"code:" not in seen and time.time() < end:
        seen += t.read(1)
    if b"code:" not in seen:
        return False
    for _ in range(40):
        code = newest_code(log, started)
        if code:
            t.send(code + b"\n")
            return True
        time.sleep(0.3)
    return False


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    ap = argparse.ArgumentParser()
    ap.add_argument("cmds", nargs="*")
    ap.add_argument("--host", default=os.environ.get("E17_HOST", "192.168.2.154"))
    ap.add_argument("--port", type=int, default=23)
    ap.add_argument("--root", action="store_true", help="su to root first")
    ap.add_argument("--log", default=os.path.join(here, os.pardir, "build", "console.log"))
    ap.add_argument("--timeout", type=float, default=20.0)
    a = ap.parse_args()
    log = os.path.abspath(a.log)

    started = time.time()
    t = Telnet(a.host, a.port, a.timeout)
    seen = t.read(3)
    # A login may demand the securetty code before giving a prompt.
    if answer_auth(t, log, started, seen):
        seen += t.read(4)
    sys.stdout.write(seen.decode("latin1", "replace"))

    if a.root:
        started = time.time()
        t.send("su\n")
        r = t.read(3)
        if answer_auth(t, log, started, r):
            r += t.read(4)
        sys.stdout.write(r.decode("latin1", "replace"))

    for c in a.cmds:
        t.send(c + "\n")
        sys.stdout.write(t.read(4).decode("latin1", "replace"))
    sys.stdout.write("\n")


if __name__ == "__main__":
    try:
        main()
    except (OSError, KeyboardInterrupt) as e:
        print(f"[e17-telnet: {e}]", file=sys.stderr)
        sys.exit(1)
