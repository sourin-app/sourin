import 'dart:async';

import 'package:flutter/services.dart';
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

void main() {
  for (final retry in [false, true]) {
    testWidgets(
      'provider save freezes selection, preserves a failed draft and ${retry ? 'retries' : 'cancels'}',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(1280, 1000);
        addTearDown(tester.view.reset);
        SourceDiscoveryService.current.value = null;
        final pending = Completer<void>();
        var selected = <String>['a', 'b'];
        var notifications = 0;
        final writes = <Map<String, dynamic>>[];
        Map<String, dynamic> catalog() => {
          'origins': [
            for (final id in ['a', 'b'])
              {
                'id': 'origin-$id',
                'name': id == 'a' ? '订阅甲' : '订阅乙',
                'kind': 'tvbox',
                'primaryUrl': 'https://$id.invalid/config',
                'providerIds': [id],
              },
          ],
          'groups': [
            {
              'id': 'shared-upstream',
              'name': '同名子源',
              'providerIds': ['a', 'b'],
              'selectedProviderIds': List<String>.of(selected),
            },
          ],
        };
        SourinCore.debugCallAsyncTransport = (command, args) async {
          switch (command) {
            case 'list_providers':
              return [
                for (final id in ['a', 'b'])
                  {
                    'id': id,
                    'name': '同名子源',
                    'kind': 'tvbox',
                    'enabled': selected.contains(id),
                    'capabilities': {'vod': true, 'search': true},
                  },
                {
                  'id': 'other',
                  'name': '其它子源',
                  'kind': 'tvbox',
                  'capabilities': {'vod': true},
                },
              ];
            case 'source_catalog_get':
              return catalog();
            case 'source_discovery_status':
              return <String, dynamic>{};
            case 'source_catalog_select_providers':
              writes.add({
                'groupId': args!['groupId'],
                'providerIds': List<String>.from(args['providerIds'] as List),
              });
              if (writes.length == 1) {
                await pending.future;
                throw SourinCoreException('暂时无法保存，请重试', 'network');
              }
              selected = List<String>.from(args['providerIds'] as List);
              return catalog();
            default:
              throw StateError('Unexpected native command: $command');
          }
        };
        addTearDown(() {
          if (!pending.isCompleted) pending.complete();
          SourinCore.debugCallAsyncTransport = null;
          SourceDiscoveryService.current.value = null;
        });
        final theme = AppTheme.themeFor(Brightness.light);
        await tester.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (_, child) => AppThemeHost(data: theme, child: child!),
            home: AppScaffold(
              child: SourceManagerPage(
                onSourcesChanged: () => notifications++,
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
        Finder choice(String id) =>
            find.byKey(ValueKey('source-provider-choice-$id'));
        bool chosen(String id) =>
            tester.widget<miuix.MiuixSwitchPreference>(choice(id)).value;
        Future<void> openProviders(int count) async {
          await tester.tap(
            find.descendant(
              of: find.byKey(const ValueKey('managed-source-a')),
              matching: find.text('提供方 $count/2'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SourceProvidersDialog), findsOneWidget);
          expect(choice('other'), findsNothing);
        }

        await openProviders(2);
        await tester.tap(choice('a'));
        await tester.pumpAndSettle();
        expect(chosen('a'), isFalse);
        expect(chosen('b'), isTrue);
        await tester.tap(find.text('保存'));
        await tester.pump();
        // A pending write is intentionally not settled. Let the route finish
        // any close animation so the old close-before-save path fails here.
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(SourceProvidersDialog), findsOneWidget);
        expect(find.text('正在保存…'), findsOneWidget);
        expect(notifications, 0);
        expect(writes, [
          {
            'groupId': 'shared-upstream',
            'providerIds': ['b'],
          },
        ]);
        for (final id in ['a', 'b']) {
          expect(
            tester.widget<miuix.MiuixSwitchPreference>(choice(id)).enabled,
            isFalse,
          );
        }
        for (final label in ['全部启用', '全部关闭']) {
          expect(
            tester
                .widget<ui.TextButton>(
                  find.widgetWithText(ui.TextButton, label),
                )
                .onPressed,
            isNull,
          );
        }
        await tester.tap(choice('a'));
        await tester.tap(find.text('正在保存…'));
        await tester.tapAt(const Offset(5, 5));
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await tester.binding.handlePopRoute();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byType(SourceProvidersDialog), findsOneWidget);
        expect(chosen('a'), isFalse);
        expect(chosen('b'), isTrue);
        expect(writes.length, 1);
        pending.complete();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const ValueKey('source-providers-error')),
          findsOneWidget,
        );
        expect(find.text('暂时无法保存，请重试'), findsOneWidget);
        expect(chosen('a'), isFalse);
        expect(chosen('b'), isTrue);
        expect(
          tester.widget<miuix.MiuixSwitchPreference>(choice('a')).enabled,
          isTrue,
        );
        expect(notifications, 0);
        if (retry) {
          await tester.tap(find.text('保存'));
          await tester.pumpAndSettle();
          expect(find.byType(SourceProvidersDialog), findsNothing);
          expect(writes, [
            {
              'groupId': 'shared-upstream',
              'providerIds': ['b'],
            },
            {
              'groupId': 'shared-upstream',
              'providerIds': ['b'],
            },
          ]);
          expect(notifications, 1);
          expect(
            tester
                .widget<ui.Switch>(
                  find.byKey(const ValueKey('source-enabled-a')),
                )
                .value,
            isFalse,
          );
          expect(
            tester
                .widget<ui.Switch>(
                  find.byKey(const ValueKey('source-enabled-b')),
                )
                .value,
            isTrue,
          );
          await openProviders(1);
          expect(chosen('a'), isFalse);
          expect(chosen('b'), isTrue);
        } else {
          await tester.tap(
            find.descendant(
              of: find.byType(SourceProvidersDialog),
              matching: miuixTooltip('关闭'),
            ),
          );
          await tester.pumpAndSettle();
          expect(find.byType(SourceProvidersDialog), findsNothing);
          expect(notifications, 0);
          expect(writes.length, 1);
          await openProviders(2);
          expect(chosen('a'), isTrue);
          expect(chosen('b'), isTrue);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pumpAndSettle();
      },
    );
  }
}
