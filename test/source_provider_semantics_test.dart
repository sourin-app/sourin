import 'dart:async';
import 'dart:ui' as semantics_ui;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

const _labelA = 'Subscription A\nShared source A';
const _labelB = 'Subscription B\nShared source B';

List<SemanticsNode> _nodes(WidgetTester tester) {
  final root = tester.binding.renderViews.single.owner!.semanticsOwner!
      .rootSemanticsNode!;
  final result = <SemanticsNode>[];
  final seen = <int>{};
  void visit(SemanticsNode node) {
    expect(seen.add(node.id), isTrue, reason: 'Every live semantic node has one parent');
    if (!node.isMergedIntoParent) result.add(node);
    node.visitChildren((child) {
      expect(child.parent, same(node));
      visit(child);
      return true;
    });
  }
  visit(root);
  return result;
}

SemanticsNode _named(WidgetTester tester, String label) {
  final found = _nodes(tester).where((node) => node.getSemanticsData().label == label);
  expect(found, hasLength(1), reason: 'A complete provider label names one accessible row');
  return found.single;
}

void _expectSwitch(WidgetTester tester, String label, bool selected, bool enabled) {
  final data = _named(tester, label).getSemanticsData();
  expect(data.flagsCollection.isToggled,
      selected ? semantics_ui.Tristate.isTrue : semantics_ui.Tristate.isFalse);
  expect(data.flagsCollection.isChecked, semantics_ui.CheckedState.none,
      reason: 'The provider switch must not also expose an unrelated unchecked checkbox');
  expect(data.flagsCollection.isEnabled,
      enabled ? semantics_ui.Tristate.isTrue : semantics_ui.Tristate.isFalse);
  expect(data.hasAction(semantics_ui.SemanticsAction.tap), enabled);
  final toggles = _nodes(tester).where((node) {
    final flags = node.getSemanticsData().flagsCollection;
    return flags.isToggled != semantics_ui.Tristate.none ||
        flags.isChecked != semantics_ui.CheckedState.none;
  });
  expect(toggles.map((node) => node.getSemanticsData().label),
      unorderedEquals([_labelA, _labelB]),
      reason: 'No duplicate unlabelled package toggle is exposed');
}

Future<void> _mountDialog(
  WidgetTester tester,
  Future<void> Function(List<String>) save,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(860, 904);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: Builder(builder: (context) => Center(
      child: ui.TextButton(
        onPressed: () => showAppDialog<bool>(
          context: context,
          builder: (_) => SourceProvidersDialog(
            group: const SourceOriginGroup(
              id: 'shared', name: 'Shared source',
              providerIds: ['a', 'b'], selectedProviderIds: ['a', 'b'],
            ),
            providers: [
              for (final id in ['a', 'b']) ProviderManifest.fromJson({
                'id': id, 'name': 'Shared source ${id.toUpperCase()}',
                'kind': 'tvbox', 'capabilities': {'vod': true},
              }),
            ],
            origins: const [
              SourceOrigin(id: 'origin-a', name: 'Subscription A', providerIds: ['a']),
              SourceOrigin(id: 'origin-b', name: 'Subscription B', providerIds: ['b']),
            ],
            onSave: save,
          ),
        ),
        child: const Text('Open providers'),
      ),
    ))),
  ));
  await tester.tap(find.text('Open providers'));
  await tester.pumpAndSettle();
  expect(find.byType(SourceProvidersDialog), findsOneWidget);
  expect(find.byType(miuix.MiuixSwitchPreference), findsNWidgets(2));
}

Finder _choice(String id) => find.byKey(ValueKey('source-provider-choice-$id'));
bool _selected(WidgetTester tester, String id) =>
    tester.widget<miuix.MiuixSwitchPreference>(_choice(id)).value;

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('provider accessibility exposes one labelled switch and invokes the actual draft action once', (tester) async {
    final semantics = tester.ensureSemantics();
    final saved = <List<String>>[];
    try {
      await _mountDialog(tester, (ids) async => saved.add(List.of(ids)));
      _expectSwitch(tester, _labelA, true, true);
      _expectSwitch(tester, _labelB, true, true);
      final first = _named(tester, _labelA);
      first.owner!.performAction(first.id, semantics_ui.SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(_selected(tester, 'a'), isFalse);
      expect(_selected(tester, 'b'), isTrue);
      expect(saved, isEmpty, reason: 'Accessible activation changes only the draft until Save');
      _expectSwitch(tester, _labelA, false, true);
      expect(_named(tester, _labelA).id, first.id);
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saved, [['b']]);
      expect(find.byType(SourceProvidersDialog), findsNothing);
      expect(_nodes(tester).where((node) => node.getSemanticsData().label == _labelA), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await _unmount(tester);
      semantics.dispose();
    }
  });

  testWidgets('provider label node and parent survive pending save and failed-save restoration', (tester) async {
    final semantics = tester.ensureSemantics();
    final pending = Completer<void>();
    final saves = <List<String>>[];
    try {
      await _mountDialog(tester, (ids) {
        saves.add(List.of(ids));
        return pending.future;
      });
      await tester.tap(_choice('a'));
      await tester.pumpAndSettle();
      final before = _named(tester, _labelA);
      final id = before.id;
      final parent = before.parent!.id;
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect(saves, [['b']]);
      for (var frame = 0; frame < 5; frame++) {
        await tester.pump(const Duration(milliseconds: 20));
        final current = _named(tester, _labelA);
        expect(current.id, id,
            reason: 'Disabling a row must not merge away the node still referenced by native accessibility');
        expect(current.parent!.id, parent);
        _expectSwitch(tester, _labelA, false, false);
        _expectSwitch(tester, _labelB, true, false);
        current.owner!.performAction(id, semantics_ui.SemanticsAction.tap);
        expect(_selected(tester, 'a'), isFalse);
        expect(saves, [['b']]);
      }
      pending.completeError(StateError('Owned save failure'));
      await tester.pumpAndSettle();
      final restored = _named(tester, _labelA);
      expect(restored.id, id);
      expect(restored.parent!.id, parent);
      _expectSwitch(tester, _labelA, false, true);
      restored.owner!.performAction(id, semantics_ui.SemanticsAction.tap);
      await tester.pumpAndSettle();
      expect(_selected(tester, 'a'), isTrue);
      _expectSwitch(tester, _labelA, true, true);
      expect(tester.takeException(), isNull);
    } finally {
      if (!pending.isCompleted) pending.complete();
      await _unmount(tester);
      semantics.dispose();
    }
  });

  testWidgets('pending successful provider save preserves semantic identity until original dialog disposal', (tester) async {
    final semantics = tester.ensureSemantics();
    final pending = Completer<void>();
    try {
      await _mountDialog(tester, (_) => pending.future);
      final beforeA = _named(tester, _labelA);
      final beforeB = _named(tester, _labelB);
      final ids = [beforeA.id, beforeB.id];
      await tester.tap(find.text('保存'));
      await tester.pump();
      expect([_named(tester, _labelA).id, _named(tester, _labelB).id], ids);
      _expectSwitch(tester, _labelA, true, false);
      pending.complete();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(find.byType(SourceProvidersDialog), findsNothing);
      expect(_nodes(tester).where((node) => ids.contains(node.id)), isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      if (!pending.isCompleted) pending.complete();
      await _unmount(tester);
      semantics.dispose();
    }
  });
}
