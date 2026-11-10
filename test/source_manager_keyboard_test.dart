import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';

Future<void> _mount(
  WidgetTester tester, {
  Size size = const Size(1280, 800),
  bool touch = false,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.reset);
  if (touch) {
    Device.overrideKind(DeviceKind.touchOnly);
  }
  SourceDiscoveryService.current.value = null;
  SourinCore.debugCallAsyncTransport = (command, _) async {
    switch (command) {
      case 'list_providers':
        return [
          for (final id in ['enabled', 'disabled'])
            {
              'id': id,
              'name': id == 'enabled' ? '启用样本' : '停用样本',
              'kind': 'tvbox',
              'enabled': id == 'enabled',
              'capabilities': {'vod': true, 'search': true},
            },
        ];
      case 'source_catalog_get':
        return {
          'origins': [
            for (var index = 1; index <= 8; index++)
              {
                'id': 'origin-$index',
                'name': '来源 $index',
                'kind': 'tvbox',
                'primaryUrl': 'https://fixture.invalid/config/$index',
                'providerIds': [
                  if (index == 1) 'enabled',
                  if (index == 8) 'disabled',
                ],
              },
          ],
          'groups': <dynamic>[],
        };
      case 'source_discovery_status':
        return <String, dynamic>{};
      default:
        throw StateError('Unexpected native command: $command');
    }
  };
  addTearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourceDiscoveryService.current.value = null;
    Device.overrideKind(null);
  });
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: SourceManagerPage(
        onSourcesChanged: () {},
        onImportTvbox: () async {},
        onPasteJs: () async {},
        onEditProvider: (_) async {},
        onConfigureProvider: (_) async {},
        onRemoveProvider: (_) async {},
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _focusStatus(WidgetTester tester) async {
  final filter = find.byKey(const ValueKey('source-status-filter'));
  expect(filter, findsOneWidget);
  final label = find.descendant(
    of: filter,
    matching: find.byWidgetPredicate(
      (widget) => widget is Text && (widget.data?.contains('全部') ?? false),
    ),
  );
  expect(label, findsOneWidget);
  final innerFocus = Focus.of(tester.element(label));
  // Shared adapters exclude package focus nodes and own one outer control stop.
  final focus = [innerFocus, ...innerFocus.ancestors].firstWhere(
    (node) =>
        node is! FocusScopeNode && node.canRequestFocus && !node.skipTraversal,
  );
  expect(focus.canRequestFocus, isTrue);
  focus.requestFocus();
  await tester.pump();
  expect(focus.hasPrimaryFocus, isTrue);
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('source status opens with remote Select', (tester) async {
    await _mount(tester);
    await _focusStatus(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pumpAndSettle();
    expect(find.text('已启用'), findsOneWidget);
    expect(find.text('已停用'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _unmount(tester);
  });

  testWidgets(
    'source status changes rendered rows through keyboard selection',
    (tester) async {
      await _mount(tester);
      await _focusStatus(tester);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text('已启用'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('managed-source-enabled')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('managed-source-disabled')),
        findsNothing,
      );
      expect(find.text('已停用'), findsNothing);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );

  testWidgets(
    'origin search keeps its editor and scrollable choices above the keyboard',
    (tester) async {
      // This is the shared phone route, not a smaller Windows minimum window.
      await _mount(tester, size: const Size(360, 640), touch: true);
      final picker = find.byKey(const ValueKey('source-origin-picker'));
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      final popup = find.byType(miuix.MiuixListPopupContent);
      expect(popup, findsOneWidget);
      final editor = find.descendant(
        of: popup,
        matching: find.byType(EditableText),
      );
      expect(editor, findsOneWidget);
      // The popup's autofocus is not the soft-keyboard interaction under test.
      // Focus the actual rendered editor through the user tap path first.
      await tester.tap(editor);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
      expect(tester.getRect(popup).bottom, lessThanOrEqualTo(640));

      tester.view.viewInsets = const FakeViewPadding(bottom: 260);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        tester.getRect(popup).bottom,
        lessThanOrEqualTo(640 - 260),
        reason: 'The real popup surface must fit above the soft keyboard.',
      );
      final editorBounds = tester.getRect(editor);
      expect(editorBounds.top, greaterThanOrEqualTo(0));
      expect(editorBounds.bottom, lessThanOrEqualTo(640 - 260));
      final last = find.byKey(const ValueKey('source-origin-option-origin-8'));
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(640 - 260));
      await tester.enterText(editor, '来源 8');
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('source-origin-option-origin-1')),
        findsNothing,
      );
      expect(last.hitTestable(), findsOneWidget);
      expect(tester.getRect(last).bottom, lessThanOrEqualTo(640 - 260));
      await tester.tap(last);
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixListPopupContent), findsNothing);
      expect(
        find.descendant(of: picker, matching: find.text('来源 8')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    },
  );
}
