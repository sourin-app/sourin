import 'dart:async';

import 'package:flutter/rendering.dart' show RenderViewport;
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/settings/theme_page.dart';
import 'package:sourin_spike/ui/widgets/app_loading.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/settings_kit.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(
      data: theme,
      child: ToastHost(child: child!),
    ),
    home: Scaffold(body: child),
  );
}

class _SettingsData {
  final calls = <String, int>{};
  Completer<dynamic>? pendingProviders;
  bool failProviders = false;
  List<Map<String, dynamic>> providers = [
    {'id': 'a', 'name': '源甲', 'kind': 'tvbox', 'enabled': true},
  ];
  List<Map<String, dynamic>> markers = [];
  List<List<String>> failures = [];
  Map<String, dynamic> remote = {'running': false};
  bool autoStart = false;

  Future<dynamic> call(String command, Map<String, dynamic>? _) async {
    calls.update(command, (n) => n + 1, ifAbsent: () => 1);
    switch (command) {
      case 'list_providers':
        if (failProviders) throw StateError('fixture failed');
        return pendingProviders?.future ?? providers;
      case 'list_plugins':
        return {'plugins': <dynamic>[], 'failed': failures};
      case 'remote_status_cmd':
        return remote;
      case 'remote_auto_start':
        return autoStart;
      case 'list_skip_markers':
        return markers;
      case 'list_tvbox_sources':
        return {'sources': <dynamic>[]};
      case 'restore_failures':
      case 'global_proxy_migration_choices':
        return <dynamic>[];
      case 'list_plugin_sources':
      case 'list_proxy_configs':
      case 'source_discovery_status':
      case 'source_catalog_get':
      case 'tvbox_update_schedule_get':
        return <String, dynamic>{};
      default:
        throw StateError('Unexpected command: $command');
    }
  }
}

SearchStreamEvent _hit(String provider, String id, String title) =>
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: provider,
      providerName: provider,
      items: [MediaItem(id: id, title: title)],
    );

void main() {
  setUp(() {
    Device.overrideKind(DeviceKind.desktop);
    UiPrefs.debugResetForTest();
    SourceDiscoveryService.current.value = null;
    ProxyCache.invalidate();
  });
  tearDown(() {
    Device.overrideKind(null);
    SourinCore.debugCallAsyncTransport = null;
    SourinApi.debugTvboxConfigSiteTotalFetcher = null;
    SearchPageState.debugAggChannelNamesFetcher = null;
    SearchPageState.debugSearchStreamRunner = null;
    SourceDiscoveryService.current.value = null;
    ProxyCache.invalidate();
    UiPrefs.debugResetForTest();
  });

  testWidgets(
    'settings lays out fewer offscreen entries without moving visible rows',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1592, 864);
      addTearDown(tester.view.reset);
      final data = _SettingsData();
      SourinCore.debugCallAsyncTransport = data.call;
      await tester.pumpWidget(_host(const SettingsPage()));
      await tester.pumpAndSettle();

      Map<String, Rect> visibleRows() {
        final viewport = tester.getRect(find.byType(ListView));
        return {
          for (final row in tester.widgetList<SettingsEntryRow>(
            find.byType(SettingsEntryRow),
          ))
            if (tester.getRect(find.byWidget(row)).overlaps(viewport))
              row.title: tester.getRect(find.byWidget(row)),
        };
      }

      final visible = visibleRows();
      // Sliver finders skip cached children by default. Count all mounted
      // entries here, while visibleRows above checks only painted geometry.
      final allRows = find.byType(SettingsEntryRow, skipOffstage: false);
      final mounted = allRows.evaluate().length;
      final reducedBounds = {
        for (final row in tester.widgetList<SettingsEntryRow>(allRows))
          row.title: tester.getRect(find.byWidget(row, skipOffstage: false)),
      };
      final reducedCache = tester
          .renderObject<RenderViewport>(find.byType(Viewport))
          .scrollCacheExtent;
      final list = tester.widget<ListView>(find.byType(ListView));
      final children =
          (list.childrenDelegate as SliverChildListDelegate).children;
      expect(visible, isNotEmpty);

      // Compare the same production rows with Flutter's default cache. This
      // measures avoided mounting/layout work without a timing threshold.
      await tester.pumpWidget(
        _host(
          ListView(
            clipBehavior: list.clipBehavior,
            padding: list.padding,
            children: children,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(visibleRows(), visible);
      final defaultBounds = {
        for (final row in tester.widgetList<SettingsEntryRow>(allRows))
          row.title: tester.getRect(find.byWidget(row, skipOffstage: false)),
      };
      final defaultCache = tester
          .renderObject<RenderViewport>(find.byType(Viewport))
          .scrollCacheExtent;
      expect(
        allRows.evaluate().length,
        greaterThan(mounted),
        reason:
            'Reduced cache $reducedCache: $reducedBounds; '
            'default cache $defaultCache: $defaultBounds',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'settings keeps scrolling, routes and disclosure state with a smaller cache',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 700);
      addTearDown(tester.view.reset);
      final data = _SettingsData();
      SourinCore.debugCallAsyncTransport = data.call;
      await tester.pumpWidget(_host(const SettingsPage()));
      await tester.pumpAndSettle();

      final header = find.byKey(const ValueKey('settings-disclosure-header'));
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('开启遥控'), findsOneWidget);

      final themeEntry = find.byWidgetPredicate(
        (widget) => widget is SettingsEntryRow && widget.title == '外观',
      );
      final scrollable = find.descendant(
        of: find.byType(ListView),
        matching: find.byType(Scrollable),
      );
      await tester.scrollUntilVisible(themeEntry, 400, scrollable: scrollable);
      await tester.pumpAndSettle();
      final position = tester.state<ScrollableState>(scrollable).position;
      final offset = position.pixels;
      expect(offset, greaterThan(0));
      expect(header, findsNothing);
      await tester.tap(themeEntry);
      await tester.pumpAndSettle();
      expect(find.byType(ThemeSettingsPage), findsOneWidget);
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(position.pixels, closeTo(offset, 0.01));

      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(find.text('开启遥控'), findsOneWidget);
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.text('开启遥控'), findsNothing);
      await tester.scrollUntilVisible(themeEntry, 400, scrollable: scrollable);
      await tester.pumpAndSettle();
      position.jumpTo(0);
      await tester.pumpAndSettle();
      expect(header, findsOneWidget);
      expect(find.text('开启遥控'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'settings keyboard traversal reaches entries beyond the layout cache',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 700);
      addTearDown(tester.view.reset);
      final data = _SettingsData();
      SourinCore.debugCallAsyncTransport = data.call;
      await tester.pumpWidget(_host(const SettingsPage()));
      await tester.pumpAndSettle();
      final list = tester.widget<ListView>(find.byType(ListView));
      final expected = (list.childrenDelegate as SliverChildListDelegate)
          .children
          .whereType<SettingsEntryRow>()
          .map((row) => row.title)
          .toSet();
      final visited = <String>{};

      for (var step = 0; step < 80 && !visited.contains('关于'); step++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        FocusManager.instance.primaryFocus?.context?.visitAncestorElements((
          element,
        ) {
          final widget = element.widget;
          if (widget is SettingsEntryRow) {
            visited.add(widget.title);
            expect(
              tester
                  .getRect(find.byWidget(widget))
                  .overlaps(tester.getRect(find.byType(ListView))),
              isTrue,
              reason: '${widget.title} should scroll into view with focus',
            );
          }
          return true;
        });
      }

      expect(visited, containsAll(expected));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'settings skips unchanged refreshes but renders new data and external prefs',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1100);
      addTearDown(tester.view.reset);
      final data = _SettingsData();
      data.pendingProviders = Completer<dynamic>();
      SourinCore.debugCallAsyncTransport = data.call;
      final key = GlobalKey<SettingsPageState>();
      await tester.pumpWidget(_host(SettingsPage(key: key)));
      final page = tester.element(find.byType(SettingsPage));
      expect(find.byType(AppLoading), findsOneWidget);
      expect(
        page.dirty,
        isFalse,
        reason: 'Starting the initial request must not rebuild its spinner',
      );
      data.pendingProviders!.complete(data.providers);
      data.pendingProviders = null;
      await tester.pumpAndSettle();
      expect(find.byType(AppLoading), findsNothing);
      final list = tester.widget<ListView>(find.byType(ListView));
      final before = Map<String, int>.of(data.calls);

      await key.currentState!.loadAll();
      for (final command in [
        'list_providers',
        'list_plugins',
        'remote_status_cmd',
        'remote_auto_start',
        'list_skip_markers',
        'list_plugin_sources',
        'list_tvbox_sources',
      ]) {
        expect(data.calls[command], before[command]! + 1, reason: command);
      }
      expect(page.dirty, isFalse);
      await tester.pump();
      expect(tester.widget<ListView>(find.byType(ListView)), same(list));

      UiPrefs.setDanmakuEndpoint('https://changed.invalid/danmaku');
      await key.currentState!.loadAll();
      expect(page.dirty, isTrue);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('https://changed.invalid/danmaku'),
        findsOneWidget,
      );

      data.providers = [
        ...data.providers,
        {'id': 'b', 'name': '源乙'},
      ];
      data.markers = [
        {'key': 'a:1', 'provider': 'a', 'native_id': '1'},
      ];
      await key.currentState!.loadAll();
      expect(page.dirty, isTrue);
      await tester.pumpAndSettle();
      expect(find.textContaining('2 个内容源'), findsOneWidget);
      final currentList = tester.widget<ListView>(find.byType(ListView));
      final markerEntry =
          (currentList.childrenDelegate as SliverChildListDelegate).children
              .whereType<SettingsEntryRow>()
              .where((entry) => entry.title == '片头片尾')
              .single;
      expect(markerEntry.subtitle, '1 个作品已设置 · 查看 / 管理');

      data.remote = {
        'running': true,
        'url': 'http://192.0.2.1:8642',
        'pin': '123456',
        'reachable': true,
      };
      data.autoStart = true;
      await key.currentState!.loadAll();
      expect(page.dirty, isTrue);
      await tester.pumpAndSettle();
      expect(find.text('123456'), findsOneWidget);
      data.remote = {...data.remote, 'pin': '654321', 'fixedPin': '778899'};
      await key.currentState!.loadAll();
      await tester.pumpAndSettle();
      expect(find.text('654321'), findsOneWidget);
      expect(find.textContaining('固定码：778899'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'settings finishes first failure and preserves content on retry',
    (tester) async {
      final data = _SettingsData()..failProviders = true;
      SourinCore.debugCallAsyncTransport = data.call;
      final key = GlobalKey<SettingsPageState>();
      await tester.pumpWidget(_host(SettingsPage(key: key)));
      await tester.pumpAndSettle();
      expect(find.byType(AppLoading), findsNothing);
      expect(find.textContaining('加载失败：'), findsOneWidget);
      final page = tester.element(find.byType(SettingsPage));
      final list = tester.widget<ListView>(find.byType(ListView));
      final retry = key.currentState!.loadAll();
      expect(page.dirty, isFalse);
      await retry;
      expect(page.dirty, isFalse);
      await tester.pump();
      expect(tester.widget<ListView>(find.byType(ListView)), same(list));
      expect(find.byType(AppLoading), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('settings secondary route receives data without parent rebuild', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1100);
    addTearDown(tester.view.reset);
    final data = _SettingsData();
    SourinCore.debugCallAsyncTransport = data.call;
    SourinApi.debugTvboxConfigSiteTotalFetcher = () async => 1;
    final key = GlobalKey<SettingsPageState>();
    await tester.pumpWidget(_host(SettingsPage(key: key)));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('源'));
    await tester.tap(find.text('源'));
    await tester.pumpAndSettle();
    final page = key.currentContext! as Element;
    data.failures = [
      ['changed-plugin.js', '新的加载错误'],
    ];
    await key.currentState!.loadAll();
    expect(page.dirty, isFalse);
    await tester.pumpAndSettle();
    expect(find.textContaining('changed-plugin.js'), findsOneWidget);
    expect(find.textContaining('新的加载错误'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'search focus feedback stays local while input and submission still work',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      SourinCore.debugCallAsyncTransport = (command, _) async {
        if (command == 'list_providers') {
          return [
            {'id': 'focus-source', 'name': '搜索源', 'enabled': true},
          ];
        }
        throw StateError(command);
      };
      SearchPageState.debugAggChannelNamesFetcher = () async => {};
      final submitted = <String>[];
      SearchPageState.debugSearchStreamRunner = (keyword, onEvent) async {
        submitted.add(keyword);
        onEvent(_hit('focus-source', 'focus-source:1', '搜索结果'));
      };
      await tester.pumpWidget(_host(const SearchPage()));
      await tester.pumpAndSettle();
      final page = tester.element(find.byType(SearchPage));
      final editable = tester.widget<EditableText>(find.byType(EditableText));
      final focus = editable.focusNode;
      final field = find.byType(miuix.MiuixTextField);
      expect(tester.widget<miuix.MiuixTextField>(field).focusNode, same(focus));

      double borderWidth() {
        final decoration =
            tester
                    .widget<DecoratedBox>(
                      find
                          .descendant(
                            of: field,
                            matching: find.byWidgetPredicate(
                              (widget) =>
                                  widget is DecoratedBox &&
                                  widget.decoration is ShapeDecoration &&
                                  (widget.decoration as ShapeDecoration).shape
                                      is miuix.MiuixSquircleBorder,
                            ),
                          )
                          .first,
                    )
                    .decoration
                as ShapeDecoration;
        return (decoration.shape as miuix.MiuixSquircleBorder).side.width;
      }

      expect(focus.hasFocus, isTrue);
      expect(borderWidth(), greaterThan(0));
      focus.unfocus();
      await tester.idle();
      expect(focus.hasFocus, isFalse);
      expect(page.dirty, isFalse);
      await tester.pumpAndSettle();
      expect(borderWidth(), 0);

      focus.requestFocus();
      await tester.idle();
      expect(focus.hasFocus, isTrue);
      expect(page.dirty, isFalse);
      await tester.pumpAndSettle();
      expect(borderWidth(), greaterThan(0));

      await tester.enterText(find.byType(EditableText), '测试输入');
      await tester.pumpAndSettle();
      expect(editable.controller.text, '测试输入');
      expect(
        tester.widget<ui.FilledButton>(find.byType(ui.FilledButton)).onPressed,
        isNotNull,
      );
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(submitted, ['测试输入']);
      expect(find.text('搜索结果'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('search metadata stays fresh without redundant name rebuilds', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    final names = Completer<Map<String, String>>();
    var providerId = 'tvbox_agg';
    SourinCore.debugCallAsyncTransport = (command, _) async {
      if (command == 'list_providers') {
        return [
          {'id': providerId, 'name': '搜索源', 'enabled': true},
        ];
      }
      throw StateError(command);
    };
    SearchPageState.debugAggChannelNamesFetcher = () => names.future;
    final key = GlobalKey<SearchPageState>();
    await tester.pumpWidget(_host(SearchPage(key: key)));
    await tester.pumpAndSettle();
    final page = tester.element(find.byType(SearchPage));
    names.complete({'child': '新子源名称'});
    await tester.idle();
    expect(page.dirty, isFalse);
    key.currentState!.debugBeginSearch('结果');
    key.currentState!.debugFeedHit(
      _hit('tvbox_agg', 'tvbox_agg:child::1', '结果'),
    );
    key.currentState!.debugEndSearch();
    await tester.pumpAndSettle();
    expect(find.text('结果'), findsOneWidget);
    expect(find.textContaining('新子源名称'), findsWidgets);

    providerId = 'replacement';
    await key.currentState!.providersChanged();
    await tester.pumpAndSettle();
    expect(find.text('结果'), findsNothing);
    key.currentState!.debugBeginSearch('新结果');
    key.currentState!.debugFeedHit(
      _hit('tvbox_agg', 'tvbox_agg:child::2', '旧源结果'),
    );
    key.currentState!.debugFeedHit(_hit('replacement', 'replacement:2', '新结果'));
    key.currentState!.debugEndSearch();
    await tester.pumpAndSettle();
    expect(find.text('旧源结果'), findsNothing);
    expect(find.text('新结果'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'empty search metadata avoids rebuilding and never starts stream',
    (tester) async {
      final providers = Completer<dynamic>();
      SourinCore.debugCallAsyncTransport = (command, _) {
        if (command == 'list_providers') return providers.future;
        throw StateError(command);
      };
      SearchPageState.debugAggChannelNamesFetcher = () async => {};
      var searches = 0;
      SearchPageState.debugSearchStreamRunner = (_, __) async {
        searches++;
      };
      await tester.pumpWidget(_host(const SearchPage()));
      await tester.pumpAndSettle();
      final page = tester.element(find.byType(SearchPage));
      providers.complete(<dynamic>[]);
      await tester.idle();
      expect(page.dirty, isFalse);
      await tester.enterText(find.byType(EditableText), '测试');
      await tester.pump();
      await tester.tap(find.byType(ui.FilledButton));
      await tester.pumpAndSettle();
      expect(searches, 0);
      expect(find.text('当前没有支持搜索的内容源'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
