# Agent Note: 行内小 spinner 需要描边按比例缩放的组件

Status: implemented

Independent: 与本仓其它 design/architecture 笔记不同 —— 那几篇讲
[material 留或换的裁决](../architecture/2026-10-17-material-keep-or-replace-verdicts.md)
与 [R1 的克制](../bug-fix/2026-10-19-r1-verdict-overturned-twice.md)。
本篇是一个**具体的组件决策**：为什么不能直接用既有组件顶替，
以及新增组件时该怎么定那个系数。

## Problem

`test/zz_t64_migrated_widget_gate_test.dart` 报一条**真产品违规**
（不是断言漂移）：

```text
settings_page.dart:3823                   CircularProgressIndicator → 应改用 AppLoading
danmaku_settings_dialog.dart  实际 4 处 > _pending 登记的 3 处
```

★ 但「直接换成 `AppLoading`」**在视觉上是错的**，两个原因：

### ① `AppLoading` 的描边不随 size 缩放

```dart
// lib/ui/widgets/app_loading.dart:371-375
final indicator = SizedBox(
  width: size, height: size,
  child: _AppSpinner(color: color, stroke: AppLoadingSize.stroke),  // ★ 写死 4.0
);
// :480 / :489   strokeWidth = stroke     ← 不随 size 算
static const double diameter = 30;   // ★ 只有这一个档
```

像素实测（`RepaintBoundary.toImage` + 沿水平中线扫描量环的横截面宽度，
深色底 `#14161B`，**未用 CopyFromScreen**）：

```text
CPI 14 / strokeWidth 2      环宽 3.0px   占直径 21.4%   ← 现状
CPI 16 / strokeWidth 2      环宽 3.0px   占直径 18.8%   ← 现状
AppLoading(size: 14)        环宽 4.0px   占直径 28.6%   +33%
AppLoading(size: 16)        环宽 5.0px   占直径 31.3%   +67%

跨尺寸看更清楚（新组件 vs AppLoading 的占直径）：
  size 12   25.0%  vs  41.7%
  size 16   18.8%  vs  31.3%
  size 30   16.7%  vs  13.3%
⇒ AppLoading 的环宽恒为 4~5px，占比在 12~30px 之间**差 3 倍**
  ⇒ 小尺寸下变成「实心圆饼感」
```

### ② 这 5 处**全是行内小圈**，不是整块 loading

```text
:2135  FilledButton.icon 的 icon 位      16px
:3709  SwitchListTile 的 trailing 位     14px
:3941  Row 里 if (s.loading) 的行内      16px
:4031  FilledButton.icon 的 icon 位      16px
settings_page:3821  健康检测行内          14px
```

⇒ 它们要的是「行内状态指示」，而 `AppLoading` 的设计意图是
  **遮罩/整块区域**（直径 30）。**两者是不同的东西。**

## Decision

新增 `lib/ui/widgets/app_inline_spinner.dart`（Owner 拍板）：

```dart
const double _kStrokeRatio = 0.14;   // 描边 = size × 0.14
const double _kMinStroke = 2.0;      // 下限（低于 2.5 Owner 说"看不清"）
const double _kMaxStroke = 4.0;      // 上限（不超过 AppLoading 默认档）
static const double _kMinSize = 8;   // size 传 0/负数的兜底
```

- 画法与 `AppLoading` **同源**（暗轨道 alpha 0.18 + 亮弧 0.4 圈 = 144°），
  但**独立实现** —— 因为 `_SpinnerPainter` 是私有类且 stroke 是常量。
- **没有改动 `app_loading.dart`**（Owner 没批那个方案）。

### 0.14 这个系数是**由实测定的**，不是拍的

替换前后像素读数（同一套测量方法）：

```text
基线 CPI 14 / 2              环宽 3px   占 21.4%
基线 CPI 16 / 2              环宽 3px   占 18.8%
★新  AppInlineSpinner(14)   环宽 3px   占 21.4%
★新  AppInlineSpinner(16)   环宽 3px   占 18.8%
⇒ 与基线完全一致（差 0px，目标 ±0.5px 以内）⇒ 0.14 不需要调
```

跨尺寸一致性（新组件在 8~20px 恒为 3px 环宽，比例随尺寸线性变化）。

## Alternatives considered

**① 直接 `AppLoading(size: 14/16)`。**
最强理由：一行改动、零组件风险，且 `about_page.dart:429` 已有先例。
否决理由：**描边粗 33%~67%**（上面读数），视觉是退化不是修复。

**② 改 `AppLoading` 让描边按比例缩放。**
最强理由：从根上修好，符合直觉。
否决理由：**改公共组件**。Owner 未批。
★ 复核补充了实测：调用点只有 **14 个**（不是我原先估的 30 个），
  其中 13 个用默认 30px（缩放后 30×0.14=4.2，几乎不变），
  真正会变的只有 `about_page:429` 一处 ⇒ 影响面其实很小。
  ⇒ **若将来 Owner 改主意，这条方案的成本比看上去低得多。**

**③ 登记进 `_pending` 当已知例外。**
最强理由：诚实。
否决理由：**这条门禁的存在意义就是清零**，登记例外等于把它变成装饰。

## Consequences

**★ 顺带修掉一个既存 analyze 问题**

```text
danmaku_settings_dialog.dart:76  Unused import: '../../design/widgets/app_icon_button.dart'
★ 核实：AppIconButton 在该文件里计数为 0，且 HEAD 版本就已经是 0
  ⇒ 这不是本轮引入的，是既存问题（落在改动范围内 ⇒ 顺手清）
⇒ unused_import 从 1 → 0
```

**★ 顺带查出一个既存的「注释与代码不符」**

```text
lib/ui/settings/about_page.dart:429 的注释写「描边从 2 提到 2.8」
但实际传的是 AppLoadingSize.stroke = 4.0 ⇒ 注释描述的是旧的意图
★ 未修（不在授权范围）—— 但这正是「注释比行号更会骗人」的又一例：
  读注释会以为那个按钮的圈是 2.8，实际是 4.0。
```

**验证**

```text
analyze：0 error，unused_import 清零
相关测试：+45 All tests passed!
注入① 任一处换回 CPI ⇒ 门禁红（证明 _pending 删掉后门禁真的被激活）
注入② size 传 0 / 负数 ⇒ 不崩，夹到 8px
```

★ **兜底为什么不用 `assert`**：这是展示组件，`assert` 在 release 下不生效、
  debug 下红屏 —— **用户看到白屏比看到一个小圈糟得多**。

**★ 关于注入的一次过程失误（复核自己披露的）**

```text
inj_gate2.py 里用了 MSYS 路径（/d/WishProject/...）做 shutil.copy，
Python 在 Windows 下不认 ⇒ FileNotFoundError ⇒ 脚本提前退出。
⇒ 那一次看到的变红其实是 settings_page 造成的，不是 danmaku 那一处。
⇒ 若不查，会把「settings_page 的注入」误报成「danmaku 的注入」——
   也就是说，**两个注入都生效了，但读数被归因错了**。

★ 判据：**每个注入必须能区分「它自己造成的红」**。
  两个注入共用一次运行时，或一次跑崩在中间，
  归因就会串。⇒ 注入要一次一个、且崩了要重跑。
```

**已知上限**

```text
· 新组件只有 5 个调用点，视觉读数覆盖 8/10/12/14/16/20/24/30
  但**只在深色底 `#14161B` 上量过** —— 浅色主题下的观感未验证。
· `_kStrokeRatio = 0.14` 是从「与 Material CPI 的 strokeWidth:2 在
  14~16px 上观感一致」反推的，不是从「什么比例最好看」来的。
  若将来 Owner 认为 0.14 偏细/偏粗，改这一个常数即可（读数表会给出前后差异）。
```

**何时该翻案**

```text
· 若 Owner 将来同意方案 ②（改 `AppLoading` 按比例缩放），
  本组件应当**并入** `AppLoading`（比如让它接受 size 时自动缩放），
  而不是长期并存两个 spinner。
· 若本仓将来引入 AST 或统一的 design-token 机制，
  这个「0.14」应当变成 token，而不是裸常量。