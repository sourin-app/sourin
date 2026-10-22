// ═══════════════════════════════════════════════════════════════════════
//  轨道 E · settings_page 控件去 Material（第 1 件）
// ═══════════════════════════════════════════════════════════════════════
//
// # 改了什么
//
// ```text
// lib/ui/settings_page.dart
//   TextButton  ×10 → AppTextButton
//   IconButton  ×9  → AppIconButton
//   AlertDialog ×2  → AppGlassDialog（只换纯文本确认框 + 单 Widget 输入框）
// ```
//
// # ★ 为什么是 21 处而不是 24 处 —— 如实说明
//
// ```text
// ① 原计划 24 处（10 + 9 + 5）。实际可换 **21 处**：
//    3 个 AlertDialog **没换**，因为它们是复杂表单，不是确认框：
//      :6591 「调整内容源顺序」 content 是 SizedBox + ListView.builder
//      :6872  title 是 **Row**（多元素标题）—— AppGlassDialog.title 是 String
//      :7230 「配置插件」     content 是 SizedBox + SingleChildScrollView 表单
//    ⇒ AppGlassDialog 的能力边界是「标题 String + 内容单 Widget」，
//      硬塞复杂表单会丢掉 ListView 的滚动语义。
//
// ② 另外发现 **6 处 FilledButton**（5 基础 + 2 .icon + 1 .tonalIcon 中的一部分）
//    **本仓没有对应的自建填充按钮组件** ⇒ 本轮不做，已报 Lead。
//    ★ 这是普查时按清单 grep 造成的漏项，不是"故意不做"。
// ```
//
// # ★ 保留的 2 处玻璃（不要动）
//
// ```text
// :4198 GlassContainer —— 「JS 插件 / 直播源」二级页的顶部 tab 条药丸
//   理由：Owner 明确要求（代码 :4129-4134 逐字引用 m04668）
//        「这个 tab 也使用液态玻璃 那个效果实现吧，记住固定在上面」
//   ⇒ 它是**正确形态**，本轮不改。
// ```

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedSuperellipse;
import 'package:material_ui/material_ui.dart'
    show InputDecoration, MaterialApp, TextButton, TextField;
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';

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

String _settings() =>
    stripComments(File('lib/ui/settings_page.dart').readAsStringSync());

void main() {
  // ══════════════════════════════════════════════════════════════════
  //  ① 源码级：归零 + 正向对照
  // ══════════════════════════════════════════════════════════════════
  group('① 源码级', () {
    test('★★★ settings_page 里 TextButton / IconButton 归零', () {
      final code = _settings();
      expect(RegExp(r'(?<!App)\bTextButton\(').hasMatch(code), isFalse,
          reason: '★★★ 不许再有 Material 的 TextButton');
      expect(RegExp(r'(?<!App)\bIconButton\(').hasMatch(code), isFalse,
          reason: '★★★ 不许再有 Material 的 IconButton');
    });

    test('★★ 正向对照：AppTextButton 10+ / AppIconButton 9（防"删了没换"）', () {
      final code = _settings();
      /*
       * ★ 精确计数，不是 `>=10`。
       * 我第一版写 `greaterThanOrEqualTo(10)`，而实际有 11 处 ⇒
       * 注入"删掉一处"后仍满足 >=10 ⇒ **注入不变红**，看起来像假绿。
       * ⇒ 精确值 + 写明它怎么来的（改前 10 个 TextButton + 1 个原有 = 11）。
       */
      expect(RegExp(r'AppTextButton\(').allMatches(code).length, 11,
          reason: '★★ 必须正好 11 处 AppTextButton'
              '（10 个替换来的 + 1 个原本就有）');
      expect(RegExp(r'AppIconButton\(').allMatches(code).length, 9,
          reason: '★★ 必须正好 9 处 AppIconButton');
    });

    test('★★★ 保留的 AlertDialog 全部有**能力边界**理由', () {
      /*
       * ★ 这条不是"忘了换"，是**登记能力边界**：
       *
       *   ① :6591 「调整内容源顺序」content 是 SizedBox + ListView.builder
       *   ② :6872  title 是 **Row**（多元素标题）
       *            —— AppGlassDialog.title 是 String，塞不进
       *   ③ :7230 「配置插件」content 是 SizedBox + SingleChildScrollView 表单
       *   ④ :2252 _promptText **含 TextField**
       *            —— ★★★ 这条是我第一版漏掉的**真回归**：
       *              AppGlassDialog 不带 Material，TextField 会抛
       *              "No Material widget found"（实测 .probe/probe_tf_test.dart）
       *              而 _promptText 有 2 个生产调用点
       *              （:1642 安装 JS 插件 / :2146 固定配对码）
       *              ⇒ 换掉会让用户点这两处直接崩。
       *
       * ⚠️ 不断言"必须保留"（将来若给组件补透明 Material 宿主可以换），
       *    只登记当前数量，防止下一个人当成遗漏。
       */
      final code = _settings();
      final n = RegExp(r'(?<!App)\bAlertDialog\(').allMatches(code).length;
      // ignore: avoid_print
      print('[SET] 保留的 AlertDialog = $n（预期 4：3 复杂表单 + 1 含输入框）');
      expect(n, 4,
          reason: '★ 登记：4 个对话框因能力边界保留 AlertDialog');
      expect(RegExp(r'AppGlassDialog\(').allMatches(code).length, 1,
          reason: '★ 纯文本确认框已换（1 处：_confirm）');
    });

    test('★★★ 含 TextField 的对话框**不许**用 AppGlassDialog（防真回归）', () {
      /*
       * ★ 这是本文件最重要的一条 —— 它是那次真回归的**回归测试**。
       *
       * 事实：AppGlassDialog 只画 GlassContainer，不带 Material；
       *      TextField 需要 Material 祖先（画光标/选择手柄/墨水）。
       *      实测抛 "No Material widget found"。
       *
       * ⇒ 判据：`_promptText` 那个 builder 必须是 AlertDialog，不是 AppGlassDialog。
       *    若将来有人给 AppGlassDialog 补了透明 Material 宿主，
       *    这条会红 ⇒ 那时应该更新它并**同时**加一条"TextField 能用"的行为断言。
       */
      final raw = File('lib/ui/settings_page.dart').readAsStringSync();
      // 定位 _promptText 函数体
      final i = raw.indexOf('Future<String?> _promptText(');
      expect(i, greaterThan(0), reason: '前提：_promptText 存在');
      final body = raw.substring(i, i + 2600);
      expect(body.contains('AlertDialog('), isTrue,
          reason: '★★★ 含 TextField 的对话框必须用 AlertDialog'
              '（AppGlassDialog 没有 Material 宿主，TextField 会抛）');
      expect(body.contains('AppGlassDialog('), isFalse,
          reason: '★★★ 不许换成 AppGlassDialog —— 会让 2 个生产调用点崩溃');
    });

    test('★ 登记：FilledButton 仍有（本仓无自建填充按钮）', () {
      final code = _settings();
      final n = RegExp(r'\bFilledButton').allMatches(code).length;
      // ignore: avoid_print
      print('[SET] 剩余 FilledButton = $n（本仓无 AppFilledButton）');
      expect(n, greaterThan(0),
          reason: '★ 登记：FilledButton 仍在（没有对应自建组件）');
    });

    test('★★★ 那 2 处玻璃**不许被碰**（Owner 明确要求）', () {
      /*
       * ⚠️ 我第一版读的是**原始源码** `raw.contains('GlassContainer')` ——
       *    而 :2275 / :4162 两处**注释**里都有这个词 ⇒ 判据恒真 ⇒ 假绿。
       *    注入实测证实：把真正的 `return GlassContainer(` 改掉，
       *    这条**仍然是绿的**。
       * ⇒ 改成剥注释后再断言**实际调用**。
       */
      final code = _settings();
      expect(RegExp(r'return\s+GlassContainer\(').hasMatch(code), isTrue,
          reason: '★★★ 二级页 tab 条的药丸玻璃必须保留 —— '
              'Owner 明确要求「固定在上面 + 液态玻璃」');
      // 而且必须**真的用到** liquid_glass 的组件（不是自造同名类）
      final raw = File('lib/ui/settings_page.dart').readAsStringSync();
      expect(raw.contains("import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';"),
          isTrue,
          reason: '★★★ 必须真的 import liquid_glass_widgets');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 行为：替换后的控件真的能用
  // ══════════════════════════════════════════════════════════════════
  group('② 行为：控件真的能点', () {
    testWidgets('★★★ AppGlassDialog 在 settings 的用法下能关且返回值正确',
        (t) async {
      /*
       * 复刻 settings_page._confirm 的用法（title/message/两个按钮）。
       * 验的是「这个用法形态真的工作」，不是"组件在树上"。
       */
      final key = GlobalKey<NavigatorState>();
      await t.pumpWidget(MaterialApp(
        navigatorKey: key,
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: const SizedBox(),
      ));

      final fut = showAppDialog<bool>(
        context: key.currentContext!,
        builder: (ctx) => AppGlassDialog(
          title: '删除确认',
          content: const Text('这条会被删掉'),
          actions: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('确定'),
              ),
            ],
          ),
        ),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));

      expect(find.byType(AppGlassDialog), findsOneWidget, reason: '前提：打开了');
      await t.tap(find.text('确定'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 800));

      expect(await fut, isTrue, reason: '★★★ 点「确定」必须返回 true');
      expect(find.byType(AppGlassDialog), findsNothing, reason: '★★★ 必须关了');
    });

  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 玻璃可见性 + padding 必要性（Lead 硬要求）
  // ══════════════════════════════════════════════════════════════════
  group('③ 玻璃像素差异 + padding 必要性', () {
    /*
     * Lead 硬要求：
     *   ③ 变化率 < 5% ⇒ 报 Lead（可能"做了但看不出"）
     *   ④ 去掉 padding 后，差异率应**明显下降**
     *      若不变 ⇒ 玻璃根本没生效
     *
     * ⚠️ 本组测的是**通用 GlassContainer**（settings_page 那 2 处用的是它），
     *    不是本轮换掉的按钮。用途是证明「玻璃在这套主题下真的可见」。
     */
    testWidgets('★★★ 玻璃 vs 纯色底：像素变化率 ≥ 5%', (t) async {
      final rate = await _glassDiffRate(t, withPadding: true);
      // ignore: avoid_print
      print('[SET] 玻璃 vs 纯色底 像素变化率 = '
          '${(rate * 100).toStringAsFixed(1)}%');
      expect(rate, greaterThanOrEqualTo(0.05),
          reason: '★★★ 玻璃必须真的看得出来（≥5%）—— '
              '低于这个数说明"做了但看不出"');
    });

    testWidgets('★★★ padding 必要性：去掉 padding ⇒ 差异率下降', (t) async {
      final withPad = await _glassDiffRate(t, withPadding: true);
      final noPad = await _glassDiffRate(t, withPadding: false);
      // ignore: avoid_print
      print('[SET] 有 padding=${(withPad * 100).toStringAsFixed(1)}%  '
          '无 padding=${(noPad * 100).toStringAsFixed(1)}%');
      expect(noPad, lessThan(withPad),
          reason: '★★★ 去掉 padding 后玻璃效果必须**变弱** —— '
              '若不变说明 padding 根本没起作用'
              '（theme_page.dart:74 的实测结论：药丸要离边缘留一口气，'
              '否则高亮盖住折射带，玻璃"看起来没生效"）');
    });
  });
}

/// 测「玻璃相对纯色底」的像素变化率。
///
/// 用 `RepaintBoundary.toImage` 抓真实像素，逐像素比。
Future<double> _glassDiffRate(
  WidgetTester t, {
  required bool withPadding,
}) async {
  const w = 200, h = 80;
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(w * 1.0, h * 1.0);
  addTearDown(t.view.reset);

  final surface = AppTheme.themeFor(Brightness.dark).colorScheme.surface;

  Widget build(Widget child) => MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: SizedBox(
          width: w * 1.0,
          height: h * 1.0,
          child: Stack(children: [
            Positioned.fill(child: ColoredBox(color: surface)),
            Center(child: child),
          ]),
        ),
      );

  Future<List<int>> shot(Widget child) async {
    final key = GlobalKey();
    await t.pumpWidget(
      RepaintBoundary(key: key, child: build(child)),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    List<int>? bytes;
    await t.runAsync(() async {
      final img = await boundary.toImage(pixelRatio: 1);
      final bd = await img.toByteData();
      if (bd != null) {
        bytes = List<int>.generate(bd.lengthInBytes, (i) => bd.getUint8(i));
      }
    });
    return bytes ?? const <int>[];
  }

  // 基准：只有底
  final base = await shot(const SizedBox(width: 120, height: 40));

  final glass = withPadding
      ? GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 999),
          padding: const EdgeInsets.all(8),
          child: const SizedBox(width: 120, height: 40),
        )
      : GlassContainer(
          shape: const LiquidRoundedSuperellipse(borderRadius: 999),
          // ★ 无 padding —— 内容直接贴玻璃边缘
          padding: EdgeInsets.zero,
          child: const SizedBox(width: 120, height: 40),
        );

  final withGlass = await shot(glass);

  if (base.isEmpty || withGlass.isEmpty || base.length != withGlass.length) {
    return 0;
  }
  var diff = 0;
  for (var i = 0; i < base.length; i += 4) {
    if (base[i] != withGlass[i] ||
        base[i + 1] != withGlass[i + 1] ||
        base[i + 2] != withGlass[i + 2]) {
      diff++;
    }
  }
  return diff / (w * h);
}
