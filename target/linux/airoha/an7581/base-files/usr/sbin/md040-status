#!/bin/sh
# Collect MD040 PPE/PON status on the device.
# Usage: sh scripts/collect-md040-status.sh > /tmp/md040-status.txt

echo "===== system ====="
ubus call system board 2>/dev/null || true
uname -a
uptime

echo
echo "===== network ====="
ip -br link
ip -br addr
uci -q show network | grep -E 'wan|lan|iptv|pon0' || true

echo
echo "===== nft flowtables ====="
nft list flowtables 2>&1 || true
nft list table inet ppe 2>&1 || true

echo
echo "===== PPE debugfs ====="
for f in config bind entries; do
	echo "--- /sys/kernel/debug/ppe/$f ---"
	cat "/sys/kernel/debug/ppe/$f" 2>&1 | head -80
done

echo
echo "===== conntrack ====="
if command -v conntrack >/dev/null 2>&1; then
	conntrack -L -o extended 2>/dev/null | grep -c HW_OFFLOAD || true
	conntrack -L -o extended 2>/dev/null | grep HW_OFFLOAD | head -10 || true
fi

echo
echo "===== PON status ====="
if command -v ponctl >/dev/null 2>&1; then
	ponctl --device pon0 status --json 2>&1 || true
fi
for f in line mac registration datapath; do
	echo "--- /sys/kernel/debug/airoha-xpon-pon0/$f ---"
	cat "/sys/kernel/debug/airoha-xpon-pon0/$f" 2>&1 | head -80
done

echo
echo "===== counters ====="
ip -s link show pon0 2>&1 || true
ip -s link show lan1 2>&1 || true
for i in lan2 lan3 lan4; do ip -s link show "$i" 2>&1 || true; done

echo
echo "===== kernel log ====="
dmesg | grep -iE 'airoha|ppe|npu|xpon|mbi|mac error|overrun|rx ring|flow' | tail -80 || true
logread | grep -iE 'ppeflow|XG-PON MAC|MBI|pppoe|PADO' | tail -40 || true

echo
echo "===== top ====="
top -bn1 2>/dev/null | head -20 || true
