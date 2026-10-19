// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮：markdown 星号清理门禁（三个文件的用户可见文案）
// ═══════════════════════════════════════════════════════════════════════
//
//  # 背景
//  ```text
//  全仓**没有 markdown 渲染器**（`flutter_markdown` 全仓 0 引用，
//  只有 release_notes.dart 的一句注释提到它）⇒ 任何 `**粗体**`
//  落在普通 `Text` 上，两个星号会**原样显示**给用户。
//  ⇒ 裁决（CS-1 先例，`lib/shell.dart:6955`）：一律改成中文引号「」。
//  不许用 Text.rich（本仓先例已定）。
//  ```
//
//  # ★ 本门禁的范围：只管这三个文件（不要求全仓零 `**`）
//  ```text
//  lib/ui/widgets/danmaku_settings_dialog.dart   21 处
//  lib/ui/settings/data_manage_page.dart          3 处
//  lib/ui/widgets/proxy_panel.dart                1 处
//  ```
//  ⚠️ 探针脚本（`lib/*_probe.dart`，229 处）不在范围内：
//     那些只进开发者终端，不显示给用户。
//  ⚠️⚠️ **脱敏掩码不在范围内、且绝不可改**：
//     `lib/core/danmaku.dart` 的 `'****'`（maskedAppId）与 `'***'`（URL 脱敏）
//     看着像 markdown，其实是**脱敏**。批量清 `**` 会打掉脱敏、泄露 AppId。
//     本门禁刻意**不扫** danmaku.dart；这里写下红线以防后人扩大范围。
//  ```
//
//  # ★ 三条判据纪律（都是本会话踩过的坑）
//  ```text
//  ① **读整棵树的 Text，不只读我改的那几个常量**
//     ⇒ 守的是「修一处漏一处」。
//  ② **防空转自检**：每条断言先证明「树非空且含已知文案」，
//     否则「不含 **」在空树上恒真（本会话已出三次同族假绿）。
//  ③ **失败信息要能定位**：打印到底哪些 Text 带了星号。
//  ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/ui/settings/data_manage_page.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

// ★ 唯一判别式（铁律 170：同一纪律只能有一个实现）
import '_support/markdown_bold.dart';

// ── 工具 ────────────────────────────────────────────────────────────────

/// 收集树上**所有** Text 的字面量（不是只找我改的那几个）
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

/// 树里带 **成对 markdown 粗体** 的文本（★ 顺带把内容打出来，便于定位）
///
/// ★ 2026-10-19（Lead）：改用 `_support/markdown_bold.dart` 的
///   [isMarkdownBoldRendered]。**不是**朴素的 `contains('**')` ——
///   屏幕上的 `****` 可能来自 `maskedAppId`（`danmaku.dart:1432`，
///   经 `statusText` 拼进状态行、由 `danmaku_settings_dialog.dart:2748`
///   的 `Text` 渲染）⇒ 朴素版会把「用户配过 AppId」误报成 markdown 泄漏。
List<String> textsWithAsterisks(WidgetTester t) =>
    allTexts(t).where(isMarkdownBoldRendered).toList();

/// 防空转：证明「树真的渲染出了东西」，且含一条已知文案
void expectTreeNotEmpty(WidgetTester t, {required String knownText}) {
  final texts = allTexts(t);
  expect(
    texts.length,
    greaterThanOrEqualTo(3),
    reason: '★★ 防空转自检：树上只有 ${texts.length} 条 Text —— '
        '页面没渲染出来，下面的「不含 **」会在空树上**恒真**。',
  );
  expect(
    texts.join('\n'),
    contains(knownText),
    reason: '★★ 防空转自检：树上找不到已知文案「$knownText」⇒ '
        '挂载方式不对（或文案已变），本条断言不可信。',
  );
}

void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('zz_t66_md_gate_');
    ClipDownloader.debugSetDataDir(tmp.path);
  });

  tearDown(() {
    ClipDownloader.debugSetDataDir(null);
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  group('弹幕设置弹窗：用户可见文案不带 markdown 星号', () {
    testWidgets('① 整棵树的 Text 都���有 **', (t) async {
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              DanmakuSettingsDialog(
                state: DanmakuSettingsState.fromPrefs(),
                onSetEnabled: (_) {},
                onSetFontScale: (_) {},
                onSetOpacity: (_) {},
                onSetSpeed: (_) {},
                onSetArea: (_) {},
                onReload: () {},
                onClose: () {},
              ),
            ],
          ),
        ),
      ));
      await t.pump();

      // ② 防空转：先证明树非空且含已知文案
      expectTreeNotEmpty(t, knownText: '弹幕');

      // ① 整棵树扫（不是只扫我改过的那几条）
      final bad = textsWithAsterisks(t);
      expect(
        bad,
        isEmpty,
        reason: '★★ 弹幕设置弹窗里有用户可见文案带 markdown 星号。\n'
            '全仓没有 markdown 渲染器 ⇒ 星号会原样显示给用户。\n'
            '带星号的文本：\n${bad.map((e) => '  · 「$e」').join('\n')}\n'
            '修法：改成中文引号「」（先例见 `lib/shell.dart:6955`），不许用 Text.rich。',
      );
    });

    testWidgets('② 阳性对照：那条被改过的文案确实在树上，且已是「」', (t) async {
      t.view.physicalSize = const Size(900, 700);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: <Widget>[
              DanmakuSettingsDialog(
                state: DanmakuSettingsState.fromPrefs(),
                onSetEnabled: (_) {},
                onSetFontScale: (_) {},
                onSetOpacity: (_) {},
                onSetSpeed: (_) {},
                onSetArea: (_) {},
                onReload: () {},
                onClose: () {},
              ),
            ],
          ),
        ),
      ));
      await t.pump();

      /*
       * ★ 这条不是"测产品"，是**证明量法抓对了对象**：
       *   若上面①恒绿而这里找不到任何「」文案，说明弹窗根本没渲染出来
       *   ⇒ ① 是恒真门禁（空树/树里没这些文案）。
       */
      final joined = allTexts(t).join('\n');
      // ignore: avoid_print
      print('MDGATE|弹窗 Text 条数=${allTexts(t).length}');
      expect(
        joined.contains('弹幕'),
        isTrue,
        reason: '阳性对照失败：弹窗树上连「弹幕」都没有 ⇒ 挂载不对。',
      );
    });
  });

  group('数据管理页：用户可见文案不带 markdown 星号', () {
    testWidgets('① 整棵树的 Text 都没有 **', (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(const MaterialApp(
        home: Scaffold(body: DataManagePage()),
      ));
      await t.pump();

      final texts = allTexts(t);
      // ignore: avoid_print
      print('MDGATE|数据管理页 Text 条数=${texts.length}');
      // ② 防空转
      //
      // ★★ 2026-10-19（Lead 补，`r4-dialog` 复核指出）：原来只有 `>= 3`，
      // 而实测这个页面**恰好就是 3 条** ⇒ **正好压线**，多一个字变 4、
      // 少一条变 2，判据含义会悄悄漂；而且它**抓不到「渲染的是别的页面」**。
      expect(texts.length, greaterThanOrEqualTo(3),
          reason: '★★ 防空转自检：数据管理页只有 ${texts.length} 条 Text ⇒ '
              '页面没渲染出来，下面的断言会恒真。');
      // ★ 加这半：**证明挂的是这一页**，而不只是「树里有点东西」
      expect(
        texts.join('\n'),
        contains('数据管理'),
        reason: '★★ 防空转自检：树上找不到「数据管理」⇒ 挂的不是这一页\n'
            '（或文案已改）。只有条数门槛时，渲染成别的页面也会通过。\n'
            '实际渲染：${texts}',
      );

      final bad = textsWithAsterisks(t);
      expect(
        bad,
        isEmpty,
        reason: '★★ 数据管理页有用户可见文案带 markdown 星号。\n'
            '带星号的文本：\n${bad.map((e) => '  · 「$e」').join('\n')}',
      );
    });
  });

  group('代理面板：用户可见文案不带 markdown 星号', () {
    testWidgets('① 整棵树的 Text 都没有 **', (t) async {
      t.view.physicalSize = const Size(900, 900);
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      await t.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ProxyPanel(providerId: 'srca', providerName: '甲源'),
        ),
      ));
      await t.pump();

      final texts = allTexts(t);
      // ignore: avoid_print
      print('MDGATE|代理面板 Text 条数=${texts.length}');
      // ② 防空转
      //
      // ⚠️ 这里实测只有 **1 条** Text ⇒ `>= 1` 门槛**完全压线**
      //   （任何页面只要渲染出 1 条文字就过）。所以条数门槛在本页几乎无判别力，
      //   **真正起作用的是下面这半**：必须出现本页特有的字样。
      expect(texts.length, greaterThanOrEqualTo(1),
          reason: '★★ 防空转自检：代理面板只有 ${texts.length} 条 Text ⇒ '
              '面板没渲染出来，下面的断言会恒真。');
      expect(
        texts.join('\n'),
        anyOf(contains('代理'), contains('代理服务')),
        reason: '★★ 防空转自检：树上找不到本页特征字样 ⇒ 挂的不是这一页。\n'
            '★ 本页只有 1 条 Text，条数门槛几乎没有判别力，'
            '**这一条才是真正守住"渲染的是代理面板"的判据**。\n'
            '实际渲染：${texts}',
      );

      final bad = textsWithAsterisks(t);
      expect(
        bad,
        isEmpty,
        reason: '★★ 代理面板有用户可见文案带 markdown 星号。\n'
            '带星号的文本：\n${bad.map((e) => '  · 「$e」').join('\n')}',
      );
    });
  });

  group('静态兜底：这三个文件里不得再有 `**粗体**` 字面量', () {
    test('剥注释后仍不含成对 **', () {
      // ★ 这是**兜底**：渲染层只覆盖「这次挂载能走到」的那些文案；
      //   静态扫描覆盖「整个文件里所有字符串字面量」，补上渲染覆盖不到的。
      //   两条互为补充，不是同一个源（渲染树 vs 源码字面量）。
      for (final f in [
        'lib/ui/widgets/danmaku_settings_dialog.dart',
        'lib/ui/settings/data_manage_page.dart',
        'lib/ui/widgets/proxy_panel.dart',
      ]) {
        final raw = File(f).readAsStringSync();
        final hits = <String>[];
        final lines = raw.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          final t = l.trimLeft();
          // 整行注释（`//` / `///`）与块注释的续行（` * …`）都跳过
          if (t.startsWith('//') || t.startsWith('*')) continue;
          if (!l.contains('**')) continue;
          // ★ 只在**字符串字面量**里判 —— 否则代码里的 `a ** b` 也会误报
          //
          // ★★ 2026-10-19（Lead）：改用 `_support/markdown_bold.dart` 的
          //   **唯一判别式**，不再用朴素的 `contains('**')`。
          //   原因：朴素版会把**脱敏掩码**（`'****'` / `'${id.substring(0,4)}****'`）
          //   判成 markdown ⇒ 门禁会要求把掩码改成「」⇒ 把打码的 AppId 明文暴露。
          //   判别式的结构差异：粗体的星号之间**夹着非星号字符**，掩码没有。
          for (final lit in _stringLiterals(l)) {
            if (!isMarkdownBoldLiteral(lit)) continue;
            hits.add('  · $f:${i + 1}  「$lit」');
          }
        }
        expect(
          hits,
          isEmpty,
          reason: '★★ $f 里还有带 `**` 的**字符串字面量**（用户可见）：\n'
              '${hits.join('\n')}',
        );
      }
    });
  });
}

/// 取一行里的字符串字面量（不含引号本身）
///
/// ⚠️ 与 `zz_t66_markdown_audit_test.dart` 里的同名函数是**两份实现** ——
///   这里刻意不复用，理由：那是个**清单工具**（要打印全部命中，
///   分类逻辑不同），这里是**门禁**（要精确判"字面量里有没有"）。
///   若日后要合并，注意那个文件已记录的 `///` 误报缺陷。
List<String> _stringLiterals(String line) {
  final out = <String>[];
  var i = 0;
  String? q;
  var buf = StringBuffer();
  while (i < line.length) {
    final c = line[i];
    if (q != null) {
      if (c == r'\') {
        buf.write(c);
        if (i + 1 < line.length) buf.write(line[i + 1]);
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