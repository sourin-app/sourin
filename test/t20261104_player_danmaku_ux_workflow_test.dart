import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

const _first = DanmakuMatch(
  episodeId: 11, animeTitle: 'Work', episodeTitle: 'Episode 1',
);
const _second = DanmakuMatch(
  episodeId: 12, animeTitle: 'Work', episodeTitle: 'Episode 2',
);

DanmakuSettingsState _state({bool loading = false}) => DanmakuSettingsState(
  enabled: true, appId: '', appSecret: '', fontScale: 1, opacity: 1,
  speed: 1, area: 1, searchKeyword: 'Work', searchSearched: true,
  searchLoading: loading, searchResults: const [_first, _second],
);

Widget _search({bool loading = false, ValueChanged<String>? onSearch,
  ValueChanged<List<DanmakuMatch>>? onBatch,
  DanmakuSearchDraft? draft, double textScale = 1}) => MaterialApp(
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(
      textScaler: TextScaler.linear(textScale)), child: child!),
  home: DanmakuSearchPage(
    state: _state(loading: loading), biliState: const BiliImportState(),
    localTitles: const ['Episode 1', 'Episode 2'],
    onSearch: onSearch ?? (_) {}, onBiliSearch: (_) {},
    onPickMatch: (_) {}, onBatchBind: onBatch ?? (_) {},
    onBiliImport: (_) {}, onBiliSelectPage: (_) {}, onClose: () {},
    draft: draft,
  ),
);

void main() {
  setUp(() => UiPrefs.debugResetForTest(<String, String>{}));
  tearDown(() => UiPrefs.debugResetForTest(<String, String>{}));

  testWidgets('source tab exposes the genuine merge source toggle', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DanmakuSettingsDialog(
        state: _state(), fill: false, onSetEnabled: (_) {},
        onSetFontScale: (_) {}, onSetOpacity: (_) {}, onSetSpeed: (_) {},
        onSetArea: (_) {}, onReload: () {}, onClose: () {},
      ),
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('弹幕来源').first);
    await tester.pumpAndSettle();
    final source = find.text(DanmakuFeedChannel.danApi.label);
    expect(source, findsOneWidget);
    await tester.ensureVisible(source);
    await tester.tap(source);
    await tester.pump(const Duration(milliseconds: 350));
    expect(UiPrefs.get('danmaku.feeds.enabled')!.split(','),
      isNot(contains(DanmakuFeedChannel.danApi.name)));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings navigation remains reachable after scrolling', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(420, 360);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: DanmakuSettingsDialog(
        state: _state(), fill: false, onSetEnabled: (_) {},
        onSetFontScale: (_) {}, onSetOpacity: (_) {}, onSetSpeed: (_) {},
        onSetArea: (_) {}, onReload: () {}, onClose: () {},
      ),
    )));
    await tester.pumpAndSettle();
    await tester.drag(find.byKey(const ValueKey('danmaku-settings-scroll')),
      const Offset(0, -1500));
    await tester.pumpAndSettle();
    expect(find.text('弹幕来源').first.hitTestable(), findsOneWidget);
    await tester.tap(find.text('弹幕来源').first);
    await tester.pumpAndSettle();
    expect(find.text(DanmakuFeedChannel.localService.label), findsOneWidget);
  });

  testWidgets('Enter cannot dispatch a second in-flight search', (tester) async {
    final dispatched = <String>[];
    await tester.pumpWidget(_search(loading: true, onSearch: dispatched.add));
    await tester.enterText(find.byType(TextField), 'Work');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(dispatched, isEmpty);
  });

  testWidgets('manual local-target collisions cannot silently bind', (tester) async {
    final batches = <List<DanmakuMatch>>[];
    await tester.pumpWidget(_search(onBatch: batches.add));
    for (final id in [11, 12]) {
      final row = find.byKey(ValueKey<int>(id));
      final dropdown = find.descendant(of: row,
        matching: find.byType(DropdownButton<int>));
      tester.widget<DropdownButton<int>>(dropdown).onChanged!(0);
      await tester.pump();
      await tester.ensureVisible(row);
      await tester.tap(row);
      await tester.pump();
    }
    await tester.ensureVisible(find.text('预览批量绑定'));
    await tester.tap(find.text('预览批量绑定'));
    await tester.pump();
    final confirm = find.widgetWithText(FilledButton, '确认并交由播放器绑定');
    expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
    expect(batches, isEmpty);
  });

  testWidgets('unclosed confirmation preserves the editable preview',
    (tester) async {
      final draft = DanmakuSearchDraft();
      final batches = <List<DanmakuMatch>>[];
      await tester.pumpWidget(_search(draft: draft, onBatch: batches.add));
      await tester.tap(find.byKey(const ValueKey<int>(11)));
      await tester.pump();
      await tester.tap(find.text('预览批量绑定'));
      await tester.pump();
      await tester.tap(find.text('确认并交由播放器绑定'));
      await tester.pump();
      expect(batches, hasLength(1));
      expect(draft.previewing, isTrue,
        reason: 'Only a successful host operation may dismiss the editor');
      expect(find.text('确认并交由播放器绑定'), findsOneWidget);
    });

  testWidgets('a new query clears old draft mappings and selection',
    (tester) async {
      final draft = DanmakuSearchDraft();
      final dispatched = <String>[];
      await tester.pumpWidget(_search(draft: draft, onSearch: dispatched.add));
      await tester.tap(find.byKey(const ValueKey<int>(11)));
      await tester.pump();
      await tester.tap(find.text('预览批量绑定'));
      await tester.pump();
      expect(draft.previewing, isTrue);
      await tester.enterText(find.byType(TextField), 'Next Work');
      await tester.tap(find.byTooltip('搜索 dan-api 与视频站'));
      await tester.pump();
      expect(dispatched, ['Next Work']);
      expect(draft.selectedEpisodeIds, isEmpty);
      expect(draft.previewing, isFalse);
      expect(find.text('已选 0 集'), findsOneWidget);
    });

  testWidgets('narrow enlarged-text search keeps its actions reachable',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(360, 640);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(_search(textScale: 1.5));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byKey(const ValueKey<int>(11)));
      await tester.pumpAndSettle();
      await tester.drag(
        find.byKey(const ValueKey('danmaku-search-results-scroll')),
        const Offset(0, -300));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey<int>(11)).hitTestable(), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey<int>(11)));
      await tester.pumpAndSettle();
      await tester.tap(find.text('预览批量绑定'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('搜索 dan-api 与视频站').hitTestable(), findsOneWidget);
      expect(find.text('确认并交由播放器绑定').hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
}
