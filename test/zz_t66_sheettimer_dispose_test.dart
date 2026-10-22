// ═══════════════════════════════════════════════════════════════════════
//  R3-④ 补漏：`_sheetGuardTimer` 必须在 dispose 时 cancel
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么
//
// ```text
// player_page.dart 的 `_holdSheetGuard()` 会装一个 350ms 的 Timer，
// 到点 setState 撤销守卫。
//
// 虽然回调里有 `if (!mounted) return` 兜住（不会崩），
// 但**不 cancel 会让 Timer 在本页销毁后继续持有 State 引用**最多 350ms。
// ⇒ 本文件证明 `dispose` 里那句 `_sheetGuardTimer?.cancel()` 真的生效，
//   而不只是"写了 cancel"。
// ```
//
// # 怎么证明
//
// ```text
// 用**结构等价**的最小 StatefulWidget 复刻这个模式（真 player_page
// 依赖 libmpv/FFI，测试环境挂不起来）：
//   ① 挂载 → 触发 guardHold → 立刻卸载（pumpWidget 换掉）→ pump 400ms
//   ② 断言：无异常（takeException 为 null）+ Timer 回调**没有**执行
//
// ⇒ 然后第 ③ 条**反向验证**：把 cancel 去掉，断言必须能抓到。
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as m;

/// 复刻 `player_page.dart` 里 `_holdSheetGuard` 的最小形态。
///
/// [cancelInDispose] = false 时**故意不 cancel**，用来反向验证本门禁有效。
class _TimerHolder extends StatefulWidget {
  const _TimerHolder({
    required this.onFire,
    this.cancelInDispose = true,
  });

  final VoidCallback onFire;
  final bool cancelInDispose;

  @override
  State<_TimerHolder> createState() => _TimerHolderState();
}

class _TimerHolderState extends State<_TimerHolder> {
  Timer? _timer;
  bool _held = false;

  @override
  void initState() {
    super.initState();
    // 挂载就立刻装一个 350ms 定时器（等价于用户点了遮罩关窗）
    _held = true;
    _timer = Timer(const Duration(milliseconds: 350), () {
      widget.onFire();
      if (!mounted) return;
      setState(() => _held = false);
    });
  }

  @override
  void dispose() {
    if (widget.cancelInDispose) {
      _timer?.cancel();
      _timer = null;
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      m.ColoredBox(color: _held ? const m.Color(0xFF202020) : const m.Color(0xFF101418));
}

/// 剥掉注释行（源码扫描判据的**前置** —— 不做这一步会假绿）
///
/// ★★ 2026-10-19（Lead 加）：我先写的三条 `contains` 断言**是假绿的** ——
///   `_player.dispose()` 在 dispose 里出现 **3 次**，但只有 **1 次是真实代码**，
///   另外 2 次在**注释里**（那段注释解释为什么要放在 `_biliApi?.close()` 之后）。
///   ⇒ 删掉真实那一行后 `contains` 仍为 true ⇒ 测试**仍全绿**（复核实测）。
/// ★ 这与本仓 AGENTS §8 记的「命中注释」是同一个病，
///   也与那条被删掉的全局 `hasMatch` 恒真是同一个病。
///
/// ⇒ 判据：**凡是用 `contains` / `hasMatch` 扫源码，先剥注释。**
///   只剥整行注释（`//` / `*` / `/*` 开头）；行尾注释未处理，
///   但那要求被扫的调用**恰好落在行尾**，而这三条都在独立行上。
String _codeOnly(String body) => body
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') &&
          !t.startsWith('*') &&
          !t.startsWith('/*');
    })
    .join('\n');

/// 按**大括号配对**取方法体（2026-10-19 加，取代固定长度窗口）
///
/// ★ 为什么不用「`substring(i, i + N)`」这种固定窗口：
///   实测 `PlayerPageState.dispose()` 的真实函数体是 **6813 字符**，
///   而原来那个窗口只有 **2600** ⇒ 只覆盖 38%，且**窗口外有 18 个
///   关键资源释放调用**（`_player.dispose()` / `_danmakuClient?.close()` 等）。
///   固定窗口的正确性依赖「目标代码恰好在窗口前段」，那是**侥幸**，
///   前面多一行注释就可能失效。
///
/// ⇒ 按大括号配对取**整个**函数体，与函数体长度无关。
String _balancedBody(String src, String signature) {
  final i = src.indexOf(signature);
  if (i < 0) return '';
  final open = src.indexOf('{', i);
  if (open < 0) return '';
  var depth = 0;
  for (var k = open; k < src.length; k++) {
    if (src[k] == '{') depth++;
    if (src[k] == '}') {
      depth--;
      if (depth == 0) return src.substring(open, k + 1);
    }
  }
  return src.substring(open);
}

void main() {
  group('R3-④ _sheetGuardTimer 的 dispose 契约', () {
    testWidgets('★★★ ① dispose 后 Timer 不许再触发', (t) async {
      var fired = 0;

      await t.pumpWidget(m.MaterialApp(
        theme: m.ThemeData.dark(),
        themeAnimationDuration: Duration.zero,
        home: _TimerHolder(onFire: () => fired++),
      ));
      await t.pump();
      // 还没到 350ms ⇒ 没触发
      expect(fired, 0, reason: '前提：刚挂载，定时器还没到点');

      // ★ 立刻卸载（模拟用户关掉播放页）
      await t.pumpWidget(m.MaterialApp(
        theme: m.ThemeData.dark(),
        themeAnimationDuration: Duration.zero,
        home: const m.SizedBox(),
      ));
      await t.pump(const Duration(milliseconds: 500));

      expect(fired, 0,
          reason: '★★★ dispose 里 cancel 之后，Timer **不许**再触发 —— '
              '否则它会打到已卸载的 State 上');
      expect(t.takeException(), isNull,
          reason: '★★★ 不许有 setState after dispose 之类的异常');
    });

    testWidgets('★★★ ② 反向验证：不 cancel 时本门禁必须能抓到', (t) async {
      /*
       * ★ 这条证明 ① 不是恒真。
       *
       * 若没有这条，① 可能因为"Timer 本来就没跑"而永远是绿的。
       * ⇒ 让复制品**故意不 cancel**，断言 Timer 真的会触发。
       */
      var fired = 0;

      await t.pumpWidget(m.MaterialApp(
        theme: m.ThemeData.dark(),
        themeAnimationDuration: Duration.zero,
        home: _TimerHolder(
          onFire: () => fired++,
          cancelInDispose: false, // ★ 故意不 cancel
        ),
      ));
      await t.pump();

      await t.pumpWidget(m.MaterialApp(
        theme: m.ThemeData.dark(),
        themeAnimationDuration: Duration.zero,
        home: const m.SizedBox(),
      ));
      await t.pump(const Duration(milliseconds: 500));

      expect(fired, 1,
          reason: '★★★ 不 cancel 时 Timer **必须**照样触发 —— '
              '若这里是 0，说明 ① 的对照组失效、本门禁是假绿');
    });

    // ══════════════════════════════════════════════════════════════════
    //  ③ 源码级：产品代码里真的有这句 cancel
    // ══════════════════════════════════════════════════════════════════
    test('★★★ ③ 产品代码 dispose 里必须有 _sheetGuardTimer?.cancel()', () {
      /*
       * ★ ①② 用的是复制品（真播放页依赖 libmpv/FFI 挂不起来）。
       *   ⇒ 若有人把产品里那句 cancel 删掉，①②**仍然是绿的**（它们测复制品）。
       *   ⇒ 这条源码级断言补住那处缺口。
       */
      final src = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * ★★★ 2026-10-19（批末复核）：**这里原来有一条恒真断言，已删除。**
       *
       * ```text
       * 删掉的是：
       *   expect(RegExp(r'_sheetGuardTimer\?\.cancel\(\);').hasMatch(src), isTrue,
       *          reason: '★★★ dispose 里必须有 `_sheetGuardTimer?.cancel();`');
       *
       * # 为什么它是恒真的（实测，不是推断）
       * `_sheetGuardTimer?.cancel();` 在产品源码里有 **2 处**：
       *   player_page.dart:11616  在 `_holdSheetGuard()` 里（重装前清旧的）
       *   player_page.dart:14447  在 `dispose()` 里（本用例真正要守的）
       * ⇒ 那条断言扫的是**整个文件**（hasMatch(src)）
       * ⇒ 只要 `_holdSheetGuard()` 里那处还在，dispose 那处删掉它**仍然绿**。
       *
       * 实测证据：把 dispose 里那处替换成 `// DELETED` 之后
       *   全局 hasMatch      = **true**   ← 断言仍然通过
       *   源码里还剩         = 1 处      ← 就是 _holdSheetGuard 里那处
       *   而下面 L160 的局部窗口判据 = false ← 能抓到
       * ```
       *
       * ★ 判据：**一条恒真的断言比没有断言更糟** —— 它提供虚假的安全感。
       * ⇒ 删掉它，只保留下面的**局部窗口**判据（那才是唯一真正守住 dispose 的）。
       *
       * ⚠️ 不要把它"改成局部窗口"了事 —— 那样会与下面 L160 那条**重复**
       *   （两条一模一样的判断，违反「同一纪律只能有一个实现」）。
       */
      // 而且必须在 dispose 方法体内（不是只在 _holdSheetGuard 里）
      final disposeIdx = src.indexOf('void dispose() {');
      expect(disposeIdx, greaterThan(0), reason: '前提：dispose 存在');
      /*
       * ★★ 2026-10-19（批末复核发现，Lead 改）：原来用**固定 2600 字符窗口**，
       *   而 dispose 的真实函数体是 **6813 字符** ⇒ 窗口只覆盖 **38%**。
       *
       * ```text
       * 实测：`_sheetGuardTimer?.cancel()` 在函数体内的偏移是 1871（27.5%）
       *   ⇒ 落进窗口，**这条断言目前侥幸正确**
       *   ⇒ 但它前面每多一行注释就可能滑出窗口
       *
       * ★ 而窗口外有 **18 个**清理调用，包含
       *   `_player.dispose()` / `_danmakuClient?.close()` / `_pageFocusNode.dispose()`
       *   这些**关键资源释放** ⇒ 截断确实丢了内容。
       *
       * ⇒ 改成按**大括号配对**取整个函数体，不再依赖窗口长度。
       */
      final disposeBody = _balancedBody(src, 'void dispose() {');
      // ★★★ 配对成功的**直接证据**（`length > 2600` 只是间接代理）：
      //   复核实测：若有人把窗口改成 2700 或取「半个函数」（3406 字符），
      //   `length > 2600` **都会静默通过** ⇒ 只断长度挡不住这类截断。
      expect(disposeBody, isNotEmpty, reason: '没取到 dispose 函数体 ⇒ 后面全是空断言');
      expect(disposeBody.startsWith('{'), isTrue,
          reason: '★ 必须从 { 开始 —— 否则说明 indexOf/signature 定位错了');
      expect(disposeBody.endsWith('}'), isTrue,
          reason: '★★ 必须以 } 结尾 —— 这是「大括号配对成功」的直接证据。'
              'length > 2600 只是间接代理：2700 的截断窗口、'
              '半个函数（3406 字符）都能通过它。');
      expect(
        disposeBody.length,
        greaterThan(2600),
        reason: '★ 配对取到的 dispose 函数体只有 ${disposeBody.length} 字符，'
            '比原来的固定窗口还短 ⇒ 截取逻辑坏了',
      );
      // ★ 剥掉注释行再判「真实代码」—— 见 _codeOnly 的注释。
      final disposeCode = _codeOnly(disposeBody);
      /*
       * ★ 2026-10-19（批末复核）：正则去掉尾部的 `;`，并把 `?.` 放宽成 `[?!]?.`
       *
       * ```text
       * 改前： r'_sheetGuardTimer\?\.cancel\(\);'
       *   尾部锚了分号 ⇒ 下列**语义等价**的写法都会让它红（假红）：
       *     多一个空格   `...cancel() ;`
       *     拆成两行     `...cancel()\n    ;`
       *     改 ?. 为 !.  `_sheetGuardTimer!.cancel();`
       *     挂链式调用   `...cancel().catchError(...)`
       *   实测：5 种真实重构形态里有 4 种会假红。
       *
       * 改后： r'_sheetGuardTimer[?!]?\.cancel\('
       *   上面 4 种假红全部消除，而**判别力一点没丢**：
       *     删掉整行调用 ⇒ 仍然 false ⇒ 仍然红 ✅（实测）
       * ```
       */
      expect(
        RegExp(r'_sheetGuardTimer[?!]?\.cancel\(').hasMatch(disposeBody),
        isTrue,
        reason: '★★★ 那句 cancel 必须在 **dispose** 里 —— '
            '只在 _holdSheetGuard 里 cancel 是不够的（那只是重装前清旧的）。\n'
            '★ 判据扫的是**局部窗口**（dispose 方法体），不是整个文件 —— '
            '因为源码里同一句在 _holdSheetGuard() 里也有一处，'
            '全局扫会恒真。',
      );
      /*
       * ★★ 2026-10-19（复核建议 + 实测，Lead 加）：断言「**恰好 1 处**」，
       *   而不只是「至少 1 处」。
       *
       * ```text
       * 为什么要这条：改成按大括号配对取**完整**函数体之后，
       *   判据变宽了 —— 若 dispose 里将来出现**第二处**同样的 cancel
       *   （比如抽成 helper 又被调两次），`hasMatch` 仍为 true ⇒ 恒绿。
       *
       * 三种形态实测（复核在 worktree 副本里跑的）：
       *   原样              ⇒ <1>  绿
       *   删掉 dispose 那处   ⇒ <0>  红 ✅
       *   ★ 在 dispose 里再加一处 ⇒ <2>  红 ✅ ← 这正是「变宽」的风险
       * ```
       *
       * ★ 而「只该有一处」本身就是一个**应当被断言的事实**：
       *   0 处 ⇒ 定时器不释放；2+ 处 ⇒ 清理逻辑被重复调用或抽成了 helper。
       */
      expect(
        RegExp(r'_sheetGuardTimer[?!]?\.cancel\(').allMatches(disposeBody).length,
        1,
        reason: '★★★ dispose 里必须有**且只有 1 处** _sheetGuardTimer?.cancel()。\n'
            '0 处 ⇒ 定时器不释放（350ms 后旧守卫会提前撤掉）。\n'
            '2+ 处 ⇒ 清理逻辑被重复调用或抽成了 helper。\n'
            '★ 这条是为了防「改成完整函数体后判据变宽」—— '
            '只断 hasMatch 的话，多出来的那处永远抓不到。',
      );

      /*
       * ★★ 2026-10-19（复核建议，Lead 加）：dispose 里的**关键**释放调用。
       *
       * ```text
       * 为什么只挑这 3 条（实测 dispose 函数体里共 24 个清理调用）：
       *   _player.dispose()        ⇒ 换页后还在放声音 / 占解码器
       *   _danmakuClient?.close()  ⇒ 旧弹幕连接不断，服务端看到重复会话
       *   super.dispose()          ⇒ 不调会抛
       *                             "ChangeNotifier was used after being disposed"
       *                             且 framework 在 debug 下断言失败
       *
       * ★ 其余 21 条**刻意不断言**（复核的判断，我采纳）：
       *   · `_xxxTimer?.cancel()` 一类（12 条）—— 删掉只是定时器多活几百 ms，
       *     由各自的功能测试覆盖（如本文件 ①② 就在测这个），
       *     重复断言违反「同一纪律只能有一个实现」。
       *   · `_xxx.dispose()` 的 ValueNotifier 一类（8 条）—— 删掉会被
       *     flutter_test 的泄漏检测直接抓到（`_cursorLive.dispose()` 的注释
       *     写着「否则 flutter_test 判泄漏」）⇒ **框架已经在守了**。
       *
       * ★★ 缺口（复核实测）：`t73_bili_wiring_test.dart:552` 提到了
       *   `_player.dispose()`，但只是把它当**位置基准**（比较与
       *   `_biliApi?.close()` 的先后），**不是当「必须存在」** ⇒
       *   实测删掉它会侥幸变红，但**把它移出 dispose 仍然绿**。
       * ```
       */
      for (final call in const <String>[
        '_player.dispose();',
        '_danmakuClient?.close();',
        'super.dispose();',
      ]) {
        expect(
          disposeCode.contains(call),
          isTrue,
          reason: '★★★ dispose 里必须有 `$call` —— '
              '不释放会在换页后继续占资源（播放器 / 网络连接），用户可感知。\n'
              '★ 注意 t73 那条只拿它当**位置基准**，把它移出 dispose 仍会绿。\n'
              '★★ 判的是**剥注释后**的代码（`_codeOnly`），且**带分号** ——\n'
              '   否则注释里那两处 `_player.dispose()` 的说明会满足它\n'
              '   （复核实测：未剥注释时删掉真实那行，测试仍全绿）。',
        );
      }
    });
  });
}
