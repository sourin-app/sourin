import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/global_proxy_settings_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

const _oldUrl = 'http://proxy-old.invalid:7890';
const _newUrl = 'http://proxy-new.invalid:8080';
const _oldSuccess = '旧代理探测已成功';
const _oldError = '旧代理探测已失败，请稍后重试';
const _saveError = '旧配置保存已失败，请稍后重试';
const _clearError = '旧配置清除已失败，请稍后重试';
const _currentSuccess = '当前代理探测已成功';
const _currentError = '当前代理探测已失败，请稍后重试';

class _ProxyFixture {
  Map<String, dynamic> config = {
    'mode': 'custom',
    'url': _oldUrl,
    'scope': 'api_only',
  };
  final saves = <Map<String, dynamic>>[];
  final probes = <Map<String, dynamic>>[];
  final unexpected = <String>[];
  Completer<dynamic>? heldProbe;
  Completer<void>? heldSave;
  bool holdNextSave = false;
  bool saveEntered = false;
  var clears = 0;
  Completer<void>? heldClear;
  bool holdNextClear = false;
  bool clearEntered = false;

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    switch (command) {
      case 'global_proxy_migration_choices':
        return <dynamic>[];
      case 'list_proxy_configs':
        return {SourinApi.globalProxyProvider: Map<String, dynamic>.from(config)};
      case 'has_proxy_password':
        expect(args!['provider'], SourinApi.globalProxyProvider);
        return {'has': false};
      case 'system_proxy_hint':
        return {'hint': null};
      case 'set_proxy_config':
        expect(args!['provider'], SourinApi.globalProxyProvider);
        final captured = Map<String, dynamic>.from(args['config'] as Map);
        saves.add(captured);
        // Commit the fixture's data before delaying the first reply. This
        // models a late completion, not invented out-of-order native writes.
        config = captured;
        if (holdNextSave) {
          holdNextSave = false;
          saveEntered = true;
          await heldSave!.future;
        }
        return null;
      case 'clear_proxy_config':
        expect(args!['provider'], SourinApi.globalProxyProvider);
        clears++;
        // As with set_proxy_config, model the committed mutation before a
        // delayed reply, so this fixture invents no reordered native writes.
        config = {'mode': 'direct', 'scope': 'api_only'};
        if (holdNextClear) {
          holdNextClear = false;
          clearEntered = true;
          await heldClear!.future;
        }
        return null;
      case 'test_proxy':
        expect(args!['provider'], SourinApi.globalProxyProvider);
        probes.add(Map<String, dynamic>.from(config));
        final held = heldProbe;
        if (held != null) return held.future;
        // This is raw core JSON. The real API must deserialize ProxyTestResult.
        return {'ok': true, 'message': _currentSuccess};
      default:
        unexpected.add(command);
        throw StateError('Unexpected global proxy fixture command: $command');
    }
  }

  void finishProbe({required bool error, required bool stale}) {
    final held = heldProbe!;
    if (held.isCompleted) return;
    if (error) {
      held.completeError(SourinCoreException(
        stale ? _oldError : _currentError,
        'network',
      ));
    } else {
      held.complete({'ok': true, 'message': stale ? _oldSuccess : _currentSuccess});
    }
  }

  void release() {
    if (heldProbe != null && !heldProbe!.isCompleted) {
      heldProbe!.complete({'ok': true, 'message': 'Released unused fixture probe'});
    }
    if (heldSave != null && !heldSave!.isCompleted) heldSave!.complete();
    if (heldClear != null && !heldClear!.isCompleted) heldClear!.complete();
  }
}

Finder _mode(String label) => find.widgetWithText(ui.ChoiceChip, label);
Finder _testButton() => find.widgetWithText(ui.OutlinedButton, '测试连接');
Finder _urlField() => find.descendant(
  of: find.byType(ProxyPanel),
  matching: find.byType(EditableText),
).first;

Future<void> _until(
  WidgetTester tester,
  bool Function() condition,
  String reason,
) async {
  for (var frame = 0; frame < 60; frame++) {
    if (condition()) return;
    await tester.pump(const Duration(milliseconds: 10));
  }
  expect(condition(), isTrue, reason: reason);
}

void main() {
  late _ProxyFixture fixture;
  late Future<dynamic> Function(String, Map<String, dynamic>?)? previousTransport;
  late String? previousDirectory;

  setUp(() {
    previousTransport = SourinCore.debugCallAsyncTransport;
    previousDirectory = DiskCache.dataDir;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest(<String, String>{});
    ProxyCache.reset();
    fixture = _ProxyFixture();
    SourinCore.debugCallAsyncTransport = fixture.call;
  });

  tearDown(() {
    fixture.release();
    SourinCore.debugCallAsyncTransport = previousTransport;
    DiskCache.debugResetForTest(previousDirectory);
    UiPrefs.debugResetForTest(<String, String>{});
    ProxyCache.reset();
    expect(fixture.unexpected, isEmpty);
  });

  Future<void> mount(WidgetTester tester, {VoidCallback? onSaved}) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1100);
    addTearDown(tester.view.reset);
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: onSaved == null
          ? const GlobalProxySettingsPage()
          : Scaffold(
              body: ProxyPanel(
                providerId: SourinApi.globalProxyProvider,
                providerName: '全局',
                defaultOpen: true,
                onSaved: onSaved,
              ),
            ),
    ));
    addTearDown(() async {
      fixture.release();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
    await tester.pumpAndSettle();
    expect(find.byType(GlobalProxySettingsPage),
        onSaved == null ? findsOneWidget : findsNothing);
    expect(find.byType(ProxyPanel), findsOneWidget);
    expect(tester.widget<ProxyPanel>(find.byType(ProxyPanel)).providerId,
        SourinApi.globalProxyProvider);
    expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
    expect(tester.widget<EditableText>(_urlField()).controller.text, _oldUrl);
  }

  Future<void> startHeldProbe(WidgetTester tester) async {
    fixture.heldProbe = Completer<dynamic>();
    await tester.tap(_testButton());
    await _until(tester, () => fixture.probes.length == 1,
        'The actual test_proxy command must be entered after its save');
    await tester.pump();
    expect(find.text('测试中…'), findsOneWidget);
    expect(fixture.probes.single['mode'], 'custom');
    expect(fixture.probes.single['url'], _oldUrl);
    expect(fixture.heldProbe!.isCompleted, isFalse);
  }

  for (final editUrl in [false, true]) {
    for (final error in [false, true]) {
      testWidgets(
        '${editUrl ? 'URL edit' : 'mode change'} rejects an older held ${error ? 'exception' : 'success'} result',
        (tester) async {
          await mount(tester);
          await startHeldProbe(tester);
          try {
            if (editUrl) {
              await tester.enterText(_urlField(), _newUrl);
              await tester.pump();
              expect(tester.widget<EditableText>(_urlField()).controller.text,
                  _newUrl, reason: 'Editing stays available during a probe');
            } else {
              expect(tester.widget<ui.ChoiceChip>(_mode('直连')).onSelected,
                  isNotNull, reason: 'Do not fix ownership by disabling mode changes');
              await tester.tap(_mode('直连'));
              await _until(tester, () => fixture.config['mode'] == 'direct',
                  'The newer mode save must reach the real command seam');
              await tester.pump();
              expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue);
            }
          } finally {
            fixture.finishProbe(error: error, stale: true);
          }
          await tester.pumpAndSettle();
          expect(find.text(_oldSuccess), findsNothing);
          expect(find.text(_oldError), findsNothing,
              reason: 'A result for the old configuration cannot describe the new view');
          expect(find.text('测试中…'), findsNothing);
          if (editUrl) {
            expect(tester.widget<EditableText>(_urlField()).controller.text, _newUrl);
            expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
            expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull);
            expect(fixture.config['url'], _oldUrl,
                reason: 'Typing is a draft edit; no unsolicited save is introduced');
          } else {
            expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue);
            expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNull);
            expect(fixture.config['mode'], 'direct');
          }
          expect(fixture.probes, hasLength(1), reason: 'No automatic replacement network probe');
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final error in [false, true]) {
    testWidgets('switching away and back rejects an older held ${error ? 'exception' : 'success'} result', (
      tester,
    ) async {
      await mount(tester);
      await startHeldProbe(tester);
      try {
        expect(tester.widget<ui.ChoiceChip>(_mode('直连')).onSelected,
            isNotNull, reason: 'Mode switching stays available during a probe');
        await tester.tap(_mode('直连'));
        await _until(tester, () => fixture.config['mode'] == 'direct',
            'The intervening direct mode must be saved');
        await tester.pump();
        expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue);
        expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).onSelected, isNotNull);
        await tester.tap(_mode('自定义'));
        await _until(tester, () => fixture.config['mode'] == 'custom',
            'The same custom mode is selected again before the old reply');
        await tester.pump();
        expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
        expect(tester.widget<EditableText>(_urlField()).controller.text, _oldUrl);
        expect(fixture.config['url'], _oldUrl,
            reason: 'The resulting values match the old configuration exactly');
      } finally {
        fixture.finishProbe(error: error, stale: true);
      }
      await tester.pumpAndSettle();
      expect(find.text(_oldSuccess), findsNothing);
      expect(find.text(_oldError), findsNothing,
          reason: 'Returning to equal values does not restore old request ownership');
      expect(find.text('测试中…'), findsNothing);
      expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
      expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull);
      expect(fixture.probes, hasLength(1), reason: 'No automatic replacement probe');
      expect(fixture.saves, hasLength(3));
      expect(tester.takeException(), isNull);
    });
  }

  for (final error in [false, true]) {
    testWidgets('an unchanged configuration displays its current ${error ? 'exception' : 'success'}', (
      tester,
    ) async {
      await mount(tester);
      await startHeldProbe(tester);
      fixture.finishProbe(error: error, stale: false);
      await tester.pumpAndSettle();
      expect(find.text(error ? _currentError : _currentSuccess), findsOneWidget,
          reason: 'Positive control for the real API parser and rendered result path');
      expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
      expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull);
      expect(fixture.probes, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final editUrl in [false, true]) {
    testWidgets('${editUrl ? 'editing URL' : 'changing mode'} during the prerequisite save prevents an obsolete probe', (
      tester,
    ) async {
      await mount(tester);
      fixture.heldSave = Completer<void>();
      fixture.holdNextSave = true;
      await tester.tap(_testButton());
      await _until(tester, () => fixture.saveEntered,
          'The actual prerequisite configuration save must be entered');
      expect(fixture.probes, isEmpty);
      try {
        if (editUrl) {
          await tester.enterText(_urlField(), _newUrl);
        } else {
          await tester.tap(_mode('直连'));
          await _until(tester, () => fixture.config['mode'] == 'direct',
              'The newer direct write completes before the old save reply');
        }
      } finally {
        fixture.heldSave!.complete();
      }
      await tester.pumpAndSettle();
      expect(fixture.probes, isEmpty,
          reason: 'Configuration ownership must be rechecked before test_proxy dispatch');
      expect(find.text(_currentSuccess), findsNothing);
      expect(find.text('测试中…'), findsNothing);
      if (editUrl) {
        expect(tester.widget<EditableText>(_urlField()).controller.text, _newUrl);
        expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
      } else {
        expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue,
            reason: 'An old save reply must not restore its captured mode');
        expect(fixture.config['mode'], 'direct');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('switching away and back during the prerequisite save prevents an obsolete probe', (
    tester,
  ) async {
    await mount(tester);
    fixture.heldSave = Completer<void>();
    fixture.holdNextSave = true;
    await tester.tap(_testButton());
    await _until(tester, () => fixture.saveEntered, 'The old prerequisite save is pending');
    expect(fixture.probes, isEmpty);
    try {
      await tester.tap(_mode('直连'));
      await _until(tester, () => fixture.config['mode'] == 'direct',
          'The intervening direct write completes before the old save reply');
      await tester.pump();
      expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue);
      await tester.tap(_mode('自定义'));
      await _until(tester, () => fixture.config['mode'] == 'custom',
          'The same custom configuration is selected again');
      await tester.pump();
      expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
      expect(fixture.config['url'], _oldUrl);
    } finally {
      fixture.heldSave!.complete();
    }
    await tester.pumpAndSettle();
    expect(fixture.probes, isEmpty,
        reason: 'An equal mode/configuration cannot renew old save-to-probe ownership');
    expect(find.text(_currentSuccess), findsNothing);
    expect(find.text('测试中…'), findsNothing);
    expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
    expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull);
    expect(fixture.saves, hasLength(3));
    expect(tester.takeException(), isNull);
  });

  testWidgets('an obsolete prerequisite save failure does not label the newer mode', (
    tester,
  ) async {
    await mount(tester);
    fixture.heldSave = Completer<void>();
    fixture.holdNextSave = true;
    await tester.tap(_testButton());
    await _until(tester, () => fixture.saveEntered, 'Old save is genuinely pending');
    try {
      await tester.tap(_mode('直连'));
      await _until(tester, () => fixture.config['mode'] == 'direct',
          'New direct mode is saved');
    } finally {
      fixture.heldSave!.completeError(SourinCoreException(_saveError, 'network'));
    }
    await tester.pumpAndSettle();
    expect(find.textContaining(_saveError), findsNothing);
    expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue);
    expect(fixture.probes, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an unchanged prerequisite save starts one normal probe after completion', (
    tester,
  ) async {
    await mount(tester);
    fixture.heldSave = Completer<void>();
    fixture.holdNextSave = true;
    await tester.tap(_testButton());
    await _until(tester, () => fixture.saveEntered, 'Current save is pending');
    expect(fixture.probes, isEmpty);
    fixture.heldSave!.complete();
    await tester.pumpAndSettle();
    expect(fixture.probes, hasLength(1));
    expect(fixture.probes.single['url'], _oldUrl);
    expect(find.text(_currentSuccess), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final error in [false, true]) {
    testWidgets('clearing proxy rejects an older held ${error ? 'exception' : 'success'} result', (
      tester,
    ) async {
      await mount(tester);
      await startHeldProbe(tester);
      try {
        final clearButton = find.widgetWithText(ui.TextButton, '清除代理');
        expect(tester.widget<ui.TextButton>(clearButton).onPressed, isNotNull,
            reason: 'Clearing stays available during the held probe');
        await tester.tap(clearButton);
        await _until(tester, () => fixture.clears == 1,
            'The actual clear_proxy_config command must be entered');
        await tester.pump();
        expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue);
      } finally {
        fixture.finishProbe(error: error, stale: true);
      }
      await tester.pumpAndSettle();
      expect(find.text(_oldSuccess), findsNothing);
      expect(find.text(_oldError), findsNothing,
          reason: 'A completed clear invalidates feedback for the removed configuration');
      expect(find.text('测试中…'), findsNothing);
      expect(tester.widget<ui.ChoiceChip>(_mode('直连')).selected, isTrue);
      expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNull);
      expect(fixture.config['mode'], 'direct');
      expect(fixture.clears, 1);
      expect(fixture.probes, hasLength(1));
      expect(tester.takeException(), isNull);
    });
  }

  for (final error in [false, true]) {
    testWidgets('a held clear ${error ? 'failure' : 'success'} preserves a newer mode and its callback contract', (
      tester,
    ) async {
      var saved = 0;
      // Mount the same real global ProxyPanel directly to observe the public
      // onSaved contract; the other races exercise the real global page entry.
      await mount(tester, onSaved: () => saved++);
      fixture.heldClear = Completer<void>();
      fixture.holdNextClear = true;
      await tester.tap(find.widgetWithText(ui.TextButton, '清除代理'));
      await _until(tester, () => fixture.clearEntered,
          'The actual clear response must be held before the newer edit');
      expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
      try {
        expect(tester.widget<ui.ChoiceChip>(_mode('跟随系统')).onSelected, isNotNull);
        await tester.tap(_mode('跟随系统'));
        await _until(tester, () => saved == 1,
            'The newer system-mode write completes and notifies the host');
        await tester.pump();
        expect(tester.widget<ui.ChoiceChip>(_mode('跟随系统')).selected, isTrue);
        expect(fixture.config['mode'], 'system');
      } finally {
        if (error) {
          fixture.heldClear!.completeError(SourinCoreException(_clearError, 'network'));
        } else {
          fixture.heldClear!.complete();
        }
      }
      await tester.pumpAndSettle();
      expect(tester.widget<ui.ChoiceChip>(_mode('跟随系统')).selected, isTrue,
          reason: 'An old clear completion cannot reset the newer local mode');
      expect(find.textContaining(_clearError), findsNothing,
          reason: 'An old clear failure cannot label the newer configuration');
      expect(saved, error ? 1 : 2,
          reason: 'Every successful persisted write notifies while mounted');
      expect(fixture.config['mode'], 'system',
          reason: 'The fixture commits clear before the newer write, never out of order');
      expect(fixture.clears, 1);
      expect(fixture.saves, hasLength(1));
      expect(fixture.probes, isEmpty);
      expect(find.text('测试中…'), findsNothing);
      expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('an explicit test after a held clear keeps its saved configuration and current result', (
    tester,
  ) async {
    await mount(tester);
    fixture.heldClear = Completer<void>();
    fixture.holdNextClear = true;
    fixture.heldProbe = Completer<dynamic>();
    await tester.tap(find.widgetWithText(ui.TextButton, '清除代理'));
    await _until(tester, () => fixture.clearEntered,
        'The real clear reply is pending before the later explicit test');
    await tester.pump();
    expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
    expect(tester.widget<EditableText>(_urlField()).controller.text, _oldUrl);
    try {
      expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull,
          reason: 'An explicit test stays available while the clear reply is pending');
      await tester.tap(_testButton());
      await _until(tester, () => fixture.probes.length == 1,
          'The later explicit test must save the real current draft and enter test_proxy');
      await tester.pump();
      expect(fixture.saves, hasLength(1));
      expect(fixture.probes.single['mode'], 'custom');
      expect(fixture.probes.single['url'], _oldUrl);
      expect(fixture.config['mode'], 'custom',
          reason: 'The fixture commits clear before the newer explicit save');
      expect(find.text('测试中…'), findsOneWidget);
      fixture.heldClear!.complete();
      await tester.pump();
      await tester.pump();
      expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue,
          reason: 'A later explicit test-save intent makes the older clear reset obsolete');
      expect(tester.widget<EditableText>(_urlField()).controller.text, _oldUrl);
      expect(find.text('测试中…'), findsOneWidget,
          reason: 'The old clear response cannot cancel the newer current probe');
      expect(find.text(_currentSuccess), findsNothing);
    } finally {
      if (!fixture.heldClear!.isCompleted) fixture.heldClear!.complete();
      fixture.finishProbe(error: false, stale: false);
    }
    await tester.pumpAndSettle();
    expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
    expect(tester.widget<EditableText>(_urlField()).controller.text, _oldUrl);
    expect(find.text(_currentSuccess), findsOneWidget,
        reason: 'The latest explicitly saved configuration owns its real parsed result');
    expect(find.text('测试中…'), findsNothing);
    expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull);
    expect(fixture.clears, 1);
    expect(fixture.saves, hasLength(1));
    expect(fixture.probes, hasLength(1));
    expect(fixture.config['mode'], 'custom');
    expect(fixture.config['url'], _oldUrl);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an ordinary save after a held clear owns the draft before its own reply', (
    tester,
  ) async {
    await mount(tester);
    fixture.heldClear = Completer<void>();
    fixture.holdNextClear = true;
    await tester.tap(find.widgetWithText(ui.TextButton, '清除代理'));
    await _until(tester, () => fixture.clearEntered,
        'The real clear reply is pending before the later explicit save');
    await tester.pump();
    fixture.heldSave = Completer<void>();
    fixture.holdNextSave = true;
    final saveButton = find.widgetWithText(ui.FilledButton, '保存设置');
    try {
      expect(tester.widget<ui.FilledButton>(saveButton).onPressed, isNotNull,
          reason: 'Ordinary save stays available while the clear reply is pending');
      await tester.tap(saveButton);
      await _until(tester, () => fixture.saveEntered,
          'The later save intent is dispatched, with its own response still held');
      expect(fixture.config['mode'], 'custom');
      expect(fixture.config['url'], _oldUrl);
      expect(fixture.heldSave!.isCompleted, isFalse);
      fixture.heldClear!.complete();
      await tester.pump();
      await tester.pump();
      expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue,
          reason: 'Save intent supersedes old clear locally before the save reply arrives');
      expect(tester.widget<EditableText>(_urlField()).controller.text, _oldUrl);
      expect(fixture.heldSave!.isCompleted, isFalse);
      expect(fixture.probes, isEmpty, reason: 'Saving introduces no unsolicited probe');
    } finally {
      if (!fixture.heldClear!.isCompleted) fixture.heldClear!.complete();
      if (!fixture.heldSave!.isCompleted) fixture.heldSave!.complete();
    }
    await tester.pumpAndSettle();
    expect(tester.widget<ui.ChoiceChip>(_mode('自定义')).selected, isTrue);
    expect(tester.widget<EditableText>(_urlField()).controller.text, _oldUrl);
    expect(find.text('测试中…'), findsNothing);
    expect(tester.widget<ui.OutlinedButton>(_testButton()).onPressed, isNotNull);
    expect(fixture.clears, 1);
    expect(fixture.saves, hasLength(1));
    expect(fixture.probes, isEmpty);
    expect(fixture.config['mode'], 'custom');
    expect(fixture.config['url'], _oldUrl);
    expect(tester.takeException(), isNull);
  });
}
