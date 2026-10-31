// ═══════════════════════════════════════════════════════════════════════
//  非媒体预检（T4-I，2026-10-31）—— mpv 起播前的最后一道关口
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这一层（cleanenv 审计实锤，.probe/play-audit-cleanenv-2026-10-31.md）
//
// ```text
// csp-yinhai ×3 / csp-apprj ×2 / csp-appysv2 ×1：resolve 报 ok、mpv 报
// 「Failed to recognize file format」。离线复现（带头 UA+Referer / 不带头，
// 响应一致 ⇒ 不是头丢失）：
//   · alipan.com/s/…、pan.baidu.com/s/…、115cdn.com/s/… → HTTP 200 text/html
//     （网盘分享页 SPA 壳 —— yinhai 的 play() 本来就交回分享页 + 空 headers）
//   · api.nbyjson.top:7788/api/?key=…&url=… → application/json
//     （第三方解析接口信封，真流在 JSON 的 `url` 字段里 —— 实测取出的是真 m3u8）
//   · www.iqiyi.com/v_xxx.html → text/html（页面链接）
// mpv 对三类的报错一模一样，用户只会看到"格式解不了"。
// ```
//
// # 判据落在通用机制上（**不许特定域名硬编码加头/加判**）
//
// ```text
// ① 明显媒体（path 去参后以 .m3u8/.mpd/.mp4/… 结尾）⇒ 直通，零成本不碰网络；
// ② 看不出来的 ⇒ 带**候选自带头**限时 GET 一发：
//      JSON 且带 http(s) 的 `url` / `data.url` 字段（TVBox 解析接口的通用契约）
//        ⇒ 用它替换起播地址（apprj 的 parse_urls 实测就是这个形状）；
//      HTML ⇒ 刮 m3u8，刮得到 ⇒ 替换；刮不到 ⇒ 人话报错（不再"格式解不了"）；
//      视频/音频/二进制 ⇒ 原样起播（mpv 自己会解）。
//   只追一跳，不递归；网络失败/超时 ⇒ 原样起播（行为与修复前一致）。
// ③ 网盘分享页要真播需要网盘账号链路（Rust 侧 pan 模块，另案）；
//   本层对它只负责**如实人话报错**，不伪造直链。
// ```
//
// # HTTP 客户端为什么用 dart:io 的 [HttpClient]
//
// 与 lib/core/danmaku.dart 同一条纪律：pubspec.yaml 不在本批写范围内，
// lib 里也没有任何 `package:http` 的先例 —— 全仓 HTTP 都是 dart:io。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// 预检应答体最多读多少字节（信封/页面都在这个量级；绝不吞视频流）
const int kPrecheckMaxBodyBytes = 64 * 1024;

/// 预检结论
///
/// 三选一：[keep]（原样起播）/ [substitute]（换成直链起播）/ [fail]（人话报错）。
class NonMediaCheck {
  /// 非 null ⇒ 用这个地址起播（替换原候选地址）
  final String? url;

  /// 非 null ⇒ 不要起播，把这段人话给用户（与 [url] 互斥）
  final String? error;

  const NonMediaCheck.keep()
      : url = null,
        error = null;
  const NonMediaCheck.substitute(this.url) : error = null;
  const NonMediaCheck.fail(this.error)
      : url = null;

  bool get isKeep => url == null && error == null;
}

/// 测试注入点：true ⇒ 预检整体短路（一切候选原样放行）。
///
/// 门禁的「证红」开关：把它置真后，预检用例必须变红 ——
/// 证明用例真的踩在预检上，而不是恒真式。生产代码**永不**写它。
@visibleForTesting
bool debugShortCircuitNonMediaPrecheck = false;

/// URL 是不是**明显是媒体流**（去 query/fragment 后 path 的扩展名）
///
/// 宽进判据：只用来**跳过**预检（少一次 GET），不用来判"能播" ——
/// 判错的代价只是多一发限时 GET，不会错杀。
bool pathHasMediaExt(String url) {
  final path = url.split(RegExp('[?#]')).first.toLowerCase();
  const exts = [
    '.m3u8', '.mpd', '.mp4', '.mkv', '.flv',
    '.ts', '.webm', '.mov', '.m4a', '.aac', '.mp3',
  ];
  return exts.any(path.endsWith);
}

/// 解析接口信封里能当流地址的字段（TVBox 生态通用契约：顶层 `url`，或 `data.url`）
///
/// ```text
/// 实测（api.nbyjson.top:7788）：
///   {"code":200, "playVodId":76902, "ip":"…", "url":"http://…/getM3u8?…", …}
/// `url` 必须是 http(s) 才认 —— 塞 base64/空串的一律不认（不猜）。
/// ```
String? envelopeUrlOf(String body) {
  final Object? v;
  try {
    v = jsonDecode(body);
  } catch (_) {
    return null;
  }
  if (v is! Map) return null;
  String? fromMap(Object? node) {
    if (node is! Map) return null;
    final u = node['url'];
    if (u is! String) return null;
    final t = u.trim();
    return (t.startsWith('http://') || t.startsWith('https://')) ? t : null;
  }

  return fromMap(v) ?? fromMap(v['data']);
}

final RegExp _quotedM3u8 = RegExp('''["']([^"']*\\.m3u8[^"']*)["']''');

/// 从 HTML 里刮第一个 `.m3u8` 直链（引号里的字符串；相对地址用 [pageUrl] 补全）
///
/// 与 Rust 侧 `tvbox.rs::extract_m3u8` 同一条思路：页面正文里带引号的
/// `.m3u8` 串才是"页里藏着真流"的可靠形状（无引号裸串误报率高，不认）。
String? extractM3u8FromHtml(String body, {String? pageUrl}) {
  for (final m in _quotedM3u8.allMatches(body)) {
    var u = m.group(1)?.trim();
    if (u == null || u.isEmpty) continue;
    if (u.startsWith('//')) u = 'https:$u';
    if (u.startsWith('http://') || u.startsWith('https://')) return u;
    // 相对地址：`/hls/x.m3u8` ⇒ 接 pageUrl 的 scheme://host
    if (u.startsWith('/') && pageUrl != null) {
      final schemeEnd = pageUrl.indexOf('://');
      if (schemeEnd > 0) {
        final after = pageUrl.substring(schemeEnd + 3);
        final hostEnd = after.indexOf('/');
        final host = hostEnd < 0 ? after : after.substring(0, hostEnd);
        return '${pageUrl.substring(0, schemeEnd)}://$host$u';
      }
    }
  }
  return null;
}

/// 预检判据（**纯函数**，门禁直接喂应答读数，不碰网络）
///
/// [status] / [contentType] / [body] 是一次 GET 的读数；
/// [body] 仅当 Content-Type 是 json/html/text 时有值（截前 64KB），
/// 视频/二进制应答恒为 null。
NonMediaCheck decideFromFetch({
  required int status,
  required String contentType,
  String? body,
}) {
  final ctMain = contentType.split(';').first.trim();
  if (status == 200 && ctMain.contains('json')) {
    final u = body == null ? null : envelopeUrlOf(body);
    return u == null
        ? const NonMediaCheck.keep() // 是 JSON 但不是信封 ⇒ 不猜，mpv 直连（行为同旧）
        : NonMediaCheck.substitute(u);
  }
  if (ctMain.contains('html')) {
    final u = body == null ? null : extractM3u8FromHtml(body);
    if (u != null) return NonMediaCheck.substitute(u);
    // 网页/分享页：不把它塞给 mpv 假装是流（mpv 只会说"格式解不了"）
    return const NonMediaCheck.fail(
      '这条给的是网页/分享页链接（HTML），不是可播放的媒体流。'
      '网盘分享页需要登录网盘账号与转发服务才能取直链，本机没有接入，所以现在播不了。',
    );
  }
  return const NonMediaCheck.keep(); // 视频/音频/二进制 ⇒ 原样（mpv 自己会解）
}

/// 对一条候选流跑非媒体预检（`_startPlayback` 在 `_player.open` 之前调用）
///
/// # 行为契约
/// ```text
/// · 明显媒体（pathHasMediaExt）⇒ 直接 keep，不发网络；
/// · 非 http(s)（file:// 等）⇒ keep，本层不管本地形态；
/// · 需要取数时带 [headers]（候选自带头）限时 GET 一发，只读文本类前 64KB；
/// · 网络/超时失败 ⇒ keep（行为与修复前一致，绝不因预检挂掉而拦播放）；
/// · [debugShortCircuitNonMediaPrecheck] 为真 ⇒ 整体短路（证红注入点）。
/// ```
Future<NonMediaCheck> precheckNonMedia(
  String url,
  Map<String, String> headers, {
  HttpClient? client,
  Duration timeout = const Duration(seconds: 3),
}) async {
  if (debugShortCircuitNonMediaPrecheck) {
    return const NonMediaCheck.keep();
  }
  final u = url.trim();
  if (!(u.startsWith('http://') || u.startsWith('https://'))) {
    return const NonMediaCheck.keep();
  }
  if (pathHasMediaExt(u)) {
    return const NonMediaCheck.keep();
  }

  HttpClient? own;
  final io = client ??
      (own = HttpClient()
        ..connectionTimeout = const Duration(seconds: 3)
        // 与全仓纪律同源：不读环境代理（代理会把「上游可读」测成「全失败」）
        ..findProxy = (_) => 'DIRECT');
  try {
    final req = await io.getUrl(Uri.parse(u)).timeout(timeout);
    headers.forEach(req.headers.set);
    final resp = await req.close().timeout(timeout);

    final ct =
        (resp.headers.value(HttpHeaders.contentTypeHeader) ?? '').toLowerCase();
    final ctMain = ct.split(';').first.trim();
    final isTextLike =
        ctMain.contains('json') || ctMain.contains('html') || ctMain.contains('text');
    // 内容长度守卫：>1MiB 的"文本"不该出现在解析信封/页面上 ⇒ 当二进制不读
    final tooBig = resp.contentLength > kPrecheckMaxBodyBytes * 16;
    String? body;
    if (isTextLike && !tooBig) {
      final sb = StringBuffer();
      var total = 0;
      final done = Completer<void>();
      late StreamSubscription<List<int>> sub;
      sub = resp.listen(
        (chunk) {
          sb.write(utf8.decode(chunk, allowMalformed: true));
          total += chunk.length;
          if (total >= kPrecheckMaxBodyBytes && !done.isCompleted) {
            unawaited(sub.cancel());
            done.complete();
          }
        },
        onDone: done.complete,
        onError: (Object e) {
          if (!done.isCompleted) done.completeError(e);
        },
      );
      await done.future.timeout(timeout);
      body = sb.toString();
    } else {
      // 视频/二进制：只看头，掐断连接（绝不吞视频流）
      try {
        await resp.listen((_) {}).cancel().timeout(timeout);
      } catch (_) {}
    }
    return decideFromFetch(status: resp.statusCode, contentType: ct, body: body);
  } catch (_) {
    return const NonMediaCheck.keep(); // 预检自己失败 ⇒ 不拦播放（行为同旧）
  } finally {
    own?.close(force: true);
  }
}
