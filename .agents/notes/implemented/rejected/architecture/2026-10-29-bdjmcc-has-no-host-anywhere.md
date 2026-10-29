# Agent Note: 北斗（csp_Bdjmcc）的 host 在任何可得产物里都不存在 —— 不注册，但把 ext 归一修对了

Status: implemented

Independent: 与 `2026-10-29-cloudflare-tls-fingerprint-blocks-seedhub.md`（有 host 但被 CF 拦）互补：
本条是**连 host 都没有**的一类。产出是"四路取证全空"的结论 + 一处真实的 ext 解析缺陷修复。

## Problem

订阅里有 `csp_Bdjmcc`（🛸北斗丨蓝光秒播）这一类，条目**没有 `ext`**：

```json
{"key":"北斗","name":"🛸北斗丨蓝光秒播","api":"csp_Bdjmcc","type":3,"searchable":0,"quickSearch":0,"filterable":1}
```

⇒ 我们的 `bdjmcc.rs` 一直是"故意不注册"的占位（缺站点地址）。

## 取证（四路，每路都有证据文件）

```text
① 订阅原文：参考链接 https://8815.kstore.vip/tvbox/wmz（base64 解码）→ 条目如上，无 ext
   （同三份本地快照一致：.probe/wmz-config.json / ref-subscription.json / bdjmcc-sub.dec.json）
② spider jar：订阅里的 261028.jar（2.4MB）→ dex 逐方法 dump：
   `Bdjmcc` 的 16 个字段里 **SITE = null**；<clinit> 只有 8 条正则、<init> 无常量 ⇒ 无站点常量
③ 模板指纹扫主机：jar 里 594 条 URL → 247 台主机，全打 `/`；
   判据 = 四个分类 code（`A051pCM47kBg2`…）任一出现 **或** `a.picture[href=/v/…]` ⇒ **0 命中**
③' 订阅 ext 里的 69 台主机同样扫 ⇒ **0 命中**
④ 域名侧：bdjm.cc/tv/top/vip/app/club/fun、bdjmcc.com、bdjm.net、bdjm.xyz
   ⇒ 全部 NXDOMAIN 或 TLS 握手失败（停放）；bdjm.xyz = 200/114B 停放跳转页
⑤ 参考 APK：3 个 dex + 全部 zip 条目扫 `csp_Bdjmcc`/`北斗`/`bdjm` ⇒ **0 命中**（客户端不内置站点表）
```

⇒ host 不存在于任何可得产物（是**原配置作者漏了 ext**）。写死猜的域名 = 制造"能注册"的假象。

## Decision

```text
保持不注册（门禁 `bdjmcc_must_not_be_registered_this_batch` 仍绿）；
但把这次顺手发现的**真缺陷**修掉：`host_of` 只认 `{"site":[…]}`，而真实订阅里还有
`{"host":…}` / `{"url":…}` / 裸字符串三种形状（例：`csp_AppRJ` 就是 `{"url":"http://v.rbotv.cn"}`）
⇒ 改成递归收集 JSON 里的 URL，四种形状全覆盖。
并把路径形态按 DEX 逐字固化：`/list/<code>/<page>.html`、`/v/<slug>.html`、`/p/<code>/<n>/<m>.html`。
```

## Alternatives considered

### A. 猜一个域名写死进去，让源"能出现在列表里"

**最强理由**：源数 +1，看起来完成了任务。

**否掉的原因**：247 台主机 + 69 台 + 8 个候选域名全扫过，0 命中。猜出来的域名只会让用户点进去吃 404，
正是本仓反复禁止的"假入口"。

### B. 把 `bdjmcc.rs` 整个删掉（既然永远用不上）

**最强理由**：不留无用代码。

**否掉的原因**：类本体与路径形态是**从 DEX 逐字取证**来的，删了就丢。留着的成本是编译时间（可忽略），
收益是"将来 ext 补上就能一行注册"。文件头写了完整配方。

## Consequences

**收益**

- `host_of` 现在认得四种 ext 形状 —— 这条**不只服务北斗**：任何 `{"url":…}`/`{"host":…}` 形态的 csp 源都因此可解析。
- 北斗的路径形态与"缺 host"的判据被固化，将来补 ext 即用（文件头有配方与验证命令）。

**代价与边界**

- 北斗仍不可用（无 host）。
- 首版 `host_of` 门禁曾**假绿**：注入"删掉 Object 分支"不红（分隔符兜底也能切出 URL）。
  已把 JSON 分支与兜底改成**互斥**，复测注入为红 —— 这条经验比修复本身更值钱。

## 验证结果（已发生）

```text
cargo test --lib csp::bdjmcc --release → 11 passed / 0 failed / 1 ignored（我自己复跑过）
  host_of_accepts_common_ext_shapes      （四种 ext 形状）
  host_only_from_ext_and_absent_everywhere_else
  paths_match_dex_shapes                 （/list/A051pCM47kBg2/1.html 等逐字）
故障注入（已实测真红）：
  删 Object 分支 ⇒ host_of_accepts_common_ext_shapes FAILED
  去掉 list_path 的 .html ⇒ paths_match_dex_shapes FAILED
取证：.probe/bdjmcc-REPORT.md、bdjmcc-dexscan.out.txt、bdjmcc-hunt.out.txt、bdjmcc-hunt2.out.txt
```

## Relations

- 同批"有 host 但取不到"：[./2026-10-29-cloudflare-tls-fingerprint-blocks-seedhub.md](./2026-10-29-cloudflare-tls-fingerprint-blocks-seedhub.md)
- ext 丢失的另一类原因：[./2026-10-29-ext-sources-dropped-on-probe-failure.md](./2026-10-29-ext-sources-dropped-on-probe-failure.md)