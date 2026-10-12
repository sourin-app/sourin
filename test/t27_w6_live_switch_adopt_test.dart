// ══════════════════════════════════════════════════════════════════════════
//  T27-06 验收③：widget 驱动 _adoptLiveChannel 两次 —— 第二次不再调
//  SourinApi.getLiveStream 的底层取数（缓存命中）。
//
//  # 为什么数「fake 取数器」而不是直接数 SourinApi 调用
//  ```text
//  · _adoptLiveChannel 直接调 SourinApi.getLiveStream（静态方法）——
//    widget 层没法替换它；但 debugLiveStreamFetcher（@visibleForTesting，
//    debugListFetcher 同一惯例）可以注入 fake 取数器，它顶替的是核心层
//    传输（callAsync）—— 缓存照常生效。
//  · 所以这里数的是 fake 取数器的调用次数：同台切第二次必须命中缓存。
//  · 计数按 channelId 分键：预取/切台会取「别的」频道，不能污染本频道。
//  ```
//
//  # 崩溃门（dart_test.yaml：native-media 默认 skip）
//  ```text
//  挂 PlayerPage = 挂真 mpv ⇒ flutter_tester 里偶发 native 崩溃
//  （c0000005，见 dart_test.yaml 顶部）⇒ 挂 PlayerPage 的用例打
//  native-media 标签默认 skip；有 libmpv 夹具时用
//  --run-skipped --tags native-media --concurrency=1 显式跑。
//  夹具探测/缺夹具优雅 skip 与 t72_jank_test.dart 同一做法。
//  ```
//
//  # 为什么全用固定 pump、零 pumpAndSettle（实测教训）
//  ```text
//  mpv open 后内部 timer/demuxer 在 flutter_tester 里永不空闲 ⇒
//  pumpAndSettle 必然超时（10 连泵实测）⇒ 固定 pump 序列代替
//  （t72_jank_test.dart 同一先例：只 pump 不 settle）。
//  驱动方式：键盘事件在本页收不到（player_page.dart:2065 先例备注）
//  ⇒ 探针开面板 + tap 频道项驱动 _pickLiveChannel → _adoptLiveChannel。
//  ```
//
//  # 为什么 fake 返回 DRM 受保护候选（而不是可播候选）
//  ```text
//  链路证据（①②打点+缓存计数）都发生在 _startPlayback 之前 ⇒ 让 first==null
//  （无线路可播）分支替我们挡住 mpv open：flutter_tester 里真 open 过的
//  media_kit 内部 Timer 永远收不掉，fake-async 不变式必炸（Timer still
//  pending，实测三次）。缺 mpv 播放断言 = 本用例只守「取数次数+打点链路」，
//  播放器行为有 t72 的仪器自检守着。
//  ```
// ══════════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

String? _libmpv;

/// 惰性加载标志：true = MediaKit.ensureInitialized 已在本进程执行过
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

// ══════════════════════════════════════════════════════════════════════════
//  ★ T27-14 惰性加载（t61_panel_radius_test.dart:205-242 同款形状）：
//
//  # 为什么 setUpAll 绝不能 MediaKit.ensureInitialized
//  ```text
//  dart_test.yaml 的 native-media 标签只跳「用例」—— setUpAll 照跑。
//  旧写法 setUpAll 里 ensureInitialized ⇒ 默认套件（全部用例 skip）也把
//  libmpv-2.dll 装进了 flutter_tester 进程；该 DLL 在 flutter_tester 里
//  有仓库既有的 native 崩溃（c0000005，见 dart_test.yaml 顶部，A/B
//  加载崩 6/25 vs 不加载 0/25），且崩点常在 tearDownAll 阶段
//  （_gate_final.log:1318 '(tearDownAll) - did not complete'，批次 exit 1）。
//  ⇒ 拆成两步：setUpAll 只「探测路径」；真加载进 _requireLibmpv()，
//    只有真要挂播放器的用例（--run-skipped 显式跑）才会触发。
//  ```
//  ⚠️ skip/fail 语义逐字保留：夹具缺失 ⇒ markTestSkipped(原文案)；
//     SOURIN_REQUIRE_LIBMPV=1 ⇒ fail。
// ══════════════════════════════════════════════════════════════════════════

/// 探测夹具路径（setUpAll 用）——**只探测，绝不加载**。
void _prepareLibmpvFixture() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      return;
    }
  }
  // 探不到时**什么都不做**（不打印，保持默认路径 stdout 零噪声）——
  // 语义由 _requireLibmpv() 下沉到依赖播放器的用例。
}

bool _requireLibmpv() {
  if (_libmpv != null) {
    // ★ 唯一的加载点（惰性 + 幂等）：ensureInitialized 进程内重复调用安全，
    //   但用标志位防 print 每用例重复。默认套件（用例全 skip）永远走不到这。
    if (!_libmpvLoaded) {
      _libmpvLoaded = true;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      // ignore: avoid_print
      print('[LIBMPV] 夹具 = $_libmpv（惰性：真播放器用例触发）');
    }
    return true;
  }
  if (Platform.environment['SOURIN_REQUIRE_LIBMPV'] == '1') {
    fail('libmpv 夹具缺失（SOURIN_REQUIRE_LIBMPV=1）');
  }
  markTestSkipped('libmpv 夹具缺失 ⇒ 播放器建不起来，本条无从断言。'
      '手动跑：先 `flutter build windows`；候选 = ${_libmpvCandidates()}');
  return false;
}

/// 「切台」tag 行数（AppLog 内存环，_liveSwitchMark 恒开写入）
int _switchMarks() {
  var n = 0;
  for (final l in AppLog.lines) {
    if (l.tag == '切台') n++;
  }
  return n;
}

/// 每频道取数次数 —— ★ 按 channelId 分键（provider 恒 'cctv'）：
/// 预取/切台会取「别的」频道，不能污染「本频道」的计数。
final Map<String, int> callsByChannel = <String, int>{};

int _calls(String id) => callsByChannel[id] ?? 0;

List<String> _allTexts(WidgetTester t) => [
  for (final e in t.allElements)
    if (e.widget is Text) ((e.widget as Text).data ?? ''),
];

Future<void> _tapChannel(WidgetTester t, String name) async {
  // ★ 面板项是流式排布的富内容，Center>Text 直系查找常失配 ⇒ textContaining。
  // ★ 必须取 .last：切台后播放页顶栏也有同名文本，且渲染在面板**之前**
  //   （面板在 overlay 栈顶）——取 .first 会点到屏障后面的标题，tap 被
  //   modal 屏障拦掉（hit-test warning）⇒ adopt 根本不发生，
  //   「缓存命中」断言会假绿。marks 增量断言就是为这种假绿兜底的。
  final f = find.textContaining(name);
  if (f.evaluate().isEmpty) {
    // ignore: avoid_print
    print('[DIAG] 找不到频道项「$name」；现有文本=${_allTexts(t)}');
    fail('面板里找不到频道项「$name」');
  }
  // ignore: avoid_print
  print('[DIAG] 「$name」匹配 ${f.evaluate().length} 处，取最后一处（面板项）');
  await t.tap(f.last);
  // adopt 是 async（取数 → mpv open）⇒ 固定 pump 序列推进（绝不 settle）
  await t.pump();
  await t.pump(const Duration(milliseconds: 120));
  await t.pump(const Duration(milliseconds: 250));
  await t.pump(const Duration(milliseconds: 300));
}

void _dumpMarks(String at) {
  // ignore: avoid_print
  print('[切台marks|$at] ' +
      AppLog.lines
          .where((l) => l.tag == '切台')
          .map((l) => l.message)
          .join(' | '));
}

Future<void> _mountLive(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '直播切台计时',
        liveChannelId: 'cctv1',
        onLiveChannelStep: (delta) => null,
        onLiveChannels: () => (
          channels: const <LiveChannel>[
            LiveChannel(id: 'cctv1', name: 'CCTV-1', group: '央视'),
            LiveChannel(id: 'cctv2', name: 'CCTV-2', group: '央视'),
          ],
          index: 0,
        ),
        onLiveChannelPick: (channel) => (provider: 'cctv', channel: channel),
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  await t.pump();
}

void main() {
  setUpAll(_prepareLibmpvFixture);
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() {
    // ★ PlayerPage.initState 会 RemoteBridge.setPlayer(...)（initState:2148）
    //   —— 桥自己的心跳/轮询 timer 不停的话，fake-async 不变式必炸
    //   （Timer still pending）。t72_jank_test.dart 同一先例。
    RemoteBridge.instance.stop();
    SourinApi.debugLiveStreamFetcher = null;
    SourinApi.debugClearLiveStreamCache();
    AppLog.debugClear();
    callsByChannel.clear();
  });

  testWidgets('切台两次：第二次不再调 getLiveStream（缓存命中）+ AppLog 打点',
      tags: 'native-media', (t) async {
    if (!_requireLibmpv()) return;
    SourinApi.debugLiveStreamFetcher = (provider, channelId) async {
      callsByChannel[channelId] = _calls(channelId) + 1;
      // ★ DRM 受保护 ⇒ isPlayable=false（models.dart:822）⇒ adopt/首播
      //   停在「无线路可播」分支，不碰 _startPlayback/mpv open ——
      //   flutter_tester 里真 open 的 media_kit 内部 Timer 收不掉，
      //   会炸 fake-async 不变式（Timer still pending，实测）。缓存与
      //   AppLog 打点链路都在 first==null 分支**之前**，语义不受影响。
      return <StreamCandidate>[
        const StreamCandidate(
          url: 'https://x.invalid/drm.m3u8',
          kind: 'hls',
          drmProtected: true,
        ),
      ];
    };
    AppLog.debugSetEnabled(false); // 只用内存环（测试环境不落盘）
    AppLog.debugClear();
    await _mountLive(t);

    // ── 首播：_load() → getLiveStream（cctv1 真取 1 次）→ open ──
    await t.pump(const Duration(milliseconds: 80));
    await t.pump(const Duration(milliseconds: 300));
    await t.pump(const Duration(milliseconds: 300));
    expect(_calls('cctv1'), 1,
        reason: '首播真取一次（实际 ${_calls('cctv1')}）');
    expect(_switchMarks(), greaterThanOrEqualTo(2),
        reason: '首播链路至少打 ①(进页取地址)+②(地址到手)，'
            '实际=${_switchMarks()}');
    _dumpMarks('首播后');

    // ── adopt ①：面板 → CCTV-2（异台，真取一次）──
    expect(debugPlayerOpenLiveChannelsForProbe(), isTrue,
        reason: '探针开面板失败 = PlayerPage 没挂上');
    await t.pump(const Duration(milliseconds: 120));
    await t.pump(const Duration(milliseconds: 260));
    await _tapChannel(t, 'CCTV-2');
    expect(_calls('cctv2'), 1,
        reason: '切到异台必须恰好真取一次（实际 ${_calls('cctv2')}）');
    final marksAfterAdopt1 = _switchMarks();
    _dumpMarks('adopt①后');

    // ── adopt ②：面板 → 再点 CCTV-2（同台，30s 内必须缓存命中）──
    expect(debugPlayerOpenLiveChannelsForProbe(), isTrue);
    await t.pump(const Duration(milliseconds: 120));
    await t.pump(const Duration(milliseconds: 260));
    await _tapChannel(t, 'CCTV-2');
    expect(_calls('cctv2'), 1,
        reason: '同台第二次 adopt 不再调 getLiveStream（30s 缓存命中）——'
            '这条红 = T27-06 根因没除（实际 ${_calls('cctv2')}）');
    expect(_switchMarks(), greaterThanOrEqualTo(marksAfterAdopt1 + 2),
        reason: '缓存命中的 adopt 也要走完整链路 ①切台发起+②地址到手，'
            'marks=$marksAfterAdopt1 → ${_switchMarks()}');
    _dumpMarks('adopt②后');

    // 收尾：卸载播放页 ⇒ dispose 播放器（否则 mpv 内部 timer 挂到 teardown）。
    // 卸载后轮询循环的下一次检查就 !mounted → return（_reportFirstFrame 守卫
    // player_page.dart:1948、_watchVideoOutput:2963 同款）——但得先泵过
    // 各自 pending 的 Future.delayed（50ms/250ms/500ms）才轮到检查：
    // 泵 1s×2 覆盖全部间隔，fake-async 不变式才不会报 Timer still pending。
    await t.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(milliseconds: 300));
  });
}

