// ═══════════════════════════════════════════════════════════════════════
//  ★ 唯一的「这是不是 markdown 粗体」判别式（铁律 170）
// ═══════════════════════════════════════════════════════════════════════
//
// # ★★ 先分清两件事（这是本文件最重要的部分）
//
// ```text
// 仓库里"扫星号"的门禁分**两层**，判据**故意不同**，不要统一成一个：
//
//   ① 源码层：扫 Dart **字符串字面量**
//      → 用 [isMarkdownBoldLiteral]
//      → 必须**放过脱敏掩码**（'****' / '${id.substring(0,4)}****' / '***'）
//        否则门禁会要求把掩码改成「」⇒ 把打码的 AppId 明文暴露给用户。
//      使用者：md_gate / dan_asterisk_gate / cs1_no_markdown_leak /
//              data_manage_md_review / markdown_audit
//
//   ② 渲染层：扫**已经画到屏幕上的 Text**
//      → 用 [isMarkdownBoldRendered]（结构判据，同 ①）
//      → ★ 屏幕上的 `****` 是**用户真实看到的字符**，
//        不存在"要不要改它"的问题 —— 但要判的是「成对粗体」，不是"有星号"。
//      使用者：md_gate / dan_asterisk_gate / cs1_no_markdown_leak /
//              data_manage_md_review / playback_page_asterisk_gate
// ```
//
// ⚠️ **不要**把渲染层改成 `isMarkdownBoldLiteral` 的语义然后去扫源码，
//   也不要拿源码层判据去判屏幕文本 —— 两者扫的对象不同。
//
// # 为什么必须有唯一实现
//
// 2026-10-19 批末自审（`r3-dns`）查出：仓库里**同时存在两种判别式**，
// 而它们在**真实的脱敏掩码**上给出**相反结论**：
//
// ```text
// A（本文件）：要求 `**…**` 的星号之间**含非星号字符**
// B（朴素 contains('**')）：只要出现 `**` 就算
//
// 实测：
//   '****'                       A=false（是掩码）  B=true（被当成 markdown）
//   '${id.substring(0, 4)}****'  A=false            B=true
//   '***'                        A=false            B=true
// ```
//
// # 这个分裂为什么危险（不是洁癖，是安全）
//
// ```text
// 若有人拿 B 去扫 lib/core/danmaku.dart，门禁会**要求**把这三处改成「」。
// 而它们是有意的脱敏掩码：
//   danmaku.dart:1431  '****'                     ← maskedAppId，id 过短时全打码
//   danmaku.dart:1432  '${id.substring(0,4)}****'  ← abcd****
//   danmaku.dart:2223  '***'                      ← URL 脱敏（路径首段替换）
// ⇒ 改掉 = 把打码后的 AppId 与真实域名**明文暴露给用户**。
// ⇒ 也就是「为了让门禁变绿而制造安全缺陷」——本仓明令禁止。
// ```
//
// # 判据本身（唯一的结构差别）
//
// ```text
//   掩码：星号之间**什么都没有**（全是星号）      ⇒ `****`
//   粗体：星号之间**有文字**                      ⇒ `**粗体**`
// ⇒ 正则 `\*\*[^*]*[^*][^*]*\*\*`：要求两个星号之间至少有一个非星号字符。
// ```
//
// ⚠️ 只匹配**单引号字面量**（Dart 代码里用户可见文案的绝大多数形态）。
//    双引号 / 三引号若将来需要，**在这里扩**，不要在别处另写一份。
library;

/// 从一段 Dart 源码里取出所有「含 markdown 粗体」的**字符串字面量**
///
/// 入参应为**已剥注释**的源码（用 `_support/strip_comments.dart`）。
/// 返回命中的字面量内容（不含两侧引号）。
List<String> markdownBoldLiterals(String code) {
  final out = <String>[];
  for (final m in RegExp(r"'([^'\\\n]*)'").allMatches(code)) {
    final lit = m.group(1) ?? '';
    if (!lit.contains('**')) continue;
    // ★★ 判据：存在一处 `**…**`，`…` 里**含非星号字符**
    //   （掩码的星号之间是空的 ⇒ 不匹配）
    if (!RegExp(r'\*\*[^*]*[^*][^*]*\*\*').hasMatch(lit)) continue;
    out.add(lit);
  }
  return out;
}

/// 单条字面量判定（给按行扫描的调用方用）
bool isMarkdownBoldLiteral(String literal) {
  if (!literal.contains('**')) return false;
  return RegExp(r'\*\*[^*]*[^*][^*]*\*\*').hasMatch(literal);
}

/// 这三处是**脱敏掩码**，任何「清 markdown」的批量动作都**绝不许碰**
///
/// ★ 门禁可以用它做红线自检：把这三条喂给 [isMarkdownBoldLiteral]，
///   必须全部返回 `false` —— 否则说明判据退化成了朴素的 `contains('**')`。
const List<String> kRedactionMaskSamples = <String>[
  '****',
  r'${id.substring(0, 4)}****',
  '***',
];

/// 判断一段**渲染出来的文本**里有没有 markdown 粗体
///
/// # 为什么它和 [isMarkdownBoldLiteral] 是两个函数，而不是一个
///
/// ```text
/// 两者扫的对象**不同**，判据也必须不同：
///
///   isMarkdownBoldLiteral  —— 扫**源码字面量**。
///     这里必须**放过脱敏掩码**（`'****'` / `'${id.substring(0,4)}****'` / `'***'`），
///     否则门禁会要求把掩码改成「」，把打码的 AppId 明文暴露给用户。
///
///   本函数 —— 扫**已经画到屏幕上的文字**。
///     ★ 渲染后**不存在**「源码里的掩码字面量」这个问题：
///       用户看到的要么是真 AppId（`abcd****`），要么什么都没有。
///       而 `'****'` 出现在屏幕上时，它就是**用户看到的字符**，
///       这里**没有"要不要改它"的问题** —— 门禁只报告"屏幕上有星号"。
/// ```
///
/// ⚠️ 但这带来一个**真实的误报风险**，必须写清楚：
/// ```text
/// `DanmakuConfig.statusText` 会把 `maskedAppId` 拼进状态行
/// （`lib/core/danmaku.dart:1442-1443`：'弹幕已开启（AppId $maskedAppId）'），
/// 而那一行确实会被 `Text(_statusText(s))` 渲染
/// （`danmaku_settings_dialog.dart:2748`）。
/// ⇒ 所以**渲染层门禁**若用"屏幕上有 `****` 就算 markdown 泄漏"，
///   会在「用户配过 AppId」时误报。
/// ⇒ 判据：渲染层**不要**把 `****` 判成 markdown；
///   要判的是「成对包裹的 `**粗体**`」—— 与源码层同一个结构判据。
/// ```
bool isMarkdownBoldRendered(String text) {
  if (!text.contains('**')) return false;
  // 与源码层同一个结构判据：星号之间必须夹着**非星号**字符
  return RegExp(r'\*\*[^*]*[^*][^*]*\*\*').hasMatch(text);
}

/// 渲染文本里**出现星号**（含掩码）—— 只用于"报告"，不用于"判失败"
///
/// 给需要「把屏幕上所有星号列出来给人看」的门禁用；
/// 若拿它判失败，会在用户配过 AppId 时误报（见 [isMarkdownBoldRendered] 的说明）。
bool hasAnyAsterisk(String text) => text.contains('*');
