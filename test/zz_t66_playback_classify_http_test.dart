// ═══════════════════════════════════════════════════════════════════════
//  轨道 H · 第 6 条门禁：失败归因必须认 **HTTP 状态码**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁补的是上一轮留下的真缺口
//
// ```text
// 上一轮（第 65 轮）的 `PlaybackErrorText.classify` 只认**中文关键词**
// （「大会员」「地区」「版权」…），**完全没有 401/403/429/5xx 这些数字**。
// 本轮实测（.probe/round65-c/samples_run6.log，32 个源 35 条样本）：
//   代理把上游的 403 原样转出来，正文是一张 **HTML 错误页**：
//     <h1>403 Forbidden</h1>
//     <p>The region has been denied.</p>
//   ⇒ 落进 unknown ⇒ 用户看到的就是那张 HTML 原文。
// ```
//
// # 为什么数字必须排在关键词之前
// ```text
// 「403」是**协议层事实**；「地区」是我们从人话里猜的。
// 协议事实优先 —— 与本仓 `ffi.rs::classify_error`
// 「先认标准前缀，再退中文关键词」是同一条纪律。
// ```
//
// # 为什么这组断言不会假绿
// ```text
// 每条都同时钉两个方向：
//   ① 该认的认出来（403 ⇒ permission）
//   ② 不许把**内容里的数字**当状态码（「第 403 集」⇒ 不是 permission）
// 只做 ① 的话，一个「见到 3 位数就当 403」的实现也能全绿 —— 那是灾难。
// ```
//
// # 撤销验证（交付报告里的读数）
// ```text
// 把 classify 里那段 `final httpCode = _extractHttpStatus(lower);`
// 整块注释掉 ⇒ 本文件 ①②③④ 组全红。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

/// 便于断言：只取 kind
PlaybackFailureKind k(String input, {bool hadCandidates = true}) =>
    PlaybackErrorText.classify(input, hadCandidates: hadCandidates).kind;

void main() {
  group('① 源站权限（E 类）：401 / 403 必须认出来', () {
    test('实测原文：代理转出的上游 403 错误页', () {
      // ★ 这条是 .probe/round65-c/samples_run6.log 里 6 条 E 类样本的**真实正文**
      const raw = '<h1>403 Forbidden</h1>'
          '<p>The region has been denied.</p>'
          '<address>Connection: 67.159.48.150 (Client) -&gt; 23.144.28.41 (Server)</address>';
      final f = PlaybackErrorText.classify(raw, hadCandidates: true);
      expect(f.kind, PlaybackFailureKind.permission,
          reason: '★ 403 是协议事实，必须归 permission（E 类）');
      expect(f.headline, '这个内容需要源站会员，或不在当前地区',
          reason: '★ 文案要说人话，不能把 HTML 错误页当标题');
      expect(f.canRetry, isFalse,
          reason: '★ 源站限制重试一万次都一样 —— 不许画假出口');
    });

    test('HTTP 403 / HTTP/1.1 403 / status=401 三种写法', () {
      for (final raw in <String>[
        'HTTP 403',
        'HTTP/1.1 403',
        'http status 403',
        'status=401',
        'status: 401',
        '401 Unauthorized',
        '403 Forbidden',
      ]) {
        expect(k(raw), PlaybackFailureKind.permission, reason: '原句: $raw');
      }
    });
  });

  group('② 源站限流/临时故障（F 类）：429 / 5xx', () {
    test('429 与 5xx 归 network', () {
      for (final raw in <String>[
        '429 Too Many Requests',
        'HTTP 503',
        'status: 504',
        '502 Bad Gateway',
        '503 Service Unavailable',
        '504 Gateway Timeout',
      ]) {
        expect(k(raw), PlaybackFailureKind.network, reason: '原句: $raw');
      }
    });

    test('F 类要给重试（它是临时的）', () {
      final f = PlaybackErrorText.classify('HTTP 503', hadCandidates: true);
      expect(f.canRetry, isTrue,
          reason: '★ 临时故障重试有意义 —— 与 E 类的处置不同');
    });
  });

  group('③ 地址没了：404 / 410 归源解析', () {
    test('404 归 source', () {
      for (final raw in <String>['404 Not Found', 'HTTP 404', 'status=410']) {
        expect(k(raw), PlaybackFailureKind.source, reason: '原句: $raw');
      }
    });
  });

  group('★★ 不许误判：内容里的数字不是状态码', () {
    test('「第 403 集」不许归成 permission', () {
      // ⚠️ 集数、时长、房间号都长这样
      final f = PlaybackErrorText.classify(
        '第 403 集不存在',
        hadCandidates: true,
      );
      expect(f.kind, isNot(PlaybackFailureKind.permission),
          reason: '★ 集数不是 HTTP 状态码');
    });

    test('URL 里的 202503 / /a/503/ 不许归成 network', () {
      /*
       * ★ 这两条是**本门禁第一次跑就抓到的真实误判**（不是假想）
       *
       * 改前 netWords 里有裸字符串 '502'/'503'/'504'，用 contains 判：
       *   "…/videos/202503/20/…"  ⇒ contains('502') 命中 "202503"
       *   "…/a/503/…"             ⇒ contains('503') 命中
       * ⇒ 两条普通 URL 被归成「源站限流」，归因彻底错。
       */
      for (final raw in <String>[
        'https://cdn.example.com/videos/202503/20/x.m3u8',
        'https://cdn.example.com/a/503/x.m3u8',
        'https://cdn.example.com/2024/504/play.m3u8',
      ]) {
        expect(k(raw), isNot(PlaybackFailureKind.network),
            reason: '★ URL 里的数字不是状态码: $raw');
      }
    });

    test('「视频时长 403 秒」不许归成 permission', () {
      expect(k('视频时长 403 秒'), isNot(PlaybackFailureKind.permission),
          reason: '★ 时长不是状态码');
    });
  });

  group('④ 数字判据优先于中文关键词（顺序有定义）', () {
    test('一条消息同时有「地区」和 503 ⇒ 按 503 归 network', () {
      /*
       * 判据顺序：**协议事实 > 人话关键词**。
       * 503 说明服务端当下不可用；「地区」是上游页面里的一句话，
       * 但真正决定这次失败性质的是 503。
       */
      final f = PlaybackErrorText.classify(
        'HTTP 503 Service Unavailable（页面提到地区限制）',
        hadCandidates: true,
      );
      expect(f.kind, PlaybackFailureKind.network,
          reason: '★ 状态码优先 —— 否则「页面里提到地区」会盖掉真实故障类型');
    });

    test('没有状态码时关键词仍然生效（不许因为加了数字判据就废掉老路径）', () {
      expect(k('该内容需要大会员'), PlaybackFailureKind.permission);
      expect(k('请求超时'), PlaybackFailureKind.network);
      expect(k('Could not open codec.'), PlaybackFailureKind.decode);
    });
  });

  group('⑤ 用户可见文案纪律（Owner 第 6/7 条）', () {
    test('E 类正文不许残留 HTML 标签堆成标题的样子', () {
      const raw = '<h1>403 Forbidden</h1><p>The region has been denied.</p>';
      final f = PlaybackErrorText.classify(raw, hadCandidates: true);
      // 标题必须是归类出来的人话，不是原文
      expect(f.headline.contains('<'), isFalse, reason: '标题不许带 HTML');
      expect(f.headline.contains('Forbidden'), isFalse, reason: '标题不许是英文原文');
    });

    test('任何类别的 headline 都不许出现内部地址', () {
      for (final input in <String>[
        'HTTP 403',
        'HTTP 503',
        'Failed to open http://127.0.0.1:1234/s/x/',
        '取流失败: error sending request for url (x)',
        '该内容没有可播放的地址',
        'Could not open codec.',
      ]) {
        final f = PlaybackErrorText.classify(input);
        expect(f.headline.contains('127.0.0.1'), isFalse, reason: input);
        expect(f.headline.contains('SourinCoreException'), isFalse,
            reason: input);
        expect(f.headline.contains('插件报错'), isFalse, reason: input);
      }
    });
  });
}
