# Agent Note: task-3 IME 组合期行为级门禁 —— maxLength 组合中截断的实测机理

Status: implemented

Independent: 与 `2026-10-30-ime-note-maxlength-search-onchanged.md`（源码级门禁：断言源码里没有 maxLength）
互补而非重复：那条断言"我们没写 maxLength"，本条的断言是"没写 maxLength 之后 IME 组合态真的不丢字"。
两条合起来才覆盖验收口径③（真机连续输入中文 ≥30 字不失效）的代码侧。

## Problem

Owner 现场反馈 Windows 桌面端连续输入中文"失效"（计划任务 3）。修复做法是移除备注框 `maxLength: 60`、
把限长移到提交时（`clampNoteTo60`），但当时的门禁只到**源码级**——检查"源码字符串里有没有 maxLength"。
源码级断言证明不了行为：它抓不到"框架层 maxLength 对组合态文本做了什么"。

真机实机验证又被物理条件卡住：Owner 持续占用机器、Flutter 窗口不响应 PostMessage 合成输入
（实测两次截图字节完全相同 42820）。⇒ 需要一层不依赖 UI 的**行为级**证据。

## Decision

新建 `test/t20261030_ime_composing_behavior_test.dart`，用真实 `TextField` + 真实 TextInput 通道
（`tester.testTextInput.updateEditingValue` 带 `composing: TextRange(...)`）驱动 IME 组合态，分四组断言：

1. **生产形态（无 maxLength）**：40 / 80 / 120 字组合态逐字保留、`composing.isValid` 仍为 true；
   组合中逐段追加（40→80→120）前文不丢。
2. **缺陷形态对照（`maxLength: 60`）**：80 字组合态被截到 60（断言截断确实发生）；
   40 字（未超限）不截断 ⇒ 说明缺陷只在长文本触发。
3. **`clampNoteTo60`**：≤60 字形簇原样、>60 截到 60 且必须是前缀、70 个 emoji 不被截出半个代理对、空白返回空串。

组②是判据有效性证明：它固化实测读数"maxLength=60 会把 80 字组合态截到 60"，
所以若有人把 maxLength 加回生产代码，组①的 `equals(eighty)` 断言必然红。

## Alternatives considered

- **只保留源码级门禁**：最省事，但证明不了行为；且 Owner 反馈的失效若来自框架层（而非我们写的字符串），
  源码级断言完全看不见。否决。
- **等真机实机输入**：验收口径要求的最强证据，但今天不具备条件（Owner 占用机器 + Flutter 不响应合成输入）。
  保留为待补项，不用它替代代码侧门禁。
- **mock TextInputClient**：能模拟但绕过了真实 `TextField`/`EditableText` 路径，属假绿形态。否决。
- **改生产代码做注入证红（加回 maxLength 跑一遍再回滚）**：本想这么做，但发现可以在同一测试文件里
  用 `maxLength: 60` 的对照实例达到同样效果——既证明了判据有效性，又不用改生产代码冒险。采用此方案。

## Consequences

实测读数（2026-10-30，`test/t20261030_ime_composing_behavior_test.dart`）：

```text
无 maxLength： 40 字组合态 => characters=36 composing=(0,36)  full=true
无 maxLength： 80 字组合态 => characters=78 composing=(0,78)  full=true
无 maxLength：120 字组合态 => 完整保留                       full=true
maxLength:60： 80 字组合态 => characters=60                  full=false   ← 组合中被削断
maxLength:60： 40 字组合态 => 完整保留（未超限）
```

⇒ **缺陷机理实锤**：Flutter 的 `maxLength`（`LengthLimitingTextInputFormatter`）对 `composing` 区间
同样计数并截断，拼音/候选未上屏就被削短、组合被打断。这就是 Owner 看到的"中文输入失效"。
⇒ 也反过来证明 task-3 的修法（去 maxLength + 提交时 `clampNoteTo60`）方向正确。

门禁读数：`flutter test test/t20261030_ime_composing_behavior_test.dart` ⇒ **10 passed / 0 failed**。

边界（如实记录）：

- 本门禁证明"框架行为 + 我们的截断函数"正确，**不等于**真机实机输入已验证；
  验收口径③的实机部分仍需真 IME 输入（待 Owner 空闲窗口，或用真输入法手打）。
- 组②的截断读数是 Flutter 具体版本行为；若未来 Flutter 改变 `LengthLimitingTextInputFormatter`
  对组合态的处理，组②会红——那时应按新读数更新本笔记与断言，而不是放宽组①。
