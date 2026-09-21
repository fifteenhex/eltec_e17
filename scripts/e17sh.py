#!/usr/bin/env python3
"""Run shell commands on the EUROCOM-17 over telnet.

The board's serial console is output-only in practice (the CD2401 receive path
is exactly what the current debugging is about), so `/init` starts a BusyBox
telnetd and that is the way in.  This is a minimal telnet client - it refuses
every option the server offers - wrapped so a command can be run and its output
captured from a script.

    e17sh.py "uname -a"                  run one command, print the output
    e17sh.py -f cmds.txt                 run each line of a file
    e17sh.py --shell                     interactive-ish: read commands on stdin

Options:
    --host H      default $E17_HOST or 192.168.2.221
    --port P      default 23
    --timeout S   per-command quiet timeout (default 8)

Note telnetd on this board blocks until the kernel's CRNG is seeded, which on a
freshly booted 68040 with no entropy source can take several minutes.  If the
connection times out right after boot, that is why - wait for
"random: crng init done" on the serial console.
"""
import argparse
import os
import socket
import sys
import time

IAC, DONT, DO, WONT, WILL, SB, SE = 255, 254, 253, 252, 251, 250, 240


class Telnet:
    def __init__(self, host, port=23, timeout=20):
        self.s = socket.create_connection((host, port), timeout=timeout)
        self.s.settimeout(1.0)

    def _filter(self, data):
        """Strip telnet negotiation, refusing every option."""
        out, resp, i = b"", b"", 0
        while i < len(data):
            if data[i] == IAC and i + 1 < len(data):
                cmd = data[i + 1]
                if cmd in (WILL, WONT) and i + 2 < len(data):
                    resp += bytes([IAC, DONT, data[i + 2]])
                    i += 3
                    continue
                if cmd in (DO, DONT) and i + 2 < len(data):
                    resp += bytes([IAC, WONT, data[i + 2]])
                    i += 3
                    continue
                if cmd == SB:                     # skip the subnegotiation
                    j = data.find(bytes([IAC, SE]), i)
                    i = len(data) if j < 0 else j + 2
                    continue
                if cmd == IAC:                    # escaped 0xff
                    out += b"\xff"
                    i += 2
                    continue
                i += 2
                continue
            out += data[i:i + 1]
            i += 1
        if resp:
            self.s.sendall(resp)
        return out

    def read(self, quiet, hard=120):
        """Read until the board has been silent for `quiet` seconds."""
        out, last, start = b"", time.time(), time.time()
        while time.time() - last < quiet and time.time() - start < hard:
            try:
                d = self.s.recv(4096)
            except socket.timeout:
                continue
            if not d:
                break
            c = self._filter(d)
            if c:
                out += c
                last = time.time()
        return out

    def run(self, cmd, quiet):
        self.s.sendall(cmd.encode() + b"\n")
        return self.read(quiet)

    def close(self):
        try:
            self.s.close()
        except OSError:
            pass


def main():
    ap = argparse.ArgumentParser(add_help=False)
    ap.add_argument("--host", default=os.environ.get("E17_HOST", "192.168.2.221"))
    ap.add_argument("--port", type=int, default=23)
    ap.add_argument("--timeout", type=float, default=8.0)
    ap.add_argument("-f", "--file")
    ap.add_argument("--shell", action="store_true")
    ap.add_argument("-h", "--help", action="store_true")
    ap.add_argument("cmd", nargs="*")
    a = ap.parse_args()

    if a.help or (not a.cmd and not a.file and not a.shell):
        print(__doc__)
        return 0

    t = Telnet(a.host, a.port)
    try:
        banner = t.read(3)
        if b"#" not in banner and b"$" not in banner:
            sys.stderr.write("warning: no shell prompt in the banner\n")

        if a.file:
            cmds = [ln.rstrip("\n") for ln in open(a.file)
                    if ln.strip() and not ln.startswith("#")]
        elif a.shell:
            cmds = [ln.rstrip("\n") for ln in sys.stdin]
        else:
            cmds = [" ".join(a.cmd)]

        for c in cmds:
            sys.stdout.buffer.write(t.run(c, a.timeout))
            sys.stdout.buffer.flush()
        return 0
    finally:
        t.close()


if __name__ == "__main__":
    sys.exit(main())
