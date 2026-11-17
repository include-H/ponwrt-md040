#!/bin/sh
# Apply local patches on top of the cloned pon_drivers feed.
#
# The xPON driver lives in feeds/pon_drivers (pbs05/openwrt-pon-drivers),
# not in target/linux.  The patches are written against
# feeds/pon_drivers/airoha-xpon/src, so apply them with --directory.

set -e
cd "$(dirname "$0")/.."

FEED=feeds/pon_drivers
[ -d "$FEED/airoha-xpon" ] || {
	echo "missing $FEED/airoha-xpon; run scripts/feeds update/install first" >&2
	exit 1
}

apply_one() {
	patch=$1
	dir=$2

	if git -C "$FEED" apply --check --directory="$dir" "$patch" 2>/dev/null; then
		git -C "$FEED" apply --directory="$dir" "$patch"
		echo "applied $(basename "$patch")"
	elif git -C "$FEED" apply --reverse --check --directory="$dir" "$patch" 2>/dev/null; then
		echo "already applied $(basename "$patch")"
	else
		echo "failed to apply $(basename "$patch")" >&2
		exit 1
	fi
}

apply_one "$PWD/patches/feeds/pon_drivers/mbi-reset.patch" airoha-xpon/src

echo "feed patches applied"
