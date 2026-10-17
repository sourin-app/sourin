# Agent Note: 决策笔记树进仓库，与 docs/DECISIONS.md 分工

Status: implemented
Archived: 2026-10-17

## Problem

本仓已经有一处决策出口：`docs/DECISIONS.md`（A1–C7）。它管得住「路线级选型」——
为什么重写成 Flutter + Rust、为什么走 PR、门禁为什么必须能变红——每条形如
「决策 / 为什么 / 排除了什么 / 何时该翻案 / 出处」。

但它管不住另一类改动：**某次具体实现为什么这么做、放弃了哪条路**。
这类信息有三个特征，DECISIONS 的条目结构装不下：

```text
① 寿命短于路线：一个内部契约的取舍，代码稳定后就没必要占 DECISIONS 的位置；
② 需要流转：先有想法（proposed）、落地后转事实（implemented）、被否要留痕（rejected），
   而 DECISIONS 只有「已生效」一种状态，写进去就等于已定案；
③ 需要与代码同批：改了行为的那次提交里就该有它，评审时 diff 与 why 一起看。
```

缺了这层，维护者面对一段非显然实现时只能读代码猜意图；而代码只说**是什么**，
说不出**为什么**和**放弃了什么**。判据很直接：本仓已经为此付出过代价——
`CONTRIBUTING.md` 的「⑥ 两条硬规矩」四条真实案例（详情页封面糊、顶底栏不同时出现、
返回卡顿、`windowBorderColor` 全仓零调用）都不是「没写代码」，而是**写了的代码
没接线**，且当时没有任何一处记录了「这条路径本该被执行到」的意图。这类缺口
正是实现级笔记该守的东西。

同时存在一个反向约束：`.gitignore` 第 149 行把整个 `.agents/` 忽略掉，
理由是 `.agents/worktrees/` 里的基线副本会被 `test/t98_no_site_names_test.dart`
当成仓库内容扫进来（同一份源码两份命中）。笔记若沿用这条忽略规则，
就**进不了仓库**——下游 clone 看不到，CI 也校验不了，笔记退化成本机草稿。

## Decision

本仓启用 Agent Note 树，**笔记进版本库**，与 `docs/DECISIONS.md` 分层共存。

```text
.agents/notes/{proposed,implemented,rejected,archived}/{class}/yyyy-mm-dd-topic.md
```

**分工**（两边都不许越界）：

| 承载 | `docs/DECISIONS.md` | `.agents/notes/` |
|---|---|---|
| 粒度 | 路线级选型（技术栈、流程、门禁哲学） | 单次改动的实现取舍 |
| 状态 | 只有「已生效」，翻案靠追加一行 | `proposed` / `implemented` / `rejected` / `archived` 四态流转 |
| 独有字段 | **何时该翻案**（保质期） | **Alternatives considered**（真权衡过的对手方案）、Consequences（代价与收益） |
| 入口 | `README.md`、`docs/README.md`、`docs/AGENTS.md` §7 | `docs/AGENTS.md` §7（与 DECISIONS 并列指向） |

**class 封闭集**（6 个，`refactor` 不单列）：`feature`、`bug-fix`、`simplification`、
`architecture`、`process`、`testing`。

**何时必须写**：改了行为 / 架构 / 跨文件契约 / 流程与工具链 / 测试策略 /
落盘、网络、配置格式，或其他维护者日后可能重访的决定。
**免写**：纯格式化、错别字、无歧义重命名、不改行为的样式与依赖补丁、版本打标、
常规 CRUD、单模块内看 diff 即懂的修复。判不准时从严。

**`.agents/` 的忽略规则收窄为白名单**：只有 `.agents/notes/` 进库，
`.agents/worktrees/` 等其余子目录继续忽略——worktree 副本污染 `t98` 扫描的问题
不能因为放行笔记而复现。

**`t98` 的扫描范围随之收窄**：该门禁按目录名跳过 `.agents`，放行笔记后必须改成
**按相对路径**只跳过 `.agents/worktrees/`，否则笔记里的文本永远扫不到，
而它正是会被发布的文本。

## Alternatives considered

- **只保留 `docs/DECISIONS.md`，不引入笔记树** —— 它最强的论据是「单一出口」：
  一处决策记录没有分裂风险，维护者不必判断该查哪一边，也不新增任何工具链依赖。
  否决理由：DECISIONS 的条目结构是「已生效的路线 + 保质期」，装不下未落地的提案
  （proposed）与已否决的路线（rejected），也装不下实现级的 why。把它扩成四态，
  等于让路线级条目和一次性实现取舍挤在同一份按字母编号的清单里，
  检索面反而变糊。

- **用笔记树整体替换 `docs/DECISIONS.md`** —— 它最强的论据是「两套记录迟早分叉」：
  同一件事被记在两处，改一处忘一处就会自相矛盾。否决理由：DECISIONS 的
  **「何时该翻案」是它独有的保质期字段**，路线级条目靠它判断何时该回来推翻；
  且它已被 `README.md`、`docs/README.md`、`docs/AGENTS.md` 三处指向为决策入口，
  替换要同时改写这些引用与既有 21 条的阅读路径。分层比替换的收益高。

- **笔记不进仓库，只留本机**（即原 `.gitignore` 的状态）—— 它最强的论据是「笔记含
  本机与个人上下文，`.agents/` 下确实混着 worktree 这类不该进库的东西」，
  整目录忽略最简单也最安全。否决理由：笔记的价值在于**与代码同批落盘**——
  改了行为的那次提交里就带着 why，评审时能一起看；不进库则下游 clone 看不到，
  CI 也无法校验格式与链接，笔记退化成本机草稿，与「写在散文里的规矩等于没有规矩」同构。

## Consequences

- **收益**：
  - 非平凡改动有了固定落点，`proposed → implemented` 有明确改写契约（落地时改
    `Status`、把 `## Proposal` 改写成现在时 `## Decision`、验收与风险折进
    `## Consequences`），不会停在半截提案上。
  - 被否决的路线进 `rejected/` 后冻结，同一诱惑不必每轮重新论证一遍。
  - 结构、状态一致性、笔记间相对链接可由脚本机械校验，不靠自觉。

- **代价与已知上限**：
  - **两套记录并存的分叉风险**：判断边界靠人工（路线级 vs 实现级）。出现「同一件事
    两边都记且说法不一」时，判据是**以更具体的那篇为准，并删掉另一边的重复描述**，
    不是两处都改。
  - 校验脚本需要 Node + `tsx` 运行，而本仓是 Flutter + Rust 双栈，CI 目前没有
    Node 步骤。上限：脚本只在本地跑通、未接进 CI 之前，笔记格式是**软约束**。
    重访信号：CI 里出现第一次因笔记格式漂移导致的返工，或笔记数量超过单页
    检索能覆盖的规模。
  - `.gitignore` 的白名单一旦写成整目录放行，worktree 副本会重新污染 `t98`。
    上限：只放行 `.agents/notes/` 一个子树；新增子目录默认仍被忽略。

## Verification

```text
# 笔记树结构与格式（含笔记间相对链接）
npx tsx <skill>/scripts/verify-agent-note-tree.ts
npx tsx <skill>/scripts/verify-agent-note-format.ts

# 归档封印（首次归档后生效）
npx tsx <skill>/scripts/verify-archived-agent-notes.ts

# 站名门禁仍覆盖笔记目录
flutter test test/t98_no_site_names_test.dart --concurrency=1

# 白名单只放行笔记子树
git check-ignore -v .agents/notes/implemented/process/2026-10-17-agent-notes-in-repo.md
git check-ignore -v .agents/worktrees/x/y.md
```

判据：前两条脚本退出码 0 且打印 `ok:`；`git check-ignore` 对笔记路径**无输出**
（未忽略），对 worktree 路径**有输出**（仍忽略）。
