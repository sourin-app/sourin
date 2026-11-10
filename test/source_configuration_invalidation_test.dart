import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: child),
  );
}

SearchStreamEvent _hit(String title) => SearchStreamEvent(
  kind: SearchEventKind.hit,
  provider: 'tvbox_agg',
  providerName: 'TVBox 聚合',
  items: [MediaItem(id: 'tvbox_agg:sub-b::$title', title: title)],
);

Section _section(String id) => Section(
  id: id,
  title: id,
  source: SectionSource(type: 'category', categoryId: id),
);

void main() {
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SearchPageState.debugAggChannelNamesFetcher = null;
    SearchPageState.debugSearchStreamRunner = null;
    debugSetAggChannelFetchers();
    SourinApi.debugHomeFetcher = null;
    debugShelfLoadOverride = null;
    homeListCache.clear();
    UiPrefs.debugResetForTest();
  });

  testWidgets(
    'home invalidates before slow metadata and ignores an older home response',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      UiPrefs.debugResetForTest();
      debugShelfLoadOverride = () async =>
          (<Favorite>[], <Favorite>[], <Progress>[]);
      var providers = <Map<String, dynamic>>[
        {
          'id': 'a',
          'name': '一级子源甲',
          'kind': 'tvbox',
          'enabled': true,
          'capabilities': {'vod': true},
        },
      ];
      Completer<dynamic>? delayedProviders;
      SourinCore.debugCallAsyncTransport = (command, _) async {
        if (command == 'list_providers') {
          final pending = delayedProviders;
          if (pending != null) return await pending.future;
          return providers;
        }
        if (command == 'list_all_progress') return <dynamic>[];
        if (command == 'repair_library_covers') return 0;
        throw StateError(command);
      };
      var homeCalls = 0;
      final lateHome = Completer<List<ProviderGroup>>();
      SourinApi.debugHomeFetcher = () async {
        homeCalls++;
        if (homeCalls == 2) return lateHome.future;
        return const [ProviderGroup(provider: 'a', providerName: '一级子源甲')];
      };
      final key = GlobalKey<HomePageState>();
      await tester.pumpWidget(_host(HomePage(key: key)));
      await tester.pumpAndSettle();
      expect(find.text('一级子源甲'), findsOneWidget);
      final oldRefresh = key.currentState!.loadAll(reason: 'refresh');
      await tester.pump();
      expect(homeCalls, 2);
      delayedProviders = Completer<dynamic>();
      final changed = key.currentState!.loadAll(reason: 'providers-changed');
      await tester.pump();
      expect(
        find.text('一级子源甲'),
        findsNothing,
        reason:
            'The old source must disappear before refreshed metadata finishes',
      );
      expect(key.currentState!.debugHomeReadout.groups, 0);
      providers = [];
      delayedProviders!.complete(providers);
      await changed;
      lateHome.complete(const [
        ProviderGroup(provider: 'a', providerName: '已关闭旧源'),
      ]);
      await oldRefresh;
      await tester.pumpAndSettle();
      expect(
        homeCalls,
        2,
        reason: 'All-off must not dispatch another home request',
      );
      expect(key.currentState!.debugHomeReadout.source, isEmpty);
      expect(key.currentState!.debugHomeReadout.groups, 0);
      expect(homeListCache.length, 0);
      expect(find.text('一级子源甲'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('all disabled sources never start a new search stream', (
    tester,
  ) async {
    SourinCore.debugCallAsyncTransport = (command, _) async {
      if (command == 'list_providers')
        return [
          {'id': 'off', 'name': '已关闭源', 'enabled': false},
        ];
      throw StateError(command);
    };
    SearchPageState.debugAggChannelNamesFetcher = () async => {};
    var calls = 0;
    SearchPageState.debugSearchStreamRunner = (_, __) async {
      calls++;
    };
    await tester.pumpWidget(_host(const SearchPage()));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(EditableText), '测试');
    await tester.pump();
    await tester.tap(find.byType(ui.FilledButton));
    await tester.pumpAndSettle();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'source changes clear search results and reject old stream work',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      var metadataReads = 0;
      SourinCore.debugCallAsyncTransport = (command, _) async {
        if (command != 'list_providers') throw StateError(command);
        metadataReads++;
        return [
          {'id': 'tvbox_agg', 'name': 'TVBox 聚合', 'enabled': true},
        ];
      };
      SearchPageState.debugAggChannelNamesFetcher = () async => {
        'sub-b': '子源乙',
      };
      final callbacks = <bool Function(SearchStreamEvent)>[];
      final completions = <Completer<void>>[];
      SearchPageState.debugSearchStreamRunner = (keyword, onEvent) {
        expect(keyword, '测试');
        callbacks.add(onEvent);
        final done = Completer<void>();
        completions.add(done);
        return done.future;
      };
      final key = GlobalKey<SearchPageState>();
      await tester.pumpWidget(_host(SearchPage(key: key)));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(EditableText), '测试');
      // onChanged schedules the rebuild that enables the search button.
      await tester.pump();
      await tester.tap(find.byType(ui.FilledButton));
      await tester.pump();
      expect(callbacks, hasLength(1));
      expect(callbacks[0](_hit('原有结果')), isTrue);
      await tester.pump();
      expect(find.text('原有结果'), findsOneWidget);

      await key.currentState!.providersChanged();
      await tester.pump();
      expect(metadataReads, 2);
      expect(find.text('原有结果'), findsNothing);
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '测试',
      );
      expect(callbacks[0](_hit('迟到结果')), isFalse);
      await tester.tap(find.byType(ui.FilledButton));
      await tester.pump();
      expect(callbacks, hasLength(2));
      completions[0].complete();
      await tester.pump();
      expect(
        tester.widget<ui.FilledButton>(find.byType(ui.FilledButton)).onPressed,
        isNull,
        reason: 'Completion of the old search must not end the current one',
      );
      expect(callbacks[1](_hit('当前结果')), isTrue);
      completions[1].complete();
      await tester.pumpAndSettle();
      expect(find.text('当前结果'), findsOneWidget);
      expect(find.text('迟到结果'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late source metadata cannot replace refreshed metadata', (
    tester,
  ) async {
    final oldProviders = Completer<dynamic>();
    final oldNames = Completer<Map<String, String>>();
    var providerCalls = 0;
    var nameCalls = 0;
    SourinCore.debugCallAsyncTransport = (command, _) async {
      if (command != 'list_providers') throw StateError(command);
      if (++providerCalls == 1) return oldProviders.future;
      return [
        {'id': 'tvbox_agg', 'name': 'TVBox 聚合', 'enabled': true},
      ];
    };
    SearchPageState.debugAggChannelNamesFetcher = () {
      if (++nameCalls == 1) return oldNames.future;
      return Future.value({'sub-b': '新子源名称'});
    };
    final key = GlobalKey<SearchPageState>();
    await tester.pumpWidget(_host(SearchPage(key: key)));
    await tester.pump();
    await key.currentState!.providersChanged();
    oldProviders.complete(<dynamic>[]);
    oldNames.complete({'sub-b': '旧子源名称'});
    await tester.pump();
    key.currentState!.debugBeginSearch('测试');
    key.currentState!.debugFeedHit(_hit('测试结果'));
    key.currentState!.debugEndSearch();
    await tester.pumpAndSettle();
    expect(find.text('测试结果'), findsOneWidget);
    expect(find.textContaining('新子源名称'), findsWidgets);
    expect(find.textContaining('旧子源名称'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'aggregate revision reloads channels and discards a disabled home response',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      var channels = const [
        AggChannel(id: 'a', name: '子源甲'),
        AggChannel(id: 'b', name: '子源乙'),
      ];
      final oldHome = Completer<AggChannelHome>();
      final homeCalls = <String>[];
      final loaded = <String>[];
      var revision = 0;
      debugSetAggChannelFetchers(
        channels: () async => AggChannelsPayload(ok: true, channels: channels),
        channelHome: (id) async {
          homeCalls.add(id);
          if (id == 'a') return oldHome.future;
          return AggChannelHome(
            ok: true,
            channelId: id,
            sections: [_section('新章节$revision')],
          );
        },
      );
      final key = GlobalKey<AggChannelsBlockState>();
      Widget block() => _host(
        SingleChildScrollView(
          child: AggChannelsBlock(
            key: key,
            provider: 'tvbox_agg',
            revision: revision,
            onOpenDetail: (_) {},
            itemsOf: (_, __) => const [],
            loadItems: (section) async => loaded.add(section.id),
          ),
        ),
      );
      await tester.pumpWidget(block());
      await tester.pump();
      expect(homeCalls, ['a']);
      final originalState = key.currentState;
      channels = const [AggChannel(id: 'b', name: '子源乙')];
      revision++;
      await tester.pumpWidget(block());
      await tester.pumpAndSettle();
      expect(key.currentState, same(originalState));
      expect(homeCalls, ['a', 'b']);
      expect(find.text('子源甲'), findsNothing);
      expect(find.text('子源乙'), findsOneWidget);
      oldHome.complete(
        AggChannelHome(ok: true, channelId: 'a', sections: [_section('旧章节')]),
      );
      await tester.pumpAndSettle();
      expect(loaded, ['新章节1']);
      expect(find.text('旧章节'), findsNothing);

      revision++;
      await tester.pumpWidget(block());
      await tester.pumpAndSettle();
      expect(homeCalls, ['a', 'b', 'b']);
      expect(loaded, ['新章节1', '新章节2']);
      channels = const [];
      revision++;
      await tester.pumpWidget(block());
      await tester.pumpAndSettle();
      expect(find.text('子源乙'), findsNothing);
      expect(find.text('没有已启用的聚合子源，可在源设置中管理'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('aggregate revision rejects a late channel list', (tester) async {
    final oldChannels = Completer<AggChannelsPayload>();
    var calls = 0;
    debugSetAggChannelFetchers(
      channels: () {
        if (++calls == 1) return oldChannels.future;
        return Future.value(const AggChannelsPayload(ok: true));
      },
      channelHome: (_) =>
          throw StateError('No disabled channel should be loaded'),
    );
    Widget block(int revision) => _host(
      AggChannelsBlock(
        provider: 'tvbox_agg',
        revision: revision,
        onOpenDetail: (_) {},
        itemsOf: (_, __) => const [],
        loadItems: (_) async {},
      ),
    );
    await tester.pumpWidget(block(0));
    await tester.pump();
    await tester.pumpWidget(block(1));
    await tester.pumpAndSettle();
    oldChannels.complete(
      const AggChannelsPayload(
        ok: true,
        channels: [AggChannel(id: 'disabled', name: '已禁用子源')],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已禁用子源'), findsNothing);
    expect(find.text('没有已启用的聚合子源，可在源设置中管理'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
