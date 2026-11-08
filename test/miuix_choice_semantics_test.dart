import 'dart:ui' as semantics_ui;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_popover.dart'
    show PlayerPopoverSurface, PopoverRow;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    themeAnimationDuration: Duration.zero,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: Center(child: child)),
  );
}

SemanticsNode _expectChoice(
  WidgetTester tester, {
  required String label,
  required bool selected,
  required bool enabled,
  bool requireButtonRole = true,
}) {
  final owner = tester.binding.renderViews.single.owner!.semanticsOwner!;
  final nodes = <SemanticsNode>[];
  bool visit(SemanticsNode node) {
    if (!node.isMergedIntoParent) nodes.add(node);
    node.visitChildren(visit);
    return true;
  }

  visit(owner.rootSemanticsNode!);
  final labelled = nodes.where(
    (node) => node.getSemanticsData().label == label,
  );
  expect(
    labelled,
    hasLength(1),
    reason: 'The choice must expose one labelled control.',
  );
  final node = labelled.single;
  final data = node.getSemanticsData();
  final flags = data.flagsCollection;
  if (requireButtonRole) {
    expect(
      flags.isButton,
      isTrue,
      reason: owner.rootSemanticsNode!.toStringDeep(),
    );
  }
  expect(
    flags.isSelected,
    selected ? semantics_ui.Tristate.isTrue : semantics_ui.Tristate.isFalse,
    reason: owner.rootSemanticsNode!.toStringDeep(),
  );
  expect(
    flags.isEnabled,
    enabled ? semantics_ui.Tristate.isTrue : semantics_ui.Tristate.isFalse,
  );
  expect(data.hasAction(semantics_ui.SemanticsAction.tap), enabled);
  final tapNodes = nodes.where(
    (candidate) => candidate.getSemanticsData().hasAction(
      semantics_ui.SemanticsAction.tap,
    ),
  );
  expect(
    tapNodes.map((candidate) => candidate.id).toList(),
    enabled ? [node.id] : <int>[],
    reason: 'Do not expose a second unlabelled action for the same choice.',
  );
  return node;
}

void main() {
  testWidgets(
    'popover row exposes one labelled selected action and suppresses disabled activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        const label = '1.5 倍';
        var selected = true;
        var enabled = true;
        final changes = <bool>[];
        late StateSetter update;
        await tester.pumpWidget(
          _host(
            StatefulBuilder(
              builder: (_, setState) {
                update = setState;
                return PlayerPopoverSurface(
                  width: 240,
                  child: PopoverRow(
                    label: label,
                    checked: selected,
                    onTap: enabled
                        ? () => setState(() {
                            selected = !selected;
                            changes.add(selected);
                          })
                        : null,
                  ),
                );
              },
            ),
          ),
        );
        expect(
          find.descendant(
            of: find.byType(PopoverRow),
            matching: find.byType(miuix.MiuixPressable),
          ),
          findsOneWidget,
        );
        // A menu choice may use a generic semantic role. Its visible label,
        // selected state and enabled action must still belong to one node.
        SemanticsNode expectRow({
          required bool selected,
          required bool enabled,
        }) => _expectChoice(
          tester,
          label: label,
          selected: selected,
          enabled: enabled,
          requireButtonRole: false,
        );

        var node = expectRow(selected: true, enabled: true);
        node.owner!.performAction(node.id, semantics_ui.SemanticsAction.tap);
        await tester.pump();
        expect(changes, [false]);
        expectRow(selected: false, enabled: true);

        update(() => enabled = false);
        await tester.pump();
        expectRow(selected: false, enabled: false);
        await tester.tap(find.text(label), warnIfMissed: false);
        await tester.pump();
        expect(changes, [false]);

        update(() => enabled = true);
        await tester.pump();
        node = expectRow(selected: false, enabled: true);
        node.owner!.performAction(node.id, semantics_ui.SemanticsAction.tap);
        await tester.pump();
        expect(changes, [false, true]);
        expectRow(selected: true, enabled: true);
        await tester.pumpWidget(const SizedBox.shrink());
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'choice and filter chips expose one labelled selected action and suppress disabled activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        for (final filter in [false, true]) {
          final label = filter ? '只看已收藏' : '当前线路';
          var selected = false;
          var enabled = true;
          final changes = <bool>[];
          late StateSetter update;
          await tester.pumpWidget(
            _host(
              StatefulBuilder(
                builder: (_, setState) {
                  update = setState;
                  void select(bool value) => setState(() {
                    changes.add(value);
                    selected = value;
                  });
                  return filter
                      ? ui.FilterChip(
                          label: Text(label),
                          selected: selected,
                          onSelected: enabled ? select : null,
                        )
                      : ui.ChoiceChip(
                          label: Text(label),
                          selected: selected,
                          onSelected: enabled ? select : null,
                        );
                },
              ),
            ),
          );
          expect(find.byType(miuix.MiuixButton), findsOneWidget);
          var node = _expectChoice(
            tester,
            label: label,
            selected: false,
            enabled: true,
          );
          node.owner!.performAction(node.id, semantics_ui.SemanticsAction.tap);
          await tester.pump();
          expect(changes, [true]);
          _expectChoice(tester, label: label, selected: true, enabled: true);
          update(() => enabled = false);
          await tester.pump();
          _expectChoice(tester, label: label, selected: true, enabled: false);
          await tester.tap(find.text(label), warnIfMissed: false);
          await tester.pump();
          expect(changes, [true]);
          update(() => enabled = true);
          await tester.pump();
          node = _expectChoice(
            tester,
            label: label,
            selected: true,
            enabled: true,
          );
          node.owner!.performAction(node.id, semantics_ui.SemanticsAction.tap);
          await tester.pump();
          expect(changes, [true, false]);
          _expectChoice(tester, label: label, selected: false, enabled: true);
          await tester.pumpWidget(const SizedBox.shrink());
          expect(tester.takeException(), isNull);
        }
      } finally {
        semantics.dispose();
      }
    },
  );
}
