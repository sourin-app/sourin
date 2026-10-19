# Agent Note: R1「毛边」的裁决被读数推翻两次，最后发现对象选错了

Status: implemented

> 同域：[../architecture/2026-10-17-material-keep-or-replace-verdicts.md](../architecture/2026-10-17-material-keep-or-replace-verdicts.md)
> 那篇有「6 类组件已换掉；1 处按证据保留」的先例；本篇是**同一种克制**在 R1 上的第二次应用。
> 相邻：[2026-10-19-sheet-guard-covered-two-of-ten.md](./2026-10-19-sheet-guard-covered-two-of-ten.md)（同类：读数推翻假设）。

## Problem

用户反馈：「这个弹幕旁边一圈毛边」。

最初的根因分析（核过框架源码，机制描述属实）：

```text
ActionChip 内部：
  chip.dart:1440  Material(shape: resolvedShape, clipBehavior: widget.clipBehavior)
                                          默认 Clip.none
  chip.dart:1449    Ink(decoration: ShapeDecoration(shape: resolvedShape, color: ...))
⇒ 同一圆角矩形画两遍 + 不裁剪 ⇒ 两层各自抗锯齿 ⇒ 边缘叠加
⇒ 纯黑底上表现为「一圈比内部略亮的边」
```

裁决：加 `clipBehavior: Clip.antiAlias`。

**这个裁决被逐像素读数否掉了。**

## Decision

### ① 裁决 1 被推翻：`Clip.antiAlias` 让边缘**更亮**，方向相反

逐像素读数（纯黑视频底，`RepaintBoundary.toImage`→rawRgba，
以**真 RenderBox 矩形**为几何基准，环带 = 距 stadium 边界 [-1.5,+1.5]px，
内部 = 距边界 >=4px 的中位数）：

```text
clipBehavior                 环带均值  环带峰值  内部中位   Δpeak
Clip.none                      4.505     8.641     8.641   0.000   ← 边缘不比内部亮
Clip.hardEdge                  5.433     8.641     8.641   0.000
Clip.antiAlias                 4.590    10.228     8.641  +1.587   ← **更亮**
Clip.antiAliasWithSaveLayer    4.506     9.228     8.641  +0.587
```

DPR 1.25 / 1.5 / 2.0：`none` 恒 0.000；`antiAlias` 恒 +1.0~+1.7。`opacity=0.5` 时 antiAlias +1.000。

**机制**（为什么方向相反）：

```text
Clip.none 时：上层 Ink 的抗锯齿边缘 与 下层 Material 的**实心底**做 source-over
              ⇒ 覆盖率**互补** ⇒ 边缘被补回接近实色
一旦 pushClipPath：下层在边缘被截断 ⇒ 上层那点半透明**直接与视频背景混合**
              ⇒ 出现更亮的环带
```

⇒ 决策：**常量定为 `Clip.none`**，并在代码里钉死 4 条反证判据
（谁要是"顺手改成 antiAlias"，4 个 DPR 全部判红）。

### ② 裁决 2 也被推翻：「边缘在动」不成立

我的下一个假设：chip 是半透明（`alpha 0.55`）叠在**每帧都变**的视频背景上，
边缘像素每帧不同 ⇒ 人眼看到的是闪烁而不是"更亮"。

多帧方差读数（5 帧真实视频底，底图亮度 span=237 已断言）：

```text
                    edgeStd   innerStd   ratio   内部逐帧亮度幅度
弹幕 chip            1.6486    0.0000     —        0.00
站名徽章(自绘)      39.4888   30.2383    1.31   104.00
纯不透明底(alpha=1)  1.8818    0.0000     —        0.00   ← 对照基准
```

```text
chip 的 edgeStd = 1.65，比"纯不透明圆角块"的对照基准 1.88 **还小**
⇒ 边缘那点抖动是抗锯齿的必然结果，不是缺陷
⇒ 「边缘在动」假设被否掉
```

### ③ ★ 但方差读数发现了真正的对象错位

```text
chip.innerStd = 0.0000，内部逐帧亮度 [8.64, 8.64, 8.64, 8.64, 8.64] 幅度 0.00
badge.innerStd = 30.2383，内部逐帧亮度 [8.00, 104.74, 37.74, 70.29, 112.00] 幅度 104.00
```

**弹幕 chip 其实是不透明的，半透明的是站名徽章。**

```text
站名徽章 = Container(BoxDecoration(color: black@55%))          直接压在视频上 ⇒ 真半透明
弹幕 chip = ActionChip ⇒ Ink(black@55%) 叠在 Material(不透明) 上 ⇒ 合成后不透明
           ★ backgroundColor 只喂给了上层 Ink，
             下面那层 Material 用的是**不透明** theme canvasColor（实测亮度 19.28）
```

★ 这两者颜色（`black@55%`）与圆角（`Radii.rFull`）**完全同值** ——
这是上一轮就发现的「天然对照实验：视觉规格相同、渲染载体不同」。
现在它有了**量化证据**：同值规格下，合成路径不同 ⇒ 一个随背景抖 104 级、一个纹丝不动。

## Alternatives considered

### ① 坚持加 `Clip.antiAlias`（"机制对了，结论应该也对"）

**最强论据**：机制描述确实成立（同一圆角画两遍 + 不裁剪是事实，我核过框架源码），
而"裁剪能去掉重叠的抗锯齿"在直觉上非常自然；而且这条改动只有一行，风险看起来极低。

**为什么否决**：**机制成立 ≠ 结论成立，中间那步我没验。**

```text
机制：两层各画一次圆角矩形，都不裁剪          ← 属实
推论：所以边缘有两层抗锯齿叠加 ⇒ 比内部亮      ← **这一句没验**
实测：边缘 Δpeak = 0.000（不比内部亮）
⇒ 中间那步错了：两层做 source-over 时覆盖率是**互补**的，
  叠加的结果是"补回实色"，不是"更亮"
★ 一般化：**"结构上有两次绘制"推不出"结果上会更亮"。**
  凡是"因为 A 所以视觉上 B"的判断，B 必须量。
```

### ② 不改，直接结案（"复现不出就当没有"）

**最强论据**：探针条件下确实复现不出（`Δpeak=0.000`、`edgeStd` 比对照组还小），
按"没证据就不改"的原则，这是最诚实的处置。

**为什么否决**：**用户看到了东西，而我看不到 —— 先怀疑我的观测条件，不是怀疑他的眼睛。**

```text
· 我的读数来自"纯黑底 + 单独挂载的 chip"，而用户看的是"真实视频帧 + 播放器叠加层 + 真机 DPR"
· 方差读数已经证明了**对象可能选错**：真正随背景变化的是站名徽章（104 级），不是 chip（0 级）
⇒ 结案会让真正的缺陷继续存在，而我们已经知道该往哪儿看
```

### ③ 把 chip 改成自绘（"彻底摆脱 Material 的合成路径"）

**最强论据**：既然问题出在 `ActionChip` 的 `Ink + Material` 双层合成，
自绘一个 `Container + BoxDecoration` 就只有一个渲染层，从根上消除双绘。
而且整排其它徽章**本来就是自绘的**，改成自绘反而统一。

**为什么否决**：**它会踩本仓 UI-1 门禁，而且收益已被读数否掉。**

```text
· `zz_ui1_no_handrolled_controls_test` 明确要求手写药丸换成
  ChoiceChip / FilterChip / ActionChip —— 手绘会被直接判红
· 更根本：chip 的 Δpeak 已经是 0.000、edgeStd 比对照组还小
  ⇒ **它本来就没有"更亮的边"** ⇒ 为它改成自绘是解决一个不存在的问题
★ 而且 ActionChip 带来整块可点 / 涟漪 / 焦点环 / 读屏语义，自绘要全部重做
```

### ④ 给 chip 加不透明底（"让它像站名徽章那样稳定"）

**最强恩据**：方差读数说 chip 内部幅度 0.00（已经稳定），
而站名徽章抖 104 级 —— 若要"稳定"，给徽章加不透明底就行，chip 不用动。

**为什么否决**：**这是把结论套在了错误的因果上。**

```text
chip 内部稳定（0.00）是因为它**已经**不透明了（下层 Material 挡住）
站名徽章抖 104 级是因为它**真的**半透明
⇒ 若用户说的是徽章，"加不透明底"会改变它的视觉设计（从"压在画面上的半透明标签"
  变成"实心标签"），这是**设计变更**，不是缺陷修复
⇒ 必须先确认用户指的是哪一枚，再决定改不改 —— 不能在不确定对象时动设计
```

## Consequences

### 最终状态

```text
· `kDanmakuChipClipBehavior = Clip.none`（player_page.dart:19801）
  注释里钉了四条 Δpeak 读数 + "改成 antiAlias 会让 4 个 DPR 全部判红"的警告
  ★ 标题行写的是「**实测选出来的值，不是默认值**」——
    防止后人以为是没人想过就随手写的默认值
· 4 条反证判据在 `zz_t66_r1_danmaku_chip_edge_test.dart`（+6 全过）
  注入 A：删掉 clipBehavior 参数 ⇒ +5 -1 红（反证那条分不出差异）
  注入 B：常量改成 antiAlias ⇒ +1 -5 红（4 条 Δpeak<=0.5 判据全红）
· 多帧方差门禁在 `zz_t66_r1_dynamic_backdrop_variance_test.dart`（+3 全过）
  注入：让探针返回真半透明自绘件 ⇒ 内部幅度 0.00 → 40.00，+2 -1 红
```

### R8（同一批、不同缺陷）—— 修好了

```text
`cache_page.dart:2116` `opacity: _hover ? 1 : 0`，`:2084` 的 MouseRegion 只由鼠标驱动
⇒ 触屏 / 遥控(TV) / 键盘 ⇒ _hover 恒 false ⇒ 按钮**永远不可见**，
  而它背后挂着「删除整部」。

对比度本身合格（深色 18.86:1 / 浅色 5.89:1）—— 用户说的「看不清」= **根本没显示**。

修法更正（我的裁决也错了）：
  ✗ 我原本让用 `MediaQuery.hoverable`
  ✓ 实际：该 API 在 Flutter 3.47 **不存在**（全 SDK grep 0 命中）
    真信号是 `MouseTracker.mouseIsConnected`（mouse_tracker.dart:285）

粘滞位（`_HoverCapability`）：单调、只升不降、订阅 ChangeNotifier
  case④：从未见鼠标 ⇒ 1.0/false；见鼠标后 seenMouse=true；
         鼠标移除后仍 true（只升不降）；重挂 ⇒ 0.0/true
  注入 A 去掉粘滞 ⇒ +3 -1；注入 B 粘滞可回退 ⇒ +3 -1（各自红得不一样）

★ 一个测试装置陷阱（必须记）：
  `PointerAddedEvent.kind` **默认是 touch**，而 `MouseTracker.updateWithEvent`
  第一行就把非 mouse/stylus 丢掉（mouse_tracker.dart:302-304）
  ⇒ 不显式传 `kind: PointerDeviceKind.mouse`，判据永远**假阴性**
```

### 一条可迁移的判据

```text
「因为结构上 A，所以视觉上 B」——B 必须量。

本轮两次违反它：
  ① 结构上"圆角画两遍" ⇒ 推"边缘叠加更亮"  ⇒ 实测 Δpeak = 0.000
  ② 结构上"半透明叠动态底" ⇒ 推"边缘闪烁"  ⇒ 实测 edgeStd 比不透明对照还小

★ 而且两次都是**机制描述完全正确**的情况下推错结论 ——
  这比"机制错"更难防，因为你已经核过源码，会有一种"我验证过了"的错觉。
```

### 还没覆盖的（诚实列出）

```text
· R1 **没修成**：在探针条件下复现不出「毛边」。
  两个假设（clipBehavior / 动态底方差）都被读数否掉。
  下一步需要：Owner 的截图坐标，或从真 `_TopBar` 树上定位三枚徽章出三方对照表。
· 主探针的读数来自**单独挂载**的 chip，不是真 PlayerPage 全页
  （`ActionChip count=0`，`_danmakuInfoVisible` 前置没满足）
· 站名徽章目前只是**复刻参数**，不是从真树上取的那一枚
· 没有真机 DPR 验证（flutter_test 是软件渲染，GPU 抗锯齿行为可能不同）
```

### 何时该翻案

```text
① 拿到 Owner 的截图坐标 ⇒ 能确定是哪一枚，直接量它的 Δpeak 与 innerStd
② 若真机上 `Clip.none` 的 Δpeak 明显 > 0（软件渲染与 GPU 不同）
   ⇒ 那时才该重开 clipBehavior 的裁决，但**必须用真机读数**，不许用推理
③ 若 UI-1 门禁允许自绘药丸（目前禁止）
   ⇒ 可以重新考虑"整排统一自绘"，但前提是 chip 真的有视觉缺陷
```
