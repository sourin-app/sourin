# Agent Note: 根 README 只留定位与索引，细节进 docs/

Status: implemented

## Problem

README 长到 1116 行后，改一处细节要在大文件里定位，评审 diff 噪音大；
而「开工前必读」的内容与「查配置字段」的内容受众不同 ——
把两者压在同一份文件里，两种读者都要翻过对方的内容。

## Decision

把 README 的架构 / 构建 / 配置 / 平台 / 数据目录 / 主题 / 插件 / 测试 / FAQ /
项目结构共 10 节拆到 `docs/`，根 README 收敛为定位 + 快速开始 + 文档索引。
新增 `docs/AGENTS.md`（开发入口）、`docs/RUNBOOK.md`。决策记录当时落在
`docs/DECISIONS.md`，现已迁到 [Agent Note 树](2026-10-17-notes-tree-is-single-decision-record.md)，
本决定本身不受影响。

## Alternatives considered

- **另起一套新文档重写内容** —— 它最强的论据是可以顺便修正过时描述。
  否决理由：新写的正文会与现有正文分叉，而这次改动要的是**搬家不改写**；
  采用搬家后可用脚本校验「原文每一行都能在目标文件里找到」，重写则失去这条判据。

## Consequences

- **收益**：两种读者各取所需；改细节时 diff 落在小文件里。
- **代价与已知上限**：文档从 1 处变 10 处，导航成本转移到索引页；
  `docs/` 层级若继续加深，找文档会比翻一份长 README 更慢。
- **重访条件**：文档再次碎片化（同一主题散落多篇），或 `docs/` 层级超过两层。
