# Agent Note: 模糊"看不见"不等于"白付"（逐像素对照才能定去留）

Status: implemented

## Problem

第 13 项量到玻璃档 `raster p50/p95 = 7155/7876us`，是全部弹窗里最贵的一档。
据此有人提出一个看起来很有道理的推理：

> 卡片内层是 100%（`app_glass_dialog` 的 `surfaceContainerHigh`）与 98%（`app_dialog_shell` 的 `#14161B@0.98`）
> 不透明的实色层，把玻璃的模糊输出整个盖住了 ⇒ **模糊对最终像素的贡献 ≤2%，代价却照付** ⇒ 摘掉它。

如果只有这个推理，摘掉模糊是"省 7ms 且看不出差别"的免费午餐。**但推理本身没有被验证过。**

## Decision

**先测再动**：对同一弹窗做逐像素对照（挂玻璃 vs 不挂玻璃），按**卡片几何**取中心带：

```text
AppGlassDialog  Δpeak(整帧)=58  interiorΔpeak(卡片中心带)=0  meanAbs=0.182  affected=0.71%
AppDialogShell  Δpeak(整帧)=13  interiorΔpeak=1             meanAbs=0.061  affected=0.07%
```

结论三点：
1. **模糊在卡片内部确实零贡献**（0 / 1）—— 推理的前半段是对的；
2. **但整层摘掉会丢掉边缘那圈描边/高光**（58 级、0.71% 像素）—— 这是"看不见"之外的真实可见差异；
3. `GlassContainer` 没有"只留描边、去掉模糊"的开关 ⇒ **整层摘掉就是改画面** ⇒ **维持现状，保留模糊**。

唯一新增的省法是 **reduced-motion 分支**：`MediaQuery.disableAnimations` 为真时不挂玻璃，
视觉代价=丢那圈描边。这是**有意的取舍**（这类用户已声明要少效果），不是性能优化，
所以注释里必须这么写，并留下"一行改回恒挂玻璃"的退路。

门禁 `zz_t1044_glass_blur_parity_test.dart` 把这三件事钉住：
①黑白对照自检（Δpeak > 200，防"仪器看不见差异"的假绿）；
②③ `Δpeak ∈ [8,80]` + `affected < 2%` + `interiorPeak ≤ 1`（**谁把玻璃摘了 Δpeak 掉到 0 ⇒ 立刻红**；
   而 `interiorPeak ≤ 1` 单独钉住"模糊本身不可见"这个事实）；
④reduced-motion 双对照（`reduced vs 摘玻璃 = 0`、`reduced vs 挂玻璃 = 60` —— 只有前者接近 0 才可能是"样本瞎"）。

## Alternatives considered

1. **按透明度推理直接摘模糊**（省 7ms）。
   实测会改 0.71% 像素的峰值 58 级 —— 那圈描边是玻璃的视觉标识。**否决**。
2. **把 `GlassContainer` 改成"只画描边、不画模糊"**。
   需要改共享组件的 API（其它 15 处弹窗都吃它），风险远大于 7ms 收益；而且要重新设计"无模糊时的描边/圆角反走样"。
   **否决**（这是将来若真需要再做的方向，入口写在这里）。
3. **给 reduced-motion 也保留玻璃**（一行动回）。
   可行且零风险，但放弃了一个"用户已声明要少效果"的现成机会。**保留分支**，并把退路写进注释。
4. **重采 7155/7876us 作为"优化后"的证据**。
   默认路径没改，重采只会得到同一读数 —— 那会把"没改"包装成"改好了"。**否决**：
   reduced-motion 那档的节省**如实记为未测**。

## Consequences

- 收益：一个"看起来免费"的性能优化被数据否掉，用户看到的画面没变；同时把"模糊对内部零贡献"这个事实
  变成了一条可复跑的门禁（`interiorPeak ≤ 1`），而不是一句注释。
- 收益：测量过程本身纠正了一个口径错误 —— 第一版把"内部"定义成"整图往里缩 24px"，
  而卡片只有 380 宽居中，缩完仍包住边缘 ⇒ `interiorΔpeak` 虚高成 58。**"内部"必须按卡片几何取**。
- 代价：玻璃档仍是较贵的一档（正常用户口径 7155/7876us），且这次没有降低它。
- 残留：reduced-motion 分支的帧耗时收益**未测**（只对少数用户，不值一次 release 探针）。

## Relations

- 同族（互链）：[2026-10-25-identity-must-carry-discriminator.md](2026-10-25-identity-must-carry-discriminator.md)
  —— 那篇讲"判据的输出不许超出输入"；本篇是"**优化方案的前提必须被测过**"（透明度推理 ≠ 像素事实）。
- 同族（互链）：[../../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md](../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md)
  —— 那篇讲"阈值不许编码缺陷态"，本篇讲"成本结论不许只靠推理"，都是**先量再下判断**。

## Testing

- `zz_t1044_glass_blur_parity_test.dart` **+4**；玻璃/遮罩/圆角 6 门禁 **92 passed / 2 skipped**。
- 注入 A（玻璃恒被摘）⇒ ② 与 ④ 各红一次；注入 B（去掉 reduced-motion 分支）⇒ ④ 红；恢复后 `diff -q` 一致。
- `flutter analyze` 0 error；三个文件 LF。
- 相关纪律（同批总结）：**帧读数必须空闲窗口**（并发负载把 4233us 抬到 7876us，1.7×）、
  **远端可用性必须直连复测**（系统代理把 200 变 502）、**探针构建会覆盖产物**（跑完必须重建并复核体积与字节串）。
