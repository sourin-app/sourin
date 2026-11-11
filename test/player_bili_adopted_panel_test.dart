@Tags(['native-media'])
library;

// Actual mounted PlayerPage/MediaSession and rendered settings-button tap.
// Native output and source/API transport are isolated adapters. Media open is
// disabled; this does not qualify decode, desktop input or Owner acceptance.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_miuix/miuix.dart' as miuix show MiuixDialogLayout, MiuixPopupHost, MiuixPopupScope;
import 'package:sourin_spike/ui/widgets/overlay_motion.dart' show OverlayCardMotion, SheetExitMotion;
import 'package:sourin_spike/ui/widgets/motion_prefs.dart' show MotionPrefs;
import 'package:sourin_spike/ui/tokens.dart' show OverlayMotion;

import 'package:flutter/foundation.dart' show FlutterError, FlutterExceptionHandler;
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as panel_controls show TextButton, ChoiceChip;
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:sourin_spike/core/bili/bili_api.dart';
import 'package:sourin_spike/core/bili/bili_auto_update.dart';
import 'package:sourin_spike/core/bili/bili_bind.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/media_session.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

const _bindingA = BiliBinding(
  bvid: 'BV1fixture0001', aid: 1, title: 'Fixture A binding', manual: false,
  episodes: [BiliEpisodeBinding(episodeIndex: 0, page: 1, cid: 41)],
);
const _bindingB = BiliBinding(
  bvid: 'BV1fixture0002', aid: 2, title: 'Fixture B binding', manual: true,
  episodes: [
    BiliEpisodeBinding(episodeIndex: 0, page: 2, cid: 51),
    BiliEpisodeBinding(episodeIndex: 1, page: 3, cid: 52),
  ],
);
const _requestB = PlayRequestData(
  provider: 'next', id: 'next-work', title: 'Adopted B',
  episodeIndex: 1, episodeId: 'ep-b2', episodeTitle: 'B Episode Two',
  episodes: [Episode(id: 'ep-b1', title: 'B Episode One'),
             Episode(id: 'ep-b2', title: 'B Episode Two')],
);
const _requestA = PlayRequestData(
  provider: 'fixture', id: 'work', title: 'Fixture',
  episodeIndex: 0, episodeId: 'ep1', episodeTitle: 'Episode One',
  episodes: [Episode(id: 'ep1', title: 'Episode One')],
);

class _NoNetworkClient implements HttpClient {
  final blocked = <String>[];
  @override void close({bool force = false}) {}
  @override dynamic noSuchMethod(Invocation invocation) {
    blocked.add(invocation.memberName.toString());
    throw StateError('No external HTTP allowed: ${invocation.memberName}');
  }
}

class _BindingApi extends BiliApi {
  _BindingApi(this.noNetwork) : super(client: noNetwork);
  final _NoNetworkClient noNetwork;
  final infoCalls = <String>[];
  final commentCalls = <int>[];
  @override Future<List<DanmakuComment>> danmaku(int cid) async {
    commentCalls.add(cid);
    throw StateError('Panel hydration cannot fetch comments');
  }
  @override Future<BiliVideoInfo> videoInfo(BiliRef ref) async {
    infoCalls.add(ref.bvid);
    if (ref.bvid != _bindingB.bvid || ref.aid != _bindingB.aid) {
      throw StateError('Only the current manual B metadata fixture is allowed');
    }
    return const BiliVideoInfo(
      bvid: 'BV1fixture0002', aid: 2, title: 'Fixture B info',
      pages: [BiliPage(cid: 51, page: 2, part: 'B P2'),
              BiliPage(cid: 52, page: 3, part: 'B P3')],
    );
  }
}

class _CoreLocal {
  final calls = <String>[];
  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    calls.add(command);
    if (command == 'list_providers' || command == 'resolve_stream') return <dynamic>[];
    if (command == 'provider_danmaku_list') {
      throw StateError('Panel hydration cannot start plugin aggregation');
    }
    if (command == 'pan_cleanup_temp' || command == 'save_progress' ||
        command == 'end_yield_for_seek') return <String, dynamic>{};
    // Retain the reviewed mounted fixture's local missing-data transport rule.
    throw SourinCoreException('No isolated fixture data', 'other');
  }
}

class _ResolverGate {
  final entered = Completer<void>();
  final pending = Completer<List<StreamCandidate>>();
  int nextCalls = 0;
  final requests = <Map<String, String>>[];
  void release() { if (!pending.isCompleted) pending.complete(const <StreamCandidate>[]); }
  Future<List<StreamCandidate>> resolve(String provider, String id, {PlayRequest? req}) async {
    requests.add({'provider': provider, 'id': id});
    if (provider == 'next' && id == 'next-work') {
      nextCalls++;
      if (nextCalls != 1) throw StateError('Unexpected repeated B resolve');
      entered.complete();
      return pending.future;
    }
    return const <StreamCandidate>[];
  }
}

const _videoChannelName = 'com.alexmercerind/media_kit_video';
const _videoChannel = MethodChannel(_videoChannelName);
final _createdHandles = <String>[];
final _disposedHandles = <String>[];
final _pushedHandles = <String>{};

Future<void> _pushCreatedTextures() async {
  for (final handle in _createdHandles.toList()) {
    if (!_pushedHandles.add(handle)) continue;
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
          _videoChannelName,
          _videoChannel.codec.encodeMethodCall(
            MethodCall('VideoOutput.Resize', <String, dynamic>{
              'handle': int.parse(handle),
              'rect': <String, dynamic>{
                'left': 0.0,
                'top': 0.0,
                'width': 0.0,
                'height': 0.0,
              },
              'id': 7,
            }),
          ),
          null,
        );
  }
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump();
    if (ready()) return;
    await tester.runAsync(() async {
      await _pushCreatedTextures();
      await Future<void>.delayed(const Duration(milliseconds: 10));
    });
  }
  expect(ready(), isTrue, reason: 'The real production stage must finish');
}

Future<void> _mount(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const PlayerPage(
        provider: 'fixture',
        id: 'work',
        title: 'Fixture',
        episodes: [Episode(id: 'ep1', title: 'Episode One')],
        episodeIndex: 0,
        episodeId: 'ep1',
        episodeTitle: 'Episode One',
      ),
    ),
  );
  final native =
      tester.widget<Video>(find.byType(Video)).controller.player.platform
          as NativePlayer;
  await _waitFor(tester, () => native.videoControllerCompleter.isCompleted);
  await tester.pump();
}

Future<void> _finish(WidgetTester tester) async {
  final native =
      tester.widget<Video>(find.byType(Video)).controller.player.platform
          as NativePlayer;
  final handle = _createdHandles.single;
  await tester.pumpWidget(const SizedBox.shrink());
  await _waitFor(
    tester,
    () => native.disposed && _disposedHandles.contains(handle),
  );
  var unlocked = false;
  final disposalBarrier = NativePlayer.lock.synchronized(() async {
    unlocked = true;
  });
  await _waitFor(tester, () => unlocked);
  await disposalBarrier;
  await tester.pump(const Duration(seconds: 6));
  await tester.pump(const Duration(seconds: 1));
  expect(tester.takeException(), isNull);
}


Map<String, String?> _bindingPreferences() => {
  for (final pair in const [('fixture', 'work'), ('next', 'next-work')])
    for (final key in [BiliPrefs.bindKey(pair.$1, pair.$2),
                      BiliPrefs.manualKey(pair.$1, pair.$2),
                      BiliPrefs.pageKey(pair.$1, pair.$2)]) key: UiPrefs.get(key),
};

Future<BiliImportDialog> _openByActualSettingsTap(WidgetTester tester) async {
  expect(debugPlayerOpenDanmakuSettingsForProbe(), isTrue, reason: 'SETUP original settings callback required');
  await tester.pump();
  final settingsFinder = find.byType(DanmakuSettingsDialog);
  expect(settingsFinder, findsOneWidget, reason: 'SETUP original settings must mount');
  var settings = tester.widget<DanmakuSettingsDialog>(settingsFinder);
  expect(settings.onOpenBili, isNotNull, reason: 'SETUP actual host opener required');
  final layoutFinder = find.descendant(of: settingsFinder,
    matching: find.byType(miuix.MiuixDialogLayout));
  expect(layoutFinder, findsOneWidget, reason: 'SETUP unique actual original dialog layout required');
  final layout = tester.widget<miuix.MiuixDialogLayout>(layoutFinder);
  final registry = miuix.MiuixPopupScope.of(tester.element(layoutFinder), root: layout.renderInRoot);
  final entries = registry.entries.where((entry) => identical(entry.controller, layout.controller)).toList();
  expect(entries, hasLength(1), reason: 'SETUP unique original controller registered entry required');
  final originalEntry = entries.single;
  final hostFinder = find.descendant(of: settingsFinder,
    matching: find.byType(miuix.MiuixPopupHost));
  expect(hostFinder, findsOneWidget, reason: 'SETUP unique original local popup host required');
  final host = tester.widget<miuix.MiuixPopupHost>(hostFinder);
  final hostRegistry = host.registry ?? miuix.MiuixPopupScope.of(tester.element(hostFinder));
  expect(identical(hostRegistry, registry), isTrue, reason: 'SETUP original host must own original layout registry');
  final entryFinder = find.descendant(of: hostFinder,
    matching: find.byKey(ObjectKey(originalEntry)));
  final sheetFinder = find.ancestor(of: settingsFinder, matching: find.byType(SheetExitMotion));
  expect(sheetFinder, findsOneWidget, reason: 'SETUP original settings sheet lifetime wrapper required');
  final sheet = tester.widget<SheetExitMotion>(sheetFinder);
  void traceAttached(String stage) {
    final rows = <Map<String, Object?>>[];
    var visited = 0;
    var truncated = false;
    void visit(Element element, int depth) {
      if (visited >= 256 || depth > 32) { truncated = true; return; }
      visited++;
      final name = element.widget.runtimeType.toString();
      final key = element.widget.key;
      final important = key != null || name.contains('MiuixPopup') || name.contains('MiuixDialog') ||
        name.contains('HostedEntry') || name == 'AppDialogShell' || name == 'AppMiuixDialogHost' ||
        name == 'OverlayCardMotion' || name == 'OverlayScrim' || name == 'ChoiceChip';
      if (important && rows.length < 48) {
        rows.add({'depth': depth, 'type': name, 'key': key?.toString(),
          'originalEntryKey': key == ObjectKey(originalEntry), 'mounted': element.mounted});
      }
      element.visitChildren((child) => visit(child, depth + 1));
    }
    visit(tester.element(settingsFinder), 0);
    final entryRows = <Map<String, Object?>>[
      for (final entry in registry.entries.take(4))
        {'sameOriginal': identical(entry, originalEntry),
         'sameController': identical(entry.controller, layout.controller),
         'visible': entry.controller.visible, 'type': entry.runtimeType.toString()},
    ];
    final tabs = find.descendant(of: entryFinder,
      matching: find.byKey(const ValueKey('danmaku-settings-tabs')));
    final cards = find.descendant(of: entryFinder, matching: find.byType(OverlayCardMotion));
    double? opacity;
    if (cards.evaluate().length == 1) {
      final opacities = find.descendant(of: cards, matching: find.byType(Opacity));
      if (opacities.evaluate().isNotEmpty) opacity = tester.widget<Opacity>(opacities.first).opacity;
    }
    debugPrint('[adopted-bili] attached $stage ${jsonEncode({
      'settingsCount': settingsFinder.evaluate().length,
      'layoutCount': layoutFinder.evaluate().length,
      'hostCount': hostFinder.evaluate().length,
      'sameHostRegistry': identical(hostRegistry, registry),
      'controllerVisible': layout.controller.visible,
      'renderInRoot': layout.renderInRoot,
      'enterDurationUs': layout.enterTransition?.duration.inMicroseconds,
      'exitDurationUs': layout.exitTransition?.duration.inMicroseconds,
      'registryEntryCount': registry.entries.length,
      'entryRootCount': entryFinder.evaluate().length,
      'tabsInOriginalEntry': tabs.evaluate().length,
      'sheetVisible': sheet.visible, 'cardCount': cards.evaluate().length,
      'cardOpacity': opacity, 'entries': entryRows, 'visited': visited,
      'truncated': truncated, 'rows': rows})}');
  }
  traceAttached('registered-before-host-frame');
  expect(layout.controller.visible, isTrue, reason: 'SETUP original controller must target visible content');
  expect(layout.renderInRoot, isFalse, reason: 'SETUP original layout must render in local host registry');
  expect(layout.enterTransition?.duration, Duration.zero, reason: 'SETUP original route transition is synchronous');
  expect(sheet.visible, isTrue, reason: 'SETUP original sheet must target visible content');
  // Registry add occurs during child build. The original Host deliberately
  // schedules setState at post-frame; this next frame paints that same entry.
  await tester.pump();
  traceAttached('after-host-frame');
  expect(entryFinder, findsOneWidget, reason: 'SETUP next original host frame must attach original entry key');
  final cardFinder = find.descendant(of: entryFinder, matching: find.byType(OverlayCardMotion));
  expect(cardFinder, findsOneWidget, reason: 'SETUP original registered card motion must mount');
  final card = tester.widget<OverlayCardMotion>(cardFinder);
  final cardDuration = MotionPrefs.duration(tester.element(cardFinder), card.duration ?? OverlayMotion.cardDuration);
  await tester.pump(cardDuration);
  await tester.pump();
  traceAttached('card-completed-before-sources-tab');
  final cardOpacity = find.descendant(of: cardFinder, matching: find.byType(Opacity)).first;
  expect(tester.widget<Opacity>(cardOpacity).opacity, 1.0,
    reason: 'SETUP original card animation must complete before real sources tap');
  final tabsFinder = find.descendant(of: entryFinder,
    matching: find.byKey(const ValueKey('danmaku-settings-tabs')));
  expect(tabsFinder, findsOneWidget, reason: 'SETUP original fixed tab bar required');
  final sourcesTab = find.descendant(of: tabsFinder, matching: find.byWidgetPredicate(
    (widget) => widget is panel_controls.ChoiceChip && widget.label is Text &&
      (widget.label as Text).data == '弹幕来源'));
  expect(sourcesTab, findsOneWidget, reason: 'SETUP original sources tab required');
  void traceSetup(String stage) {
    final chips = find.descendant(of: tabsFinder, matching: find.byType(panel_controls.ChoiceChip))
      .evaluate().take(4).map((element) {
        final chip = element.widget as panel_controls.ChoiceChip;
        return {'label': chip.label is Text ? (chip.label as Text).data : '<non-text>',
          'selected': chip.selected, 'callbackPresent': chip.onSelected != null};
      }).toList();
    final controls = find.descendant(of: entryFinder, matching: find.byType(panel_controls.TextButton))
      .evaluate().take(12).map((element) {
        final button = element.widget as panel_controls.TextButton;
        return {'callbackPresent': button.onPressed != null,
          'sameOriginalOpener': identical(button.onPressed, settings.onOpenBili)};
      }).toList();
    debugPrint('[adopted-bili] setup $stage ${jsonEncode({'chips': chips, 'buttons': controls})}');
  }
  traceSetup('before-sources-tab');
  expect(tester.widget<panel_controls.ChoiceChip>(sourcesTab).selected, isFalse,
    reason: 'SETUP new original settings starts on display tab');
  await tester.ensureVisible(sourcesTab);
  await tester.pump();
  expect(sourcesTab.hitTestable(), findsOneWidget, reason: 'SETUP original sources tab must be hit-testable');
  await tester.tap(sourcesTab);
  await tester.pump(const Duration(milliseconds: 320));
  await tester.pump();
  expect(tester.widget<panel_controls.ChoiceChip>(sourcesTab).selected, isTrue,
    reason: 'SETUP actual sources tab pointer tap must select sources');
  // Observe the current actual host field after the tab's normal rebuild.
  settings = tester.widget<DanmakuSettingsDialog>(settingsFinder);
  expect(settings.onOpenBili, isNotNull, reason: 'SETUP current original host opener required');
  traceSetup('after-sources-tab');
  final button = find.descendant(of: entryFinder, matching: find.byWidgetPredicate(
    (widget) => widget is panel_controls.TextButton && identical(widget.onPressed, settings.onOpenBili)));
  expect(button, findsOneWidget, reason: 'SETUP unique rendered original opener required');
  await tester.ensureVisible(button);
  await tester.pump();
  expect(button.hitTestable(), findsOneWidget, reason: 'SETUP original opener must be hit-testable');
  await tester.tap(button);
  // Preserve normal parent double-tap arbitration before inspecting the newly
  // mounted panel. This is a gesture/controller completion budget, not timing.
  await tester.pump(const Duration(milliseconds: 320));
  await tester.pump();
  await tester.pump();
  expect(find.byType(BiliImportDialog), findsOneWidget, reason: 'SETUP original tap must open one real panel');
  return tester.widget<BiliImportDialog>(find.byType(BiliImportDialog));
}

void main() {
  late Directory scratch;
  late _CoreLocal core;
  late _ResolverGate resolver;
  late _BindingApi api;
  FlutterExceptionHandler? originalErrorHandler;
  final frameworkErrors = <String>[];
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    expect(dll.existsSync(), isTrue);
    MediaKit.ensureInitialized(libmpv: dll.absolute.path);
  });
  setUp(() async {
    scratch = await Directory.systemTemp.createTemp('adopted-bili-panel-');
    ClipDownloader.debugSetDataDir(scratch.path);
    UiPrefs.debugResetForTest();
    BiliDanmakuStore.debugResetForTest();
    await UiPrefs.load(scratch.path);
    setBiliAutoUpdateEnabled(false);
    saveBinding('fixture', 'work', _bindingA);
    saveBinding('next', 'next-work', _bindingB);
    UiPrefs.set(BiliPrefs.pageKey('fixture', 'work'), '1');
    UiPrefs.set(BiliPrefs.pageKey('next', 'next-work'), '3');
    await UiPrefs.flush();
    _createdHandles.clear(); _disposedHandles.clear(); _pushedHandles.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_videoChannel, (call) async {
      if (call.method == 'VideoOutputManager.Create') _createdHandles.add(call.arguments['handle'] as String);
      else if (call.method == 'VideoOutputManager.Dispose') _disposedHandles.add(call.arguments['handle'] as String);
      return null;
    });
    core = _CoreLocal(); resolver = _ResolverGate(); api = _BindingApi(_NoNetworkClient());
    Device.overrideKind(DeviceKind.desktop); RemoteBridge.instance.stop();
    debugPlayerSkipOpenForProbe = true;
    SourinApi.debugSkipMarkerFetcher = (_, __) async => null;
    SourinApi.debugResolveStreamFetcher = resolver.resolve;
    SourinCore.debugCallAsyncTransport = core.call;
    frameworkErrors.clear(); originalErrorHandler = FlutterError.onError;
    FlutterError.onError = (details) { frameworkErrors.add(details.exceptionAsString()); originalErrorHandler?.call(details); };
  });
  tearDown(() async {
    FlutterError.onError = originalErrorHandler;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(_videoChannel, null);
    RemoteBridge.instance.stop(); debugPlayerSkipOpenForProbe = false;
    SourinApi.debugSkipMarkerFetcher = null; SourinApi.debugResolveStreamFetcher = null;
    SourinCore.debugCallAsyncTransport = null; Device.overrideKind(null);
    await UiPrefs.flush(); UiPrefs.debugResetForTest(); BiliDanmakuStore.debugResetForTest();
    ClipDownloader.debugSetDataDir(null); await scratch.delete(recursive: true);
  });

  for (final scenario in ['a-control', 'adopted-b', 'return-a-control']) {
    final name = switch (scenario) {
      'adopted-b' => 'same State adopted B opens its selected-episode binding and saved P',
      'return-a-control' => 'same State returns to A and opens original binding and saved P',
      _ => 'unchanged A opens its original binding and saved P',
    };
    testWidgets(name, (tester) async {
      final report = <String, Object?>{'scenario': scenario, 'passed': false, 'setupCompleted': false,
        'sameState': false, 'sameWidget': false, 'panelOpenedByActualTap': false,
        'nativeTerminal': false, 'cleanupErrors': <String>[], 'decodedMediaAccepted': false,
        'desktopInputActions': 0, 'ownerAccepted': false};
      var switchingStarted = false; var switchingDone = false;
      var returningStarted = false; var returningDone = false;
      Future<void> switching = Future<void>.value(); Future<void> returning = Future<void>.value();
      Object? failure; StackTrace? failureStack;
      try {
        await _mount(tester);
        final initialWidget = tester.widget<PlayerPage>(find.byType(PlayerPage));
        final initialState = tester.state(find.byType(PlayerPage));
        final session = initialState as MediaSession;
        debugPlayerSetBiliApiForProbe(api);
        expect(initialWidget.provider, 'fixture'); expect(initialWidget.id, 'work');
        expect(session.currentEpisodeId, 'ep1'); expect(biliAutoUpdateEnabled(), isFalse);
        final preferencesBefore = _bindingPreferences();
        report['preferencesBefore'] = preferencesBefore;
        final initialGeneration = debugPlayerSessionGenForProbe()!;
        if (scenario != 'a-control') {
          switchingStarted = true; switching = session.applySession(_requestB);
          switching.then((_) => switchingDone = true);
          await _waitFor(tester, () => resolver.entered.isCompleted);
          expect(resolver.nextCalls, 1); expect(switchingDone, isFalse);
          expect(resolver.pending.isCompleted, isFalse);
          expect(debugPlayerSessionGenForProbe(), greaterThan(initialGeneration));
          expect(session.currentEpisodeId, 'ep-b2'); expect(debugPlayerEpisodeIndexForProbe(), 1);
          if (scenario == 'return-a-control') {
            returningStarted = true; returning = session.applySession(_requestA);
            returning.then((_) => returningDone = true);
            await _waitFor(tester, () => returningDone); await returning;
            expect(session.currentEpisodeId, 'ep1'); expect(debugPlayerEpisodeIndexForProbe(), 0);
            expect(switchingDone, isFalse); expect(resolver.pending.isCompleted, isFalse);
          }
        }
        report['sameState'] = identical(initialState, tester.state(find.byType(PlayerPage)));
        report['sameWidget'] = identical(initialWidget, tester.widget<PlayerPage>(find.byType(PlayerPage)));
        expect(report['sameState'], isTrue); expect(report['sameWidget'], isTrue);
        final panel = await _openByActualSettingsTap(tester);
        report['panelOpenedByActualTap'] = true;
        report['setupCompleted'] = true;
        final state = panel.state;
        report['panel'] = {'bvid': state.binding?.bvid, 'manual': state.binding?.manual,
          'cid': state.binding?.cidFor(state.episodeIndex), 'selectedPage': state.selectedPage,
          'episodeIndex': state.episodeIndex, 'episodeTitle': state.episodeTitle,
          'episodeCount': state.episodeCount, 'metadataBvid': state.info?.bvid};
        report['metadataCalls'] = api.infoCalls.toList();
        report['preferencesAfter'] = _bindingPreferences();
        report['resolverHeldAtObservation'] = scenario == 'adopted-b' && !resolver.pending.isCompleted && !switchingDone;
        debugPrint('[adopted-bili] $scenario observed ${jsonEncode(report['panel'])}');
        expect(_bindingPreferences(), preferencesBefore, reason: 'Opening reads cannot modify either private binding/P identity');
        expect(api.commentCalls, isEmpty); expect(api.noNetwork.blocked, isEmpty);
        if (scenario == 'adopted-b') {
          expect(state.binding?.bvid, _bindingB.bvid,
            reason: 'Opened B panel must hydrate the adopted session B binding');
          expect(state.binding?.manual, isTrue);
          expect(state.binding?.cidFor(1), 52); expect(state.selectedPage, 3);
          expect(state.episodeIndex, 1); expect(state.episodeTitle, 'B Episode Two'); expect(state.episodeCount, 2);
          expect(api.infoCalls, [_bindingB.bvid], reason: 'Current B manual eligibility must hydrate B metadata');
          expect(state.info?.bvid, _bindingB.bvid);
          expect(find.textContaining('Fixture B binding'), findsOneWidget);
          expect(report['resolverHeldAtObservation'], isTrue);
        } else {
          expect(state.binding?.bvid, _bindingA.bvid); expect(state.binding?.manual, isFalse);
          expect(state.binding?.cidFor(0), 41); expect(state.selectedPage, 1);
          expect(state.episodeIndex, 0); expect(state.episodeTitle, 'Episode One'); expect(state.episodeCount, 1);
          expect(api.infoCalls, isEmpty, reason: 'Nonmanual A must not request metadata on opening');
          expect(find.textContaining('Fixture A binding'), findsOneWidget);
        }
        report['passed'] = true;
      } catch (error, stack) { failure = error; failureStack = stack; report['failure'] = error.toString(); }
      finally {
        try {
          resolver.release();
          if (switchingStarted) { await _waitFor(tester, () => switchingDone); await switching; }
          if (returningStarted) { await _waitFor(tester, () => returningDone); await returning; }
          if (find.byType(PlayerPage).evaluate().isNotEmpty) await _finish(tester);
          report['nativeTerminal'] = true;
          expect(frameworkErrors, isEmpty);
          debugPrint('[adopted-bili] $scenario native terminal');
        } catch (error, stack) {
          (report['cleanupErrors'] as List<String>).add(error.toString());
          failure ??= error; failureStack ??= stack; report['passed'] = false;
        }
        report['frameworkErrors'] = frameworkErrors.toList();
        report['coreCalls'] = core.calls.toList();
        report['commentCalls'] = api.commentCalls.toList(); report['blockedHttp'] = api.noNetwork.blocked.toList();
        report['createdHandles'] = _createdHandles.toList(); report['disposedHandles'] = _disposedHandles.toList();
        final output = Platform.environment['SOURIN_BILI_PANEL_RUN']!;
        File('$output/$scenario-result.json').writeAsStringSync(jsonEncode(report) + '\n', flush: true);
      }
      if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
    });
  }
}
