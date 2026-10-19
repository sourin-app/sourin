# Agent Note: 那张「控件重叠」的证据截图，其实是首页的源条 + 一个过渡帧

Status: implemented

> 同域：[../testing/2026-10-19-dns-hijack-needs-authoritative-truth.md](../testing/2026-10-19-dns-hijack-needs-authoritative-truth.md)
> 那篇是「能解析 ≠ 解析正确」；本篇是**同一个母题在像素上的版本**：
> 「我看到的东西，是不是我以为的那个东西」。
> 相邻：[2026-10-19-sheet-guard-covered-two-of-ten.md](./2026-10-19-sheet-guard-covered-two-of-ten.md)（同样是"数满足点"发现的）。

## Problem

用户报：「静音按钮都有一半没显示出来，这个窗口都没契合」，并给了一张 900×600 的截图。

前两轮（含 Lead 自己）的取证过程都很"认真"：

```text
第一轮：live-ux 静态定位，否定三条候选根因（left 负值 / 负 margin / bandFor）
第二轮：Lead 真机 900×600 采样，读到「▶/🔇 压在 chip 上」，判定 _EmbedBar 溢出
        ★ 中间还发生过一次"采样采到左侧海报上"的错误，被自己发现并撤回
第三轮：live-ux 复刻布局，测出 -8px（不重叠）⇒ 判定"复刻不忠实"
```

**三轮都在同一个前提上打转**：那张截图里的 chip 是 `lineSwitcher`（直播页的线路切换器）。

## Decision

### ① 那张 chip 根本不是直播页画的

```bash
$ grep -c "SourceBar" lib/ui/live_page.dart
0
$ grep -c "source_bar" lib/ui/live_page.dart
0
$ grep -rn "' 个源'" lib/ui/widgets/
lib/ui/widgets/source_bar.dart:335:  text: ' 个源',
```

截图里那排 chip 的文案是：

```text
次元城动画 / 哔哩哔哩 / 影视建安 / 360资源-采集 / 百度 /
光速资源(切) / 新浪资源(切) / **25 个源**
```

`个源` 这个后缀**全仓只出现在 `source_bar.dart`**，而 `live_page.dart` 里 `SourceBar`
出现 **0 次、也不 import `source_bar`** ⇒ **直播页画不出那排 chip。**

它是**首页的源切换条**。

★ 这同时解释了两件之前想不通的事：

```text
· 为什么 chip 文字是「次元城动画」这种源名，而不是「高清/标清」这种线路名
  ⇒ 因为它**就是源名**
· 为什么上一轮的阴性对照红不了
  ⇒ 它测的「控件 vs lineSwitcher」重叠，在修复前**本来就不存在**（-8px）
     那条判据测错了对象，不是"复刻不忠实"
```

### ② 那张图是一个 50% 交叉淡入的**过渡帧**

像素反解：

```text
黑卡内部 (y=200, x=300) = (120,121,124)
页面底色               = (238,240,246)
⇒ 该黑色层的等效不透明度 = 1 - 120/238 = 0.4958 ≈ 50%

而稳态（同机自拍）实测 alpha = 0.996
```

拿同机稳态的两帧做合成模型对照（裁剪原点暴力搜索到 (12,120)）：

```text
模型                         与原图的 MAE
单页稳态 live                    101.56
单页稳态 home                     93.68
0.5·live + 0.5·home                8.83    ← **只有这个能解释**
0.5·live+0.25·home+0.25·bg         5.36
```

⇒ **那张图必然是一次切页交叉淡入的中间帧**：图上同时有 home 的源条和 live 的播放器。

### ③ 但 R5 仍是真缺陷，只是形态不同

```text
900×600：
  播放窗口（ClipRRect）可用高 356
  视频按满宽 532 已占 532*9/16 = 299.25
  剩给 chip = 56.7，而两行 chip 需要 72
  ⇒ 溢出 15.3px ⇒ 被外层 ClipRRect 裁掉

1444×845：
  窗口 1074×600，视频 1074*9/16 = 604.1 ≈ 600 ⇒ 装得下
  ⇒ **不复现** —— 与用户现场完全一致（大窗没事）
```

用户说的「**这个窗口都没契合**」是真的 —— 窗口装不下自己的内容。

**修法（代码只改一行）**：

```dart
- AspectRatio(aspectRatio: 16 / 9, child: player),
+ Flexible(child: AspectRatio(aspectRatio: 16 / 9, child: player)),
```

```text
`Column(mainAxisSize: min)` 在有界高里，子项之和 > 可用高就溢出，溢出被外层裁。
`Flexible` 让**视频**让出 chip 需要的高度 ⇒ 视频等比缩小（实测 r 恒 1.778，不变形）
```

## Alternatives considered

### ① 继续按「控件 vs lineSwitcher 重叠」修

**最强论据**：前两轮的像素读数确实显示了"图标与 chip 视觉重叠"，
而代码里 `_EmbedBar` 是 `Positioned(bottom: 0)`、`lineSwitcher` 在它下面 —— 机理上说得通。

**为什么否决**：**读数是真，但读数所属的对象是错的。**

```text
· 图标确实压在 chip 上（那张图里）
· 但 chip 是 home 的源条，不是 live 的 lineSwitcher
· 而且整张图是过渡帧 —— 图标与 chip 的"重叠"是两层不同页面叠出来的
★ 一般化：**"我看到了重叠"与"这两个控件重叠了"不是同一句话。**
  中间差一步："这两个东西是不是同一页、同一时刻画的？"
```

### ② 认定「复刻不忠实」，重写复刻

**最强论据**：`live-ux` 的复刻测出 -8px（不重叠），而 Lead 的画面上有重叠 ——
两者的差异必然来自复刻与实现的偏差，所以去修复刻是最直接的。

**为什么否决**：**复刻其实是对的 —— 那个重叠在稳态下确实不存在。**

```text
实测（探针扫布局，clip 取真机自拍的 532×356）：
  n=2（一行 chip）⇒ chip 317.6..345.6   ✅ 在窗口内
  n=4（两行）    ⇒ chip 307.3..371.3   ✗ 溢出 15.3px
  n=9            ⇒ 溢出 + RenderFlex overflow 异常
  n=9, clip 1074×600（1444 窗口）⇒ 678.6..742.6  ✅
⇒ 复刻测不出重叠，是因为它测的**对象**与截图里的对象不同
   （它测 lineSwitcher，截图里是 SourceBar）
⇒ 重写复刻只会让它更"忠实"地测一个错误的属性
```

### ③ 判定「用户截到了过渡帧 ⇒ 这不是缺陷 ⇒ 不改」

**最强论据**：证据链很强（alpha 0.4958 + MAE 8.83）—— 那张图确实是过渡态。
若只针对那张图，确实不用改任何东西。

**为什么否决**：**那张图只是证据，不是缺陷本身。**

```text
用户的原话是「这个窗口都没契合」——
  而实测 900×600 下窗口确实装不下自己的内容（溢出 15.3px，RenderFlex overflow）
⇒ **证据是假的，但缺陷是真的**
★ 判据：**"这张图不能证明缺陷" ≠ "没有缺陷"。**
  要分别回答两个问题：① 这张图证明了什么 ② 这个功能有没有问题。
```

### ④ 给 `lineSwitcher` 加滚动区（让它多行时不挤压视频）

**最强论据**：更彻底 —— 线路再多也不会把视频压没，`Flexible` 那条路在 n=40 时
会把视频压到 0 高（已知代价）。

**为什么否决**：**它是 R6 的范畴，不是 R5 的。**

```text
· R5 的判据是"窗口装得下自己的内容"，`Flexible` 一行就够
· 加滚动区是**交互设计变更**（用户要滚动才能看到线路），属于 R6 那张"控件清单"的讨论
⇒ 本轮只保证 chip 不被裁，并把"n=40 时视频会被压到 0"写进代码注释作为已知代价
★ 判据：**修 A 的代价若需要 B 的设计决策，就把代价写下来，不要顺手做 B。**
```

## Consequences

### 改动与读数

```text
代码改动：lib/ui/live_page.dart 一行（Flexible 包 AspectRatio），其余 38 行是注释
live_embedded_player.dart：**零改动**（一个字节都没动）

门禁 test/zz_t66_r5_player_no_overlap_test.dart 重写，+8 全绿：
  R5-G 几何（900 / 1444 两档，9 条线路 = 2 行）：
    控件条 + chip 都必须在窗口内，且视频仍是 16:9
  R5-S 源码契约 S1/S2：`Flexible(child: AspectRatio(...))` 必须在；不许退回裸 AspectRatio
  R5-S S3/S4/S5：判据分辨力自检（含 _stripComments 自检）
  R5-N 阴性对照：用**修复前形状**跑，必须红
    [R5-N] 修复前结构：chip.bottom=793.3 clip.bottom=778.0 被裁=15.3px overflow=FlutterError

回归：+89 All tests passed
  zz_t66_r5_player_no_overlap_test / live_page_test / t65d_live_ui_test /
  t48_live_embedded_doubletap_test / t1013_live_filter_test / t58_embed_layout_test
```

### 故障注入

```text
注入：删掉 Flexible(...)，退回 AspectRatio(...)
  dart analyze 被注入文件 ⇒ 0 error（注入有效）
  ⇒ **红 4 条**：R5-G×2（900 与 1444 都红）、S1、S2
还原 ⇒ 全绿 +8；git status --porcelain 只剩 M lib/ui/live_page.dart（本轮的预期改动）
```

### ★ 门禁设计的两处改进（都来自踩坑）

```text
① **复刻形态从产品源码读**（`_implWrapsVideoInFlexible()`）
   第一版写死 `fixed: true` ⇒ 注入旧形状时 R5-G **仍然绿**（假绿）
   改成读源码后，产品退回旧形状 ⇒ R5-G **自己**红，不靠 S2 兜底
   ★ 这个设计消灭了"复刻与实现漂开"这一整类假绿

② **S2 的窗口不能再写死 400 字符**
   第一版固定窗口 + 没剥注释 ⇒ 注入时只有 S1 红
   现在：剥注释 + 按结构定位
```

### 代价与已知风险

```text
· **线路极多时（实测 n=40）视频会被压到 0 高**
  根因：`lineSwitcher` 自己没有滚动区 ⇒ 属 R6 范畴
  已在代码注释里写明；本轮只保证 chip 不被裁
· **没能端到端复现带 chip 的稳态**
  真机自拍里自动选中的频道只有 1 条可播线路 ⇒ `lineSwitcher` 是 SizedBox.shrink()
  ⇒ chip 侧的证据全部来自「探针扫布局 + 用户给的现场裁片」，
    不是"我亲眼在 900×600 带 chip 的真机上看到修好了"
· **窄屏分支 `_buildNarrowBody` 有同族风险**（899×500 下 VIDOUT=+5.7 且抛 FlutterError）
  但 `shell.dart` 的 minimumSize = 900×600 ⇒ **生产不可达** ⇒ 没修
  ⚠️ 若将来 minimumSize 变小，这里必须同步修
```

### 需要用户确认的一件事

```text
我能证明：他给我那张图**必然是** 50% 过渡态（alpha 0.4958 + 双页合成 MAE 8.83 vs 单页 93~102）
我不能证明：他当时是否在切页动画中按的截图

⇒ 若他看到的是**稳态**（动画结束后仍这样），那么「过渡帧」这个解释不成立，
   需要重新查 —— 但 900×600 下"窗口装不下内容"这条实测仍然成立。
```

### 何时该翻案

```text
① 若用户确认「稳态下也看到那排 chip 与图标重叠」
   ⇒ 过渡帧假说被推翻，必须重新查（但 SourceBar 的证据仍然成立：
     直播页画不出那种 chip，所以要么是别的页面，要么是别的控件）
② 若 minimumSize 变小（< 900×600）⇒ `_buildNarrowBody` 的同族风险变成生产可达，必须修
③ 若 R6 给 lineSwitcher 加了滚动区 ⇒ `Flexible` 的"n=40 压到 0 高"代价消失，
   但那时要复核 Flexible 是否还需要（可能可以用别的约束）
④ 若将来有频道确知有多条可播线路 ⇒ 可以补一次"真机带 chip 的稳态"验证
```
