@Tags(['native-media'])
library;

// ═══════════════════════════════════════════════════════════════════════
//  PR #10：过期的片头标记响应**不许**污染新的播放会话
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷（CodeRabbit 在 PR #10 上点出，已核实成立）
//
// `_loadSkipMarker()` 里那一步是 `await` 的，而**换集 / 换源 / 换会话**
// 三条路都会把 `_skipMarker` 清成 null 并重新起播。于是：
//
// ```text
// t0  第 1 集起播 ⇒ _loadSkipMarker() 发出请求（await 中）
// t1  用户立刻切到第 2 集 ⇒ 清 _skipMarker、_startPlayback
// t2  t0 那次请求这才返回**第 1 集**的标记
//     ⇒ setState(_skipMarker = 第1集的标记)   ← 污染了第 2 集
//     ⇒ _skipAfterMarkerLoad() 用第1集的片头秒数去 seek 第 2 集
// ```
//
// 用户可见后果：切集/换源后「画面莫名跳到某个位置」或「片头没跳成」。
// `mounted` 拦不住 —— widget 一直挂着，只是"会话"变了。
//
// # 修法
//
// 单调递增的会话代次 `_playSessionGen`：发请求前记下，返回后核对；
// 不一致就**丢弃**（不 setState、不补判）。三条切换路径各 `++` 一次。
//
// # 本文件为什么打 `native-media` 标签
//
// 它挂**真实 PlayerPage** ⇒ 会 `MediaKit.ensureInitialized()` 加载 libmpv，
// 而该库在 flutter_tester 里会偶发 native 崩溃（本仓已知，见
// `.probe/native-media-tests.md`）。照仓规打 tag。
// ⚠️ 后果：**裸 `flutter test` 会跳过本文件**（CI 空洞，如实标注）。
//    跑法（★ `--run-skipped` **不能漏** —— 少了它等于一条都没跑）：
//    `flutter test test/zz_pr10_stale_skip_marker_test.dart --run-skipped --tags native-media --concurrency=1`
//
// # 数据隔离
//
// **绝不**碰用户真实库。标记的取数走 `SourinApi.debugSkipMarkerFetcher`
// 注入（生产路径永为 null ⇒ 生产逐字不变）。

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 挂真实 PlayerPage（与 t27_w20 同款）。
/// 不 `pumpAndSettle`：播放器持续产生定时器/帧，settle 永不返回。
Future<void> mountPlayer(WidgetTester t, {String id = 'pr10skip'}) async {
  await t.pumpWidget(
    MaterialApp(
      home: PlayerPage(
        provider: 'cctv',
        id: id,
        title: '过期标记门禁',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  );
  for (var i = 0; i < 6; i++) {
    await t.pump(const Duration(milliseconds: 50));
  }
}

Future<void> drainTimers(WidgetTester t) async {
  for (var i = 0; i < 40; i++) {
    await t.pump(const Duration(seconds: 3));
  }
  RemoteBridge.instance.stop();
}

SkipMarker marker(int introEnd) => SkipMarker(
      key: 'cctv:pr10skip',
      provider: 'cctv',
      nativeId: 'pr10skip',
      title: '过期标记门禁',
      introStart: 0,
      introEnd: introEnd,
      outroStart: null,
      outroEnd: null,
      autoSkip: true,
      updatedAt: 0,
    );

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() {
    SourinApi.debugSkipMarkerFetcher = null; // ★ 不留注入，免得影响后续用例
    RemoteBridge.instance.stop();
  });

  group('PR #10 过期片头标记', () {
    testWidgets('★★★ 会话已变 ⇒ 迟到的标记**不许**写进当前会话（核心回归）',
        (t) async {
      final completer = Completer<SkipMarker?>();
      SourinApi.debugSkipMarkerFetcher = (p, id) => completer.future;

      await mountPlayer(t);
      final genBefore = debugPlayerSessionGenForProbe();
      expect(genBefore, isNotNull, reason: '★ 仪器自检：必须挂上了 PlayerPage');

      // ① 发起取标记（会停在 await —— completer 还没完成）
      final pending = debugPlayerLoadSkipMarkerForProbe();
      await t.pump();

      // ② 模拟"用户切集/换源"⇒ 会话推进一代（走生产字段 + 生产清理动作）
      expect(debugPlayerBumpSessionForProbe(), isTrue);
      final genAfter = debugPlayerSessionGenForProbe();
      expect(genAfter, genBefore! + 1,
          reason: '★ 仪器自检：bump 真的让代次 +1（否则下面的断言是空的）');
      await t.pump();

      // ③ **现在**才让那个迟到请求返回第 1 集的标记
      completer.complete(marker(33));
      await pending;
      await t.pump();

      // ④ 断言：当前会话的 _skipMarker **仍是 null**（过期响应被丢弃）
      expect(
        debugPlayerSkipMarkerForProbe(),
        isNull,
        reason: '★★★ 换会话后迟到的标记必须被**丢弃** —— '
            '若这里非 null，说明旧集的片头秒数污染了新会话，'
            '而紧接着的 _skipAfterMarkerLoad() 会用它去 seek 新播放',
      );

      await drainTimers(t);
    });

    testWidgets('★ 阴性对照：会话**没变**时，标记必须照常写进去', (t) async {
      final completer = Completer<SkipMarker?>();
      SourinApi.debugSkipMarkerFetcher = (p, id) => completer.future;

      await mountPlayer(t);
      final pending = debugPlayerLoadSkipMarkerForProbe();
      await t.pump();

      // ★ 不 bump —— 会话没变，响应应当被采纳
      completer.complete(marker(33));
      await pending;
      await t.pump();

      final m = debugPlayerSkipMarkerForProbe();
      expect(
        m,
        isNotNull,
        reason: '★★ 阴性对照：会话没变时**必须**采纳 —— '
            '否则这个"丢弃"逻辑会把**所有**标记都丢掉（功能直接坏掉）',
      );
      expect(m!.introEnd, 33, reason: '★ 值也要对（不是随便塞了一个）');

      await drainTimers(t);
    });

    testWidgets('★★ 阳性对照：同一会话内**第二次**请求仍然生效（丢弃不是一次性的）',
        (t) async {
      SourinApi.debugSkipMarkerFetcher = (p, id) async => marker(11);
      await mountPlayer(t);

      await debugPlayerLoadSkipMarkerForProbe();
      await t.pump();
      expect(debugPlayerSkipMarkerForProbe()?.introEnd, 11);

      // 再取一次（换标记值）—— 同会话，必须更新
      SourinApi.debugSkipMarkerFetcher = (p, id) async => marker(22);
      await debugPlayerLoadSkipMarkerForProbe();
      await t.pump();
      expect(
        debugPlayerSkipMarkerForProbe()?.introEnd,
        22,
        reason: '★ 同会话内后续请求必须照常生效（代次只在**切换**时变）',
      );

      await drainTimers(t);
    });

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ CodeRabbit PR #10 第二轮：换集后**位置也必须复位**
     * ══════════════════════════════════════════════════════════════════
     *
     * 我给「会话代次」加的三处 `++` 只清了 `_skipMarker`，**没清 `_position`**。
     * 而 `_currentSkipProbePosition()` 取的是
     * `max(_player.state.position, _position)` ⇒ 换集后补判**读到上一集的位置**：
     * ```text
     * 第 1 集播到 1200s ⇒ _position = 1200
     * 切到第 2 集（短集，outroStart = 600）⇒ 补判读到 1200 ≥ 600
     * ⇒ 命中片尾分支 ⇒ **刚起播就弹"下一集"倒计时**
     * ```
     * ⇒ 修法：三处切换路径与 `_playSessionGen++` **一起**把 `_position` 归零。
     */
    testWidgets('★★★ 换会话后不许用上一集的位置误触发片尾倒计时', (t) async {
      await mountPlayer(t);

      /*
       * ★ 必须**先造出"有下一集"** —— `_startNextCountdown()` 第一行是
       *   `if (_nextEpisode == null) return;`，而 `_nextEpisode` 要求
       *   `_episodes` 里 ≥2 集。
       *   ⚠️ 少了这一步，倒计时**天然不会启动** ⇒ 用例恒绿（假绿）。
       *   （我第一版就漏了它，红度证明时被抓住。）
       */
      expect(
        debugPlayerSetEpisodesForProbe(const [
          Episode(id: 'ep1', title: '第01集', index: 0),
          Episode(id: 'ep2', title: '第02集', index: 1),
        ]),
        isTrue,
        reason: '★ 仪器自检：必须挂上了播放页且成功塞入两集',
      );

      // ① 摆出「上一集播到 1200s」的状态
      expect(debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 1200)),
          isTrue);

      // ② 换集（会话推进）—— 生产路径会把 _position 一起复位
      expect(debugPlayerBumpSessionForProbe(), isTrue);
      await t.pump();

      // ③ 新集是**短集**：片尾起点 600s（**小于**旧位置 1200）
      expect(
        debugPlayerSetSkipMarkerForProbe(outroStart: 600, outroEnd: 900),
        isTrue,
        reason: '★ 仪器自检：标记必须设进去了',
      );

      // ④ canplay 后的补判（【A】）
      expect(debugPlayerSkipAfterCanplayForProbe(), isTrue);
      await t.pump();

      // ⑤ 若 _position 没复位 ⇒ 读到 1200 ⇒ 误判"已到片尾"⇒ 倒计时被拉起
      expect(
        debugPlayerNextCountdownForProbe(),
        0,
        reason: '★★★ 换集后 `_position` 必须归零 —— '
            '否则补判读到**上一集**的 1200s，命中新集的片尾区间（600 起）'
            '⇒ 刚起播就弹出「下一集」倒计时（用户看到莫名其妙）',
      );

      await drainTimers(t);
    });

    testWidgets('★ 阴性对照：同会话内位置**不该**被复位', (t) async {
      await mountPlayer(t);
      expect(debugPlayerSetPositionOnlyForProbe(const Duration(seconds: 1200)),
          isTrue);
      // ★ 不 bump —— 同会话内位置必须保留（否则正常续播/补判全乱）
      await t.pump();
      expect(
        debugPlayerNextCountdownForProbe(),
        0,
        reason: '★ 阴性对照：没换会话时不该有任何倒计时（这条不证明复位，'
            '只证明仪器没恒真）',
      );
      await drainTimers(t);
    });
  });
}
