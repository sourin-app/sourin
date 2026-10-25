// ═══════════════════════════════════════════════════════════════════════
//  `AppInlineSpinner` 的「钉回退」门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件接替谁
//
// ```text
// `test/t27_w7_spinner_color_test.dart` 的 `kFixedMustHaveColor` 原本钉住
// 「danmaku_settings_dialog.dart 必须仍有带 color 的 CircularProgressIndicator」。
//
// commit `ff54fbe` 把那 4 处迁到了 `AppInlineSpinner`（行内小圈需要描边
// 按 size 按比例缩放 —— Material CPI 做不到：AppLoading 的 stroke 写死 4.0，
// 14px 时描边占直径 28.6%，实测比原来粗 33%）。
// ⇒ 该文件现在 0 处 CPI ⇒ 从那张「钉回退」清单移出（见那边的注释）。
//
// ★ 但「钉回退」的**职责不能丢** —— 本文件就是接过来的那一半：
//   钉住「这 5 处必须仍是 AppInlineSpinner，且 color 原样保留」。
// ```
//
// # 这 5 处是哪 5 处（2026-10-19 迁移时的实测清单）
//
// ```text
//   danmaku_settings_dialog.dart:2099  16px  FilledButton.icon 的 icon 位
//   danmaku_settings_dialog.dart:3654  14px  SwitchListTile 的 trailing 位
//   第 12 项迁移：原搜索行与搜索按钮两处不再属于行内小圈清单。
//   独立搜索页改用在途态整行 LinearProgressIndicator，由下方独立断言守护。
//   settings_page.dart:3821            14px  健康检测行内（color: colors.primary）
// ```
//
// ⚠️ 行号会漂 ⇒ 判据**不锚行号**，只锚「该文件里 AppInlineSpinner 的处数 + 每处都带 color」。
//
// # 为什么「必须带 color」是实质判据
//
// ```text
// 迁移前的 CPI 每一处都显式给了 color（那是 t27_w7 修复的成果：
// 不给 color 会落到 progressIndicatorTheme，深/浅板都不是按真实底色选的 ⇒ 灰圈）。
// 若迁移时把 color 丢了，AppInlineSpinner 会回落到 DefaultTextStyle 的颜色 ——
// 在按钮里可能正好，在 trailing/行内就可能与底色撞 ⇒ **同一个缺陷会回来**。
// ⇒ 这条判据守的就是「换组件时别把 color 丢掉」。
// ```
//
// ⚠️ 纯源码扫描，不挂 native-media，不加载 libmpv。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 迁移后的 5 处所在文件
const List<String> kMigratedFiles = <String>[
  'lib/ui/widgets/danmaku_settings_dialog.dart',
  'lib/ui/settings_page.dart',
];

/// 每个文件应有的 AppInlineSpinner 处数（迁移时实测）
const Map<String, int> kExpectedCount = <String, int>{
  'lib/ui/widgets/danmaku_settings_dialog.dart': 2,
  'lib/ui/settings_page.dart': 1,
};

/// 剥掉 `//` 行注释与 `/* */` 块注释（本仓多处踩过「命中注释」的坑）
String _codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0;
  var inLine = false;
  var inStr = '';
  while (i < src.length) {
    if (inLine) {
      if (src[i] == '\n') {
        inLine = false;
        out.write('\n');
      }
      i++;
      continue;
    }
    if (depth > 0) {
      if (src.startsWith('*/', i)) {
        depth = 0;
        i += 2;
        continue;
      }
      i++;
      continue;
    }
    if (inStr.isNotEmpty) {
      if (src[i] == r'\') {
        out.write(src.substring(i, i + 2 > src.length ? i + 1 : i + 2));
        i += 2;
        continue;
      }
      if (src[i] == inStr) inStr = '';
      out.write(src[i]);
      i++;
      continue;
    }
    if (src.startsWith('//', i)) {
      inLine = true;
      i += 2;
      continue;
    }
    if (src.startsWith('/*', i)) {
      depth = 1;
      i += 2;
      continue;
    }
    if (src[i] == "'" || src[i] == '"') {
      inStr = src[i];
      out.write(src[i]);
      i++;
      continue;
    }
    out.write(src[i]);
    i++;
  }
  return out.toString();
}

/// 取一处 `AppInlineSpinner(` 的完整调用体（按括号配对）
String? _callBodyAt(String code, int start) {
  final open = code.indexOf('(', start);
  if (open < 0) return null;
  var d = 0;
  for (var k = open; k < code.length; k++) {
    if (code[k] == '(') d++;
    if (code[k] == ')') {
      d--;
      if (d == 0) return code.substring(open, k + 1);
    }
  }
  return null;
}

void main() {
  test('搜索页在真实搜索在途态保留整行加载反馈且不回退灰圈', () {
    final code = _codeOnly(File('lib/ui/danmaku_search_page.dart').readAsStringSync());
    expect(RegExp(r'if\s*\(s\.searchLoading\s*\|\|\s*b\.loading\)\s*const\s+LinearProgressIndicator\(').hasMatch(code), isTrue,
        reason: '第12项迁移的是加载反馈形态，不是删除反馈；必须由两渠道真实在途态驱动。�');
    expect(RegExp(r'(?<![A-Za-z0-9_.])CircularProgressIndicator\(').hasMatch(code), isFalse,
        reason: '独立搜索页不得退回未显式配色的灰圈。');
  });

  test('★★★ 现存 3 处行内小圈必须仍是 AppInlineSpinner（钉回退）', () {
    for (final path in kMigratedFiles) {
      final f = File(path);
      expect(f.existsSync(), isTrue,
          reason: '★ 前提：$path 不存在 —— 若文件被改名，本门禁要同步更新');
      final code = _codeOnly(f.readAsStringSync());
      final n = RegExp(r'AppInlineSpinner\(').allMatches(code).length;
      expect(
        n,
        kExpectedCount[path],
        reason: '★★★ $path 里 AppInlineSpinner 的处数不对（实际 $n，应为 '
            '${kExpectedCount[path]}）。\n'
            '★ 少了 ⇒ 有人把这批行内小圈换回去了（换回 CircularProgressIndicator '
            '会让 [[t27_w7]] 那个「灰圈」缺陷回来；换回 AppLoading 会让描边变粗 '
            '33%~67%）。\n'
            '★ 多了 ⇒ 新增了调用点 —— 请同时更新 kExpectedCount 并说明来由。',
      );
    }
  });

  test('★★★ 每一处 AppInlineSpinner 都必须显式给 color（不许丢）', () {
    final missing = <String>[];
    for (final path in kMigratedFiles) {
      final code = _codeOnly(File(path).readAsStringSync());
      for (final m in RegExp(r'AppInlineSpinner\(').allMatches(code)) {
        final body = _callBodyAt(code, m.start);
        if (body == null) continue;
        if (!RegExp(r'\bcolor\s*:').hasMatch(body)) {
          final line = code.substring(0, m.start).split('\n').length;
          missing.add('$path:$line');
        }
      }
    }
    expect(
      missing,
      isEmpty,
      reason: '★★★ 这些 AppInlineSpinner **没给 color**：\n'
          '${missing.map((e) => '  $e').join('\n')}\n'
          '★ 迁移前这 5 处每一处都显式给了 color —— 那是 t27_w7 修复的成果'
          '（不给 color 会落到 progressIndicatorTheme，深/浅板都不是按真实底色'
          '选的 ⇒ 「灰圈」缺陷回来）。\n'
          '★ 修法：补上原来的颜色（danmaku 面板 4 处用 DanmakuTextColors.body，'
          'settings_page 那处用 colors.primary）。',
    );
  });

  test('★★ 那 5 处不许再出现 CircularProgressIndicator（防止换回去）', () {
    for (final path in kMigratedFiles) {
      final code = _codeOnly(File(path).readAsStringSync());
      final n = RegExp(r'(?<![A-Za-z0-9_.])CircularProgressIndicator\(')
          .allMatches(code)
          .length;
      expect(
        n,
        0,
        reason: '★★ $path 里又出现了 $n 处 CircularProgressIndicator。\n'
            '★ 行内小圈应走 AppInlineSpinner（描边按 size 缩放）。\n'
            '★ 若确实需要用 CPI（例如整块 loading），请改 [[t27_w7]] 的'
            ' kFixedMustHaveColor 或本清单，并说明理由。',
      );
    }
  });

  test('★ 阳性对照：扫描器确实能抓到（否则上面三条是空断言）', () {
    const bad = '''
      Widget a = AppInlineSpinner(size: 14);
      Widget b = CircularProgressIndicator(color: x);
    ''';
    final code = _codeOnly(bad);
    expect(RegExp(r'AppInlineSpinner\(').allMatches(code).length, 1,
        reason: '★ 扫描器连合成样本都数不对 ⇒ 上面三条会假绿');
    expect(
      RegExp(r'(?<![A-Za-z0-9_.])CircularProgressIndicator\(')
          .allMatches(code)
          .length,
      1,
      reason: '★ 同上',
    );
    // color 检测：第一处没有 color ⇒ 必须被判「缺 color」
    final bodies = <String>[];
    for (final m in RegExp(r'AppInlineSpinner\(').allMatches(code)) {
      final b = _callBodyAt(code, m.start);
      if (b != null) bodies.add(b);
    }
    expect(bodies, hasLength(1));
    expect(RegExp(r'\bcolor\s*:').hasMatch(bodies.single), isFalse,
        reason: '★ 合成样本 `AppInlineSpinner(size: 14)` 没有 color ⇒ '
            '判定必须为「缺 color」。若这里 true ⇒ 色判据永远通过（假绿）');
  });

  test('★ 剥注释器自检：注释里的 AppInlineSpinner 不许被数进去', () {
    const src = '''
      // AppInlineSpinner(size: 14, color: x)
      /* AppInlineSpinner(size: 16, color: y) */
      Widget real = AppInlineSpinner(size: 14, color: z);
    ''';
    final code = _codeOnly(src);
    expect(RegExp(r'AppInlineSpinner\(').allMatches(code).length, 1,
        reason: '★ 剥注释器失效 ⇒ 上面几条会被注释满足（本仓踩过多次）');
  });
}
