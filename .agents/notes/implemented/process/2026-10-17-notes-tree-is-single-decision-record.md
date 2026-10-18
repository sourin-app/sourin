# Agent Note: 决策记录只有一处出口 —— Agent Note 树

Status: implemented

## Problem

本仓曾同时存在两处决策记录：`docs/DECISIONS.md`（A1–C7，18 条）与
`.agents/notes/`。当时的分工是「DECISIONS 管路线级选型，笔记管单次实现取舍」。

这个分工在实践中产生两个可观察的问题：

```text
① 归属判断是每次都要重做的人工判断。同一件事该记哪边，取决于它"够不够路线级"——
   而这条线没有判据，只有感觉。于是同一主题被两边各记一半，改一处忘一处。
② 为了让旧链接继续有效，DECISIONS.md 被保留成"索引 + 迁移对照表"。
   但那份对照表是 18 行手写链接，内容与 `ls .agents/notes/implemented/*/` 高度重叠，
   而它不会随笔记增删自动更新 —— 新增一篇笔记没人会想起来去补索引。
```

第二点尤其糟：一个手写索引的失效方式是**静默的** —— 它不会报错，只会越来越旧，
最后读者按它找不到东西，却以为笔记不存在。

## Decision

`.agents/notes/` 是**唯一**的决策记录出口。`docs/DECISIONS.md` 已移除，
其 18 条内容全部在笔记树内（迁移在移除前完成，逐条校验过链接可达）。

```text
.agents/notes/{proposed,implemented,rejected,archived}/{class}/yyyy-mm-dd-主题.md
```

`class` 封闭集 6 个：`feature` / `bug-fix` / `simplification` / `architecture` /
`process` / `testing`。

**不建任何索引**（`INDEX.md` 由校验脚本直接拒绝）。找笔记的方式是：

```bash
ls .agents/notes/implemented/architecture/     # 按意图直切目录
rg --hidden --glob '!.agents/notes/archived/**' "关键词" .agents/notes/
```

原 DECISIONS 的「何时该翻案」字段并入每篇的 `## Consequences` ——
语义不变：条件一旦成立，就该回来推翻它，而不是继续执行。

## Alternatives considered

- **维持两层（DECISIONS 管路线级 + 笔记管实现级）** —— 它最强的论据是
  两种读者的检索习惯不同：想通读「这个项目做过哪些大决定」时，一份按编号排列的
  单文件比翻目录树快；而「何时该翻案」作为独立字段也确实比埋在 Consequences 里显眼。
  否决理由：归属判断没有判据，只能每次凭感觉切；而它带来的「两处都要看」的成本，
  是**每次**发生的，通读的便利是**偶尔**发生的。用偶尔的便利换每次的成本，不划算。

- **保留 DECISIONS.md 作为纯索引（不写正文）** —— 它最强的论据是保住旧链接与
  通读入口，且改动最小。否决理由：这正是被移除的那个形态，问题在于索引必须手写维护、
  且失效时静默。一个不会随笔记增删自动更新的索引，比没有索引更误导 ——
  读者会以为「索引里没有 = 项目里没有」。

- **把 18 条留在 DECISIONS.md，只让新决策进笔记树** —— 它最强的论据是零迁移风险：
  不动存量，只规范增量。否决理由：那等于把「按时间分界的两套记录」固化下来，
  读者必须先知道分界点才知道该查哪边；而分界点只会随时间的推移变得更难记。

## Consequences

- **收益**：
  - 决策只有一处，不需要判断归属；检索路径唯一。
  - 索引的失效方式从「静默变旧」变成「不存在」—— 目录树由文件系统维护，
    新增笔记自动可见。
  - 笔记格式、状态一致性、笔记间相对链接由脚本机械校验（CI 已接）。

- **代价与已知上限**：
  - **失去单文件通读**：想知道「这个项目做过哪些大决定」，要翻目录树或全文检索。
    上限：笔记数量到数十篇之前，`ls` 与 `rg` 足够；超过之后需要看板工具
    （技能目录里有 `build-board.ts` 可生成静态看板），但它生成的是**派生物**，
    不是需要手工维护的索引 —— 这个区别是本决定成立的前提。
  - **迁移的历史成本已付出**：18 条逐条改写并校验链接，一次性开销。
  - `docs/README.md`、根 `README.md`、`docs/AGENTS.md` 三处入口已同步指向笔记树；
    外部旧链接（issue、聊天记录里的 `docs/DECISIONS.md`）会失效，
    失效信息落在迁移对照表的提交里。

- **重访条件**：出现「必须在不检索的前提下通读全部决策」的真实需求
  （例如对外发布决策白皮书），那时加的是**从笔记树生成的**派生视图，
  而不是回到手工维护的第二份记录。

## Verification

```text
npx --yes tsx .agents/notes-scripts/verify-agent-note-tree.ts
npx --yes tsx .agents/notes-scripts/verify-agent-note-format.ts
npx --yes tsx .agents/notes-scripts/verify-archived-agent-notes.ts
```

判据：三条均 exit 0；`docs/DECISIONS.md` 不存在；全仓无指向它的 Markdown 链接
（`rg "DECISIONS" --glob '*.md'` 只应命中归档笔记里的历史叙述）。

[历史快照：决策笔记树进仓库，与 docs/DECISIONS.md 分工](../../archived/process/2026-10-17-agent-notes-in-repo.md)
