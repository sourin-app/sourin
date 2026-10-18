// ═══════════════════════════════════════════════════════════════════════
//  task-33：needsHostResolve 契约 —— **含消费点**的验证
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这组测试的重点不是「字段能不能存」
// ```text
// 本仓反复吃亏的缺陷类型是：**声明了不生效**（等于骗人）。
// theme_pack 的 buttonPadding 就是全仓零消费、注释里记着这件事。
// ⇒ 所以这里断言的不是「字段存在」，而是「它真的改变了行为」。
// ```
//
// # 关键的一条：消费点必须真的被调用
// 最后一组用**源码断言**把 SourinApi 的两个出口钉住 ——
// 有人把 StreamPreparer.prepare 那行删了，测试就红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../lib/core/models.dart';
import '../lib/core/stream_prepare.dart';

void main() {
  setUp(StreamPreparer.debugReset);
  tearDown(StreamPreparer.debugReset);

  group('① 契约字段的默认值（老插件行为必须逐字不变）', () {
    test('不传新字段 ⇒ needsHostResolve=false / siteId=null / flags 空', () {
      const c = StreamCandidate(url: 'https://x/a.m3u8');
      expect(c.needsHostResolve, isFalse);
      expect(c.siteId, isNull);
      expect(c.streamFlags.isEmpty, isTrue);
      expect(c.isPlayable, isTrue, reason: '老插件的候选必须照样可播');
    });

    test('fromJson 缺失新键 ⇒ 全部取默认（向后兼容）', () {
      final c = StreamCandidate.fromJson(const {'url': 'https://x/a.m3u8'});
      expect(c.needsHostResolve, isFalse);
      expect(c.siteId, isNull);
      expect(c.streamFlags.isEmpty, isTrue);
    });

    test('fromJson 能读 snake_case 新键', () {
      final c = StreamCandidate.fromJson(const {
        'url': 'https://s1/watch/123',
        'needs_host_resolve': true,
        'site_id': 'S1',
        'stream_flags': {'drm': true, 'hdr': false, 'codec': 'hevc'},
      });
      expect(c.needsHostResolve, isTrue);
      expect(c.siteId, 'S1');
      expect(c.streamFlags.drm, isTrue);
      expect(c.streamFlags.codec, 'hevc');
    });
  });

  group('② ★ needsHostResolve 必须让 isPlayable 变 false', () {
    test('未解析的播放页 URL 不可播', () {
      const c = StreamCandidate(
        url: 'https://s1/watch/123',
        needsHostResolve: true,
      );
      expect(c.isPlayable, isFalse,
          reason: '否则播放页 URL 会被当可播地址交给 mpv ⇒ 静默黑屏');
    });

    test('★ 不许把「未解析」说成 DRM', () {
      const c = StreamCandidate(
        url: 'https://s1/watch/123',
        needsHostResolve: true,
      );
      expect(c.drmProtected, isFalse,
          reason: '未解析 ≠ 受版权保护。混用会让 UI 对用户说假话');
    });

    test('解析完成后（needsHostResolve=false + 有地址）可播', () {
      const c = StreamCandidate(
        url: 'https://cdn/x.m3u8',
        needsHostResolve: false,
      );
      expect(c.isPlayable, isTrue);
    });
  });

  group('③ StreamPreparer 的编排行为', () {
    test('列表里没有 needsHostResolve ⇒ 原样返回（零副作用）', () async {
      final list = <StreamCandidate>[
        const StreamCandidate(url: 'https://a/1.m3u8'),
        const StreamCandidate(url: 'https://a/2.mp4'),
      ];
      final out = await StreamPreparer.prepare(list);
      expect(out, same(list), reason: '没有要解析的就不该复制/改动');
      expect(StreamPreparer.lastNeedsResolveCount, 0);
    });

    test('★ 没有解析器时：该条不可播，但**不冒充 DRM**', () async {
      final list = <StreamCandidate>[
        const StreamCandidate(url: 'https://s1/watch/1', needsHostResolve: true),
        const StreamCandidate(url: 'https://ok/x.m3u8'),
      ];
      final out = await StreamPreparer.prepare(list);

      expect(StreamPreparer.lastNeedsResolveCount, 1);
      expect(out[0].isPlayable, isFalse, reason: '解不出来就必须不可播');
      expect(out[0].drmProtected, isFalse,
          reason: '★ 不许把「宿主没实现解析」说成「受版权保护」');
      expect(out[1].isPlayable, isTrue, reason: '另一条传统线路不受影响');
    });

    test('★ 注入解析器后：url 被替换、标志位被清', () async {
      StreamPreparer.resolver = (url, {siteId}) async {
        expect(url, 'https://s1/watch/1');
        expect(siteId, 'S1');
        return 'https://cdn/real.m3u8';
      };
      final out = await StreamPreparer.prepare([
        const StreamCandidate(
          url: 'https://s1/watch/1',
          needsHostResolve: true,
          siteId: 'S1',
        ),
      ]);

      expect(out[0].url, 'https://cdn/real.m3u8');
      expect(out[0].needsHostResolve, isFalse);
      expect(out[0].isPlayable, isTrue);
      expect(out[0].siteId, 'S1', reason: '解析后站点标识仍要保留（排查用）');
    });

    test('解析器返回 null ⇒ 该条不可播（不抛异常，不影响别的条）', () async {
      StreamPreparer.resolver = (url, {siteId}) async => null;
      final out = await StreamPreparer.prepare([
        const StreamCandidate(url: 'https://s1/watch/1', needsHostResolve: true),
        const StreamCandidate(url: 'https://ok/x.m3u8'),
      ]);
      expect(out[0].isPlayable, isFalse);
      expect(out[1].isPlayable, isTrue);
    });

    test('解析器抛异常 ⇒ 同样只废掉那一条（一条失败不该让整页报错）', () async {
      StreamPreparer.resolver = (url, {siteId}) async => throw StateError('boom');
      final out = await StreamPreparer.prepare([
        const StreamCandidate(url: 'https://s1/watch/1', needsHostResolve: true),
        const StreamCandidate(url: 'https://ok/x.m3u8'),
      ]);
      expect(out[0].isPlayable, isFalse);
      expect(out[1].isPlayable, isTrue);
      expect(out[0].drmProtected, isFalse, reason: '异常 ≠ DRM');
    });
  });

  group('④ ★★ 消费点必须真的挂在两个出口上（源码断言）', () {
    late String api;
    setUpAll(() => api = File('lib/core/sourin_api.dart').readAsStringSync());

    test('resolveStream（点播）必须调 StreamPreparer.prepare', () {
      final i = api.indexOf('static Future<List<StreamCandidate>> resolveStream(');
      expect(i, greaterThan(0));
      final body = api.substring(i, (i + 2500).clamp(0, api.length));
      expect(body.contains('StreamPreparer.prepare'), isTrue,
          reason: '★ 声明了不生效等于骗人 —— 这个字段必须有消费者。'
              '删掉这一行 ⇒ needsHostResolve 变死字段 ⇒ 本项目就是没这能力。');
    });

    test('getLiveStream（直播）也必须调 StreamPreparer.prepare', () {
      final i = api.indexOf('static Future<List<StreamCandidate>> getLiveStream(');
      expect(i, greaterThan(0));
      final body = api.substring(i, (i + 4000).clamp(0, api.length));
      expect(body.contains('StreamPreparer.prepare'), isTrue,
          reason: '点播/直播是两条独立代码路径，只挂一条会留下另一边静默黑屏');
    });

    test('★ 直播必须在**写缓存之前**预处理', () {
      final i = api.indexOf('static Future<List<StreamCandidate>> getLiveStream(');
      final body = api.substring(i, (i + 4000).clamp(0, api.length));
      final prep = body.indexOf('StreamPreparer.prepare');
      final cacheWrite = body.indexOf('_liveStreamCache[key] =');
      expect(prep, greaterThan(0));
      expect(cacheWrite, greaterThan(0));
      expect(prep, lessThan(cacheWrite),
          reason: '★ 若先写缓存再预处理，缓存里存的是「没解的播放页 URL」，'
              '30s 内再切台会拿到它并当成可播地址 ⇒ 黑屏');
    });
  });
}
