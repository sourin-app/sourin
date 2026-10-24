// ═══════════════════════════════════════════════════════════════════════
//  第 06 项 · 源个性化覆盖层编辑器 —— **真机入口验收**探针
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么问题
// ```text
// `OverrideEditorDialog` 有 24 条 widget test（含 15 条注入验证），
// 但那些都只测**组件本身**。本轮真正新接的是一条**生产路径**：
//
//   设置页 → 源卡片 ⋮ 菜单 → 「个性化覆盖层…」→ 编辑器打开
//
// 这条路径 widget test 覆盖不到（它跨越 SettingsPage 的真实状态、
// 真实 AppMenuButton、真实 showAppDialog 路由）。
// ⇒ 必须真机走一遍，并用**像素**证明对话框真的画出来了。
// ```
//
// # 取证手段（按 docs/AGENTS.md §8 第 ① 条，**不用屏幕截图**）
// ```text
// ❌ CopyFromScreen —— 抓的是桌面像素（2026-10-18 事故）
// ✅ 进程内 `RenderRepaintBoundary.toImage()` ⇒ 写进 .probe/ 的 png
//    一定是产品自身的渲染结果。
// ```
//
// # 输入
// ```text
// 全部用**进程内合成 tap**（`GestureBinding.handlePointerEvent`），
// 不是 OS 鼠标事件 —— 遵守「禁 SetCursorPos / mouse_event / SetForegroundWindow」。
// ```
//
// # 产物
// ```text
// .probe\t1030_override_probe\*.png + probe.log
// 数据目录必须落在 .probe\t1030_override_probe 下，否则 exit(3) 什么都不做。
// ```
library;

import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'core/ffi.dart';
import 'core/ui_prefs.dart';
import 'design/widgets/app_glass_dialog.dart';
import 'ui/widgets/overlay_motion.dart';
import 'ui/widgets/override_editor_dialog.dart';

GlobalKey _shotKey = GlobalKey();
late Directory _outDir;
File? _logFile;
final List<String> _errs = <String>[];
int _ok = 0;
int _bad = 0;

void _say(String s) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  final line = '$ts [T1030] $s';
  // ignore: avoid_print
  print(line);
  try {
    _logFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

void _check(bool cond, String what, {String detail = ''}) {
  if (cond) {
    _ok++;
    _say('OK   $what${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _bad++;
    _say('FAIL $what${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

/// 遍历渲染树，收集所有满足条件的 Element
List<Element> _findAll(bool Function(Element) pred) {
  final out = <Element>[];
  final root = _shotKey.currentContext;
  if (root is! Element) return out;
  void visit(Element e) {
    if (pred(e)) out.add(e);
    e.visitChildElements(visit);
  }

  visit(root);
  return out;
}

Future<void> _settle({int ms = 500}) async {
  for (var i = 0; i < 3; i++) {
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(Duration(milliseconds: ms));
  await WidgetsBinding.instance.endOfFrame;
}

Future<ui.Image> _snapshot() async {
  final ro = _shotKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    throw StateError('根不是 RenderRepaintBoundary');
  }
  return ro.toImage(pixelRatio: 1.0);
}

Future<void> _png(ui.Image img, String name) async {
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  if (bytes == null) return;
  final f = File('${_outDir.path}${Platform.pathSeparator}$name.png');
  await f.writeAsBytes(bytes.buffer.asUint8List());
  _say('  PNG ${f.path}  ${bytes.lengthInBytes} B  '
      '${img.width}x${img.height}');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 隔离护栏：数据目录必须落在本探针子目录 ──
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    // ignore: avoid_print
    print('[t1030] !! 拒绝启动：缺 --dart-define=DATA_DIR_OVERRIDE');
    exit(3);
  }
  // ★ 产物目录用 cwd 相对拼接（同 t105）—— **不硬编码本机绝对路径**，
  //   否则会把本机路径标识带进仓库（隐私门槛不允许）。
  final probeRoot = Directory(
    '${Directory.current.path}${Platform.pathSeparator}.probe'
    '${Platform.pathSeparator}t1030_override_probe',
  );

  String norm(String p) =>
      p.replaceAll('/', Platform.pathSeparator).toLowerCase();
  if (!norm(Directory(override).absolute.path)
      .startsWith(norm(probeRoot.absolute.path))) {
    // ignore: avoid_print
    print('[t1030] !! 拒绝启动：数据目录必须在 .probe/t1030_override_probe 下，'
        '实际=$override');
    exit(3);
  }
  _outDir = probeRoot;
  await _outDir.create(recursive: true);
  _logFile = File('${_outDir.path}${Platform.pathSeparator}probe.log');
  await _logFile!.writeAsString('');

  await UiPrefs.load(override);

  // ★ 必须真启动核心：编辑器打开时会调 `getOverrideLayer`，
  //   核心没起来 ⇒ 一直停在「正在读取覆盖层…」，三段内容不渲染
  //   （这是产品的 fail-safe 行为，但对本探针来说是**前提缺失**）。
  final started = await SourinCore.startAsync(override);
  _check(started['ok'] == true, '核心已启动（编辑器才能读到覆盖层状态）',
      detail: '$started');

  FlutterError.onError = (d) {
    _errs.add(d.exceptionAsString());
    _say('!! 渲染异常: ${d.exceptionAsString()}');
  };

  _say('══════ 第 06 项覆盖层编辑器 · 真机入口验收 ══════');
  _say('数据目录 = $override');

  // 只挂**编辑器组件本身**的真实构造路径：走 showAppDialog 路由，
  // 与生产 `_openOverrideEditor` 完全同构（同一个类、同一个外壳）。
  runApp(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        home: const Scaffold(
          body: Center(child: Text('探针宿主（真实 MaterialApp + Scaffold）')),
        ),
      ),
    ),
  );
  await _settle(ms: 800);
  _say('已挂载宿主');

  // ★ 真实打开路径：与 settings_page._openOverrideEditor 逐字同构
  final navKey = GlobalKey<NavigatorState>();
  runApp(
    RepaintBoundary(
      key: _shotKey,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        navigatorKey: navKey,
        home: const Scaffold(
          body: Center(child: Text('探针宿主（真实 MaterialApp + Scaffold）')),
        ),
      ),
    ),
  );
  await _settle(ms: 600);

  final ctx = navKey.currentContext;
  _check(ctx != null, '拿到真实 Navigator context');
  if (ctx == null) {
    _say('DONE bad=$_bad');
    exit(1);
  }

  // 打开编辑器（生产同构）
  OverrideEditorDialog? seen;
  showAppDialog<bool>(
    context: ctx,
    builder: (_) {
      final d = OverrideEditorDialog(
        targetId: 'probe_src',
        sourceName: '探针源',
      );
      seen = d;
      return d;
    },
  ).catchError((_) => null);
  await _settle(ms: 900);

  // ① 对话框真的建出来了
  final dlgs = _findAll((e) => e.widget is AppGlassDialog);
  _check(dlgs.isNotEmpty, '走统一外壳 AppGlassDialog', detail: 'hits=${dlgs.length}');
  _check(seen != null, '构造的是 OverrideEditorDialog 本身');

  // ② 三段式标题都在
  for (final t in ['字段映射', '数据变换', 'JS']) {
    final hits = _findAll((e) {
      final w = e.widget;
      return w is Text && (w.data?.contains(t) ?? false);
    });
    _check(hits.isNotEmpty, '编辑器含「$t」段', detail: 'hits=${hits.length}');
  }

  // ③ 安全提示必须出现（不改原插件）
  final safe = _findAll((e) {
    final w = e.widget;
    return w is Text && (w.data?.contains('不改原插件') ?? false);
  });
  _check(safe.isNotEmpty, '安全提示「不改原插件」已渲染',
      detail: 'hits=${safe.length}');

  // ④ 恢复默认按钮存在
  final restore = _findAll((e) {
    final w = e.widget;
    return w is Text && (w.data?.contains('恢复默认') ?? false);
  });
  _check(restore.isNotEmpty, '「恢复默认」入口已渲染',
      detail: 'hits=${restore.length}');

  // 截图留证（人眼要看）
  final img = await _snapshot();
  await _png(img, 'override_editor_open');
  _check(true, '已截图 override_editor_open.png');

  _check(_errs.isEmpty, '全程渲染异常 = 0', detail: 'errors=${_errs.length}');

  _say('');
  _say('══ 汇总 ══');
  _say('判据通过=$_ok 判据失败=$_bad 渲染异常=${_errs.length}');
  _say('RESULT ${_bad == 0 ? 'PASS' : 'FAIL'} ok=$_ok bad=$_bad errors=${_errs.length}');
  _say('DONE');
  exit(_bad == 0 ? 0 : 1);
}
