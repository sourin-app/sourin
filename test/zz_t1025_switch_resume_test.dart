@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  缺陷③（2026-10-25）：换源不续播
// ══════════════════════════════════════════════════════════════════════
//
// # 两条路径，两种坏法
// ```text
// ① 详情区换源（合并页）  —— **完全不续播**
//    `_onDetailSwitchSource` 以前只传 provider/id/title/cover，
//    连当前 `_position` 都没往下传；`applySession` 里又写死 `_pendingSeek = null`。
//
// ② 播放器内换源         —— 有续播意图，但有**竞态**
//    `_applySwitch` 写了 `_pendingSeek`，紧接着 `_loadSkipMarker()`
//    ⇒ 片头补判 `seek(69)` 可能抢在续播前面（谁后落地谁赢）。
// ```
//
// # 修法（契约 + 让位）
// ```text
// ① `PlayRequestData.resumeFrom`（`Duration?`，**不**参与 `isSameSessionAs`）
//    加进会话判据的后果：「同源换集」会被误判成"换了会话"⇒ 每次换集都重启流。
// ② 详情区传 `_session?.currentPosition`（`MediaSession` 上的只读 getter）
// ③ `applySession`：`resumeFrom > 3s` 才写进 `_pendingSeek`（短的不续播）
// ④ `_maybeSkip` 在 `_pendingSeek != null` 期间直接 return（竞态消除）
// ⑤ 「换集不续播」保持不变（换集走 `_gotoEpisode`，不传 resumeFrom）
// ```
//
// # 跑法
// ```powershell
// flutter test test/zz_t1025_switch_resume_test.dart --concurrency=1 --run-skipped --tags native-media
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 挂页，并把**核心传输**换成可控夹具（只换网络，不换生产会话逻辑）
///
/// 与 `zz_t1023_player_seek_behavior_test` 同一手法：
/// ```text
/// SourinApi.debugResolveStreamFetcher  ⇒ 解析流（挂起，让 applySession 停在中间）
/// SourinApi.debugSkipMarkerFetcher     ⇒ 片头标记（给 null，避免干扰）
/// ```
Future<Completer<List<StreamCandidate>>> mountWithStalledResolve(
  WidgetTester t,
) async {
  SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
  await fixture.mountPlayer(t);
  final resolution = Completer<List<StreamCandidate>>();
  SourinApi.debugResolveStreamFetcher =
      (String provider, String id, {PlayRequest? req}) => resolution.future;
  addTearDown(() {
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    if (!resolution.isCompleted) {
      resolution.complete(<StreamCandidate>[]);
    }
  });
  return resolution;
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

  testWidgets('① 详情区换源带 resumeFrom: 300s ⇒ `_pendingSeek == 300s`', (t) async {
    await mountWithStalledResolve(t);

    final applying = debugPlayerApplySessionForProbe(const PlayRequestData(
      provider: 'resume-fixture',
      id: 'switch-to-b',
      title: '换源到 B',
      resumeFrom: Duration(seconds: 300),
    ));
    await t.pump();

    expect(debugPlayerSessionKeyForProbe(), 'resume-fixture:switch-to-b',
        reason: '★ 会话身份必须真的换了（否则下面读到的是旧会话）');
    expect(debugPlayerPendingSeekForProbe(), const Duration(seconds: 300),
        reason: '★★★ 换源续播契约：`resumeFrom` 必须落进 `_pendingSeek`，'
            '否则新流从 0 开始播（用户看到"换源后回到开头"）');

    applying.ignore();
    await fixture.drain(t);
  });

  testWidgets('② 阴性对照：不带 resumeFrom 的会话切换 ⇒ `_pendingSeek == null`', (t) async {
    await mountWithStalledResolve(t);

    final applying = debugPlayerApplySessionForProbe(const PlayRequestData(
      provider: 'resume-fixture',
      id: 'switch-to-c',
      title: '换集（不续播）',
    ));
    await t.pump();

    expect(debugPlayerSessionKeyForProbe(), 'resume-fixture:switch-to-c');
    expect(debugPlayerPendingSeekForProbe(), isNull,
        reason: '★★ 「换集不续播」必须保持不变 —— '
            '若这里续播，用户点下一集会从上一集的位置继续放');

    applying.ignore();
    await fixture.drain(t);
  });

  testWidgets('③ `resumeFrom` 只有 > 3 秒才生效（2 秒 ⇒ 从头播）', (t) async {
    await mountWithStalledResolve(t);

    final applying = debugPlayerApplySessionForProbe(const PlayRequestData(
      provider: 'resume-fixture',
      id: 'switch-to-d',
      title: '刚开播就换源',
      resumeFrom: Duration(seconds: 2),
    ));
    await t.pump();

    expect(debugPlayerPendingSeekForProbe(), isNull,
        reason: '★★ 3 秒阈值（计划原文）：刚开播就换源不该续播那 2 秒');
    expect(debugPlayerPendingSeekForProbe(), isNot(const Duration(seconds: 2)));

    applying.ignore();
    await fixture.drain(t);
  });

  testWidgets('④ 换源续播期间 `_maybeSkip` 不许抢跑（竞态消除）', (t) async {
    await mountWithStalledResolve(t);

    final applying = debugPlayerApplySessionForProbe(const PlayRequestData(
      provider: 'resume-fixture',
      id: 'switch-to-e',
      title: '换源到 E',
      resumeFrom: Duration(seconds: 300),
    ));
    await t.pump();
    expect(debugPlayerPendingSeekForProbe(), isNotNull,
        reason: '夹具自检：续播意图必须在');

    // 新源的片头标记到手（[0,69]）
    expect(debugPlayerSetAutoSkipForProbe(true), isTrue);
    expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 69), isTrue);
    debugPlayerResetSkipProbe();
    expect(debugPlayerResetIntroSkippedForProbe(), isTrue);

    // 位置流此刻刚 tick 到 5s（新流初始化位置）
    expect(debugPlayerMaybeSkipForProbe(const Duration(seconds: 5)), isTrue);
    expect(debugPlayerSkipSeekCalls(), 0,
        reason: '★★★ 续播落地前不许自动跳片头 —— '
            '否则 seek(69) 和 seek(300) 谁后落地谁赢，用户看到"跳到 69 秒"');
    expect(debugPlayerLastSkipSeek(), isNull);

    applying.ignore();
    await fixture.drain(t);
  });

  testWidgets('⑤ `MediaSession.currentPosition` 返回的是真实播放位置', (t) async {
    await fixture.mountPlayer(t);

    debugPlayerPushPositionForProbe(const Duration(seconds: 123));
    await t.pump();
    final pos = debugPlayerSessionCurrentPositionForProbe();
    expect(pos, isNotNull, reason: '★ 没挂页时探针返回 null —— 必须先判挂上');
    expect(pos!.inSeconds, 123,
        reason: '★★ 详情区换源就是拿这个值当 `resumeFrom`；'
            '它若恒为 0，换源续播的**起点**就是错的');

    await fixture.drain(t);
  });

  test('⑥ 源码契约：`resumeFrom` **不在** `isSameSessionAs` 判据里', () {
    final session = File('lib/ui/media_session.dart').readAsStringSync();
    final start = session.indexOf('bool isSameSessionAs(');
    expect(start, greaterThan(-1));
    final open = session.indexOf('{', start);
    var depth = 0;
    var end = -1;
    for (var i = open; i < session.length; i++) {
      if (session[i] == '{') depth++;
      if (session[i] == '}') {
        depth--;
        if (depth == 0) {
          end = i;
          break;
        }
      }
    }
    expect(end, greaterThan(open), reason: '`isSameSessionAs` 的大括号必须配平');
    final body = session.substring(open, end + 1);
    final code = body
        .split('\n')
        .where((l) {
          final t2 = l.trimLeft();
          return !t2.startsWith('//') && !t2.startsWith('*') && !t2.startsWith('/*');
        })
        .join('\n');
    expect(code, isNot(contains('resumeFrom')),
        reason: '★★★ `resumeFrom` 一旦进了会话判据，「同源换集」会被判成'
            '"换了会话" ⇒ 每次换集都白重启一次流（黑屏 + 丢进度）');
  });

  test('⑦ 源码契约：详情区换源的 resumeFrom 来自 `currentPosition` 且真的传下去', () {
    final src = File('lib/ui/media_page.dart').readAsStringSync();
    final start = src.indexOf('Future<void> _onDetailSwitchSource(');
    expect(start, greaterThan(-1), reason: '锚点不存在：`_onDetailSwitchSource`');
    final sub = src.substring(start, start + 6000);
    expect(sub, contains('_session?.currentPosition'),
        reason: '★★ 续播起点必须取自 `MediaSession.currentPosition`');
    expect(sub, contains('resumeFrom: resumeFrom'),
        reason: '★★★ 拿到了却不传给 `applySession` 等于没修（改前就是这个形态）');

    final player = File('lib/ui/player_page.dart').readAsStringSync();
    expect(player, contains('req.resumeFrom != null'),
        reason: '★ `applySession` 必须消费 `resumeFrom`');
    expect(player, contains('_pendingSeek = null;'),
        reason: '★ 换集路径仍然清 `_pendingSeek`（「换集不续播」不变）');
  });
}
