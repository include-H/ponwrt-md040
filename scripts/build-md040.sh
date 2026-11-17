#!/bin/sh
set -e
cd "$(dirname "$0")/.."

[ -f configs/md040.config ] || {
	echo "missing configs/md040.config" >&2
	exit 1
}

./scripts/feeds update -a
./scripts/feeds install -a
./scripts/apply-feed-patches.sh

cp configs/md040.config .config
make defconfig
make -j"$(nproc)" download
make -j"$(nproc)" world

echo
echo "images: bin/targets/airoha/an7581/"
