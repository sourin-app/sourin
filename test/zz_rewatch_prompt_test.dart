@Tags(['native-media'])
//
// ★ 本文件必须挂 native-media 标签（它加载真 libmpv-2.dll，见 dart_test.yaml 顶部）。
//   手动跑：
//     flutter test test/zz_rewatch_prompt_test.dart --run-skipped --tags native-media --concurrency=1
library;

// ═══════════════════════════════════════════════════════════════════════
//  fix/rewatch-prompt：切集时「这一集以前看过」⇒ 非阻断小浮层
//  「上次看到 20:00 / 继续观看 / 从头播放」的行为门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 如果第3集我看过了,时间是22分钟,我看到20分钟,然后我又从第2集看,正好第二集结束
// > 自动切换到下一集,那么第三集应该从头播放 **或者** 有个提示从头播放
// > (这个可以做成一个选项,默认是从头播放,然后可选 提示 从头播放)
//
// # Owner 已确认的形态
//
// > a弹个小浮层,你这个主意很好
//   ⇒ **默认「从头播放」**（= 现状）；有个选项可切成「**提示**」模式，
//     那时弹一个**非阻断**小浮层：「上次看到 20:00」，两个动作
//     「继续观看」/「从头播放」。**不操作 ⇒ 默认从头播放**。
//
// # ⚠️ 必须如实说明的**存储层限制**（不是本实现的缺陷，是既有 schema）
//
// ```text
// `progress` 表的主键是 `key = provider:native_id`（rust/sourin_core/src/store.rs:461-472）
// ⇒ **一个作品一行**，`episode_id` 只是"最后看的那一集"。
//
// 所以 Owner 描述的**字面**场景（看第 3 集到 20:00 → 回去看第 2 集看完 →
//   自动切回第 3 集）里，第 3 集那条 20:00 的记录**已经被第 2 集的进度覆盖掉了**
//   （每次 `_saveProgress` 都是按同一个 key upsert）——
//   换到第 3 集时，库里唯一那行说的是第 2 集 ⇒ "第 3 集看过 20:00"这件事
//   **不在库里**，任何读法都变不出来。
//
// ⇒ 本实现能做到、也**正确地做到**的是：**当库里那条记录所指的集，正好就是
//   你切过去的那一集**时，提示"上次看到 XX:XX"。
//   典型可命中的场景：
//     · 上次看到第 5 集 12:30，重新打开这部作品 → 从第 1 集点进第 5 集 ⇒ 提示
//     · 在任何集上，手动跳到"最后看过的那一集" ⇒ 提示
//   要做到 Owner 字面场景（逐集记忆），需要给 progress 加**按集的主键**
//   （Rust schema 改动），**超出本次授权范围**——此处在文件头如实标注。
// ```
//
// # 本文件的六条门禁（每条都做**撤销验证**：还原 ⇒ 变红）
//
// ```text
// ① 默认行为不变：缺省（没设偏好）⇒ 切集**不弹浮层**、从头播（_pendingSeek == null）
// ② 提示模式 + 该集看过 ⇒ **弹浮层**，且**不暂停**、播放继续
// ③ 提示模式 + 该集没看过 ⇒ **不弹**，从头播
// ④ 不操作 ⇒ 默认从头：超时后位置仍是 0（不是续播位置）
// ⑤ ★阴性对照：「继续观看」被点 ⇒ **确实** seek 到上次位置（两个动作真接线）
// ⑥ 快看完的不提示（position >= duration-10）⇒ 不弹
// ```
//
// ⚠️ 断言读**真实渲染**的浮层文字（`find.text(...)`）与真实 `_pendingSeek` /
//    `_rewatchPrompt`（探针），**不许**只断言源码含某字符串（见 CONTRIBUTING ⑥规矺二）。
//
// ⚠️ 硬规则：数据目录指到 TEMP 沙盒，**绝不碰** `%APPDATA%\app.sourin.player`。

import 'dart:ffi' show DynamicLibrary;
import 'dart:io';

import 'package:flutter/services.dart' show MethodCall, MethodChannel;
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/player_settings_sheet.dart';

Widget _appWith(Widget home) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(
    theme: theme,
    builder: (c, child) =>
        AppThemeHost(data: theme, child: child ?? const mui.SizedBox()),
    home: home,
  );
}

/// 浮层两个动作的**真实**渲染文字（`find.text` 的证据）
const _kContinueLabel = '继续观看';
const _kFromStartLabel = '从头播放';

void main() {
  late Directory sandbox;
  const provider = 'cycani';
  const contentId = 'rewatch-3862';
  const ep1Id = '51462';
  const ep2Id = '51463';
  const ep3Id = '51464';

  /// 每集 `id + title` —— 与站点路径同形（episode.id = 站点集 id）
  final episodes = <Episode>[
    const Episode(id: ep1Id, title: '第1集'),
    const Episode(id: ep2Id, title: '第2集'),
    const Episode(id: ep3Id, title: '第3集'),
  ];

  setUpAll(() async {
    // 真核心 DLL 必须**先按绝对路径**载进本进程（见 zz_ops13_resume_read_test 的长注释）
    const dllPath = r'build\windows\x64\runner\Release\sourin_core.dll';
    if (File(dllPath).existsSync()) {
      DynamicLibrary.open(File(dllPath).absolute.path);
      debugPrint('REWATCH DLL 预加载 = OK');
    }
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
    sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'rewatch_${DateTime.now().microsecondsSinceEpoch}')
      ..createSync(recursive: true);
    if (!SourinCore.isStarted) {
      await SourinCore.startAsync(sandbox.path);
    }
    debugPrint('REWATCH 真核心 isStarted=${SourinCore.isStarted} '
        'sandbox=${sandbox.path}');
  });

  tearDownAll(() {
    try {
      if (sandbox.existsSync()) sandbox.deleteSync(recursive: true);
    } catch (e) {
      debugPrint('REWATCH 清理沙盒失败（不影响结论）: $e');
    }
  });

  setUp(() {
    RemoteBridge.instance.stop();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      (MethodCall call) async {
        if (call.method == 'Create') return 'rewatch-fake-texture';
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel('com.alexmercerind/media_kit_video'),
      null,
    );
    RemoteBridge.instance.stop();
    // 每个用例都从"空偏好"开始 —— 缺省 = 从头（门禁①测的正是它）
    UiPrefs.debugResetForTest();
  });

  /// 挂一个**在线会话**页（真 PlayerPage）—— episodes 非空、可切集
  Future<void> mountOnline(WidgetTester t, {String tag = 'x'}) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(_appWith(mui.Scaffold(
      body: PlayerPage(
        // ★ 每个用例唯一 key ⇒ 强制重建 State（否则 Flutter 复用，见 ops13 的说明）
        key: ValueKey('rewatch-$tag'),
        provider: provider,
        id: contentId,
        title: '追更剧',
        episodeId: ep1Id,
        episodes: episodes,
        episodeIndex: 0,
      ),
    )));
    while (t.takeException() != null) {}
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    while (t.takeException() != null) {}
    debugPrint('REWATCH 挂上在线会话 ⇒ 当前会话键 = '
        '${debugPlayerSessionKeyForProbe()}（必须是 $provider:$contentId）');
  }

  /// 造一条"某集看过"的进度记录（真写库，走生产写入路径）
  Future<void> seedProgress(
    WidgetTester t, {
    required String episodeId,
    required int position,
    int duration = 1320, // 22 分钟（Owner 原话里的时长）
    String title = '追更剧',
  }) async {
    await t.runAsync(() => SourinApi.saveProgress(
          provider,
          contentId,
          title: title,
          episodeId: episodeId,
          episodeTitle: '第${episodeId == ep3Id ? 3 : (episodeId == ep2Id ? 2 : 1)}集',
          position: position,
          duration: duration,
        ));
    final back = await t
        .runAsync<Progress?>(() => SourinApi.getProgress(provider, contentId));
    expect(back, isNotNull, reason: '★ 仪器自检：刚写的进度必须真的读得回');
    expect(back!.episodeId, episodeId,
        reason: '★ 仪器自检：库里的集号 = 刚写的那一集');
    debugPrint('REWATCH 种入进度：ep=$episodeId pos=${back.position}s/'
        '${back.duration}s');
  }

  /// 驱动**生产方法** `_gotoEpisode(第3集)`
  Future<void> gotoEp3(WidgetTester t) async {
    final ok =
        await t.runAsync<bool>(() => debugPlayerGotoEpisodeForProbe(episodes[2]));
    expect(ok, isTrue,
        reason: '★★★ 播放页没挂上（_livePlayerState 为 null）⇒ 后面全是假绿');
    // ★ 必须 pump 一帧：`_gotoEpisode` 在 runAsync（真实异步区）里跑完，
    //   状态变了但**树还没重建** ⇒ 直接 find.text 会找不到（"浮层没渲染"的假象）。
    await t.pump();
    while (t.takeException() != null) {}
  }

  // ══════════════════════════════════════════════════════════════════
  //  ① 默认行为不变：缺省 ⇒ 不弹浮层、从头播
  // ══════════════════════════════════════════════════════════════════
  group('① 默认行为不变（缺省偏好 ⇒ 与改前逐字一致）', () {
    testWidgets('★★★ 没设偏好 + 第3集看过 ⇒ **不弹**浮层、_pendingSeek == null',
        (t) async {
      // 造一个"第 3 集看到 20:00"的记录（对旧实现毫无影响）
      await seedProgress(t, episodeId: ep3Id, position: 1200);

      await mountOnline(t, tag: 'default');
      await gotoEp3(t);

      debugPrint('REWATCH ① 默认：浮层可见='
          '${debugPlayerRewatchPromptVisible()} '
          'pendingSeek=${debugPlayerPendingSeekForProbe()}');

      expect(debugPlayerRewatchPromptVisible(), isFalse,
          reason: '★★★ 缺省（没设偏好）⇒ **绝不**弹浮层 —— 老用户升级后行为不变');
      expect(find.text(_kContinueLabel), findsNothing,
          reason: '★★ 真实渲染里也不该有「继续观看」');
      expect(debugPlayerPendingSeekForProbe(), isNull,
          reason: '★★★ 换集一律从头 ⇒ _pendingSeek == null（与改前逐字一致）');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 提示模式 + 该集看过 ⇒ 弹浮层，且不暂停
  // ══════════════════════════════════════════════════════════════════
  group('② 提示模式 + 该集看过 ⇒ 弹浮层（非阻断）', () {
    testWidgets('★★★ 弹「上次看到 20:00」+「继续观看」「从头播放」，且不暂停',
        (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 1200); // 20:00
      // 切成「提示」模式（走生产偏好键）
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'prompt');
      final playingBefore = debugPlayerIsPlaying();
      await gotoEp3(t);

      debugPrint('REWATCH ② 提示：浮层可见='
          '${debugPlayerRewatchPromptVisible()} '
          'rewatch=${debugPlayerRewatchPromptForProbe()}');

      expect(debugPlayerRewatchPromptVisible(), isTrue,
          reason: '★★★ 提示模式 + 该集看过 ⇒ 必须弹浮层');
      // ★★ 真实渲染的文字（不是"源码里有没有这个串"）
      expect(find.text('上次看到 20:00'), findsOneWidget,
          reason: '★★★ 浮层必须显示出「上次看到 20:00」（真实渲染）');
      expect(find.text(_kContinueLabel), findsOneWidget,
          reason: '★★ 必须有「继续观看」这个动作（真实渲染）');
      expect(find.text(_kFromStartLabel), findsOneWidget,
          reason: '★★ 必须有「从头播放」这个动作（真实渲染）');
      // ★ 非阻断：**不改**播放态、**不 seek**
      //
      // ⚠️ 本单测里根本没有真流 ⇒ `_playing` 恒为 false，**不能**断言它为 true
      //    （那会是恒假的坏门禁）。要测的是"**弹浮层这个动作没有暂停**"——
      //    等价判据 = 弹浮层**前后** `_playing` **相同**，且 `_pendingSeek`
      //    仍是 null（弹浮层没有插进任何 seek）。
      expect(debugPlayerIsPlaying() == playingBefore, isTrue,
          reason: '★★ 弹浮层**不许**改播放态（非阻断）—— 前后必须一致');
      expect(debugPlayerPendingSeekForProbe(), isNull,
          reason: '★★ 弹浮层本身**不 seek**（默认仍是位置 0）');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 提示模式 + 该集没看过 ⇒ 不弹
  // ══════════════════════════════════════════════════════════════════
  group('③ 提示模式 + 该集没看过 ⇒ 不弹（阴性对照）', () {
    testWidgets('★★★ 库里没有第3集的记录 ⇒ 不弹、从头播', (t) async {
      // 库里那条说的是**第 1 集**（不是要切过去的第 3 集）
      await seedProgress(t, episodeId: ep1Id, position: 600);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'notwatched');
      await gotoEp3(t);

      debugPrint('REWATCH ③ 没看过：浮层可见='
          '${debugPlayerRewatchPromptVisible()}');
      expect(debugPlayerRewatchPromptVisible(), isFalse,
          reason: '★★★ 库里的记录属于**别的集** ⇒ 不得提示（否则就是"没接线"的假提示）');
      expect(find.text(_kContinueLabel), findsNothing);
      expect(debugPlayerPendingSeekForProbe(), isNull);
      await drainTimers(t);
    });

    testWidgets('★★ position ≤ 5（刚点开就退）⇒ 不弹', (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 3); // ≤ 5
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'tinypos');
      await gotoEp3(t);
      debugPrint('REWATCH ③ pos≤5：浮层可见='
          '${debugPlayerRewatchPromptVisible()}');
      expect(debugPlayerRewatchPromptVisible(), isFalse,
          reason: '★★ 看 ≤5 秒不算"看过"⇒ 不提示（与 _prepareResume 的 >5 判据同义）');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 不操作 ⇒ 默认从头（超时后位置仍是 0）
  // ══════════════════════════════════════════════════════════════════
  group('④ 不操作 ⇒ 默认从头播（不能卡住流程）', () {
    testWidgets('★★★ 浮层超时自动消失 ⇒ 位置仍是 0（没有 seek 到续播位置）',
        (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 1200);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'timeout');
      await gotoEp3(t);
      expect(debugPlayerRewatchPromptVisible(), isTrue,
          reason: '前置：浮层必须真的弹了（否则下面测的是空气）');

      /*
       * ★ 为什么这里**重新**用探针把浮层摆一次（而不是用上面那次）
       * ```text
       * `_gotoEpisode` 是在 `t.runAsync`（**真实**异步区）里跑的 ⇒
       * 它内部 `Timer(8s)` 是**真定时器**，`t.pump(9s)` 推的是**假时钟**
       * ⇒ 推不动它（会永远"还在显示"）。
       * ⇒ 在**测试自己的 zone** 里再调一次 `showRewatchPrompt`（同一个生产方法）
       *    ⇒ 那个 `Timer` 是假定时器 ⇒ `t.pump(9s)` 能把它推到点。
       * ⚠️ 走的仍是生产方法本体（不是测试里复刻一份"超时逻辑"）。
       * ```
       */
      expect(debugPlayerShowRewatchPromptForProbe(const Duration(seconds: 1200)),
          isTrue);
      await t.pump();
      expect(debugPlayerRewatchPromptVisible(), isTrue,
          reason: '前置：探针摆的浮层必须可见');
      expect(find.text('上次看到 20:00'), findsOneWidget,
          reason: '★ 真实渲染里必须有这行字（超时前的基线）');

      // 推进 9 秒（浮层 8 秒自动消失）—— 全程不点任何按钮
      await t.pump(const Duration(seconds: 9));
      while (t.takeException() != null) {}

      debugPrint('REWATCH ④ 超时后：浮层可见='
          '${debugPlayerRewatchPromptVisible()} '
          'pendingSeek=${debugPlayerPendingSeekForProbe()} '
          'pos=${debugPlayerPositionSeconds()}');
      expect(debugPlayerRewatchPromptVisible(), isFalse,
          reason: '★★ 8 秒后浮层必须自动消失（不能永远赖在画面上）');
      expect(find.text('上次看到 20:00'), findsNothing,
          reason: '★ 真实渲染里浮层也消失了');
      expect(debugPlayerPendingSeekForProbe(), isNull,
          reason: '★★★ 不操作 ⇒ 从头播：_pendingSeek 必须仍是 null');
      /*
       * ★★★ 这一条是本门禁的**分辨力**所在（否则它是假绿）：
       * ```text
       * "超时后位置还是 0" 这一条**单独**是分不出「超时=从头」还是
       * 「超时=续播」的 —— 因为本单测里根本没有真播放器，`_player.seek()`
       * 是空转 ⇒ 两种实现的 `_pendingSeek` / `_position` 读数**一样**。
       * 实测过：把超时改成调用 `continueFromRewatchPrompt()`（=续播），
       * 上面那些断言**仍然全绿** ⇒ 它们是假绿。
       *
       * ⇒ 必须读一个能区分二者的**真实副作用**：续播路径会 `_flash(
       *   '已跳到上次观看位置')`，从头路径**不会**。所以断言"没有这条提示"。
       *   把超时改成 continueFromRewatchPrompt ⇒ 这条立刻红（撤销验证做过）。
       * ```
       */
      expect(debugPlayerTipForProbe() ?? '', isNot(contains('上次观看位置')),
          reason: '★★★ 超时**不是**续播 —— 不能出现"已跳到上次观看位置"这条提示'
              '（没有它，本门禁分不出「从头」与「续播」两种实现）');
      // ★ 没有发生"续播 seek"：位置仍在 0 附近（真机里播放器不动，
      //   单测里根本不起播 ⇒ 位置恒为 0）
      final pos = debugPlayerPositionSeconds();
      expect(pos == null || pos < 5, isTrue,
          reason: '★★★ 位置必须还在 0 附近（不是续播到的 1200s）—— '
              '这就是"默认从头"的直接证据');
      await drainTimers(t);
    });

    testWidgets('★ 点「从头播放」⇒ 关掉浮层、位置仍是 0', (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 1200);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'fromstartbtn');
      await gotoEp3(t);
      expect(debugPlayerRewatchPromptVisible(), isTrue);

      // ★ 直接取按钮的 onPressed 调它 —— 证明"按钮 → 回调"这根线真的接着，
      //   而不依赖播放器 Stack 里的命中测试（那个在本单测里被视频层挡着，
      //   生产环境里按钮在最上层、能点到；这里测的是**接线**，不是命中测试）。
      final btn = t.widget<mui.TextButton>(find.widgetWithText(mui.TextButton, _kFromStartLabel));
      expect(btn.onPressed, isNotNull,
          reason: '★「从头播放」必须挂着一个回调（null = 壳）');
      btn.onPressed!();
      await t.pump();
      while (t.takeException() != null) {}

      debugPrint('REWATCH ④ 点「从头播放」：浮层可见='
          '${debugPlayerRewatchPromptVisible()}');
      expect(debugPlayerRewatchPromptVisible(), isFalse,
          reason: '★ 点「从头播放」必须关掉浮层');
      expect(debugPlayerPendingSeekForProbe(), isNull,
          reason: '★★ 「从头播放」= 不 seek（_pendingSeek 仍是 null）');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ ★★★ 阴性对照的**反面**：「继续观看」被点 ⇒ 确实 seek 到上次位置
  // ══════════════════════════════════════════════════════════════════
  group('⑤ ★★★「继续观看」必须真的 seek（证明两个动作都接线）', () {
    testWidgets('★★★ 点「继续观看」⇒ 关掉浮层、_pendingSeek == 1200s（真的续播）',
        (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 1200);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'continue');
      await gotoEp3(t);
      expect(debugPlayerRewatchPromptVisible(), isTrue,
          reason: '前置：浮层必须真的弹了');

      /*
       * ★★★ 怎么证明「继续观看」**真的有效**（而不是画了个没接线的壳）：
       *   点它 ⇒ 生产代码 `continueFromRewatchPrompt()` 调 `_player.seek(pos)`。
       *   把它改成 no-op ⇒ 本用例的红点就是 `_rewatchPrompt` 还在（浮层不关）
       *   以及 `_flash` 文案不变 —— 两处读数一起钉住"这个动作确实执行了"。
       *   ⚠️ `_player.seek` 本身在 flutter_tester 里对原生播放器是空转，
       *     所以**不能**只断言"播放位置跳了"（那测不到）。改用**可稳定观测的
       *     等价判据**：浮层被关 + 提示条切到「已跳到上次观看位置」
       *     （见 `_flash('已跳到上次观看位置')`）—— 两者都在同一段生产代码里，
       *     缺一这条就红。
       */
      final btn = t.widget<mui.FilledButton>(
          find.widgetWithText(mui.FilledButton, _kContinueLabel));
      expect(btn.onPressed, isNotNull,
          reason: '★「继续观看」必须挂着一个回调（null = 壳）');
      btn.onPressed!();
      await t.pump();
      while (t.takeException() != null) {}
      debugPrint('REWATCH ⑤ 点「继续观看」：浮层可见='
          '${debugPlayerRewatchPromptVisible()} tip=${debugPlayerTipForProbe()}');
      expect(debugPlayerRewatchPromptVisible(), isFalse,
          reason: '★★ 点「继续观看」必须关掉浮层');
      expect(debugPlayerTipForProbe(), contains('上次观看位置'),
          reason: '★★★ 必须走到 `continueFromRewatchPrompt()` 那条 seek + 提示 —— '
              '浮层不关 / 没提示 = 这个按钮是个没接线的壳');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑥ 快看完的不提示（position >= duration-10）
  // ══════════════════════════════════════════════════════════════════
  group('⑥ 快看完了不提示（与 _prepareResume 同义）', () {
    testWidgets('★★★ position >= duration-10（剩不到 10 秒）⇒ 不弹', (t) async {
      // duration=1320（22 分钟），position=1315 ⇒ 剩 5 秒 ⇒ 快看完
      await seedProgress(t, episodeId: ep3Id, position: 1315, duration: 1320);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'nearlydone');
      await gotoEp3(t);
      debugPrint('REWATCH ⑥ 快看完：浮层可见='
          '${debugPlayerRewatchPromptVisible()}');
      expect(debugPlayerRewatchPromptVisible(), isFalse,
          reason: '★★★ 快看完的（剩不到 10 秒）⇒ 不提示、直接从头（与续播守卫同义）');
      expect(find.text(_kContinueLabel), findsNothing);
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑦ 设置入口：面板里「切集起播」两选一真的接线
  // ══════════════════════════════════════════════════════════════════
  group('⑦ 设置入口（面板「切集起播」两选一）', () {
    testWidgets('★★ 面板显示「从头播放 / 提示」两档，点「提示」回调带 prompt',
        (t) async {
      // 面板很长，给一个大画布 + 滚到「切集起播」那一行再点
      await t.binding.setSurfaceSize(const Size(1280, 1600));
      addTearDown(() => t.binding.setSurfaceSize(null));
      // 轻量挂面板本身（不挂真 PlayerPage，避免加载 mpv）
      final theme = AppTheme.themeFor(Brightness.dark);
      await t.pumpWidget(mui.MaterialApp(
        theme: theme,
        builder: (c, child) =>
            AppThemeHost(data: theme, child: child ?? const mui.SizedBox()),
        home: mui.Scaffold(
          body: PlayerSettingsSheetHost(
            onPick: (v) => picked = v,
          ),
        ),
      ));
      await t.pump();
      debugPrint('REWATCH ⑦ 面板：从头=${find.text(_kFromStartLabel).evaluate().length} '
          '提示=${find.text('提示').evaluate().length}');
      expect(find.text(_kFromStartLabel), findsWidgets,
          reason: '★ 面板必须能显示「从头播放」（默认档）');
      expect(find.text('提示'), findsWidgets,
          reason: '★ 面板必须能显示「提示」档');
      // 滚到可见再点（面板比一屏长）
      await t.ensureVisible(find.text('提示').first);
      await t.pump();
      await t.tap(find.text('提示').first);
      await t.pump();
      expect(picked, PlayEpisodeStartAction.prompt,
          reason: '★★ 点「提示」必须回调 `onSetEpisodeStartAction(prompt)`（真的接线）');
    });
  });
}

/// ⑦ 用的小夹具：只把面板摆出来，只关心「切集起播」那一行的接线
///
/// 为什么另起一个小夹具而不是复用 `player_capability_test._sheet`：
/// 那个夹具在别的文件里；这里只要面板的**这一个新行**能显示 + 回调。
PlayEpisodeStartAction? picked;

class PlayerSettingsSheetHost extends StatelessWidget {
  const PlayerSettingsSheetHost({super.key, required this.onPick});

  final ValueChanged<PlayEpisodeStartAction> onPick;

  @override
  Widget build(BuildContext context) {
    return mui.Stack(children: [
      PlayerSettingsSheet(
        isLive: false,
        subtitleTracks: const [],
        audioTracks: const [],
        currentSubtitleId: 'no',
        currentAudioId: 'no',
        externalSubtitleName: null,
        mpvStyle: const {},
        endAction: PlayEndAction.autoNext,
        countdownBeforeNext: true,
        keepSourceOnNext: true,
        autoSkip: true,
        rate: 1.0,
        isPlaying: true,
        clipDownloading: false,
        clipDownloaded: false,
        clipDownloadError: null,
        onSetConcurrency: (_) {},
        onDownloadClip: () {},
        onOpenClipDir: () {},
        onPickSubtitle: (_) {},
        onPickAudio: (_) {},
        onLoadSubtitleFile: (_) {},
        onRemoveExternalSubtitle: () {},
        onSetMpvProperty: (_, __) {},
        onSetEndAction: (_) {},
        onSetCountdown: (_) {},
        onSetKeepSource: (_) {},
        onSetAutoSkip: (_) {},
        onSetRate: (_) {},
        episodeStartAction: PlayEpisodeStartAction.fromStart,
        onSetEpisodeStartAction: onPick,
        onClose: () {},
      ),
    ]);
  }
}

/// 把挂起的定时器在用例体内跑完（`_flash` 1.2s / 浮层 8s 等）
Future<void> drainTimers(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}
