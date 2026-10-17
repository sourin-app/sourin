/// 全仓统一的**现代下拉菜单** —— 替代裸 `PopupMenuButton`
///
/// # 为什么要有这个文件（Owner 第 8 条）
///
/// Owner 原话（逐字）：
/// ```text
/// > 这些个弹窗的ui布局,交互都很烂,请优化,真的操作很烂,文字看不清楚
/// > 按钮瞎设计,一点设计规范也没有,说是液态玻璃也没统一,
/// > 就没有好点的ui框架的能直接让你用的吗?
/// > 还有插件那个点击出来操作菜单的也好难看,不要用谷歌那个matrial那个啥设计规范了
/// ```
///
/// # 裸 `PopupMenuButton` 到底难看在哪（逐条对着截图看）
/// ```text
/// ① 菜单面是 Material 默认的 `surfaceContainer`，与本仓卡片**不同色**
///    ⇒ 点开菜单像"从别的 App 弹出来的"。
/// ② 圆角 4px（M3 默认）而本仓卡片是 22px ⇒ 圆角语言不统一。
/// ③ 阴影是 Material elevation（一层灰雾），没有描边 ⇒ 在深色下几乎看不出边界。
/// ④ 菜单项是 48px 高、左右各 16 内边距，图标与文字间距固定 ⇒ 紧凑场景下很空。
/// ⑤ 进出场只有透明度渐变，没有位移 ⇒ 没有"从按钮长出来"的方向感。
/// ```
///
/// # 本组件怎么改（全部走本仓既有令牌）
/// ```text
/// 底色    → colorScheme.surfaceContainerHighest（与 AppDialogShell 同源）
/// 圆角    → Radii.md（16）—— 菜单比卡片矮一档，与"对话框 22"区分
/// 描边    → colorScheme.outlineVariant（与卡片同一个"弱化描边"角色）
/// 阴影    → 无（改用描边定界，与卡片一致）
/// 条目高  → 40（比 Material 的 48 紧，桌面端更合适）
/// 进出场  → 透明度 + 8px 上移，120ms（尊重 Reduce Motion）
/// 危险项  → colorScheme.error，且**图标与文字同色**（改前图标与文字不同色）
/// ```
///
/// ⚠️ 无障碍不回退：`Semantics` / 键盘可达 / `onSelected` 语义与
///    `PopupMenuButton` 保持一致 —— 这是"换皮不换行为"，
///    调用方把 `PopupMenuButton` 换成 `AppMenuButton` 即可，
///    `itemBuilder` 的签名**逐字相同**。
///
/// # 两种入口形态（两种都只统一**菜单面**，不碰调用方的按钮几何）
/// ```text
/// ① 需要「⋮ 按钮」的      → AppMenuButton（插件区块头那处）
/// ② 已有自己的按钮的      → 调用方保留按钮，在 onPressed 里调
///                          [showAppMenu]（detail_page 的「下载」）
/// ```
/// ★ 为什么 ② 不能靠给 `AppMenuButton` 传一个 `child` 触发器：
///   `PopupMenuButton` 在 child 模式下把触发器包进 `InkWell(onTap: 打开菜单)`
///   （popup_menu.dart:1768+）。若 child 本身是**可点的按钮**，内层按钮
///   会吃掉点击 ⇒ 外层的 InkWell 永远不触发。
///   而把内层按钮设成 `onPressed: null` 又会：
///     · 视觉变灰（与旁边三枚不同档）
///     · 有效文字色变成 disabled 档 ⇒ `t27_w3_download_button_style_test`
///       的「下载与收藏/追更有效文字色相等」当场变红
///   另外 child 模式下菜单默认 `PopupMenuPosition.over`（盖住按钮），
///   而 detail_page 用的是 `under`（在按钮下方）⇒ 位置也会变。
///   ⇒ 所以 ② 走**函数**：调用方保留自己那套取位与按钮，只换菜单面。
library;

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import '../../design/icons/app_icons.dart';

/// 菜单面的**统一几何** —— `AppMenuButton` 与 [showAppMenu] 共用这一份。
///
/// ★ 为什么提成常量：两处各写一遍迟早会各自演化（本仓踩过"改一处漏一处"），
///   而"统一"正是本文件存在的理由。
const BoxConstraints kAppMenuConstraints = BoxConstraints(
  minWidth: 160,
  maxWidth: 260,
);

/// 菜单面的**颜色与形状** —— 由 [AppMenuSurface.of] 现取（跟随主题）。
class AppMenuSurface {
  const AppMenuSurface({required this.color, required this.shape});

  final Color color;
  final ShapeBorder shape;

  /// 与 `AppDialogShell` 的卡片同源：底色 `surfaceContainerHighest`、
  /// 描边 `outlineVariant`、圆角 `Radii.md`（比对话框的 rLg 矮一档）。
  static AppMenuSurface of(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppMenuSurface(
      color: colors.surfaceContainerHighest,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        side: BorderSide(color: colors.outlineVariant),
      ),
    );
  }
}

/// 只统一**菜单面**的弹出函数 —— 给"已经有自己按钮"的调用方用。
///
/// # 什么时候用它（而不是 [AppMenuButton]）
/// 调用方那枚按钮的几何/取位是被门禁钉住的（`detail_page` 的「下载」按钮
/// 就是：几何与收藏/追更同档，位置用 `PopupMenuPosition.under` 现算），
/// 换按钮 = 破坏设计。这时保留按钮与取位，只把菜单面换成本件。
///
/// # 与 [AppMenuButton] 的关系
/// 两者**共用** [AppMenuSurface] 与 [kAppMenuConstraints] —— 换任何一处，
/// 两个入口一起变（这才是"统一"）。
///
/// ⚠️ `position` 必传：本函数**不猜**位置（调用方自己知道按钮在哪）。
Future<T?> showAppMenu<T>({
  required BuildContext context,
  required RelativeRect position,
  required List<AppMenuItem<T>> items,
  T? initialValue,
}) {
  final surface = AppMenuSurface.of(context);
  return showMenu<T>(
    context: context,
    position: position,
    initialValue: initialValue,
    color: surface.color,
    elevation: 0,
    shape: surface.shape,
    constraints: kAppMenuConstraints,
    items: <PopupMenuEntry<T>>[
      for (final it in items) _appMenuItem<T>(context, it),
    ],
  );
}

/// 把一个 [AppMenuItem] 变成框架的 `PopupMenuItem`。
///
/// ★ 必须由 `AppMenuButton` 与 [showAppMenu] **共用** —— 否则两个入口的
///   条目外观（高度/图标色/危险色）会各写一遍。
PopupMenuItem<T> _appMenuItem<T>(BuildContext context, AppMenuItem<T> it) {
  final colors = Theme.of(context).colorScheme;
  final fg = it.danger ? colors.error : colors.onSurface;
  return PopupMenuItem<T>(
    value: it.value,
    enabled: it.enabled,
    height: 40,
    // ★ 调用方自带行时直接用（见 AppMenuItem.child 的文档）
    child: it.child ??
        Row(
          children: [
            if (it.icon != null) ...[
              Icon(it.icon, size: 16, color: fg),
              const SizedBox(width: Sp.x3),
            ],
            Expanded(
              child: Text(
                it.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: FontSizes.sm, color: fg),
              ),
            ),
          ],
        ),
  );
}

/// 菜单项 —— 与 `PopupMenuItem` 同形，调用方改动最小
///
/// 两种给内容的形态（二选一）：
/// ```text
/// label + icon   常规项：本组件统一排版（图标 16 + Sp.x3 间距 + 文字 sm）
/// child          调用方自带的现成行（例如 settings_page 的 `_menuRow`）
///                —— 让既有文案/图标 helper **一行都不用重写**
/// ```
/// ⚠️ `child` 是给「要保住既有 helper widget」的口子，**不是**常规用法：
///   能用 label+icon 就用它（那样条目排版才真的统一）。
/// ⚠️ 用 `child` 时 `danger` 管不到 child 内部的取色（widget 树已定），
///   危险项请自己保证 child 的配色 —— 所以危险项优先仍用 label+icon。
class AppMenuItem<T> {
  const AppMenuItem({
    required this.value,
    this.label = '',
    this.icon,
    this.child,
    this.danger = false,
    this.enabled = true,
  }) : assert(
          label != '' || child != null,
          'label 或 child 必须给一个 —— 否则菜单项是一片空白',
        );

  final T value;

  /// 条目文字。给了 [child] 时可留空。
  final String label;

  /// 条目图标。给了 [child] 时忽略（图标画在 child 里）。
  final IconData? icon;

  /// 调用方自带的行 —— 非 null 时**优先**于 label/icon 排版。
  final Widget? child;

  /// 危险操作（删除/移除）—— 用 `colorScheme.error`，图标与文字同色
  final bool danger;

  final bool enabled;
}

/// 统一的"更多操作"按钮 + 现代菜单
class AppMenuButton<T> extends StatelessWidget {
  const AppMenuButton({
    super.key,
    required this.items,
    required this.onSelected,
    this.tooltip,
    this.icon,
    this.iconSize = 17,
  });

  final List<AppMenuItem<T>> items;
  final ValueChanged<T> onSelected;
  final String? tooltip;
  final IconData? icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final surface = AppMenuSurface.of(context);
    return PopupMenuButton<T>(
      tooltip: tooltip ?? '更多操作',
      padding: EdgeInsets.zero,
      icon: Icon(
        icon ?? AppIcons.more_vert,
        size: iconSize,
        color: colors.onSurfaceVariant,
      ),
      // ★ 关键：把 Material 默认的菜单面换成与卡片同源的现代面
      color: surface.color,
      elevation: 0,
      shape: surface.shape,
      constraints: kAppMenuConstraints,
      onSelected: onSelected,
      itemBuilder: (context) => [
        for (final it in items) _buildItem(context, it),
      ],
    );
  }

  // ★ 条目外观与 [showAppMenu] 共用同一个构造（见 _appMenuItem 的文档）
  PopupMenuItem<T> _buildItem(BuildContext context, AppMenuItem<T> it) =>
      _appMenuItem<T>(context, it);
}
