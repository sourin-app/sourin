# Agent Note: appget 类源候选摘除判据改造 —— 规则⑤从"摘"改"留+标（需解析）"（N1）

Status: implemented

Independent: 接续上批 appget 静默失败收口（留痕），本篇改**判据本身**——
上批定位的结论是：appget 类源不能播的直因不是"源坏了"，是
`StreamPreparer.prepare` 把它们的第三方播放页候选**整批摘掉**（列表空）。

## Problem

appget 类源的 play 结果普遍是第三方播放页（Rust 侧 `needs_parse` 自认），
命中规则⑤ `looksLikePage && !hasMediaExt` ⇒ 候选全摘 ⇒ 用户看到
「该内容没有可播放的地址」。上批只补了留痕（摘了不说=静默失败）；本批回答
"该不该摘"。

## 管线核实（决定性，实测非推演）

生产唯一可达的解析路径 = 起播预检 `precheckNonMedia`（nonmedia_guard.dart，
T4-I 已接线）：JSON 信封取 url / HTML 刮引号 m3u8 换直链，都不行给人话报错。
`StreamPreparer.resolver` 全仓零注入 = 死代码，不算数。
**实测**（appget 代表源）：播放页 HTML 壳内嵌 `const vid='…/index.m3u8'`，
该地址 200 + 合法 HLS 清单（AES-128 密钥 + 真 .ts 分段）⇒ **保留后有真实
可播路径**——round65 时代"该形态永远打不开"的结论已过时。

## Decision

```text
三态判据（纯形态、不联网、按形态不按 label——appget 自家页 needs_parse
根本不声明，只认声明会漏掉主修目标）：
S1 空/非 http(s)/无 host        ⇒ 摘（不变，无任何后续路径）
S2 猜拼媒体后缀（规则④）        ⇒ 摘（本批不动，见 N6）
S3 页面段且无媒体扩展（规则⑤）  ⇒ 留 + label 标「（需解析）」（不双标）
S4 直链/HLS                     ⇒ 直通，逐字不变（identical 契约回归）
不走 needsHostResolve=true：那会让 isPlayable=false 又被筛掉 ⇒ 回到空列表。
```

## Alternatives considered

- **按 Rust 的 needs_parse 声明保留**：appget 自家页不声明 ⇒ 漏掉主修目标。否决。
- **S2 规则④一并放宽**：gsuus 单点实测动摇了"几乎必然 404"前提，但涉及全部
  /video|/vodplay/ 宿主且仅单点 ⇒ 立项 N6 多源实测后再动。本批一字未动。
- **保留但不标注**：用户不知道这条要走解析、为何点开慢/可能报错。标注是可行动信息。

## Consequences

- 门禁：新文件三态单测五组 + 留+标行为七条 + 直链/HLS identical 回归；
  r65 混合③断言同步（旁注实证依据）；**注入证红**（开关置真=退回摘 ⇒ S3 红 +
  r65 红，还原复绿——新字面有牙）；label 消费点全仓核实仅三处且零触碰
  （isAudioOnlyLine 有行为断言钉住）。
- 互检复核通过（无 P1/P2）：_pageShapePathOf 与 HEAD 规则⑤**逐字对拍等价**
  （S2/S3 天然互斥有证明）；直链 8 条 identical；证红亲手跑。
- 残余边界（**不许当作已解决**，已写进两处文件头）：VIP 大站（需 jx 接口，
  仓内无 jx）保留后播不了但预检给人话报错；页面嵌假流 mpv open 失败（预检既有边界）。
- 附带：pan_wiring 门禁"摘除判据不许动"文案过时，升级为钉三态判据符号。

## 边界（如实）

- N6：S2 规则④的多源实测后放宽，未做。
- 未做真机验证（按分工 lead 部署后验收；验收判据：appget 类源线路列表出现
  「（需解析）」标注且点开可播）。
