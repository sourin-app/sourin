# Agent Note: 判据里写死"当前还没实现的那个类"，一定会随别人推进变成红

Status: implemented

## Problem

`csp/route_tests.rs` 里有两条判据测的是"**未实现的 csp 类**要怎么处理"（进 `skipped` + 文案逐字
`csp_X 尚未实现`、以及 `build_site_provider` 必须拒绝它）。它们当时写死了 `csp_XBPQ` 当样本 ——
因为写的时候 XBPQ **恰好**还没实现。

本批把 XBPQ 实现了（`register_site!` 之后 `is_implemented("csp_XBPQ") == true`）⇒ 两条判据同时变红：

```text
assert!(jobs.is_empty())                        ← 现在 jobs 不空（XBPQ 能建出 provider）
reasons.contains("csp_XBPQ 尚未实现")            ← 现在根本进不了 skipped
```

**代码一行没错，红的理由是"样本过期"。** 而且这种红很容易被误读成"我改坏了 XBPQ"。

这不是第一次：`mod.rs::unimplemented_sample()` 的注释里已经记过一次
（"写死类名的判据会随着别人推进而失效，而失效方式是红，容易被误读成回归"），
当时只修了那一处，`route_tests.rs` 这两条没跟上 —— 这次是**第 4 次**同族事故。

## Decision

**判据里要一个"永远不成立"的样本时，用合成名，不要用"当下恰好没实现"的真实类。**

```rust
// 改前（会过期）
r#"{"api":"csp_XBPQ"}"#          // XBPQ 一旦被实现，这两条就红

// 改后（永不过期）
r#"{"api":"csp_NotAClassForTest"}"#   // 合成类名：永远不会出现在注册表里
```

两条判据的语义不变（"未实现 ⇒ 进 skipped + 文案逐字 `csp_<类名> 尚未实现`"），
只是把"谁是未实现的"从**世界状态**换成了**构造出来的输入**。

## Alternatives considered

1. **继续用 `unimplemented_sample()`（运行时挑一个还没实现的真实类）**。
   最强理由：它是仓里已有的机制，专门为这个坑写的，改一行就能用。
   **否决** —— 它解决的是"样本会过期"，但把判据与"当下还剩哪些类没实现"继续绑在一起：
   等 14 个类全做完，`unimplemented_sample()` 会 panic（它自己写着"该换判据了"），
   那时这两条又得改一次。合成名从根上没有这个耦合。
2. **把这两条判据删掉**（"未实现的类"这个场景快不存在了）。
   最强理由：本批之后几乎所有类都实现了，这条路径用得越来越少。
   **否决** —— 这条路**永远**要能用：用户配置里可能引用任意 `csp_Xxx`（包括拼错的名字、
   或将来新增但还没写的类）。它的失败形态是"源静默消失"，正是本仓最忌讳的"看起来没有"。
3. **改成断言 `skipped` 非空却不校验文案**。
   **否决** —— 文案是给用户看的唯一线索（`csp_X 尚未实现` vs `需要 Java 运行时`），
   不钉文案等于放弃这条判据的核心价值。

## Consequences

- 收益：这两条判据与"谁实现了什么"彻底解耦，不会再因为别人推进而红。
- 收益：把"合成输入 > 依赖世界状态"这条口径固定下来，同族事故（第 4 次）到此为止。
- 代价：合成类名要多写一行注释解释"为什么不用真实类名"，否则下一个人会把它"修正"成真实类名
  （代码里已写明，并注明这是第 4 次）。
- 代价：`csp_NotAClassForTest` 如果哪天真被实现（不可能，但），判据会红 —— 那时它红得有道理。

## Relations

- 同族：[./2026-10-27-assertion-text-features-are-not-outcomes.md](./2026-10-27-assertion-text-features-are-not-outcomes.md)
  —— 都在讲"判据别去依赖会变的东西"（那篇是措辞特征，本篇是样本集合）。
- 同族：[./2026-10-28-source-gates-must-window-by-char.md](./2026-10-28-source-gates-must-window-by-char.md)
  —— 源码判据的取景方式；本篇是源码判据的**样本选择**。
