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
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

void main() {
  testWidgets(
    'settings opens flat sources and persists manual provider selection to empty',
    (tester) async {
      UiPrefs.debugResetForTest();
      Device.overrideKind(DeviceKind.desktop);
      ProxyCache.invalidate();
      SourceDiscoveryService.current.value = null;
      const firstId = 'tvbox-subscription-a-common';
      const secondId = 'tvbox-subscription-b-common';
      const unrelatedId = 'tvbox-subscription-c-other';
      const groupId = 'common-upstream';
      var selected = <String>[firstId, secondId];
      final saves = <Map<String, dynamic>>[];
      final commands = <String>[];
      var providersChanged = 0;

      Map<String, dynamic> catalog() => {
        'origins': [
          {
            'id': 'subscription-a',
            'name': '订阅甲',
            'kind': 'tvbox',
            'primaryUrl': 'https://first.invalid/config.json',
            'providerIds': [firstId],
          },
          {
            'id': 'subscription-b',
            'name': '订阅乙',
            'kind': 'tvbox',
            'primaryUrl': 'https://second.invalid/config.json',
            'providerIds': [secondId],
          },
          {
            'id': 'subscription-c',
            'name': '其它订阅',
            'kind': 'tvbox',
            'primaryUrl': 'https://other.invalid/config.json',
            'providerIds': [unrelatedId],
          },
        ],
        'groups': [
          {
            'id': groupId,
            'name': '同名子源',
            'providerIds': [firstId, secondId],
            'selectedProviderIds': List<String>.of(selected),
          },
        ],
      };

      SourinCore.debugCallAsyncTransport = (command, args) async {
        commands.add(command);
        switch (command) {
          case 'list_providers':
            return [
              for (final id in [firstId, secondId])
                {
                  'id': id,
                  'name': '同名子源',
                  'kind': 'tvbox',
                  'enabled': selected.contains(id),
                  'capabilities': {'vod': true, 'home': true, 'search': true},
                },
              {
                'id': unrelatedId,
                'name': '其它子源',
                'kind': 'tvbox',
                'enabled': true,
                'capabilities': {'vod': true, 'search': true},
              },
              {'id': 'local-js', 'name': '本地脚本', 'kind': 'js'},
              {'id': 'tvbox_agg', 'name': '旧聚合独立入口', 'kind': 'tvbox'},
            ];
          case 'source_catalog_get':
            return catalog();
          case 'source_catalog_select_providers':
            selected = List<String>.from(args!['providerIds'] as List);
            saves.add({
              'groupId': args['groupId'],
              'providerIds': List<String>.of(selected),
            });
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
            child: SettingsPage(onProvidersChanged: () => providersChanged++),
          ),
        ),
      );
      await tester.pumpAndSettle();

      Finder row(String id) => find.byKey(ValueKey('managed-source-$id'));
      Finder choice(String id) =>
          find.byKey(ValueKey('source-provider-choice-$id'));
      bool enabled(String id) => tester
          .widget<ui.Switch>(find.byKey(ValueKey('source-enabled-$id')))
          .value;

      Future<void> openSources() async {
        await tester.ensureVisible(find.text('源'));
        await tester.tap(find.text('源'));
        await tester.pumpAndSettle();
        expect(find.byType(SourceManagerPage), findsOneWidget);
        expect(
          find.byKey(const ValueKey('source-settings-tabs')),
          findsNothing,
        );
        expect(find.byType(TvboxAggregatePage), findsNothing);
        expect(row('tvbox_agg'), findsNothing);
        expect(find.text('旧聚合独立入口'), findsNothing);
      }

      Future<void> filterFirstOrigin() async {
        await tester.tap(find.byKey(const ValueKey('source-type-tvbox')));
        await tester.pumpAndSettle();
        expect(row('local-js'), findsNothing);
        await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
        await tester.pumpAndSettle();
        await tester.tap(
          find.byKey(const ValueKey('source-origin-option-subscription-a')),
        );
        await tester.pumpAndSettle();
        expect(row(firstId), findsOneWidget);
        expect(row(secondId), findsNothing);
        expect(row(unrelatedId), findsNothing);
        expect(find.text('来自 订阅甲'), findsOneWidget);
      }

      Future<void> openProviders(int count) async {
        final button = find.descendant(
          of: row(firstId),
          matching: find.text('提供方 $count/2'),
        );
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(find.byType(SourceProvidersDialog), findsOneWidget);
        expect(choice(firstId), findsOneWidget);
        expect(choice(secondId), findsOneWidget);
        expect(choice(unrelatedId), findsNothing);
        expect(find.byType(TvboxAggregatePage), findsNothing);
      }

      await openSources();
      expect(row(firstId), findsOneWidget);
      expect(row(secondId), findsOneWidget);
      await filterFirstOrigin();
      expect(enabled(firstId), isTrue);
      await openProviders(2);
      await tester.tap(choice(firstId));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saves, [
        {
          'groupId': groupId,
          'providerIds': [secondId],
        },
      ]);
      expect(providersChanged, 1);
      expect(enabled(firstId), isFalse);

      await openProviders(1);
      expect(
        tester.widget<miuix.MiuixSwitchPreference>(choice(firstId)).value,
        isFalse,
      );
      expect(
        tester.widget<miuix.MiuixSwitchPreference>(choice(secondId)).value,
        isTrue,
      );
      await tester.tap(choice(secondId));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(saves, [
        {
          'groupId': groupId,
          'providerIds': [secondId],
        },
        {'groupId': groupId, 'providerIds': <String>[]},
      ]);
      expect(providersChanged, 2);
      expect(enabled(firstId), isFalse);

      await tester.tap(find.byKey(const ValueKey('page-header-back')));
      await tester.pumpAndSettle();
      expect(find.byType(SourceManagerPage), findsNothing);
      await openSources();
      expect(enabled(firstId), isFalse);
      expect(enabled(secondId), isFalse);
      expect(enabled(unrelatedId), isTrue);
      await filterFirstOrigin();
      await openProviders(0);
      for (final id in [firstId, secondId]) {
        expect(
          tester.widget<miuix.MiuixSwitchPreference>(choice(id)).value,
          isFalse,
        );
      }
      expect(commands, contains('source_catalog_get'));
      expect(commands, isNot(contains('tvbox_aggregate_get')));
      expect(commands, isNot(contains('tvbox_aggregate_set')));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );
}
