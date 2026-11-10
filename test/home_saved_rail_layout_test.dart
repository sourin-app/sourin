import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide Page;
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/webhome/webhome_store.dart';
import 'package:sourin_spike/ui/widgets/compact_shelf_card.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';
import 'package:sourin_spike/ui/widgets/shelf_tabs.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

import 'support/miuix_finders.dart';

Future<void> _mount(
  WidgetTester tester,
  double width,
  List<String> opened,
  List<String> seeAll, {
  double scale = 1,
  List<Favorite>? following,
  List<Progress> history = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  Device.overrideKind(width < 640 ? DeviceKind.touchOnly : DeviceKind.desktop);
  UiPrefs.debugResetForTest({UiPrefs.homeSourceKey: 'fixture'});
  DiskCache.debugResetForTest();
  homeListCache.clear();
  SourceDiscoveryService.current.value = null;
  late Directory scratch;
  await tester.runAsync(() async {
    scratch = await Directory.systemTemp.createTemp('home-saved-rail-');
    WebHomeController.debugSetDataDir(scratch.path);
    await WebHomeController.instance.reload();
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    SourinCore.debugCallAsyncTransport = null;
    SourinApi.debugHomeFetcher = null;
    SourinApi.debugSetListFetchers();
    debugShelfLoadOverride = null;
    debugShelfPreloadOverride = null;
    homeListCache.clear();
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest();
    Device.overrideKind(null);
    SourceDiscoveryService.current.value = null;
    WebHomeController.debugSetDataDir(null);
    tester.view.reset();
    await tester.runAsync(() => scratch.delete(recursive: true));
  });
  debugShelfPreloadOverride = () async => null;
  debugShelfLoadOverride = () async => (
    const [
      Favorite(
        key: 'fixture:favorite',
        provider: 'fixture',
        nativeId: 'favorite',
        title: '收藏内容',
        favorited: true,
      ),
    ],
    following ?? const [
      Favorite(
        key: 'fixture:following',
        provider: 'fixture',
        nativeId: 'following',
        title: '追更内容保留单行标题',
        following: true,
        lastEpisodeTitle: '第14集',
      ),
    ],
    history,
  );
  SourinCore.debugCallAsyncTransport = (command, _) async {
    switch (command) {
      case 'list_providers':
        return [
          {
            'id': 'fixture',
            'name': '测试来源',
            'kind': 'tvbox',
            'enabled': true,
            'capabilities': {'vod': true},
          },
        ];
      case 'list_all_progress':
        return <dynamic>[];
      case 'repair_library_covers':
        return 0;
      case 'source_discovery_status':
        return <String, dynamic>{};
      default:
        throw StateError('Unexpected homepage fixture command: $command');
    }
  };
  SourinApi.debugHomeFetcher = () async => [
    const ProviderGroup(
      provider: 'fixture',
      providerName: '测试来源',
      sections: [
        Section(
          id: 'catalog',
          title: '目录',
          source: SectionSource(type: 'category', categoryId: 'catalog'),
        ),
      ],
    ),
  ];
  SourinApi.debugSetListFetchers(
    getList: (_, __, {int page = 1}) async => const Page<MediaItem>(
      items: [MediaItem(id: 'fixture:catalog', title: '目录内容')],
    ),
  );
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
          ),
          child: child!,
        ),
      ),
      home: Scaffold(
        body: HomePage(
          onOpenDetail: (provider, id) => opened.add('$provider:$id'),
          onSeeAllShelf: seeAll.add,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [1280.0, 360.0]) {
    for (final scale in [1.0, 1.6]) {
      testWidgets('saved rail omits empty subtitle space at $width / $scale', (
        tester,
      ) async {
        final opened = <String>[];
        final seeAll = <String>[];
        await _mount(tester, width, opened, seeAll, scale: scale);
        final shelf = find.byType(MyShelf);
        final card = find.byType(CompactShelfCard);
        expect(card, findsOneWidget);
        final poster = find.descendant(
          of: card,
          matching: find.byType(PosterCard),
        );
        expect(poster, findsOneWidget);
        final shelfBounds = tester.getRect(shelf);
        final cardBounds = tester.getRect(card);
        final tabsBounds = tester.getRect(find.byType(ShelfTabs));
        final sourceBounds = tester.getRect(find.byType(SourceBar));
        final title = find.text('追更内容保留单行标题');
        expect(tester.widget<Text>(title).maxLines, 1);
        expect(tester.getRect(title).top,
            greaterThan(tester.getRect(poster).bottom));
        expect(cardBounds.width, closeTo(CompactShelfCard.width, .01));
        expect(tester.getSize(poster).width, closeTo(116, .01));
        expect(tester.getSize(poster).height, closeTo(174, .01));
        expect(find.text('更新至14集'), findsOneWidget);
        final statusBounds = tester.getRect(find.descendant(
          of: poster,
          matching: find.byKey(const ValueKey('poster-release-status')),
        ));
        expect(statusBounds.bottom, lessThan(tester.getRect(poster).bottom));
        expect(sourceBounds.top, greaterThanOrEqualTo(shelfBounds.bottom));
        expect(tabsBounds.bottom, lessThanOrEqualTo(cardBounds.top));
        expect(tester.widget<CompactShelfCard>(card).subtitle, isNull);
        final titleBounds = tester.getRect(title);
        expect(
          cardBounds.bottom - titleBounds.bottom,
          closeTo(Sp.x2, .1),
          reason: 'A title-only card needs its existing bottom padding, '
              'not an empty subtitle row.',
        );
        final necessaryHeight = Sp.x2 + tester.getSize(poster).height +
            Sp.x2 + titleBounds.height + Sp.x2;
        expect(cardBounds.height, closeTo(necessaryHeight, .1));
        expect(sourceBounds.top - shelfBounds.bottom,
            lessThanOrEqualTo(Sp.x6 + Sp.x3));
        await tester.tap(title);
        await tester.pump();
        expect(opened, ['fixture:following']);
        await tester.tap(miuixTooltip('查看更多'));
        await tester.pump();
        expect(seeAll, ['following']);
        await tester.tap(find.text('收藏 1'));
        await tester.pumpAndSettle();
        expect(find.text('收藏内容'), findsOneWidget);
        expect(find.text('追更内容保留单行标题'), findsNothing);
        await tester.tap(miuixTooltip('查看更多'));
        await tester.pump();
        expect(seeAll, ['following', 'all']);
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets('mixed saved subtitles reserve one shared row without changing posters', (
    tester,
  ) async {
    await _mount(tester, 1280, [], [], following: const [
      Favorite(
        key: 'fixture:following', provider: 'fixture', nativeId: 'following',
        title: '仅标题内容', lastEpisodeTitle: '第14集',
      ),
      Favorite(
        key: 'fixture:extra', provider: 'fixture', nativeId: 'extra',
        title: '附带文字内容', lastEpisodeTitle: '幕后花絮',
      ),
    ]);
    final cards = find.byType(CompactShelfCard);
    expect(cards, findsNWidgets(2));
    final first = tester.getRect(cards.first);
    final second = tester.getRect(cards.last);
    expect(first.height, closeTo(second.height, .01));
    expect(first.bottom, closeTo(second.bottom, .01));
    final text = find.text('幕后花絮');
    expect(text, findsOneWidget);
    expect(second.bottom - tester.getRect(text).bottom, closeTo(Sp.x2, .1));
    expect(tester.widget<CompactShelfCard>(cards.first).subtitle, isNull);
    expect(tester.widget<CompactShelfCard>(cards.last).subtitle, '幕后花絮');
    for (final card in [cards.first, cards.last]) {
      final poster = find.descendant(of: card, matching: find.byType(PosterCard));
      expect(tester.getSize(poster), const Size(116, 174));
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('history and favorite captions retain their rendered subtitle row', (
    tester,
  ) async {
    final seeAll = <String>[];
    await _mount(tester, 1280, [], seeAll, history: const [
      Progress(
        key: 'fixture:history:e4', provider: 'fixture', nativeId: 'history',
        title: '历史内容', episodeTitle: '第4集', position: 40, duration: 100,
      ),
    ]);
    for (final (tab, caption, target) in [
      ('收藏 1', '剧集', 'all'),
      ('历史 1', '第4集', 'continue'),
    ]) {
      await tester.tap(find.text(tab));
      await tester.pumpAndSettle();
      final card = find.byType(CompactShelfCard);
      expect(card, findsOneWidget);
      expect(tester.widget<CompactShelfCard>(card).subtitle, caption);
      final text = find.descendant(of: card, matching: find.text(caption));
      expect(text, findsOneWidget);
      expect(tester.getRect(card).bottom - tester.getRect(text).bottom,
          closeTo(Sp.x2, .1));
      await tester.tap(miuixTooltip('查看更多'));
      await tester.pump();
      expect(seeAll.last, target);
    }
    expect(tester.takeException(), isNull);
  });
}
