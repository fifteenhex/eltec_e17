#!/usr/bin/env bash
# Build the E17 kernel.
#
# Out-of-tree (O=build/linux).  The shipped defconfig points
# CONFIG_INITRAMFS_SOURCE at an absolute path on the development machine; we
# repoint it at whatever 'make rootfs' produced, or turn it off if there is no
# rootfs yet (the kernel still boots, it just has no userspace).
. "$(dirname "$0")/lib.sh"

SRC="$(resolve_src linux)"
OUT="$BUILD/linux"
CPIO="$BUILD/rootfs/e17-rootfs.cpio"

need_cross
have bison && have flex || die "the kernel needs bison and flex - run 'make deps'"

export ARCH=m68k
export CROSS_COMPILE="$CROSS"

mkdir -p "$OUT"

if [ ! -f "$OUT/.config" ]; then
	say "configuring: $LINUX_DEFCONFIG"
	make -C "$SRC" O="$OUT" "$LINUX_DEFCONFIG"
fi

if [ -f "$CPIO" ]; then
	say "initramfs: $CPIO"
	"$SRC/scripts/config" --file "$OUT/.config" \
		--enable BLK_DEV_INITRD \
		--set-str INITRAMFS_SOURCE "$CPIO"
else
	warn "no $CPIO yet - building without a baked-in initramfs ('make rootfs' first)"
	"$SRC/scripts/config" --file "$OUT/.config" --set-str INITRAMFS_SOURCE ""
fi
make -C "$SRC" O="$OUT" olddefconfig

say "building (-j$JOBS)"
make -C "$SRC" O="$OUT" -j "$JOBS"

[ -f "$OUT/vmlinux" ] || die "no vmlinux produced"
say "built $OUT/vmlinux"
"${CROSS}size" "$OUT/vmlinux" || true
