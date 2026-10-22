// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3-③ / R3-⑦ 内置 dan-api 不可用 —— **让 UI 说真话**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，两条指向同一件事）
// ```text
// R3-③「弹幕来源搜不了」
// R3-⑦「内置两个 dan-api 根本用不了」
// ```
//
// # 根因（已由 Lead 查明，本轮**不重修**）
// ```text
// `kDanmakuPublicInstances` 的两个内置实例都是 `*.vercel.app`：
//   https://danmu-api-delta.vercel.app
//   https://danmu-api-kappa.vercel.app
// ```
//
// # 本轮实测（2026-10-19，本机，dart:io 真跑；不是抄结论）
// ```text
// $ InternetAddress.lookup('danmu-api-delta.vercel.app')
//   → 2a03:2880:f10c:283:face:b00c:0:25de / 31.13.87.19     ← **解析得到**
// $ Socket.connect(host, 443)
//   → SocketException: Connection timed out (errno 10060) 6.0s  ← **连不上**
// $ danmu-api-kappa.vercel.app → 同上
// $ 对照：一个真不存在的域名 → errno 11001「不知道这样的主机」10ms
// $ 对照：vercel.com → 200（所以不是"vercel 整片挂了"）
// ```
//
// # ★★★ 上面这段读数**曾经**被写成「DNS 没被污染、断在 TCP」—— 那个结论是错的
// ```text
// 错的归因：解析没抛异常 ⇒ 判定 DNS 正常 ⇒ TCP 超时是**独立病因**
// 事实（读数本身全是真的，只有归因错）：
//   ✓ 真的：解析确实没抛异常
//   ✓ 真的：TCP 确实超时
//   ✗ 假的：**TCP 连的那个地址本来就是错的** ⇒ 超时是劫持的**后果**
// ```
//
// # 拿什么证据推翻的：必须与**权威/加密通道（DoH/DoT）真值**对照
// ```text
// $ curl -s "https://cloudflare-dns.com/dns-query?name=danmu-api-delta.vercel.app&type=A" \
//       -H "accept: application/dns-json"
//   → 216.198.79.3 / 64.29.17.3
//
// 本机 DNS   74.86.17.48        + 2a03:2880:…:face:b00c
// DoH 真值   216.198.79.3 / 64.29.17.3      ✗ 完全不是一组
//
// ★ 判据因此成形（读这个文件的人该带走的）：
//   **「能解析」不是「解析正确」的同义词。**
//   判 DNS 是否被劫持**必须**拿 DoH/DoT 真值做对照 —— 只看 getaddrinfo
//   有没有抛异常，会把「劫持」误判成「网络不通」：劫持的实现方式
//   恰恰是"正常返回一个假地址"，这个判据对它**结构性失明**。
//
// ⚠️ 详见 docs/notes/2026-10-19-dns-hijack-vs-tcp.md（三层读数）与
//    .agents/notes/implemented/testing/2026-10-19-dns-hijack-needs-authoritative-truth.md
//
// # 所以本轮**不假装修好**，只做一件事：**UI 说真话**
// ```text
// 改前：core 的 `_probeOne` 刻意吞异常并返回 null ⇒ UI 只有一句
//       「内置公共实例（…）暂时连不上」
//       把三件完全不同的事混成一句：
//         ① 域名解析不出来（本机 DNS 坏了）      ⇒ 换网络
//         ② 解析出来了但连不上                  ⇒ 被墙/代理/路由
//         ③ 连上了但服务报错（真·服务端问题）
//       以及第四类**根本不是失败**的：④ 连上了，但这一集/这个词没有弹幕
//       ⚠️ ② 当年还标着「本机就是这一类」—— 正因为它**同时**覆盖了
//          "被墙"与"被劫持"两种病因完全不同的情形，这一档后来才必须
//          再拆出 `dnsHijacked`（判据见上：真值是**劫持**，不是"网络不通"）。
// 改后：`DanmakuProbeReport` 按真实 errno / 异常类型分类，文案分叉。
// ```
//
// # 本门禁钉什么
// ```text
// ① DNS 失败（errno 11001）⇒ 文案必须说「域名解析失败」，且**不许**说服务坏了
// ② 连接超时（errno 10060 / TimeoutException）⇒ 「连不上（连接超时）」，
//    且必须点明是**本机网络/代理**这一侧，不是"服务没有运行"
// ③ 连接被拒（errno 10061/1225）⇒ 「连不上（连接被拒绝）」，这条才该说"服务没起来"
// ④ 服务返回错误（HTTP 5xx/401）⇒ 「服务返回错误」，**不许**说成连不上
// ⑤ 服务返回空 ⇒ 「服务正常，但没有弹幕」——**不是失败**，不许画成红色报错
// ⑥ ★★★ DNS 失败与"服务返回空"的文案**必须可区分**（Owner 那条要求的核心）
// ⑦ 面板与设置页用**同一份**分类（防止两处漂移）
// ```
//
// # 故障注入（已实测）
// ```text
// ① 把 `fromError` 里 SocketException 一律归成 connectionTimeout（不分 errno）
//    ⇒ ①②③ 组的区分断言红
// ② 把 emptyResponse 也归成 isFailure ⇒ ⑤ 组红
// ③ 把 `_probeReportBox` 删掉（不画）⇒ 全部 UI 断言红
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

// ══════════════════════════════════════════════════════════════════════
//  分类层（纯函数，不挂 UI）—— 判据必须来自**真实 errno**
// ══════════════════════════════════════════════════════════════════════

/// 造一个真实形状的 SocketException（与 Windows 上实测的 errno 一致）
///
/// ⚠️ 用真的 `SocketException` 构造而不是自己 implements：
///    `SocketException` 是 final-ish 的（`implements` 会报非 class），
///    而且用真类型能保证判据面对的就是生产里那个类型。
Object _sock(int errno, String msg) => SocketException(
      msg,
      osError: OSError(msg, errno),
    );

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 分类：四类失败 + 一类"不是失败"，判据全部来自真实 errno
  // ═══════════════════════════════════════════════════════════════════
  group('① 失败分类（真实 errno ⇒ 正确档位）', () {
    test('★★★ errno 11001（不知道这样的主机）⇒ dnsFailed', () {
      final r = DanmakuProbeReport.fromError(
        _sock(11001, '不知道这样的主机。'),
        url: 'https://x.invalid',
      );
      expect(r.failure, DanmakuProbeFailure.dnsFailed,
          reason: '★★★ 这是实测的真·DNS 失败（11001）');
      expect(r.failure.title, contains('域名解析失败'));
    });

    test('★★★ errno 10060（连接超时）⇒ connectionTimeout，且判据识别为"本机网络问题"',
        () {
      final r = DanmakuProbeReport.fromError(
        _sock(10060, 'Connection timed out'),
        url: 'https://danmu-api-delta.vercel.app',
      );
      expect(r.failure, DanmakuProbeFailure.connectionTimeout,
          reason: '★★★ 这是**本机实测**的内置实例失败档位');
      expect(r.failure.isLocalNetworkProblem, isTrue,
          reason: '★★★ 该怪本机网络/代理，不该怪服务');
      expect(r.failure.isServiceProblem, isFalse);
    });

    test('★★★ errno 10061 / 1225（连接被拒）⇒ connectionRefused', () {
      for (final code in <int>[10061, 1225]) {
        final r = DanmakuProbeReport.fromError(
          _sock(code, '远程计算机拒绝网络连接。'),
          url: 'http://127.0.0.1:2080',
        );
        expect(r.failure, DanmakuProbeFailure.connectionRefused,
            reason: '★★★ errno $code 是"这个地址上没有服务在听"');
      }
    });

    test('★★ TimeoutException（没有 errno）⇒ connectionTimeout', () {
      final r = DanmakuProbeReport.fromError(
        TimeoutException('Future not completed', const Duration(seconds: 8)),
        url: 'https://x',
      );
      expect(r.failure, DanmakuProbeFailure.connectionTimeout);
    });

    test('★★ TLS 握手失败 ⇒ tlsFailed（与"连不上"分开）', () {
      final r = DanmakuProbeReport.fromError(
        Exception('HandshakeException: CERTIFICATE_VERIFY_FAILED'),
        url: 'https://x',
      );
      expect(r.failure, DanmakuProbeFailure.tlsFailed,
          reason: '★ 中间人代理与"被墙"是两种问题，修法不同');
    });

    test('★★ HTTP 错误 ⇒ serverError（这条才该怪服务端）', () {
      final r = DanmakuProbeReport.httpError(
        url: 'https://x',
        statusCode: 500,
      );
      expect(r.failure, DanmakuProbeFailure.serverError);
      expect(r.failure.isServiceProblem, isTrue);
      expect(r.failure.isLocalNetworkProblem, isFalse,
          reason: '★★ 服务端问题不许被归到"你网络不好"');
    });

    test('★★★ 服务返回空 ⇒ emptyResponse，且 **不是失败**', () {
      final r = DanmakuProbeReport.empty(url: 'https://x');
      expect(r.failure, DanmakuProbeFailure.emptyResponse);
      expect(r.failure.isJustEmpty, isTrue);
      expect(r.failure.isFailure, isFalse,
          reason: '★★★ 「服务活着但没有这一集」是**正常结果**，'
              '画成失败会让用户去修一个没坏的东西');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② ★★★ Owner 那条要求的核心：DNS 失败 ≠ 服务返回空
  // ═══════════════════════════════════════════════════════════════════
  group('② DNS 失败 / 连接超时 / 服务返回空 三者文案必须可区分', () {
    test('★★★ 三种情形的 title 两两不同', () {
      final dns = DanmakuProbeReport.fromError(
        _sock(11001, '不知道这样的主机。'),
        url: 'https://a',
      );
      final timeout = DanmakuProbeReport.fromError(
        _sock(10060, 'Connection timed out'),
        url: 'https://a',
      );
      final empty = DanmakuProbeReport.empty(url: 'https://a');

      final titles = <String>{
        dns.failure.title,
        timeout.failure.title,
        empty.failure.title,
      };
      expect(titles.length, 3,
          reason: '★★★ 三件事各有一句话 —— 混成一句就是本轮要修的病');
    });

    test('★★★ DNS 失败的 remedy 必须点明「不是服务坏了」', () {
      final r = DanmakuProbeReport.fromError(
        _sock(11001, '不知道这样的主机。'),
        url: 'https://a',
      );
      expect(r.remedy, contains('不是'));
      expect(r.remedy, contains('DNS'),
          reason: '★★★ 用户要知道该去修 DNS，而不是去改弹幕地址');
    });

    test('★★★ 超时的 remedy 必须点明是**本机网络/代理**这一侧', () {
      final r = DanmakuProbeReport.fromError(
        _sock(10060, 'Connection timed out'),
        url: 'https://danmu-api-delta.vercel.app',
      );
      expect(r.remedy, contains('代理'),
          reason: '★★★ 本机实测就是这一类 —— 唯一有用的下一步是动代理');
      expect(r.remedy, contains('不是"服务没运行"'),
          reason: '★★★ 必须**明确否掉**那句会误导人的话');
    });

    test('★★★ 服务返回空的 remedy 不许提"去改配置"', () {
      final r = DanmakuProbeReport.empty(url: 'https://a');
      expect(r.remedy, contains('不用去改配置'),
          reason: '★★★ 服务活着 ⇒ 改配置没有任何用');
    });

    test('★★ 内置实例的真实失败（errno 10060）不会被说成"没运行"', () {
      final r = DanmakuProbeReport.fromError(
        _sock(10060, 'Connection timed out'),
        url: 'https://danmu-api-delta.vercel.app',
      );
      final text = '${r.failure.title} ${r.remedy}';
      expect(text, isNot(contains('未运行')),
          reason: '★★ "未运行"是 connectionRefused 的说法，这里用它是错的');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ UI：面板里真的把分类画出来（行为断言，不是"字段存在"）
  // ═══════════════════════════════════════════════════════════════════
  group('③ 播放页面板：分类文案真的画出来', () {
    setUp(() => UiPrefs.debugResetForTest());
    tearDown(() => UiPrefs.debugResetForTest());

    /// 挂面板，注入一个"探针直接抛"的实现（零联网），跑一次测试连接
    Future<void> probeWith(WidgetTester t, Object error) async {
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: DanmakuSettingsDialog(
            state: const DanmakuSettingsState(
              enabled: true,
              appId: '',
              appSecret: '',
              fontScale: 1,
              opacity: 1,
              speed: 8,
              area: 1,
            ),
            onSetEnabled: (_) {},
            onSetFontScale: (_) {},
            onSetOpacity: (_) {},
            onSetSpeed: (_) {},
            onSetArea: (_) {},
            onReload: () {},
            onClose: () {},
            // 探针抛异常 ⇒ 走 `_runProbe` 的 catch 分支（不联网）
            probeOverride: (DanmakuEndpoint? e) async => throw error,
          ),
        ),
      ));
      await t.pumpAndSettle();
      // 切到「高级」页签，那里有 dan-api 的测试按钮
      await t.tap(find.descendant(
        of: find.byType(SegmentedButton<DanmakuPanelTab>),
        matching: find.text('高级'),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
    }

    testWidgets('★★★ DNS 失败 ⇒ 面板说「域名解析失败」', (t) async {
      await probeWith(t, _sock(11001, '不知道这样的主机。'));

      expect(find.textContaining('域名解析失败'), findsOneWidget,
          reason: '★★★ 分类必须出现在屏幕上（只存在字段里不算）');
      expect(find.textContaining('DNS'), findsWidgets,
          reason: '★ 要指明是 DNS 这一层');
    });

    testWidgets('★★★ 连接超时 ⇒ 面板说「连不上（连接超时）」', (t) async {
      await probeWith(t, _sock(10060, 'Connection timed out'));

      // 标题里带档位；remedy 里也会出现「连不上」，所以用 findsWidgets
      expect(find.textContaining('连不上'), findsWidgets);
      expect(find.textContaining('连不上（连接超时）'), findsOneWidget,
          reason: '★★★ 与"域名解析失败"必须能区分开');
      // ★ 反证：DNS 那档的标题**不该**出现
      expect(find.textContaining('域名解析失败'), findsNothing);
    });

    testWidgets('★★★ 连接被拒 ⇒ 面板说「连接被拒绝」（与服务问题是两件事）',
        (t) async {
      await probeWith(t, _sock(10061, '远程计算机拒绝网络连接。'));

      expect(find.textContaining('连不上（连接被拒绝）'), findsOneWidget,
          reason: '★★ 标题带档位（remedy 里也有「连接被拒绝」四个字，所以用带前缀的写法）');
      expect(find.textContaining('连不上（连接超时）'), findsNothing,
          reason: '★★ 被拒 ≠ 超时：一个该去启动服务，一个该去动代理');
    });

    testWidgets('★★ 机械细节（errno 原文）也要透出来', (t) async {
      await probeWith(t, _sock(10060, 'Connection timed out'));

      expect(find.textContaining('errno 10060'), findsOneWidget,
          reason: '★★ 会贴到群里求助的人需要这个 —— 不许翻译掉');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 设置页：「弹幕源」页同样说真话（同一份分类）
  // ═══════════════════════════════════════════════════════════════════
  group('④ 设置页 · 弹幕源：用同一份分类', () {
    setUp(() => UiPrefs.debugResetForTest());
    tearDown(() => UiPrefs.debugResetForTest());

    Future<void> probeWith(WidgetTester t, Object error) async {
      /*
       * ⚠️ 视口必须够高：设置页的内容比 800×600 长，
       *    「测试连接」按钮实测落在 y=725 ⇒ 默认视口下 tap **打空**
       *    （第一版就是这么假绿的：断言失败但原因是"没点到"）。
       */
      t.view.physicalSize = const Size(1200, 1400);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: DanmakuSourcePage(
            probeOverride: (DanmakuEndpoint? e) async => throw error,
          ),
        ),
      ));
      await t.pumpAndSettle();
      await t.tap(find.text('测试连接'));
      await t.pumpAndSettle();
    }

    testWidgets('★★★ DNS 失败 ⇒ 设置页也说「域名解析失败」', (t) async {
      await probeWith(t, _sock(11001, '不知道这样的主机。'));
      expect(find.textContaining('域名解析失败'), findsOneWidget);
      await t.pump(const Duration(milliseconds: 400)); // 结清 UiPrefs 定时器
    });

    testWidgets('★★★ 连接超时 ⇒ 设置页说「连不上（连接超时）」', (t) async {
      await probeWith(t, _sock(10060, 'Connection timed out'));
      expect(find.textContaining('连不上（连接超时）'), findsOneWidget);
      expect(find.textContaining('域名解析失败'), findsNothing,
          reason: '★★ 两档不许混');
      await t.pump(const Duration(milliseconds: 400));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ ★★★ 2026-10-19（归因修正）：「能解析」≠「解析正确」
  //     —— DNS 被劫持必须与"解析失败"分开，且**优先于** TCP 超时
  // ═══════════════════════════════════════════════════════════════════
  group('⑥ DNS 劫持（解析成功但地址是伪造的）', () {
    test('★★★ 已知伪造段：本机实测到的三个都命中', () {
      /*
       * 这些是**本机实测的真实读数**（2026-10-19），不是编的：
       *   danmu-api-delta.vercel.app → 74.86.17.48 / 2a03:2880:…:face:b00c
       *   danmu-api-kappa.vercel.app → 108.160.173.207 / 2a03:2880:…:face:b00c
       *   vercel.app (apex)          → 199.96.58.15  / 2a03:2880:…:face:b00c
       */
      expect(
        DanmakuProbeReport.isKnownForgedAddress(
            '2a03:2880:f117:83:face:b00c:0:25de'),
        isTrue,
        reason: '★★★ face:b00c 是 Facebook 的固定花样段',
      );
      expect(DanmakuProbeReport.isKnownForgedAddress('74.86.17.48'), isTrue,
          reason: '★ SoftLayer 静态段（PTR: *.sl-reverse.com）');
      expect(DanmakuProbeReport.isKnownForgedAddress('108.160.173.207'), isTrue,
          reason: '★ Dropbox 段（PTR: v.dropbox.com）');
      expect(DanmakuProbeReport.isKnownForgedAddress('199.96.58.15'), isTrue);
      expect(DanmakuProbeReport.isKnownForgedAddress('157.240.2.36'), isTrue,
          reason: '★ Facebook 段（计划里早先 nslookup 拿到的就是它）');
    });

    test('★★ 真值地址不许被判成伪造（反证，防止判据写成恒真）', () {
      // DoH 实测真值 + 一个能通的对照（vercel.com）
      for (final real in <String>[
        '216.198.79.3',
        '64.29.17.3',
        '216.198.79.67',
        '64.29.17.67',
        '216.198.79.131',
        '64.29.17.131',
        '64.239.123.129', // vercel.com（这条能通，是正对照）
      ]) {
        expect(DanmakuProbeReport.isKnownForgedAddress(real), isFalse,
            reason: '★★ 真值 $real 被判成伪造 ⇒ 判据写错了（会误伤正常用户）');
      }
    });

    test('★★★ looksForged：一组里只要有一个伪造就算', () {
      expect(
        DanmakuProbeReport.looksForged(<String>[
          '2a03:2880:f117:83:face:b00c:0:25de',
          '74.86.17.48',
        ]),
        isTrue,
      );
      expect(
        DanmakuProbeReport.looksForged(<String>['216.198.79.3', '64.29.17.3']),
        isFalse,
      );
    });

    test('★★★ forHijackedDns：标题/建议/证据都与 dnsFailed **完全不同**', () {
      final hij = DanmakuProbeReport.forHijackedDns(
        url: 'https://danmu-api-delta.vercel.app',
        localAddresses: <String>['74.86.17.48'],
        dohAddresses: <String>['216.198.79.3', '64.29.17.3'],
      );
      final dns = DanmakuProbeReport.fromError(
        _sock(11001, '不知道这样的主机。'),
        url: 'https://danmu-api-delta.vercel.app',
      );

      expect(hij.failure, DanmakuProbeFailure.dnsHijacked);
      expect(hij.failure.title, isNot(dns.failure.title),
          reason: '★★★ 两句混用会把用户指向错误的修法');
      // 标题要点明"错误地址/劫持"，而不是"解析失败"
      expect(hij.failure.title, contains('错误地址'));
      expect(hij.failure.title, contains('劫持'));
      // 建议要指向"换 DNS / 开代理"，而不是"换网络"
      expect(hij.remedy, contains('DNS'));
      expect(hij.remedy, contains('代理'));
      // 证据要同时给出本机值与真值（这是用户能自查的部分）
      expect(hij.detail, contains('74.86.17.48'));
      expect(hij.detail, contains('216.198.79.3'));
      // ★ 2026-10-19（任务 B）：把"两者不一致"说得更直白
      //   （改前是"两者不一致"，用户仍要自己想"所以呢"）
      expect(hij.detail, contains('不是一个东西'),
          reason: '★ 要有把两个地址"对上"的一句话');
      // ★ 必须说清"不是服务坏了"（服务在代理下是活的）
      expect(hij.remedy, contains('不是这个服务坏了'));

      // ★ 两档都算"本机网络问题"（都不是服务端的锅）
      expect(hij.failure.isLocalNetworkProblem, isTrue);
      expect(hij.failure.isServiceProblem, isFalse);
      expect(hij.failure.isFailure, isTrue);
    });

    test('★★ 没有 DoH 佐证时也要成立（伪造段表可单独定案）', () {
      final hij = DanmakuProbeReport.forHijackedDns(
        url: 'https://x',
        localAddresses: <String>['108.160.173.207'],
      );
      expect(hij.failure, DanmakuProbeFailure.dnsHijacked);
      expect(hij.detail, contains('108.160.173.207'));
      expect(hij.detail, contains('已知的伪造段'),
          reason: '★ 没有真值对照时，要说清凭什么判的');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ ★★★ 任务 A：伪造段表**可维护**（数据驱动 + 每条带依据）
  // ═══════════════════════════════════════════════════════════════════
  group('⑦ 伪造段表：可维护 + 每条有依据 + 反证', () {
    test('★★★ 每一条都必须带**非空依据**（空依据 = 假绿）', () {
      expect(DanmakuProbeReport.kForgedAddressRanges, isNotEmpty);
      for (final r in DanmakuProbeReport.kForgedAddressRanges) {
        /*
         * # 为什么这条重要
         * ```text
         * 一张"看起来是个表"但没有依据的清单，下一个人无法判断：
         *   · 这条还能不能删
         *   · 它是实测来的，还是谁随手加的
         * ⇒ 强制非空，且必须提到**可复跑的取证方式**（PTR / DoH / 花样段）。
         * ```
         */
        expect(r.evidence.trim(), isNotEmpty,
            reason: '★★★ 伪造段 "${r.prefix}" 没有依据 —— 不许凭"看着不像"就列进来');
        expect(r.prefix.trim(), isNotEmpty);
        final e = r.evidence;
        final hasEvidence = e.contains('PTR') ||
            e.contains('DoH') ||
            e.contains('花样') ||
            e.contains('Facebook') ||
            e.contains('Twitter') ||
            e.contains('Dropbox') ||
            e.contains('SoftLayer');
        expect(hasEvidence, isTrue,
            reason: '★★ 依据必须是**可复跑的取证**（PTR / DoH / 花样段），'
                '而 "${r.prefix}" 的依据里看不出来：$e');
      }
    });

    test('★★★ 表里不许有重复前缀（重复 = 维护时容易改一处漏一处）', () {
      final seen = <String>{};
      for (final r in DanmakuProbeReport.kForgedAddressRanges) {
        expect(seen.add(r.prefix), isTrue,
            reason: '★★★ 前缀 "${r.prefix}" 重复了');
      }
    });

    test('★★★ 反证：7 个 DoH 真值地址**一个都不许**被判成伪造', () {
      /*
       * 这条防的是"判据写成恒真"（例如 `return true`），
       * 也防"前缀取得太宽的段"误伤真实地址。
       */
      for (final real in <String>[
        '216.198.79.3', // delta 真值
        '64.29.17.3', // delta 真值
        '216.198.79.67', // kappa 真值（第一次采样）
        '64.29.17.67',
        '216.198.79.195', // kappa 真值（第二次采样，地址也变了）
        '64.29.17.195',
        '64.239.123.129', // vercel.com（能通的对照）
      ]) {
        expect(DanmakuProbeReport.isKnownForgedAddress(real), isFalse,
            reason: '★★★ 真值 $real 被判成伪造 ⇒ 判据太宽，会误伤正常用户');
      }
    });

    test('★★★ 轮换走掉的旧伪造地址仍在表里（回归保护）', () {
      /*
       * 本轮实测：同一个域名两次采样拿到**不同**的伪造地址。
       * 这些"历史样本"必须留在表里 —— 否则换回旧地址时就抓不到了。
       */
      for (final forged in <String>[
        '74.86.17.48', // 第一次采样
        '199.59.150.39', // 第二次采样
        '104.244.43.182', // kappa 第二次采样
        '199.96.58.15', // vercel.app apex 采样
        '2a03:2880:f117:83:face:b00c:0:25de', // 每次都有的 IPv6 花样
      ]) {
        expect(DanmakuProbeReport.isKnownForgedAddress(forged), isTrue,
            reason: '★★ 实测收到的伪造地址 $forged 必须能命中');
      }
    });

    test('★★ 阳性对照：表里每条前缀喂给自己都要命中（防写错前缀）', () {
      for (final r in DanmakuProbeReport.kForgedAddressRanges) {
        // 前缀补一个尾数，模拟真实地址
        final sample = '${r.prefix}1';
        expect(DanmakuProbeReport.isKnownForgedAddress(sample), isTrue,
            reason: '★★ 前缀 "${r.prefix}" 自己构造的样本 $sample 都没命中 —— '
                '这条前缀写错了');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑧ ★★★ 任务 B：detail 要让用户**自己看懂**（两个地址都摆出来）
  // ═══════════════════════════════════════════════════════════════════
  group('⑧ 用户自查：detail 里本机地址与真值都要出现', () {
    test('★★★ 有 DoH 时：本机地址 + DoH 地址 + "不是一个东西"的结论', () {
      final r = DanmakuProbeReport.forHijackedDns(
        url: 'https://danmu-api-delta.vercel.app',
        localAddresses: <String>['74.86.17.48'],
        dohAddresses: <String>['216.198.79.3', '64.29.17.3'],
      );
      /*
       * 用户不需要懂 DNS：看到两个不同的地址就明白了。
       * ⇒ 断言**两者同时出现**，且有一句把这层意思说破。
       */
      expect(r.detail, contains('74.86.17.48'),
          reason: '★★★ 本机地址必须显示（这是他机器上的事实）');
      expect(r.detail, contains('216.198.79.3'),
          reason: '★★★ 权威真值也必须显示（对比才成立）');
      expect(r.detail, contains('不是一个东西'),
          reason: '★★ 要有把两个地址"对上"的一句话，不能只是并列两串数字');
      expect(r.detail, contains('本机解析到'));
      expect(r.detail, contains('权威 DNS'));
    });

    test('★★★ 没有 DoH 时：**不编真值**，明说无法核对', () {
      final r = DanmakuProbeReport.forHijackedDns(
        url: 'https://x',
        localAddresses: <String>['108.160.173.207'],
      );
      expect(r.detail, contains('108.160.173.207'));
      expect(r.detail.contains('无法核对') || r.detail.contains('没能核对'), isTrue,
          reason: '★★★ 拿不到真值就必须明说，不许沉默（沉默会让人以为已核对过）');
      /*
       * ★ 关键反证：**不许**出现任何看起来像"真值"的地址。
       *   这里用一个不可能出现的占位（真值都是 216.198.x / 64.29.x）。
       */
      expect(r.detail.contains('216.198.'), isFalse,
          reason: '★★★ 没有做 DoH 就不许凭空出现真值地址 —— 那是编的');
      expect(r.detail.contains('64.29.'), isFalse);
    });

    test('★★ 两种情形的 detail 都能独立读懂（不依赖 UI 其它部分）', () {
      final withDoh = DanmakuProbeReport.forHijackedDns(
        url: 'https://x',
        localAddresses: <String>['74.86.17.48'],
        dohAddresses: <String>['216.198.79.3'],
      );
      final noDoh = DanmakuProbeReport.forHijackedDns(
        url: 'https://x',
        localAddresses: <String>['74.86.17.48'],
      );
      // 两者的 detail 必须**不同**（否则"没有真值"这个事实被吞掉了）
      expect(withDoh.detail, isNot(noDoh.detail),
          reason: '★★ 有没有真值对照，说的话必须不一样');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 内置实例现状：**如实记录**，不许假装它们可用
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ 内置实例的地址现状（如实钉住，改动时请同步核实）', () {
    test('★★★ 内置实例目前都是 vercel 域 —— 这是本轮根因所在', () {
      expect(kDanmakuPublicInstances, isNotEmpty);
      final hosts = kDanmakuPublicInstances
          .map((p) => Uri.parse(p.baseUrl).host)
          .toList();
      /*
       * ⚠️ 这条断言**不是在说"vercel 好"** —— 恰恰相反：
       *    本机实测这两个域名**连接超时**（见文件头）。
       *    它钉的是"根因在这里"，这样将来谁换成非 vercel 域，
       *    这条会红 ⇒ 提醒他同步更新本文件的实测读数与交付说明。
       */
      expect(
        hosts.every((h) => h.endsWith('.vercel.app')),
        isTrue,
        reason: '★★★ 若这里红了：内置实例域名变了 —— '
            '请重跑本轮的分层探测并更新本文件的读数（不要只改断言）',
      );
      expect(hosts.length, greaterThanOrEqualTo(2),
          reason: '★ Owner 说「内置两个 dan-api」—— 至少两条备选');
    });
  });
}
