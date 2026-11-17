# Feed patches

The PON driver is an OpenWrt feed, not part of `target/linux/`.

After `scripts/feeds update/install`, `scripts/apply-feed-patches.sh` applies
the patches below to `feeds/pon_drivers/airoha-xpon/src`.

| Patch | 作用 |
|---|---|
| `pon_drivers/mbi-reset.patch` | issue #49：MBI RX overrun 风暴达到阈值后触发 MAC epoch reset |

Patch format:

- Paths are relative to `feeds/pon_drivers/airoha-xpon/src`
- Apply with `git apply --directory=airoha-xpon/src`
- Do not use `git am` at the feed root; the path prefix will not match
