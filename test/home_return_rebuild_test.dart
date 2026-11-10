import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide Page;
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/source_bar.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: child),
  );
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    homeListCache.clear();
  });
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourinApi.debugHomeFetcher = null;
    SourinApi.debugSetListFetchers();
    debugShelfLoadOverride = null;
    homeListCache.clear();
    UiPrefs.debugResetForTest();
  });

  testWidgets(
    'unchanged return reuses fresh catalog and refreshes personal data',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      var providerCalls = 0, homeCalls = 0, shelfCalls = 0, listCalls = 0;
      var sourceName = '测试源';
      var cardTitle = '旧内容';
      var enabled = true;
      debugShelfLoadOverride = () async {
        shelfCalls++;
        return (<Favorite>[], <Favorite>[], <Progress>[]);
      };
      SourinCore.debugCallAsyncTransport = (command, _) async {
        if (command == 'list_providers') {
          providerCalls++;
          return [
            {
              'id': 'a',
              'name': sourceName,
              'kind': 'tvbox',
              'enabled': enabled,
              'capabilities': {'vod': true},
            },
          ];
        }
        if (command == 'list_all_progress') return <dynamic>[];
        if (command == 'repair_library_covers') return 0;
        throw StateError(command);
      };
      SourinApi.debugHomeFetcher = () async {
        homeCalls++;
        return [
          ProviderGroup(
            provider: 'a',
            providerName: sourceName,
            sections: [
              Section(
                id: 'recent',
                title: '最近更新',
                source: SectionSource(type: 'category', categoryId: 'recent'),
              ),
            ],
          ),
        ];
      };
      SourinApi.debugSetListFetchers(
        getList: (_, __, {int page = 1}) async {
          listCalls++;
          return Page(
            items: [MediaItem(id: 'a:1', title: cardTitle)],
          );
        },
      );
      final key = GlobalKey<HomePageState>();
      await tester.pumpWidget(_host(HomePage(key: key)));
      await tester.pumpAndSettle();
      final home = tester.element(find.byType(HomePage));
      final sourceBar = tester.widget<SourceBar>(find.byType(SourceBar));
      final callsBefore = (providerCalls, homeCalls, shelfCalls, listCalls);
      expect(home.dirty, isFalse);
      expect(find.text('旧内容'), findsOneWidget);

      await key.currentState!.loadAll(reason: 'tab-switch');
      expect(providerCalls, callsBefore.$1 + 1);
      expect(homeCalls, callsBefore.$2);
      expect(shelfCalls, callsBefore.$3 + 1);
      expect(listCalls, callsBefore.$4);
      expect(home.dirty, isFalse);
      await tester.pumpAndSettle();
      expect(tester.widget<SourceBar>(find.byType(SourceBar)), same(sourceBar));

      // Positive control: a forced content refresh still updates cards, while
      // the unchanged sticky source bar retains its widget configuration.
      cardTitle = '新内容';
      await key.currentState!.loadAll(force: true, reason: 'refresh');
      expect(home.dirty, isTrue);
      expect(listCalls, callsBefore.$4 + 1);
      await tester.pumpAndSettle();
      expect(find.text('旧内容'), findsNothing);
      expect(find.text('新内容'), findsOneWidget);
      expect(tester.widget<SourceBar>(find.byType(SourceBar)), same(sourceBar));

      sourceName = '改名后的源';
      await key.currentState!.loadAll(reason: 'tab-switch');
      await tester.pumpAndSettle();
      expect(find.text('改名后的源'), findsOneWidget);
      expect(find.text('测试源'), findsNothing);

      enabled = false;
      final homeCallsBeforeDisable = homeCalls;
      await key.currentState!.loadAll(reason: 'tab-switch');
      await tester.pumpAndSettle();
      expect(homeCalls, homeCallsBeforeDisable);
      expect(key.currentState!.debugHomeReadout.groups, 0);
      expect(key.currentState!.debugHomeReadout.source, isEmpty);
      expect(find.text('新内容'), findsNothing);
      await key.currentState!.loadAll(reason: 'tab-switch');
      expect(home.dirty, isFalse);
      expect(homeCalls, homeCallsBeforeDisable);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'catalog reuse expires without sliding and invalidates on edits or errors',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      var now = DateTime.utc(2026, 11, 9);
      var homeCalls = 0;
      var failMetadata = false;
      debugShelfLoadOverride = () async =>
          (<Favorite>[], <Favorite>[], <Progress>[]);
      SourinCore.debugCallAsyncTransport = (command, _) async {
        if (command == 'list_providers') {
          return [
            {
              'id': 'a',
              'name': '测试源',
              'kind': 'tvbox',
              'enabled': true,
              'capabilities': {'vod': true},
            },
          ];
        }
        if (command == 'list_all_progress') return <dynamic>[];
        if (command == 'repair_library_covers') return 0;
        throw StateError(command);
      };
      SourinApi.debugHomeFetcher = () async {
        homeCalls++;
        if (failMetadata) throw StateError('metadata temporarily unavailable');
        return const [ProviderGroup(provider: 'a', providerName: '测试源')];
      };
      final key = GlobalKey<HomePageState>();
      await tester.pumpWidget(
        _host(HomePage(key: key, catalogClock: () => now)),
      );
      await tester.pumpAndSettle();
      expect(homeCalls, 1);

      now = now.add(const Duration(seconds: 20));
      await key.currentState!.loadAll(reason: 'tab-switch');
      expect(homeCalls, 1);
      now = now.add(const Duration(seconds: 11));
      await key.currentState!.loadAll(reason: 'tab-switch');
      expect(
        homeCalls,
        2,
        reason: 'Returning must not renew the original metadata age',
      );

      await key.currentState!.loadAll(force: true, reason: 'user-refresh');
      expect(homeCalls, 3, reason: 'Manual refresh must bypass fresh metadata');
      await key.currentState!.loadAll(reason: 'providers-changed');
      expect(
        homeCalls,
        4,
        reason: 'Changed source addresses invalidate the same provider id',
      );
      await key.currentState!.loadAll(reason: 'github-source-enabled');
      expect(homeCalls, 5);

      failMetadata = true;
      await key.currentState!.loadAll(force: true, reason: 'user-refresh');
      expect(homeCalls, 6);
      failMetadata = false;
      await key.currentState!.loadAll(reason: 'tab-switch');
      expect(
        homeCalls,
        7,
        reason: 'A failed refresh cannot leave the old catalog fresh',
      );
      now = now.subtract(const Duration(seconds: 1));
      await key.currentState!.loadAll(reason: 'tab-switch');
      expect(homeCalls, 8, reason: 'Clock rollback cannot prolong freshness');
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'sticky source bar reuses equal data and updates changed inputs',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final barKey = GlobalKey();
      var selected = '';
      void onSelect(String id) => selected = id;
      List<ProviderManifest> sources({String name = '甲', String? icon}) => [
        ProviderManifest(id: 'a', name: name, icon: icon),
        const ProviderManifest(id: 'b', name: '乙'),
      ];
      Widget page(
        List<ProviderManifest> items, {
        String current = 'a',
        ValueChanged<String>? onChanged,
      }) => CustomScrollView(
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: debugStickySourceBar(
              visibleCount: visibleSourceList(items).length,
              sources: items,
              current: current,
              onSelect: onChanged ?? onSelect,
              key: barKey,
            ),
          ),
        ],
      );

      // Keep MaterialApp/theme/route ancestors fixed: the production change
      // guards a page update, not an inherited-theme rebuild of the header.
      final content = ValueNotifier<Widget>(page(sources()));
      addTearDown(content.dispose);
      await tester.pumpWidget(
        _host(
          ValueListenableBuilder<Widget>(
            valueListenable: content,
            builder: (_, child, __) => child,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final original = tester.widget<SourceBar>(find.byType(SourceBar));
      content.value = page(sources());
      await tester.pumpAndSettle();
      expect(tester.widget<SourceBar>(find.byType(SourceBar)), same(original));

      final changedSources = sources(name: '新甲', icon: '★').reversed.toList();
      content.value = page(changedSources, current: 'b');
      await tester.pumpAndSettle();
      expect(find.text('甲'), findsNothing);
      expect(find.text('新甲'), findsOneWidget);
      expect(find.text('★'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('乙')).dx,
        lessThan(tester.getTopLeft(find.text('新甲')).dx),
      );
      expect(
        tester.widget<SourcePill>(find.widgetWithText(SourcePill, '乙')).active,
        isTrue,
      );
      await tester.tap(find.text('新甲'));
      expect(selected, 'a');

      content.value = page(
        changedSources,
        current: 'b',
        onChanged: (id) => selected = 'new:$id',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('新甲'));
      expect(selected, 'new:a');

      content.value = page(const [
        ProviderManifest(id: 'a', name: '新甲', enabled: false),
        ProviderManifest(id: 'b', name: '乙'),
      ], current: 'b');
      await tester.pumpAndSettle();
      expect(find.text('新甲'), findsNothing);
      expect(find.text('乙'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
