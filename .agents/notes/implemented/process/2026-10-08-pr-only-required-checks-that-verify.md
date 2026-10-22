# Agent Note: 走 PR，不直推 main；必需检查只列「真的在验证东西」的

Status: implemented

## Problem

没有第二双眼睛时，有一类问题 CI 拦不住，本仓**每一条都真踩过**：某个分支在某种平台
组合下永远走不到、一条断言其实恒真、改了 A 忘了同步 B、并发与时序问题。
它们的共同特征是「CI 全绿，问题在用户那里才爆」。

同时有反向风险：如果必需检查里混进一条**永远 skipped** 的 job，
那等于加了一条恒过的假门禁 —— 它不验证任何东西，却让「必需检查」这个词失去意义。

## Decision

`main` 开分支保护，任何直推被服务端拒绝（GH006）。必需检查只列 `Windows` 与 `macOS`
两个 job，**不列** `Android` 与发 Release —— 后两者在 PR 上会被 job 级 `if:` 判成 skipped。

Independent: PR 流程与必需检查的准入标准。与「禁假绿」相关但那是另一篇的具体判据，本篇讲流程形态。

## Alternatives considered

- **把 Android / Release job 也列进必需检查** —— 它最强的论据是覆盖更全：
  多一个平台跑过再合，风险更低。否决理由：它们不验证 Android / Release（在 PR 上是
  skipped），列进去只是恒过的假门禁。实测 PR #1 已证：skipped 的 job 被报成 `Success`，
  列不列都不挡合并，真正挡住合并的是 `required_conversation_resolution`。
  ⇒ 不列它们的原因是**它们不验证东西**，不是「它们会卡住合并」。

- **不开分支保护，只靠自觉** —— 它最强的论据是单人开发时流程成本低。
  否决理由：上面四类问题恰恰是「自觉」覆盖不到的，且本仓已全部踩过。

## Consequences

- **收益**：合并前有一道真实的外部检查；「必需检查」四个字保持可信 ——
  列进去的都是真会跑的。
- **代价与已知上限**：破坏性操作（例如紧急回滚 main）需要临时去 Settings → Branches
  改规则，**改完必须改回来**。单人开发时 PR 流程本身有开销。
- **重访条件**：Android / Release job 改成在 PR 上真的执行（不再 skip）——
  那时**应该**把它们列进必需检查。
