// ═══════════════════════════════════════════════════════════════════════
//  task-92：直播内嵌播放器「等首帧」提示 —— 消灭首帧黑窗期的纯黑
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（Owner 报的第 1′ 条，逐字）
//
// ```text
// 「第一次启动,切换到直播页面,要黑屏 8秒+ 才能显示出来画面」
// ```
//
// # 实测：那段黑屏**连一个像素的非黑都没有**（不是“提示太暗看不清”）
//
// ```text
// 已部署构建、同帧采样播放器区域与顶/底栏（`.probe/ops/nf4/dual.csv`）：
//   t=671 … 13027 播放器区域 mean=0.0 sd=0.0 brightRatio=0.000（24 帧全是纯黑）
//   同帧顶栏底栏恒 233.3 / 0.988 ⇒ 不是整窗黑、不是截图失败
// ⇒ 黑窗 ≈ 12.9 秒，全程**纯黑**。
// ```
//
// # 根因（两条，都不是“提示画错了”）
//
// ```text
// ① 源侧：同机同命令 ffprobe 同一批直播源
//      ABN China（mediaserver.abnvideos.com）probe_ms = 8005
//      白城（stream2.jlntv.cn）        probe_ms =  515
//    ⇒ “8 秒”主要是**源侧**；ffmpeg 参数扫描（probesize/analyzeduration
//      四种组合 × 3 次、首帧 4 次 × 3 组）**完全重叠** ⇒ 本机调不短。
//
// ② 提示判据恒 false（**本文件守的就是这一条**）：
//    media_kit 1.2.6 `real.dart:1468-1485` 在 `MPV_EVENT_START_FILE` 上
//    **同时**推 `playing=true` 与 `buffering=true`
//    ⇒ `_ready=true` 与 `_buffering=true` 几乎同帧到
//    ⇒ 既有判据 `(_buffering && !_ready)` 在 START_FILE 后**立刻变 false**；
//    随后 `core-idle=false`（`:1517-1535`）又把 buffering 置回 false。
//    ⇒ 整个黑窗期该判据恒 false ⇒ 纯黑。
// ```
//
// # 判据（本文件四条 + 一条静态契约）
//
// ```text
// ① 纯黑期（还没见到视频轨）⇒ 必须**有**加载提示，且文案非空
// ② ★ 见到视频轨（dw 到手）⇒ 提示**必须立刻消失**（不能等到首帧渲染）
//    —— 这条是“不遮挡刚出来的画面”，也是“不撒谎”的另一半
// ③ ★ 阴性对照：看门狗判成“本来就没有视频轨” ⇒ 提示**必须收口**
//    —— 不收口就是转圈永不消失（比纯黑更糟：转圈暗示“马上就有”）
// ④ ★ 阴性对照：`audioOnly`（仅音频台）⇒ 提示**必须不出现**
//    —— 否则与 `_AudioOnlyBadge` 两个居中卡片互相盖字
// ⑤ 静态契约：判据必须是 `_awaitingFirstVideoFrame`（不是某处就地拼的）
// ```
//
// # ★★ 为什么本文件**不加** `@Tags(['native-media'])`
//
// ```text
// 同目录 `t74_embed_visibility_gate_test.dart` 必须加那个 tag，因为它在
// `runAsync` 里跑满 380ms 让 `_create()` 真构造 `Player(...)` ⇒ 加载
// libmpv-2.dll ⇒ flutter_tester 偶发访问违例 c0000005（实测 6/25）。
//
// 本文件**全程停在 `_createDelay`（380ms）之内**：
//   pumpWidget(0ms) + pump(60ms) + pump(120ms) = 180ms < 380ms
// ⇒ `_createTimer` 从未触发 ⇒ `Player` 从未构造 ⇒ 不加载 libmpv。
// ★ 这个前提**不是**注释里说说而已 —— 每个用例都用
//   `hasPlayerForTest == false`（`live_embedded_player.dart:1284`）
//   **当场证明**它成立。若将来有人把 `_createDelay` 调短、
//   或在窗口内多 pump 几帧，这条断言会**先变红**，
//   而不是变成偶发 native 崩溃。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

// ═══════════════════════════════════════════════════════════════════════
//  仪器
// ═══════════════════════════════════════════════════════════════════════

Widget _mount({
  required GlobalKey<LiveEmbeddedPlayerState> key,
  bool audioOnly = false,
}) {
  return MaterialApp(
    home: Scaffold(
      body: LiveEmbeddedPlayer(
        key: key,
        // ★ 这个 URL **永远不会被打开** —— 用例全程停在 380ms 窗口内
        //   （由 `hasPlayerForTest == false` 当场证明）。
        stream: const StreamCandidate(
          url: 'file:///t92-firstframe-probe-never-opened.mp4',
          label: 'probe',
        ),
        title: 'probe',
        audioOnly: audioOnly,
      ),
    ),
  );
}

/// ★ 前置断言：确认“还没建播放器”（= 没加载 libmpv = 本文件可进默认套件）
void _expectNoPlayerYet(GlobalKey<LiveEmbeddedPlayerState> key, String when) {
  expect(key.currentState, isNotNull, reason: '★ 控件必须挂上了（$when）');
  expect(
    key.currentState!.hasPlayerForTest,
    isFalse,
    reason: '★★★ $when：`Player` **已经**被构造了 ⇒ 本用例已经越过 380ms '
        '窗口 ⇒ 会去加载 libmpv-2.dll ⇒ 本文件就不再是“无原生”的了'
        '（偶发 c0000005）。',
  );
}

/// 本控件里“正在等首帧”的那条提示。
///
/// ★ 用**文案**而不是 `byType(AppLoading)` 定位：`AppLoading` 是共享组件，
///   将来别处若也往这个 Stack 里塞一个，`byType` 会数到两个而假红；
///   文案是**这个点独有**的，数出来的一定是它。
final Finder _hint = find.text('正在加载直播画面…');

Future<void> _unmount(WidgetTester t) async {
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump();
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 黑窗期 ⇒ 必须画出提示（占位臂）
  // ═══════════════════════════════════════════════════════════════════
  //
  // ```text
  // ⚠️ 诚实标注本条**测的是哪条臂**：
  //   `_createDelay`（380ms）窗口内 `_controller` 恒为 null
  //   ⇒ build 里那条 `c == null` **已经**让提示为真。
  //   ⇒ 本条证明的是“黑窗期画面上确实有东西、且文案在”，
  //     **不是**证明 task-92 新加的那条判据生效（那是 ②③④⑤ 的活）。
  // ```
  testWidgets('① 黑窗期 ⇒ 必须画出加载提示（含文案）', (t) async {
    final key = GlobalKey<LiveEmbeddedPlayerState>();
    try {
      await t.pumpWidget(_mount(key: key));
      await t.pump(const Duration(milliseconds: 60));
      _expectNoPlayerYet(key, '挂载后');

      expect(
        _hint,
        findsOneWidget,
        reason: '★★★ 黑窗期**必须**有提示。实测那段是 6.5~13.4 秒的**纯黑**'
            '（`.probe/ops/nf4/dual.csv`：播放器区域 24 帧恒 mean=0.0），'
            '用户除了黑什么都看不到 —— 这正是 Owner 报的第 1′ 条。'
            '★ 文案必须是**非空**的：光一个转圈盖 13 秒会让人以为卡死'
            '（`_EmbedLoading` 现在传 `label: 正在加载直播画面…`）。',
      );
      debugPrint('VERDICT F1 black_window_hint=present');
    } finally {
      await _unmount(t);
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 见到视频轨 ⇒ 判据必须立刻翻假
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('② ★ 见到视频轨（dw 到手）⇒ 判据必须立刻翻假', (t) async {
    final key = GlobalKey<LiveEmbeddedPlayerState>();
    try {
      await t.pumpWidget(_mount(key: key));
      await t.pump(const Duration(milliseconds: 60));
      expect(
        key.currentState!.awaitingFirstVideoFrameForTest,
        isTrue,
        reason: '★ 前置：黑窗期判据为真（否则下面那条是空断言）',
      );

      key.currentState!.debugSetVideoTrackSeen(true);
      await t.pump(const Duration(milliseconds: 60));

      expect(
        key.currentState!.awaitingFirstVideoFrameForTest,
        isFalse,
        reason: '★★ 见到视频轨之后判据必须**立刻**翻假 —— 提示随即从 build 里撤掉。'
            '\n  · 若仍为真 ⇒ 提示会盖在已经出来的画面上（比纯黑更糟）；'
            '\n  · 判据必须是“轨到了”而不是“首帧渲染了” —— 后者在本控件里'
            '    拿不到（media_kit_video 的 `VideoOutput.Resize` 只在**尺寸变化**时'
            '    发，`windows/video_output.cc:241-266 CheckAndResize` 会提前 return）。',
      );
      debugPrint('VERDICT F2 predicate_false_after_track=true');
    } finally {
      await _unmount(t);
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 阴性对照：无视频轨 ⇒ 必须收口（否则转圈永不消失）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('③ ★ 阴性对照：判成“本来就没有视频轨” ⇒ 判据必须收口', (t) async {
    final key = GlobalKey<LiveEmbeddedPlayerState>();
    try {
      await t.pumpWidget(_mount(key: key));
      await t.pump(const Duration(milliseconds: 60));
      expect(key.currentState!.awaitingFirstVideoFrameForTest, isTrue,
          reason: '★ 前置：提示在');

      key.currentState!.debugSetNoVideoTrackSettled(true);
      await t.pump(const Duration(milliseconds: 60));

      expect(
        key.currentState!.awaitingFirstVideoFrameForTest,
        isFalse,
        reason: '★★★ 纯音频/无视频轨的台**永远**不会有 `dw`。'
            '\n  若不收口 ⇒ 转圈**永不消失**，而转圈在语义上是“马上就有画面”'
            '  ⇒ 那是对用户**撒谎**（`live_embedded_player.dart` 的'
            '     `:1406-1407` 记着同一条纪律：“输出层已死时不画转圈”）。',
      );
      expect(
        key.currentState!.videoOutputDeadForTest,
        isFalse,
        reason: '★★ 收口**不许**顺手置“输出层已死” —— 音频在正常播，'
            '弹“画面不会有”是**误报**（`:800-802` 的“纯音频台不误报”纪律）。',
      );
      debugPrint('VERDICT F3 no_video_track_settles=true dead=false');
    } finally {
      await _unmount(t);
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 阴性对照：仅音频台 ⇒ 判据必须恒假（不与 _AudioOnlyBadge 叠字）
  // ═══════════════════════════════════════════════════════════════════
  testWidgets('④ ★ 阴性对照：audioOnly 台 ⇒ 判据必须恒假', (t) async {
    final key = GlobalKey<LiveEmbeddedPlayerState>();
    try {
      await t.pumpWidget(_mount(key: key, audioOnly: true));
      await t.pump(const Duration(milliseconds: 60));

      expect(
        key.currentState!.videoTrackSeenForTest,
        isFalse,
        reason: '★ 前置：它同样“还没见到视频轨” —— 所以下面那条不是靠状态凑出来的',
      );
      expect(
        key.currentState!.awaitingFirstVideoFrameForTest,
        isFalse,
        reason: '★★ `audioOnly` 台由 `_AudioOnlyBadge`（`:1396-1397`）负责解释'
            '  “为什么没画面”。两个都是 `Center` 里的居中卡片 ⇒ 同时出现会'
            '  **互相盖字**（本仓反复踩过“两个居中提示叠字”）。',
      );
      debugPrint('VERDICT F4 audio_only_predicate=false');
    } finally {
      await _unmount(t);
    }
  });
  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 静态契约：判据必须收口在一个 getter 上
  // ═══════════════════════════════════════════════════════════════════
  group('task-92 静态契约', () {
    test('★★★ 提示判据必须走 `_awaitingFirstVideoFrame`（不许就地拼）', () {
      final src = _stripComments(_readFile('lib/ui/widgets/live_embedded_player.dart'));
      expect(
        src.contains('bool get _awaitingFirstVideoFrame'),
        isTrue,
        reason: '★ 判据 getter 不见了 —— 判据随代码漂移了，' '必须重新判决这个点，而不是删掉这条断言',
      );
      expect(
        src.contains('_awaitingFirstVideoFrame))'),
        isTrue,
        reason: '★★ build 里必须**真的用了**它。' '\n  只定义不调用 = 提示永远不出现，而上面 ①② 两条用例' '  用的还是 debug 钩子 ⇒ 会**假绿**（铁律 78：断言必须咬住真实路径）。',
      );
      expect(
        src.contains('!_videoTrackSeen &&'),
        isTrue,
        reason: '★ 判据第一项必须是“还没见到视频轨”',
      );
      debugPrint('VERDICT F5 gate_getter=used_in_build');
    });
  });
}

// ═══════════════════════════════════════════════════════════════════════
//  静态分析工具（照抄 `t48_live_embedded_doubletap_test.dart:370-380`）
// ═══════════════════════════════════════════════════════════════════════

String _readFile(String rel) {
  // ★ 相对路径按 `flutter test` 的工作目录（项目根）解析
  final f = File(rel);
  if (f.existsSync()) return f.readAsStringSync();
  return File('${Directory.current.path}/$rel').readAsStringSync();
}

/// 剥掉注释（`//` 行注释 **和** `/* */` 块注释）
///
/// ★ 必须剥：本仓的注释里大量出现被否定的代码片段（“**不**走 X”），
///   不剥就会把**注释里提到的**字符串当成真代码 ⇒ 假绿。
String _stripComments(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final c = s[i];
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      i += 2;
      var depth = 1;
      while (i < s.length && depth > 0) {
        if (s[i] == '/' && i + 1 < s.length && s[i + 1] == '*') {
          depth++;
          i += 2;
        } else if (s[i] == '*' && i + 1 < s.length && s[i + 1] == '/') {
          depth--;
          i += 2;
        } else {
          i++;
        }
      }
    } else {
      out.write(c);
      i++;
    }
  }
  return out.toString();
}