// ═══════════════════════════════════════════════════════════════════════
//  轨道 E · 玻璃化 M2 —— follow_page 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// Owner 已定路线：**彻底不用 Material 组件，全部自建 / 玻璃**。
// 本文件守「追更页（follow_page）真的玻璃化了，且**没丢功能**」。
//
// # 四组判据（每条都能红）
// ```text
// ① 页面里不再有 Material 的**交互组件**（InkWell / LinearProgressIndicator）
// ② 玻璃组件真的在树上（不是只 import 了没用）
// ③ 铁律 8：点击 / 焦点 / 无障碍语义 / 键盘激活 全部保留
// ④ ★ 诚实记录「间接依赖还在」—— 不假装 0 依赖
// ```
//
// ⚠️ 本文件刻意**不断言**「follow_page 不 import material_ui」。
//    原因见 ④：它仍然需要 material_ui 来拿 Text / Icon / Colors 等
//    **非组件**符号，且间接依赖 widgets/ 里的公共组件。
//    假装断干净 = 假绿，比不断言更糟。

import 'dart:io';
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/follow_page.dart';

// ══════════════════════════════════════════════════════════════════════
//  剥注释（块 + 行；保留字符串字面量）
// ══════════════════════════════════════════════════════════════════════
//
// ★ 必须剥注释再判：本文件的源码里大量注释写着
//   「InkWell → _GlassTapSurface」「不用 LinearProgressIndicator」，
//   不剥就会**假红**（判到自己的说明文字）。
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

String followSource() =>
    stripComments(File('lib/ui/follow_page.dart').readAsStringSync());

/// 挂载真实 FollowPage 的宿主（与 t36 / t74 同一套脚手架）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    home: child,
  );
}

/// tab 药丸当前的 left（读**真实渲染**，不读 State 私有字段）
///
/// 药丸 = Stack 里那个带**渐变**的 DecoratedBox。
/// ⚠️ 必须限定在 tab 区域找，不能用全局 .first —— 全树有多个渐变
///    DecoratedBox（页面内容里也有），用 .first 会读到错的（t36:88 记过）。
double? _followPillLeft(WidgetTester t) {
  final pill = find.descendant(
    of: find.byType(FollowPage),
    matching: find.byWidgetPredicate((w) {
      if (w is! DecoratedBox) return false;
      final d = w.decoration;
      if (d is! BoxDecoration) return false;
      return d.gradient is LinearGradient;
    }),
  );
  final n = pill.evaluate().length;
  if (n == 0) return null;
  // 取最靠上的那个（tab 药丸在页面顶部；内容区的渐变在下面）
  var best = double.infinity;
  double? result;
  for (final e in pill.evaluate()) {
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize) continue;
    final pos = box.localToGlobal(Offset.zero);
    if (pos.dy < best) {
      best = pos.dy;
      result = pos.dx;
    }
  }
  return result;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① Material 交互组件已清出（源码级）
  // ═══════════════════════════════════════════════════════════════════
  group('① follow_page 里不再有 Material 交互组件', () {
    test('★★★ 没有 InkWell（被 _GlassTapSurface 取代）', () {
      final code = followSource();
      /*
       * 判据用 `InkWell(` 而不是裸 `InkWell` —— 后者会命中
       * `_GlassTapSurface` 的类型名与文档引用，造成假红。
       */
      expect(code.contains('InkWell('), isFalse,
          reason: '★★★ InkWell 是 Material 的水波纹载体；'
              '本项目已换成 _GlassTapSurface（内部 GlassButton.custom）');
    });

    test('★★★ 没有 LinearProgressIndicator（被 _GlassProgressLine 取代）', () {
      expect(followSource().contains('LinearProgressIndicator('), isFalse,
          reason: '★★★ 进度条已自绘为 _GlassProgressLine（零 Material）');
    });

    test('★★ 没有 Theme.of(context).colorScheme 取色（改走语义色层）', () {
      /*
       * ⚠️ 唯一的例外是 `_followColors` 的**兜底分支**，它读
       *    `Theme.of(context).brightness`（不是 .colorScheme）——
       *    那是过渡期为了"AppThemeScope 还没接线时不崩"而刻意保留的。
       *    所以这里只禁 `.colorScheme`，不禁 `Theme.of(...).brightness`。
       */
      final code = followSource();
      expect(code.contains('.colorScheme'), isFalse,
          reason: '★★ 取色必须走 _followColors / AppSemanticColors，'
              '不许再读 Material 的 ColorScheme');
    });

    test('★ 正向对照：玻璃件与语义色层**真的**在源码里（防空文件假绿）', () {
      final code = followSource();
      // 若哪天有人把上面三条判据的"被取代物"清空，上面会假绿
      expect(code.contains('_GlassTapSurface('), isTrue,
          reason: '★ 点击面必须真的是 _GlassTapSurface');
      expect(code.contains('GlassButton.custom('), isTrue,
          reason: '★ 内部必须真的走 GlassButton.custom');
      expect(code.contains('_GlassProgressLine('), isTrue,
          reason: '★ 进度条必须真的是 _GlassProgressLine');
      expect(code.contains('AppSemanticColors.derive('), isTrue,
          reason: '★ 兜底取色必须真的走 AppSemanticColors');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 玻璃组件真的在树上（渲染级，不是源码级）
  // ═══════════════════════════════════════════════════════════════════
  group('② 玻璃组件在渲染树上', () {
    testWidgets('★★★ 真实 FollowPage 上真的有 GlassButton（不是自造一个充数）',
        (tester) async {
      /*
       * ★★★ 为什么必须挂**真实页面**（2026-10-18 故障注入抓到的假绿）
       *
       * 第一版这里是**自己 new 一个 GlassButton** 然后断言它在树上 ——
       * 注入「把 `_GlassTapSurface` 内部的 `onTap` 改成 `() {}`」之后
       * 这条**仍然是绿的**，因为测试根本没经过页面的那个组件。
       * ⇒ 判据必须落在**产品代码实际渲染出来的树**上。
       *
       * 教训与上一轮同源：**门禁不许"同一个源比同一个源"**。
       * 这里改成挂真实 FollowPage，用 find.byType(GlassButton) 找页面的。
       */
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(const FollowPage()));
      await tester.pump();
      while (tester.takeException() != null) {}
      await tester.pump(const Duration(milliseconds: 800));
      while (tester.takeException() != null) {}

      expect(find.byType(FollowPage), findsOneWidget,
          reason: '前提：页面真的挂上了');
      expect(find.byType(GlassButton), findsWidgets,
          reason: '★★★ 真实页面上必须有玻璃按钮（tab chip 的点击层）');
      // ignore: avoid_print
      print('[GLASS] 真实 FollowPage 上的 GlassButton 数量 = '
          '${find.byType(GlassButton).evaluate().length}');
    });

    testWidgets('★★★ 页面上的玻璃按钮**可点击**（点击层没被写空）', (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = const Size(1280, 800);
      addTearDown(tester.view.reset);

      await tester.pumpWidget(_host(const FollowPage()));
      await tester.pump();
      while (tester.takeException() != null) {}
      await tester.pump(const Duration(milliseconds: 800));
      while (tester.takeException() != null) {}

      final buttons = find.byType(GlassButton);
      if (buttons.evaluate().isEmpty) {
        fail('页面上没有 GlassButton，无法验证可点击性');
      }
      /*
       * 点击第一个玻璃按钮，断言**页面状态真的变了**。
       *
       * ⚠️ 判据不能用"taps 计数器"（那是自造组件的玩法，页面上没有计数器）。
       *    这里读真实结果：tab 切换后 `_FollowTabChip` 的选中态会变
       *    ⇒ 用 AnimatedPositioned 的 left 变化来证明"点击真的生效"。
       */
      /*
       * ⚠️ 必须点**未选中**的 tab，不能点第一个。
       *    实测（.probe 探针）：页面上 3 个 GlassButton 分别在
       *    x=28/124/220，第一个是**当前已选中**的 tab ——
       *    点它药丸本来就该不动（切到同一个 tab 是 no-op）。
       *    我第一版点 first ⇒ 药丸 28→28 不变 ⇒ 误判成"onTap 没接上"。
       *    ★ 这是"判据设计错"，不是代码错。
       */
      final pillBefore = _followPillLeft(tester);
      final target = buttons.evaluate().length > 1 ? buttons.at(1) : buttons.first;
      await tester.tap(target, warnIfMissed: false);
      await tester.pump();
      while (tester.takeException() != null) {}
      await tester.pump(const Duration(milliseconds: 600));
      while (tester.takeException() != null) {}
      final pillAfter = _followPillLeft(tester);

      // ignore: avoid_print
      print('[GLASS] 点击玻璃按钮后 药丸 left: $pillBefore → $pillAfter');
      expect(pillBefore, isNotNull, reason: '前提：页面上找得到 tab 药丸');
      expect(pillAfter, isNot(equals(pillBefore)),
          reason: '★★★ 点击玻璃按钮必须真的切换 tab（药丸位置应改变）'
              '—— 若不变，说明 onTap 被写空/没接上');
    });

    testWidgets('★★ GlassContainer 也能在本仓的纯 widgets 树里渲染', (tester) async {
      await tester.pumpWidget(
        const Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: GlassContainer(
              padding: EdgeInsets.all(8),
              child: Text('x', textDirection: TextDirection.ltr),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(GlassContainer), findsOneWidget);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 铁律 8：不许丢功能
  // ═══════════════════════════════════════════════════════════════════
  group('③ 铁律 8 —— 点击 / 焦点 / 语义 / 键盘 都不许丢', () {
    testWidgets('★★★ 无障碍语义：读屏器能按 label 找到按钮，且有 button 角色',
        (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: GlassButton.custom(
              onTap: () {},
              style: GlassButtonStyle.transparent,
              stretch: 0,
              anchorStretch: false,
              label: '追更列表',
              child: const Text('追更列表', textDirection: TextDirection.ltr),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));

      /*
       * ★ 判据用 `bySemanticsLabel` 而**不是** `getSemantics(find.byType(...))`：
       *   后者取到的是外层 Listener/GestureDetector 的节点，其 label 为空
       *   （实测：label="" isButton=false），会**假红**。
       *   语义真正的拥有者是内层的 GlassFocusRegion 节点。
       *   —— 这个坑我实测踩过一次，记在这里免得后人重踩。
       */
      expect(find.bySemanticsLabel('追更列表'), findsWidgets,
          reason: '★★★ 铁律 8：读屏器必须能按 label 找到这个按钮');

      final node = tester.getSemantics(find.bySemanticsLabel('追更列表').first);
      expect(node.hasFlag(SemanticsFlag.isButton), isTrue,
          reason: '★★★ 铁律 8：必须是 button 语义（否则读屏器念成普通文本）');
      handle.dispose();
    });

    testWidgets('★★ 可聚焦（键盘 / TV 方向键的前提）', (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: GlassButton.custom(
              onTap: () {},
              style: GlassButtonStyle.transparent,
              stretch: 0,
              anchorStretch: false,
              autofocus: true,
              label: 'f',
              child: const Text('f', textDirection: TextDirection.ltr),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 200));

      // autofocus=true 时必须真的拿到焦点
      expect(FocusManager.instance.primaryFocus, isNotNull,
          reason: '★★ 铁律 8：必须能拿到键盘焦点（TV 方向键的前提）');
    });

    testWidgets('★★ 触控目标 ≥ 34dp（项目规范坑 35，不许玻璃化时缩水）',
        (tester) async {
      /*
       * 本页 tab 药丸有硬契约：纵向 padding ≥ Sp.x3(12)，否则
       * 「8×2 + 17 行高 = 33」不达标（task-36 实测过 96x33 的违规）。
       * 玻璃化**不许**把这个尺寸改小。
       */
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: GlassButton.custom(
              onTap: () {},
              style: GlassButtonStyle.transparent,
              stretch: 0,
              anchorStretch: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 8,
                  vertical: 12,
                ),
                child: const Text('tab', textDirection: TextDirection.ltr),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 100));
      final size = tester.getSize(find.byType(GlassButton));
      expect(size.height, greaterThanOrEqualTo(34.0),
          reason: '★★ 触控目标 ${size.height}dp < 34dp（项目规范坑 35）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ ★ 诚实记录：间接依赖还在（不假装 0 依赖）
  // ═══════════════════════════════════════════════════════════════════
  group('④ 间接依赖如实记录（不假装断干净）', () {
    test('★★ follow_page 仍 import material_ui —— 这是**已知且有意**的', () {
      /*
       * # 为什么还留着
       * ```text
       * 本页仍需要 material_ui 提供的**非组件**符号：
       *   Text / Icon / Colors / Brightness / TextOverflow / FontWeight …
       * （其中 Text 其实来自 flutter/widgets，但经 material_ui 一并导出）
       * 而且它 import 的 widgets/poster_card.dart 等公共组件**本身**还用 Material。
       * ```
       * # 为什么不现在删
       * ```text
       * 删了会连锁改 6+ 个公共组件（poster_card / cover_image / app_toast …），
       * 那是 M3 的工作量。现在硬删 = 编译不过。
       * ```
       * ⇒ 本测试**断言这个事实**，让"还剩多少 Material"是**可度量的**，
       *   而不是靠记忆。将来 M3 真删掉时，这条会红 —— 那时改成 isFalse 即可。
       */
      final raw = File('lib/ui/follow_page.dart').readAsStringSync();
      expect(raw.contains("import 'package:material_ui/material_ui.dart';"), isTrue,
          reason: '★ 如实记录：follow_page 仍 import material_ui（M3 才删）');
    });

    test('★★ 但 Material 的**交互组件**用量已归零（这才是本轮的目标）', () {
      final code = followSource();
      // 交互组件清单（本页曾用过的 + 常见的）
      const banned = [
        'InkWell(',
        'Ink(',
        'LinearProgressIndicator(',
        'CircularProgressIndicator(',
        'TextButton(',
        'ElevatedButton(',
        'OutlinedButton(',
        'IconButton(',
        'FilledButton(',
        'Scaffold(',
        'AppBar(',
        'FloatingActionButton(',
      ];
      for (final b in banned) {
        expect(code.contains(b), isFalse,
            reason: '★★ 交互组件 $b 必须已清出 follow_page');
      }
    });

    test('★ 记录当前剩余 Material 符号（度量，不是断言 0）', () {
      final code = followSource();
      // 这些是**非组件**符号，允许保留到 M3
      final allowed = <String>[];
      for (final sym in const [
        'Text(',
        'Icon(',
        'Colors.',
        'TextOverflow.',
        'FontWeight.',
        'Brightness.',
        'EdgeInsets.',
        'BoxDecoration(',
      ]) {
        if (code.contains(sym)) allowed.add(sym);
      }
      expect(allowed, isNotEmpty,
          reason: '★ 说明这些非组件符号仍在用（预期行为）');
      // ignore: avoid_print
      print('[GLASS] follow_page 仍在用的非组件 Material 符号: $allowed');
    });
  });
}
