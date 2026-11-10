import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';
import 'package:sourin_spike/ui/widgets/settings_sub_page.dart';

Widget host(Widget page) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: page,
  );
}

void main() {
  setUp(UiPrefs.debugResetForTest);
  tearDown(UiPrefs.debugResetForTest);

  testWidgets('saved danmaku instance stays visibly selected after reopening', (
    t,
  ) async {
    const instances = kDanmakuPublicInstances;
    expect(instances.length, greaterThan(1));
    await t.pumpWidget(host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    await t.ensureVisible(find.text(instances[1].label));
    await t.tap(find.text(instances[1].label));
    await t.pumpAndSettle();
    List<miuix.MiuixRadioButtonPreference> selected() => t
        .widgetList<miuix.MiuixRadioButtonPreference>(
          find.byType(miuix.MiuixRadioButtonPreference),
        )
        .where((w) => w.selected)
        .toList();
    expect(selected().single.title, instances[1].label);
    expect(UiPrefs.danmakuEndpoint, instances[1].baseUrl);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    expect(selected().single.title, instances[1].label);
    expect(find.text('当前使用：${instances[1].label}'), findsOneWidget);
    expect(t.takeException(), isNull);
  });

  testWidgets('custom endpoint selects no builtin and clear restores default', (
    t,
  ) async {
    UiPrefs.setDanmakuEndpoint('https://custom.invalid/danmaku');
    await t.pumpWidget(host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    expect(find.text('当前使用：自定义服务'), findsOneWidget);
    expect(
      t
          .widgetList<miuix.MiuixRadioButtonPreference>(
            find.byType(miuix.MiuixRadioButtonPreference),
          )
          .where((w) => w.selected),
      isEmpty,
    );
    await t.ensureVisible(find.text('清除'));
    await t.pumpAndSettle();
    await t.tap(find.text('清除'));
    await t.pumpAndSettle();
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(host(const DanmakuSourcePage()));
    await t.pumpAndSettle();
    expect(
      t
          .widgetList<miuix.MiuixRadioButtonPreference>(
            find.byType(miuix.MiuixRadioButtonPreference),
          )
          .where((w) => w.selected)
          .single
          .title,
      kDanmakuPublicInstances.first.label,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'secondary header stays centered and consumes inner back before popping',
    (t) async {
      t.view.devicePixelRatio = 1;
      t.view.physicalSize = const Size(360, 700);
      addTearDown(t.view.reset);
      var inner = true;
      await t.pumpWidget(
        host(
          Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsSubPage(
                      title: '二级页面',
                      subtitle: '说明',
                      onBack: (_) {
                        if (!inner) return false;
                        inner = false;
                        return true;
                      },
                      pinnedHeader: const Text('固定筛选'),
                      scrollBody: ListView(
                        children: List.generate(
                          40,
                          (i) => SizedBox(height: 50, child: Text('内容$i')),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      expect(find.byType(miuix.MiuixSmallTopAppBar), findsOneWidget);
      expect(t.getCenter(find.text('二级页面')).dx, closeTo(180, 2));
      final headerTop = t.getTopLeft(find.text('二级页面'));
      await t.drag(find.byType(ListView), const Offset(0, -400));
      await t.pumpAndSettle();
      expect(t.getTopLeft(find.text('二级页面')), headerTop);
      expect(find.text('固定筛选').hitTestable(), findsOneWidget);
      await t.tap(find.byKey(const ValueKey('page-header-back')));
      await t.pumpAndSettle();
      expect(inner, isFalse);
      expect(find.text('二级页面'), findsOneWidget);
      await t.sendKeyEvent(LogicalKeyboardKey.escape);
      await t.pumpAndSettle();
      expect(find.text('二级页面'), findsNothing);
      expect(find.text('打开'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
