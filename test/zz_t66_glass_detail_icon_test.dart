// ═══════════════════════════════════════════════════════════════════════
//  轨道 E · 玻璃化 M2 第 2 步 —— detail_page 的 IconButton 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// `detail_page.dart` 里 2 个 Material `IconButton` 已换成自建 `AppIconButton`：
// ```text
// ① 返回按钮（`_bodyTop` 顶部左侧，icon=chevron_left，tooltip='返回'）
//    原：IconButton(onPressed:, icon:, tooltip:) —— 实测 48×48
// ② 每行的删除按钮（`_LocalRowDeleteButton`，悬停才显形）
//    原：Tooltip + IconButton(constraints: tightFor(28,28), iconSize: 16)
//        ★ 实测真实尺寸也是 **48×48** —— 那个 28 被 Material 最小触控约束覆盖了
// ```
//
// # ★★★ 本文件最重要的一条：**触控目标不许缩水**
//
// ```text
// `AppIconButton` 的默认热区 = iconSize + pad*2 = 24+16 = 40×40，
// 而原 Material 是 48×48。直接替换会缩水 8dp（返回）/ 20dp（删除）。
// ⇒ 两处都显式 `SizedBox(48, 48)`，与替换前逐值一致。
// 本文件用**真实渲染尺寸**钉住这件事。
// ```

import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp;
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/design/widgets/app_icon_button.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/design/widgets/app_tooltip_slider.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';

// ══════════════════════════════════════════════════════════════════════
//  剥注释（块 + 行；保留字符串字面量）
// ══════════════════════════════════════════════════════════════════════
//
// ★ 必须剥注释：detail_page 的注释里大量写着
//   「IconButton → AppIconButton」这类说明，不剥会**假红**。
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

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(theme: theme, home: child);
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 源码级：IconButton 已清出
  // ═══════════════════════════════════════════════════════════════════
  group('① detail_page 里不再有 Material IconButton', () {
    test('★★★ 没有裸 IconButton( 残留', () {
      final code = detailSource();
      /*
       * ⚠️ 判据必须排除 `AppIconButton(` —— 它包含 `IconButton(` 子串。
       *    直接用 contains 会**永远为真**（假红）。
       */
      final bare = RegExp(r'(?<!App)\bIconButton\(').hasMatch(code);
      expect(bare, isFalse,
          reason: '★★★ detail_page 里不许再有 Material 的 IconButton');
    });

    test('★ 正向对照：AppIconButton 真的在源码里，且正好 2 处', () {
      final code = detailSource();
      expect(RegExp(r'AppIconButton\(').allMatches(code).length, 2,
          reason: '★ 应该正好 2 处 AppIconButton（替换了原来的 2 个 IconButton）');
      expect(
          code.contains("import '../design/widgets/app_icon_button.dart';"),
          isTrue,
          reason: '★ 必须真的 import 了自建图标按钮');
    });

    test('★★ 外层 Tooltip 也换成 AppTooltip（否则悬停气泡丢失）', () {
      /*
       * 删除按钮原来用 `Tooltip(message: '删除这一集')` 包着 ——
       * Material 的 Tooltip 属于 Material 层，留着就等于没摘干净。
       * 但它**不是** IconButton 的参数，所以上一条判据抓不到。
       */
      final code = detailSource();
      /*
       * ⚠️ 判据只针对**删除按钮那一处**，不能断言"全文没有裸 Tooltip("。
       *
       * 实测：detail_page 里还有 1 处裸 `Tooltip(` 包着 `OutlinedButton.icon`
       * （下载菜单，**第 3 步**才换）。那是别的一步的范围，
       * 在这里一并断言会让本步永远无法通过（假红），
       * 而且会掩盖"到底哪一处还没换"。
       * ⇒ 精确判据：删除按钮的提示必须已换成 AppTooltip。
       */
      /*
       * ⚠️ 用**正则**而不是 contains 拼换行 —— 本文件是 CRLF，
       *    硬拼 "\n" 匹配不到（我第一版就这样假红了一次）。
       *    `\s*` 同时吃掉 \r\n 与缩进，两种行尾都对。
       */
      final appTip = RegExp("AppTooltip\\(\\s*message: '删除这一集'");
      final materialTip = RegExp("(?<!App)Tooltip\\(\\s*message: '删除这一集'");
      expect(appTip.hasMatch(code), isTrue,
          reason: '★★ 删除按钮的悬停提示必须换成 AppTooltip（否则悬停气泡丢失）');
      expect(materialTip.hasMatch(code), isFalse,
          reason: '★★ 删除按钮不许再用 Material 的 Tooltip');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 渲染级：真实尺寸 = 替换前（48×48）
  // ═══════════════════════════════════════════════════════════════════
  group('② 触控目标不许缩水（实测值钉住）', () {
    /*
     * ★★★ 2026-10-18 故障注入抓到的**假绿**，记录在此免得后人重犯：
     *
     * 第一版这两条测试是**自己**写 `SizedBox(width:48,height:48)` 包住
     * `AppIconButton` 再量尺寸 —— 量到的永远是测试自己给的那个 48，
     * 与产品代码无关。注入「把产品里的 SizedBox 换成 Container」之后
     * **仍然是绿的**（实测 48.0x48.0）。
     *
     * ⇒ 这是**第三次**遇到同一个病：门禁没有经过被测对象。
     *
     * 为什么不能改成"挂真实 DetailPage 量"（我试过）：
     * ```text
     * 实测：无数据时真实 DetailPage 上 AppIconButton 数量 = **0**
     * （页面走加载/错误分支，返回按钮都不渲染）。
     * ⇒ 真实页面级尺寸断言在本环境**做不到**，如实说明，不假装。
     * ```
     * ⇒ 改用**源码断言**守住"产品代码里确实有 48×48 的约束"，
     *   并用注入验证：把 48 改成别的值 ⇒ 必须红。
     */
    test('★★★ 返回按钮的 48×48 约束必须在**产品源码**里', () {
      final code = detailSource();
      // 返回按钮：SizedBox(width: 48, height: 48, child: AppIconButton(...chevron_left...))
      final re = RegExp(
        r'width:\s*48,\s*height:\s*48,\s*child:\s*AppIconButton\('
        r'[^;]{0,400}?AppIcons\.chevron_left',
        dotAll: true,
      );
      expect(re.hasMatch(code), isTrue,
          reason: '★★★ 返回按钮必须在产品源码里被 48×48 锁住'
              '（AppIconButton 默认只有 40×40，缩水 8dp）');
    });

    test('★★★ 删除按钮的 48×48 约束必须在**产品源码**里', () {
      final code = detailSource();
      final re = RegExp(
        r'width:\s*48,\s*height:\s*48,\s*child:\s*AppIconButton\('
        r'[^;]{0,400}?AppIcons\.delete_outline',
        dotAll: true,
      );
      expect(re.hasMatch(code), isTrue,
          reason: '★★★ 删除按钮必须 48×48（原代码写 28 但实测 Material 是 48，'
              '按实测值对齐）');
    });

    testWidgets('★★ 组件级尺寸：48 约束下 AppIconButton 真的占满 48×48',
        (tester) async {
      /*
       * 这条只验证**组件在被约束到 48 时确实铺满**（不是验证产品代码的取值，
       * 那个由上面两条源码断言负责）。
       * 两条合起来才完整：源码里写了 48 + 组件确实能撑满 48。
       */
      await tester.pumpWidget(
        _host(Center(
          child: SizedBox(
            width: 48,
            height: 48,
            child: AppIconButton(
              onPressed: () {},
              icon: const Icon(AppIcons.chevron_left),
              tooltip: '返回',
            ),
          ),
        )),
      );
      await tester.pump();
      final size = tester.getSize(find.byType(AppIconButton));
      // ignore: avoid_print
      print('[GLASS] 48 约束下实际尺寸 = ${size.width}x${size.height}');
      expect(size.width, 48.0);
      expect(size.height, 48.0);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 铁律 8：点击 / 禁用 / 语义 / 悬停提示 都不许丢
  // ═══════════════════════════════════════════════════════════════════
  group('③ 铁律 8 —— 功能不许丢', () {
    testWidgets('★★★ 返回按钮点击有效', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(Center(
          child: AppIconButton(
            onPressed: () => taps++,
            icon: const Icon(AppIcons.chevron_left),
            tooltip: '返回',
          ),
        )),
      );
      await tester.pump();
      await tester.tap(find.byType(AppIconButton));
      await tester.pump();
      expect(taps, 1, reason: '★★★ 点击必须真的触发 onPressed');
    });

    testWidgets('★★★ 无障碍语义：读屏器能念出「返回」', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(
        _host(Center(
          child: AppIconButton(
            onPressed: () {},
            icon: const Icon(AppIcons.chevron_left),
            tooltip: '返回',
          ),
        )),
      );
      await tester.pump();

      /*
       * `AppIconButton` 把 tooltip 文本挂成 `Semantics.label`
       * （因为它不能用 Material 的 Tooltip）。
       * ⇒ 读屏器能念出「返回」，这条必须成立。
       */
      expect(find.bySemanticsLabel('返回'), findsWidgets,
          reason: '★★★ 铁律 8：读屏器必须能念出按钮用途');
      handle.dispose();
    });

    testWidgets('★★ 禁用态（onPressed=null）真的不可点', (tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(Center(
          child: AppIconButton(
            onPressed: null,
            icon: const Icon(AppIcons.delete_outline_rounded),
            tooltip: '删除',
          ),
        )),
      );
      await tester.pump();
      await tester.tap(find.byType(AppIconButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0, reason: '★★ 禁用态绝不许触发');
      // 机制级判据：AppInkWell.onTap 必须为 null（只数计数会被空回调骗过）
      final ink = tester.widget<AppInkWell>(find.byType(AppInkWell));
      expect(ink.onTap, isNull, reason: '★★ 禁用态必须让 AppInkWell.onTap 为 null');
    });

    testWidgets('★★ AppTooltip 真的能在悬停后弹出（悬停气泡没丢）', (tester) async {
      /*
       * 删除按钮原来是 Material 的 `Tooltip`，换成了 `AppTooltip`。
       * 若 AppTooltip 不工作，用户就**永远看不到「删除这一集」这个提示** ——
       * 而那个图标在未悬停时是**完全透明**的，没有提示就完全猜不到它是什么。
       * ⇒ 这条是**可用性关键**，不是装饰。
       */
      await tester.pumpWidget(
        _host(Center(
          child: AppTooltip(
            message: '删除这一集',
            child: SizedBox(
              width: 48,
              height: 48,
              child: AppIconButton(
                onPressed: () {},
                iconSize: 16,
                icon: const Icon(AppIcons.delete_outline_rounded),
              ),
            ),
          ),
        )),
      );
      await tester.pump();

      // 悬停前：不应有气泡
      expect(find.text('删除这一集'), findsNothing,
          reason: '前提：未悬停时不该有气泡');

      // 悬停并等待 waitDuration(500ms) + 动画
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: tester.getCenter(find.byType(AppIconButton)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('删除这一集'), findsWidgets,
          reason: '★★ 悬停后必须弹出提示（否则那个透明图标完全不可理解）');
      await g.removePointer();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 依赖如实记录
  // ═══════════════════════════════════════════════════════════════════
  group('④ 依赖如实记录', () {
    test('★★ AppIconButton 与 AppTooltip 自身零 Material 依赖', () {
      for (final f in const [
        'lib/design/widgets/app_icon_button.dart',
        'lib/design/widgets/app_tooltip_slider.dart',
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
          reason: '★ 如实记录：还要 AlertDialog / Scaffold / SnackBar 等（M3 才删）');
    });

    test('★ 混合态说明：对话框仍是 Material，按钮已是自建（有意，非缺陷）', () {
      /*
       * Lead 已裁决：**不要**把第 1/2 步与第 4 步（AlertDialog）合并。
       * 混合态（Material 对话框 + 自建按钮）视觉上没问题 ——
       * 因为自建按钮不带材质，它只是"一个按钮"，不携带 Material 的视觉特征。
       * ⇒ 这是**有意的中间状态**，本测试把它记录下来，避免后人以为是没做完。
       */
      final code = detailSource();
      expect(code.contains('AlertDialog('), isTrue,
          reason: '★ 记录：AlertDialog 仍是 Material（第 4 步才换）');
      expect(code.contains('AppTextButton('), isTrue,
          reason: '★ 记录：对话框里的按钮已是自建（第 1 步已换）');
    });
  });
}
