@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  第 16 项（2026-10-25）：**内嵌 / 全屏快捷键一致**
// ══════════════════════════════════════════════════════════════════════
//
// # 计划原文（这条验收的最后一块）
// ```text
// 16 内嵌与全屏控件一致：统一的是播放/暂停/静音/音量的**实际操作与状态反馈**，
//    不只图标；…快捷键…均一致。
// ```
// # 改前缺什么
// ```text
// 内嵌播放器已按共享契约处理「空格 / M」（`livePlaybackActionForKey` +
// `dispatchLivePlaybackAction`），而**全屏播放页**是各自手写的分支：
//   · 空格：`_onKey`（焦点路径）与 `_onHardwareKey`（硬件兜底）各有一条；
//   · **M**：只有 `_onKey` 那条 —— 焦点不在页内（全屏刚进来时正是这种）
//     ⇒ M 静音**完全没反应**，而空格因为另有一条兜底所以"看起来是好的"。
// ⇒ 「内嵌按 M 会静音、全屏按 M 不会」——这就是第 16 条要消灭的不一致。
// ```
// # 修法
// ```text
// `_PlayerPageState implements LivePlaybackTarget`（四个成员**转调**既有的
// `_togglePlay` / `_toggleMute` / `_player.state.playing` / `_muted`）；
// `_onHardwareKey` 在既有分支之后按**共用契约**派发：
//   final a = livePlaybackActionForKey(k);
//   if (a != null) { unawaited(dispatchLivePlaybackAction(this, a)); return true; }
// ⇒ 空格/M 只有一套「键→动作→调用」的真相；将来契约加键位本页自动跟上。
// ```
// # 三条门禁（本文件）
// ```text
// ① 全屏态：空格 ⇒ `_togglePlay` 真的被调（计数 +1）；
// ② 全屏态：M ⇒ `_toggleMute` +1 **且** `_muted` 真的翻转（不是只画图标）；
// ③ 打字态：空格/M **必须放行**（不被抢）—— 输入框里空格是打字。
// ```
// # 跑法
// ```powershell
// SOURIN_NO_REMOTE_AUTOSTART=1 flutter test test/zz_t1024_player_live_keys_test.dart \
//   --run-skipped --tags native-media --concurrency=1
// ```

import 'dart:io';

import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 挂页 **并提供一个"页外的焦点"**（模拟"焦点不在播放页"的全屏常态）
///
/// # 为什么需要它（这条用例的关键前提）
/// ```text
/// `_onHardwareKey` 的第 4 道门是 `if (_focusIsInsideThisPage(f)) return false;`
///   —— 焦点在页内时**故意让给 `_onKey`**（防双触发）。
/// 而第 16 项缺的那一块恰恰是"焦点不在页内"时的兜底（全屏刚进来就是这种）。
/// ⇒ 测试必须真的把焦点搬到**页外**的节点上，否则 handler 一定返回 false，
///   那条断言会"看起来是坏的"，实际是没造出场景。
/// ```
Future<FocusNode> mountWithFocusOutside(
  WidgetTester t, {
  /// true = 把焦点搬进一个**真实 TextField**（打字态）；false = 搬到一个空白 Focus（页外）
  bool typing = false,
}) async {
  final outside = FocusNode(debugLabel: 'outside-page');
  addTearDown(outside.dispose);
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: Stack(children: [
        PlayerPage(
          provider: 'cctv',
          id: 'cctv1',
          title: '快捷键一致性',
          episodes: fixture.fakeEpisodes(3),
          episodeIndex: 0,
          episodeId: 'ep1',
          isTv: false,
          isTouchOnly: false,
        ),
        // 焦点锚点：typing=false ⇒ 空白 Focus（页外）；true ⇒ 真实 TextField（打字态）
        Positioned(
          left: 0,
          top: 0,
          width: 240,
          child: typing
              ? TextField(
                  key: const ValueKey('typing-probe'),
                  focusNode: outside,
                )
              : Focus(
                  focusNode: outside,
                  child: const SizedBox(width: 1, height: 1),
                ),
        ),
      ]),
    ),
  ));
  await t.pump();
  expect(debugPlayerClearErrorForProbe(), isTrue);
  expect(debugPlayerForceBarsForShot(), isTrue);
  outside.requestFocus(); // ★ 焦点搬到页外
  await t.pump();
  return outside;
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('① 全屏态（焦点在页外）：空格 ⇒ 真的切播放/暂停（计数 +1）', (t) async {
    await mountWithFocusOutside(t);
    expect(debugPlayerIsTypingForProbe(), isFalse,
        reason: '★ 仪器自检：此刻不在打字态（否则门控会先放行，测不到快捷键）');

    final before = debugPlayerTogglePlayCalls();
    expect(before, isNotNull, reason: '★ 探针必须接上（null = 播放页没挂）');
    expect(debugPlayerHardwareKeyForProbe(LogicalKeyboardKey.space), isTrue,
        reason: '★★ 空格必须被本页接管（返回 true = handled）');
    await t.pump();
    expect(debugPlayerTogglePlayCalls(), before! + 1,
        reason: '★★★ 空格必须真的走 `_togglePlay`（与内嵌同一个动作）');
    // `_flash` 会挂 1.2s 定时器 —— 不排空会报 "Pending timers"
    await fixture.drain(t);
  });

  testWidgets('② 全屏态（焦点在页外）：M ⇒ 真的静音/取消静音（状态翻转，不只图标）', (t) async {
    await mountWithFocusOutside(t);
    expect(debugPlayerIsTypingForProbe(), isFalse, reason: '★ 仪器自检：不在打字态');

    final mutedBefore = debugPlayerMutedForProbe();
    final callsBefore = debugPlayerToggleMuteCalls();
    expect(mutedBefore, isNotNull);
    expect(callsBefore, isNotNull);

    expect(debugPlayerHardwareKeyForProbe(LogicalKeyboardKey.keyM), isTrue,
        reason: '★★★ 全屏按 M 必须被接管 —— 改前只有焦点在页内时 `_onKey` 处理，'
            '焦点不在（刚进全屏的常态）就**完全没反应**');
    await t.pump();
    expect(debugPlayerToggleMuteCalls(), callsBefore! + 1,
        reason: '★★ M 必须真的走 `_toggleMute`（共用契约派发，不是本页另写一套）');
    expect(debugPlayerMutedForProbe(), !mutedBefore!,
        reason: '★★★ `_muted` 必须真的翻转（$mutedBefore → '
            '${debugPlayerMutedForProbe()}）—— 只改图标不改状态就是"两套真相"');

    // 再按一次必须回到原值（幂等翻转，不是单向开关）
    expect(debugPlayerHardwareKeyForProbe(LogicalKeyboardKey.keyM), isTrue);
    await t.pump();
    expect(debugPlayerMutedForProbe(), mutedBefore,
        reason: '★★ 再按一次 M 必须解除静音（往返一致）');
    expect(debugPlayerToggleMuteCalls(), callsBefore + 2);
    await fixture.drain(t);
  });

  testWidgets('③ 打字态（真实输入框持焦点）：空格/M 必须放行，不许被抢', (t) async {
    await mountWithFocusOutside(t, typing: true);
    expect(debugPlayerIsTypingForProbe(), isTrue,
        reason: '★ 仪器自检：焦点必须真的落在 EditableText 上（否则打字态没造出来，'
            '下面两条"放行"会变成"巧合"}');

    final playBefore = debugPlayerTogglePlayCalls();
    final muteBefore = debugPlayerToggleMuteCalls();
    final mutedBefore = debugPlayerMutedForProbe();

    expect(debugPlayerHardwareKeyForProbe(LogicalKeyboardKey.space), isFalse,
        reason: '★★★ 打字态下空格必须**放行**（返回 false）—— '
            '被抢的话用户在输入框里打不出空格，反而把视频暂停了');
    expect(debugPlayerHardwareKeyForProbe(LogicalKeyboardKey.keyM), isFalse,
        reason: '★★ 打字态下 M 也必须放行（那是输入字母 M，不是静音）');
    await t.pump();

    expect(debugPlayerTogglePlayCalls(), playBefore,
        reason: '★★★ 空格**一次都不许**触发 `_togglePlay`（实测计数必须不变）');
    expect(debugPlayerToggleMuteCalls(), muteBefore,
        reason: '★★ M 一次都不许触发 `_toggleMute`');
    expect(debugPlayerMutedForProbe(), mutedBefore,
        reason: '★ 静音状态不许因为打字而翻转');
    await fixture.drain(t);
  });

  testWidgets('④ 浮层打开 + 焦点在页内：M 必须让位（不许静音后台播放器）', (t) async {
    /*
     * ★★★ 2026-10-25（交叉复核抓的必需修复）
     *
     * # 缺陷（V43h 那个真 bug 的同一形态，当时只修了空格）
     * ```text
     * `_onKey` 的空格分支有 `if (_anySheetOpen) return ignored;`，
     * 而 **M 分支没有** ⇒ 选集/设置/线路/提示 打开、焦点在页内时按 M，
     * 会把**后台播放器**静音：浮层挡着看不见、也听不出，
     * 回来发现"怎么没声音了"。
     * 而焦点在页外时全局门控（`_onHardwareKey` 的 `_anySheetOpen`）已经挡住
     * ⇒ 同一个键两种语义。
     * ```
     * # 本用例
     * ```text
     * 打开选集浮层（生产 `_episodeSheetOpen`）⇒ 断言 `_anySheetOpen` 为真
     * ⇒ 走**焦点树路径** `_onKey` 按 M ⇒ 必须返回 ignored，且 `_muted` 不变。
     * ```
     */
    await fixture.mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
    await t.pump();

    expect(debugPlayerOpenEpisodesForProbe(), isTrue);
    await t.pump();
    expect(debugPlayerAnySheetOpen(), isTrue,
        reason: '★ 仪器自检：浮层必须真的开着（否则本用例什么都没验到）');

    final mutedBefore = debugPlayerMutedForProbe();
    final callsBefore = debugPlayerToggleMuteCalls();
    expect(mutedBefore, isNotNull);
    expect(callsBefore, isNotNull);

    expect(debugPlayerFocusKeyHandledForProbe(LogicalKeyboardKey.keyM), isFalse,
        reason: '★★★ 浮层开着时 M 必须**让位**（返回 ignored）—— '
            '改前它会静音后台播放器，用户回来发现没声音');
    await t.pump();
    expect(debugPlayerToggleMuteCalls(), callsBefore,
        reason: '★★ `_toggleMute` 一次都不许被调用');
    expect(debugPlayerMutedForProbe(), mutedBefore,
        reason: '★★ 静音状态必须不变（$mutedBefore）');

    // 阴性对照：关掉浮层后 M 必须**恢复**生效（不能把 M 一起修死）
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerForceBarsForShot(), isTrue);
    await t.pump();
    await fixture.drain(t);
  });
}
