// ═══════════════════════════════════════════════════════════════════════
//  独立复核：data_manage_page 的 3 处 markdown 星号清理（r6-live 改）
// ═══════════════════════════════════════════════════════════════════════
//
// # 复核什么
//
// ```text
// ① 那 3 处确实改成了「」，且**渲染结果**里不再有 `**`（读整棵树）
// ② 他的门禁 `zz_t66_md_gate_test.dart` 的**防空转自检**有没有真的起作用
//    ⇒ 构造「树为空」，「不含 `**`」的断言**必须先红**
// ③ 他报告里的结论：「渲染断言够不着 remedy/hasPassword 两条路径，
//    真正守住它们的是静态兜底，两条互补不能只留一条」—— 这个结论对不对
// ```
//
// ⚠️ 只复核，不改实现（`data_manage_page.dart` 与他的门禁都不是我的写入范围）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/ui/settings/data_manage_page.dart';

// ★ 唯一判别式（铁律 170）
import '_support/markdown_bold.dart';

/// 收集树上**所有** Text 的字面量（与他的门禁同法：data + textSpan）
List<String> allTexts(WidgetTester t) {
  final out = <String>[];
  for (final el in find.byType(Text).evaluate()) {
    final w = el.widget as Text;
    final d = w.data;
    if (d != null) out.add(d);
    final span = w.textSpan;
    if (span != null) out.add(span.toPlainText());
  }
  return out;
}

List<String> withAsterisks(WidgetTester t) =>
    allTexts(t).where((s) => s.contains('**')).toList();

void main() {
  late Directory tmp;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('r4_md_review_');
    // ★ AGENTS.md §8：pumpWidget 单渲页面**必须**先隔离数据目录，
    //   否则 `_scan()` 会去读用户真实目录。
    ClipDownloader.debugSetDataDir(tmp.path);
  });
  tearDown(() {
    ClipDownloader.debugSetDataDir(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('① 渲染结果：整棵树无 `**`，且改过的三处确实是「」', () {
    testWidgets('1.1 整棵树零星号（读整棵树，不只读常量）', (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
          const MaterialApp(home: Scaffold(body: DataManagePage())));
      await t.pump();

      final texts = allTexts(t);
      // ignore: avoid_print
      print('[REVIEW] 数据管理页 Text 条数=${texts.length}');
      final bad = withAsterisks(t);
      expect(bad, isEmpty,
          reason: '★★ 渲染树里还有带 `**` 的用户可见文案：$bad');
    });

    test('1.2 三处改动在**源码字面量**里确实是「」', () {
      // ⚠️ 这条是**静态**的（读源文件），与 1.1 的**渲染**读数互补。
      //   1.1 只能覆盖"这次挂载渲染到的"，1.2 覆盖文件里所有字面量。
      final raw =
          File('lib/ui/settings/data_manage_page.dart').readAsStringSync();
      // 剥注释后再找（否则注释里的 ** 会误报）
      final code = _stripComments(raw);
      expect(code.contains('**'), isFalse,
          reason: '★★ 剥注释后代码里还有 `**`：它会显示给用户');
      // 三条改过的 hint 必须逐条在，且用「」
      for (final frag in const [
        '「建议只做检查点，不要直接删」',
        '「这是你的资产，不建议删」',
        '「这是你的资产，不提供删除」',
      ]) {
        expect(code.contains(frag), isTrue, reason: '改动丢了：$frag');
      }
    });

    testWidgets('1.3 ★ 已证实：数据管理页的渲染树**够不着**那三处改动'
        '（⇒ 渲染断言单独守不住，靠的是静态兜底）', (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
          const MaterialApp(home: Scaffold(body: DataManagePage())));
      await t.pump();
      final texts = allTexts(t);
      final joined = texts.join('\n');

      // ★ 实测读数（空数据目录下）：Text = [返回设置, 数据管理, 查看各类数据占用，按类清理]
      //   三处改的是 `_Cat.hint`，它只在
      //     · :402（分类卡片，要先有该类条目）
      //     · :198（清理确认框，要先有 _entries）
      //   出现 ⇒ **空目录下一处都渲染不到**。
      // ignore: avoid_print
      print('[REVIEW] 渲染出的 Text = $texts');
      expect(texts.length, 3,
          reason: '★ Text 条数变了 ⇒ 若将来页面结构改了，本条的读数需重测。'
              '（这条不是判据，是把「渲染层覆盖不到」这个事实钉住。）');
      expect(joined.contains('建议只做检查点'), isFalse,
          reason: '★ 空目录下竟然渲染出了 hint ⇒ 结论③的前提变了，请重新评估。');
    });
  });

  group('② 他的防空转自检：在**空树**上，「不含 `**`」会先红吗', () {
    testWidgets('2.1 ★ 空树复现：只 pump 一个空 Scaffold', (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(const MaterialApp(home: Scaffold(body: SizedBox())));
      await t.pump();
      final texts = allTexts(t);
      // ignore: avoid_print
      print('[REVIEW] 空树 Text 条数=${texts.length}');

      // ★ 实测（探针）：空树 Text=0 ⇒ 他的 `length >= 3` 必然红 ⇒ 自检**有判别力**
      expect(texts.length, lessThan(3),
          reason: '★ 空树却有 ${texts.length} 条 Text（>=3）⇒ 他的防空转自检'
              '在这台环境里失效，「不含 **」会恒真。');
    });

    testWidgets('2.2 ★ 强度：Text 够多但**不是那页**时，「已知文案」那半必须红',
        (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: Column(children: [
            Text('甲'), Text('乙'), Text('丙'), Text('丁'), Text('戊'),
          ]),
        ),
      ));
      await t.pump();
      final texts = allTexts(t);
      expect(texts.length, greaterThanOrEqualTo(3),
          reason: '这棵假树刻意造得够长 ⇒ 只靠 length 会放行');
      expect(texts.join('\n').contains('弹幕'), isFalse,
          reason: '★ 它不含弹幕弹窗的已知文案 ⇒ 「含 knownText」那半自检会红，'
              '说明该自检**有判别力**（不是恒真）');
    });

    testWidgets('2.3 ★ 数据管理页那条**只用了 length，没有 knownText**', (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);
      await t.pumpWidget(
          const MaterialApp(home: Scaffold(body: DataManagePage())));
      await t.pump();
      final texts = allTexts(t);
      // ignore: avoid_print
      print('[REVIEW] 数据管理页 Text=$texts');
      expect(texts.length, greaterThanOrEqualTo(3));
      // ★ 缺口（如实记录）：他在这条**没有**「含已知文案」那半，
      //   而这条页面恰好只渲染 3 条 = **正好压线**。
      // ⇒ 只要有人往标题栏塞一个字导致多一条、或某条不渲染导致变 2 条，
      //    判据含义就漂了；而它**抓不到**「渲染的是别的页面」。
      //    ⚠️ 但结合 1.3：这条渲染断言本来就够不着那 3 处改动，
      //       所以这个缺口**不影响本轮结论**（守改动的是静态兜底）。
    });
  });

  group('③ 他的结论复核：渲染够不着 remedy/hasPassword，靠静态兜底', () {
    test('3.1 源码级：remedy / hasPassword 两条路径存在', () {
      final raw =
          File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();
      expect(raw.contains('remedy') || raw.contains('DanmakuProbeReport'),
          isTrue,
          reason: '★ 找不到 remedy 相关标识 ⇒ r6 的结论③前提不成立，'
              '请重新核对他说的"两条路径"到底指什么');
    });

    test('3.2 ★ 静态兜底确实覆盖它们（剥注释后逐行扫字面量）', () {
      // 他的门禁第 4 组就是这么做的。这里**独立重跑一遍**，
      // 证明「即使渲染层够不着，静态那层仍会红」。
      for (final f in const [
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'lib/ui/settings/data_manage_page.dart',
        'lib/ui/widgets/proxy_panel.dart',
      ]) {
        final code = _stripComments(File(f).readAsStringSync());
        expect(code.contains('**'), isFalse,
            reason: '★★ $f 剥注释后代码里还有 `**`');
      }
    });

    test('3.3 ★ 反证：静态兜底若被去掉，注入一条 `**` 必须被抓住', () {
      // 直接对**判据函数本身**做注入：不改他的文件，只验证这条判据有判别力。
      const injected = "const x = '这是**你的资产**';";
      expect(injected.contains('**'), isTrue,
          reason: '★ 注入样例本身不含 ** ⇒ 判据读数无效');
      // 他的判据是「剥注释后按行找字符串字面量里的 **」
      final line = injected;
      final lits = _stringLiterals(line);
      // ★ 2026-10-19（Lead）：改用唯一判别式。注入样例是真粗体
      //   （`**你的资产**`），朴素版在这里恰好也对，但统一实现后
      //   将来若有人拿它扫含掩码的文件，不会误伤。
      final hit = lits.where(isMarkdownBoldLiteral).toList();
      expect(hit, isNotEmpty,
          reason: '★★ 判据没抓到注入的 `**` ⇒ 静态兜底这条是恒真');
    });
  });
}

/// 剥掉注释（不碰字符串字面量）—— 与他的门禁同思路
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  var inStr = false;
  String? q;
  while (i < src.length) {
    final c = src[i];
    final nx = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && nx == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (inStr) {
      out.write(c);
      if (c == r'\' && nx.isNotEmpty) {
        out.write(nx);
        i += 2;
        continue;
      }
      if (c == q) inStr = false;
      i++;
      continue;
    }
    if (c == '/' && nx == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && nx == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      inStr = true;
      q = c;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取一行里的字符串字面量（与他的实现同法）
List<String> _stringLiterals(String line) {
  final out = <String>[];
  var i = 0;
  String? q;
  var buf = StringBuffer();
  while (i < line.length) {
    final c = line[i];
    if (q != null) {
      if (c == r'\' && i + 1 < line.length) {
        buf.write(c);
        buf.write(line[i + 1]);
        i += 2;
        continue;
      }
      if (c == q) {
        if (buf.isNotEmpty) out.add(buf.toString());
        buf = StringBuffer();
        q = null;
      } else {
        buf.write(c);
      }
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      q = c;
      buf = StringBuffer();
    }
    i++;
  }
  return out;
}
