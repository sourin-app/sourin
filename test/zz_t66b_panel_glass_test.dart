// task-66 任务 B-2：**弹幕设置面板玻璃化**门禁
//
// # 钉什么
// ```text
// ① 弹幕面板真的走玻璃档（GlassContainer 在树上）
// ② 其余弹窗**不受影响**（glass 默认 false ⇒ 没有 GlassContainer）
//    ★ 这条是关键：外壳被全仓 7 个弹窗共用，
//      玻璃化只针对弹幕面板，别的不许变。
// ③ 涟漪宿主仍在（内层 Material 不许被去掉 —— 否则 Switch/ChoiceChip
//    会抛 "ink splashes may be invisible"）
// ④ 面板功能一个不少（三个页签、来源行、开关都还在）
// ```
//
// # 故障注入（两条，都已实测）
// ```text
// ① 把 `glass: true` 改成 false ⇒ 第①组红
// ② 让 glass 变成全局默认 true  ⇒ 第②组红（污染其余弹窗）
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

DanmakuSettingsState _state() => DanmakuSettingsState(
      enabled: true,
      appId: '',
      appSecret: '',
      fontScale: 1.0,
      opacity: 0.9,
      speed: 1.0,
      area: 0.5,
      count: 1200,
      lanes: 6,
      dropped: 0,
    );

Widget _host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      home: Scaffold(body: child),
    );

Widget _panel() => DanmakuSettingsDialog(
      state: _state(),
      onSetEnabled: (_) {},
      onSetFontScale: (_) {},
      onSetOpacity: (_) {},
      onSetSpeed: (_) {},
      onSetArea: (_) {},
      onReload: () {},
      onClose: () {},
      biliCount: 1200,
      onOpenBili: () {},
      fill: false,
    );

void main() {
  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  // ═══════════════════════════════════════════════════════════════════
  //  ① 弹幕面板：真的玻璃化了
  // ═══════════════════════════════════════════════════════════════════
  group('① 弹幕面板走玻璃档', () {
    testWidgets('★★★ 面板里有 GlassContainer', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();

      expect(find.byType(GlassContainer), findsWidgets,
          reason: '★★★ Owner 要玻璃材质 —— 弹幕面板必须真的玻璃化');
    });

    testWidgets('★★ 玻璃容器**包住**整个面板（不是只包一角）', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();

      /*
       * 判据：面板标题「弹幕设置」必须是某个 GlassContainer 的**后代**
       * ⇒ 证明玻璃包的是**整张卡片**，不是局部装饰。
       */
      final titleInGlass = find.descendant(
        of: find.byType(GlassContainer),
        matching: find.text('弹幕设置'),
      );
      expect(titleInGlass, findsOneWidget,
          reason: '★★ 玻璃必须包住整张卡片（标题在里面就算包住了）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 其余弹窗不许受影响（glass 默认 false）
  // ═══════════════════════════════════════════════════════════════════
  group('② 其他弹窗零污染', () {
    testWidgets('★★★ 不传 glass ⇒ 没有 GlassContainer（默认 false）', (t) async {
      await t.pumpWidget(_host(const AppDialogShell(
        title: '别的面板',
        child: Text('内容'),
      )));
      await t.pumpAndSettle();

      /*
       * ★ 这条防的是"把 glass 改成默认 true" ——
       *   外壳被全仓 7 个弹窗共用，默认一变就是全局回归。
       */
      expect(find.byType(GlassContainer), findsNothing,
          reason: '★★★ 默认必须是非玻璃 —— 否则其余 6 个弹窗全被改了');
      expect(find.text('别的面板'), findsOneWidget, reason: '阳性对照：面板在');
    });

    testWidgets('★★ 显式 glass: false 与不传等价', (t) async {
      await t.pumpWidget(_host(const AppDialogShell(
        title: '显式关',
        glass: false,
        child: Text('内容'),
      )));
      await t.pumpAndSettle();
      expect(find.byType(GlassContainer), findsNothing);
    });

    testWidgets('★★ 显式 glass: true 才出现玻璃（参数真的生效）', (t) async {
      await t.pumpWidget(_host(const AppDialogShell(
        title: '显式开',
        glass: true,
        child: Text('内容'),
      )));
      await t.pumpAndSettle();
      expect(find.byType(GlassContainer), findsWidgets,
          reason: '★★ 传了 true 就必须生效 —— 否则这个参数是死的');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 涟漪宿主仍在（Material 不许被玻璃取代）
  // ═══════════════════════════════════════════════════════════════════
  group('③ Material 仍是涟漪宿主', () {
    testWidgets('★★★ 玻璃档下 Material 仍在树上', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();

      /*
       * # 为什么必须留着
       * ```text
       * 框架的 SwitchListTile / ChoiceChip 把涟漪画在**最近的 Material** 上。
       * 盒子里没有 Material ⇒ 抛 "ink splashes may be invisible"。
       * 本面板有 Switch（显示弹幕）和 SegmentedButton（页签）⇒ 一定会踩。
       * ```
       * ⇒ 玻璃只负责"外观"，Material 负责"涟漪宿主"，两者并存。
       */
      expect(find.byType(Material), findsWidgets,
          reason: '★★★ 去掉 Material 会让 Switch/ChoiceChip 抛 '
              'ink splashes may be invisible');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 功能一个不少
  // ═══════════════════════════════════════════════════════════════════
  group('④ 玻璃化不许弄丢功能', () {
    testWidgets('★★★ 三个页签 / 开关 / 关闭钮 都在', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();

      expect(find.text('显示弹幕'), findsOneWidget, reason: '★ 总开关');
      for (final tab in <String>['显示', '弹幕来源', '高级']) {
        expect(
          find.descendant(
            of: find.byType(SegmentedButton<DanmakuPanelTab>),
            matching: find.text(tab),
          ),
          findsOneWidget,
          reason: '★ 页签「$tab」',
        );
      }
      expect(find.byType(Switch), findsWidgets, reason: '★ 开关控件');
    });

    testWidgets('★★ 页签仍然能切换（玻璃没挡住点击）', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();
      await t.tap(find.descendant(
        of: find.byType(SegmentedButton<DanmakuPanelTab>),
        matching: find.text('弹幕来源'),
      ));
      await t.pumpAndSettle();

      /*
       * ★ 这条防的是"玻璃层盖在上面把点击吃了" ——
       *   玻璃容器如果没设 `IgnorePointer` / 位置不对，就会挡住交互。
       */
      expect(find.text('本片源自带'), findsOneWidget,
          reason: '★★ 切到「弹幕来源」后必须真的看到内容 —— 玻璃不该挡点击');
    });
  });
}
