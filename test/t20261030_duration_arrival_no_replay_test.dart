@Tags(['native-media'])
// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：duration 到账的行为边界（ep 回跳排查产物）
//  「duration 广播只更新状态 + 写线路时长缓存，绝不二次起播/换集」
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景（真机 ep2→ep1 单次回跳，driver-ops 假设 + 代码级排查）
// ```text
// 真机：老舅 cctv 10s 样片连播，ep2 首帧后 ~3s 出现第二次起播、/api/state
// 读数落 ep1。driver-ops 假设：duration 测量完成（<60s 命中 1.3 样片判据）
// ⇒ 触发默认选线重评估 ⇒ 二次 resolve。
// 代码级排查结论（dart-player）：**假设不成立** ——
//   · _recordLineDuration 只写内存缓存 + UiPrefs，无 setState 之外的任何动作；
//   · pickDefaultPlayable 全仓唯一调用点在 _load() 内部（resolve 返回后的
//     既有流程），duration 广播不会进入它；
//   · _sampleBadgeFor 只在线路面板 build 时读。
// ⇒ duration 到账"只更新缓存与标注、绝不重选线/重跳集"是**现状不变量**，
//   本文件把它钉成门禁（防将来有人把选线/重试逻辑挂进这条监听）。
// ```
//
// # 判据
// ```text
// ① 生产 _onDurationTick（mpv 订阅与探针同调一份）：灌一次 duration ⇒
//    _startPlayback 调用数**不变**（无二次起播）、_epIndex 不变（不换集）、
//    线路时长缓存**真的记了**（1.3 的本职工作没被砍）；
// ② 静态边界：duration 监听体只允许走 _onDurationTick（抽方法防漂移）。
// ```
//
// # 故障注入（实测见笔记）
// ```text
// 注入：_onDurationTick 里挂上"duration 到账 ⇒ 重播首候选"（模拟假设中的
// 回归形态）⇒ 组① 调用数断言红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/player_page.dart';

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

List<Episode> _eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv-1',
        title: 'duration 边界测试',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  debugPlayerClearErrorForProbe();
}

void main() {
  setUpAll(_prepareLibmpvFixture);

  setUp(() {
    // ★ 线路时长缓存会经 UiPrefs 持久化 —— 用例间必须隔离（本进程内共享）
    UiPrefs.debugResetForTest();
  });

  testWidgets('① duration 到账 ⇒ 只写缓存，绝不二次起播/换集', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);

    const s = StreamCandidate(url: 'https://x.invalid/1.m3u8', label: '线路A');
    expect(debugPlayerSetStreamsForProbe(const [s]), isTrue);
    expect(debugPlayerSetAggregateTitleForProbe(current: s), isTrue,
        reason: '灌当前流（_recordLineDuration 的键需要 _current）');
    await t.pump();

    final calls0 = debugPlayerStartPlaybackCallsForProbe();
    final index0 = debugPlayerEpisodeIndexForProbe();
    expect(calls0, isNotNull, reason: '前提：播放页已挂上');
    final key = lineDurationKey(provider: 'cctv', contentId: 'cctv-1', s: s);

    // ★ 灌一次 duration 广播（10s 样片形态 —— 命中 1.3 缓存写入）
    debugPlayerPushDurationForProbe(const Duration(seconds: 10));
    await t.pump();
    // 缓存落盘走 UiPrefs 的 300ms 防抖 Timer —— pump 过它，否则
    // "Timer still pending" 假红（与断言无关，纯仪器）
    await t.pump(const Duration(milliseconds: 400));

    expect(debugPlayerStartPlaybackCallsForProbe(), calls0,
        reason: '★★ duration 到账**绝不**触发二次起播（driver-ops 假设的'
            '回归形态在这里会被抓：调用数 +1 即红）');
    expect(debugPlayerEpisodeIndexForProbe(), index0,
        reason: '★ 不换集（ep 回跳的表象是集序回跳，这里结构性钉住）');
    expect(debugPlayerLineDurationForProbe(key), 10,
        reason: '★ 缓存本职工作必须还在：1.3 的时长写入不许被砍');
  });

  testWidgets('② duration 为零/负 ⇒ 连缓存都不写（宁缺勿错）', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t);
    const s = StreamCandidate(url: 'https://x.invalid/1.m3u8', label: '线路A');
    expect(debugPlayerSetStreamsForProbe(const [s]), isTrue);
    expect(debugPlayerSetAggregateTitleForProbe(current: s), isTrue);
    await t.pump();
    final calls0 = debugPlayerStartPlaybackCallsForProbe();

    debugPlayerPushDurationForProbe(Duration.zero);
    await t.pump();

    expect(debugPlayerStartPlaybackCallsForProbe(), calls0);
    expect(
      debugPlayerLineDurationForProbe(
          lineDurationKey(provider: 'cctv', contentId: 'cctv-1', s: s)),
      isNull,
      reason: '量坏了的读数（0）不进缓存 —— 与 isSuspectedSampleLine 的'
          '"null/≤0 不冤枉"口径一致',
    );
  });

  test('③ 静态边界：duration 监听体只允许走 _onDurationTick（抽方法防漂移）', () {
    final src = File('lib/ui/player_page.dart').readAsStringSync();
    expect(src.contains('_player.stream.duration.listen(_onDurationTick)'), isTrue,
        reason: '监听体必须收敛到生产方法 —— 内联回调会让"边界"没有单一执行点，'
            '将来把选线/重试挂进去时本文件的运行时断言抓不到');
  });
}
