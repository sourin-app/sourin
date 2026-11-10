import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/widgets/compact_shelf_card.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

const _currentCover = 'http://127.0.0.1:61234/s/current-cover-fixture';
const _oldCover = 'http://127.0.0.1:53002/s/old-cover-fixture';

Favorite _favorite(String lane, String cover) => Favorite(
  key: 'fixture:$lane',
  provider: 'fixture',
  nativeId: lane,
  title: '$lane series',
  cover: cover,
  following: lane == 'following',
);

Progress _history(String cover) => Progress(
  key: 'fixture:history:e2',
  provider: 'fixture',
  nativeId: 'history',
  title: 'history series',
  cover: cover,
  episodeId: 'e2',
  episodeTitle: 'Episode 2',
  position: 40,
  duration: 100,
);

CacheEntry _oldCache() => CacheEntry(
  at: DateTime(2026, 11, 7),
  data: {
    'favorites': [_favorite('favorites', _oldCover).toJson()],
    'following': [_favorite('following', _oldCover).toJson()],
    'history': [_history(_oldCover).toJson()],
  },
);

Future<void> _mount(WidgetTester tester, {bool compact = true}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1000, 800);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(
        body: SingleChildScrollView(child: MyShelf(compact: compact)),
      ),
    ),
  );
  await tester.pump();
  await tester.pump();
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
  });
}

Future<void> _showLane(WidgetTester tester, ShelfTab tab, int count) async {
  final label = switch (tab) {
    ShelfTab.following => '追更',
    ShelfTab.favorites => '收藏',
    ShelfTab.history => '历史',
  };
  await tester.tap(find.text('$label $count'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void _expectCover(WidgetTester tester, String cover, {bool compact = true}) {
  expect(find.byType(PosterCard), findsOneWidget);
  expect(tester.widget<PosterCard>(find.byType(PosterCard)).cover, cover);
  if (compact) {
    expect(find.byType(CompactShelfCard), findsOneWidget);
    expect(
      tester.widget<CompactShelfCard>(find.byType(CompactShelfCard)).cover,
      cover,
    );
  }
}

void main() {
  setUp(() {
    final previousTransport = SourinCore.debugCallAsyncTransport;
    final previousLoad = debugShelfLoadOverride;
    final previousPreload = debugShelfPreloadOverride;
    final previousCacheDir = DiskCache.dataDir;
    UiPrefs.debugResetForTest();
    // The delayed CacheEntry below is in memory. Persistence has no directory,
    // and ancillary core calls never bind a native library or read a profile.
    DiskCache.debugResetForTest(null);
    SourinCore.debugCallAsyncTransport = (command, _) async =>
        switch (command) {
          'list_all_progress' => <dynamic>[],
          'repair_library_covers' => 0,
          _ => throw UnsupportedError('Unexpected shelf command: $command'),
        };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = previousTransport;
      debugShelfLoadOverride = previousLoad;
      debugShelfPreloadOverride = previousPreload;
      DiskCache.debugResetForTest(previousCacheDir);
      UiPrefs.debugResetForTest();
    });
    // Retain Flutter's test HTTP client: fixture URLs are widget data only.
    // No real HTTP client, socket, or network override is installed here.
  });

  for (final compact in [false, true]) {
    testWidgets(
      'late disk preload preserves current covers in every shelf lane (compact=$compact)',
      (tester) async {
        final preload = Completer<CacheEntry?>();
        var preloadCalls = 0;
        var loadCalls = 0;
        debugShelfPreloadOverride = () {
          preloadCalls++;
          return preload.future;
        };
        debugShelfLoadOverride = () async {
          loadCalls++;
          return (
            [_favorite('favorites', _currentCover)],
            [_favorite('following', _currentCover)],
            [_history(_currentCover)],
          );
        };
        await _mount(tester, compact: compact);
        expect(preloadCalls, 1);
        expect(loadCalls, 1);
        expect(preload.isCompleted, isFalse);
        _expectCover(tester, _currentCover, compact: compact);

        // Subsequent tab selections cannot repair a stale overwrite and hide
        // the race: all later loads deliberately fail and retain current data.
        debugShelfLoadOverride = () async => (null, null, null);
        preload.complete(_oldCache());
        await tester.pump();
        await tester.pump();
        for (final tab in ShelfTab.values) {
          await _showLane(tester, tab, 1);
          _expectCover(tester, _currentCover, compact: compact);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('successful empty lists are not revived by late cached records', (
    tester,
  ) async {
    final preload = Completer<CacheEntry?>();
    debugShelfPreloadOverride = () => preload.future;
    debugShelfLoadOverride = () async =>
        (<Favorite>[], <Favorite>[], <Progress>[]);
    await _mount(tester);
    expect(find.byType(PosterCard), findsNothing);
    expect(find.text('追更 0'), findsOneWidget);

    debugShelfLoadOverride = () async => (null, null, null);
    preload.complete(_oldCache());
    await tester.pump();
    await tester.pump();
    for (final tab in ShelfTab.values) {
      await _showLane(tester, tab, 0);
      expect(find.byType(PosterCard), findsNothing);
      expect(find.byType(CompactShelfCard), findsNothing);
    }
    expect(tester.takeException(), isNull);
  });

  for (final failedLane in ShelfTab.values) {
    testWidgets(
      'late cache restores failed $failedLane while preserving successful lanes',
      (tester) async {
        final preload = Completer<CacheEntry?>();
        debugShelfPreloadOverride = () => preload.future;
        debugShelfLoadOverride = () async => (
          failedLane == ShelfTab.favorites
              ? null
              : [_favorite('favorites', _currentCover)],
          failedLane == ShelfTab.following
              ? null
              : [_favorite('following', _currentCover)],
          failedLane == ShelfTab.history ? null : [_history(_currentCover)],
        );
        await _mount(tester);
        if (failedLane == ShelfTab.following) {
          expect(find.byType(PosterCard), findsNothing);
        } else {
          _expectCover(tester, _currentCover);
        }

        debugShelfLoadOverride = () async => (null, null, null);
        preload.complete(_oldCache());
        await tester.pump();
        await tester.pump();
        for (final tab in ShelfTab.values) {
          await _showLane(tester, tab, 1);
          _expectCover(tester, tab == failedLane ? _oldCover : _currentCover);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
}
