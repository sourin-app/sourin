@Tags(['needs-shot-dir'])
// ignore_for_file: avoid_print
//
// ═══════════════════════════════════════════════════════════════════════
//  task-66 轨道 I · 弹幕**聚合**看图台（合并后分路读数 + 四页签面板）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这份（Lead 要求：截图必须真的产出 PNG 让我看）
// ```text
// 行为对错由 `zz_t66_danmaku_bili_aggregate_gate_test.dart`（源码契约）
// 与 `t65b_danmaku_aggregate_test.dart`（聚合器单测，21 例）保证。
// 但**好不好看 / 读不读得懂**只能人眼看 ⇒ 这份文件只出图，不做断言。
// ```
//
// # 看什么（Lead 特别提醒的那条）
// ```text
// Owner 第 11 条：「同时加载并合并」+ 面板要显示「各路来源与条数」
// ⇒ 图里必须能同时看到：
//    · 总条数（合并去重后，不是简单相加）
//    · 每一路**各自**的条数（不被总数覆盖）
//    · 失败那一路的原因（不许被吞）
// ```
//
// ⚠️ 必须带标签：不带 `needs-shot-dir` ⇒ CI 会真去跑它然后因为没有
//    SOURIN_SHOT_DIR 而红（第 65 轮 `zz_composer_shot_test.dart` 就这么炸过，
//    Lead 已经修过一次）。带标签 ⇒ 默认 skip，显式跑才出图。
//
// 跑法：
//   SOURIN_SHOT_DIR=.probe/shots \
//   flutter test test/zz_t66_danmaku_shots_test.dart \
//     --run-skipped --tags needs-shot-dir --concurrency=1
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

import 'support/ui_shot.dart';

/// 面板数据：**两路都成功**（这是 Owner 第 11 条要的正常形态）
///
/// 数字取的是真实量级：外部源那一份 9415 条（实测 ep11954），
/// 插件那一份给个同量级的数字（本机没有真插件，这里只验"画得出来"）。
DanmakuInfoData _twoFeedsOk() => const DanmakuInfoData(
      source: DanmakuInfoSource.bili,
      match: DanmakuPairKind.autoSearch,
      count: 18854,
      title: '示例作品 第 1 集',
      loading: false,
      enabled: true,
      aggregate: <DanmakuAggregateFeed>[
        DanmakuAggregateFeed(
          label: '导入源',
          count: 9415,
          detail: '外部视频站',
        ),
        DanmakuAggregateFeed(
          label: '插件提供',
          count: 9440,
          detail: 'demo-plugin',
        ),
      ],
    );

/// 面板数据：**一路成功 + 一路失败**（排错现场，失败原因必须可读）
DanmakuInfoData _oneFeedFailed() => const DanmakuInfoData(
      source: DanmakuInfoSource.bili,
      match: DanmakuPairKind.none,
      count: 9415,
      title: '示例作品 第 1 集',
      loading: false,
      enabled: true,
      aggregate: <DanmakuAggregateFeed>[
        DanmakuAggregateFeed(
          label: '导入源',
          count: 9415,
          detail: '外部视频站',
        ),
        DanmakuAggregateFeed(
          label: '插件提供',
          count: 0,
          detail: 'demo-plugin',
          error: '这个源没有提供弹幕数据',
        ),
      ],
    );

/// 面板数据：**单源**（没有聚合 ⇒ 不该画出"来源 1 路"那一段）
DanmakuInfoData _singleFeed() => const DanmakuInfoData(
      source: DanmakuInfoSource.bili,
      match: DanmakuPairKind.manual,
      count: 9415,
      title: '示例作品 第 1 集',
      loading: false,
      enabled: true,
    );

Future<void> _pumpPanel(WidgetTester t, DanmakuInfoData d) async {
  await setShotViewport(t, const Size(720, 560));
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(Brightness.dark),
    home: Scaffold(
      backgroundColor: const Color(0xFF0A0B0D),
      body: RepaintBoundary(
        key: const ValueKey<String>('page'),
        child: Align(
          alignment: Alignment.topRight,
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: DanmakuInfoPanel(data: d, initiallyExpanded: true),
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

DanmakuSettingsState _settingsState() => const DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 0.9,
      speed: 1.0,
      area: 0.5,
      count: 18854,
      lanes: 6,
      dropped: 12,
    );

Future<void> _pumpSettings(WidgetTester t, String tab) async {
  await setShotViewport(t, const Size(760, 1180));
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(Brightness.dark),
    home: Scaffold(
      backgroundColor: const Color(0xFF0A0B0D),
      body: RepaintBoundary(
        key: const ValueKey<String>('page'),
        child: Center(
          child: SizedBox(
            width: 620,
            child: DanmakuSettingsDialog(
              state: _settingsState(),
              onSetEnabled: (_) {},
              onSetFontScale: (_) {},
              onSetOpacity: (_) {},
              onSetSpeed: (_) {},
              onSetArea: (_) {},
              onReload: () {},
              onClose: () {},
              fill: false,
            ),
          ),
        ),
      ),
    ),
  ));
  await t.pumpAndSettle();
  await t.tap(find.descendant(
    of: find.byType(SegmentedButton<DanmakuPanelTab>),
    matching: find.text(tab),
  ));
  await t.pumpAndSettle();
}

void main() {
  setUpAll(loadRealFonts);

  // ── 信息面板：三条关键形态 ──
  testWidgets('信息面板 · 两路合并（总 18854 / 9415 + 9440）', (t) async {
    await _pumpPanel(t, _twoFeedsOk());
    await saveViewShot(t, 't66_info_two_feeds');
    print('[SHOT] t66_info_two_feeds');
  });

  testWidgets('信息面板 · 一路成功一路失败（原因要读得出来）', (t) async {
    await _pumpPanel(t, _oneFeedFailed());
    await saveViewShot(t, 't66_info_one_failed');
    print('[SHOT] t66_info_one_failed');
  });

  testWidgets('信息面板 · 单源（不该出现"来源 N 路"）', (t) async {
    await _pumpPanel(t, _singleFeed());
    await saveViewShot(t, 't66_info_single');
    print('[SHOT] t66_info_single');
  });

  // ── 设置面板四个页签（确认改名后文字都排得下）──
  testWidgets('面板 · dan-api 页签', (t) async {
    await _pumpSettings(t, 'dan-api');
    await saveViewShot(t, 't66_panel_danapi');
    print('[SHOT] t66_panel_danapi');
  });

  testWidgets('面板 · 插件提供页签', (t) async {
    await _pumpSettings(t, '插件提供');
    await saveViewShot(t, 't66_panel_plugin');
    print('[SHOT] t66_panel_plugin');
  });

  testWidgets('面板 · 官方兜底页签', (t) async {
    await _pumpSettings(t, '官方兜底');
    await saveViewShot(t, 't66_panel_official');
    print('[SHOT] t66_panel_official');
  });
}
