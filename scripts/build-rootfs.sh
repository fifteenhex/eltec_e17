#!/usr/bin/env bash
# Build the initramfs the kernel boots.
#
# Contents:
#   /init            PID 1.  ROOTFS_INIT=nolibc (default) builds rootfs/init.c
#                    against the kernel's own nolibc - a few KB instead of
#                    ~550 KB of static glibc, which matters because a fat
#                    vmlinux collides with U-Boot's bootelf load on the real
#                    board.  ROOTFS_INIT=busybox uses rootfs/init.sh instead.
#   /init-smptest    the SMP/hotplug stress harness (boot with
#                    rdinit=/init-smptest)
#   /bin/busybox     static BusyBox, if the toolchain can link a libc
#   /dev/console etc static device nodes
#
# The device nodes have to be baked in: the kernel needs to open /dev/console
# for PID 1 *before* /init runs, and ordinary cpio cannot make device nodes
# without root.  The kernel's gen_init_cpio can, so we build a second archive
# with it and concatenate (the initramfs loader reads back-to-back archives).
. "$(dirname "$0")/lib.sh"

LINUX="$(resolve_src linux)"
SMOLUTILS="${SMOLUTILS:-/workspace/src/smolutils}"
NLEXT="${NLEXT:-/workspace/src/nolibc-extensions}"
OUT="$BUILD/rootfs"
ROOT="$OUT/root"
CPIO="$OUT/e17-rootfs.cpio"
KHDR="$BUILD/khdr"

need_cross
have cpio || die "missing 'cpio' - run 'make deps'"

rm -rf "$ROOT"
mkdir -p "$ROOT"/{bin,sbin,dev,proc,sys,root,run,tmp,etc} "$OUT"

# ---- kernel headers + gen_init_cpio (host tool) -----------------------------

have rsync || die "kernel headers_install needs 'rsync' - run 'make deps'"
if [ ! -d "$KHDR/include/asm" ] && [ ! -d "$KHDR/asm" ]; then
	say "installing kernel headers -> $KHDR"
	make -C "$LINUX" ARCH=m68k O="$BUILD/khdr-build" \
		INSTALL_HDR_PATH="$KHDR" headers_install >/dev/null
fi
# headers_install normally lands in $KHDR/include; tolerate either layout.
KINC="$KHDR/include"
[ -d "$KINC/asm" ] || KINC="$KHDR"

GEN="$OUT/gen_init_cpio"
if [ ! -x "$GEN" ]; then
	say "building gen_init_cpio"
	cc -O2 -o "$GEN" "$LINUX/usr/gen_init_cpio.c"
fi

# ---- nolibc userspace -------------------------------------------------------

nolibc_cc() {  # nolibc_cc <out> <src>
	"${CROSS}gcc" -Os -static -nostdlib -nostdinc \
		-fno-stack-protector -fno-asynchronous-unwind-tables -fno-ident \
		-isystem "$LINUX/tools/include/nolibc" \
		-isystem "$KINC" \
		-include nolibc.h \
		-o "$1" "$2" -lgcc
	"${CROSS}strip" "$1"
}

say "building init-smptest (nolibc)"
nolibc_cc "$ROOT/init-smptest" "$TOP/tests/smpstress.c"

case "${ROOTFS_INIT:-nolibc}" in
nolibc)
	say "building /init (nolibc)"
	nolibc_cc "$ROOT/init" "$TOP/rootfs/init.c"
	install -m 0755 "$TOP/rootfs/init.sh" "$ROOT/init.real"
	;;
busybox)
	say "using the BusyBox shell script as /init"
	install -m 0755 "$TOP/rootfs/init.sh" "$ROOT/init"
	;;
*)
	die "ROOTFS_INIT must be 'nolibc' or 'busybox'"
	;;
esac

# ---- smolutils --------------------------------------------------------------
#
# The userspace is smolutils rather than BusyBox: it is built against the same
# nolibc (plus nolibc-extensions for the sockets nolibc lacks), so it needs no
# target libc at all, and it is small enough not to bloat the netboot image.
# telnetd matters most - with Linux up, the CD2401 console is output-only, so
# it is the only way to drive the board.

# getty is not optional: telnetd spawns /sbin/getty for every session, so
# without it a telnet connection is accepted and then silently dies with no
# shell - which, when the serial console is output-only, means no way into the
# board at all.
SMOL_PROGS="${SMOL_PROGS:-smolsh telnetd getty cat ls ps dmesg uname df mount kill touch tftp}"

if [ -d "$SMOLUTILS" ] && [ -d "$NLEXT/include" ]; then
	say "building smolutils userspace ($SMOL_PROGS)"
	for p in $SMOL_PROGS; do
		[ -f "$SMOLUTILS/$p.c" ] || { warn "no $p.c in $SMOLUTILS"; continue; }
		"${CROSS}gcc" -include "$LINUX/tools/include/nolibc/nolibc.h" \
			-include "$NLEXT/include/nolibc-extensions.h" \
			-Wl,--hash-style=gnu \
			-Werror=return-type -Werror=implicit-function-declaration \
			-nostdlib -std=c99 -Os -m68040 -static \
			-I"$KINC" -I"$NLEXT/include" \
			-o "$ROOT/bin/$p" "$SMOLUTILS/$p.c" -lgcc ||
			die "failed to build smolutils/$p.c"
		"${CROSS}strip" "$ROOT/bin/$p"
	done
	ln -sf smolsh "$ROOT/bin/sh"
	# telnetd execs it by absolute path.
	if [ -x "$ROOT/bin/getty" ]; then
		mkdir -p "$ROOT/sbin"
		mv "$ROOT/bin/getty" "$ROOT/sbin/getty"
	fi
else
	warn "no smolutils at $SMOLUTILS (or nolibc-extensions at $NLEXT):
  the image will have no shell and no telnetd, so the board cannot be driven."
fi

# ---- BusyBox (legacy, needs a libc) -----------------------------------------

if [ "${ROOTFS_BUSYBOX:-0}" = 1 ] && cross_has_libc; then
	BB="$BUILD/busybox/busybox-$BUSYBOX_VERSION"
	if [ ! -x "$BB/busybox" ]; then
		mkdir -p "$BUILD/busybox" "$BUILD/dl"
		tarball="$BUILD/dl/busybox-$BUSYBOX_VERSION.tar.bz2"
		[ -f "$tarball" ] || {
			say "downloading BusyBox $BUSYBOX_VERSION"
			curl -fL --progress-bar -o "$tarball" "$BUSYBOX_URL"
		}
		[ -d "$BB" ] || tar -C "$BUILD/busybox" -xf "$tarball"
		say "configuring BusyBox"
		make -C "$BB" defconfig >/dev/null
		# Static, and no TC applet (it does not build against modern headers).
		sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' "$BB/.config"
		sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' "$BB/.config"
		make -C "$BB" CROSS_COMPILE="$CROSS" oldconfig >/dev/null
		say "building BusyBox (-j$JOBS)"
		make -C "$BB" CROSS_COMPILE="$CROSS" -j "$JOBS" >/dev/null
	fi
	install -m 0755 "$BB/busybox" "$ROOT/bin/busybox"
	ln -sf busybox "$ROOT/bin/sh"
elif [ "${ROOTFS_BUSYBOX:-0}" = 1 ]; then
	warn "${CROSS}gcc cannot link a libc - skipping BusyBox."
fi

# ---- pack -------------------------------------------------------------------

say "packing $CPIO"
( cd "$ROOT" && find . | LC_ALL=C sort |
	cpio -o -H newc --owner=0:0 --quiet ) > "$CPIO"
"$GEN" "$TOP/rootfs/dev.list" >> "$CPIO"

sz=$(wc -c < "$CPIO")
say "initramfs: $sz bytes"

# Soft memory-layout guard: on the real board U-Boot TFTPs this to
# ${initrd_start}=0x1810000 on a 32 MB machine, and U-Boot itself lives at the
# top of RAM.  Leave ~2 MB of headroom.
python3 - "$sz" <<'EOF'
import sys
sz = int(sys.argv[1]); start = 0x1810000; top = 0x2000000; head = 0x200000
if start + sz >= top - head:
    print("==> warning: initramfs ends at 0x%x, past the safe limit 0x%x" %
          (start + sz, top - head))
    print("    shrink it, or lower initrd_start / fit more RAM")
EOF
