@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/detail_raw_meta.dart';

// Actual MediaPage -> DetailPage layout and original episode callbacks. The
// source receiver is synthetic; native media opening, accounts and network are
// disabled. These dimensions reproduce the retained 860x904 task window,
// including its normal 40dp title bar and 475.2dp stacked detail allocation.
const _provider = 'csp-stacked-layout-fixture';
const _item = 'work';
const _title = '疯狂动物城2';
const _description =
    '一个神秘爬行动物的到来，把温馨的动物城搅动得天翻地覆。'
    '面对全新的城市危机，警官兔朱迪与狐尼克将继续携手为保卫动物城而奔波。'
    '在追捕行动中，这对老搭档不仅要揭开新角色的神秘面纱，'
    '还要前往被迷雾笼罩的新领域，探索未知的地下黑市。美国 2025';
const _sources = <Map<String, dynamic>>[
  {'code': 'PAN1', 'title': 'PAN1', 'count': 3},
  {'code': 'NBY', 'title': 'NBY', 'count': 1},
  {'code': 'qsvip', 'title': 'qsvip', 'count': 2},
  {'code': 'BBA', 'title': 'BBA', 'count': 2},
];
const _episodeRows = <Map<String, dynamic>>[
  {'id': 'PAN1:1', 'title': 'PAN1 正片', 'flag': 'PAN1', 'index': 0},
  {'id': 'PAN1:2', 'title': 'PAN1 中文字幕', 'flag': 'PAN1', 'index': 1},
  {'id': 'PAN1:3', 'title': 'PAN1 英文字幕', 'flag': 'PAN1', 'index': 2},
  {'id': 'NBY:1', 'title': 'NBY 1080P', 'flag': 'NBY', 'index': 0},
  {'id': 'qsvip:1', 'title': 'qsvip HD英语', 'flag': 'qsvip', 'index': 0},
  {'id': 'qsvip:2', 'title': 'qsvip HD中字', 'flag': 'qsvip', 'index': 1},
  {'id': 'BBA:1', 'title': 'BBA HD中字', 'flag': 'BBA', 'index': 0},
  {'id': 'BBA:2', 'title': 'BBA HD英语', 'flag': 'BBA', 'index': 1},
];

Future<void> _advance(WidgetTester tester) async {
  for (var i = 0; i < 30; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(seconds: 3));
  }
}

Finder _insideDetail(Finder target) =>
    find.descendant(of: find.byType(DetailPage), matching: target);

void main() {
  late Directory scratch;
  final forwarded = <PlayRequestData>[];
  final requests = <Map<String, dynamic>>[];
  final previousTransport = SourinCore.debugCallAsyncTransport;
  Completer<Object?>? delayedEpisodes;
  String? delayedSource;

  setUpAll(() {
    final native = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(
      native.existsSync(),
      isTrue,
      reason: 'Native widget fixture is required.',
    );
    MediaKit.ensureInitialized(libmpv: native.absolute.path);
  });

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('sourin-stacked-detail-');
    CachePage.debugScanRootOverride = scratch.path;
    UiPrefs.debugResetForTest({
      'dsh.danmaku.enabled': '0',
      'dsh.playprefs.lastVolume': '0',
    });
    NetworkStatus.debugResetForTest();
    NetworkStatus.debugProbe = () async => true;
    RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    debugSetOnDetailPlayForward(forwarded.add);
    forwarded.clear();
    requests.clear();
    delayedEpisodes = null;
    delayedSource = null;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), (
          call,
        ) async {
          if (call.method == 'isFullScreen') return false;
          return null;
        });
    SourinCore.debugCallAsyncTransport = (command, args) async {
      switch (command) {
        case 'get_detail':
          return {
            'id': '$_provider:$_item',
            'title': _title,
            'description': _description,
            'episodes': _episodeRows,
            'sources': _sources,
          };
        case 'get_sources':
          return _sources;
        case 'get_episodes':
          final source = args?['sourceCode'] ?? args?['source_code'] ?? 'PAN1';
          if (source == delayedSource && delayedEpisodes != null) {
            return await delayedEpisodes!.future;
          }
          return _episodeRows
              .where((episode) => episode['flag'] == source)
              .toList();
        case 'get_progress':
          return null;
        case 'list_favorites':
        case 'list_all_progress':
          return <dynamic>[];
        case 'list_providers':
          return [
            {
              'id': _provider,
              'name': 'Owned public YunDuo',
              'kind': 'tvbox',
              'enabled': true,
            },
          ];
        case 'save_progress':
        case 'pan_cleanup_temp':
          return <String, dynamic>{};
        case 'resolve_stream':
          requests.add(Map<String, dynamic>.from(args!));
          return [
            {'url': 'https://fixture.invalid/never-opened.mp4', 'kind': 'mp4'},
          ];
        default:
          throw SourinCoreException(
            'No data in isolated layout fixture',
            'other',
          );
      }
    };
  });

  tearDown(() {
    RemoteBridge.instance.stop();
    debugSetOnDetailPlayForward(null);
    debugPlayerSkipOpenForProbe = false;
    SourinApi.debugResolveStreamFetcher = null;
    SourinApi.debugSkipMarkerFetcher = null;
    SourinCore.debugCallAsyncTransport = previousTransport;
    NetworkStatus.debugResetForTest();
    UiPrefs.debugResetForTest();
    CachePage.debugScanRootOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('window_manager'), null);
    final resolved = Directory(scratch.resolveSymbolicLinksSync());
    expect(
      resolved.parent.path,
      Directory.systemTemp.resolveSymbolicLinksSync(),
    );
    expect(
      resolved.path.split(Platform.pathSeparator).last,
      startsWith('sourin-stacked-detail-'),
    );
    resolved.deleteSync(recursive: true);
  });

  for (final size in [const Size(860, 904), const Size(1440, 900)]) {
    testWidgets(
      'real MediaPage ${size.width}x${size.height}: fixed header and reachable episodes',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = size;
        addTearDown(tester.view.reset);
        final theme = AppTheme.themeFor(Brightness.light);
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              builder: (_, child) => AppThemeHost(data: theme, child: child!),
              home: Padding(
                padding: const EdgeInsets.only(top: AppMetrics.titleBarHeight),
                child: MediaPage(
                  provider: _provider,
                  id: _item,
                  title: _title,
                  episodeId: 'PAN1:1',
                  episodeTitle: 'PAN1 正片',
                  episodeIndex: 0,
                  episodes: [
                    for (final row in _episodeRows) Episode.fromJson(row),
                  ],
                  sourceCode: 'PAN1',
                  isTouchOnly: false,
                ),
              ),
            ),
          );
          await _advance(tester);
          expect(find.byType(MediaPage), findsOneWidget);
          expect(find.byType(PlayerPage), findsOneWidget);
          expect(find.byType(DetailPage), findsOneWidget);
          expect(
            requests,
            isNotEmpty,
            reason: 'The original player resolve path must run.',
          );
          expect(
            tester.takeException(),
            isNull,
            reason:
                'The retained stacked window has a real RenderFlex overflow.',
          );

          final detailRect = tester.getRect(find.byType(DetailPage));
          final playerRect = tester.getRect(find.byType(PlayerPage));
          if (size.width < 900) {
            expect(playerRect.height, closeTo(388.8, 0.2));
            expect(detailRect.height, closeTo(475.2, 0.2));
            expect(detailRect.top, closeTo(playerRect.bottom, 0.2));
          } else {
            expect(detailRect.height, closeTo(860, 0.2));
            expect(detailRect.left, greaterThan(playerRect.left));
          }

          final title = _insideDetail(find.text(_title)).first;
          expect(title, findsOneWidget);
          expect(
            find.ancestor(of: title, matching: find.byType(Scrollable)),
            findsNothing,
            reason:
                'The fixed header must not be moved into an outer scroll view.',
          );
          for (final line in ['PAN1', 'NBY', 'qsvip', 'BBA']) {
            expect(_insideDetail(find.text(line)), findsOneWidget);
          }
          final episode = _insideDetail(find.text('PAN1 中文字幕'));
          expect(episode, findsOneWidget);
          expect(
            episode.hitTestable(),
            findsOneWidget,
            reason:
                'A present but clipped episode does not satisfy reachability.',
          );
          final episodeRect = tester.getRect(episode);
          expect(episodeRect.top, greaterThanOrEqualTo(detailRect.top));
          expect(episodeRect.bottom, lessThanOrEqualTo(detailRect.bottom));
          expect(
            find.ancestor(of: episode, matching: find.byType(Scrollable)),
            findsOneWidget,
          );
          final titleBefore = tester.getTopLeft(title);
          await tester.tap(episode);
          await _advance(tester);
          expect(forwarded, hasLength(1));
          expect(forwarded.single.episodeId, 'PAN1:2');
          expect(forwarded.single.sourceCode, 'PAN1');
          expect(
            tester.getTopLeft(title),
            titleBefore,
            reason: 'Changing an episode must not scroll the fixed header.',
          );
          expect(tester.takeException(), isNull);

          // Real requests leave the loading skeleton visible for multiple
          // frames; an immediate fixture response hides its overflow.
          delayedSource = 'qsvip';
          delayedEpisodes = Completer<Object?>();
          final picker = tester.widget<DetailSourcePicker>(
            _insideDetail(find.byType(DetailSourcePicker)),
          );
          picker.onPick(picker.sources.firstWhere((s) => s.code == delayedSource));
          await _advance(tester);
          expect(tester.takeException(), isNull,
              reason: 'Pending source episodes must fit the same fixed pane.');
          final skeleton = _insideDetail(find.byWidgetPredicate(
            (widget) => widget.runtimeType.toString() == '_EpsSkeleton',
          ));
          expect(skeleton, findsOneWidget);
          expect(tester.getTopLeft(title), titleBefore);
          delayedEpisodes!.complete(_episodeRows
              .where((episode) => episode['flag'] == delayedSource).toList());
          await _advance(tester);
          expect(skeleton, findsNothing);
          expect(_insideDetail(find.text('qsvip HD中字')).hitTestable(), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          if (delayedEpisodes != null && !delayedEpisodes!.isCompleted) {
            delayedEpisodes!.complete(<Object>[]);
          }
          await _unmount(tester);
        }
      },
    );
  }
}
