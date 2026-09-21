#!/usr/bin/env bash
# Create a blank 2 KB M48T02 backing file for the model (-drive if=mtd).
#
# A blank image makes RMON warn about the parameter checksum once, exactly as a
# board with a dead battery does; after one 'we' from the monitor the warning
# goes away and the saved configuration persists across runs.
#
# Tip: the DIP-switch low nibble decides whether RMON reads its configuration
# from NVRAM at all - 1 or 2 means "use the saved config", anything else picks a
# ROM profile.  In the model: -global e17-sysc.dip-switches=1
. "$(dirname "$0")/lib.sh"

OUT="${1:-${NVRAM:-$BUILD/nvram.img}}"
mkdir -p "$(dirname "$OUT")"
if [ -f "$OUT" ]; then
	say "$OUT already exists (delete it to start fresh)"
	exit 0
fi
dd if=/dev/zero of="$OUT" bs=2048 count=1 status=none
say "created $OUT (2048 bytes)"
