@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinApi.debugResolveStreamFetcher = (_, __, {PlayRequest? req}) async =>
        [];
    SourinCore.debugCallAsyncTransport = (cmd, args) async {
      if (cmd == 'pan_cleanup_temp') return <String, dynamic>{};
      throw SourinCoreException('isolated test has no remote data', 'other');
    };
  });
  tearDown(() {
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = null;
  });

  testWidgets(
    'buffer updates repaint the progress interval without rebuilding the player or action bar',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 720));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      addTearDown(() async {
        await tester.pumpWidget(const SizedBox());
        for (var i = 0; i < 60; i++) {
          await tester.pump(const Duration(seconds: 3));
        }
      });
      await tester.pumpWidget(
        const MaterialApp(
          home: PlayerPage(
            provider: 'buffer-fixture',
            id: 'video',
            title: '缓冲测试',
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(debugPlayerForceBarsForShot(), isTrue);
      debugPlayerPushDurationForProbe(const Duration(seconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      final element = tester.element(find.byType(PlayerPage));
      final dynamic state = tester.state(find.byType(PlayerPage));
      final bar = tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar));
      final sliderElement = tester.element(find.byType(PlayerProgressSlider));

      state.debugPlayerPushBufferForProbe(
        const Duration(seconds: 60),
        start: const Duration(seconds: 20),
      );
      expect(
        element.dirty,
        isFalse,
        reason: 'A cache tick must not dirty the entire player',
      );
      await tester.pump();
      expect(
        tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar)),
        same(bar),
      );
      expect(
        tester.element(find.byType(PlayerProgressSlider)),
        same(sliderElement),
      );
      final slider = tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      expect(slider.buffered!.start, const Duration(seconds: 20));
      expect(slider.buffered!.end, const Duration(seconds: 60));
      final first = tester.getRect(find.byKey(slider.barKey!));
      expect(first.width, greaterThan(0));
      state.debugPlayerPushBufferForProbe(
        const Duration(seconds: 60),
        start: const Duration(seconds: 30),
      );
      expect(element.dirty, isFalse);
      await tester.pump();
      final changed = tester.getRect(find.byKey(slider.barKey!));
      expect(changed.left, greaterThan(first.left));
      expect(changed.right, closeTo(first.right, .01));
      expect(
        tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar)),
        same(bar),
      );
      final unchanged = tester.widget<PlayerProgressSlider>(
        find.byType(PlayerProgressSlider),
      );
      state.debugPlayerPushBufferForProbe(
        const Duration(seconds: 60),
        start: const Duration(seconds: 30),
      );
      await tester.pump();
      expect(
        tester.widget<PlayerProgressSlider>(find.byType(PlayerProgressSlider)),
        same(unchanged),
      );
      state.debugPlayerPushBufferForProbe(null);
      await tester.pump();
      expect(find.byKey(slider.barKey!), findsNothing);
      expect(
        tester.widget<PlayerBottomBar>(find.byType(PlayerBottomBar)),
        same(bar),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
