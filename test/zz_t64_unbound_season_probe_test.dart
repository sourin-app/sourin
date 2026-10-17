// 2026-10-17（task-32 ①）真实网络：**未绑定**作品走 Season 兜底能否拿到 cid
//
// ★ 与 zz_t64_bili_season_fallback_test.dart 的分工：
//   那份只测 `seasonInfo(26801)` 这个**已知 season_id** 的接口；
//   本份测的是**产品真正走的那条路** —— `autoBindBySearch()`：
//   用户第一次播一个没绑过的作品 ⇒ 搜索 ⇒ 搜索被风控(412/空) ⇒ 走 season 兜底。
//   Lead 改的正是这条兜底（bili_bind.dart:_autoBindViaSeason），所以必须测它。
//
// ⚠️ 真发 HTTP；网络不可用 ⇒ skip（skip ≠ pass）。
// ignore_for_file: avoid_print
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

Future<bool> _online() async {
  try {
    final r = await (await io.HttpClient()
            .getUrl(Uri.parse('https://api.bilibili.com/x/web-interface/view?bvid=BV1GJ411x7h7'))
        .timeout(const Duration(seconds: 10)))
        .close();
    await r.drain<void>();
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('未绑定作品：autoBindBySearch 必须经 season 兜底拿到 cid', () async {
    if (!await _online()) {
      markTestSkipped('bilibili 不可达');
      return;
    }

    // ★ 空的 UiPrefs ⇒ 保证**没有任何历史绑定**（正是"用户第一次播"）
    UiPrefs.debugResetForTest(<String, String>{});
    addTearDown(() => UiPrefs.debugResetForTest());

    final api = BiliApi();
    // 一个**故意没绑定过**的 provider/id（要真播放才有的键，这里只是取个不存在的）
    final outcome = await autoBindBySearch(
      api: api,
      provider: 'cycani',
      id: 't64-unbound-probe',
      // 用番剧名（season 链路就是给 PGC 用的）
      localTitle: '鬼灭之刃',
      episodeTitles: const <String>['第01集', '第02集'],
    );

    print('[PROBE] outcome = ${outcome == null ? 'null' : 'score=${outcome.score} reason=${outcome.reason}'}');
    if (outcome != null) {
      print('[PROBE] binding.manual=${outcome.binding.manual}');
      print('[PROBE] binding.bvid=${outcome.binding.bvid}  title=${outcome.binding.title}');
      print('[PROBE] binding.episodes=${outcome.binding.episodeCount}');
      for (final e in outcome.binding.episodes.take(3)) {
        print('[PROBE]   ep#${e.episodeIndex} cid=${e.cid} page=${e.page}');
      }
    }

    expect(outcome, isNotNull,
        reason: '★ 未绑定作品必须能自动匹配到（否则播放页会落到 danmaku-service 报 403）');
    // 弹幕真正要的是 cid
    final cid = outcome!.binding.cidFor(0);
    print('[PROBE] 第1集 cid = $cid');
    expect(cid, greaterThan(0), reason: '★ 必须有 cid 才能取弹幕 XML');
  }, timeout: const Timeout(Duration(seconds: 90)));
}
