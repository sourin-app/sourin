// Independent real-dialog exit cases with raw JSON at the default FFI seam.
// No native DLL, desktop client or user profile is accessed.
import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

const _origin = 'exit-parent';
const _url = 'https://parent.invalid/config.json';
const _live = {
  'id': 'exit-live',
  'name': '新直播',
  'url': 'https://live.invalid/a.m3u',
};

class _Transport {
  Completer<void>? pending;
  bool fail = false;
  bool applied = false;
  int loads = 0;
  final updates = <Map<String, dynamic>>[];

  void install() {
    final transport = SourinCore.debugCallAsyncTransport;
    final restore = SourinApi.debugRestoreFailuresFetcher;
    final discovery = SourceDiscoveryService.current.value;
    SourinApi.debugRestoreFailuresFetcher = null;
    SourceDiscoveryService.current.value = null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      switch (command) {
        case 'source_catalog_get':
          loads++;
          return {
            'origins': [
              {
                'id': _origin,
                'name': '订阅退出',
                'kind': 'tvbox',
                'primaryUrl': _url,
                'providerIds': <String>[],
                'relatedProviderIds': applied ? ['exit-live'] : <String>[],
              },
              if (applied)
                {
                  'id': 'playlist-owner',
                  'name': '新直播',
                  'kind': 'live',
                  'primaryUrl': _live['url'],
                  'providerIds': ['exit-live'],
                },
            ],
            'groups': <Object>[],
          };
        case 'list_providers':
          return [
            if (applied)
              {
                'id': 'exit-live',
                'name': '新直播',
                'kind': 'm3u_live',
                'enabled': true,
                'capabilities': {'live': true, 'vod': false},
              },
          ];
        case 'source_discovery_status':
          return <String, dynamic>{};
        case 'restore_failures':
          return {'count': 0, 'items': <Object>[]};
        case 'check_tvbox_updates':
          expect(args, {'id': _origin});
          return {
            'items': [
              {
                'originId': _origin,
                'sourceUrl': _url,
                'ids': <String>[],
                'ok': true,
                'liveHasChanges': !applied,
                'liveAdded': applied ? <Object>[] : [_live],
              },
            ],
            'checked': 1,
            'skipped': 0,
          };
        case 'update_tvbox_source':
          updates.add(Map<String, dynamic>.from(args!));
          await pending?.future;
          if (fail) throw StateError('synthetic update failed');
          applied = true;
          return {
            'updated': true,
            'originId': _origin,
            'sourceUrl': _url,
            'liveAdded': [_live],
            'liveMembershipChanged': true,
          };
        default:
          throw StateError('Unexpected command: $command');
      }
    };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = transport;
      SourinApi.debugRestoreFailuresFetcher = restore;
      SourceDiscoveryService.current.value = discovery;
    });
  }
}

Future<void> _tap(WidgetTester tester, Finder finder) async {
  expect(finder, findsOneWidget);
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Finder _text(String text) => find.descendant(
  of: find.byType(TvboxUpdateDialog),
  matching: find.text(text),
);

Future<void> _open(WidgetTester tester, VoidCallback changed) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1800);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: SourceManagerPage(
        onSourcesChanged: changed,
        onImportTvbox: () async {},
        onPasteJs: () async {},
        onEditProvider: (_) async {},
        onConfigureProvider: (_) async {},
        onRemoveProvider: (_) async {},
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, find.byKey(const ValueKey('source-origin-picker')));
  await _tap(
    tester,
    find.byKey(const ValueKey('source-origin-option-$_origin')),
  );
  await _tap(tester, find.byKey(const ValueKey('source-origin-update')));
  await _tap(tester, _text('检测更新'));
  expect(_text('应用更新'), findsOneWidget);
}

Future<void> _exit(WidgetTester tester, String way) async {
  switch (way) {
    case 'outside':
      await tester.tapAt(const Offset(8, 8));
    case 'escape':
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    case 'back':
      await tester.binding.handlePopRoute();
    case 'button':
      await tester.tap(_text('关闭'));
  }
  await tester.pumpAndSettle();
}

void main() {
  for (final way in ['outside', 'escape', 'back', 'button']) {
    testWidgets(
      'accepted update survives $way exit and refreshes its parent once',
      (tester) async {
        final transport = _Transport()..install();
        var notifications = 0;
        await _open(tester, () => notifications++);
        await _tap(tester, _text('应用更新'));
        expect(transport.applied, isTrue);
        expect(notifications, 0);
        await _exit(tester, way);
        expect(find.byType(TvboxUpdateDialog), findsNothing);
        expect(notifications, 1);
        expect(transport.loads, 2);
        expect(
          find.byKey(const ValueKey('managed-source-exit-live')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets(
      'pending update blocks $way exit until its result can be reported',
      (tester) async {
        final transport = _Transport()..pending = Completer<void>();
        transport.install();
        addTearDown(() {
          if (!transport.pending!.isCompleted) transport.pending!.complete();
        });
        var notifications = 0;
        await _open(tester, () => notifications++);
        await tester.tap(_text('应用更新'));
        await tester.pump();
        expect(transport.updates, [
          {'id': _origin, 'applyNew': true, 'deleteMissing': false},
        ]);
        await _exit(tester, way);
        expect(
          find.byType(TvboxUpdateDialog),
          findsOneWidget,
          reason: 'an accepted native update must retain its result owner while pending',
        );
        expect(notifications, 0);
        expect(transport.applied, isFalse);
        transport.pending!.complete();
        await tester.pumpAndSettle();
        await _exit(tester, way);
        expect(find.byType(TvboxUpdateDialog), findsNothing);
        expect(notifications, 1);
        expect(transport.loads, 2);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'failed update releases dismissal without claiming a source change',
    (tester) async {
      final transport = _Transport()..fail = true;
      transport.install();
      var notifications = 0;
      await _open(tester, () => notifications++);
      await _tap(tester, _text('应用更新'));
      expect(find.textContaining('synthetic update failed'), findsOneWidget);
      await _exit(tester, 'outside');
      expect(find.byType(TvboxUpdateDialog), findsNothing);
      expect(notifications, 0);
      expect(transport.loads, 2);
      expect(tester.takeException(), isNull);
    },
  );
}
