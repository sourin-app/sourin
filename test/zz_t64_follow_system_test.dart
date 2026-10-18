// 2026-10-17（dlg-source 实测发现）——「跟随系统」必须切到同家族的兄弟版本
//
// # 缺陷现场
// ```text
// themeFor(b) 原来直接 themeForPack(b, selectedPack)，
// 而 themeForPack 无条件以包的明暗为准 ⇒ 选樱粉后系统切浅色仍返回深色。
// ⇒ 11-A 补的 8 个浅色版在「跟随系统」路径上全是死代码。
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

void main() {
  String? rawModeBackup;

  setUp(() {
    // ★ 保存原始值再改，测完原样写回 ——
    //   不往用户真实偏好文件里留多余的键（app_theme.dart 特意为此提供了 rawStored）
    rawModeBackup = AppTheme.rawStored;
  });

  tearDown(() {
    AppTheme.restoreRaw(rawModeBackup);
    ThemePackStore.select("");
  });

  test("★ 选樱粉 + 系统浅色 ⇒ 必须返回樱粉·浅（不是樱粉深色）", () {
    ThemePackStore.select("builtin.sakura");
    AppTheme.setMode(AppThemeMode.system);

    final light = AppTheme.themeFor(Brightness.light);
    final dark = AppTheme.themeFor(Brightness.dark);

    expect(light.brightness, Brightness.light,
        reason: "系统浅色时必须真的返回浅色主题");
    expect(dark.brightness, Brightness.dark,
        reason: "系统深色时必须真的返回深色主题");

    // ★ 核心：两档必须不同（这正是修前的缺陷）
    expect(identical(light, dark), isFalse);
    expect(light.colorScheme.brightness, Brightness.light,
        reason: "浅色档的 colorScheme 也必须真的变浅");
  });

  test("★ 每套双色主题都能跟随系统切换（8 个浅色版不是死代码）", () {
    final all = ThemePackStore.builtins;
    final fams = <String>{for (final p in all) p.familyId};

    final broken = <String>[];
    for (final fam in fams) {
      final dark = ThemePackStore.findByFamily(all, fam, Brightness.dark);
      final light = ThemePackStore.findByFamily(all, fam, Brightness.light);
      if (dark == null || light == null) continue;

      ThemePackStore.select(dark.id);
      final asLight = AppTheme.themeFor(Brightness.light);
      if (asLight.brightness != Brightness.light) {
        broken.add("$fam（选深色版 + 系统浅色 ⇒ 仍是深色）");
      }

      ThemePackStore.select(light.id);
      final asDark = AppTheme.themeFor(Brightness.dark);
      if (asDark.brightness != Brightness.dark) {
        broken.add("$fam（选浅色版 + 系统深色 ⇒ 仍是浅色）");
      }
    }

    expect(broken, isEmpty,
        reason: "以下家族无法跟随系统切换：\n${broken.join("\n")}");
  });

  test("单档家族（无兄弟版本）⇒ 保持自己的明暗，不静默换主题", () {
    // 造一个单档家庭：midnight 的 familyId 被改成别人没有的
    ThemePackStore.select("builtin.midnight");
    AppTheme.setMode(AppThemeMode.dark);

    final t = AppTheme.themeFor(Brightness.dark);
    expect(t.brightness, Brightness.dark);
  });
}
