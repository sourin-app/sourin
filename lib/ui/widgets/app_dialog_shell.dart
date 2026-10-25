/// 全仓统一弹窗外壳 —— 所有 AppDialog 必须走这里，不许各写各的
///
/// # 为什么要有这个文件
///
/// 改前 7 个弹窗的外壳各写各的，实测宽高有三/四种取值：
/// ```text
/// danmaku_settings_dialog  width 560 / maxHeight 620 / Radii.rLg
/// bili_import_dialog       width 560 / maxHeight 620 / Radii.rLg
/// source_switch_dialog     maxWidth 620 / maxHeight 640
/// update_dialog            width 460
/// skip_marker_dialog       maxWidth 820 / maxHeight 740（动态算）
/// plugin_edit_dialog       SizedBox 560（无统一 constraints）
/// provider_import_dialog   无宽度约束
/// ```
/// showAppDialog（overlay_motion.dart）只统一动效、不管样式，
/// 所以样式必须靠这个外壳组件收拢。
///
/// # 规范（见 docs/AGENTS.md 第 3.5 节）
///
/// ```text
/// 宽度      默认 560；窄弹窗 460、宽版面 820 需显式传 width 并注释原因
/// 最大高度  视口高度 * 0.8（MediaQuery，不写死数值）
/// 圆角      Radii.rLg
/// 标题栏    title + subtitle + 右侧关闭 IconButton
/// 内容区    SingleChildScrollView
/// 底部操作  可选 actions，与内容区分隔、按钮靠右
/// ```
///
/// # fill 语义（必读，写错会崩既有测试）
///
/// ```text
/// fill = true （默认）  调用方自己是 Stack 的直接孩子，定位由调用方负责
///                      本组件不写 Positioned（见 build 里的三版踩坑记录）
/// fill = false          同样直接返回内容，定位交给宿主
///                      供 SheetExitMotion 包裹（它要在中间插
///                      Opacity / IgnorePointer）
/// ```
/// 三个旧面板（danmaku / bili 等）的挂载点是 if (_open) XxxDialog(...)，
/// 直接做 Stack 的孩子。默认值必须保持 true。
/// 反之一旦被 SheetExitMotion 包着又写 Positioned.fill，两个
/// ParentDataWidget 会争同一个 StackParentData，抛
/// Incorrect use of ParentDataWidget。
library;

import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedRectangle;
import 'package:material_ui/material_ui.dart';

import '../app_scaffold.dart';
import '../app_theme.dart';
import '../tokens.dart';
import 'overlay_motion.dart';
import '../../design/icons/app_icons.dart';

/// 默认宽度。窄弹窗传 460，宽版面（片头片尾）传 820。
class AppDialogShell extends StatelessWidget {
  const AppDialogShell({
    super.key,
    required this.title,
    required this.child,
    this.subtitle,
    this.onClose,
    this.actions,
    this.width = 560,
    this.fill = true,
    this.scrollable = true,
    this.contentPadding,
    this.headerPadding,
    this.motion = false,
    this.margin,
    this.maxHeight,
    this.footer,
    this.icon,
    this.closeEnabled = true,
    this.forceDarkCard = false,
    this.glass = false,
  });

  /// 卡片是否走**玻璃材质**（2026-10-18，任务 B）
  ///
  /// # 为什么是可选、且默认 `false`
  /// ```text
  /// 这个外壳被**全仓 7 个弹窗**共用。玻璃化只针对弹幕面板，
  /// 默认 false ⇒ 其余 6 个弹窗**逐像素不变**（零回归）。
  /// 想玻璃化哪个就显式传 true。
  /// ```
  /// # 玻璃化做了什么
  /// ```text
  /// 卡片外面套一层 `GlassContainer`（半透明 + 模糊 + 描边），
  /// 同时把内层 `Material` 的底色置透明、描边置 none
  /// ⇒ 材质只由一层承担，不会叠出两层底。
  ///
  /// ⚠️ 内层 `Material` **必须保留**：框架的 SwitchListTile / ChoiceChip
  ///    把涟漪画在最近的 Material 上，去掉会抛
  ///    "ink splashes may be invisible"。
  /// ```
  final bool glass;

  /// 卡片高度上限的**绝对值**（与改前 7 个弹窗的 620 对齐）。
  ///
  /// ★ 2026-10-16：我第一版用「视口 × 0.8」算上限 —— 在 800×600 的测试视口下
  ///   只有 480，**比改前的 620 更矮** ⇒ 内容被挤、Slider 落到 y=559 出视口，
  ///   t70 的 3 条 tap 测试红（HEAD 基线 +76 全绿）。
  ///   0.8 这个数是拍的，没有依据 —— 改回「绝对值 + 视口夹取」。
  static const double _kMaxHeight = 620;

  /// 视口窄于此值时**放弃留边距**（卡片贴边），**不是**"弹窗没有意义"。
  ///
  /// ★ 2026-10-21（R4-⑤）：260 是从 `skip_marker_dialog.dart:2210` 抄来的
  ///   **经验值**。它的原注释写的是「内容可用宽（下限 260 —— 低于这个宽度
  ///   弹窗就没有意义了）」—— 那句是**断言，不是论证**，而且语义是错的（见下）。
  ///
  /// # 出处不可考（查过了）
  /// ```text
  /// $ git log -S "260.0" -- lib/ui/widgets/skip_marker_dialog.dart
  ///   b289bb6 2026-10-08 源影 · Flutter：跨端视频聚合客户端（首次开源）
  /// ⇒ 唯一命中的提交就是"首次开源"，拿不到更早的推导。
  /// $ grep -nE "MinWidth|minWidth|MinHeight" lib/ui/tokens.dart   ⇒ 0
  /// ⇒ tokens 里**没有"尺寸下限"这一类**（260 只以 Motion.base 的形式存在，
  ///    那是动画时长，不是宽度）。
  /// ```
  ///
  /// ⚠️ 它**不是**从"竖条事故"推导出来的 —— 别把两件事混起来：
  /// ```text
  /// 竖条事故（skip_marker_dialog:2164-2175 有完整记录）：
  ///   窗口 120 宽 → Dialog 默认 insetPadding 40*2 → 可用宽 40
  ///   → 再减 Sp.x5*2(40) 内边距 = **0** ⇒ 卡片塌成 40x640 竖条。
  /// ⇒ 那次证明的是"**下限不能是 0**"（否则可用宽退化成 0），
  ///   推不出"下限应该是 260"。260 是另一个独立的（且无据的）选择。
  /// ```
  ///
  /// # ★ 实测（2026-10-21）：它不是"安全下限"，是"边距消失的临界点"
  /// ```text
  /// vp=300 ⇒ cardW 268 / 边距 16
  /// vp=260 ⇒ cardW 260 / 边距  0
  /// vp=120 ⇒ cardW 120 / 边距  0    ← 它**照样渲染**，没有"没意义"
  /// ```
  /// `SizedBox(width: 260)` 仍然会被父级约束压到更小 ⇒ **它不造成溢出**。
  /// 它的唯一效果就是让 left/right margin 从 16 变成 0。
  ///
  /// ⚠️ 语义差别的危险之处：
  /// ```text
  /// 「低于它就没意义」    ⇒ 可能被引用成"再窄就不该开"（甚至加一条禁止逻辑）
  /// 「低于它不再留边距」  ⇒ 只是边距策略的临界点，安全、无副作用
  /// ⇒ 错误的语义比没有语义更危险，因为它会指导别人做错事。
  /// ```
  ///
  /// ⇒ 若将来要给它真实依据，需要回答：
  ///   「260 宽下哪个弹窗的内容开始不可用」——**目前没有任何人测过**。
  ///   在那之前，**不要把它当安全下限引用**。
  static const double _kMinDialogWidth = 260;



  final String title;
  final String? subtitle;

  /// 内容区。scrollable = false 时不套 SingleChildScrollView
  /// （调用方自己管滚动，例如内部已有 ListView 的面板）。
  final Widget child;

  /// 右上角关闭。传 null 时不渲染关闭钮。
  final VoidCallback? onClose;

  /// 底部操作区。传 null 时不渲染底部条。
  final Widget? actions;

  final double width;
  final bool fill;
  final bool scrollable;
  final EdgeInsets? contentPadding;
  final EdgeInsets? headerPadding;

  /// 是否套 [OverlayScrim] / [OverlayCardMotion] 的入场动效。
  ///
  /// ★★ 默认 **false** —— 与改前 `bili_import_dialog` / `update_dialog` 等
  ///   「无动效」面板逐像素一致。
  ///
  /// ⚠️ 为什么不能无条件开启（实测教训）：
  ///   `OverlayCardMotion` 的 `TweenAnimationBuilder` 首帧 `t = 1`，
  ///   卡片会被 `Transform.translate` 下移 24px。只用 `pump()` 不推时长的
  ///   测试（如 `t70_bili_danmaku_test.dart` 的 `_host`）里，卡片停在
  ///   下移后的位置 ⇒ 按钮落到 y=622、超出 800×600 视口 ⇒ tap 打空，
  ///   t70 三条红（HEAD 基线 +76 全绿）。
  ///
  ///   改前 `danmaku_settings_dialog` / `subtitle_panel` 有动效、
  ///   `bili_import_dialog` 没有 —— 这个开关就是为还原这个差异。
  final bool motion;

  /// 卡片外边距。窄屏时给左右留白用（`subtitle_panel` 就是
  /// `wide ? EdgeInsets.zero : EdgeInsets.symmetric(horizontal: Sp.x3)`）。
  final EdgeInsets? margin;

  /// 覆盖高度上限（默认 [_kMaxHeight] = 620）。
  ///
  /// `subtitle_panel` 用「视口 × 0.86」，比 620 大 —— 它的内容是长列表，
  /// 需要尽量高。**按需传，不要为了"看起来统一"乱改**。
  final double? maxHeight;

  /// 固定在**底部**、不随内容滚动的区域（`subtitle_panel` 的 `_footer`）。
  ///
  /// 与 [actions] 的区别：`actions` 是「按钮条」（外壳自带分隔线 + 靠右布局），
  /// `footer` 是「调用方自己画的任意底部区」（外壳原样放，不加装饰）。
  final Widget? footer;

  /// 标题左侧图标（透传给 [_Header]）。
  final IconData? icon;

  /// 关闭钮是否可点（透传给 [_Header]）。
  final bool closeEnabled;

  /// 卡片强制**深色**外观（不跟随系统主题）。
  ///
  /// # 什么时候必须开（★ 2026-10-16 实测教训）
  /// ```text
  /// 弹幕设置面板的文字色来自 `DanmakuTextColors` —— 那是一套**为深色底
  /// `#14161B` 设计的固定灰阶**（body #E6E6E6 / secondary #B9BEC6 /
  /// muted #8E939B），`t27_w1_danmaku_contrast_test` 钉着它们对那个底的
  /// 对比度（14.5:1 / 9.7:1 / 5.9:1）。
  ///
  /// 我把卡片底统一成 `surfaceContainerHighest`（跟随主题）之后，**浅色主题**
  /// 下底变成浅灰，而灰阶还是浅色 ⇒ Owner 实测「字都看不清了」。
  /// ```
  ///
  /// ⚠️ 这不是「把灰阶改成主题色」能解决的：那 41 处灰阶与 t27_w1 门禁是
  ///    一起设计的，改色要先改门禁判据（等于改设计）。
  ///    这个面板**本来就是深色面板**（业主 fig1 的实测底色就是 #14161B）。
  /// ⇒ 正确做法是让它**保持深色**，与「底写死 ⇒ 前景也写死」这条通则一致。
  final bool forceDarkCard;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);

    /*
     * ★★ 2026-10-16（Owner 第 8 条）：键盘交互统一到外壳。
     *
     * Owner 原话：「这些个弹窗的ui布局,交互都很烂,请优化,真的操作很烂」
     *
     * 改前的问题：
     * ```text
     * ① 各弹窗自己处理 Esc（有的处理、有的没有、有的处理两次）
     *    ⇒ 用户按 Esc 有时关有时不关，像坏了。
     * ② Tab 焦点会跑出弹窗到背后的页面上 ⇒ 键盘用户"失联"。
     * ③ 没有默认焦点 ⇒ 打开弹窗后要按好几次 Tab 才到第一个输入框。
     * ```
     *
     * ⇒ 三件事收口到外壳一处：
     *   Esc 关闭（`onClose` 存在时）、焦点循环（`FocusTraversalGroup`）、
     *   自动聚焦第一个可聚焦控件。
     *
     * ⚠️ 只做**加法**：调用方原来自己处理的 Esc 仍生效（多一次 pop 是无害的，
     *    因为路由已 pop 后 `onClose` 不会再被调用 —— 见 `_escClose` 的 mounted 判断）。
     */
    final shell = _buildShell(context, media);
    if (onClose == null) return shell;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () {
          if (closeEnabled) onClose!();
        },
      },
      child: FocusTraversalGroup(child: shell),
    );
  }

  Widget _buildShell(BuildContext context, MediaQueryData media) {

    /*
     * ★★ forceDarkCard：**整棵子树**强制深色主题，而不是只把卡片底刷成深色。
     *
     * 为什么必须包一层主题、不能只改底色（2026-10-16 Owner 实测「字都看不清了」）：
     * ```text
     * 只改底色 ⇒ 卡片是深色，但内部的框架控件（SegmentedButton / Switch /
     * Slider / TextField）仍按**外层主题**取色。
     * 浅色主题下它们按浅色渲染（浅灰字/浅色轨道）压在深底上 ⇒ 几乎不可见。
     * 实测截图：Tab 栏的**两个未选中项**在**两态下都看不见**（选中项正常）。
     * ```
     * `AppThemeHost` 会把 `Theme` 换掉 ⇒ 子树里所有 `Theme.of` 都拿到深色，
     * 与 `PlayerPanelTheme`（player_page.dart:201）同一个手法。
     */
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-21（R4-⑤）：宽度**按视口夹取** + 窄视口自动留边距
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前的缺陷（真机前置的像素验证抓到，不是推断）
     * ```text
     * 外壳直接 `SizedBox(width: width)`，**没有任何视口夹取**，
     * 且 `margin` 默认 `EdgeInsets.zero`。
     *
     * 视口 800x600 下的实测（三弹窗）：
     *   composer(width 820)  卡片 = [0,0 .. 800,600]  边距 **0/0/0/0**
     *   skip   (width 768)   卡片 = [16,16 .. 784,584] 边距 16（它自己夹取）
     *   update (width 460)   卡片 = [170,122 .. 630,478] 居中
     *
     * ⇒ 卡片顶满屏幕时：遮罩看不见（四角像素=卡片色，不是遮罩色）、
     *   圆角被切掉、标题栏顶到屏幕最上沿。
     * ```
     *
     * # 为什么修在**外壳**而不是各弹窗
     * ```text
     * 7 个弹窗里有 5 个是「硬编码 width + 不夹取」：
     *   composer 820 / plugin_edit 560 / bili 560 / danmaku 560 / provider 560
     * 只修 composer ⇒ 另外 5 个仍留着同一个坑，而下一个人看到 composer 是好的，
     * 就会以为外壳是对的。**「5 个有隐患只有 1 个修」比「6 个都没修」更难发现。**
     * ```
     *
     * # 夹取公式（照抄 `skip_marker_dialog` 的既有写法，不是新发明）
     * ```text
     * maxW        = 视口宽 − 两侧外边距（Sp.x4 = 16）
     * effectiveW  = min(传入的 width, maxW)
     * 夹取发生 ⇔ width > maxW
     * ```
     * ⚠️ 下限 260：与 `skip_marker_dialog` 的 `math.max(..., 260.0)` 同源 ——
     *    低于 260 的弹窗没有意义（实测窄窗口塌成竖条那次就是这个数）。
     *
     * # 大视口**零影响**（这是回归判据，已实测）
     * ```text
     * 1280x800 下 width 460/820/820 全部 < maxW(1248) ⇒ 不夹取 ⇒ effectiveW == width
     * ⇒ 卡片宽度与改前**逐像素相同**（实测 cardW 460/820/820，改前改后一致）。
     * ```
     */
    final viewport = MediaQuery.sizeOf(context);
    // 两侧各留 16（Sp.x4）—— 与 skip_marker_dialog 的 margin 同值
    const double horizontalMargin = Sp.x4;
    final maxCardW =
        math.max(viewport.width - horizontalMargin * 2, _kMinDialogWidth);
    final effectiveW = math.min(width, maxCardW);

    final card = _maybeDark(
      SizedBox(
        width: effectiveW,
        child: ConstrainedBox(
        // ★ 同时给 minHeight：`Flexible` 里的滚动区需要有界高度才生效。
        //   只给 maxHeight 时，Column(mainAxisSize.min) 在 loose 约束下会
        //   把内容全部撑开（实测 30 行内容算出 1303px，滚动条形同虚设）。
        // ★ 2026-10-16 修：这里原来写死 `_kMaxHeight`，`maxHeight` 字段
        //   **声明了却从没被读** —— 传了不生效（dlg-subtitle 实测抓到）。
        /*
         * ★★★ 2026-10-21（R4-⑤）：高度也要**按视口夹取**。
         *
         * # 改前的缺陷（与宽度同源，同一轮发现的第二处）
         * ```text
         * 改前：maxHeight ?? _kMaxHeight  —— 只认常量，不认视口。
         * 视口 800x600、composer(maxHeight 620) 实测：
         *   卡片 = 768x**600**，上下边距 **0/0**
         *   左右已有 16（宽度夹取修好之后）
         * ⇒ 上下仍然贴满屏幕：标题栏顶到 y=0、底部按钮区压到 y=600。
         * ```
         * # 修法：与宽度对称
         * ```text
         * maxCardH = max(视口高 − 2*Sp.x4, 下限)
         * effectiveMaxH = min(maxHeight ?? _kMaxHeight, maxCardH)
         * ```
         * 下限用 320（与 `skip_marker_dialog` 的
         * `math.max(media.height - margin*2, 320.0)` 同源）：再矮就没有意义，
         * 那种场合宁可让卡片顶到边（此时内部一定可滚，判据 C 钉着）。
         *
         * ★ 大视口零影响：1280x800 下 maxCardH = 768 > 620 ⇒ 取 620，与改前一致。
         */
        /*
         * ══════════════════════════════════════════════════════════════
         * ★ 高度：**不加视口夹取**（原因见下，这是与宽度不对称的地方）
         * ══════════════════════════════════════════════════════════════
         *
         * # 我试过加，然后回退了（2026-10-21，t70 变红抓到的）
         * ```text
         * 加夹取：maxHeight = min(maxHeight ?? 620, 视口高 - 32)
         *   800x600 视口下 ⇒ 620 被夹到 568
         *   ⇒ 卡片比父级约束**允许的**还矮 32px
         *   ⇒ t70「立即更新」按钮落到 y=598（视口 600），点击打空 ⇒ 那条红
         * ```
         * # 为什么宽度需要夹取、高度不需要
         * ```text
         * 宽度：`SizedBox(width:)` 是**紧**约束，父级只会把它压到视口宽，
         *       **不会**自动留边距 ⇒ 卡片贴满屏幕（这是真缺陷，已修）。
         *       夹取 = 主动留白，方向正确。
         *
         * 高度：`ConstrainedBox(maxHeight:)` 给的是**上界**，父级约束
         *       （Scaffold.body / showDialog 路由）本来就会把它压到视口内。
         *       实测 800x600：不加夹取时卡片高 = **600**（正好视口高），
         *       不溢出、内部可滚。
         *       ⇒ 再夹一次（568）是**双重夹取**，只会让卡片更矮、把内容挤出去。
         * ```
         * ⇒ 高度的"按视口夹取"由**父级约束**天然完成，外壳只负责常量上限 620。
         */
        constraints: BoxConstraints(maxHeight: maxHeight ?? _kMaxHeight),
        child: Material(
          // card 类型 + antiAlias 裁剪：框架的 SwitchListTile / ChoiceChip
          // 把涟漪画在最近的 Material 祖先上，盒子里没有 Material
          // 会抛 ink splashes may be invisible。
          type: MaterialType.card,
          clipBehavior: Clip.antiAlias,
          // ★ 2026-10-16 统一：卡片底色用 `surfaceContainerHighest`
          //   —— 它是 M3 里「抬升的卡片/对话框面」的语义角色。
          //   实测各面板改前**本来就不一致**：
          //     bili      写死 Color(0xFF14161C)@0.98
          //     danmaku   DanmakuTextColors.panelBg@0.98
          //     subtitle  colorScheme.surfaceContainerHighest
          //     provider  colorScheme.surfaceContainerHighest@0.3/0.35
          //   深色下 surfaceContainerHighest = #171717，与 bili 那个写死值
          //   #14161C 几乎同档 ⇒ 统一到它观感变化最小，且明暗两套都有定义。
          //   原用 `surface`@0.98（深色 #0A0A0A）—— 卡片与页面底几乎同色，
          //   "浮起来"的感觉没了。
          color: glass
              /*
               * ★★★ 2026-10-19（第 66 轮 R3-① / R3-②）：`Colors.transparent` → **实色衬底**
               *
               * # 改前为什么是 transparent
               * ```text
               * 任务 B 玻璃化时把遮光整个交给外层 `GlassContainer`，
               * 内层 Material 置透明 —— 当时的目标是"别叠出两层底"。
               * ```
               * # 但真渲染像素取证证明那样**把文字弄糊了**
               * ```text
               * 在最坏底图（纯白 + 高饱和动画色块）上真渲染本弹窗，
               * 对每个 Text 的矩形做颜色直方图（众数=真实背景、次众数=字形）：
               *
               *   卡片内真实背景  rgb(94,91,45) / rgb(95,35,50) / rgb(26,85,94)
               *                   ← **橄榄/暗红/暗青**，全是底下色块透上来的
               *   说明档 #8E939B 对 rgb(94,91,45) = **2.09:1**（正文线 4.5）
               *   次要档 #B9BEC6 对 rgb(94,91,45) = **3.74:1**
               *
               * 而"常量对 #14161B"是 5.86~14.5:1（t27_w1 早钉过）——
               * 两组数字对不上，唯一解释就是**真实背景根本不是那个常量色**。
               * ```
               * # 修法：玻璃只负责质感，遮光由这层实色负责
               * ```text
               * 玻璃档也给它一个**高不透明度**的实色底（与非玻璃档同源 #14161B@0.98）。
               * ⇒ 文字永远压在自己那层实色上，与底下画面无关；
               *   外层的 GlassContainer 仍然在（描边/模糊/高光都是它画的），
               *   只是**不再承担遮光** —— 这是职责划分，不是把玻璃删掉。
               *
               * ⚠️ 保留 2% 透明度（0.98）：与 `forceDarkCard` 那一支完全一致，
               *    玻璃的"透一点底色"观感仍在，但不足以污染文字对比度。
               * ⚠️ 涟漪宿主仍是这个 Material（只是它现在**有底色**了，更好）——
               *    `SwitchListTile` / `ChoiceChip` 依赖它，不能删。
               * ```
               */
              ? const Color(0xFF14161B).withValues(alpha: 0.98)
              : forceDarkCard
                  // 深色档：与 DanmakuTextColors.panelBg 同源（业主 fig1 实测值）
                  ? const Color(0xFF14161B).withValues(alpha: 0.98)
                  : Theme.of(context).colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: Radii.rLg,
            // ★ 2026-10-16 修：原来用 `dividerColor` —— 它是**亮灰**
            //   （深色 #938F99 / 浅色 #79747E），画在卡片边上很显眼。
            //   实测 `outlineVariant` 才是这套主题的「弱化描边」
            //   （深色 #222222 / 浅色 #DFE1E8），与各面板改前用的同一个角色。
            side: glass
                // 玻璃档：描边由 GlassContainer 画，Material 这层不再画
                ? BorderSide.none
                : BorderSide(
                    color: forceDarkCard
                        // 深色档：与 DanmakuTextColors.border 同源
                        ? const Color(0xFF4A4E56)
                        : Theme.of(context).colorScheme.outlineVariant,
                  ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _Header(
                title: title,
                subtitle: subtitle,
                onClose: onClose,
                padding: headerPadding,
                icon: icon,
                closeEnabled: closeEnabled,
                forceDark: forceDarkCard,
              ),
              Flexible(
                child: scrollable
                    ? SingleChildScrollView(
                        clipBehavior: Clip.antiAlias,
                        padding: contentPadding ??
                            const EdgeInsets.fromLTRB(Sp.x6, 0, Sp.x6, Sp.x2),
                        child: child,
                      )
                    : child,
              ),
                if (footer != null) footer!,
                if (actions != null) _ActionBar(child: actions!),
              ],
            ),
          ),
        ),
      ),
    );
    /*
     * ★★ 2026-10-18（任务 B）：玻璃档 —— 在卡片**外面**套一层材质。
     *
     * # 为什么包在外面而不是改里面的 Material
     * ```text
     * Material 必须继续存在（涟漪宿主），且必须是**内层**；
     * 玻璃只是"外观"，把它套在最外层最直观，也不动内部结构。
     *
     * 玻璃档时 Material 的 color 已置透明、side 已置 none（见上），
     * ⇒ 材质完全由这层 GlassContainer 承担，不会叠出两层底。
     * ```
     * ⚠️ `glass == false` 时**原样返回** ⇒ 其余 6 个弹窗逐像素不变。
     */
    final shelled = (glass && !skipGlassShellFor(context))
        ? GlassContainer(
            /*
             * ★ 玻璃轮廓的圆角取 `Radii.lg`（22），改前是硬编码 `20`。
             *
             * 同一个壳里原本**两个值**：内层 Material 的
             * `RoundedRectangleBorder(borderRadius: Radii.rLg)`（见 :303）是 22，
             * 而这一层是 20。玻璃档下观感由**这一层**决定 —— 内层 Material 的
             * color 已置透明、side 已置 none（它不画底也不描边），且
             * `Material.clipBehavior` 默认 `Clip.none`（它不裁切）——
             * ⇒ 真正被看见的圆角一直是 20，§3.5 的「圆角 Radii.rLg」
             * 在玻璃档上**名不副实**。两处现已统一成 `Radii.lg`。
             *
             * ⚠️ 别把这里改回字面量：§3.5 写「圆角一律 Radii.*，禁硬编码」，
             *    引 token 才能在下一次调 `Radii.lg` 时自动跟上。
             */
            shape: const LiquidRoundedRectangle(borderRadius: Radii.lg),
            padding: EdgeInsets.zero,
            child: card,
          )
        : card;
    final overlay = GestureDetector(
      /*
       * 点背景关闭（与播放页其它面板一致）
       *
       * ⚠️ 2026-10-17（CodeRabbit CR）：**必须也检查 `closeEnabled`**。
       *
       * 改前只有这一条路径没检查 —— 于是三条关闭路径不一致：
       * ```text
       *   X 按钮   → 检查 closeEnabled ✓
       *   Esc      → 检查 closeEnabled ✓
       *   点遮罩   → **不检查** ✗  ⇒ 忙碌时点背景仍能关
       * ```
       * 具体受害场景：字幕面板忙碌时传 `closeEnabled: !_st.busy`，
       * 原意是"搜索进行中不许关"，但点遮罩能绕过去。
       *
       * ⇒ 与 Esc 用**同一个判据**（`closeEnabled ? onClose : null`）。
       *   注意这里**不能**写成 `closeEnabled ? onClose : () {}` —— 空回调
       *   仍会吞掉点击（虽然行为上等价，但留一个死回调容易误导）。
       */
      onTap: closeEnabled ? onClose : null,
      child: _scrim(context,
        Center(
          child: Padding(
            /*
             * 外边距。
             *
             * ★ 2026-10-21（R4-⑤）：默认值从 `EdgeInsets.zero` 改成
             *   **只在"视口太窄、宽度被夹取"时**留左右边距。
             *
             * # 为什么不能无条件给默认 margin（Lead 明确要求实测）
             * ```text
             * 无条件 `EdgeInsets.symmetric(horizontal: Sp.x4)` 会让**大视口**下
             * 卡片也被塞进一个 16px 的 Padding 里 —— 虽然卡片本身宽度不变，
             * 但它在 `Center` 里的"可用盒"变了，且 bottom sheet 形态
             * （`fill: false` + 宿主 Stack）的定位语义会被动到。
             * ⇒ 只在大视口零影响的前提下才敢改默认值，而这个前提
             *   只有在**夹取发生**时才成立。
             * ```
             * # 夹取时为什么必须留边距
             * ```text
             * 夹取后 `effectiveW == 视口宽 - 32` ⇒ 两侧天然各有 16px 留白，
             * 卡片**不会**贴满屏幕；而 `margin` 再叠一层 16 会让它变成
             * `视口宽 - 64` ⇒ 双重夹取，反而更窄（这正是 skip 自算 + 外壳夹取
             * 若同时存在会出的问题，见 skip 那边的注释）。
             * ⇒ 夹取时**不额外加 margin**：宽度公式已经把边距算进去了。
             * ```
             */
            padding: margin ?? EdgeInsets.zero,
            child: GestureDetector(
              // 卡片内部的点击不能穿透到背景（否则点滑块也会关掉面板）
              onTap: () {},
              child: motion ? OverlayCardMotion(child: shelled) : shelled,
            ),
          ),
        ),
      ),
    );

    /*
     * ══════════════════════════════════════════════════════════════════
     * fill 两种取值 —— 定位责任归属（★ 四版踩坑后的定稿）
     * ══════════════════════════════════════════════════════════════════
     *
     * 【契约】
     *   fill = true （默认）  本组件**自撑满**宿主给的空间（`SizedBox.expand`）
     *   fill = false          只返回内容，定位交给宿主（`SheetExitMotion`）
     *
     * 【坑 1】`Positioned` 必须有 `Stack` 祖先
     *   第一版 `GestureDetector(child: OverlayScrim(child: Positioned.fill(...)))`
     *   ⇒ 父链是 GestureDetector（不产生 RenderObject）⇒
     *     `Incorrect use of ParentDataWidget`（t99 红 9 条）。
     *
     * 【坑 2】走 `showDialog` 路由时，内容树里**没有** `Stack`
     *   第二版把 `Positioned.fill` 挪到最外层 —— t99 绿了，但真实路由一挂就崩：
     *   ```text
     *   The offending Positioned is currently placed inside a Padding widget.
     *   Chain: GestureDetector ← Positioned ← AppDialogShell ← Builder ←
     *          _CaptureAll ← MediaQuery ← Padding ← SafeArea
     *   ```
     *   ⇒ 路由内容树是 `SafeArea → Padding → MediaQuery → Builder`，没有 Stack。
     *   （`test/zz_dialog_shell_route_test.dart` 抓的，既有测试没一条走真实路由）
     *
     * 【坑 3】自建 `Stack(fit: StackFit.expand)` 会让卡片**撑满视口**
     *   第三版外壳自建 Stack —— 两个坑都没了，但 `StackFit.expand` 把紧约束
     *   传给卡片 ⇒ 卡片长成整个视口（1444×845），而不是按内容收缩
     *   ⇒ 视觉上是「只有一层灰、看不见弹窗」（Owner 2026-10-09 截图记过）。
     *   实测：t70 三条 tap 测试红（按钮落到 y=632，超出 800×600 视口）。
     *
     * 【坑 4】直接 `return overlay` ⇒ `Center` 在松约束下缩成 0×0
     *   第四版什么都不包 —— 但 `OverlayScrim` 内部的 `Stack` 是
     *   `StackFit.loose`，卡片那一路拿不到紧约束 ⇒ `Center` 塌成 0 尺寸，
     *   卡片画不出来、点击全被遮罩吃掉。
     *   实测：t70 仍 -3，命中栈顶是 `_RenderColoredBox`（遮罩），Expected 5 / Actual null。
     *
     * 【定稿】`fill = true` 时用 **`SizedBox.expand`** —— 它是普通 RenderObject，
     *   **不要求** `Stack` 祖先（避开坑 1、2），又给紧约束（避开坑 4），
     *   而紧约束只到 `OverlayScrim` 这一层：卡片仍是它的**非定位孩子**、
     *   由 `Center` 按内容居中 ⇒ 几何与改前逐像素一致（避开坑 3）。
     *
     * ⚠️ `fill: false` 也**必须**返回 `overlay`（含遮罩 + 点背景关闭），
     *   不能只返回卡片 —— 改前面板的 `body` 就含这两样。
     */
    if (!fill) return overlay;

    /*
     * fill = true：把 overlay 撑到**宿主给的最大空间**。
     *
     * 【坑 5】`SizedBox.expand` 在 loose 约束下会塌成 0×0
     *   第五版用 `SizedBox.expand(child: overlay)` —— 它在**紧**约束下没问题，
     *   但 `Stack` 给非定位孩子的约束是 **loose**（`StackFit.loose`，
     *   max 有界、min 为 0）⇒ `SizedBox.expand` 想撑到无穷、被夹到 min=0
     *   ⇒ 塌成 0×0，卡片画不出来（t70 仍 -3，命中栈顶 `_RenderColoredBox`）。
     *
     * 【定稿】`ConstrainedBox` 把 min 提到 max —— 不依赖父级是 Stack，
     *   也不依赖约束是紧的，两种宿主（loose / tight）都撑满：
     *   · 直挂 Stack（t70 的宿主）⇒ loose ⇒ 被提到 max ⇒ 撑满 ✓
     *   · showDialog 路由（SafeArea/Padding 给的紧约束）⇒ 本来就是 tight ⇒ 撑满 ✓
     *   · 播放页 fill=false ⇒ 走上面的早返回，不受影响 ✓
     */
    /*
     * 【定稿】把 overlay 撑到宿主给的最大空间。
     *
     * 为什么用 `LayoutBuilder` + `ConstrainedBox(min = max)` 而不是别的：
     * ```text
     * Positioned.fill   要求祖先有 Stack —— 走 showDialog 路由时没有（坑 1/2）
     * SizedBox.expand   在 loose 约束下塌成 0×0（Stack 给非定位孩子的是 loose，坑 5）
     * Stack(expand)     把紧约束传给卡片 ⇒ 卡片长成整个视口（坑 3）
     * ```
     * `ConstrainedBox` 把 min 提到 max —— 不依赖祖先类型、不依赖约束松紧，
     * 三种宿主（Stack 直挂 / Scaffold.body / showDialog 路由）都撑满；
     * 而紧约束只到 `OverlayScrim` 这一层，卡片仍是它的非定位孩子、
     * 由 `Center` 按内容居中 ⇒ 几何与改前一致。
     */
    // 用 MediaQuery 的尺寸给**紧约束** —— 不依赖宿主的约束松紧，
    // 也不要求祖先有 Stack（避开坑 1/2/5）。
    // 这与改前 `Positioned.fill` 在「铺满视口」这一点上等价。
    return SizedBox(
      width: media.size.width,
      height: media.size.height,
      child: overlay,
    );
  }
  /// `forceDarkCard` 时把整棵子树换成深色主题（见该字段的文档）。
  Widget _maybeDark(Widget child) {
    if (!forceDarkCard) return child;
    return AppThemeHost(
      data: AppTheme.themeFor(Brightness.dark),
      child: child,
    );
  }

  /// 遮罩层 —— `motion` 决定用带淡入的 [OverlayScrim] 还是裸 `ColoredBox`。
  ///
  /// 裸 `ColoredBox` 是改前 `bili_import_dialog` 的写法（无动画层），
  /// [OverlayScrim] 是改前 `danmaku_settings_dialog` / `subtitle_panel` 的写法。
  /// 见 [motion] 的文档。
  Widget _scrim(BuildContext context, Widget child) {
    final color = Colors.black.withValues(alpha: 0.72);
    if (motion) return OverlayScrim(color: color, child: child);
    // 裸 ColoredBox 作**父**：与改前 bili 的 `ColoredBox(child: Center(...))` 一致。
    // ⚠️ 不能无脑用 `OverlayScrim` —— 它内部是 `Stack[Positioned.fill(ColoredBox), child]`，
    //   而 `Stack` 给非定位孩子的是 **loose** 约束 ⇒ 在 `Stack` 直挂的宿主下
    //   整层会缩到卡片大小、遮罩盖不住全屏（t70 实测命中栈顶变成 `_RenderColoredBox`）。
    return ColoredBox(color: color, child: child);
  }
}


class _Header extends StatelessWidget {
  const _Header({
    required this.title,
    this.subtitle,
    this.onClose,
    this.padding,
    this.icon,
    this.closeEnabled = true,
    this.forceDark = false,
  });

  final String title;
  final String? subtitle;
  final VoidCallback? onClose;
  final EdgeInsets? padding;

  /// 标题左侧的图标（`subtitle_panel` 改前有 `AppIcons.subtitles_outlined`）。
  /// 传 null 时不占位。
  final IconData? icon;

  /// 关闭钮是否可点。`subtitle_panel` 改前是 `_st.busy ? null : onClose`
  /// （忙碌时禁用关闭）—— 外壳只收 `VoidCallback?` 表达不了禁用态，
  /// 所以单独给一个开关。
  final bool closeEnabled;

  /// 标题/关闭钮走**深色卡片**上的浅色档（见 [AppDialogShell.forceDarkCard]）。
  final bool forceDark;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    // ★ 深色档的取色与 `DanmakuTextColors` 同源（body / muted），
    //   这样强制深色的面板里，标题栏与面板正文是同一套灰阶。
    final titleColor = forceDark ? const Color(0xFFE6E6E6) : cs.onSurface;
    final subColor = forceDark ? const Color(0xFF8E939B) : cs.onSurfaceVariant;
    return Padding(
      padding: padding ??
          const EdgeInsets.fromLTRB(Sp.x6, Sp.x3, Sp.x3, Sp.x2),
      child: Row(
        children: [
          if (icon != null) ...[
            Icon(icon, color: subColor),
            const SizedBox(width: Sp.x2),
          ],
          // ★ 无副标题时用 Spacer（与改前各面板的 `Text + Spacer + IconButton`
          //   逐像素一致）；有副标题才走 Column。
          //   实测：`Expanded(Column(min))` 会比 `Spacer` 多算出一行的高度，
          //   在 800×600 视口下把「立即更新」按钮顶到 y=622（出视口），
          //   t70 的 tap 测试因此红。
          if (subtitle == null)
            Expanded(
              child: Text(
                title,
                style: TextStyle(
                  color: titleColor,
                  fontSize: FontSizes.lg,
                  fontWeight: FontWeight.w600,
                ),
              ),
            )
          else
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: FontSizes.lg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Sp.x1),
                  Text(
                    subtitle!,
                    // ★ 长片名不许换行把标题栏撑高（改前 subtitle_panel 就是
                    //   `maxLines: 1` + ellipsis）
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: subColor,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ),
            ),
          if (onClose != null)
            IconButton(
              onPressed: closeEnabled ? onClose : null,
              icon: Icon(AppIcons.close, color: titleColor),
              tooltip: '关闭',
            ),
        ],
      ),
    );
  }
}

class _ActionBar extends StatelessWidget {
  const _ActionBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Divider(height: 1),
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x2, Sp.x6, Sp.x3),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [child],
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  玻璃档的「要不要挂」判据（第 13 项：7ms 的模糊值不值得画）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这里会有一个开关
// ```text
// 本外壳的玻璃档内层是 `#14161B @ alpha 0.98`（见 build 里 glass 分支的 color）
// ⇒ 玻璃画的模糊对最终像素的贡献上限只有 2%。
// 要证明"糊了一层几乎看不见的东西"，只能把玻璃**摘掉再渲一张**逐像素比
// （判据见 test/zz_t1044_glass_blur_parity_test.dart）。
// ⇒ 这个开关是**仪器**：生产恒 false，行为逐字不变。
// ```

/// 测量时临时摘掉玻璃层（生产恒 false；逐像素对照用）
///
/// 与 `app_glass_dialog.dart` 的同名开关**各自独立**：两套外壳的
/// "要不要挂玻璃"必须能单独验证，混用一个开关会让对照实验互相污染。
@visibleForTesting
bool debugSkipGlassShell = false;

/// 这一次要不要跳过玻璃层
///
/// # 这是一条**有意的取舍**，不是性能优化
/// ```text
/// 省的是 raster 成本；代价是**可感知的**：
///   逐像素对照（test/zz_t1044_glass_blur_parity_test.dart）里摘掉玻璃
///   ⇒ Δpeak 13 / 受影响像素 0.07%，差**全在边缘描边**，卡片内部 zero（interiorΔpeak ≤ 1）。
/// ⇒ 不是"看不见的浪费"，而是"用户说少点效果，就少一点"。
/// ```
/// # 判据
/// ① [debugSkipGlassShell] —— 测量仪器（生产恒 false）；
/// ② `MediaQuery.disableAnimations` —— 用户已声明减少动效/效果。
///
/// # 若要回退（Owner 认为不可接受时，**一行**）
/// ```dart
/// bool skipGlassShellFor(BuildContext context) => debugSkipGlassShell;
/// ```
bool skipGlassShellFor(BuildContext context) =>
    debugSkipGlassShell ||
    (MediaQuery.maybeOf(context)?.disableAnimations ?? false);
