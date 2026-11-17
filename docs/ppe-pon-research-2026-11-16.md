# AN7581 / XG-040G-MD：PPE 加速与光口断网研究汇总

日期：2026-11-16
适用对象：PonWrt / AN7581 / Nokia XG-040G-MD（原 md040 分支；该分支工作区已归档）
目的：把 issue 调研、外部讨论、现有代码审查和补丁清单固化下来，后续对话直接引用本文件，不再重复铺上下文。

> 2026-11-16：本文档已从 deepseek-harness 工作区移动到当前工作区 `/home/hao/ponwrt`；
> 第 1 节描述的是原 md040 分支快照，补丁清单和结论仍然适用。

---

## 0. TL;DR

1. **当前 md040 分支还不是“已修好”的固件**。真正进构建的只有 `ppeflow` 脚本；内核补丁、PON 补丁都还没应用。
2. **PPE 侧**：
   - 只打了 ring 4 扩容（`182`），缺 OpenWrt #24715 的 `925`（NO_CPU_DSCP 中断）和 `926`（RX ring hw stall 恢复）。
   - `ppeflow` 默认取 `network.lan.device=br-lan`、`network.wan.device=pon0`，LAN 侧不是物理 `lan1`，大概率触发不了 `airoha_eth` 的 `ndo_setup_tc`。
   - `991`（NPU stats 失败后继续）是早期简单版，上游 review 已指出 `npu->stats == NULL` 的 MMIO 风险；应改用 naoki66 的 `9999-14`。
   - PPPoE 上传流已有现成实现：naoki66 的 `9996`，不是必须自己从零写。
3. **光口侧**：
   - `int=0x8000 fifo=0x180` 这个具体日志，naoki66 在 2026-11-08 有专门分析：根因是 RX stall watchdog 被持续 overrun IRQ 重置计时，30 秒恢复永远不到期；修复在私有 feed，公开 pbs05 驱动里没有 `rx_stall` 这套代码。
   - OpenWrt #24715 的 `925/926` 是另一条“PPPoE 断网”根因（控制包 ring 4 / NO_CPU_DSCP），已在 AN7581（XG-040G-MD）上实测。
   - 原厂 `xpon_10g.ko` 的 `gpon_err_int_reset`/`gpon_err_reset` 说明“overrun 计数 + MAC reset”方向正确；`gponDevMpiStopNoRxDone` 可省掉等 `MBI_RX_STOP_DONE` 的时间。
4. **优先级**：
   - P0：补 `925` + `926`（保留 `182`），先解决 PPPoE/控制包断网。
   - P0：修正 `ppeflow` 设备解析，或改用 fw4/物理口 flowtable。
   - P1：用 `9999-14` 替代 `991`；需要路由模式 PPPoE 卸载时加 `9996`；加 `920-17` 修 PPPoE MTU。
   - P1：PON 先上 #49 的 overrun→MAC reset 补丁（或移植 naoki66 RX stall watchdog），再加用户态 watchdog 兜底。
   - P2：`931` 不要原样应用（有 `REG_WAN_MTU0` + `WAN_MTU1_MASK` 已知缺陷）。

---

## 1. 当前工作区实际状态

原 md040 工作区（已归档）：`/home/hao/文档/deepseek-harness/default-workspace/ponwrt`
当前工作区：`/home/hao/ponwrt`

### 1.1 分支与提交

- 分支：`md040`，上游 `master` 保持干净。
- 关键提交：
  - `001ddd0`：单设备 fork、build/sync 脚本、`ppeflow` workaround、导入的 WIP 补丁
  - `1a1bd07`：`HANDOFF.md`
  - `ce5f5b3` / `7b7f020` / `62d9a38` / `2763a4c`：rootless 构建相关
- 构建内核：`build_dir/target-aarch64_cortex-a53_musl/linux-airoha_an7581/linux-6.18.60`

### 1.2 已进构建的内容

| 文件 | 状态 | 说明 |
|---|---|---|
| `configs/md040.config` | 已提交 | 只选 `nokia_xg-040g-md-ubi`；`kmod-airoha-xpon=y`、`airoha-en7581-npu-firmware=y`、`kmod-phy-airoha-en8811h=m` |
| `files/etc/init.d/ppeflow` | **未提交、被 `.gitignore` 忽略** | 本地构建会复制进镜像；干净 clone 没有这个文件 |
| `target/linux/airoha/patches-6.18/182-*` | 已有 | ring 4 扩到 128、fallback 16→32；这是 OpenWrt #24872 已合并的部分 |
| `custom/pon-drivers/mbi-reset.patch` | 未应用 | 需要应用到 `feeds/pon_drivers`，不是 `target/linux/` |
| `custom/patches-wip/931-*` | 未应用 | 有已知缺陷，见 4.4 |
| `ont/patchwork/991-*` | 未应用 | 早期简单版 flow stats 补丁，不安全 |

### 1.3 构建/网络默认值

- `configs/md040.config` 里 `CONFIG_PACKAGE_kmod-nf-flow=y`、`kmod-nft-offload=y`、`kmod-nf-conntrack-bridge=y`，这些没问题。
- `CONFIG_PACKAGE_tc-full` 没有选；nft flowtable 本身不需要 `tc` 二进制，但手工 `tc filter show` 调试需要 `tc-full`。
- 默认生成的网络配置：
  - `network.lan.device = br-lan`（由 `config_generate` 根据 ports 生成）
  - `network.wan.device = pon0`（Nokia XG-040G-MD 的 board.d 默认）
  - 如果用户把 WAN 改成 PPPoE over `pon0.41`，`network.wan.device` 会是 `pon0.41`。
- `target/linux/airoha/an7581/config-6.18`：`# CONFIG_NET_AIROHA_FLOW_STATS is not set`。
- 构建脚本 `scripts/build-md040.sh` 只做 `cp config → make defconfig → download → world`，没有 `scripts/feeds update/install`；干净 clone 直接跑会缺 feed。

---

## 2. Issue 收集（PonWrt 仓库）

### 2.1 PPE / 硬件加速

| Issue | 状态 | 设备 | 结论 |
|---|---|---|---|
| [#41](https://github.com/pbs05/ponwrt/issues/41) | open | XG2010G（AN7581 桥接） | PON RX ~1.17Gbps，PPE/L2B 不接管。两个已定位点：PON RX 队列 21..30 只有 32 描述符（调到 1024 约 +7%）；NPU 拒绝 flow stats 时 setup 中止。剩余：flow 建立但没下发硬件 |
| [#41 评论](https://github.com/pbs05/ponwrt/issues/41#issuecomment-3563709443) | — | ZN504XG-D / XG-040G-MD | 路由 + 本机 PPPoE：`pppoe-wan` 不是 GDM，FOE 校验失败；VLAN/PPP/DSA 设备不把 `ndo_setup_tc` 传给 `airoha_eth`。include-H 实测物理口 `lan1 + pon0`：`npu_attached=1`、`ppe/bind=51`、CPU 50%→3%、1178Mbps；DSA lan2-4 不行 |
| [#37](https://github.com/pbs05/ponwrt/issues/37) | open | XG-040G-MD | flow offload 把创建方向的 DSCP 复制到双向；PR #38 关闭未合并 |
| [#16](https://github.com/pbs05/ponwrt/issues/16) | closed | HG5585F-CU | MT7916 + 开源 mt76 不支持 WiFi offload |
| [#63](https://github.com/pbs05/ponwrt/issues/63) | open | XG-040G-MD | AN7581 16K SRAM 门限未初始化；原厂 `qdma_dev_7581.h` 确认 LAN `0x3ff0/0x3f00`、WAN `0x3999/0x2e00`；PR #64 未合并 |
| [#71](https://github.com/pbs05/ponwrt/issues/71) | open | AN7581 | NPU 固件版本/IPv6 PPE 调试输出可观测性 |
| [#23](https://github.com/pbs05/ponwrt/issues/23) | open | pon0 加入 br-lan | 桥接后高负载 CPU 仍高；本质是桥流量没走 PPE |
| [#104](https://github.com/pbs05/ponwrt/issues/104) | open | HG5585F | 6.18.55 WireGuard/WiFi NAT 性能回归，怀疑 CPU 调度；非 PPE 直接问题 |

### 2.2 光口断网 / 注册不稳

| Issue | 状态 | 设备 | 结论 |
|---|---|---|---|
| [#49](https://github.com/pbs05/ponwrt/issues/49) | open | XG-040G-MD、ZN504XG-D | 36–46h 后 `int=0x8000 fifo=0x180`，下行死、PPPoE 掉、永不恢复；`MBI_RX_STOP_DONE` 不置位。补丁：overrun 计数 32 次/60s 触发 MAC epoch reset，463s+手动 → 17.6s 自动 |
| [#50](https://github.com/pbs05/ponwrt/issues/50) | open | XG-040G-MD | 大流量下载后 `XG-PON MAC error int=0x8000 fifo=0x180`，PPPoE 断；关硬件加速不复现但吞吐降到 600–800Mbps。评论提到华为 OLT 下兼容性改 0x86 可数天不复现 |
| [#112](https://github.com/pbs05/ponwrt/issues/112) | open | XG-040G-MF（an7583） | O5 后每 1–3h 被 OLT Deactivate（PLOAM 0x05）；当前驱动 plain MAC reset 只能重注册 |
| [#42](https://github.com/pbs05/ponwrt/issues/42) | closed | 10G-EPON（ZN504XG-D） | 冷启动 1Hz MPCP timeout 循环，`interrupt_status=0x8000`；GRO 已修 IPTV；当前驱动有 EPON burst path 恢复（a24ef29） |
| [#28](https://github.com/pbs05/ponwrt/issues/28) | open | 重庆/成都/上海移动 XG-PON | O2_3→O4→O5 循环，OLT 主动 Deactivate；怀疑 r68 上行 profile/BWmap/ACK；参考 odi-oss #29 |
| [#12](https://github.com/pbs05/ponwrt/issues/12) | closed | XG-040G-MD | 编译没选 pon-driver + en8811h firmware；全选后正常 |
| [#40](https://github.com/pbs05/ponwrt/issues/40) | closed | XG-040G-MF | 浙江移动注册问题，无日志 |
| [#22](https://github.com/pbs05/ponwrt/issues/22) | closed | GPON 线路 | 不支持 GPON 波长，需要 GPON 版 758x 设备 |

---

## 3. 外部讨论与现成实现

### 3.1 naoki66/ImmortalWrt-for-Gemtek-brightspeed（最重要）

仓库：https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed

文档：

- `docs/airoha-ppe-pppoe-bridge-offload.md`：AN7581/AN7583 桥接网口下游 PPPoE 的 PPE 加速四层条件、FOE 中 PPPoE 字段、MTU 陷阱、验收清单。
- `docs/airoha-bridge-flowtable-offload.md`：桥接 flowtable/native L2B 的关系。
- `docs/airoha-bridge-pppoe-offload-verification.md`：六项逐条核实；关键结论是“代码已具备，真正缺的是内核 CONFIG（BRIDGE_NETFILTER / NF_CONNTRACK_BRIDGE / NF_FLOW_TABLE / NFT_FLOW_OFFLOAD）和 userspace 锚点”。
- `docs/pon-rx-stall-recovery-20261108.md`：`int=0x8000 fifo=0x180` 的 RX stall 分析，见 3.2。

补丁（`target/linux/airoha/patches-6.18/`）：

| 补丁 | 作用 | 与当前 fork 的关系 |
|---|---|---|
| `9990-net-airoha-bind-WLAN-bound-flows-on-PPE-driver-L2-cache-miss.patch` | PPE L2 cache miss 时用 bridge FDB 兜底绑定 WLAN/GDM | WiFi 桥接相关；MD040 无 WiFi，可不动 |
| `9993-net-airoha-pass-ingress-vlan-to-bridge-path.patch` | 桥接路径传递 ingress VLAN 上下文 | 桥接/VLAN 场景 |
| `9994-net-airoha-fix-native-l2b-entry-layout.patch` | native L2B 入口布局 | 和树里的 `930` 同类，二选一 |
| `9995-net-airoha-complete-ppe-offload.patch` | PON/QinQ/组播/aging 补全；打开 flow stats | 可作为 PPE 综合补丁参考 |
| `9996-net-airoha-pppoe-uplink-offload-and-debugfs.patch` | **路由模式 PPPoE 上传流卸载**：识别 `ARPHRD_PPP` egress，按外层 VLAN/P-bit 找 PON GEM/T-CONT 映射，换成真正 PON GDM；QDMA/NPU debugfs | **gate 3 的现成实现**，优先参考 |
| `9999-14-net-airoha-ppe-tolerate-unsupported-flow-stats.patch` | flow stats 失败后安全继续：检查 `npu->stats`，跳过 stats reset/readout 和 PSE port 6 重定向 | **替代 991**，避免 NULL MMIO / PSE 队列堵死 |
| `9999-15-net-airoha-report-unsupported-ppe-flow-stats.patch` | 调试输出区分“不支持”与“0 计数” | 可观测性 |
| `920-17-net-airoha-account-for-PPPoE-session-header-in-PPE-MTU.patch` | PPE/WAN MTU 加 PPPoE 8 字节 | 修“小包通、大包不通” |

### 3.2 PON RX stall（naoki66，2026-11-08）

文档：https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/blob/master/docs/pon-rx-stall-recovery-20261108.md

- 日志：`int=0x8000 fifo=0x180`，随后 PPP LCP 心跳失联、PPPoE PADO 超时；ONU 仍在 O5，重载 xPON 后恢复。
- 根因：驱动 `airoha_xpon_xgpon_rx_stall()` 每次消费 `rx_stall_pending` 都清空采样状态并把 `rx_stall_since` 更新为当前时间；持续 MBI overrun IRQ 不断重启 30 秒计时，内核恢复永远不到期。
- 修复：已 armed 的 watchdog 保留采样基线和截止时间；首次读到有效 datapath 统计后开始计时；30 秒无 RX 进展触发 MAC epoch reset。
- 用户态兜底：`files/usr/sbin/pon-link-watchdog`，PPPoE 持续 down 180s 后 reload PON MAC，3 次/30 分钟退避；桥接模式不触发。
- **注意**：该修复在 naoki66 的私有 feed 里；pbs05 公开驱动（截至 2026-11-16 的 47ad313）没有 `rx_stall` 这套代码，不能直接 patch，只能按思路移植或等上游。

### 3.3 OpenWrt #24715 / PR #24872（RX ring 控制包黑洞）

- Issue：https://github.com/openwrt/openwrt/issues/24715
- PR：#24872 已合并（ring 4 扩容，即树里的 `182`）
- Vitaliy Sochniy 定位到两个 `airoha_eth` RX bug：
  1. `RX_NO_CPU_DSCP` 中断被 unmask 但 handler 只处理 `RX_DONE`；ring 排空后 NAPI 不再调度，ring 永远不补充。
  2. ring 4 的硬件完成竞争：硬件写到软件未 post 的 descriptor，顺序消费端永远等不到。
- 三个补丁：
  - `925-net-airoha-handle-rx-no-cpu-dscp-irq.patch`
  - `926-net-airoha-recover-rx-ring-hw-stall.patch`
  - ring 4 扩到 128（已合并为 `182`）
- 测试：Vitaliy 在 AN7581（XG-040G-MD）上跑过 570 次 PPPoE 强制重连；csharper2005 在 MF 上确认稳定；dellemcryan 也确认修复。
- **当前 fork 只有 `182`，缺 `925`/`926`。** 这两个补丁不是完整 PON MAC 修复，但能解决控制包 ring 4 黑洞导致的 PPPoE 断网/DHCP 拿不到地址。

### 3.4 LKML：flow stats 补丁与 review

- v1 review（Sashiko）指出简单“warn 后继续”会导致 `npu->stats == NULL` 时 MMIO，High severity；还指出 PSE port 6 共享缓冲问题：
  https://lists.infradead.org/pipermail/linux-arm-kernel/2026-October/1185762.html
- v3：
  https://lists.infradead.org/pipermail/linux-arm-kernel/2026-October/1187016.html
- 结论：`ont/patchwork/991-*` 是最早的简单版，不应作为最终补丁；用 `9999-14`（带 `npu->stats` 检查 + 跳过 PSE port 6 重定向）或上游 v3 + 额外保护。

### 3.5 其他 OpenWrt issue

- **#25820**：IPv6 PPE 卸载后 UPDMEM egress 源 MAC 不同步，IPv6 TCP 会中途卡死；IPv4 正常。https://github.com/openwrt/openwrt/issues/25820
- **#24038 / #22533**：bridge flowtable / L2 桥卸载；桥接模式相关。https://github.com/openwrt/openwrt/issues/24038
- **#24687**：PPE 突发拥塞、QDMA shaping；提到 AN7581 的 per-port shaper / `npu-jitter`；和 #63 的性能/丢包相关。https://github.com/openwrt/openwrt/issues/24687
- **#20104**：Airoha 设备/xPON 支持总 issue；主要是早期 EN7523 内容，PPE 细节不多。

### 3.6 论坛

- OpenWrt 论坛 xPON 适配帖：基本 xPON 已工作，PPE/offload 被明确说成后续增量项。
  https://forum.openwrt.org/t/is-it-feasible-to-adapt-the-airoha-xpon-driver-for-pon-mac-support-on-the-nokia-xg-040g-md/252382
- 恩山 XG-040G-MF PPPoE 拨号失败帖（指向 #24715）：
  https://www.right.com.cn/forum/thread-8487282-1-1.html

---

## 4. 现有代码审查（md040 分支）

### 4.1 `files/etc/init.d/ppeflow`

现状：

```sh
wan=$(uci -q get network.wan.device)
lan=$(uci -q get network.lan.device)
[ -n "$wan" ] || wan="pon0"
[ -n "$lan" ] || lan="lan1"
nft list table inet ppe >/dev/null 2>&1 && return 0
nft add table inet ppe
nft add flowtable inet ppe ft { hook ingress priority 0; devices = { $lan, $wan }; flags offload; }
nft add chain inet ppe c { type filter hook forward priority 10; policy accept; }
nft add rule inet ppe c meta l4proto { tcp, udp } flow add @ft
```

问题：

1. **LAN 取错设备**：默认 `network.lan.device=br-lan`，不是物理 `lan1`。`br-lan` 没有 `ndo_setup_tc`；forward path 的最终 `indev` 是 `lan1`，但 flowtable hook 列表里是 `br-lan`，`nft_flowtable_find_dev()` 不匹配，flow 不会卸载。issue #41 的验证用的是 `{ lan1, pon0 }`。
2. **WAN 取错设备（VLAN 场景）**：如果 PPPoE over `pon0.41`，`network.wan.device=pon0.41`，脚本会把 VLAN 设备放进 flowtable；`airoha_eth` 的 `ndo_setup_tc` 不会被调用。需要还原成物理 `pon0`。
3. **未提交**：`.gitignore` 第 16 行是 `/files`，`git ls-files` 里没有 `ppeflow`；干净 clone/推送分支会丢失。建议放到 `target/linux/airoha/base-files/etc/init.d/ppeflow`（会被 target base-files 打包），或 `git add -f` 并明确说明。
4. **早退不刷新**：`nft list table inet ppe` 成功就 return，设备变化/上次建错时不会重建。
5. **和第二张 flowtable 的关系**：如果 fw4 自己的 flowtable 也在工作，两个表可能重复卸载；更干净的做法是改 fw4 的 flowtable 设备列表，或使用 naoki66 的 bridge flowtable/fw4 方案。

建议的修正方向：

```sh
# WAN：VLAN 子接口还原到物理设备
wan=$(uci -q get network.wan.device)
[ -n "$wan" ] || wan="pon0"
wan=${wan%%.*}

# LAN：如果是 bridge，取 bridge 的第一个物理 port；MD040 上 lan1 是 2.5G native GDM
lan=$(uci -q get network.lan.device)
if [ -z "$lan" ] || [ "$lan" = "br-lan" ]; then
    lan=$(uci -q get network.@device[0].ports | awk '{print $1}')
fi
[ -n "$lan" ] || lan="lan1"
```

注意：MD040 的 lan2–lan4 是 DSA，当前 PPE 卸载不工作；只用 lan1。

### 4.2 Gate 1：PON RX ring

`HANDOFF.md` 说“上游已修”，不准确：

- 树里的 `182` 只做：
  - `RX_DSCP_NUM()` fallback 16 → 32
  - ring 4 → 128
- PON 的 RX 队列是 21..30，仍落到 fallback 32；issue #41 验证的“PON 队列 1024”并没有进树。
- 所以 gate 1 对 PON 收包上限仍未修；对 ring 4 控制包黑洞只修了“扩容”这一半，缺 `925`/`926`。

### 4.3 Gate 2：NPU stats 中止

- `target/linux/airoha/an7581/config-6.18` 仍是 `# CONFIG_NET_AIROHA_FLOW_STATS is not set`。
- 关闭时 `airoha_ppe_get_num_stats_entries()` 返回 `-EOPNOTSUPP`，`ppe_num_stats_entries > 0` 不成立，`ppe_init_stats()` 根本不会调用。
- 所以 MD040 默认配置下 `npu_attached=0` 更可能是 **gate 4：setup 根本没被调用**，不是 stats 中止。include-H 的物理口 workaround 也证明 setup 可以成功。
- 如果为了 flow counters 打开 `CONFIG_NET_AIROHA_FLOW_STATS`，必须同时用安全补丁（`9999-14`），否则可能 abort 或 NULL deref。
- `991` 补丁可以 `git apply`（有 offset），`eth->dev` 字段存在，编译没问题；但逻辑不如 `9999-14` 完整。

### 4.4 Gate 3：PPPoE egress

- 上游 `airoha_ppe.c` 已有 `FLOW_ACTION_PPPOE_PUSH`、`AIROHA_FOE_IB1_BIND_PPPOE`、`mac_info->pppoe_id`、`l2->etype = ETH_P_PPP_SES`。
- 缺的是：当 `odev` 是 `pppoe-wan`（`ARPHRD_PPP`）时，解引用到真正的 PON GDM，并把 PPPoE session id + PON GEM/T-CONT 元数据带进 FOE。
- `faadd2` 的评论说 MTK 的 `mtk_ppe_offload.c` 也不支持 pppoe-wan egress；naoki66 的 `9996` 已经实现了 Airoha 版本。
- `custom/patches-wip/931-*` 不是这个修复；它修的是 `airoha_ppe_foe_insert_entry()` 的 fallthrough、`src_mac_hi` 掩码、IPv6 stats 排除。README 已指出它有一个 `REG_WAN_MTU0` + `WAN_MTU1_MASK` 的缺陷：第二个 `airoha_fe_rmw()` 应使用 `REG_WAN_MTU1`，否则 MTU0 被破坏。不要原样应用。

### 4.5 Gate 4：flowtable 设备

- 根因不是驱动不会写 FOE，而是 `nf_flow_table_offload_setup()` 只在 flowtable 的设备上调用 `ndo_setup_tc`。
- 物理 `lan1` + `pon0` 能触发；`br-lan`、`pon0.41`、`pppoe-wan`、DSA 口不能。
- 两个方向：
  - 短期：修正 `ppeflow`，用物理设备；或改 fw4 生成的 flowtable 设备列表。
  - 长期：驱动侧 `flow_indr` 注册（naoki66 的方案/后续），替代脚本。
- 对路由模式 + 本机 PPPoE，flowtable 的 `devices` 里至少要有 `lan1` 和 `pon0`；`odev` 仍可能是 `pppoe-wan`，所以 `9996` 仍需配合。

### 4.6 PON #49 补丁

- `custom/pon-drivers/mbi-reset.patch` 是 issue #49 的附件，未应用。
- 路径相对 `airoha-xpon/src`，在 feed 根目录直接 `git am` 会失败；用：
  ```sh
  cd feeds/pon_drivers
  git apply --check --directory=airoha-xpon/src /path/to/mbi-reset.patch
  git apply --directory=airoha-xpon/src /path/to/mbi-reset.patch
  ```
- 内容：overrun 计数达到 32 次、且距上次 reset ≥60s，置 `mbi_reset_pending`，由 `link_work` 调 `airoha_xpon_xgpon_restart_mac()`。
- 阈值与厂商不同：厂商 `maxRxMBIFifoErrCnt` 默认 10；issue 补丁用 32。需要真机调。
- `airoha_xpon_xgpon_restart_mac()` 里 `stop_mac_interfaces()` 会等 3ms（不是 issue 时间线的 2.7s）超时；厂商 `gpon_err_reset()` 用 `gponDevMpiStopNoRxDone()` 跳过等 `MBI_RX_STOP_DONE`，可以进一步缩短恢复时间。

### 4.7 PON 厂商行为（SDK/二进制对照）

- 原厂固件：Nokia XG-040G-MD（AN7581，XG-PON），内核 5.4.55；rootfs 带 `xpon.ko`/`xpon_10g.ko`/`hw_nat.ko`/`qdma_*.ko`。
- `maxRxMBIFifoErrCnt` 默认 10（`.data` 0x90 = 0x0a）。
- `gpon_err_int_reset()` 计数，超阈值调 `gpon_err_reset()`；后者序列：
  `gpon_disable()` → `gponDevMbiStop()` → `gponDevMpiStopNoRxDone()` → `gponDevMacReset()` → re-init，随后 `gponDevMbiStop(1)`、`gponDevMpiStop(1)`。
- `ploam_recv_deactivate_onu()` 对 EN7581/AN7583 使用 `GPON_MAC_PLAIN_RESET`（保留 PHY），与当前开源驱动一致；#112 不是复位方式差异。
- 原厂 `qdma_dev_7581.h` 有 issue #63 的 SRAM 门限，确认当前驱动漏初始化。
- 原厂 `hw_nat` 支持 PPPoE/VLAN：`GetPppoeSid()`、FOE 7581 `psn`/`pppoe_id` 字段。
- SDK 源码（`lotusmomo/airoha_sdk`、`AKoo7/openwrt-econet-gpon`）是 EcoNet 专有，只能当参考，不要拷进 GPL 工程。

---

## 5. 建议的补丁清单与优先级

### P0：先让 PPPoE/控制包稳定

1. **`925-net-airoha-handle-rx-no-cpu-dscp-irq.patch`**
   - 来源：Vitaliy Sochniy，OpenWrt #24715 的修复候选；文件在 commit `5b7a70d226fc1b1957be8b322f56d0d4634178d8`。
   - 作用：`airoha_irq_handler()` 把 `NO_CPU_DSCP` 当 `RX_DONE` 一样调度 NAPI，并在 NAPI complete 时重新使能。
   - 这是 ring 4 排空后不恢复的核心修复。
2. **`926-net-airoha-recover-rx-ring-hw-stall.patch`**
   - 来源：Vitaliy Sochniy，commit `7f37ab604dc34778d2d3a151f1f4fdc7ddf5c237`。
   - 作用：用 `REG_RX_DMA_IDX` 对比 `tail` 检测硬件完成竞争，work item 里 disable RX DMA → cleanup/fill ring → re-enable。
   - 注意：会短暂停整个 QDMA 的 RX（最长 50ms），可能丢无关 ring 的包。
3. 保留现有 `182`（ring 4 = 128）。
4. 修正 `ppeflow`：LAN 取 `lan1`，WAN 去 VLAN 后缀取 `pon0`；或改用 fw4 设备列表。
5. 上机验证：`npu_attached`、`ppe/bind`、PPPoE 重连稳定性、`dmesg` 无 `XG-PON MAC error`。

### P1：PPE 真正卸载

1. **`9999-14`**：替换 `991`，安全处理 flow stats 失败；如打开 `CONFIG_NET_AIROHA_FLOW_STATS` 必须用。
2. **`9996`**：路由模式 PPPoE 上传流卸载（ppp egress → PON GDM + GEM/T-CONT）。如果物理口 flowtable 已能让 `ppe/bind` 起来、且 PPPoE 流能绑定，可以先观察；若 `pppoe-wan` 仍被拒，必须上。
3. **`920-17`**：PPPoE 8 字节 MTU，修大包不通。
4. 可选 `9995`：PON/QinQ/组播/aging/flow stats 综合补丁。
5. 可选 `9999-15`：调试输出区分 stats 不可用。
6. 可选 `9990/9993/9994`：WiFi 桥接/VLAN/L2B，MD040 无 WiFi，按需。
7. 若只做桥接（下游拨号），参考 naoki66 的 bridge flowtable/config 文档，而不是 `9996`（本机 PPPoE 场景）。

### P1：光口 MBI overrun

1. 先上 **#49 `mbi-reset.patch`**（`--directory=airoha-xpon/src`），观察 32 次/60s 阈值是否合适。
2. 加 **NoRxDone 变体**：在 `stop_mac_interfaces()` 里跳过等 `MBI_RX_STOP_DONE`（或新增 `stop_mac_interfaces_no_rxdone()`），缩短恢复时间。
3. 如果能在 naoki66 的私有 feed 拿到 `rx_stall` 修复，优先移植其“保留 watchdog 截止时间”的逻辑；这比每次 overrun 都 reset 更精确。
4. 用户态兜底：`pon-link-watchdog`（PPPoE down 180s → reload PON MAC，3 次/30min 退避）；桥接模式跳过。
5. #112/#28 的 OLT Deactivate：当前 plain MAC reset 与原厂一致；要真正解决需要 OLT/OMCI/注册参数侧证据，单靠复位不够。

### P2：其他

- `931` 不要原样应用；先修 `REG_WAN_MTU1`。
- `#63` SRAM 门限、`#25820` IPv6 UPDMEM、`#24687` QDMA shaping 按需。
- 构建脚本补 `scripts/feeds update -a && scripts/feeds install -a`（或文档说明需先准备 feed）。
- `files/` 被忽略的问题：把 `ppeflow` 移到 `target/linux/airoha/base-files/`，或 force-add。

---

## 6. 上机验收清单

### 6.1 PPE

```sh
# 1. 内核是否支持 flowtable
zcat /proc/config.gz | grep -E 'NF_FLOW_TABLE|NFT_FLOW_OFFLOAD|NF_CONNTRACK_BRIDGE'

# 2. flowtable 设备是否是物理口
nft list flowtables
nft list flowtable inet fw4 2>/dev/null
nft list flowtable bridge fw4 2>/dev/null

# 3. PPE 是否 attach / 是否有 bind
cat /sys/kernel/debug/ppe/config
cat /sys/kernel/debug/ppe/bind
cat /sys/kernel/debug/ppe/entries | head

# 4. conntrack 是否 HW_OFFLOAD
conntrack -L -o extended 2>/dev/null | grep -c HW_OFFLOAD

# 5. 吞吐/CPU 对比；tc 调试需要 tc-full
tc -s filter show dev lan1 ingress
tc -s filter show dev pon0 ingress
```

期望：
- `npu_attached: 1`
- `ppe0_flow_cfg` / `ppe1_flow_cfg` 非 0
- `ppe/bind` 有行
- `ppe/entries` 出现 BND，PPPoE 场景能看到 `pppoe_id`
- CPU 软中断明显下降，吞吐接近线速

### 6.2 PON

```sh
# 1. 当前状态
ponctl --device pon0 status --json
cat /sys/kernel/debug/airoha-xpon-pon0/line
cat /sys/kernel/debug/airoha-xpon-pon0/mac
cat /sys/kernel/debug/airoha-xpon-pon0/registration
cat /sys/kernel/debug/airoha-xpon-pon0/datapath

# 2. 断网/恢复日志
dmesg | grep -E 'XG-PON MAC error|MBI|MAC epoch reset|rx stall|timed out stopping'
logread | grep -E 'XG-PON MAC error|MBI|pppoe|PADO'

# 3. 计数
ip -s link show pon0
ethtool -S pon0 2>/dev/null | head
```

期望：
- `service_ready: true`，`onu_state: O5`
- `mbi_header_overrun_irq` / `mbi_payload_overrun_irq` 不再持续增长
- 触发 overrun 后出现 `MAC epoch reset (MBI RX overrun storm)` 并自动恢复
- PPPoE 不再 PADO 超时；重连计数可观测

---

## 7. 风险与注意事项

1. `9995/9996/9999-14/920-17` 是基于 6.18.55 的补丁；当前树是 6.18.60，应用前先 `git apply --check` / `patch --dry-run`，可能有 offset。
2. `9996` 依赖 PON flow table 的 VLAN/P-bit → GEM/T-CONT 映射；没配置映射时会 `-EOPNOTSUPP`，这是预期。
3. `925/926` 是 OpenWrt 修复候选，不是完整上游合入；`926` 会暂时停整个 QDMA RX，可能丢无关 ring 的包，需实测。
4. `991` 不要直接上；至少要加 `npu->stats` 检查，最好用 `9999-14`。
5. `ppeflow` 是第二张 flowtable，和 fw4 自己的 flowtable 可能重复卸载；长期应改 fw4 设备列表或驱动 `flow_indr`。
6. `files/` 被 `.gitignore` 忽略；当前本地构建有 `ppeflow`，但分支/干净 clone 没有。
7. 厂商 SDK 是 EcoNet 专有源码，只能阅读，不能拷进 GPL 工程。
8. `npu_attached=0` 不能直接归因于 gate 2；先确认 `airoha_ppe_offload_setup()` 是否被调用（gate 4）。
9. `#112` 的 OLT Deactivate 是 OLT 主动行为；复位只能恢复，不能阻止再次被踢，需要注册参数/OMCI/OLT 侧证据。

---

## 8. 参考链接汇总

### PonWrt issue

- #41 https://github.com/pbs05/ponwrt/issues/41
- #37 https://github.com/pbs05/ponwrt/issues/37
- #49 https://github.com/pbs05/ponwrt/issues/49
- #50 https://github.com/pbs05/ponwrt/issues/50
- #63 https://github.com/pbs05/ponwrt/issues/63
- #112 https://github.com/pbs05/ponwrt/issues/112
- #42 https://github.com/pbs05/ponwrt/issues/42
- #28 https://github.com/pbs05/ponwrt/issues/28

### 外部实现/讨论

- naoki66 PPE/PPPoE 文档：
  https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/blob/master/docs/airoha-ppe-pppoe-bridge-offload.md
- naoki66 桥接 PPPoE 核实：
  https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/blob/master/docs/airoha-bridge-pppoe-offload-verification.md
- naoki66 PON RX stall：
  https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/blob/master/docs/pon-rx-stall-recovery-20261108.md
- naoki66 补丁目录：
  https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/tree/master/target/linux/airoha/patches-6.18
- OpenWrt #24715：
  https://github.com/openwrt/openwrt/issues/24715
- OpenWrt #24872（已合并 ring 补丁）：
  https://github.com/openwrt/openwrt/pull/24872
- OpenWrt #25820（IPv6 PPE UPDMEM）：
  https://github.com/openwrt/openwrt/issues/25820
- OpenWrt #24038（bridge flowtable）：
  https://github.com/openwrt/openwrt/issues/24038
- OpenWrt #22533（L2 bridge offload）：
  https://github.com/openwrt/openwrt/issues/22533
- OpenWrt #24687（PPE 拥塞/QDMA shaping）：
  https://github.com/openwrt/openwrt/issues/24687
- LKML flow stats v1 review：
  https://lists.infradead.org/pipermail/linux-arm-kernel/2026-October/1185762.html
- LKML flow stats v3：
  https://lists.infradead.org/pipermail/linux-arm-kernel/2026-October/1187016.html
- OpenWrt 论坛 xPON 适配：
  https://forum.openwrt.org/t/is-it-feasible-to-adapt-the-airoha-xpon-driver-for-pon-mac-support-on-the-nokia-xg-040g-md/252382
- 恩山 XG-040G-MF PPPoE：
  https://www.right.com.cn/forum/thread-8487282-1-1.html

### 本地材料

- 原厂固件：`/home/hao/ponwrt/壶关 光猫固件/`
- 厂商 SDK：`/tmp/opencode/airoha_sdk`（仅参考）
- econet-xpon 社区源码：`/tmp/opencode/openwrt-econet-gpon`
- pbs05 xpon 驱动：`/tmp/opencode/openwrt-pon-drivers`
- 已下载的 9995/9996/9999-14/920-17：`/tmp/opencode/`
- 本文件：`docs/ppe-pon-research-2026-11-16.md`

---

## 9. 待决定

1. MD040 的定位是**路由模式本机 PPPoE**，还是**桥接 + 下游拨号**？
   - 路由模式：优先 `9996` + `9999-14` + `920-17` + 物理口 flowtable。
   - 桥接模式：优先 naoki66 的 bridge flowtable / `9995` / `9990` / `9993` / `9994`，不要套 `9996`。
2. 是否接受 `925/926` 这类“修复候选”补丁进入 md040 分支（非上游正式合入）？
3. PON 侧先上 #49 的 storm reset，还是等/移植 naoki66 的 RX stall watchdog？
4. 是否把 `ppeflow` 从被忽略的 `files/` 移到 target base-files，或直接改 fw4 设备列表？
