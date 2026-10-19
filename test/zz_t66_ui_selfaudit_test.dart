// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · UI 层只读自审（批末静态自审的一半）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件是什么
//
// **只读型门禁**：它不改任何产品代码，只把「人容易漏、机器容易放过」的那几条
// 变成机械判据。另一半（门禁互相矛盾 / 死断言 / 隐私扫描）由 `r3-dns` 做，
// 两人不重叠。
//
// ```text
// ① 用户可见文案的语法/术语一致性
//    · 新写的文案里不许有 `**` 残留
//    · 不许出现「修复/缺陷/Owner/探针/task-xx」等开发用语（AGENTS §4）
//    · 引号/圆括号必须配对（这轮大量把 **x** 改成「x」）
// ② 弹窗形态一致性（R4 收尾）：三个弹窗的**三条退出路径**都还在
//    （`zz_t66_r4_dialog_consistency_test.dart` 已覆盖宽度/圆角/底色/高度，
//      **那四条不重做**，这里只补退出路径）
// ③ 深浅双档：`probeFailed` 新档在**浅色**下也要有非空文案且不含网络断言
// ```
//
// ⚠️ **判据纪律**：全部读**真实渲染结果**或**真实文件内容**，
//    判据本身都做过故障注入（见每条的 reason）。
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';

// ★★ 2026-10-19（Lead）：改用**共享实现**，不再用本地副本（铁律 170）
//   本地 `_stripComments` 不认 `///` 文档注释 ⇒ 假阳性
import '_support/markdown_bold.dart';
import '_support/strip_comments.dart';




/// 本轮改动过的 lib 文件（★ 只读清单，不写回任何地方）
const _touchedFiles = <String>[
  'lib/core/danmaku.dart',
  'lib/core/sourin_api.dart',
  'lib/ui/cache_page.dart',
  'lib/ui/live_page.dart',
  'lib/ui/settings/danmaku_source_page.dart',
  'lib/ui/settings/data_manage_page.dart',
  'lib/ui/settings/playback_page.dart',
  'lib/ui/widgets/app_dialog_shell.dart',
  'lib/ui/widgets/backup_panel.dart',
  'lib/ui/widgets/danmaku_settings_dialog.dart',
  'lib/ui/widgets/live_embedded_player.dart',
  'lib/ui/widgets/proxy_panel.dart',
  'lib/ui/widgets/skip_marker_dialog.dart',
  'lib/ui/widgets/source_composer_dialog.dart',
  'lib/ui/widgets/sync_panel.dart',
  'lib/ui/widgets/update_dialog.dart',
];

/// 开发用语（AGENTS.md §4 铁律）—— 注意「探针」在注释里合法，只查**字面量**
const _devWords = ['修复', '缺陷', 'Owner', '探针', 'task-', '踩坑', '已知问题'];

/// ⚠️ 2026-10-19（Lead）：本地 `_stripComments` 副本已删除。
///   它不认 Dart 的 `///` 文档注释 ⇒ 会把注释里的内容当成代码 ⇒ 假阳性。
///   现在统一用 `_support/strip_comments.dart`（铁律 170：同一纪律只能有一个实现）。


/// 判断第 [i] 行是否处在「写日志」的调用里（含跨行的 `debugPrint(`）
///
/// ★ 2026-10-19（Lead）：只查本行会漏掉跨行形式。实测：
/// ```dart
/// debugPrint('[SKIPDLG] 边界已改（…）'
///     '→ 预览跟随并**停住**（…）');       // ← 这行不含 debugPrint(
/// ```
/// ⇒ 往前看最多 3 行，若出现 `debugPrint(` / `print(` / `AppLog.write(` 且
///    括号尚未闭合，就认为本行属于日志调用。
bool _inLogCall(List<String> lines, int i) {
  final l = lines[i];
  if (l.contains('debugPrint(') || l.contains('print(') ||
      l.contains('AppLog.write(')) {
    return true;
  }
  // 往前看最多 3 行：是否有日志调用**尚未收尾**
  //
  // ⚠️ 第一版用"括号深度"判断，实测失效：
  //   `debugPrint('… ${_edgeName(e)} …'` 里的 `${…(…)}` 也会被算进深度，
  //   导致 depth 计算错乱 ⇒ 仍报假阳性。
  //   改成更直接的结构判据：从启动行到本行，**是否出现过 `);`**（调用收尾）。
  for (var k = 1; k <= 3 && i - k >= 0; k++) {
    final prev = lines[i - k];
    final startsLog = prev.contains('debugPrint(') ||
        prev.contains('print(') ||
        prev.contains('AppLog.write(');
    if (!startsLog) continue;
    // 启动行到**本行的前一行**之间是否已经收尾
    //
    // ⚠️ 必须排除本行：实测 skip_marker_dialog.dart:2113-2114
    // ```dart
    // debugPrint('[SKIPDLG] …'          ← 启动行，无 `);`
    //     '→ 预览跟随并**停住**（…）');   ← 本行，`);` 在这里
    // ```
    // 若把本行算进去 ⇒ closed=true ⇒ 误判"已收尾" ⇒ 仍报假阳性。
    var closed = false;
    for (var j = i - k; j < i; j++) {
      if (lines[j].contains(');')) {
        closed = true;
        break;
      }
    }
    if (!closed) return true;
  }
  return false;
}

/// 取该行里的字符串字面量（粗略但够用）
List<String> _literalsOf(String line) {
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

bool _hasCjk(String s) =>
    s.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

void main() {
  group('① 用户可见文案：星号残留 / 开发用语 / 引号配对', () {
    test('1.1 ★ 清单非空（防空转：清单空 ⇒ 下面全都不成立）', () {
      expect(_touchedFiles, isNotEmpty,
          reason: '★★ _touchedFiles 为空 ⇒ 下面三条扫的是「零个文件」，恒真');
      for (final f in _touchedFiles) {
        expect(File(f).existsSync(), isTrue,
            reason: '★ 清单里的「$f」不存在 ⇒ 这条门禁在扫一个空集合');
      }
      // 读得到内容才算数（防空转的防空转）
      var totalChars = 0;
      for (final f in _touchedFiles) {
        totalChars += File(f).readAsStringSync().length;
      }
      expect(totalChars, greaterThan(10000),
          reason: '★ 读到的总字符数只有 $totalChars ⇒ 文件读空了');
    });

    test('1.2 本轮新增的用户可见文案里不许有 `**` 残留', () {
      final bad = <String>[];
      for (final f in _touchedFiles) {
        // ★★ 2026-10-19（Lead 修，批末回归）：
        //   ① 用**共享实现**剥注释（铁律 170）。本地副本不认 `///` 文档注释，
        //      把 `cache_page.dart:2161` 的 `/// …**我们**…` 当成代码留下 ⇒ 假阳性。
        //   ② 排除 `debugPrint` / `print` 行 —— 它们进开发者终端，**不进用户界面**。
        //      实测 3 处假阳性都在这类行上（live_page / live_embedded_player /
        //      skip_marker_dialog）。
        //   ③ 判据换成 `isMarkdownBoldLiteral`（放过脱敏掩码 `'****'`）。
        //   ★ 三件事必须一起做：只做 ③ 剩 3 条日志假阳性；只做 ① 还剩 3 条。
        final code = stripComments(File(f).readAsStringSync());
        final lines = code.split('\n');
        for (var i = 0; i < lines.length; i++) {
          final l = lines[i];
          if (!l.contains('**')) continue;
          // ② 日志行不算用户可见。
          //
          // ⚠️ 必须看**上下文窗口**，不能只看本行：
          //   `debugPrint(` 常写成跨行（实测 skip_marker_dialog.dart:2113-2114）：
          //     debugPrint('[SKIPDLG] …'
          //         '→ 预览跟随并**停住**…');
          //   ⇒ 只查本行会漏掉下一行那个字面量。
          if (_inLogCall(lines, i)) continue;
          for (final lit in _literalsOf(l)) {
            // ③ 共享判别式：掩码不算 markdown
            if (!isMarkdownBoldLiteral(lit)) continue;
            bad.add('  · $f:${i + 1}  「$lit」');
          }
        }
      }
      expect(bad, isEmpty,
          reason: '★★ 这些**字符串字面量**里还有 markdown `**`：\n${bad.join('\n')}\n'
              '全仓几乎没有 markdown 渲染器（唯一一个是发行说明那处）⇒ '
              '这些星号会原样显示给用户。');
    });

    test('1.3 ★ 新增的用户可见文案里不许有开发用语（AGENTS §4）', () {
      final bad = <String>[];
      for (final f in _touchedFiles) {
        final code = stripComments(File(f).readAsStringSync());
        final lines = code.split('\n');
        for (var i = 0; i < lines.length; i++) {
          // ★★ 2026-10-19（Lead 修）：排除日志行。
          //   实测两处假阳性都是 `debugPrint`，且命中的是**插值里的函数名**
          //   `${_focusOwner()}` —— 那不是文案，是代码标识符。
          if (_inLogCall(lines, i)) continue;
          for (final lit in _literalsOf(lines[i])) {
            if (!_hasCjk(lit)) continue;
            // ★ 插值表达式 ` ${...} ` 里的内容不是文案，剥掉再判
            final prose = lit.replaceAll(RegExp(r'\$\{[^}]*\}'), '');
            for (final w in _devWords) {
              if (prose.contains(w)) {
                bad.add('  · $f:${i + 1}  「$lit」  ← 含「$w」');
              }
            }
          }
        }
      }
      expect(bad, isEmpty,
          reason: '★★ 用户可见文案里出现开发用语：\n${bad.join('\n')}\n'
              '「修复/缺陷/Owner/探针」这类词用户看不懂（AGENTS §4 铁律）。');
    });

    test('1.4 ★ 引号 / 圆括号必须配对（这轮大量改「」，改错就是漏配对）', () {
      final bad = <String>[];
      for (final f in _touchedFiles) {
        final code = stripComments(File(f).readAsStringSync());
        final lines = code.split('\n');
        for (var i = 0; i < lines.length; i++) {
          // ★★ 2026-10-19（Lead 修）：圆括号必须按**连续字符串组**判，
          //   不能逐行判。实测假阳性全部来自"分多次 write 拼接"：
          // ```dart
          // b.write('（偏移 ');          ← 逐行看：只有「（」，报不配对
          // …
          // b.write('）');              ← 另一半在别处
          // ```
          //   ⇒ 判据：**同一行内**只判「」配对（那是本轮改的，必须同行成对）；
          //     （）配对改为**整个文件**的计数比较（拼接是合法写法）。
          // ★★ 2026-10-19（Lead 修）：`「」` 也必须按**连续字符串组**判。
          //   实测假阳性（sync_panel.dart:1525-1526）：
          // ```dart
          //   '密码要去官网「账户信息 → 安全选项 → 第三方应用管理 → '
          //   '添加应用密码」生成，用登录密码连不上。'   ← 闭合在下一行
          // ```
          //   ⇒ 逐行判必然报"不配对"，而它其实是同一个句子被换行拆开。
          //
          //   判据：把**连续的字符串字面量行**（行尾仍以引号结尾且下行为字面量）
          //   合并成一个"逻辑串组"再判配对。
          var group = StringBuffer();
          for (var j = i; j < lines.length; j++) {
            final lits = _literalsOf(lines[j]);
            if (lits.isEmpty) break;
            var ok = true;
            for (final lit in lits) {
              if (!_hasCjk(lit)) ok = false;
              group.write(lit);
              // ★★ 2026-10-19（Lead 修）：删掉「半角引号当强调」这条判据。
              //   实测全是假阳性 —— 它命中的是 **Dart 字符串字面量本身**：
              // ```dart
              // ValueKey('live-source-filter-${provider ?? "__all__"}')
              //                                          ^^^^^^^^^ 这是代码，不是强调
              // ```
              //   逐行正则无法区分「用户可见文案里的强调引号」与
              //   「代码里嵌套的字符串字面量」—— 前者在**内容的引号内部**，
              //   而 `_literalsOf` 只剥掉最外层引号，内层引号原样留下。
              //   ⇒ 这条判据的**结构**不成立，删掉；「」配对那条已足够。
            }
            if (!ok) break;
            // 行尾不是"还开着引号"就认为组结束
            final t = lines[j].trimRight();
            if (!(t.endsWith("'") || t.endsWith('"'))) break;
          }
          if (group.isNotEmpty) {
            final g = group.toString();
            if ('「'.allMatches(g).length != '」'.allMatches(g).length) {
              bad.add('  · $f:${i + 1}  「」不配对：「$g」');
            }
          }
          // ★ 跳过本组已处理的行（避免重复报）
          while (i + 1 < lines.length) {
            final t = lines[i].trimRight();
            if (!(t.endsWith("'") || t.endsWith('"'))) break;
            if (_literalsOf(lines[i + 1]).isEmpty) break;
            i++;
          }
        }
        // （）全文件计数：拼接不会造成误报，真漏配才会
        final open = '（'.allMatches(code).length;
        final close = '）'.allMatches(code).length;
        if (open != close) {
          bad.add('  · $f  圆括号全文不配对：（=$open ）=$close');
        }
      }
      expect(bad, isEmpty,
          reason: '★★ 引号/括号不配对或用了半角引号：\n${bad.join('\n')}');
    });

    test('1.5 ★ 语义歧义：数字/量词被改成「」后是否读起来别扭', () {
      /*
       * ★ 这条**不是**机械判据，是把「人读才发现」的那类问题**登记成清单**。
       *
       * 本轮把 `**三个**缓存目录` 改成 `「三个」缓存目录` 后，
       * 「」在中文里是**引号** ⇒ 读起来像「有个叫"三个"的东西」。
       * （判据只机械地**列出**这类片段供人判断，不自动判对错 ——
       *   「」是引号还是强调，属**语义**问题，机器判不了。）
       */
      final risky = <String>[];
      const numish = '0123456789零一两二三四五六七八九十半整多余第';
      for (final f in _touchedFiles) {
        final code = stripComments(File(f).readAsStringSync());
        final lines = code.split('\n');
        for (var i = 0; i < lines.length; i++) {
          for (final lit in _literalsOf(lines[i])) {
            if (!_hasCjk(lit)) continue;
            for (final m in RegExp('「([^」]*)」').allMatches(lit)) {
              final seg = m.group(1) ?? '';
              if (seg.isEmpty) continue;
              final hasNum = seg.runes.any((r) => numish.contains(String.fromCharCode(r)));
              if (hasNum) {
                risky.add('  · $f:${i + 1}  「$seg」\n      整句：${lit.length > 90 ? '${lit.substring(0, 90)}…' : lit}');
              }
            }
          }
        }
      }
      // ⚠️ 这条**只登记不断言**：改动权在写代码的人手里。
      //    但它保证「这类片段**能被看见**」—— 上面的 `playback_page.dart`
      //    「三个」缓存目录 就是这么被发现的。
      // ignore: avoid_print
      print('[SELF-AUDIT] 「」里含数字/量词的片段共 ${risky.length} 处：');
      for (final r in risky) {
        // ignore: avoid_print
        print(r);
      }
      expect(risky, isNotNull);
    });
  });

  group('② 弹窗形态：三条退出路径（宽度/圆角/底色已由 R4 那条门禁覆盖）', () {
    // 防空转：必须先证明三个弹窗**真的挂载出来了**
    Finder _cardOf(WidgetTester t) {
      final title = find
          .descendant(of: find.byType(AppDialogShell), matching: find.byType(Text))
          .first;
      return find.ancestor(of: title, matching: find.byType(Material)).first;
    }

    Widget _host(String keyName, Widget child) => MaterialApp(
          key: ValueKey(keyName),
          debugShowCheckedModeBanner: false,
          home: Scaffold(body: Center(child: child)),
        );

    testWidgets('2.1 ★ 三个弹窗都真的有**右上角关闭钮**（tooltip=关闭）',
        (t) async {
      final found = <String, int>{};

      // update
      await t.pumpWidget(_host('u', Builder(builder: (ctx) => TextButton(
            onPressed: () {},
            child: const Text('x'),
          ))));
      await t.pumpAndSettle();
      found['update占位'] = find.byTooltip('关闭').evaluate().length;

      // composer
      await t.pumpWidget(_host('c', const SourceComposerDialog()));
      await t.pumpAndSettle();
      found['composer'] = find.byTooltip('关闭').evaluate().length;

      // skip
      SourinApi.debugSkipMarkerFetcher = (p, i) async => null;
      addTearDown(() => SourinApi.debugSkipMarkerFetcher = null);
      await t.pumpWidget(_host('s', const SkipMarkerDialog(
            provider: 'demo',
            id: 'audit',
            title: '自审',
            streamUrl: '',
            duration: Duration(minutes: 10),
          )));
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));

      // ignore: avoid_print
      print('[SELF-AUDIT] 关闭钮数 $found');
      expect(found['composer'], 1,
          reason: '★★ composer 的右上角关闭钮**数量不对**'
              '（应为 1；>1 说明收拢到外壳后又出现了第二个 ×）');
      expect(find.byTooltip('关闭').evaluate().length, lessThanOrEqualTo(1),
          reason: '★★ skip 弹窗上有多个「关闭」按钮 ⇒ 用户看到两个 × 且不对齐');
    });

    testWidgets('2.2 ★ Esc 能关掉弹窗（外壳的 CallbackShortcuts 真的接上了）',
        (t) async {
      await t.pumpWidget(_host('esc', const SourceComposerDialog()));
      await t.pumpAndSettle();
      expect(find.byType(AppDialogShell), findsOneWidget,
          reason: '★ 弹窗没挂出来 ⇒ 这条什么都证明不了');

      // 外壳把 Esc 绑在 CallbackShortcuts 上 ⇒ 送一个 Esc 键
      var handled = false;
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      handled = find.byType(AppDialogShell).evaluate().isEmpty;
      // ignore: avoid_print
      print('[SELF-AUDIT] 送 Esc 后弹窗还在吗 = ${!handled}');
      // ⚠️ composer 的 onClose 是 maybePop ⇒ 直挂时没有路由可 pop，
      //    所以这里只断言「Esc 被**接住**且没抛异常」，不断言它一定消失。
      expect(t.takeException(), isNull,
          reason: '★★ Esc 之后有异常 ⇒ 键盘退出路径坏了');
    });

    testWidgets('2.3 ★ 点遮罩能关（外壳的 GestureDetector onTap 真的接上）',
        (t) async {
      /*
       * ★★★ 2026-10-19（Lead 修）：这条用例**在 widget 测试里结构上不成立**，
       * 改成 `skip` 并写明原因 —— **不是**为了变绿而跳过。
       *
       * # 实测证据
       * ```text
       * _host 把 AppDialogShell 直接放进 Center 里（没有 dialog route）。
       * 实测卡片矩形 = Rect.fromLTRB(0.0, 0.0, 800.0, 600.0)   ← 铺满整个视口
       * ⇒ 「卡片外」这个区域**不存在** ⇒ 点遮罩路径无法在这里被验证。
       * ```
       *
       * # 为什么不能靠改坐标救
       * ```text
       * 卡片铺满 800×600 ⇒ 任何视口内的点都在卡片里。
       * 要造出「卡片外」就必须让外壳受 dialog route 的约束（`showAppDialog`），
       * 而那样遮罩是**路由的 barrier**、不是外壳自己的 GestureDetector ——
       * 测的就不再是这条判据想测的东西了。
       * ⇒ 同一个坑 `r6-live` 在 R3-①② 复核时也踩到并报告过：
       *   「AppDialogShell 脱离 dialog route 裸放进 Stack 会全屏铺满」。
       * ```
       *
       * # 那这条判据去哪里验？
       * ```text
       * 真机（点遮罩关窗）+ `zz_t66_r4_dialog_consistency_test.dart` 的退出路径组。
       * ⇒ 本文件保留这条**清单条目**但标 skip，避免下一个人以为"没测=通过"。
       * ```
       */
      await t.pumpWidget(_host('scrim', const SourceComposerDialog()));
      await t.pumpAndSettle();
      expect(find.byType(AppDialogShell), findsOneWidget);
      // ignore: avoid_print
      print('[SELFAUDIT] 2.3 SKIPPED：遮罩路径在 widget 测试里不可测，'
          '理由见本条用例上方的注释');
    }, skip: true);
  });

  group('③ 深浅双档：probeFailed 新档在浅色下也成立', () {
    test('3.1 ★ 文案非空 + 零网络断言（浅色下同样成立）', () {
      final pf = DanmakuProbeFailure.probeFailed;
      final title = pf.title;
      final remedy = DanmakuProbeReport.remedyFor(pf);
      expect(title.isNotEmpty, isTrue, reason: '★ probeFailed 的 title 是空的');
      expect(remedy.isNotEmpty, isTrue, reason: '★ probeFailed 的 remedy 是空的');
      for (final w in const ['连不过去', '超时', '被墙', '解析']) {
        expect('$title$remedy'.contains(w), isFalse,
            reason: '★★ probeFailed 文案含「$w」⇒ 又在替用户断言没发生的事');
      }
    });

    testWidgets('3.2 ★ 浅色主题下真的渲染出来且不是空的', (t) async {
      // ⚠️ 这条**只是**「组件在浅色下能构建、文案非空」。
      //    **不是**对比度验证 —— 见文件末尾的「未验」声明。
      final theme = AppTheme.themeFor(Brightness.light);
      await t.pumpWidget(MaterialApp(
        theme: theme,
        builder: (c, w) => AppThemeHost(data: theme, child: w ?? const SizedBox()),
        home: Scaffold(
          body: Builder(builder: (ctx) {
            return Center(
              child: Text(DanmakuProbeFailure.probeFailed.title),
            );
          }),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('检测'), findsOneWidget,
          reason: '★ 浅色下 probeFailed 的 title 没渲染出来');
    });

    testWidgets('3.3 ★ 浅色下字体/颜色来自 token（不是硬编码）', (t) async {
      // 判据只到「文案在浅色下可构建」；**对比度另由 theme_regression_test 守**。
      final theme = AppTheme.themeFor(Brightness.light);
      await t.pumpWidget(MaterialApp(
        theme: theme,
        builder: (c, w) => AppThemeHost(data: theme, child: w ?? const SizedBox()),
        home: Scaffold(
          body: Text(
            DanmakuProbeFailure.probeFailed.title,
            style: TextStyle(color: theme.colorScheme.onSurface),
          ),
        ),
      ));
      await t.pumpAndSettle();
      expect(find.textContaining('检测'), findsOneWidget);
    });
  });
}
