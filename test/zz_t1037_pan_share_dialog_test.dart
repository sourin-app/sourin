import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/pan_share_dialog.dart';

/// 网盘链接识别对话框的门禁
///
/// # 守什么
/// 这个对话框存在的唯一理由是**把"为什么不能播"说清楚**。所以门禁要证明：
/// - 它真的走统一外壳、含 TextField 时有透明 Material 宿主（否则真机必崩）
/// - 空输入在本地被拦（不发请求）
/// - 认出后**分层原因**真的显示出来了，且不会出现"能播"的假承诺
void main() {
  Future<void> pump(WidgetTester t) async {
    t.view.devicePixelRatio = 1.0;
    t.view.physicalSize = const Size(1000, 900);
    addTearDown(() {
      t.view.resetPhysicalSize();
      t.view.resetDevicePixelRatio();
    });
    await t.pumpWidget(MaterialApp(
      theme: AppTheme.themeFor(Brightness.dark),
      themeAnimationDuration: Duration.zero,
      home: const Scaffold(body: PanShareDialog()),
    ));
    await t.pump();
    await t.pump(const Duration(milliseconds: 300));
  }

  testWidgets('走统一外壳 AppGlassDialog，并说明用途', (t) async {
    await pump(t);
    expect(find.byType(AppGlassDialog), findsOneWidget);
    expect(find.textContaining('属于哪个网盘'), findsOneWidget,
        reason: '必须告诉用户这个对话框能回答什么');
  });

  testWidgets('含 TextField 时有透明 Material 宿主（防真机崩溃）', (t) async {
    await pump(t);
    expect(find.byType(TextField), findsOneWidget);
    final mats = t
        .widgetList<Material>(find.byType(Material))
        .where((m) => m.type == MaterialType.transparency);
    expect(mats, isNotEmpty,
        reason: '★★★ 缺透明 Material 宿主 ⇒ 真机点开就抛 '
            '"require a Material widget ancestor"');
  });

  testWidgets('空输入不发请求，直接提示', (t) async {
    await pump(t);
    await t.tap(find.text('识别'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    expect(find.textContaining('请先粘贴'), findsOneWidget,
        reason: '空输入必须在本地拦下');
  });

  // ── 为什么这里**不测**"认出分享后显示分层原因" ──
  //
  // 试过在 `testWidgets` 里调真实 FFI（`SourinCore.startAsync` +
  // `identifyPanShare`）：实测 **did not complete**（跑满 8 分钟后超时）。
  // 原因是 `testWidgets` 跑在 fake-async 环境里，真实 FFI 的异步回调
  // 等不到事件循环推进。
  //
  // 而这个能力**已经被 `zz_t1036` 覆盖**了，且它用的是普通 `test()`
  // （真实异步可正常完成），断言更细（五条分层原因逐条验）。
  //
  // ⇒ 这里不重复，也不为了"看起来覆盖全"而写一个会挂的用例。
  //    UI 层只测"外壳 / Material 宿主 / 空输入拦截"这三件纯 UI 的事。
}
