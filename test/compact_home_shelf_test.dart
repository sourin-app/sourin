import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/compact_shelf_card.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets(
      'compact shelf at $width keeps details and first screen height',
      (t) async {
        UiPrefs.debugResetForTest();
        debugShelfLoadOverride = () async =>
            (<Favorite>[], <Favorite>[], <Progress>[]);
        addTearDown(() {
          debugShelfLoadOverride = null;
          UiPrefs.debugResetForTest();
        });
        t.view.devicePixelRatio = 1;
        t.view.physicalSize = Size(width, 800);
        addTearDown(t.view.reset);
        final selected = <String>[];
        final key = GlobalKey<MyShelfState>();
        final theme = AppTheme.themeFor(Brightness.light);
        await t.pumpWidget(
          MaterialApp(
            theme: theme,
            builder: (_, child) => AppThemeHost(data: theme, child: child!),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MyShelf(
                  key: key,
                  compact: true,
                  onOpenDetail: (p, id) => selected.add('$p:$id'),
                ),
              ),
            ),
          ),
        );
        await t.pump();
        key.currentState!.debugSetData(
          following: const [
            Favorite(
              key: 'fixture:work',
              provider: 'fixture',
              nativeId: 'work',
              title: 'Example series',
              following: true,
              lastEpisodeTitle: '第 8 集',
            ),
          ],
          remaining: {'fixture:work': 3},
        );
        await t.pump();
        expect(find.byType(CompactShelfCard), findsOneWidget);
        expect(t.getSize(find.byType(CompactShelfCard)).height, lessThan(150));
        expect(t.getSize(find.byType(MyShelf)).height, lessThan(260));
        expect(find.text('第 8 集'), findsOneWidget);
        expect(
          t.widget<PosterCard>(find.byType(PosterCard)).showCaption,
          isFalse,
        );
        await t.tap(find.text('Example series'));
        await t.pump();
        expect(selected, ['fixture:work']);
        expect(t.takeException(), isNull);
        await t.pumpWidget(const SizedBox());
        await t.pump(const Duration(seconds: 5));
      },
    );
  }
  testWidgets('large text and progress fit inside a compact card', (t) async {
    final theme = AppTheme.themeFor(Brightness.dark);
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.6)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => SizedBox(
              width: 312,
              height: CompactShelfCard.heightOf(context),
              child: CompactShelfCard(
                title: 'A long title across two lines',
                subtitle: '第 20 集',
                percent: 42,
                unread: 3,
                onTap: () {},
              ),
            ),
          ),
        ),
      ),
    );
    expect(t.getSize(find.byType(PosterCard)).height, greaterThanOrEqualTo(96));
    expect(
      t
          .widget<miuix.MiuixLinearProgressIndicator>(
            find.byType(miuix.MiuixLinearProgressIndicator),
          )
          .progress,
      .42,
    );
    expect(t.takeException(), isNull);
  });

  testWidgets('small system text preserves the whole poster and its inset', (
    t,
  ) async {
    final theme = AppTheme.themeFor(Brightness.light);
    var opened = 0;
    await t.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(0.8)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: 312,
                height: CompactShelfCard.heightOf(context),
                child: CompactShelfCard(
                  title: 'Small text keeps the full cover',
                  subtitle: '第 20 集',
                  percent: 42,
                  onTap: () => opened++,
                ),
              ),
            ),
          ),
        ),
      ),
    );
    final card = t.getRect(find.byType(CompactShelfCard));
    final poster = t.getRect(find.byType(PosterCard));
    expect(poster.height, greaterThanOrEqualTo(96));
    expect(poster.top - card.top, greaterThanOrEqualTo(12));
    expect(card.bottom - poster.bottom, greaterThanOrEqualTo(12));
    await t.tap(find.text('Small text keeps the full cover'));
    await t.pump();
    expect(opened, 1);
    expect(t.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('compact card has a visible Miuix surface in $brightness', (
      t,
    ) async {
      final theme = AppTheme.themeFor(brightness);
      await t.pumpWidget(
        MaterialApp(
          theme: theme,
          home: Scaffold(
            body: SizedBox(
              width: 312,
              height: 120,
              child: CompactShelfCard(title: 'Library item', onTap: () {}),
            ),
          ),
        ),
      );
      expect(find.byType(miuix.MiuixCard), findsOneWidget);
      final surface = t.widget<DecoratedBox>(
        find
            .descendant(
              of: find.byType(CompactShelfCard),
              matching: find.byWidgetPredicate(
                (widget) =>
                    widget is DecoratedBox &&
                    widget.decoration is ShapeDecoration,
              ),
            )
            .first,
      );
      final color = (surface.decoration as ShapeDecoration).color;
      expect(color, theme.colorScheme.surfaceContainer);
      expect(color, isNot(theme.scaffoldBackgroundColor));
      expect(t.takeException(), isNull);
    });
  }
}
