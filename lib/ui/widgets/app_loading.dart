// ═══════════════════════════════════════════════════════════════════════
//  共享 loading —— 页级 / 遮罩级的粗体转圈（★ OPS-14，2026-10-10）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个组件是为了**修一个真缺陷**而存在的
//
// Owner 原话（逐字）：
//   「还有这个loading样式,那个转圈的颜色太浅了,然后这个圆圈是不是有点大?
//     我感觉这个效果不太好 优化一下」
//
// ```text
// 改前（player 两处）：
//   _LoadingOverlay  CircularProgressIndicator(color: Colors.white)
//                    —— 没给 size/strokeWidth ⇒ Material 默认 4px 描边、
//                       约束到 40×40；再叠一层 Colors.black54 底
//   缓冲指示         SizedBox(44×44) + 同一个白转圈
// ```
//
// **两个症状各有各的根因，必须分开治**：
//   ① 「太大」= 没人给尺寸，落到 Material 默认的 40，或手写的 44。
//   ② 「太浅」= Colors.white 压在 Colors.black54 上 —— 白本身亮度最高，
//      但 54% 黑压下来之后剩下的仍是**没有层次的白**；
//      而且描边 4px 在 40px 的圈上只占 10%，远看就是一根**灰白发丝**。
// ⇒ 所以尺寸与描边在这里**各自成为常量**，不再由各调用点各写一遍。
//
// # ★ 为什么不做「弧线缺口 / 呼吸感」那类自定义动画
// ```text
// 任务书第 5 条明确要求：保持 Material 风格即可，不为炫技重写动画。
// 理由也站在 Material 这边 —— 发丝感的真正成因是**描边太细**（4px @40px），
// 而不是「画法不够花」；把描边提到 2.8、圈收到 30，感知上的「实」就回来了。
// ⇒ 保留 CircularProgressIndicator 本身，只改它的**尺寸 / 描边 / 颜色**。
// ```
//
// # 颜色怎么选（这是最需要解释的一处）
// ```text
// 任务书要求：深底用主题主色或明确的白色，浅底用 onSurfaceVariant。
// 
// ⚠ **不能直接用 colorScheme.primary** —— 本仓两套主色都恰好是中性色：
//    深色板 AppPalette.dark.primary  = #E5E5E5（浅灰！）
//    浅色板 AppPalette.light.primary = #171717（近黑）
//    theme_bridge.dart:403-407 的 progressIndicatorTheme 用的正是它
//    ⇒ 那正是「转圈发灰」的另一条来源。
// ⇒ 所以这里显式取语义角色，不用 primary：
//    深底 → palette.foreground（深色板 = #FAFAFA，亮度 ~0.95，与 #0A0A0A 底差 ~0.95）
//    浅底 → theme.colorScheme.onSurfaceVariant（= LightTokens.textSecondary #70727A）
// ```
//
// # ★★★ 底色优先于主题（CR #11 / T26-W6，2026-10-11 —— 这才是「太浅」的真根因）
// ```text
// 上面那套「深底 / 浅底」原来判的是 **theme.brightness**（主题明暗），
// 不是组件**背后那块底色**。两者在播放页上恰好相反：
//   lib/ui/player_page.dart 的 _LoadingOverlay 固定 Colors.black54 作底
//   （下面还是视频黑底），与主题无关；用户切到**浅色主题**打开播放页
//   ⇒ isDark == false ⇒ 选 onSurfaceVariant(#70727A)
//   ⇒ 灰圈灰字叠在近黑底上 —— 实测读数 (112,114,122)，逐位吻合。
//
// ⇒ 现在「背后那块实际底色」按**三级优先**取，取到谁就按谁选前景色：
//   ① 调用方显式声明的 `ground:`
//   ② 祖先链上最近的 ColoredBox —— 播放页 _LoadingOverlay 正是这个形状
//      （player_page.dart:12539-12543 的 ColoredBox(color: Colors.black54)
//       正压在 AppLoading 头上）⇒ **那处一个字都不用改**就修好了
//      ⚠ 但**缓冲指示**那处探不到：它的黑底是 `Video(fill: Colors.black)`
//        画的（player_page.dart:11174-11178），不是 widget ⇒ 那里显式声明
//        `ground: Colors.black`（player_page.dart:11401）。
//   ③ 都没有 ⇒ 回落 theme.brightness（= OPS-14 原行为，逐字不变）
//   ⚠ 全透明色块（含本仓路由转场那层）不算「底」，见 `_declaresGround`。
//   判据是 Material 自己的 ThemeData.estimateBrightnessForColor（亮度 > 0.15 = 浅底），
//   所以半透明的 black54 照样判成深底。
//   深底 → #FAFAFA；浅底 → onSurfaceVariant（#70727A），与 ③ 的浅底分支同一档。
// ⚠️ 深底那一支在浅色主题下**不能**取 palette.foreground：
//    浅色板的 foreground 是近黑（#0A0A0A；实际生效的浅色板是 #1E2028），
//    那是「浅底上的字」的颜色，压到黑底上等于隐形。
// ```
//
// ⚠ 为什么深底那一支**不**用纯白：
//    白色没有方向感，贴在纯黑遮罩上缺少对比层次，这正是「太浅」的手感来源。
//    foreground（#FAFAFA）带一点暖灰，与 #0A0A0A 拉开亮度差、又不同于死白。
//    ★ AppPalette.of 在祖先没有注入扩展时按 brightness 兜底
//      （app_palette.dart:137-148），所以本组件**不依赖 MaterialApp** 也不会崩。
//
// # 已统一到这里的调用点
// ```text
//   OPS-14 那批（任务书第 3 条列出的 6 处）
//   lib/ui/player_page.dart              _LoadingOverlay（遮罩）+ 缓冲指示
//   lib/ui/cache_page.dart:1164          下载页整页 loading
//   lib/ui/settings_page.dart:1796       设置页整页 loading
//   lib/ui/detail_page.dart:2366         详情页 loading
//   lib/ui/settings/about_page.dart:391  关于页按钮 busy

//   T20 · D 行收口（2026-10-11）新增 5 处，判据是「整块区域等一件事」：
//   lib/ui/cast/cast_device_sheet.dart      投屏弹窗的扫描空态
//   lib/ui/widgets/live_embedded_player.dart  _EmbedLoading（画布整块等待）
//   lib/ui/widgets/provider_login_panel.dart  200×200 二维码空态
//   lib/ui/widgets/skip_marker_dialog.dart    _loading 时的弹窗内容空态
//   lib/ui/widgets/skip_marker_dialog.dart    预览框上的 _loadingHint 转圈
// ```
// ★ 剩下 14 处是**按钮内 / 小控件内**的忙指示（12~20px，底色不确定），
//   保持原样 —— 但它们在 test/zz_cr_loading_style_test.dart 的 T20 组里
//   **显式登记豁免**，且那条断言会反过来查「豁免条目是否仍然真的是裸转圈」，
//   「点改完了、名单没删」这种假绿挡得住。
// ⚠ 本文件**没有**直接 import Flutter 的 material 库（lib/ 全仓禁，
//    见 test/theme_regression_test.dart 的全 lib 文本扫描）——
//    上面只 import 本仓 material_ui（它已 re-export Flutter 的 widgets）。

import 'package:material_ui/material_ui.dart';

import '../app_palette.dart';
import '../tokens.dart';

/// loading 的**唯一**尺寸 / 描边真源
///
/// # 30 / 2.8 是怎么定的（任务书要求 28~30、描边 2.5~3）
/// ```text
/// 直径 30：在 40px 默认值上收 25%。再小则旋转弧线在小屏上糊成一点，
///           实测 24 以下「转」这个动作基本看不出来。
/// 描边 2.8：占直径 9.3%（改前 4/40 = 10%，比例看似一样，
///           但绝对值差 1.2px —— 细描边在高 DPI 上被抗锯齿吃掉半个像素，
///           这就是「发丝」的来源）。
/// ★ 两者是**同一个视觉决策**，不要只调其中一个：
///   只收尺寸不改描边 ⇒ 比例不变，看起来仍是原来那个圈；
///   只加描边不收尺寸 ⇒ 变成一个「粗白环」，在小方块里会撑爆容器。
/// ```
abstract final class AppLoadingSize {
  /// 外圈直径（浅色档同样是它）
  static const double diameter = 30;

  /// 描边宽度 —— **必须 >= 2.5**，见上
  static const double stroke = 2.8;
}

/// 「这个颜色算不算一块**底色**」—— 全透明的不算
///
/// ⚠️ 必须挡住 `Colors.transparent`：本仓的路由转场被**有意**设成透明
///    （theme_bridge.dart:85-104 的 `SourinPageTransitionsBuilder`，
///     为的是不让离场页被那层 scrim 盖住）。那层 `ColoredBox` 挂在
///    **整条路由**外面 ⇒ 页面里任何一个 AppLoading 都是它的子孙。
///    拿它当底 ⇒ 亮度 0 ⇒ 判成深底 ⇒ 浅色页面上画一个 #FAFAFA 的白圈，
///    **隐形**。它不是「底」：它什么都不遮。
bool _declaresGround(Color? c) => c != null && c.a > 0;

/// 沿祖先链找**最近的那块纯色底**（[ColoredBox]）
///
/// 只认 [ColoredBox] —— 它是 Flutter 里「纯色底」的规范表达，
/// `Container(color:)` / `ModalBarrier` 最终都落到它上面，面小、可预测。
/// 其它形式（[DecoratedBox] / 自绘 / 图片 / 视频帧）探不到，
/// 那正是 [AppLoading.ground] 存在的意义：让调用方把话说清楚。
///
/// ⚠️ 探测**不改变**默认行为：一个 ColoredBox 祖先都没有时返回 null，
///    调用方照旧走主题明暗 —— 所以 OPS-14 的既有门禁不受影响。
Color? _groundFromAncestors(BuildContext context) {
  final c = context.findAncestorWidgetOfExactType<ColoredBox>()?.color;
  return _declaresGround(c) ? c : null;
}

/// 「压在深底上一定看得清」的那一档前景色
///
/// ⚠️ 这一档**故意写死**，不走 `AppPalette.foreground`：
///    浅色板的 foreground 是「浅底上的字」的颜色（近黑），
///    深底这一档必须与主题明暗**解耦**，否则又回到 CR #11 那个坑。
/// 取值与 `AppPalette.dark.foreground` 一致（#FAFAFA，亮度 0.957）。
abstract final class _ReadableOn {
  /// 深底前景（= 深色板 `AppPalette.dark.foreground`）
  static const Color dark = Color(0xFFFAFAFA);
}

/// 共享 loading —— 页级 / 遮罩级的粗体转圈
///
/// # 三种用法
/// ```dart
/// // ① 纯转圈（居中交给调用方）
/// const Center(child: AppLoading())
///
/// // ② 转圈 + 文案（文案颜色跟着调色板走，**不用纯白**）
/// const AppLoading(label: '正在加载…')
///
/// // ③ ★ 压在**与主题无关**的底色上时，必须声明那块底色（见 [ground]）
/// const ColoredBox(
///   color: Colors.black54,
///   child: Center(child: AppLoading(label: '正在加载…', ground: Colors.black54)),
/// )
/// ```
///
/// # 为什么 `size` 有默认值还不够、必须允许覆盖
/// ```text
/// 「关于」页的按钮内 busy 只有 40px 高的按钮位置（about_page.dart:388-392），
/// 那里用 [AppLoadingSize.diameter] = 30 会把 40px 高的按钮顶高，
/// 按钮**高度就跳了** ⇒ 必须在按钮内显式传小尺寸。
/// 这是「组件给默认、调用点能覆盖」而不是「一刀切写死」的直接理由。
/// ```
class AppLoading extends StatelessWidget {
  const AppLoading({
    this.label,
    this.size = AppLoadingSize.diameter,
    this.ground,
    super.key,
  });

  /// 转圈下方的可选文案（**保留**调用点原有的文字，不改语义）
  final String? label;

  /// 外圈直径 —— 默认 [AppLoadingSize.diameter]；按钮内请传小值
  final double size;

  /// ★ 组件**背后那块实际底色**的**显式声明**（可选，优先级最高）
  ///
  /// # 为什么「底色」必须压过「主题明暗」（CR #11 / T26-W6）
  /// ```text
  /// 播放页遮罩的底色是 Colors.black54、下面还是视频黑底 —— 与用户选的主题**无关**。
  /// 只按 theme.brightness 判 ⇒ 浅色主题下取到 #70727A 的灰圈压在近黑底上，
  /// 实测读数 (112,114,122) —— 正是 Owner 报的「太浅」。
  /// ```
  ///
  /// # 取色优先级（从高到低）
  /// ```text
  /// ① 本参数 ground  —— 调用方最清楚自己压在哪块底色上
  /// ② 祖先链上最近的 [ColoredBox] 的颜色
  ///    —— 播放页 _LoadingOverlay 就是这个形状（player_page.dart:12539-12543
  ///       的 ColoredBox(color: Colors.black54) 正压在 AppLoading 头上），
  ///       ⇒ 那两处**一个字都不用改**就自动修好了
  /// ③ 都没有 ⇒ 回落 theme.brightness（= OPS-14 原行为，逐字不变）
  /// ```
  ///
  /// # 什么时候要显式传
  /// ```text
  /// 底色不是 ColoredBox 写的（DecoratedBox / 自绘 / 图片 / 视频帧）时；
  /// 或者你要覆盖祖先链里那个**不是**背景的 ColoredBox 时。
  /// 深底 → ground: Colors.black54（或任何深色）；浅底 → ground: Colors.white。
  /// ```
  ///
  /// ⚠️ 判据是**底色自身的亮度**（[ThemeData.estimateBrightnessForColor]），
  ///    不是颜色的名字 —— 传半透明的 black54 照样判成深底。
  final Color? ground;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = AppPalette.of(context);

    // ★ 取色只认「背后那块底色」（CR #11 / T26-W6）：
    //   ① 调用方显式声明的 ground
    //   ② 祖先链上最近的 ColoredBox（播放页 _LoadingOverlay 就是这个形状，
    //      它一个字都没改就修好了）
    //   ③ 都没有才回落主题明暗（与 OPS-14 的行为**逐字一致**）
    final groundColor =
        _declaresGround(ground) ? ground : _groundFromAncestors(context);
    final onDark = groundColor != null
        ? ThemeData.estimateBrightnessForColor(groundColor) == Brightness.dark
        : theme.brightness == Brightness.dark;

    // 深底 → 深色板前景（#FAFAFA）；浅底 → onSurfaceVariant（#70727A）
    final Color color;
    if (!onDark) {
      color = theme.colorScheme.onSurfaceVariant;
    } else if (palette.brightness == Brightness.dark) {
      // 深色调色板的前景就是 #FAFAFA，且将来调令牌时两处一起变
      color = palette.foreground;
    } else {
      // ⚠️ 这里**不能**取 palette.foreground —— 浅色板的它是近黑
      //    （#0A0A0A / 实际生效的浅色板 #1E2028），压到黑遮罩上等于隐形。
      color = _ReadableOn.dark;
    }

    final indicator = SizedBox(
      width: size,
      height: size,
      child: CircularProgressIndicator(
        color: color,
        strokeWidth: AppLoadingSize.stroke,
      ),
    );

    if (label == null) return indicator;

    // ★ 文案**不用**纯白 —— 与转圈同一档，保证整块 loading 色调一致
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        indicator,
        const SizedBox(height: Sp.x3),
        Text(label!, style: TextStyle(color: color, fontSize: FontSizes.sm)),
      ],
    );
  }
}
