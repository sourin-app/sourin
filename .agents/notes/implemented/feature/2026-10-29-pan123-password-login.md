# Agent Note: 123 云盘走"账号密码表单"——它本来就没有扫码

Status: implemented

Independent: 与 `2026-10-28-remaining-pans-honest-reasons-not-generic.md` 的结论一致
（123 没有扫码这条路，是**事实**不是"没取证"），本条是把它变成**能用的登录方式**：
表单登录 + FFI 一条新命令 + 设置页一行表单。不改任何扫码实现。

## Problem

Owner：网盘页里 123 只能看到"没有扫码登录"这句话，**没有任何登录入口**。
而 123 官方只有两条路：账号密码（`login.123pan.com/api/user/sign_in`）与 open-api 开发者令牌。
用户要的是"能登进去"，不是"被告知不能扫码"。

## Decision

1. 新模块 `pan_login_123.rs`：`password_login(kind, account, password)`
   - 只收 `PanKind::Pan123`；其它盘在**任何 HTTP 之前**返回明确 Err。
   - 变体① `{"passport":…,"password":…,"remember":true}`（判 `message=="success"`）
     → 失败再变体② `{"mail":…,"password":…,"type":<int>}`（判 `code==200`）→ token 都在 `data.token`。
   - 成功：`cookie = "access_token=<token>"`（沿用 token 型的约定键），在函数内 `pan_auth::save`。
   - 失败：两段响应原文 + 两个 HTTP 码 + 判据名，全部过 `redact()`（服务端回显密码也会被抹掉）。
   - 本文件**没有 write_log**（避免凭据入日志的入口）。
2. FFI 一条命令 `pan_password_login {kind, account, password}`；token **不过 Dart 层**。
3. 设置页：123 那一行展开成"账号/密码（obscureText）+ 登录"，成功后就地刷新状态，失败在按钮下方报错；
   新增 `debugPasswordLogin` 注入点（生产恒 null）让 widget 门禁能离线跑。
4. 扫码下拉**摘掉 123**（它没有码），补上光鸭/迅雷（设备码，确实出码）。

## Alternatives considered

### A. 123 也做 open-api 令牌粘贴框

**最强理由**：open-api 是官方给开发者的正路，令牌比存密码更"干净"。

**否掉的原因**：用户要的是"像别的盘一样登进去"，去申请开发者令牌是另一件事。
密码登录是原版（参考实现 dex 里 `merge.FM.b.C`）就在用的路，先对齐原版。
令牌粘贴可作为后续选项，本轮不做（不引入第二个凭据来源）。

### B. 拿 `open-api.123pan.com/api/v1/user/info` 当"登录成功"的闸门

**最强理由**：能验证 token 真的可用，比"拿到 token 就算成功"更硬。

**否掉的原因**：web 会话 token 是否被 open-api 接受**没有证据**。
拿它当闸门会把"其实登上了"判成失败（本仓反复出现的"用错判据把成功判死"）。
⇒ 只保留纯判定函数 `user_info_ok()`，不串进登录链。

### C. 把密码存下来（记住密码）

**最强理由**：用户不用每次输。

**否掉的原因**：凭据只该进系统钥匙串，且 access_token 已可续期；存明文密码是纯粹的风险。
（参考实现确实往 `/cloud123.txt` 写了 `userName/passWord` —— 那一条**明确不学**。）

## Consequences

**收益**

- 123 从"只能看一句话"变成**能登录**；登录态与其它盘一致（钥匙串 + `status_of`）。
- 表单只在 123 那一行出现（门禁钉住"其它盘不许出现密码框"）。
- 密码不进日志、不进错误文案、不过 Dart 层（三重门禁）。

**代价与边界**

- 变体② 的 `type` 整数**未取证**（dex 只看到 `Integer.valueOf(<某 int>)`）⇒ 收敛成单一常量
  `MAIL_LOGIN_TYPE = 1`，门禁钉"它进了报文且形状逐字"，**不钉"1 一定对"**；真机若否只改这一处。
- 两套报文哪套现行**没有账号密码，无法真跑**；首跑失败会把两段原文摊出来，一眼能判。
- 成功判据是 `message=="success"` / `code==200`（dex 两套各一个），不做额外校验。

## 验证结果（已发生）

```text
cargo test --lib pan_login_123 --release → 13 passed
flutter test test/zz_pan123_password_login_test.dart → 9 passed
（我自己复跑过两条命令，不是只看执行者汇报）
门禁重点：报文逐字（含 true 字面量）、两套判据、redact（错误里不许出现密码）、
         其它盘在任何 HTTP 之前拒绝、空字段拒绝、凭据用 access_token= 约定键。
故障注入（子任务实测 7 处，红/绿原始输出已留）：
  ① remember:true→1 ② message 判据放宽 ③ 去掉 redact
  ④ Dart 去掉 obscureText ⑤ 表单挂到所有盘 ⑥ 成功后不刷新状态 ⑦ kind 传错
```

## Relations

- 123 没有扫码这条路（结论未变）：
  [./2026-10-28-remaining-pans-honest-reasons-not-generic.md](./2026-10-28-remaining-pans-honest-reasons-not-generic.md)
- token 型凭据的约定键：
  [./2026-10-28-aliyun-qr-login-and-token-shape.md](./2026-10-28-aliyun-qr-login-and-token-shape.md)