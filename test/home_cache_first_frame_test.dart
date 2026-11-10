import 'dart:async';
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide Page;
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/disk_cache.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/webhome/webhome_store.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

const _cachedTitle = '甲源缓存海报';
const _otherTitle = '乙源缓存海报';
const _freshTitle = '甲源刷新海报';

ProviderGroup _group(String provider, String section, String title) =>
    ProviderGroup(
      provider: provider,
      providerName: provider == 'a' ? '源甲' : '源乙',
      sections: [
        Section(
          id: section,
          title: title,
          source: SectionSource(type: 'category', categoryId: section),
        ),
      ],
    );

void _seedCache(String provider, String posterTitle) {
  homeListCache.put(
    provider,
    HomeSnapshot(
      fingerprint: '$provider:old',
      groups: [_group(provider, 'old', '缓存分区$provider')],
      items: {
        '$provider::old': [
          MediaItem(id: '$provider:cached', title: posterTitle),
        ],
      },
      // Preloaded data stays usable while a fresh metadata request is pending.
      at: DateTime.now().subtract(const Duration(days: 30)),
    ),
  );
}

class _HomeFixture {
  _HomeFixture({
    this.aEnabled = true,
    this.bEnabled = true,
    this.allowOtherRefresh = false,
  });

  final bool aEnabled;
  final bool bEnabled;
  final bool allowOtherRefresh;
  final home = Completer<List<ProviderGroup>>();
  final commands = <String>[];
  final unexpected = <String>[];
  final listRequests = <String>[];
  int homeRequests = 0;

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    commands.add(command);
    switch (command) {
      case 'list_providers':
        return [
          for (final entry in {'a': aEnabled, 'b': bEnabled}.entries)
            {
              'id': entry.key,
              'name': entry.key == 'a' ? '源甲' : '源乙',
              'kind': 'tvbox',
              'enabled': entry.value,
              'capabilities': {'vod': true},
            },
        ];
      case 'list_all_progress':
        return <dynamic>[];
      case 'repair_library_covers':
        return 0;
      case 'source_discovery_status':
        return {
          'proxyUrl': '',
          'automatic': false,
          'running': false,
          'lastError': '',
          'lastScan': 0,
          'candidates': <dynamic>[],
          'notices': <dynamic>[],
        };
      default:
        unexpected.add(command);
        throw StateError('Unexpected native command: $command');
    }
  }
}

Future<void> _pumpHomeFrames(WidgetTester tester) async {
  // The metadata request deliberately stays pending. A global settle could
  // wait forever on the skeleton; advance enough frames for normal card fade.
  for (var frame = 0; frame < 10; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _mountHome(WidgetTester tester, _HomeFixture fixture) async {
  UiPrefs.debugResetForTest({UiPrefs.homeSourceKey: 'a'});
  DiskCache.debugResetForTest();
  homeListCache.clear();
  homeListCache.enabled = true;
  Device.overrideKind(DeviceKind.desktop);
  SourceDiscoveryService.current.value = null;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1000);
  late Directory scratch;
  await tester.runAsync(() async {
    scratch = await Directory.systemTemp.createTemp('home-cache-first-frame-');
    WebHomeController.debugSetDataDir(scratch.path);
    await WebHomeController.instance.reload();
  });
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    if (!fixture.home.isCompleted) fixture.home.complete([]);
    await tester.pump();
    SourinCore.debugCallAsyncTransport = null;
    SourinApi.debugHomeFetcher = null;
    SourinApi.debugSetListFetchers();
    debugShelfLoadOverride = null;
    debugShelfPreloadOverride = null;
    homeListCache.clear();
    DiskCache.debugResetForTest();
    UiPrefs.debugResetForTest();
    Device.overrideKind(null);
    SourceDiscoveryService.current.value = null;
    WebHomeController.debugSetDataDir(null);
    tester.view.reset();
    await tester.runAsync(() => scratch.delete(recursive: true));
  });

  debugShelfLoadOverride = () async =>
      (<Favorite>[], <Favorite>[], <Progress>[]);
  debugShelfPreloadOverride = () async => null;
  SourinCore.debugCallAsyncTransport = fixture.call;
  SourinApi.debugHomeFetcher = () {
    fixture.homeRequests++;
    return fixture.home.future;
  };
  SourinApi.debugSetListFetchers(
    getList: (provider, category, {int page = 1}) async {
      final request = '$provider::$category';
      fixture.listRequests.add(request);
      if (fixture.allowOtherRefresh && request == 'b::old') {
        return const Page<MediaItem>(
          items: [MediaItem(id: 'b:cached', title: _otherTitle)],
        );
      }
      if (request != 'a::fresh') {
        throw StateError('Unexpected list request: $request');
      }
      return const Page<MediaItem>(
        items: [MediaItem(id: 'a:fresh', title: _freshTitle)],
      );
    },
  );
  _seedCache('a', _cachedTitle);
  _seedCache('b', _otherTitle);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const Scaffold(body: HomePage()),
    ),
  );
  await _pumpHomeFrames(tester);
}

Finder _poster(String title) => find.descendant(
  of: find.byType(HomePage),
  matching: find.byWidgetPredicate(
    (widget) => widget is PosterCard && widget.title == title,
  ),
);

void _expectVisiblePoster(WidgetTester tester, String title) {
  final poster = _poster(title);
  expect(poster, findsOneWidget);
  expect(poster.hitTestable(), findsOneWidget);
  final rect = tester.getRect(poster);
  expect(rect.width, greaterThan(0));
  expect(rect.height, greaterThan(0));
  expect(rect.overlaps(const Rect.fromLTWH(0, 0, 1280, 1000)), isTrue);
  var opacity = 1.0;
  RenderObject? render = tester.renderObject(poster);
  while (render != null) {
    if (render is RenderOpacity) opacity *= render.opacity;
    if (render is RenderAnimatedOpacity) opacity *= render.opacity.value;
    if (render is RenderSliverOpacity) opacity *= render.opacity;
    if (render is RenderSliverAnimatedOpacity) opacity *= render.opacity.value;
    render = render.parent;
  }
  expect(opacity, closeTo(1, 0.001), reason: '缓存海报必须已结束淡入，不能只挂载透明元素');
}

void _expectNoNativeFailures(WidgetTester tester, _HomeFixture fixture) {
  expect(fixture.unexpected, isEmpty);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('当前启用源的缓存海报在 getHome 返回之前已真实可见', (tester) async {
    final fixture = _HomeFixture();
    await _mountHome(tester, fixture);

    expect(fixture.homeRequests, 1);
    expect(fixture.home.isCompleted, isFalse);
    expect(fixture.listRequests, isEmpty);
    _expectVisiblePoster(tester, _cachedTitle);
    expect(_poster(_otherTitle), findsNothing);
    expect(find.text('缓存分区a'), findsOneWidget);
    _expectNoNativeFailures(tester, fixture);
  });

  testWidgets('已禁用的记忆源不得显示缓存，等待期间只显示启用回退源', (tester) async {
    final fixture = _HomeFixture(aEnabled: false);
    await _mountHome(tester, fixture);

    expect(fixture.homeRequests, 1);
    expect(fixture.home.isCompleted, isFalse);
    expect(fixture.listRequests, isEmpty);
    expect(_poster(_cachedTitle), findsNothing);
    expect(find.text('缓存分区a'), findsNothing);
    _expectVisiblePoster(tester, _otherTitle);
    expect(UiPrefs.homeSource, 'b');
    _expectNoNativeFailures(tester, fixture);
  });

  testWidgets('等待元数据期间切源后，迟到结果不得切回原源或覆盖当前缓存', (tester) async {
    final fixture = _HomeFixture(allowOtherRefresh: true);
    await _mountHome(tester, fixture);
    expect(fixture.home.isCompleted, isFalse);
    _expectVisiblePoster(tester, _cachedTitle);

    final otherSource = find.text('源乙');
    expect(otherSource.hitTestable(), findsOneWidget);
    await tester.tap(otherSource);
    await _pumpHomeFrames(tester);

    expect(fixture.home.isCompleted, isFalse);
    expect(UiPrefs.homeSource, 'b');
    _expectVisiblePoster(tester, _otherTitle);
    expect(_poster(_cachedTitle), findsNothing);
    expect(find.text('缓存分区b'), findsOneWidget);

    fixture.home.complete([
      _group('a', 'fresh', '刷新分区'),
      _group('b', 'old', '缓存分区b'),
    ]);
    await _pumpHomeFrames(tester);

    // Each selected source requests its own catalog; A's response remains obsolete.
    expect(fixture.homeRequests, 2);
    expect(UiPrefs.homeSource, 'b');
    final selectedSource = tester.widget<ui.ChoiceChip>(
      find.ancestor(of: otherSource, matching: find.byType(ui.ChoiceChip)),
    );
    expect(selectedSource.selected, isTrue);
    _expectVisiblePoster(tester, _otherTitle);
    expect(_poster(_cachedTitle), findsNothing);
    expect(_poster(_freshTitle), findsNothing);
    expect(find.text('缓存分区b'), findsOneWidget);
    expect(find.text('刷新分区'), findsNothing);
    expect(fixture.listRequests, isNotEmpty);
    expect(fixture.listRequests, everyElement('b::old'));
    _expectNoNativeFailures(tester, fixture);
  });

  testWidgets('全部源关闭时不复活任何缓存也不请求首页元数据', (tester) async {
    final fixture = _HomeFixture(aEnabled: false, bEnabled: false);
    await _mountHome(tester, fixture);

    expect(fixture.commands, contains('list_providers'));
    expect(fixture.homeRequests, 0);
    expect(fixture.listRequests, isEmpty);
    expect(find.byType(PosterCard), findsNothing);
    expect(find.text('缓存分区a'), findsNothing);
    expect(find.text('缓存分区b'), findsNothing);
    expect(UiPrefs.homeSource, isEmpty);
    _expectNoNativeFailures(tester, fixture);
  });

  testWidgets('getHome 失败后仍保留此前可见的缓存海报和分区', (tester) async {
    final fixture = _HomeFixture();
    await _mountHome(tester, fixture);
    expect(fixture.home.isCompleted, isFalse);
    _expectVisiblePoster(tester, _cachedTitle);

    fixture.home.completeError(StateError('metadata unavailable'));
    await _pumpHomeFrames(tester);

    expect(fixture.homeRequests, 1);
    expect(fixture.listRequests, isEmpty);
    _expectVisiblePoster(tester, _cachedTitle);
    expect(find.text('缓存分区a'), findsOneWidget);
    expect(_poster(_otherTitle), findsNothing);
    _expectNoNativeFailures(tester, fixture);
  });

  testWidgets('getHome 返回新骨架后以实际新列表替换旧缓存分区和海报', (tester) async {
    final fixture = _HomeFixture();
    await _mountHome(tester, fixture);
    expect(fixture.home.isCompleted, isFalse);
    _expectVisiblePoster(tester, _cachedTitle);

    fixture.home.complete([_group('a', 'fresh', '刷新分区')]);
    await _pumpHomeFrames(tester);

    expect(fixture.homeRequests, 1);
    expect(fixture.listRequests, ['a::fresh']);
    _expectVisiblePoster(tester, _freshTitle);
    expect(find.text('刷新分区'), findsOneWidget);
    expect(find.text('缓存分区a'), findsNothing);
    expect(_poster(_cachedTitle), findsNothing);
    expect(_poster(_otherTitle), findsNothing);
    _expectNoNativeFailures(tester, fixture);
  });
}
