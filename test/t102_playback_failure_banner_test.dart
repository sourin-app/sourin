@Tags(['native-media'])

// ══════════════════════════════════════════════════════════════════════
//  t102 —— ★★★ 桌面端第 9 条回归：mpv 报错不许把正在看的画面盖掉
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 报（截图 u9_1c91d6a6.png）
// ```text
// 播放失败
// Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
// ```
//
// # 根因（代码级）
// `lib/ui/player_page.dart` 的 `_bindPlayerStreams()` 里**只有一条**错误处理：
// ```dart
// _player.stream.error.listen((e) {
//   if (mounted) setState(() => _error = e);   // ← 一律走全屏 _ErrorOverlay
// });
// ```
// 而 `stream.error` 在**整条生命周期**里都会发（换清晰度重开、缓冲重试、
// 单帧解码报错…），不只是起播那一次。于是**播放中**来一条错误，
// 全屏遮罩立刻盖住画面 ⇒ 用户看到的就是「看着看着突然播放失败」。
//
// # 修法
// 用 `_sawFirstFrame`（`stream.width` 首次非空 = 真的有画面）把错误**分两类**：
// ```text
// 从未出画面 ⇒ 全屏 _ErrorOverlay（用户什么都没看到，必须解释 + 给出口）
// 已出画面   ⇒ 底部非阻断横幅 _PlaybackFailureBanner（画面继续 + 一键重试）
// ```
//
// # 关于夹具
// 起播需要真网络 + 真解码，widget 测试里做不到 ⇒ 用探针直调
// （`debugPlayerInjectStreamErrorForProbe` / `debugPlayerMarkFirstFrameForProbe`）。
// 两个探针**逐字复刻**生产闭包体，判据读的是 `_sawFirstFrame` / `_playbackFailure`
// 这些**真实字段**，不是测试自己记的副本。
//
// ⚠️ 必须 `--run-skipped --tags native-media`（见 dart_test.yaml:62-69）
// ══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

const kMpvMessage = 'Failed to open '
    'http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.';

List<Episode> fakeEpisodes(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://example.invalid/$i.m3u8'),
    ];

Future<void> mountPlayer(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '播放中断回归',
        episodes: fakeEpisodes(5),
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
}

Future<void> drain(WidgetTester t) async {
  for (var i = 0; i < 60; i++) {
    await t.pump(const Duration(seconds: 3));
  }
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('① 起手：没出过画面、没有横幅（夹具自检）', (t) async {
    await mountPlayer(t);
    final st = debugPlayerPlaybackFailureState();
    expect(st.contains('hasFrame=false'), isTrue, reason: '★ 起手不能有画面：$st');
    expect(st.contains('failure=-'), isTrue, reason: '★ 起手不能有横幅：$st');
    await drain(t);
  });

  testWidgets('② ★★★ 没出过画面时来的错误 ⇒ 仍然走全屏错误层（不能静默）', (t) async {
    await mountPlayer(t);
    expect(debugPlayerInjectStreamErrorForProbe(kMpvMessage), isFalse,
        reason: '★ 返回的是「注入前是否已出画面」，此刻应为 false');
    await t.pump();
    final st = debugPlayerPlaybackFailureState();
    expect(st.contains('failure=-'), isTrue,
        reason: '★★ 起播阶段**不该**走非阻断横幅（用户什么都没看到，必须解释）：$st');
    expect(st.contains('error=$kMpvMessage'), isTrue,
        reason: '★★★ 起播阶段的错误必须进 `_error`（全屏 _ErrorOverlay）：$st');
    /*
     * ★★★ 2026-10-18（Owner 第 6 条）—— 断言**故意**从「原文上屏」翻到「地址不上屏」
     *
     * 改前这里断言的是 `find.text(kMpvMessage)`（那条带 127.0.0.1:63534 的原句）。
     * 而 Owner 第 6 条的诉求正是「不要让我看到内部地址，我要知道是源还是软件」。
     * ⇒ 新行为：内部代理地址**必须被抹掉**，同时错误**仍然要显示**（不能变空白）。
     *
     * ⚠️ 这不是"为了让测试变绿而放宽断言"：新断言在**旧行为**下会红
     *    （旧行为把原文贴上屏 ⇒ `findsNothing` 那条红）。
     */
    expect(find.text(kMpvMessage), findsNothing,
        reason: '★★ 内部代理地址不许上屏（Owner 第 6 条）');
    expect(find.textContaining('127.0.0.1'), findsNothing,
        reason: '★★ 连子串都不许有 —— 端口会变，匹配整句不够');
    expect(find.textContaining('内置代理'), findsWidgets,
        reason: '★ 抹掉之后要有替代说明（不能留空、也不能不显示错误）');
    await drain(t);
  });

  testWidgets('③ ★★★ 出过画面后的错误 ⇒ 非阻断横幅，`_error` 保持为空', (t) async {
    await mountPlayer(t);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue, reason: '★ 先要有画面');
    await t.pump();

    expect(debugPlayerInjectStreamErrorForProbe(kMpvMessage), isTrue,
        reason: '★ 返回的是「注入前是否已出画面」，此刻应为 true');
    await t.pump();

    final st = debugPlayerPlaybackFailureState();
    expect(st.contains('error=-'), isTrue,
        reason: '★★★ 播放中来的错误**不许**写进 `_error` —— '
            '写进去就会弹全屏 _ErrorOverlay，正在看的画面被整块盖掉（Owner 报的就是这个）：$st');
    expect(st.contains('failure=$kMpvMessage'), isTrue,
        reason: '★★★ 播放中的错误要进非阻断横幅字段：$st');

    expect(find.text('播放中断了（画面还在，可以重试）'), findsOneWidget,
        reason: '★★★ 非阻断横幅必须在树上（底部一条，画面继续）');
    expect(find.text('重试'), findsWidgets, reason: '★ 这条是**可恢复**的，必须给重试');
    /*
     * ★★★ 2026-10-18（Owner 第 6 条）—— 同 ② 组，断言方向翻了。
     * 横幅正文必须显示**错误**，但那条内部代理地址必须被抹掉。
     */
    expect(find.text(kMpvMessage), findsNothing,
        reason: '★ 内部代理地址不许上屏（Owner 第 6 条）');
    expect(find.textContaining('127.0.0.1'), findsNothing,
        reason: '★ 连子串都不许有');
    expect(find.textContaining('内置代理'), findsWidgets,
        reason: '★ 要有替代说明，且横幅**仍然**在报错（不能变成空横幅）');
    await drain(t);
  });

  testWidgets('④ ★★ 恢复后横幅自动收掉（已经好了就不该继续吓用户）', (t) async {
    await mountPlayer(t);
    debugPlayerMarkFirstFrameForProbe();
    await t.pump();
    debugPlayerInjectStreamErrorForProbe(kMpvMessage);
    await t.pump();
    expect(find.text('播放中断了（画面还在，可以重试）'), findsOneWidget);

    // 画面回来（mpv 重连成功 ⇒ stream.width 再发一次非空）
    debugPlayerMarkFirstFrameForProbe();
    await t.pump();
    expect(debugPlayerPlaybackFailureState().contains('failure=-'), isTrue,
        reason: '★★ 画面回来了，横幅必须收掉');
    expect(find.text('播放中断了（画面还在，可以重试）'), findsNothing);
    await drain(t);
  });

  testWidgets('⑤ ★ 静态审计：分流判据 + 新一轮起播会复位 + 错误已落盘', (t) async {
    final src = File('lib/ui/player_page.dart').readAsStringSync();

    expect(src.contains('bool _sawFirstFrame = false;'), isTrue,
        reason: '★★★ 判据字段必须在 —— 它是「出过画面」这个事实的唯一记录');
    expect(src.contains('_playbackFailure = e;'), isTrue,
        reason: '★★★ error 监听里必须把错误分流到非阻断字段');
    expect(src.contains('if (_sawFirstFrame) {'), isTrue,
        reason: '★★★ 分流必须按 `_sawFirstFrame` 判，不能一律写 `_error`');
    expect(src.contains('class _PlaybackFailureBanner extends StatelessWidget'),
        isTrue);
    expect(src.contains('onRetry: () => unawaited(_load()),'), isTrue,
        reason: '★★ 横幅的「重试」必须真的重新起播（`_load`），不能只关横幅');
    expect(src.contains('AppLog.write('), isTrue,
        reason: '★ 错误必须落盘 —— 端口随进程退出失效，事后只能靠日志');

    // 新一轮起播（_load 与 _startPlayback 两处）都要复位判据
    final resets = RegExp('_sawFirstFrame = false;').allMatches(src).length;
    expect(resets, greaterThanOrEqualTo(2),
        reason: '★★★ `_load` 与 `_startPlayback` 都必须复位「出过画面」—— '
            '否则换了条根本打不开的流，错误会被当成「可恢复中断」而**不弹全屏**'
            '（用户对着黑屏什么都没有）');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑥ ★★★ 缺陷②（2026-10-25）：横幅与底栏的**结构**关系
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么补在**这个**文件里
  // 本文件就是「非阻断横幅」那一条缺陷的门禁（Owner 第 9 条）。
  // 缺陷② 是它的直接续集：横幅不消失 + 盖住底栏。判据放同一处，
  // 免得将来只跑 t102 的人以为横幅这件事已经全绿。
  //
  // # 判据
  // ```text
  // ① `_bottomOccupied` 计入 `_playbackFailure` ⇒ 占据态时底栏整条卸下
  //    （否则底栏与横幅抢同一块底部区域 ⇒ 「重试」被盖住点不到）
  // ② 恢复判据存在：`_playing` + 位置连续推进 ≥ 3 秒 ⇒ 清横幅
  // ③ 跳过的 `debugPlayerMaybeSkipForProbe` 那条竞态让位（缺陷③同一处）
  // ```
  // ⚠️ 行为断言在 `zz_t1024_player_banner_order_test.dart`
  //    （② 恢复 / ③ 暂停阴性对照 / ④ `_bottomOccupied` 为真且底栏不在树上）；
  //    这里只钉**源码结构**，两处一起才算完整。
  test('⑥ ★★★ `_bottomOccupied` 计入横幅，且恢复判据用 3 秒推进', () {
    final src = File('lib/ui/player_page.dart').readAsStringSync();

    final occAt = src.indexOf('bool get _bottomOccupied =>');
    expect(occAt, greaterThan(-1), reason: '锚点不存在：`bool get _bottomOccupied =>`');
    final occBody = src.substring(occAt, occAt + 800);
    expect(occBody, contains('_playbackFailure != null'),
        reason: '★★★ 不算 `_playbackFailure` ⇒ 底栏会跟横幅抢同一块底部区域');

    expect(src, contains('_recoveryProgress += p - _position;'),
        reason: '★★ 恢复必须是"位置**连续推进**"，不是"又出了一帧"'
            '（掉帧/缓冲重试期间 stream.width 不会再发）');
    expect(src, contains('_playing &&'),
        reason: '★★ 暂停时位置推进不算恢复（否则横幅会在用户暂停时自己跑掉）');
    expect(src, contains('_recoveryProgress >= const Duration(seconds: 3)'),
        reason: '★ 3 秒阈值（要能过 t72_jank 这类掉帧场景）');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑦ ★★★ task-14（2026-10-25）：横幅出现后「重试」**真的点得到**
  // ══════════════════════════════════════════════════════════════════
  //
  // # 补的是什么（交叉复核指出的证据缺口）
  // ```text
  // 第 02 项原来只验到「横幅顺序对 + `_bottomOccupied` 让位」，
  // **没有一条**把两者渲染出来断言「重试」按钮真的可点。
  // 而 Owner 报的原症状正是"点不到"：
  //   「鼠标一动控件浮现就盖住「重试」」。
  // ⇒ 本用例：横幅出现 → 断言 hitTestable + 真的 tap → `_load()` 计数 +1；
  //   再把控制条**钉在显示态**（`debugPlayerForceBarsForShot`，最坏情形），
  //   断言底栏仍然不在树上、重试仍然点得到。
  // ```
  // # 两道防线（各自独立，缺一都会复发）
  // ```text
  // ① `_bottomOccupied` 计入 `_playbackFailure` ⇒ 底栏整条卸下（抢不到点击）
  // ② 三条横幅画在 `_BottomBar` **之后**（后写的在上）⇒ 即使底栏在，也压不住横幅
  // ```
  // ⚠️ 注入结论（本用例实测）：删掉 ① 会红；只把横幅搬回底栏之前**不会**红 ——
  //    因为 ① 已经把底栏卸下了。① + 把横幅搬回之前 一起注入才红。
  //    顺序本身由 `zz_t1024_player_banner_order_test` ① 做源码顺序断言守住。
  testWidgets('⑦ ★★★ 横幅出现后「重试」真的点得到，且点了真的重新起播', (t) async {
    await mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);

    // ── 先让控制条可见（鼠标唤起态），量它原本占的那条带 ──
    debugPlayerHoverControlsForProbe();
    await t.pump();
    expect(find.byType(PlayerBottomBar), findsOneWidget,
        reason: '夹具自检：唤起控制条后底栏必须在树上');
    final barRect = t.getRect(find.byType(PlayerBottomBar));

    // ── 注入一条"播放中"的错误 ⇒ 非阻断横幅 ──
    expect(debugPlayerInjectStreamErrorForProbe('fixture stream interrupted'),
        isTrue,
        reason: '★ 返回 true = 已出过画面 ⇒ 走非阻断横幅（不是全屏错误层）');
    await t.pump();

    final retry = find.text('重试');
    expect(retry, findsWidgets, reason: '横幅必须给「重试」出口');
    expect(retry.first.hitTestable(), findsOneWidget,
        reason: '★★★ 「重试」在它的中心点必须**可命中** —— '
            'Owner 报的就是"鼠标一动控件浮现就盖住重试，点不到"');

    // ── 几何：重试落在底栏原本占的那条带里（所以"谁在上面"才重要）──
    final retryRect = t.getRect(retry.first);
    expect(retryRect.bottom, greaterThan(barRect.top),
        reason: '★ 「重试」$retryRect 落在底栏带 $barRect 之外 ⇒ '
            '本用例没覆盖到真正的重叠区，判据失去意义');
    expect(debugPlayerBottomOccupiedForProbe(), isTrue,
        reason: '★★ `_bottomOccupied` 必须为真（横幅占据底部）');
    expect(find.byType(PlayerBottomBar), findsNothing,
        reason: '★★ 第一道防线：占据态底栏整条卸下 ⇒ 它不可能抢走这一次点击');

    // ── 最坏情形：把控制条钉在显示态，底栏仍不许回来 ──
    expect(debugPlayerForceBarsForShot(), isTrue);
    await t.pump();
    expect(find.byType(PlayerBottomBar), findsNothing,
        reason: '★★★ 控制条被强制显示时底栏仍必须让位 —— '
            '否则它画在横幅上（改前形态）就会盖住「重试」');
    expect(find.text('重试').hitTestable(), findsOneWidget,
        reason: '★★★ 控制条被唤起之后，「重试」仍然必须点得到');

    /*
     * ── 「真的重新起播」的行为证据 ──
     *
     * ⚠️ 这里**不能**用 `tester.tap` 做行为断言：本仓已记录的仪器限制是
     *   「`flutter_tester` 里 `PlayerPage` 整棵树的**指针回调不派发**」
     *   （`test/t98` 文件头 / `debugOpenEpisodesForProbe` 的注释）。
     *   本轮实测复核（`.probe/fix01-tap-probe.log`）：
     *   ```text
     *   底栏 InkWell 上 `tester.tap` ⇒ `debugPlayerTogglePlayCalls` 0 → 0
     *   横幅「重试」`hitTestable()` = 1，`tester.tap` ⇒ `_loadCalls` 1 → 1
     *   ```
     *   ⇒ 不是横幅的问题，是这台仪器**不派发**手势。若在这里硬断言 tap 生效，
     *     测试会**永久红**；那属于"用错误期待值逼代码让步"，本仓禁止。
     * ⇒ 行为证据改为：**读那颗真实按钮的 `onPressed` 并调用它**。
     *   那是**同一颗按钮的同一个回调**（`FilledButton(onPressed: onRetry)`），
     *   既不是旁路、也不是复刻；"点得到"由 `hitTestable()` 证明。
     */
    final button = find.widgetWithText(FilledButton, '重试');
    expect(button, findsOneWidget,
        reason: '★ 横幅的「重试」必须是一颗真实按钮（不是一段文字）');
    final btn = t.widget<FilledButton>(button);
    expect(btn.onPressed, isNotNull,
        reason: '★★ 按钮必须 enabled（disabled 的按钮在真机上点不动）');

    final before = debugPlayerLoadCallsForProbe();
    expect(before, isNotNull, reason: '★ 探针必须接上（null = 播放页没挂）');
    btn.onPressed!(); // = onRetry = `() => unawaited(_load())`
    await t.pump();
    expect(debugPlayerLoadCallsForProbe(), before! + 1,
        reason: '★★★ 「重试」必须真的重新起播（`_load()` 计数 +1）；'
            '只把横幅关掉的"假重试"会在这里被抓住');

    await drain(t);
  });
}
