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

import 'package:flutter/services.dart';
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
  });

  /// 卡片高度上限的**绝对值**（与改前 7 个弹窗的 620 对齐）。
  ///
  /// ★ 2026-10-16：我第一版用「视口 × 0.8」算上限 —— 在 800×600 的测试视口下
  ///   只有 480，**比改前的 620 更矮** ⇒ 内容被挤、Slider 落到 y=559 出视口，
  ///   t70 的 3 条 tap 测试红（HEAD 基线 +76 全绿）。
  ///   0.8 这个数是拍的，没有依据 —— 改回「绝对值 + 视口夹取」。
  static const double _kMaxHeight = 620;

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
    final card = _maybeDark(
      SizedBox(
        width: width,
        child: ConstrainedBox(
        // ★ 同时给 minHeight：`Flexible` 里的滚动区需要有界高度才生效。
        //   只给 maxHeight 时，Column(mainAxisSize.min) 在 loose 约束下会
        //   把内容全部撑开（实测 30 行内容算出 1303px，滚动条形同虚设）。
        // ★ 2026-10-16 修：这里原来写死 `_kMaxHeight`，`maxHeight` 字段
        //   **声明了却从没被读** —— 传了不生效（dlg-subtitle 实测抓到）。
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
          color: forceDarkCard
              // 深色档：与 DanmakuTextColors.panelBg 同源（业主 fig1 实测值）
              ? const Color(0xFF14161B).withValues(alpha: 0.98)
              : Theme.of(context).colorScheme.surfaceContainerHighest,
          shape: RoundedRectangleBorder(
            borderRadius: Radii.rLg,
            // ★ 2026-10-16 修：原来用 `dividerColor` —— 它是**亮灰**
            //   （深色 #938F99 / 浅色 #79747E），画在卡片边上很显眼。
            //   实测 `outlineVariant` 才是这套主题的「弱化描边」
            //   （深色 #222222 / 浅色 #DFE1E8），与各面板改前用的同一个角色。
            side: BorderSide(
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
            padding: margin ?? EdgeInsets.zero,
            child: GestureDetector(
              // 卡片内部的点击不能穿透到背景（否则点滑块也会关掉面板）
              onTap: () {},
              child: motion ? OverlayCardMotion(child: card) : card,
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
