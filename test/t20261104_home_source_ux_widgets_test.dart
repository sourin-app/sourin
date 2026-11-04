import 'dart:io';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/webhome/webhome_settings_page.dart';
import 'package:sourin_spike/ui/webhome/webhome_settings_sheet.dart';
import 'package:sourin_spike/ui/webhome/webhome_store.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(1280, 800)]) {
    testWidgets('home library and editor fit ${size.width}x${size.height}', (
      tester,
    ) async {
      late Directory dir;
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        WebHomeController.debugSetDataDir(null);
        UiPrefs.debugResetForTest();
        await tester.runAsync(() => dir.delete(recursive: true));
      });
      late WebHomeController controller;
      await tester.runAsync(() async {
        dir = await Directory.systemTemp.createTemp('home-widget-');
        WebHomeController.debugSetDataDir(dir.path);
        UiPrefs.debugResetForTest();
        controller = WebHomeController.instance;
        await controller.reload();
        await controller.saveTemplate(
          name: 'Very long named movie homepage configuration',
          html: '<h1>Movies</h1>',
          activate: true,
        );
      });
      await tester.pumpWidget(const MaterialApp(home: WebHomeSettingsPage()));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('webhome-native')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.tap(
        find.byKey(const ValueKey<String>('webhome-add-template')),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WebHomeTemplateEditor), findsOneWidget);
      final name = find.byKey(const ValueKey<String>('webhome-template-name'));
      final html = find.byKey(const ValueKey<String>('webhome-template-html'));
      final save = find.byKey(const ValueKey<String>('webhome-template-save'));
      expect(tester.getSize(name).width, greaterThan(100));
      expect(tester.getSize(html).height, greaterThan(24));
      expect(tester.getRect(save).right, lessThanOrEqualTo(size.width));
      expect(tester.getRect(save).bottom, lessThanOrEqualTo(size.height));
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(find.text('请填写首页名称（最多 128 个字符）'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(name, 'New');
      await tester.enterText(html, '<h1>New</h1>');
      await tester.runAsync(() async {
        await tester.tap(save);
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pumpAndSettle();
      expect(find.byType(WebHomeTemplateEditor), findsNothing);
      expect(controller.templates, hasLength(2));
      expect(
        controller.html,
        '<h1>Movies</h1>',
        reason: 'saving another template is not implicit activation',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
