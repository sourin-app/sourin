# Agent Note: 插件元数据（源类型 / 上次更新时间）走头注释，必须在前 2048 字节内

Status: implemented

Related: [2026-10-18-cross-language-shape-must-run-against-real-parser.md](2026-10-18-cross-language-shape-must-run-against-real-parser.md)
—— 同一类教训的第二个实例：跨语言边界的字段不能"看起来对就行"，
必须用对面那侧的真解析器跑一遍才算验过。本篇不取代它，是它的应用。

## Problem

「设置 → JS 插件」列表早期只显示文件名和加载状态。用户装上十几个源之后，
分不清哪个是单站 CMS、哪个是聚合仓、哪个是 IPTV，也不知道**这个源的上游
最后一次验证通过是什么时候** —— 一个源挂了两周也不会有人察觉。

要显示的字段只有两个：`@type`（源类型枚举）和 `@updated`（上次真实刷新时间）。
问题是这两个值**只能来自插件自己**：宿主不可能知道「某 CMS 接口今天还活着」，
除非插件作者真的跑过。

## Decision

字段写进插件**头注释**，宿主在 `sourin_core/src/plugins/mod.rs` 里解析，
并且**只读文件前 2048 字节**：

```rust
pub kind: String,     // ← JSON 里叫 "type"（Rust 侧 type 是关键字）
pub updated: String,  // ← ISO8601 带时区偏移，如 2026-10-23T09:41:00+08:00
```

三条配套约束：

1. **边界版 tag 查找**。`@type` 不能被 `@typedef` 命中，`@updated` 不能被
   `@updatedAt` 命中 —— 这两个同前缀长标签在真实插件里都出现过。所以不能
   用 `starts_with`，必须要求**标签后是空白**。
2. **多候选 + 值净化**。同一个头注释里出现多次时取第一个「看起来像值」的：
   `@type` 过白名单（`video-site|aggregator|iptv|emby|other`），
   `@updated` 必须能被解析成带时区偏移的 ISO8601，否则当没写。
3. **缺值是合法的**。`@updated` 缺失的语义是「从来没验证过，不是验证失败」，
   UI 不能显示 `null` 或占位垃圾，直接省略这一段。

配套在插件仓加了门禁 `tools/check-plugin-meta.mjs`：字段被挤出 2048 字节窗口
时**不会报错、只会静默变空**（卡片就是不显示），必须靠 CI 卡住。

## Alternatives considered

- **放在插件配置 JSON（`plugins/.data/<id>.json`）里**：写的时候方便，但
  「作者声明的静态元信息」和「运行时状态」混在一起就分不清谁覆盖谁了。
  最终取的是：两处都读，运行时 `sourceStatus` 有值优先，否则用头注释值。
- **扫描整个文件而不是前 2048 字节**：更简单，但插件 JS 动辄几十 KB，
  列表页要给几十个插件各读一遍文件，只为拿两行头注释。
  定 2048 的代价是「头注释太长会把字段挤出去」，所以配了门禁。
- **让宿主去探测上游是否可用**：不可能 —— 每个源的上游接口形状都不一样，
  探测逻辑本来就写在插件里。

## Consequences

- 插件作者必须把 `@type` / `@updated` 放在头注释**前面**，且 `@updated`
  只许写**真实验证通过**的时间（写假的等于撒谎，用户看到的时间就没有意义）。
- 32 个插件的门禁结果：全部合规；4 个故意没有 `@updated`
  （`站点A.ts` 示例模板、`站点B.js` 403 死链、`站点C-live.js` 游客态不可用、
  `demo.js` 模板）。
- 宿主侧验证方式不是「看代码对不对」，而是真跑 FFI 看返回：
  `list_plugins` 实测输出
  `{"type":"video-site","updated":"2026-10-23T09:41:00+08:00"}`。
