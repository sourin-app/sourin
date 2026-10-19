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
      final disposeBody = src.substring(disposeIdx, disposeIdx + 2600);
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
    });
  });
}
