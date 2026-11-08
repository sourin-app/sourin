import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/design/widgets/app_ink_well.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

const _low = LiveQualityOption(
  value: 'https://example.invalid/low.m3u8',
  label: '标清',
);
const _high = LiveQualityOption(
  value: 'https://example.invalid/high.m3u8',
  label: '高清',
);

Finder _option(int index, LiveQualityOption option) =>
    find.byKey(ValueKey('live-quality-opt-$index-${option.value}'));

Finder _checkIn(Finder row) =>
    find.descendant(of: row, matching: find.byIcon(AppIcons.check));

FocusNode _triggerFocus(WidgetTester tester) => tester
    .widget<AppInkWell>(
      find.ancestor(
        of: find.byIcon(AppIcons.high_quality),
        matching: find.byType(AppInkWell),
      ),
    )
    .focusNode!;

Finder _menuItemFinder(Finder row) =>
    find.ancestor(of: row, matching: find.byType(miuix.MiuixBasicComponent));

miuix.MiuixBasicComponent _menuItem(WidgetTester tester, Finder row) =>
    tester.widget<miuix.MiuixBasicComponent>(_menuItemFinder(row));

// Focus updates rebuild AppMenu, then Miuix defers its separate OverlayEntry
// rebuild to the frame end. Observe the committed row after both frames.
Future<void> _pumpMenuFocus(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

// The actual player's loading indicator animates while native creation is
// skipped. Advance popup animations without waiting for every ticker to settle.
Future<void> _pumpMenu(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await _pumpMenuFocus(tester);
}

Future<void> _mountPlayer(
  WidgetTester tester, {
  required List<LiveQualityOption> options,
  required LiveQualityOption initial,
  required List<LiveQualityOption> picked,
}) async {
  tester.view.physicalSize = const Size(900, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  var current = initial;
  final theme = AppTheme.themeFor(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 532,
            height: 356,
            child: StatefulBuilder(
              builder: (_, setState) => LiveEmbeddedPlayer(
                stream: StreamCandidate(
                  url: current.value,
                  kind: 'hls',
                  label: current.label,
                ),
                title: '清晰度菜单',
                qualityOptions: options,
                onQualityChanged: (option) {
                  picked.add(option);
                  setState(() => current = option);
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<void> _unmountPlayer(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  late Directory scratch;
  late bool previousSkipPlayerCreation;
  late bool? previousForcePlaying;
  late bool previousFatalHitWarnings;

  setUp(() {
    scratch = Directory.systemTemp.createTempSync('live_quality_miuix_');
    ClipDownloader.debugSetDataDir(scratch.path);
    previousSkipPlayerCreation = debugSkipPlayerCreation;
    previousForcePlaying = debugForcePlaying;
    previousFatalHitWarnings = WidgetController.hitTestWarningShouldBeFatal;
    debugSkipPlayerCreation = true;
    debugForcePlaying = null;
    WidgetController.hitTestWarningShouldBeFatal = true;
  });

  tearDown(() {
    debugSkipPlayerCreation = previousSkipPlayerCreation;
    debugForcePlaying = previousForcePlaying;
    WidgetController.hitTestWarningShouldBeFatal = previousFatalHitWarnings;
    ClipDownloader.debugSetDataDir(null);
    if (scratch.existsSync()) scratch.deleteSync(recursive: true);
  });

  testWidgets(
    'live quality selection uses Miuix and updates the current mark',
    (tester) async {
      final picked = <LiveQualityOption>[];
      try {
        await _mountPlayer(
          tester,
          options: const [_low, _high],
          initial: _low,
          picked: picked,
        );
        final triggerFocus = _triggerFocus(tester);
        await tester.tap(find.byIcon(AppIcons.high_quality));
        await _pumpMenu(tester);

        expect(find.byType(miuix.MiuixWindowListPopup), findsOneWidget);
        expect(find.byType(miuix.MiuixListPopupContent), findsOneWidget);
        expect(find.byType(miuix.MiuixBasicComponent), findsNWidgets(2));
        expect(find.byType(MenuAnchor), findsNothing);
        expect(find.byType(MenuItemButton), findsNothing);
        expect(_checkIn(_option(0, _low)), findsOneWidget);
        expect(_checkIn(_option(1, _high)), findsNothing);

        await tester.tap(_menuItemFinder(_option(1, _high)));
        await _pumpMenu(tester);
        expect(picked, hasLength(1));
        expect(picked.single, same(_high));
        expect(find.byType(miuix.MiuixWindowListPopup), findsNothing);
        expect(triggerFocus.hasPrimaryFocus, isTrue);

        await tester.tap(find.byIcon(AppIcons.high_quality));
        await _pumpMenu(tester);
        expect(_checkIn(_option(0, _low)), findsNothing);
        expect(_checkIn(_option(1, _high)), findsOneWidget);
        expect(_menuItem(tester, _option(1, _high)).holdDownState, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _pumpMenu(tester);
        expect(picked, hasLength(1));
        expect(triggerFocus.hasPrimaryFocus, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmountPlayer(tester);
      }
    },
  );

  testWidgets(
    'keyboard opens at current quality and restores focus on Escape',
    (tester) async {
      final picked = <LiveQualityOption>[];
      try {
        await _mountPlayer(
          tester,
          options: const [_low, _high],
          initial: _high,
          picked: picked,
        );
        final triggerFocus = _triggerFocus(tester)..requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _pumpMenu(tester);
        expect(_menuItem(tester, _option(1, _high)).holdDownState, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.escape);
        await _pumpMenu(tester);
        expect(picked, isEmpty);
        expect(find.byType(miuix.MiuixWindowListPopup), findsNothing);
        expect(triggerFocus.hasPrimaryFocus, isTrue);

        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _pumpMenu(tester);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await _pumpMenuFocus(tester);
        expect(_menuItem(tester, _option(0, _low)).holdDownState, isTrue);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await _pumpMenu(tester);
        expect(picked, hasLength(1));
        expect(picked.single, same(_low));
        expect(triggerFocus.hasPrimaryFocus, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmountPlayer(tester);
      }
    },
  );

  testWidgets(
    'duplicate stream URLs preserve option identity and exclude DRM',
    (tester) async {
      const first = LiveQualityOption(
        value: 'https://example.invalid/shared.m3u8',
        label: '高清主线',
      );
      const second = LiveQualityOption(
        value: 'https://example.invalid/shared.m3u8',
        label: '高清备用',
      );
      const protected = LiveQualityOption(
        value: 'https://example.invalid/protected.m3u8',
        label: '受保护线路',
        drm: true,
      );
      final picked = <LiveQualityOption>[];
      try {
        await _mountPlayer(
          tester,
          options: const [first, protected, second],
          initial: first,
          picked: picked,
        );
        final triggerFocus = _triggerFocus(tester);
        await tester.tap(find.byIcon(AppIcons.high_quality));
        await _pumpMenu(tester);
        expect(_option(0, first), findsOneWidget);
        expect(_option(1, second), findsOneWidget);
        expect(find.byType(miuix.MiuixBasicComponent), findsNWidgets(2));
        expect(find.text(protected.label), findsNothing);
        // The current stream is URL-based, so both equivalent URLs stay marked.
        expect(_checkIn(_option(0, first)), findsOneWidget);
        expect(_checkIn(_option(1, second)), findsOneWidget);

        await tester.tap(_menuItemFinder(_option(1, second)));
        await _pumpMenu(tester);
        expect(picked, hasLength(1));
        expect(picked.single, same(second));
        expect(triggerFocus.hasPrimaryFocus, isTrue);
        expect(tester.takeException(), isNull);
      } finally {
        await _unmountPlayer(tester);
      }
    },
  );
}
