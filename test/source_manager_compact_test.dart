import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';

const _longOriginName = '这是一条用于区分不同订阅的长来源名称保留其完整配置名称';

Future<void> _mount(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(360, 640);
  addTearDown(tester.view.reset);
  SourceDiscoveryService.current.value = null;
  // Source management is shared with the Android touch layout; 360px is a
  // supported phone viewport, not a proposal to lower Windows' 900px minimum.
  Device.overrideKind(DeviceKind.touchOnly);
  SourinCore.debugCallAsyncTransport = (command, _) async {
    switch (command) {
      case 'list_providers':
        return [
          for (final id in ['a', 'b'])
            {
              'id': id,
              'name': id == 'a' ? '目标源' : '其它源',
              'kind': 'tvbox',
              'enabled': true,
              'capabilities': {'vod': true, 'search': true},
            },
        ];
      case 'source_catalog_get':
        return {
          'origins': [
            {
              'id': 'long',
              'name': _longOriginName,
              'kind': 'tvbox',
              'primaryUrl': 'https://fixture.invalid/config',
              'providerIds': ['a'],
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
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: AppScaffold(child: SourceManagerPage(
      onSourcesChanged: () {},
      onImportTvbox: () async {},
      onPasteJs: () async {},
      onEditProvider: (_) async {},
      onConfigureProvider: (_) async {},
      onRemoveProvider: (_) async {},
    )),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('long selected origin stays within a narrow source manager', (tester) async {
    await _mount(tester);
    final picker = find.byKey(const ValueKey('source-origin-picker'));
    await tester.ensureVisible(picker);
    await tester.tap(picker);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('source-origin-option-long')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final label = find.descendant(of: picker, matching: find.text(_longOriginName));
    expect(label, findsOneWidget);
    final text = tester.widget<Text>(label);
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
    final bounds = tester.getRect(picker);
    expect(bounds.left, greaterThanOrEqualTo(0));
    expect(bounds.right, lessThanOrEqualTo(360));
    await tester.ensureVisible(find.byKey(const ValueKey('source-origin-edit')));
    await tester.tap(find.byKey(const ValueKey('source-origin-edit')));
    await tester.pumpAndSettle();
    final address = tester.widget<SourceAddressDialog>(find.byType(SourceAddressDialog));
    expect(address.origin.id, 'long');
    expect(address.origin.name, _longOriginName);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('source search keeps matching rows reachable above the soft keyboard', (tester) async {
    await _mount(tester);
    final editor = find.descendant(
      of: find.byKey(const ValueKey('source-manager-search')),
      matching: find.byType(EditableText),
    );
    final sourceList = find.byKey(const PageStorageKey('source-manager-list'));
    expect(tester.widget<ListView>(sourceList).scrollDirection, Axis.vertical);
    final scrollable = find.descendant(
      of: sourceList,
      matching: find.byWidgetPredicate(
        (widget) => widget is Scrollable && widget.axisDirection == AxisDirection.down,
        description: 'source manager vertical list scrollable',
      ),
    );
    expect(scrollable, findsOneWidget);
    await tester.ensureVisible(editor);
    await tester.tap(editor);
    await tester.pump();
    final controller = tester.widget<EditableText>(editor).controller;
    expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
    tester.view.viewInsets = const FakeViewPadding(bottom: 260);
    await tester.enterText(editor, '目标');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final match = find.byKey(const ValueKey('managed-source-a'));
    await tester.ensureVisible(match);
    await tester.pumpAndSettle();
    expect(match.hitTestable(), findsOneWidget);
    expect(find.byKey(const ValueKey('managed-source-b')), findsNothing);
    final bounds = tester.getRect(match);
    expect(bounds.top, greaterThanOrEqualTo(0));
    expect(bounds.bottom, lessThanOrEqualTo(640 - 260));
    // The lazy filter row may have been recycled after scrolling to results.
    // Scroll back as a user would before asking for its rendered editor.
    await tester.scrollUntilVisible(editor, -120,
        scrollable: scrollable, maxScrolls: 12);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(editor).controller, same(controller));
    expect(controller.text, '目标');
    await tester.tap(editor);
    await tester.pump();
    expect(tester.widget<EditableText>(editor).focusNode.hasFocus, isTrue);
    await tester.enterText(editor, '没有这个源');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('没有匹配的源'), 120,
        scrollable: scrollable, maxScrolls: 12);
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的源').hitTestable(), findsOneWidget);
    await tester.scrollUntilVisible(editor, -120,
        scrollable: scrollable, maxScrolls: 12);
    await tester.pumpAndSettle();
    expect(tester.widget<EditableText>(editor).controller, same(controller));
    expect(controller.text, '没有这个源');
    await tester.enterText(editor, '');
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(match, 120,
        scrollable: scrollable, maxScrolls: 12);
    await tester.pumpAndSettle();
    expect(match.hitTestable(), findsOneWidget);
    final other = find.byKey(const ValueKey('managed-source-b'));
    await tester.scrollUntilVisible(other, 120,
        scrollable: scrollable, maxScrolls: 12);
    await tester.pumpAndSettle();
    expect(other.hitTestable(), findsOneWidget);
    expect(find.text('没有匹配的源'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
