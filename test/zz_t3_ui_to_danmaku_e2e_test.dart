// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 端到端：**从 UI 配置**自建服务 ⇒ bilibili 弹幕搜索真的出结果
// ═══════════════════════════════════════════════════════════════════════
//
// 这是 Owner 第 6 条「bilibili搜索弹幕,提示失败」的**验收**：
// ```text
// 改前：没有凭证 ⇒ 官方边 403「Missing Authentication Headers」⇒ 搜索失败
// 改后：在面板里填一个自建服务地址、测通 ⇒ 搜索**真的出结果**
// ```
//
// # 本文件模拟的正是**面板点了什么**
// ```text
// ① UiPrefs.setDanmakuEndpoint(...)   ← 面板「测试连接」成功时写的同一个键
// ② ExternalDanmakuClient()            ← **不传** endpoint，与 player_page 的构造一致
//    （证明「面板写偏好 ⇒ 客户端自动生效」这条接线真的通了）
// ③ searchEpisodesSmart / loadFor      ← 与生产同一条链路
// ```
//
// ⚠️ 需要本机跑着 danmu_api（默认 9321）。没跑 ⇒ **跳过**（不是通过）。
//    跑法：flutter test test/zz_t3_ui_to_danmaku_e2e_test.dart --concurrency=1

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

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

  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  test('★★★ 面板写偏好 ⇒ 不传 endpoint 的客户端**自动**走自建服务', () async {
    if (!up) {
      markTestSkipped('本机 $_base 没跑 danmu_api ⇒ 跳过（不是通过）');
      return;
    }
    // ① 这一步 = 面板「测试连接」成功后写的同一个键
    UiPrefs.setDanmakuEndpoint(_base);

    // ② 与 player_page._ensureDanmakuClient() 一模一样的构造（不传 endpoint）
    final c = ExternalDanmakuClient();
    try {
      // ③ 与生产同一条链路
      final ms = await c.searchEpisodesSmart('火影忍者');
      expect(ms, isNotEmpty, reason: '★★★ 从 UI 配好之后，搜索必须真的出结果');
      // ignore: avoid_print
      print('[E2E-UI] 不传 endpoint 的客户端搜到 ${ms.length} 条；'
          '首条 epId=${ms.first.episodeId} title=${ms.first.episodeTitle}');
    } finally {
      c.close();
    }
  });

  test('★★★ 配好后 loadFor（bilibili 命名）真的取到弹幕', () async {
    if (!up) {
      markTestSkipped('本机 $_base 没跑 danmu_api ⇒ 跳过（不是通过）');
      return;
    }
    UiPrefs.setDanmakuEndpoint(_base);
    final c = ExternalDanmakuClient();
    try {
      final r = await c.loadFor(
        fileName: '[Nekomoe kissaten] Spy x Family S02 - 01.mp4',
        anime: 'Spy x Family',
      );
      expect(r.comments, isNotEmpty, reason: '★★★ 取到弹幕才算通');
      // ignore: avoid_print
      print('[E2E-UI] loadFor → ${r.comments.length} 条弹幕；'
          'match=${r.match?.animeTitle}');
    } finally {
      c.close();
    }
  });

  test('★★★ Owner 第 6 条原题：搜索 bilibili 弹幕**真的出结果**', () async {
    if (!up) {
      markTestSkipped('本机 $_base 没跑 danmu_api ⇒ 跳过（不是通过）');
      return;
    }
    UiPrefs.setDanmakuEndpoint(_base);
    final c = ExternalDanmakuClient();
    try {
      // 找一个弹幕源带 bilibili 的剧集
      final ms = await c.searchEpisodesSmart('火影忍者');
      expect(ms, isNotEmpty);
      final bili = ms.where((m) => m.episodeTitle.contains('bilibili1')).toList();
      // ignore: avoid_print
      print('[E2E-UI] 搜到 ${ms.length} 条剧集，其中 bilibili 源 ${bili.length} 条');
      expect(bili, isNotEmpty, reason: '★ 搜到 0 条 bilibili 源 = 没用');

      final ep = bili.first;
      // ignore: avoid_print
      print('[E2E-UI] bilibili 剧集: epId=${ep.episodeId} title=${ep.episodeTitle}');

      final cs = await c.fetchComments(ep.episodeId);
      expect(cs, isNotEmpty, reason: '★★★ bilibili 弹幕必须真的取到');
      // ignore: avoid_print
      print('[E2E-UI] ★★★ bilibili 弹幕取到 ${cs.length} 条；'
          '首条 t=${cs.first.time} mode=${cs.first.mode} text=${cs.first.text}');
    } finally {
      c.close();
    }
  });

  test('★★ 清除偏好 ⇒ 客户端**立刻**不再走自建服务（回到内置路径）', () async {
    if (!up) {
      markTestSkipped('本机 $_base 没跑 danmu_api ⇒ 跳过（不是通过）');
      return;
    }
    UiPrefs.setDanmakuEndpoint(_base);
    final c = ExternalDanmakuClient();
    try {
      final ms = await c.searchEpisodesSmart('火影忍者');
      expect(ms, isNotEmpty);

      // 用户点「清除」
      UiPrefs.setDanmakuEndpoint('');
      // ★ 同一个客户端实例、不清缓存 —— 因为 _endpoint 是**每次请求重解析**的
      //   所以下一条请求就该走官方边（无凭证 ⇒ 会失败，这正是预期）
      await expectLater(
        c.searchEpisodesSmart('火影忍者'),
        throwsA(isA<DanmakuException>()),
        reason: '★★ 清掉地址后仍然打自建服务 = 偏好没生效',
      );
      // ignore: avoid_print
      print('[E2E-UI] 清除后如实回到官方边（无凭证 ⇒ 抛错，符合预期）');
    } finally {
      c.close();
    }
  });
}
