// ═══════════════════════════════════════════════════════════════════════
//  CS-1 门禁：钉住「flutter test 里中文字宽恒为 12.000/字」
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁的作用**不是防缺陷，是防结论过期**
//
// `docs/notes/evidence/round-66-cs1/README.md` 里写着一条我们自己量化出来的事实：
//
// ```text
// flutter_tester 的中文宽度是**固定 12.000 px/字**，对所有字族相同：
//   Microsoft YaHei UI / Noto Sans CJK SC / Roboto / Ahem / (null)
//   → 全部 12.000/字
// ⇒ loadRealFonts 加载的 msyh.ttc 只让**字形**变成真的，**字宽**仍然是假的
// ```
//
// 这条事实支撑着一个结论：「截图能证明**文字是什么**，不能证明**文字排出来多宽**」。
//
// ★ 如果将来 Flutter 版本升级修了这个行为（某个族真的生效了、宽度不再相同），
//   那么**上面那条结论就过期了** —— 而没有任何东西会告诉你。
//   ⇒ 本门禁就是那个"东西"。
//
// # 它红了意味着什么
//
// ```text
// 不是"代码坏了"，而是：
//   「flutter_tester 的中文字宽不再是等宽，
//     证据 README 与 AGENTS.md 里关于字体差异的结论需要**重新评估**」
// ```
//
// # 为什么用 5 个族 + null
//
// ```text
// 只测一个族不能区分两种情况：
//   ① 「字体没生效」      ⇒ 所有族都落到同一个回退
//   ② 「字体生效了」      ⇒ 该族与回退的宽度**应当不同**
// ⇒ 必须同时有「已加载的族」（雅黑/思源）、「未加载的族」（Roboto/Ahem）、
//   和「完全不指定」（null）。三者宽度若全相同 ⇒ 判定为①。
// ```

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'support/ui_shot.dart';

/// 用来量的中文字符串
///
/// ★ 必须**全汉字**：混入拉丁字母或数字会让它们各自回退，
///   把「中文字宽是否等宽」这个问题污染成「混合文本怎么排版」。
const String _cjkSample = '凭据将同步个源仅上行本机云端从云端取回请用备份导入';

/// flutter_tester 实测的中文字宽（逻辑像素/字）
///
/// ⚠️ 这是个**实测常量**，不是推算。改它之前先跑本文件看真实读数。
const double kTesterCjkAdvance = 12.0;

/// 参与对比的字族
///
/// ```text
/// 'Microsoft YaHei UI' / 'Microsoft YaHei'  ← loadRealFonts 真的去加载了
/// 'Noto Sans CJK SC'                        ← Android 端主题用的族
/// 'Roboto' / 'Ahem'                         ← **没有**被加载（Ahem 是测试默认）
/// null                                      ← 完全不指定
/// ```
const List<String?> _families = <String?>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans CJK SC',
  'Roboto',
  'Ahem',
  null,
];

double _widthOf(String? family, {double fontSize = 12}) {
  final tp = TextPainter(
    text: TextSpan(
      text: _cjkSample,
      style: TextStyle(fontFamily: family, fontSize: fontSize),
    ),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  final w = tp.width;
  tp.dispose();
  return w;
}

void main() {
  setUpAll(loadRealFonts);

  // ─────────────────────────────────────────────────────────────
  // ① ★★★ 中文字宽对**所有**字族都相同（= 等宽 12.000/字）
  // ─────────────────────────────────────────────────────────────

  test('★★★ flutter test 里中文字宽对五个字族全部相同（等宽 12.000/字）', () {
    final n = _cjkSample.characters.length;
    // ignore: avoid_print
    print('[CJK-ADVANCE] 样本 $n 个字');

    final widths = <String, double>{};
    for (final f in _families) {
      final w = _widthOf(f);
      widths[f ?? '(null)'] = w;
      // ignore: avoid_print
      print('[CJK-ADVANCE] family=${f ?? "(null)"}  w=${w.toStringAsFixed(2)}  '
          'perChar=${(w / n).toStringAsFixed(3)}');
    }

    final distinct = widths.values.map((w) => w.toStringAsFixed(3)).toSet();

    /*
     * ★★★ 本门禁的核心断言。
     *
     * 若这条红了，**先别改代码** —— 先读失败信息：
     * ```text
     * 它可能意味着「Flutter 修了 flutter_tester 的字体行为」，
     * 那么 README / AGENTS.md 里关于「字宽是假的」的结论就过期了，
     * 需要重新评估并更新那两处文档。
     * ```
     */
    expect(
      distinct.length,
      1,
      reason: '★★★ flutter_tester 的中文字宽**不再是等宽**了 —— '
          '这不是代码缺陷，是**结论过期信号**：\n'
          '  docs/notes/evidence/round-66-cs1/README.md 里「字体」节\n'
          '  与 AGENTS.md 的「截图里的文字全是方块」那条\n'
          '  都写着「字宽恒为 12.000/字，与字族无关」。\n'
          '  实测各字族宽度: $widths\n'
          '⇒ 请重新评估：现在截图能证明的东西变多了（连字宽也可信了）吗？\n'
          '  若确认变了，同步更新那两处文档 + 本文件的 kTesterCjkAdvance。',
    );
  });

  // ─────────────────────────────────────────────────────────────
  // ② 每字 12.000（把"相同"钉成"等于多少"）
  // ─────────────────────────────────────────────────────────────

  test('★★ 每字宽度 == 12.000（不只是"彼此相同"）', () {
    /*
     * ① 只证明「所有族一样」。若某天全世界的字族都变成 10.0，
     * ① 仍然绿（大家一样），但文档里「12.000」这个数就错了。
     * ⇒ 单独钉住**数值**。
     */
    final n = _cjkSample.characters.length;
    final w = _widthOf('Microsoft YaHei UI');
    final perChar = w / n;

    // ignore: avoid_print
    print('[CJK-ADVANCE] perChar=${perChar.toStringAsFixed(4)} '
        '（期望 $kTesterCjkAdvance）');

    expect(
      perChar,
      closeTo(kTesterCjkAdvance, 0.001),
      reason: '★★ 每字宽度不再是 $kTesterCjkAdvance —— '
          '证据 README 与 AGENTS.md 里引用的这个数需要更新。实际: $perChar',
    );
  });

  // ─────────────────────────────────────────────────────────────
  // ③ 阳性对照：宽度确实随**字号**变化（证明 TextPainter 真的在量）
  // ─────────────────────────────────────────────────────────────

  test('★ 阳性对照：字号变了宽度必须变（证明本探针真的在量宽度）', () {
    /*
     * 若 TextPainter 因为某种原因恒返回 0 或某个常数，
     * 上面两条会"全绿"而毫无意义。
     * ⇒ 用「同一族、不同字号」做对照：宽度必须不同且成比例。
     */
    final w11 = _widthOf('Microsoft YaHei UI', fontSize: 11);
    final w12 = _widthOf('Microsoft YaHei UI', fontSize: 12);
    final w24 = _widthOf('Microsoft YaHei UI', fontSize: 24);

    // ignore: avoid_print
    print('[CJK-CONTROL] fs11=${w11.toStringAsFixed(2)}  '
        'fs12=${w12.toStringAsFixed(2)}  fs24=${w24.toStringAsFixed(2)}');

    expect(w11, lessThan(w12), reason: '★ 字号变大宽度应变大（探针失效？）');
    expect(w24, greaterThan(w12));
    // 12 → 24 应约为两倍（等宽字体下是精确两倍）
    expect(
      w24 / w12,
      closeTo(2.0, 0.01),
      reason: '★ 等宽字体下 24/12 应约为 2.0（实测 ${(w24 / w12).toStringAsFixed(3)}）',
    );
  });

  // ─────────────────────────────────────────────────────────────
  // ④ 空串/纯 ASCII 的对照（说明这条判据只对中文成立）
  // ─────────────────────────────────────────────────────────────

  test('☆ 报告：拉丁字母是否也等宽（诊断，不判红）', () {
    double w(String? f, String s) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontFamily: f, fontSize: 12)),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final v = tp.width;
      tp.dispose();
      return v;
    }

    // ignore: avoid_print
    print('[LATIN] ii   =${w('Microsoft YaHei UI', 'ii').toStringAsFixed(2)}');
    // ignore: avoid_print
    print('[LATIN] WWWW =${w('Microsoft YaHei UI', 'WWWW').toStringAsFixed(2)}');
    // ignore: avoid_print
    print('[LATIN] 中文 =${w('Microsoft YaHei UI', '中文中文').toStringAsFixed(2)}');
  });
}
