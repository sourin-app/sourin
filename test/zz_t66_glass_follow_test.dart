// Historical filename retained for the follow-page regression gate.
// Exercise the real Miuix page, its detail action, data, tabs and input paths.
import 'dart:ui' show SemanticsFlag;

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/follow_page.dart';

import 'support/follow_fixture.dart';

const _progress = followProgressFixture;

Future<void> _mount(
  WidgetTester tester, {
  required Brightness brightness,
  required double width,
  required List<String> details,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 800);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(brightness);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: AppScaffold(
        child: FollowPage(
          initialTab: 'continue',
          onOpenDetail: (provider, id) => details.add('$provider:$id'),
        ),
      ),
    ),
  );
  // Wait for the real load/refresh path backed by the isolated transport.
  // Never drain framework exceptions: layout and semantics failures must fail.
  await tester.pumpAndSettle();
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    SourinCore.debugCallAsyncTransport = followFixtureTransport;
  });
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    UiPrefs.debugResetForTest();
  });

  for (final brightness in Brightness.values) {
    for (final width in [360.0, 1280.0]) {
      testWidgets(
        'real follow tabs select with pointer and arrows at $brightness / $width',
        (tester) async {
          final details = <String>[];
          await _mount(
            tester,
            brightness: brightness,
            width: width,
            details: details,
          );
          final tabs = find.byType(miuix.MiuixGlassSegmentedTabRow);
          expect(tabs, findsOneWidget);
          expect(
            tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
            2,
          );
          expect(tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).tabs, [
            '追更 0',
            '收藏 0',
            '历史 1',
          ]);
          final bounds = tester.getRect(tabs);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(width));
          expect(bounds.height, greaterThanOrEqualTo(40));
          expect(find.text(_progress.title), findsOneWidget);
          final state = tester.state<FollowPageState>(find.byType(FollowPage));
          expect(state.activeTabKey, 'continue');

          await tester.tap(find.text('收藏 0'));
          await tester.pump();
          expect(
            tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
            1,
          );
          expect(find.text('还没有收藏'), findsOneWidget);
          expect(state.activeTabKey, 'all');
          Focus.of(tester.element(find.text('收藏 0'))).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          expect(
            tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
            0,
          );
          expect(find.text('还没有追更的内容'), findsOneWidget);
          expect(state.activeTabKey, 'following');
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(
            tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
            1,
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(
            tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
            2,
          );
          expect(find.text(_progress.title), findsOneWidget);
          expect(details, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );

      testWidgets(
        'real continue card retains progress detail action and keyboard activation at $brightness / $width',
        (tester) async {
          final semantics = tester.ensureSemantics();
          try {
            final details = <String>[];
            await _mount(
              tester,
              brightness: brightness,
              width: width,
              details: details,
            );
            final title = find.text(_progress.title);
            final card = find
                .ancestor(of: title, matching: find.byType(miuix.MiuixCard))
                .first;
            expect(card, findsOneWidget);
            expect(tester.getSize(card).shortestSide, greaterThanOrEqualTo(44));
            final progress = find.descendant(
              of: card,
              matching: find.byType(miuix.MiuixLinearProgressIndicator),
            );
            expect(progress, findsOneWidget);
            expect(
              tester
                  .widget<miuix.MiuixLinearProgressIndicator>(progress)
                  .progress,
              .4,
            );
            final node = tester.getSemantics(
              find.bySemanticsLabel(RegExp(_progress.title)).first,
            );
            expect(node.hasFlag(SemanticsFlag.isButton), isTrue);

            await tester.tap(card);
            await tester.pump();
            expect(details, ['fixture:continue']);
            Focus.of(tester.element(title)).requestFocus();
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.enter);
            await tester.pump();
            await tester.sendKeyEvent(LogicalKeyboardKey.select);
            await tester.pump();
            expect(details, [
              'fixture:continue',
              'fixture:continue',
              'fixture:continue',
            ]);
            expect(tester.takeException(), isNull);
          } finally {
            semantics.dispose();
          }
        },
      );
    }
  }
}
