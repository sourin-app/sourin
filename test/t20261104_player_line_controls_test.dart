import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart'
    show PlayerBottomBar, PlayerMoreMenuData;
import 'package:sourin_spike/ui/player/player_popover.dart'
    show PopoverController, PopoverOption, PlayerPopoverSurface;
import 'package:sourin_spike/ui/widgets/episode_strip.dart' show LineChip;

Future<void> _mountBar(
  WidgetTester t, {
  required Size size,
  required List<PopoverOption<String>> lines,
  List<StreamCandidate> streams = const [],
  required ValueChanged<String> onLine,
}) async {
  await t.binding.setSurfaceSize(size);
  addTearDown(() => t.binding.setSurfaceSize(null));
  final controller = PopoverController();
  final position = ValueNotifier(Duration.zero);
  addTearDown(controller.dispose);
  addTearDown(position.dispose);
  final bar = PlayerBottomBar(
    controller: controller,
    playing: false,
    positionListenable: position,
    duration: Duration.zero,
    isLive: false,
    rate: 1,
    volume: 50,
    muted: false,
    fullscreen: false,
    onTogglePlay: () {},
    onSeek: (_) {},
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
    streams: streams,
    lineOptions: lines,
    onPickLine: onLine,
  );
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(
        children: [
          bar,
          ListenableBuilder(
            listenable: controller,
            builder: (_, __) => Positioned.fill(
              bottom: 120,
              child: bar.buildPopoverLayer(),
            ),
          ),
        ],
      ),
    ),
  ));
  await t.pump();
}

void main() {
  test('episode context uses compatible optional snake-case fields', () {
    expect(const PlayRequest().toJson(), isEmpty);
    expect(
      const PlayRequest(
        episodeId: 'file-2',
        flag: 'line-b',
        episodeTitle: '第02集',
        episodeOrder: 2,
      ).toJson(),
      {
        'episode_id': 'file-2',
        'flag': 'line-b',
        'episode_title': '第02集',
        'episode_order': 2,
      },
    );
  });

  for (final size in [const Size(1280, 720), const Size(360, 800)]) {
    for (final streamCount in [0, 1]) {
      testWidgets('${size.width}: lines remain available with $streamCount streams',
          (t) async {
        final selected = <String>[];
        await _mountBar(
          t,
          size: size,
          streams: [
            for (var i = 0; i < streamCount; i++)
              const StreamCandidate(url: 'https://fixture.invalid/test.m3u8'),
          ],
          lines: const [
            PopoverOption(value: 'a', label: '线路A', checked: true),
            PopoverOption(value: 'b', label: '线路B'),
          ],
          onLine: selected.add,
        );
        expect(find.text('线路'), findsOneWidget);
        expect(find.text('清晰度'), findsNothing);
        await t.tap(find.text('线路'));
        await t.pumpAndSettle();
        expect(find.byType(PlayerPopoverSurface), findsOneWidget);
        await t.tap(find.text('线路B'));
        await t.pumpAndSettle();
        expect(selected, ['b']);
        expect(find.text('线路B'), findsNothing);
        expect(t.takeException(), isNull);
      });
    }
  }

  testWidgets('single episode line does not show a line tool', (t) async {
    await _mountBar(
      t,
      size: const Size(1280, 720),
      lines: const [PopoverOption(value: 'a', label: '唯一线路')],
      onLine: (_) => fail('A single line is not a switching action.'),
    );
    expect(find.text('线路'), findsNothing);
    expect(t.takeException(), isNull);
  });

  testWidgets('many long names stay in a bounded scrollable popover', (t) async {
    final selected = <String>[];
    await _mountBar(
      t,
      size: const Size(360, 800),
      lines: [
        for (var i = 1; i <= 31; i++)
          PopoverOption(value: '$i', label: '线路$i-长名称用于验证窄屏排版'),
      ],
      onLine: selected.add,
    );
    await t.tap(find.text('线路'));
    await t.pumpAndSettle();
    final panel = find.byType(PlayerPopoverSurface);
    final rect = t.getRect(panel);
    expect(rect.height, lessThanOrEqualTo(328));
    expect(rect.left, greaterThanOrEqualTo(0));
    expect(rect.right, lessThanOrEqualTo(360));
    final last = find.text('线路31-长名称用于验证窄屏排版');
    await t.ensureVisible(last);
    await t.pumpAndSettle();
    await t.tap(last);
    await t.pumpAndSettle();
    expect(selected, ['31']);
    expect(t.takeException(), isNull);
  });

  testWidgets('line chip can be reached and activated by keyboard', (t) async {
    var calls = 0;
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              LineChip(
                flag: '线路A',
                selected: true,
                onTap: () => fail('Right-arrow navigation must leave line A.'),
              ),
              LineChip(
                flag: '线路B',
                selected: false,
                onTap: () => calls++,
              ),
            ],
          ),
        ),
      ),
    ));
    await t.sendKeyEvent(LogicalKeyboardKey.tab);
    await t.pump();
    await t.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await t.pump();
    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull);
    expect(
      focus!.context!.findAncestorWidgetOfExactType<LineChip>(),
      isA<LineChip>().having((chip) => chip.flag, 'focused line', '线路B'),
      reason: 'The rendered chip, not a player-level shortcut, must own focus.',
    );
    await t.sendKeyEvent(LogicalKeyboardKey.enter);
    await t.pump();
    expect(calls, 1);
    expect(t.takeException(), isNull);
  });
}
