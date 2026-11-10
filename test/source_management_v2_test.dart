import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/source_address_fields.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/widgets/plugin_speedtest.dart';
import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';

import 'support/miuix_finders.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: child,
  );
}

Map<String, Object?> _provider(
  String id,
  String name,
  String kind, {
  bool enabled = true,
  bool live = false,
}) => {
  'id': id,
  'name': name,
  'kind': kind,
  'enabled': enabled,
  'capabilities': {'vod': !live, 'live': live, 'search': !live},
};

void main() {
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourceDiscoveryService.current.value = null;
  });

  test(
    'flat sources preserve provider identity and exclude retired entries',
    () {
      final providers = [
        const ProviderManifest(id: 'a', name: '同名源', kind: 'tvbox'),
        const ProviderManifest(id: 'b', name: '同名源', kind: 'tvbox'),
        const ProviderManifest(id: 'js', name: 'JS', kind: 'js'),
        const ProviderManifest(
          id: 'live',
          name: '直播',
          kind: 'm3u_live',
          capabilities: Capabilities(live: true),
        ),
        const ProviderManifest(id: 'tvbox_agg', name: '旧聚合入口'),
        const ProviderManifest(id: 'old', name: '声明式', kind: 'declarative'),
      ];
      expect(managedSourceList(providers).map((p) => p.id), [
        'a',
        'b',
        'js',
        'live',
      ]);
      expect(
        managedSourceList(providers, type: ManagedSourceType.js).single.id,
        'js',
      );
      expect(
        managedSourceList(providers, type: ManagedSourceType.live).single.id,
        'live',
      );
      expect(
        managedSourceList(
          providers,
          origin: const SourceOrigin(id: 'second', providerIds: ['b']),
        ).single.id,
        'b',
      );
      expect(
        sourceBackupUrls(
          ' https://a.test\n\nhttps://b.test\r\nhttps://a.test ',
        ),
        ['https://a.test', 'https://b.test'],
      );
    },
  );

  testWidgets(
    'normal source import exposes only TVBox and no retired declarative controls',
    (tester) async {
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: Builder(
              builder: (context) => ui.TextButton(
                onPressed: () => ProviderImportDialog.showAdd(context),
                child: const Text('打开源导入'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开源导入'));
      await tester.pumpAndSettle();
      expect(find.text('导入 TVBox 配置'), findsOneWidget);
      expect(find.text('TVBox 配置'), findsOneWidget);
      expect(find.text('导入并探测'), findsOneWidget);
      expect(find.textContaining('声明式'), findsNothing);
      expect(find.text('HTTP Provider'), findsNothing);
      expect(find.text('填入模板'), findsNothing);
      expect(find.text('可视化编排'), findsNothing);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderImportDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'provider multi-selection persists an explicit empty list and refreshes immediately',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(tester.view.reset);
      var selected = <String>['a', 'b'];
      var notifications = 0;
      var healthChecks = 0;
      final writes = <Map<String, dynamic>>[];
      Map<String, Object?> catalog() => {
        'origins': [
          {
            'id': 'first',
            'name': '订阅甲',
            'kind': 'tvbox',
            'primaryUrl': 'https://first.test/config',
            'providerIds': ['a'],
          },
          {
            'id': 'second',
            'name': '订阅乙',
            'kind': 'tvbox',
            'primaryUrl': 'https://second.test/config',
            'providerIds': ['b'],
          },
        ],
        'groups': [
          {
            'id': 'same-upstream',
            'name': '子源',
            'providerIds': ['a', 'b'],
            'selectedProviderIds': selected,
          },
        ],
      };
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'list_providers':
            return [
              _provider('a', '子源', 'tvbox', enabled: selected.contains('a')),
              _provider('b', '子源', 'tvbox', enabled: selected.contains('b')),
            ];
          case 'source_catalog_get':
            return catalog();
          case 'source_discovery_status':
            return <String, dynamic>{};
          case 'source_catalog_select_providers':
            writes.add({...args!});
            selected = (args['providerIds'] as List).cast<String>();
            return catalog();
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
            onHealthCheck: () async {
              healthChecks++;
            },
            onReload: () async {},
            subscriptionSettings: const Text('自动更新设置'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('managed-source-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('managed-source-b')), findsOneWidget);
      await tester.tap(find.text('提供方 2/2').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('全部关闭'));
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(writes.single['groupId'], 'same-upstream');
      expect(writes.single['providerIds'], isEmpty);
      expect(notifications, 1);
      expect(
        tester
            .widget<ui.Switch>(find.byKey(const ValueKey('source-enabled-a')))
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<ui.Switch>(find.byKey(const ValueKey('source-enabled-b')))
            .value,
        isFalse,
      );
      expect(find.text('提供方 0/2'), findsNWidgets(2));
      expect(
        tester
            .widget<PluginSpeedTestAllButton>(
              find.byType(PluginSpeedTestAllButton),
            )
            .pluginIds,
        isEmpty,
      );
      await tester.tap(miuixTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('重新加载 JS'), findsOneWidget);
      expect(find.text('订阅自动更新'), findsOneWidget);
      await tester.tap(find.text('健康检测'));
      await tester.pumpAndSettle();
      expect(healthChecks, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'flat sources show persisted GitHub provenance only for the installed provider identity',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(tester.view.reset);
      SourceDiscoveryService.current.value = null;
      final status = Completer<Map<String, dynamic>>();
      final calls = <String>[];
      Map<String, dynamic> snapshot({required bool installed}) => {
        'candidates': [
          {
            'id': 'verified',
            'name': '发现的原始名称',
            'providerId': 'imported-tvbox',
            'repository': 'fixture/verified-catalog',
            'installed': installed,
            'status': 'ready',
          },
          {
            'id': 'pending',
            'name': 'GitHub 名称',
            'repository': 'fixture/pending-catalog',
            'installed': false,
            'status': 'ready',
          },
        ],
      };
      SourinCore.debugCallAsyncTransport = (command, args) async {
        calls.add(command);
        switch (command) {
          case 'list_providers':
            return [
              _provider('imported-tvbox', '用户改过的名称', 'tvbox'),
              _provider('github-manual', 'GitHub 名称', 'tvbox'),
            ];
          case 'source_catalog_get':
            return {
              'origins': [
                {
                  'id': 'manual',
                  'name': 'GitHub 地址',
                  'kind': 'tvbox',
                  'primaryUrl': 'https://raw.githubusercontent.com/fixture/manual/main/source.json',
                  'providerIds': ['github-manual'],
                },
              ],
              'groups': <Object>[],
            };
          case 'source_discovery_status':
            return await status.future;
          case 'source_discovery_enable':
            expect(args!['id'], 'verified');
            return snapshot(installed: true);
          default:
            throw StateError(command);
        }
      };
      await tester.pumpWidget(
        _host(
          SourceManagerPage(
            onSourcesChanged: () {},
            onImportTvbox: () async {},
            onPasteJs: () async {},
            onEditProvider: (_) async {},
            onConfigureProvider: (_) async {},
            onRemoveProvider: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final verified = find.byKey(
        const ValueKey('source-github-origin-imported-tvbox'),
      );
      final manual = find.byKey(
        const ValueKey('source-github-origin-github-manual'),
      );
      expect(find.text('用户改过的名称'), findsOneWidget);
      expect(verified, findsNothing);
      expect(manual, findsNothing);

      status.complete(snapshot(installed: true));
      await tester.pumpAndSettle();
      expect(verified, findsOneWidget);
      expect(find.text('来自 GitHub · fixture/verified-catalog'), findsOneWidget);
      expect(manual, findsNothing);
      expect(
        calls.where((call) => call == 'source_discovery_status').length,
        1,
      );
      expect(calls, isNot(contains('source_discovery_scan')));

      SourceDiscoveryService.current.value = DiscoverySnapshot(
        snapshot(installed: false),
      );
      await tester.pumpAndSettle();
      expect(verified, findsNothing);
      await SourceDiscoveryService.enable('verified');
      await tester.pumpAndSettle();
      expect(verified, findsOneWidget);
      expect(manual, findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'status filtering intersects type, origin and search and follows enable changes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(tester.view.reset);
      var bEnabled = false;
      var notifications = 0;
      final writes = <Map<String, dynamic>>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'list_providers':
            return [
              _provider('a', '子源甲', 'tvbox'),
              _provider('b', '子源乙', 'tvbox', enabled: bEnabled),
              _provider('c', '脚本源', 'js', enabled: false),
            ];
          case 'source_catalog_get':
            return {
              'origins': [
                {
                  'id': 'first',
                  'name': '订阅甲',
                  'kind': 'tvbox',
                  'primaryUrl': 'https://first.test/config',
                  'providerIds': ['a', 'b'],
                },
                {
                  'id': 'second',
                  'name': '订阅乙',
                  'kind': 'js',
                  'providerIds': ['c'],
                },
              ],
              'groups': <Object>[],
            };
          case 'set_provider_enabled':
            writes.add({...args!});
            bEnabled = args['enabled'] as bool;
            return true;
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
      final statusFilter = find.byKey(const ValueKey('source-status-filter'));
      expect(tester.widget(statusFilter), isA<miuix.MiuixWindowDropdownMenu>());
      expect(row('a'), findsOneWidget);
      expect(row('b'), findsOneWidget);
      expect(row('c'), findsOneWidget);

      Future<void> selectStatus(String label) async {
        await tester.tap(statusFilter);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await selectStatus('已停用');
      expect(row('a'), findsNothing);
      expect(row('b'), findsOneWidget);
      expect(row('c'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-type-tvbox')));
      await tester.pumpAndSettle();
      expect(row('b'), findsOneWidget);
      expect(row('c'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('source-origin-option-first')),
      );
      await tester.pumpAndSettle();

      final search = find.descendant(
        of: find.byKey(const ValueKey('source-manager-search')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(search, '子源甲');
      await tester.pumpAndSettle();
      expect(row('a'), findsNothing);
      expect(row('b'), findsNothing);
      expect(find.text('没有匹配的源'), findsOneWidget);
      await tester.enterText(search, '');
      await tester.pumpAndSettle();
      expect(row('b'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('source-enabled-b')));
      await tester.pumpAndSettle();
      expect(writes, [
        {'id': 'b', 'enabled': true},
      ]);
      expect(notifications, 1);
      expect(row('b'), findsNothing);
      expect(find.text('没有匹配的源'), findsOneWidget);

      await selectStatus('已启用');
      expect(row('a'), findsOneWidget);
      expect(row('b'), findsOneWidget);
      expect(row('c'), findsNothing);
      await selectStatus('全部');
      expect(row('a'), findsOneWidget);
      expect(row('b'), findsOneWidget);
      expect(row('c'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'local JS provenance stays local and JS/live origin addresses remain editable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1000);
      addTearDown(tester.view.reset);
      final origins = <Map<String, Object?>>[
        {
          'id': 'js-origin',
          'name': '同名脚本',
          'kind': 'js',
          'providerIds': ['local-js'],
        },
        {
          'id': 'live-origin',
          'name': '直播地址',
          'kind': 'live',
          'primaryUrl': 'https://live.test/main.m3u',
          'providerIds': ['live'],
        },
      ];
      Map<String, Object?> catalog() => {
        'origins': origins,
        'groups': <Object>[],
      };
      final writes = <Map<String, dynamic>>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'list_providers':
            return [
              _provider('local-js', '同名脚本', 'js'),
              _provider('fallback-js', '旧核心脚本', 'js'),
              _provider('live', '直播源', 'm3u_live', live: true),
            ];
          case 'source_catalog_get':
            return catalog();
          case 'source_catalog_set_origin':
            final update = args!;
            writes.add({...update});
            origins.firstWhere((o) => o['id'] == update['id']).addAll(update);
            return catalog();
          case 'source_discovery_status':
            return <String, dynamic>{};
          default:
            throw StateError(command);
        }
      };
      await tester.pumpWidget(
        _host(
          SourceManagerPage(
            onSourcesChanged: () {},
            onImportTvbox: () async {},
            onPasteJs: () async {},
            onEditProvider: (_) async {},
            onConfigureProvider: (_) async {},
            onRemoveProvider: (_) async {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('本地 JS'), findsNWidgets(2));
      expect(find.text('来自 同名脚本'), findsNothing);

      for (final (provider, origin) in [
        ('local-js', 'js-origin'),
        ('live', 'live-origin'),
      ]) {
        final row = find.byKey(ValueKey('managed-source-$provider'));
        await tester.tap(
          find.descendant(of: row, matching: find.text('主地址与备用地址')),
        );
        await tester.pumpAndSettle();
        final dialog = tester.widget<SourceAddressDialog>(
          find.byType(SourceAddressDialog),
        );
        expect(dialog.origin.id, origin);
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('source-address-primary')),
            matching: find.byType(EditableText),
          ),
          'https://$provider.test/main',
        );
        await tester.enterText(
          find.descendant(
            of: find.byKey(const ValueKey('source-address-backups')),
            matching: find.byType(EditableText),
          ),
          'https://$provider.test/backup',
        );
        await tester.tap(find.text('保存'));
        await tester.pumpAndSettle();
        expect(writes.last['id'], origin);
        expect(writes.last['primaryUrl'], 'https://$provider.test/main');
        expect(writes.last['backupUrls'], ['https://$provider.test/backup']);
      }
      expect(find.text('JS 源'), findsOneWidget);
      expect(find.text('本地 JS'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('source-origin-option-js-origin')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('source-origin-option-live-origin')),
        findsNothing,
      );
      await tester.tap(find.text('全部聚合来源').last);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'origin dropdown only searches TVBox subscriptions and returns the selected origin',
    (tester) async {
      String? selected;
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SearchableSourceOriginPicker(
                origins: const [
                  SourceOrigin(
                    id: 'a',
                    name: '订阅甲',
                    kind: 'tvbox',
                    primaryUrl: 'https://first.test/config',
                    providerIds: ['a'],
                  ),
                  SourceOrigin(
                    id: 'b',
                    name: '订阅乙',
                    kind: 'tvbox',
                    primaryUrl: 'https://second.test/config',
                    providerIds: [],
                  ),
                  SourceOrigin(
                    id: 'local-js',
                    name: '同名本地脚本',
                    kind: 'js',
                    providerIds: ['local-js'],
                  ),
                  SourceOrigin(
                    id: 'remote-js',
                    name: '远程脚本',
                    kind: 'js',
                    primaryUrl: 'https://js.test/plugin.js',
                  ),
                  SourceOrigin(
                    id: 'local-tvbox',
                    name: '本地TVBox',
                    kind: 'tvbox',
                  ),
                  SourceOrigin(
                    id: 'live',
                    name: '直播地址',
                    kind: 'live',
                    primaryUrl: 'https://live.test/list.m3u',
                  ),
                  SourceOrigin(
                    id: 'invalid',
                    name: '无效地址',
                    kind: 'tvbox',
                    primaryUrl: 'file:///local.json',
                  ),
                ],
                selected: null,
                onSelected: (id) => selected = id,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('source-origin-option-a')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('source-origin-option-b')),
        findsOneWidget,
      );
      for (final id in [
        'local-js',
        'remote-js',
        'local-tvbox',
        'live',
        'invalid',
      ]) {
        expect(find.byKey(ValueKey('source-origin-option-$id')), findsNothing);
      }
      await tester.enterText(find.byType(EditableText), '订阅乙');
      await tester.pumpAndSettle();
      expect(find.text('订阅甲'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('source-origin-option-b')));
      await tester.pumpAndSettle();
      expect(selected, 'b');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'shared address editor submits ordered fallbacks with its primary address',
    (tester) async {
      List<String>? savedBackups;
      String? savedPrimary;
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: Builder(
              builder: (context) => ui.TextButton(
                onPressed: () => showAppDialog<bool>(
                  context: context,
                  builder: (_) => SourceAddressDialog(
                    origin: const SourceOrigin(
                      id: 'tvbox',
                      name: '订阅甲',
                      primaryUrl: 'https://main.test',
                    ),
                    onSave: (_, primary, backups) async {
                      savedPrimary = primary;
                      savedBackups = backups;
                    },
                  ),
                ),
                child: const Text('编辑地址'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('编辑地址'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('source-address-backups')),
          matching: find.byType(EditableText),
        ),
        'https://backup-b.test\nhttps://backup-a.test\nhttps://backup-b.test',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(savedPrimary, 'https://main.test');
      expect(savedBackups, ['https://backup-b.test', 'https://backup-a.test']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'source sorting saves the visible provider ids and identifies each origin',
    (tester) async {
      List<String>? saved;
      var notifications = 0;
      SourinCore.debugCallAsyncTransport = (command, args) async {
        if (command != 'set_provider_order') throw StateError(command);
        saved = (args!['ids'] as List).cast<String>();
        return saved;
      };
      await tester.pumpWidget(
        _host(
          Scaffold(
            body: Builder(
              builder: (context) => ui.TextButton(
                onPressed: () => Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => SourceOrderPage(
                      providers: const [
                        ProviderManifest(id: 'a', name: '子源甲'),
                        ProviderManifest(id: 'b', name: '子源乙'),
                        ProviderManifest(
                          id: 'local-js',
                          name: '本地脚本',
                          kind: 'js',
                        ),
                      ],
                      origins: const [
                        SourceOrigin(
                          id: 'first',
                          name: '聚合甲',
                          kind: 'tvbox',
                          primaryUrl: 'https://first.test/config',
                          providerIds: ['a'],
                        ),
                        SourceOrigin(
                          id: 'second',
                          name: '聚合乙',
                          kind: 'tvbox',
                          primaryUrl: 'https://second.test/config',
                          providerIds: ['b'],
                        ),
                      ],
                      onSaved: () => notifications++,
                    ),
                  ),
                ),
                child: const Text('排序'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('排序'));
      await tester.pumpAndSettle();
      expect(find.text('来自 聚合甲'), findsOneWidget);
      expect(find.text('来自 聚合乙'), findsOneWidget);
      expect(find.text('本地 JS'), findsOneWidget);
      tester
          .widget<ReorderableListView>(find.byType(ReorderableListView))
          .onReorder!(0, 2);
      await tester.pump();
      await tester.tap(find.text('保存顺序'));
      await tester.pumpAndSettle();
      expect(saved, ['b', 'a', 'local-js']);
      expect(notifications, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'large catalog keeps row identity across scrolling, filtering and reload',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 900);
      addTearDown(tester.view.reset);
      final enabled = <String, bool>{};
      final writes = <Map<String, dynamic>>[];
      var notifications = 0;
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'list_providers':
            return List.generate(
              240,
              (i) => _provider(
                'large-$i',
                '源 ${i.toString().padLeft(3, '0')}',
                'tvbox',
                enabled: enabled['large-$i'] ?? true,
              ),
            );
          case 'source_catalog_get':
            return {
              'origins': List.generate(
                240,
                (i) => {
                  'id': 'origin-$i',
                  'name': '订阅 $i',
                  'kind': 'tvbox',
                  'primaryUrl': 'https://fixture.test/$i.json',
                  'providerIds': ['large-$i'],
                },
              ),
              'groups': <Object>[],
            };
          case 'source_discovery_status':
            return <String, dynamic>{};
          case 'set_provider_enabled':
            writes.add({...args!});
            enabled[args['id'] as String] = args['enabled'] as bool;
            return true;
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
      final list = find.byKey(const PageStorageKey('source-manager-list'));
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final last = find.byKey(const ValueKey('managed-source-large-239'));
      expect(
        find.byKey(const ValueKey('managed-source-large-0')),
        findsOneWidget,
      );
      expect(last, findsNothing);
      await tester.scrollUntilVisible(
        last,
        1200,
        scrollable: scrollable,
        maxScrolls: 40,
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: last, matching: find.text('来自 订阅 239')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('source-enabled-large-239')));
      await tester.pumpAndSettle();
      expect(writes, [
        {'id': 'large-239', 'enabled': false},
      ]);
      final search = find.descendant(
        of: find.byKey(const ValueKey('source-manager-search')),
        matching: find.byType(EditableText),
      );
      await tester.enterText(search, '源 000');
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('managed-source-large-0'));
      expect(first, findsOneWidget);
      expect(last, findsNothing);
      expect(
        find.descendant(of: first, matching: find.text('来自 订阅 0')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('source-enabled-large-0')));
      await tester.pumpAndSettle();
      expect(writes.last, {'id': 'large-0', 'enabled': false});
      expect(notifications, 2);
      await tester.enterText(search, '源 239');
      await tester.pumpAndSettle();
      expect(last, findsOneWidget);
      expect(
        find.descendant(of: last, matching: find.text('来自 订阅 239')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
