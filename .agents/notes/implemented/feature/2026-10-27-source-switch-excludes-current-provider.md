# Agent Note: 跨源换源必须排除当前源 —— 并收回「当前源要显示」的旧决定

Status: implemented

Related: [source-switch search generations](../bug-fix/2026-11-10-source-switch-search-generation.md)
guards keyword resubmission, obsolete results and search-state lifetime. It
extends this dialog's event path without replacing the provider exclusion,
matching order or selected-result handoff specified here.

## Problem

Owner 实测换源后仍不跟进度，明确要求候选列表排除当前片源：

```text
Owner 原话（2026-10-27，逐字）：
  换源后还是没跟着上次的进度条走（换源应该要排除当前片源）
```

而当时的实现**刻意保留**当前源，且把这条决定写成了注释（`source_switch_dialog.dart` 的条目徽标一节）：

```text
原版注释（逐字）：
  当前源**要显示**而不是过滤掉
  > 用户需要看到"我现在这个源也搜到了"，
  > 这能确认搜索是对的；过滤掉反而让人以为搜漏了。
```

两条理由各自成立，但**对象不同**：旧决定关心的是"搜索完整性"（怕用户以为搜漏了），
Owner 关心的是**动作可用性** —— 点自己正在看的那个源等于原地不动，是一个"点了没反应"的选项。

## Decision

在 `_SourceSwitchDialog.build` 里按 **provider 维度**排掉当前源**整组**：

```dart
final candidates = _candidates
    .where((c) => c.provider != widget.currentProvider)
    .toList(growable: false);
final sorted = stableRankDesc(candidates, (c) => c.score);
```

四条必须守住的规则：

1. **排的是 provider 整组，不是单条 item**。候选按源分组，用户的意图是"换一个源看同一部片"；
   只排掉当前源里那一条命中，等于让用户还能点到同一个源的另一条 —— 那是半吊子修法。
2. **排空后走既有的「没有找到其他源」分支如实说**，**never** 回退成"把当前源又列出来"。
   最典型的场景是只有一个源（聚合源本身）——此时列表就是空，这是正确的结果。
3. **排序判据不变**：过滤后仍必须用 `stableRankDesc`（同分不许乱跳），且仍作用在**写进列表的那份数据**上。
4. **旧决定如实收回，不留过期结论骗下一个人**。`isCurrent` 徽标那段注释改成
   「该决定已被 Owner 2026-10-27 推翻」+ 新判据；`if (isCurrent)` 分支**保留但不再触发**
   （它是 `_CandidateBlock` 的渲染契约；上游已保证不会再有当前源的组进来）。
   保留的理由：删它要连带改构造器签名，收益为零；留着是"能力在位但不触发"。

## Alternatives considered

- **只排掉当前源里"那一条"命中（按 item 粒度）** —— 它最强的论据是更精确，
  用户可能确实想换到同一个源的**另一集/另一条**。
  否决理由：那**不是换源**（那是选集，走另一条已有路径）。换源的语义就是"换一个源"，
  同一个源留在候选里只会制造"点了没反应"。

- **保留当前源但置灰/禁用**（旧决策 + 禁用态） —— 它最强的论据是兼得
  "看到我搜到了"与"点不动"。
  否决理由：Owner 的用词是"**排除**当前片源"，不是"标注"。而且置灰项在窄列表里仍占位置、
  仍要读一遍 —— 对一个**不可选**的项来说那是纯噪声。

- **改 `_CandidateBlock`：删掉 `isCurrent` 与徽标** —— 它最强的论据是彻底，
  不留"看起来永远不会走"的分支。
  否决理由：要连带改构造器签名与 `t137` 一类关系判据，而它守的是一段**当前不可达**的渲染能力。
  收益为零、动面不小 —— 不在本项范围。

- **顺手把 `_run` 里的事件处理留在闭包里，测试自己造一份过滤逻辑** —— 它最强的论据是
  不用给生产代码加注入口。
  否决理由：那正是本仓反复踩的假绿形状（测试验的是测试自己写的那份）。
  见下面「注入口」一节。

## Consequences

- **收益**：候选列表每一个选项都**真的可选** —— 点下去必然换到一个不同的源。
  最后一个源时列表为空且被如实说明，不再出现"点了没反应"。
- **代价**：用户不再能通过换源弹层确认"我当前这个源也搜到了同一部片"。
  这层信息在**搜索页**仍有（那里不去重源），需要它的用户可以走那边。
- **注入口**（本项引入，两条）：
  ```text
  debugSwitchSearchRunner / debugSetSwitchSearchRunner
    ⇒ 替换"取候选源"那一段（真实链路里 listProviders + searchAllStream 两个调用）。
      onEvent 与真实回调**同签名同语义**，喂进去的事件走**同一个 `_handleEvent`**
      ⇒ 真的累积 / 真排序 / 真的过滤 / 真的渲染。
  ```
  存在理由：`flutter test` 里没有核心 DLL ⇒ `_candidates` 恒为空 ⇒ 在空候选上断言
  "没有当前源"是**恒真**的（铁律 149）。没有这个口子，本项的门禁全是假绿。
  为此把事件处理从 `_run` 的闭包里抽成了 `_handleEvent`，生产路径与注入路径**共用同一份**。
- **关联（必须同步的一处）**：`test/t73_search_order_test.dart` 的 `⑧-7` 源码锚点从
  `stableRankDesc(_candidates, …)` 改成 `stableRankDesc(candidates, …)`。
  ★ 这不是放水：同一条断言里**新增**了「`.where((c) => c.provider != widget.currentProvider)`
  必须在位」的钉子 —— 否则"把 `_candidates` 原样传进来"（= 取消排除）仍能让旧锚点通过。
  排序判据本身（必须 `stableRankDesc`、必须作用在写进列表的数据上）一字未改。
- **重访条件**：若 Owner 反馈"想看当前源是否也搜到了"，那不是恢复过滤前行为，
  而是在**搜索页**补更强的展示（那里本来就不去重源）。
- **验证**：`test/zz_t1055_switch_exclude_current_source_test.dart`（4 用例：主判据整组排除 /
  阴性对照排空如实说且不回退 / 非当前源不受牵连 / provider 维度不是只排一条）。
  故障注入两条：取消排除 ⇒ 1 通过 3 失败、退出码 1（`.probe/n2-injectA.log`）；
  排空后回退列出当前源 ⇒ 1 失败（`.probe/n2-injectB.log`）。
  恢复后 4 项通过（`.probe/n2-t1055-final.log`）；相关回归 168 项通过、退出码 0
  （`.probe/n2-regress2.log`，含 `t73` / `t27` / `task32` / `t77` / `t67` / `detail_follow`）。
  **未覆盖边界（如实标注）**：Owner 主诉的**换源续播**（换源后不跟上次进度）本身
  仍未复现定位 —— 本项只完成了"排除当前片源"那一半，续播待实机复现。

Independent: 本篇记录 2026-10-27 批内一次具体改动的决策；当时按标题关键词在 .agents/notes 全树检索，未发现记录同一决定的笔记，故不构成取代关系。后续部分重叠的请求代次决定见上方链接。
