# Agent Note: 115 扫码登录接通 —— 验收判据是 cookie 的四键，不是"有 cookie"

Status: implemented

Independent: 115 在参考实现里是**独立一类**（`Qr115`，7 个方法），登录与网盘操作分开；
本仓此前 115 完全没有登录链路（连 `Err("尚未接入")` 都是通用兜底）。
本条与夸克/UC（CAS 族）、百度（passport 族）并列，是第三种形状：**自建扫码 + POST 换四键**。

## Problem

Owner：「其余 7 家网盘登录扫码能出二维码」。115 点「登录」时只有
`Err("115 网盘 的扫码登录尚未接入（当前完成夸克/UC/百度）")`，没有二维码。

## Decision

按取证实现三跳（`.probe/r3c-nine-pan-login-protocols.md` 附：115 的完整登录流程）：

```text
① 取码   GET https://qrcodeapi.115.com/api/1.0/qandroid/1.0/token/
        → uid；二维码内容 = https://115.com/scan/dg-<uid>
② 轮询   GET https://qrcodeapi.115.com/get/status/?uid=<uid>&_=0
        → state / code / data.status
③ 换 cookie POST https://passportapi.115.com/app/1.0/qandroid/1.0/login/qrcode/
        → cookie 必须含 UID / CID / SEID / KID 四键
UA（逐字）：Mozilla/5.0 115disk/30.1.0
```

两条实现决定（都是"把不确定集中到一处"）：

1. **状态码映射只写在一处**（`pan115_status_of`）：`data.status == 1` ⇒ 已扫未确认；
   `>= 2` ⇒ 已确认；其它 ⇒ 等待。取证只给了**字段名**、没给取值表 ——
   所以每次轮询都把 body 记进日志，真机读数来了只改这一个函数。
2. **四键缺一即失败**（`pan115_cookie_from_body`）：这是取证里明确写下的**验收判据**，
   不是我自己加的严格。缺键的登录态不会在登录这一步报错，只会在后续请求里全 401。

## Alternatives considered

### A. 只要"有 cookie"就算登录成功（不校验四键）

**最强理由**：宽松些能兼容 115 的协议演进；万一以后多一个键也不至于登不进。

**否掉的原因**：取证给的判据就是四键 —— 这是唯一可判定的"登录态完整"证据。
放宽成"非空"会让"只拿到 UID 一个键"也算成功，用户看到"登录成功"然后所有列表请求 401，
排查成本极高（本仓已经因为"空判断"吃过一次，写在夸克那条的 cookie 基线里）。

### B. 状态码按"响应里出现 uid 就算确认"

**最强理由**：不用猜 status 的取值语义，看到 uid 回来就往下走。

**否掉的原因**：取码响应里本来就有 uid（轮询接口也会回显 uid），
那样第一次轮询就会判定"已确认" ⇒ 用户还没掏出手机就"登录成功"了，
换 cookie 必然失败，且错误指向错误的地方。

### C. 换 cookie 时把参考实现常见的 `app=web`/`account=...` 一起塞进表单

**最强理由**：多带参数成功率更高（有些接口缺参数会 400）。

**否掉的原因**：取证里**没有**这个请求体的字段表。多编一个参数就是猜协议，
而且猜错了错误信息会指向"参数不对"而不是"我们不知道"。只发 `uid`（最小集合），
失败时如实报 HTTP 与响应体，批末真机再补。

## Consequences

**收益**

- 115 的「登录」从"报错"变成"出二维码"，并且给出了可判定的完成判据（四键）。
- 状态映射、四键校验、三条 URL 都是纯函数 ⇒ 离线可断言、可注入。
- 未接入名单继续缩短（现在只剩光鸭一家；阿里/天翼/迅雷/123 待下一轮）。

**代价与边界**

- **整条链路没有真账号跑过**；`status` 的取值语义是唯一"按常见两态映射"的地方，
  已在代码里显式标注，并把每次轮询的 body 打进日志。
- 换 cookie 的请求体只有 `uid`（见 Alternatives C）。
- `account` 固定写"115 网盘"（没有取证到昵称接口）。

## 验证结果（已发生）

```text
cargo test --lib pan_login --release → 30 passed / 0 failed
  新增：pan115_urls_match_the_documented_flow       三条 URL + dg- 前缀
        pan115_cookie_requires_all_four_keys        四键齐全成功 / 缺 SEID 失败且点名
        pan115_status_mapping_is_single_sourced     1→Scanned、2→Confirmed、0→Pending
故障注入（真红，已实测）：
  ① 二维码前缀 `dg-` → `d-` ⇒ pan115_urls_match_the_documented_flow FAILED
  ② KEYS 里把 SEID 换成重复的 KID ⇒ pan115_cookie_requires_all_four_keys FAILED
```

## Relations

- 同批（不同协议族，供对照）：
  [./2026-10-28-uc-qr-login-same-cas-different-ids.md](./2026-10-28-uc-qr-login-same-cas-different-ids.md)、
  [./2026-10-28-baidu-qr-login-passport.md](./2026-10-28-baidu-qr-login-passport.md)
- 判据来源（115 的 `Qr115` 类取证）：
  `.probe/r3c-nine-pan-login-protocols.md` 附录"115 的完整登录流程"