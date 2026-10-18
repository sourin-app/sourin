// ═══════════════════════════════════════════════════════════════════════
//  轨道 E · 玻璃化 M2 第 3 步 —— OutlinedButton → AppOutlinedButton
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// `detail_page.dart` 里 4 处 Material `OutlinedButton` 已换成自建
// `AppOutlinedButton`（3 处在操作行四枚里，1 处是错误页的「返回」）。
//
// # 与 t27_w3 的分工（**不重复**）
// ```text
// t27_w3：守「四枚按钮同源同档 + 几何随平台变化」这个**产品契约**
//         （已改造成不认组件类型：按 ValueKey 定位 + 读渲染后的实际几何）
// 本文件：守「替换完整性」+「自建组件自身的行为正确」
//         —— 源码级没有裸 OutlinedButton(、组件可点、禁用态、语义、Tooltip
// ```
//
// ★★★ 本文件最重要的一条：**尺寸断言必须挂真实页面**
//
// ```text
// 上一轮（第 2 步）我记过一个限制：
//   真实 DetailPage 无数据时 AppIconButton 数量 = 0 ⇒ 页面级尺寸断言做不到。
//
// 本轮找到了正确脚手架（从 t27_w3 学来的）：
//   host() + debugSetDetail() 注入真数据 ⇒ 操作行真的渲染出来。
// ⇒ 本文件的几何断言**全部走这条路**，不再自己 new 组件再量。
// ```

import 'dart:io';
import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, Material, Scaffold;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/design/widgets/app_outlined_button.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';

// ══════════════════════════════════════════════════════════════════════
//  剥注释（块 + 行；保留字符串字面量）
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

// ══════════════════════════════════════════════════════════════════════
//  真实页面脚手架（与 t27_w3 同一套）
// ══════════════════════════════════════════════════════════════════════
const _panelW = 433.0;
const _panelH = 900.0;

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    themeAnimationDuration: Duration.zero,
    home: Scaffold(body: Material(child: child)),
  );
}

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

/// 挂真实 DetailPage + 注入 1 集 ⇒ 操作行四枚真的渲染出来
Future<void> _mountDetail(WidgetTester t) async {
  NetworkStatus.debugProbe = () async => true;
  addTearDown(NetworkStatus.debugResetForTest);
  await t.binding.setSurfaceSize(const Size(_panelW, _panelH));
  addTearDown(() => t.binding.setSurfaceSize(null));

  final key = GlobalKey<State<DetailPage>>();
  await t.pumpWidget(_host(DetailPage(
    key: key,
    provider: 'cycani',
    id: '3862',
    embedded: true,
  )));
  _claim(t);
  await t.pump(const Duration(milliseconds: 50));
  _claim(t);

  const d = MediaDetail(
    id: '3862',
    title: '在线剧',
    episodes: <Episode>[Episode(id: 'ep-1', title: '第01集')],
  );
  // ignore: avoid_dynamic_calls
  (key.currentState! as dynamic).debugSetDetail(d, episodes: d.episodes);
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  _claim(t);
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 源码级：OutlinedButton 已清出
  // ═══════════════════════════════════════════════════════════════════
  group('① detail_page 里不再有 Material OutlinedButton', () {
    test('★★★ 没有裸 OutlinedButton( 残留', () {
      final code = detailSource();
      // ⚠️ 必须排除 AppOutlinedButton( —— 它含 OutlinedButton( 子串
      final bare = RegExp(r'(?<!App)\bOutlinedButton\(').hasMatch(code);
      expect(bare, isFalse,
          reason: '★★★ detail_page 里不许再有 Material 的 OutlinedButton');
    });

    test('★ 正向对照：AppOutlinedButton 正好 4 处', () {
      final code = detailSource();
      /*
       * ⚠️ 必须同时数 `AppOutlinedButton(` 与 `AppOutlinedButton.icon(` ——
       *    后者不含前者的完整子串（`.icon` 插在中间）。
       *    我第一版只数前者，实测得到 1（应为 4）⇒ 假红。
       */
      final total = RegExp(r'AppOutlinedButton\s*(\.icon)?\s*\(')
          .allMatches(code)
          .length;
      expect(total, 4,
          reason: '★ 应该正好 4 处（换源 / _ToggleButton 收藏追更 / 下载 / 错误页返回），'
              '实测 $total');
      expect(
          code.contains(
              "import '../design/widgets/app_outlined_button.dart';"),
          isTrue,
          reason: '★ 必须真的 import 了自建描边按钮');
    });

    test('★★ 下载按钮的 Tooltip 也换成 AppTooltip', () {
      final code = detailSource();
      // 用正则吃 CRLF（硬拼 \n 会匹配不到 —— 第 2 步踩过）
      expect(RegExp(r"AppTooltip\(\s*message: '下载'").hasMatch(code), isTrue,
          reason: '★★ 下载按钮的悬停提示必须换成自建 AppTooltip');
      expect(RegExp(r"(?<!App)Tooltip\(\s*message: '下载'").hasMatch(code),
          isFalse,
          reason: '★★ 不许再用 Material 的 Tooltip');
    });

    test('★★★ 四枚按钮必须有语义位置 Key（t27_w3 靠它定位）', () {
      /*
       * Lead 的裁决：判据不该认组件类型，该认**语义位置**。
       * 这四个 Key 就是那个"语义位置"，缺一个 t27_w3 就找不到那枚按钮。
       */
      final code = detailSource();
      for (final k in const [
        'detail-action-favorite',
        'detail-action-follow',
        'detail-action-switch-source',
        'detail-action-download',
      ]) {
        expect(code.contains("ValueKey('$k')"), isTrue,
            reason: '★★★ 缺 ValueKey($k) —— t27_w3 将无法定位这枚按钮');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 真实页面：四枚真的渲染出来，且几何同档
  // ═══════════════════════════════════════════════════════════════════
  group('② 真实 DetailPage 上的几何（不自己 new 组件）', () {
    testWidgets('★★★ 四枚都在真实页面上渲染出来', (tester) async {
      await _mountDetail(tester);

      expect(find.byType(DetailPage), findsOneWidget, reason: '前提');
      for (final k in const [
        'detail-action-favorite',
        'detail-action-follow',
        'detail-action-switch-source',
        'detail-action-download',
      ]) {
        expect(find.byKey(ValueKey(k)), findsOneWidget,
            reason: '★★★ 真实页面上必须有这枚按钮：$k');
      }
      // ignore: avoid_print
      print('[GLASS3] 真实页面四枚 AppOutlinedButton 全部渲染 ✓');
    });

    testWidgets('★★★ 真实页面上四枚的渲染尺寸逐值相同', (tester) async {
      /*
       * ★ 这条是本轮最重要的收获之一：
       *   第 2 步我记录过"真实页面无数据时按钮数量=0 ⇒ 页面级尺寸断言做不到"。
       *   本轮用 debugSetDetail 注入真数据，**真的做到了**。
       *   ⇒ 不再需要"不假装"，而是真的验证。
       */
      await _mountDetail(tester);

      const keys = [
        'detail-action-favorite',
        'detail-action-follow',
        'detail-action-switch-source',
        'detail-action-download',
      ];
      final sizes = <String, Size>{
        for (final k in keys) k: tester.getSize(find.byKey(ValueKey(k))),
      };
      // ignore: avoid_print
      print('[GLASS3] 真实页面四枚尺寸 = $sizes');

      Size? base;
      for (final e in sizes.entries) {
        base ??= e.value;
        expect(e.value, base,
            reason: '★★★ 四枚必须同尺寸（实测 ${e.key}=${e.value} vs $base）');
      }
      // 非盲性：尺寸不能是 0（否则"都相等"毫无意义）
      expect(base!.width, greaterThan(0));
      expect(base.height, greaterThanOrEqualTo(34.0),
          reason: '★ 触控目标 ≥34dp（项目规范坑 35），实测 ${base.height}');
    });

    testWidgets('★★ 真实页面上「下载」比旁钮宽不会超过 8dp（同档）',
        (tester) async {
      await _mountDetail(tester);
      final dl = tester.getSize(find.byKey(
          const ValueKey('detail-action-download')));
      final follow =
          tester.getSize(find.byKey(const ValueKey('detail-action-follow')));
      expect((dl.width - follow.width).abs(), lessThan(8.0),
          reason: '★ 下载与追更必须同档（实测 $dl vs $follow）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 铁律 8：自建组件的功能一个不许丢
  // ═══════════════════════════════════════════════════════════════════
  group('③ 铁律 8 —— 点击 / 禁用 / 语义 / 悬停提示', () {
    testWidgets('★★★ 点击真的触发 onPressed', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(Center(
        child: AppOutlinedButton(
          onPressed: () => taps++,
          child: const Text('返回'),
        ),
      )));
      await tester.pump();
      await tester.tap(find.byType(AppOutlinedButton));
      await tester.pump();
      expect(taps, 1, reason: '★★★ 点击必须真的触发');
    });

    testWidgets('★★★ 禁用态（onPressed=null）真的不可点', (tester) async {
      var taps = 0;
      await tester.pumpWidget(_host(Center(
        child: AppOutlinedButton(
          onPressed: null,
          child: const Text('返回'),
        ),
      )));
      await tester.pump();
      await tester.tap(find.byType(AppOutlinedButton), warnIfMissed: false);
      await tester.pump();
      expect(taps, 0, reason: '★★★ 禁用态绝不许触发');
      /*
       * ★ 机制级判据（第 1 步的教训：只数计数器会被空回调骗过）
       *   禁用时 AppInkWell.onTap 必须是 null。
       */
      final ink = tester.widget<AppInkWell>(find.byType(AppInkWell));
      expect(ink.onTap, isNull,
          reason: '★★★ 禁用态必须让 AppInkWell.onTap 为 null');
    });

    testWidgets('★★ 语义：读屏器能念成按钮', (tester) async {
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(Center(
        child: AppOutlinedButton(
          onPressed: () {},
          child: const Text('返回'),
        ),
      )));
      await tester.pump();
      expect(find.bySemanticsLabel('返回'), findsWidgets,
          reason: '★★ 铁律 8：读屏器必须能找到');
      handle.dispose();
    });

    testWidgets('★★ 下载按钮的悬停提示真的弹出（AppTooltip 可用）',
        (tester) async {
      await _mountDetail(tester);
      final dl = find.byKey(const ValueKey('detail-action-download'));
      expect(dl, findsOneWidget);

      // 悬停前：页面上只有按钮自己那个「下载」
      final before = find.text('下载').evaluate().length;

      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: tester.getCenter(dl));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pump(const Duration(milliseconds: 300));
      _claim(tester);

      final after = find.text('下载').evaluate().length;
      // ignore: avoid_print
      print('[GLASS3] 悬停前「下载」文本数=$before 悬停后=$after');
      expect(after, greaterThan(before),
          reason: '★★ 悬停 600ms 后必须多出一个「下载」气泡');
      await g.removePointer();
      await tester.pump(const Duration(milliseconds: 300));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 密度复刻有出处 + 混合态记录
  // ═══════════════════════════════════════════════════════════════════
  group('④ 依赖与出处如实记录', () {
    test('★★ 密度映射必须写明 SDK 出处（Lead 硬要求②）', () {
      /*
       * Lead 要求：复刻 Material 密度策略不能靠猜，必须写明
       * 出处（SDK 文件+行号），否则半年后没人知道为什么是 32/48。
       */
      /*
       * ⚠️ 这里必须读**未剥注释**的原文 —— 出处正是写在注释里的。
       *    我第一版用 stripComments 后再断言 `button_style_button.dart`，
       *    必然找不到（注释被剥光了）⇒ 假红。
       * ⇒ 这条判据的对象就是"文档"，不是"代码"，所以不能剥注释。
       */
      final code = File('lib/design/widgets/app_outlined_button.dart')
          .readAsStringSync();
      expect(code.contains('button_style_button.dart'), isTrue,
          reason: '★★ 必须写明 Material 密度逻辑的源文件出处');
      // 关键行号
      for (final ln in const [':584', ':586', ':593']) {
        expect(code.contains(ln), isTrue,
            reason: '★★ 必须写明具体行号 $ln');
      }
      expect(code.contains('material_ui-1.6.0'), isTrue,
          reason: '★★ 必须写明包版本（版本会变，出处要可追溯）');
    });

    test('★★ 组件内唯一保留的 Material 依赖必须标注为「读主题配置」', () {
      final raw = File('lib/design/widgets/app_outlined_button.dart')
          .readAsStringSync();
      expect(raw.contains('material_ui'), isTrue,
          reason: '如实记录：为读 materialTapTargetSize / visualDensity 而引入');
      expect(raw.contains('TODO(M5)'), isTrue,
          reason: '★★ 必须标注 M5 会把主题层自建后删除本依赖');
    });

    test('★ 混合态记录：AlertDialog / Scaffold / SnackBar 仍是 Material', () {
      /*
       * ★ 2026-10-18 更新（第 4 步已完成）：
       *   原先断言「AlertDialog 仍是 Material（第 4 步才换）」——
       *   那是第 3 步时的如实记录。第 4 步做完后该事实变了，判据跟着改。
       *
       * 当前混合态（Lead 裁决：分步做，不合并）：
       *   OutlinedButton → 已换（AppOutlinedButton）   ← 第 3 步
       *   AlertDialog    → 已换（AppGlassDialog）      ← 第 4 步
       *   SnackBar       → 仍是 Material              ← 第 5 步
       *   Scaffold ×2    → 仍是 Material              ← 第 6 步（须先报 Lead）
       */
      final code = detailSource();
      expect(RegExp(r'(?<!App)AlertDialog\(').hasMatch(code), isFalse,
          reason: '★ 记录：AlertDialog 已全部换成 AppGlassDialog');
      expect(code.contains('Scaffold('), isTrue,
          reason: '★ 记录：Scaffold 仍是 Material（第 6 步才换，**须先报 Lead**）');
      expect(code.contains('AppOutlinedButton('), isTrue,
          reason: '★ 记录：描边按钮已是自建');
      expect(code.contains('AppGlassDialog('), isTrue,
          reason: '★ 记录：确认框已是玻璃自建');
    });

    test('★★ AppOutlinedButton 的几何必须**不依赖** Material 组件', () {
      /*
       * 证明自建组件不是在内部包一个 OutlinedButton 蒙混过关。
       * 允许读 Theme 的密度配置（那是主题层），但不许 new Material 组件。
       */
      final code = stripComments(
          File('lib/design/widgets/app_outlined_button.dart').readAsStringSync());
      expect(RegExp(r'\bOutlinedButton\(').hasMatch(code), isFalse,
          reason: '★★ 内部不许 new Material 的 OutlinedButton');
      expect(code.contains('Material('), isFalse,
          reason: '★★ 内部不许 new Material');
    });
  });
}
