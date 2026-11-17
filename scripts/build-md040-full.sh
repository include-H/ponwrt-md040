#!/bin/sh
# Build the "full" MD040 image with the plugin set from include-H/XG-040G-MD.
set -e
cd "$(dirname "$0")/.."

[ -f configs/md040-full.config ] || {
	echo "missing configs/md040-full.config" >&2
	exit 1
}

./scripts/feeds update -a
./scripts/feeds install -a
./scripts/apply-feed-patches.sh

cp configs/md040-full.config .config
make defconfig

# dae/luci-app-dae are dropped by defconfig because KERNEL_XDP_SOCKETS is a
# hidden kernel symbol in this tree.  Force the selections after defconfig;
# the package build and image install use .config directly.
cat >> .config <<'EOF'
CONFIG_PACKAGE_dae=y
CONFIG_PACKAGE_dae-geoip=y
CONFIG_PACKAGE_dae-geosite=y
CONFIG_PACKAGE_luci-app-dae=y
CONFIG_PACKAGE_luci-i18n-dae-zh-cn=y
CONFIG_PACKAGE_kmod-veth=y
CONFIG_PACKAGE_kmod-xdp-sockets-diag=y
EOF

make -j"$(nproc)" download
make -j"$(nproc)" world

echo
echo "images: bin/targets/airoha/an7581/"
