#!/usr/bin/env bash
# Install the host packages the rest of the scripts need.
#
# Debian/Ubuntu only.  Needs root; if sudo wants a password this script prints
# the command instead of hanging on a prompt, so you can run it yourself.
. "$(dirname "$0")/lib.sh"

PKGS_COMMON="build-essential git curl python3 python3-venv bc bison flex \
libssl-dev libelf-dev cpio lz4 rsync file kmod"

PKGS_QEMU="ninja-build meson pkg-config libglib2.0-dev libpixman-1-dev \
libslirp-dev zlib1g-dev python3-setuptools"

# The Debian cross toolchain.  gcc-m68k-linux-gnu alone builds the kernel and
# U-Boot; libc6-dev-m68k-cross is what BusyBox needs.
PKGS_CROSS="gcc-m68k-linux-gnu binutils-m68k-linux-gnu libc6-dev-m68k-cross"

# Optional, for driving serial consoles and netboot by hand.
PKGS_EXTRA="socat python3-serial tftpd-hpa gdb-multiarch"

ALL="$PKGS_COMMON $PKGS_QEMU $PKGS_CROSS $PKGS_EXTRA"

if [ "$(id -u)" = 0 ]; then
	SUDO=""
elif sudo -n true 2>/dev/null; then
	SUDO="sudo"
else
	cat <<EOF
This needs root and sudo is asking for a password.  Run:

    sudo apt-get update
    sudo apt-get install -y $(echo $ALL | fmt -w 68 | sed '2,$s/^/        /')

Then re-run the build.  (If you cannot install packages, 'make toolchain'
fetches an m68k cross compiler into build/toolchain without root - enough
for the kernel, U-Boot and the nolibc userspace, but not for BusyBox.)
EOF
	exit 1
fi

say "apt-get update"
$SUDO apt-get update
say "installing: $ALL"
# shellcheck disable=SC2086
$SUDO apt-get install -y $ALL
say "done"
