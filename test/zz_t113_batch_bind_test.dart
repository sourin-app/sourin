// T113: batch danmaku binding + cross-source interconnection
//
// Owner: "fan ju de pi liang bang ding dan mu, ke yi hu lian guan xi"
//
// THE core invariant this file guards:
//   NEVER copy episode 1's episodeId onto all 12 episodes.
// Each episode has its own id in the danmaku library; duplicating one id
// means all 12 episodes replay episode 1's comments -- wrong timeline, wrong
// dialogue -- while the UI looks like it bound successfully.

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/batch_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';

DanmakuMatch _m(int id, String ep) =>
    DanmakuMatch(episodeId: id, animeTitle: 'X', episodeTitle: ep);

void main() {
  group('T113-1 episode number extraction', () {
    test('chinese di-N-hua/ji/hui/mu', () {
      expect(episodeNumberFrom('第1话 我是路飞'), 1);
      expect(episodeNumberFrom('第01集 xxx'), 1);
      expect(episodeNumberFrom('第 3 话 yyy'), 3);
      expect(episodeNumberFrom('第12回'), 12);
      expect(episodeNumberFrom('第7幕'), 7);
    });
    test('EP/SP prefix, case insensitive', () {
      expect(episodeNumberFrom('EP05 aaa'), 5);
      expect(episodeNumberFrom('ep5'), 5);
      expect(episodeNumberFrom('SP03 x'), 3);
    });
    test('bare number', () {
      expect(episodeNumberFrom('12'), 12);
    });
    test('** unparseable returns null (never guess 1)', () {
      expect(episodeNumberFrom('燃烧吧，狂犬'), isNull);
      expect(episodeNumberFrom(''), isNull);
      expect(episodeNumberFrom('剧场版'), isNull);
    });
    test('*** a year embedded in a title is not an episode number', () {
      expect(episodeNumberFrom('2024'), 2024);
      expect(episodeNumberFrom('无职转生 2024'), isNull,
          reason: '** a year inside a title must not be read as an episode number');
    });
  });

  group('T113-2 alignment (the core of the feature)', () {
    test('*** 12 to 12: every episode gets its OWN distinct id', () {
      final plan = buildBatchBindPlan(
        localTitles: [for (var i = 1; i <= 12; i++) '第$i集'],
        matches: [for (var i = 1; i <= 12; i++) _m(1000 + i, '第$i话')],
      );
      expect(plan.count, 12);
      final ids = plan.items.map((e) => e.episodeId).toSet();
      expect(ids.length, 12,
          reason: '*** 12 episodes must get 12 DIFFERENT ids; one id for all means ep1 everywhere');
      for (final it in plan.items) {
        expect(it.episodeId, 1000 + it.episodeIndex + 1);
      }
    });

    test('** out-of-order episode numbers still align (not by raw index)', () {
      final plan = buildBatchBindPlan(
        localTitles: ['第1集', '第2集', '第3集'],
        matches: [_m(33, '第3话'), _m(11, '第1话'), _m(22, '第2话')],
      );
      expect(plan.count, 3);
      expect(plan.items[0].episodeId, 11);
      expect(plan.items[1].episodeId, 22);
      expect(plan.items[2].episodeId, 33);
    });

    test('*** 24 local vs 12 in library: extras are NOT bound, and are reported', () {
      final plan = buildBatchBindPlan(
        localTitles: [for (var i = 1; i <= 24; i++) '第$i集'],
        matches: [for (var i = 1; i <= 12; i++) _m(1000 + i, '第$i话')],
      );
      expect(plan.count, lessThanOrEqualTo(12),
          reason: '*** rather unbound than wrong: never pad the tail to look complete');
      expect(plan.unmatchedLocal, isNotEmpty,
          reason: '** unbound episodes must be reported, or the user assumes all 24 are done');
      expect(plan.totalLocal, 24);
    });

    test('* unnumbered library entries fall back to positional pairing', () {
      final plan = buildBatchBindPlan(
        localTitles: ['第1集', '第2集'],
        matches: [_m(77, '上'), _m(88, '下')],
      );
      expect(plan.count, 2);
      expect(plan.items[0].episodeId, 77);
      expect(plan.items[1].episodeId, 88);
    });

    test('★★ 库这侧带集号却没配上时，退路不许拿别人的 id（会两集撞同一集）', () {
      /*
       * 本地集号已知、但库里没有对应集 ⇒ 必须记进 unmatchedLocal，
       * **不能**退到下标去拿一条已经有主的记录。
       *
       * 改前：第 2 集退路拿到 matches[1] = #33，第 3 集按集号也配 #33 ⇒
       *       两集共享 episodeId，第 2 集放的是第 3 集的弹幕，
       *       而且 unmatchedLocal 是空的（用户以为全绑好了）。
       */
      final plan = buildBatchBindPlan(
        localTitles: ['第1集', '第2集', '第3集'],
        matches: [_m(11, '第1话'), _m(33, '第3话')],
      );

      final ids = plan.items.map((e) => e.episodeId).toList();
      expect(ids.length, ids.toSet().length,
          reason: '★★ 两集撞同一个 episodeId = 有一集在放别人的弹幕');
      expect(plan.unmatchedLocal, contains(1),
          reason: '★ 第 2 集在库里没对应集 ⇒ 必须如实报告没配上，而不是随便配一个');
      expect(plan.items.firstWhere((e) => e.episodeIndex == 0).episodeId, 11);
      expect(plan.items.firstWhere((e) => e.episodeIndex == 2).episodeId, 33);
    });

    test('* empty input does not crash and reports zero bound', () {
      final a = buildBatchBindPlan(localTitles: [], matches: [_m(1, '第1话')]);
      expect(a.isEmpty, isTrue);
      final b = buildBatchBindPlan(localTitles: ['第1集'], matches: []);
      expect(b.isEmpty, isTrue);
      expect(b.unmatchedLocal, [0]);
    });
  });

  group('T113-3 cross-source interconnection', () {
    test('same work, same name', () {
      expect(looksLikeSameWork('无职转生', '无职转生'), isTrue);
    });
    test('** different works are not the same', () {
      expect(looksLikeSameWork('无职转生', '葬送的芙莉莲'), isFalse);
      expect(looksLikeSameWork('孤独摇滚', '赛马娘'), isFalse);
    });
    test('*** empty titles never interconnect', () {
      expect(looksLikeSameWork('', ''), isFalse,
          reason: '*** two empty titles must never be judged the same work');
      expect(looksLikeSameWork('无职转生', ''), isFalse);
      expect(looksLikeSameWork('', '无职转生'), isFalse);
    });
    test('* finds sibling sources sorted by similarity', () {
      final got = findInterconnectedSources(
        title: '无职转生',
        candidates: [
          (provider: 'a', id: '1', title: '无职转生'),
          (provider: 'b', id: '2', title: '葬送的芙莉莲'),
        ],
      );
      expect(got, isNotEmpty);
      expect(got.first.provider, 'a');
      expect(got.any((e) => e.provider == 'b'), isFalse);
    });
  });

  group('T113-4 thresholds', () {
    test('interconnect threshold must exceed the auto-bind threshold', () {
      expect(kInterconnectThreshold, greaterThan(0.34),
          reason: 'a wrong interconnect silently poisons another source; be stricter');
    });
  });
}
