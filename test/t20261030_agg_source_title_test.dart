@Tags(['native-media'])
// ═══════════════════════════════════════════════════════════════════════
//  现场反馈批次 2026-10-30：任务2 Dart —— 聚合源的播放源显示
//  顶栏 pill 与「线路/清晰度」抽屉行显示「TVBox 聚合(<备注>) · <label>」
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 验收②
// ```text
// 播放页顶部显示「TVBox 聚合(备注) · 子源名 · 线路」，聚合名读 AggregateConfig.note
// ```
//
// # 判据
// ```text
// ① 纯函数 aggregateSourceTitle 三态：空 note 不画括号（绝不画「TVBox 聚合()」）、
//    label 空只显示聚合名、非空拼「 · 」；
// ② 真树：provider=tvbox_agg ⇒ 顶栏 pill 与抽屉行都带前缀
//    （label = Rust 填的「子源 · 线路」）；
// ③ 真树：非聚合源（provider=cctv）⇒ 行标题原样 displayName，一个字不添。
// ```
//
// # 故障注入（实测见笔记）
// ```text
// 注入①：_topBarSourceName 退回 _providerName ⇒ 顶栏断言红；
// 注入②：_StreamSheet 行标题退回 s.displayName ⇒ 抽屉行断言红。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

// ═══════════════════════════════════════════════════════════════════════
//  libmpv 夹具（与 t72_stream_sheet_test 同一套 —— 缺夹具 skip，不是假红）
// ═══════════════════════════════════════════════════════════════════════

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
  return <String>['/usr/lib/x86_64-linux-gnu/libmpv.so.2'];
}

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

bool _requireLibmpv() {
  if (_libmpv != null) return true;
  return false; // 缺夹具 ⇒ 调用方 return（组①纯函数不受影响照跑）
}

List<Episode> _eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t, {required String provider}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: provider,
        id: '$provider-1',
        title: '聚合显示测试',
        episodes: episodes,
        episodeIndex: 0,
        episodeId: episodes.first.id,
        episodeTitle: episodes.first.title,
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  await t.pump();
  // FFI 在 flutter_tester 里加载不了 ⇒ _load 必然失败 ⇒ 抹平错误态
  debugPlayerClearErrorForProbe();
  await t.pump();
}

void main() {
  setUpAll(_prepareLibmpvFixture);

  group('① aggregateSourceTitle 纯函数（顶栏与抽屉行共用）', () {
    test('note 空 ⇒ 不画括号（绝不出现「TVBox 聚合()」）', () {
      expect(aggregateSourceTitle(), 'TVBox 聚合');
      expect(aggregateSourceTitle(note: ''), 'TVBox 聚合');
      expect(aggregateSourceTitle(note: '   '), 'TVBox 聚合',
          reason: '空白 note 按 trim 归空 —— 与 TvboxAggregate.note 的口径一致');
    });

    test('note 非空 ⇒ 画括号', () {
      expect(aggregateSourceTitle(note: '我的聚合'), 'TVBox 聚合(我的聚合)');
    });

    test('label 非空 ⇒ 拼「 · 」', () {
      expect(aggregateSourceTitle(note: '我的聚合', label: '子站A · 线路1'),
          'TVBox 聚合(我的聚合) · 子站A · 线路1');
      expect(aggregateSourceTitle(label: '子站A · 线路1'),
          'TVBox 聚合 · 子站A · 线路1',
          reason: '没配备注也要能看到子源（label 是 Rust 侧的本体信息）');
      expect(aggregateSourceTitle(note: 'n', label: '  '), 'TVBox 聚合(n)',
          reason: '空白 label 不许拼出「 · 」尾巴');
    });
  });

  testWidgets('② 真树：聚合源 ⇒ 顶栏与抽屉行都带「TVBox 聚合(备注) · 」前缀',
      (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t, provider: 'tvbox_agg');

    const streams = <StreamCandidate>[
      StreamCandidate(url: 'https://x.invalid/1.m3u8', label: '子站A · 线路1'),
      StreamCandidate(url: 'https://x.invalid/2.m3u8', label: '子站B · 线路2'),
    ];
    expect(debugPlayerSetStreamsForProbe(streams), isTrue);
    expect(
      debugPlayerSetAggregateTitleForProbe(
        note: '我的聚合',
        current: streams.first,
      ),
      isTrue,
      reason: '探针要真把 note/current 灌进生产 state',
    );
    await t.pump();

    // ── 顶栏 pill（正在播的当前线路）────────────────────────────────
    expect(find.text('TVBox 聚合(我的聚合) · 子站A · 线路1'), findsOneWidget,
        reason: '顶栏站名 pill 必须显示「TVBox 聚合(备注) · label」（Owner 验收②）');

    // ── 抽屉行（换源列表）────────────────────────────────────────────
    expect(debugPlayerOpenStreamSheetForProbe(), isTrue);
    await t.pump();
    // 开抽屉后顶栏 pill 仍在树里（淡出中/透明但未卸载）⇒ 当前串两处命中是**预期**
    expect(find.text('TVBox 聚合(我的聚合) · 子站A · 线路1'), findsWidgets,
        reason: '顶栏 pill + 抽屉当前行都显示「TVBox 聚合(备注) · label」');
    expect(find.text('TVBox 聚合(我的聚合) · 子站B · 线路2'), findsOneWidget,
        reason: '候选行也要带前缀 —— 用户才知道这条线路来自哪个子源');
    expect(find.text('子站B · 线路2'), findsNothing,
        reason: '聚合源下不许出现裸 displayName（改前形态）');
  });

  testWidgets('③ 真树：非聚合源 ⇒ 行标题原样，不添前缀', (t) async {
    if (!_requireLibmpv()) return;
    await _mount(t, provider: 'cctv');

    const streams = <StreamCandidate>[
      StreamCandidate(url: 'https://x.invalid/1.m3u8', label: '主线', quality: '高清'),
    ];
    expect(debugPlayerSetStreamsForProbe(streams), isTrue);
    // ★ 就便注入备注也**不许**影响非聚合源（判据在 _provider 上，不在 note 上）
    expect(debugPlayerSetAggregateTitleForProbe(note: '杂音'), isTrue);
    await t.pump();

    expect(debugPlayerOpenStreamSheetForProbe(), isTrue);
    await t.pump();
    expect(find.text('主线'), findsOneWidget,
        reason: '非聚合源的行标题 = displayName 原样（改前行为逐字不变）');
    expect(find.textContaining('TVBox 聚合'), findsNothing,
        reason: 'cctv 不是聚合源，前缀一个字都不许出现');
  });
}
