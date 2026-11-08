import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

const _listKey = ValueKey('refresh-scrollable');

Widget _host(Future<void> Function() refresh) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(
      body: ui.RefreshIndicator(
        onRefresh: refresh,
        child: ListView.builder(
          key: _listKey,
          physics: const AlwaysScrollableScrollPhysics(
            parent: ClampingScrollPhysics(),
          ),
          itemExtent: 48,
          itemCount: 24,
          itemBuilder: (_, index) => Text('第 $index 项'),
        ),
      ),
    ),
  );
}

Future<void> _waitForRefreshState(
  WidgetTester tester, {
  required bool refreshing,
}) async {
  // Wait for the observable state. The package awaits a critically damped
  // release spring before dispatch, while an active request keeps ticking.
  for (var frame = 1; frame <= 60; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    final actual = tester.widget<miuix.MiuixPullToRefresh>(
      find.byType(miuix.MiuixPullToRefresh),
    );
    final indicatorIdle = actual.refreshTexts.every(
      (text) => find.text(text).evaluate().isEmpty,
    );
    if (actual.isRefreshing == refreshing && (refreshing || indicatorIdle)) {
      return;
    }
  }
  fail('Miuix did not reach refreshing=$refreshing within 3 seconds.');
}

Future<void> _pull(WidgetTester tester) async {
  final rect = tester.getRect(find.byKey(_listKey));
  final start = Offset(rect.center.dx, rect.top + 80);
  final gesture = await tester.startGesture(start);
  for (var step = 1; step <= 8; step++) {
    await gesture.moveTo(
      start + Offset(0, step * 40),
      timeStamp: Duration(milliseconds: step * 80),
    );
    await tester.pump(const Duration(milliseconds: 80));
  }
  final refresh = tester.widget<miuix.MiuixPullToRefresh>(
    find.byType(miuix.MiuixPullToRefresh),
  );
  if (!refresh.isRefreshing) {
    expect(
      find.text(refresh.refreshTexts[1]),
      findsOneWidget,
      reason: 'Real overscroll must arm the Miuix release threshold.',
    );
  }
  // Hold the final position before releasing: this is a pull, not a fling.
  await gesture.moveTo(
    start + const Offset(0, 320),
    timeStamp: const Duration(milliseconds: 900),
  );
  await tester.pump(const Duration(milliseconds: 260));
  await gesture.up(timeStamp: const Duration(milliseconds: 1000));
  await _waitForRefreshState(tester, refreshing: true);
}

void main() {
  testWidgets('real pull waits for one request and can refresh again', (
    tester,
  ) async {
    final requests = <Completer<void>>[];
    await tester.pumpWidget(
      _host(() {
        final request = Completer<void>();
        requests.add(request);
        return request.future;
      }),
    );
    await tester.pumpAndSettle();

    final refresh = find.byType(miuix.MiuixPullToRefresh);
    expect(refresh, findsOneWidget);
    expect(find.byType(RefreshIndicator), findsNothing);
    expect(
      tester.widget<miuix.MiuixPullToRefresh>(refresh).isRefreshing,
      isFalse,
    );

    await _pull(tester);
    expect(requests, hasLength(1));
    expect(
      tester.widget<miuix.MiuixPullToRefresh>(refresh).isRefreshing,
      isTrue,
    );
    final progressText = tester
        .widget<miuix.MiuixPullToRefresh>(refresh)
        .refreshTexts[2];
    expect(progressText, matches(RegExp(r'[\u4e00-\u9fff]')));
    expect(find.text(progressText), findsOneWidget);

    await _pull(tester);
    expect(requests, hasLength(1), reason: 'Pending refresh must not reenter.');
    requests.single.complete();
    await _waitForRefreshState(tester, refreshing: false);
    expect(
      tester.widget<miuix.MiuixPullToRefresh>(refresh).isRefreshing,
      isFalse,
    );
    expect(find.text(progressText), findsNothing);

    await _pull(tester);
    expect(requests, hasLength(2));
    requests.last.complete();
    await _waitForRefreshState(tester, refreshing: false);
    expect(
      tester.widget<miuix.MiuixPullToRefresh>(refresh).isRefreshing,
      isFalse,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('pending refresh may complete after its page is removed', (
    tester,
  ) async {
    final pending = Completer<void>();
    var calls = 0;
    await tester.pumpWidget(
      _host(() {
        calls++;
        return pending.future;
      }),
    );
    await tester.pumpAndSettle();
    await _pull(tester);
    expect(calls, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete();
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
