# Shared helpers for the EUROCOM-17 build scripts.  Sourced, not executed.
# shellcheck shell=bash

set -o errexit -o nounset -o pipefail

TOP="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="${BUILD:-$TOP/build}"
TFTP="${TFTP:-$BUILD/tftp}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"
CROSS="${CROSS:-m68k-linux-gnu-}"

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m==> warning:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m==> error:\033[0m %s\n' "$*" >&2; exit 1; }

# A toolchain fetched with scripts/toolchain.sh, and host tools built by
# scripts/hosttools.sh, live here; put both on PATH so the build scripts find
# them without the caller having to.
for d in "$BUILD/toolchain/bin" "$BUILD/hosttools/bin"; do
	[ -d "$d" ] && PATH="$d:$PATH"
done
export PATH

have() { command -v "$1" >/dev/null 2>&1; }

# True for a git working tree.  Note .git may be a *file* (a linked worktree),
# which is how the development machine has the Linux and U-Boot trees set up.
is_git() { git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }

need_cross() {
	have "${CROSS}gcc" || die "no ${CROSS}gcc on PATH.
  Either 'make deps' (Debian gcc-m68k-linux-gnu, needs sudo) or
  'make toolchain' (kernel.org crosstool, no root but no libc)."
}

# Cross toolchain that can link against a libc (needed for BusyBox).
cross_has_libc() {
	local rc=0
	mkdir -p "$BUILD"
	echo 'int main(void){return 0;}' > "$BUILD/.libc-probe.c"
	"${CROSS}gcc" -static -o "$BUILD/.libc-probe" "$BUILD/.libc-probe.c" \
		>/dev/null 2>&1 || rc=1
	rm -f "$BUILD/.libc-probe.c" "$BUILD/.libc-probe"
	return $rc
}

# resolve_src <NAME> -> echoes the source directory, cloning if necessary.
# Uses the <NAME>_SRC / <NAME>_GIT / <NAME>_REF variables from config.mk.
resolve_src() {
	local name="$1" upper lower src git ref
	upper="$(echo "$name" | tr '[:lower:]' '[:upper:]')"
	lower="$(echo "$name" | tr '[:upper:]' '[:lower:]')"
	eval "src=\${${upper}_SRC:-}"
	eval "git=\${${upper}_GIT:-}"
	eval "ref=\${${upper}_REF:-}"

	if [ -n "$src" ] && [ -d "$src" ]; then
		echo "$src"
		return 0
	fi
	src="$BUILD/src/$lower"
	if [ -d "$src" ] && is_git "$src"; then
		echo "$src"
		return 0
	fi
	[ -n "$git" ] || die "$upper: no source tree and no ${upper}_GIT to clone from"
	say "cloning $git ($ref) -> $src" >&2
	mkdir -p "$(dirname "$src")"
	git clone --branch "$ref" "$git" "$src" >&2
	echo "$src"
}
