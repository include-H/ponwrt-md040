# luci-app-airoha-npu 评估

## 结论

**有用，但它是观测/调频工具，不是 PPE/PON 修复补丁。**

它能看：

- NPU 固件版本、核心数、是否 attach
- PPE bind / 总条目数
- PPE 流表（前 100 条，BND/UNB、IPv4/IPv6/L2B、五元组）
- Frame Engine / PSE 队列、CDM 卸载比例
- CPU 频率、governor、PLL 超频

不能做：

- 让 PPE 绑定成功
- 修 PPPoE / IPv6 offload 的 fallthrough
- 修 PON MBI overrun
- 替代 `ppeflow` flowtable 或 `airoha_ppe` 补丁

## rchen14b 原版 vs DenzelVincent 分支

| | rchen14b/luci-app-airoha-npu | DenzelVincent/luci-app-airoha-npu |
|---|---|---|
| 版本 | 1.0.1 | 1.2.2 |
| 界面 | 英文为主 | 中文翻译 |
| 仓库结构 | 根目录有一份 package Makefile，另有 `luci-app-airoha-npu/` 子目录 | 根目录只有 `luci-app-airoha-npu/` 包目录 |
| 作为 feed | 容易扫到两份同名包，建议按 README clone 到 `package/` | 可以直接作为 feed，或 clone 到 `package/` |
| 功能 | NPU/PPE/PSE/CPU 频率/超频 | 同左，包含中文和部分界面改进 |

本仓库的 full build 使用 **DenzelVincent 1.2.2**，因为：

1. 和你现有的 `include-H/XG-040G-MD` 云编译仓库一致；
2. 中文界面；
3. 仓库结构更适合 feed。

如果你想换回 rchen14b 原版：

```sh
# 不要用 feed；直接 clone 到 package/
git clone https://github.com/rchen14b/luci-app-airoha-npu.git package/luci-app-airoha-npu
```

然后确保 `CONFIG_PACKAGE_luci-app-airoha-npu=y`。包名相同，不能和 Denzel 版同时安装。

## 依赖

- `CONFIG_BUSYBOX_CONFIG_DEVMEM=y`：Frame Engine 寄存器、CPU 超频需要
- `CONFIG_KERNEL_DEVMEM=y`：`/dev/mem`
- PPE debugfs：`/sys/kernel/debug/ppe/entries`
- 可选 `air_tools`：更多 Frame Engine 调试

本仓库的 full config 已启用 busybox devmem 和 kernel devmem。

## 已知问题

论坛/naoki66 文档提到过 PSE 队列历史丢包计数会长期标红，wuziwei 的固件对界面做过修复。若只看 PPE bind 和流表，原版/Denzel 版都能用；不要把 PSE 红色计数直接当成当前丢包。

CPU 超频部分只建议调试时用，默认不要动；MD040 的散热和供电不适合长期超频。
