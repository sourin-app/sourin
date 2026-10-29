# Agent Note: 百度二维码是**一张图片**，而且 unicast 是长轮询

Status: implemented

Independent: 与 `2026-10-28-baidu-qr-login-passport.md` 是同一条链路的**两处硬错**：
那条的流程骨架（getqrcode → unicast → qrbdusslogin）没错，但**报文形状**全错了 ——
当时按"`data.channel_id` + `data.url`（二维码文本）"实现，真接口两样都不给。
本笔记是事实更正 + 两条新读数，不改那条笔记里的协议顺序。

## Problem

Owner 现场：点百度「获取登录二维码」→ 报"字段不全"，根本出不了码。

真读数（2026-10-29，curl 逐字）：

```text
GET https://passport.baidu.com/v2/api/getqrcode?lp=pc&qrloginfrom=pc
→ {"imgurl":"passport.baidu.com/v2/api/qrcode?sign=<32位hex>&lp=pc&qrloginfrom=pc",
   "errno":0,"sign":"<32位hex>","prompt":"登录后…"}
```

⇒ 百度给的是**一张 PNG 的地址**（`imgurl`，**无 scheme**），不是二维码文本。
旧实现找 `data.channel_id`/`data.url` ⇒ 恒"字段不全"。

第二条新读数：

```text
GET https://passport.baidu.com/channel/unicast?channel_id=<sign>&v=<sign>
  curl -m 30  →  (28) Operation timed out with 0 bytes received
带 getqrcode 下发的 cookie / 加 &callback= / 去掉 v → 同样 0 字节
```

⇒ `unicast` 是**长轮询**（未扫时连接挂着不回）。共用 10s 全局超时 ⇒ 第一次轮询就 Err ⇒
UI 报 `error sending request`、停表。

## Decision

1. **解析改成真报文**：顶层 `sign` + `imgurl`（`data.*` 只作兜底）；`errno` 非 0 / 非 JSON / 缺字段
   ⇒ Err 并**点名缺哪个**。
2. **二维码图片直接内嵌**：`https://` + imgurl 取 PNG（实测 225×225、769 字节），
   用自写 `b64_encode` 拼成 `<svg><image href="data:image/png;base64,…"/></svg>`；
   `png_size` 读 IHDR 拿宽高（SVG 要先知道尺寸）。取图失败 ⇒ 退回 `qr_svg_for(img_url)` 并在 hint 里说明。
3. **unicast 单跳 3 秒超时，超时当 Pending**；非超时传输错（DNS/TLS/拒连）仍 Err ——
   这条不能一起放宽，否则网络死了会永远"等待扫码"。
4. **Dart 侧补一条渲染分支**：`qr_view.dart` 原来只认 `<rect>`+`<path>`，
   内嵌 `<image>` 会降级成"一行图片地址"。已加 `qrSvgEmbeddedPng()` → `Image.memory`。

## Alternatives considered

### A. 只显示 `imgurl` 文本（现状的降级行为）

**最强理由**：零改动，UI 已经能显示"二维码不可用 + 一段地址"。

**否掉的原因**：Owner 要的是"能扫码"。让用户去浏览器打开那张图再扫，等于把功能退回命令行。
而且 Rust 侧已经有 PNG 字节，差的就是渲染那一跳。

### B. 给百度换一个"返回二维码文本"的接口

**最强理由**：文本二维码能走现成的矢量渲染，不用碰 Dart。

**否掉的原因**：真网只发现这一个 getqrcode（带不带 `gid` 都回同一形状）。
换接口=猜接口，本仓纪律不允许；而"内嵌图片"这条路是**确定能成**的（PNG 已真取到）。

### C. unicast 也跟其它盘一样用全局 10s 超时

**最强理由**：一份超时配置，少一处特例。

**否掉的原因**：长轮询的语义就是"没事件就不回"。10s 超时必然每次失败，
现场表现是"一扫码就报错"，比不出码更糟。特例有明确证据与门禁
（`baidu_unicast_timeout_is_shorter_than_the_global_one`）。

## Consequences

**收益**

- 百度从"字段不全"变成**真的出二维码图片**（真网 curl 取到 225×225 的真码，样图在
  `.probe/r3c-baidu-qr-live-sample.png`）。
- unicast 长轮询被正确对待：未扫时 `Pending`，不再误报网络错误。
- `qr_view.dart` 现在两种形态都支持（矢量 + 内嵌位图），以后哪家给图片都能显示。

**代价与边界**

- `unicast` 的 `channel_id=<sign>&v=<sign>` 这层**参数对应关系仍未取证**（真网只能证明"连接是通的、
  是长轮询"）。所以每次轮询都把 `HTTP / errno / Set-Cookie 键名 / body 摘要` 写进日志，
  真机一扫就能判读；拿不到 BDUSS 一律 `Pending`，绝不伪造成功。
- 百度登录的 cookie 组装（BDUSS + pan 域）仍沿用上一版，没有新的真机读数。

## 验证结果（已发生）

```text
cargo test --lib pan_login --release → 77 passed / 0 failed（2 ignored = 真网 smoke）
真网 smoke（SOURIN_LIVE_BAIDU=1，--ignored）：
  取码成功 sign_len=32 img_url_len=99 img_url_is_https=true
  二维码图片内嵌成功 svg_len=2583
  轮询 3s 内无事件（长轮询，正常）⇒ Pending
Dart：flutter test test/zz_qr_view_embedded_png_test.dart → 4 passed
  （href / xlink:href / 无内嵌 ⇒ null / 坏 base64 ⇒ null）
故障注入（已实测真红）：
  ① baidu_img_url 去掉 `https://` ⇒ 门禁 FAILED
  ② unicast 的 `v=` 改 `sign=` ⇒ 门禁 FAILED
  ③ unicast 超时改成 10s（= 全局）⇒ 门禁 FAILED
  ④ png_size 宽高读反 ⇒ 门禁 FAILED
  ⑤ b64_encode 字母表错一位 ⇒ 门禁 FAILED
```

## Relations

- 本条的骨架来源（协议顺序仍有效）：
  [../feature/2026-10-28-baidu-qr-login-passport.md](../feature/2026-10-28-baidu-qr-login-passport.md)
- 同批：`qr_view.dart` 的位图分支也服务其它"给图片"的盘