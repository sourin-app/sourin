import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/live_availability.dart';

/// P0 门禁：**探测结论必须真的被镜像进健康状态并落盘**
///
/// # 为什么必须补这一组（一条真实的失败）
///
/// ```text
/// 我第一版 `_mirrorProbeIntoHealth()` 只写了：
///     if (a == LiveAvailability.unavailable && healthOf == unknown) record(broken)
///
/// ⇒ 探测 1136 个频道，绝大多数是 **playable**
/// ⇒ 只把 unavailable 的写进 _health，playable / audioOnly **一条都不写**
/// ⇒ _health.snapshot() 空 ⇒ 落盘 {"data":{}}
/// ⇒ 下次启动读到 0 条 ⇒ 不 seed ⇒ **全量重探 706 次**
/// ```
///
/// ## ★ 为什么我原有的 26 条门禁全绿却漏了它
///
/// ```text
/// 那些门禁直接调 `probe.seed(...)` 然后断言 `calls == 0` ——
/// **从不经过 `_mirrorProbeIntoHealth`**。
/// ⇒ 它们证明的是"有缓存时不会探测"，
///   而缺陷在于"**根本产生不了缓存**"。
/// ⇒ 测了前提，没测前提是怎么来的。
/// ```
///
/// ## 这一组的判据
/// ```text
/// 喂进 playable / audioOnly / unavailable 三种探测结论
/// ⇒ _health 必须有 **3 条**（不是 1 条）
/// ⇒ 落盘文件里的 data 必须有 **3 条**（不是 0 条）
/// ★ 走的是产品代码同一个函数 `mirrorAvailabilityIntoHealth`
/// ```
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String k(String p, String c) => liveHealthCacheKey(p, c);

  group('P0 镜像：三种可用性都必须写进健康状态', () {
    test('★★★ playable + audioOnly + unavailable ⇒ 恰好 3 条（不是 1 条）', () {
      final store = LivePlaybackHealthStore();

      final n = mirrorAvailabilityIntoHealth(
        store: store,
        items: const [
          ('iptv', 'c-playable', LiveAvailability.playable),
          ('iptv', 'c-audio', LiveAvailability.audioOnly),
          ('iptv', 'c-dead', LiveAvailability.unavailable),
        ],
      );

      expect(n, 3,
          reason: '★★★ 这正是缺陷所在：第一版只会写 1 条（只处理 unavailable）');
      expect(store.length, 3,
          reason: '★ 3 条都要进 store，否则落盘就是空的');
    });

    test('★★★ 映射正确：playable→playable / audioOnly→playable / unavailable→broken', () {
      final store = LivePlaybackHealthStore();
      mirrorAvailabilityIntoHealth(
        store: store,
        items: const [
          ('p', 'a', LiveAvailability.playable),
          ('p', 'b', LiveAvailability.audioOnly),
          ('p', 'c', LiveAvailability.unavailable),
        ],
      );

      expect(store.healthOf('p', 'a'), LivePlaybackHealth.playable);
      expect(store.healthOf('p', 'b'), LivePlaybackHealth.playable,
          reason: '★ 仅音频也是"这个源可用"，不能标成不可用'
              '（否则广播台会被隐藏）');
      expect(store.healthOf('p', 'c'), LivePlaybackHealth.broken);
    });

    test('★★ unknown 不写（"还没探到"不该变成记录）', () {
      final store = LivePlaybackHealthStore();
      final n = mirrorAvailabilityIntoHealth(
        store: store,
        items: const [
          ('p', 'a', LiveAvailability.unknown),
          ('p', 'b', LiveAvailability.playable),
        ],
      );
      expect(n, 1);
      expect(store.length, 1, reason: '★ unknown 不制造记录');
      expect(store.healthOf('p', 'a'), LivePlaybackHealth.unknown);
    });

    test('★★★ 已有真实播放证据时**不覆盖**（优先级保护）', () {
      final store = LivePlaybackHealthStore();
      // 真实播放失败（更硬的证据）
      store.record(
          provider: 'p', channelId: 'c', health: LivePlaybackHealth.broken,
          detail: '[stream] Failed to open');
      // 探测说"没线路" —— 不该覆盖掉真实错误原文
      mirrorAvailabilityIntoHealth(
        store: store,
        items: const [('p', 'c', LiveAvailability.unavailable)],
      );

      expect(store.entryOf('p', 'c')!.detail, '[stream] Failed to open',
          reason: '★ 真实播放的 broken 比探测推断更硬，不该覆盖');
    });
  });

  group('P0 镜像：落盘的非空闭环（缺陷的直接防线）', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zz_t66_mirror');
      DiskCache.init(dir.path);
    });

    tearDown(() {
      DiskCache.debugResetForTest();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('★★★ 镜像 → save → 磁盘 data 必须有 3 条（不是 0 条）', () async {
      final store = LivePlaybackHealthStore();
      mirrorAvailabilityIntoHealth(
        store: store,
        items: const [
          ('iptv', 'c1', LiveAvailability.playable),
          ('iptv', 'c2', LiveAvailability.audioOnly),
          ('iptv', 'c3', LiveAvailability.unavailable),
        ],
      );
      await LiveHealthCache.save(store.snapshot());

      final f = File('${dir.path}${Platform.pathSeparator}$kLiveHealthCacheName');
      expect(await f.exists(), isTrue, reason: '前置：文件必须生成');

      final raw = jsonDecode(await f.readAsString()) as Map;
      final data = raw['data'] as Map;

      expect(data.length, 3,
          reason: '★★★ 这是缺陷的直接读数：第一版这里是 **0 条**（{"data":{}}）。'
              '★ 文件存在、大小正常、路径正确，但内容是空的 —— '
              '这正是它比"没接线"更隐蔽的地方');

      // 内容也要对
      expect((data[k('iptv', 'c1')] as Map)['h'], 'playable');
      expect((data[k('iptv', 'c2')] as Map)['h'], 'playable');
      expect((data[k('iptv', 'c3')] as Map)['h'], 'broken');
    });

    test('★★★ 端到端：镜像 → 落盘 → 读回 → seed ⇒ 探测 0 次', () async {
      // ① 上次会话：探测完 → 镜像 → 落盘
      final prev = LivePlaybackHealthStore();
      mirrorAvailabilityIntoHealth(
        store: prev,
        items: const [
          ('iptv', 'c1', LiveAvailability.playable),
          ('iptv', 'c2', LiveAvailability.playable),
          ('iptv', 'c3', LiveAvailability.unavailable),
        ],
      );
      await LiveHealthCache.save(prev.snapshot());

      // ② 本次会话：读盘
      final loaded = await LiveHealthCache.load();
      expect(loaded.length, 3, reason: '前置：真的读回 3 条');

      // ③ seed 进 probe
      var calls = 0;
      final probe = LiveAvailabilityProbe(
        fetch: (p, c) async {
          calls++;
          return const [];
        },
      );
      for (final e in LiveHealthCache.freshOnly(loaded).entries) {
        final parts = liveHealthCacheKeyParts(e.key)!;
        final a = switch (e.value.health) {
          LivePlaybackHealth.playable => LiveAvailability.playable,
          LivePlaybackHealth.broken => LiveAvailability.unavailable,
          _ => LiveAvailability.unknown,
        };
        probe.seed(parts.$1, parts.$2, a, e.value.at);
      }

      // ④ 探测
      await probe.probe(const [
        LiveGroup(provider: 'iptv', providerName: 'IPTV', channels: [
          LiveChannel(id: 'c1', name: '台1'),
          LiveChannel(id: 'c2', name: '台2'),
          LiveChannel(id: 'c3', name: '台3'),
        ]),
      ]);

      expect(calls, 0,
          reason: '★★★ 完整闭环：探测 → 镜像 → 落盘 → 读回 → seed ⇒ '
              '**0 次网络请求**。这是"不被拉黑"的完整证据链');
    });
  });
}
