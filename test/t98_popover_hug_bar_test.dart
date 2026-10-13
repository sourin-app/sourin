// ═══════════════════════════════════════════════════════════════════════
//  悬浮窗「贴紧底栏」+「不再往上挪就关闭」的回归守卫（Owner 2026-10-13）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 这个悬浮窗距离底部太多了,往上挪的过程中就可能悬浮窗关闭了
// ```
// 追问后明确：**贴紧底栏（去掉 8px 缝）**。
//
// # 两条根因（都已修，本文件各钉一组）
// ```text
// ① 「距离底部太多」= 两个数都错了：
//    a. `_kPlayerBottomBarHeight` 填 96，**真实底栏高 106**
//       （`getRect(PlayerBottomBar)` = Rect(0,794,1280,900)）
//       ⇒ popover 层底边钻进底栏 10px ⇒ 面板被顶高 10px。
//    b. `_PopoverAnchorDelegate` 竖向留白用 `spacing`(8px)，
//       且贴的是**按钮上沿** —— 而按钮在底栏里偏下
//       ⇒ 面板底边又高 8px + 贴按钮（比底栏顶还高）。
//    ⇒ 修：常量 96→106、竖向留白改 0、底边改贴**层底**（= 底栏上沿）。
// ② 「往上挪就关闭」= `PopoverController.closeDelay` 只有 250ms，
//    而按钮↔面板之间有一段真空，指针横穿时起计时，没走到就关了。
//    ⇒ 修：450ms。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart'
    show PlayerBottomBar, PlayerMoreMenuData;
import 'package:sourin_spike/ui/player/player_popover.dart'
    show PopoverController;
import 'package:sourin_spike/ui/tokens.dart';

/// 读源码（与其它源码扫描测试同款；测试 cwd = 仓库根）
String _src(String p) {
  final f = File(p);
  return f.existsSync() ? f.readAsStringSync() : '';
}

/// ★ 从**源码**实测 `_kPlayerBottomBarHeight`，不手抄
///
/// ⚠️ 手抄正是原来那个缺陷的成因：常量写 96、文件里另一半注释写"高约 106"，
///    两处互相矛盾而无人钉。本函数把"读到真值"变成断言前提。
double _constFromSource() {
  final m = RegExp(r'const double _kPlayerBottomBarHeight = ([0-9.]+);')
      .firstMatch(_src('lib/ui/player_page.dart'));
  expect(m, isNotNull,
      reason: '★ 找不到 `_kPlayerBottomBarHeight` 常量 —— 被改名/删了？'
          '本测试的前提没了，先修测试。');
  return double.parse(m!.group(1)!);
}

void main() {
  group('① 数值契约：底栏高度与收起计时', () {
    test('★ `_kPlayerBottomBarHeight` 必须 = 底栏**真实**高度', () {
      /*
       * 这条是**不变量**而不是"抄一个数"：它当场把底栏渲染出来量高度，
       * 再与源码里的常量比。
       * 反面：把常量改回 96 ⇒ 96 != 106 ⇒ 红。
       *
       * ⚠️ 量高度需要 widget 测试（见下一组），这里先做一个**源码自检**：
       *    常量必须与 player_bottom_bar.dart 注释里写的"高约 Npx"一致
       *    —— 两者曾长期矛盾（96 vs 106）。
       */
      final v = _constFromSource();
      final doc = _src('lib/ui/player/player_bottom_bar.dart');
      final note = RegExp(r'高约 (\d+)px').firstMatch(doc);
      if (note != null) {
        expect(
          v,
          double.parse(note.group(1)!),
          reason: '★★★ 常量与同仓注释里的"高约 Npx"必须一致 —— '
              '它们曾分别是 96 与 106，谁也没报错，直到 Owner 说'
              '「悬浮窗距离底部太多」才被发现。',
        );
      }
      expect(v, greaterThan(0));
    });

    testWidgets('★ 真渲染：底栏高度必须 = 常量（96 就是错的）', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final c = PopoverController();
      addTearDown(c.dispose);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(children: <Widget>[
            PlayerBottomBar(
              controller: c,
              playing: false,
              positionListenable: ValueNotifier(Duration.zero),
              duration: const Duration(minutes: 1),
              isLive: false,
              rate: 1,
              volume: 1,
              muted: false,
              fullscreen: false,
              onTogglePlay: () {},
              onSeek: (_) {},
              onVolume: (_) {},
              onToggleMute: () {},
              onRate: (_) {},
              onToggleFullscreen: () {},
              onEpisodes: () {},
              hasEpisodes: false,
              showEpisodeNav: false,
              onNext: () {},
              hasNext: false,
              more: const PlayerMoreMenuData(groups: []),
            ),
          ]),
        ),
      ));
      await tester.pump();

      final real = tester.getSize(find.byType(PlayerBottomBar)).height;
      expect(
        _constFromSource(),
        real,
        reason: '★★★ `_kPlayerBottomBarHeight` 必须等于底栏真实高度。'
            '实测底栏高 $real。原来常量是 96（比真值小 10）'
            '⇒ popover 层底边钻进底栏 10px ⇒ 面板被顶高、'
            'Owner 看到的就是"悬浮窗距离底部太多"。',
      );
    });

    test('★ 收起延时必须 ≥ 400ms（原 250ms 会让"往上挪"中途关闭）', () {
      // 反面：把 PopoverController.closeDelay 改回 250ms ⇒ 红
      expect(
        PopoverController.closeDelay.inMilliseconds,
        greaterThanOrEqualTo(400),
        reason: '★ 按钮↔面板之间有真空，指针横穿要时间；'
            '250ms 不给够 ⇒ 还没进面板就收起（Owner 报的'
            '「往上挪的过程中就可能悬浮窗关闭了」）。',
      );
    });
  });

  group('② 定位契约：竖向留白必须是 0（贴层底）', () {
    test('★ 面板底边贴 **层底**，不再贴按钮上沿 + 8px', () {
      /*
       * 源码级判据（这层没有可 import 的常量，直接扫源码）：
       *   · `desiredBottom` 必须取 `size.height`（层底）
       *   · `maxTop` 的竖向留白必须是 **0**（不是 `spacing`）
       * 反面：把 `maxTop` 改回 `size.height - spacing - childSize.height`
       *       ⇒ 面板底边 = 层底 - 8 ⇒ 红（实测过：面板停在 796 而非 804）。
       */
      final src = _src('lib/ui/player/player_bottom_bar.dart');
      expect(
        src.contains('final desiredBottom = size.height;'),
        isTrue,
        reason: '★ 竖向基准必须是**层底**（= 底栏上沿）—— Owner 1013「贴紧底栏」。'
            '原来贴的是按钮上沿（`a.top - spacing`），而按钮在底栏里偏下 ⇒ 悬空。',
      );
      expect(
        src.contains('final maxTop = size.height - childSize.height;'),
        isTrue,
        reason: '★★★ 竖向留白必须为 **0**：真正夹住面板的是 `maxTop`，'
            '不是 `desiredBottom`（我第一版只改后者，面板一个像素没动 —— '
            '因为被这里夹回去了）。改回 `- spacing` ⇒ 面板底边离层底 8px ⇒ 红。',
      );
      // 反向守卫：这两处**不许**再出现旧的 spacing 留白写法
      expect(
        RegExp(r'final maxTop = size\.height - spacing - childSize\.height;')
            .hasMatch(src),
        isFalse,
        reason: '★ 旧的 8px 竖向留白不许回来（那正是"距离底部太多"的一半）。',
      );
    });
  });

  group('③ 横向契约不变（Owner 1011 第 4 条，别顺手改坏）', () {
    test('横向仍按按钮中心居中', () {
      final src = _src('lib/ui/player/player_bottom_bar.dart');
      expect(
        src.contains('a.center.dx - childSize.width / 2'),
        isTrue,
        reason: '★ Owner 只说了"离底部太多"，横向居中一个字都不许动。',
      );
    });

    test('横向 clamp 仍用 spacing（别把 spacing 改成 0）', () {
      final src = _src('lib/ui/player/player_bottom_bar.dart');
      expect(
        src.contains('final minLeft = spacing;') &&
            src.contains('final maxLeft = size.width - spacing - childSize.width;'),
        isTrue,
        reason: '★ `spacing` 还管着"面板别顶到窗口左右边缘"——'
            '若为凑"贴底"把它也改成 0，贴边时面板会顶到窗口边缘、看着挤。',
      );
    });
  });
}
