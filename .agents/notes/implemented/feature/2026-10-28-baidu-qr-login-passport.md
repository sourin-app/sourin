# Agent Note: 百度网盘扫码登录接通 —— passport 族，判据在响应头而不是业务码

Status: implemented

Independent: 与本目录 `2026-10-28-uc-qr-login-same-cas-different-ids.md` 是**不同协议族**：
夸克/UC 是自建 CAS（业务码在 body、二维码由 token 拼出来），百度是 passport
（二维码 URL 由响应直接给、"扫中"的信号是响应头出现 `BDUSS`）。
两条笔记各自守自己那一族，不互相引用为前置。

## Problem

Owner：「其余 7 家网盘登录扫码能出二维码（UC 优先，与夸克同族）」。
UC 完成后，百度仍是 `Err("百度 的扫码登录尚未接入…")` —— 点「登录」得到错误，没有二维码。

## Decision

按取证实现四跳（`.probe/r3c-nine-pan-login-protocols.md` 附二）：

```text
① 取二维码  GET passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc
            → data.channel_id / data.sign / data.url（二维码内容 = url 字段）
② 轮询      GET passport.baidu.com/channel/unicast?channel_id=<cid>&v=<sign>
            → ★ "已确认"的唯一判据：响应头 set-cookie 里出现 `BDUSS`
③ 换登录态  GET passport.baidu.com/v3/login/main/qrbdusslogin?v=<sign>&bduss=<BDUSS>
④ 补 cookie GET pan.baidu.com/disk/main?from=homeFlow（pan 域的 STOKEN 等在这条响应里）
UA：Chrome/151 桌面；Referer：https://pan.baidu.com/
```

三条实现决定：

1. **`v` 按候选字段找**：`sign`（真报文）→ `v`（取证用词）；都缺 ⇒ 报"协议可能变了"，**不编默认值**。
2. **cookie 是合并出来的**：`unicast` 的 Set-Cookie + `qrbdusslogin` 的 Set-Cookie +
   `disk/main` 的 Set-Cookie，**同名后到覆盖**（`merge_cookie` 纯函数）。
3. **未确认一律 `Pending`**：百度侧没有可判定的业务码读数，不去猜"已扫描"。

## Alternatives considered

### A. 把百度塞进"同族参数表"（与夸克/UC 共用实现）

**最强理由**：三家都是"出码 → 轮询 → 换 cookie"三段式，看着能抽。

**否掉的原因**：三处结构性差异，抽出来只会变成一堆 `if kind ==`：
二维码内容来源不同（token 拼 URL vs 响应给 url）、确认信号不同（业务码 vs 响应头 BDUSS）、
换 cookie 次数不同（一次 vs 两次 + pan 域补取）。登录协议族的差异是**行为差异**，不是参数差异。

### B. 用关键词判"已扫描"（`scanned` 中间态）

**最强理由**：用户扫完到手机上点确认之间有 1~3 秒，显示"已扫描，请在手机上确认"体验更好；
夸克的 `classify_pending` 也有关键词兜底。

**否掉的原因**：夸克那条有**真读数**（`50004001` = 未扫描），关键词只是兜底；
百度这边**一条读数都没有**。猜错的代价是 UI 显示"已扫描"而用户根本没扫
—— 那正是夸克第一版被记为"靠运气"的同一种错。宁可一直 Pending 到 BDUSS 出现。

### C. 只留 `qrbdusslogin` 那一次的 Set-Cookie

**最强理由**：少一次请求，实现更短。

**否掉的原因**：百度登录态是**分散**的 —— `STOKEN` 等 pan 域键在 `disk/main` 的响应头里。
只留一次的表现是"登录成功，但列不出文件"（本仓最怕的静默失败）。
`merge_cookie` 就是为此存在，并有"后到覆盖"的门禁。

### D. 合并 cookie 时保留先到的值

**最强理由**：实现更简单（`if 已存在 { continue }`）。

**否掉的原因**：旧值顶掉新值 = 拿着上一次的 ticket 去请求 ⇒ 401。
这条已用故障注入钉死（`merge_cookie_lets_later_win` 会红）。

## Consequences

**收益**

- 百度的「登录」从"报错"变成"出二维码"（`pan_qr_login_start` → UI 的 `QrView`）。
- 三条 URL + cookie 合并 + BDUSS 判定都是纯函数，离线可断言、可注入。
- `merge_cookie` 是通用件：后面 115/阿里 的"多段 Set-Cookie"也能复用。

**代价与边界**

- **整条链路没有真账号跑过**；失败会如实报"哪一步 HTTP 多少 / 字段缺哪个"。
- 没有 `Scanned` 中间态：扫码后 UI 会一直显示"等待扫码"，直到确认那一刻。
  这是有意的（宁可少一个漂亮状态，不多一个假状态）。
- `account` 固定写"百度网盘"：百度没有像夸克 `account/info` 那样稳定的昵称接口（未取证），
  编一个昵称等于造假。
- 未接入名单又短了一家（`unimplemented_kind_…` 现在只剩 115 / 光鸭）。

## 验证结果（已发生）

```text
cargo test --lib pan_login --release → 27 passed / 0 failed
  新增：baidu_urls_match_the_documented_flow
        baidu_qr_fields_accept_sign_or_v        （真报文用 sign、取证写 v，两种都认）
        bduss_detection_is_exact                （前缀必须整键匹配，空值不算）
        merge_cookie_lets_later_win             （同名后到覆盖、无重复键）
故障注入（真红，已实测）：
  ① unicast 的 `v=` 改成 `sign=` ⇒ baidu_urls_match_the_documented_flow FAILED
  ② merge_cookie 改成"保留先到的" ⇒ merge_cookie_lets_later_win FAILED
```

## Relations

- 同批的 UC（不同协议族，供对照）：
  [./2026-10-28-uc-qr-login-same-cas-different-ids.md](./2026-10-28-uc-qr-login-same-cas-different-ids.md)
- 夸克（CAS 族的第一家，登录链路的原始实现）：
  [../bug-fix/2026-10-28-quark-play-needs-puus-from-response-header.md](../bug-fix/2026-10-28-quark-play-needs-puus-from-response-header.md)
