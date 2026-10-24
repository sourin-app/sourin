# Agent Note: 扫码登录要支持「上游只给一张图」的站点（站点C ptqrshow）

Status: implemented

Related: [2026-10-18-cross-language-shape-must-run-against-real-parser.md](2026-10-18-cross-language-shape-must-run-against-real-parser.md)
—— 同一类坑的第三个实例：字段名差一个下划线，功能**静默**退化成错误行为。

## Problem

宿主原来的扫码登录契约假设「插件能给出一个**可被编码成二维码的 URL**」：

```text
插件 qrLoginStart() → { key, url }
宿主                → remote::qr_svg_for(&start.url) → SVG → 界面显示
```

站点A、站点B、站点D都符合这个模型。**站点C不符合**：它只给
`https://ptqrshow.qq.com/...` 这个 **PNG 图片**地址，登录票据在图片里。

于是站点C插件填 `url = <那张 PNG 的地址>`，宿主照规矩把它编码成二维码 ——
用户拿手机扫出来的结果是「一张 PNG 的链接」，扫完什么都不发生。
**没有任何报错**：二维码画出来了、也扫得动、就是登不上。

更隐蔽的一层：新字段最初写成 `pub image_url: Option<String>`，
而插件侧按 JS 习惯传的是 `imageUrl`。serde 找不到 `image_url` 键就取 `None`
（因为 `#[serde(default)]`），于是**静默**退回上面那条错误路径。
只有用真 JSON 反序列化才测得出来，手写结构体测不到。

## Decision

`QrLoginStart` 增加可选字段，**语义互斥**：

```rust
#[serde(default, rename = "imageUrl", alias = "image_url",
        skip_serializing_if = "Option::is_none")]
pub image_url: Option<String>,
```

收尾逻辑抽成 `QrLoginStart::finalize_qr_rendering()`：

- `image_url` 有值（去空白后非空）⇒ **清空 `svg`**，界面直接 `Image.network`
- 没有 ⇒ 走原路，`qr_svg_for(url)` 渲染 SVG（老插件行为字节级不变）

不清 `svg` 的话会同时显示两张码：一张对的图、一张错的 SVG，用户必然扫错。

抽成独立函数的关键理由是**可离线测试**：真二维码要真网络，而「分支写反」
和「字段名写错」这两类错误只有逻辑测试能挡住。5 条用例覆盖：
图片优先、空白图片回落、纯 URL 老路、`imageUrl` camelCase 解析、缺字段为 None。

## Alternatives considered

- **让插件把 PNG 下载下来转 base64 塞进 `url`**：QuickJS 侧拿不到二进制
  转码能力（且 `host.http` 返回文本），宿主要多做一次解码，还得处理
  5 种图片格式的嗅探。不如把「显示一张 URL 图」这件事交给 UI 层。
- **宿主自己去抓图再转 QR**：需要图像识别（从位图里解二维码），
  引入一个只为两家站点服务的重依赖，且失败模式更玄学。
- **不支持站点C扫码，只保留 Cookie 登录**：站点C的 Cookie 有效期短，
  用户体验最差的就是这条。既然插件侧已经能拿到图片地址，缺的只是 UI 一行。

## Consequences

- 新增一条**跨语言字段名约定**：JSON 里一律 camelCase，Rust 侧用 `rename`，
  同时留 `alias` 兼容下划线写法（先写的插件不会被这次改动打死）。
- 界面白底必须保留：PNG 可能是透明底，深色主题下扫码识别率会掉。
- `flutter analyze` 对本文件 0 issue；`cargo test --lib qr_start_tests` 5 passed；
  **实机视觉验证未做**（本期无法起 app 截屏），已在提交说明中如实标注。
