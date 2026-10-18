// ═══════════════════════════════════════════════════════════════════════
//  统一测试宿主 —— 给测试用的 AppThemeScope 包装
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么必须存在（2026-10-17 实测）
// ```text
// 全仓 228 个测试文件用 MaterialApp，只有 3 个包了 AppThemeScope。
//
// 产品代码一旦换成 App* 组件（去 Material 迁移），这些宿主会**集体崩**：
//   AppTheme.of() 找不到 AppThemeScope 祖先。
//
// ★ 而且报的是**主题错**，与断言无关 —— 会让人以为是主题配置问题，
//   白折腾很久才发现是宿主缺包装。
// ```
//
// # 用法
// ```dart
// await tester.pumpWidget(AppTestHost(child: MyWidget()));
// ```
//
// ⚠️ import 路径注意：palette/typeface/themePack 在 `ui/` 下，
//    **不在** `design/theme/` 下。我第一次就写错了。

import 'package:flutter/widgets.dart';
import 'package:material_ui/material_ui.dart' show MaterialApp, Scaffold;

import 'package:sourin_spike/design/theme/app_theme.dart';
import 'package:sourin_spike/design/theme/app_theme_data.dart';
import 'package:sourin_spike/ui/app_palette.dart';
import 'package:sourin_spike/ui/app_typeface.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';

/// 测试宿主：注入 [AppThemeScope]，再套 MaterialApp。
///
/// 默认用第一套内置主题（`builtin.midnight`，深色）。
/// 需要浅色时传 [brightness]。
class AppTestHost extends StatelessWidget {
  const AppTestHost({
    super.key,
    required this.child,
    this.brightness,
    this.withScaffold = true,
  });

  final Widget child;

  /// null ⇒ 用主题包自己的明暗
  final Brightness? brightness;

  /// false ⇒ 不套 Scaffold（测纯组件时用）
  final bool withScaffold;

  @override
  Widget build(BuildContext context) {
    final pack = _pickPack();
    final b = brightness ?? pack.brightness;

    final body = withScaffold ? Scaffold(body: child) : child;

    return AppThemeScope(
      data: AppThemeData(
        palette: b == Brightness.dark ? AppPalette.dark : AppPalette.light,
        typeface: AppTypeface.forPlatform(b),
        pack: pack,
      ),
      child: MaterialApp(home: body),
    );
  }

  ThemePack _pickPack() {
    final all = ThemePackStore.builtins;
    final want = brightness;
    if (want == null) return all.first;
    // 找第一套匹配明暗的；找不到就用第一套（宁可跑起来也别崩）
    for (final p in all) {
      if (p.brightness == want) return p;
    }
    return all.first;
  }
}
