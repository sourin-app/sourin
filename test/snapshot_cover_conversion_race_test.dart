import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/snapshot_cover_codec.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

import 'support/snapshot_cover_fixture.dart';

final _at = DateTime(2026, 11, 1);
const _homeFile = 'home-cache-fixture.json';

HomeSnapshot _home(String title, String cover) => HomeSnapshot(
  fingerprint: 'fixture',
  at: _at,
  groups: [
    ProviderGroup(provider: 'fixture', providerName: 'Fixture', sections: [
      Section(
        id: 'static',
        title: 'Static',
        source: const SectionSource(type: 'static'),
        items: [MediaItem(id: 'fixture:media', title: title, cover: cover)],
      ),
    ]),
  ],
  items: const {},
);

Favorite _favorite(String title, String cover) => Favorite(
  key: 'fixture:media',
  provider: 'fixture',
  nativeId: 'media',
  title: title,
  cover: cover,
  following: true,
);

void main() {
  late Directory scratch;
  late SnapshotCoverTransport transport;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('cover-conversion-race-');
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

  for (final clear in [true, false]) {
    test('home ${clear ? 'clear' : 'put'} wins while native display registration is pending', () async {
      final source = _home('cached title', snapshotRawCover);
      expect(await DiskCache.write(_homeFile, source.toJson(), at: _at), isTrue);
      final entered = Completer<void>();
      final release = Completer<void>();
      addTearDown(() {
        if (!release.isCompleted) release.complete();
      });
      SourinCore.debugCallAsyncTransport = (command, args) async {
        if (command == 'covers_to_display') {
          entered.complete();
          await release.future;
        }
        return transport.call(command, args);
      };
      final cache = HomeListCache();
      final preload = cache.preload();
      final live = _home('live title', snapshotNewCover);
      try {
        await entered.future.timeout(const Duration(seconds: 5));
        if (clear) {
          cache.clear();
        } else {
          cache.put('fixture', live);
        }
      } finally {
        release.complete();
      }
      expect(await preload, 0);
      if (clear) {
        expect(cache.length, 0);
        expect((await DiskCache.read(_homeFile))!.data, source.toJson());
      } else {
        expect(identical(cache.take('fixture', fingerprint: '', now: _at), live), isTrue);
        await snapshotEventually(() async {
          final entry = await DiskCache.read(_homeFile);
          final data = Map<String, dynamic>.from(entry!.data as Map);
          return HomeSnapshot.fromJson(data)!.groups.single.sections.single
              .items.single.title == 'live title';
        });
      }
    });
  }

  test('an invalid cover type rejects only its batch and never merges response metadata', () async {
    final snapshot = <String, dynamic>{
      'favorites': [
        for (var index = 0; index < 4097; index++)
          <String, dynamic>{
            'provider': 'fixture',
            'native_id': 'media-$index',
            'title': 'original-$index',
            'cover': snapshotRawCover,
          },
      ],
      'historyCount': 73,
    };
    var batch = 0;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      final response = await transport.call(command, args) as Map;
      final rows = response['items'] as List;
      if (batch++ == 0) {
        (rows.first as Map)['cover'] = 42;
      } else {
        (rows.single as Map)['title'] = 'untrusted response title';
      }
      return response;
    };
    final converted = await SnapshotCoverCodec.shelfToDisplay(snapshot);
    final rows = converted['favorites'] as List;
    expect(rows, hasLength(4097));
    expect(rows.take(4096).map((row) => row['cover']).toSet(), {null});
    expect(rows.last['cover'], snapshotNewCover);
    expect(rows.last['title'], 'original-4096');
    expect(converted['historyCount'], 73);
    expect((snapshot['favorites'] as List).first['cover'], snapshotRawCover);
  });

  testWidgets('live shelf data wins after delayed native cover registration', (tester) async {
    // The native seam is awaited during runAsync; allocate its signals there.
    final gate = (await tester.runAsync(() async => (
      entered: Completer<void>(),
      release: Completer<void>(),
    )))!;
    addTearDown(() {
      if (!gate.release.isCompleted) gate.release.complete();
    });
    debugShelfPreloadOverride = () async => CacheEntry(
      at: _at,
      data: {
        'following': [_favorite('cached shelf title', snapshotRawCover).toJson()],
      },
    );
    SourinCore.debugCallAsyncTransport = (command, args) async {
      if (command == 'covers_to_display') {
        gate.entered.complete();
        await gate.release.future;
      }
      return transport.call(command, args);
    };
    final key = GlobalKey<MyShelfState>();
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(
        body: SingleChildScrollView(child: MyShelf(key: key, compact: true)),
      ),
    ));
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.runAsync(() => gate.entered.future.timeout(const Duration(seconds: 5)));
    debugShelfLoadOverride = () async => (
      <Favorite>[],
      [_favorite('live shelf title', snapshotNewCover)],
      <Progress>[],
    );
    try {
      await tester.runAsync(() => key.currentState!.load());
    } finally {
      gate.release.complete();
    }
    for (var frame = 0; frame < 4; frame++) {
      await tester.pump();
    }
    expect(find.text('live shelf title'), findsOneWidget);
    expect(find.text('cached shelf title'), findsNothing);
    expect(tester.widget<PosterCard>(find.byType(PosterCard)).cover, snapshotNewCover);
    await tester.runAsync(() => snapshotEventually(() async {
      final entry = await DiskCache.read(kShelfCacheFile);
      return ((entry?.data as Map?)?['following'] as List?)?.single['title'] ==
          'live shelf title';
    }));
  });
}
