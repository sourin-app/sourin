// ═══════════════════════════════════════════════════════════════════════
//  task-67 需求⑤ —— 换源迁移（repoint_item）的跨层契约与调用点
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这个文件主要是**源码断言**（而不是跑 FFI）
//
// ```text
// `SourinCore.callAsync` 要真核心（sourin_core.dll），
// 而 `flutter test` 里必然加载失败（error code: 126）
// ⇒ "真的把记录搬过去了"这件事**只能**在 Rust 单测里验
//   （`store.rs` 的 repoint_* 六个用例，`cargo test --release --lib`）
// ```
// ★ 所以本文件负责 Rust 单测**覆盖不到**的那一半：
//   ```text
//   ① ★★★ 跨层 key 契约：Dart 发的 JSON key 必须与 Rust 读的 key **逐字相同**
//         —— 不一致不会报错，只会**静默什么都不做**（最坏的一类）
//   ② 调用点在 `setState` **之前**（否则拿不到旧源）
//   ③ 调用点被 try/catch 包住，且失败后**仍然**走 applySession
//   ④ 迁移在 `applySession` **之前** await（否则新源进度先落库会被覆盖）
//   ⑤ FFI 分发器里有 `repoint_item` 这条 arm
//   ```
//
// 跑法：
// ```powershell
// & .probe\flutter_test_lock.ps1 -Paths 'test/t67_repoint_test.dart' -Agent fix-file-dialog
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉行注释与块注释（判据对象是**代码**时必做）
///
/// ⚠️ 本仓大量长块注释里**引用**了被删掉的旧代码 —— 只剥行注释会让
/// "旧代码还在"这类断言**假绿**（task-63/67 都踩过）。
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

String readCode(String path) => stripComments(File(path).readAsStringSync());

/// 把 `_onDetailSwitchSource` 的**函数体**精确切出来
///
/// ★ 必须精确切 —— 本仓踩过"`substring(start)` 一直到文件末尾，
///   于是断言命中的是**后面另一个类**里的同名符号"（见
///   `t65_follow_cards_test.dart:183-217` 的完整复盘）。
String switchSourceBody() {
  final code = readCode('lib/ui/media_page.dart');
  final start = code.indexOf('Future<void> _onDetailSwitchSource(');
  expect(start, greaterThan(-1), reason: '必须能找到 _onDetailSwitchSource');
  // 切到**下一个方法声明**之前（`\n  Future<` / `\n  void ` / `\n  @override`）
  final rest = code.substring(start + 10);
  final m = RegExp(r'\n  (?:@override\n  )?(?:Future<|void |Widget |String )')
      .firstMatch(rest);
  final end = m == null ? code.length : start + 10 + m.start;
  return code.substring(start, end);
}

/// 把 `_onDetailSwitchSource` 里**包住 repointItem 的那个 catch 块**切出来
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 为什么必须切到 catch **体内**（这是红度证明抓出来的假绿洞）
/// ══════════════════════════════════════════════════════════════════
///
/// `.probe\t67u_dart_redproof.py` 的 M11 变异在 `} catch (e) {` 之后插入
/// 一行 `rethrow;` —— 运行时后果是**后面的 `applySession` 不可达**，
/// 也就是"用户点了换源，播放器却没换" ⇒ **换源被阻断**，
/// 正是 task-67 要消灭的那类症状。
///
/// 而本条用例**原来**的四条断言全是**结构位置**检查：
/// ```text
/// ① try 在 catch 之前（repointItem 在 try 里）
/// ② repointItem 之后出现过 `catch`
/// ③ applySession 在 repointItem 之后，且两者之间出现过 `catch`
/// ④ 两者之间出现过 `debugPrint`
/// ```
/// ⇒ 插入 `rethrow;` 后**四条依然全绿**：它们检查的是
///   「这些**串**在函数体里出现过」，**从来没有**检查 catch 体内是否
///   有控制流把后面的 `applySession` 短路掉。
/// ★ 与 Lead 发现的 `..t`→`..f` 洞**同一族**（证明"串出现过"，
///   不证明"行为正确"）⇒ M11 实测 verdict = **GREEN**（假绿）。
///
/// ⇒ 修法：按**大括号配平**从 `} catch` 起切出 catch 体，在**体内**断言
///   「只有 debugPrint，没有任何短路控制流」。
///
/// # 为什么能安全地数大括号
///
/// ```text
/// ① 入参是 switchSourceBody() 的返回值，而它经过 readCode ⇒
///    注释（含块注释）**已被剥掉** ⇒ 注释里引用的旧代码不会假绿（本仓踩过）
/// ② `catch (e)` 的括号里没有大括号 ⇒ `indexOf('{', catchAt)` 拿到的
///    必然是**块体**的开括号
/// ③ 块体内目前只有一条 debugPrint，字符串里没有**不配平**的大括号
///    （`$e` 是 `$` 插值，不含大括号；即便写成 `${e}` 也是成对的）
/// ```
String switchCatchBody(String body) {
  final iRepoint = body.indexOf('repointItem');
  expect(iRepoint, greaterThan(-1), reason: '★ 必须能找到 repointItem');

  final catchAt = body.indexOf('} catch', iRepoint);
  expect(catchAt, greaterThan(-1),
      reason: '★ repointItem 之后必须有 `} catch` —— 否则迁移失败会打断换源');

  final open = body.indexOf('{', catchAt);
  expect(open, greaterThan(-1), reason: '★ `} catch` 后面必须有块体 `{`');

  var depth = 0;
  for (var i = open; i < body.length; i++) {
    if (body[i] == '{') depth++;
    if (body[i] == '}') {
      depth--;
      if (depth == 0) return body.substring(open + 1, i);
    }
  }
  fail('★ `} catch` 的块体大括号不配平');
}

/// 把 `ffi.rs` 里 `"repoint_item" =>` 这条 **arm 的函数体**精确切出来
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 为什么必须"精确切"而不是 `substring(ri, ri + 1600)`
/// ══════════════════════════════════════════════════════════════════
///
/// 我第一版用的是**固定 1600 字符窗口** —— 它当场就坏了：
/// ```text
/// [T67] Rust repoint_item arm 读的 key =
///       {fromProvider, fromId, toProvider, toId, provider, id, title, cover, kind}
///                                                        ^^^^^^^^^^^^^^^^^^^^^^^^
///                                                        ★ 这五个是**下一条 arm**
///                                                          (`set_favorite`) 的
/// ⇒ 断言 "Rust 只该读这四个" 假红
/// ```
/// ★ 根因：`repoint_item` 的 arm 实际只有 ~27 行（L1105-1131），
///   1600 字符**越过了**它的结束大括号，把下一条 arm 一起切了进来。
/// ⇒ 这是**仪器边界切错**，不是产品缺陷 —— 与 `t65_follow_cards_test.dart`
///   踩的是**同一族**（那里是切到文件末尾，命中了后面另一个类的同名符号）。
///
/// # 修法：按**大括号配平**切到本条 arm 结束
///
/// ```text
/// 从 `"repoint_item" =>` 起，找到第一个 `{`，
/// 然后数大括号直到配平 ⇒ 那就是这条 arm 的精确范围。
/// ```
/// ★ 不依赖任何魔数（行数/字符数），arm 内部怎么改都不会切错。
String rustRepointArm() {
  final code = readCode('rust/sourin_core/src/ffi.rs');
  const key = '"repoint_item" =>';
  final at = code.indexOf(key);
  expect(at, greaterThan(-1),
      reason: '★★★ ffi.rs 里必须有 `"repoint_item" =>` 这条 arm —— '
          'FFI 是通用分发器，少了它 Dart 调用会走到 default 分支报"未知命令"');

  final open = code.indexOf('{', at);
  expect(open, greaterThan(-1), reason: '"repoint_item" arm 后面必须有 `{`');

  var depth = 0;
  for (var i = open; i < code.length; i++) {
    if (code[i] == '{') depth++;
    if (code[i] == '}') {
      depth--;
      if (depth == 0) return code.substring(at, i + 1);
    }
  }
  fail('"repoint_item" arm 的大括号不配平');
}

/// 把某个 `.rs` 函数的**函数体**按大括号配平精确切出来
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 为什么不能用 `substring(i, i + 魔数)`
/// ══════════════════════════════════════════════════════════════════
///
/// 本文件的 ①③④ 三条**原来**分别用 `i + 1600` / `i + 2500` / `i + 17000`。
/// 三个魔数**各错各的**，全是同一根因的三种表现：
/// ```text
/// ① i + 1600  ——  越过 repoint_item 的 arm 结束大括号
///                  ⇒ 把下一条 arm（set_favorite）的 key 也收进来
///                  ⇒ 断言 "Rust 只该读这四个" **假红**
///                  Actual: {fromProvider, fromId, toProvider, toId,
///                           provider, id, title, cover, kind}
/// ③ i + 2500  ——  commands_write.rs 只有 14412 字符，函数起于 13499
///                  ⇒ **超出文件末尾** ⇒ substring **抛异常**（不是断言失败）
/// ④ i + 17000 ——  恰好盖住四张表的 DELETE，**但纯属侥幸**
///                  （往函数里加 10 行注释就会失效）
/// ```
/// ★ 共同根因：**判据的边界靠"估一个够大的数"**，而不是**算出来**。
///   本仓已有同族教训（`t65_follow_cards_test.dart` 切到文件末尾，
///   命中了后面另一个类的同名符号）。
///
/// ⇒ 正确做法：从函数签名起，找到第一个 `{`，数大括号直到配平。
///    ★ 不依赖任何魔数 —— 函数内部怎么改都不会切错。
String rustFnBody(String path, String signature) {
  final code = readCode(path);
  final at = code.indexOf(signature);
  expect(at, greaterThan(-1), reason: '★ 找不到 `$signature`（$path）');

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

/// 切某个 **Dart** 方法的函数体（同一套大括号配平）
///
/// ★ 与 `rustFnBody` 是**同一个算法** —— 只是名字让调用点读起来诚实：
///   `rustFnBody('lib/ui/player_page.dart', …)` 会让读者以为在切 Rust。
String dartFnBody(String path, String signature) => rustFnBody(path, signature);

/// 从 `repoint_item` 的函数体里切出某张表的 `Some(t) =>` **合并臂**
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 为什么断言必须落在**臂内**，而不是整个函数体
/// ══════════════════════════════════════════════════════════════════
///
/// 「其余字段按裁决」这条用例**原来**用 10 条正则对**整个** 21KB 函数体
/// 做 `hasMatch`。Lead 用 `.probe\t67_rule_attribution3.py` 逐条量了命中的
/// **归属**：
/// ```text
/// Progress.Some(t) 与 HistoryEntry.Some(t) 两臂合计只贡献 1 条命中；
/// 9 条「通过」里 6 条唯一命中来自 Favorite、2 条来自 SkipMarker。
/// 两臂的「取 TO」字段**一个都没显式写出**
/// （title / cover / episode_title / episode_id / duration /
///   last_episode_count / updated_at 全走 `..t`）。
/// ```
/// ⇒ 那些正则证明的是「这 10 个串在 21KB 函数里**出现过**」，
///   不是「这 4 张表按裁决合并」。
///
/// ★ 真实后果（这才是必须修的原因）：把 Progress 臂的 `..t` 改成 `..f`
///   （= 「取 FROM 的」），那条断言**仍然全绿** —— 因为该臂内本来就没有
///   任何正则会命中，改前改后都不命中
///   ⇒ **该用例对 progress 段的合并语义零分辨力**。
///
/// ⇒ 修法：按**大括号配平**从 `Some(t) =>` 起切出每条臂，在**臂内**断言。
///   ★ 与 `rustFnBody` 同一手法，不依赖任何魔数。
///
/// # 为什么能安全地数大括号
///
/// ```text
/// ① 入参是 rustFnBody 的返回值 ⇒ 注释（含块注释）**已被剥掉**
///    ⇒ 注释里引用的旧代码不会造成假绿（本仓踩过）
/// ② 四条臂内部**没有字符串字面量**（INSERT 语句在 match 之外）
///    ⇒ 不存在 `{` 出现在字符串里导致配平错位
/// ```
String rustMatchArm(String fnBody, String ctor) {
  final noneAt = fnBody.indexOf('None => $ctor {');
  expect(noneAt, greaterThan(-1), reason: '★ 找不到 `None => $ctor {` 臂');

  final someAt = fnBody.indexOf('Some(t) =>', noneAt);
  expect(someAt, greaterThan(-1),
      reason: '★ `$ctor` 的 None 臂后面必须紧跟 `Some(t) =>` 臂');

  final open = fnBody.indexOf('{', someAt);
  expect(open, greaterThan(-1), reason: '★ `$ctor` 的 `Some(t) =>` 后面必须有 `{`');

  var depth = 0;
  for (var i = open; i < fnBody.length; i++) {
    if (fnBody[i] == '{') depth++;
    if (fnBody[i] == '}') {
      depth--;
      if (depth == 0) return fnBody.substring(someAt, i + 1);
    }
  }
  fail('★ `$ctor` 的 `Some(t) =>` 臂大括号不配平');
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① ★★★ 跨层 key 契约（最高价值的一条）
  // ═══════════════════════════════════════════════════════════════════

  group('① ★★★ Dart 发的 JSON key 必须与 Rust 读的 key 逐字相同', () {
    test('★★★ 四个参数名：Dart payload == Rust a.str()', () {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 为什么这是**最重要**的一条断言
       * ══════════════════════════════════════════════════════════════
       *
       * FFI 是**通用 JSON 分发器**（`ffi.rs` 的 `sourin_call`），
       * 参数靠**字符串名**取：
       * ```rust
       * let from_provider = match a.str("fromProvider") { ... }
       * ```
       * 而 Dart 侧是：
       * ```dart
       * SourinCore.callAsync('repoint_item', {'fromProvider': ...});
       * ```
       * ★ 两边名字只要差一个字符（如 `from_provider` vs `fromProvider`），
       *   Rust 的 `a.str(...)` 就返回 Err ⇒ **报错**（这个还好）；
       *   但若**四个都写错**、或写成了"有默认值"的取法，就会**静默什么都不做**
       *   —— 用户以为记录搬过去了，实际没有。这正是最坏的一类。
       * ⇒ 所以必须**逐字比对两边的字符串**，而不是各测各的。
       */
      final dart = readCode('lib/core/sourin_api.dart');

      // Dart 侧：repointItem 的 payload
      final di = dart.indexOf('static Future<void> repointItem(');
      expect(di, greaterThan(-1), reason: '★ SourinApi.repointItem 必须存在');
      final dartFn = dart.substring(di, di + 1200);
      expect(dartFn.contains("callAsync('repoint_item'"), isTrue,
          reason: "★ 命令名必须是 'repoint_item'");

      // Rust 侧：repoint_item 的 arm（★ 按大括号配平精确切，不用魔数）
      final rustArm = rustRepointArm();
      // ★ 仪器自检：切片必须**不含**下一条 arm（否则边界又切错了）
      expect(rustArm.contains('"set_favorite" =>'), isFalse,
          reason: '★★ 仪器自检：arm 切片越界了（切进了下一条 arm）—— '
              '这会让"Rust 只该读这四个"假红');

      // ★★★ 逐字比对四个 key
      for (final k in const [
        'fromProvider',
        'fromId',
        'toProvider',
        'toId',
      ]) {
        expect(dartFn.contains("'$k'"), isTrue,
            reason: "★ Dart payload 必须含 key '$k'");
        expect(rustArm.contains('a.str("$k")'), isTrue,
            reason: '★★★ Rust 侧必须用 `a.str("$k")` 取 —— '
                '与 Dart 发的 `$k` 逐字相同。差一个字符就会静默失效');
      }
    });

    test('★★ 反向：Rust arm 不许读 Dart 没发的 key', () {
      final dart = readCode('lib/core/sourin_api.dart');
      final di = dart.indexOf('static Future<void> repointItem(');
      final dartFn = dart.substring(di, di + 1200);
      final rustArm = rustRepointArm();

      final reads = RegExp(r'a\.str\("([A-Za-z_]+)"\)')
          .allMatches(rustArm)
          .map((m) => m.group(1)!)
          .toSet();
      // ignore: avoid_print
      print('[T67] Rust repoint_item arm 读的 key = $reads');
      expect(reads, {'fromProvider', 'fromId', 'toProvider', 'toId'},
          reason: '★ Rust 只该读这四个（多读一个 ⇒ Dart 没发 ⇒ 必然 Err）');
      for (final k in reads) {
        expect(dartFn.contains("'$k'"), isTrue,
            reason: "★ Rust 读的 '$k' 必须出现在 Dart payload 里");
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 调用点：位置与顺序（都在 media_page.dart）
  // ═══════════════════════════════════════════════════════════════════

  group('② ★★ 调用点 _onDetailSwitchSource：位置与顺序', () {
    test('★★★ 迁移必须在 setState **之前**（否则拿不到旧源）', () {
      final body = switchSourceBody();
      // ignore: avoid_print
      print('[T67] _onDetailSwitchSource 片段长度 = ${body.length}');

      // ★ 仪器自检：片段必须**不含**下一个方法（否则边界切错了）
      expect(body.contains('Future<void> _onDetailLoaded('), isFalse,
          reason: '★★ 仪器自检：片段不许包含 _onDetailLoaded —— 否则边界切错');
      expect(body.contains('repointItem'), isTrue,
          reason: '★ 仪器自检：片段里必须能找到 repointItem');

      final iRepoint = body.indexOf('repointItem');
      final iSetState = body.indexOf('setState(() {');
      expect(iSetState, greaterThan(-1), reason: '★ 必须能找到 setState');
      expect(iRepoint, lessThan(iSetState),
          reason: '★★★ 迁移必须在 setState **之前** —— '
              '`_provider` 一旦被改写，就再也拿不到"旧源是谁"了');
    });

    test('★★★ 迁移用旧值作 from、新值作 to（不许写反）', () {
      final body = switchSourceBody();
      expect(body.contains('fromProvider: _provider'), isTrue,
          reason: '★ from 必须是**旧**的 `_provider`（setState 之前读到的）');
      expect(body.contains('fromId: _contentId'), isTrue,
          reason: '★ from 必须是**旧**的 `_contentId`');
      expect(body.contains('toProvider: provider'), isTrue,
          reason: '★ to 必须是**新**的入参 `provider`');
      expect(body.contains('toId: id'), isTrue,
          reason: '★ to 必须是**新**的入参 `id`');
      // ★ 反向：不许写成 fromProvider: provider（那是"新→新"，等于没迁移）
      expect(body.contains('fromProvider: provider'), isFalse,
          reason: '★★ fromProvider 不许写成新入参 —— 那是"新→新"，什么都没做');
    });

    test('★★★ 迁移在 applySession **之前** await（否则新进度会被覆盖）', () {
      final body = switchSourceBody();
      final iRepoint = body.indexOf('repointItem');
      final iApply = body.indexOf('applySession');
      expect(iApply, greaterThan(-1), reason: '★ 必须能找到 applySession');
      expect(iRepoint, lessThan(iApply),
          reason: '★★★ 迁移必须在 applySession **之前** —— '
              '`applySession` 会立刻起播并写**新**进度；'
              '若迁移还没做完，之后"把旧行合并进新行"会把刚写的进度覆盖掉');
      // ★ 必须是 await（不是 unawaited）—— 否则上面那条顺序保证不成立
      expect(RegExp(r'await\s+SourinApi\.repointItem\(').hasMatch(body), isTrue,
          reason: '★★ 必须 `await` —— `unawaited` 会让"先迁移后起播"的顺序失效');
    });

    test('★★★ 失败**不阻断**换源（catch 住 + 仍然走 applySession）', () {
      final body = switchSourceBody();
      final iRepoint = body.indexOf('repointItem');
      final iApply = body.indexOf('applySession');

      // ① repointItem 必须在 try 里
      final before = body.substring(0, iRepoint);
      final lastTry = before.lastIndexOf('try {');
      final lastCatch = before.lastIndexOf('catch');
      expect(lastTry, greaterThan(lastCatch),
          reason: '★★★ repointItem 必须在 `try {` 里 —— '
              '否则迁移失败会**把整个换源动作打断**（用户点了换源却什么都没发生）');

      // ② 必须有 catch
      final after = body.substring(iRepoint);
      expect(after.contains('catch'), isTrue,
          reason: '★★★ 必须有 catch —— 记录搬不动也得让用户能看');

      // ③ ★★ 关键：applySession 在 try/catch **之外**（所以失败也会执行）
      expect(iApply, greaterThan(iRepoint), reason: '★ applySession 在后面');
      final between = body.substring(iRepoint, iApply);
      expect(between.contains('catch'), isTrue,
          reason: '★ repoint 与 applySession 之间必须有 catch（说明 catch 包住了 repoint）');

      // ④ 失败要**响亮**（debugPrint），不许静默吞
      expect(between.contains('debugPrint'), isTrue,
          reason: '★ 失败必须 debugPrint 如实记 —— 本仓纪律"失败不许静默"');

      // ⑤ ★★★ catch **体内**不许有短路控制流
      //
      // ══════════════════════════════════════════════════════════════
      // ★★★ 这一条是 M11 红度证明抓出来的**假绿洞**的补丁
      // ══════════════════════════════════════════════════════════════
      //
      // 上面 ①~④ 全是**结构位置**检查 —— 它们检查的是「这些**串**在
      // 函数体里出现过」，**从来没有**检查 catch 体内是否有控制流把
      // 后面的 `applySession` 短路掉。
      //
      // `.probe\t67u_dart_redproof.py` 的 M11 变异在 `} catch (e) {` 之后
      // 插入一行 `rethrow;`：运行时后果是 **`applySession` 不可达**
      // （用户点了换源，播放器却没换）⇒ 换源被阻断。
      // ★ 而 ①~④ **依然全绿** ⇒ M11 实测 verdict = **GREEN**（假绿）。
      //
      // ★ 与 Lead 发现的 `..t`→`..f` 洞**同一族**：证明"串出现过"，
      //   不证明"行为正确"。⇒ 必须**切进 catch 体内**断言。
      final catchBody = switchCatchBody(body);
      expect(catchBody.length, greaterThan(20),
          reason: '★ 仪器自检：catch 体切出来不能是空的 —— '
              '若切片器坏了，下面的"不含 rethrow"会**真空通过**');

      expect(RegExp(r'\brethrow\b').hasMatch(catchBody), isFalse,
          reason: '★★★ catch 体内**不许** `rethrow` —— '
              'rethrow 会让异常继续冒泡 ⇒ 下面的 `applySession` 不再执行 ⇒ '
              '**换源被阻断**（用户点了换源却什么都没发生）。'
              '★ 这正是 M11 变异：旧断言（只查结构位置）对它**零分辨力**');

      expect(RegExp(r'\bthrow\b').hasMatch(catchBody), isFalse,
          reason: '★★★ catch 体内也不许新起 `throw` —— 同理，异常冒泡会跳过 applySession');

      expect(RegExp(r'\breturn\b').hasMatch(catchBody), isFalse,
          reason: '★★★ catch 体内不许 `return` —— 提前返回同样会让 applySession 不执行');

      expect(catchBody.contains('debugPrint'), isTrue,
          reason: '★ catch 体内必须**仍然**有 debugPrint（失败不许静默）—— '
              '与上面 ④ 的区别：④ 查的是"两者之间出现过"，这里查的是"catch 体内有"');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 只在**跨源**时迁移（防误迁移）
  // ═══════════════════════════════════════════════════════════════════

  group('③ ★★★ 只在跨源时迁移（防把两部作品的记录混在一起）', () {
    test('★★★ Rust 侧有 provider 相同的守卫', () {
      /*
       * ⚠️ 这里**原来**是 `code.substring(i, i + 2500)` —— 一个**魔数窗口**。
       *    实测 `commands_write.rs` 只有 14412 字符，而 `repoint_item`
       *    起于 13499 ⇒ `i + 2500` **超出文件末尾**
       *    ⇒ Dart 的 `substring` 直接**抛异常**（不是断言失败，是崩）。
       *    ★ 与同文件 ① 的 `i + 1600`、④ 的 `i + 17000` 是**同一族**错误：
       *      **用魔数切边界**。① 那次越界是"多切进了下一条 arm"（假红），
       *      这次是"切出文件外"（崩溃）—— 同一个根因的两种表现。
       * ⇒ 改用 `_rustFnBody()` 按**大括号配平**精确切。
       */
      final body = rustFnBody('rust/sourin_core/src/commands_write.rs',
          'pub fn repoint_item(');

      expect(
        RegExp(r'if\s+from_provider\s*==\s*to_provider\s*\{').hasMatch(body),
        isTrue,
        reason: '★★★ 必须有 `from_provider == to_provider` 守卫 —— '
            '同一个 provider 内换**线路**不是换源；'
            '而"同 provider 不同 id"是**另一部作品**，'
            '迁移会把两部不相干的记录混在一起（严重）',
      );
      expect(body.contains('return Ok(())'), isTrue,
          reason: '★ 守卫命中时必须**直接返回**（不是 Err —— 换线路是合法操作）');
    });

    test('★★★ 播放页的 _remoteSwitchSource **不该** repoint（换线路）', () {
      /*
       * `player_page.dart:4165 _remoteSwitchSource(code)` 是
       * **按 code 换线路**（同一个 provider 内）——
       * 它调 `_resolveAndPlay(_provider, _contentId, ep?.id, code)`，
       * provider/id **原样传**，只有 code 变。
       * ⇒ ★ 它**不该**、也**没有**调 repointItem。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ task-77：口径从「**整文件**不含 repointItem」收窄到
       *     「**这个函数体**不含」
       * ══════════════════════════════════════════════════════════════
       *
       * # 为什么必须收窄（不是"为了让测试变绿"）
       *
       * 原断言是 `readCode('lib/ui/player_page.dart').contains('repointItem')
       * == false` —— 它断言的是**整份文件**。
       * 而它的 reason 逐字写的是：
       * ```text
       * 'player_page 不该调 repointItem ——
       *  它的换源是"同 provider 换线路"，provider 没变 ⇒ 不该迁移'
       * ```
       * ⇒ ★ 这条 reason 的**论证只覆盖 `_remoteSwitchSource`**（换线路）。
       *   它并**没有**、也不可能论证「播放器页里**跨源**换源也不该迁移」——
       *   而 `_applySwitch(SwitchPick p)`（`:3326`）恰恰是**跨源**的：
       *   `p.provider` 与 `_provider` **可以不同**（`SwitchPick` 自带
       *   provider 字段，见 `source_switch_dialog.dart:93-107`）。
       *
       * ```text
       * 用户看到的（task-77 缺口）：
       *   播放器内点「换源」→ 换到另一个 provider
       *   ⇒ 历史/追更/收藏里出现**两条**（旧源一条、新源一条）
       *   ⇒ 且旧源上的进度**不被带走**
       * ```
       * ⇒ 原来那条断言若保持"整文件"口径，就会把**修复**判成回归。
       *
       * # ★ 所以这不是"删断言"，是**把断言精确到它真正论证的那一段**
       *
       * 反面（`_remoteSwitchSource` 不许 repoint）**仍然守着**，
       * 而且守得更准 —— 原来它靠"整文件没有"间接成立，
       * 现在直接盯住那个函数体。
       * ★ 本仓先例：`t67_stage1_symptom_test.dart:415-459` 那条测试
       *   原本**反向**刻画缺陷（"全项目没有迁移路径"），阶段 2 落地后
       *   **反转**成守住修复，注释明写「不许把这条测试删掉了事」。
       *   这里是**同一族**处置：结论没变，范围收窄。
       */
      final body = dartFnBody('lib/ui/player_page.dart',
          'Future<void> _remoteSwitchSource(String code) async {');
      expect(body.contains('_resolveAndPlay'), isTrue,
          reason: '★ 仪器自检：切出来的必须真是那个函数体'
              '（它确实调 _resolveAndPlay）—— '
              '否则下面的 isFalse 是**假绿**');
      expect(body.contains('repointItem'), isFalse,
          reason: '★★★ _remoteSwitchSource 不该调 repointItem —— '
              '它是"同 provider 换线路"，provider 没变 ⇒ 不该迁移');
    });

    test('★★ 入口守卫仍在（同一个 provider+id ⇒ 直接返回）', () {
      final body = switchSourceBody();
      expect(
        RegExp(r'if\s*\(\s*provider\s*==\s*_provider\s*&&\s*id\s*==\s*_contentId\s*\)\s*return\s*;')
            .hasMatch(body),
        isTrue,
        reason: '★ 原有的入口守卫必须保留 —— 点同一个源不该触发任何动作',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ Rust 侧：四张表都要迁 + 旧行要删
  // ═══════════════════════════════════════════════════════════════════

  group('④ ★★ Rust Db::repoint_item：四张表都要动', () {
    test('★★★ 四张表都在同一个事务里，且都 DELETE 旧行', () {
      // ★ 按大括号配平精确切（原来用 `i + 17000` 魔数 —— 见 `rustFnBody` 的说明）
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'pub fn repoint_item(');

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-12 按集扩容：`progress` 的删除口径从 `key` 改成 `item_key`
       * ══════════════════════════════════════════════════════════════
       *
       * ```text
       * 老口径：progress 一个作品**一行**，主键就是作品键 ⇒ DELETE ... WHERE key=from
       * 新口径：progress 一个作品**每集一行**（主键 = provider:native_id:episode_id）,
       *         而 FROM 的那 N 行的**共同**标识是 item_key（= provider:native_id）
       *         ⇒ 必须 DELETE ... WHERE item_key=from
       * ```
       *
       * ★ 这两句**不是等价写法**，改动也不是「顺手改个列名」：
       * ```text
       * 用 key=    ⇒ 只删掉**恰好等于** from_key 的那一行
       *              （而按集后 from_key 下面有 N 行，且**一行都不叫** from_key）
       *              ⇒ 换源后旧源的 N 行**全部残留**
       *              ⇒ 用户在「继续观看」里看到同一部剧两条（新旧源各一）
       * ```
       * ⇒ 下面**同时**用料正反两条钉住：必须用 item_key，且不许退回 key。
       *   （只写正向那条的话，将来有人把另三张表也"统一"成 item_key 时不会红 ——
       *     而 favorites/history/skip_markers 仍是按作品一行，用 item_key 也不算错，
       *     所以这里只对 progress 加反向。）
       */
      for (final t in const [
        'favorites',
        'history',
        'skip_markers',
      ]) {
        expect(body.contains('DELETE FROM $t WHERE key=?1'), isTrue,
            reason: '★★★ `$t` 的旧行必须 DELETE —— '
                '★ skip_markers 也是 provider:id 分键的，漏它就是同一个坑');
      }

      // ── progress：按集口径，必须按 item_key 删 ────────────────────
      expect(body.contains('DELETE FROM progress WHERE item_key=?1'), isTrue,
          reason: '★★★ `progress` 的旧行必须按 **item_key** 删 —— '
              '按集后 FROM 作品有 N 行（每集一行），它们的共同标识是 item_key');
      // ★ 反向：不许退回按 key 删（会漏删 N-1 行 ⇒ 换源后同一部剧两条）
      expect(
          RegExp(r'DELETE FROM progress WHERE key=\?1').hasMatch(body), isFalse,
          reason: '★★★ `progress` 不许按 `key` 删 —— '
              '按集后 FROM 的 N 行**一行都不叫** from_key ⇒ 等于一行没删 '
              '⇒ 旧源的行全部残留 ⇒ 用户在列表里看到同一部剧两条。'
              '★ 这条反向断言是本次（2026-10-12）**补回**的：'
              '原正向断言改成 item_key 后，若没有它，这个坑就没人守了');

      // ★ 一个事务（不是四次独立写）
      expect(body.contains('unchecked_transaction'), isTrue,
          reason: '★★★ 必须在一个事务里 —— 中途崩溃会丢数据');
      expect(body.contains('tx.commit()'), isTrue, reason: '★ 必须显式提交');

      // ★ 幂等
      expect(body.contains('if from_key == to_key'), isTrue,
          reason: '★ from == to 必须直接返回（否则"先删后写"会把唯一那行删掉）');
    });

    test('★★★ position 取 **max**（m00753 ③ 裁决，取代 m00370 的"取 FROM"）', () {
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'pub fn repoint_item(');

      expect(body.contains('position: f.position.max(t.position)'), isTrue,
          reason: '★★★ position 必须取 **max(FROM, TO)** —— '
              '单调不减，换源不该让进度**倒退**'
              '（与 Legado 在 (chapterIndex, chapterPos) 上取单调 max 一致）。'
              '★ 无职转生那组（FROM=91 / TO=766）是**唯一可区分锚点**：'
              '取 FROM 会得到 91 ⇒ 用户进度倒退 675 秒');
      // ★ 反向：不许再回到"取 FROM"（m00370 旧规则，已被 m00753 ③ 取代）
      expect(RegExp(r'position:\s*f\.position\s*,').hasMatch(body), isFalse,
          reason: '★★ position 不许取 FROM 的 —— 那是 m00370 在没有集号概念时'
              '定的规则，已被 m00753 ③ 点名取代');
      // ★ 反向：也不许取 TO 的（会丢掉 FROM 上更大的进度）
      expect(RegExp(r'position:\s*t\.position').hasMatch(body), isFalse,
          reason: '★★ position 不许取 TO 的 —— 那会让"看了一半"变成"刚开始"');
      // ★ finished 仍取 FROM（决策点，完整论证见 store.rs 的文档）
      expect(RegExp(r'finished:\s*f\.finished').hasMatch(body), isTrue,
          reason: '★ finished 取 FROM 的 —— 决策点：若 TO.finished=true 而 '
              'FROM.finished=false，取 TO 会让 continue_watching 的 '
              '`finished=0` 过滤把这条**刚恢复的进度**直接滤掉');
    });

    test('★★★ 三态合并：集号匹配才携带（m00753 ④⑤⑦）', () {
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'pub fn repoint_item(');

      // ① ★★★ 必须真的**解析集号**，而不是比较字符串
      expect(body.contains('episode_number_from_title('), isTrue,
          reason: '★★★ 必须用集号解析器比较 —— 直接比字符串会把 '
              '`第01集` 与 `第1集` 判为不同 ⇒ 无职转生那组的 766 秒被丢掉'
              '（这正是本任务要修的形态）');
      // ② ★★★ `Option` 比较恰好就是裁决⑤的四条
      expect(RegExp(r'if\s+ep_f\s*==\s*ep_t\s*\{').hasMatch(body), isTrue,
          reason: '★★★ 必须用 `ep_f == ep_t` 的 **Option 比较** —— '
              '`None == None` 为真（两边都解析不出 ⇒ 视为匹配，单片时 '
              'position 是同一段视频的时间偏移，携带有意义）；'
              '`None == Some(_)` 为假（只有一侧 ⇒ 取保守侧，不携带）');
      // ③ ★★ TO 无行 ⇒ 整行照搬（不重置为 0）
      expect(RegExp(r'None\s*=>\s*Progress\s*\{').hasMatch(body), isTrue,
          reason: '★★ TO 无行必须**整行搬到 TO 的 key**（原值照搬）—— '
              '★ 这是最常见的触发场景（用户因当前源卡/坏而换源，新源从没看过）；'
              '在那里重置为 0 ⇒ 每次换源都丢进度 ⇒ 功能反而有害');
      /*
       * ④ ★★★ 不匹配 ⇒ TO 行**原样返回**（不携带 FROM 的 position）
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-12 按集扩容：progress 侧的**形状变了**，判据必须跟着改
       * ══════════════════════════════════════════════════════════════
       *
       * ```text
       * 老：progress 一个作品一行 ⇒ 直接 `match to { None => …, Some(t) => … }`
       *     不匹配时走 `else { t }`
       * 新：progress 一个作品**每集一行** ⇒ 先要在 TO 里**找出同一集**：
       *     to_idx = to_rows.iter().position(|t| …集号判定…)
       *     to_idx 为 None ⇒ 该集在 TO 没有 ⇒ 整行搬过去
       *     to_idx 为 Some ⇒ 保留 TO 行
       * ```
       * ⇒ `else { t }` 这**一个**串被 `position` 的语义吸收了
       *   （"没找到同一集"= 老口径的"不匹配"，两者都在 `position` 里返回 None）。
       *
       * ★ 但**语义不能丢**：本用例原来要防的是「集号不匹配却把 FROM 的
       *   position 带过去」（用户在新源上被弹到没看过的位置）。
       *   所以判据换成「**配对判据本身**」，而不是某个分支的写法：
       */
      // ④-a ★★★ 必须真的**按集配对**（`to_rows.iter().position`）—— 这是新形状的入口
      //
      //   ⚠️ 2026-10-13（CodeRabbit on #23）：判据从 `find(` 换成 `position(`。
      //     `find` 返回的是 `&Progress` **引用**，而每轮写完库后必须把合并结果
      //     写回 `to_rows` 快照（见 ④-e）—— 持有引用就没法写。换成下标即可两全。
      expect(
          RegExp(r'to_rows\s*\.\s*iter\(\)\s*\.\s*position\(').hasMatch(body), isTrue,
          reason: '★★★ progress 必须**逐集**在 TO 里找同一集（`to_rows.iter().position(…)`）'
              '—— 按集后 FROM 有 N 行，不逐集配对就会把别的集当成"同一集"；'
              '★ 用 `position`（下标）而不是 `find`（引用）是因为每轮要把合并结果'
              '**写回**快照，持有引用就写不了');
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-13：④-b / ④-c 从「整函数体」收紧为「按段断言」
       *     （CodeRabbit #21:731 / #23:722 —— 两条都指出原判据可被绕过）
       * ══════════════════════════════════════════════════════════════
       *
       * 原判据的两个洞（逐条量过）：
       *   · ④-b `RegExp(r'if\s+ep_f\s*==\s*ep_t\s*\{')` 只可能命中 **history**
       *     臂 —— progress 侧是配对闭包（`find` / `position`）里的**裸表达式** `ep_f == ep_t`，
       *     没有 `if … {` ⇒ 把 progress 闭包改成 `ep_f.is_some() && ep_f == ep_t`
       *     甚至改成恒真，这条**仍然全绿**。
       *   · ④-c 计数在整个函数体上做 ⇒ 现计数 3（progress 闭包 2 + history 1）
       *     ⇒ 只要 history 那一次调用还在，progress 的判据怎么改都能过。
       * ⇒ 修法：把函数体**切成 progress 段与 history 段**，各自在段内断言。
       *
       * ★ 分段锚点的选择（**不用** `HistoryEntry` 这个词 —— 它在本函数里出现
       *   3 次：`None => HistoryEntry {`、`let from: Option<HistoryEntry>`、
       *   以及文档注释；用词定位会把 progress 段切歪）：
       *   · progress 段的**代码**起点 = `let from_rows`
       *   · history 段的起点 = `let from: Option<HistoryEntry>`
       *   两个串在整个 `store.rs` 里都**只出现一次**（已核）。
       */
      final progAt = body.indexOf('let from_rows');
      final histAt = body.indexOf('let from: Option<HistoryEntry>');
      expect(progAt, greaterThan(-1),
          reason: '★ 仪器自检：progress 段的代码起点 `let from_rows` 必须找得到');
      expect(histAt, greaterThan(progAt),
          reason: '★ 仪器自检：history 段的起点必须在 progress 段之后');
      final progSection = body.substring(progAt, histAt);
      final histSection = body.substring(histAt);
      // ★ 仪器自检：两段都得切出非空内容，否则下面的断言会**真空通过**
      expect(progSection.length, greaterThan(200));
      expect(histSection.length, greaterThan(200));

      // ④-b ★★★ progress 段的配对判据必须是**集号比较**（而不是按行号/下标这种位置猜测）
      expect(
          RegExp(r'(?:find|position)\(\|t\|[\s\S]{0,800}?\bep_f\s*==\s*ep_t')
              .hasMatch(progSection),
          isTrue,
          reason: '★★★ progress 的配对闭包里必须**真的**比集号'
              '—— 判据限定在 progress 段内（且限定 800 字符窗口）⇒ '
              '换成恒真闭包（`|t| true`）立刻变红。'
              '★ 老判据 `if\\s+ep_f\\s*==\\s*ep_t\\s*\\{` 只命中 history 臂；'
              '★ 闭包名 `find` / `position` 都接受 —— #23 从 `find` 改下标'
              '（`position`）是为了每轮能把合并结果写回快照，判据本身没变');
      /*
       * ★★ 而且必须**恰好是**这个比较 —— 不许加任何额外条件。
       *   CR 给的绕过形态就是 `ep_f.is_some() && ep_f == ep_t`：
       *   它**仍含** `ep_f == ep_t` ⇒ 上面那条宽判据抓不住。
       *   这条要求该比较**独占一行**（可带行尾注释）。
       */
      expect(
          RegExp(r'^\s*ep_f\s*==\s*ep_t\s*(//[^\n]*)?$', multiLine: true)
              .hasMatch(progSection),
          isTrue,
          reason: '★★★ progress 的配对判据必须**恰好**是 `ep_f == ep_t` 的 Option 比较'
              '（独占一行）—— `ep_f.is_some() && ep_f == ep_t` 会让「两侧都解析不出'
              '集号」的单片不再配对 ⇒ 用户换源后单片进度每次丢光');
      // ★ 反向：progress 段的配对判据不许退化成恒真/恒假
      expect(
          RegExp(r'(?:find|position)\(\|\w+\|\s*(true|false)\s*\)')
              .hasMatch(progSection),
          isFalse,
          reason: '★★ progress 的配对闭包不许恒真/恒假 —— 那等于**不做**集号判定');
      // ④-c ★★★ **history 必须与 progress 走同一套**（否则同一作品两张表各说各话）
      //   ★ 这条是 2026-10-12 **补回**的：原判据靠"`else { t }` 出现 ≥2 次"
      //     间接确立"两张表都有集号判定"，改成按集后那个计数不再成立。
      //   ★ 现在改成**按段各断言一次**（而不是全函数计数）：
      //     CR 给的绕过形态是把 history 臂改成 `if true {` —— 全函数计数抓不住。
      expect(
          RegExp(r'^\s*if\s+ep_f\s*==\s*ep_t\s*\{', multiLine: true)
              .hasMatch(histSection),
          isTrue,
          reason: '★★★ history 的 `Some(t) =>` 臂内必须有 `if ep_f == ep_t` 集号判定'
              '—— 只给 progress 加而漏了 history ⇒ 同一部作品在两张表里各说各话'
              '（一张携带、一张不携带）⇒ 更难解释的 bug。'
              '★ 改成 `if true {` 会让这条立刻变红');
      expect(
          RegExp(r'episode_number_from_title\(').hasMatch(progSection),
          isTrue,
          reason: '★★★ progress 段必须**自己**解析集号（不许只靠 history 那一次撑计数）');
      // ④-d ★★ 反向：不许有「拿 FROM 的 position 却不过集号判定」的臂
      //   老形态是 `else { Progress { … position: f.position … } }`（错位携带）。
      //   新形态下这个坑同样可能被写出来 —— 只不过程序员不会用 `else`，
      //   而会在配对闭包（`position`）里写错。下面钉住「Progress 结构体字面量里
      //   出现的 `f.position` 必须与 `f.position.max(t.position)` 是同一条」
      //   （即：位置只在**配对成功**的臂里出现，且取的是 max）。
      final progArmForCarry = rustMatchArm(body, 'Progress');
      expect(
          RegExp(r'position:\s*f\.position\s*[,}]').hasMatch(progArmForCarry),
          isFalse,
          reason: '★★★ progress 的合并臂不许直接 `position: f.position` —— '
              'position 必须取 `f.position.max(t.position)`（单调不减）。'
              '★ 直接取 FROM 的会让"看了一半"的进度在换源后**倒退**；'
              '★ 而且这条同时守住了"只在配对成功的臂里才动 position" —— '
              '若有人把 position 提到 `position` 之外的公共路径上，这里会红');
      /*
       * ④-e ★★★ 每轮写完库必须**写回内存快照**（CodeRabbit on #23）
       *
       * ══════════════════════════════════════════════════════════════
       * 为什么必须有这条：④-a 的配对是**多对一**的
       * ══════════════════════════════════════════════════════════════
       *
       * 判据是**集号**，而集号会多对一 —— FROM 的 `第01集` 与 `第1集`
       * （字符串不同、集号都是 1）会**同时**配到 TO 的同一行：
       * ```text
       * 改前：`to_rows` 是循环**开始前**读的一次快照，每轮都在它上面找
       *   第一轮 f=800 ⇒ max(800, TO=100) = 800 写库 ✅
       *   第二轮 f= 50 ⇒ 仍拿**原始** TO=100 重算 max(50,100) = 100 ❌
       *   随后 FROM 的全部行被 DELETE ⇒ 用户 800 秒**永久丢失**
       * ```
       * ⇒ 修复 = 每轮把 `merged` 写回 `to_rows[i]`（`position` 单调不减
       *   在写回前**根本不成立**）。
       *
       * ★ 这条断言守的是「写回这一句存在」，而**行为**由 Rust 侧用例
       *   `store::tests::repoint_writeback_keeps_max_position_across_multiple_from_rows`
       *   钉住（改前它得到 100）。
       *   两处缺一不可：Dart 侧防「有人顺手删掉写回」，Rust 侧防「写回写错了」。
       */
      expect(body.contains('to_rows[i] = merged;'), isTrue,
          reason: '★★★ 写完库必须把合并结果写回 `to_rows` 快照 —— '
              'FROM 多行配到同一个 TO 行时（集号多对一），不写回就会用 TO 的'
              '**原始** position 重算 max，把第一轮写进去的大值覆盖成小的，'
              '而 FROM 行随后被 DELETE ⇒ 用户进度**永久丢失**。'
              '★ 行为回归锁在 Rust 侧：'
              '`repoint_writeback_keeps_max_position_across_multiple_from_rows`');
      // ⑤ ★ history 段必须存在
      expect(body.contains('HistoryEntry'), isTrue,
          reason: '★ history 段必须存在且同样做集号判定');
    });

    test('★★★ 其余字段按裁决：OR / max / min / TO（按表臂定位）', () {
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'pub fn repoint_item(');

      // ══════════════════════════════════════════════════════════════
      // ★★★ 本用例原先用 10 条正则对**整个** 21KB 函数体做 `hasMatch`。
      // Lead 用 `.probe\t67_rule_attribution3.py` 逐条量了命中的**归属**：
      //   · Progress.Some(t) 与 HistoryEntry.Some(t) 两臂合计只贡献 1 条命中
      //   · 9 条「通过」里 6 条的唯一命中来自 Favorite、2 条来自 SkipMarker
      //   · 两臂的「取 TO」字段**一个都没显式写出**（全走 `..t`）
      // ⇒ 那些正则证明的是「这 10 个串在函数里**出现过**」，
      //   不是「这 4 张表按裁决合并」。
      // ★ 真实后果：把 Progress 臂的 `..t` 改成 `..f`（= 取 FROM 的），
      //   那条断言**仍然全绿**（该臂内本来就没有正则会命中）
      //   ⇒ 该用例对 progress 段的合并语义**零分辨力**。
      // ⇒ 现在每条断言都**只在自己那张表的臂内**求值（`rustMatchArm`）。
      // ══════════════════════════════════════════════════════════════
      final favArm = rustMatchArm(body, 'Favorite');
      final progArm = rustMatchArm(body, 'Progress');
      final histArm = rustMatchArm(body, 'HistoryEntry');
      final skipArm = rustMatchArm(body, 'SkipMarker');

      // ★ 仪器自检：四臂都得切出来、且互不相同。
      //   若切片器坏了（切出空串 / 切出同一段），下面所有断言会**真空通过**。
      final arms = <String, String>{
        'Favorite': favArm,
        'Progress': progArm,
        'HistoryEntry': histArm,
        'SkipMarker': skipArm,
      };
      for (final e in arms.entries) {
        expect(e.value.length, greaterThan(200),
            reason: '★ 仪器自检：`${e.key}` 臂只切出 ${e.value.length} 字符 ⇒ '
                '切片器可能坏了，本用例会真空通过');
      }
      expect(arms.values.toSet().length, 4,
          reason: '★ 仪器自检：四臂切片必须互不相同');

      // ── ① favorites：OR / max / min / TO ──────────────────────────
      final favRules = <String, RegExp>{
        'favorited 取 OR': RegExp(r'favorited:\s*f\.favorited\s*\|\|\s*t\.favorited'),
        'following 取 OR': RegExp(r'following:\s*f\.following\s*\|\|\s*t\.following'),
        'unread_count 取 max': RegExp(r'unread_count:\s*f\.unread_count\.max\(t\.unread_count\)'),
        'created_at 取 min': RegExp(r'created_at:\s*f\.created_at\.min\(t\.created_at\)'),
        'updated_at 取 max': RegExp(r'updated_at:\s*f\.updated_at\.max\(t\.updated_at\)'),
        'title 取 TO': RegExp(r'title:\s*t\.title'),
        'cover 取 TO': RegExp(r'cover:\s*t\.cover'),
        'last_episode_count 取 TO': RegExp(r'last_episode_count:\s*t\.last_episode_count'),
      };
      for (final e in favRules.entries) {
        expect(e.value.hasMatch(favArm), isTrue,
            reason: '★★ favorites 臂内必须写「${e.key}」（Lead 逐条裁决）—— '
                '★ 断言已按臂定位：在别的表臂里命中不算数');
      }

      // ── ② progress / history：`..t` + 显式字段白名单 ─────────────
      //
      // 「其余列保持 TO 的」在源码里的**真实书写形式**是 `..t`，
      // 而不是把每个字段显式写成 `t.xxx` ⇒ 必须直接断言 `..t` 存在。
      expect(progArm.contains('..t'), isTrue,
          reason: '★★★ progress 的合并臂必须用 `..t`（= 其余列保持 TO 的）—— '
              '★ 若改成 `..f`，`episode_title`/`duration`/`episode_id`/`title` '
              '会全部变成 FROM 的，而**旧断言对此零分辨力**');
      expect(histArm.contains('..t'), isTrue,
          reason: '★★★ history 的合并臂必须用 `..t`（同上）');

      // ★ 白名单：臂内**显式写出**的字段必须**恰好**是这些。
      //   多写任何一个「取 FROM 的」字段都会被这里挡住 —— 这正是
      //   Lead 说的「防止以后悄悄多写一个取 FROM 的字段」。
      //   （实测四臂的字段集是量出来的，不是猜的：Progress 臂 941 字符、
      //    HistoryEntry 臂 928 字符，见 `.probe\t67_rule_attribution3.txt`。）
      //
      // ══════════════════════════════════════════════════════════════
      // ★★★ 2026-10-12 仪器 bug：字段提取器会把**类型标注**读成字段名
      // ══════════════════════════════════════════════════════════════
      //
      // 原判据是 `RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*:')`。
      // 按集扩容后 Progress 臂里出现了这一行：
      // ```rust
      // key: String::new(), // 落库时由 progress_key 重算
      // ```
      // ⇒ 正则把 `String` 也当成一个「字段名」抓了进来（`String` 后面正好跟着 `:`）
      // ⇒ 白名单比对失败，报 `Actual: {key, String, provider, …}`。
      //
      // ★ **不能靠"把 String 加进白名单"来修** —— 那是拿白名单掩盖仪器故障：
      //   提取器一旦会读进类型名，白名单就再也分不清
      //   「真的多了一个字段」和「又一个类型标注」，本用例**零分辨力**。
      // ⇒ 修的是**提取器本身**：只认「字段名后面**不是** `::`」的形态。
      //   `key: String::new()` 里 `String:` 后面紧跟的是 `:`（`::` 的第二半）
      //   ⇒ 用 `(?!:)` 排除掉；而真正的字段 `key:` 后面是 ` String::new()` ⇒ 保留。
      //
      // ★ 保留原有的仪器自检精神：下面额外断言提取结果里**不含任何 Rust 类型名**，
      //   若提取器将来又被写出漏洞，这条会直接点名，而不是让白名单静默变宽。
      final fieldOf = RegExp(r'([A-Za-z_][A-Za-z0-9_]*)\s*:(?!:)');
      Set<String> extractFields(String arm) =>
          fieldOf.allMatches(arm).map((m) => m.group(1)!).toSet();

      // ★ 仪器自检 ①：提取器不许把 Rust 类型名当字段（用真臂自证）
      const rustTypeNames = {
        'String', 'Option', 'Vec', 'HashMap', 'HashSet', 'i32', 'i64', 'u32',
        'u64', 'usize', 'bool', 'f64', 'Box', 'Some', 'None', 'Self',
      };
      for (final e in {'Progress': progArm, 'HistoryEntry': histArm}.entries) {
        final bad = extractFields(e.value).intersection(rustTypeNames);
        expect(bad, isEmpty,
            reason: '★ 仪器自检：`${e.key}` 臂的字段提取结果里出现了 Rust 类型名 '
                '$bad ⇒ **提取器坏了**（把类型标注读成了字段名）。'
                '★ 这时下面的白名单比对**不再可信** —— '
                '先把提取器修对（判据要排除 `::`），再跑本用例');
      }
      // ★ 仪器自检 ②：提取器在**人造样本**上的行为必须符合预期
      //   （正例：真字段抓得到；反例：类型标注抓不到）
      expect(extractFields('key: String::new(), provider: p, x: 1,'),
          {'key', 'provider', 'x'},
          reason: '★ 仪器自检：`key: String::new()` 只该贡献 `key`，'
              '`String:` 必须被排除（它后面紧跟 `::` 的第二半）');

      final whitelists = <String, (String, Set<String>, String)>{
        'Progress': (
          progArm,
          {'key', 'provider', 'native_id', 'position', 'finished'},
          'key/provider/native_id 是**身份**（必须换成 TO 的 key，'
              '这就是 repoint 的本体）；position 是唯一被裁决覆盖的**进度**列'
              '（取 max）；finished 取 FROM 的（Lead ④ 补充裁决，'
              '理由见 store.rs 的文档披露段）',
        ),
        'HistoryEntry': (
          histArm,
          {'key', 'provider', 'native_id', 'position', 'watched_at'},
          'key/provider/native_id 是身份；position 取 max；'
              'watched_at 取 max —— 比 progress 多这一列，因为 history 没有 finished',
        ),
      };
      for (final e in whitelists.entries) {
        final (arm, allow, why) = e.value;
        final fields = extractFields(arm);
        expect(fields, allow,
            reason: '★★★ `${e.key}` 合并臂**显式写出**的字段必须恰好是 $allow —— '
                '实际是 $fields。\n'
                '  · 白名单之外多出字段 ⇒ 可能有人把「取 FROM 的」悄悄写进来了；\n'
                '  · 少字段 ⇒ 可能被搬进 `..f`（会丢裁决）或 `..t` 了。\n'
                '  $why');
      }

      // ── ③ skip_markers：title 取 TO + updated_at 取 max ──────────
      expect(RegExp(r'title:\s*t\.title').hasMatch(skipArm), isTrue,
          reason: '★★ skip_markers 的 title 取 TO 的');
      expect(
        RegExp(r'updated_at:\s*f\.updated_at\.max\(t\.updated_at\)')
            .hasMatch(skipArm),
        isTrue,
        reason: '★★ skip_markers 的 updated_at 取 max',
      );

      // ── ④ 全局负向：`episode_title` **从不**取 FROM 的 ────────────
      //
      // ★ 注意这条断言的方向：它检查的是「**不许有** FROM 写法」，
      //   而**不是**「必须有 TO 写法」。`episode_title` 的「取 TO」是靠
      //   Progress/HistoryEntry 臂的 `..t` 实现的（臂内根本没有这个字面形式），
      //   所以**不能**用 `episode_title:\s*t\.` 做正向断言 ——
      //   那正是本用例原先假绿的根因。
      expect(RegExp(r'episode_title:\s*f\.').hasMatch(body), isFalse,
          reason: '★★★ `episode_title` 在**任何**一张表里都不许取 FROM 的 —— '
              '集名跟着行所属的源走（新源的行说自己是第几集）');
    });

    test('★★★ skip_markers 四个端点：FROM 非 null 优先，缺的用 TO 补', () {
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'pub fn repoint_item(');

      for (final f in const [
        'intro_start',
        'intro_end',
        'outro_start',
        'outro_end',
      ]) {
        expect(
          RegExp('$f:\\s*f\\.$f\\.or\\(t\\.$f\\)').hasMatch(body),
          isTrue,
          reason: '★★★ `$f` 必须是 `f.$f.or(t.$f)` —— '
              'FROM 的非 null 优先，缺的用 TO 补（Lead 裁决）',
        );
      }
    });

    test('★★ 合并不许留墓碑（否则备份导出会数成两条）', () {
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'pub fn repoint_item(');

      expect(
        RegExp(r'deleted:\s*f\.deleted\s*&&\s*t\.deleted').hasMatch(body),
        isTrue,
        reason: '★★ 合并后的行必须"活着" —— '
            '若写成 `||` 或直接取 FROM 的，用户会看到收藏凭空消失',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⑤ 边界：《老舅》真实例子必须有测试盯着
  // ═══════════════════════════════════════════════════════════════════

  group('⑤ ★★★ 《老舅》真实例子（TO 行已存在）必须有测试盯着', () {
    test('★★★ Rust 单测里有 TO 已存在的合并用例', () {
      final code = File('rust/sourin_core/src/store.rs').readAsStringSync();
      expect(code.contains('fn repoint_merges_when_target_row_already_exists_laojiu_case'),
          isTrue,
          reason: '★★★ 必须有一条**专测"TO 行已存在"**的用例 —— '
              '这是用户库里真实发生过的形态（360:86969 与 caiji:74774 并存）');
      // ★ 自证：用例里必须真的写入 TO 行（否则"已存在"这个前提不成立）
      //   ★ 用 rustFnBody 按大括号配平精确切（原来是 `i + 3000` 魔数）
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'fn repoint_merges_when_target_row_already_exists_laojiu_case');
      expect(body.contains('caiji:74774'), isTrue,
          reason: '★ 用例必须用真实的 key');
      expect(body.contains('360:86969'), isTrue,
          reason: '★ 用例必须用真实的 key');
      expect(body.contains('db.repoint_item("360:86969", "caiji:74774")'), isTrue,
          reason: '★ 必须真的调用迁移');
    });

    test('★★★ Rust 单测覆盖：四表搬迁 / 幂等 / 无墓碑 / 冒号 key', () {
      final code = File('rust/sourin_core/src/store.rs').readAsStringSync();
      for (final f in const [
        'repoint_moves_all_four_tables_and_deletes_old_rows',
        'repoint_merges_when_target_row_already_exists_laojiu_case',
        'repoint_skip_markers_prefers_from_and_fills_from_to',
        'repoint_is_idempotent_and_noop_when_source_missing',
        'repoint_leaves_no_tombstone_in_favorites',
        'split_item_key_handles_colons_inside_native_id',
        // ★ m00753 ② 点名要求：双前缀坏行必须单独有用例
        'split_item_key_keeps_double_prefixed_native_id_intact',
        // ★ m00753 ③：position 取 max 的**唯一可区分锚点**（无职转生那组）
        'repoint_position_takes_max_when_to_is_larger_mushoku_case',
        // ★ m00753 ④⑤：三态匹配
        //   ⚠️ 2026-10-12 按集扩容：本名单从「缺陷刻画」口径改成了「按集保住」口径
        //      —— `does_not_carry`（不携带）在按集后语义变成
        //      `keeps_both_episodes`（两集各自留着）。名字改了**行为没变**，
        //      但名单必须跟实测的 fn 名对齐，否则这条断言变成在检一个不存在的名字。
        'repoint_keeps_both_episodes_when_episode_numbers_differ',
        'repoint_keeps_separate_when_only_one_side_has_episode_number',
        'repoint_carries_when_both_sides_have_no_episode_number',
        'repoint_carries_whole_row_when_target_has_no_row',
        // ★ 按集扩容新增：配对成功/失败的**保留 TO 集名**两个方向
        'repoint_matched_arm_keeps_target_episode_title',
        'repoint_matched_arm_keeps_target_episode_title_in_history',
        // ★ m00753 ⑥：两份实现被**同一张夹具**钉住
        'episode_number_fixture_matches_dart',
      ]) {
        expect(code.contains('fn $f('), isTrue,
            reason: '★★ Rust 单测 `$f` 必须存在（cargo test --release --lib 里跑）');
      }
    });

    test('★★★ 两份集号实现被**同一张夹具**钉住（m00753 ⑥）', () {
      /*
       * ⚠️ 为什么必须有这条：Dart `RegExp` 是 **ECMAScript** 语义，
       *    Rust `regex` 默认是 **Unicode** 语义 ⇒ 两份实现**天然不等价**。
       *    实测分歧（见夹具里的注记）：
       *      `第\u00851集`  Dart null / Rust `\s` 认 U+0085 ⇒ 1
       *      `第\ufeff1集`  Dart **1** / Rust `\s` 不认 U+FEFF ⇒ null
       *      `第٣集`       Dart null / Rust `\d`=`\p{Nd}` 认阿拉伯-印度数字 ⇒ 3
       *    ⇒ 靠"两份都写对"是**指望**，靠同一张夹具才是**保证**。
       */
      const fixture = 'test/fixtures/episode_number_cases.json';
      expect(File(fixture).existsSync(), isTrue,
          reason: '★★★ 共享夹具必须存在（$fixture）—— '
              '它是"两份实现不会悄悄漂移"的**唯一**保证');
      final raw = File(fixture).readAsStringSync();
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final cases = decoded['cases'] as List;
      expect(cases.length, greaterThanOrEqualTo(20),
          reason: '★★ 夹具必须有足够多的用例（当前 ${cases.length} 条）'
              '—— 太少就钉不住边界（全角/空白类/firstMatch/溢出）');

      // ★★★ 正向对照：Rust 侧必须**真的读这张夹具**（不是另写一张）
      final rust = File('rust/sourin_core/src/store.rs').readAsStringSync();
      expect(rust.contains('episode_number_fixture_matches_dart'), isTrue,
          reason: '★★★ Rust 必须有读同一张夹具的用例');
      expect(rust.contains('test/fixtures/episode_number_cases.json'), isTrue,
          reason: '★★★ Rust 侧读的必须是**这张**夹具的路径 —— '
              '★ 注意 `cargo test` 的 cwd 是**包根** `rust/sourin_core/`，'
              '所以路径是 `../../test/fixtures/...`（两个 `..`）；'
              '写一个 `..` 会落到 `rust/`，那里没有 `test/`');

      // ★★ 关键边界必须在夹具里（缺一条就少一个钉子）
      final inputs = cases
          .map((c) => (c as Map<String, dynamic>)['input'])
          .whereType<String>()
          .toSet();
      for (final must in const [
        '第01集', // 前导零 —— 无职转生 TO 侧的真实值
        '第1集', // 无职转生 FROM 侧的真实值
        '第 1 集', // 空白
        '第01話', // 繁体「話」
        '第１集', // 全角数字
        '正片', // 解析不出 —— 老舅/鬼灭的真实值
        '第\ufeff1集', // ★ BOM：Dart 认 / Rust 默认 \s 不认
        '第\u00851集', // ★ NEL：Dart 不认 / Rust 默认 \s 认
        '第٣集', // ★ 阿拉伯-印度数字：Dart \d 不认 / Rust \d 认
      ]) {
        expect(inputs.contains(must), isTrue,
            reason: '★★★ 夹具里必须有边界样本 ${jsonEncode(must)} —— '
                '它对应一处**实测过的** Dart/Rust 分歧');
      }
    });

    test('★★★ native_id 自带冒号时不许截断（实测用户库真有）', () {
      final body = rustFnBody('rust/sourin_core/src/store.rs',
          'fn split_item_key(');

      expect(body.contains('split_once'), isTrue,
          reason: '★★★ 必须用 `split_once(\':\')` 按**第一个**冒号切 —— '
              '实测用户库有 `bilibili:av:BV1Bfex6tEEH`（native_id 自带 "av:"），'
              '用 `split(\':\')` 取第二段会把 native_id 截断成 "av"（静默写错）');
      // ★ m00753 ②：双前缀坏行 —— 生产库里**真实存在**的那一条
      expect(body.contains('split_once'), isTrue,
          reason: '★★★ 实测用户库里有 `bilibili:bilibili:av:BV1B8ZJYTEPg` '
              '（provider 被写了两次）—— 按第一个冒号切才能保住 '
              'native_id=\'bilibili:av:BV1B8ZJYTEPg\'；'
              '用 `split(\':\')` 会截成 \'bilibili\' ⇒ **迁到错误作品**');
    });
  });
}
