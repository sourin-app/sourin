import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:sourin_spike/ui/player/player_settings_portal.dart';
import 'package:sourin_spike/ui/widgets/miuix_tooltip_host.dart';

// The native AX failure captured on 2026-11-09 pointed at a settings portal.
// A reduced overlapping-portal scene reproduces an orphaned serialized node
// with the former zero-size, shared semantics anchor. The single-portal timing
// case guards further changes; native reproduction is validated separately.
// Observe actual updateNode arguments, not just widget presence.
void main() {
  final binding = _RecordingBinding();

  testWidgets(
    'switching a tooltip visibility source removes its serialized overlay',
    (tester) async {
      binding.recording.reset();
      final semantics = tester.ensureSemantics();
      final visible = ValueNotifier(true);
      final state = miuix.MiuixTooltipState(
        initialIsVisible: true,
        isPersistent: true,
      );
      final entry = OverlayEntry(
        builder: (_) => ValueListenableBuilder<bool>(
          valueListenable: visible,
          builder: (_, shown, __) => Focus(
            autofocus: true,
            child: Center(
              child: MiuixTooltipVisibility(
                visibility: shown
                    ? kAlwaysCompleteAnimation
                    : kAlwaysDismissedAnimation,
                child: Opacity(
                  opacity: shown ? 1 : 0,
                  child: MiuixTooltipHost(
                    state: state,
                    preferBelow: true,
                    spacing: 8,
                    tooltip: (_, __) => Semantics(
                      container: true,
                      label: 'Visibility tooltip',
                      child: const SizedBox(width: 120, height: 32),
                    ),
                    child: Semantics(
                      button: true,
                      label: 'Visible action',
                      child: const SizedBox(width: 48, height: 48),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(_overlayHost(entry));
        await tester.pump();
        await tester.pump(miuix.MiuixTooltipDefaults.animationDuration);
        _checkFrame(tester, binding, 'tooltip visible before source swap');
        binding.recording.overlayParentFor('Visibility tooltip');
        visible.value = false;
        await tester.pump();
        _checkFrame(tester, binding, 'visibility source swapped during build');
        await tester.pump();
        _checkFrame(tester, binding, 'hidden tooltip overlay removed');
        expect(find.bySemanticsLabel('Visibility tooltip'), findsNothing);
        expect(state.isVisible, isFalse);
      } finally {
        entry.remove();
        entry.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        visible.dispose();
        state.dispose();
      }
    },
  );

  testWidgets(
    'tooltip handoff preserves both serialized parents during crossfade',
    (tester) async {
      binding.recording.reset();
      final semantics = tester.ensureSemantics();
      final tooltips = List.generate(
        2,
        (_) => miuix.MiuixTooltipState(isPersistent: true),
      );
      final revision = ValueNotifier(0);
      final entry = OverlayEntry(
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: revision,
          builder: (_, value, __) => Focus(
            autofocus: true,
            child: Center(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var index = 0; index < tooltips.length; index++)
                    MiuixTooltipHost(
                      key: ValueKey('tooltip-$index'),
                      state: tooltips[index],
                      preferBelow: true,
                      spacing: 8,
                      tooltip: (_, __) => Semantics(
                        container: true,
                        label: 'Tooltip panel $index',
                        child: const SizedBox(width: 120, height: 32),
                      ),
                      child: Semantics(
                        button: true,
                        label: 'Action $index revision $value',
                        child: const SizedBox(width: 48, height: 48),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      try {
        await tester.pumpWidget(_overlayHost(entry));
        _checkFrame(tester, binding, 'tooltip anchors mounted');
        for (var cycle = 0; cycle < 3; cycle++) {
          tooltips[0].show();
          await tester.pump();
          await tester.pump();
          await tester.pump(miuix.MiuixTooltipDefaults.animationDuration);
          _checkFrame(tester, binding, 'cycle $cycle first tooltip visible');

          // The shared active state dismisses the first tooltip, but its
          // reverse animation still overlaps the second tooltip's entrance.
          tooltips[1].show();
          await tester.pump();
          await tester.pump();
          revision.value++;
          await tester.pump(const Duration(milliseconds: 90));
          _checkFrame(tester, binding, 'cycle $cycle tooltip crossfade');
          final parents = [
            binding.recording.overlayParentFor('Tooltip panel 0'),
            binding.recording.overlayParentFor('Tooltip panel 1'),
          ];
          expect(parents.toSet(), hasLength(2));
          for (final parent in parents) {
            expect(binding.recording.nodes[parent]!.rect.isEmpty, isFalse);
          }
          await tester.pump(miuix.MiuixTooltipDefaults.animationDuration);
          await tester.pump();
          _checkFrame(tester, binding, 'cycle $cycle first tooltip removed');
          tooltips[1].dismiss();
          await tester.pump();
          await tester.pump(miuix.MiuixTooltipDefaults.animationDuration);
          await tester.pump();
          _checkFrame(tester, binding, 'cycle $cycle both tooltips removed');
        }
      } finally {
        entry.remove();
        entry.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        revision.dispose();
        for (final state in tooltips) {
          state.dispose();
        }
      }
    },
  );

  testWidgets(
    'overlapping settings portals serialize distinct reachable parents',
    (tester) async {
      binding.recording.reset();
      final semantics = tester.ensureSemantics();
      final scene = ValueNotifier(const _Scene());
      final entry = OverlayEntry(
        builder: (_) => _sceneHost(scene, portalCount: 2),
      );
      try {
        await tester.pumpWidget(_overlayHost(entry));
        _checkFrame(tester, binding, 'initial hidden portals');

        scene.value = const _Scene(visible: true, controlsVisible: false);
        await tester.pump();
        _checkFrame(tester, binding, 'opening callbacks queued');
        await tester.pump();
        _checkFrame(tester, binding, 'both overlays submitted');

        final parents = <int>[
          binding.recording.portalParentFor('Settings panel 0'),
          binding.recording.portalParentFor('Settings panel 1'),
        ];
        expect(parents.toSet(), hasLength(2));
        for (final parent in parents) {
          expect(binding.recording.nodes[parent]!.rect.isEmpty, isFalse);
        }

        scene.value = const _Scene();
        await tester.pump();
        _checkFrame(tester, binding, 'both panel contents removed');
        await tester.pump();
        _checkFrame(tester, binding, 'both deferred overlays removed');
        expect(binding.recording.panelNodes, isEmpty);
      } finally {
        entry.remove();
        entry.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        scene.dispose();
      }
    },
  );

  testWidgets(
    'rapid settings opening and loading updates preserve serialized links',
    (tester) async {
      binding.recording.reset();
      final semantics = tester.ensureSemantics();
      final scene = ValueNotifier(const _Scene());
      final entry = OverlayEntry(
        builder: (_) => _sceneHost(scene, portalCount: 1),
      );
      try {
        await tester.pumpWidget(_overlayHost(entry));
        _checkFrame(tester, binding, 'player mounted while loading');

        int? mountedPortalParent;
        for (var cycle = 0; cycle < 3; cycle++) {
          // Deliberately do not settle or insert a delay: the native failure
          // occurred while opening settings immediately after playback started.
          scene.value = _Scene(
            visible: true,
            controlsVisible: false,
            loadingLabel: 'Loading $cycle',
          );
          await tester.pump();
          _checkFrame(tester, binding, 'cycle $cycle open scheduled');

          // The async loading update lands between portal.show() and its build.
          scene.value = _Scene(
            visible: true,
            controlsVisible: false,
            loadingLabel: 'Ready $cycle',
          );
          await tester.pump();
          _checkFrame(tester, binding, 'cycle $cycle open plus loading update');
          final parent = binding.recording.portalParentFor('Settings panel 0');
          mountedPortalParent ??= parent;
          expect(parent, mountedPortalParent);
          expect(binding.recording.nodes[parent]!.rect.isEmpty, isFalse);

          scene.value = _Scene(
            visible: true,
            controlsVisible: false,
            loadingLabel: 'Updated $cycle',
          );
          await tester.pump(const Duration(milliseconds: 16));
          _checkFrame(tester, binding, 'cycle $cycle loading changes again');
          expect(
            binding.recording.portalParentFor('Settings panel 0'),
            mountedPortalParent,
          );

          scene.value = _Scene(loadingLabel: 'Closed $cycle');
          await tester.pump();
          _checkFrame(
            tester,
            binding,
            'cycle $cycle content removed before hide',
          );
          await tester.pump();
          _checkFrame(tester, binding, 'cycle $cycle deferred overlay removed');
          expect(binding.recording.panelNodes, isEmpty);
        }
      } finally {
        entry.remove();
        entry.dispose();
        await tester.pumpWidget(const SizedBox.shrink());
        semantics.dispose();
        scene.dispose();
      }
    },
  );
}

Widget _overlayHost(OverlayEntry entry) => Directionality(
  textDirection: TextDirection.ltr,
  child: MediaQuery(
    data: const MediaQueryData(size: Size(800, 600)),
    child: Overlay(initialEntries: [entry]),
  ),
);

// This reduced host retains the production ownership and layout: an enclosing
// Focus, changing loading text and controls, and non-Positioned settings portals
// inside a bounded Stack. The overlay builder also returns shrink before hide.
Widget _sceneHost(ValueNotifier<_Scene> scene, {required int portalCount}) =>
    ValueListenableBuilder<_Scene>(
      valueListenable: scene,
      builder: (_, state, __) => Focus(
        autofocus: true,
        child: SizedBox.expand(
          child: Stack(
            children: [
              Text(state.loadingLabel),
              Opacity(
                opacity: state.controlsVisible ? 1 : 0,
                child: Semantics(
                  button: true,
                  child: const SizedBox(
                    width: 48,
                    height: 48,
                    child: Text('Controls'),
                  ),
                ),
              ),
              for (var index = 0; index < portalCount; index++)
                PlayerSettingsPortal(
                  key: ValueKey('settings-$index'),
                  visible: state.visible,
                  overlayChildBuilder: (_) => scene.value.visible
                      ? Positioned.fill(
                          child: Semantics(
                            container: true,
                            label: 'Settings panel $index',
                            child: const SizedBox.expand(),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
            ],
          ),
        ),
      ),
    );

class _Scene {
  const _Scene({
    this.visible = false,
    this.controlsVisible = true,
    this.loadingLabel = 'Loading',
  });

  final bool visible;
  final bool controlsVisible;
  final String loadingLabel;
}

void _checkFrame(WidgetTester tester, _RecordingBinding binding, String stage) {
  expect(tester.takeException(), isNull, reason: stage);
  final rootIds = <int>[];
  void visitOwner(PipelineOwner owner) {
    final root = owner.semanticsOwner?.rootSemanticsNode;
    if (root != null) rootIds.add(root.id);
    owner.visitChildren(visitOwner);
  }

  visitOwner(binding.rootPipelineOwner);
  expect(rootIds, hasLength(1), reason: stage);
  binding.recording.checkPending(rootIds.single, stage);
}

class _RecordingBinding extends AutomatedTestWidgetsFlutterBinding {
  final recording = _SerializedTree();

  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _RecordingBuilder(
    super.createSemanticsUpdateBuilder(),
    recording.batches.add,
  );
}

class _SerializedNode {
  _SerializedNode({
    required this.id,
    required this.traversalParent,
    required this.rect,
    required this.label,
    required Iterable<int> traversalChildren,
    required Iterable<int> hitTestChildren,
  }) : traversalChildren = List.unmodifiable(traversalChildren),
       hitTestChildren = List.unmodifiable(hitTestChildren);

  final int id;
  final int traversalParent;
  final Rect rect;
  final String label;
  final List<int> traversalChildren;
  final List<int> hitTestChildren;
}

class _SerializedTree {
  final batches = <List<_SerializedNode>>[];
  final nodes = <int, _SerializedNode>{};
  int _checkedBatches = 0;

  Iterable<_SerializedNode> get panelNodes =>
      nodes.values.where((node) => node.label.startsWith('Settings panel '));

  void reset() {
    batches.clear();
    nodes.clear();
    _checkedBatches = 0;
  }

  void checkPending(int rootId, String stage) {
    while (_checkedBatches < batches.length) {
      final batch = batches[_checkedBatches++];
      final context = '$stage / semantics batch $_checkedBatches';
      expect(
        batch.map((node) => node.id).toSet(),
        hasLength(batch.length),
        reason: '$context: duplicate node update',
      );
      for (final node in batch) {
        nodes[node.id] = node;
      }
      final traversal = _reachable(rootId, hitTest: false, context: context);
      final hitTest = _reachable(rootId, hitTest: true, context: context);
      expect(
        hitTest,
        unorderedEquals(traversal),
        reason: '$context: traversal and hit-test trees disagree',
      );
      for (final node in batch) {
        expect(
          traversal,
          contains(node.id),
          reason: '$context: submitted node ${node.id} is orphaned',
        );
      }
      for (final id in traversal) {
        final node = nodes[id]!;
        if (node.traversalParent < 0) continue;
        expect(
          traversal,
          contains(node.traversalParent),
          reason: '$context: node $id has an unreachable portal parent',
        );
        expect(
          nodes[node.traversalParent]!.traversalChildren,
          contains(id),
          reason: '$context: portal parent does not include child $id',
        );
      }
      // The native tree deletes disconnected nodes. Retaining them here would
      // let a later dangling reference incorrectly pass using historical data.
      nodes.removeWhere((id, _) => !traversal.contains(id));
    }
  }

  Set<int> _reachable(
    int rootId, {
    required bool hitTest,
    required String context,
  }) {
    final visited = <int>{};
    void visit(int id) {
      expect(
        visited.add(id),
        isTrue,
        reason: '$context: cycle or multiple parents for node $id',
      );
      expect(
        nodes,
        contains(id),
        reason: '$context: reference to absent node $id',
      );
      final node = nodes[id]!;
      for (final child
          in hitTest ? node.hitTestChildren : node.traversalChildren) {
        visit(child);
      }
    }

    visit(rootId);
    return visited;
  }

  int portalParentFor(String panelLabel) {
    var node = nodes.values.singleWhere((node) => node.label == panelLabel);
    final seen = <int>{};
    while (node.traversalParent < 0) {
      expect(seen.add(node.id), isTrue);
      final parents = nodes.values.where(
        (parent) => parent.traversalChildren.contains(node.id),
      );
      expect(
        parents,
        hasLength(1),
        reason: 'Missing portal link for $panelLabel',
      );
      node = parents.single;
    }
    return node.traversalParent;
  }

  int overlayParentFor(String label) {
    final child = nodes.values.singleWhere((node) => node.label == label);
    final parents = nodes.values.where(
      (node) => node.traversalChildren.contains(child.id),
    );
    expect(parents, hasLength(1), reason: 'Missing overlay owner for $label');
    final parent = parents.single;
    return parent.id;
  }
}

// Forward every call to the real builder. The copy only observes the same
// arguments the framework submits to dart:ui; it does not repair its graph.
class _RecordingBuilder implements ui.SemanticsUpdateBuilder {
  _RecordingBuilder(this._delegate, this._onBuild);

  final ui.SemanticsUpdateBuilder _delegate;
  final void Function(List<_SerializedNode>) _onBuild;
  final _nodes = <_SerializedNode>[];

  @override
  void updateNode({
    required int id,
    required ui.SemanticsFlags flags,
    required int actions,
    required int maxValueLength,
    required int currentValueLength,
    required int textSelectionBase,
    required int textSelectionExtent,
    required int platformViewId,
    required int scrollChildren,
    required int scrollIndex,
    required int traversalParent,
    required double scrollPosition,
    required double scrollExtentMax,
    required double scrollExtentMin,
    required ui.Rect rect,
    required String identifier,
    required String label,
    required List<ui.StringAttribute> labelAttributes,
    required String value,
    required List<ui.StringAttribute> valueAttributes,
    required String increasedValue,
    required List<ui.StringAttribute> increasedValueAttributes,
    required String decreasedValue,
    required List<ui.StringAttribute> decreasedValueAttributes,
    required String hint,
    required List<ui.StringAttribute> hintAttributes,
    required String tooltip,
    required ui.TextDirection? textDirection,
    required Float64List transform,
    required Float64List hitTestTransform,
    required Int32List childrenInTraversalOrder,
    required Int32List childrenInHitTestOrder,
    required Int32List additionalActions,
    int headingLevel = 0,
    String linkUrl = '',
    ui.SemanticsRole role = ui.SemanticsRole.none,
    required List<String>? controlsNodes,
    ui.SemanticsValidationResult validationResult =
        ui.SemanticsValidationResult.none,
    ui.SemanticsHitTestBehavior hitTestBehavior =
        ui.SemanticsHitTestBehavior.defer,
    required ui.SemanticsInputType inputType,
    required ui.Locale? locale,
    required String minValue,
    required String maxValue,
  }) {
    _nodes.add(
      _SerializedNode(
        id: id,
        traversalParent: traversalParent,
        rect: rect,
        label: label,
        traversalChildren: childrenInTraversalOrder,
        hitTestChildren: childrenInHitTestOrder,
      ),
    );
    _delegate.updateNode(
      id: id,
      flags: flags,
      actions: actions,
      maxValueLength: maxValueLength,
      currentValueLength: currentValueLength,
      textSelectionBase: textSelectionBase,
      textSelectionExtent: textSelectionExtent,
      platformViewId: platformViewId,
      scrollChildren: scrollChildren,
      scrollIndex: scrollIndex,
      traversalParent: traversalParent,
      scrollPosition: scrollPosition,
      scrollExtentMax: scrollExtentMax,
      scrollExtentMin: scrollExtentMin,
      rect: rect,
      identifier: identifier,
      label: label,
      labelAttributes: labelAttributes,
      value: value,
      valueAttributes: valueAttributes,
      increasedValue: increasedValue,
      increasedValueAttributes: increasedValueAttributes,
      decreasedValue: decreasedValue,
      decreasedValueAttributes: decreasedValueAttributes,
      hint: hint,
      hintAttributes: hintAttributes,
      tooltip: tooltip,
      textDirection: textDirection,
      transform: transform,
      hitTestTransform: hitTestTransform,
      childrenInTraversalOrder: childrenInTraversalOrder,
      childrenInHitTestOrder: childrenInHitTestOrder,
      additionalActions: additionalActions,
      headingLevel: headingLevel,
      linkUrl: linkUrl,
      role: role,
      controlsNodes: controlsNodes,
      validationResult: validationResult,
      hitTestBehavior: hitTestBehavior,
      inputType: inputType,
      locale: locale,
      minValue: minValue,
      maxValue: maxValue,
    );
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => _delegate.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );

  @override
  ui.SemanticsUpdate build() {
    final update = _delegate.build();
    _onBuild(List.unmodifiable(_nodes));
    return update;
  }
}
