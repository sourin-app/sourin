// PosterCard interaction, badge readability and compact overlay regression.
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

Widget host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(
      backgroundColor: AppTheme.floorColor(Brightness.dark),
      body: Center(child: SizedBox(width: 168, child: child)),
    ),
  );
}

void main() {
  group('PosterCard badges and interaction', () {
    testWidgets('card still activates once', (t) async {
      var tapped = 0;
      await t.pumpWidget(
        host(
          PosterCard(title: '样本标题', subtitle: '更新至 1 集', onTap: () => tapped++),
        ),
      );
      await t.pump();
      await t.tap(find.byType(PosterCard));
      await t.pump();
      expect(tapped, 1);
    });

    testWidgets('unread count retains an opaque red badge and white text', (
      t,
    ) async {
      await t.pumpWidget(
        host(const PosterCard(title: '样本标题', unread: 7, onTap: _noop)),
      );
      await t.pump();

      expect(find.text('7'), findsOneWidget);
      final badge = t.widget<miuix.MiuixBadge>(
        find.ancestor(
          of: find.text('7'),
          matching: find.byType(miuix.MiuixBadge),
        ),
      );
      expect(badge.containerColor, AppColors.badge);
      expect(badge.contentColor, Colors.white);
      expect(t.widget<Text>(find.text('7')).style!.color, Colors.white);
    });

    testWidgets('long badge stays inside the poster without covering unread', (
      t,
    ) async {
      const label = '9.2 分 · 高清修复加长版';
      await t.pumpWidget(
        host(
          const PosterCard(
            title: '样本标题',
            badge: label,
            unread: 7,
            onTap: _noop,
          ),
        ),
      );
      await t.pump();

      expect(find.text(label), findsOneWidget);
      final text = t.widget<Text>(find.text(label));
      expect(text.maxLines, 1);
      expect(text.overflow, TextOverflow.ellipsis);
      final badge = find.ancestor(
        of: find.text(label),
        matching: find.byType(miuix.MiuixBadge),
      );
      final unread = find.ancestor(
        of: find.text('7'),
        matching: find.byType(miuix.MiuixBadge),
      );
      final poster = t.getRect(find.byType(AspectRatio));
      final badgeRect = t.getRect(badge);
      expect(badgeRect.left, greaterThanOrEqualTo(t.getRect(unread).right));
      expect(badgeRect.right, lessThanOrEqualTo(poster.right));
      expect(badgeRect.top, greaterThanOrEqualTo(poster.top));
      expect(badgeRect.bottom, lessThan(poster.bottom));
      expect(t.takeException(), isNull);
    });

    testWidgets('no badges when there is no label or unread count', (t) async {
      await t.pumpWidget(host(const PosterCard(title: '样本标题', onTap: _noop)));
      await t.pump();
      expect(find.byType(miuix.MiuixBadge), findsNothing);
    });

    testWidgets('badges do not change card geometry', (t) async {
      await t.pumpWidget(
        host(
          const PosterCard(
            title: '样本标题',
            subtitle: '更新至 1 集',
            titleLines: 2,
            badge: 'HD',
            unread: 7,
            onTap: _noop,
          ),
        ),
      );
      await t.pump();
      final withChips = t.getRect(find.byType(PosterCard));

      await t.pumpWidget(
        host(
          const PosterCard(
            title: '样本标题',
            subtitle: '更新至 1 集',
            titleLines: 2,
            onTap: _noop,
          ),
        ),
      );
      await t.pump();
      final withoutChips = t.getRect(find.byType(PosterCard));
      expect(withChips.size, withoutChips.size);
    });
  });
}

void _noop() {}
