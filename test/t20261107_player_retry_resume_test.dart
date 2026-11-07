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

void main() {
  setUpAll(() {
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

  testWidgets('repeated retry preserves the latest in-memory position', (
    tester,
  ) async {
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
          provider: 'retry-fixture',
          id: 'series',
          title: 'Retry fixture',
          episodes: [_episode],
          episodeIndex: 0,
          episodeId: 'episode-1',
        ),
      ),
    );
    await tester.pump();
    expect(debugPlayerResetResumeGuardForProbe(), isTrue);

    debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 10));
    expect(await debugPlayerPrepareResumeForProbe(), isTrue);
    expect(debugPlayerPendingSeekForProbe(), const Duration(seconds: 10));

    // Do not reset the session guard: ordinary retry reuses this same State.
    debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 99));
    expect(await debugPlayerPrepareResumeForProbe(), isTrue);
    expect(
      debugPlayerPendingSeekForProbe(),
      const Duration(seconds: 99),
      reason: 'A previous resume must not block a later retry position.',
    );
    expect(tester.takeException(), isNull);
  });
}
