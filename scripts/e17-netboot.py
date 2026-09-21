#!/usr/bin/env python3
"""Reboot the board and netboot a kernel of our choosing.

Why this exists: U-Boot loads its environment "from nowhere" on this board, so
`bootfile` reverts to its built-in default at every reset.  The default points
at the TFTP *root*, which we cannot write; the file bridge only gives us a
subdirectory.  So to boot a kernel we pushed, autoboot has to be interrupted
and `bootfile` set by hand each time.

That is not purely a nuisance - it is a usable safety net.  A kernel under test
lives in the subdirectory and is only booted deliberately; if it wedges, the
watchdog resets the board and it comes back on the known-good kernel in the
root, with no hands needed.

    e17-netboot.py                          boot e17/vmlinux.e17.stripped.lz4
    e17-netboot.py --bootfile e17/other.lz4
    e17-netboot.py --no-reboot              board is already resetting
    e17-netboot.py --dry-run                just watch the console

Options: --broker/--topic for the serial bridge, --host for the telnet shell,
--wait for how long to follow the boot (default 300 s).
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mqttlib import MQTT                                    # noqa: E402

PROMPT = b"e17 =>"
AUTOBOOT = b"Hit any key to stop autoboot"
BOOTED = b"Run /init as init process"


def reboot_via_telnet(host):
    """Ask the running kernel to reset.  If it cannot, the watchdog will."""
    from e17sh import Telnet

    try:
        t = Telnet(host, 23, timeout=15)
    except OSError as e:
        print(f"[no telnet ({e}); reset the board yourself]")
        return False
    t.read(3)
    print("[telnet: sending 'reboot -f']")
    t.s.sendall(b"reboot -f\n")
    time.sleep(1)
    t.close()
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--broker", default=os.environ.get("E17_BROKER",
                                                       "192.168.3.2"))
    ap.add_argument("--topic", default=os.environ.get("E17_TOPIC",
                                                      "m68k/e17/serial"))
    ap.add_argument("--host", default=os.environ.get("E17_HOST",
                                                     "192.168.2.221"))
    ap.add_argument("--bootfile", default="e17/vmlinux.e17.stripped.lz4")
    ap.add_argument("--no-reboot", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    ap.add_argument("--wait", type=float, default=300.0)
    a = ap.parse_args()

    rx, tx = a.topic + "/rx", a.topic + "/tx"
    m = MQTT(a.broker, client_id=f"e17-netboot-{os.getpid()}")
    m.subscribe(rx)

    if not a.no_reboot and not a.dry_run:
        reboot_via_telnet(a.host)

    seen = b""
    stage = "waiting for u-boot"
    last_poke = 0.0
    deadline = time.time() + a.wait
    print(f"[{stage}]")

    for topic, payload in m.messages(a.wait):
        if payload:
            sys.stdout.buffer.write(payload)
            sys.stdout.buffer.flush()
            seen += payload
            seen = seen[-4096:]

        if a.dry_run:
            continue

        if stage == "waiting for u-boot":
            # Spam a harmless key through the autoboot countdown; at 9600 baud
            # the three-second window is too short to react to precisely.
            if AUTOBOOT in seen and time.time() - last_poke > 0.2:
                m.publish(tx, b" ")
                last_poke = time.time()
            if PROMPT in seen:
                print(f"\n[u-boot prompt reached; bootfile={a.bootfile}]")
                time.sleep(0.5)
                m.publish(tx, b"setenv bootfile " + a.bootfile.encode() + b"\r")
                time.sleep(1.5)
                m.publish(tx, b"run netboot\r")
                stage = "booting"
                seen = b""
                print("[booting]")
                continue

        if stage == "booting" and BOOTED in seen:
            print("\n[kernel reached userspace]")
            return 0

        if time.time() > deadline:
            break

    print(f"\n[gave up after {a.wait:.0f}s in stage '{stage}']")
    return 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
