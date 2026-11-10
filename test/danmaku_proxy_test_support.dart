import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/danmaku_source_page.dart';
import 'package:sourin_spike/ui/settings/global_proxy_settings_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

const savedService = 'https://service-saved.invalid';
const draftService = 'https://service-draft.invalid';
const nextService = 'https://service-next.invalid';
const savedToken = 'saved-fixture-token';
const draftToken = 'draft-fixture-token';
const nextToken = 'next-fixture-token';
const oldProxyUrl = 'http://proxy-old.invalid:7890';
const newProxyUrl = 'http://proxy-new.invalid:8080';
const legacyProxyUrl = 'http://legacy-only.invalid:7900';
const staleVersion = 'obsolete-service-version';
const currentVersion = 'current-service-version';
const staleError = '旧服务探测没有完成，请稍后重试';
const currentError = '当前服务探测没有完成，请稍后重试';

enum ServiceOutcome { success, offline, exception }
enum GlobalEdit { mode, address, none }

class ServiceProbeCall {
  ServiceProbeCall(this.endpoint);
  final DanmakuEndpoint? endpoint;
  final completion = Completer<DanmakuLocalStatus>();
}

class DanmakuProxyFixture {
  late final Future<dynamic> Function(String, Map<String, dynamic>?)?
      _previousTransport;
  late final String? _previousDirectory;
  final calls = <ServiceProbeCall>[];
  final proxyWrites = <Map<String, dynamic>>[];
  final unexpected = <String>[];
  Map<String, dynamic> proxyConfig = {
    'mode': 'custom',
    'url': oldProxyUrl,
    'scope': 'api_only',
  };

  void install() {
    _previousTransport = SourinCore.debugCallAsyncTransport;
    _previousDirectory = DiskCache.dataDir;
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest({
      'dsh.danmaku.endpoint': savedService,
      UiPrefs.danmakuTokenKey: savedToken,
      // Sentinels prove the new global flow does not revive old proxy storage.
      UiPrefs.danmakuProxyModeKey: 'custom',
      UiPrefs.danmakuProxyUrlKey: legacyProxyUrl,
    });
    ProxyCache.reset();
    SourinCore.debugCallAsyncTransport = _transport;
  }

  Future<dynamic> _transport(
    String command,
    Map<String, dynamic>? args,
  ) async {
    switch (command) {
      case 'global_proxy_migration_choices':
        return <dynamic>[];
      case 'list_proxy_configs':
        return {
          SourinApi.globalProxyProvider: Map<String, dynamic>.from(proxyConfig),
        };
      case 'has_proxy_password':
        expect(args!['provider'], SourinApi.globalProxyProvider);
        return {'has': false};
      case 'system_proxy_hint':
        return {'hint': null};
      case 'set_proxy_config':
        expect(args!['provider'], SourinApi.globalProxyProvider);
        final config = Map<String, dynamic>.from(args['config'] as Map);
        proxyWrites.add({
          'provider': args['provider'],
          'config': Map<String, dynamic>.from(config),
        });
        proxyConfig = config;
        return null;
      default:
        // Real service HTTP, native proxy probes and Mopen are never allowed.
        unexpected.add(command);
        throw StateError('Unexpected Danmaku navigation command: $command');
    }
  }

  Future<DanmakuLocalStatus> probe(DanmakuEndpoint? endpoint) {
    final call = ServiceProbeCall(endpoint);
    calls.add(call);
    return call.completion.future;
  }

  void finish(
    int index,
    ServiceOutcome outcome, {
    String version = staleVersion,
    String error = staleError,
  }) {
    final call = calls[index];
    if (call.completion.isCompleted) return;
    if (outcome == ServiceOutcome.exception) {
      call.completion.completeError(DanmakuException(
        error,
        failureKind: DanmakuFailureKind.timeout,
      ));
    } else {
      call.completion.complete(DanmakuLocalStatus(
        online: outcome == ServiceOutcome.success,
        version: outcome == ServiceOutcome.success ? version : null,
        endpoint: call.endpoint,
      ));
    }
  }

  void releasePending() {
    for (var index = 0; index < calls.length; index++) {
      if (!calls[index].completion.isCompleted) {
        finish(index, ServiceOutcome.offline);
      }
    }
  }

  void restore() {
    releasePending();
    SourinCore.debugCallAsyncTransport = _previousTransport;
    DiskCache.debugResetForTest(_previousDirectory);
    UiPrefs.debugResetForTest();
    ProxyCache.reset();
    expect(unexpected, isEmpty);
  }

  Future<void> mount(WidgetTester tester) async {
    // A tall deterministic viewport keeps the real connection and navigation
    // blocks built, so hidden-route assertions cannot pass due to lazy removal.
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 2200);
    addTearDown(tester.view.reset);
    final theme = AppTheme.themeFor(Brightness.dark);
    await tester.pumpWidget(MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: DanmakuSourcePage(
        probeOverride: probe,
        dohOverride: (_) async => <String>[],
        mopenFetchOverride: (_, _) async => <DanmakuComment>[],
      ),
    ));
    addTearDown(() async {
      releasePending();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 400));
    });
    await frames(tester);
    expect(find.byType(DanmakuSourcePage), findsOneWidget);
    expect(find.byType(GlobalProxySettingsPage), findsNothing);
    expectDraft(tester, savedService, savedToken);
    expectSaved(savedService, savedToken);
  }

  Future<void> draft(
    WidgetTester tester, {
    String endpoint = draftService,
    String token = draftToken,
  }) async {
    await tester.ensureVisible(serviceUrl());
    await tester.enterText(serviceUrl(), endpoint);
    await tester.ensureVisible(serviceToken());
    await tester.enterText(serviceToken(), token);
    await tester.pump();
    expectDraft(tester, endpoint, token);
  }

  Future<void> startProbe(
    WidgetTester tester, {
    required String endpoint,
    required String token,
  }) async {
    final previousCount = calls.length;
    await tester.ensureVisible(serviceTest());
    expect(tester.widget<ui.FilledButton>(serviceTest()).onPressed, isNotNull);
    await tester.tap(serviceTest());
    await until(tester, () => calls.length == previousCount + 1,
        'The real service probe entry must be reached exactly once');
    await tester.pump();
    expect(calls.last.endpoint?.baseUrl, endpoint);
    expect(calls.last.endpoint?.token, token);
    expect(find.text('正在测试…'), findsOneWidget);
    expect(tester.widget<ui.FilledButton>(serviceBusy()).onPressed, isNull);
  }

  Future<void> openGlobal(WidgetTester tester) async {
    final entry = find.widgetWithText(ui.OutlinedButton, '全局代理设置');
    await tester.ensureVisible(entry);
    await tester.pump();
    expect(tester.widget<ui.OutlinedButton>(entry).onPressed, isNotNull);
    await tester.tap(entry);
    await frames(tester);
    expect(find.byType(GlobalProxySettingsPage), findsOneWidget);
    expect(find.byType(DanmakuSourcePage), findsNothing,
        reason: 'The real child route must be current before old completion');
    expect(find.byType(DanmakuSourcePage, skipOffstage: false), findsOneWidget);
    expect(find.byType(ProxyPanel), findsOneWidget);
    expect(tester.widget<ProxyPanel>(find.byType(ProxyPanel)).providerId,
        SourinApi.globalProxyProvider);
    expect(tester.widget<ui.ChoiceChip>(globalMode('自定义')).selected, isTrue);
    // A positive existence check guards every hidden feedback-absence check.
    expect(serviceUrl(hidden: true), findsOneWidget);
    expect(serviceToken(hidden: true), findsOneWidget);
    expect(find.descendant(
      of: find.byType(DanmakuSourcePage, skipOffstage: false),
      matching: find.byType(ui.FilledButton, skipOffstage: false),
      skipOffstage: false,
    ), findsOneWidget);
  }

  Future<void> editGlobal(WidgetTester tester, GlobalEdit edit) async {
    if (edit == GlobalEdit.none) {
      expect(proxyWrites, isEmpty);
      return;
    }
    final previousCount = proxyWrites.length;
    if (edit == GlobalEdit.mode) {
      await tester.ensureVisible(globalMode('跟随系统'));
      expect(tester.widget<ui.ChoiceChip>(globalMode('跟随系统')).onSelected,
          isNotNull);
      await tester.tap(globalMode('跟随系统'));
    } else {
      final editor = find.descendant(
        of: find.byType(ProxyPanel),
        matching: find.byType(EditableText),
      ).first;
      await tester.ensureVisible(editor);
      await tester.enterText(editor, newProxyUrl);
      await tester.pump();
      expect(tester.widget<EditableText>(editor).controller.text, newProxyUrl);
      expect(proxyWrites, hasLength(previousCount),
          reason: 'Typing an address stays an unsaved global draft');
      final save = find.widgetWithText(ui.FilledButton, '保存设置');
      await tester.ensureVisible(save);
      await tester.tap(save);
    }
    await until(tester, () => proxyWrites.length == previousCount + 1,
        'The actual global write must reach the existing command seam');
    await frames(tester);
    expectGlobal(edit);
    expect(find.byType(GlobalProxySettingsPage), findsOneWidget);
  }

  Future<void> closeGlobal(WidgetTester tester) async {
    final back = find.descendant(
      of: find.byType(GlobalProxySettingsPage),
      matching: find.byKey(const ValueKey('page-header-back')),
    );
    expect(back, findsOneWidget);
    await tester.tap(back);
    await frames(tester);
    expect(find.byType(GlobalProxySettingsPage), findsNothing);
    expect(find.byType(DanmakuSourcePage), findsOneWidget);
    await tester.ensureVisible(serviceUrl());
    await tester.pump();
  }

  void expectGlobal(GlobalEdit edit) {
    final mode = edit == GlobalEdit.mode ? 'system' : 'custom';
    final url = edit == GlobalEdit.address ? newProxyUrl : oldProxyUrl;
    expect(proxyConfig, {'mode': mode, 'url': url, 'scope': 'api_only'});
    if (edit == GlobalEdit.none) {
      expect(proxyWrites, isEmpty);
    } else {
      expect(proxyWrites, [
        {
          'provider': SourinApi.globalProxyProvider,
          'config': {'mode': mode, 'url': url, 'scope': 'api_only'},
        },
      ]);
    }
    expect(UiPrefs.danmakuProxyMode, 'custom');
    expect(UiPrefs.danmakuProxyUrl, legacyProxyUrl,
        reason: 'The real global route never changes obsolete proxy keys');
  }

  void expectSaved(String endpoint, String token) {
    expect(UiPrefs.danmakuEndpoint, endpoint,
        reason: 'A cancelled service probe cannot persist an unsaved endpoint');
    expect(UiPrefs.danmakuToken, token,
        reason: 'Service Token persistence has the same captured-input owner');
  }

  void expectDraft(
    WidgetTester tester,
    String endpoint,
    String token, {
    bool hidden = false,
  }) {
    expect(tester.widget<EditableText>(serviceUrl(hidden: hidden)).controller.text,
        endpoint);
    expect(tester.widget<EditableText>(serviceToken(hidden: hidden)).controller.text,
        token);
  }

  void expectIdle(WidgetTester tester, {bool hidden = false}) {
    final button = serviceTest(hidden: hidden);
    expect(button, findsOneWidget);
    expect(tester.widget<ui.FilledButton>(button).onPressed, isNotNull);
    expect(find.text('正在测试…', skipOffstage: !hidden), findsNothing);
    expect(serviceBusy(hidden: hidden), findsNothing);
  }
}

Finder serviceUrl({bool hidden = false}) => find.descendant(
  of: find.byType(DanmakuSourcePage, skipOffstage: !hidden),
  matching: find.byWidgetPredicate(
    (widget) => widget is EditableText &&
        widget.keyboardType == TextInputType.url,
    skipOffstage: !hidden,
  ),
  skipOffstage: !hidden,
);

Finder serviceToken({bool hidden = false}) => find.descendant(
  of: find.byType(DanmakuSourcePage, skipOffstage: !hidden),
  matching: find.byType(EditableText, skipOffstage: !hidden),
  skipOffstage: !hidden,
).at(1);

Finder serviceTest({bool hidden = false}) => find.descendant(
  of: find.byType(DanmakuSourcePage, skipOffstage: !hidden),
  matching: find.widgetWithText(ui.FilledButton, '测试连接',
      skipOffstage: !hidden),
  skipOffstage: !hidden,
);

Finder serviceBusy({bool hidden = false}) => find.descendant(
  of: find.byType(DanmakuSourcePage, skipOffstage: !hidden),
  matching: find.widgetWithText(ui.FilledButton, '测试中…',
      skipOffstage: !hidden),
  skipOffstage: !hidden,
);

Finder globalMode(String label) => find.widgetWithText(ui.ChoiceChip, label);

Future<void> frames(WidgetTester tester) async {
  for (var frame = 0; frame < 16; frame++) {
    await tester.pump(const Duration(milliseconds: 30));
  }
}

Future<void> until(
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
