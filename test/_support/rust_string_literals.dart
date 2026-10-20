// ═══════════════════════════════════════════════════════════════════════
//  ★ 唯一的「Rust 源码里的字符串字面量」提取器（铁律 170）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不能复用 `_support/strip_comments.dart`
// ```text
// 那个状态机是**为 Dart 写的**：只认 `//` 与 `/* */`，而且**不认**
// Rust 的三种写法：
//   ① 字符字面量 `'"'` —— 里面那个双引号会被当成「字符串开始」，
//      于是一直扫到下一个双引号，把中间整段代码当成一个字面量
//      （实测：这样扫 `plugins/mod.rs` 会产出 63 条假命中，
//       全是跨几十行的注释碎片）。
//   ② 原始字符串 `r"…"` / `r#"…"#` —— 内部**没有**转义，
//      且 `#` 的个数决定闭合边界。
//   ③ 生命周期标记 `'a`（`&'a str`）—— 与字符字面量同形但**没有闭合引号**。
// ⇒ 谁要用 Rust 字面量，**只许调本文件**，不许在测试里再抄一份扫描器。
// ```
//
// # 判据边界（本文件只管「取出字面量」，不管「它是不是 markdown」）
// ```text
// 取出之后要不要判红，交给调用方；判别式复用
// `_support/markdown_bold.dart` 的 `isMarkdownBoldLiteral`
// （**不要**在这里另写一份 `contains('**')`，那会把脱敏掩码也算成粗体）。
// ```
library;

/// 一条 Rust 字符串字面量
class RustLiteral {
  const RustLiteral({
    required this.line,
    required this.text,
    required this.raw,
    required this.inCfgTest,
    required this.before,
  });

  /// 1 起的行号（字面量**开始**的那一行）
  final int line;

  /// 字面量内容（不含两侧引号 / 不含 `r#"` 与 `"#`）
  final String text;

  /// 是否是原始字符串 `r"…"` / `r#"…"#`
  final bool raw;

  /// 是否落在 `#[cfg(test)] mod … { … }` 里（那里是夹具，允许出现任意星号）
  final bool inCfgTest;

  /// 该字面量**之前** 240 个字符的源码（已把注释抹成空格）
  ///
  /// 用来判它是被 `log::info!` / `println!` 这类宏包住的，还是直接进 UI 的。
  final String before;
}

/// 取出一段 Rust 源码里**所有**字符串字面量（跳过注释与字符字面量）
List<RustLiteral> rustStringLiterals(String src) {
  final lineOf = _LineIndex(src);
  // ★ 不用「先把 cfg(test) 抹掉」的做法：抹掉的话块里的字面量**取不出来**，
  //   调用方就没法给它们打 `inCfgTest` 标记（自检也会看不见夹具样本）。
  //   ⇒ 原样扫描，命中后由 `inCfgTest` 决定跳不跳。
  final masked = src;
  final out = <RustLiteral>[];

  var i = 0;
  final n = masked.length;
  while (i < n) {
    final c = masked[i];

    // ── 行注释 ──
    if (c == '/' && i + 1 < n && masked[i + 1] == '/') {
      while (i < n && masked[i] != '\n') {
        i++;
      }
      continue;
    }

    // ── 块注释（Rust 允许嵌套）──
    if (c == '/' && i + 1 < n && masked[i + 1] == '*') {
      var depth = 1;
      i += 2;
      while (i + 1 < n && depth > 0) {
        if (masked[i] == '/' && masked[i + 1] == '*') {
          depth++;
          i += 2;
          continue;
        }
        if (masked[i] == '*' && masked[i + 1] == '/') {
          depth--;
          i += 2;
          continue;
        }
        i++;
      }
      continue;
    }

    // ── 原始字符串 r"…" / r#"…"#（`#` 的个数决定闭合边界）──
    if (c == 'r') {
      var j = i + 1;
      var hashes = 0;
      while (j < n && masked[j] == '#') {
        hashes++;
        j++;
      }
      if (j < n && masked[j] == '"') {
        final start = i;
        final bodyStart = j + 1;
        final close = '"${'#' * hashes}';
        var k = masked.indexOf(close, bodyStart);
        if (k < 0) k = n;
        out.add(RustLiteral(
          line: lineOf.at(start),
          text: masked.substring(bodyStart, k),
          raw: true,
          inCfgTest: _inCfgTest(src, start),
          before: _before(masked, start),
        ));
        i = k + close.length;
        continue;
      }
    }

    // ── 字符字面量 `'"'` / `'\''` / `'\u{1F600}'` / 生命周期 `'a` ──
    if (c == "'") {
      final charLit = RegExp(r"'(?:\\u\{[0-9a-fA-F]+\}|\\.|[^\\'])'")
          .matchAsPrefix(masked, i);
      if (charLit != null) {
        i = charLit.end;
        continue;
      }
      i++; // 生命周期标记，不是字面量
      continue;
    }

    // ── 普通字符串 "…"（含转义）──
    if (c == '"') {
      final start = i;
      i++;
      final buf = StringBuffer();
      while (i < n) {
        if (masked[i] == '\\' && i + 1 < n) {
          buf
            ..write(masked[i])
            ..write(masked[i + 1]);
          i += 2;
          continue;
        }
        if (masked[i] == '"') {
          i++;
          break;
        }
        buf.write(masked[i]);
        i++;
      }
      out.add(RustLiteral(
        line: lineOf.at(start),
        text: buf.toString(),
        raw: false,
        inCfgTest: _inCfgTest(src, start),
        before: _before(masked, start),
      ));
      continue;
    }

    i++;
  }
  return out;
}

/// 该偏移是否落在 `#[cfg(test)]` 开的模块块里
///
/// 判据是**花括号配对**（不是「看到 cfg(test) 就算」）：
/// `#[cfg(test)]` 也可能挂在单个 `fn` / `use` 上，那样它后面没有块，
/// 不能把文件剩下的部分全当成夹具 —— 那会**静默放过**产品文案。
bool _inCfgTest(String src, int offset) {
  for (final span in _cfgTestSpans(src)) {
    if (offset >= span.$1 && offset < span.$2) return true;
  }
  return false;
}

/// `#[cfg(test)]` 之后第一个块 `{ … }` 的区间列表
List<(int, int)> _cfgTestSpans(String src) {
  final spans = <(int, int)>[];
  for (final m in RegExp(r'#\[cfg\(test\)\]').allMatches(src)) {
    final open = src.indexOf('{', m.end);
    if (open < 0) continue;
    var depth = 0;
    var k = open;
    while (k < src.length) {
      if (src[k] == '{') {
        depth++;
      } else if (src[k] == '}') {
        depth--;
        if (depth == 0) break;
      }
      k++;
    }
    final end = k + 1 > src.length ? src.length : k + 1;
    spans.add((m.start, end));
  }
  return spans;
}

String _before(String masked, int start) {
  final from = start - 240 < 0 ? 0 : start - 240;
  final head = masked.substring(from, start);
  // ★ 只保留**当前表达式**：退到最近的语句/块边界。
  //   不这么做的话，前 240 字符会跨越很多行 —— 同一个函数里前面那行
  //   `log::info!(…)` 会让后面一句普通文案被误判成日志
  //   （实测：合成样本里的界面文案就是这么被判成"日志"的）。
  var cut = 0;
  for (final stop in <String>[';', '{', '}']) {
    final at = head.lastIndexOf(stop);
    if (at + 1 > cut) cut = at + 1;
  }
  return head.substring(cut);
}

class _LineIndex {
  _LineIndex(String src) {
    _starts.add(0);
    for (var i = 0; i < src.length; i++) {
      if (src[i] == '\n') _starts.add(i + 1);
    }
  }

  final List<int> _starts = <int>[];

  /// 偏移 ⇒ 1 起的行号（二分）
  int at(int offset) {
    var lo = 0;
    var hi = _starts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) ~/ 2;
      if (_starts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return lo + 1;
  }
}
