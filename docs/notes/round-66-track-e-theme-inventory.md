# 9 个「尚无对应角色」的消费方清单

> **本清单由轨道 E 在 2026-10-18（第 66 轮）产出**，用于 M2/M3 阶段删
> `theme_bridge.dart` 时定位消费方；**零消费的 4 个角色可直接消失**。
>
> 用途：等真要删 `theme_bridge.dart` 时，一眼看出删它会点亮哪些地方。
> 统计口径：只统计 **`lib/` 下的真实读取**（`.roleName` 形式）。
> `theme_bridge.dart` 自身的**赋值行**（`roleName: ...`）不计入消费方 —— 那是定义处，删它本来就是目的。
>
> ⚠️ 本清单只记录，**本轮一个角色都没补**（Lead 拍板：补角色 = 定派生公式 +
> 浅深分岔 + 门禁 + 容差验证，是完整一轮工作）。下一轮做时按本清单直接动手，
> 不用重查。

---

## ★ 下一轮优先：`surfaceContainerHighest` 与 `surfaceSunken` 的语义合并

```text
这是**语义层的清理**，比补字段重要 —— 已与 Lead 对齐，标为下一轮优先。
```

`surfaceContainerHighest` 在本仓有 **22 个消费方**，但它的用法**不是** Material
原意里的「最高阶容器」，而是：

```text
.withValues(alpha: 0.35)   8 处   ← 最常见的真实用法
.withValues(alpha: 0.5)    3 处
.withValues(alpha: 0.3)    2 处
直接当 backgroundColor      3 处
```

即「取它再压 alpha，当**凹槽 / 次级条的浅底**」。

而 `AppThemeData.surfaceSunken`（`lib/design/theme/app_theme_data.dart:97`）
**已经在表达同一个意图**：
```dart
// 深色：alphaBlend(0x14FFFFFF, background)   在暗底上压一层白
// 浅色：alphaBlend(0x0A000000, card)         在白卡上压一层黑
```

⇒ **两者应该合并成一个角色**，否则同一个视觉意图会留下两个色名，
将来必然漂移（这正是 task-31 / task-42 反复出现的"两处真源"病根）。

合并时的判据建议：
```text
① 合并后必须有 ≥22 个调用点能直接换过去（否则说明拆得不对）
② 压 alpha 的动作应由角色自带宽（返回已含 alpha 的色），
   而不是让 22 处各自写 .withValues(alpha: 0.35) —— 现在这 13 处
   的 alpha 值有 0.3 / 0.35 / 0.5 / 0.6 / 0.8 / 0.22 六种，是散的
③ 门禁：合并后的角色对 surface 的对比度必须 > 1.05（task-31 的下限）

---

## 一句话结论

```text
9 个角色里，真正被人用的只有 6 个；另外 3 个（surfaceContainerLowest /
surfaceContainerLow / secondaryContainer）在本仓**零读取**，纯属把 Material
的 ColorScheme 全字段补满才写的 —— 删 theme_bridge 时它们可以**直接消失**，
不需要在新色层里补。
```

| 角色 | 消费文件数 | 归档 |
|---|---|---|
| `surfaceContainerHighest` | **22** | ★ 重度使用，必须补 |
| `errorContainer` | 4 | 必须补 |
| `primaryContainer` | 4 | 必须补 |
| `onPrimaryContainer` | 2 | 必须补 |
| `onErrorContainer` | 1 | 必须补 |
| `surfaceContainerLow` | **0** | ✅ 可随 theme_bridge 一起消失 |
| `surfaceContainerLowest` | **0** | ✅ 同上 |
| `secondaryContainer` | **0** | ✅ 同上 |
| `onSecondaryContainer` | **0** | ✅ 同上 |

---

## ① `surfaceContainerHighest` —— 22 个文件（最多）

最常用的形态是「取它再压 alpha 当浅底色」，不是直接当背景：

```text
.withValues(alpha: 0.35)   8 处    ← 最常见的用法（分组条/次级条背景）
.withValues(alpha: 0.5)    3 处
.withValues(alpha: 0.3)    2 处
直接当 backgroundColor     3 处
```

前 5 个消费方（按使用次数）：

```text
lib/ui/widgets/backup_panel.dart        6 处  (多处)
lib/ui/live_page.dart                   4 处  3386 / 4813 / 4854 / 5084
lib/ui/settings_page.dart               3 处  4858 / 5734 / 6319
lib/ui/widgets/provider_import_dialog.dart  3 处
lib/ui/widgets/player_settings_sheet.dart   3 处
```
其余 17 个文件各 1~3 处：`source_composer_dialog` · `app_dialog_shell` ·
`data_manage_page` · `cast_device_sheet` · `probe_cast` · `search_page` ·
`settings_kit` · `app_menu` · `detail_page` · `detail_raw_meta` · `epg_panel` ·
`my_shelf` · `playback_page` · `cache_page` · `skip_page` · `tvbox_source_panel`
（+ `delivery_test.dart` 2 处，是**断言**不是消费）。

⚠️ 特殊：`search_page.dart:859` 是**注释**里提到它（解释为什么用 0.35），
但同一文件 619 / 1093 是真读取。

★ 语义提示：它被大量用作「**凹槽/次级条**」的底（配合 alpha），
所以它在新色层里的名字其实更接近 `surfaceSunken` 而不是「最高阶容器」——
`AppThemeData.surfaceSunken`（app_theme_data.dart:97）已经在做同一件事。
**这两者将来应该合并**，否则会出现「同一个视觉意图有两个色名」。

---

## ② `errorContainer` —— 4 个文件

```text
lib/ui/home_page.dart:2886                color: colors.errorContainer.withValues(alpha: 0.35)
lib/ui/settings_page.dart:5915            color: colors.errorContainer.withValues(alpha: 0.35)
lib/ui/settings/theme_page.dart:1043      color: cs.errorContainer              ← 主题页的色卡预览
lib/ui/widgets/subtitle_panel.dart:474    color: colors.errorContainer.withValues(alpha: 0.35)
```
★ 三处都是 **@35% 当淡红底**，只有 theme_page 是拿它当色块展示。
⇒ 新色层若补，语义应是「错误色的淡底」，不是「实心红」。

深色现网值 `#3A1416`，浅色 `#FCE8E6`（`LightTokens.errorContainer`）。

---

## ③ `primaryContainer` —— 4 个文件

```text
lib/ui/settings_page.dart:2646                    color: colors.primaryContainer.withValues(alpha: 0.35)
lib/ui/widgets/subtitle_panel.dart:620            color: colors.primaryContainer.withValues(alpha: 0.35)
lib/ui/widgets/provider_import_dialog.dart:724    color: colors.primaryContainer              ← 选中态整块底
lib/ui/widgets/reorderable_card_grid.dart:967     color: colors.primaryContainer              ← 拖拽中的卡底色
```
★ 两种强度混用：两处 **@35% 淡底**、两处**实心**（选中态/拖拽态）。
补角色时要确认「实心那两处」用的是不是同一个语义 —— 若是，可能需要
一个 `primaryContainer`（实心）+ 一个派生的淡底，而不是让调用方自己压 alpha。

---

## ④ `onPrimaryContainer` —— 2 个文件

```text
lib/ui/widgets/provider_import_dialog.dart:740    color: active ? colors.onPrimaryContainer : colors.onSurface
lib/ui/widgets/reorderable_card_grid.dart:994     color: colors.onPrimaryContainer
```
★ 这两处与 ③ 的实心用法**成对**（选中卡片 = `primaryContainer` 底 +
`onPrimaryContainer` 字）。所以 ③ 与 ④ 必须**一起补**，只补一半会出现
「底补了、字没补」⇒ 字色回落。

---

## ⑤ `onErrorContainer` —— 1 个文件

```text
lib/ui/settings/theme_page.dart:1049   Icon(..., color: cs.onErrorContainer)
lib/ui/settings/theme_page.dart:1056   color: cs.onErrorContainer
```
★ **只有主题页的色卡预览在用**（不是在真实内容区）。
⇒ 优先级最低。若不想为一处预览补一个角色，可以让主题页直接算
`contrast(foreground, errorContainer)`。

---

## ⑥ 零消费的 4 个（可随 theme_bridge 一起消失）

```text
surfaceContainerLowest    0 处读取
surfaceContainerLow       0 处读取
secondaryContainer        0 处读取
onSecondaryContainer      0 处读取
```

核实过程：
```text
grep -r "\.surfaceContainerLowest"  lib/  → 0
grep -r "\.surfaceContainerLow\b"   lib/  → 0
grep -r "\.secondaryContainer"      lib/  → 0
grep -r "\.onSecondaryContainer"    lib/  → 0
```

⚠️ 唯一「看起来命中」的是 `lib/ui/widgets/settings_kit.dart:449`，
但那是**注释**：
```text
⚠️ 不取 ChipTheme 默认色：默认来自 secondaryContainer，与这里的
   primary/secondary 是两套色，直接吃默认会整体变色。
```
它恰恰是在**解释为什么不使用 secondaryContainer** —— 不是消费。

---

## 给删 theme_bridge 时的操作建议

```text
① 必须补进新色层的（5 个，按优先级）：
     surfaceContainerHighest   ← 22 个文件，且用途其实是"凹槽底"
     primaryContainer + onPrimaryContainer  ← 必须成对，2~4 个文件
     errorContainer            ← 3 处 @35% 淡底 + 1 处色卡
     onErrorContainer          ← 只有主题页预览，可最后补或让页面自算

② 不需要补的（4 个）：Lowest / Low / secondaryContainer / onSecondaryContainer
     —— 本仓零读取，随 theme_bridge 一起消失即可

③ 一个**去重**机会：
     surfaceContainerHighest 被当"凹槽底"用，而 AppThemeData.surfaceSunken
     （app_theme_data.dart:97）已经在表达同一个意图 ⇒ 补角色时应该合并成一个，
     否则同一视觉意图会有两个色名，将来又会漂移。
```

---

## 附：本清单的核实命令（可复现）

```bash
# 逐个角色的真实读取（排除定义处 theme_bridge.dart）
grep -rn "\.surfaceContainerHighest" lib/ --include=*.dart | grep -v theme_bridge
grep -rn "\.errorContainer"          lib/ --include=*.dart | grep -v theme_bridge
grep -rn "\.primaryContainer"        lib/ --include=*.dart | grep -v theme_bridge
grep -rn "\.onPrimaryContainer"      lib/ --include=*.dart | grep -v theme_bridge
grep -rn "\.onErrorContainer"        lib/ --include=*.dart | grep -v theme_bridge
grep -rn "\.surfaceContainerLowest"  lib/ --include=*.dart | grep -v theme_bridge   # 0
grep -rn "\.surfaceContainerLow\b"   lib/ --include=*.dart | grep -v theme_bridge   # 0
grep -rn "\.secondaryContainer"      lib/ --include=*.dart | grep -v theme_bridge   # 0
grep -rn "\.onSecondaryContainer"    lib/ --include=*.dart | grep -v theme_bridge   # 0
```
