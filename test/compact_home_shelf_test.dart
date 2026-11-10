import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/compact_shelf_card.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'compact shelf at $width puts the cover above the title and opens details',
      (t) async {
        UiPrefs.debugResetForTest();
        debugShelfLoadOverride = () async =>
            (<Favorite>[], <Favorite>[], <Progress>[]);
        addTearDown(() {
          debugShelfLoadOverride = null;
          UiPrefs.debugResetForTest();
        });
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(width, 800);
        addTearDown(t.view.reset);
        final selected = <String>[];
        final key = GlobalKey<MyShelfState>();
        final theme = AppTheme.themeFor(Brightness.light);
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (_, child) => AppThemeHost(data: theme, child: child!),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MyShelf(
                  key: key,
                  compact: true,
                  onOpenDetail: (p, id) => selected.add('$p:$id'),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        key.currentState!.debugSetData(
          following: const [
            Favorite(
              key: 'fixture:work',
              provider: 'fixture',
              nativeId: 'work',
              title: 'Example series',
              following: true,
              lastEpisodeTitle: '第 8 集',
            ),
          ],
          remaining: {'fixture:work': 3},
        );
        await t.pump();
        final card = find.byType(CompactShelfCard);
        final poster = find.byType(PosterCard);
        final title = find.text('Example series');
        expect(card, findsOneWidget);
        expect(t.getSize(card).width, inInclusiveRange(120, 140));
        expect(t.getSize(card).height, lessThan(280));
        expect(t.getSize(find.byType(MyShelf)).height, lessThan(340));
        expect(t.getRect(title).top, greaterThan(t.getRect(poster).bottom));
        expect(t.widget<Text>(title).maxLines, 1);
        expect(find.text('我的'), findsNothing);
        expect(find.text('更新至8集'), findsOneWidget);
        expect(find.text('第 8 集'), findsNothing);
        expect(t.widget<PosterCard>(poster).showCaption, isFalse);
        expect(t.widget<PosterCard>(poster).unread, 3);
        await t.tap(title);
        await t.pump();
        expect(selected, ['fixture:work']);

        Focus.of(t.element(title)).requestFocus();
        await t.pump();
        await t.sendKeyEvent(LogicalKeyboardKey.select);
        await t.pump();
        expect(selected, ['fixture:work', 'fixture:work']);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 5));
      },
    );
  }

  testWidgets('shelf status uses known episodes and explicit completion only', (
    t,
  ) async {
    final key = await _mountStatusShelf(t);
    const cases = <(String?, int, String?, String?)>[
      (null, 12, null, '更新至12集'),
      ('更新至第１２集', 30, null, '更新至12集'),
      ('全 24 集', 0, null, '已完结·全24集'),
      ('第24集（完结）', 24, null, '已完结·全24集'),
      ('已完结', 0, null, '已完结'),
      ('已完结,全26话', 0, null, '已完结·全26集'),
      ('已完结，全２６話', 0, null, '已完结·全26集'),
      ('全26集，完结', 0, null, '已完结·全26集'),
      ('未完结，全26话', 0, null, null),
      ('已完结,全26话特别篇', 0, null, null),
      ('未完结', 0, null, null),
      (null, 0, '已完结·全24集', null),
    ];
    for (final (latest, count, note, expected) in cases) {
      key.currentState!.debugSetData(
        following: [
          Favorite(
            key: 'fixture:work',
            provider: 'fixture',
            nativeId: 'work',
            title: 'Status series',
            lastEpisodeTitle: latest,
            lastEpisodeCount: count,
            unreadCount: 7,
            note: note,
          ),
        ],
        remaining: {'fixture:work': 3},
      );
      await t.pump();
      final card = t.widget<CompactShelfCard>(find.byType(CompactShelfCard));
      expect(card.releaseStatus, expected, reason: '$latest / $count / $note');
      expect(card.unread, 3);
      expect(find.text('更新至3集'), findsNothing);
      expect(find.text('更新至7集'), findsNothing);
      if (expected != null) expect(find.text(expected), findsOneWidget);
      expect(t.takeException(), isNull);
    }
    key.currentState!.debugSetData(
      tab: ShelfTab.favorites,
      favorites: const [
        Favorite(
          key: 'fixture:work',
          provider: 'fixture',
          nativeId: 'work',
          title: 'Favorite series',
          lastEpisodeCount: 18,
        ),
      ],
    );
    await t.pump();
    expect(find.text('更新至18集'), findsOneWidget);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets('history status matches the source and refreshes independently', (
    t,
  ) async {
    final key = await _mountStatusShelf(t);
    const history = [
      Progress(
        key: 'fixture:work:ep4',
        provider: 'fixture',
        nativeId: 'work',
        title: 'History series',
        episodeTitle: '第4集',
        position: 96,
        duration: 100,
        finished: true,
      ),
    ];
    key.currentState!.debugSetData(
      tab: ShelfTab.history,
      history: history,
      favorites: const [
        Favorite(
          key: 'other:work',
          provider: 'other',
          nativeId: 'work',
          title: 'History series',
          lastEpisodeTitle: '全24集',
        ),
      ],
    );
    await t.pump();
    var card = t.widget<CompactShelfCard>(find.byType(CompactShelfCard));
    expect(card.releaseStatus, isNull);
    expect(card.subtitle, '第4集');
    expect(card.percent, 96);
    expect(find.textContaining('已完结'), findsNothing);
    key.currentState!.debugSetData(
      favorites: const [],
      following: const [
        Favorite(
          key: 'fixture:work',
          provider: 'fixture',
          nativeId: 'work',
          title: 'History series',
          lastEpisodeCount: 12,
        ),
      ],
    );
    await t.pump();
    expect(find.text('更新至12集'), findsOneWidget);
    final previousSignature = key.currentState!.debugSignatureForTest();
    debugShelfLoadOverride = () async => (
      <Favorite>[],
      <Favorite>[
        const Favorite(
          key: 'fixture:work',
          provider: 'fixture',
          nativeId: 'work',
          title: 'History series',
          lastEpisodeTitle: '全24集',
          lastEpisodeCount: 24,
        ),
      ],
      history,
    );
    await t.runAsync(() async => key.currentState!.load());
    await t.pump();
    expect(key.currentState!.debugSignatureForTest(), isNot(previousSignature));
    card = t.widget<CompactShelfCard>(find.byType(CompactShelfCard));
    expect(card.releaseStatus, '已完结·全24集');
    expect(find.text('第4集'), findsOneWidget);
    expect(find.text('已完结·全24集'), findsOneWidget);
    expect(t.takeException(), isNull);
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 5));
  });

  testWidgets(
    'compact rail preserves its scroll position when data refreshes',
    (t) async {
      UiPrefs.debugResetForTest();
      var refreshed = false;
      final previousTransport = SourinCore.debugCallAsyncTransport;
      // load() also refreshes unread counts after the injected shelf lists.
      // Keep that ancillary query local; this test exercises the real shelf
      // refresh and ScrollPosition, not the native worker or media library.
      SourinCore.debugCallAsyncTransport = (command, _) async =>
          switch (command) {
            'list_all_progress' => <dynamic>[],
            'repair_library_covers' => 0,
            _ => throw UnsupportedError('Unexpected shelf command: $command'),
          };
      List<Favorite> items() => List.generate(
        16,
        (index) => Favorite(
          key: 'fixture:$index',
          provider: 'fixture',
          nativeId: '$index',
          title: 'Series $index${refreshed ? ' updated' : ''}',
          following: true,
        ),
      );
      debugShelfLoadOverride = () async =>
          (<Favorite>[], items(), <Progress>[]);
      addTearDown(() {
        debugShelfLoadOverride = null;
        SourinCore.debugCallAsyncTransport = previousTransport;
        UiPrefs.debugResetForTest();
      });
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(360, 800);
      addTearDown(t.view.reset);
      final key = GlobalKey<MyShelfState>();
      final theme = AppTheme.themeFor(Brightness.light);
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: Scaffold(body: MyShelf(key: key, compact: true)),
        ),
      );
      await t.pump();
      key.currentState!.debugSetData(following: items());
      await t.pump();
      final rail = find.descendant(
        of: find.descendant(
          of: find.byType(MyShelf),
          matching: find.byType(ListView),
        ),
        matching: find.byType(Scrollable),
      );
      expect(rail, findsOneWidget);
      await t.drag(rail, const Offset(-240, 0));
      await t.pumpAndSettle();
      final position = t.state<ScrollableState>(rail).position;
      final offset = position.pixels;
      expect(offset, greaterThan(100));
      refreshed = true;
      await t.runAsync(() async {
        await key.currentState!.load();
      });
      await t.pump();
      expect(t.state<ScrollableState>(rail).position, same(position));
      expect(position.pixels, closeTo(offset, .1));
      expect(find.textContaining('updated'), findsWidgets);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox.shrink());
      await t.pump(const Duration(seconds: 5));
    },
  );

  for (final scale in [.8, 1.0, 1.6]) {
    testWidgets(
      'poster, single-line title and progress fit at text scale $scale',
      (t) async {
        final theme = AppTheme.themeFor(Brightness.dark);
        var opened = 0;
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (_, child) => AppThemeHost(data: theme, child: child!),
            home: MediaQuery(
              data: MediaQueryData(
                size: t.view.physicalSize / t.view.devicePixelRatio,
                textScaler: TextScaler.linear(scale),
              ),
              child: Scaffold(
                body: Builder(
                  builder: (context) => Align(
                    alignment: Alignment.topLeft,
                    child: SizedBox(
                      width: CompactShelfCard.width,
                      height: CompactShelfCard.heightOf(context),
                      child: CompactShelfCard(
                        title: 'A long title remains on one line',
                        releaseStatus: '已完结·全240集',
                        subtitle: '第 20 集',
                        percent: 42,
                        unread: 3,
                        onTap: () => opened++,
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        final card = t.getRect(find.byType(CompactShelfCard));
        final poster = t.getRect(find.byType(PosterCard));
        final title = t.getRect(find.text('A long title remains on one line'));
        final status = find.text('已完结·全240集');
        final statusRect = t.getRect(status);
        final subtitle = t.getRect(find.text('第 20 集'));
        final progress = find.byType(miuix.MiuixLinearProgressIndicator);
        final progressRect = t.getRect(progress);
        expect(poster.width, inInclusiveRange(110, 124));
        expect(poster.height / poster.width, closeTo(1.5, .001));
        expect(poster.top - card.top, greaterThanOrEqualTo(8));
        expect(title.top, greaterThan(poster.bottom));
        expect(statusRect.top, greaterThanOrEqualTo(poster.top));
        expect(statusRect.bottom, lessThan(poster.bottom));
        expect(
          t
              .widget<Text>(find.text('A long title remains on one line'))
              .maxLines,
          1,
        );
        expect(
          find.descendant(
            of: find.byType(PosterCard),
            matching: find.byKey(const ValueKey('poster-release-status')),
          ),
          findsOneWidget,
        );
        expect(statusRect.left, greaterThanOrEqualTo(poster.left));
        expect(statusRect.right, lessThanOrEqualTo(poster.right + .01));
        expect(t.widget<Text>(status).overflow, isNot(TextOverflow.ellipsis));
        expect(subtitle.top, greaterThanOrEqualTo(title.bottom));
        expect(subtitle.bottom, lessThanOrEqualTo(card.bottom - 7.9));
        expect(progressRect.left, greaterThanOrEqualTo(poster.left));
        expect(progressRect.right, lessThanOrEqualTo(poster.right));
        expect(progressRect.bottom, closeTo(poster.bottom, .001));
        expect(
          t.widget<miuix.MiuixLinearProgressIndicator>(progress).progress,
          .42,
        );
        await t.tap(find.text('A long title remains on one line'));
        await t.pump();
        expect(opened, 1);
        expect(t.takeException(), isNull);
      },
    );
  }

  for (final brightness in Brightness.values) {
    testWidgets('compact card has a visible Miuix surface in $brightness', (
      t,
    ) async {
      final theme = AppTheme.themeFor(brightness);
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: Scaffold(
            body: Builder(
              builder: (context) => Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                  width: CompactShelfCard.width,
                  height: CompactShelfCard.heightOf(context),
                  child: CompactShelfCard(title: 'Library item', onTap: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      expect(find.byType(miuix.MiuixCard), findsOneWidget);
      final surface = t.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(CompactShelfCard),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is DecoratedBox &&
                    widget.decoration is ShapeDecoration,
              ),
            )
            .first,
      );
      final color = (surface.decoration as ShapeDecoration).color;
      expect(color, theme.colorScheme.surfaceContainer);
      expect(color, isNot(theme.scaffoldBackgroundColor));
      expect(t.takeException(), isNull);
    });
  }
}

Future<GlobalKey<MyShelfState>> _mountStatusShelf(WidgetTester t) async {
  UiPrefs.debugResetForTest();
  final previousTransport = SourinCore.debugCallAsyncTransport;
  SourinCore.debugCallAsyncTransport = (command, _) async => switch (command) {
    'list_all_progress' => <dynamic>[],
    'repair_library_covers' => 0,
    _ => throw UnsupportedError('Unexpected shelf command: $command'),
  };
  debugShelfLoadOverride = () async =>
      (<Favorite>[], <Favorite>[], <Progress>[]);
  addTearDown(() {
    debugShelfLoadOverride = null;
    SourinCore.debugCallAsyncTransport = previousTransport;
    UiPrefs.debugResetForTest();
  });
  final key = GlobalKey<MyShelfState>();
  final theme = AppTheme.themeFor(Brightness.light);
  await t.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(body: MyShelf(key: key, compact: true)),
    ),
  );
  await t.pump();
  return key;
}
