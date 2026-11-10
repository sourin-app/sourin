import 'dart:async';

import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

import 'support/miuix_finders.dart';

Future<void> _mount(WidgetTester tester, {VoidCallback? onChanged}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1000);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: AppScaffold(
        child: SourceManagerPage(
          onSourcesChanged: onChanged ?? () {},
          onImportTvbox: () async {},
          onPasteJs: () async {},
          onEditProvider: (_) async {},
          onConfigureProvider: (_) async {},
          onRemoveProvider: (_) async {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  setUp(() => SourceDiscoveryService.current.value = null);
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourceDiscoveryService.current.value = null;
  });

  testWidgets(
    'selected empty origin can edit its own addresses without a child row',
    (tester) async {
      final emptyOrigin = <String, dynamic>{
        'id': 'empty',
        'name': '空订阅',
        'kind': 'tvbox',
        'primaryUrl': 'https://empty.invalid/main',
        'backupUrls': ['https://empty.invalid/backup'],
        'providerIds': <String>[],
      };
      final otherOrigin = <String, dynamic>{
        'id': 'other',
        'name': '其它订阅',
        'kind': 'tvbox',
        'primaryUrl': 'https://other.invalid/main',
        'providerIds': ['other-child'],
      };
      Map<String, dynamic> catalog() => {
        'origins': [emptyOrigin, otherOrigin],
        'groups': <dynamic>[],
      };
      final writes = <Map<String, dynamic>>[];
      var notifications = 0;
      SourinCore.debugCallAsyncTransport = (command, args) async {
        switch (command) {
          case 'list_providers':
            return [
              {
                'id': 'other-child',
                'name': '其它子源',
                'kind': 'tvbox',
                'enabled': true,
              },
            ];
          case 'source_catalog_get':
            return catalog();
          case 'source_catalog_set_origin':
            final update = args!;
            writes.add({...update});
            expect(update['id'], 'empty');
            emptyOrigin.addAll(update);
            return catalog();
          case 'source_discovery_status':
            return <String, dynamic>{};
          default:
            throw StateError('Unexpected native command: $command');
        }
      };
      await _mount(tester, onChanged: () => notifications++);
      await tester.tap(find.byKey(const ValueKey('source-origin-picker')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey('source-origin-option-empty')),
      );
      await tester.pumpAndSettle();
      final summary = find.byKey(const ValueKey('source-origin-summary'));
      final edit = find.byKey(const ValueKey('source-origin-edit'));
      expect(summary, findsOneWidget);
      expect(
        find.descendant(of: summary, matching: find.text('空订阅 · 0 个源')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('managed-source-other-child')),
        findsNothing,
      );
      expect(find.text('没有匹配的源'), findsOneWidget);
      expect(
        // ui.TextButton inherits _ActionButton, whose actual Miuix surface is
        // MiuixButton. Keep the assertion on the rendered component.
        find.descendant(of: edit, matching: find.byType(miuix.MiuixButton)),
        findsOneWidget,
      );
      await tester.tap(edit);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SourceAddressDialog>(find.byType(SourceAddressDialog))
            .origin
            .id,
        'empty',
      );
      await tester.tap(
        find.descendant(
          of: find.byType(SourceAddressDialog),
          matching: miuixTooltip('关闭'),
        ),
      );
      await tester.pumpAndSettle();
      expect(writes, isEmpty);
      expect(notifications, 0);
      await tester.tap(edit);
      await tester.pumpAndSettle();
      Finder field(String key) => find.descendant(
        of: find.byKey(ValueKey(key)),
        matching: find.byType(EditableText),
      );
      await tester.enterText(field('source-address-name'), '空订阅已更新');
      await tester.enterText(
        field('source-address-primary'),
        'https://empty.invalid/new',
      );
      await tester.enterText(
        field('source-address-backups'),
        'https://empty.invalid/backup-b\nhttps://empty.invalid/backup-a',
      );
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();
      expect(writes, [
        {
          'id': 'empty',
          'name': '空订阅已更新',
          'primaryUrl': 'https://empty.invalid/new',
          'backupUrls': [
            'https://empty.invalid/backup-b',
            'https://empty.invalid/backup-a',
          ],
        },
      ]);
      expect(notifications, 1);
      expect(find.byType(SourceAddressDialog), findsNothing);
      expect(
        find.descendant(of: summary, matching: find.text('空订阅已更新 · 0 个源')),
        findsOneWidget,
      );
      expect(otherOrigin['primaryUrl'], 'https://other.invalid/main');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets(
    'initial source load failure offers bounded retry without a false empty match',
    (tester) async {
      var reads = 0;
      var notifications = 0;
      final retry = Completer<Map<String, dynamic>>();
      addTearDown(() {
        if (!retry.isCompleted) {
          retry.complete({'origins': <dynamic>[], 'groups': <dynamic>[]});
        }
      });
      SourinCore.debugCallAsyncTransport = (command, _) async {
        switch (command) {
          case 'list_providers':
            return [
              {'id': 'available', 'name': '可用源', 'kind': 'js', 'enabled': true},
            ];
          case 'source_catalog_get':
            if (++reads == 1) throw SourinCoreException('来源清单读取失败', 'network');
            return retry.future;
          case 'source_discovery_status':
            return <String, dynamic>{};
          default:
            throw StateError('Unexpected native command: $command');
        }
      };
      await _mount(tester, onChanged: () => notifications++);
      expect(find.text('来源清单读取失败'), findsOneWidget);
      expect(find.text('没有匹配的源'), findsNothing);
      final retryButton = find.byKey(const ValueKey('source-manager-retry'));
      expect(tester.widget<ui.TextButton>(retryButton).onPressed, isNotNull);
      await tester.tap(retryButton);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(reads, 2);
      expect(tester.widget<ui.TextButton>(retryButton).onPressed, isNull);
      await tester.tap(retryButton);
      await tester.pump();
      expect(reads, 2);
      expect(find.text('没有匹配的源'), findsNothing);
      retry.complete({'origins': <dynamic>[], 'groups': <dynamic>[]});
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('managed-source-available')),
        findsOneWidget,
      );
      expect(find.text('来源清单读取失败'), findsNothing);
      expect(retryButton, findsNothing);
      expect(notifications, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    },
  );

  testWidgets('successful empty source load keeps the empty match state', (
    tester,
  ) async {
    SourinCore.debugCallAsyncTransport = (command, _) async {
      return switch (command) {
        'list_providers' => <dynamic>[],
        'source_catalog_get' ||
        'source_discovery_status' => <String, dynamic>{},
        _ => throw StateError('Unexpected native command: $command'),
      };
    };
    await _mount(tester);
    expect(find.text('没有匹配的源'), findsOneWidget);
    expect(find.byKey(const ValueKey('source-manager-retry')), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });
}
