# Agent Note: MaterialApp → WidgetsApp —— 移除 Material 的最难一步，以及它引入的真机崩溃

Status: implemented

> 同域：[2026-10-18-glass-components-replace-material.md](./2026-10-18-glass-components-replace-material.md)
> 两篇同属「移除 Material」这条线：那篇讲**组件层**替换（按钮/弹窗），
> 本篇讲**应用外壳**替换（MaterialApp → WidgetsApp）及其引入的真机崩溃。
> 那篇是面上的替换，本篇是根上的替换。

## Problem

要「彻底不用 Material」，就必须把 `MaterialApp` 换掉。但它不只是个包壳：

```text
MaterialApp 免费提供了四样东西：
  ① MaterialLocalizations（日期选择器、tooltip、对话框语义标签要用）
  ② pageRouteBuilder / 默认路由过渡
  ③ ScrollBehavior（滚动手势、滚动条样式）
  ④ 主题传播（Theme → 子树）
```

直接换成 `WidgetsApp` 会一次性失去这四样。本轮的实测结果证明了这一点：

```text
全量 flutter test ⇒ 4131 通过
但产品 Release 启动后**第一次弹窗就崩**：
  Null check operator used on a null value
  #0 MaterialLocalizations.of (material_ui/src/material_localizations.dart:718)
  #1 new DialogRoute        (material_ui/src/dialog.dart:1906)
  #5 showAppDialog          (ui/widgets/overlay_motion.dart:324)
⇒ 4131 个用例**没有一个**抓到它，因为它只在真机触发。
```

## Decision

### ① 先补 pageRouteBuilder，保住路由过渡

`fix(round-66/M4)`：`WidgetsApp` 缺 `pageRouteBuilder` 会导致平台默认过渡
（Windows 上没有过渡，页面直切）。

### ② MaterialLocalizations 用「兜底 delegate」补上

`fix(round-66/M4)`：`WidgetsApp` 缺 `MaterialLocalizations` ⇒ 任何
`DialogRoute` 构造时 `MaterialLocalizations.of(context)` 抛 null check。

做法（`lib/shell.dart`）：
```dart
class _AnyLocaleMaterialDelegate extends LocalizationsDelegate<MaterialLocalizations> {
  bool isSupported(Locale locale) => true;
  Future<MaterialLocalizations> load(Locale l) =>
      DefaultMaterialLocalizations.load(const Locale('en','US'));
  bool shouldReload(_) => false;
}
```
并注册 `supportedLocales: [Locale("zh","CN"), Locale("en","US")]`。

★ 这个 delegate 的语义是「**任何语言都解析成英文**」——
它解决的是**崩溃**，不是本地化正确性。影响面已独立核实：
当前到达用户可见文案的只有 `modalBarrierDismissLabel` / `tooltip` 这类
无障碍语义标签；`TimePicker`/`DatePicker`/`AboutDialog`/`BackButton` 用量全为 0。

### ③ 保留 `material_ui` 依赖，只为一个 delegate

这是刻意的取舍：为了 `MaterialLocalizations` 这一个类型保留整个包。
已在代码注释里写明「未来混排」的陷阱（一旦引入带可见文案的 Material 组件，
会出现「界面中文 + 该组件英文」）。

## Alternatives considered

- **继续用 `MaterialApp`，只换内部组件** —— 它最强的论据是零风险，
  四样东西都免费保留。
  否决理由：Owner 的硬要求是「彻底不用 Material 组件」。虽然 `MaterialApp`
  本身不算"组件"，但它会把 `Material` 的语义层带进来，而那正是要清的。

- **自己实现一套 `MaterialLocalizations`（中文版）** —— 它最强的论据是一步到位，
  既解决崩溃又解决本地化。
  否决理由：那是一个几十个 getter 的接口，且每个都要有正确的中文文案与
  复数/日期格式。当前产品的实际用量接近 0，投入产出极度不平衡。
  ⇒ 先修崩溃，等真的需要某个文案时再逐条实现。

- **不用 WidgetsApp，自己搭一个最小 App 壳** —— 它最强的论据是最彻底，
  不留任何 Material 痕迹。
  否决理由：`WidgetsApp` 提供的 `Navigator`/`Overlay`/`Localizations` 编排
  不是几十行能替代的，自己搭等于重写 Flutter 的 App 骨架，
  且会失去后续版本的路由修复。

- **只在测试里 mock `MaterialLocalizations`，真机不管** —— 它最强的论据是
  测试全绿。
  否决理由：这正是本轮实证的失败模式 —— 4131 个用例全绿而真机首屏弹窗就崩。
  **测试绿不等于能用。**

## Consequences

- **收益**：`MaterialApp` 移除，`Material` 语义层退到只剩一个 delegate；
  真机崩溃已修并有 `supportedLocales` 显式声明。
- **代价**：
  · 保留 `material_ui` 依赖（只为 `MaterialLocalizations`），
    与「彻底不用 Material」的目标存在张力，属已知妥协
  · locale 协商恒为英文 —— 一旦引入带可见文案的 Material 组件就会混排
- **这条最重要的教训**：**全量测试 4131 通过，产品首屏仍崩。**
  所以 AGENTS.md §6 现在硬性要求收尾必做「真机隔离启动一次」，
  且必须确认「零 Unhandled Exception」而不是"看起来没崩"。
- **重访条件**：当 `material_ui` 因其他原因可被移除时，应同时替换这个 delegate；
  若某天需要 Material 的中文文案，应逐条实现而不是整体切换。
