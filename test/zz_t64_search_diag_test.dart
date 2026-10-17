// 诊断：`searchVideos` 在**产品代码的调用方式**下到底成不成功
//
// 为什么必须单独测：season 兜底只在 `hits.isEmpty` 时触发。
// 若 searchVideos 成功 ⇒ season 永远不会被走到 ⇒ 真机证明不了 Lead 的改动。
// ignore_for_file: avoid_print
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/danmaku.dart';

void main() {
  test('searchVideos 真实行为', () async {
    final api = BiliApi();
    try {
      final hits = await api.searchVideos('鬼灭之刃');
      print('[SEARCH] OK  hits=${hits.length}');
      for (final h in hits.take(3)) {
        print('[SEARCH]   bvid=${h.bvid}  title=${h.title}');
      }
    } on DanmakuException catch (e) {
      print('[SEARCH] THREW DanmakuException status=${e.statusCode} msg=${e.message}');
      print('[SEARCH]   uri=${e.uri}');
    } catch (e) {
      print('[SEARCH] THREW $e');
    }

    // season 搜索那条
    try {
      final ids = await api.searchSeasonIds('鬼灭之刃');
      print('[SEASON-SEARCH] OK  ids=$ids');
    } catch (e) {
      print('[SEASON-SEARCH] THREW $e');
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
