import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/global_proxy_settings_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

Future<ProxyConfig> Function(String) _ok(ProxyConfig cfg) =>
    (_) async => cfg;
Future<ProxyConfig> Function(String) get _boom =>
    (_) async => throw Exception('测试环境没有核心 DLL');

Widget _host(
  Future<ProxyConfig> Function(String)? loader, {
  Object? keySeed,
  int cards = 1,
}) =>
    // KeyedSubtree：换 loader 必须换树，否则 Element 复用旧 State、
    // 旧 cfg 残留 —— 那验的是 State 缓存，不是"失败 ⇒ 零尺寸"。
    KeyedSubtree(
      key: ValueKey(keySeed ?? identityHashCode(loader)),
      child: MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        builder: (_, child) => AppThemeHost(
          data: AppTheme.themeFor(Brightness.dark),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 700,
                child: Column(
                  children: [
                    for (var i = 0; i < cards; i++)
                      settingsProviderCardForTest(
                        provider: ProviderManifest(
                          id: 'proxy-sum-$i',
                          name: 'Proxy summary fixture $i',
                          kind: 'js',
                        ),
                        onEdit: () {},
                        onToggle: () {},
                        proxyLoader: loader,
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  late Map<String, dynamic> configs;
  setUp(() {
    final previousTransport = SourinCore.debugCallAsyncTransport;
    ProxyCache.reset();
    configs = {
      SourinApi.globalProxyProvider: {'mode': 'direct'},
    };
    SourinCore.debugCallAsyncTransport = (command, args) async {
      switch (command) {
        case 'list_proxy_configs':
          return Map<String, dynamic>.from(configs);
        case 'global_proxy_migration_choices':
          return <dynamic>[];
        case 'has_proxy_password':
          return {'has': false};
        case 'system_proxy_hint':
          return {'hint': null};
        case 'set_proxy_config':
          configs[args!['provider'] as String] = args['config'];
          return null;
        default:
          throw UnsupportedError('Unexpected summary command: $command');
      }
    };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = previousTransport;
      ProxyCache.reset();
    });
  });

  testWidgets('custom summary opens the shared global proxy editor', (t) async {
    await t.pumpWidget(
      _host(
        _ok(
          const ProxyConfig(
            mode: ProxyMode.custom,
            url: 'http://127.0.0.1:7890',
          ),
        ),
      ),
    );
    await t.pump();
    const summary = '跟随全局代理 · http://127.0.0.1:7890';
    expect(
      find.text(summary),
      findsOneWidget,
      reason: '折叠态必须一眼看到"是否走代理"（N5a 恢复的常显摘要）',
    );
    expect(
      find.byType(ProxyPanel),
      findsNothing,
      reason: '面板本体仍遵守第 07 项「展开才挂载」，摘要常显不等于面板常开',
    );
    await t.tap(find.text(summary));
    await t.pumpAndSettle();
    expect(find.byType(GlobalProxySettingsPage), findsOneWidget);
    expect(find.byType(ProxyPanel), findsOneWidget);
    expect(
      t.widget<ProxyPanel>(find.byType(ProxyPanel)).providerId,
      SourinApi.globalProxyProvider,
    );
  });

  testWidgets('③ 直连摘要可见；④ 读取失败零尺寸（零占位垃圾）', (t) async {
    await t.pumpWidget(_host(_ok(const ProxyConfig(mode: ProxyMode.direct))));
    await t.pump();
    expect(
      find.text('跟随全局代理 · 直连'),
      findsOneWidget,
      reason: '默认直连也必须显示 —— 摘要行的意义就是"每个源的代理模式一眼可见"',
    );

    await t.pumpWidget(_host(_boom, keySeed: 'boom'));
    await t.pump();
    expect(
      find.text('跟随全局代理 · 直连'),
      findsNothing,
      reason: '读取失败不出占位垃圾行（测试环境无 DLL 的形态）',
    );
    expect(find.byType(ProxyPanel), findsNothing);
  });

  testWidgets('saving global config refreshes every mounted source summary', (
    t,
  ) async {
    await t.pumpWidget(_host(null, cards: 2));
    await t.pump();
    expect(find.text('跟随全局代理 · 直连'), findsNWidgets(2));

    // This is the same write used by any entry into global proxy settings.
    await SourinApi.setProxyConfig(
      SourinApi.globalProxyProvider,
      const ProxyConfig(
        mode: ProxyMode.custom,
        url: 'http://new-global.invalid:7890',
      ),
    );
    await t.pump();
    expect(find.text('跟随全局代理 · 直连'), findsNothing);
    expect(
      find.text('跟随全局代理 · http://new-global.invalid:7890'),
      findsNWidgets(2),
    );
    expect(t.takeException(), isNull);
  });

  for (final staleFails in [false, true]) {
    testWidgets('stale summary response is ignored (failure=$staleFails)', (
      t,
    ) async {
      final stale = Completer<ProxyConfig>();
      var calls = 0;
      Future<ProxyConfig> loader(String _) {
        calls++;
        return calls == 1
            ? stale.future
            : Future.value(const ProxyConfig(mode: ProxyMode.system));
      }

      await t.pumpWidget(_host(loader));
      expect(calls, 1);
      ProxyCache.invalidate();
      ProxyCache.invalidate();
      expect(calls, 1, reason: 'Invalidation must not notify synchronously');
      await t.pump();
      expect(calls, 2, reason: 'Same-turn invalidations are combined');
      expect(find.text('跟随全局代理 · 跟随系统'), findsOneWidget);

      if (staleFails) {
        stale.completeError(StateError('Synthetic stale failure'));
      } else {
        stale.complete(const ProxyConfig(mode: ProxyMode.direct));
      }
      await t.pump();
      expect(find.text('跟随全局代理 · 跟随系统'), findsOneWidget);
      expect(find.text('跟随全局代理 · 直连'), findsNothing);

      await t.pumpWidget(const SizedBox.shrink());
      ProxyCache.invalidate();
      await t.pump();
      expect(calls, 2, reason: 'Disposed cards remove their listeners');
      expect(t.takeException(), isNull);
    });
  }

  test(
    'an old config response cannot repopulate invalidated shared cache',
    () async {
      final stale = Completer<Map<String, ProxyConfig>>();
      const current = ProxyConfig(mode: ProxyMode.system);
      var calls = 0;
      ProxyCache.overrideFetchers(
        configs: () {
          calls++;
          return calls == 1
              ? stale.future
              : Future.value({SourinApi.globalProxyProvider: current});
        },
      );
      final oldRequest = ProxyCache.configs();
      ProxyCache.invalidate();
      expect((await ProxyCache.configs()).values.single, same(current));
      stale.complete({
        SourinApi.globalProxyProvider: const ProxyConfig(
          mode: ProxyMode.direct,
        ),
      });
      await oldRequest;
      expect((await ProxyCache.configs()).values.single, same(current));
      expect(calls, 2);
    },
  );
}
