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
// ═══════════════════════════════════════════════════════════════════════
//  ★★★ N7（2026-10-27）：menu 液态玻璃化 —— **面 = 框架 Material + 玻璃 tokens；
//  材质只落在条目上**
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（N7）：「menu 也很丑，完全不适配现在的液态玻璃设计风格」。
//
// # 这一支为什么**没有**把「整块菜单面」做成玻璃（先写清楚，免得下一个人重做）
// ```text
// 菜单面那条 `Material` 在框架 `showMenu` 内部
//   （flutter/src/material/popup_menu.dart:784  `_PopupMenuState.build`）
// ⇒ 它**不受本文件控制**：本文件只能通过 `showMenu` 的参数给它
//   color / shape / elevation / clipBehavior（这些已经全给了）。
//
// 要做出"整块面玻璃"只剩一条路：在菜单面**外面再套一层** `GlassContainer`。
// 那正是**重复模糊层** —— 旧13 的台账 31/42 与 `test/zz_t1044_glass_blur_parity_test.dart`
// 实测背书禁止的形态：
//   · 台账 31 逐像素：模糊对卡片**内部零贡献**，可见差异**全在边缘那圈描边**；
//   · t1044 实测：整层摘掉玻璃 Δpeak=58（画面会变）⇒ 玻璃不是"白付"，
//     但**再叠一层**只会加 raster 成本，不会多出可见收益。
// ⇒ 所以本文件**不**为了"整块面玻璃"而在外面加第二层 —— 这是形态的如实描述，
//   不是把 Owner 的要求降级（裁定见 task-4 的 Lead 回复）。
// ```
//
// # 那么玻璃到底落在哪
// ```text
// ① **面**：继续由框架 `Material` 承担，但颜色/圆角/描边**全部走本仓玻璃 tokens**
//    （`AppMenuSurface`：surfaceContainerHighest + outlineVariant + Radii.md + elevation 0）
//    —— 与 `AppDialogShell` / `AppGlassDialog` 的卡片同源。这一段 2026-10-17 已完成，
//    本轮的 t137 关系判据钉着它，**不许动**。
// ② **条目**：`AppMenuGlassSurface`（本文件新增）—— 每条一枚玻璃材质。
//    这是"材质落在条目上"的唯一落点，**不再往面上叠第二层**。
// ③ **动效**：从框架默认（300ms / linear）换成**本仓自己的动效档**
//    （`Motion.base` + `Motion.easeOut`，与 `OverlayCardMotion` 同一套曲线/时长），
//    并尊重「减少动效」⇒ `AnimationStyle.noAnimation`。
// ```
//
// ⚠️ 两个开关都**生产恒 false**（`debugSkipGlassMenu` 恒 false），只用于 A/B 对照：
//    默认行为（挂玻璃）一个像素都没动。
library;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedRectangle;
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import '../../design/icons/app_icons.dart';
import 'motion_prefs.dart';

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

// ═══════════════════════════════════════════════════════════════════════
//  N7：条目玻璃材质（**唯一**的玻璃落点）
// ═══════════════════════════════════════════════════════════════════════

/// 生产恒 `false` 的测量仪器开关 —— 只用于 A/B 对照（`test/zz_t1059_n7_menu_glass_test.dart`）。
///
/// # 为什么要有它（而不是"改产品行为来对照"）
/// ```text
/// 逐像素门禁需要"挂玻璃"与"不挂玻璃"两张图。若靠**改产品代码**来造对照，
/// 那对照本身就在改产品 —— 门禁跑完还得记得改回来（旧批踩过"忘了回滚"）。
/// ⇒ 用这个守卫：生产路径恒 false，只有测试把它翻 true。
/// ```
/// ⚠️ 与 `app_dialog_shell.dart` 的 `debugSkipGlassShell` /
///    `app_glass_dialog.dart` 的 `debugSkipGlassDialog` **各自独立**：
///    三个外壳三个开关，互不影响（改一个不会顺手改到别的弹窗）。
bool debugSkipGlassMenu = false;

/// 这一次要不要跳过条目玻璃
///
/// # 与「减少动效」的关系（旧13 的取舍：reduced-motion 档不挂玻璃）
/// ```text
/// `MediaQuery.disableAnimations` = 用户已声明减少动效/效果
///   ⇒ 连材质也一起降下来（省的是 raster 成本；代价是**可感知的**，
///     逐像素对照见 t1044：摘玻璃 Δpeak=58、全在边缘描边、卡片内部 zero）。
/// 这与 `app_dialog_shell.dart:508` 的 `skipGlassShellFor` / `app_glass_dialog.dart`
/// 的 `_skipGlass` 是**同一条判据**，三处形状一致。
/// ```
bool _skipGlassMenu(BuildContext context) =>
    debugSkipGlassMenu ||
    (MediaQuery.maybeOf(context)?.disableAnimations ?? false);

/// 把**一条菜单项的内容**包上玻璃材质。
///
/// # 它是"材质"，不是"内容" —— 所以只包内容，不碰条目几何
/// `PopupMenuItem` 自己的 `height: 40` / padding / `InkWell` / `Semantics`
/// **一字不动**（那几样是行为契约，t137 与无障碍都钉着）；本件只在它们**里面**
/// 加一层玻璃材质 ⇒ 点击、键盘、读屏全部走原路。
///
/// # 为什么不是"给整块面加玻璃"
/// 见文件头那一段：菜单面在框架内部，外面再套一层 = 重复模糊层（被旧13 实测否定）。
///
/// # 为什么用 `LiquidRoundedRectangle` 而不是 `LiquidRoundedSuperellipse`
/// `AppDialogShell` 玻璃档用的是 `LiquidRoundedRectangle(borderRadius: Radii.lg)`
/// （`app_dialog_shell.dart:524`）⇒ 条目沿用**同一个形状类**，只是半径取 `Radii.md`
/// （菜单比对话框矮一档，与 `AppMenuSurface` 的圆角语言一致）。
Widget appMenuGlassItem(BuildContext context, Widget child) {
  if (_skipGlassMenu(context)) return child;
  return GlassContainer(
    shape: kAppMenuGlassShape,
    padding: EdgeInsets.zero,
    child: child,
  );
}

/// 菜单**进出场**的动效档 —— 与 `AppGlassDialog` 那一族同一套 token。
///
/// # 改前是什么（实测：本仓自己没给，全吃框架默认）
/// ```text
/// `showMenu` 不传 `popUpAnimationStyle` ⇒ `_PopupMenuRoute.transitionDuration`
///   落在 `_kMenuDuration = 300ms`，`createAnimation` 的 curve 落在 `Curves.linear`
///   （flutter/src/material/popup_menu.dart:50 / :1017-1026）
/// ⇒ 与本仓 `Motion.base`(260ms) / `Motion.easeOut` 的动效**不是一套**，
///   且与本仓所有浮层（对话框/抽屉）的观感不一致 —— 这正是 Owner
///   说的「完全不适配现在设计风格」的一条具体成分。
/// ```
///
/// # 为什么尊重「减少动效」时给 `noAnimation` 而不是"时长为 0 的动画"
/// 与 `overlay_motion.dart:62 overlaySheetAnimationStyle` **同一条**判据：
/// `noAnimation` 让路由**不建动画层**（零 ticker），而"时长 0"仍会建。
AnimationStyle appMenuAnimationStyle(BuildContext context) =>
    MotionPrefs.reduce(context)
        ? AnimationStyle.noAnimation
        : const AnimationStyle(
            // 曲线/时长取本仓浮层那一套（`OverlayMotion.cardDuration` = Motion.base、
            // `OverlayMotion.cardCurve` = Motion.easeOut）。
            duration: OverlayMotion.cardDuration,
            curve: OverlayMotion.cardCurve,
          );

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
    // ★ N7：动效吃本仓那一套（框架默认是 300ms/linear）—— 两个入口共用
    popUpAnimationStyle: appMenuAnimationStyle(context),
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
    /*
     * ★★★ N7：**条目玻璃** —— 唯一落点，包在 **child 的外面**。
     *
     * # 为什么包 child 而不是包整个条目
     * ```text
     * `PopupMenuItem.height` / padding / 内建 `InkWell` / `Semantics`
     * 都在 `PopupMenuItemState.build` 里（framework 内部）：
     *   ConstrainedBox(minHeight: height) → Padding → Align → buildChild()
     * ⇒ 传进来的 `child` 正好**落在那一串里面** ⇒ 包它就是"给条目内容加材质"，
     *   而条目高 40、点击、键盘、读屏语义**一个都没动**（t137 钉着那些）。
     * ```
     * ⚠️ 若包在 `PopupMenuItem` **外面**（包整个条目），会同时套住框架的
     *    `InkWell` ⇒ 涟漪画到玻璃底下看不见，且禁用项的 IconTheme 也会被隔离。
     */
    child: appMenuGlassItem(context, it.child ?? _itemRow(it, fg)),
  );
}

/// 条目内容的标准排版（图标 16 + Sp.x3 间距 + 文字 sm）—— 与改前逐字相同。
///
/// ★ 抽出来的理由：N7 加玻璃时，`child: appMenuGlassItem(...)` 那一层需要一个
///   **表达式**，而 `if (it.icon != null) ...[]` 的集合展开只能写在
///   `children:` 里 ⇒ 用一个小函数比在调用点塞一个 `Builder` 干净。
Widget _itemRow<T>(AppMenuItem<T> it, Color fg) => Row(
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
    );

/// 条目玻璃的**形状** —— 与 `AppMenuSurface` 同源（`Radii.md`）。
///
/// ★ 提成常量：`GlassContainer` 的 `shape` 是 `LiquidShape`（非 const 构造链上
///   必须能 const 化，否则每帧 new 一个 shape 对象 ⇒ 触发 render 对象
///   `shape` setter 的 `markNeedsPaint`，等于每帧重画一遍玻璃）。
const LiquidRoundedRectangle kAppMenuGlassShape =
    LiquidRoundedRectangle(borderRadius: Radii.md);

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
      // ★ N7：动效与 [showAppMenu] 共用同一份（框架默认 300ms/linear）
      popUpAnimationStyle: appMenuAnimationStyle(context),
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
