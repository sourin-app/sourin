// ═══════════════════════════════════════════════════════════════════════
//  第 65 轮 · 第 8 条门禁：D 类（插件解析错）宿主必须**补校验**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// > 现在有部分视频无法播放，请修复
//
// 第 8 条要求：D 类（插件给的 url 本身不可播）由**插件修 + 宿主补校验**。
// 本文件测的就是"宿主补校验"这一半。
//
// # 每条夹具都来自**实测读数**（.probe/round65-c/samples_run4.log）
//
// ```text
// 实测见过的坏形态：
//   ① 插件给的是播放页 /play/<id>，自己拼了 /index.m3u8
//      ⇒ https://v.gsuus.com/play/dBBBRBxd/index.m3u8
//   ② 空 url / 只有空白
//   ③ 非 http(s)
// ```
//
// # 为什么这组断言不会假绿
//
// ```text
// 每条都同时钉「坏的一定被摘」**和**「好的必须留下」：
//   只断言前者 ⇒ 一个"全都摘掉"的实现也能全绿（那是灾难）
//   只断言后者 ⇒ 校验没接上也能全绿
// ```
// 撤销验证：把 `prepare` 里那段摘除循环删掉 ⇒ ①②③④ 全红。

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/stream_prepare.dart';

/// 造一条候选（只填本组要用的字段）
StreamCandidate cand(String url, {String label = '', bool needsHost = false}) =>
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

  group('D 类：插件给的地址本身不可用 ⇒ 宿主摘掉（不许交给播放器）', () {
    test('① 实测形态：播放页 + 插件自己拼的 /index.m3u8 ⇒ 摘掉', () async {
      // ★ 这条是 .probe 里真实出现过的 url
      const raw = 'https://v.gsuus.com/play/dBBBRBxd/index.m3u8';
      final out = await StreamPreparer.prepare([cand(raw)]);

      expect(out, isEmpty,
          reason: '★ 实测的坏地址必须被摘掉 —— 否则用户看到的是'
              '「Failed to open <代理地址>」，而真因是插件给错了');
      expect(StreamPreparer.lastDroppedCount, 1,
          reason: '★ 计数必须涨 —— 它恒为 0 就说明校验没接上（written≠wired）');
      expect(StreamPreparer.lastDroppedReasons.single.contains('播放页'), isTrue,
          reason: '★ 要记下**为什么**摘（排查时才不用重新猜）: '
              '${StreamPreparer.lastDroppedReasons}');
    });

    test('② 空 / 空白地址 ⇒ 摘掉', () async {
      for (final raw in <String>['', '   ', '\n\t ']) {
        StreamPreparer.debugReset();
        final out = await StreamPreparer.prepare([cand(raw)]);
        expect(out, isEmpty, reason: '空地址必须摘掉: ${raw.runes.toList()}');
        expect(StreamPreparer.lastDroppedCount, 1, reason: '计数要涨');
      }
    });

    test('③ 非 http(s) 地址 ⇒ 摘掉', () async {
      for (final raw in <String>[
        'blob:https://x/abc',
        'file:///C:/a.mp4',
        'data:video/mp4;base64,AAAA',
        'ftp://x/a.mp4',
      ]) {
        StreamPreparer.debugReset();
        final out = await StreamPreparer.prepare([cand(raw)]);
        expect(out, isEmpty, reason: '播放器取不了这种地址: $raw');
        expect(StreamPreparer.lastDroppedCount, 1, reason: '$raw 计数要涨');
      }
    });

    test('④ 没有主机名 ⇒ 摘掉', () async {
      StreamPreparer.debugReset();
      final out = await StreamPreparer.prepare([cand('https:///a.mp4')]);
      expect(out, isEmpty, reason: 'https:// 后面没有 host 的地址取不了');
    });
  });

  group('★ 不许错杀：正常地址必须原样留下', () {
    test('① 正常 m3u8 / mp4 / mpd 全都要留下', () async {
      final good = <String>[
        'https://cdn.example.com/a/index.m3u8',
        'https://cdn.example.com/b.mp4',
        'https://cdn.example.com/c/manifest.mpd',
        'http://1.2.3.4:9981/x/y.m3u8?token=abc',
        'https://cdn.example.com/d.flv',
      ];
      StreamPreparer.debugReset();
      final out = await StreamPreparer.prepare([for (final u in good) cand(u)]);
      expect(out.length, good.length,
          reason: '★ 一条都不许摘 —— 错杀一条能播的线路比漏放一条代价大得多');
      expect(StreamPreparer.lastDroppedCount, 0, reason: '没有该摘的');
    });

    test('② 带查询串的 m3u8 不许被误判', () async {
      // ⚠️ 常见形态：路径不以 .m3u8 结尾，而是 .m3u8?xxx
      const raw = 'https://cdn.example.com/live/play.m3u8?sign=1&t=2';
      StreamPreparer.debugReset();
      final out = await StreamPreparer.prepare([cand(raw)]);
      expect(out.length, 1, reason: '查询串不影响可用性');
      expect(StreamPreparer.lastDroppedCount, 0);
    });

    test('③ 路径里恰好有 /video/ 但确实是媒体文件 ⇒ 不许摘', () async {
      // ⚠️ 判据 ⑤ 只拦「页面且没有媒体扩展」，这条有 .mp4 后缀 ⇒ 必须放行
      const raw = 'https://cdn.example.com/video/abc/def.mp4';
      StreamPreparer.debugReset();
      final out = await StreamPreparer.prepare([cand(raw)]);
      expect(out.length, 1,
          reason: '★ 有媒体扩展 ⇒ 不是"拼出来的"，必须放行');
    });
  });

  group('混合场景：坏的被摘、好的留下（这才是真实候选列表）', () {
    test('① 三条候选里一条坏 ⇒ 只剩两条', () async {
      StreamPreparer.debugReset();
      final out = await StreamPreparer.prepare([
        cand('https://v.gsuus.com/play/dBBBRBxd/index.m3u8', label: '坏'),
        cand('https://cdn.example.com/ok1/index.m3u8', label: '好1'),
        cand('https://cdn.example.com/ok2.mp4', label: '好2'),
      ]);
      expect(out.length, 2, reason: '只摘坏的那一条');
      expect(out.map((e) => e.url).toList(),
          containsAll(<String>['https://cdn.example.com/ok1/index.m3u8',
                               'https://cdn.example.com/ok2.mp4']),
          reason: '好的那两条必须原样在');
      expect(StreamPreparer.lastDroppedCount, 1);
      expect(StreamPreparer.lastDroppedReasons.single.contains('坏'), isTrue,
          reason: '理由里要能认出是哪条线路: '
              '${StreamPreparer.lastDroppedReasons}');
    });

    test('② 全坏 ⇒ 返回空（上层会说"这个源没有返回可播放地址"）', () async {
      StreamPreparer.debugReset();
      final out = await StreamPreparer.prepare([
        cand(''),
        cand('blob:x'),
        cand('https://v.gsuus.com/play/abc/index.m3u8'),
      ]);
      expect(out, isEmpty, reason: '全坏就是没有可播地址');
      expect(StreamPreparer.lastDroppedCount, 3, reason: '三条都要记上');
    });

    test('③ 坏地址与 needsHostResolve / 页面形态候选共存（N1 三态改判）', () async {
      // ★ N1（2026-11-01，lead 批复②）：`/play/xyz` 纯页面从「摘」改「留+标」——
      //   appget 类页面保留后有实测可播路径（gsuus 实证：页壳内嵌 vid m3u8，
      //   200 + 合法 #EXTM3U + 真 .ts 分段；起播预检可刮出换直链），故改为留+标。
      //   证红：把 StreamPreparer.debugShortCircuitPageKeep 置真（规则⑤退回「摘」）
      //   ⇒ 本条与 t20261101_n1_three_state_prepare_test.dart 必须变红。
      StreamPreparer.debugReset();
      final out = await StreamPreparer.prepare([
        cand('', needsHost: false),                                   // 坏
        cand('https://page.example/play/xyz', needsHost: true),        // 页面形态 ⇒ 留+标
        cand('https://cdn.example.com/ok.m3u8', needsHost: false),     // 好
      ]);
      // 坏的被摘；页面形态的保留（三态标注与 needsHostResolve 各管各的）；
      // 直链留下
      expect(StreamPreparer.lastDroppedCount, 1,
          reason: '★ 只有空地址要摘 —— 页面形态改留+标，不再计入摘除');
      expect(StreamPreparer.lastKeptNeedsResolveCount, 1,
          reason: '★ 页面候选进「留+标」计数（留痕语义与新三态对齐）');
      expect(out.length, 2, reason: '页面候选保留后还剩两条');
      expect(out.map((e) => e.url).toList(),
          containsAll(<String>['https://page.example/play/xyz',
                               'https://cdn.example.com/ok.m3u8']),
          reason: '★ 页面候选的 url 逐字不变 —— 换直链是起播预检的活');
      final page = out.firstWhere((e) => e.url == 'https://page.example/play/xyz');
      expect(page.label, '需解析',
          reason: '★ 页面候选标「需解析」—— 用户看得见，点开走预检');
      expect(page.needsHostResolve, isTrue,
          reason: '★ 三态标注不许动 needsHostResolve（t33 契约各管各的）');
      expect(page.isPlayable, isFalse,
          reason: 'needsHostResolve=true 的仍不可播（原契约不变）');
      final good = out.firstWhere((e) => e.url == 'https://cdn.example.com/ok.m3u8');
      expect(good.label, '', reason: '直链条目逐字原样（夹具默认空串 label）');
    });
  });

  group('计数与理由必须真的被写（written == wired）', () {
    test('① 每轮 prepare 都重置计数（不许跨轮累积）', () async {
      StreamPreparer.debugReset();
      await StreamPreparer.prepare([cand('')]);
      expect(StreamPreparer.lastDroppedCount, 1);

      await StreamPreparer.prepare([cand('https://cdn.example.com/a.m3u8')]);
      expect(StreamPreparer.lastDroppedCount, 0,
          reason: '★ 这一轮没有坏的 ⇒ 计数必须归零（累积会让人误判）');
    });

    test('② 理由列表是只读的（外部改不动，防止互相污染）', () async {
      StreamPreparer.debugReset();
      await StreamPreparer.prepare([cand('')]);
      expect(
        () => StreamPreparer.lastDroppedReasons.add('我硬塞的'),
        throwsUnsupportedError,
        reason: '★ 只读视图 —— 否则任何调用方都能篡改证据',
      );
    });
  });
}
