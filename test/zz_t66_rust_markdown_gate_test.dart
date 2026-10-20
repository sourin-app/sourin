// ═══════════════════════════════════════════════════════════════════════
//  门禁：Rust 侧**用户可见文案**里 markdown 粗体 `**` 必须 = 0
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这条（与 Dart 侧那条是**两层**，不是重复）
// ```text
// Rust 核心（`rust/sourin_core`）会把文案**穿过 FFI** 交给 Dart 渲染：
// 例如导出备份时那句「未设置导出用的口令 ⇒ …」就是 Rust 拼好的字符串，
// Dart 侧原样塞进 `Text`（`lib/ui/widgets/backup_panel.dart` 的凭据提示）。
// ⇒ 全仓没有 markdown 渲染器 ⇒ 那对星号会**原样显示**给用户。
//
// Dart 侧门禁（`zz_t66_markdown_audit_test.dart`）只扫 `lib/**` 的 `.dart`，
// **扫不到** Rust 字符串字面量 ⇒ 这里是它补不上的那一半。
// 两个文件共用同一个判别式 `_support/markdown_bold.dart`（铁律 170）。
// ```
//
// # 三条判据（与 Dart 侧同构）
// ```text
// ① 只算**字符串字面量**，注释里的 `**` 不算
//    （Rust 注释里满是「**必须**这样」这类强调，会淹掉真命中）。
// ② 三类桶，只有第一类能判红：
//      用户可见 —— 普通字面量，且**不是**日志宏的参数   ⇒ 必须 0 条
//      日志     —— `log::info!` / `println!` 等宏参数    ⇒ 只打印
//      嵌入代码 —— 多行**原始字符串**（`r#"…"#`）：
//                 那里装的是 SQL DDL / 内嵌 JS，星号是**被嵌入语言的注释**，
//                 永远到不了界面                            ⇒ 只打印
// ③ `#[cfg(test)]` 块里的字面量是**夹具**（断言失败信息里故意写 `**`），
//    整块跳过；但**只跳花括号配对的那个块**，不许「看到 cfg(test) 就跳完整个文件」。
// ```
//
// # 防空转（这条门禁最容易退化成恒绿）
// ```text
// 扫描器一旦坏掉（比如把 `'"'` 当成字符串开始、或者干脆不认普通字面量），
// 「用户可见 0 条」会**自动成立**，而门禁看起来全绿。
// ⇒ 所以下面有 5 组**合成样本**自检（不依赖仓库现状）：
//    正常文案 / 日志宏 / 多行原始字符串 / 字符字面量 `'"'` / cfg(test) 块。
// ⇒ 任何一组判错就地变红，而不是等某天漏了真缺陷。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/markdown_bold.dart';
import '_support/rust_string_literals.dart';

/// 日志宏：字面量出现在它后面 ⇒ 进日志，不进界面
const List<String> _logMacros = <String>[
  'log::trace!',
  'log::debug!',
  'log::info!',
  'log::warn!',
  'log::error!',
  'println!',
  'eprintln!',
  'dbg!',
];

/// 一条命中
class _Hit {
  _Hit(this.file, this.line, this.literal, this.bucket);

  final String file;
  final int line;
  final String literal;

  /// '用户可见' | '日志' | '嵌入代码'
  final String bucket;

  @override
  String toString() => '$file:$line  「$literal」';
}

/// 判定一个已取出的字面量属于哪个桶
String _bucketOf(RustLiteral lit) {
  if (lit.raw && lit.text.contains('\n')) return '嵌入代码';
  for (final m in _logMacros) {
    if (lit.before.contains(m)) return '日志';
  }
  return '用户可见';
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 扫描器 + 分桶器的自检（合成样本，不依赖仓库现状）
  // ═══════════════════════════════════════════════════════════════════
  test('★ 自检：Rust 字面量提取与分桶（合成样本）', () {
    const sample = r'''
fn demo(c: char) -> &'static str {
    // 注释里的 **不算**
    log::info!("日志里的**强调**不进界面");
    if c == '"' {
        return "界面文案**粗体**";
    }
    let sql = r#"SELECT 1; -- **注释**
    FROM t"#;
    "最后一句"
}

#[cfg(test)]
mod tests {
    #[test]
    fn t() {
        assert!(false, "夹具里的**强调**");
    }
}
''';
    final lits = rustStringLiterals(sample);

    // ① `'"'` 不许把后面的整段代码吞掉：普通字面量必须被逐个认出
    final texts = lits.map((l) => l.text).toList();
    expect(texts, contains('界面文案**粗体**'),
        reason: '★ 扫描器坏了：`\'"\'` 这个字符字面量被当成了字符串开始，'
            '把后面的代码整段吞掉 ⇒ 真命中全丢。');
    expect(texts, contains('最后一句'),
        reason: '★ 扫描器坏了：字符字面量之后的普通字面量没被取出。');
    expect(texts.any((t) => t.contains('注释里的')), isFalse,
        reason: '★ 扫描器坏了：`//` 注释被当成了字面量。');

    // ② 分桶：日志宏 / 用户可见 / 多行原始字符串（嵌入代码）/ cfg(test)
    final byText = {for (final l in lits) l.text: l};
    expect(_bucketOf(byText['日志里的**强调**不进界面']!), '日志');
    expect(_bucketOf(byText['界面文案**粗体**']!), '用户可见');
    expect(_bucketOf(byText['SELECT 1; -- **注释**\n    FROM t']!), '嵌入代码');
    expect(
      lits.where((l) => l.inCfgTest).map((l) => l.text),
      contains('夹具里的**强调**'),
      reason: '★ cfg(test) 块的识别坏了 ⇒ 夹具里的星号会被当成产品文案。',
    );
    expect(
      lits.where((l) => l.inCfgTest).length,
      1,
      reason: '★ cfg(test) 的块边界算错了（应只圈住 `mod tests` 那个块，'
          '不许把文件剩下的部分都当成夹具）。',
    );

    // ③ 判别式自身双向自检（与 Dart 侧同一条纪律）
    expect(kRedactionMaskSamples.map(isMarkdownBoldLiteral), everyElement(isFalse),
        reason: '★★ 判别式退化：脱敏掩码被当成 markdown 粗体。');
    expect(isMarkdownBoldLiteral('**粗体**'), isTrue,
        reason: '★★ 判别式坏了：连成对粗体都认不出来 ⇒ 本门禁永远绿。');
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 真门禁：rust/sourin_core/src 里用户可见文案的 `**` 必须 = 0
  // ═══════════════════════════════════════════════════════════════════
  test('★ rust/sourin_core/src 用户可见文案 `**` 必须 = 0', () {
    final root = Directory('rust/sourin_core/src');
    expect(root.existsSync(), isTrue,
        reason: '★ 防空转：扫描根不存在：rust/sourin_core/src');

    final files = root
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.rs'))
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));

    final hits = <_Hit>[];
    var scanned = 0;
    var literalCount = 0;

    for (final f in files) {
      scanned++;
      final rel = f.path.replaceAll(r'\', '/');
      final raw = f.readAsStringSync();
      for (final lit in rustStringLiterals(raw)) {
        literalCount++;
        if (lit.inCfgTest) continue; // 夹具：允许任意星号
        if (!isMarkdownBoldLiteral(lit.text)) continue;
        hits.add(_Hit(rel, lit.line, _clip(lit.text), _bucketOf(lit)));
      }
    }

    final visible = hits.where((h) => h.bucket == '用户可见').toList();
    final other = hits.where((h) => h.bucket != '用户可见').toList()
      ..sort((a, b) {
        final c = a.file.compareTo(b.file);
        return c != 0 ? c : a.line.compareTo(b.line);
      });

    // ignore: avoid_print
    print('RUSTRGATE|扫描 $scanned 个 .rs / $literalCount 条字面量：'
        '用户可见 ${visible.length} 条 / 日志+嵌入代码 ${other.length} 条');
    for (final h in other) {
      // ignore: avoid_print
      print('RUSTRGATE|${h.bucket}（非红）${h.toString()}');
    }

    // ── 防空转自检（与仓库现状挂钩的那几条）──────────────────────────
    expect(scanned, greaterThanOrEqualTo(25),
        reason: '★ 防空转：只扫到 $scanned 个 .rs ⇒ 扫描根或递归坏了。');
    expect(literalCount, greaterThanOrEqualTo(2000),
        reason: '★ 防空转：只取出 $literalCount 条字面量（实测 > 2000）'
            '⇒ 提取器坏了，下面的「== 0」会恒真。');

    // 提取链真的工作：一条**已知的跨 FFI 产品文案**必须被取出
    // （导出备份时那句提示，`commands_backup.rs`）
    final exportSrc =
        File('rust/sourin_core/src/commands_backup.rs').readAsStringSync();
    final exportLits = rustStringLiterals(exportSrc).map((l) => l.text).toList();
    expect(
      exportLits.any((t) => t.contains('未设置导出用的口令')),
      isTrue,
      reason: '★ 防空转：没读到已知的导出提示文案 ⇒ 提取器已失效。',
    );
    // ★ 回归钉：这句提示里**不许**再出现 markdown 粗体
    //   （2026-10-20 之前写的是 `**不含登录态**`，星号会画到界面上）
    expect(
      exportLits.where((t) => t.contains('不含登录态') && isMarkdownBoldLiteral(t)),
      isEmpty,
      reason: '★★ 导出提示里出现了 markdown 粗体：这句话会原样显示给用户。\n'
          '修法：改成中文引号「」，与 Dart 侧同一条先例。',
    );

    // ── 真断言 ──────────────────────────────────────────────────────
    expect(
      visible,
      isEmpty,
      reason: '★★★ Rust 里有用户可见文案带 markdown 粗体 `**`。\n'
          '这些字符串会穿过 FFI 交给 Dart 的 `Text` 原样显示，'
          '而全仓没有 markdown 渲染器 ⇒ 用户看到的是星号。\n'
          '修法：改成中文引号「」。\n'
          '命中：\n${visible.map((h) => '  · $h').join('\n')}',
    );
  });
}

String _clip(String s) {
  final oneLine = s.replaceAll('\n', r'\n');
  return oneLine.length > 120 ? '${oneLine.substring(0, 120)}…' : oneLine;
}
