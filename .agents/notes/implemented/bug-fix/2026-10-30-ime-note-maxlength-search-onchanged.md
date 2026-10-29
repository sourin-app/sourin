# Agent Note: 中文 IME 输入失效 —— 备注框 maxLength 组合期截断 + 搜索框 onChanged 全页重建

Status: implemented

Independent: task-3（批次契约 `.probe/plan-2026-10-30-field-feedback-batch.md` 任务 3）。
Owner 现场反馈：Windows 桌面端连续输入中文会"失效"。两条线索都能在**源码里证伪**，
故本条只动两处输入框 + 一个源码级门禁；实机 ≥30 字中文连打验证按批次纪律攒到批末统一做。

## Problem

```text
线索一（备注框 agg-note-input）：
  lib/ui/settings/tvbox_aggregate_page.dart 原 589 行 `maxLength: 60`。
  Flutter 的 maxLength 由 LengthLimitingTextInputFormatter 实现，它对 IME
  组合中（composing）的文本同样计数/截断 —— 拼音串还没上屏就被削断，
  组合被打断 ⇒ Windows 桌面端连打中文"失效"。

线索二（搜索框）：
  lib/ui/search_page.dart 原 880 行 `onChanged: (_) => setState(() {})`。
  IME 组合期**每一次组合更新**都触发 onChanged ⇒ 全页 setState；而搜索框住在
  SliverPersistentHeader 里，_StickySearchBar.shouldRebuild 因 child 每次都是
  新实例而恒为 true ⇒ 组合期内每一帧重建页头 delegate + 结果栅格。
  （另两项排查为阴性：全 lib `inputFormatters` = 0 处；controller 是
   State 字段级 `final` 单实例，无 build 内重建。）
```

## Decision

```text
① 备注框：去 maxLength，限长移到提交时 —— _save 里经新函数 clampNoteTo60()
  （trim + 按 characters 字形簇截 60），与 Rust 侧 tvbox_aggregate.rs:264
  `t.chars().take(60)` 同界。用字形簇而不是 UTF-16 substring，emoji/代理对
  不会被拦腰截断。
② 搜索框：onChanged 改走 _onSearchChanged() 闸门 —— 只在「文本是否为空」
  **翻转**时 setState（清空按钮可见性、搜索按钮可用性都只依赖这一点，
  行为等价论证写在代码注释里）；_clear() 里同步 _wasEmpty，防止清空后
  首字的翻转被漏掉。
③ 门禁 test/ime_field_gate_test.dart（新建，源码级，用共享
  test/_support/strip_comments.dart 剥注释）：两文件无 maxLength /
  inputFormatters；clampNoteTo60 存在且被 tvboxAggregateSet 的 note 参数引用；
  搜索页 TextEditingController 构造恰 1 处；onChanged 不得内联 setState、
  闸门 _onSearchChanged 必须存在。
```

## Alternatives considered

### A. 备注框换成自定义 LengthLimitingTextInputFormatter（组合期放行）

**最强理由**：输入框上仍能实时挡字。

**否掉的原因**：formatter 任何对组合文本的干预都在跟 IME 抢输入态，Windows 上
正是这次要修的病灶；"输入期零干预、提交时截断"才从根上消除这一类问题。

### B. 搜索框 setState 节流（Timer/帧对齐）

**最强理由**：改动更小，保留"每次输入都刷新"的语义。

**否掉的原因**：节流只是把重建频次降下来，组合期内仍然在重建；且引入定时器
状态（dispose/竞态）比"按依赖翻转重建"复杂。"build 依赖什么就为什么建闸门"
是行为等价的最小修法。

### C. 给搜索框 TextField 加 GlobalKey 兜底

**最强理由**：零行为改动，纯防丢组合态。

**否掉的原因**：外层 Container 已有 `_searchBoxKey`（task-74 遗产），真问题
不是身份丢失而是**无谓重建**；再加一把 key 是掩盖不是修复。

## Consequences

**收益**

- 备注框与搜索框在 IME 组合期不再被截断 / 不再每帧全页重建；
- 备注上限语义与 Rust 完全同界（服务端兜底截断仍在）。

**代价与边界**

- 备注框输入超 60 字不再有即时"0/60"计数反馈，超长只会在**保存后**被截 ——
  这是"输入期不干预组合态"的必要代价；
- 搜索页清空按钮的显隐仍只在空/非空翻转时刷新 —— 若将来 build 里新增
  依赖 `_controller.text` **具体内容**（而非是否为空）的 UI，必须同步扩闸门；
- 门禁是文本级断言，防回归但不替代实机手感验证（批末 ≥30 字中文连打）。

## 验证结果（已发生）

```text
① 证红（改动前源码即注入样本）：门禁首跑 5 条中 3 红 ——
   maxLength 命中 / clampNoteTo60 缺失 / onChanged 无条件 setState 命中。
② 修复后：test/ime_field_gate_test.dart 5/5 绿（.probe/ime-gate-run-final.txt）。
③ 反向注入证红（门禁非恒绿）：
   注入一：把 maxLength: 60 加回 agg-note-input ⇒ 「备注框不带 maxLength」红；
   注入二：把 onChanged 改回 `setState(() {})` ⇒ 「onChanged 不得无条件全页
   setState」红；两者随后回滚。
④ 既有测试无回归：zz_t1088_agg_split_dialogs + search_all +
   zz_t111_search_autofill_cover 共 34 条全绿。
⑤ flutter analyze errors=0（.probe/ime-analyze.txt；touched 文件仅余
   既有告警，本次新增 0 条）。
⑥ 待批末：实机连续输入中文 ≥30 字不失效（组合中态截图），由 lead 统一安排。
```

Evidence:
- .probe/ime-gate-run-final.txt（门禁 5/5 绿）
- .probe/ime-analyze.txt（analyze errors=0）
