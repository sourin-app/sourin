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
      // ★ 必须**有**订阅链接 —— 否则落到"无来源"那一态（见下一条）
      const never = TvboxSourceInfo(
        id: 'a',
        name: '甲',
        api: 'http://x',
        sourceUrl: 'http://cfg/1.json',
        needsSource: false,
      );
      expect(tvboxLastUpdateText(never), '从未更新');
      expect(tvboxLastUpdateFailed(never), isFalse);
    });

    /// ★ 真机判读打回的那一条（2026-11-01）
    ///
    /// ```text
    /// 真机 64 条子站是**贴配置文本导入**的 ⇒ source_url = None
    /// ⇒ 定时器第一道闸就把它们跳过 ⇒ 它们**永远**不会有章。
    /// 若统一显示「从未更新」，用户读到的是"还没轮到"，
    /// 而真相是"根本没有可更新的来源，也永远不会自动更新"
    /// ⇒ 那是把"不可能"说成"还没发生"（读数说谎）+ 用户不知去哪补救。
    /// ```
    test('没有订阅链接 ⇒ 如实报原因 + 给出路，**不是**「从未更新」', () {
      const noLink = TvboxSourceInfo(id: 'a', name: '甲', api: 'csp_X');
      expect(noLink.needsSource, isTrue);
      final got = tvboxLastUpdateText(noLink)!;
      expect(got, isNot('从未更新'),
          reason: '★ 缺链接 ≠ 还没更新过 —— 这两件事不许合并成一句');
      expect(got, contains('无法定时更新'), reason: '要说清后果：{got}');
      expect(got, contains('补'), reason: '要给出路（去哪儿补链接）：{got}');
      // 它是"配置缺失"，不是"运行故障" ⇒ 不许染成失败红
      expect(tvboxLastUpdateFailed(noLink), isFalse);
      expect(tvboxLastUpdateNoSource(noLink), isTrue);
    });

    test('「从未更新」与「缺链接」两态互不串台（有链接 + at=0 ≠ 缺链接）', () {
      const has = TvboxSourceInfo(
        id: 'a',
        name: '甲',
        api: 'http://x',
        sourceUrl: 'http://cfg/1.json',
        needsSource: false,
      );
      expect(tvboxLastUpdateText(has), '从未更新');
      expect(tvboxLastUpdateNoSource(has), isFalse);
      expect(tvboxLastUpdateFailed(has), isFalse);
    });

    test('成功 ⇒ 「上次更新：MM-dd HH:mm」；失败 ⇒ 失败文案 + failed=true', () {
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final secs =
          DateTime(now.year, now.month, now.day, 9, 30).millisecondsSinceEpoch ~/
              1000;
      /*
       * ★ 夹具必须**可能**：一个"已经更新过"的源必然有订阅链接
       *   （章是"核对某条链接"的产物 —— 没有链接的源永远不会有章）。
       *   少了 sourceUrl 的旧夹具之所以能过，是因为它们正好触发了本次要修的
       *   "把已更新也显示成缺链接"的歧义 —— 那正是判读打回的那类漏网。
       */
      final ok = TvboxSourceInfo(
        id: 'a',
        name: '甲',
        api: 'http://x',
        sourceUrl: 'http://cfg/1.json',
        needsSource: false,
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
        sourceUrl: 'http://cfg/1.json',
        needsSource: false,
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
        id: 'a',
        name: '甲',
        api: 'http://x',
        sourceUrl: 'http://cfg/1.json',
        needsSource: false,
        lastUpdateAt: secs,
        lastUpdateOk: true,
      );
      expect(tvboxLastUpdateText(s)!, contains('$lastYear-12-01 08:00'));
    });
  });

  /// ★ 聚合源（tvbox_agg）—— 真机判读打回的**第一条**
  ///
  /// ```text
  /// tvbox_agg 是 Rust 内置 provider ⇒ 不在 list_tvbox_sources 的 sources[]
  /// ⇒ 设置页 _tvboxSources['tvbox_agg'] == null ⇒ 「上次更新」整行不画
  ///   （功能加了但用户看不见 —— 打回的原话）。
  /// 修法：后端把它所含子站的章聚合成 max，走**顶层 aggregate 字段**下发；
  ///       Dart 侧解析成 TvboxSourceInfo，卡片对它单独取用。
  /// ```
  group('①+ 聚合源：解析 + 真实时间文案（不许「从未更新」兜底）', () {
    test('TvboxSourceList 解析顶层 aggregate（缺字段 ⇒ null，不伪造）', () {
      final l = TvboxSourceList.fromJson(<String, dynamic>{
        'sources': <dynamic>[],
        'total': 0,
        'withSource': 0,
        'aggregate': <String, dynamic>{
          'id': 'tvbox_agg',
          'lastUpdateAt': 1800000000,
          'lastUpdateOk': true,
          'lastUpdateError': null,
        },
      });
      expect(l.aggregate, isNotNull);
      expect(l.aggregate!.id, 'tvbox_agg');
      expect(l.aggregate!.lastUpdateAt, 1800000000);
      expect(l.aggregate!.lastUpdateOk, isTrue);

      // 旧核心没这个字段 ⇒ null（调用方据此不画，而不是显示"从未更新"）
      final old = TvboxSourceList.fromJson(<String, dynamic>{
        'sources': <dynamic>[],
      });
      expect(old.aggregate, isNull);
    });

    test('★ 聚合真实时间 ⇒ 文案是「上次更新：MM-dd HH:mm」，不含「从未更新」', () {
      final now = DateTime.now();
      String two(int n) => n.toString().padLeft(2, '0');
      final secs =
          DateTime(now.year, now.month, now.day, 9, 30).millisecondsSinceEpoch ~/
              1000;
      final agg = TvboxSourceInfo(
        id: 'tvbox_agg',
        name: 'TVBox 聚合',
        api: '',
        // ★ 后端显式给 needsSource=false（聚合源不是一条源，没有自己的链接）
        needsSource: false,
        lastUpdateAt: secs,
        lastUpdateOk: true,
      );
      final got = tvboxLastUpdateText(agg)!;
      expect(got, isNot('从未更新'),
          reason: '★ 聚合源更新过就必须显示真实时间 —— 恒显「从未更新」等于没修');
      expect(got, contains('上次更新'));
      expect(got, contains('${two(now.month)}-${two(now.day)} 09:30'));
      expect(tvboxLastUpdateFailed(agg), isFalse);
    });

    test('★ 任一子站上次失败 ⇒ 聚合标失败（定时一直在失败必须看得见）', () {
      final bad = TvboxSourceInfo(
        id: 'tvbox_agg',
        name: 'TVBox 聚合',
        api: '',
        needsSource: false,
        lastUpdateAt: 1800000000,
        lastUpdateOk: false,
        lastUpdateError: '下载配置失败：连接被拒',
      );
      expect(tvboxLastUpdateText(bad)!, contains('上次更新失败'));
      expect(tvboxLastUpdateFailed(bad), isTrue);
    });

    /// ★ 后端**必须**显式给 needsSource=false
    /// ```text
    /// TvboxSourceInfo.needsSource 的缺省是 true（`j['needsSource'] != false`）。
    /// 聚合源不是一条源、没有自己的链接 —— 但它也不"缺链接"（时间是子站给的）。
    /// 后端不给这个键 ⇒ 界面会对聚合源显示「无法定时更新，去补链接」
    /// ⇒ 把"不适用"说成"配置缺失"，用户会去补一个根本补不了的链接。
    /// ```
    test('聚合源不是「缺链接」态（后端显式 needsSource=false）', () {
      final agg = TvboxSourceInfo.fromJson(<String, dynamic>{
        'id': 'tvbox_agg',
        'name': 'TVBox 聚合',
        'api': '',
        'needsSource': false,
        'lastUpdateAt': 1800000000,
        'lastUpdateOk': true,
      });
      expect(agg.needsSource, isFalse);
      expect(tvboxLastUpdateNoSource(agg), isFalse);
      expect(tvboxLastUpdateText(agg), isNot(tvboxNoSourceHint),
          reason: '★ 聚合源不许显示"去补链接"—— 它的时间是子站聚合来的');
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

      /*
       * 旧后端（没有 lastUpdate 三件套）的**源条目**：
       * 它仍然带 sourceUrl（旧后端只是不认识新字段，不是没链接）
       * ⇒ 容错为「从未更新」，**不是**「无法定时更新」。
       *
       * ⚠️ 旧夹具这里没给 sourceUrl ⇒ 会被 needsSource 缺省成 true，
       *    于是断言的是"缺链接"那一态 —— 与本条的标题（缺字段容错）不符，
       *    而且正好掩盖了"有没有链接"这个判据。修夹具，不是修断言。
       */
      final old = TvboxSourceInfo.fromJson(<String, dynamic>{
        'id': 'tvbox2',
        'name': '乙站',
        'api': 'http://y/api',
        'sourceUrl': 'http://cfg/2.json',
        'needsSource': false,
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
        // ★ 有订阅链接 ⇒ 才是真正的"还没轮到更新"
        info: TvboxSourceInfo(
          id: 't1',
          name: '甲站',
          api: 'http://x',
          sourceUrl: 'http://cfg/1.json',
          needsSource: false,
        ),
      )));
      await tester.pump();
      final line = find.byKey(const ValueKey<String>('tvbox-manage-last-update'));
      expect(line, findsOneWidget);
      expect(tester.widget<Text>(line).data, '从未更新');
    });

    /// ★ 真机那 64 条的形态（贴文本导入、没有链接）
    testWidgets('没有订阅链接 ⇒ 行里写清原因 + 出路（不是「从未更新」）',
        (tester) async {
      await tester.pumpWidget(host(const TvboxSourceManagePanel(
        id: 't1',
        name: '甲站',
        info: TvboxSourceInfo(id: 't1', name: '甲站', api: 'csp_X'),
      )));
      await tester.pump();
      final line = find.byKey(const ValueKey<String>('tvbox-manage-last-update'));
      expect(line, findsOneWidget, reason: '缺链接也是一种状态，行必须画出来');
      final got = tester.widget<Text>(line).data!;
      expect(got, isNot('从未更新'), reason: '★ 不许把"不可能"说成"还没发生"');
      expect(got, contains('无法定时更新'));
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
          // ★ 同纯函数那组：更新过的源必然有链接（否则夹具不可能存在）
          sourceUrl: 'http://cfg/1.json',
          needsSource: false,
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
      // ★ 聚合源走 `_tvboxSourceOf(...)`（它不在 sources[] 里），
      //   其余 id 走 `_tvboxSources[...]` ⇒ 两处的**总调用数**仍是 2。
      final n = RegExp(r'tvboxSource: _tvboxSource(?:s\[|Of\()')
          .allMatches(src)
          .length;
      expect(n, 2, reason: '内容源网格 + 直播源列表都要接线（实测两处）：实际 $n');
      expect(src.contains('_tvboxSourceOf(visible[i].id)'), isTrue,
          reason: '内容源网格要走分派（聚合源才能拿到时间）');
      expect(src.contains('_tvboxSourceOf(live[i].id)'), isTrue,
          reason: '直播源列表要走分派');
    });

    /// ★ 聚合源接线的**关键**判据：
    /// ```text
    /// ① settings 必须真的存下后端给的聚合信息（否则卡片永远 null ⇒ 行不画）
    /// ② 分派只能认 kTvboxAggregateId（别把别的源也分派过去）
    /// ③ 聚合**不许**进 _tvboxSources（否则卡片多出必然报错的"检测更新"按钮）
    /// ```
    test('聚合源：存得下 + 只分派 tvbox_agg + 不混进 _tvboxSources', () {
      expect(src.contains('TvboxSourceInfo? _tvboxAggregateSource'), isTrue,
          reason: '必须有地方存聚合源的订阅信息');
      /*
       * ★ 判据必须**排除注释行**：只写 `src.contains(...)` 的话，
       *   把那行注释掉（典型的"拉到了但没存"）照样绿 ——
       *   本条要防的正是这种"看着接线了、其实没接线"。
       *   ⇒ 按行取 trim 后的**行首**比较（`//` 开头的行不匹配）。
       */
      final codeLines = src
          .split('\n')
          .map((l) => l.trim())
          .where((l) => !l.startsWith('//'))
          .toList();
      expect(
        codeLines.contains('_tvboxAggregateSource = aggregateSource;'),
        isTrue,
        reason: '★ 拉到的聚合信息必须真的存进 state（排除注释行 —— 写了 ≠ 接线了）',
      );
      expect(
        codeLines.any((l) => l.startsWith('aggregateSource = tvs.aggregate;')),
        isTrue,
        reason: '★ 必须从 listTvboxSources 的顶层字段取（不在 sources[] 里）',
      );
      expect(src.contains("id == kTvboxAggregateId"), isTrue,
          reason: '分派必须正向列举 tvbox_agg（不是放宽通用判据）');
      // 聚合不许被塞进 _tvboxSources —— 那会让卡片多出必然报错的按钮
      final assign = RegExp(r'_tvboxSources\[[^\]]*\] = ')
          .allMatches(src)
          .map((m) => m.group(0) ?? '')
          .toList();
      expect(
        assign.any((a) => a.contains('tvbox_agg')),
        isFalse,
        reason: '★ 聚合源不许被塞进 _tvboxSources（会多出必然报错的「检测更新」按钮）',
      );
    });

    test('聚合二级页也显示了「上次更新」（同口径，两处不漂移）', () {
      final aggSrc =
          File('lib/ui/settings/tvbox_aggregate_page.dart').readAsStringSync();
      expect(aggSrc.contains("'agg-last-update'"), isTrue,
          reason: '聚合页必须画出「上次更新」行');
      expect(aggSrc.contains('tvboxLastUpdateText(_aggregateSource)'), isTrue,
          reason: '★ 文案必须复用 tvboxLastUpdateText（与设置页同一份口径，不许另写一遍）');
      expect(aggSrc.contains('aggregateSource = l.aggregate'), isTrue,
          reason: '★ 聚合页也要从顶层字段取（不是自己造）');
    });

    test('卡片渲染块真的在（_tvboxUpdatedLine 条件渲染）', () {
      expect(src.contains("if (_tvboxUpdatedLine != null)"), isTrue,
          reason: '渲染块必须在卡片 build 里');
      expect(src.contains('const TvboxAutoUpdateRow()'), isTrue,
          reason: '设置行必须真的插进源区块');
    });
  });
}
