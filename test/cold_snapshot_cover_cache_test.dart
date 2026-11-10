import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

import 'support/snapshot_cover_fixture.dart';

const _homeFile = 'home-cache-tvbox_agg.json';
final _at = DateTime(2026, 11, 1, 12, 34, 56);

HomeSnapshot _home(String? cover, {String title = 'cached home title'}) => HomeSnapshot(
  fingerprint: 'fixture-fingerprint',
  at: _at,
  groups: [
    ProviderGroup(provider: 'tvbox_agg', providerName: '聚合来源', sections: [
      Section(
        id: 'static', title: '静态目录',
        source: const SectionSource(type: 'static'),
        items: [MediaItem(
          id: 'tvbox_agg:child::static-native', title: title, cover: cover,
          note: '全24集', badges: const ['7.1'], year: '2026', category: 'series',
        )],
      ),
    ]),
  ],
  items: {
    'tvbox_agg::category': [MediaItem(
      id: 'tvbox_agg:child::list-native', title: title, cover: cover,
      note: '更新至3集', badges: const ['8.2'], year: '2025', category: 'animation',
    )],
  },
);

Favorite _favorite(String lane, String? cover, {String? title}) => Favorite(
  key: 'fixture:$lane', provider: 'fixture', nativeId: lane,
  title: title ?? '$lane title', cover: cover, favorited: lane == 'favorites',
  following: lane == 'following', groupName: '分组', kind: 'series',
  lastEpisodeCount: 12, lastEpisodeTitle: '第12集', unreadCount: 3,
  note: '用户备注', createdAt: 100, updatedAt: 200, lastCheckedAt: 300,
);

Progress _history(String? cover, {String? title}) => Progress(
  key: 'fixture:history:e4', provider: 'fixture', nativeId: 'history',
  title: title ?? 'history title', cover: cover, episodeId: 'e4',
  episodeTitle: 'Episode 4', position: 40, duration: 100, updatedAt: 456,
);

Map<String, Object?> _shelf(String? cover, {String? title}) => {
  'favorites': [_favorite('favorites', cover, title: title).toJson()],
  'following': [_favorite('following', cover, title: title).toJson()],
  'history': [_history(cover, title: title).toJson()],
  'historyCount': 1,
};

List<Object?> _homeCovers(HomeSnapshot snapshot) => [
  snapshot.groups.single.sections.single.items.single.cover,
  snapshot.items.values.single.single.cover,
];

Future<Map> _diskData(String name) async {
  final entry = await DiskCache.read(name);
  expect(entry, isNotNull);
  return entry!.data as Map;
}

Future<void> _drainShelf(WidgetTester tester) async {
  for (var frame = 0; frame < 12; frame++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
    await tester.pump();
  }
}

Future<GlobalKey<MyShelfState>> _mountShelf(WidgetTester tester) async {
  final key = GlobalKey<MyShelfState>();
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: SingleChildScrollView(child: MyShelf(key: key, compact: true))),
  ));
  await _drainShelf(tester);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
  return key;
}

void main() {
  late Directory scratch;
  late SnapshotCoverTransport transport;
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cold-snapshot-covers-');
    DiskCache.debugResetForTest(scratch.path);
    UiPrefs.debugResetForTest(<String, String>{});
    transport = SnapshotCoverTransport();
    SourinCore.debugCallAsyncTransport = transport.call;
    debugShelfLoadOverride = () async => (null, null, null);
    debugShelfPreloadOverride = null;
  });
  tearDown(() async {
    SourinCore.debugCallAsyncTransport = null;
    debugShelfLoadOverride = null;
    debugShelfPreloadOverride = null;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    await scratch.delete(recursive: true);
  });

  test('home disk snapshot makes both inline and fetched items durable without changing metadata', () async {
    final original = _home(snapshotOldCover);
    final cache = HomeListCache();
    cache.put('tvbox_agg', original);
    await snapshotEventually(() async => (await DiskCache.read(_homeFile)) != null);
    final data = await _diskData(_homeFile);
    final persisted = HomeSnapshot.fromJson(Map<String, dynamic>.from(data))!;
    expect(_homeCovers(persisted), [snapshotRawCover, snapshotRawCover]);
    expect(snapshotWithoutCovers(data), snapshotWithoutCovers(original.toJson()));
    expect((await DiskCache.read(_homeFile))!.at, original.at);
    expect(_homeCovers(cache.take('tvbox_agg', fingerprint: '', now: _at)!),
        [snapshotOldCover, snapshotOldCover], reason: 'Persistence must not rewrite live display objects.');
    expect(transport.calls.where((call) => call.command == 'covers_to_durable'), isNotEmpty);
    final sent = transport.calls.expand((call) => call.items).toList();
    expect(sent.map((item) => item['provider']).toSet(), {'tvbox_agg'});
    expect(sent.map((item) => item['id']).toSet(), {'child::static-native', 'child::list-native'});
  });

  test('home cold preload registers a fresh display wrapper in both stored item locations', () async {
    final source = _home(snapshotRawCover);
    expect(await DiskCache.write(_homeFile, source.toJson(), at: _at), isTrue);
    final cache = HomeListCache();
    expect(await cache.preload(), 1);
    final restored = cache.take('tvbox_agg', fingerprint: '', now: _at)!;
    expect(_homeCovers(restored), [snapshotNewCover, snapshotNewCover]);
    expect(snapshotWithoutCovers(restored.toJson()), snapshotWithoutCovers(source.toJson()));
    expect(await _diskData(_homeFile), source.toJson(), reason: 'Preload is read-only, not a freshness-renewing write.');
  });

  test('inline raw cover headers survive real home snapshot persistence unchanged', () async {
    final source = _home(snapshotRawCover);
    HomeListCache().put('tvbox_agg', source);
    await snapshotEventually(() async => (await DiskCache.read(_homeFile)) != null);
    final actual = await _diskData(_homeFile);
    expect(actual, source.toJson());
    expect(_homeCovers(HomeSnapshot.fromJson(Map<String, dynamic>.from(actual))!),
        [snapshotRawCover, snapshotRawCover]);
  });

  test('unknown old home wrappers become null without dropping cards or inline metadata', () async {
    final source = _home(snapshotUnknownCover);
    expect(await DiskCache.write(_homeFile, source.toJson(), at: _at), isTrue);
    final cache = HomeListCache();
    expect(await cache.preload(), 1);
    final restored = cache.take('tvbox_agg', fingerprint: '', now: _at)!;
    expect(restored.cardCount, 1);
    expect(restored.groups.single.sections.single.items, hasLength(1));
    expect(_homeCovers(restored), [null, null]);
    expect(snapshotWithoutCovers(restored.toJson()), snapshotWithoutCovers(source.toJson()));
  });

  test('large home snapshots split cover batches and preserve every item', () async {
    final original = _home(snapshotOldCover);
    final source = HomeSnapshot(
      fingerprint: original.fingerprint, groups: original.groups, at: original.at,
      items: {
        'tvbox_agg::large': [
          for (var index = 0; index < 5000; index++)
            MediaItem(id: 'tvbox_agg:child::item-$index', title: 'item-$index', cover: snapshotOldCover),
        ],
      },
    );
    HomeListCache().put('tvbox_agg', source);
    await snapshotEventually(() async => (await DiskCache.read(_homeFile)) != null);
    final data = await _diskData(_homeFile);
    final persisted = HomeSnapshot.fromJson(Map<String, dynamic>.from(data))!;
    expect(persisted.items.values.single, hasLength(5000));
    expect(persisted.groups.single.sections.single.items.single.cover, snapshotRawCover);
    expect(persisted.items.values.single.map((item) => item.cover).toSet(), {snapshotRawCover});
    expect(snapshotWithoutCovers(data), snapshotWithoutCovers(source.toJson()));
    final calls = transport.calls.where((call) => call.command == 'covers_to_durable').toList();
    expect(calls.length, greaterThanOrEqualTo(2));
    expect(calls.every((call) => call.items.length <= 4096), isTrue);
    expect(calls.fold<int>(0, (count, call) => count + call.items.length), 5001);
  });

  test('failed cover conversion cannot persist temporary wrappers again', () async {
    transport.rejectConversions = true;
    final source = _home(snapshotOldCover);
    HomeListCache().put('tvbox_agg', source);
    await snapshotEventually(() async => (await DiskCache.read(_homeFile)) != null);
    final persisted = HomeSnapshot.fromJson(Map<String, dynamic>.from(await _diskData(_homeFile)))!;
    expect(_homeCovers(persisted), [null, null]);
    expect(snapshotWithoutCovers(persisted.toJson()), snapshotWithoutCovers(source.toJson()));
  });

  test('failed display conversion keeps cached cards without direct remote images', () async {
    transport.rejectConversions = true;
    final source = _home(snapshotRawCover);
    expect(await DiskCache.write(_homeFile, source.toJson(), at: _at), isTrue);
    final cache = HomeListCache();
    expect(await cache.preload(), 1);
    final restored = cache.take('tvbox_agg', fingerprint: '', now: _at)!;
    expect(_homeCovers(restored), [null, null]);
    expect(snapshotWithoutCovers(restored.toJson()), snapshotWithoutCovers(source.toJson()));
  });

  for (final malformed in ['foreign identity', 'missing result']) {
    test('display conversion rejects a batch with $malformed instead of pasting another cover', () async {
      transport.foreignIdentity = malformed == 'foreign identity';
      transport.truncateResponse = malformed == 'missing result';
      final source = _home(snapshotRawCover);
      expect(await DiskCache.write(_homeFile, source.toJson(), at: _at), isTrue);
      final cache = HomeListCache();
      expect(await cache.preload(), 1);
      final restored = cache.take('tvbox_agg', fingerprint: '', now: _at)!;
      expect(_homeCovers(restored), [null, null]);
      expect(snapshotWithoutCovers(restored.toJson()), snapshotWithoutCovers(source.toJson()));
    });
  }

  test('data images remain intact when native conversion is unavailable', () async {
    transport.rejectConversions = true;
    const dataImage = 'data:' 'image/svg+xml;base64,PHN2Zy8+';
    final source = _home(dataImage);
    expect(await DiskCache.write(_homeFile, source.toJson(), at: _at), isTrue);
    final cache = HomeListCache();
    expect(await cache.preload(), 1);
    expect(_homeCovers(cache.take('tvbox_agg', fingerprint: '', now: _at)!), [dataImage, dataImage]);
  });

  test('late real home disk read cannot replace a newer memory put', () async {
    final source = _home(snapshotRawCover, title: 'older home title');
    expect(await DiskCache.write(_homeFile, source.toJson(), at: _at), isTrue);
    final gate = SnapshotDiskGate('${scratch.path}${Platform.pathSeparator}$_homeFile', holdRead: true);
    addTearDown(gate.unblock);
    final cache = HomeListCache();
    await snapshotGatedIO(gate, () async {
      final preload = cache.preload();
      await gate.entered.future.timeout(const Duration(seconds: 5));
      cache.put('tvbox_agg', _home(snapshotNewCover, title: 'newer home title'));
      gate.unblock();
      await preload;
      await snapshotEventually(() async {
        final data = await _diskData(_homeFile);
        return HomeSnapshot.fromJson(Map<String, dynamic>.from(data))!
            .items.values.single.single.title == 'newer home title';
      });
      final current = cache.take('tvbox_agg', fingerprint: '', now: _at)!;
      expect(current.items.values.single.single.title, 'newer home title');
      expect(_homeCovers(current), [snapshotNewCover, snapshotNewCover]);
    });
    await snapshotEventually(() async => (await _diskData(_homeFile))['items'] != null);
  });

  test('older home persistence cannot publish after a newer put', () async {
    final gate = SnapshotDiskGate('${scratch.path}${Platform.pathSeparator}$_homeFile', oldWriteMarker: 'older home title');
    addTearDown(gate.unblock);
    final cache = HomeListCache();
    await snapshotGatedIO(gate, () async {
      cache.put('tvbox_agg', _home(null, title: 'older home title'));
      await gate.entered.future.timeout(const Duration(seconds: 5));
      cache.put('tvbox_agg', _home(null, title: 'newer home title'));
      // A serialized writer may hold the second publication until the first
      // completes. The old writer reaches this actual rename boundary first.
      await Future.any([gate.newerPublished.future, Future<void>.delayed(const Duration(milliseconds: 500))]);
      gate.unblock();
      await gate.olderPublished.future.timeout(const Duration(seconds: 5));
      await gate.newerPublished.future.timeout(const Duration(seconds: 5));
      final persisted = HomeSnapshot.fromJson(Map<String, dynamic>.from(await _diskData(_homeFile)))!;
      expect(persisted.items.values.single.single.title, 'newer home title');
    });
  });

  testWidgets('all three shelf lists persist durable covers and preserve complete record metadata', (tester) async {
    final key = await _mountShelf(tester);
    final source = _shelf(snapshotOldCover);
    debugShelfLoadOverride = () async => (
      [_favorite('favorites', snapshotOldCover)],
      [_favorite('following', snapshotOldCover)],
      [_history(snapshotOldCover)],
    );
    await tester.runAsync(() => key.currentState!.load());
    await tester.pump();
    await tester.runAsync(() => snapshotEventually(() async => (await DiskCache.read(kShelfCacheFile)) != null));
    final persisted = (await tester.runAsync(() => _diskData(kShelfCacheFile)))!;
    for (final lane in ['favorites', 'following', 'history']) {
      expect((persisted[lane] as List).single['cover'], snapshotRawCover, reason: lane);
    }
    expect(snapshotWithoutCovers(persisted), snapshotWithoutCovers(source));
    expect(tester.widget<PosterCard>(find.byType(PosterCard)).cover, snapshotOldCover);
    await tester.pumpWidget(const SizedBox.shrink());
    await _drainShelf(tester);
  });

  testWidgets('real shelf disk preload refreshes wrappers across favorites following and history', (tester) async {
    final source = _shelf(snapshotRawCover);
    expect(await tester.runAsync(() => DiskCache.write(kShelfCacheFile, source, at: _at)), isTrue);
    await _mountShelf(tester);
    for (final label in ['追更 1', '收藏 1', '历史 1']) {
      await tester.tap(find.text(label));
      await _drainShelf(tester);
      expect(find.byType(PosterCard), findsOneWidget);
      expect(tester.widget<PosterCard>(find.byType(PosterCard)).cover, snapshotNewCover, reason: label);
    }
    expect(await tester.runAsync(() => _diskData(kShelfCacheFile)), source);
    await tester.pumpWidget(const SizedBox.shrink());
    await _drainShelf(tester);
  });

  testWidgets('unknown old shelf wrappers keep every lane card with a null cover', (tester) async {
    expect(await tester.runAsync(() => DiskCache.write(kShelfCacheFile, _shelf(snapshotUnknownCover), at: _at)), isTrue);
    await _mountShelf(tester);
    for (final label in ['追更 1', '收藏 1', '历史 1']) {
      await tester.tap(find.text(label));
      await _drainShelf(tester);
      expect(find.byType(PosterCard), findsOneWidget);
      expect(tester.widget<PosterCard>(find.byType(PosterCard)).cover, isNull, reason: label);
    }
    await tester.pumpWidget(const SizedBox.shrink());
    await _drainShelf(tester);
  });

  testWidgets('late real shelf preload cannot overwrite current live metadata', (tester) async {
    expect(await tester.runAsync(() => DiskCache.write(kShelfCacheFile,
        _shelf(snapshotRawCover, title: 'older shelf title'), at: _at)), isTrue);
    final gate = SnapshotDiskGate(
      '${scratch.path}${Platform.pathSeparator}$kShelfCacheFile', holdRead: true,
    );
    addTearDown(gate.unblock);
    await snapshotGatedIO(gate, () async {
      final key = await _mountShelf(tester);
      await tester.runAsync(() => gate.entered.future.timeout(const Duration(seconds: 5)));
      debugShelfLoadOverride = () async => (
        [_favorite('favorites', snapshotNewCover, title: 'newer shelf title')],
        [_favorite('following', snapshotNewCover, title: 'newer shelf title')],
        [_history(snapshotNewCover, title: 'newer shelf title')],
      );
      await tester.runAsync(() => key.currentState!.load());
      await tester.pump();
      gate.unblock();
      await _drainShelf(tester);
      for (final label in ['追更 1', '收藏 1', '历史 1']) {
        await tester.tap(find.text(label));
        await _drainShelf(tester);
        expect(find.text('newer shelf title'), findsOneWidget);
        expect(find.text('older shelf title'), findsNothing);
        expect(tester.widget<PosterCard>(find.byType(PosterCard)).cover, snapshotNewCover);
      }
      await tester.runAsync(() => snapshotEventually(() async =>
          ((await _diskData(kShelfCacheFile))['following'] as List).single['title'] == 'newer shelf title'));
    });
  });

  testWidgets('older shelf persistence cannot publish after a newer live load', (tester) async {
    final key = await _mountShelf(tester);
    // Its completion signals are awaited during real file I/O. Allocate them
    // in that same real zone, rather than queuing them on the fake pump clock.
    final gate = (await tester.runAsync(() async => SnapshotDiskGate(
      '${scratch.path}${Platform.pathSeparator}$kShelfCacheFile',
      oldWriteMarker: 'older shelf title',
    )))!;
    addTearDown(gate.unblock);
    await snapshotGatedIO(gate, () async {
      debugShelfLoadOverride = () async => (
        [_favorite('favorites', null, title: 'older shelf title')],
        [_favorite('following', null, title: 'older shelf title')],
        [_history(null, title: 'older shelf title')],
      );
      await tester.runAsync(() => key.currentState!.load());
      await tester.runAsync(() => gate.entered.future.timeout(const Duration(seconds: 5)));
      debugShelfLoadOverride = () async => (
        [_favorite('favorites', null, title: 'newer shelf title')],
        [_favorite('following', null, title: 'newer shelf title')],
        [_history(null, title: 'newer shelf title')],
      );
      await tester.runAsync(() => key.currentState!.load());
      await tester.runAsync(() => Future.any([
        gate.newerPublished.future,
        Future<void>.delayed(const Duration(milliseconds: 500)),
      ]));
      gate.unblock();
      await tester.runAsync(() => Future.wait([
        gate.olderPublished.future, gate.newerPublished.future,
      ]).timeout(const Duration(seconds: 5)));
      final persisted = (await tester.runAsync(() => _diskData(kShelfCacheFile)))!;
      for (final lane in ['favorites', 'following', 'history']) {
        expect((persisted[lane] as List).single['title'], 'newer shelf title', reason: lane);
      }
    });
  });

  test('startup cover rehydration follows successful core startup and precedes runApp', () {
    final source = File('lib/shell.dart').readAsStringSync();
    final core = RegExp(r'^\s*final r = await SourinCore\.startAsync\(dir\);', multiLine: true)
        .allMatches(source).first.start;
    final preload = RegExp(r'^\s*final preloaded = await homeListCache\.preload\(\);', multiLine: true)
        .allMatches(source).single.start;
    final firstFrame = RegExp(r'^\s*runApp\(app\);', multiLine: true)
        .allMatches(source).single.start;
    expect(preload, greaterThan(core), reason: 'Real cover registration cannot call FFI before startAsync succeeds.');
    expect(preload, lessThan(firstFrame), reason: 'Cold snapshot preload must still precede the first Home build.');
  });
}
