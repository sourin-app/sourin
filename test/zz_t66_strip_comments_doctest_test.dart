// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · `stripComments` 的 `///` 与 **raw string** 自检
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这个文件（Lead 指派 ②）
// ```text
// `test/_support/strip_comments.dart` 是**共享 helper**，被 16 个文件的静态断言共用。
// 它一旦行为漂移，那 16 个文件的判据**同时变形**，且多半是**静默**的。
// ⇒ 这里给它钉一组自检，使将来有人改回去时有症状。
// ```
//
// # ★★★ 本轮最重要的发现：**Lead 给的归因是错的，真因在别处**
// ```text
// 原假设：「stripComments 不认 `///`，把它当 `//` + 游离 `/`
//          ⇒ `/// …**我们**…` 那行剥完仍在 ⇒ 被当成代码」
//
// 实测（改前）：
//   stripComments('/// 而我们要回答的是"**我们**有没有泄漏"。')
//     ⇒ 返回 **空串**（长度 0）
//     ⇒ 含 ** = false
//   ⇒ `///` 行**本来就被完全剥掉**。**它不是那条假阳性的成因。**
//
// ★ 真因（实测定位）：**raw string 以反斜杠结尾**。
// ```dart
//   lib/ui/cache_page.dart:1097
//     p = p.replaceAll(r'\', '/');        ← 合法 Dart：原始字符串内容就是一个反斜杠
// ```
//   旧状态机：进入单引号模式 ⇒ 遇到 `\` 判定为"转义" ⇒ 把**那个收尾单引号**
//   当成被转义的内容写出 ⇒ `quote` 永远不归零 ⇒ **该行之后整个文件都被当作
//   字符串原样保留** ⇒ 后面的 `//` / `/* */` 全都不再被剥。
//
//   实测影响面（改前）：**4 个文件、374 行**仍是注释形态
//     lib/ui/cache_page.dart / delivery_test.dart / main.dart / t98_codec_probe.dart
// ```
//
// ⚠️ 判据纪律：每条都要能回答「**这个缺陷存在时，它凭什么会红**」。

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';

void main() {
  final bs = String.fromCharCode(92);
  final sq = String.fromCharCode(39);
  final dq = String.fromCharCode(34);

  // ══════════════════════════════════════════════════════════════════
  // ① `///` 文档注释：**本来就被剥干净**（推翻原假设的判据）
  // ══════════════════════════════════════════════════════════════════
  group('① /// 文档注释', () {
    test('★★★ `/// …**词**…` ⇒ 剥后不含 `**`（Lead 报的那一行逐字）', () {
      const line = '/// 而我们要回答的是"**我们**有没有泄漏"。';
      final out = stripComments(line);
      expect(out, isEmpty,
          reason: '★★★ 这条是**原假设**的直接反证：'
              '若它红（含内容残留），原假设成立；'
              '实测剥后 = "$out"（空）⇒ 原假设不成立。');
    });

    test('★★ `///` 行里的引号**不会**把状态机带偏', () {
      const src = '/// 他说"不可能"这件事\n/// 而我们要回答的是"**我们**有没有泄漏"。\nfinal x = 1;';
      expect(stripComments(src), isNot(contains('**')),
          reason: '★★ 文档注释里出现**成对**引号，仍必须被整行剥掉');
    });

    test('★★ 文档块注释 `/** … **/ **', () {
      const src = '/** 文档块 **词** */\nfinal x = 1;';
      expect(stripComments(src), isNot(contains('**')));
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ② ★★ 真因：raw string 以反斜杠结尾
  // ══════════════════════════════════════════════════════════════════
  group('② raw string 终止符（真正的缺陷）', () {
    test('★★★ raw string 以反斜杠结尾之后，注释**必须**继续被剥', () {
      // ★ 逐字构造 `r'\'`（r + 引号 + 反斜杠 + 引号），避免源码里再写一遍这个转义。
      //   ⚠️ 我第一版写成 `r + ' + 反斜杠 + ' + '`（**多了一个引号**）⇒
      //   那是 `r'\'` 后面又跟一个引号，等于另一个字符串开始 ⇒ 测的根本不是同一件事。
      final realLine = "  p = p.replaceAll(r" + sq + bs + sq + ", '/');";
      final src = realLine + '\n'
          '  // 这行注释本该被剥掉 **词**\n'
          '  final x = 1;\n';
      final out = stripComments(src);

      expect(out, isNot(contains('**')),
          reason: '★★★ ★本组是真正的判据★\n'
              '旧实现：r 后接 `\\` 被当成"转义"，把收尾引号吃掉 ⇒ quote 永不归零 '
              '⇒ 后面整段原样保留 ⇒ 这行注释存活。\n'
              '实测 OUT = ${out.replaceAll('\n', '|')}');
    });

    test('★★ 整个文件从那一行起都必须恢复正常（不止下一行）', () {
      final realLine = "  p = p.replaceAll(r" + sq + bs + sq + ", '/');";
      final src = realLine + '\n'
          '  final a = 1; // 注释一 **词一**\n'
          '  /* 块 **词二** */\n'
          '  final b = 2; // 注释三 **词三**\n';
      final out = stripComments(src);
      for (final w in ['**词一**', '**词二**', '**词三**']) {
        expect(out, isNot(contains(w)),
            reason: '★★ 旧实现下**整段**都存活；修后每一个都该被剥掉。'
                '实测 OUT = ${out.replaceAll('\n', '|')}');
      }
    });

    test('★★ `r"…"` 双引号形态同样成立', () {
      final realLine = '  final s = r' + dq + bs + dq + ';';
      final src = realLine + '\n'
          '  // 注释 **词**\n';
      expect(stripComments(src), isNot(contains('**')),
          reason: '★★ 双引号 raw string 同样是"引号即终止"');
    });

    test('★★ 对照：普通（转义）字符串**仍要**按转义处理（别把功能改坏）', () {
      // 'a\' 里的引号是**被转义**的 ⇒ 不该结束字符串
      final src = "  final s = 'a" + bs + sq + "b';\n"
          '  // 注释 **词**\n';
      expect(stripComments(src), isNot(contains('**')),
          reason: '★★ 对照组：证明修法没有把"转义"一起干掉');
      expect(stripComments(src), contains(bs + sq),
          reason: '★★ 转义后的引号必须原样保留（它在字符串内部）');
    });

    test('★★ `r` 出现在标识符里时**不得**被当成 raw 前缀', () {
      // `var'…'`：那个 r 是 var 的尾巴 ⇒ 普通字符串
      final src = "  final v = var'" + sq + 'x' + bs + sq + "y';\n"
          '  // 注释 **词**\n';
      expect(stripComments(src), isNot(contains('**')),
          reason: '★★ var 后面接引号是**普通字符串**；'
              '只有独立的 r 引号才是 raw 前缀');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ③ 回归护栏：本文件**原有的**三条能力不能退化
  // ══════════════════════════════════════════════════════════════════
  group('③ 原有能力不许退化', () {
    test('★★ 字符串里的 `//` 不是注释', () {
      const src = "final u = 'http://x/y';\n// 真注释 **词**\nfinal v = 1;";
      final out = stripComments(src);
      expect(out, contains('http://x/y'), reason: 'URL 必须原样保留');
      expect(out, isNot(contains('**')), reason: '真注释必须被剥');
    });

    test('★★ 字符串里的 `/*` 不是块注释', () {
      const src = 'final s = "a /* b";\n/* 真块注释 **词** */\nfinal x = 1;';
      final out = stripComments(src);
      expect(out, contains('a /* b'), reason: '字符串内容必须原样保留');
      expect(out, isNot(contains('**')));
    });

    test('★★ 块注释里的 `//` 不是行注释', () {
      const src = '/* 内含 // 与 **词** */\nfinal x = 1;';
      expect(stripComments(src), isNot(contains('**')));
    });

    test('★★ 行号必须保持一致（剥注释不改变行数）', () {
      const src = 'final a = 1;\n// c1\n// c2\n/* b1\n b2 */\nfinal b = 2;';
      expect(
        stripComments(src).split('\n').length,
        src.split('\n').length,
        reason: '★★ 静态断言按行号报错 ⇒ 剥注释必须保留换行',
      );
    });

    test('★★ 多行 raw string（真实形态）', () {
      final src = "  final p = r" + sq + bs + sq + ";\n"
          '  // 注释 **词**\n';
      expect(stripComments(src), isNot(contains('**')));
    });
  });
}
