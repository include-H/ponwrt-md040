# 恩山 8497992 / wuziwei 931 补丁评审

来源：
https://www.right.com.cn/forum/forum.php?mod=viewthread&tid=8497992

标题：`AN7581 Ponwrt-ZN504&HG5585F 增强整合版 11/15独家修复硬件流卸载`

仓库：
https://github.com/wuziwei/ponwrt-ZN504-HG5585F

补丁：
`target/linux/airoha/patches-6.18/931-net-airoha-fix-wan-ipv6-pppoe-flow-offload.patch`

## 1. 它说的问题成立吗

基本成立。对照当前 6.18.60 树：

- `airoha_ppe_foe_insert_entry()` 在软件 `foe_flow[]` 未命中后，确实会直接落到 `l2_lookup:`，没有检查包类型。非 bridge 的 L3 包可能被当成 L2 subflow 提交。
- `airoha_ppe_foe_commit_subflow_entry()` 对 IPv6 分支确实执行：
  ```c
  hwe.ipv6.l2.src_mac_hi = FIELD_PREP(AIROHA_FOE_MAC_SMAC_ID, 0xf);
  ```
  这会清掉低 16 位的 `AIROHA_FOE_MAC_PPPOE_ID`。
- `airoha_ppe_foe_flow_stats_update()` 在 stats 可用时会把流重定向到 PSE port 6（CDM3/NPU）；AN7581 的 IPv6 PPPoE 流在这个 NPU 统计路径上没有验证过的布局，确实可能卡住。
- 所以“fallthrough → L2 subflow → PPPoE ID 丢失 → NPU port 6 → 黑洞”的链路是可信的，和 issue #41 / #37 里看到的“flow 建了但没正确进 PPE/性能掉到几十 KB/s”能对上。

## 2. 一个被误传的点：REG_WAN_MTU0 / WAN_MTU1_MASK

旧的研究笔记里曾把 931 的这一段当成 bug：

```c
airoha_fe_rmw(dev->eth, REG_WAN_MTU0, WAN_MTU0_MASK,
              FIELD_PREP(WAN_MTU0_MASK, ...));
airoha_fe_rmw(dev->eth, REG_WAN_MTU0, WAN_MTU1_MASK,
              FIELD_PREP(WAN_MTU1_MASK, ...));
```

并说第二个应该用 `REG_WAN_MTU1`。**这个说法是错的。**

当前 `airoha_regs.h`：

```c
#define REG_WAN_MTU0    0x2300
#define WAN_MTU1_MASK   GENMASK(29, 16)
#define WAN_MTU0_MASK   GENMASK(13, 0)
```

`MTU0` 和 `MTU1` 是**同一个寄存器** `0x2300` 的两个字段，不存在 `REG_WAN_MTU1`。所以 931 的第二次 `airoha_fe_rmw(REG_WAN_MTU0, WAN_MTU1_MASK, ...)` 是正确的，不是 bug。

因此：
- 931 的 MTU 部分可以工作，但它用固定 `+16` 字节预算，比较粗。
- 本仓库的 `992-md040-pppoe-mtu.patch` 用 `PPPOE_SES_HLEN`（PON 设备才加）更精确，所以**没有采用 931 的 MTU hunk**，避免重复/过度放宽。

## 3. 931 的核心修复是否正确

| 修复 | 判断 |
|---|---|
| 非 bridge 包禁止 fallthrough 到 `l2_lookup` | ✅ 正确；`hwe` 在到达该点前已判空 |
| IPv6 subflow 保留 `AIROHA_FOE_MAC_PPPOE_ID` | ✅ 正确；只保留低 16 位，不破坏 SMAC_ID |
| AN7581 IPv6 route 跳过 NPU stats 更新 | ✅ 方向正确；`type >= PPE_PKT_TYPE_IPV6_ROUTE_3T` 覆盖 3T/5T/6RD |
| AN7581 IPv6 route 跳过 stats 读取 | ✅ 一致；避免 debugfs 走未验证的 NPU 计数布局 |
| MTU 固定 +16 | ⚠️ 可用但粗糙；本仓库用 992 替代 |

## 4. 本仓库实际采用的版本

没有原样应用 931，而是抽出三个核心修复作为：

`target/linux/airoha/patches-6.18/993-md040-ipv6-pppoe-flow-offload.patch`

包含：

1. `airoha_ppe_foe_insert_entry()`：非 `PPE_PKT_TYPE_BRIDGE` 不进入 `l2_lookup`
2. `airoha_ppe_foe_commit_subflow_entry()`：IPv6 子流保留 PPPoE ID
3. `airoha_ppe_foe_flow_stats_update()` / `airoha_ppe_foe_entry_get_stats()`：AN7581 IPv6 route 跳过 NPU stats

不包含：

- 931 的 MTU hunk（由 992 负责）
- 931 的固定 +16 字节预算

## 5. 还需要验证什么

- 931/993 只在 ZN504XG-D、HG5585F 上由作者测试；MD040 的 PON + 2.5G 拓扑需要实测。
- 重点看 IPv6 PPPoE 大流量：
  - `ppe/bind` 是否持续增长
  - IPv6 流是否还有 18 KB/s 级别的断崖
  - `dmesg` 是否有 NPU/PPE 错误
- 如果 IPv6 仍掉速，再考虑：
  - 禁用 `CONFIG_NET_AIROHA_FLOW_STATS`（当前本来就是关闭）
  - 检查 `pppoe-wan` egress 是否被 `airoha_is_valid_gdm_dev` 拒绝（需要 9996 的 ppp uplink 解析）
