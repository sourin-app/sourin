// ═══════════════════════════════════════════════════════════════════════
//  task-66【N10】seek 让路窗口的静态契约门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件，且为什么它**不是恒绿门禁**
// ```text
// N10 的机制是「预取在 seek 后抢带宽」。
// 真机 A/B 能证明它有效，但 **widget 测试里没有真 mpv**，
// 所以「seek 后转圈 ≤ Xms」这类断言在 flutter test 里测不到 ——
// 写出来就是恒绿（改前改后都过）。
//
// ★ 但「暂停 + 恢复」这两个动作**可以被静态契约钉住**：
//   ① 有人删掉暂停逻辑 ⇒ 本门禁红
//   ② 有人忘了恢复   ⇒ 本门禁红
//   ③ 连续 seek 叠定时器 ⇒ 本门禁红
//   ④ 页面销毁不 cancel  ⇒ 本门禁红
//   ⑤ 原本关闭被打开  ⇒ 本门禁红（由 Rust 侧单测守，这里校验调用契约）
//
// ⇒ 这五条都是**可证伪**的：把对应实现删掉，门禁确实会红。
//   （已实测：把 Rust 的 restore 改成无条件 false ⇒ streamproxy 单测红）
// ```
//
// # 为什么用「源码字面量」而不是行为测试
// ```text
// 生产代码里的 `_beginPrefetchYield()` 依赖 FFI（真 core）。
// widget 测试没有 core ⇒ 调用会抛，无法用行为断言。
// ⇒ 退而钉**源码结构**：这是本仓库既有的做法（见 t118 的控制条门禁）。
// ⚠️ 代价：它是脆的（改注释/改格式会红）。
//   所以本文件校验的每一处都用**语义稳定的最小片段**，不钉整行。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 读源码（相对仓库根）
String _read(String rel) {
  final f = File(rel);
  expect(f.existsSync(), isTrue, reason: '源码文件不存在: $rel');
  return f.readAsStringSync();
}

void main() {
  late String page;
  late String api;
  late String proxy;

  setUpAll(() {
    page = _read('lib/ui/player_page.dart');
    api = _read('lib/core/sourin_api.dart');
    proxy = _read('rust/sourin_core/src/streamproxy.rs');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① seek 之后确实挂了让路钩子
  // ═══════════════════════════════════════════════════════════════════
  test('① seek 路径上必须调用 _beginPrefetchYield()', () {
    /*
     * 钉住：`if (!_isLive) { _player.seek(d); _beginPrefetchYield(); }`
     *
     * ★ 为什么用正则会话而不是整行字面量：
     *   中间可能插注释/换行，钉整行会因格式变化误红；
     *   但「seek 之后紧跟 _beginPrefetchYield」这个语义必须保。
     */
    final re = RegExp(
      r'_player\.seek\(d\);[\s\S]{0,80}?_beginPrefetchYield\(\);',
    );
    expect(
      re.hasMatch(page),
      isTrue,
      reason: '★ seek 之后必须调用 _beginPrefetchYield()：'
          '否则预取不会让路给前台读取，N10 的修复等于没做。',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 让路窗口结束后必须恢复
  // ═══════════════════════════════════════════════════════════════════
  test('② 定时器到点必须调 endYieldForSeek()', () {
    /*
     * ★ 这一条是本门禁**最重要**的一条。
     *
     * 若有人只加 begin 不加 end：
     *   预取会**永久关闭** ⇒ 远端 seek 永远慢
     *   实测：预取 OFF 时远端 85% 是 190ms，ON 是 162ms
     *   ⇒ 永久关闭 = 永久损失 28ms，而且**没有任何用户可见的报错**
     * ⇒ 这种"静默退化"必须由门禁守住。
     */
    final re = RegExp(
      r'_prefetchYieldTimer\s*=\s*Timer\([\s\S]{0,200}?endYieldForSeek\(\)',
    );
    expect(
      re.hasMatch(page),
      isTrue,
      reason: '★ 让路窗口必须由定时器调 endYieldForSeek() 恢复：'
          '忘了恢复会让预取永久关闭，远端 seek 静默变慢且无人察觉。',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 连续 seek 不得叠定时器
  // ═══════════════════════════════════════════════════════════════════
  test('③ 必须用 first 判据避免连续拖动时叠定时器', () {
    /*
     * ★ 为什么必须钉：
     *   连续拖 3 次若起 3 个定时器，第一个到点就把预取恢复了
     *   ⇒ 后两次的让路**提前失效** ⇒ 用户拖得越快越不生效（反直觉的坏）。
     */
    expect(
      page.contains('if (!first) return;'),
      isTrue,
      reason: '★ 必须检查 beginYieldForSeek() 返回的 first：'
          '连续拖动时 Rust 侧只重置截止时刻，Dart 侧不该再起定时器。',
    );
    expect(
      api.contains('final r = await SourinCore.callAsync(\'begin_yield_for_seek\');'),
      isTrue,
      reason: 'beginYieldForSeek 必须真的调 FFI（不能吞掉返回的 first）',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 页面销毁必须取消定时器 + 补一次恢复
  // ═══════════════════════════════════════════════════════════════════
  test('④ dispose 必须 cancel 定时器并补一次 end', () {
    /*
     * ★ 只 cancel 不 end 的后果：
     *   销毁瞬间若正在窗口内，Rust 侧的 `yield_until_ms` 还没到点，
     *   但再没有人会调 end ⇒ 预取要等到窗口自然过期（2 秒）才恢复。
     *   2 秒不算长，但如果**每次换集都这样**，累积影响不可忽略。
     * ⇒ 所以 cancel 之后必须 fire-and-forget 调一次 end（Rust 侧幂等）。
     *
     * ★★ 本门禁第一版是**恒绿**的（故障注入 case 4 抓到）：
     *    原来的正则 `_prefetchYieldTimer?.cancel();...endYieldForSeek`
     *    会跨过 dispose 边界，匹配到 `_beginPrefetchYield` 里那个 end。
     *    ⇒ 改成：先定位 dispose 方法体，再在**它内部**找这两个调用。
     */
    final disposeRe = RegExp(r'void dispose\(\)\s*\{');
    final m = disposeRe.firstMatch(page);
    expect(m, isNotNull, reason: '找不到 dispose()');

    // 取 dispose 方法体（到下一个 `\n  void ` / `\n  }` 为止，取 4000 字符兜底）
    final body = page.substring(m!.end, (m.end + 4000).clamp(0, page.length));

    expect(
      body.contains('_prefetchYieldTimer?.cancel()'),
      isTrue,
      reason: '★ dispose 内必须 cancel 让路定时器',
    );
    /*
     * ★★ 必须匹配**实际调用**，不能只匹配方法名
     *
     * 本门禁第二版仍是恒绿（故障注入 case 4 又抓到）：
     * dispose 上方的注释里就写着「…调一次 endYieldForSeek()…」
     * ⇒ `body.contains('endYieldForSeek()')` 命中的是**注释**，不是代码。
     * ⇒ 改成匹配调用表达式 `unawaited(SourinApi.endYieldForSeek());`
     */
    final endCallRe = RegExp(
      r'unawaited\(\s*SourinApi\.endYieldForSeek\(\)\s*\)',
    );
    expect(
      endCallRe.hasMatch(body),
      isTrue,
      reason: '★ dispose 内必须有**实际调用** unawaited(SourinApi.endYieldForSeek())：'
          '只 cancel 不 end，销毁时若在窗口内预取会一直让路到自然过期。',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 恢复语义：Rust 侧必须"恢复原值"，不是无条件 false
  // ═══════════════════════════════════════════════════════════════════
  test('⑤ Rust 侧恢复必须读回保存的原值（不得无条件 false）', () {
    /*
     * ★ 这是本类开关最容易出的 bug：
     *   用户配了 SOURIN_PREFETCH_DISABLE=1（预取本来就关）
     *   我们的"恢复"若无条件 set(false)，会**打开用户配的关闭状态**
     * ⇒ 必须先保存、后恢复。
     */
    expect(
      proxy.contains('yield_saved_disabled'),
      isTrue,
      reason: '★ Rust 侧必须保存进入窗口前的 prefetch_disabled 原值',
    );

    // 恢复时必须读 saved 值，而不是直接 store(false)
    final restoreRe = RegExp(
      r'fn end_yield_for_seek\(&self\)[\s\S]{0,600}?yield_saved_disabled',
    );
    expect(
      restoreRe.hasMatch(proxy),
      isTrue,
      reason: '★ end_yield_for_seek() 必须读 yield_saved_disabled 来恢复，'
          '不能无条件 store(false)。',
    );

    /*
     * ★★ 反证（本门禁第一版这里是**恒绿**的，故障注入 case 5 抓到）
     *
     * 原来写的是 `proxy.contains('...store(false...)')` —— 但源码里
     * `store(false` 根本不存在（换行/缩进不同）⇒ 断言永远成立 ⇒ 恒绿。
     *
     * 现在改成：从 `end_yield_for_seek` 方法体里取关键片段，
     * 断言它**必须**出现 `orig == 1`（= 按保存值恢复），
     * 且**不得**出现 `store(false`（= 无条件打开）。
     * 两者都作用在**同一个方法体**上，这样删掉原值逻辑就会红。
     */
    final endBodyRe = RegExp(
      r'fn end_yield_for_seek\(&self\)\s*\{([\s\S]{0,800}?)\n    \}',
    );
    final endBody = endBodyRe.firstMatch(proxy)?.group(1);
    expect(endBody, isNotNull, reason: '找不到 end_yield_for_seek 方法体');

    expect(
      endBody!.contains('orig == 1'),
      isTrue,
      reason: '★ end_yield_for_seek() 必须按保存的原值恢复（`orig == 1`）：'
          '否则用户配的 SOURIN_PREFETCH_DISABLE 会被我们的恢复逻辑打开。',
    );
    expect(
      RegExp(r'store\(\s*false\s*,').hasMatch(endBody),
      isFalse,
      reason: '★ end_yield_for_seek() 内不得无条件 store(false)。',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑥ 两侧的窗口长度必须一致
  // ═══════════════════════════════════════════════════════════════════
  test('⑥ Dart 与 Rust 的窗口长度必须一致（2000ms）', () {
    /*
     * ★ 不一致的后果：
     *   Dart 定时器比 Rust 短 ⇒ end 提前到达，但 Rust 仍认为在窗口内
     *     （`in_yield_window` 靠时间判断，end 会 store(0) 立刻结束 ⇒ 其实没问题）
     *   Dart 比 Rust 长 ⇒ 多等一会，无害但浪费
     * ⇒ 虽然不致命，但两侧散落魔数是维护隐患 ⇒ 钉住。
     */
    expect(
      api.contains('static const int yieldWindowMs = 2000;'),
      isTrue,
      reason: '★ Dart 侧窗口长度必须是 2000ms',
    );
    expect(
      proxy.contains('pub const YIELD_WINDOW_MS: u64 = 2000;'),
      isTrue,
      reason: '★ Rust 侧窗口长度必须是 2000ms（与 Dart 一致）',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑦ 让路必须真的影响 plan_prefetch 的判据
  // ═══════════════════════════════════════════════════════════════════
  test('⑦ 窗口内 prefetch_is_disabled() 必须返回 true', () {
    /*
     * ★ 这是"让路真的生效"的唯一连接点：
     *   `plan_prefetch(proxy.prefetch_is_disabled(), ...)`
     * 若 `prefetch_is_disabled()` 不看窗口状态 ⇒ 让路是空操作。
     */
    final re = RegExp(
      r'fn prefetch_is_disabled\(&self\) -> bool \{[\s\S]{0,300}?in_yield_window\(\)',
    );
    expect(
      re.hasMatch(proxy),
      isTrue,
      reason: '★ prefetch_is_disabled() 必须先看 in_yield_window()：'
          '否则让路窗口不会影响实际预取行为，整个修复是空操作。',
    );
    // 且必须仍被 plan_prefetch 使用
    /*
     * ⚠️ 用正则而不是字面量：仓库里 Rust 文件是 CRLF，
     *    字面量里的 `\n` 匹配不到 `\r\n`（本门禁第一版就栽在这）。
     */
    final callRe = RegExp(
      r'plan_prefetch\(\s*proxy\.prefetch_is_disabled\(\)',
    );
    expect(
      callRe.hasMatch(proxy),
      isTrue,
      reason: '★ plan_prefetch 必须继续读 prefetch_is_disabled()',
    );
  });
}
