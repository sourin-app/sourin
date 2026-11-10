import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/search_page.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

Widget _host(Widget child, Brightness brightness, {double scale = 1}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
    ),
    home: Scaffold(body: child),
  );
}

void main() {
  test(
    'release state accepts source episode metadata, not ratings or progress',
    () {
      expect(PosterCard.releaseStatusFor(note: '全 24 集'), '已完结·全24集');
      expect(PosterCard.releaseStatusFor(note: '更新至第１２集'), '更新至12集');
      expect(PosterCard.releaseStatusFor(note: '第24集（完结）'), '已完结·全24集');
      for (final note in ['9.2', 'HD', '未完结', '我的备注：已完结', '第 2 集 · 剩余 5 分钟']) {
        expect(PosterCard.releaseStatusFor(note: note), isNull, reason: note);
      }
    },
  );

  for (final brightness in Brightness.values) {
    for (final scale in [1.0, 1.6]) {
      testWidgets(
        'poster separates release and viewing state at $brightness / $scale',
        (tester) async {
          await tester.pumpWidget(
            _host(
              Builder(
                builder: (context) => Align(
                  alignment: Alignment.topLeft,
                  child: SizedBox(
                    width: 116,
                    height: PosterCard.heightOf(
                      context,
                      width: 116,
                      hasSubtitle: true,
                    ),
                    child: const PosterCard(
                      width: 116,
                      title: '这是一部标题很长的剧集名称',
                      releaseStatus: '已完结·全240集',
                      subtitle: '第 2 集 · 剩余 5 分钟',
                      badge: '9.2',
                      unread: 7,
                    ),
                  ),
                ),
              ),
              brightness,
              scale: scale,
            ),
          );
          final title = find.text('这是一部标题很长的剧集名称');
          expect(tester.widget<Text>(title).maxLines, 1);
          final poster = tester.getRect(find.byType(AspectRatio));
          final status = tester.getRect(
            find.byKey(const ValueKey('poster-release-status')),
          );
          final unread = tester.getRect(
            find.ancestor(
              of: find.text('7'),
              matching: find.byType(miuix.MiuixBadge),
            ),
          );
          final rating = tester.getRect(
            find.ancestor(
              of: find.text('9.2'),
              matching: find.byType(miuix.MiuixBadge),
            ),
          );
          expect(status.left, greaterThanOrEqualTo(poster.left));
          expect(status.right, lessThanOrEqualTo(poster.right));
          expect(status.bottom, lessThan(poster.bottom));
          expect(status.top, greaterThan(unread.bottom));
          expect(status.top, greaterThan(rating.bottom));
          expect(tester.getRect(title).top, greaterThan(poster.bottom));
          final subtitle = find.text('第 2 集 · 剩余 5 分钟');
          expect(subtitle, findsOneWidget);
          expect(
            tester.getRect(subtitle).bottom,
            lessThanOrEqualTo(tester.getRect(find.byType(PosterCard)).bottom),
          );
          expect(find.text('已完结·全240集'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }

    for (final width in [360.0, 1280.0]) {
      testWidgets(
        'search uses themed input, centered action and real categories at $brightness / $width',
        (tester) async {
          final previous = SourinCore.debugCallAsyncTransport;
          SourinCore.debugCallAsyncTransport = (command, _) async =>
              switch (command) {
                'list_providers' => <dynamic>[
                  for (final name in ['甲来源', '乙来源'])
                    {'id': name, 'name': name, 'kind': 'tvbox', 'enabled': true},
                ],
                'tvbox_agg_channels' => {'ok': true, 'channels': <dynamic>[]},
                _ => throw UnsupportedError(
                  'Unexpected search command: $command',
                ),
              };
          addTearDown(() => SourinCore.debugCallAsyncTransport = previous);
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.reset);
          await tester.pumpWidget(_host(const SearchPage(), brightness));
          await tester.pump();
          final state = tester.state<SearchPageState>(find.byType(SearchPage));
          state.debugSetProviderCount(2);
          state.debugBeginSearch('示例');
          for (final (provider, note) in [('甲来源', '全24集'), ('乙来源', 'HD')]) {
            state.debugFeedHit(
              SearchStreamEvent(
                kind: SearchEventKind.hit,
                provider: provider,
                providerName: provider,
                items: [
                  MediaItem(id: provider, title: '示例$provider', note: note),
                ],
              ),
            );
          }
          state.debugEndSearch();
          await tester.pumpAndSettle();
          final field = find.byType(miuix.MiuixTextField);
          expect(field, findsOneWidget);
          final colors = miuix.MiuixTheme.of(tester.element(field)).colors;
          expect(
            tester.widget<miuix.MiuixTextField>(field).colors!.backgroundColor,
            colors.surface,
          );
          final buttonFinder = find.ancestor(
            of: find.text('搜索'),
            matching: find.byType(miuix.MiuixButton),
          );
          expect(buttonFinder, findsOneWidget);
          final action = find.descendant(
            of: buttonFinder,
            matching: find.text('搜索'),
          );
          expect(
            tester.getCenter(action).dx,
            closeTo(tester.getCenter(buttonFinder).dx, .1),
          );
          expect(
            tester.getCenter(action).dy,
            closeTo(tester.getCenter(buttonFinder).dy, .1),
          );
          if (width < 720) {
            final tabs = find.byType(miuix.MiuixGlassSegmentedTabRow);
            expect(tabs, findsOneWidget);
            expect(tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).tabs, [
              '全部',
              '甲来源 1',
              '乙来源 1',
            ]);
          } else {
            final rail = find.byKey(const ValueKey('search-source-rail'));
            expect(
              find.descendant(
                of: rail,
                matching: find.byType(miuix.MiuixBasicComponent),
              ),
              findsNWidgets(3),
            );
          }
          final first = tester.widget<PosterCard>(
            find.byType(PosterCard).first,
          );
          expect(first.titleLines, 1);
          expect(first.releaseStatus, '已完结·全24集');
          expect(first.subtitle, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump();
        },
      );
    }
  }
}
