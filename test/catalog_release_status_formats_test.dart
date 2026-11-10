// Feed normal search result events, then inspect the actual production card.
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

Future<void> _mountResult(WidgetTester tester, String note) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(720, 900);
  addTearDown(tester.view.reset);
  final previous = SourinCore.debugCallAsyncTransport;
  SourinCore.debugCallAsyncTransport = (command, _) async => switch (command) {
    'list_providers' => <dynamic>[
      {'id': 'fixture', 'name': '测试来源', 'kind': 'tvbox', 'enabled': true},
    ],
    'tvbox_agg_channels' => {'ok': true, 'channels': <dynamic>[]},
    _ => throw UnsupportedError('Unexpected search command: $command'),
  };
  addTearDown(() => SourinCore.debugCallAsyncTransport = previous);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: const Scaffold(body: SearchPage()),
    ),
  );
  await tester.pump();
  final state = tester.state<SearchPageState>(find.byType(SearchPage));
  state.debugSetProviderCount(1);
  state.debugBeginSearch('进度样本');
  state.debugFeedHit(
    SearchStreamEvent(
      kind: SearchEventKind.hit,
      provider: 'fixture',
      providerName: '测试来源',
      items: [MediaItem(id: 'work', title: '来源进度样本', note: note)],
    ),
  );
  state.debugEndSearch();
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
}

void main() {
  const recognized = <(String, String)>[
    ('更新至13/30集，平台VIP更新说明', '更新至13/30集'),
    ('更新至16集/全24集', '更新至16/24集'),
    ('全剧集', '已完结'),
  ];
  for (final (note, expected) in recognized) {
    testWidgets('catalog status appears on the actual cover for $note', (
      tester,
    ) async {
      await _mountResult(tester, note);
      final card = find.byType(PosterCard);
      expect(card, findsOneWidget);
      expect(tester.widget<PosterCard>(card).releaseStatus, expected);
      expect(tester.widget<PosterCard>(card).subtitle, isNull);
      final badge = find.descendant(
        of: card,
        matching: find.byKey(const ValueKey('poster-release-status')),
      );
      expect(badge, findsOneWidget);
      expect(tester.widget(badge), isA<miuix.MiuixBadge>());
      expect(
        find.descendant(of: badge, matching: find.text(expected)),
        findsOneWidget,
      );
      final poster = tester.getRect(
        find.descendant(of: card, matching: find.byType(AspectRatio)),
      );
      final badgeBounds = tester.getRect(badge);
      expect(badgeBounds.left, greaterThanOrEqualTo(poster.left));
      expect(badgeBounds.right, lessThanOrEqualTo(poster.right));
      expect(badgeBounds.top, greaterThanOrEqualTo(poster.top));
      expect(badgeBounds.bottom, lessThan(poster.bottom));
      expect(find.text(note), note == expected ? findsOneWidget : findsNothing);
      if (note.startsWith('更新至')) {
        expect(find.textContaining('已完结'), findsNothing);
      } else {
        expect(find.textContaining('全0集'), findsNothing);
        expect(find.textContaining('全1集'), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }

  const unrecognized = <String>[
    '更新至31/30集',
    '更新至0/30集',
    '更新至13/0集',
    '更新至16集/全24集特别篇',
    '说明：更新至13/30集',
    '共30集',
    '全剧集抢先看',
    '未完结，全剧集',
    '已完结,全26话特别篇',
    '第2集 · 剩余5分钟',
    '02',
  ];
  for (final note in unrecognized) {
    testWidgets('catalog keeps ambiguous metadata as a subtitle for $note', (
      tester,
    ) async {
      await _mountResult(tester, note);
      final card = find.byType(PosterCard);
      expect(card, findsOneWidget);
      expect(tester.widget<PosterCard>(card).releaseStatus, isNull);
      expect(tester.widget<PosterCard>(card).subtitle, note);
      expect(
        find.descendant(
          of: card,
          matching: find.byKey(const ValueKey('poster-release-status')),
        ),
        findsNothing,
      );
      expect(find.text(note), findsOneWidget);
      expect(tester.takeException(), isNull);
      await _unmount(tester);
    });
  }
}
