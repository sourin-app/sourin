// ═══════════════════════════════════════════════════════════════════════
//  task-42：主题包的配色必须真的进到 colorScheme（不许被 _buildLight 覆盖）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这条
// ```text
// 2026-10-17 dlg-source 实测发现：`_buildLight()` 的 `cs.copyWith(...)`
// 里有 7 个字段写死成 LightTokens / Colors.white，在 `c.toColorScheme()`
// **之后**执行 ⇒ 把主题包的值覆盖掉。
//
// 实测（改前）：
//   sakura.light  palette.primary = E38AA6（粉）  cs.primary = 3B6FE0（蓝）
//   forest.light  palette.primary = 2E7D4F（绿）  cs.primary = 3B6FE0（蓝）
//   neoBrutal     palette.primary = 000000（黑）  cs.primary = 3B6FE0（蓝）
// ⇒ 用户选「樱粉」，按钮却是蓝色 —— 与「三套看起来像不同 App」直接冲突。
// ```
//
// # 判据
// ```text
// 对每套内置浅色/深色主题包：
//   colorScheme.primary           == palette.primary
//   colorScheme.onPrimary         == palette.primaryForeground
//   colorScheme.onSurfaceVariant  == palette.mutedForeground
//   colorScheme.outline           == palette.border
//   colorScheme.onSecondary       == palette.secondaryForeground
//   colorScheme.surface           == palette.background
// ```
// ⚠️ 这条门禁的价值不在「今天的值对不对」，而在**防止下一次**
//    有人再往 copyWith 里塞一个写死值把它盖回去。
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

String _hex(Color c) =>
    (c.toARGB32() & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase();

void main() {
  final packs = ThemePackStore.builtins;

  test('主题包数量足够（防在空集上假绿）', () {
    expect(packs.length, greaterThanOrEqualTo(8),
        reason: '内置主题少于 8 套 ⇒ 门禁可能在空集上跑');
  });

  test('*** 主题包的 primary 必须真的进到 colorScheme（task-42）', () {
    final bad = <String>[];
    for (final p in packs) {
      final cs = AppTheme.themeForPack(p.brightness, p).colorScheme;
      if (_hex(cs.primary) != _hex(p.palette.primary)) {
        bad.add(p.id +
            '  palette.primary=' + _hex(p.palette.primary) +
            '  但 colorScheme.primary=' + _hex(cs.primary));
      }
    }
    expect(bad, isEmpty,
        reason: '这些主题的主色被 colorScheme 覆盖了 ⇒ 用户选了主题，'
            '按钮/强调色却不是主题色：\n' + bad.join('\n'));
  });

  test('*** 其余单真源字段也必须一致（防又一次「修一个漏一个」）', () {
    final bad = <String>[];
    for (final p in packs) {
      final cs = AppTheme.themeForPack(p.brightness, p).colorScheme;
      final pl = p.palette;
      void chk(String name, Color got, Color want) {
        if (_hex(got) != _hex(want)) {
          bad.add(p.id + '  ' + name + ': cs=' + _hex(got) +
              '  palette=' + _hex(want));
        }
      }
      chk('onPrimary', cs.onPrimary, pl.primaryForeground);
      chk('onSurfaceVariant', cs.onSurfaceVariant, pl.mutedForeground);
      //
      // ⚠️ outline 对**深色**是例外，且有明确理由（不是放水）：
      //   `_buildDark` 的注释写：「边框角色不能带 alpha —— ColorScheme 的描边
      //   会被当实色画。这里按背景 #0A0A0A 把 border(白 10%) 合成成实色 #222222」。
      //   深色主题包的 palette.border 是**带 alpha 的**（如 FFFFFF@10%），
      //   若直接用会画出一条纯白硬边 ⇒ 所以深色下必须合成。
      //   ⇒ 深色跳过 outline；浅色的 border 是实色，必须严格相等。
      if (p.brightness == Brightness.light) {
        chk('outline', cs.outline, pl.border);
      }
      chk('onSecondary', cs.onSecondary, pl.secondaryForeground);
      chk('surface', cs.surface, pl.background);
    }
    expect(bad, isEmpty,
        reason: '这些字段在 _buildLight/_buildDark 的 copyWith 里被写死值盖住了：\n' +
            bad.join('\n'));
  });

  test('阳性对照：判定函数本身能识别不一致', () {
    // 同一色 => 通过
    expect(_hex(const Color(0xFFE38AA6)), _hex(const Color(0xFFE38AA6)));
    // 不同色 => 必须能分出（这就是上面断言用的比较方式）
    expect(_hex(const Color(0xFFE38AA6)) != _hex(const Color(0xFF3B6FE0)), isTrue,
        reason: '樱粉与品牌蓝必须被判定为不同；否则门禁永远绿');
  });
}