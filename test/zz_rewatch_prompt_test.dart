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
// # 本文件的十一条门禁（每条都做**撤销验证**：还原 ⇒ 变红）
//
// ```text
// ① 默认行为不变：缺省（没设偏好）⇒ 切集**不弹浮层**、从头播（_pendingSeek == null）
// ② 提示模式 + 该集看过 ⇒ **弹浮层**，且**不暂停**、播放继续
// ③ 提示模式 + 该集没看过 ⇒ **不弹**，从头播
// ④ 不操作 ⇒ 默认从头：超时后位置仍是 0（不是续播位置）
// ⑤ ★阴性对照：「继续观看」被点 ⇒ **确实** seek 到上次位置（两个动作真接线）
// ⑥ 快看完的不提示（position >= duration-10）⇒ 不弹
// ⑦ 设置入口：面板「切集起播」两选一真的接线（点「提示」回调带 prompt）
// ⑧ ★先过滤再挑选：镜像那条属于**别的集**且位置更大 ⇒ 不许连坐本集自己那条
// ⑨ ★代次守卫：慢的那次切集回来时（用户已切走）⇒ 不许弹过期浮层
// ⑩ ★mounted 守卫：切集停在 `_reload()` 的 await 上时页面被销毁 ⇒ 不许抛异常
// ⑪ ★会话被别的路径换掉：切集停在 `_reload()` 的 await 上时 `applySession`
//    送来另一个 provider 的同一集 ⇒ 不许弹浮层、也不许把旧流盖回去
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
import 'package:sourin_spike/ui/media_session.dart'; // 门禁⑪：拼 PlayRequestData
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

/// 门禁用假 `resolve_stream`：造出「有可播放候选」的世界
///
/// # 为什么门禁必须装它
/// ```text
/// `flutter test` 里没有核心层（`sourin_core.dll` 未加载），真 `resolve_stream`
/// 会抛 `SourinCoreException(other): 无法路由: cycani:rewatch-3862`；
/// `_reload()` 把它写进 `_error` ⇒ CR #22 ② 新增的 `_error == null` 守卫
/// **在门禁里恒为假** ⇒ 提示永远弹不出来，门禁分不出「守卫对」与「守卫写错」。
/// ```
/// ★ 只顶替**核心层传输**（`SourinCore.callAsync`），不顶替任何 UI 逻辑。
Future<List<StreamCandidate>> _fakeResolve(
  String provider,
  String id, {
  PlayRequest? req,
}) async =>
    [
      StreamCandidate(
        url: 'http://127.0.0.1:1/fake.m3u8',
        kind: 'hls',
        quality: '1080P',
      ),
    ];

/// 门禁⑨ 用：**第一次** `resolve_stream` 慢 400ms，之后立刻返回。
///
/// # 为什么需要它
/// ```text
/// 门禁⑨ 要制造**两次切集重叠**（第二次不等第一次就发出）——
/// 只有第一次那条路在 `_reload()` 里停住，第二次才能"后发先至"。
/// 停住的位置必须是 `_reload()` 里的 await（**不是**测试自己插的 sleep），
/// 否则测的是测试的时序，不是生产的时序。
/// ```
Future<List<StreamCandidate>> _fakeResolveSlowFirst(
  String provider,
  String id, {
  PlayRequest? req,
}) async {
  final n = ++_fakeResolveCalls;
  /*
   * ★★★ 把**请求里的集 id** 编进 url —— 这是门禁⑨/⑪ 唯一的"哪一集的流"读数。
   *
   * 为什么不另加一个探针：`debugPlayerStreamUrlsForProbe()` 已经是**只读**的
   * `_streams` 视图（本仓既有探针，见 player_page.dart:15312）。让 url 自带
   * 集 id，就等于「过期的那次 `_reload()` 有没有把 `_streams` 盖回去」直接
   * 可断言 —— 不必为测试在生产代码里再开一个后门字段。
   * ⚠️ 只改**慢的**这两个（门禁⑨⑩⑪ 专用）；`_fakeResolve` 仍是 /fake.m3u8。
   */
  final epId = req?.episodeId ?? 'none';
  /*
   * ★★★ 日志必须在 `await` **之前**记 —— 它记的是**请求发生的顺序**。
   *
   * 门禁⑪ 里两次请求的集 id 相同、provider 不同：旧会话那次先发（然后
   * 停 400ms），新会话那次晚 80ms 发却**先**返回。若把日志写在 `await`
   * 之后，记的就变成**完成顺序**（实测 = [othersrc/51464, cycani/51464]），
   * 于是"第一条必须是旧会话"这句自检会**误判**成失败 —— 被测行为其实
   * 是对的（`prompt=null`、`_streams` 已是新会话那份）。
   */
  _resolveLog.add('$provider/$epId');
  if (n == 1) {
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }
  return [
    StreamCandidate(
      url: 'http://127.0.0.1:1/$provider/$epId.m3u8',
      kind: 'hls',
      quality: '1080P',
    ),
  ];
}

/// 门禁⑩ 用：**第一次** `resolve_stream` 慢 1500ms —— 窗口足够宽，
/// 保证「拆页」这一步**确定**落在 `_reload()` 的 await 里面。
///
/// 为什么不用 `_fakeResolveSlowFirst` 的 400ms：拆页要等前面
/// `readRewatchProgress` + `_saveProgress` 两次 FFI 跑完才发得出去，
/// 400ms 的窗口**可能**在拆页前就结束了 ⇒ 门禁变成"测了个寂寞"
/// （实测过一次：改前的代码在那种时序下仍然全绿）。
Future<List<StreamCandidate>> _fakeResolveVerySlowFirst(
  String provider,
  String id, {
  PlayRequest? req,
}) async {
  final n = ++_fakeResolveCalls;
  if (n == 1) {
    await Future<void>.delayed(const Duration(milliseconds: 1500));
  }
  return [
    StreamCandidate(
      url: 'http://127.0.0.1:1/${req?.episodeId ?? "none"}.m3u8',
      kind: 'hls',
      quality: '1080P',
    ),
  ];
}

/// `_fakeResolveSlowFirst` 的调用计数（每个用例自己清零）
int _fakeResolveCalls = 0;

/// 门禁⑪ 用：**每一次** resolve 请求的 `provider/集id`（按发生顺序）
///
/// # 为什么必须记它
/// ```text
/// 门禁⑪ 要断言的是「**过期**的那次 `_reload()` 有没有把 `_streams` 盖回去」。
/// 但 `_streams` 只是一份当前值 —— 没有这份顺序日志，就分不清
/// ```
///   ① 现在这份 `_streams` 是**新会话**解析出来的（正确），还是
///   ② 旧会话那次**晚到**的解析结果（过期覆盖，正是要抓的缺陷）。
/// ```
/// 有了顺序日志 + url 里带 `provider/集id`（见 `_fakeResolveSlowFirst`），
/// 「谁写的最后一份」就直接可读。
/// ★ 仪器自检也靠它：断言第 1 条一定是**旧会话**发出的，
///   否则「换会话」发生在过期解析之前 ⇒ 门禁测了个寂寞。
final List<String> _resolveLog = <String>[];

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

  /// 门禁⑧ 用的「镜像来源」provider —— 只要求 **≠ 会话 provider**
  /// （`mirrorOriginFor` 只拒绝同 provider / local，见 progress_origin.dart:174-182）
  const mirrorProvider = 'mirrorx';

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
    // ★★ 门禁世界（两件必须一起装，见下面各自的说明）：
    //   ① 假 resolve_stream ⇒ `_reload()` 能拿到可播放候选；
    //   ② 跳过 `open()` ⇒ `_startPlayback()` 能**跑完**。
    //   两件缺一，`_gotoEpisode()` 都走不到末尾的 `_error == null` 守卫
    //   ⇒ 门禁②④⑤ 恒红（实测过，不是推测）。
    SourinApi.debugResolveStreamFetcher = _fakeResolve;
    debugPlayerSkipOpenForProbe = true;
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
    // ★ 门禁注入点必须复位：否则会漏到同进程里的其它用例（假绿/假红都可能）
    SourinApi.debugResolveStreamFetcher = null;
    _resolveLog.clear();
    debugPlayerSkipOpenForProbe = false;
    // 每个用例都从"空偏好"开始 —— 缺省 = 从头（门禁①测的正是它）
    UiPrefs.debugResetForTest();
  });

  /// 挂一个**在线会话**页（真 PlayerPage）—— episodes 非空、可切集
  ///
  /// [originProvider] / [originMediaId]：可选「镜像来源」（门禁⑧ 用）。
  /// ★ 只在**来源 provider ≠ 会话 provider** 时才会形成镜像目标
  ///   （判据在 `mirrorOriginFor`，本页不重写）—— 传同一个 provider 等于没传。
  Future<void> mountOnline(
    WidgetTester t, {
    String tag = 'x',
    String? originProvider,
    String? originMediaId,
  }) async {
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
        originProvider: originProvider,
        originMediaId: originMediaId,
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

  /// 造一条**任意键**的进度记录（门禁⑧ 用）
  ///
  /// 为什么要它：镜像那条住在**另一个 provider** 的键上
  /// （`mirrorOriginFor` 只拒绝「同 provider」，见 progress_origin.dart:174-182）
  /// ⇒ 必须能往 `atProvider:atId` 这个键上写。
  Future<void> seedProgressRaw(
    WidgetTester t, {
    required String atProvider,
    required String atId,
    required String episodeId,
    required String episodeTitle,
    required int position,
    int duration = 1320,
    String title = '追更剧',
  }) async {
    await t.runAsync(() => SourinApi.saveProgress(
          atProvider,
          atId,
          title: title,
          episodeId: episodeId,
          episodeTitle: episodeTitle,
          position: position,
          duration: duration,
        ));
    final back = await t.runAsync<Progress?>(
        () => SourinApi.getProgress(atProvider, atId));
    expect(back, isNotNull, reason: '★ 仪器自检：刚写的镜像进度必须真的读得回');
    expect(back!.episodeId, episodeId,
        reason: '★ 仪器自检：镜像那条的集号 = 刚写的那一集');
    debugPrint('REWATCH 种入镜像进度 at=$atProvider:$atId ep=$episodeId '
        'pos=${back.position}s/${back.duration}s');
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
    // ★ 环境态取证：`_error` / 候选数 / 浮层可见性一次打全 ——
    //   门禁②④⑤ 全都依赖「起播成功 + 浮层真的弹了」，这两件事必须在日志里可见。
    debugPrint('REWATCH 环境态：_error=${debugPlayerErrorForProbe()} '
        'streams=${debugPlayerStreamUrlsForProbe().length} '
        'promptVisible=${debugPlayerRewatchPromptVisible()}');
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

  // ══════════════════════════════════════════════════════════════════
  //  ⑧ 先过滤、再挑选（CR #22 ①）—— 跨集镜像不许连坐本集自己那条
  // ══════════════════════════════════════════════════════════════════
  group('⑧ 先过滤再挑选（跨集镜像不许压掉本集自己的记录）', () {
    testWidgets('★★★ 镜像那条是第2集且位置更大 ⇒ 仍按第3集自己那条提示', (t) async {
      // 本会话键：第3集看到 05:00（300s）
      await seedProgress(t, episodeId: ep3Id, position: 300);
      // 镜像键（另一个 provider）：第2集看到 16:40（1000s）—— 位置**更大**
      await seedProgressRaw(
        t,
        atProvider: mirrorProvider,
        atId: contentId,
        episodeId: ep2Id,
        episodeTitle: '第2集',
        position: 1000,
      );
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(
        t,
        tag: 'mirror-cross',
        originProvider: mirrorProvider,
        originMediaId: contentId,
      );
      debugPrint('REWATCH ⑧ 镜像目标=${debugPlayerMirrorOriginForProbe()}'
          '（必须是 $mirrorProvider:$contentId）');
      await gotoEp3(t);

      debugPrint('REWATCH ⑧ 跨集镜像：prompt='
          '${debugPlayerRewatchPromptForProbe()}');
      expect(debugPlayerRewatchPromptVisible(), isTrue,
          reason: '★★★ 本集自己那条（05:00）满足提示条件 ⇒ 浮层必须弹');
      expect(find.text('上次看到 05:00'), findsOneWidget,
          reason: '★★★ 取的是**本集自己**那条 —— 第2集那条 16:40 更大，'
              '但它属于另一集：既不许被选中，也不许把本集这条一起连坐丢掉');
      expect(find.text('上次看到 16:40'), findsNothing,
          reason: '★★ 第2集的位置绝不能显示成第3集的「上次看到」');
      await drainTimers(t);
    });

    testWidgets('★★ 镜像那条**同集**且位置更大 ⇒ 仍取镜像（不过度过滤）', (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 300);
      await seedProgressRaw(
        t,
        atProvider: mirrorProvider,
        atId: contentId,
        episodeId: ep3Id,
        episodeTitle: '第3集',
        position: 1000,
      );
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(
        t,
        tag: 'mirror-same',
        originProvider: mirrorProvider,
        originMediaId: contentId,
      );
      await gotoEp3(t);

      debugPrint('REWATCH ⑧ 同集镜像：prompt='
          '${debugPlayerRewatchPromptForProbe()}');
      expect(find.text('上次看到 16:40'), findsOneWidget,
          reason: '★★ 镜像那条**也是第3集**、位置更大 ⇒ 仍取镜像'
              '（过滤只该滤掉**别的集**，不许把同集的镜像一起滤掉）');
      expect(find.text('上次看到 05:00'), findsNothing,
          reason: '★ 同集时位置大的赢（pickResumeProgress 的既有语义）');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑨ 代次守卫（CR #22 ②）：后发先至的切集不许被慢的那次盖回去
  // ══════════════════════════════════════════════════════════════════
  group('⑨ 代次守卫（连续切集时过期的那次不许弹浮层）', () {
    testWidgets('★★★ 先切第3集（慢）→ 再切第2集（快）⇒ 不许弹第3集的 20:00',
        (t) async {
      // 库里只有一条：第3集看到 20:00（1200s）
      await seedProgress(t, episodeId: ep3Id, position: 1200);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'race');
      // ★ 挂载那次的 resolve 已经用掉「第一次」—— 之后才换成慢的
      SourinApi.debugResolveStreamFetcher = _fakeResolveSlowFirst;
      _fakeResolveCalls = 0;

      /*
       * ★★ 两次切集必须塌进**同一个** runAsync 回调：
       *    `runAsync` 明确禁止重入（binding.dart:3020 的
       *    `fail('Reentrant call to runAsync() denied.')`）⇒ 拆成两次调用
       *    会在第二次直接 fail。
       * ★ 停住的位置是 `_reload()` 里那个 `await resolveStream`（慢的假
       *    resolve 卡住它），**不是**测试自己插的 sleep。
       */
      await t.runAsync(() async {
        final f1 = debugPlayerGotoEpisodeForProbe(episodes[2]); // 第3集：读到 20:00
        await Future<void>.delayed(const Duration(milliseconds: 80));
        await debugPlayerGotoEpisodeForProbe(episodes[1]); // 第2集：后发先至
        await f1; // 等慢的那次收尾
      });
      await t.pump();
      while (t.takeException() != null) {}

      debugPrint('REWATCH ⑨ 竞态：prompt=${debugPlayerRewatchPromptForProbe()} '
          '可见=${debugPlayerRewatchPromptVisible()}');
      expect(debugPlayerRewatchPromptForProbe(), isNull,
          reason: '★★★ 第一次切集（第3集 20:00）在 `_reload()` 的 await 上停住'
              '期间用户又切到第2集 ⇒ 它回来时代次已变，**不许**再弹浮层'
              '（弹了就是 CR #22 ② 说的「旧调用把第一目标集的进度显示出来」）');
      expect(find.text('上次看到 20:00'), findsNothing,
          reason: '★★ 真实渲染里也不许出现第3集那个 20:00');
      /*
       * ★★★ CR #22 ⑤ 的另一半（过期的那次 `_reload()`）：
       *   上面那条断言只锁住「浮层不许弹」。但过期的那次调用**还**会
       *   把第3集的流重新起播（`_streams` 被它晚到的结果盖回去）——
       *   用户看到的就是「点了第2集，画面又跳回第3集」。
       *   慢 fetcher 把 `provider/集id` 编进了 url（见 `_fakeResolveSlowFirst`）
       *   ⇒ 这一条直接断言**哪一集的流在 `_streams` 里**。
       */
      debugPrint('REWATCH ⑨ 流=${debugPlayerStreamUrlsForProbe()}');
      expect(debugPlayerStreamUrlsForProbe().join('|'), contains('/$ep2Id.'),
          reason: '★★★ `_reload()` 里那句令牌核对必须挡住过期结果：'
              '第3集那次晚到的 resolve **不许**把 `_streams` 盖回去'
              '（摘掉那句 `if (token != _rewatchToken) return;` ⇒ 本条变红）');
      expect(debugPlayerStreamUrlsForProbe().join('|'), isNot(contains('/$ep3Id.')),
          reason: '★★ 过期那次的 url 不许出现在 `_streams` 里');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑩ 每个 await 之后都要 mounted 守卫（CR #22 ④）
  // ══════════════════════════════════════════════════════════════════
  group('⑩ 每个 await 之后都要 mounted 守卫', () {
    testWidgets('★★★ 切集停在 _reload 的 await 上时把页面拆掉 ⇒ 不抛异常',
        (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 1200);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'dispose');
      SourinApi.debugResolveStreamFetcher = _fakeResolveVerySlowFirst;
      _fakeResolveCalls = 0;

      /*
       * 拆页必须发生在**切集停在 `_reload()` 的 await 上**时：
       *   起播成功后 `_gotoEpisode` 的尾巴会调 `showRewatchPrompt`，
       *   而那时页面已经被销毁 ⇒ `setState() called after dispose()`。
       *
       * ★ 撤销验证的**实测归属**（这一步必须说清，否则门禁的名字会骗人）：
       * ```text
       * 只摘掉 `_reload()` 里那句 `if (!mounted) return;`   ⇒ 仍然全绿
       *   （`_reload` 的 setState 在 try 里，被自己的 catch 吞掉；
       *     catch 里那句 `if (mounted)` 让异常不外泄）
       * 同时摘掉 `_gotoEpisode` 尾部守卫的 `mounted` 与
       *   `showRewatchPrompt` 开头那句 `if (!mounted) return;`  ⇒ **变红**
       *   `setState() called after dispose(): _PlayerPageState#…(lifecycle
       *    state: defunct, not mounted, ticker inactive)`（实测原文）
       * ```
       * ⇒ 这两处 `mounted` 是**一对**：任一句在，本场景就不炸；
       *   两句都不在才炸。本门禁锁的是「这一对必须在」。
       */
      /*
       * ★★ 拆页必须发生在**真实异步区之外**：
       *   `runAsync` 内部 `pumpWidget` 不会真的把那棵旧树拆掉（实测：
       *   改前的代码在这一版门禁下**仍然全绿** ⇒ 这条门禁没有分辨力），
       *   所以把「起跑 + 等它停住」与「拆页 + 等它收尾」拆成两次
       *   `runAsync`（顺序调用，不违反重入禁令）。
       */
      late Future<bool> f1;
      await t.runAsync(() async {
        f1 = debugPlayerGotoEpisodeForProbe(episodes[2]);
        // ★ 等够 300ms：让 `readRewatchProgress` + `_saveProgress` 两次 FFI
        //   跑完、`_reload()` 已经发出 resolve（此后它会停 1500ms）——
        //   这样「拆页」就**确定**落在 `_reload()` 的 await 里面。
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      debugPrint('REWATCH ⑩ 拆页前：resolve 已发起 $_fakeResolveCalls 次'
          '（必须是 1 ⇒ 说明 _reload 正在等它）');
      expect(_fakeResolveCalls, 1,
          reason: '★★ 仪器自检：拆页必须发生在 _reload() 等 resolve 期间，'
              '否则这条门禁测不到 mounted 守卫');
      await t.pumpWidget(const SizedBox()); // 拆页 ⇒ dispose
      await t.runAsync(() => f1); // 让它带着「已销毁」跑完

      final err = t.takeException();
      debugPrint('REWATCH ⑩ 拆页后异常=$err');
      expect(err, isNull,
          reason: '★★★ 页面销毁后 `_reload()` 还在跑 ⇒ 必须靠 mounted 守卫'
              '提前返回；抛出来就是 setState-after-dispose');
      await drainTimers(t);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑪ 会话被**别的路径**换掉时，在途的切集链路要作废（CR #22 ⑥）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 与 ⑨ 的区别（两条门禁锁的是**不同**的漏洞）
  // ```text
  // ⑨：令牌由 `_gotoEpisode` 自己推 —— 抓的是「两次切集互相超车」。
  // ⑪：令牌由**会话替换路径**推（这里用 `applySession`）—— 抓的是
  //    「切集途中整个会话被换掉」。`_rewatchToken` 原来只在
  //    `_gotoEpisode` 里自增 ⇒ ⑨ 全绿也挡不住下面这一幕：
  //
  //      ① `_gotoEpisode(第3集)` 停在 `_reload()` 的 await 上；
  //      ② 合并页 `applySession` 送来**另一个 provider 的同一集**
  //         （`episodeIndex` 一样、`episodes` 里的 id 也一样）；
  //      ③ 新会话起播完成 ⇒ 旧调用的四道守卫**全部**通过
  //         （令牌没变 / mounted / `_error == null` / 集 id 相同）
  //         ⇒ 旧 provider 的「上次看到 20:00」弹在**新源**上，
  //            用户点「继续观看」就跳到错误位置。
  // ```
  //
  // # ★★ 撤销验证的实测结论（如实记录，别把归属写反）
  // ```text
  // A) 摘掉 `_reload()` 里那句 `if (token != _rewatchToken) return;`
  //    ⇒ ⑨ 与 ⑪ **都变红**（`_streams` 被过期那次盖回旧集）。
  //    ⇒ 本门禁（以及 ⑨）的**主判据**就是那句令牌核对。
  //
  // B) 只摘掉 `applySession` 里那句 `_rewatchToken++` ⇒ ⑪ **仍然全绿**。
  //    机制：`applySession` 在线支会走 `_resolveAndPlay`，而它也推令牌，
  //    且新会话那次假 resolve 立即返回 ⇒ 旧 `_reload()` 的 400ms 回来时
  //    令牌已经变了。⇒ 那句 bump 单独摘掉**测不出来**，它覆盖的是
  //    「新会话的 resolve 还没回来」这段窗口，以及**本地支**
  //    （`req.localPath != null` ⇒ `_bootLocalFile`，**不经**
  //    `_resolveAndPlay`）。本地支那句 bump 见 `_bootLocalFile` 开头。
  // ```
  //
  // ⇒ 会话替换路径上的 bump 共 4 处：`_bootLocalFile` / `applySession` /
  //    `_applySwitch`（直播换台）/ `_resolveAndPlay`；`_gotoEpisode` 自己
  //    在 `final rewatchToken = ++_rewatchToken;` 处也推。
  group('⑪ 会话被别的路径换掉时，在途的切集链路必须作废（CR #22 ⑥）', () {
    testWidgets('★★★ 切集停在 _reload 的 await 上时会话被换掉 ⇒ 不许弹浮层，也不许把旧流盖回去',
        (t) async {
      await seedProgress(t, episodeId: ep3Id, position: 1200);
      UiPrefs.debugResetForTest(
          {'dsh.playprefs.episodeStartAction': 'prompt'});

      await mountOnline(t, tag: 'session-swap');
      // ★ 挂载那次的 resolve 已经用掉「第一次」—— 之后才换成慢的
      SourinApi.debugResolveStreamFetcher = _fakeResolveSlowFirst;
      _fakeResolveCalls = 0;

      /*
       * ★★ 与 ⑨ 一样必须塌进**同一个** `runAsync` 回调（重入禁令）。
       * ★ 80ms：此刻 `_gotoEpisode` 已经过了 `readRewatchProgress` +
       *   `_saveProgress`，正停在 `_reload()` 的 `await resolveStream` 上
       *   （那一次的假 resolve 要 400ms 才返回）。
       */
      await t.runAsync(() async {
        final f1 = debugPlayerGotoEpisodeForProbe(episodes[2]); // 第3集：读到 20:00
        await Future<void>.delayed(const Duration(milliseconds: 80));
        /*
         * ★★★ 换会话走**生产方法** `applySession`（探针只是转发）。
         *   `isSameSessionAs` 的四元组是 provider/id/episodeId/sourceCode
         *   ⇒ 换 provider 必然判为「换会话」，不会被早退挡掉。
         *   `episodeIndex: 2` ⇒ 新会话的当前集**仍是第3集**
         *   （`_episodes[2].id == ep3Id`）—— 旧调用末尾那两道身份守卫
         *   （集 id 相同 / 令牌未变）在**改前**会全部通过，所以这条门禁
         *   才有分辨力。
         */
        final swapped = await debugPlayerApplySessionForProbe(PlayRequestData(
          provider: 'othersrc',
          id: contentId,
          title: '追更剧',
          episodeId: ep3Id,
          episodeTitle: '第3集',
          episodes: episodes,
          episodeIndex: 2,
        ));
        expect(swapped, isTrue, reason: '★ 仪器自检：页面必须还挂着，否则测不到换会话那条路');
        await f1; // 等慢的那次收尾
      });
      await t.pump();
      while (t.takeException() != null) {}

      /*
       * ★★ 仪器自检：第 1 条请求必须是**旧会话**（cycani）发出的。
       *   若「换会话」发生在它之前 ⇒ 过期解析根本没发生 ⇒ 本门禁
       *   测了个寂寞（会假绿）。
       */
      debugPrint('REWATCH ⑪ resolve 顺序=$_resolveLog '
          '流=${debugPlayerStreamUrlsForProbe()} '
          '会话=${debugPlayerSessionKeyForProbe()} '
          'prompt=${debugPlayerRewatchPromptForProbe()}');
      expect(_resolveLog.length, greaterThanOrEqualTo(2),
          reason: '★★ 仪器自检：必须真的发生了两次 resolve（旧会话那次 + 新会话那次）');
      expect(_resolveLog.first, '$provider/$ep3Id',
          reason: '★★ 仪器自检：第 1 条必须是旧会话 cycani 的第3集请求');
      expect(debugPlayerSessionKeyForProbe(), 'othersrc:$contentId',
          reason: '★★ 仪器自检：会话必须真的被换掉了');

      expect(debugPlayerRewatchPromptForProbe(), isNull,
          reason: '★★★ CR #22 ⑥：会话被换掉后，旧 provider 那次切集的'
              '「上次看到 20:00」**不许**弹在**新源**上（用户点「继续观看」'
              '会跳到错误位置）—— 靠会话替换路径上的 `_rewatchToken++` '
              '推大令牌 + `_reload()` 里那句令牌核对共同挡');
      expect(find.text('上次看到 20:00'), findsNothing,
          reason: '★★ 真实渲染里也不许出现那个 20:00');
      expect(debugPlayerStreamUrlsForProbe().join('|'), contains('/othersrc/'),
          reason: '★★ `_streams` 必须是**新会话**解析出来的那份');
      expect(debugPlayerStreamUrlsForProbe().join('|'), isNot(contains('/cycani/')),
          reason: '★★★ 旧会话那次晚到的 resolve 不许把 `_streams` 盖回去');
      await drainTimers(t);
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
