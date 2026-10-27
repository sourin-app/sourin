// N5a（2026-10-27）：卡片正文代理模式摘要行 `_ProxyModeSummary` 的行为门禁
//
// Owner 原话：「还把 具体插件 是否 直连还是走代理 这个功能给删除了」。
// 功能没删，但第 07 项「展开才挂载」让摘要行从卡片上消失了。
// 本门禁钉三条不变量：
//   ① 摘要**常显**（折叠态就能看到 直连/跟随系统/自定义·地址）；
//   ② 点摘要 = 展开卡片（面板本体仍遵守第 07 项「展开才挂载」）；
//   ③ 读取失败 → 零尺寸（零占位垃圾；测试环境无 DLL 不出垃圾行）。
// 注入：把卡片正文里的 `_ProxyModeSummary` 挂载删掉 ⇒ ①④ 当场红
//（.probe/n5a-injectA.log）。
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

Future<ProxyConfig> Function(String) _ok(ProxyConfig cfg) => (_) async => cfg;
Future<ProxyConfig> Function(String) get _boom =>
    (_) async => throw Exception('测试环境没有核心 DLL');

Widget _host(Future<ProxyConfig> Function(String)? loader, {Object? keySeed}) =>
    // KeyedSubtree：换 loader 必须换树，否则 Element 复用旧 State、
    // 旧 cfg 残留 —— 那验的是 State 缓存，不是"失败 ⇒ 零尺寸"。
    KeyedSubtree(
      key: ValueKey(keySeed ?? identityHashCode(loader)),
      child: MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Center(
              child: SizedBox(
                width: 700,
                child: settingsProviderCardForTest(
                  provider: const ProviderManifest(
                      id: 'proxy-sum', name: 'Proxy summary fixture', kind: 'js'),
                  onEdit: () {},
                  onToggle: () {},
                  proxyLoader: loader,
                ),
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  testWidgets('① 自定义代理：摘要常显地址；② 点摘要展开卡片（面板才挂载）',
      (t) async {
    await t.pumpWidget(_host(_ok(const ProxyConfig(
      mode: ProxyMode.custom,
      url: 'http://127.0.0.1:7890',
    ))));
    await t.pump();
    expect(find.text('http://127.0.0.1:7890'), findsOneWidget,
        reason: '折叠态必须一眼看到"是否走代理"（N5a 恢复的常显摘要）');
    expect(find.byType(ProxyPanel), findsNothing,
        reason: '面板本体仍遵守第 07 项「展开才挂载」，摘要常显不等于面板常开');
    await t.tap(find.text('http://127.0.0.1:7890'));
    await t.pump();
    expect(find.byType(ProxyPanel), findsOneWidget,
        reason: '点摘要 = 展开卡片，代理面板随之挂载');
  });

  testWidgets('③ 直连摘要可见；④ 读取失败零尺寸（零占位垃圾）', (t) async {
    await t.pumpWidget(_host(_ok(const ProxyConfig(mode: ProxyMode.direct))));
    await t.pump();
    expect(find.text('直连'), findsOneWidget,
        reason: '默认直连也必须显示 —— 摘要行的意义就是"每个源的代理模式一眼可见"');

    await t.pumpWidget(_host(_boom, keySeed: 'boom'));
    await t.pump();
    expect(find.text('直连'), findsNothing,
        reason: '读取失败不出占位垃圾行（测试环境无 DLL 的形态）');
    expect(find.byType(ProxyPanel), findsNothing);
  });
}
