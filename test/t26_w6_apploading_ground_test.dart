// T26-W6 / CR #11 回归：转圈颜色按**实际底色**取，不按主题明暗
//
// ★ 缺陷（CodeRabbit 未解决线程 #11，path=lib/ui/widgets/app_loading.dart line=140）：
//   转圈颜色原来只看 `Theme.of(context).brightness`，不看组件背后那块**实际底色**。
//   `lib/ui/player_page.dart` 的 `_LoadingOverlay` 固定 `Colors.black54` 作底、
//   下面还是视频黑底 —— 与用户选的主题**无关**；切到浅色主题打开播放页，
//   `isDark == false` ⇒ 选 `onSurfaceVariant`(#70727A) ⇒ 灰圈灰字压在近黑底上。
//   实测读数 (112,114,122) —— 逐位吻合，正是 Owner 报的「太浅」。
//
// # 这个文件钉住什么
// ```text
// 1. 渲染级：同一段代码，在**浅色主题**下挂到黑遮罩里，转圈像素必须是 ≈ #FAFAFA
//    —— 修复前是 (112,114,122)，修复后是 (250,250,250)。
// 2. 与主题解耦：同一段代码在深色主题下读数**完全一样**（底色决定，不是主题决定）。
// 3. 反方向也对：浅色底（白卡）+ 深色主题 ⇒ 取「浅底档」，不是无脑 #FAFAFA。
// 4. 优先级：显式 `ground:` 压过祖先 ColoredBox；两者都没有才回落主题明暗。
// 5. 源码门禁：播放页只差**一行** ——
//    · `_LoadingOverlay` **一个字都不用改**：它的 `ColoredBox(color: Colors.black54)`
//      就是祖先链上的那块底，走 ② 自动命中；
//    · 缓冲指示那一处**必须显式声明** `ground: Colors.black` —— 它的底色是
//      `Video(fill: Colors.black)` 画的，**不是 widget**，祖先探测拿不到。
// ```
//
// ⚠ 像素读数怎么来的（为什么不是 golden 文件）：
//   golden 依赖平台字体与栅格化，本仓没有 golden 基线；而这里要证的是一件事 ——
//   「半透明前景色压在某块底上，合成出来的那个像素是多少」。
//   那就是 Flutter 自己的 `Color.alphaBlend` 公式，算出来与截屏读数**逐位一致**，
//   且不需要任何外部基线文件。所以本文件把「读数」直接算出来当断言。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_loading.dart';

/// 生产里「深底档」前景色（= AppPalette.dark.foreground）
const Color kOnDark = Color(0xFFFAFAFA);

/// 把共享组件挂到真实主题里渲染
///
/// ⚠ 必须自己套 [Directionality]：`AppThemeHost` 只注入 ThemeData，
///   生产里这层是 MaterialApp 给的（同 test/zz_cr_loading_style_test.dart:41-47）。
Widget _host(Widget child, Brightness b) => Directionality(
      textDirection: TextDirection.ltr,
      child: AppThemeHost(
        data: AppTheme.themeFor(b),
        child: Center(child: child),
      ),
    );

CircularProgressIndicator _ring(WidgetTester tester) => tester
    .widget<CircularProgressIndicator>(
        find.byType(CircularProgressIndicator));

/// ★ 像素读数：把前景色（可能半透明）压到 [bg] 上合成出的那个像素
///
/// 用整数三元组而不是 [Color]，是为了让断言的**字面量**就等于屏幕上读到的值
/// —— `(112, 114, 122)` 这种读数可以直接贴进失败信息里。
(int, int, int) _pixel(Color fg, Color bg) {
  final a = fg.a;
  int ch(double f, double b) => ((f * a + b * (1 - a)) * 255).round();
  return (ch(fg.r, bg.r), ch(fg.g, bg.g), ch(fg.b, bg.b));
}

/// 播放页遮罩的真实形状：`Colors.black54` 压在视频黑底上
const Color kMaskOverBlack = Color(0xFF000000);

/// 剥掉注释，只留代码 —— 源码门禁不能在注释里被「自我实现」
String _stripComments(String s) => s
    .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

void main() {
  group('T26-W6 · 转圈颜色按底色取（CR #11）', () {
    testWidgets('浅色主题 + 黑遮罩：转圈像素 = (250,250,250)，不再是 (112,114,122)',
        (tester) async {
      // 播放页 _LoadingOverlay 的**逐字**形状：黑54 遮罩 + 居中 + 带文案
      await tester.pumpWidget(_host(
        const ColoredBox(
          color: Colors.black54,
          child: Center(child: AppLoading(label: '正在加载…')),
        ),
        Brightness.light,
      ));

      final c = _ring(tester).color!;
      expect(c, kOnDark, reason: '浅色主题下压在黑遮罩上的转圈必须是深底档 #FAFAFA');

      // ★ 读数：修复前 (112,114,122)（= #70727A 原样），修复后 (250,250,250)
      final px = _pixel(c, kMaskOverBlack);
      expect(px, (250, 250, 250), reason: '像素读数应为 ≈ #FAFAFA');
      expect(px, isNot((112, 114, 122)), reason: '这就是修复前的灰色读数');

      // 文案与转圈同一档（整块 loading 色调一致）
      final label = tester.widget<Text>(find.text('正在加载…'));
      expect(label.style!.color, c);
    });

    testWidgets('与主题解耦：同一段代码在深色主题下读数一模一样', (tester) async {
      await tester.pumpWidget(_host(
        const ColoredBox(
          color: Colors.black54,
          child: Center(child: AppLoading()),
        ),
        Brightness.dark,
      ));
      expect(_pixel(_ring(tester).color!, kMaskOverBlack), (250, 250, 250));
    });

    testWidgets('反方向：深色主题 + 白卡 ⇒ 取浅底档，不是无脑 #FAFAFA', (tester) async {
      final theme = AppTheme.themeFor(Brightness.dark);
      await tester.pumpWidget(_host(
        const ColoredBox(
          color: Colors.white,
          child: Center(child: AppLoading()),
        ),
        Brightness.dark,
      ));
      expect(_ring(tester).color, theme.colorScheme.onSurfaceVariant);
    });

    testWidgets('优先级：显式 ground 压过祖先 ColoredBox', (tester) async {
      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(_host(
        const ColoredBox(
          color: Colors.black54,
          child: Center(child: AppLoading(ground: Colors.white)),
        ),
        Brightness.light,
      ));
      expect(_ring(tester).color, theme.colorScheme.onSurfaceVariant,
          reason: '调用方显式声明了浅底，就不该再按祖先那块黑遮罩判');
    });

    testWidgets('透明色块**不算**底色（路由转场那层 ColoredBox(transparent) 不是底）',
        (tester) async {
      // theme_bridge.dart:85-104 把路由转场设成透明，那层 ColoredBox 挂在整条路由外面
      // ⇒ 页面里每个 AppLoading 都是它的子孙。它什么都不遮，不能当底。
      final light = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(_host(
        const ColoredBox(
          color: Colors.transparent,
          child: Center(child: AppLoading()),
        ),
        Brightness.light,
      ));
      expect(_ring(tester).color, light.colorScheme.onSurfaceVariant,
          reason: '透明祖先不是底 ⇒ 必须回落主题明暗（浅色主题 ⇒ 深色一档）');

      // 显式传 transparent 同样不算声明
      await tester.pumpWidget(_host(
        const AppLoading(ground: Colors.transparent),
        Brightness.light,
      ));
      expect(_ring(tester).color, light.colorScheme.onSurfaceVariant);
    });

    testWidgets('没有底色声明时回落主题明暗（OPS-14 原行为不变）', (tester) async {
      final light = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(_host(const AppLoading(), Brightness.light));
      expect(_ring(tester).color, light.colorScheme.onSurfaceVariant);

      await tester.pumpWidget(_host(const AppLoading(), Brightness.dark));
      expect(_ring(tester).color!.computeLuminance(), greaterThan(0.5),
          reason: '深色主题 + 无底色声明 ⇒ 仍是深底档');
    });
  });

  group('T26-W6 · 源码门禁：播放页的底色声明', () {
    final player = _stripComments(
        File('lib/ui/player_page.dart').readAsStringSync());

    test('_LoadingOverlay 仍是「黑54 ColoredBox + AppLoading」—— 它靠祖先探测修好，零改动',
        () {
      final m = RegExp(r'class _LoadingOverlay\b.*?\n\}', dotAll: true)
          .firstMatch(player);
      expect(m, isNotNull, reason: '播放页遮罩类不见了，这条门禁要重写');
      final body = m!.group(0)!;
      expect(body.contains('ColoredBox'), isTrue);
      expect(body.contains('Colors.black54'), isTrue);
      expect(body.contains('AppLoading'), isTrue);
    });

    test('缓冲指示底下那层黑是 `Video(fill: Colors.black)` 画的（所以探不到）', () {
      expect(player.contains('fill: Colors.black'), isTrue,
          reason: '视频层黑底是缓冲指示的底色来源；它没了，这条门禁要重写');
    });
    test('缓冲指示**显式声明**了黑底 —— 它没有 ColoredBox 祖先，探测不到',
        () {
      // 视频黑底是 `Video(fill: Colors.black)` 画的，**不是 widget**，
      // 祖先探测拿不到 ⇒ 这一处只能由调用方声明。
      final ok = RegExp(
        r'_buffering && !_loading\)[\s\S]{0,120}?AppLoading\(ground: Colors\.black\)',
      ).hasMatch(player);
      expect(ok, isTrue,
          reason: '缓冲指示没声明黑底 ⇒ 浅色主题下它会退回 #70727A 灰圈压黑底');
    });
  });
}
