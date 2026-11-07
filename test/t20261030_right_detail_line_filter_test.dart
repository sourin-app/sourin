// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：1.1 右侧详情栏选集按线路过滤 + 1.2 集数徽标
// ═══════════════════════════════════════════════════════════════════════
//
// # 真机读数（不是编的 —— Owner 图5 兰香如故 / 图8 老舅）
// ```text
// 老舅：17 条线路 × 27 集 = 459 条（flag = BD/BF/…/YZ），
// 右侧详情栏把 459 条**全部平铺** ⇒ 「第01集」出现 17 次；
// 头部徽标写「459 集」（兰香如故 853）—— 多线路总数。
// ```
//
// # 判据
// ```text
// ① 右侧详情栏选集网格只画**当前线路**的 27 格：
//    · 播放器还没报当前集 ⇒ 第一条线路（与 PlayerEpisodePanel 同一兜底）；
//    · 播放器报了第二线路的某集 ⇒ 画那条线路（当前线路从播放态取）；
//    · 单线路源（flag 全空）⇒ 原样全部显示，一集不丢。
// ② 徽标：多线路 = 「本线路 N 集 · 共 M 条线路」；单线路 = 「N 集」。
// ```
//
// # 判据落在公共函数上（widgets/episode_filter.dart）
//
// 两条渲染路径（PlayerEpisodePanel / DetailPage._bodyEpisodes）共用同一份
// `episodesForLine` —— 纯函数用例直接钉它的语义（含 selectedFlag 失效兜底）。
//
// # 故障注入（2026-10-30 实测，见 .agents/notes/implemented/bug-fix/ 笔记）
// ```text
// 注入①：detail_page._bodyEpisodes 遍历对象改回 _episodes（全集）⇒ 组①红
//        （find.text('第01集') 变 17 个）；
// 注入②：_buildHeader 徽标退回 '$episodeCount 集' ⇒ 组②红
//        （找不到「本线路 27 集 · 共 17 条线路」）；
// 注入③：episode_filter.episodesForLine 恒返回 all ⇒ 组①③全红。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/widgets/episode_filter.dart';

// ── 老舅的真数据形状：17 线路 × 27 集 ──────────────────────────────────
const List<String> _lines = [
  'BD', 'BF', 'FF', 'HH', 'HN', 'JS', 'JY', 'KC', 'LZ',
  'MT', 'NN', 'SD', 'SN', 'UK', 'WJ', 'XL', 'YZ',
];

/// 每条线路的标题带**线路前缀**（真数据里各线路标题相同，
/// 但那样断言没法区分"画的是哪条线路"；前缀只服务判读，判据仍是 flag）
List<Episode> _episodes17x27() => [
      for (final line in _lines)
        for (var i = 1; i <= 27; i++)
          Episode(
            id: '$line|$i',
            title: '${line}_第${i.toString().padLeft(2, '0')}集',
            flag: line,
          ),
    ];

MediaDetail _detail(List<Episode> eps) => MediaDetail(
      id: 'cycani:3862',
      title: '老舅',
      description: '门禁夹具简介。',
      kind: 'series',
      episodes: eps,
    );

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

/// 挂真 DetailPage（embedded = 合并页右侧栏）+ 注入 eps；
/// [currentEpisodeId] 模拟播放器上报的"正在播的那一集"。
Future<void> _mount(
  WidgetTester t,
  List<Episode> eps, {
  String? currentEpisodeId,
  ValueChanged<String>? onPickLine,
}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final key = GlobalKey<State<DetailPage>>();
  await t.pumpWidget(_host(Scaffold(
    body: DetailPage(
      key: key,
      provider: 'cycani',
      id: '3862',
      embedded: true,
      currentEpisodeId: currentEpisodeId,
      onPickLine: onPickLine,
    ),
  )));
  await t.pump();
  final st = key.currentState!;
  // ignore: avoid_dynamic_calls
  (st as dynamic).debugSetDetail(_detail(eps), episodes: eps);
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

void main() {
  testWidgets('episode flags render as wrapping clickable lines and switch the episode list', (t) async {
    final picked = <String>[];
    await _mount(t, _episodes17x27(), onPickLine: picked.add);
    expect(find.text('播放线路'), findsOneWidget);
    await t.tap(find.text('BF').first);
    await t.pump();
    expect(picked, ['BF']);
    expect(find.text('BF_第01集'), findsOneWidget);
    expect(find.text('BD_第01集'), findsNothing);
    expect(t.takeException(), isNull);
  });
  group('episode_filter 纯函数（两渲染路径共用的判据本体）', () {
    test('effectiveFlag：合法 selectedFlag 直通', () {
      final eps = _episodes17x27();
      expect(effectiveFlag(eps, 'BF'), 'BF');
    });

    test('effectiveFlag：null / 指向不存在的线路 ⇒ 兜底第一条', () {
      final eps = _episodes17x27();
      expect(effectiveFlag(eps, null), 'BD');
      expect(effectiveFlag(eps, 'GONE'), 'BD',
          reason: '换源后 selectedFlag 停在旧值 ⇒ 判据层兜底，不许"列表全空"');
    });

    test('effectiveFlag：单线路源（flag 全空）⇒ null（原样返回）', () {
      final eps = [
        for (var i = 1; i <= 40; i++)
          Episode(id: 'e$i', title: '第$i集', flag: null),
      ];
      expect(effectiveFlag(eps, null), isNull);
      expect(episodesForLine(eps, null).length, 40,
          reason: '★ 防"修重复把集弄丢"');
    });

    test('episodesForLine / lineCountOf：17 线路 ⇒ 27 条 / 17', () {
      final eps = _episodes17x27();
      expect(episodesForLine(eps, null).length, 27);
      expect(lineCountOf(eps), 17);
    });

    test('episodeNumberOf：集号归一化（1.4 的判据底座）', () {
      expect(episodeNumberOf('第2集'), 2);
      expect(episodeNumberOf('第02集'), 2, reason: '零填充差异必须归一');
      expect(episodeNumberOf('01'), 1);
      expect(episodeNumberOf('1'), 1);
      expect(episodeNumberOf('第 12 话'), 12);
      expect(episodeNumberOf('EP3'), 3);
      expect(episodeNumberOf(null), isNull);
      expect(episodeNumberOf('预告'), isNull);
    });
  });

  group('① 右侧详情栏选集只画当前线路（真 DetailPage 渲染）', () {
    testWidgets('播放器未上报 ⇒ 第一条线路的 27 格，「第…集」不重复 17 次', (t) async {
      await _mount(t, _episodes17x27());

      // 铁律 149：先证明选集区真的渲染出来了
      expect(find.text('BD_第01集'), findsOneWidget);
      // ★ 核心断言：改前 17 条线路平铺 ⇒ 'BD_第01集' 只有 1 处、
      //   别的线路一条都不该出现
      expect(find.text('BF_第01集'), findsNothing,
          reason: 'BF 线路的集不该出现在 BD 线路的视图里（改前会出现 ⇒ 459 条平铺）');
      // 渲染出的集按钮总数 = 27（每格标题以「XX_第」开头，前缀 = 线路名）
      final rendered = find
          .byWidgetPredicate((w) =>
              w is Text && (w.data ?? '').startsWith('第') == false &&
              RegExp(r'^[A-Z]{2}_第\d{2}集$').hasMatch(w.data ?? ''))
          .evaluate()
          .length;
      expect(rendered, 27, reason: '右侧列表必须是 27 格，不是 459');
    });

    testWidgets('播放器报了 BF 线路的第 5 集 ⇒ 视图切到 BF 线路', (t) async {
      await _mount(
        t,
        _episodes17x27(),
        currentEpisodeId: 'BF|5',
      );
      expect(find.text('BF_第05集'), findsOneWidget,
          reason: '当前集必须可见（它属于 BF 线路 ⇒ 视图画 BF）');
      expect(find.text('BD_第01集'), findsNothing,
          reason: '播放器在播 BF ⇒ BD 线路的集不该再平铺出来');
    });

    testWidgets('单线路源（flag 全空）⇒ 全部照旧显示，不许丢集', (t) async {
      final eps = [
        for (var i = 1; i <= 40; i++)
          Episode(id: 'e$i', title: '第$i集', flag: null),
      ];
      await _mount(t, eps);
      expect(find.text('第1集'), findsOneWidget);
      expect(find.text('第40集'), findsOneWidget,
          reason: '第 40 集必须还在 —— 防"修重复把集弄丢"');
    });
  });

  group('② 集数徽标（1.2）', () {
    testWidgets('多线路源 ⇒ 「本线路 27 集 · 共 17 条线路」', (t) async {
      await _mount(t, _episodes17x27());
      expect(find.text('本线路 27 集 · 共 17 条线路'), findsOneWidget,
          reason: '徽标必须是"当前线路"的集数 + 线路总数，不是 459 那种全集总数');
      expect(find.text('459 集'), findsNothing,
          reason: '改前的多线路总数徽标不许再出现');
    });

    testWidgets('单线路源 ⇒ 「N 集」（与改前逐字一致）', (t) async {
      final eps = [
        for (var i = 1; i <= 40; i++)
          Episode(id: 'e$i', title: '第$i集', flag: null),
      ];
      await _mount(t, eps);
      expect(find.text('40 集'), findsOneWidget);
      expect(find.textContaining('本线路'), findsNothing,
          reason: '单线路没有"共 M 条线路"可报，不许画出来');
    });
  });
}
