// ═══════════════════════════════════════════════════════════════════════
//  task-35 ③：弹幕源页的**状态行**文案分支
// ═══════════════════════════════════════════════════════════════════════
//
// # 这里守的是什么（真机实测发现的缺陷，不是想出来的）
// 真机上把「服务地址」清空后点「测试连接」，状态行显示
// 「检测到本机外部弹幕 未运行」。
// 那句话是真的 —— 地址为空时探的确实是本机弹弹play（2080）——
// 但用户刚在**服务地址**这一栏点了按钮，会把它当成
// 「我填的地址」的结论，而他其实什么都没填。
// 这是**归因错误**，比「没提示」更糟。
//
// # 判据用「屏幕上的字」，不用内部字段
// `_StatusLine` 是私有类，测试不该读它的私有状态（会随重构碎）。
// 用 `find.textContaining` 读**渲染出来的文案**：
// 那正是用户看到的东西，也正是这条要求的对象。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';

Widget _app(Widget home) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: home),
    );

/// 假探针：立刻返回给定结果，零联网
Future<DanmakuLocalStatus> Function(DanmakuEndpoint?) _probe(
    DanmakuLocalStatus st) {
  return (DanmakuEndpoint? ep) async => st;
}

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() => UiPrefs.debugResetForTest());

  /*
   * ★★ 每个用例结束前把 UiPrefs 的合并落盘定时器**真的跑掉**。
   *
   * # 为什么必须做（真泄漏，不是测试洁癖）
   * `UiPrefs.set` 会排一个 300ms 的 Future.delayed（ui_prefs.dart:107-113）。
   * 测试体一结束，框架检查到它还没到点就报：
   *   A Timer is still pending even after the widget tree was disposed.
   * 而这条报错会**掩盖真正的断言结果**。
   *
   * # ★ 为什么必须用 `pump(Duration)` 而不是 `runAsync` 里等真实时间
   * 那个 Timer 是在 **FakeAsync 区**里被创建的 ⇒ 它只认**假时钟**。
   * `runAsync` 期间跑的是真实时钟，假时钟**一动不动** ⇒ 定时器永远不会到点
   * （第一版就是这么写的，仍然报 pending）。
   * `pump(Duration)` 才推进假时钟 ⇒ 300ms 的延时真的到点、定时器结清。
   */
  Future<void> settlePrefs(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('★ 未配置 ⇒ 状态行说「未配置」，不提本机弹弹play 的探测结论', (tester) async {
    await tester.pumpWidget(_app(DanmakuSourcePage(
      probeOverride: _probe(const DanmakuLocalStatus(online: false)),
    )));
    await tester.pumpAndSettle();

    expect(find.textContaining('未配置'), findsOneWidget,
        reason: '刚打开、什么都没填时，状态行必须说「未配置」');
    expect(find.textContaining('未运行'), findsNothing,
        reason: '★ 还没点任何按钮，不该出现探测结论（那是无中生有）');
  });

  testWidgets('★ 地址为空却点了测试 ⇒ 明说「测的是本机弹弹play」', (tester) async {
    await tester.pumpWidget(_app(DanmakuSourcePage(
      probeOverride: _probe(const DanmakuLocalStatus(online: false)),
    )));
    await tester.pumpAndSettle();

    // ⚠️ 2026-10-18（round-65 批次 B）：页面顶部新增了「内置实例」区块，
    //    按钮被推到 800x600 测试视口之外 ⇒ 先滚进可视区再 tap。
    //    真机上页面是 ListView，用户滚一下就到，行为没变。
    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('地址为空，测的是本机弹弹play'), findsOneWidget,
        reason: '★ 归因必须清楚：这句话是 2080 的结论，不是 dan-api 的');
  });

  testWidgets('★ 填了地址且探通 ⇒ 显示「已就绪」，不出现「地址为空」前缀', (tester) async {
    await tester.pumpWidget(_app(DanmakuSourcePage(
      probeOverride: _probe(const DanmakuLocalStatus(
        online: true,
        version: '1.21.5',
        endpoint: DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
      )),
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'http://127.0.0.1:9321');
    await tester.pumpAndSettle();
    // ⚠️ 2026-10-18（round-65 批次 B）：页面顶部新增了「内置实例」区块，
    //    按钮被推到 800x600 测试视口之外 ⇒ 先滚进可视区再 tap。
    //    真机上页面是 ListView，用户滚一下就到，行为没变。
    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(find.textContaining('已就绪'), findsOneWidget,
        reason: '探通了必须说「已就绪」，否则用户不知道能用了');
    expect(find.textContaining('地址为空'), findsNothing,
        reason: '填了地址就不该再出现「地址为空」的归因前缀');
    await settlePrefs(tester);
  });

  testWidgets('★ 探通后落盘（用户点了测试就等于认了这个地址）', (tester) async {
    await tester.pumpWidget(_app(DanmakuSourcePage(
      probeOverride: _probe(const DanmakuLocalStatus(
        online: true,
        version: '1.0',
        endpoint: DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
      )),
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'http://127.0.0.1:9321');
    await tester.pumpAndSettle();
    // ⚠️ 2026-10-18（round-65 批次 B）：页面顶部新增了「内置实例」区块，
    //    按钮被推到 800x600 测试视口之外 ⇒ 先滚进可视区再 tap。
    //    真机上页面是 ListView，用户滚一下就到，行为没变。
    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(UiPrefs.danmakuEndpoint, 'http://127.0.0.1:9321',
        reason: '★ 测通了不落盘 = 用户改了等于没改（改前那个面板也是这个纪律）');
    await settlePrefs(tester);
  });

  testWidgets('★ 探不通不落盘（不许把坏地址写进偏好）', (tester) async {
    await tester.pumpWidget(_app(DanmakuSourcePage(
      probeOverride: _probe(const DanmakuLocalStatus(online: false)),
    )));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'http://127.0.0.1:9999');
    await tester.pumpAndSettle();
    // ⚠️ 2026-10-18（round-65 批次 B）：页面顶部新增了「内置实例」区块，
    //    按钮被推到 800x600 测试视口之外 ⇒ 先滚进可视区再 tap。
    //    真机上页面是 ListView，用户滚一下就到，行为没变。
    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pumpAndSettle();

    expect(UiPrefs.danmakuEndpoint, isEmpty,
        reason: '★ 探不通还落盘，等于下次启动就拿一个坏地址去请求');
    await settlePrefs(tester);
  });

  testWidgets('★★ 竞态：测试在途时改地址 ⇒ 旧结果不许写状态行、也不许落盘', (tester) async {
    final completer = <Completer<DanmakuLocalStatus>>[];
    Future<DanmakuLocalStatus> slow(DanmakuEndpoint? ep) {
      final c = Completer<DanmakuLocalStatus>();
      completer.add(c);
      return c.future;
    }

    await tester.pumpWidget(_app(DanmakuSourcePage(probeOverride: slow)));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).first, 'http://10.0.0.1:9321');
    await tester.pumpAndSettle();
    // ⚠️ 2026-10-18（round-65 批次 B）：页面顶部新增了「内置实例」区块，
    //    按钮被推到 800x600 测试视口之外 ⇒ 先滚进可视区再 tap。
    //    真机上页面是 ListView，用户滚一下就到，行为没变。
    await tester.ensureVisible(find.text('测试连接'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试连接'));
    await tester.pump();

    // 在途时改地址 ⇒ 序号前进 ⇒ 旧结果作废
    await tester.enterText(find.byType(TextField).first, 'http://10.0.0.2:9321');
    await tester.pumpAndSettle();

    // 旧请求现在成功返回
    completer.first.complete(const DanmakuLocalStatus(
      online: true,
      version: '1.0',
      endpoint: DanmakuEndpoint(baseUrl: 'http://10.0.0.1:9321'),
    ));
    await tester.pumpAndSettle();

    expect(UiPrefs.danmakuEndpoint, isEmpty,
        reason: '★★ 用户在途改了地址，旧地址的「成功」不许落盘 ——'
            ' 否则输入框是 B、偏好是 A，两者互相矛盾');
    await settlePrefs(tester);
  });
}