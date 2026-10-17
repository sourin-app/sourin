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

/// 药丸门禁的白名单 —— **每一条都必须写清「为什么它不能换」**
///
/// 规则：产品特有的复合件不是 Material 控件的等价物，替换反而是错的；
///       但如果只是「长得像药丸」的普通可选胶囊，就必须换。
const _pillWhitelist = <String>{
  // ① 液态玻璃药丸：背景/折射由 GlassContainer 画，ChoiceChip 表达不了
  'lib/ui/widgets/settings_kit.dart',

  'lib/ui/widgets/source_bar.dart',


  // ② 源条的选中药丸：它**自己带补间**（AnimatedContainer + Motion.fast +
  //    渐变底），选中态是一次真实动画。`source_bar_test.dart:61` 与
  //    `t50c_source_button_feedback_test.dart` 钉的就是「补间真的在跑」。
  //    换成静态 chip 会把这个已测试的动画语义丢掉 —— 属于「非必要」的反面。

  // ③④ 追更页 / 「我的」的 tab chip：它们**整体在玻璃容器里**，选中态由
  //    外层一个**滑动药丸**（AnimatedPositioned）画，chip 自己是透明的。
  //    task16_glass_autorefresh_test.dart 明确钉着「一块玻璃包三个 tab」+
  //    「内部 tab 是透明的 + 有滑动选中药丸」——换成 ChoiceChip 会同时
  //    破掉玻璃与滑动药丸两件事。
  'lib/ui/follow_page.dart',
  'lib/ui/widgets/my_shelf.dart',
};

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
          /*
           * ★★★ 2026-10-17：跳过**设计预览面板的样张**
           *
           * theme_page.dart 的预览里有：
           *   Row(children: [Switch(value: true, onChanged: (_) {}), ...])
           * 和旁边的 FilledButton/OutlinedButton/TextButton 一样，
           * 全是空回调、只读展示（注释：「开关两态」「只读展示，不抢焦点」）。
           *
           * ⇒ 样张要展示的就是 Switch 本身，改成 SwitchListTile 会展示错东西。
           * 判据：空回调视为样张。不用文件白名单 ——
           *   同一个文件里既有样张也有真控件，文件级豁免会连真控件一起放过。
           */
          if (RegExp(r'onChanged:\s*\(_\)\s*\{\}').hasMatch(body)) continue;
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

    test('★ 开关行：不许「自写行 + 裸 Switch」（应换 SwitchListTile）', () {
      /*
       * ★ 2026-10-16 新增。为什么第一组规则抓不到它：
       *
       * 上面那条「手写 Row 里塞裸 Switch」的判据是**词法范围**的 ——
       * 它在 `Row(` 的直接体里找 `Switch(`。但真实写法常常是：
       * ```text
       *   Widget _row(String label, Widget child, ...) {   // ← Row 在这里
       *     return Padding(child: Row(children: [Text(label), Expanded(child: child)]));
       *   }
       *   ...
       *   _row('间隔', Switch(value: v, onChanged: f));   // ← Switch 在这里（参数里）
       * ```
       * `Row` 与 `Switch` **不在同一段代码里** ⇒ 第一组规则完全看不见。
       * 实测：player_settings_sheet.dart 就是这么写的，门禁当时是**绿的**。
       *
       * 本组改成**跨行扫调用点**：把 `Switch(` 出现在 `_row(...)` 实参里也认出来。
       *
       * ⚠️ 白名单是**待办**，不是豁免 —— 该处应改成 SwitchListTile
       *   （整行可点 + 涟漪 + 读屏语义；长相用 contentPadding/dense 调回原样）。
       *   清掉后必须把白名单一并删掉（下面的自检会抓空条款）。
       */
      /*
       * ★ 2026-10-16：白名单**已清空**。
       *
       * 原条目 `lib/ui/widgets/player_settings_sheet.dart` 已修复：
       * 那 19 个 `_row` 调用点里唯一塞了裸 `Switch` 的一处
       * （`_switchRow`）改成了框架的 `SwitchListTile`；
       * `_row` 保留给其余 18 处「标签 + 右侧控件」。
       *
       * ⚠️ 白名单是**待办**，不是豁免 —— 清完必须删条目，
       *   下面的自检就是抓「空条款 = 假绿」的。
       */
      const pending = <String>{};
      final bad = <String>[];
      for (final f in _dartFiles()) {
        final rel = f.path.replaceAll(r'\', '/');
        if (pending.contains(rel)) continue;
        final src = f.readAsStringSync();
        final lines = src.split('\n');
        for (var i = 0; i < lines.length; i++) {
          // 调用点：本行是 `_row(` 且同行有裸 Switch(（排除 SwitchListTile）
          if (!RegExp(r'\b_row\s*\(').hasMatch(lines[i])) continue;
          /*
           * ★★★ 2026-10-17：跳过**设计预览面板**
           *
           * theme_page.dart 的预览面板里有 `Switch(value: true, onChanged: (_) {})`
           * —— 那是**组件样张**，和旁边的 FilledButton/OutlinedButton 一样，
           * 全部空回调、只读展示，注释也写着「开关两态」「只读展示，不抢焦点」。
           *
           * ⇒ 样张的目的就是"展示这个控件长什么样"，
           *   改成 SwitchListTile 反而会展示错东西（样张要展示的是 Switch 本身）。
           *
           * 判据：空回调 onChanged: (_) {} 或 onPressed: () {} 视为样张。
           * 不用文件级白名单，因为同一个文件里既有样张也有真控件。
           */
          if (RegExp(r'onChanged:\s*\(_\)\s*\{\}').hasMatch(lines[i])) continue;
          for (var k = i; k < lines.length && k < i + 7; k++) {
            if (!RegExp(r'\bSwitch\s*\(').hasMatch(lines[k])) continue;
            if (lines[k].contains('SwitchListTile')) continue;
            bad.add('$rel:${k + 1}');
          }
        }
      }
      expect(
        bad,
        isEmpty,
        reason: '这些地方是「自写行 + 裸 Switch」，应改用框架的 SwitchListTile：${bad.join('  ')}',
      );
      // ★ 白名单自检：待办清完就必须删条目，不许留空条款
      for (final w in pending) {
        final f = File(w);
        expect(f.existsSync(), isTrue, reason: '白名单里的 $w 不存在了 —— 请同步更新本文件');
        expect(
          f.readAsStringSync().contains('Switch('),
          isTrue,
          reason: '★ $w 已经没有裸 Switch 了 —— 该处已清理，请把白名单条目删掉（空条款 = 假绿）',
        );
      }
    });
    test('★ 药丸（手写 InkWell + 全圆角容器）应改用 ChoiceChip/FilterChip', () {
      /*
       * 判据是「InkWell 直接包一个自己画底色/描边的全圆角容器」——
       * 那就是一颗手写药丸，框架里对应 ChoiceChip / FilterChip。
       *
       * ⚠️ 2026-10-15 第二版：**第一版判据漏了** —— 它只匹配字面量
       *    `BorderRadius.circular(999)`，而仓库里还有一半药丸写的是
       *    设计令牌 `Radii.rFull`（二者同一个值）。于是 browse_page /
       *    player_settings_sheet / live_page 里那几颗手写药丸**从门禁下
       *    溜了过去**。现在判据改成结构性识别（InkWell + BoxDecoration +
       *    全圆角），两种写法都算。
       */
      final bad = <String>[];
      for (final f in _dartFiles()) {
        final rel = f.path.replaceAll(r'\', '/');
        if (_pillWhitelist.contains(rel)) continue;
        final src = f.readAsStringSync();
        /*
         * ★★★ 2026-10-17 修假阳性：`InkWell\s*\(` 会匹配到 `AppInkWell(`
         *
         * 正则没有词边界，`AppInkWell(` 里含子串 `InkWell(`，于是
         * 已迁到 AppInkWell 的代码（**正是迁移的目标**）被当成
         * 「手写药丸」报出来 —— 与本门禁的意图完全相反。
         *
         * 实测：lib/ui/shell_layouts/top_bar_layout.dart:150 报错，
         * 而那里写的是 `return AppInkWell(`（去 Material 后的正确形态）。
         *
         * ⇒ 加 `(?<![A-Za-z_])` 负向后顾：前面不能紧跟标识符字符，
         *   这样只认裸的 `InkWell(`，放过 `AppInkWell(` / `XxxInkWell(`。
         */
        for (final m in RegExp(r'(?<![A-Za-z_])InkWell\s*\(').allMatches(src)) {
          final end = _closeOf(src, m.end - 1);
          final body = src.substring(m.end, end);
          if (!body.contains('BoxDecoration')) continue;
          // 圆形色板不是胶囊
          if (body.contains('BoxShape.circle')) continue;
          // 只看这个 InkWell 自己那层 BoxDecoration 的圆角
          //
          // ⚠️ 第三版：**不许用正则**。`BoxDecoration(...)` 的参数里可以嵌
          //    任意层括号（颜色表达式、注释里的括号……），一个
          //    `([^()]|\([^()]*\))*` 的非递归正则**匹配不到** —— 于是
          //    命中的文件被**静默跳过**，门禁显示绿而其实没查。
          //    实测：source_bar.dart 的选中药丸就因此溜过（故障注入把它的
          //    白名单条目删掉，门禁**依然绿** —— 那就是假绿）。
          //    ⇒ 改成括号配平取整段，才真的看得见。
          final dStart = body.indexOf('BoxDecoration(');
          if (dStart < 0) continue;
          final dEnd = _closeOf(body, dStart + 'BoxDecoration'.length);
          final d = body.substring(dStart, dEnd + 1);
          if (!d.contains('Radii.rFull') &&
              !d.contains('BorderRadius.circular(999)') &&
              !d.contains('BorderRadius.circular(Radii.full)')) {
            continue;
          }
          final line = src.substring(0, m.start).split('\n').length;
          bad.add('$rel:$line');
        }
      }
      expect(bad, isEmpty, reason: '手写药丸应改用框架的 ChoiceChip/FilterChip：${bad.join('  ')}');
    });

    test('★ 白名单条目必须仍然存在（空条款 = 假绿）', () {
      // 防「假绿」：白名单路径若已不存在，说明豁免早已失效、门禁在偷偷放行
      for (final w in _pillWhitelist) {
        expect(File(w).existsSync(), isTrue, reason: '白名单里的 $w 不存在了 —— 请同步更新本文件');
      }
    });
  });
}
