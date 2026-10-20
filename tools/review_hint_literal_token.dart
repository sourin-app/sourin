// tools/review_hint_literal_token.dart
//
// ══════════════════════════════════════════════════════════════════════
//  ⚠️ 这**不是门禁**，不进 CI，退出码恒 0（`--selftest` 除外，见下）。
//
//  它的输出是「供人看一眼的候选清单」，不是「错误」。
//
//  ★ 判据（Lead 2026-10-21 定）：
//    一个工具说「这是提示」还是「这是错误」，必须在**名字和输出**里都写清。
//    所以名字带 `review_hint_`，输出第一行写明"提示，非错误"。
//
//  ★ 为什么它**不做成门禁**（这是一个**排除性结论**，值得记）
//  ```text
//  本仓实测 0 命中。而 0 命中的门禁**无法在日常运行中被验证**：
//  它永远绿，与"工具静默失效"在输出上无法区分。
//
//  可以靠"每次跑都造一段缺陷源码"来验证（--selftest 就是这么做的），
//  但那等于在 CI 里常驻一个扫描器 —— 成本确定，而收益是
//  "防止将来某人写出这类代码"。
//
//  而"将来有人会写出来"这个假设**没有被验证**：
//  第 66 轮全组写了 8 个新门禁，只有一处用了字面值，且同一行注释里
//  已经写了正确算式（近乎笔误）。
//  ⇒ 更像"一个人一次手误"，不是"一类系统性风险"。
//  ⇒ 针对一次手误建常设门禁 = 用常设机构处理一次事故。
//  ```
//
//  ★ 何时该把它升级成门禁（反例条件）：
//  ```text
//  · 这类缺陷再出现 2 次以上（不同人 / 不同文件）⇒ 系统性风险
//  · 或它出现在**产品代码**里（不是测试）⇒ 危害从"误报"升级为"行为错误"
//  ```
// ══════════════════════════════════════════════════════════════════════
//
// # 它找什么
//
// 测试文件里这种形态：
// ```dart
// // 期望：min(w, 视口宽 − 2*Sp.x4)          ← 注释里有**算式**
// final expectW = math.min(w, math.max(vp.width - 32, 260));   ← 代码是字面值 32
// ```
// `2*Sp.x4` 算出来正好是 32 ⇒ 可疑：作者声明了一个算式，代码却没照做。
//
// # 为什么只认「算式」不认「token 名」（这是第二版）
//
// 第一版用「注释含 Sp.xN 名 + 代码含该值」扫 564 个文件，命中 5 处，
// **逐条人工判断后 5 处全部是正常写法**（假红率 100%）：
// ```text
// test/t75_browse_autoload_test.dart:57
//   /// 展开高度（= 吸顶高度 + `Sp.x8`）      ← 解释"这个数等于什么"
//   const double kHeaderMax = kHeaderMin + 32;
// ```
// ⇒ token 名信息量太低。算式（`2*Sp.x4`）才表达"这里应该用什么"。
//
// # 用法
// ```bash
// dart run tools/review_hint_literal_token.dart              # 扫 test/
// dart run tools/review_hint_literal_token.dart lib test     # 指定目录
// dart run tools/review_hint_literal_token.dart --selftest   # 自证有效（现算）
// ```
//
// # ★ 为什么有 `--selftest`（Lead 2026-10-21 要求）
// ```text
// 文件头写"实测命中 N 处"是**历史读数**，正则一改就过期、且没人会重跑。
// `--selftest` 每次都**现造**两段源码（一正一负）、现跑、现断言。
// ⇒ 谁想验证这个工具时，一条命令就能自证，不依赖任何存档读数。
// ⇒ 它比"进 CI 做对照组"便宜，比"注释里的历史读数"可靠。
// ```
//
// # 实测（2026-10-21）
// ```text
// 本仓（564 个 test/*.dart）：命中 0 处
// --selftest：PASS（阳性必中、阴性不中）
// ```
//
// ⚠️ 已知不覆盖：注释本身写错（写 `2*Sp.x4` 但实际该是 `3*Sp.x4`）
//    不属于本工具的判据范围 —— 它假设注释表达的是**真实意图**。

import 'dart:io';

/// token 名 → 当前值。只放间距类（也是最容易被写成字面值的）。
const _tokens = <String, int>{
  'Sp.x1': 4,
  'Sp.x2': 8,
  'Sp.x3': 12,
  'Sp.x4': 16,
  'Sp.x5': 20,
  'Sp.x6': 24,
  'Sp.x8': 32,
  'Sp.x10': 40,
  'Sp.x12': 48,
  'Sp.x16': 64,
};

/// 注释里的算式，形如 `2*Sp.x4` / `Sp.x4 * 2` / `3 * Sp.x2`
final _exprRe = RegExp(
  r'(\d+)\s*\*\s*(Sp\.x\d+)|(Sp\.x\d+)\s*\*\s*(\d+)',
);

/// 扫描一段源码，返回命中列表。
///
/// ★ 抽成纯函数是为了让 `--selftest` 用的是**同一份**逻辑
///   （而不是复制一份 —— 那正是"同一个源比同一个源"的假绿形态）。
List<String> scanSource(String path, String source) {
  final out = <String>[];
  final lines = source.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trimLeft();
    if (!(t.startsWith('//') || t.startsWith('*'))) continue;

    for (final m in _exprRe.allMatches(lines[i])) {
      final mult = int.tryParse((m.group(1) ?? m.group(4)) ?? '');
      final tok = m.group(2) ?? m.group(3) ?? '';
      final base = _tokens[tok];
      if (mult == null || base == null) continue;
      final expected = mult * base;

      // 注释后 4 行内找该字面值
      for (var j = i + 1; j < lines.length && j <= i + 4; j++) {
        final c = lines[j].trimLeft();
        if (c.startsWith('//') || c.startsWith('*')) continue;
        final re = RegExp(r'(?<![\w.])' + expected.toString() + r'(?![\w.])');
        if (re.hasMatch(lines[j])) {
          out.add('HINT|$path:${i + 1}|算式=$mult*$tok|算出=$expected'
              '|代码=${lines[j].trim()}');
          break;
        }
      }
    }
  }
  return out;
}

void main(List<String> args) {
  if (args.contains('--selftest')) {
    _selftest();
    return;
  }

  stdout.writeln('=== 提示（不是错误）：注释里写了算式，代码里却是它的算好值 ===');
  stdout.writeln('=== 这是供人 review 的候选清单。退出码恒 0。 ===');
  stdout.writeln('');

  final roots = args.isEmpty ? ['test'] : args;
  final files = <File>[];
  for (final r in roots) {
    final d = Directory(r);
    if (!d.existsSync()) continue;
    for (final e in d.listSync(recursive: true)) {
      if (e is! File || !e.path.endsWith('.dart')) continue;
      final p = e.path.replaceAll('\\', '/');
      if (p.contains('/support/')) continue; // 工具/夹具目录，不判
      files.add(e);
    }
  }

  var hits = 0;
  for (final f in files) {
    final p = f.path.replaceAll('\\', '/');
    for (final h in scanSource(p, f.readAsStringSync())) {
      hits++;
      stdout.writeln(h);
    }
  }

  stdout.writeln('');
  stdout.writeln('扫描 ${files.length} 个 dart 文件，命中 $hits 处。');
  stdout.writeln('⚠️ 命中 ≠ 缺陷。请人工判断注释表达的是"意图"还是"解释数值"。');
  // ★ 恒 0：这不是门禁
  exitCode = 0;
}

/// 自证有效：**现造**一正一负两段源码，现跑，现断言。
///
/// ★ 为什么必须现造而不是读存档：
///   文件头写的"实测命中 N 处"是历史读数，正则一改就过期。
///   这里每次跑都重新生成，所以它验证的是**当前这份代码**。
void _selftest() {
  stdout.writeln('=== selftest：验证扫描器本身有效（不是验证仓里有没有问题）===');
  stdout.writeln('');

  /*
   * 阳性：注释有算式 + 代码是字面值 ⇒ **必须**命中。
   * 内容刻意用 2026-10-21 那次的真实形态（假阳性修之前的 D-2）。
   */
  const positive = '''
void main() {
  // 期望：min(w, 视口宽 − 2*Sp.x4)，下限 260
  final expectW = 800 - 32;
}
''';

  /*
   * 阴性：注释只有 token 名（**解释数值**），没有算式 ⇒ **不该**命中。
   * 对应当前仓里 5 处"钉实现"写法的真实形态。
   */
  const negative = '''
void main() {
  /// 展开高度（= 吸顶高度 + `Sp.x8`）
  const double kHeaderMax = 40 + 32;
}
''';

  final posHits = scanSource('selftest://positive.dart', positive);
  final negHits = scanSource('selftest://negative.dart', negative);

  final posOk = posHits.length == 1;
  final negOk = negHits.isEmpty;

  stdout.writeln('[1/2] 阳性对照（注释算式 2*Sp.x4 + 代码 32）');
  stdout.writeln('      期望命中 1 处，实际 ${posHits.length} 处 ⇒ '
      '${posOk ? "PASS" : "FAIL"}');
  for (final h in posHits) {
    stdout.writeln('      $h');
  }
  stdout.writeln('');
  stdout.writeln('[2/2] 阴性对照（注释只有 `Sp.x8` 名、无算式）');
  stdout.writeln('      期望命中 0 处，实际 ${negHits.length} 处 ⇒ '
      '${negOk ? "PASS" : "FAIL"}');
  for (final h in negHits) {
    stdout.writeln('      $h');
  }
  stdout.writeln('');

  if (posOk && negOk) {
    stdout.writeln('SELFTEST PASS —— 扫描器当前这份代码是有效的：'
        '该抓的抓得到、该放过的不误报。');
    exitCode = 0;
  } else {
    stdout.writeln('SELFTEST FAIL —— 扫描器失效了（正则/token 表被改过？）。');
    stdout.writeln('★ 此时扫描结果"0 命中"**不可信**。');
    // ★ selftest 失败才给非 0：它验证的是工具自身，不是仓里的问题
    exitCode = 1;
  }
}
