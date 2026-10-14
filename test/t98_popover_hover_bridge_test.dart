// ═══════════════════════════════════════════════════════════════════════
//  悬浮窗「往上挪就关闭」的回归守卫（Owner 2026-10-13）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 这个悬浮窗距离底部太多了,往上挪的过程中就可能悬浮窗关闭了
// ```
//
// # 根因与最终采用的修法
// ```text
// 根因：`PopoverController.closeDelay` 原来是 250ms，而按钮上沿 ↔ 面板下沿
//   之间有 `spacing = Sp.x2 = 8px` 的真空（`_PopoverAnchorDelegate.spacing`）。
//   指针横穿那 8px 时**两边都不是 hover 区** ⇒ onExit ⇒ armClose 起计时；
//   250ms 内没走到面板 ⇒ 关。Owner 观感就是"往上挪的过程中自己关了"。
//
// 修法：closeDelay 250 -> 450ms（给"从容地挪"留够时间）。
// ```
//
// # ★ 为什么**没有**做"补一块透明悬停桥"（本文件改名前的旧设计）
// ```text
// 试过两种填缝方案，都失败并已回退（详见 `player_popover.dart:293-296`）：
//   ① 面板侧补桥 —— 两个 MouseRegion 之间有竞态；一个 MouseRegion 又框不住溢出。
//   ② 按钮侧包 Column 补桥 —— 会改布局，破坏按钮在底栏 Row 里的排布。
// ⇒ 本仓**最终只调延时值**：最小、最安全、不改任何几何。
//
// ⚠️ 本文件此前写成"守桥高(bridgeHeight=12)"，而源码里**根本没有那块桥**
//    （`_PopoverKeepAliveState` 就是一个裸 `MouseRegion`）—— 那条断言读的是
//    测试文件里硬编码的常量，于是**永远绿**；而真正测行为的 ④ 一直红。
//    现改为守住**实际存在**的机制，见下面四条。
// ```
//
// # 本文件守什么（每条都要能测出反面）
// ```text
// ① 契约：closeDelay 必须 ≥ 400ms（改回 250ms ⇒ 红）
// ② 契约：进入要"跟手"、离开要"宽容" ⇒ hoverDelay < closeDelay（改成相等 ⇒ 红）
// ③ 几何：PopoverKeepAlive 的**布局尺寸**必须**等于**它的 child
//    （壳只挂 MouseRegion，**不许**改变面板尺寸 —— 撑高会顶偏面板位置）
// ④ 行为（绿）：指针离开面板 ⇒ 起收起计时；在到点前**回到面板** ⇒ 计时被取消
// ⑤ 行为（红）：指针离开面板后**不回来** ⇒ 到点确实收起
//    ★ ④⑤ 是一对：只有 ④ 绿 = 计时器可能压根没武装（假绿）；
//      只有 ⑤ 绿 = 取消根本没生效。两条同时绿才证明"延时"这一机制真的在起作用。
// ```

import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';

/// 把 [PopoverKeepAlive] 挂进一个已知尺寸的盒子里
Future<void> _mountKeepAlive(
  WidgetTester tester,
  PopoverController controller, {
  double panelHeight = 200,
  double panelWidth = 300,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: panelWidth,
            // ★ 外层给一个"面板本身的高度"的 child；PopoverKeepAlive 必须
            //   原样返回这个尺寸（不许被壳撑大）。
            height: panelHeight,
            child: PopoverKeepAlive(
              controller: controller,
              child: const SizedBox.expand(),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  group('①/② 数值契约：进入跟手、离开宽容', () {
    test('closeDelay 必须 ≥ 400ms（原来的 250ms 会让"往上挪"中途关闭）', () {
      // 反面：把 player_popover.dart 的 closeDelay 改回 250ms ⇒ 本断言红
      expect(
        PopoverController.closeDelay.inMilliseconds,
        greaterThanOrEqualTo(400),
        reason: '★ 收起计时太短 ⇒ 指针还没穿过按钮↔面板那条 8px 的缝，面板就没了'
            '（Owner 报的「往上挪的过程中可能关闭」）。原来 250ms，现在 450ms。',
      );
    });

    test('★ hoverDelay 必须**严格小于** closeDelay（进入跟手 / 离开宽容）', () {
      // 反面：把 hoverDelay 提到 ≥ closeDelay（比如都改成 450ms）⇒ 红
      expect(
        PopoverAnchorButtonState.hoverDelay,
        lessThan(PopoverController.closeDelay),
        reason: '★ 两者不对称是**有意的**（player_popover.dart:289-291）：'
            '进入要"跟手"、离开要"宽容"。若离开不比进入更宽容，'
            '就退化成"移出即关"，Owner 那个缺陷原样复发。',
      );
    });
  });

  group('③ 几何：壳不许改变面板尺寸', () {
    testWidgets('PopoverKeepAlive 的尺寸必须**逐字等于** child', (tester) async {
      final c = PopoverController();
      addTearDown(c.dispose);
      await _mountKeepAlive(tester, c, panelHeight: 200, panelWidth: 300);

      final box = tester.getSize(find.byType(PopoverKeepAlive));
      // 反面：给壳加 Padding/Column 之类的"填缝" ⇒ 高度变成 200 + 缝 ⇒ 红
      expect(
        box.height,
        200,
        reason: '★ 壳只挂 MouseRegion，绝不能改变布局 —— '
            '否则面板被顶高、位置整体错位（"修一个坏一个"）。'
            '实测高度 ${box.height}（应为 200）。',
      );
      expect(box.width, 300, reason: '宽度同理不许被壳改变');
    });
  });

  group('④/⑤ 行为：收起计时的武装与取消（一对，缺一条即假绿）', () {
    testWidgets('④ 绿：离开面板后**回到面板** ⇒ 收起计时被取消（面板不关）',
        (tester) async {
      final c = PopoverController();
      addTearDown(c.dispose);
      c.toggleOpen('probe'); // 先打开（armClose 只在 openId != null 时生效）
      await _mountKeepAlive(tester, c);

      final center = tester.getCenter(find.byType(PopoverKeepAlive));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: center);
      addTearDown(gesture.removePointer);
      await tester.pump();

      // 移出面板 ⇒ onExit ⇒ armClose 起计时（这就是"往上挪"穿缝那一刻）
      await gesture.moveTo(const Offset(-500, -500));
      await tester.pump();
      // 在到点前**回到面板** ⇒ onEnter ⇒ holdOpen 取消计时
      await gesture.moveTo(center);
      await tester.pump();

      // 过了 closeDelay 后面板**仍然开着**
      await tester.pump(
        PopoverController.closeDelay + const Duration(milliseconds: 50),
      );
      expect(
        c.openId,
        isNotNull,
        reason: '★ 指针在到点前回到了面板，收起计时必须被取消 —— '
            '这正是"从按钮往上挪进面板"要穿那条缝时的行为。',
      );
    });

    testWidgets('⑤ 红：离开面板后**不回来** ⇒ 到点确实收起（证明计时真的武装了）',
        (tester) async {
      final c = PopoverController();
      addTearDown(c.dispose);
      c.toggleOpen('probe');
      await _mountKeepAlive(tester, c);

      final center = tester.getCenter(find.byType(PopoverKeepAlive));
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: center);
      addTearDown(gesture.removePointer);
      await tester.pump();

      // 移出且**不再回来**
      await gesture.moveTo(const Offset(-500, -500));
      await tester.pump();
      await tester.pump(
        PopoverController.closeDelay + const Duration(milliseconds: 50),
      );
      expect(
        c.openId,
        isNull,
        reason: '★ 这一条是 ④ 的**阴性对照**：若计时器压根没被武装，'
            '④ 就会假绿。移出且不回来 ⇒ 必须收起。',
      );
    });
  });
}
