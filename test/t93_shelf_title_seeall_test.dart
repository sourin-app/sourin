// ══════════════════════════════════════════════════════════════════════════
//  t93 —— 2026-10-06 Owner 手机端两条新诉求的回归门禁
// ══════════════════════════════════════════════════════════════════════════
//
// Owner 原话（同一轮，安卓端）：
// > 手机端可以把左上角的 我的 这两个文字隐藏吧
// > 然后这个查看更多看起来还是不合理啊
//
// 两条都落在 `lib/ui/widgets/my_shelf.dart`：
//   ① 2026-11-08 新要求：所有宽度不画「我的」，显示简短分段标签
//   ② 「查看更多」从「文字胶囊」改成「纯箭头 + 44dp 触控目标」
//
// ⚠️ 为什么用 `tester.view.physicalSize` + `devicePixelRatio` 而不是
//    `binding.setSurfaceSize`：本仓踩过 —— `setSurfaceSize` 只改
//    `MediaQuery.size`，不改 `MediaQuery.padding`/实际视口，
//    在**有系统栏**的档位上会给出与真机不同的布局 ⇒ 假红。
//    这里 dpr 固定 1，物理像素 = 逻辑像素，读数最好对。
// ══════════════════════════════════════════════════════════════════════════

/*
 * ⚠️ 铁律：本仓 Flutter 3.47 把 material 拆成了独立的 `material_ui` 包
 *   （见 `test/detail_follow_test.dart:1269-1297` 的全仓扫描断言）。
 *   混用 `flutter/material` 会让 `InkWell` 找不到 `Material` 祖先 ——
 *   我第一次就是这么写的，t93 当场报「No Material widget found」。
 */
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import 'support/miuix_finders.dart';

import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

/// 用**物理尺寸 + dpr** 固定视口（见文件头注释）
Future<void> _at(WidgetTester t, Size logical) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = logical;
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
}

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('① 所有宽度均省略我的标题', () {
    for (final width in [360.0, 412.0, 639.0, 640.0, 1280.0]) {
      testWidgets('$width dp 保留三个简短分段而不重复版块标题', (t) async {
        await _at(t, Size(width, 900));
        await t.pumpWidget(
          _host(
            MyShelf(
              onOpenDetail: (_, __) {},
              onPlay: (_, __, ___, ____, _____) {},
            ),
          ),
        );
        await t.pump();
        expect(find.text('我的'), findsNothing);
        final tabs = find.byType(miuix.MiuixGlassSegmentedTabRow);
        expect(tabs, findsOneWidget);
        for (final label in ['追更', '收藏', '历史']) {
          expect(
            find.descendant(of: tabs, matching: find.text('$label 0')),
            findsOneWidget,
          );
        }
        expect(t.takeException(), isNull);
      });
    }
  });

  group('② 「查看更多」改成纯箭头（v3）', () {
    testWidgets('★★★ 412dp：是一枚带 tooltip 的箭头按钮，且触控目标 ≥34dp', (t) async {
      await _at(t, const Size(412, 915));
      await t.pumpWidget(
        _host(
          MyShelf(
            onSeeAll: (_) {},
            onOpenDetail: (_, __) {},
            onPlay: (_, __, ___, ____, _____) {},
          ),
        ),
      );
      await t.pump();

      final byTip = miuixTooltip('查看更多');
      expect(
        byTip,
        findsOneWidget,
        reason:
            '★★★ 入口必须还在（Owner 只要求换形态，没要求删掉）；'
            '文字没了 ⇒ 读屏靠 tooltip（Semantics.label）',
      );
      final size = t.getSize(byTip);
      // ignore: avoid_print
      print('[T93] 查看更多命中区 = ${size.width} x ${size.height}');
      expect(
        size.width,
        greaterThanOrEqualTo(34.0),
        reason: '★ 项目规范（DEVELOPMENT.md 坑 35）：触控目标 ≥34px',
      );
      expect(
        size.height,
        greaterThanOrEqualTo(34.0),
        reason: '★ 项目规范（DEVELOPMENT.md 坑 35）：触控目标 ≥34px',
      );

      /*
       * 形态判据：**没有**「查看更多」文字，且不是 TextButton。
       * 前者证明容器/文字真的去掉了，后者证明不是把 TextButton 换了个皮。
       */
      expect(
        find.text('查看更多'),
        findsNothing,
        reason:
            '★★ Owner：「这个查看更多看起来还是不合理啊」⇒'
            ' v3 是纯箭头，屏幕上不该再出现这四个字',
      );
      expect(
        find.descendant(of: byTip, matching: find.byType(TextButton)),
        findsNothing,
        reason: '★ 不该还是文字按钮（那说明 v2 的胶囊只是换了个写法）',
      );
    });

    testWidgets('★★★ 点箭头 ⇒ 回调仍拿正确的 tab key（行为没退）', (t) async {
      await _at(t, const Size(412, 915));
      final got = <String>[];
      await t.pumpWidget(
        _host(
          MyShelf(
            onSeeAll: got.add,
            onOpenDetail: (_, __) {},
            onPlay: (_, __, ___, ____, _____) {},
          ),
        ),
      );
      await t.pump();

      await t.tap(miuixTooltip('查看更多'));
      await t.pump();
      // ignore: avoid_print
      print('[T93] 412dp 点箭头 ⇒ $got');
      expect(got, ['following'], reason: '★ 形态换了，行为不许变（默认 tab 是「追更」）');
    });

    testWidgets('★★★ 仪器自检：1280dp（宽屏）同一枚入口也可点', (t) async {
      await _at(t, const Size(1280, 900));
      final got = <String>[];
      await t.pumpWidget(
        _host(
          MyShelf(
            onSeeAll: got.add,
            onOpenDetail: (_, __) {},
            onPlay: (_, __, ___, ____, _____) {},
          ),
        ),
      );
      await t.pump();

      expect(miuixTooltip('查看更多'), findsOneWidget);
      await t.tap(miuixTooltip('查看更多'));
      await t.pump();
      expect(got, ['following'], reason: '宽屏布局调整后仍必须到达对应追更分类');
    });

    testWidgets('★ 阳性对照：onSeeAll 为 null ⇒ 整枚入口不渲染', (t) async {
      await _at(t, const Size(412, 915));
      await t.pumpWidget(
        _host(
          MyShelf(
            onOpenDetail: (_, __) {},
            onPlay: (_, __, ___, ____, _____) {},
          ),
        ),
      );
      await t.pump();
      expect(
        miuixTooltip('查看更多'),
        findsNothing,
        reason: '★ 没给回调 ⇒ 不该渲染一个点了没反应的按钮',
      );
    });
  });
}
