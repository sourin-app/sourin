// ═══════════════════════════════════════════════════════════════════════
//  task-92 真机探针：直播首帧黑窗期「正在加载直播画面…」是否真的画在屏幕上
//  task-92b：**慢首帧窗口（10.5s→15.5s）里提示是否一直没被撤掉**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它
//
// `test/t92_embed_first_frame_hint_test.dart` 只证明**判据**对（纯 Dart 逻辑）。
// 它证明不了「像素上真的不黑了」。而外部 `PrintWindow` 对这个构建的窗口
// 拿不到活帧（实测 flags=0/1/2/3 + RedrawWindow + DwmFlush 全部返回同一张
// 陈旧帧，见 `.probe/ops/_cap17.cs` / `_cap18.cs`）。
//
// ⇒ 改用**应用自己光栅化**：`RenderRepaintBoundary.toImage()`。
//   这是本仓库既有手法（`lib/merge_view_probe.dart:29-35`）：真实进程里
//   `toImage()` 正常工作，像素由 Flutter 自己光栅化，
//   与「窗口是否在前台 / 屏幕是否解锁」全都无关。
//
// # 它跑的是真东西
//
// 真 `LiveEmbeddedPlayer` + 真 `media_kit`/libmpv + 真直播源（ABN China，
// 同机 ffprobe 8005ms 的那个慢源）⇒ 复现 Owner 报的 8 秒黑窗。
//
// # 判据
//
// ① 黑窗期（还没见到视频轨）：`awaitingFirstVideoFrameForTest == true`
//    且截图的**中心小方框必须非纯黑**（均值 > 2）—— 这就是「不黑了」
// ② 见到视频轨之后：`awaitingFirstVideoFrameForTest == false`（提示收口）
// ③ 全程 `videoOutputDeadForTest == false`（慢源不许被误判成输出层死亡）
//
// # ★★ task-92b 新增的两条判据（本次修复的验收口径）
//
// ```text
// nf9 实测（改前）逐帧：
//   t=10530  awaiting=true   settled=false  loading=true   center=5.2   ← 提示还在
//   t=11031  awaiting=false  settled=true   loading=false  center=0.0   ← ★ 提示被撤
//   t=15042  awaiting=false  settled=true   loading=false  center=0.0   ← 还是纯黑
//   t=15542  awaiting=false  settled=true   loading=false  center=129.7 ← 首帧才到
// ⇒ 10.5s→15.5s **约 5 秒纯黑**。
//
// ④ windowHeld  —— t≥10.0s 且**首帧还没到**的每一帧都必须 awaiting=true
//                  且 loading=true 且 center>2（提示**全程**在，且像素非黑）
//                  ⚠️ 上界必须**跟着"首帧到没到"走**，不能写死毫秒：
//                     nf9 首帧 15542ms、nf10 首帧 12032/14542ms —— 写死
//                     会把"首帧已到、提示正确地撤了"的那一帧判成失败
//                     （仪器错误，不是产品缺陷）。
// ⑤ blackGap    —— 全程**不许**出现「已收口 + 无提示 + 中心纯黑」的帧
//                  （t>8s 才算，避开起播瞬间的正常空档）
// ⑥ settledEarly—— ★★★ **缺陷本体的直接计数**：首帧还没到（seen=false）
//                  就被判成"没有视频轨"（settled=true）的帧数。改前 >0，改后必须 =0。
// ```
//
// # 产物
//
// `.probe/ops/nf10/result.txt` + `t<ms>.png`；所有结论同时 debugPrint 到 stdout。

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'core/models.dart';
import 'ui/widgets/app_loading.dart';
import 'ui/widgets/live_embedded_player.dart';

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe\ops\nf10';

/// ABN China —— 同机 ffprobe probe_ms=8005 的慢源（Owner 撞上的就是它）
const _slowSource = 'https://mediaserver.abnvideos.com/streams/abnchina.m3u8';

final _rootKey = GlobalKey();
final _playerKey = GlobalKey<LiveEmbeddedPlayerState>();

void say(String s) => debugPrint('[T92] $s');

/// 树里有没有 `AppLoading`（提示真的挂上去了吗）
bool hasLoading() {
  var hit = false;
  void walk(Element e) {
    if (hit) return;
    if (e.widget is AppLoading) {
      hit = true;
      return;
    }
    e.visitChildren(walk);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root != null) walk(root);
  return hit;
}

/// 光栅化整棵树 → PNG；同时给出**中心小方框**的均值与颜色数（仪器自检）
Future<(int colors, double centerMean, int w, int h)> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) {
    say('✗ $name：根还没有 context');
    return (0, -1.0, 0, 0);
  }
  final obj = ctx.findRenderObject();
  if (obj is! RenderRepaintBoundary) {
    say('✗ $name：根不是 RenderRepaintBoundary');
    return (0, -1.0, 0, 0);
  }
  final img = await obj.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  File('$_outDir\\$name.png').writeAsBytesSync(png!.buffer.asUint8List());
  final rgba = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  final bytes = rgba!.buffer.asUint8List();
  final w = img.width, h = img.height;
  img.dispose();
  final seen = <int>{};
  for (var i = 0; i + 3 < bytes.length; i += 4 * 7) {
    seen.add((bytes[i] << 16) | (bytes[i + 1] << 8) | bytes[i + 2]);
  }
  // 中心 240x240（播放器是整窗，转圈就在正中心）
  final x0 = (w - 240) ~/ 2, y0 = (h - 240) ~/ 2;
  var sum = 0.0;
  var n = 0;
  for (var y = y0; y < y0 + 240 && y < h; y++) {
    for (var x = x0; x < x0 + 240 && x < w; x++) {
      final i = (y * w + x) * 4;
      sum += 0.299 * bytes[i] + 0.587 * bytes[i + 1] + 0.114 * bytes[i + 2];
      n++;
    }
  }
  return (seen.length, n == 0 ? -1.0 : sum / n, w, h);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();
  Directory(_outDir).createSync(recursive: true);
  runApp(
    MaterialApp(
      debugShowCheckedModeBanner: false,
      home: RepaintBoundary(
        key: _rootKey,
        child: ColoredBox(
          color: Colors.black,
          child: LiveEmbeddedPlayer(
            key: _playerKey,
            stream: const StreamCandidate(url: _slowSource),
            title: 'ABN China',
          ),
        ),
      ),
    ),
  );
  unawaited(_drive());
}

Future<void> _drive() async {
  final rows = <String>[];
  final sw = Stopwatch()..start();
  var sawAwaiting = false;
  var sawAwaitingWithHint = false;
  var hintNonBlack = false;
  var anyDead = false;
  var closedAfterTrack = true;
  // ★★ task-92b 新增：慢首帧窗口（10.0s→15.6s）与「纯黑空档」计数
  var windowSamples = 0;
  var windowHeld = 0;
  var blackGap = 0;
  var firstFrameMs = -1;
  var firstAuthMs = -1;
  var anyRealAudio = false;
  var settledEarly = 0;
  for (var k = 0; k < 44; k++) {
    final t = sw.elapsedMilliseconds;
    final st = _playerKey.currentState;
    final awaiting = st?.awaitingFirstVideoFrameForTest;
    final seen = st?.videoTrackSeenForTest;
    final settled = st?.noVideoTrackSettledForTest;
    final dead = st?.videoOutputDeadForTest;
    final hasPlayer = st?.hasPlayerForTest;
    // ★ task-92b：原始轨道证据（判据为什么收口 / 为什么不收口）
    final hasVt = st?.hasVideoTrackForTest;
    final realAudio = st?.realAudioTrackSeenForTest;
    final auth = st?.noVideoTrackAuthoritativeForTest;
    final loading = hasLoading();
    final r = await shoot('t$t');
    if (awaiting == true) {
      sawAwaiting = true;
      if (loading) sawAwaitingWithHint = true;
      if (loading && r.$2 > 2.0) hintNonBlack = true;
    }
    if (dead == true) anyDead = true;
    if (realAudio == true) anyRealAudio = true;
    if (seen == true && firstFrameMs < 0) firstFrameMs = t;
    if (auth == true && firstAuthMs < 0) firstAuthMs = t;
    if (seen == true && awaiting != false) closedAfterTrack = false;
    // ★④ 慢首帧窗口：提示必须**全程**在，且像素非黑
    //    ★ 判据是「**首帧还没到**」（seen != true），不是按毫秒切窗口 ——
    //      首帧到的那一帧本身 awaiting/loading 已经正确地翻了，
    //      拿它当"窗口内"是**仪器 off-by-one**（实测 14542 那一帧）。
    if (t >= 10000 && seen != true) {
      windowSamples++;
      if (awaiting == true && loading && r.$2 > 2.0) windowHeld++;
    }
    // ★⑥ 缺陷本体：首帧还没到就收口（改前正是这里 >0）
    if (seen != true && settled == true) settledEarly++;
    // ★⑤ 纯黑空档：已收口 + 提示没了 + 中心还是黑的
    if (t > 8000 &&
        settled == true &&
        awaiting == false &&
        loading == false &&
        r.$2 <= 2.0) {
      blackGap++;
    }
    rows.add(
      '$t,player=$hasPlayer,awaiting=$awaiting,seen=$seen,settled=$settled,'
      'auth=$auth,hasVt=$hasVt,realAudio=$realAudio,dead=$dead,loading=$loading,'
      'colors=${r.$1},center=${r.$2.toStringAsFixed(1)},${r.$3}x${r.$4}',
    );
    say(rows.last);
    // ★ 跑满慢首帧窗口之后才允许提前收：首帧 15.5s 才到，
    //   若在 6s 就 break（旧口径），10.5s→15.5s 那 5 秒根本没采到样。
    if (seen == true && t >= 16000) break;
    final spent = sw.elapsedMilliseconds - t;
    if (spent < 500) {
      await Future<void>.delayed(Duration(milliseconds: 500 - spent));
    }
  }
  final windowOk = windowSamples >= 2 && windowHeld == windowSamples;
  final noBlackGap = blackGap == 0;
  final lines = <String>[
    'source=$_slowSource',
    'sawAwaiting=$sawAwaiting',
    'sawAwaitingWithHint=$sawAwaitingWithHint',
    'hintNonBlack=$hintNonBlack',
    'anyDead=$anyDead',
    'closedAfterTrack=$closedAfterTrack',
    'windowSamples=$windowSamples',
    'windowHeld=$windowHeld',
    'windowOk=$windowOk',
    'blackGap=$blackGap',
    'noBlackGap=$noBlackGap',
    'firstFrameMs=$firstFrameMs',
    'firstAuthMs=$firstAuthMs',
    'anyRealAudio=$anyRealAudio',
    'settledEarly=$settledEarly',
    'noSettledEarly=${settledEarly == 0}',
    '--- rows ---',
    ...rows,
  ];
  File('$_outDir\\result.txt').writeAsStringSync(lines.join('\n'));
  say('==== RESULT ====');
  for (final l in lines) {
    if (!l.contains(',player=')) say(l);
  }
  say('✓ ① 黑窗期出现过 awaiting 且提示挂上树: $sawAwaitingWithHint');
  say('✓ ①b 黑窗期提示所在截图**中心非纯黑**: $hintNonBlack');
  say('✓ ② 见到视频轨后提示收口: $closedAfterTrack');
  say('✓ ③ 全程未误判输出层死亡: ${!anyDead}');
  say('✓ ④ ★★★ 慢首帧窗口全程有提示且非黑: $windowOk ($windowHeld/$windowSamples)');
  say('✓ ⑤ ★★★ 全程无「已收口+无提示+纯黑」空档: $noBlackGap (blackGap=$blackGap)');
  say('✓ ⑥ ★★★ 首帧未到就被判"没有视频轨"的帧数（必须 0）: $settledEarly');
  exit(0);
}

