# Agent Note: 115 网盘撤掉「网页登录」+ 修四家网页登录的静默失败

Status: implemented

Independent: 接续 [2026-10-31-pan-webview-login.md](../feature/2026-10-31-pan-webview-login.md)
（W1 建了网页登录通道；本篇是它的**边界收口**：发现其中一家架构上走不通并如实撤除，
同时修掉该通道共有的静默失败）。

## Problem

Owner 报：「115 已登录但是没反应」。现场物证（另一路判读）：「网页登录115 网盘」
弹窗转圈、无错误行，背后 WebView 标题「115科技官网_首页」——停在官网首页。

## Root cause（三链证据，决定性的是第 1 条）

```text
① 决定性：115 的登录凭据形状与网页 cookie 不同源。
   · csp/pan115.rs:449 is_logged(cookie) => cookie.contains("UID=")（DEX 逐字 [logged]，
     有测试钉住：只认 UID=；CID/SEID 那半截判未登录）。
   · UID/CID/SEID/KID 的唯一来源是**扫码换 cookie 的响应体**
     （pan_login.rs:1658 pan115_cookie_from_body 从 POST ...login/qrcode/ 的 JSON 里取出
     拼成字符串）——不是浏览器 cookie store 的键。
   ⇒ 网页登录**产出不了含 UID= 的凭据**；即使捕获成功并存盘，is_logged 仍判 false
     ⇒ 那是"存了却显示未登录"的**读数说谎**（本批反复判为缺陷的形态）。
② 入口错：代码配的 https://www.115.com/ 实测是 357 字节 JS 跳壳页（<script>location.href=
   "https://115.com"</script>）⇒ 跳到官网首页（36KB，title「115科技官网_首页」，
   登录框只是首页 JS 弹层，无独立登录页；passport.115.com 也 302 回跳壳页）。
③ 登录态键名：未取证到，如实标注不编造（无账号、不该在空窗开 webview 点登录框）。
```

## Decision

```text
① 115 撤掉「网页登录」入口（四家→三家），并给出**如实原因 + 指路扫码**
   （panWebLoginUnsupportedReason：UID 形状对不上 + 用扫码登录）。
② 修静默（四家通用，与①解耦）——这是独立缺陷：
   等待弹窗原来判据不过/拼串失败都静默 return，只有"转圈 + 会自动保存"的空头承诺，
   可无限转（现场 07:00:53→07:06 一直转、零错误行）。
   ⇒ 6s 起给缺键 hint（还缺哪个键、在哪个域）/ 无 cookie 直说"多半没进登录页"；
      90s 超时给终态错误 + 停表；拼串失败显式报错；终态时不再转圈、按钮变「关闭」。
③ showPanWebLogin 的 spec==null 从静默 return false 改成弹如实说明对话框
   ——"点了没反应"的同款缺陷不再可能出现。
```

## Alternatives considered

- **保留 115 并改判据（猜一个键名）**：判据必须落在客观事实上；无账号取不到证，
  且即使拿到键名也产不出 `UID=`。硬凑就是编造 + 制造"存了却说没登录"。否决。
- **改 Rust 侧 is_logged 去适配网页 cookie**：会动 115 的登录语义与既有 DEX 判据，
  属另一个命题。立下批项，本批不做。
- **只撤按钮、不修静默**：静默失败本身是缺陷（"点了没反应"），且四家共有。否决。

## Consequences

- 门禁：新文件 `test/t20261101_pan_web_login_115_test.dart` **19/19**（无 native-media
  标签 ⇒ 全量默认真跑）；同步更新旧文件 `pan_web_login_test.dart` 三条（四家→三家）；
  `flutter analyze` errors=0/warnings=0。
- 证红 4 组真跑：① 把 115 加回 ⇒ 红 3 条；② showPanWebLogin 退回静默 return ⇒ 红 1 条；
  ③ 去掉 hint ⇒ 红 1 条；④ URL 退回官网首页 ⇒ 由 A4 覆盖。均还原复绿。
- **★ 防"改一半"（本批踩过两次的坑）**：`pan_qr_login_dialog.dart:144` 仍有**第二份**
  `_webLoginKinds`（含 115），不在本次清单 ⇒ 扫码弹窗里那颗按钮还在。已靠兜底
  （spec==null 弹说明而非静默）保证点击有反馈，并用 E2 门禁**把"半边未同步"显式登记**
  ——不假装只有一处。下批应改为读 `PanWebLoginSpec.all` 同真源。
- 三家（quark/uc `__pus/__kps`、baidu `BDUSS`）网页登录不受影响，仍可用（其登录态键
  是网页真实键）。

## 边界（如实）

- 115 网页版登录后实际 cookie 名与域**未取证**；门禁里零个 115 键名断言，无编造。
- 要真正把 115 接入网页登录，需先改 Rust 侧映射（is_logged / 凭据形状）——下批项。
- 未做真机验证（按分工，lead 批末部署后验收；本次部署时桌面不可见，UI 取证受限）。
