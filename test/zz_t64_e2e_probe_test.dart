// 2026-10-17（task-32 ①）★★ 端到端：season 兜底拿到的 cid ⇒ 真能取到弹幕
//
// # 为什么要这一步
// 拿到 cid 只证明"绑定成立"，不证明"弹幕出得来"。
// Owner 报的现象是「Missing Authentication Headers」—— 那发生在
// danmaku-service 那条路。本文件证明：**只要走了 season 兜底，
// 根本不需要 danmaku-service**，弹幕 XML 直接可取。
//
// 步骤 = 产品真实顺序（player_page.dart:_loadDanmaku → _loadBiliDanmaku）：
//   autoBindBySearch(搜索被风控) → season 兜底 → cid → fetchDanmaku(cid) → N 条弹幕
// ignore_for_file: avoid_print
import 'dart:io' as io;

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

class _SearchBlockedApi extends BiliApi {
  @override
  Future<List<BiliSearchItem>> searchVideos(String keyword, {int page = 1}) async {
    throw DanmakuException('某视频站接口返回 HTTP 412', statusCode: 412);
  }
}

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
  test('★★★ season 兜底的 cid ⇒ 真能取到弹幕（不需要 danmaku-service）', () async {
    if (!await _online()) {
      markTestSkipped('bilibili 不可达');
      return;
    }
    UiPrefs.debugResetForTest(<String, String>{});
    addTearDown(() => UiPrefs.debugResetForTest());

    final api = _SearchBlockedApi();
    final outcome = await autoBindBySearch(
      api: api,
      provider: 'cycani',
      id: 't64-e2e',
      localTitle: '鬼灭之刃',
      episodeTitles: const <String>['第01集', '第02集'],
    );
    expect(outcome, isNotNull, reason: 'season 兜底必须给出绑定');
    print('[E2E] 绑定 = ${outcome!.binding.title}（${outcome.binding.episodeCount} 集）');

    final cid = outcome.binding.cidFor(0);
    print('[E2E] 第1集 cid = $cid');
    expect(cid, greaterThan(0));

    // ★ 真正取弹幕（product 用 fetchDanmaku(cid)）
    final comments = await api.danmakuXml(cid);
    print('[E2E] XML 长度 = ${comments.length} 字节');
    expect(comments, isNotEmpty, reason: '★ 必须能取到弹幕 XML 正文');

    final list = parseBiliDanmakuXml(comments);
    print('[E2E] 解析出弹幕 = ${list.length} 条');
    for (final c in list.take(3)) {
      print('[E2E]   t=${c.time}  mode=${c.mode}  text=${c.text}');
    }
    expect(list.length, greaterThan(10),
        reason: '★ 必须真的解析出弹幕（不是空列表）');

    print('[E2E] ✅ 整条链路成立：搜索被风控(412) ⇒ season 兜底 ⇒ cid ⇒ ${list.length} 条弹幕');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
