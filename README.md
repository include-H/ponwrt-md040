# MD040 — Nokia XG-040G-MD 自定义 PonWrt 维护仓库

本仓库是 [PonWrt](https://github.com/pbs05/ponwrt) 的 MD040 单设备定制分支，目标是把 Nokia XG-040G-MD（Airoha AN7581，XG-PON）做成一台稳定的 **路由模式主路由器**：

- **WAN**：PON，本机 PPPoE（可带运营商 VLAN）
- **LAN**：2.5G 口 `lan1`
- **IPTV**：剩余 1G 口 `lan2` / `lan3` / `lan4`，二层桥接给机顶盒
- **PPE 硬件加速**：只作用于 `lan1` ↔ `pon0` 的路由/NAT 流量
- **不包含 WiFi**（MD040 无无线）

> 这是个人维护分支，不是 PonWrt 官方发行版。刷机有风险，务必先备份原厂分区（BOSA / RI / flag / 校准数据）。

---

## 1. 硬件与接口定义

### 1.1 硬件

| 项目 | 规格 |
|---|---|
| SoC | Airoha AN7581（4× Cortex-A53 + NPU） |
| PON | XG-PON，`pon0` |
| 2.5G LAN | `lan1`，EN8811H PHY，native GDM |
| 1G LAN | `lan2` / `lan3` / `lan4`，DSA/交换口 |
| 无线 | 无 |
| 存储 | 256MB NAND（UBI） |
| 内存 | 512MB DDR4 |

### 1.2 接口角色

| 接口 | 硬件 | 角色 | 网络 | PPE |
|---|---|---|---|---|
| `pon0` | XG-PON | WAN 物理口 | `wan`（PPPoE over `pon0.<WAN_VLAN>`） | ✅ L3 路由/NAT |
| `lan1` | 2.5G EN8811H | LAN 主口 | `br-lan`，仅 `lan1` | ✅ L3 路由/NAT |
| `lan2` | 1G DSA | IPTV | `br-iptv` | ❌ 初始阶段走软件桥 |
| `lan3` | 1G DSA | IPTV | `br-iptv` | ❌ 初始阶段走软件桥 |
| `lan4` | 1G DSA | IPTV | `br-iptv` | ❌ 初始阶段走软件桥 |

### 1.3 拓扑

```text
                         XG-PON
                           |
                         pon0
                           |
                 +---------+---------+
                 |   AN7581 / PPE    |
                 +---------+---------+
                           |
          +----------------+----------------+
          |                                 |
      lan1 2.5G                       lan2 / lan3 / lan4 1G
      br-lan                          br-iptv
      Internet / LAN                  IPTV STB
```

---

## 2. 网络设计

### 2.1 WAN

- 协议：`pppoe`
- 设备：`pon0` 或 `pon0.<WAN_VLAN>`
- VLAN ID 由运营商决定，仓库不硬编码；示例中的 `41` 只是占位。
- IPv6 可选，默认不强制启用。

### 2.2 LAN

- `br-lan` **只包含 `lan1`**。
- `lan` 接口默认 `192.168.1.1/24`，开启 DHCP。
- 防火墙 zone `lan`，允许访问 `wan`。

### 2.3 IPTV

- `br-iptv` 包含 `lan2`、`lan3`、`lan4`，以及运营商的 IPTV VLAN 子接口（例如 `pon0.43`、`pon0.3990`）。
- `iptv` 接口使用 `proto none`，不做 NAT，不做路由；机顶盒通过二层桥获取运营商地址。
- 建议开启 `igmp_snooping`，避免组播泛洪到所有 IPTV 口。
- 初始阶段 **不把 IPTV 桥加入 PPE flowtable**，避免与主路由的 `lan1 + pon0` 路由流冲突。
- `lan2-4` 不是原生 GDM 口，而是 `gdm1` 后面的 `en7581-switch` 用户口；PPE 的组播端口掩码在 EN7581 上只有低 4 位是明确 LAN 映射，不能直接表达这三个 switch 口。因此 IPTV 组播的硬件复制不是简单“加进 flowtable”就能解决。
- IPTV 码率通常较低，软件桥 + IGMP snooping 的 CPU 成本可控；优先稳定性。
- 如果后续确实要尝试桥接卸载，走 **native L2B / switch 组播** 的独立实验分支，不放进主分支的 `ppeflow`。详见 `docs/iptv-ppe-evaluation.md`。

### 2.4 为什么不把 `br-lan` 直接放进 PPE flowtable

`br-lan` 是 bridge master，没有 `airoha_eth` 的 `ndo_setup_tc`；把 flowtable 挂在 `br-lan` 上不会触发 PPE 初始化。

本仓库的做法和验证过的方式一致：

```text
flowtable inet ppe {
    hook ingress priority 0
    devices = { lan1, pon0 }
    flags offload
}
```

- LAN 侧必须解析到物理 `lan1`，不是 `br-lan`
- WAN 侧必须解析到物理 `pon0`，不是 `pon0.41` / `pppoe-wan`
- `ppeflow` 服务负责在开机后建立这张 flowtable

---

## 3. UCI 配置示例

以下为结构示例，VLAN 请按当地运营商替换。

```uci
config interface 'wan'
    option proto 'pppoe'
    option device 'pon0.41'
    option username 'your-account'
    option password 'your-password'
    option ipv6 '0'

config device
    option name 'br-lan'
    option type 'bridge'
    list ports 'lan1'

config interface 'lan'
    option device 'br-lan'
    option proto 'static'
    option ipaddr '192.168.1.1'
    option netmask '255.255.255.0'

config device
    option name 'br-iptv'
    option type 'bridge'
    option igmp_snooping '1'
    list ports 'lan2'
    list ports 'lan3'
    list ports 'lan4'
    list ports 'pon0.43'
    list ports 'pon0.3990'

config interface 'iptv'
    option device 'br-iptv'
    option proto 'none'
```

防火墙建议：

- `wan` zone：`masq=1`、`input=REJECT`、`forward=REJECT`
- `lan` zone：`input=ACCEPT`、`output=ACCEPT`、`forward=ACCEPT`
- `iptv` zone：如果 IPTV 是纯二层桥，可不建 zone；如果机顶盒需要 DHCP/路由，再单独建 zone，不要和 `lan` 混在一起

---

## 4. PPE 加速设计

### 4.1 目标

只加速：

- `lan1` → `pon0` 的上行 NAT
- `pon0` → `lan1` 的下行 NAT
- 以及对应的 IPv4/IPv6 路由流

不加速：

- IPTV `br-iptv` 的二层/组播流量（初始阶段）
- DSA `lan2-4` 的 L3 流（当前 PPE 对 DSA 出口支持不完整）

### 4.2 `ppeflow`

`target/linux/airoha/an7581/base-files/etc/init.d/ppeflow` 会在开机后：

1. 读取 `network.wan.device`，去掉 VLAN 后缀，得到物理 `pon0`
2. 读取 `network.lan.device`；如果是 `br-lan`，取 bridge 的第一个 port（`lan1`）
3. 创建 `inet ppe` flowtable，设备为 `{ lan1, pon0 }`
4. 在 forward 链添加 `flow add @ft`

注意：

- 该服务只负责 **路由/NAT** 的 flowtable
- IPTV 桥不加入
- 创建第二张 flowtable 是过渡方案；长期可改为修改 fw4 生成的设备列表，或驱动侧 `flow_indr`

### 4.3 运行时检查

```sh
cat /sys/kernel/debug/ppe/config
cat /sys/kernel/debug/ppe/bind
cat /sys/kernel/debug/ppe/entries
nft list flowtables
conntrack -L -o extended 2>/dev/null | grep -c HW_OFFLOAD
```

期望：

- `npu_attached: 1`
- `ppe0_flow_cfg` / `ppe1_flow_cfg` 非 0
- `ppe/bind` 有表项
- `ppe/entries` 出现 `BND`
- CPU 软中断明显下降，吞吐接近线速

---

## 5. 构建

### 5.1 前置

- Linux（Fedora / Ubuntu 均可）
- `git`、`make`、`gcc`、`g++`、`ncurses-devel`、`perl`、`python3`、`swig` 等 OpenWrt 构建依赖
- 能访问 GitHub / OpenWrt 源（必要时设置代理）
- 建议至少 8 核、16GB 内存、50GB 磁盘

### 5.2 构建命令

```sh
./scripts/build-md040.sh
```

脚本会：

1. `cp configs/md040.config .config`
2. `make defconfig`
3. `scripts/feeds update -a && scripts/feeds install -a`
4. `make download`
5. `make -j$(nproc) world`

输出：

```text
bin/targets/airoha/an7581/
```

目标文件：

- `ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-squashfs-sysupgrade.itb`
- `ponwrt-airoha-an7581-nokia_xg-040g-md-ubi-initramfs-recovery.itb`

### 5.3 全量插件版（Argon）

参考 `include-H/XG-040G-MD` 的插件集，构建带 Argon 主题、MosDNS、dae、
Lucky、Airoha NPU 面板等插件的完整镜像：

```sh
./scripts/build-md040-full.sh
```

默认主题为 Argon；PPE/IPTV 拓扑不变，仍是 `lan1 + pon0` 走 PPE，
`lan2-4` 走 IPTV 软件桥。

插件清单、dae 的 `KERNEL_XDP_SOCKETS` 配置坑和
`luci-app-airoha-npu` 的说明见 `docs/full-build.md`；
NPU 面板的选型对比见 `docs/npu-app.md`。

### 5.4 代理

```sh
export https_proxy=http://192.168.1.253:7890
export http_proxy=http://192.168.1.253:7890
```

按自己的代理地址修改。

---

## 6. 仓库结构

```text
.
├── configs/
│   └── md040.config                         # 单设备 defconfig
├── docs/
│   ├── ppe-pon-research-2026-11-16.md       # issue/外部讨论/补丁研究汇总
│   ├── iptv-ppe-evaluation.md               # IPTV 桥接 PPE 评估
│   ├── implementation-2026-11-17.md         # 本轮 PPE/PON 实施记录
│   └── feeds.lock                           # 构建使用的 feed commit
├── patches/
│   └── feeds/pon_drivers/mbi-reset.patch    # xPON #49 MBI overrun reset
├── scripts/
│   ├── build-md040.sh                       # 构建
│   ├── build-md040-full.sh                  # 全量插件版（Argon/MosDNS/dae/Lucky/NPU）
│   ├── apply-feed-patches.sh                # 应用 feed 补丁
│   ├── collect-md040-status.sh              # 设备状态采集
│   ├── update-upstream.sh                   # rebase 上游
│   └── sync-feeds.sh                        # 更新/固定 feed
├── target/linux/airoha/
│   ├── an7581/base-files/
│   │   ├── etc/init.d/ppeflow               # PPE flowtable
│   │   └── etc/uci-defaults/99-md040-network# 默认 LAN/IPTV 划分
│   └── patches-6.18/                        # 本地内核补丁
├── feeds.conf.default                       # 固定 feed 版本
└── README.md                                # 本仓库唯一根 README
```

---

## 7. 维护策略

### 7.1 分支

- `master`：上游 `pbs05/ponwrt` 镜像，**不提交本地改动**
- `md040`：本仓库的定制分支，只放 MD040 相关配置、补丁、脚本、文档

### 7.2 上游跟随策略（PonWrt vs ImmortalWrt）

结论：**主上游跟 PonWrt，ImmortalWrt 只作为次级参考。**

- 调用链：OpenWrt → ImmortalWrt → PonWrt → md040。
- PonWrt 本身就在定期 merge ImmortalWrt（例如 2026-11-07 的 `Merge ImmortalWrt upstream`），跟随 PonWrt 等于间接跟随 ImmortalWrt，同时保留 Airoha target、PON feeds、MD040 设备支持。
- 直接以 ImmortalWrt 为 base 会丢失：`target/linux/airoha` 的 170+ 补丁、PON 数据通路、DTS/image、NPU firmware、`pon_drivers` / `pon_userspace`，需要自己全部维护。
- ImmortalWrt 只用于 cherry-pick PonWrt 尚未合入的通用修复；不要整树 merge。
- 基准优先用 PonWrt 的 snapshot tag（如 `snapshot-20261116`）或固定 commit，不要直接跟 master HEAD。
- 更新节奏：每月一次，或 PonWrt 发新 snapshot 时；紧急修复单独 cherry-pick。
- 如果 PonWrt 停更：再评估把 Airoha/PON 补丁整体迁移到 ImmortalWrt，作为应急分支，不混入主分支。

### 7.3 上游同步

```sh
./scripts/update-upstream.sh
```

脚本会：

- 添加/更新 `upstream` remote
- `git fetch upstream master`
- `git rebase upstream/master`

注意：当前仓库是 shallow clone；首次 rebase 前可能需要：

```sh
git fetch --unshallow upstream
```

### 7.4 内核版本策略

- 跟随 OpenWrt/PonWrt 的 `KERNEL_PATCHVER := 6.18`
- 只跟 `6.18.y` stable 小版本
- 不直接跳 mainline 6.19/7.x；内核大版本升级需要重做 `target/linux/airoha` 的大量补丁

### 7.5 Feed 固定

`feeds.conf.default` 中固定：

- `pon_drivers`：`openwrt-pon-drivers`
- `pon_userspace`：`openwrt-pon-userspace`

建议 pin 到具体 commit：

```text
src-git pon_drivers https://github.com/<you>/openwrt-pon-drivers.git^<commit>
src-git pon_userspace https://github.com/<you>/openwrt-pon-userspace.git^<commit>
```

### 7.5 补丁策略

- 内核改动：放 `target/linux/airoha/patches-6.18/9xx-md040-*.patch`
- Feed 改动：fork feed + 分支，或 `patches/feeds/pon_drivers/`
- 不直接改 `build_dir` 里的内核源码；所有改动必须能通过 patch 复现

---

## 8. 路线图

### P0：先稳定 PPPoE / PPE

- [x] 接入 OpenWrt `925`：`RX_NO_CPU_DSCP` 中断处理
  - `target/linux/airoha/patches-6.18/925-net-airoha-handle-rx-no-cpu-dscp-irq.patch`
- [x] 接入 OpenWrt `926`：RX ring hw stall 恢复
  - `target/linux/airoha/patches-6.18/926-net-airoha-recover-rx-ring-hw-stall.patch`
- [x] 保留 `182`：ring 4 扩容
- [x] `ppeflow` 使用物理 `lan1 + pon0`
- [ ] 验证 `npu_attached=1` / `ppe/bind` / PPPoE 稳定性（需上机）

### P1：PPE 完整卸载

- [x] 用 `9999-14` 替代简单 `991`（flow stats 安全回退）
  - `target/linux/airoha/patches-6.18/991-md040-ppe-flow-stats-safe.patch`
- [ ] 接入 `9996`：PPPoE 上传流 egress → PON GDM + GEM/T-CONT
- [x] 接入 `920-17`（适配为 `992-md040-pppoe-mtu.patch`）：PPPoE 8 字节 MTU
- [x] 接入 `993-md040-ipv6-pppoe-flow-offload.patch`：IPv6 PPPoE fallthrough / PPPoE ID / NPU stats 修复（源自 wuziwei 931）
- [ ] 可选 `9995`：PON/QinQ/组播/aging/flow stats

### P1：光口稳定性

- [x] 接入 #49 `mbi-reset.patch`（overrun 风暴 → MAC epoch reset）
  - `patches/feeds/pon_drivers/mbi-reset.patch`
  - 由 `scripts/apply-feed-patches.sh` 在 feeds install 后应用
- [ ] 评估 `gponDevMpiStopNoRxDone` 变体，缩短恢复时间
- [ ] 可选：移植 RX stall watchdog（保留 30s 截止时间）
- [ ] 可选：用户态 `pon-link-watchdog` 兜底

### P2：IPTV / 可观测性

- [ ] IPTV 桥接稳定性、IGMP snooping
- [ ] 独立分支评估 native L2B / switch 组播卸载（参考 `docs/iptv-ppe-evaluation.md`）
- [ ] `tc-full`、QDMA/NPU debugfs、PPE drop reason 统计
- [ ] CI 构建与 release 产物

---

## 9. 验收清单

### 9.1 网络

```sh
ip -br link
ip -br addr
nft list ruleset
```

- `br-lan` 只有 `lan1`
- `br-iptv` 有 `lan2 lan3 lan4` + IPTV VLAN
- `wan` 为 PPPoE，`pppoe-wan` 有地址
- IPTV 机顶盒能获取地址/播放组播

### 9.2 PPE

```sh
cat /sys/kernel/debug/ppe/config
cat /sys/kernel/debug/ppe/bind
nft list flowtables
conntrack -L -o extended 2>/dev/null | grep -c HW_OFFLOAD
```

- `npu_attached: 1`
- `ppe/bind` 非空
- `HW_OFFLOAD` 计数增长
- 2.5G → PON 吞吐/CPU 对比正常

### 9.3 PON

```sh
ponctl --device pon0 status --json
cat /sys/kernel/debug/airoha-xpon-pon0/line
cat /sys/kernel/debug/airoha-xpon-pon0/mac
dmesg | grep -E 'XG-PON MAC error|MBI|MAC epoch reset'
```

- `onu_state: O5`
- `service_ready: true`
- 无持续 `int=0x8000 fifo=0x180`
- 断网后能自动恢复

---

## 10. 参考资料

- 研究汇总：`docs/ppe-pon-research-2026-11-16.md`
- PonWrt 上游：https://github.com/pbs05/ponwrt
- ImmortalWrt 上游：https://github.com/immortalwrt/immortalwrt
- PON 驱动：https://github.com/pbs05/openwrt-pon-drivers
- PON 用户态：https://github.com/pbs05/openwrt-pon-userspace
- OpenWrt #24715（RX ring / NO_CPU_DSCP）：https://github.com/openwrt/openwrt/issues/24715
- OpenWrt #24872（ring 4 扩容）：https://github.com/openwrt/openwrt/pull/24872
- naoki66 PPE/PPPoE 文档：https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/tree/master/docs
- LKML flow stats 讨论：https://lists.infradead.org/pipermail/linux-arm-kernel/2026-October/1185762.html

---

## 11. 免责声明

本项目仅用于个人设备研究与维护。刷机、修改 PON 配置、使用非官方固件可能导致设备变砖、无法注册、业务中断或违反运营商条款。请自行备份原厂分区和身份/校准数据，并自行承担风险。

厂商 SDK（EcoNet/Airoha）为专有源码，本仓库不包含、不分发；仅以公开的 Linux/OpenWrt/PonWrt 代码为基础。
