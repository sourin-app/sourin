import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/shell.dart' show kAppLocalizationsDelegates;
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

const _link = 'https://subscription-fixture.invalid/list.json';
const _empty = TvboxSourceInfo(id: 'fixture', name: 'Fixture', api: '');
const _previous = TvboxSourceInfo(
  id: 'fixture',
  name: 'Fixture',
  api: '',
  sourceUrl: _link,
  needsSource: false,
  lastUpdateAt: 1800000000,
  lastUpdateOk: false,
  lastUpdateError: '连接超时',
);

Widget _host(TvboxSourceInfo info, Future<void> Function(String, String) save) =>
    Localizations(
      locale: const Locale('zh', 'CN'),
      delegates: kAppLocalizationsDelegates,
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: mui.Material(
          child: Overlay(initialEntries: [
            OverlayEntry(
              builder: (_) => SingleChildScrollView(
                child: TvboxSourceManagePanel(
                  id: info.id,
                  name: info.name,
                  sourceUrl: info.sourceUrl,
                  info: info,
                  linkSaver: save,
                  probeRunner: (_) async => const TvboxUpdateCheck(),
                ),
              ),
            ),
          ]),
        ),
      ),
    );

Finder _key(String name) => find.byKey(ValueKey<String>('tvbox-manage-$name'));
String _status(WidgetTester tester) =>
    tester.widget<Text>(_key('last-update')).data!;

void main() {
  testWidgets('saved link removes the stale missing-source status', (t) async {
    final saved = <String>[];
    await t.pumpWidget(_host(_empty, (_, url) async => saved.add(url)));
    await t.enterText(_key('link-input'), _link);
    await t.tap(_key('link-save'));
    await t.pumpAndSettle();
    expect(saved, [_link]);
    expect(_status(t), '从未更新', reason: 'Saved link status must refresh.');
  });

  testWidgets('cleared link replaces the previous update status', (t) async {
    final saved = <String>[];
    await t.pumpWidget(_host(_previous, (_, url) async => saved.add(url)));
    await t.tap(_key('link-clear'));
    await t.pumpAndSettle();
    expect(saved, ['']);
    expect(_status(t), tvboxNoSourceHint,
        reason: 'Cleared link status must refresh.');
    final line = t.widget<Text>(_key('last-update'));
    final colors = mui.Theme.of(t.element(_key('last-update'))).colorScheme;
    expect(line.style!.color, colors.onSurfaceVariant);
    final tooltip = t.widget<mui.Tooltip>(find.ancestor(
      of: _key('last-update'),
      matching: find.byType(mui.Tooltip),
    ));
    expect(tooltip.message, contains('没有记录订阅来源'));
    expect(tooltip.message, isNot(contains('连接超时')));
  });

  testWidgets('unsaved input keeps the confirmed missing-source status',
      (t) async {
    await t.pumpWidget(_host(_empty, (_, _) async {}));
    await t.enterText(_key('link-input'), _link);
    await t.pump();
    expect(_status(t), tvboxNoSourceHint);
  });

  testWidgets('save failure keeps the confirmed missing-source status',
      (t) async {
    await t.pumpWidget(_host(_empty, (_, _) async {
      throw StateError('synthetic-save-failure');
    }));
    await t.enterText(_key('link-input'), _link);
    await t.tap(_key('link-save'));
    await t.pumpAndSettle();
    expect(_status(t), tvboxNoSourceHint);
    expect(_key('error'), findsOneWidget);
  });

  testWidgets('clear failure keeps the prior update timestamp', (t) async {
    await t.pumpWidget(_host(_previous, (_, _) async {
      throw StateError('synthetic-clear-failure');
    }));
    final previous = _status(t);
    await t.tap(_key('link-clear'));
    await t.pumpAndSettle();
    expect(_status(t), previous);
    expect(_key('error'), findsOneWidget);
  });

  testWidgets('changing a saved link preserves real update metadata', (t) async {
    await t.pumpWidget(_host(_previous, (_, _) async {}));
    final previous = _status(t);
    await t.enterText(_key('link-input'), 'https://subscription-fixture.invalid/new');
    await t.tap(_key('link-save'));
    await t.pumpAndSettle();
    expect(_status(t), previous);
  });
}
