# Agent Note: 退场浮层隔离键盘焦点

Status: implemented

- 日期：2026-10-23
- 适用：基线 1281a20；lib/ui/widgets/overlay_motion.dart 的 SheetExitMotion

部分重叠：[弹窗外壳收拢](../feature/2026-10-19-dialog-shell-unification-and-hover-sticky-bit.md)。既有外壳与动效体系保持不变，本篇只规定退场期间的键盘交互边界，不取代既有尺寸与样式决策。

## Problem

SheetExitMotion 为保留淡出绘制，在 visible=false 后�继续挂载子树。IgnorePointer 只隔离指针，已获得焦点的子树仍处理键盘事件。独立 widget 测试先确认打开态焦点与按键正常，再关闭并在首帧发送按键：旧实现事件计数从 1 增至 2，期望保持 1。

用户反馈的全局 modal 卡顿、片头片尾样式遗漏、弹幕裁切和边缘毛边是待核实事项。本缺陷是键盘行为证据，不是这些反馈的共同根因，也不是性能改善证据。

## Decision

在现有 IgnorePointer 外套 ExcludeFocus(excluding: !widget.visible)。打开态仍允许焦点；关闭态立即排除焦点，但保留原退场绘制、时长、曲线和卸载时机。减少动态效果仍在首帧卸载。退场中重新打开恢复焦点资格，不主动抢焦点。

不修改 AppDialogShell 的尺寸、材质、滚动和按钮契约，不改业务保存与取消逻辑。

## Alternatives considered

- 仅保留 IgnorePointer：实测仍接收键盘事件，未覆盖键盘与方向键输入。
- 关闭时立即卸载：破坏既有退场动画契约。
- 逐个业务弹窗手动 unfocus：分散共享边界，且不能阻止退场子树重新获取焦点。
- 重建一套 modal 外壳：已有 AppDialogShell 与 SheetExitMotion，无必要。

## Consequences

关闭中的浮层不再处理自身键盘动作。焦点回落由既有 Focus 树负责；本次没有新增自动恢复焦点策略。若未来业务要求关闭后明确回到某个控件，应由宿主实现并单独验证。

### Verification

- 专属测试：test/zz_t1023_sheet_exit_focus_test.dart，3 项覆盖退场键盘隔离、退场中重开、减少动态效果首帧卸载。
- 工作树旧实现：flutter test test/zz_t1023_sheet_exit_focus_test.dart --concurrency=1，退出 1，2 通过、1 失败；失败值 expected 1 / actual 2。
- 独立 detached worktree 基线 1281a20：同一测试退出 1，2 通过、1 失败，同一计数失败。该工作树只额外加入测试；依赖解析生成的平台注册文件不��属于产品修复。
- 修复后：同一测试退出 0，3/3 通过。
- flutter analyze lib/ui/widgets/overlay_motion.dart test/zz_t1023_sheet_exit_focus_test.dart：退出 0，No issues found。
- 未运行全量测试、未重启客户端、未进行实机或 profile 验收。总计划 13/18 及关联 09/14 不据此标完成。

### 入口盘点边界

以下为源码定位，不是实机验收清单；搜索结果含注释、探针和定义，不能把命中数当产品入口总数。

- 路��由入口：lib/core/app_tray.dart；lib/ui/cache_page.dart；lib/ui/detail_page.dart；lib/ui/player_page.dart；lib/ui/settings_page.dart；lib/ui/settings/data_manage_page.dart、emby_page.dart、skip_page.dart、theme_page.dart；lib/ui/widgets/backup_panel.dart、download_panel.dart、plugin_edit_dialog.dart、provider_import_dialog.dart、provider_login_panel.dart、source_switch_dialog.dart、sync_panel.dart、tvbox_source_panel.dart、update_dialog.dart。以上文件命中 showAppDialog，逐项参��数与渲染仍待核对。
- AppDialogShell 产品组件调用点：lib/ui/live_page.dart；lib/ui/subtitle/subtitle_panel.dart；lib/ui/widgets/bili_import_dialog.dart、danmaku_settings_dialog.dart、plugin_edit_dialog.dart、provider_import_dialog.dart、skip_marker_dialog.dart、source_composer_dialog.dart、source_switch_dialog.dart、update_dialog.dart。共 10 个产品文件；探针调用另计。
- 常挂退场宿主：lib/ui/player_page.dart 的三处 SheetExitMotion，分别承载弹幕设置��、导入与字幕面板；本次未改宿主。
- 片头片尾：lib/ui/player_page.dart:9599 的 showAppDialog → SkipMarkerDialog → lib/ui/widgets/skip_marker_dialog.dart:2260 的 AppDialogShell。已接共享外壳，不应重复迁移。宽 820 / 高 740 是既有预览预算例外；scrollable:false 由内部滚动管理，actions 使用共享底栏。样式差异仍需同主题、同缩放截图核实。
- blur、clip、阴影、重复动画及重建范围：尚无 profile 数据；不据源码�成本猜测宣称卡顿根因或改善。
