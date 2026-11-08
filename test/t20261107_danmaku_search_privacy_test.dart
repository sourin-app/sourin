import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

import 'support/miuix_dialog_host.dart';

const _match = DanmakuMatch(
  episodeId: 7,
  animeTitle: 'Fixture work',
  episodeTitle: 'Episode 1',
);

DanmakuException _failure(String channel) => DanmakuException(
  'Fixture $channel request refused; retry may succeed',
  statusCode: 403,
  uri:
      'https://fixture-user:fixture-password@media.example.invalid/'
      'fixture-$channel-private-path?token=fixture-$channel-query-secret',
  xErrorMessage: 'Authorization: Bearer fixture-$channel-bearer-secret',
  body:
      'Fixture $channel response explains refusal.\n'
      'Cookie: fixture-$channel-cookie-secret\n'
      'signature=fixture-$channel-body-secret; HTTP status=403',
);

DanmakuSettingsState _state({
  DanmakuException? searchError,
  DanmakuException? error,
}) => DanmakuSettingsState(
  enabled: true,
  appId: '',
  appSecret: '',
  fontScale: 1,
  opacity: 1,
  speed: 1,
  area: 1,
  searchKeyword: 'Fixture work',
  searchSearched: true,
  searchResults: const [_match],
  searchError: searchError,
  error: error,
);

Widget _host({
  required DanmakuSettingsState state,
  BiliImportState biliState = const BiliImportState(),
}) => DanmakuSearchPage(
  state: state,
  biliState: biliState,
  localTitles: const ['Episode 1'],
  onSearch: (_) => fail('Rendering must not dispatch a search.'),
  onBiliSearch: (_) => fail('Rendering must not dispatch a video search.'),
  onPickMatch: (_) => fail('Rendering must not bind a match.'),
  onBatchBind: (_) => fail('Rendering must not bind a batch.'),
  onBiliImport: (_) => fail('Rendering must not import a video.'),
  onBiliSelectPage: (_) => fail('Rendering must not select a video page.'),
  onClose: () {},
);

String _visibleText(WidgetTester tester) {
  final text = tester
      .widgetList<Text>(find.byType(Text))
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '');
  final selectable = tester
      .widgetList<SelectableText>(find.byType(SelectableText))
      .map((widget) => widget.data ?? widget.textSpan?.toPlainText() ?? '');
  return [...text, ...selectable].join('\n');
}

void _expectPrivateFieldsHidden(String visible) {
  for (final marker in [
    'https://',
    'fixture-user',
    'fixture-password',
    '-private-path',
    '-query-secret',
    '-bearer-secret',
    '-cookie-secret',
    '-body-secret',
  ]) {
    expect(
      visible.contains(marker),
      isFalse,
      reason:
          'Production DanmakuSearchPage must hide synthetic private fields.',
    );
  }
}

Future<void> _mount(WidgetTester tester, Widget host) async {
  await tester.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await pumpMiuixDialog(tester, host);
  expect(find.byType(DanmakuSearchPage), findsOneWidget);
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('dan-api hot-path failure hides private fields', (tester) async {
    final error = _failure('search');
    await _mount(tester, _host(state: _state(searchError: error)));
    final page = tester.widget<DanmakuSearchPage>(
      find.byType(DanmakuSearchPage),
    );
    expect(page.state.searchError, same(error));
    expect(error.uri, contains('-query-secret'));
    expect(
      tester
          .widget<ui.CheckboxListTile>(find.byType(ui.CheckboxListTile))
          .onChanged,
      isNotNull,
      reason: 'Partial failure must not disable existing results.',
    );
    final visible = _visibleText(tester);
    _expectPrivateFieldsHidden(visible);
    expect(visible, contains('Fixture search request refused'));
    expect(visible, contains('HTTP 403'));
    expect(visible, contains('HTTP status=403'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('video hot-path failure hides private fields', (tester) async {
    final error = _failure('video');
    await _mount(
      tester,
      _host(
        state: _state(),
        biliState: BiliImportState(error: error),
      ),
    );
    final page = tester.widget<DanmakuSearchPage>(
      find.byType(DanmakuSearchPage),
    );
    expect(page.biliState.error, same(error));
    expect(error.body, contains('-body-secret'));
    final visible = _visibleText(tester);
    _expectPrivateFieldsHidden(visible);
    expect(visible, contains('Fixture video request refused'));
    expect(visible, contains('HTTP 403'));
    expect(visible, contains('HTTP status=403'));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'expanded request details hide private fields and response body',
    (tester) async {
      final loadError = _failure('load');
      final searchError = _failure('search');
      final videoError = _failure('video');
      await _mount(
        tester,
        _host(
          state: _state(error: loadError, searchError: searchError),
          biliState: BiliImportState(error: videoError),
        ),
      );
      final expansion = find.byType(ui.ExpansionTile);
      expect(expansion, findsOneWidget);
      expect(
        find.descendant(of: expansion, matching: find.byType(miuix.MiuixCard)),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: expansion,
          matching: find.byType(miuix.MiuixBasicComponent),
        ),
        findsOneWidget,
      );
      expect(find.byType(SelectableText), findsNothing);
      final header = find.text('请求与服务端详情');
      await tester.ensureVisible(header);
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNWidgets(5));
      final page = tester.widget<DanmakuSearchPage>(
        find.byType(DanmakuSearchPage),
      );
      expect(page.state.error, same(loadError));
      expect(page.state.searchError, same(searchError));
      expect(page.biliState.error, same(videoError));
      expect(loadError.body, contains('-body-secret'));
      final visible = _visibleText(tester);
      _expectPrivateFieldsHidden(visible);
      expect(visible, contains('Fixture load response explains refusal.'));
      expect(visible, contains('Fixture search response explains refusal.'));
      expect(visible, contains('Fixture video response explains refusal.'));
      expect(visible, contains('HTTP 403'));
      expect(visible, contains('HTTP status=403'));
      await tester.ensureVisible(header);
      await tester.tap(header);
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
