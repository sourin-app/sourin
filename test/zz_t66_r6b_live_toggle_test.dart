// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 R6-b：直播态那枚「弹幕」开关不许撒谎
// ═══════════════════════════════════════════════════════════════════════
//
//  # 用户看到的现象（真机读数，改前）
//  ```text
//  全屏直播页底栏：[…, 弹幕, 更多]
//  点一下 +1s     ：[…, 弹幕 !, …, 弹幕失败：弹幕服务返回 HTTP 400]
//  再等 +13s      ：[…, 弹幕 !, …]
//  ⇒ 停在「开着、零弹幕、一枚看不懂的 !」—— 开关自己翻成了"开"，
//    而**没有任何一条直播弹幕请求**打成过。
//  ```
//
//  # 根因（wire 级，两条都要钉）
//  ```text
//  ① 唯一发出去的请求是 `POST …/api/v2/match`（番剧按文件名匹配），
//     带的是**频道名** ⇒ 这是点播那条路被直播借用了，服务端当然 400。
//  ② `_toggleDanmaku()` 没有任何直播守卫 ⇒ 状态照翻、提示照给，
//     于是"失败"被画成"已开启"。
//  ```
//
//  # 本轮裁决（沿用 R6 已定的先例，不新设计）
//  ```text
//  ① 直播态**整块不渲染**这两枚（开关 + 设置入口）——
//     与 `showEpisodeNav`（直播没有上一集/下一集 ⇒ 整块不出现）同一条口径；
//     「能力此刻不可用」才用 `enabled` 灰着，直播是**根本没有**这条路。
//  ② 守卫加在 `_toggleDanmaku()` 与 `_loadDanmakuNamed()`（唯一的请求叶子）：
//     判据是**发出去的请求数 = 0**，不是"点了不崩"。
//  ③ 点播路径**一行都不许变**。
//  ```
//
//  # 判据分两层（为什么必须两层）
//  ```text
//  A 层：真 `PlayerBottomBar` 的**渲染结果**（默认套件就跑）
//        —— 控件在不在，用 `find.byKey` 的命中数回答。
//  B 层：真 `PlayerPage` + **计数 transport**（`native-media`，默认跳过）
//        —— 请求发没发，用 `calls.isEmpty` 回答。
//  C 层（补充判据，不是主判据）：直播守卫必须**是第一句/在叶子之前**、
//        以及发送栏那个 AND 谓词的四项齐全。
//        ⚠️ C 层读源码，只为钉住"守卫没被顺手删掉"这件事；
//           行为判据在 A/B 两层，不许用 C 层替代。
//  ```
//
//  ⚠️ B 层为什么打 `native-media`：真 `PlayerPage` 的 `initState` 会建
//     `media_kit.Player()` ⇒ 需要 libmpv，而它在 flutter_tester 里有仓库
//     既有的偶发 native 崩溃（见 `dart_test.yaml` 顶部与 t27_w6 的长注释）。
//     手动跑：`flutter test test/zz_t66_r6b_live_toggle_test.dart
//             --run-skipped --tags native-media --concurrency=1`
//
//  # 隔离
//  ```text
//  每个用例 `ClipDownloader.debugSetDataDir(<临时目录>)`，收尾传 null ——
//  防止 `pumpWidget` 探针写到真实数据目录（AGENTS.md §8 的专门坑）。
//  ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_more_menu.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

// ── libmpv 夹具（惰性：只有 B 层真挂播放器的用例才会加载）─────���─────────

String? _libmpv;
bool _libmpvLoaded = false;

List<String> _libmpvCandidates() {
  if (Platform.isWindows) {
    return <String>[
      r'build\windows\x64\libmpv\libmpv-2.dll',
      r'build\windows\x64\runner\Release\libmpv-2.dll',
    ];
  }
  if (Platform.isMacOS) {
    return <String>[
      'macos/Pods/media_kit_libs_macos_video/Frameworks/'
          'Mpv.xcframework/macos-arm64_x86_64/libmpv-2.dylib',
    ];
  }
  return <String>[
    '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
    '/usr/lib/libmpv.so.2',
  ];
}

void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      return;
    }
  }
}

bool _requireLibmpv() {
  if (_libmpv != null) {
    if (!_libmpvLoaded) {
      _libmpvLoaded = true;
      MediaKit.ensureInitialized(libmpv: _libmpv);
    }
    return true;
  }
  markTestSkipped('libmpv 夹具缺失 ⇒ 播放器建不起来，本条无从断言。'
      '手动跑：先 `flutter build windows`；候选 = ${_libmpvCandidates()}');
  return false;
}

// ── 计数 transport（B 层的仪器）────────────────────────────────────────

/// 只记账、不出网的 danmaku 传输。
///
/// ★ 它顶替的是 `danmaku.dart` 里**唯一的**注入点
///   （`debugSetDanmakuTransportForTest`）⇒ 发没发请求这件事变成
///   一刀切的确定性判据，不是"跑到网上碰运气"。
class _CountingTransport implements DanmakuTransport {
  /// 已发出的请求（按发出顺序）
  final List<Uri> calls = <Uri>[];

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    calls.add(uri);
    // 回一个"在线但没命中"的响应，让调用方走完自己的分支
    return const DanmakuHttpResponse(
      statusCode: 200,
      body: '{"version":"1.21.5","animes":[],"comments":[],"isMatched":false}',
    );
  }

  @override
  void close() {}
}

// ── A 层夹具：真 `PlayerBottomBar`（不碰 PlayerPage，默认套件可跑）────

class _Spy {
  int toggles = 0;
  int settings = 0;
}

PlayerBottomBar _bar(_Spy spy, PopoverController controller, {required bool isLive}) =>
    PlayerBottomBar(
      controller: controller,
      playing: true,
      positionListenable: ValueNotifier<Duration>(Duration.zero),
      duration: const Duration(minutes: 24),
      isLive: isLive,
      rate: 1.0,
      volume: 60,
      muted: false,
      fullscreen: false,
      onTogglePlay: () {},
      onSeek: (_) {},
      onVolume: (_) {},
      onToggleMute: () {},
      onRate: (_) {},
      onToggleFullscreen: () {},
      onEpisodes: () {},
      hasEpisodes: false,
      showEpisodeNav: false,
      onNext: () {},
      hasNext: false,
      more: const PlayerMoreMenuData(groups: <MoreMenuGroup>[]),
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a.invalid/1.m3u8'),
        StreamCandidate(url: 'https://a.invalid/2.m3u8'),
      ],
      danmakuEnabled: false,
      danmakuBusy: false,
      onDanmakuToggle: () => spy.toggles++,
      onDanmakuSettings: () => spy.settings++,
    );

Future<_Spy> _pumpBar(WidgetTester t, {required bool isLive}) async {
  final spy = _Spy();
  final controller = PopoverController();
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(1400, 900);
  addTearDown(t.view.reset);
  final theme = AppTheme.themeFor(Brightness.dark);
  await t.pumpWidget(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: child ?? const SizedBox(),
      ),
      home: Scaffold(
        body: Material(
          type: MaterialType.transparency,
          child: Stack(
            children: <Widget>[
              Stack(children: <Widget>[_bar(spy, controller, isLive: isLive)]),
            ],
          ),
        ),
      ),
    ),
  );
  await t.pump();
  return spy;
}

// ── C 层用的源码工具 ───────────────────────────────────────────────────

String _stripComments(String s) {
  // 块注释 → 空；行注释 → 空。够用即可（本文件只喂我们自己的源码片段）。
  final noBlock = s.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock.replaceAll(RegExp(r'//[^\n]*'), ' ');
}

String _squash(String s) => s.replaceAll(RegExp(r'\s+'), ' ').trim();

String _read(String rel) => File(rel).readAsStringSync();

/// 从 `sig` 之后取出**大括号配平**的那一段（用于取方法体）
String _bodyAfter(String src, String sig) {
  final i = src.indexOf(sig);
  expect(i, greaterThanOrEqualTo(0), reason: '源码里找不到锚点：$sig');
  var depth = 0;
  var start = -1;
  for (var k = i; k < src.length; k++) {
    final c = src[k];
    if (c == '{') {
      if (depth == 0) start = k;
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0 && start >= 0) return src.substring(start, k + 1);
    }
  }
  fail('大括号不配平：$sig');
}

void main() {
  late Directory tmp;

  setUpAll(_prepareLibmpvFixture);

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zz_t66_r6b_');
    ClipDownloader.debugSetDataDir(tmp.path);
  });

  tearDown(() {
    debugSetDanmakuTransportForTest(null);
    RemoteBridge.instance.stop();
    SourinApi.debugLiveStreamFetcher = null;
    SourinApi.debugClearLiveStreamCache();
    ClipDownloader.debugSetDataDir(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  A 层：底栏的**渲染结果**（默认套件就跑）
  // ═══════════════════════════════════════════════════════════════════
  group('A 直播底栏：弹幕两枚整块不渲染', () {
    testWidgets('A① 命中数 = 0，而底栏其它入口还在（阳性对照）', (t) async {
      await _pumpBar(t, isLive: true);

      expect(
        find.byKey(PlayerBottomBar.danmakuToggleKey).evaluate().length,
        0,
        reason: '★★ 直播没有弹幕数据源 ⇒ 开关这枚**不许画出来**。'
            '画出来就是给人点，点了只有一条 HTTP 400 和一枚看不懂的 `!`。',
      );
      expect(
        find.byKey(PlayerBottomBar.danmakuSettingsKey).evaluate().length,
        0,
        reason: '★★ 设置入口同一条口径：设置面板里那把开关在直播里同样无处可落。',
      );
      expect(
        find.text('弹幕').evaluate().length,
        0,
        reason: '★★ 连「弹幕」这个标签都不该出现（不画控件不是说谎的另一种写法）。',
      );

      // 阳性对照：底栏本体确实画出来了 —— 否则上面三个 0 是"整页没渲染"的假绿
      expect(
        find.text('更多').evaluate().length,
        1,
        reason: '★ 阳性对照：底栏在树上（否则上面三条命中 0 毫无意义）',
      );
    });

    testWidgets('A② 成对：非直播点得到（+1），直播没有那枚可点（0）', (t) async {
      // ① 阳性对照：同一份 fixture 只把 isLive 改成 false ⇒ 这一下必须真的连到回调
      final vodSpy = await _pumpBar(t, isLive: false);
      expect(
        find.byKey(PlayerBottomBar.danmakuToggleKey).evaluate().length,
        1,
        reason: '★ 阳性对照：非直播时开关必须在',
      );
      await t.tap(find.byKey(PlayerBottomBar.danmakuToggleKey));
      await t.pump();
      expect(
        vodSpy.toggles,
        1,
        reason: '★ 仪器自检：这里的 tap 真的会打到 onDanmakuToggle'
            '（否则"直播态计数 0"可能只是 tap 根本没生效）',
      );

      // ② 直播：没有那枚可点 ⇒ 回调一次都不该被触发
      final liveSpy = await _pumpBar(t, isLive: true);
      expect(
        find.byKey(PlayerBottomBar.danmakuToggleKey).evaluate().length,
        0,
        reason: '★★ 直播态那枚控件不存在（与 A① 同一条判据，此处用于成对）',
      );
      expect(
        find.byKey(PlayerBottomBar.danmakuSettingsKey).evaluate().length,
        0,
        reason: '★★ 设置入口同样不存在',
      );
      expect(
        liveSpy.toggles,
        0,
        reason: '★★ 直播态：开关回调被触发 0 次（"点不到"在回调层面同样成立）',
      );
      expect(
        liveSpy.settings,
        0,
        reason: '★★ 直播态：设置入口回调被触发 0 次',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  B 层：真 PlayerPage + 计数 transport（`native-media`，默认跳过）
  // ═══════════════════════════════════════════════════════════════════
  group('B 真 PlayerPage：直播态请求数 = 0', () {
    testWidgets('B① 直播：开关不在树上，强推入口也一条请求都不发', (t) async {
      if (!_requireLibmpv()) return;

      // 直播取流走假传输：DRM 受保护 ⇒ isPlayable=false ⇒ 不碰 mpv open
      SourinApi.debugLiveStreamFetcher = (provider, channelId) async =>
          <StreamCandidate>[
            const StreamCandidate(
              url: 'https://x.invalid/drm.m3u8',
              kind: 'hls',
              label: '线路',
              drmProtected: true,
            ),
          ];

      final net = _CountingTransport();
      debugSetDanmakuTransportForTest(net);

      t.view.devicePixelRatio = 1.0;
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        const MaterialApp(
          home: PlayerPage(
            provider: 'cctv',
            id: 'cctv1',
            title: '直播弹幕门禁',
            liveChannelId: 'cctv1',
            isTv: false,
            isTouchOnly: false,
          ),
        ),
      );
      await t.pump();
      await t.pump();

      // ① 控件不存在（真树，真 host ⇒ 证明宿主真的把 isLive 传下去了）
      final toggle = find.byKey(PlayerBottomBar.danmakuToggleKey);
      if (toggle.evaluate().isNotEmpty) {
        // 万一哪天又画回来：点它，仍不许发请求（下面 ② 会红）
        await t.tap(toggle.first, warnIfMissed: false);
        await t.pump(const Duration(milliseconds: 300));
      }
      expect(
        net.calls.where((u) => u.path.contains('/api/v2/match')).toList(),
        isEmpty,
        reason: '★★ 判据：直播间发出去的 `/api/v2/match` 请求数必须是 0。'
            '（改前这里恰好有 1 条：频道名被当成番剧名，服务端回 400）',
      );

      // ② 把生产入口本身强推一遍（= 那枚开关 onTap 直连的方法）：
      //    没有控件 ⇒ 用户点不到；守卫 ⇒ 即使有人绕过控件也发不出请求。
      final before = DanmakuConfig.enabled;
      final after = await debugPlayerToggleDanmakuForProbe();
      await t.pump();
      expect(
        net.calls,
        isEmpty,
        reason: '★★ 判据：强推 `_toggleDanmaku()` 之后请求数仍然是 0 ——'
            '"点不到"与"发不出"是两件事，这里钉的是后者。'
            '读数：${net.calls}',
      );
      expect(
        after,
        isFalse,
        reason: '★★ 开关不许撒谎：直播态它不该被翻成"开"',
      );
      expect(
        DanmakuConfig.enabled,
        before,
        reason: '★★ 用户偏好也不该被这条注定失败的路改掉',
      );

      // ③ 叶子那条路：起播时 `unawaited(_loadDanmaku())` 不经过开关，
      //    所以「开关不渲染」拦不住它 —— 必须在叶子（唯一发请求处）同样断掉。
      final leafCount = await debugPlayerLoadDanmakuForProbe('cctv1');
      await t.pump();
      expect(
        net.calls,
        isEmpty,
        reason: '★★ 判据：直接走叶子取弹幕，直播间请求数仍然是 0。'
            '（起播那条路就是直接调它，绕开开关）读数：${net.calls}',
      );
      expect(
        leafCount,
        lessThanOrEqualTo(0),
        reason: '★ 叶子在直播态必须原样早退（一条都取不到）',
      );
    }, tags: 'native-media');

    testWidgets('B② 阳性对照：点播同一套仪器里请求数 ≥ 1', (t) async {
      if (!_requireLibmpv()) return;

      final net = _CountingTransport();
      debugSetDanmakuTransportForTest(net);

      t.view.devicePixelRatio = 1.0;
      await t.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => t.binding.setSurfaceSize(null));
      await t.pumpWidget(
        const MaterialApp(
          home: PlayerPage(
            provider: 'cctv',
            id: 'cctv1',
            title: '点播弹幕门禁',
            isTv: false,
            isTouchOnly: false,
          ),
        ),
      );
      // ★ 只 pump 一帧：`_load()` 在无网环境里必失败，多 pump 会把控制条收掉
      //   （见 player_episode_nav_boundary_test 的长注释）。
      expect(
        find.byKey(PlayerBottomBar.danmakuToggleKey).evaluate().length,
        1,
        reason: '★ 阳性对照：点播底栏那枚开关**必须**还在'
            '（证明 A 层的 0 不是"这东西永远不渲染"）',
      );

      // ★ 仪器自检写成「相对翻转」而不是「必须为 true」：`DanmakuConfig.enabled`
      //   是**跨用例存活的全局偏好**，上一个用例（B①）留下的状态会让"必须为 true"
      //   在故障注入时假红/假绿。这里只问一件事：同一条路走通时开关会不会翻。
      final startEnabled = debugPlayerDanmakuEnabled();
      final before = await debugPlayerToggleDanmakuForProbe();
      expect(
        before,
        !(startEnabled ?? false),
        reason: '★ 仪器自检：点播时同一条 `_toggleDanmaku()` 能把开关翻过去'
            '（起点 reading=${startEnabled ?? false}）',
      );
      await t.pump();
      expect(
        net.calls.where((u) => u.path.contains('/api/v2/match')).length,
        greaterThanOrEqualTo(1),
        reason: '★★ 仪器自检：计数 transport 真的数得到请求 ——'
            '否则 B① 的 `isEmpty` 结论作废（仪器坏了不能说"没发请求"）。'
            '读数：${net.calls}',
      );

      // ★ 排空 fake_async 的计时器（toast 1.2s / UiPrefs 落盘节流 0.3s），
      //   否则框架的 "A Timer is still pending" 不变量会把结论误判成失败。
      for (var i = 0; i < 3; i++) {
        await t.pump(const Duration(seconds: 5));
      }
    }, tags: 'native-media');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  C 层：源码契约（补充判据）
  // ═══════════════════════════════════════════════════════════════════
  group('C 源码契约（补充：守卫与谓词不许被顺手删掉）', () {
    test('C① `_toggleDanmaku()` 的第一句就是直播守卫', () {
      final body = _bodyAfter(_read('lib/ui/player_page.dart'),
          'Future<void> _toggleDanmaku() async {');
      final code = _squash(_stripComments(body));
      expect(
        code,
        startsWith('{ if (_isLive) return;'),
        reason: '★★ 守卫必须是**第一句**：它前面多一行状态翻转，'
            '开关就又会在直播里撒谎。实际开头：${code.substring(0, code.length > 80 ? 80 : code.length)}',
      );
    });

    test('C② 唯一的请求叶子（`_loadDanmakuNamed`）在发请求前就断掉直播', () {
      final src = _read('lib/ui/player_page.dart');
      final body = _bodyAfter(src, 'Future<void> _loadDanmakuNamed(String fileName) async {');
      final code = _stripComments(body);
      final guardAt = code.indexOf('if (_isLive) return;');
      final bindAt = code.indexOf('loadDanmakuBind(');
      final sendAt = code.indexOf('danmakuMatch(');
      expect(guardAt, greaterThanOrEqualTo(0),
          reason: '★★ 直播态必须在**叶子**这里断（起播/开关/面板/手动搜索四条路共用它）');
      expect(bindAt, greaterThan(-1), reason: '★ 锚点自检：叶子函数体没取错');
      expect(guardAt, lessThan(bindAt),
          reason: '★★ 守卫必须在任何网络/绑定查找**之前**');
      if (sendAt > -1) {
        expect(guardAt, lessThan(sendAt),
            reason: '★★ 守卫必须排在真正发请求的那句之前');
      }
    });

    test('C③ 底栏那两枚确实被 `if (!isLive)` 包住（不是逐枚散落判断）', () {
      final src = _read('lib/ui/player/player_bottom_bar.dart');
      final iGuard = src.indexOf('if (!isLive) ...[');
      expect(iGuard, greaterThan(-1),
          reason: '★★ 直播态「整块不渲染」的实现抓手：`if (!isLive) ...[`');
      final iToggle = src.indexOf('key: danmakuToggleKey');
      final iSettings = src.indexOf('key: danmakuSettingsKey');
      final iMore = src.indexOf('PlayerPopoverIds.more');
      expect(iToggle, greaterThan(iGuard), reason: '★ 开关必须在守卫之后（包在里面）');
      expect(iSettings, greaterThan(iToggle), reason: '★ 设置入口同理');
      expect(iMore, greaterThan(iSettings),
          reason: '★ 门控只该包住这两枚 —— 「更多」必须留在外面（它不属于弹幕）');
    });

    test('C④ 发送栏那个 AND 谓词四项齐全（此前无覆盖）', () {
      final src = readSourceSquashed();
      expect(
        src.contains(
            'danmakuSend: (_danmakuEnabled && _danmakuCanSend && _danmakuSendProvider != null && !_isLive)'),
        isTrue,
        reason: '★★ 这四项是一个整体：删掉 `_danmakuCanSend` ⇒ 不支持的源上'
            '入口常驻、点了必失败（既有测试全绿也发现不了）。'
            '删掉 `!_isLive` ⇒ 直播间又冒出"发弹幕"。',
      );
    });
  });
}

/// 把 `player_page.dart` 的 `danmakuSend:` 谓词**压成一行**再比
///
/// ★ 只读这一句所在的几百字符，避免整文件 2 万行的注释噪声。
String readSourceSquashed() {
  final src = _read('lib/ui/player_page.dart');
  final i = src.indexOf('danmakuSend: (');
  expect(i, greaterThan(-1), reason: '★ 锚点自检：`danmakuSend:` 不见了');
  final expr = src.substring(i, i + 600);
  return _squash(_stripComments(expr));
}
