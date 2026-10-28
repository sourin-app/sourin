// ═══════════════════════════════════════════════════════════════════════
//  共享门禁 `_support/shell_theme_gate.dart` 自己的门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这条要存在
// ```text
// `_support/shell_theme_gate.dart` 是「shell.dart 主题绑定」这条纪律的**唯一实现**，
// 被 `theme_regression_test.dart` 与 `zz_cr_nit_theme_gate_not_false_test.dart` 共用。
// 但**没有人测过它自己**：
//   · 正则写错（比如少一个 `,`）⇒ 两个消费者一起静默变宽/变窄；
//   · 忘记剥注释 ⇒ 又回到"守注释"的假门禁。
// 所以这里用**人造源码**把它的三种行为钉住（不需要真 lib/shell.dart）：
//   ① 只有注释里出现 ⇒ **不许**通过（这正是 2026-10 那次假门禁的病）；
//   ② 真实代码里 MaterialApp.theme 形态 ⇒ 通过；
//   ③ 真实代码里 AppThemeHost 注入形态（M4 之后的产品根）⇒ 通过。
// 另外把"被测真源"也真跑一遍：`lib/shell.dart` 现在必须过（否则门禁与产品脱节）。
// ```
// 注入：把 `_support/shell_theme_gate.dart` 里的 `stripComments(rawSource)`
//      改回 `rawSource` ⇒ ① 红（注释里的形态也被当成通过）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/shell_theme_gate.dart';

void main() {
  group('shell 主题绑定门禁（共享实现）', () {
    test('① 只有**注释**里出现绑定形态 ⇒ 不许通过（假门禁的病灶）', () {
      const onlyInComments = '''
// 曾经这样写过：
//   final materialTheme = AppTheme.themeFor(brightness);
//   MaterialApp(theme: materialTheme,)
//
/* 或者块注释里：
   final materialTheme = AppTheme.themeFor(brightness);
   AppThemeHost(data: materialTheme,)
*/
void nothingHere() {}
''';
      expect(
        shellThemeBindingHasMatch(onlyInComments),
        isFalse,
        reason: '★★ 只在注释里出现不算绑定 —— 这正是 2026-10 那次"守注释"的假门禁',
      );
    });

    test('② 真实代码里的 MaterialApp.theme 形态 ⇒ 通过（M4 之前）', () {
      const code = '''
Widget build(BuildContext c) {
  final materialTheme = AppTheme.themeFor(brightness);
  return MaterialApp(theme: materialTheme, home: const X());
}
''';
      expect(shellThemeBindingHasMatch(code), isTrue);
    });

    test('③ 真实代码里的 AppThemeHost 注入形态 ⇒ 通过（M4 之后的产品根）', () {
      const code = '''
Widget build(BuildContext c) {
  final materialTheme = AppTheme.themeFor(brightness);
  return WidgetsApp(
    builder: (ctx, child) => AppThemeHost(data: materialTheme, child: child!),
  );
}
''';
      expect(shellThemeBindingHasMatch(code), isTrue);
    });

    test('④ 两者都没有（只算了 theme 但没挂上去）⇒ 不许通过', () {
      const code = '''
Widget build(BuildContext c) {
  final materialTheme = AppTheme.themeFor(brightness);
  return WidgetsApp(builder: (ctx, child) => child!);
}
''';
      expect(shellThemeBindingHasMatch(code), isFalse,
          reason: '★ 算了主题却没交给任何宿主，等于没绑');
    });

    test('⑤ 裸 `toApproximateMaterialTheme()` 的行号扫描（剥注释后）', () {
      const code = '''
void a() {
  // 注释里的 toApproximateMaterialTheme() 不算
  final x = toApproximateMaterialTheme();
}
''';
      final hits = bareApproximateMaterialThemeLines(code);
      expect(hits.length, 1, reason: '★ 注释里那处必须被剥掉，只留真实代码那一行');
      expect(hits.single.contains('final x'), isTrue);
    });

    test('⑥ 真源：lib/shell.dart 现在必须真的通过这些判据', () {
      final src = File('lib/shell.dart').readAsStringSync();
      expect(shellThemeBindingHasMatch(src), isTrue,
          reason: '★★ 产品根必须把 AppTheme.themeFor(brightness) 的结果交给主题宿主；'
              '这条红了要么产品脱钩、要么判据停在迁移前');
      expect(bareApproximateMaterialThemeLines(src), isEmpty,
          reason: '★ 产品代码里不许出现裸 toApproximateMaterialTheme()（走 AppTheme 的那条路）');
    });
  });
}
