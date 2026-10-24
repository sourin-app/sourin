@Tags(['native-media'])
library;

import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('direct disposal reports snapshot exactly once without pop', (t) async {
    final events = <String>[];
    await t.pumpWidget(MaterialApp(
      home: PlayerPage(
        provider: 'fixture',
        id: 'live-dispose-only',
        title: '直播直接销毁夹具',
        liveChannelId: 'fixture-channel',
        onLivePlaybackExit: (_) => events.add('snapshot'),
        isTv: false,
        isTouchOnly: false,
      ),
    ));
    await t.pump();
    expect(find.byType(PlayerPage), findsOneWidget);
    expect(events, isEmpty);

    // Replace the entire tree, without active exit or any Navigator pop.
    await t.pumpWidget(const SizedBox.shrink());
    expect(find.byType(PlayerPage), findsNothing);
    expect(events, ['snapshot'],
        reason: 'Direct disposal must report through the fallback.');
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(seconds: 3));
    }
    expect(events, ['snapshot'],
        reason: 'Disposal and later cleanup must report exactly once.');
  });

  for (final systemBack in [false, true]) {
    testWidgets('${systemBack ? "system back" : "active exit"} reports snapshot before route future', (t) async {
      final navigator = GlobalKey<NavigatorState>();
      final events = <String>[];
      await t.pumpWidget(MaterialApp(
        navigatorKey: navigator,
        home: const SizedBox.shrink(),
      ));
      final route = navigator.currentState!.push<bool>(MaterialPageRoute<bool>(
        builder: (_) => PlayerPage(
          provider: 'fixture',
          id: 'live-exit-order',
          title: '直播返回顺序夹具',
          liveChannelId: 'fixture-channel',
          onLivePlaybackExit: (_) => events.add('snapshot'),
          isTv: false,
          isTouchOnly: false,
        ),
      ));
      route.then((_) => events.add('route-future'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 350));
      if (systemBack) {
        await t.binding.handlePopRoute();
      } else {
        expect(debugPlayerBackForProbe(), isTrue);
      }
      await t.pump();
      debugPrint('EXIT_ORDER systemBack=$systemBack events=$events '
          'canPop=${navigator.currentState!.canPop()} '
          'playerWidgets=${find.byType(PlayerPage).evaluate().length}');
      expect(events, ['snapshot', 'route-future'],
          reason: 'Snapshot must precede route completion, not wait for dispose.');
      await t.pump(const Duration(milliseconds: 350));
      for (var i = 0; i < 60; i++) {
        await t.pump(const Duration(seconds: 3));
      }
      expect(events.where((e) => e == 'snapshot'), hasLength(1),
          reason: 'dispose fallback must not report twice.');
    });
  }
}
