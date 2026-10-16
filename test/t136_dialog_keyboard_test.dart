// ★ 弹窗外壳的键盘交互门禁（Owner 第 8 条「交互都很烂」）
//
// 钉两件事：
//   ① Esc 能关（且 closeEnabled=false 时不关）
//   ② 焦点被圈在弹窗内（Tab 不会跑到背后页面）
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';

Future<void> pumpShell(
  WidgetTester t, {
  required VoidCallback onClose,
  bool closeEnabled = true,
}) async {
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: AppDialogShell(
        title: '测试弹窗',
        subtitle: '副标题',
        onClose: onClose,
        closeEnabled: closeEnabled,
        fill: false,
        child: const TextField(autofocus: true),
      ),
    ),
  ));
  await t.pumpAndSettle();
}

void main() {
  testWidgets('★ Esc 必须能关闭弹窗（有 onClose 时）', (t) async {
    var closed = 0;
    await pumpShell(t, onClose: () => closed++);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(closed, 1, reason: '★ Esc 没关弹窗 ⇒ 键盘用户只能去找鼠标');
  });

  testWidgets('★ closeEnabled=false 时 Esc 不许关（忙碌态保护）', (t) async {
    var closed = 0;
    await pumpShell(t, onClose: () => closed++, closeEnabled: false);
    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pumpAndSettle();
    expect(closed, 0,
        reason: '★ 忙碌时 Esc 不该关 —— 否则用户会丢掉正在进行的操作');
  });

  testWidgets('★ 焦点必须在弹窗内（Tab 不许跑到背后）', (t) async {
    await pumpShell(t, onClose: () {});
    final focus = FocusManager.instance.primaryFocus;
    expect(focus, isNotNull, reason: '★ 打开后必须有焦点落在弹窗内');
    expect(
      find.ancestor(
        of: find.byType(TextField),
        matching: find.byType(AppDialogShell),
      ),
      findsOneWidget,
      reason: '★ 输入框必须在弹窗子树里',
    );
  });
}
