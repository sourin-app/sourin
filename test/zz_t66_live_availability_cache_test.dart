import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/live_availability.dart';

/// P0 门禁：直播可用性的**持久化**（Owner：「迟早要被拉黑」）
///
/// # 为什么这条最要紧
///
/// 用户原话：
/// > 直播页现在每次都刷新全量的检测,这是错误的 一定要有缓存啊,
/// > 不然这样子迟早要被拉黑
///
/// ## 病因（**不是** TTL 太短）
/// ```text
/// `LiveAvailabilityProbe._result` 与 `SourinApi._liveStreamCache`
/// 都是**进程内存** ⇒ 进程一退就没了 ⇒ 每次启动从零全量探测 1248 个频道。
/// ⚠️ 把 TTL 从 30 秒改成 10 分钟解决不了这件事
///    （内存里 TTL 多长，进程一退都要重来），
///    还会带回"点重试没用"的老 bug（见 sourin_api.invalidateLiveStream）。
/// ⇒ 唯一有效的对策是**落盘**。
/// ```
///
/// ## 这套门禁防的是什么
/// ```text
/// ① 序列化能往返（状态与观测时间都原样恢复）
/// ② 过期条目**不**被当成新鲜的（但**也不删** —— 用户要"保留待刷新"）
/// ③ 损坏的 JSON 一律降级为"无缓存"，绝不能抛（否则直播页打不开）
/// ④ unknown 不落盘（"没观测过"不该变成一条记录）
/// ⑤ 四态原样保存 —— 不许压成 bool（idle ≠ broken，意义完全不同）
/// ```
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final t0 = DateTime(2026, 10, 18, 12, 0, 0);

  /// 唯一的键格式（
  /// ★ 测试**必须**用它，不能手写 'a|b' ——
  ///   手写正是这次抓到的 bug：持久化用 '|'、store 用 NUL，永远不命中。
  String k(String provider, String channelId) =>
      liveHealthCacheKey(provider, channelId);


  LivePlaybackHealthEntry e(LivePlaybackHealth h, DateTime at, [String? d]) =>
      LivePlaybackHealthEntry(health: h, at: at, detail: d);

  group('P0 键格式：生成与解析必须互逆（防"写进去却读不出"）', () {
    /*
     * ★★★ 这一组是补测出来的**真缺口**（如实记录）
     *
     * 我第一版门禁跑 +22 全绿，但故障注入"把键改成管道符"**没有变红**。
     * 查清原因：
     * ```text
     * `LivePlaybackHealthStore._key()` 与 `LiveHealthCache` **都调**同一个
     * `liveHealthCacheKey()` ⇒ 两边同时改，仍然自洽 ⇒ 往返测试全部通过。
     * ⇒ 我的门禁只测到了"自洽性"，**没测到"生成与解析互逆"**。
     * ```
     * 而原始 bug 恰恰是**不对称**：生成用 NUL、解析按 `|` 切
     * ⇒ 缓存文件看起来正常，重启后一个徽标都没有，且日志无任何报错。
     *
     * ⇒ 补这一组：直接咬住 `key()` 与 `parts()` 互为逆运算。
     */
    test('★★★ 生成 → 解析 必须原样还原 provider 与 channelId', () {
      const cases = [
        ('iptv', 'CCTV1'),
        ('huya-live', 'abc123'),
        ('p', 'c'),
        // ★ 频道 id 里真的可能带竖线 —— 这正是不能用 '|' 当分隔符的原因
        ('p', 'a|b'),
        ('p|q', 'r'),
      ];
      for (final (provider, channelId) in cases) {
        final key = liveHealthCacheKey(provider, channelId);
        final back = liveHealthCacheKeyParts(key);
        expect(back, isNotNull, reason: '必须能解析：$key');
        expect(back!.$1, provider, reason: 'provider 必须原样还原（key=$key）');
        expect(back.$2, channelId, reason: 'channelId 必须原样还原（key=$key）');
      }
    });

    test('★★★ 分隔符必须是 NUL 而不是 "|"（否则含竖线的 id 会串味）', () {
      // 这是原始 bug 的直接防线：两种分隔符的往返结果不同
      const provider = 'p';
      const withPipe = 'a|b';
      final key = liveHealthCacheKey(provider, withPipe);
      expect(key.contains('\u0000'), isTrue,
          reason: '★ 分隔符必须是 NUL —— 用 "|" 的话 channelId 里的竖线会被误当成边界');
      final back = liveHealthCacheKeyParts(key);
      expect(back!.$2, withPipe, reason: '★ 含竖线的 id 必须完整还原，不能被切碎');
    });

    test('★★ 格式不对时返回 null（不猜）', () {
      for (final bad in ['', 'no-separator', '\u0000only', 'tail\u0000']) {
        expect(liveHealthCacheKeyParts(bad), isNull,
            reason: '解析不了就返回 null，绝不返回半个结果');
      }
    });

    test('★★★ store 的键与持久化的键**必须一致**（跨层契约）', () {
      final store = LivePlaybackHealthStore();
      store.record(
          provider: 'iptv', channelId: 'CCTV1', health: LivePlaybackHealth.broken);
      final snapKey = store.snapshot().keys.single;
      expect(snapKey, liveHealthCacheKey('iptv', 'CCTV1'),
          reason: '★ 若 store 与持久化各用一套键，落盘再读回将永远不命中');
      expect(liveHealthCacheKeyParts(snapKey)!.$2, 'CCTV1');
    });
  });

  group('P0 持久化 ①②：序列化往返', () {
    test('★★★ 四态 + 观测时间 + 错误原文 都能原样往返', () {
      final src = {
        k('iptv','CCTV1'): e(LivePlaybackHealth.broken, t0.add(const Duration(minutes: 1)),
            '[stream] Failed to open http://x/y.m3u8.'),
        k('iptv','CCTV2'): e(LivePlaybackHealth.idle, t0.add(const Duration(minutes: 2))),
        k('huya','abc'): e(LivePlaybackHealth.playable, t0.add(const Duration(minutes: 3))),
      };

      final back = LiveHealthCache.decode(
        jsonDecode(jsonEncode(LiveHealthCache.encode(src))),
      );

      expect(back.length, 3);
      for (final k in src.keys) {
        expect(back[k]!.health, src[k]!.health, reason: '状态必须一致');
        expect(back[k]!.at, src[k]!.at, reason: '★ 观测时间必须一致 —— '
            '丢了它就分不清"刚探的"和"一小时前的"');
        expect(back[k]!.detail, src[k]!.detail, reason: '错误原文是唯一证据，不能丢');
      }
    });

    test('★★★ idle 与 broken 必须分别保存（不许压成 bool）', () {
      final src = {
        k('p','idle-chan'): e(LivePlaybackHealth.idle, t0),
        k('p','broken-chan'): e(LivePlaybackHealth.broken, t0),
      };
      final back = LiveHealthCache.decode(
        jsonDecode(jsonEncode(LiveHealthCache.encode(src))),
      );
      expect(back[k('p','idle-chan')]!.health, LivePlaybackHealth.idle);
      expect(back[k('p','broken-chan')]!.health, LivePlaybackHealth.broken,
          reason: '★ 压成 bool 会把"可能没开播"和"源坏了"混成一类 —— '
              '正是用户要求区分的东西');
    });

    test('★★ unknown 不落盘（"没观测过"不该变成记录）', () {
      final src = {
        k('p','a'): e(LivePlaybackHealth.unknown, t0),
        k('p','b'): e(LivePlaybackHealth.broken, t0),
      };
      final enc = LiveHealthCache.encode(src);
      final data = (enc['data'] as Map);
      expect(data.containsKey(k('p','a')), isFalse);
      expect(data.containsKey(k('p','b')), isTrue);
      expect(data.length, 1);
    });

    test('★ 版本号写进信封（将来格式变了能识别）', () {
      final enc = LiveHealthCache.encode({k('p','a'): e(LivePlaybackHealth.idle, t0)});
      expect(enc['v'], kLiveHealthCacheVersion);
    });
  });

  group('P0 持久化 ③：损坏数据必须降级，不能抛', () {
    test('★★★ 版本不符 ⇒ 空（不猜旧格式）', () {
      final bad = {'v': 999, 'data': {k('p','a'): {'h': 'idle', 't': 1}}};
      expect(LiveHealthCache.decode(bad), isEmpty);
    });

    test('★★★ 各种残缺/畸形输入 ⇒ 空，且不抛', () {
      final cases = <Object?>[
        null,
        'not a map',
        42,
        <String, dynamic>{},
        {'v': kLiveHealthCacheVersion},                    // 缺 data
        {'v': kLiveHealthCacheVersion, 'data': 'nope'},    // data 不是 Map
        {'v': kLiveHealthCacheVersion, 'data': null},
      ];
      for (final c in cases) {
        expect(() => LiveHealthCache.decode(c), returnsNormally,
            reason: '★ 直播页不能因为一份坏缓存就打不开');
        expect(LiveHealthCache.decode(c), isEmpty);
      }
    });

    test('★★★ 单条坏数据只跳过它自己，不连坐其余条目', () {
      final mixed = {
        'v': kLiveHealthCacheVersion,
        'data': {
          k('p','good'): {'h': 'broken', 't': t0.millisecondsSinceEpoch},
          k('p','bad-name'): {'h': 'NO_SUCH_STATE', 't': t0.millisecondsSinceEpoch},
          k('p','bad-type'): {'h': 'idle', 't': 'not-an-int'},
          k('p','no-time'): {'h': 'idle'},
        },
      };
      final out = LiveHealthCache.decode(mixed);
      expect(out.keys, [k('p','good')],
          reason: '★ 一条坏数据不该让整份缓存作废 —— 其余记录仍然有价值');
    });

    test('★ 缺 detail 也能解（detail 是可选的）', () {
      final m = {
        'v': kLiveHealthCacheVersion,
        'data': {
          k('p','a'): {'h': 'idle', 't': t0.millisecondsSinceEpoch},
        },
      };
      final out = LiveHealthCache.decode(m);
      expect(out[k('p','a')]!.health, LivePlaybackHealth.idle);
      expect(out[k('p','a')]!.detail, isNull);
    });
  });

  group('P0 持久化 ④：TTL / 过期语义', () {
    test('★★★ 超过 TTL 的不算 fresh（但 freshOnly 只分类、不删原表）', () {
      final old = t0.subtract(const Duration(minutes: 11));
      final src = {
        k('p','old'): e(LivePlaybackHealth.broken, old),
        k('p','new'): e(LivePlaybackHealth.broken, t0),
      };
      final fresh = LiveHealthCache.freshOnly(src, now: t0);
      expect(fresh.keys, [k('p','new')], reason: '★ 11 分钟前的不能当新鲜的');
      expect(src.length, 2,
          reason: '★ 过期的**必须留着**（用户要求"保留待刷新"）：'
              '直接清掉会让红点突然消失，用户以为状态丢了');
    });

    test('★★ 恰好等于 TTL 边界：< TTL 才算 fresh', () {
      final exactly = t0.subtract(kLiveHealthTtl);
      final justIn = t0.subtract(kLiveHealthTtl - const Duration(seconds: 1));
      final src = {
        k('p','exact'): e(LivePlaybackHealth.idle, exactly),
        k('p','in'): e(LivePlaybackHealth.idle, justIn),
      };
      final fresh = LiveHealthCache.freshOnly(src, now: t0);
      expect(fresh.containsKey(k('p','in')), isTrue);
      expect(fresh.containsKey(k('p','exact')), isFalse,
          reason: '边界取 <，恰好 10 分钟视为过期（保守：宁可多探一次）');
    });

    test('★ TTL 与探测 TTL 一致（10 分钟）', () {
      expect(kLiveHealthTtl, const Duration(minutes: 10));
      expect(LiveAvailabilityProbe().ttl, kLiveHealthTtl,
          reason: '★ 两套缓存用同一节律，否则"多久前检查的"语义会打架');
    });
  });

  group('P0 持久化 ⑤：store 的 snapshot / restore / seed', () {
    test('★★★ restore 用磁盘时间，**不**改写成 now', () {
      final store = LivePlaybackHealthStore(now: () => t0);
      final old = t0.subtract(const Duration(minutes: 30));
      store.restore({k('p','a'): e(LivePlaybackHealth.broken, old)});

      expect(store.entryOf('p', 'a')!.at, old,
          reason: '★ 若改写成 now，"已过期"的信息就丢了 —— '
              '等于把一小时前的坏状态洗成"刚刚才坏"');
    });

    test('★★★ snapshot 是副本（改它不影响 store）', () {
      final store = LivePlaybackHealthStore(now: () => t0);
      store.record(provider: 'p', channelId: 'a', health: LivePlaybackHealth.idle);
      final snap = store.snapshot();
      snap.clear();
      expect(store.length, 1, reason: '★ 否则落盘时的改动会反噬内存状态');
    });

    test('★★ snapshot 可直接被 encode（端到端串起来）', () {
      final store = LivePlaybackHealthStore(now: () => t0);
      store.record(
          provider: 'p', channelId: 'a', health: LivePlaybackHealth.broken,
          detail: 'boom');
      final enc = LiveHealthCache.encode(store.snapshot());
      final back = LiveHealthCache.decode(jsonDecode(jsonEncode(enc)));
      expect(back[k('p','a')]!.health, LivePlaybackHealth.broken);
      expect(back[k('p','a')]!.detail, 'boom');
    });

    test('★★★ seed 进探测层后，cached() 立刻命中 ⇒ probe 会跳过（P0 门禁⑥的一半）', () {
      final probe = LiveAvailabilityProbe();
      // 模拟"磁盘上有有效缓存"
      probe.seed('p', 'c1', LiveAvailability.playable, DateTime.now());
      expect(probe.cached('p', 'c1'), LiveAvailability.playable,
          reason: '★ 这是"跳过全量探测"能生效的关键：'
              'probe() 的跳过判据就是 cached() != null');
    });

    test('★★★ seed 用过期时间 ⇒ cached() 返回 null（不会阻止正确的重探）', () {
      final probe = LiveAvailabilityProbe(ttl: const Duration(minutes: 10));
      probe.seed('p', 'c1', LiveAvailability.playable,
          DateTime.now().subtract(const Duration(minutes: 11)));
      expect(probe.cached('p', 'c1'), isNull,
          reason: '★ 灌入过期数据不能让它看起来新鲜，否则该探的永远不探');
    });
  });

  group('P0 门禁⑥：有缓存时**零网络**（fake fetcher 计数）', () {
    test('★★★ 全部频道都有有效缓存 ⇒ fetcher 调用次数 == 0', () async {
      var calls = 0;
      final probe = LiveAvailabilityProbe(
        fetch: (provider, channelId) async {
          calls++;
          return const [];
        },
      );

      final now = DateTime.now();
      const groups = [
        LiveGroup(
          provider: 'p',
          providerName: 'P',
          channels: [
            LiveChannel(id: 'c1', name: '台1'),
            LiveChannel(id: 'c2', name: '台2'),
            LiveChannel(id: 'c3', name: '台3'),
          ],
        ),
      ];
      // 模拟三个频道都在磁盘上且新鲜
      for (final c in groups.first.channels) {
        probe.seed('p', c.id, LiveAvailability.playable, now);
      }

      final n = await probe.probe(groups);

      expect(n, 0, reason: '★ 一条都不该新探');
      expect(calls, 0,
          reason: '★★★ 这是 Owner「迟早要被拉黑」的直接防线：'
              '有缓存时**一个网络请求都不发**');
    });

    test('★★★ 一个频道有缓存、另一个没有 ⇒ 只探那一个（不许全量）', () async {
      var calls = 0;
      final probe = LiveAvailabilityProbe(
        fetch: (provider, channelId) async {
          calls++;
          return const [];
        },
      );
      final now = DateTime.now();
      const groups = [
        LiveGroup(
          provider: 'p',
          providerName: 'P',
          channels: [
            LiveChannel(id: 'cached', name: '有缓存'),
            LiveChannel(id: 'missing', name: '没缓存'),
          ],
        ),
      ];
      probe.seed('p', 'cached', LiveAvailability.playable, now);

      await probe.probe(groups);

      expect(calls, 1, reason: '★ 只探缺的那一个 —— 不是 2');
    });
  });

  group('P0 门禁④：真实 DiskCache 落盘往返（含损坏降级）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zz_t66_health_cache');
      DiskCache.init(dir.path);
    });

    tearDown(() {
      DiskCache.debugResetForTest();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('★★★ save → load 往返一致（真实文件）', () async {
      final src = {
        k('iptv','CCTV1'): e(LivePlaybackHealth.broken, t0, 'Failed to open'),
        k('iptv','CCTV5'): e(LivePlaybackHealth.idle, t0),
      };
      await LiveHealthCache.save(src);
      final back = await LiveHealthCache.load();

      expect(back.length, 2);
      expect(back[k('iptv','CCTV1')]!.health, LivePlaybackHealth.broken);
      expect(back[k('iptv','CCTV1')]!.detail, 'Failed to open');
      expect(back[k('iptv','CCTV5')]!.health, LivePlaybackHealth.idle);
    });

    test('★★★ 磁盘上是**半截/坏 JSON** ⇒ load 返回空，不抛', () async {
      // 直接往目标文件写垃圾（模拟写到一半断电）
      final f = File('${dir.path}${Platform.pathSeparator}$kLiveHealthCacheName');
      await f.writeAsString('{"v":1,"data":{"p|a":{"h":"idle"');

      final back = await LiveHealthCache.load();
      expect(back, isEmpty, reason: '★ 直播页必须还能打开');
    });

    test('★★ 文件不存在 ⇒ 空（第一次启动）', () async {
      final back = await LiveHealthCache.load();
      expect(back, isEmpty);
    });

    test('★ 数据目录未 init ⇒ 空，不抛', () async {
      DiskCache.debugResetForTest();
      final back = await LiveHealthCache.load();
      expect(back, isEmpty);
    });
  });
}
