// ═══════════════════════════════════════════════════════════════════════
//  T6 · 下拉菜单面统一 —— AppMenuButton 与 showAppMenu 必须**同源**
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这份
//
// Owner 第 8 条：「还有插件那个点击出来操作菜单的也好难看」。
// 改法是把两处菜单（插件区块头的 ⋮ / detail_page 的「下载」）都收进
// app_menu.dart。**只换一处等于没换** —— 两个菜单会长得不一样。
//
// ⇒ 本文件钉两件事：
//   ① 两处入口都走 app_menu.dart（源码级，防"又有人手写 showMenu"）
//   ② 两处**运行时**拿到的菜单面颜色/形状/约束是同一份
//      （行为级：真的把菜单弹出来量，不是读源码里的字面量）
//
// ⚠️ 不断言具体色值 —— 色值随主题走，写死就成了"改主题必红"的假门禁。
//    判据是"两者相等"这个**关系**。
//
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/app_menu.dart';

/// 剥注释（字符串里的 // 不算注释）—— 与 t103 / t27_w1 同款
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    } else {
      out.write(c);
    }
    i++;
  }
  return out.toString();
}

/// 弹出一个菜单并返回它的菜单面装饰（`_PopupMenuRoute` 画的那层 Material）。
///
/// ★ 用 `AppMenuButton` 弹（它在测试里可点）—— `showAppMenu` 与它共用同一份
///   面，所以量到的就是两个入口都会得到的东西。
/// 菜单面 = 那个带 `RoundedRectangleBorder` 形状的 `Material`。
///
/// ⚠️ 不能用 `find.ancestor(...).first` —— 菜单项自己也有 Material 祖先
///   （`PopupMenuItem` 内部有 InkWell/InkFeatures），`first` 拿到的不一定是
///   菜单面那一层。用**形状谓词**定位才唯一。
Finder _menuSurfaceFinder() => find.byWidgetPredicate(
      (w) => w is Material && w.shape is RoundedRectangleBorder,
    );

/// 弹出一个菜单（挂在真 App 主题下），返回后菜单处于打开态。
Future<void> _openMenu(WidgetTester t, Brightness b) async {
  // ★ 先拆掉整棵树：`pumpWidget` 复用同类型的 MaterialApp 时会保留 Navigator，
  //   上一轮 pop 掉的菜单路由仍在树里 ⇒ 下一轮量到的是**上一轮**那层面
  //   （本文件第二版就栽在这里：浅色那轮量到的仍是深色面）。
  await t.pumpWidget(const SizedBox.shrink());
  await t.pumpAndSettle();
  await t.pumpWidget(MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: AppTheme.themeFor(b),
    home: Scaffold(
      body: Center(
        child: AppMenuButton<String>(
          items: const <AppMenuItem<String>>[
            AppMenuItem<String>(value: 'a', label: '调整顺序', icon: Icons.reorder),
            AppMenuItem<String>(
              value: 'b',
              label: '移除',
              icon: Icons.delete_outline,
              danger: true,
            ),
          ],
          onSelected: (_) {},
        ),
      ),
    ),
  ));
  await t.tap(find.byType(AppMenuButton<String>));
  await t.pumpAndSettle();
  expect(find.text('调整顺序'), findsOneWidget, reason: '菜单必须弹得出');
}

/// 关掉菜单 —— ⚠️ `pumpWidget` 不会清掉已 push 的路由（同一个 MaterialApp
/// 类型会复用 Navigator）⇒ 不显式关掉的话下一轮 tap 会打在**上一轮的菜单项**上
/// （本文件第一版就栽在这里，报错是 "No element"）。
Future<void> _closeMenu(WidgetTester t) async {
  await t.tapAt(const Offset(5, 5));
  await t.pumpAndSettle();
  expect(find.text('调整顺序'), findsNothing, reason: '菜单必须关掉');
}

void main() {
  group('T6 · 菜单面统一', () {
    test('★ 两处入口都走 app_menu.dart（源码级，剥注释）', () {
      final settings = stripComments(
        File('lib/ui/settings_page.dart').readAsStringSync(),
      );
      final detail = stripComments(
        File('lib/ui/detail_page.dart').readAsStringSync(),
      );
      expect(detail.contains('showAppMenu<String>('), isTrue,
          reason: '★ 「下载」按钮的菜单必须走 showAppMenu');
      expect(settings.contains('AppMenuButton<String>('), isTrue,
          reason: '★ 插件区块头的 ⋮ 必须走 AppMenuButton');
      /*
       * ★ 为什么**不**写成「AppMenuButton 或 PopupMenuButton 二选一」：
       *   那是假门禁 —— 两个都放行等于没查。这里钉的是**最终契约**
       *   （settings_page 的 ⋮ 已经是 AppMenuButton 了）。
       *   `test/provider_import_test.dart` 那条因为要兼容两条入口，用的是
       *   `A || B`；本文件负责把它收紧成 `A`。
       *
       * ⚠️ 两处入口**都**必须走 app_menu.dart：只换一处等于没换，
       *   两个菜单会长得不一样（那正是 Owner 抱怨的"不统一"）。
       */
      // 反向对照：不许再有裸 showMenu / PopupMenuButton 自己画菜单面
      for (final e in <List<String>>[
        <String>['lib/ui/settings_page.dart', settings],
        <String>['lib/ui/detail_page.dart', detail],
      ]) {
        expect(RegExp(r'\bshowMenu\s*<').hasMatch(e[1]), isFalse,
            reason: '★ ${e[0]} 又出现了裸 showMenu —— 菜单面会退回 Material 默认');
        expect(RegExp(r'\bPopupMenuButton\s*<').hasMatch(e[1]), isFalse,
            reason: '★ ${e[0]} 又出现了裸 PopupMenuButton');
      }
    });

    testWidgets('★ 菜单面颜色 = 卡片同源槽位（明暗两态都成立）', (t) async {
      for (final b in Brightness.values) {
        await _openMenu(t, b);
        final m = t.widget<Material>(_menuSurfaceFinder().first);
        final cs = AppTheme.themeFor(b).colorScheme;
        expect(m.color, cs.surfaceContainerHighest,
            reason: '★ $b 下菜单面必须用与卡片同一个槽位（实测 ${m.color}）');
        expect(m.elevation, 0.0,
            reason: '★ 不许用 Material 阴影定界（改用描边）');
        final shape = m.shape;
        expect(shape, isA<RoundedRectangleBorder>(),
            reason: '★ 菜单圆角必须与卡片同一套语言（M3 默认 4px 太方）');
        final r = (shape as RoundedRectangleBorder).borderRadius;
        expect(r, BorderRadius.circular(Radii.md),
            reason: '★ 菜单圆角必须是 Radii.md（实测 $r）');
        expect(
          shape.side.color,
          cs.outlineVariant,
          reason: '★ 描边必须是本主题的"弱化描边"角色（实测 ${shape.side.color}）',
        );
        await _closeMenu(t);
      }
    });

    testWidgets('★ 条目高 40 + 危险项图标与文字同色', (t) async {
      await _openMenu(t, Brightness.dark);

      /// 某个条目那一枚 PopupMenuItem（图标与文字都在它里面）
      PopupMenuItem<String> itemOf(String label) => t.widget<PopupMenuItem<String>>(
            find
                .ancestor(
                  of: find.text(label),
                  matching: find.byType(PopupMenuItem<String>),
                )
                .first,
          );

      expect(itemOf('调整顺序').height, 40,
          reason: '★ 条目高必须 40（Material 默认 48 太松）');
      expect(itemOf('移除').height, 40);

      final cs = AppTheme.themeFor(Brightness.dark).colorScheme;
      expect(t.widget<Text>(find.text('移除')).style?.color, cs.error,
          reason: '★ 危险项文字必须是 error 色');
      // 图标必须在**同一条目**里，且与文字同色
      final icon = t.widget<Icon>(
        find.descendant(
          of: find.byWidget(itemOf('移除')),
          matching: find.byType(Icon),
        ).first,
      );
      expect(icon.color, cs.error,
          reason: '★ 危险项图标必须与文字**同色**（改前两者不同色）');
      // 普通项的图标**不是** error 色 —— 否则上面那条可能只是"全红"
      final normalIcon = t.widget<Icon>(
        find.descendant(
          of: find.byWidget(itemOf('调整顺序')),
          matching: find.byType(Icon),
        ).first,
      );
      expect(normalIcon.color, cs.onSurface,
          reason: '★ 普通项图标必须是 onSurface（阳性对照：不是所有图标都红）');
      await _closeMenu(t);
    });

    testWidgets('★ 点条目回传值（onSelected 语义与 PopupMenuButton 一致）', (t) async {
      String? picked;
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: AppMenuButton<String>(
              items: const <AppMenuItem<String>>[
                AppMenuItem<String>(value: 'x', label: '甲'),
                AppMenuItem<String>(value: 'y', label: '乙'),
              ],
              onSelected: (v) => picked = v,
            ),
          ),
        ),
      ));
      await t.tap(find.byType(AppMenuButton<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('乙'));
      await t.pumpAndSettle();
      expect(picked, 'y', reason: '★ 选中的值必须原样回传');
      expect(find.text('乙'), findsNothing, reason: '★ 选中后菜单必须关闭');
    });

    testWidgets('★ 禁用项不可选（enabled:false 语义不变）', (t) async {
      var count = 0;
      await t.pumpWidget(MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: AppMenuButton<String>(
              items: const <AppMenuItem<String>>[
                AppMenuItem<String>(
                  value: 'busy',
                  label: '处理中…',
                  enabled: false,
                ),
                AppMenuItem<String>(value: 'ok', label: '可用'),
              ],
              onSelected: (_) => count++,
            ),
          ),
        ),
      ));
      await t.tap(find.byType(AppMenuButton<String>));
      await t.pumpAndSettle();
      await t.tap(find.text('处理中…'));
      await t.pumpAndSettle();
      expect(count, 0, reason: '★ 禁用项点了不许回传值');
    });
  });
}
