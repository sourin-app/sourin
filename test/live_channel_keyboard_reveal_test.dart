import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

const _provider = 'fixture_primary';
const _otherProvider = 'fixture_other';
const _first = 'channel-0';

class _LiveReadFixture {
  _LiveReadFixture({required this.long});

  final bool long;
  final streams = <({String provider, String id})>[];
  final unexpected = <String>[];

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    if (command == 'get_live_channels') {
      return [
        {
          'provider': _provider,
          'providerName': 'Fixture primary',
          'channels': [
            for (var index = 0; index < (long ? 80 : 3); index++)
              {'id': 'channel-$index', 'name': 'Fixture channel $index'},
          ],
        },
        if (long)
          {
            'provider': _otherProvider,
            'providerName': 'Fixture other',
            'channels': [
              // Native IDs may collide across providers. Wrapping to this row
              // must not select/focus the first provider's identically named ID.
              {'id': _first, 'name': 'Fixture final channel'},
            ],
          },
      ];
    }
    if (command == 'get_live_stream') {
      streams.add((
        provider: args!['provider'] as String,
        id: args['channel_id'] as String,
      ));
      // No media address, stream preparation request or native decode is needed
      // to verify the real page's keyboard, selection and lazy-list rendering.
      return <dynamic>[];
    }
    unexpected.add(command);
    throw StateError('Unexpected live keyboard fixture command: $command');
  }
}

Finder _list() => find.descendant(
  of: find.byType(LiveChannelList),
  matching: find.byType(ListView),
);

Finder _tile(String provider, String id) =>
    find.byKey(liveChannelTileKey(provider, id));

Finder _highlight(String provider, String id) =>
    find.byKey(liveChannelHighlightKey(provider, id));

Set<String> _selectedRenderedRows() {
  const prefix = 'live-channel-highlight-';
  final selected = <String>{};
  for (final element in find.byType(miuix.MiuixCard).evaluate()) {
    final key = element.widget.key;
    if (key is! ValueKey<String> || !key.value.startsWith(prefix)) continue;
    var active = false;
    element.visitAncestorElements((ancestor) {
      final widget = ancestor.widget;
      if (widget is Semantics && widget.properties.selected != null) {
        active = widget.properties.selected!;
        return false;
      }
      return true;
    });
    if (active) selected.add(key.value.substring(prefix.length));
  }
  return selected;
}

void _expectLogicalSelection(
  WidgetTester tester,
  String provider,
  String id,
) {
  expect(
    tester.widget<LiveChannelList>(find.byType(LiveChannelList)).selectedRow,
    liveChannelRowKey(provider, id),
    reason: 'The actual keyboard path must first choose the expected identity',
  );
}

void _expectSelectedVisibleAndFocused(
  WidgetTester tester,
  String provider,
  String id,
) {
  _expectLogicalSelection(tester, provider, id);
  final target = _tile(provider, id);
  expect(target, findsOneWidget,
      reason: 'The selected lazy-list target must actually be mounted');
  expect(target.hitTestable(), findsOneWidget,
      reason: 'The selected channel must be reachable in the list viewport');
  final viewport = tester.getRect(_list());
  final row = tester.getRect(target);
  expect(row.left, greaterThanOrEqualTo(viewport.left - .5));
  expect(row.right, lessThanOrEqualTo(viewport.right + .5));
  expect(row.top, greaterThanOrEqualTo(viewport.top - .5));
  expect(row.bottom, lessThanOrEqualTo(viewport.bottom + .5));
  final pressable = tester.widget<miuix.MiuixPressable>(target);
  expect(pressable.focusNode?.hasFocus, isTrue,
      reason: 'Keyboard focus must follow the selected channel row');
  expect(_selectedRenderedRows(), {liveChannelRowKey(provider, id)},
      reason: 'Exactly the selected provider/native row remains highlighted');
  final card = tester.widget<miuix.MiuixCard>(_highlight(provider, id));
  final colors = miuix.MiuixTheme.of(tester.element(_highlight(provider, id))).colors;
  expect(card.colors?.color, colors.primary.withValues(alpha: .12));
  expect(tester.takeException(), isNull);
}

Future<void> _finishReveal(WidgetTester tester) async {
  // Multiple frames let a lazy implementation approach an unmounted row and
  // then use its real bounds. No tester scroll/ensureVisible runs after a key.
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  await tester.pump();
}

Future<void> _mount(
  WidgetTester tester,
  _LiveReadFixture fixture,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  SourinCore.debugCallAsyncTransport = fixture.call;
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: const Scaffold(body: LivePage()),
  ));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(fixture.unexpected, isEmpty);
  });
  for (var frame = 0; frame < 5; frame++) {
    await tester.pump();
  }
  expect(find.byType(LiveChannelList), findsOneWidget);
  expect(_list(), findsOneWidget);
  _expectLogicalSelection(tester, _provider, _first);
  expect(fixture.streams, [(provider: _provider, id: _first)]);
  final first = tester.widget<miuix.MiuixPressable>(_tile(_provider, _first));
  // Establish the same starting keyboard focus as a previously used row.
  // Subsequent target focus is entirely owned by production behavior.
  first.focusNode!.requestFocus();
  await tester.pump();
  _expectSelectedVisibleAndFocused(tester, _provider, _first);
  if (fixture.long) {
    expect(_tile(_otherProvider, _first), findsNothing,
        reason: 'The last identity starts outside the mounted lazy window');
    expect(
      find.byWidgetPredicate((widget) => widget is miuix.MiuixPressable &&
          widget.key is ValueKey<String> &&
          (widget.key! as ValueKey<String>).value.startsWith('live-channel-'))
          .evaluate().length,
      lessThan(30),
      reason: 'The fixture must not solve reveal by mounting all 81 rows',
    );
  }
}

void main() {
  late Future<dynamic> Function(String, Map<String, dynamic>?)? previousTransport;
  late Future<List<LiveGroup>> Function()? previousGroups;
  late Future<List<StreamCandidate>> Function(String, String)? previousStreams;
  late bool previousSkipPlayer;
  late bool? previousForcePlaying;
  late String? previousDirectory;
  late bool previousHitWarnings;

  setUp(() {
    previousTransport = SourinCore.debugCallAsyncTransport;
    previousGroups = LivePageState.debugLiveGroupsFetcher;
    previousStreams = SourinApi.debugLiveStreamFetcher;
    previousSkipPlayer = debugSkipPlayerCreation;
    previousForcePlaying = debugForcePlaying;
    previousDirectory = DiskCache.dataDir;
    previousHitWarnings = WidgetController.hitTestWarningShouldBeFatal;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    LivePageState.debugLiveGroupsFetcher = null;
    SourinApi.debugLiveStreamFetcher = null;
    SourinApi.debugClearLiveStreamCache();
    debugSkipPlayerCreation = true;
    debugForcePlaying = null;
    WidgetController.hitTestWarningShouldBeFatal = true;
  });

  tearDown(() {
    SourinCore.debugCallAsyncTransport = previousTransport;
    LivePageState.debugLiveGroupsFetcher = previousGroups;
    SourinApi.debugLiveStreamFetcher = previousStreams;
    SourinApi.debugClearLiveStreamCache();
    debugSkipPlayerCreation = previousSkipPlayer;
    debugForcePlaying = previousForcePlaying;
    DiskCache.debugResetForTest(previousDirectory);
    UiPrefs.debugResetForTest(<String, String>{});
    WidgetController.hitTestWarningShouldBeFatal = previousHitWarnings;
  });

  testWidgets('up wraps to an unmounted final provider row and reveals its focus', (
    tester,
  ) async {
    final fixture = _LiveReadFixture(long: true);
    await _mount(tester, fixture);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await _finishReveal(tester);
    expect(fixture.streams.last, (provider: _otherProvider, id: _first));
    _expectSelectedVisibleAndFocused(tester, _otherProvider, _first);
  });

  testWidgets('down wraps from a clicked last row to an unmounted first row', (
    tester,
  ) async {
    final fixture = _LiveReadFixture(long: true);
    await _mount(tester, fixture);
    final scrollable = find.descendant(
      of: _list(),
      matching: find.byType(Scrollable),
    );
    // Scrolling is only a setup action here. The later wrap must reveal itself.
    await tester.scrollUntilVisible(
      _tile(_otherProvider, _first),
      500,
      scrollable: scrollable,
    );
    await tester.tap(_tile(_otherProvider, _first));
    await _finishReveal(tester);
    _expectSelectedVisibleAndFocused(tester, _otherProvider, _first);
    expect(_tile(_provider, _first), findsNothing,
        reason: 'The first identity must be outside the lazy window before wrap');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishReveal(tester);
    expect(fixture.streams.last, (provider: _provider, id: _first));
    _expectSelectedVisibleAndFocused(tester, _provider, _first);
  });

  testWidgets('rapid downward keys keep a far selected row visible and focused', (
    tester,
  ) async {
    final fixture = _LiveReadFixture(long: true);
    await _mount(tester, fixture);
    for (var index = 0; index < 55; index++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump(const Duration(milliseconds: 10));
    }
    await _finishReveal(tester);
    expect(fixture.streams.last, (provider: _provider, id: 'channel-55'));
    _expectSelectedVisibleAndFocused(tester, _provider, 'channel-55');
  });

  testWidgets('short-list directional movement and both wraps retain one focus', (
    tester,
  ) async {
    final fixture = _LiveReadFixture(long: false);
    await _mount(tester, fixture);
    for (final (key, id) in [
      (LogicalKeyboardKey.arrowDown, 'channel-1'),
      (LogicalKeyboardKey.arrowUp, _first),
      (LogicalKeyboardKey.arrowUp, 'channel-2'),
      (LogicalKeyboardKey.arrowDown, _first),
    ]) {
      await tester.sendKeyEvent(key);
      await _finishReveal(tester);
      _expectSelectedVisibleAndFocused(tester, _provider, id);
    }
  });

  testWidgets('a newer visible keyboard choice cancels a pending distant reveal', (
    tester,
  ) async {
    final fixture = _LiveReadFixture(long: true);
    await _mount(tester, fixture);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    _expectLogicalSelection(tester, _otherProvider, _first);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await _finishReveal(tester);
    _expectSelectedVisibleAndFocused(tester, _provider, _first);
  });

  testWidgets('disposing with a pending distant reveal leaves no callbacks', (
    tester,
  ) async {
    final fixture = _LiveReadFixture(long: true);
    await _mount(tester, fixture);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    await _finishReveal(tester);
    expect(find.byType(LiveChannelList), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
