#!/usr/bin/env python3
"""Tiny read-only TFTP server for netbooting the real EUROCOM-17.

Enough of RFC 1350 + RFC 2348 (blksize) for U-Boot's client: RRQ in octet
mode, one file at a time, retransmit on timeout.  No writes, no directory
traversal - the served path is confined to the root directory.

    scripts/tftpd.py <root-dir> [port]

Port defaults to 69, which needs root; any other port works unprivileged and
is handy for testing (u-boot cannot use it, though).
"""
import os
import socket
import sys

OP_RRQ, OP_WRQ, OP_DATA, OP_ACK, OP_ERROR, OP_OACK = 1, 2, 3, 4, 5, 6
RETRIES = 5
TIMEOUT = 2.0


def error(sock, peer, code, msg):
    sock.sendto(OP_ERROR.to_bytes(2, "big") + code.to_bytes(2, "big") +
                msg.encode() + b"\0", peer)


def serve_file(root, peer, fields):
    name = fields[0].decode("latin1")
    opts = {}
    rest = fields[2:]
    for k, v in zip(rest[0::2], rest[1::2]):
        opts[k.decode("latin1").lower()] = v.decode("latin1")

    # Confine to root: no absolute paths, no "..".
    path = os.path.realpath(os.path.join(root, name.lstrip("/")))
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.settimeout(TIMEOUT)

    if not path.startswith(os.path.realpath(root) + os.sep) or \
            not os.path.isfile(path):
        print(f"  {peer[0]} -> {name}: NOT FOUND")
        error(sock, peer, 1, "file not found")
        return

    blksize = 512
    if "blksize" in opts:
        blksize = max(8, min(65464, int(opts["blksize"])))

    data = open(path, "rb").read()
    print(f"  {peer[0]} -> {name}: {len(data)} bytes, blksize {blksize}")

    block = 0
    if opts:
        ack = {"blksize": str(blksize)}
        if "tsize" in opts:
            ack["tsize"] = str(len(data))
        pkt = OP_OACK.to_bytes(2, "big")
        for k, v in ack.items():
            pkt += k.encode() + b"\0" + v.encode() + b"\0"
        if not exchange(sock, peer, pkt, 0):
            return

    off = 0
    while True:
        block = (block + 1) & 0xFFFF
        chunk = data[off:off + blksize]
        pkt = OP_DATA.to_bytes(2, "big") + block.to_bytes(2, "big") + chunk
        if not exchange(sock, peer, pkt, block):
            print("  timed out")
            return
        off += len(chunk)
        if len(chunk) < blksize:
            print("  complete")
            return


def exchange(sock, peer, pkt, expect_block):
    """Send pkt, wait for the matching ACK, retransmitting on timeout."""
    for _ in range(RETRIES):
        sock.sendto(pkt, peer)
        try:
            reply, addr = sock.recvfrom(1024)
        except socket.timeout:
            continue
        if addr[0] != peer[0] or len(reply) < 4:
            continue
        op = int.from_bytes(reply[0:2], "big")
        blk = int.from_bytes(reply[2:4], "big")
        if op == OP_ERROR:
            msg = reply[4:].rstrip(b"\0").decode("latin1", "replace")
            print(f"  client error: {msg}")
            return False
        if op == OP_ACK and blk == expect_block:
            return True
    return False


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    root = os.path.realpath(sys.argv[1])
    port = int(sys.argv[2]) if len(sys.argv) > 2 else 69
    if not os.path.isdir(root):
        sys.exit(f"no such directory: {root}")

    srv = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        srv.bind(("", port))
    except PermissionError:
        sys.exit(f"cannot bind udp/{port} - run as root, or pass a high port")
    print(f"tftpd: serving {root} on udp/{port} (read-only, Ctrl-C to stop)")

    while True:
        pkt, peer = srv.recvfrom(1024)
        if len(pkt) < 4:
            continue
        op = int.from_bytes(pkt[0:2], "big")
        fields = pkt[2:].split(b"\0")
        if op == OP_RRQ:
            serve_file(root, peer, fields)
        elif op == OP_WRQ:
            error(srv, peer, 2, "read-only server")


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        print()
