# 决策记录（DECISIONS）

> 2026-10-15 建立，2026-10-17 迁到 Agent Note 树。
>
> **本文件不再承载决策正文。** 全部条目已迁成
> [`.agents/notes/`](../.agents/notes/) 下的 Agent Note，与代码同批提交、可机械校验。
> 保留本文件是为了让既有的三处入口链接（[../README.md](../README.md)、
> [README.md](README.md)、[AGENTS.md](AGENTS.md)）继续有效。

---

## 决策在哪

```text
.agents/notes/{proposed,implemented,rejected,archived}/{class}/yyyy-mm-dd-主题.md
```

`class` 是封闭集 6 个：`feature` / `bug-fix` / `simplification` / `architecture` /
`process` / `testing`。每条笔记固定三段骨架：
`## Problem`（动机）→ `## Decision`（现在时事实）→ `## Alternatives considered`（真权衡过的对手方案）→ `## Consequences`（代价、收益、重访条件）。

原「何时该翻案」字段现在落在每篇的 `## Consequences` 里 —— 语义不变：
**条件一旦成立，就该回来推翻它，而不是继续执行。**

## 怎么找

不建索引（会与正文分叉），按意图直切目录：

```bash
# 架构与结构决策
ls .agents/notes/implemented/architecture/
# 流程、门禁、工具链
ls .agents/notes/implemented/process/
# 测试策略
ls .agents/notes/implemented/testing/
# 修过的缺陷与复盘
ls .agents/notes/implemented/bug-fix/

# 按关键词搜（含 proposed / rejected，排除冻结的 archived）
rg --hidden --glob '!.agents/notes/archived/**' "关键词" .agents/notes/
```

## 迁移对照

下表的编号沿用原条目编号，便于从旧链接、旧提交信息或旧讨论里回溯到现笔记。
笔记正文不重复编号 —— 一个事实只在一处讲透，映射只在本文维护。

| 原编号 | 现笔记 |
|---|---|
| A1 用 Flutter 重写 | [2026-09-22-use-flutter-rewrite-not-tauri-vue](../.agents/notes/implemented/architecture/2026-09-22-use-flutter-rewrite-not-tauri-vue.md) |
| A2 业务全放 Rust + FFI | [2026-09-01-rust-core-flutter-ui-ffi](../.agents/notes/implemented/architecture/2026-09-01-rust-core-flutter-ui-ffi.md) |
| A3 预取开关按实例读 | [2026-10-08-prefetch-switch-per-instance](../.agents/notes/implemented/bug-fix/2026-10-08-prefetch-switch-per-instance.md) |
| B1 走 PR + 必需检查 | [2026-10-08-pr-only-required-checks-that-verify](../.agents/notes/implemented/process/2026-10-08-pr-only-required-checks-that-verify.md) |
| B2 去掉 PR 规模门禁 | [2026-10-12-drop-pr-size-gate](../.agents/notes/implemented/process/2026-10-12-drop-pr-size-gate.md) |
| B3 合并要 Owner 点头 | [2026-10-14-merge-requires-owner-approval](../.agents/notes/implemented/process/2026-10-14-merge-requires-owner-approval.md) |
| B4 仓库不出现站名 | [2026-10-13-no-site-names-in-repo](../.agents/notes/implemented/process/2026-10-13-no-site-names-in-repo.md) |
| B5 凭证构建期注入 | [2026-10-12-danmaku-credentials-build-time-secrets](../.agents/notes/implemented/process/2026-10-12-danmaku-credentials-build-time-secrets.md) |
| B6 文档拆分 | [2026-10-15-readme-slim-docs-split](../.agents/notes/implemented/process/2026-10-15-readme-slim-docs-split.md) |
| B7 交互契约是验收基准 | [2026-09-22-interaction-contract-as-acceptance-baseline](../.agents/notes/implemented/process/2026-09-22-interaction-contract-as-acceptance-baseline.md) |
| B8 小工具目录不进仓库 | [2026-10-08-local-tool-dirs-not-in-repo](../.agents/notes/implemented/process/2026-10-08-local-tool-dirs-not-in-repo.md) |
| C1 native-media 用 skip | [2026-09-25-native-media-tag-skip-not-exclude](../.agents/notes/implemented/testing/2026-09-25-native-media-tag-skip-not-exclude.md) |
| C2 门禁必须能变红 | [2026-10-12-gates-must-be-able-to-fail](../.agents/notes/implemented/testing/2026-10-12-gates-must-be-able-to-fail.md) |
| C3 红基线用纯净 worktree | [2026-10-14-red-baseline-needs-clean-worktree](../.agents/notes/implemented/testing/2026-10-14-red-baseline-needs-clean-worktree.md) |
| C4 开发模式跳过更新检查 | [2026-10-15-devmode-skip-update-check-and-await-ignore](../.agents/notes/implemented/bug-fix/2026-10-15-devmode-skip-update-check-and-await-ignore.md) |
| C5 开发数据播种 | [2026-10-15-dev-data-seed-readonly-no-credentials](../.agents/notes/implemented/process/2026-10-15-dev-data-seed-readonly-no-credentials.md) |
| C6 首页判据看 home() | [2026-10-15-home-keeps-guest-source](../.agents/notes/implemented/bug-fix/2026-10-15-home-keeps-guest-source.md) |
| C7 弹幕源提到设置一级 | [2026-10-17-danmaku-source-in-settings-and-priority](../.agents/notes/implemented/feature/2026-10-17-danmaku-source-in-settings-and-priority.md) |

> 第 19 篇 [`2026-10-17-agent-notes-in-repo`](../.agents/notes/implemented/process/2026-10-17-agent-notes-in-repo.md)
> 不属于本表 —— 它记的是笔记体系自身的引入决定，不是从本文件迁出来的条目。
