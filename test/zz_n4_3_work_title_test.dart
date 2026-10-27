// ═══════════════════════════════════════════════════════════════════════
//  N4-3 #1 · 顶栏必须显示"我在给哪部剧搜"
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷长什么样（`.probe/n4-3-layout/n4-3-wide-results.png`）
// ```text
// 顶栏只有「✕ 搜索弹幕与绑定剧集」，右侧 800px 空白 ⇒
// 用户在搜索页看不到自己正在给哪部剧搜，搜到两条同名剧时无从核对。
// ```
//
// # 这条门禁钉三件事
// ```text
// ① 宿主传了作品名 ⇒ 顶栏必须出现它；
// ② 没传 / 传空    ⇒ 保持原来那句（不许出现"搜索弹幕 · " 这种半截标题）；
// ③ 传进来的名字必须**逐字**出现（不做大小写/繁简/省略号处理后再比）。
// ```
//
// 注入（证明有牙）：把三元的"传了就用"删掉（恒用原标题）⇒ ① 红。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/core/danmaku.dart';
import '../lib/ui/danmaku_search_page.dart';
import '../lib/ui/widgets/bili_import_dialog.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';

void main() {
  const workTitle = '某部测试用作品';

  DanmakuSettingsState state() => DanmakuSettingsState(
        enabled: true,
        appId: '',
        appSecret: '',
        fontScale: 1,
        opacity: 1,
        speed: 1,
        area: 1,
        searchSearched: false,
        searchStale: false,
        searchResults: const <DanmakuMatch>[],
      );

  Future<void> mount(WidgetTester tester, String? title) =>
      tester.pumpWidget(MaterialApp(
        home: DanmakuSearchPage(
          state: state(),
          biliState: const BiliImportState(),
          localTitles: const <String>['第1集'],
          workTitle: title,
          onSearch: (_) {},
          onBiliSearch: (_) {},
          onPickMatch: (_) {},
          onBatchBind: (_) {},
          onBiliImport: (_) {},
          onBiliSelectPage: (_) {},
          onClose: () {},
        ),
      ));

  testWidgets('N4-3 #1 ① 传了作品名 ⇒ 顶栏逐字出现', (tester) async {
    await mount(tester, workTitle);
    expect(find.textContaining(workTitle), findsOneWidget,
        reason: '★★ 搜索页必须让用户看到"在给哪部剧搜"（同名剧核对全靠它）');
  });

  testWidgets('N4-3 #1 ② 没传 / 空串 ⇒ 保持原标题，不出现半截标题', (tester) async {
    await mount(tester, null);
    expect(find.text('搜索弹幕与绑定剧集'), findsOneWidget,
        reason: '★ 没有剧上下文时必须还是原来那句');
    expect(find.textContaining('搜索弹幕 · '), findsNothing,
        reason: '★ 不许出现"搜索弹幕 · "后面空着的半截标题');

    await mount(tester, '   ');
    expect(find.text('搜索弹幕与绑定剧集'), findsOneWidget,
        reason: '★ 全空白的名字等同于没传');
  });
}
