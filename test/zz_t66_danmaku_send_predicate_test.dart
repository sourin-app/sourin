// ═══════════════════════════════════════════════════════════════════════
//  门禁：底栏「发送弹幕」入口 = 四条件 AND 谓词（真树真值表）
// ═══════════════════════════════════════════════════════════════════════
//
// # 守的是哪一行（`lib/ui/player_page.dart`，第 66 轮 Owner 第 1 条）
// ```dart
// danmakuSend: (_danmakuEnabled &&          // ① 弹幕总开关为开
//         _danmakuCanSend &&                // ② 当前源声明 danmaku_send
//         _danmakuSendProvider != null &&   // ③ 有真站点 id 可发
//         !_isLive)                         // ④ 直播没有「这一集」
//     ? DanmakuSendData(provider: …, episodeId: …, positionMs: …, onSend: …)
//     : null,
// ```
// 任一条件为假 ⇒ 底栏那枚发送入口**整条不渲染**。
//
// # 为什么必须有「阳性对照」（全 T 那一格）
// ```text
// 只测「不该出现时没出现」的门禁，在**入口永远不出现**的实现下也全绿 ——
// 那不是门禁，是一句话。所以表里第 1 行必须是「四条件全满足 ⇒ 入口真的在」，
// 且它断言的是**底栏实例上真实的 `danmakuSend` 值**，不是"某个控件没找到"。
// ```
//
// # 为什么是「真树」而不是白送祖先的围栏
// ```text
// 谓词写在 `PlayerPage.build` 里，只有**真的挂起 PlayerPage**才能执行到它。
// `MaterialApp(home: Scaffold(body: PlayerBottomBar(...)))` 这种围栏只测到底栏
// 自己的渲染，谓词一个字节都没跑 —— 删掉 `&& _danmakuCanSend` 它照样全绿。
// ⇒ 本文件 pump 的是 `PlayerPage`，读的是它**建出来的** `PlayerBottomBar` 实例。
// ```
//
// # 三个「看起来该红其实是假红」的坑（都是实测踩出来的，别再走一遍）
// ```text
// ① 不 start 核心 ⇒ `SourinApi.listProviders()` 抛 ⇒ `_danmakuCanSend` 恒 false
//    ⇒ 阳性对照必假红。所以 setUpAll 用**沙盒数据目录**起真核心，
//      并往 `<sandbox>/plugins/` 放两枚夹具插件（一枚声明可发、一枚不可发）。
// ② 只 `tester.pump()` ⇒ 上面那趟 FFI 的原生回调在 fake_async 里**不会被派发**
//    ⇒ 查询永远挂着 ⇒ 同样恒 false。必须先 `tester.runAsync(...)` 让真实事件
//    循环跑一次，回调落地、`setState` 生效，再 pump。
// ③ 让 `_load()` 真去解析流 ⇒ 沙盒里没有真流 ⇒ `_error != null` ⇒ 底栏整个消失
//    ⇒ 读不到任何东西（实测 `bars=0`）。所以统一走 `localPath`：那是一条
//    **完全不调 `_load()`** 的生产短路（`player_page.dart:3238` 附近），页面停在
//    「本地文件播放中」，底栏照常在树里。
// ```
//
// # 一个「不可达格」——不要为了凑满 16 格去假造
// ```text
// (canSend=T, provider=F) 这一格**结构上不可达**：
// `_loadDanmakuSendCapability()` 里 id 为空时直接
// `_danmakuCanSend = false; _danmakuSendProvider = null;` 一起置（:3383-3392），
// 之后 canSend 只在该函数里由 `danmakuSendAllowed(list, id)` 赋值（:3413）。
// ⇒ ② 真而 ③ 假的状态**没有任何代码路径能产生**。
// 反过来 (canSend=F, provider=T) 是可达的（源存在但不声明 danmaku_send），见第 3 行。
// ```
//
// # 跑法（默认套件**跳过**：需要真核心 dll + libmpv）
// ```bash
// flutter test test/zz_t66_danmaku_send_predicate_test.dart \
//   --run-skipped --tags native-media --concurrency=1
// ```
// 缺 `sourin_core.dll` / `libmpv-2.dll` 时整文件 skip（**不是**通过）。

@Tags(['native-media'])
library;
// ignore_for_file: avoid_print

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 声明了 `danmakuSend: true` 的源（夹具）
const String kSendCapable = 'demo';

/// 存在、但**不**声明 `danmakuSend` 的源（夹具）
const String kReadOnly = 'demo2';

int _seq = 0;
void log(String s) => print(s);

/// 把仓库自带的 `rust/sourin_core/plugins/demo.js` 复制进沙盒并改写 id / 能力位
///
/// 用仓库自带插件当夹具（而不是手写一份 mini 插件）：解析器、能力位归一化、
/// 元信息头部都走同一条生产路径，夹具不会因为"写了个假的"而测到另一套契约。
String _fixture(String id, {required bool danmakuSend}) {
  final src = File('rust/sourin_core/plugins/demo.js').readAsStringSync();
  var s = src.replaceAll('@id          demo', '@id          $id');
  s = s.replaceAll("  id: 'demo',", "  id: '$id',");
  s = s.replaceAll('''  capabilities: {
    vod: true, // 点播
    search: true, // 搜索''', '''  capabilities: {
    vod: true, // 点播
    search: true, // 搜索
    danmaku: true,
    danmakuSend: $danmakuSend,''');
  // 防呆：改写没命中就**禁止继续**，否则测的其实是原样 demo（能力位 false）
  if (!s.contains("id: '$id'") || !s.contains('danmakuSend: $danmakuSend')) {
    throw StateError('夹具改写没命中（$id / $danmakuSend），禁止继续');
  }
  return s;
}

/// 造一个**真能播**的最小 WAV（0.2s / 8kHz / 8bit 单声道静音）
///
/// 只为让 `localPath` 那条短路有东西可开：mpv 打不开会走错误态、底栏消失，
/// 那样读到的 null 就分不清是「谓词为假」还是「页面没底栏」。
Uint8List _tinyWav() {
  const rate = 8000;
  const secs = 0.2;
  final samples = (rate * secs).round();
  final b = BytesBuilder();
  void str(String s) => b.add(s.codeUnits);
  void u32(int v) => b
      .add([v & 0xFF, (v >> 8) & 0xFF, (v >> 16) & 0xFF, (v >> 24) & 0xFF]);
  void u16(int v) => b.add([v & 0xFF, (v >> 8) & 0xFF]);
  str('RIFF');
  u32(36 + samples);
  str('WAVEfmt ');
  u32(16);
  u16(1); // PCM
  u16(1); // mono
  u32(rate);
  u32(rate); // byte rate (8bit mono)
  u16(1); // block align
  u16(8); // bits
  str('data');
  u32(samples);
  b.add(Uint8List(samples)..fillRange(0, samples, 0x80)); // 静音
  return b.toBytes();
}

void main() {
  late Directory sandbox;
  late String wavPath;
  var dllReady = false;

  setUpAll(() async {
    final core = File('sourin_core.dll');
    final mpv = File('libmpv-2.dll');
    dllReady = core.existsSync() && mpv.existsSync();
    log('DIAG core.dll=${core.existsSync()} libmpv=${mpv.existsSync()}');
    if (!dllReady) return;
    MediaKit.ensureInitialized(libmpv: mpv.absolute.path);

    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'zz_t66_pred_${DateTime.now().microsecondsSinceEpoch}');
    Directory('${sandbox.path}/plugins').createSync(recursive: true);
    File('${sandbox.path}/plugins/$kSendCapable.js')
        .writeAsStringSync(_fixture(kSendCapable, danmakuSend: true));
    File('${sandbox.path}/plugins/$kReadOnly.js')
        .writeAsStringSync(_fixture(kReadOnly, danmakuSend: false));
    wavPath = '${sandbox.path}/tiny.wav';
    File(wavPath).writeAsBytesSync(_tinyWav());
    log('DIAG sandbox=${sandbox.path} wav=${File(wavPath).lengthSync()}B');

    if (!SourinCore.isStarted) {
      final r = await SourinApi.start(sandbox.path);
      log('DIAG start=$r');
    }
    final ps = await SourinApi.listProviders();
    for (final p in ps) {
      log('DIAG provider id=${p.id} danmaku=${p.capabilities.danmaku} '
          'danmakuSend=${p.capabilities.danmakuSend}');
    }
    // 夹具自检：两枚必须都在，且能力位一真一假（否则整张表测的是同一件事）
    expect(
        ps.any((p) => p.id == kSendCapable && p.capabilities.danmakuSend), isTrue,
        reason: '夹具自检：$kSendCapable 必须是「声明可发送」');
    expect(
        ps.any((p) => p.id == kReadOnly && !p.capabilities.danmakuSend), isTrue,
        reason: '夹具自检：$kReadOnly 必须是「未声明可发送」');
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (e) {
      log('清理沙盒失败（核心仍持有文件，不影响结论）: $e');
    }
  });

  /*
   * ★ PlayerPage 一挂起就会拉起 `RemoteBridge` 的轮询定时器；
   *   不 stop 的话测试结束时报「A Timer is still pending even after the widget
   *   tree was disposed」——**红的原因与本门禁无关**，是夹具漏了收尾。
   *   t103/t108 用的是同一写法。
   */
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  final bool skipIt = !dllReady;

  /// 真树挂载 → 让 FFI 落地 → 按需打开总开关 → 读底栏实例上的谓词输出
  Future<int> mount(
    WidgetTester t, {
    required String provider,
    required bool enabled,
    String? liveChannelId,
  }) async {
    _seq++;
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: PlayerPage(
        key: ValueKey('pred$_seq'),
        provider: provider,
        id: 'cid$_seq',
        title: '谓词门禁',
        localPath: wavPath, // ★ 生产短路：完全不调 _load()，页面不会进错误态
        liveChannelId: liveChannelId,
      ),
    ));
    await t.pump();
    // ★ 让 initState 里那条真 FFI 查询的回调**真的**派发（fake_async 不会派发）
    await t.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    });
    await t.pump();
    if (enabled) debugPlayerSetDanmakuEnabledForProbe(true);
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    final bars =
        t.widgetList<PlayerBottomBar>(find.byType(PlayerBottomBar)).toList();
    if (bars.isEmpty) {
      throw StateError('底栏不在树里 —— 读数无意义（不是谓词的错，是夹具没挂稳）');
    }
    final d = bars.first.danmakuSend;
    final entries = t.widgetList(find.byType(DanmakuSendInline)).length;
    // 两个观测量必须同向：谓词给了数据 ⇒ 入口被建出来
    expect(entries, d == null ? 0 : 1,
        reason: '底栏拿到 danmakuSend=${d == null ? 'null' : d.provider} 时，'
            '发送入口数量必须与之同向（0 或 1）');
    return entries;
  }

  /// 一行真值表
  Future<void> row(
    WidgetTester t, {
    required int id,
    required bool enabled,
    required String provider,
    required bool providerIdResolved,
    required bool live,
    required int expected,
  }) async {
    final got = await mount(
      t,
      provider: provider,
      enabled: enabled,
      liveChannelId: live ? 'lc1' : null,
    );
    final canSend =
        providerIdResolved && provider == kSendCapable ? 'T' : 'F';
    final pass = got == expected;
    log('PRED|#$id enabled=${enabled ? 'T' : 'F'} canSend=$canSend '
        'provider=${providerIdResolved ? 'T' : 'F'} '
        'live=${live ? 'T' : 'F'} => entry=$got expected=$expected '
        '${pass ? 'PASS' : 'FAIL'}');
    expect(got, expected,
        reason: '第 $id 行：四条件 (enabled=${enabled ? 'T' : 'F'}, '
            'canSend=$canSend, provider=${providerIdResolved ? 'T' : 'F'}, '
            'live=${live ? 'T' : 'F'}) ⇒ 发送入口应当 '
            '${expected == 1 ? '出现' : '不出现'}');
  }

  /*
   * ══════════════════════════════════════════════════════════════════════
   *  源码契约：为什么第 ③ 条**只能**这么钉
   * ══════════════════════════════════════════════════════════════════════
   * 故障注入实测（第 ③ 条注入后真值表 **EXIT=0、零行变红**）：
   * ```text
   * 把 `_danmakuSendProvider != null &&` 从谓词里删掉 ⇒ 8 行全绿。
   * 原因不是"门禁写漏了"，是这一格**结构上不可达**：
   *   _danmakuCanSend 只在 _loadDanmakuSendCapability() 里赋值，
   *   而该函数里 id 为空时 canSend/provider 是**一起**置 false/null（:3383-3392），
   *   之后 canSend 只由 danmakuSendAllowed(list, id) 决定（:3413）。
   * ⇒ 「canSend 真 但 provider 空」没有任何代码路径能产生。
   * ```
   * 所以黑盒表**永远**钉不住它（谁删了它都是绿的）。它真正的职责是：
   * 万一哪天可达，`_danmakuSendProvider!` 会**当场空断言崩**，而不是渲染一个坏入口。
   * ⇒ 唯一能钉的办法是源码契约（与 task41 对 player_bottom_bar.dart 的做法同源）。
   * ⚠️ 本条不是"文字匹配凑数"：它同时断言 `: null` 分支还在 —— 删掉 false 支
   *    会让发送框**永不出现**，那是比"多一个入口"更重的回归。
   */
  group('源码契约（真值表够不着的第 ③ 条 + false 分支）', () {
    test('谓词四条缺一不可，且 false 分支仍然是 null', () {
      final raw = File('lib/ui/player_page.dart').readAsStringSync();
      final code = raw
          .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
          .replaceAll(RegExp(r'//[^\x0A]*'), '');
      final i = code.indexOf('danmakuSend: (');
      expect(i, greaterThan(0), reason: 'player_page.dart 里找不到底栏挂载点');
      final seg = code.substring(i, i + 700);
      for (final clause in <String>[
        '_danmakuEnabled',
        '_danmakuCanSend',
        '_danmakuSendProvider != null',
        '!_isLive',
      ]) {
        expect(seg.contains(clause), isTrue,
            reason: '谓词丢了条件 `$clause` —— 这一条被删后真值表未必变红，'
                '但行为一定变（入口该消失时不消失，或该出现时不出现）');
      }
      expect(seg.contains(': null'), isTrue,
          reason: 'false 分支不再返回 null ⇒ 发送数据成了「永远有值」，'
              '底栏会无视谓词恒显示入口');
      // 反查：入口数据真用的是谓词算出来的那个 provider，不是另一路来源
      expect(seg.contains('provider: _danmakuSendProvider!'), isTrue,
          reason: 'DanmakuSendData 的 provider 与谓词用的不是同一个字段');
    });
  });

  group('四条件真值表（真树 · PlayerPage → PlayerBottomBar.danmakuSend）', () {
    testWidgets('1 阳性对照：全 T ⇒ 入口必须出现', (t) async {
      await row(t,
          id: 1,
          enabled: true,
          provider: kSendCapable,
          providerIdResolved: true,
          live: false,
          expected: 1);
    }, skip: skipIt);

    testWidgets('2 总开关关 ⇒ 不出现', (t) async {
      await row(t,
          id: 2,
          enabled: false,
          provider: kSendCapable,
          providerIdResolved: true,
          live: false,
          expected: 0);
    }, skip: skipIt);

    testWidgets('3 源存在但不声明 danmaku_send ⇒ 不出现', (t) async {
      await row(t,
          id: 3,
          enabled: true,
          provider: kReadOnly,
          providerIdResolved: true,
          live: false,
          expected: 0);
    }, skip: skipIt);

    testWidgets('4 认不出真站点 id ⇒ 不出现', (t) async {
      // provider == 'local' 且没有 originProvider ⇒ providerNameLookupId 返回 null
      // （player_page.dart:20524 那一支）⇒ ② ③ 一起为假
      await row(t,
          id: 4,
          enabled: true,
          provider: 'local',
          providerIdResolved: false,
          live: false,
          expected: 0);
    }, skip: skipIt);

    testWidgets('5 直播态（其余全 T）⇒ 不出现', (t) async {
      await row(t,
          id: 5,
          enabled: true,
          provider: kSendCapable,
          providerIdResolved: true,
          live: true,
          expected: 0);
    }, skip: skipIt);

    testWidgets('6 全 F ⇒ 不出现', (t) async {
      await row(t,
          id: 6,
          enabled: false,
          provider: 'local',
          providerIdResolved: false,
          live: true,
          expected: 0);
    }, skip: skipIt);

    testWidgets('7 开关开 + 认不出 id ⇒ 不出现', (t) async {
      await row(t,
          id: 7,
          enabled: true,
          provider: 'local',
          providerIdResolved: false,
          live: false,
          expected: 0);
    }, skip: skipIt);

    testWidgets('8 可发送源 + 直播 + 开关关 ⇒ 不出现', (t) async {
      await row(t,
          id: 8,
          enabled: false,
          provider: kSendCapable,
          providerIdResolved: true,
          live: true,
          expected: 0);
    }, skip: skipIt);
  });
}
