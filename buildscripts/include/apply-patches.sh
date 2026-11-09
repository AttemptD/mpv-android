#!/bin/bash

# Check committed fork sources as well as the bases of uncommitted patches.
require_revision () {
	local dep="$1" revision="$2"
	local actual
	actual=$(git -C "$dep" rev-parse HEAD) || return 1
	if [ "$actual" != "$revision" ]; then
		echo >&2 "Unexpected $dep revision $actual; expected $revision."
		echo >&2 "Preserve local changes, then update the checkout before retrying."
		return 1
	fi
}

# Apply a complete local patch only to its recorded upstream source revision.
# The reverse check makes repeated dependency downloads safe.
apply_pinned_patch () {
	local dep="$1" revision="$2" patch="$3"
	require_revision "$dep" "$revision" || return 1
	if [ ! -f "$patch" ]; then
		echo >&2 "Required local patch missing: $patch"
		return 1
	fi
	if git -C "$dep" apply --reverse --check "$patch" 2>/dev/null; then
		return 0
	fi
	git -C "$dep" apply --check "$patch" || return 1
	git -C "$dep" apply "$patch"
}
