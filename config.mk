# Build configuration for the EUROCOM-17 test environment.
#
# Everything here is overridable, either by editing this file or on the command
# line:  make linux LINUX_REF=m68k-smp JOBS=4
#
# The three upstream trees (QEMU, Linux, U-Boot) are *forks* and are not public.
# Each one is resolved like this, in order:
#
#   1. if <NAME>_SRC points at an existing directory, that tree is used in place
#      (this is the default - the working trees on the development machine);
#   2. otherwise the tree is cloned from <NAME>_GIT at branch <NAME>_REF into
#      $(BUILD)/src/<name> and updated on each `make sources`.
#
# Builds are always out-of-tree (kernel/U-Boot O=, QEMU separate build dir), so
# using the working trees in place does not dirty them.

# ---- where the sources come from -------------------------------------------

QEMU_SRC   ?= $(CURDIR)/qemu
QEMU_GIT   ?= /workspace/git/qemu.git
QEMU_REF   ?= e17-linux

LINUX_SRC  ?= $(CURDIR)/linux
LINUX_GIT  ?= /workspace/git/linux.git
LINUX_REF  ?= e17-clean

UBOOT_SRC  ?= $(CURDIR)/u-boot
UBOOT_GIT  ?= /workspace/git/u-boot.git
UBOOT_REF  ?= e17-fixes

# ---- where things are built ------------------------------------------------

BUILD      ?= $(CURDIR)/build
# Everything the board (or the model) actually boots ends up here.  This is also
# the TFTP root used for netbooting the real machine.
TFTP       ?= $(BUILD)/tftp

# ---- toolchain -------------------------------------------------------------

# Prefix for the m68k cross toolchain.  Debian's gcc-m68k-linux-gnu gives you a
# glibc-capable toolchain (needed for BusyBox); `make toolchain` fetches the
# kernel.org crosstool build instead, which is enough for the kernel, U-Boot and
# the nolibc userspace but cannot build BusyBox.
CROSS      ?= m68k-linux-gnu-
CROSSTOOL_GCC ?= 14.3.0

JOBS       ?= $(shell nproc 2>/dev/null || echo 4)

# ---- kernel / U-Boot configs ------------------------------------------------

LINUX_DEFCONFIG ?= eltec-e17_defconfig
UBOOT_DEFCONFIG ?= eltec-e17_defconfig

# ---- rootfs ----------------------------------------------------------------

BUSYBOX_VERSION ?= 1.36.1
BUSYBOX_URL ?= https://busybox.net/downloads/busybox-$(BUSYBOX_VERSION).tar.bz2
# init=... baked into the initramfs: "nolibc" (rootfs/init.c, the production
# PID 1) or "busybox" (rootfs/init.sh).  BusyBox aborts with "stack smashing
# detected" under QEMU system emulation, so nolibc is the default.
ROOTFS_INIT ?= nolibc

# ---- the real board ---------------------------------------------------------

# Serial console, bridged by smolmqtt's serial2mqtt.
MQTT_BROKER ?= 192.168.3.2
MQTT_TOPIC  ?= m68k/e17/serial
# The lab's TFTP root, served by smolmqtt's file2mqtt (see docs/TESTING.md).
MQTT_FILE_TOPIC ?= m68k/e17/files
MQTTFILE    ?= /workspace/src/smolmqtt/mqttfile
TARWAK      ?= /workspace/src/tarwak/build/tarwak
# The booted kernel's telnetd, which is how commands get in (the serial
# console is output-only once Linux is up).
E17_HOST    ?= 192.168.2.154

# ---- QEMU run defaults ------------------------------------------------------

RAM        ?= 32M
SMP        ?= 2
# The real board has no video fitted, so the default model matches it and puts
# the console on serial.  VIDEO=on opens a display window with the Bt445
# framebuffer and the PS/2 keyboard.
VIDEO      ?= off
ROM        ?= $(CURDIR)/rmon.bin
NVRAM      ?= $(BUILD)/nvram.img
