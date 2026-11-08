@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player/episode_panel.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart'
    show PlayerBottomBar, PlayerPopoverIds;
import 'package:sourin_spike/ui/player/player_popover.dart'
    show PlayerPopoverSurface, PopoverRow;
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/episode_strip.dart' show LineChip;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as controls;

const _episodes = [
  Episode(id: 'A1', title: '第1集', index: 0, flag: '线路A'),
  Episode(id: 'A2', title: '第2集', index: 1, flag: '线路A'),
  Episode(id: 'B1', title: '第01集', index: 2, flag: '线路B'),
  Episode(id: 'B2', title: '第02集', index: 3, flag: '线路B'),
];

final _requests = <PlayRequest?>[];
final _pending = <Completer<List<StreamCandidate>>>[];

Finder get _tool => find.descendant(
  of: find.byType(PlayerBottomBar),
  matching: find.text('线路'),
);

Future<void> _mount(WidgetTester t, {bool showBottomBar = true}) async {
  await t.binding.setSurfaceSize(const Size(1280, 720));
  addTearDown(() => t.binding.setSurfaceSize(null));
  addTearDown(() async {
    await t.pumpWidget(const SizedBox.shrink());
    for (final pending in _pending) {
      if (!pending.isCompleted) pending.complete([]);
    }
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(seconds: 3));
    }
  });
  await t.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'dpad-fixture',
        id: 'series',
        title: '线路按键测试',
        episodes: _episodes,
        episodeIndex: 1,
        episodeId: 'A2',
        episodeTitle: '第2集',
        isTv: true,
      ),
    ),
  );
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 100));
  }
  expect(_requests, hasLength(1));
  if (!showBottomBar) {
    expect(debugPlayerErrorForProbe(), contains('没有可播放'));
    expect(find.byType(PlayerBottomBar), findsNothing);
    expect(find.text('线路'), findsOneWidget);
    return;
  }
  // Exercise real controls and key routing without opening any media.
  expect(debugPlayerForceBarsForShot(), isTrue);
  await t.pump(const Duration(milliseconds: 400));
  expect(debugPlayerErrorForProbe(), isNull);
  expect(
    _tool,
    findsOneWidget,
    reason:
        'The real bottom-bar line tool, not the error-layer entry, must exist.',
  );
}

FocusNode _controlNode(WidgetTester t, Finder target) {
  // Miuix buttons have an internal focus node excluded by the shared keyboard
  // adapter. Select the nearest eligible node within the actual control, never
  // an excluded package node or the page-level video shortcut handler.
  final boundary = find.ancestor(
    of: target,
    matching: find.byWidgetPredicate(
      (w) =>
          w is controls.TextButton ||
          w is controls.OutlinedButton ||
          w is controls.ChoiceChip ||
          w is PopoverRow,
    ),
  );
  expect(boundary, findsOneWidget);
  final control = t.element(boundary);
  final inner = Focus.of(t.element(target));
  final node = [inner, ...inner.ancestors].firstWhere((n) => n.canRequestFocus);
  var withinControl = identical(node.context, control);
  node.context?.visitAncestorElements((element) {
    if (identical(element, control)) withinControl = true;
    return !withinControl;
  });
  expect(
    withinControl,
    isTrue,
    reason: 'The control must own an eligible focus node.',
  );
  return node;
}

Future<void> _focus(WidgetTester t, Finder target) async {
  final node = _controlNode(t, target);
  node.requestFocus();
  await t.pump();
  expect(node.hasPrimaryFocus, isTrue);
}

Future<void> _openMenu(WidgetTester t) async {
  await _focus(t, _tool);
  expect(debugPlayerOpenPopoverForProbe(PlayerPopoverIds.lines), isTrue);
  await t.pump(const Duration(milliseconds: 200));
  expect(find.byType(PlayerPopoverSurface), findsOneWidget);
  expect(find.text('线路B'), findsOneWidget);
}

bool _focusIsWithin(WidgetTester t, Finder target) {
  final node = _controlNode(t, target);
  final current = FocusManager.instance.primaryFocus;
  return current == node || (current?.ancestors.contains(node) ?? false);
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() {
    _requests.clear();
    _pending.clear();
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async {
      _requests.add(req);
      if (_requests.length > 1) {
        final pending = Completer<List<StreamCandidate>>();
        _pending.add(pending);
        return pending.future;
      }
      return [];
    };
    SourinCore.debugCallAsyncTransport = (cmd, args) async {
      if (cmd == 'pan_cleanup_temp') return <String, dynamic>{};
      throw SourinCoreException('隔离接口没有数据', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
  });

  for (final key in [
    LogicalKeyboardKey.enter,
    LogicalKeyboardKey.select,
    LogicalKeyboardKey.gameButtonA,
  ]) {
    testWidgets(
      'TV-shaped failed line entry opens and selects with ${key.keyLabel}',
      (t) async {
        await _mount(t, showBottomBar: false);
        await _focus(t, find.text('线路'));
        final toggles = debugPlayerTogglePlayCalls();
        await t.sendKeyEvent(key);
        await t.pump(const Duration(milliseconds: 400));
        expect(
          find.byType(PlayerEpisodePanel),
          findsOneWidget,
          reason: 'An initial empty parser result must not trap remote users.',
        );
        expect(debugPlayerTogglePlayCalls(), toggles);
        final chip = find.byWidgetPredicate(
          (w) => w is LineChip && w.flag == '线路B',
        );
        await t.ensureVisible(chip);
        await _focus(t, find.descendant(of: chip, matching: find.text('线路B')));
        await t.sendKeyEvent(key);
        await t.pump(const Duration(milliseconds: 400));
        expect(_requests, hasLength(2));
        expect(_requests.last?.episodeId, 'B2');
        expect(_requests.last?.flag, '线路B');
        expect(
          t
              .widget<PlayerEpisodePanel>(find.byType(PlayerEpisodePanel))
              .selectedFlag,
          '线路B',
        );
        expect(debugPlayerTogglePlayCalls(), toggles);
        expect(t.takeException(), isNull);
      },
    );

    testWidgets('TV-shaped line tool opens with ${key.keyLabel}', (t) async {
      await _mount(t);
      await _focus(t, _tool);
      final toggles = debugPlayerTogglePlayCalls();
      await t.sendKeyEvent(key);
      await t.pump(const Duration(milliseconds: 200));
      expect(find.byType(PlayerPopoverSurface), findsOneWidget);
      expect(
        _focusIsWithin(t, find.text('线路A')),
        isTrue,
        reason: 'Opening must put keyboard focus on the current line.',
      );
      expect(debugPlayerTogglePlayCalls(), toggles);
      expect(t.takeException(), isNull);
    });
  }

  for (final key in [LogicalKeyboardKey.enter, LogicalKeyboardKey.select]) {
    testWidgets('TV-shaped line row selects with ${key.keyLabel}', (t) async {
      await _mount(t);
      await _openMenu(t);
      await _focus(t, find.text('线路B'));
      final toggles = debugPlayerTogglePlayCalls();
      await t.sendKeyEvent(key);
      await t.pump(const Duration(milliseconds: 200));
      expect(_requests, hasLength(2));
      expect(_requests.last?.flag, '线路B');
      expect(_requests.last?.episodeId, 'B2');
      expect(find.byType(PlayerPopoverSurface), findsNothing);
      expect(_focusIsWithin(t, _tool), isTrue);
      expect(debugPlayerTogglePlayCalls(), toggles);
      expect(t.takeException(), isNull);
    });
  }

  testWidgets(
    'TV-shaped line arrows move focus without seeking or changing volume',
    (t) async {
      await _mount(t);
      await _openMenu(t);
      await _focus(t, find.text('线路B'));
      final seeks = debugPlayerSeekByCalls();
      final volume = debugPlayerVolumeWrites();
      final toggles = debugPlayerTogglePlayCalls();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.pump();
      expect(_focusIsWithin(t, find.text('线路A')), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await t.pump();
      expect(_focusIsWithin(t, find.text('线路B')), isTrue);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.pump();
      expect(debugPlayerSeekByCalls(), seeks);
      expect(debugPlayerVolumeWrites(), volume);
      expect(debugPlayerTogglePlayCalls(), toggles);
      expect(_requests, hasLength(1));
      expect(t.takeException(), isNull);
    },
  );

  for (final key in [LogicalKeyboardKey.escape, LogicalKeyboardKey.goBack]) {
    testWidgets(
      'TV-shaped line ${key.keyLabel} closes and returns to its tool',
      (t) async {
        await _mount(t);
        await _openMenu(t);
        await _focus(t, find.text('线路B'));
        final toggles = debugPlayerTogglePlayCalls();
        await t.sendKeyEvent(
          key,
          physicalKey: key == LogicalKeyboardKey.goBack
              ? PhysicalKeyboardKey.escape
              : null,
        );
        await t.pump(const Duration(milliseconds: 200));
        expect(find.byType(PlayerPopoverSurface), findsNothing);
        expect(find.byType(PlayerPage), findsOneWidget);
        expect(_focusIsWithin(t, _tool), isTrue);
        expect(_requests, hasLength(1));
        expect(debugPlayerTogglePlayCalls(), toggles);
        expect(t.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'TV-shaped video focus keeps original seek volume and play keys',
    (t) async {
      await _mount(t);
      Focus.of(t.element(find.byType(PlayerBottomBar))).requestFocus();
      await t.pump();
      final seeks = debugPlayerSeekByCalls();
      final volume = debugPlayerVolumeWrites();
      final toggles = debugPlayerTogglePlayCalls();
      await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await t.sendKeyEvent(LogicalKeyboardKey.enter);
      await t.pump();
      expect(debugPlayerSeekByCalls(), seeks! + 1);
      expect(debugPlayerVolumeWrites(), isNot(volume));
      expect(debugPlayerTogglePlayCalls(), toggles! + 1);
      expect(find.byType(PlayerPopoverSurface), findsNothing);
      await t.pump(const Duration(seconds: 2));
      expect(t.takeException(), isNull);
    },
  );
}
