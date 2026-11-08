// Shared Miuix dialog integration; preserve panel tabs and controls.
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer;
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
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
  builder: (_, child) =>
      AppThemeHost(data: AppTheme.themeFor(Brightness.dark), child: child!),
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
  group('① 弹幕面板由实际 Miuix 对话框渲染', () {
    testWidgets('对话框布局、宿主与卡片实际包住整个面板', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();
      expect(find.byType(miuix.MiuixDialogLayout), findsOneWidget);
      expect(find.byType(miuix.MiuixPopupHost), findsOneWidget);
      expect(find.byType(GlassContainer), findsNothing);
      expect(
        find.descendant(
          of: find.byType(miuix.MiuixCard),
          matching: find.text('弹幕设置'),
        ),
        findsOneWidget,
      );
    });
  });

  group('② 共享外壳统一渲染 Miuix', () {
    for (final glass in [null, false, true]) {
      testWidgets('遗留 glass=$glass 不分叉组件表面', (t) async {
        final panel = glass == null
            ? const AppDialogShell(title: '面板', child: Text('内容'))
            : AppDialogShell(
                title: '面板',
                glass: glass,
                child: const Text('内容'),
              );
        await t.pumpWidget(_host(panel));
        await t.pumpAndSettle();
        expect(find.byType(miuix.MiuixDialogLayout), findsOneWidget);
        expect(find.byType(miuix.MiuixCard), findsOneWidget);
        expect(find.byType(GlassContainer), findsNothing);
        expect(find.text('面板'), findsOneWidget);
        expect(find.text('内容'), findsOneWidget);
        expect(t.takeException(), isNull);
      });
    }
  });

  group('③ 透明兼容宿主', () {
    testWidgets('Miuix 面板保留透明 Material 宿主', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();
      final hosts = t.widgetList<Material>(
        find.descendant(
          of: find.byType(miuix.MiuixCard),
          matching: find.byType(Material),
        ),
      );
      expect(
        hosts.any((material) => material.type == MaterialType.transparency),
        isTrue,
      );
      expect(t.takeException(), isNull);
    });
  });
  group('④ Miuix 迁移保留面板功能', () {
    testWidgets('★★★ 三个页签 / 开关 / 关闭钮 都在', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();

      expect(find.text('显示弹幕'), findsOneWidget, reason: '★ 总开关');
      for (final tab in <String>['显示', '弹幕来源', '高级']) {
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('danmaku-settings-tabs')),
            matching: find.text(tab),
          ),
          findsOneWidget,
          reason: '★ 页签「$tab」',
        );
      }
      expect(find.byType(ui.Switch), findsWidgets, reason: '★ 开关控件');
    });

    testWidgets('★★ 页签仍然能切换（玻璃没挡住点击）', (t) async {
      await t.pumpWidget(_host(_panel()));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: find.byKey(const ValueKey('danmaku-settings-tabs')),
          matching: find.text('弹幕来源'),
        ),
      );
      await t.pumpAndSettle();

      /*
       * ★ 这条防的是"玻璃层盖在上面把点击吃了" ——
       *   玻璃容器如果没设 `IgnorePointer` / 位置不对，就会挡住交互。
       */
      expect(
        find.text('本片源自带'),
        findsOneWidget,
        reason: '★★ 切到「弹幕来源」后必须真的看到内容 —— 玻璃不该挡点击',
      );
    });
  });
}
