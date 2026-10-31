// ═══════════════════════════════════════════════════════════════════════
//  T6 webHome 纯函数门禁（untagged：不碰 MediaKit，全量必跑）
// ═══════════════════════════════════════════════════════════════════════
//
// # 防的是什么
// webHome 给页面一个**免 CORS 的 HTTP 客户端**（net.request 宿主代发），
// SSRF 判据一旦被"顺手删掉/放宽"，内网就对任意 HTML 敞开了。
// 这里把判据钉死成门禁；每组判据都配**阳性+阴性**（证红口径）。
//
// # 证红记录（2026-10-31）
// - SSRF：临时把 _ipAllowed 放开为恒真 ⇒ 本文件 ④⑤ 组红（已复绿）；
// - 白名单：临时在 dispatch 的 default 分支放行 ⇒ ⑥ 组红（已复绿）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/webhome/fm_bridge.dart';
import 'package:sourin_spike/ui/webhome/fm_sdk_js.dart';
import 'package:sourin_spike/ui/webhome/webhome_page.dart';
import 'package:sourin_spike/ui/webhome/webhome_store.dart';

Uri _u(String s) => Uri.parse(s);

void main() {
  group('T6-WH-① net.request 字面量判据：scheme', () {
    test('http/https 放行', () {
      expect(isNetRequestTargetAllowed(_u('https://api.example.com/vod')), isTrue);
      expect(isNetRequestTargetAllowed(_u('http://api.example.com/vod')), isTrue);
    });
    test('file/data/javascript/空 scheme 一律拒', () {
      expect(isNetRequestTargetAllowed(_u('file:///etc/passwd')), isFalse);
      expect(isNetRequestTargetAllowed(_u('data:text/html,x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('javascript:alert(1)')), isFalse);
      expect(isNetRequestTargetAllowed(_u('//api.example.com/x')), isFalse);
    });
  });

  group('T6-WH-② net.request 字面量判据：主机名', () {
    test('localhost 族拒，普通域名放行', () {
      expect(isNetRequestTargetAllowed(_u('http://localhost/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://a.localhost/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://nas.local/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://db.internal/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('https://cdn.example.com/a.jpg')), isTrue);
    });
    test('空 host 拒', () {
      expect(isNetRequestTargetAllowed(_u('https:///path-only')), isFalse);
    });
  });

  group('T6-WH-③ net.request 字面量判据：IP 字面量', () {
    test('公网 IP 放行', () {
      expect(isNetRequestTargetAllowed(_u('https://8.8.8.8/dns-query')), isTrue);
      expect(isNetRequestTargetAllowed(_u('https://1.1.1.1/x')), isTrue);
    });
    test('回环/内网/链路本地/CGNAT/未指定全拒', () {
      expect(isNetRequestTargetAllowed(_u('http://127.0.0.1:9978/api')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://127.3.4.5/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://10.0.0.1/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://172.16.0.1/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://172.31.255.255/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://192.168.1.1/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://169.254.1.1/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://100.64.0.1/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://0.0.0.0/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://[::1]/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://[::ffff:127.0.0.1]/x')), isFalse);
      expect(isNetRequestTargetAllowed(_u('http://[fd00::1]/x')), isFalse);
    });
    test('★ P2-3 互检补钉：三种伪装形态（互检前是"意外 fail-closed"，无门禁）', () {
      // hex 形态的 IPv4-mapped：'::ffff:7f00:1' ≡ '::ffff:127.0.0.1'，
      // 判据必须按**字节**归一（字符串 startsWith 只兜一种写法）
      expect(isNetRequestTargetAllowed(_u('http://[::ffff:7f00:1]/x')), isFalse,
          reason: 'hex-mapped IPv6 回环必须拒');
      // 十进制整型主机：浏览器按 IPv4 展开，2130706433 = 127.0.0.1
      expect(isNetRequestTargetAllowed(_u('http://2130706433/x')), isFalse,
          reason: '十进制整型回环必须拒');
      // 尾点：DNS 语义上 127.0.0.1. == 127.0.0.1.
      expect(isNetRequestTargetAllowed(_u('http://127.0.0.1./x')), isFalse,
          reason: '尾点回环必须拒');
      expect(isNetRequestTargetAllowed(_u('http://localhost./x')), isFalse,
          reason: '尾点 localhost 必须拒');
    });
    test('★ P2-3 阳性对照：伪装形态里的公网地址要放行（防门禁一刀切）', () {
      // 134744072 = 8.8.8.8（十进制整型公网）
      expect(isNetRequestTargetAllowed(_u('http://134744072/dns-query')), isTrue);
      // 公网域名带尾点（DNS 语义合法）
      expect(isNetRequestTargetAllowed(_u('https://example.com./x')), isTrue);
      // hex 公网 mapped：'::ffff:808:808' = 8.8.8.8
      expect(isNetRequestTargetAllowed(_u('http://[::ffff:808:808]/x')), isTrue);
    });
    test('172 段边界：172.15/172.32 是公网', () {
      expect(isNetRequestTargetAllowed(_u('http://172.15.0.1/x')), isTrue);
      expect(isNetRequestTargetAllowed(_u('http://172.32.0.1/x')), isTrue);
    });
  });

  group('T6-WH-④ 解析段判据（★ 收窄 TOCTOU 窗口 —— 未闭合 rebinding，P2-1 措辞纪律）', () {
    test(' evil.com 解析出内网 IP ⇒ 拒', () {
      expect(
        isNetRequestTargetAllowed(
          _u('https://evil.com/api'),
          resolvedIps: ['93.184.216.34', '192.168.1.10'],
        ),
        isFalse,
      );
      expect(
        isNetRequestTargetAllowed(
          _u('https://evil.com/api'),
          resolvedIps: ['127.0.0.1'],
        ),
        isFalse,
      );
    });
    test('全公网解析 ⇒ 放行', () {
      expect(
        isNetRequestTargetAllowed(
          _u('https://evil.com/api'),
          resolvedIps: ['93.184.216.34', '2606:2800:220:1:248:1893:25c8:1946'],
        ),
        isTrue,
      );
    });
  });

  group('T6-WH-⑤ 桥分发白名单', () {
    test('白名单内方法可达', () async {
      var played = <String>[];
      final bridge = FmBridge(
        onPlayVod: (p, id) => played.add('$p/$id'),
        onOpenLive: (_, __, ___) {},
        onNetRequest: (_) async => {'status': 200, 'body': ''},
        onCacheGet: (_) async => null,
        onCacheSet: (_, __) async => true,
        onCacheDelete: (_) async {},
        onLog: (_, __) {},
        onToast: (_) {},
      );
      final r = await bridge.dispatch(
          fmMethodPlayVod, {'provider': 'srcl', 'id': 'v123'});
      expect(r, containsPair('ok', true));
      expect(played, ['srcl/v123']);
    });
    test('白名单外一律 unknown-method（页面伪造 FFI 方法名）', () async {
      final bridge = FmBridge(
        onPlayVod: (_, __) {},
        onOpenLive: (_, __, ___) {},
        onNetRequest: (_) async => {},
        onCacheGet: (_) async => null,
        onCacheSet: (_, __) async => true,
        onCacheDelete: (_) async {},
        onLog: (_, __) {},
        onToast: (_) {},
      );
      // ★ 试着通过桥够 FFI/文件系统能力 —— 必须被拒
      for (final m in ['ffi.invoke', 'fs.read', 'eval', 'player.playUrl',
        'pan.check', 'net.resourceUrl', 'app.search', 'ext.info']) {
        final r = await bridge.dispatch(m, {'url': 'http://127.0.0.1/x'});
        expect(r, containsPair('error', 'unknown-method'),
            reason: '方法 $m 不该在白名单里');
      }
    });
    test('playVod 参数不齐拒（不抛异常出桥）', () async {
      final bridge = FmBridge(
        onPlayVod: (_, __) {},
        onOpenLive: (_, __, ___) {},
        onNetRequest: (_) async => {},
        onCacheGet: (_) async => null,
        onCacheSet: (_, __) async => true,
        onCacheDelete: (_) async {},
        onLog: (_, __) {},
        onToast: (_) {},
      );
      final r = await bridge.dispatch(fmMethodPlayVod, {'provider': 'srcl'});
      expect(r, containsPair('error', 'bad-args'));
    });
    test('net.request 字面量拒时走 rejected 分支（不发起请求）', () async {
      var requested = 0;
      final logs = <String>[];
      final bridge = FmBridge(
        onPlayVod: (_, __) {},
        onOpenLive: (_, __, ___) {},
        onNetRequest: (_) async {
          requested++;
          return {'status': 200};
        },
        onCacheGet: (_) async => null,
        onCacheSet: (_, __) async => true,
        onCacheDelete: (_) async {},
        onLog: (_, msg) => logs.add(msg),
        onToast: (_) {},
      );
      final r = await bridge.dispatch(
          fmMethodNetRequest, {'url': 'http://127.0.0.1:5266/admin'});
      expect(requested, 0, reason: '被拒目标绝不能到 onNetRequest');
      expect(r, containsPair('error', 'target-not-allowed'));
      expect(logs, isNotEmpty, reason: '拒绝必须落日志（静默失败=缺陷）');
    });
  });

  group('T6-WH-⑥ cache 配额', () {
    test('配额内放行、超限拒绝、同 key 覆盖不算新增', () {
      const q = webhomeCacheQuotaBytes;
      expect(cacheWriteAllowed(0, 1024, q), isTrue);
      expect(cacheWriteAllowed(q - 100, 200, q), isFalse);
      // 边界：正好装满
      expect(cacheWriteAllowed(q - 100, 100, q), isTrue);
    });
    test('WebHomeCache.set 同 key 覆盖后仍受配额约束（集成）', () async {
      final dir = await Directory.systemTemp.createTemp('t6wh');
      addTearDown(() => dir.delete(recursive: true));
      WebHomeCache.debugSetFile(
          '${dir.path}${Platform.pathSeparator}cache.json');
      WebHomeController.debugSetDataDir(dir.path);
      addTearDown(() {
        WebHomeCache.debugSetFile(null);
        WebHomeController.debugSetDataDir(null);
      });
      final cache = WebHomeCache.instance;
      final big = 'x' * (webhomeCacheQuotaBytes ~/ 2 + 100);
      expect(await cache.set('a', big), isTrue);
      expect(await cache.set('b', big), isFalse, reason: '超 5MB 配额');
      expect(await cache.set('a', '${big}more'), isTrue,
          reason: '同 key 覆盖只按增量算');
      expect(await cache.get('a'), '${big}more');
    });
  });

  group('T6-WH-⑦ HTML 受理判据', () {
    test('空/超限拒，普通 HTML 放行', () {
      expect(webhomeHtmlAcceptable('   '), isFalse);
      expect(webhomeHtmlAcceptable('<h1>hello</h1>'), isTrue);
      expect(
          webhomeHtmlAcceptable('x' * (webhomeHtmlMaxBytes + 1)), isFalse);
      expect(
          webhomeHtmlAcceptable('x' * webhomeHtmlMaxBytes), isTrue);
    });
  });

  group('T6-WH-⑧ 控制器判据收口', () {
    test('showWebHome = 启用 && 未回退 && HTML 非空（三与门）', () {
      final c = WebHomeController.instance;
      final oldFallback = c.fallbackThisSession;
      addTearDown(() => c.fallbackThisSession = oldFallback);
      c.fallbackThisSession = false;
      // 默认未启用 ⇒ false（不依赖磁盘状态）
      if (!c.enabled) {
        expect(c.showWebHome, isFalse);
      }
      // 回退位一挂，即便启用也不显示
      // （直接操纵内部位：控制器的持久化方法要走 IO，这里只测判据本身）
      // eslint 风格说明：enabled 置位通过私有字段做不到 ⇒ 用回退位单侧验证。
      c.fallbackThisSession = true;
      // 不管 enabled 与 html，回退位独立否决：
      // 若 enabled=false 本就 false；若真启用也会被回退位压住。
      expect(c.showWebHome, isFalse);
      c.fallbackThisSession = false;
    });
  });

  group('T6-WH-⑨ SDK 方法面与白名单一致（静态）', () {
    test('kFmSdkJs 里每个 call(...) 的方法都在白名单内', () {
      final calls = RegExp(r"call\('([^']+)'").allMatches(kFmSdkJs);
      expect(calls, isNotEmpty, reason: 'SDK 必须真的在调桥');
      const whitelist = {
        fmMethodPlayVod,
        fmMethodOpenLive,
        fmMethodNetRequest,
        fmMethodCacheGet,
        fmMethodCacheSet,
        fmMethodCacheDel,
        fmMethodLogWrite,
        fmMethodToast,
        fmMethodBack, // navigation.back（页面内消化，但允许经桥）
      };
      for (final m in calls) {
        expect(whitelist, contains(m.group(1)),
            reason: 'SDK 调了 ${m.group(1)}，白名单没有 —— 两处必须同改');
      }
    });
    test('SDK 劫持了 console 五级', () {
      for (final lv in ['log', 'info', 'warn', 'error', 'debug']) {
        expect(kFmSdkJs, contains("'$lv'"), reason: 'console.$lv 未劫持');
      }
    });
  });

  group('T6-WH-⑩ 接线编译覆盖（不建 webview，只证符号可编译可达）', () {
    test('home_page / webhome_page 符号存在', () {
      // import 即编译：home_page.dart 的双模式接入点与 webhome_page.dart
      // 的桥接线只要有编译错误，本测试文件就编不过 —— 这是它的全部职责。
      expect(WebHomeController.instance, isNotNull);
      expect(const WebHomePage(
        onBackToNative: _noop,
        onOpenSettings: _noop,
      ), isNotNull);
      expect(HomePage, isNotNull);
    });
  });
}

void _noop() {}
