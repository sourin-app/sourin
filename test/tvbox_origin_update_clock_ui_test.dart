// Independent raw JSON → real SourceManagerPage picker/summary/dialog tests.
// Only public symbols present on the original Dart baseline are referenced.
// No new clock getter or constructor argument is used by this test.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

const _parentId = 'clock-parent';
const _parentUrl = 'https://parent.invalid/live.json';
const _sensitiveError =
    '下载失败 https://access.invalid/private/a.m3u?token=clock-secret '
    'Authorization: Bearer clock-bearer access_token=clock-extra';
const _clockWarning = '订阅内容已更新，但更新时间未保存，请稍后重试';
final _okAt = DateTime.utc(2025, 6, 7, 8, 9).millisecondsSinceEpoch ~/ 1000;
final _failedAt = DateTime.utc(2025, 6, 8, 9, 10).millisecondsSinceEpoch ~/ 1000;
final _childAt = DateTime.utc(2024, 2, 3, 4, 5).millisecondsSinceEpoch ~/ 1000;

String get _successText => '上次更新：${tvboxShortTime(_okAt)}';
String get _failureText => '上次更新失败 ${tvboxShortTime(_failedAt)}';

class _ClockTransport {
  _ClockTransport({
    Map<String, dynamic> clock = const {},
    this.offerChange = false,
    this.outcome = 'changed',
  }) : clock = Map<String, dynamic>.from(clock);

  Map<String, dynamic> clock;
  final bool offerChange;
  final String outcome;
  bool endpointChecked = false;
  bool attempted = false;
  bool applied = false;
  int loads = 0;
  final checks = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];
  final writes = <String>[];

  Map<String, dynamic> catalog() => {
    'origins': [
      {
        'id': _parentId,
        'name': '纯直播订阅',
        'kind': 'tvbox',
        'primaryUrl': _parentUrl,
        'lastSuccessfulUrl': endpointChecked
            ? 'https://endpoint.invalid/checked?token=endpoint-secret'
            : 'https://endpoint.invalid/available?token=endpoint-secret',
        'providerIds': <String>[],
        'relatedProviderIds': ['old-live', if (applied) 'new-live'],
        ...clock,
      },
      {
        'id': 'playlist-owner',
        'name': '旧直播',
        'kind': 'live',
        'primaryUrl': 'https://playlist.invalid/old.m3u',
        'providerIds': ['old-live'],
        // A live address owner clock must never become the TVBox parent clock.
        'lastUpdateAt': _childAt,
        'lastUpdateOk': true,
        'lastUpdateError': _sensitiveError,
      },
    ],
    'groups': <Object>[],
  };

  Map<String, dynamic> result(bool updated) => {
    'updated': updated,
    'sourceUrl': _parentUrl,
    'added': <Object>[],
    'changed': <Object>[],
    'removed': <Object>[],
    'deleted': <Object>[],
    'failed': <Object>[],
    'notApplied': <Object>[],
    'liveAdded': updated
        ? [
            {'id': 'new-live', 'name': '新直播', 'url': 'https://playlist.invalid/new.m3u'},
          ]
        : <Object>[],
    'liveRemoved': <Object>[],
    'liveNotApplied': <Object>[],
    'liveDeleted': <Object>[],
    'liveMembershipChanged': updated,
  };

  void install() {
    final savedTransport = SourinCore.debugCallAsyncTransport;
    final savedRestore = SourinApi.debugRestoreFailuresFetcher;
    final savedDiscovery = SourceDiscoveryService.current.value;
    SourinApi.debugRestoreFailuresFetcher = null;
    SourceDiscoveryService.current.value = null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      switch (command) {
        case 'source_catalog_get':
          loads++;
          return jsonDecode(jsonEncode(catalog()));
        case 'list_providers':
          return [
            {
              'id': 'old-live', 'name': '旧直播', 'kind': 'm3u_live',
              'enabled': true, 'capabilities': {'live': true, 'vod': false},
            },
            if (applied)
              {
                'id': 'new-live', 'name': '新直播', 'kind': 'm3u_live',
                'enabled': true, 'capabilities': {'live': true, 'vod': false},
              },
          ];
        case 'source_discovery_status':
          return <String, dynamic>{};
        case 'restore_failures':
          return {'count': 0, 'items': <Object>[]};
        case 'check_tvbox_updates':
          checks.add(Map<String, dynamic>.from(args!));
          expect(args, {'id': _parentId});
          endpointChecked = true;
          return {
            'items': [
              {
                'originId': _parentId, 'sourceUrl': _parentUrl,
                'ids': <String>[], 'ok': true,
                'liveHasChanges': offerChange && !attempted,
                'liveAdded': offerChange && !attempted
                    ? [
                        {'id': 'new-live', 'name': '新直播', 'url': 'https://playlist.invalid/new.m3u'},
                      ]
                    : <Object>[],
              },
            ],
            'checked': 1, 'skipped': 0,
          };
        case 'update_tvbox_source':
          updates.add(Map<String, dynamic>.from(args!));
          expect(args, {'id': _parentId, 'applyNew': true, 'deleteMissing': false});
          attempted = true;
          if (outcome == 'failed') {
            clock = {
              'lastUpdateAt': _failedAt,
              'lastUpdateOk': false,
              'lastUpdateError': _sensitiveError,
            };
            // The clock privacy test concerns the stored raw error, while the
            // existing dialog exception handler receives a safe fixture error.
            throw StateError('synthetic update failure');
          }
          if (outcome == 'warning') {
            applied = true;
            return result(true)
              ..addAll({
                'updateClockWarning': _clockWarning,
                // An untrusted write error is separate from the fixed warning.
                'clockWriteError': _sensitiveError,
              });
          }
          if (outcome == 'warning-unchanged') {
            return result(false)
              ..addAll({
                'reason': '远端配置与本地一致，无需更新',
                // A raw warning value must not be rendered as its own text.
                'updateClockWarning': _sensitiveError,
              });
          }
          clock = {
            'lastUpdateAt': _okAt,
            'lastUpdateOk': true,
            'lastUpdateError': null,
          };
          applied = outcome != 'unchanged';
          return result(applied)
            ..addAll({
              if (!applied) 'reason': '远端配置与本地一致，无需更新',
            });
        case 'set_tvbox_source':
        case 'source_catalog_set_origin':
          writes.add(command);
          throw StateError('Unexpected client metadata write');
        default:
          throw StateError('Unexpected command: $command');
      }
    };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = savedTransport;
      SourinApi.debugRestoreFailuresFetcher = savedRestore;
      SourceDiscoveryService.current.value = savedDiscovery;
    });
  }
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Finder get _summary => find.byKey(const ValueKey('source-origin-summary'));
Finder _summaryText(String text) =>
    find.descendant(of: _summary, matching: find.text(text));
Finder _dialogText(String text) => find.descendant(
  of: find.byType(TvboxUpdateDialog), matching: find.text(text),
);
Finder _resultText(String text) => find.descendant(
  of: find.byType(TvboxUpdateResultView), matching: find.textContaining(text),
);

Future<void> _mount(
  WidgetTester tester,
  _ClockTransport transport,
  VoidCallback changed,
) async {
  transport.install();
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
}

Future<void> _select(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('source-origin-picker')));
  expect(find.byKey(const ValueKey('source-origin-option-playlist-owner')), findsNothing);
  await _tap(tester, find.byKey(const ValueKey('source-origin-option-clock-parent')));
  expect(_summary, findsOneWidget);
  expect(_summaryText('编辑地址'), findsOneWidget);
  expect(_summaryText('订阅更新'), findsOneWidget);
}

Future<void> _openAndCheck(WidgetTester tester) async {
  await _tap(tester, find.byKey(const ValueKey('source-origin-update')));
  expect(find.byType(TvboxUpdateDialog), findsOneWidget);
  await _tap(tester, _dialogText('检测更新'));
}

Future<void> _close(WidgetTester tester) async {
  await _tap(tester, _dialogText('关闭'));
  expect(find.byType(TvboxUpdateDialog), findsNothing);
  expect(tester.takeException(), isNull);
}

void _noSecrets({List<String> logs = const []}) {
  for (final secret in [
    'clock-secret', 'clock-bearer', 'clock-extra', 'access.invalid',
    'Authorization:', 'access_token=', 'endpoint-secret',
  ]) {
    expect(find.textContaining(secret), findsNothing);
    expect(logs.join('\n'), isNot(contains(secret)));
  }
}

void main() {
  testWidgets('old raw JSON with pure-live zero VOD shows never updated and keeps its entry/count', (tester) async {
    final transport = _ClockTransport();
    var notifications = 0;
    await _mount(tester, transport, () => notifications++);
    await _select(tester);
    expect(_summaryText('纯直播订阅 · 1 个源'), findsOneWidget);
    expect(
      _summaryText('从未更新'),
      findsOneWidget,
      reason: '旧 JSON 缺少 clock 字段时默认为 0/false/null；纯直播父订阅没有点播代表源也要显示。',
    );
    expect(find.byKey(const ValueKey('source-origin-update-error')), findsNothing);
    expect(transport.checks, isEmpty);
    expect(transport.updates, isEmpty);
    expect(transport.writes, isEmpty);
    expect(notifications, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('successful check and successful endpoint cannot fabricate an update clock', (tester) async {
    final transport = _ClockTransport(clock: {'lastUpdateAt': 0, 'lastUpdateOk': true});
    var notifications = 0;
    await _mount(tester, transport, () => notifications++);
    await _select(tester);
    expect(_summaryText('从未更新'), findsOneWidget);
    await _openAndCheck(tester);
    expect(transport.endpointChecked, isTrue);
    expect(transport.updates, isEmpty);
    await _close(tester);
    expect(transport.loads, 2);
    expect(_summaryText('从未更新'), findsOneWidget);
    expect(find.textContaining('上次更新：'), findsNothing);
    expect(notifications, 0);
    expect(transport.writes, isEmpty);
  });

  testWidgets('parent success uses Unix seconds and only the selected TVBox summary displays a clock', (tester) async {
    final transport = _ClockTransport(clock: {
      'lastUpdateAt': _okAt, 'lastUpdateOk': true, 'lastUpdateError': _sensitiveError,
    });
    await _mount(tester, transport, () {});
    expect(find.byKey(const ValueKey('source-origin-last-update')), findsNothing);
    expect(find.text('上次更新：${tvboxShortTime(_childAt)}'), findsNothing);
    await _select(tester);
    expect(_summaryText(_successText), findsOneWidget);
    expect(find.byKey(const ValueKey('source-origin-update-error')), findsNothing);
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('managed-source-old-live')),
        matching: find.textContaining('上次更新'),
      ),
      findsNothing,
    );
    _noSecrets();
    expect(transport.checks, isEmpty);
    expect(transport.updates, isEmpty);
  });

  testWidgets('persisted failure is visible without forwarding raw URL/token to UI or debugPrint', (tester) async {
    final logs = <String>[];
    final savedPrint = debugPrint;
    debugPrint = (String? message, {int? wrapWidth}) {
      if (message != null) {
        logs.add(message);
      }
    };
    try {
      final transport = _ClockTransport(clock: {
        'lastUpdateAt': _failedAt, 'lastUpdateOk': false, 'lastUpdateError': _sensitiveError,
      });
      await _mount(tester, transport, () {});
      await _select(tester);
      expect(_summaryText(_failureText), findsOneWidget);
      final reason = find.byKey(const ValueKey('source-origin-update-error'));
      expect(reason, findsOneWidget, reason: '失败原因必须实际渲染安全提示，不能只靠红色或日志。');
      expect(tester.widget<Text>(reason).data, contains('失败原因'));
      expect(tester.widget<Text>(reason).data, isNot(_sensitiveError));
      _noSecrets(logs: logs);
      expect(find.textContaining('https://access.invalid'), findsNothing);
    } finally {
      debugPrint = savedPrint;
    }
  });

  testWidgets('failed clock without an error field remains visible with a safe missing-reason hint', (tester) async {
    final transport = _ClockTransport(clock: {'lastUpdateAt': _failedAt, 'lastUpdateOk': false});
    await _mount(tester, transport, () {});
    await _select(tester);
    expect(_summaryText(_failureText), findsOneWidget);
    expect(_summaryText('失败原因：后端没有给出原因'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('actual changed update closes true and reloads the persisted parent timestamp', (tester) async {
    final transport = _ClockTransport(offerChange: true);
    var notifications = 0;
    await _mount(tester, transport, () => notifications++);
    await _select(tester);
    expect(_summaryText('从未更新'), findsOneWidget);
    await _openAndCheck(tester);
    expect(_dialogText('应用更新'), findsOneWidget);
    await _tap(tester, _dialogText('应用更新'));
    expect(transport.applied, isTrue);
    expect(notifications, 0);
    expect(transport.loads, 1);
    expect(find.byKey(const ValueKey('tvbox-update-clock-warning')), findsNothing);
    await _close(tester);
    expect(_summaryText(_successText), findsOneWidget);
    expect(_summaryText('纯直播订阅 · 2 个源'), findsOneWidget);
    expect(notifications, 1);
    expect(transport.loads, 2);
    expect(transport.writes, isEmpty);
    expect(transport.updates, [{'id': _parentId, 'applyNew': true, 'deleteMissing': false}]);
  });

  testWidgets('successful updated=false attempt reloads its clock without source-change notification', (tester) async {
    final transport = _ClockTransport(offerChange: true, outcome: 'unchanged');
    var notifications = 0;
    await _mount(tester, transport, () => notifications++);
    await _select(tester);
    await _openAndCheck(tester);
    await _tap(tester, _dialogText('应用更新'));
    expect(transport.applied, isFalse);
    expect(transport.updates, hasLength(1));
    expect(notifications, 0);
    await _close(tester);
    expect(transport.loads, 2, reason: 'updated=false 不代表 parent clock 没有变化。');
    expect(_summaryText(_successText), findsOneWidget);
    expect(notifications, 0);
    expect(transport.writes, isEmpty);
  });

  testWidgets('failed actual attempt closes false yet reloads the stored failure clock safely', (tester) async {
    final transport = _ClockTransport(offerChange: true, outcome: 'failed');
    var notifications = 0;
    await _mount(tester, transport, () => notifications++);
    await _select(tester);
    await _openAndCheck(tester);
    await _tap(tester, _dialogText('应用更新'));
    expect(transport.applied, isFalse);
    expect(notifications, 0);
    await _close(tester);
    expect(transport.loads, 2, reason: '失败尝试的持久化 clock 也必须重新读取。');
    expect(_summaryText(_failureText), findsOneWidget);
    expect(find.byKey(const ValueKey('source-origin-update-error')), findsOneWidget);
    expect(notifications, 0);
    expect(transport.writes, isEmpty);
    _noSecrets();
  });

  testWidgets('applied contents retain success and close notification when clock persistence warns', (tester) async {
    final transport = _ClockTransport(offerChange: true, outcome: 'warning');
    var notifications = 0;
    await _mount(tester, transport, () => notifications++);
    await _select(tester);
    await _openAndCheck(tester);
    await _tap(tester, _dialogText('应用更新'));
    expect(transport.applied, isTrue);
    expect(find.descendant(of: find.byType(TvboxUpdateResultView), matching: find.text('已更新')), findsOneWidget);
    expect(_resultText(_clockWarning), findsOneWidget);
    expect(_resultText('直播已加入此订阅 1：新直播'), findsOneWidget);
    _noSecrets();
    expect(notifications, 0);
    await _close(tester);
    expect(notifications, 1, reason: 'clock 保存警告不能抹掉已经应用的内容和成功关闭结果。');
    expect(transport.loads, 2);
    expect(_summaryText('从未更新'), findsOneWidget);
    expect(_summaryText('纯直播订阅 · 2 个源'), findsOneWidget);
    expect(transport.writes, isEmpty);
  });

  testWidgets('updated=false clock-save warning remains visible and reloads without source notification', (tester) async {
    final transport = _ClockTransport(offerChange: true, outcome: 'warning-unchanged');
    var notifications = 0;
    await _mount(tester, transport, () => notifications++);
    await _select(tester);
    await _openAndCheck(tester);
    await _tap(tester, _dialogText('应用更新'));
    expect(transport.applied, isFalse);
    expect(_resultText('订阅已核对，但更新时间未保存，请稍后重试'), findsOneWidget);
    expect(_resultText('订阅内容已更新，但更新时间未保存'), findsNothing);
    expect(find.descendant(of: find.byType(TvboxUpdateResultView), matching: find.text('已更新')), findsNothing);
    _noSecrets();
    expect(notifications, 0);
    await _close(tester);
    expect(notifications, 0);
    expect(transport.loads, 2);
    expect(_summaryText('从未更新'), findsOneWidget);
    expect(transport.writes, isEmpty);
    expect(transport.updates, [{'id': _parentId, 'applyNew': true, 'deleteMissing': false}]);
  });
}
