import 'dart:ui' as semantics_ui;

import 'package:flutter/semantics.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/theme/miuix_palette.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

enum _Control { checkbox, switchControl, checkboxTile, switchTile }

bool _isCheckbox(_Control control) =>
    control == _Control.checkbox || control == _Control.checkboxTile;

Widget _host(Widget child) => MaterialApp(
  home: miuix.MiuixTheme(
    data: miuixThemeData(Brightness.light),
    child: Center(child: SizedBox(width: 320, child: child)),
  ),
);

Widget _control(
  _Control control, {
  required String label,
  required bool value,
  required ValueChanged<bool>? onChanged,
}) {
  switch (control) {
    case _Control.checkbox:
      // A bare checkbox has no title property. Its caller provides the name;
      // the control itself must still supply checked/enabled/action semantics.
      return MergeSemantics(
        child: Semantics(
          label: label,
          child: ui.Checkbox(
            value: value,
            onChanged: onChanged == null ? null : (v) => onChanged(v!),
          ),
        ),
      );
    case _Control.switchControl:
      return MergeSemantics(
        child: Semantics(
          label: label,
          child: ui.Switch(value: value, onChanged: onChanged),
        ),
      );
    case _Control.checkboxTile:
      // A tile already owns its title and toggle: it must expose one labelled
      // control without requiring its caller to merge the internal subtrees.
      return ui.CheckboxListTile(
        title: Text(label),
        value: value,
        onChanged: onChanged == null ? null : (v) => onChanged(v!),
      );
    case _Control.switchTile:
      return ui.SwitchListTile(
        title: Text(label),
        value: value,
        onChanged: onChanged,
      );
  }
}

SemanticsOwner _semanticsOwner(WidgetTester tester) =>
    tester.binding.renderViews.single.owner!.semanticsOwner!;

List<SemanticsNode> _exposedNodes(WidgetTester tester) {
  final root = _semanticsOwner(tester).rootSemanticsNode!;
  final result = <SemanticsNode>[];
  bool visit(SemanticsNode node) {
    // Merged descendants are implementation nodes, not additional controls
    // exposed to the accessibility service.
    if (!node.isMergedIntoParent) result.add(node);
    node.visitChildren(visit);
    return true;
  }

  visit(root);
  return result;
}

SemanticsNode _expectToggle(
  WidgetTester tester, {
  required _Control control,
  required String label,
  required bool value,
  required bool enabled,
}) {
  final nodes = _exposedNodes(tester);
  final named = nodes
      .where((node) => node.getSemanticsData().label == label)
      .toList();
  expect(named, hasLength(1), reason: 'The title must name one exposed node.');
  final node = named.single;
  final data = node.getSemanticsData();
  final flags = data.flagsCollection;
  if (_isCheckbox(control)) {
    expect(
      flags.isChecked,
      value
          ? semantics_ui.CheckedState.isTrue
          : semantics_ui.CheckedState.isFalse,
      reason: 'The labelled checkbox must expose its actual checked state.',
    );
    expect(flags.isToggled, semantics_ui.Tristate.none);
  } else {
    expect(
      flags.isToggled,
      value ? semantics_ui.Tristate.isTrue : semantics_ui.Tristate.isFalse,
      reason: 'The labelled switch must expose its actual toggled state.',
    );
    expect(flags.isChecked, semantics_ui.CheckedState.none);
  }
  expect(
    flags.isEnabled,
    enabled ? semantics_ui.Tristate.isTrue : semantics_ui.Tristate.isFalse,
  );
  expect(data.hasAction(semantics_ui.SemanticsAction.tap), enabled);

  final toggleNodes = nodes.where((candidate) {
    final flags = candidate.getSemanticsData().flagsCollection;
    return flags.isChecked != semantics_ui.CheckedState.none ||
        flags.isToggled != semantics_ui.Tristate.none;
  }).toList();
  expect(toggleNodes.map((node) => node.id).toList(), [
    node.id,
  ], reason: 'Do not expose a second unlabelled toggle beside the title.');
  final tapNodes = nodes
      .where(
        (candidate) => candidate.getSemanticsData().hasAction(
          semantics_ui.SemanticsAction.tap,
        ),
      )
      .toList();
  expect(
    tapNodes.map((node) => node.id).toList(),
    enabled ? [node.id] : <int>[],
    reason: 'The labelled row and its toggle must be one accessible action.',
  );
  return node;
}

void main() {
  for (final control in _Control.values) {
    for (final initialValue in [false, true]) {
      for (final enabled in [true, false]) {
        testWidgets(
          '${control.name} exposes label/state and ${enabled ? 'one tap' : 'no disabled tap'} from $initialValue',
          (tester) async {
            final semantics = tester.ensureSemantics();
            try {
              const label = '显示弹幕';
              var value = initialValue;
              final changes = <bool>[];
              await tester.pumpWidget(
                _host(
                  StatefulBuilder(
                    builder: (context, setState) => _control(
                      control,
                      label: label,
                      value: value,
                      onChanged: enabled
                          ? (next) {
                              changes.add(next);
                              setState(() => value = next);
                            }
                          : null,
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();
              final node = _expectToggle(
                tester,
                control: control,
                label: label,
                value: initialValue,
                enabled: enabled,
              );

              // Dispatch through the real semantics owner. Calling a widget's
              // callback directly would bypass the accessibility action wiring.
              _semanticsOwner(tester)
                  .performAction(node.id, semantics_ui.SemanticsAction.tap);
              await tester.pumpAndSettle();
              expect(changes, enabled ? [!initialValue] : <bool>[]);
              _expectToggle(
                tester,
                control: control,
                label: label,
                value: enabled ? !initialValue : initialValue,
                enabled: enabled,
              );
              expect(tester.takeException(), isNull);
            } finally {
              semantics.dispose();
            }
          },
        );
      }
    }
  }
}
