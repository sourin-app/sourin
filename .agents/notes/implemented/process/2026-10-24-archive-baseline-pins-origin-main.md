# Agent Note: 归档 append-only 的基线钉 origin/main，不再默认比 HEAD

Status: implemented

> 接续 [./2026-10-17-notes-tree-is-single-decision-record.md](./2026-10-17-notes-tree-is-single-decision-record.md)
> ——那篇定的是「笔记树是唯一决策记录」，本篇管的是**归档区怎么才算真的冻结**。
> 与 `dsh-agent-notes` 插件侧的同一决定对齐（`lib/notes.js` 的 archived 分支）。

## Problem

归档区对外承诺「冻结只读：封印只增不改」。但 `notes-gate.mjs` 调 vendored 的
`verify-archived-agent-notes.ts` 时**不设** `AGENT_NOTE_ARCHIVE_BASE_REF`，
而它的默认值是 `HEAD`。

`HEAD` 与「提交之后的工作区」是同一份内容 —— 于是这条检查只对「改了还没提交」
有效。实测（真 Git 仓库）：

```
改归档笔记内容 → 同步更新 manifest 里的封印 → 提交
默认（基线 HEAD）      → exit=0，什么都没发现
显式指「改之前」的 ref → exit=1（seal changed）
```

也就是说 CI 上那道 `ok: 1 archived note(s) verified` 并没有在保护「已提交的改动」，
而它读起来像是保护了。

## Decision

`notes-gate.mjs` 在启动时解析基线：

```
显式 AGENT_NOTE_ARCHIVE_BASE_REF ── 原样尊重，不覆盖
        │
        ├─ 有 refs/remotes/origin/main ⇒ 用它
        └─ 没有                      ⇒ 退回 HEAD，并往 stderr 告警
```

`must`：**退让可以，静默不行。** 本地新仓、浅克隆、无远端的检出不罕见，
直接失败会让它们一律红；但「冻结强度下降」必须出现在输出里，
否则它只存在于注释里。

## Alternatives considered

- **钉 HEAD~1** — 不需要远端，也能发现最近一次提交的封印改动。**否掉**：只覆盖一次提交，改动随历史越走越远就越看不见；合并提交与浅克隆下 `HEAD~1` 的语义也不稳定。
- **没有 origin/main 就判红（exit 2）** — 更严格。**否掉**：代价落在没错的对象上（本地新仓、夹具都会红），而判据本该是「这次比对有没有做成」。
- **只在 CI 里设环境变量，不改 gate** — 改动最小。**否掉**：本地跑同一条 `notes-gate` 得到的绿与 CI 的绿含义不同，而它们共用同一个命令名；且 `actions/checkout` 浅克隆时该 ref 可能不存在，显式设置反而把 CI 打红。
- **钉最近一个发版 tag** — 不翻旧账。**否掉**：两次发版之间的改动仍可被悄悄改掉，那正是「冻结」要堵的窗口。

## Consequences

- **收益**：默认配置下「只增不改」真的生效 —— 已合并的封印改动现在会红。
- **收益**：退让路径有可见告警，`AGENT_NOTE_ARCHIVE_BASE_REF` 的作用也被顺带解释清楚。
- **代价与已知上限**：**需要 origin/main 才有完整强度。** 无远端/浅克隆时只剩告警。
- **代价与已知上限**：升级后，历史上「改过封印并已提交」的仓库会首次变红 —— 那是刻意收紧。实测本仓当前 154 篇笔记仍全绿、无告警。
- **重访信号**：若 CI 改浅克隆 → 要先 `git fetch origin main:refs/remotes/origin/main`，否则强度悄悄退回 HEAD。

## Verification

```sh
node .agents/notes-scripts/notes-gate.mjs
# notes-gate: 154 篇笔记，runner=node
# ok: 153 note(s) tree and relative links verified
# ok: 153 note(s) verified
# ok: 1 archived note(s) verified, 1 seal(s) in manifest
# notes-gate: 三道门禁全部通过（154 篇笔记）   ← 无「没有 origin/main」告警
```

手工对照（在 `dsh-agent-notes` 插件的夹具里做过，非本仓）：改一行归档封印并提交 →
默认 HEAD 基线 `exit=0`（空转），显式旧 ref `exit=1` 且报
`seal added/changed/removed relative to …`。本仓只验证了「钉 origin/main 之后仍然绿」
（上面那段输出，且无告警），未在本仓改封印做破坏性对照。
