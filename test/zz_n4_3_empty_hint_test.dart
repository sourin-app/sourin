// ═══════════════════════════════════════════════════════════════════════
//  N4-3 #10 · 空态必须给出"下一步"（不是只有一条灰按钮）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷长什么样（`.probe/n4-3-layout/n4-3-wide-empty.png`）
// ```text
// 没搜过时，结果区只有一条**灰色禁用**的「预览批量绑定」按钮，下面 400px 全空
// ⇒ 用户看到"这里什么都没有"，而不是"接下来该做什么"。
// ```
//
// # 这条门禁钉三件事
// ```text
// ① 还没搜过（空态）⇒ 必须有"下一步"引导
// ② 搜过了但没匹配      ⇒ 不许还挂着"还没搜"的引导（那是两句不同的话）
// ③ 搜索中              ⇒ 不许挂引导（先给进度）
// ```
//
// 注入（证明有牙）：把那句引导删掉 ⇒ ① 红。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/core/danmaku.dart';
import '../lib/ui/danmaku_search_page.dart';
import '../lib/ui/widgets/bili_import_dialog.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';

void main() {
  const hint = '还没有结果';

  DanmakuSettingsState state({
    required bool searched,
    bool loading = false,
    bool withResults = false,
  }) =>
      DanmakuSettingsState(
        enabled: true,
        appId: '',
        appSecret: '',
        fontScale: 1,
        opacity: 1,
        speed: 1,
        area: 1,
        searchLoading: loading,
        searchSearched: searched,
        searchStale: false,
        searchResults: withResults
            ? const <DanmakuMatch>[
                DanmakuMatch(episodeId: 9, animeTitle: '作品', episodeTitle: '第1集'),
              ]
            : const <DanmakuMatch>[],
      );

  Future<void> mount(WidgetTester tester, DanmakuSettingsState s) =>
      tester.pumpWidget(MaterialApp(
        home: DanmakuSearchPage(
          state: s,
          biliState: const BiliImportState(),
          localTitles: const <String>['第1集'],
          onSearch: (_) {},
          onBiliSearch: (_) {},
          onPickMatch: (_) {},
          onBatchBind: (_) {},
          onBiliImport: (_) {},
          onBiliSelectPage: (_) {},
          onClose: () {},
        ),
      ));

  testWidgets('N4-3 #10 ① 空态必须有"下一步"引导', (tester) async {
    await mount(tester, state(searched: false));
    expect(find.textContaining(hint), findsOneWidget,
        reason: '★★ 空态只给一条灰按钮 = 让用户猜下一步（截图证据见 n4-3-wide-empty.png）');
  });

  testWidgets('N4-3 #10 ② 搜过没匹配：给"没找到"，不再给"还没搜"', (tester) async {
    await mount(tester, state(searched: true));
    expect(find.textContaining(hint), findsNothing,
        reason: '★ "还没搜"和"搜过没匹配"是两句不同的话，混用会把用户推向错误动作');
    expect(find.text('dan-api 未找到匹配剧集'), findsOneWidget,
        reason: '★ 搜过没匹配时，原有那句"未找到"必须还在（既有契约）');
  });

  testWidgets('N4-3 #10 ③ 有结果 / 搜索中都不许挂引导', (tester) async {
    await mount(tester, state(searched: true, withResults: true));
    expect(find.textContaining(hint), findsNothing, reason: '★ 有结果时挂引导 = 噪声');

    await mount(tester, state(searched: false, loading: true));
    expect(find.textContaining(hint), findsNothing,
        reason: '★ 搜索中先给进度条，不再叠引导');
  });
}
