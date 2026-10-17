// ═══════════════════════════════════════════════════════════════════════
//  骨架 2 · 侧栏式（Owner 第 14 条）
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ┌──────┬──────────────────────┐
// │ 发现 │                      │
// │ 直播 │      内容区          │
// │ 追更 │                      │
// │ 搜索 │                      │
// │ 缓存 │                      │
// │ 设置 │                      │
// └──────┴──────────────────────┘
// ```
//
// # 与骨架 1 的**结构性差异**（这就是判据 1 要的）
// ```text
//   底栏式：导航在**底部横向**，内容区占满整个高度
//   侧栏式：导航在**左侧纵向**，内容区被推到右边、高度不变但宽度变窄
// ⇒ 同一页面上「发现」的位置：底栏式在底部居中，侧栏式在左上角。
// ```
//
// # 响应式：>= 900px 展开，否则只图标
// ```text
// 桌面宽屏（>=900）⇒ 图标 + 文字，宽 180px
// 窄屏 / 分屏 / 手机 ⇒ 只图标，宽 64px
// ⇒ 这是**骨架自己的**响应式，与配色无关。
// ```

import 'package:material_ui/material_ui.dart';

import '../../shell.dart' show AppTab;
import '../tokens.dart';
import 'shell_layout.dart';
import '../../design/widgets/app_ink_well.dart';

class SideRailShellLayout extends ShellLayout {
  const SideRailShellLayout();

  /// 展开阈值 —— 低于它只显示图标
  ///
  /// 900 的依据：桌面 1280 宽时侧栏占 180（14%），内容区还剩 1100；
  /// 而 900 以下（分屏 / 平板竖屏）若仍占 180，内容区就只剩 720，
  /// 海报网格会掉一列 ⇒ 折成 64px 只留图标。
  static const double expandAt = 900;

  static const double expandedWidth = 180;
  static const double railWidth = 64;

  @override
  String get id => 'sideRail';

  @override
  String get label => '侧栏式';

  @override
  Widget build({
    required BuildContext context,
    required AppTab current,
    required ValueChanged<AppTab> onSelect,
    required Widget body,
    required List<AppTab> tabs,
  }) {
    final colors = Theme.of(context).colorScheme;
    final width = MediaQuery.of(context).size.width;
    final expanded = width >= expandAt;
    final railW = expanded ? expandedWidth : railWidth;

    return Row(
      children: [
        SizedBox(
          width: railW,
          child: _Rail(
            current: current,
            onSelect: onSelect,
            tabs: tabs,
            expanded: expanded,
            colors: colors,
          ),
        ),
        // ★ body 原样放进去 —— 不重建、不包新的 Key
        Expanded(child: body),
      ],
    );
  }
}

class _Rail extends StatelessWidget {
  const _Rail({
    required this.current,
    required this.onSelect,
    required this.tabs,
    required this.expanded,
    required this.colors,
  });

  final AppTab current;
  final ValueChanged<AppTab> onSelect;
  final List<AppTab> tabs;
  final bool expanded;
  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.28),
      child: SafeArea(
        right: false,
        child: Column(
          children: [
            const SizedBox(height: Sp.x4),
            for (final t in tabs)
              _RailItem(
                key: ValueKey<String>('rail-${t.name}'),
                tab: t,
                active: t == current,
                expanded: expanded,
                colors: colors,
                onTap: () => onSelect(t),
              ),
            const Spacer(),
            const SizedBox(height: Sp.x4),
          ],
        ),
      ),
    );
  }
}

class _RailItem extends StatelessWidget {
  const _RailItem({
    super.key,
    required this.tab,
    required this.active,
    required this.expanded,
    required this.colors,
    required this.onTap,
  });

  final AppTab tab;
  final bool active;
  final bool expanded;
  final ColorScheme colors;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = active ? colors.primary : colors.onSurfaceVariant;
    final bg = active
        ? colors.primary.withValues(alpha: 0.14)
        : Colors.transparent;

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Sp.x2,
        vertical: 2,
      ),
      // ★ 去 Material（纯 A 类：完全透明，只为水波提供绘制面）
      child: AppInkWell(
          borderRadius: Radii.rMd,
          onTap: onTap,
          child: Container(
            height: 42,
            padding: EdgeInsets.symmetric(
              horizontal: expanded ? Sp.x3 : 0,
            ),
            decoration: BoxDecoration(
              color: bg,
              borderRadius: Radii.rMd,
            ),
            child: Row(
              mainAxisAlignment: expanded
                  ? MainAxisAlignment.start
                  : MainAxisAlignment.center,
              children: [
                Icon(_iconFor(tab, active), size: 20, color: fg),
                if (expanded) ...[
                  const SizedBox(width: Sp.x3),
                  Text(
                    tab.label,
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: fg,
                    ),
                  ),
                ],
              ],
            ),
          ),
      ),
    );
  }
}

/// 侧栏图标（与底栏同一套语义，但底栏那套是私有的 ⇒ 这里各写一份）
///
/// ⚠️ 两处必须同义：底栏的 `_icons` / `_iconsActive` 在 shell.dart 里。
///    改底栏图标时要一起看这里 —— 否则同一个页面在两套骨架里图标不同。
IconData _iconFor(AppTab t, bool active) {
  switch (t) {
    case AppTab.home:
      return active ? Icons.explore : Icons.explore_outlined;
    case AppTab.live:
      return active ? Icons.live_tv : Icons.live_tv_outlined;
    case AppTab.follow:
      return active ? Icons.star : Icons.star_border;
    case AppTab.search:
      return Icons.search;
    case AppTab.cached:
      return active ? Icons.download_done : Icons.download_outlined;
    case AppTab.settings:
      return active ? Icons.settings : Icons.settings_outlined;
  }
}
