# Agent Note: 扫码弹窗的网页登录按钮接入同一真源（115 按钮移除收口）

Status: implemented

Independent: 接续 [2026-11-01-pan115-weblogin-retired.md](2026-11-01-pan115-weblogin-retired.md)
——那一篇撤了 115 的网页登录（四家→三家），但当时 `pan_qr_login_dialog.dart:144`
还有**第三份**手抄名单 `_webLoginKinds`（含 '115'）不在改动清单内，扫码弹窗里
那颗按钮仍在（靠兜底弹说明）。本篇把最后半边收掉——"两道闸门只改一道"教训的根治。

## Problem

同一份"哪些盘有网页登录"的知识散在三处（PanWebLoginSpec.all /
pan_settings_page._webLoginKinds / pan_qr_login_dialog._webLoginKinds）。
115 撤除时改了两处，第三处仍在 ⇒ 扫码弹窗给用户看一个**点了必然弹"不支持"**的按钮。

## Decision

```text
① 删除手抄名单，按钮条件改为读 PanWebLoginSpec.of(kind) != null（真源，
   与设置页同源）——从机制上消灭"多处漂移"，而不是再改一次清单。
② 115 等已撤的盘渲染 panWebLoginUnsupportedReason(kind) 原句（指路扫码，
   文案零复制）。
③ quark/uc/baidu 三家按钮 key/置灰判据/showPanWebLogin 回调链路逐字不动。
④ 旧门禁 E2 从"钉半边未同步"改写为"钉已同步"（原断言钉的是要修掉的旧状态）。
```

## Alternatives considered

- **只把 '115' 从第三份名单里删掉**：最小 diff，但三份手抄名单依然并存，
  下次撤/加还得改三处——根因不除。否决，改为同真源。
- **保留按钮、点了弹说明就够**：兜底能防"没反应"，但展示一个注定不可用的
  入口仍是误导。否决。

## Consequences

- 门禁：新文件剥注释断言"弹窗源码零盘种名单字面量 + 必须读真源"（注回手抄
  名单 ⇒ 恰红 2 条，撤销回绿）；三家按钮零变化回归。
- 后续两处过时注释（pan_web_login.dart 文件头、pan_settings_page.dart:314 的
  "下批需同步"）已失去时效，下批顺手更新。

## 教训（延续本批主线）

**同一份知识只允许一个真源**。三份手抄名单让"撤一家"变成三次改动、漏一次
就是可见的不一致。撤除类改动的正确顺序：先建单一真源与公开判据函数，
再把所有消费点改读真源，最后删手抄。
