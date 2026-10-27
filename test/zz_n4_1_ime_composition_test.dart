// ═══════════════════════════════════════════════════════════════════════
//  N4-1 取证 · 中文（IME）输入在这条链路上到底通不通 —— **Flutter 层**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条用例证明什么、不证明什么（先说边界，免得被当成"IME 修好了"）
// ```text
// 证明：`DanmakuSearchPage` 的输入框**不吞合成态** —— IME 先送一段 composing
//      （拼音串 + 未提交区间），再提交成中文，控件两次都收下，且提交后的中文
//      能原样进到 `onSearch` 的回调里。
// 不证明：Win32 的 `WM_IME_*` 有没有被自绘窗口层（`window_frame.dart`）吞掉。
//      那一层在真机 release 上才看得见，且需要真实 IME 驱动 ⇒ 本文件**不是**它的证据。
// ⇒ 结论口径：本文件绿 = "页面层没有拦中文输入，嫌疑收窄到窗口/引擎层"；
//   本文件红 = "页面层就吞了，先修页面"。
// ```
//
// # 为什么用 `updateEditingValue` 而不是 `enterText`
// ```text
// `tester.enterText` 直接给**最终文本**，跳过 composing —— 而"中文输入不了"
// 的典型形态恰恰发生在**合成区间**上（控件若在 onChanged 里重建 controller
// 或重置 selection，合成区间就被打断，中文永远提交不上来）。
// ```
//
// 门禁注入（证明它有牙）：给输入框加一条 `inputFormatters` 只允许 ASCII ⇒ 本文件必红。

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../lib/core/danmaku.dart';
import '../lib/ui/danmaku_search_page.dart';
import '../lib/ui/widgets/bili_import_dialog.dart';
import '../lib/ui/widgets/danmaku_settings_dialog.dart';

void main() {
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

  Future<void> mount(WidgetTester tester, {required void Function(String) onSearch}) {
    return tester.pumpWidget(MaterialApp(
      home: DanmakuSearchPage(
        state: state(),
        biliState: const BiliImportState(),
        localTitles: const <String>['第1集'],
        onSearch: onSearch,
        onBiliSearch: (_) {},
        onPickMatch: (_) {},
        onBatchBind: (_) {},
        onBiliImport: (_) {},
        onBiliSelectPage: (_) {},
        onClose: () {},
      ),
    ));
  }

  EditableText editable(WidgetTester tester) =>
      tester.widget<EditableText>(find.byType(EditableText));

  testWidgets('N4-1 ① 合成态进得来：composing 区间不被页面重置', (tester) async {
    await mount(tester, onSearch: (_) {});
    /*
     * ★ 必须先让输入框拿到焦点（= 建立 test 的 IME 连接），否则
     *   `testTextInput.updateEditingValue` 没有接收方，文本会静默丢掉 ——
     *   实测过：不加这一行，controller 一直是空串（看起来像"页面吞了输入"，
     *   其实是测试没接上线，属于仪器坑不是产品缺陷）。
     */
    await tester.tap(find.byType(TextField));
    await tester.pump();

    // ① IME 送"拼音中"的合成态（还没提交）
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: 'wuzhizhuansheng',
        selection: TextSelection.collapsed(offset: 15),
        composing: TextRange(start: 0, end: 15),
      ),
    );
    await tester.pump();

    final v1 = editable(tester).controller.value;
    expect(v1.text, 'wuzhizhuansheng',
        reason: '★ 合成中的拼音必须能进控件（进不来 = 中文输入的第一步就断了）');
    expect(v1.composing.isValid, isTrue,
        reason: '★★ 合成区间必须还在 —— 页面若在输入过程中重建/重置 controller，'
            '这个区间会被清空，IME 就永远提交不了中文');

    // ② IME 提交成中文（composing 收起）
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '无职转生',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    );
    await tester.pump();

    final v2 = editable(tester).controller.value;
    expect(v2.text, '无职转生', reason: '★ 提交后的中文必须落在控件里');
    expect(v2.composing.isValid, isFalse, reason: '★ 提交后合成区间必须收起');
  });

  testWidgets('N4-1 ② 中文能原样进 onSearch（不被过滤/截断）', (tester) async {
    final sent = <String>[];
    await mount(tester, onSearch: sent.add);
    await tester.tap(find.byType(TextField)); // 同上：先建输入连接
    await tester.pump();

    tester.testTextInput.updateEditingValue(
      const TextEditingValue(
        text: '无职转生',
        selection: TextSelection.collapsed(offset: 4),
        composing: TextRange.empty,
      ),
    );
    await tester.pump();
    await tester.ensureVisible(find.text('搜索 dan-api 与视频站'));
    await tester.tap(find.text('搜索 dan-api 与视频站'));
    await tester.pump();

    expect(sent, isNotEmpty, reason: '★ 点搜索必须真的发出请求');
    expect(sent.first, contains('无职转生'),
        reason: '★★ 中文必须原样进回调 —— 这一条若红，说明输入层把非 ASCII 过滤掉了'
            '（历史上最常见的原因是给 TextField 加了只允许 ASCII 的 inputFormatters）');
  });
}
