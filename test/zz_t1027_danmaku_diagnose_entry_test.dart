import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// 第 05 项 · DNS 四档归因的**生产入口驱动**门禁
///
/// # 为什么必须有这个文件（而不是继续在 zz_t1027 里调纯函数）
/// ```text
/// 2026-10-25 的复核发现：`dnsConsistent` / `dnsInconsistent` /
/// `dnsUnverifiable` 三档在生产里**一次都执行不到** —— 因为唯一带 DoH 对照的
/// 入口 `_diagnose` 前面有一道 `looksForged(local)` 门禁。
/// 那时的门禁全是"直接调 forHijackedDns / hijackReportWithTruth"的纯函数用例
/// ⇒ 三条档位"看着都有断言"，实际一次都不会出现在用户眼前。
/// ⇒ 本文件从**组件入口**（`_runProbe → _diagnose`）驱动，断言**屏幕上的文案**。
/// ```
///
/// 驱动方式（三步，全部零联网）：
///   1. `probeOverride`：让"测试连接"的探针判离线（不联网）
///   2. `routeOverride`：替换 HTTP 路由诊断 —— 它抛出带地址的 SocketException
///      （地址就是"本机解析到的那一个"），同时它也是让 `_diagnose` 在
///      注入了 probeOverride 时仍被调用的放行条件
///   3. `dohOverride`：替换权威 DNS 查询，返回我们指定的真值
void main() {
  /// 与真实渲染一致的宿主（面板是深色固定灰阶）
  Widget host(DanmakuSettingsDialog dialog) => MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(body: dialog),
      );

  DanmakuSettingsDialog dialogWith({
    required String localAddress,
    required Future<List<String>> Function(String host) doh,
  }) =>
      DanmakuSettingsDialog(
        state: const DanmakuSettingsState(
          enabled: true,
          appId: '',
          appSecret: '',
          fontScale: 1,
          opacity: 1,
          speed: 8,
          area: 1,
        ),
        onSetEnabled: (_) {},
        onSetFontScale: (_) {},
        onSetOpacity: (_) {},
        onSetSpeed: (_) {},
        onSetArea: (_) {},
        onReload: () {},
        onClose: () {},
        // ① 探针：判离线（零联网）
        probeOverride: (DanmakuEndpoint? e) async => const DanmakuLocalStatus(
          online: false,
        ),
        // ② 路由诊断：抛一个带"本机地址"的 SocketException（零联网）
        routeOverride: (DanmakuEndpoint? e) async => throw SocketException(
          'fixture',
          address: InternetAddress(localAddress),
          osError: const OSError('Connection timed out', 10060),
        ),
        // ③ 权威 DNS：注入真值（零联网）
        dohOverride: doh,
      );

  /// 点「测试连接」→ 探针判离线 → 走 `_diagnose`（含 DoH 对照）
  Future<void> runDiagnose(WidgetTester t, DanmakuSettingsDialog dialog) async {
    // 视口给够：高级页签的内容比默认视口长，按钮实测会落在折叠线以下
    t.view.physicalSize = const Size(1200, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    await t.pumpWidget(host(dialog));
    await t.pumpAndSettle();
    await t.tap(find.descendant(
      of: find.byType(SegmentedButton<DanmakuPanelTab>),
      matching: find.text('高级'),
    ));
    await t.pumpAndSettle();
    // 必须先填一个「服务地址」：`_record()` 用 `tryParse(raw)` 造 endpoint，
    // 地址为空时 `ep == null` ⇒ 分层诊断根本不会被调用（这是驱动这条入口的前提）
    await t.enterText(
      find.ancestor(
        of: find.text('服务地址'),
        matching: find.byType(TextField),
      ).first,
      'http://127.0.0.1:9321',
    );
    await t.pumpAndSettle();
    await t.scrollUntilVisible(
      find.text('测试连接'),
      150,
      scrollable: find
          .descendant(
            of: find.byKey(const ValueKey('danmaku-settings-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await t.ensureVisible(find.text('测试连接'));
    await t.tap(find.text('测试连接'));
    await t.pumpAndSettle();
    // 探针/诊断都是 async：再多走几帧，让 setState 落地
    await t.pump(const Duration(milliseconds: 300));
    await t.pumpAndSettle();
  }

  testWidgets('① 本机正常 + 真值同 /24 ⇒ 屏幕上是「域名解析正确」', (t) async {
    await runDiagnose(
      t,
      dialogWith(
        localAddress: '216.198.79.67',
        doh: (_) async => const <String>['216.198.79.131'],
      ),
    );
    expect(find.textContaining('域名解析正确'), findsOneWidget,
        reason: '★ 同 /24 必须判"一致" —— 这是 2026-10-25 那次误诊的正向对照');
    expect(find.textContaining('DNS 可能被劫持'), findsNothing,
        reason: '★★ 健康网络**不许**被说成劫持（本项最初要修的就是这个）');
  });

  testWidgets('② 跨段但两边都正常 ⇒ 屏幕上是「与本机解析不一致」', (t) async {
    await runDiagnose(
      t,
      dialogWith(
        localAddress: '216.198.79.67',
        doh: (_) async => const <String>['64.29.17.131'],
      ),
    );
    expect(find.textContaining('与本机解析不一致'), findsOneWidget,
        reason: '★ 跨网段且未落伪造段 ⇒ 只能说"不一致"（多 A/CDN 是常态）');
    expect(find.textContaining('DNS 可能被劫持'), findsNothing,
        reason: '★★ 没有伪造段证据就不许说劫持');
  });

  testWidgets('③ 本机落在伪造段 + 真值不同 ⇒ 屏幕上是「DNS 可能被劫持」', (t) async {
    await runDiagnose(
      t,
      dialogWith(
        localAddress: '74.86.17.48',
        doh: (_) async => const <String>['216.198.79.131'],
      ),
    );
    expect(find.textContaining('DNS 可能被劫持'), findsOneWidget,
        reason: '★ 伪造段是地址级物证 ⇒ 必须定案劫持');
    expect(find.textContaining('域名解析正确'), findsNothing);
  });

  testWidgets('④ 真值拿不到 + 本机不在伪造段 ⇒ 屏幕上是「没有可比较」', (t) async {
    await runDiagnose(
      t,
      dialogWith(
        localAddress: '216.198.79.67',
        // 查了但没有答案 ⇒ 一侧缺失
        doh: (_) async => const <String>[],
      ),
    );
    expect(find.textContaining('没有可比较'), findsOneWidget,
        reason: '★ 缺真值且不在伪造段 ⇒ 如实说"比不了"，不猜');
    expect(find.textContaining('DNS 可能被劫持'), findsNothing);
  });
}
