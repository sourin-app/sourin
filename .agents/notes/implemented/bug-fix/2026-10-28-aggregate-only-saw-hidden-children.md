# Agent Note: 聚合"全部"的候选集不许只看 hidden —— Owner 拿原版对了数

Status: implemented

## Problem

Owner 现场对照原版：搜「老舅」，**原版 73 条**（左侧十几个源分组，全部 73/73），我们 **0 条**。

查下来是聚合兜底候选集的筛选条件写错了对象：

```rust
let mut all = registry.enabled_manifests().into_iter()
    .filter(|m| m.hidden)            // ← 只收"TVBox 导入的隐藏子站"
    .filter_map(|m| registry.get(&m.id))
    .collect();
```

后果链条（每一步都能对上他的现场）：

```text
① 内置 csp 源（`csp-*`、56 个）**不 hidden** ⇒ 永远进不了聚合候选集；
② 他配置里那批 hidden 子站（TVBox 导入的）在 disabled-providers.json 里**全被停用**
   ⇒ `enabled_manifests()` 里一个都没有；
③ 于是候选集为空 ⇒ 聚合 0 个渠道 ⇒ 搜索 0 条。
```

`hidden` 的语义是**"要不要在源列表里露脸"**（导入的子站默认藏起来，避免列表被塞满），
它**不该**决定"能不能被搜到"。原版的"全部"就是所有站。

## Decision

兜底（`enabledSiteIds` 为空时那条路）改成：

```rust
.filter(|m| m.id != AGGREGATE_ID)   // 排除聚合自己（否则递归）
```

即 **所有仍启用的 provider 都进候选集**，与 hidden 无关。

R2-B 的意图（"用户显式停用过的源不许被拉回来"）**没有被破坏**：
候选集本来就来自 `enabled_manifests()`，停用的一律不在。
`fallback_allowed` 那个分支保留，只用来记一条区分意图的日志。

## Alternatives considered

1. **只把内置 csp 源当特例加进去**（`m.hidden || m.id.starts_with("csp-")`）。
   最强理由：改动面最小，只影响这批新源，不动导入子站的既有行为。
   **否决** —— 那是把"某批源的命名约定"写进聚合的候选逻辑里，
   下一个新增源族（JS 插件、将来的别的前缀）会再犯一次同样的问题。
   判据该按"启用与否"来，不该按"名字长什么样"。
2. **把 56 个内置源都标 `hidden`**（让它们走原来的 hidden 分支）。
   最强理由：一行都不用改聚合逻辑。
   **否决** —— 那等于把内置源从源列表里藏起来，与 Owner 明确要的
   "原版是自动的，jar 里有什么类就出什么源"直接冲突（上一轮的自动暴露就白做了）。
3. **保留 hidden 过滤，但在 UI 上让用户手动勾选"全选"**。
   最强理由：把选择权交给用户。
   **否决** —— 原版开箱就是"全部"，多一步手动勾选等于没对标；
   而且这正是上一轮被打回的"让用户额外导配置"那类错误的变体。

## Consequences

- 收益：聚合"全部"搜索/首页的候选集从 **0** 变成"所有启用源"（本机 57 个），
  与原版一致；内置 csp 源第一次能被搜到。
- 门禁：`tests/zz_parity_aggregate_fanout.rs` —— 空目录 bootstrap 后断言
  "每个启用的非 hidden 源都在 `channels()` 里"+"聚合不把自己算成渠道"；
  注入把 `.filter(|m| m.id != AGGREGATE_ID)` 换回 `.filter(|m| m.hidden)` ⇒ 真红。
- 代价：搜索会同时打 ~57 个源（原版也是这样）。多数需要 ext 的类会失败 ——
  但那正是"上游没配"的如实表现，聚合会按既有规则容忍单源失败。
  若将来实测发现首屏/搜索过慢，正确的收紧方式是**逐类标注 needs_ext 并把它们排除在
  "不是源"之外**，而不是退回"只看 hidden"。
- 代价：`hidden` 现在只影响源列表展示，不再影响可搜索性 ——
  这条语义要在 `hidden` 的定义处写清（否则下一个人会以为它还是"隐藏=不参与"）。

## Relations

- 前情：[./2026-10-28-builtin-csp-sources-auto-exposed.md](./2026-10-28-builtin-csp-sources-auto-exposed.md)
  —— 那篇让内置源"出现在列表里"；本篇让它们"能被搜到"。两件缺一，用户都看不到内容。
- 相关（判据读错对象族）：[./2026-10-28-hardcoded-sample-classes-go-stale.md](./2026-10-28-hardcoded-sample-classes-go-stale.md)
