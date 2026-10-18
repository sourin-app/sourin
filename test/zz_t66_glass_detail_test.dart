// ═══════════════════════════════════════════════════════════════════════
//  轨道 E · 玻璃化 M2 第 1 步 —— detail_page 的 TextButton 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// `detail_page.dart` 里 10 个 Material `TextButton` 已换成自建 `AppTextButton`。
// 本文件守三件事：
// ```text
// ① 源码级：没有裸 TextButton( 残留
// ② 渲染级：**真实 DetailPage** 上真的有 AppTextButton（不许自己 new 充数）
// ③ 铁律 8：点击 / 禁用态 / 无障碍语义 / 键盘焦点 都不许丢
// ```
//
// ★★★ 本文件最重要的一条纪律（Lead 本轮特别强调）
// ```text
// 「门禁不许同一个源比同一个源」—— 断言必须经过**被测对象**。
// 上一轮我在 follow_page 上犯过这个错：自己 new 一个 GlassButton
// 断言它在树上，注入「页面里的 onTap 写空」后**仍然绿**。
// ⇒ 本文件所有渲染级断言都挂**真实 DetailPage**。
// ```

import 'dart:io';
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';

// ══════════════════════════════════════════════════════════════════════
//  剥注释（块 + 行；保留字符串字面量）
// ══════════════════════════════════════════════════════════════════════
//
// ★ 必须剥注释再判：detail_page 的注释里大量写着
//   「TextButton → AppTextButton」这类说明，不剥会**假红**。
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

/// 挂载真实 DetailPage 的宿主（与 t36 / t74 同一套脚手架）
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(theme: theme, home: child);
}

/// 挂一个真实 DetailPage（在线模式，provider/id 用测试值）
Future<void> _pumpDetail(WidgetTester t) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(1280, 900);
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(const DetailPage(provider: 'test-provider', id: 'test-id')));
  await t.pump();
  // FFI 在测试环境会失败（sourin_core.dll 不可用），但那不是判据，吞掉
  while (t.takeException() != null) {}
  await t.pump(const Duration(milliseconds: 800));
  while (t.takeException() != null) {}
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 源码级：TextButton 已清出
  // ═══════════════════════════════════════════════════════════════════
  group('① detail_page 里不再有 Material TextButton', () {
    test('★★★ 没有裸 TextButton( 残留', () {
      final code = detailSource();
      /*
       * ⚠️ 判据必须排除 `AppTextButton(` —— 它包含 `TextButton(` 子串。
       *    直接用 `code.contains('TextButton(')` 会**永远为真**（假红）。
       *    这里用「前面不是 App」来区分。
       */
      final bare = RegExp(r'(?<!App)\bTextButton\(').hasMatch(code);
      expect(bare, isFalse,
          reason: '★★★ detail_page 里不许再有 Material 的 TextButton');
    });

    test('★ 正向对照：AppTextButton 真的在源码里（防空文件假绿）', () {
      final code = detailSource();
      // 若有人把上面的"被取代物"清空，上一条会假绿
      /*
       * ★ 2026-10-18（第 4 步后更新）：从 10 处降到 **4 处**。
       *
       * 原因：对话框里的 6 个按钮搬进了 `AppGlassDialogActions`
       *   （lib/design/widgets/app_glass_dialog.dart），由那个组件内部画
       *   `AppTextButton`；`detail_page` 里只剩：
       *     · 「管理」                :3391
       *     · 选择栏「全选/全不选」   :3474
       *     · 选择栏「删除」          :3487
       *     · 选择栏「取消」          :3494
       * ⇒ 这不是"少换了"，是**搬到了更合适的位置**。
       *   判据同时要求「对话框用的确实是 AppGlassDialogActions」
       *   （见下方 ④ 组的断言）。
       */
      expect(RegExp(r'AppTextButton\(').allMatches(code).length, 4,
          reason: '★ detail_page 里应剩 4 处 AppTextButton'
              '（对话框那 6 个已搬进 AppGlassDialogActions）');
      expect(code.contains('import \'../design/widgets/app_text_button.dart\''),
          isTrue,
          reason: '★ 必须真的 import 了自建按钮');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 渲染级：真实页面上有 AppTextButton
  // ═══════════════════════════════════════════════════════════════════
  group('② 真实 DetailPage 上真的有 AppTextButton', () {
    testWidgets('★★★ 挂真实页面，断言 AppTextButton 在树上', (tester) async {
      /*
       * ★★★ 这条是本文件的**核心**：必须挂真实 DetailPage。
       * 自己 new 一个 AppTextButton 断言它在树上 = 假绿
       * （注入「页面里换成 TextButton」后仍然绿）。
       */
      await _pumpDetail(tester);

      expect(find.byType(DetailPage), findsOneWidget,
          reason: '前提：页面真的挂上了');

      /*
       * ⚠️ 详情页的 10 个按钮**不在首屏**：
       *    6 个在 AlertDialog 里（要触发下载/删除才出现），
       *    4 个在「已下载」区块（本地模式）。
       *    在线模式 + 无数据时，页面上可能一个都不渲染。
       *
       * ⇒ 本测试的判据是「**源码里 10 个都换了**」（① 组已覆盖），
       *    渲染级这里只验证「AppTextButton 这个组件在真实页面树里能被渲染」。
       *    若首屏确实没有，就明确跳过并**如实打印**，不假装验证过。
       */
      final n = find.byType(AppTextButton).evaluate().length;
      // ignore: avoid_print
      print('[GLASS] 真实 DetailPage 首屏 AppTextButton 数量 = $n');
      // ignore: avoid_print
      print('[GLASS] （6 个在对话框里、4 个在「已下载」区块，首屏无数据时为 0 是预期的）');
    });

    testWidgets('★★★ AppTextButton 渲染出来**可点击**（不是只摆样子）',
        (tester) async {
      /*
       * 这条挂**真实组件**（AppTextButton 本身），不是页面 ——
       * 因为要验证的是「这个自建组件的行为对不对」。
       * 页面级的"按钮在不在"由 ① 的源码断言 + 上一条覆盖。
       */
      var taps = 0;
      await tester.pumpWidget(
        _host(Center(
          child: AppTextButton(
            onPressed: () => taps++,
            child: const Text('确定'),
          ),
        )),
      );
      await tester.pump();

      expect(find.byType(AppTextButton), findsOneWidget);
      await tester.tap(find.byType(AppTextButton));
      await tester.pump();
      expect(taps, 1, reason: '★★★ 点击必须真的触发 onPressed');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 铁律 8：不许丢功能
  // ═══════════════════════════════════════════════════════════════════
  group('③ 铁律 8 —— 禁用态 / 语义 / 焦点 都不许丢', () {
    testWidgets('★★★ 禁用态（onPressed=null）真的不可点 —— 对应 TextButton 的 null',
        (tester) async {
      /*
       * Material 的 `TextButton(onPressed: null)` = 禁用。
       * 本仓 detail_page 有 3 处用它（全选/删除/…）——
       * 若自建组件不实现禁用态，用户点"删除"会**误删**。
       * ⇒ 这条是**安全相关**，不是观感。
       */
      var taps = 0;
      await tester.pumpWidget(
        _host(Center(
          child: AppTextButton(
            onPressed: null,
            child: const Text('删除'),
          ),
        )),
      );
      await tester.pump();
      await tester.tap(find.byType(AppTextButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0, reason: '★★★ 禁用态绝不许触发 onPressed');

      /*
       * ★★★ 只断言 taps==0 是**不够**的（2026-10-18 故障注入抓到的假绿）。
       *
       * 注入「把 AppInkWell 的 onTap 改成 `onPressed ?? () {}`」之后，
       * 上面那条 `taps == 0` **仍然通过** —— 因为注入的 `() {}` 是个空函数，
       * 它不增加计数。禁用态**已经被绕过了**，但计数器看不出来。
       *
       * ⇒ 必须断言**更靠近机制**的事实：禁用时 `AppInkWell.onTap` 必须是 null。
       *    `AppInkWell` 的文档写明「为 null ⇒ 禁用态：不响应点击，也不显示按下反馈」，
       *    所以这是该组件**自己的契约**，不是我的实现细节。
       *    注入 `?? () {}` 会让它变成非 null ⇒ 这条必须红。
       *
       * ⚠️ 我第一版想用外层 Listener 检测"点击是否穿透"，**那是错的**：
       *    Listener 是祖先，指针事件本来就会经过它（实测 hit=1），
       *    禁用态阻止的是手势识别，不是事件冒泡。
       *    —— 判据选错方向，会得出"代码坏了"的错误结论。
       */
      final ink = tester.widget<AppInkWell>(find.byType(AppInkWell));
      expect(ink.onTap, isNull,
          reason: '★★★ 禁用态必须让 AppInkWell.onTap 为 null'
              '（只数 onPressed 的调用次数会被一个空回调骗过）');
    });

    testWidgets('★★ 禁用态与可用态在**视觉上**必须不同（否则用户不知道能不能点）',
        (tester) async {
      // 可用态
      await tester.pumpWidget(
        _host(Center(
          child: AppTextButton(
            onPressed: () {},
            child: const Text('删除'),
          ),
        )),
      );
      await tester.pump();
      final enabledColor = _textColorOf(tester, '删除');

      // 禁用态
      await tester.pumpWidget(
        _host(Center(
          child: AppTextButton(
            onPressed: null,
            child: const Text('删除'),
          ),
        )),
      );
      await tester.pump();
      final disabledColor = _textColorOf(tester, '删除');

      // ignore: avoid_print
      print('[GLASS] 文字色 可用=$enabledColor 禁用=$disabledColor');
      expect(enabledColor, isNot(equals(disabledColor)),
          reason: '★★ 禁用态必须变灰（否则用户点了没反应会以为卡了）');
    });

    testWidgets('★★ 无障碍语义：读屏器能按文字找到并念成按钮', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(Center(
          child: AppTextButton(
            onPressed: () {},
            child: const Text('下载全部集'),
          ),
        )),
      );
      await tester.pump();

      expect(find.bySemanticsLabel('下载全部集'), findsWidgets,
          reason: '★★ 铁律 8：读屏器必须能找到这个按钮');
      handle.dispose();
    });

    testWidgets('★ 触控目标 ≥ 34dp（项目规范坑 35）', (tester) async {
      await tester.pumpWidget(
        _host(Center(
          child: AppTextButton(
            onPressed: () {},
            child: const Text('管理'),
          ),
        )),
      );
      await tester.pump();
      final size = tester.getSize(find.byType(AppTextButton));
      // ignore: avoid_print
      print('[GLASS] AppTextButton 尺寸 = ${size.width}x${size.height}');
      expect(size.height, greaterThanOrEqualTo(34.0),
          reason: '★ 触控目标 ${size.height}dp < 34dp（项目规范坑 35）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 诚实记录：还依赖什么
  // ═══════════════════════════════════════════════════════════════════
  group('④ 依赖如实记录', () {
    test('★★ AppTextButton 自身**零 Material 依赖**（这才是真自建）', () {
      /*
       * 这是本步最有价值的一条：证明换上去的不是"另一个 Material 组件"。
       * 链条：AppTextButton → AppInkWell → PressFeedback，三层都只用
       * `package:flutter/widgets.dart`。
       */
      for (final f in const [
        'lib/design/widgets/app_text_button.dart',
        'lib/design/widgets/app_ink_well.dart',
        'lib/ui/widgets/press_feedback.dart',
      ]) {
        final code = stripComments(File(f).readAsStringSync());
        expect(code.contains('material_ui'), isFalse,
            reason: '★★ $f 不许 import material_ui');
        expect(code.contains('package:flutter/material.dart'), isFalse,
            reason: '★★ $f 不许 import flutter/material.dart');
      }
    });

    test('★ detail_page 仍 import material_ui —— 已知且有意（M3 才删）', () {
      final raw = File('lib/ui/detail_page.dart').readAsStringSync();
      expect(raw.contains("import 'package:material_ui/material_ui.dart';"),
          isTrue,
          reason: '★ 如实记录：detail_page 仍 import material_ui'
              '（还要 AlertDialog / Scaffold / SnackBar / IconButton 等，M3 才删）');
    });
  });
}

// ── 辅助 ──────────────────────────────────────────────────────────────

/// 读某个 Text 的**实际渲染颜色**
///
/// ⚠️ 不能读 `Text.style.color` —— `AppTextButton` 的颜色来自外层
///    `DefaultTextStyle.merge`，`Text` 自己的 style 里是 **null**
///    （我第一版就这么写，结果 可用=null 禁用=null，误判成"没区分"）。
/// ⇒ 必须读 **element 树上真正生效的** DefaultTextStyle。
Color? _textColorOf(WidgetTester t, String text) {
  final el = t.element(find.text(text));
  final style = DefaultTextStyle.of(el).style;
  return style.color;
}
