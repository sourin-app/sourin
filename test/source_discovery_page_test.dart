import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_discovery_page.dart';
import 'package:sourin_spike/ui/settings/global_proxy_settings_page.dart';
import 'package:sourin_spike/ui/widgets/proxy_panel.dart';

Map<String, dynamic> _snapshot({
  bool automatic = false,
  bool running = false,
  bool installed = false,
  bool unread = true,
  int lastScan = 100,
}) => {
  'automatic': automatic,
  'running': running,
  'lastScan': lastScan,
  'candidates': [
    {
      'id': 'ready',
      'name': 'Synthetic catalog',
      'repository': 'fixture/public-config',
      'status': 'ready',
      'message': '分类与内容接口校验通过',
      'installed': installed,
      if (installed) 'providerId': 'github-ready',
    },
  ],
  'notices': [
    {'at': lastScan, 'text': '发现 1 个可启用的候选', 'unread': unread},
  ],
};

void _transport(
  Future<dynamic> Function(String, Map<String, dynamic>?) transport,
) {
  SourceDiscoveryService.current.value = null;
  SourinCore.debugCallAsyncTransport = transport;
  addTearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourceDiscoveryService.current.value = null;
  });
}

Future<void> _showDiscovery(WidgetTester t, {VoidCallback? onChanged}) async {
  t.view.physicalSize = const Size(1280, 1100);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  final theme = AppTheme.themeFor(Brightness.light);
  await t.pumpWidget(MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: SourceDiscoveryPage(onSourcesChanged: onChanged)),
  ));
  await t.pump();
}

bool _automatic(WidgetTester t) => t.widget<miuix.MiuixSwitchPreference>(
  find.byType(miuix.MiuixSwitchPreference),
).value;

void main() {
  final actions = <String, Future<DiscoverySnapshot> Function()>{
    'configure': () => SourceDiscoveryService.configure(true),
    'scan': SourceDiscoveryService.scan,
    'enable': () => SourceDiscoveryService.enable('ready'),
    'read': SourceDiscoveryService.markRead,
  };
  for (final action in actions.entries) {
    for (final statusDuringAction in [false, true]) {
      test(
        'discovery late status ${statusDuringAction ? 'during' : 'before'} ${action.key} cannot undo its result',
        () async {
          final oldStatus = Completer<dynamic>();
          final mutation = Completer<dynamic>();
          final oldData = _snapshot(running: action.key == 'scan');
          final updatedData = _snapshot(
            automatic: action.key == 'configure',
            installed: action.key == 'enable',
            unread: action.key != 'read',
            lastScan: action.key == 'scan' ? 200 : 100,
          );
          _transport((command, args) {
            if (command == 'source_discovery_status') return oldStatus.future;
            expect(command, 'source_discovery_${action.key}');
            return mutation.future;
          });
          late Future<DiscoverySnapshot> pendingStatus;
          if (!statusDuringAction) pendingStatus = SourceDiscoveryService.refresh();
          final pendingAction = action.value();
          if (statusDuringAction) pendingStatus = SourceDiscoveryService.refresh();
          mutation.complete(updatedData);
          final accepted = await pendingAction;
          oldStatus.complete(oldData);
          await pendingStatus;
          expect(SourceDiscoveryService.current.value, same(accepted));
        },
      );
    }
  }

  test('discovery refresh after a save does not reuse the pre-save read', () async {
    final oldStatus = Completer<dynamic>();
    var statusCalls = 0;
    _transport((command, args) async {
      if (command == 'source_discovery_status') {
        statusCalls++;
        if (statusCalls == 1) return oldStatus.future;
      }
      return _snapshot(automatic: true);
    });
    final oldRead = SourceDiscoveryService.refresh();
    await SourceDiscoveryService.configure(true);
    final freshRead = SourceDiscoveryService.refresh();
    oldStatus.complete(_snapshot());
    await Future.wait([oldRead, freshRead]);
    expect(statusCalls, 2);
    expect(SourceDiscoveryService.current.value!.automatic, isTrue);
  });

  testWidgets('discovery saves from reopened pages reach the backend in user order', (t) async {
    final firstSave = Completer<void>();
    var persistedAutomatic = false;
    final sent = <bool>[];
    _transport((command, args) async {
      if (command == 'source_discovery_configure') {
        final automatic = args!['automatic'] as bool;
        sent.add(automatic);
        if (sent.length == 1) await firstSave.future;
        persistedAutomatic = automatic;
      }
      return _snapshot(automatic: persistedAutomatic);
    });
    t.view.physicalSize = const Size(1280, 1100);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    final theme = AppTheme.themeFor(Brightness.light);
    await t.pumpWidget(MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const Scaffold(body: SourceDiscoveryEntry()),
    ));
    await t.pumpAndSettle();
    await t.tap(find.text('GitHub 源发现'));
    await t.pumpAndSettle();
    await t.tap(find.text('每天自动发现'));
    await t.pumpAndSettle();
    await t.tap(find.text('保存设置'));
    await t.pump();

    // Pop the actual route while its save is held, then create another page.
    await t.tap(find.byKey(const ValueKey('page-header-back')));
    await t.pumpAndSettle();
    await t.tap(find.text('GitHub 源发现'));
    await t.pumpAndSettle();
    await t.tap(find.text('保存设置'));
    await t.pump();
    final sentBeforeFirstSettled = List<bool>.of(sent);

    firstSave.complete();
    await t.pumpAndSettle();
    final displayedAutomatic = _automatic(t);
    await t.pumpWidget(const SizedBox.shrink());
    expect(sentBeforeFirstSettled, [true], reason: 'the second page must queue its write');
    expect(sent, [true, false]);
    expect(persistedAutomatic, isFalse, reason: 'backend writes must follow user intent order');
    expect(SourceDiscoveryService.current.value!.automatic, isFalse);
    expect(displayedAutomatic, isFalse);
    expect(t.takeException(), isNull);
  });

  test('discovery failed mutation does not block the next queued save', () async {
    final firstSave = Completer<dynamic>();
    final sent = <bool>[];
    _transport((command, args) async {
      expect(command, 'source_discovery_configure');
      sent.add(args!['automatic'] as bool);
      if (sent.length == 1) return await firstSave.future;
      return _snapshot();
    });
    final first = SourceDiscoveryService.configure(true);
    final failure = expectLater(first, throwsA(isA<SourinCoreException>()));
    final second = SourceDiscoveryService.configure(false);
    await Future<void>.delayed(Duration.zero);
    final sentBeforeFirstSettled = List<bool>.of(sent);
    firstSave.completeError(SourinCoreException('第一次保存失败', 'other'));
    await failure;
    final saved = await second;
    expect(sentBeforeFirstSettled, [true]);
    expect(sent, [true, false]);
    expect(saved.automatic, isFalse);
    expect(SourceDiscoveryService.current.value, same(saved));
  });

  testWidgets('discovery initial status preserves an edited automatic draft', (t) async {
    final status = Completer<dynamic>();
    _transport((command, args) => status.future);
    await _showDiscovery(t);
    await t.tap(find.text('每天自动发现'));
    await t.pump();
    status.complete(_snapshot());
    await t.pumpAndSettle();
    expect(_automatic(t), isTrue);
    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('discovery unedited automatic switch follows refreshed settings', (t) async {
    var automatic = false;
    _transport((command, args) async => _snapshot(automatic: automatic));
    await _showDiscovery(t);
    await t.pumpAndSettle();
    automatic = true;
    await SourceDiscoveryService.refresh();
    await t.pumpAndSettle();
    expect(_automatic(t), isTrue);
    await t.pumpWidget(const SizedBox.shrink());
  });

  for (final savedAutomatic in [false, true]) {
    testWidgets('discovery failed save restores confirmed automatic=$savedAutomatic', (t) async {
      final configured = <bool>[];
      _transport((command, args) async {
        if (command == 'source_discovery_configure') {
          configured.add(args!['automatic'] as bool);
          throw SourinCoreException('保存发现设置失败', 'other');
        }
        return _snapshot(automatic: savedAutomatic);
      });
      await _showDiscovery(t);
      await t.pumpAndSettle();
      await t.tap(find.text('每天自动发现'));
      await t.pumpAndSettle();
      await t.tap(find.text('保存设置'));
      await t.pumpAndSettle();
      expect(configured, [!savedAutomatic]);
      expect(_automatic(t), savedAutomatic);
      expect(find.text('保存发现设置失败'), findsOneWidget);
      expect(SourceDiscoveryService.current.value!.automatic, savedAutomatic);
      await t.pumpWidget(const SizedBox.shrink());
      expect(t.takeException(), isNull);
    });
  }

  testWidgets('discovery ignores an old poll failure after saving successfully', (t) async {
    final poll = Completer<dynamic>();
    var statusCalls = 0;
    _transport((command, args) async {
      if (command == 'source_discovery_status') {
        statusCalls++;
        if (statusCalls > 1) return poll.future;
        return _snapshot(running: true);
      }
      return _snapshot();
    });
    await _showDiscovery(t);
    await t.pump(const Duration(seconds: 5));
    await t.tap(find.text('保存设置'));
    await t.pump();
    poll.completeError(SourinCoreException('过期的状态读取失败', 'network'));
    await t.pumpAndSettle();
    expect(statusCalls, 2);
    expect(find.text('过期的状态读取失败'), findsNothing);
    await t.pumpWidget(const SizedBox.shrink());
    expect(t.takeException(), isNull);
  });

  testWidgets('discovery successful enable still notifies its owner after page disposal', (t) async {
    final enable = Completer<dynamic>();
    var changed = 0;
    var statusCalls = 0;
    _transport((command, args) async {
      if (command == 'source_discovery_enable') return enable.future;
      statusCalls++;
      return _snapshot();
    });
    await _showDiscovery(t, onChanged: () => changed++);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('启用'));
    await t.tap(find.text('启用'));
    await t.pump();
    await t.pumpWidget(const SizedBox.shrink());
    enable.complete(_snapshot(installed: true));
    await t.pump();
    await t.pump(const Duration(seconds: 6));
    expect(changed, 1);
    expect(SourceDiscoveryService.current.value!.candidates.single.installed, isTrue);
    expect(statusCalls, 1, reason: 'disposing the page cancels its polling timer');
    expect(t.takeException(), isNull);
  });

  testWidgets('discovery disposed poll failure does not require a cached snapshot', (t) async {
    final poll = Completer<dynamic>();
    var statusCalls = 0;
    _transport((command, args) async {
      statusCalls++;
      if (statusCalls == 1) return _snapshot(running: true);
      return await poll.future;
    });
    await _showDiscovery(t);
    await t.pump(const Duration(seconds: 5));
    await t.pumpWidget(const SizedBox.shrink());
    SourceDiscoveryService.current.value = null;
    poll.completeError(SourinCoreException('状态读取失败', 'network'));
    await t.pump();
    await t.pump(const Duration(seconds: 6));
    expect(statusCalls, 2);
    expect(t.takeException(), isNull);
  });

  testWidgets(
    'discovery stays pending until explicit enable and displays origin and messages',
    (t) async {
      var installed = false;
      var read = false;
      var changed = 0;
      final calls = <String>[];
      final configureCalls = <Map<String, dynamic>>[];
      Map<String, dynamic> snapshot() => {
        'automatic': false,
        'running': false,
        'candidates': [
          {
            'id': 'ready',
            'name': 'Synthetic catalog',
            'repository': 'fixture/public-config',
            'status': 'ready',
            'message': '分类与内容接口校验通过',
            'installed': installed,
            if (installed) 'providerId': 'github-ready',
          },
          {
            'id': 'failed',
            'name': 'Unsupported fixture',
            'repository': 'fixture/public-config',
            'status': 'unsupported',
            'message': '暂不支持此校验类型',
          },
        ],
        'notices': [
          {'at': 100, 'text': '发现 1 个可启用的候选', 'unread': !read},
        ],
      };
      SourceDiscoveryService.current.value = null;
      ProxyCache.reset();
      SourinCore.debugCallAsyncTransport = (command, args) async {
        calls.add(command);
        if (command == 'global_proxy_migration_choices') return <dynamic>[];
        if (command == 'list_proxy_configs') return <String, dynamic>{};
        if (command == 'has_proxy_password') return {'has': false};
        if (command == 'system_proxy_hint') return {'hint': null};
        if (command == 'source_discovery_configure') {
          configureCalls.add(Map<String, dynamic>.from(args!));
        }
        if (command == 'source_discovery_enable') {
          expect(args!['id'], 'ready');
          installed = true;
        }
        if (command == 'source_discovery_read') read = true;
        return snapshot();
      };
      addTearDown(() {
        SourinCore.debugCallAsyncTransport = null;
        SourceDiscoveryService.current.value = null;
        ProxyCache.reset();
      });
      t.view.physicalSize = const Size(1280, 1100);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final theme = AppTheme.themeFor(Brightness.light);
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          builder: (_, child) => AppThemeHost(data: theme, child: child!),
          home: Scaffold(
            body: SourceDiscoveryPage(onSourcesChanged: () => changed++),
          ),
        ),
      );
      await t.pumpAndSettle();
      expect(calls, ['source_discovery_status']);
      expect(find.byType(miuix.MiuixTextField), findsNothing);
      final proxyEntry = find.ancestor(
        of: find.text('全局代理设置'),
        matching: find.byType(miuix.MiuixButton),
      );
      expect(proxyEntry, findsOneWidget);
      expect(find.byType(miuix.MiuixSwitchPreference), findsOneWidget);
      expect(find.byType(miuix.MiuixButton), findsWidgets);
      expect(find.byType(miuix.MiuixCard), findsWidgets);
      expect(find.text('发现 1 个可启用的候选'), findsOneWidget);
      await t.tap(proxyEntry);
      await t.pumpAndSettle();
      expect(find.byType(GlobalProxySettingsPage), findsOneWidget);
      expect(
        t.widget<ProxyPanel>(find.byType(ProxyPanel)).providerId,
        SourinApi.globalProxyProvider,
      );
      Navigator.of(t.element(find.byType(GlobalProxySettingsPage))).pop();
      await t.pumpAndSettle();
      await t.tap(find.text('发现并校验'));
      await t.pumpAndSettle();
      expect(calls.where((c) => c == 'source_discovery_enable'), isEmpty);
      expect(
        calls,
        containsAllInOrder([
          'source_discovery_configure',
          'source_discovery_scan',
        ]),
      );
      expect(configureCalls, [
        <String, dynamic>{'automatic': false},
      ]);
      await t.ensureVisible(find.text('启用'));
      await t.tap(find.text('启用'));
      await t.pumpAndSettle();
      expect(changed, 1);
      expect(installed, isTrue);
      expect(find.text('已加入源页面'), findsOneWidget);
      await t.ensureVisible(find.text('全部已读'));
      await t.tap(find.text('全部已读'));
      await t.pumpAndSettle();
      expect(read, isTrue);
      expect(find.text('消息 · 0 条未读'), findsOneWidget);
      installed = false;
      final removed = snapshot();
      (removed['candidates'] as List).first['providerId'] = 'github-ready';
      SourceDiscoveryService.current.value = DiscoverySnapshot(removed);
      await t.pumpAndSettle();
      expect(
        find.text('启用'),
        findsOneWidget,
        reason: 'A removed source must offer manual reinstall',
      );
      await t.ensureVisible(find.text('启用'));
      await t.tap(find.text('启用'));
      await t.pumpAndSettle();
      expect(
        changed,
        2,
        reason: 'Removing a source keeps provenance but allows reinstall',
      );
      await t.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: GithubSourceOrigin(providerId: 'github-ready')),
        ),
      );
      expect(find.text('来自 GitHub · fixture/public-config'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
