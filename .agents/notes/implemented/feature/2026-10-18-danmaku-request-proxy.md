# Agent Note: 弹幕请求走代理 —— 把「时好时坏」变成用户可选项

Status: implemented

> 同域：[2026-10-17-plugin-http-ignored-per-source-proxy.md](../bug-fix/2026-10-17-plugin-http-ignored-per-source-proxy.md)
> 那篇讲「插件 HTTP **读不到**按源配置的代理」——代理配了但没生效；
> 本篇讲「弹幕请求**不属于任何源**，所以按源配置那套根本用不上」。
> 两篇合起来说明：本仓的代理配置是按 provider 维度设计的，
> 而**不挂在 provider 上的请求（弹幕、探活）**需要自己的一套。

## Problem

Owner 的弹幕在国内网络下**时好时坏**，而产品里没有任何地方能改。

实测到的原因链：

```text
本机环境变量 HTTPS_PROXY = http://127.0.0.1:7890/
而 IoDanmakuTransport 改前没有任何 findProxy 设置
⇒ Dart 自己去读环境变量 ⇒ 弹幕请求一直在"偷偷走 7890"

Owner 网络实测：
  *.vercel.app 被 DNS 污染（157.240.2.36 / 199.16.156.39 都是假 IP）
  直连     ⇒ SocketException
  走 7890  ⇒ HandshakeException
⇒ 同一台机器，取决于有没有设环境变量，行为完全不同
```

**这不是"网络不好"，是"行为不可预期"。**

## Decision

### 一、传输层加 `findProxy`，且 `null` 必须显式表达为 `'DIRECT'`

```dart
IoDanmakuTransport({
  HttpClient? client,
  Duration timeout = const Duration(seconds: 15),
  String? findProxy,
}) : _client = client ?? (HttpClient()
      ..connectionTimeout = ...
      ..userAgent = ...
      ..findProxy = ((String? p) => (Uri _) => p ?? 'DIRECT')(findProxy));
```

**为什么 `null` 不能直接不设**：

```text
findProxy 一旦赋值 ⇒ Dart 完全不读环境变量
findProxy 不赋值   ⇒ Dart 可能去读

⇒ 若"直连"用"不赋值"表达：有 HTTPS_PROXY 就偷偷走代理，没有就直连
⇒ 同包不同机器行为不同 —— 这就是"时好时坏"本身
⇒ 要"可预期"必须两者都显式：direct 走 'DIRECT'，system 才用 null
```

### 二、三态 UI，存储不复用 ProxyConfig

设置 → 弹幕源 → 网络代理：直连（默认）/ 跟随系统 / 自定义 + 地址框。

**为什么不复用 `ProxyConfig`**：它是按源（per-provider）存的
（`list_proxy_configs()` / `set_proxy_config(provider, config)`），
而弹幕请求**不属于任何源**。硬塞进 provider 维度会导致
「同一个番换个源看，弹幕代理跟着变」。

⇒ 新开 `dsh.danmaku.proxy.mode` / `.url` 两键。

### 三、SOCKS5 在解析层拒绝

`dart:io` 实测对 socks5 报 `Invalid proxy configuration`，**连连接都不建**。

改前那版把它解析成 `PROXY host:port` ⇒ 用户以为在用 socks5，
**实际是明文 HTTP 代理打到 socks 端口**。静默换协议比明确报错危险得多。

### 四、custom 地址无效时退回**显式 DIRECT**，不是 null

`null` 会"偷偷跟随系统" ⇒ 用户看到"我配了代理却走了别人的代理"，无法排查。

## Alternatives considered

- **把 findProxy 写成必填参数（不允许 null）** —— 它最强的论据是彻底消除
  隐式行为，任何人都必须明确表态。
  否决理由：`system` 这个选项**就是要让 Dart 去读环境变量**，
  用户主动选它时，"读环境"正是期望行为。必填会把这个合法选项也堵死。

- **复用 `ProxyConfig` 按源存** —— 它最强的论据是全仓只有一套代理配置，
  用户心智模型简单。
  否决理由：弹幕不属于任何源（见上）。而且会导致"换源看同一个番，
  弹幕代理跟着变"，这是用户完全无法预期的行为。

- **只加 UI 校验挡 socks5，不改进解析层** —— 它最强的论据是解析层改动风险小。
  否决理由：UI 校验挡不住 `ui-prefs.json` 里的旧值、手工编辑的配置、
  以及未来别的入口。**解析层是唯一必经之路。**

- **超时/失败时静默退回直连** —— 它最强的论据是"至少还能用"。
  否决理由：那会让用户以为代理生效了（实际没有），
  与"把故障伪装成正常"同族。已在实现里改成显式 DIRECT + 专门文案
  （`不支持 socks 代理，请填 HTTP 代理地址`），而不是笼统的"地址无效"。

## Consequences

- **收益**：弹幕请求的行为从"取决于环境变量"变成"用户可选的三种确定行为"；
  且 `CONNECT` 隧道实测确认（不是明文降级）。
- **代价**：多了一层配置（三态 + 地址框）；用户若选 `system` 而系统代理
  对目标不可达，仍会失败 —— 但这次失败是**可解释的**（他自己选的）。
- **已知上限**：
  · 未起真正的 HTTPS target（自签证书），所以证明的是「发起了 CONNECT 隧道」，
    不是「隧道里跑完了一次完整 HTTPS 往返」
  · 代理需要认证（407）时无支持 —— 当前实现没有 proxy 认证
  · 触摸端长按/拖动未验
- **重访条件**：当用户反馈"选了 system 还是不通"时，应提供"诊断"入口
  （显示探针实际走的路由），而不是再加一个选项。
