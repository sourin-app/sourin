@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const _episode = Episode(id: 'episode-1', title: 'Episode 1', index: 0);
const _signedTip =
    'Playback request failed: Failed to open '
    'https://fixture-viewer:fixture-password@media.example.invalid/'
    'fixture-private-path?token=fixture-query-secret&time=1790000000000.\n'
    'Authorization: Bearer fixture-bearer-secret\n'
    'Cookie: fixture-cookie-secret\n'
    'signature=fixture-detached-signature; retry may succeed';

String _visibleText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((text) => text.data ?? text.textSpan?.toPlainText() ?? '')
    .join('\n');

void _requireIsolatedEnvironment() {
  expect(Platform.isWindows, isTrue);
  expect(Platform.environment['SOURIN_NO_REMOTE_AUTOSTART'], '1');
  final probeRoot =
      '${Directory.current.absolute.path}${Platform.pathSeparator}.probe';
  final probePrefix = '$probeRoot${Platform.pathSeparator}'.toLowerCase();
  for (final name in [
    'USERPROFILE',
    'HOME',
    'APPDATA',
    'LOCALAPPDATA',
    'TMP',
    'TEMP',
  ]) {
    final value = Platform.environment[name] ?? '';
    expect(value, isNotEmpty, reason: 'An isolated $name is required.');
    expect(
      Directory(value).absolute.path.toLowerCase().startsWith(probePrefix),
      isTrue,
      reason: '$name must be under this repository probe directory.',
    );
  }
}

Future<void> _mountInactivePlayer(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (var i = 0; i < 60; i++) {
      await tester.pump(const Duration(seconds: 3));
    }
  });
  await tester.pumpWidget(
    const MaterialApp(
      home: PlayerPage(
        provider: 'tip-privacy-fixture',
        id: 'series',
        title: 'Tip privacy fixture',
        episodes: [_episode],
        episodeIndex: 0,
        episodeId: 'episode-1',
      ),
    ),
  );
  await tester.pump();
  expect(debugPlayerSessionKeyForProbe(), 'tip-privacy-fixture:series');
  expect(debugPlayerLoadCallsForProbe(), 1);
  expect(debugPlayerStartPlaybackCallsForProbe(), 0);
  expect(debugPlayerLastTip(), isNull);
  expect(tester.takeException(), isNull);
}

void main() {
  setUpAll(() {
    _requireIsolatedEnvironment();
    final native = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(native.existsSync(), isTrue, reason: 'Native fixture is required.');
    MediaKit.ensureInitialized(libmpv: native.absolute.path);
  });

  setUp(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async => [];
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinCore.debugCallAsyncTransport = (command, arguments) async {
      if (command == 'get_progress') return null;
      if (command == 'pan_cleanup_temp') return <String, dynamic>{};
      throw SourinCoreException('Unarmed fixture has no data', 'other');
    };
  });

  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
  });

  testWidgets(
    'production TipBubble hides signed fields without rewriting raw tip',
    (tester) async {
      await _mountInactivePlayer(tester);
      expect(debugPlayerFlashForProbe(_signedTip), isTrue);
      await tester.pump();
      expect(debugPlayerLastTip(), _signedTip);
      final visible = _visibleText(tester);
      for (final marker in [
        'https://',
        'fixture-viewer',
        'fixture-password',
        'fixture-private-path',
        'fixture-query-secret',
        '1790000000000',
        'fixture-bearer-secret',
        'fixture-cookie-secret',
        'fixture-detached-signature',
      ]) {
        expect(
          visible.contains(marker),
          isFalse,
          reason: 'Production TipBubble must hide synthetic private fields.',
        );
      }
      expect(
        find.text(PlaybackErrorText.forDisplay(_signedTip)),
        findsOneWidget,
      );
      expect(visible, contains('retry may succeed'));
      expect(tester.takeException(), isNull);

      await tester.pump(const Duration(milliseconds: 1199));
      expect(debugPlayerLastTip(), _signedTip);
      await tester.pump(const Duration(milliseconds: 1));
      expect(debugPlayerLastTip(), isNull);
      expect(
        find.text(PlaybackErrorText.forDisplay(_signedTip)),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'ordinary tip replacement preserves the original 1200ms timeout',
    (tester) async {
      await _mountInactivePlayer(tester);
      expect(debugPlayerFlashForProbe('First ordinary tip'), isTrue);
      await tester.pump();
      expect(find.text('First ordinary tip'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));

      expect(debugPlayerFlashForProbe('Replacement ordinary tip'), isTrue);
      await tester.pump();
      expect(debugPlayerLastTip(), 'Replacement ordinary tip');
      expect(find.text('First ordinary tip'), findsNothing);
      expect(find.text('Replacement ordinary tip'), findsOneWidget);

      // The first timer fires here but cannot clear a different current tip.
      await tester.pump(const Duration(milliseconds: 700));
      expect(debugPlayerLastTip(), 'Replacement ordinary tip');
      expect(find.text('Replacement ordinary tip'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 499));
      expect(debugPlayerLastTip(), 'Replacement ordinary tip');
      await tester.pump(const Duration(milliseconds: 1));
      expect(debugPlayerLastTip(), isNull);
      expect(find.text('Replacement ordinary tip'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
