import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/global_proxy_settings_page.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart';
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

import 'support/miuix_finders.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(ProxyCache.reset);
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    ProxyCache.reset();
  });

  test(
    'global config and credentials override legacy provider settings',
    () async {
      final configs = <String, dynamic>{
        SourinApi.globalProxyProvider: {
          'mode': 'custom',
          'url': 'http://global.invalid:7890',
          'scope': 'all',
        },
        'fixture': {'mode': 'custom', 'url': 'http://legacy.invalid:8080'},
      };
      final credentialProviders = <String>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'global_proxy_migration_choices':
            return <dynamic>[];
          case 'list_proxy_configs':
            return configs;
          case 'has_proxy_password':
            credentialProviders.add(args!['provider'] as String);
            return {'has': args['provider'] == SourinApi.globalProxyProvider};
          case 'set_proxy_config':
            configs[args!['provider'] as String] = args['config'];
            return null;
          default:
            fail('Unexpected core command: $command');
        }
      };

      final configured = await SourinApi.proxyConfigWithPassword('fixture');
      expect(configured.url, 'http://global.invalid:7890');
      expect(configured.scope, ProxyScope.all);
      expect(configured.hasPassword, isTrue);
      expect(credentialProviders, [SourinApi.globalProxyProvider]);
      expect(
        (await SourinApi.proxyConfigFor('new-provider')).url,
        'http://global.invalid:7890',
      );

      await SourinApi.setProxyConfig(
        SourinApi.globalProxyProvider,
        const ProxyConfig(mode: ProxyMode.direct),
      );
      expect(
        (await SourinApi.proxyConfigFor('fixture')).mode,
        ProxyMode.direct,
      );
      expect(
        (await SourinApi.proxyConfigFor('new-provider')).mode,
        ProxyMode.direct,
      );
    },
  );

  test(
    'legacy settings remain readable until a global config exists',
    () async {
      SourinCore.debugCallAsyncTransport = (command, args) async {
        expect(command, 'list_proxy_configs');
        return {
          'fixture': {'mode': 'custom', 'url': 'http://legacy.invalid:8080'},
        };
      };
      expect(
        (await SourinApi.proxyConfigFor('fixture')).url,
        'http://legacy.invalid:8080',
      );
      expect(
        (await SourinApi.proxyConfigFor('unconfigured')).mode,
        ProxyMode.direct,
      );
    },
  );

  testWidgets(
    'global settings save one shared config and separate credentials',
    (tester) async {
      final configWrites = <Map<String, dynamic>>[];
      final passwordWrites = <Map<String, dynamic>>[];
      final tests = <String>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'global_proxy_migration_choices':
            return <dynamic>[];
          case 'list_proxy_configs':
            return {
              SourinApi.globalProxyProvider: {
                'mode': 'custom',
                'url': 'http://old-proxy.invalid:7890',
                'scope': 'api_only',
              },
            };
          case 'has_proxy_password':
            expect(args!['provider'], SourinApi.globalProxyProvider);
            return {'has': false};
          case 'system_proxy_hint':
            return {'hint': null};
          case 'set_proxy_config':
            configWrites.add(Map<String, dynamic>.from(args!));
            return null;
          case 'set_proxy_password':
            passwordWrites.add(Map<String, dynamic>.from(args!));
            return null;
          case 'test_proxy':
            tests.add(args!['provider'] as String);
            return {'ok': true, 'message': 'Synthetic proxy connected'};
          default:
            fail('Unexpected core command: $command');
        }
      };
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1100);
      addTearDown(tester.view.reset);
      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: const GlobalProxySettingsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('全局代理'), findsOneWidget);
      expect(find.byType(ProxyPanel), findsOneWidget);
      expect(
        tester.widget<ProxyPanel>(find.byType(ProxyPanel)).providerId,
        SourinApi.globalProxyProvider,
      );
      expect(find.byType(miuix.MiuixTextField), findsNWidgets(4));
      final fields = find.byType(EditableText);
      expect(fields, findsNWidgets(4));
      expect(
        tester.widget<EditableText>(fields.at(0)).controller.text,
        'http://old-proxy.invalid:7890',
      );
      await tester.enterText(fields.at(0), 'http://new-proxy.invalid:8080');
      await tester.enterText(fields.at(1), 'fixture-user');
      await tester.enterText(fields.at(2), 'fixture-password');
      await tester.enterText(fields.at(3), 'localhost, example.invalid');
      await tester.tap(find.text('全部流量'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(configWrites.last, {
        'provider': SourinApi.globalProxyProvider,
        'config': {
          'mode': 'custom',
          'url': 'http://new-proxy.invalid:8080',
          'scope': 'all',
          'username': 'fixture-user',
          'bypass': ['localhost', 'example.invalid'],
        },
      });
      expect(passwordWrites, isEmpty);
      await tester.tap(miuixTooltip('保存密码到系统钥匙串'));
      await tester.pumpAndSettle();
      expect(passwordWrites, [
        {
          'provider': SourinApi.globalProxyProvider,
          'password': 'fixture-password',
        },
      ]);
      expect(
        tester.widget<EditableText>(fields.at(2)).controller.text,
        isEmpty,
      );
      await tester.tap(find.text('测试连接'));
      await tester.pumpAndSettle();
      expect(tests, [SourinApi.globalProxyProvider]);
      expect(find.text('Synthetic proxy connected'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('system proxy exposes and saves the same traffic scope', (
    tester,
  ) async {
    final writes = <Map<String, dynamic>>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      switch (command) {
        case 'global_proxy_migration_choices':
          return <dynamic>[];
        case 'list_proxy_configs':
          return {
            SourinApi.globalProxyProvider: {
              'mode': 'system',
              'scope': 'api_only',
            },
          };
        case 'has_proxy_password':
          return {'has': false};
        case 'system_proxy_hint':
          return {'hint': 'http://system-proxy.invalid:7890'};
        case 'set_proxy_config':
          writes.add(Map<String, dynamic>.from(args!));
          return null;
        default:
          fail('Unexpected core command: $command');
      }
    };
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1100);
    addTearDown(tester.view.reset);
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: const GlobalProxySettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixTextField), findsNothing);
    expect(find.text('作用范围'), findsOneWidget);
    expect(find.text('仅接口'), findsOneWidget);
    await tester.tap(find.text('全部流量'));
    await tester.pumpAndSettle();
    expect(writes, [
      {
        'provider': SourinApi.globalProxyProvider,
        'config': {'mode': 'system', 'scope': 'all'},
      },
    ]);
    await tester.tap(find.text('直连'));
    await tester.pumpAndSettle();
    expect(find.text('作用范围'), findsNothing);
    await tester.tap(find.text('跟随系统'));
    await tester.pumpAndSettle();
    expect(find.text('作用范围'), findsOneWidget);
    expect(writes.last['config'], {'mode': 'system', 'scope': 'all'});
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'choosing a legacy proxy reloads the shared panel with that address',
    (tester) async {
      final selectedConfig = <String, dynamic>{
        'mode': 'custom',
        'url': 'http://discovery-proxy.invalid:8080',
        'scope': 'api_only',
      };
      final choices = [
        {
          'source': '弹幕',
          'config': {
            'mode': 'custom',
            'url': 'http://danmaku-proxy.invalid:7890',
            'scope': 'api_only',
          },
        },
        {'source': '源发现', 'config': selectedConfig},
      ];
      var currentConfig = <String, dynamic>{
        'mode': 'direct',
        'scope': 'api_only',
      };
      final writes = <Map<String, dynamic>>[];
      var reads = 0;
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'global_proxy_migration_choices':
            return choices;
          case 'list_proxy_configs':
            reads++;
            return {SourinApi.globalProxyProvider: currentConfig};
          case 'has_proxy_password':
            return {'has': false};
          case 'system_proxy_hint':
            return {'hint': null};
          case 'set_proxy_config':
            writes.add(Map<String, dynamic>.from(args!));
            currentConfig = Map<String, dynamic>.from(args['config'] as Map);
            return null;
          default:
            fail('Unexpected core command: $command');
        }
      };
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1100);
      addTearDown(tester.view.reset);
      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: const GlobalProxySettingsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择沿用的代理'), findsOneWidget);
      expect(find.byType(miuix.MiuixTextField), findsNothing);
      expect(writes, isEmpty);
      await tester.tap(find.text('源发现 · http://discovery-proxy.invalid:8080'));
      await tester.pumpAndSettle();
      expect(writes, [
        {'provider': SourinApi.globalProxyProvider, 'config': selectedConfig},
      ]);
      expect(reads, 2);
      expect(find.text('选择沿用的代理'), findsNothing);
      expect(find.byType(ProxyPanel), findsOneWidget);
      expect(
        tester.widget<ProxyPanel>(find.byType(ProxyPanel)).providerId,
        SourinApi.globalProxyProvider,
      );
      expect(
        tester
            .widget<EditableText>(find.byType(EditableText).first)
            .controller
            .text,
        'http://discovery-proxy.invalid:8080',
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'manual proxy saving clears migration choices only after success',
    (tester) async {
      final choices = [
        {
          'source': '弹幕',
          'config': {
            'mode': 'custom',
            'url': 'http://danmaku-proxy.invalid:7890',
          },
        },
        {
          'source': '源发现',
          'config': {
            'mode': 'custom',
            'url': 'http://discovery-proxy.invalid:8080',
          },
        },
      ];
      final saved = <Map<String, dynamic>>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'global_proxy_migration_choices':
            return choices;
          case 'list_proxy_configs':
            return <String, dynamic>{};
          case 'has_proxy_password':
            return {'has': false};
          case 'system_proxy_hint':
            return {'hint': null};
          case 'set_proxy_config':
            final config = Map<String, dynamic>.from(args!['config'] as Map);
            if (config['url'] == null) {
              throw StateError('Synthetic proxy address required');
            }
            saved.add(Map<String, dynamic>.from(args));
            return null;
          default:
            fail('Unexpected core command: $command');
        }
      };
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1100);
      addTearDown(tester.view.reset);
      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: const GlobalProxySettingsPage(),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('选择沿用的代理'), findsOneWidget);
      await tester.tap(find.text('自定义'));
      await tester.pumpAndSettle();
      expect(saved, isEmpty);
      expect(find.text('选择沿用的代理'), findsOneWidget);
      expect(find.textContaining('保存代理失败'), findsOneWidget);
      final urlField = find.byType(EditableText).first;
      await tester.enterText(urlField, 'http://new-proxy.invalid:8888');
      await tester.ensureVisible(find.text('保存设置'));
      await tester.tap(find.text('保存设置'));
      await tester.pumpAndSettle();
      expect(saved, [
        {
          'provider': SourinApi.globalProxyProvider,
          'config': {
            'mode': 'custom',
            'url': 'http://new-proxy.invalid:8888',
            'scope': 'api_only',
          },
        },
      ]);
      expect(find.text('选择沿用的代理'), findsNothing);
      expect(find.textContaining('保存代理失败'), findsNothing);
      expect(
        tester.widget<EditableText>(urlField).controller.text,
        'http://new-proxy.invalid:8888',
      );
      expect(ProxyCache.configFetches, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('clearing proxy removes a failed draft and notifies its parent', (
    tester,
  ) async {
    var saved = 0;
    var cleared = 0;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      switch (command) {
        case 'list_proxy_configs':
          return <String, dynamic>{};
        case 'has_proxy_password':
          return {'has': false};
        case 'system_proxy_hint':
          return {'hint': null};
        case 'set_proxy_config':
          throw StateError('Synthetic invalid proxy');
        case 'clear_proxy_config':
          cleared++;
          return null;
        default:
          fail('Unexpected command: $command');
      }
    };
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 1100);
    addTearDown(tester.view.reset);
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: Scaffold(
          body: ProxyPanel(
            providerId: SourinApi.globalProxyProvider,
            providerName: '全局代理',
            defaultOpen: true,
            onSaved: () => saved++,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('自定义'));
    await tester.pumpAndSettle();
    expect(find.textContaining('保存代理失败'), findsOneWidget);
    await tester.tap(find.text('清除代理'));
    await tester.pumpAndSettle();
    expect(cleared, 1);
    expect(saved, 1);
    expect(find.textContaining('保存代理失败'), findsNothing);
    for (final editor in tester.widgetList<EditableText>(
      find.byType(EditableText),
    )) {
      expect(editor.controller.text, isEmpty);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'aggregate credentials open the shared proxy page without another address form',
    (tester) async {
      final calls = <String>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        calls.add(command);
        switch (command) {
          case 'global_proxy_migration_choices':
            return <dynamic>[];
          case 'list_providers':
            return <dynamic>[];
          case 'list_proxy_configs':
            return {
              SourinApi.globalProxyProvider: {
                'mode': 'custom',
                'url': 'http://global-proxy.invalid:7890',
                'scope': 'api_only',
              },
            };
          case 'has_proxy_password':
            expect(args!['provider'], SourinApi.globalProxyProvider);
            return {'has': false};
          case 'system_proxy_hint':
            return {'hint': null};
          default:
            fail('Unexpected core command: $command');
        }
      };
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1100);
      addTearDown(tester.view.reset);
      final theme = AppTheme.themeFor(Brightness.light);
      await tester.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: TvboxAggregateCredentialsSection(aggregateId: 'tvbox_agg'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ProxyPanel), findsNothing);
      expect(find.byType(miuix.MiuixTextField), findsOneWidget);
      expect(
        find.byKey(const ValueKey('pan-share-body-input')),
        findsOneWidget,
      );
      expect(calls, ['list_providers']);
      await tester.tap(find.byKey(const ValueKey('agg-global-proxy-settings')));
      await tester.pumpAndSettle();
      expect(find.byType(GlobalProxySettingsPage), findsOneWidget);
      expect(find.byType(ProxyPanel), findsOneWidget);
      expect(
        tester.widget<ProxyPanel>(find.byType(ProxyPanel)).providerId,
        SourinApi.globalProxyProvider,
      );
      expect(find.byType(miuix.MiuixTextField), findsNWidgets(4));
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'an existing danmaku transport delegates again after global changes',
    () async {
      var activeMode = 'custom';
      final observedModes = <String>[];
      final requests = <Map<String, dynamic>>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        if (command == 'set_proxy_config') {
          expect(args!['provider'], SourinApi.globalProxyProvider);
          activeMode = (args['config'] as Map)['mode'] as String;
          return null;
        }
        expect(command, 'global_proxy_text_request');
        requests.add(Map<String, dynamic>.from(args!));
        observedModes.add(activeMode);
        return {
          'statusCode': 200,
          'body': activeMode,
          'headers': <String, String>{},
        };
      };
      final transport = CoreDanmakuTransport(
        timeout: const Duration(milliseconds: 2300),
      );
      addTearDown(transport.close);
      final uri = Uri.parse('https://danmaku.invalid/api/comments');
      final first = await transport.send(
        method: 'POST',
        uri: uri,
        headers: {'content-type': 'application/json', 'x-fixture': 'request'},
        body: '{"episodeId":42}',
      );
      await SourinApi.setProxyConfig(
        SourinApi.globalProxyProvider,
        const ProxyConfig(mode: ProxyMode.direct),
      );
      final second = await transport.send(
        method: 'GET',
        uri: uri,
        headers: const {},
      );
      expect(first.body, 'custom');
      expect(second.body, 'direct');
      expect(observedModes, ['custom', 'direct']);
      expect(requests, [
        {
          'url': uri.toString(),
          'method': 'POST',
          'headers': {
            'content-type': 'application/json',
            'x-fixture': 'request',
          },
          'body': '{"episodeId":42}',
          'timeoutMs': 2300,
        },
        {
          'url': uri.toString(),
          'method': 'GET',
          'headers': <String, String>{},
          'timeoutMs': 2300,
        },
      ]);
    },
  );

  test(
    'danmaku preserves non-success status, response body and headers',
    () async {
      SourinCore.debugCallAsyncTransport = (command, args) async {
        expect(command, 'global_proxy_text_request');
        expect(args!['timeoutMs'], 15000);
        return {
          'statusCode': 403,
          'body': 'fixture-denied',
          'headers': {
            'x-error-message': 'fixture-key-rejected',
            'content-type': 'text/plain',
          },
        };
      };
      final transport = CoreDanmakuTransport();
      addTearDown(transport.close);
      final response = await transport.send(
        method: 'GET',
        uri: Uri.parse('https://danmaku.invalid/api/comments'),
        headers: const {},
      );
      expect(response.statusCode, 403);
      expect(response.isOk, isFalse);
      expect(response.body, 'fixture-denied');
      expect(response.xErrorMessage, 'fixture-key-rejected');
      expect(response.contentType, 'text/plain');
    },
  );

  test('danmaku propagates core failures without another request', () async {
    final failure = StateError('Synthetic proxy unavailable');
    var requests = 0;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(command, 'global_proxy_text_request');
      requests++;
      throw failure;
    };
    final transport = CoreDanmakuTransport();
    addTearDown(transport.close);
    await expectLater(
      transport.send(
        method: 'GET',
        uri: Uri.parse('https://danmaku.invalid/api/comments'),
        headers: const {},
      ),
      throwsA(same(failure)),
    );
    expect(requests, 1);
  });

  test(
    'closed danmaku transport rejects requests before reaching core',
    () async {
      var requests = 0;
      SourinCore.debugCallAsyncTransport = (command, args) async {
        requests++;
        return {'statusCode': 204};
      };
      final transport = CoreDanmakuTransport();
      final uri = Uri.parse('https://danmaku.invalid/api/comments');
      final response = await transport.send(
        method: 'GET',
        uri: uri,
        headers: const {},
      );
      expect(response.isOk, isTrue);
      expect(response.body, isEmpty);
      expect(response.headers, isEmpty);
      transport.close();
      transport.close();
      await expectLater(
        transport.send(method: 'GET', uri: uri, headers: const {}),
        throwsStateError,
      );
      expect(requests, 1);
    },
  );
}
