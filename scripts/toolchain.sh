#!/usr/bin/env bash
# Fetch a prebuilt m68k cross toolchain from kernel.org into build/toolchain.
#
# No root required.  This is the "nolibc" crosstool build: binutils + gcc with
# no target libc, which is everything the kernel, U-Boot and our nolibc
# userspace need.  BusyBox needs a libc, so for a full rootfs install Debian's
# gcc-m68k-linux-gnu + libc6-dev-m68k-cross instead ('make deps').
. "$(dirname "$0")/lib.sh"

GCC="${CROSSTOOL_GCC:-14.3.0}"
HOST_ARCH="$(uname -m)"
TARBALL="${HOST_ARCH}-gcc-${GCC}-nolibc-m68k-linux.tar.xz"
URL="https://mirrors.edge.kernel.org/pub/tools/crosstool/files/bin/${HOST_ARCH}/${GCC}/${TARBALL}"

DEST="$BUILD/toolchain"
if [ -x "$DEST/bin/m68k-linux-gcc" ] || [ -x "$DEST/bin/m68k-linux-gnu-gcc" ]; then
	say "toolchain already present in $DEST"
	"$DEST"/bin/m68k-linux*gcc --version | head -1
	exit 0
fi

mkdir -p "$BUILD/dl" "$DEST"
say "downloading $URL"
curl -fL --progress-bar -o "$BUILD/dl/$TARBALL" "$URL" ||
	die "download failed - check CROSSTOOL_GCC=$GCC exists for $HOST_ARCH"

say "unpacking"
# The tarball unpacks as gcc-<ver>-nolibc/m68k-linux/{bin,lib,...}
tmp="$(mktemp -d "$BUILD/dl/unpack.XXXXXX")"
tar -C "$tmp" -xf "$BUILD/dl/$TARBALL"
src="$(find "$tmp" -maxdepth 3 -type d -name 'm68k-linux' | head -1)"
[ -n "$src" ] || die "unexpected tarball layout"
rm -rf "$DEST"
mv "$src" "$DEST"
rm -rf "$tmp"

# kernel.org names the tools m68k-linux-*, Debian names them m68k-linux-gnu-*.
# Symlink the Debian spelling so CROSS= works either way.
( cd "$DEST/bin"
  for f in m68k-linux-*; do
	ln -sf "$f" "m68k-linux-gnu-${f#m68k-linux-}"
  done )

say "installed in $DEST"
"$DEST/bin/m68k-linux-gnu-gcc" --version | head -1
cat <<EOF

Add it to your PATH for manual use:

    export PATH="$DEST/bin:\$PATH"

The build scripts pick it up automatically.
EOF
