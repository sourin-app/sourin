// ═══════════════════════════════════════════════════════════════════════
//  T64 · 源码切片门禁：不许把「会变的东西」写死进 indexOf
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁是怎么来的（真实事故，不是假想）
// ```text
// test/theme_tokens_test.dart 的切片函数写死了：
//   indexOf('class _BottomBar extends StatelessWidget')
//
// 而 task-36 把 _BottomBar 改成 StatefulWidget（要支持拖动跟随）；
// ⇒ indexOf 返回 -1 ⇒ 切片取不到 ⇒ **4 条红**。
//
// ★ 注意：产品代码**没有错**。错的是**测试的定位方式** ——
//   它依赖了「基类是什么」这个**与它要测的东西无关**的细节。
// ```
//
// # 为什么「基类是无关细节」
// ```text
// 那个测试要断言的是「药丸渐变是主题色分支」，
// 它根本不关心 _BottomBar 是 Stateless 还是 Stateful。
// 但写死基类后，一次纯粹的**内部重构**就会让它红 ——
// 而红的理由与它要证明的事**毫无关系**。
// ⇒ 这类红最坏：看起来像改坏了，其实只是定位方式太脆。
//    人会花时间去查一个不存在的回归。
// ```
//
// # 本门禁查什么（**只查这一类**，不扩大）
// ```text
//   indexOf('class Xxx extends <具体基类>')   ← 写死基类
//   indexOf('class Xxx with <Mixin>')         ← 写死 mixin
//   indexOf('class Xxx implements <接口>')    ← 写死接口
//   indexOf('class Xxx {')                    ← 写死「紧跟大括号」
// ```
//
// # 不查什么（避免误伤）
// ```text
//   indexOf('class Xxx')      ← ✅ 正确写法：只匹配类名
//   其它 indexOf（'@override' / 方法名 / 普通字符串）
// ```

// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 递归收集 test/ 下所有 .dart 文件
List<File> _testFiles() {
  final out = <File>[];
  for (final e in Directory('test').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    out.add(e);
  }
  return out;
}

/// 剥掉注释 —— **注释里的反例写法不是代码**
///
/// ⚠️ 本文件自身的头部注释里就写满了反例；不剥注释它会把**自己**报出来。
String _stripComments(String s) {
  return s
      .replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '')
      .replaceAll(RegExp(r'//[^\n]*'), '');
}

class _Hit {
  _Hit(this.file, this.line, this.snippet, this.why);
  final String file;
  final int line;
  final String snippet;
  final String why;

  @override
  String toString() => '$file:$line  $why\n        $snippet';
}

/// 在源码里找「indexOf 定位 class 且写死了会变的东西」
///
/// ⚠️ 用**括号配平**取 indexOf 的实参 —— 不能用简单正则：
///    实参可能是 `indexOf('x', start)`，正则会把 `, start` 也算进去。
List<_Hit> _scan(String rel, String raw) {
  final hits = <_Hit>[];
  final src = _stripComments(raw);

  final re = RegExp(r'\.(?:last)?indexOf\s*\(');
  for (final m in re.allMatches(src)) {
    final open = m.end - 1;
    var depth = 0;
    var close = -1;
    for (var i = open; i < src.length; i++) {
      if (src[i] == '(') depth++;
      if (src[i] == ')') {
        depth--;
        if (depth == 0) {
          close = i;
          break;
        }
      }
    }
    if (close < 0) continue;
    final args = src.substring(open + 1, close);

    /*
     * ★ 取实参里**第一个字符串字面量**
     *
     * ⚠️ 不能用 `RegExp(r'''(['"])(.*?)\1''')` —— 在 **raw string** 里
     *    `\1` 是「反斜杠 + 1」两个字符，不是反向引用 ⇒ 永远匹配不上。
     *    我第一版就是这么写的，结果只报出 1 处（其余全被静默漏掉）。
     *    ⇒ 改用普通字符串，让 `\1` 真正成为反向引用。
     */
    final lit = RegExp('([\'\"])(.*?)\\1', dotAll: true).firstMatch(args);
    if (lit == null) continue;
    final text = lit.group(2) ?? '';
    if (!text.contains('class ')) continue;

    String? why;
    if (RegExp(r'\bclass\s+\w+\s+extends\b').hasMatch(text)) {
      why = '写死了基类 extends —— 基类一改(Stateless→Stateful)就 -1';
    } else if (RegExp(r'\bclass\s+\w+\s+with\b').hasMatch(text)) {
      why = '写死了 with 子句 —— mixin 组合一变就 -1';
    } else if (RegExp(r'\bclass\s+\w+\s+implements\b').hasMatch(text)) {
      why = '写死了 implements 子句 —— 接口一变就 -1';
    } else if (RegExp(r'\bclass\s+\w+\s*\{').hasMatch(text)) {
      why = '写死了类名后紧跟大括号 —— 加 extends/换行就 -1';
    }
    if (why == null) continue;

    final line = raw.substring(0, m.start.clamp(0, raw.length)).split('\n').length;
    hits.add(_Hit(rel, line, 'indexOf 实参 = $text', why));
  }
  return hits;
}

void main() {
  group('T64 · 源码切片不许写死会变的基类', () {
    test('★★★ test/ 下没有「indexOf 写死 class extends <基类>」', () {
      final hits = <_Hit>[];
      for (final f in _testFiles()) {
        final rel = f.path.replaceAll(r'\', '/');
        /*
         * ⚠️ 跳过**本文件自己** —— 它的阳性对照里**故意**写了坏样本。
         *
         * 不跳过的话，门禁会把自己的考题当成违规报出来，
         * 于是「红」永远消不掉 ⇒ 这条门禁变成不可用的噪声（实测踩到）。
         *
         * ★ 注意这不是「放宽」：坏样本是**字符串常量**喂给 `_scan()` 的，
         *   不是真的去 indexOf 某个产品源码；跳过本文件不影响真实覆盖。
         *   下面第 2 条测试就是专门证明扫描器对坏样本**仍然灵敏**。
         */
        if (rel.endsWith('zz_t64_source_slice_gate_test.dart')) continue;
        hits.addAll(_scan(rel, f.readAsStringSync()));
      }

      for (final h in hits) {
        print('  $h');
      }

      expect(
        hits,
        isEmpty,
        reason: '这些地方用 indexOf 定位类声明时写死了会变的基类/子句。\n'
            '改法：只匹配类名 + 边界，不要带 extends/with/implements/大括号。\n'
            '例：把 indexOf(\'class Xxx extends StatelessWidget\') 换成\n'
            '    RegExp 匹配 ^class Xxx\\s+(?:extends|with|implements|\\{)',
      );
    });

    test('★ 阳性对照：扫描器必须能抓到坏样本', () {
      final bad = _scan('fake.dart', [
        'void f() {',
        "  final a = src.indexOf('class _AA extends StatelessWidget');",
        "  final b = src.indexOf('class _BB with Foo');",
        "  final c = src.indexOf('class _CC implements Q');",
        "  final d = src.indexOf('class _DD {');",
        '}',
      ].join('\n'));
      print('[T64] 阳性对照命中 = ${bad.length}（应为 4）');
      expect(bad.length, 4, reason: '扫描器抓不到坏样本 ⇒ 主断言是假绿');
    });

    test('★ 阴性对照：正确写法不许被误报', () {
      final ok = _scan('fake.dart', [
        'void f() {',
        "  final a = src.indexOf('class _AA');",
        "  final b = src.indexOf('class _BB', 10);",
        "  final c = src.indexOf('@override');",
        "  final d = src.indexOf('class ');",
        '}',
      ].join('\n'));
      print('[T64] 阴性对照命中 = ${ok.length}（应为 0）');
      expect(ok, isEmpty, reason: '正确写法被误报 ⇒ 门禁会误伤，没人会留着它');
    });

    test('★ 注释里的反例写法不许被抓', () {
      final cm = _scan('fake.dart', [
        "// 反例：src.indexOf('class _AA extends StatelessWidget')",
        "/* 反例：src.indexOf('class _BB with Mixin') */",
        'void f() {}',
      ].join('\n'));
      print('[T64] 注释内命中 = ${cm.length}（应为 0）');
      expect(cm, isEmpty, reason: '注释是说明不是代码 —— 本文件自己就写满了反例');
    });
  });
}
