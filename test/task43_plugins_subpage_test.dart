// Source management is a separate route. Exercise the retained settings owner
// through its real entry/menu instead of matching retired _PluginsPage text.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/settings_sub_page.dart';

import 'support/miuix_finders.dart';

class _Data {
  final calls = <String>[];
  List<List<String>> failures = [];
  List<Map<String, dynamic>> providers = [
    {'id': 'js-a', 'name': '测试插件甲', 'kind': 'js', 'enabled': true},
  ];
  Completer<int>? pendingReload;
  bool failReload = false;
  Completer<bool>? pendingEnabled;
  Completer<List<String>>? pendingOrder;
  Completer<bool>? pendingProviders;
  Completer<void>? pendingAddress;
  final addressWrites = <Map<String, dynamic>>[];
  String address = 'https://source.invalid/catalog';

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    calls.add(command);
    switch (command) {
      case 'list_providers':
        return providers;
      case 'list_plugins':
        return {'plugins': <dynamic>[], 'failed': failures};
      case 'reload_plugins':
        if (failReload) throw StateError('fixture reload failure');
        return pendingReload?.future ?? 2;
      case 'set_provider_enabled':
        final result = await (pendingEnabled?.future ?? Future.value(true));
        if (result) {
          providers = [
            for (final p in providers)
              p['id'] == args!['id'] ? {...p, 'enabled': args['enabled']} : p,
          ];
        }
        return result;
      case 'set_provider_order':
        return pendingOrder?.future ?? providers.map((p) => p['id']).toList();
      case 'source_catalog_select_providers':
        final saved = await pendingProviders!.future;
        if (saved) {
          final selected = (args!['providerIds'] as List).cast<String>();
          providers = [
            for (final p in providers)
              {...p, 'enabled': selected.contains(p['id'])},
          ];
        }
        return _catalog();
      case 'source_catalog_set_origin':
      case 'install_plugin':
      case 'import_live_source':
        addressWrites.add({'command': command, ...args!});
        await pendingAddress!.future;
        if (command == 'source_catalog_set_origin') {
          address = args['primaryUrl'] as String;
          return _catalog();
        }
        return {'id': 'new-source', 'name': '新源', 'kind': 'js'};
      case 'remote_status_cmd':
        return {'running': false};
      case 'remote_auto_start':
        return false;
      case 'list_skip_markers':
      case 'restore_failures':
      case 'global_proxy_migration_choices':
        return <dynamic>[];
      case 'list_tvbox_sources':
        return {'sources': <dynamic>[]};
      case 'list_plugin_sources':
      case 'list_proxy_configs':
      case 'source_discovery_status':
      case 'tvbox_update_schedule_get':
        return <String, dynamic>{};
      case 'source_catalog_get':
        return _catalog();
      default:
        throw StateError('Unexpected command: $command');
    }
  }

  Map<String, dynamic> _catalog() =>
      pendingProviders == null && pendingAddress == null
      ? <String, dynamic>{}
      : {
          'origins': [
            {
              'id': 'subscription',
              'name': '测试订阅',
              'kind': 'tvbox',
              'primaryUrl': address,
              'providerIds': providers.map((p) => p['id']).toList(),
            },
          ],
          'groups': [
            if (pendingProviders != null)
              {
                'id': 'shared',
                'name': '测试子源',
                'providerIds': providers.map((p) => p['id']).toList(),
                'selectedProviderIds': providers
                    .where((p) => p['enabled'] == true)
                    .map((p) => p['id'])
                    .toList(),
              },
          ],
        };
}

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

Future<void> _mount(
  WidgetTester tester,
  _Data data,
  GlobalKey<SettingsPageState> key, {
  VoidCallback? onChanged,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1100);
  addTearDown(tester.view.reset);
  SourinCore.debugCallAsyncTransport = data.call;
  await tester.pumpWidget(
    _host(SettingsPage(key: key, onProvidersChanged: onChanged)),
  );
  await tester.pumpAndSettle();
}

Future<void> _openSources(WidgetTester tester) async {
  await tester.ensureVisible(find.text('源'));
  await tester.tap(find.text('源'));
  await tester.pumpAndSettle();
  expect(find.byType(SourceManagerPage), findsOneWidget);
}

Future<void> _reload(WidgetTester tester) async {
  await tester.tap(miuixTooltip('更多操作'));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  await tester.tap(find.text('重新加载 JS'));
  // Inspect the message before its normal auto-dismiss deadline.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

void main() {
  setUp(() {
    Device.overrideKind(DeviceKind.desktop);
    UiPrefs.debugResetForTest();
    SourceDiscoveryService.current.value = null;
    ProxyCache.invalidate();
  });
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourinApi.debugTvboxConfigSiteTotalFetcher = null;
    Device.overrideKind(null);
    UiPrefs.debugResetForTest();
    SourceDiscoveryService.current.value = null;
    ProxyCache.invalidate();
  });

  testWidgets(
    'source entry stays below remote and opens the full management route',
    (tester) async {
      final data = _Data();
      await _mount(tester, data, GlobalKey<SettingsPageState>());
      expect(find.text('局域网遥控'), findsOneWidget);
      expect(find.text('源'), findsOneWidget);
      expect(
        tester.getTopLeft(find.text('局域网遥控')).dy,
        lessThan(tester.getTopLeft(find.text('源')).dy),
      );
      expect(find.text('测试插件甲'), findsNothing);
      await _openSources(tester);
      expect(find.byType(SettingsSubPage), findsOneWidget);
      expect(find.byKey(const ValueKey('managed-source-js-a')), findsOneWidget);
      expect(find.text('测试插件甲'), findsOneWidget);
      await tester.tap(miuixTooltip('更多操作'));
      await tester.pumpAndSettle();
      for (final label in ['重新加载 JS', '健康检测', '粘贴 JS 源码', '订阅自动更新', '识别网盘链接']) {
        expect(find.text(label), findsOneWidget);
      }
      expect(data.calls.where((c) => c == 'reload_plugins'), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'host data refresh reaches source activity without rebuilding hidden settings',
    (tester) async {
      final data = _Data();
      final key = GlobalKey<SettingsPageState>();
      await _mount(tester, data, key);
      await _openSources(tester);
      final host = key.currentContext! as Element;
      data.failures = [
        ['new-plugin.js', '新增加载错误'],
      ];
      await key.currentState!.loadAll();
      expect(host.dirty, isFalse);
      await tester.pumpAndSettle();
      expect(find.textContaining('new-plugin.js'), findsOneWidget);
      expect(find.textContaining('新增加载错误'), findsOneWidget);
      data.failures = [];
      await key.currentState!.loadAll();
      await tester.pumpAndSettle();
      expect(find.textContaining('new-plugin.js'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'reload refreshes source rows and exposes its toast above the active route',
    (tester) async {
      final data = _Data();
      var changes = 0;
      await _mount(
        tester,
        data,
        GlobalKey<SettingsPageState>(),
        onChanged: () => changes++,
      );
      await _openSources(tester);
      data.providers = [
        {'id': 'js-b', 'name': '测试插件乙', 'kind': 'js', 'enabled': true},
      ];
      data.failures = [
        ['failed-plugin.js', '插件文件错误'],
      ];
      await _reload(tester);
      expect(data.calls.where((c) => c == 'reload_plugins'), hasLength(1));
      expect(changes, 1);
      expect(find.byKey(const ValueKey('managed-source-js-a')), findsNothing);
      expect(find.byKey(const ValueKey('managed-source-js-b')), findsOneWidget);
      expect(find.textContaining('failed-plugin.js'), findsOneWidget);
      expect(find.text('已重新加载 2 个插件'), findsOneWidget);
      final toast = tester.getRect(find.text('已重新加载 2 个插件'));
      expect(
        const Rect.fromLTWH(0, 0, 1280, 1100).contains(toast.center),
        isTrue,
      );
      expect(find.byType(SourceManagerPage), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('failed reload reports an error and allows a successful retry', (
    tester,
  ) async {
    final data = _Data()..failReload = true;
    var changes = 0;
    await _mount(
      tester,
      data,
      GlobalKey<SettingsPageState>(),
      onChanged: () => changes++,
    );
    await _openSources(tester);
    await _reload(tester);
    expect(find.textContaining('重新加载失败：'), findsOneWidget);
    expect(find.text('测试插件甲'), findsOneWidget);
    expect(changes, 0);
    data.failReload = false;
    await _reload(tester);
    expect(find.text('已重新加载 2 个插件'), findsOneWidget);
    expect(data.calls.where((c) => c == 'reload_plugins'), hasLength(2));
    expect(changes, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  for (final back in ['header', 'escape', 'remote']) {
    testWidgets(
      'source route returns through $back without losing the settings owner',
      (tester) async {
        final key = GlobalKey<SettingsPageState>();
        await _mount(tester, _Data(), key);
        final state = key.currentState;
        await _openSources(tester);
        if (back == 'header') {
          await tester.tap(find.byKey(const ValueKey('page-header-back')));
        } else {
          await tester.sendKeyEvent(
            back == 'escape'
                ? LogicalKeyboardKey.escape
                : LogicalKeyboardKey.goBack,
            physicalKey: PhysicalKeyboardKey.escape,
          );
        }
        await tester.pumpAndSettle();
        expect(find.byType(SourceManagerPage), findsNothing);
        expect(key.currentState, same(state));
        expect(find.text('源'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }

  testWidgets(
    'pending reload blocks duplicate work and completes after only the route closes',
    (tester) async {
      final data = _Data()..pendingReload = Completer<int>();
      var changes = 0;
      final key = GlobalKey<SettingsPageState>();
      await _mount(tester, data, key, onChanged: () => changes++);
      await _openSources(tester);
      await _reload(tester);
      await _reload(tester);
      expect(data.calls.where((c) => c == 'reload_plugins'), hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.byKey(const ValueKey('page-header-back')));
      await tester.pumpAndSettle();
      expect(find.byType(SourceManagerPage), findsNothing);
      expect(key.currentState, isNotNull);
      data.pendingReload!.complete(3);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(changes, 1);
      expect(find.text('已重新加载 3 个插件'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'pending source reload can finish after route and owner disposal',
    (tester) async {
      final data = _Data()..pendingReload = Completer<int>();
      var changes = 0;
      await _mount(
        tester,
        data,
        GlobalKey<SettingsPageState>(),
        onChanged: () => changes++,
      );
      await _openSources(tester);
      await _reload(tester);
      expect(data.calls.where((c) => c == 'reload_plugins'), hasLength(1));
      await tester.pumpWidget(const SizedBox());
      final callsAtDispose = data.calls.length;
      data.pendingReload!.complete(2);
      await tester.pumpAndSettle();
      expect(
        changes,
        0,
        reason: 'A disposed settings owner cannot notify its former shell',
      );
      expect(
        data.calls.length,
        callsAtDispose,
        reason: 'No reload may start after owner disposal',
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final action in ['toggle', 'order']) {
    for (final disposeOwner in [false, true]) {
      testWidgets(
        'pending $action save respects owner lifetime (dispose=$disposeOwner)',
        (tester) async {
          final data = _Data()
            ..pendingEnabled = Completer<bool>()
            ..pendingOrder = Completer<List<String>>();
          var changes = 0;
          final key = GlobalKey<SettingsPageState>();
          await _mount(tester, data, key, onChanged: () => changes++);
          await _openSources(tester);
          if (action == 'toggle') {
            await tester.tap(find.byKey(const ValueKey('source-enabled-js-a')));
          } else {
            await tester.tap(find.text('调整顺序'));
            await tester.pumpAndSettle();
            expect(find.byType(SourceOrderPage), findsOneWidget);
            await tester.tap(find.text('保存顺序'));
          }
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          final command = action == 'toggle'
              ? 'set_provider_enabled'
              : 'set_provider_order';
          expect(data.calls.where((c) => c == command), hasLength(1));
          expect(changes, 0);
          if (disposeOwner) {
            await tester.pumpWidget(const SizedBox());
          } else {
            final pages = action == 'order' ? 2 : 1;
            for (var i = 0; i < pages; i++) {
              await tester.tap(find.byKey(const ValueKey('page-header-back')));
              await tester.pumpAndSettle();
            }
            expect(find.byType(SourceManagerPage), findsNothing);
            expect(key.currentState, isNotNull);
          }
          final callsBeforeReply = data.calls.length;
          if (action == 'toggle') {
            data.pendingEnabled!.complete(true);
          } else {
            data.pendingOrder!.complete(['js-a']);
          }
          await tester.pumpAndSettle();
          expect(changes, disposeOwner ? 0 : 1);
          if (disposeOwner) {
            expect(
              data.calls.length,
              callsBeforeReply,
              reason: 'A removed owner cannot start a new data refresh',
            );
          } else {
            expect(
              data.calls.skip(callsBeforeReply),
              contains('list_providers'),
            );
            await _openSources(tester);
            expect(
              find.byKey(const ValueKey('managed-source-js-a')),
              findsOneWidget,
            );
            if (action == 'toggle') {
              expect(
                tester
                    .widget<ui.Switch>(
                      find.byKey(const ValueKey('source-enabled-js-a')),
                    )
                    .value,
                isFalse,
              );
            }
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
        },
      );
    }
  }

  for (final disposeOwner in [false, true]) {
    for (final fails in [false, true]) {
      testWidgets(
        'pending provider selection completes after route removal (dispose=$disposeOwner, fails=$fails)',
        (tester) async {
          final data = _Data()
            ..pendingProviders = Completer<bool>()
            ..providers = [
              {'id': 'a', 'name': '同名子源', 'kind': 'tvbox', 'enabled': true},
              {'id': 'b', 'name': '同名子源', 'kind': 'tvbox', 'enabled': true},
            ];
          var changes = 0;
          final key = GlobalKey<SettingsPageState>();
          await _mount(tester, data, key, onChanged: () => changes++);
          await _openSources(tester);
          await tester.tap(find.text('提供方 2/2').first);
          await tester.pumpAndSettle();
          await tester.tap(
            find.byKey(const ValueKey('source-provider-choice-a')),
          );
          await tester.pumpAndSettle();
          await tester.tap(find.text('保存'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.text('正在保存…'), findsOneWidget);
          expect(
            data.calls.where((c) => c == 'source_catalog_select_providers'),
            hasLength(1),
          );
          if (disposeOwner) {
            await tester.pumpWidget(const SizedBox());
          } else {
            // An app-level route removal can bypass ordinary user dismissal.
            // Remove both child routes while retaining the settings owner.
            Navigator.of(tester.element(find.byType(SourceProvidersDialog)))
                .popUntil((route) => route.isFirst);
            await tester.pumpAndSettle();
            expect(find.byType(SourceManagerPage), findsNothing);
            expect(find.byType(SourceProvidersDialog), findsNothing);
            expect(key.currentState, isNotNull);
          }
          final callsBeforeReply = data.calls.length;
          if (fails) {
            data.pendingProviders!.completeError(
              SourinCoreException('保存未完成', 'network'),
            );
          } else {
            data.pendingProviders!.complete(true);
          }
          await tester.pumpAndSettle();
          expect(changes, !disposeOwner && !fails ? 1 : 0);
          if (disposeOwner || fails) {
            expect(data.calls.length, callsBeforeReply);
          } else {
            expect(
              data.calls.skip(callsBeforeReply),
              contains('list_providers'),
            );
            await _openSources(tester);
            expect(
              tester
                  .widget<ui.Switch>(
                    find.byKey(const ValueKey('source-enabled-a')),
                  )
                  .value,
              isFalse,
            );
            expect(
              tester
                  .widget<ui.Switch>(
                    find.byKey(const ValueKey('source-enabled-b')),
                  )
                  .value,
              isTrue,
            );
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await tester.pumpAndSettle();
        },
      );
    }
  }

  for (final action in ['address', 'js', 'live']) {
    for (final removal in ['dialog', 'children', 'owner', 'none']) {
      for (final fails in [false, true]) {
        testWidgets(
          'pending $action address save notifies only after persistence (remove=$removal, fails=$fails)',
          (tester) async {
            final data = _Data()..pendingAddress = Completer<void>();
            var changes = 0;
            final key = GlobalKey<SettingsPageState>();
            await _mount(tester, data, key, onChanged: () => changes++);
            await _openSources(tester);
            if (action == 'address') {
              await tester.tap(find.text('主地址与备用地址'));
            } else {
              await tester.tap(find.text(action == 'js' ? '安装 JS' : '添加直播'));
            }
            await tester.pumpAndSettle();
            expect(find.byType(SourceAddressDialog), findsOneWidget);
            final primary = find.descendant(
              of: find.byKey(const ValueKey('source-address-primary')),
              matching: find.byType(EditableText),
            );
            await tester.enterText(primary, 'https://new.invalid/main');
            await tester.enterText(
              find.descendant(
                of: find.byKey(const ValueKey('source-address-backups')),
                matching: find.byType(EditableText),
              ),
              'https://new.invalid/backup',
            );
            await tester.tap(find.text('保存'));
            await tester.pump();
            await tester.pump(const Duration(milliseconds: 400));
            final command = switch (action) {
              'address' => 'source_catalog_set_origin',
              'js' => 'install_plugin',
              _ => 'import_live_source',
            };
            expect(data.addressWrites, [
              {
                'command': command,
                if (action == 'address') 'id': 'subscription',
                'name': action == 'address' ? '测试订阅' : '',
                if (action == 'address')
                  'primaryUrl': 'https://new.invalid/main',
                if (action != 'address') 'url': 'https://new.invalid/main',
                'backupUrls': ['https://new.invalid/backup'],
              },
            ]);
            expect(changes, 0);
            if (removal == 'owner') {
              await tester.pumpWidget(const SizedBox());
            } else if (removal != 'none') {
              final navigator = Navigator.of(
                tester.element(find.byType(SourceAddressDialog)),
              );
              if (removal == 'dialog') {
                navigator.pop();
              } else {
                navigator.popUntil((route) => route.isFirst);
              }
              await tester.pumpAndSettle();
              expect(find.byType(SourceAddressDialog), findsNothing);
            }
            final callsBeforeReply = data.calls.length;
            if (fails) {
              data.pendingAddress!.completeError(
                SourinCoreException('保存未完成', 'network'),
              );
            } else {
              data.pendingAddress!.complete();
            }
            await tester.pumpAndSettle();
            expect(changes, removal != 'owner' && !fails ? 1 : 0);
            if (removal == 'owner' || (fails && removal != 'none')) {
              expect(data.calls.length, callsBeforeReply);
            }
            if (fails && removal == 'none') {
              expect(find.byType(SourceAddressDialog), findsOneWidget);
              expect(find.text('保存未完成'), findsOneWidget);
              expect(
                tester.widget<EditableText>(primary).controller.text,
                'https://new.invalid/main',
              );
            } else if (removal != 'owner') {
              expect(find.byType(SourceAddressDialog), findsNothing);
            }
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox());
            await tester.pumpAndSettle();
          },
        );
      }
    }
  }
}
