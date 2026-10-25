@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  t27-w20：片头/片尾**自动跳过**「上一次真的会跳吗」的行为门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件守的那个从没被验证过的缺陷
//
// `lib/delivery_test.dart:1064` 原话：
// > 跳过片头  代码写了（_maybeSkip），但从没验证过"真的会跳"
//
// 核实到的代码事实（读代码 + 本文件实测两路印证）：
// ```text
// ① _maybeSkip 全仓**只有一个调用点**：挂在每秒 tick 的播放位置流上
// ② 起播顺序是 _startPlayback() → _loadSkipMarker()
//    ⇒ _startPlayback 返回后到标记到手前，位置流已经在跑，而 _skipMarker 仍是 null
//    ⇒ _maybeSkip 第 2 行 `if (m == null) return;` 早退
//    ⇒ 短片头 / 起播点落在区间内 ⇒ **整段漏跳**
// ③ 契约 PLAYER-CONTRACT.md:206-213 明确要求「canplay 里【再调一次】」
//    而 Flutter 版此前**没有**这第二次调用
// ```
//
// # 本文件的两类断言（缺一不可）
//
// ```text
// ① 行为 —— 真的驱动**真实 PlayerPage** 的 `_maybeSkip` 补判路径，
//    断言生产代码里 `_player.seek(...)` 真的被执行（探针计数 + 目标位置）
// ② 阴性对照 —— 没有标记 / autoSkip 关掉时，**不得**发生任何跳过 seek
//    （没有这条对照，任何"绿"都可能是"仪器恒真"）
// ```
//
// # ★ 关于 `native-media` 标签（如实说明一个 CI 空洞）
//
// 本文件构造**真实 PlayerPage**，它会 `MediaKit.ensureInitialized()` 加载
// **libmpv-2.dll**；实测该库在 flutter_tester 里会**偶发 native 崩溃**
// （见 `.probe/native-media-tests.md`）。所以照仓规打 `@Tags(['native-media'])`。
//
// ⚠️ **本仓 CI 跑裸 `flutter test`** ⇒ 带这个 tag 的文件**会被默认跳过**。
//    也就是说：这条门禁在 CI 里**不会自动跑**，需要手动
//    `flutter test test/t27_w20_skip_auto_seek_test.dart --tags native-media --concurrency=1`。
//    这是**已知的 CI 空洞**，本文件如实标注、不假装它被 CI 守着。
//
// # 数据隔离（硬约束）
//
// **绝不**碰用户真实库 `%APPDATA%\app.sourin.player`。
// 库读写那一环用一个隔离 `USERPROFILE` + 若可绑定则指 `sourin_core.dll`
// 的**真库**做"写得进 / 读得出"的往返；塞标记进播放页则走探针接缝
// （见 `debugPlayerSetSkipMarkerForProbe` 的说明，防脆/防慢）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
// ★ 审计 B9：缺 dll 的统一处置（Windows ⇒ fail；其它平台 ⇒ 点名 skip）
import 'support/core_gate.dart';

/// 挂真实 PlayerPage（桌面场景）—— 与 `pc_arrow_keys_test.mountPlayer` 同款。
///
/// 不 `pumpAndSettle`：播放器持续产生定时器/帧，settle 永不返回。
Future<void> mountPlayer(WidgetTester t, {String id = 'w20skip'}) async {
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: id,
        title: '跳过门禁',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

/// 把挂起的定时器在用例体内跑完（`_flash` 1.2s / 起播失败超时等）。
/// 必须在用例**返回之前**跑 —— 见 `pc_arrow_keys_test.drainTimers` 的注释。
Future<void> drainTimers(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

void main() {
  setUpAll(() {
    // libmpv 只在**存在时**加载（加载它会偶发 native 崩溃，故本文件带 tag）
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  // ═══════════════════════════════════════════════════════════════════
  //  〇 隔离库的往返：真的写得进、读得出（不跳过"库"这一环）
  // ═══════════════════════════════════════════════════════════════════

  group('〇 隔离库真的能写/读跳过标记（不碰用户真实库）', () {
    test('★★ setSkipMarker(intro=[0,3]) → getSkipMarker 读回逐字一致', () async {
      /*
       * 若测试进程里绑不上 sourin_core.dll（CI 裸环境），跳过本组 ——
       * **如实**标记 skip，不让"核心不可用"伪装成"库里写不进去"。
       *
       * ★★★ 2026-10-25（审计 B9）：改前这里是
       * ```dart
       * if (!hasCore) { markTestSkipped('本机无 sourin_core.dll（CI 裸环境）…'); return; }
       * ```
       * ⇒ **Windows 上把"仓库提交物缺失"写成了 skip**：CI 结论从红变绿
       *   （"有 N 项跳过"），"核心没同步"能一路混进发布。
       * 现在走统一处置：Windows ⇒ fail；其它平台 ⇒ skip 且点名缺什么 + 没校验到什么。
       */
      if (!requireCoreFiles(kCoreDllPaths, notVerified: '跳过标记的库往返（set/get）')) {
        return;
      }

      /*
       * 隔离数据目录：绝不能用用户真实库。
       * 核心的 dataDir 由调用方传入（见 rust sourin_core/src/ffi.rs），
       * 这里显式指到一个**临时**目录。
       * ⚠️ AppState::bootstrap 是**幂等**的（第二次直接返回），所以本文件里
       *    即便别的用例先启动过，也只会用第一次那个 dataDir。
       */
      final sandbox = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
        'sourin_w20_skip_${DateTime.now().microsecondsSinceEpoch}',
      )..createSync(recursive: true);
      addTearDown(() {
        try {
          sandbox.deleteSync(recursive: true);
        } catch (_) {}
      });

      String coreWs;
      try {
        final r = await SourinCore.startAsync(sandbox.path);
        coreWs = (r['dataDir'] ?? '').toString();
      } catch (e, st) {
        // ★ 审计 B9：改前是无条件 `markTestSkipped('核心启动失败（$e）…')`
        //   —— 那样连「核心自己报错」「FFI 契约坏了」也会变成 skip。
        //   现在只对 dlopen/符号缺失按平台处置，其余一律 fail。
        coreStartFailedThenSkip(e, st, notVerified: '跳过标记的库往返（set/get）');
        return;
      }
      /*
       * ★ 证明核心**真的用了隔离目录**（而不是用户真实库）。
       *
       * `sourin_start` 的返回 JSON 里**没有** dataDir 字段（只有
       * ok/version/deviceId/providers/thirdPartyProviders —— 见
       * `rust/sourin_core/src/ffi.rs:605-611`），所以不能从返回值断言。
       * 改用**落盘证据**：核心 bootstrap 会在 dataDir 下建 `plugins/` 并
       * 释放内置插件（实测日志：`已释放 IPTV 直播插件 -> <dataDir>/plugins/iptv.js`）。
       * ⇒ 隔离沙盒里出现 plugins/ 目录，就说明核心用的是这个沙盒。
       */
      final sandboxPlugins = Directory(
        '${sandbox.path}${Platform.pathSeparator}plugins',
      );
      expect(
        sandboxPlugins.existsSync(),
        isTrue,
        reason: '★ 核心必须把插件释放进隔离沙盒 ⇒ 证明它没写用户真实库'
            '（真实库目录绝不会有我们刚建的随机名沙盒路径）',
      );
      debugPrint(
        'T27W20 读数[〇]：核心已在隔离沙盒建 plugins/ (${sandbox.path})；'
        'sourin_start 返回的 dataDir 字段 = "$coreWs"'
        '（该键本就不存在，故不作断言 —— 隔离证据改用落盘的 plugins/）',
      );

      const p = 'cctv';
      const id = 'w20roundtrip';

      // 先清干净（幂等，防上一次残留）
      await SourinApi.clearSkipMarker(p, id);

      await SourinApi.setSkipMarker(
        p,
        id,
        title: 'T27-W20·片头跳过',
        introStart: 0,
        introEnd: 3,
        autoSkip: true,
      );
      final m = await SourinApi.getSkipMarker(p, id);
      expect(m, isNotNull, reason: '★★ 隔离库里必须真的读得回刚才写的标记');
      expect(m!.introStart, 0, reason: '片头起点必须逐字一致');
      expect(m.introEnd, 3, reason: '★ 片头终点 = 3（本文件断言"被 seek 到 3s"）');
      debugPrint('T27W20 读数：隔离库 getSkipMarker → '
          'intro=[${m.introStart},${m.introEnd}] autoSkip=${m.autoSkip}');

      await SourinApi.clearSkipMarker(p, id);
      expect(await SourinApi.getSkipMarker(p, id), isNull,
          reason: '★ 用例必须自己清干净（不留残留）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 阳性：标记在，位置落在片区 ⇒ 真的 seek 到 introEnd
  // ═══════════════════════════════════════════════════════════════════

  group('① 阳性对照：片头区命中 ⇒ 真的 seek 到 introEnd', () {
    testWidgets('★★★ 【A】canplay 补判 ⇒ 生产代码真的发出 seek(3s) 且弹「已跳过片头」',
        (t) async {
      await mountPlayer(t);
      expect(
        debugPlayerSkipSeekCalls(),
        isNotNull,
        reason: '★ 必须先挂上真实 PlayerPage —— 否则下面所有读数都是空的',
      );
      debugPlayerResetSkipProbe();

      expect(
        debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 3),
        isTrue,
        reason: '探针必须把标记塞进真实页面（false = 没挂页 ⇒ 判红）',
      );
      // 把"此刻位置在片区"摆好，**但不触发位置流**（见 setPositionOnly 的说明）
      expect(debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 1)), isTrue);

      /*
       * 驱动【A】的**生产方法** `_skipAfterCanplay()` ——
       * 就是 `_startPlayback` 里 `open()` 返回后**真正调用的那个**。
       * ⚠️ 不是测试里复刻一份：把它改成 no-op ⇒ 本用例立刻红（撤销验证）。
       */
      expect(debugPlayerSkipAfterCanplayForProbe(), isTrue);

      final calls = debugPlayerSkipSeekCalls();
      final target = debugPlayerLastSkipSeek();
      debugPrint('T27W20 读数[①-A]：skipSeekCalls=$calls '
          'lastSeek=${target?.inSeconds}s tip=${debugPlayerTipForProbe()}');

      expect(calls, 1, reason: '★★ 生产代码里 seek 那一行必须真的执行了一次');
      expect(
        target,
        const Duration(seconds: 3),
        reason: '★★★ 必须是 seek 到 **introEnd=3**，不是别的位置',
      );
      expect(
        debugPlayerTipForProbe(),
        contains('已跳过片头'),
        reason: '提示条文案也是用户可见证据（与 seek 同一条路径）',
      );

      await drainTimers(t);
    });

    testWidgets('★★★ 【B】标记到手后的补判 ⇒ 同样真的 seek 到 3s', (t) async {
      await mountPlayer(t, id: 'w20posB');
      debugPlayerResetSkipProbe();
      expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 3), isTrue);
      // "起播点落在区间内"：位置已 1s，且**没有**触发过位置流的 _maybeSkip
      expect(debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 1)), isTrue);

      /*
       * 驱动【B】的**生产方法** `_skipAfterMarkerLoad()` ——
       * 就是 `_loadSkipMarker()` 成功路径上真正调用的那个。
       * 把它改成 no-op ⇒ 本用例红（撤销验证）。
       */
      expect(debugPlayerSkipAfterMarkerLoadForProbe(), isTrue);

      final calls = debugPlayerSkipSeekCalls();
      debugPrint('T27W20 读数[①-B]：skipSeekCalls=$calls '
          'lastSeek=${debugPlayerLastSkipSeek()?.inSeconds}s');
      expect(calls, 1, reason: '★★ 【B】补判必须真的发出一次 seek');
      expect(
        debugPlayerLastSkipSeek(),
        const Duration(seconds: 3),
        reason: '★★★ 目标必须是 introEnd=3',
      );
      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 阴性对照（**这条是本文件的灵魂**）
  // ═══════════════════════════════════════════════════════════════════

  group('② 阴性对照：不该跳时**一次都不许跳**', () {
    testWidgets('★ 没有片头标记（_skipMarker == null）⇒ 不 seek', (t) async {
      await mountPlayer(t, id: 'w20nopmark');
      debugPlayerResetSkipProbe();
      // 不塞标记：_skipMarker 保持 null
      expect(debugPlayerMaybeSkipForProbe(const Duration(seconds: 1)), isTrue);
      debugPrint('T27W20 读数[②-a]：无标记 skipSeekCalls='
          '${debugPlayerSkipSeekCalls()}');
      expect(
        debugPlayerSkipSeekCalls(),
        0,
        reason: '★★ 没有标记就绝不 seek —— 这条不过说明计数器恒真，全文件作废',
      );
      await drainTimers(t);
    });

    testWidgets('★ 位置在片区外（10s，intro=[0,3]）⇒ 不 seek', (t) async {
      await mountPlayer(t, id: 'w20outside');
      debugPlayerResetSkipProbe();
      expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 3), isTrue);
      expect(debugPlayerMaybeSkipForProbe(const Duration(seconds: 10)), isTrue);
      debugPrint('T27W20 读数[②-b]：区间外 skipSeekCalls='
          '${debugPlayerSkipSeekCalls()}');
      expect(
        debugPlayerSkipSeekCalls(),
        0,
        reason: '★★ 10s 不在 [0,3) 内 ⇒ 不得触发片头跳',
      );
      await drainTimers(t);
    });

    testWidgets('★★ autoSkip 关掉 ⇒ 即使命中片区也不 seek', (t) async {
      /*
       * 「自动跳过片头」开关必须是真的闸门 —— 不是死开关。
       * 走生产路径关：UiPrefs 里那条 + `_autoSkip` 由 `_loadPrefs` 读入。
       * 但这里为了**不依赖偏好加载时序**，直接用探针关掉页面内的开关。
       */
      await mountPlayer(t, id: 'w20autoskipoff');
      debugPlayerResetSkipProbe();
      expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 3), isTrue);
      expect(debugPlayerSetAutoSkipForProbe(false), isTrue,
          reason: '探针必须能关掉页面内的自动跳过开关');
      expect(debugPlayerMaybeSkipForProbe(const Duration(seconds: 1)), isTrue);
      debugPrint('T27W20 读数[②-c]：autoSkip=off skipSeekCalls='
          '${debugPlayerSkipSeekCalls()}');
      expect(
        debugPlayerSkipSeekCalls(),
        0,
        reason: '★★ 开关关掉 ⇒ 命中片区也**不许**跳（否则那开关是死开关）',
      );
      await drainTimers(t);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 幂等：两次调用只跳一次（【A】+【B】不会重复跳）
  // ═══════════════════════════════════════════════════════════════════

  group('③ 幂等：补判两次也只跳一次', () {
    testWidgets('★★★ 【A】+【B】+ 位置流 tick ⇒ 合计只 seek 一次', (t) async {
      await mountPlayer(t, id: 'w20idem');
      debugPlayerResetSkipProbe();
      expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 3), isTrue);
      expect(debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 1)), isTrue);

      // 【A】的**生产方法**：canplay 补判（第一次跳）
      expect(debugPlayerSkipAfterCanplayForProbe(), isTrue);
      // 位置流随后照常 tick（每秒一次）—— 走生产 `_onPositionTick`
      debugPlayerPushPositionForProbe(const Duration(seconds: 1));
      debugPlayerPushPositionForProbe(const Duration(seconds: 2));
      // 【B】的**生产方法**：标记到手后再补判一次
      expect(debugPlayerSkipAfterMarkerLoadForProbe(), isTrue);

      final calls = debugPlayerSkipSeekCalls();
      debugPrint('T27W20 读数[③]：多次补判后 skipSeekCalls=$calls '
          'lastSeek=${debugPlayerLastSkipSeek()?.inSeconds}s');
      expect(
        calls,
        1,
        reason: '★★★ _introSkipped 守卫必须拦住后续补判/位置流 ⇒ 只跳一次',
      );
      await drainTimers(t);
    });
  });
}
