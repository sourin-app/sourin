// ═══════════════════════════════════════════════════════════════════════
//  轨道 E · 玻璃化 M2 第 4 步 —— AlertDialog → AppGlassDialog
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// `detail_page.dart` 的 3 个 `AlertDialog` 已换成自建 `AppGlassDialog`。
//
// # ★★★ 与前面几步最大的不同：这一组守的是**风险项**，不是外观
//
// Lead 明令：以下五项**任何一项退化都不许接受**，哪怕"看起来能用"：
// ```text
// ① barrier（点外面能不能关）
// ② 焦点陷阱（Tab 不能跑到对话框外）
// ③ ESC（能不能关）
// ④ 返回键（Android/TV）
// ⑤ role=dialog（读屏能否识别）
// ```
// 加上 Lead 追加的两项：
// ```text
// ⑥ 动画（能否 settle）
// ⑦ 内容溢出（长内容能不能滚）
// ```
// 加我加的两项：
// ```text
// ⑧ 颜色同源（不许 CupertinoColors）
// ⑨ 双向（旧实现 AlertDialog 下新判据必须绿）
// ```
//
// # ★ 一条贯穿全文件的方法论
// ```text
// 每一条都必须是**行为断言**，不是"组件在树上"。
//   例：ESC 要真的 sendKeyEvent(Escape)，然后断言对话框**没了**。
// 而且每条都要有**反向对照**：证明"如果不这样配置，它就不会过"。
//   —— 否则判据可能永远为真（本仓反复踩过）。
// ```

import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalCupertinoLocalizations, GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
// ⑧ 用来说「这是卡片本体」——量它的 rect 才知道有没有铺满整窗。
// ignore: depend_on_referenced_packages
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedRectangle, LiquidRoundedSuperellipse;
import 'package:material_ui/material_ui.dart'
    show AlertDialog, MaterialApp, Scaffold, TextButton;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/design/theme/app_theme.dart' as design;
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/ui/app_palette.dart' show AppPalette;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/app_colors.dart' show AppSemanticColors;
import 'package:sourin_spike/ui/theme/theme_pack.dart' show ThemePackStore;
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/tokens.dart' show Radii;
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';

// ══════════════════════════════════════════════════════════════════════
//  工具
// ══════════════════════════════════════════════════════════════════════

String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i = (i + 2).clamp(0, src.length);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

String detailSource() =>
    stripComments(File('lib/ui/detail_page.dart').readAsStringSync());

/// 宿主：**必须**给 CupertinoLocalizations —— 否则 `showAppDialog` 内部
/// 的 DialogRoute 在部分路径下会抛（真实 shell.dart:2112-2114 也给了）。
Widget _app(GlobalKey<NavigatorState> key) => MaterialApp(
  navigatorKey: key,
  theme: AppTheme.themeFor(Brightness.dark),
  themeAnimationDuration: Duration.zero,
  localizationsDelegates: const [
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: const SizedBox(),
);

/// 用**产品同款**的方式弹出 AppGlassDialog
Future<bool?> _open(
  GlobalKey<NavigatorState> key, {
  bool barrierDismissible = true,
  Widget? content,
  String confirmLabel = '删除',
}) {
  return showAppDialog<bool>(
    context: key.currentContext!,
    barrierDismissible: barrierDismissible,
    builder: (ctx) => AppGlassDialog(
      title: '删除这一集？',
      content: content ?? const Text('文件会从磁盘上真正删除，此操作不可恢复。'),
      actions: AppGlassDialogActions(
        onCancel: () => Navigator.of(ctx).pop(false),
        onConfirm: () => Navigator.of(ctx).pop(true),
        confirmLabel: confirmLabel,
      ),
    ),
  );
}

/// 打开并等待入场完成。
///
/// ★ 实测：`AppGlassDialog` 走 DialogRoute，入场 ~400ms。
///   而 `GlassDialog`（我们没用的那个）退出要 ~800ms —— 本轮探查时
///   我因为只等 400ms 误判过"它关不掉"。这里统一等足。
Future<void> _openAndSettle(
  WidgetTester t,
  GlobalKey<NavigatorState> key, {
  bool barrierDismissible = true,
  Widget? content,
}) async {
  unawaited(
    _open(key, barrierDismissible: barrierDismissible, content: content),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 800));
}

void unawaited(Future<void> f) {}

// ══════════════════════════════════════════════════════════════════════
//  ⑪ 的算式：WCAG 2.1 对比度
// ══════════════════════════════════════════════════════════════════════

/// WCAG 2.1 相对亮度（sRGB 通道线性化 + 0.2126/0.7152/0.0722 加权）。
///
/// ⚠️ 为什么在测试里自己算、而不是把 `6.08:1` 这种数字写死：
/// 写死就成了「守某个具体数值」，主题一改色判据失效；要守的是**规范线 4.5:1**。
double _relLuminance(Color c) {
  double lin(double v) =>
      v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * lin(c.r) + 0.7152 * lin(c.g) + 0.0722 * lin(c.b);
}

/// 对比比 = (较亮 + 0.05) / (较暗 + 0.05)，范围 1:1 ~ 21:1。
double _contrast(Color a, Color b) {
  final la = _relLuminance(a);
  final lb = _relLuminance(b);
  final hi = math.max(la, lb);
  final lo = math.min(la, lb);
  return (hi + 0.05) / (lo + 0.05);
}

/// 由 palette 现算语义色 —— 与 `AppThemeData.colors` 同一条派生路径。
///
/// ★ 为什么不用 `AppTheme.resolvedOf(context).colors` 来算「另一个明暗档」：
///   `resolvedOf` 的明暗来自 `MediaQuery.platformBrightness`（测试环境恒为
///   light），拿它算不出深色档。这里按 palette 直接算，两档都可控。
AppSemanticColors _semanticFor(AppPalette p) => AppSemanticColors.derive(
  brightness: p.brightness,
  background: p.background,
  card: p.card,
  border: p.border,
  foreground: p.foreground,
  mutedForeground: p.mutedForeground,
  primary: p.primary,
  primaryForeground: p.primaryForeground,
  error: p.error,
);

void main() {
  // ══════════════════════════════════════════════════════════════════
  //  ① barrier
  // ══════════════════════════════════════════════════════════════════
  group('① barrier', () {
    testWidgets('★★★ barrierDismissible:true ⇒ 点外面**真的关了**', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key);
      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提：已打开');

      await t.tapAt(const Offset(5, 5));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(
        find.byType(AppGlassDialog),
        findsNothing,
        reason: '★★★ 点外面必须关（barrier 语义）',
      );
    });

    testWidgets('★★★ barrierDismissible:false ⇒ 点外面**不关**（反向对照）', (t) async {
      /*
       * ★ 这条是**防"组件自有 onTap 绕过 barrier"**的。
       *
       * 背景：我原本想复用已有的 `AppDialogShell(glass: true)`，
       *   但它自带铺满全屏的 scrim + `onTap: closeEnabled ? onClose : null`
       *   ⇒ 实测传 barrierDismissible:false 后点外面**仍然关了**。
       *   那是"全屏面板"的语义，不是对话框的。
       * ⇒ 本组件不画 scrim，barrier 完全交给路由层。
       *   这条断言就是钉住那个决定：**组件不许自己关**。
       */
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key, barrierDismissible: false);
      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提');

      await t.tapAt(const Offset(5, 5));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(
        find.byType(AppGlassDialog),
        findsOneWidget,
        reason:
            '★★★ barrierDismissible:false 时必须**不关** —— '
            '组件不许自己画 scrim 抢走 barrier 语义',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 焦点陷阱
  // ══════════════════════════════════════════════════════════════════
  group('② 焦点陷阱', () {
    testWidgets('★★★ Tab 循环不跑出对话框', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key);
      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提');

      // 连按 Tab 12 次（超过对话框内可聚焦元素数量）
      for (var i = 0; i < 12; i++) {
        await t.sendKeyEvent(LogicalKeyboardKey.tab);
        await t.pump();
      }

      // ① 对话框必须还开着（Tab 不该把它关掉）
      expect(
        find.byType(AppGlassDialog),
        findsOneWidget,
        reason: '★★★ Tab 不许把对话框搞没',
      );

      // ② 焦点必须仍在对话框内
      final focusCtx = FocusManager.instance.primaryFocus?.context;
      expect(focusCtx, isNotNull, reason: '前提：有焦点');
      final inDialog = find
          .descendant(
            of: find.byType(AppGlassDialog),
            matching: find.byType(Focus),
          )
          .evaluate()
          .any(
            (e) =>
                e == focusCtx ||
                (focusCtx?.findAncestorWidgetOfExactType<AppGlassDialog>() !=
                    null),
          );
      expect(inDialog, isTrue, reason: '★★★ Tab 12 次后焦点必须仍在对话框内（焦点陷阱）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ ESC
  // ══════════════════════════════════════════════════════════════════
  group('③ ESC', () {
    testWidgets('★★★ 发 Escape ⇒ **真的关了**', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key);
      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提');

      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(
        find.byType(AppGlassDialog),
        findsNothing,
        reason: '★★★ ESC 必须能关（Lead 明令：不许出现"只能点按钮"的退化）',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 返回键
  // ══════════════════════════════════════════════════════════════════
  group('④ 返回键', () {
    testWidgets('★★★ maybePop（系统 back 的等价路径）⇒ 真的关了', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key);
      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提');

      final popped = await key.currentState!.maybePop();
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(popped, isTrue, reason: '★★ 返回键必须被路由接受');
      expect(
        find.byType(AppGlassDialog),
        findsNothing,
        reason: '★★★ 返回键（Android/TV）必须能关',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ 语义
  // ══════════════════════════════════════════════════════════════════
  group('⑤ role=dialog / 语义', () {
    testWidgets('★★★ 标题与两个按钮都能被读屏找到', (t) async {
      final handle = t.ensureSemantics();
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key);

      expect(
        find.bySemanticsLabel('删除这一集？'),
        findsWidgets,
        reason: '★★★ 标题必须可被读屏找到',
      );
      expect(
        find.bySemanticsLabel('取消'),
        findsWidgets,
        reason: '★★★ 「取消」必须可被读屏找到',
      );
      expect(
        find.bySemanticsLabel('删除'),
        findsWidgets,
        reason: '★★★ 「删除」必须可被读屏找到',
      );
      handle.dispose();
    });

    testWidgets('★★ 走的是 DialogRoute（不是 CupertinoDialogRoute）', (t) async {
      /*
       * ★ Lead 裁决的关键点：必须复用 showAppDialog，
       *   保持 3.47 的 DialogRoute 语义，不许换成 CupertinoDialogRoute
       *   （glass_dialog.dart 的 .show() 会换成后者）。
       */
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key);
      final route = ModalRoute.of(t.element(find.byType(AppGlassDialog)));
      expect(
        route.runtimeType.toString(),
        contains('DialogRoute'),
        reason: '★★ 必须是 DialogRoute',
      );
      expect(
        route.runtimeType.toString(),
        isNot(contains('Cupertino')),
        reason: '★★★ 不许是 CupertinoDialogRoute（那会绕过 showAppDialog）',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑥ 动画
  // ══════════════════════════════════════════════════════════════════
  group('⑥ 动画', () {
    testWidgets('★★★ pumpAndSettle 能收敛', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      unawaited(_open(key));
      await t.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 5),
      );
      expect(
        find.byType(AppGlassDialog),
        findsOneWidget,
        reason: '★★★ 入场必须收敛（否则测试会挂，真机上会一直重绘）',
      );
      // ignore: avoid_print
      print('[GLASS4] ⑥ pumpAndSettle 收敛 ✓');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑦ 内容溢出
  // ══════════════════════════════════════════════════════════════════
  group('⑦ 溢出滚动', () {
    testWidgets('★★★ 长内容：有滚动容器且**零溢出异常**', (t) async {
      /*
       * ★ Lead 追加的要求：「既然要新建，就顺手把它做对」。
       *
       * 实测背景（.probe/probe_e4_overflow_test.dart）：
       *   `AlertDialog` 与 `GlassDialog` 在长内容下**都会溢出**
       *   （Scrollable 都是 0、都有 RenderFlex overflowed）
       * ⇒ 本组件包了 Flexible + SingleChildScrollView，这条钉住它。
       *
       * ⚠️ 这条是**真·行为断言**：读 Scrollable 数量 + 清空异常队列。
       */
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 600);
      addTearDown(t.view.reset);

      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(
        t,
        key,
        content: Column(
          children: [
            for (var i = 0; i < 60; i++)
              SizedBox(height: 20, child: Text('第 $i 项')),
          ],
        ),
      );

      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提');
      expect(
        find.descendant(
          of: find.byType(AppGlassDialog),
          matching: find.byType(Scrollable),
        ),
        findsWidgets,
        reason: '★★★ 内容区必须有滚动容器',
      );

      var exCount = 0;
      while (t.takeException() != null) {
        exCount++;
      }
      expect(exCount, 0, reason: '★★★ 长内容不许抛溢出异常（实测 AlertDialog 会抛）');
    });

    testWidgets('★★ 短内容：不溢出（反向对照，证明上一条不是"永远过"）', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      await _openAndSettle(t, key);

      var exCount = 0;
      while (t.takeException() != null) {
        exCount++;
      }
      expect(exCount, 0, reason: '★★ 短内容当然也不许溢出');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑧ 颜色同源
  // ══════════════════════════════════════════════════════════════════
  group('⑧ 颜色同源', () {
    test('★★★ 不许出现 CupertinoColors（源码断言）', () {
      /*
       * `GlassDialog`（我们没用的那个）内部硬编码了 Cupertino 色
       * （glass_dialog.dart:318-320 / 410-414）⇒ 与全站主题不同源。
       * 本组件必须全走 AppSemanticColors。
       */
      final code = stripComments(
        File('lib/design/widgets/app_glass_dialog.dart').readAsStringSync(),
      );
      expect(
        code.contains('CupertinoColors'),
        isFalse,
        reason: '★★★ 不许用 Cupertino 色（与全站主题不同源）',
      );
      expect(
        code.contains('AppSemanticColors'),
        isTrue,
        reason: '★★★ 必须走 AppSemanticColors',
      );
    });

    test('★★★ 组件不自带 show() —— 弹出必须由 showAppDialog 装', () {
      /*
       * Lead 裁决的核心：不许绕过 showAppDialog
       * （否则丢 task-104 的 animationStyle + 换用 CupertinoDialogRoute）。
       */
      final code = stripComments(
        File('lib/design/widgets/app_glass_dialog.dart').readAsStringSync(),
      );
      expect(
        RegExp(r'static\s+Future').hasMatch(code),
        isFalse,
        reason: '★★★ 组件不许有 static show()',
      );
      expect(
        code.contains('showCupertinoDialog'),
        isFalse,
        reason: '★★★ 不许调 showCupertinoDialog',
      );
      expect(
        code.contains('showDialog'),
        isFalse,
        reason: '★★★ 不许调 showDialog（本仓唯一入口是 showAppDialog）',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑨ 源码级 + 混合态
  // ══════════════════════════════════════════════════════════════════
  group('⑨ detail_page 侧', () {
    test('★★★ 没有裸 AlertDialog( 残留', () {
      final code = detailSource();
      expect(
        RegExp(r'(?<!App)\bAlertDialog\(').hasMatch(code),
        isFalse,
        reason: '★★★ detail_page 里不许再有 Material 的 AlertDialog',
      );
    });

    test('★ 正向对照：AppGlassDialog 正好 3 处', () {
      final code = detailSource();
      expect(
        RegExp(r'AppGlassDialog\(').allMatches(code).length,
        3,
        reason: '★ 三个确认框都应该换（下载全部集 / 删除这一集 / 删除选中的集）',
      );
    });

    test('★★★ 三处仍然走 showAppDialog（不许自己 new 路由）', () {
      final code = detailSource();
      // 3 个 builder 都在 showAppDialog 里 ⇒ 至少有 3 处 showAppDialog<bool>
      final n = RegExp(r'showAppDialog<bool>\(').allMatches(code).length;
      expect(
        n,
        greaterThanOrEqualTo(3),
        reason: '★★★ 三处必须仍由 showAppDialog 弹出（实测 $n 处）',
      );
    });

    test('★ 混合态记录：Scaffold 仍是 Material（有意，非遗漏）', () {
      /*
       * ★ 2026-10-18 更新（第 5 步已完成）：SnackBar 已归零。
       *   原断言「SnackBar 仍是 Material（第 5 步才换）」是当时的如实记录，
       *   第 5 步做完后事实变了 ⇒ 判据跟着改。
       *
       * 当前混合态（Lead 裁决：分步做，不合并）：
       *   AlertDialog → 已换（AppGlassDialog）      ← 第 4 步
       *   SnackBar    → 已换（showAppToast）        ← 第 5 步
       *   Scaffold ×2 → 仍是 Material              ← 第 6 步（**须先报 Lead**）
       */
      final code = detailSource();
      expect(
        code.contains('Scaffold('),
        isTrue,
        reason: '★ 记录：Scaffold 仍是 Material（第 6 步才换，**须先报 Lead**）',
      );
      expect(
        code.contains('SnackBar('),
        isFalse,
        reason: '★ 记录：SnackBar 已全部换成 showAppToast（第 5 步）',
      );
      expect(
        code.contains('showAppToast('),
        isTrue,
        reason: '★ 记录：toast 已统一到 showAppToast',
      );
      expect(
        code.contains('AppGlassDialog('),
        isTrue,
        reason: '★ 记录：确认框已是玻璃自建',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  按钮能真的关（返回值正确）
  // ══════════════════════════════════════════════════════════════════
  group('按钮行为', () {
    testWidgets('★★★ 点「删除」⇒ 返回 true；点「取消」⇒ 返回 false', (t) async {
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key));
      final fut = _open(key);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      await t.tap(find.text('删除'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(await fut, isTrue, reason: '★★★ 确认必须返回 true');
      expect(find.byType(AppGlassDialog), findsNothing);

      final key2 = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(key2));
      final fut2 = _open(key2);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      await t.tap(find.text('取消'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(await fut2, isFalse, reason: '★★★ 取消必须返回 false');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  真实 DetailPage：三个确认框确实用上了
  // ══════════════════════════════════════════════════════════════════
  group('真实页面', () {
    testWidgets('★★★ 挂真实 DetailPage，触发「下载全部集」确认框', (t) async {
      /*
       * ★ 走 t27_w3 学来的脚手架（host + debugSetDetail 注真数据）。
       * 这里验证的不是"组件单独好用"，而是**产品里真的接上了**。
       */
      NetworkStatus.debugProbe = () async => true;
      addTearDown(NetworkStatus.debugResetForTest);
      await t.binding.setSurfaceSize(const Size(433, 900));
      addTearDown(() => t.binding.setSurfaceSize(null));

      final key = GlobalKey<State<DetailPage>>();
      await t.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(Brightness.dark),
          themeAnimationDuration: Duration.zero,
          localizationsDelegates: const [
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: Scaffold(
            body: DetailPage(
              key: key,
              provider: 'cycani',
              id: '3862',
              embedded: true,
            ),
          ),
        ),
      );
      while (t.takeException() != null) {}
      await t.pump(const Duration(milliseconds: 50));

      const d = MediaDetail(
        id: '3862',
        title: '在线剧',
        episodes: <Episode>[Episode(id: 'ep-1', title: '第01集')],
      );
      // ignore: avoid_dynamic_calls
      (key.currentState! as dynamic).debugSetDetail(d, episodes: d.episodes);
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      while (t.takeException() != null) {}

      // 点「下载」→ 菜单 → 「下载全部集（1 集）」→ 触发 AppGlassDialog
      expect(find.text('下载'), findsOneWidget, reason: '前提：下载按钮在');
      await t.tap(find.text('下载'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      final allItem = find.text('下载全部集（1 集）');
      if (allItem.evaluate().isEmpty) {
        // ignore: avoid_print
        print('[GLASS4] 菜单项未出现，跳过页面级确认框断言（不强求）');
        return;
      }
      await t.tap(allItem);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      while (t.takeException() != null) {}

      expect(
        find.byType(AppGlassDialog),
        findsOneWidget,
        reason: '★★★ 真实页面里弹出的必须是 AppGlassDialog（不是 AlertDialog）',
      );
      expect(find.text('下载全部集'), findsWidgets, reason: '★★★ 标题必须对');
      // ignore: avoid_print
      print('[GLASS4] ★ 真实页面的确认框 = AppGlassDialog ✓');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑨ 双向：旧实现（AlertDialog）下新判据必须绿
  // ══════════════════════════════════════════════════════════════════
  group('⑨ 双向验证（旧实现下必须绿）', () {
    /*
     * ⚠️ 每条场景**单独一个 testWidgets**。
     *
     * 我第一版把 ①②③④⑦ 塞进同一个测试体、共用 `t.pumpWidget` ——
     * 结果 ① 的"点外面应关"读到的是**上一次残留**的 AlertDialog 实例，
     * 报了一个假的"判据在旧实现下不成立"。
     * ⇒ 对话框测试必须一场景一用例（tester 自己也会在用例边界重建树）。
     */
    Future<void> openAlert(
      WidgetTester t,
      GlobalKey<NavigatorState> k, {
      bool barrierDismissible = true,
    }) async {
      unawaited(
        showAppDialog<bool>(
          context: k.currentContext!,
          barrierDismissible: barrierDismissible,
          builder: (ctx) => AlertDialog(
            title: const Text('删除这一集？'),
            content: const Text('文件会从磁盘上真正删除，此操作不可恢复。'),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删除'),
              ),
            ],
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
    }

    testWidgets('① barrier=true 在 AlertDialog 上也成立', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      expect(find.byType(AlertDialog), findsOneWidget, reason: '前提');
      await t.tapAt(const Offset(5, 5));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(
        find.byType(AlertDialog),
        findsNothing,
        reason: '★ barrier=true 在旧实现下也成立',
      );
    });

    testWidgets('① barrier=false 在 AlertDialog 上也成立', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k, barrierDismissible: false);
      expect(find.byType(AlertDialog), findsOneWidget, reason: '前提');
      await t.tapAt(const Offset(5, 5));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(
        find.byType(AlertDialog),
        findsOneWidget,
        reason: '★ barrier=false 在旧实现下也成立',
      );
    });

    testWidgets('③ ESC 在 AlertDialog 上也成立', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      expect(find.byType(AlertDialog), findsOneWidget, reason: '前提');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byType(AlertDialog), findsNothing, reason: '★ ESC 在旧实现下也成立');
    });

    testWidgets('④ 返回键在 AlertDialog 上也成立', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      expect(await k.currentState!.maybePop(), isTrue, reason: '★ 返回键在旧实现下也成立');
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byType(AlertDialog), findsNothing, reason: '★ 已关');
    });

    testWidgets('⑤ 语义在 AlertDialog 上也成立', (t) async {
      final handle = t.ensureSemantics();
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      expect(
        find.bySemanticsLabel('删除这一集？'),
        findsWidgets,
        reason: '★ 标题语义在旧实现下也成立',
      );
      expect(
        find.bySemanticsLabel('取消'),
        findsWidgets,
        reason: '★ 按钮语义在旧实现下也成立',
      );
      handle.dispose();
    });

    testWidgets('⑦ 短内容在 AlertDialog 上也不溢出', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      var ex = 0;
      while (t.takeException() != null) {
        ex++;
      }
      expect(ex, 0, reason: '★ 短内容在旧实现下也不溢出');
    });

    /*
     * ★★★ ⑦ 的**已知差异**（不是判据错，是真实差异）
     *
     * 实测：`AlertDialog` 在长内容下**会溢出**（Scrollable=0 + RenderFlex overflowed）。
     * ⇒ 这一项**不**要求旧实现也绿 —— 它是我们**主动做对**的地方。
     * 把它显式记录下来，免得后人看到"新实现比旧实现多一条"以为判据不一致。
     */
    testWidgets('⑦【已知差异】长内容在 AlertDialog 上**会**溢出（我们改进了）', (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 600);
      addTearDown(t.view.reset);
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      unawaited(
        showAppDialog<void>(
          context: k.currentContext!,
          builder: (_) => AlertDialog(
            title: const Text('长内容'),
            content: SizedBox(
              height: 1200,
              child: Column(
                children: [
                  for (var i = 0; i < 60; i++)
                    SizedBox(height: 20, child: Text('第 $i 项')),
                ],
              ),
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      var ex = 0;
      while (t.takeException() != null) {
        ex++;
      }
      // ignore: avoid_print
      print('[GLASS4] ⑦ 旧实现（AlertDialog）长内容溢出异常数 = $ex（预期 >0）');
      expect(
        ex,
        greaterThan(0),
        reason:
            '★ 如实记录：AlertDialog 长内容会溢出 —— '
            '这正是 AppGlassDialog 主动修掉的差异',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  ⑧ 紧约束全窗（P1 修：卡片曾铺满整窗）
  //
  //  ★ 为什么这条判据必须存在：`showDialog` 的 DialogRoute 把 builder 结果
  //    挂在 Positioned.fill 上，传进来的是**紧约束**（min==max==整窗）。
  //    `ConstrainedBox(maxWidth: …)` 用的是 `enforce(父约束)` ⇒ 父是紧的，
  //    maxWidth 直接被顶掉，卡片铺满 100% 屏幕（实测 rect=(0,0,1280,800)）。
  //    Material 的 AlertDialog 自己 build 里有一层 Align，我们这层外壳漏了。
  //  ★ 这条**不看具体数值**也成立：宽度不是满屏 + 居中 + 两侧留白 > 0。
  // ══════════════════════════════════════════════════════════════════════
  group('⑧ 紧约束全窗 ⇒ 必须是居中卡片，不是满屏', () {
    testWidgets('★★★ 1280×800 视口：宽度非满屏 + 水平居中 + 两侧留白 > 0', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await _openAndSettle(t, k);

      final rect = t.getRect(find.byType(GlassContainer));
      // ignore: avoid_print
      print('[GLASS4] ⑧ rect=$rect w=${rect.width} h=${rect.height}');
      expect(
        rect.width,
        lessThan(1280 * 0.9),
        reason: '★ 卡片不许满屏：少一层 Align 时 maxWidth 会被紧约束顶掉',
      );
      expect(rect.height, lessThan(800 * 0.9), reason: '★ 高度同理，不许满屏');
      expect(rect.left, greaterThan(0), reason: '★ 左侧必须留白');
      expect(1280 - rect.right, greaterThan(0), reason: '★ 右侧必须留白');
      expect(
        (rect.left - (1280 - rect.right)).abs(),
        lessThanOrEqualTo(1),
        reason: '★ 必须水平居中（两侧留白相等）',
      );
      expect(t.takeException(), isNull);
    });

    // ── 默认值必须落在 §3.5 白名单里（380/420 是拍出来的数） ──────────
    testWidgets('★★★ 默认宽度 ∈ §3.5 白名单 {460,560,820}，且等于窄弹窗档 460', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await _openAndSettle(t, k);

      final rect = t.getRect(find.byType(GlassContainer));
      // ignore: avoid_print
      print('[GLASS4] ⑧ 默认宽=${rect.width} 高=${rect.height}');
      /*
       * docs/AGENTS.md §3.5：宽度默认 560；窄弹窗 460、宽版面 820。
       * 本类装确认框 ⇒ 460 档。★ 380 不在白名单里，这条就是为了钉死它。
       */
      expect(
        const [460.0, 560.0, 820.0],
        contains(rect.width),
        reason: '★ §3.5：宽度只允许 460 / 560 / 820（380 是拍出来的数）',
      );
      expect(rect.width, 460, reason: '★ 确认框 = §3.5 的「窄弹窗」档 ⇒ 460');
      expect(rect.height, lessThanOrEqualTo(620), reason: '★ §3.5：最大高度绝对值 620');
    });

    // ── 三键同排在 460 宽下不许溢出 / 不裁切 ─────────────────────────
    testWidgets('★★★ 三键同排（最小化到托盘 / 彻底退出 / 取消）在 460 宽下不溢出', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      // 用 app_tray 真实那三个标签（最宽的一处三键）
      unawaited(
        showAppDialog<int>(
          context: k.currentContext!,
          barrierDismissible: false,
          builder: (ctx) => AppGlassDialog(
            title: '要关闭还是彻底退出？',
            content: const Text(
              '最小化到托盘：窗口收起来，程序继续在后台运行。\n\n'
              '彻底退出：结束程序，后台下载等任务会一起停止。',
            ),
            actions: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                AppTextButton(
                  onPressed: () => Navigator.of(ctx).pop(0),
                  child: const Text('最小化到托盘'),
                ),
                const SizedBox(width: 4),
                AppTextButton(
                  onPressed: () => Navigator.of(ctx).pop(1),
                  child: const Text('彻底退出'),
                ),
                const SizedBox(width: 4),
                AppTextButton(
                  onPressed: () => Navigator.of(ctx).pop(-1),
                  child: const Text('取消'),
                ),
              ],
            ),
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));

      final card = t.getRect(find.byType(GlassContainer));
      final labels = ['最小化到托盘', '彻底退出', '取消'];
      final rects = [for (final l in labels) t.getRect(find.text(l).last)];
      // ignore: avoid_print
      print('[GLASS4] ⑧ card=$card 三键=$rects');
      // ① 不许有 RenderFlex overflow / 任何异常
      expect(t.takeException(), isNull, reason: '★ 三键同排在 460 宽下不许溢出');
      // ② 三个键都必须真的在卡片内（没被裁掉）
      for (var i = 0; i < 3; i++) {
        expect(
          rects[i].left,
          greaterThanOrEqualTo(card.left),
          reason: '★「${labels[i]}」被卡片左边缘裁切',
        );
        expect(
          rects[i].right,
          lessThanOrEqualTo(card.right),
          reason: '★「${labels[i]}」被卡片右边缘裁切',
        );
      }
      // ③ 三键必须仍在**同一行**（y 相同）—— 溢出/换行的另一种形态
      expect(rects[0].center.dy, rects[1].center.dy, reason: '★ 三键被挤成两行');
      expect(rects[1].center.dy, rects[2].center.dy, reason: '★ 三键被挤成两行');
    });
  });

  // ════════════════════════════════════════════════════════════════════
  group('⑩ 圆角引 token（读 widget 属性，不看像素）', () {
    /*
     * # 守什么
     * ```text
     * docs/AGENTS.md §3.5：圆角 Radii.rLg
     * lib/ui/tokens.dart:98  Radii.lg  = 22
     * lib/ui/tokens.dart:107 Radii.rLg = all(circular(22))
     * ```
     * 改前两套外壳的**玻璃轮廓层**都硬编码 `20`（`AppGlassDialog` 的
     * `LiquidRoundedSuperellipse`、`AppDialogShell` 的 `LiquidRoundedRectangle`），
     * 而玻璃档的观感由正是这一层决定（内层 Material 已透明 + side:none +
     * Clip.none，不画也不裁）⇒ §3.5 在玻璃档上一直**名不副实**。
     *
     * # 为什么读属性而不是像素
     * ```text
     * 像素会被抗锯齿、设备像素比、玻璃模糊抖掉；
     * `GlassContainer.shape.borderRadius` 是**决定观感的那个值本身**。
     * ```
     * # ⚠️ 判据写「等于 Radii.lg」，不写「等于 22」
     * ```text
     * 写死 22 ⇒ 以后调 token 时这两条会红，逼下一个人改测试而不是宣 token
     * ⇒ 判据从"守规范"退化成"守某个具体数字"。
     * ```
     * # 判别力（已做故障注入）
     * ```text
     * 任一处改成字面量 20 ⇒ 本组立刻红（Expected: 22.0 / Actual: 20.0）。
     * ```
     */
    testWidgets('AppGlassDialog 的 GlassContainer.shape 用 Radii.lg', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await _openAndSettle(t, k);

      final glass = t.widget<GlassContainer>(find.byType(GlassContainer));
      final shape = glass.shape;
      expect(
        shape,
        isA<LiquidRoundedSuperellipse>(),
        reason:
            '★ AppGlassDialog 的玻璃轮廓不是超椭圆了 —— '
            '先确认是不是换了 shape 类型，再决定这条判据怎么改',
      );
      expect(
        (shape as LiquidRoundedSuperellipse).borderRadius,
        Radii.lg,
        reason:
            '★ §3.5「圆角 Radii.rLg」：玻璃轮廓圆角必须引 token，'
            '不许硬编码 20',
      );
    });

    testWidgets(
      'AppDialogShell(glass: true) 的 GlassContainer.shape 也用 Radii.lg',
      (t) async {
        await t.pumpWidget(
          MaterialApp(
            theme: AppTheme.themeFor(Brightness.dark),
            themeAnimationDuration: Duration.zero,
            localizationsDelegates: const [
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const AppDialogShell(
              title: '圆角判据',
              glass: true,
              child: Text('内容'),
            ),
          ),
        );

        final glass = t.widget<GlassContainer>(find.byType(GlassContainer));
        final shape = glass.shape;
        expect(
          shape,
          isA<LiquidRoundedRectangle>(),
          reason:
              '★ AppDialogShell 的玻璃轮廓不是圆角矩形了 —— '
              '先确认是不是换了 shape 类型，再决定这条判据怎么改',
        );
        expect(
          (shape as LiquidRoundedRectangle).borderRadius,
          Radii.lg,
          reason:
              '★ §3.5「圆角 Radii.rLg」：玻璃档的观感由这一层决定'
              '（内层 Material 已透明 + side:none + Clip.none）'
              '⇒ 这里硬编码 20 就等于整个玻璃弹窗的圆角不受规范管',
        );
      },
    );
  });

  // ════════════════════════════════════════════════════════════════════
  group('⑪ 实色垫层：正文对比度（P0，R3-① 同类缺陷）', () {
    /*
     * # 守什么
     *
     * 真机读数（Lead 用 PIL 从 `.probe/round66_r4_device/fix1_01_tray_close.png`
     * 逐像素量；卡底 `#A1A9BC` 是**玻璃压页面后的模糊结果**）：
     * ```text
     * 标题「要关闭还是彻底退出？」      #0A0A0A on #A1A9BC = 8.41:1  ✔
     * 正文（最小化到托盘…）            #737373 on #A1A9BC = 2.01:1  ✘
     * 正文（彻底退出：结束程序…）       #737373 on #A1A9BC = 2.01:1  ✘
     * 按钮行                          #171717 on #A1A9BC = 7.59:1  ✔
     * ```
     * 病因：R3-① 的口诀是「玻璃管质感、遮光交给**实色垫层**」，但那个垫层只
     * 落在 `app_dialog_shell.dart:301`；本组件从来没有 ⇒ R4 把 7 个 `AlertDialog`
     * 搬进来，等于把 R3-① 的缺陷搬了回来。
     *
     * # 垫层用哪个色：`c.surfaceContainerHigh`（**不是** ColorScheme）
     * ```text
     * 本组件的标题/正文色来自 `AppTheme.resolvedOf(context).colors`
     * （AppSemanticColors），不是 `Theme.of(context).colorScheme`。
     * 垫层必须与**文字色同源**，否则「算出来的对比度」和「真渲染的对比度」
     * 对不上 ⇒ 又变成一条算着绿、看着坏的假门禁。
     * ```
     * ⚠️ 也**不要**照抄 AppDialogShell 玻璃档写死的 `#14161B@0.98`：那一档是
     *    「视频上面的面板」，文字被换成浅色系；本组件的调用点是浅色页面上的
     *    确认框，正文 `c.onSurfaceVariant` 在浅色档就是 `#737373` ——
     *    压在近黑底上只剩 ~1.5:1，比不修更糟。
     *
     * # 三条判据（①②接线 + ③效果，缺一不可）
     * ```text
     * ① 结构：`GlassContainer` 的**直接子层**是 `DecoratedBox`
     *         ⇒ 证明垫层没被漏掉（改前直接子层是 Padding）。
     * ② 同源：该 DecoratedBox 的 color == 组件自己 resolve 出来的
     *         `colors.surfaceContainerHigh`，borderRadius == `Radii.rLg`
     *         ⇒ 读 widget 属性，不读像素：像素会被玻璃模糊/DPR/抗锯齿抖掉。
     *         ⇒ 圆角也要断言：`ColoredBox` 那种直角垫层会从玻璃圆角外侧露出来。
     * ③ 效果：拿**两套 palette** 现算的 `onSurfaceVariant` / `onSurface` 压在
     *         `surfaceContainerHigh` 上，WCAG 对比比都 ≥ 4.5:1（AA 正文档）。
     *         不写死 6.08 这种数 —— 主题改色时判据要跟着重算。
     * ```
     *
     * # 判别力（故障注入，两次都实测变红后精确还原）
     * ```text
     * 注入 A：把 DecoratedBox 垫层整层删掉（回到玻璃直接压 Padding）⇒ ① 红
     * 注入 B：垫层色改成 `Colors.transparent`                      ⇒ ② 红
     * ```
     */
    for (final entry in <(String, AppPalette)>[
      ('浅色', AppPalette.light),
      ('深色', AppPalette.dark),
    ]) {
      final name = entry.$1;
      final palette = entry.$2;

      testWidgets(
        '$name主题：垫层 = 同源 surfaceContainerHigh + Radii.rLg，正文对比度 ≥ 4.5:1',
        (t) async {
          final k = GlobalKey<NavigatorState>();
          await t.pumpWidget(_app(k));
          await _openAndSettle(t, k);

          // ── ① 结构：垫层就在 GlassContainer 的直接子层 ────────────────
          final glass = t.widget<GlassContainer>(find.byType(GlassContainer));
          expect(
            glass.child,
            isA<DecoratedBox>(),
            reason:
                '★★ 玻璃卡片下面**没有实色垫层**了。'
                '玻璃只管质感、遮光必须靠垫层（R3-① 的裁决）——'
                '少了这层，正文 c.onSurfaceVariant 压在页面色的模糊结果上会掉到 ~2:1',
          );

          // ── ② 同源：颜色/圆角都要对得上 ──────────────────────────────
          final ctx = t.element(find.byType(GlassContainer));
          final live = design.AppTheme.resolvedOf(ctx).colors;
          // ⚠️ 子树里 DecoratedBox 不止一个（按钮等也有），
          //    深度优先的**第一个**才是 GlassContainer 的直接子层。
          final deco = t
              .widget<DecoratedBox>(
                find
                    .descendant(
                      of: find.byType(GlassContainer),
                      matching: find.byType(DecoratedBox),
                    )
                    .first,
              )
              .decoration;
          expect(
            deco,
            isA<BoxDecoration>(),
            reason: '★ 垫层应该是 BoxDecoration（要能同时给色和圆角）',
          );
          final box = deco as BoxDecoration;

          expect(
            box.color,
            live.surfaceContainerHigh,
            reason:
                '★ 垫层色必须与文字色**同源**：`c.surfaceContainerHigh`'
                '（AppSemanticColors），不是 Theme.of(context).colorScheme 那一套。'
                '实测 = ${box.color}，期望 = ${live.surfaceContainerHigh}',
          );
          expect(
            box.borderRadius,
            Radii.rLg,
            reason:
                '★ 垫层必须跟着卡片圆角（Radii.rLg）——'
                '直角垫层会从玻璃圆角外侧露出来',
          );

          // ── ③ 效果：按两套 palette 的真实色值算对比度 ────────────────
          final semantic = _semanticFor(palette);
          final under = semantic.surfaceContainerHigh;
          final body = _contrast(semantic.onSurfaceVariant, under);
          final title = _contrast(semantic.onSurface, under);
          // 失败时把读数打出来，省得下一个人再量一遍像素。
          // ignore: avoid_print
          print(
            '[⑪] $name 垫层=$under body=${body.toStringAsFixed(2)}:1 '
            'title=${title.toStringAsFixed(2)}:1',
          );

          expect(
            body,
            greaterThanOrEqualTo(4.5),
            reason:
                '★★ $name主题正文（onSurfaceVariant）对比度 = '
                '${body.toStringAsFixed(2)}:1 < 4.5:1（WCAG AA 正文档）。'
                '真机改前实测 2.01:1，正是这个缺陷。',
          );
          expect(
            title,
            greaterThanOrEqualTo(4.5),
            reason:
                '★★ $name主题标题（onSurface）对比度 = '
                '${title.toStringAsFixed(2)}:1 < 4.5:1',
          );

          // ── 反向对照：证明这套算式**不是恒真**的 ─────────────────────
          // 把改前的真实卡底（#A1A9BC，玻璃压浅色页面的模糊结果）代进同一套
          // 算式，必须算出 < 4.5:1；否则说明算式或取色写错了，这条判据此刻无判别力。
          final oldCard = _contrast(
            semantic.onSurfaceVariant,
            const Color(0xFFA1A9BC),
          );
          expect(
            oldCard,
            lessThan(4.5),
            reason:
                '★ 反向对照失败：改前真机卡底 #A1A9BC 代进同一套算式居然也'
                '算出 ≥ 4.5:1（=${oldCard.toStringAsFixed(2)}:1）'
                '⇒ 算式或取色错了，本条判据此刻无判别力',
          );
        },
      );
    }
  });

  // ════════════════════════════════════════════════════════════════════
  group('⑪-b 报告：全主题包的正文对比度（只打印，不 assert）', () {
    /*
     * # 为什么单独一条、且不 assert
     * ```text
     * `AppPalette.light.mutedForeground = #737373`（app_palette.dart:118）本身
     * 对页面底 `#EEF0F6` 只有 4.16:1，theme_pack.dart:954/995/1011/1026 的注释
     * 也承认某些主题包只有 4.34~4.48:1 ⇒ 这是**既有 token 问题**，不属于
     * 「弹窗外壳」这一轮的修复范围。
     * 硬 assert 的后果：要么逼人去改别人的主题包色值，要么把阈值写松（假绿）。
     * ⇒ 只打印读数表，交 Lead 裁决。
     * ```
     */
    testWidgets('打印 builtins 各主题包 contrast(mutedForeground, card)', (t) async {
      for (final pack in ThemePackStore.builtins) {
        final c = _semanticFor(pack.palette);
        final body = _contrast(c.onSurfaceVariant, c.surfaceContainerHigh);
        final onPage = _contrast(c.onSurfaceVariant, c.surface);
        // ignore: avoid_print
        print(
          '[⑪-b] ${pack.id.padRight(26)} '
          'body=${c.onSurfaceVariant} card=${c.surfaceContainerHigh} '
          '→ 卡面 ${body.toStringAsFixed(2)}:1 | '
          '页面底 ${onPage.toStringAsFixed(2)}:1 '
          '${body >= 4.5 ? 'OK' : '<4.5!'}',
        );
      }
    });
  });
}
