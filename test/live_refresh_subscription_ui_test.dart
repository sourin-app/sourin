// Independent behavioral controls: this file references only pre-existing
// public Dart symbols. The old UI must compile it and fail on live behavior.
// No native library, account data, profile or network is used.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

const _representative = 'a-vod';
const _parentUrl = 'https://parent.invalid/a.json';
const _newLive = <String, dynamic>{
  'id': 'new-live',
  'name': '新直播一',
  'url': 'https://playlist.invalid/new.m3u',
};
const _oldLive = <String, dynamic>{'id': 'old-live', 'name': '旧直播一'};

Map<String, dynamic> _copy(Map<String, dynamic> value) =>
    (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();

Map<String, dynamic> _item({
  List<Map<String, dynamic>> added = const [],
  List<Map<String, dynamic>> removed = const [],
  List<Map<String, dynamic>> changed = const [],
  Map<String, dynamic> live = const {},
}) => <String, dynamic>{
  'sourceUrl': _parentUrl,
  'ids': [_representative],
  'ok': true,
  'remoteTotalSites': 3,
  'remoteConvertible': 3,
  'remoteUnsupported': 0,
  'added': added,
  'removed': removed,
  'changed': changed,
  'unchanged': 3,
  'unchangedForeign': 0,
  ...live,
};

Map<String, dynamic> _check(Map<String, dynamic> item) => <String, dynamic>{
  'items': [item],
  'checked': 1,
  'skipped': 0,
  'skippedIds': <String>[],
};

Map<String, dynamic> _update({
  bool updated = true,
  String? reason,
  List<Map<String, dynamic>> added = const [],
  List<Map<String, dynamic>> changed = const [],
  Map<String, dynamic> live = const {},
}) => <String, dynamic>{
  'updated': updated,
  if (reason != null) 'reason': reason,
  'sourceUrl': _parentUrl,
  'added': added,
  'changed': changed,
  'removed': <Object>[],
  'deleted': <Object>[],
  'notApplied': <Object>[],
  'failed': <Object>[],
  'unchanged': 3,
  'unchangedForeign': 0,
  'skippedByType': 0,
  ...live,
};

class _RawTransport {
  _RawTransport({required this.initial, required this.applied, this.after});

  final Map<String, dynamic> initial;
  final Map<String, dynamic> applied;
  final Map<String, dynamic>? after;
  final checks = <Map<String, dynamic>>[];
  final updates = <Map<String, dynamic>>[];
  final calls = <String>[];

  void install() {
    final savedTransport = SourinCore.debugCallAsyncTransport;
    final savedRestoreFetcher = SourinApi.debugRestoreFailuresFetcher;
    SourinApi.debugRestoreFailuresFetcher = null;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      calls.add(command);
      switch (command) {
        case 'check_tvbox_updates':
          checks.add(_copy(args ?? <String, dynamic>{}));
          return _copy(
            updates.isNotEmpty && applied['updated'] == true
                ? after ?? initial
                : initial,
          );
        case 'update_tvbox_source':
          updates.add(_copy(args ?? <String, dynamic>{}));
          return _copy(applied);
        case 'restore_failures':
          return <String, dynamic>{'count': 0, 'items': <Object>[]};
        default:
          throw StateError('Unexpected command: $command');
      }
    };
    addTearDown(() {
      SourinCore.debugCallAsyncTransport = savedTransport;
      SourinApi.debugRestoreFailuresFetcher = savedRestoreFetcher;
    });
  }

  void expectUpdate({bool applyNew = true, bool deleteMissing = false}) {
    expect(updates, [
      {
        'id': _representative,
        'applyNew': applyNew,
        'deleteMissing': deleteMissing,
      },
    ]);
  }
}

Widget _host(Widget body) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: body),
  );
}

void _configureView(WidgetTester tester) {
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

Future<void> _openDialog(
  WidgetTester tester, {
  required ValueChanged<bool> onClosed,
}) async {
  _configureView(tester);
  await tester.pumpWidget(
    _host(
      Builder(
        builder: (context) => TextButton(
          onPressed: () async {
            onClosed(
              await TvboxUpdateDialog.show(
                context,
                id: _representative,
                name: '订阅甲',
                sourceUrl: _parentUrl,
              ),
            );
          },
          child: const Text('打开订阅更新'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await _tap(tester, find.text('打开订阅更新'));
  expect(find.byType(TvboxUpdateDialog), findsOneWidget);
}

Finder _resultText(String text) => find.descendant(
  of: find.byType(TvboxUpdateResultView),
  matching: find.textContaining(text),
);

Finder _toggle(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byType(ui.SwitchListTile),
);

Future<void> _closeDialog(WidgetTester tester) async {
  await _tap(tester, find.text('关闭'));
  expect(find.byType(TvboxUpdateDialog), findsNothing);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets(
    'live-only JSON reaches actual check, default application and close callback',
    (tester) async {
      final transport = _RawTransport(
        initial: _check(
          _item(
            live: {
              'liveHasChanges': true,
              'liveAdded': [_newLive],
              'liveRemoved': [_oldLive],
            },
          ),
        ),
        applied: _update(
          live: {
            'liveAdded': [_newLive],
            'liveRemoved': [_oldLive],
            'liveNotApplied': <Object>[],
            'liveDeleted': <Object>[],
            'liveMembershipChanged': true,
          },
        ),
        after: _check(_item()),
      )..install();
      bool? closed;
      await _openDialog(tester, onClosed: (value) => closed = value);
      expect(transport.checks, isEmpty);
      expect(transport.updates, isEmpty);
      await _tap(tester, find.text('检测更新'));
      expect(transport.checks, [
        {'id': _representative},
      ]);
      expect(transport.updates, isEmpty);
      expect(find.text('发现更新：直播新增 1 · 直播待解除归属 1（播放列表保留）'), findsOneWidget);
      expect(find.textContaining('待加入此订阅的直播：新直播一'), findsOneWidget);
      expect(find.textContaining('待解除此订阅归属的直播：旧直播一'), findsOneWidget);
      expect(
        tester.widget<ui.SwitchListTile>(_toggle('同时加入新增站点')).value,
        isTrue,
      );
      expect(
        tester.widget<ui.SwitchListTile>(_toggle('同时删除远端已消失的站')).value,
        isFalse,
      );
      await _tap(tester, find.text('应用更新'));
      transport.expectUpdate();
      expect(transport.checks, [
        {'id': _representative},
        {'id': _representative},
      ]);
      expect(_resultText('直播已加入此订阅 1：新直播一'), findsOneWidget);
      expect(_resultText('直播已解除此订阅归属 1：旧直播一'), findsOneWidget);
      expect(_resultText('播放列表保留'), findsOneWidget);
      expect(_resultText('新增 0 · 变更 0 · 删除 0'), findsNothing);
      expect(_resultText('直播已删除'), findsNothing);
      expect(_resultText('https://playlist.invalid'), findsNothing);
      expect(find.text('已是最新（远端 3 个可转换站点）'), findsOneWidget);
      expect(transport.calls, contains('restore_failures'));
      await _closeDialog(tester);
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'real apply switches send false and true, and updated=false shows skipped live',
    (tester) async {
      final transport = _RawTransport(
        initial: _check(
          _item(
            live: {
              'liveHasChanges': true,
              'liveAdded': [_newLive],
            },
          ),
        ),
        applied: _update(
          updated: false,
          reason: '未添加新的直播来源',
          live: {
            'liveAdded': <Object>[],
            'liveRemoved': <Object>[],
            'liveNotApplied': [_newLive],
            'liveDeleted': <Object>[],
            'liveMembershipChanged': false,
          },
        ),
      )..install();
      bool? closed;
      await _openDialog(tester, onClosed: (value) => closed = value);
      await _tap(tester, find.text('检测更新'));
      expect(
        find.text('应用更新'),
        findsOneWidget,
        reason: '直播新增的原始 JSON 必须开启真实应用区，用户才能选择是否加入直播。',
      );
      await _tap(tester, find.text('同时加入新增站点'));
      await _tap(tester, find.text('同时删除远端已消失的站'));
      expect(
        tester.widget<ui.SwitchListTile>(_toggle('同时加入新增站点')).value,
        isFalse,
      );
      expect(
        tester.widget<ui.SwitchListTile>(_toggle('同时删除远端已消失的站')).value,
        isTrue,
      );
      expect(find.textContaining('此开关只删除点播站，直播播放列表保留'), findsOneWidget);
      await _tap(tester, find.text('应用更新'));
      transport.expectUpdate(applyNew: false, deleteMissing: true);
      expect(transport.checks, [
        {'id': _representative},
      ]);
      expect(_resultText('未添加新的直播来源'), findsOneWidget);
      expect(_resultText('按你的选择未加入直播 1：新直播一'), findsOneWidget);
      expect(_resultText('直播已加入此订阅'), findsNothing);
      expect(_resultText('直播已解除此订阅归属'), findsNothing);
      expect(_resultText('直播已删除'), findsNothing);
      expect(_resultText('applyNew'), findsNothing);
      await _closeDialog(tester);
      expect(closed, isFalse);
    },
  );

  testWidgets(
    'live removal rows alone enable real application and report retained playlists',
    (tester) async {
      final transport = _RawTransport(
        initial: _check(
          _item(
            live: {
              'liveRemoved': [_oldLive],
            },
          ),
        ),
        applied: _update(
          live: {
            'liveRemoved': [_oldLive],
            'liveDeleted': <Object>[],
            'liveMembershipChanged': true,
          },
        ),
        after: _check(_item()),
      )..install();
      bool? closed;
      await _openDialog(tester, onClosed: (value) => closed = value);
      await _tap(tester, find.text('检测更新'));
      expect(find.text('发现更新：直播待解除归属 1（播放列表保留）'), findsOneWidget);
      expect(transport.updates, isEmpty);
      await _tap(tester, find.text('应用更新'));
      transport.expectUpdate();
      expect(_resultText('直播已解除此订阅归属 1：旧直播一'), findsOneWidget);
      expect(_resultText('播放列表保留'), findsOneWidget);
      expect(_resultText('直播已删除'), findsNothing);
      expect(_resultText('删除 1'), findsNothing);
      await _closeDialog(tester);
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'flag-only live difference stays actionable without claiming zero changes',
    (tester) async {
      final transport = _RawTransport(
        initial: _check(_item(live: {'liveHasChanges': true})),
        applied: _update(live: {'liveMembershipChanged': true}),
        after: _check(_item()),
      )..install();
      bool? closed;
      await _openDialog(tester, onClosed: (value) => closed = value);
      await _tap(tester, find.text('检测更新'));
      expect(find.text('发现更新：直播归属有变化'), findsOneWidget);
      expect(find.text('远端直播归属有变化'), findsOneWidget);
      expect(find.text('远端有 0 处变化'), findsNothing);
      expect(find.textContaining('已是最新'), findsNothing);
      await _tap(tester, find.text('应用更新'));
      transport.expectUpdate();
      expect(_resultText('直播订阅归属已更新，播放列表保留。'), findsOneWidget);
      expect(_resultText('新增 0 · 变更 0 · 删除 0'), findsNothing);
      await _closeDialog(tester);
      expect(closed, isTrue);
    },
  );

  for (final removedOnly in [false, true]) {
    testWidgets(
      removedOnly
          ? 'old VOD removal-only JSON keeps its report-only gate'
          : 'old unchanged JSON preserves latest summary and no application',
      (tester) async {
        final oldItem = _item(
          removed: removedOnly
              ? [
                  {
                    'id': 'gone-vod',
                    'key': 'gone',
                    'name': '旧点播站',
                    'api': 'https://vod.invalid/gone',
                  },
                ]
              : const [],
        );
        final parsed = TvboxUpdateItem.fromJson(oldItem);
        expect(parsed.hasChanges, isFalse);
        expect(tvboxProbeOf(parsed).text, '能用（远端 3 个可转换站点）');
        final transport = _RawTransport(
          initial: _check(oldItem),
          applied: _update(updated: false),
        )..install();
        bool? closed;
        await _openDialog(tester, onClosed: (value) => closed = value);
        await _tap(tester, find.text('检测更新'));
        expect(find.text('已是最新（远端 3 个可转换站点）'), findsOneWidget);
        expect(find.text('应用更新'), findsNothing);
        expect(find.byType(ui.SwitchListTile), findsNothing);
        if (removedOnly) {
          expect(find.text('远端配置里已经没有这些站（默认不删，只报告）：'), findsOneWidget);
          expect(find.text('· 旧点播站'), findsOneWidget);
        }
        expect(transport.updates, isEmpty);
        await _closeDialog(tester);
        expect(closed, isFalse);
      },
    );
  }

  testWidgets(
    'old VOD added JSON preserves application flags and result counts',
    (tester) async {
      const site = <String, dynamic>{
        'key': 'new-vod',
        'name': '新增点播站',
        'api': 'https://vod.invalid/new',
        'persisted': true,
      };
      final transport = _RawTransport(
        initial: _check(_item(added: [site])),
        applied: _update(added: [site]),
        after: _check(_item()),
      )..install();
      bool? closed;
      await _openDialog(tester, onClosed: (value) => closed = value);
      await _tap(tester, find.text('检测更新'));
      expect(find.text('发现更新：新增 1 · 变更 0'), findsOneWidget);
      expect(find.text('新增 1 个站 · 变更 0 个接口'), findsOneWidget);
      expect(find.text('同时加入新增站点'), findsOneWidget);
      expect(find.text('同时删除远端已消失的站'), findsOneWidget);
      await _tap(tester, find.text('应用更新'));
      transport.expectUpdate();
      expect(_resultText('新增 1 · 变更 0 · 删除 0'), findsOneWidget);
      expect(_resultText('直播'), findsNothing);
      await _closeDialog(tester);
      expect(closed, isTrue);
    },
  );

  testWidgets(
    'default manage panel transports live probe, default update and public result',
    (tester) async {
      _configureView(tester);
      final transport = _RawTransport(
        initial: _check(
          _item(
            live: {
              'liveHasChanges': true,
              'liveAdded': [_newLive],
            },
          ),
        ),
        applied: _update(
          live: {
            'liveAdded': [_newLive],
            'liveMembershipChanged': true,
          },
        ),
        after: _check(_item()),
      )..install();
      await tester.pumpWidget(
        _host(
          const SingleChildScrollView(
            child: TvboxSourceManagePanel(
              id: _representative,
              name: '订阅甲',
              sourceUrl: _parentUrl,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(transport.checks, isEmpty);
      expect(transport.updates, isEmpty);
      await _tap(tester, find.byKey(const ValueKey('tvbox-manage-probe')));
      expect(find.text('能用，且远端有更新：直播新增 1'), findsOneWidget);
      expect(transport.checks, [
        {'id': _representative},
      ]);
      expect(transport.updates, isEmpty);
      expect(
        find.text('立即更新会加入新增点播站和直播；默认不删点播站。已消失直播只解除此订阅归属，播放列表保留。'),
        findsOneWidget,
      );
      await _tap(tester, find.byKey(const ValueKey('tvbox-manage-update')));
      transport.expectUpdate();
      expect(transport.checks, [
        {'id': _representative},
        {'id': _representative},
      ]);
      expect(find.byType(TvboxUpdateResultView), findsOneWidget);
      expect(_resultText('直播已加入此订阅 1：新直播一'), findsOneWidget);
      expect(_resultText('新增 0 · 变更 0 · 删除 0'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'public updated=false result independently preserves live skipped names',
    (tester) async {
      _configureView(tester);
      final raw = _update(
        updated: false,
        reason: '未添加新的直播来源',
        live: {
          'liveNotApplied': [_newLive],
        },
      );
      final transport = _RawTransport(initial: _check(_item()), applied: raw)
        ..install();
      await tester.pumpWidget(
        _host(
          SingleChildScrollView(
            child: TvboxUpdateResultView(
              result: TvboxSourceUpdate.fromJson(_copy(raw)),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(_resultText('按你的选择未加入直播 1：新直播一'), findsOneWidget);
      expect(_resultText('直播已加入此订阅'), findsNothing);
      expect(_resultText('直播已删除'), findsNothing);
      expect(transport.updates, isEmpty);
      expect(transport.checks, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
