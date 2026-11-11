import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';

import 'support/miuix_finders.dart';

Map<String, dynamic> _catalog({String aLiveUrl = 'https://live.test/a.m3u'}) =>
    {
      'origins': [
        {
          'id': 'parent-a',
          'name': '订阅甲',
          'kind': 'tvbox',
          'primaryUrl': 'https://parent.test/a.json',
          'providerIds': ['a-vod'],
          'relatedProviderIds': ['a-live'],
        },
        {
          'id': 'parent-b',
          'name': '订阅乙',
          'kind': 'tvbox',
          'primaryUrl': 'https://parent.test/b.json',
          'providerIds': ['b-vod'],
          'relatedProviderIds': ['b-live'],
        },
        {
          'id': 'live-a',
          'name': '甲直播',
          'kind': 'live',
          'primaryUrl': aLiveUrl,
          'backupUrls': ['https://backup.test/a.m3u'],
          'providerIds': ['a-live'],
        },
        {
          'id': 'live-b',
          'name': '乙直播',
          'kind': 'live',
          'primaryUrl': 'https://live.test/b.m3u',
          'providerIds': ['b-live'],
        },
        {
          'id': 'live-standalone',
          'name': '独立直播',
          'kind': 'live',
          'primaryUrl': 'https://live.test/standalone.m3u',
          'providerIds': ['standalone'],
        },
      ],
      'groups': <Object>[],
    };

const _providers = [
  ProviderManifest(id: 'a-vod', name: '甲点播', kind: 'tvbox'),
  ProviderManifest(id: 'b-vod', name: '乙点播', kind: 'tvbox'),
  ProviderManifest(
    id: 'a-live',
    name: '甲直播',
    kind: 'm3u_live',
    capabilities: Capabilities(live: true),
  ),
  ProviderManifest(
    id: 'b-live',
    name: '乙直播',
    kind: 'm3u_live',
    capabilities: Capabilities(live: true),
    enabled: false,
  ),
  ProviderManifest(
    id: 'standalone',
    name: '独立直播',
    kind: 'm3u_live',
    capabilities: Capabilities(live: true),
  ),
];

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: child,
  );
}

void main() {
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourceDiscoveryService.current.value = null;
  });

  testWidgets(
    'TVBox origin filters its VOD and live children while live address editor owns the playlist',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1500);
      addTearDown(tester.view.reset);
      final writes = <Map<String, dynamic>>[];
      var url = 'https://live.test/a.m3u';
      var notifications = 0;
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'list_providers':
            return [
              for (final p in _providers)
                {
                  'id': p.id,
                  'name': p.name,
                  'kind': p.kind,
                  'enabled': p.enabled,
                  'capabilities': {
                    'vod': !p.capabilities.live,
                    'live': p.capabilities.live,
                  },
                },
            ];
          case 'source_catalog_get':
            return _catalog(aLiveUrl: url);
          case 'source_catalog_set_origin':
            writes.add({...args!});
            url = args['primaryUrl'] as String;
            return _catalog(aLiveUrl: url);
          case 'source_discovery_status':
            return <String, dynamic>{};
          default:
            throw StateError(command);
        }
      };
      await tester.pumpWidget(
        _host(
          SourceManagerPage(
            onSourcesChanged: () => notifications++,
            onImportTvbox: () async {},
            onPasteJs: () async {},
            onEditProvider: (_) async {},
            onConfigureProvider: (_) async {},
            onRemoveProvider: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder row(String id) => find.byKey(ValueKey('managed-source-$id'));
      expect(row('standalone'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('source-origin-option-parent-a')),
      );
      await tester.pumpAndSettle();
      expect(row('a-vod'), findsOneWidget);
      expect(
        row('a-live'),
        findsOneWidget,
        reason: 'The parent filter must include live descendants without making the JSON URL their address',
      );
      expect(row('b-vod'), findsNothing);
      expect(row('b-live'), findsNothing);
      expect(row('standalone'), findsNothing);
      expect(find.text('订阅甲 · 2 个源'), findsOneWidget);
      expect(
        find.descendant(of: row('a-live'), matching: find.text('来自 订阅甲')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('source-type-live')));
      await tester.pumpAndSettle();
      expect(row('a-vod'), findsNothing);
      expect(row('a-live'), findsOneWidget);
      await tester.tap(
        find.descendant(of: row('a-live'), matching: find.text('地址 · 1 个备用')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is EditableText &&
              w.controller.text == 'https://live.test/a.m3u',
        ),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is EditableText &&
              w.controller.text == 'https://parent.test/a.json',
        ),
        findsNothing,
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SourceAddressDialog),
          matching: miuixTooltip('关闭'),
        ),
      );
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      await tester.tap(
        find.descendant(of: row('a-live'), matching: find.text('地址 · 1 个备用')),
      );
      await tester.pumpAndSettle();
      final field = find.byWidgetPredicate(
        (w) =>
            w is EditableText && w.controller.text == 'https://live.test/a.m3u',
      );
      await tester.enterText(field, 'https://updated.test/a.m3u');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();
      expect(writes.single['id'], 'live-a');
      expect(writes.single['primaryUrl'], 'https://updated.test/a.m3u');
      expect(writes.single['backupUrls'], ['https://backup.test/a.m3u']);
      expect(notifications, 1);
      expect(
        find.descendant(of: row('a-live'), matching: find.text('来自 订阅甲')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('source-origin-option-parent-b')),
      );
      await tester.pumpAndSettle();
      expect(row('a-live'), findsNothing);
      expect(row('b-live'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source ordering describes TVBox live parents and keeps standalone playlist identity',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1000, 1400);
      addTearDown(tester.view.reset);
      final origins = SourceCatalog.fromJson(_catalog()).origins;
      await tester.pumpWidget(
        _host(
          SourceOrderPage(
            providers: _providers,
            origins: origins,
            onSaved: () {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      Finder row(String id) => find.byKey(ValueKey(id));
      expect(
        find.descendant(of: row('a-live'), matching: find.text('来自 订阅甲')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('b-live'), matching: find.text('来自 订阅乙 · 已关闭')),
        findsOneWidget,
      );
      expect(
        find.descendant(of: row('standalone'), matching: find.text('直播订阅')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('source-order-up-a-live')));
      await tester.pumpAndSettle();
      expect(
        tester.getTopLeft(row('a-live')).dy,
        lessThan(tester.getTopLeft(row('b-vod')).dy),
      );
      expect(
        find.descendant(of: row('a-live'), matching: find.text('来自 订阅甲')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  test('legacy origin JSON retains existing owner filtering and local descriptions', () {
    final legacy = SourceOrigin.fromJson({
      'id': 'legacy',
      'kind': 'tvbox',
      'primaryUrl': 'https://legacy.test/config',
      'providerIds': ['a-vod'],
    });
    expect(managedSourceList(_providers, origin: legacy).map((p) => p.id), [
      'a-vod',
    ]);
    expect(sourceOriginDescription(legacy, _providers.first), '来自 TVBox 订阅');
    expect(sourceOriginDescription(null, _providers.last), '本地直播');
  });
}
