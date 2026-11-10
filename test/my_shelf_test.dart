import 'support/miuix_finders.dart';

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

const _following = <Favorite>[
  Favorite(
    key: 'fixture:follow',
    provider: 'fixture',
    nativeId: 'follow',
    title: '追更示例',
    following: true,
  ),
];
const _favorites = <Favorite>[
  Favorite(
    key: 'fixture:favorite',
    provider: 'fixture',
    nativeId: 'favorite',
    title: '收藏示例',
  ),
];
const _history = <Progress>[
  Progress(
    key: 'fixture:history:e2',
    provider: 'fixture',
    nativeId: 'history',
    title: '历史示例',
    episodeId: 'e2',
    episodeTitle: '第 2 集',
    position: 40,
    duration: 100,
  ),
];

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    debugShelfLoadOverride = () async => (_favorites, _following, _history);
  });
  tearDown(() {
    debugShelfLoadOverride = null;
    UiPrefs.debugResetForTest();
  });

  for (final brightness in Brightness.values) {
    for (final width in [360.0, 1280.0]) {
      testWidgets(
        'Miuix shelf tabs keep counts, callbacks and bounds at $brightness / $width',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 800);
          addTearDown(tester.view.reset);
          final details = <String>[];
          final allPages = <String>[];
          final key = GlobalKey<MyShelfState>();
          final theme = AppTheme.themeFor(brightness);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              builder: (_, child) => AppThemeHost(data: theme, child: child!),
              home: AppScaffold(
                child: SingleChildScrollView(
                  child: MyShelf(
                    key: key,
                    onOpenDetail: (provider, id) =>
                        details.add('$provider:$id'),
                    onSeeAll: allPages.add,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          key.currentState!.debugSetData(
            following: _following,
            favorites: _favorites,
            history: _history,
          );
          await tester.pump();
          final tabs = find.byType(miuix.MiuixGlassSegmentedTabRow);
          expect(tabs, findsOneWidget);
          expect(tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).tabs, [
            '追更 1',
            '收藏 1',
            '历史 1',
          ]);
          expect(find.text('我的'), findsNothing);
          expect(
            find.byKey(const ValueKey('shelf-current-count')),
            findsNothing,
          );
          final bounds = tester.getRect(tabs);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(width));
          expect(bounds.height, greaterThanOrEqualTo(40));
          expect(bounds.height, lessThanOrEqualTo(44));
          final hitTargets = find.descendant(
            of: tabs,
            matching: find.byType(FocusableActionDetector),
          );
          expect(hitTargets, findsNWidgets(3));
          for (var i = 0; i < 3; i++) {
            expect(
              tester.getSize(hitTargets.at(i)).height,
              greaterThanOrEqualTo(34),
            );
          }

          for (final (label, title, page, id, index) in [
            ('追更', '追更示例', 'following', 'follow', 0),
            ('收藏', '收藏示例', 'all', 'favorite', 1),
            ('历史', '历史示例', 'continue', 'history', 2),
          ]) {
            await tester.tap(find.text('$label 1'));
            await tester.pump();
            expect(
              tester
                  .widget<miuix.MiuixGlassSegmentedTabRow>(tabs)
                  .selectedIndex,
              index,
            );
            expect(find.text(title), findsOneWidget);
            await tester.tap(find.text(title));
            await tester.pump();
            expect(details.last, 'fixture:$id');
            await tester.tap(miuixTooltip('查看更多'));
            await tester.pump();
            expect(allPages.last, page);
          }
          final progress = find.byType(miuix.MiuixLinearProgressIndicator);
          expect(progress, findsOneWidget);
          expect(
            tester
                .widget<miuix.MiuixLinearProgressIndicator>(progress)
                .progress,
            .4,
          );

          await tester.tap(find.text('清空历史'));
          await tester.pump();
          expect(find.text('再点一次确认清空'), findsOneWidget);
          expect(find.text('历史示例'), findsOneWidget);

          Focus.of(tester.element(find.text('历史 1'))).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          expect(
            tester.widget<miuix.MiuixGlassSegmentedTabRow>(tabs).selectedIndex,
            1,
          );
          expect(find.text('收藏示例'), findsOneWidget);
          expect(
            Focus.of(tester.element(find.text('收藏 1'))).hasPrimaryFocus,
            isTrue,
          );
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 5));
        },
      );
    }
  }
}
