// LIVE probe: multi-keyword search must find a work that a full title misses.
//
// Measured 2026-10-15 against the official API:
//   searchEpisodes(anime: <full episode title>) -> 0 works
//   searchEpisodesSmart(<same title>)           -> finds it
// and that episode (187270001) really has 2709 comments.
//
// Credentials come from --dart-define; with none the group is SKIPPED.

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';

const String kAppId = String.fromEnvironment('DANDANPLAY_APP_ID');
const String kAppSecret = String.fromEnvironment('DANDANPLAY_APP_SECRET');

const String kFullTitle =
    '无职转生Ⅲ ～到了异世界就拿出真本事～ 第1话 燃烧吧，狂犬';

void main() {
  final hasCred = kAppId.isNotEmpty && kAppSecret.isNotEmpty;

  group('T112-LIVE', () {
    test('** keyword splitter produces the segment that works', () {
      final kws = danmakuSearchKeywords(kFullTitle);
      print('  keywords=' + kws.toString());
      expect(kws, contains('无职转生Ⅲ'),
          reason: '** the first whitespace segment is the one that finds the show');
      expect(kws.first, kFullTitle,
          reason: 'the exact title must be tried first');
    });

    test('*** the OLD single-shot search finds NOTHING for this title', () async {
      final c = ExternalDanmakuClient(appId: kAppId, appSecret: kAppSecret);
      final old = await c.searchEpisodes(anime: kFullTitle);
      print('  old single-shot found=' + old.length.toString());
      expect(old, isEmpty,
          reason: 'documented root cause; if it ever starts working this guard becomes vacuous');
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('*** the NEW search finds the show, and that episode really has comments', () async {
      final c = ExternalDanmakuClient(appId: kAppId, appSecret: kAppSecret);
      final got = await c.searchEpisodesSmart(kFullTitle);
      print('  smart found=' + got.length.toString());
      expect(got, isNotEmpty, reason: '** this is the whole point of the fix');

      final hit = got.where((m) => m.episodeId == 187270001).toList();
      print('  contains 187270001=' + hit.isNotEmpty.toString());
      expect(hit, isNotEmpty,
          reason: '** must surface the correct episode (segment finds animeId 18727)');

      final cs = await c.fetchComments(187270001);
      print('  comments=' + cs.length.toString());
      expect(cs, isNotEmpty,
          reason: '** finding an episode with 0 comments would still show nothing');
      expect(got.first.episodeId, 187270001,
          reason: '* the right episode should rank FIRST');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('* no credentials => searchEpisodesSmart still fails loudly', () async {
      final c = ExternalDanmakuClient(appId: '', appSecret: '');
      await expectLater(
        c.searchEpisodesSmart(kFullTitle),
        throwsA(isA<DanmakuException>()),
      );
    }, timeout: const Timeout(Duration(seconds: 60)));
  }, skip: hasCred ? false : "need dart-define creds");
}