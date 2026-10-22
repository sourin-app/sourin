import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/live_availability.dart';

/// N15 门禁：播放结果驱动的可用性状态机
///
/// # 为什么这套判据长这样（全部来自实测，不是设计偏好）
///
/// 用户原话：
/// > 直播频道的可用性应该缓存,而不是每次都实时刷新,
/// > 然后定时刷新+打开如果不能播放,动态标记 定时再刷新掉状态
/// > + 有些直播不是一直播放的,这个也要注意
///
/// ## 实测结论（决定判据只能这么写）
/// ```text
/// 五类源喂工程自带的 libmpv-2.dll：
///   ① 正常 HLS        ⇒ 出画面，无 stream.error
///   ② 404 地址失效    ⇒ [stream] Failed to open <m3u8>
///   ③ 端口无监听      ⇒ [ffmpeg] tcp: Connection ... failed + 同②
///   ④ 空播放列表(没开播) ⇒ ★ 一条错误都没有
///   ⑤ 分片全 404      ⇒ [stream] Failed to open <分片.ts>
///
/// ④ 零信号的原因（查实）：mpv 只发 prefix='cplayer' level='fatal'
///   'No video or audio streams selected.'，而 media_kit real.dart:2075
///   只转发 level=='error' ⇒ 这条被丢弃。
///
/// ⇒ 判据只能是「有没有收到错误串」，不是「错误串长什么样」：
///   ②③⑤ 的文本几乎一样，靠文本细分必然出错。
/// ```
void main() {
  group('N15 判据 derive()：错误串优先于超时', () {
    test('★★★ 收到错误串 ⇒ broken（即使还没到超时时间）', () {
      final h = LivePlaybackHealthStore.derive(
        sawFrame: false,
        errorText: '[stream] Failed to open http://x/y.m3u8.',
        timedOut: false, // ★ 3 秒就报错，远没到 12 秒
      );
      expect(h, LivePlaybackHealth.broken,
          reason: '★ 错误串优先：用户已经看到明确失败原因，不必空等 12 秒');
    });

    test('★★★ 错误串 + 也超时了 ⇒ 仍是 broken（不是 idle）', () {
      final h = LivePlaybackHealthStore.derive(
        sawFrame: false,
        errorText: 'tcp: Connection to tcp://x failed',
        timedOut: true,
      );
      expect(h, LivePlaybackHealth.broken,
          reason: '★ 两者都成立时必须报 broken：它带原因，idle 不带');
    });

    test('★★★ 无错误串 + 超时 ⇒ idle（这才是"没开播"的候选）', () {
      final h = LivePlaybackHealthStore.derive(
        sawFrame: false,
        errorText: null,
        timedOut: true,
      );
      expect(h, LivePlaybackHealth.idle,
          reason: '★ 实测④空播放列表就是这种形态：12 秒没画面、一条错误都没有');
    });

    test('★★ 无错误串 + 没超时 ⇒ unknown（还没结论，不能标记）', () {
      final h = LivePlaybackHealthStore.derive(
        sawFrame: false,
        errorText: null,
        timedOut: false,
      );
      expect(h, LivePlaybackHealth.unknown,
          reason: '★ 3 秒还没画面就标灰点会把慢源全误判成"没开播"');
    });

    test('★★ 出过画面 ⇒ playable（错误串不该存在，但若存在则以错误为准）', () {
      expect(
        LivePlaybackHealthStore.derive(
            sawFrame: true, errorText: null, timedOut: true),
        LivePlaybackHealth.playable,
      );
      // 出过画面又收到错误 ⇒ 说明是"播放中断"，此刻仍是能播过的源
      // ★ 这里刻意断言 broken：因为 derive 的契约是"错误串优先"，
      //   调用方若要区分"中途中断"应自己先判 sawFrame（播放页已有该逻辑）
      expect(
        LivePlaybackHealthStore.derive(
            sawFrame: true, errorText: 'boom', timedOut: false),
        LivePlaybackHealth.broken,
      );
    });

    test('★ 空白错误串不算错误（trim 后为空）', () {
      expect(
        LivePlaybackHealthStore.derive(
            sawFrame: false, errorText: '   ', timedOut: true),
        LivePlaybackHealth.idle,
        reason: '★ 空串不能当"有错误"—— 那会把 idle 误判成 broken',
      );
      expect(
        LivePlaybackHealthStore.derive(
            sawFrame: false, errorText: '', timedOut: true),
        LivePlaybackHealth.idle,
      );
    });
  });

  group('N15 状态存储：回写与优先级', () {
    late LivePlaybackHealthStore store;
    late DateTime clock;

    setUp(() {
      clock = DateTime(2026, 10, 18, 12, 0, 0);
      store = LivePlaybackHealthStore(now: () => clock);
    });

    test('★★★ broken 一旦成立，idle 不得覆盖它', () {
      store.record(
          provider: 'p', channelId: 'c', health: LivePlaybackHealth.broken,
          detail: 'Failed to open');
      // 12 秒超时随后到 —— 不能把"有明确错误"抹成"没等到画面"
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.idle);

      expect(store.healthOf('p', 'c'), LivePlaybackHealth.broken,
          reason: '★ 否则用户看到的原因会从"源坏了"退化成含糊的"未检测到画面"');
      expect(store.entryOf('p', 'c')!.detail, 'Failed to open',
          reason: '★ 错误原文必须留住 —— 它是唯一的证据');
    });

    test('★★★ playable 可以覆盖 broken（真的播起来了是最硬证据）', () {
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.broken);
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.playable);

      expect(store.healthOf('p', 'c'), LivePlaybackHealth.playable);
    });

    test('★★ idle 可以被 playable 覆盖', () {
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.idle);
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.playable);
      expect(store.healthOf('p', 'c'), LivePlaybackHealth.playable);
    });

    test('★★ unknown 不产生记录（"没试过"不等于"有结论"）', () {
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.unknown);
      expect(store.length, 0);
      expect(store.healthOf('p', 'c'), LivePlaybackHealth.unknown);
    });

    test('★ 未记录过的频道读出来是 unknown（不是 broken）', () {
      expect(store.healthOf('nope', 'nope'), LivePlaybackHealth.unknown);
      expect(store.needsRetry('nope', 'nope'), isFalse);
    });
  });

  group('N15 定时刷新：只重试 idle/broken，且要过期', () {
    late LivePlaybackHealthStore store;
    late DateTime clock;

    setUp(() {
      clock = DateTime(2026, 10, 18, 12, 0, 0);
      store = LivePlaybackHealthStore(
        now: () => clock,
        retryAfter: const Duration(minutes: 10),
      );
    });

    test('★★★ 刚记录完不该立刻重试（要等 retryAfter）', () {
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.broken);
      expect(store.needsRetry('p', 'c'), isFalse,
          reason: '★ 刚失败就立刻重试会打成死循环，10 分钟与探测 TTL 一致');

      clock = clock.add(const Duration(minutes: 9));
      expect(store.needsRetry('p', 'c'), isFalse);

      clock = clock.add(const Duration(minutes: 2)); // 共 11 分钟
      expect(store.needsRetry('p', 'c'), isTrue);
    });

    test('★★★ playable 永远不需要重试（别浪费流量）', () {
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.playable);
      clock = clock.add(const Duration(hours: 5));
      expect(store.needsRetry('p', 'c'), isFalse);
    });

    test('★★ pendingRetries 只返回 idle/broken 且已过期的', () {
      store.record(provider: 'a', channelId: '1', health: LivePlaybackHealth.broken);
      store.record(provider: 'a', channelId: '2', health: LivePlaybackHealth.idle);
      store.record(provider: 'a', channelId: '3', health: LivePlaybackHealth.playable);

      expect(store.pendingRetries(), isEmpty, reason: '★ 都还没过期');

      clock = clock.add(const Duration(minutes: 11));
      final pending = store.pendingRetries();
      expect(pending.length, 2,
          reason: '★ 只重试 idle + broken；playable 不该被重试');
      expect(pending.map((e) => e.$2).toSet(), {'1', '2'});
    });

    test('★★★ 重试成功后 clear() 真的清掉（用户要的"定时再刷新掉状态"）', () {
      store.record(provider: 'p', channelId: 'c', health: LivePlaybackHealth.broken);
      clock = clock.add(const Duration(minutes: 11));
      expect(store.needsRetry('p', 'c'), isTrue);

      // 定时刷新试了一次，这次没报错也没超时失败 ⇒ 清掉标记
      store.clear('p', 'c');

      expect(store.healthOf('p', 'c'), LivePlaybackHealth.unknown,
          reason: '★ 清掉 = 回到 unknown ⇒ UI 不再显示红点，用户看到"它又活了"');
      expect(store.needsRetry('p', 'c'), isFalse);
      expect(store.length, 0);
    });

    test('★ clear 对没记录过的 key 是安全的（不抛）', () {
      expect(() => store.clear('x', 'y'), returnsNormally);
    });
  });

  group('N15 常量与边界', () {
    test('★★★ 起播超时 = 12 秒（实测：正常 HLS <2s，慢源到 8s，留 50% 余量）', () {
      expect(LivePlaybackHealthStore().bootTimeout,
          const Duration(seconds: 12));
    });

    test('★★ 重试间隔 = 10 分钟（与探测 TTL 一致）', () {
      expect(LivePlaybackHealthStore().retryAfter,
          const Duration(minutes: 10));
    });

    test('★ 每个状态都出现在枚举里（防止有人删档）', () {
      expect(LivePlaybackHealth.values.toSet(), {
        LivePlaybackHealth.unknown,
        LivePlaybackHealth.playable,
        LivePlaybackHealth.idle,
        LivePlaybackHealth.broken,
      });
    });

    test('★ retryable 只对 idle/broken 为真', () {
      LivePlaybackHealthEntry e(LivePlaybackHealth h) =>
          LivePlaybackHealthEntry(health: h, at: DateTime(2026));
      expect(e(LivePlaybackHealth.idle).retryable, isTrue);
      expect(e(LivePlaybackHealth.broken).retryable, isTrue);
      expect(e(LivePlaybackHealth.playable).retryable, isFalse);
      expect(e(LivePlaybackHealth.unknown).retryable, isFalse);
    });
  });

  group('N15 文案：idle 不能冒充确定', () {
    test('★★★ idle 的文案必须含"可能/未检测"，不能直接断言"未开播"', () {
      final t = liveHealthLabel(LivePlaybackHealth.idle);
      expect(t.contains('未检测'), isTrue,
          reason: '★ idle 的真实含义是"我们没等到画面"，'
              '不一定是"频道没开播"——也可能是我们超时太短');
      expect(t.contains('未开播') && !t.contains('可能'), isFalse,
          reason: '★ 把推断说成事实，违背"不知道就说不知道"');
    });

    test('★★ broken 的文案与 idle 不同（两者对用户意义完全不同）', () {
      expect(liveHealthLabel(LivePlaybackHealth.broken),
          isNot(liveHealthLabel(LivePlaybackHealth.idle)));
      expect(liveHealthLabel(LivePlaybackHealth.broken).contains('不可用'), isTrue);
    });

    test('★ playable / unknown 不需要徽标（文案为空）', () {
      expect(liveHealthLabel(LivePlaybackHealth.playable), isEmpty);
      expect(liveHealthLabel(LivePlaybackHealth.unknown), isEmpty);
    });
  });
}
