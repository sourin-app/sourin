// =======================================================================
//  弹幕（弹弹play 外部弹幕 开放弹幕网络）—— 客户端
// =======================================================================
//
// # 这个文件解决什么
//
// 用户 2026-10-04 要求（逐字）：
// > 接入一下 弹弹play 的弹幕功能
//
// 这里实现三件事：
// ```text
// (1) 配置      DanmakuConfig    —— 开关 / AppId / AppSecret（键名已锁定，见下）
// (2) 取弹幕    ExternalDanmakuClient —— 真实 HTTP：/api/v2/match + /api/v2/comment/{id}
// (3) 渲染      lib/ui/widgets/danmaku_overlay.dart（本文件只出数据，不碰 widget）
// ```
//
// # 锁定的偏好键名（task-13 定；task-14 若做统一入口按这套接，不要改）
// ```text
// dsh.danmaku.enabled     "1" / "0"，缺省 "0"
// dsh.danmaku.appId       AppId，缺省 ""
// dsh.danmaku.appSecret   AppSecret，缺省 ""
// ```
// 本文件另外新增四个**显示参数**键（与上面三个不冲突）：
// ```text
// dsh.danmaku.fontScale   字号比例，缺省 "1.0"
// dsh.danmaku.opacity     不透明度，缺省 "1.0"
// dsh.danmaku.speed       一条弹幕穿过画面的秒数，缺省 "8.0"
// dsh.danmaku.area        ★ 弹幕显示区域占画面高度的比例（**从顶部往下量**），缺省 "0.5"
// ```
//
// # ★★★ Owner 2026-10-11 反馈：显示区域按 某视频站重做
//
// Owner 原话（逐字）：
// > 那个遮挡区域我对现在的不满意,要按照某视频站的那个去做
// 追问"哪一点不满意"⇒「1 2 3 4我都要」（四条全要）：
// ```text
// ① 拖动时画面上要有**半透明的分界线/遮罩**（某视频站拖动时的视觉反馈）
// ② 默认值不能是 1.0（铺满全屏）—— 某视频站默认约为上半屏
// ③ 百分比含义对齐 某视频站：从**顶部往下量**的"弹幕占用区"
// ④ 拖动时**实时**生效（每帧都画）
// ```
// （②③ 的 `area` 语义与默认值见 [DanmakuConfig.area] / [DanmakuConfig.defaultArea]；
//  ①④ 的渲染在 lib/ui/widgets/danmaku_overlay.dart 的 `DanmakuAreaGuide`。）
//
// # 为什么自己写 SHA-256、用 dart:io 而不是 package:crypto / package:http
//
// `pubspec.yaml` 的 `dependencies:` 里只有 `http`，**没有** `crypto` ——
// 而签名模式要 `base64(sha256(AppId + Timestamp + Path + AppSecret))`。
// 直接 `import 'package:crypto/crypto.dart'` 属于**未声明依赖**
// （现在能编译只是因为它恰好是传递依赖，换一次 lock 就会炸）。
// `pubspec.yaml` 不在本次写范围内 ⇒ 用 `dart:io` 的 `HttpClient`
// 加本文件自己实现的 SHA-256，**零新依赖**。
//
// # 鉴权：签名模式（不把 AppSecret 直接当请求头发出去）
//
// 逐字来自官方文档（`.probe/danmaku/open.txt`「签名验证模式指南」）：
// > base64(sha256(AppId + Timestamp + Path + AppSecret))
// > Timestamp：当前时间戳（UTC Unix 秒）
// > Path：API 地址后的路径部分，以斜杠开头，不含协议/域名/问号后的查询参数
// 请求头：`X-AppId` / `X-Signature` / `X-Timestamp`。
//
// # 错误必须**原文**透出（不要换成"网络错误"这种糊话）
//
// 实测（2026-10-04，无凭证）：
// ```text
// GET https://api.dandanplay.net/api/v2/comment/123450001?withRelated=true
// => HTTP 403 Forbidden
//    X-Error-Message: Missing Authentication Headers
//    Server: nginx
//    Content-Length: 0
// ```
// 403 的**原因**只在响应头 `X-Error-Message` 里（正文是空的），
// 取值有 `Missing Authentication Headers` / `Invalid Timestamp` /
// `Invalid AppId` / `Invalid Signature` / `Invalid AppSecret`。
// ⇒ 本文件把这些值**原样**带进 `DanmakuException.xErrorMessage`，
//   UI 直接显示 —— 用户和我们才能一眼看出是"没配凭证"还是"签名算错"。
//
// # 拿不到 fileHash 的现实（为什么走 fileNameOnly / search）
//
// 官方推荐流程是 `fileHash = 文件前 16MB 的 MD5`。
// 而本项目的播放地址是**流**（本地代理或远端 m3u8），
// `StreamCandidate` 里**没有本地路径、也没有 fileSize**
// ⇒ 物理上算不出 fileHash ⇒ 只能用 `matchMode = fileNameOnly`
//   或退路 `GET /api/v2/search/episodes?anime=&episode=`。
// 这一点在报告里必须如实标注为**能力限制**，不是 bug。
//
// TODO(security): AppSecret 目前明文存 ui-prefs.json，需迁移到系统凭据存储
// （Windows DPAPI / Android Keystore）。见 danmaku_settings_dialog.dart 头部。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart' show immutable, visibleForTesting;

import 'ui_prefs.dart';

/// 一条弹幕的显示模式
///
/// 值来自 弹弹play 的 `p` 字段第 2 段（`出现时间,模式,颜色,用户ID`）：
/// ```text
/// 1 = 滚动（从右往左）
/// 4 = 底部固定
/// 5 = 顶部固定
/// ```
/// 其余值（2/3/6/7/8/9）是历史遗留或高级模式（逆向、精确时间定位等）。
/// 这里一律按**滚动**处理 —— 宁可按常见方式显示，也不要整条丢掉。
enum DanmakuMode {
  scroll,
  bottom,
  top;

  static DanmakuMode fromWire(int v) {
    switch (v) {
      case 4:
        return DanmakuMode.bottom;
      case 5:
        return DanmakuMode.top;
      default:
        return DanmakuMode.scroll;
    }
  }

  /// 是否固定在屏幕上（顶部/底部）—— 决定用哪一套轨道
  bool get isFixed => this != DanmakuMode.scroll;

  /// 给 UI / 日志看的中文名
  String get label {
    switch (this) {
      case DanmakuMode.scroll:
        return '滚动';
      case DanmakuMode.bottom:
        return '底部';
      case DanmakuMode.top:
        return '顶部';
    }
  }
}

/// 一条弹幕（已经解析、已经算好出现时间）
///
/// 弹弹play 返回的原始形态是 `CommentData{ cid, p, m }`，
/// 其中 `p` 是一串**逗号分隔的字符串**：`出现时间,模式,颜色,用户ID`。
/// 本类把它拆开并做三件规范化：
/// ```text
/// 1. time  : String -> double（秒），并叠加 shift（见下）
/// 2. mode  : int    -> DanmakuMode（未知值归滚动）
/// 3. color : int    -> 只留 24 位 RGB（有些源会塞超过 0xFFFFFF 的值）
/// ```
///
/// ## 关于 shift（弹幕偏移）
///
/// `/api/v2/match` 的每条结果带一个 `shift` 字段，官方逐字：
/// > 弹幕偏移时间（弹幕应延迟多少秒出现）。此数字为负数时表示弹幕应提前多少秒出现。
///
/// 例：视频本体带了 90 秒的片头，弹幕库是按**无片头版**录的，
/// 那么 shift = 90，弹幕时间要整体 +90 才对得上。
/// ⇒ shift 由 [DanmakuMatch.shift] 提供，在 [ExternalDanmakuClient] 里一次性叠加，
///   叠加后 time < 0 的弹幕直接丢掉（提前到负数 = 这条本来就不该出现）。
class DanmakuComment {
  const DanmakuComment({
    required this.cid,
    required this.time,
    required this.text,
    this.mode = DanmakuMode.scroll,
    this.color = 0xFFFFFF,
    this.userId = '',
  });

  /// 弹幕库内的唯一编号（弹弹play 的 `cid`）
  final int cid;

  /// 出现时间，单位**秒**，已经叠加过 shift
  final double time;

  /// 弹幕正文
  final String text;

  final DanmakuMode mode;

  /// 24 位 RGB（`R * 65536 + G * 256 + B`）。
  /// UI 侧拼成 `Color(0xFF000000 | color)`。
  /// 注意：弹幕颜色**没有** alpha 通道，透明度由全局设置控制。
  final int color;

  final String userId;

  /// 解析一条原始弹幕；无法解析时返回 null（调用方直接跳过）
  ///
  /// `p` 的容错策略：只要求第 1 段（时间）能解析出数字，
  /// 后面的段缺失就用默认值 —— 弹幕库里历史数据格式很杂，
  /// 为了一个坏字段丢掉整条弹幕不划算。
  static DanmakuComment? parse({
    required int cid,
    required String p,
    required String m,
    double shift = 0,
  }) {
    if (m.trim().isEmpty) return null;
    final parts = p.split(',');
    if (parts.isEmpty) return null;
    final rawTime = double.tryParse(parts[0].trim());
    if (rawTime == null) return null;
    final t = rawTime + shift;
    if (t < 0) return null;
    var mode = DanmakuMode.scroll;
    if (parts.length > 1) {
      final mv = int.tryParse(parts[1].trim());
      if (mv != null) mode = DanmakuMode.fromWire(mv);
    }
    var color = 0xFFFFFF;
    if (parts.length > 2) {
      final cv = int.tryParse(parts[2].trim());
      if (cv != null && cv > 0) color = cv & 0xFFFFFF;
    }
    final uid = parts.length > 3 ? parts[3].trim() : '';
    return DanmakuComment(
      cid: cid,
      time: t,
      text: m,
      mode: mode,
      color: color,
      userId: uid,
    );
  }

  /// 从 弹弹play 的 JSON 对象解析（`{cid, p, m}`）
  static DanmakuComment? fromJson(Map<String, dynamic> j, {double shift = 0}) {
    final cid = _asInt(j['cid']);
    final p = j['p']?.toString() ?? '';
    final m = j['m']?.toString() ?? '';
    if (cid == null) return null;
    return DanmakuComment.parse(cid: cid, p: p, m: m, shift: shift);
  }

  @override
  String toString() => 'DanmakuComment(#$cid ${time.toStringAsFixed(2)}s '
      '${mode.label} #${color.toRadixString(16).padLeft(6, "0")} "$text")';
}

/// 弹弹play 的整数可能以 int 或 String 出现（int64 走 JSON 时常见），
/// 这里统一成 int。
int? _asInt(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}

/// `/api/v2/match` 的一条匹配结果（只要本项目用得上的字段）
///
/// 官方 `MatchResultV2` 还有 animeId / type / typeDescription / imageUrl，
/// 这里只留渲染和排错需要的：
/// ```text
/// episodeId   弹幕库 ID —— 拿弹幕的唯一钥匙
/// animeTitle  作品名   —— 给用户看，让用户确认"匹配对不对"
/// episodeTitle 剧集名  —— 同上
/// shift       弹幕偏移秒数（负数=提前）—— 必须叠加，见 DanmakuComment
/// ```
class DanmakuMatch {
  const DanmakuMatch({
    required this.episodeId,
    this.animeTitle = '',
    this.episodeTitle = '',
    this.shift = 0,
    this.cover = '',
  });

  final int episodeId;
  final String animeTitle;
  final String episodeTitle;
  final double shift;

  /// Poster URL for the work (empty = none available).
  ///
  /// 2026-10-15 (Owner: "I remember it could show covers? see if you can").
  ///
  /// IMPORTANT: /api/v2/search/episodes does NOT return a cover at all --
  /// verified against the live API: animes[] there only carries animeId,
  /// animeTitle, type, typeDescription and episodes. The image lives on
  /// /api/v2/bangumi/{animeId} as bangumi.imageUrl (that endpoint also
  /// returns the episode list, so one request gets both).
  ///
  /// Empty string rather than null: matches how the rest of this class
  /// treats missing text, and keeps `?.toString() ?? ''` call sites simple.
  final String cover;

  static DanmakuMatch? fromJson(Map<String, dynamic> j) {
    final id = _asInt(j['episodeId']);
    if (id == null || id <= 0) return null;
    return DanmakuMatch(
      episodeId: id,
      animeTitle: j['animeTitle']?.toString() ?? '',
      episodeTitle: j['episodeTitle']?.toString() ?? '',
      shift: _asDouble(j['shift']),
    );
  }

  /// 一行给人看的描述，例：`某番 第 3 集（偏移 +90.0s）`
  String get label {
    final b = StringBuffer();
    if (animeTitle.isNotEmpty) b.write(animeTitle);
    if (episodeTitle.isNotEmpty) {
      if (b.isNotEmpty) b.write(' ');
      b.write(episodeTitle);
    }
    if (b.isEmpty) b.write('弹幕库 #$episodeId');
    if (shift != 0) {
      b.write('（偏移 ');
      if (shift > 0) b.write('+');
      b.write(shift.toStringAsFixed(1));
      b.write('s）');
    }
    return b.toString();
  }

  @override
  String toString() => 'DanmakuMatch(#$episodeId "$label")';
}

double _asDouble(Object? v) {
  if (v == null) return 0;
  if (v is num) return v.toDouble();
  return double.tryParse(v.toString()) ?? 0;
}

// -----------------------------------------------------------------------
// 搜索关键词候选（2026-10-15：修「点了导入还是 0 条弹幕」）
// -----------------------------------------------------------------------

/// 从标题切出若干「可能搜得到」的关键词（纯函数 —— 便于单测钉住）
///
/// # 实测依据（真打官方 API，2026-10-15）
/// ```text
/// 标题 = 「无职转生Ⅲ ～到了异世界就拿出真本事～ 第1话 燃烧吧，狂犬」
///   整串当关键词        ⇒ 0 个作品          ← 改前全程用的就是这一条
///   砍掉「第N话…」        ⇒ 4 个作品，**不含正确的 18727**
///   砍掉「～副标题～」      ⇒ 0 个作品
///   只留第一个空格段        ⇒ 5 个作品，含 18727 ✓
/// ```
/// 而 18727 的第1话（187270001）本身有 **2709 条**弹幕
/// ⇒ 弹幕一直都在，是「搜的词不对」把它挡在了门外。
///
/// # 为什么是「多候选」而不是「取一个最好的词」
/// ```text
/// 官方搜索是**模糊**的：把一个作品的**完整名字**喂进去，
/// 反而**搜不到它自己**（上面第 1 行就是）。
/// 所以不能只因为某个候选返回非空就信它，
/// 要把几个候选的结果**合并**后再按相似度排序。
/// ```
///
/// 返回值已去重、保序；调用方按顺序尝试（见 [ExternalDanmakuClient.searchEpisodesSmart]）。
List<String> danmakuSearchKeywords(String rawTitle) {
  final t = rawTitle.trim();
  if (t.isEmpty) return const <String>[];
  final out = <String>[];
  void add(String s) {
    final v = s.trim().replaceAll(RegExp(r'\s+'), ' ');
    if (v.length >= 2 && !out.contains(v)) out.add(v);
  }

  add(t);
  // 「～副标题～」/ 「~sub~」整段去掉
  add(t.replaceAll(RegExp(r'[～~][^～~]*[～~]'), ' '));
  // 「第N话/集/回/幕」及其后面的一切去掉
  add(t.replaceAll(RegExp(r'第\s*\d+\s*[话集回幕].*$'), ''));
  // 最粗但常常最有效：第一个空格段（「无职转生Ⅲ」就是这样出来的）
  final segs = t.split(RegExp(r'\s+'));
  if (segs.isNotEmpty) add(segs.first);
  return out;
}

/// 从标题里抠出「第N话 …」这一段（拿来比**集**的相似度）；抠不到返回 ''
String danmakuEpisodeHint(String rawTitle) {
  final m = RegExp(r'第\s*\d+\s*[话集回幕].*$').firstMatch(rawTitle.trim());
  if (m == null) return '';
  return m.group(0)!.trim();
}

/// 按 code point 数公共前缀（按 UTF-16 会把中文算成半个）
int _commonPrefixRunes(String a, String b) {
  final ra = a.runes.toList();
  final rb = b.runes.toList();
  final n = ra.length < rb.length ? ra.length : rb.length;
  var i = 0;
  while (i < n && ra[i] == rb[i]) {
    i++;
  }
  return i;
}

/// 候选作品名与「用户正在看的标题」有多像（越大越像）
///
/// 用“公共前缀最长”而不是一般的字符串相似度：剧集标题的差别
/// 恰恰在**后面**（「无职转生Ⅲ」vs「无职转生Ⅱ」差在第 5 个字），
/// 前缀能把它们分开；而「含子串」只能分出“是不是同一部”。
int danmakuTitleScore(String candidate, String original) {
  if (candidate.isEmpty) return 0;
  var s = _commonPrefixRunes(candidate, original) * 10;
  if (original.contains(candidate)) s += 40;
  // 同前缀下短名字更可能是“基础作品”而不是“第二部分”
  s -= candidate.runes.length;
  return s;
}

// -----------------------------------------------------------------------
// SHA-256（自己实现，理由见文件头）
// -----------------------------------------------------------------------

/// SHA-256 的 64 个轮常量（FIPS 180-4 5.4.2）
const List<int> _k256 = <int>[
  0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
  0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
  0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
  0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
  0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
  0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
  0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
  0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
  0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
  0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
  0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
  0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
  0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
  0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
  0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
  0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

int _rotr(int x, int n) => ((x >> n) | (x << (32 - n))) & 0xFFFFFFFF;

/// 计算 SHA-256，返回 32 字节摘要
///
/// 纯 Dart、零依赖。正确性靠**公开测试向量**验证（见 `test/task13_danmaku_test.dart`）：
/// ```text
/// sha256("")          = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
/// sha256("abc")       = ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad
/// sha256("abcdbcde...")（56 字节长串，跨 2 个分组）= 248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1
/// ```
Uint8List sha256Bytes(List<int> input) {
  final msgLen = input.length;
  // 补位：0x80 + 若干 0x00，使总长 = 56 (mod 64)，再接 8 字节大端位长
  final total = ((msgLen + 9 + 63) ~/ 64) * 64;
  final data = Uint8List(total);
  data.setRange(0, msgLen, input);
  data[msgLen] = 0x80;
  final bitLen = msgLen * 8;
  for (var i = 0; i < 8; i++) {
    data[total - 1 - i] = (bitLen >> (8 * i)) & 0xFF;
  }

  var h0 = 0x6a09e667;
  var h1 = 0xbb67ae85;
  var h2 = 0x3c6ef372;
  var h3 = 0xa54ff53a;
  var h4 = 0x510e527f;
  var h5 = 0x9b05688c;
  var h6 = 0x1f83d9ab;
  var h7 = 0x5be0cd19;

  final w = Uint32List(64);
  for (var off = 0; off < total; off += 64) {
    for (var i = 0; i < 16; i++) {
      final b = off + i * 4;
      w[i] = (data[b] << 24) | (data[b + 1] << 16) | (data[b + 2] << 8) | data[b + 3];
    }
    for (var i = 16; i < 64; i++) {
      final x = w[i - 15];
      final y = w[i - 2];
      final s0 = _rotr(x, 7) ^ _rotr(x, 18) ^ (x >> 3);
      final s1 = _rotr(y, 17) ^ _rotr(y, 19) ^ (y >> 10);
      w[i] = (w[i - 16] + s0 + w[i - 7] + s1) & 0xFFFFFFFF;
    }
    var a = h0;
    var b = h1;
    var c = h2;
    var d = h3;
    var e = h4;
    var f = h5;
    var g = h6;
    var h = h7;
    for (var i = 0; i < 64; i++) {
      final s1 = _rotr(e, 6) ^ _rotr(e, 11) ^ _rotr(e, 25);
      final ch = (e & f) ^ ((~e & 0xFFFFFFFF) & g);
      final t1 = (h + s1 + ch + _k256[i] + w[i]) & 0xFFFFFFFF;
      final s0 = _rotr(a, 2) ^ _rotr(a, 13) ^ _rotr(a, 22);
      final maj = (a & b) ^ (a & c) ^ (b & c);
      final t2 = (s0 + maj) & 0xFFFFFFFF;
      h = g;
      g = f;
      f = e;
      e = (d + t1) & 0xFFFFFFFF;
      d = c;
      c = b;
      b = a;
      a = (t1 + t2) & 0xFFFFFFFF;
    }
    h0 = (h0 + a) & 0xFFFFFFFF;
    h1 = (h1 + b) & 0xFFFFFFFF;
    h2 = (h2 + c) & 0xFFFFFFFF;
    h3 = (h3 + d) & 0xFFFFFFFF;
    h4 = (h4 + e) & 0xFFFFFFFF;
    h5 = (h5 + f) & 0xFFFFFFFF;
    h6 = (h6 + g) & 0xFFFFFFFF;
    h7 = (h7 + h) & 0xFFFFFFFF;
  }

  final out = Uint8List(32);
  final hs = <int>[h0, h1, h2, h3, h4, h5, h6, h7];
  for (var i = 0; i < 8; i++) {
    out[i * 4] = (hs[i] >> 24) & 0xFF;
    out[i * 4 + 1] = (hs[i] >> 16) & 0xFF;
    out[i * 4 + 2] = (hs[i] >> 8) & 0xFF;
    out[i * 4 + 3] = hs[i] & 0xFF;
  }
  return out;
}

/// `base64(sha256(text))` —— 就是 弹弹play 要求的 `X-Signature`
String sha256Base64(String text) =>
    base64.encode(sha256Bytes(utf8.encode(text)));

/// 十六进制摘要，只给日志和测试用
String sha256Hex(String text) {
  final d = sha256Bytes(utf8.encode(text));
  final sb = StringBuffer();
  for (final b in d) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

// -----------------------------------------------------------------------
// 错误
// -----------------------------------------------------------------------

/// 弹幕功能里所有"能给人看"的失败都走这个异常
///
/// 设计要点：**保留服务端原文**。
/// 弹幕拿不到的原因分三类，用户看到的提示必须能区分：
/// ```text
/// 1. 没配凭证   HTTP 403 + 头 X-Error-Message: Missing Authentication Headers
/// 2. 凭证不对   HTTP 403 + 头 X-Error-Message: Invalid Signature / Invalid AppId ...
/// 3. 匹配不到   业务错误（HTTP 200 + success:false）或 matches 为空
/// ```
/// 所以 [xErrorMessage] / [errorCode] / [errorMessage] / [body] 全部原样保留，
/// [message] 只是给人看的一句话总结，**不替换**原文。
class DanmakuException implements Exception {
  DanmakuException(
    this.message, {
    this.statusCode = 0,
    this.xErrorMessage = '',
    this.errorCode = 0,
    this.errorMessage = '',
    this.body = '',
    this.uri = '',
    this.resolvedAddress = '',
    this.hint,
  });

  /// 中文一句话总结（UI 主文案）
  final String message;

  /// HTTP 状态码，0 表示还没发出去就失败了（DNS / 连接超时等）
  final int statusCode;

  /// 响应头 `X-Error-Message` 原文，可能为空
  final String xErrorMessage;

  /// 业务错误码（`ResponseBase.errorCode`）
  final int errorCode;

  /// 业务错误原文（`ResponseBase.errorMessage`）
  final String errorMessage;

  /// 响应正文原文（截断到 2000 字，够排错又不至于把 UI 撑爆）
  final String body;

  /// 出错的请求地址（不含签名，可以安全展示）
  final String uri;

  /// 这次失败时**本机解析到、并去连的那个地址**（空串 = 没拿到）
  ///
  /// ★★★ 2026-10-19（R3-③/⑦ 收尾）：只来自 `SocketException.address`。
  ///
  /// # 它为什么存在（不是为了"多打印一行"）
  /// ```text
  /// 「DNS 被劫持」与「服务没起来」在**连接层是同一个现象**（都连不上），
  /// 区别只在"连的那个地址对不对"。而那个地址**本来就在异常里**，
  /// 改前被 `catch (e)` 丢掉了 ⇒ UI 只能给出同一句话。
  /// ⇒ 把它带出来，UI 才能把两件事分开说（见 DanmakuProbeReport）。
  ///
  /// ⚠️ 隐私：它是一个 IP，不是 URL，**不含 token**，与 [uri] 同级可展示。
  /// ⚠️ 语义边界：只有"连不上"那一支有值；超时（TimeoutException）
  ///    分支拿不到地址 ⇒ 空串。**空串必须被当成"没有证据"，不能当成"正常"。**
  final String resolvedAddress;

  /// 「为什么失败 + 怎么办」的中文动作，null = 没有比 [message] 更具体的话可说
  ///
  /// 判据全部来自真实读数（HTTP 状态码 + `X-Error-Message` 原文），
  /// 见 [DanmakuHint.of]。它**不替换** [message] / [xErrorMessage] ——
  /// 服务端原文照旧透出，这里只是补一句"下一步做什么"。
  final DanmakuHint? hint;

  /// 是否属于"没配 / 配错凭证"这一类 —— UI 据此提示"去设置里填 AppId"
  bool get isAuthProblem => statusCode == 403 || statusCode == 401;

  /// 多行详细描述，给对话框的"详情"区域用
  String get detail {
    final b = StringBuffer();
    if (statusCode != 0) b.writeln('HTTP $statusCode');
    if (xErrorMessage.isNotEmpty) b.writeln('X-Error-Message: $xErrorMessage');
    if (errorCode != 0) b.writeln('errorCode: $errorCode');
    if (errorMessage.isNotEmpty) b.writeln('errorMessage: $errorMessage');
    if (uri.isNotEmpty) b.writeln('请求: $uri');
    if (body.isNotEmpty) b.writeln('响应正文: $body');
    return b.toString().trimRight();
  }

  @override
  String toString() {
    final d = detail;
    return d.isEmpty ? 'DanmakuException($message)' : 'DanmakuException($message)\n$d';
  }
}

// -----------------------------------------------------------------------
// 传输层（抽出来是为了**可测**：真实实现走 dart:io，测试注入假实现）
// -----------------------------------------------------------------------

/// 一次 HTTP 响应的最小快照
class DanmakuHttpResponse {
  const DanmakuHttpResponse({
    required this.statusCode,
    this.body = '',
    this.headers = const <String, String>{},
  });

  final int statusCode;
  final String body;

  /// 响应头，**键统一小写**（HTTP 头大小写不敏感，统一后才好查）
  final Map<String, String> headers;

  /// 403 时的失败原因就在这里（正文是空的）
  String get xErrorMessage => headers['x-error-message'] ?? '';

  String get contentType => headers['content-type'] ?? '';

  bool get isOk => statusCode >= 200 && statusCode < 300;

  @override
  String toString() => 'DanmakuHttpResponse($statusCode, ${body.length} chars)';
}

/// 弹幕 HTTP 传输接口
///
/// 存在的理由：单测 / 探针里要能**确定性地**造出 403 + `X-Error-Message`，
/// 而不是"跑到网上碰运气"。生产环境用 [IoDanmakuTransport]。
abstract class DanmakuTransport {
  /// 发一次请求；**不允许**在非 2xx 时抛异常 —— 状态码和响应头要带回来，
  /// 由上层决定怎么解释（403 的 X-Error-Message 就是这么拿到的）。
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  });

  /// 释放底层连接池
  void close();
}

/// 生产实现：`dart:io` 的 [HttpClient]
///
/// 两个关键设置：
/// ```text
/// followRedirects = true   —— /api/v2/comment/{id} 官方响应码就是 302，
///                            不跟随重定向的话永远拿不到弹幕
/// connectionTimeout        —— 移动网络下别无限等
/// ```
class IoDanmakuTransport implements DanmakuTransport {
  /// [findProxy] 是 `HttpClient.findProxy` 的**直接值**（如
  /// `'PROXY 127.0.0.1:7890'` / `'DIRECT'`）；null = 直连。
  ///
  /// # ★★★ 为什么 null 也要**显式**设成 `'DIRECT'`（而不是"不设"）
  /// ```text
  /// `HttpClient.findProxy` **一旦被赋值**，Dart 就完全按这个回调决定走向，
  /// 不再看 `HTTPS_PROXY` / `HTTP_PROXY` 等环境变量。
  /// 反之**不赋值**时，Dart 会去读环境变量 —— 也就是说：
  ///
  ///   不设 ⇒ 行为取决于用户 shell 里有没有 HTTPS_PROXY
  ///        ⇒ "同一个包在不同机器上表现不同"
  ///        ⇒ 这正是"时好时坏"的来源（本机 7890 代理下 HandshakeException）
  ///   显式 DIRECT ⇒ 无论环境变量是什么，都走直连 ⇒ **可预期**
  ///
  /// ⇒ 要让「用户选直连」成为**真的直连**，就必须显式给 'DIRECT'。
  ///    用"不设"来表达直连是错的：那是"让别人替我决定"。
  /// ```
  IoDanmakuTransport({
    HttpClient? client,
    this.timeout = const Duration(seconds: 15),
    String? findProxy,
  }) : _client = client ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 10)
              ..userAgent = 'sourin-flutter-spike/danmaku'
              // 无条件赋值（见构造函数文档：null ⇒ 显式 'DIRECT'）
              ..findProxy = ((String? p) => (Uri _) => p ?? 'DIRECT')(findProxy));

  final HttpClient _client;
  final Duration timeout;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    final req = await _client.openUrl(method, uri).timeout(timeout);
    headers.forEach(req.headers.set);
    if (body != null) {
      final bytes = utf8.encode(body);
      req.headers.contentLength = bytes.length;
      req.add(bytes);
    }
    final resp = await req.close().timeout(timeout);
    // 弹弹play 全站 UTF-8；allowMalformed 保证偶发坏字节不会把整次请求炸掉
    final text = await resp
        .transform(const Utf8Decoder(allowMalformed: true))
        .join()
        .timeout(timeout);
    final h = <String, String>{};
    resp.headers.forEach((name, values) {
      if (values.isNotEmpty) h[name.toLowerCase()] = values.join(', ');
    });
    return DanmakuHttpResponse(
      statusCode: resp.statusCode,
      body: text,
      headers: h,
    );
  }

  @override
  void close() => _client.close(force: true);
}

// -----------------------------------------------------------------------
// 弹幕代理（Owner 要 a+b：传输层支持 + 配置页开关）
// -----------------------------------------------------------------------

/// 弹幕请求的代理模式（与 `UiPrefs.danmakuProxyMode` 的字符串一一对应）。
///
/// # 为什么是**三个**而不是"开/关"
/// ```text
/// Owner 原话要的是「可以在配置页面让他选择是否走代理」。
/// 而"是否"在实际网络里至少是三种情况：
///   ① 直连可用（多数网络）           ⇒ 选 direct
///   ② 必须跟随系统那一套（公司/校园）  ⇒ 选 system
///   ③ 只有一个特定端口（本机 7890）    ⇒ 选 custom
/// ⇒ 只给"开关"会让 ②③ 的用户没法表达，
///   而他们正是最需要这个功能的人（本机 *.vercel.app 被屏蔽就是 ③）。
/// ```
enum DanmakuProxyMode {
  /// 直连。**显式**下发 `DIRECT`，不受环境变量影响。
  direct,

  /// 跟随系统代理。**下发 `null` 回调之外的语义**见下：
  /// 注意 Dart 没有"跟随系统"这个 API —— 它的默认行为是
  /// 「读 `HTTPS_PROXY`/`HTTP_PROXY` 环境变量」。
  /// ⇒ 本模式 = 把 `findProxy` 设为「读环境变量」的行为，
  ///    即**保留改动前的隐式行为**，只是现在由用户**主动选择**才发生。
  system,

  /// 自定义代理地址（如 `http://127.0.0.1:7890`）。
  custom,
}

/// 把 [DanmakuProxyMode] + 地址解析成 `HttpClient.findProxy` 的**直接值**。
///
/// 返回值语义（三个值对应三种行为，缺一不可）：
/// ```text
/// 'DIRECT'                ⇒ 直连，且**不读**环境变量
/// 'PROXY host:port'       ⇒ 走这个代理
/// null                    ⇒ ★ 不设置 findProxy ⇒ Dart 自己读环境变量
///                            （= "跟随系统"，这是 Dart 唯一能表达它的方式）
/// ```
///
/// # ★ 为什么 system 用 `null` 而 direct 用 `'DIRECT'`
/// ```text
/// 这两个必须**不同**，否则"直连"和"跟随系统"在环境变量存在时会变成同一件事，
/// 用户的选择就白给了。
///
///   direct ⇒ 显式 'DIRECT' ⇒ 有 HTTPS_PROXY 也**照样直连**
///   system ⇒ null         ⇒ 有 HTTPS_PROXY 就走它，没有就直连
/// ```
///
/// # 解析失败怎么办
/// ```text
/// `custom` 但地址空/解析不出 host:port ⇒ 退回直连（`'DIRECT'`），
/// 并让调用方**能感知**（见 [diagnoseDanmakuProxy]）。
/// ★ 不能静默退回"跟随系统" —— 那会让"我配了代理却没生效"变成
///   "它偷偷用了别的代理"，两种失败的表现完全不同，难以排查。
/// ```
String? resolveDanmakuFindProxy({
  required DanmakuProxyMode mode,
  String url = '',
}) {
  switch (mode) {
    case DanmakuProxyMode.direct:
      return 'DIRECT';
    case DanmakuProxyMode.system:
      // ★ 注意：不是 'DIRECT'！见上面那段文档。
      return null;
    case DanmakuProxyMode.custom:
      final p = _parseProxyHostPort(url);
      // 地址不可用 ⇒ 退回显式直连（不是 null，理由见上）
      return p == null ? 'DIRECT' : 'PROXY $p';
  }
}

/// `http://127.0.0.1:7890` / `127.0.0.1:7890` ⇒ `'h:7890'`
///
/// 失败返回 null（调用方据此退回直连）。
///
/// # ★★★ 为什么**拒绝** `socks5://`（2026-10-18 实测，不是推测）
/// ```text
/// 实测（本机 HTTP 服务 + 假 socks 端口，真发请求）：
///   DIRECT                   ⇒ OK status=200        （target 命中 +1）
///   SOCKS5 127.0.0.1:<port>  ⇒ HttpException:
///                              "Invalid proxy configuration SOCKS5 ..."
///                              target 命中 +0，假 socks 端口 accept +0
///
/// ⇒ `dart:io` 的 `HttpClient.findProxy` **只认 DIRECT / PROXY**。
///   `SOCKS5` / `SOCKS` / `HTTPS` 这些字符串**一律**抛
///   `HttpException: Invalid proxy configuration`，且**根本不建连接**。
/// ```
///
/// # 为什么改前那版是**错的**
/// ```text
/// 改前把它解析成 `PROXY host:1080` 下发 —— 会让用户以为在用 socks5，
/// 实际走的是**明文 HTTP 代理协议**打到对方的 socks 端口：
///   · socks 服务端看不懂 HTTP 代理请求 ⇒ 失败（或更糟：行为未定义）
///   · 用户完全无法从现象判断"是我配错了协议"
/// ⇒ 静默换一种协议比明确报错**危险得多**。
/// ```
///
/// ⇒ 现在**明确拒绝**（返回 null ⇒ 上层退回显式直连，UI 诊断行给专门文案）。
///   真要支持 socks5 得换传输层（自己做握手），不是在这里换个字符串。
String? _parseProxyHostPort(String raw) {
  final s = raw.trim();
  if (s.isEmpty) return null;
  final scheme = s.contains('://') ? s.split('://').first.toLowerCase() : 'http';
  // ★ socks 协议族一律拒绝（理由见上）
  if (scheme.startsWith('socks')) return null;
  // 有 scheme 就交给 Uri 解析；没有就补一个假的（Uri 必须有 scheme 才给 host/port）
  final uri = s.contains('://') ? Uri.tryParse(s) : Uri.tryParse('http://$s');
  if (uri == null) return null;
  final host = uri.host;
  if (host.isEmpty) return null;
  // ★ 不猜默认端口：没写端口 = 配置不完整 ⇒ 让 UI 明说"无效"。
  //   猜 80/1080/7890 会把"我漏写端口"变成"它连了别的地方"。
  if (!uri.hasPort) return null;
  if (uri.port <= 0) return null;
  return '$host:${uri.port}';
}

/// 地址是否是 socks 协议 —— 供 UI 显示**专门**的提示
///
/// ★ 单独暴露这个判断，是为了让设置页能说
///   「不支持 socks，请填 HTTP 代理」而不是笼统的「地址无效」：
///   后者的用户会反复改 host/port，改不出结果。
bool isSocksProxyUrl(String raw) {
  final s = raw.trim().toLowerCase();
  return s.startsWith('socks://') || s.startsWith('socks5://');
}

/// 当前该用哪种模式 + 地址（读 UiPrefs，解析成枚举）
///
/// 未知字符串一律按 `direct`（保守：不改既有行为）。
({DanmakuProxyMode mode, String url}) currentDanmakuProxySetting() {
  final raw = UiPrefs.danmakuProxyMode;
  final url = UiPrefs.danmakuProxyUrl;
  final mode = switch (raw) {
    'system' => DanmakuProxyMode.system,
    'custom' => DanmakuProxyMode.custom,
    _ => DanmakuProxyMode.direct,
  };
  return (mode: mode, url: url);
}

/// 把当前设置解析成 `findProxy` 的直接值（生产代码唯一入口）
///
/// ★ 单独抽出来是为了**可单测**：门禁直接调它，
///   不必构造 HttpClient（那需要真实网络）。
String? currentDanmakuFindProxy() {
  final s = currentDanmakuProxySetting();
  return resolveDanmakuFindProxy(mode: s.mode, url: s.url);
}

/// 诊断文案：给设置页显示"现在到底会怎么走"
///
/// ★ 存在的理由：`custom` 但地址坏掉时 `resolve` 会退回 `DIRECT`，
///   用户看到的是"我配了代理却没生效"。有了这句文案，
///   他能在设置页**当场**看到"代理地址无效 ⇒ 当前按直连处理"。
String diagnoseDanmakuProxy({
  required DanmakuProxyMode mode,
  String url = '',
}) {
  final f = resolveDanmakuFindProxy(mode: mode, url: url);
  return switch (mode) {
    DanmakuProxyMode.direct => '直连（不受系统代理环境变量影响）',
    DanmakuProxyMode.system => '跟随系统代理（读取 HTTP_PROXY / HTTPS_PROXY）',
    DanmakuProxyMode.custom => f != 'DIRECT'
        ? '走代理 $f'
        // ★ socks 要给**专门**的文案：笼统说"无效"会让用户反复改 host/port
        : isSocksProxyUrl(url)
            ? '不支持 socks 代理，请填 HTTP 代理地址（如 http://127.0.0.1:7890）'
            : '代理地址无效，当前按直连处理',
  };
}

// -----------------------------------------------------------------------
// 配置（键名已锁定，见文件头）
// -----------------------------------------------------------------------

/// 弹幕配置 —— 三个锁定键 + 四个显示参数
///
/// 全部走 [UiPrefs]，也就是 `<数据目录>/ui-prefs.json`。
/// 空串一律 **remove** 而不是写空值，避免配置文件里攒一堆没用的键。
///
/// ## 为什么不用 `UiPrefs.load` 之外的东西
/// 播放页可能在任何时候读配置（底栏按钮要显示开/关状态），
/// [UiPrefs] 的内存缓存读是同步的、零 IO，正合适。
/// 写是异步合并落盘的（300ms 合并），不需要调用方 await。
///
/// ## 安全
/// AppSecret 目前是**明文**存在 ui-prefs.json 里。
/// 这是当前唯一可选项：项目没有 keyring / secure-storage 依赖，
/// 而 `pubspec.yaml` 不在本次改动范围内。
/// 已在设置对话框里**明确告知用户**，并留了 TODO 见文件头。
class DanmakuConfig {
  DanmakuConfig._();

  // ---- 锁定键（不要改名字，task-14 要按这套接） ----

  /// `"1"` 开 / `"0"` 关；缺省 `"0"`
  static const String keyEnabled = 'dsh.danmaku.enabled';

  /// 弹弹play 开放平台申请到的 AppId；缺省 `""`
  static const String keyAppId = 'dsh.danmaku.appId';

  /// 弹弹play 开放平台申请到的 AppSecret；缺省 `""`
  static const String keyAppSecret = 'dsh.danmaku.appSecret';

  // ---- 显示参数（本文件新增，非锁定） ----

  static const String keyFontScale = 'dsh.danmaku.fontScale';
  static const String keyOpacity = 'dsh.danmaku.opacity';
  static const String keySpeed = 'dsh.danmaku.speed';
  static const String keyArea = 'dsh.danmaku.area';

  // ---- ★★★ 2026-10-09 新增：屏蔽与分类开关（对齐 某视频站弹幕设置） ----
  //
  // Owner 原话：「弹幕管理 还要支持指定区域的屏幕不显示 大小 屏蔽 速度 等等,
  //            这些都参考某视频站的弹幕设置就行了」
  //
  // 键名沿用 `dsh.danmaku.` 前缀，且**全部有向后兼容的缺省值** ——
  // 老用户的 ui-prefs.json 里没有这些键，读出来就是默认（全显示、不屏蔽）。

  /// 滚动弹幕开关（缺省开）
  static const String keyScroll = 'dsh.danmaku.showScroll';

  /// 顶部固定弹幕开关（缺省开）
  static const String keyTop = 'dsh.danmaku.showTop';

  /// 底部固定弹幕开关（缺省开）
  static const String keyBottom = 'dsh.danmaku.showBottom';

  /// 屏蔽词（**每行一个**，存成一个多行字符串）
  ///
  /// 为什么用多行字符串而不是 JSON 数组：用户是在一个多行输入框里敲的，
  /// 存成 JSON 的话每次读写都要序列化，而 UiPrefs 存的就是字符串 ——
  /// 多行文本**就是**最自然的形态，且用户手改 ui-prefs.json 时也看得懂。
  static const String keyBlockWords = 'dsh.danmaku.blockWords';

  /// 屏蔽词是否按**正则**解释（缺省否 ⇒ 按子串包含匹配）
  static const String keyBlockRegex = 'dsh.danmaku.blockRegex';

  /// 屏蔽「按类型」—— 上面三个开关是"显示/不显示"，
  /// 这一组是"这类弹幕直接不进渲染队列"（与 某视频站的"屏蔽类型"对应）。
  static const String keyBlockScroll = 'dsh.danmaku.blockScroll';
  static const String keyBlockTop = 'dsh.danmaku.blockTop';
  static const String keyBlockBottom = 'dsh.danmaku.blockBottom';

  /// ★ 2026-10-11 新增：「只显示彩色弹幕」开关（缺省关 = 彩色和白色都显示）
  ///
  /// # 某视频站语义（查证）
  /// ```text
  /// 某视频站「按类型过滤」里的「彩色」是一枚**只显示彩色弹幕**的开关：
  ///   开 ⇒ 画面上**只留彩色弹幕**，白色（默认色）弹幕全部隐藏。
  /// 参照：DPlayer 的 danmaku API（https://dplayer.diygod.dev/guide.html）
  ///   把「只显示彩色弹幕」实现成一个布尔 API 项 —— 开 = 只留彩色。
  /// ⇒ 本项目同语义：`colorOnly == true` ⇒ 只显示 color != 0xFFFFFF 的弹幕。
  ///   （若 Owner 想要的是反过来的"过滤掉彩色"，把这里取反即可，
  ///     单点可改；之所以选"只显示彩色"，是因为 某视频站原图那枚开关的字面就是
  ///     「彩色」+ 其它三枚「滚动/顶部/底部」也是"开 = 这一类要显示"的同构语义。）
  /// ```
  ///
  /// ⚠️ 本项目**有** `DanmakuComment.color` 字段（24 位 RGB，见 [DanmakuComment.color]），
  ///   所以这枚开关是**有数据支持**的，不是画个假开关。
  static const String keyColorOnly = 'dsh.danmaku.colorOnly';

  /// 白色弹幕的判定阈值：与 0xFFFFFF 的每通道差都 ≤ 它，就算「白」。
  ///
  /// 为什么不是 `== 0xFFFFFF`：弹弹play 的 `p` 第 3 段颜色写得很杂，
  /// 实测有 `16777215`(纯白)、也有近白（如 `16777214`）。用**纯相等**会漏判，
  /// 于是"只显示彩色"时这些近白弹幕会被当成彩色留下 —— 与用户预期相反。
  /// 24 容差（每通道 ~2.4%）足以覆盖"肉眼看上去就是白"的抖动，又不会把
  /// 真正的浅色（如淡粉 `0xFFFFE0E0` 差 32）误当白。
  static const int whiteTolerance = 24;

  // ---- 显示参数的取值范围（UI 滑块与这里共用，别在两处写死） ----

  static const double fontScaleMin = 0.6;
  static const double fontScaleMax = 2.0;
  static const double opacityMin = 0.2;
  static const double opacityMax = 1.0;
  static const double speedMin = 3.0;
  static const double speedMax = 16.0;

  /// ★ 2026-10-11：`area` 下界从 0.3 收到 0.1（Owner 第 ③ 条：按 某视频站）。
  ///
  /// # 为什么要改下界（不是拍脑袋）
  /// ```text
  /// 改前 0.3 = "给最下方的字幕预留 30% 高度"的**反推刻度**——
  ///   刻度本身是对的（弹幕区从顶部往下铺），但 0.3 是个**下界猜测**：
  ///   视频没有字幕、或用户就是想把弹幕压在最上面两条时，0.3 还是太大。
  /// 某视频站那根滑杆允许一直拖到很小（弹幕只占顶上窄窄一条）。
  /// ⇒ 下界收到 0.1（480px 画面上仍能放下 floor(48/27)=1 条轨道，
  ///   `DanmakuTrackAllocator.layout` 里还有 `math.max(..., lh)` 与
  ///   `math.max(1, ...)` 两道兜底 ⇒ 永远不会出现 0 轨道）。
  /// ```
  static const double areaMin = 0.1;
  static const double areaMax = 1.0;

  static const double defaultFontScale = 1.0;
  static const double defaultOpacity = 1.0;
  static const double defaultSpeed = 8.0;

  /// ★ 2026-10-11：默认显示区域 = **0.5（上半屏）**，对齐 某视频站。
  ///
  /// # 依据（不是拍脑袋 —— Owner 第 ② 条）
  /// ```text
  /// 某视频站播放器弹幕设置的"显示区域"默认约为**上半屏**；DPlayer 的 danmaku
  /// 也把"显示区域限制"缺省设为 `unlimited`（= 只受"底部给字幕留一段"约束，
  /// 落到滑块刻度上正是 50%~ 这一档，见 https://dplayer.diygod.dev/guide.html）。
  /// 改前本项目默认 1.0 = 铺满整个画面 ⇒ 弹幕压在下半屏的**字幕**上，
  /// 这正是 Owner「那个遮挡区域…不满意」的直接观感来源。
  /// ```
  ///
  /// # ⚠️ 为什么不给"已存偏好"的老用户做迁移
  /// ```text
  /// 用户若**主动**拖过这根滑杆，存下的就是他自己的选择，不该被我们改掉；
  /// 而"用默认值"的用户根本没写过 `dsh.danmaku.area` 这个键 ——
  /// 他们本来就走 defaultArea 这条支，改默认值**立刻**对他们生效。
  /// ⇒ 真正需要迁移的只有"改前恰好把 1.0 存下来过"的极少数；
  ///   为一个键引入一次性迁移（多一个 `dsh.danmaku.areaMigrated` 标记、
  ///   多一条永远难测的分支）不值，且会**覆盖用户自己的 1.0 选择**。
  ///   故：**不迁移**，只改缺省。老用户想回到铺满 ⇒ 把滑杆拖回 100% 即可
  ///   （滑杆可拖范围仍是 0.1~1.0，能力没丢）。
  /// ```
  static const double defaultArea = 0.5;

  // ---- ★ T27-10：内置凭证（构建期注入，仓库里只有占位符/空串） ----
  //
  // 业主在 dev.dandanplay.com 建好了应用（AppId xgmriqmqcq，2026-10-09
  // 审核通过），但客户端从来没拿到过凭证 ⇒ 「弹幕服务没收到凭证」。
  // 官方文档（doc.dandanplay.com/open/）明确允许开源客户端
  // 「在开源代码中使用占位符，之后在构建时从机密中读取 AppSecret 后替换」。
  //
  // 注入通道：--dart-define=DANDANPLAY_APP_ID=… --dart-define=DANDANPLAY_APP_SECRET=…
  // 缺省（没 define 也没运行时注入）就是空串 ⇒ 本构建行为与改前逐字一致。
  // 仓库里**绝不**出现真实 Secret —— CI 从 GitHub Secrets 读，见 task-11。
  //
  // 优先级（appId/appSecret 各自独立）：UiPrefs 用户覆盖（非空）> builtin > ''。
  // 覆盖/清除（clearCredentials）只动 UiPrefs，永远不写 builtin。

  /// 构建期注入的 AppId（`String.fromEnvironment` 是 const，缺省 ''）
  static const String builtinAppId =
      String.fromEnvironment('DANDANPLAY_APP_ID');

  /// 构建期注入的 AppSecret（同上；**不会**落盘，只在内存里给签名用）
  static const String builtinAppSecret =
      String.fromEnvironment('DANDANPLAY_APP_SECRET');

  /// 内置凭证是否成对可用（只有 AppId 没有 Secret 没法签名 ⇒ 视为没有）。
  ///
  /// 看的是**生效的**内置值（= debugSetBuiltin 注入值 ?? 构建期 const），
  /// 这样对话框的「内置凭证：已生效/未注入」状态行在两种注入通道下
  /// 都说真话；没注入的构建里两者相同（都是空串）⇒ 行为与只读 const 一致。
  static bool get hasBuiltinCredentials =>
      _builtinAppId.isNotEmpty && _builtinAppSecret.isNotEmpty;

  /// 测试注入口（`String.fromEnvironment` 是 const，运行时改不了）。
  ///
  /// 传 null = 恢复「读 const」的缺省路径 ⇒ 不调用它的构建**完全无害**。
  /// 覆盖优先级不变：UiPrefs 用户覆盖仍然压过这里的内置值。
  @visibleForTesting
  static void debugSetBuiltin({String? appId, String? appSecret}) {
    _debugBuiltinAppId = appId;
    _debugBuiltinAppSecret = appSecret;
  }

  static String? _debugBuiltinAppId;
  static String? _debugBuiltinAppSecret;

  static String get _builtinAppId =>
      _debugBuiltinAppId ?? builtinAppId; // null = 缺省读 const

  static String get _builtinAppSecret =>
      _debugBuiltinAppSecret ?? builtinAppSecret;

  /// 用户没覆盖（UiPrefs 无非空值）且内置有值 ⇒ 这次用的是内置 AppId
  static bool get usingBuiltinAppId =>
      (UiPrefs.get(keyAppId) ?? '').trim().isEmpty && _builtinAppId.isNotEmpty;

  /// 同上（AppSecret 半边）
  static bool get usingBuiltinAppSecret =>
      (UiPrefs.get(keyAppSecret) ?? '').trim().isEmpty &&
      _builtinAppSecret.isNotEmpty;

  // ---- 读 ----

  static bool get enabled => UiPrefs.get(keyEnabled) == '1';

  /// 生效的 AppId：用户覆盖（UiPrefs 非空）优先，否则内置，否则空串
  static String get appId {
    final user = (UiPrefs.get(keyAppId) ?? '').trim();
    if (user.isNotEmpty) return user;
    return _builtinAppId;
  }

  /// 生效的 AppSecret：优先级同 [appId]
  static String get appSecret {
    final user = (UiPrefs.get(keyAppSecret) ?? '').trim();
    if (user.isNotEmpty) return user;
    return _builtinAppSecret;
  }

  /// **用户自己填的** AppId（只看 UiPrefs 覆盖，不看内置）；没填返回空串。
  ///
  /// ★ 2026-10-14：给凭证输入框做**预填**用 —— 面板要能看见用户上次填的值。
  /// ⚠️ 与 [appId]（**生效值**）分开是有意的：生效值可能是内置凭证，
  ///    把它塞进输入框会让用户误以为"这是我填的"，一点保存反而用真内置值
  ///    覆盖掉原值。预填只看用户覆盖，生效值走 `maskedAppId` 在状态行展示。
  static String get userAppId => (UiPrefs.get(keyAppId) ?? '').trim();

  /// 用户自己填的 AppSecret（只看 UiPrefs 覆盖，不看内置）；没填返回空串。
  static String get userAppSecret => (UiPrefs.get(keyAppSecret) ?? '').trim();

  /// 用户配置的自建弹幕后端（[UiPrefs.danmakuEndpoint] / [UiPrefs.danmakuToken]）。
  ///
  /// # 为什么放在 `DanmakuConfig` 上（而不是让每个调用点自己读）
  /// ```text
  /// 与 [appId] / [appSecret] **同一条纪律**：偏好读进来的地方只有一个，
  /// 于是「面板写 UiPrefs」⇒「客户端构造时自动生效」是**天然**的，
  /// 不需要宿主在构造参数上再传一遍（少一处会漂移的接线）。
  /// ```
  ///
  /// ⚠️ 非法/空的地址 ⇒ 返回 null ⇒ 完全退回内置的官方/本机路径，
  ///    行为与没有这个功能时**逐字一致**（[DanmakuEndpoint.tryParse] 不抛）。
  static DanmakuEndpoint? get danmakuEndpoint => DanmakuEndpoint.tryParse(
    UiPrefs.danmakuEndpoint,
    token: UiPrefs.danmakuToken,
  );

  /// 内置公共实例（可被测试清空，见 [debugSetPublicInstances]）
  static List<DanmakuPublicInstance> _publicInstances = kDanmakuPublicInstances;

  /// 测试注入口：传 null = 恢复内置表；传 `const []` = 关掉内置实例。
  ///
  /// # 为什么需要这个开关
  /// ```text
  /// 内置实例一上线，「没配地址 ⇒ 走官方」这条老断言就**必然**变成
  /// 「没配地址 ⇒ 走内置实例」。签名/官方那条边的用例要测的是官方本身，
  /// 它们必须能**明确**关掉内置，否则测的是另一条路（假绿）。
  /// 与 [debugSetBuiltin]（内置凭证）同一条纪律。
  /// ```
  @visibleForTesting
  static void debugSetPublicInstances(List<DanmakuPublicInstance>? v) {
    _publicInstances = v ?? kDanmakuPublicInstances;
  }

  /// 当前生效的内置公共实例（第一个 = 默认选中的那个；表空 ⇒ null）
  static DanmakuPublicInstance? get defaultPublicInstance =>
      _publicInstances.isEmpty ? null : _publicInstances.first;

  /// 内置公共实例对应的端点（表空 ⇒ null）
  static DanmakuEndpoint? get publicInstanceEndpoint {
    final p = defaultPublicInstance;
    if (p == null) return null;
    return DanmakuEndpoint.tryParse(p.baseUrl, token: p.token);
  }

  /// **生效的** dan-api 端点 —— 用户填的优先，否则内置公共实例。
  ///
  /// # 与 [danmakuEndpoint] 的区别（这个区别是 Owner 第 4 条的全部要点）
  /// ```text
  /// danmakuEndpoint   = 用户**填了**什么（空 = 没填）
  /// effectiveEndpoint = dan-api 这条路**指向**哪里（空 = 连内置也没有）
  /// ```
  /// Owner 原话：「我之前说的dan-api 是让你接入现成的服务,不是让我去填的,
  /// 或者可以内置上几个」⇒ 没填**不等于**没有，而是用内置的。
  ///
  /// ⚠️ 内置只是**默认值**，不是写死：用户在设置里填了地址就压过它
  ///    （覆盖链与凭证那套同形：用户 > 内置）。
  /// ⚠️ 它**不**代表「本次请求一定打这里」—— 本机 2080 在线时仍然优先本机
  ///    （内置实例是**兜底**，不是抢占）。真实优先序见
  ///    [ExternalDanmakuClient._endpoint] 的文档。
  static DanmakuEndpoint? get effectiveEndpoint =>
      danmakuEndpoint ?? publicInstanceEndpoint;

  /// 这次生效的是不是内置实例（状态行/面板要如实说「内置」还是「你自己填的」）
  static bool get usingPublicInstance =>
      danmakuEndpoint == null && publicInstanceEndpoint != null;

  /// 是否"有资格"发请求。
  ///
  /// 注意：这**不代表**凭证一定有效 —— 有效性只有服务端说了算，
  /// 所以 UI 上这个值只用来决定"是否提示用户去填"，
  /// 不能用来跳过真实请求（真实请求失败要如实显示服务端原文）。
  static bool get isConfigured => appId.isNotEmpty && appSecret.isNotEmpty;

  static double get fontScale =>
      _readDouble(keyFontScale, defaultFontScale, fontScaleMin, fontScaleMax);

  static double get opacity =>
      _readDouble(keyOpacity, defaultOpacity, opacityMin, opacityMax);

  /// 一条弹幕从右边缘走到左边缘的秒数（越大越慢）
  static double get speed =>
      _readDouble(keySpeed, defaultSpeed, speedMin, speedMax);

  /// 弹幕显示区域占画面高度的比例 —— **从画面顶部往下量**（对齐 某视频站）。
  ///
  /// 语义（Owner 第 ③ 条）：
  /// ```text
  /// area = 0.5  ⇒ 弹幕只排在画面顶部 50% 的高度里，下半屏完全留给画面/字幕；
  /// area = 1.0  ⇒ 铺满整个画面高度（某视频站滑杆拖到最右）。
  /// ```
  /// 渲染侧对应 `DanmakuTrackAllocator.layout(area:)`：轨道从顶部第 0 行
  /// 往下铺，铺满 `canvasHeight * area` 为止（顶部固定弹幕从上往下、
  /// 底部固定弹幕在这个区域内从下往上找轨，见该函数的 `_laneOrder`）。
  static double get area =>
      _readDouble(keyArea, defaultArea, areaMin, areaMax);

  // ---- ★ 新增项的读（缺省值 = 向后兼容：老用户读出来就是"全显示、不屏蔽"） ----

  static bool get showScroll => UiPrefs.get(keyScroll) != '0';

  static bool get showTop => UiPrefs.get(keyTop) != '0';

  static bool get showBottom => UiPrefs.get(keyBottom) != '0';

  /// 屏蔽词列表（已 trim、去空行、去重）
  static List<String> get blockWords {
    final raw = UiPrefs.get(keyBlockWords) ?? '';
    if (raw.trim().isEmpty) return const <String>[];
    final out = <String>[];
    for (final line in raw.split('\n')) {
      final w = line.trim();
      if (w.isNotEmpty && !out.contains(w)) out.add(w);
    }
    return out;
  }

  static bool get blockRegex => UiPrefs.get(keyBlockRegex) == '1';

  static bool get blockScroll => UiPrefs.get(keyBlockScroll) == '1';

  static bool get blockTop => UiPrefs.get(keyBlockTop) == '1';

  static bool get blockBottom => UiPrefs.get(keyBlockBottom) == '1';

  /// ★ 「只显示彩色弹幕」开关（缺省关 ⇒ 彩色/白色都显示）
  static bool get colorOnly => UiPrefs.get(keyColorOnly) == '1';

  /// 一条弹幕是不是「白色（默认色）」—— 供「只显示彩色」过滤用。
  ///
  /// 判据：与 0xFFFFFF 的 R/G/B 三通道差都 ≤ [whiteTolerance]（见该常量注释）。
  /// **纯函数**，可单测。
  static bool isWhiteColor(int color) {
    final rgb = color & 0xFFFFFF;
    final r = (rgb >> 16) & 0xFF;
    final g = (rgb >> 8) & 0xFF;
    final b = rgb & 0xFF;
    return (255 - r).abs() <= whiteTolerance &&
        (255 - g).abs() <= whiteTolerance &&
        (255 - b).abs() <= whiteTolerance;
  }

  /// 一条弹幕该不该显示 —— **纯函数**，可单测。
  ///
  /// 判据（全部来自 某视频站那套，逐条对应）：
  /// ```text
  /// ① 该类型的"显示"开关关着 ⇒ 不显示
  /// ② 该类型被"屏蔽类型"勾上 ⇒ 不显示
  /// ③ 文本命中屏蔽词 ⇒ 不显示（正则模式按正则，否则按子串包含）
  /// ④ ★「只显示彩色」开着且这条是白色 ⇒ 不显示
  /// ```
  ///
  /// ⚠️ 正则**编译失败**时按"不匹配"处理（不是"全都屏蔽"）——
  ///    用户敲错一个正则不该让所有弹幕消失。
  static bool shouldShow({
    required DanmakuMode mode,
    required String text,
    int color = 0xFFFFFF,
  }) {
    switch (mode) {
      case DanmakuMode.scroll:
        if (!showScroll || blockScroll) return false;
      case DanmakuMode.top:
        if (!showTop || blockTop) return false;
      case DanmakuMode.bottom:
        if (!showBottom || blockBottom) return false;
    }
    // ④ 「只显示彩色」—— 白色弹幕直接不进渲染队列（也就不占轨道）
    if (colorOnly && isWhiteColor(color)) return false;
    final words = blockWords;
    if (words.isEmpty) return true;
    if (blockRegex) {
      for (final w in words) {
        try {
          if (RegExp(w).hasMatch(text)) return false;
        } catch (_) {
          // 用户的正则写错了 ⇒ 跳过这一条（见上面的说明）
        }
      }
      return true;
    }
    for (final w in words) {
      if (text.contains(w)) return false;
    }
    return true;
  }

  // ---- 写 ----

  static void setEnabled(bool v) => UiPrefs.set(keyEnabled, v ? '1' : '0');

  /// ★★★ 2026-10-14（Owner 反馈「弹弹play的凭证流程根本没走通」）：
  /// 面板上的凭证输入框**恢复**了（见 `danmaku_settings_dialog.dart` 的
  /// `_credentialsSection`）⇒ 这三个写入口重新有了**生产调用者**，
  /// 不再是"只给测试用"。
  ///
  /// 改前它们被标 `@visibleForTesting`，因为 2026-10-11 把输入框整节删了
  /// （当时的设想是"客户端内置凭证、用户不必手填"）。但**本地构建没有
  /// `--dart-define`** ⇒ 没有内置值、`UiPrefs` 也没值 ⇒ 官方那条边必然
  /// 403「弹幕服务没收到凭证」，且**没有入路**把它配起来。
  /// ⇒ 恢复手动写入口，让没有内置凭证的构建也能用。
  ///
  /// # 纪律：用户填的是**他自己的**配置，存 UiPrefs（本机），不进仓库
  /// 落盘的是用户本机数据目录的 `ui-prefs.json`；仓库里仍然**绝无**真实
  /// Secret（内置值只经 `--dart-define` 从 CI Secrets 注入，见 [builtinAppId]）。
  static void setAppId(String v) => _writeTrimmed(keyAppId, v);

  static void setAppSecret(String v) => _writeTrimmed(keyAppSecret, v);

  static void setFontScale(double v) =>
      UiPrefs.set(keyFontScale, _fmt(_clamp(v, fontScaleMin, fontScaleMax)));

  static void setOpacity(double v) =>
      UiPrefs.set(keyOpacity, _fmt(_clamp(v, opacityMin, opacityMax)));

  static void setSpeed(double v) =>
      UiPrefs.set(keySpeed, _fmt(_clamp(v, speedMin, speedMax)));

  static void setArea(double v) =>
      UiPrefs.set(keyArea, _fmt(_clamp(v, areaMin, areaMax)));

  // ---- ★ 2026-10-09 新增项的写 ----

  static void setShowScroll(bool v) => UiPrefs.set(keyScroll, v ? '1' : '0');

  static void setShowTop(bool v) => UiPrefs.set(keyTop, v ? '1' : '0');

  static void setShowBottom(bool v) => UiPrefs.set(keyBottom, v ? '1' : '0');

  /// 写入屏蔽词原文（多行，每行一个）
  static void setBlockWords(String raw) {
    if (raw.trim().isEmpty) {
      UiPrefs.remove(keyBlockWords);
    } else {
      UiPrefs.set(keyBlockWords, raw);
    }
  }

  static void setBlockRegex(bool v) => UiPrefs.set(keyBlockRegex, v ? '1' : '0');

  static void setBlockScroll(bool v) => UiPrefs.set(keyBlockScroll, v ? '1' : '0');

  static void setBlockTop(bool v) => UiPrefs.set(keyBlockTop, v ? '1' : '0');

  static void setBlockBottom(bool v) => UiPrefs.set(keyBlockBottom, v ? '1' : '0');

  /// ★ 2026-10-11：写「只显示彩色弹幕」开关
  static void setColorOnly(bool v) => UiPrefs.set(keyColorOnly, v ? '1' : '0');

  /// 清空凭证（面板上「清除」按钮的动作）。
  ///
  /// ★ 2026-10-14：恢复为生产 API（见 [setAppId] 的说明）—— 面板的
  /// 「清除」按钮调用它，优先级随之回落到内置（若该构建有内置值）。
  /// 只动 UiPrefs，**永远不写 builtin**。
  static void clearCredentials() {
    UiPrefs.remove(keyAppId);
    UiPrefs.remove(keyAppSecret);
  }

  // ---- 展示用 ----

  /// 打码后的 AppId，例 `abcd****`；空则返回空串。
  ///
  /// 只用于"已经配过"的只读回显，**不要**拿它当输入框初值。
  static String get maskedAppId {
    final id = appId;
    if (id.isEmpty) return '';
    if (id.length <= 4) return '****';
    return '${id.substring(0, 4)}****';
  }

  /// 当前配置的一句话状态，给底栏提示 / 对话框标题用
  ///
  /// T27-10：内置凭证生效时给**可区分**的文案 —— 用户要能分清
  /// 「这是客户端自带的」还是「我自己填的」（排错时这是第一件事）。
  static String get statusText {
    if (!enabled) return '弹幕已关闭';
    if (!isConfigured) return '弹幕已开启，但还没填 AppId / AppSecret';
    if (usingBuiltinAppId) return '弹幕已开启（内置凭证 AppId $maskedAppId）';
    return '弹幕已开启（AppId $maskedAppId）';
  }
}

double _readDouble(String key, double def, double lo, double hi) {
  final raw = UiPrefs.get(key);
  if (raw == null || raw.isEmpty) return def;
  final v = double.tryParse(raw);
  if (v == null) return def;
  return _clamp(v, lo, hi);
}

double _clamp(double v, double lo, double hi) {
  if (v.isNaN) return lo;
  if (v < lo) return lo;
  if (v > hi) return hi;
  return v;
}

/// 定点输出（最多 3 位小数，去掉多余的 0），保证落盘字符串稳定可比
String _fmt(double v) {
  var s = v.toStringAsFixed(3);
  if (s.contains('.')) {
    s = s.replaceAll(RegExp(r'0+$'), '');
    s = s.replaceAll(RegExp(r'\.$'), '');
  }
  return s;
}

void _writeTrimmed(String key, String v) {
  final t = v.trim();
  if (t.isEmpty) {
    UiPrefs.remove(key);
  } else {
    UiPrefs.set(key, t);
  }
}

// -----------------------------------------------------------------------
// 客户端
// -----------------------------------------------------------------------

/// 一次取弹幕的完整结果
class DanmakuFetchResult {
  const DanmakuFetchResult({
    required this.comments,
    this.match,
    this.matchedBy = '',
    this.matchMode = '',
  });

  final List<DanmakuComment> comments;

  /// 命中的弹幕库；走 search 退路时也可能是 null
  final DanmakuMatch? match;

  /// `match` 或 `search` —— 报告里要如实说明"这条弹幕是怎么找到的"
  final String matchedBy;

  final String matchMode;

  bool get isEmpty => comments.isEmpty;

  /// 给人看的一句话：`某番 第 3 集 · 842 条弹幕`
  String get summary {
    final m = match;
    final head = m == null ? '弹幕库' : m.label;
    return '$head · ${comments.length} 条弹幕';
  }
}

// -----------------------------------------------------------------------
// 失败之后：告诉用户**下一步做什么**（而不只是"失败了"）
// -----------------------------------------------------------------------
//
// Owner 反馈（2026-10-08，逐字）：「弹幕报错，如图1」，截图里那句话是
// `弹幕失败：Missing Authentication Headers`。
//
// 这句英文是 弹弹play 的原话，**必须原样保留**（它是排错的唯一线索，
// 见文件头"错误必须原文透出"），但光有它用户不知道该干什么 ——
// 实测 Owner 机器上 `dsh.danmaku.appId` / `dsh.danmaku.appSecret` 两个键
// 根本不存在，所以这句话会出现在每一台"还没填凭证"的机器上。
//
// ⇒ 在本文件里把「哪一类失败」判出来，并给出对应的中文动作：
//   · 判据**只认真实读数** —— HTTP 状态码 + `X-Error-Message` 原文；
//   · 不做"消息里含某几个字"这种乱匹配（那是脆的，服务端改一个词就失效）；
//   · UI 只负责显示 [DanmakuHint.text]、把 [DanmakuHint.action] 变成按钮，
//     **不替换** [DanmakuException.message] / [DanmakuException.xErrorMessage]。

/// 提示里附带的一个「按钮」
///
/// 刻意用 bool 而不是回调：本文件是 core 层，不许依赖任何 UI 包
/// （理由见 lib/core/ui_prefs.dart 头部），导航由宿主（播放页）负责。
class DanmakuHintAction {
  const DanmakuHintAction({
    required this.label,
    this.openDanmakuSettings = false,
    this.openBiliSheet = false,
    this.useLocalDanmaku = false,
    this.useOfficialDanmaku = false,
    this.forceLocalDanmaku = false,
  });

  /// 按钮文案
  final String label;

  /// 点了之后打开「弹幕设置」面板
  final bool openDanmakuSettings;

  /// 点了之后打开「外部视频源弹幕」面板
  final bool openBiliSheet;

  /// 点了之后**改用本机外部弹幕**（T27-08）
  ///
  /// 与上面两个开关一样只是「请宿主做某件事」的标记，判据留在这一层：
  /// 只有**本次请求确实走的是官方**（即本机不在线）时才置 true —— 反之
  /// 「本次已经走了本机却还给『改用本机』」是一个**死循环**按钮（T27-14）。
  /// 宿主（player_page）据此重建客户端并重取弹幕 —— 本机源的本地接口
  /// **免签名**，不需要 AppId/AppSecret。
  final bool useLocalDanmaku;

  /// 点了之后**改用官方 API**（T27-14）
  ///
  /// 本次请求**确实走了本机外部弹幕**、而本机却回了 401/403 ⇒ 真正该做的是
  /// **换一条路**（官方 API），而不是再点一次「改用本机」（那会原样复现）。
  /// 宿主据此粘住「强制官方」再重取一次。与 [useLocalDanmaku] 互斥。
  final bool useOfficialDanmaku;

  /// 点了之后**改用本机外部弹幕** —— 与 [useLocalDanmaku] 同一动作，但
  ///   语义不同：`useLocalDanmaku` 是「本机不在线 ⇒ 建议你启动本机再用」，
  ///   而这个是「用户此前点了『改用官方 API』、官方那条边**确实也失败了**
  ///   ⇒ 给一条**回头路**」。
  ///
  /// ★★★ N2（CodeRabbit PR#5）：补它的原因是一个**出口不对称** ——
  ///   A7 修好了「本机失败 ⇒ 能改走官方」，但官方也失败时提示走【第 2 态】，
  ///   而第 2 态的动作只有 openDanmakuSettings / openBiliSheet，
  ///   **没有任何入口**能清掉宿主那颗粘性的「强制官方」标记 ⇒ 文案写着
  ///   「在弹幕设置里选本机」，用户却无处可选，本会话内每次重取都被钉在官方。
  ///   ⇒ 由 [DanmakuHint.of] 的 [DanmakuHint.of.allowUseLocal] 置位，
  ///     宿主消费它与 [useLocalDanmaku] 同一实现（重建客户端 = 真换边）。
  final bool forceLocalDanmaku;
}

/// 「为什么失败 + 怎么办」——一句话解释 + 可选的动作按钮
class DanmakuHint {
  const DanmakuHint({
    required this.title,
    required this.text,
    this.action,
    this.url = '',
  });

  /// 短标题（一句话说清是哪一类问题）
  final String title;

  /// 说人话的解释 + 下一步怎么做
  final String text;

  /// 可选的按钮（null = 不需要按钮）
  final DanmakuHintAction? action;

  /// 可选的官方地址（只有需要用户去申请凭证时才给）
  final String url;

  /// 从一次失败里判出「该告诉用户什么」；判不出来返回 null
  ///
  /// 判据（**全部是真实读数**）：
  /// ```text
  /// HTTP 403/401 + X-Error-Message 含 "Missing Authentication Headers"（或该头为空）
  ///   ⇒ 没填凭证。实测无凭证访问 api.dandanplay.net 就是这个组合。
  /// HTTP 403/401 + 其它 X-Error-Message（Invalid AppId / Signature / Timestamp / AppSecret）
  ///   ⇒ 凭证填了但没通过。
  /// 其余 ⇒ 返回 null，让 UI 只说服务端原文（不猜）。
  /// ```
  ///
  /// ## ★ T27-08（Owner 第 8 条）：「没收到凭证」这一态按**数据源事实**分两支
  ///
  /// 改前只有一句话「去官网免费申请」—— 而业主机器上本机外部弹幕
  /// 就在跑（T27-05 的本地源，**免签名**），叫他去申请凭证是**指向错误**的：
  /// 真正该做的是把这次请求切到本地源。判据只有一个、且来自真实读数。
  ///
  /// ## ★★★ T27-14（CodeRabbit A7）：判据必须是「这次请求**走了哪个源**」，
  ///    不是「本机在不在线」
  ///
  /// ```text
  /// 改前的注入值是 host 的 `usingLocal`，而 host 的选路规则是
  ///   usingLocal = localStatus.online（player_page.dart:5013）
  /// ⇒ 只有「本机在线 ⇒ 本次走了本机 ⇒ 本机又回了 401/403」这一条路能进来。
  ///   这时这段文案写「检测到本机外部弹幕，但当前数据源是官方 API」——
  ///   **与事实完全相反**（这次请求打的就是本机），且按钮「改用本机外部弹幕」
  ///   点了还是打本机 ⇒ 复现同一条失败 ⇒ **死循环**。
  /// 反过来，「本机在线却走了官方」这个组合按自动路由**根本不会出现**。
  /// ```
  ///
  /// ⇒ 入参语义改为 [usedLocalSource] = 「产生这条失败的那次请求**确实走了**
  ///   本机外部弹幕」。它决定的是**换哪条路**，不再是「本机在不在线」：
  ///   · true（本机拒绝了这次请求）⇒ 实话实说 + 「改用官方 API」（真换路）；
  ///   · false（官方拒绝了这次请求）⇒ 老文案（t100/t103/zz_t3 逐字钉着）。
  ///
  /// 刻意**不**在这里自己探测：本函数是**纯函数**（t100/t103 直接调它断言），
  /// 一探测就变成异步 + 依赖网络，那些断言全得跟着改 —— 事实由宿主注入。
  ///
  /// ⚠️ 只有「没填凭证」这一支分两态。凭证填了被拒（Invalid AppId /
  ///    Signature）那一支**一个字都没动**：换哪条源都救不了填错的凭证。
  ///
  /// [usedLocalSource] 缺省 false ⇒ 与改前**逐字同形**的「走的是官方」那一支，
  /// 既有调用方（含 t100/t103）行为不变。
  ///
  /// ## ★★★ N2（CodeRabbit PR#5）：[allowUseLocal] —— 官方那条边也失败时的回头路
  ///
  /// ```text
  /// A7 之后两条边是：本机失败 ⇒ useOfficialDanmaku（改用官方）；官方失败 ⇒ ？
  /// 官方那一支的按钮里没有「改用本机」⇒ 用户只能停在官方，本会话内绕不回来，
  /// 而文案还写着「在弹幕设置里选本机」（面板里其实没有那个控件）。
  /// 这个参数由宿主置位，条件只有一个、且来自真实读数：**本机在线、且用户
  /// 确实点过「改用官方 API」**（即官方这条路被真的走过一次、并失败了）。
  /// ```
  /// ⚠️ 缺省 false ⇒ 与改前**逐字同形**（本机不在线时不给「改用本机」，
  ///    那颗按钮点了必然连不上）。
  static DanmakuHint? of(
    DanmakuException e, {
    bool usedLocalSource = false,
    bool allowUseLocal = false,
  }) {
    final rejected = e.statusCode == 401 || e.statusCode == 403;
    if (!rejected) return null;

    final xe = e.xErrorMessage.trim();
    final lower = xe.toLowerCase();
    final missing = xe.isEmpty || lower.contains('missing authentication');

    if (missing) {
      /*
       * ★ 第 1 态：本次请求**走的是本机外部弹幕**，而本机回了 401/403
       *
       * 这是本机源自己拒绝了请求（它免签名，正常绝不该 401/403）。
       * ⇒ 文案必须**如实**说「本机拒绝了这次请求」，绝不能写「走的是官方 API」
       *   （那是反的）。出路必须是**换一条路**：改用官方 API —— 而不是
       *   再点一次「改用本机」（那正是原缺陷的死循环按钮）。
       */
      if (usedLocalSource) {
        return DanmakuHint(
          title: '本机外部弹幕 拒绝了这次请求',
          text: '这次弹幕是从本机外部弹幕（${DanmakuLocalService.hostPort}）取的，'
              '而它回了 401/403（原文：${xe.isEmpty ? "未提供原因" : xe}）。'
              '本机外部弹幕 的本地接口「免签名」、正常不需要凭证 ⇒ '
              '这个报错多半说明 2080 端口上回应的不是外部弹幕，'
              '或者它的接口版本对不上。'
              '点下面的「改用官方 API」换一条路重取一次'
              '（官方那侧要一对 AppId / AppSecret，'
              '在 https://dev.dandanplay.com 申请）。'
              '也可以先去弹幕设置看看「数据源」状态行。',
          action: const DanmakuHintAction(
            label: '改用官方 API',
            openDanmakuSettings: true,
            useOfficialDanmaku: true,
          ),
          url: 'https://dev.dandanplay.com',
        );
      }
      /*
       * ★ 第 2 态：本次请求走的是官方 API，且没凭证
       *
       * 「去官网免费申请」在这里删掉：本机外部弹幕 这条路不用申请，
       * 先让用户知道有两条路，再让他自己选（默认仍是官方）。
       * ⚠️ 标题保持 '弹幕服务没收到凭证' —— t100:534/551/608 逐字钉着它。
       *
       * ★★★ N2（CodeRabbit PR#5）：[allowUseLocal] = 「官方那条边**确实**
       *   试过并失败了」（本机在线 + 用户点过「改用官方」）。
       *   此时必须补一颗**真正能换回本机**的按钮，否则：
       *     · 文案写「在弹幕设置里选本机」，而面板里**没有**数据源切换控件；
       *     · 清掉宿主那颗粘性「强制官方」标记的唯一入口是「改用本机」，
       *       而这一态的按钮里没有它 ⇒ 用户被永久钉在官方，无路可走。
       *   ⚠️ 默认（allowUseLocal=false，本机压根不在线）**一个字都不加** ——
       *      那时给「改用本机」是点了必然连不上的死按钮（t27_w8 ② 组钉着）。
       */
      return DanmakuHint(
        title: '弹幕服务没收到凭证',
        /*
         * ★★★ 用户可见文案里不许出现具体服务名（Owner 第 11 条，2026-10-18）
         *
         * Owner 原话：
         * > 弹弹play 我说了要让可用的dan-api去替换的,这里的弹幕面板怎么还是弹弹play?
         *
         * 改前这段文案写的是「弹弹play有两个数据源…」——
         * 面板页签已经改名成 dan-api / 插件提供 / 官方兜底 了，
         * 但这条**提示文案**没跟上，用户点进来还是看到旧名字。
         * ⇒ 改成「弹幕服务」，与页签口径一致。
         */
        text: '弹幕服务有两个数据源，在弹幕设置里选一个：'
            '「本机外部弹幕」（本机跑着外部弹幕 就用它，免签名、不用申请任何凭证）'
            '或「官方 API」（它要一对 AppId / AppSecret —— '
            '构建期若已注入则「直接用」；没注入的构建，'
            '在弹幕设置的「凭证」一节「填进去」即可，'
            '或去 doc.dandanplay.com/open 申请一对）。'
            '选好之后点「重新获取弹幕」。'
            '另外：外部站视频可以改用「外部视频源弹幕」直接绑定，不需要这对凭证。',
        action: DanmakuHintAction(
          label: '去弹幕设置',
          openDanmakuSettings: true,
          openBiliSheet: true,
          // ★ N2：只有「官方也失败了」才追加回头路（与上面两个开关并存，
          //   让用户自己选：去看设置 / 换回本机 / 改用 某视频站）。
          forceLocalDanmaku: allowUseLocal,
        ),
        url: 'https://dev.dandanplay.com',
      );
    }

    return DanmakuHint(
      title: '凭证没通过',
      text: '弹幕服务说这次请求的凭证不对（$xe）。'
          '本次请求用的是客户端「内置」的官方凭证；'
          '★ 若要换成你自己的，去弹幕设置的「凭证」一节填一对 AppId / AppSecret'
          '（构建期没注入内置凭证时，那一节就是「唯一」的补救入口）。'
          '也可以改用「本机外部弹幕」（免签名）或「外部视频源弹幕」，'
          '再点「重新获取弹幕」。',
      action: const DanmakuHintAction(label: '去弹幕设置', openDanmakuSettings: true),
      url: 'https://dev.dandanplay.com',
    );
  }

  /// 「拿到的是网页，不是数据」这一类（CDN / 人机校验页）
  ///
  /// 实测：某视频站搜索接口在 Referer 不对时**返回 HTTP 200 + text/html**，
  /// 正文是一张**风控响应页** —— 状态码是 200，最容易骗过
  /// "非 2xx 才报错"的判断，所以这里给一句人话。
  static DanmakuHint htmlPage({required String what}) => DanmakuHint(
        title: '拿到的是网页，不是数据',
        text: '$what这次返回的是一张网页（多半是被人机校验拦了），不是数据。'
            '等几分钟再试一次；一直这样的话，先换成别的片源。',
      );

  @override
  String toString() => 'DanmakuHint($title)';
}

/// 弹弹play 开放弹幕网络客户端
///
/// ## 三步流程（对应官方文档）
/// ```text
/// 1. POST /api/v2/match                   文件名 -> episodeId
/// 2. GET  /api/v2/comment/{episodeId}      episodeId -> 弹幕列表（302 重定向）
/// 3. GET  /api/v2/search/episodes          匹配不到时的退路（按番剧名 + 集数搜）
/// ```
///
/// ## ★ 没配凭证时**照样发请求**
///
/// 这是一个刻意的设计决定：
/// 与其在本地"猜"一个错误提示，不如把请求真发出去、
/// 把服务端返回的 `X-Error-Message` **原文**显示给用户 ——
/// 用户和我们才能区分"没填"（`Missing Authentication Headers`）、
/// "时间戳不对"（`Invalid Timestamp`）、"签名算错"（`Invalid Signature`）
/// 这几种完全不同的情况。本地短路会把这条信息永久埋掉。
///
/// 因此 [isConfigured] 只用来在 UI 上**追加**一句提示，
/// **不**用来阻止请求。
///
/// ═══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-14：测试 / 探针用的**可注入传输**（默认 null = 生产行为）
///
/// # 为什么需要这个缝
/// ```text
/// 「手动搜索番剧」的宿主回调（`player_page._searchDanmaku`）要能被
/// 真渲染测试**确定性地**驱动 —— 否则测试只能真发 HTTP，那是"碰运气"
/// 而不是"测行为"（同 `DanmakuTransport` 存在的理由）。
/// 生产里这个开关**恒为 null** ⇒ 走 `IoDanmakuTransport`，与改前逐字一致。
/// ```
/// ⚠️ 只在测试里由 `debugSetDanmakuTransportForTest` 写入；测试尾部必须
///    用同一个函数传 null 复位（否则会污染同进程里后面的用例）。
/// ═══════════════════════════════════════════════════════════════════════
DanmakuTransport? _debugTransportOverride;

/// 安装 / 清除测试传输（传 null = 恢复生产实现）
void debugSetDanmakuTransportForTest(DanmakuTransport? t) {
  _debugTransportOverride = t;
}

// -----------------------------------------------------------------------
//  内置 dan-api 公共实例（Owner 第 4 条）
// -----------------------------------------------------------------------
//
// Owner 原话（逐字，2026-10-17）：
// ```text
// > 我之前说的dan-api 是让你接入现成的服务,不是让我去填的,或者可以内置上几个
// ```
//
// # 它解决什么
// ```text
// 改前「dan-api」这条路**只有输入框**：地址栏是空的，用户必须先自己
// 部署一份 danmu_api（Node / Docker / Vercel…）才有地址可填。
// ⇒ 对「我就想现在有弹幕」的用户，这条路等于不存在。
//
// 现在：预置几个**已实测可用**的公共实例，默认选中第一个；
//   用户也可以填自己的（覆盖内置）。空着不是失败态，是「用内置的」。
// ```
//
// # ★ 每一条都必须是**实测跑过**的地址（不是占位符）
// ```text
// 实测脚本：`.probe/danmaku_b_builtin_probe.py`
// 判据（两条都要过）：
//   ① GET /<token>/api/v2/search/anime?keyword=火影  → 200 且 animes 非空
//   ② GET /<token>/api/v2/comment/10002?format=json  → 200 且 comments 非空
// 只过 ① 不过 ② 的实例（能搜不能取）**不算可用**，已剔除。
// ```
//
// # ⚠️ 为什么这些地址不能写进「支持某站」的语境
// ```text
// 它们是**弹幕协议服务**（与 `弹弹play` 同类），不是本软件对接的视频网站
// ⇒ 不受 t98 站名门禁约束（该门禁的口径是「对接的具体视频网站」）。
// ⚠️ 但**主机名里不许出现任何视频站名** —— 那是另一回事，会被 t98 抓。
// ```
//
// # ⚠️ 公共实例的**现实**：会挂、会慢、会被封
// ```text
// 实测 2026-10-17 深夜（本机）：
//   · 3 个候选里只有 1 个两条判据全过；另两个「能搜不能取」
//   · 单次 search 3.7~6.5 s（serverless 冷启动），comment 取 2102 条约 12 s
// ⇒ 所以：
//   ① 内置**不是**「一定好用」的承诺，UI 必须给「测试连接」让用户自己验
//   ② 选中内置实例 ⇒ 仍走**用户可覆盖**的同一对偏好键（dsh.danmaku.endpoint
//      / .token），不是另开一套 —— 否则「改了没生效」又是一处接线坑
//   ③ 一个都不通时如实回退（本机 2080 → 官方），不假装成功
// ```
class DanmakuPublicInstance {
  const DanmakuPublicInstance({
    required this.baseUrl,
    required this.token,
    required this.label,
  });

  /// 基址（不含 token 前缀），如 `https://xxx.vercel.app`
  final String baseUrl;

  /// 路径前缀 token。danmu_api 的默认 token 是 `87654321`，
  /// 这类公共部署**保留默认值** ⇒ 必须带上（不带就是 401，实测过）。
  final String token;

  /// 给用户看的短名（**中性词**：不带任何站名）
  final String label;

  /// 拼成 [DanmakuEndpoint] 能直接吃的完整地址
  String get endpointUrl => baseUrl;

  @override
  String toString() => '$label（$baseUrl）';
}

/// 预置的公共 dan-api 实例表（**按实测可用性排序，第一个默认选中**）
///
/// ⚠️ 加新条目之前必须先用 `.probe/danmaku_b_builtin_probe.py` 跑一遍，
///    并把读数写进提交信息 —— 没实测过的地址**不许**进这张表。
const List<DanmakuPublicInstance> kDanmakuPublicInstances =
    <DanmakuPublicInstance>[
  DanmakuPublicInstance(
    baseUrl: 'https://danmu-api-delta.vercel.app',
    token: '87654321',
    label: '公共实例 A',
  ),
  DanmakuPublicInstance(
    baseUrl: 'https://danmu-api-kappa.vercel.app',
    token: '87654321',
    label: '公共实例 B',
  ),
];

/// 用户配置的弹幕后端（自建服务，如 danmu_api）
///
/// ══════════════════════════════════════════════════════════════════════
/// # 为什么需要它
/// ══════════════════════════════════════════════════════════════════════
/// 改前 [ExternalDanmakuClient] 只有**两条写死**的路：
/// ```text
/// unsignedLocal = true   → http://127.0.0.1:2080（弹弹play 桌面版，免签名）
/// unsignedLocal = false  → https://api.dandanplay.net（官方，要签名）
/// ```
/// 两者都是 `static const` ⇒ 用户**没法**填一个自己部署的地址。
/// 而自建弹幕服务（danmu_api 这类）是免凭证的第三方实现，
/// 正好能解决「官方要凭证、本仓又没凭证」的死结。
///
/// # 协议契约（实测确认，2026-10-16）
/// ```text
/// 该后端与弹弹play **协议同构**：/api/v2/{search/anime,search/episodes,
/// match,bangumi,comment} 的请求/响应形状一致 ⇒ 解析层零改动。
/// 实测把返回的 10157 条弹幕喂给 DanmakuComment.parse：10157/10157 通过。
/// ```
///
/// ⚠️ 该模式下**不发签名头**：这类自建服务默认免凭证。
///    若将来要接「需要签名的自建弹弹play」，需另开参数（本类当前不覆盖）。
class DanmakuEndpoint {
  const DanmakuEndpoint({required this.baseUrl, this.token = ''});

  /// 基址，如 `http://127.0.0.1:9321`（不带协议时按 http 处理）
  final String baseUrl;

  /// 可选 token。
  ///
  /// 某些自建服务把 token 放在**路径前缀**上（`/{token}/api/v2/…`），
  /// 例如 danmu_api：默认 token `87654321` 时可不带，自定义后必须带。
  /// 空串 = 不带前缀。
  final String token;

  /// 解析用户输入；不可用（空/无主机）时返回 null。
  ///
  /// 刻意**不抛异常** —— 用户填错一个地址不该让取弹幕这条路崩掉，
  /// 而是安静地退回内置的官方/本机路径（同 [DanmakuSourceSelector] 的纪律）。
  static DanmakuEndpoint? tryParse(String baseUrl, {String token = ''}) {
    final e = DanmakuEndpoint(baseUrl: baseUrl.trim(), token: token.trim());
    return e.isUsable ? e : null;
  }

  Uri? get _base {
    final raw = baseUrl.trim();
    if (raw.isEmpty) return null;
    // 允许用户只填 `127.0.0.1:9321`（不带协议）
    final withScheme = raw.contains('://') ? raw : 'http://$raw';
    final u = Uri.tryParse(withScheme);
    if (u == null || u.host.isEmpty) return null;
    return u;
  }

  bool get isUsable => _base != null;

  String get scheme => _base?.scheme ?? 'http';
  String get host => _base?.host ?? '';
  bool get hasPort => _base?.hasPort ?? false;
  int get port => _base?.port ?? 0;

  /// 把一条协议路径拼成完整请求 URI（自动带 token 前缀）
  Uri resolve(String path, [Map<String, String>? query]) => Uri(
    scheme: scheme,
    host: host,
    port: hasPort ? port : null,
    path: prefixedPath(path),
    queryParameters: (query == null || query.isEmpty) ? null : query,
  );

  /// 把 token 前缀拼进路径（空 token 时原样返回）
  String prefixedPath(String path) {
    final t = token.trim();
    final p = path.startsWith('/') ? path : '/$path';
    return t.isEmpty ? p : '/$t$p';
  }

  /// 归一化后的展示串（给状态行用；**不含 token**，避免把它显示出来）
  String get display =>
      isUsable ? '$scheme://$host${hasPort ? ':$port' : ''}' : '';

  @override
  String toString() =>
      'DanmakuEndpoint($display${token.isEmpty ? '' : ' +token'})';
}

class ExternalDanmakuClient {
  ExternalDanmakuClient({
    DanmakuTransport? transport,
    String? appId,
    String? appSecret,
    DateTime Function()? clock,
    bool unsignedLocal = false,
    DanmakuEndpoint? endpoint,
  })  : _transport = transport ??
            _debugTransportOverride ??
            IoDanmakuTransport(
              // ★ 接线点 ①：弹幕客户端默认传输层
              //   读用户的代理选择（UiPrefs）⇒ 用户不选就是 direct。
              findProxy: currentDanmakuFindProxy(),
            ),
        _appId = appId ?? DanmakuConfig.appId,
        _appSecret = appSecret ?? DanmakuConfig.appSecret,
        _clock = clock ?? DateTime.now,
        _unsignedLocal = unsignedLocal,
        _endpointExplicit = endpoint;

  /// 弹弹play后端的**默认**主机名（客户端要连的 API 端点）。
  ///
  /// ⚠️ 这是"实现细节"（客户端默认后端），**不是**"产品在宣传某个站"。
  ///   它**可被覆盖**：`DanmakuConfig` 的 appId/appSecret 已有 UiPrefs 覆盖链，
  ///   端点本身也可由构建期 `--dart-define` / 运行时配置替换（见上层配置）。
  ///   ⇒ 删掉或换成假域名会让弹幕功能**静默失效**，所以保留真实默认值；
  ///     仓库里不含任何"支持某站"的文案。
  static const String host = 'api.dandanplay.net';

  /// 本机外部弹幕（弹弹play 协议的本地实例）——本地接口**免签名**
  static const String localAuthority = '127.0.0.1:2080';

  /// `fileHash` 拿不到时的匹配模式（见文件头"拿不到 fileHash 的现实"）
  static const String defaultMatchMode = 'fileNameOnly';

  final DanmakuTransport _transport;
  final String _appId;
  final String _appSecret;
  final DateTime Function() _clock;

  /// true ⇒ 打本机外部弹幕（127.0.0.1:2080，http、免签名）。
  /// false ⇒ 官方 api.dandanplay.net（https、签名），行为与改前逐字一致。
  final bool _unsignedLocal;

  /// **显式**传入的自建后端（构造参数）。null = 没显式传。
  ///
  /// ⚠️ 与 [_endpoint] 分开：这个只在构造时定一次，[_endpoint] 每次请求
  ///    重新解析用户偏好（见那里的说明）。测试注入走这个。
  final DanmakuEndpoint? _endpointExplicit;

  /// 本次请求实际要打的自建后端。
  ///
  /// # 为什么每次请求重新解析（而不是构造时快照一次）
  /// ```text
  /// 构造快照（改前的做法）有个真实代价：用户刚在面板里填好地址、
  /// 点「测试连接」成功，可**正在用的客户端**还拿着旧值 ⇒ 地址改了等于没改，
  /// 除非宿主记得 close + 重建。而「记得重建」是容易漏的接线
  /// （player_page 里就有 _resetDanmakuClient 这类补丁），
  /// 正确性不该依赖调用方记得重置。
  /// ```
  ///
  /// # 优先序（★ Owner 第 7 条改：dan-api 优先于本机弹弹play）
  /// ```text
  /// ① 显式传入的 endpoint      → 用它（测试注入 / 调用方明确指定）
  /// ② 用户**配了** dan-api      → 用它（即使宿主说要走本机）
  /// ③ unsignedLocal = true     → 返回 null，走本机 2080
  /// ④ 否则                     → 官方
  /// ```
  ///
  /// # ★★★ ② 为什么必须排在 ③ 前面（真缺陷，Owner 亲口报的）
  /// ```text
  /// Owner 原话：
  /// > 配置页没看到,既然弹弹play不行,就换成dan-api
  ///
  /// 改前是 ③ 在前：
  ///   宿主探到本机弹弹play 在线 ⇒ unsignedLocal = true
  ///   ⇒ 本 getter 走到 `if (_unsignedLocal) return null`
  ///   ⇒ **用户配的 dan-api 地址被完全忽略**
  /// 于是「本机弹弹play 一在线，dan-api 就永远轮不到」——
  /// 用户明明填了地址、点测试也通了，取弹幕却还在打 2080。
  /// ```
  ///
  /// ⚠️ 为什么这不是「无视宿主的选路」：宿主那次选路（player_page）
  ///    只看得到「本机 2080 在不在线」，**看不到**用户有没有配 dan-api ——
  ///    它没有做这个判断所需的信息。配置的归属在用户，
  ///    而「用户显式配了地址」是比「本机恰好有个服务」更强的意图。
  /// ⚠️ 用户点过「改用官方 API」时**不受影响**：那条路走的是
  ///    `_danmakuForceOfficial`（宿主侧的显式开关），不经过本 getter 的 ②。
  ///
  /// null ⇒ 完全退回内置的官方/本机路径，行为与没有这个功能时逐字一致。
  DanmakuEndpoint? get _endpoint {
    final explicit = _endpointExplicit;
    if (explicit != null) return explicit;
    /*
     * ★★ ② 配了 dan-api ⇒ 用它，**即使**宿主说要走本机 2080
     *
     * 见上方「② 为什么必须排在 ③ 前面」。判据是「配了」而不是
     * 「探通了」—— 探通与否由宿主那次 probe 决定，而它探的可能是 2080。
     * 这里只负责「用户的意思优先」；真的连不上会由请求自己失败，
     * 并且宿主有一条「改用官方」的回头路。
     */
    final configured = DanmakuConfig.danmakuEndpoint;
    if (configured != null) return configured;

    /*
     * ③ 本机弹弹play（宿主探通了才会把 `_unsignedLocal` 置真）
     *
     * ⚠️ 顺序很要紧：**内置公共实例排在它后面**。
     * ```text
     * 本机 2080 是本机进程：零网络、毫秒级、不过公网。
     * 内置实例是公网 serverless：冷启动 3~6 s。
     * ⇒ 本机活着就必须让本机赢 —— 内置是**兜底**，不是抢占。
     * ```
     * 改前这里是 `if (_unsignedLocal) return null;` 然后无条件 `return null;`
     * （官方）。现在把「内置」插在两者之间。
     */
    if (_unsignedLocal) return null;

    /*
     * ★★★ ④ 内置公共实例（Owner 第 4 条）
     *
     * ```text
     * 走到这里说明：用户没填地址、本机 2080 也没起来。
     * 改前 ⇒ 直接掉到官方（要 AppId/AppSecret 签名，本仓没凭证 ⇒ 必然失败）。
     * 现在 ⇒ 用内置的公共实例，**开箱就有弹幕**。
     * ```
     * Owner 原话：「不是让我去填的,或者可以内置上几个」——
     * 没填**不等于**没有。
     *
     * ⚠️ 内置只是默认值：用户一填就压过它（同凭证那条覆盖链）。
     * ⚠️ 官方/签名那条边的用例靠 `debugSetPublicInstances(const [])`
     *    把内置关掉，否则它们测的是内置实例（假绿）。
     */
    return DanmakuConfig.publicInstanceEndpoint;
  }

  /// 本次是否走「免签名」路径（自建后端 / 本机弹弹play / 内置公共实例）
  bool get _signatureFree => _endpoint != null || _unsignedLocal;

  /// 本次生效的是**内置**公共实例（不是用户填的）—— 面板要如实区分
  bool get usingBuiltinPublicInstance =>
      _endpointExplicit == null &&
      DanmakuConfig.danmakuEndpoint == null &&
      !_unsignedLocal &&
      DanmakuConfig.publicInstanceEndpoint != null;

  bool get isConfigured => _appId.isNotEmpty && _appSecret.isNotEmpty;

  /// 当前 UTC 秒 —— 签名里的 `Timestamp` 要求是 UTC Unix 秒
  int get _nowSeconds => _clock().toUtc().millisecondsSinceEpoch ~/ 1000;

  /// 构造请求 URI
  ///
  /// 三条路（优先级从高到低）：
  /// ```text
  /// ① endpoint 非空    → 用户自建后端（协议/主机/端口由用户填的地址决定）
  /// ② unsignedLocal    → 本机弹弹play（127.0.0.1:2080，http、免签名）
  /// ③ 默认             → 官方 api.dandanplay.net（https、签名）
  /// ```
  /// ★ ① 与 ② 都不发签名头（见 [_authHeaders]）。
  Uri _uri(String path, [Map<String, String>? query]) {
    final q = (query == null || query.isEmpty) ? null : query;
    final ep = _endpoint;
    if (ep != null) {
      // 自建后端：协议/主机/端口全部来自用户配置，路径带上可选 token 前缀
      return Uri(
        scheme: ep.scheme,
        host: ep.host,
        port: ep.hasPort ? ep.port : null,
        path: ep.prefixedPath(path),
        queryParameters: q,
      );
    }
    return _unsignedLocal
        ? Uri.http(localAuthority, path, q)
        : Uri.https(host, path, q);
  }

  /// 构造鉴权头
  ///
  /// 签名 = `base64(sha256(AppId + Timestamp + Path + AppSecret))`，
  /// 其中 Path **以斜杠开头、不含协议/域名/查询参数**。
  /// 文档建议 Path 全小写、不做 URL 编码 —— 这里按文档来。
  Map<String, String> _authHeaders(String path) {
    // 免签名路径（自建后端 / 本机弹弹play）：只带 Accept，**绝不**发签名三件套
    // （发了反而可能被这类服务当非法头处理）。
    // ★ 自建服务默认免凭证 —— 这正是它能替代官方路（要 AppId/Secret）的原因。
    if (_signatureFree) {
      return <String, String>{'Accept': 'application/json'};
    }
    final ts = _nowSeconds;
    final p = path.toLowerCase();
    final sig = sha256Base64('$_appId$ts$p$_appSecret');
    return <String, String>{
      'X-AppId': _appId,
      'X-Timestamp': '$ts',
      'X-Signature': sig,
      'Accept': 'application/json',
    };
  }

  /// 请求地址的**脱敏形态** —— 只用于异常里记录/展示，**绝不**用于发请求。
  ///
  /// # 为什么必须脱敏（CWE-532：敏感信息进日志）
  /// ```text
  /// 自建后端把 token 放在**路径前缀**上（见 [DanmakuEndpoint.prefixedPath]）
  /// ⇒ 完整 URI 形如 http://host:9321/<token>/api/v2/comment/9527
  /// 而 [DanmakuException.uri] 会进 `detail` / `toString()`，异常又会显示给用户、
  /// 也进日志 ⇒ **token 明文泄露**。
  /// ```
  ///
  /// # 判据为什么用**结构**而不是比对 `_endpoint.token`
  /// ```text
  /// 本客户端所有协议路径都以 /api 开头（各处 `const path = '/api/v2/…'`）
  /// ⇒ 路径第一段不是 `api` 时，它就是 token 前缀。
  ///
  /// ⚠️ 刻意**不**拿 `_endpoint.token` 去比：请求在途时用户可能改了地址
  ///    （见 _probeSeq 那条竞态的同类窗口）——那时 `_endpoint` 已指向新 token，
  ///    而这条 URI 上带的还是**旧** token ⇒ 比对会放行，**漏脱敏**。
  ///    结构判据没有这个时间窗口。
  /// ```
  ///
  /// ⚠️ 过度脱敏是**安全方向**的取舍：宁可多打一段码，也不能漏一个 token。
  String _safeUri(Uri u) {
    final segs = u.pathSegments;
    if (segs.length < 2 || segs.first == 'api') return u.toString();
    return u.replace(pathSegments: <String>['***', ...segs.skip(1)]).toString();
  }

  /// 从一次 [SocketException] 里取出**它连的那个地址**（空串 = 取不到）
  ///
  /// ⚠️ 取不到就**如实返回空串**，不猜、不回填 —— 上层据此知道
  ///    「这次没有地址证据」，不会拿空串去跑伪造段判据。
  ///
  /// ⚠️ `SocketException.address` 的类型是 `InternetAddress`，
  ///    不同平台可能是 IPv4 或 IPv6 ⇒ 取它的 `address` 字段（裸串），
  ///    上层的判据对两种都成立（IPv6 花样段就是靠这个进来的）。
  static String _addressOf(SocketException e) {
    final a = e.address;
    if (a == null) return '';
    // ★★ 2026-10-19（Lead 修自审 P1-3）：用 `a.address`（裸 IP），
    //   **不要**用 `a.toString()` ——
    //
    // ```dart
    // InternetAddress.tryParse('74.86.17.48')!.toString()
    //   ⇒ "InternetAddress('74.86.17.48', IPv4)"   ← Dart 的调试表示！
    // InternetAddress.tryParse('74.86.17.48')!.address
    //   ⇒ "74.86.17.48"                             ← 裸 IP
    // ```
    //
    // ⇒ 这串会进 `DanmakuProbeReport.detail`，而 detail 在面板里是
    //   **用户可见**的（monospace 那段）⇒ 用户会看到 `InternetAddress(...)`
    //   这种开发者写法。同文件 `_diagnose` 用的就是 `a.address`，那才是对的。
    //
    // ⚠️ IPv6 同样正确：`a.address` 对 IPv6 返回不带方括号的裸地址，
    //   与 `looksForged` 的字面判据口径一致。
    return a.address;
  }

  /// 发一次请求，并把**网络层异常**翻译成带打码地址的 [DanmakuException]。
  ///
  /// # 为什么必须有这一层（CWE-532 的**第二个口子**）
  /// ```text
  /// 上一轮修的是 _decode 里那 6 处（响应到手之后、解析失败时）。
  /// 但 _transport.send 本身还会**抛异常**（网络层），而它抛的是
  /// HttpException / SocketException / TimeoutException ——
  /// ★ 这三者**都不是 DanmakuException** ⇒ 它们**绕过 _decode** 直接冒到上层。
  ///
  /// 实测（2026-10-17）：
  ///   SocketException.toString() = SocketException: failed, address = 127.0.0.1, port = 9321
  ///   HttpException.toString()   = HttpException: bad, uri = http://…/<token>/api/v2/…
  ///                                  ↑ 这条**逐字带 URI**（SDK 行为）
  /// ⇒ 打码必须在这一层做，_safeUri 帮不上忙（异常还没被我们构造出来）。
  /// ```
  ///
  /// # 上层怎么用它（证明这不是防御性代码而是真链路）
  /// ```text
  /// player_page.dart 的取弹幕失败分支：
  ///   on DanmakuException catch (e) ⇒ 写进 _danmakuError / _flash
  ///   catch (e)                     ⇒ DanmakuException(e.toString()) ⇒ ★ 原文进 UI
  /// ⇒ 未翻译的网络异常会把带 token 的 URI 显示给用户、也写进日志。
  /// ```
  ///
  /// # ⚠️ 三种网络异常要**区分**，不能一律同一句话
  /// ```text
  /// 用户据此判断「该重试」还是「该改配置」：
  ///   超时      ⇒ 服务慢/网络差 ⇒ 重试有意义
  ///   连不上    ⇒ 地址填错/服务没起 ⇒ 该去改配置
  ///   协议错    ⇒ 地址不是这个服务 ⇒ 该去改配置
  /// ```
  Future<DanmakuHttpResponse> _send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    try {
      return await _transport.send(
        method: method,
        uri: uri,
        headers: headers,
        body: body,
      );
    } on TimeoutException {
      throw DanmakuException(
        '弹幕服务没有响应（超时）。可以稍后重试。',
        // statusCode 0 = 还没拿到响应（同 DanmakuException 的既有约定）
        uri: _safeUri(uri),
      );
    } on SocketException catch (e) {
      /*
       * ★★★ 2026-10-19（R3-③/⑦ 收尾）：**把解析到的地址带出去**。
       *
       * # 为什么（这是本轮唯一新增的信号，来源是实测）
       * ```text
       * 改前：catch (e) 丢掉异常本体，UI 只拿到一句
       *       「连不上弹幕服务（地址不通或服务没起来）」。
       *       ⇒ 本机 DNS 被劫持到伪造段时，UI **无法**把
       *         "被劫持" 与 "服务没起来" 分开 —— 它只看到"连不上"。
       *
       * `SocketException.address` 是**已经解析出来、并且连不上的那个 IP**
       * （本机实测：连 74.86.17.48 超时 ⇒ address 就是它）。
       * ⇒ 它就是那条"本机拿到的地址"，正是判据需要的输入。
       *
       * # 为什么这样就够，不需要在 UI 上再联网探测
       * ```text
       * 判据 `DanmakuProbeReport.looksForged` 是**纯函数**（查已知伪造段表）。
       * 喂它这个 address 即可 ⇒ 失败路径上**零新增网络请求**。
       * ⚠️ 这**不是**新增依赖：`address` 本来就在异常里，语义与本文件
       *    既有的 `uri` 字段一致（都只做展示，都不打码 token）。
       * ⚠️ 但它**只覆盖"连不上"那一支**（抛到了 SocketException）。
       *    超时（TimeoutException）分支拿不到地址 ⇒ 那一支仍由
       *    `_diagnose` 的 DoH 对照兜底（见 DanmakuProbeReport.dohLookup）。
       */
      throw DanmakuException(
        '连不上弹幕服务（地址不通或服务没起来）。请检查地址 / 服务是否在运行。',
        uri: _safeUri(uri),
        resolvedAddress: _addressOf(e),
      );
    } on HttpException {
      /*
       * ⚠️ **不要**把 e.message 拼进文案：
       *    HttpException.message 可能由 SDK 生成、也可能带上原始 URI，
       *    拼进来就等于把刚打掉的码又加回去。只保留「协议层出错」这个结论。
       */
      throw DanmakuException(
        '弹幕服务返回了不合法的响应（协议错误）。请确认这个地址是弹幕服务。',
        uri: _safeUri(uri),
      );
    }
  }

  /// 把一次响应翻译成"要么是数据、要么是带原文的异常"
  ///
  /// ⚠️ 记录到异常里的地址一律走 [_safeUri]（去掉 token 前缀），
  ///    但**请求本身**用的仍是原始 [uri] —— 两件事不能混。
  Map<String, dynamic> _decode(DanmakuHttpResponse r, String what, Uri uri) {
    if (r.statusCode == 403 || r.statusCode == 401) {
      final xe = r.xErrorMessage;
      final e = DanmakuException(
        xe.isEmpty ? '弹幕服务拒绝了这次请求（HTTP ${r.statusCode}）' : '弹幕服务拒绝了这次请求：$xe',
        statusCode: r.statusCode,
        xErrorMessage: xe,
        body: _clip(r.body),
        uri: _safeUri(uri),
      );
      // ★ 原文照旧（上面那个 message），额外挂一句"下一步做什么"
      throw DanmakuException(
        e.message,
        statusCode: e.statusCode,
        xErrorMessage: e.xErrorMessage,
        body: e.body,
        uri: e.uri,
        hint: DanmakuHint.of(e),
      );
    }
    if (!r.isOk) {
      throw DanmakuException(
        '弹幕服务返回 HTTP ${r.statusCode}',
        statusCode: r.statusCode,
        xErrorMessage: r.xErrorMessage,
        body: _clip(r.body),
        uri: _safeUri(uri),
        // 412/429 是"被限流"，不是"坏了" —— 用户该做的是等一下
        hint: r.statusCode == 412 || r.statusCode == 429
            ? const DanmakuHint(
                title: '被弹幕服务限流了',
                text: '短时间内请求太多次了，等几分钟再点一次「重新获取弹幕」。',
              )
            : null,
      );
    }
    // ★ HTTP 200 但正文是网页 —— 实测 某视频站搜索接口在 Referer 不对时就是这样
    //   （200 + text/html 的**风控响应页**）。不判这个的话，
    //   用户会看到一句没头没脑的"返回的不是 JSON"。
    if (_looksLikeHtml(r.body)) {
      throw DanmakuException(
        '弹幕服务返回的是一张网页，不是数据（$what）',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: _safeUri(uri),
        hint: DanmakuHint.htmlPage(what: what),
      );
    }
    Object? parsed;
    try {
      parsed = jsonDecode(r.body);
    } catch (e) {
      throw DanmakuException(
        '弹幕服务返回的不是 JSON（$what）',
        statusCode: r.statusCode,
        xErrorMessage: r.xErrorMessage,
        body: _clip(r.body),
        uri: _safeUri(uri),
      );
    }
    if (parsed is! Map<String, dynamic>) {
      throw DanmakuException(
        '弹幕服务返回的 JSON 结构不对（$what）',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: _safeUri(uri),
      );
    }
    // 业务错误：HTTP 200 + success:false + errorCode/errorMessage
    if (parsed['success'] == false) {
      final code = _asInt(parsed['errorCode']) ?? 0;
      final msg = parsed['errorMessage']?.toString() ?? '';
      throw DanmakuException(
        msg.isEmpty ? '弹幕服务报错（errorCode $code）' : '弹幕服务报错：$msg',
        statusCode: r.statusCode,
        errorCode: code,
        errorMessage: msg,
        body: _clip(r.body),
        uri: _safeUri(uri),
      );
    }
    return parsed;
  }

  /// 1) 按文件名匹配弹幕库
  ///
  /// `fileName` 按官方要求**不含文件夹和扩展名**，由调用方负责裁剪。
  /// `fileHash` / `fileSize` 本项目拿不到（播放地址是流），留空即可，
  /// 同时把 `matchMode` 设成 `fileNameOnly` 免得服务端白算一遍 hash。
  Future<List<DanmakuMatch>> match({
    required String fileName,
    String fileHash = '',
    int fileSize = 0,
    int videoDuration = 0,
    String matchMode = defaultMatchMode,
  }) async {
    const path = '/api/v2/match';
    final uri = _uri(path);
    final payload = <String, dynamic>{
      'fileName': fileName,
      'fileHash': fileHash,
      'fileSize': fileSize,
      'videoDuration': videoDuration,
      'matchMode': matchMode,
    };
    final headers = _authHeaders(path);
    headers['Content-Type'] = 'application/json; charset=utf-8';
    final resp = await _send(
      method: 'POST',
      uri: uri,
      headers: headers,
      body: jsonEncode(payload),
    );
    final j = _decode(resp, '匹配弹幕库', uri);
    final raw = j['matches'];
    final out = <DanmakuMatch>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is Map<String, dynamic>) {
          final m = DanmakuMatch.fromJson(e);
          if (m != null) out.add(m);
        }
      }
    }
    return out;
  }

  /// 2) 取某个弹幕库的全部弹幕
  ///
  /// ★ 官方 swagger 里这个接口**唯一**的响应码是 **302**，
  /// 所以传输层必须跟随重定向（[IoDanmakuTransport] 默认跟随）。
  /// 用 `dart:io` 直接发而不跟随的话，永远只能拿到一个空的重定向响应。
  Future<List<DanmakuComment>> fetchComments(
    int episodeId, {
    bool withRelated = true,
    int chConvert = 0,
    double shift = 0,
  }) async {
    final path = '/api/v2/comment/$episodeId';
    final uri = _uri(path, <String, String>{
      'withRelated': withRelated ? 'true' : 'false',
      if (chConvert != 0) 'chConvert': '$chConvert',
    });
    final resp = await _send(
      method: 'GET',
      uri: uri,
      headers: _authHeaders(path),
    );
    final j = _decode(resp, '获取弹幕', uri);
    return _parseComments(j, shift: shift);
  }

  /// 3) 退路：按番剧名 / 集数搜索剧集
  ///
  /// 用在"文件名匹配不到"的时候（本地文件名常常是 `第03集` 这种），
  /// 用户也可以手动输入番剧名来搜。
  Future<List<DanmakuMatch>> searchEpisodes({
    String anime = '',
    String episode = '',
  }) async {
    /*
     * ★ 2026-10-17：空关键词**不发请求**（Lead 裁决：收紧这条存量缺陷）。
     *
     * # 为什么（实测 danmu_api，2026-10-16）
     * ```text
     * GET /api/v2/search/episodes              → HTTP 400 Missing anime parameter
     * GET /api/v2/search/episodes?episode=1    → HTTP 400 Missing anime parameter
     * GET /api/v2/search/episodes?anime=火影   → HTTP 200
     * ```
     * 一个**没有任何关键词**的搜索请求本来就没有意义：发出去只是
     * 浪费一次往返 + 换回一个 400，再被 _decode 包成异常抛给上层。
     *
     * # 为什么返回空列表而不是抛错
     * 语义是「这个后端没得搜」；对调用方而言它与「搜了但没有」**同路**：
     * [loadFor] 随后统一走 found.isEmpty 分支抛「没有匹配到弹幕库」，
     * 错误文案与改前**逐字一致**（t100 / task13 逐字钉着它）。
     * ⇒ 不会出现「静默空结果被误当成没有弹幕」：该抛的地方照样抛。
     *
     * ⚠️ 与 [searchEpisodesSmart] 的 `kws.isEmpty` 守卫同一条纪律 ——
     *    那条早就在了，这里只是把同一个判据补到直接调用入口。
     */
    if (anime.trim().isEmpty && episode.trim().isEmpty) {
      return const <DanmakuMatch>[];
    }
    const path = '/api/v2/search/episodes';
    final uri = _uri(path, <String, String>{
      if (anime.isNotEmpty) 'anime': anime,
      if (episode.isNotEmpty) 'episode': episode,
    });
    final resp = await _send(
      method: 'GET',
      uri: uri,
      headers: _authHeaders(path),
    );
    final j = _decode(resp, '搜索剧集', uri);
    final animes = j['animes'];
    final out = <DanmakuMatch>[];
    if (animes is List) {
      for (final a in animes) {
        if (a is! Map<String, dynamic>) continue;
        final title = a['animeTitle']?.toString() ?? '';
        final animeId = _asInt(a['animeId']);
        /*
         * 2026-10-15 (Owner asked for covers): this endpoint has no image,
         * so fetch the poster from /api/v2/bangumi/{animeId}.
         *
         * Two things worth knowing:
         *   · verified live -- animes[] here carries only animeId,
         *     animeTitle, type, typeDescription, episodes. There is no
         *     imageUrl anywhere in this response.
         *   · that endpoint also returns the episode list, so this is ONE
         *     extra request per work, not per episode.
         *
         * Failures are swallowed on purpose: a missing poster must never
         * break search (it is decoration, the episode list is the point).
         */
        var cover = '';
        if (animeId != null && animeId > 0) {
          cover = await _fetchCover(animeId);
        }
        final eps = a['episodes'];
        if (eps is! List) continue;
        for (final e in eps) {
          if (e is! Map<String, dynamic>) continue;
          final id = _asInt(e['episodeId']);
          if (id == null || id <= 0) continue;
          out.add(DanmakuMatch(
            episodeId: id,
            animeTitle: title,
            episodeTitle: e['episodeTitle']?.toString() ?? '',
            cover: cover,
          ));
        }
      }
    }
    return out;
  }

  /// 智能搜索：把标题切成多个关键词分别搜，合并去重后按相似度排序
  ///
  /// # 为什么不能只搜一次（实测，2026-10-15）
  /// ```text
  /// 官方搜索是模糊的：把「无职转生Ⅲ ～到了异世界就拿出真本事～ 第1话 燃烧吧，狂犬」
  /// 整串嗂进去 ⇒ **0 个作品**，而作品 14758/15954/17236/18104/18727 全在库里、
  /// 18727 的第1话有 2709 条弹幕 ⇒ 弹幕在，是搜的词不对。
  /// ```
  ///
  /// # 合并后还要排序
  /// ```text
  /// 不同关键词会吐出不同的作品集（有些是**前传/副本/剪辑版**）。
  /// 按与原标题的相似度排，并**将同作品的集聚在一起** ⇒
  /// 用户看到的第一条就是最可能的那一部。
  /// ```
  ///
  /// ⚠️ 单个关键词失败（网络/限流）**不中断**：只要任一个关键词有结果就返回；
  ///    全部失败才把最后一个异常抛出去（否则会把一个偶发网络错误
  ///    演成“搜不到这部番”，那是假因果）。
  Future<List<DanmakuMatch>> searchEpisodesSmart(String title) async {
    final kws = danmakuSearchKeywords(title);
    if (kws.isEmpty) return const <DanmakuMatch>[];
    final seen = <int, DanmakuMatch>{};
    Object? lastErr;
    var anyOk = false;
    for (final kw in kws) {
      try {
        final got = await searchEpisodes(anime: kw);
        anyOk = true;
        for (final m in got) {
          // 同一 episodeId 只留一次（不同关键词会重复命中）
          seen.putIfAbsent(m.episodeId, () => m);
        }
      } catch (e) {
        lastErr = e;
      }
    }
    if (!anyOk && lastErr != null) throw lastErr;

    final list = seen.values.toList();
    if (list.length <= 1) return list;
    // 排序：先比作品名相似度；同题者按**集**号稳定排序
    final epHint = danmakuEpisodeHint(title);
    list.sort((a, b) {
      final sa = danmakuTitleScore(a.animeTitle, title);
      final sb = danmakuTitleScore(b.animeTitle, title);
      if (sa != sb) return sb.compareTo(sa);
      if (epHint.isNotEmpty) {
        final ea = a.episodeTitle.contains(epHint) ? 1 : 0;
        final eb = b.episodeTitle.contains(epHint) ? 1 : 0;
        if (ea != eb) return eb.compareTo(ea);
      }
      return a.episodeId.compareTo(b.episodeId);
    });
    return list;
  }
  /// Poster URL for a work, or '' when unavailable.
  ///
  /// 2026-10-15: lives on /api/v2/bangumi/{animeId} as `bangumi.imageUrl`.
  /// Deliberately never throws -- a missing cover must not break search.
  Future<String> _fetchCover(int animeId) async {
    final path = '/api/v2/bangumi/$animeId';
    try {
      final resp = await _send(
        method: 'GET',
        uri: _uri(path, const <String, String>{}),
        headers: _authHeaders(path),
      );
      final j = _decode(resp, '作品详情', _uri(path, const <String, String>{}));
      final b = j['bangumi'];
      if (b is! Map<String, dynamic>) return '';
      return b['imageUrl']?.toString() ?? '';
    } catch (_) {
      // Decoration only -- swallow and move on.
      return '';
    }
  }

  /// 一条龙：文件名 -> 弹幕列表（匹配不到就自动走 search 退路）
  ///
  /// [anime] / [episode] 是给退路用的关键词，通常传当前剧集标题。
  /// 命中多条匹配结果时**不自动选**（返回 [DanmakuMatch] 列表让 UI 问用户），
  /// 只有唯一一条才自动取 —— 对应官方 `isMatched` 的语义。
  Future<DanmakuFetchResult> loadFor({
    required String fileName,
    int videoDuration = 0,
    String anime = '',
    String episode = '',
    bool allowSearchFallback = true,
  }) async {
    final matches = await match(
      fileName: fileName,
      videoDuration: videoDuration,
    );
    if (matches.isNotEmpty) {
      final m = matches.first;
      final cs = await fetchComments(m.episodeId, shift: m.shift);
      return DanmakuFetchResult(
        comments: cs,
        match: m,
        matchedBy: 'match',
        matchMode: defaultMatchMode,
      );
    }
    if (!allowSearchFallback) {
      throw DanmakuException('没有匹配到弹幕库（fileName=$fileName）');
    }
    /*
     * 2026-10-15: go through the multi-keyword search.
     *
     * The old call passed the title straight through, and a full episode title
     * returns ZERO works even though the show is in the library (measured --
     * see danmakuSearchKeywords). Multi-keyword + merge is what actually finds
     * it, so both the automatic path and the panel must use it.
     */
    final found = anime.isNotEmpty
        ? await searchEpisodesSmart(anime)
        : await searchEpisodes(anime: anime, episode: episode);
    if (found.isEmpty) {
      throw DanmakuException('没有匹配到弹幕库（fileName=$fileName）');
    }
    final m = found.first;
    final cs = await fetchComments(m.episodeId);
    return DanmakuFetchResult(
      comments: cs,
      match: m,
      matchedBy: 'search',
      matchMode: 'searchEpisodes',
    );
  }

  /// 把一个 `CommentResponseV2` 的 JSON 拆成弹幕列表
  ///
  /// 单独抽出来是因为测试要能直接喂 JSON，不经过网络。
  static List<DanmakuComment> _parseComments(
    Map<String, dynamic> j, {
    double shift = 0,
  }) {
    final raw = j['comments'];
    final out = <DanmakuComment>[];
    if (raw is List) {
      for (final e in raw) {
        if (e is! Map<String, dynamic>) continue;
        final c = DanmakuComment.fromJson(e, shift: shift);
        if (c != null) out.add(c);
      }
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  void close() => _transport.close();
}

/// 弹幕数据源：本机外部弹幕（127.0.0.1:2080）或官方开放平台
///
/// T27-05：本机桌面版提供**免签名的本地接口**；官方接口则要
/// AppId/AppSecret 签名。选路规则：本地在线 ⇒ 优先本地；否则退回官方。
enum DanmakuSourceKind {
  /// 本机弹弹play 桌面版（127.0.0.1:2080，免签名）
  local,

  /// 用户配置的自建后端（[DanmakuEndpoint]，免签名）
  ///
  /// ★ 与 [local] **分开**而不是合并：两者都免签名，但「探到谁」决定了
  ///   状态行文案与排错方向（本机没启动 vs 自建地址填错）。
  custom,

  /// 官方 api.dandanplay.net（https + AppId/AppSecret 签名）
  official,
}

/// 数据源选路：先探自建后端 / 本机外部弹幕，探不通再退回官方
///
/// 本机外部弹幕（桌面版）在 127.0.0.1:2080 提供 弹弹play 协议的本地接口，
/// **本地接口不需要签名**；用户配置的自建后端（[DanmakuEndpoint]）同理。
/// 探测失败（连接拒绝 / 超时 / 返回的是别的网页）一律安静退回官方，
/// 绝不让取弹幕这条路因为探测挂掉。
class DanmakuSourceSelector {
  /// 返回应该使用的数据源。
  ///
  /// [transport] 可注入假 transport 做双环境单测；[timeout] 限制探测
  /// 最长等待，避免本地服务假死时拖住取弹幕。
  /// [endpoint] 非空时**优先**探用户自建后端（见 [DanmakuEndpoint]）。
  static Future<DanmakuSourceKind> select({
    DanmakuTransport? transport,
    Duration timeout = const Duration(seconds: 2),
    DanmakuEndpoint? endpoint,
  }) async {
    final status = await DanmakuLocalService.probe(
      transport: transport,
      timeout: timeout,
      endpoint: endpoint,
    );
    if (!status.online) return DanmakuSourceKind.official;
    /*
     * ★ 2026-10-17（Owner 第 4 条）：内置公共实例算 `custom`（用户可覆盖的
     * 那一路），**不算** `local`（本机进程）。
     * ```text
     * 用户要做的事完全不同：
     *   local  → 去启动本机桌面版
     *   custom → 地址在设置里，可以直接改（内置只是默认值）
     * ```
     */
    if (endpoint != null) return DanmakuSourceKind.custom;
    return status.isPublicInstance
        ? DanmakuSourceKind.custom
        : DanmakuSourceKind.local;
  }
}

/// 本机外部弹幕（127.0.0.1:2080）探测与状态文案
///
/// [describe] 一次探测 + 一行人话文案，给弹幕设置面板的「数据源」状态行。
class DanmakuLocalService {
  static const String hostPort = '127.0.0.1:2080';

  /// 弹弹play 桌面版的原生探测端点
  static const String versionPath = '/api/v2/system/version';

  /// ★ 2026-10-16 修：自建后端（danmu_api 这类）**没有** [versionPath]。
  ///
  /// # 这是真缺陷，不是洁癖
  /// ```text
  /// 实测 danmu_api：GET /api/v2/system/version → HTTP 404
  ///                  GET /api/config            → HTTP 200 + {"version":"1.21.5",…}
  /// ```
  /// 改前只认 [versionPath] ⇒ **服务明明活着却被判成不可用**，
  /// 用户会看到「未运行」而实际能取到弹幕（假阴性）。
  /// ⇒ 探测按序试两个端点，任一命中即算在线。
  static const String configPath = '/api/config';

  /// ★★★ 2026-10-17（Owner 第 4 条）：**内置公共实例两个都没有**。
  ///
  /// # 实测（`.probe/danmaku_b_builtin_probe.py`）
  /// ```text
  /// https://<实例>/<token>/api/v2/system/version  → 404
  /// https://<实例>/<token>/api/config             → 404
  /// https://<实例>/<token>/api/v2/search/anime?keyword=a → 200 {"animes":[...]}  ~3-5 s
  /// https://<实例>/<token>/                               → 200 {"message":"Welcome …","version":"1.1.6"}
  /// ```
  /// ⇒ 只认前两个端点的话，**内置实例永远显示「未运行」**，
  ///   而它明明能取到 2000+ 条弹幕（假阴性，和 configPath 那次同一个病）。
  ///
  /// # 为什么用 search 而不是根路径
  /// ```text
  /// 根路径 `/` 也可能被**别的**服务占用（随便一个静态站也回 200 文本）。
  /// search 返回的是这个协议**特有**的结构（`animes` 数组），
  /// 误判概率低得多 —— 与 _probeOne 里「非 JSON 不算」同一条纪律。
  /// 代价：慢一点（3~5 s），所以它排在最后，且只有在前两个都没命中时才试。
  /// ```
  static const String searchProbePath = '/api/v2/search/anime';

  static const String notRunningLine = '检测到本机外部弹幕 未运行';

  const DanmakuLocalService._();

  /// 探测某个弹幕后端是否在跑。
  ///
  /// 判定：2xx 且正文是 JSON（这类服务回 JSON；若有人在这个端口挂了
  /// 别的网页服务，不算）。任何异常（连接拒绝/超时/非 JSON）⇒ 不在线。
  ///
  /// [endpoint] 非空时探**用户自建后端**（按 [DanmakuEndpoint.resolve] 拼路径）；
  /// 为空时探本机弹弹play（行为与改前逐字一致，只是多试一个端点）。
  ///
  /// ══════════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-18（Owner 第 9 条）：**整次探测的总耗时 = [timeout]**，
  /// 不是「每个端点各 [timeout]」
  /// ══════════════════════════════════════════════════════════════════════
  ///
  /// # 改前是什么
  /// ```text
  /// 下面按序试 1~3 个端点，**每个**都拿完整的 [timeout]。
  /// ⇒ 最坏 2 个端点（本机 2080 那条路）= 2×timeout = 4 s
  ///   最坏 3 个端点（带 endpoint 那条路）= 3×timeout = 6 s
  /// ```
  ///
  /// # 为什么这是个真问题（Owner 原话是关键）
  /// ```text
  /// > dan-api 依旧异步,全都不能阻塞应用的启动,都应该在后台异步处理
  ///
  /// 启动路径本身**不调**它（见 test/zz_t66_danmaku_startup_gate_test.dart
  /// 的三条判据），但**凡是等它的地方**都会被这个 3 倍放大拖住：
  ///   · 弹幕面板/设置页的「测试连接」按钮（用户点了要等 6 s 转圈）
  ///   · 播放页起播时的状态行（`_ensureDanmakuLocalStatus`）
  /// 用户体感就是「弹幕这块很慢」，与「不许阻塞」是同一类问题。
  /// ```
  ///
  /// # 改法：**共享一个截止时间**
  /// ```text
  /// 进函数时算一次 deadline = now + timeout
  /// 每次 _probeOne 只拿 remaining = deadline - now
  /// remaining <= 0 ⇒ 不再试，直接判离线
  /// ```
  /// ⇒ 语义仍是「按序试、任一命中即在线」，但**整次探测有上界**。
  ///
  /// ⚠️ 这会改变一个**边界行为**：多个端点都慢时，后面的端点可能**来不及试**。
  ///    方向是安全的 —— 那种情况下服务本来也已经在超时边缘，
  ///    再等下去只会让用户多等，而不会让判定更准。
  /// ⚠️ 默认 [timeout] 保持 2 s 不变（与改前逐字一致）：
  ///    本机 2080 是毫秒级，2 s 足够；内置公网实例本来就要靠
  ///    `_probeOne` 的 404 快速失败，不吃这个预算。
  static Future<DanmakuLocalStatus> probe({
    DanmakuTransport? transport,
    Duration timeout = const Duration(seconds: 2),
    DanmakuEndpoint? endpoint,
  }) async {
    final t = transport ??
        IoDanmakuTransport(
          timeout: timeout,
          // ★ 接线点 ②：探活/自检用的传输层
          //   与 ① 用同一个解析函数 —— 否则"探活直连、取弹幕走代理"
          //   会出现"探活通了但取不到"的假阳性。
          findProxy: currentDanmakuFindProxy(),
        );
    final shouldClose = transport == null;
    /*
     * ★ 整次探测的唯一截止时间（见上方长注释）。
     * 用 Stopwatch 而不是 DateTime：后者会被系统时钟调整影响，
     * 而墙钟往回跳一次就会让 remaining 变成负数并**跳过所有端点**。
     */
    final clock = Stopwatch()..start();
    Duration remaining() {
      final left = timeout - clock.elapsed;
      return left.isNegative ? Duration.zero : left;
    }

    try {
      // ① 首选：弹弹play 桌面版的原生端点（本机 2080 与本机自建实例同款拼法）
      final st0 = await _probeOne(
        t,
        endpoint?.resolve(versionPath) ?? Uri.http(hostPort, versionPath),
        remaining(),
        endpoint: endpoint,
      );
      if (st0 != null) return st0;

      // ② 退路：★ 自建后端（danmu_api 这类）**没有** versionPath，
      //    只有 /api/config。少了这一步，活着的自建服务会被判成不可用
      //    —— 实测 404 vs 200，是本轮修掉的真缺陷（假阴性）。
      final st1 = await _probeOne(
        t,
        endpoint?.resolve(configPath) ?? Uri.http(hostPort, configPath),
        remaining(),
        endpoint: endpoint,
      );
      if (st1 != null) return st1;

      /*
       * ③ 再退一步：★ 内置公共实例两个都没有（实测 404 / 404）。
       *    见 [searchProbePath] 的推导。只有带了 endpoint（= 有具体后端
       *    可打）才试 —— 本机 2080 那条路不加这一步（它本来就有前两个）。
       *
       * ⚠️ 预算已经用完时**不再发起**这一步：它是最慢的那个
       *    （公网 serverless，实测 3~5 s），顶着 0 预算去打只会
       *    立刻超时，还多留一个在途连接。
       */
      if (endpoint != null && remaining() > Duration.zero) {
        final st2 = await _probeOne(
          t,
          endpoint.resolve(searchProbePath, const {'keyword': 'a'}),
          remaining(),
          endpoint: endpoint,
        );
        if (st2 != null) return st2;
      }

      return DanmakuLocalStatus(
        online: false,
        endpoint: endpoint,
        isPublicInstance: _isPublicEndpoint(endpoint),
      );
    } catch (_) {
      return DanmakuLocalStatus(
        online: false,
        endpoint: endpoint,
        isPublicInstance: _isPublicEndpoint(endpoint),
      );
    } finally {
      if (shouldClose) t.close();
    }
  }

  /// 探一个端点：在线返回状态，不在线返回 null（让调用方试下一个）。
  ///
  /// ⚠️ 这里**故意吞掉异常**并返回 null 而不是直接判离线：
  ///    404 会让部分服务直接抛，那是「这个端点没有」而不是「服务没起来」。
  ///
  /// ★ 2026-10-18（Owner 第 9 条）：[timeout] 现在是**整次探测剩下的预算**
  ///   （由 [probe] 算好传进来），不再是「每个端点各拿一份」。
  ///   `== Duration.zero` 表示预算已耗尽 ⇒ **一个字节都不发**，
  ///   直接返回 null（见 [probe] 里 remaining() 的说明）。
  static Future<DanmakuLocalStatus?> _probeOne(
    DanmakuTransport t,
    Uri uri,
    Duration timeout, {
    DanmakuEndpoint? endpoint,
  }) async {
    /*
     * ★ 预算是 0 ⇒ 不发请求。
     * 为什么必须显式挡：(await x).timeout(Duration.zero) 会**立刻**抛
     * TimeoutException，看起来"等效"，但它已经在事件循环上排了一次
     * 真实的 send() —— 对一个要连公网的 transport 来说，那可能真的
     * 把 socket 建起来（iOS/Android 上是真流量）。这里直接短路。
     */
    if (timeout <= Duration.zero) return null;
    try {
      final r = await t
          .send(
            method: 'GET',
            uri: uri,
            headers: const {'Accept': 'application/json'},
          )
          .timeout(timeout);
      if (!r.isOk || _looksLikeHtml(r.body)) return null;
      final j = jsonDecode(r.body);
      if (j is! Map) return null;
      // 两个端点的版本字段名不同：弹弹play 用 versionCode，danmu_api 用 version
      final v = j['versionCode'] ?? j['version'];
      return DanmakuLocalStatus(
        online: true,
        version: v?.toString(),
        /*
         * 记住命中的是哪个端点（诊断用）。
         * ⚠️ 只留**最后一段**（version / config / anime），不留整条 path ——
         *    self-hosted 后端的 path 带 token 前缀（/<token>/api/config），
         *    整条存下来就是一个**潜伏的泄漏面**（今天没人显示它，
         *    明天加一行调试输出就泄了）。同 _safeUri 的纪律。
         */
        viaPath: uri.pathSegments.isEmpty ? '' : uri.pathSegments.last,
        endpoint: endpoint,
        isPublicInstance: _isPublicEndpoint(endpoint),
      );
    } catch (_) {
      return null;
    }
  }

  /// 这个端点是不是内置公共实例里的某一个（决定状态行怎么说）
  ///
  /// ⚠️ 按 **baseUrl 归一化后**比较，不比 token —— token 是默认值，
  ///    用户可能改过它却仍在同一个实例上（那是「还是内置的」）。
  static bool _isPublicEndpoint(DanmakuEndpoint? ep) {
    if (ep == null) return false;
    final want = ep.baseUrl.toLowerCase().replaceAll(RegExp(r'/+$'), '');
    for (final p in kDanmakuPublicInstances) {
      final have = p.baseUrl.toLowerCase().replaceAll(RegExp(r'/+$'), '');
      if (have == want) return true;
    }
    return false;
  }

  /// 「数据源」状态行文案：本机显示「检测到本机外部弹幕 未运行」，
  /// 在线时显示端口（带版本更好）。
  static Future<DanmakuLocalStatus> describe({
    DanmakuTransport? transport,
    Duration timeout = const Duration(seconds: 2),
    DanmakuEndpoint? endpoint,
  }) => probe(transport: transport, timeout: timeout, endpoint: endpoint);
}

/// 探测结果：是否在线 + （可选）版本号 + 状态行文案
class DanmakuLocalStatus {
  const DanmakuLocalStatus({
    required this.online,
    this.version,
    this.viaPath,
    this.endpoint,
    this.isPublicInstance = false,
  });

  final bool online;
  final String? version;

  /// 命中的探测端点（诊断用；不在线时为 null）
  final String? viaPath;

  /// 探的是哪个自建后端（null = 本机弹弹play）
  final DanmakuEndpoint? endpoint;

  /// ★ 探的是**内置公共实例**（不是用户自己填的、也不是本机）
  ///
  /// 文案要分开说：内置实例挂了用户**不用去改配置**（等我们换/换下一个），
  /// 而自建服务挂了用户必须去改地址 —— 两件事。
  final bool isPublicInstance;

  /// 弹幕设置面板「数据源」一行的文案。
  String get line {
    final ep = endpoint;
    if (!online) {
      if (ep == null) return DanmakuLocalService.notRunningLine;
      if (isPublicInstance) return '内置公共实例（${ep.display}）暂时连不上';
      return '自建弹幕服务（${ep.display}）未运行';
    }
    final v = (version == null || version!.isEmpty) ? '' : ' · v$version';
    // ★ 2026-10-16：自建后端与本机弹弹play **必须分开说** ——
    //   两者都能让 online 为 true，但用户要做的事完全不同
    //   （前者去配置里改地址，后者去启动桌面版弹弹play）。
    // ★ 2026-10-17：内置公共实例是**第三种** —— 用户没配任何东西就能用。
    if (ep != null) {
      if (isPublicInstance) return '内置公共实例（${ep.display}）已就绪$v';
      return '自建弹幕服务（${ep.display}）已就绪$v';
    }
    return '本机外部弹幕（${DanmakuLocalService.hostPort}）已就绪$v';
  }
}

/// 正文看起来像网页吗（CDN 错误页 / 人机校验页）
///
/// 只认**开头**的特征，不做全文搜索 —— 正常 JSON 正文里出现 "html"
/// 这个词的概率不低，全文匹配会误判。
/// 实测来源：某视频站搜索接口在 Referer 不对时回 HTTP 200 + text/html
/// 的风控页（见 lib/core/bili/bili_api.dart 的 searchVideos）。
bool _looksLikeHtml(String body) {
  final s = body.trimLeft().toLowerCase();
  return s.startsWith('<!doctype html') || s.startsWith('<html');
}

/// 正文太长时截断，避免把整个响应塞进异常对象和 UI
String _clip(String s, [int max = 2000]) {
  if (s.length <= max) return s;
  return '${s.substring(0, max)}…（已截断，共 ${s.length} 字）';
}

// -----------------------------------------------------------------------
// 排版：轨道分配（纯函数，可单测、可离线证明"不重叠"）
// -----------------------------------------------------------------------
//
// 这一层刻意**不碰任何 widget / dart:ui 类型**，只做数学：
// 输入一串弹幕 + 画面尺寸 + 字号，输出每条弹幕"在第几轨道、什么时候、
// 从哪儿到哪儿"。渲染层（danmaku_overlay.dart）只负责照着画。
//
// 好处："不重叠"这个验收点可以用纯计算证明（test/task13_danmaku_test.dart
// 会把所有弹幕在时间轴上密集采样，逐帧做矩形相交检测），
// 不依赖截图肉眼看。

/// 一个矩形（左、上、宽、高）—— 不引 dart:ui，保持本文件纯 Dart
class DanmakuBox {
  const DanmakuBox(this.left, this.top, this.width, this.height);

  final double left;
  final double top;
  final double width;
  final double height;

  double get right => left + width;
  double get bottom => top + height;

  /// 两个矩形是否**有面积**相交（只是贴边不算）
  bool overlaps(DanmakuBox o, {double epsilon = 0.5}) {
    if (right <= o.left + epsilon) return false;
    if (o.right <= left + epsilon) return false;
    if (bottom <= o.top + epsilon) return false;
    if (o.bottom <= top + epsilon) return false;
    return true;
  }

  @override
  String toString() => 'DanmakuBox(${left.toStringAsFixed(1)}, '
      '${top.toStringAsFixed(1)}, ${width.toStringAsFixed(1)}, '
      '${height.toStringAsFixed(1)})';
}

/// 一条弹幕被分配到轨道之后的结果
class DanmakuPlacement {
  const DanmakuPlacement({
    required this.comment,
    required this.lane,
    required this.laneTop,
    required this.width,
    required this.enterAt,
    required this.exitAt,
    required this.speed,
    required this.fixed,
    required this.fontSize,
  });

  final DanmakuComment comment;

  /// 轨道序号（0 在最上面）
  final int lane;

  /// 轨道顶部 y（相对弹幕区域顶部，未加任何偏移）
  final double laneTop;

  /// 估算的文本宽度
  final double width;

  /// 开始出现的时间（秒）—— 等于弹幕自己的时间戳
  final double enterAt;

  /// 完全离开的时间（秒）；固定弹幕 = 出现时间 + 停留时长
  final double exitAt;

  /// 水平速度（px/s）；固定弹幕为 0
  final double speed;

  /// 是否固定弹幕（顶部 / 底部）
  final bool fixed;

  final double fontSize;

  /// 某个时刻的矩形
  ///
  /// [canvasWidth] 是弹幕区域宽度。
  /// 滚动弹幕：从右边 `canvasWidth` 处进入，向左走到 `-width` 离开；
  /// 固定弹幕：水平居中，位置不动。
  DanmakuBox boxAt(double t, double canvasWidth, double lineHeight) {
    final top = laneTop;
    if (fixed) {
      final left = (canvasWidth - width) / 2;
      return DanmakuBox(left, top, width, lineHeight);
    }
    final left = canvasWidth - speed * (t - enterAt);
    return DanmakuBox(left, top, width, lineHeight);
  }

  /// 这个时刻是否**应该**被画出来（还没进画 / 已经出画就跳过）
  ///
  /// ★ 区间是**半开**的 `[enterAt, exitAt)`：
  ///   分配器回收轨道用的判据是 `exitAt < t`（也就是 `t == exitAt` 时轨道已可复用），
  ///   如果这里写成闭区间，就会在 `t == exitAt` 这一瞬间出现"
  ///   上一条还在画、下一条已经进来"的同轨重叠 ——
  ///   单测 `task13_danmaku_test.dart` 的 900 帧逐帧相交检测正是这么抓到它的。
  bool visibleAt(double t) => t >= enterAt && t < exitAt;

  @override
  String toString() => 'DanmakuPlacement(lane $lane, '
      '${enterAt.toStringAsFixed(2)}~${exitAt.toStringAsFixed(2)}s, '
      'w=${width.toStringAsFixed(1)}, ${fixed ? "固定" : "滚动"}, '
      '"${comment.text}")';
}

/// 粗略估算一段文本的像素宽度
///
/// 用于**没有 TextPainter 时**的退路（纯 Dart 单测、离线排版分析）。
/// 渲染层会传入真实的 `TextPainter` 测量结果，两者不要混用。
///
/// 系数：CJK（含全角标点、假名、韩文）按 1.0 em，其余按 0.55 em ——
/// 不追求精确，只保证"长文本占更宽"这个单调关系成立。
double estimateTextWidth(String text, double fontSize) {
  var units = 0.0;
  for (final r in text.runes) {
    units += r < 0x2E80 ? 0.55 : 1.0;
  }
  return units * fontSize;
}

/// 轨道分配器
///
/// ## 规则（决定了"不重叠"是怎么成立的）
///
/// 所有弹幕按时间顺序处理，每条尝试从**上往下**找第一条能放下的轨道。
/// 轨道里已经有的弹幕记为一次"占用"，占用分两种：
/// ```text
/// 滚动弹幕：占用区间 [enterAt, exitAt]，但**只要上一条已经完整进入画面**
///           且留出 gap 的空隙，下一条就能进 —— 因为速度相同，
///           空隙会一直保持，不会追尾。
/// 固定弹幕：整段时间停在原地，必须等它彻底消失才能进。
/// ```
/// 也就是：`下一条的进入时间 >= 上一条要求的时刻`。
/// 两种占用合并成同一个判据后，滚动 / 顶部 / 底部**共用同一批轨道**，
/// 于是任意两条弹幕在任何时刻的矩形都不会相交。
///
/// ## 和常见播放器的差异（刻意为之）
///
/// 多数播放器允许顶部/底部弹幕和滚动弹幕**压在同一个位置**
/// （因为它们看起来"本来就该叠"）。这里不这么做 —— 本项目的验收点
/// 明确要求"不重叠"，所以固定弹幕也占用轨道。
/// 代价是固定弹幕多的时候滚动弹幕可用轨道变少，
/// 放不下的弹幕会被丢弃并计入 [DanmakuLayout.dropped]。
class DanmakuTrackAllocator {
  const DanmakuTrackAllocator._();

  /// 分配轨道
  ///
  /// * [comments] 已按时间排好序（[ExternalDanmakuClient] 保证）
  /// * [canvasWidth] / [canvasHeight] 弹幕区域的逻辑像素尺寸
  /// * [fontSize] 字号（px）
  /// * [lineHeight] 单行占用的高度（px），通常 = fontSize * 1.35
  /// * [speed] 滚动弹幕速度（px/s）
  /// * [area] 弹幕显示区域占画面高度的比例（0.1 ~ 1.0），**从顶部往下量**：
  ///   轨道从第 0 行往下铺，铺满 `canvasHeight * area` 为止。
  /// * [fixedSeconds] 固定弹幕停留时长
  /// * [gap] 同轨道两条滚动弹幕之间的最小空隙（px）
  /// * [measure] 文本宽度测量；缺省用 [estimateTextWidth]
  static DanmakuLayout layout({
    required List<DanmakuComment> comments,
    required double canvasWidth,
    required double canvasHeight,
    required double fontSize,
    double? lineHeight,
    double speed = 120,
    double area = 1.0,
    double fixedSeconds = 4.0,
    double gap = 24,
    double Function(String text, double fontSize)? measure,
  }) {
    final lh = lineHeight ?? fontSize * 1.35;
    final measurer = measure ?? estimateTextWidth;
    final v = speed <= 0 ? 1.0 : speed;
    final usable = math.max(canvasHeight * area.clamp(0.05, 1.0), lh);
    final laneCount = math.max(1, (usable / lh).floor());
    final lanes = List<List<_Occ>>.generate(laneCount, (_) => <_Occ>[]);
    final out = <DanmakuPlacement>[];
    var dropped = 0;

    for (final c in comments) {
      final w = math.max(measurer(c.text, fontSize), fontSize);
      final fixed = c.mode.isFixed;
      final t = c.time;
      // 先清掉"以后都不可能再挡路"的占用（时间只增不减，所以安全）
      for (final occ in lanes) {
        occ.removeWhere((o) => o.exitAt < t);
      }
      var placed = false;
      // 顶部固定从上往下找；底部固定从下往上找；滚动从上往下找
      final order = _laneOrder(c.mode, laneCount);
      for (final li in order) {
        final occ = lanes[li];
        var ok = true;
        for (final o in occ) {
          if (t < o.requiredStartFor(fixed, v, gap)) {
            ok = false;
            break;
          }
        }
        if (!ok) continue;
        final exitAt = fixed ? t + fixedSeconds : t + (canvasWidth + w) / v;
        out.add(DanmakuPlacement(
          comment: c,
          lane: li,
          laneTop: li * lh,
          width: w,
          enterAt: t,
          exitAt: exitAt,
          speed: fixed ? 0 : v,
          fixed: fixed,
          fontSize: fontSize,
        ));
        occ.add(_Occ(
          enterAt: t,
          exitAt: exitAt,
          width: w,
          fixed: fixed,
        ));
        placed = true;
        break;
      }
      if (!placed) dropped++;
    }

    return DanmakuLayout(
      placements: out,
      laneCount: laneCount,
      lineHeight: lh,
      dropped: dropped,
      canvasWidth: canvasWidth,
      canvasHeight: canvasHeight,
      speed: v,
    );
  }

  /// 轨道搜索顺序：顶部固定从上往下，底部固定从下往上，滚动从上往下。
  /// 底部固定从下往上找，是为了让它优先待在画面下缘（符合直觉）。
  static List<int> _laneOrder(DanmakuMode mode, int laneCount) {
    if (mode == DanmakuMode.bottom) {
      return List<int>.generate(laneCount, (i) => laneCount - 1 - i);
    }
    return List<int>.generate(laneCount, (i) => i);
  }
}

/// 一次排版的完整结果
class DanmakuLayout {
  const DanmakuLayout({
    required this.placements,
    required this.laneCount,
    required this.lineHeight,
    required this.dropped,
    required this.canvasWidth,
    required this.canvasHeight,
    required this.speed,
  });

  final List<DanmakuPlacement> placements;
  final int laneCount;
  final double lineHeight;

  /// 因为所有轨道都被占满而丢掉的条数（如实统计，不要藏）
  final int dropped;

  final double canvasWidth;
  final double canvasHeight;
  final double speed;

  bool get isEmpty => placements.isEmpty;

  int get length => placements.length;

  /// 某个时刻应该画出来的弹幕
  List<DanmakuPlacement> at(double t) {
    final out = <DanmakuPlacement>[];
    for (final p in placements) {
      if (p.visibleAt(t)) out.add(p);
    }
    return out;
  }

  /// 某个时刻所有可见弹幕的矩形（给"不重叠"证明用）
  List<DanmakuBox> boxesAt(double t) {
    final out = <DanmakuBox>[];
    for (final p in at(t)) {
      out.add(p.boxAt(t, canvasWidth, lineHeight));
    }
    return out;
  }

  /// 一行统计，探针日志里打这个
  String get summary => '轨道 $laneCount 条 · 排版 $length 条'
      '${dropped > 0 ? " · 丢弃 $dropped 条" : ""}';
}

/// 轨道里的一次占用（内部用）
class _Occ {
  _Occ({
    required this.enterAt,
    required this.exitAt,
    required this.width,
    required this.fixed,
  });

  final double enterAt;
  final double exitAt;
  final double width;
  final bool fixed;

  /// 下一条弹幕最早能在什么时刻进入这条轨道
  ///
  /// * 上一条是固定弹幕 -> 必须等它整段消失
  /// * 上一条是滚动弹幕，本条也是滚动 -> 只要上一条完整进入画面 + 留出空隙
  /// * 上一条是滚动弹幕，本条是固定 -> 固定弹幕停在原地，必须等滚动弹幕走完
  double requiredStartFor(bool newIsFixed, double speed, double gap) {
    if (fixed || newIsFixed) return exitAt;
    return enterAt + (width + gap) / speed;
  }

  @override
  String toString() => '_Occ(${enterAt.toStringAsFixed(2)}~'
      '${exitAt.toStringAsFixed(2)}s, w=${width.toStringAsFixed(1)}, '
      '${fixed ? "固定" : "滚动"})';
}

// -----------------------------------------------------------------------
//  弹幕聚合（Owner 第 9 条）
// -----------------------------------------------------------------------
//
// Owner 原话（逐字，2026-10-17）：
// ```text
// > 有些网站本身也提供弹幕,我们要支持弹幕的聚合
// ```
//
// # 改前是**单选**，不是聚合
// ```text
// `_loadDanmakuNamed` 里那串 if 是**互斥**的：
//   绑了外部视频站 ⇒ `_loadBiliDanmaku(cid); return;`   ← 插件那条被 return 掉
//   没绑          ⇒ 走 dan-api / 官方
// ⇒ 用户「插件也能给弹幕」+「dan-api 也能给弹幕」时，**只有一条**被载入。
//   这不是聚合，是"二选一"。Owner 说的正是这个。
// ```
//
// # 聚合要解决的三件事（不是简单 concat）
// ```text
// ① 时间轴对齐 —— 两路的 `time` 都是"从这一集开头算的秒"，直接合并即可
//    （shift 已在各自的解析层叠加过，见 DanmakuComment 的注释）
// ② 重复 —— 同一句弹幕在同一个时间点出现两次会**明显**看得出来（重影）
//    ⇒ 按 (time 四舍五入到 0.1s, text) 去重；**保留先到的那个源**
// ③ 排序 —— 轨道分配器要求「已按时间排好序」（DanmakuTrackAllocator.layout
//    的入参契约）⇒ 合并后必须重排，否则后半段的弹幕会挤在开头
// ```
//
// # 为什么做成**纯函数**（而不是挂在客户端上）
// ```text
// ① 可离线单测 + 可故障注入（把"只返回第一源"写回去必须变红）
// ② 不碰网络 ⇒ 不需要假 transport，测试跑得快、没有 flake
// ③ 宿主只加**一个调用点**（`_loadDanmakuNamed` 里），接线面最小
// ```

/// 聚合里的**一路**来源：谁 + 给了多少条 + 有没有出错
///
/// ⚠️ `count` 是**这一路自己**的条数（去重**前**）—— 信息面板要显示
///    「插件 1200 条 + dan-api 800 条 = 合并 1900 条（去掉 100 条重复）」，
///    这个等式必须成立，否则用户会以为丢数据了。
@immutable
class DanmakuFeedStat {
  const DanmakuFeedStat({
    required this.kind,
    required this.count,
    this.detail = '',
    this.error = '',
    this.loaded = true,
  });

  /// 这一路是哪一类（与右侧信息面板的枚举同源，见 DanmakuSourceChannel）
  final DanmakuSourceChannel kind;

  /// 这一路贡献了多少条（**去重前**）
  final int count;

  /// 附加说明（版本号 / 端点 / 文件名…）
  final String detail;

  /// 这一路**失败**时的原文（空 = 没失败）
  ///
  /// ⚠️ 失败的一路**必须**出现在 [DanmakuAggregate.feeds] 里且 `count == 0`
  ///    —— 悄悄吞掉一路失败，用户看到的就是「聚合只来了一半，不知道为什么」。
  final String error;

  /// 这一路是否真的被尝试过（false = 没试，例如插件不支持弹幕）
  final bool loaded;

  bool get failed => error.isNotEmpty;

  @override
  String toString() =>
      'DanmakuFeedStat($kind, $count${failed ? ", 失败: $error" : ""})';
}

/// 弹幕来源的种类 —— **定义在这里**（core 层），UI 层做展示映射。
///
/// # 为什么枚举在 core、标签在 UI
/// ```text
/// 聚合器要按"哪一路"分组统计 ⇒ 它需要一个稳定的**类别**标识；
/// 而「显示成什么中文」是展示问题（还要考虑以后换文案/多语言）。
/// ⇒ 本文件只给类别，`danmaku_info_panel.dart` 给 label/icon。
/// ```
enum DanmakuSourceChannel {
  /// 插件提供（`provider_danmaku_list`，走 Rust 桥接）
  plugin,

  /// 导入源（外部视频站直连 / dan-api / 官方）—— 具体的由 `detail` 说明
  imported,

  /// 本机外部弹幕（127.0.0.1:2080）
  local,

  /// 本地弹幕库文件
  library,

  /// 没试过 / 未知
  none,
}

/// 聚合的结果：合并后的弹幕 + **每一路**的条数
@immutable
class DanmakuAggregate {
  const DanmakuAggregate({
    this.comments = const <DanmakuComment>[],
    this.feeds = const <DanmakuFeedStat>[],
  });

  /// 合并、去重、按时间排好序的弹幕 —— 直接喂给渲染层
  final List<DanmakuComment> comments;

  /// 每一路来源的读数（含失败的那几路）
  final List<DanmakuFeedStat> feeds;

  bool get isEmpty => comments.isEmpty;

  /// 各路条数之和（**去重前**）
  int get sumOfFeeds {
    var n = 0;
    for (final f in feeds) {
      n += f.count;
    }
    return n;
  }

  /// 去重掉了多少条（`sumOfFeeds - comments.length`）
  int get deduped {
    final d = sumOfFeeds - comments.length;
    return d < 0 ? 0 : d;
  }

  /// 有几路**真的**供上了数据（失败/没试的不算）
  int get liveFeedCount {
    var n = 0;
    for (final f in feeds) {
      if (f.loaded && !f.failed && f.count > 0) n++;
    }
    return n;
  }

  /// 一行如实读数：`2 路 · 插件 1200 + 导入 800 = 1900 条（去重 100）`
  ///
  /// ⚠️ 只在**多于一路**时才是"聚合"口径；单路时退化成普通摘要，
  ///    免得用户以为自己开了什么奇怪的东西。
  String get summary {
    if (feeds.isEmpty) return '${comments.length} 条弹幕';
    if (feeds.length == 1) {
      final f = feeds.first;
      return '${_kindLabel(f.kind)} ${f.count} 条';
    }
    final parts = <String>[
      for (final f in feeds)
        if (f.loaded && !f.failed) '${_kindLabel(f.kind)} ${f.count}',
    ];
    final head = '$liveFeedCount 路 · ${parts.join(' + ')}';
    final tail = deduped > 0
        ? ' = ${comments.length} 条（去掉 $deduped 条重复）'
        : ' = ${comments.length} 条';
    return '$head$tail';
  }

  static String _kindLabel(DanmakuSourceChannel k) => switch (k) {
        DanmakuSourceChannel.plugin => '插件',
        DanmakuSourceChannel.imported => '导入源',
        DanmakuSourceChannel.local => '本机',
        DanmakuSourceChannel.library => '本地库',
        DanmakuSourceChannel.none => '未知',
      };

  @override
  String toString() => 'DanmakuAggregate(${comments.length} 条, $feeds)';
}

/// 弹幕聚合器 —— 把**多路**弹幕合并成一份可渲染的列表
///
/// 见本文件「弹幕聚合」那一节的推导。全部是纯函数，无 IO、无 widget。
class DanmakuAggregator {
  const DanmakuAggregator._();

  /// 合并多路弹幕
  ///
  /// [sources] 顺序 = **优先级**（先到的先占坑，去重时保留先到的那条）。
  /// 空列表 / 全是空列表 ⇒ 返回空聚合（不抛）。
  ///
  /// # 去重判据（为什么是 `(time 取到 0.1s, text)` 而不是别的）
  /// ```text
  /// · 只按 text 去重 ⇒ 同一句"哈哈"在不同时间点会被误杀（那是**不同**弹幕）
  /// · 只按 (time, text) 精确比 ⇒ 两路的浮点解析可能差 0.01s（`0.1` vs `0.10001`）
  ///   而人眼在 0.1s 内完全看不出区别 ⇒ 按 0.1s 归并
  /// · 颜色/模式**不参与**判据：同一句话同一个时间点，颜色不同也是同一条
  ///   （真实场景是同一批弹幕被两个源各抓了一遍，颜色必然一致）
  /// ```
  ///
  /// # 排序
  /// 按 [DanmakuComment.time] 升序。**稳定**（Dart 的 `sort` 不保证稳定，
  /// 所以同 time 的用"先到的源"作次序 —— 这靠给每条记一个来源序号实现）。
  ///
  /// # ★★★ 为什么每条**源自己内部**也去重一次（真实数据逼出来的修正）
  /// ```text
  /// 第一版只做"跨源去重" ⇒ 用真数据（ep11954，9415 条）一跑就露馅：
  ///   同一路自己给了 9415 条，输出只有 9342 条 —— **少了 73 条**。
  ///
  /// 原因：真实弹幕里**同一个时间点同一句话被很多人刷**是常态
  /// （"哈哈"、"前方高能"、应援词）。那是**不同的弹幕**，
  /// 只是内容撞了 —— 跨源去重的判据把它们当成了重复。
  ///
  /// ⇒ 判据改成两段：
  ///   ① 源**内部**：一律保留（那是别人的真实发言，重复也要留着）
  ///   ② **跨源**：按 (0.1s, 正文) 去重（同一批数据被两个源各抓一遍）
  /// ```
  /// ⚠️ 这样一来 `sumOfFeeds - comments.length` 就**只**反映跨源重复，
  ///    与面板上"合并去重 N 条"的语义一致（那个 N 只该统计跨源）。
  static DanmakuAggregate merge(
    List<DanmakuFeedInput> sources,
  ) {
    final feeds = <DanmakuFeedStat>[];
    /*
     * `seenBy` 记「这个 (时间,正文) 是**哪一路**先给的」。
     *
     * ⚠️ 不能只用 `Set<String>`：那样同一路内部的第二次出现的同句也会被吃掉
     *    （见上方"源内部一律保留"）。
     */
    final seenBy = <String, int>{};
    // 排序键带上「来源序号」⇒ 同 time 时先到的源排前面（稳定）
    final keyed = <({double time, int order, DanmakuComment c})>[];
    var order = 0;

    for (var si = 0; si < sources.length; si++) {
      final src = sources[si];
      final list = src.comments;
      feeds.add(DanmakuFeedStat(
        kind: src.kind,
        count: list.length,
        detail: src.detail,
        error: src.error,
        loaded: src.loaded,
      ));
      /*
       * 这一路**自己**见过的键。用于区分两件事：
       *   · 这一路内部又出现一次 ⇒ 保留（真实发言）
       *   · **另一路**已经给过 ⇒ 丢掉（同一批数据被抓了两遍）
       *
       * ⚠️ 改前这里写的是 `Set<String> seen` 全局共享 ⇒ 第一路内部的同句
       *    也被吃掉（真数据 9415 条掉到 9342 条，少了 73 条真实弹幕）。
       *    见 merge 的文档「为什么每条源自己内部也去重一次」。
       */
      for (final c in list) {
        final k = _dedupKey(c);
        final owner = seenBy[k];
        if (owner != null && owner != si) {
          // ★ 别的源已经给过这一条 ⇒ 跨源重复，丢掉后来的
          continue;
        }
        seenBy.putIfAbsent(k, () => si);
        keyed.add((time: c.time, order: order++, c: c));
      }
    }

    keyed.sort((a, b) {
      final d = a.time.compareTo(b.time);
      if (d != 0) return d;
      return a.order.compareTo(b.order);
    });

    return DanmakuAggregate(
      comments: <DanmakuComment>[for (final k in keyed) k.c],
      feeds: feeds,
    );
  }

  /// 去重键：`时间（0.1s 精度）| 正文`
  ///
  /// 时间取整用 `round()`（不是 floor）—— `0.05` 与 `0.14` 都归到 0.1，
  /// 而 `0.14` 与 `0.16` 归到 0.1 / 0.2 两个桶，与直觉一致。
  static String _dedupKey(DanmakuComment c) {
    final t = (c.time * 10).round();
    return '$t|${c.text}';
  }
}

/// [DanmakuAggregator.merge] 的一路输入
@immutable
class DanmakuFeedInput {
  const DanmakuFeedInput({
    required this.kind,
    this.comments = const <DanmakuComment>[],
    this.detail = '',
    this.error = '',
    this.loaded = true,
  });

  /// 没试过这一路（例如插件不支持弹幕）—— 用这个构造，别伪造一个空列表
  const DanmakuFeedInput.skipped({
    required this.kind,
    this.detail = '',
  })  : comments = const <DanmakuComment>[],
        error = '',
        loaded = false;

  /// 这一路失败了 —— 错误原文照透（面板要显示"为什么只来了一半"）
  const DanmakuFeedInput.failed({
    required this.kind,
    required this.error,
    this.detail = '',
  })  : comments = const <DanmakuComment>[],
        loaded = true;

  final DanmakuSourceChannel kind;
  final List<DanmakuComment> comments;
  final String detail;
  final String error;
  final bool loaded;
}

