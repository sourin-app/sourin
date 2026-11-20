import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/widgets/detail_raw_meta.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    themeAnimationDuration: Duration.zero,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(
      body: Center(child: SizedBox(width: 400, child: child)),
    ),
  );
}

void main() {
  testWidgets(
    'thin progress track keeps a full-height target and commits once',
    (tester) async {
      final seeks = <Duration>[];
      await tester.pumpWidget(
        _host(
          PlayerProgressSlider(
            position: const Duration(seconds: 20),
            duration: const Duration(seconds: 100),
            buffered: const PlayerBufferedRange(
              start: Duration(seconds: 20),
              end: Duration(seconds: 60),
            ),
            onSeek: seeks.add,
          ),
        ),
      );
      final hit = tester.getRect(find.byType(PlayerProgressSlider));
      final track = tester.getRect(find.byType(miuix.MiuixSlider));
      final buffer = tester.getRect(find.byKey(PlayerProgressSlider.bufferKey));
      expect(hit.height, 28);
      expect(track.height, 4);
      expect(buffer.height, track.height);
      expect(buffer.center.dy, track.center.dy);
      final upperTarget = Offset(hit.left + hit.width * .75, hit.top + 2);
      expect(track.contains(upperTarget), isFalse);
      await tester.tapAt(upperTarget);
      await tester.pumpAndSettle();
      expect(seeks, hasLength(1));
      expect(seeks.single.inMilliseconds, closeTo(75000, 1000));

      final drag = await tester.startGesture(
        Offset(hit.left + hit.width * .3, hit.bottom - 2),
      );
      await drag.moveBy(const Offset(40, 0));
      await drag.moveBy(const Offset(40, 0));
      await drag.up();
      await tester.pumpAndSettle();
      expect(seeks, hasLength(2));
      expect(seeks.last.inSeconds, greaterThan(40));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('desktop mouse click on progress track commits seek', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      _host(
        PlayerProgressSlider(
          position: const Duration(seconds: 20),
          duration: const Duration(seconds: 100),
          onSeek: seeks.add,
        ),
      ),
    );
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
    expect(tester.takeException(), isNull);
  });

  testWidgets('slider click still commits when pointer-up leaves hit area', (
    tester,
  ) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      _host(
        PlayerProgressSlider(
          position: const Duration(seconds: 20),
          duration: const Duration(seconds: 100),
          onSeek: seeks.add,
        ),
      ),
    );
    final rect = tester.getRect(find.byType(PlayerProgressSlider));
    final start = Offset(rect.left + rect.width * .75, rect.center.dy);
    final mouse = await tester.startGesture(
      start,
      kind: PointerDeviceKind.mouse,
    );
    await mouse.moveTo(start.translate(0, rect.height / 2 + 1));
    await mouse.up();
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();

    expect(seeks, hasLength(1));
    expect(seeks.single.inMilliseconds, closeTo(75000, 1000));
    expect(tester.takeException(), isNull);
  });

  for (final kind in [PointerDeviceKind.mouse, PointerDeviceKind.touch]) {
    testWidgets('progress $kind click commits beneath parent double-tap', (
      tester,
    ) async {
      final seeks = <Duration>[];
      var doubleTaps = 0;
      var position = const Duration(seconds: 20);
      await tester.pumpWidget(
        _host(
          StatefulBuilder(
            builder: (context, setState) => GestureDetector(
              onDoubleTap: () => doubleTaps++,
              child: PlayerProgressSlider(
                position: position,
                duration: const Duration(seconds: 100),
                onSeek: (target) {
                  seeks.add(target);
                  setState(() => position = target);
                },
              ),
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(PlayerProgressSlider));
      final pointer = await tester.startGesture(
        Offset(rect.left + rect.width * .75, rect.center.dy),
        kind: kind,
      );
      await pointer.up();
      await tester.pump(const Duration(milliseconds: 350));

      expect(seeks, hasLength(1));
      expect(seeks.single.inMilliseconds, closeTo(75000, 1000));
      expect(doubleTaps, 0);
      expect(
        tester.widget<miuix.MiuixSlider>(find.byType(miuix.MiuixSlider)).value,
        closeTo(75000, 1000),
        reason: 'The click must commit the rendered slider value.',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('progress $kind double-tap resolves before a seek commits', (
      tester,
    ) async {
      final seeks = <Duration>[];
      var doubleTaps = 0;
      await tester.pumpWidget(
        _host(
          GestureDetector(
            onDoubleTap: () => doubleTaps++,
            child: PlayerProgressSlider(
              position: const Duration(seconds: 20),
              duration: const Duration(seconds: 100),
              onSeek: seeks.add,
            ),
          ),
        ),
      );
      final rect = tester.getRect(find.byType(PlayerProgressSlider));
      final point = Offset(rect.left + rect.width * .75, rect.center.dy);
      for (var tap = 0; tap < 2; tap++) {
        final pointer = await tester.startGesture(point, kind: kind);
        await pointer.up();
        if (tap == 0) await tester.pump(const Duration(milliseconds: 60));
      }
      await tester.pump(const Duration(milliseconds: 400));

      expect(doubleTaps, 1);
      expect(seeks, isEmpty);
      expect(
        tester.widget<miuix.MiuixSlider>(find.byType(miuix.MiuixSlider)).value,
        20000,
        reason: 'A double tap must not leave a preview-only position.',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'inline search binds the exact candidate and rejects stale results',
    (tester) async {
      const match = DanmakuMatch(
        episodeId: 708,
        animeTitle: '测试作品',
        episodeTitle: '第 8 集',
      );
      final picked = <DanmakuMatch>[];
      Widget results({bool stale = false, bool loading = false}) =>
          DanmakuQuickSearchResults(
            results: const [match],
            loading: loading,
            searched: true,
            stale: stale,
            failed: false,
            onPickMatch: picked.add,
          );
      await tester.pumpWidget(_host(results()));
      expect(find.byType(miuix.MiuixButton), findsOneWidget);
      await tester.tap(find.text(match.displayName));
      await tester.pumpAndSettle();
      expect(picked, [same(match)]);
      await tester.pumpWidget(_host(results(stale: true)));
      expect(find.text('播放内容已变化，请重新搜索'), findsOneWidget);
      expect(find.text(match.displayName), findsNothing);
      await tester.pumpWidget(_host(results(loading: true)));
      expect(find.byType(miuix.MiuixLinearProgressIndicator), findsOneWidget);
      expect(find.text(match.displayName), findsNothing);
      expect(picked, hasLength(1));
      await tester.pumpWidget(const SizedBox.shrink());
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'detail source choices use Miuix and preserve selected identity',
    (tester) async {
      const sources = [
        PlaySource(code: 'a', title: '线路 A', count: 7),
        PlaySource(code: 'b', title: '线路 B', count: 9),
      ];
      final picked = <PlaySource>[];
      await tester.pumpWidget(
        _host(
          DetailSourcePicker(sources: sources, active: 'b', onPick: picked.add),
        ),
      );
      expect(find.byType(miuix.MiuixButton), findsNWidgets(2));
      expect(find.byType(miuix.MiuixBadge), findsNWidgets(2));
      final choices = tester.widgetList<ui.ChoiceChip>(
        find.byType(ui.ChoiceChip),
      );
      expect(choices.map((choice) => choice.selected), [false, true]);
      await tester.tap(find.text('线路 A'));
      await tester.pumpAndSettle();
      expect(picked, [same(sources.first)]);
      expect(tester.takeException(), isNull);
    },
  );
}
