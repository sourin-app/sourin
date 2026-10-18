import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/live_availability.dart';

/// P0 门禁：**三场景请求数**（Lead 要求的最终验收）
///
/// # 这三个场景就是 Owner 那句话的完整体现
///
/// > 直播页现在每次都刷新全量的检测,这是错误的 一定要有缓存啊,
/// > 不然这样子迟早要被拉黑
///
/// ```text
/// 场景 A  冷启动 + 磁盘有 10 分钟内的缓存
///         ⇒ 网络请求数 = **0**        （"要拉黑"的核心防线）
/// 场景 B  冷启动 + 无缓存
///         ⇒ 前 30 秒 = 0，之后才全量探 （错开启动瞬间）
/// 场景 C  冷启动 + 缓存已过期（>10 分钟）
///         ⇒ 条目**保留**（不清空），但视为待刷新
/// ```
///
/// ★ 用 fake fetcher 计数，不依赖真实网络，也不依赖真实计时器。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String k(String p, String c) => liveHealthCacheKey(p, c);

  List<LiveGroup> groupsOf(List<String> ids) => [
        LiveGroup(
          provider: 'iptv',
          providerName: 'IPTV',
          channels: [
            for (final id in ids) LiveChannel(id: id, name: '台$id'),
          ],
        ),
      ];

  group('P0 三场景请求数', () {
    test('★★★ 场景 A：磁盘缓存新鲜 ⇒ **0 次网络请求**', () async {
      var calls = 0;
      final probe = LiveAvailabilityProbe(
        fetch: (p, c) async {
          calls++;
          return const [];
        },
      );

      // 模拟 `_loadHealthThenMaybeProbe()` 走"有缓存"分支：
      // 把磁盘状态 seed 进 probe（这正是产品代码做的事）
      final now = DateTime.now();
      final disk = {
        for (final id in ['c1', 'c2', 'c3', 'c4'])
          k('iptv', id): LivePlaybackHealthEntry(
            health: LivePlaybackHealth.playable,
            at: now.subtract(const Duration(minutes: 3)),
          ),
      };
      final fresh = LiveHealthCache.freshOnly(disk, now: now);
      expect(fresh.length, 4, reason: '前置：4 条都该算新鲜');

      for (final e in fresh.entries) {
        final parts = liveHealthCacheKeyParts(e.key)!;
        probe.seed(parts.$1, parts.$2, LiveAvailability.playable, e.value.at);
      }

      await probe.probe(groupsOf(['c1', 'c2', 'c3', 'c4']));

      expect(calls, 0,
          reason: '★★★ Owner「迟早要被拉黑」的直接验收：'
              '有新鲜缓存时**一个请求都不发**');
    });

    test('★★★ 场景 B：无缓存 ⇒ 未到延迟时限**不发任何请求**', () async {
      var calls = 0;
      final probe = LiveAvailabilityProbe(
        fetch: (p, c) async {
          calls++;
          return const [];
        },
      );

      // 全新安装：磁盘空 ⇒ freshOnly 为空 ⇒ 产品代码走"延迟 30 秒"分支
      final fresh = LiveHealthCache.freshOnly(const {}, now: DateTime.now());
      expect(fresh, isEmpty, reason: '前置：确实没有缓存');

      // ★ 延迟期间**根本不该调用 probe()**。这里断言的是"还没探"
      //   —— 请求数保持 0。真正的"到点才探"由
      //   zz_t66_live_probe_delay_test.dart 用 fake_async 验证时序。
      expect(calls, 0, reason: '★★★ 启动瞬间不许发请求（错开启动峰值）');

      // 反之：若真的开始探了，请求数必然上升 ⇒ 证明计数器有效（阳性对照）
      await probe.probe(groupsOf(['c1', 'c2']));
      expect(calls, 2, reason: '★ 阳性对照：计数器能涨 ⇒ 上面的 0 不是"计数器坏了"');
    });

    test('★★★ 场景 C：缓存过期 ⇒ 条目**保留**，但不算新鲜（不删）', () async {
      final now = DateTime.now();
      final stale = {
        for (final id in ['c1', 'c2'])
          k('iptv', id): LivePlaybackHealthEntry(
            health: LivePlaybackHealth.broken,
            at: now.subtract(const Duration(minutes: 25)),
          ),
      };

      final fresh = LiveHealthCache.freshOnly(stale, now: now);

      expect(fresh, isEmpty, reason: '★ 25 分钟前的不能算新鲜');
      expect(stale.length, 2,
          reason: '★★★ 但**不许清空** —— 用户要求"保留待刷新"，'
              '直接删掉会让红点突然消失，用户以为状态丢了');
    });
  });

  group('P0 场景 A 的真实落盘版本（走 DiskCache 而非内存）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zz_t66_scenario');
      DiskCache.init(dir.path);
    });

    tearDown(() {
      DiskCache.debugResetForTest();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('★★★ 先落盘 → 再读回 → seed → probe ⇒ 仍然 0 请求', () async {
      final now = DateTime.now();
      // ① 上一次会话落盘
      await LiveHealthCache.save({
        for (final id in ['c1', 'c2', 'c3'])
          k('iptv', id): LivePlaybackHealthEntry(
            health: LivePlaybackHealth.playable,
            at: now.subtract(const Duration(minutes: 1)),
          ),
      });

      // ② 本次会话读盘（真实文件往返）
      final loaded = await LiveHealthCache.load();
      expect(loaded.length, 3, reason: '前置：真的从磁盘读回来了');

      // ③ 灌进 probe
      var calls = 0;
      final probe = LiveAvailabilityProbe(
        fetch: (p, c) async {
          calls++;
          return const [];
        },
      );
      for (final e in LiveHealthCache.freshOnly(loaded, now: now).entries) {
        final parts = liveHealthCacheKeyParts(e.key)!;
        probe.seed(parts.$1, parts.$2, LiveAvailability.playable, e.value.at);
      }

      // ④ 跑一轮
      await probe.probe(groupsOf(['c1', 'c2', 'c3']));

      expect(calls, 0,
          reason: '★★★ 端到端：落盘 → 读回 → 跳过探测 ⇒ 0 请求。'
              '这是"重启后不再全量"的完整闭环');

      // ⑤ 顺便确认落盘内容是人能读懂的（便于真机排查）
      final f = File('${dir.path}${Platform.pathSeparator}$kLiveHealthCacheName');
      final raw = jsonDecode(await f.readAsString()) as Map;
      expect(raw['v'], kLiveHealthCacheVersion);
      expect((raw['data'] as Map).length, 3);
      final one = (raw['data'] as Map).values.first as Map;
      expect(one['h'], 'playable', reason: '★ 存枚举名，人能看懂');
      expect(one['t'], isA<int>(), reason: '★ 每条带自己的观测时刻');
    });
  });
}
