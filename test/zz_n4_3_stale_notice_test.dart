// ═══════════════════════════════════════════════════════════════════════
//  N4-3 #11 · 过期态必须说出原因（真机截图逼出来的缺陷）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷长什么样（`.probe/n4-3-layout/n4-3-wide-stale.png`）
// ```text
// `searchStale == true` 时，复选框 /「绑定当前集」/ 批量绑定按钮全部
// `onPressed: null` ⇒ 整列**变灰**，页面上**一个字都没说**为什么点不动。
// ```
//
// # 这条门禁钉两件事
// ```text
// ① 过期态：必须有**可读的原因文案**（不是只有颜色）
// ② 非过期态 / 搜索中：不许出现这条文案（否则就成了"永远挂着的一句废话"）
// ```
//
// 注入（证明有牙）：把那段 `if (…s.searchStale)` 整段删掉 ⇒ ① 红。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/core/danmaku.dart';
import '../lib/ui/danmaku_search_page.dart';
import '../lib/ui/widgets/bili_import_dialog.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';

void main() {
  const notice = '结果已过期';

  DanmakuSettingsState state({
    required bool stale,
    bool loading = false,
    bool searched = true,
    bool empty = false,
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
        searchStale: stale,
        searchResults: empty
            ? const <DanmakuMatch>[]
            : const <DanmakuMatch>[
                DanmakuMatch(episodeId: 7, animeTitle: '作品', episodeTitle: '第1集'),
              ],
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

  testWidgets('N4-3 #11 ① 过期态必须给出原因文案（不只有灰色）', (tester) async {
    await mount(tester, state(stale: true));
    expect(find.textContaining(notice), findsOneWidget,
        reason: '★★ 过期态必须说明"为什么点不动" —— 只把控件变灰等于让用户猜');

    // 同时确认"确实点不动"（否则文案与行为不符，是另一种骗）
    final boxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(boxes, isNotEmpty, reason: '前置：过期态仍然把结果列出来（只是不可绑）');
    expect(boxes.every((b) => b.onChanged == null), isTrue,
        reason: '★ 过期态条目必须不可勾选（文案说的"已不能再绑定"要真的成立）');
  });

  testWidgets('N4-3 #11 ③ 过期但结果为空 ⇒ 不许挂（没有指代对象）', (tester) async {
    /*
     * ★ 2026-10-28 复核抓到的 nit：过期提示说的是"**下面这些条目**已不能再绑定"，
     *   而 `searchStale` 为真、结果为空时下面一条都没有 ⇒ 这句话没有指代对象。
     *   注入（把守卫去掉）⇒ 本条红。
     */
    await mount(tester, state(stale: true, searched: false, empty: true));
    expect(find.textContaining(notice), findsNothing,
        reason: '★ 没有结果时不许说"下面这些条目已不能再绑定"（下面一条都没有）');
  });

  testWidgets('N4-3 #11 ② 非过期态与搜索中都不许挂这条文案', (tester) async {
    await mount(tester, state(stale: false));
    expect(find.textContaining(notice), findsNothing,
        reason: '★ 正常态挂"结果已过期"= 误导');

    await mount(tester, state(stale: true, loading: true));
    expect(find.textContaining(notice), findsNothing,
        reason: '★ 搜索中先给进度，不再叠加"已过期"（两者互斥）');
  });
}
