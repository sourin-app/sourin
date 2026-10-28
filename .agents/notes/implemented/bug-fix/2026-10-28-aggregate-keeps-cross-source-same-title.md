# Agent Note: 「全部」搜索要像原版那样几十条 —— 去重不许跨源合并，UI 按子站分组

Status: implemented

Independent: 与本目录 `2026-10-28-aggregate-only-saw-hidden-children.md`（同一天、同一功能）
解决的是**不同两段**：那条修的是"候选集为空 ⇒ 一个子站都不扇出"（结果是 0 条）；
本条修的是"扇出来了却被合并成 1 条"（结果是 1 条）＋"UI 全挤在一个组里"。
两条合起来才是 Owner 说的"原版 73 条、按源分组"。

## Problem

Owner：「搜『老舅』，原版出来几十条、按源分组；我们这边不是这个形态」。
候选集那条修好之后仍然出不了几十条，还剩两个断点：

```text
① Rust `TvboxAggregate::dedupe` 的 key 是 `(title, kind)` —— **跨源同名即合并**。
   十几个子站都返回「老舅（2023）」⇒ 只剩 1 条。
② UI（`search_page.dart`）按 **provider** 分组；聚合源是**一个** provider
   ⇒ 所有子站的条目全挤在「TVBox 聚合」这一组里，
   用户看不出哪条来自哪个站，也没有原版那种"一排源、每组几条"的形态。
```

## Decision

```text
① 去重只合并"同一条"：key = `(provider, native)`（同一源翻页重叠才会重复）。
   跨源同名**一律保留** —— 原版"全部"就是逐源列，同一个剧在 5 个源里算 5 条。
② UI 侧拆组：`splitAggregateHit()` 按条目 id 里的**子站前缀**
   （`tvbox_agg:<子站id>::<原始 id>`）拆成多组，组标题用子站名
   （来自 `tvbox_agg_channels`，零网络命令；拿不到就退回子站 id）。
③ 拆分**不许丢条目**：认不出前缀的条目进兜底组（组名 = 聚合源名）。
   条数守恒是硬判据（丢一条就是"搜索结果变少"的静默 bug）。
```

职责划分写进代码注释了，避免下一个人再混：

```text
去重：只挡"同一条被收了两次"
分组：只按来源拆开（不看标题）
排序：另有一套判据（`rankHitGroups` 按匹配度，不动）
```

## Alternatives considered

### A. 保持 `(title, kind)` 去重，只把"合并了多少条"显示出来

**最强理由**：结果列表更短、更干净，用户不用在 5 个同名片之间选；列表也更省内存。

**否掉的原因**：Owner 的验收是**逐字对比原版**（"原版几十条"）。
而且"合并"会让**换源**失去意义 —— 我们自己有换源弹层，而换源的前提是
"同一部剧有多个源可选"；合并成 1 条后，用户看不到还有哪个源能播。
（这条也解释了为什么原版要按源分组：那里的"多条"就是"多路可用"。）

### B. 在 Rust 侧把聚合搜索拆成"每个子站一个 provider 事件"

**最强理由**：UI 一行不用改，分组天然按 provider 走；`_skipped`/进度计数也自动对。

**否掉的原因**：那要改流式搜索的事件模型（`registry::search_all` 目前**一个 provider
一个事件**），等于给聚合源开一个"一对多"的特例 —— 事件计数、取消、
`_settled` 进度全要跟着改，风险远大于收益；而这些语义只有 UI 需要。
⇒ 在 UI 侧按 id 前缀拆，是**不改协议**的最小改动。

### C. 组标题直接用子站 id（不查名字）

**最强理由**：零依赖、零请求，`splitAggregateHit` 不需要外部数据。

**否掉的原因**：`tvbox_agg:csp-4k-zhinan::…` 这种 id 用户看不懂（原版显示的是站点名）。
`tvbox_agg_channels` 是**已经存在的零网络命令**，不用才是浪费；
但名字**允许缺失**（缺了退回 id）—— 分组本身不依赖它。

## Consequences

**收益**

- 「全部」的条目数恢复成"各源之和"（同名不再被吃掉），与 Owner 数的原版条数可比。
- 组标题是子站名 ⇒ 与首页渠道条、原版"按源分组"三处口径一致。
- 去重仍然挡"同一条收两次"，翻页重叠不会出现重复卡片。

**代价与边界**

- 搜索结果会**变长**（同名多源时尤其明显）：这是对标原版的必然代价，
  但用户能通过"哪个源"决定点哪条。
- 每条事件现在可能产生多个组 ⇒ `_hits` 增长更快；排序是稳定排序，
  同分保持到达顺序，不会因为拆分而乱序。
- 子站名清单来自 `tvbox_agg_channels`：该命令只列"聚合口径内的子站"，
  若某个子站不在清单里，标题会显示 id（可读，不空白）。
- 一条旧门禁翻面：`fanout_dedupes_same_media`（断言跨源同名合并成 1 条）
  → `fanout_keeps_same_title_from_different_sources`（断言必须 2 条）；
  另新增 `fanout_dedupes_exact_same_item` 守住"同一条收两次仍要合并"。

## 验证结果（已发生）

```text
① Rust：cargo test --lib tvbox_aggregate --release → 21 passed / 0 failed
   fanout_keeps_same_title_from_different_sources  两个子站同名 ⇒ 2 条且分属两个子站
   fanout_dedupes_exact_same_item                  同一子站给两次同一条 ⇒ 仍 1 条
② Dart：flutter test test/zz_t1062_agg_groups_test.dart → 9 passed
   纯函数：非聚合源不拆 / 聚合源按子站拆（组名、条数、到达顺序）/
          名字缺失退回 id / 认不出前缀进兜底组且总数守恒 / 空结果仍是一组
   真界面：喂一个聚合事件（两个子站）⇒ 页面上真的渲染出「源甲」「源乙」两个组标题，
          且「源甲」在上（`tester.getRect` 读坐标）；非聚合源仍是单组（"2 个结果"）
故障注入（真红，已实测）：
  ① dedupe 的 key 改回 `(title, kind)` ⇒ fanout_keeps_same_title_from_different_sources FAILED
  ② `_addHit` 不用 `splitAggregateHit`（回到 `items: ev.items`）⇒ 真界面那条 FAILED
     （只出现「TVBox 聚合」一个组标题，找不到「源甲」「源乙」）
```

## Relations

- 同功能前一段（候选集为空 ⇒ 0 条）：
  [./2026-10-28-aggregate-only-saw-hidden-children.md](./2026-10-28-aggregate-only-saw-hidden-children.md)
- 同批收尾的网盘侧：
  [../feature/2026-10-28-share-link-play-via-item-id.md](../feature/2026-10-28-share-link-play-via-item-id.md)
