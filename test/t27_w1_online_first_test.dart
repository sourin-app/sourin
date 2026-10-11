// ═══════════════════════════════════════════════════════════════════════
//  Owner 1011 反馈①：首页/历史进在线条目 ⇒ 右栏被磁盘同名缓存抢走
//  （w1-online-first）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 从首页进入已缓存的页面，跟从已缓存页面进入根本不一样，
// > 从已缓存页面进入是本地的文件，其他页面进（首页、播放历史这些）
// > 优先进在线播放页
// ```
//
// # 缺陷（两条入口的差别**不在播放流，在右栏被谁抢走**）
// ```text
// 首页/历史/追更 ⇒ shell._openDetail ⇒ _mediaRoute（只带 provider/id）
//   ⇒ _resolvedLocalPath == null —— 会话判定**本来就是对的**（在线）
//   ⇒ 但 `_diskWorkForThis` 的**标题回退**仍会命中磁盘上同名的那部剧
//   ⇒ `_downloadedItems` 非空
//   ⇒ media_page.dart 右栏判据 `if (mine.isEmpty && onDisk.isEmpty) return detail;`
//     不成立 ⇒ 右栏**整块**换成 DownloadPanel
//     （没有封面 / 没有来源 / 没有剧集列表 / 操作按钮全没）
// ```
// ★ 而「已缓存页进入」看起来"对"，恰恰是因为它 `_resolvedLocalPath != null`
//   ⇒ 右栏判据**提前 return detail** ⇒ **根本走不到标题回退**。
//
// # 修法
// ```text
// `_diskWorkForThis` 的标题回退加在线会话门控：
//     if (_resolvedLocalPath == null) return null;
// 规范化路径那一档**保持不变**（在线 id 与磁盘目录绝对路径规范化后绝无可能相等，
// 天然只在本地会话命中）。
// ★ 标题回退**不能整个删掉** —— 它仍是本地会话下宿主没给 localMeta 那个入口
//   （收藏里的本地条目，T27-04）认回 CachedWork 的唯一手段。
// ```
//
// # 门禁形态：确定性接缝级（零 libmpv）
// 本机/CI 无 libmpv-2.dll ⇒ 真解码路径在 flutter_tester 里走不通
// （理由与 t27_w4 同，见那个文件的说明）。
// ⇒ 不驱动解码，只断言**右栏选中的是哪个组件**：
//   ① 在线条目 + 磁盘有同名缓存 ⇒ 右栏必须是**在线详情区**（DetailPage），
//      且 DetailPage.localFile == null（不是本地模式）；
//   ② 同一部剧从**已缓存入口**进 ⇒ 右栏仍是本地详情区（回归护栏，逐字节不变）；
//   ③ 本地会话（收藏腿，无 localMeta）⇒ 标题回退**仍然生效**（不许误伤 T27-04）；
//   ④ 静态契约：标题回退前必须有在线会话门控（防后续手滑删掉）。
//
// # 判据表（红=修复前实测，见 .probe/ops/t27-w1-online-first.md）
// ① 在线 + 同名缓存 ⇒ 修复前：右栏=DownloadPanel（红）；修复后：右栏=DetailPage
// ② 已缓存腿        ⇒ 前后都是本地详情区（护栏）
// ③ 收藏腿          ⇒ 前后都靠标题回退认出本地剧（护栏，钉死不许误伤）
// ④ 静态契约        ⇒ 修复前红（无门控）
//
// # 跑法
//   C:\Users\iuuuuuuuu\flutter\bin\flutter.bat test test/t27_w1_online_first_test.dart --concurrency=1
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/widgets/download_panel.dart';

import 'support/ui_shot.dart';

Directory _sandbox(String name) {
  final p =
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}$name';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  d.createSync(recursive: true);
  return d;
}

Widget _appWith(Widget home) {
  return mui.MaterialApp(
    theme: AppTheme.themeFor(Brightness.dark),
    home: home,
  );
}

/// 右栏读数：当前树上选中的是**详情区**还是**下载面板**，以及详情区是不是本地模式。
///
/// ⚠️ 两个组件**互斥**（右栏那个位置二选一，见 media_page 的 detailOrDownloads），
///    所以断言"在线会话下 DownloadPanel 不存在"是有区分力的。
({int details, int panels, int localDetails}) _rightRail(WidgetTester t) {
  final details =
      t.widgetList(find.byType(DetailPage)).whereType<DetailPage>().toList();
  final panels = t.widgetList(find.byType(DownloadPanel)).length;
  return (
    details: details.length,
    panels: panels,
    localDetails: details.where((d) => d.localFile != null).length,
  );
}

/// 本页本地会话裁决值读数（@visibleForTesting getter，经 dynamic 拿私有 State）。
String? _resolvedOf(WidgetTester t) {
  final st = t.state(find.byType(MediaPage));
  // ignore: avoid_dynamic_calls —— 私有 State 的测试专用出口
  return (st as dynamic).resolvedLocalPath as String?;
}

/// 稳定推进若干帧（扫盘是异步 IO，必须给足时间让它落地）
Future<void> _settle(WidgetTester t, {int rounds = 20}) async {
  for (var i = 0; i < rounds; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 50));
    await t.pump();
    while (t.takeException() != null) {}
  }
}

void main() {
  late Directory root;
  late Directory workDir;
  late CachedWork work;
  late String ep1Path;
  late String ep1Key;
  const workTitle = 'T27W1 剧名';
  const ep1Name = '第01集 T27W1.mp4';

  setUpAll(loadRealFonts);

  setUp(() {
    UiPrefs.debugResetForTest();
    root = _sandbox('t27_w1_online_first');
    for (final e in root.listSync()) {
      e.deleteSync(recursive: true);
    }
    ClipDownloader.debugSetDataDir(root.path);

    // 造一部 2 集的"已下载"本地剧 —— 它就是磁盘上那部**同名**的剧。
    workDir = Directory('${root.path}${Platform.pathSeparator}$workTitle')
      ..createSync(recursive: true);
    for (var i = 1; i <= 2; i++) {
      File('${workDir.path}${Platform.pathSeparator}第0$i集 T27W1.mp4')
          .writeAsBytesSync(List<int>.filled(1024, 0x42));
    }
    CachePage.debugScanRootOverride = root.path;
    addTearDown(() {
      CachePage.debugScanRootOverride = null;
      ClipDownloader.debugSetDataDir(null);
    });

    work = CachedWork(
      dirName: workTitle,
      path: workDir.path,
      title: workTitle,
      episodes: const <CachedEpisode>[],
    );
    ep1Path = '${workDir.path}${Platform.pathSeparator}$ep1Name';
    ep1Key = canonicalLocalPath(ep1Path);
    expect(File(ep1Path).existsSync(), isTrue, reason: '夹具文件必须存在');
  });

  tearDownAll(() {
    final d = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t27_w1_online_first');
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  // ─────────────────────────────────────────────────────────────────────
  //  ① 本缺陷的**主判据**：在线条目 + 磁盘同名缓存 ⇒ 右栏必须是在线详情区
  // ─────────────────────────────────────────────────────────────────────
  testWidgets('T27W1-① 首页进在线条目（磁盘有同名缓存）⇒ 右栏是在线详情区，不被下载面板抢走',
      (t) async {
    await setShotViewport(t, const Size(1600, 1000));

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        // ★ 与首页/历史的真实入参同构：shell._openDetail ->
        //   MediaPage(provider:'demo', id:…) —— **没有** localPath。
        //   title 与磁盘上那部剧**逐字相同**（这正是标题回退的触发条件）。
        const MediaPage(
          provider: 'demo',
          id: 'demo-online-1',
          title: 'T27W1 剧名',
        ),
      ));
      await _settle(t);
    });

    final rail = _rightRail(t);
    debugPrint('T27W1-① 读数：DetailPage=${rail.details} '
        'DownloadPanel=${rail.panels} 本地详情区=${rail.localDetails}');

    expect(_resolvedOf(t), isNull, reason: '在线条目绝不能被判成本地会话');
    expect(rail.panels, 0,
        reason: '★ 本缺陷主判据：在线会话的右栏**不许**被磁盘同名缓存换成下载面板');
    expect(rail.details, greaterThan(0), reason: '右栏必须是在线详情区');
    expect(rail.localDetails, 0,
        reason: '在线条目的详情区不能是「本地模式」（那是已缓存入口的形态）');
  });

  // ─────────────────────────────────────────────────────────────────────
  //  ② 回归护栏：已缓存入口（带 localPath+localMeta）行为逐字节不变
  // ─────────────────────────────────────────────────────────────────────
  testWidgets('T27W1-② 已缓存入口 ⇒ 右栏仍是本地详情区（行为不变）', (t) async {
    await setShotViewport(t, const Size(1600, 1000));

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        MediaPage(
          provider: kLocalProvider,
          id: ep1Key,
          title: workTitle,
          episodeId: ep1Name,
          localPath: ep1Path,
          localMeta: work,
        ),
      ));
      await _settle(t);
    });

    final rail = _rightRail(t);
    debugPrint('T27W1-② 读数：DetailPage=${rail.details} '
        'DownloadPanel=${rail.panels} 本地详情区=${rail.localDetails}');

    expect(_resolvedOf(t), ep1Path,
        reason: '带 localPath 的入口，裁决值不得被规范化改写');
    expect(rail.localDetails, 1,
        reason: '已缓存入口必须是本地详情区（与本改动前一致）');
  });

  // ─────────────────────────────────────────────────────────────────────
  //  ③ 关键护栏：标题回退**不许被误伤**
  //     本地会话 + 宿主没给 localMeta（收藏里的本地条目，T27-04）
  //     ⇒ 只能靠标题回退认出磁盘上那部剧，否则「已下载」列表会空掉。
  // ─────────────────────────────────────────────────────────────────────
  testWidgets('T27W1-③ 收藏腿（本地会话·无 localMeta）⇒ 标题回退仍生效，已下载列表不空',
      (t) async {
    await setShotViewport(t, const Size(1600, 1000));

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        // ★ 与首页收藏点本地条目的真实入参同构：provider=local + id=文件路径，
        //   **没有** localPath、**没有** localMeta。
        //   ⇒ 本页只能靠 `_diskWorkForThis` 的**标题回退**认出磁盘上那部剧。
        MediaPage(
          provider: kLocalProvider,
          id: ep1Key,
          title: workTitle,
        ),
      ));
      await _settle(t);
    });

    final rail = _rightRail(t);
    debugPrint('T27W1-③ 读数：DetailPage=${rail.details} '
        'DownloadPanel=${rail.panels} 本地详情区=${rail.localDetails}');

    expect(_resolvedOf(t), isNotNull,
        reason: 'id 指向存在的文件 ⇒ 必须被判成本地会话');
    expect(rail.localDetails, 1,
        reason: '★ 标题回退不许被误伤：本地会话（无 localMeta）必须认出磁盘上那部剧');
    final d = t
        .widgetList(find.byType(DetailPage))
        .whereType<DetailPage>()
        .firstWhere((x) => x.localFile != null);
    expect(d.localEpisodeCount, 2,
        reason: '「已下载」列表必须列出那 2 集（标题回退认不出就会是 0）');
  });
}
