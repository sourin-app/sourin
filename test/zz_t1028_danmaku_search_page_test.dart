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

  // ══════════════════════════════════════════════════════════════════════
  //  第 11 项验收剩下的两条：**渠道标注** 与 **部分失败**
  // ══════════════════════════════════════════════════════════════════════
  testWidgets('★★★ 每条结果都标明渠道（不许只给标题）', (tester) async {
    await tester.pumpWidget(MaterialApp(home: DanmakuSearchPage(
      state: state(), biliState: const BiliImportState(), localTitles: const ['第1集'],
      onSearch: (_) {}, onBiliSearch: (_) {}, onPickMatch: (_) {},
      onBatchBind: (_) {}, onBiliImport: (_) {}, onBiliSelectPage: (_) {},
      onClose: () {},
    )));
    // 渠道是验收原文的一句（「搜索结果标明渠道」）—— 只断"有结果"是漏掉它
    expect(find.text('渠道：dan-api'), findsOneWidget,
        reason: '★★★ 跨渠道搜索后用户必须能分清这条结果来自哪个渠道');
    expect(find.text('视频站视频与分P'), findsOneWidget,
        reason: '★ 另一条渠道有自己的分区标题，不许把两路结果混在一起');
  });

  testWidgets('★★★ 一个渠道失败：错误各自展示，另一路结果仍然可用', (tester) async {
    final batches = <List<DanmakuMatch>>[];
    await tester.pumpWidget(MaterialApp(home: DanmakuSearchPage(
      state: DanmakuSettingsState(
        enabled: true, appId: '', appSecret: '', fontScale: 1, opacity: 1,
        speed: 1, area: 1, searchSearched: true,
        // dan-api 这一路失败，但上一批结果**还在**
        searchError: DanmakuException('dan-api 这一路超时', statusCode: 0),
        searchResults: const [match],
      ),
      // 视频站这一路也失败
      biliState: const BiliImportState(),
      localTitles: const ['第1集'],
      onSearch: (_) {}, onBiliSearch: (_) {}, onPickMatch: (_) {},
      onBatchBind: batches.add, onBiliImport: (_) {}, onBiliSelectPage: (_) {},
      onClose: () {},
    )));
    // ① 失败原因各自上屏（不互相覆盖、不被吞）
    expect(find.textContaining('dan-api 这一路超时'), findsOneWidget,
        reason: '★★★ 失败原因必须透出（渠道失败分别展示）');
    // ② **已有结果继续可用** —— 这是验收原文的另一半
    final tile = find.byType(CheckboxListTile);
    expect(tile, findsOneWidget, reason: '★★★ 一路失败不许把另一路的结果也清掉');
    expect(tester.widget<CheckboxListTile>(tile).onChanged, isNotNull,
        reason: '★★★ 失败 ≠ 过期：结果还在，就必须能勾选');
    await tester.tap(tile);
    await tester.pump();
    await tester.ensureVisible(find.text('预览批量绑定'));
    await tester.tap(find.text('预览批量绑定'));
    await tester.pump();
    await tester.ensureVisible(find.text('确认并交由播放器绑定'));
    await tester.tap(find.text('确认并交由播放器绑定'));
    await tester.pump();
    expect(batches.single.single.episodeId, 42,
        reason: '★ 部分失败之后绑定链路仍然真的能走通（不是只画了个勾）');
  });
}
