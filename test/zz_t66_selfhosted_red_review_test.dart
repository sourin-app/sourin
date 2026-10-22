// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮：**6 个「基线红」的根因复核**（只读型，不改任何产品代码）
// ═══════════════════════════════════════════════════════════════════════
//
// ⚠️⚠️ **本文件不是门禁 —— 不要把它当门禁，也不要因为"它不够格当门禁"就删掉。**
//
// ```text
// 它的断言只有 `expect(texts, isNotEmpty)` 这类**防空跑**兜底
// （`texts.length >= 3`），证明的是"面板真的渲染出来了"，
// **不证明**"UI 说了该说的话"。
//
// ★ 真正的主张（"测试连接该显示什么"）本文件**故意不断言** ——
//   文件内原话：「这里只把实测数字打印出来，不 assert ——
//   因为『该显示什么』是产品决策，不是本只读文件的职权」。
//   ⇒ 所以它对真正的主张**无法变红**。这不是缺陷，是它的定位。
//
// ⇒ 它的价值全在 **print 出来的文案快照**（`RED|TEXT 「…」`）里：
//   那是"产品当时到底说了什么"的原始证据，供人读、供下一个人考古。
//
// ★ 为什么留在 `test/` 而不是 `.probe/`：
//   2026-10-19 `.probe/` 被一次"清理临时文件"误删（多人共享目录）。
//   ⇒ **想保留的取证文件应进 `test/` 或 `docs/`，不要放 `.probe/`** ——
//     `test/` 受 git 保护，`.probe/` 随时可能被下一个人删掉。
//   本文件留在 `test/` 的**唯一**理由是保住这份快照，不是因为它能拦缺陷。
// ```
//
//  # 复核对象
//  ```text
//  t3b_selfhosted_panel_test      ② 测试连接：四种结果都如实  ×1 红
//  zz_t3_selfhosted_shots_test    ×5 红
//  Lead 已确认「与本轮改动无关」（stash 回 HEAD 读数不变），但**没查为什么**。
//  ⇒ 本文件补的就是「为什么」。
//  ```
//
//  # 本文件守什么（只读，不改代码）
//  ```text
//  ① 把 StateError 喂进「测试连接」，把**真实渲染出来的文案**打印出来
//     —— 判定「UI 到底说了什么」必须读渲染结果，不许读源码字符串。
//  ② 机械断言：那条「探针自己异常 ⇒ 如实说测试失败」的测试，
//     断言的字符串在**当前产品行为下**是否还能出现。
//  ```
//
//  # 判据纪律
//  ```text
//  · 打印全部 Text（含空树则先红，防恒真）。
//  · 本文件**故意不 fail**：它是取证工具，处置权在 Lead。
//    只对「树非空」做硬断言，其余全部 print。
//  ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
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
              probeOverride: probe,
            ),
          ],
        ),
      ),
    );

Future<void> _pumpOnAdvancedTab(
  WidgetTester t, {
  required Future<DanmakuLocalStatus> Function(DanmakuEndpoint?)? probe,
}) async {
  t.view.physicalSize = const Size(1200, 2000);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);
  await t.pumpWidget(_host(state: _state(), probe: probe));
  await t.pump();
  final tab = find.descendant(
    of: find.byType(SegmentedButton<DanmakuPanelTab>),
    matching: find.text('高级'),
  );
  await t.tap(tab);
  await t.pumpAndSettle();
}

Finder get _urlField =>
    find.ancestor(of: find.text('服务地址'), matching: find.byType(TextField));

List<String> _allTexts(WidgetTester t) {
  final out = <String>[];
  for (final el in find.byType(Text).evaluate()) {
    final w = el.widget as Text;
    final d = w.data;
    if (d != null && d.trim().isNotEmpty) out.add(d);
  }
  return out;
}

void main() {
  testWidgets('★ 复核：探针抛 StateError 时，UI 到底说了什么', (t) async {
    await _pumpOnAdvancedTab(
      t,
      probe: (e) async => throw StateError('boom'),
    );
    await t.enterText(_urlField, 'http://127.0.0.1:9321');
    await t.pump();
    await t.tap(find.text('测试连接'));
    await t.pumpAndSettle();

    final texts = _allTexts(t);
    // 防空转：树必须非空，否则「没找到某句」是恒真
    expect(texts.length, greaterThanOrEqualTo(3),
        reason: '★★ 防空转：树上只有 ${texts.length} 条 Text ⇒ 面板没渲染出来，'
            '下面「找不到『测试失败』」没有意义。');

    // ignore: avoid_print
    print('RED|=== StateError(\'boom\') 之后树上出现的全部文案 ===');
    for (final s in texts) {
      // ignore: avoid_print
      print('RED|TEXT 「$s」');
    }

    final hitOld = find.textContaining('测试失败').evaluate().length;
    // ignore: avoid_print
    print('RED|含「测试失败」的 Text 数 = $hitOld');

    /*
     * ★★★ 核心结论用的判据（不是"红不红"，而是"UI 说了什么"）
     * ===================================================================
     * t3b 那条测试断言的是 `find.textContaining('测试失败')` 命中 1。
     * 这里只把实测数字打印出来，**不 assert** ——
     * 因为「该显示什么」是产品决策，不是本只读文件的职权。
     */
    expect(texts, isNotEmpty, reason: '防空转兜底');
  });

  testWidgets('★ 复核：探针返回 online:false（未配置）时说了什么', (t) async {
    await _pumpOnAdvancedTab(
      t,
      probe: (e) async => const DanmakuLocalStatus(online: false),
    );
    await t.enterText(_urlField, 'http://127.0.0.1:9321');
    await t.pump();
    await t.tap(find.text('测试连接'));
    await t.pumpAndSettle();

    final texts = _allTexts(t);
    expect(texts.length, greaterThanOrEqualTo(3), reason: '防空转');
    // ignore: avoid_print
    print('RED|=== online:false 之后树上出现的全部文案 ===');
    for (final s in texts) {
      // ignore: avoid_print
      print('RED|TEXT 「$s」');
    }
  });

  testWidgets('★ 复核：探针抛 SocketException(超时) 时说了什么', (t) async {
    await _pumpOnAdvancedTab(
      t,
      probe: (e) async => throw const SocketException(
        'Connection timed out',
        osError: OSError('Connection timed out', 10060),
      ),
    );
    await t.enterText(_urlField, 'http://127.0.0.1:9321');
    await t.pump();
    await t.tap(find.text('测试连接'));
    await t.pumpAndSettle();

    final texts = _allTexts(t);
    expect(texts.length, greaterThanOrEqualTo(3), reason: '防空转');
    // ignore: avoid_print
    print('RED|=== SocketException(10060) 之后树上出现的全部文案 ===');
    for (final s in texts) {
      // ignore: avoid_print
      print('RED|TEXT 「$s」');
    }
  });
}