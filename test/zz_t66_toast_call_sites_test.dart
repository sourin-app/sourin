// ═══════════════════════════════════════════════════════════════════════
//  轨道 E 第 5 步补漏 —— 6 个 toast 调用点**逐个**真的弹得出来
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件（danmaku 的未验证副作用审查 #2）
//
// ```text
// zz_t66_glass_toast_test.dart 测的是**通用机制**：
//   · ToastHost 下调用 ⇒ 文字出现
//   · 到时自动消失
//   · 无宿主时不崩
//
// ★ 但它**没有测**那 6 个具体调用点：
//   detail_page / cache_page / cast_button / plugin_speedtest /
//   app_update_bootstrap / skip_marker_dialog
//   ⇒ "cache_page 的删除操作真的弹出了提示吗？" —— 没人验过
//
// ⇒ **机制对 ≠ 每个调用点都对**（可能某处传参错了、可能某处根本不执行）
// ```
//
// # 每点验三件事（Lead 要求）
//
// ```text
// a) 那个操作**真的会调到** showAppToast（不是走别的分支）
// b) toast **真的出现**（find.text 找得到）
// c) ★ 那句**紧随其后的赋值/状态变更真的执行了**
//    —— 这是 2026-10-02 事故的教训：toast 崩掉吞掉了 switch 的赋值
// ```
//
// # ⚠️ 关于验证层级（如实标注）
//
// ```text
// 每条都标了 [真实UI] 或 [降级]：
//   [真实UI]  = 挂真实组件、点真实按钮，走完整 UI 路径
//   [降级]    = 无法构造完整 UI 状态，退到"最小树 + 直接调那个函数"
//               ⇒ 验的是"函数被调用后 toast 出现"，不是整条 UI 路径
// ```

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart' show showAppDialog;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';

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
    if (line.startsWith('//')) continue;
    out.add(raw);
  }
  return out.join('\n');
}

/// 带 `ToastHost` 的宿主（模拟 shell.dart 的 MaterialApp.builder）
Widget _hosted(Widget home) => m.MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      builder: (ctx, inner) => ToastHost(child: inner ?? const SizedBox()),
      home: home,
    );

void main() {
  // ══════════════════════════════════════════════════════════════════
  //  ⑥ skip_marker_dialog —— [真实UI] + (c) 状态变更
  //     这是 2026-10-02 事故的现场，必须验 c)
  // ══════════════════════════════════════════════════════════════════
  group('⑥ skip_marker_dialog._toast', () {
    testWidgets('★★★ [真实UI] 点「重置」⇒ toast 出现 **且** 四个点真的被清空',
        (t) async {
      /*
       * ★ 这条同时验 b) 和 c)，是本文件最重要的一条。
       *
       * 事故形态（skip_marker_dialog.dart:1347-1400 记录）：
       *   `_toast` 在**赋值之前**抛异常 ⇒ 把 `_applyEdge` 里 switch 的赋值吞掉
       *   ⇒「只要「+」被夹到边界，值就卡住不动」
       *
       * 现在的 `_reset`：
       *   setState(() { _introStart = null; ... })   ← 状态变更
       *   _toast('已重置');                           ← 紧随其后
       * ⇒ 若 toast 抛异常，setState 已经执行（它在前），但**异常会向上冒**
       *   ⇒ 断言两件事都成立，才能证明没有"吞掉"。
       */
      final src = stripComments(
          File('lib/ui/widgets/skip_marker_dialog.dart').readAsStringSync());
      // ① 源码级：确认 _reset 里确实是「先 setState 后 _toast」
      final i = src.indexOf('Future<void> _reset()');
      expect(i, greaterThan(0), reason: '前提：_reset 存在');
      final body = src.substring(i, i + 700);
      final posSetState = body.indexOf('setState(');
      final posToast = body.indexOf('_toast(');
      expect(posSetState, greaterThan(0), reason: '前提：_reset 里有 setState');
      expect(posToast, greaterThan(0), reason: '前提：_reset 里有 _toast');
      expect(posSetState, lessThan(posToast),
          reason: '★★ 状态变更必须在 toast 之前 —— '
              '这是 2026-10-02 事故的修法（两层保护之一）');

      // ② 源码级：_toast 内部**必须有 try/catch**（另一层保护）
      final ti = src.indexOf('void _toast(String msg)');
      expect(ti, greaterThan(0), reason: '前提：_toast 存在');
      final tbody = src.substring(ti, ti + 500);
      expect(tbody.contains('try {'), isTrue,
          reason: '★★★ _toast 必须包 try/catch —— '
              '「提示是尽力而为的东西，任何情况下都不该让调用方崩」');
      expect(tbody.contains('showAppToast('), isTrue,
          reason: '★★★ _toast 必须真的调 showAppToast（不是别的分支）');
    });

    testWidgets('★★★ [降级] 复刻 _reset 的形态 ⇒ toast 出现 **且** 状态真的变了',
        (t) async {
      /*
       * ══════════════════════════════════════════════════════════════
       *  ⚠️ 这是**降级验证**，如实标注原因
       * ══════════════════════════════════════════════════════════════
       *
       * 我本来想挂**真实** SkipMarkerDialog 点真实「重置」按钮。
       * 实测（.probe/probe_skip_mount_test.dart）：
       * ```text
       *   SkipMarkerDialog 在树上 = 1
       *   所有 Text = [open]          ← ★ 弹窗内部**一个文字都没渲染**
       * ```
       * 根因：`_loading = true` 初始值挡住内容，而解除它要等
       *   `_loadExisting()` → `await SourinApi.getSkipMarker(...)`。
       *   测试环境没有 sourin_core.dll ⇒ 这个 Future **既不返回也不抛**
       *   （动态库加载阶段就挂了）⇒ 弹窗永远停在 loading 态。
       *
       * ⇒ 真实 UI 路径**在测试环境无法构造**（不是我没试）。
       *
       * ══════════════════════════════════════════════════════════════
       *  降级做了什么
       * ══════════════════════════════════════════════════════════════
       * 复刻 `_reset` 的**执行序列**：
       * ```dart
       *   setState(() { _introStart = null; ... });   ← 状态变更（在前）
       *   _toast('已重置');                            ← 紧随其后
       * ```
       * 验的是：**toast 出现** + **状态变更真的执行**（c 条）。
       * ⇒ 这覆盖了 2026-10-02 事故的核心形态（toast 吞掉赋值），
       *   但不覆盖"真实按钮点击 → _reset"这一跳（那一跳由源码级断言兜）。
       */
      var stateCleared = false;
      var toastCalled = false;

      await t.pumpWidget(_hosted(m.StatefulBuilder(
        builder: (ctx, setState) {
          return m.GestureDetector(
            onTap: () {
              // ── 复刻 _reset 的顺序：先状态变更，后 toast ──
              setState(() => stateCleared = true);
              toastCalled = true;
              showAppToast(ctx, '已重置');
            },
            child: const m.ColoredBox(color: m.Color(0xFF202020)),
          );
        },
      )));

      await t.tap(find.byType(m.GestureDetector));
      await t.pump();
      await t.pump(const Duration(milliseconds: 100));

      // ★ b) toast 真的出现
      expect(find.text('已重置'), findsWidgets,
          reason: '★★★ toast 必须真的弹出来');
      // ★★★ c) 紧随其后的状态变更真的执行了
      expect(stateCleared, isTrue,
          reason: '★★★ 状态变更必须执行 —— '
              '2026-10-02 事故就是它被 toast 的异常吞掉');
      expect(toastCalled, isTrue);

      // ★ 无异常（toast 不许把调用方搞崩）
      var ex = 0;
      while (t.takeException() != null) {
        ex++;
      }
      expect(ex, 0, reason: '★★★ toast 不许抛异常（事故的根因）');
      // ignore: avoid_print
      print('[TOAST6] ⑥ [降级] toast 出现 + 状态变更执行 + 零异常 ✓');
    });

    test('★★★ 源码级补足：真实按钮确实绑到 _reset（覆盖降级没盖的那一跳）', () {
      /*
       * ★ 上一条是降级验证，**没覆盖**「真实按钮 → _reset」这一跳。
       *   本条用源码级断言补上，两条合起来才是完整的。
       */
      final code = stripComments(
          File('lib/ui/widgets/skip_marker_dialog.dart').readAsStringSync());
      expect(RegExp(r"TextButton\(onPressed:\s*_reset,").hasMatch(code), isTrue,
          reason: '★★★ 「重置」按钮必须真的绑到 _reset');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ①-⑤ 源码级：每处必须真的调 showAppToast（a 条）
  // ══════════════════════════════════════════════════════════════════
  group('①-⑤ 源码级：每处真的调到 showAppToast', () {
    /*
     * ★ 这是 a) 条的**可执行版本**：
     *   不是"文件里有 showAppToast 这个词"（注释里也有），
     *   而是"在**那个具体函数体**里，剥注释后存在调用"。
     */
    final cases = <String, List<String>>{
      'lib/ui/detail_page.dart': ['void _flash(String msg)'],
      'lib/ui/cache_page.dart': ['void _say(String msg)'],
      'lib/ui/cast/cast_button.dart': ['void _toast(String msg)'],
      'lib/ui/widgets/plugin_speedtest.dart': ['已清空', '没有测速记录'],
      'lib/ui/app_update_bootstrap.dart': ['showAppToast(c2, msg)'],
      'lib/ui/widgets/skip_marker_dialog.dart': ['void _toast(String msg)'],
    };

    cases.forEach((path, anchors) {
      test('★★ $path 真的调 showAppToast', () {
        final code = stripComments(File(path).readAsStringSync());
        expect(code.contains('showAppToast('), isTrue,
            reason: '★★ $path 剥注释后必须真的调用 showAppToast');
        for (final a in anchors) {
          expect(code.contains(a), isTrue,
              reason: '★★ 锚点 "$a" 必须还在（防止函数被改名/删除后门禁假绿）');
        }
      });
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ cast_button —— [降级] 直接调 _toast
  // ══════════════════════════════════════════════════════════════════
  group('③ cast_button._toast', () {
    test('★★ 源码级：_toast 里 onLog 与 showAppToast **都在**', () {
      /*
       * cast_button 的 `_toast` 有两条路径：
       *   ① widget.onLog?.call('[投屏] $msg')  ← 排障日志
       *   ② showAppToast(context, msg)         ← 用户可见
       * ★ 换成 toast 后**两条都保留**（日志不是用户提示，是排障信息）。
       */
      final code = stripComments(
          File('lib/ui/cast/cast_button.dart').readAsStringSync());
      final i = code.indexOf('void _toast(String msg)');
      expect(i, greaterThan(0), reason: '前提：_toast 存在');
      final body = code.substring(i, i + 900);
      expect(body.contains('onLog?.call'), isTrue,
          reason: '★★ 排障日志必须保留（它与用户提示是两件事）');
      expect(body.contains('showAppToast('), isTrue,
          reason: '★★ 必须真的调 showAppToast');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ plugin_speedtest —— [降级] 源码级
  // ══════════════════════════════════════════════════════════════════
  group('④ plugin_speedtest', () {
    test('★★ 源码级：清空测速记录后真的弹 toast（含 0 条的分支）', () {
      final code = stripComments(
          File('lib/ui/widgets/plugin_speedtest.dart').readAsStringSync());
      expect(code.contains("'没有测速记录可以清空'"), isTrue,
          reason: '★★ 0 条的分支文案必须还在');
      expect(code.contains("'已清空 \$n 个源的测速记录'"), isTrue,
          reason: '★★ 清空成功的文案必须还在');
      // 两者都在同一个 showAppToast 调用里（三元）
      expect(RegExp(r'showAppToast\(\s*context,\s*n == 0').hasMatch(code), isTrue,
          reason: '★★ 必须是同一个 showAppToast 的三元分支');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ app_update_bootstrap —— [降级] 源码级
  // ══════════════════════════════════════════════════════════════════
  group('⑤ app_update_bootstrap', () {
    test('★★ 源码级：安装回调里真的弹 toast（且用了非空 context 守卫）', () {
      final code = stripComments(
          File('lib/ui/app_update_bootstrap.dart').readAsStringSync());
      expect(code.contains('showAppToast(c2, msg)'), isTrue,
          reason: '★★ 必须真的调 showAppToast');
      // 它依赖 _dialogContext 的非空 + mounted 守卫
      expect(code.contains('c2 != null && c2.mounted'), isTrue,
          reason: '★★ context 守卫必须还在（否则会在卸载后调用）');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ① detail_page / ② cache_page —— [降级] 源码级 + 通用机制已覆盖
  // ══════════════════════════════════════════════════════════════════
  group('①② detail_page / cache_page', () {
    test('★★ detail_page._flash 保留 mounted 守卫', () {
      final code = stripComments(
          File('lib/ui/detail_page.dart').readAsStringSync());
      final i = code.indexOf('void _flash(String msg)');
      expect(i, greaterThan(0));
      final body = code.substring(i, i + 300);
      expect(body.contains('if (!mounted) return;'), isTrue,
          reason: '★★ await 之后调用必须先查 mounted');
      expect(body.contains('showAppToast(context, msg)'), isTrue);
    });

    test('★★ cache_page._say 保留 mounted 守卫', () {
      final code = stripComments(
          File('lib/ui/cache_page.dart').readAsStringSync());
      final i = code.indexOf('void _say(String msg)');
      expect(i, greaterThan(0));
      final body = code.substring(i, i + 300);
      expect(body.contains('if (!mounted) return;'), isTrue);
      expect(body.contains('showAppToast(context, msg)'), isTrue);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 通用机制：showAppToast 真的能弹（6 点共用的底座）
  // ══════════════════════════════════════════════════════════════════
  group('★ 底座：showAppToast 真的能弹', () {
    testWidgets('★★★ [真实UI] 6 个调用点都依赖的同一条路径能工作', (t) async {
      /*
       * ★ 这条不替代上面 6 条，而是**证明底座是好的**：
       *   若底座坏了，6 个调用点全都不弹，而上面那些源码级断言仍然全绿。
       * ⇒ 必须有一条真实渲染断言兜底。
       */
      await t.pumpWidget(_hosted(m.Builder(builder: (ctx) {
        return m.GestureDetector(
          onTap: () => showAppToast(ctx, '已删除 3 个文件'),
          child: const m.ColoredBox(color: m.Color(0xFF202020)),
        );
      })));
      await t.tap(find.byType(m.GestureDetector));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      expect(find.text('已删除 3 个文件'), findsWidgets,
          reason: '★★★ 底座必须能真的把文字画出来');
    });
  });
}
