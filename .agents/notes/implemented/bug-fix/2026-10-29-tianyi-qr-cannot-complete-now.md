# Agent Note: 天翼扫码"只能出码、轮询做不完"—— 按真读数把假入口关掉

Status: implemented

Independent: **推翻** `2026-10-28-device-flow-and-tianyi-logins.md` 里天翼那一段
（"三跳全逐字，直接实现"）。那条的三跳是从 dex 取证来的，但**真实网络已经改版**：
`loginUrl.action` 不再返回 `lt`/`reqId`，于是 appConf/轮询全线拿不到会话参数。
本条不改夸克/UC/百度/115/阿里/光鸭/迅雷任何一家。

## Problem

按取证实现的天翼链路在真机上报 `天翼出码失败 step=loginUrl HTTP 302 location_len=837`。
2026-10-29 逐跳真网复现：

```text
① GET cloud.189.cn/api/portal/loginUrl.action?…（no-redirect）
   → 302 Location = open.e.189.cn/api/logbox/oauth2/separate/auth/unifyAccountLogin.do
                    ?appId=cloud&version=v1.1&clientType=1&format=redirect&paras=<长串>&sign=<串>
   ⇒ **没有** lt / reqId（参考实现的正则取不到任何东西）
② POST open.e.189.cn/api/logbox/oauth2/appConf.do  (appKey=cloud&version=2.0)
   → {"result":22001,"msg":"非正确来源"}            ← 缺 lt/reqId 就不让过
③ POST …/getUUID.do（同参）
   → {"result":0,"uuid":"…qrClinentLogin.do?paras=new_uuid%3D…","encryuuid":"…",
      "encodeuuid":"https%3A%2F%2F…%3Fparas%3Dnew_uuid%253D…"}
   ⇒ **这一跳单独能通**；二维码内容 = 解两次 URL 编码后的 encodeuuid
④ POST …/qrcodeLoginState.do（带 uuid/encryuuid + 其余尽力补）
   → {"result":-20099,"msg":"页面已过期，刷新页面后重试"}
   ⇒ 轮询要的是 ② 那次会话产出的 paramId/reqId，而它们拿不到
```

## Decision

```text
· `tianyi_start` / `tianyi_poll` 一律返回**同一句如实报错**（常量 TIANYI_UNSUPPORTED）：
  说清"出码能通、轮询做不完"，并带上 22001 / -20099 两个真读数；
· 出码那一跳保留成纯函数 `tianyi_qr_from_getuuid_body()`（真报文门禁覆盖），
  轮询可用时直接接上，不必重新取证；
· 扫码下拉里**保留天翼**：它是"能救"的一家，摘掉会让用户以为不支持；
  点进去会看到这句原因，而不是空白。
```

## Alternatives considered

### A. 照样给一个二维码（getUUID 真能出），只是扫完没结果

**最强理由**：UI 上"有码"看起来就像做了；Owner 也一直在催"要能出码"。

**否掉的原因**：那是**假入口** —— 用户扫完、在手机上点了同意，客户端永远 `Pending`
（轮询 -20099）。本仓的硬纪律是"不许伪造成功/不许给点了没反应的按钮"，
一个扫了没用的码正是同一个形态。

### B. 给核心内嵌 WebView 走网页登录

**最强理由**：这是唯一能真正完成天翼登录的路（凭据要靠 sessionKey 换）。

**否掉的原因**：架构级改动（进程模型/打包体积/各平台 WKWebView 差异），
不在本批范围。要做得单独立项并先与 Owner 定形态（已记在"何时该翻案"）。

### C. 继续用 loginUrl 的 Location 硬凑 appConf 参数

**最强理由**：只差"两个参数"，凑出来就全通了。

**否掉的原因**：Location 里根本没有它们（只有 `paras`/`sign`，且 `paras` 是加密串）。
硬凑 = 猜协议；appConf 回的 22001 明确说"非正确来源"，猜中的概率接近零。

## Consequences

**收益**

- 天翼从"点了报错但不知道卡在哪"变成**一句说清原因与缺哪一步**的话。
- `tianyi_qr_from_getuuid_body()` 把已经验通的出码跳固化下来（真报文门禁覆盖），
  轮询一旦可用就能接上。
- 不再维护 1500 行"永远跑不通"的流程代码（浪费编译时间、误导后来人）。

**代价与边界**

- **天翼当前不能登录**（扫码做不完；也没有账号密码表单）。这是能力缺口，不是 bug。
- 之前那篇笔记里"天翼三跳全逐字，直接实现"的说法已失效（本篇是更正）。

## 何时该翻案

1. 抓到网页端登录时的 `paramId`/`reqId` 来源（旧客户端 UA/旧版 loginUrl，或从
   `unifyAccountLogin.do` 的 `paras` 解密）⇒ 把 ② 接上，`tianyi_start` 改成真出码。
2. 或决定允许内嵌 WebView / 让用户粘 `sessionKey`（架构决策）。

## 验证结果（已发生）

```text
cargo test --lib pan_login_tianyi --release → 4 passed
  getuuid_body_yields_qr_content（真报文 → 二维码内容/uuid/encryuuid）
  tianyi_says_it_cannot_complete_instead_of_faking（必须 Err 且带 22001/-20099）
  is_tianyi_login_is_exactly_one_kind
  url_decode_handles_percent_and_plus
真网络读数：见 Problem 段四条（全部 2026-10-29 现场 curl）
```

## Relations

- 被更正的那篇（天翼段）：[../feature/2026-10-28-device-flow-and-tianyi-logins.md](../feature/2026-10-28-device-flow-and-tianyi-logins.md)
- 同族的"如实报"纪律：`needs_ext` 逐类标注、网盘 `play` 早年的"取流未接通"