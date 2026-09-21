#!/usr/bin/env bash
# Build the initramfs the kernel boots.
#
# Contents:
#   /init            PID 1: smolutils' init (master), which also provides
#                    reboot/poweroff/halt and starts getty/telnetd from the
#                    smolinit.* kernel command line (see configs/e17.h).
#   /sbin, /bin      smolutils userland (busybox-style multicall binaries),
#                    built static for -m68040 from the smolutils tree.
#   /init-smptest    the SMP/hotplug stress harness (boot with
#                    rdinit=/init-smptest)
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

# ---- nolibc helper (for the standalone SMP stress harness) ------------------

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

# ---- smolutils (master) -----------------------------------------------------
#
# The userspace is smolutils, built from its own tree with Makefile.m68kmmu
# (CPU=68040, NOPIE=1 -> plain -static, no dynamic loader).  Master is a
# busybox-style set of multicall binaries plus a real init/getty/telnetd with
# an auth mechanism:
#
#   * init  is PID 1 and also provides reboot/poweroff/halt (dispatched on
#     argv[0]); it reads smolinit.* args from the kernel command line to know
#     which gettys and telnetd to start (see the bootargs in configs/e17.h).
#   * a "securetty" (set to the serial console) is where auth codes are shown.
#     A telnet login and `su` each print a random code there and ask for it
#     back - and since the E17 serial console is output-only under Linux
#     (console_rx defaults off, see the CD2401 driver), that code appears on
#     serial2mqtt where we can read it.  This is the supported way to root.
#   * getty drops the login to an unprivileged uid; `su` regains root from a
#     file capability (cap_setuid,cap_setgid) that startup applies at boot -
#     no setuid bit.  This needs CONFIG_TMPFS_XATTR so the rootfs can hold it.
#
# There is deliberately no serial getty: the console is output-only, so a
# getty there could never read a login.  Input is via telnet.

SMOL_MK="${SMOL_MK:-Makefile.m68kmmu}"
SMOL_CPU="${SMOL_CPU:-68040}"
TARWAK="${TARWAK:-/workspace/src/tarwak/build/tarwak}"

# tarwak features that select the optional manifest entities (net tools,
# telnetd, and the initramfs /init -> /sbin/init symlink).  Kept in step with
# what we build below.
SMOL_FEATURES="-fnet -ftelnetd -finitramfs -fmodules"

if [ -d "$SMOLUTILS" ] && [ -d "$NLEXT/include" ] && [ -x "$TARWAK" ]; then
	say "building smolutils ($SMOL_MK CPU=$SMOL_CPU)"
	make -C "$SMOLUTILS" -f "$SMOL_MK" CPU="$SMOL_CPU" NOPIE=1 \
		CROSS_COMPILE="$CROSS" \
		NOLIBCDIR="$LINUX/tools/include/nolibc" \
		NOLIBCEXTDIR="$NLEXT" \
		UAPIDIR="$KINC" \
		TARWAK="$TARWAK" \
		-j "$JOBS" elfs >/dev/null || die "smolutils build failed"

	# Let smolutils lay out its own rootfs from rootfs.tarwak.json: the proper
	# /lib/smol multicall binaries, the /bin and /sbin symlink farm, the
	# /init -> /sbin/init initramfs symlink, and the file-capability xattrs on
	# su/ping/init (so su becomes root from a capability, not a setuid bit).
	# tarwak writes a tar; bsdtar converts it to a newc cpio in the pack step
	# below, carrying the capability xattrs straight into the initramfs image.
	say "packing smolutils rootfs (tarwak)"
	( cd "$SMOLUTILS" && "$TARWAK" -i rootfs.tarwak.json -o "$OUT/smol.tar" \
		-b ./ -p "%s.$SMOL_CPU.elf" $SMOL_FEATURES ) ||
		die "tarwak failed"
else
	warn "no smolutils at $SMOLUTILS, nolibc-extensions at $NLEXT, or tarwak at
  $TARWAK: the image will have no shell and no telnetd, so the board cannot be
  driven.  Build tarwak (meson) or set TARWAK=."
fi

# ---- pack -------------------------------------------------------------------
#
# The initramfs is concatenated cpio archives, so it is assembled in pieces:
#   1. the smolutils rootfs, converted tar -> newc cpio by bsdtar (this is the
#      libarchive path that preserves the capability xattrs);
#   2. the device nodes and the standalone SMP stress harness, which are not in
#      the manifest, added with the kernel's gen_init_cpio.
have bsdtar || die "missing 'bsdtar' (libarchive-tools) - run 'make deps'"

say "packing $CPIO"
if [ -f "$OUT/smol.tar" ]; then
	bsdtar --format=newc -cf "$CPIO" @"$OUT/smol.tar"
else
	: > "$CPIO"
fi

# dev nodes (kernel needs /dev/console before /init) + init-smptest, appended
# through gen_init_cpio, which can make device nodes without being root.
EXTRA_MANIFEST="$OUT/extra.cpiolist"
cat "$TOP/rootfs/dev.list" > "$EXTRA_MANIFEST"
[ -f "$ROOT/init-smptest" ] &&
	echo "file /init-smptest $ROOT/init-smptest 0755 0 0" >> "$EXTRA_MANIFEST"
"$GEN" "$EXTRA_MANIFEST" >> "$CPIO"

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
