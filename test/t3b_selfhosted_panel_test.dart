// ═══════════════════════════════════════════════════════════════════════
//  T3b · 面板「自建弹幕服务」入口 —— 离线 widget 单测
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么（Owner 第 6 条「搜索弹幕提示失败」的解法）
// ```text
// ① 区块真的画出来（地址 / token / 测试连接 / 清除）
// ② 「测试连接」的四种结果都**如实**：在线、离线、地址非法、探针异常
// ③ ★ 测通才落盘；测不通**绝不**写偏好（不许假装配好了）
// ④ ★ token 不进状态行文案（面板是强制深色卡片，但打码是纪律）
// ⑤ 清除 ⇒ 偏好真的变空（回到内置路径）
// ```
//
// ⚠️ 全程**不联网**：连通性测试注入假探针（见 DanmakuSettingsDialog.probeOverride）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

DanmakuSettingsState _state() => const DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 0.9,
      speed: 1.0,
      area: 0.5,
    );

Widget _host({
  required DanmakuSettingsState state,
  Future<DanmakuLocalStatus> Function(DanmakuEndpoint?)? probe,
  VoidCallback? onChanged,
}) =>
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            DanmakuSettingsDialog(
              state: state,
              onSetEnabled: (_) {},
              onSetFontScale: (_) {},
              onSetOpacity: (_) {},
              onSetSpeed: (_) {},
              onSetArea: (_) {},
              onReload: () {},
              onClose: () {},
              onChanged: onChanged,
              probeOverride: probe,
            ),
          ],
        ),
      ),
    );

/// 装面板并切到「弹弹play」页签（自建服务区块在那里）。
Future<void> _pumpOnDandanTab(
  WidgetTester t, {
  DanmakuSettingsState? state,
  Future<DanmakuLocalStatus> Function(DanmakuEndpoint?)? probe,
  VoidCallback? onChanged,
}) async {
  t.view.physicalSize = const Size(1200, 2000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(
    state: state ?? _state(),
    probe: probe,
    onChanged: onChanged,
  ));
  await t.pump();
  final tab = find.descendant(
    of: find.byType(SegmentedButton<DanmakuPanelTab>),
    matching: find.text('弹弹play'),
  );
  await t.tap(tab);
  await t.pumpAndSettle();
}

Finder get _urlField => find.ancestor(
      of: find.text('服务地址'),
      matching: find.byType(TextField),
    );

Finder get _tokenField => find.ancestor(
      of: find.text('Token（可选）'),
      matching: find.byType(TextField),
    );

void main() {
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
    DanmakuConfig.debugSetBuiltin();
  });

  tearDown(() {
    UiPrefs.debugResetForTest(<String, String>{});
    DanmakuConfig.debugSetBuiltin();
  });

  group('① 区块渲染', () {
    testWidgets('★ 弹弹play 页签上有自建服务区块（地址/token/测试/清除）', (t) async {
      await _pumpOnDandanTab(t);
      expect(find.text('自建弹幕服务'), findsOneWidget);
      expect(_urlField, findsOneWidget);
      expect(_tokenField, findsOneWidget);
      expect(find.text('测试连接'), findsOneWidget);
      expect(find.text('清除'), findsOneWidget);
    });

    testWidgets('★ 没配过 ⇒ 明确说留空就走内置路径', (t) async {
      await _pumpOnDandanTab(t);
      expect(
        find.textContaining('没填就按内置路径走'),
        findsOneWidget,
        reason: '★ 用户必须知道留空不是坏状态 —— 那是默认路',
      );
    });

    testWidgets('★ 配过 ⇒ 输入框预填已存的地址（用户看得见当前值）', (t) async {
      UiPrefs.setDanmakuEndpoint('http://10.0.0.9:9321');
      UiPrefs.setDanmakuToken('tok123');
      await _pumpOnDandanTab(t);
      expect(t.widget<TextField>(_urlField).controller!.text,
          'http://10.0.0.9:9321');
      expect(t.widget<TextField>(_tokenField).controller!.text, 'tok123');
    });
  });

  group('② 测试连接：四种结果都如实', () {
    testWidgets('★ 探通 ⇒ 显示已就绪 · vX 并落盘', (t) async {
      await _pumpOnDandanTab(t, probe: (e) async => const DanmakuLocalStatus(
            online: true,
            version: '1.21.5',
            endpoint: DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
          ));
      await t.enterText(_urlField, 'http://127.0.0.1:9321');
      await t.pump();
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
      expect(find.textContaining('已就绪'), findsOneWidget);
      expect(find.textContaining('v1.21.5'), findsOneWidget);
      expect(UiPrefs.danmakuEndpoint, 'http://127.0.0.1:9321',
          reason: '★ 测通了就该落盘，否则用户白填');
    });

    testWidgets('★★ 探不通 ⇒ 如实说未运行，且绝不落盘（不许假装配好）', (t) async {
      await _pumpOnDandanTab(t, probe: (e) async => const DanmakuLocalStatus(
            online: false,
            endpoint: DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
          ));
      await t.enterText(_urlField, 'http://127.0.0.1:9321');
      await t.pump();
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
      expect(find.textContaining('未运行'), findsOneWidget);
      expect(UiPrefs.danmakuEndpoint, '',
          reason: '★★ 探不通还写偏好 = 假装配好了；用户下次起播会用这个死地址');
    });

    testWidgets('★★ 地址非法 ⇒ 说地址格式不对，不说后台未运行', (t) async {
      await _pumpOnDandanTab(t, probe: (e) async => const DanmakuLocalStatus(
            online: true,
            version: '9.9',
          ));
      await t.enterText(_urlField, 'http://');
      await t.pump();
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
      expect(find.textContaining('地址格式不对'), findsOneWidget);
      /*
       * ⚠️ 判据要**精确到那句假话**，不能笼统断言「不含本机外部弹幕」：
       *    凭证节的提示本来就会提到「本机外部弹幕 / 外部视频源弹幕」
       *    （那是在指免签名的两条路），笼统断言会把那句**正确**的话也判红。
       *    ★ 这里要防的是 core 的 notRunningLine —— 它说的是 2080 的结论，
       *      与用户填错的地址无关。
       */
      expect(
        find.textContaining(DanmakuLocalService.notRunningLine),
        findsNothing,
        reason: '★★ 地址填错时说「本机外部弹幕 未运行」是假话 —— '
            '用户会跑去查 2080，而问题其实在他自己的输入框里',
      );
      expect(UiPrefs.danmakuEndpoint, '', reason: '★ 非法地址不落盘');
    });

    testWidgets('★ 探针自己异常 ⇒ 如实说测试失败（不伪装成服务没起来）', (t) async {
      await _pumpOnDandanTab(t, probe: (e) async => throw StateError('boom'));
      await t.enterText(_urlField, 'http://127.0.0.1:9321');
      await t.pump();
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
      expect(find.textContaining('测试失败'), findsOneWidget);
    });

    testWidgets('★ 改了地址 ⇒ 上一次的测试结果作废', (t) async {
      await _pumpOnDandanTab(t, probe: (e) async => const DanmakuLocalStatus(
            online: true,
            version: '1.21.5',
          ));
      await t.enterText(_urlField, 'http://127.0.0.1:9321');
      await t.pump();
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
      expect(find.textContaining('已就绪'), findsOneWidget);
      await t.enterText(_urlField, 'http://other:1234');
      await t.pumpAndSettle();
      expect(find.textContaining('已就绪'), findsNothing,
          reason: '★ 地址改了还挂着上一条已就绪 = 撒谎（那个结论属于旧地址）');
    });
  });

  group('③ ★ token 不回显', () {
    /// 面板里所有 Text 的内容（用来做「明文不许出现」的全量扫描）
    Iterable<String> allTexts(WidgetTester t) =>
        t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '');

    testWidgets('★★ 未探测态：「当前生效」行是打码的（这是刚打开面板时的真实态）',
        (t) async {
      const secret = 'SUPERSECRETTOKEN';
      UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
      UiPrefs.setDanmakuToken(secret);
      // ⚠️ **不**点测试连接 —— 这一态才走 _maskedEndpoint（打码 helper）
      await _pumpOnDandanTab(t);
      expect(find.textContaining('当前生效'), findsOneWidget,
          reason: '阳性对照：这一行必须真的渲染出来，否则下面扫的是空气');
      for (final s in allTexts(t)) {
        expect(s.contains(secret), isFalse,
            reason: '★★ 明文 token 出现在文案里：$s');
      }
      /*
       * 打码后的形态应当是 scheme://host:port。
       * ⚠️ 不用 findsOneWidget：find.textContaining **也匹配 EditableText**，
       *    所以两个输入框里那份明文（用户自己输的，允许）也会被数进去。
       *    这里只要求「至少有一处」确实是打码形态。
       */
      expect(find.textContaining('http://127.0.0.1:9321'), findsWidgets);
    });

    testWidgets('★★ 探测成功后：状态行（core 的 res.line）也不含 token', (t) async {
      const secret = 'SUPERSECRETTOKEN';
      UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
      UiPrefs.setDanmakuToken(secret);
      await _pumpOnDandanTab(t, probe: (e) async => const DanmakuLocalStatus(
            online: true,
            version: '1.0',
            endpoint: DanmakuEndpoint(
                baseUrl: 'http://127.0.0.1:9321', token: 'SUPERSECRETTOKEN'),
          ));
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
      expect(find.textContaining('已就绪'), findsOneWidget,
          reason: '阳性对照：状态行必须真的渲染');
      for (final s in allTexts(t)) {
        expect(s.contains(secret), isFalse,
            reason: '★★ 明文 token 出现在文案里：$s');
      }
    });
  });

  group('④ 清除 ⇒ 回到内置路径', () {
    testWidgets('★ 点清除 ⇒ 两个偏好键都真的变空', (t) async {
      UiPrefs.setDanmakuEndpoint('http://10.0.0.9:9321');
      UiPrefs.setDanmakuToken('t');
      await _pumpOnDandanTab(t);
      await t.tap(find.text('清除'));
      await t.pumpAndSettle();
      expect(UiPrefs.danmakuEndpoint, '');
      expect(UiPrefs.danmakuToken, '');
      expect(UiPrefs.get(UiPrefs.danmakuEndpointKey), isNull,
          reason: '★ 清除要真的删键（不留垃圾键）');
      expect(find.textContaining('没填就按内置路径走'), findsOneWidget);
    });

    testWidgets('★ 没存过 ⇒ 清除按钮禁用（画一个点了没反应的按钮更糟）', (t) async {
      await _pumpOnDandanTab(t);
      final btn = t.widget<TextButton>(
        find.ancestor(of: find.text('清除'), matching: find.byType(TextButton)),
      );
      expect(btn.onPressed, isNull);
    });
  });

  group('⑤ 不破坏既有结构', () {
    testWidgets('★ 面板仍然有外壳标题（没自己套 Scaffold）', (t) async {
      await _pumpOnDandanTab(t);
      expect(find.text('弹幕设置'), findsOneWidget);
      expect(find.text('显示 / 过滤 / 请求'), findsOneWidget);
    });

    testWidgets('★ 三个页签都在（自建服务没挤掉任何一页）', (t) async {
      await _pumpOnDandanTab(t);
      expect(find.text('配置'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(SegmentedButton<DanmakuPanelTab>),
          matching: find.text('弹弹play'),
        ),
        findsOneWidget,
      );
    });
  });
}
