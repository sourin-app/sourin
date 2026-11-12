import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/sourin_api.dart'
    show SourinApi, TvboxUpdateSchedule;
import 'package:sourin_spike/shell.dart' show kAppLocalizationsDelegates;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart' show TvboxAutoUpdateRow;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

class _Write {
  _Write(this.enabled, this.intervalSecs);
  final bool enabled;
  final int intervalSecs;
  final result = Completer<TvboxUpdateSchedule>();
}

class _Fixture {
  final writes = <_Write>[];
  TvboxUpdateSchedule persisted =
      const TvboxUpdateSchedule(enabled: true, intervalSecs: 21600);

  Future<TvboxUpdateSchedule> read() async => persisted;

  Future<TvboxUpdateSchedule> write(bool enabled, int intervalSecs) {
    final request = _Write(enabled, intervalSecs);
    writes.add(request);
    return request.result.future;
  }

  void succeed(int index) {
    final request = writes[index];
    persisted = TvboxUpdateSchedule(
      enabled: request.enabled,
      intervalSecs: request.intervalSecs,
    );
    request.result.complete(persisted);
  }

  void drain() {
    for (final request in writes) {
      if (!request.result.isCompleted) {
        request.result.complete(TvboxUpdateSchedule(
          enabled: request.enabled,
          intervalSecs: request.intervalSecs,
        ));
      }
    }
  }
}

Finder _interval(int seconds) => find.byKey(
  ValueKey<String>('tvbox-auto-update-interval-$seconds'),
);

Widget _host() {
  final theme = AppTheme.themeFor(Brightness.light);
  return mui.MaterialApp(
    theme: theme,
    localizationsDelegates: kAppLocalizationsDelegates,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: const mui.Scaffold(
      body: SingleChildScrollView(child: TvboxAutoUpdateRow()),
    ),
  );
}

Future<void> _mount(WidgetTester tester, _Fixture fixture) async {
  await tester.binding.setSurfaceSize(const Size(1280, 720));
  SourinApi.debugTvboxScheduleFetcher = fixture.read;
  SourinApi.debugTvboxScheduleSetter = fixture.write;
  await tester.pumpWidget(_host());
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  expect(find.byType(TvboxAutoUpdateRow), findsOneWidget);
  expect(_interval(43200).hitTestable(), findsOneWidget);
  expect(_interval(86400).hitTestable(), findsOneWidget);
}

Future<void> _finish(WidgetTester tester, _Fixture fixture) async {
  fixture.drain();
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  SourinApi.debugTvboxScheduleFetcher = null;
  SourinApi.debugTvboxScheduleSetter = null;
  await tester.binding.setSurfaceSize(null);
}

void main() {
  tearDown(() {
    SourinApi.debugTvboxScheduleFetcher = null;
    SourinApi.debugTvboxScheduleSetter = null;
  });

  testWidgets('two actual interval taps before the next frame start one save', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await _mount(tester, fixture);
      final originalState = tester.state(find.byType(TvboxAutoUpdateRow));
      await tester.tap(_interval(43200).hitTestable());
      // Intentionally no pump or remount between the two public pointer taps.
      // The second rendered control still carries its previously enabled callback.
      await tester.tap(_interval(86400).hitTestable());
      await tester.pump();
      expect(fixture.writes.map((request) => request.intervalSecs).toList(),
          [43200], reason: 'The existing busy UI promises one outstanding save.');
      expect(identical(tester.state(find.byType(TvboxAutoUpdateRow)), originalState),
          isTrue, reason: 'Both taps must target the same original mounted State.');
      fixture.succeed(0);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<ui.ChoiceChip>(_interval(43200)).selected, isTrue);
      expect(fixture.persisted.intervalSecs, 43200);
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, fixture);
    }
  });

  testWidgets('a rejected save shows the error and permits a subsequent retry', (
    tester,
  ) async {
    final fixture = _Fixture();
    try {
      await _mount(tester, fixture);
      await tester.tap(_interval(43200).hitTestable());
      await tester.pump();
      expect(fixture.writes, hasLength(1));
      fixture.writes.single.result.completeError(Exception('schedule save rejected'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey<String>('tvbox-auto-update-error')), findsOneWidget);
      expect(tester.widget<ui.ChoiceChip>(_interval(21600)).selected, isTrue,
          reason: 'Rejected preference must not look persisted.');
      await tester.tap(_interval(86400).hitTestable());
      await tester.pump();
      expect(fixture.writes.map((request) => request.intervalSecs).toList(), [43200, 86400]);
      expect(find.byKey(const ValueKey<String>('tvbox-auto-update-error')), findsNothing);
      fixture.succeed(1);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.widget<ui.ChoiceChip>(_interval(86400)).selected, isTrue);
      expect(fixture.persisted.intervalSecs, 86400);
      expect(tester.takeException(), isNull);
    } finally {
      await _finish(tester, fixture);
    }
  });
}
