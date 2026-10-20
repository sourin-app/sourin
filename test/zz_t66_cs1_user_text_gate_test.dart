// ═══════════════════════════════════════════════════════════════════════
//  CS-1 门禁：用户可见文案的**噪声字符**与**关键告知缺失**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件补的是哪一块
//
// 已有两条门禁，各管一半：
// ```text
// zz_t66_markdown_audit_test.dart   扫 lib/**/*.dart 的 `**`
// zz_t66_rust_markdown_gate_test.dart 扫 rust/**/*.rs 的 `**`（用户可见桶）
// ```
// 它们都**只管 `**`**。本轮实测发现另一个同类噪声：**连续空格**。
//
// ```text
// 2026-10-20 实测（Rust 侧第二条 note）：
//   "未设置导出用的口令 ⇒ …（其它数据都在）。                 要一起备份…"
//                                            ↑ 17 个空格
// 它经 FFI 进 Dart 的 Text（全仓无 markdown/富文本渲染器）
// ⇒ 用户看到一句中间裂开一大块空白的文案。
// ```
//
// ★ 为什么它没被 `**` 门禁抓到：那两条的判据是 `isMarkdownBoldLiteral`
//   （只认 `**`）。**判据的对象不同，就不是同一条门禁** ——
//   这是本仓反复出现的"以为覆盖了其实没覆盖"。
//
// # 本文件的两组判据
//
// ```text
// ① 噪声字符：Rust 用户可见串里不许有 连续空格 / 制表符 / 零宽字符
// ② 关键告知：凭据同步 UI 必须明确说「服务端解不开」
//    ★ 理由见下面那条用例的注释（用户最关心的正是这一句）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Rust 侧 CS-1 的**用户可见**源文件
///
/// ⚠️ 只扫 CS-1 相关的三个文件（不扫整个 rust/）：
///    本门禁的判据只在 CS-1 的文案上成立，扫全域会把别人的文件拖进来。
const List<String> _cs1RustFiles = <String>[
  'rust/sourin_core/src/commands_backup.rs',
  'rust/sourin_core/src/sync/credentials.rs',
  'rust/sourin_core/src/sync/mod.rs',
];

/// 提取源码里的**中文单行字符串字面量**（跳过注释）
///
/// ★ 只取含中文的：纯 ASCII 串（`"sha256="` / `"dev-a"`）不是用户可见文案。
/// ★ 只取单行：跨行字面量在 Rust 里要用 `\` 续行，那种写法本仓没有；
///   而多行原始字符串（`r#"…"#`）是嵌入的 SQL/JS，不是文案
///   —— 与 `zz_t66_rust_markdown_gate_test.dart` 的桶划分保持一致。
List<({int line, String text})> chineseLiterals(String src) {
  final out = <({int line, String text})>[];
  final lines = src.split('\n');
  final re = RegExp(r'"([^"\\]*[\u4e00-\u9fff][^"\\]*)"');
  var inBlock = false;
  var inRaw = false;

  for (var i = 0; i < lines.length; i++) {
    final t = lines[i].trim();

    // 跳过块注释（Rust 的 /// 与 //! 是行注释，由下面 split('//') 处理）
    if (inBlock) {
      if (t.contains('*/')) inBlock = false;
      continue;
    }
    if (t.startsWith('/*')) {
      inBlock = true;
      if (t.contains('*/')) inBlock = false;
      continue;
    }
    // 跳过多行原始字符串（内嵌 SQL / JS）
    if (inRaw) {
      if (t.contains('"#')) inRaw = false;
      continue;
    }
    if (t.contains('r#"') || t.contains('r##"')) {
      if (!t.contains('"#')) inRaw = true;
      continue;
    }

    // 去掉行注释（本仓的字符串里不含 `//`，见 URL 已用变量拼接）
    final code = lines[i].contains('//')
        ? lines[i].substring(0, lines[i].indexOf('//'))
        : lines[i];
    for (final m in re.allMatches(code)) {
      out.add((line: i + 1, text: m.group(1)!));
    }
  }
  return out;
}

/// 一句话里有没有**用户可见的噪声**
///
/// # 判据（每条都对应一种"到界面上会变成难看字符"的形态）
/// ```text
/// 连续 2+ 空格   → 界面自动换行，那段空白毫无意义
/// 制表符 \t      → 在 Text 里宽度不定，且本仓文案不用表格对齐
/// 零宽字符       → 完全不可见，只会让文案"看起来少了一个字"
/// ```
/// ⚠️ **不查** `**`：那已经有两条专门的门禁（见文件头），
///    在这里再查一遍就是"同一份真相两处维护"。
List<String> noiseIn(String text) {
  final problems = <String>[];
  if (RegExp(r'  +').hasMatch(text)) {
    final m = RegExp(r'  +').firstMatch(text)!;
    problems.add('连续空格 ×${m.group(0)!.length}（"${m.group(0)}"）');
  }
  if (text.contains('\t')) problems.add('制表符 \\t');
  for (final zw in ['\u200b', '\u200c', '\u200d', '\ufeff']) {
    if (text.contains(zw)) problems.add('零宽字符 U+${zw.codeUnitAt(0).toRadixString(16)}');
  }
  return problems;
}

void main() {
  // ─────────────────────────────────────────────────────────────
  // ⓪ 仪器自检
  // ─────────────────────────────────────────────────────────────

  group('⓪ 仪器自检', () {
    test('★ 提取器能抓到真实的中文字面量', () {
      final lits = chineseLiterals(File(_cs1RustFiles[0]).readAsStringSync());
      expect(
        lits,
        isNotEmpty,
        reason: '★ 一条都没提取到 ⇒ 提取器坏了，下面全是假绿',
      );
      // 必须抓到那条已知的 note（它是 CS-1 的核心文案之一）
      expect(
        lits.any((e) => e.text.contains('已加密包含')),
        isTrue,
        reason: '★ 应当能抓到「已加密包含…」那条 note',
      );
    });

    test('★ 提取器跳过注释里的中文', () {
      const src = '''
// 这是一条注释，不该被提取
/// 文档注释也不该
let a = "真正的中文文案在这里";
''';
      final lits = chineseLiterals(src);
      expect(lits.length, 1, reason: '注释里的中文不该被算进来: $lits');
      expect(lits.first.text, '真正的中文文案在这里');
    });

    test('★ 提取器跳过内嵌原始字符串', () {
      const src = '''
let sql = r#"
  SELECT * FROM t WHERE name = '中文注释'
"#;
let b = "真的文案";
''';
      final lits = chineseLiterals(src);
      expect(lits.length, 1, reason: '原始字符串里的中文不该被算进来: $lits');
      expect(lits.first.text, '真的文案');
    });

    test('★ noiseIn 的阳性/阴性对照', () {
      expect(noiseIn('正常的一句话'), isEmpty);
      expect(noiseIn('两个  空格'), isNotEmpty);
      expect(noiseIn('一堆                   空格'), isNotEmpty);
      expect(noiseIn('制表\t符'), isNotEmpty);
      expect(noiseIn('零宽\u200b字符'), isNotEmpty);
      // 单个空格是正常的（中文标点后加一个空格排版用）
      expect(noiseIn('第一句。 第二句'), isEmpty);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ① ★★★ Rust 用户可见文案里不许有噪声字符
  // ─────────────────────────────────────────────────────────────

  test('★★★ CS-1 的 Rust 用户可见文案里没有连续空格/制表符/零宽字符', () {
    final offenders = <String>[];
    var checked = 0;

    for (final path in _cs1RustFiles) {
      final f = File(path);
      if (!f.existsSync()) {
        offenders.add('$path —— 文件不存在（清单腐化）');
        continue;
      }
      for (final lit in chineseLiterals(f.readAsStringSync())) {
        checked++;
        final problems = noiseIn(lit.text);
        if (problems.isEmpty) continue;
        offenders.add(
          '${path.split('/').last}:${lit.line}  [${problems.join(' / ')}]\n'
          '    ${lit.text.length > 80 ? '${lit.text.substring(0, 80)}…' : lit.text}',
        );
      }
    }

    expect(
      checked,
      greaterThan(10),
      reason: '★ 只检查了 $checked 条 ⇒ 提取器漏了东西（本门禁会变假绿）',
    );
    expect(
      offenders,
      isEmpty,
      reason: '★★★ 这些文案会**原样**进界面的 Text（全仓无富文本渲染器）⇒ '
          '中间的连续空格会让用户看到一句话裂开一块空白。\n'
          '修法：删掉多余空格，让界面自己换行。\n\n'
          '${offenders.join('\n')}',
    );
    printOnFailure('[TEXT-GATE] 检查了 $checked 条中文字面量');
  });

  // ─────────────────────────────────────────────────────────────
  // ② ★★★ 凭据同步必须告诉用户「服务端解不开」
  // ─────────────────────────────────────────────────────────────

  test('★★★ 凭据同步的说明里必须说清「服务端/云端解不开」', () {
    /*
     * # 为什么这条是硬要求（不是锦上添花）
     *
     * 用户看到「登录态会同步到云盘」时的**第一反应**是：
     * ```text
     * 「我的账号密码要传到别人的服务器上？」⇒ 不敢开
     * ```
     * 而真实机制是：**本机用你的口令加密**，上传的是密文，
     * 服务端（坚果云/Nextcloud…）拿到也解不开 —— 口令不在包里、不在服务器上。
     *
     * 本轮实测：全仓**没有任何一处**说过这一点。
     * ```text
     * $ grep -n "服务端" lib/ui/widgets/sync_panel.dart backup_panel.dart
     *   （空）
     * 现有文案只说了「加密后才上传」（说了机制的一半：加密）
     * 却没说「谁解不开」（另一半：服务端也不行）
     * ⇒ 用户仍然不知道"我能不能放心用"
     * ```
     * ⇒ 这不是"文案不够漂亮"，是**关键告知缺失**，会直接让用户不用这个功能。
     *
     * # ★★★ 为什么判据是**精确子串**而不是正则（两次假绿换来的）
     *
     * 我先用正则 `(服务端|云端|网盘)[^。]{0,24}(解不开|...)`，**两次都假绿**：
     * ```text
     * 第 1 版命中：「忘记口令 = 云端那份和已导出的备份包都解不开」
     *              主语是"你"（用户自己解不开），不是"服务端"
     * 第 2 版（收紧后）仍然命中同一句 —— 因为"云端"在前、"解不开"在后，
     *              恰好满足"同一句 + 顺序正确"
     * ```
     * ⇒ **正则能表达"顺序"，表达不了"主语"**。用正则判语义，
     *   只要文里恰好有一句"含这两个词"，它就绿 —— 而那句话可能完全是别的意思。
     *
     * ⇒ 改成钉住**那句必须存在的话**（精确子串）。它同时起两个作用：
     *   ① 判据不再能被无关句子满足；
     *   ② 它就是给用户看的那句原文，改文案必须同步改这里（意图明确）。
     */
    final src = File('lib/ui/widgets/sync_panel.dart').readAsStringSync();

    /*
     * 这句必须**逐字**出现在凭据区块的说明里。
     * 措辞要点（三条缺一不可）：
     *   · 上传的是**密文**
     *   · 服务端/网盘**解不开**（点明"谁"解不开）
     *   · 口令**不在**服务器上（解释为什么解不开）
     */
    const mustSay = '上传的是密文，网盘那边解不开（口令不在服务器上）';

    expect(
      src.contains(mustSay),
      isTrue,
      reason: '★★★ 凭据同步的说明必须逐字包含：\n'
          '  「$mustSay」\n'
          '缺这一句，用户会因为"我的密码要传到别人服务器"而不敢开这个功能。\n'
          '⚠️ 不要用正则近似匹配（试过两次，都被'
          '「云端那份…解不开」这句无关文案假绿了）。',
    );
  });

  test('★ 且必须说清「口令不进包/不上传」', () {
    final src = File('lib/ui/widgets/sync_panel.dart').readAsStringSync();
    expect(
      RegExp(r'口令[^。]{0,20}(只存在|不进|不会上传|不上传)').hasMatch(src),
      isTrue,
      reason: '★ 必须说明口令本身不外传（只在本机钥匙串）',
    );
  });

  // ─────────────────────────────────────────────────────────────
  // ③ 反向：必要的警示不许被删掉
  // ─────────────────────────────────────────────────────────────

  test('★★ 必要的警示文案必须还在（防"为了干净而删警示"）', () {
    /*
     * 约束 3：不许为了"看起来干净"删掉必要的警示。
     * 这里把 CS-1 的几条**必须存在**的警示钉住。
     */
    final sync = File('lib/ui/widgets/sync_panel.dart').readAsStringSync();
    final backup = File('lib/ui/widgets/backup_panel.dart').readAsStringSync();

    final mustKeep = <String, String>{
      '忘记口令 ⇒ 不可恢复': '忘记口令时也只能清除后重新设一个（旧包就解不开了）。',
      '明文密码类要单独提示': '账号密码明文',
      '导出前提示含登录态': '这个备份文件含登录态',
      '口令不对 ⇒ 整次导入失败': '整次导入会失败',
    };

    final missing = <String>[];
    for (final e in mustKeep.entries) {
      final all = sync + backup;
      if (!all.contains(e.value)) {
        missing.add('${e.key} —— 期望包含「${e.value}」');
      }
    }
    expect(
      missing,
      isEmpty,
      reason: '★★ 这些警示是用户做决定的前提，不许为了文案整洁删掉：\n'
          '${missing.join('\n')}',
    );
  });
}
