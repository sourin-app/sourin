import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';

Progress _history(int index) => Progress(
  key: 'fixture:series-$index:e1',
  provider: 'fixture',
  nativeId: 'series-$index',
  title: 'Series $index',
  episodeId: 'e1',
  episodeTitle: 'Episode 1',
  position: 40,
  duration: 100,
);

class _HistoryFixture {
  int total = 25;
  bool failCount = false;
  final limits = <int>[];
  final rows = List.generate(25, _history);

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    switch (command) {
      case 'continue_watching':
        final limit = args!['limit'] as int;
        limits.add(limit);
        return rows.take(limit).map((row) => row.toJson()).toList();
      case 'continue_watching_count':
        if (failCount) throw StateError('Synthetic count failure');
        return total;
      case 'list_favorites':
      case 'list_following_for_ui':
      case 'list_all_progress':
      case 'list_providers':
      case 'check_updates':
        return <dynamic>[];
      case 'total_unread':
      case 'repair_library_covers':
        return 0;
      default:
        throw UnsupportedError('Unexpected history command: $command');
    }
  }
}

Future<void> _mount(
  WidgetTester tester,
  GlobalKey<MyShelfState> shelfKey,
  GlobalKey<FollowPageState> followKey,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(
        body: Row(
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: MyShelf(key: shelfKey, compact: true),
              ),
            ),
            Expanded(child: FollowPage(key: followKey)),
          ],
        ),
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

void _expectBothCounts(WidgetTester tester, int count) {
  final tabs = tester.widgetList<ShelfTabs>(find.byType(ShelfTabs)).toList();
  expect(tabs, hasLength(2));
  expect(tabs.map((tab) => tab.counts[2]), [count, count]);
  expect(find.text('历史 $count'), findsNWidgets(2));
}

void main() {
  setUp(() {
    final previousTransport = SourinCore.debugCallAsyncTransport;
    final previousLoad = debugShelfLoadOverride;
    final previousPreload = debugShelfPreloadOverride;
    final previousCacheDir = DiskCache.dataDir;
    UiPrefs.debugResetForTest();
    DiskCache.debugResetForTest(null);
    debugShelfLoadOverride = null;
    debugShelfPreloadOverride = () async => null;
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = previousTransport;
      debugShelfLoadOverride = previousLoad;
      debugShelfPreloadOverride = previousPreload;
      DiskCache.debugResetForTest(previousCacheDir);
      UiPrefs.debugResetForTest();
    });
  });

  testWidgets('both history badges use total while previews stay bounded', (
    tester,
  ) async {
    final fixture = _HistoryFixture();
    SourinCore.debugCallAsyncTransport = fixture.call;
    final shelfKey = GlobalKey<MyShelfState>();
    final followKey = GlobalKey<FollowPageState>();
    await _mount(tester, shelfKey, followKey);
    _expectBothCounts(tester, 25);
    // FollowPage reloads after its initial update sweep; each refresh must
    // still use the bounded preview request for its own page.
    expect(fixture.limits.toSet(), {12, 20});
    expect(fixture.limits, everyElement(anyOf(12, 20)));
    expect(followKey.currentState!.debugContinueList, hasLength(20));

    // An older item changes the total without changing either preview.
    fixture.total = 26;
    await shelfKey.currentState!.load();
    await followKey.currentState!.loadAll();
    await tester.pump();
    _expectBothCounts(tester, 26);

    // A transient count failure must not shrink the badge to the preview.
    fixture.failCount = true;
    await shelfKey.currentState!.load();
    await followKey.currentState!.loadAll();
    await tester.pump();
    _expectBothCounts(tester, 26);
    expect(fixture.limits, everyElement(anyOf(12, 20)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('late disk count cannot replace a fresh core total', (
    tester,
  ) async {
    final fixture = _HistoryFixture();
    SourinCore.debugCallAsyncTransport = fixture.call;
    final preload = Completer<CacheEntry?>();
    debugShelfPreloadOverride = () => preload.future;
    await _mount(
      tester,
      GlobalKey<MyShelfState>(),
      GlobalKey<FollowPageState>(),
    );
    _expectBothCounts(tester, 25);
    preload.complete(
      CacheEntry(
        at: DateTime(2026, 11, 7),
        data: {
          'favorites': <dynamic>[],
          'following': <dynamic>[],
          'history': [_history(0).toJson()],
          'historyCount': 99,
        },
      ),
    );
    await tester.pump();
    await tester.pump();
    _expectBothCounts(tester, 25);
    expect(tester.takeException(), isNull);
  });
}
