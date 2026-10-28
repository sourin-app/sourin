# Agent Note: 两条"判据被实现甩下"的红 —— 一条跟形态、一条是算术错

Status: implemented

## Problem

批末全量跑 Dart 门禁（369 个 `zz_*.dart`），最后剩两条红，都不是产品缺陷：

```text
① zz_t66_r1_danmaku_chip_edge（2 条）
   断言：`t.widget<mui.ActionChip>(find.byType(mui.ActionChip))` 存在且 clipBehavior == Clip.none
   实测：**Bad state: No element** —— 树里根本没有 ActionChip
   原因：R2-#6 Owner 选 (c)「自绘药丸 + 不透明等效色」之后，这枚 chip 改成
         `AppInkWell + Container` 自绘（`player_page.dart::_DanmakuInfoChip`），
         `clipBehavior` 退化成"保留签名、不再消费"的史料参数（代码里已注明）。
   ⇒ 判据测的对象**已经不存在**：红的意思是"我找不到那个东西"，
     不是"值不对"。它连"生产有没有画出来"都没验到（No element 直接抛）。

② zz_t66_settings_dematerial ①
   断言：`settings_page.dart` 里 `AppTextButton(` 必须**正好 10 处**
   实测：**11 处**（HEAD 与工作树都是 11，本批没动过这个文件）
   原因：**判据自己的算术错** —— 它那句理由写的是
        「8 个替换来的 + 1 个原有 + 2 个聚合入口」= 11，断言却写 10。
   ⇒ 这条从写下的那天起就不可能绿；只是那时恰好还没跑到它。
```

## Decision

两条都**保留精确计数/精确形态的口径**，只把"测什么"和"测多少"与现状对齐：

```text
① chip 门禁改成测当前形态下的**同一条不变量**：
   · 子树里**没有 ActionChip**（旧 Material 双层机制已消失 ⇒ 那圈"互补边缘"不可能再出现）；
   · 生产 chip **确实画出来了**（防空真：不许靠"什么都不渲染"通关）；
   · 蒸汽值 `kDanmakuChipClipBehavior == Clip.none` 仍断言（别偷偷改史料常量骗过 grep）。
   「反证」那条主体已消失 ⇒ 改成**事实判据**：两臂（none / antiAlias）读数必须**相同**
   （<0.001），再加一条真正的用户可见预算：生产 Δpeak ≤ 0.5。
   若哪天有人把裁剪重新接回渲染 ⇒ 两臂出现差异 ⇒ 这条会红，那时再按新机制重写反证。

② dematerial 的分母 10 → 11，并把 11 的构成写进注释（8+1+2），供下一个人复核。
   保持"精确计数"不变：改成 `>=10` 会让"删掉一处"的注入不再变红（该文件自己记过这个坑）。
```

## Alternatives considered

1. **删掉 chip 门禁的两条**（"对象没了，留着没意义"）。
   最强理由：最省事，反正它已经红了两天。
   **否决** —— 它守的机制（两层透明叠加产生的亮边）是 Owner 亲报过的缺陷；
   现在机制消失是**修好了**的结果，但"修好"要被钉住：没有 ActionChip + 生产真的画出来 + Δpeak ≤ 0.5
   这三条合起来，才能防"哪天有人把 Material chip 加回来"。
2. **把 chip 门禁改成 `find.byType(ActionChip)` 的"存在性无关"断言**（只测像素）。
   最强理由：纯像素判据最贴近用户。
   **否决** —— 像素预算已经有 ④ 那条 DPR 矩阵在守（1.25/1.5/2.0，Δpeak 恒 0.000）；
   再加一条纯像素等于重复，而"机制形态"（有没有 ActionChip）反而没人守了。
3. **dematerial 改成 `greaterThanOrEqualTo(10)`**。
   最强理由：对未来新增更宽容。
   **否决** —— 该文件里已有实测记录：`>=` 会让"删掉一处 AppTextButton"的注入**不变红**，
   等于把这条判据废掉（假绿）。

## Consequences

- 收益：Dart 全量从"2 文件 3 条红"变成**全绿**（只剩 1 个半成品文件加载失败，属仪器故障、什么都不守）。
- 收益：chip 那条从"测一个不存在的对象"变成"测当前形态的三条不变量 + 一条预算"，覆盖面反而更宽。
- 代价：chip 门禁不再证明"antiAlias 会更亮"这个历史结论 —— 那条结论现在只活在
  `kDanmakuChipClipBehavior` 上方的注释里。**若将来要重开 R1 的裁决，得重建仪器**（注释里写了怎么建）。
- 代价：dematerial 的分母以后每次产品新增 AppTextButton 都要跟着改 —— 这是该判据刻意的代价
  （精确计数换"删了没换"的可检测性），注释里已写明构成，便于下一个人核对。

## Relations

- 前情：[../bug-fix/2026-10-27-chip-edge-glow-fixed-by-opaque-equivalent-fill.md](../bug-fix/2026-10-27-chip-edge-glow-fixed-by-opaque-equivalent-fill.md)
  —— 那篇是 R2-#6(c) 的修复本身；本篇是**修复之后判据怎么跟上**。
- 同族：[./2026-10-28-hardcoded-sample-classes-go-stale.md](./2026-10-28-hardcoded-sample-classes-go-stale.md)
  —— 那篇是"样本过期"，本篇是"**被测对象整个消失**"，同一族但更彻底。
