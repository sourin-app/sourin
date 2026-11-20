@Tags(['native-media'])
library;

import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('PlayerPage mouse click seeks and updates its playhead', (
    tester,
  ) async {
    await fixture.mountPlayer(tester);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
    expect(
      debugPlayerSetDurationForProbe(const Duration(seconds: 100)),
      isTrue,
    );
    final seeks = <Duration>[];
    expect(
      debugPlayerSetUserSeekForProbe((target) async {
        seeks.add(target);
      }),
      isTrue,
    );
    debugPlayerHoverControlsForProbe();
    await tester.pump();
    expect(find.byType(PlayerProgressSlider), findsOneWidget);

    final rect = tester.getRect(find.byType(PlayerProgressSlider));
    final mouse = await tester.startGesture(
      Offset(rect.left + rect.width * .75, rect.center.dy),
      kind: PointerDeviceKind.mouse,
    );
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(seeks, hasLength(1));
    expect(seeks.single.inMilliseconds, closeTo(75000, 1000));
    expect(debugPlayerPositionSeconds(), closeTo(75, 1));
    await fixture.drain(tester);
  });
}
