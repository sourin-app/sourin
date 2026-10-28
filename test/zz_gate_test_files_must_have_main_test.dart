// ═══════════════════════════════════════════════════════════════════════
//  结构性守则：`test/zz_*.dart` 必须真的是测试文件（有 main）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这条
// ```text
// `zz_cr_nit_shell_theme_gate.dart` 是**共享门禁实现**（没有 main，被两个测试 import）。
// 它一放进 `test/` 且以 `zz_` 开头，`flutter test` 就会把它当测试文件跑：
//   每次全量都报 `Failed to load: Missing definition of main`，
//   看起来像"有一条红"，其实**一条断言都没在守**。
// 这种"半成品文件混进测试目录"的红最耗人 —— 它永远是红的，且红得没有信息量。
//
// 处置（2026-10-28，Owner：「半成品给补全」）：
//   · 共享件挪到 `test/_support/`（仓库既有约定，如 strip_comments.dart）；
//   · 另加本门禁：`test/zz_*.dart` 里出现没有 main 的文件 ⇒ 红，
//     并在消息里直接给出"该挪到哪"。
// ```
// 注入：放一个 `test/zz_tmp_no_main.dart`（只有 import）⇒ 本条红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('★★ test/zz_*.dart 必须都有 main（共享件放 test/_support/）', () {
    final files = Directory('test')
        .listSync()
        .whereType<File>()
        .map((f) => f.path.replaceAll('\\', '/'))
        .where((p) => p.startsWith('test/zz_') && p.endsWith('.dart'))
        .toList();

    expect(files.length, greaterThan(300),
        reason: '★ 反空真：扫到的 zz_ 测试文件应当有几百个（实际 ${files.length}）');

    final noMain = <String>[];
    for (final p in files) {
      final src = File(p).readAsStringSync();
      final hasMain = RegExp(r'^(void |Future<void> )?main\(', multiLine: true)
              .hasMatch(src) ||
          src.contains('main() async') ||
          RegExp(r'\bmain\(\)\s*\{').hasMatch(src);
      if (!hasMain) noMain.add(p);
    }

    expect(
      noMain,
      isEmpty,
      reason: '★★ 这些 `test/zz_*.dart` 没有 main —— `flutter test` 会把它们当测试跑，'
          '每次全量都报 "Failed to load: Missing definition of main"（一条断言都没守）。\n'
          '处置：共享件挪到 `test/_support/`，测试件补 main。\n  实际：${noMain.join("\n  ")}',
    );
  });
}
