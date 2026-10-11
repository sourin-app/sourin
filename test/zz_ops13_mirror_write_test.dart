@Tags(['native-media'])
//
// ★ 本文件必须挂 native-media 标签：它 `MediaKit.ensureInitialized()` 加载真
//   libmpv-2.dll（flutter_tester 里偶发 native 崩溃，见 dart_test.yaml 顶部）。
//   手动跑：
//     flutter test test/zz_ops13_mirror_write_test.dart --run-skipped --tags native-media --concurrency=1
library;

// ═══════════════════════════════════════════════════════════════════════
//  OPS-13（反馈 C）**写入侧**：本地会话看完 ⇒ 真的多写一条「原来源」镜像
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 续播进度,我希望的是我缓存这集了,但是如果我在线看,他还能记得我看过
// > 而不是 本地和线上的就彻底分开了,你懂不
//
// # 本文件钉住什么（★ 行为，不是「源码里有没有那行字」）
//
// ```text
// ① 本地会话手上的「集号」是**文件名** ⇒ 不是站点集 id ⇒ **一条镜像都不写**
//    （写 episode_id=null 会把在线记录已有的集 ID 覆盖成 NULL；写文件名
//     又会被在线那条「按集校验」挡掉 —— 两条路都是坏的，见 CR-08）。
// ② 跳过镜像**不等于**跳过保存：会话自己那条（local 键）照常写。
// ③ 没有来源（老下载 / 手拷进来的目录）⇒ **一条都不写**（不猜）。
// ④ 端到端：站点键上那条**在线记录逐列不变**（作品标题 / 站点集 ID /
//    集标题 / 位置 / updatedAt 一个都不许被动）。
// ```
//
// # ★★ 本文件为什么**不**出现 `originEpisodeId`
//
// 那是**修复后**才有的形参。本文件要在**缺陷代码上也能编译** ——
// 否则「修复前红」只是一句编译错误，证明不了任何行为。
// ⇒ 「有站点集 id 时镜像真的写出去」那组正向契约放在
//   `test/t26_w4_mirror_site_id_test.dart`，并如实标注它是**编译期红**。
//
// # ★ 为什么必须真挂 PlayerPage、真调 _saveProgress()
//
// 本仓反复吃过「手抄副本与生产脱钩 ⇒ 测试全绿、生产是错的」的亏。
// 「镜像那条到底写没写出去、写成什么样」正是本任务的**全部内容**，
// 复刻一份写入逻辑等于把被测对象换成影子。
// ⇒ 走 debugPlayerSaveProgressForProbe()（它直接调生产的 _saveProgress）。
//
// ⚠️ 硬规则：数据目录指到 TEMP 沙盒，**绝不碰** %APPDATA% 下的用户真实库。

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/foundation.dart';
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

Widget _appWith(Widget home) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (c, child) =>
        AppThemeHost(data: theme, child: child ?? const mui.SizedBox()),
    home: home,
  );
}

/// 交付件里那颗 DLL —— `lib/core/ffi.dart:222-259` 的 Windows 分支只认**裸名**
/// `DynamicLibrary.open('sourin_core.dll')`（按 exe 所在目录 / PATH 找），
/// 而 flutter_tester.exe 的目录里没有它。
///
/// ★ 实测（2026-10-11）：**少了这一步本文件必然死在 setUpAll**
///   `Invalid argument(s): Failed to load dynamic library 'sourin_core.dll':
///    The specified module could not be found. (error code: 126)`
///   —— 因为 `SourinCore.startAsync` 的工作 isolate **不会**继承主 isolate
///   已经映射好的模块（`lib/core/ffi.dart:368-373` 的注释说 dlopen 幂等，
///   在 Windows 上对**裸名** open 不成立）。
///   ⇒ 先按**绝对路径**载进本进程，之后那次裸名 open 才命中已映射的模块。
///
/// 这条是 `test/task18_entry_test.dart:100-104` 与
/// `test/t96_emby_multisource_live_test.dart:93-107` 的既有做法。
const String _dllRel = r'build\windows\x64\runner\Release\sourin_core.dll';
final bool _dllReady = File(_dllRel).existsSync();

void _preloadCoreDll() {
  if (!_dllReady) return;
  DynamicLibrary.open(File(_dllRel).absolute.path);
  debugPrint('OPS13-W DLL 预加载 = OK（${File(_dllRel).absolute.path}）');
}

void main() {
  late Directory sandbox;
  late Directory caseDir;
  late String videoPath;
  late String localId;
  final mirrorCalls = <ProgressMirrorCall>[];

  setUpAll(() async {
    /*
     * ⓪ 真核心那颗 DLL 必须**先按绝对路径**载进本进程（见 _preloadCoreDll 的说明）
     */
    _preloadCoreDll();
    /*
     * ① libmpv：与 test/zz_t12_local_play_probe_test.dart 同一条（仓库自带 dll）。
     */
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
    /*
     * ② 真核心：**必须真的起来**。
     *
     * # 为什么不能省（实测推理）
     * ```text
     * saveProgressWithMirror 的第一件事就是**原样写会话自己的键**
     *   （await SourinApi.saveProgress(provider, id, …)）。
     * 核心没起来时这一句抛 SourinCoreException(unsupported) ⇒
     * 被 _saveProgress 的 catch 吞掉 ⇒ **镜像那一步根本走不到**
     * ⇒ 注入点一条记录都没有。
     * ★ 那时测试会红，但红的原因是**环境**而不是产品 ——
     *   所以这里必须把核心真的起起来，让红/绿都只反映产品行为。
     * ```
     */
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'ops13_write_${DateTime.now().microsecondsSinceEpoch}');
    sandbox.createSync(recursive: true);
    if (!SourinCore.isStarted) {
      await SourinCore.startAsync(sandbox.path);
    }
    debugPrint('OPS13-W 真核心 isStarted=${SourinCore.isStarted} '
        'sandbox=${sandbox.path}');
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (e) {
      // Windows 上 SQLite 文件可能还被核心持有 —— 删不掉不是失败
      debugPrint('OPS13-W 清理沙盒失败（不影响结论）: $e');
    }
  });

  setUp(() {
    /*
     * ★★ 掐掉 RemoteBridge 的轮询定时器（本仓播放器测试的既有做法，
     *    见 test/pc_arrow_keys_test.dart:220-233）。
     *
     * 它是**应用级**单例：播放页一挂上就开始 `_ensurePolling()`，
     * 而 flutter_test 在**每个用例结束时**断言「树上不许有未结束的计时器」：
     * ```text
     * A Timer is still pending even after the widget tree was disposed.
     * Failed assertion: line 2543 pos 12: '!timersPending'
     * ```
     * ⚠️ 实测（2026-10-10）：**只有第一条用例**红 —— 因为那个 400ms 的
     *    定时器在第一条用例期间被建起来，之后的用例复用了同一个单例。
     *    它不是产品缺陷（真机上它本来就该一直轮询），所以在这里掐掉。
     */
    RemoteBridge.instance.stop();
    /*
     * ★ 假 media_kit_video 通道（同 zz_t12_local_play_probe_test.dart）。
     *
     * flutter_tester 里没有视频输出插件 ⇒ VideoController(...) 会抛
     * MissingPluginException（**跑在 flutter_tester 里的固有事实**，不是产品缺陷）
     * ⇒ 从源头补上这个环境缺口，让真正的断言能被看见。
     */
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async {
        if (call.method == 'Create') return 'ops13-fake-texture';
        return null;
      },
    );
    addTearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel('com.alexmercerind/media_kit_video'),
        null,
      );
      debugProgressMirrorSink = null; // ★ 用完必须复位，否则污染同进程其它用例
      RemoteBridge.instance.stop();
    });

    caseDir = Directory('${sandbox.path}${Platform.pathSeparator}'
        'case-${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    videoPath = '${caseDir.path}${Platform.pathSeparator}第01集.mp4';
    final fixture = File('.probe${Platform.pathSeparator}t3_12'
        '${Platform.pathSeparator}fixture.mp4');
    if (fixture.existsSync()) fixture.copySync(videoPath);
    localId = canonicalLocalPath(videoPath);
    mirrorCalls.clear();
    debugProgressMirrorSink = (ProgressMirrorCall call) async {
      mirrorCalls.add(call);
      debugPrint('OPS13-W 镜像写入被拦截: $call');
    };
  });

  /// 挂一个**本地会话**的播放页（真 PlayerPage），再驱动真实写入路径
  ///
  /// ⚠️ 顺序（实测踩过）：pumpWidget 必须在**受控时钟**里，
  ///    真 FFI 才放进 runAsync。反过来的话页面没挂上 ⇒
  ///    _livePlayerState 是 null ⇒ 探针返回 false ⇒ 假绿。
  Future<void> mountLocal(
    WidgetTester t, {
    String? originProvider,
    String? originMediaId,
  }) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_appWith(mui.Scaffold(
      body: PlayerPage(
        provider: kLocalProvider,
        id: localId,
        title: '本地剧',
        /*
         * ★★★ 这一行必须与生产**逐字同形**。
         *
         * shell.dart 的 _openCachedWork 传的是 `req.episode.fileName`
         *   （形如 `第01集.mp4`）—— 本地会话的「集号」就是**文件名**。
         * 而镜像那条的标题正是从它推出来的（`mirrorProgressTitle`：
         *   没有集标题 ⇒ 文件名去后缀）。
         * ⚠️ 我第一版漏了这一行 ⇒ episodeId 为 null ⇒ 标题推不出来 ⇒
         *    `saveProgressWithMirror` 直接 return ⇒ 测试红，
         *    而红的原因是**夹具与生产不同形**，不是产品缺陷。
         *    记在这里：夹具必须照抄生产构造点的参数表。
         */
        episodeId: '第01集.mp4',
        localPath: videoPath,
        originProvider: originProvider,
        originMediaId: originMediaId,
      ),
    )));
    // 挂载期那条插件异常立刻收走（否则 testWidgets 记成失败）
    while (t.takeException() != null) {}
    await t.pump(const Duration(milliseconds: 50));
    while (t.takeException() != null) {}
  }

  /// 真跑一遍生产的 _saveProgress（走 runAsync，因为里面是真 FFI）
  ///
  /// ⚠️ 时长与位置**在同一次调用里**灌进去（见探针的说明）：
  ///    中间夹一次 `pump()` 会被真实的 `stream.duration` 事件冲掉 ⇒
  ///    `_saveProgress` 早退 ⇒ 测试把「环境没喂上」误判成「产品没实现」。
  Future<bool> driveSave(WidgetTester t) async {
    final mounted = debugPlayerSetDurationForProbe(const Duration(seconds: 100));
    expect(mounted, isTrue,
        reason: '★★★ 播放页没挂上（_livePlayerState 为 null）⇒ '
            '下面的读数全是空的（本仓最经典的假绿形态）');
    debugPlayerPushPositionForProbe(const Duration(seconds: 30));
    await t.pump(const Duration(milliseconds: 20));
    final ok = await t.runAsync<bool>(() => debugPlayerSaveProgressForProbe(
          duration: const Duration(seconds: 100),
          position: const Duration(seconds: 30),
        ));
    return ok ?? false;
  }
  group('① 写入侧：拿不到**站点集 id** ⇒ 一条镜像都不写（CR-08 的安全修复）', () {
    testWidgets('★★★ 真跑 _saveProgress ⇒ 镜像整条被跳过', (t) async {
      await mountLocal(t,
          originProvider: 'bilibili', originMediaId: 'BV1ops13write');
      debugPrint('OPS13-W 本会话会镜像到: '
          '${debugPlayerMirrorOriginForProbe()}');
      expect(debugPlayerMirrorOriginForProbe(), isNotNull,
          reason: '★ 前置：来源本身认得出来 —— 否则下面那条「跳过」'
              '分不清是「来源没认出来」还是「站点集 id 拿不到」');

      final ok = await driveSave(t);
      expect(ok, isTrue, reason: '★ 必须真的走到了 _saveProgress');

      debugPrint('OPS13-W 拦截到 ${mirrorCalls.length} 条镜像: $mirrorCalls');
      expect(mirrorCalls, isEmpty,
          reason: '★★★ 本地会话手上的「集号」是**文件名**（shell.dart 传 '
              'req.episode.fileName）⇒ 不是站点集 id ⇒ **必须整条跳过**：'
              '写 episode_id=null 会在 upsert_progress（store.rs 的 ON CONFLICT '
              '里 episode_id=excluded.episode_id，没有守卫）把在线记录已有的集 ID '
              '覆盖成 NULL；写文件名又会被在线那条「按集校验」挡掉。'
              '⇒ 「少写一条镜像」只是退化成今天的样子，'
              '「写坏一条在线记录」是不可逆的数据损坏 —— 两者不对等');
    });

    testWidgets('★★★ 跳过镜像**不等于**跳过保存：会话自己那条照常写', (t) async {
      await mountLocal(t,
          originProvider: 'bilibili', originMediaId: 'BV1ops13own');
      expect(await driveSave(t), isTrue);

      final own = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kLocalProvider, localId));
      debugPrint('OPS13-W 会话自己那条: key=${own?.key} pos=${own?.position}');
      expect(own, isNotNull,
          reason: '★★ 本地文件的观看进度必须能存能读 —— '
              '「跳过镜像」修的是镜像那条，不是会话自己那条');
      expect(own!.position, 30);
      expect(own.duration, 100);
    });
  });

  group('② 反面对照：没有来源 ⇒ 一条镜像都不写', () {
    testWidgets('★★★ originProvider/originMediaId 全缺 ⇒ 只写自己那条', (t) async {
      /*
       * ★ 这条是**反向**判据，防的是「无条件镜像」这种修法：
       *   老下载 / 手拷进来的目录**没有旁文件** ⇒ 真不知道来源 ⇒
       *   猜一个写进去会污染**别人的**播放记录。
       */
      await mountLocal(t);
      debugPrint('OPS13-W 无来源时会镜像到: '
          '${debugPlayerMirrorOriginForProbe()}');
      expect(debugPlayerMirrorOriginForProbe(), isNull,
          reason: '★ 没有来源时必须为 null（不猜）');

      expect(await driveSave(t), isTrue);
      expect(mirrorCalls, isEmpty,
          reason: '★★★ 没有来源时**一条都不许写** —— '
              '猜一个来源 = 污染别人作品的播放记录');
    });

    testWidgets('★★★ 来源就是 local ⇒ 也不写（那是原地重写自己）', (t) async {
      await mountLocal(t,
          originProvider: kLocalProvider, originMediaId: 'D:/a.mp4');
      expect(debugPlayerMirrorOriginForProbe(), isNull);
      expect(await driveSave(t), isTrue);
      expect(mirrorCalls, isEmpty);
    });
  });

  group('③ 端到端：站点键上那条在线记录**逐列不变**', () {
    testWidgets('★★★ 去掉注入点后，在线记录一个字都没被抹掉', (t) async {
      const originProvider = 'bilibili';
      const originMediaId = 'BV1ops13e2e';
      /*
       * ★ 这一步是「端到端」的硬证据：注入点只证明**调用了**，
       *   不证明**真的写进了库**（键拼错、参数名写错都照样绿）。
       * ⇒ 摘掉注入点，让 saveProgressWithMirror 走真 FFI。
       *
       * ★ 为什么先**种一条在线记录**：
       *   CR-08 的危害是「镜像把在线记录已有的集 ID 覆盖成 NULL」，
       *   只有站点键上**原本有**一条记录时才看得出来。
       *   空键上写一条 null 的镜像看起来完全正常 —— 那正是这个 bug
       *   在生产里活了这么久的原因。
       */
      debugProgressMirrorSink = null;

      final seeded = await t.runAsync<Progress?>(() async {
        await SourinApi.saveProgress(originProvider, originMediaId,
            title: '在线剧',
            episodeId: '51463',
            episodeTitle: '第03集',
            position: 600,
            duration: 1200);
        return SourinApi.getProgress(originProvider, originMediaId);
      });
      expect(seeded, isNotNull, reason: '★ 前置：在线那条种进去了');
      debugPrint('OPS13-W 种下的在线记录: title=${seeded!.title} '
          'episodeId=${seeded.episodeId} episodeTitle=${seeded.episodeTitle} '
          'pos=${seeded.position}/${seeded.duration} '
          'updatedAt=${seeded.updatedAt}');

      await mountLocal(t,
          originProvider: originProvider, originMediaId: originMediaId);
      expect(await driveSave(t), isTrue);

      final got = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(originProvider, originMediaId));
      debugPrint('OPS13-W 端到端读回: key=${got?.key} '
          'title=${got?.title} pos=${got?.position}/${got?.duration} '
          'episodeId=${got?.episodeId} episodeTitle=${got?.episodeTitle} '
          'updatedAt=${got?.updatedAt}');
      expect(got, isNotNull);
      expect(got!.title, '在线剧',
          reason: '★★★ 作品标题不许被本地那条的「第01集」顶掉（CR-07）—— '
              'detail_page._resolveLocalOrigin 正是按标题认回来源的');
      expect(got.episodeId, '51463',
          reason: '★★★ 站点集 ID 不许被抹成 NULL（CR-08）—— '
              '抹掉之后「按集校验」就永远放行任何一集了');
      expect(got.episodeTitle, '第03集',
          reason: '★★ 集标题同上，不许被顶成 null');
      expect(got.position, 600,
          reason: '★★ 在线看到哪儿就还是哪儿 —— 本地那条 30 秒不许顶掉它');
      expect(got.duration, 1200);
      expect(got.updatedAt, seeded.updatedAt,
          reason: '★★★ updatedAt 一个字都没变 = 这一行**根本没被写过** '
              '（不是「写了个差不多的值」）—— '
              'pickResumeProgress 正是按 updatedAt 挑较新的那条');

      // 会话自己的那条也必须在（既有行为逐字不变）
      final own = await t.runAsync<Progress?>(() =>
          SourinApi.getProgress(kLocalProvider, localId));
      debugPrint('OPS13-W 会话自己那条: key=${own?.key} pos=${own?.position}');
      expect(own, isNotNull,
          reason: '★★ 跳过镜像**不等于**跳过保存 —— 会话自己那条必须照写');
      expect(own!.position, 30);
      expect(own.duration, 100);
    });
  });
}
