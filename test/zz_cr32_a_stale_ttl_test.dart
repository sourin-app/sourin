// ═══════════════════════════════════════════════════════════════════════
//  PR #32 ①：**过期条目的时间戳从不刷新** ⇒ 10 分钟后每次启动都全量重探
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷链路（CodeRabbit 给的，我逐步复核过每一步）
//
// ```text
// 1. 首次全量探测后 `mirrorAvailabilityIntoHealth` 写入所有频道，at = T0，落盘
// 2. 10 分钟后重启，`_loadHealthThenMaybeProbe` 走 `_health.restore(loaded)`，
//    条目 at 仍是 T0
// 3. `freshOnly(loaded)` 返回空 ⇒ 进延迟分支，30s 后 `_probeAll()` 全量重发
// 4. 探测完 `_mirrorProbeIntoHealth()` 里
//        if (store.healthOf(...) != unknown) continue;
//    ⇒ 对**所有**频道都成立（第 2 步刚 restore 回来）⇒ **一条都不写**
// 5. `_persistHealth()` 把仍是 T0 的旧快照写回磁盘
// 6. 下次启动重复第 3 步
// ⇒ 只有「首次探测后 10 分钟内重启」才命中缓存，此外每次启动都是全量探测
//   —— 本 PR 的 P0 目标（避免每次启动全量探测）被这条链路打穿了。
// ```
//
// # ★ 为什么这是"真缺陷"而不是"设计选择"
//
// ```text
// 原判据的**意图**写在注释里：
//     「已有真实播放证据（playable/broken/idle）⇒ 不覆盖」
//     「broken 来自真实播放失败，比'探测说没有可播地址'更硬」
// 这个意图是「**新鲜的真实证据**比推断硬」。
// 但代码写成了「**任何**已有条目都保护」—— 包括 11 分钟前的证据。
// ⇒ 实现比意图强了一档：过期的旧证据也获得了否决权。
//   而 `at` 这个字段的语义是「**最后一次观测到该状态的时刻**」
//   （两处消费方都要这个语义：`needsRetry` 判"多久没重试"、
//     `freshOnly` 判"多久没观测"）。重新观测到同一状态却不更新 `at`，
//   等于让 `at` 变成"第一次观测到的时刻" —— 语义被写坏了。
// ```
//
// # 修法（CR 给的，我采纳）
//
// ```text
// 只有已有条目**仍新鲜**时才保护它不被覆盖；
// 已过期的条目应当被新探测结论刷新。
// ⇒ 判据从「有没有条目」变成「条目新不新鲜」，与 `freshOnly` / `needsRetry`
//   用同一个 [kLiveHealthTtl]，不再自造第二套时间语义。
// ```
//
// ⚠️ 本文件是**判据门禁**，不含任何 I/O（除最后一组落盘闭环）。
//    不挂 native-media：纯逻辑。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/live_availability.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  String k(String p, String c) => liveHealthCacheKey(p, c);

  /// 固定时间原点（不依赖真实时钟，读数可复现）
  final t0 = DateTime(2026, 10, 21, 12, 0, 0);

  group('① 过期条目的 at 必须被新探测结论刷新', () {
    test('★★★ CR 的判据（固定时钟）：restore 11 分钟前的 playable ⇒ '
        'mirror 同结论 ⇒ at 必须更新且 freshOnly 非空', () {
      final at11 = t0.add(const Duration(minutes: 11));
      final store = LivePlaybackHealthStore(now: () => at11);

      // 前置：磁盘上是 11 分钟前的观测（已超过 kLiveHealthTtl = 10min）
      store.restore({
        k('p', 'c'): LivePlaybackHealthEntry(
          health: LivePlaybackHealth.playable,
          at: t0,
        ),
      });

      // 前置自检：这条确实"不新鲜" —— 否则下面的断言是恒真的
      expect(
        LiveHealthCache.freshOnly(store.snapshot(), now: at11),
        isEmpty,
        reason: '前置：11 分钟前的条目必须被判为过期（否则本测试没有分辨力）',
      );

      // 重新探测，结论相同
      final n = mirrorAvailabilityIntoHealth(
        store: store,
        items: const [('p', 'c', LiveAvailability.playable)],
      );

      expect(
        store.entryOf('p', 'c')!.at,
        at11,
        reason: '★★★ 缺陷所在：修复前这里仍是 t0（11 分钟前）—— '
            '`if (healthOf != unknown) continue` 把过期条目也保护了',
      );
      expect(n, 1, reason: '写入条数：修复前是 0');
      expect(
        LiveHealthCache.freshOnly(store.snapshot(), now: at11),
        isNotEmpty,
        reason: '★★★ 这一步是 P0 的直接判据：刷新后必须重新算"新鲜"，'
            '否则下次启动 freshOnly 仍为空 ⇒ 又全量重探',
      );
    });

    test('★★★ CR 的判据（真实时钟，逐字照它的复现步骤）', () {
      final store = LivePlaybackHealthStore(); // 默认 DateTime.now
      final old = DateTime.now().subtract(const Duration(minutes: 11));
      store.restore({
        k('iptv', 'c1'): LivePlaybackHealthEntry(
          health: LivePlaybackHealth.playable,
          at: old,
        ),
      });

      expect(LiveHealthCache.freshOnly(store.snapshot()), isEmpty,
          reason: '前置：真实时钟下 11 分钟前也必须过期');

      mirrorAvailabilityIntoHealth(
        store: store,
        items: const [('iptv', 'c1', LiveAvailability.playable)],
      );

      final now = DateTime.now();
      expect(
        now.difference(store.entryOf('iptv', 'c1')!.at).inSeconds,
        lessThan(5),
        reason: '★★★ at 必须是"刚才"，不是 11 分钟前',
      );
      expect(LiveHealthCache.freshOnly(store.snapshot()), isNotEmpty,
          reason: '★★★ freshOnly(snapshot()) 必须非空（CR 原话）');
    });

    test('★★★ 仍新鲜的条目**必须继续受保护**（不能把优先级保护一起改没）', () {
      final at1 = t0.add(const Duration(minutes: 1));
      final store = LivePlaybackHealthStore(now: () => at1);
      store.restore({
        k('p', 'c'): LivePlaybackHealthEntry(
          health: LivePlaybackHealth.broken,
          at: t0,
          detail: '[stream] Failed to open',
        ),
      });

      final n = mirrorAvailabilityIntoHealth(
        store: store,
        items: const [('p', 'c', LiveAvailability.unavailable)],
      );

      expect(n, 0, reason: '★ 1 分钟前的真实播放证据仍然新鲜 ⇒ 不许被推断覆盖');
      expect(store.entryOf('p', 'c')!.detail, '[stream] Failed to open',
          reason: '★ 真实错误原文必须留住（这是优先级保护的原始意图）');
      expect(store.entryOf('p', 'c')!.at, t0, reason: '★ at 也不该被推后');
    });

    test('★★ 过期的 broken 可以被新的 playable 覆盖（方向也要对）', () {
      final at11 = t0.add(const Duration(minutes: 11));
      final store = LivePlaybackHealthStore(now: () => at11);
      store.restore({
        k('p', 'c'): LivePlaybackHealthEntry(
          health: LivePlaybackHealth.broken,
          at: t0,
          detail: '[stream] Failed to open',
        ),
      });

      mirrorAvailabilityIntoHealth(
        store: store,
        items: const [('p', 'c', LiveAvailability.playable)],
      );

      expect(store.healthOf('p', 'c'), LivePlaybackHealth.playable,
          reason: '★ 11 分钟前打不开、现在探到可播 ⇒ 新的观测更相关');
      expect(store.entryOf('p', 'c')!.at, at11);
    });

    test('★★ 新条目（store 里没有）不受新鲜度判据影响，照写', () {
      final at11 = t0.add(const Duration(minutes: 11));
      final store = LivePlaybackHealthStore(now: () => at11);
      final n = mirrorAvailabilityIntoHealth(
        store: store,
        items: const [
          ('p', 'new1', LiveAvailability.playable),
          ('p', 'new2', LiveAvailability.unavailable),
        ],
      );
      expect(n, 2);
      expect(store.length, 2);
      expect(store.entryOf('p', 'new1')!.at, at11);
    });
  });

  group('① 三会话闭环：这才是 P0 真正要的那件事', () {
    late Directory dir;

    setUp(() async {
      dir = await Directory.systemTemp.createTemp('zz_cr32_a');
      DiskCache.init(dir.path);
    });

    tearDown(() {
      DiskCache.debugResetForTest();
      try {
        dir.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('★★★ 会话1 探完落盘 → 会话2（+11min）读盘再探再落盘 → '
        '会话3（+15min）必须命中缓存且**零请求**', () async {
      // ── 会话 1：首次探测，at = t0 ────────────────────────────────
      final s1 = LivePlaybackHealthStore(now: () => t0);
      mirrorAvailabilityIntoHealth(
        store: s1,
        items: const [
          ('iptv', 'c1', LiveAvailability.playable),
          ('iptv', 'c2', LiveAvailability.playable),
        ],
      );
      await LiveHealthCache.save(s1.snapshot());

      // ── 会话 2：11 分钟后重启 ───────────────────────────────────
      final at11 = t0.add(const Duration(minutes: 11));
      final loaded = await LiveHealthCache.load();
      expect(loaded.length, 2, reason: '前置：磁盘上确实有 2 条');

      final s2 = LivePlaybackHealthStore(now: () => at11);
      s2.restore(loaded);
      expect(
        LiveHealthCache.freshOnly(loaded, now: at11),
        isEmpty,
        reason: '前置：会话 2 读到的全部过期 ⇒ 会触发全量重探（这是正常行为）',
      );

      // 会话 2 探完 ⇒ 必须把 at 刷新到 at11
      mirrorAvailabilityIntoHealth(
        store: s2,
        items: const [
          ('iptv', 'c1', LiveAvailability.playable),
          ('iptv', 'c2', LiveAvailability.playable),
        ],
      );
      await LiveHealthCache.save(s2.snapshot());

      // ── 会话 3：再 4 分钟后重启（仍在 10 分钟 TTL 内）───────────
      final at15 = t0.add(const Duration(minutes: 15));
      final loaded3 = await LiveHealthCache.load();
      final fresh3 = LiveHealthCache.freshOnly(loaded3, now: at15);

      expect(
        fresh3.length,
        2,
        reason: '★★★ 缺陷所在：修复前这里是 **0 条**（磁盘上的 at 还停在 t0，'
            '已 15 分钟）⇒ 会话 3 又全量重探。'
            '这一条就是「10 分钟后每次启动都全量重探」的直接读数',
      );

      // 零请求：seed 之后 probe 一条都不发
      var calls = 0;
      // ★★★ 必须注入时钟：`seed()` 灌的是 at11（固定时刻），
      //   `cached()` 却拿"现在"去比。若这里留默认 `DateTime.now`，
      //   两者差的是**真实墙钟**与固定 t0 的距离（写好时差 0 分钟、
      //   第二天跑就差一整天）⇒ seed 全部被判过期 ⇒ calls = 2，
      //   读数与"修法对不对"无关，纯粹是两个世界对不上。
      //   （2026-10-22 实测复现：未注入时 calls = 2，本用例红。）
      final probe = LiveAvailabilityProbe(
        now: () => at15,
        fetch: (p, c) async {
          calls++;
          return const [];
        },
      );
      for (final e in fresh3.entries) {
        final parts = liveHealthCacheKeyParts(e.key)!;
        final a = switch (e.value.health) {
          LivePlaybackHealth.playable => LiveAvailability.playable,
          LivePlaybackHealth.broken => LiveAvailability.unavailable,
          _ => LiveAvailability.unknown,
        };
        probe.seed(parts.$1, parts.$2, a, e.value.at);
      }
      await probe.probe(const [
        LiveGroup(provider: 'iptv', providerName: 'IPTV', channels: [
          LiveChannel(id: 'c1', name: '台1'),
          LiveChannel(id: 'c2', name: '台2'),
        ]),
      ]);
      expect(calls, 0, reason: '★★★ P0 目标：会话 3 必须 0 次网络请求');
    });

    test('★★ 落盘内容里 t 字段确实变成了新时刻（不是只在内存里新）', () async {
      final at11 = t0.add(const Duration(minutes: 11));
      final store = LivePlaybackHealthStore(now: () => at11);
      store.restore({
        k('iptv', 'c1'): LivePlaybackHealthEntry(
          health: LivePlaybackHealth.playable,
          at: t0,
        ),
      });
      mirrorAvailabilityIntoHealth(
        store: store,
        items: const [('iptv', 'c1', LiveAvailability.playable)],
      );
      await LiveHealthCache.save(store.snapshot());

      final f = File('${dir.path}${Platform.pathSeparator}$kLiveHealthCacheName');
      final raw = jsonDecode(await f.readAsString()) as Map;
      final t = ((raw['data'] as Map)[k('iptv', 'c1')] as Map)['t'] as int;
      expect(
        t,
        at11.millisecondsSinceEpoch,
        reason: '★★ 磁盘上的 t 必须是刷新后的时刻 —— '
            '否则"重启后命中缓存"只在这一进程内成立',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  仪器活性对照（读数的分辨力自检）
  // ═══════════════════════════════════════════════════════════════════
  //
  // ★ 本组证明「freshOnly 这个读数不是恒真的」：
  //   同一个 store，只换 `now` 一维 ⇒ 读数必须不同。
  //   如果它恒为空或恒非空，上面所有断言都会失去意义。
  group('仪器活性对照', () {
    test('★ 只换 now 一维 ⇒ freshOnly 读数必须不同', () {
      final store = LivePlaybackHealthStore();
      store.restore({
        k('p', 'c'): LivePlaybackHealthEntry(
          health: LivePlaybackHealth.playable,
          at: t0,
        ),
      });
      final snap = store.snapshot();

      final freshAt1 = LiveHealthCache.freshOnly(
        snap,
        now: t0.add(const Duration(minutes: 1)),
      ).length;
      final freshAt11 = LiveHealthCache.freshOnly(
        snap,
        now: t0.add(const Duration(minutes: 11)),
      ).length;

      expect(freshAt1, 1, reason: '1 分钟后：新鲜');
      expect(freshAt11, 0, reason: '11 分钟后：过期');
      expect(
        freshAt1,
        isNot(equals(freshAt11)),
        reason: '★ 仪器活性对照失败：换输入后读数相同 ⇒ 这个读数可能是写死的',
      );
    });
  });
}
