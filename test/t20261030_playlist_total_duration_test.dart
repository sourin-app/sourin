// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30（task-9）：playlistTotalMs 修正不可靠的 duration
//  DISCONTINUITY 清单下 mpv 只报当前分片时长（6/4/3s），整集真实 82.72s
// ═══════════════════════════════════════════════════════════════════════
//
// # 真机取证（已定论，勿再猜）
// ```text
// 那条 dur=6 的「第33集」清单原文：#EXT-X-TARGETDURATION:6
//   + #EXTINF:6/4 交替 17 段 + 两个 #EXT-X-DISCONTINUITY + #EXT-X-ENDLIST，
//   EXTINF 求和 = 82.720s。mpv 在不连续点重建时间轴 ⇒ stream.duration
//   报的是"当前分片时长"不是整集。内容正常播 82.72s，错的是时长读数。
// ```
//
// # 判据
// ```text
// ① models 解析：camelCase 键（与 Rust serde 逐字对齐）；缺键（旧 DLL）
//    安全降级 null/false 不抛；playlistTotalMs=0 ⇒ 权威值不可用；
// ② 真 _onDurationTick：_current 带清单事实 ⇒ 广播 6s 时 _duration/
//    遥控 duration/样片缓存全用 82（覆盖口径）；分片值 4s 再广播仍 82；
// ③ 无清单事实（普通源/旧 DLL）⇒ 广播值原样（展示零变化）。
// ```
//
// # 故障注入（实测见笔记）
// ```text
// 注入：_onDurationTick 退回"广播值直写"（覆盖失效）⇒ 组②红（读数回到 6）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
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
        title: '清单时长修正测试',
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

const StreamCandidate _cctvLine = StreamCandidate(
  url: 'https://x.invalid/33.m3u8',
  kind: 'hls',
  label: 'CDN 直连',
  // 真机取证形态：TARGETDURATION 6 但 EXTINF 求和 82.72s + 2 个 DISCONTINUITY
  playlistTotalMs: 82720,
  playlistDiscontinuous: true,
);

void main() {
  setUpAll(_prepareLibmpvFixture);

  setUp(() {
    // 线路时长缓存经 UiPrefs 持久化 —— 用例间隔离
    // ignore: unnecessary_import
  });

  group('① StreamCandidate 解析（与 Rust serde camelCase 逐字对齐）', () {
    test('★★ 带清单事实的 JSON：两字段解析正确', () {
      final s = StreamCandidate.fromJson(const {
        'url': 'https://x.invalid/33.m3u8',
        'kind': 'hls',
        'playlistTotalMs': 82720,
        'playlistDiscontinuous': true,
      });
      expect(s.playlistTotalMs, 82720);
      expect(s.playlistDiscontinuous, isTrue);
      expect(s.authoritativeDuration, const Duration(milliseconds: 82720),
          reason: '权威整集时长 = 82.72s（EXTINF 求和），不是 TARGETDURATION 的 6s');
    });

    test('★★ 旧 DLL（缺两键）：安全降级 null/false，不抛', () {
      final s = StreamCandidate.fromJson(const {
        'url': 'https://x.invalid/1.m3u8',
        'kind': 'hls',
      });
      expect(s.playlistTotalMs, isNull);
      expect(s.playlistDiscontinuous, isFalse);
      expect(s.authoritativeDuration, isNull);
    });

    test('playlistTotalMs=0 / 负值 ⇒ 权威值不可用（>0 判据）', () {
      final s = StreamCandidate.fromJson(const {
        'url': 'u',
        'playlistTotalMs': 0,
      });
      expect(s.playlistTotalMs, 0);
      expect(s.authoritativeDuration, isNull,
          reason: '0/负值是"清单没量出来"的形态，不许当权威值覆盖观测值');
    });

    test('playlistDiscontinuous 缺键 ⇒ false（不许默认 true 触发提示）', () {
      final s = StreamCandidate.fromJson(const {'url': 'u'});
      expect(s.playlistDiscontinuous, isFalse);
    });
  });

  group('② 真树：清单事实覆盖分片伪影（_onDurationTick 覆盖口径）', () {
    testWidgets('广播 6s ⇒ 总时长/缓存全用 82；广播 4s 仍 82', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);

      expect(debugPlayerSetStreamsForProbe(const [_cctvLine]), isTrue);
      expect(debugPlayerSetAggregateTitleForProbe(current: _cctvLine), isTrue,
          reason: '灌当前流（_current 带清单事实）');
      await t.pump();

      // ★ mpv 报"当前分片"6s（真机取证形态）
      debugPlayerPushDurationForProbe(const Duration(seconds: 6));
      await t.pump();
      await t.pump(const Duration(milliseconds: 400)); // 过 UiPrefs 防抖 Timer

      final st1 = debugPlayerRemoteStateForProbe();
      expect(st1.hasMedia, isTrue, reason: '前提：探针拿到真实 state');
      expect(st1.duration, 82,
          reason: '★★ 遥控/显示用的总时长必须是 82（EXTINF 求和），'
              '不是 mpv 分片伪影 6 —— Owner 报的「6 秒」问题本体');
      expect(
        debugPlayerLineDurationForProbe(
            lineDurationKey(provider: 'cctv', contentId: 'cctv-1', s: _cctvLine)),
        82,
        reason: '★ 1.3 样片缓存记的也是权威值 —— 记 6s 会把 82.72s 的完整内容'
            '误判成「疑似样片」并错误跳过默认线');
      expect(debugPlayerEpisodeIndexForProbe(), 0,
          reason: '连播判据不被触碰（切集结构性不受影响）');

      // ★ 分片切换：mpv 报 4s（DISCONTINUITY 后时间轴重建）⇒ 仍 82
      debugPlayerPushDurationForProbe(const Duration(seconds: 4));
      await t.pump();
      expect(debugPlayerRemoteStateForProbe().duration, 82,
          reason: '时间轴重建后分片值再变（6→4），权威总时长恒 82');
    });

    testWidgets('无清单事实（普通源/旧 DLL）⇒ 广播值原样（展示零变化）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      const s = StreamCandidate(url: 'https://x.invalid/1.m3u8', kind: 'hls');
      expect(debugPlayerSetStreamsForProbe(const [s]), isTrue);
      expect(debugPlayerSetAggregateTitleForProbe(current: s), isTrue);
      await t.pump();

      debugPlayerPushDurationForProbe(const Duration(seconds: 6));
      await t.pump();
      expect(debugPlayerRemoteStateForProbe().duration, 6,
          reason: '没有清单事实 ⇒ mpv 读数原样（普通源行为逐字不变）');
    });
  });
}
