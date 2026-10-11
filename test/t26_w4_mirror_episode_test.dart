@Tags(['native-media'])
//
// ★ 本文件必须挂 native-media 标签：它 `MediaKit.ensureInitialized()` 加载真
//   libmpv-2.dll（flutter_tester 里偶发 native 崩溃，见 dart_test.yaml 顶部）。
//   手动跑：
//     flutter test test/t26_w4_mirror_episode_test.dart --run-skipped --tags native-media --concurrency=1
library;

// ═══════════════════════════════════════════════════════════════════════
//  T26-W4：镜像进度的 title（CR-07）与 episodeId（CR-08）两条 CodeRabbit 线程
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件钉的是**行为**，不是「源码里有没有那行字」
//
// ```text
// CR-07（Major）：镜像把「集标题」写进了 progress.title（作品标题）。
//   rust/sourin_core/src/store.rs:932-947 的 upsert_progress 对**非空** title 是
//   覆盖写：title = CASE WHEN excluded.title <> '' THEN excluded.title ELSE title END
//   ⇒ 站点键上原本那条在线记录，作品标题被改成「第01集」
//   ⇒ lib/ui/detail_page.dart:1643-1760 的 _resolveLocalOrigin 按标题认源随之失效
//     ⇒ 来源 chip 退回「本地」。
//
// CR-08（Major）：镜像的 episode_id 恒为 null。
//   store.rs:939 是 episode_id=excluded.episode_id —— **没有** COALESCE 守卫
//   ⇒ 镜像写入把在线记录已有的集 ID 覆盖成 NULL
//   ⇒ 续播的「按集校验」（player_page.dart:3390 / progressBelongsToCurrentEpisode）失效
//   ⇒ 本地第 1 集的进度被在线第 3 集用上。
// ```
//
// # ★★ 为什么这一条必须真跑 SQLite（注入点不够）
//
// 注入点只能证明「**调用了**、参数是这些」；上面两条缺陷的**全部危害**都发生在
// 「落库之后」—— 覆盖写就在 `ON CONFLICT(key) DO UPDATE` 里。
// ⇒ 端到端那组**先种一条在线记录**（title=在线剧 / episode_id=51463 / pos=600），
//   再驱动本地会话写一次，然后**读回**那几列。
//
// # ★★ 为什么本文件**不**引用 `originEpisodeId` / `episodeTitle`
//
// 那两个名字属于**修复后**的 API。本文件要在**缺陷代码上也能编译**，
// 否则「修复前红」只是一句编译错误，证明不了任何行为。
// ⇒ 修复后才存在的契约放 `test/t26_w4_mirror_site_id_test.dart`。
//
// ⚠️ 硬规则：数据目录指到 TEMP 沙盒，**绝不碰** %APPDATA% 下的用户真实库。

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/progress_origin.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 站点键上**原本就有的**那条在线记录（模拟「用户先在线上看过第 3 集」）
const String kSiteProvider = 'bilibili';
const String kSiteMediaId = 'BV1t26w4mirror';
const String kSiteTitle = '在线剧';
const String kSiteEpisodeId = '51463';
const String kSiteEpisodeTitle = '第03集';
const int kSitePosition = 600;
const int kSiteDuration = 1200;

/// 本地会话手上那个「集号」——**文件名**，不是站点集 id
const String kLocalEpisodeFileName = '第01集.mp4';

/// 交付件里那颗 DLL —— `lib/core/ffi.dart:222-259` 的 Windows 分支只认**裸名**
/// `DynamicLibrary.open('sourin_core.dll')`（按 exe 所在目录 / PATH 找），
/// 而 flutter_tester.exe 的目录里没有它 ⇒ 必须先按**绝对路径**载进本进程，
/// 之后那次裸名 open 就命中已经映射好的模块。
///
/// ★ 这条是 `test/task18_entry_test.dart:100-104` 与
///   `test/t96_emby_multisource_live_test.dart:93-107` 的既有做法，
///   少了它 `SourinCore.startAsync` 必然抛
///   `Failed to load dynamic library 'sourin_core.dll' (error code: 126)`。
const String _dllRel = r'build\windows\x64\runner\Release\sourin_core.dll';
final bool _dllReady = File(_dllRel).existsSync();

void _preloadCoreDll() {
  if (!_dllReady) return;
  DynamicLibrary.open(File(_dllRel).absolute.path);
  debugPrint('T26W4 DLL 预加载 = OK（${File(_dllRel).absolute.path}）');
}

Widget _appWith(Widget home) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (c, child) =>
        AppThemeHost(data: theme, child: child ?? const mui.SizedBox()),
    home: home,
  );
}

void main() {
  late Directory sandbox;
  late Directory caseDir;
  late String videoPath;
  late String localId;
  final mirrorCalls = <ProgressMirrorCall>[];

  /// ★ 真核心起没起来 —— 决定「真跑」还是「如实跳过」
  ///
  /// `saveProgressWithMirror` 的第一件事就是真 FFI 写会话自己的键。
  /// 核心没起来时它会抛 `SourinCoreException` ⇒ 镜像那一步根本走不到
  /// ⇒ 那时测试红的原因**是环境而不是产品**（本仓最经典的假红）。
  var coreReady = false;
  var coreWhy = '';

  setUpAll(() async {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
    _preloadCoreDll();
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        't26w4_mirror_${DateTime.now().microsecondsSinceEpoch}');
    sandbox.createSync(recursive: true);
    try {
      if (!SourinCore.isStarted) {
        await SourinCore.startAsync(sandbox.path);
      }
      coreReady = SourinCore.isStarted;
      coreWhy = coreReady ? '核心已启动' : 'startAsync 返回了但 isStarted=false';
    } catch (e) {
      coreReady = false;
      coreWhy = e.toString();
    }
    debugPrint('T26W4 环境: coreReady=$coreReady why=$coreWhy '
        'sandbox=${sandbox.path}');
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('T26W4 清理沙盒失败（不影响结论）: $e');
    }
  });

  setUp(() {
    RemoteBridge.instance.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async {
        if (call.method == 'Create') return 't26w4-fake-texture';
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
      debugProgressMirrorSink = null;
      RemoteBridge.instance.stop();
    });

    caseDir = Directory('${sandbox.path}${Platform.pathSeparator}'
        'case-${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    videoPath = '${caseDir.path}${Platform.pathSeparator}$kLocalEpisodeFileName';
    localId = canonicalLocalPath(videoPath);
    mirrorCalls.clear();
    debugProgressMirrorSink = (ProgressMirrorCall call) async {
      mirrorCalls.add(call);
      debugPrint('T26W4 镜像写入被拦截: $call');
    };
  });

  /// 挂一个**本地会话**的播放页（真 PlayerPage），再驱动真实写入路径
  ///
  /// ⚠️ 参数表照抄生产构造点（shell.dart:4824-4850 的 _openCachedWork）：
  ///    本地会话的 `episodeId` **就是文件名**，`title` 是作品标题。
  Future<void> mountLocal(WidgetTester t) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_appWith(mui.Scaffold(
      body: PlayerPage(
        provider: kLocalProvider,
        id: localId,
        title: '本地剧',
        episodeId: kLocalEpisodeFileName,
        localPath: videoPath,
        originProvider: kSiteProvider,
        originMediaId: kSiteMediaId,
      ),
    )));
    while (t.takeException() != null) {}
    await t.pump(const Duration(milliseconds: 50));
    while (t.takeException() != null) {}
  }

  /// 真跑一遍生产的 _saveProgress（走 runAsync，因为里面是真 FFI）
  Future<bool> driveSave(WidgetTester t) async {
    final mounted = debugPlayerSetDurationForProbe(const Duration(seconds: 100));
    expect(mounted, isTrue,
        reason: '★★★ 播放页没挂上（_livePlayerState 为 null）⇒ '
            '下面的读数全是空的（本仓最经典的假绿形态）');
    debugPlayerPushPositionForProbe(const Duration(seconds: 30));
    await t.pump(const Duration(milliseconds: 20));
    while (t.takeException() != null) {}
    final ok = await t.runAsync<bool>(() => debugPlayerSaveProgressForProbe(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 30),
        ));
    return ok ?? false;
  }

  group('① 拿不到站点集 id ⇒ 跳过镜像写入（CR-08 的安全修复）', () {
    test('★★★ 会话手上的「集号」是**文件名** ⇒ 不是站点集 id ⇒ 一条镜像都不写',
        () async {
      if (!coreReady) {
        markTestSkipped('flutter_tester 起不了真核心（$coreWhy）—— '
            '`saveProgressWithMirror` 第一步就要真 FFI，这里如实跳过而不是假红');
        return;
      }
      await saveProgressWithMirror(
        provider: kProgressLocalProvider,
        id: 'D:/t26w4/$kLocalEpisodeFileName',
        title: '本地剧',
        // ★ 本地会话的「集号」= 文件名（shell.dart:4830 传 req.episode.fileName）
        episodeId: kLocalEpisodeFileName,
        position: 30,
        duration: 100,
        mirror: const ProgressOrigin(
            provider: kSiteProvider, mediaId: 'BV1t26w4skip'),
      );
      debugPrint('T26W4 无站点集 id 时拦截到 ${mirrorCalls.length} 条: $mirrorCalls');
      expect(mirrorCalls, isEmpty,
          reason: '★★★ 拿不到站点集 id 时**必须跳过**镜像写入 —— '
              '写 episode_id=null 会在 upsert_progress 里把在线记录已有的集 ID '
              '覆盖成 NULL（store.rs:939 没有守卫）⇒ 按集校验失效 ⇒ '
              '本地第 1 集的进度被在线第 3 集用上');
    });
  });

  group('② 端到端：站点键上原有的在线记录不被镜像抹掉', () {
    testWidgets('★★★ 本地看完一集之后，站点键那条的作品标题与集 ID 逐字不变',
        (t) async {
      if (!coreReady) {
        markTestSkipped('flutter_tester 起不了真核心（$coreWhy）—— '
            '本组全部读数来自真 SQLite，起不来就如实跳过而不是假红');
        return;
      }
      // ★ 摘掉注入点：注入点只证明「调用了」，不证明「真落库」
      debugProgressMirrorSink = null;

      final seeded = await t.runAsync<bool>(() async {
        await SourinApi.saveProgress(
          kSiteProvider,
          kSiteMediaId,
          title: kSiteTitle,
          episodeId: kSiteEpisodeId,
          episodeTitle: kSiteEpisodeTitle,
          position: kSitePosition,
          duration: kSiteDuration,
        );
        return true;
      });
      expect(seeded, isTrue);

      final before = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kSiteProvider, kSiteMediaId));
      expect(before?.title, kSiteTitle, reason: '★ 前置：种进去那条必须是可读的');
      expect(before?.episodeId, kSiteEpisodeId);

      await mountLocal(t);
      expect(await driveSave(t), isTrue, reason: '★ 必须真的走到了 _saveProgress');

      final got = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kSiteProvider, kSiteMediaId));
      debugPrint('T26W4 端到端读回: title=${got?.title} '
          'episodeId=${got?.episodeId} episodeTitle=${got?.episodeTitle} '
          'pos=${got?.position}/${got?.duration}');
      expect(got, isNotNull);
      expect(got!.title, kSiteTitle,
          reason: '★★★ 站点键上的**作品标题**不许被镜像的集标题覆盖 —— '
              '覆盖了之后 _resolveLocalOrigin 按标题认源失效、来源 chip 退回「本地」');
      expect(got.episodeId, kSiteEpisodeId,
          reason: '★★★ 站点键上的**站点集 ID**不许被镜像的 null 覆盖成 NULL');
      expect(got.episodeTitle, kSiteEpisodeTitle);
      expect(got.position, kSitePosition,
          reason: '★ 反向：跳过镜像**不等于**把会话自己的写入也跳过 —— '
              '在线那条的播放位置不该被本地会话的 30 秒改掉');

      // 会话自己的那条也必须在（既有行为逐字不变）
      final own = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kProgressLocalProvider, localId));
      debugPrint('T26W4 会话自己那条: key=${own?.key} pos=${own?.position}');
      expect(own, isNotNull,
          reason: '★★ 镜像只是**补充** —— 会话自己的那条不许因此丢');
      expect(own!.position, 30);
    });
  });
}
