import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';

import 'support/library_load_fixture.dart';

void main() {
  late Directory scratch;
  late LibraryReadFixture reads;

  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('follow-load-order-');
    DiskCache.debugResetForTest(scratch.path);
    UiPrefs.debugResetForTest(<String, String>{});
    reads = LibraryReadFixture(LibraryReadData.named('initial'));
    SourinCore.debugCallAsyncTransport = reads.call;
  });

  tearDown(() async {
    reads.releaseAll();
    SourinCore.debugCallAsyncTransport = null;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    await scratch.delete(recursive: true);
    expect(reads.unexpectedCommands, isEmpty);
  });

  Future<GlobalKey<FollowPageState>> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    final key = GlobalKey<FollowPageState>();
    await tester.pumpWidget(libraryLoadHost(FollowPage(key: key)));
    addTearDown(() async {
      reads.releaseAll();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await pumpLibrary(tester);
    expect(find.text('initial following title'), findsOneWidget);
    return key;
  }

  Future<void> expectLanes(
    WidgetTester tester,
    LibraryReadData expected,
  ) async {
    // Keep the actual tab-refresh path active but failing, so selecting another
    // rendered tab cannot repair an earlier stale publication from fixture data.
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
        if (label == '历史')
          'progress': [
            for (final node in tester.widgetList<Semantics>(find.byType(Semantics)))
              if (node.properties.label == '观看进度') node.properties.value,
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
        'progress': [for (final row in expected.history) '${row.percent}%'],
      },
    });
    expect(tester.takeException(), isNull);
  }

  for (final empty in [false, true]) {
    testWidgets(
      'older follow read finishing last cannot ${empty ? 'revive successful empty lanes' : 'replace newer cards or viewing progress'}',
      (tester) async {
        final key = await mount(tester);
        final held = (await tester.runAsync(() async => reads.hold()))!;
        late Future<void> older;
        await tester.runAsync(() async {
          older = key.currentState!.loadAll();
          await held.entered.future.timeout(const Duration(seconds: 5));
        });
        final newer = empty
            ? LibraryReadData.empty
            : LibraryReadData.named('newer', position: 80);
        reads.use(newer);
        try {
          await tester.runAsync(() => key.currentState!.loadAll());
          await pumpLibrary(tester);
          expect(find.text('追更 ${newer.following.length}'), findsOneWidget);
          expect(find.text('older following title'), findsNothing);
          if (!empty) expect(find.text('newer following title'), findsOneWidget);
        } finally {
          held.complete(LibraryReadData.named('older', position: 10));
        }
        await tester.runAsync(() => older.timeout(const Duration(seconds: 5)));
        await pumpLibrary(tester);
        await expectLanes(tester, newer);
      },
    );
  }

  testWidgets('an older failed follow read keeps the newer successful cards', (
    tester,
  ) async {
    final key = await mount(tester);
    final held = (await tester.runAsync(() async => reads.hold()))!;
    late Future<void> older;
    await tester.runAsync(() async {
      older = key.currentState!.loadAll();
      await held.entered.future.timeout(const Duration(seconds: 5));
    });
    final newer = LibraryReadData.named('newer', position: 80);
    reads.use(newer);
    try {
      await tester.runAsync(() => key.currentState!.loadAll());
    } finally {
      held.complete(const LibraryReadData(
        favorites: [], following: [], history: [], historyCount: 0,
        failures: {'favorites', 'following', 'history', 'count'},
      ));
    }
    await tester.runAsync(() => older.timeout(const Duration(seconds: 5)));
    await pumpLibrary(tester);
    await expectLanes(tester, newer);
  });

  testWidgets('follow failed lane is retained while successful empty lanes clear', (
    tester,
  ) async {
    final key = await mount(tester);
    final initial = LibraryReadData.named('initial');
    reads.use(const LibraryReadData(
      favorites: [], following: [], history: [], historyCount: 0,
      failures: {'following'},
    ));
    await tester.runAsync(() => key.currentState!.loadAll());
    await pumpLibrary(tester);
    await expectLanes(tester, LibraryReadData(
      favorites: const [],
      following: initial.following,
      history: const [],
      historyCount: 0,
    ));
  });

  testWidgets('a successful empty follow refresh clears all three prior lists', (
    tester,
  ) async {
    final key = await mount(tester);
    reads.use(LibraryReadData.empty);
    await tester.runAsync(() => key.currentState!.loadAll());
    await pumpLibrary(tester);
    await expectLanes(tester, LibraryReadData.empty);
  });
}
