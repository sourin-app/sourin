// ═══════════════════════════════════════════════════════════════════════
//  源个性化覆盖层 · 独立弹窗（第 06 项 · 三段式 L1 / L2 / L3）
// ═══════════════════════════════════════════════════════════════════════
//
// # 2026-10-25（P5 统一）：本文件从"实现"瘦成"外壳"
// ```text
// 改前：L1/L2/L3 的**全部状态机与渲染**都在这个文件里（1244 行），
//       而声明式源的编排器（source_composer_dialog.dart）是另一套完全
//       独立的界面 —— 用户要"对数据二次编排"，得先知道该点哪个入口。
//
// 改后：状态机与渲染搬进 `composer_overrides_tab.dart`（`ComposerOverridesTab`），
//       本文件只保留：
//         ① 玻璃外壳（AppGlassDialog / showAppDialog）
//         ② 两个入口（`OverrideEditorDialog` / `showOverrideEditorDialog`）
//         ③ `export` 出去的纯函数与取值域（**既有门禁从本文件 import 它们**）
//       ⇒ 同一个页签既能独立弹出，也能嵌进编排器：
//         「源定义」与「个性化覆盖」并排，两条路走同一份校验与拼装。
// ```
//
// # 它**不做**什么（这条比上面那条更重要）
// ```text
// ✗ 不解析插件、不跑 JS、不应用规则 —— 全部在 Rust 侧（rust/sourin_core/src/overrides.rs）
// ✗ 不改插件与声明式源文件 —— 三条命令只读写 overrides 目录
// ✗ 不自己造数据模型 —— 字段名/取值域与 overrides.rs 的 serde 结构**逐字对齐**
// ```
//
// # 弹窗外壳（本仓硬规矩）
// ```text
// docs/AGENTS.md §3.5：弹窗必须走统一外壳，不许裸 `AlertDialog(`。
// 本文件走 `AppGlassDialog`（design/widgets/app_glass_dialog.dart）。
//
// ⚠️ 机制②：`AppGlassDialog` 的内容区**零 Material 宿主**
//   （外壳刻意不包 Material —— 那是它「玻璃卡片」的前提）。
//   而本弹窗有 TextField / DropdownButton ⇒ 必须**就地**包一层
//   `Material(type: MaterialType.transparency)`，否则在**真 showAppDialog 路由**里
//   弹窗根本打不开（实测异常："No Material widget found. ... require a Material
//   widget ancestor"，依据见 test/zz_dialog18_unified_shell_test.dart 的仪器自检）。
//   ⇒ 透明 Material 只作光标/选择手柄/墨水的宿主：不画底色、不裁剪，观感不变。
//   ⚠️ 这层宿主**只在弹窗宿主里加**，不进 `ComposerOverridesTab` ——
//      编排器那条路上外壳自带 Material，再包一层会让 `DropdownButton` 的
//      下拉层拿到错误的祖先（而且是无意义的额外 widget）。
// ```
//
// # 安全提示为什么必须写在界面上（不是只写在文档里）
// ```text
// 用户对「个性化」最怕的是「改了会不会把插件弄坏」。
// 事实是**不会**：覆盖层是独立文件，删除即完全恢复。这句话必须出现在
// 用户按下任何按钮**之前** —— 所以它在页签内容区最上面，不是折叠说明。
// ```

import 'package:material_ui/material_ui.dart';

import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import 'composer_overrides_tab.dart';
import 'overlay_motion.dart';

/*
 * ★ 既有门禁（test/zz_t1030_override_editor_test.dart 等）从**本文件**
 *   import `buildOverrideLayer` / `validateOverrideDraft` / `kMapOps` / ...
 *   实现搬去 `composer_overrides_tab.dart` 后，用 `export` 保持同一个 import 路径
 *   仍然拿得到它们 —— 不改任何既有测试的 import 行。
 */
export 'composer_overrides_tab.dart';

// ═══════════════════════════════════════════════════════════════════════
//  弹出入口
// ═══════════════════════════════════════════════════════════════════════

/// 弹出「源个性化覆盖层」编辑器；返回 `true` = 保存过（调用方可据此提示/刷新）
///
/// ⚠️ 必须走 [showAppDialog]（本仓唯一对话框入口）：`showDialog` 的
///    `animationStyle` 只在那里接上 token，裸调会丢掉 task-104 的退场动效。
Future<bool?> showOverrideEditorDialog({
  required BuildContext context,
  required String targetId,
  required String sourceName,
}) {
  return showAppDialog<bool>(
    context: context,
    builder: (_) => OverrideEditorDialog(
      targetId: targetId,
      sourceName: sourceName,
    ),
  );
}

// ═══════════════════════════════════════════════════════════════════════
//  组件
// ═══════════════════════════════════════════════════════════════════════

/// 覆盖层编辑器（三段式）—— 玻璃外壳 + [ComposerOverridesTab]
///
/// 内部自己 `getOverrideLayer(targetId)` 加载；`null` = 尚未个性化（正常状态）。
class OverrideEditorDialog extends StatelessWidget {
  const OverrideEditorDialog({
    super.key,
    required this.targetId,
    required this.sourceName,
    this.loadLayer,
    this.saveLayer,
    this.deleteLayer,
  });

  /// 绑定的源 id（插件 @id 或声明式源 id）—— 写进 `target_id`，也是文件名
  final String targetId;

  /// 源名（只用于界面显示，不参与任何逻辑）
  final String sourceName;

  /// ── 测试注入口（生产路径**永不为 null**）──────────────────────────
  ///
  /// 三个 FFI 边界函数可以替换，为的是在 `flutter test` 里不必起真核心也能
  /// 验证**界面逻辑**（加载回显 / 增删行 / 结构拼装 / 校验拦截 / 删除）。
  ///
  /// ⚠️ 被替换的**只有 FFI 边界**：状态机、校验、JSON 拼装、渲染全部真跑。
  ///    「桩掉被测逻辑」是被禁止的，这里桩的是文件/网络那一层。
  final Future<Map<String, dynamic>?> Function(String id)? loadLayer;
  final Future<String> Function(Map<String, dynamic> layer)? saveLayer;
  final Future<bool> Function(String id)? deleteLayer;

  @override
  Widget build(BuildContext context) => AppGlassDialog(
    title: '个性化覆盖层',
    /*
     * 宽度：§3.5 的默认档 560（不是确认框那档 460）。
     * 理由：本弹窗是**表单**，每行要并排放"源字段 → 目标字段"两个输入框；
     * 460 档的可用宽只有 412，两个输入框各剩 ~190，路径类值
     * （`pager.total`、`^EP\d+$`）会被截断成看不清。
     * 560 档可用宽 512 —— 仍在 §3.5 的白名单 {460, 560, 820} 内。
     */
    maxWidth: 560,
    content: Material(
      // ★ 机制②：内容区零 Material 宿主，TextField / DropdownButton 需要它
      //   （只作光标与墨水的宿主，不画底色、不裁剪 ⇒ 玻璃观感不变）
      type: MaterialType.transparency,
      child: ComposerOverridesTab(
        targetId: targetId,
        sourceName: sourceName,
        loadLayer: loadLayer,
        saveLayer: saveLayer,
        deleteLayer: deleteLayer,
        // ★ 独立弹窗的语义：保存成功即关窗，把"改过了"告诉调用方
        onSaved: () => Navigator.of(context).pop(true),
      ),
    ),
    /*
     * 外壳 actions 只放「关闭」：**保存按钮跟着状态机走**，在
     * `ComposerOverridesTab` 内容区底部（理由见那边的注释）。
     * 若把保存挂在这里，就得把 `_canSave` / `_busy` 从页签 State 里提出来 ——
     * 那等于把同一个状态机拆成两半，两侧必然漂移。
     */
    actions: Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AppTextButton(
          key: const ValueKey<String>('ov-cancel'),
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('关闭'),
        ),
      ],
    ),
  );
}
