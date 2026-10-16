// ★ 弹窗外壳的键盘交互门禁（Owner 第 8 条「交互都很烂」）
//
// 钉四件事：
//   ① Esc 能关（且 closeEnabled=false 时不关）
//   ② 弹窗里注册了 FocusTraversalGroup（焦点圈的实现）
//   ③ 真做一次 Tab 遍历，焦点不跑出弹窗
//   ④ ★ busy 时点遮罩也不许关（三条关闭路径必须同判据）
//
// ⚠️ 2026-10-17（CodeRabbit CR）修复两处假绿/真 bug：
//   ③ 改前只断言「输入框是外壳的后代」—— 树结构，与焦点无关
//      （删掉 FocusTraversalGroup 后照样绿）。
//   ④ 改前「点遮罩」这条路径**没检查 closeEnabled** ⇒ busy 时点背景仍能关。
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
        // 两个可聚焦控件 ⇒ Tab 真的能走
        child: const Column(
          children: [
            TextField(autofocus: true),
            TextField(),
          ],
        ),
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

  testWidgets('★★ busy 时点遮罩也不许关', (t) async {
    var closed = 0;
    await pumpShell(t, onClose: () => closed++, closeEnabled: false);
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(closed, 0,
        reason: '★ busy 时点遮罩关了面板 ⇒ 三条关闭路径判据不一致');

    // ★ 阳性对照：不 busy 时点同一位置必须关
    var closed2 = 0;
    await pumpShell(t, onClose: () => closed2++);
    await t.tapAt(const Offset(5, 5));
    await t.pumpAndSettle();
    expect(closed2, 1,
        reason: '阳性对照：非 busy 时点遮罩必须能关（否则上面那条是空的）');
  });

  testWidgets('★ 弹窗里必须注册 FocusTraversalGroup（焦点圈的实现）', (t) async {
    await pumpShell(t, onClose: () {});
    final groups = find.descendant(
      of: find.byType(AppDialogShell),
      matching: find.byType(FocusTraversalGroup),
    );
    expect(groups, findsWidgets,
        reason: '★ 没有 FocusTraversalGroup ⇒ Tab 会跑到背后的页面上');
  });

  testWidgets('★★ Tab 遍历：焦点必须始终留在弹窗内', (t) async {
    await pumpShell(t, onClose: () {});
    expect(FocusManager.instance.primaryFocus, isNotNull,
        reason: '阳性对照：打开后必须有焦点（否则下面扫的是空气）');

    for (var i = 0; i < 6; i++) {
      await t.sendKeyEvent(LogicalKeyboardKey.tab);
      await t.pumpAndSettle();

      final f = FocusManager.instance.primaryFocus;
      expect(f, isNotNull, reason: '★ 第 ${i + 1} 次 Tab 后焦点不该消失');

      var insideShell = false;
      f!.context?.visitAncestorElements((e) {
        if (e.widget is AppDialogShell) {
          insideShell = true;
          return false;
        }
        return true;
      });
      expect(insideShell, isTrue,
          reason: '★ 第 ${i + 1} 次 Tab 后焦点跑出弹窗了 ⇒ 键盘用户会失联');
    }
  });
}
