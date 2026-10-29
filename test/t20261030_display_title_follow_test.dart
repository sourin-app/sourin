// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：标题跟随自动连播（Owner 解锁授权）
//  CCTV 类源 detail.title 内嵌「第N集」⇒ 展示层剥后缀 + 缀当前在播集
// ═══════════════════════════════════════════════════════════════════════
//
// # 真机读数（repro14-20261030-004500.state.json / audit #4）
// ```text
// /api/state: title="《老舅》 第1集" 而 episode_order=3 —— 自动连播后标题陈旧。
// 根因：CCTV 类源一集一个详情，detail.title 把集数编进标题；title 是加载快照。
// ```
//
// # 判据（原则：不改写 _title 本体，只展示层拼装）
// ```text
// ① 纯函数 showTitleOf：title 以某条**含数字**集标题逐字结尾才剥（防剧名
//    尾部撞短集名误剥，如《西游记》/「记」）；普通源原样；
// ② detailDisplayTitle：剥掉才缀当前集；当前集=内嵌那集 ⇒ 往返恒等；
// ③ 真 _remoteGetState：连播推进后 title=「《老舅》 第3集」（order 实时）；
// ④ 真顶栏：剧名「《老舅》」与集名「第3集」分离渲染；
// ⑤ 真右栏（DetailPage）：currentEpisodeId 推进 ⇒ 标题跟随。
// ```
//
// # 故障注入（实测见笔记）
// ```text
// 注入①：_remoteGetState 退回 title: _title ⇒ 组②红；
// 注入②：_TopBar 退回 title: _liveTitle ⇒ 组③红；
// 注入③：DetailPage 头部退回 detail.title ⇒ 组④红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/widgets/episode_filter.dart';

// ═══════════════════════════════════════════════════════════════════════
//  libmpv 夹具（同 t72 —— 缺夹具 skip，不假红）
// ═══════════════════════════════════════════════════════════════════════

List<String> _libmpvCandidates() => Platform.isWindows
    ? <String>[
        r'build\windows\x64\libmpv\libmpv-2.dll',
        r'build\windows\x64\runner\Release\libmpv-2.dll',
      ]
    : <String>['/usr/lib/x86_64-linux-gnu/libmpv.so.2'];

String? _libmpv;

void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      return;
    }
  }
}

bool _requireLibmpv() => _libmpv != null;

/// CCTV 形态：剧集标题是朴素「第N集」，detail.title 内嵌「第1集」
List<Episode> _cctvEps() => [
      for (var i = 1; i <= 3; i++) Episode(id: 'ep$i', title: '第$i集'),
    ];

void main() {
  setUpAll(_prepareLibmpvFixture);

  group('① 纯函数（展示层剥离/拼装）', () {
    test('showTitleOf：CCTV 形态剥掉内嵌集数后缀', () {
      expect(showTitleOf('《老舅》 第1集', _cctvEps()), '《老舅》');
    });

    test('showTitleOf：普通源（纯剧名）原样，展示零变化', () {
      expect(showTitleOf('思君如故', _cctvEps()), '思君如故');
    });

    test('showTitleOf：剧名尾部撞上**不含数字**的短集名 ⇒ 不剥（防误伤）', () {
      final eps = [const Episode(id: 'e1', title: '记')];
      expect(showTitleOf('西游记', eps), '西游记',
          reason: '判据=集标题必须含数字（episodeNumberOf 同源），'
              '否则剧名尾字撞集名会把剧剥坏');
    });

    test('showTitleOf：title 与集标题全等 ⇒ 剥出空 ⇒ 原样（不返回空串）', () {
      final eps = [const Episode(id: 'e1', title: '第1集')];
      expect(showTitleOf('第1集', eps), '第1集');
    });

    test('detailDisplayTitle：剥掉后缀 + 缀当前在播集（自动连播跟随）', () {
      expect(detailDisplayTitle('《老舅》 第1集', _cctvEps(), '第3集'),
          '《老舅》 第3集');
    });

    test('detailDisplayTitle：当前集=内嵌那集 ⇒ 往返恒等', () {
      expect(detailDisplayTitle('《老舅》 第1集', _cctvEps(), '第1集'),
          '《老舅》 第1集');
    });

    test('detailDisplayTitle：没剥掉（普通源）⇒ 原样（连当前集都不缀）', () {
      expect(detailDisplayTitle('思君如故', _cctvEps(), '第3集'), '思君如故',
          reason: '普通源的右栏标题本来就不带集数 ⇒ 展示零变化');
    });
  });

  group('② 真 _remoteGetState：遥控 title 随连播推进', () {
    testWidgets('order 推进后 title=「《老舅》 第3集」', (t) async {
      if (!_requireLibmpv()) return;
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final episodes = _cctvEps();
      await t.pumpWidget(MaterialApp(
        home: PlayerPage(
          provider: 'cctv',
          id: 'cctv-1',
          title: '标题跟随测试',
          episodes: episodes,
          episodeIndex: 0,
          episodeId: episodes.first.id,
          episodeTitle: episodes.first.title,
          isTv: false,
          isTouchOnly: false,
        ),
      ));
      await t.pump();
      debugPlayerClearErrorForProbe();
      // ★ 走生产写入点：详情加载后的标题快照（CCTV 形态：内嵌「第1集」）
      final el = t.element(find.byType(PlayerPage)) as StatefulElement;
      // ignore: avoid_dynamic_calls
      (el.state as dynamic).updateDisplayTitle('《老舅》 第1集');
      await t.pump();

      final st0 = debugPlayerRemoteStateForProbe();
      expect(st0.hasMedia, isTrue, reason: '前提：探针拿到真实 state');
      expect(st0.title, '《老舅》 第1集',
          reason: '正在播第 1 集 ⇒ 拼装结果与原串逐字相同（往返恒等）');

      // ★ 自动连播推进（生产 state：_epIndex → 2，即第3集）
      expect(debugPlayerSetEpisodesForProbe(_cctvEps(), index: 2), isTrue);
      final st1 = debugPlayerRemoteStateForProbe();
      expect(st1.episodeOrder, 3, reason: '前提：order 实时准确（此前已钉）');
      expect(st1.title, '《老舅》 第3集',
          reason: '★★ 连播到第 3 集 ⇒ 遥控 title 必须跟随（改前仍「第1集」—— '
              'audit #4 的缺陷本体）');
    });
  });

  group('③ 真顶栏：剧名与集名分离（剧名不再内嵌旧集数）', () {
    testWidgets('推进后顶栏剧名=「《老舅》」、集名=「第3集」', (t) async {
      if (!_requireLibmpv()) return;
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final episodes = _cctvEps();
      await t.pumpWidget(MaterialApp(
        home: PlayerPage(
          provider: 'cctv',
          id: 'cctv-1',
          title: '标题跟随测试',
          episodes: episodes,
          episodeIndex: 0,
          episodeId: episodes.first.id,
          episodeTitle: episodes.first.title,
          isTv: false,
          isTouchOnly: false,
        ),
      ));
      await t.pump();
      debugPlayerClearErrorForProbe();
      final el = t.element(find.byType(PlayerPage)) as StatefulElement;
      // ignore: avoid_dynamic_calls
      (el.state as dynamic).updateDisplayTitle('《老舅》 第1集');
      expect(debugPlayerSetEpisodesForProbe(_cctvEps(), index: 2), isTrue);
      // 触发一次重建（探针本身 setState ⇒ 顶栏树读到新 title）
      debugPlayerSetStreamsForProbe(const [
        StreamCandidate(url: 'https://x.invalid/1.m3u8'),
      ]);
      await t.pump();

      expect(find.text('《老舅》'), findsOneWidget,
          reason: '★★ 顶栏剧名必须剥掉内嵌的「第1集」（改前显示整串陈旧标题）');
      expect(find.text('《老舅》 第1集'), findsNothing,
          reason: '陈旧快照不许再出现在顶栏');
      expect(find.text('第3集'), findsOneWidget,
          reason: '集名由 episodeTitle 独立渲染（实时）');
    });
  });

  group('④ 真右栏（DetailPage）：标题随 currentEpisodeId 跟随', () {
    testWidgets('ep1 → ep3 ⇒ 头部「《老舅》 第3集」', (t) async {
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final theme = AppTheme.themeFor(Brightness.dark);
      Widget host(Widget child) => MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            builder: (_, c) =>
                AppThemeHost(data: theme, child: c ?? const SizedBox()),
            home: child,
          );
      final key = GlobalKey<State<DetailPage>>();
      Widget page(String currentId) => Scaffold(
            body: DetailPage(
              key: key,
              provider: 'cctv',
              id: '3862',
              embedded: true,
              currentEpisodeId: currentId,
            ),
          );

      await t.pumpWidget(host(page('ep1')));
      await t.pump();
      final st = key.currentState!;
      // ignore: avoid_dynamic_calls
      (st as dynamic).debugSetDetail(
        const MediaDetail(id: 'cctv:3862', title: '《老舅》 第1集', kind: 'series'),
        episodes: _cctvEps(),
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('《老舅》 第1集'), findsOneWidget,
          reason: '在播第 1 集 ⇒ 往返恒等（显示与原串一致）');

      // ★ 自动连播：播放器上报 currentEpisodeId=ep3（media_page 同一通路）
      await t.pumpWidget(host(page('ep3')));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));

      expect(find.text('《老舅》 第3集'), findsOneWidget,
          reason: '★★ 连播到第 3 集 ⇒ 右栏标题必须跟随（audit #4 的缺陷本体）');
      expect(find.text('《老舅》 第1集'), findsNothing,
          reason: '陈旧标题不许残留');
    });
  });
}
