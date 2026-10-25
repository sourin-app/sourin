@Tags(['native-media'])

// ══════════════════════════════════════════════════════════════════════
//  t27_w9 —— ★★★ T27-09 门禁：顶栏/底栏显隐联动（Owner 第 9 条）
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 报（逐字）
// ```text
// > 9.上面这个出现,下面的操作没一起联动显示
// ```
//
// # 真值表（门禁按它逐组合断言）
//
// 记号：C=_controlsVisible，err=_error!=null，F1..F7 = 7 个浮层 flag
// （选集 episode / 设置 settings / 线路 stream / 直播 liveChannels /
//   弹幕 danmaku / B站 bili / 字幕 subtitle）。
// ⚠️ _hintsOpen/_zoomOpen **不在**底栏门控里（不在 F1..F7 之列）。
//
// ```text
// 顶栏 visible = (C && !err && !notice && !dead) || _canUseTopBarBack
//   _canUseTopBarBack = Device.isDesktop && err && !anyF && C
// 底栏挂载     = C && !err && !F1 && !F2 && !F3 && !F4 && !F5 && !F6 && !F7
//                && _liveAudioOnlyNotice == null && !_videoOutputDead
// ```
// ★ 2026-10-11 缺陷④：顶栏正常支也 AND 上 `!_liveAudioOnlyNotice && !_videoOutputDead`
//   （原为 `(C && !err) || …`）⇒ 两条降级横幅出现时顶栏与底栏**一起收**。
//   `_canUseTopBarBack`（错误态返回口）**不**被 AND —— 它与正常支互斥。
//   ⚠️ S5 的真值表只扫 (err, desktop, F1..F7)，**不含** notice/dead 两维；
//      这两维的联动由 t27_w13_defect4_bar_linkage_test.dart 单独门禁。
//
// **修复的语义**（本门禁钉死的耦合）：任何一个 F 打开时，生产 open 点
// 必须把 C 一并收掉 ⇒ 「浮层开着」这个状态在修复后**只能**与 C=false
// 同时出现。于是对全部 (err, desktop, F1..F7) ∈ 2^9 组合：
//
// ```text
// 令 C_eff = 打开过浮层之后的 C = !anyF（打开前 C=true）
// top   = (C_eff && !err) || (desktop && err && !anyF && C_eff)
// bottom = C_eff && !err && !anyF
// 断言 top == bottom，唯一例外（登记特例）：
//   desktop && err && !anyF ⇒ top=1 / bottom=0（错误返回口，故意保留顶栏）
// ```
//
// # 为什么修法是「open 点收 C」而不是抽判据 getter
// t118⑧ 逐字钉死 '(_controlsVisible && _error == null) ||'、
// 'if (_controlsVisible &&'、'_canUseTopBarBack,'，⑨ 钉 _autoHideNow 字面；
// 且修复后两栏真源本来就是**同一个字段** C —— 无需新 getter。
//
// # 关于「真点按钮」这条路径
// flutter_tester 里 PlayerPage 整棵树的指针回调不被调用（见 t98 文件头），
// 且 _load() 必然失败（sourin_core.dll error 126）⇒ _error 恒非空。
// ⇒ 行为组用 debugPlayerForceBarsForShot() 离开错误态（唯一入口），
//   用生产 open/close 探针驱动浮层（与用户点按钮同一个字段、同一段 build）。
//
// ⚠️ 必须带 @Tags(['native-media']) 并用 --run-skipped --tags native-media 跑
//    （dart_test.yaml: 该标签默认 skip）；测试一律 --concurrency=1。
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

// ═══════════════════════════════════════════════════════════════════════
//  源码切片工具（stripComments 逐字照抄 t68_android_adapt_test.dart:65-114，
//  即 player_capability_test.dart:61-110 的已验证实现）
// ═══════════════════════════════════════════════════════════════════════

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释（保留字符串字面量）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 断言 needle 恰好出现 want 次，返回首次下标
int indexOfExactly(String src, String needle, {int want = 1, String? why}) {
  final found = <int>[];
  var from = 0;
  while (true) {
    final i = src.indexOf(needle, from);
    if (i < 0) break;
    found.add(i);
    from = i + needle.length;
  }
  expect(found.length, want,
      reason: why ?? '「$needle」应恰好出现 ' + want.toString() + ' 次，实测 ' + found.length.toString() + ' 次');
  return found.isEmpty ? -1 : found.first;
}

/// 取 start 之后第一个 open 到配平 close 的文本
String sliceBalanced(String src, int start, String open, String close) {
  final begin = src.indexOf(open, start);
  expect(begin, greaterThanOrEqualTo(0), reason: '找不到「$open」');
  var depth = 0;
  for (var i = begin; i < src.length; i++) {
    if (src.startsWith(open, i)) {
      depth++;
      i += open.length - 1;
      continue;
    }
    if (src.startsWith(close, i)) {
      depth--;
      if (depth == 0) return src.substring(begin, i + close.length);
      i += close.length - 1;
    }
  }
  fail('括号没配平：从 $begin 起');
}

/// 取函数签名之后的整个函数体
String fnBody(String src, String signature) {
  final i = indexOfExactly(src, signature, why: '找不到签名 $signature');
  return sliceBalanced(src, i, '{', '}');
}

const String _pagePath = 'lib/ui/player_page.dart';

const List<String> kSheetNames = [
  '选集 episode',
  '设置 settings',
  '线路 stream',
  '所有直播 liveChannels',
  '弹幕设置 danmaku',
  'B站弹幕 bili',
  '字幕搜索 subtitle',
];

// ═══════════════════════════════════════════════════════════════════════
//  夹具（与 t98 同构）
// ═══════════════════════════════════════════════════════════════════════

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(
          id: 'ep$i',
          title: '第$i集',
          url: 'https://example.invalid/$i.m3u8',
        ),
    ];

Future<void> mountPlayer(WidgetTester t) async {
  // ★ T27-14：唯一加载点（惰性）—— 默认套件（用例全 skip）走不到 mountPlayer，
  //   进程里一次都不装 libmpv（崩溃门禁见 main() 上方注释）。
  _ensureLibmpvLoaded();
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '联动测试',
        episodes: fakeEpisodes(2),
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

/// 把 3 秒自动隐藏之类的挂起计时器推完，免得报 pending timer
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

/// 底栏挂载判据：_BottomBar 是私有类 ⇒ 用 runtimeType 名字匹配
final Finder bottomBar = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_BottomBar',
);

Future<void> forceBars(WidgetTester t) async {
  expect(debugPlayerForceBarsForShot(), isTrue,
      reason: 'flutter_tester 里 _load 必败 ⇒ 必须用截图探针离开错误态');
  await t.pump();
  await t.pump();
}

// ══════════════════════════════════════════════════════════════════════
//  ★ T27-14 惰性加载（t61_panel_radius_test.dart:205-242 同款形状）：
//  旧写法 setUpAll 里 MediaKit.ensureInitialized ⇒ 默认套件（用例全被
//  native-media 标签 skip）也把 libmpv-2.dll 装进了 flutter_tester 进程；
//  该 DLL 在 flutter_tester 里有仓库既有的 native 崩溃（c0000005，见
//  dart_test.yaml 顶部）⇒ 拆成两步：setUpAll 只「探测路径」；真加载
//  挪到 mountPlayer 首行的 _ensureLibmpvLoaded()（惰性 + 幂等），
//  默认套件一次都不加载。
// ══════════════════════════════════════════════════════════════════════

/// 探测到的 libmpv 绝对路径；`null` = 夹具缺失
String? _libmpv;

/// 惰性加载标志：true = MediaKit.ensureInitialized 已在本进程执行过
bool _libmpvLoaded = false;

/// setUpAll 用：**只探测路径，绝不加载**（探不到时什么都不做，
/// 与旧 setUpAll 的缺夹具行为一致）。
void _probeLibmpvFixture() {
  final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
  if (dll.existsSync()) _libmpv = dll.absolute.path;
}

/// 挂 PlayerPage 前惰性加载（幂等）——只为挂这棵树；行为组全程不碰真解码。
void _ensureLibmpvLoaded() {
  if (_libmpv == null || _libmpvLoaded) return;
  _libmpvLoaded = true;
  try {
    MediaKit.ensureInitialized(libmpv: _libmpv);
  } catch (_) {}
}

void main() {
  setUpAll(_probeLibmpvFixture);

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  静态组：open 点收口 + 复活护栏 + 底栏真源字面
  // ═══════════════════════════════════════════════════════════════════

  test('S1 收口助手恰好定义 1 处，且全文件恰好 15 个调用点', () {
    final page = stripComments(File(_pagePath).readAsStringSync());
    indexOfExactly(page, 'void _collapseControlsForSheet() {', want: 1,
        why: 'T27-09 收口助手必须恰好定义一次');
    // 15 = 生产 7（danmaku/bili/subtitle/settings/debugSettings/debugEpisodes
    //      /toggleLive 开分支）+ 底栏内联 2（onEpisodes/onStreams）+ 顶层探针 6
    indexOfExactly(page, '_collapseControlsForSheet();', want: 15,
        why: 'T27-09：15 个浮层 open 点必须全部收口（剥注释后计数，防注释假绿）');
  });

  test('S2 每个浮层 open 函数体都必须调用收口助手', () {
    final page = stripComments(File(_pagePath).readAsStringSync());
    const signatures = <String>[
      'void _openDanmakuSettings() {',
      'void _openBiliSheet() {',
      'void _openSubtitlePanel() {',
      'Future<void> _openSettings() async {',
      'void debugOpenSettingsForProbe() {',
      'bool debugOpenEpisodesForProbe() {',
      'void _toggleLiveChannels() {',
      // 顶层探针与生产 open 点走**同一个字段**，也必须同一条显隐路径
      'bool debugPlayerOpenStreamSheetForProbe() {',
      'bool debugPlayerOpenEpisodeSheetForProbe() {',
      'bool debugPlayerOpenLiveChannelsForProbe() {',
      'bool debugPlayerOpenDanmakuSettingsForProbe() {',
      'bool debugPlayerOpenBiliSheetForProbe() {',
      'bool debugPlayerOpenSubtitlePanelForProbe() {',
    ];
    for (final sig in signatures) {
      final body = fnBody(page, sig);
      expect(body.contains('_collapseControlsForSheet();'), isTrue,
          reason: '「$sig」打开浮层时必须把 _controlsVisible 一并收掉（T27-09）');
    }
    // _toggleLiveChannels 只在**开**分支收：保住 w6 钉的预取调用
    final toggle = fnBody(page, 'void _toggleLiveChannels() {');
    final openBranch = toggle.indexOf('if (_liveChannelsOpen) {');
    expect(openBranch, greaterThanOrEqualTo(0),
        reason: '_toggleLiveChannels 必须保留 if (_liveChannelsOpen) 开分支');
    final collapse = toggle.indexOf('_collapseControlsForSheet();');
    final prefetch = toggle.indexOf('unawaited(_prefetchNextLiveChannel');
    expect(prefetch, greaterThan(openBranch),
        reason: 'w6/t27_w6 钉：开分支里必须预取相邻台');
    expect(collapse, greaterThan(openBranch),
        reason: '收口必须落在**开**分支里（关面板不碰控制条显隐）');
    expect(collapse, lessThan(prefetch), reason: '收口先于预取（同分支内）');
  });

  test('S3 _showControls 复活护栏：浮层开着时 hover 不得叫回', () {
    final page = stripComments(File(_pagePath).readAsStringSync());
    final body = fnBody(page, 'void _showControls() {');
    expect(
      body.contains('if (mounted && !_controlsVisible && !_anySheetOpen) {'),
      isTrue,
      reason: '「浮层开 → hover → 顶栏回来、底栏仍被 !flag 拦着」的复发路径'
          '必须由 _showControls 的 !_anySheetOpen 护栏封堵（T27-09）',
    );
    // _autoHideNow 判据（t118⑨ 钉字面 + 语义正确）
    //
    // ★ 2026-10-11 缺陷⑤（Owner 原话：「鼠标悬浮…控件消失，但是这个倍速的
    //   面板没消失，其他悬浮的面板应该也是一样的」）：判据新增
    //   `_popover.openId == null` —— 悬浮 popover（倍速/清晰度/字幕/弹幕/更多）
    //   开着时不得收底栏（面板挂底栏按钮旁，底栏没了面板就悬空）。
    //   ⇒ 这里的期望字面跟着更新为**含 popover** 的新形态；hints/zoom 两个
    //     既有例外仍在（只加不减）。
    // ⚠️ 断言的是「存在这几条判据」而不是钉死整行排版 —— 换成多行折行
    //    （见 player_page.dart 里那段注释：`!_hintsOpen && !_zoomOpen` 必须
    //     留在同一行，t78 判据④ 钉它）都不该让这条假红。
    final hide = fnBody(page, 'void _autoHideNow() {');
    for (final judge in const [
      'mounted',
      '_playing',
      '!_hintsOpen',
      '!_zoomOpen',
      '_popover.openId == null',
    ]) {
      expect(
        hide.contains(judge),
        isTrue,
        reason: '_autoHideNow 判据缺了 `$judge`'
            '（hints/zoom/popover 三个例外都要登记）',
      );
    }
  });

  test('S4 底栏真源：唯一真源 `_chromeVisible` 的 11 项门控字面原样', () {
    final src = File(_pagePath).readAsStringSync();
    /*
     * ★★★ T27-13（Owner 第 3 / 5 条）：底栏那 11 项门控**已收拢**进
     *   `bool get _chromeVisible`；底栏渲染点写 `if (_chromeVisible)`，
     *   顶栏 `visible` 的正常支也读它 ⇒ 两栏读**同一表达式**，不可能分裂。
     *   ⇒ 本判据（「模型来源」）跟着搬到 getter 上：
     *     原文仍是这 12 项（只是缩进从 24 空格变为 6 空格）。
     ★ 2026-10-25（task-38）：产品新增第 12 项 `!_danmakuSearchOpen`（弹幕手动搜索独立页），
       本字面跟着补上 —— 它是**判据的模型来源**，漏一项 = 模型失效，不是"多打个字"。
     */
    const gate = '_chromeVisible =>\n'
        '      _controlsVisible &&\n'
        '      _error == null &&\n'
        '      !_episodeSheetOpen &&\n'
        '      !_streamSheetOpen &&\n'
        '      !_settingsOpen &&\n'
        '      !_danmakuSearchOpen &&\n'
        '      !_danmakuSheetOpen &&\n'
        '      !_biliSheetOpen &&\n'
        '      !_subtitlePanelOpen &&\n'
        '      !_liveChannelsOpen &&\n'
        '      _liveAudioOnlyNotice == null &&\n'
        '      !_videoOutputDead;';
    expect(src.contains(gate), isTrue,
        reason: '唯一真源 `_chromeVisible` 的 12 项门控'
            '（C && !err && !8flag && !notice && !dead）'
            '是 T27-09/T27-13 真值表的模型来源，字面漂移 = 模型失效');
    // 底栏渲染点必须读唯一真源（用 ListenableBuilder 包住，淡出窗口内留树）
    expect(src.contains('if (!_chromeVisible && !keepForFade) {'), isTrue,
        reason: '★ 底栏显隐必须读唯一真源 `_chromeVisible`（T27-13 唯一真源）');
    // 顶栏 visible 公式字面（t118⑧ 同款，本文件自证模型）
    // ★ 2026-10-11 缺陷④ → T27-13：顶栏正常支**不再内联**那串判据，
    //   改为与底栏共读 `_chromeVisible`；错误态返回口 `|| _canUseTopBarBack` 不变。
    expect(src.contains('visible: _chromeVisible || _canUseTopBarBack,'), isTrue,
        reason: '★★ 顶栏 visible 必须 = `_chromeVisible || _canUseTopBarBack`'
            '（正常支读唯一真源 + 错误态返回口互斥分支）');
    expect(src.contains('_canUseTopBarBack,'), isTrue);
    final back = src.indexOf('bool get _canUseTopBarBack =>');
    expect(back, greaterThanOrEqualTo(0));
    expect(src.substring(back, back + 200).contains('_error != null'), isTrue);
    expect(src.substring(back, back + 200).contains('!_anySheetOpen'), isTrue,
        reason: '_canUseTopBarBack 必须含 !_anySheetOpen（错误态+浮层开着 ⇒ 顶栏也不留）');
  });

  test('S5 真值表：2^9 组合里 top==bottom，唯一例外=登记的错误态特例', () {
    // 模型（与 S4 钉死的唯一真源一一对应）：
    //   chrome = C && !err && !anyF && !notice && !dead
    //   top    = chrome || (desktop && err && !anyF && C)   ← _canUseTopBarBack
    //   bottom = chrome
    // 修复语义：浮层 open 后 C_eff = !anyF（打开前 C=true）。
    // ★ T27-13：top 与 bottom 现在读**同一** `_chromeVisible` ⇒ 除错误态
    //   返回口那一支外恒相等（不再依赖 caller 各自算的巧合）。
    var splits = 0;
    var checked = 0;
    for (var mask = 0; mask < (1 << 9); mask++) {
      final err = (mask & (1 << 0)) != 0;
      final desktop = (mask & (1 << 1)) != 0;
      final flags = <bool>[
        for (var f = 0; f < 7; f++) (mask & (1 << (2 + f))) != 0,
      ];
      final anyF = flags.any((b) => b);
      final c = !anyF; // 修复语义：开了浮层 ⇒ C 被收掉
      final chrome = c && !err && !anyF;
      final top = chrome || (desktop && err && !anyF && c);
      final bottom = chrome;
      checked++;
      if (top != bottom) {
        splits++;
        // 唯一允许的分裂：错误态 + 桌面 + 没开浮层（_canUseTopBarBack 返回口）
        expect(desktop && err && !anyF, isTrue,
            reason: '组合 mask=$mask (err=$err desktop=$desktop F=$flags) 分裂了，'
                '且不是登记特例（错误返回口）—— 违反 T27-13 联动');
      }
    }
    expect(checked, 1 << 9, reason: '必须扫满 2^9 组合');
    expect(splits, 1,
        reason: '恰好 1 个登记特例：desktop && err && !anyF ⇒ 顶栏 1 / 底栏 0');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  行为组：真机树上的联动（native-media）
  // ═══════════════════════════════════════════════════════════════════

  testWidgets('B0 夹具基线：forceBars 后 C=1 且底栏挂载（阳性对照）', (t) async {
    await mountPlayer(t);
    await forceBars(t);
    expect(debugPlayerControlsVisibleForProbe(), isTrue);
    expect(bottomBar, findsOneWidget, reason: '基线：底栏必须在树上');
    await drain(t);
  });

  testWidgets('B1 登记特例行为：错误态（未 forceBars）⇒ 底栏不挂载而 C=1', (t) async {
    await mountPlayer(t);
    /*
     * ★ 2026-10-25（task-38）：**不再依赖**「flutter_tester 里 _load 必败 ⇒ _error 置上」
     * 这个环境巧合 —— 实测今天它不成立了（debugPlayerErrorForProbe() 返回 null）。
     * 改成**显式注入**起播失败：探针转调生产方法 _handleStreamError，
     * 与真实起播失败走同一条路径（不是测试自己复刻一遍）。
     */
    if (debugPlayerErrorForProbe() == null) {
      expect(debugPlayerInjectStreamErrorForProbe('起播失败：回归测试'), isTrue,
          reason: '前置：注入起播失败没生效（探针找不到 PlayerPage？）');
      await t.pump();
    }
    expect(debugPlayerErrorForProbe(), isNotNull, reason: '前置：必须先进入错误态');
    expect(debugPlayerControlsVisibleForProbe(), isTrue,
        reason: '错误态 C 仍为 true（顶栏靠 _canUseTopBarBack 返回口亮着）');
    expect(bottomBar, findsNothing,
        reason: '登记特例：错误态底栏整条摘掉（_error == null 不成立）——'
            '真值表 S5 的唯一允许分裂');
    await drain(t);
  });

  // 每个浮层：open ⇒ 两栏同收；hover 不复活；close ⇒ hover 叫回（有 close 探针的 4 个）
  for (var i = 0; i < kSheetNames.length; i++) {
    final name = kSheetNames[i];
    testWidgets('B2.$i 开「$name」⇒ 顶/底栏一起收；hover 不复活', (t) async {
      await mountPlayer(t);
      await forceBars(t);
      expect(bottomBar, findsOneWidget);

      bool open() {
        switch (i) {
          case 0:
            return debugPlayerOpenEpisodesForProbe();
          case 1:
            return debugPlayerOpenSettingsForProbe();
          case 2:
            return debugPlayerOpenStreamSheetForProbe();
          case 3:
            return debugPlayerOpenLiveChannelsForProbe();
          case 4:
            return debugPlayerOpenDanmakuSettingsForProbe();
          case 5:
            return debugPlayerOpenBiliSheetForProbe();
          case 6:
            return debugPlayerOpenSubtitlePanelForProbe();
        }
        throw StateError('unreachable');
      }

      expect(open(), isTrue, reason: '$name 必须开得出来（阳性对照）');
      await t.pump();

      expect(debugPlayerControlsVisibleForProbe(), isFalse,
          reason: '「$name」打开后 _controlsVisible 必须被收掉（T27-09 联动）');
      expect(bottomBar, findsNothing,
          reason: '「$name」打开后底栏必须消失 —— 与顶栏同真源联动');
      await t.pump();

      // 复发路径封堵：浮层开着时 hover 不得把控制条叫回来
      expect(debugPlayerHoverControlsForProbe(), isFalse,
          reason: '「$name」开着时 hover 不得复活顶/底栏（!_anySheetOpen 护栏）');
      await t.pump();
      expect(debugPlayerControlsVisibleForProbe(), isFalse);
      expect(bottomBar, findsNothing);

      // 关闭 ⇒ hover 叫回（只有带 close 探针的 4 个面板走这条完整链）
      if (i == 1) {
        expect(debugPlayerCloseSettingsForProbe(), isTrue);
      } else if (i == 4) {
        expect(debugPlayerCloseDanmakuSettingsForProbe(), isTrue);
      } else if (i == 5) {
        expect(debugPlayerCloseBiliSheetForProbe(), isTrue);
      } else if (i == 6) {
        expect(debugPlayerCloseSubtitlePanelForProbe(), isTrue);
      } else {
        await drain(t);
        return; // episodes/stream/liveChannels 无 close 探针：收口+护栏已验完
      }
      await t.pump();
      expect(debugPlayerHoverControlsForProbe(), isTrue,
          reason: '「$name」关掉后 hover 必须能把两栏叫回来（自愈路径）');
      await t.pump();
      expect(debugPlayerControlsVisibleForProbe(), isTrue);
      expect(bottomBar, findsOneWidget, reason: '叫回后底栏必须重新挂载');
      await drain(t);
    });
  }

  testWidgets('B3 错误态下开浮层 ⇒ 顶栏也收（特例不被浮层穿透）', (t) async {
    await mountPlayer(t);
    // ★ 2026-10-25（task-38）：同 B1 —— 显式注入，不靠「_load 必败」这个环境巧合。
    if (debugPlayerErrorForProbe() == null) {
      expect(debugPlayerInjectStreamErrorForProbe('起播失败：回归测试'), isTrue,
          reason: '前置：注入起播失败没生效');
      await t.pump();
    }
    expect(debugPlayerErrorForProbe(), isNotNull, reason: '前置：必须先进入错误态');
    expect(debugPlayerOpenSettingsForProbe(), isTrue);
    await t.pump();
    expect(debugPlayerControlsVisibleForProbe(), isFalse,
        reason: '错误态 + 开浮层：_canUseTopBarBack 的 !_anySheetOpen 分量失效，'
            'C 又被收掉 ⇒ 顶栏必须与底栏一起消失');
    expect(bottomBar, findsNothing);
    await drain(t);
  });

  testWidgets('B4 无浮层时 hover 照常叫回（护栏不得误伤正常路径）', (t) async {
    await mountPlayer(t);
    await forceBars(t);
    // 先收（走生产 _autoHideNow），再 hover —— t118③ 同款回归
    debugPlayerAutoHideControlsForProbe();
    await t.pump();
    expect(debugPlayerControlsVisibleForProbe(), isFalse);
    expect(debugPlayerHoverControlsForProbe(), isTrue,
        reason: '没有浮层时 hover 必须照常叫回（护栏只在 _anySheetOpen 时拦截）');
    await t.pump();
    expect(bottomBar, findsOneWidget);
    await drain(t);
  });
}
