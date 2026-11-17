# IPTV 桥接与 PPE：可行性评估

日期：2026-11-17
适用：Nokia XG-040G-MD / AN7581，路由模式，`lan2-4` 作为 IPTV

## 1. 结论

**IPTV 不建议现在接入 PPE。** 原因不是“PPE 不会桥接”，而是 IPTV 的流量形态和 MD040 的 1G 口拓扑决定了收益/风险不成比例：

- IPTV 是 **二层桥接 + 组播**，不是 `lan1`/`pon0` 的 L3 路由/NAT。
- `lan2-4` 不是原生 GDM 口，而是 **`gdm1` 后面的 `en7581-switch` 用户口**（DTS: `gsw_port2/3/4`）。
- PPE 的组播端口掩码 `AIROHA_FOE_IB2_PORT_AG` 在 EN7581 上只有低 4 位是明确可用的 LAN 映射；它不能直接表达 `lan2-4` 这三个 switch 用户口。
- IPTV 码率通常只有几 Mbps 到几十 Mbps；软件桥 + IGMP snooping 在 AN7581 上成本很低，稳定性优先。

因此建议：

1. **当前阶段**：IPTV 走 `br-iptv` 软件桥 + IGMP snooping，不加入 `ppeflow`。
2. **后续实验**：只在独立分支尝试 native L2B / switch 组播卸载，不影响主路由的 P0/P1。
3. **不要**把 `br-iptv` 加进 `inet ppe` flowtable；那条路只适用于 L3 路由/NAT。

## 2. 拓扑与包路径

```text
XG-PON
  |
 pon0 (gdm2)
  |
 PPE
  |
 gdm1 (10G internal)
  |
 en7581-switch
  |---- gsw_port2 -> lan2 (1G)
  |---- gsw_port3 -> lan3 (1G)
  |---- gsw_port4 -> lan4 (1G)
```

LAN 主口：

```text
lan1 = gdm4 (2.5G EN8811H), native GDM
```

IPTV 桥：

```text
br-iptv = { lan2, lan3, lan4, pon0.<IPTV_VLAN> }
```

- PON 侧 IPTV VLAN 子接口进入 `br-iptv`
- 机顶盒接 `lan2-4`
- IGMP snooping 决定组播复制到哪些口

## 3. 为什么 `ppeflow` 不覆盖 IPTV

`ppeflow` 创建的是：

```text
table inet ppe
flowtable ft { hook ingress priority 0; devices = { lan1, pon0 }; flags offload; }
chain forward { ... flow add @ft }
```

这是 **L3 路由/NAT** flowtable，只处理 `lan1` ↔ `pon0` 的三层流。

IPTV 是：

- `br-iptv` 的二层桥转发
- 目的 MAC 是组播 MAC
- 不经过 `inet` forward 的 L3 路由/NAT
- `lan2-4` 是 switch 用户口，不是 `lan1`

所以 `ppeflow` 不适用；把 `br-iptv` 加进去也不会触发 `airoha_eth` 的 `ndo_setup_tc`（bridge master 没有这个回调）。

## 4. native L2B 能做什么

AN7581 的桥接加速走 **native L2B**，不是 nft flowtable：

- QDMA RX 上报未绑定 L2 条目
- 驱动解析 Ethernet + VLAN(1~2 层) + 可选 PPPoE
- 填 native L2B FOE，硬件学习/绑定

相关补丁：

| 补丁 | 作用 |
|---|---|
| `930-net-airoha-fix-native-l2b-entry-layout.patch` | 修正 AN7581 native L2B 布局，保留硬件学习到的 ingress key |
| `9994-net-airoha-fix-native-l2b-entry-layout.patch` | naoki66 同类实现 |
| `9995-net-airoha-complete-ppe-offload.patch` | PON/QinQ/组播/aging；组播 L2B 读取/更新 |
| `9993-net-airoha-pass-ingress-vlan-to-bridge-path.patch` | 桥接路径传递 ingress VLAN 上下文 |

理论上：

- **单播 IPTV**（如果运营商用 unicast）：可能通过 L2B 卸载到 `gdm1`/switch 口；需要实测 `ppe/entries` 和 CPU。
- **组播 IPTV**：PPE 需要复制到多个 LAN 口；`PORT_AG` 只明确支持低 4 位 LAN 映射，无法直接表达 `lan2-4` 三个 switch 用户口。更现实的路径是：
  - PPE 把一份流送到 `gdm1`
  - `en7581-switch` 根据 MDB/IGMP snooping 复制到 `gsw_port2-4`
  - 但这依赖 switch 驱动的组播表支持，不是 PPE 单独能完成的

## 5. 实验方案（独立分支）

如果确实要尝试，建议单独开 `iptv-ppe` 分支，不影响 `md040` 主线：

1. 应用 `930`/`9994`（L2B 布局）、`9995`（组播 L2B）、`9993`（ingress VLAN）。
2. 保持 `br-iptv` 软件桥，先只观察 native L2B 是否自动学习 IPTV 流：
   ```sh
   cat /sys/kernel/debug/ppe/entries | grep -i L2B
   cat /sys/kernel/debug/ppe/bind
   ```
3. 对比开启/关闭 IPTV 播放时的：
   - `top` / `mpstat` 软中断
   - `pon0` RX、`gdm1` TX、`lan2-4` TX
   - `ppe/entries` 是否出现组播 L2B 条目
4. 测试：
   - 单路/多路组播
   - 频繁换台、IGMP join/leave
   - 机顶盒重启
   - VLAN 单层/双层
   - 桥接与主路由 NAT 同时大流量
5. 判定标准：
   - IPTV 播放稳定，无花屏/卡顿
   - CPU 软中断明显下降，或至少不升高
   - 主路由 `lan1`↔`pon0` 的 PPE 绑定/吞吐不受影响
   - 失败可一键回退到软件桥

如果 `ppe/entries` 没有组播 L2B 条目，或 CPU 没有改善，说明硬件路径没有接管，应停止该实验。

## 6. 建议的最终形态

短期（当前仓库）：

- `br-lan` = `lan1`，走 `ppeflow` + L3 PPE
- `br-iptv` = `lan2-4` + IPTV VLAN，走软件桥 + IGMP snooping
- `ppeflow` 不包含 `br-iptv`
- 文档明确标注 IPTV 不在 PPE 范围

中期：

- 若 IPTV CPU 成为瓶颈，先查 switch 组播表 / IGMP snooping 是否生效
- 再评估 `9995` 的组播 L2B 和 switch MDB 是否能协同
- 不在主分支默认启用实验性组播卸载

## 7. 参考

- `docs/ppe-pon-research-2026-11-16.md`
- naoki66 bridge flowtable 说明：
  https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/blob/master/docs/airoha-bridge-flowtable-offload.md
- naoki66 PPPoE/桥接说明：
  https://github.com/naoki66/ImmortalWrt-for-Gemtek-brightspeed/blob/master/docs/airoha-ppe-pppoe-bridge-offload.md
- PonWrt #41（DSA/flowtable 限制）：
  https://github.com/pbs05/ponwrt/issues/41
