import 'package:flutter/rendering.dart' show MatrixUtils, RenderBox;
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
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/page_transition.dart';

// Fixed transport only; production ShellPage owns navigation, animation clocks,
// lifecycle, Offstage and content. No user data or native player is required.
class _ShellData {
  final unexpected = <String>[];

  Future<dynamic> call(String command, Map<String, dynamic>? _) async {
    switch (command) {
      case 'list_providers':
        return <Map<String, dynamic>>[
          {
            'id': 'motion-fixture',
            'name': '测试源',
            'kind': 'tvbox',
            'enabled': true,
            'capabilities': {'vod': true},
          },
        ];
      case 'list_plugins':
        return {'plugins': <dynamic>[], 'failed': <dynamic>[]};
      case 'remote_status_cmd':
        return {'running': false};
      case 'remote_auto_start':
        return false;
      case 'list_tvbox_sources':
        return {'sources': <dynamic>[]};
      case 'get_home':
      case 'get_provider_home':
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
        unexpected.add(command);
        throw StateError('Unexpected shell fixture command: $command');
    }
  }
}

Finder _page(Type type) => find.byType(type, skipOffstage: false);

bool _offstage(WidgetTester tester, AppTab tab) => tester
    .widget<Offstage>(find.byKey(ValueKey<AppTab>(tab), skipOffstage: false))
    .offstage;

Rect _paintedBounds(WidgetTester tester, Type type) {
  final box = tester.renderObject<RenderBox>(_page(type));
  return MatrixUtils.transformRect(
    box.getTransformTo(null),
    Offset.zero & box.size,
  );
}

double _paintedOpacity(WidgetTester tester, Type type) => tester
    .widgetList<FadeTransition>(
      find.ancestor(
        of: _page(type),
        matching: find.byType(FadeTransition, skipOffstage: false),
      ),
    )
    .fold(1.0, (value, fade) => value * fade.opacity.value);

Future<_ShellData> _mount(
  WidgetTester tester,
  ValueNotifier<bool> reduced,
) async {
  final data = _ShellData();
  Device.overrideKind(DeviceKind.desktop);
  SourinCore.debugCallAsyncTransport = data.call;
  SearchPageState.debugAggChannelNamesFetcher = () async => {};
  SourceDiscoveryService.current.value = null;
  ProxyCache.invalidate();
  PageTransitionStyleStore.resetForTest(PageTransitionStyle.slideRight);
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  final theme = AppTheme.themeFor(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      themeAnimationDuration: Duration.zero,
      builder: (context, child) => ValueListenableBuilder<bool>(
        valueListenable: reduced,
        builder: (context, disable, _) => MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: disable),
          child: AppThemeHost(data: theme, child: child!),
        ),
      ),
      home: ShellPage(key: debugShellKey),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(seconds: 2));
  expect(find.byType(HomePage), findsOneWidget);
  expect(tester.takeException(), isNull);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Disposal must cancel any outgoing timer/listener still owned by Shell.
    PageTransitionStyleStore.resetForTest(PageTransitionStyle.fade);
    await tester.pump(const Duration(seconds: 5));
    expect(tester.takeException(), isNull);
    expect(data.unexpected, isEmpty);
    await tester.binding.setSurfaceSize(null);
    Device.overrideKind(null);
    SourinCore.debugCallAsyncTransport = null;
    SearchPageState.debugAggChannelNamesFetcher = null;
    SourceDiscoveryService.current.value = null;
    ProxyCache.invalidate();
    reduced.dispose();
  });
  return data;
}

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  tearDown(() {
    UiPrefs.debugResetForTest();
    PageTransitionStyleStore.syncFromPrefs();
  });

  for (final system in [false, true]) {
    testWidgets('running shell transition retires immediately when '
        '${system ? 'system reduction' : 'none style'} is selected', (
      tester,
    ) async {
      final reduced = ValueNotifier<bool>(false);
      await _mount(tester, reduced);
      final homeState = tester.state(_page(HomePage));
      debugShellKey.currentState!.debugSwitchTo(AppTab.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final searchState = tester.state(_page(SearchPage));
      expect(_offstage(tester, AppTab.home), isFalse);
      expect(_paintedOpacity(tester, SearchPage), inExclusiveRange(0, 1));

      if (system) {
        reduced.value = true;
      } else {
        PageTransitionStyleStore.set(PageTransitionStyle.none);
      }
      // Zero elapsed time: waiting for Motion.base would hide the defect.
      await tester.pump();
      await tester.pump();
      expect(
        _offstage(tester, AppTab.home),
        isTrue,
        reason: 'Cancelling motion must retire the composed outgoing page now.',
      );
      expect(find.byType(HomePage), findsNothing);
      expect(find.byType(SearchPage), findsOneWidget);
      expect(_paintedOpacity(tester, SearchPage), 1);
      expect(tester.state(_page(HomePage)), same(homeState));
      expect(tester.state(_page(SearchPage)), same(searchState));
      final settledBounds = _paintedBounds(tester, SearchPage);
      for (final snapshot in tester.widgetList<SnapshotWidget>(
        find.byType(SnapshotWidget, skipOffstage: false),
      )) {
        expect(snapshot.controller.allowSnapshotting, isFalse);
      }

      // Re-enable before the former exit interval expires: an old exit
      // controller or timer must not revive content or reset page state.
      if (system) {
        reduced.value = false;
      } else {
        PageTransitionStyleStore.set(PageTransitionStyle.slideRight);
      }
      await tester.pump();
      await tester.pump();
      expect(_offstage(tester, AppTab.home), isTrue);
      expect(_paintedOpacity(tester, SearchPage), 1);
      expect(_paintedBounds(tester, SearchPage), settledBounds);
      await tester.pump(Motion.base);
      expect(_offstage(tester, AppTab.home), isTrue);
      expect(_paintedBounds(tester, SearchPage), settledBounds);
      expect(tester.state(_page(SearchPage)), same(searchState));
      expect(tester.takeException(), isNull);
        // Drain the production preference debounce after zero-time assertions.
        await tester.pump(const Duration(milliseconds: 400));
    });
  }

  testWidgets(
    'ordinary running shell animation retains the outgoing interval',
    (tester) async {
      final reduced = ValueNotifier<bool>(false);
      await _mount(tester, reduced);
      final homeState = tester.state(_page(HomePage));
      debugShellKey.currentState!.debugSwitchTo(AppTab.search);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final early = _paintedBounds(tester, SearchPage);
      final opacity = _paintedOpacity(tester, SearchPage);
      expect(_offstage(tester, AppTab.home), isFalse);
      expect(opacity, inExclusiveRange(0, 1));
      await tester.pump(const Duration(milliseconds: 45));
      expect(_offstage(tester, AppTab.home), isFalse);
      expect(_paintedOpacity(tester, SearchPage), greaterThan(opacity));
      expect(_paintedBounds(tester, SearchPage).left, lessThan(early.left));
      await tester.pump(Motion.base);
      await tester.pump();
      expect(_offstage(tester, AppTab.home), isTrue);
      expect(tester.state(_page(HomePage)), same(homeState));
      expect(tester.takeException(), isNull);
    },
  );
}
