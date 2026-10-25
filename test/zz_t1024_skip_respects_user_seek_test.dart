@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  缺陷①（2026-10-25）：拖到 0 被自动跳片头弹回来
// ══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// 拖到 0 自动往前 / 拖几次累加
// ```
//
// # 因果链（代码级）
// ```text
// 片头区间 [0, 69s]（三条真机片源都从 0 开始）
// 进度条拖到最左 ⇒ onSeek(0) ⇒ _seekByUser(0)
// 位置流下一秒 tick 到 0 ⇒ _maybeSkip(0) ⇒ 命中片头区间 ⇒ seek(69)
// ⇒ 用户看到「拖到 0 自动往前」
// ```
//
// # 修法（两条**正交**的证据）
// ```text
// ① `_seekByUser` 里 `_introSkipped = true`      —— 本集不再自动跳（既有）
// ② `_maybeSkip` 里 2 秒**用户 seek 豁免窗口**    —— 本次新增，单调时钟
// ```
// 为什么②不是多余的：①有 5 处复位点
// （`_applySwitch` / `_applySession` / `_gotoEpisode` / 存设置 / 开 autoSkip），
// 用户"拖回 0 → 又碰了其中任一条 ⇒ 下一次 tick 又被弹走"，
// 这正是"拖几次累加"的形态。②是时间戳，不跟着那些复位走。
//
// # ★ task-14（2026-10-25，交叉复核结果）：口径修正 + 一个真缺陷
// ```text
// 我原来写的口径「`_seekByUser` 是唯一入口」**当时不成立**：
// `continueFromRewatchPrompt()`（浮层「继续观看」）里是裸
// `unawaited(_player.seek(pos))` —— 既不记 `_lastUserSeek`，也不置
// `_introSkipped` ⇒ 用户续播到片头区间内会被下一秒 tick 顶到 introEnd。
// 与缺陷①同形，只是入口不同（已修，见用例 ⑥）。
// ⇒ 现在的口径是：「`_seekByUser` 是**用户意图** seek 的唯一入口」，
//   程序性 seek 各自带 programmatic 标记，由 ⑤ 号结构门禁**逐条枚举**核对
//   （新增裸路径必红）。
// ```
//
// # ⚠️ 为什么每条用户 seek 用例都要先 `debugPlayerResetIntroSkippedForProbe()`
// ```text
// `_seekByUser` 自己就会置 `_introSkipped = true`
// ⇒ 若不复位，删掉②那条判据测试**照样绿**（①挡着）—— 那是假绿。
// 复位它之后仍然不跳，才证明**豁免判据本身**在起作用（见故障注入记录）。
// ```
//
// # 跑法
// ```powershell
// flutter test test/zz_t1024_skip_respects_user_seek_test.dart --concurrency=1 --run-skipped --tags native-media
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 换行符的 code unit —— **不用字符串字面量转义**
///
/// ⚠️ 这份文件曾被一次脚本化改写把"反斜杠 + n"写成了真实换行，
/// 直接把 Dart 字符串截断成语法错误。凡是"按行处理"的地方一律走
/// code unit 比较 / `String.fromCharCode`，避免再被工具链吃掉转义。
const int _kLf = 10;

/// 挂页 + 片头 [0,69] + 清空跳过探针（各用例的公共前置）
Future<void> armIntroSkip(WidgetTester t) async {
  await fixture.mountPlayer(t);
  expect(debugPlayerSetAutoSkipForProbe(true), isTrue,
      reason: '★ 自动跳过必须为开，否则测不到这个缺陷');
  expect(debugPlayerSetSkipMarkerForProbe(introStart: 0, introEnd: 69), isTrue,
      reason: '★ 真机三条片源都是 [0,69] 这个形态');
  expect(debugPlayerResetIntroSkippedForProbe(), isTrue,
      reason: '★ 起手复位，让每条用例的前置都干净');
  debugPlayerResetSkipProbe();
}

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });

  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('① 用户拖到 0 ⇒ 自动跳片头让位（即使 _introSkipped 被复位）', (t) async {
    await armIntroSkip(t);

    // ★ 真走生产 `_seekByUser`（进度条 onSeek / 键盘 ←→ / 远端命令都汇到这里）
    expect(debugPlayerUserSeekForProbe(Duration.zero), isTrue);
    final state = debugPlayerUserSeekStateForProbe();
    expect(state, contains('position=0'),
        reason: '★★ 用户 seek 的落点必须被记下来（真源 = `_lastUserSeek`）：$state');
    expect(state, isNot(contains('ageMs=-')),
        reason: '★★ 必须同时记**单调时间戳**（否则 2 秒窗口无从计算）：$state');

    // ★ 模拟生产里的复位点（`_applySwitch` / `_applySession` / `_gotoEpisode` …）
    expect(debugPlayerResetIntroSkippedForProbe(), isTrue);
    expect(debugPlayerIntroSkippedForProbe(), isFalse,
        reason: '夹具自检：复位之后本集确实"还没判定跳过"');

    expect(debugPlayerMaybeSkipForProbe(Duration.zero), isTrue);
    expect(debugPlayerSkipSeekCalls(), 0,
        reason: '★★★ 拖到 0 之后不许再 seek 到 69s —— 这就是 Owner 报的那条');
    expect(debugPlayerLastSkipSeek(), isNull);
    expect(debugPlayerIntroSkippedForProbe(), isTrue,
        reason: '★ 用户已经用 seek 表过态 ⇒ 本集不再自动跳片头');

    await fixture.drain(t);
  });

  testWidgets('② 阴性对照：起播自动落在片头区间内 ⇒ 仍然跳（功能不许改废）', (t) async {
    await armIntroSkip(t);

    // ⚠️ 没有用户 seek ⇒ 豁免窗口不成立
    expect(debugPlayerUserSeekStateForProbe(), contains('position=-'),
        reason: '夹具自检：本次会话**没有**用户 seek 记录');

    expect(debugPlayerMaybeSkipForProbe(Duration.zero), isTrue);
    expect(debugPlayerSkipSeekCalls(), 1,
        reason: '★★★ 自动跳过必须照旧工作（阴性对照）——'
            '把豁免写成"任何 seek 之后都不跳"会让这条红');
    expect(debugPlayerLastSkipSeek(), const Duration(seconds: 69));

    await fixture.drain(t);
  });

  testWidgets('③ 2 秒窗口会过期 ⇒ 之后自动跳恢复（豁免不是永久的）', (t) async {
    await armIntroSkip(t);

    expect(debugPlayerUserSeekForProbe(Duration.zero), isTrue);
    // 把"用户 seek 的时刻"往前拨 2.5 秒（超过窗口）
    expect(debugPlayerAgeUserSeekForProbe(const Duration(milliseconds: 2500)),
        isTrue);
    expect(debugPlayerResetIntroSkippedForProbe(), isTrue);

    expect(debugPlayerMaybeSkipForProbe(Duration.zero), isTrue);
    expect(debugPlayerSkipSeekCalls(), 1,
        reason: '★★ 窗口只有 2 秒 —— 超过之后自动跳过必须恢复。'
            '把窗口写死成"无限"会让这条红');
    expect(debugPlayerLastSkipSeek(), const Duration(seconds: 69));

    await fixture.drain(t);
  });

  testWidgets('④ 续播期间（_pendingSeek != null）⇒ 不跳（缺陷③同一处让位）', (t) async {
    await armIntroSkip(t);

    // 续播意图：换源续播到 300s（缺陷③的契约）
    expect(debugPlayerSetPendingSeekForProbe(const Duration(seconds: 300)),
        isTrue);
    expect(debugPlayerResetIntroSkippedForProbe(), isTrue);

    expect(debugPlayerMaybeSkipForProbe(Duration.zero), isTrue);
    expect(debugPlayerSkipSeekCalls(), 0,
        reason: '★★ 续播落地前的位置属于新流初始化，不是自动跳过的依据；'
            '此刻抢跑会把续播位置顶掉（谁后落地谁赢的竞态）');
    expect(debugPlayerLastSkipSeek(), isNull);

    await fixture.drain(t);
  });

  testWidgets('⑥ 「继续观看」也是用户意图 ⇒ 落在片头区间内不被自动跳过顶掉', (t) async {
    /*
     * ★★★ task-14（2026-10-25，交叉复核查出的**真缺陷**）
     *
     * 实测缺陷形态（改前）：
     * ```text
     * `continueFromRewatchPrompt()` 里是裸 `unawaited(_player.seek(pos))`
     *   ⇒ 没 `_noteUserSeek`（无 2 秒豁免）、没 `_introSkipped = true`
     *   ⇒ 用户点「继续观看」跳到 30s（片头 [0,69] 内）
     *   ⇒ 下一秒 tick 进 `_maybeSkip(30s)` ⇒ seek(69) 把用户选的位置顶掉
     * ```
     * 与缺陷①（拖到 0 被弹走）**同形**，只是入口不同。
     */
    await armIntroSkip(t);

    expect(debugPlayerShowRewatchPromptForProbe(const Duration(seconds: 30)),
        isTrue,
        reason: '夹具自检：浮层必须摆出来（否则本用例什么都没验）');
    expect(debugPlayerContinueRewatchForProbe(), isTrue,
        reason: '★ 必须真的走生产 `continueFromRewatchPrompt()`');
    expect(debugPlayerRewatchPromptForProbe(), isNull,
        reason: '点了之后浮层要收掉');

    final st = debugPlayerUserSeekStateForProbe();
    expect(st, contains('position=30000'),
        reason: '★★★ 「继续观看」必须记进用户 seek 记录（`_lastUserSeek`）：$st');
    expect(debugPlayerIntroSkippedForProbe(), isTrue,
        reason: '★★ 用户已表态 ⇒ 本集不再自动跳片头');

    expect(debugPlayerMaybeSkipForProbe(const Duration(seconds: 30)), isTrue);
    expect(debugPlayerSkipSeekCalls(), 0,
        reason: '★★★ 用户刚选的 30s 落在片头 [0,69] 内，'
            '自动跳过不许把他顶到 69s（改前就是这个症状）');
    expect(debugPlayerLastSkipSeek(), isNull);

    await fixture.drain(t);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ 结构门禁：**每一条** `_player.seek` 都必须能解释清楚
  // ══════════════════════════════════════════════════════════════════
  //
  // # ⚠️ 两条不变量**不是同一件事**（task-26 补充，别混）
  // ```text
  // ① 「用户意图 seek 优先」（本文件 ①–⑥ 守）
  //     同一集内：用户拖到 0 / 点「继续观看」⇒ 2 秒内 `_maybeSkip` 必须让位，
  //     且本集不再自动跳片头。
  //     实现：`_seekByUser`（唯一入口）+ `_lastUserSeek` 时间窗 + `_introSkipped`。
  //     主语 = **用户当下的动作**；作用域 = 同一集；时间 = 2 秒。
  //
  // ② 「换集从 0 开始」（`test/zz_rewatch_prompt_test.dart` + 本文件 ④ 守）
  //     跨集：`_gotoEpisode` 清 `_pendingSeek` 之后，**在途的旧加载不许再写回来**。
  //     实现：`_prepareResume` 里的**代次快照**（`_playSessionGen` + `_epIndex`
  //     进入时记、`await` 回来后比对，不一致就作废）。
  //     主语 = **会话身份**；作用域 = 跨集；时间 = 整个异步读取窗口。
  // ```
  // 两者都叫"用户意图优先"，但判据、时机、作用域完全不同：
  // ```text
  // 若用②去实现① ⇒ 用户拖到 0 之后、只要不换集就永远不跳片头（把功能改废）；
  // 若用①去实现② ⇒ 换集后旧加载照样把 20:00 写回 `_pendingSeek`（task-26 的真缺陷）。
  // ⇒ 本文件只守①；② 由 `zz_rewatch_prompt_test` 的 14 条行为门禁守
  //   （注入方式：删掉 `_prepareResume` 里的代次守卫 ⇒ 其中 4 条立刻红，
  //    见 `.probe/fix03-inject.log`）。
  // ```
  //
  // # 为什么原来那条不够（task-14 的教训，逐字记录）
  // ```text
  // 原来只断言 src.contains('_noteUserSeek(target)') —— 这只证明
  // "某个地方调了它"，对**新增的用户 seek 入口**零判别力：
  //   `continueFromRewatchPrompt` 里那条裸 `_player.seek(pos)` 照样合绿。
  // ⇒ 改成**枚举**：文件里每一处 `_player.seek` 必须落在
  //   ① `_seekByUser` 的函数体内（= 用户意图的唯一入口），或
  //   ② 紧邻一行 programmatic 标记（`seek-intent: programmatic — <理由>`）。
  // 新增一条裸用户 seek ⇒ 两条都不满足 ⇒ 立刻红，并指出行号。
  // ```
  test('⑤ 结构门禁：所有 `_player.seek` 要么在 `_seekByUser` 内，要么带 programmatic 标记', () {
    final src = File('lib/ui/player_page.dart').readAsStringSync();
    final code = stripCommentsKeepLines(src);
    final srcLines = src.split(String.fromCharCode(_kLf));
    final codeLines = code.split(String.fromCharCode(_kLf));
    expect(srcLines.length, codeLines.length,
        reason: '剥注释必须**保留换行**（否则行号对不上，下面全部失效）');

    // ① 定位 `_seekByUser` 的函数体（按大括号配平，不用魔数窗口）
    final body = _dartFnBody(code, 'Future<void> _seekByUser(Duration target)');
    final bodyStart = code.indexOf(body);
    expect(bodyStart, greaterThan(-1));
    final bodyEnd = bodyStart + body.length;
    int lineOf(int offset) {
      var n = 0;
      for (var i = 0; i < offset && i < code.length; i++) {
        if (code.codeUnitAt(i) == _kLf) n++;
      }
      return n;
    }

    final bodyFrom = lineOf(bodyStart);
    final bodyTo = lineOf(bodyEnd);

    // ② 枚举每一处 `_player.seek`（含 tear-off：`(_x ?? _player.seek)(t)`）
    final sites = <int>[];
    for (var i = 0; i < codeLines.length; i++) {
      if (codeLines[i].contains('_player.seek')) sites.add(i);
    }
    expect(sites.length, greaterThanOrEqualTo(5),
        reason: '★ 枚举必须非空（否则这条门禁等于没开）：实际 ${sites.length} 处');

    for (final line in sites) {
      final inEntry = line >= bodyFrom && line <= bodyTo;
      if (inEntry) continue;
      final marker = line > 0 ? srcLines[line - 1].trimLeft() : '';
      expect(marker.startsWith('// seek-intent: programmatic'), isTrue,
          reason: '★★★ player_page.dart:${line + 1} 出现了一处 `_player.seek`，'
              '既不在 `_seekByUser`（用户意图唯一入口）里，也没有 '
              '`seek-intent: programmatic` 标记 ｜ 该行：${srcLines[line].trim()} ｜ '
              '新增**用户** seek 入口必须走 `_seekByUser`（否则 2 秒豁免与 '
              '`_introSkipped` 都不生效 = 缺陷①复发的形态）；'
              '程序性 seek 必须写清理由。');
    }

    // ③ 标记不许漂：每个 programmatic 标记的**下一行**必须真的是 seek
    for (var i = 0; i < srcLines.length - 1; i++) {
      // ⚠️ 必须**行首**匹配：文档注释里也会引用这个标记串（本文件就被坑过一次 ——
      //    散文里出现同一串会让"标记漂了"误报，指着 `_seekByUser` 的说明文字）。
      if (!srcLines[i].trimLeft().startsWith('// seek-intent: programmatic')) {
        continue;
      }
      expect(codeLines[i + 1].contains('_player.seek'), isTrue,
          reason: '★★ player_page.dart:${i + 1} 的 programmatic 标记'
              '下面一行不是 seek（标记漂了 ⇒ 它可能在掩护另一处裸 seek）');
    }

    // ④ 具体回归：缺陷 1 的那条入口
    final rewatch = _dartFnBody(code, 'void continueFromRewatchPrompt()');
    expect(rewatch, contains('_seekByUser(pos)'),
        reason: '★★★ 「继续观看」是用户意图 ⇒ 必须走 `_seekByUser`');
    expect(rewatch.contains('_player.seek'), isFalse,
        reason: '★★★ 不许再出现裸 seek（task-14 修的就是这一行）');

    // ⑤ 原有的两条口径不变
    expect(src, contains("AppLog.write('PLAY', '跳过片头"),
        reason: '★★ 跳过动作必须落盘 —— 改前只有 debugPrint，'
            'Release 版日志里一条都没有（Owner 无法排查）');
    expect(src, contains('_userSeekClock = Stopwatch()'),
        reason: '★★ 必须是单调时钟：墙钟会被 NTP / 用户改时间影响，'
            '2 秒窗口会变成负数或几小时');
    expect(src, contains('_kUserSeekGraceWindow = Duration(seconds: 2)'),
        reason: '★ 窗口宽度 2 秒（计划原文）');
  });
}

/// 剥掉注释但**保留换行**（行号必须与原文件一一对应）
///
/// 为什么不能用正则一次性替换块注释：那样会把注释里的换行一起吃掉
/// ⇒ 之后按行号定位会整体错位，门禁就会指着错误的行。
String stripCommentsKeepLines(String src) {
  final out = StringBuffer();
  var i = 0;
  var inBlock = false;
  String two(int at) =>
      at + 1 < src.length ? src.substring(at, at + 2) : src.substring(at);
  while (i < src.length) {
    if (!inBlock && two(i) == '//') {
      while (i < src.length && src.codeUnitAt(i) != _kLf) {
        i++;
      }
      continue;
    }
    if (!inBlock && two(i) == '/*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (inBlock) {
      if (two(i) == '*/') {
        inBlock = false;
        i += 2;
      } else {
        if (src.codeUnitAt(i) == _kLf) out.writeCharCode(_kLf);
        i++;
      }
      continue;
    }
    out.writeCharCode(src.codeUnitAt(i));
    i++;
  }
  return out.toString();
}

/// 按**大括号配平**切出某个 Dart 方法的函数体（含签名与花括号）
String _dartFnBody(String code, String signature) {
  final at = code.indexOf(signature);
  expect(at, greaterThan(-1), reason: '锚点不存在：$signature');
  final open = code.indexOf('{', at);
  expect(open, greaterThan(-1), reason: '`$signature` 后面必须有 `{`');
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(at, i + 1);
    }
  }
  fail('`$signature` 的大括号不配平');
}
