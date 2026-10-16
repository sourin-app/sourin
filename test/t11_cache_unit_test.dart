// ═══════════════════════════════════════════════════════════════════════
//  task-11：首页列表缓存的上限 / 失效语义（纯单测，不碰 FFI / 不碰网络）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这条测试要单独存在（真机探针已经量了同一件事）
//
// ```text
// 真机探针（.probe/t11-cache.txt）量的是**端到端**：切源第一帧有没有卡片、
//   那一刻发了几次列表请求 —— 但它要 flutter build windows（全 app 编译），
//   会被**别人的中间态**卡住（本轮实测被 lib/ui/detail_page.dart 卡过两次）。
// 这条单测量的是**缓存类自己**：上限 / 淘汰顺序 / TTL / 指纹作废。
//   ⇒ 前者证明「用户看得见」，后者证明「内存不会涨」—— 两条互补，都要有。
// ```
//
// ⚠️ 判据用**返回值**（take() 给的快照是不是 null），不数内部字段 ——
//    内部字段可以「标记不命中却仍留着对象」，那样内存照样涨。
//    ★ 所以每条「不命中」都同时断言 length 变小（对象真的被丢掉了）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// ⚠️ home_page.dart **不导出** 领域模型（它只是 import 了），
//    所以要拿 MediaItem / ProviderGroup 必须自己再引一次 core/models.dart。
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/home_page.dart';

HomeSnapshot snap(String fp, DateTime at, {int cards = 0}) {
  final items = <String, List<MediaItem>>{};
  if (cards > 0) {
    items['p::s'] = List<MediaItem>.generate(
      cards,
      (i) => MediaItem(id: 'p:s$i', title: 't$i'),
    );
  }
  return HomeSnapshot(
    fingerprint: fp,
    groups: const <ProviderGroup>[],
    items: items,
    at: at,
  );
}

void main() {
  final now = DateTime(2026, 10, 9, 20, 0, 0);

  group('① 上限：LRU 真的丢对象（不只是「不命中」）', () {
    test('★★ 塞满 maxEntries+5 个键后，驻留数**恰好**等于上限', () {
      final c = HomeListCache();
      for (var i = 0; i < kHomeCacheMaxEntries + 5; i++) {
        c.put('p$i', snap('fp', now));
      }
      expect(c.length, kHomeCacheMaxEntries,
          reason: '★ 上限是**硬约束**（任务书第 4 条：不许让内存无限增长）');
    });

    test('★★ 被淘汰的是**最久未用**的那个（LRU 顺序）', () {
      final c = HomeListCache();
      for (var i = 0; i < kHomeCacheMaxEntries + 5; i++) {
        c.put('p$i', snap('fp', now));
      }
      for (var i = 0; i < 5; i++) {
        expect(c.take('p$i', fingerprint: 'fp', now: now), isNull,
            reason: '★ p$i 是第 ${i + 1} 个写入的 ⇒ 最早被淘汰');
      }
      expect(
        c.take('p${kHomeCacheMaxEntries + 4}', fingerprint: 'fp', now: now),
        isNotNull,
      );
    });

    test('★ 命中会把该键**提升**为最近使用（否则 LRU 退化成 FIFO）', () {
      final c = HomeListCache();
      for (var i = 0; i < kHomeCacheMaxEntries; i++) {
        c.put('p$i', snap('fp', now));
      }
      expect(c.take('p0', fingerprint: 'fp', now: now), isNotNull);
      c.put('px', snap('fp', now));
      expect(c.length, kHomeCacheMaxEntries);
      expect(c.take('p0', fingerprint: 'fp', now: now), isNotNull,
          reason: '★ 刚用过的不该被淘汰 —— 否则「命中提升」没生效');
      expect(c.take('p1', fingerprint: 'fp', now: now), isNull,
          reason: '★ 该被淘汰的应当是 p1');
    });
  });

  group('② 失效：TTL 与骨架指纹', () {
    /*
     * ★★★ 2026-10-15：生产默认 **不再有 TTL**（Owner：「不限制时间」）。
     *
     * ```text
     * 旧：kHomeCacheTtl = 10min，超过就不当可用缓存
     * 新：kHomeCacheTtl = null ⇒ 只比指纹，不因"存了多久"作废
     * ```
     * ⚠️ 但**机制本身**必须继续被测着 —— 所以这里显式注入一个 ttl。
     *    否则"过期会作废"这条语义就再没有任何用例盯着了（门禁退化）。
     */
    const ttl10 = Duration(minutes: 10);

    test('★★ 超过注入的 TTL 的快照不算命中，**且真的从表里删掉**', () {
      final c = HomeListCache(ttl: ttl10);
      c.put('a', snap('fp', now.subtract(ttl10 + const Duration(minutes: 1))));
      expect(c.take('a', fingerprint: 'fp', now: now), isNull,
          reason: '★ 显式设了 TTL 的调用方 ⇒ 过期就不该命中');
      expect(c.length, 0,
          reason: '★★ 不只是「不命中」：对象必须真的被丢掉，否则内存照涨');
    });

    test('★★★ 生产默认（ttl=null）⇒ **再老也照样命中**（Owner：不限制时间）', () {
      final c = HomeListCache();
      // 存了整整 30 天 —— 旧实现在这里必然判过期
      c.put('a', snap('fp', now.subtract(const Duration(days: 30))));
      expect(c.take('a', fingerprint: 'fp', now: now), isNotNull,
          reason: '★ Owner 原话「不限制时间」⇒ 旧数据也要先画出来，'
              '再由后台刷新替换（而不是冷加载转圈）');
    });

    test('★★ 指纹不符（用户刚启停过源）⇒ 不算命中，也真的删掉', () {
      final c = HomeListCache();
      c.put('a', snap('old-fingerprint', now));
      expect(c.take('a', fingerprint: 'new-fingerprint', now: now), isNull,
          reason: '★ 骨架变了 ⇒ 旧快照的分区列表与当前对不上，画出来是错的标题');
      expect(c.length, 0);
    });

    test('★ 边界：刚好等于 TTL 仍然算命中（判据是 > 不是 >=）', () {
      final c = HomeListCache(ttl: ttl10);
      c.put('a', snap('fp', now.subtract(ttl10)));
      expect(c.take('a', fingerprint: 'fp', now: now), isNotNull,
          reason: '边界写错会在「刚好 TTL」那一刻出现无谓的冷加载');
    });
  });

  group('③ 命中：拿到的是同一份数据 + 计数器真的在动', () {
    test('★★ 命中返回的快照内容与写入时一致（160 张那种规模）', () {
      final c = HomeListCache();
      c.put('a', snap('fp', now, cards: 160));
      final got = c.take('a', fingerprint: 'fp', now: now);
      expect(got, isNotNull);
      expect(got!.cardCount, 160);
      expect(c.hits, 1);
      expect(c.misses, 0);
    });

    test('★ items 是**只读视图**（防止别处顺手原地改坏缓存）', () {
      final c = HomeListCache();
      c.put('a', snap('fp', now, cards: 1));
      final got = c.take('a', fingerprint: 'fp', now: now)!;
      expect(() => got.items['x'] = const <MediaItem>[], throwsUnsupportedError,
          reason: '★ 缓存里的 Map 必须不可变 —— 否则「存引用省一次拷贝」'
              '就会变成「两处互相改」的隐蔽 bug');
    });

    test('★ clear() 之后一个都不留（测试/换源清单时要用）', () {
      final c = HomeListCache(maxEntries: 2);
      c.put('a', snap('fp', now));
      c.put('b', snap('fp', now));
      c.clear();
      expect(c.length, 0);
    });

    test('★ 空 provider 不许写入（否则会出现一个永远取不到的垃圾条目）', () {
      final c = HomeListCache();
      c.put('', snap('fp', now));
      expect(c.length, 0);
    });
  });

  group('⑤ 冷启动指纹未知（实机抓到的真缺陷）', () {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-15：磁盘缓存预热读回来的快照，**冷启动时永远命中不了**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 现象（.probe/ops/cachedemo 两次启动的实机读数）
     * ```text
     * RUN1（冷）: 写出 home-cache-cycani.json 20778 B ✓
     * RUN2（重启）: [SHELL] 首页磁盘缓存预热：2 个源   ← ★ 读盘成功了
     *               [HOME] 缓存命中 …                   ← ★ 一条都没有！
     *               [HOME] 渲染完成 … 卡片=693            ← 全是重新拉的
     * ```
     *
     * # 根因
     * ```text
     * 冷启动时 _fingerprint 还是初始值 **空串**（它要等 getHome() 返回才填），
     * 而 loadAll 立刻就拿这个空串去 take() ⇒ 与快照的真指纹不符 ⇒ 不命中。
     * ★ 更糟：take() 不命中时**顺手把那条删掉了**
     *   ⇒ 等真指纹到手，缓存已经没了 ⇒ 重启后照样冷加载。
     * ```
     *
     * # 修法
     * 空串 = 「调用方还不知道骨架」，不是「不符」⇒ 先信这份缓存。
     * ⚠️ 指纹**非空**时判据逐字不变（用户启停过源仍然作废）。
     */
    test('★★★ 指纹传空串 ⇒ 命中（冷启动预热必须能用）', () {
      final c = HomeListCache();
      c.put('a', snap('real-fingerprint', now, cards: 160));
      final got = c.take('a', fingerprint: '', now: now);
      expect(got, isNotNull,
          reason: '★★★ 冷启动时 _fingerprint 还是空串 ⇒ 不命中就等于'
              '整个磁盘缓存白做（实机就是这么失败的）');
      expect(got!.cardCount, 160, reason: '★ 拿到的是那份真数据');
      expect(c.length, 1,
          reason: '★★ 关键：不能顺手删掉 —— 删了以后真指纹到手也找不回来');
    });

    test('★★ 指纹传空串也要**过 TTL**（注入 ttl 时照样能作废）', () {
      const ttl10 = Duration(minutes: 10);
      final c = HomeListCache(ttl: ttl10);
      c.put('a', snap('fp', now.subtract(ttl10 + const Duration(minutes: 1))));
      expect(c.take('a', fingerprint: '', now: now), isNull,
          reason: '★ 空指纹只放宽**指纹**那一维，不放过期那一维');
    });

    test('★★ 指纹非空时判据不变（启停过源 ⇒ 旧快照仍作废）', () {
      final c = HomeListCache();
      c.put('a', snap('old', now));
      expect(c.take('a', fingerprint: 'new', now: now), isNull,
          reason: '★ 放宽空串**不许**顺带把"真不符"也放过');
      expect(c.length, 0);
    });
  });

  group('④ 常量契约（上限 / TTL 是公开可读的，改它必须是有意的）', () {
    test('★ 上限 = 12 / TTL = null（不限制时间）', () {
      expect(kHomeCacheMaxEntries, 12,
          reason: '★ 改这个数要同时说明内存代价（见 home_page.dart 的注释：'
              '一个条目 ≈ 一个源的卡片引用数，cctv 实测 160 张）');
      expect(kHomeCacheTtl, isNull,
          reason: '★★ Owner 2026-10-15：「不限制时间,可以启动后异步刷新替换」'
              '⇒ 生产默认**永不因时间作废**。改回具体时长前先问 Owner。');
    });
  });
}
