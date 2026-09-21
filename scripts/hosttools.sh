#!/usr/bin/env bash
# Build the host tools the kernel needs, from source, into build/hosttools.
#
# The kernel's kconfig and its copy of dtc are generated with flex and bison at
# build time (no _shipped parsers any more), so without them nothing builds.
# 'make deps' installs them from Debian, but that needs root; this does the same
# job with no privileges at all, which is what you want on a machine where you
# cannot install packages.
#
# bison invokes m4 at run time, so m4 comes first.
. "$(dirname "$0")/lib.sh"

PREFIX="$BUILD/hosttools"
DL="$BUILD/dl"
mkdir -p "$PREFIX" "$DL"

M4_VER=1.4.19
BISON_VER=3.8.2
FLEX_VER=2.6.4

M4_URL="https://ftp.gnu.org/gnu/m4/m4-$M4_VER.tar.xz"
BISON_URL="https://ftp.gnu.org/gnu/bison/bison-$BISON_VER.tar.xz"
FLEX_URL="https://github.com/westes/flex/releases/download/v$FLEX_VER/flex-$FLEX_VER.tar.gz"

export PATH="$PREFIX/bin:$PATH"

build_one() {  # build_one <name> <version> <url> <extra configure args...>
	local name="$1" ver="$2" url="$3"
	shift 3
	local tarball="$DL/$(basename "$url")"
	local src="$BUILD/hosttools-src/$name-$ver"

	[ -f "$tarball" ] || {
		say "downloading $name $ver"
		curl -fL --progress-bar -o "$tarball" "$url"
	}
	[ -d "$src" ] || {
		mkdir -p "$BUILD/hosttools-src"
		tar -C "$BUILD/hosttools-src" -xf "$tarball"
	}
	say "building $name $ver"
	( cd "$src" && ./configure --prefix="$PREFIX" "$@" >/dev/null &&
	  make -j"$JOBS" >/dev/null && make install >/dev/null )
}

if have m4 && [ -z "${FORCE:-}" ]; then
	say "m4 already available: $(command -v m4)"
else
	build_one m4 "$M4_VER" "$M4_URL"
fi

if have bison && [ -z "${FORCE:-}" ]; then
	say "bison already available: $(command -v bison)"
else
	build_one bison "$BISON_VER" "$BISON_URL"
fi

if have flex && [ -z "${FORCE:-}" ]; then
	say "flex already available: $(command -v flex)"
else
	# flex's own test suite needs bison; skip building the tests.
	build_one flex "$FLEX_VER" "$FLEX_URL" --disable-shared
fi

say "host tools in $PREFIX/bin"
for t in m4 bison flex; do
	printf '    %-6s %s\n' "$t" "$(command -v $t) ($($t --version 2>&1 | head -1))"
done
