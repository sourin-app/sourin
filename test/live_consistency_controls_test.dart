import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';
import 'package:sourin_spike/ui/media_session.dart';

void main() {
  testWidgets('embedded live exposes an actionable volume control', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 532,
          height: 356,
          child: LiveEmbeddedPlayer(stream: null, title: 'Test channel'),
        ),
      ),
    ));
    final slider = find.byKey(const ValueKey('live-volume-slider'));
    expect(slider, findsOneWidget);
    expect(tester.widget<Slider>(slider).onChanged, isNotNull);
    final state = tester.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));
    tester.widget<Slider>(slider).onChanged!(37);
    await tester.pump();
    expect(state.desiredVolume, 37);
    expect(state.muted, isFalse);
    expect(tester.widget<Slider>(slider).value, 37);
    await state.toggleMute();
    await tester.pump();
    expect(state.muted, isTrue);
    expect(state.desiredVolume, 37);
    expect(tester.widget<Slider>(slider).value, 0);
    await state.toggleMute();
    await tester.pump();
    expect(state.muted, isFalse);
    expect(tester.widget<Slider>(slider).value, 37);
    await state.setVolume(0);
    await tester.pump();
    expect(state.muted, isTrue);
    expect(state.desiredVolume, 37);
    await state.toggleMute();
    await tester.pump();
    expect(state.desiredVolume, 37);
    expect(state.muted, isFalse);
    await state.applyPlaybackSnapshot(
      LivePlaybackSnapshot(playing: false, muted: true, volume: 64),
      restorePlaying: false,
    );
    await tester.pump();
    expect(state.playbackSnapshot.muted, isTrue);
    expect(state.playbackSnapshot.volume, 64);
    expect(tester.widget<Slider>(slider).value, 0);
    await state.toggleMute();
    await tester.pump();
    expect(state.muted, isFalse);
    expect(tester.widget<Slider>(slider).value, 64);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
