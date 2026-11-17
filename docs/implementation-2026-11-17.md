# MD040 PPE / 光口修复实施记录

日期：2026-11-17
分支：`md040`

## 1. 本轮目标

1. 让 `lan1`（2.5G）↔ `pon0`（XG-PON）的路由/NAT 流量真正进入 PPE。
2. 修 PPPoE / 控制包在 RX ring 上的黑洞，避免 PPPoE 断网和 DHCP/PPPoE 协商失败。
3. 给 XG-PON MBI RX overrun 增加自动恢复，避免 `int=0x8000 fifo=0x180` 后永久断网。
4. 保持 IPTV `br-iptv` 为软件桥，不混入主路由 flowtable。

## 2. 已应用的补丁

### 2.1 内核 target 补丁

| 文件 | 来源 | 作用 |
|---|---|---|
| `target/linux/airoha/patches-6.18/925-net-airoha-handle-rx-no-cpu-dscp-irq.patch` | OpenWrt #24715 / Vitaliy Sochniy | `NO_CPU_DSCP` 中断也调度 NAPI，ring 排空后能重新补充 |
| `target/linux/airoha/patches-6.18/926-net-airoha-recover-rx-ring-hw-stall.patch` | OpenWrt #24715 / Vitaliy Sochniy | 用 `RX_DMA_IDX` 对比 `tail` 检测硬件完成竞争，work item 里重置 ring |
| `target/linux/airoha/patches-6.18/991-md040-ppe-flow-stats-safe.patch` | naoki66 / liujixings `9999-14` | NPU 不支持 flow stats 时安全继续；检查 `npu->stats`，跳过 stats reset/readout 和 PSE port 6 重定向 |
| `target/linux/airoha/patches-6.18/992-md040-pppoe-mtu.patch` | 由 naoki66 `920-17` 适配到 6.18.60 | PPE/WAN egress MTU 计入 PPPoE 8 字节头 |
| `target/linux/airoha/patches-6.18/993-md040-ipv6-pppoe-flow-offload.patch` | 由 wuziwei `931` 抽取核心修复 | 非 bridge 不 fallthrough 到 L2 subflow；IPv6 子流保留 PPPoE ID；AN7581 IPv6 route 跳过 NPU stats |
| `182-v7.4-net-airoha-grow-the-small-RX-rings.patch` | 已有 | ring 4 = 128，fallback 16→32 |

### 2.2 Feed 补丁

| 文件 | 作用 |
|---|---|
| `patches/feeds/pon_drivers/mbi-reset.patch` | issue #49：MBI RX overrun 计数达到 32 次、且距上次 reset ≥60s，置 `mbi_reset_pending`，由 `link_work` 调 `airoha_xpon_xgpon_restart_mac()` |
| `scripts/apply-feed-patches.sh` | 在 `feeds install` 后把补丁应用到 `feeds/pon_drivers/airoha-xpon/src` |

### 2.3 用户态/网络

| 文件 | 作用 |
|---|---|
| `target/linux/airoha/an7581/base-files/etc/init.d/ppeflow` | 开机建立 `{ lan1, pon0 }` 的 `inet ppe` flowtable |
| `target/linux/airoha/an7581/base-files/etc/uci-defaults/99-md040-network` | `br-lan=lan1`；`br-iptv=lan2-4`；启用 `ppeflow` |

## 3. 编译验证

已执行：

```sh
./scripts/feeds update -a
./scripts/feeds install -a
./scripts/apply-feed-patches.sh
cp configs/md040.config .config
make defconfig
make target/linux/prepare V=s
```

结果：

- 925 / 926 / 991 / 992 / 993 均成功应用到 `linux-6.18.60`
- `991` 有 offset/fuzz，但目标代码已存在：
  - `if (!npu->stats) return;`
  - `if (npu && npu->stats)`
  - `if (npu->stats) airoha_ppe_foe_flow_stats_reset(...)`
- feed 补丁已应用到 `feeds/pon_drivers/airoha-xpon/src`

编译结果：

- `make -j$(nproc) target/linux/compile V=s` 成功
  - `arch/arm64/boot/Image` 13M
  - `vmlinux` 74M
  - `System.map` 含 `airoha_qdma_rx_recover_work`
  - `vmlinux` 字符串含 `qid=%d RX ring recovered after hw stall`
- `airoha-xpon.ko` 已编译
  - 874K，`vermagic: 6.18.60 SMP mod_unload aarch64`
  - 字符串含 `MBI RX overrun storm`、`mbi_reset: %u`
- `make -j$(nproc) world` 成功，退出码 0
  - `bin/targets/airoha/an7581/ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-squashfs-sysupgrade.itb`（14M）
  - `bin/targets/airoha/an7581/ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-initramfs-recovery.itb`（12M）
  - `sha256sum -c sha256sums` 全部通过
  - `version.buildinfo`：`r0-dade890`
  - sysupgrade sha256：`8c07d862a406ba296abe1b4ec6277970de9f4e89ab39e8cea8808cca7adb8335`
  - recovery sha256：`980b2f5cd1d67c3fd3e96c94bd28a883faa62b376f582b570b521779d4b1c75b`
- 发现并修正一个设备可用性问题：`airoha-en8811h-firmware` / `kmod-phy-airoha-en8811h` 原来是 `=m`，只编译不装入镜像；已改为 `=y`。最终 manifest 含：
  - `airoha-en8811h-firmware`
  - `kmod-phy-airoha-en8811h`
  - `/lib/modules/6.18.60/air_en8811h.ko`
  - `/lib/firmware/airoha/EthMD32.DSP.bin`
  - `/lib/firmware/airoha/EthMD32.dm.bin`
- 最终 rootfs / squashfs 已确认包含：
  - `/etc/init.d/ppeflow`
  - `/etc/rc.d/S99ppeflow -> ../init.d/ppeflow`
  - `/etc/uci-defaults/99-md040-network`
  - `/lib/modules/6.18.60/airoha-xpon.ko`（含 MBI reset 字符串）
  - `/lib/modules/6.18.60/air_en8811h.ko`

## 4. 上机验收

在设备上运行：

```sh
sh scripts/collect-md040-status.sh > /tmp/md040-status.txt
```

重点检查：

### PPE

- `/sys/kernel/debug/ppe/config`：`npu_attached: 1`，`ppe0_flow_cfg` / `ppe1_flow_cfg` 非 0
- `/sys/kernel/debug/ppe/bind`：有绑定条目
- `/sys/kernel/debug/ppe/entries`：出现 `BND`，PPPoE 流有 `pppoe_id`
- `nft list flowtables`：存在 `inet ppe`，`devices` 为 `lan1` / `pon0`
- `conntrack -L -o extended | grep -c HW_OFFLOAD`：计数增长
- 2.5G → PON 吞吐/CPU 对比：软中断明显下降

### 光口

- `ponctl --device pon0 status --json`：`service_ready: true`，`onu_state: O5`
- `dmesg | grep -E 'XG-PON MAC error|MBI|MAC epoch reset'`
  - 出现 overrun 后约 60s 内应看到 `MAC epoch reset` 或恢复日志
- PPPoE 不再 PADO 超时；`logread` 无持续 `int=0x8000 fifo=0x180`
- `ip -s link show pon0`：RX 计数恢复增长

## 5. 已知未完成

1. `9996` PPPoE 上传流 egress → PON GDM + GEM/T-CONT：未接入；当前依赖 nft flowtable 的物理 egress 路径。若上机发现 `pppoe-wan` 仍被 `-EINVAL` 拒绝，需要移植。
2. `gponDevMpiStopNoRxDone` 变体：未做；当前 #49 仍走 `stop_mac_interfaces()` 等待 3ms。
3. naoki66 的 RX stall watchdog（保留 30s 截止时间）：未移植；当前公开 pbs05 驱动没有 `rx_stall` 代码。
4. IPTV native L2B/组播卸载：保持实验性，见 `docs/iptv-ppe-evaluation.md`。
5. 硬件实测：尚未刷机；编译通过不等于 PPE 绑定/恢复已验证。
