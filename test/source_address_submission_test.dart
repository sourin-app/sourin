import 'dart:async';
import 'dart:ui' as semantics_ui;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: child),
  );
}

List<SemanticsNode> _nodes(WidgetTester tester) {
  final result = <SemanticsNode>[];
  void visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) result.add(node);
    node.visitChildren((child) { visit(child); return true; });
  }
  visit(tester.binding.renderViews.single.owner!.semanticsOwner!.rootSemanticsNode!);
  return result;
}

void main() {
  testWidgets('input keeps its semantic parent while disabled and restored', (tester) async {
    final semantics = tester.ensureSemantics();
    final controller = TextEditingController(text: 'draft');
    addTearDown(controller.dispose);
    var enabled = true;
    late StateSetter update;
    await tester.pumpWidget(_host(StatefulBuilder(builder: (_, setState) {
      update = setState;
      return Column(children: [
        ui.TextField(controller: controller, enabled: enabled,
          decoration: const InputDecoration(labelText: '名称', hintText: '可选')),
        const Text('其他内容'),
      ]);
    })));
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixTextField), findsOneWidget);
    SemanticsNode input() => _nodes(tester).singleWhere((node) =>
      node.getSemanticsData().flagsCollection.isTextField && node.getSemanticsData().value == 'draft');
    final before = input();
    final id = before.id;
    final parent = before.parent!.id;
    expect(before.getSemanticsData().hasAction(semantics_ui.SemanticsAction.tap), isTrue);
    before.owner!.performAction(id, semantics_ui.SemanticsAction.tap);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(find.byType(EditableText)).focusNode.hasFocus, isTrue);
    for (final value in [false, true]) {
      update(() => enabled = value);
      await tester.pumpAndSettle();
      if (value) {
        input().owner!.performAction(id, semantics_ui.SemanticsAction.tap);
        await tester.pumpAndSettle();
      }
      final current = input();
      expect(current.id, id);
      expect(current.parent!.id, parent,
        reason: 'Disabling input must not reparent its surviving editable node.');
      expect(current.getSemanticsData().flagsCollection.isEnabled,
        value ? semantics_ui.Tristate.isTrue : semantics_ui.Tristate.isFalse);
      expect(current.getSemanticsData().hasAction(semantics_ui.SemanticsAction.setText), value);
      expect(controller.text, 'draft');
    }
    await tester.pumpWidget(const SizedBox());
    semantics.dispose();
  });

  testWidgets('address limit explains failure and preserves the draft for retry', (tester) async {
    var calls = 0;
    final pending = Completer<void>();
    await tester.pumpWidget(_host(SourceAddressDialog(
      origin: const SourceOrigin(id: 'test', name: '示例', primaryUrl: 'https://main.test'),
      onSave: (_, _, _) { calls++; return pending.future; },
    )));
    await tester.pumpAndSettle();
    final backups = find.descendant(of: find.byKey(const ValueKey('source-address-backups')),
      matching: find.byType(EditableText));
    final nine = List.generate(9, (i) => 'https://backup-$i.test').join('\n');
    await tester.enterText(backups, nine);
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(find.text('备用地址最多 8 个'), findsOneWidget);
    expect(tester.widget<EditableText>(backups).controller.text, nine);
    expect(tester.widget<ui.FilledButton>(find.byType(ui.FilledButton)).onPressed, isNotNull);
    await tester.enterText(backups, 'https://backup.test');
    await tester.tap(find.text('保存'));
    await tester.pump();
    expect(calls, 1);
    expect(find.text('备用地址最多 8 个'), findsNothing);
    expect(find.text('正在保存…'), findsOneWidget);
    expect(tester.widget<EditableText>(backups).readOnly, isTrue);
    await tester.pumpWidget(const SizedBox());
    pending.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
