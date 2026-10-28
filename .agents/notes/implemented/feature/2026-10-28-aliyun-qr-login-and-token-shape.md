# Agent Note: 阿里云盘扫码接通 —— 顺带定下"token 型网盘"的凭据约定键

Status: implemented

Independent: 本条同时做两件事：①阿里云盘的扫码登录；②为**第一个非 cookie 凭据**
（bearer token）定下落盘约定。②是架构决定，与 `pan_auth` 的既有契约直接相关，
但**不改**那条契约的形状（这正是选择的结果，见 Alternatives A）。夸克/UC/百度/115
那些 cookie 型网盘的行为一个字都没动。

## Problem

Owner：「其余 7 家网盘登录扫码能出二维码」。阿里点「登录」时只有"尚未接入"。
而阿里云盘的凭据是 **bearer token**（`access_token`/`refresh_token`），
不是 cookie —— 直接套用现有 `PanCredential.cookie` 的语义会埋一个"名字骗人"的坑：

```text
改前：PanCredential { kind, account, cookie: String, saved_at, expires_at }
阿里/光鸭/迅雷/123 的凭据都不是 cookie ⇒ 存什么、消费方怎么读，没有任何约定。
```

## Decision

### 1. 扫码头三跳（端点与报文形状**都已逐字取证**）

```text
① 取码  passport.aliyundrive.com/newlogin/qrcode/generate.do
        ?appName=aliyun_drive&fromSite=52&appName=aliyun_drive&appEntrance=web
        &isMobile=false&lang=zh_CN&returnUrl=&bizParams=&_bx-v=2.2.3
        → content.data{qrCodeUrl, ck, t}
② 轮询  passport.aliyundrive.com/newlogin/qrcode/query.do
        ?appName=aliyun_drive&fromSite=52&_bx-v=2.2.3   （表单 ck + t + _bx-v=2.2.3）
        → content.data.qrCodeStatus：NEW / SCANED / CONFIRMED / EXPIRED
③ 取凭据 CONFIRMED 的响应里 `bizExt` = **base64 的 JSON**，
        内含 pds_login_result.{access_token, refresh_token, expires_in}
```

★ 报文形状的出处（2026-10-28 晚补）：参考实现 dex 的
`com.github.catvod.spider.merge.m.G.buildAliQrInfo` 与
`merge.C0.h.b.e`（query.do），逐字 dump 得到 —— **不再依赖社区通行实现**。

**因此改正了两处偏差**：原实现按社区实现写成 `_bx-v=2.5.3`，且缺
`isMobile/lang/returnUrl/bizParams`。这类偏差**不会报错**，只会让服务端返回另一套字段
（典型的"看起来在跑、其实参数不是逐字"）。门禁也从 `starts_with` 收紧为**逐字全等**。

### 2. 凭据约定（本条最重要的决定）

```text
token 型网盘统一写成：`access_token=<…>; refresh_token=<…>` 存进 PanCredential.cookie。
消费者（将来的阿里驱动）按 `access_token=` 取，**不许**把它当 Cookie 头直接发。
`expires_at` 用响应的 `expires_in` 换算（这类 token 有明确有效期，与网盘 cookie 不同）。
```

### 3. 自己写 base64 解码

`bizExt` 是标准 base64（含 `=` 填充），本仓没有 base64 依赖 ⇒ 20 行自带实现 + 一条
与标准结果对照的门禁（期望值用 Python base64 独立算出，不是拿被测函数反推）。

## Alternatives considered

### A. 给 `PanCredential` 加字段（`token: Option<String>` 或 `secret_kind`）

**最强理由**：语义最正确 —— 凭据是 token 就说 token，不必让 `cookie` 这个字段名骗人。

**否掉的原因**：那是**改落盘形状**。牵动四处：钥匙串条目格式（已有凭据要兼容读）、
`pan_auth::load()` 的返回、设置页的登录态展示、诊断导出（它按字段名脱敏）。
换来的收益只是"命名准确"，而命名问题用**约定键**就能覆盖，且随时可升级：
将来真要加字段，把 `access_token=` 约定升级成结构字段是一次可回退的迁移
（旧值能解析出新结构），反过来（先改结构再想兼容）成本更高。

### B. 加 `base64` crate

**最强理由**：不自己写编解码，少一处可能写错的算法。

**否掉的原因**：本批纪律是零新增依赖；解码只服务 `bizExt` 一处，20 行 + 一条对照门禁
已经足够（对照用的是独立算出的期望值，不是自证）。

### C. 只出二维码，不做 token 交换（等有消费方再说）

**最强理由**：现在没有阿里驱动，存下来的 token 也没人用 —— 看似无用功。

**否掉的原因**：①Owner 的验收是"扫码能登"；只出码不给凭据，用户扫完确认后
什么也不会发生（比"未接入"更糟：它看起来像成功了）；②凭据落盘正是"以后接取数"的**前提**，
先有存储再有消费方，是这类多网盘功能的正常顺序（夸克/UC/百度/115 都一样）。

### D. 忽略 bizExt，直接调 `auth.aliyundrive.com/v2/account/token`

**最强理由**：这条端点是取证里明确有的，用它更"有据"。

**否掉的原因**：那条接口要 `code`（而 code 只在 bizExt 里）+ 一个 `client_id`
（取证里**没有**）。放着现成的 access_token 不用，去凑两个未知参数，是用更多的猜测
换更少的确定性。

## Consequences

**收益**

- 阿里从"报错"变成"出二维码 + 扫完能拿到 bearer token 并落钥匙串"。
- 定下了 token 型网盘的统一约定（光鸭/迅雷/123 可以直接复用，不必各自发明一种存法）。
- 自带 base64 解码是通用件，`bizExt` 之外的 base64 报文（如某些盘的 `data` 字段）也能用。

**代价与边界**

- **报文形状未真验**（端点是取证，形状是社区通行实现）。失败会如实报字段缺失/HTTP 错误。
- `account` 写死"阿里云盘"（没有稳定的昵称接口取证）。
- `access_token` 的消费方还不存在 —— 这一条的交付边界是"凭据能拿到、能存、能读"，
  不是"阿里网盘文件能列出来"。
- `refresh_token` 也一起存了，将来续期不必让用户重扫；但它同样是敏感值，
  只进钥匙串（`pan_auth` 的既有约束）。

## 验证结果（已发生）

```text
cargo test --lib pan_login --release → 35 passed / 0 failed
  新增：aliyun_urls_match_the_documented_flow   （appName/fromSite/三个主机）
        b64_decode_matches_standard             （与 Python base64 独立算出的值对照）
        aliyun_status_maps_enums                （NEW/SCANED/CONFIRMED/EXPIRED）
        aliyun_token_from_biz_ext               （base64 JSON 取 token；缺 access_token 必报错）
        aliyun_credential_uses_the_agreed_keys  （约定键名，不是 Cookie 头）
故障注入（真红，已实测）：
  ① base64 的 `A..Z` 映射改成 `c - b'B'` ⇒ b64_decode_matches_standard FAILED
  ② bizExt 的层级 `pds_login_result` 改成 `pds_login` ⇒ aliyun_token_from_biz_ext FAILED
```

## 何时该翻案

1. 真机扫码拿到读数后：核 `bizExt` 的层级与 `expires_in` 的存在性，改
   `aliyun_token_from_body` 一处即可。
2. 若将来 `pan_auth` 决定给 `PanCredential` 加结构字段：把 `access_token=` 约定
   迁成字段（保留"能读旧值"的兼容分支），并同步改光鸭/迅雷/123 的写入点。

## Relations

- 同批的 cookie 型几家（供对照，凭据形状完全不同）：
  [./2026-10-28-uc-qr-login-same-cas-different-ids.md](./2026-10-28-uc-qr-login-same-cas-different-ids.md)、
  [./2026-10-28-baidu-qr-login-passport.md](./2026-10-28-baidu-qr-login-passport.md)、
  [./2026-10-28-pan115-qr-login-four-key-cookie.md](./2026-10-28-pan115-qr-login-four-key-cookie.md)