// =======================================================================
//  站源原生弹幕 provider（T8 · 弹幕对标补齐）—— 拉取（读操作）
// =======================================================================
//
// # 这个文件解决什么
//
// T2 对标取证（`.probe/reference-apk-benchmark.md` ③）发现参考 fork 内置了
// 「站源原生弹幕拉取」：不经过弹弹play 协议，直接打视频站自家的弹幕网关。
// 本文件把那条链路移植成 core 层的一个 provider（可注入 transport，
// 频控友好，失败留痕）。
//
// ⚠️ 产品代码按 t98 站名铁律**中性化**（"站源"，不写具体站名）；
//   具体站点、协议参数逐字取证与 live probe 实测读数都在
//   `.probe/mopen-danmu-probe.py` / `.probe/mopen-danmu-probe-result.md`。
//
// # 取证来源（不猜参数）
// ```text
// .probe/reference-apk-benchmark.md ③
// .probe/ref-apk/dump-core.txt n6 段（17 串逐字：body 模板 / 'data=' /
//   '&' / '&24679788&' / secret / URL 两个前缀片段）
// .probe/mopen-danmu-probe.py + .probe/mopen-danmu-probe-result.md
//   （T8 live probe，对弹幕端点共 3 次请求，成败均归档）
// ```
//
// # probe 实证结论（2026-11-01，round-1/round-2，均已归档）
// ```text
// ① POST（表单 data=<body>）到站源弹幕网关，回 MTOP 风格信封
//    {"api","data","ret":[...],"traceId","v"}。
// ② 无令牌 ⇒ ret=["FAIL_SYS_TOKEN_EMPTY::令牌为空"]，同时 Set-Cookie
//    下发 `_m_h5_tk`（MTOP 两步流的正规第一步）。
// ③ ★ round-2 实证（lead 授权补证）：MTOP h5 标准签名口径成立——
//      sign = md5(token + '&' + t + '&' + appKey + '&' + data)
//    （token = `_m_h5_tk` 下划线前半段；t 秒/毫秒都被网关收下，实现取秒）。
//    成功响应：ret=["SUCCESS::调用成功"]，且 data.result 是**二次 JSON
//    编码的字符串**：
//      "{\"code\":1,\"data\":{\"result\":[…],\"count\":N},\"message\":\"success\"}"
// ⇒ 信封 + 包裹层形态已逐字取证；**元素级字段名未取证**（样本 vid 计数 0，
//    result 空数组）——元素解析走 [DanmakuComment.fromAnyJson] 泛化探测，
//    并加「count>0 但解析 0 条」的矛盾留痕（元素形态对不上时绝不静默回 0 条）。
// ```
//
// # 纪律
// ```text
// · 只做拉取（读操作）。发送（写操作，触达站源账号）一期不做——Owner 批复。
// · 失败一律抛 [DanmakuException] 带原文（ret 串 / HTTP 状态 / 正文片段），
//   绝不静默。
// · 频控友好（对齐 pan_check 口径）：同 vid+mat 结果缓存 TTL 10 分钟；
//   失败后 30 秒冷却，冷却期内不发裸请求。
// ```

import 'dart:convert';

import 'package:crypto/crypto.dart' show md5;
import 'package:flutter/foundation.dart' show visibleForTesting;

import 'danmaku.dart';
import 'ui_prefs.dart';

/// 站源原生弹幕（mopen 弹幕网关）拉取客户端
///
/// 传输层复用 [DanmakuTransport]（可注入假 transport 做单测 / 故障注入），
/// 与弹弹play 那条管线的代理选择 / 探活纪律共用同一套底座。
class MopenDanmuClient {
  MopenDanmuClient({
    DanmakuTransport? transport,
    DateTime Function()? clock,
    this.cacheTtl = const Duration(minutes: 10),
    this.cooldown = const Duration(seconds: 30),
  }) : _transport = transport ??
            IoDanmakuTransport(
              timeout: const Duration(seconds: 20),
              findProxy: currentDanmakuFindProxy(),
            ),
        _clock = clock ?? DateTime.now;

  // ── 取证常量（逐字，dump-core.txt n6 段；主机名按 t98 行级豁免保留）──

  /// 拉取端点（n6 URL 前缀串逐字；查询参数里的 `t`/`sign` 由请求时拼上）
  static const String endpoint =
      'https://acs.youku.com/h5/mopen.youku.danmu.list/1.0/';

  /// 站源网关域（Origin/Referer 请求头用；取证 + probe 实测口径）
  static const String gatewayOrigin = 'https://www.youku.com';

  /// mopen 开放平台 appKey（T2 取证公开常量）
  static const String appKey = '24679788';

  /// mopen 签名密钥（T2 取证公开常量，n6 串集之一）
  ///
  /// ⚠️ round-2 实证后签名走 MTOP token 参签式（见 [signFor]），这条
  ///   secret **不再参与签名**——保留作取证对拍锚点，别删（t141 钉着它）。
  static const String secret = 'MkmC9SoIw6xCkSKHhJ7b5D2r51kBiREr';

  /// n6 body 里的固定 guid（逐字）
  static const String guid = 'NJnMGnrls3wCAXQaiNsMGIsY';

  /// mopen API 名（URL 的 `api=` 参数值）
  static const String apiName = 'mopen.youku.danmu.list';

  // ── 可注入 ────────────────────────────────────────────────────────────

  final DanmakuTransport _transport;
  final DateTime Function() _clock;

  /// 同 vid+mat 拉取结果的缓存 TTL（对齐 pan_check 的 CACHE_TTL）
  final Duration cacheTtl;

  /// 失败后的风控冷却时长（对齐 pan_check 的 COOLDOWN）
  final Duration cooldown;

  // ── 频控/缓存状态（**类级**，不是实例态）────────────────────────────
  //
  // # 为什么是 static（互检 P2，真缺陷）
  // ```text
  // 生产唯一调用点（danmaku_source_page 的「拉取测试」）**每次按键新建
  // 实例** ⇒ 冷却/缓存若挂在实例上，每次按压都被清零——
  // "声明了 30s 冷却"在产品路径上等于没声明（声明不生效=骗人）。
  // ⇒ 状态长在类上：跨按压、跨实例都生效（有"跨实例冷却仍生效"的
  //   门禁钉着，t141）。
  // ```
  /// 同 vid+mat 的结果缓存（键 `vid|mat`，类级 ⇒ 跨实例命中）
  static final Map<String, (List<DanmakuComment>, DateTime)> _cache = {};

  /// 风控冷却截止时刻（类级 ⇒ 跨实例生效）
  static DateTime? _cooldownUntil;

  /// 最近一次失败原文（冷却提示里带出"上次失败是什么"）
  static String _lastError = '';

  /// 测试隔离口：清空类级频控/缓存状态（用例互不污染）
  @visibleForTesting
  static void debugResetRateLimitState() {
    _cache.clear();
    _cooldownUntil = null;
    _lastError = '';
  }

  // ── 纯函数（单测逐字对拍）────────────────────────────────────────────

  /// n6 拉取 body 模板（17 串逐字，键序照串序拼接；T8 probe 实测网关收下）：
  /// `{"ctime": <ts>, "ctype": 10004, "cver": "v1.0", "guid": "<guid>",
  ///   "mat": <mat>, "mcount": 1, "pid": 0, "sver": "3.1.0", "vid": "<vid>"}`
  static String buildBody({
    required String vid,
    required int mat,
    required int ctime,
  }) =>
      '{"ctime": $ctime'
      ', "ctype": 10004, "cver": "v1.0", "guid": "$guid'
      '", "mat": $mat'
      ', "mcount": 1, "pid": 0, "sver": "3.1.0", "vid": "$vid'
      '"}';

  /// URL sign（MTOP h5 标准签名，**round-2 probe 实证成立**）。
  ///
  /// `md5(token + '&' + t + '&' + appKey + '&' + data)`：
  /// ```text
  /// token  _m_h5_tk 下划线前半段（step1 拿到；首跳无令牌时为空串）
  /// t      时间戳（probe 实证秒/毫秒都被网关收下，实现取秒）
  /// data   POST 的 data 值（= [buildBody] 的 JSON 本体，不含 'data=' 前缀）
  /// ```
  /// ⚠️ 所有调用方都从 [signFor] 取签名；改口径只动这一个函数。
  static String signFor(String token, int t, String data) =>
      md5.convert(utf8.encode('$token&$t&$appKey&$data')).toString();

  /// 拉取 URL（n6 两个 URL 前缀串逐字拼接，中段是 `t=<ts>`；probe 实测形态）
  static Uri buildUri({required int t, required String sign}) => Uri.parse(
      '$endpoint?jsv=2.7.0&appKey=$appKey&t=$t&api=$apiName&v=1.0'
      '&type=originaljson&dataType=jsonp&timeout=20000'
      '&jsonpIncPrefix=utility&sign=$sign');

  /// 从用户输入里提取 vid：站源播放链接（`…id_X…` 段）取其 vid，裸 vid 原样收。
  ///
  /// ⚠️ vid 的规范形态（带不带 `==` 后缀等）**未取证**——probe 的 vid 来自
  ///   页面 `"videoId":"X…"` 字面（末尾 `==` 被 probe 剥掉后请求到了令牌层，
  ///   未见 vid 相关报错，但也没走到弹幕校验那一步）。这里只做**提取**，
  ///   不做规范化，用户给什么带什么。
  static String? vidFromInput(String raw) {
    final s = raw.trim();
    if (s.isEmpty) return null;
    if (s.startsWith('X') && s.length >= 10 && !s.contains(' ')) return s;
    final m = RegExp(r'id_(X[0-9A-Za-z=+/]+)').firstMatch(s);
    return m?.group(1);
  }

  // ── 拉取（两步令牌流，probe 实证）────────────────────────────────────

  /// 拉取一个视频的弹幕列表。
  ///
  /// # 流程（两步，probe 实证）
  /// ```text
  /// step1 无令牌请求（sign 用空 token）⇒ 网关回 FAIL_SYS_TOKEN_EMPTY +
  ///   Set-Cookie `_m_h5_tk`（MTOP 拿令牌的正规第一步，不是错误路径）
  /// step2 带 Cookie + token 参签重放（新 t）⇒ ret = SUCCESS/空 = 成功，
  ///   否则抛 ret 原文
  /// ```
  ///
  /// [mat] 语义未取证（取证只见字段名）；probe 用 1 请求成功（SUCCESS），
  /// 默认 1。返回 [] = 网关明确说这一段没有弹幕（诚实空，与失败分开）。
  Future<List<DanmakuComment>> fetch({required String vid, int mat = 1}) async {
    final v = vid.trim();
    if (v.isEmpty || !v.startsWith('X')) {
      throw DanmakuException('站源弹幕需要一个 vid（站源视频 id，X 开头）');
    }
    final now = _clock();
    if (_cooldownUntil != null && now.isBefore(_cooldownUntil!)) {
      final left = _cooldownUntil!.difference(now).inSeconds;
      throw DanmakuException(
          '站源弹幕处于风控冷却中（$left 秒后再试）。上次失败：$_lastError');
    }
    final key = '$v|$mat';
    final hit = _cache[key];
    if (hit != null && now.difference(hit.$2) < cacheTtl) {
      return hit.$1;
    }
    try {
      final comments = await _fetchUncached(v, mat);
      _cache[key] = (comments, _clock());
      return comments;
    } on DanmakuException catch (e) {
      // 失败 ⇒ 30s 冷却 + 记住原文（冷却提示里要带出"上次失败是什么"）
      _cooldownUntil = _clock().add(cooldown);
      _lastError = e.message;
      rethrow;
    }
  }

  Future<List<DanmakuComment>> _fetchUncached(String vid, int mat) async {
    // step1：无令牌（拿 _m_h5_tk，probe 实证这一步必回 TOKEN_EMPTY+Set-Cookie）
    final r1 = await _post(vid: vid, mat: mat, token: '', cookies: const {});
    final cookies = _h5TokenCookies(r1.headers);
    final ret1 = _retOf(r1);
    if (ret1 == null || !_isTokenEmptyRet(ret1)) {
      // 有些场景第一步就直接成功/直接报别的错——都按信封如实处理
      return _parseEnvelope(r1);
    }
    if (cookies.isEmpty) {
      throw DanmakuException(
        '站源弹幕网关要求令牌，但响应里没有 _m_h5_tk cookie',
        statusCode: r1.statusCode,
        body: _clip(r1.body),
        uri: endpoint,
      );
    }
    // step2：带令牌重放（新 t；token 参签——round-2 实证口径）
    final token = cookies['_m_h5_tk']!.split('_').first;
    final r2 = await _post(vid: vid, mat: mat, token: token, cookies: cookies);
    return _parseEnvelope(r2);
  }

  static bool _isTokenEmptyRet(List<String> ret) =>
      ret.any((s) => s.startsWith('FAIL_SYS_TOKEN_EMPTY'));

  Future<DanmakuHttpResponse> _post({
    required String vid,
    required int mat,
    required String token,
    required Map<String, String> cookies,
  }) async {
    final ts = _clock().millisecondsSinceEpoch ~/ 1000;
    final body = buildBody(vid: vid, mat: mat, ctime: ts);
    final uri = buildUri(t: ts, sign: signFor(token, ts, body));
    final headers = <String, String>{
      'Accept': 'application/json, text/plain, */*',
      'Content-Type': 'application/x-www-form-urlencoded',
      'Origin': gatewayOrigin,
      'Referer': '$gatewayOrigin/',
      if (cookies.isNotEmpty)
        'Cookie': cookies.entries.map((e) => '${e.key}=${e.value}').join('; '),
    };
    try {
      return await _transport.send(
        method: 'POST',
        uri: uri,
        headers: headers,
        body: 'data=$body',
      );
    } catch (e) {
      // 网络层异常也要留痕不静默；不带签名/令牌原文（无敏感值可泄）
      throw DanmakuException('站源弹幕请求失败：$e', uri: endpoint);
    }
  }

  /// 信封 → 弹幕列表（包裹层形态 round-2 逐字取证；元素级泛化探测 + 矛盾留痕）
  ///
  /// ```text
  /// ret：空 或 ["SUCCESS::…"] ⇒ 成功；其它 ⇒ 抛 ret 原文
  /// data.result：二次 JSON 编码的字符串 ⇒ 解出内层
  ///   {"code":1,"data":{"result":[…],"count":N},"message":"success"}
  /// 内层 code != 1 ⇒ 抛业务原文；result 数组元素 ⇒ fromAnyJson 泛化探测
  /// 矛盾留痕：count > 0 却解析出 0 条 ⇒ 元素字段形态对不上 ⇒ **抛**，
  ///   不许静默回空（静默失败=缺陷）
  /// ```
  List<DanmakuComment> _parseEnvelope(
    DanmakuHttpResponse r, {
    List<String>? fallbackRet,
  }) {
    final j = _decodeEnvelope(r);
    final ret = fallbackRet ?? _retOf(r) ?? const <String>[];
    final success = ret.isEmpty || ret.any((s) => s.startsWith('SUCCESS'));
    if (!success) {
      throw DanmakuException(
        '站源弹幕网关报错：${ret.first}',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    final raw = j['data'];
    final inner = _unwrapDataResult(raw, r);
    final code = _intOf(inner['code']) ?? 0;
    if (code != 1) {
      throw DanmakuException(
        '站源弹幕业务报错：code=$code ${inner['message']?.toString() ?? ''}',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    final innerData = inner['data'];
    final list = innerData is Map ? innerData['result'] : null;
    if (list is! List) {
      throw DanmakuException(
        '站源弹幕返回成功，但内层 result 不是数组（形态与取证不符）',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    final out = <DanmakuComment>[];
    for (var i = 0; i < list.length; i++) {
      final c = DanmakuComment.fromAnyJson(list[i], fallbackCid: i + 1);
      if (c != null) out.add(c);
    }
    // ★ 矛盾留痕：网关报了 N 条却一条都没解析出来 ⇒ 元素字段形态与
    //   泛化探测不对上（元素级字段未取证）——把首个元素原文带出去排障。
    final count = _intOf(innerData is Map ? innerData['count'] : null) ?? 0;
    if (count > 0 && out.isEmpty) {
      final sample = list.isEmpty
          ? ''
          : _clip(jsonEncode(list.first), 600);
      throw DanmakuException(
        '站源弹幕网关报 $count 条，但元素字段形态未对上（元素级字段未取证），'
        '解析结果 0 条。首元素原文：$sample',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    out.sort((a, b) => a.time.compareTo(b.time));
    return out;
  }

  /// `data.result` 是二次 JSON 编码的字符串（round-2 逐字取证）；解开它
  Map<String, dynamic> _unwrapDataResult(Object? raw, DanmakuHttpResponse r) {
    Object? inner;
    if (raw is Map && raw['result'] is String) {
      try {
        inner = jsonDecode(raw['result'] as String);
      } catch (e) {
        throw DanmakuException(
          '站源弹幕返回成功，但内层 result 不是合法 JSON：$e',
          statusCode: r.statusCode,
          body: _clip(r.body),
          uri: endpoint,
        );
      }
    } else if (raw is Map<String, dynamic>) {
      // 兼容：万一某天网关不再二次编码（直接给对象）——按内层信封收
      inner = raw;
    }
    if (inner is! Map<String, dynamic>) {
      throw DanmakuException(
        '站源弹幕返回成功，但 data.result 形态与取证不符（非二次 JSON 字符串）',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    return inner;
  }

  /// 弹弹play 整数可能以 int/String 出现；这里同样统一成 int（本库私有版）
  static int? _intOf(Object? v) {
    if (v == null) return null;
    if (v is int) return v;
    if (v is num) return v.toInt();
    return int.tryParse(v.toString());
  }

  Map<String, dynamic> _decodeEnvelope(DanmakuHttpResponse r) {
    if (!r.isOk) {
      throw DanmakuException(
        '站源弹幕网关返回 HTTP ${r.statusCode}',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    Object? j;
    try {
      j = jsonDecode(r.body);
    } catch (e) {
      throw DanmakuException(
        '站源弹幕网关返回的不是 JSON：$e',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    if (j is! Map<String, dynamic>) {
      throw DanmakuException(
        '站源弹幕网关返回的 JSON 结构不对（信封不是对象）',
        statusCode: r.statusCode,
        body: _clip(r.body),
        uri: endpoint,
      );
    }
    return j;
  }

  /// 信封里的 `ret` 数组（probe 实证：`["FAIL_SYS_XXX::中文"]`，成功为空）
  static List<String>? _retOf(DanmakuHttpResponse r) {
    Object? j;
    try {
      j = jsonDecode(r.body);
    } catch (_) {
      return null;
    }
    if (j is! Map<String, dynamic>) return null;
    final ret = j['ret'];
    if (ret is! List) return null;
    return <String>[for (final e in ret) '$e'];
  }

  /// 从响应头里取 `_m_h5_tk` / `_m_h5_tk_enc`（DanmakuHttpResponse 的头键
  /// 统一小写、多值以 ', ' 连接，正则按值形态取，不按分隔切）
  static Map<String, String> _h5TokenCookies(Map<String, String> headers) {
    final raw = headers['set-cookie'] ?? '';
    final out = <String, String>{};
    final tk = RegExp(r'_m_h5_tk=([0-9a-f]+_[0-9]+)').firstMatch(raw);
    final enc = RegExp(r'_m_h5_tk_enc=([0-9a-f]+)').firstMatch(raw);
    if (tk != null) out['_m_h5_tk'] = tk.group(1)!;
    if (enc != null) out['_m_h5_tk_enc'] = enc.group(1)!;
    return out;
  }

  static String _clip(String s, [int max = 2000]) =>
      s.length <= max ? s : s.substring(0, max);

  void close() => _transport.close();
}

/// 站源弹幕来源的用户配置（UiPrefs，键名前缀与弹幕既有一致）
///
/// # 默认行为零变化（Owner 批复）
/// ```text
/// enabled 默认 false ⇒ 不配置时站源这条路**根本不存在**，
/// 既有弹幕来源（dan-api / 自建 / 本机 / 插件）的一切行为逐字不变。
/// ```
class MopenDanmuConfig {
  /// 来源开关（"1"/"0"，缺省 "0"）
  static const String keyEnabled = 'dsh.danmaku.mopen.enabled';

  /// 用户输入的 vid（站源视频 id，可从播放链接提取）
  static const String keyVid = 'dsh.danmaku.mopen.vid';

  /// mat 参数（语义未取证，见 [MopenDanmuClient.fetch]；缺省 "1"）
  static const String keyMat = 'dsh.danmaku.mopen.mat';

  const MopenDanmuConfig._();

  static bool get enabled => UiPrefs.get(keyEnabled) == '1';

  static void setEnabled(bool v) {
    if (v) {
      UiPrefs.set(keyEnabled, '1');
    } else {
      UiPrefs.remove(keyEnabled);
    }
  }

  static String get vid => (UiPrefs.get(keyVid) ?? '').trim();

  static void setVid(String v) {
    final t = v.trim();
    if (t.isEmpty) {
      UiPrefs.remove(keyVid);
    } else {
      UiPrefs.set(keyVid, t);
    }
  }

  static int get mat => int.tryParse(UiPrefs.get(keyMat) ?? '') ?? 1;

  static void setMat(String v) {
    final t = v.trim();
    if (t.isEmpty || int.tryParse(t) == null) {
      UiPrefs.remove(keyMat);
    } else {
      UiPrefs.set(keyMat, t);
    }
  }
}
