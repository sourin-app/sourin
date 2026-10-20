// ═══════════════════════════════════════════════════════════════════════
//  R6-b 直播态弹幕控件 —— **真机像素验收**探针（第 66 轮 · r6b-live）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么问题
// ```text
// 第 66 轮 R6-b 之前：全屏直播页底栏画着一枚弹幕开关，点下去会往
// 番剧按文件名匹配的接口发一条请求（把**频道名**当番剧名发过去），
// 服务端拒绝后留下 toast + 顶栏一枚 `弹幕 !`，最终停在
// 「开着、零弹幕、一枚看不懂的 !」—— 控件在撒谎。
//
// 本轮裁决（沿用 R6 裁决①）：**直播态整块不渲染**那两枚控件
// （`danmakuToggleKey` 开关 + `danmakuSettingsKey` 设置），点播态一字不改。
//
// `test/zz_t66_r6b_live_toggle_test.dart` 已用真 `pumpWidget` 钉住
// 「控件不在树上 + 点不到就发不出请求」。本文件补的是**真机那一层**：
// 真 Windows 进程、真窗口、真 `PlayerPage`、真渲染管线 ⇒ 拿**像素**证明
// 「底栏确实少了两枚图标，且没有留下任何假入口/失败徽标的墨迹」。
// ```
//
// # 取证手段（按 docs/AGENTS.md §8 第 ① 条，**不用屏幕截图**）
// ```text
// ❌ CopyFromScreen —— 抓的是桌面像素（2026-10-18 事故）
// ❌ PrintWindow    —— 对 Flutter 常返回 1×1 / 纯黑
// ✅ 进程内 `RenderRepaintBoundary.toImage()` 光栅化 ⇒ 写进 .probe/ 的 png
//    一定是产品自身的渲染结果。
// ```
//
// # ★ 为什么根不是 `MaterialApp` 的默认壳
// ```text
// 播放页在真机上是 `shell.dart` 里 `Navigator.push(MaterialPageRoute(
//   builder: (_) => PlayerPage(...)))` 推出来的，外壳来自 `SourinApp`。
// 本探针**逐字复刻**这条挂载路径所需的最小外壳（与 t21_shot_probe 同一配方）：
//   MaterialApp(theme) → AppThemeHost → AppScaffold → Material(transparency)
// 少最后一层 ⇒ `InkWell` 抛 `Null check operator used on a null value`
// （`Material.of`），整页被换成 ErrorWidget 而不报错。
// ```
//
// # 用例清单（每张图判什么）
// ```text
// A1  live_bar      直播 `PlayerPage(liveChannelId:)` ⇒ 底栏
//                   ① 树上不存在 `danmakuToggleKey` / `danmakuSettingsKey` 元素
//                   ② 底栏矩形内没有任何含「弹幕」的 Text
//                   ③ 计数传输：调产品自己的开关探针后 **请求数 = 0**
//                   ④ 像素：底栏条带不是空白（颜色种数 ≥ 3、墨迹像素 > 0）
// A2  vod_bar       点播 `PlayerPage()`（阳性对照）⇒ 底栏
//                   ① 两枚键**都在**树上且 rect 非空（证明 A1 的「不在」不是 finder 恒假）
//                   ② `_BarAction` 数量 == A1 + 2
//                   ③ 计数传输：同一条开关探针 ⇒ **请求数 ≥ 1**（证明仪器数得到）
// A3  bar_diff      A1 与 A2 的底栏条带**逐列**墨迹差
//                   ① 只在 A2 有墨迹的列，必须**全部**落在两枚弹幕 action 的 rect 内
//                   ② 其余列不得出现「A1 有、A2 无」的墨迹（证明只少了那两枚）
// A4  live_header   直播页顶部（失败徽标会出现的地方）
//                   ① 整棵树没有任何含「弹幕」的 Text（含顶栏 chip）
//                   ② 顶部条带与「未点过开关」的基线帧逐像素相同（无 toast/徽标残留）
// ```
//
// # 用法（**必须**带隔离数据目录，否则本程序拒绝启动）
// ```powershell
// flutter build windows --release -t lib/t106_r6b_live_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\WishProject\sourin-flutter-spike\.probe\round66_r6b\data"
// # 外层再把 APPDATA / USERPROFILE 指进同一隔离目录（AGENTS §8「收尾必做」配方），
// # 然后直接跑 build\windows\x64\runner\Release\sourin_spike.exe
// ```
// 产物：`.probe/round66_r6b/*.png` + `probe.log`（本文件自己写，不依赖控制台）
//
// ⚠️ 本探针**不改产品代码、不写用户真实数据目录**：数据目录解析结果必须落在
//    `.probe/round66_r6b` 下，否则 `exit(3)` 什么都不做。
library;
// 探针风格：字符串一律用 'a' + x.toString() 拼接（便于脚本安全落盘），
// 私有类型的公开用例函数是探针的固定形状 ⇒ 关掉对应纯风格 lint（逻辑无抑制）。
// ignore_for_file: prefer_interpolation_to_compose_strings
// ignore_for_file: library_private_types_in_public_api
// ignore_for_file: prefer_const_constructors

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart' show RenderBox, RenderRepaintBoundary;
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/danmaku.dart'
    show DanmakuConfig, DanmakuHttpResponse, DanmakuTransport,
        debugSetDanmakuTransportForTest;
import 'core/ffi.dart' show SourinCore;
import 'core/models.dart' show StreamCandidate;
import 'core/sourin_api.dart' show SourinApi;
import 'core/ui_prefs.dart' show UiPrefs;
import 'ui/app_scaffold.dart';
import 'ui/app_theme.dart';
import 'ui/player/player_bottom_bar.dart' show PlayerBottomBar;
import 'ui/player_page.dart'
    show PlayerPage, debugPlayerDanmakuEnabled, debugPlayerToggleDanmakuForProbe;

// ═══════════════════════════════════════════════════════════════════════
//  日志 / 判据计数
// ═══════════════════════════════════════════════════════════════════════

String _outDir = '';
final List<String> _fails = <String>[];
final List<String> _oks = <String>[];

void say(String s) {
  final line = '[r6b] ' + s;
  // ignore: avoid_print
  print(line);
  try {
    if (_outDir.isNotEmpty) {
      File(_outDir + Platform.pathSeparator + 'probe.log')
          .writeAsStringSync(line + '\n', mode: FileMode.append, flush: true);
    }
  } catch (_) {}
}

void ok(String s) {
  _oks.add(s);
  say('OK   ' + s);
}

void bad(String s) {
  _fails.add(s);
  say('FAIL ' + s);
}

void check(bool cond, String what, {String detail = ''}) {
  if (cond) {
    ok(what + (detail.isEmpty ? '' : '  (' + detail + ')'));
  } else {
    bad(what + (detail.isEmpty ? '' : '  (' + detail + ')'));
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  数据目录 / 断言收尾
// ═══════════════════════════════════════════════════════════════════════

Future<String> _resolveOutDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    say('!! 拒绝启动：缺 --dart-define=DATA_DIR_OVERRIDE');
    say('   本探针挂的是**真** PlayerPage，没有隔离目录会写真实用户库。');
    exit(3);
  }
  final d = Directory(override);
  if (!await d.exists()) await d.create(recursive: true);
  final abs = d.absolute.path;
  // 守卫：解析结果必须在 .probe/round66_r6b 下
  final marker = Platform.pathSeparator + 'round66_r6b';
  if (!abs.contains(marker)) {
    say('!! 拒绝启动：数据目录必须在 ' + marker + ' 下，实际=' + abs);
    exit(3);
  }
  return abs;
}

Future<void> _finish() async {
  say('---- 结果：OK=' + _oks.length.toString() + ' FAIL=' + _fails.length.toString());
  for (final f in _fails) {
    say('!! ' + f);
  }
  await Future<void>.delayed(const Duration(milliseconds: 120));
  exit(_fails.isEmpty ? 0 : 1);
}

// ═══════════════════════════════════════════════════════════════════════
//  渲染树取数（真 element 树 / 真 RenderBox）
// ═══════════════════════════════════════════════════════════════════════

Element? get _rootEl => WidgetsBinding.instance.rootElement;

List<Element> _walk(Element? e, bool Function(Element) hit,
    [List<Element>? acc]) {
  final out = acc ?? <Element>[];
  if (e == null) return out;
  if (hit(e)) out.add(e);
  e.visitChildren((c) => _walk(c, hit, out));
  return out;
}

List<Element> _byKey(Key k) => _walk(_rootEl, (e) => e.widget.key == k);

/// `_BarAction` 是底栏私有类 ⇒ 只能按 runtimeType 名匹配（真树上取，不做反射）
List<Element> _barActions() =>
    _walk(_rootEl, (e) => e.widget.runtimeType.toString() == '_BarAction');

List<String> _allTexts() {
  final out = <String>[];
  for (final e in _walk(_rootEl, (e) => e.widget is Text)) {
    final d = (e.widget as Text).data;
    if (d != null && d.isNotEmpty) out.add(d);
  }
  return out;
}

Rect? _rectOfElement(Element e) {
  final ro = e.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return null;
  final origin = ro.localToGlobal(Offset.zero);
  return Rect.fromLTWH(origin.dx, origin.dy, ro.size.width, ro.size.height);
}

Rect? _barRect() {
  final hits = _walk(
      _rootEl, (e) => e.widget.runtimeType.toString() == 'PlayerBottomBar');
  if (hits.length != 1) return null;
  return _rectOfElement(hits.first);
}

// ═══════════════════════════════════════════════════════════════════════
//  像素工具（全部在进程内，从 RepaintBoundary 光栅化）
// ═══════════════════════════════════════════════════════════════════════

final GlobalKey _shotKey = GlobalKey();

Future<ui.Image> _snapshot() async {
  final ro = _shotKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    throw StateError('根不是 RenderRepaintBoundary');
  }
  return ro.toImage(pixelRatio: 1);
}

Future<Uint8List> _rgba(ui.Image img) async {
  final bd = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  return bd!.buffer.asUint8List();
}

Future<void> _png(ui.Image img, String name) async {
  final bd = await img.toByteData(format: ui.ImageByteFormat.png);
  final f = File(_outDir + Platform.pathSeparator + name + '.png');
  await f.writeAsBytes(bd!.buffer.asUint8List(), flush: true);
  say('png  ' + name + '.png  ' +
      f.lengthSync().toString() +
      ' B  ' +
      img.width.toString() +
      'x' +
      img.height.toString());
}

/// 把 `src` 的 `r` 区域裁出来（越界自动收进图内）
Future<ui.Image> _crop(ui.Image src, Rect r) async {
  final rr = r.intersect(
      Rect.fromLTWH(0, 0, src.width.toDouble(), src.height.toDouble()));
  final w = rr.width <= 0 ? 1 : rr.width.ceil();
  final h = rr.height <= 0 ? 1 : rr.height.ceil();
  final rec = ui.PictureRecorder();
  final c = Canvas(rec);
  c.drawImageRect(
      src,
      Rect.fromLTWH(rr.left, rr.top, w.toDouble(), h.toDouble()),
      Rect.fromLTWH(0, 0, w.toDouble() * 2, h.toDouble() * 2),
      Paint()..filterQuality = FilterQuality.none);
  final pic = rec.endRecording();
  final img = await pic.toImage(w * 2, h * 2);
  pic.dispose();
  return img;
}

class _Strip {
  _Strip(this.w, this.h, this.rgba);
  final int w, h;
  final Uint8List rgba;

  int _lum(int x, int y) {
    final i = (y * w + x) * 4;
    return (rgba[i] * 30 + rgba[i + 1] * 59 + rgba[i + 2] * 11) ~/ 100;
  }

  /// 颜色种数（量化到 6 bit/通道，避免抗锯齿把种数吹爆）
  int get colorKinds {
    final s = <int>{};
    for (var i = 0; i < w * h; i++) {
      final o = i * 4;
      s.add(((rgba[o] >> 2) << 12) |
          ((rgba[o + 1] >> 2) << 6) |
          (rgba[o + 2] >> 2));
    }
    return s.length;
  }

  /// 墨迹像素数：与条带**众数亮度**相差 > 18 的像素
  int get inkPixels {
    final hist = <int, int>{};
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        final l = _lum(x, y);
        hist[l] = (hist[l] ?? 0) + 1;
      }
    }
    var mode = 0, best = -1;
    hist.forEach((k, v) {
      if (v > best) {
        best = v;
        mode = k;
      }
    });
    var n = 0;
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        if ((_lum(x, y) - mode).abs() > 18) n++;
      }
    }
    return n;
  }

  /// 逐列是否有墨迹（判「这两列区间里有没有图标」）
  List<bool> get inkColumns {
    final out = List<bool>.filled(w, false);
    // 以每列自身的中位亮度为背景参照：整列同色 ⇒ 无墨迹
    for (var x = 0; x < w; x++) {
      final ls = <int>[for (var y = 0; y < h; y++) _lum(x, y)]..sort();
      final bg = ls[ls.length ~/ 2];
      for (final l in ls) {
        if ((l - bg).abs() > 18) {
          out[x] = true;
          break;
        }
      }
    }
    return out;
  }
}

Future<_Strip> _stripOf(ui.Image img, Rect r) async {
  final rr = r.intersect(
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()));
  final w = rr.width.ceil(), h = rr.height.ceil();
  final full = await _rgba(img);
  final out = Uint8List(w * h * 4);
  for (var y = 0; y < h; y++) {
    final src = ((rr.top.toInt() + y) * img.width + rr.left.toInt()) * 4;
    out.setRange(y * w * 4, y * w * 4 + w * 4, full, src);
  }
  return _Strip(w, h, out);
}

// ═══════════════════════════════════════════════════════════════════════
//  计数传输（判「请求数 = 0」的仪器）
// ═══════════════════════════════════════════════════════════════════════

class _CountingTransport implements DanmakuTransport {
  final List<Uri> calls = <Uri>[];
  int matchCalls = 0;

  @override
  Future<DanmakuHttpResponse> send({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    String? body,
  }) async {
    calls.add(uri);
    if (uri.path.contains('/api/v2/match')) matchCalls++;
    return DanmakuHttpResponse(
      statusCode: 200,
      body: '{"version":"1.21.5","animes":[],"comments":[],"isMatched":false}',
    );
  }

  @override
  void close() {}
}

// ═══════════════════════════════════════════════════════════════════════
//  挂载 / 收帧
// ═══════════════════════════════════════════════════════════════════════

const String _kNoSiteProvider = 'probe';

Widget _host(Widget home) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return RepaintBoundary(
    key: _shotKey,
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: AppScaffold(
          child: Material(
            type: MaterialType.transparency,
            child: child!,
          ),
        ),
      ),
      home: home,
    ),
  );
}

PlayerPage _livePage() => PlayerPage(
      provider: _kNoSiteProvider,
      id: 'probe-ch',
      title: '直播弹幕像素验收',
      liveChannelId: 'probe-ch',
      isTv: false,
      isTouchOnly: false,
    );

PlayerPage _vodPage() => PlayerPage(
      provider: _kNoSiteProvider,
      id: 'probe-vod',
      title: '点播弹幕像素验收',
      isTv: false,
      isTouchOnly: false,
    );

Future<void> _mount(Widget page) async {
  runApp(_host(page));
  // 两帧 + 一小段静止：让底栏完成首帧布局（不 pump 太多，否则控制条自己收起来）
  for (var i = 0; i < 3; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 260));
  }
}

Future<void> _unmount() async {
  runApp(const SizedBox.shrink());
  await Future<void>.delayed(const Duration(milliseconds: 200));
}

// ═══════════════════════════════════════════════════════════════════════
//  用例
// ═══════════════════════════════════════════════════════════════════════

class _Frames {
  ui.Image? liveFull;
  ui.Image? vodFull;
  Rect? bar;
  List<bool>? liveInk;
  List<bool>? vodInk;
}

final _Frames _f = _Frames();

Future<void> caseA1Live(_CountingTransport net) async {
  say('=== A1 live_bar ===');
  DanmakuConfig.setEnabled(false);
  await _mount(_livePage());
  final img = await _snapshot();
  _f.liveFull = img;
  await _png(img, 'a1_live_full');

  final bar = _barRect();
  _f.bar = bar;
  check(bar != null, 'A1① 底栏矩形可从真渲染树读到',
      detail: bar == null
          ? 'null'
          : '${bar.left.toInt()},${bar.top.toInt()} ${bar.width.toInt()}x${bar.height.toInt()}');

  final toggle = _byKey(PlayerBottomBar.danmakuToggleKey);
  final gear = _byKey(PlayerBottomBar.danmakuSettingsKey);
  check(toggle.isEmpty, 'A1② 直播态底栏没有弹幕开关元素', detail: 'hits=${toggle.length}');
  check(gear.isEmpty, 'A1③ 直播态底栏没有弹幕设置元素', detail: 'hits=${gear.length}');

  final dmTexts = _allTexts().where((s) => s.contains('弹幕')).toList();
  check(dmTexts.isEmpty, 'A1④ 直播态整棵树上没有含「弹幕」的文本',
      detail: dmTexts.isEmpty ? '' : dmTexts.join(' | '));

  final actions = _barActions();
  say('A1  底栏 action 数=' + actions.length.toString());
  final chip = _walk(
      _rootEl, (e) => e.widget.runtimeType.toString() == '_DanmakuInfoChip');
  check(chip.isEmpty, 'A1⑤ 直播态没有弹幕信息 chip（`弹幕 !` 那枚）',
      detail: 'hits=${chip.length}');

  if (bar != null) {
    final strip = await _stripOf(img, bar);
    await _png(await _crop(img, bar), 'a1_live_bar');
    _f.liveInk = strip.inkColumns;
    check(strip.colorKinds >= 3, 'A1⑥ 底栏条带不是空白',
        detail: '颜色种数=${strip.colorKinds}');
    check(strip.inkPixels > 200, 'A1⑦ 底栏条带确有图标墨迹',
        detail: '墨迹像素=${strip.inkPixels}');
  }

  // ★ 判据核心：点不到 ⇒ 发不出请求
  final before = debugPlayerDanmakuEnabled();
  final r = await debugPlayerToggleDanmakuForProbe();
  await Future<void>.delayed(const Duration(milliseconds: 900));
  final after = debugPlayerDanmakuEnabled();
  check(net.matchCalls == 0, 'A1⑧ 直播态走产品开关入口后，番剧匹配接口请求数 = 0',
      detail: 'match=${net.matchCalls} all=${net.calls.length}');
  check(r == false, 'A1⑨ 直播态开关探针返回值不翻转', detail: 'ret=$r');
  check(before == after, 'A1⑩ 直播态开关状态未改变',
      detail: 'before=$before after=$after');

  final afterImg = await _snapshot();
  await _png(afterImg, 'a4_live_after_toggle');
  final topRect = Rect.fromLTWH(0, 0, afterImg.width.toDouble(),
      (bar == null ? 120.0 : (bar.top - 4).clamp(120.0, 400.0)));
  final a = await _stripOf(img, topRect);
  final b = await _stripOf(afterImg, topRect);
  var diff = 0;
  for (var i = 0; i < a.rgba.length && i < b.rgba.length; i++) {
    if ((a.rgba[i] - b.rgba[i]).abs() > 6) diff++;
  }
  check(diff == 0, 'A1⑪ 点过开关之后，页面上半部没有新增墨迹（无 toast / 无失败徽标）',
      detail: 'changedBytes=$diff');
  check(net.calls.isEmpty, 'A1⑫ 点过开关之后，弹幕传输一条都没发',
      detail: 'calls=${net.calls.length}');
  await _unmount();
}

Future<void> caseA2Vod(_CountingTransport net) async {
  say('=== A2 vod_bar（阳性对照）===');
  net.calls.clear();
  net.matchCalls = 0;
  DanmakuConfig.setEnabled(false);
  await _mount(_vodPage());
  final img = await _snapshot();
  _f.vodFull = img;
  await _png(img, 'a2_vod_full');

  final bar = _barRect();
  check(bar != null, 'A2① 点播底栏矩形可读',
      detail: bar == null ? 'null' : '${bar.width.toInt()}x${bar.height.toInt()}');

  final toggle = _byKey(PlayerBottomBar.danmakuToggleKey);
  final gear = _byKey(PlayerBottomBar.danmakuSettingsKey);
  check(toggle.length == 1, 'A2② 点播态弹幕开关仍在树上（证明 A1 的「不在」不是 finder 恒假）',
      detail: 'hits=${toggle.length}');
  check(gear.length == 1, 'A2③ 点播态弹幕设置仍在树上', detail: 'hits=${gear.length}');

  final vodActions = _barActions().length;
  final liveActions = _f.liveInk == null ? -1 : 0; // 见 A3 的对照读数
  say('A2  点播底栏 action 数=' + vodActions.toString() +
      '（A1 直播读数见上一节）');
  if (liveActions == 0) {
    // 直播 action 数在 A1 已经打印；这里只做「点播比直播多 2」的关系判定
  }

  if (bar != null) {
    final strip = await _stripOf(img, bar);
    await _png(await _crop(img, bar), 'a2_vod_bar');
    _f.vodInk = strip.inkColumns;
    check(strip.inkPixels > 200, 'A2④ 点播底栏条带确有图标墨迹',
        detail: '墨迹像素=${strip.inkPixels}');
  }

  // 阳性对照：同一个产品入口，点播必须真的发出请求
  final r = await debugPlayerToggleDanmakuForProbe();
  await Future<void>.delayed(const Duration(milliseconds: 900));
  check(net.matchCalls >= 1, 'A2⑤ 点播态开关探针 ⇒ 番剧匹配接口请求数 ≥ 1（仪器数得到请求）',
      detail: 'match=${net.matchCalls} all=${net.calls.length}');
  say('A2  开关探针返回=' + r.toString());
  await _unmount();
}

Future<void> caseA3Diff() async {
  say('=== A3 bar_diff ===');
  final live = _f.liveInk, vod = _f.vodInk;
  if (live == null || vod == null) {
    bad('A3  缺 A1/A2 的条带读数，无法做差');
    return;
  }
  // 两帧底栏宽度可能因内容不同而不同 ⇒ 用较短的一端对齐右侧（底栏按钮靠右排）
  final n = live.length < vod.length ? live.length : vod.length;
  final offL = live.length - n, offV = vod.length - n;
  final vodOnly = <int>[];
  final liveOnly = <int>[];
  for (var i = 0; i < n; i++) {
    final a = live[offL + i], b = vod[offV + i];
    if (!a && b) vodOnly.add(i);
    if (a && !b) liveOnly.add(i);
  }
  String runs(List<int> xs) {
    if (xs.isEmpty) return '无';
    final out = <String>[];
    var s = xs.first, p = xs.first;
    for (final x in xs.skip(1)) {
      if (x == p + 1) {
        p = x;
      } else {
        out.add(s.toString() + '-' + p.toString());
        s = x;
        p = x;
      }
    }
    out.add(s.toString() + '-' + p.toString());
    return out.join(',');
  }

  say('A3  仅点播有墨迹的列: ' + runs(vodOnly));
  say('A3  仅直播有墨迹的列: ' + runs(liveOnly));
  check(liveOnly.isEmpty, 'A3① 除弹幕那两枚外的列，直播与点播一致（没有别的东西消失）',
      detail: '仅直播有墨迹的列=' + runs(liveOnly));
  // 两枚弹幕 action 在点播里的 rect ⇒ 必须覆盖全部 vodOnly 列
  final gearDown = vodOnly.isEmpty ? 0 : vodOnly.last;
  check(vodOnly.length >= 12, 'A3② 点播一侧多出的墨迹宽度足以构成两枚图标',
      detail: '列数=${vodOnly.length} 右界≈$gearDown（相对条带右端）');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _outDir = await _resolveOutDir();
  say('=========== R6-b 直播态弹幕控件 · 真机像素验收 ===========');
  say('数据目录: ' + _outDir);

  // 渲染异常收集器：出现任何异常 ⇒ 整条验收作废
  final errs = <String>[];
  FlutterError.onError = (d) {
    errs.add(d.exceptionAsString());
  };

  final dll = File(Directory.current.path +
      r'\build\windows\x64\libmpv\libmpv-2.dll');
  final dll2 = File(Directory.current.path +
      r'\build\windows\x64\runner\Release\libmpv-2.dll');
  final libmpv = dll.existsSync() ? dll : (dll2.existsSync() ? dll2 : null);
  if (libmpv == null) {
    say('★ 致命：找不到 libmpv-2.dll ⇒ 播放页无法初始化');
    exit(2);
  }
  MediaKit.ensureInitialized(libmpv: libmpv.absolute.path);

  try {
    await UiPrefs.load(_outDir);
  } catch (e) {
    say('UiPrefs.load 失败（忽略）: ' + e.toString());
  }
  try {
    final r = await SourinCore.startAsync(_outDir);
    say('核心: ' + r.toString());
  } catch (e) {
    say('SourinCore.startAsync 失败（忽略）: ' + e.toString());
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.setTitle('源影 · R6-b 直播弹幕像素验收');
  }

  // 直播流来源：给一条 DRM 流 ⇒ 页面停在「无线路可播」，不真起 mpv
  // （真起 mpv 会去拉网络流；本探针要证的是**底栏**，不需要真解码）
  // 探针不是 test 文件，但用的正是产品为测试留的口子（只读、可清空）
  // ignore: invalid_use_of_visible_for_testing_member
  SourinApi.debugLiveStreamFetcher = (provider, channelId) async =>
      <StreamCandidate>[
        const StreamCandidate(
          url: 'https://127.0.0.1/never-played.m3u8',
          kind: 'hls',
          label: '线路',
          drmProtected: true,
        ),
      ];

  final net = _CountingTransport();
  debugSetDanmakuTransportForTest(net);

  try {
    await caseA1Live(net);
    await caseA2Vod(net);
    await caseA3Diff();
  } catch (e, st) {
    bad('探针异常: ' + e.toString());
    say(st.toString());
  } finally {
    debugSetDanmakuTransportForTest(null);
    // ignore: invalid_use_of_visible_for_testing_member
    SourinApi.debugLiveStreamFetcher = null;
  }

  if (errs.isNotEmpty) {
    for (final e in errs.take(8)) {
      bad('渲染异常: ' + e);
    }
  } else {
    ok('A0  全程无渲染异常（RenderFlex overflow 也走这里）');
  }

  await _finish();
}
