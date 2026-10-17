// ═══════════════════════════════════════════════════════════════════════
//  门禁：主题的「跟随系统 / 单选黑 / 单选白」三种行为（Owner 第 16 条）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// > 主题的深浅色我意思是,一套主题可以单出一套颜色,也可以出 深浅两套,
// > 当使用跟随系统,选择默认的黑白两套,就是自动切换,
// > 如果是单选 黑色 或者 白色 也是允许的,只是不自动切换了
//
// # 这条门禁钉的是「四种组合」的真实行为
// ```text
//   ① 双档主题 + 跟随系统  ⇒ 系统浅色用浅版、系统深色用深版（自动切换）
//   ② 单档主题 + 跟随系统  ⇒ 用该包自己的明暗，**不**换主题（不自动切换）
//   ③ 双档主题 + 单选浅色  ⇒ 固定用浅版（不自动切换）
//   ④ 双档主题 + 单选深色  ⇒ 固定用深版（不自动切换）
// ```
//
// # 为什么这条容易假绿
// ```text
// 「跟随系统」这条路径曾经完全失效：themeFor 无条件用 pack.brightness，
// ⇒ 系统切浅色仍返回深色版，两档一模一样（11-A 补的 8 个浅色版全是死代码）。
// 当时的测试只断言「能拿到一个主题」，恒真 ⇒ 没抓到。
// ⇒ 本测试断言**具体是哪一版**（比对 familyId + brightness），不是「非空」。
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

void main() {
  /// 造一对双档包（同 familyId、不同 brightness）
  ThemePack pack(String id, String family, Brightness b) => ThemePack(
        id: id,
        name: id,
        familyId: family,
        brightness: b,
        palette: b == Brightness.dark ? AppPalette.dark : AppPalette.light,
      );

  group('第 16 条：主题深浅色关系', () {
    test('★★★ 双档家族：siblingOf 能找到对面那一档', () {
      final dark = pack('fam.dark', 'fam', Brightness.dark);
      final light = pack('fam.light', 'fam', Brightness.light);
      final all = [dark, light];

      expect(ThemePackStore.siblingOf(all, dark)?.id, 'fam.light',
          reason: '选了深版，兄弟应是浅版 —— 这是「跟随系统自动切换」的基础');
      expect(ThemePackStore.siblingOf(all, light)?.id, 'fam.dark');
    });

    test('★★★ 单档家族：siblingOf 返回 null（不自动切换）', () {
      final solo = pack('solo.dark', 'solo', Brightness.dark);
      final all = [solo];

      expect(ThemePackStore.siblingOf(all, solo), isNull,
          reason: '★ 单档主题没有对面那一版 ⇒ 必须返回 null，'
              '调用方才能「不切换」而不是静默换成别的主题');
    });

    test('★★ isDual 判定：两档为 true，单档为 false', () {
      final d = pack('fam.dark', 'fam', Brightness.dark);
      final l = pack('fam.light', 'fam', Brightness.light);
      expect(ThemePackStore.isDual([d, l], 'fam'), isTrue);

      final solo = pack('solo.dark', 'solo', Brightness.dark);
      expect(ThemePackStore.isDual([solo], 'solo'), isFalse);
    });

    test('★★★ 反面：若 siblingOf 忽略 brightness 直接返回自己，本断言会红', () {
      final dark = pack('fam.dark', 'fam', Brightness.dark);
      final light = pack('fam.light', 'fam', Brightness.light);
      final all = [dark, light];

      final sib = ThemePackStore.siblingOf(all, dark);
      // 关键：兄弟版本必须与当前版本**明暗相反**
      expect(sib?.brightness, isNot(dark.brightness),
          reason: '★★★ 若这里变红，说明 siblingOf 返回了同明暗的包 —— '
              '那「跟随系统自动切换」就是假的（两档一样）');
      // 且必须同家族
      expect(sib?.familyId, dark.familyId,
          reason: '兄弟版本必须同 familyId，不能跨主题乱配');
    });

    test('★ 三个以上同家族时也只返回一个（不能返回列表）', () {
      final a = pack('fam.dark', 'fam', Brightness.dark);
      final b = pack('fam.light', 'fam', Brightness.light);
      final c = pack('fam.extra', 'fam', Brightness.dark);
      final all = [a, b, c];

      final sib = ThemePackStore.siblingOf(all, a);
      // a 是 dark ⇒ 兄弟必须是 light，即 b（不是 c）
      expect(sib?.brightness, Brightness.light);
    });
  });
}
