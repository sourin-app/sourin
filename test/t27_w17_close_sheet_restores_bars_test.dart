@Tags(['native-media'])

// ══════════════════════════════════════════════════════════════════════
//  t27_w15 —— ★★★ Owner 2026-10-11 第 2 条门禁：**关掉浮层必须把顶/底栏叫回来**
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 2.顶部和底部的还是一样没有联动,而且底部的也还是我点暂停才显示出来,
// >   压根没休
// ```
//
// # 根因（已核实行号；T27-09 的**另一半没补**）
// ```text
// T27-09 的 open 点调 `_collapseControlsForSheet()` 把 `_controlsVisible`
// 收成 false（显隐联动）。它的注释**声称**：
//   「关闭浮层后由 Esc 关闭链 / 面板 onClose 的 `_showControls()`（或下次
//     hover）自然叫回。」
// ★ 但实测只有**播放设置面板**那一条真的调了 `_showControls()`
//   （`_closeSettingsFromEsc` + 设置 onClose + 设置 X，三处）。
//   其余 6 个浮层（弹幕设置 / B 站导入 / 在线字幕 / 选集 / 线路 / 所有直播）
//   的 Esc 分支与 onClose **只翻 flag，不叫回控制条** ——
//   ⇒ 关掉它们之后 `_controlsVisible` 仍是 false，底栏只能等**下一次 hover**。
// ⇒ 真机上若 hover 那条路不灵（鼠标停在浮层原位不动 / 挪到原生视频面上 /
//   浮层淡出的 260ms 里点不到底栏），用户看到的就是
//   「关掉面板后底栏一直不回来，只有点一次暂停（`_togglePlay` →
//     `_showControls()`）才回来」—— 正是 Owner 复报的症状。
// ```
//
// # 修法
// ```text
// 新增 `_restoreBarsAfterSheet()`（= 就地调 `_showControls()`），
// 补到**每一个**浮层关闭点（Esc 链 6 处 + 各面板 onClose / onPick +
// 三个 close 探针）。与「播放设置面板关闭的三步自愈」同一条纪律。
// ★ 不动 `_showControls()` 里那条 `!_anySheetOpen` 护栏（T27-09 的
//   防分裂意图）—— 关的那一刻 flag 已翻 false，护栏放行 ⇒ 两条栏
//   一起回来（同一个 `_chromeVisible` 真源，构造上不可能分裂）。
// ```
//
// # 判据
// ```text
// 静态契约：每个浮层关闭点（Esc 分支 / onClose / close 探针）都必须调用
//           `_restoreBarsAfterSheet()`；且该助手恰好定义一次。
// 行为：真树上 open 浮层 ⇒ C=false；close ⇒ **不靠 hover** C 立刻回 true、
//       底栏重新挂载（每条 close 探针走一遭）。
// ```
//
// # ★★ 阳性对照（铁律②）
// 先把浮层**真的打开**（断言 C=false、底栏不在），再关 —— 否则
// 「关掉后 C=true」可能只是因为压根没打开过（空判据）。
//
// ⚠️ 必须带 @Tags(['native-media']) 并用 `--run-skipped --tags native-media` 跑
//    （dart_test.yaml: 该标签默认 skip）；测试一律 --concurrency=1。
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

// ══════════════════════════════════════════════════════════════════════
//  夹具（与 t27_w9_bar_linkage_test.dart 同构；不新造一套）
// ══════════════════════════════════════════════════════════════════════

const String _pagePath = 'lib/ui/player_page.dart';

/// 剥掉 `//` 行注释、`///` 文档注释、`/* */` 块注释（保留字符串字面量）
/// —— 逐字照抄 t27_w9_bar_linkage_test.dart:69-110（已验证实现）。
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

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(
          id: 'ep$i',
          title: '第$i集',
          url: 'https://example.invalid/$i.m3u8',
        ),
    ];

/// 底栏挂载判据：_BottomBar 是私有类 ⇒ 用 runtimeType 名字匹配
final Finder bottomBar = find.byWidgetPredicate(
  (w) => w.runtimeType.toString() == '_BottomBar',
);

String? _libmpv;
bool _libmpvLoaded = false;

void _probeLibmpvFixture() {
  final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
  if (dll.existsSync()) _libmpv = dll.absolute.path;
}

void _ensureLibmpvLoaded() {
  if (_libmpv == null || _libmpvLoaded) return;
  _libmpvLoaded = true;
  try {
    MediaKit.ensureInitialized(libmpv: _libmpv);
  } catch (_) {}
}

Future<void> mountPlayer(WidgetTester t) async {
  _ensureLibmpvLoaded();
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '关浮层复原',
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

/// flutter_tester 里 `_load()` 必败 ⇒ 必须用截图探针离开错误态
Future<void> forceBars(WidgetTester t) async {
  expect(debugPlayerForceBarsForShot(), isTrue);
  await t.pump();
  await t.pump();
}

/// 把挂起计时器推完，免得报 pending timer
Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

void main() {
  setUpAll(_probeLibmpvFixture);

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  静态组：关点必须调用复原助手
  // ═══════════════════════════════════════════════════════════════════

  test('S1 `_restoreBarsAfterSheet` 恰好定义 1 次，调用点覆盖全部关点', () {
    final page = stripComments(File(_pagePath).readAsStringSync());
    // 定义：恰好一处。
    final defs =
        RegExp(r'void _restoreBarsAfterSheet\(\)\s*\{').allMatches(page).length;
    expect(defs, 1,
        reason: '★ `_restoreBarsAfterSheet` 必须恰好定义一次'
            '（多处定义 = 纪律分裂）');
    // 调用点：13 处 = Esc 链 6（hints/bili/subtitle/danmaku/zoom/episode
    //   /stream/live 里除 settings 外全部，计 8 条但 settings 走自己的三步）
    //   + 生产 onClose/onPick 若干 + 3 个 close 探针。
    // ⚠️ 只断言「≥ 一个下界」会太松；这里钉「每个已知关点文本块都含它」。
    final calls =
        RegExp(r'_restoreBarsAfterSheet\(\);').allMatches(page).length;
    expect(calls, greaterThanOrEqualTo(13),
        reason: '★★ Owner 2026-10-11 第 2 条：每个浮层关闭点都必须把顶/底栏'
            '叫回来（Esc 链 + 面板 onClose/onPick + close 探针）。'
            '实际调用点=$calls，少于 13 ⇒ 有关点漏补，'
            '「关掉面板底栏不回来」会复发');

    // Esc 链专用的一行助手（把 Esc 分支的长度压回 700 窗口内）。
    final escDefs =
        RegExp(r'void _escCloseSheet\(VoidCallback flip\)\s*\{').allMatches(page).length;
    expect(escDefs, 1, reason: '★ Esc 链关点助手 `_escCloseSheet` 必须恰好定义一次');
    /*
     * ★★★ task-34（2026-10-25）：Esc 链改成**点名清单**，不再只钉一个数字。
     *
     * # 为什么必须点名（上一轮就漂过一次）
     * ```text
     * 改前：`expect(escCalls, 8)` —— 本批新增了**弹幕搜索页**这个关点，
     *       实际变 9 ⇒ 报 `Expected: <8> Actual: <9>`，
     *       但**看报错根本不知道多的是哪一处**（只能去数源码）。
     *       「只把 8 改成 9」的迁移等于把清单又埋回一个裸数字，下次继续漂。
     * ⇒ 现在：把 9 个分支**逐个写出来**，再断言
     *       count == 清单长度 + 每个片段**恰好出现一次**。
     *   新增关点时，报错会直接指出"清单里缺 X / 多了一条没登记的 Y"。
     * ```
     */
    const escBranches = <String, String>{
      '选集 episode': '_escCloseSheet(() => _episodeSheetOpen = false);',
      '提示 hints': '_escCloseSheet(() => _hintsOpen = false);',
      'B站弹幕 bili': '_escCloseSheet(() => _biliSheetOpen = false);',
      '字幕搜索 subtitle': '_escCloseSheet(() => _subtitlePanelOpen = false);',
      // ★ 本批（第 12 项）新增的第 9 个关点：弹幕搜索页
      '弹幕搜索 danmakuSearch':
          '_escCloseSheet(() => _danmakuSearchOpen = false);',
      '弹幕设置 danmaku': '_escCloseSheet(() => _danmakuSheetOpen = false);',
      '缩放 zoom': '_escCloseSheet(() => _zoomOpen = false);',
      '清晰度 stream': '_escCloseSheet(() => _streamSheetOpen = false);',
      '直播频道 liveChannels':
          '_escCloseSheet(() => _liveChannelsOpen = false);',
    };
    for (final e in escBranches.entries) {
      final hits =
          RegExp(RegExp.escape(e.value)).allMatches(page).length;
      expect(hits, 1,
          reason: '★★ Esc 链分支「${e.key}」必须**恰好一处**（实际 $hits）：'
              '${e.value} ｜ 0 = 这个关点丢了 Esc 出口（按 Esc 关不掉面板）；'
              '>1 = 重复接线（两份真相，迟早漂）');
    }
    final escCalls = RegExp(r'_escCloseSheet\(\(').allMatches(page).length;
    expect(escCalls, escBranches.length,
        reason: '★★★ Esc 链的关点**必须与上面清单一一对应**：'
            '实际=$escCalls，清单=${escBranches.length}。'
            '不等 ⇒ 新增/删除了关点却没登记（本批新增的正是'
            '「弹幕搜索 danmakuSearch」，它是第 12 项搬进页内的搜索页，'
            'Esc 关掉时也要把顶/底栏叫回来）。');

    /*
     * ★★★ 第 12 项：弹幕搜索页的 **onClose** 也必须复位顶/底栏（点名，不只数总数）
     *
     * # 为什么它必须恢复
     * ```text
     * `_danmakuSearchOpen` 进了 `_bottomOccupied` ⇒ 搜索页一开，底栏整条卸下。
     * 关闭时若只翻 flag 不叫回控制条，用户会看到"面板没了、底栏也不回来"，
     * 得再动一下鼠标才出现（Owner 报的"关掉面板底栏不回来"同款）。
     * ```
     * ⚠️ 与 Esc 分支是**两条不同的入口**：Esc 走 `_escCloseSheet`，
     *    点右上角 X 走这段 `onClose`。两条都要能恢复，少一条就有一条路被漏掉。
     */
    const danmakuSearchOnClose = 'setState(() => _danmakuSearchOpen = false);';
    final onCloseAt = page.indexOf(danmakuSearchOnClose);
    expect(onCloseAt, greaterThanOrEqualTo(0),
        reason: '★ 找不到弹幕搜索页的 onClose（锚点：$danmakuSearchOnClose）');
    final onCloseBody = page.substring(
        onCloseAt, (onCloseAt + 300).clamp(0, page.length));
    expect(onCloseBody.contains('_restoreBarsAfterSheet();'), isTrue,
        reason: '★★★ 弹幕搜索页 onClose 必须调用 `_restoreBarsAfterSheet()` —— '
            '否则点 X 关掉搜索页后顶/底栏不回来（删掉那一行 ⇒ 本条立刻红）');

    // 三个 close 探针必须与生产同路径（否则行为组验的是假路径）。
    for (final fn in const [
      'bool debugPlayerCloseDanmakuSettingsForProbe() {',
      'bool debugPlayerCloseBiliSheetForProbe() {',
      'bool debugPlayerCloseSubtitlePanelForProbe() {',
    ]) {
      final i = page.indexOf(fn);
      expect(i, greaterThanOrEqualTo(0), reason: '找不到探针 `$fn`');
      final body = page.substring(i, page.indexOf('return !', i));
      expect(body.contains('_restoreBarsAfterSheet();'), isTrue,
          reason: '★ `$fn` 必须与生产 onClose 同路径调用 `_restoreBarsAfterSheet()`');
    }
  });

  test('S2 `_showControls` 的 T27-09 护栏**逐字未动**（不靠改松护栏取巧）', () {
    final page = stripComments(File(_pagePath).readAsStringSync());
    final i = page.indexOf('void _showControls() {');
    expect(i, greaterThanOrEqualTo(0));
    final body = page.substring(i, page.indexOf('void _armHideTimer', i));
    expect(body.contains('if (mounted && !_controlsVisible && !_anySheetOpen) {'),
        isTrue,
        reason: '★★ 本修复**只**补关点自愈，**不动** T27-09 的 hover 护栏'
            '（浮层开着时 hover 不得叫回 —— 防「顶栏回来、底栏仍被拦」的分裂）');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  行为组：真树上「关浮层 ⇒ 不靠 hover 底栏立刻回来」
  // ═══════════════════════════════════════════════════════════════════

  // 每条可关的浮层：open ⇒ C=false + 底栏不在；close ⇒ C=true + 底栏回来
  // （**中间不 hover** —— 这正是 Owner 报的场景）。
  //
  // ⚠️ 只列**close 探针与生产同路径**的三个面板。`debugPlayerCloseSettingsForProbe`
  //    **故意**只翻 `_settingsOpen`（它模拟的是「真源说关、portal 镜像还开着」的
  //    中间态，见它自己的文档）⇒ 不在本组；设置面板的生产关点自愈由
  //    `_closeSettingsFromEsc` / 设置 onClose 承担，另有 t98 盯着。
  final closers = <String, (bool Function(), bool Function())>{
    '弹幕设置 danmaku': (
      debugPlayerOpenDanmakuSettingsForProbe,
      debugPlayerCloseDanmakuSettingsForProbe
    ),
    'B站弹幕 bili': (
      debugPlayerOpenBiliSheetForProbe,
      debugPlayerCloseBiliSheetForProbe
    ),
    '字幕搜索 subtitle': (
      debugPlayerOpenSubtitlePanelForProbe,
      debugPlayerCloseSubtitlePanelForProbe
    ),
  };

  closers.forEach((name, pair) {
    testWidgets('B1「$name」开 ⇒ 两栏同收；关 ⇒ **不靠 hover** 两栏立刻回来',
        (t) async {
      await mountPlayer(t);
      await forceBars(t);
      expect(bottomBar, findsOneWidget, reason: '基线：底栏在树上');

      final (open, close) = pair;

      // ── 阳性对照：真的打开 ──
      expect(open(), isTrue, reason: '$name 没打开（阳性对照失败）');
      await t.pump();
      expect(debugPlayerControlsVisibleForProbe(), isFalse,
          reason: '「$name」打开后 _controlsVisible 必须被收掉（T27-09 联动）');
      expect(bottomBar, findsNothing,
          reason: '「$name」打开后底栏必须消失（与顶栏同真源）');

      // ── 关闭：**全程不调 hover**，直接断言复原点 ──
      //   ★ 这是本门禁的核心：关点必须**自己**把控制条叫回来
      //     （Owner 原话「底部的也还是我点暂停才显示出来」）。
      expect(close(), isTrue, reason: '$name 没关掉');
      await t.pump();
      expect(debugPlayerControlsVisibleForProbe(), isTrue,
          reason: '★★ Owner 2026-10-11 第 2 条：关掉「$name」后 `_controlsVisible` '
              '必须**立即**回 true（关点自愈），而不是等下一次 hover');

      await t.pump();
      expect(bottomBar, findsOneWidget,
          reason: '★ 关掉「$name」后底栏必须重新挂载（顶/底栏同真源联动）');

      await drain(t);
    });
  });

  testWidgets('B2 回归护栏：浮层开着时 hover 仍**不得**叫回（T27-09 不回归）', (t) async {
    await mountPlayer(t);
    await forceBars(t);
    expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue);
    await t.pump();
    expect(debugPlayerHoverControlsForProbe(), isFalse,
        reason: '★ T27-09：浮层开着时 hover 不得把控制条叫回来'
            '（本修复只补关点，不许把这条护栏改松）');
    await drain(t);
  });
}
