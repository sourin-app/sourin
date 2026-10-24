# Agent Note: 让 TVBox 配置里声明的解析服务真正生效

Status: implemented

Independent: 本仓此前**没有关于 TVBox 解析服务的决策笔记**（`try_parsers` 与
`PARSE_SERVICES` 是随 TVBox 导入一起落地的实现细节，未单独立笔记）。
本笔记只补「配置里的 `parses[]` 从没被读」这一处遗漏，不与任何既有决定重叠。
相关但不同域：[仓库内不许出现站名](../process/2026-10-13-no-site-names-in-repo.md)
—— 本模块的测试夹具遵守它（解析服务前缀用 `jx.example` 这类中性占位）。

## Problem

TVBox 配置里有一个 `parses` 数组，声明作者**验证过的**解析服务：

```json
"parses": [
  {"name": "聚合", "type": 3, "url": "Web"},
  {"name": "某服务", "type": 0, "url": "https://jx.example/?url="}
]
```

而本仓的 `try_parsers` 只用了**编译期常量** `PARSE_SERVICES`（1 个硬编码服务）：

```rust
pub const PARSE_SERVICES: &[&str] = &["https://player.gimy.example/u/parse.php?url="];
```

⇒ 用户拿到的配置里，作者明确写下的解析器**从来没被用上**；
我们只用自己硬编码的那一个。配置作者的验证成果被浪费，且用户无法调整。

这是之前把 P1'.4 判为"没有消费方"的**误判** —— 其实有消费方（`try_parsers`），
只是它读的不是配置。

## Decision

1. **`collect_parsers(cfg)`** 从配置提取可用前缀，判据：
   - 只取 `type: 0`（URL 前缀式：`<前缀><页面地址>`，纯 HTTP 能做）
   - **跳过 `type: 3`**（WebView 式：需要真实浏览器内核执行页面 JS，本仓没有）
   - 跳过空、非 http(s)、去重
2. **`TvboxAppleCmsProvider::with_parsers()`** builder（不改 `new()` 签名，
   既有调用点零改动 —— 与 `with_proxy` 同一风格）
3. **`try_parsers` 优先用配置的，再退回内置**：
   ```text
   配置里有 ⇒ 先试它们（作者验证过，更贴合用户拿到的配置）
   全失败   ⇒ 再试 PARSE_SERVICES（我们的兜底）
   ```
   顺序不能反：内置那个是兜底，不该抢在用户配置前面。
4. **持久化**：`PersistedProvider::Tvbox` 加 `#[serde(default)] parsers`。
   旧清单（没这个字段）读出来是空 Vec ⇒ 退回内置兜底，**行为与改动前一致**。

## Alternatives considered

### A. 直接把配置的 `parses` 追加到 `PARSE_SERVICES`（改编译期常量）
**最强理由**：改动最小，一行搞定。
**否掉的原因**：`PARSE_SERVICES` 是 `const`，编译期定死。要追加只能改成 `static`
+ 运行时可变，那是**全局可变状态** —— 多个 TVBox 源各自有不同的 parsers 时会互相污染。

### B. 也支持 `type: 3`（WebView 式解析器）
**最强理由**：配置里 `type: 3` 是常见项，支持了覆盖面更大。
**否掉的原因**：`type: 3` 需要一个真实浏览器内核去跑页面里的 JS。本仓没有 WebView
（Rust 侧无浏览器），**做不到**。假装支持只会让用户点开黑屏。
⇒ 静默跳过它，且这不算"丢功能"——那本来就不是我们能执行的形态。

### C. 配置的 parsers 失败后仍返回错误（而不是退回内置）
**最强理由**：用户配置里的解析器失效了，应该让他知道。
**否掉的原因**：`try_parsers` 的既有语义就是"逐个试、全失败返回 None"，
调用方会走后续兜底。中途改成硬失败会打断既有取流链路。
配置解析器失败已用 `log::debug` 记录（与既有每个服务失败的记录方式一致）。

### D. 让用户能在设置里编辑 parsers
**最强理由**：可控性最好。
**否掉的原因**：本仓没有"解析服务管理"界面，加一套是新的产品面。
当前用户改配置源本身就会带上 parsers，够用。真需要时再加。

## Consequences

**收益**
- 配置作者验证过的解析器**真的生效**了，且优先级高于我们的兜底。
- 用户可以只在自己的配置里调整解析器，不必等我们发版更新常量。
- `type: 3` 被**明确跳过而非假装支持**，行为可解释。

**代价与边界**
- 解析服务仍是**第三方**（这一点没有改变，只是候选来源多了一个）。
  内置列表作为兜底保留 —— 配置里没写 parsers 时行为与改动前完全一致。
- 只看 `type: 0`。`type: 3`（WebView 式）做不到，已在文档与代码注释里写明。
- 解析器是"页面 URL → 播放地址"的黑盒服务，其可用性取决于第三方；
  本仓只负责按顺序尝试并如实记录失败。

## 验证结果（已发生）

- `cargo test --lib --release` → **546 passed / 0 failed**
- 新增 4 条门禁：
  · `collect_parsers_takes_only_type0_with_http_url`：混合 6 条（含 type:3、
    空 url、非 http、重复）⇒ 只留 2 条正确的
  · `collect_parsers_handles_missing_or_broken_section`：缺 / 非数组 / 空数组都返回空
  · `with_parsers_is_a_builder_that_does_not_change_new`：不调 builder 时为空
  · `old_persisted_tvbox_without_parsers_still_loads`：**旧清单能读**，parsers 为空

## 顺带修掉一个我自己引入的缺陷

全量跑出 `pan_auth::roundtrip_through_keyring_when_available` **FAILED**：

```text
left:  cookie "q=1"                    ← 读到的
right: cookie "sess=abc123; uid=42"    ← 期望的
```

根因：**系统钥匙串是进程外共享状态**，而 `cargo test` 默认并行；
三个测试都操作 `pan/quark` ⇒ 互相覆盖。
修法：每个用例用**不同的盘**（从根上消除共享，而不是依赖执行顺序），
连跑 3 次均 9 passed。

## 何时该翻案

若将来引入 WebView 内核（或改用带 JS 引擎的解析方案），`type: 3` 应一并支持。
若本仓有了"解析服务管理"界面，parsers 应改为用户可编辑而不是只读配置。
