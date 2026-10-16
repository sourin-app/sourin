// T112b: live probe using the Owner's REAL titles.
//
// The earlier probe (zz_t112) proved the smart search works for the episode
// title the player shows.  This one goes further and uses the actual strings
// found on this machine:
//
//   local file : 第01集 第01集.mp4
//   work title : 无职转生Ⅲ ～到了异世界就拿出真本事～ 第1话 燃烧吧，狂犬
//
// It also runs buildBatchBindPlan against REAL API output -- the closest we
// can get to the batch-bind feature with only one episode on disk.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/batch_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';

const String _appId = String.fromEnvironment('DANDANPLAY_APP_ID');
const String _appSecret = String.fromEnvironment('DANDANPLAY_APP_SECRET');

void main() {
  final hasCreds = _appId.isNotEmpty && _appSecret.isNotEmpty;

  test('REAL local file title parses as episode 1', () {
    // The Owner's file is literally "第01集 第01集.mp4".
    expect(episodeNumberFrom('第01集 第01集'), 1);
  });

  test('*** live: the REAL work title finds the right episode', () async {
    final client = ExternalDanmakuClient(appId: _appId, appSecret: _appSecret);
    const workTitle = '无职转生Ⅲ ～到了异世界就拿出真本事～ 第1话 燃烧吧，狂犬';

    // The old single-shot path -- this is what shipped before the fix.
    final old = await client.searchEpisodes(anime: workTitle);
    stdout.writeln('[REAL] old single-shot found=' + old.length.toString());

    final smart = await client.searchEpisodesSmart(workTitle);
    stdout.writeln('[REAL] smart found=' + smart.length.toString());

    expect(smart.length, greaterThan(0),
        reason: '*** the whole point: the real title must find something');
    expect(smart.any((m) => m.episodeId == 187270001), isTrue,
        reason: '*** must find episode 187270001 (the correct one)');

    final hit = smart.firstWhere((m) => m.episodeId == 187270001);
    stdout.writeln('[REAL] hit: ' + hit.animeTitle + ' / ' + hit.episodeTitle);

    final comments = await client.fetchComments(187270001);
    stdout.writeln('[REAL] comments=' + comments.length.toString());
    expect(comments.length, greaterThan(100),
        reason: '*** there really are comments behind this id');

    // ---- batch bind against REAL api output --------------------------
    final plan = buildBatchBindPlan(
      localTitles: [
        for (var i = 1; i <= 12; i++)
          '第' + i.toString().padLeft(2, '0') + '集 第' + i.toString().padLeft(2, '0') + '集',
      ],
      matches: smart,
      workTitle: hit.animeTitle,
    );
    stdout.writeln('[REAL] plan: ' + plan.toString());
    stdout.writeln('[REAL] unmatched=' + plan.unmatchedLocal.toString());

    // Every bound episode must be a DIFFERENT id -- the invariant that matters.
    final ids = plan.items.map((e) => e.episodeId).toSet();
    expect(ids.length, plan.items.length,
        reason: '*** no two episodes may share one episodeId');
  }, skip: hasCreds ? false : 'no --dart-define credentials');
}
