// ═══════════════════════════════════════════════════════════════════════
//  task-92 真机探针：直播首帧黑窗期「正在加载直播画面…」是否真的画在屏幕上
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
// # 产物
//
// `.probe/ops/nf9/result.txt` + `t<ms>.png`；所有结论同时 debugPrint 到 stdout。

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

const _outDir = r'D:\WishProject\sourin-flutter-spike\.probe\ops\nf9';

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
  for (var k = 0; k < 44; k++) {
    final t = sw.elapsedMilliseconds;
    final st = _playerKey.currentState;
    final awaiting = st?.awaitingFirstVideoFrameForTest;
    final seen = st?.videoTrackSeenForTest;
    final settled = st?.noVideoTrackSettledForTest;
    final dead = st?.videoOutputDeadForTest;
    final hasPlayer = st?.hasPlayerForTest;
    final loading = hasLoading();
    final r = await shoot('t$t');
    if (awaiting == true) {
      sawAwaiting = true;
      if (loading) sawAwaitingWithHint = true;
      if (loading && r.$2 > 2.0) hintNonBlack = true;
    }
    if (dead == true) anyDead = true;
    if (seen == true && awaiting != false) closedAfterTrack = false;
    rows.add(
      '$t,player=$hasPlayer,awaiting=$awaiting,seen=$seen,settled=$settled,'
      'dead=$dead,loading=$loading,colors=${r.$1},center=${r.$2.toStringAsFixed(1)},${r.$3}x${r.$4}',
    );
    say(rows.last);
    if (seen == true && t > 6000) break;
    final spent = sw.elapsedMilliseconds - t;
    if (spent < 500) await Future<void>.delayed(Duration(milliseconds: 500 - spent));
  }
  final lines = <String>[
    'source=$_slowSource',
    'sawAwaiting=$sawAwaiting',
    'sawAwaitingWithHint=$sawAwaitingWithHint',
    'hintNonBlack=$hintNonBlack',
    'anyDead=$anyDead',
    'closedAfterTrack=$closedAfterTrack',
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
  exit(0);
}
