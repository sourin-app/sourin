// ═══════════════════════════════════════════════════════════════════════
//  源码断言的**唯一**剥注释实现（2026-11-01 抽出）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须有它（本批两次踩中同一类假绿）
// ```text
// 接线层断言若直接 `src.contains('xxx')`，把那行代码**注释掉**照样匹配
// ⇒ 注入之后门禁**仍是绿的**（"接线了但没真接"就靠这道缝活下来）。
// ⇒ 断言前必须先把 // 与 /* */ 剥掉。
// ```
//
// # 为什么是**状态机**而不是正则
// ```text
// 字符串字面量里可能出现 `//`（URL 就是最典型的：`https://x`）。
// 正则分不清"注释开始"与"字符串里的两个斜杠" ⇒ 会把 URL 后半段当成注释
// 删掉 ⇒ 真代码被削掉 ⇒ 断言假红（另一类假象）。
// ⇒ 逐字符扫，带引号状态（先例：t20261030_sample_line_test.dart 的同款实现）。
// ```
//
// ⚠️ 抽成共用文件的原因：第二份实现迟早会与第一份漂移（本仓铁律 170），
//    而漂移的表现恰恰是"一边能抓、一边抓不到"。
library;

/// 剥掉 `//` 行注释与 `/* */` 块注释（**保留字符串字面量**，保留行号密度）
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (n.isNotEmpty) {
          out.write(n);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && n == '*') {
      i += 2;
      while (i < src.length &&
          !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n');
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}
