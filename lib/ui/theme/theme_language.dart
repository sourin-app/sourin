// ═══════════════════════════════════════════════════════════════════════
//  设计语言层 —— 把主题包里的「形状 / 边缘 / 控件手感」接到 ThemeData 上
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要单独一层（2026-10-16 · Owner 第 14 条）
//
// Owner 原话：
// ```text
// > 项目配置了 open design，你自己设计几套 ui，三套吧最少，
// >   要完全不同风格的，我明天验收
// > 不要用谷歌那个 material 那个啥设计规范了，好难看啊
// ```
//
// 「完全不同风格」靠**只换配色**做不到 —— 本仓原来那 6 套内置主题就是
// 只换颜色的，用户在设置页扫过去会觉得"都是同一个 App 的皮肤"：
// ```text
// 午夜 / 日间 / OLED 纯黑 / 深海蓝 / 樱粉 / 森绿   ← 全部圆角 10、描边 1px、
//                                                    按钮内边距一模一样
// ```
// 而**直角 vs 胶囊**的差别比配色大得多：同一套颜色，圆角 0 + 2.5px 硬边
// 读起来是"海报 / 印刷品"，圆角 22 + 1px 细线读起来是"浮起来的玻璃"。
//
// ⇒ 于是 `ThemePack` 上有四个**设计语言**维度，本文件负责把它们落到
//   `ThemeData` 的每一个相关组件上：
//   ```text
//   radius            圆角（形状语言）
//   borderWidth       描边粗细（边缘语言）
//   dividerThickness  分隔线粗细（排版语言）
//   buttonPadding     按钮内边距（控件手感）
//   ```
//
// # 为什么要从 `theme_bridge.dart` 里抽出来
//
// 那段逻辑原来内联在 `buildAppTheme` 里，且**只管 radius**。
// 抽出来有两个好处：
// ```text
// ① 四件事是**同一个概念**（设计语言），散在两处必然改一处漏一处
// ② theme_bridge 是"角色补全"（哪个 Material 角色填什么色），
//    本文件是"形状/边缘/手感"—— 两件事分开，各自可测
// ```
//
// # ★ 默认零变化（这一条是硬约束）
//
// `pack == null`（用户没选主题包，只走明暗三态）或四个字段全 null 时，
// [ThemeLanguage.apply] **原样返回**传入的 ThemeData —— 既有 6 套主题与
// "跟随系统"路径的渲染结果**逐像素不变**。这不是优化，是回归纪律：
// 本仓的 `theme_invariants_test.dart` 逐值断言明暗两套的形状/尺寸一致。

import 'package:material_ui/material_ui.dart';

import 'theme_pack.dart';

/// 组件默认圆角（= 移除 forui 前的读数，见 `theme_bridge.dart` 的 `_defaultRadius`）
///
/// ⚠️ 与 `theme_bridge._defaultRadius` **必须同值**。这里是公开常量，
///    theme_bridge 那边应当改成引用本常量，避免两个真源。
const double kDefaultRadius = 10.0;

/// 组件默认描边粗细
const double kDefaultBorderWidth = 1.0;

/// 组件默认分隔线粗细
const double kDefaultDividerThickness = 1.0;

/// 一份主题包解析出来的**设计语言**
///
/// 四个维度都已经**归一**过（null 变成默认值），所以消费方不需要再判空。
@immutable
class ThemeLanguage {
  const ThemeLanguage({
    required this.radius,
    required this.borderWidth,
    required this.dividerThickness,
    required this.buttonPadding,
  });

  /// 从主题包解析。`pack == null` ⇒ 全默认（= 改前行为）
  factory ThemeLanguage.of(ThemePack? pack) => ThemeLanguage(
        radius: pack?.radius ?? kDefaultRadius,
        borderWidth: pack?.borderWidth ?? kDefaultBorderWidth,
        dividerThickness:
            pack?.dividerThickness ?? kDefaultDividerThickness,
        // ⚠️ 默认值必须与 `theme_bridge._shared` 里那档**逐值相同**，
        //    否则"没写 buttonPadding 的主题包"会静默换一套按钮内边距。
        buttonPadding:
            pack?.buttonPadding ??
            const EdgeInsets.symmetric(horizontal: 10, vertical: 11),
      );

  final double radius;
  final double borderWidth;
  final double dividerThickness;
  final EdgeInsets buttonPadding;

  /// 是否**完全等于默认**（= 不需要碰 ThemeData）
  ///
  /// ★ 判据用「与默认值相等」而不是「字段是不是 null」：
  ///   用户完全可以在 JSON 里显式写 `"radius": 10`（= 默认值），
  ///   那种情况下也**不该**重建一遍组件主题（重建会丢掉 `shape` 上
  ///   原有的 `side`，是实打实的观感差异）。
  bool get isDefault =>
      radius == kDefaultRadius &&
      borderWidth == kDefaultBorderWidth &&
      dividerThickness == kDefaultDividerThickness &&
      buttonPadding ==
          const EdgeInsets.symmetric(horizontal: 10, vertical: 11);

  BorderRadius get borderRadius => BorderRadius.all(Radius.circular(radius));

  /// 把设计语言落到一套 ThemeData 上
  ///
  /// 覆盖范围（逐项都有理由，不是"能改的都改"）：
  /// ```text
  /// card / dialog / bottomSheet / snackBar / listTile / chip
  ///        → 圆角 + 描边粗细（这些是"面"，形状语言最明显的地方）
  /// 四类按钮 → 圆角 + 内边距（控件手感）
  /// 输入框   → 圆角 + 四态描边粗细
  /// 分隔线   → 粗细
  /// ```
  ///
  /// ⚠️ 描边粗细**不能**简单地 `BorderSide(width: w)` 覆盖 —— 必须保留
  ///    原来那一笔的 `color`。本仓的卡片描边颜色来自主题角色
  ///    （`theme_bridge` 里逐个填过），覆盖掉颜色 = 描边变黑/变透明。
  static ThemeData apply(ThemeData td, ThemePack? pack) {
    final lang = ThemeLanguage.of(pack);
    if (lang.isDefault) return td;

    final radius = lang.borderRadius;
    final shape = WidgetStateProperty.all(
      RoundedSuperellipseBorder(borderRadius: radius),
    );

    /// 保留原描边颜色，只换粗细
    ///
    /// ══════════════════════════════════════════════════════════════════
    /// ★★★ CR/PR#30-①（2026-10-17）：`BorderSide.none` **不能**变成实线
    /// ══════════════════════════════════════════════════════════════════
    ///
    /// 改前这里只写了 `BorderSide(color: s.color, width: lang.borderWidth)` ——
    /// 而 `BorderSide` 构造函数的 `style` **默认是 `BorderStyle.solid`**
    /// （`flutter/lib/src/painting/borders.dart:72`），于是一笔
    /// `BorderSide.none`（= `width:0, style:none`）会被变成
    /// `BorderSide(color: 黑, width: 2.5, style: solid)`：
    /// **原本没有边的面凭空多出一条 1~2.5px 的黑色实线。**
    ///
    /// 实测（`.probe/probe_tests/zz_t14cr_repro_test.dart`）：
    /// ```text
    /// [CR1a] base dialog   style=none w=0.0     ← theme_bridge 的 _shape() 默认无边
    /// [CR1b] dialog before style=none  →  after style=solid w=1.0 color=ff000000
    /// [CR1a] thicken(none) 模拟 -> style=solid w=2.5 color=ff000000
    /// ```
    /// 「面」那一组里只有 card 在 theme_bridge 里有真描边，其余
    /// dialog / bottomSheet / snackBar / listTile / chip **全是 none** ⇒ 全中招。
    ///
    /// ⇒ 判据分两档，与 `BorderStyle` 的语义对齐：
    /// ```text
    /// ① style == BorderStyle.none（或 width == 0）⇒ **原样返回**，不造边
    /// ② 否则 ⇒ 只换 width，**显式带上 style**（不靠构造函数默认值）
    /// ```
    /// 第 ② 档要显式写 `style: s.style` 也是必要的：将来若有人给某个面配了
    /// solid 之外的值，这里不能又悄悄把它压回 solid。
    BorderSide thicken(BorderSide s) {
      // ① 原本无描边 ⇒ 保持无描边（判据与 CSS 的 border-width:0 一致）
      // ① 原本无描边 ⇒ 保持无描边（判据与 CSS 的 border-width:0 一致）
      if (s.style == BorderStyle.none || s.width == 0) return s;
      // ② 有描边 ⇒ 只改粗细，颜色与 style 都沿用原值
      return BorderSide(
        color: s.color,
        width: lang.borderWidth,
        style: s.style,
      );
    }

    /// 从任意 shape 里安全取出它当前的描边（取不到就当没有描边）
    BorderSide sideOf(ShapeBorder? s) =>
        s is OutlinedBorder ? s.side : BorderSide.none;

    RoundedSuperellipseBorder face(ShapeBorder? s) =>
        RoundedSuperellipseBorder(
          borderRadius: radius,
          side: thicken(sideOf(s)),
        );

    // ══════════════════════════════════════════════════════════════════
    // ★★★ CR/PR#30-②（2026-10-17）：一律 `copyWith(shape:)`，不得整体替换
    // ══════════════════════════════════════════════════════════════════
    //
    // 改前 dialog / bottomSheet / listTile 三处写的是**新建**：
    // ```dart
    // dialogTheme: DialogThemeData(shape: face(...)),        // ← 丢了 backgroundColor、
    // bottomSheetTheme: BottomSheetThemeData(shape: ...),    //    titleTextStyle、
    // listTileTheme: ListTileThemeData(shape: ...),          //    dragHandleColor、iconColor…
    // ```
    // `XxxThemeData(shape: x)` 的**其余字段全是 null** ⇒ 凡是 theme_bridge
    // 填过的非 shape 字段（背景色、文字样式、拖拽柄颜色、图标色…）**一律被清空**，
    // 回退到 Material 默认值。实测（同一探针）：
    // ```text
    // [CR2] dialog bg        before=Color(0xff123456) after=null
    // [CR2] dialog elevation before=7.0               after=null
    // [CR2] dialog title     before=33.0              after=null
    // [CR2] sheet dragHandle before=Color(0xffaabbcc) after=null
    // [CR2] listTile icon    before=Color(0xff00ff00) after=null
    // [CR2] listTile pad     before=EdgeInsets.all(9.0) after=null
    // ```
    // 这与文件头那条「只换形状」的约定**直接矛盾** —— 约定没被代码守住。
    //
    // ⇒ 三处统一改成 `td.xxxTheme.copyWith(shape: ...)`，与 card / snackBar /
    //   chip 完全一致（本来就是对的写法）。这样非 shape 字段**逐字段原样保留**。
    return td.copyWith(
      cardTheme: td.cardTheme.copyWith(shape: face(td.cardTheme.shape)),
      dialogTheme: td.dialogTheme.copyWith(shape: face(td.dialogTheme.shape)),
      bottomSheetTheme: td.bottomSheetTheme
          .copyWith(shape: face(td.bottomSheetTheme.shape)),
      snackBarTheme:
          td.snackBarTheme.copyWith(shape: face(td.snackBarTheme.shape)),
      listTileTheme:
          td.listTileTheme.copyWith(shape: face(td.listTileTheme.shape)),
      chipTheme: td.chipTheme.copyWith(shape: face(td.chipTheme.shape)),

      // ── 四类按钮：圆角 + 内边距 ──
      filledButtonTheme: FilledButtonThemeData(
        style: td.filledButtonTheme.style?.copyWith(
          shape: shape,
          padding: WidgetStateProperty.all(lang.buttonPadding),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: td.elevatedButtonTheme.style?.copyWith(
          shape: shape,
          padding: WidgetStateProperty.all(lang.buttonPadding),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: td.outlinedButtonTheme.style?.copyWith(
          shape: shape,
          padding: WidgetStateProperty.all(lang.buttonPadding),
          // 描边按钮的边是它唯一的"体"，必须跟着 borderWidth 走，
          // 否则新粗野主义里"卡片 2.5px、按钮 1px"会显得没做完。
          side: WidgetStateProperty.all(
            thicken(
              (td.outlinedButtonTheme.style?.side?.resolve(<WidgetState>{}) ??
                      const BorderSide())
                  .copyWith(width: lang.borderWidth),
            ),
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: td.textButtonTheme.style?.copyWith(
          shape: shape,
          padding: WidgetStateProperty.all(lang.buttonPadding),
        ),
      ),

      // ── 输入框：圆角 + 四态描边粗细 ──
      inputDecorationTheme: td.inputDecorationTheme.copyWith(
        border: _inputBorder(td.inputDecorationTheme.border, radius, lang),
        enabledBorder: _inputBorder(
            td.inputDecorationTheme.enabledBorder, radius, lang),
        focusedBorder: _inputBorder(
            td.inputDecorationTheme.focusedBorder, radius, lang),
        errorBorder:
            _inputBorder(td.inputDecorationTheme.errorBorder, radius, lang),
        focusedErrorBorder: _inputBorder(
            td.inputDecorationTheme.focusedErrorBorder, radius, lang),
        disabledBorder: _inputBorder(
            td.inputDecorationTheme.disabledBorder, radius, lang),
      ),

      // ── 分隔线：粗细（颜色仍是主题角色给的，不动）──
      dividerTheme: td.dividerTheme.copyWith(
        thickness: lang.dividerThickness,
      ),
    );
  }

  /// 输入框的描边是 `InputBorder`（可能是 `WidgetStateInputBorder`），
  /// 逐个具体类型处理；认不出来的一律**原样返回**（宁可不动，也不要
  /// 把它降级成别的类型 —— `WidgetStateInputBorder` 丢掉就会失去四态）。
  static InputBorder? _inputBorder(
    InputBorder? src,
    BorderRadius radius,
    ThemeLanguage lang,
  ) {
    if (src == null) return null;
    if (src is OutlineInputBorder) {
      return src.copyWith(
        borderRadius: radius,
        borderSide: BorderSide(
          color: src.borderSide.color,
          width: lang.borderWidth,
        ),
      );
    }
    if (src is UnderlineInputBorder) {
      return src.copyWith(
        borderRadius: radius,
        borderSide: BorderSide(
          color: src.borderSide.color,
          width: lang.borderWidth,
        ),
      );
    }
    // `WidgetStateInputBorder`：Material 用它做"按状态解析"的边框。
    // ⚠️ 这里刻意**不动**它 —— 它的 `resolve` 逻辑在框架内部，
    //    外层再包一层解析器会把四态压成一态（输入框失去聚焦反馈）。
    //    代价：显式给主题包配了 borderWidth 时，输入框仍用原粗细；
    //    这是"宁可少改一处，不要改坏一处"的取舍，已在文档里写明。
    return src;
  }
}
