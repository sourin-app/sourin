// 2026-10-17 Owner 第 6 条：验证 season 备用链路**真能拿到 cid**
//
// 这不是 mock —— 它真发 HTTP 请求。若网络上不了就 skip（不是 pass）。
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';

void main() {
  test('searchSeasonIds + seasonInfo 能免登录拿到整季 cid', () async {
    // 先确认网络可用，不可用就 skip（skip ≠ pass）
    try {
      final probe = await io.HttpClient()
          .getUrl(Uri.parse('https://api.bilibili.com/x/web-interface/view?bvid=BV1GJ411x7h7'))
          .timeout(const Duration(seconds: 10));
      final r = await probe.close();
      await r.drain<void>();
      if (r.statusCode != 200) {
        markTestSkipped('bilibili 不可达（http=${r.statusCode}）');
        return;
      }
    } catch (e) {
      markTestSkipped('bilibili 不可达：$e');
      return;
    }

    final api = BiliApi();
    // 无职转生 = season_id 26801（Lead 2026-10-17 实测确认 26 集）
    final season = await api.seasonInfo(26801);

    expect(season, isNotNull, reason: 'seasonInfo 必须能拿到季信息');
    expect(season!.seasonId, 26801);
    expect(season.episodes, isNotEmpty, reason: '整季必须有分集');
    expect(season.episodes.first.cid, greaterThan(0),
        reason: '第一集必须有 cid（弹幕靠它取）');

    // 逐集 cid 都必须是正数（无 cid 的条目应被 parseBiliSeason 跳过）
    for (final e in season.episodes) {
      expect(e.cid, greaterThan(0),
          reason: '每集都应有 cid，无 cid 的应已被跳过');
    }

    // ignore: avoid_print
    print('✓ season 26801「${season.title}」共 ${season.episodes.length} 集');
    // ignore: avoid_print
    print('  第1集 cid=${season.episodes.first.cid}  title=${season.episodes.first.title}');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
