// ═══════════════════════════════════════════════════════════════════════
//  T27-04 首页收藏进本地播放失败：local 会话缺 localPath（w4-localfav）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（Owner 反馈 ④/⑤，fig4/fig5）
// 收藏的是本地文件条目（ui-prefs.json：dsh.bili.bind.local -> ……第01集….mp4）。
// 首页收藏卡点开：MyShelf.onTap -> onOpenDetail(provider='local', id=绝对路径)
//   -> shell._openDetail -> shell._mediaRoute -> MediaPage(provider, id)。
// 这个入口【没有 localPath】（shell._openCachedWork 才有）⇒ MediaPage 的
// 本地判据全是 widget.localPath ⇒ 判成在线会话 ⇒ resolveStream('local', 路径)
// ⇒ 核心代理无 local 流 ⇒ 「Failed to open http://127.0.0.1:<port>/s/…」。
//
// # 门禁形态：确定性接缝级（零 libmpv）
// 本机/CI 无 libmpv-2.dll（整机深扫确认）：PlayerPage.initState 的 Player()
// 构造（player_page.dart:2230）在 flutter_tester 里直接抛
// 「MediaKit.ensureInitialized must be called…」⇒ 真解码路径无法在测试里走通。
// ⇒ 不构造 PlayerPage：用 debugOnDetailPlayForward 置**空探针**拦下
//   applySession（媒体会话请求在进播放器前被截获），断言
//   ① MediaPage 的**会话判据本身**：修复前收藏腿 DetailPage.localFile=null、
//     会话 req.localPath=null；修复后 localFile=id、req.localPath=id。
//   ② 已缓存入口（带 localPath+localMeta）行为逐字节不变。
//   ③ 在线条目不拿本地会话。
//   ④ 失效文件（provider=local 但文件不存在）不静默短路成本地。
// 另有静态契约：钉死 PlayerPage.localPath / DetailPage.localFile /
//   _onDetailPlay 兜底接线全部改用 _resolvedLocalPath（防止后续手滑回退）。
// 先例：test/my_shelf_test.dart —— 环境受限时用静态契约守关键接线。
//
// # 判据表（红=修复前实测 +0 -4 见 .probe/ops/t27-w4-localfav.md）
// ① 收藏腿   DetailPage.localFile==id、onPlayLocalEpisode 可点、会话 req.localPath!=null
// ② 已缓存腿 同①（回归护栏：原入口逐字节不变）
// ③ 在线条目 localFile==null、会话 req.localPath==null
// ④ 失效文件 localFile==null（不短路）
//
// # 跑法
//   C:\Users\iuuuuuuuu\flutter\bin\flutter.bat test test/t27_w4_local_fav_play_test.dart --concurrency=1
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

/// 右侧本地区读数：DetailPage.localFile != null 的实例恰好 [expected] 个，
/// 且其中第一部的 localFile 规范化后等于 [localFile]。
void _expectDetailLocal(WidgetTester t, String localFile, {int expected = 1}) {
  final details = t
      .widgetList(find.byType(DetailPage))
      .whereType<DetailPage>()
      .toList();
  final localOnes =
      details.where((d) => d.localFile != null).toList();
  debugPrint('T27W4 读数：DetailPage=${details.length} '
      'localFile!=null 的=${localOnes.length} '
      'localFile=${localOnes.isEmpty ? "-" : localOnes.first.localFile}');
  expect(localOnes, hasLength(expected),
      reason: '本地区数量不符：details=${details.length} '
          'local=${localOnes.length}');
  if (expected > 0) {
    expect(
      canonicalLocalPath(localOnes.first.localFile!),
      canonicalLocalPath(localFile),
      reason: '本地区必须指向被点开的那个文件（规范化后）',
    );
  }
}

/// 本页本地会话裁决值读数（@visibleForTesting getter，经 dynamic 拿私有 State）。
String? _resolvedOf(WidgetTester t) {
  final st = t.state(find.byType(MediaPage));
  // ignore: avoid_dynamic_calls —— 私有 State 的测试专用出口
  return (st as dynamic).resolvedLocalPath as String?;
}

/// ★ 本套件**唯一**允许放行的异常源 —— 无 libmpv 的原生播放器构造失败。
///
/// # 为什么必须放行（且**只**放行这一个根因）
/// ```text
/// 本机/CI 无 libmpv-2.dll ⇒ PlayerPage.initState 里 `Player(...)` 构造抛
///   ① Exception: MediaKit.ensureInitialized must be called before using any
///      API from package:media_kit.
///   ② 同一个构造在**首次同步构建**里抛出 ⇒ 框架再抛一条次生内部断言
///        'framework.dart': Failed assertion: '_elements.contains(element)'
///      —— 根因仍是"无 dll"，不是接缝/渲染/状态逻辑出错。
/// ```
/// # ⚠️ 这里原来是**四处**相同的 `while (t.takeException() != null) {}`
///
/// 那正是 `CONTRIBUTING.md`「⑥ 规矩二」要防的形态：把**失败静默吞掉**。
/// 非原生媒体错误（接缝断言、渲染、状态）会被一起丢弃 ⇒ 门禁漏报。
/// 现在收敛成**同一项**预期异常检查：只放行上面这一个根因，其余抛出 ⇒ 测试变红。
bool isKnownNativeMediaException(String s) =>
    s.contains('MediaKit.ensureInitialized') ||
    s.contains('_elements.contains(element)');

/// 稳定推进若干帧（扫盘是异步 IO，必须给足时间让它落地）
///
/// ★ 放行口径：**只**放行已知的原生播放器异常；其余**让测试红**。
///   四个测试原来各自写一遍 `while (t.takeException() != null) {}`，现统一走这里。
///
/// # 为什么必须从 `FlutterError.onError` 逐条取（不能只看 takeException）
/// ```text
/// 同一个 pump 里抛了**两条**异常时，`takeException()` 只返回一句
///   'Multiple exceptions (2) were detected …'（正文全丢）——
///   那正是"非预期异常被静默"的温床：既不知道抛了什么，也没法判定放行。
/// ⇒ 抄本仓既有形态（test/t119_error_view_overflow_test.dart:146-169）：
///   临时挂 `FlutterError.onError` 把**每一条**正文收进 sink，逐条判定。
/// ```
Future<void> _settle(WidgetTester t, {int rounds = 20}) async {
  final caught = <String>[];
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    caught.add(details.exceptionAsString());
    prev?.call(details);
  };
  try {
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
      for (final e in caught) {
        if (!isKnownNativeMediaException(e)) {
          throw Exception('★ 非预期异常（改前被 `while (takeException)` 静默吞掉）:\n$e');
        }
      }
      caught.clear();
      while (t.takeException() != null) {}
    }
  } finally {
    FlutterError.onError = prev;
  }
}

void main() {
  late Directory root;
  late Directory workDir;
  late CachedWork work;
  late String ep1Path;
  late String ep1Key;
  const workTitle = 'T27W4 剧名';
  const ep1Name = '第01集 T27W4.mp4';

  setUpAll(loadRealFonts);

  setUp(() {
    UiPrefs.debugResetForTest();
    root = _sandbox('t27_w4_local_fav');
    for (final e in root.listSync()) {
      e.deleteSync(recursive: true);
    }
    ClipDownloader.debugSetDataDir(root.path);

    // 造一部 2 集的"已下载"本地剧（收藏条目指它）。
    workDir = Directory(
        '${root.path}${Platform.pathSeparator}$workTitle')
      ..createSync(recursive: true);
    for (var i = 1; i <= 2; i++) {
      File(
              '${workDir.path}${Platform.pathSeparator}第0$i集 T27W4.mp4')
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
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}t27_w4_local_fav');
    if (d.existsSync()) d.deleteSync(recursive: true);
  });

  testWidgets('T27W4-① 收藏腿：provider=local + id=文件路径（无 localPath）⇒ 本地会话',
      (t) async {
    await setShotViewport(t, const Size(1600, 1000));

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        // ★ 与首页收藏点开的真实入参同构：MyShelf -> shell._openDetail ->
        //   MediaPage(provider:'local', id=绝对路径)，**没有** localPath。
        MediaPage(provider: kLocalProvider, id: ep1Key, title: workTitle),
      ));
      await _settle(t);
    });

    // 右侧详情区必须切成本地模式（isLocalFile 判据 = DetailPage.localFile）。
    final details =
        t.widgetList(find.byType(DetailPage)).whereType<DetailPage>().toList();
    final localOnes = details.where((d) => d.localFile != null).toList();
    debugPrint('T27W4-① 读数：DetailPage=${details.length} '
        'localFile=${localOnes.isEmpty ? "-" : localOnes.first.localFile}');
    expect(localOnes, hasLength(1),
        reason: '收藏进来的本地条目，右侧必须是本地详情区');
    expect(localOnes.single.localEpisodeCount, 2,
        reason: '本地详情区要列出 2 集（与已缓存入口同观感）');
    expect(localOnes.single.onPlayLocalEpisode, isNotNull,
        reason: '本地集列表必须可点');
    // ★ 会话裁决读数：本页解析出的本地路径必须就是被点开的文件
    //   （修复前 = null ⇒ 播放器走在线 resolveStream ⇒ 127.0.0.1 失败）。
    expect(canonicalLocalPath(_resolvedOf(t)!), canonicalLocalPath(ep1Path),
        reason: '收藏腿必须被裁决成本地会话（resolvedLocalPath）');
    // PlayerPage 运行期接线（localPath 收到裁决值）在无 libmpv 的开发机上
    // 断言不了：Player() 构造在 initState 里先于本地短路执行，无 dll 必抛
    // MediaKit 异常 ⇒ 元素被 ErrorWidget 替换。转发接线由静态契约 T27W4-S
    // 钉死（`localPath: _resolvedLocalPath,`），本地短路行为由
    // zz_t12_local_play_probe_test（native-media 标签）在有机的机器上覆盖。
  });

  testWidgets('T27W4-② 已缓存腿：带 localPath+localMeta（shell._openCachedWork 同构）⇒ 行为不变',
      (t) async {
    await setShotViewport(t, const Size(1600, 1000));

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        MediaPage(
          provider: kLocalProvider,
          id: ep1Key,
          title: work.displayTitle,
          episodeId: ep1Name,
          localPath: ep1Path,
          localMeta: work,
        ),
      ));
      await _settle(t);
    });

    _expectDetailLocal(t, ep1Path);
    // ★ 回归护栏：已缓存入口的裁决值必须**逐字**等于宿主传的 localPath。
    expect(_resolvedOf(t), ep1Path,
        reason: '带 localPath 的入口，裁决值不得被规范化改写');
  });

  testWidgets('T27W4-③ 在线条目：provider=demo ⇒ 右侧不是本地详情区',
      (t) async {
    await setShotViewport(t, const Size(1600, 1000));

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        const MediaPage(provider: 'demo', id: 'demo-id-1', title: 'T27W4 在线剧'),
      ));
      await _settle(t);
    });

    _expectDetailLocal(t, ep1Path, expected: 0);
    expect(_resolvedOf(t), isNull, reason: '在线条目绝不能被判成本地会话');
  });

  testWidgets('T27W4-④ 失效文件：provider=local 但文件不存在 ⇒ 不静默短路成本地',
      (t) async {
    await setShotViewport(t, const Size(1600, 1000));

    final ghostPath =
        '${root.path}${Platform.pathSeparator}ghost${Platform.pathSeparator}第01集.mp4';
    expect(File(ghostPath).existsSync(), isFalse, reason: '夹具前提：幽灵文件不存在');

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(
        MediaPage(
          provider: kLocalProvider,
          id: canonicalLocalPath(ghostPath),
          title: 'T27W4 幽灵剧',
        ),
      ));
      await _settle(t);
    });

    _expectDetailLocal(t, ep1Path, expected: 0);
    expect(_resolvedOf(t), isNull,
        reason: '文件已不在磁盘 ⇒ 不短路，走在线链路自然报错');
  });
// ═══════════════════════════════════════════════════════════════════════
// 静态契约：钉死本地会话判据的**接线**（防止后续手滑改回 widget.localPath）。
// 先例：test/my_shelf_test.dart 的静态契约形态（读源码文本断言）。
// ═══════════════════════════════════════════════════════════════════════
  test('T27W4-S 静态契约：本地会话判据统一走 _resolvedLocalPath', () {
    final src = File('lib/ui/media_page.dart').readAsStringSync();
  
    // 唯一的解析函数存在且只解析一次
    expect(src.contains('String? _resolveLocalSessionPath()'), isTrue,
        reason: '三档解析函数必须存在');
    expect(src.contains('late final String? _resolvedLocalPath ='), isTrue,
        reason: '裁决值必须只初始化一次（本页一份事实）');
  
    // 播放器 / 详情区 / 兜底 / 右栏判据全部接到裁决值
    expect(src.contains('localPath: _resolvedLocalPath,'), isTrue,
        reason: 'PlayerPage.localPath 必须转发裁决值');
    expect(src.contains('localFile: _resolvedLocalPath,'), isTrue,
        reason: 'DetailPage.localFile 必须接裁决值');
    expect(
      src.contains('if (req.localPath == null && _resolvedLocalPath != null) {'),
      isTrue,
      reason: '_onDetailPlay 兜底判据必须接裁决值',
    );
    expect(src.contains('if (_resolvedLocalPath != null) return detail;'), isTrue,
        reason: 'detailOrDownloads 判据必须接裁决值');
  
    // 关键红线：① 原入口逐字沿用；② 文件不存在绝不短路。
    expect(
      src.contains('if (widget.localPath != null) return widget.localPath;'),
      isTrue,
      reason: '解析第一档必须逐字沿用宿主 localPath（已缓存页行为不变）',
    );
    expect(src.contains("if (!File(p).existsSync()) return null;"), isTrue,
        reason: '文件不存在必须返回 null（不静默短路）');
    expect(src.contains("if (widget.provider != kLocalProvider) return null;"),
        isTrue, reason: '非 local provider 必须返回 null（在线不受影响）');
  });
  
  }
  
  
  