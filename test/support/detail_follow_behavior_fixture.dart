import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/widgets/detail_raw_meta.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';

import 'library_load_fixture.dart';

// These controls mount the product pages and replace only the existing async
// transport. No native DLL, account, external request or real profile is used.
class _DetailReads {
  int sourceCount = 2;
  final episodeRequests = <Map<String, dynamic>>[];
  final unexpectedCommands = <String>[];

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    switch (command) {
      case 'get_detail':
        return {
          'id': 'fixture-detail-follow:work',
          'title': '线路行为示例',
          'episodes': <Object>[],
          'sources': [
            {'code': 'line-a', 'title': '线路甲', 'count': 1},
            if (sourceCount == 2)
              {'code': 'line-b', 'title': '线路乙', 'count': 1},
          ],
        };
      case 'get_episodes':
        episodeRequests.add(Map<String, dynamic>.from(args!));
        final source = args['source_code'];
        return [
          {'id': '$source:1', 'title': '$source 剧集', 'flag': source},
        ];
      case 'get_progress':
        return null;
      case 'list_favorites':
      case 'list_providers':
        return <Object>[];
      default:
        unexpectedCommands.add(command);
        throw StateError('Unexpected detail behavior command: $command');
    }
  }
}

_DetailReads _installDetailReads() {
  final previousTransport = SourinCore.debugCallAsyncTransport;
  final reads = _DetailReads();
  UiPrefs.debugResetForTest();
  SourinCore.debugCallAsyncTransport = reads.call;
  addTearDown(() {
    SourinCore.debugCallAsyncTransport = previousTransport;
    UiPrefs.debugResetForTest();
    expect(reads.unexpectedCommands, isEmpty);
  });
  return reads;
}

Future<void> _mountDetail(WidgetTester tester, String key) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(860, 904);
  await tester.pumpWidget(libraryLoadHost(DetailPage(
    key: ValueKey(key),
    provider: 'fixture-detail-follow',
    id: 'work',
    embedded: true,
    compactHeader: true,
  )));
  await pumpLibrary(tester);
  await pumpLibrary(tester);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await pumpLibrary(tester);
  tester.view.reset();
}

Future<void> checkDetailSourceRequests(WidgetTester tester) async {
  final reads = _installDetailReads();
  try {
    await _mountDetail(tester, 'source-request');
    expect(reads.episodeRequests, [
      {'provider': 'fixture-detail-follow', 'id': 'work', 'source_code': 'line-a'},
    ]);
    expect(find.text('line-a 剧集').hitTestable(), findsOneWidget);
    final secondSource = find.descendant(
      of: find.byType(DetailSourcePicker),
      matching: find.text('线路乙'),
    );
    expect(secondSource.hitTestable(), findsOneWidget);
    await tester.tap(secondSource);
    await pumpLibrary(tester);
    expect(reads.episodeRequests, [
      {'provider': 'fixture-detail-follow', 'id': 'work', 'source_code': 'line-a'},
      {'provider': 'fixture-detail-follow', 'id': 'work', 'source_code': 'line-b'},
    ]);
    expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active,
        'line-b');
    expect(find.text('line-b 剧集').hitTestable(), findsOneWidget);
    expect(find.text('line-a 剧集'), findsNothing);
    expect(tester.takeException(), isNull);
  } finally {
    await _unmount(tester);
  }
}

Future<void> checkDetailSourceCount(WidgetTester tester) async {
  final reads = _installDetailReads();
  try {
    await _mountDetail(tester, 'two-sources');
    expect(find.text('2 个播放源').hitTestable(), findsOneWidget);
    expect(find.byType(DetailSourcePicker), findsOneWidget);
    expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker))
        .sources.map((source) => source.code), ['line-a', 'line-b']);
    expect(find.text('线路甲').hitTestable(), findsOneWidget);
    expect(find.text('线路乙').hitTestable(), findsOneWidget);

    reads.sourceCount = 1;
    await _mountDetail(tester, 'single-source');
    expect(find.text('2 个播放源'), findsNothing);
    expect(find.text('1 个播放源'), findsNothing);
    expect(find.byType(DetailSourcePicker), findsNothing);
    expect(find.text('播放源'), findsNothing);
    expect(find.text('line-a 剧集').hitTestable(), findsOneWidget,
        reason: 'Hiding a redundant picker must not hide the only source episodes');
    expect(reads.episodeRequests.last['source_code'], 'line-a');
    expect(tester.takeException(), isNull);
  } finally {
    await _unmount(tester);
  }
}

Future<void> checkFollowTabsAndCounts(WidgetTester tester) async {
  Favorite favorite(String id, {bool followed = false}) => Favorite(
    key: 'fixture:$id', provider: 'fixture', nativeId: id, title: id,
    favorited: !followed, following: followed,
  );
  final reads = LibraryReadFixture(LibraryReadData(
    favorites: [favorite('收藏作品甲'), favorite('收藏作品乙')],
    following: [favorite('追更作品', followed: true)],
    history: [libraryProgress('历史作品', 20)],
    historyCount: 3,
  ));
  final previousTransport = SourinCore.debugCallAsyncTransport;
  final previousDirectory = DiskCache.dataDir;
  DiskCache.debugResetForTest();
  SourinCore.debugCallAsyncTransport = reads.call;
  addTearDown(() {
    reads.releaseAll();
    SourinCore.debugCallAsyncTransport = previousTransport;
    DiskCache.debugResetForTest(previousDirectory);
    expect(reads.unexpectedCommands, isEmpty);
  });
  try {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1200, 900);
    await tester.pumpWidget(libraryLoadHost(const FollowPage()));
    await pumpLibrary(tester);
    await pumpLibrary(tester);
    final tabs = find.byType(ShelfTabs);
    expect(tabs, findsOneWidget);
    Finder label(String text) => find.descendant(of: tabs, matching: find.text(text));
    Set<String> titles() => tester.widgetList<PosterCard>(find.byType(PosterCard))
        .map((card) => card.title).toSet();
    expect(tester.widget<ShelfTabs>(tabs).counts, [1, 2, 3]);
    expect(tester.widget<ShelfTabs>(tabs).selected, 0);
    expect(label('追更 1').hitTestable(), findsOneWidget);
    expect(label('收藏 2').hitTestable(), findsOneWidget);
    expect(label('历史 3').hitTestable(), findsOneWidget);
    expect(titles(), {'追更作品'});

    await tester.tap(label('收藏 2'));
    await pumpLibrary(tester);
    expect(tester.widget<ShelfTabs>(tabs).selected, 1);
    expect(titles(), {'收藏作品甲', '收藏作品乙'});
    await tester.tap(label('历史 3'));
    await pumpLibrary(tester);
    expect(tester.widget<ShelfTabs>(tabs).selected, 2);
    expect(titles(), {'历史作品 history title'});
    expect(tester.widget<ShelfTabs>(tabs).counts, [1, 2, 3],
        reason: 'History total is independent of the one rendered preview row');
    await tester.tap(label('追更 1'));
    await pumpLibrary(tester);
    expect(tester.widget<ShelfTabs>(tabs).selected, 0);
    expect(titles(), {'追更作品'});
    expect(tester.takeException(), isNull);
  } finally {
    await _unmount(tester);
  }
}
