#!/usr/bin/env bash
# Run the QEMU e17 model.
#
#   run-qemu.sh rmon      RMON monitor only (the board as it ships)
#   run-qemu.sh uboot     RMON + U-Boot loaded via -kernel
#   run-qemu.sh linux     the kernel, straight in via -kernel
#   run-qemu.sh smptest   the kernel with rdinit=/init-smptest
#   run-qemu.sh probe     headless, driven by tools/e17probe.py
#
# Knobs (config.mk or the environment): RAM SMP VIDEO ROM NVRAM APPEND EXTRA
#
# Note -bios rmon.bin is needed even for -kernel: the 680x0 reset SP/PC are
# read out of the ROM file, and -kernel only loads an ELF and enters it.
. "$(dirname "$0")/lib.sh"

MODE="${1:-linux}"

QEMU="$BUILD/qemu/qemu-system-m68k"
[ -x "$QEMU" ] || QEMU="$(command -v qemu-system-m68k || true)"
[ -n "$QEMU" ] && [ -x "$QEMU" ] || die "no qemu-system-m68k - run 'make qemu'"

[ -f "$ROM" ] || die "missing ROM $ROM"

# 2 KB M48T02 backing store, so the RTC and the saved configuration persist.
NVRAM="${NVRAM:-$BUILD/nvram.img}"
[ -f "$NVRAM" ] || "$TOP/scripts/mknvram.sh"

KERNEL="$BUILD/vmlinux.e17"
UBOOT="$BUILD/u-boot/u-boot"
APPEND="${APPEND:-console=ttyS0 ip=dhcp}"

args=(
	-M "e17,video=$VIDEO"
	-m "$RAM"
	-smp "$SMP"
	-bios "$ROM"
	-drive "if=mtd,format=raw,file=$NVRAM"
	-nic "user,tftp=$TFTP"
)

# With no video fitted the console is serial, so -nographic is the right shape:
# one terminal, serial multiplexed with the QEMU monitor (Ctrl-A c to switch,
# Ctrl-A x to quit).  With video fitted a display window opens instead.
if [ "$VIDEO" = off ]; then
	args+=(-nographic)
else
	args+=(-serial mon:stdio)
fi

case "$MODE" in
rmon)
	;;
uboot)
	[ -f "$UBOOT" ] || die "no $UBOOT - run 'make uboot'"
	args+=(-kernel "$UBOOT")
	;;
linux)
	[ -f "$KERNEL" ] || die "no $KERNEL - run 'make linux boot-images'"
	args+=(-kernel "$KERNEL" -append "$APPEND")
	;;
smptest)
	[ -f "$KERNEL" ] || die "no $KERNEL - run 'make linux boot-images'"
	args+=(-kernel "$KERNEL" -append "$APPEND rdinit=/init-smptest")
	;;
probe)
	sock="$BUILD/e17-probe.sock"
	rm -f "$sock"
	args=(
		-M "e17,video=off" -m "$RAM" -smp "$SMP" -bios "$ROM"
		-drive "if=mtd,format=raw,file=$NVRAM"
		-nic "user,tftp=$TFTP"
		-serial "unix:$sock,server,nowait" -display none
	)
	say "starting the model headless on $sock"
	"$QEMU" "${args[@]}" &
	qpid=$!
	# shellcheck disable=SC2064
	trap "kill $qpid 2>/dev/null || true" EXIT
	for _ in $(seq 50); do [ -S "$sock" ] && break; sleep 0.1; done
	sleep 1
	python3 "$TOP/tools/e17probe.py" --socket "$sock"
	exit 0
	;;
*)
	die "unknown mode '$MODE' (rmon|uboot|linux|smptest|probe)"
	;;
esac

# shellcheck disable=SC2086
say "$QEMU ${args[*]} ${EXTRA:-}"
exec "$QEMU" "${args[@]}" ${EXTRA:-}
