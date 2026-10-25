@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  缺陷②（2026-10-25）：重试横幅不消失 + 遮挡底栏
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 报
// ```text
// 恢复之后那条「播放中断了（画面还在，可以重试）」一直挂着；
// 鼠标一动控制条浮上来，反而把「重试」盖住，点不到。
// ```
//
// # 两条根因（代码级，均已核对）
// ```text
// ① 没有「恢复」事件
//    `_playbackFailure` 的**唯一**清除路径是 `stream.width` 再次非空
//    （那是"分辨率变化"事件）。`_sawFirstFrame` 一旦为 true，
//    后面再没有事件会清它 ⇒ 播放其实恢复了（位置在推进），横幅永久挂着。
//
// ② 叠放顺序
//    Stack 的 children 顺序 = 绘制顺序（后写的画在上面）。
//    三条横幅改前写在 `_BottomBar` **之前** ⇒ 底栏画在横幅上面 ⇒ 盖住「重试」。
//    另一道保险是 `_bottomOccupied` 计入 `_playbackFailure`（占据态底栏整条卸下）。
// ```
//
// # 本文件的判据
// ```text
// ① 源码顺序：三条横幅的挂载点**必须**在 `_BottomBar(` 之后
// ② 正向恢复：`_playing == true` 且位置连续推进累计 ≥3s ⇒ 横幅消失
// ③ 阴性对照：`_playing == false`（暂停）时同样推进 ⇒ 横幅**不许**消失
// ④ 让位：`_playbackFailure != null` ⇒ `_bottomOccupied` 为真、底栏不在树上
// ```
//
// ⚠️ 为什么恢复要靠"推进"而不是"又出画面"：掉帧 / 缓冲重试期间
//    `stream.width` 不会再发（分辨率没变），但位置在推进 ⇒ 那才是"真的在放"。
//
// # 跑法
// ```powershell
// flutter test test/zz_t1024_player_banner_order_test.dart --concurrency=1 --run-skipped --tags native-media
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 把 Dart 源码里的注释替换成空白（保留换行与字符串字面量）。
///
/// ★ 为什么必须剥：本文件的判据①是按"文本先后"断言的，而注释里**也会出现**同样的
///   挂载点文本与类名。实测（2026-10-26）：把挂载点那行文本写进注释、放在底栏之前，
///   判据立刻红 —— 说明它读到了注释。反过来，真实挂载点被搬走而注释里留着旧文本时，
///   它会**假绿**。本仓已多次踩到"门禁读注释"（站名门禁 / native-media 登记门禁 / EOL 门禁同源）。
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  final n = src.length;
  while (i < n) {
    final c = src[i];
    if (c == '/' && i + 1 < n && src[i + 1] == '/') {
      while (i < n && src[i] != '\n') {
        out.write(' ');
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      var depth = 0;
      while (i < n) {
        if (src.startsWith('/*', i)) {
          depth++;
          out.write('  ');
          i += 2;
        } else if (src.startsWith('*/', i)) {
          depth--;
          out.write('  ');
          i += 2;
          if (depth == 0) break;
        } else {
          out.write(src[i] == '\n' ? '\n' : ' ');
          i++;
        }
      }
      continue;
    }
    if (c == "'" || c == '"') {
      final triple = (i + 2 < n && src[i + 1] == c && src[i + 2] == c);
      final delim = triple ? c * 3 : c;
      out.write(delim);
      i += delim.length;
      while (i < n) {
        if (!triple && src[i] == r'\' && i + 1 < n) {
          out.write(src[i]);
          out.write(src[i + 1]);
          i += 2;
          continue;
        }
        if (src.startsWith(delim, i)) {
          out.write(delim);
          i += delim.length;
          break;
        }
        out.write(src[i]);
        i++;
      }
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

const kBannerText = '播放中断了（画面还在，可以重试）';

/// 挂页 → 清错误 → 标首帧 → 注入一条"播放中"的错误 ⇒ 横幅出现
Future<void> armFailureBanner(WidgetTester t) async {
  await fixture.mountPlayer(t);
  expect(debugPlayerClearErrorForProbe(), isTrue);
  expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
  expect(debugPlayerInjectStreamErrorForProbe('fixture stream interrupted'),
      isTrue,
      reason: '★ 注入时必须已出过画面（否则走全屏错误层，不是本用例的对象）');
  await t.pump();
  expect(find.text(kBannerText), findsOneWidget, reason: '夹具自检：横幅必须在树上');
}

/// 连续推进 [seconds] 秒（每秒一个 tick，走**真实** `_onPositionTick`）
Future<void> advance(WidgetTester t, int seconds, {int from = 0}) async {
  for (var i = 1; i <= seconds; i++) {
    debugPlayerPushPositionForProbe(Duration(seconds: from + i));
    await t.pump();
  }
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

  test('① 源码顺序：三条横幅的挂载点都在 `_BottomBar(` **之后**', () {
    /*
     * ★ 2026-10-26：**先剥注释再找锚点**。
     *
     * 踩过的坑（一次真红，不是假想）：把挂载点那行文本写进**注释**、放在底栏之前，
     * 这条判据立刻变红 —— 说明它对顺序敏感，但也说明**注释能骗过它**：
     *   · 往注释里写一遍同样的文本 ⇒ 假红
     *   · 有人把真实挂载点搬走、只在注释里留一行旧文本 ⇒ 假绿
     * 本仓已多次踩到"门禁读注释"（站名门禁、native-media 登记门禁、EOL 门禁同源），
     * 所以这里统一先剥注释再匹配。
     */
    final src = _stripComments(
        File('lib/ui/player_page.dart').readAsStringSync());
    /*
     * ⚠️ 锚点必须是**挂载点**，不是注释里提到的那个名字。
     * 实测：`src.indexOf('_BottomBar(')` 命中的是文件头那条注释
     * （`//   -> _BottomBar(buffered:) -> _ProgressSlider …`），
     * 拿它当基准 ⇒ 横幅搬到哪都在它"之后" ⇒ 断言恒绿（假绿，本用例改过一版）。
     * ⇒ 用**构造处**的独特前缀（`_BottomBar(` 紧跟 `playing: _playing,`）。
     */
    /*
     * ⚠️ 锚点必须是**挂载点**，不是注释里提到的那个名字。
     * 实测：`src.indexOf('_BottomBar(')` 命中的是文件头那条注释
     * （`//   -> _BottomBar(buffered:) -> _ProgressSlider …`），
     * 拿它当基准 ⇒ 横幅搬到哪都在它"之后" ⇒ 断言恒绿（假绿，本用例改过一版）。
     * ⇒ 用**构造参数** `playing: _playing,` 反向定位那次真实调用。
     */
    // ⚠️ 用 **last**IndexOf：`playing: _playing,` 在别的小控件里也出现过
    //    （实测 4 处），只有最后一次是底栏挂载点。
    final markerAt = src.lastIndexOf('playing: _playing,');
    expect(markerAt, greaterThan(-1), reason: '锚点不存在：`playing: _playing,`');
    final barAt = src.lastIndexOf('_BottomBar(', markerAt);
    expect(barAt, greaterThan(-1), reason: '找不到 `_BottomBar(` 的挂载点');

    // ★ 用**挂载点**（`if (…)` 后面那个类名调用），不是类声明（`class _Xxx`）
    for (final entry in <String, String>{
      '_LiveAudioOnlyBanner': 'if (_liveAudioOnlyNotice != null)',
      '_VideoOutputDeadBanner': 'if (_videoOutputDead)',
      '_PlaybackFailureBanner': 'if (_playbackFailure != null && _error == null)',
    }.entries) {
      final mountAt = src.indexOf(entry.value);
      expect(mountAt, greaterThan(-1), reason: '挂载点不存在：${entry.value}');
      expect(mountAt, greaterThan(barAt),
          reason: '★★★ ${entry.key} 的挂载点必须在 `_BottomBar(` 之后 —— '
              '写在前面就会被底栏画在上面，「重试」点不到（Owner 报的就是这个）');
    }
  });

  testWidgets('② 正向恢复：`_playing` + 位置连续推进 ≥3s ⇒ 横幅消失', (t) async {
    await armFailureBanner(t);

    expect(debugPlayerSetPlayingForProbe(true), isTrue,
        reason: '★ 恢复判据要求真的在播（`_playing` = `stream.playing` 的镜像）');

    await advance(t, 2);
    expect(find.text(kBannerText), findsOneWidget,
        reason: '★ 只推进 2 秒还不够（阈值 3 秒）—— '
            '提前清除会让"还在恢复中"的抖动被当成已恢复');
    expect(debugPlayerPlaybackFailureState(), isNot(contains('failure=-')),
        reason: '★ 2 秒时横幅仍在（`_playbackFailure` 非空）');

    await advance(t, 1, from: 2);
    expect(find.text(kBannerText), findsNothing,
        reason: '★★★ 位置连续推进累计 3 秒 ⇒ 横幅必须自己消失（缺陷②的主判据）');
    expect(debugPlayerPlaybackFailureState(), contains('failure=-'),
        reason: '★★ 3 秒之后 `_playbackFailure` 必须被清空');
    expect(debugPlayerRecoveryStateForProbe(), contains('recoveryMs=0'),
        reason: '★ 清完之后推进量必须归零（否则下一次会立刻又被判"恢复"）');

    await fixture.drain(t);
  });

  testWidgets('③ 阴性对照：暂停（`_playing == false`）时推进 ⇒ 横幅不许消失', (t) async {
    await armFailureBanner(t);

    // ⚠️ 明确置成"没在播"（探针返回的是**读取后**的真实值，不是入参）
    expect(debugPlayerSetPlayingForProbe(false), isFalse,
        reason: '夹具自检：`_playing` 必须是 false');
    await advance(t, 4);
    expect(find.text(kBannerText), findsOneWidget,
        reason: '★★ 掉帧 / 暂停不是"恢复"—— 位置推进但没在播，'
            '横幅不许自己跑掉（否则用户会以为问题解决了）');

    await fixture.drain(t);
  });

  testWidgets('④ 让位：`_playbackFailure != null` ⇒ `_bottomOccupied` 为真、底栏不在树上', (t) async {
    await fixture.mountPlayer(t);
    expect(debugPlayerClearErrorForProbe(), isTrue);
    expect(debugPlayerMarkFirstFrameForProbe(), isTrue);
    debugPlayerHoverControlsForProbe();
    await t.pump();
    expect(find.byType(PlayerBottomBar), findsOneWidget,
        reason: '夹具自检：正常态下底栏必须在树上');
    expect(debugPlayerBottomOccupiedForProbe(), isFalse);

    expect(debugPlayerInjectStreamErrorForProbe('fixture stream interrupted'),
        isTrue);
    await t.pump();

    expect(debugPlayerBottomOccupiedForProbe(), isTrue,
        reason: '★★★ `_bottomOccupied` 必须计入 `_playbackFailure` —— '
            '否则底栏会跟横幅抢同一块底部区域');
    expect(find.byType(PlayerBottomBar), findsNothing,
        reason: '★★ 占据态下底栏整条卸下（结构上的"让位"）');

    await fixture.drain(t);
  });

  test('⑤ 源码契约：恢复判据读的是页面 `_playing`，不是每次 tick 一次原生属性', () {
    final src = _stripComments(
        File('lib/ui/player_page.dart').readAsStringSync());
    expect(src, contains('_recoveryProgress += p - _position;'),
        reason: '★ 推进量必须按真实差值累计');
    expect(src, contains('_recoveryProgress >= const Duration(seconds: 3)'),
        reason: '★★ 3 秒阈值（计划原文：要能过 t72_jank 这类掉帧场景）');
    expect(src, contains("AppLog.write(\n          'PLAY',\n          '播放已恢复"),
        reason: '★ 恢复必须落盘（事后能对齐"什么时候好的"）');
    expect(src, contains('_playing &&'),
        reason: '★★ 判据里必须有"在播"这一项');
  });
}
