# Full MD040 build (cloud-repo plugin set)

参考：https://github.com/include-H/XG-040G-MD

## 构建

```sh
./scripts/build-md040-full.sh
```

产物：

```text
bin/targets/airoha/an7581/
```

## 额外插件

在基础 `configs/md040.config` 上增加：

| 分类 | 插件 |
|---|---|
| 主题 | `luci-theme-argon`（含 Argon 配置页） |
| Airoha | `luci-app-airoha-npu`（DenzelVincent feed，1.2.2） |
| DNS | `mosdns` + `luci-app-mosdns` + `luci-app-mosdns-panel` |
| 代理 | `dae` + `dae-geoip` + `dae-geosite` + `luci-app-dae` |
| 工具 | `luci-app-lucky`、`luci-app-msd_lite`、`luci-app-ttyd` |
| 存储 | `luci-app-diskman`、`luci-app-samba4`、`luci-app-hd-idle` |
| 系统 | `luci-app-sqm`、`luci-app-autoreboot`、`luci-app-upnp`、`luci-app-package-manager` |

## dae 的配置坑

当前树里 `dae` 的 Kconfig 依赖 `KERNEL_XDP_SOCKETS`。这个符号是隐藏的，
`make defconfig` 会把 `CONFIG_PACKAGE_dae=y` 丢掉（即使 `.config` 里已经有
`CONFIG_KERNEL_XDP_SOCKETS=y`）。

`build-md040-full.sh` 在 `make defconfig` 之后强制追加：

```text
CONFIG_PACKAGE_dae=y
CONFIG_PACKAGE_dae-geoip=y
CONFIG_PACKAGE_dae-geosite=y
CONFIG_PACKAGE_luci-app-dae=y
CONFIG_PACKAGE_luci-i18n-dae-zh-cn=y
```

`make world` 不会再次跑 defconfig，因此这些选择会进入最终镜像。

内核需要：

```text
CONFIG_KERNEL_DEBUG_INFO_BTF=y
CONFIG_KERNEL_BPF_EVENTS=y
CONFIG_KERNEL_XDP_SOCKETS=y
```

主机需要可用的 clang（>= 12）和 pahole：

```sh
sudo dnf install clang llvm dwarves
```

## IPTV / 网络

全量版仍保持：

- `br-lan`：`lan1`（2.5G）
- `br-iptv`：`lan2-4` + IPTV VLAN
- PPE flowtable：只 `lan1 + pon0`

插件不改变这个拓扑；MosDNS/dae 是用户态服务，不参与 PPE 数据面。

## 关于 luci-app-airoha-npu

本仓库使用 `DenzelVincent/luci-app-airoha-npu`（1.2.2，中文），因为它的仓库
根目录只有 `luci-app-airoha-npu/` 包目录，适合作为 feed 或直接 clone 到
`package/`。

`rchen14b/luci-app-airoha-npu` 是上游原始项目，功能同样有用（NPU 状态、PSE
队列、PPE 流表、CPU 调频/超频）。但它的仓库根目录既有一份 package Makefile，
又有 `luci-app-airoha-npu/` 子目录；作为 feed 扫描时容易出现同名包重复，建议
按它的 README 用 `git clone ... package/luci-app-airoha-npu` 的方式引入。

它只是**观测工具**，不修复 PPE/PON 本身：

- PPE 流表来自 `/sys/kernel/debug/ppe/entries`
- Frame Engine 寄存器 / CPU 超频需要 busybox `devmem` 和 `/dev/mem`
- 本仓库的 `md040.config` 已启用 `CONFIG_BUSYBOX_CONFIG_DEVMEM=y` 和
  `CONFIG_KERNEL_DEVMEM=y`

论坛里提到过 `luci-app-airoha-npu` 的 PSE 队列历史丢包计数误报，wuziwei 的
固件对界面做过修复；如果只看 PPE bind/entries，原版和 Denzel 版都能用。

更完整的对比（rchen14b 原版 vs DenzelVincent 分支、依赖、已知问题）见
`docs/npu-app.md`。

## 2026-11-17 构建结果

- 版本：`r0+43269-a2b1f6ec18`
- sysupgrade：55M
- recovery：48M
- recovery sha256：`8560a48cb28dc246fa24b30b6abd9d92e6ec98a4292bf831c4774e1b6eb318f5`
- sysupgrade sha256：`815d3da5e28f1943fa804f5d990f27970712c7687d64a338075f3f0854c99538`
- manifest 已确认包含：
  - `luci-theme-argon` 3.1.3
  - `luci-app-airoha-npu` 1.2.2 + 中文
  - `mosdns` 5.3.4 + `luci-app-mosdns` + panel
  - `dae` 2.0.0 + `luci-app-dae` + geoip/geosite
  - `lucky`、`luci-app-lucky`
  - `luci-app-samba4`、`sinfo`、`diskman`、`msd_lite`、`ttyd`、`upnp`、`sqm`
- squashfs 已确认包含：
  - `/usr/bin/dae`
  - `/usr/bin/mosdns`
  - `/usr/libexec/rpcd/luci.airoha_npu`
  - `/etc/uci-defaults/30_luci-theme-argon`
- `bridger` 包为了满足 dae 的 BPF 依赖被编入，但 `99-md040-network` 会在首启
  执行 `bridger disable`；需要时手动启用。

## MosDNS 默认配置

`98-mosdns-defaults` 在首启写入：

- `enabled=1`，监听 `0.0.0.0:5335`
- `redirect=1`：dnsmasq 继续用 53，把查询转发给 MosDNS，并关闭 dnsmasq 缓存
- 国内 DoH：阿里 223.5.5.5 / 223.6.6.6、DNSPod、1.12.12.12、120.53.53.53
- 缓存 8000 条、lazy_cache_ttl 86400、cache.dump 持久化
- 广告过滤：217heidai adblockdns 规则（AdGuard 语法，adblock_set 解析）
- geo 自动更新，每天 3 点
- 日志级别 error

境外域名默认也先用国内 DoH，保证无代理环境可用；需要更干净的境外解析时，
在 LuCI「服务 → MosDNS」把 `remote_dns` 改成代理端 DNS 端口。

首启脚本只在 `/etc/config/mosdns` 存在时执行；恢复出厂/首次刷机后生效，
升级保留配置时不会覆盖用户已有 MosDNS 设置。
