// 验证：每套主题的 colorScheme.primary 是否真的来自主题包（task-42）
//
// 命令：
//   flutter test --concurrency=1 test/zz_t69_primary_follows_pack_test.dart
//
// # 为什么要有这个门禁
// ```text
// task-42 之前 theme_bridge.dart 写死了 `primary: LightTokens.brand`，
// 把主题包的 primary 覆盖掉：
//   sakura 的 E38AA6(粉) 被换成 3B6FE0(蓝)
//   forest 的 2E7D4F(绿) 被换成 3B6FE0(蓝)
// 7 套里 6 套失效。
//
// 现有的 theme_invariants_test 只算**对比度**，
// 对比度满足时它不会发现「颜色被换了」——
// 蓝字配白底对比度 4.63，也是合法的。
// ⇒ 必须直接断言：cs.primary == pack.palette.primary。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/theme/theme_pack.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';

void main() {
  const lightIds = <String>[
    'builtin.daylight',
    'builtin.oled.light',
    'builtin.midnightBlue.light',
    'builtin.sakura.light',
    'builtin.forest.light',
    'builtin.glass.light',
    'builtin.neoBrutal.light',
    'builtin.minimal',
  ];

  test('存在这 8 套浅色主题', () {
    final all = ThemePackStore.builtins;
    final ids = all.map((p) => p.id).toSet();
    for (final id in lightIds) {
      expect(ids.contains(id), isTrue, reason: '缺少主题 $id');
    }
  });

  test('★ colorScheme.primary 必须等于主题包的 primary（task-42）', () {
    final all = ThemePackStore.builtins;
    final problems = <String>[];

    for (final id in lightIds) {
      final pack = all.firstWhere((p) => p.id == id);
      final td = buildAppTheme(Brightness.light, pack: pack);
      final cs = td.colorScheme;
      final want = pack.palette.primary;
      if (cs.primary != want) {
        problems.add(
          '  $id: cs.primary=${_hex(cs.primary)}  '
          'pack.primary=${_hex(want)}  不一致',
        );
      }
      // onPrimary 也必须跟着走：樱粉浅底上白字只有 2:1
      final wantFg = pack.palette.primaryForeground;
      if (cs.onPrimary != wantFg) {
        problems.add(
          '  $id: cs.onPrimary=${_hex(cs.onPrimary)}  '
          'pack.primaryForeground=${_hex(wantFg)}  不一致',
        );
      }
    }

    expect(problems, isEmpty,
        reason: '主题的强调色没有跟主题包走。'
            '用户选「樱粉」，按钮却是蓝的 ⇒ 主题形同虚设。\n'
            + problems.join('\n'));
  });

  test('每套主题的强调色互不相同（不能都是同一个蓝）', () {
    final all = ThemePackStore.builtins;
    final seen = <String, String>{};
    final dup = <String>[];
    for (final id in lightIds) {
      final pack = all.firstWhere((p) => p.id == id);
      final hx = _hex(pack.palette.primary);
      if (seen.containsKey(hx)) {
        dup.add('  $id 与 ${seen[hx]} 都是 $hx');
      } else {
        seen[hx] = id;
      }
    }
    expect(dup, isEmpty,
        reason: '两套主题的强调色完全相同 ⇒ 其中一套没生效。\n'
            + dup.join('\n'));
  });
}

String _hex(Color c) {
  final v = c.toARGB32();
  return '#${(v & 0xFFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';
}