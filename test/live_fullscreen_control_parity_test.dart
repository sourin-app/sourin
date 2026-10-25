// ═══════════════════════════════════════════════════════════════════════
//  第 16 项验收：内嵌与全屏控件一致
// ═══════════════════════════════════════════════════════════════════════
//
// # 计划原文（判据）
// ```text
// 16 内嵌与全屏控件一致：统一的是播放/暂停/静音/音量的**实际操作与状态反馈**，
//    不只图标；切全屏保留频道/播放状态/音量/静音；**核实是否共用播放器实例**。
// ```
//
// # 本文件钉住的三件事（都是"真的跑过代码"，不是读源码字符串）
// ```text
// ① 状态**搬运**：进全屏时交给全屏页的快照 = 内嵌播放器此刻的真实状态
//    （频道 id/name + playing/muted/volume），一个字段都不许漂。
// ② 状态**回传**：全屏页返回的快照被 `applyPlaybackSnapshot` 真的应用回
//    内嵌播放器（静音位 + 用户音量），**不是**只换了一个图标。
// ③ **不共用播放器实例**：全屏是另一条路由里的另一个 `Player`
//    （`player_page.dart:3240` 与 `live_embedded_player.dart:660` **各自**
//    `Player(...)`），两者之间只靠 `LivePlaybackSnapshot` 显式传值。
//    ⇒ 这里断言"往返之后内嵌实例还是同一个 State 且没被 dispose"，
//      这正是"两个实例 + 显式搬运"的可观测证据。
// ```
//
// # 怎么让整页真的挂起来（不然什么都验不到）
// ```text
// `loadAll()` 取数只走 FFI ⇒ 隔离环境失败 ⇒ `build` 只画错误卡，
// **连 `LiveEmbeddedPlayer` 都不挂载**。
// ⇒ 用 `LivePageState.debugLiveGroupsFetcher`（`@visibleForTesting`，
//   生产恒 null）注入两组频道；其余（缓存落盘/探测/定时器/选中恢复）
//   全部走**原路**，不是另一条平行实现。
// ★ 频道注入口只替换"取数那一句"，所以 `_providerOf` 也能正常反查源 id。
// ```
//
// # ⚠️ 这里**不能**验真机项（如实记录，不写成已完成）
// ```text
// `Player` 要 libmpv 才建得出来；`flutter test` 里 `_player` 恒为 null。
// ⇒ 下面这些验不了，别宣称已覆盖：
//   · 内嵌真的出声 / 进全屏后内嵌**真的**停了（双播放器音频释放）
//   · 全屏页里按暂停后回来**真的**不响
//   · mpv 的真实音量数值（这里验的是"用户意图值"这条链）
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

const _chA = LiveChannel(id: 'ch-a', name: '频道甲');
const _chB = LiveChannel(id: 'ch-b', name: '频道乙');

List<LiveGroup> _fakeGroups() => const [
      LiveGroup(
        provider: 'iptv',
        providerName: 'IPTV 直播',
        channels: [_chA, _chB],
      ),
    ];

/// 一次往返里全屏页**收到**的东西
class _Handoff {
  String? provider;
  String? channelId;
  String? name;
  LivePlaybackSnapshot? initial;
  int calls = 0;
}

void main() {
  setUp(() {
    LivePageState.debugLiveGroupsFetcher = () async => _fakeGroups();
  });

  tearDown(() {
    LivePageState.debugLiveGroupsFetcher = null;
  });

  /// 起一个宽布局（`width >= 900` ⇒ 不是 narrow）的直播页，等它把频道喂完
  Future<({LivePageState page, LiveEmbeddedPlayerState embedded})> pumpPage(
    WidgetTester t, {
    required Future<LivePlaybackSnapshot?> Function(
      String provider,
      String channelId,
      String name,
      LivePlaybackSnapshot initial,
    ) onWatch,
  }) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1000, 680);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });

    await t.pumpWidget(_host(LivePage(onWatchLivePlayback: onWatch)));
    await t.pump(); // 让 loadAll 的 Future 完成
    await t.pump(); // 让 setState 后的第一帧落地

    expect(find.byType(LivePage), findsOneWidget);
    expect(find.byType(LiveEmbeddedPlayer), findsOneWidget,
        reason: '★ 频道数据注入口没生效 / 页面停在加载或错误态 ⇒ '
            '内嵌播放器根本没挂载，下面的判据全都无从谈起');
    return (
      page: t.state<LivePageState>(find.byType(LivePage)),
      embedded:
          t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer)),
    );
  }

  testWidgets('① 进全屏时把「频道 + 播放/静音/音量」原样交给全屏页', (t) async {
    final handoff = _Handoff();
    final r =
        await pumpPage(t, onWatch: (provider, channelId, name, initial) async {
      handoff
        ..calls += 1
        ..provider = provider
        ..channelId = channelId
        ..name = name
        ..initial = initial;
      return initial; // 全屏里用户没动任何东西 ⇒ 原样回来
    });

    // 用户把音量调到 37（不是默认值，才能区分"搬运"和"写死"）
    await r.embedded.setVolume(37);
    await t.pump();
    expect(r.embedded.muted, isFalse);
    expect(r.embedded.desiredVolume, 37);

    await r.page.selectChannelForProbe(_chB);
    await t.pump();
    await t.pump();

    await r.page.watchLiveForProbe(LiveRoundtripReceipt());
    await t.pump();

    expect(handoff.calls, 1, reason: '进全屏的回调必须被调用一次');
    // ── 频道保留 ──
    expect(handoff.channelId, 'ch-b',
        reason: '★ 全屏页拿到的频道 id 不是当前选中台 ⇒ 切全屏会换台/黑屏');
    expect(handoff.name, '频道乙', reason: '★ 频道名没带过去 ⇒ 全屏标题错台');
    expect(handoff.provider, 'iptv', reason: '★ 源 id 没带过去 ⇒ 全屏页取不到流');

    // ── 播放/静音/音量 保留 ──
    final snap = handoff.initial!;
    expect(snap.volume, 37,
        reason: '★ 交给全屏的音量 ${snap.volume} ≠ 内嵌的 37 ⇒ '
            '全屏页会以错的音量起播（"只同步图标"的反面）');
    expect(snap.muted, r.embedded.muted,
        reason: '★ 静音位没带过去 ⇒ 内嵌静音、全屏却出声');
    expect(snap.playing, r.embedded.isPlaying,
        reason: '★ 播放态没带过去 ⇒ 内嵌暂停着，全屏却自己播起来');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('② 全屏返回的静音/音量被真的应用回内嵌播放器', (t) async {
    final handoff = _Handoff();
    final returned =
        LivePlaybackSnapshot(playing: false, muted: true, volume: 64);
    final r =
        await pumpPage(t, onWatch: (provider, channelId, name, initial) async {
      handoff
        ..calls += 1
        ..channelId = channelId
        ..initial = initial;
      // 用户在全屏里把音量改成 64 并点了静音
      return returned;
    });

    await r.embedded.setVolume(37);
    await t.pump();
    expect(r.embedded.desiredVolume, 37);

    await r.page.selectChannelForProbe(_chB);
    await t.pump();
    await t.pump();

    await r.page.watchLiveForProbe(LiveRoundtripReceipt());
    await t.pump();
    await t.pump();

    expect(handoff.calls, 1);
    // ★ 核心：全屏里改的东西必须落地到内嵌（不是只换了图标）
    expect(r.embedded.muted, isTrue,
        reason: '★ 全屏里点了静音，回到内嵌却没静音 ⇒ 状态反馈没统一');
    expect(r.embedded.desiredVolume, 64,
        reason: '★ 全屏里把音量改成 64，回到内嵌是 ${r.embedded.desiredVolume} ⇒ '
            '音量没有回传（回退成 37 或 100 都属于"两套状态"）');

    // 界面上的滑块必须跟着这个真实状态走（同一份状态的投影）
    final slider =
        t.widget<Slider>(find.byKey(const ValueKey('live-volume-slider')));
    expect(slider.value, 0, reason: '静音态下滑块必须显示 0（与 `muted` 一致）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('③ 往返之后内嵌实例仍是**同一个**（两处各持一个播放器）', (t) async {
    final r = await pumpPage(
        t, onWatch: (provider, channelId, name, initial) async => initial);

    final before = r.embedded;
    final disposal = before.disposalReceiptForProbe;

    await r.page.selectChannelForProbe(_chB);
    await t.pump();
    await t.pump();

    await r.page.watchLiveForProbe(LiveRoundtripReceipt());
    await t.pump();
    await t.pump();

    final after =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));
    /*
     * ★ 判据「核实是否共用播放器实例」的可观测形式：
     *   全屏是**另一条路由**（`onWatchLivePlayback` 交出去的只有
     *   provider/id/name + 快照），内嵌播放器**既不交出自己也不被销毁**
     *   ⇒ 往返之后必须还是同一个 State。
     *   `Player` 本身两处各自 `Player(...)` 创建（见文件头引用），
     *   这里能证的是"内嵌这一侧没有把实例交出去/重建"。
     */
    expect(identical(before, after), isTrue,
        reason: '★ 往返之后内嵌播放器的 State 换了 ⇒ 实例被重建/交出，'
            '那就不是"两个实例 + 快照搬运"而是"共用一个实例"的坏实现');
    expect(after.mounted, isTrue);
    expect(disposal.started, isFalse,
        reason: '★ 往返途中内嵌播放器被 dispose 了 ⇒ 返回后没有播放器可用');

    await t.pumpWidget(const SizedBox.shrink());
  });

  test('④ 两条链之间唯一的状态通道只搬运「播放/静音/音量」三项', () {
    /*
     * 结构判据：`LivePlaybackSnapshot` 是两条链之间**唯一**的显式状态通道，
     * 只有 playing / muted / volume 三项。任何把 `Player` / `VideoController`
     * 塞进来的改动都会改变这里的语义（那意味着"共用实例"）。
     */
    final snap = LivePlaybackSnapshot(playing: true, muted: false, volume: 55.5);
    expect(snap.playing, isTrue);
    expect(snap.muted, isFalse);
    expect(snap.volume, 55.5);

    final normalized =
        LivePlaybackSnapshot(playing: false, muted: true, volume: 555);
    expect(normalized.volume, 100,
        reason: '音量必须被夹到 0~100，否则全屏回来会得到一个非法音量');
    final nan =
        LivePlaybackSnapshot(playing: false, muted: false, volume: double.nan);
    expect(nan.volume, 100, reason: 'NaN 音量必须兜底成 100');
  });
}
