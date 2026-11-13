// One test keeps all negative network cases before the first allowed repair.
// LibraryCoverRecovery's process-wide minute cooldown must not mask those cases.
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';

import 'support/library_load_fixture.dart';

void main() {
  testWidgets(
    'retained library pages defer hidden network work and keep visible return refresh',
    (tester) async {
      final scratch = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('library-visible-'),
      ))!;
      DiskCache.debugResetForTest(scratch.path);
      UiPrefs.debugResetForTest(<String, String>{});
      debugShelfLoadOverride = null;
      debugShelfPreloadOverride = null;
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);

      const unknown = Progress(
        key: 'fixture:history:e2',
        provider: 'fixture',
        nativeId: 'history',
        title: '',
        episodeId: 'e2',
        episodeTitle: '',
        position: 37,
        duration: 100,
        updatedAt: 200,
      );
      final data = LibraryReadData(
        favorites: [libraryFavorite('favorites', 'preserved')],
        following: [libraryFavorite('following', 'preserved')],
        history: const [unknown],
        historyCount: 1,
      );
      final reads = LibraryReadFixture(data);
      final commands = <String>[];
      final metadataWrites = <Map<String, dynamic>>[];
      final repairFinish = Completer<int>();
      final shelf = GlobalKey<MyShelfState>();
      final follow = GlobalKey<FollowPageState>();
      final navigator = GlobalKey<NavigatorState>();
      // -1 models a different active shell tab. Both previously visited pages
      // stay mounted, just as the production keyed Offstage/TickerMode stack.
      final active = ValueNotifier<int>(-1);
      final shelfDisk = LibraryDiskObserver(
        '${scratch.path}${Platform.pathSeparator}$kShelfCacheFile',
      );

      int count(String command) => commands.where((c) => c == command).length;
      int localReads() => commands.where((c) => const {
        'list_favorites',
        'continue_watching',
        'continue_watching_count',
      }.contains(c)).length;

      SourinCore.debugCallAsyncTransport = (command, args) {
        commands.add(command);
        if (command == 'repair_library_covers') return repairFinish.future;
        if (command == 'get_detail') {
          return Future.value(<String, dynamic>{
            'id': 'fixture:history',
            'title': 'recovered history title',
            'episodes': <dynamic>[],
          });
        }
        if (command == 'patch_progress_metadata') {
          metadataWrites.add(Map<String, dynamic>.from(args!));
          reads.use(LibraryReadData(
            favorites: data.favorites,
            following: data.following,
            history: [Progress(
              key: unknown.key,
              provider: unknown.provider,
              nativeId: unknown.nativeId,
              title: args['title'] as String,
              episodeId: unknown.episodeId,
              episodeTitle: unknown.episodeTitle,
              position: unknown.position,
              duration: unknown.duration,
              finished: unknown.finished,
              updatedAt: unknown.updatedAt,
            )],
            historyCount: data.historyCount,
          ));
          return Future<dynamic>.value(null);
        }
        return reads.call(command, args);
      };

      Future<void> settle() async {
        await pumpLibrary(tester);
        await settleLibraryDisk(tester, shelfDisk);
        await tester.pump();
      }

      Future<void> roundTrip() async {
        final routeDone = navigator.currentState!.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('owned detail route')),
          ),
        );
        await tester.pumpAndSettle();
        navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await routeDone;
        await settle();
      }

      try {
        await IOOverrides.runZoned(() async {
          // Reuse the existing themed fixture host; this builder merely gives
          // its two real product pages the same keep-alive visibility boundary.
          await tester.pumpWidget(libraryLoadHost(
            Navigator(
              key: navigator,
              onGenerateRoute: (_) => MaterialPageRoute<void>(
                builder: (_) => ValueListenableBuilder<int>(
                  valueListenable: active,
                  builder: (_, tab, __) => Stack(children: [
                    Offstage(
                      offstage: tab != 0,
                      child: TickerMode(
                        enabled: tab == 0,
                        child: MyShelf(key: shelf),
                      ),
                    ),
                    Offstage(
                      offstage: tab != 1,
                      child: TickerMode(
                        enabled: tab == 1,
                        child: FollowPage(key: follow, initialTab: 'continue'),
                      ),
                    ),
                    if (tab == -1) const Text('another active shell tab'),
                  ]),
                ),
              ),
            ),
          ));
          await settle();
          expect(shelf.currentState, isNotNull);
          expect(follow.currentState, isNotNull);
          expect(localReads(), greaterThan(0),
              reason: 'Explicit local reads are allowed while initially hidden');
          expect(count('repair_library_covers'), 0,
              reason: 'A hidden initial local read must not start cover egress');
          expect(count('get_detail'), 0,
              reason: 'A hidden initial local read must not start title egress');
          expect(count('check_updates'), 0,
              reason: 'A hidden initial load must not start a network sweep');

          final beforeHiddenReturn = localReads();
          await roundTrip();
          expect(localReads(), beforeHiddenReturn,
              reason: 'Both retained hidden route gates must ignore pop return');
          expect(count('repair_library_covers'), 0);
          expect(count('get_detail'), 0);

          for (final tab in [0, 1]) {
            active.value = tab;
            await tester.pump();
            final held = reads.hold();
            final load = tab == 0
                ? shelf.currentState!.load()
                : follow.currentState!.loadAll();
            await tester.pump();
            expect(held.entered.isCompleted, isTrue,
                reason: 'Real product local reads entered the held transport');
            active.value = -1;
            await tester.pump();
            held.complete(data);
            await load;
            await settle();
            reads.use(data);
            expect(count('repair_library_covers'), 0,
                reason: 'Read begun visible for tab $tab finished hidden');
            expect(count('get_detail'), 0,
                reason: 'Hidden Follow completion must defer title backfill');
            expect(count('check_updates'), 0);
            expect(metadataWrites, isEmpty);
          }

          // Actual visible entry now permits the first repair and title request.
          // Deliberately hold its repair result to test the later changed>0 path.
          active.value = 1;
          // Start the real read before the parent's next frame updates the old
          // hidden TickerMode. Fast FFI reads must not lose this visible entry.
          await follow.currentState!.loadAll();
          expect(count('repair_library_covers'), 0);
          expect(count('get_detail'), 0);
          expect(count('check_updates'), 0);
          await settle();
          expect(count('repair_library_covers'), 1,
              reason: 'A visible product entry still reaches the core repair');
          expect(count('get_detail'), 1);
          expect(metadataWrites, hasLength(1));
          expect(find.text('recovered history title'), findsOneWidget);
          expect(metadataWrites.single, {
            'provider': unknown.provider,
            'id': unknown.nativeId,
            'episode_id': unknown.episodeId,
            'expected_title': unknown.title,
            'expected_cover': unknown.cover,
            'title': 'recovered history title',
            'cover': null,
          }, reason: 'Metadata patch does not rewrite playback or ordering fields');
          final progress = tester.widgetList<Semantics>(find.descendant(
            of: find.byKey(follow),
            matching: find.byType(Semantics),
          )).where((w) => w.properties.label == '观看进度');
          expect(progress.map((w) => w.properties.value), ['37%'],
              reason: 'The actual visible progress remains unchanged');

          final beforeHiddenRepairFinish = localReads();
          active.value = -1;
          await tester.pump();
          repairFinish.complete(1);
          await settle();
          expect(localReads(), beforeHiddenRepairFinish,
              reason: 'A positive repair finishing hidden must not reload');

          // Positive local refresh checks follow both visible return paths. The
          // already-used shared repair cooldown is deliberately not counted as
          // evidence of a second repair call or as a hidden-work cancellation.
          for (final tab in [1, 0]) {
            active.value = tab;
            await tester.pump();
            if (tab == 1) {
              await follow.currentState!.loadAll();
            } else {
              await shelf.currentState!.load();
            }
            await settle();
            final beforeVisibleReturn = localReads();
            await roundTrip();
            expect(localReads(), greaterThan(beforeVisibleReturn),
                reason: 'Visible tab $tab preserves its original return refresh');
          }
          final shelfTabs = tester.widget<ShelfTabs>(find.descendant(
            of: find.byKey(shelf),
            matching: find.byType(ShelfTabs),
          ));
          expect(shelfTabs.counts, [1, 1, 1]);
          expect(tester.widgetList<PosterCard>(find.descendant(
            of: find.byKey(shelf),
            matching: find.byType(PosterCard),
          )).map((w) => w.title), ['preserved following title']);
          expect(reads.unexpectedCommands, isEmpty);
        }, createFile: shelfDisk.file);
      } finally {
        reads.releaseAll();
        if (!repairFinish.isCompleted) repairFinish.complete(0);
        await tester.pumpWidget(const SizedBox.shrink());
        await settleLibraryDisk(tester, shelfDisk);
        await tester.pump();
        active.dispose();
        SourinCore.debugCallAsyncTransport = null;
        debugShelfLoadOverride = null;
        debugShelfPreloadOverride = null;
        DiskCache.debugResetForTest();
        UiPrefs.debugResetForTest(<String, String>{});
        await tester.runAsync(() => scratch.delete(recursive: true));
      }
    },
  );
}
