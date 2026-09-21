#!/usr/bin/env bash
# Build qemu-system-m68k with the 'e17' machine model.
#
# Out-of-tree build in build/qemu; the source tree is untouched.  Only the m68k
# target is built - a full QEMU build takes an order of magnitude longer and we
# never use the rest.
. "$(dirname "$0")/lib.sh"

SRC="$(resolve_src qemu)"
OUT="$BUILD/qemu"

for t in ninja meson pkg-config python3; do
	have "$t" || die "missing host tool '$t' - run 'make deps'"
done

grep -q 'ELTEC Eurocom E17' "$SRC/hw/m68k/e17.c" 2>/dev/null ||
	die "$SRC does not contain the e17 machine (hw/m68k/e17.c) - wrong branch?
  expected QEMU_REF=$QEMU_REF"

if [ ! -f "$OUT/build.ninja" ]; then
	say "configuring QEMU in $OUT"
	mkdir -p "$OUT"
	( cd "$OUT" && "$SRC/configure" \
		--target-list=m68k-softmmu \
		--enable-slirp \
		--disable-docs \
		--disable-werror )
fi

say "building (-j$JOBS)"
ninja -C "$OUT" -j "$JOBS" qemu-system-m68k

BIN="$OUT/qemu-system-m68k"
[ -x "$BIN" ] || die "build finished but $BIN is missing"
say "built $BIN"
"$BIN" -M help | grep -i e17 || warn "the 'e17' machine is not in -M help"
