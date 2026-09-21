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

# An O= build refuses to run against a tree that already holds an in-tree
# build, and the development machine's tree does (and is short on disk, so
# a second copy of the objects is not free).  Fall back to building in place
# when that is the situation; the source itself is unmodified either way.
if [ -e "$SRC/.config" ] || [ -e "$SRC/vmlinux.o" ]; then
	if [ "${FORCE_O_BUILD:-}" = 1 ]; then
		die "$SRC has an in-tree build; run 'make mrproper' there or unset FORCE_O_BUILD"
	fi
	warn "$SRC already has an in-tree build - building in place, not in $OUT"
	OUT="$SRC"
	IN_TREE=1
fi

need_cross
have bison && have flex || die "the kernel needs bison and flex - run 'make deps'"

export ARCH=m68k
export CROSS_COMPILE="$CROSS"

mkdir -p "$OUT"

# With an in-tree build O= must not be passed at all.
if [ "${IN_TREE:-0}" = 1 ]; then
	O=()
else
	O=(O="$OUT")
fi

if [ ! -f "$OUT/.config" ]; then
	say "configuring: $LINUX_DEFCONFIG"
	make -C "$SRC" "${O[@]}" "$LINUX_DEFCONFIG"
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
make -C "$SRC" "${O[@]}" olddefconfig

say "building (-j$JOBS)"
make -C "$SRC" "${O[@]}" -j "$JOBS"

[ -f "$OUT/vmlinux" ] || die "no vmlinux produced"

# Record where it landed, so package-boot.sh finds it whether the build was
# out-of-tree or in place.
mkdir -p "$BUILD"
echo "$OUT" > "$BUILD/.linux-out"
say "built $OUT/vmlinux"
"${CROSS}size" "$OUT/vmlinux" || true
