// ═══════════════════════════════════════════════════════════════════════
//  N1 · appget 类源候选摘除判据三态化门禁（2026-11-01，lead 批复①②）
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景（.probe/play-audit-cleanenv-2026-10-31.md 实锤）
// ```text
// appget 类源的 play 结果普遍是第三方播放页 ⇒ 改前规则⑤按形态整批摘掉
// ⇒ 列表空 ⇒ 「该内容没有可播放的地址」—— appget 类源完全不能播的直因。
// ```
//
// # 三态判据（lib/core/stream_prepare.dart::verdictOf，lead 批复的判据表）
// ```text
// S1 空 / 非 http(s) / 无 host   ⇒ 摘（无任何后续路径）
// S2 猜拼媒体后缀                ⇒ 摘（既有 r65 门禁，本批不动）
// S3 页面段且无媒体扩展          ⇒ 留 + 标「需解析」
// S4 直链 / HLS                 ⇒ 直通（逐字不变）
// S5 needsHostResolve           ⇒ 编排层不变（t33 契约）
// ```
//
// # 「有路径」的实测依据（第一段报告，lead 批复①）
// ```text
// 起播预检（player/nonmedia_guard.dart，T4-I 已接线）：
//   播放页 https://v.gsuus.com/play/dBBBRBxd GET 200（HTML 壳）
//   页内唯一流 const vid = '…/play/dBBBRBxd/index.m3u8'
//   实测 200 + application/vnd.apple.mpegurl + 合法 #EXTM3U（AES-128 + 真 .ts 分段）
// ⇒ S3 保留后点开：预检刮出 vid ⇒ 换直链 ⇒ 可播。
// ```
//
// # ⚠️ 残余边界（如实，lead 批复补充 2 —— 不许当作"已解决"）
// ```text
// ① VIP 大站播放页（v.qq.com 等，需 jx 解析接口）页内无流、仓内无 jx
//    ⇒ 保留后点开由预检给人话报错 —— 播不了，但不是黑屏/静默；
// ② 页面若嵌假流 ⇒ 预检刮出后 mpv open 失败。
// 两者都由预检兜底；判据层只保证"不摘有路径的候选"。
// ```
//
// # 证红开关
// `StreamPreparer.debugShortCircuitPageKeep` = true ⇒ S3 退回改前的「摘」
// ⇒ 本文件的「留+标」用例与 `zz_r65_stream_validation_test.dart` 混合③
//    必须变红（证明新字面有牙；生产代码永不写它）。
//
// # 撤销验证
// 把 `verdictOf` 里 keepMarked 分支改成恒 drop（或置真证红开关）⇒
// 「留+标行为」组全红；把 `_pageShapePathOf` 删掉 ⇒ S3 用例红、S2 用例仍绿。

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/stream_prepare.dart';
import 'package:sourin_spike/ui/live_availability.dart' show isAudioOnlyLine;

/// 造一条候选（只填本文件要用的字段；与 r65 门禁同款）
StreamCandidate cand(
  String url, {
  String? label,
  bool needsHost = false,
}) =>
    StreamCandidate(
      url: url,
      kind: 'mp4',
      quality: '1080P',
      label: label,
      headers: const <(String, String)>[],
      notWebReady: false,
      drmProtected: false,
      needsHostResolve: needsHost,
      siteId: 'src',
    );

void main() {
  setUp(StreamPreparer.debugReset);
  tearDown(() => debugShortCircuitPageKeep = false);

  group('三态判据 verdictOf（纯函数）', () {
    test('S3 appget 形态：/play/<id> 纯页面 ⇒ keepMarked', () {
      expect(StreamPreparer.verdictOf('https://v.gsuus.com/play/dBBBRBxd'),
          PrepareVerdict.keepMarked);
    });

    test('S3 其余页面段形态：/video/ /vodplay/ /index.php/ ⇒ keepMarked', () {
      expect(StreamPreparer.verdictOf('https://s.example/video/12345'),
          PrepareVerdict.keepMarked);
      expect(StreamPreparer.verdictOf('https://s.example/vodplay/9-1-1.html'),
          PrepareVerdict.keepMarked);
      expect(StreamPreparer.verdictOf('https://s.example/index.php/vod/play/id/9'),
          PrepareVerdict.keepMarked);
    });

    test('S1 空 / 非 http(s) / 无 host ⇒ drop（无任何后续路径）', () {
      expect(StreamPreparer.verdictOf(''), PrepareVerdict.drop);
      expect(StreamPreparer.verdictOf('   '), PrepareVerdict.drop);
      expect(StreamPreparer.verdictOf('blob:https://x/abc'), PrepareVerdict.drop);
      expect(StreamPreparer.verdictOf('file:///C:/a.mp4'), PrepareVerdict.drop);
      expect(StreamPreparer.verdictOf('https:///a.mp4'), PrepareVerdict.drop);
    });

    test('S2 猜拼媒体后缀 ⇒ drop（不因三态改造放宽，r65 门禁原样）', () {
      expect(StreamPreparer.verdictOf('https://v.gsuus.com/play/dBBBRBxd/index.m3u8'),
          PrepareVerdict.drop);
      expect(StreamPreparer.verdictOf('https://s.example/video/abc/playlist.mp4'),
          PrepareVerdict.drop);
    });

    test('S4 直链 / HLS ⇒ passthrough（含带 query 与 /video/ 带扩展）', () {
      expect(StreamPreparer.verdictOf('https://cdn.example.com/a/index.m3u8'),
          PrepareVerdict.passthrough);
      expect(StreamPreparer.verdictOf('https://cdn.example.com/b.mp4'),
          PrepareVerdict.passthrough);
      expect(StreamPreparer.verdictOf('https://cdn.example.com/c/manifest.mpd'),
          PrepareVerdict.passthrough);
      expect(StreamPreparer.verdictOf('http://1.2.3.4:9981/x/y.m3u8?token=abc'),
          PrepareVerdict.passthrough);
      expect(StreamPreparer.verdictOf('https://cdn.example.com/video/abc/def.mp4'),
          PrepareVerdict.passthrough,
          reason: '★ 路径有 /video/ 但带媒体扩展 ⇒ 直链，不是页面');
    });
  });

  group('留+标行为（prepare）', () {
    test('① appget 形态：保留、url 逐字不变、label 标「需解析」、留痕对齐', () async {
      final out = await StreamPreparer.prepare(
          [cand('https://v.gsuus.com/play/dBBBRBxd', label: '线路1')]);
      expect(out, hasLength(1),
          reason: '★ 改前这里被整批摘掉 ⇒ 列表空 ⇒ 「该内容没有可播放的地址」');
      expect(out.single.url, 'https://v.gsuus.com/play/dBBBRBxd',
          reason: '★ url 逐字不变 —— 换直链是起播预检的活，不是 prepare 的');
      expect(out.single.label, '线路1（需解析）');
      expect(out.single.needsHostResolve, isFalse,
          reason: '★ 不许走 needsHostResolve=true —— '
              'isPlayable 会被筛掉，又回空列表，等于白改');
      expect(out.single.isPlayable, isTrue);
      expect(StreamPreparer.lastDroppedCount, 0,
          reason: '★ 页面形态不算摘除（留痕语义与新三态对齐）');
      expect(StreamPreparer.lastDroppedReasons, isEmpty);
      expect(StreamPreparer.lastKeptNeedsResolveCount, 1);
    });

    test('② Rust 已声明「需 parse」的页面候选 ⇒ 保留且不重复加标', () async {
      final out = await StreamPreparer.prepare(
          [cand('https://v.example/play/abc', label: '线路1（需 parse）')]);
      expect(out, hasLength(1));
      expect(out.single.url, 'https://v.example/play/abc');
      expect(out.single.label, '线路1（需 parse）',
          reason: '★ 声明过的不再追加「（需解析）」—— 不许双标');
      expect(StreamPreparer.lastKeptNeedsResolveCount, 1);
      expect(StreamPreparer.lastDroppedCount, 0);
    });

    test('③ 声明了 parse 但不是页面形态（VIP 大站形态）⇒ 原样直通、零标注', () async {
      // v.qq.com/x/cover/… 不命中页面段判据（改前就没被摘，是既有正常源）
      // ⇒ 三态改造不许碰它（既有正常源行为零变化）
      final out = await StreamPreparer.prepare(
          [cand('https://v.qq.com/x/cover/mzc002001w361jz/v4102hrb7cq.html',
              label: '线路1（需 parse）')]);
      expect(out, hasLength(1));
      expect(out.single.label, '线路1（需 parse）');
      expect(StreamPreparer.lastKeptNeedsResolveCount, 0,
          reason: '★ 直通档不计「留+标」—— 计数语义只收页面形态档');
    });

    test('④ 空 label 的页面候选 ⇒ 标「需解析」（不落到空串）', () async {
      final out = await StreamPreparer.prepare(
          [cand('https://v.gsuus.com/play/dBBBRBxd')]);
      expect(out.single.label, '需解析');
      expect(out.single.isPlayable, isTrue);
    });

    test('⑤ 标注串不许踩音频线判据（isAudioOnlyLine 关键字）', () async {
      // lead 补充 1 的断言面：live_availability.dart:97 只认 音频/广播/audio，
      // 「（需解析）」不许含这些关键字 —— 否则直播分类会被误判成 audioOnly
      final out = await StreamPreparer.prepare(
          [cand('https://v.gsuus.com/play/dBBBRBxd', label: '线路1')]);
      expect(isAudioOnlyLine(out.single), isFalse,
          reason: '★ 标「需解析」不许让线路被误判成音频线');
    });

    test('⑥ 直通档：零摘零标 ⇒ 原实例返回（identical 契约保持）', () async {
      final list = [cand('https://cdn.example.com/a/index.m3u8', label: '好')];
      final out = await StreamPreparer.prepare(list);
      expect(identical(out, list), isTrue,
          reason: '★ 没要改的东西，必须返回同一个 List（t33 同款契约）');
      expect(out.single.label, '好', reason: 'label 逐字不动');
    });

    test('⑦ 混合：页面候选与直链共存，直链条目逐字原样', () async {
      final out = await StreamPreparer.prepare([
        cand('https://v.gsuus.com/play/dBBBRBxd', label: '页'),
        cand('https://cdn.example.com/ok/index.m3u8', label: '直链1'),
        cand('https://cdn.example.com/ok2.mp4', label: '直链2'),
      ]);
      expect(out, hasLength(3));
      expect(out[0].label, '页（需解析）');
      expect(out[1].label, '直链1');
      expect(out[1].url, 'https://cdn.example.com/ok/index.m3u8');
      expect(out[2].label, '直链2');
      expect(out[2].url, 'https://cdn.example.com/ok2.mp4');
      expect(StreamPreparer.lastDroppedCount, 0);
      expect(StreamPreparer.lastKeptNeedsResolveCount, 1);
    });
  });

  group('直链/HLS 回归：prepare 结果与改前逐字一致', () {
    test('媒体直链集合：identical + url/label/quality 逐字 + 双计数归零', () async {
      final urls = <String>[
        'https://cdn.example.com/a/index.m3u8',
        'https://cdn.example.com/a.m3u',
        'https://cdn.example.com/b.mp4',
        'https://cdn.example.com/c/manifest.mpd',
        'https://cdn.example.com/d.flv',
        'http://1.2.3.4:9981/x/y.m3u8?token=abc',
        'https://cdn.example.com/live/play.m3u8?sign=1&t=2',
        'https://cdn.example.com/video/abc/def.mp4',
      ];
      final list = <StreamCandidate>[
        for (var i = 0; i < urls.length; i++) cand(urls[i], label: 'L$i'),
      ];
      final out = await StreamPreparer.prepare(list);
      expect(identical(out, list), isTrue,
          reason: '★ 全是直链 ⇒ 一条都不动、原实例返回');
      for (var i = 0; i < urls.length; i++) {
        expect(out[i].url, urls[i], reason: '第 $i 条 url 逐字');
        expect(out[i].label, 'L$i', reason: '第 $i 条 label 逐字');
        expect(out[i].quality, '1080P', reason: '第 $i 条 quality 逐字');
        expect(out[i].needsHostResolve, isFalse);
        expect(out[i].isPlayable, isTrue);
      }
      expect(StreamPreparer.lastDroppedCount, 0);
      expect(StreamPreparer.lastDroppedReasons, isEmpty);
      expect(StreamPreparer.lastKeptNeedsResolveCount, 0);
      expect(StreamPreparer.lastNeedsResolveCount, 0);
    });

    test('纯页面坏形态（S1/S2）⇒ 照旧摘除、理由逐字在（回归不改旧账）', () async {
      final out = await StreamPreparer.prepare([
        cand(''),
        cand('ftp://x/a.mp4'),
        cand('https:///a.mp4'),
        cand('https://v.gsuus.com/play/dBBBRBxd/index.m3u8', label: '坏'),
      ]);
      expect(out, isEmpty, reason: '四条都无任何后续路径 ⇒ 照旧全摘');
      expect(StreamPreparer.lastDroppedCount, 4);
      expect(StreamPreparer.lastDroppedReasons[3], contains('播放页地址又拼了媒体后缀'),
          reason: '★ S2 的摘除理由原句不变');
      expect(StreamPreparer.lastKeptNeedsResolveCount, 0);
    });
  });

  group('证红注入（debugShortCircuitPageKeep）', () {
    test('开关置真 ⇒ S3 退回改前的「摘」，摘除理由用改前原句', () async {
      debugShortCircuitPageKeep = true;
      final out = await StreamPreparer.prepare(
          [cand('https://v.gsuus.com/play/dBBBRBxd', label: '线路1')]);
      expect(out, isEmpty, reason: '证红：规则⑤退回摘 ⇒ 改前行为逐字复现');
      expect(StreamPreparer.lastDroppedCount, 1);
      expect(StreamPreparer.lastDroppedReasons.single,
          '线路1: 看起来是播放页而不是媒体地址：/play/dbbbrbxd',
          reason: '★ 逐字等于改前理由串（path 小写化口径不变）');
      expect(StreamPreparer.lastKeptNeedsResolveCount, 0);
    });
  });
}
