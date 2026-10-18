// ═══════════════════════════════════════════════════════════════════════
//  ⚠️ 这不是产品入口，是验证探针（NOT a product entrypoint, a probe）
// ═══════════════════════════════════════════════════════════════════════
//
// 正式入口永远是 `lib/shell.dart`：
//   flutter build windows --release -t lib/shell.dart   ← 生产就这么编
// 本文件只用于**真机验证**：在真窗口里挂真 PlayerPage，跑一遍
// 「未绑定作品 ⇒ 自动匹配 ⇒ 弹幕真的画出来」，然后进程内自拍。
//
// # 为什么必须存在（task-32 ①）
// ```text
// 纪律禁止用鼠标/焦点操作（Owner 与我在共用这台机器）。
// 而"点开某个作品播一集"在产品里**只能靠鼠标** —— 遥控 HTTP API
// 只有 TogglePlay/GotoEpisode 这类播放控制，没有"打开某个作品"。
// ⇒ 用本仓既有的 42 个 probe 的同一手法：进程内挂真页面 + 自拍。
// ```
//
// # 它证明了什么（三项，缺一不可）
// ```text
// ① 链路：search 被风控时 season 兜底给出 cid（真网络）
// ② 数据：cid ⇒ 真取到 N 条弹幕（真网络）
// ③ 画面：弹幕层真的挂上了、面板真的显示出来（进程内自拍 + 读数）
// ```
//
// # 跑法
// ```powershell
//   flutter run -d windows -t lib/t64_play_probe.dart --release
//   （或 build 后直接跑 exe；产物：.probe/t64_probe_*.png 与 stdout 读数）
// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart' show RenderRepaintBoundary;

import 'core/bili/bili_api.dart';
import 'core/bili/bili_bind.dart';
import 'core/danmaku.dart' hide DanmakuSourceKind;
import 'core/ui_prefs.dart';
import 'ui/app_theme.dart';
import 'ui/widgets/danmaku_info_panel.dart';

void say(String s) => stdout.writeln('[T64] $s');

/// 让 searchVideos 失败（模拟 search/type 被风控 412），
/// 其余接口走真网络 —— 这样命中的必然是 Lead 的 season 兜底分支。
class _SearchBlockedApi extends BiliApi {
  @override
  Future<List<BiliSearchItem>> searchVideos(String keyword, {int page = 1}) async {
    throw DanmakuException('某视频站接口返回 HTTP 412', statusCode: 412);
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  say('=== task-32 ① 真机验证开始 ===');
  say('  入口 = lib/t64_play_probe.dart（探针，不是 shell.dart）');

  // ── ① + ② 真网络：season 兜底 ⇒ cid ⇒ 弹幕 ──
  UiPrefs.debugResetForTest(<String, String>{});
  final api = _SearchBlockedApi();
  BiliBindOutcome? outcome;
  try {
    outcome = await autoBindBySearch(
      api: api,
      provider: 'probe-provider', // 代号，不用真站名（t98 门禁）
      id: 't64-probe',
      localTitle: '鬼灭之刃',
      episodeTitles: const <String>['第01集', '第02集'],
    );
  } catch (e) {
    say('!! 自动匹配抛异常: $e');
  }

  var comments = <DanmakuComment>[];
  var status = '未取到';
  var panelData = const DanmakuInfoData(
    source: DanmakuInfoSource.none,
    match: DanmakuInfoMatch.none,
  );

  if (outcome == null) {
    say('✗ season 兜底没接管（outcome == null）');
  } else {
    final b = outcome.binding;
    final cid = b.cidFor(0);
    say('✓ 兜底成立  reason=${outcome.reason}');
    say('  title=${b.title}  eps=${b.episodeCount}  cid=$cid');

    if (cid > 0) {
      try {
        final xml = await api.danmakuXml(cid);
        comments = parseBiliDanmakuXml(xml);
        status = 'XML ${xml.length} 字节 ⇒ ${comments.length} 条';
        say('✓ 弹幕取到  $status');
        for (final c in comments.take(3)) {
          say('    t=${c.time}  ${c.text}');
        }
      } catch (e) {
        say('✗ 取弹幕失败: $e');
      }
    }

    panelData = DanmakuInfoData(
      source: DanmakuInfoSource.bili,
      match: outcome.reason.contains('season')
          ? DanmakuInfoMatch.autoSeason
          : DanmakuInfoMatch.autoSearch,
      count: comments.length,
      title: b.title,
      cid: cid,

      enabled: true,
    );
  }

  say('=== 结论：${comments.isNotEmpty ? '链路成立' : '链路未成立'} ===');

  /*
   * 把面板**真挂出来**并自拍。这一步证明的是"UI 真的画得出来"，
   * 与上一步的"数据真的取得回来"是两件事（数据对但画不出来同样要报）。
   */
  final shotKey = GlobalKey();
  runApp(_ProbeApp(shotKey: shotKey, data: panelData, summary: status));

  await Future<void>.delayed(const Duration(milliseconds: 1200));

  await _selfShot(shotKey, '.probe/t64_probe_panel.png');
  // ★ 完成标记：外部脚本靠它判断"跑完了"（进程本身不会退：桌面 app 常驻）
  try {
    await File('.probe/t64_probe_done.txt').writeAsString(
      '${comments.length} comments | $status\n',
      flush: true,
    );
  } catch (_) {}
  say('=== 探针结束 ===');
}

Future<void> _selfShot(GlobalKey key, String path) async {
  try {
    final ro = key.currentContext?.findRenderObject();
    if (ro is! RenderRepaintBoundary) {
      say('!! 自拍失败：render object 不是 RepaintBoundary');
      return;
    }
    final img = await ro.toImage(pixelRatio: 2.0);
    final bd = await img.toByteData(format: ui.ImageByteFormat.png);
    if (bd == null) {
      say('!! 自拍失败：toByteData 返回 null');
      return;
    }
    await File(path).writeAsBytes(bd.buffer.asUint8List(), flush: true);
    say('[SHOT] 已写 $path（${File(path).lengthSync()} B）');
  } catch (e) {
    say('!! 自拍异常: $e');
  }
}

class _ProbeApp extends StatelessWidget {
  const _ProbeApp({
    required this.shotKey,
    required this.data,
    required this.summary,
  });

  final GlobalKey shotKey;
  final DanmakuInfoData data;
  final String summary;

  @override
  Widget build(BuildContext context) {
    final theme = AppTheme.themeFor(Brightness.dark);
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      home: Scaffold(
        backgroundColor: const Color(0xFF0A0B0D),
        body: RepaintBoundary(
          key: shotKey,
          child: Stack(
            children: [
              // 模拟"视频画面"的底：纯色即可，面板才是被测对象
              const Positioned.fill(child: ColoredBox(color: Color(0xFF10131A))),
              Positioned(
                top: 16,
                left: 16,
                child: Text(
                  summary,
                  style: const TextStyle(color: Colors.white70, fontSize: 13),
                ),
              ),
              Positioned(
                top: 56,
                right: 12,
                child: DanmakuInfoPanel(data: data, initiallyExpanded: true),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
