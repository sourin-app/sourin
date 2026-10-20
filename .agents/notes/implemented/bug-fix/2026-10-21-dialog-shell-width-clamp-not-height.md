# Agent Note: 弹窗外壳的宽度要按视口夹取，高度**不要**

Status: implemented

- 日期：2026-10-21
- 适用：`lib/ui/widgets/app_dialog_shell.dart`

部分重叠：[弹窗外壳收拢（R4）与缓存徽标的全局订阅（R8）](../feature/2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md)
那篇讲的是「**把三个绕过外壳的弹窗收拢进来**」，建立了外壳的契约；
本篇讲的是「**外壳自己少了一条规则**」——收拢之后才发现，
`width` 是紧约束且 `margin` 默认 zero，窄视口下谁进来都会贴满屏幕。
两篇是先后关系，都保留。

同时与 [弹窗外壳的真机像素验收要「自带量具 + 入库存档」](../testing/2026-10-20-r4-dialog-device-pixel-acceptance.md)
成对：那篇讲「量具会骗人」，本篇讲「量具量出了一个真缺陷」。

## Problem

`AppDialogShell` 把 `child` 包进 `SizedBox(width: width)`，而 `margin` 默认
`EdgeInsets.zero`，**没有任何视口夹取**：

```bash
$ grep -c "math.min\|clamp" lib/ui/widgets/app_dialog_shell.dart
0
```

后果（真渲染取证，不是推断）：视口 800×600 下打开 `source_composer_dialog`
（`width: 820`）：

```text
卡片 rect = [0,0 .. 800,600]    四边距 L=0 T=0 R=0 B=0
四角像素 = (54,52,58)           = 卡片底色，**不是**遮罩色 (71,71,71)
```

⇒ 三个可见后果：

```text
① 遮罩完全看不见 —— 用户失去「这是个浮层」的感知
② 圆角被切掉 —— 圆角画在四角，而四角已出屏
③ 标题栏顶到 y=0 —— 与无边框窗口的标题区视觉粘连
```

**同一视口下另外两个弹窗是好的**，这说明不是"小窗口就长这样"：

```text
skip_marker  卡片 [16,16 .. 784,584]   边距 16   ← 它自己夹取
update       卡片 [170,122 .. 630,478] 居中      ← 宽度 460 < 视口
```

覆盖面对比（7 个走外壳的弹窗里 5 个有隐患）：

```text
composer 820 / plugin_edit 560 / bili 560 / danmaku 560 / provider 560
⇒ 都可能在窄视口贴边；只有 skip 因为历史原因自带夹取
```

## Decision

**在外壳加宽度夹取（一处修好全部）：**

```dart
final viewport = MediaQuery.sizeOf(context);
const double horizontalMargin = Sp.x4;                       // 16
final maxCardW = math.max(viewport.width - horizontalMargin * 2,
                          _kMinDialogWidth);                  // 下限 260
final effectiveW = math.min(width, maxCardW);
// SizedBox(width: effectiveW, ...)
```

**高度明确不加夹取。** 这是本笔记最要紧的一条，理由见 Alternatives ②。

配套门禁 `test/zz_t66_r4_dialog_pixel_test.dart`：

```text
D-1  渲染级：3 个可渲染弹窗 × 3 档视口（1280x800 / 1024x640 / 800x600）
     ⇒ 左右边距必须 > 0
D-2  规则级：width ∈ {460, 560, 820} × 5 档视口 = 15 格
     ⇒ 卡片宽必须 == min(width, 视口宽 - 32)，且边距 > 0
```

★ D-2 为什么在**规则层**验而不是把 5 个弹窗都渲染出来：
`bili_import` / `provider_import` / `source_switch` / `danmaku` / `plugin_edit`
的构造函数**全部要求真实状态**（state / 回调 / seed / 播放位置）。无头渲染
要编一整套假数据 —— 那样测的是"我编的假数据"，不是"外壳规则"，正是
「同一个源比同一个源」。夹取是**外壳的一条规则**，8 个弹窗都只是传 `width`
进来，没有一个绕过它 ⇒ 在规则层验 15 格比在渲染层验 3 格 + 编 5 套假数据更强。
三档 `460/560/820` 恰好覆盖全部 8 个（那 5 个没传 width ⇒ 默认 560）。

## Alternatives considered

**① 只修 `composer`（最小风险）—— 否决。**
另外 5 个弹窗仍留着同一个坑。而「5 个有隐患、只有 1 个被修」比「6 个都没修」
**更难发现** —— 下一个人看到 composer 是好的，会以为外壳是对的。
且 §3.5 写了高度的夹取条款却没有宽度的对应条款 ⇒ 这是文档缺口，
而 skip 自己实现过夹取（git 证明比外壳早），说明正确做法早已存在、只是没上收。

**② 高度也加夹取 —— 试过，t70 变红，已回退。★ 这条必须留着防复发。**
我按"对称"的直觉加了 `maxHeight: min(maxHeight ?? 620, 视口高 - 32)`，
800×600 下 620 被夹到 568，然后：

```text
t70「立即更新」从绿变红
  Expected: <1>   Actual: <0>
  hit-test 警告：derived an Offset (347.7, 598.0) would not hit test
  ⇒ 按钮落到 y=598，视口高 600 ⇒ 点击打空
```

根因是**约束语义不对称**：

```text
宽度  SizedBox(width:)      = **紧**约束。父级只把它压到视口宽，
                              **不**自动留边距 ⇒ 必须由外壳夹取留白。
高度  ConstrainedBox(maxHeight:) = **上界**。父级约束（Scaffold.body /
                              showDialog 路由）本来就会把卡片压进视口。
        实测 800x600、内容恰好 620：不加夹取 ⇒ 卡片 **600** 高，
        不溢出、内部可滚 ✓；加夹取 ⇒ **558**（被压两次）⇒ 内容挤出 ✗
```

⇒ 高度是**双重夹取**，方向错了。这条不对称的原因已写进代码注释，
防止下一个人"顺手补上"。

**③ 删掉 `skip_marker_dialog` 的自算 —— 否决。**
它的 `boxW` 不只用于宽度，还喂给 `previewHeightFor(boxH)` 算预览高度预算
（`kDialogMaxH = 740` → 预览 236px）。删掉它、只靠外壳，预览预算就没来源了。
而宽度在这里是**双重用途**（布局 + 预算输入），不能因为"外壳也夹了"就删。
★ 幂等性已实测：两边用同一个公式 `min(上限, 视口-32)`，叠一次等于没叠
（skip@800x600 改前改后都是 `768 / 边距 16`）。

**④ 判据 D 用「上下左右都要有边距」—— 否决（改完才发现要收窄）。**
一开始四条边一起判，于是逼出了 ② 的高度夹取，把 t70 弄红。
上下贴边是**父级约束的必然结果**，不是缺陷 ⇒ D-1 只判左右。

## Consequences

**收益**

```text
· 7 个弹窗在窄视口下都有左右边距（不写各自的分支，只在外壳一处）
· 大视口零影响：9 格实测 8 格 SAME，唯一变化的是 composer@800x600
  （800→768，正是缺陷本身）
· 判据 D-1（渲染）+ D-2（规则 15 格）守住，且 D-2 覆盖全部 8 个弹窗
```

**代价（如实记）**

```text
· 宽高夹取**不对称** —— 有意为之，原因写在代码里。这是本笔记最容易被误读的点。
· 新增 _kMinDialogWidth = 260 常量。它没有对应的 token：
  tokens.dart 里只有间距/圆角/字号，没有"尺寸下限"这一类。
· D-2 验的是规则不是每个弹窗的实际渲染 —— 若将来某个弹窗**绕过** width 参数
  自己定宽（例如改用 constraints），D-2 就管不到它。这条已知未覆盖。
· 玻璃档（glass: true）只测了规则层，没测"玻璃 + 窄视口"的像素表现。
```

**何时该翻案**

```text
· 若 Flutter 改变 SizedBox / Padding 的约束语义（届时"紧 vs 上界"的区分失效）
· 若有人真要加高度夹取 ⇒ 必须先证明 ConstrainedBox 不再被父级压
  （即：在 Stack 直挂 + Scaffold.body 两种宿主下都实测卡片不会被压）
· 若 8 个弹窗之外新增的弹窗开始自己定宽而不传 width ⇒ D-2 需要补渲染级覆盖
```
