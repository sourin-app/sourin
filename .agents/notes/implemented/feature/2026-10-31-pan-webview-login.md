# Agent Note: 网盘网页登录（webview 回调）—— 手机不在手边也能登录

Status: implemented

后续局部更新：[独立登录弹窗与本地识别](../bug-fix/2026-11-04-pan-login-modal-and-local-recognition.md)
补齐有界失败、取消与保存后状态回读。本文原生 CookieManager 和保存入口决定保留；
本地成功回读不证明远端会话有效。

Independent: 与 [2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md](../bug-fix/2026-10-30-pan-login-t5-aliyun-bizext-115-cookie-baidu-unicast.md)
（扫码登录协议修复）互补不冲突——那篇管"扫码链路通不通"，本篇加的是
**第二条登录路径**（网页登录回调），保存入口复用同一个 pan_auth::save。
与 2026-10-31-aliyun-bizext-lossy-and-body-dump.md（bizExt 解码）也无关
（阿里不放网页登录入口，注释在案）。

## Problem

Owner 原话（逐字）：「还有这些应该都要支持webview登录回调的，不然如果是在手机上
怎么扫码？」——扫码登录要求"第二台设备扫第一台设备上的码"，桌面端用户手机
不在手边就登不了。网页登录（在 App 里打开网盘网页版直接登录）是标准替代路径。

## Decision

`desktop_webview_window 0.4.0`（精确锁版，pubspec.lock 钉 sha256）+
四盘网页登录（quark/uc/115/baidu）：

```text
· 独立原生登录窗口（自带标题栏），关窗=取消；WebView2 Runtime 探测
  （isWebviewAvailable）失败 ⇒ 按钮置灰 + 装哪里的人话提示
· 2s 轮询 getAllCookies（原生 CookieManager，HttpOnly 键可取——
  __pus/__kps/BDUSS 全是 HttpOnly，document.cookie 读不到，这是选型命门）
· 登录态判定纯函数：目标域 + 登录态键逐字存在
  （quark/uc=__pus/__kps、baidu=BDUSS、115=UID/CID/SEID/KID）
  ⇒ 命中即走新增 FFI 命令 pan_save_credential(kind, account, cookie) 落盘
· 保存唯一入口仍是 pan_auth::save（薄封装只加 kind 白名单 + 非空校验 +
  一行脱敏日志；天翼/阿里/123/光鸭/迅雷逐家注明该走哪条路）
```

- cookie 捕获/键判定/拼接全为纯函数（16 条单测，假夹具）。
- 判据键名取自仓内既有真读数（夸克 6 键基线、115 四键验收判据、百度 BDUSS 判据），
  四家入口页真开取证过 pre-login Set-Cookie 形状——quark/uc 的 pre-login
  `ctoken` **故意不进判据**（否则未登录也算登录成功 = 假绿）。
- 不放入口的两家（注释在案）：天翼=出码链路本就做不完整（4.4 如实报）；
  阿里=网页登录态映射不到本仓的 access_token 形凭据（其登录走 bizExt 扫码链）。

## Alternatives considered

- **webview_flutter_windows 1.3.0（fork）**：内嵌 widget 形态、getCookies(url)
  按域过滤更顺手；但单人维护 fork（4 likes/8k downloads）bus factor 低。备选保留。
- **flutter_inappwebview**：Windows 实验性，getCookies 空列表修复史（#2314）+
  至今 open 的 Windows cookie issue（#2783），依赖最重。排除。
- **官方 webview_flutter**：无 Windows 实现。排除。
- **JS document.cookie 捕获**：HttpOnly 键读不到 = BDUSS/__pus 全漏。否决
  （必须原生 CookieManager——选型命门）。

## Consequences

- 门禁：flutter analyze errors=0；`test/pan_web_login_test.dart` 16 条
  （判据键逐字、label 边界、多域混入只取目标域、同名后到覆盖、注入键丢弃、
  空值不许冒充成功）；Rust 侧 web_login_gate 4 条；
  `cargo test --lib --release` 1944/0（含 K1 隔离修复的 +1）。
- 证红：判据/注入用例全红过（label 边界、短路注入）。
- 手动验收步骤（Owner）：设置→网盘账号→四盘任一行「网页登录」⇒ 弹独立浏览器窗
  → 网页里登录 ⇒ 弹窗显示"登录成功"并自动关 ⇒ 该行变已登录；不登录直接关窗=取消。
  首次构建需访问 api.nuget.org 拉 WebView2 SDK；机器需 WebView2 Runtime（Win11 自带）。
- 日志验证口径：[PAN] 网页登录凭据已落盘 kind=… 摘要=N 个键（M 字节）——只有键名与长度。

## 边界（如实）

- getAllCookies 返回 profile 全量 cookie，域过滤在纯函数里做（有单测）。
- 0.4.0 是两周前的大版本：精确锁版防 API 漂移；升级需重新核对 cookie API。
- 网页登录期间该原生窗口持有焦点，属预期交互。
