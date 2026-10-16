/// 统一弹窗外壳在真实 showDialog 路由下的行为探针
///
/// # 为什么要这个文件
///
/// AppDialogShell 在 fill: true 时根节点是 Positioned.fill，而 Positioned 是
/// ParentDataWidget<StackParentData>，它要求祖先里有 Stack。
///
/// 但走 showAppDialog（= showDialog）的弹窗，内容树是
/// Navigator -> DialogRoute -> _FullWindowDialogWrapper -> builder 返回值，
/// 不一定有 Stack。
///
/// 既有测试（t99 / provider_import_test 等）都是把面板直接 pumpWidget 到
/// Scaffold.body 或自建 Stack 下，没有一条走真实路由。
/// 所以「线上打开弹窗会不会崩」此前没有任何门禁覆盖，本文件补上。
library;

import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';

import '../lib/ui/widgets/app_dialog_shell.dart';

void main() {
  testWidgets('★ 外壳 fill=true 在真实 showDialog 路由下不抛异常且渲染卡片', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (ctx) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showDialog<void>(
                context: ctx,
                builder: (_) => const AppDialogShell(
                  title: '探针标题',
                  subtitle: '探针副标题',
                  child: Text('探针内容'),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // (1) 不抛异常：若 Positioned 缺 Stack 祖先，这里会挂
    expect(tester.takeException(), isNull,
        reason: '★★ fill=true 在 showDialog 路由下抛异常 —— 线上打开弹窗会崩');

    // (2) 卡片真的渲染出来了
    expect(find.text('探针标题'), findsOneWidget);
    expect(find.text('探针副标题'), findsOneWidget);
    expect(find.text('探针内容'), findsOneWidget);
  });
}
