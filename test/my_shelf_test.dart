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
          final tabs = find.byType(miuix.MiuixTabRow);
          expect(tabs, findsOneWidget);
          expect(tester.widget<miuix.MiuixTabRow>(tabs).tabs, [
            '最近追更 1',
            '最近收藏 1',
            '播放历史 1',
          ]);
          final bounds = tester.getRect(tabs);
          expect(bounds.left, greaterThanOrEqualTo(0));
          expect(bounds.right, lessThanOrEqualTo(width));
          expect(bounds.height, greaterThanOrEqualTo(44));

          for (final (label, title, page, id, index) in [
            ('最近追更 1', '追更示例', 'following', 'follow', 0),
            ('最近收藏 1', '收藏示例', 'all', 'favorite', 1),
            ('播放历史 1', '历史示例', 'continue', 'history', 2),
          ]) {
            await tester.tap(find.text(label));
            await tester.pump();
            expect(
              tester.widget<miuix.MiuixTabRow>(tabs).selectedTabIndex,
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

          Focus.of(tester.element(tabs)).requestFocus();
          await tester.pump();
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          expect(tester.widget<miuix.MiuixTabRow>(tabs).selectedTabIndex, 1);
          expect(find.text('收藏示例'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(const Duration(seconds: 5));
        },
      );
    }
  }
}
