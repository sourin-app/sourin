// ═══════════════════════════════════════════════════════════════════════
//  Owner 第 1009 批 · 「已缓存的也要显示原来的封面 / 显示原来源，而不是 local」
//  —— 回归测试（RED 先行）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// > 已缓存的也要显示原来的封面，点击进去的播放也要显示出来原来源，而不是 local
//
// # 为什么每条都在**真磁盘目录**上跑（Lead 硬要求）
// ```text
// 「没有旁文件 ⇒ 封面退化成占位块、来源退化成 local」是**文件系统的性质**，
// 不是某个函数的返回值 ⇒ 必须在真目录上建真文件，再让页面真扫一遍。
// 只调 buildLocalPlayRequest 之类的纯函数证明不了这件事（那是假门禁）。
// ```
//
// # 三条断言分别钉住三个不同的缺陷
// ```text
// ① 卡片封面：盘上有 _sourin-cover.jpg 就必须**画出来**（Owner 看到的是灰方块）
// ② 来源标签：旁文件缺失时来源要从库里找回（找回不到才是「本地」，不猜）
// ③ 播放请求：cover 优先本地文件，originProvider 透出原来源
// ```
//
// ⚠️ 沙盒一律 _sandboxRoot()（绝对路径 + 收尾自清理），产物绝不许落仓库根。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart' show DownloadQueue;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';

/// Owner 真机上的目录名与剧名（逐字照抄截图，别改成测试友好的短名）
const String kRealDirName = '无职转生 第三季 ～到了异世界就拿出真本事～';
const String kRealCover =
    'https://gimg1.baidu.com/gimg/app=2001&src=img2.cycimg.me/pic/cover/l/1f/9e/501963_bXlEP.jpg';
const String kBilibili = 'bilibili';

/// ★ 探针沙盒根 —— 必须是绝对路径，且落在系统临时目录下
Directory _sandboxRoot() {
  final p = '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}zz_cr_cache';
  final d = Directory(p);
  if (!d.isAbsolute) {
    fail('★ 探针沙盒必须是绝对路径，实际 = $p');
  }
  if (!d.existsSync()) d.createSync(recursive: true);
  return d;
}

/// 写一个指定字节数的假视频（内容无所谓，长度就是判据）
File _writeBytes(String path, int bytes, {bool part = false}) {
  final f = File(part ? '$path.part' : path);
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(List<int>.filled(bytes, 0x41));
  return f;
}

/// ★ 一张**真的** 1×1 PNG（不是 0 字节！0 字节会走 errorBuilder，测不出东西）
///
/// # 为什么不能拿假字节凑数
/// 封面断言要看 `Image` 的 `image` 是**哪个** provider（FileImage vs NetworkImage）；
/// 用 0 字节的"图片"只会得到 errorBuilder 的空盒，测出来的绿是假的。
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

void _writeSidecar(String dirPath, {String? provider, String? id, String? title, String? cover, String? coverFile, String? episodeId}) {
  File('$dirPath${Platform.pathSeparator}$kCacheSidecarName').writeAsStringSync(jsonEncode({
    'provider': provider,
    'id': id,
    'title': title,
    'cover': cover,
    'coverFile': coverFile,
    // ★★★ OPS-13 反馈 C ①：站点集 id（本地进度镜像到站点键时 episode_id 的值）
    if (episodeId != null) DownloadQueue.kSidecarEpisodeIdKey: episodeId,
  }));
}

/// 与生产外壳一致的包装（RefreshIndicator 需要 MaterialLocalizations）
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

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}


/// 屏幕上每张 `Image` 用的是哪个 provider（判据：owner 看到的是哪张图）
class _CoverPicks {
  _CoverPicks(this.fileImages, this.networkImages);

  /// 来自**盘上文件**的（FileImage / ResizeImage(FileImage)）
  final List<Object> fileImages;

  /// 来自**网络**的（NetworkImage / ResizeImage(NetworkImage)）
  final List<Object> networkImages;

  @override
  String toString() => 'file=$fileImages network=$networkImages';
}

/// 从一棵 `Image` 里挖出底层 provider（ResizeImage 会包一层）
Object? _providerOf(Image img) {
  Object? p = img.image;
  while (true) {
    if (p is ResizeImage) {
      p = p.imageProvider;
      continue;
    }
    return p;
  }
}

/// 真把「已缓存」页泵起来，把卡片上海报的图片来源收集回来
///
/// # 为什么必须 runAsync
/// 扫盘是**真碰盘**的真异步 IO；`t.pump` 走受控时钟，真实 IO 的 future 在
/// fake async 区里永不完成 ⇒ 页面永远停在 loading（上一轮探针假阴性的原因）。
Future<_CoverPicks> _pumpCachePage(
  WidgetTester t,
  String rootPath, {
  void Function(WidgetTester t)? before,
}) async {
  CachePage.debugScanRootOverride = rootPath;
  DownloadDir.setConfiguredDir(rootPath);

  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));

  await t.runAsync(() async {
    await t.pumpWidget(_appWith(
      home: const mui.Scaffold(body: CachePage()),
    ));
    for (var i = 0; i < 20; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    }
  });
  await t.pump();
  before?.call(t);

  final st = t.state<CachePageState>(find.byType(CachePage));
  debugPrint('RENDER 页面 loading=${st.debugLoading} error=${st.debugError} '
      'works=${st.debugWorkCount} loadCount=${st.debugLoadCount}');
  final file = <Object>[];
  final net = <Object>[];
  for (final img in t.widgetList<Image>(find.byType(Image))) {
    final prov = _providerOf(img);
    if (prov == null) continue;
    if (prov is FileImage) {
      file.add(prov);
    } else if (prov is NetworkImage) {
      net.add(prov);
    }
  }
  final texts = t.widgetList<Text>(find.byType(Text)).map((w) => w.data ?? '')
      .where((s) => s.isNotEmpty).toList();
  debugPrint('RENDER 屏幕文字：$texts');
  debugPrint('RENDER 海报来源：file=$file network=$net');

  // 收尾：走完 UiPrefs 的防抖落盘 timer，否则判「Timer is still pending」
  await t.pump(const Duration(milliseconds: 500));
  _claim(t);
  return _CoverPicks(file, net);
}
void main() {
  late Directory root;

  setUp(() {
    UiPrefs.remove(DownloadDir.kDirKey);
    DownloadDir.debugReset();
    debugClearCacheMetaMemo();
    // ★ 默认把查库这条路短路成空列表：真 API 要 FFI 核心，探针里没有，
    //   会一直等到 10 分钟超时（上一轮 ①-a 就是这么挂的）。
    //   要「命中」的用例自己再覆盖它。
    debugMetaFetchers = (
      history: () async => const <HistoryEntry>[],
      favorites: () async => const <Favorite>[],
    );
    CachePage.debugScanRootOverride = null;
    root = Directory(
      '${_sandboxRoot().path}${Platform.pathSeparator}case-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
  });

  tearDown(() {
    debugClearCacheMetaMemo();
    debugMetaFetchers = null;
    // ★ OPS-13 反馈 C ①：集号反查的注入点用完必须复位（否则污染同进程其它用例）
    debugProgressFetcher = null;
    CachePage.debugScanRootOverride = null;
    DownloadDir.debugReset();
  });

  tearDownAll(() {
    final d = Directory('${Directory.systemTemp.absolute.path}${Platform.pathSeparator}zz_cr_cache');
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径，实际 = ${d.path}');
    if (d.existsSync()) d.deleteSync(recursive: true);
    debugPrint('CLEANUP 已删除探针沙盒 ${d.path} 存在=${d.existsSync()}');
  });

  // ══════════════════════════════════════════════════════════════
  //  ① 卡片封面：盘上有封面文件就必须**画出来**
  //  （Owner 看到的是灰方块 + 只剩第一个字「无」）
  // ══════════════════════════════════════════════════════════════

  test('★ 扫盘：旁文件的 coverFile + 盘上的文件 ⇒ localCoverPath 解析出来',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    final png = _writeRealPng('$dir${Platform.pathSeparator}_sourin-cover.jpg');
    _writeSidecar(dir,
      provider: kBilibili,
      id: 'bv1xx411c7mD',
      title: kRealDirName,
      cover: kRealCover,
      coverFile: '_sourin-cover.jpg',
    );

    final works = await scanCacheWorks(root.path);
    expect(works.length, 1, reason: '★ 扫盘必须扫到那一部');
    final w = works.single;
    expect(w.localCoverPath, isNotNull,
        reason: '★★ 旁文件记了 coverFile 且文件真在盘上 ⇒ 必须解析出本地封面');
    expect(File(w.localCoverPath!).existsSync(), isTrue);
    expect(png.absolute.path, w.localCoverPath);
  });

  testWidgets('★★★ RED 卡片真渲染：那张海报必须是 **FileImage**（盘上的那张）',
      (t) async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    _writeRealPng('$dir${Platform.pathSeparator}_sourin-cover.jpg');
    _writeSidecar(dir,
      provider: kBilibili,
      id: 'bv1xx411c7mD',
      title: kRealDirName,
      cover: kRealCover,
      coverFile: '_sourin-cover.jpg',
    );

    final picks = await _pumpCachePage(t, root.path);
    debugPrint('RENDER 卡片上的图片来源：$picks');

    expect(picks.fileImages, isNotEmpty,
        reason: '★★★ Owner 原话「已缓存的也要显示原来的封面」\n'
            '盘上明明有 _sourin-cover.jpg，页面上却是一块灰方块。\n'
            'PosterCard 的 cover 只喂 Image.network ⇒ 本地文件从没被画过。');
  });

  test('★ 占位块只在**真的什么都没有**时出现（封面文件被删 ⇒ 退网络/占位）',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    // 旁文件说封面在这，但文件**不在**（被删/被移动）
    _writeSidecar(dir,
      provider: kBilibili,
      id: 'bv1xx411c7mD',
      title: kRealDirName,
      cover: null,
      coverFile: '_sourin-cover.jpg',
    );

    final works = await scanCacheWorks(root.path);
    expect(works.single.localCoverPath, isNull,
        reason: '★ 文件不在盘上 ⇒ 绝不能指着一个不存在的路径（否则卡片永远裂图）');
  });

  // ══════════════════════════════════════════════════════════════
  //  ② 来源：旁文件缺失时从库里找回（Owner：「显示原来源，而不是 local」）
  // ══════════════════════════════════════════════════════════════

  // ★ 业主真机的那个目录：**只有** mp4，**没有** _sourin-cache.json。
  //   下面的 ②-b / ②-c 就是照着它建的。
  test('★★ 旁文件缺失 + 库里命中 ⇒ CachedWork.provider 必须是原来源',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    expect(File('$dir${Platform.pathSeparator}$kCacheSidecarName').existsSync(), isFalse,
        reason: '★ 前置：本目录**没有**旁文件（= 业主真机的状态）');
    // 库里有一条同名记录（B 站）
    debugMetaFetchers = (
      history: () async => const [
        HistoryEntry(
          key: '$kBilibili:bv1xx411c7mD',
          provider: kBilibili,
          nativeId: 'bv1xx411c7mD',
          title: kRealDirName,
          cover: kRealCover,
          watchedAt: 1700000000,
        ),
      ],
      favorites: () async => const <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).single;
    expect(w.provider, kBilibili,
        reason: '★★ 没有旁文件时，来源必须**从库里找回**。'
            '找不回来才是「本地」（不猜）；找回来了却还是 null ⇒ '
            '详情页的「来源」只能显示 local（Owner 的原话）。');
    expect(w.mediaId, 'bv1xx411c7mD');
    expect(w.cover, kRealCover,
        reason: '★ 封面同样从库里找回（否则卡片是灰方块）');
  });

  test('★★ 旁文件有封面但**没有** provider ⇒ 也要去问库（原来白问）',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    _writeSidecar(dir, cover: kRealCover); // ★ 只有封面，没有 provider
    var asked = 0;
    debugMetaFetchers = (
      history: () async {
        asked++;
        return const [
          HistoryEntry(
            key: 'bilibili:bv1xx411c7mD',
            provider: kBilibili,
            nativeId: 'bv1xx411c7mD',
            title: kRealDirName,
            cover: kRealCover,
            watchedAt: 1700000000,
          ),
        ];
      },
      favorites: () async => const <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).single;
    expect(asked, 1, reason: '★ 判据只看封面空不空时，这条**根本不会去问库**');
    expect(w.provider, kBilibili,
        reason: '★★ 封面有、来源没有 ⇒ 来源仍然必须找回（来源标签要显示 B站）');
    expect(w.cover, kRealCover,
        reason: '★ 库里的封面绝不能把旁文件里已有的好封面**覆盖成 null**');
  });

  test('★ 库里也没有 ⇒ 来源留 null（不猜），由详情页显示「本地」',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    debugMetaFetchers = (
      history: () async => const <HistoryEntry>[],
      favorites: () async => const <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).single;
    expect(w.provider, isNull, reason: '★ 查不到就不猜');
    expect(w.cover, isNull);
    expect(w.localCoverPath, isNull);
  });

  // ══════════════════════════════════════════════════════════════
  //  ③ 播放请求：cover 优先本地文件 + 原来源透出
  // ══════════════════════════════════════════════════════════════

  test('★★★ 播放请求：cover 用本地文件，originProvider 透出 B站',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    final png = _writeRealPng('$dir${Platform.pathSeparator}_sourin-cover.jpg');
    _writeSidecar(dir,
      provider: kBilibili,
      id: 'bv1xx411c7mD',
      title: kRealDirName,
      cover: kRealCover,
      coverFile: '_sourin-cover.jpg',
    );

    final w = (await scanCacheWorks(root.path)).single;
    final req = buildLocalPlayRequest(w);
    expect(req, isNotNull);

    // ★ provider 恒为 local（续播命名空间不能动）；原来源是**另一个**字段
    expect(req!.provider, kLocalProvider,
        reason: '★ 续播主键必须仍是 local（改了旧进度全丢）');
    expect(req.originProvider, kBilibili,
        reason: '★★★ Owner 原话「要显示原来源，而不是 local」\n'
            '详情页那个「来源」标签要的是 originProvider，不是 provider。');
    expect(req.originMediaId, 'bv1xx411c7mD');
    expect(req.cover, png.absolute.path,
        reason: '★★ 进播放页要显示**盘上**那张（离线也在），不是那个网络 URL');
    expect(File(req.episodeAbsolutePath).existsSync(), isTrue);
  });

  test('★ 没有本地封面文件时 cover 退回网络 URL（不指空路径）',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    _writeSidecar(dir,
      provider: 'dandanplay',
      id: '36578',
      title: kRealDirName,
      cover: kRealCover,
    );

    final w = (await scanCacheWorks(root.path)).single;
    final req = buildLocalPlayRequest(w)!;
    expect(w.localCoverPath, isNull);
    expect(req.cover, kRealCover,
        reason: '★ 本地文件不在 ⇒ 用网络 URL，绝不能是 null（详情页会空白）');
    expect(req.originProvider, 'dandanplay', reason: '★★ 弹弹play 也要能显示出来');
  });

  test('★ 旁文件全缺 ⇒ originProvider 为 null（真不知道，不猜）',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集 第01集.mp4', 2 * 1024 * 1024);
    debugMetaFetchers = (
      history: () async => const <HistoryEntry>[],
      favorites: () async => const <Favorite>[],
    );

    final w = (await scanCacheWorks(root.path)).single;
    final req = buildLocalPlayRequest(w)!;
    expect(req.originProvider, isNull,
        reason: '★ 查不到来源时不猜（详情页据此显示「本地」，不显示错源）');
    expect(req.originMediaId, isNull);
    expect(req.cover, isNull);
  });


  // ═══════════════════════════════════════════════════════════════════
  //  OPS-13 反馈 C ①：站点集 id 从旁文件读进 CachedWork → 接进播放请求
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么是「读进 CachedWork」而不是只测 JSON 字段
  // ```text
  // 站点集 id 只在**下载那一刻**知道（DownloadTask.episodeId）——
  // 它必须一路流到 CachedPlayRequest.originEpisodeId，否则镜像进度那一步
  // 又被 CR-08 守卫跳过（本地与在线永远不同步）。
  // 这条从**真实扫盘的旁文件**读起，钉住整条读取链。
  // ```
  test('★★★ 旁文件带 episodeId ⇒ 扫进 CachedWork.originEpisodeId 并透出',
      () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集.mp4', 2 * 1024 * 1024);
    _writeSidecar(dir,
        provider: 'cycani',
        id: '3862',
        title: kRealDirName,
        episodeId: '51463');

    final w = (await scanCacheWorks(root.path)).single;
    debugPrint('OPS13-C 扫出的 siteEpisodeId=${w.originEpisodeId}');
    expect(w.originEpisodeId, '51463',
        reason: '★★★ 旁文件的 episodeId 必须读进 CachedWork —— '
            '它是镜像进度时 episode_id 的唯一来源');
    final req = buildLocalPlayRequest(w)!;
    expect(req.originEpisodeId, '51463',
        reason: '★★★ 必须透出到播放请求（单集目录 ⇒ 直接可用）');
    expect(req.originProvider, 'cycani');
  });

  test('★★ 旁文件**没有** episodeId ⇒ originEpisodeId 为 null（不猜）', () async {
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集.mp4', 2 * 1024 * 1024);
    _writeSidecar(dir, provider: 'cycani', id: '3862', title: kRealDirName);
    debugProgressFetcher = null;

    final w = (await scanCacheWorks(root.path)).single;
    expect(w.originEpisodeId, isNull,
        reason: '★★ 旁文件没记集号、库里也反查不到 ⇒ null ⇒ '
            '退化成「不写镜像」（宁可不同步，不张冠李戴）');
    expect(buildLocalPlayRequest(w)!.originEpisodeId, isNull);
  });

  test('★★★ 老下载兜底：无旁文件 ⇒ 按目录名去库反查集号', () async {
    // 业主真机的那种目录：只有 mp4，**没有** _sourin-cache.json
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集.mp4', 2 * 1024 * 1024);
    debugMetaFetchers = (
      history: () async => [
            HistoryEntry(
              key: 'cycani:3862',
              provider: 'cycani',
              nativeId: '3862',
              title: kRealDirName,
              position: 254,
              duration: 1800,
            ),
          ],
      favorites: () async => const <Favorite>[],
    );
    // ★ 反查集号：真 API 要 FFI 核心 ⇒ 注入（生产路径默认走 SourinApi.getProgress）
    debugProgressFetcher = (provider, id) async => Progress(
          key: '$provider:$id',
          provider: provider,
          nativeId: id,
          title: kRealDirName,
          episodeId: '51463',
          position: 254,
          duration: 1800,
        );

    final w = (await scanCacheWorks(root.path)).single;
    debugPrint('OPS13-C 老下载反查 siteEpisodeId=${w.originEpisodeId}');
    expect(w.provider, 'cycani', reason: '★ 前置：来源按目录名找回了');
    expect(w.originEpisodeId, '51463',
        reason: '★★★ 老下载（无旁文件）的兜底：按目录名去库反查同标题作品的'
            'progress.episode_id —— 这条是「无旁文件也不完全退化」的证据');
  });

  test('★★★ 老下载反查：progress 已被**别的一集**覆盖 ⇒ 必须放弃（不许污染）',
      () async {
    /*
     * ══════════════════════════════════════════════════════════════════
     *  CodeRabbit PR #15 点出的真缺陷（已核实），这条是它的回归门禁
     * ══════════════════════════════════════════════════════════════════
     *
     * # 缺陷机制
     *
     * ```text
     * progress 表按**作品**一行（key = provider:native_id），且 upsert 对
     *   episode_id 没有守卫 ⇒ 每次播放都覆盖
     * ⇒ getProgress() 返回的 episodeId = **最后一次在线看的那一集**
     *
     * 用户：下载了第 1 集（老下载，无旁文件） → 之后在线看到第 5 集
     *   目录名只匹配到**作品名**（不区分集）⇒ 取到第 5 集的 episode_id
     *   ⇒ localOriginEpisodeIdFor 对"单集目录"直接返回它
     *   ⇒ 镜像写入把**第 1 集本地文件**的进度写到**第 5 集**的站点集键上
     *   ⇒ 在线进度被静默污染
     * ```
     *
     * # 为什么旧代码抓不到
     *
     * 上面那条用例的注入 history 与 progress **位置完全一致**（都是 254/1800）
     * ⇒ 只覆盖了良性情形 ⇒ 有无守卫它都绿。
     *
     * # 本用例
     *
     * 刻意让二者**对不上**（history 是第 1 集的读数，progress 已被第 5 集覆盖）
     * ⇒ 期望 originEpisodeId **为 null**（放弃，让镜像写入跳过）。
     */
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集.mp4', 2 * 1024 * 1024);
    debugMetaFetchers = (
      history: () async => [
            HistoryEntry(
              key: 'cycani:3862',
              provider: 'cycani',
              nativeId: '3862',
              title: kRealDirName,
              // ★ 第 1 集的读数（本地那个文件就是第 1 集）
              position: 254,
              duration: 1800,
            ),
          ],
      favorites: () async => const <Favorite>[],
    );
    // ★ progress 已被**第 5 集**覆盖 —— 位置完全不同
    debugProgressFetcher = (provider, id) async => Progress(
          key: '$provider:$id',
          provider: provider,
          nativeId: id,
          title: kRealDirName,
          episodeId: '99999', // ← 第 5 集的站点集 id
          position: 900, // ← 与 history 的 254 对不上
          duration: 1800,
        );

    final w = (await scanCacheWorks(root.path)).single;
    debugPrint('OPS13-C(污染) 老下载反查 siteEpisodeId=${w.originEpisodeId}');
    expect(
      w.originEpisodeId,
      isNull,
      reason: '★★★ progress 的 (position,duration) 与 history 对不上 ⇒ '
          '说明那一行已被**别的一集**覆盖 ⇒ 必须**放弃**（返回 null）。'
          '若这里得到 "99999"，就是把第 1 集本地文件的进度写到第 5 集的'
          '站点集键上 ⇒ **在线进度被静默污染**',
    );
    expect(w.provider, 'cycani',
        reason: '★ 前置：来源仍按目录名找回了 —— 放弃的**只是集号**，不是来源');
  });

  test('★ 阴性对照：history 缺 position/duration ⇒ 同样放弃（不猜）', () async {
    // 找不到可比对的读数时也不许采纳 —— 与上一条同一裁决（宁可漏写不可写错）
    final dir = '${root.path}${Platform.pathSeparator}$kRealDirName';
    _writeBytes('$dir${Platform.pathSeparator}第01集.mp4', 2 * 1024 * 1024);
    debugMetaFetchers = (
      history: () async => [
            HistoryEntry(
              key: 'cycani:3862',
              provider: 'cycani',
              nativeId: '3862',
              title: kRealDirName,
              position: 0, // ★ 没有可信读数
              duration: 0,
            ),
          ],
      favorites: () async => const <Favorite>[],
    );
    debugProgressFetcher = (provider, id) async => Progress(
          key: '$provider:$id',
          provider: provider,
          nativeId: id,
          title: kRealDirName,
          episodeId: '51463',
          position: 254,
          duration: 1800,
        );

    final w = (await scanCacheWorks(root.path)).single;
    expect(
      w.originEpisodeId,
      isNull,
      reason: '★★ history 没有 position/duration ⇒ 无法确认是同一集 ⇒ '
          '返回 null（调用方退化成"不写镜像"）。**猜**的代价是静默污染在线进度',
    );
  });
}
