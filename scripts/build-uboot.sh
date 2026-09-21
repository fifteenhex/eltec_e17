#!/usr/bin/env bash
# Build U-Boot for the E17.
#
# Out-of-tree (O=build/u-boot).  Produces:
#   u-boot       ELF, what QEMU's -kernel loads
#   u-boot.bin   raw binary, the thing that gets S-record loaded onto the board
#   u-boot.srec  S-records for RMON's 'sload' + 'gm' (see docs/TESTING.md)
#
# TEXT_BASE is 0x600000 and the first longwords of u-boot.bin form the module
# header RMON's 'gm' consumes (SP at +0, entry at +4) - which is why the
# S-records must be made from the BINARY, not from the ELF.
. "$(dirname "$0")/lib.sh"

SRC="$(resolve_src uboot)"
OUT="$BUILD/u-boot"
TEXT_BASE=0x600000

need_cross
export CROSS_COMPILE="$CROSS"

mkdir -p "$OUT"
[ -f "$OUT/.config" ] || {
	say "configuring: $UBOOT_DEFCONFIG"
	make -C "$SRC" O="$OUT" "$UBOOT_DEFCONFIG"
}

say "building (-j$JOBS)"
make -C "$SRC" O="$OUT" -j "$JOBS"

[ -f "$OUT/u-boot.bin" ] || die "no u-boot.bin produced"

say "making S-records at $TEXT_BASE"
"${CROSS}objcopy" -I binary -O srec \
	--change-addresses="$TEXT_BASE" --srec-forceS3 \
	"$OUT/u-boot.bin" "$OUT/u-boot.srec"
# RMON's sload wants an S0 header record and CRLF line endings, or it reports
# "Transfer complete" and silently loads nothing.
sed -i '1i S00600004844521B' "$OUT/u-boot.srec"
sed -i 's/$/\r/' "$OUT/u-boot.srec"

head -1 "$OUT/u-boot.srec" | grep -q '^S0' || warn "S0 header record missing"
say "built $OUT/u-boot (+ .bin, .srec)"
