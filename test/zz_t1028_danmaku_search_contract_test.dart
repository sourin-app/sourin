import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// 弹幕搜索页的契约：设置弹窗不再承载搜索，搜索与选择性在独立页上。
///
/// 本文件原来只有一条「源码里不许再出现三个旧分节」的字符串判据（保留在最后）。
/// 字符串判据只证明"写法变了"，证明不了"行为对不对" ⇒ 这里补三条
/// 驱动真实 `DanmakuSearchPage` 的行为判据：
///   ① 过期结果禁止选中，并且"没过期时能选"（两个方向都断）
///   ② 同一集有多个候选时必须明确选一个，不许按列表顺序默默取第一条
///   ③ 搜索失败时错误要透出，且已有结果仍然可用
///
/// 每条都自带对照（对照组不成立就会红），避免"把开关焊死"也能过。
void main() {
  const resultOne = DanmakuMatch(
    episodeId: 42,
    animeTitle: '作品甲',
    episodeTitle: '第1集',
  );

  DanmakuSettingsState stateWith({
    bool stale = false,
    bool searched = true,
    DanmakuException? searchError,
    List<DanmakuMatch> results = const <DanmakuMatch>[],
  }) =>
      DanmakuSettingsState(
        enabled: true,
        appId: '',
        appSecret: '',
        fontScale: 1,
        opacity: 1,
        speed: 1,
        area: 1,
        searchSearched: searched,
        searchStale: stale,
        searchError: searchError,
        searchResults: results,
      );

  Widget page(
    DanmakuSettingsState state, {
    List<List<DanmakuMatch>>? batches,
    List<String> localTitles = const <String>['第1集', '第2集'],
  }) =>
      MaterialApp(
        home: DanmakuSearchPage(
          state: state,
          biliState: const BiliImportState(),
          localTitles: localTitles,
          onSearch: (_) {},
          onBiliSearch: (_) {},
          onPickMatch: (_) {},
          onBatchBind: (l) => batches?.add(l),
          onBiliImport: (_) {},
          onBiliSelectPage: (_) {},
          onClose: () {},
        ),
      );

  group('① 过期结果禁止选中（两个方向都断）', () {
    testWidgets('结果过期时：勾选框不可改、预览按钮不可点、提交不会发生',
        (tester) async {
      final batches = <List<DanmakuMatch>>[];
      await tester.pumpWidget(
        page(
          stateWith(stale: true, results: const <DanmakuMatch>[resultOne]),
          batches: batches,
        ),
      );
      await tester.pump();

      expect(
        tester
            .widget<CheckboxListTile>(find.byType(CheckboxListTile))
            .onChanged,
        isNull,
        reason: '过期结果必须禁止勾选，否则用户会把上一次搜索的结果绑到这一集',
      );
      final preview = find.widgetWithText(OutlinedButton, '预览批量绑定');
      expect(tester.widget<OutlinedButton>(preview).onPressed, isNull,
          reason: '一条都没选（也选不了）时，预览必须先禁用');
      expect(batches, isEmpty, reason: '没有任何提交路径能在过期状态下发出绑定');
    });

    testWidgets('对照：没过期时同一份结果确实可选（证明上面的禁用不是焊死的）',
        (tester) async {
      await tester.pumpWidget(
        page(
          stateWith(results: const <DanmakuMatch>[resultOne]),
          batches: <List<DanmakuMatch>>[],
        ),
      );
      await tester.pump();

      final tile = find.byType(CheckboxListTile);
      expect(tester.widget<CheckboxListTile>(tile).onChanged, isNotNull,
          reason: '没过期就必须能选，否则"过期禁止"这条判据没有对照、恒真');
      await tester.tap(tile);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(tile).value, isTrue,
          reason: '点一下必须真的选中');
    });
  });

  group('② 同一集多个候选：必须明确选一个', () {
    testWidgets('两个候选同集时确认被禁用，选定后才能提交且只交选中的那条',
        (tester) async {
      final batches = <List<DanmakuMatch>>[];
      await tester.pumpWidget(
        page(
          stateWith(results: const <DanmakuMatch>[
            DanmakuMatch(episodeId: 11, animeTitle: '作品甲', episodeTitle: '第1集'),
            DanmakuMatch(episodeId: 22, animeTitle: '作品乙', episodeTitle: '第1集'),
          ]),
          batches: batches,
        ),
      );
      await tester.pump();

      for (var i = 0; i < 2; i++) {
        await tester.tap(find.byType(CheckboxListTile).at(i));
        await tester.pump();
      }
      await tester.ensureVisible(find.text('预览批量绑定'));
      await tester.tap(find.text('预览批量绑定'));
      await tester.pump();

      expect(find.textContaining('请明确选择一个'), findsOneWidget,
          reason: '同集多候选时必须提示，不能默默取第一条');

      final confirm = find.widgetWithText(FilledButton, '确认并交由播放器绑定');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull,
          reason: '冲突未解决时确认必须禁用，否则用户以为已经选好了');
      expect(batches, isEmpty, reason: '冲突状态下不许提交');

      final choice = find.textContaining('选择 ').last;
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.pump();
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull,
          reason: '选定后确认必须恢复可用');
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pump();
      expect(batches.single.map((m) => m.episodeId), <int>[22],
          reason: '只提交用户明确选中的那条，不许把两个 id 都塞进去');
    });

    testWidgets('对照：只有一个候选时不出现冲突、确认直接可用', (tester) async {
      final batches = <List<DanmakuMatch>>[];
      await tester.pumpWidget(
        page(
          stateWith(results: const <DanmakuMatch>[resultOne]),
          batches: batches,
        ),
      );
      await tester.pump();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.ensureVisible(find.text('预览批量绑定'));
      await tester.tap(find.text('预览批量绑定'));
      await tester.pump();

      expect(find.textContaining('请明确选择一个'), findsNothing,
          reason: '只有一个候选时不该报冲突（否则这条提示会被用户学会无视）');
      final confirm = find.widgetWithText(FilledButton, '确认并交由播放器绑定');
      expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull,
          reason: '没有冲突就必须能确认，证明②的禁用是"冲突驱动"而不是恒禁用');
    });
  });

  group('③ 一路失败：错误要透出，已有结果仍可用', () {
    testWidgets('搜索失败时错误上屏，已有结果仍可勾选并真提交', (tester) async {
      final batches = <List<DanmakuMatch>>[];
      await tester.pumpWidget(
        page(
          stateWith(
            searchError: DanmakuException('这一路没有应答', statusCode: 0),
            results: const <DanmakuMatch>[resultOne],
          ),
          batches: batches,
        ),
      );
      await tester.pump();

      expect(find.textContaining('这一路没有应答'), findsOneWidget,
          reason: '失败原因必须透出，否则用户只看到"没结果"，不知道该重试还是改配置');

      final tile = find.byType(CheckboxListTile);
      expect(tester.widget<CheckboxListTile>(tile).onChanged, isNotNull,
          reason: '一路失败不等于结果作废，已有结果必须还能选');
      await tester.tap(tile);
      await tester.pump();
      await tester.ensureVisible(find.text('预览批量绑定'));
      await tester.tap(find.text('预览批量绑定'));
      await tester.pump();
      await tester.ensureVisible(find.text('确认并交由播放器绑定'));
      await tester.tap(find.text('确认并交由播放器绑定'));
      await tester.pump();
      expect(batches.single.single.episodeId, 42,
          reason: '部分失败后绑定链路仍然真的走得通，不只是画了个可点的勾');
    });
  });

  // 保留：设置弹窗不再渲染旧的三块（源码判据）
  test('设置弹窗不再渲染请求 / 搜索 / 服务端返回三块', () {
    final source =
        File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync();
    expect(source, contains('final VoidCallback? onOpenSearch;'));
    expect(source, contains('danmaku-settings-scroll'));
    final start = source.indexOf('final settings =');
    expect(start, greaterThan(0), reason: '锚点变了就要同步改这条判据，别让它变成恒真');
    final build = source.substring(start, source.indexOf('final body =', start));
    expect(build, isNot(contains('_group(_requestSection())')));
    expect(build, isNot(contains('_group(_searchSection())')));
    expect(build, isNot(contains('_group(_errorSection(s.error!))')));
  });
}
