import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';

import 'support/library_load_fixture.dart';

void main() {
  late Directory scratch;
  late LibraryReadFixture reads;
  late LibraryDiskObserver disk;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('shelf-load-order-');
    DiskCache.debugResetForTest(scratch.path);
    UiPrefs.debugResetForTest(<String, String>{});
    reads = LibraryReadFixture(LibraryReadData.named('initial'));
    disk = LibraryDiskObserver(
      '${scratch.path}${Platform.pathSeparator}$kShelfCacheFile',
    );
    SourinCore.debugCallAsyncTransport = reads.call;
    debugShelfLoadOverride = null;
    debugShelfPreloadOverride = null;
  });

  tearDown(() async {
    reads.releaseAll();
    SourinCore.debugCallAsyncTransport = null;
    debugShelfLoadOverride = null;
    debugShelfPreloadOverride = null;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    await scratch.delete(recursive: true);
    expect(reads.unexpectedCommands, isEmpty);
  });

  Future<GlobalKey<MyShelfState>> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    final key = GlobalKey<MyShelfState>();
    await tester.pumpWidget(libraryLoadHost(
      SingleChildScrollView(child: MyShelf(key: key, compact: true)),
    ));
    addTearDown(() async {
      reads.releaseAll();
      await tester.pumpWidget(const SizedBox.shrink());
      await settleLibraryDisk(tester, disk);
      await tester.pump();
    });
    await pumpLibrary(tester);
    await settleLibraryDisk(tester, disk);
    expect(find.text('initial following title'), findsOneWidget);
    expect(disk.publications, greaterThan(0));
    return key;
  }

  Future<void> expectLanes(
    WidgetTester tester,
    LibraryReadData expected,
  ) async {
    // Tab selection still invokes the real load path. Failed refreshes preserve
    // the already accepted records, allowing each actual rendered lane to be
    // inspected without the fixture repairing a stale overwrite while tapping.
    reads.rejectReads = true;
    final actual = <String, Object>{};
    const labels = ['追更', '收藏', '历史'];
    for (var index = 0; index < labels.length; index++) {
      final label = labels[index];
      final count = tester.widget<ShelfTabs>(find.byType(ShelfTabs)).counts[index];
      await tester.tap(find.text('$label $count'));
      await pumpLibrary(tester);
      actual[label] = {
        'count': count,
        'titles': [
          for (final card in tester.widgetList<PosterCard>(find.byType(PosterCard)))
            card.title,
        ],
      };
    }
    expect(actual, {
      '追更': {
        'count': expected.following.length,
        'titles': [for (final row in expected.following) row.title],
      },
      '收藏': {
        'count': expected.favorites.length,
        'titles': [for (final row in expected.favorites) row.title],
      },
      '历史': {
        'count': expected.historyCount,
        'titles': [for (final row in expected.history) row.title],
      },
    });
    expect(tester.takeException(), isNull);
  }

  Future<void> expectDisk(
    WidgetTester tester,
    LibraryReadData expected,
  ) async {
    await settleLibraryDisk(tester, disk);
    final data = (await tester.runAsync(() => readLibraryDisk(kShelfCacheFile)))!;
    expect(data['favorites'], [for (final f in expected.favorites) f.toJson()]);
    expect(data['following'], [for (final f in expected.following) f.toJson()]);
    expect(data['history'], [for (final p in expected.history) p.toJson()]);
    expect(data['historyCount'], expected.historyCount);
  }

  for (final empty in [false, true]) {
    testWidgets(
      'older shelf read finishing last cannot ${empty ? 'revive successful empty lanes' : 'replace newer cards and persisted metadata'}',
      (tester) async {
        await IOOverrides.runZoned(() async {
          final key = await mount(tester);
          final held = (await tester.runAsync(() async => reads.hold()))!;
          late Future<void> older;
          await tester.runAsync(() async {
            older = key.currentState!.load();
            await held.entered.future.timeout(const Duration(seconds: 5));
          });
          final newer = empty
              ? LibraryReadData.empty
              : LibraryReadData.named('newer', position: 80);
          reads.use(newer);
          try {
            await tester.runAsync(() => key.currentState!.load());
            await pumpLibrary(tester);
            await expectDisk(tester, newer);
          } finally {
            held.complete(LibraryReadData.named('older', position: 10));
          }
          await tester.runAsync(() => older.timeout(const Duration(seconds: 5)));
          await pumpLibrary(tester);
          await expectDisk(tester, newer);
          await expectLanes(tester, newer);
        }, createFile: disk.file);
      },
    );
  }

  testWidgets('an older failed shelf read keeps the newer successful cards', (
    tester,
  ) async {
    await IOOverrides.runZoned(() async {
      final key = await mount(tester);
      final held = (await tester.runAsync(() async => reads.hold()))!;
      late Future<void> older;
      await tester.runAsync(() async {
        older = key.currentState!.load();
        await held.entered.future.timeout(const Duration(seconds: 5));
      });
      final newer = LibraryReadData.named('newer', position: 80);
      reads.use(newer);
      try {
        await tester.runAsync(() => key.currentState!.load());
      } finally {
        held.complete(const LibraryReadData(
          favorites: [], following: [], history: [], historyCount: 0,
          failures: {'favorites', 'following', 'history', 'count'},
        ));
      }
      await tester.runAsync(() => older.timeout(const Duration(seconds: 5)));
      await pumpLibrary(tester);
      await expectDisk(tester, newer);
      await expectLanes(tester, newer);
    }, createFile: disk.file);
  });

  testWidgets('shelf failed lane is retained while successful empty lanes clear', (
    tester,
  ) async {
    await IOOverrides.runZoned(() async {
      final key = await mount(tester);
      final initial = LibraryReadData.named('initial');
      reads.use(const LibraryReadData(
        favorites: [], following: [], history: [], historyCount: 0,
        failures: {'following'},
      ));
      await tester.runAsync(() => key.currentState!.load());
      await pumpLibrary(tester);
      final expected = LibraryReadData(
        favorites: const [],
        following: initial.following,
        history: const [],
        historyCount: 0,
      );
      await expectDisk(tester, expected);
      await expectLanes(tester, expected);
    }, createFile: disk.file);
  });
}
