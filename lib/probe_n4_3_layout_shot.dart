// ═══════════════════════════════════════════════════════════════════════
//  N4-3 根布局取证探针 —— 弹幕搜索页在**真机 release** 下的版面截图
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么用探针而不是截桌面
// ```text
// ❌ CopyFromScreen —— 抓的是桌面像素（2026-10-18 事故），还会把本机窗口拍进去；
// ✅ 进程内 `RenderRepaintBoundary.toImage()` ⇒ 一定是产品自身的渲染结果。
// ✅ 合成信号一律进程内造（不点鼠标、不抢焦点）—— 本探针只"画"和"拍"，不模拟输入。
// ```
//
// # 它产出什么
// ```text
// .probe/n4-3-layout/n4-3-<场景>.png   （由 cwd 相对拼接，不写本机绝对路径）
// 场景 = 宽窗（1280x800）/ 窄窗（900x640）+ 有结果 / 空结果
// ⇒ 用来做"改动前"的版面基线：信息密度、层级、可点区、空态占位。
// ```
//
// # 它**不**判断什么
// ```text
// 不判断"好不好看"（那是 Owner 的观感）；只固定"现在长什么样"，
// 好让后续任何布局改动都能同倍率对比（计划里 N4-3 的验收方式就是截图对照）。
// ```

import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:material_ui/material_ui.dart';

import 'core/danmaku.dart';
import 'ui/danmaku_search_page.dart';
import 'ui/widgets/bili_import_dialog.dart';
import 'ui/widgets/danmaku_settings_dialog.dart';

final GlobalKey _shotKey = GlobalKey();
Directory? _outDir;

void _say(String s) {
  // ignore: avoid_print
  print('[N4-3] $s');
}

Future<void> _settle(int ms) async {
  for (var i = 0; i < 3; i++) {
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(Duration(milliseconds: ms));
  await WidgetsBinding.instance.endOfFrame;
}

Future<void> _shot(String name) async {
  final ro = _shotKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    _say('!! 根不是 RenderRepaintBoundary，跳过 $name');
    return;
  }
  final img = await ro.toImage(pixelRatio: 1.0);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) {
    _say('!! toByteData 返回空（$name）');
    return;
  }
  final f = File('${_outDir!.path}${Platform.pathSeparator}$name.png');
  await f.writeAsBytes(bytes.buffer.asUint8List());
  _say('PNG ${f.path}  ${bytes.lengthInBytes} B  ${img.width}x${img.height}');
}

List<DanmakuMatch> _matches(int n) => List<DanmakuMatch>.generate(
      n,
      (i) => DanmakuMatch(
        episodeId: 1000 + i,
        animeTitle: i.isEven ? '无职转生 第三季' : '葬送的芙莉莲',
        episodeTitle: '第${i + 1}集',
      ),
    );

DanmakuSettingsState _state({required bool withResults, bool stale = false}) =>
    DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1,
      opacity: 1,
      speed: 1,
      area: 1,
      searchSearched: withResults,
      searchStale: stale,
      searchResults: withResults ? _matches(6) : const <DanmakuMatch>[],
    );

Widget _page({required bool withResults, required bool stale}) => MaterialApp(
      debugShowCheckedModeBanner: false,
      home: DanmakuSearchPage(
        state: _state(withResults: withResults, stale: stale),
        biliState: const BiliImportState(),
        localTitles: const <String>['第1集', '第2集', '第3集'],
        // N4-3 #1 之后：宿主会传作品名 —— 探针也照传，否则拍出来的顶栏不是真实形态
        workTitle: '某部示例作品（第三季）',
        onSearch: (_) {},
        onBiliSearch: (_) {},
        onPickMatch: (_) {},
        onBatchBind: (_) {},
        onBiliImport: (_) {},
        onBiliSelectPage: (_) {},
        onClose: () {},
      ),
    );

Future<void> _render(Widget page, Size size, String name) async {
  runApp(
    RepaintBoundary(
      key: _shotKey,
      child: SizedBox(
        width: size.width,
        height: size.height,
        child: page,
      ),
    ),
  );
  await _settle(320);
  await _shot(name);
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _outDir = Directory(
    '${Directory.current.path}${Platform.pathSeparator}.probe'
    '${Platform.pathSeparator}n4-3-layout',
  );
  await _outDir!.create(recursive: true);
  _say('产物目录=${_outDir!.path}');

  const wide = Size(1280, 800);
  const narrow = Size(900, 640);

  await _render(_page(withResults: true, stale: false), wide, 'n4-3-wide-results');
  await _render(_page(withResults: true, stale: true), wide, 'n4-3-wide-stale');
  await _render(_page(withResults: false, stale: false), wide, 'n4-3-wide-empty');
  await _render(_page(withResults: true, stale: false), narrow, 'n4-3-narrow-results');

  _say('DONE');
  exit(0);
}
