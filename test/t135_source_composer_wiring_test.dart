// ★ 可视化编排器接线门禁（Owner 第 9 条）
// ignore_for_file: avoid_print
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';


void main() {
  testWidgets('composer wired', (t) async {
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: AppTheme.themeFor(Brightness.dark),
      builder: (c, ch) =>
          AppThemeHost(data: AppTheme.themeFor(Brightness.dark), child: ch ?? const SizedBox()),
      home: Scaffold(
        backgroundColor: const Color(0xFF101014),
        body: Builder(builder: (c) {
          WidgetsBinding.instance.addPostFrameCallback((_) async {
            await ProviderImportDialog.showAdd(c);
          });
          return const SizedBox();
        }),
      ),
    ));
    await t.pumpAndSettle();
    // 找到「可视化编排」按钮
    expect(find.text('可视化编排'), findsOneWidget, reason: '入口按钮必须存在');

    // ★★ 关键：**能点**才算接线成功。只断言"存在"会漏掉 onPressed: null，
    //    那正是本条门禁第一版的假绿（故障注入实测 +1 passed）。
    final btn = t.widget<TextButton>(
      find.ancestor(
        of: find.text('可视化编排'),
        matching: find.byType(TextButton),
      ),
    );
    expect(btn.onPressed, isNotNull,
        reason: '★★ 按钮存在但 onPressed 为 null ⇒ 点了没反应，等于没接线');
    await t.tap(find.text('可视化编排'));
    await t.pumpAndSettle();
    /*
     * ★★ 2026-10-17（CodeRabbit CR）：改前这里断言 find.text(可视化编排) ——
     *   但**按钮文字本身就是这个字符串** ⇒ 点击前后都能命中 ⇒
     *   onPressed 改成空函数后照样绿（假绿）。
     *
     * ⇒ 改成断言**编排器独有的内容**，而不是那句按钮文案。
     */
    expect(find.byType(SourceComposerDialog), findsOneWidget,
        reason: '★ 点击后编排器必须真的弹出来（不是"按钮文字还在"）');
    /*
     * ★★★ 2026-10-17（task-40 / Owner 第 9 条）：断言**新行为**。
     *
     * 改前这里断言 find.text('这个源叫什么') —— 那是**三步向导第 1 步**的标题。
     * 编排器改成一屏分区卡片后，那句文案不存在了（第 1 块现在叫「① 站点」）。
     *
     * ⚠️ 这不是「为了让测试变绿而放宽」：判据换成**更强**的三条 ——
     *    ① 编排器真的渲染出来（byType）
     *    ② 三块**同时**在（一屏化，不需要下一步）
     *    ③ 没有「下一步」按钮（向导已删除）
     * 这三条在**旧实现下都会红**（旧实现里 ② 的 ②③ 两块不在同一屏、③ 有按钮）。
     */
    expect(find.textContaining('① 站点'), findsOneWidget,
        reason: '★ 站点区块必须在一屏内可见');
    expect(find.textContaining('③ 字段映射'), findsOneWidget,
        reason: '★★ 字段映射也必须**同时**可见 —— 这就是「一屏化」的判据');
    expect(find.text('下一步'), findsNothing,
        reason: '★★ 不许再有「下一步」—— Owner 要的就是不用点它');
    });
}
