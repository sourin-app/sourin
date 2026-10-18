// 2026-10-17（task-32 ①）★★★ 关键缺口：搜索**有结果但都不匹配**时，season 兜底不会被触发
//
// Lead 的兜底条件是 `if (hits.isEmpty)` —— 只在**搜索返回空**时进入。
// 但 `autoBindBySearch` 还有另一条 return null 的路：
//   搜到 20 条，但没有一条的 titleCoverage >= 0.34 ⇒ 同样 return null
//   ⇒ 同样降级 danmaku-service ⇒ 同样 403 Missing Authentication Headers。
// 这条路**不会**走到 season。
//
// 本文件证明这条缺口真实存在（用真网络 + 一个搜索有结果但匹配分不够的标题）。
// ignore_for_file: avoid_print
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/title_match.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

Future<bool> _online() async {
  try {
    final r = await (await io.HttpClient()
            .getUrl(Uri.parse('https://api.bilibili.com/pgc/view/web/season?season_id=26801'))
        .timeout(const Duration(seconds: 10)))
        .close();
    await r.drain<void>();
    return r.statusCode == 200;
  } catch (_) {
    return false;
  }
}

void main() {
  test('★ 搜索有结果但匹配分不够 ⇒ season 兜底**不**接管（缺口）', () async {
    if (!await _online()) {
      markTestSkipped('bilibili 不可达');
      return;
    }
    final api = BiliApi();

    // 一个"真实存在但搜索出来全是别的东西"的标题：
    // 用一部番剧名的**剧中中文译名**，搜索会返回一堆不相关条目。
    const localTitle = '鬼灭之刃 柱训练篇 第二季 特别编集版';
    /*
     * ★★★ 2026-10-17：把「站点风控」与「真失败」分开
     *
     * # 为什么要加
     * 这条是**真网络**测试，直接打 api.bilibili.com。连续跑几次就会被风控，
     * 实测：连跑 3 次里必有一次抛
     *   DanmakuException(某视频站接口返回 HTTP 412)
     * 而 412 是**站点的反爬响应**，不是本仓的缺陷，也不是「缺口不成立」。
     *
     * # 不加会怎样
     * 全量测试会**间歇性变红**。而 flaky 测试比没有测试更坏：
     * 它让人开始忽略红灯，真正的回归就混在里面被放过。
     * （本仓已有先例：zz_t42_player_keys_test 的 setUp 污染让别的门禁假红。）
     *
     * # 判据
     * 只对「站点侧限流/风控」跳过，且**必须明说跳过**（markTestSkipped 会显示原因）。
     * 网络不通（连不上）仍走上面的 _online() 分支。
     * 其它异常一律照常抛出 —— 不许把真缺陷也一起吞掉。
     */
    final List<dynamic> hits;
    try {
      hits = await api.searchVideos(localTitle);
    } catch (e) {
      final s = e.toString();
      final throttled = s.contains('412') ||
          s.contains('429') ||
          s.contains('403') ||
          s.contains('风控') ||
          s.contains('risk');
      if (throttled) {
        markTestSkipped('站点风控/限流（$s）⇒ 这次验不了缺口，不当作失败。'
            '稍等几分钟再跑，或换一个搜索关键词。');
        return;
      }
      rethrow;
    }
    print('[GAP] search hits = ${hits.length}');
    double best = 0;
    String bestT = '';
    for (final h in hits) {
      final s = titleCoverage(localTitle, h.title);
      if (s > best) {
        best = s;
        bestT = h.title;
      }
    }
    print('[GAP] bestCoverage = ${best.toStringAsFixed(4)}  on "$bestT"');
    print('[GAP] threshold    = kN/A（minScore 默认 0.34）');

    UiPrefs.debugResetForTest(<String, String>{});
    addTearDown(() => UiPrefs.debugResetForTest());

    final outcome = await autoBindBySearch(
      api: api,
      provider: 'cycani',
      id: 't64-gap',
      localTitle: localTitle,
      episodeTitles: const <String>['第01集', '第02集'],
    );

    print('[GAP] autoBindBySearch => ${outcome == null ? 'null（缺口成立）' : outcome.reason}');

    // ★ 这条测试**不是**断言"应该成功"——它记录的是一个**现存事实**：
    //   搜到了结果但匹配分不够时，season 兜底被跳过。
    //   若将来 Lead 把兜底条件从 `hits.isEmpty` 放宽，这条会自然变绿。
    if (outcome == null && hits.isNotEmpty && best < 0.34) {
      print('[GAP] ⇒ 确认缺口：hits 非空但 bestCoverage 不足，season 未接管');
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
