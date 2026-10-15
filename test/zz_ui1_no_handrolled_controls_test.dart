// ═══════════════════════════════════════════════════════════════════════
//  UI-1 · 不许再手写「框架已有的控件」
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁是为什么立的（2026-10-15 · Owner）
//
// ```text
// > 不止弹窗,还有各种输入框等等组件,如果有现成契合现在设计的都可以直接使用,
// > 非必要情况,不手写组件
// ```
//
// 上一轮把这几处手写件换成了框架控件：
//   ① 弹幕面板四处开关：手写 `Row`+`Switch` ⇒ `SwitchListTile`
//   ② 弹幕面板卡片外壳：`Container(decoration:)` ⇒ `Material`
//      （不换的话框架会直接抛断言：ListTile 的涟漪画不出来）
//   ③ `SettingsGesturePill`：手写 InkWell+Container 药丸 ⇒ `ChoiceChip`
//   ④ `SettingsGestureToggle` / tvbox `_toggleRow`：手写 Row ⇒ `SwitchListTile`
//   ⑤ bili 导入面板 / 跳过面板的开关行 ⇒ `SwitchListTile`
//
// 换完**长相不变**（颜色/圆角/间距都显式给死），多出来的是：整行可点、
// 涟漪与焦点环、以及读屏语义（把标题+副标题+开关读成**一个**控件）。
//
// # 这条门禁拦什么、不拦什么
//
// ```text
// 拦：**重复造框架轮子** —— 一个「标签 + 开关」的手写 Row、一颗手写药丸。
// 不拦：产品特有的复合件（液态玻璃 tab、弹幕轨道、海报卡、进度条……）。
//      它们不是 Material 控件的等价物，替换反而是错的。
// ```
//
// ⚠️ 判据是**结构性**的（源码里有没有那个形状），不是「长得像不像」。
//    所以白名单里每一条都写了「为什么它不能换」。
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 递归收集 lib/ 下所有 .dart 文件（跳过探针文件）
List<File> _dartFiles() {
  final out = <File>[];
  for (final e in Directory('lib').listSync(recursive: true)) {
    if (e is! File || !e.path.endsWith('.dart')) continue;
    final p = e.path.replaceAll(r'\', '/');
    if (p.contains('probe')) continue;
    out.add(e);
  }
  return out;
}

/// 取某个 '(' 起、配对的那个 ')' 的下标
int _closeOf(String s, int openIdx) {
  var d = 0;
  for (var i = openIdx; i < s.length; i++) {
    if (s[i] == '(') d++;
    if (s[i] == ')') {
      d--;
      if (d == 0) return i;
    }
  }
  return s.length;
}

void main() {
  group('UI-1 · 不许再手写框架已有的控件', () {
    test('★ 不许有「手写 Row 里塞一枚裸 Switch」的开关行', () {
      // 判据：同一个 Row( 的子项里出现 Switch(，且没有用 SwitchListTile
      final bad = <String>[];
      for (final f in _dartFiles()) {
        final src = f.readAsStringSync();
        final rel = f.path.replaceAll(r'\', '/');
        for (final m in RegExp(r'Row\s*\(').allMatches(src)) {
          final end = _closeOf(src, m.end - 1);
          final body = src.substring(m.end, end);
          if (!RegExp(r'\bSwitch\s*\(').hasMatch(body)) continue;
          if (body.contains('SwitchListTile')) continue;
          final line = src.substring(0, m.start).split('\n').length;
          bad.add('$rel:$line');
        }
      }
      expect(
        bad,
        isEmpty,
        reason: '这些地方是「手写 Row + 裸 Switch」，应改用框架的 SwitchListTile（整行可点 + 涟漪 + 读屏语义；长相用 contentPadding/dense 调回原样）：${bad.join('  ')}  —— 若某处确实不能换，加进本文件白名单并写明理由。',
      );
    });

    test('★ 药丸（999 圆角 + 手写底色）应改用 ChoiceChip/FilterChip', () {
      const whitelist = <String>{
        // 液态玻璃药丸：背景/折射由 GlassContainer 画，ChoiceChip 表达不了
        'lib/ui/widgets/settings_kit.dart',
      };
      final bad = <String>[];
      for (final f in _dartFiles()) {
        final rel = f.path.replaceAll(r'\', '/');
        if (whitelist.contains(rel)) continue;
        final src = f.readAsStringSync();
        final lines = src.split('\n');
        for (var i = 0; i < lines.length; i++) {
          if (!lines[i].contains('BorderRadius.circular(999)')) continue;
          final win = lines.sublist(i, (i + 12).clamp(0, lines.length)).join('\n');
          if (!win.contains('BoxDecoration')) continue;
          bad.add('$rel:${i + 1}');
        }
      }
      expect(bad, isEmpty, reason: '手写药丸应改用框架的 ChoiceChip/FilterChip：${bad.join('  ')}');
    });

    test('★ 白名单条目必须仍然存在（空条款 = 假绿）', () {
      // 防「假绿」：白名单路径若已不存在，说明豁免早已失效、门禁在偷偷放行
      const whitelist = <String>['lib/ui/widgets/settings_kit.dart'];
      for (final w in whitelist) {
        expect(File(w).existsSync(), isTrue, reason: '白名单里的 $w 不存在了 —— 请同步更新本文件');
      }
    });
  });
}
