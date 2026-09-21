#!/usr/bin/env bash
# Serve $TFTP to the real board for netbooting.
#
# U-Boot's default environment does DHCP and then TFTPs the kernel, the DTB and
# the initramfs from ${serverip} (0x1810000 etc, see docs/TESTING.md).  This
# script runs a foreground read-only TFTP server on port 69 - which needs root,
# so it re-execs under sudo unless you pass a high port:
#
#   scripts/tftp-serve.sh            # port 69, needs root
#   scripts/tftp-serve.sh 6969       # unprivileged, for testing the server
#
# DHCP itself is not provided here: use whatever already serves the lab network
# (or set a static ipaddr/serverip in the U-Boot environment).
. "$(dirname "$0")/lib.sh"

PORT="${1:-69}"
[ -d "$TFTP" ] || die "no $TFTP - run 'make boot-images' first"

say "serving $TFTP on udp/$PORT (read-only)"
ls -la "$TFTP"

if have in.tftpd; then
	CMD=(in.tftpd --listen --foreground --address ":$PORT" --secure "$TFTP")
else
	CMD=(python3 "$TOP/scripts/tftpd.py" "$TFTP" "$PORT")
fi

if [ "$PORT" -lt 1024 ] && [ "$(id -u)" != 0 ]; then
	exec sudo "${CMD[@]}"
fi
exec "${CMD[@]}"
