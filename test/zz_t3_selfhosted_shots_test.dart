// 自建弹幕服务区块的**看图台**（自用，不是断言型测试）。
//
// 跑法：
//   SOURIN_SHOT_DIR=.probe/shots flutter test test/zz_t3_selfhosted_shots_test.dart --concurrency=1
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

import 'support/ui_shot.dart';

DanmakuSettingsState _state() => const DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 0.9,
      speed: 1.0,
      area: 0.5,
      count: 111,
      lanes: 6,
      dropped: 12,
    );

Future<void> _pump(
  WidgetTester t, {
  required Brightness brightness,
  Future<DanmakuLocalStatus> Function(DanmakuEndpoint?)? probe,
}) async {
  await setShotViewport(t, const Size(760, 1180));
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(brightness),
    builder: (context, c) => AppThemeHost(
      data: AppTheme.themeFor(brightness),
      child: c ?? const SizedBox(),
    ),
    home: Scaffold(
      backgroundColor: brightness == Brightness.dark
          ? const Color(0xFF101014)
          : const Color(0xFFEEF0F6),
      body: Center(
        child: SizedBox(
          width: 620,
          child: DanmakuSettingsDialog(
            state: _state(),
            onSetEnabled: (_) {},
            onSetFontScale: (_) {},
            onSetOpacity: (_) {},
            onSetSpeed: (_) {},
            onSetArea: (_) {},
            onReload: () {},
            onClose: () {},
            fill: false,
            probeOverride: probe,
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
  // 切到「高级」页签 —— 自建弹幕服务的区块（`_selfHostedSection`）在那里
  //
  // ★★ 2026-10-19（Lead 修，两处）：
  //   ① 原文案 `'dan-api'` → R3 那轮改名成「显示 / 弹幕来源 / 高级」
  //      （`danmaku_settings_dialog.dart:1832/1836/1840`）
  //   ② ★ 我第一次只改成「弹幕来源」⇒ 仍然红，因为**「测试连接」按钮不在那一页**：
  //      `_selfHostedSection()` 只在 `DanmakuPanelTab.advanced` 分支里被调用
  //      （`:1574` 的 `_group(_selfHostedSection())` 在 else 分支 = 高级），
  //      而按钮本身在 `:2141`。
  //   ⇒ 判据不能靠"哪个页签名字听起来像"，必须读**渲染位置**。
  await t.tap(find.descendant(
    of: find.byType(SegmentedButton<DanmakuPanelTab>),
    matching: find.text('高级'),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);
  setUp(() {
    UiPrefs.debugResetForTest(<String, String>{});
  });
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  testWidgets('自建弹幕服务 · 未配置（深色）', (t) async {
    await _pump(t, brightness: Brightness.dark);
    await saveViewShot(t, 't3_selfhost_unconfigured_dark');
  });

  testWidgets('自建弹幕服务 · 未配置（浅色）', (t) async {
    await _pump(t, brightness: Brightness.light);
    await saveViewShot(t, 't3_selfhost_unconfigured_light');
  });

  testWidgets('自建弹幕服务 · 测试连接成功（深色）', (t) async {
    UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
    await _pump(
      t,
      brightness: Brightness.dark,
      probe: (e) async => const DanmakuLocalStatus(
        online: true,
        version: '1.21.5',
        endpoint: DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
      ),
    );
    await t.tap(find.text('测试连接'));
    await t.pumpAndSettle();
    await saveViewShot(t, 't3_selfhost_ok_dark');
  });

  testWidgets('自建弹幕服务 · 测试连接成功（浅色）', (t) async {
    UiPrefs.setDanmakuEndpoint('http://127.0.0.1:9321');
    await _pump(
      t,
      brightness: Brightness.light,
      probe: (e) async => const DanmakuLocalStatus(
        online: true,
        version: '1.21.5',
        endpoint: DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
      ),
    );
    await t.tap(find.text('测试连接'));
    await t.pumpAndSettle();
    await saveViewShot(t, 't3_selfhost_ok_light');
  });

  testWidgets('自建弹幕服务 · 测试失败（深色）', (t) async {
    await _pump(
      t,
      brightness: Brightness.dark,
      probe: (e) async => const DanmakuLocalStatus(
        online: false,
        endpoint: DanmakuEndpoint(baseUrl: 'http://127.0.0.1:9321'),
      ),
    );
    await t.enterText(
      find.ancestor(of: find.text('服务地址'), matching: find.byType(TextField)),
      'http://127.0.0.1:9321',
    );
    await t.pump();
    await t.tap(find.text('测试连接'));
    await t.pumpAndSettle();
    await saveViewShot(t, 't3_selfhost_fail_dark');
  });
}
