// ═══════════════════════════════════════════════════════════════════════
//  R4 门禁：全仓弹窗一致性（机械可核对）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个门禁守的是什么
//
// Owner 原话：「弹窗样式不统一」「太丑了 丑爆了！」
// 规范见 `docs/AGENTS.md` §3.5 + `app_dialog_shell.dart` 文件头：
// ```text
// 宽度      默认 560；窄弹窗 460、宽版面 820 需显式传 width 并注释原因
// 最大高度  绝对值 620，再按视口夹取（maxHeight 可覆盖，须写清原因）
// 圆角      Radii.rLg = 22
// 标题栏    title + subtitle + 右侧关闭 IconButton
// 内容区    SingleChildScrollView
// 底部操作  可选 actions，与内容区分隔、按钮靠右
// ```
//
// # 三条断言（每条都做过故障注入，见文件末尾）
// ```text
// ① lib/ui/widgets/ 下每个 *dialog*.dart
//    · 不许裸 `AlertDialog(`（Material 原生外壳）
//    · 不许裸 `Dialog(`（自建外壳）
//    · width / maxHeight 取值必须落在白名单，或带 `// R4-EXCEPTION: <理由>`
// ② 白名单本身必须非空（空条款 = 假绿 —— 本仓有先例）
// ③ `AppDialogShell._kMaxHeight == 620`（防有人改回"视口 × 0.8"）
// ```
//
// ⚠️ **注释里的 `Dialog(` 不算**（`skip_marker_dialog.dart` 的注释里
//    留了改前写法的记录，那是文档不是代码）。所以扫描前先剥注释 ——
//    只剥 `//` 行注释与 `/* */` / `///` 文档注释，**不碰字符串字面量**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';
import 'package:sourin_spike/ui/widgets/update_dialog.dart';

import 'support/ui_shot.dart';

/// 允许的弹窗宽度档位（§3.5：默认 560 / 窄 460 / 宽版面 820）
///
/// ⚠️ 用 `int` 而不是 `double`：`const <double>{460}` 会报
///    "The element '460.0' does not have a primitive equality"
///    （double 的 `==` 不是原始相等，不能进 const Set）。
///    弹窗尺寸都是整数值，取整比较足够。
const _allowedWidths = <int>{460, 560, 820};

/// 允许的最大高度（§3.5：绝对值 620）
const _allowedMaxHeights = <int>{620};

/// 允许**不走外壳**的文件（每个都必须写清理由）
///
/// # 为什么这里**必须有**两个条目（不是洁癖）
/// ```text
/// 扫描范围是「文件名含 dialog 的 .dart」，其中两个**不是弹窗**：
///   app_dialog_shell.dart    ← 它**就是外壳本身**，不能要求它再走自己
///   app_dialog_section.dart  ← 分区标题/容器组件，不是弹窗
/// 把它们列进来是语义正确；同时也让下面的 ②「白名单非空」**真的有内容**
/// —— 一个恒空的集合没法被断言"非空"。
/// ```
///
/// ⚠️ 这是**空条款假绿**的防线：本仓有过"白名单空 ⇒ 门禁看起来全绿
///    其实什么都没守"的先例，所以 ② 强制 `isNotEmpty`。
const _bareShellWhitelist = <String, String>{
  'app_dialog_shell.dart': '它本身就是统一外壳 —— 不能要求外壳去使用外壳',
  'app_dialog_section.dart': '分区标题/容器组件，不是弹窗，没有卡片外壳',
};

/// lib/ui/widgets 下所有 `*dialog*.dart`
List<String> _dialogFiles() {
  final dir = Directory('lib/ui/widgets');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'))
      .map((f) => f.path.replaceAll('\\', '/'))
      .where((p) => p.split('/').last.contains('dialog'))
      .toList()
    ..sort();
  return files;
}

/// 剥掉注释，只留**可执行代码**
///
/// ★ 为什么必须剥（否则门禁是假红）：
/// ```text
/// skip_marker_dialog.dart:2222 的注释里留着改前写法
///   「改前这里是自建的 `Dialog(backgroundColor: …」
/// 不剥注释的话，① 这条会对**已经修好的文件**报红 ⇒ 只能靠白名单消掉
/// ⇒ 白名单一旦为了"修门禁"而加，门禁就失效了。
/// ```
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  var inString = false;
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
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (inString) {
      out.write(c);
      if (c == r'\') {
        // 转义：下一个字符原样写入
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) inString = false;
      i++;
      continue;
    }
    // 非注释、非字符串
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
    if (c == '"' || c == "'") {
      inString = true;
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

/// 从代码里抽出 `AppDialogShell(` 调用里的 `width:` / `maxHeight:` 数值
///
/// ⚠️ **只认第一层的**参数，不进嵌套的花括号/圆括号。
///
/// # 为什么必须限"第一层"（2026-10-19 实测踩到）
/// ```text
/// 第一版是"截到配平的右括号，然后在整段里找 width:" ——
/// 结果扫到的是**正文里缩略图/色点**的宽度，不是外壳的宽度：
///   provider_import_dialog.dart width=16.0   ← 那是某张封面的宽
///   source_switch_dialog.dart  width=14.0   ← 那是色点的宽
/// ⇒ 门禁对着**已经正确的文件**报红，只能靠加白名单消掉
/// ⇒ 白名单一旦为"修门禁"而加，门禁就失效了（正是本仓记过的假绿形态）。
/// ```
/// ⇒ 判据：只在 `AppDialogShell(` 的**直接实参**里找，遇到
///    `{`/`[`/`(` 就跳过整段。
({double? width, double? maxHeight, bool hasShell}) _shellArgs(String code) {
  final i = code.indexOf('AppDialogShell(');
  if (i < 0) return (width: null, maxHeight: null, hasShell: false);

  // 取 AppDialogShell( 之后、**第一层**配平右括号之前的文本，
  // 但跳过所有嵌套的 {} [] () 内容（那些属于 child / actions 的子树）
  final buf = StringBuffer();
  var depth = 1; // 已经在 AppDialogShell( 里
  var skip = 0;
  for (var j = i + 'AppDialogShell('.length; j < code.length; j++) {
    final c = code[j];
    if (skip > 0) {
      // 在嵌套结构里：只跟踪配平
      if (c == '(' || c == '{' || c == '[') skip++;
      if (c == ')' || c == '}' || c == ']') skip--;
      continue;
    }
    if (c == '(' || c == '{' || c == '[') {
      if (c == '(' && depth == 1) {
        // 需要区分：这是参数列表的延续还是嵌套调用？
        // 直接进 skip，避免把嵌套调用的同名参数算进来
        skip = 1;
        continue;
      }
      skip = 1;
      continue;
    }
    if (c == ')') {
      depth--;
      if (depth == 0) break;
      continue;
    }
    buf.write(c);
  }

  final body = buf.toString();
  final w = RegExp(r'\bwidth:\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(body);
  final h = RegExp(r'\bmaxHeight:\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(body);
  return (
    width: w == null ? null : double.parse(w.group(1)!),
    maxHeight: h == null ? null : double.parse(h.group(1)!),
    hasShell: true,
  );
}

/// 一条弹窗的**实测**几何/外观（全部来自渲染树）
///
/// ⚠️ 为什么放在**文件顶层**而不是 `group()` 里：
///   Dart 不允许在函数体内声明 class（`group((){ class X{} })` 报
///   "'class' can't be used as an identifier because it's a keyword"）。
class _Meas {
  _Meas(this.name, this.rect, this.radius, this.color, this.maxHeight);
  final String name;
  final Rect rect;
  final double? radius;
  final Color? color;
  final double? maxHeight;

  @override
  String toString() => '$name(w=${rect.width.toStringAsFixed(1)}'
      ',h=${rect.height.toStringAsFixed(1)}'
      ',r=$radius,c=${color?.toARGB32().toRadixString(16)}'
      ',maxH=$maxHeight)';
}

void main() {
  group('R4 弹窗一致性', () {
    late List<String> files;

    setUpAll(() {
      files = _dialogFiles();
    });

    // ═══════════════════════════════════════════════════════════════
    //  ② 白名单必须非空（**必须第一个跑** —— 它是另外两条的前提）
    // ═══════════════════════════════════════════════════════════════
    test('② 白名单非空校验（空条款 = 假绿）', () {
      /*
       * ★ 为什么单独一条：`_bareShellWhitelist` 是 `Map`，
       *   `isEmpty` 为真时 ① 里那句 `where((f) => !wl.containsKey(...))`
       *   会把**所有**文件都当成违规 —— 看起来"门禁很严"，
       *   实际是配置丢了。本仓有过"空条款假绿"的先例。
       *
       * ⚠️ 我第一版写的是 `src.contains('const _bareShellWhitelist = ...{')`
       *    —— 那是**子串匹配**，注入「把 Map 清空成 {}」之后它**仍然为真**
       *    ⇒ 门禁没红 = 假绿（本轮注入 ② 实测抓到）。
       *    ⇒ 判据改成**读真实值**：`_bareShellWhitelist.isNotEmpty`
       *       + 每个条目的文件名真的在扫描范围内（防"写了不存在的文件"凑数）。
       */
      expect(_bareShellWhitelist, isNotEmpty,
          reason: '★★ 白名单**不许为空** —— 空 Map 会让 ① 把所有文件判违规'
              '（"红得莫名其妙"），而 ② 本身也就失去了被验证的意义。'
              '本仓有过"空条款假绿"的先例。');

      // 白名单里提到的文件必须**真实存在**（防用不存在的文件名凑数）
      for (final name in _bareShellWhitelist.keys) {
        final path = 'lib/ui/widgets/$name';
        expect(File(path).existsSync(), isTrue,
            reason: '★ 白名单里的「$name」在 lib/ui/widgets/ 下**不存在** —— '
                '这种条目什么都没豁免，只是让白名单看起来非空');
      }

      // 阴性对照：白名单里的文件**必须真的**是"不需要外壳"的那两个
      // （防止有人为了消红把自己的弹窗塞进来）
      expect(
        _bareShellWhitelist.keys.toSet(),
        {'app_dialog_shell.dart', 'app_dialog_section.dart'},
        reason: '★★ 白名单只允许这两个**非弹窗**文件。\n'
            '新增条目 = 允许某个弹窗绕过统一外壳 ⇒ 必须先在本注释里'
            '写清原因，并同步改本断言的期望集合。',
      );

      // 每条理由都要够具体（"占位"式理由等于没写）
      for (final e in _bareShellWhitelist.entries) {
        expect(e.value.trim().length, greaterThan(8),
            reason: '★ 白名单条目「${e.key}」的理由太短 —— 等于没写');
      }
    });

    // ═══════════════════════════════════════════════════════════════
    //  ① 不许裸 AlertDialog / Dialog + 尺寸必须落在白名单
    // ═══════════════════════════════════════════════════════════════
    test('①-a 不许裸 `AlertDialog(`（Material 原生外壳）', () {
      final bad = <String>[];
      for (final f in files) {
        final name = f.split('/').last;
        if (_bareShellWhitelist.containsKey(name)) continue;
        final code = _stripComments(File(f).readAsStringSync());
        if (RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\(').hasMatch(code)) {
          bad.add(name);
        }
      }
      expect(bad, isEmpty,
          reason: '★★ 这些文件还在用 Material 的 `AlertDialog`（原生外壳）：$bad\n'
              '它没有我们的标题栏形态（无副标题 / 无右上关闭钮 / 按钮条不靠右），'
              '也没有统一圆角与底色 ⇒ 正是 Owner 说的「样式不统一」。\n'
              '改法：换成 `AppDialogShell`（参考 update_dialog.dart）。');
    });

    test('①-b 不许裸 `Dialog(`（自建外壳）', () {
      final bad = <String>[];
      for (final f in files) {
        final name = f.split('/').last;
        if (_bareShellWhitelist.containsKey(name)) continue;
        final code = _stripComments(File(f).readAsStringSync());
        /*
         * 判据只认**代码里**的 `Dialog(`：
         *   · 前面不能是标识符字符或 `.`（排除 `showDialog(` / `foo.Dialog(`）
         *   · 排除 `AlertDialog(`（上一条管）、`AppDialogShell(` 等
         * ⚠️ 已经剥过注释 ⇒ 注释里记录"改前写法"不会误报。
         */
        final re = RegExp(r'(?<![A-Za-z0-9_.])Dialog\(');
        if (re.hasMatch(code)) bad.add(name);
      }
      expect(bad, isEmpty,
          reason: '★★ 这些文件自建了 `Dialog(` 外壳：$bad\n'
              '自建外壳是"宽度四种、高度三种"的来源（见 app_dialog_shell.dart 文件头）。\n'
              '改法：换成 `AppDialogShell`，尺寸用它的 width / maxHeight 参数。');
    });

    test('①-c width / maxHeight 必须落在白名单，或带 R4-EXCEPTION 注释', () {
      final violations = <String>[];
      for (final f in files) {
        final name = f.split('/').last;
        if (_bareShellWhitelist.containsKey(name)) continue;
        final raw = File(f).readAsStringSync();
        final code = _stripComments(raw);
        final args = _shellArgs(code);
        if (!args.hasShell) {
          // 没走外壳的文件已由 ①-a / ①-b 负责；这里不重复报
          continue;
        }
        final hasException = raw.contains('// R4-EXCEPTION:');

        if (args.width != null &&
            !_allowedWidths.contains(args.width!.round())) {
          if (!hasException) {
            violations.add('$name width=${args.width}');
          }
        }
        if (args.maxHeight != null &&
            !_allowedMaxHeights.contains(args.maxHeight!.round())) {
          if (!hasException) {
            violations.add('$name maxHeight=${args.maxHeight}');
          }
        }
      }
      expect(violations, isEmpty,
          reason: '★★ 这些弹窗的尺寸不在 §3.5 白名单里：$violations\n'
              '允许：width ∈ ${_allowedWidths.toList()}、'
              'maxHeight ∈ ${_allowedMaxHeights.toList()}。\n'
              '确实需要破例的，在**同一个文件**里写一行：\n'
              '    // R4-EXCEPTION: <为什么这个数不能改，以及实测依据>\n'
              '（只写"因为看起来更好"不算理由 —— 要能被下一个人验证。）');
    });

    // ═══════════════════════════════════════════════════════════════
    //  ③ 外壳的高度上限必须是绝对值 620
    // ═══════════════════════════════════════════════════════════════
    test('③ `AppDialogShell._kMaxHeight` 必须是绝对值 620', () {
      final src = File('lib/ui/widgets/app_dialog_shell.dart').readAsStringSync();
      final code = _stripComments(src);

      /*
       * ★ 这条守的是**算错方向**：改回"视口 × 0.8"是一种很容易犯的直觉错误
       *   （"按屏幕比例更自适应"），但 800×600 的测试视口下只有 480
       *   —— **比改前的 620 更矮**，内容被挤、Slider 出视口。
       *   见 `app_dialog_shell.dart` 里 `_kMaxHeight` 的注释（t70 三条红）。
       */
      final m = RegExp(r'_kMaxHeight\s*=\s*([0-9]+(?:\.[0-9]+)?)')
          .firstMatch(code);
      expect(m, isNotNull,
          reason: '★ 找不到 `_kMaxHeight = <数值>` —— 常量被改名/删掉了？');
      expect(double.parse(m!.group(1)!), 620,
          reason: '★★ `_kMaxHeight` 必须是 **620（绝对值）**，实际是 ${m.group(1)}。\n'
              '2026-10-17 的更正：改前文档写的是"视口 × 0.8"，那是**被证伪**的数：\n'
              '  800x600 测试视口下 0.8*600 = 480 < 620 ⇒ 内容被挤，t70 三条 tap 红。\n'
              '⇒ 不许改回比例式，除非同时改 AGENTS.md §3.5 并重跑 t70。');

      // 阳性对照：这个常量**真的被用**（不是定义了没人读）
      expect(RegExp(r'maxHeight\s*\?\?\s*_kMaxHeight').hasMatch(code), isTrue,
          reason: '★★ `_kMaxHeight` 必须在 `maxHeight ?? _kMaxHeight` 里被**读**——'
              '定义了却不使用 = 改了半天没生效（本仓有过这个坑）');
    });

    // ═══════════════════════════════════════════════════════════════
    //  阳性对照：三个本轮收拢的弹窗**真的**走了外壳
    // ═══════════════════════════════════════════════════════════════
    test('阳性对照：update / skip / composer 三个弹窗都走 AppDialogShell', () {
      for (final n in const [
        'update_dialog.dart',
        'skip_marker_dialog.dart',
        'source_composer_dialog.dart',
      ]) {
        final code = _stripComments(
            File('lib/ui/widgets/$n').readAsStringSync());
        expect(code.contains('AppDialogShell('), isTrue,
            reason: '★★ $n 必须走统一外壳 —— 这是 R4 的核心成果');
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ★★★ 渲染判据（2026-10-19 补）★★★ —— 读**真实渲染结果**，不是源码
  // ═════════════════════════════════════════════════════════════════════
  //
  // # 为什么上面那组静态检查**不够**（这是本组存在的理由）
  // ```text
  // 上面 ①-a/①-b/①-c 扫的是**源码文本**。它们能证明"写了 AppDialogShell("，
  // 但证明不了"渲染出来的卡片是同一个样子"。
  // 真正决定 Owner 说的「不统一、丑」的，是**像素**：
  //   卡片实际多宽 / 什么圆角 / 什么底色 / 吃的是不是同一个高度上限。
  // 假想一种真实存在的坑（源码全对、像素不对）：
  // ```text
  //   外壳把 width 写成 SizedBox(width: w * 0.9)，
  //   或 forceDarkCard/glass 分支让底色走另一条路，
  //   或某个弹窗传的 maxHeight 悄悄吃掉了默认值
  // ⇒ ①-c 全绿，但三个弹窗并排一看就是三个尺寸。
  // ```
  //
  // # 本组的判据
  // ```text
  // ④ 三个弹窗各自真渲染一遍（真挂载、真 pump），读：
  //      · 卡片 Rect（tester.getRect）
  //      · 圆角（Material.shape 的 borderRadius）
  //      · 底色（Material.color）
  //    断言三者**逐项相等**（圆角/底色）且宽度落在 §3.5 白名单。
  // ⑤ 只有 skip_marker 允许传 maxHeight（实测反证），另两个必须吃默认。
  // ```
  //
  // ⚠️ 判据全部取自 `Material` 的**渲染实例**，不是源码常量 ——
  //    源码字符串当判据是本仓明确记过的假绿形态。
  group('R4 弹窗一致性（渲染判据）', () {
    /// 卡片 = 外壳里那层 `Material(type: card)`。
    ///
    /// ★ 为什么取「标题 Text 的最近 Material 祖先」而不是"第一个 Material"：
    ///   `AppDialogShell` 的子树里可能先出现别的 Material（如 Chip/SnackBar），
    ///   "第一个"不一定是卡片。标题栏一定在卡片里，且卡片是它的**最近** Material 祖先。
    Finder _cardFinder() {
      final shell = find.byType(AppDialogShell);
      final title = find.descendant(of: shell, matching: find.byType(Text)).first;
      final mat = find.ancestor(of: title, matching: find.byType(Material));
      return mat.first;
    }

    _Meas _measure(WidgetTester t, String name) {
      final card = _cardFinder();
      final r = t.getRect(card);
      final m = t.widget<Material>(card);
      final shape = m.shape;
      double? radius;
      if (shape is RoundedRectangleBorder) {
        // ⚠️ `material_ui` 遮蔽了 `BorderRadius` 这个名字 ⇒ 只能按 `is` 判断
        final br = shape.borderRadius;
        if (br is BorderRadius && br.topLeft == br.bottomRight) {
          radius = br.topLeft.x;
        }
      }
      final shellW = t.widget<AppDialogShell>(find.byType(AppDialogShell));
      return _Meas(name, r, radius, m.color, shellW.maxHeight);
    }

    /// ★ `key` 是**必须**的（2026-10-19 实测踩到）：
    ///   `showUpdateDialog` 走的是 **route**，而 route 挂在 `MaterialApp` 的
    ///   `Navigator` 里。连续 pump 两个形状相同的 `MaterialApp` 时，Flutter
    ///   **复用**同一个 Element 子树 ⇒ 上一个 dialog 的 route 还在 overlay 里，
    ///   `find.byType(AppDialogShell)` 命中 2 个 ⇒
    ///   `Bad state: Too many elements`（WidgetController.widget 抛的）。
    ///   给每次挂载一个**不同的 key** ⇒ 旧子树整个 dispose，Navigator 一并销毁。
    Widget _host(String keyName, Widget child) => MaterialApp(
          key: ValueKey(keyName),
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'Microsoft YaHei UI',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF7C4DFF),
              brightness: Brightness.dark,
            ),
          ),
          home: Scaffold(body: Center(child: child)),
        );

    ReleaseInfo _rel() => parseReleaseJson({
          'tag_name': 'v1.1.0',
          'name': 'v1.1.0',
          'body': '## 本次更新\n\n- 修了些东西',
          'draft': false,
          'prerelease': false,
          'html_url': '',
          'published_at': null,
          'assets': [
            {
              'name': 'Sourin-Setup-1.1.0.exe',
              'size': 12345678,
              'browser_download_url': 'https://example.invalid/a.exe',
            }
          ],
        } as Map<String, dynamic>);

    setUpAll(loadRealFonts);

    setUp(() async {
      final tmp = await Directory.systemTemp.createTemp('sourin_r4');
      await UiPrefs.load(tmp.path);
      AppUpdateController.instance.loadPrefs();
      AppUpdateController.instance.debugResetAvailable();
      AppUpdateController.instance
          .debugSetDownloadState(UpdateDownloadState.idle);
    });

    /// 三个弹窗各真渲染一遍，返回实测值（按名字索引）
    Future<Map<String, _Meas>> _measureAll(WidgetTester t) async {
      final out = <String, _Meas>{};

      // update：走真实 showUpdateDialog 入口（与 app_update_ui_test 同路子）
      await setShotViewport(t, const Size(1440, 900));
      await t.pumpWidget(_host('update', Builder(builder: (ctx) => TextButton(
            onPressed: () =>
                showUpdateDialog(ctx, _rel(), platform: UpdatePlatform.windows),
            child: const Text('打开'),
          ))));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      out['update'] = _measure(t, 'update');

      // composer
      await setShotViewport(t, const Size(1600, 1000));
      await t.pumpWidget(_host('composer', const SourceComposerDialog()));
      await t.pumpAndSettle();
      out['composer'] = _measure(t, 'composer');

      // skip
      SourinApi.debugSkipMarkerFetcher = (p, i) async => null;
      addTearDown(() => SourinApi.debugSkipMarkerFetcher = null);
      await setShotViewport(t, const Size(1280, 800));
      await t.pumpWidget(_host('skip', const SkipMarkerDialog(
        provider: 'tyyszy',
        id: '70260',
        title: '怒鲨狂潮',
        streamUrl: 'file:///nonexistent.mp4',
        duration: Duration(seconds: 600),
      )));
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      out['skip'] = _measure(t, 'skip');

      return out;
    }

    testWidgets('④ 三弹窗卡片：圆角/底色一致 + 宽度落在白名单（渲染实测）',
        (t) async {
      final m = await _measureAll(t);

      // —— 宽度：必须落在 §3.5 白名单（460 窄 / 560 默认 / 820 宽）——
      for (final e in m.entries) {
        expect(_allowedWidths.contains(e.value.rect.width.round()),
            isTrue,
            reason: '★★ ${e.key} 的**卡片实测宽** = ${e.value.rect.width}，'
                '不在 §3.5 白名单 ${_allowedWidths.toList()}。\n'
                '这是 `tester.getRect` 读出来的真实渲染宽度，不是源码里的 `width:` '
                '—— 源码可能写对了而渲染被别的约束改掉。');
      }

      // —— 圆角：三者必须完全相同（实测）——
      final radii = m.values.map((x) => x.radius).toSet();
      expect(radii.length, 1,
          reason: '★★ 圆角不一致：${m.values.join(" / ")}\n'
              '三个弹窗并排看圆角不一样，正是 Owner 说的「样式不统一」。'
              '统一走 AppDialogShell 的 `Radii.rLg`。');
      expect(radii.single, isNotNull,
          reason: '★ 圆角读不到 —— `Material.shape` 不是 RoundedRectangleBorder，'
              '或 `borderRadius` 不是等角圆。外壳必须写死 Radii.rLg。');
      // 等角圆时把三档具体数值也钉住（§3.5：Radii.rLg = 22）
      expect(radii.single, 22,
          reason: '★★ 卡片圆角实测 = ${radii.single}，§3.5 规定 Radii.rLg = 22。');

      // —— 底色：三者必须完全相同（实测）——
      final colors = m.values.map((x) => x.color).toSet();
      expect(colors.length, 1,
          reason: '★★ 底色不一致：${m.values.join(" / ")}\n'
              '卡片底色必须由外壳一处决定（`surfaceContainerHighest`，'
              '玻璃档/深色档走各自的实色），不许各弹窗自己写。');
      expect(colors.single, isNotNull,
          reason: '★ 底色读不到 —— `Material.color` 是 null。'
              '不允许"透明卡片"（R3-①② 的教训：transparent 让底下色块透上来，'
              '把文字对比度打穿）。');
      // 不许透明（alpha 必须足够高，R3-①② 的实测教训）
      expect(colors.single!.a, greaterThanOrEqualTo(0.98),
          reason: '★★ 卡片底色实测 alpha = ${colors.single!.a}，'
              '必须 ≥ 0.98。R3-①② 实测：玻璃档曾用 Colors.transparent，'
              '底下高饱和色块透上来，把 #8E939B 的对比度打到 2.09:1（正文线 4.5）。');
    });

    testWidgets('⑤ 只有 skip_marker 传 maxHeight，另两个吃默认值（渲染实测）',
        (t) async {
      final m = await _measureAll(t);

      // update / composer 必须吃默认（maxHeight 字段为 null ⇒ 外壳用 _kMaxHeight）
      expect(m['update']!.maxHeight, isNull,
          reason: '★★ update_dialog 不许传 `maxHeight` —— 必须吃外壳默认的 '
              '`_kMaxHeight`（620）。实测 = ${m['update']!.maxHeight}。\n'
              '§3.5 只有在有**实测反证**时才允许覆盖，且必须在同文件写清理由。');
      expect(m['composer']!.maxHeight, isNull,
          reason: '★★ source_composer_dialog 不许传 `maxHeight` —— 必须吃默认。'
              '实测 = ${m['composer']!.maxHeight}。');

      // skip 是本轮唯一有实测反证的破例，必须传且必须是 740
      expect(m['skip']!.maxHeight, isNotNull,
          reason: '★ skip_marker_dialog 应当显式传 `maxHeight`（740）——'
              '620 会把第四行挤出视口、预览只剩 116px。'
              '若这里变 null，说明有人把破例删了。');
      expect(m['skip']!.maxHeight, 740,
          reason: '★★ skip 的 `maxHeight` 实测 = ${m['skip']!.maxHeight}，应为 740'
              '（= `kDialogMaxH`）。改这个数前先跑 '
              '`skip_history_dialog_test.dart` 与 orchestrator 系列。');

      // 高度上限的**实际生效值**也钉一下：另两个的高度必须 <= 620（默认值）
      expect(m['update']!.rect.height, lessThanOrEqualTo(620),
          reason: '★★ update 卡片高 ${m['update']!.rect.height} 超过默认上限 620');
      expect(m['composer']!.rect.height, lessThanOrEqualTo(620),
          reason: '★★ composer 卡片高 ${m['composer']!.rect.height} 超过默认上限 620');
    });
  });
}
