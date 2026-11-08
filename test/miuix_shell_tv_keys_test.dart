import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart' show RenderBox;
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/shell.dart' show ShellPage;
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/follow_page.dart';
import 'package:sourin_spike/ui/spatial_nav.dart'
    show primeFocus, spatialNavCandidates, spatialNavLog;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as controls;

import 'support/follow_fixture.dart';

Future<void> _mountShellRoute(WidgetTester tester, Widget page) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  final navigator = GlobalKey<NavigatorState>();
  final theme = AppTheme.themeFor(Brightness.dark);
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      // The actual ShellPage still installs its early TV key handler; only its
      // core-dependent content is replaced by its production error page.
      home: const ShellPage(
        coreError: 'PathAccessException: Permission denied',
      ),
    ),
  );
  await tester.pumpAndSettle();
  navigator.currentState!.push(
    MaterialPageRoute<void>(builder: (_) => AppScaffold(child: page)),
  );
  await tester.pumpAndSettle();
  expect(find.byType(ShellPage, skipOffstage: false), findsOneWidget);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    Device.overrideKind(DeviceKind.tv);
    SourinCore.debugCallAsyncTransport = followFixtureTransport;
  });
  tearDown(() {
    Device.overrideKind(null);
    SourinCore.debugCallAsyncTransport = null;
    UiPrefs.debugResetForTest();
  });

  testWidgets(
    'real TV shell lets follow tabs select before moving down to a card',
    (tester) async {
      final details = <String>[];
      await _mountShellRoute(
        tester,
        FollowPage(
          isTv: true,
          onOpenDetail: (provider, id) => details.add('$provider:$id'),
        ),
      );
      final tabs = find.byType(miuix.MiuixTabRow);
      expect(tabs, findsOneWidget);
      final groupFocus = Focus.of(tester.element(tabs));
      groupFocus.requestFocus();
      await tester.pump();
      expect(groupFocus.hasPrimaryFocus, isTrue);
      expect(tester.widget<miuix.MiuixTabRow>(tabs).selectedTabIndex, 0);

      for (final index in [1, 2]) {
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pumpAndSettle();
        expect(tester.widget<miuix.MiuixTabRow>(tabs).selectedTabIndex, index);
        expect(FocusManager.instance.primaryFocus, same(groupFocus));
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
      await tester.pumpAndSettle();
      expect(tester.widget<miuix.MiuixTabRow>(tabs).selectedTabIndex, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
      await tester.pumpAndSettle();

      final title = find.text(followProgressFixture.title);
      expect(title, findsOneWidget);
      final card = find.ancestor(
        of: title,
        matching: find.byType(miuix.MiuixCard),
      );
      expect(card, findsOneWidget);
      final cardFocus = Focus.of(tester.element(title));
      expect(cardFocus.canRequestFocus, isTrue);
      expect(cardFocus, isNot(same(groupFocus)));
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(FocusManager.instance.primaryFocus, same(cardFocus));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(details, ['fixture:continue']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('real TV shell edits slider horizontally and exits vertically', (
    tester,
  ) async {
    final sliderFocus = FocusNode(debugLabel: 'settings-slider');
    final nextFocus = FocusNode(debugLabel: 'next-setting');
    addTearDown(sliderFocus.dispose);
    addTearDown(nextFocus.dispose);
    var value = .5;
    var activations = 0;
    await _mountShellRoute(
      tester,
      Center(
        child: SizedBox(
          width: 320,
          child: StatefulBuilder(
            builder: (_, setState) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                controls.Slider(
                  value: value,
                  divisions: 10,
                  focusNode: sliderFocus,
                  onChanged: (next) => setState(() => value = next),
                ),
                const SizedBox(height: 32),
                controls.TextButton(
                  focusNode: nextFocus,
                  onPressed: () => activations++,
                  child: const Text('下一项'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    sliderFocus.requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(value, closeTo(.6, .0001));
    expect(FocusManager.instance.primaryFocus, same(sliderFocus));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
    await tester.pump();
    expect(value, closeTo(.5, .0001));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    expect(
      FocusManager.instance.primaryFocus,
      same(nextFocus),
      reason:
          'TV spatial navigation must reach the actual shared button. '
          'Its excluded package focus descendants must not remove it from '
          'the candidate pool. Navigation: $spatialNavLog',
    );
    expect(
      nextFocus.children,
      isNotEmpty,
      reason: 'The fixture must exercise the real adapter with excluded package nodes.',
    );
    expect(nextFocus.descendants.any((node) => node.canRequestFocus), isFalse);
    expect(
      primeFocus(),
      isFalse,
      reason: 'An already focused real control must not be mistaken for a container.',
    );
    expect(value, closeTo(.5, .0001));
    await tester.sendKeyEvent(LogicalKeyboardKey.select);
    await tester.pump();
    expect(activations, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'TV candidates exclude scopes and containers with independent controls',
    (tester) async {
      final container = FocusNode(debugLabel: 'full-page-container');
      final first = FocusNode(debugLabel: 'first-control');
      final second = FocusNode(debugLabel: 'second-control');
      final scope = FocusScopeNode(debugLabel: 'settings-scope');
      addTearDown(container.dispose);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      addTearDown(scope.dispose);
      var selected = 0;
      await _mountShellRoute(
        tester,
        FocusScope(
          node: scope,
          child: Focus(
            focusNode: container,
            child: Center(
              child: SizedBox(
                width: 320,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    controls.TextButton(
                      focusNode: first,
                      onPressed: () {},
                      child: const Text('第一项'),
                    ),
                    const SizedBox(height: 32),
                    controls.TextButton(
                      focusNode: second,
                      onPressed: () => selected++,
                      child: const Text('第二项'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      first.requestFocus();
      await tester.pump();
      expect(first.hasPrimaryFocus, isTrue);
      expect(container.descendants.any((node) => node.canRequestFocus), isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(
        FocusManager.instance.primaryFocus,
        same(second),
        reason:
            'Container/scope rectangles must not win over the next control: $spatialNavLog',
      );
      final containerBox = container.context!.findRenderObject()! as RenderBox;
      final containerRect =
          containerBox.localToGlobal(Offset.zero) & containerBox.size;
      expect(spatialNavCandidates, isNot(contains(containerRect)));
      expect(FocusManager.instance.primaryFocus, isNot(isA<FocusScopeNode>()));
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(selected, 1);
      expect(tester.takeException(), isNull);
    },
  );
}
