import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_discovery_page.dart';

void main() {
  testWidgets(
    'discovery stays pending until explicit enable and displays origin and messages',
    (t) async {
      var installed = false;
      var read = false;
      var changed = 0;
      final calls = <String>[];
      Map<String, dynamic> snapshot() => {
        'proxyUrl': 'http://127.0.0.1:7890',
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
      SourinCore.debugCallAsyncTransport = (command, args) async {
        calls.add(command);
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
      expect(find.byType(miuix.MiuixTextField), findsOneWidget);
      expect(find.byType(miuix.MiuixSwitchPreference), findsOneWidget);
      expect(find.byType(miuix.MiuixButton), findsWidgets);
      expect(find.byType(miuix.MiuixCard), findsWidgets);
      expect(find.text('发现 1 个可启用的候选'), findsOneWidget);
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
        MaterialApp(
          home: Scaffold(body: GithubSourceOrigin(providerId: 'github-ready')),
        ),
      );
      expect(find.text('来自 GitHub · fixture/public-config'), findsOneWidget);
      expect(t.takeException(), isNull);
    },
  );
}
