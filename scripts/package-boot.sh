#!/usr/bin/env bash
# Stage everything the board (or the model) boots into $TFTP.
#
# U-Boot's default environment netboots three files:
#   vmlinux.e17.stripped.lz4   ${bootfile}    -> ${loadaddr}, unlz4'd, bootelf'd
#   eltec-e17.dtb              ${fdtfile}     -> ${fdtaddr}
#   e17-rootfs.cpio            ${initrd_file} -> ${initrd_start}
# The kernel is shipped stripped and lz4-compressed purely to keep the TFTP
# transfer short; bootelf parses the decompressed ELF.
. "$(dirname "$0")/lib.sh"

# build-linux.sh leaves a breadcrumb: the kernel may have been built in the
# source tree rather than in build/linux (see the note there).
LINUX_OUT="$BUILD/linux"
[ -f "$BUILD/.linux-out" ] && LINUX_OUT="$(cat "$BUILD/.linux-out")"
UBOOT_OUT="$BUILD/u-boot"
mkdir -p "$TFTP"

stage() {  # stage <src> <name>
	if [ -f "$1" ]; then
		install -m 0644 "$1" "$TFTP/$2"
		printf '    %-28s %10d bytes\n' "$2" "$(wc -c < "$1")"
	else
		warn "missing $1 (skipped $2)"
	fi
}

say "staging into $TFTP"

if [ -f "$LINUX_OUT/vmlinux" ]; then
	cp "$LINUX_OUT/vmlinux" "$BUILD/vmlinux.e17"
	"${CROSS}strip" -o "$BUILD/vmlinux.e17.stripped" "$LINUX_OUT/vmlinux"
	if have lz4; then
		# -B4 (64 KB blocks) rather than the 4 MB default: u-boot's lz4
		# wrapper pets the watchdog once per frame block, so a
		# single-block image decompresses for seconds with nothing
		# petting and the board resets mid-boot.  Costs ~6% in size.
		lz4 -9 -f -B4 "$BUILD/vmlinux.e17.stripped" \
			"$BUILD/vmlinux.e17.stripped.lz4" >/dev/null
	else
		warn "no lz4 on PATH - U-Boot's default netboot expects the .lz4"
	fi
fi

stage "$BUILD/vmlinux.e17"                 vmlinux.e17
stage "$BUILD/vmlinux.e17.stripped"        vmlinux.e17.stripped
stage "$BUILD/vmlinux.e17.stripped.lz4"    vmlinux.e17.stripped.lz4
stage "$LINUX_OUT/arch/m68k/dts/eltec-e17.dtb" eltec-e17.dtb
stage "$BUILD/rootfs/e17-rootfs.cpio"      e17-rootfs.cpio
stage "$UBOOT_OUT/u-boot"                  u-boot
stage "$UBOOT_OUT/u-boot.bin"              u-boot.bin
stage "$UBOOT_OUT/u-boot.srec"             u-boot.srec

say "done - 'make tftp' serves this directory to the real board"
