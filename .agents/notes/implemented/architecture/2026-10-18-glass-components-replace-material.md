# Agent Note: 玻璃化不是换控件 —— 自建组件层取代 Material，并用门禁守住「不再长回来」

Status: implemented

> 同域：[2026-10-18-glassify-where-it-is-visible.md](./2026-10-18-glassify-where-it-is-visible.md)
> 那篇讲**哪里该玻璃、哪里不该**（判据）；本篇讲**用什么组件去实现**。
> 先后关系：先按那篇判「该不该玻璃」，再按本篇换组件。

## Problem

本轮 Owner 的硬要求是「彻底不用 Material 组件，全部自建/玻璃」，且
「非 material 风格的，还是要跟现在的液态玻璃风格契合才行」。

难点不在「把 `ElevatedButton` 换成自定义控件」这件事本身，而在三件事：

```text
① 换掉之后**外观必须仍然契合液态玻璃**，不能变成一堆朴素方块
② 换掉之后**交互语义不能退化**（悬停/聚焦/禁用/键盘可达）
③ 换完之后**不许长回来** —— 否则今天换掉、下周又有人贴一个 Material 按钮
```

第 ③ 条是本仓反复出现的病：**没有门禁的约定等于没有约定**。

## Decision

### 一、不做「逐个替换」，而是先建自建组件层

按详情页 / 追更页 / 设置页的用点盘点，Material 组件集中在四类按钮与弹窗。
于是先建四个自建件，再统一替换用点：

| 自建件 | 取代 | 提交 |
|---|---|---|
| `AppTextButton` | `TextButton` × 10（详情页） | `0cc9cbc` |
| `AppIconButton` | `IconButton` × 2 + 若干 | `5f797cf` |
| `AppOutlinedButton` | `OutlinedButton` × 4 | `b0e23a0` |
| `AppGlassDialog` | `AlertDialog` × 3 | `574968a` |

同期把追更页（`b0f45d1`）与设置页（`4048146`）的同源用点一并迁完。

### 二、每个自建件都带自己的门禁文件

```text
zz_t66_glass_detail_test.dart            详情页 TextButton 迁移
zz_t66_glass_detail_icon_test.dart       IconButton
zz_t66_glass_detail_outlined_test.dart   OutlinedButton
zz_t66_glass_follow_test.dart            追更页
zz_t66_settings_dematerial_test.dart     设置页
zz_t66b_panel_glass_test.dart            弹幕面板
```

★ 门禁不是「检查有没有 import」，而是**读渲染结果与语义属性**
（悬停态、禁用态、圆角 token、玻璃层的存在），理由见下一篇同域笔记的判据。

### 三、弹窗外壳加可选 glass 档，而不是另起一套

`fe53564` 给 `AppDialogShell` 加了 `glass` 可选档，弹幕设置面板用它。
理由：本仓已有 7 个弹窗走同一外壳，另起一套等于回到「各写各的」。

## Alternatives considered

- **直接用 forui 的组件替 Material** —— 它最强的论据是现成、外观本来就是玻璃风，
  一步到位。
  否决理由：本仓已明确「不再新增 forui 用法」，且 forui 的视觉与现有液态玻璃
  不是同一套语言；再引入一个依赖还会把「样式在哪定义」变成三个来源。

- **保留 Material 控件，只覆盖 `ThemeData` 把它画成玻璃** —— 它最强的论据是
  改动量最小，用点一行都不用动。
  否决理由：Material 控件的**布局与交互尺寸**是写死在组件里的（最小点击区、
  ink 波纹、`ElevatedButton` 的 elevation 阴影语义），主题只能改颜色与形状，
  改不掉那些结构性行为。结果会是「看起来像玻璃，动起来还是 Material」。

- **逐个替换，不建统一组件层** —— 它最强的论据是不引入新抽象，改哪算哪。
  否决理由：本轮盘点出同一类按钮在 3 个页面共 16 处用点。逐个替换必然出现
  「同一类按钮三种圆角」，而那正是本仓第 65 轮已经在收拢的债。

- **只替换、不写门禁** —— 它最强的论据是省时间，且人工 review 能看出来。
  否决理由：本仓实证过多次「没有门禁的约定会静默失效」。见
  [2026-10-12-gates-must-be-able-to-fail.md](../../../implemented/testing/2026-10-12-gates-must-be-able-to-fail.md)。

## Consequences

- **收益**：Material 组件在详情页/追更页/设置页的用点清零，且外观统一到同一套
  玻璃语言；每类按钮有独立门禁，回退会被立刻发现。
- **代价**：新增 4 个自建组件 ≈ 700 行（含注释与边界处理），
  以及 6 个门禁文件。这些代码本身需要维护 —— 未来改玻璃语言要改 4 处而不是 1 处。
  ⇒ 已用「统一取色走 `Theme.of(context).colorScheme` + token」把改动面收敛。
- **未完成（诚实列出）**：首页仍有 3 个 Material 控件未迁（计划里标为「视觉收益小，
  挪到最后」）；彻底移除 `MaterialApp` 仍待 `ScrollBehavior` 替代品与 `Navigator` 重建；
  `theme_bridge` 胶水层仍在。
- **重访条件**：当 `MaterialApp` 也被移除后，`material_ui` 这个依赖只剩
  `MaterialLocalizations` 一个用途 —— 届时要么换成自建本地化，
  要么接受「为了一个 delegate 保留整个依赖」。
