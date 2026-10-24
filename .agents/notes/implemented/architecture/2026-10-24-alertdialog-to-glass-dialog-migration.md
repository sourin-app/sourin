# Agent Note: 13 处裸 AlertDialog 收拢到统一弹窗外壳

Status: implemented

本篇与既有弹窗笔记的关系：接在 [弹窗外壳统一与 hover 粘滞位](../feature/2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md) 之后，是其「统一外壳已建立、残留待收拢」的**续作**；宽度夹取的实现细节见 [外壳宽度夹取不是高度](../bug-fix/2026-10-21-dialog-shell-width-clamp-not-height.md)；实机像素验收方法沿用 [R4 弹窗设备像素验收](../testing/2026-10-20-r4-dialog-device-pixel-acceptance.md)。三篇均为**部分重叠**：本篇只新增"13 处残留调用点如何逐处等价迁移"，未推翻其中任何决定，故三篇全部保留、不归档。

## Problem

仓库已有统一弹窗外壳：`lib/ui/widgets/app_dialog_shell.dart` 的 `AppDialogShell`（文件头写明「全仓统一弹窗外壳 —— 所有 AppDialog 必须走这里」），以及基于它封装的 `AppGlassDialog`（`lib/design/widgets/app_glass_dialog.dart`）。规范见 `docs/AGENTS.md` §3.5：宽度默认 560（窄 460／宽 820 须显式传并注释原因）、最大高度**绝对值 620** 再按视口夹取、圆角 `Radii.rLg`、标题栏 title+subtitle+右侧关闭、内容区滚动、底部 actions 可选。

但仍有 13 处生产代码直接使用 Material 原生 `AlertDialog(`：`settings_page.dart` 4、`backup_panel.dart` 3、`sync_panel.dart` 2、`theme_page.dart` 2、`download_panel.dart` 1、`tvbox_source_panel.dart` 1。样式与动效因此与其余弹窗不一致——这正是 Owner 报的「全局弹窗样式统一遗漏」。

`test/zz_t66_r4_dialog_consistency_test.dart` 早已用「逐处豁免登记」的方式记录了这 13 处**为什么当时不能换**，每条都写明具体机制，不是笼统的"待办"。

## Decision

13 处全部改为 `AppGlassDialog`，并**在调用点**逐条补齐当初登记的能力缺口，**不改共享组件**（组件不在本项写入范围）：

- 机制②「外壳内容区零 Material 宿主」⇒ `content` 就地包一层 `Material(type: MaterialType.transparency)`。只作光标/选择手柄/墨水宿主，不画底色、不裁剪，外壳视觉不变。涉及含 `TextField` / `ListTile` / `Switch` / `SwitchListTile` / `InkWell` 的内容。
- 机制⑤「外壳内容区 `DefaultTextStyle` 写死 `textAlign: center`」⇒ 显式传 `TextAlign.left`（`Text.textAlign` 显式传入时**优先于** `DefaultTextStyle.textAlign`）。
- 机制③「内联 `TextStyle` 定色被外壳 DefaultTextStyle 覆盖」⇒ 显式样式在 merge 中胜出，警示色（`Colors.red`）保持生效。
- 机制①「内容固定宽超外壳默认」⇒ 按 §3.5 白名单档显式传 `maxWidth` 并注释原因（如 `tvbox` 的 560、`theme_page` 的 560）。

逐处保持**返回值语义与按钮文案/顺序完全不变**：`pop(null)` 与 `pop(false)` 的区别、`ok != true` 判据、`r ?? false`、`void` 出口的「先关窗再切主题」顺序，一律照旧。

`test/zz_t66_r4_dialog_consistency_test.dart` 的 `_siteExemptions` 从 14 条精简为 **2 条真豁免**（`t104_overlay_exit_probe.dart` 的真机探针、`provider_login_panel.dart` 的自建外壳）。删除的 12 条逐条对应已迁移站点：登记的是"这一处不能换"，既然换了就不该再登记，属**正当减法**而非掩盖。

`test/zz_dialog18_unified_shell_test.dart` 新增三节：① 仪器自检（实测外壳内容区的 Material 依赖名单）、② 逐处行为（真挂载 → 真 `showAppDialog` 路由 → 真点按钮 → 断言返回值与副作用）、③ 结构断言（那 6 个文件不再有裸 `AlertDialog(`，配阳性对照）。

## Alternatives considered

- **保持裸 `AlertDialog` 不动**：零风险、零工作量，但 Owner 报的样式不统一就永远存在；13 处已逐条登记机制说明"能换"，只是没人做。放弃。
- **先给 `AppGlassDialog` 补 `Material` 宿主、`padding`、`backgroundColor`、`textAlign` 四个可选参数，再统一迁移**：这是最"干净"的架构解，一次补齐后所有调用点都不用重复包 `Material`。但共享组件不在本项写入范围，且改组件会同时影响已在使用它的 13 个文件，回归面远大于本项——需要独立一轮与独立验收。放弃（作为后续项保留）。
- **一次性全仓重写所有弹窗**：范围不可控，会与其它在途改动互相踩，且无法逐处取得"改前/改后"对照证据。放弃。
- **把 `_siteExemptions` 整份删掉**：看似"迁移完了就不需要豁免"，但 `t104` 探针与 `provider_login_panel` 两处按设计确实不走统一外壳，删光会让门禁失去这两处的保护，且违反门禁自身的「白名单必须非空」规则（空条款 = 假绿）。放弃，改为只删已迁移站点的 12 条。

## Consequences

13 处弹窗的宽度、圆角、标题栏、内边距、动效与其余弹窗一致；每处的返回值语义与副作用逐条保持，并有行为测试驱动真实路由与真实按钮。

代价与边界：

- 机制②/③/⑤ 的补法**在每个调用点重复**（透明 `Material` 包了 6 处以上）。这是"不改共享组件"这一范围约束的直接代价；后续若补组件参数，可逐处删掉这层包装。
- `theme_page` 的两处**有意观感变化**：卡片底色从每套主题自己的 `p.palette.card` 改为外壳统一卡片色，内容内边距从 0 改为外壳的 24/22/24/16。这是第 18 项的目标而非副作用，但**单测抓不到"变丑"**，必须进批末实机截图验收。
- `tvbox` 的 `title` 从「`Row` + `Flexible` + ellipsis 单行截断」变为「超长名字换行」（`AppGlassDialog.title` 只收 `String` 且不设 `maxLines`）。不溢出、不抛异常，仅观感差异。
- `zz_dialog18_unified_shell_test.dart` 有 2 条用例在**入口不可达时明确 `markTestSkipped` 并说明原因**（备份导出需真实凭证与文件写入；主题预览需已装主题包），不是把断言弱化成"存在即通过"。这两处的等价性由 ① 组仪器自检与 ⑬ download 的同形态断言间接覆盖；如实标注为覆盖边界。
- 门禁有效性已验证：`zz_t66_r4_dialog_consistency_test.dart` 抽掉一条真豁免 → `+11 -2` 退出码 1，恢复后 `+13` 全绿；`zz_dialog18_unified_shell_test.dart` 把 `textAlign: TextAlign.left` 改成 `right` → `+11 ~2 -1` 退出码 1，恢复后 `+12 ~2` 全绿。

## Verification

- `flutter test test/zz_t66_r4_dialog_consistency_test.dart --run-skipped --concurrency=1` → `+13: All tests passed!`，退出码 0（`.probe/r4gate-lead-after.log`）。
- 同一门禁故障注入：抽掉 `provider_login_panel` 豁免 → `+11 -2`，退出码 1（`.probe/r4gate-inject.log`）；恢复后复跑 `+13`。
- `flutter test test/zz_dialog18_unified_shell_test.dart --run-skipped --concurrency=1` → `+12 ~2: All tests passed!`，退出码 0（`.probe/dialog18-final-lead.log`）。
- 同一测试故障注入：`download_panel` 的 `textAlign: TextAlign.left` 改 `right` → `+11 ~2 -1`，退出码 1（`.probe/dialog18-inject.log`）；恢复后复跑 `+12 ~2`。
- 仪器自检已实测外壳内容区的 Material 依赖名单：裸 `TextField` / `ListTile` / `Switch` / `SwitchListTile` / `InkWell` 抛，Material 按钮不抛，包透明 `Material` 后不抛。**该自检刻意走真实 `showAppDialog` 路由**——在 `MaterialApp(home: Scaffold(...))` 里直接摆一个会被 Scaffold 白送 Material 祖先，得出"TextField 能用"的假结论（R4 当年改判就是这个仪器问题）。
- 上述均为专项测试证据，**不替代实机验收**。`theme_page` 的两处观感变化、`tvbox` 的标题换行、13 处弹窗的实际观感必须进批末实机截图逐项确认。
