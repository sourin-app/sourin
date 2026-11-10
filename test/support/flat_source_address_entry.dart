import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

import 'miuix_finders.dart';

/// Exercises the replacement for the retired aggregate-page route. A matching
/// label is insufficient: the visible row must edit its own persisted origin.
Future<void> exerciseFlatSourceAddressEntry(
  WidgetTester tester, {
  required bool filtered,
}) async {
  UiPrefs.debugResetForTest();
  Device.overrideKind(DeviceKind.desktop);
  ProxyCache.invalidate();
  SourceDiscoveryService.current.value = null;
  var notifications = 0;
  final commands = <String>[];
  final writes = <Map<String, dynamic>>[];
  final origins = <Map<String, dynamic>>[
    {
      'id': 'first',
      'name': '订阅甲',
      'kind': 'tvbox',
      'primaryUrl': 'https://first.invalid/main.json',
      'backupUrls': ['https://first.invalid/backup.json'],
      'providerIds': ['first-child'],
    },
    {
      'id': 'second',
      'name': '订阅乙',
      'kind': 'tvbox',
      'primaryUrl': 'https://second.invalid/main.json',
      'backupUrls': <String>[],
      'providerIds': ['second-child'],
    },
  ];
  Map<String, dynamic> catalog() => {'origins': origins, 'groups': <dynamic>[]};
  SourinCore.debugCallAsyncTransport = (command, args) async {
    commands.add(command);
    switch (command) {
      case 'list_providers':
        return [
          for (final id in ['first-child', 'second-child'])
            {
              'id': id,
              'name': '同名子源',
              'kind': 'tvbox',
              'enabled': id == 'second-child',
              'capabilities': {'vod': true, 'search': true},
            },
          {'id': 'local-js', 'name': '本地脚本', 'kind': 'js'},
          {'id': 'tvbox_agg', 'name': '历史聚合入口', 'kind': 'tvbox'},
          {'id': 'retired', 'name': '历史声明式源', 'kind': 'declarative'},
        ];
      case 'source_catalog_get':
        return catalog();
      case 'source_catalog_set_origin':
        final update = args!;
        writes.add({...update});
        origins.firstWhere((o) => o['id'] == update['id']).addAll(update);
        return catalog();
      case 'list_tvbox_sources':
        return {'sources': <dynamic>[]};
      case 'list_plugins':
        return {'plugins': <dynamic>[], 'failed': <dynamic>[]};
      case 'global_proxy_migration_choices':
      case 'list_skip_markers':
      case 'restore_failures':
        return <dynamic>[];
      case 'remote_auto_start':
        return false;
      case 'remote_status_cmd':
      case 'list_plugin_sources':
      case 'list_proxy_configs':
      case 'source_discovery_status':
      case 'tvbox_update_schedule_get':
        return <String, dynamic>{};
      default:
        throw StateError('Unexpected native command: $command');
    }
  };
  addTearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    Device.overrideKind(null);
    ProxyCache.invalidate();
    SourceDiscoveryService.current.value = null;
    UiPrefs.debugResetForTest();
  });
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1100);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: AppScaffold(
        child: SettingsPage(onProvidersChanged: () => notifications++),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('源'));
  await tester.tap(find.text('源'));
  await tester.pumpAndSettle();
  expect(find.byType(SourceManagerPage), findsOneWidget);
  expect(find.byType(TvboxAggregatePage), findsNothing);
  for (final id in ['tvbox_agg', 'retired']) {
    expect(find.byKey(ValueKey('managed-source-$id')), findsNothing);
  }
  Finder row(String id) => find.byKey(ValueKey('managed-source-$id'));
  expect(row('first-child'), findsOneWidget);
  expect(row('second-child'), findsOneWidget);
  if (filtered) {
    await tester.tap(find.byKey(const ValueKey('source-type-tvbox')));
    await tester.pumpAndSettle();
    expect(row('local-js'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-origin-option-first')));
    await tester.pumpAndSettle();
    expect(row('second-child'), findsNothing);
    await tester.enterText(
      find.descendant(
        of: find.byKey(const ValueKey('source-manager-search')),
        matching: find.byType(EditableText),
      ),
      '同名',
    );
    await tester.pumpAndSettle();
  }
  expect(
    tester
        .widget<ui.Switch>(
          find.byKey(const ValueKey('source-enabled-first-child')),
        )
        .value,
    isFalse,
    reason: 'A disabled child must retain its address entry.',
  );
  Future<void> openAddress() async {
    await tester.tap(
      find.descendant(
        of: row('first-child'),
        matching: find.text('地址 · 1 个备用'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(SourceAddressDialog), findsOneWidget);
    expect(
      tester
          .widget<SourceAddressDialog>(find.byType(SourceAddressDialog))
          .origin
          .id,
      'first',
    );
    expect(find.byType(TvboxAggregatePage), findsNothing);
  }

  Finder field(String key) => find.descendant(
    of: find.byKey(ValueKey(key)),
    matching: find.byType(EditableText),
  );
  await openAddress();
  expect(
    tester
        .widget<EditableText>(field('source-address-primary'))
        .controller
        .text,
    'https://first.invalid/main.json',
  );
  await tester.enterText(
    field('source-address-primary'),
    'https://cancelled.invalid/main.json',
  );
  await tester.tap(
    find.descendant(
      of: find.byType(SourceAddressDialog),
      matching: miuixTooltip('关闭'),
    ),
  );
  await tester.pumpAndSettle();
  expect(writes, isEmpty);
  expect(notifications, 0);
  await openAddress();
  expect(
    tester
        .widget<EditableText>(field('source-address-primary'))
        .controller
        .text,
    'https://first.invalid/main.json',
  );
  await tester.enterText(field('source-address-name'), '订阅甲新名称');
  await tester.enterText(
    field('source-address-primary'),
    'https://first.invalid/new-main.json',
  );
  await tester.enterText(
    field('source-address-backups'),
    'https://first.invalid/backup-two.json\nhttps://first.invalid/backup-one.json',
  );
  await tester.tap(find.text('保存'));
  await tester.pumpAndSettle();
  expect(writes, [
    {
      'id': 'first',
      'name': '订阅甲新名称',
      'primaryUrl': 'https://first.invalid/new-main.json',
      'backupUrls': [
        'https://first.invalid/backup-two.json',
        'https://first.invalid/backup-one.json',
      ],
    },
  ]);
  expect(notifications, 1);
  expect(find.byType(SourceAddressDialog), findsNothing);
  expect(find.text('来自 订阅甲新名称'), findsOneWidget);
  expect(origins[1]['primaryUrl'], 'https://second.invalid/main.json');
  expect(commands, isNot(contains('tvbox_aggregate_get')));
  expect(commands, isNot(contains('tvbox_aggregate_set')));
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}
