import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/source_switch_dialog.dart';

class _SearchRun {
  _SearchRun(this.keyword, this.onEvent);

  final String keyword;
  final bool Function(SearchStreamEvent) onEvent;
  final completion = Completer<void>();

  void finish({bool error = false}) {
    if (completion.isCompleted) return;
    if (error) {
      completion.completeError(StateError('Earlier search failed'));
    } else {
      completion.complete();
    }
  }
}

class _ControlledSearch {
  final runs = <_SearchRun>[];

  Future<void> call(
    String keyword,
    bool Function(SearchStreamEvent) onEvent,
  ) {
    final run = _SearchRun(keyword, onEvent);
    runs.add(run);
    return run.completion.future;
  }
}

SearchStreamEvent _hit(String title, String nativeId) => SearchStreamEvent(
  kind: SearchEventKind.hit,
  provider: 'other-provider',
  providerName: '其他来源',
  items: [MediaItem(id: 'other-provider:$nativeId', title: title)],
);

Future<void> _open(
  WidgetTester tester,
  _ControlledSearch search,
  List<SwitchPick?> picks,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  debugSetSwitchSearchRunner(search.call);
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox.shrink());
    for (final run in search.runs) {
      run.finish();
    }
    await tester.pump();
    debugSetSwitchSearchRunner(null);
  });
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(
        body: Builder(
          builder: (context) => ui.TextButton(
            onPressed: () async {
              picks.add(
                await showSourceSwitchDialog(
                  context,
                  title: '原始作品',
                  currentProvider: 'current-provider',
                  currentProviderName: '当前来源',
                  episodeIndex: 3,
                  position: 95,
                ),
              );
            },
            child: const Text('打开换源'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开换源'));
  await tester.pump();
  await tester.pump(Motion.base);
  await tester.pump();
  expect(search.runs, hasLength(1));
  expect(search.runs.single.keyword, '原始作品');
  expect(find.textContaining('搜索中…'), findsOneWidget);
}

Future<void> _submitNewQuery(
  WidgetTester tester,
  _ControlledSearch search,
) async {
  final editor = find.byType(EditableText);
  expect(editor, findsOneWidget);
  await tester.enterText(editor, '第二次查询');
  await tester.testTextInput.receiveAction(TextInputAction.search);
  await tester.pump();
  expect(search.runs, hasLength(2));
  expect(search.runs.last.keyword, '第二次查询');
  expect(find.textContaining('搜索中…'), findsOneWidget);
}

void main() {
  testWidgets('new query rejects earlier source-search hits and misses', (
    tester,
  ) async {
    final search = _ControlledSearch();
    final picks = <SwitchPick?>[];
    await _open(tester, search, picks);
    await _submitNewQuery(tester, search);
    expect(search.runs.last.onEvent(_hit('新查询结果', 'new')), isTrue);
    final oldHitAccepted = search.runs.first.onEvent(_hit('旧查询结果', 'old'));
    final oldMissAccepted = search.runs.first.onEvent(
      const SearchStreamEvent(
        kind: SearchEventKind.miss,
        provider: 'expired-provider',
        reason: 'Earlier request failed',
      ),
    );
    await tester.pump();
    expect(find.text('新查询结果'), findsOneWidget);
    expect(find.text('旧查询结果'), findsNothing);
    expect(find.textContaining('expired-provider'), findsNothing);
    expect(oldHitAccepted, isFalse);
    expect(oldMissAccepted, isFalse);
    expect(picks, isEmpty);
    expect(tester.takeException(), isNull);
  });

  for (final error in [false, true]) {
    testWidgets(
      'earlier source-search ${error ? 'error' : 'completion'} keeps the new query pending',
      (tester) async {
        final search = _ControlledSearch();
        final picks = <SwitchPick?>[];
        await _open(tester, search, picks);
        await _submitNewQuery(tester, search);
        search.runs.first.finish(error: error);
        await tester.pump();
        expect(
          find.textContaining('搜索中…'),
          findsOneWidget,
          reason: 'Only the active query may finish the visible progress state.',
        );
        final retry = tester.widget<ui.FilledButton>(
          find.ancestor(
            of: find.text('重搜'),
            matching: find.byType(ui.FilledButton),
          ),
        );
        expect(retry.onPressed, isNull);
        expect(search.runs.last.onEvent(_hit('新查询结果', 'new')), isTrue);
        search.runs.last.finish();
        await tester.pump();
        expect(find.text('新查询结果'), findsOneWidget);
        expect(find.textContaining('搜索中…'), findsNothing);
        expect(picks, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('current source-search result returns its identity and resume data', (
    tester,
  ) async {
    final search = _ControlledSearch();
    final picks = <SwitchPick?>[];
    await _open(tester, search, picks);
    expect(search.runs.single.onEvent(_hit('当前有效结果', 'valid')), isTrue);
    search.runs.single.finish();
    await tester.pump();
    expect(find.text('当前有效结果'), findsOneWidget);
    await tester.tap(find.text('当前有效结果'));
    // This run has completed, so no progress ticker can keep the real dialog
    // exit unsettled. Observe its removal after the route finishes animating.
    await tester.pumpAndSettle();
    expect(picks, hasLength(1));
    final pick = picks.single!;
    expect(pick.provider, 'other-provider');
    expect(pick.id, 'valid');
    expect(pick.title, '当前有效结果');
    expect(pick.episodeIndex, 3);
    expect(pick.position, 95);
    expect(find.text('当前有效结果'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
