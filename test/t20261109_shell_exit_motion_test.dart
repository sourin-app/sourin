import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/app_loading.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';

class _ShellData {
  final calls = <String, int>{};
  final unexpectedCommands = <String>[];
  Completer<dynamic>? pendingProviders;
  final providers = <Map<String, dynamic>>[
    {
      'id': 'fixture',
      'name': '测试源',
      'kind': 'tvbox',
      'enabled': true,
      'capabilities': {'vod': true},
    },
  ];

  Future<dynamic> call(String command, Map<String, dynamic>? _) async {
    calls.update(command, (count) => count + 1, ifAbsent: () => 1);
    switch (command) {
      case 'list_providers':
        return pendingProviders?.future ?? providers;
      case 'list_plugins':
        return {'plugins': <dynamic>[], 'failed': <dynamic>[]};
      case 'remote_status_cmd':
        return {'running': false};
      case 'remote_auto_start':
        return false;
      case 'list_tvbox_sources':
        return {'sources': <dynamic>[]};
      case 'get_home':
      case 'list_favorites':
      case 'list_all_progress':
      case 'continue_watching':
      case 'list_skip_markers':
      case 'restore_failures':
      case 'global_proxy_migration_choices':
        return <dynamic>[];
      case 'continue_watching_count':
      case 'repair_library_covers':
        return 0;
      case 'list_plugin_sources':
      case 'list_proxy_configs':
      case 'source_discovery_status':
      case 'source_catalog_get':
      case 'tvbox_update_schedule_get':
        return <String, dynamic>{};
      default:
        unexpectedCommands.add(command);
        throw StateError('Unexpected shell fixture command: $command');
    }
  }
}

Finder _page(Type type) => find.byType(type, skipOffstage: false);

Rect _paintedBounds(WidgetTester tester, Type type) {
  final box = tester.renderObject<RenderBox>(_page(type));
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

// Multiplying every ancestor fade catches a duplicated exit fade. Reading only
// the nearest FadeTransition would miss the resulting squared opacity.
double _paintedOpacity(WidgetTester tester, Type type) => tester
    .widgetList<FadeTransition>(
      find.ancestor(
        of: _page(type),
        matching: find.byType(FadeTransition, skipOffstage: false),
      ),
    )
    .fold(1.0, (value, fade) => value * fade.opacity.value);

bool _offstage(WidgetTester tester, AppTab tab) => tester
    .widget<Offstage>(find.byKey(ValueKey<AppTab>(tab), skipOffstage: false))
    .offstage;

Future<void> _mount(
  WidgetTester tester,
  PageTransitionStyle style, {
  GlobalKey? rasterKey,
}) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  PageTransitionStyleStore.resetForTest(style);
  final theme = AppTheme.themeFor(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: rasterKey == null
          ? ShellPage(key: debugShellKey)
          : RepaintBoundary(
              key: rasterKey,
              child: ShellPage(key: debugShellKey),
            ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  expect(find.byType(HomePage), findsOneWidget);
  expect(tester.takeException(), isNull);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
  });
}

void _expectExitGeometry(
  PageTransitionStyle style,
  Rect before,
  Rect current,
  Rect previous,
) {
  switch (style) {
    case PageTransitionStyle.slideRight:
      expect(current.left, lessThan(before.left - 0.5));
      expect(current.left, lessThan(previous.left));
      expect(current.top, closeTo(before.top, 0.01));
      expect(current.size, before.size);
    case PageTransitionStyle.slideUp:
    case PageTransitionStyle.fadeUp:
      expect(current.top, greaterThan(before.top + 0.5));
      expect(current.top, greaterThan(previous.top));
      expect(current.left, closeTo(before.left, 0.01));
      expect(current.size, before.size);
    case PageTransitionStyle.zoom:
      expect(current.width, lessThan(before.width - 0.5));
      expect(current.width, lessThan(previous.width));
      expect(current.height, lessThan(previous.height));
      expect(current.center.dx, closeTo(before.center.dx, 0.01));
      expect(current.center.dy, closeTo(before.center.dy, 0.01));
    case PageTransitionStyle.fade:
      expect(current, before);
    case PageTransitionStyle.none:
      fail('An immediate switch has no outgoing painted page.');
  }
}

Future<Uint8List> _pixels(WidgetTester tester, GlobalKey key) async {
  return (await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      return Uint8List.fromList(data!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  }))!;
}

int _changedChannels(Uint8List a, Uint8List b) {
  expect(a.length, b.length);
  var changed = 0;
  for (var i = 0; i < a.length; i++) {
    if ((a[i] - b[i]).abs() > 3) changed++;
  }
  return changed;
}

int _changedRegion(
  Uint8List a,
  Uint8List b,
  int width,
  int left,
  int top,
  int right,
  int bottom,
) {
  var changed = 0;
  for (var y = top; y < bottom; y++) {
    for (var x = left; x < right; x++) {
      final base = (y * width + x) * 4;
      for (var channel = 0; channel < 4; channel++) {
        if ((a[base + channel] - b[base + channel]).abs() > 3) changed++;
      }
    }
  }
  return changed;
}

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() {
    UiPrefs.debugResetForTest();
    PageTransitionStyleStore.syncFromPrefs();
  });

  for (final style in PageTransitionStyle.values.where(
    (style) => style != PageTransitionStyle.none,
  )) {
    testWidgets('real shell paints the selected ${style.name} exit once', (
      tester,
    ) async {
      await _mount(tester, style);
      final homeState = tester.state(_page(HomePage));
      final before = _paintedBounds(tester, HomePage);
      debugShellKey.currentState!.debugSwitchTo(AppTab.search);
      await tester.pump();
      expect(_offstage(tester, AppTab.home), isFalse);

      var previous = before;
      var previousOpacity = 1.0;
      for (final elapsed in [
        const Duration(milliseconds: 40),
        const Duration(milliseconds: 90),
      ]) {
        await tester.pump(elapsed);
        final current = _paintedBounds(tester, HomePage);
        final opacity = _paintedOpacity(tester, HomePage);
        _expectExitGeometry(style, before, current, previous);
        expect(opacity, inExclusiveRange(0, previousOpacity));
        expect(
          opacity + _paintedOpacity(tester, SearchPage),
          closeTo(1, 0.01),
          reason: 'Exit and enter opacity must stay complementary.',
        );
        previous = current;
        previousOpacity = opacity;
      }

      await tester.pump(Motion.base);
      await tester.pump();
      expect(_offstage(tester, AppTab.home), isTrue);
      expect(find.byType(HomePage), findsNothing);
      expect(tester.state(_page(HomePage)), same(homeState));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('backward tab navigation moves the outgoing page right', (
    tester,
  ) async {
    await _mount(tester, PageTransitionStyle.slideRight);
    debugShellKey.currentState!.debugSwitchTo(AppTab.search);
    await tester.pump();
    await tester.pump(Motion.base);
    await tester.pump();
    final before = _paintedBounds(tester, SearchPage);

    debugShellKey.currentState!.debugSwitchTo(AppTab.home);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final outgoing = _paintedBounds(tester, SearchPage);
    expect(outgoing.left, greaterThan(before.left + 0.5));
    expect(outgoing.top, closeTo(before.top, 0.01));
    expect(outgoing.size, before.size);
    expect(_paintedOpacity(tester, SearchPage), inExclusiveRange(0, 1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('rapid tab changes retire old pages and retain settings scroll', (
    tester,
  ) async {
    final data = _ShellData();
    Device.overrideKind(DeviceKind.desktop);
    SourinCore.debugCallAsyncTransport = data.call;
    SearchPageState.debugAggChannelNamesFetcher = () async => {};
    SourceDiscoveryService.current.value = null;
    ProxyCache.invalidate();
    addTearDown(() {
      Device.overrideKind(null);
      SourinCore.debugCallAsyncTransport = null;
      SearchPageState.debugAggChannelNamesFetcher = null;
      SourceDiscoveryService.current.value = null;
      ProxyCache.invalidate();
    });
    await _mount(tester, PageTransitionStyle.slideRight);
    final shell = debugShellKey.currentState!;
    final providerCalls = data.calls['list_providers']!;
    final settingsProviders = Completer<dynamic>();
    data.pendingProviders = settingsProviders;
    shell.debugSwitchTo(AppTab.settings);
    await tester.pump();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(data.calls['list_providers'], providerCalls + 1);
    final loading = find.descendant(
      of: _page(SettingsPage),
      matching: find.byType(AppLoading),
    );
    expect(loading, findsOneWidget);
    // Complete the real loadAll request through the FFI test transport. Pumping
    // virtual time cannot complete an unmocked native callback.
    settingsProviders.complete(data.providers);
    data.pendingProviders = null;
    await tester.pumpAndSettle();
    expect(loading, findsNothing);
    for (final command in [
      'list_plugins',
      'remote_status_cmd',
      'remote_auto_start',
      'list_skip_markers',
      'list_plugin_sources',
      'list_tvbox_sources',
    ]) {
      expect(data.calls[command], 1, reason: command);
    }
    final settingsState = tester.state(_page(SettingsPage));
    final settingsList = find.descendant(
      of: _page(SettingsPage),
      matching: find.byType(ListView),
    );
    expect(settingsList, findsOneWidget);
    final scrollFinder = find.descendant(
      of: settingsList,
      matching: find.byType(Scrollable, skipOffstage: false),
    );
    expect(scrollFinder, findsOneWidget);
    final scroll = tester.state<ScrollableState>(scrollFinder);
    expect(scroll.position.maxScrollExtent, greaterThan(240));
    scroll.position.jumpTo(240);
    await tester.pump();

    shell.debugSwitchTo(AppTab.search);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    shell.debugSwitchTo(AppTab.home);
    await tester.pump();
    expect(_offstage(tester, AppTab.settings), isTrue);
    expect(_offstage(tester, AppTab.search), isFalse);
    await tester.pump(Motion.base);
    await tester.pump();
    expect(_offstage(tester, AppTab.search), isTrue);
    expect(_offstage(tester, AppTab.home), isFalse);

    shell.debugSwitchTo(AppTab.settings);
    await tester.pump();
    await tester.pump(Motion.base);
    await tester.pump();
    expect(tester.state(_page(SettingsPage)), same(settingsState));
    expect(tester.state<ScrollableState>(scrollFinder), same(scroll));
    expect(scroll.position.pixels, closeTo(240, 0.01));
    expect(data.unexpectedCommands, isEmpty);
    expect(tester.takeException(), isNull);
  });
  for (final style in [
    PageTransitionStyle.fade,
    PageTransitionStyle.slideRight,
  ]) {
    testWidgets(
      'real shell ${style.name} pixels animate and recover after rapid reversal',
      (tester) async {
        final data = _ShellData();
        Device.overrideKind(DeviceKind.desktop);
        SourinCore.debugCallAsyncTransport = data.call;
        SearchPageState.debugAggChannelNamesFetcher = () async => {};
        SourceDiscoveryService.current.value = null;
        ProxyCache.invalidate();
        addTearDown(() {
          Device.overrideKind(null);
          SourinCore.debugCallAsyncTransport = null;
          SearchPageState.debugAggChannelNamesFetcher = null;
          SourceDiscoveryService.current.value = null;
          ProxyCache.invalidate();
        });
        final rasterKey = GlobalKey();
        await _mount(tester, style, rasterKey: rasterKey);
        await tester.pumpAndSettle();
        final homeState = tester.state(_page(HomePage));
        final homePixels = await _pixels(tester, rasterKey);
        final size = tester.getSize(find.byKey(rasterKey));
        final contentWidth = size.width.toInt();
        final contentBottom = size.height.toInt() - 120;
        final shell = debugShellKey.currentState!;
        shell.debugSwitchTo(AppTab.settings);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 35));
        final early = await _pixels(tester, rasterKey);
        await tester.pump(const Duration(milliseconds: 100));
        final late = await _pixels(tester, rasterKey);
        expect(
          _changedRegion(
            early,
            late,
            contentWidth,
            0,
            50,
            contentWidth,
            contentBottom,
          ),
          greaterThan(500),
          reason:
              'The cached content must not freeze the outer fade or movement',
        );
        await tester.pumpAndSettle();
        final settingsPixels = await _pixels(tester, rasterKey);
        expect(_changedChannels(homePixels, settingsPixels), greaterThan(5000));
        shell.debugSwitchTo(AppTab.home);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 40));
        shell.debugSwitchTo(AppTab.search);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 35));
        shell.debugSwitchTo(AppTab.home);
        await tester.pumpAndSettle();
        expect(tester.state(_page(HomePage)), same(homeState));
        expect(_offstage(tester, AppTab.settings), isTrue);
        expect(_offstage(tester, AppTab.search), isTrue);
        final restored = await _pixels(tester, rasterKey);
        expect(
          _changedRegion(
            homePixels,
            restored,
            contentWidth,
            0,
            50,
            contentWidth,
            contentBottom,
          ),
          0,
          reason: 'No pixels from an interrupted page may remain on Home',
        );
        for (final snapshot in tester.widgetList<SnapshotWidget>(
          find.byType(SnapshotWidget, skipOffstage: false),
        )) {
          expect(
            snapshot.controller.allowSnapshotting,
            isFalse,
            reason: 'Settled or hidden pages must release their transient snapshots',
          );
        }
        expect(data.unexpectedCommands, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'live page keeps its native content outside transient snapshots',
    (tester) async {
      final data = _ShellData();
      Device.overrideKind(DeviceKind.desktop);
      SourinCore.debugCallAsyncTransport = data.call;
      LivePageState.debugLiveGroupsFetcher = () async => [];
      addTearDown(() {
        Device.overrideKind(null);
        SourinCore.debugCallAsyncTransport = null;
        LivePageState.debugLiveGroupsFetcher = null;
      });
      await _mount(tester, PageTransitionStyle.slideRight);
      final shell = debugShellKey.currentState!;
      shell.debugSwitchTo(AppTab.live);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final liveSnapshot = find.descendant(
        of: find.byKey(const ValueKey(AppTab.live), skipOffstage: false),
        matching: find.byType(SnapshotWidget, skipOffstage: false),
      );
      expect(liveSnapshot, findsOneWidget);
      expect(
        tester
            .widget<SnapshotWidget>(liveSnapshot)
            .controller
            .allowSnapshotting,
        isFalse,
      );
      shell.debugSwitchTo(AppTab.home);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      expect(
        tester
            .widget<SnapshotWidget>(liveSnapshot)
            .controller
            .allowSnapshotting,
        isFalse,
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
}
