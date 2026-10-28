# Agent Note: UC 扫码登录接通 —— 与夸克同族，但 client_id / 主机 / 二维码入口三处都不同

Status: implemented

Independent: 本仓此前**只有夸克一家**有扫码登录（`2026-10-27` 的 B1）。
本条新增 UC。与既有决定的关系是"**按批推进的第二家**"，不改夸克那条的任何判据；
但它**推翻了一个说法**：`qr_login_start` 的兜底文案写着"B1 只做夸克" ——
现在改成"当前完成夸克/UC"（否则用户点 UC 会以为我们只支持一家）。

## Problem

Owner：「其余 7 家网盘登录扫码能出二维码（UC 优先，与夸克同族）」。
改前 `qr_login_start(PanKind::Uc)` 直接返回 `Err("UC 的扫码登录尚未接入（B1 只做夸克）")`
⇒ 网盘配置页点 UC 的「登录」得到错误提示，**没有二维码**。

## Decision

照取证实现 UC 的三跳（`.probe/r3c-quark-login-endpoints.log` 的 `buildUcQrInfo` /
`handleUc` 方法体字符串，逐字）：

```text
① 取码     GET https://api.open.uc.cn/cas/ajax/getTokenForQrcodeLogin
              ?pr=UCBrowser&fr=pc&sys=win32&client_id=529&v=1.2&request_id=<rid>
② 二维码   https://su.uc.cn/4_fzMj2?uc_param_str=<固定串>&token=<token>
              &client_id=529&uc_biz_str=S%3Acustom%7CC%3Atitlebar_fix
③ 换票     GET https://api.open.uc.cn/cas/ajax/getServiceTicketByQrcodeToken
              ?__dt=18884&__t=<ms>&client_id=381&v=1.2&request_id=<rid>&token=<token>
④ 换 cookie GET https://drive.uc.cn/account/info?st=<ticket>   （Referer: broccoli.uc.cn）
```

四条实现决定：

1. **每家一个函数**（`quark_start`/`uc_start`、`quark_poll`/`uc_poll`），不做"参数表 + 通用实现"。
2. **`request_id` 客户端生成**（32 位十六进制，纳秒时间 ^ 进程内序号），
   并在会话表里与 token 用 `|` 拼起来存 —— 换票必须与取码**同一个** id。
3. **两个 UA 分工**：取码用 `uc-cloud-drive/2.5.20 …`（Electron 版）；轮询用 Chrome 151。
4. **业务码判据与夸克共用**（`quark_status_code` / `classify_pending`）：同族 CAS 同一套码，
   另写一份必然漂移。

## Alternatives considered

### A. 把"同族"做成一张参数表 + 一个通用实现

**最强理由**：`PanDrive`（夸克/UC 网盘列表）就是这么做的（一份实现 + 两份数据），
看似该保持一致的风格；将来第三家同族盘只要加一行。

**否掉的原因**：

```text
① 这两家**不是纯参数差异**：取码 client_id 与换票 client_id **不同**（529 vs 381）、
   二维码入口不同（su.uc.cn/4_fzMj2 vs su.quark.cn/4_eMHBJ）、
   `uc_param_str` 只有 UC 有、Referer 也不同（broccoli.uc.cn vs pan.quark.cn/）。
   参数表会膨胀到"每行五个特殊值"，读表的人反而看不出差异在哪。
② 更危险的副作用：一旦有了通用实现，下一家（百度/115/阿里）就会被**硬塞进表里** ——
   而它们的协议族根本不同（passport 扫码 / 自建扫码 / device-code）。
③ `PanDrive` 能合并是**取证结论**（协议特有方法集逐字相同）；
   `pan_login` 没有这样的证据，不应套用同一种抽象。
```

### B. UC 轮询也用 Electron UA

**最强理由**：一家一个 UA 更好记，少一个常量。

**否掉的原因**：取证是**两个不同 UA**（`buildUcQrInfo` 与 `handleUc` 各一个），
与夸克同一种分工。UA 错了 CAS 可能当成不支持的客户端 —— 这种错不会报错，只是扫不动。

### C. `request_id` 传空串

**最强理由**：少一个随机数来源，实现更短；取证的 URL 里 `request_id=` 后面就是空的。

**否掉的原因**：取证里那个 `=` 后面是**动态拼接**（说明它本来是个变量）。
传空等于赌"服务端不校验"；而并发扫码时更需要唯一 id 区分会话。
生成 32 位十六进制不引任何依赖（本批零新增依赖的纪律不变）。

## Consequences

**收益**

- UC 的「登录」从"报错"变成"出二维码"（走 `pan_qr_login_start` → UI 的 `QrView`）。
- 三条 URL 都是纯函数，可离线断言逐字（取证一旦被上游改动会立刻红）。
- 业务码判据与夸克共用一份：两家同族，不会再出现"夸克按码判、UC 按文案猜"的分裂。

**代价与边界**

- **整条链路没有真账号跑过** —— 只做了取证对齐与纯函数门禁。
  失败会如实报"哪一步 HTTP 多少 / 业务码多少"，不伪造成功；
  实机验证按 Owner 的批末统一做。
- UC cookie 的"完整键集"没有真读数基线（夸克有 6 键基线），
  所以这里**不做**关键键告警 —— 宁可少一条日志，也不编一个假的基线。
- 其余 6 家（百度/115/阿里/天翼/迅雷/123/光鸭）仍是"如实未接入"，文案已更准。

## 验证结果（已发生）

```text
cargo test --lib pan_login --release → 23 passed / 0 failed
  新增：uc_token_url_carries_its_own_client_id
        uc_qr_url_matches_the_reference_byte_for_byte
        uc_ticket_url_uses_client_id_381_and_echoes_request_id
        request_id_shape_is_stable_and_unique
  改写：unimplemented_kind_says_so_instead_of_pretending
        （UC 接通后从列表里移除，否则它会去发真网络请求 = 靠网络失败通过的假绿）
故障注入（真红，已实测）：
  ① UC_QR_CLIENT_ID 529 → 532 ⇒ uc_token_url… / uc_qr_url… FAILED
  ② UC_TICKET_CLIENT_ID 381 → 529 ⇒ uc_ticket_url… FAILED
```

## 何时该翻案

拿到 UC 真账号后：把三条 URL 的**真实响应**贴进 `.probe/`，补上"cookie 合法键集"基线
（像夸克那 6 键），并把 `unimplemented_kind_…` 的名单继续缩短。
