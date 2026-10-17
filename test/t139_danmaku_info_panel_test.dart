@Tags(['needs-shot-dir'])
// ignore_for_file: avoid_print
//
// ═══════════════════════════════════════════════════════════════════════
//  task-32 ② · 播放页右侧「弹幕信息」面板 —— 看图台 + 行为门禁
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话：「在播放页面右侧显示加载了哪些弹幕,方便排查问题(要优化ui)」
//
// # 这份文件回答两件事
// ```text
// ① 面板**该说的话**都说全了（来源/条数/匹配/失败原因四项，行为级）
// ② 真实渲染落成 PNG 给人眼看「好不好看」（截图，需 SOURIN_SHOT_DIR）
// ```
//
// ⚠️ 截图是 `@Tags(['needs-shot-dir'])` ⇒ 默认跑会 skip（exit 0）。
//    要出图：
//     flutter test test/t139_danmaku_info_panel_test.dart --run-skipped \
//       --tags needs-shot-dir   （带 SOURIN_SHOT_DIR）
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/danmaku_info_panel.dart';

import 'support/ui_shot.dart';

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0B0D),
        body: RepaintBoundary(
          key: const ValueKey<String>('page'),
          child: Align(alignment: Alignment.topRight, child: child),
        ),
      ),
    );

/// 一个"典型"的快照：bili 直连 + 自动匹配 + 有数据
const _loaded = DanmakuInfoData(
  source: DanmakuSourceKind.bili,
  match: DanmakuMatchKind.autoSearch,
  count: 1200,
  title: '鬼灭之刃 柱训练篇',
  cid: 1602741036,
  enabled: true,
);

/// 走 season 兜底的那种（面板要能一眼看出"这是备用链路"）
const _fallback = DanmakuInfoData(
  source: DanmakuSourceKind.bili,
  match: DanmakuMatchKind.autoSeason,
  count: 7200,
  title: '鬼灭之刃 柱训练篇',
  cid: 1602741036,
  enabled: true,
);

void main() {
  setUpAll(loadRealFonts);

  group('面板 · 行为', () {
    testWidgets('★ 收起态只显示条数，点一下展开', (t) async {
      await t.pumpWidget(_host(const DanmakuInfoPanel(data: _loaded)));
      // 收起态：有"弹幕 1200"，没有"已载入"那一行
      expect(find.textContaining('1200'), findsOneWidget);
      expect(find.text('已载入'), findsNothing);

      await t.tap(find.byType(InkWell).first);
      await t.pumpAndSettle();
      expect(find.text('已载入'), findsOneWidget, reason: '展开后要出现四项事实');
    });

    testWidgets('★★ 四项事实必须全在：来源 / 条数 / 匹配 / （失败时才有的）原因',
        (t) async {
      await t.pumpWidget(_host(
        const DanmakuInfoPanel(data: _loaded, initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(find.text('外部视频站直连'), findsOneWidget, reason: '① 来源');
      expect(find.text('已载入'), findsOneWidget, reason: '② 条数标签');
      expect(find.textContaining('1200'), findsWidgets, reason: '② 条数真值');
      expect(find.text('匹配'), findsOneWidget, reason: '③ 匹配标签');
      expect(find.text('自动匹配'), findsOneWidget, reason: '③ 匹配真值');
      expect(find.textContaining('1602741036'), findsOneWidget, reason: 'cid');
      expect(find.textContaining('鬼灭之刃'), findsOneWidget, reason: '作品名');
      // 没有失败 ⇒ 不该有失败块（阳性对照：不许无条件画）
      expect(find.text('失败原因'), findsNothing);
    });

    testWidgets('★★ season 兜底必须显眼（不能和普通自动匹配长得一样）', (t) async {
      await t.pumpWidget(_host(
        const DanmakuInfoPanel(data: _fallback, initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(find.text('番剧季兜底'), findsOneWidget);
      expect(find.text('备用链路'), findsOneWidget,
          reason: '★ 兜底要有一枚显眼的标 —— 排查时最该被看见的就是它');
      // 阳性对照：普通自动匹配**不该**有这枚标
      await t.pumpWidget(_host(
        const DanmakuInfoPanel(data: _loaded, initiallyExpanded: true),
      ));
      await t.pumpAndSettle();
      expect(find.text('备用链路'), findsNothing);
    });

    testWidgets('★★ 失败原因要原文照透，且带 HTTP 码', (t) async {
      await t.pumpWidget(_host(
        const DanmakuInfoPanel(
          data: DanmakuInfoData(
            source: DanmakuSourceKind.service,
            match: DanmakuMatchKind.none,
            error: '弹幕服务没收到凭证（HTTP 403） · Missing Authentication Headers',
            enabled: true,
          ),
          initiallyExpanded: true,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.text('失败原因'), findsOneWidget);
      // ★ 原文必须逐字在（这是排查的全部价值）
      expect(
        find.textContaining('Missing Authentication Headers'),
        findsOneWidget,
        reason: '★ 服务端原文必须原样透出，不许改写/截断成"失败"',
      );
    });

    testWidgets('★ 未知条数画成「—」而不是 0（不许撒谎）', (t) async {
      await t.pumpWidget(_host(
        const DanmakuInfoPanel(
          data: DanmakuInfoData(
            source: DanmakuSourceKind.service,
            match: DanmakuMatchKind.none,
            // count 省略 = null = 未查询
          ),
          initiallyExpanded: true,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('未查询'), findsOneWidget,
          reason: '★ null 必须显示成"未查询"，不能显示 0');
    });

    testWidgets('★ 开关关着时必须说明「有数据也不会上屏」', (t) async {
      await t.pumpWidget(_host(
        const DanmakuInfoPanel(
          data: DanmakuInfoData(
            source: DanmakuSourceKind.bili,
            count: 10,
            // enabled 默认 false
          ),
          initiallyExpanded: true,
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('弹幕开关是关的'), findsOneWidget);
    });
  });

  // ════════════════════ 截图 ════════════════════
  group('面板 · 看图', () {
    for (final e in <MapEntry<String, DanmakuInfoData>>[
      const MapEntry<String, DanmakuInfoData>('loaded', _loaded),
      const MapEntry<String, DanmakuInfoData>('fallback', _fallback),
      const MapEntry<String, DanmakuInfoData>(
        'error',
        DanmakuInfoData(
          source: DanmakuSourceKind.service,
          match: DanmakuMatchKind.none,
          error: '弹幕服务没收到凭证（HTTP 403） · Missing Authentication Headers',
          enabled: true,
        ),
      ),
    ]) {
      testWidgets('SHOT ${e.key}', (t) async {
        await setShotViewport(t, const Size(420, 360));
        await t.pumpWidget(_host(
          Padding(
            padding: const EdgeInsets.all(12),
            child: DanmakuInfoPanel(data: e.value, initiallyExpanded: true),
          ),
        ));
        await t.pumpAndSettle();
        final f = await saveBoundaryShot(
          t,
          find.byKey(const ValueKey<String>('page')),
          'danmaku_info_${e.key}',
          pixelRatio: 2.0,
        );
        print('[shot] ${f.path} (${f.lengthSync()} B)');
        expect(f.lengthSync(), greaterThan(2000), reason: '疑似空图');
      });
    }
  });
}
