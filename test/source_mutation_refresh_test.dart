import 'dart:async';

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
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/plugin_edit_dialog.dart';
import 'package:sourin_spike/ui/widgets/plugin_speedtest.dart';
import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';

import 'support/miuix_finders.dart';

class _Sources {
  int notifications = 0;
  bool failWrite = false;
  bool rejectWrite = false;
  bool enabled = true;
  bool removed = false;
  bool holdReload = false;
  final reload = Completer<void>();
  final writes = <String>[];
  final unexpected = <String>[];

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    switch (command) {
      case 'list_providers':
        if (holdReload) await reload.future;
        return [
          if (!removed)
            {
              'id': 'remote',
              'name': '远程子源',
              'kind': 'tvbox',
              'enabled': enabled,
              'capabilities': {'vod': true, 'search': true},
            },
          {
            'id': 'local-js',
            'name': '本地脚本',
            'kind': 'js',
            'enabled': true,
            'capabilities': {'vod': true, 'search': true},
          },
        ];
      case 'source_catalog_get':
        return {'origins': <dynamic>[], 'groups': <dynamic>[]};
      case 'list_plugins':
        return {
          'plugins': [
            {
              'id': 'local-js',
              'name': '本地脚本',
              'file': 'local.js',
              'loaded': true,
            },
          ],
          'failed': <dynamic>[],
        };
      case 'list_tvbox_sources':
        return {'sources': <dynamic>[]};
      case 'global_proxy_migration_choices':
      case 'list_skip_markers':
      case 'restore_failures':
      case 'get_categories':
        return <dynamic>[];
      case 'remote_auto_start':
        return false;
      case 'remote_status_cmd':
      case 'list_plugin_sources':
      case 'list_proxy_configs':
      case 'source_discovery_status':
      case 'tvbox_update_schedule_get':
        return <String, dynamic>{};
      case 'read_plugin':
        return 'export default {}';
      case 'set_provider_order':
      case 'import_tvbox_config':
      case 'reload_plugins':
      case 'install_plugin':
      case 'install_plugin_source':
      case 'save_plugin_source':
      case 'remove_provider':
      case 'remove_plugin':
      case 'set_provider_enabled':
        writes.add(command);
        if (failWrite) throw StateError('保存失败');
        if (rejectWrite) return false;
        holdReload = true;
        if (command == 'set_provider_enabled') {
          enabled = args!['enabled'] as bool;
        }
        if (command == 'remove_provider') removed = true;
        return switch (command) {
          'set_provider_order' => args!['ids'],
          'import_tvbox_config' => {
            'totalSites': 1,
            'imported': [
              {'id': 'remote', 'name': '远程子源', 'api': 'https://source.invalid'},
            ],
          },
          'install_plugin' ||
          'install_plugin_source' => {'id': 'local-js', 'name': '本地脚本'},
          'reload_plugins' || 'save_plugin_source' => 1,
          _ => true,
        };
      default:
        unexpected.add(command);
        throw StateError('Unexpected native command: $command');
    }
  }
}

Future<_Sources> _open(WidgetTester tester) async {
  UiPrefs.debugResetForTest();
  Device.overrideKind(DeviceKind.desktop);
  ProxyCache.invalidate();
  SourceDiscoveryService.current.value = null;
  final sources = _Sources();
  SourinCore.debugCallAsyncTransport = sources.call;
  addTearDown(() {
    if (!sources.reload.isCompleted) sources.reload.complete();
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
        child: SettingsPage(onProvidersChanged: () => sources.notifications++),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('源'));
  await tester.tap(find.text('源'));
  await tester.pumpAndSettle();
  expect(find.byType(SourceManagerPage), findsOneWidget);
  expect(sources.notifications, 0);
  return sources;
}

Future<void> _menu(WidgetTester tester, String item) async {
  await tester.tap(miuixTooltip('更多操作'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(item));
  await tester.pumpAndSettle();
}

Future<void> _remove(WidgetTester tester, {String id = 'remote'}) async {
  final menu = find.descendant(
    of: find.byKey(ValueKey('managed-source-$id')),
    matching: miuixTooltip('源操作'),
  );
  await tester.tap(menu);
  await tester.pumpAndSettle();
  await tester.tap(find.text('移除源'));
  await tester.pumpAndSettle();
}

Future<void> _close(WidgetTester tester, _Sources sources) async {
  if (!sources.reload.isCompleted) sources.reload.complete();
  await tester.pumpAndSettle();
  expect(sources.unexpected, isEmpty);
  expect(tester.takeException(), isNull);
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('cancel and read-only source actions never invalidate content', (
    tester,
  ) async {
    final sources = await _open(tester);
    await tester.tap(find.text('导入 TVBox'));
    await tester.pumpAndSettle();
    expect(find.byType(ProviderImportDialog), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sources.notifications, 0, reason: 'empty import cancellation');

    await _menu(tester, '粘贴 JS 源码');
    expect(find.byType(PluginEditDialogBody), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sources.notifications, 0, reason: 'paste cancellation');

    await tester.tap(find.text('编辑 JS'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sources.notifications, 0, reason: 'edit cancellation');

    await _remove(tester);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(sources.notifications, 0, reason: 'remove cancellation');

    await _menu(tester, '健康检测');
    expect(
      sources.notifications,
      0,
      reason: 'health results are not source configuration',
    );
    expect(sources.writes, isEmpty);
    await tester.tap(find.text('调整顺序'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('按速度排序'));
    await tester.pumpAndSettle();
    expect(
      sources.notifications,
      0,
      reason: 'no speed results means no persisted order',
    );
    expect(sources.writes, isEmpty);
    await _close(tester, sources);
  });

  for (final action in [
    'speed',
    'reload',
    'install',
    'install-link',
    'edit',
    'edit-link',
    'remove',
    'remove-js',
    'toggle',
    'tvbox',
  ]) {
    for (final fails in [false, true]) {
      testWidgets(
        '$action ${fails ? 'failure does not invalidate' : 'invalidates once before metadata reload'}',
        (tester) async {
          final sources = await _open(tester);
          sources.failWrite = fails;
          if (action == 'speed') {
            PluginSpeedTest.append(
              'local-js',
              PluginSpeedRun(ts: DateTime(2026), ok: true, mbPerSec: 2),
            );
            await tester.tap(find.text('调整顺序'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('按速度排序'));
          } else if (action == 'reload') {
            // Do not settle here: a successful action intentionally waits on reload.
            await tester.tap(miuixTooltip('更多操作'));
            await tester.pumpAndSettle();
            await tester.tap(find.text('重新加载 JS'));
          } else if (action.startsWith('install') ||
              action.startsWith('edit')) {
            if (action.startsWith('install')) {
              await _menu(tester, '粘贴 JS 源码');
            } else {
              await tester.tap(find.text('编辑 JS'));
              await tester.pumpAndSettle();
            }
            await tester.enterText(
              find.descendant(
                of: find.byType(PluginEditDialogBody),
                matching: find.byType(EditableText),
              ),
              action.endsWith('-link')
                  ? 'https://source.invalid/plugin.js'
                  : 'export default {name: "changed"}',
            );
            await tester.tap(
              find.text(action.startsWith('install') ? '安装' : '保存'),
            );
          } else if (action.startsWith('remove')) {
            await _remove(
              tester,
              id: action == 'remove-js' ? 'local-js' : 'remote',
            );
            await tester.tap(find.text('确定'));
          } else if (action == 'tvbox') {
            await tester.tap(find.text('导入 TVBox'));
            await tester.pumpAndSettle();
            await tester.enterText(
              find.byKey(const ValueKey('source-address-primary')),
              'https://configuration.invalid/tvbox.json',
            );
            await tester.pump();
            await tester.tap(find.text('导入并探测'));
            await tester.pumpAndSettle();
            expect(sources.notifications, 0);
            // TVBox closes with ProviderImportCancelled(done: ...) after a
            // successful import; an empty cancellation must remain distinct.
            await tester.tap(find.text(fails ? '取消' : '完成'));
          } else {
            await tester.tap(
              find.byKey(const ValueKey('source-enabled-remote')),
            );
          }
          for (var frame = 0; frame < 6; frame++) {
            await tester.pump(const Duration(milliseconds: 100));
          }
          expect(sources.writes, hasLength(1));
          expect(
            sources.notifications,
            fails ? 0 : 1,
            reason: 'saved configuration must invalidate while metadata is still waiting',
          );
          sources.reload.complete();
          await tester.pumpAndSettle();
          expect(
            sources.notifications,
            fails ? 0 : 1,
            reason: 'no second notification from source manager',
          );
          await _close(tester, sources);
        },
      );
    }
  }

  testWidgets('backend rejected toggle never announces a saved configuration', (
    tester,
  ) async {
    final sources = await _open(tester);
    sources.rejectWrite = true;
    await tester.tap(find.byKey(const ValueKey('source-enabled-remote')));
    await tester.pumpAndSettle();
    expect(sources.writes, ['set_provider_enabled']);
    expect(sources.notifications, 0);
    await _close(tester, sources);
  });
}
