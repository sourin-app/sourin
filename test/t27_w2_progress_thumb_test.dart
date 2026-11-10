import 'dart:ui' as raster;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart' hide PlayerPopoverIds;

class _Spy {
  final List<Duration> seeks = <Duration>[];
  void onSeek(Duration d) => seeks.add(d);
}

const Duration _kTotal = Duration(minutes: 24);

PopoverController _newController() => PopoverController();

PlayerBottomBar _bar(_Spy spy, ValueNotifier<Duration> position,
        {bool isLive = false}) =>
    PlayerBottomBar(
      controller: _newController(),
      playing: true,
      positionListenable: position,
      duration: _kTotal,
      isLive: isLive,
      rate: 1.0,
      volume: 60,
      muted: false,
      fullscreen: false,
      onTogglePlay: () {},
      onSeek: spy.onSeek,
      onVolume: (_) {},
      onToggleMute: () {},
      onRate: (_) {},
      onToggleFullscreen: () {},
      onEpisodes: () {},
      hasEpisodes: false,
      showEpisodeNav: false,
      onNext: () {},
      hasNext: false,
      more: const PlayerMoreMenuData(groups: []),
      streams: const <StreamCandidate>[],
      qualityOptions: const <PopoverOption<String>>[],
      onPickQuality: null,
      trackGroups: const <String, List<PopoverOption<String>>>{},
      onPickTrack: null,
    );

/// 使用产品的 AppThemeHost，让实际 Miuix 输入与播放器主题一致。
Future<void> _pump(
  WidgetTester tester,
  _Spy spy,
  ValueNotifier<Duration> position, {
  bool isLive = false,
}) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1400, 900);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(mui.Brightness.dark);
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: child ?? const SizedBox(),
      ),
      home: mui.Scaffold(
        body: mui.Material(
          type: mui.MaterialType.transparency,
          child: Stack(children: [_bar(spy, position, isLive: isLive)]),
        ),
      ),
    ),
  );
  expect(tester.takeException(), isNull);
}

Finder _actualSlider() => find.descendant(
  of: find.byType(PlayerProgressSlider),
  matching: find.byType(miuix.MiuixSlider),
);

/// Read the actual framework painter, including its animated thumb position.
Future<double> _whiteThumbCenter(WidgetTester tester) async {
  final slider = _actualSlider();
  final paintFinder = find.descendant(of: slider, matching: find.byType(CustomPaint));
  expect(paintFinder, findsOneWidget);
  final paint = tester.widget<CustomPaint>(paintFinder);
  final size = tester.getSize(paintFinder);
  expect(size.width, greaterThan(0), reason: 'The actual Miuix painter must fill the progress track.');
  expect(size.height, PlayerProgressSlider.trackHeight);
  final center = await tester.runAsync(() async {
    final recorder = raster.PictureRecorder();
    // The intentional 4px track has a roughly 3px thumb. Sample its actual
    // painter at 4x to avoid rounding its white disk to only 3-4 opaque pixels.
    // All geometry below remains in logical pixels.
    const scale = 4.0;
    final canvas = raster.Canvas(recorder)..scale(scale);
    paint.painter!.paint(canvas, size);
    final picture = recorder.endRecording();
    final image = await picture.toImage((size.width * scale).ceil(), (size.height * scale).ceil());
    final pixels = (await image.toByteData(format: raster.ImageByteFormat.rawRgba))!;
    var count = 0;
    var sum = 0.0;
    for (var y = 0; y < image.height; y++) {
      for (var x = 0; x < image.width; x++) {
        final i = (y * image.width + x) * 4;
        if (pixels.getUint8(i) > 230 && pixels.getUint8(i + 1) > 230 &&
            pixels.getUint8(i + 2) > 230 && pixels.getUint8(i + 3) > 230) {
          count++;
          sum += x + .5;
        }
      }
    }
    image.dispose();
    picture.dispose();
    expect(count, greaterThan(30), reason: 'Actual Miuix thumb must paint visible opaque white pixels.');
    return sum / count / scale;
  });
  return center!;
}

void main() {
  testWidgets('buffer paints its actual bounded interval on the Miuix track', (tester) async {
    await tester.pumpWidget(const Directionality(
      textDirection: TextDirection.ltr,
      child: Center(child: SizedBox(width: 400, child: _BufferedFixture())),
    ));
    final slider = tester.getRect(find.byType(PlayerProgressSlider));
    final buffer = tester.getRect(find.byKey(PlayerProgressSlider.bufferKey));
    const radius = PlayerProgressSlider.trackHeight / 2;
    final width = slider.width - PlayerProgressSlider.trackHeight;
    expect(buffer.left - slider.left, closeTo(radius + width * .2, .5));
    expect(buffer.width, closeTo(width * .4, .5));
    expect(buffer.right, lessThanOrEqualTo(slider.right));
  });

  testWidgets('Miuix paints a complete white thumb at both endpoints', (tester) async {
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await _pump(tester, _Spy(), position);
    expect(_actualSlider(), findsOneWidget);
    for (final fraction in [0.0, 0.25, 1.0]) {
      position.value = Duration(milliseconds: (_kTotal.inMilliseconds * fraction).round());
      await tester.pumpAndSettle();
      final size = tester.getSize(_actualSlider());
      final x = await _whiteThumbCenter(tester);
      final radius = PlayerProgressSlider.trackHeight / 2;
      expect(x, closeTo(radius + fraction * (size.width - 2 * radius), 1.5));
      expect(x, greaterThanOrEqualTo(radius - 1.5));
      expect(x, lessThanOrEqualTo(size.width - radius + 1.5));
    }
  });

  testWidgets('drag commits once and position notifier moves the painted thumb', (tester) async {
    final position = ValueNotifier<Duration>(const Duration(minutes: 6));
    addTearDown(position.dispose);
    final spy = _Spy();
    await _pump(tester, spy, position);
    await tester.pumpAndSettle();
    final before = await _whiteThumbCenter(tester);
    await tester.drag(_actualSlider(), const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(spy.seeks, hasLength(1));
    expect(spy.seeks.single, greaterThan(position.value));
    position.value = spy.seeks.single;
    await tester.pumpAndSettle();
    expect(await _whiteThumbCenter(tester), greaterThan(before));
  });

  testWidgets('live playback does not mount a seek control', (tester) async {
    final position = ValueNotifier<Duration>(Duration.zero);
    addTearDown(position.dispose);
    await _pump(tester, _Spy(), position, isLive: true);
    expect(find.byType(PlayerProgressSlider), findsNothing);
  });

  testWidgets('cancelled drag restores painted thumb and accepts later positions', (tester) async {
    final position = ValueNotifier<Duration>(const Duration(minutes: 6));
    addTearDown(position.dispose);
    final spy = _Spy();
    await _pump(tester, spy, position);
    await tester.pumpAndSettle();
    final before = await _whiteThumbCenter(tester);
    final gesture = await tester.startGesture(tester.getCenter(_actualSlider()));
    await gesture.moveBy(const Offset(120, 0));
    await tester.pumpAndSettle();
    expect(await _whiteThumbCenter(tester), greaterThan(before));
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(spy.seeks, isEmpty);
    expect(await _whiteThumbCenter(tester), closeTo(before, 1.5));
    position.value = const Duration(minutes: 18);
    await tester.pumpAndSettle();
    expect(await _whiteThumbCenter(tester), greaterThan(before));
  });
}

class _BufferedFixture extends StatelessWidget {
  const _BufferedFixture();
  @override
  Widget build(BuildContext context) => PlayerProgressSlider(
    position: const Duration(minutes: 1),
    duration: const Duration(minutes: 10),
    buffered: const PlayerBufferedRange(
      start: Duration(minutes: 2), end: Duration(minutes: 6),
    ),
    onSeek: (_) {},
  );
}
