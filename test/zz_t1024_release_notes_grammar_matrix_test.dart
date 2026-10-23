// 门禁：**语法覆盖矩阵** —— 每种 Markdown 写法要么被人工稿校验拒掉，
//       要么被渲染器正确消化。不许出现「校验放行 + 渲染时把标记漏给用户」。
//
// # 为什么需要它（2026-10-22 / 2026-10-23 连续两次同一个失效面）
//
// 客户端自己渲染更新说明（`lib/ui/widgets/release_notes.dart`），认的形态很少：
// 行首只有 `#` 标题、`-`/`*`/`序号.` 列表、其余当段落；行内只认 `**粗**`、
// 反引号、`[文字](地址)`。**别的语法不报错、原样显示。**
//
// 于是「不支持的语法」必须由写稿那一侧拦。但这条边界由**两份**判据共同决定：
//
//   · Python `validate_manual_notes()` —— 拦哪些写法不许进稿子
//   · Dart `buildReleaseNotes()`       —— 认哪些写法、别的怎么显示
//
// 两份各自演化 ⇒ 曾经漏过两次：
//   ① 2026-10-22：注释与分隔线，渲染器当正文画出来（线上 rc3 就带着 26 行注释）
//   ② 2026-10-23：引用块 / 删除线 / 下划线粗体，校验没拦、渲染器也不认
//
// 两次都是「加了一条判据」，两次都留着下一格没钉。真正缺的不是又一条判据，
// 而是**把两份判据的对账做成可执行的事**：
//
//   每一种写法 → 跑真校验 → 若放行，就用真渲染器渲染，断言标记没漏出来
//
// 新写法的处置因此变成机械的：加一行到这个矩阵里，测试立刻告诉你它现在
// 属于「已被拒」还是「已渲染干净」还是**两边都没管**（第三种会红）。
//
// # 为什么断言里必须有阳性对照
//
// 「渲染结果里没有 `|`」可以被「渲染器把整段丢了」满足 —— 那是假绿。
// 所以每条被放行的写法都同时断言**哨兵文字确实渲染出来了**。
//
// ★ 本门禁不规定实现方式：修法可以是「校验拒掉」，也可以是「渲染器支持」，
//   甚至将来「换成通用解析器」—— 只要不留「放行且泄漏」这一格。

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/release_notes.dart';

/// 找可用的 python（macOS 只有 python3，Windows 上可能是 python / py）。
String? findPython() {
  for (final exe in <String>['python', 'python3', 'py']) {
    try {
      if (Process.runSync(exe, <String>['-c', 'print(1)']).exitCode == 0) {
        return exe;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

/// 跑一次生成器的人工稿校验，返回退出码与 stderr。
ProcessResult runValidator(String py, File file) {
  return Process.runSync(
    py,
    <String>[
      'tools/gen_release_notes.py',
      '--manual',
      file.path,
      '--out',
      '${file.parent.path}/out.md',
    ],
    workingDirectory: Directory.current.path,
    stdoutEncoding: const Utf8Codec(),
    stderrEncoding: const Utf8Codec(),
  );
}

/// 把渲染结果里的**纯文本**全抓出来（含 Text.rich 的各个 span）。
List<String> renderedTexts(List<Widget> widgets) {
  final out = <String>[];
  void visit(Widget w) {
    if (w is Text) {
      final d = w.data;
      if (d != null) out.add(d);
      final span = w.textSpan;
      if (span != null) out.add(span.toPlainText());
      return;
    }
    if (w is Padding) {
      final child = w.child;
      if (child != null) visit(child);
      return;
    }
    if (w is Row) {
      for (final c in w.children) {
        visit(c);
      }
      return;
    }
    if (w is Expanded) {
      // Expanded.child 在 Flutter 的类型里非空（判空会被 analyzer 报恒真）。
      visit(w.child);
    }
  }

  for (final w in widgets) {
    visit(w);
  }
  return out;
}

/// 矩阵里的一格：一种写法 + 它在渲染结果里**绝不许可出现**的标记。
class Construct {
  const Construct({
    required this.name,
    required this.body,
    required this.leakMarkers,
  });

  /// 写法名字（报错时人读的）。
  final String name;

  /// 完整的稿子正文（都带哨兵文字「哨兵」与合法的 `### 修复` 小标题）。
  final String body;

  /// 渲染结果里一旦出现就说明「标记漏给用户了」的片段。
  final List<String> leakMarkers;
}

const List<Construct> matrix = <Construct>[
  Construct(
    name: '标题',
    body: '### 修复\n\n- 哨兵一条。\n\n## 二级哨兵\n',
    leakMarkers: <String>['##'],
  ),
  Construct(
    name: '短横列表',
    body: '### 修复\n\n- 哨兵一条。\n',
    leakMarkers: <String>['- '],
  ),
  Construct(
    name: '星号列表',
    body: '### 修复\n\n* 哨兵一条。\n',
    leakMarkers: <String>['* '],
  ),
  Construct(
    name: '有序列表',
    body: '### 修复\n\n- 哨兵一条。\n3. 哨兵第二条。\n',
    leakMarkers: <String>['3.'],
  ),
  Construct(
    name: '双星号粗体',
    body: '### 修复\n\n- **哨兵**加粗。\n',
    leakMarkers: <String>['**'],
  ),
  Construct(
    name: '行内反引号',
    body: '### 修复\n\n- 设置里搜 `哨兵` 即可。\n',
    leakMarkers: <String>['`'],
  ),
  Construct(
    name: '链接',
    body: '### 修复\n\n- 见 [哨兵](https://example.com/a)。\n',
    leakMarkers: <String>['](', 'https://'],
  ),
  Construct(
    name: '表格',
    body: '### 修复\n\n- 哨兵一条。\n\n| 哨兵 | 乙 |\n| --- | --- |\n| 1 | 2 |\n',
    leakMarkers: <String>['|'],
  ),
  Construct(
    name: '图片',
    body: '### 修复\n\n- ![哨兵](pic.png)\n',
    leakMarkers: <String>['![', 'pic.png'],
  ),
  Construct(
    name: '引用块',
    body: '### 修复\n\n- 一条说明。\n\n> 哨兵引用。\n',
    leakMarkers: <String>['> '],
  ),
  Construct(
    name: '删除线',
    body: '### 修复\n\n- ~~哨兵~~ 新说明。\n',
    leakMarkers: <String>['~~'],
  ),
  Construct(
    name: '下划线粗体',
    body: '### 修复\n\n- __哨兵__ 重点。\n',
    leakMarkers: <String>['__'],
  ),
  Construct(
    name: 'HTML 标签',
    body: '### 修复\n\n- <b>哨兵</b> 粗体。\n',
    leakMarkers: <String>['<b>', '</b>'],
  ),
  Construct(
    name: '围栏代码块',
    body: '### 修复\n\n- 哨兵一条。\n\n```text\n哨兵\n```\n',
    leakMarkers: <String>['```', 'text\n'],
  ),
  Construct(
    name: '分隔线',
    body: '### 修复\n\n- 一条说明。\n\n---\n\n- 另一条。\n',
    leakMarkers: <String>['---'],
  ),
  Construct(
    name: '占位符残留',
    body: '### 修复\n\n- 哨兵 {{CHANGELOG}} 残留。\n',
    leakMarkers: <String>['{{', '}}'],
  ),
  Construct(
    name: 'Setext 标题',
    body: '### 修复\n\n- 哨兵一条。\n\n哨兵标题\n====\n',
    leakMarkers: <String>['===='],
  ),
];

void main() {
  final py = findPython();

  test('语法矩阵：放行的写法不许把标记漏给用户', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无法判定校验放不放行');
      return;
    }

    final tmpDir = Directory.systemTemp.createTempSync('sourin_matrix');
    final accepted = <String>[];
    final rejected = <String>[];
    try {
      for (final c in matrix) {
        final f = File('${tmpDir.path}/${c.name}.md');
        f.writeAsStringSync(c.body);
        final r = runValidator(py, f);

        if (r.exitCode != 0) {
          rejected.add(c.name);
          // 被拒是合法归宿 —— 但要拒得**说得出原因**，不能靠崩溃。
          expect(r.stderr.toString().trim(), isNotEmpty,
              reason: '「${c.name}」被拒了但 stderr 是空的 ⇒ 说不出为什么，等于没有报错。');
          continue;
        }

        accepted.add(c.name);
        final joined = renderedTexts(buildReleaseNotes(c.body)).join('\n');

        // 阳性对照：渲染器确实把这段文字画出来了（否则「没漏标记」是空的）。
        expect(joined, contains('哨兵'),
            reason: '「${c.name}」被校验放行、但渲染结果里连哨兵文字都没有 ⇒ '
                '这一段是被整段丢掉了。本条断言的「没漏标记」因此毫无意义，先修这个。');

        for (final marker in c.leakMarkers) {
          expect(joined, isNot(contains(marker)),
              reason: '「${c.name}」被人工稿校验放行了，但渲染器把「$marker」原样'
                  '显示给用户 ⇒ 两处判据都没管这一格。'
                  '要么在校验里拒掉它（tools/gen_release_notes.py 的 '
                  'validate_manual_notes），要么让渲染器认识它'
                  '（lib/ui/widgets/release_notes.dart）—— 二者都不做就会漏到用户面前。');
        }
      }
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }

    // 矩阵本身要有效力：全被拒或全放行都说明这个矩阵没在测边界。
    expect(accepted, isNotEmpty,
        reason: '矩阵里的写法全被拒了 ⇒ 没有一格在验「放行之后渲染得对不对」，'
            '这条门禁退化成「校验很严」的自证。');
    expect(rejected, isNotEmpty,
        reason: '矩阵里的写法全被放行了 ⇒ 校验对渲染器不支持的语法完全无感。');
    // 把结论打到日志里，方便下次加写法时看现状（不参与断言）。
    // ignore: avoid_print
    print('[grammar-matrix] 放行 $accepted\n[grammar-matrix] 已拒 $rejected');
  });
}
