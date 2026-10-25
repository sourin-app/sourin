@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  缺陷⑧（2026-10-25）：播放失败归因分层 —— 新增 `timeout` 档
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// 从最近两个版本开始一直展示这个  这一条流获取不到
// 内置代理获取不到流,不知道是播放器的问题还是插件的问题,排查都没办法排查
// ```
//
// # 为什么这句话是**误导**
// ```text
// mpv 的原文只有一句：Failed to open http://127.0.0.1:52199/s/18e110…/.
// 改前的归因只要看到「Failed to open + 环回地址」就判 proxy
//   ⇒ 文案「这一条流取不到」/「内置代理没起来」
// 而 Owner 日志里同一端口 40 秒后成功起播 ⇒ 代理一直活着，
// 真相是**首字节超过了 mpv 的 network-timeout**（四次失败都是 5.13 秒）。
// ```
//
// # 修法（三层，缺一层都不成立）
// ```text
// ① 新档位 `PlaybackFailureKind.timeout`，文案不提"代理"
// ② `classify(..., Duration? elapsed)`：原文没有耗时，只能靠播放器自己计时
// ③ 判据窗口 = `[t-0.5s, t+0.5s]`，t = `kPlaybackNetworkTimeoutSeconds`
//    —— **不许写字面量 5.0**（否则把 network-timeout 调大后这一档永远不命中）
// ```
//
// # 跑法
// ```powershell
// flutter test test/zz_t1024_player_failure_attribution_test.dart --concurrency=1 --run-skipped --tags native-media
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// Owner 本机日志里的**真实**失败文案（四次失败原文之一）
const kOwnerMpvFailure = 'Failed to open '
    'http://127.0.0.1:52199/s/18e1104af5b563881108bfdbd0/.';

/// 真正的"代理没起来"
const kRefused = 'Failed to connect: Connection refused';

PlaybackFailureKind kindOf(String text, {Duration? elapsed}) =>
    PlaybackErrorText.classify(text, elapsed: elapsed).kind;

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  test('① `timeout` 档存在，且文案里**不含「代理」二字**', () {
    expect(PlaybackFailureKind.values, contains(PlaybackFailureKind.timeout),
        reason: '★ 第七档必须存在（否则超时只能继续冒充 proxy）');

    final f = PlaybackErrorText.classify(kOwnerMpvFailure,
        elapsed: Duration(milliseconds: 5130));
    expect(f.kind, PlaybackFailureKind.timeout);
    expect(f.headline, isNotEmpty);
    expect(f.nextStep, isNotEmpty);
    expect(f.headline.contains('代理'), isFalse,
        reason: '★★★ 这一档存在的全部意义就是**不再把锅甩给代理**');
    expect(f.nextStep.contains('代理'), isFalse);
    expect(f.headline, '这条流等太久了');
    expect(f.canRetry, isTrue, reason: '★ 等太久是**可重试**的');
  });

  test('② 同一条文案，两个耗时两个结论（两向都断）', () {
    expect(kindOf(kOwnerMpvFailure, elapsed: const Duration(milliseconds: 5130)),
        PlaybackFailureKind.timeout,
        reason: '★★★ Owner 日志里四次失败都落在 5.13 秒 ⇒ 必须是 timeout');
    expect(
        kindOf(kOwnerMpvFailure, elapsed: const Duration(milliseconds: 200)),
        isNot(PlaybackFailureKind.timeout),
        reason: '★★ 0.2 秒就打不开，那是**真打不开**，不是等不及 '
            '（只断一个方向的话，"永远判 timeout"也能通过）');
    expect(
        kindOf(kOwnerMpvFailure, elapsed: const Duration(milliseconds: 200)),
        PlaybackFailureKind.proxy,
        reason: '★ 拿不到"等太久"证据时退回保守判断（维持既有行为）');
  });

  test('③ 阴性对照：`Connection refused` 配同样耗时 ⇒ 仍是 proxy', () {
    expect(kindOf(kRefused, elapsed: const Duration(milliseconds: 5130)),
        PlaybackFailureKind.proxy,
        reason: '★★★ 这才是"代理真没起来"。'
            '把超时判据写成"只认耗时"会让这条红');
    expect(kindOf(kRefused), PlaybackFailureKind.proxy,
        reason: '★ 不给 elapsed 时也必须认得出来');
  });

  test('④ 窗口跟着**常量**走，不是写死的 5.0', () {
    // 常量与 mpv 实际取值同源
    expect(kPlaybackNetworkTimeoutSeconds, 5,
        reason: '★ 当前取值与 media_kit 默认一致（real.dart:2394 的 5）');
    expect(kPlaybackTimeoutWindowSlack, const Duration(milliseconds: 500));

    final t = Duration(seconds: kPlaybackNetworkTimeoutSeconds);
    // 窗口 = [t-0.5s, t+0.5s]
    expect(kindOf(kOwnerMpvFailure, elapsed: t - const Duration(milliseconds: 600)),
        isNot(PlaybackFailureKind.timeout),
        reason: '★ 窗口下界之外 ⇒ 不是 timeout');
    expect(kindOf(kOwnerMpvFailure, elapsed: t - const Duration(milliseconds: 400)),
        PlaybackFailureKind.timeout,
        reason: '★ 窗口下界之内 ⇒ timeout');
    expect(kindOf(kOwnerMpvFailure, elapsed: t + const Duration(milliseconds: 400)),
        PlaybackFailureKind.timeout,
        reason: '★ 窗口上界之内 ⇒ timeout');
    expect(kindOf(kOwnerMpvFailure, elapsed: t + const Duration(milliseconds: 600)),
        isNot(PlaybackFailureKind.timeout),
        reason: '★ 窗口上界之外 ⇒ 不是 timeout（例如 8 秒才失败 = 别的原因）');

    // 源码判据：窗口表达式必须引用常量，不许写字面量
    final src = File('lib/core/sourin_api.dart').readAsStringSync();
    expect(src, contains('Duration? elapsed,'),
        reason: '★★ `classify` 的签名里必须有 elapsed（跨文件契约）');
    expect(src, contains('final timeoutWindow = Duration(seconds: kPlaybackNetworkTimeoutSeconds);'),
        reason: '★★★ 窗口必须**算出来** —— 计划里最容易踩空的一条：'
            '把 network-timeout 调大后，写死的 5.0 会让这一档变成死档');
    expect(src, contains('kPlaybackTimeoutWindowSlack'),
        reason: '★ 容差也必须来自常量');
    expect(
        RegExp(r'timeoutWindow\s*[+-]\s*Duration\(seconds:\s*5')
            .hasMatch(src),
        isFalse,
        reason: '★★ 窗口里不许出现字面量 5');
  });

  testWidgets('⑤ 起播失败路径**真的**把 elapsed 传进归因（5.1 秒 ⇒ timeout）', (t) async {
    await fixture.mountPlayer(t);
    // ★ 只清错误，**不**标首帧 —— 本用例要的就是"从未出过画面"的起播阶段
    expect(debugPlayerClearErrorForProbe(), isTrue);

    // 造出"已经等了 5.1 秒"的真实读数（起点往前拨）
    expect(debugPlayerAgeLoadStartForProbe(const Duration(milliseconds: 5100)),
        isTrue);
    expect(debugPlayerInjectStreamErrorForProbe(kOwnerMpvFailure), isFalse,
        reason: '★ 返回 false = 注入时"没出过画面" ⇒ 走的是起播失败那一支');

    final elapsed = debugPlayerStartFailureElapsedForProbe();
    expect(elapsed, isNotNull,
        reason: '★★★ 起播失败必须带耗时 —— 否则归因无从区分"等太久"与"真打不开"');
    expect(elapsed!.inMilliseconds, greaterThanOrEqualTo(5100));

    expect(debugPlayerFailureAttributionForProbe(), contains('kind=timeout'),
        reason: '★★★ 播放器测到的耗时必须真的流进 classify（不只是签名里有）');

    /*
     * ★★★ 上面那条读的是**状态字段**，还证不了"渲染路径那次 classify 也传了"。
     * 真正上屏的是 `build` 里
     * `failure: PlaybackErrorText.classify(..., elapsed: _startFailureElapsed)`。
     * ⇒ 断言浮层**文案**：这一档 headline 是「这条流等太久了」。
     * 把 `elapsed:` 改成 `null` ⇒ 浮层显示「这一条流取不到」⇒ 立刻红（故障注入 I8 实测）。
     */
    await t.pump();
    expect(find.text('这条流等太久了'), findsOneWidget,
        reason: '★★★ 起播失败浮层必须按 timeout 档给文案 —— '
            '证明渲染路径那次 classify 真的拿到了耗时');

    await fixture.drain(t);
  });

  testWidgets('⑥ 阴性对照：0.2 秒就失败 ⇒ 归 proxy，不是 timeout', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerAgeLoadStartForProbe(const Duration(milliseconds: 200)),
        isTrue);
    expect(debugPlayerInjectStreamErrorForProbe(kOwnerMpvFailure), isFalse);

    final attribution = debugPlayerFailureAttributionForProbe();
    expect(attribution, contains('kind=proxy'),
        reason: '★★ 真打不开（瞬间失败）不许被算成 timeout');
    expect(attribution, isNot(contains('kind=timeout')));

    await fixture.drain(t);
  });

  test('⑦ 源码契约：`network-timeout` 由**同一个常量**下发给 mpv', () {
    final player = File('lib/ui/player_page.dart').readAsStringSync();
    expect(player, contains("'network-timeout'"),
        reason: '★★ 点播播放器必须显式下发这条（改前只有直播组件设过 3 秒）');
    expect(player, contains("'\$kPlaybackNetworkTimeoutSeconds'"),
        reason: '★★★ 下发的值必须来自常量 —— '
            '归因窗口与 mpv 实际等待时间必须是同一个数字');
    expect(player, contains('elapsed: _startFailureElapsed'),
        reason: '★★★ 渲染路径那次 classify 必须把真实耗时传进去');
    expect(player, contains('_startFailureElapsed = elapsed;'),
        reason: '★ 起播失败分支必须真的写入耗时');
  });
}
