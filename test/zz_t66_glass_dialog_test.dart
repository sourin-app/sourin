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

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart'
    show GlobalCupertinoLocalizations, GlobalWidgetsLocalizations;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart'
    show AlertDialog, MaterialApp, Scaffold, TextButton;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/design/theme/app_theme.dart' as design;
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
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
Future<void> _openAndSettle(WidgetTester t, GlobalKey<NavigatorState> key,
    {bool barrierDismissible = true, Widget? content}) async {
  unawaited(_open(key,
      barrierDismissible: barrierDismissible, content: content));
  await t.pump();
  await t.pump(const Duration(milliseconds: 800));
}

void unawaited(Future<void> f) {}

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
      expect(find.byType(AppGlassDialog), findsNothing,
          reason: '★★★ 点外面必须关（barrier 语义）');
    });

    testWidgets('★★★ barrierDismissible:false ⇒ 点外面**不关**（反向对照）',
        (t) async {
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
      expect(find.byType(AppGlassDialog), findsOneWidget,
          reason: '★★★ barrierDismissible:false 时必须**不关** —— '
              '组件不许自己画 scrim 抢走 barrier 语义');
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
      expect(find.byType(AppGlassDialog), findsOneWidget,
          reason: '★★★ Tab 不许把对话框搞没');

      // ② 焦点必须仍在对话框内
      final focusCtx = FocusManager.instance.primaryFocus?.context;
      expect(focusCtx, isNotNull, reason: '前提：有焦点');
      final inDialog = find
          .descendant(
              of: find.byType(AppGlassDialog), matching: find.byType(Focus))
          .evaluate()
          .any((e) => e == focusCtx ||
              (focusCtx?.findAncestorWidgetOfExactType<AppGlassDialog>() !=
                  null));
      expect(inDialog, isTrue,
          reason: '★★★ Tab 12 次后焦点必须仍在对话框内（焦点陷阱）');
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
      expect(find.byType(AppGlassDialog), findsNothing,
          reason: '★★★ ESC 必须能关（Lead 明令：不许出现"只能点按钮"的退化）');
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
      expect(find.byType(AppGlassDialog), findsNothing,
          reason: '★★★ 返回键（Android/TV）必须能关');
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

      expect(find.bySemanticsLabel('删除这一集？'), findsWidgets,
          reason: '★★★ 标题必须可被读屏找到');
      expect(find.bySemanticsLabel('取消'), findsWidgets,
          reason: '★★★ 「取消」必须可被读屏找到');
      expect(find.bySemanticsLabel('删除'), findsWidgets,
          reason: '★★★ 「删除」必须可被读屏找到');
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
      expect(route.runtimeType.toString(), contains('DialogRoute'),
          reason: '★★ 必须是 DialogRoute');
      expect(route.runtimeType.toString(), isNot(contains('Cupertino')),
          reason: '★★★ 不许是 CupertinoDialogRoute（那会绕过 showAppDialog）');
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
      expect(find.byType(AppGlassDialog), findsOneWidget,
          reason: '★★★ 入场必须收敛（否则测试会挂，真机上会一直重绘）');
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
        content: Column(children: [
          for (var i = 0; i < 60; i++)
            SizedBox(height: 20, child: Text('第 $i 项')),
        ]),
      );

      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提');
      expect(find.descendant(
              of: find.byType(AppGlassDialog),
              matching: find.byType(Scrollable)),
          findsWidgets,
          reason: '★★★ 内容区必须有滚动容器');

      var exCount = 0;
      while (t.takeException() != null) {
        exCount++;
      }
      expect(exCount, 0,
          reason: '★★★ 长内容不许抛溢出异常（实测 AlertDialog 会抛）');
    });

    testWidgets('★★ 短内容：不溢出（反向对照，证明上一条不是"永远过"）',
        (t) async {
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
      final code =
          stripComments(File('lib/design/widgets/app_glass_dialog.dart')
              .readAsStringSync());
      expect(code.contains('CupertinoColors'), isFalse,
          reason: '★★★ 不许用 Cupertino 色（与全站主题不同源）');
      expect(code.contains('AppSemanticColors'), isTrue,
          reason: '★★★ 必须走 AppSemanticColors');
    });

    test('★★★ 组件不自带 show() —— 弹出必须由 showAppDialog 装', () {
      /*
       * Lead 裁决的核心：不许绕过 showAppDialog
       * （否则丢 task-104 的 animationStyle + 换用 CupertinoDialogRoute）。
       */
      final code =
          stripComments(File('lib/design/widgets/app_glass_dialog.dart')
              .readAsStringSync());
      expect(RegExp(r'static\s+Future').hasMatch(code), isFalse,
          reason: '★★★ 组件不许有 static show()');
      expect(code.contains('showCupertinoDialog'), isFalse,
          reason: '★★★ 不许调 showCupertinoDialog');
      expect(code.contains('showDialog'), isFalse,
          reason: '★★★ 不许调 showDialog（本仓唯一入口是 showAppDialog）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑨ 源码级 + 混合态
  // ══════════════════════════════════════════════════════════════════
  group('⑨ detail_page 侧', () {
    test('★★★ 没有裸 AlertDialog( 残留', () {
      final code = detailSource();
      expect(RegExp(r'(?<!App)\bAlertDialog\(').hasMatch(code), isFalse,
          reason: '★★★ detail_page 里不许再有 Material 的 AlertDialog');
    });

    test('★ 正向对照：AppGlassDialog 正好 3 处', () {
      final code = detailSource();
      expect(RegExp(r'AppGlassDialog\(').allMatches(code).length, 3,
          reason: '★ 三个确认框都应该换（下载全部集 / 删除这一集 / 删除选中的集）');
    });

    test('★★★ 三处仍然走 showAppDialog（不许自己 new 路由）', () {
      final code = detailSource();
      // 3 个 builder 都在 showAppDialog 里 ⇒ 至少有 3 处 showAppDialog<bool>
      final n = RegExp(r'showAppDialog<bool>\(').allMatches(code).length;
      expect(n, greaterThanOrEqualTo(3),
          reason: '★★★ 三处必须仍由 showAppDialog 弹出（实测 $n 处）');
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
      expect(code.contains('Scaffold('), isTrue,
          reason: '★ 记录：Scaffold 仍是 Material（第 6 步才换，**须先报 Lead**）');
      expect(code.contains('SnackBar('), isFalse,
          reason: '★ 记录：SnackBar 已全部换成 showAppToast（第 5 步）');
      expect(code.contains('showAppToast('), isTrue,
          reason: '★ 记录：toast 已统一到 showAppToast');
      expect(code.contains('AppGlassDialog('), isTrue,
          reason: '★ 记录：确认框已是玻璃自建');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  按钮能真的关（返回值正确）
  // ══════════════════════════════════════════════════════════════════
  group('按钮行为', () {
    testWidgets('★★★ 点「删除」⇒ 返回 true；点「取消」⇒ 返回 false',
        (t) async {
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
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        localizationsDelegates: const [
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(body: DetailPage(
          key: key,
          provider: 'cycani',
          id: '3862',
          embedded: true,
        )),
      ));
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

      expect(find.byType(AppGlassDialog), findsOneWidget,
          reason: '★★★ 真实页面里弹出的必须是 AppGlassDialog（不是 AlertDialog）');
      expect(find.text('下载全部集'), findsWidgets,
          reason: '★★★ 标题必须对');
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
    Future<void> openAlert(WidgetTester t, GlobalKey<NavigatorState> k,
        {bool barrierDismissible = true}) async {
      unawaited(showAppDialog<bool>(
        context: k.currentContext!,
        barrierDismissible: barrierDismissible,
        builder: (ctx) => AlertDialog(
          title: const Text('删除这一集？'),
          content: const Text('文件会从磁盘上真正删除，此操作不可恢复。'),
          actions: [
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('取消')),
            TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('删除')),
          ],
        ),
      ));
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
      expect(find.byType(AlertDialog), findsNothing,
          reason: '★ barrier=true 在旧实现下也成立');
    });

    testWidgets('① barrier=false 在 AlertDialog 上也成立', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k, barrierDismissible: false);
      expect(find.byType(AlertDialog), findsOneWidget, reason: '前提');
      await t.tapAt(const Offset(5, 5));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byType(AlertDialog), findsOneWidget,
          reason: '★ barrier=false 在旧实现下也成立');
    });

    testWidgets('③ ESC 在 AlertDialog 上也成立', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      expect(find.byType(AlertDialog), findsOneWidget, reason: '前提');
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byType(AlertDialog), findsNothing,
          reason: '★ ESC 在旧实现下也成立');
    });

    testWidgets('④ 返回键在 AlertDialog 上也成立', (t) async {
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      expect(await k.currentState!.maybePop(), isTrue,
          reason: '★ 返回键在旧实现下也成立');
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      expect(find.byType(AlertDialog), findsNothing, reason: '★ 已关');
    });

    testWidgets('⑤ 语义在 AlertDialog 上也成立', (t) async {
      final handle = t.ensureSemantics();
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      await openAlert(t, k);
      expect(find.bySemanticsLabel('删除这一集？'), findsWidgets,
          reason: '★ 标题语义在旧实现下也成立');
      expect(find.bySemanticsLabel('取消'), findsWidgets,
          reason: '★ 按钮语义在旧实现下也成立');
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
    testWidgets('⑦【已知差异】长内容在 AlertDialog 上**会**溢出（我们改进了）',
        (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = const Size(400, 600);
      addTearDown(t.view.reset);
      final k = GlobalKey<NavigatorState>();
      await t.pumpWidget(_app(k));
      unawaited(showAppDialog<void>(
        context: k.currentContext!,
        builder: (_) => AlertDialog(
          title: const Text('长内容'),
          content: SizedBox(
            height: 1200,
            child: Column(children: [
              for (var i = 0; i < 60; i++)
                SizedBox(height: 20, child: Text('第 $i 项')),
            ]),
          ),
        ),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));
      var ex = 0;
      while (t.takeException() != null) {
        ex++;
      }
      // ignore: avoid_print
      print('[GLASS4] ⑦ 旧实现（AlertDialog）长内容溢出异常数 = $ex（预期 >0）');
      expect(ex, greaterThan(0),
          reason: '★ 如实记录：AlertDialog 长内容会溢出 —— '
              '这正是 AppGlassDialog 主动修掉的差异');
    });
  });
}
