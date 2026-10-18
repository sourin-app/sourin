# Agent Note: 底栏装卸子树的代价 —— 结构存在 ≠ 它是重建的来源

Status: implemented

## Problem

播放页「鼠标一动就卡」（Owner N11）。此前的修复（`e6458e5`）已经让控制条显隐
不再 `setState` 整页，`pageBuild` 稳定为 0 —— 但门禁 `zz_t66_player_jank_test.dart`
仍是红的：8 轮「收起→叫回」的元素重建面 **1624**（门禁自带改前基线 188）。

```text
T6 8 轮  pageBuild=0  all=1624  p50≈55ms  max≈73ms
                  ↑ 整页不重建了，但每轮仍有 ~203 个元素在重建
```

⇒ 「不重建整页」并不等于「不重建」。局部化的**粒度**选错了位置。

## Decision

底栏包装层只负责**一个结构问题**：占据态要不要留在树上。其余情况恒挂，
淡入淡出交给底栏自身已有的 `fade` 动画。

```dart
if (_bottomOccupied) return const SizedBox.shrink();  // 占据态：原样卸下
return child!;                                        // 其余：恒挂，只翻 opacity
```

改前的写法是 `shrink ⇄ child` 装卸：

```dart
final keepForFade = !_bottomOccupied && _controlsAnim.value > 0;
if (!_chromeVisible && !keepForFade) return const SizedBox.shrink();
return child!;
```

`child` 是整个 `_BottomBar`（333 行 / 128 个后代元素）。控制条一收起就返回
`shrink` ⇒ 整棵子树 **deactivate**；鼠标一动叫回来 ⇒ **重新 activate**。
实测那一次重建 **398** 个元素 / **85ms**：

```text
IconTheme×22, DefaultSelectionStyle×22, GestureDetector×17,
RawGestureDetector×17, Focus×13, Actions×12, InkWell×11,
_MaterialInterior×11, _ShapeBorderPaint×11 …
```

**为什么只要 4 行**：淡出底栏自己早就做好了。`player/player_bottom_bar.dart`
已有 `IgnorePointer → Opacity`，由 `fade` 驱动，而 `fade` 就是 `_bottomFade`
（与顶栏**同一个** `_controlsFade` 实例）。包装层一直在做一件底栏已经做完的事，
只是它做的方式（装卸）是错的。

占据态必须**仍然整条卸下**：`_bottomOccupied`（错误层/选集/换源/设置/弹幕/
字幕/直播频道/音频提示/画面死亡）时那块归占据者 —— 留在树里会叠字、抢点击。

## 归因更正：我最初的判断是错的

```text
我的假设（Lead 按代码结构核实过）：`_TopBar` 重建面太大。
实测：_TopBar 内重建 = 1，_TopBar 外 = 397。
```

Lead 核实的是「代码结构长什么样」——那没错：`ListenableBuilder(_controlsLive)
→ _TopBar` 确实存在。但**结构存在 ≠ 它是重建的来源**。

顶栏那种改法（`_controlsLive` + 常挂 + Opacity）是对的，缺的是底栏这半边没同步改。
**不要再动顶栏。**

## Alternatives considered

**① 把 `_TopBar` 再切一层**（我最初的方案）
按「变/不变」把 370 行的 `_TopBar` 拆开，让标题/进度这类不依赖控制条显隐的部分
不跟着重建。**否掉**：实测顶栏内重建只有 1 个元素，那里根本没有可省的。
按错误假设动手会改一个不热的地方，还留下更难懂的代码。

**② 保留 `shrink ⇄ child`，只把 `child` 变小**
把 `_BottomBar` 拆成「必须常驻的部分」和「可装卸的部分」。**否掉**：底栏是一个
整体视觉条，拆开后任一部分装卸仍会触发重新布局；而且它已经有现成的 `fade`，
再造一套重复机制。

**③ 用 `Offstage` 代替 `shrink`**
`Offstage(true)` 会让子树保留在 element 树里但不布局。**否掉**：它不参与布局，
从 `Offstage` 切回正常仍要重新布局整棵子树 —— 省的是 paint，省不了我们要省的
build + layout。而 `Opacity` 已经在底栏内部生效了。

## Consequences

**收益（实测，同机 `--concurrency=1`，`Stopwatch` 围 `pump()`）**

```text
                改前        改后        变化
8 轮 all        1624        20          81×
帧 p50          55ms        1.6ms       34×
帧 max          73ms        2.0ms       36×
淡出曲线        1.00→…→0.00  1.00→…→0.00  同形（未变硬切）
```

**代价与限制**

- `Opacity` 的子树**仍然参与命中测试**，所以「看不见时点不到」必须由
  `IgnorePointer` 保证。底栏内部已经有（`player_bottom_bar.dart`），
  这里**不重复包一层** —— 重复包会让语义分散在两处，将来改一处忘一处。
- 常挂意味着底栏的 128 个元素始终在树上（内存/遍历成本）。对播放页这个量级
  可以接受；若将来底栏显著变大，需要重新权衡，而不是无脑常挂。
- 读数来自 `flutter_tester` + software rendering，绝对毫秒真机会更低。
  但 8.6 倍（188→1624）是**相对**对比，且真正的判据是「切换时重新插入 333 行
  子树」这个**结构性事实**，与渲染后端无关。

**连带改动：两条既有门禁从「钉实现」改成「钉契约」**

`t27_w13_chrome_ssot_test.dart` 的 A3 与 `t27_w13_defect4_bar_linkage_test.dart`
的 B2 原本逐字钉住 `keepForFade` 这个**变量名**：

```dart
expect(page.contains('if (!_chromeVisible && !keepForFade) {'), isTrue);
```

本修复让这个变量**不再需要**，变量消失**恰恰是改进**，但门禁红了。
改成断言契约：不许用 `_chromeVisible` 决定「要不要卸下底栏」（这才是「同源」
的真实意图）、必须喂 `fade: _bottomFade`、只在 `_bottomOccupied` 时卸下。

★ 必须验证新门禁在**旧实现**下会红，否则就是把好门禁改成废门禁。
实测：旧实现 ⇒ A3 红 + B2 红 / 新实现 ⇒ 13/13 绿 /
注入「fade 换别的 Animation」⇒ A4+B2 红 / 注入「删掉占据态分支」⇒ A3+T2 红。

**何时该翻案**

- 若底栏元素数大幅增长（比如加了很多常显控件），常挂的内存成本需要重估。
- 若将来出现「底栏内部有必须停止运行的定时器/动画」的需求，恒挂会让它们
  一直跑 —— 那时要引入「降级到 Offstage + 停表」的机制，而不是继续常挂。
