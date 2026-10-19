# Agent Note: 「钉回退」清单要跟着实现一起迁移

Status: implemented

Independent: 与本仓其它 testing 笔记不同 —— 那几篇讲**判据本身**对不对
（[恒绿断言的四种形态](../testing/2026-10-19-four-shapes-of-always-green-assertions.md)、
[红测试的三种成因](../testing/2026-10-19-three-causes-of-a-red-test.md)、
[framework assertion 不是 throw](../testing/2026-10-19-framework-assertion-is-not-throw.md)）。
本篇讲一个**生命周期**问题：判据的**守备对象**被换掉时，
守着它的那张清单要一起迁移，否则会出现「钉回退没人管」的空档。

## Problem

`test/t27_w7_spinner_color_test.dart` 有一张清单：

```dart
/// 本任务修复的 6 个文件 + Lead 集成补漏的 4 个文件：
/// 修复后必须各含 ≥1 处带 color: 的 CPI（**钉回退**）
const List<String> kFixedMustHaveColor = [ … 'lib/ui/widgets/danmaku_settings_dialog.dart' … ];
```

而本轮另一个提交（`ff54fbe`）把那个文件的 **4 处 `CircularProgressIndicator`
全部换成了 `AppInlineSpinner`** ⇒ 该文件现在 `grep -c CircularProgressIndicator` = 0。

⇒ 那条断言**必然红**。★ 这是本轮引入的回归，**由执行者自查发现**。

## Decision

### ① 处置：移出清单 + 就地留注释（不是删条目了事）

```dart
// ★★★ 2026-10-19 移出：`lib/ui/widgets/danmaku_settings_dialog.dart`
// commit `ff54fbe` 把那 4 处 CPI 全部迁到了 AppInlineSpinner
//   （行内小圈需要描边按 size 按比例缩放；Material 的 CPI 做不到：
//    实测 AppLoading 的 stroke 写死 4.0，14px 时描边占直径 28.6%，比原来粗 33%）
// ⇒ 该文件现在 0 处 CPI。「钉回退」对一个已无 CPI 的文件不再有意义。
// ⚠️ **不要**改成「必须 0 处 CPI」——那会禁止将来合理地再引入 CPI。
// ★★ 钉回退的职责**已转移**，不是丢失：见 test/zz_t66_app_inline_spinner_test.dart
```

★ 注释里那句「**不要改成必须 0 处**」是关键 ——
  否则下一个人会把「移除」理解成「改成反向断言」，把清单变成禁令。

### ② ★★ 顺带补上空档：原来**根本没有**接手的门禁

```bash
$ grep -rln "AppInlineSpinner" test/*.dart
test/zz_t64_migrated_widget_gate_test.dart     ← ★ 只有一行注释，不是门禁
```

⇒ **「钉回退」的职责在迁移那一刻掉进了空档。**
  已补 `test/zz_t66_app_inline_spinner_test.dart`，5 条断言：

| # | 断言 | 守什么 |
|---|---|---|
| 1 | 迁移后的 5 处必须仍是 `AppInlineSpinner` | 有人换回去 ⇒ 红 |
| 2 | 每一处都必须**显式给 color** | 迁移时丢 color ⇒ 灰圈缺陷回来 |
| 3 | 那 5 处不许再出现 `CPI` | 换回去的另一种形态 |
| 4 | **阳性对照**（扫描器能抓到合成坏样本） | 防前三条是空断言 |
| 5 | **剥注释器自检** | 防「注释满足判据」（本仓踩过多次） |

★ 判据**不锚行号**（行号会漂），只锚「文件里处数 + 每处带 color」。

### ③ 注入验证

```text
注入 A：把 1 处换回 CPI
  → 断言 1 红：Expected <4> Actual <3>
  → 断言 3 红：Expected <0> Actual <1>       两条同时抓 ✔
注入 B：删掉一处 color
  → 红，且**精确到行号**：lib/ui/settings_page.dart:2717 ✔
```

## Alternatives considered

**A. 把该文件改成「必须 0 处 CPI」。**
最强理由：也能变绿，且反向断言更强。
否决理由：**把「钉回退」变成了「禁止引入」** ——
  将来若有人 legitimately 地在那个文件里加一处普通 spinner，
  门禁会拦住他。★ 清单的语义是「钉住已有的修复」，不是「冻结文件内容」。

**B. 保留条目，把断言改成「有 AppInlineSpinner 或有带 color 的 CPI」。**
最强理由：兼容性最好。
否决理由：**判据变宽** —— 它不再区分「迁移了」与「两种都有」，
  而后者恰恰是要抓的形态（等于半迁移）。

## Consequences

**★ 可迁移的判据**

```text
凡是把某个实现**整体替换**掉（而不是修一处），
必须同时问：**有哪些门禁在「钉」那个实现？**
  · 钉回退清单（本文）
  · 「不许出现 X」的禁令式断言（可能是错的，需一起改）
  · 依赖某个具体类名/符号的断言

★ 三者的处置不同：
  钉回退清单  → 移除条目 + 写明「职责转移到哪」
  禁令式断言  → 删掉（它会冻结文件内容）
  类名断言    → 改锚点（但要看新实现是否等价）
```

**★ 这次是「执行者自查」发现的，不是 Owner 或 CI 发现的**

```text
⇒ 一个值得学的动作：**每做完一次「实现替换」，立刻 grep 一次
  「谁在断言那个旧实现」**。
  本轮 grep CircularProgressIndicator 就发现了；
  若没做这一步，这条红会一直躺在「既存红」里被忽略。
```

**★ 顺带：既有红的确认方式**

同批复核还确认了另一条红**是既有的**，方法可复用：

```bash
git worktree add --detach .probe/wt_base <引入该改动之前的 commit>
cp -r .dart_tool .probe/wt_base/.dart_tool    # 复制，不能软链
cp sourin_core.dll .probe/wt_base/
cp libmpv-2.dll .probe/wt_base/build/windows/x64/libmpv/
flutter test …                                  # 基线读数 +3 -1，同一处
```

★ 他自己指出「与 probe 无关」**不能证明**是既有红 —— 这个自我纠正很对：
  「与某因素无关」与「在改动之前就存在」是两件事。

**已知上限**

```text
· `zz_t66_app_inline_spinner_test.dart` 只钉那 5 处。
  若将来新增调用点，需要同步更新它的「处数」判据。
· 判据不锚行号，所以它守不住「某一处被换成了别的 widget 但处数不变」
  —— 那种形态要靠断言 2（必须显式给 color）与断言 3（不许有 CPI）组合抓。
```

**何时该翻案**

```text
· 若 AppInlineSpinner 自己被换掉，这条门禁会红（断言 1）
  ⇒ 那时它就该像本次一样做一次「迁移 + 转移职责」。
· 若本仓引入 AST 或统一的「实现清单」机制，这张手工清单可退役。
```