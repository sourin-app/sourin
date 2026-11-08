import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart';

import 'support/miuix_dialog_host.dart';

const _providers = [
  ProviderManifest(id: 'hidden', name: 'Hidden', kind: 'tvbox', hidden: true),
  ProviderManifest(id: 'a', name: 'Alpha', kind: 'js'),
  ProviderManifest(id: 'off', name: 'Beta', kind: 'js', enabled: false),
  ProviderManifest(id: 'tvbox_agg', name: 'Aggregate', kind: 'tvbox'),
  ProviderManifest(id: 'b', name: 'Another Alpha', kind: 'js'),
];

const _sites = [
  TvboxAggregateSite(
    id: 'outside',
    name: 'Outside',
    implemented: true,
    enabled: true,
  ),
  TvboxAggregateSite(
    id: 'one',
    name: 'Matching One',
    implemented: true,
    enabled: true,
  ),
  TvboxAggregateSite(id: 'two', name: 'Matching Two', implemented: true),
  TvboxAggregateSite(
    id: 'unsupported',
    name: 'Matching Unsupported',
    reason: 'Not implemented',
  ),
];

void main() {
  test(
    'source filters preserve hidden semantics, order and source identity',
    () {
      expect(filterManagedSources(_providers).map((p) => p.id), [
        'a',
        'off',
        'tvbox_agg',
        'b',
      ]);
      expect(filterManagedSources(_providers, query: ' HIDDEN '), isEmpty);
      expect(
        filterManagedSources(_providers, query: 'ALPHA').map((p) => p.id),
        ['a', 'b'],
      );
      expect(filterManagedSources(_providers, enabled: false).single.id, 'off');
      expect(
        filterManagedSources(
          _providers,
          sourceClass: SourceClass.tvboxAggregate,
        ).single.id,
        'tvbox_agg',
      );
      final subset = filterManagedSources(_providers, query: 'Alpha');
      expect(
        SettingsPageState.reorderSubsetIds(
          allIds: _providers.map((p) => p.id).toList(),
          subsetIds: subset.map((p) => p.id).toList(),
          oldIndex: 0,
          newIndex: 1,
        ),
        ['hidden', 'off', 'tvbox_agg', 'b', 'a'],
      );
    },
  );

  test('bulk actions only mutate visible implemented sites', () {
    final selected = {'outside', 'one'};
    final visible = filterManagedSites(
      _sites,
      selected: selected,
      query: 'Matching',
    );
    expect(visible.map((s) => s.id), ['one', 'two', 'unsupported']);
    expect(selectionForVisibleSites(selected, visible, true), {
      'outside',
      'one',
      'two',
    });
    expect(selectionForVisibleSites(selected, visible, false), {'outside'});
    expect(selected, {
      'outside',
      'one',
    }, reason: 'helpers must not mutate caller state');
    expect(
      filterManagedSites(
        _sites,
        selected: selected,
        enabled: true,
      ).map((s) => s.id),
      ['outside', 'one'],
    );
  });

  testWidgets('aggregate search and bulk controls retain offscreen selection', (
    tester,
  ) async {
    await pumpMiuixDialog(
      tester,
      TvboxAggregateSitesDialog(
        aggregate: const TvboxAggregate(sites: _sites),
        sourceOf: (_) => null,
        panelBuilder: (_, __, ___) => const SizedBox.shrink(),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('agg-sites-search')),
      'Matching',
    );
    await tester.pump();
    await tester.tap(
      find.byKey(const ValueKey<String>('agg-sites-clear-visible')),
    );
    await tester.pump();
    await tester.enterText(
      find.byKey(const ValueKey<String>('agg-sites-search')),
      '',
    );
    await tester.pump();
    expect(
      tester
          .widget<ui.Checkbox>(
            find.byKey(const ValueKey<String>('agg-site-check-outside')),
          )
          .value,
      isTrue,
    );
    expect(
      tester
          .widget<ui.Checkbox>(
            find.byKey(const ValueKey<String>('agg-site-check-one')),
          )
          .value,
      isFalse,
    );
    expect(
      tester
          .widget<ui.Checkbox>(
            find.byKey(const ValueKey<String>('agg-site-check-unsupported')),
          )
          .onChanged,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('source toolbar remains usable at mobile width', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var query = '';
    await tester.pumpWidget(
      MaterialApp(
        home: Material(
          child: Align(
            alignment: Alignment.topLeft,
            child: SourceManagerToolbar(
              query: '',
              enabled: null,
              sourceClass: null,
              resultCount: 2,
              totalCount: 4,
              onQuery: (value) => query = value,
              onEnabled: (_) {},
              onClass: (_) {},
            ),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey<String>('source-manager-search')),
      'Alpha',
    );
    expect(query, 'Alpha');
    expect(tester.takeException(), isNull);
  });
}
