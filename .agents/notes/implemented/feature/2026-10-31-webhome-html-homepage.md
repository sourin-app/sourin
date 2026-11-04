# Agent Note: 首页 HTML 自定义（webHome V1）—— 用户可粘贴 HTML 美化首页

Status: implemented

后续局部更新：[设置页多模板管理](2026-11-04-settings-owned-html-home-library-and-source-filters.md)
取代首页配置入口及单 HTML 存储形态，兼容迁移旧文件；本文渲染、白名单桥、
网络安全和原生回退决定继续有效。

Independent: 机制底稿 = [reference-apk-benchmark](../../../../.probe/reference-apk-benchmark.md)
第⑥节（FongMi fork 的 webHome 子系统逐字取证）；渲染栈 = 本批
[pan-webview-login](2026-10-31-pan-webview-login.md) 引入的 WebView2 家族。
设计书 .probe/t6-homepage-html-design.md、实机探针 .probe/t6-webview-probe-report.md。

## Problem

Owner（逐字）：「他还有个功能我想要,就是可以自己实现首页用html自己美化,你看看
这个我们呢工作能做到吗」。可行性裁决：能做到——desktop_webview_window 0.4.0
是独立窗形态不能内嵌（源码级核实 WS_OVERLAPPEDWINDOW 宿主），引
flutter_inappwebview 6.1.5（windows 0.6.0）内嵌 widget，实机探针三件事全 PASS
（内嵌渲染交互/双向桥 50 回环零失败 2.2ms/与 DWW 共存），cookie HttpOnly 两
issue 在 0.6.0 已修复（顺带核实）。

## Decision

```text
V1 切口（最小可用）：粘贴/本地 HTML → 内嵌 InAppWebView 渲染 → fm 六方法
白名单桥（playVod/openLive/net.request/cache 三件/log/toast）→ 原生/HTML
双模式自动回退（加载失败/8s 白屏看门狗 ⇒ 本次会话回退原生 + 常驻回原生按钮）。
安全：net.request 两段 SSRF（字面量 + DNS 解析后逐 IP 复判，2MB 响应上限
+ 20s 超时）；N3b 起连接只拨**校验过的那批 IP**（connectionFactory 直连），
解析与连接同源——DNS rebinding TOCTOU 闭合；console 五级劫持落 AppLog
（凭据零打印：仅 method+host+path）；webHome profile incognito 强隔离（探针实证纯内存
不落盘，含持久 cookie）；HTML 来源粘贴/本地路径，零新依赖。
六项明确不做：扩展引擎/站点级 webHome/远程 URL/资源服务器/inline 播放/
分块回传——V1 之后按需立项。
```

## Alternatives considered

- **desktop_webview_window 重父化 hack**：API 文档灰色地带，z-order/DPI/生命
  周期全是脆点。备胎保留。否决。
- **独立窗当首页**：首页是主 Tab，独立窗形态 UX 不成立。否决（但桥协议第
  0 步先在独立窗打通——探针就是这么做的）。
- **原生渲染 HTML 子集**：自写 HTML 解析/渲染 = 重造浏览器。否决。

## Consequences

- 架构门禁整改（批末全量抓到，如实记）：webhome 初版 import material.dart /
  用 SnackBar / 异常原文进用户字段，违反玻璃体系三门禁
  （theme_regression/r7/glass_toast/user_error_text）——已改
  material_ui.dart + showAppToast + userErrorText 收口，6 门禁全绿。
  教训：新文件也要过"体系门禁"，不能只看 analyze。
- SSRF 对抗验证（复核人六类攻击全拒）+ 互检打回补齐：三负例形态显式化
  （尾点归一/十进制整型展开/IPv4-mapped 按 rawAddress——不再依赖 tryParse
  实现细节的"意外 fail-closed"）；incognito 探针实证（"纯内存不落盘"从
  断言变证据）；"防 DNS rebinding"措辞降级为"收窄 TOCTOU 窗口，未闭合"
  （按解析 IP 直连为下批项，威胁模型自洽：HTML 用户自写）。
- 门禁：test/t20261031_webhome_pure_gate_test.dart 22/22（含证红）；
  analyze webhome = No issues found。
- N3b TOCTOU 闭合（2026-11-01，Lead 批复，取代上一条的"收窄未闭合"措辞）：
  net.request 连接实现从 webhome_page 整体迁入 lib/ui/webhome/fm_net_request.dart，
  HttpClient.connectionFactory 只拨**校验过的那批 IP**——解析与连接同源、
  无第二次 DNS，rebinding 窗口闭合。两个 SDK 层实锤否决项：①
  connectionFactory 路径 SDK 对返回 socket **不做 TLS 升级**，而
  SecureSocket.startConnect(IP) 会拿 IP 当 SNI/校验主机名、真域名证书必挂
  ⇒ https 改为裸拨 IP 后 SecureSocket.secure(raw, host: 原域名)（SNI/证书
  校验保持按真域名）经 ConnectionTask.fromSocket 包回（Dart 3.13 稳定线
  API，文档原文即为此场景）；② 备胎本机 127.0.0.1 CONNECT 中继已论证但
  未启用（fromSocket 可用，无需中继）。
- ★ 有意行为收紧（Lead 批复，N3b）：net.request 显式 findProxy=DIRECT，
  不再读 HTTP_PROXY/HTTPS_PROXY 等 env 代理。理由：本机长期挂
  HTTP_PROXY=127.0.0.1:7890，走代理意味着校验通过后由代理二次解析/重绑，
  "校验 IP = 连接 IP"被架空（与 t69 假红事故同源）。net.request 从此是
  确定性直连通道。
- N3b 门禁：test/t20261101_webhome_net_dial_test.dart 6/6——行为断言为
  "拨号口（Socket.startConnect 第一参）恒为已验证 InternetAddress、
  hostname 字符串零出现"（IOOverrides 拦截 + 本地 ServerSocket 承接）；
  rebinding 注入（首调 8.8.8.8/次调 10.0.0.1）证绿、legacy 对照（hostname
  交还拨号口）跑同一断言证红；解析与连接全链路只解析一次。
  t20261031 纯函数门禁 22/22 全保留；analyze 本批文件零告警。
- 真机渲染的产品路径留批末 T11 验收（纯函数门禁 + 编译已闭环）。

## 边界（如实）

- V1 的 HTML 沙箱边界 = WebView2 进程隔离 + incognito + 白名单桥；
  HTML 作者即用户本人，威胁模型自洽。
- net.request 的 DNS rebinding TOCTOU 已由 N3b 闭合（解析与连接同 IP，
  connectionFactory 直连）；net.request 不走 env 代理（DIRECT，有意收紧）。
- 与原生首页的关系是双模式切换，原生首页是回归底线，不是被替换。
