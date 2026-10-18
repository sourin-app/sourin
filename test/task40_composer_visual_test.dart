// ═══════════════════════════════════════════════════════════════════════
//  task-40 / Owner 第 9 条：可视化编排器（一屏 + 拖拽 + 实时预览）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的四条验收判据
// ```text
// ① 一屏内能改完，**不需要**「下一步」
// ② 端点拖拽后，预览 JSON 的键序**真的变**
// ③ 改任一字段 ⇒ 预览**立即**更新（不点保存）
// ④ 用 Modal 外壳（AppDialogShell），不是裸 showDialog
// ```
//
// # ★ 判据 ② 是这里最容易假绿的地方
// ```text
// 「拖拽」有两层：UI 的行换了位置，和**数据**换了顺序。
// 只测第一层（find 到的 widget 顺序）⇒ 数据没动也照样绿。
// ⇒ 这里断言的是**渲染出来的 JSON 文本**里键的先后，
//   那是用户真正会保存下去的东西。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';
import 'package:sourin_spike/ui/widgets/source_composer_model.dart';

Widget _host(Widget child, {Size size = const Size(1200, 900)}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: Center(child: SizedBox(width: 900, height: 820, child: child))),
    );

/// 取出预览区**渲染出来的文本**（用户实际看到/会保存的东西）
String _previewText(WidgetTester t) {
  final texts = t.widgetList<SelectableText>(find.byType(SelectableText));
  expect(texts, isNotEmpty, reason: '预览区必须存在（SelectableText）');
  return texts.first.data ?? '';
}

/// 从预览文本里取出 endpoints 的键，**按出现先后**
List<String> _endpointKeyOrder(String json) {
  final i = json.indexOf('"endpoints"');
  expect(i, greaterThanOrEqualTo(0), reason: 'JSON 里必须有 endpoints 段');
  final tail = json.substring(i);
  final keys = <String>[];
  for (final m in RegExp(r'^\s{4}"([a-z]+)"\s*:', multiLine: true).allMatches(tail)) {
    final k = m.group(1)!;
    // endpoints 段里的四个合法键
    if (const ['categories', 'list', 'detail', 'search'].contains(k)) keys.add(k);
  }
  return keys;
}

/// 造一个四端点全开的初值
ComposerDraft _full() {
  final d = ComposerDraft(id: 'demo', name: '演示源', base: 'https://api.example.com');
  for (final e in ComposerEndpoint.values) {
    d.endpoints[e]!
      ..enabled = true
      ..path = '/${e.key}';
    d.endpoints[e]!.map['items'] = r'$.data.list';
  }
  return d;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 一屏化：没有「下一步」，三块都在
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('★★★ ① 一屏内三块全在，且**没有**「下一步」按钮', (t) async {
    await t.pumpWidget(_host(SourceComposerDialog(initial: _full())));
    await t.pumpAndSettle();

    // 三块标题必须同时出现（不需要点任何东西）
    expect(find.textContaining('① 站点'), findsOneWidget);
    expect(find.textContaining('② 端点'), findsOneWidget);
    expect(find.textContaining('③ 字段映射'), findsOneWidget);
    expect(find.textContaining('实时预览'), findsOneWidget);

    // ★ 向导的两个按钮必须**不存在**
    expect(find.text('下一步'), findsNothing,
        reason: '★★ 还有「下一步」就说明仍是三步向导 —— 这条是 Owner 诉求的原点');
    expect(find.text('上一步'), findsNothing);
  });

  testWidgets('★ ① 窄屏退化成上下，但仍是同一屏（无「下一步」）', (t) async {
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: const Scaffold(
        body: Center(child: SizedBox(width: 420, height: 800, child: SourceComposerDialog())),
      ),
    ));
    await t.pumpAndSettle();
    expect(find.text('下一步'), findsNothing,
        reason: '窄屏也不能退回向导 —— 只是换个排列');
    expect(find.textContaining('实时预览'), findsOneWidget);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 拖拽：预览 JSON 的键序**真的**变
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('★★★ ② 拖拽后预览 JSON 的 endpoints 键序真的变了', (t) async {
    final d = _full();
    await t.pumpWidget(_host(SourceComposerDialog(initial: d)));
    await t.pumpAndSettle();

    final before = _endpointKeyOrder(_previewText(t));
    expect(before, ['categories', 'list', 'detail', 'search'],
        reason: '初值顺序应与枚举序一致');

    // 把第一行（categories）拖到最后
    final handle = find.byIcon(Icons.drag_indicator).first;
    expect(handle, findsOneWidget, reason: '必须存在拖拽手柄（否则用户没法拖）');

    final g = await t.startGesture(t.getCenter(handle));
    await t.pump(const Duration(milliseconds: 100));
    // 往下拖过三行
    await g.moveBy(const Offset(0, 150));
    await t.pump(const Duration(milliseconds: 100));
    await g.up();
    await t.pumpAndSettle();

    final after = _endpointKeyOrder(_previewText(t));
    expect(after, isNot(before),
        reason: '★★★ 拖完 JSON 键序必须真的变 —— '
            ' 若这里仍是 $before，就是「UI 动了、数据没动」的假拖拽');
    expect(after.first, isNot('categories'),
        reason: '★ 被拖走的那一项不该还在第一位');
  });

  testWidgets('★★ ② 拖拽后 toJson() 的键序也变（数据层，不只 UI）', (t) async {
    final d = _full();
    await t.pumpWidget(_host(SourceComposerDialog(initial: d)));
    await t.pumpAndSettle();

    final before = (d.toJson()['endpoints'] as Map).keys.toList();
    expect(before, ['categories', 'list', 'detail', 'search']);

    final handle = find.byIcon(Icons.drag_indicator).first;
    final g = await t.startGesture(t.getCenter(handle));
    await t.pump(const Duration(milliseconds: 100));
    await g.moveBy(const Offset(0, 150));
    await t.pump(const Duration(milliseconds: 100));
    await g.up();
    await t.pumpAndSettle();

    final after = (d.toJson()['endpoints'] as Map).keys.toList();
    expect(after, isNot(before),
        reason: '★★ 传进 onSubmit 的就是这份 —— 它不变等于白拖');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 实时预览：改字段 ⇒ 立即更新
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('★★★ ③ 改站点名 ⇒ 预览立即跟着变（不点任何按钮）', (t) async {
    await t.pumpWidget(_host(SourceComposerDialog(initial: _full())));
    await t.pumpAndSettle();

    expect(_previewText(t), contains('演示源'));

    // 第 2 个 TextField 是「显示名」（id / name / base 三个）
    await t.enterText(find.byType(TextField).at(1), '改过的名字');
    await t.pump();

    expect(_previewText(t), contains('改过的名字'),
        reason: '★★ 改完字段预览必须立即反映 —— 这是判据 3 的核心');
    expect(_previewText(t), isNot(contains('演示源')));
  });

  testWidgets('★★ ③ 改 JSONPath ⇒ 预览立即跟着变', (t) async {
    await t.pumpWidget(_host(SourceComposerDialog(initial: _full())));
    await t.pumpAndSettle();

    expect(_previewText(t), contains(r'$.data.list'));

    // 第一个映射行（categories 的 items）
    final mapFields = find.byType(TextField);
    await t.enterText(mapFields.last, r'$.result.items');
    await t.pump();

    expect(_previewText(t), contains(r'$.result.items'),
        reason: '★★ JSONPath 改了预览必须跟着变');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ Modal 外壳
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('★ ④ 走 AppDialogShell（不是裸容器）', (t) async {
    await t.pumpWidget(_host(SourceComposerDialog(initial: _full())));
    await t.pumpAndSettle();
    expect(find.byType(AppDialogShell), findsOneWidget,
        reason: '★ 统一弹窗外壳 —— Owner 说「这里肯定也要用到 modal」');
  });
}