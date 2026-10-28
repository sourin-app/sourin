# Agent Note: 玻璃着色器的"首次成本"与"判据不能跨形态搬"

Status: implemented

## Problem

Owner 原话：「全局弹窗 / modal 卡顿与动效 还是很卡，弹幕设置弹窗，还有其他弹窗，menu也很丑，完全不适配现在的液态玻璃的设计风格」。

两件事要同时办：**menu 玻璃化**（观感）+ **弹幕设置弹窗按四类交互分类采样**（性能，旧13 只采过"关闭"11 档与"打开"2 例）。

做这件事时踩出**三个方法论坑**，其中两个会直接影响判据的正确性 —— 这也是本篇要留的东西：

```text
① 玻璃着色器**异步加载** ⇒ 进程内**第一棵**玻璃树画的是"染色直通"，
   之后才是真玻璃。不等就绪就取字节 ⇒ 量到**偶然值**（本门禁第一版实测 33 vs 135）。
② `zz_t1044` 的两条像素判据（interior 零贡献 + affected < 2%）**不能直接搬**到菜单条目上 ——
   那两个外壳**内层有不透明实色垫层**（`#14161B@0.98`），菜单条目**没有**
   ⇒ 模糊照进整块条目。照抄会让判据**恒红**（那是判据搬错，不是产品坏）。
③ **注入脚本本身也会产出假绿**：`n7-run-inject.sh` 第一版用 `python3` 做文本替换，
   而本机 `python3` 是 Windows Store 的**占位存根**（静默退出、什么都不做）
   ⇒ 三条注入一个都没应用，却三次都报"All tests passed"。
```

## Decision

### 一、menu 玻璃化：面 = 框架 Material + 玻璃 tokens，材质只落条目

`app_menu.dart` 里：

```text
面  : 仍是框架 `showMenu` 内部那条 Material（`popup_menu.dart:784` **拿不到**）
      ⇒ **不许**为做"整块面玻璃"在外面再套一层 GlassContainer（= 引重复模糊层）
行  : 玻璃材质只落在**条目**上（`appMenuGlassItem` 包 child，不包框架 chrome）
动效: 框架默认 300ms/linear → `OverlayMotion.cardDuration` / `cardCurve`
      两个入口（`showAppMenu` / `AppMenuButton`）共用一份 `appMenuAnimationStyle`
      reduced-motion ⇒ `AnimationStyle.noAnimation`（与 `MotionPrefs` 同源）
```

门禁 `test/zz_t1059_n7_menu_glass_test.dart` **+6**，实测读数：

```text
玻璃 vs 不挂玻璃   Δpeak=102  interiorΔpeak=26  edgeΔpeak=48
                  meanAbs=3.370  affected=13.35%  **affectedInItem=97.9%**
reduced-motion vs 摘玻璃   Δpeak=0    （逐像素一致）
reduced-motion vs 挂玻璃   Δpeak=102  （阳性对照）
glass vs glass（同状态连拍两张）  Δpeak=0  ⇒ 引擎确定，不抖
```

判据按**本件形态**重写（未照抄 t1044 的 interior≤1 / affected<2%）：要求 `affectedInItem > 0.8`
（材质覆盖整块条目）且 `interiorPeak > 8`（条目内部也在变）。**判据对象不同就该有不同判据**，
文件里逐字写明了两处形态为何不同。

### 二、弹幕设置弹窗：真窗口四类交互读数（`lib/n7_danmaku_dialog_probe.dart`）

照 t107 的仪器纪律（引擎 timings **常驻不摘** + 窗口按下标切片 + postFrame 第二路 + drain +
阳性/阴性对照），并按**时间戳**归属帧。**两路时钟必须先算 offset**（见下）。

改前（`.probe/n7-dialog-before.log`，raster p50/p95/max，单位 us）：

```text
打开     6510 / 23210 / 34366   ← **2 帧超预算**
滚动     6138 /  7642 /  8134
页签切换  4375 /  5084 /  5084
关闭     4857 /  6243 /  7539
```

**`打开 r1` 那根尖峰（max 34366us、2 帧超预算）= 进程内第一次渲染玻璃面的一次性成本。**
两路对照都指向它，且都**可复现**：

```text
N7_GLASS=off （摘掉外壳玻璃）      打开 r1 max 34366 → 5891、超预算 2 → **0**
N7_WARMUP=1  （先真开一次弹窗）    尖峰**移到预热那一次**（max 30473、2 超）
                                  之后 打开 r1 max=8410、超预算 **0**
```

⚠️ 这一段我一开始**误判过两次**，都记在下面「Errors」里 —— 尖峰的归属是"玻璃 vs 第一次开弹窗"
两种解释都一致的，所以补了判决性对照 `N7_WARMUP_NG=1`（用**摘掉玻璃**的弹窗预热，付掉建树成本，
再在**挂玻璃**下量）：尖峰**仍在**（max 18290、1 帧超）⇒ 成本确实归**玻璃面**，不是建树。

### 三、包装了官方预热 API，但**没解决问题**（如实记录）

`liquid_glass_widgets` 自带 `LiquidGlassWidgets.initialize()` / `LightweightLiquidGlass.preWarm()`，
本仓 `lib/` **一次都没调**。实测（`N7_PRECACHE=1`）：

```text
  LightweightLiquidGlass.preWarm() ✓ 0ms
  LiquidGlassWidgets.initialize()  ✓ 0ms
  ⇒ 打开 r1 仍 max=32980us、2 帧超预算   ← **尖峰没被吃掉**
```

两个调用都是 **0ms 且无效**：包内 `GlassContainer` 走的是 `AdaptiveGlass`，
这些 preWarm 预热的是**另外几张着色器**。**故不作为修法上报**（不能拿"调了个官方 API"
当"修好了"）。真正的修法方向见 Consequences。

### 四、**否决**一条没复现的优化（裁剪）

按 plan 的指引"若在 raster，不动模糊、查阴影/裁剪叠加"，实验了 `_group` 的
`Material(clipBehavior: Clip.antiAlias)` → `Clip.none`（build 里 6 处调用）：

```text
第一次实验（.probe/n7-dialog-noGroupClip.log）四类同向下降：
  打开 -10.6%  滚动 -13.8%  页签切换 -9.2%  关闭 -13.0%  总体 -11.7%
⇒ 看起来超出噪声，我**一度按它落了产品改动**。

但补采同配置第二份样本后（.probe/n7-dialog-after-opt{,2}.log）：
  去裁剪臂两次跑  4524 vs 5256（**同一配置，差 16%**）
  vs 改前臂噪声地板  -10.2% ~ +5.0%
⇒ **增益没有复现**（臂间均值只差 ~4.5%，小于臂内散度）⇒ **回滚，不上报为优化**。
```

**回滚后 md5 = `a0fea39fb623ac64ca3b38df2c8d95b7`（与改前逐字节一致）。**
判据：`bash .probe/n7-apply-opt.sh` 可复现该实验；本文档把"没复现"如实记为结论。

## Alternatives considered

1. **把菜单面也做成玻璃**（外面再套一层 `GlassContainer`）。**否决**：框架 `showMenu` 内部那条
   Material 拿不到，外层再套 = **重复模糊层**，旧13 台账31 与 `zz_t1044` 都明令禁止。
2. **照抄 t1044 的两条像素判据**。**否决**：判据对象形态不同（条目无内层不透明垫层），
   照抄 ⇒ 恒红。已按实测重写并在文件里写明差异。
3. **给菜单条目加 `clipBehavior`/阴影**去凑"玻璃感"。**否决**：那会改变条目几何/涟漪宿主，
   `t137` 的四条关系断言（面 = `surfaceContainerHighest`/elevation 0/`Radii.md`/`outlineVariant`）会破。
4. **启动期预热玻璃着色器**（`LiquidGlassWidgets.initialize()`）。**实测无效**（0ms、尖峰仍在）
   ⇒ 不作为本次修法；方向留在下面。
5. **删模糊/把玻璃档降级**。**否决**：旧13 台账31 逐像素已证模糊在卡片内部贡献为 0、
   可见差异全在描边带；删它 = 改画面（本文档第一段的 ③ 就是重演这个推理的诱惑）。

## Consequences

- 收益：menu 的玻璃化**没有引入第二层模糊**，且四类交互**有真窗口读数**可复核（不再只有"关闭"11 档）。
- 收益：把"**进程内第一棵玻璃树是染色直通**"这条钉成 `t1059` 的**第四条仪器纪律**
  （前三条来自 t1044：`runAsync` 包住、两图同尺寸、底图高低频混合）——
  没这条，玻璃判据会量到 33 或 135 的**偶然值**。
- 收益：把"**注入脚本要先证明注入落到文件上**"钉成硬闸（md5 断言），
  这条比 N7 本身更通用（任何注入脚本都可能像 `python3` 那样哑掉）。
- 代价：**弹幕设置弹窗的 raster 成本本次没有降低**。`打开 r1` 的一次性尖峰（34366us、2 帧超预算）
  给了成因（玻璃面首次渲染），但**没给修法**：包的官方预热 API 实测无效，
  可行的方向是把"首帧的玻璃渲染"挪到用户看不见的时刻（例如弹窗出现前先离屏渲染一帧，
  或首次打开时先用 reduced-motion 那档再切回）—— 这需要产品侧的时序设计，**留给后续**。
- 残留：`_group` 裁剪那条改动**已回滚**，是否真有效**未定论**（本次噪声地板 ~±10%，
  要判定它需要更多样本或更稳的测量条件）。这是本篇最值得记住的一条：
  **一次"同向下降"不等于增益**；同配置连跑两次就能把散度暴露出来。

## Relations

- 同族（互链）：[2026-10-26-blur-invisible-is-not-free.md](../bug-fix/2026-10-26-blur-invisible-is-not-free.md)
  —— 那篇讲"透明度推理 ≠ 像素事实"（先量再动）；本篇是它的**下一步**：
  "**一次量到的下降 ≠ 增益**"（先量噪声地板，再下结论），且两篇都落到"玻璃面首次成本"这个对象上。
- 同族（互链）：[../../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md](../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md)
  —— 那篇讲"阈值不许编码缺陷态"；本篇的 ③ 讲"**注入脚本要先证明自己没哑**"，同属"仪器的自证"。
- 同族（互链）：[../../testing/2026-10-20-r4-dialog-device-pixel-acceptance.md](../testing/2026-10-20-r4-dialog-device-pixel-acceptance.md)
  —— 那篇是弹窗逐像素验收，本篇复用了它的 `Δpeak/interiorΔpeak` 口径并说明**为何不能照抄到菜单条目**。

## Testing

- `test/zz_t1059_n7_menu_glass_test.dart` **+6**（仪器自检 / 条目玻璃 / reduced-motion / 动效档）。
- 故障注入三条**真红**（`.probe/n7-inject-{A,B,C}.log`）：
  A 摘玻璃 `+4 -2`（②③ 红）；B 退回框架动效 `+5 -1`（④ 红）；C 不尊重减少动效 `+5 -1`（③ 红）；
  恢复后 `+6` 全绿、回滚 md5 一致。
- 既有门禁复核（`--concurrency=1`）：`t137` +5、`zz_t1044` +4、`zz_t66_r4_dialog_consistency` +13、
  `zz_dialog18_unified_shell` +13 ~1 —— **全绿**，外壳改动没破坏 13 处迁移。
- `flutter analyze`：`app_menu.dart` / `danmaku_settings_dialog.dart` / `n7_danmaku_dialog_probe.dart`
  均 No issues。
- 探针实机读数：`.probe/n7-dialog-{before,glassoff,warmup,warmNG,precache,noGroupClip,after-opt,after-opt2}.log`；
  汇总脚本 `.probe/n7-tabulate.py`（含噪声地板计算）。