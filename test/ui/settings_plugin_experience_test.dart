import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

void main() {
  for (final width in [700.0, 360.0]) {
    testWidgets('card $width starts collapsed; body toggles; actions stay isolated', (t) async {
      t.view.physicalSize = const Size(1000, 1600);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      var edits = 0;
      var toggles = 0;
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        home: Scaffold(body: SingleChildScrollView(child: Center(child: SizedBox(
          width: width,
          child: settingsProviderCardForTest(
            provider: const ProviderManifest(id: 'exp-test', name: 'Experience fixture', kind: 'js'),
            cellWidth: width,
            onEdit: () => edits++,
            onToggle: () => toggles++,
          ),
        )))),
      ));
      await t.pump();
      expect(find.byType(ProxyPanel), findsNothing, reason: 'Entering the page must not expand every card');
      await t.tap(find.text('Experience fixture'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsOneWidget, reason: 'Body tap must reveal real detail panels');
      await t.tap(find.text('Experience fixture'));
      await t.pump();
      expect(find.byType(ProxyPanel), findsNothing);
      await t.tap(find.byTooltip('更多操作'));
      await t.pumpAndSettle();
      expect(find.byType(ProxyPanel), findsNothing);
      await t.tap(find.text('编辑'));
      await t.pumpAndSettle();
      expect(edits, 1);
      expect(find.byType(ProxyPanel), findsNothing, reason: 'Edit action must not expand the body');
      expect(toggles, 0, reason: 'Body and edit must not invoke enable/disable');
    });
  }
}
