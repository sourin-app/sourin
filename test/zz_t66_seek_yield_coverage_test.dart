// ═══════════════════════════════════════════════════════════════════════
//  task-66【N10】seek 让路窗口的**覆盖完整性**门禁（白名单式强制决策）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这份文件解决什么问题（上一版门禁的真实缺陷）
// ```text
// 上一版门禁只钉了一处：
//   _player\.seek\(d\);[\s\S]{0,80}?_beginPrefetchYield\(\);
//
// ★ 三个问题：
//   ① 只认**底栏滑杆**那一条路径（变量名叫 d 的那个）
//   ② 生产代码里其实有 **10 处** `_player.seek(`，
//      快进键 / 点进度条 / 遥控跳转 / 续播恢复 / 跳过片头 …**全部没挂**
//   ③ 绑死变量名 `d` ⇒ 别人写 `seek(target)` 它看不见
//
// ⇒ 结果是门禁"全绿"，而**用户按快进键照样转圈**。
//   这是「看起来守住了、实际漏了 90%」的典型假绿。
// ```
//
// # 现在改成「白名单式强制决策」
// ```text
// 不强制每一处都挂 yield（有些确实不该挂），
// 但**强制每一处明确表态**：
//
//   扫描所有 `_player.seek(` 调用（剥掉注释行）
//   对每一处，在它**所在的方法体内**必须能找到以下之一：
//     a) `_beginPrefetchYield()`          ⇒ 挂上了
//     b) `// seek-yield: skip —— <理由>`   ⇒ 明确不挂，且写了理由
//     c) 出现在 EXPLICIT_SKIP 清单里       ⇒ 非生产路径（探针/测试）
//
// ⇒ 新增一个 seek 而没表态 ⇒ 本门禁**红**
// ⇒ 想漏掉就必须主动写下一行"我不挂，因为…"，而不是悄悄漏
// ```
//
// # 为什么这个形态比"必须全挂"更好
// ```text
// · 有些 seek 挂了反而有害（例如 `seek(Duration.zero)` 是循环重播，
//   挂上会让每次循环都打断预取）
// · 硬性全挂会逼人写假实现（为了过门禁而挂，不看场景）
// ⇒ 强制"表态"而不是强制"挂上"，才是可持续的
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥离 Dart 行注释与块注释，只留代码
///
/// ⚠️ 为什么必须剥：门禁自身经常被注释里的示例文字误命中
/// （上一版就发生过：dispose 上方注释里写着方法名 ⇒ 断言命中的是注释）
String _stripComments(String src) {
  // 块注释整体去掉
  final out = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '');
  final lines = out.split('\n');
  final kept = <String>[];
  for (final line in lines) {
    // 只跳过**行首**注释（`// ...`）——
    // 行尾注释必须保留，因为 `// seek-yield: skip` 标记本身就是行尾注释
    if (line.trimLeft().startsWith('//')) continue;
    kept.add(line);
  }
  return kept.join('\n');
}

/// 非生产路径的 seek：这些**不需要**表态标记
///
/// 每一条都要写清为什么，否则后人不敢删也不敢确认。
final _nonProductionSites = <String, String>{
  // 探针注入点（`_skipSeekCalls` 的埋点，见文件末尾的探针扩展）
  's._player.seek(target)': '探针注入点（_skipSeekCalls 只读探针），非生产路径',
};

void main() {
  late String pageRaw;
  late String pageCode;

  setUpAll(() {
    final f = File('lib/ui/player_page.dart');
    expect(f.existsSync(), isTrue, reason: '找不到 player_page.dart');
    pageRaw = f.readAsStringSync();
    pageCode = _stripComments(pageRaw);
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 每一个生产路径的 seek 都必须"表态"
  // ═══════════════════════════════════════════════════════════════════
  test('① 每个 _player.seek( 都必须挂 yield 或显式声明 skip', () {
    /*
     * ★★ 做法修正（第一版写错了两次）
     *
     * 第一版：先 `_stripComments()` 再找 seek。
     *   ⇒ 剥注释时用空串替换块注释，破坏了行号对齐，
     *     导致大量**正常代码行**被误判成"未表态"（:3741 `final pct = …`）。
     *
     * 第二版（本版）：**直接在原始源码上**找 seek，
     *   再用「该行是否处于块注释内」这个状态机判断它是不是注释里的字串。
     *   ⇒ 行号天然对齐，且块注释判断是精确的。
     */
    final rawLines = pageRaw.split('\n');

    // 状态机：逐行跟踪"是否在块注释内"
    final inBlockComment = <bool>[];
    var inBlock = false;
    for (final line in rawLines) {
      final t = line.trimLeft();
      if (!inBlock) {
        final start = t.indexOf('/*');
        if (start >= 0) {
          final closeSameLine = t.indexOf('*/', start + 2) >= 0;
          inBlockComment.add(false); // 该行本身是注释起始行 ⇒ 不算代码
          if (!closeSameLine) inBlock = true;
          continue;
        }
        inBlockComment.add(false);
      } else {
        inBlockComment.add(true);
        if (t.contains('*/')) inBlock = false;
      }
    }

    final sites = <int>[];
    for (var i = 0; i < rawLines.length; i++) {
      final l = rawLines[i];
      if (!l.contains('_player.seek(')) continue;
      // ① 在块注释里 ⇒ 跳过
      if (i < inBlockComment.length && inBlockComment[i]) continue;
      // ② 行首是行注释 ⇒ 跳过
      final t = l.trimLeft();
      if (t.startsWith('//') || t.startsWith('*')) continue;
      sites.add(i);
    }

    expect(
      sites, isNotEmpty,
      reason: '一处 _player.seek( 都没找到 —— 说明扫描逻辑写错了',
    );

    final violations = <String>[];

    for (final lineNo in sites) {
      final rawLine = rawLines[lineNo];

      // 排除非生产路径
      final isNonProd = _nonProductionSites.keys.any(
        (sig) => rawLine.replaceAll(' ', '').contains(sig.replaceAll(' ', '')),
      );
      if (isNonProd) continue;

      /*
       * 找它所在的方法体范围。
       *
       * 做法：从该行向上找最近的「方法定义行」
       * （形如 `  void xxx(` / `  Future<void> xxx(` / `  bool xxx(`），
       * 向下找下一个方法定义行（或到文件末尾）。
       *
       * ⚠️ 这是启发式，不是 Dart 语法分析 —— 但本仓库的方法都是扁平的
       *    `  return_type name(...)` 形式，够用。若将来出现内联闭包套方法，
       *    这个门禁会偏保守（范围取大）⇒ 只可能漏报，不会误报。
       */
      var start = lineNo;
      final methodRe = RegExp(
        r'^  (?:@\w+\s+)?(?:static\s+)?(?:Future<[^>]*>|void|bool|int|String|double|Duration|Widget)\s+\w+\s*\(',
      );
      for (var i = lineNo; i >= 0; i--) {
        if (methodRe.hasMatch(rawLines[i])) {
          start = i;
          break;
        }
      }
      var end = rawLines.length - 1;
      for (var i = lineNo + 1; i < rawLines.length; i++) {
        if (methodRe.hasMatch(rawLines[i])) {
          end = i - 1;
          break;
        }
      }

      final body = rawLines.sublist(start, end + 1).join('\n');

      final hasYield = body.contains('_beginPrefetchYield()');
      final hasSkipMark = RegExp(
        r'//\s*seek-yield:\s*skip\s*[—–-]+\s*\S+',
      ).hasMatch(body);

      if (!hasYield && !hasSkipMark) {
        violations.add(
          '  :${lineNo + 1}  ${rawLine.trim()}\n'
          '      ⇒ 所在方法（从 :${start + 1} 起）既没有 _beginPrefetchYield()，'
          '也没有 `// seek-yield: skip —— 理由` 标记',
        );
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          '★ 有 seek 调用点**没有表态**。\n'
          '　每处必须满足其一：\n'
          '　a) 调用 _beginPrefetchYield()（挂上让路）\n'
          '　b) 写一行 `// seek-yield: skip —— <理由>`（明确不挂）\n'
          '　\n'
          '　为什么强制表态：漏挂一处 ⇒ 那条路径上用户照样看到转圈，\n'
          '　而门禁却是绿的（上一版就是这样只覆盖了 1/10）。\n'
          '\n未表态的调用点：\n${violations.join('\n')}',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 覆盖率下限：至少要有 N 处真的挂上
  // ═══════════════════════════════════════════════════════════════════
  test('② 真挂上 yield 的位置不得少于 6 处（防有人全标 skip）', () {
    /*
     * ★ 为什么需要这条：
     *   ① 只要求"表态"，那有人可以给每一处都写 skip ⇒ 门禁绿，功能废。
     *   ② 本条的判据来自实测的用户路径清点：
     *      · 底栏滑杆          （Owner 报的"拖动"）
     *      · _seekBy 快进/快退  （键盘 ←/→、按钮）
     *      · _seekToPercent     （点进度条跳 N%）
     *      · 续播恢复           （起播跳到上次位置）
     *      · 跳过片头           （跳到片头结束，可能几分钟后）
     *      · 遥控 seek_to       （手机发起）
     *      · 遥控 seek_preview  （手机微调，电视出画面）
     *      · 「继续观看」浮层
     *      ⇒ 其中至少 6 处应挂上。低于 6 说明有人批量标了 skip。
     */
    final code = _stripComments(pageRaw);
    final count = RegExp(r'_beginPrefetchYield\(\)').allMatches(code).length;
    // 减去定义处那一处（`void _beginPrefetchYield()` 也是这个字符串）
    final callSites = count - 1;

    expect(
      callSites >= 6,
      isTrue,
      reason: '★ 真挂上 yield 的调用点只有 $callSites 处（要求 ≥6）。\n'
          '　已知用户路径至少有 8 处会产生"跳到中间位置"的行为：\n'
          '　底栏滑杆 / 快进快退 / 点进度条 / 续播恢复 / 跳片头 /\n'
          '　遥控 seek_to / 遥控 seek_preview / 继续观看浮层\n'
          '　⇒ 若大面积标成 skip，请说明为什么那些路径不需要让路。',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ skip 标记必须带理由（不许只写 skip）
  // ═══════════════════════════════════════════════════════════════════
  test('③ 每个 seek-yield: skip 都必须带非空理由', () {
    final bareSkip = RegExp(r'//\s*seek-yield:\s*skip\s*(?:\r?\n|$)');
    expect(
      bareSkip.hasMatch(pageRaw),
      isFalse,
      reason: '★ 有 `seek-yield: skip` 没写理由。\n'
          '　理由必须落在同一行（`// seek-yield: skip —— <理由>`），\n'
          '　否则后人无法判断该不该删。',
    );
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 原有 7 条契约仍须成立（防止本次改造把老保障弄丢）
  // ═══════════════════════════════════════════════════════════════════
  test('④ 让路窗口的恢复契约仍然成立', () {
    /*
     * 本文件是 `zz_t66_prefetch_yield_test.dart` 的**补充**，不替代它。
     * 但为防止有人删掉那边、或把三处关键调用改坏，这里再钉一次核心语义。
     */
    expect(
      pageCode.contains('_prefetchYieldTimer = Timer('),
      isTrue,
      reason: '定时器必须存在（否则窗口永不结束）',
    );
    expect(
      RegExp(r'if\s*\(!first\)\s*return;').hasMatch(pageCode),
      isTrue,
      reason: '必须用 first 判据避免连续 seek 叠定时器',
    );
    final endCalls = RegExp(
      // ★ 2026-10-19（Lead 修，批末全量跑抓出）：原正则要求
      //   `unawaited(...endYieldForSeek()\s*)` —— 即 `()` 之后**立刻**闭括号。
      //   本轮给 dispose 那处加了 `.catchError(...)`（修「异常从 dispose 逃逸」
      //   那个真回归）⇒ 正则失配 ⇒ 只数到定时器那 1 处 ⇒ 这条变红。
      //
      // ⇒ 放宽尾部，允许链式调用（`.catchError` / `.then` / …）。
      //   `unawaited(` 与 `SourinApi.` 两个锚点保留 ⇒ 注释里的假调用骗不过
      //   （这条门禁第二版就是恒绿，被"注释里提一句"骗过，教训在先）。
      r'unawaited\(\s*SourinApi\.endYieldForSeek\(\)[^;]*?\)',
    ).allMatches(pageCode).length;
    expect(
      endCalls >= 2,
      isTrue,
      reason: '至少 2 处恢复（定时器到点 + dispose 补一次），实际 $endCalls 处',
    );
  });
}
