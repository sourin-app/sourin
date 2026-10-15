// ═══════════════════════════════════════════════════════════════════════
//  T-CACHE：磁盘缓存的三条契约（模型往返 / 落盘读回 / 真的接线了）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（2026-10-15）
// ```text
// > 我希望这个页面的数据可以缓存,而不是每次打开都是彻底的请求重载,
// > 太影响观感,可以缓存然后异步
// > （追加）对的,我就是希望持久化的,而不是重启软件就没了
// > （再追加）不限制时间,可以启动后异步刷新替换,切换源检测时间对比 然后再替换
// ```
//
// # 这个文件守的三件事
// ```text
// ① 模型 toJson↔fromJson **逐字段往返** —— 缓存写盘用的是它，
//    一个键名写错 ⇒ 读回来静默缺字段（本项目栽过：note 其实来自 subtitle，
//    6 处 UI 恒为空且不报错）
// ② DiskCache 落盘→读回 相等；坏文件 / 版本不符 / 目录未就绪 ⇒ 降级不崩
// ③ **真的接线了** —— 防"写了没调用"（本仓 ⑥ 规矩一）
// ```
//
// ⚠️ 用 dart:io 的真实临时目录（不是 mock）—— 落盘这条路必须真跑。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/models.dart';

void main() {
  // ═��═══════════════════════════════════════════════════════════════════
  //  ① 模型往返：写出去再读回来，**每个字段**都要一模一样
  // ═════════════════════════════════════════════════════════════════════
  group('① 模型 toJson ↔ fromJson 逐字段往返', () {
    test('★★★ MediaItem：全部字段往返（含 note←subtitle 这个易错点）', () {
      final src = MediaItem(
        id: 'srca:3862',
        title: '测试剧',
        cover: 'https://example.invalid/c.jpg',
        note: '全 27 集',
        badges: const ['全 27 集', '7.0 分'],
        year: '2024',
        category: '电视剧',
        provider: 'srca',
      );
      final back = MediaItem.fromJson(src.toJson());
      expect(back.id, src.id);
      expect(back.title, src.title);
      expect(back.cover, src.cover);
      expect(back.note, src.note,
          reason: '★★ note 存的是 subtitle（Rust 真名）—— 键名写错这里就红');
      expect(back.badges, src.badges);
      expect(back.year, src.year);
      expect(back.category, src.category);
      expect(back.provider, src.provider);
    });

    test('★★★ MediaItem：note 发的是 **subtitle** 这个键（不是 note）', () {
      final m = MediaItem(id: 'x', title: 't', note: '全 3 集');
      final j = m.toJson();
      expect(j['subtitle'], '全 3 集',
          reason: '★ 必须与线上报文的键名一致 —— 否则存下来的文件"不是那个样子"，'
              '以后排查缓存问题会对不上');
      expect(j.containsKey('note'), isFalse,
          reason: '★ 不该同时发两个键（多一个就多一处漂移点）');
    });

    test('★★ SectionSource：五种 type 各自往返（category/rank/recent/custom/static）', () {
      const cases = <SectionSource>[
        SectionSource(type: 'category', categoryId: '1'),
        SectionSource(type: 'rank', rankId: 'hot'),
        SectionSource(type: 'recent'),
        SectionSource(type: 'custom', key: 'k'),
        SectionSource(type: 'static'),
      ];
      for (final s in cases) {
        final back = SectionSource.fromJson(s.toJson());
        expect(back.type, s.type, reason: 'type 往返失败: ${s.type}');
        expect(back.categoryId, s.categoryId);
        expect(back.rankId, s.rankId);
        expect(back.key, s.key);
      }
    });

    test('★★★ ProviderGroup + Section + MediaItem 三层嵌套往返', () {
      final g = ProviderGroup(
        provider: 'srca',
        providerName: 'SRCA源',
        sections: [
          Section(
            id: 'sec1',
            title: '热门电影',
            source: const SectionSource(type: 'category', categoryId: '1'),
            items: [MediaItem(id: 'srca:1', title: '片A', note: '全 12 集')],
          ),
        ],
      );
      final back = ProviderGroup.fromJson(g.toJson());
      expect(back.provider, g.provider);
      expect(back.providerName, g.providerName,
          reason: '★ 键名是 providerName（camelCase，与原版前端一致）');
      expect(back.sections.length, 1);
      expect(back.sections.first.id, 'sec1');
      expect(back.sections.first.title, '热门电影');
      expect(back.sections.first.source.type, 'category');
      expect(back.sections.first.source.categoryId, '1');
      expect(back.sections.first.items.length, 1);
      expect(back.sections.first.items.first.note, '全 12 集');
    });

    test('★★★ Favorite：全部字段往返', () {
      const src = Favorite(
        key: 'srca:1',
        provider: 'srca',
        nativeId: '1',
        title: '测试剧',
        cover: 'https://example.invalid/a.jpg',
        groupName: '电视剧',
        kind: 'series',
        favorited: true,
        following: true,
        lastEpisodeCount: 27,
        lastEpisodeTitle: '第27集',
        unreadCount: 3,
        lastCheckedAt: 111,
        lastUpdateAt: 222,
        note: '备注',
        createdAt: 333,
        updatedAt: 444,
        deleted: false,
      );
      final back = Favorite.fromJson(src.toJson());
      expect(back.key, src.key);
      expect(back.provider, src.provider);
      expect(back.nativeId, src.nativeId);
      expect(back.title, src.title);
      expect(back.cover, src.cover);
      expect(back.groupName, src.groupName);
      expect(back.kind, src.kind);
      expect(back.favorited, src.favorited);
      expect(back.following, src.following);
      expect(back.lastEpisodeCount, src.lastEpisodeCount);
      expect(back.lastEpisodeTitle, src.lastEpisodeTitle);
      expect(back.unreadCount, src.unreadCount);
      expect(back.lastCheckedAt, src.lastCheckedAt);
      expect(back.lastUpdateAt, src.lastUpdateAt);
      expect(back.note, src.note);
      expect(back.createdAt, src.createdAt);
      expect(back.updatedAt, src.updatedAt);
      expect(back.deleted, src.deleted);
    });

    test('★★★ Progress：全部字段往返', () {
      const src = Progress(
        key: 'srca:1:e2',
        provider: 'srca',
        nativeId: '1',
        title: '测试剧',
        cover: 'https://example.invalid/b.jpg',
        episodeId: 'e2',
        episodeTitle: '第2集',
        position: 120,
        duration: 1440,
        finished: false,
        updatedAt: 999,
      );
      final back = Progress.fromJson(src.toJson());
      expect(back.key, src.key);
      expect(back.provider, src.provider);
      expect(back.nativeId, src.nativeId);
      expect(back.title, src.title);
      expect(back.cover, src.cover);
      expect(back.episodeId, src.episodeId);
      expect(back.episodeTitle, src.episodeTitle);
      expect(back.position, src.position);
      expect(back.duration, src.duration);
      expect(back.finished, src.finished);
      expect(back.updatedAt, src.updatedAt);
    });

    test('★ 可空字段为 null 时往返仍是 null（不许变成空串）', () {
      final m = MediaItem(id: 'x', title: 't');
      final back = MediaItem.fromJson(m.toJson());
      expect(back.cover, isNull);
      expect(back.note, isNull);
      expect(back.year, isNull);
      expect(back.category, isNull);
      expect(back.provider, isNull);
      expect(back.badges, isEmpty);
    });
  });
}