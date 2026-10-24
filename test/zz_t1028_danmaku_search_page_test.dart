import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import '../lib/core/danmaku.dart';
import '../lib/ui/danmaku_search_page.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';
import '../lib/ui/widgets/bili_import_dialog.dart';

void main() {
  const match = DanmakuMatch(episodeId: 42, animeTitle: '作品', episodeTitle: '第1集');
  DanmakuSettingsState state({bool stale = false}) => DanmakuSettingsState(
    enabled: true, appId: '', appSecret: '', fontScale: 1, opacity: 1,
    speed: 1, area: 1, searchSearched: true, searchStale: stale,
    searchResults: const [match]);

  testWidgets('search dispatches both channels and batch requires preview confirmation', (tester) async {
    final searches = <String>[];
    final batches = <List<DanmakuMatch>>[];
    await tester.pumpWidget(MaterialApp(home: DanmakuSearchPage(
      state: state(), biliState: const BiliImportState(), localTitles: const ['第1集', '第2集'],
      onSearch: (q) => searches.add('dan:$q'), onBiliSearch: (q) => searches.add('bili:$q'),
      onPickMatch: (_) {}, onBatchBind: batches.add, onBiliImport: (_) {},
      onBiliSelectPage: (_) {}, onClose: () {},
    )));
    await tester.enterText(find.byType(TextField), '作品');
    await tester.tap(find.text('搜索 dan-api 与视频站'));
    await tester.pump();
    expect(searches, ['dan:作品', 'bili:作品']);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(batches, isEmpty);
    await tester.ensureVisible(find.text('预览批量绑定'));
    await tester.tap(find.text('预览批量绑定'));
    await tester.pump();
    expect(find.text('将匹配 1 / 2 集；未匹配 1 集'), findsOneWidget);
    expect(batches, isEmpty);
    await tester.ensureVisible(find.text('确认并交由播放器绑定'));
    await tester.tap(find.text('确认并交由播放器绑定'));
    await tester.pump();
    expect(batches.single.single.episodeId, 42);
  });

  testWidgets('stale results cannot be selected or bound', (tester) async {
    await tester.pumpWidget(MaterialApp(home: DanmakuSearchPage(
      state: state(stale: true), biliState: const BiliImportState(), localTitles: const ['第1集'],
      onSearch: (_) {}, onBiliSearch: (_) {}, onPickMatch: (_) => fail('stale bind'),
      onBatchBind: (_) => fail('stale batch'), onBiliImport: (_) {},
      onBiliSelectPage: (_) {}, onClose: () {},
    )));
    expect(tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '绑定当前集')).onPressed, isNull);
  });
}
