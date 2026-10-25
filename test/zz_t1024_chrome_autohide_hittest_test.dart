library;

// ══════════════════════════════════════════════════════════════════════
//  真缺陷（2026-10-25，交叉复核用仪表钉死）：
//  「3 秒自动收起 → 鼠标叫回」之后，顶栏整条（含返回箭头）**看得见、点不到**
// ══════════════════════════════════════════════════════════════════════
//
// # 现场（不依赖错误态，正常播放也会中）
// ```text
// 1. `_autoHideNow()` 隐藏时只 `setState(() => _controlsVisible = false);`
//    —— **漏调 `_pushControlsLive()`** ⇒ `_controlsLive.value` 停在旧值 true；
// 2. 鼠标一动 → `_showControls()` 写 `_controlsVisible = true` 再 push，
//    而 push 的守卫是 `if (_controlsLive.value == _controlsVisible) return;`
//    ⇒ `true == true` **提前 return，不通知**；
// 3. `_TopBar` 只订阅 `_controlsLive` ⇒ 不重建 ⇒ 它那份 `visible` 仍是 false
//    ⇒ `IgnorePointer` 继续挡住；
// 4. 但 `_applyControlsMotion()` 照常把动画推到 1.0
//    ⇒ **不透明度 1.0 + 命中被挡** = 「箭头看得见、点不到」。
// ```
// 对照：正常 `_showControls()` 是 `set false → push → motion` 三步齐全，
// 所以那条路不复现。
//
// # 本文件钉两条
// ```text
// ① 不变量：任何时候 `_controlsLive.value == _controlsVisible`（含自动收起）；
// ② 行为：自动收起 → 鼠标唤起 ⇒ 顶栏返回箭头**真的进命中路径**、
//    底栏**真的可命中**，且底栏的播放回调**真的能触发**（计数 +1）。
// ```
// ⚠️ 改前 ② 必红（先跑过一遍取证：`.probe/final-fix-chrome-before.log`）。
//
// # 正确跑法（★ 这条门禁**故意不带 `native-media` 标签**）
// ```powershell
// # 单跑（最常用）
// flutter test test/zz_t1024_chrome_autohide_hittest_test.dart --concurrency=1
//
// # 默认全量（`flutter test test/`）里也会跑 —— 这正是要点
// flutter test test/ --concurrency=1
// ```
// ## 为什么**不能**加 `@Tags(['native-media'])`
// ```text
// `dart_test.yaml` 对该标签配的是 **`skip:`**（避免 libmpv 在 flutter_tester 里
// 偶发 native 崩溃）⇒ 标签一挂上，默认全量就会**跳过**这条门禁 ⇒ CI 里等于不存在。
// 而本文件**不需要 libmpv**：全靠探针驱动（`debugPlayerAutoHideControlsForProbe` /
// `debugPlayerHoverControlsForProbe` / `debugPlayerTopBarBackProbe`），不建真播放器。
// ```
// ## ⚠️ 两种错误跑法（都会"看起来没跑"）
// ```text
// · `--run-skipped --tags native-media` + 本文件**没有**该标签 ⇒ `No tests match`(79)
// · 不带参数 + 文件**挂标签** ⇒ `All tests skipped`
// ⇒ 现在无标签 ⇒ 最朴素的命令就能真跑；若将来有人加回标签，
//   默认全量会静默跳过 —— 这段注释就是防线。
// ```
// ## ⚠️ 它确实会 `MediaKit.ensureInitialized(libmpv)`（`PlayerPage` 挂载需要）
// ```text
// 所以默认全量里偶尔会撞上 `dart_test.yaml` 顶部记录的 libmpv native 崩溃：
// 症状是整文件 `did not complete`（exit 79）。
// ⇒ 那不是断言失败，重跑该文件即可；**不要**为了躲它把标签加回来
//   （加了就变成"永远不跑"，比偶发崩溃更糟）。
// ```

import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 等动画稳定（`_controlsFade` 是 220ms 动画）
Future<void> settleMotion(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 400));
  await t.pump();
}

/// 返回箭头此刻是否**真的在命中路径里**（几何相同的那块 RenderBox 存在）
///
/// 与 `zz_cr_backbtn_backarrow_test` 同一判据（那边是 Owner 验收用的仪表）：
/// `Opacity`/`IgnorePointer` 都不改布局 ⇒ 只看矩形不够，必须在箭头中心
/// 打一次**真实** hitTestOnBinding，看路径里有没有与之逐点相同的 RenderBox。
({Rect rect, double? opacity, bool ignoring, bool inHitPath})? readArrow(
    WidgetTester t) {
  final p = debugPlayerTopBarBackProbe();
  final rect = p?.$1;
  if (rect == null || rect.width <= 0) return null;
  var inHitPath = false;
  final hit = t.hitTestOnBinding(rect.center);
  for (final entry in hit.path) {
    final target = entry.target;
    if (target is RenderBox && target.attached && target.hasSize) {
      final r = target.localToGlobal(Offset.zero) & target.size;
      if ((r.left - rect.left).abs() < 0.5 &&
          (r.top - rect.top).abs() < 0.5 &&
          (r.width - rect.width).abs() < 0.5 &&
          (r.height - rect.height).abs() < 0.5) {
        inHitPath = true;
        break;
      }
    }
  }
  return (rect: rect, opacity: p?.$2, ignoring: p?.$3 ?? false, inHitPath: inHitPath);
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

  testWidgets('① 不变量：自动收起后 `_controlsLive` 必须跟着 `_controlsVisible` 一起变', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
    expect(debugPlayerSetPlayingForProbe(true), isTrue,
        reason: '★ `_autoHideNow()` 要求 `_playing == true`');
    debugPlayerHoverControlsForProbe();
    await settleMotion(t);

    expect(debugPlayerControlsVisibleForProbe(), isTrue);
    expect(debugPlayerControlsLiveForProbe(), isTrue,
        reason: '自检：唤起态两者都该是 true');

    // ── 自动收起（走生产 `_autoHideNow`）──
    expect(debugPlayerAutoHideControlsForProbe(), isTrue);
    await settleMotion(t);

    expect(debugPlayerControlsVisibleForProbe(), isFalse,
        reason: '自检：控制条必须真的收起');
    expect(debugPlayerControlsLiveForProbe(), isFalse,
        reason: '★★★ 不变量：收起后 `_controlsLive` 必须也是 false —— '
            '改前它停在 true（`_autoHideNow` 漏 push），于是下一次"叫回"'
            '会因为 `true == true` 提前 return，顶栏永远收不到通知');

    // ── 鼠标叫回 ──
    expect(debugPlayerHoverControlsForProbe(), isTrue);
    await settleMotion(t);
    expect(debugPlayerControlsVisibleForProbe(), isTrue);
    expect(debugPlayerControlsLiveForProbe(), isTrue,
        reason: '★★ 叫回之后两者必须再次一致');
  });

  testWidgets('② 行为：自动收起 → 鼠标唤起 ⇒ 顶栏箭头与底栏都必须真的可命中/可点', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
    expect(debugPlayerSetPlayingForProbe(true), isTrue);
    debugPlayerHoverControlsForProbe();
    await settleMotion(t);

    final shown = readArrow(t);
    expect(shown, isNotNull, reason: '自检：顶栏返回箭头必须在树上');
    expect(shown!.inHitPath, isTrue, reason: '自检：唤起态下箭头本该可点');

    // ── 自动收起 ──
    expect(debugPlayerAutoHideControlsForProbe(), isTrue);
    await settleMotion(t);
    final hidden = readArrow(t);
    expect(hidden!.inHitPath, isFalse,
        reason: '自检：收起后箭头不该可点（这条既有行为不能被本次修复破坏）');

    // ── 鼠标唤起（用户的日常动作）──
    expect(debugPlayerHoverControlsForProbe(), isTrue);
    await settleMotion(t);

    final afterHover = readArrow(t);
    /*
     * ★ 自证对照（Lead 要求）：`debugSetPlayingForProbe(false)` → `(true)`
     *   各触发一次**整页 setState** ⇒ 顶栏被迫重建 ⇒ `inHitPath` 必须变 true。
     *   证明"红"是**状态分裂**（`visible` 布尔没落地），不是探针/夹具坏了。
     *   ⚠️ 必须放在主断言**之前**：否则改前主断言先失败，对照永远跑不到。
     */
    expect(debugPlayerSetPlayingForProbe(false), isFalse);
    expect(debugPlayerSetPlayingForProbe(true), isTrue);
    await settleMotion(t);
    expect(readArrow(t)!.inHitPath, isTrue,
        reason: '★ 自证对照：一次整页 setState 之后箭头必须可命中 —— '
            '若这里也 false，说明是**探针/夹具**坏了，不是本缺陷');

    expect(afterHover!.opacity, 1.0,
        reason: '★ 鼠标一动箭头必须满不透明地回来（既有验收）');
    expect(afterHover.inHitPath, isTrue,
        reason: '★★★ 改前这里必红：不透明度已 1.0，但顶栏没重建 ⇒ '
            '`IgnorePointer` 仍挡着 ⇒「箭头看得见、点不到」。'
            '★ 判据必须是 `inHitPath`（真的进 hitTest 路径）——'
            '"矩形存在"和"可见"在本缺陷下**都是 true**，会假绿');

    // 底栏同理：必须可命中
    expect(find.byType(PlayerBottomBar).hitTestable(), findsOneWidget,
        reason: '★★ 底栏也必须真的可命中');

    // 且**真的可点**：直接调底栏那颗真实回调（`onTogglePlay`），断言计数 +1
    final bar = t.widget<PlayerBottomBar>(find.byType(PlayerBottomBar));
    final before = debugPlayerTogglePlayCalls();
    expect(before, isNotNull);
    bar.onTogglePlay();
    await t.pump();
    expect(debugPlayerTogglePlayCalls(), before! + 1,
        reason: '★★ 唤起后底栏的回调必须真的能触发（不是"看得见点不到"）');

    await fixture.drain(t);
  });
}
