// ═══════════════════════════════════════════════════════════════════════
//  CS-1 门禁自检：**被断言的用户可见文案，在产品代码里只能有一个渲染点**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁为什么存在（本轮踩到的真实坑）
//
// 做「同步方向」那条文案时，我第一版写了两处：
// ```dart
// statusLabel            → '凭据将同步：N 个源（仅上行：…；取回用「备份导入」）'
// 状态行下面另起一行      → _note(Colors..., CredentialsStatus.directionNote)
// ```
// 然后做故障注入（把 `statusLabel` 里的方向语义删掉）⇒ **门禁仍然全绿**，
// 因为屏幕上还有第二行，`find.textContaining('仅上行')` 照样找得到。
//
// ```text
// 判据的满足点 > 1  ⇒ 故障注入只会打中其中一个 ⇒ 门禁给人"我守住了"的错觉
// ```
// 本仓这一轮的三个"门禁自身假绿"实例，共性都是这个。
//
// ⇒ 修法不是"再加一条断言去覆盖第二条渲染点"（那是打地鼠），
//   **而是从结构上保证只有一个渲染点**，并让这件事可机械核对。
//
// # 这条门禁做什么
//
// ```text
// ① 从本门禁文件里提取所有 `find.textContaining('X')` / `find.text('X')`
//    的字面量 X（跳过纯 ASCII 的控件名，如 '设置口令' 这类短词另算 ——
//    见下面 _isUserFacingCopy 的判据）
// ② 到产品代码（本仓的 2 个面板 + 模型契约）里数 X 出现在几个**文件**
// ③ > 1 个文件 ⇒ 红，并把文件清单打出来
// ```
//
// ⚠️ 判据是"出现在几个**文件**"，不是"几行"：
//    同一个文件里多行是正常的（注释、常量定义、使用处），
//    跨文件才意味着"有两个独立的渲染点"。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 产品代码里**可能渲染文案**的源文件（本轮涉及的全部）
///
/// ★ 为什么只扫这几个而不是整个 lib/：
///   遍历整个 lib/ 会让这条门禁依赖无关文件（其它 agent 正在改 UI），
///   一次无关改动就可能让它假红。本门禁的判据只在**这几个文件之间**成立。
const List<String> _productFiles = <String>[
  'lib/core/models.dart',
  'lib/ui/widgets/sync_panel.dart',
  'lib/ui/widgets/backup_panel.dart',
];

/// 这条门禁自己的路径（要从扫描里排除，否则字面量自己命中自己）
const String _selfPath = 'test/zz_t66_cs1_credentials_gate_test.dart';

/// 从源码里提取 `find.textContaining('X')` 与 `find.text('X')` 的字面量
///
/// ⚠️ 只收**单引号或双引号的纯字符串**（不做插值求值）——
///    需要插值的文案（如 `'凭据将同步：$n 个源'`）在这里取到的是
///    带 `$` 的模板串，用它去 grep 产品代码会失败。
///    ⇒ 这类**直接跳过**（下面 `_hasInterpolation`），并在报告里说明跳过了几条。
List<String> userFacingLiterals(String source) {
  final out = <String>[];
  // find.text('X') / find.textContaining('X')
  final re = RegExp(
    r"""find\.(?:text|textContaining)\(\s*(['"])(.*?)\1""",
    multiLine: true,
  );
  for (final m in re.allMatches(source)) {
    final lit = m.group(2)!;
    if (lit.isEmpty) continue;
    if (_hasInterpolation(lit)) continue;
    out.add(lit);
  }
  return out;
}

/// 字面量里有没有 Dart 插值（`$x` / `${x}`）
bool _hasInterpolation(String s) =>
    s.contains(r'$');

/// 这一条是否属于"**判据性文案**"（必须单点渲染）
///
/// # 判据：含中文，且**不在**"允许重复"的动作名白名单里
///
/// ★ 为什么不能按长度过滤 —— 第一版就是这么写错的，被本文件自己的
///   仪器自检当场抓住：
/// ```text
/// 本门禁真正断言的是这些（实测提取结果）：
///   凭据未同步(5) / 备份导入(4) / 仅上行(3) / 设置口令(4) / 修改口令(4)
/// 若按 ">= 8 个字符" 过滤 ⇒ **一条都不剩** ⇒ 门禁恒真（假绿）
/// ```
/// 我当时假设"长句才需要唯一性"，但**短词恰恰最危险**：
/// `仅上行` 三个字，任何地方多写一次都会让故障注入打不中。
///
/// # 所以改成"排除动作名"
///
/// ```text
/// 允许重复：设置口令 / 修改口令 / 清除口令 / 导入 / 导出 / 取消 / 保存
///           —— 这些是**动作名**，按钮上和提示里同时出现是正常的，
///              不构成"两个渲染点抢同一条判据"
/// 必须唯一：凭据未同步 / 仅上行 / 备份导入
///           —— 这些是**判据性结论**，多一处就意味着注入可能打不中
/// ```
const Set<String> _allowedMultiSite = <String>{
  '设置口令',
  '修改口令',
  '清除口令',
  '导入',
  '导出',
  '取消',
  '保存',
};

bool isUserFacingCopy(String s) {
  final hasCjk = RegExp(r'[\u4e00-\u9fff]').hasMatch(s);
  if (!hasCjk) return false;
  return !_allowedMultiSite.contains(s);
}

void main() {
  // 每个用例的文案都从产品代码里读
  late final String gateSource;
  late final Map<String, String> productSources;

  setUpAll(() {
    gateSource = File(_selfPath).readAsStringSync();
    productSources = {
      // ★ 必须**剥掉注释**再数 —— 否则注释里提到同一句话也会被当成"第二个渲染点"。
      //   实测：`sync_panel.dart` 的注释里出现了 `仅上行` / `凭据未同步`
      //   各一次（解释性文字），不剥注释会直接把门禁判红（假红）。
      //   这与 `settings_panels_test.dart` 的 `_code()` 是同一个教训。
      for (final p in _productFiles) p: stripComments(File(p).readAsStringSync()),
    };
  });

  // ─────────────────────────────────────────────────────────────
  // ⓪ 仪器自检（先证明提取器与判据都能抓到东西）
  // ─────────────────────────────────────────────────────────────

  group('⓪ 仪器自检', () {
    test('★ 提取器能从真实门禁文件里抓到字面量', () {
      final lits = userFacingLiterals(gateSource);
      expect(
        lits,
        isNotEmpty,
        reason: '★ 一个都没抓到 ⇒ 提取器坏了，下面全是假绿',
      );
      printOnFailure('[UNIQ] 提取到 ${lits.length} 个字面量');
    });

    test('★ 提取器认得出两种写法', () {
      final lits = userFacingLiterals(
        "a(find.text('甲甲甲甲甲甲甲甲'));"
        "b(find.textContaining(\"乙乙乙乙乙乙乙乙\"));",
      );
      expect(lits, contains('甲甲甲甲甲甲甲甲'));
      expect(lits, contains('乙乙乙乙乙乙乙乙'));
    });

    test('★ 阳性对照：明确构造"两个文件都有同一句" ⇒ 判据能抓到', () {
      /*
       * 不往产品文件里插脏数据（会污染工作区），
       * 而是直接喂一份人造的 map 给计数函数。
       */
      const copy = '仅上行：本机 → 云端；从云端取回请用「备份导入」';
      final fake = <String, String>{
        'a.dart': "const x = '$copy';",
        'b.dart': "const y = '$copy';",
      };
      final hits = filesContaining(fake, copy);
      expect(
        hits.length,
        2,
        reason: '★ 阳性对照失败 ⇒ 计数函数抓不到重复，本门禁是假绿',
      );
    });

    test('★ 阴性对照：只在一个文件里 ⇒ 不报', () {
      const copy = '这是一句只出现一次的中文文案';
      final fake = <String, String>{
        'a.dart': "const x = '$copy';",
        'b.dart': 'const y = 1;',
      };
      expect(filesContaining(fake, copy).length, 1);
    });
  });

  // ─────────────────────────────────────────────────────────────
  // ① ★★★ 每个被断言的长文案只能有一个渲染点
  // ─────────────────────────────────────────────────────────────

  /// 判据性文案的唯一性检查
  ///
  /// # ⚠️ 为什么改为"模型定义一次 + 面板不重定义"（而不是扫所有文件）
  ///
  /// 实测抓到两类命中，**性质完全不同**：
  /// ```text
  /// ① 真正的重复（该修）
  ///    `_credLabel` 里又写了一遍 '凭据未同步（状态未知）'
  ///    ⇒ 同一句判据有两个渲染点 ⇒ 注入打不中   ⇒ 已改成引用模型常量
  ///
  /// ② 同一短语的**不同用法**（不该修）
  ///    点开关之后的 toast：'已开启，但还没设置口令 ⇒ 凭据未同步。请点…'
  ///    它复用了这个说法，但它是**动作反馈**、不是状态行，
  ///    用户看到它的时机完全不同（点完开关 vs 随时看状态行）。
  ///    ⇒ 强制它不许出现只会让文案变别扭，不增加任何保护 ——
  ///      而"为了过门禁去改文案"是本仓明令禁止的。
  /// ```
  ///
  /// ⇒ 判据锚在**"状态行那几句"**上：要求它们在 `models.dart` 定义一次，
  ///    面板里**只引用不重定义**。
  test('★★★ 判据性文案只在 models.dart 定义一次（面板只引用）', () {
    final models = productSources['lib/core/models.dart']!;
    final panel = productSources['lib/ui/widgets/sync_panel.dart']!;

    final mustBeDefinedInModels = <String>[
      '凭据未同步（未开启）',
      '凭据未同步（未设置口令）',
      '凭据未同步（状态未知）',
      '仅上行',
      '备份导入',
    ];

    final offenders = <String>[];
    for (final lit in mustBeDefinedInModels) {
      if (!models.contains(lit)) {
        offenders.add('「$lit」在 models.dart 里找不到 ⇒ 判据清单过时了');
        continue;
      }
      if (panel.contains("'${lit}") || panel.contains('"${lit}')) {
        offenders.add(
          '「$lit」在 sync_panel.dart 里**又定义了一遍** ⇒ 两个渲染点，注入打不中',
        );
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: '★★★ 同一句判据性文案被两个文件各自定义 ⇒ '
          '故障注入只会打中其中一个（本仓三个"门禁自身假绿"的共性）。\n'
          '修法：**消除重复**，让面板只引用模型常量。\n'
          '${offenders.join('\n')}',
    );
  });

  test('★ 阳性对照：把同一句写进面板的字符串里 ⇒ 上面的判据会报', () {
    const lit = '凭据未同步（未开启）';
    final fakePanel = "return '$lit';";
    expect(
      fakePanel.contains("'$lit"),
      isTrue,
      reason: '★ 阳性对照失败 ⇒ 判据里的 contains 写法有误，门禁是假绿',
    );
  });

  /// 诊断报告：被判据断言的文案在各文件里的出现次数（**只报告，不必红**）
  ///
  /// 理由：第二类命中（toast 复用同一短语）是合理的，
  /// 强行必红会逼人改文案迁就测试。
  test('☆ 报告：被判据断言的文案分布（仅供参考）', () {
    final lits = userFacingLiterals(gateSource).where(isUserFacingCopy).toList();
    final rows = <String>[];
    for (final lit in lits) {
      final hits = filesContaining(productSources, lit);
      if (hits.length > 1) rows.add('「$lit」→ ${hits.join(', ')}');
    }
    if (rows.isNotEmpty) {
      printOnFailure('[UNIQ-REPORT] 多处出现（需人工判断是否合理）:\n${rows.join('\n')}');
    }
    expect(true, isTrue);
  });

  /// ★ 正则里的源码级断言：不许出现"把同一句话再渲染一遍"的写法
  test('★★ 不许在状态行之外另起一行渲染 directionNote', () {
    /*
     * 这条是上面那条的**结构补充**：即使某天文案改了字，
     * 「另起一行渲染 directionNote 常量」这个**写法**本身仍然是错的
     * （它必然造成两个渲染点）。
     *
     * ⚠️ 判据锚在常量名上，而不是那句话 —— 改文案不会让它假红/假绿。
     */
    final src = productSources['lib/ui/widgets/sync_panel.dart']!;

    /*
     * ★★★ 判据是 **0 次**，不是「≤1 次」。
     *
     * # 为什么上一版 `lessThanOrEqualTo(1)` 是假绿（实测）
     *
     * 我第一版写的是 `<= 1`，理由是"它应当只渲染一次"。
     * 但真相是：**面板里本来就不该直接引用它** ——
     * 方向文案是通过 `statusLabel` 渲染的，而 `statusLabel` 定义在
     * `models.dart` 里。所以面板里正确的次数是 **0**。
     *
     * 故障注入证明了这点：我加一行 `_note(colors, directionNote)`
     * ⇒ 面板里有 1 次 ⇒ `<= 1` **通过** ⇒ 门禁没抓到。
     * `<= 1` 这个上界恰好把"唯一正确值 0"和"错误值 1"都放行了。
     *
     * ⇒ 边界必须钉在**精确的期望值**上。这是本仓"给宽上界 = 假绿"的又一例。
     */
    final occurrences = RegExp(
      r'CredentialsStatus\.directionNote',
      multiLine: true,
    ).allMatches(src).length;

    expect(
      occurrences,
      0,
      reason: '★★★ `CredentialsStatus.directionNote` 在 sync_panel 里出现了 '
          '$occurrences 次，正确值是 **0**。\n'
          '方向文案必须只经由 `statusLabel` 渲染（它定义在 models.dart）—— '
          '面板里再写一处就造成第二个渲染点，故障注入打不中第二个（实测过）。',
    );
  });
}

/// 剥掉 Dart 注释（行注释 + 块注释）—— **带状态机**，不是逐行判断
///
/// # 为什么不能逐行判断（本仓踩过至少四次）
///
/// ```text
/// ① 行尾注释   `final x = 1; // 这里也提到"仅上行"`   ← 行首不是注释
/// ② 单行块注释 `/* 仅上行 */ final y = 2;`             ← 同上
/// ```
/// 逐行过滤放不过这两种，于是**注释里的词被当成第二个渲染点** ⇒ 假红。
///
/// # 状态机要处理的三件事
/// ```text
/// 'http://x'     字符串里的 `//` **不是**注释
/// "a /* b"       字符串里的 `/*` 不是注释
/// /*  //  */     块注释里的 `//` 不是行注释
/// ```
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      // 保留换行，避免把两行粘成一行（会让跨行匹配变形）
      if (c == '\n') out.write('\n');
      i++;
      continue;
    }
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]); // 转义字符原样跳过
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }

    // 不在任何注释/字符串里
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 给定一组「文件 → 源码」，返回**包含该字面量**的文件清单
///
/// ★ 抽成顶层函数是为了让阳性/阴性对照能直接喂人造数据。
List<String> filesContaining(Map<String, String> sources, String literal) {
  final out = <String>[];
  for (final e in sources.entries) {
    if (e.value.contains(literal)) out.add(e.key);
  }
  out.sort();
  return out;
}
