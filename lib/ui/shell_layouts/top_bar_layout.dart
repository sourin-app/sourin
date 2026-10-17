// ═══════════════════════════════════════════════════════════════════════
//  骨架 3 · 顶栏式 + 命令面板（Owner 第 14 条）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ┌─────────────────────────────┐
// │ 源影    [搜索框]        ⚙  │  ← 顶栏，设置是齿轮
// ├─────────────────────────────┤
// │         内容区              │
// └─────────────────────────────┘
// ```
//
// # 与另两套的结构性差异
// ```text
//   底栏式：导航在底部**横向 6 格**，每格都可见
//   侧栏式：导航在左侧**纵向 6 行**，每行都可见
//   顶栏式：**导航不常驻** —— 只在命令面板里出现，平时只有 3 个元素
// ⇒ 这是三套里差异最大的一套：日常界面里**看不到** 6 个 tab。
// ```
//
// # ⚠️ 必须有**不依赖快捷键**的切页路径
// ```text
// Lead 的提醒：触屏用户没有 Ctrl+K。
// ⇒ 搜索框**点击就弹面板**，面板里列全部 tab。
//   键盘用户还能用 Ctrl+K 直接弹（同一入口，两条触发路径）。
// ```

import 'package:material_ui/material_ui.dart';

import '../../shell.dart' show AppTab;
import '../tokens.dart';
import 'shell_layout.dart';
import '../../design/widgets/app_ink_well.dart';

class TopBarShellLayout extends ShellLayout {
  const TopBarShellLayout();

  @override
  String get id => 'topBar';

  @override
  String get label => '顶栏式';

  @override
  Widget build({
    required BuildContext context,
    required AppTab current,
    required ValueChanged<AppTab> onSelect,
    required Widget body,
    required List<AppTab> tabs,
  }) {
    final colors = Theme.of(context).colorScheme;

    return Column(
      children: [
        _TopBar(
          current: current,
          onSelect: onSelect,
          tabs: tabs,
          colors: colors,
        ),
        // ★ body 原样放进去
        Expanded(child: body),
      ],
    );
  }
}

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.current,
    required this.onSelect,
    required this.tabs,
    required this.colors,
  });

  final AppTab current;
  final ValueChanged<AppTab> onSelect;
  final List<AppTab> tabs;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.28),
      child: SafeArea(
        bottom: false,
        child: SizedBox(
          height: 56,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: Sp.x4),
            child: Row(
              children: [
                // ① logo
                Text(
                  '源影',
                  style: TextStyle(
                    fontSize: FontSizes.lg,
                    color: colors.onSurface,
                    fontWeight: FontWeights.semibold,
                  ),
                ),
                const SizedBox(width: Sp.x6),
                // ② 搜索框（点击即弹命令面板 —— 触屏路径）
                Expanded(
                  child: _CommandEntry(
                    current: current,
                    onSelect: onSelect,
                    tabs: tabs,
                    colors: colors,
                  ),
                ),
                const SizedBox(width: Sp.x4),
                // ③ 设置齿轮
                _GearButton(
                  active: current == AppTab.settings,
                  colors: colors,
                  onTap: () => onSelect(AppTab.settings),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 搜索框样子的按钮 —— 点它弹命令面板
///
/// ⚠️ 它**不是**真的输入框：本骨架下「搜索」是一个 tab（有自己的页面），
///    这里只是**切页入口**。写成输入框会让用户以为能直接打字搜片。
class _CommandEntry extends StatelessWidget {
  const _CommandEntry({
    required this.current,
    required this.onSelect,
    required this.tabs,
    required this.colors,
  });

  final AppTab current;
  final ValueChanged<AppTab> onSelect;
  final List<AppTab> tabs;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    // ★ 去 Material（纯 A 类：完全透明，只为水波提供绘制面）
    //   ⚠️ ValueKey 必须保留 —— 测试按它定位命令面板入口。
    return AppInkWell(
      key: const ValueKey('topbar-command-entry'),
      borderRadius: Radii.rFull,
      onTap: () => _openPalette(context),
      child: Container(
        height: 34,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
        decoration: BoxDecoration(
          color: colors.onSurface.withValues(alpha: 0.06),
          borderRadius: Radii.rFull,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Row(
          children: [
            Icon(Icons.search, size: 17, color: colors.onSurfaceVariant),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                '搜索或跳转…',
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
            Text(
              'Ctrl+K',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _openPalette(BuildContext context) async {
    final picked = await showDialog<AppTab>(
      context: context,
      barrierColor: Colors.black54,
      builder: (ctx) => _CommandPalette(
        current: current,
        tabs: tabs,
      ),
    );
    if (picked != null) onSelect(picked);
  }
}

/// 命令面板 —— 列出全部 tab（这就是「不依赖快捷键的切页路径」）
class _CommandPalette extends StatelessWidget {
  const _CommandPalette({required this.current, required this.tabs});

  final AppTab current;
  final List<AppTab> tabs;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Align(
      alignment: Alignment.topCenter,
      child: Padding(
        padding: const EdgeInsets.only(top: 96),
        child: Material(
          color: colors.surfaceContainerHighest,
          borderRadius: Radii.rLg,
          child: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.all(Sp.x4),
                  child: Text(
                    '跳转到…',
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
                for (final t in tabs)
                  ListTile(
                    key: ValueKey<String>('palette-${t.name}'),
                    dense: true,
                    selected: t == current,
                    leading: Icon(_paletteIcon(t), size: 19),
                    title: Text(t.label),
                    onTap: () => Navigator.of(context).pop(t),
                  ),
                const SizedBox(height: Sp.x2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _GearButton extends StatelessWidget {
  const _GearButton({
    required this.active,
    required this.colors,
    required this.onTap,
  });

  final bool active;
  final ColorScheme colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    /*
     * ★ 去 Material：`Material(transparency)` + `InkWell` ⇒ `AppInkWell`
     *
     * # 为什么这里能换（与 :215 那处命令面板不同）
     * ```text
     * 齿轮的子树里**没有** ListTile / ChoiceChip 之类需要 Material 祖先的控件，
     * 它只要一个点击态 ⇒ AppInkWell 自绘高亮，**不再需要祖先 Material**
     * （见 lib/design/widgets/app_ink_well.dart 头部的有意差异说明）。
     * ```
     *
     * ⚠️ `ValueKey('topbar-settings-gear')` 必须保留在原位 ——
     *    测试按它定位这个按钮；丢了测试会 "找不到"。
     */
    return AppInkWell(
      key: const ValueKey('topbar-settings-gear'),
      borderRadius: Radii.rFull,
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(Sp.x2),
        child: Icon(
          active ? Icons.settings : Icons.settings_outlined,
          size: 21,
          color: active ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

IconData _paletteIcon(AppTab t) {
  switch (t) {
    case AppTab.home:
      return Icons.explore_outlined;
    case AppTab.live:
      return Icons.live_tv_outlined;
    case AppTab.follow:
      return Icons.star_border;
    case AppTab.search:
      return Icons.search;
    case AppTab.cached:
      return Icons.download_outlined;
    case AppTab.settings:
      return Icons.settings_outlined;
  }
}
