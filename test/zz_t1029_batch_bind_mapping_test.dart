import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/batch_bind.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

/// 第 11 项（2026-10-26，Owner：弹幕批量绑定找不到对应关系）
///
/// 四条判据：
///   ① 候选行必须有**可读名字**（番剧名 · 第N集），不许出现裸 `#123456`
///   ② 同集号多候选必须显式选（沿用既有规则，这里做回归保护）
///   ③ 用户改了"对应到本地第N集"后，提交的是**改后的映射**
///   ④ 预览区改顺序后，提交的**顺序跟着变**
void main() {
  DanmakuSettingsState stateWith(List<DanmakuMatch> results) =>
      DanmakuSettingsState(
        enabled: true,
        appId: '',
        appSecret: '',
        fontScale: 1,
        opacity: 1,
        speed: 1,
        area: 1,
        searchSearched: true,
        searchResults: results,
      );

  Widget page(
    DanmakuSettingsState st, {
    List<List<BatchBindPlanItem>>? plans,
    List<List<DanmakuMatch>>? legacy,
    List<String> localTitles = const <String>['第1集', '第2集', '第3集', '第4集', '第5集'],
  }) =>
      MaterialApp(
        home: DanmakuSearchPage(
          state: st,
          biliState: const BiliImportState(),
          localTitles: localTitles,
          onSearch: (_) {},
          onBiliSearch: (_) {},
          onPickMatch: (_) {},
          onBatchBind: (l) => legacy?.add(l),
          onBatchBindPlan: (items, title) => plans?.add(items),
          onBiliImport: (_) {},
          onBiliSelectPage: (_) {},
          onClose: () {},
        ),
      );

  Future<void> selectAllAndPreview(WidgetTester t, int count) async {
    for (var i = 0; i < count; i++) {
      await t.tap(find.byType(CheckboxListTile).at(i));
      await t.pump();
    }
    await t.ensureVisible(find.text('预览批量绑定'));
    await t.tap(find.text('预览批量绑定'));
    await t.pump();
    await t.pump();
  }

  testWidgets('① 候选行显示「番剧名 · 第N集」，不出现裸 #编号', (t) async {
    await t.pumpWidget(page(stateWith(const <DanmakuMatch>[
      DanmakuMatch(
        episodeId: 987654,
        animeTitle: '无职转生 第三季',
        episodeTitle: '第1话 燃烧吧',
      ),
    ])));
    await t.pump();
    expect(find.textContaining('无职转生 第三季'), findsOneWidget,
        reason: '★ 番剧名必须可见（用户靠它确认"是不是这部"）');
    expect(find.textContaining('第1集'), findsOneWidget,
        reason: '★ 集号必须可见（用户靠它确认"对应哪一集"）');
    expect(find.textContaining('#987654'), findsNothing,
        reason: '★★ 不许出现裸 id —— 那正是 Owner 报的缺陷');
  });

  testWidgets('③ 改了「对应到本地第N集」⇒ 提交的是改后的映射', (t) async {
    final plans = <List<BatchBindPlanItem>>[];
    await t.pumpWidget(page(
      stateWith(const <DanmakuMatch>[
        DanmakuMatch(episodeId: 11, animeTitle: '作品甲', episodeTitle: '第1话'),
        DanmakuMatch(episodeId: 22, animeTitle: '作品甲', episodeTitle: '第2话'),
      ]),
      plans: plans,
    ));
    await t.pump();
    await selectAllAndPreview(t, 2);

    // 把第二个候选改成"对应本地第5集"（默认是第2集）
    final dropdowns = find.byType(DropdownButton<int>);
    await t.tap(dropdowns.at(1));
    await t.pumpAndSettle();
    await t.tap(find.text('第5集').last);
    await t.pumpAndSettle();
    await t.ensureVisible(find.text('预览批量绑定'));
    await t.tap(find.text('预览批量绑定'));
    await t.pump();

    await t.ensureVisible(find.text('确认并交由播放器绑定'));
    await t.tap(find.text('确认并交由播放器绑定'));
    await t.pump();

    final items = plans.single;
    expect(
      items.any((it) => it.episodeIndex == 4 && it.episodeId == 22),
      isTrue,
      reason: '★★ 用户改成"本地第5集（下标4）"后，提交必须反映这个映射：'
          '${items.map((e) => '${e.episodeIndex}->${e.episodeId}').toList()}',
    );
  });

  testWidgets('④ 预览区改顺序 ⇒ 提交顺序跟着变', (t) async {
    final plans = <List<BatchBindPlanItem>>[];
    await t.pumpWidget(page(
      stateWith(const <DanmakuMatch>[
        DanmakuMatch(episodeId: 11, animeTitle: '作品甲', episodeTitle: '第1话'),
        DanmakuMatch(episodeId: 22, animeTitle: '作品甲', episodeTitle: '第2话'),
      ]),
      plans: plans,
    ));
    await t.pump();
    await selectAllAndPreview(t, 2);

    final list = t.widget<ReorderableListView>(find.byType(ReorderableListView));
    // 直接驱动真实回调（等价于用户把第 1 行拖到第 2 行之后）
    list.onReorder?.call(0, 2);
    await t.pump();

    await t.ensureVisible(find.text('确认并交由播放器绑定'));
    await t.tap(find.text('确认并交由播放器绑定'));
    await t.pump();

    expect(plans.single.map((e) => e.episodeIndex).toList(), <int>[1, 0],
        reason: '★★ 拖动后提交顺序必须跟着变（不许按返回顺序硬套）');
  });

  testWidgets('⑤ 取消勾选后再勾选 ⇒ 映射回到默认（不留上次的脏值）', (t) async {
    await t.pumpWidget(page(stateWith(const <DanmakuMatch>[
      DanmakuMatch(episodeId: 11, animeTitle: '作品甲', episodeTitle: '第1话'),
      DanmakuMatch(episodeId: 22, animeTitle: '作品甲', episodeTitle: '第2话'),
    ])));
    await t.pump();
    await t.tap(find.byType(CheckboxListTile).at(1));
    await t.pump();
    // 改成"对应本地第5集"
    await t.tap(find.byType(DropdownButton<int>).at(1));
    await t.pumpAndSettle();
    await t.tap(find.text('第5集').last);
    await t.pumpAndSettle();
    expect(t.widget<DropdownButton<int>>(find.byType(DropdownButton<int>).at(1)).value, 4);
    // 取消勾选 → 再勾选
    await t.tap(find.byType(CheckboxListTile).at(1));
    await t.pump();
    await t.tap(find.byType(CheckboxListTile).at(1));
    await t.pump();
    expect(t.widget<DropdownButton<int>>(find.byType(DropdownButton<int>).at(1)).value, isNot(4),
        reason: '★★ 重新勾选必须回到默认映射，不能留着上次的"第5集"（用户会以为它还有效）');
  });

  testWidgets('② 同集号多候选 ⇒ 预览里要提示并禁止确认', (t) async {
    await t.pumpWidget(page(stateWith(const <DanmakuMatch>[
      DanmakuMatch(episodeId: 11, animeTitle: '作品甲', episodeTitle: '第1话'),
      DanmakuMatch(episodeId: 22, animeTitle: '作品乙', episodeTitle: '第1话'),
    ])));
    await t.pump();
    await selectAllAndPreview(t, 2);
    expect(find.textContaining('请明确选择一个'), findsOneWidget);
    final confirm = find.widgetWithText(FilledButton, '确认并交由播放器绑定');
    expect(t.widget<FilledButton>(confirm).onPressed, isNull);
  });
}
