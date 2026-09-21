#!/usr/bin/env python3
"""Persistent E17 serial-console logger.

Follows the MQTT serial-console topic and appends everything to a file, so a
boot (or a watchdog reset, or an auth code printed on the securetty) can be read
back after the fact.  Runs forever, reconnecting on drop.

    e17-conlog.py [logfile]        default: $BUILD/console.log

Kept in the repo (not /tmp, which this sandbox wipes) so it survives.  The log
is capped: once it passes --max bytes it is truncated to the last half, so it
cannot fill the (shared, often full) disk.
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from mqttlib import MQTT                                    # noqa: E402


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    default_log = os.path.join(here, os.pardir, "build", "console.log")
    ap = argparse.ArgumentParser()
    ap.add_argument("logfile", nargs="?", default=os.path.abspath(default_log))
    ap.add_argument("--broker", default=os.environ.get("E17_BROKER", "192.168.3.2"))
    ap.add_argument("--topic", default=os.environ.get("E17_TOPIC", "m68k/e17/serial"))
    ap.add_argument("--max", type=int, default=4 << 20, help="cap in bytes")
    a = ap.parse_args()

    os.makedirs(os.path.dirname(a.logfile), exist_ok=True)
    log = open(a.logfile, "ab", buffering=0)

    def cap():
        if log.tell() < a.max:
            return
        log.flush()
        with open(a.logfile, "rb") as f:
            f.seek(-a.max // 2, os.SEEK_END)
            tail = f.read()
        log.seek(0)
        log.truncate()
        log.write(b"[...truncated...]\n" + tail)

    while True:
        try:
            m = MQTT(a.broker, client_id=f"e17-conlog-{os.getpid()}")
            m.subscribe(a.topic + "/rx")
            log.write(b"\n[connected %s]\n" % time.strftime("%T").encode())
            for _topic, payload in m.messages(None):
                if payload:
                    log.write(payload)
                    cap()
        except Exception as e:  # noqa: BLE001 - keep the logger alive
            log.write(b"\n[reconnect %s: %s]\n"
                      % (time.strftime("%T").encode(), str(e).encode()))
            time.sleep(0.5)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
