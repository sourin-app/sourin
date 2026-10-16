// ═══════════════════════════════════════════════════════════════════════
//  端到端探针：真实 danmu_api（**需要本机跑着服务**）
// ═══════════════════════════════════════════════════════════════════════
//
// 用途：验证 T3 落地后的 core 层能**真的**从自建服务取到弹幕。
// ⚠️ 这是探针，不是单测：服务不在时**跳过**（不算失败，也不算通过）。
//    跑法：flutter test test/zz_t3_danmu_api_live_probe.dart --concurrency=1
//
// 它证明的是「离线单测的假 transport 形状与真服务一致」——
// 若真服务的响应形状变了，这里会红，而离线单测不会。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';

const _base = 'http://127.0.0.1:9321';

void main() {
  late bool up;
  setUpAll(() async {
    try {
      final c = HttpClient()..connectionTimeout = const Duration(seconds: 2);
      final req = await c.getUrl(Uri.parse('$_base/api/config'));
      final res = await req.close().timeout(const Duration(seconds: 3));
      up = res.statusCode == 200;
      c.close();
    } catch (_) {
      up = false;
    }
  });

  test('★ 真服务：探测 → 判在线（改前只认 version ⇒ 这里会判死）', () async {
    if (!up) {
      markTestSkipped('本机 $_base 没跑 danmu_api ⇒ 跳过（不是通过）');
      return;
    }
    final st = await DanmakuLocalService.describe(
      endpoint: const DanmakuEndpoint(baseUrl: _base),
    );
    expect(st.online, isTrue, reason: '★ 服务活着必须探到');
    expect(st.version, isNotNull, reason: '应读到 /api/config 的 version');
    // ignore: avoid_print
    print('[E2E] 状态行 = ${st.line}');
  });

  test('★ 真服务：搜索 → 取弹幕 → 解析（全链路）', () async {
    if (!up) {
      markTestSkipped('本机 $_base 没跑 danmu_api ⇒ 跳过（不是通过）');
      return;
    }
    final c = ExternalDanmakuClient(
      endpoint: const DanmakuEndpoint(baseUrl: _base),
    );
    try {
      final ms = await c.searchEpisodes(anime: '火影');
      expect(ms, isNotEmpty, reason: '真实搜索应返回结果');
      // ignore: avoid_print
      print('[E2E] 搜到 ${ms.length} 条；第一条 epId=${ms.first.episodeId} '
          'title=${ms.first.episodeTitle}');

      final cs = await c.fetchComments(ms.first.episodeId);
      // ignore: avoid_print
      print('[E2E] 取到 ${cs.length} 条弹幕；首条 t=${cs.first.time} '
          'mode=${cs.first.mode} text=${cs.first.text}');
      expect(cs, isNotEmpty, reason: '★ 解析器必须能吃下真服务的响应');
    } finally {
      c.close();
    }
  });

  test('★ 真服务：match 全链路（文件名 → 弹幕）', () async {
    if (!up) {
      markTestSkipped('本机 $_base 没跑 danmu_api ⇒ 跳过（不是通过）');
      return;
    }
    final c = ExternalDanmakuClient(
      endpoint: const DanmakuEndpoint(baseUrl: _base),
    );
    try {
      /*
       * ⚠️ 必须与**真实调用点**一致：player_page.dart:5979 传的是
       *     loadFor(fileName: fileName, videoDuration: ..., anime: fileName)
       *     —— anime **非空**。
       *
       * 探针第一版漏了 anime，落进 loadFor 的 else 支
       * （searchEpisodes(anime: '', episode: '') ⇒ 不带任何关键词），
       * danmu_api 对此回 HTTP 400 "Missing anime parameter"。
       * ★ 那是**存量**行为（HEAD 同一行、同一条支），不是本轮引入的；
       *   生产调用点永远带非空 anime ⇒ 用户碰不到。这里按真实调用点写。
       */
      final r = await c.loadFor(
        fileName: '[Nekomoe kissaten] Spy x Family S02 - 01.mp4',
        anime: 'Spy x Family',
      );
      // ignore: avoid_print
      print('[E2E] loadFor → ${r.comments.length} 条弹幕'
          '${r.match == null ? '' : ' match=${r.match!.animeTitle}'}');
      // 不强求非空（该片名未必被匹配到），但**不能抛**
    } finally {
      c.close();
    }
  });
}
