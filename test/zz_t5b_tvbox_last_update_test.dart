// ═══════════════════════════════════════════════════════════════════════
//  T5 门禁：源上次更新时间显示 + 订阅定时自动更新
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话：「源 里面的没有显示上次更新时间，这个要显示出来,定时更新」
//
// 本文件钉四层：
// ```text
// ① 纯函数口径   tvboxLastUpdateText / tvboxLastUpdateFailed /
//                TvboxAutoUpdateRow.intervalLabel（卡片行与管理面板的单一事实源）
// ② 模型解析     TvboxSourceInfo 新字段（缺省容错）+ TvboxUpdateSchedule 默认值
// ③ 真渲染       TvboxSourceManagePanel（info 三态）+ TvboxAutoUpdateRow
//                （开关/档位写配置、写失败显示错误行 —— 注入替身，不碰核心）
// ④ 接线         settings_page.dart 源卡片真的传了 tvboxSource（两处调用点）
//                + 设置行真的插进了源区块（防"写了≠接线了"）
// ```
// 到点判定的注入证红在 cargo 侧（tvbox::tests::t5_due_judgment）。

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/shell.dart' show kAppLocalizationsDelegates;
import 'package:sourin_spike/ui/settings_page.dart'
    show TvboxAutoUpdateRow;
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

/// 测试宿主：material_ui 组件要的是 **material_ui 自己的** MaterialLocalizations
/// （flutter 的 MaterialApp 默认不提供这个类型 —— 见
/// test/zz_t66_material_localizations_test.dart 与 shell.dart 的决策笔记），
/// 所以挂真 App 的同一组 delegates；Material 用 mui 的（ChoiceChip/TextField 的
/// debug 检查按自己的类型找）；外面包滚动 —— 面板内容超过 600 高的测试视口。
Widget _host(Widget child) => Localizations(
      locale: const Locale('zh', 'CN'),
      delegates: kAppLocalizationsDelegates,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: mui.Material(
          // ★ Tooltip 需要 Overlay 祖先（失败行的原因挂在 Tooltip 里）——
          //   生产在 Navigator 下天然有，测试宿主要自己给。
          child: Overlay(
            initialEntries: <OverlayEntry>[
              OverlayEntry(builder: (_) => SingleChildScrollView(child: child)),
            ],
          ),
        ),
      ),
    );

void main() {
  group('① 纯函数口径：tvboxLastUpdateText / tvboxLastUpdateFailed', () {
    test('info 为 null ⇒ 整行不画（非 TVBox 源零回归）', () {
      expect(tvboxLastUpdateText(null), isNull);
      expect(tvboxLastUpdateFailed(null), isFalse);
    });

    test('从未更新（lastUpdateAt == 0）⇒ 「从未更新」，不是假时间', () {
      const never = TvboxSourceInfo(id: 'a', name: '甲', api: 'http://x');
      expect(tvboxLastUpdateText(never), '从未更新');
      expect(tvboxLastUpdateFailed(never), isFalse);
    });

    test('成功 ⇒ 「上次更新：MM-dd HH:mm」；失败 ⇒ 失败文案 + failed=true', () {
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final secs =
          DateTime(now.year, now.month, now.day, 9, 30).millisecondsSinceEpoch ~/
              1000;
      final ok = TvboxSourceInfo(
        id: 'a',
        name: '甲',
        api: 'http://x',
        lastUpdateAt: secs,
        lastUpdateOk: true,
      );
      final got = tvboxLastUpdateText(ok)!;
      expect(got, contains('上次更新'));
      expect(got, isNot(contains('失败')));
      expect(
        got,
        contains('${two(now.month)}-${two(now.day)} 09:30'),
        reason: '本次运行年份内 ⇒ 不带年份：$got',
      );
      expect(tvboxLastUpdateFailed(ok), isFalse);

      final bad = TvboxSourceInfo(
        id: 'a',
        name: '甲',
        api: 'http://x',
        lastUpdateAt: secs,
        lastUpdateOk: false,
        lastUpdateError: '下载配置失败：连接被拒',
      );
      expect(tvboxLastUpdateText(bad)!, contains('上次更新失败'));
      expect(tvboxLastUpdateFailed(bad), isTrue,
          reason: '失败必须能被调用方识别并红色渲染');
    });

    test('跨年 ⇒ 带年份（"去年"不许读成"今年"）', () {
      final lastYear = DateTime.now().year - 1;
      final secs = DateTime(lastYear, 12, 1, 8, 0).millisecondsSinceEpoch ~/ 1000;
      final s = TvboxSourceInfo(
        id: 'a', name: '甲', api: 'http://x', lastUpdateAt: secs, lastUpdateOk: true,
      );
      expect(tvboxLastUpdateText(s)!, contains('$lastYear-12-01 08:00'));
    });
  });

  group('① 档位：TvboxAutoUpdateRow.intervalLabel', () {
    test('三个档位 = 关/6h/12h/24h 里的 6/12/24（关由开关表达）', () {
      expect(TvboxAutoUpdateRow.kIntervalChoices,
          unorderedEquals(<int>[21600, 43200, 86400]));
      expect(TvboxAutoUpdateRow.intervalLabel(21600), '6 小时');
      expect(TvboxAutoUpdateRow.intervalLabel(43200), '12 小时');
      expect(TvboxAutoUpdateRow.intervalLabel(86400), '24 小时');
    });

    test('未知值按小时数如实折算（不编「其它」）', () {
      expect(TvboxAutoUpdateRow.intervalLabel(28800), '8 小时');
    });
  });

  group('② 模型解析', () {
    test('TvboxSourceInfo：lastUpdate 三字段解析 + 缺省容错', () {
      final full = TvboxSourceInfo.fromJson(<String, dynamic>{
        'id': 'tvbox1',
        'name': '甲站',
        'api': 'http://x/api',
        'sourceUrl': 'http://cfg/1.json',
        'needsSource': false,
        'lastUpdateAt': 1800000000,
        'lastUpdateOk': false,
        'lastUpdateError': ' 下载配置失败（http://cfg/1.json）：超时 ',
      });
      expect(full.lastUpdateAt, 1800000000);
      expect(full.lastUpdateOk, isFalse);
      expect(full.lastUpdateError, '下载配置失败（http://cfg/1.json）：超时');

      // 旧后端 / 旧文件没有这些键 ⇒ 容错为「从未更新」
      final old = TvboxSourceInfo.fromJson(<String, dynamic>{
        'id': 'tvbox2',
        'name': '乙站',
        'api': 'http://y/api',
      });
      expect(old.lastUpdateAt, 0);
      expect(old.lastUpdateOk, isFalse);
      expect(old.lastUpdateError, isNull);
      expect(tvboxLastUpdateText(old), '从未更新');
    });

    test('TvboxUpdateSchedule：解析 + 缺省 = 开 + 24h（Lead 批复的默认档位）', () {
      const d = TvboxUpdateSchedule();
      expect(d.enabled, isTrue, reason: '默认必须开（关是用户的明确动作）');
      expect(d.intervalSecs, 86400);
      final j = TvboxUpdateSchedule.fromJson(<String, dynamic>{
        'enabled': false,
        'intervalSecs': 21600,
      });
      expect(j.enabled, isFalse);
      expect(j.intervalSecs, 21600);
      // 坏/缺键回退默认
      final fallback = TvboxUpdateSchedule.fromJson(<String, dynamic>{});
      expect(fallback.enabled, isTrue);
      expect(fallback.intervalSecs, 86400);
    });
  });

  group('③ 真渲染：TvboxSourceManagePanel 的「上次更新」行', () {
    // ★ 宿主两件套（material_ancestor_test 同款教训）：
    //   ① ChoiceChip/输入行需要显式 Material 祖先（Scaffold 自带的不够）；
    //   ② 面板内容超过 600 高的测试视口 ⇒ 包一层滚动（生产里它在滚动页内）。
    //   统一走顶层 _host（material_ui 自己的 Localizations delegates）。
    Widget host(Widget child) => _host(child);

    testWidgets('info == null ⇒ 不画（旧调用点零回归）', (tester) async {
      await tester.pumpWidget(host(const TvboxSourceManagePanel(
        id: 't1',
        name: '甲站',
      )));
      await tester.pump();
      expect(find.byKey(const ValueKey<String>('tvbox-manage-last-update')),
          findsNothing);
    });

    testWidgets('从未更新 ⇒ 显示「从未更新」', (tester) async {
      await tester.pumpWidget(host(const TvboxSourceManagePanel(
        id: 't1',
        name: '甲站',
        info: TvboxSourceInfo(id: 't1', name: '甲站', api: 'http://x'),
      )));
      await tester.pump();
      final line = find.byKey(const ValueKey<String>('tvbox-manage-last-update'));
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).data, '从未更新');
    });

    testWidgets('失败 ⇒ 失败文案（信息本体在纯函数里钉过，这里钉"行真的画出来"）',
        (tester) async {
      await tester.pumpWidget(host(const TvboxSourceManagePanel(
        id: 't1',
        name: '甲站',
        info: TvboxSourceInfo(
          id: 't1',
          name: '甲站',
          api: 'http://x',
          lastUpdateAt: 1800000000,
          lastUpdateOk: false,
          lastUpdateError: '下载配置失败：连接被拒',
        ),
      )));
      await tester.pump();
      final line = find.byKey(const ValueKey<String>('tvbox-manage-last-update'));
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).data!, contains('上次更新失败'));
    });
  });

  group('③ 真渲染：TvboxAutoUpdateRow（替身注入，不碰核心）', () {
    tearDown(() {
      SourinApi.debugTvboxScheduleFetcher = null;
      SourinApi.debugTvboxScheduleSetter = null;
    });

    testWidgets('开关关掉 ⇒ 写入 enabled=false；档位点击 ⇒ 写入对应秒数',
        (tester) async {
      SourinApi.debugTvboxScheduleFetcher =
          () async => const TvboxUpdateSchedule(enabled: true, intervalSecs: 86400);
      bool? savedEnabled;
      int? savedSecs;
      SourinApi.debugTvboxScheduleSetter = (enabled, secs) async {
        savedEnabled = enabled;
        savedSecs = secs;
        return TvboxUpdateSchedule(enabled: enabled, intervalSecs: secs);
      };

      await tester.pumpWidget(_host(const TvboxAutoUpdateRow()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('tvbox-auto-update-row')),
          findsOneWidget);

      // 档位：点 6 小时 ⇒ 写 21600
      await tester.tap(
          find.byKey(const ValueKey<String>('tvbox-auto-update-interval-21600')));
      await tester.pumpAndSettle();
      expect(savedSecs, 21600, reason: '档位点击必须真的落配置');

      // 开关关掉 ⇒ enabled=false
      await tester.tap(find.byKey(const ValueKey<String>('tvbox-auto-update-switch')));
      await tester.pumpAndSettle();
      expect(savedEnabled, false, reason: '关掉必须真的落配置');
    });

    testWidgets('写失败 ⇒ 显示错误行（用户点了必须有回音，不许静默）', (tester) async {
      SourinApi.debugTvboxScheduleFetcher =
          () async => const TvboxUpdateSchedule(enabled: true, intervalSecs: 86400);
      SourinApi.debugTvboxScheduleSetter =
          (enabled, secs) async => throw Exception('core exploded');
      await tester.pumpWidget(_host(const TvboxAutoUpdateRow()));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey<String>('tvbox-auto-update-switch')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('tvbox-auto-update-error')),
          findsOneWidget, reason: '写失败必须有可见回音');
    });

    testWidgets('读不到配置 ⇒ 组件零尺寸（附加信息不拖垮源列表）', (tester) async {
      SourinApi.debugTvboxScheduleFetcher =
          () async => throw Exception('no core');
      await tester.pumpWidget(_host(const TvboxAutoUpdateRow()));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<String>('tvbox-auto-update-row')),
          findsNothing);
    });
  });

  group('④ 接线（写了 ≠ 接线了）：settings_page.dart 源文件自证', () {
    // 门禁不 import settings_page 的私有类（_ProviderCard 是私有的），
    // 改读**真实源码文本**钉两处调用点 + 渲染块 + 设置行（zz_t1048 同款判据）。
    final src = File('lib/ui/settings_page.dart').readAsStringSync();

    test('源卡片两处调用点都传了 tvboxSource', () {
      final n = 'tvboxSource: _tvboxSources['.allMatches(src).length;
      expect(n, 2, reason: '内容源网格 + 直播源列表都要接线（实测两处）：实际 $n');
    });

    test('卡片渲染块真的在（_tvboxUpdatedLine 条件渲染）', () {
      expect(src.contains("if (_tvboxUpdatedLine != null)"), isTrue,
          reason: '渲染块必须在卡片 build 里');
      expect(src.contains('const TvboxAutoUpdateRow()'), isTrue,
          reason: '设置行必须真的插进源区块');
    });
  });
}
