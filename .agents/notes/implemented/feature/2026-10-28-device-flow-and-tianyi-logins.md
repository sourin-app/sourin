# Agent Note: 光鸭/迅雷/天翼的登录接通了 —— 上一轮"做不了"的三条结论全被推翻

Status: implemented

Independent: 本条**推翻** [./2026-10-28-remaining-pans-honest-reasons-not-generic.md](./2026-10-28-remaining-pans-honest-reasons-not-generic.md)
的四条判断中的三条（光鸭/迅雷/天翼），并保留第四条（123 没有扫码）。
推翻的**不是**"如实说原因"这条纪律，而是那三条**事实依据**：
它们来自一次有缺陷的 dex 取证（工具漏报）+ 一次过度推断（把提示文案当协议证据）。

## Problem

上一轮收尾时剩下四家没接通，笔记里写下的理由是：

```text
光鸭  缺 client_id/scope
迅雷  缺"申请设备码"的端点
天翼  要网页登录（logbox + callbackUnify），核心没有内嵌浏览器
123   只有 open-api 令牌（这条后来确认不完整，但结论对：没有扫码）
```

本轮重新取证后，三条依据被逐一推翻：

1. **工具缺陷（根因）**：`.probe/r3c-dexstrings.py` 的 dalvik 指令长度表有 **12 处错**，
   且不跳过 `packed-switch` / `fill-array-data` 的 payload ⇒ 逐条指令**错位** ⇒
   `const-string` 被静默漏掉。修好后对齐率 99.69%（34320/34426），
   迅雷 `device/code`、光鸭 `client_id/scope` 立刻现形。**"没有证据"当时其实是"工具没读到"。**
2. **天翼的"必须 webview"是过度推断**：依据是用户可见文案（`189tip` 里提到"用浏览器扫描二维码"）。
   但 dex 里 `merge.b.l.k()` 是纯 HTTP 三跳，二维码内容由 `URLDecoder.decode(encodeuuid)` 本地拼出，
   **没有任何 WebView/CookieManager 调用**。文案 ≠ 协议。
3. 123 的结论**保留**：`login.123pan.com` 下全池只有 `api/user/sign_in`（账号密码，两套报文），
   `qrcode` 相关 22 条命中逐条核对无一条属于 123 ⇒ "没有这条路"是事实。

## Decision

### 1. 新增两个模块（不是一个模块硬塞）

```text
rust/sourin_core/src/pan_login_device.rs   光鸭 + 迅雷（OAuth device flow）
rust/sourin_core/src/pan_login_tianyi.rs   天翼（logbox uuid 扫码）
```

理由：这两族与 `pan_login` 里那五家（CAS / passport / 115 / 阿里）**结构不同**，
而且它们**自己管会话表**：
- device flow：`start` 拿 `verification_uri_complete` + `device_code`，`poll` 用 `device_code` 换 token；
- 天翼：`start` 走三跳拿 `encodeuuid` 并本地解码成二维码，`poll` 用 11 个逐字表单参数查状态。

### 2. 光鸭/迅雷合并成"一条 core + 一张 spec 表"（**只对这两家**）

`buildGuangyaQrInfo` 与 `buildXunleiQrInfo` 的**指令结构逐条同形**（都是 73 insns），
差异只有 UA / client_id / scope / 两个端点 ⇒ 这符合本仓"一份实现 + N 份数据"的先例（`PanDrive`）。
**不**把五家 CAS/passport 也并进来 —— 它们的差异是结构性的（换 cookie 次数、确认信号来源都不同）。

### 3. 分流必须发生在"查本模块会话表"之前

```text
pan_login::qr_login_poll 开头那段"这个 key 在 SESSIONS 里吗/超时了吗"查的是**它自己的**表。
新增两族的 key 不在其中 ⇒ 会被判 Expired，**一次 HTTP 都不会发生**
（现场表现："刚出码就过期"）。
⇒ 用 is_device_flow(kind) / is_tianyi_login(kind) 在检查之前分流，落盘仍走同一入口。
```

### 4. 凭据解码表补齐（"存得进、读不出"）

`pan_auth::decode` 的 match 原来没有 `guangya`/`xunlei` ⇒ 凭据能写进钥匙串、
`load` 永远 `None` ⇒ UI 永远显示"未登录"。已补，并加门禁
`every_code_roundtrips_through_decode`（对**所有** code 都 round-trip，防止将来再漏一家）。

### 5. 123 保持"没有扫码"，且不再用"尚未接入"的措辞

它是**没有这条路**，不是"还没做"——两者对用户的含义完全不同。

## Alternatives considered

### A. 沿用上一轮的做法：既然没证据就继续如实说"做不了"

**最强理由**：上一轮的决定本身就是"不猜"，符合纪律；改动成本为零。

**否掉的原因**：那三条依据是**错的**（工具漏报 + 文案当协议）。
"不猜"的前提是"真的没有证据"；本轮证据已经取到，再不做就是**用纪律当借口**。
更具体的代价：天翼那句"没有内嵌浏览器"会把一家**能做**的网盘永久排除在功能之外。

### B. 给核心内嵌 WebView 来做天翼

**最强理由**：如果天翼真的只能网页登录，那是唯一能完成的路。

**否掉的原因**：dex 证明不需要 —— 天翼是纯 HTTP 的 uuid 扫码。
内嵌浏览器是架构级改动（进程模型/打包体积/各平台差异），为了一个不存在的需求去做它，
是**把推断当事实**导致的过度工程。

### C. 光鸭/迅雷也各写一份（不共用一个 core）

**最强理由**：两家各自独立，改一家不影响另一家，读代码不用跳表。

**否掉的原因**：两家的 **73 条指令逐条同形**，只有 4 个值不同。写两份的必然结果是
"改了一处忘了另一处"（本仓已有先例：夸克/UC 的 `_size` 串了那次）。
⇒ 用 spec 表，并用门禁把"两家的值必须不同"钉住（`xunlei` 的两个 client_id 不同、
`guangya` 的 client_id 逐字等）。

### D. 给 123 画一个二维码（哪怕是 open-api 授权页）

**最强理由**：Owner 要"7 家都能出二维码"，画一个至少 UI 齐了。

**否掉的原因**：123 没有任何扫码端点，画出来的码**扫了必然无效**。
这不是"实现取舍"，是伪造。保留"没有这条路"的说明，并指出它实际有的两条路
（账号密码 `sign_in` / open-api 令牌）。

## Consequences

**收益**

- 9 家网盘里 **8 家能出二维码**（夸克/UC/百度/115/阿里/光鸭/迅雷/天翼）；
  第 9 家（123）如实说明没有这条路。目标里"其余 7 家"实际达成 **7/8**，第 8 家不存在。
- 设备码两家的 `verification_uri_complete` 也编成二维码 —— 那是这类流程本来就该做的事，
  与"画一个假码"性质不同（用户扫的是服务端给的真链接）。
- 取证工具修好后，同类"漏报即结论"的错误不会再犯（对齐率自检留在 `.probe/`）。

**代价与边界**

- 三家的**整条链路都没有真账号跑过**；失败一律带 HTTP 码 + 响应摘要。
- 推断项（逐条标在代码注释与门禁里）：
  设备码族 `interval`（RFC 8628 的 5s）、四个错误串语义、`expires_in` 缺失时的本地 300s 兜底；
  天翼的轮询间隔（2s）、`status` 非 0 语义、`clientType="appId"` 这个可疑值（逐字保留 + TODO）。
- 天翼的 `getAccessTokenBySsKey` **没做**：签名算法未取证，只留 TODO，没编签名。凭据 = 会话 cookie。
- 天翼回调链是**手动走跳 + 每跳收 Set-Cookie**（reqwest 未开 `cookie_store`，跟随会丢中间跳的 cookie）。

## 验证结果（已发生）

```text
cargo test --lib --release → 1875 passed / 0 failed / 79 ignored
  pan_login_device  18 条（端点/client_id/scope/请求体整串/头部最小集/RFC 三态/会话 peek/摘要脱敏）
  pan_login_tianyi  21 条（5 端点逐字+浏览器 id 三处同源 / 11 个表单键 / url_decode 正反例 /
                          Location 解析与"没 Location 就大声报错" / 手动跳转解析 / 会话 peek）
  pan_login         36 条（含 123 的"没有扫码"文案、三族路由判据）
  pan_auth          12 条（含 every_code_roundtrips_through_decode）

故障注入（全部真红，原始输出见各模块注释与提交说明）：
  device：guangya client_id 末位改错 → 2 红；xunlei 两个 client_id 改成相同 → 2 红；
          还原"用 verification_uri 拼一个"的回落 → 1 红
  tianyi：clientType appId→1 → 1 红；删掉 redirectUrl 非空判据 → 1 红（left: Confirmed("")）
  wiring：123 文案改成"尚未接入" → 1 红；decode 删掉 xunlei 分支 → 1 红；
          aliyun `_bx-v` 改回 2.5.3 → 1 红
```

## Relations

- 被本条推翻的三条判断：
  [./2026-10-28-remaining-pans-honest-reasons-not-generic.md](./2026-10-28-remaining-pans-honest-reasons-not-generic.md)
  （该文仍有效的是"123 没有这条路"与"逐家说清区别"这条纪律）
- token 型凭据的约定键（光鸭/迅雷沿用）：
  [./2026-10-28-aliyun-qr-login-and-token-shape.md](./2026-10-28-aliyun-qr-login-and-token-shape.md)
- 取证与工具缺陷的完整读数：`.probe/pan-login-evidence-remaining.md`（754 行，逐条带出处）