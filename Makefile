# ELTEC EUROCOM-17 test environment.
#
#   make deps        host packages (needs sudo)
#   make toolchain   m68k cross toolchain from kernel.org (no root needed)
#   make sources     clone/update the QEMU, Linux and U-Boot forks
#   make all         build everything and stage the boot images
#   make run-linux   boot the kernel in the QEMU model
#
# See docs/TESTING.md for what each piece is and how the real board is driven.

include config.mk

export QEMU_SRC QEMU_GIT QEMU_REF
export LINUX_SRC LINUX_GIT LINUX_REF
export UBOOT_SRC UBOOT_GIT UBOOT_REF
export BUILD TFTP CROSS CROSSTOOL_GCC JOBS
export LINUX_DEFCONFIG UBOOT_DEFCONFIG
export BUSYBOX_VERSION BUSYBOX_URL ROOTFS_INIT
export RAM SMP VIDEO ROM NVRAM

S := $(CURDIR)/scripts

.PHONY: help all deps toolchain sources qemu linux uboot rootfs boot-images \
        run-rmon run-uboot run-linux run-smptest probe-qemu probe-board \
        tftp nvram console console-cmd shell clean distclean

help:
	@sed -n '2,9p' $(MAKEFILE_LIST) | sed 's/^# \{0,1\}//'
	@echo ""
	@echo "Targets:"
	@echo "  deps          install host build dependencies (apt, needs sudo)"
	@echo "  toolchain     fetch the kernel.org m68k crosstool into build/toolchain"
	@echo "  sources       clone or update the QEMU / Linux / U-Boot forks"
	@echo "  qemu          build qemu-system-m68k with the 'e17' machine"
	@echo "  linux         build the kernel ($(LINUX_DEFCONFIG))"
	@echo "  uboot         build U-Boot ($(UBOOT_DEFCONFIG))"
	@echo "  rootfs        build the initramfs cpio (BusyBox + init)"
	@echo "  boot-images   stage kernel/dtb/initramfs/u-boot into $(TFTP)"
	@echo "  all           sources + qemu + uboot + rootfs + linux + boot-images"
	@echo ""
	@echo "  run-rmon      boot the RMON ROM in the model"
	@echo "  run-uboot     boot U-Boot in the model"
	@echo "  run-linux     boot the kernel in the model (SMP=$(SMP))"
	@echo "  run-smptest   boot the kernel with rdinit=/init-smptest"
	@echo "  probe-qemu    run the read-only register probe against the model"
	@echo "  probe-board   run it against a real board (PORT=/dev/ttyUSB0)"
	@echo "  tftp          serve $(TFTP) for netbooting the real board"
	@echo "  nvram         create a blank 2 KB M48T02 image"
	@echo ""
	@echo "  console       watch the real board's serial console (SECS=30)"
	@echo "  console-cmd   send one RMON command      CMD='db fec20600 10'"
	@echo "  shell         run a command on the booted board over telnet"
	@echo ""
	@echo "  clean         remove build outputs (keeps fetched sources)"
	@echo "  distclean     remove $(BUILD) entirely"

all: sources qemu uboot rootfs linux boot-images

deps:
	$(S)/deps.sh

toolchain:
	$(S)/toolchain.sh

sources:
	$(S)/fetch-sources.sh

qemu:
	$(S)/build-qemu.sh

linux:
	$(S)/build-linux.sh

uboot:
	$(S)/build-uboot.sh

rootfs:
	$(S)/build-rootfs.sh

boot-images:
	$(S)/package-boot.sh

nvram:
	$(S)/mknvram.sh

run-rmon:   ; $(S)/run-qemu.sh rmon
run-uboot:  ; $(S)/run-qemu.sh uboot
run-linux:  ; $(S)/run-qemu.sh linux
run-smptest:; $(S)/run-qemu.sh smptest

probe-qemu:
	$(S)/run-qemu.sh probe

probe-board:
	@test -n "$(PORT)" || { echo "usage: make probe-board PORT=/dev/ttyUSB0 [BAUD=9600]"; exit 2; }
	python3 tools/e17probe.py $(PORT) $(or $(BAUD),9600)

tftp:
	$(S)/tftp-serve.sh

# --- driving the real board ---------------------------------------------
# console: the serial console, bridged to MQTT by serial2mqtt.
# shell:   BusyBox telnetd, which is how you get input in (the serial console
#          is output-only on the current kernel).
console:
	python3 $(S)/e17con.py listen $(or $(SECS),30)

console-cmd:
	@test -n "$(CMD)" || { echo 'usage: make console-cmd CMD="db fec20600 10"'; exit 2; }
	python3 $(S)/e17con.py cmd $(CMD)

shell:
	@test -n "$(CMD)" || { echo 'usage: make shell CMD="cat /proc/interrupts"'; exit 2; }
	python3 $(S)/e17sh.py $(CMD)

clean:
	rm -rf $(BUILD)/qemu $(BUILD)/linux $(BUILD)/u-boot $(BUILD)/rootfs \
	       $(BUILD)/busybox $(TFTP)

distclean:
	rm -rf $(BUILD)
