@Tags(['native-media'])
import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide ListTile;
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/stream_prepare.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' show ListTile;
import 'support/strip_comments.dart';

// ═══════════════════════════════════════════════════════════════════════
//  T1b 接线①（2026-11-01）：网盘分享链接预检**接到线路面板上**
//  + ② 候选「空 / 被摘」的静默失败留痕
// ═══════════════════════════════════════════════════════════════════════
//
// # 它守的是什么（本批的收口目标）
// ```text
// Rust 侧 `tvbox_pan_check`（commit b84dd9d）已经能零凭据探活，而 Dart 侧
// **零消费点** ⇒ 引擎建好了、用户一行都看不到（本批 T5 = "功能加了，用户
// 一行都看不到"）。这次不许重蹈 ⇒ 三条链必须同时成立：
//   ① Rust 引擎 → ② Dart 封装 → ③ 线路面板的行标注
// 少任何一截，"已实现"都是空的。
// ```
//
// # 判据分层（每一层各有分工，不能只有一层）
// ```text
// 组① 纯函数   isPanShareUrl 的正/反向（反向是主断言 —— contains 写法必红）
// 组② 解析     PanCheckResult.fromJson 五档 + 坏数据不炸
// 组③ 真树     ★ 注入假核心 → 驱动**生产** _armPanPrecheck → 读真 ListTile
//                bad 不可点 + 有 summary；locked 仍可点 + 有徽章；其余不标注
// 组④ 接线     ★ 先 stripComments 剥注释再比；且**逐处钉**四个 _streams 赋值点
// 组⑤ 代次     ★ lead 批复 A：换集/换台/换源必须作废在途结果（错标比不标更糟）
// 组⑥ 留痕     ★ ② 的静默失败收口：可行动线索 + 防刷屏（lead 批复 B）
// ```
//
// # ★★ 换源弹层**为什么不在本文件里**（lead 批复 1）
// ```text
// `source_switch_dialog.dart` 渲染的是 searchAllStream 的**搜索命中条目**
// （MediaItem 只有 id/title/note，**没有播放 URL**），而预检的输入是 URL
// ⇒ 那里没有可接的东西。硬凑一个接线点上去 = 又一处"接线了但没真接"
// （本批已踩过两次）。这条理由写在这里，免得下一个人再补一个假接线。
// ```
//
// # 故障注入（实测记录，逐条做过）
// ```text
// 注入① isPanShareUrl 改成 contains            ⇒ 组①反向红
// 注入② _StreamSheet 里 bad 分支删掉           ⇒ 组③ bad 红
// 注入③ locked 也置灰（rowEnabled=false）      ⇒ 组③ locked 仍可点红
// 注入④ panStateOf 恒返回 null                ⇒ 组③ 全部红
// 注入⑤ 删掉某处 _armPanPrecheck( 调用         ⇒ 组④-1 红
// 注入⑥ panStateOf: _panStateFor 不传          ⇒ 组④-2 红
// 注入⑦ panCheck 里把 callAsync 注释掉         ⇒ 组④-3 红 + 组③ 全红
// 注入⑧ 删留痕调用                            ⇒ 组④-4 / 组⑥ 红
// 注入⑨ 代次不抬（+=0）                       ⇒ 组⑤ 红
// 注入⑩ 留痕不记账（去掉 add 判据）            ⇒ 组⑥ 防刷屏红
// ```

// ── libmpv 夹具（同 t20261030_sample_line_test —— 缺夹具 skip，不假红）──
List<String> _libmpvCandidates() => Platform.isWindows
    ? <String>[
        r'build\windows\x64\libmpv\libmpv-2.dll',
        r'build\windows\x64\runner\Release\libmpv-2.dll',
      ]
    : <String>['/usr/lib/x86_64-linux-gnu/libmpv.so.2'];

String? _libmpv;

void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      return;
    }
  }
}

bool _requireLibmpv() => _libmpv != null;

/// 四条线路（bad / locked / ok / unsupported），URL 形态各取自真实网盘域名族
const _bad = StreamCandidate(
  url: 'https://pan.quark.cn/s/dead0001',
  label: '夸克线路A',
);
const _locked = StreamCandidate(
  url: 'https://pan.quark.cn/s/lock0002',
  label: '夸克线路B',
);
const _ok = StreamCandidate(
  url: 'https://pan.baidu.com/s/ok000003',
  label: '百度线路C',
);
const _unsupported = StreamCandidate(
  url: 'https://cloud.189.cn/t/un000004',
  label: '天翼线路D',
);
const _normal = StreamCandidate(
  url: 'https://cdn.example.com/vod/1.m3u8',
  label: '普通线路E',
);

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv-1',
        title: '网盘预检测试',
        episodes: const [
          Episode(id: 'ep1', title: '第1集', url: 'https://x.invalid/1.m3u8'),
        ],
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: '第1集',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  debugPlayerClearErrorForProbe();
  await t.pump();
}

/// 装一个假 `tvbox_pan_check`（顶替的是**核心层传输**，不是 UI 判据）
void _installFakePanCheck(
  Future<List<PanCheckResult>> Function(List<({String url, String? pwd})>) f,
) {
  SourinApi.debugPanCheckFetcher = f;
}

void main() {
  setUpAll(_prepareLibmpvFixture);
  tearDown(() {
    SourinApi.debugPanCheckFetcher = null;
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组① 纯函数：网盘族判据（反向是主断言）
  // ═══════════════════════════════════════════════════════════════════
  group('① isPanShareUrl：正向认得出、反向不冤枉', () {
    test('★★ 五家 + 预检未接入的盘都能认出来（按域名族）', () {
      for (final u in <String>[
        'https://pan.quark.cn/s/abc',
        'https://drive.uc.cn/s/abc',
        'https://pan.baidu.com/s/1abc',
        'https://www.alipan.com/s/abc',
        'https://pan.xunlei.com/s/abc',
        // ★ 预检未接入的盘也**必须**认出来：Rust 会回 unsupported，
        //   而"不标注"这个决定在 Dart 侧不猜（把 115 当普通线路 = 漏筛）
        'https://115.com/s/abc',
        'https://www.123pan.com/s/abc',
        'https://cloud.189.cn/t/abc',
        'https://app.guangyapan.com/pan/abc',
      ]) {
        expect(isPanShareUrl(u), isTrue, reason: '必须认出 $u');
      }
    });

    test('★★★ 反向：长得像但不是网盘的**不许**命中（contains 写法必红）', () {
      for (final u in <String>[
        'https://evil-quark.example.com/s/abc', // 别人的域名
        'https://notpan.quark.cn.evil.com/s/abc', // 后缀不在域标签边界上
        'https://myquark.cn/s/abc', // 含 quark 但不是夸克
        'https://cdn.example.com/vod/1.m3u8', // 普通媒体直链
        'https://example.com/pan/quark/s/abc', // path 里有 quark，host 不是
        '', // 空
        'not-a-url', // 不是 URL
        'file:///C:/a.mp4', // 非 http(s)
        'https:///s/abc', // 没有 host
      ]) {
        expect(isPanShareUrl(u), isFalse, reason: '不许命中 $u');
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组② 解析：五档 state 逐字 + 坏数据不炸
  // ═══════════════════════════════════════════════════════════════════
  group('② PanCheckResult.fromJson：Rust 吐的键逐字对应，坏数据不炸', () {
    test('★★ 五档 state 逐字对上 Rust 的 CheckState::code()', () {
      expect(panCheckStateOf('ok'), PanCheckState.ok);
      expect(panCheckStateOf('locked'), PanCheckState.locked);
      expect(panCheckStateOf('bad'), PanCheckState.bad);
      expect(panCheckStateOf('uncertain'), PanCheckState.uncertain);
      expect(panCheckStateOf('unsupported'), PanCheckState.unsupported);
    });

    test('★★ 未知 / 缺失 state ⇒ uncertain（不猜、不抛）', () {
      expect(panCheckStateOf(''), PanCheckState.uncertain);
      expect(panCheckStateOf('weird_new_state'), PanCheckState.uncertain,
          reason: 'Rust 若加新档，Dart 最稳的处置是"不下结论"');
    });

    test('★★ 正常一条：url/kind/shareId/state/summary/cacheable 全读出', () {
      final r = PanCheckResult.fromJson(<String, dynamic>{
        'url': 'https://pan.quark.cn/s/abc',
        'kind': 'quark',
        'shareId': 'abc',
        'state': 'bad',
        'summary': '链接失效',
        'cacheable': true,
      });
      expect(r.url, 'https://pan.quark.cn/s/abc');
      expect(r.kind, 'quark');
      expect(r.shareId, 'abc');
      expect(r.state, PanCheckState.bad);
      expect(r.summary, '链接失效');
      expect(r.cacheable, isTrue);
    });

    test('阴性：空 map / 类型不对 ⇒ 落到"不下结论"，不抛', () {
      final empty = PanCheckResult.fromJson(const <String, dynamic>{});
      expect(empty.state, PanCheckState.uncertain);
      expect(empty.summary, '');
      final badTypes = PanCheckResult.fromJson(<String, dynamic>{
        'url': 42,
        'state': 7,
        'summary': null,
      });
      expect(badTypes.url, '');
      expect(badTypes.state, PanCheckState.uncertain);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组③ 真树：注入假核心 → 生产筛选 → 真 ListTile 的表现
  // ═══════════════════════════════════════════════════════════════════
  group('③ 真树：bad 置灰不可点 / locked 标注但仍可点 / 其余不标注', () {
    testWidgets('★★★ 三态落在真 ListTile 上', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);

      // ★ 注入**假核心**：顶替的是 `tvbox_pan_check` 这一段传输
      _installFakePanCheck(
        (items) async => <PanCheckResult>[
          for (final it in items)
            PanCheckResult(
              url: it.url,
              state: it.url.contains('dead')
                  ? PanCheckState.bad
                  : it.url.contains('lock')
                      ? PanCheckState.locked
                      : it.url.contains('un000004')
                          ? PanCheckState.unsupported
                          : PanCheckState.ok,
              summary: it.url.contains('dead') ? '链接失效' : '',
            ),
        ],
      );

      final all = <StreamCandidate>[_bad, _locked, _ok, _unsupported];
      expect(debugPlayerSetStreamsForProbe(all), isTrue);
      await t.pump();
      // ★ 驱动**生产**的 _armPanPrecheck（不是测试里另写一份筛选）
      expect(await debugPlayerRunPanPrecheckForProbe(), isTrue);
      await t.pump();

      // ── 数据层：只留 bad / locked 两档 ──
      final states = debugPlayerPanStatesForProbe();
      expect(states[_bad.url], 'bad');
      expect(states[_locked.url], 'locked');
      expect(states.containsKey(_ok.url), isFalse,
          reason: 'ok 不标注（链接有效，没什么要告诉用户的）');
      expect(states.containsKey(_unsupported.url), isFalse,
          reason: 'unsupported 不标注（不确定就不下结论）');

      // ── 渲染层：打开抽屉读**真** ListTile ──
      expect(debugPlayerOpenStreamSheetForProbe(), isTrue);
      await t.pump();

      final tiles = t.widgetList<ListTile>(find.byType(ListTile)).toList();
      expect(tiles.length, 4, reason: '四条线路四行');

      ListTile tileOf(String label) => tiles.firstWhere(
            (w) => (w.title as Row).children.any(
              (c) => c is Flexible &&
                  ((c.child as Text).data ?? '').contains(label),
            ),
          );

      miuix.MiuixBasicComponent componentOf(ListTile tile) =>
          t.widget<miuix.MiuixBasicComponent>(find.descendant(
            of: find.byWidget(tile),
            matching: find.byType(miuix.MiuixBasicComponent),
          ));

      // ① bad：不可点 + 无 onTap + 副标题是预检给的那句归因
      final badTile = tileOf('夸克线路A');
      expect(badTile.enabled, isFalse, reason: '死链必须不可点（点了必然失败）');
      expect(badTile.onTap, isNull);
      expect(componentOf(badTile).enabled, isFalse);
      expect(componentOf(badTile).onClick, isNull);
      expect(find.text('链接失效'), findsOneWidget,
          reason: 'bad 行必须把 summary 显示出来 —— 用户不必点进去才知道死链');

      // ② locked：★★★ **仍可点**（lead 批复 3：locked 不等于死）
      final lockedTile = tileOf('夸克线路B');
      expect(lockedTile.enabled, isTrue,
          reason: '★ locked 不等于死：用户有码就能播，锁死是错标');
      expect(lockedTile.onTap, isNotNull, reason: 'locked 行必须还能点');
      expect(componentOf(lockedTile).enabled, isTrue);
      expect(componentOf(lockedTile).onClick, same(lockedTile.onTap));
      expect(find.text('需提取码'), findsOneWidget,
          reason: 'locked 行必须标出来（用户知道要先找码）');

      // ③ ok：不标注，且按线路本身可点
      final okTile = tileOf('百度线路C');
      expect(okTile.enabled, isTrue);
      expect(okTile.subtitle, isNull, reason: 'ok 不该有任何预检痕迹');

      // ④ unsupported：不标注（还没接入 ≠ 坏了）
      final unTile = tileOf('天翼线路D');
      expect(unTile.enabled, isTrue, reason: '没接入预检不许当成坏了');
      expect(unTile.subtitle, isNull);

      // 整树里「需提取码」恰好一枚（不许重复标）
      expect(find.text('需提取码'), findsOneWidget);
    });

    testWidgets('★★ 非网盘线路 ⇒ 一次请求都不发（零开销）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      var calls = 0;
      _installFakePanCheck((items) async {
        calls++;
        return const <PanCheckResult>[];
      });
      expect(debugPlayerSetStreamsForProbe([_normal]), isTrue);
      await t.pump();
      expect(await debugPlayerRunPanPrecheckForProbe(), isTrue);
      await t.pump();
      expect(calls, 0,
          reason: '★ 普通 m3u8 线路不该触发任何预检请求（1.3：不增加起播延迟）');
      expect(debugPlayerPanStatesForProbe(), isEmpty);
    });

    testWidgets('★★ 同一条链接被多条线路引用 ⇒ 只问一次（去重）', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);
      final asked = <String>[];
      _installFakePanCheck((items) async {
        for (final it in items) {
          asked.add(it.url);
        }
        return const <PanCheckResult>[];
      });
      expect(
        debugPlayerSetStreamsForProbe([
          _bad,
          // 同 URL 再来一条（label 不同 ⇒ 是两条线路行）
          StreamCandidate(url: _bad.url, label: '夸克线路A2'),
        ]),
        isTrue,
      );
      await t.pump();
      expect(await debugPlayerRunPanPrecheckForProbe(), isTrue);
      await t.pump();
      expect(asked.length, 1, reason: '同一 URL 只该问一次');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组⑤ 代次防护（lead 批复 A）：错标比不标更糟
  // ═══════════════════════════════════════════════════════════════════
  group('⑤ 代次：换集后旧结果必须作废', () {
    testWidgets('★★ 预检在途时换列表 ⇒ 旧结果不落地', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);

      /*
       * ★ 假核心卡住：用 **Completer** 而不是 `while (!release) await delayed()`。
       *
       * 原因（第一次跑挂了 10 分钟才发现的坑）：flutter_test 的 `t.pump()`
       * 用的是**假时钟**，而 `Future.delayed` 排的是真计时器 ⇒
       * 自旋等法永远等不到 ⇒ 整个文件挂住（不是红，是卡死）。
       * ⇒ 必须由**测试自己**在确定的时刻 complete（时序可控、且零等待）。
       */
      final gate = Completer<List<PanCheckResult>>();
      _installFakePanCheck((items) => gate.future);

      // 第 1 集：两条网盘线路
      expect(debugPlayerSetStreamsForProbe([_bad, _locked]), isTrue);
      await t.pump();
      unawaited(debugPlayerRunPanPrecheckForProbe());
      await t.pump();
      final genBefore = debugPlayerPanCheckGenForProbe();
      expect(genBefore, greaterThan(0), reason: '发起预检必须抬代次');

      // 用户在预检回来的**之前**换到了第 2 集（新列表只有普通线路）
      expect(debugPlayerSetStreamsForProbe([_normal]), isTrue);
      await t.pump();
      await debugPlayerRunPanPrecheckForProbe();
      await t.pump();
      expect(debugPlayerPanCheckGenForProbe(), greaterThan(genBefore),
          reason: '★ 换集必须抬代次 —— 否则旧结果会把 A 集的死链标到 B 集上');

      // 放开发起于第 1 集的那个预检（它此刻已经是"过期"的）
      gate.complete(<PanCheckResult>[
        PanCheckResult(
          url: _bad.url,
          state: PanCheckState.bad,
          summary: '链接失效',
        ),
      ]);
      for (var i = 0; i < 5; i++) {
        await t.pump();
      }

      expect(debugPlayerPanStatesForProbe(), isEmpty,
          reason: '★ 过期结果必须被丢弃（错标比不标更糟）');
    });

    test('接线断言：代次早退必须写在 uniq 为空**之前**（否则漏防）', () {
      final src =
          stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      // 方法体内：先出现 ++_panCheckGen，后出现 uniq.isEmpty
      final m = RegExp(r'void _armPanPrecheck\(List<StreamCandidate> list\) \{')
          .firstMatch(src);
      expect(m, isNotNull, reason: '找不到 _armPanPrecheck');
      final body = src.substring(m!.end, (m.end + 2600).clamp(0, src.length));
      final iGen = body.indexOf('++_panCheckGen');
      final iEmpty = body.indexOf('uniq.isEmpty');
      expect(iGen, greaterThan(-1), reason: '必须抬代次');
      expect(iEmpty, greaterThan(-1));
      expect(iGen, lessThan(iEmpty),
          reason: '★ 代次必须在早退**之前**抬 —— 否则新列表里没有网盘链接时'
              '（绝大多数源）根本不抬代次，旧集结果照旧落地（A 的洞）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  组⑥ ② 静默失败留痕：可行动线索（纯函数）+ 防刷屏（行为层）
  // ═══════════════════════════════════════════════════════════════════
  //
  // ⚠️ 纯函数那三条（留痕串的可行动线索 / 不编造 / 截断）在
  //
  group('⑥ 留痕串的可行动线索与防刷屏（行为层）', () {
    test('★★ 留痕串必须含可行动线索：provider + id 前缀 + 条数 + 原因', () {
      final line = emptyCandidateLogLine(
        provider: 'csp-appget-97d9adc9',
        contentId: '357566@轮播|0|https://x/y.m3u8',
        empty: true,
        droppedCount: 2,
        droppedReasons: const <String>['线路1: 看起来是播放页而不是媒体地址：/play/abc'],
      );
      expect(line.contains('provider=csp-appget-97d9adc9'), isTrue,
          reason: '★ 不知道是哪个源 ⇒ 排不了障');
      expect(line.contains('id~=357566@轮播|0|https://x/y'), isTrue,
          reason: '★ id 截 24 字符（与 Rust resolve 落盘同一脱敏口径）');
      expect(line.contains('空列表=true'), isTrue);
      expect(line.contains('摘除=2'), isTrue);
      expect(line.contains('原因='), isTrue,
          reason: '★ lead 批复：没原因 = 记了但排不了障');
    });

    test('★ 没原因时不编造（如实说"未给出"）', () {
      final line = emptyCandidateLogLine(
        provider: 'p',
        contentId: 'i',
        empty: false,
        droppedCount: 3,
        droppedReasons: const <String>[],
      );
      expect(line.contains('（未给出）'), isTrue,
          reason: '宁可说"没给出"，不许造一个理由');
    });

    test('★ 原因过多时截断但报数（不刷屏、也不丢信息）', () {
      final line = emptyCandidateLogLine(
        provider: 'p',
        contentId: 'i',
        empty: false,
        droppedCount: 9,
        droppedReasons: List<String>.generate(9, (i) => '原因$i'),
      );
      expect(line.contains('还有 6 条'), isTrue);
      expect(line.contains('原因0'), isTrue);
      expect(line.contains('原因8'), isFalse, reason: '只带前 3 条');
    });

    testWidgets('★★ 行为层：同一集只记一次，换集后能再记一次', (t) async {
      if (!_requireLibmpv()) return;
      await _mount(t);

      addTearDown(StreamPreparer.debugReset);
      StreamPreparer.lastDroppedCount = 2;
      StreamPreparer.lastDroppedReasons = <String>['原因A'];
      // ★ 清账：防刷屏的账是 State 级状态，用例之间必须隔离
      //   （不清 ⇒ 前一个用例记过的 key 会挡住本用例 ⇒ 假红）
      expect(debugPlayerResetShortfallLogForProbe(), isTrue);

      // ★ 直接驱动**生产**的 `_logCandidateShortfall`（不在测试里另写一份记账）
      // ★ 相对增量判据（不用绝对值 —— 播放页自身还会写别的日志行）
      int logged(void Function() f) {
        final before = AppLog.lineCount;
        f();
        return AppLog.lineCount - before;
      }

      // ① 第一次：必须真的记了（没记 = 静默失败没被收掉）
      expect(logged(() => debugPlayerLogCandidateShortfallForProbe(const [])), 1,
          reason: '★ 第一次必须真的记了（没记 = 静默失败没被收掉）');

      // ② 同一 provider/id 再调 ⇒ 被账挡住 ⇒ 一行都不记
      expect(
        logged(() => debugPlayerLogCandidateShortfallForProbe(const [])),
        0,
        reason: '★ 同一集反复调用不许刷屏（lead 批复 B）',
      );

      // ③ 换集（contentId 变了）⇒ 允许再记一次
      //    ★ 这是"留痕账必须能被换集解开"的行为证明 —— 只做静态断言不够
      //      （行在 ≠ 生效：本门禁第一次就是这么红的）
      expect(
        logged(
          () => debugPlayerLogCandidateShortfallForProbe(
            const [],
            contentId: 'cctv-2',
          ),
        ),
        1,
        reason: '★ 换集后的失败必须还能记（被旧账挡住 = 留痕永久丢失）',
      );

      // ④ 换回第 1 集 ⇒ 上一集的账作废，但**本集**的账必须留着
      //    （清账时把当前 key 一起清掉 ⇒ 来回切两集就能刷满日志 —— 防刷屏被绕过）
      expect(
        logged(() => debugPlayerLogCandidateShortfallForProbe(const [])),
        0,
        reason: '★ 换走又换回时，本集不许重复记（否则来回切集即可刷屏）',
      );
    });
  });
}
