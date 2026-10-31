// ═══════════════════════════════════════════════════════════════════════
//  T6 webHome：注入 SDK（document-start）—— window.fm 六方法白名单 + console 劫持
// ═══════════════════════════════════════════════════════════════════════
//
// # 对标（T2 ⑥）：参考的 `window.fm` 全家桶，这里只开 V1 白名单六方法
// （白名单的**执行点**在 fm_bridge.dart 的 dispatch，这里只是它们的
// 页面侧门面 —— 两处必须同改）。
//
// # 为什么用 UserScript 注入而不是 HTML 里 <script>
// document-start 注入保证页面自己的脚本执行时 window.fm 已就绪
// （参考实现同款语义，探针 T1 已实测）。
//
// ⚠️ 本文件是**将要被注入页面的 JS 字符串**：Dart 侧不解析它，
// 它的正确性由门禁（t20261031_webhome_pure_gate_test.dart 的
// 「SDK 方法面与白名单一致」静态断言）与实机探针共同兜底。
const String kFmSdkJs = r'''
(function () {
  'use strict';
  if (window.fm) return;

  function call(method, payload) {
    return window.flutter_inappwebview.callHandler('fm', method, payload);
  }

  window.fm = {
    /** 点内容卡片 → 详情页（多集/多源都在详情，不直接开播放器） */
    player: {
      playVod: function (p) { return call('player.playVod', p || {}); }
    },
    /** 点直播频道 → 直接进播放器 */
    app: {
      openLive: function (p) { return call('app.openLive', p || {}); }
    },
    /** 宿主代发 HTTP（免 CORS；SSRF 白名单在宿主侧强制执行） */
    net: {
      request: function (opts) { return call('net.request', opts || {}); }
    },
    /** 宿主侧持久化缓存（配额 5MB，超限写不进） */
    cache: {
      get: function (k) { return call('cache.get', { key: String(k) }); },
      set: function (k, v) { return call('cache.set', { key: String(k), value: String(v) }); },
      del: function (k) { return call('cache.del', { key: String(k) }); }
    },
    /** 日志与提示（宿主侧落 AppLog，自动脱敏） */
    log: {
      write: function (level, msg) { return call('log.write', { level: String(level), msg: String(msg) }); }
    },
    ui: {
      toast: function (msg) { return call('ui.toast', { msg: String(msg) }); },
      /** 视口在页面内直接可取，不过桥 */
      getViewport: function () {
        return Promise.resolve({ w: window.innerWidth, h: window.innerHeight });
      }
    },
    /** 返回：WebView 有历史则页内后退，否则回原生首页（宿主处理） */
    navigation: {
      back: function () { return call('navigation.back', {}); }
    }
  };

  // ── console 五级劫持（保留原实现；宿主落 AppLog）──
  var levels = ['log', 'info', 'warn', 'error', 'debug'];
  var originals = {};
  levels.forEach(function (lv) {
    originals[lv] = console[lv] ? console[lv].bind(console) : function () {};
    console[lv] = function () {
      var parts = [];
      for (var i = 0; i < arguments.length; i++) {
        var x = arguments[i];
        try { parts.push(typeof x === 'string' ? x : JSON.stringify(x)); }
        catch (e) { parts.push(String(x)); }
      }
      try { call('log.write', { level: lv, msg: parts.join(' ') }); } catch (e2) {}
      originals[lv].apply(console, arguments);
    };
  });

  // navigation.back 的语义在页面内判断不了历史与"是否该退出 HTML 首页"，
  // 交宿主：webview 有历史 → goBack，否则回调 onBackToNative。
})();
''';
