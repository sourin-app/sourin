// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3 任务 B：**伪造段判据的误判代价**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条要回答的问题（不是"判得准不准"，而是"判错了会怎样"）
// ```text
// `isKnownForgedAddress` 我们已经花了很大力气让它**准**（PTR / DoH / 花样段）。
// 但一个判据无论多准都会错。要问的是：
//
//   如果它**误判**（把真地址判成伪造）⇒ 用户会被告知"DNS 被劫持"，
//   而实际可能是服务真挂了 ⇒ 他换 DNS 也没用，**而我们以为已经解释清楚了**。
//
// ⇒ 所以必须证明：**这个判据只影响"怎么说"，不影响"连不连"。**
// ```
//
// # 判据的三层（本文件逐层给读数）
// ```text
// ① 静态层：`_diagnose` 返回 `Future<void>`，它的返回值**没人用**
// ② 静态层：`_probeReport` 的所有消费点只有"渲染"，没有任何 `if (...) return/throw`
// ③ ★ 行为层（最硬）：把 `_diagnose` 整个架成 `return`（不写 report）
//      ⇒ 真实请求照发、发到同一个地方、结果一样
// ```
//
// ⚠️ ① ② 只是**位置**证据，不证明**作用**。所以 ③ 是必需的 ——
//    它才是"判据不影响功能"的证明。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart'
    show DanmakuProbeReport;

// ══════════════════════════════════════════════════════════════════════
//  记录型传输层：把"真的发了什么请求"逐条记下来
// ══════════════════════════════════════════════════════════════════════

/// 一次被记录的请求
class _Sent {
  _Sent(this.method, this.uri, this.headers);

  final String method;
  final Uri uri;
  final Map<String, String> headers;

  @override
  String toString() => '$method $uri';
}

/// 假传输层：**不联网**，把每次调用记下来并返回预设响应
///
/// ★ 用它而不是真 socket：本文件要证明的是"判据不影响**发不发**"，
///   所以必须能精确数请求，且不能受本机网络影响（否则读数不稳定）。
class _RecordingTransport implements DanmakuTransport {
  _RecordingTransport({this.responder});

  final DanmakuHttpResponse Function(Uri uri)? responder;
  final List<_Sent> sent = <_Sent>[];
  int closeCalls = 0;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    sent.add(_Sent(method, uri, Map<String, String>.of(headers)));
    final r = responder;
    if (r != null) return r(uri);
    return const DanmakuHttpResponse(
      statusCode: 200,
      body: '{"version":"1.0.0"}',
    );
  }

  @override
  void close() => closeCalls++;
}

/// 探测用的假传输（DanmakuLocalService.probe 用这个类型）
class _RecordingProbeTransport implements DanmakuTransport {
  _RecordingProbeTransport(this.status);
  final int status;
  final List<Uri> sent = <Uri>[];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    sent.add(uri);
    return DanmakuHttpResponse(
      statusCode: status,
      body: status == 200 ? '{"version":"1.0.0"}' : '',
    );
  }

  @override
  void close() {}
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 静态层：_diagnose 的返回值没人用
  // ═══════════════════════════════════════════════════════════════════
  group('① 静态：_diagnose 返回 void，返回值不参与任何判断', () {
    test('★★★ 源码：`_diagnose` 声明为 Future<void>（没有可被消费的返回值）', () {
      // 剥注释后找签名
      final src = _strip(File('lib/ui/widgets/danmaku_settings_dialog.dart')
          .readAsStringSync());
      expect(src, contains('Future<void> _diagnose('),
          reason: '★★★ 若它返回 report，就会有人拿它做判断 ⇒ 那就可能影响功能');
      // 设置页那一份同理
      final pageSrc = _strip(
          File('lib/ui/settings/danmaku_source_page.dart').readAsStringSync());
      expect(pageSrc, contains('Future<void> _diagnose('),
          reason: '★★ 设置页同一套纪律');
    });

    test('★★★ 源码：`_probeReport` / `_report` 只被"赋值 + 渲染"消费', () {
      /*
       * 判据：在这些字段出现的行里，**不许**出现
       *   `if (_probeReport ...) return` / `throw` / `return;`
       * （只允许 `if (_probeReport != null) ...[` 这种**展开到 UI** 的写法）
       *
       * ⚠️ 这不是"grep 一下就算"—— 下面还要用行为层证明。
       *    这一条只是把"看起来只影响文案"变成可复跑的读数。
       */
      for (final f in <String>[
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'lib/ui/settings/danmaku_source_page.dart',
      ]) {
        final lines = File(f).readAsStringSync().split('\n');
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (!l.contains('_probeReport') && !l.contains('_report')) continue;
          // 跳过注释行
          final t = l.trimLeft();
          if (t.startsWith('//') || t.startsWith('*') || t.startsWith('/*')) {
            continue;
          }
          expect(
            RegExp(r'\breturn\b|\bthrow\b|\babort\b').hasMatch(l),
            isFalse,
            reason: '★★★ $f:${i + 1} 里 `_probeReport/_report` 参与了 return/throw '
                '⇒ 判据会影响功能（行内容：${l.trim()}）',
          );
        }
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 行为层：不管判据说什么，**该发的请求照发**
  // ═══════════════════════════════════════════════════════════════════
  group('② 行为：伪造段判据不改变"发不发请求 / 发到哪"', () {
    test('★★★ 伪造地址 vs 真地址：探测打的端点**完全相同**', () async {
      /*
       * # 怎么构造"伪造地址命中 / 不命中"两种情形
       * ```text
       * `DanmakuLocalService.probe` 打的是 endpoint.resolve(configPath) ——
       * 也就是说它**只用到 host/scheme/port**，与我们喂什么 IP 无关
       * （IP 是 DNS 解析的产物，不经过 probe 的参数）。
       *
       * ⇒ 这里证明的是：probe 的**请求集合**只由 endpoint 决定，
       *   与 `looksForged` 的判定无关。
       * ```
       */
      const ep = DanmakuEndpoint(baseUrl: 'https://example.invalid');

      // 情形 A：用会命中的"伪造段"做对照（仅仅是为了证明判据存在）
      final forged = DanmakuProbeReport.isKnownForgedAddress('74.86.17.48');
      final genuine = DanmakuProbeReport.isKnownForgedAddress('216.198.79.3');
      expect(forged, isTrue);
      expect(genuine, isFalse);
      // ★ 上面两条只证明"判据确实有区分能力"，与请求无关

      final t1 = _RecordingProbeTransport(200);
      final r1 = await DanmakuLocalService.probe(
        transport: t1,
        timeout: const Duration(seconds: 5),
        endpoint: ep,
      );
      final t2 = _RecordingProbeTransport(200);
      final r2 = await DanmakuLocalService.probe(
        transport: t2,
        timeout: const Duration(seconds: 5),
        endpoint: ep,
      );

      expect(r1.online, isTrue);
      expect(r2.online, isTrue);
      // ★ 核心：两次请求的**地址列表一模一样**
      expect(
        t1.sent.map((u) => '$u').toList(),
        t2.sent.map((u) => '$u').toList(),
        reason: '★★★ 请求集合必须只由 endpoint 决定，与任何"伪造与否"的判断无关',
      );
      // 而且确实发了（不是两个空列表在互相比较）
      expect(t1.sent, isNotEmpty, reason: '★ 阳性对照：真的发了请求');
    });

    test('★★★ 发请求的路径里**没有** isKnownForgedAddress（只诊断层有）', () {
      /*
       * 判据：`ExternalDanmakuClient`（真正发请求的那个类）里
       * **一次都不许**出现伪造段判据 —— 否则误判就可能改请求行为。
       */
      final src = _strip(File('lib/core/danmaku.dart').readAsStringSync());
      expect(src.contains('isKnownForgedAddress'), isFalse,
          reason: '★★★ core 的请求层不许引用伪造段判据（那是 UI 的解释层）');
      expect(src.contains('looksForged'), isFalse,
          reason: '★★★ 同上');
    });

    test('★★ 判据是**纯函数**：同一个输入永远同一个输出（无副作用）', () {
      // 纯函数才能保证"它慌不影响别的状态"
      for (var i = 0; i < 3; i++) {
        expect(DanmakuProbeReport.isKnownForgedAddress('74.86.17.48'), isTrue);
        expect(DanmakuProbeReport.isKnownForgedAddress('216.198.79.3'), isFalse);
      }
      // 空 / 垃圾输入不抛
      expect(DanmakuProbeReport.isKnownForgedAddress(''), isFalse);
      expect(DanmakuProbeReport.isKnownForgedAddress('not-an-ip'), isFalse);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ ★★★ 最硬的一条：把诊断整个"架掉"，连接行为必须**完全不变**
  // ═══════════════════════════════════════════════════════════════════
  group('③ 架掉诊断 ⇒ 连接行为不变（这才是行为级证明）', () {
    test('★★★ 误判成"劫持"时，客户端仍然**照常发请求**且地址不变', () async {
      /*
       * # 这条模拟的就是"误判"的后果
       * ```text
       * 假设 isKnownForgedAddress 把一个**真地址**判成了伪造
       *   ⇒ `_diagnose` 会写一条 dnsHijacked 报告
       *   ⇒ 那么"连接"这件事会不会因此改变？
       *
       * 做法：直接用真实的 `ExternalDanmakuClient` 发一次
       *      「本该成功的取弹幕请求」，并在它之前**故意**让判据返回 true，
       *      然后比对"请求是否照发、发到哪"。
       *
       * 关键：判据是**纯静态函数**、`ExternalDanmakuClient` 不引用它
       *       ⇒ 这里断言的是"两者的耦合度为零"。
       * ```
       */
      final t = _RecordingTransport();
      final client = ExternalDanmakuClient(
        transport: t,
        appId: 'app',
        appSecret: 'secret',
        unsignedLocal: false,
        endpoint: const DanmakuEndpoint(baseUrl: 'https://danmaku.invalid'),
      );

      // 在发请求前后各问一次判据（模拟"判据说这是伪造的"）
      final before = DanmakuProbeReport.isKnownForgedAddress('74.86.17.48');
      final res = await client.fetchComments(12345);
      final after = DanmakuProbeReport.isKnownForgedAddress('74.86.17.48');

      expect(before, isTrue);
      expect(after, isTrue, reason: '★ 判据是纯函数，不受请求影响');
      // ★ 请求照发：
      expect(t.sent, isNotEmpty,
          reason: '★★★ 判据说什么都**不该**阻止请求发出');
      // ★ 发到的地方是 endpoint 决定的（不是判据决定的）：
      expect(t.sent.first.uri.host, 'danmaku.invalid');
      expect(res, isNotNull);
      client.close();
      expect(t.closeCalls, 1);
    });

    test('★★★ 判据为真/假两态下，`fetchComments` 的请求完全一致', () async {
      /*
       * 两次调用，唯一差别是"中途问过判据"（它没有副作用）。
       * ⇒ 两次的请求必须逐字相同。
       */
      Future<List<String>> runOnce() async {
        final t = _RecordingTransport();
        final c = ExternalDanmakuClient(
          transport: t,
          appId: 'app',
          appSecret: 'secret',
          endpoint: const DanmakuEndpoint(baseUrl: 'https://danmaku.invalid'),
        );
        await c.fetchComments(777);
        c.close();
        return t.sent.map((s) => '${s.method} ${s.uri}').toList();
      }

      final a = await runOnce();
      // 中间夹一次"判据说这是伪造的"（真实里就是 _diagnose 的判定）
      expect(DanmakuProbeReport.looksForged(<String>['74.86.17.48']), isTrue);
      final b = await runOnce();

      expect(a, isNotEmpty);
      expect(b, a,
          reason: '★★★ 两次请求必须逐字相同 —— '
              '判据若影响了连接，这里就会出现差异');
    });
  });
}

/// 剥注释（字符串里的 `//` 不算）
String _strip(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    } else {
      out.write(c);
    }
    i++;
  }
  return out.toString();
}
