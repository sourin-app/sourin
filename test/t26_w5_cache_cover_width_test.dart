// ═══════════════════════════════════════════════════════════════════════
//  T26-W5 / CR-09 —— 「已缓存」页**盘上封面层**的宽度必须与海报卡同源
// ═══════════════════════════════════════════════════════════════════════
//
// # CodeRabbit 原始意见（未解决线程）
// ```text
// lib/ui/cache_page.dart:643 —— _CacheWorkCard 没给 PosterCard 传 width；
// 窄网格下父约束把 PosterCard 压小，而本地封面层仍按屏幕宽度与
// AppMetrics.posterWidth 计算 ⇒ 封面层宽于海报格、高度可能盖住标题区。
// ```
//
// # 判据是什么（不是「能不能变绿」）
// ```text
// 盘上那张封面是**叠在海报格上**的一层（Stack 的第二个孩子）。
// 它唯一正确的几何 = **海报卡自己那一格**：
//     left / top  与卡片重合
//     width       = 卡片的实际宽
//     height      = 宽 / AppMetrics.posterAspect
// ⇒ 断言比较**两个真实渲染矩形**（盘上封面的 Image vs PosterCard），
//   而不是比较某个常量 —— 常量对了、几何错了照样是缺陷。
// ```
//
// # 为什么必须驱动**真页面**（Lead 硬要求）
// ```text
// 「窄网格下父约束把 PosterCard 压小」发生在 SliverGrid 的 tight 约束里。
// 只有把 CachePage 真挂起来、真让 SliverLayoutBuilder 算列数，
// 才能拿到那个格子宽。
// 单独调 _posterBoxWidth() 之类是**假门禁** —— 它读 MediaQuery，
// 窄窗口下本来就返回 148（= 缺陷值本身），测不出任何东西。
// ```
//
// # 为什么窄档只能取 ≤ 500px 的窗口（这条很重要）
// ```text
// Layout.columnsForBand 在**宽档**（>640）给的最小格宽是
// minCellWide = 152 > 148 ⇒ 宽档**永远复现不出**这条缺陷。
// 窄档（≤640）：padding = Sp.x4(16) / minCellNarrow = 112 / gap = Sp.x3(12)
//   窗口 400 ⇒ inner = 368、cols = 3、格子宽 = (368 - 24) / 3 = 114.67
//   ⇒ 封面层按 148 画 ⇒ 比格子**宽出 33.3px**（盖到邻格间距上），
//     高 222 而海报格只有 172 ⇒ **多出 50px 盖住标题区**。
// ★ 这正是 CR 描述的那一幕。
// ```
//
// ⚠️ 沙盒一律 _sandboxRoot()（绝对路径 + 收尾自清理），产物绝不许落仓库根。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

/// 业主真机上的目录名（逐字照抄上一轮探针，别改成测试友好的短名）
const String kDirName = '无职转生 第三季 ～到了异世界就拿出真本事～';
const String kCoverUrl = 'https://gimg1.baidu.com/gimg/pic/cover/l/1f/9e/501963.jpg';

/// ★ 探针沙盒根 —— 必须是绝对路径，且落在系统临时目录下
Directory _sandboxRoot() {
  final p = '${Directory.systemTemp.absolute.path}'
      '${Platform.pathSeparator}t26_w5_cover_width';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 探针沙盒必须是绝对路径，实际 = $p');
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 一张**真的** 1×1 PNG（不是 0 字节！0 字节会走 errorBuilder，测不出东西）
File _writeRealPng(String path) {
  const bytes = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82,
  ];
  final f = File(path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  return f;
}

void _writeSidecar(
  String dirPath, {
  String? provider,
  String? id,
  String? title,
  String? cover,
  String? coverFile,
}) {
  File(dirPath + Platform.pathSeparator + kCacheSidecarName)
      .writeAsStringSync(jsonEncode(<String, String?>{
    'provider': provider,
    'id': id,
    'title': title,
    'cover': cover,
    'coverFile': coverFile,
  }));
}

Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: child ?? const mui.SizedBox(),
    ),
    home: home,
  );
}

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常 / 布局溢出报告）
///
/// ★ 返回**原文**而不是丢掉：窄档下 `childAspectRatio` 与卡片内容高不匹配
///   是**既有**现象（与本次缺陷同源但不同因），报告里要如实写出来。
List<String> _claim(WidgetTester t) {
  final out = <String>[];
  var n = 0;
  while (n++ < 200) {
    final e = t.takeException();
    if (e == null) break;
    out.add(e.toString());
  }
  return out;
}

/// 屏幕上那张**盘上封面**的 Image（判据：provider 是 FileImage）
Image? _fileCoverImage(WidgetTester t) {
  for (final img in t.widgetList<Image>(find.byType(Image))) {
    Object? p = img.image;
    while (p is ResizeImage) {
      p = p.imageProvider;
    }
    if (p is FileImage) return img;
  }
  return null;
}

/// 屏幕上那张 `PosterCard` **组件**（读它的 `width` 参数）
///
/// ★ 为什么必须单独断言「有没有把宽度传给 PosterCard」
/// ```text
/// 窄档下父约束是**紧的**（`SliverGridDelegate` 给的是 tight 约束）
/// ⇒ `SizedBox(width:148)` 会被 `BoxConstraints.enforce` 压到格子宽
/// ⇒ 光看**渲染矩形**分不出「传了没有」：两种写法都得到 114.67。
/// 但卡片内部的 `w` 决定它把封面**解码成多大**
/// （`poster_card.dart:177-179` → `coverImage(layoutWidth: w,
///   layoutHeight: w / posterAspect)` → `cover_image.dart:191-206`
///   `cacheHeight = w / posterAspect * dpr`）：
///   没传 ⇒ w=148    ⇒ 解码高 222（按 148 那张卡的尺寸解码）
///   传了 ⇒ w=114.67 ⇒ 解码高 172（与真实盒子同源）
/// ⇒ 直接把组件参数读出来，是这条判据最不易退化的形式。
/// ```
PosterCard _posterCardOf(WidgetTester t) =>
    t.widget<PosterCard>(find.byType(PosterCard));

/// 真把「已缓存」页泵起来
///
/// # 为什么必须 runAsync
/// 扫盘是**真碰盘**的真异步 IO；`t.pump` 走受控时钟，真实 IO 的 future 在
/// fake async 区里永不完成 ⇒ 页面永远停在 loading（上一轮探针假阴性的原因）。
Future<List<String>> _pumpCachePageAt(
  WidgetTester t,
  String rootPath,
  Size logical,
) async {
  CachePage.debugScanRootOverride = rootPath;
  DownloadDir.setConfiguredDir(rootPath);

  // ★ 必须用 tester.view.* —— 它同时驱动 RenderView 的约束与 MediaQuery；
  //   setSurfaceSize 只改前者，两者不一致会造成假红。
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = logical;
  addTearDown(t.view.reset);

  await t.runAsync(() async {
    await t.pumpWidget(_appWith(home: const mui.Scaffold(body: CachePage())));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    }
  });
  await t.pump();

  final st = t.state<CachePageState>(find.byType(CachePage));
  debugPrint('RENDER loading=${st.debugLoading}'
      ' error=${st.debugError}'
      ' works=${st.debugWorkCount}'
      ' loadCount=${st.debugLoadCount}');

  // 收尾：走完 UiPrefs 的防抖落盘 timer，否则判「Timer is still pending」
  await t.pump(const Duration(milliseconds: 500));
  return _claim(t);
}

/// 造一部**带盘上封面**的缓存作品（真目录 + 真 PNG + 真旁文件）
void _seedOneWork(Directory root) {
  final dir = root.path + Platform.pathSeparator + kDirName;
  Directory(dir).createSync(recursive: true);
  File('$dir${Platform.pathSeparator}第01集 第01集.mp4')
      .writeAsBytesSync(List<int>.filled(2 * 1024 * 1024, 0x41));
  _writeRealPng('$dir${Platform.pathSeparator}_sourin-cover.jpg');
  _writeSidecar(
    dir,
    provider: 'bilibili',
    id: 'bv1xx411c7mD',
    title: kDirName,
    cover: kCoverUrl,
    coverFile: '_sourin-cover.jpg',
  );
}

/// 当前窗口下**这一格**的宽 —— 与 CachePage 里 SliverGrid 的算式同源
///
/// band  = 窗口宽（`Layout.bandFor` 恒等于窗口宽）
/// cols  = `Layout.columnsForBand(band)`（页面里由 SliverLayoutBuilder 算出）
/// cell  = `Layout.cellWidthFor(band, cols)`（= SliverGrid 的格子宽）
({double band, int cols, double cell}) _gridGeometry(WidgetTester t) {
  final band = t.view.physicalSize.width / t.view.devicePixelRatio;
  final cols = Layout.columnsForBand(band);
  final cell = Layout.cellWidthFor(band, cols);
  return (band: band, cols: cols, cell: cell);
}

/// 把当前那部作品的**两个矩形**读出来（盘上封面层 / 海报卡）
({Rect cover, Rect card, Rect grid}) _rects(WidgetTester t) {
  final img = _fileCoverImage(t);
  expect(img, isNotNull,
      reason: '★ 前提：盘上封面那层必须真的在树里（FileImage）—— '
          '它不在的话本探针什么都没测到');
  final card = find.byType(PosterCard);
  expect(card, findsOneWidget, reason: '★ 前提：屏幕上恰好一张海报卡');
  return (
    cover: t.getRect(find.byWidget(img!)),
    card: t.getRect(card),
    grid: t.getRect(find.byType(CustomScrollView)),
  );
}

void main() {
  late Directory root;

  setUp(() {
    UiPrefs.remove(DownloadDir.kDirKey);
    DownloadDir.debugReset();
    debugClearCacheMetaMemo();
    // ★ 默认把查库这条路短路成空列表：真 API 要 FFI 核心，探针里没有
    debugMetaFetchers = (
      history: () async => const <HistoryEntry>[],
      favorites: () async => const <Favorite>[],
    );
    CachePage.debugScanRootOverride = null;
    root = Directory(
      '${_sandboxRoot().path}${Platform.pathSeparator}'
      'w5-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
  });

  tearDown(() {
    debugClearCacheMetaMemo();
    debugMetaFetchers = null;
    CachePage.debugScanRootOverride = null;
    DownloadDir.debugReset();
  });

  tearDownAll(() {
    final d = Directory('${Directory.systemTemp.absolute.path}'
        '${Platform.pathSeparator}t26_w5_cover_width');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径，实际 = ${d.path}');
    if (d.existsSync()) d.deleteSync(recursive: true);
    debugPrint('CLEANUP 已删除探针沙盒 ${d.path} 存在=${d.existsSync()}');
  });

  // ══════════════════════════════════════════════════════════════
  //  ① 窄档（400px）：格子宽 114.67 < 148 ⇒ **缺陷现场**
  // ══════════════════════════════════════════════════════════════
  testWidgets('★★★ CR-09 窄网格：盘上封面层必须与海报卡同宽同高同原点', (t) async {
    _seedOneWork(root);
    final errs = await _pumpCachePageAt(t, root.path, const Size(400, 900));
    for (final e in errs) {
      debugPrint('CLAIM ${e.split('\n').first}');
    }

    final st = t.state<CachePageState>(find.byType(CachePage));
    expect(st.debugWorkCount, 1, reason: '★ 前提：真扫到那一部');

    final g = _gridGeometry(t);
    final r = _rects(t);
    debugPrint('GEOM band=${g.band}'
        ' cols=${g.cols}'
        ' cell=${g.cell.toStringAsFixed(3)}'
        ' card=${r.card}'
        ' cover=${r.cover}');

    // 前提：这一档确实是「格子比设计宽 148 还窄」的那一档（否则测的是别的场景）
    expect(g.cell, lessThan(AppMetrics.posterWidth),
        reason: '★ 前提：窄档的格子宽必须真的小于 AppMetrics.posterWidth');
    // 前提：视口宽 == 窗口宽（页面里 band 就是这么算出来的）
    expect(r.grid.width, closeTo(g.band, 0.5),
        reason: '★ 前提：CustomScrollView 的宽 == 窗口宽（band 的来源）');

    // ★★★ 核心判据：盘上封面层 = 海报卡那一格
    expect(r.card.width, closeTo(math.min(g.cell, AppMetrics.posterWidth), 0.5),
        reason: '★ 海报卡必须落在**这一格**里（父约束压小后它不再是 148）');
    expect(r.cover.width, closeTo(r.card.width, 0.01),
        reason: '★★★ CR-09：盘上封面层的宽必须等于海报卡的宽。\n'
            '改前它按 AppMetrics.posterWidth(148) 画 ⇒ 比 114.67 的格子\n'
            '宽出 33.3px，压到邻格的间距上。');
    expect(r.cover.left, closeTo(r.card.left, 0.01),
        reason: '★ 封面层左缘必须与海报卡左缘重合');
    expect(r.cover.top, closeTo(r.card.top, 0.01),
        reason: '★ 封面层上缘必须与海报卡上缘重合');
    expect(r.cover.height, closeTo(r.card.width / AppMetrics.posterAspect, 0.01),
        reason: '★ 封面层高 = 海报格高（宽 / posterAspect）');
    expect(r.cover.bottom,
        lessThanOrEqualTo(r.card.top + r.card.width / AppMetrics.posterAspect + 0.01),
        reason: '★★ CR-09 后半句：封面层**不许盖住标题区**。\n'
            '改前高 222 而海报格只有 172 ⇒ 多出的 50px 正压在标题上。');

    // ★ CR 的另一半：「把它同时传给 PosterCard」。
    //   矩形上看不出来（父约束是紧的），但组件参数读得出来。
    final pc = _posterCardOf(t);
    debugPrint('GEOM posterWidth=${pc.width}');
    expect(pc.width, isNotNull,
        reason: '★★ CR-09：必须把宽度传给 PosterCard。\n'
            '改前这里是 null ⇒ 卡片按 148 算自己的解码尺寸，'
            '而父约束只给了 114.67 ⇒ 图与盒子不同源。');
    expect(pc.width, closeTo(r.card.width, 0.01),
        reason: '★★ CR-09：传给 PosterCard 的宽必须等于它**实际**占的宽');
    expect(pc.width, closeTo(math.min(g.cell, AppMetrics.posterWidth), 0.5));
  });

  // ══════════════════════════════════════════════════════════════
  //  ② 宽档（1280px）：**回归护栏** —— 视觉一个像素都不许变
  // ══════════════════════════════════════════════════════════════
  testWidgets('★ CR-09 宽网格：海报卡仍是设计宽 148，封面层跟着它', (t) async {
    _seedOneWork(root);
    final errs = await _pumpCachePageAt(t, root.path, const Size(1280, 800));
    for (final e in errs) {
      debugPrint('CLAIM ${e.split('\n').first}');
    }

    final st = t.state<CachePageState>(find.byType(CachePage));
    expect(st.debugWorkCount, 1, reason: '★ 前提：真扫到那一部');

    final g = _gridGeometry(t);
    final r = _rects(t);
    debugPrint('GEOM band=${g.band}'
        ' cols=${g.cols}'
        ' cell=${g.cell.toStringAsFixed(3)}'
        ' card=${r.card}'
        ' cover=${r.cover}');

    expect(g.cell, greaterThan(AppMetrics.posterWidth),
        reason: '★ 前提：宽档的格子比 148 宽（所以海报**不该**被撑到格子宽）');
    expect(r.card.width, closeTo(AppMetrics.posterWidth, 0.01),
        reason: '★ 宽档下海报卡必须**逐字节保持**设计宽 148 ——\n'
            '把它撑到格子宽(162.29)会让「已缓存」页的卡片比首页大 10%，\n'
            '那是本任务没要求的视觉改动。');
    expect(r.cover.width, closeTo(r.card.width, 0.01),
        reason: '★ 封面层仍然必须等于海报卡（宽档本来就对，这里是护栏）');
    expect(r.cover.left, closeTo(r.card.left, 0.01));
    expect(r.cover.top, closeTo(r.card.top, 0.01));
    expect(r.cover.height, closeTo(r.card.width / AppMetrics.posterAspect, 0.01));

    // ★ 宽档传给 PosterCard 的宽必须**逐值不变** = 148 ——
    //   这条钉住「本次改动对宽档是恒等变换」。
    final pc = _posterCardOf(t);
    expect(pc.width, closeTo(AppMetrics.posterWidth, 0.01),
        reason: '★ 宽档下必须仍按设计宽 148 传给 PosterCard');
  });
}
