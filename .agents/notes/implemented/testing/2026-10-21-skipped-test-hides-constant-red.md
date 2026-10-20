# Agent Note: 被 skip 的测试里，恒红断言可以躺很久没人发现

Status: implemented

> 同域：[2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)
> （判据要精确到"为什么"）；本篇管的是**判据失效后没人看得见**。
> Independent: 本篇的形态是「跳过机制吞掉了失败信号」，与上述那篇的
> 「断言强度不足」不是同一个失效点。

## Problem

`test/player_episode_nav_boundary_test.dart` 的**阳性对照**恒红：

```text
Expected: exactly one matching candidate
  Actual: _TextWidgetFinder:<Found 0 widgets with text "下一集": []>
```

它躺在仓库里很久，因为本文件挂 `@Tags(['native-media'])`（默认不跑）。
全量跑时 skip 只体现为 `~N` 计数器 +1，`grep "All tests skipped"` 计数 = 0
⇒ **一条恒红的断言可以躺很久，没有任何信号**。

### 两个真原因（都不是产品缺陷）

**① 断言过时：「下一集」不是 Text，是图标按钮的 tooltip**

```text
lib/ui/player/player_bottom_bar.dart:727
  _BarAction(icon: AppIcons.skip_next, tooltip: '下一集', …)
  ⇒ _BarIconButton ⇒ IconButton(tooltip: tooltip, icon: Icon(…))
```

`find.text('下一集')` 永远匹配不到 —— 文字在 `Tooltip.message` 里。

**② 阳性对照不能靠点按钮：`IgnorePointer` 会吞掉点击**

```text
player_bottom_bar.dart:771
  IgnorePointer(ignoring: fade.value < 0.5, child: Opacity(...))
```

起播失败后控制条淡出，一旦 `fade < 0.5` 就是**看得见但点不动**。

实测三个读数（这就是我踩的坑）：

```text
按钮几何 Rect(1184,740,1224,780)  ← 在 1280×800 视口内，正常
gotoEpisode 0→0 且 blockedNav 0→0 ← 压根没点到
```

⇒ **「找得到 + 有几何」不等于「点得动」。**

## Decision

### ① 断言改用 `find.byTooltip`，不用 `find.byIcon`

```text
tooltip 是**产品自己的语义**（'下一集'）⇒ 换图标时会跟着换
find.byIcon(AppIcons.skip_next) 绑死在图标常量上 ⇒ 产品换图标就假红
★ 判据：**用语义，不用实现细节。**
```

4 处 `find.text` 全改：`:341`（阳性对照）、`:380`、`:406`、`:431/:433`。

### ② 阳性对照改走遥控通道

`execRemoteForTest` 已在 `:232` 注册 `setGlobals`，能真的走到
`_gotoNextEpisode`，且**绕开 `IgnorePointer`**。按钮**可见性**仍单独断言。

### ③ 用两个计数器区分三种状态（这是关键判据）

产品文档明写「单独看 `blockedNav` 没有意义」：

```text
gotoEpisode 不变 + blockedNav 也不变  ⇒ 压根没点到（仪器问题）
gotoEpisode 不变 + blockedNav +1      ⇒ 被边界拦住了（判据生效）
gotoEpisode +1                        ⇒ 真的切了（阳性对照期望）
```

★ **这三行是本次修的核心**：没有它，「没点到」会被读成「判据生效」。

## Alternatives considered

### ① 把 `@Tags(['native-media'])` 去掉，让它进全量跑

**最强论据**：一劳永逸 —— 进了全量就不会再躺。

**为什么否决**：**它挂标签是有原因的，文件头写着完整证据链**
（`.probe/native-media-tests.md`）：加载 libmpv 时 `flutter_tester` 原生崩溃
（`c0000005`）。去掉标签会让全量跑出现不可预测的崩溃，**反而让全量读数不可信**。

★ 正确的解法不是"去掉 skip"，而是**让 skip 区有定期抽检机制**
（`--run-skipped` 跑一遍）。这次就是 `r5-live` 抽检捞到的。

### ② 用 `find.byIcon(AppIcons.skip_next)` 定位按钮

**最强论据**：图标是按钮最直接的特征，比 tooltip 稳（tooltip 可能被改文案）。

**为什么否决**：**反了。** tooltip 是**语义**（"这个按钮干什么"），
图标是**实现**（"用什么图形表示"）。产品换图标（比如换成 `skip_next_outlined`）
时，语义不变而图标变 ⇒ `byIcon` 假红，`byTooltip` 仍绿。

★ 判据：**断言要绑在"这个按钮是什么"上，不绑在"它长什么样"上。**

### ③ 在测试里手动把 `fade.value` 拉满，再点按钮

**最强论据**：这样测的就是"真实的点击路径"，比遥控更接近用户操作。

**为什么否决**：**要拉 `fade.value` 就得先能拿到那个 `AnimationController`**，
而它藏在 `_BottomBar` 的私有 State 里，没有 debug 入口。
为此新增一个 `@visibleForTesting` 的 setter，等于**为了测试改产品 API**
（违反「新增公开 API 必须同时给出调用点」）。

★ 而且遥控通道**本来就是用户真实路径之一**（手机端发命令），
  不是"测试专用后门"—— 文件 `:199-209` 已说明它走的是
  `与真实手机命令完全同一条分发路径`。

### ④ 只修 4 处 `find.text`，不动阳性对照

**最强论据**：改动最小，只碰坏掉的那几行。

**为什么否决**：**实测证明不行** —— 改完 `byTooltip` 后，阳性对照仍然红：
`gotoEpisode 0→0，blockedNav 0→0`。根因是 `IgnorePointer`，不是 finder。
⇒ 只修 finder 会得到一个"看起来修好了但实际没验到东西"的测试。

## Consequences

### 收益

```text
· 一条躺了很久的恒红断言被修好（+0 -1 → +6 全绿，--run-skipped 下真跑）
· 阳性对照现在真的能验到"仪器能数到正常切集"
· 两个计数器一起读的判据被写进注释，下一个人不会再把"没点到"读成"判据生效"
· 顺带记下 IgnorePointer 这个形态：按钮看得见 ≠ 点得动
```

### 读数

```text
修前  +0 -1（阳性对照第一条就红）
修后  +6 全绿

故障注入（删掉 _gotoNextEpisode 里 n == null 的 return）：
  dart analyze  ⇒ 0 error（排除写坏语法）
  flutter test  ⇒ +0 红
  抓住它的断言 ⇒ ★★★ 遥控 next_episode：最后一集时计数不变
                 Expected: <0>  Actual: <1>
还原后  git status 空 / analyze 0 error / +6 全绿
```

### 代价

```text
· 阳性对照不再走"点按钮"，而是走遥控 —— 覆盖的是命令分发路径，
  不是按钮的 onPressed 路径。若哪天按钮接线断了，这条测不出来。
  ★ 缓解：按钮**可见性**仍单独断言（find.byTooltip findsOneWidget），
    但那只是"在不在"，不是"点得动"。
· 本文件仍挂 @Tags(['native-media'])，仍默认不跑 ⇒ 下次失效还是会躺。
  ⇒ 唯一防线是定期 `--run-skipped` 抽检，而那是**人的纪律**，不是机制。
```

### 何时该翻案

```text
① 若将来给 `_controlsVisible` / `fade` 加了 debug 入口 ⇒ 阳性对照可以改回
   点按钮，那样覆盖的是真实点击路径，比遥控更贴近用户操作
② 若 `native-media` 标签的根因（libmpv 原生崩溃）被解决 ⇒ 去掉标签，
   让它进全量跑，问题就从"靠人抽检"变成"每次 CI 都验"
③ 若产品把「下一集」从图标按钮改回文字按钮 ⇒ `byTooltip` 仍能匹配
   （tooltip 还在），但断言「必须可见」的语义要重新想一遍
```

## 给下一个人的提醒

```text
★ 本次最值得记的不是"改了 4 处 finder"，而是这个形态：
  **两次都是「仪器没工作」，不是「判据生效」。**

  第一次（文件 :212-231 已记）：_globals == null ⇒ 遥控命令被丢弃
  第二次（本次）：IgnorePointer 吞点击 ⇒ 按钮点不动

  两次的症状完全一样：计数 0→0。
  ⇒ 判据：**看到"计数没涨"时，先问"仪器动了吗"，再问"判据生效了吗"。**
    区分方法就是读**两个**计数器，而不是一个。
```
