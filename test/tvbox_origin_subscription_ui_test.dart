// Independent origin-entry behavior tests. All Dart symbols existed before
// the suggested patch; originId enters through raw default-transport JSON.
// No real DLL, client, player, account/profile or network is used.
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

const _liveOriginId = 'origin-live';
const _mixedOriginId = 'origin-mixed';
const _vodId = 'selected-vod';
const _liveParentUrl = 'https://parent.invalid/live.json';
const _mixedParentUrl = 'https://parent.invalid/mixed.json';
const _newLive = <String, dynamic>{
  'id': 'new-live',
  'name': '新直播',
  'url': 'https://playlist.invalid/new.m3u',
};
const _oldLive = <String, dynamic>{'id': 'old-live', 'name': '旧直播'};
const _goneVod = <String, dynamic>{
  'id': _vodId,
  'key': 'old-vod',
  'name': '旧点播站',
  'api': 'https://vod.invalid/old',
};

dynamic _copy(dynamic value) => jsonDecode(jsonEncode(value));

Map<String, dynamic> _baseItem({
  required String originId,
  required String sourceUrl,
  required List<String> ids,
}) => {
  'originId': originId,
  'sourceUrl': sourceUrl,
  'ids': ids,
  'ok': true,
  'added': <Object>[],
  'removed': <Object>[],
  'changed': <Object>[],
  'remoteTotalSites': 0,
  'remoteConvertible': 0,
  'remoteUnsupported': 0,
  'unchanged': 0,
  'unchangedForeign': 0,
  'liveHasChanges': false,
  'liveAdded': <Object>[],
  'liveRemoved': <Object>[],
};

Map<String, dynamic> _outcome({
  required bool updated,
  required String sourceUrl,
  String? reason,
}) => {
  'updated': updated,
  if (reason != null) 'reason': reason,
  'sourceUrl': sourceUrl,
  'added': <Object>[],
  'changed': <Object>[],
  'removed': <Object>[],
  'deleted': <Object>[],
  'notApplied': <Object>[],
  'failed': <Object>[],
  'unchanged': 0,
  'unchangedForeign': 0,
  'skippedByType': 0,
  'liveAdded': <Object>[],
  'liveRemoved': <Object>[],
  'liveNotApplied': <Object>[],
  'liveDeleted': <Object>[],
  'liveMembershipChanged': false,
};

class _OriginTransport {
  _OriginTransport({this.removedOnly = false});

  final bool removedOnly;
  bool liveApplied = false;
  bool vodDeleted = false;
  int catalogLoads = 0;
  int providerLoads = 0;
  final checks = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];
  final sidecarWrites = <Map<String, dynamic>>[];
  final catalogWrites = <Map<String, dynamic>>[];
  final commands = <String>[];

  List<Map<String, dynamic>> providers() => [
    {
      'id': 'old-live',
      'name': '旧直播',
      'kind': 'm3u_live',
      'enabled': true,
      'capabilities': {'live': true, 'vod': false},
    },
    if (liveApplied)
      {
        'id': 'new-live',
        'name': '新直播',
        'kind': 'm3u_live',
        'enabled': true,
        'capabilities': {'live': true, 'vod': false},
      },
    if (!vodDeleted)
      {
        'id': _vodId,
        'name': '旧点播站',
        'kind': 'tvbox',
        'enabled': true,
        'capabilities': {'vod': true, 'live': false},
      },
  ];

  Map<String, dynamic> catalog() => {
    'origins': [
      {
        'id': _liveOriginId,
        'name': '纯直播订阅',
        'kind': 'tvbox',
        'primaryUrl': _liveParentUrl,
        'providerIds': <String>[],
        'relatedProviderIds': [liveApplied ? 'new-live' : 'old-live'],
      },
      {
        'id': _mixedOriginId,
        'name': '点播订阅',
        'kind': 'tvbox',
        'primaryUrl': _mixedParentUrl,
        'providerIds': vodDeleted ? <String>[] : [_vodId],
        'relatedProviderIds': <String>[],
      },
      {
        'id': 'old-playlist-owner',
        'name': '旧直播',
        'kind': 'live',
        'primaryUrl': 'https://playlist.invalid/old.m3u',
        'providerIds': ['old-live'],
      },
      if (liveApplied)
        {
          'id': 'new-playlist-owner',
          'name': '新直播',
          'kind': 'live',
          'primaryUrl': 'https://playlist.invalid/new.m3u',
          'providerIds': ['new-live'],
        },
    ],
    'groups': <Object>[],
  };

  Map<String, dynamic> checkFor(String id) {
    final live = _baseItem(
      originId: _liveOriginId,
      sourceUrl: _liveParentUrl,
      ids: const [],
    );
    if (!liveApplied) {
      live.addAll({
        'liveHasChanges': true,
        'liveAdded': [_newLive],
        'liveRemoved': [_oldLive],
      });
    }
    final vod = _baseItem(
      originId: _mixedOriginId,
      sourceUrl: _mixedParentUrl,
      ids: vodDeleted ? const [] : [_vodId],
    );
    if (removedOnly && !vodDeleted) {
      vod['removed'] = [_goneVod];
    } else if (!removedOnly) {
      vod['remoteTotalSites'] = 1;
      vod['remoteConvertible'] = 1;
      vod['unchanged'] = 1;
    }
    if (id != _liveOriginId && id != _mixedOriginId && id != _vodId) {
      throw StateError('Unexpected subscription identity: $id');
    }
    return {
      // The selected pure-live response is deliberately not the first item,
      // and its ids remain empty. It must be located by exact originId.
      'items': id == _liveOriginId ? [vod, live] : [live, vod],
      'checked': 1,
      'skipped': 0,
      'skippedIds': <String>[],
    };
  }

  Map<String, dynamic> apply(Map<String, dynamic> args) {
    final id = args['id'];
    if (id == _liveOriginId) {
      liveApplied = true;
      return _outcome(updated: true, sourceUrl: _liveParentUrl)
        ..addAll({
          'liveAdded': [_newLive],
          'liveRemoved': [_oldLive],
          'liveMembershipChanged': true,
        });
    }
    if (id == _mixedOriginId || id == _vodId) {
      final deleting = args['deleteMissing'] == true;
      final result = _outcome(
        updated: deleting,
        sourceUrl: _mixedParentUrl,
        reason: deleting ? null : '远端已消失的点播站已保留',
      )..['removed'] = [_goneVod];
      if (deleting) {
        vodDeleted = true;
        result['deleted'] = [_goneVod];
      }
      return result;
    }
    throw StateError('Unexpected update identity');
  }

  void install() {
    final savedTransport = SourinCore.debugCallAsyncTransport;
    final savedRestoreFetcher = SourinApi.debugRestoreFailuresFetcher;
    final savedDiscovery = SourceDiscoveryService.current.value;
    SourinApi.debugRestoreFailuresFetcher = null;
    SourceDiscoveryService.current.value = null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      commands.add(command);
      switch (command) {
        case 'list_providers':
          providerLoads++;
          return _copy(providers());
        case 'source_catalog_get':
          catalogLoads++;
          return _copy(catalog());
        case 'source_discovery_status':
          return <String, dynamic>{};
        case 'restore_failures':
          return <String, dynamic>{'count': 0, 'items': <Object>[]};
        case 'check_tvbox_updates':
          final request = Map<String, dynamic>.from(args!);
          checks.add(request);
          return _copy(checkFor(request['id'] as String));
        case 'update_tvbox_source':
          final request = Map<String, dynamic>.from(args!);
          updates.add(request);
          return _copy(apply(request));
        case 'set_tvbox_source':
          sidecarWrites.add(Map<String, dynamic>.from(args!));
          return null;
        case 'source_catalog_set_origin':
          catalogWrites.add(Map<String, dynamic>.from(args!));
          return _copy(catalog());
        default:
          throw StateError('Unexpected command: $command');
      }
    };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = savedTransport;
      SourinApi.debugRestoreFailuresFetcher = savedRestoreFetcher;
      SourceDiscoveryService.current.value = savedDiscovery;
    });
  }
}

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: child,
  );
}

void _view(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1800);
  addTearDown(tester.view.reset);
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder _dialogText(String text) => find.descendant(
  of: find.byType(TvboxUpdateDialog),
  matching: find.text(text),
);

Finder _resultText(String text) => find.descendant(
  of: find.byType(TvboxUpdateResultView),
  matching: find.textContaining(text),
);

Finder _address(String text) => find.descendant(
  of: find.byType(TvboxUpdateDialog),
  matching: find.byWidgetPredicate(
    (widget) => widget is EditableText && widget.controller.text == text,
  ),
);

Future<void> _openSelectedOrigin(
  WidgetTester tester, {
  required String originId,
  required VoidCallback onSourcesChanged,
}) async {
  _view(tester);
  await tester.pumpWidget(
    _host(
      SourceManagerPage(
        onSourcesChanged: onSourcesChanged,
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
  await _tap(tester, find.byKey(ValueKey('source-origin-option-$originId')));
  final entry = find.byKey(const ValueKey('source-origin-update'));
  expect(
    entry,
    findsOneWidget,
    reason: '实际已选父订阅必须提供更新入口，纯直播订阅不能依赖点播代表源。',
  );
  expect(
    find.descendant(
      of: find.byKey(const ValueKey('source-origin-summary')),
      matching: find.text('订阅更新'),
    ),
    findsOneWidget,
  );
  await _tap(tester, entry);
  expect(find.byType(TvboxUpdateDialog), findsOneWidget);
}

Future<void> _openProviderDialog(
  WidgetTester tester, {
  required ValueChanged<bool> onClosed,
}) async {
  _view(tester);
  await tester.pumpWidget(
    _host(
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => onClosed(
              await TvboxUpdateDialog.show(
                context,
                id: _vodId,
                name: '旧点播站',
                sourceUrl: _mixedParentUrl,
              ),
            ),
            child: const Text('打开点播订阅'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, find.text('打开点播订阅'));
}

Future<void> _close(WidgetTester tester) async {
  await _tap(tester, _dialogText('关闭'));
  expect(find.byType(TvboxUpdateDialog), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'selected pure-live origin opens the real dialog and locates ids-empty JSON by originId',
    (tester) async {
      final transport = _OriginTransport()..install();
      var notifications = 0;
      await _openSelectedOrigin(
        tester,
        originId: _liveOriginId,
        onSourcesChanged: () => notifications++,
      );
      expect(_dialogText('订阅更新 · 纯直播订阅'), findsOneWidget);
      expect(transport.checks, isEmpty);
      expect(transport.updates, isEmpty);
      expect(transport.catalogLoads, 1);
      await _tap(tester, _dialogText('检测更新'));
      expect(transport.checks, [{'id': _liveOriginId}]);
      expect(
        _dialogText('发现更新：直播新增 1 · 直播待解除归属 1（播放列表保留）'),
        findsOneWidget,
        reason: '纯直播响应 ids=[]，必须读取选中父订阅的 originId，不能取第一条或点播 id。',
      );
      expect(_dialogText('应用更新'), findsOneWidget);
      expect(transport.updates, isEmpty);
      await _tap(tester, _dialogText('应用更新'));
      expect(transport.updates, [
        {'id': _liveOriginId, 'applyNew': true, 'deleteMissing': false},
      ]);
      expect(transport.checks, [
        {'id': _liveOriginId},
        {'id': _liveOriginId},
      ]);
      expect(_resultText('直播已加入此订阅 1：新直播'), findsOneWidget);
      expect(_resultText('直播已解除此订阅归属 1：旧直播'), findsOneWidget);
      expect(_resultText('播放列表保留'), findsOneWidget);
      expect(_resultText('直播已删除'), findsNothing);
      expect(transport.sidecarWrites, isEmpty);
      expect(transport.catalogWrites, isEmpty);
      expect(notifications, 0);
      expect(transport.catalogLoads, 1);
      await _close(tester);
      expect(notifications, 1);
      expect(transport.catalogLoads, 2);
      expect(transport.providerLoads, 2);
      expect(find.byKey(const ValueKey('managed-source-new-live')), findsOneWidget);
      expect(find.byKey(const ValueKey('managed-source-old-live')), findsNothing);
    },
  );

  testWidgets(
    'origin-mode address is read-only and actual clicks and Enter cannot save a VOD sidecar',
    (tester) async {
      final transport = _OriginTransport()..install();
      var notifications = 0;
      await _openSelectedOrigin(
        tester,
        originId: _liveOriginId,
        onSourcesChanged: () => notifications++,
      );
      final address = _address(_liveParentUrl);
      expect(address, findsOneWidget);
      expect(
        tester.widget<EditableText>(address).readOnly,
        isTrue,
        reason: '父订阅目录拥有该地址；更新弹窗不能将它当点播 sidecar 的可编辑地址。',
      );
      expect(_dialogText('保存'), findsNothing);
      expect(_dialogText('填入'), findsNothing);
      expect(_dialogText('清除'), findsNothing);
      expect(
        _dialogText('订阅地址由源管理页的“编辑地址”管理；这里仅检测和应用更新。'),
        findsOneWidget,
      );
      await _tap(tester, address);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(tester.widget<EditableText>(address).controller.text, _liveParentUrl);
      expect(transport.sidecarWrites, isEmpty);
      expect(transport.catalogWrites, isEmpty);
      expect(transport.checks, isEmpty);
      await _tap(tester, _dialogText('检测更新'));
      expect(transport.checks, [{'id': _liveOriginId}]);
      expect(transport.updates, isEmpty);
      expect(transport.sidecarWrites, isEmpty);
      await _close(tester);
      expect(notifications, 0);
      expect(transport.catalogLoads, 1);
    },
  );

  testWidgets(
    'selected VOD origin with only removed sites offers explicit deletion and refreshes after consent',
    (tester) async {
      final transport = _OriginTransport(removedOnly: true)..install();
      var notifications = 0;
      await _openSelectedOrigin(
        tester,
        originId: _mixedOriginId,
        onSourcesChanged: () => notifications++,
      );
      await _tap(tester, _dialogText('检测更新'));
      expect(transport.checks, [{'id': _mixedOriginId}]);
      expect(_dialogText('发现更新：远端已消失 1'), findsOneWidget);
      expect(
        _dialogText('应用更新'),
        findsOneWidget,
        reason: '仅远端消失的点播站也必须提供显式删除开关，不可让说明指向不存在的开关。',
      );
      final deletion = find.ancestor(
        of: _dialogText('同时删除远端已消失的站'),
        matching: find.byType(ui.SwitchListTile),
      );
      expect(tester.widget<ui.SwitchListTile>(deletion).value, isFalse);
      expect(transport.updates, isEmpty);
      await _tap(tester, _dialogText('应用更新'));
      expect(transport.updates, [
        {'id': _mixedOriginId, 'applyNew': true, 'deleteMissing': false},
      ]);
      expect(transport.checks, [{'id': _mixedOriginId}]);
      expect(_resultText('远端已消失 1 个站（未删除）'), findsOneWidget);
      expect(notifications, 0);
      await _tap(tester, _dialogText('同时删除远端已消失的站'));
      expect(tester.widget<ui.SwitchListTile>(deletion).value, isTrue);
      await _tap(tester, _dialogText('应用更新'));
      expect(transport.updates, [
        {'id': _mixedOriginId, 'applyNew': true, 'deleteMissing': false},
        {'id': _mixedOriginId, 'applyNew': true, 'deleteMissing': true},
      ]);
      expect(transport.checks, [
        {'id': _mixedOriginId},
        {'id': _mixedOriginId},
      ]);
      expect(_resultText('删除 1'), findsOneWidget);
      expect(_resultText('直播已删除'), findsNothing);
      expect(transport.sidecarWrites, isEmpty);
      expect(transport.catalogWrites, isEmpty);
      await _close(tester);
      expect(notifications, 1);
      expect(transport.catalogLoads, 2);
    },
  );

  testWidgets(
    'provider removed-only check independently exposes the real deleteMissing switch',
    (tester) async {
      final transport = _OriginTransport(removedOnly: true)..install();
      bool? closed;
      await _openProviderDialog(tester, onClosed: (value) => closed = value);
      await _tap(tester, _dialogText('检测更新'));
      expect(transport.checks, [{'id': _vodId}]);
      expect(
        _dialogText('应用更新'),
        findsOneWidget,
        reason: '真实 removed-only 点播结果需要应用区中的显式删除开关。',
      );
      final deletion = find.ancestor(
        of: _dialogText('同时删除远端已消失的站'),
        matching: find.byType(ui.SwitchListTile),
      );
      expect(tester.widget<ui.SwitchListTile>(deletion).value, isFalse);
      expect(transport.updates, isEmpty);
      await _tap(tester, _dialogText('同时删除远端已消失的站'));
      await _tap(tester, _dialogText('应用更新'));
      expect(transport.updates, [
        {'id': _vodId, 'applyNew': true, 'deleteMissing': true},
      ]);
      expect(_resultText('删除 1'), findsOneWidget);
      expect(transport.sidecarWrites, isEmpty);
      await _close(tester);
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'legacy provider mode retains editable source link and actual sidecar saving',
    (tester) async {
      final transport = _OriginTransport()..install();
      bool? closed;
      await _openProviderDialog(tester, onClosed: (value) => closed = value);
      final address = _address(_mixedParentUrl);
      expect(tester.widget<EditableText>(address).readOnly, isFalse);
      expect(_dialogText('保存'), findsOneWidget);
      expect(_dialogText('清除'), findsOneWidget);
      await tester.enterText(address, 'https://parent.invalid/replacement.json');
      await tester.pumpAndSettle();
      expect(transport.sidecarWrites, isEmpty);
      await _tap(tester, _dialogText('保存'));
      expect(transport.sidecarWrites, [
        {'id': _vodId, 'url': 'https://parent.invalid/replacement.json'},
      ]);
      expect(transport.checks, [{'id': _vodId}]);
      expect(transport.catalogWrites, isEmpty);
      expect(transport.updates, isEmpty);
      await _close(tester);
      expect(closed, isFalse);
    },
  );
}
