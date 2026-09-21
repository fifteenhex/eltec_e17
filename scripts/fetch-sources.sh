#!/usr/bin/env bash
# Resolve (and, if necessary, clone) the three upstream forks, then report what
# each one is sitting on.  Working trees that already exist are left alone - we
# never check out over someone's work in progress.
. "$(dirname "$0")/lib.sh"

status_of() {
	local name="$1" dir="$2" ref="$3"
	echo "--- $name: $dir"
	if ! is_git "$dir"; then
		echo "    (not a git tree)"
		return
	fi
	git -C "$dir" --no-pager log --oneline -1 || true
	local cur
	cur="$(git -C "$dir" rev-parse --abbrev-ref HEAD)"
	echo "    branch: $cur (expected $ref)"
	[ "$cur" = "$ref" ] || warn "$name is on '$cur', not '$ref'"
	# Not every branch here has an upstream configured, so fall back to the
	# remote-tracking ref for the branch we expect.
	local base=""
	if git -C "$dir" rev-parse --verify -q "@{upstream}" >/dev/null; then
		base="@{upstream}"
	elif git -C "$dir" rev-parse --verify -q "origin/$ref" >/dev/null; then
		base="origin/$ref"
	fi
	if [ -n "$base" ]; then
		local ahead
		ahead="$(git -C "$dir" rev-list --count "$base..HEAD")"
		[ "$ahead" = 0 ] ||
			warn "$name has $ahead commit(s) not in $base - a fresh clone will not have them"
	fi
	if [ -n "$(git -C "$dir" status --porcelain)" ]; then
		echo "    (working tree has local modifications)"
	fi
}

for c in qemu linux uboot; do
	dir="$(resolve_src "$c")"
	upper="$(echo "$c" | tr '[:lower:]' '[:upper:]')"
	eval "ref=\${${upper}_REF}"
	# Only fast-forward trees we manage ourselves under build/src.
	case "$dir" in
	"$BUILD/src/"*)
		say "updating $c"
		git -C "$dir" fetch origin "$ref"
		git -C "$dir" checkout "$ref"
		git -C "$dir" merge --ff-only "origin/$ref"
		;;
	esac
	status_of "$c" "$dir" "$ref"
done
