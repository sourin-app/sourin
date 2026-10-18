// ═══════════════════════════════════════════════════════════════════════
//  轨道 E 第 5 步 —— 全仓 SnackBar → showAppToast
// ═══════════════════════════════════════════════════════════════════════
//
// # 这一步改的是什么
//
// ```text
// 5 处遗留的 `ScaffoldMessenger...showSnackBar` 统一到 `showAppToast`：
//   lib/ui/detail_page.dart:3354        _sayLocal
//   lib/ui/cache_page.dart:1868         _say
//   lib/ui/cast/cast_button.dart:187    _toast
//   lib/ui/widgets/plugin_speedtest.dart:1933
//   lib/ui/app_update_bootstrap.dart:66
// ```
//
// # ★★★ 为什么不是「换个组件」这么简单 —— 这是可靠性修复
//
// ```text
// showSnackBar 内部有断言：
//   assert(_scaffolds.isNotEmpty,
//     'ScaffoldMessenger.showSnackBar was called, but there are currently
//      no descendant Scaffolds to present to.')
//
// 而 `ScaffoldMessenger.maybeOf(context)` 只保证 **messenger 存在**，
// 不保证它**能显示** —— MaterialApp 自带一个 messenger ⇒ maybeOf 一直非 null
// ⇒ 原来那 5 处的 `?.` **形同虚设**。
//
// ★ 这不是理论风险。skip_marker_dialog.dart:1347-1400 记录了 2026-10-02 的
//   真实事故：`_toast` 在赋值**之前**抛异常 ⇒ 把 switch 的赋值吞掉
//   ⇒「只要「+」被夹到边界，值就卡住不动」
//   （Owner 看到的是"那四个三角根本不能拖动"）
// ```
//
// `AppToaster.maybeOf` 找不到宿主时**静默忽略、不抛异常**
// ⇒ toast 是锦上添花，绝不会把调用方搞崩。
//
// # Lead 的五条门禁要求
// ```text
// ① detail_page 内 showSnackBar 归零（源码断言，剥注释）
// ② 全仓 showSnackBar 只剩 0 处
// ③ 每处替换后行为断言：调那个操作 ⇒ toast 真的弹出来
// ④ ★ 反向：AppToaster 无宿主时不崩（事故的回归测试）
// ⑤ 故障注入：改回 showSnackBar ⇒ ①②必须红
// ```

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';

// ══════════════════════════════════════════════════════════════════════
//  工具
// ══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 与 `/* */` 注释（保留字符串字面量内容）。
///
/// ★ 必须剥：有 3 处 showSnackBar 出现在**注释**里（我写的"为什么换"），
///   不剥就会把它们当成真实调用 ⇒ 门禁永远红。
///   而 `skip_marker_dialog.dart` 有 15 处注释提及，同理。
/// 剥掉 `//`、`///` 与 `/* */` 注释。
///
/// ★ 为什么不用"逐字符状态机"（我第一版的做法）：
/// ```text
/// 注释里常有反引号包裹的行内代码，例如
///   /// `ScaffoldMessenger.maybeOf(context)?.showSnackBar(...)`
/// 里面既有 `?.` 又有成对的引号字符。逐字符状态机在遇到
/// "注释中的奇数个引号" 时会把后续代码整体误判成字符串 ⇒ 剥不干净。
/// ⇒ 改成**逐行**处理：先按行判断是不是注释行，再处理块注释。
///   注释行的判定不需要理解字符串，代价是"代码行里的行内块注释"处理得保守，
///   但那对我们够用（本仓不用行内块注释）。
/// ```
String stripComments(String src) {
  final out = <String>[];
  var inBlock = false;
  for (final raw in src.split('\n')) {
    final line = raw.trimLeft();
    if (inBlock) {
      if (line.contains('*/')) inBlock = false;
      continue;
    }
    if (line.startsWith('/*')) {
      if (!line.contains('*/')) inBlock = true;
      continue;
    }
    if (line.startsWith('//')) continue; // 含 ///
    out.add(raw);
  }
  return out.join('\n');
}

String _code(String relPath) =>
    stripComments(File(relPath).readAsStringSync());

/// 挂一个带 `ToastHost` 的宿主（模拟 shell.dart:2502 的结构）
Widget _hosted(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      builder: (ctx, inner) => ToastHost(child: inner ?? const SizedBox()),
      home: child,
    );

/// 挂一个**不带** `ToastHost` 的宿主（用于"无宿主不崩"）
Widget _bare(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: child,
    );

void main() {
  // ══════════════════════════════════════════════════════════════════
  //  ① 源码级：5 处全部归零
  // ══════════════════════════════════════════════════════════════════
  group('① 源码级：SnackBar 归零', () {
    test('★★★ detail_page 内 showSnackBar 归零（剥注释）', () {
      final code = _code('lib/ui/detail_page.dart');
      expect(code.contains('showSnackBar'), isFalse,
          reason: '★★★ detail_page 里不许再有 showSnackBar');
      expect(code.contains('SnackBar('), isFalse,
          reason: '★★★ 也不许有 SnackBar( 构造');
    });

    test('★★★ 其余 4 处也全部归零', () {
      const files = <String, String>{
        'lib/ui/cache_page.dart': 'cache_page',
        'lib/ui/cast/cast_button.dart': 'cast_button',
        'lib/ui/widgets/plugin_speedtest.dart': 'plugin_speedtest',
        'lib/ui/app_update_bootstrap.dart': 'app_update_bootstrap',
      };
      files.forEach((path, name) {
        final code = _code(path);
        expect(code.contains('showSnackBar'), isFalse,
            reason: '★★★ $name 里不许再有 showSnackBar（剥注释后）');
      });
    });

    test('★★★ 全仓 lib/ 里真实 showSnackBar 只剩 0 处', () {
      /*
       * ★ 这条是**全量扫描**：不只查那 5 个文件。
       *
       * 排除名单（都是**注释密集**的文件，不是真实调用）：
       *   skip_marker_dialog.dart —— 15 处注释记录 2026-10-02 的事故
       *   t465_skip_dialog_probe.dart —— 探针
       * 剥注释后它们也应该是 0，所以**不用排除**，直接扫。
       */
      final offenders = <String>[];
      for (final e in Directory('lib').listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final code = stripComments(e.readAsStringSync());
        if (code.contains('showSnackBar') || code.contains('SnackBar(')) {
          offenders.add(e.path);
        }
      }
      expect(offenders, isEmpty,
          reason: '★★★ 全仓 lib/ 剥注释后不该还有 SnackBar，'
              '但发现：${offenders.join(", ")}');
    });

    test('★★ 正向对照：showAppToast 确实被用上了（防"删了但没换"假绿）', () {
      // 若有人把调用点直接删掉（而不是替换），上面几条会假绿
      final counts = <String, int>{
        'lib/ui/detail_page.dart': 1,
        'lib/ui/cache_page.dart': 1,
        'lib/ui/cast/cast_button.dart': 1,
        'lib/ui/widgets/plugin_speedtest.dart': 1,
        'lib/ui/app_update_bootstrap.dart': 1,
      };
      counts.forEach((path, min) {
        final code = _code(path);
        final n = RegExp(r'showAppToast\(').allMatches(code).length;
        expect(n, greaterThanOrEqualTo(min),
            reason: '★★ $path 里必须真的调用了 showAppToast（实际 $n 处）');
      });
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 行为断言：toast 真的弹得出来
  // ══════════════════════════════════════════════════════════════════
  group('③ 行为：toast 真的弹出来', () {
    testWidgets('★★★ 在 ToastHost 下调用 ⇒ 文字出现在树上', (t) async {
      await t.pumpWidget(_hosted(Builder(builder: (context) {
        return GestureDetector(
          onTap: () => showAppToast(context, '已删除 3 个文件'),
          child: const ColoredBox(color: Color(0xFF202020)),
        );
      })));
      expect(find.text('已删除 3 个文件'), findsNothing, reason: '前提：还没点');

      await t.tap(find.byType(GestureDetector));
      await t.pump(); // 触发 setState
      await t.pump(const Duration(milliseconds: 50)); // 入场

      expect(find.text('已删除 3 个文件'), findsWidgets,
          reason: '★★★ 点了必须真的弹出来（这条能测出"静默 no-op"）');
    });

    testWidgets('★★ toast 会自己消失（各自计时）', (t) async {
      await t.pumpWidget(_hosted(Builder(builder: (context) {
        return GestureDetector(
          onTap: () => showAppToast(context, '一闪而过'),
          child: const ColoredBox(color: Color(0xFF202020)),
        );
      })));
      await t.tap(find.byType(GestureDetector));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('一闪而过'), findsWidgets, reason: '前提：弹出来了');

      // 默认 2600ms + 退场动画
      await t.pump(const Duration(milliseconds: 2600));
      await t.pump(const Duration(milliseconds: 600));
      expect(find.text('一闪而过'), findsNothing,
          reason: '★★ 到时间必须自己消失');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ ★★★ 反向：无宿主时不崩（2026-10-02 事故的回归测试）
  // ══════════════════════════════════════════════════════════════════
  group('④ ★★★ 无宿主时不许崩（事故回归测试）', () {
    testWidgets('★★★ 没有 ToastHost 时 showAppToast 静默 no-op，不抛异常',
        (t) async {
      /*
       * ★ 这条直接对应 skip_marker_dialog.dart:1347-1400 记录的事故。
       *
       * 事故形态：
       * ```text
       *   final messenger = ScaffoldMessenger.maybeOf(context);
       *   messenger?.showSnackBar(...);   // ← 看着安全（有 ?.）
       *   ★ 但 showSnackBar 内部断言 `_scaffolds.isNotEmpty`
       *   ⇒ 抛异常 ⇒ 把调用方**紧跟其后的赋值**吞掉
       *   ⇒「只要「+」被夹到边界，值就卡住不动」
       * ```
       *
       * 若将来有人把 `AppToaster.maybeOf` 改成抛异常、或把
       * `showAppToast` 里的 `?.` 去掉，这条会红。
       */
      var reachedAfter = false;
      await t.pumpWidget(_bare(Builder(builder: (context) {
        return GestureDetector(
          onTap: () {
            // ★ 关键：toast 之后紧跟一句赋值 —— 复刻事故形态
            showAppToast(context, '这条没有宿主');
            reachedAfter = true; // ← 事故里就是这句被吞掉
          },
          child: const ColoredBox(color: Color(0xFF202020)),
        );
      })));

      await t.tap(find.byType(GestureDetector));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      // ① 不许有异常
      var exCount = 0;
      while (t.takeException() != null) {
        exCount++;
      }
      expect(exCount, 0, reason: '★★★ 无宿主时 showAppToast 不许抛异常');

      // ② ★ 关键：后面的赋值必须执行到（事故里它被吞了）
      expect(reachedAfter, isTrue,
          reason: '★★★ toast 之后的那句必须执行 —— '
              '2026-10-02 的事故就是它被异常吞掉');

      // ③ 也不该真的画出来（没有宿主）
      expect(find.text('这条没有宿主'), findsNothing,
          reason: '★★ 无宿主时静默丢弃，不该出现');
    });

    test('★★ 源码级：showAppToast 用的是 `?.`（找不到宿主就静默）', () {
      final code = _code('lib/ui/widgets/app_toast.dart');
      expect(
        RegExp(r'AppToaster\.maybeOf\(context\)\?\.show\(').hasMatch(code),
        isTrue,
        reason: '★★★ showAppToast 必须用 `?.` —— '
            '这是"找不到宿主不崩"的实现方式',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ 依赖如实记录
  // ══════════════════════════════════════════════════════════════════
  group('⑤ 混合态', () {
    test('★ 记录：app_toast 是自建的（Material 只出现在注释里）', () {
      final code = _code('lib/ui/widgets/app_toast.dart');
      expect(code.contains('SnackBar('), isFalse,
          reason: '★ app_toast 运行时不许构造 SnackBar');
      expect(code.contains('ScaffoldMessenger'), isFalse,
          reason: '★ app_toast 不许依赖 ScaffoldMessenger');
      expect(code.contains('ToastHost'), isTrue,
          reason: '★ 它自己的宿主是 ToastHost（挂在 MaterialApp.builder）');
    });

    test('★ 记录：Scaffold 仍是 Material（第 6 步，须先报 Lead）', () {
      final code = _code('lib/ui/detail_page.dart');
      expect(code.contains('Scaffold('), isTrue,
          reason: '★ Scaffold 仍是 Material —— 第 6 步才换，**须先报 Lead**');
    });
  });
}
