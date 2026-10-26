// ═══════════════════════════════════════════════════════════════════════
//  t1048：「TVBox 聚合」分组折叠（Owner 架构 A′ 的 B 半）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
// ```text
// ① 分组**计数**只数 kind == 'tvbox'（别把 JS/HTTP/声明式源算进来）
// ② 折叠 ⇒ 组内条目**真的从展示序列里消失**（不是"透明但仍占位"）
// ③ 展开 ⇒ 它们回到序列**末尾**（其他源在前，聚合组在后）
// ④ 标题文案逐字 + 收起/展开可点（宿主状态由外部持有，组件无状态）
// ⑤ 接线：宿主用 `tvboxGroupCount(list) > 0` 才画标题、用
//    `tvboxGroupOrder(list, expanded:)` 决定画哪些卡
// ```
//
// # 为什么用纯函数 + 公开小组件来测
// ```text
// 分组逻辑在 `_pluginsBlock` 里，而那是 `_PluginsPage`（私有宿主）渲染的
// ⇒ 整页挂载要起 FFI。把"折叠到底画哪些"抽成纯函数后：
//   注入「折叠也返回全量」⇒ ② 立刻红，**不需要**整页。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';

ProviderManifest p(String id, String kind) =>
    ProviderManifest(id: id, name: id, kind: kind);

final List<ProviderManifest> mixed = <ProviderManifest>[
  p('js1', 'js'),
  p('tv1', 'tvbox'),
  p('http1', 'http'),
  p('tv2', 'tvbox'),
  p('decl1', 'declarative'),
];

Widget host(Widget child) => MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  group('① 计数只数 tvbox', () {
    test('★★ 混合列表 ⇒ 2（不是 5）', () {
      expect(tvboxGroupCount(mixed), 2,
          reason: '★★ 把 JS/HTTP/声明式也数进来 ⇒ 标题会谎报条目数');
      expect(tvboxGroupCount(const <ProviderManifest>[]), 0);
    });
  });

  group('② 折叠 / 展开：展示序列真的变', () {
    test('★★★ 折叠 ⇒ 组内条目从序列里**消失**', () {
      final collapsed = tvboxGroupOrder(mixed, expanded: false);
      expect(collapsed.map((e) => e.id).toList(), <String>['js1', 'http1', 'decl1'],
          reason: '★★★ 折叠只改标题不省卡片 = 假折叠；'
              '注入「折叠也返回全量」本条立刻红');
    });

    test('★★ 展开 ⇒ 其他源在前、聚合组在末尾（各自保持原序）', () {
      final expanded = tvboxGroupOrder(mixed, expanded: true);
      expect(expanded.map((e) => e.id).toList(),
          <String>['js1', 'http1', 'decl1', 'tv1', 'tv2'],
          reason: '★★ 顺序必须是"其他源 → TVBox 组"，否则标题与卡片不在一处');
      expect(expanded.length, mixed.length,
          reason: '★ 展开态不许丢条目（丢一条 = 用户以为源没了）');
    });
  });

  group('③ 标题：逐字 + 可点', () {
    testWidgets('★★★ 文案 `TVBox 聚合（16 个源）`，收起/展开可点', (t) async {
      var taps = 0;
      await t.pumpWidget(host(TvboxGroupHeader(
        count: 16,
        expanded: true,
        onToggle: () => taps++,
      )));
      await t.pump();

      expect(find.text('TVBox 聚合（16 个源）'), findsOneWidget,
          reason: '★★ 文案逐字（用户要照着找这一行）');
      expect(find.text('收起'), findsOneWidget, reason: '★ 展开态显示「收起」');
      await t.tap(find.byKey(const ValueKey<String>('tvbox-group-header')));
      await t.pump();
      expect(taps, 1, reason: '★★ 点标题必须真的回调宿主（否则折叠不了）');

      await t.pumpWidget(host(TvboxGroupHeader(
        count: 3,
        expanded: false,
        onToggle: () {},
      )));
      await t.pump();
      expect(find.text('TVBox 聚合（3 个源）'), findsOneWidget);
      expect(find.text('展开'), findsOneWidget, reason: '★ 折叠态显示「展开」');
    });
  });

  group('④ 接线：宿主按计数决定画不画、按展开态决定画哪些', () {
    test('★★ settings_page 用 tvboxGroupCount / tvboxGroupOrder', () {
      final src = File('lib/ui/settings_page.dart').readAsStringSync();
      expect(RegExp(r'if \(tvboxGroupCount\(list\) > 0\)').hasMatch(src), isTrue,
          reason: '★ 没有 tvbox 源时不许画分组标题');
      expect(src.contains('tvboxGroupOrder(list, expanded: _tvboxExpanded)'), isTrue,
          reason: '★★ 网格必须用**折叠态**算出的序列（否则折叠不生效）');
      expect(src.contains('_tvboxExpanded'), isTrue,
          reason: '★ 展开态由宿主持有（组件无状态）');
    });
  });
  _hiddenGroup();
}

void _hiddenGroup() {
  group('⑤ hidden：被聚合器接管的子站不单独出现', () {
    test('★★★ hidden 的源被过滤，未 hidden 的仍在', () {
      final list = <ProviderManifest>[
        p('js1', 'js'),
        ProviderManifest(id: 'tv1', name: 'tv1', kind: 'tvbox'),
        ProviderManifest(id: 'tv2', name: 'tv2', kind: 'tvbox', hidden: true),
      ];
      final shown = visibleProviders(list);
      expect(shown.map((e) => e.id).toList(), <String>['js1', 'tv1'],
          reason: '★★★ hidden:true 必须从列表里消失（否则 16 张卡还在、聚合白做）；'
              '注入「去掉 .where((p) => !p.hidden)」本条立刻红');
      // 分组计数也必须在过滤后的集合上算
      expect(tvboxGroupCount(shown), 1,
          reason: '★★ 过滤在**分组之前** ⇒ 计数不能把 hidden 算进来');
    });

    test('★★ 全 hidden ⇒ 什么都不画（N=0）', () {
      final list = <ProviderManifest>[
        ProviderManifest(id: 'tv1', name: 'tv1', kind: 'tvbox', hidden: true),
      ];
      expect(visibleProviders(list), isEmpty);
      expect(tvboxGroupCount(visibleProviders(list)), 0);
    });

    test('★ 接线：宿主先 visibleProviders 再分组', () {
      final src = File('lib/ui/settings_page.dart').readAsStringSync();
      expect(src.contains('visibleProviders(_nonLiveProviders)'), isTrue,
          reason: '★ 过滤必须在宿主那一层生效，而不是只在某个纯函数里');
    });
  });
}

