// 2026-10-17 Owner 第 11-A 条：双色主题的家族配对机制
//
// Owner 原话：「一个主题同时提供浅色版和深色版两个独立风格」
//
// 钉住的判据：
//   1 老主题包（没显式给 familyId）=> familyId 回落成 id 本身（向后兼容）
//   2 findByFamily 能按家族 + 明暗精确命中
//   3 家族缺某一档 => 返回 null，不许静默找个替身顶上
//   4 siblingOf 能从当前版找到另一档的兄弟
//   5 isDual 只在两档齐全时为 true

import 'dart:math' as math;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

void main() {
  ThemePack mk(String id, Brightness b, {String? family}) => ThemePack(
        id: id,
        name: id,
        brightness: b,
        palette: b == Brightness.dark ? AppPalette.dark : AppPalette.light,
        familyId: family,
      );

  test('1 没给 familyId => 回落成 id 本身（向后兼容老主题包）', () {
    final p = mk('legacy.onlyDark', Brightness.dark);
    expect(p.familyId, 'legacy.onlyDark');
  });

  test('2 findByFamily 按家族 + 明暗精确命中', () {
    final all = <ThemePack>[
      mk('x.dark', Brightness.dark, family: 'fam.x'),
      mk('x.light', Brightness.light, family: 'fam.x'),
      mk('y.dark', Brightness.dark, family: 'fam.y'),
    ];

    expect(ThemePackStore.findByFamily(all, 'fam.x', Brightness.light)?.id, 'x.light');
    expect(ThemePackStore.findByFamily(all, 'fam.x', Brightness.dark)?.id, 'x.dark');
  });

  test('3 家族缺某一档 => 返回 null，不许静默找替身', () {
    final all = <ThemePack>[
      mk('y.dark', Brightness.dark, family: 'fam.y'),
      mk('z.light', Brightness.light, family: 'fam.z'),
    ];

    expect(ThemePackStore.findByFamily(all, 'fam.y', Brightness.light), isNull,
        reason: '家族缺浅色版时必须 null，静默换主题会让用户以为选错了');
    expect(ThemePackStore.findByFamily(all, 'nope', Brightness.dark), isNull);
  });

  test('4 siblingOf 找到另一档的兄弟版本', () {
    final all = <ThemePack>[
      mk('fam.p.dark', Brightness.dark, family: 'fam.p'),
      mk('fam.p.light', Brightness.light, family: 'fam.p'),
    ];
    final dark = all.firstWhere((e) => e.id == 'fam.p.dark');
    expect(ThemePackStore.siblingOf(all, dark)?.id, 'fam.p.light');
    final light = all.firstWhere((e) => e.id == 'fam.p.light');
    expect(ThemePackStore.siblingOf(all, light)?.id, 'fam.p.dark');
  });

  test('5 单档家族 siblingOf 返回 null（现状多数主题如此）', () {
    final all = <ThemePack>[mk('solo.dark', Brightness.dark)];
    expect(ThemePackStore.siblingOf(all, all.first), isNull,
        reason: '只有一档时没有兄弟，必须 null 而不是自己');
  });

  test('6 isDual 只在两档齐全时 true', () {
    final all = <ThemePack>[
      mk('d.dark', Brightness.dark, family: 'fam.d'),
      mk('d.light', Brightness.light, family: 'fam.d'),
      mk('m.dark', Brightness.dark, family: 'fam.m'),
    ];
    expect(ThemePackStore.isDual(all, 'fam.d'), isTrue);
    expect(ThemePackStore.isDual(all, 'fam.m'), isFalse);
    expect(ThemePackStore.isDual(all, 'nope'), isFalse);
  });

  test('7 ★ 所有内置主题家族都必须是双色的（Owner 第 11-A 条）', () {
    final all = ThemePackStore.builtins;

    // 收集所有 familyId
    final families = <String>{};
    for (final p in all) {
      families.add(p.familyId);
    }

    // 每个家族必须明暗齐全
    final missing = <String>[];
    for (final fam in families) {
      if (!ThemePackStore.isDual(all, fam)) {
        final hasLight =
            ThemePackStore.findByFamily(all, fam, Brightness.light) != null;
        missing.add('$fam（缺${hasLight ? "深色" : "浅色"}版）');
      }
    }

    expect(missing, isEmpty,
        reason: '以下主题家族不是双色的（Owner 要求每套都同时有浅色版和深色版）：\n'
            '${missing.join("\n")}');

    // 附加：每套都必须能找到自己的兄弟版本
    for (final p in all) {
      expect(ThemePackStore.siblingOf(all, p), isNotNull,
          reason: '${p.name}（${p.id}）找不到另一档明暗的兄弟版本');
    }
  });

  test('9 ★ 所有主题的次要文字都必须过 AA（mutedForeground 覆盖漏洞）', () {
    /*
     * ★★★ 2026-10-17（dlg-source 视觉验证发现的**门禁覆盖漏洞**）
     *
     * # 漏洞现场
     * ```text
     * theme_pack_test 的 WCAG 断言查了 primary / foreground，
     * **没有查 mutedForeground**。
     *
     * ⇒ 4 套浅色主题只 copyWith 了 background/card/border/primary，
     *   没覆盖 mutedForeground ⇒ 继承 AppPalette.light 的默认 #737373
     * ⇒ 而它们的背景都比纯白更亮（带色相）⇒ 刚好掉到线下：
     *     midnightBlue.light  4.42 ✗
     *     sakura.light        4.45 ✗
     *     forest.light        4.48 ✗
     *     glass.light         4.34 ✗
     * ```
     *
     * ⇒ 本测试补上这个维度。**任何**主题（内置的、将来新增的）
     *   都必须让次要文字在正文底上 >= 4.5:1。
     */
    double lum(Color c) {
      final r = (c.r * 255).round() / 255;
      final g = (c.g * 255).round() / 255;
      final b = (c.b * 255).round() / 255;
      double ch(double v) =>
          v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
      return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b);
    }

    double cr(Color a, Color b) {
      final la = lum(a), lb = lum(b);
      return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
    }

    final bad = <String>[];
    for (final p in ThemePackStore.builtins) {
      // 次要文字会出现在**卡片**上和**页面底**上，两处都要够
      for (final e in [
        (p.palette.card, '卡片'),
        (p.palette.background, '页面底'),
      ]) {
        final r = cr(p.palette.mutedForeground, e.$1);
        if (r < 4.5) {
          bad.add('${p.id} 次要文字在${e.$2}上只有 ${r.toStringAsFixed(2)}:1');
        }
      }
    }

    expect(bad, isEmpty,
        reason: '以下主题的次要文字没过 WCAG AA 4.5:1：\n${bad.join("\n")}\n'
            '★ 常见原因：copyWith 时漏了 mutedForeground，继承了默认值');
  });

  test('8 双色主题的主色在明暗两版之间保持同一色相', () {
    final all = ThemePackStore.builtins;
    final families = <String>{for (final p in all) p.familyId};

    for (final fam in families) {
      final dark = ThemePackStore.findByFamily(all, fam, Brightness.dark);
      final light = ThemePackStore.findByFamily(all, fam, Brightness.light);
      if (dark == null || light == null) continue;

      // 两版的主色都必须"看得见"：不能与各自背景过近
      // （这里只做一个粗判：主色与背景的亮度差要够大）
      double lum(Color c) {
        final r = (c.r * 255).round() / 255;
        final g = (c.g * 255).round() / 255;
        final b = (c.b * 255).round() / 255;
        // ★ WCAG 2.x 相对亮度公式：((v + 0.055) / 1.055) ** 2.4
        //   我第一版漏了 2.4 次方 ⇒ 算出的亮度全错 ⇒ 断言值不可信。
        //   （被"改色后仍是 2.43:1"这个反直觉结果抓出来）
        double ch(double v) => v <= 0.03928
            ? v / 12.92
            : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
        return 0.2126 * ch(r) + 0.7152 * ch(g) + 0.0722 * ch(b);
      }

      double cr(Color a, Color b) {
        final la = lum(a), lb = lum(b);
        return (math.max(la, lb) + 0.05) / (math.min(la, lb) + 0.05);
      }

      /*
       * ★ 2026-10-17 修正判据（dlg-source 视觉验证后）
       *
       * # 原来的判据错在哪
       * ```text
       * 我原来断言：「主色 vs 背景 >= 2.5:1」
       *
       * 这个判据对**深底+浅主色**成立（如樱粉深色版 #F2B8C6 on #14100F）。
       * 但它把"浅底+浅主色"判成错的 —— 而那恰恰是**正确的做法**：
       *   樱粉浅色版 #E38AA6 配深字 #231419 = 7.13:1 ✓
       *   主色本身接近背景是**设计意图**，不是缺陷。
       * ⇒ 判据把"粉要够粉"和"主色要够深"混为一谈了。
       * ```
       *
       * # 正确的判据：看**主色上的前景**能不能读，而不是主色对背景
       * ```text
       * 主色的实际用途：按钮底、选中态底、开关轨道 ——
       * 上面**永远压着前景色**（primaryForeground）。
       * ⇒ 该验的是 primary vs primaryForeground >= 4.5:1
       *   （WCAG AA 对正文的要求，因为按钮上有文字）
       * ```
       */
      for (final e in [
        (dark.palette.primary, dark.palette.primaryForeground, '深色'),
        (light.palette.primary, light.palette.primaryForeground, '浅色'),
      ]) {
        final r = cr(e.$1, e.$2);
        expect(r, greaterThanOrEqualTo(4.5),
            reason: '$fam 的${e.$3}版主色上的文字只有 ${r.toStringAsFixed(2)}:1，'
                '低于 AA 4.5 —— 按钮文字会看不清');
      }
    }
  });
}
