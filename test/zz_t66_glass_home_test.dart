// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 M 批次：首页卡片玻璃化门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件守什么（三条，都是"改完不能退化"的功能判据）
// ```text
// ① 卡片仍然是**可点的**（onTap 真的触发）—— 玻璃化不许吃掉点击
// ② 未读数仍然**高对比**（红底白字，不走玻璃）—— 这是我自己造过又修掉的缺陷
// ③ 角标（装饰性）**真的走玻璃**（GlassChip 存在）—— 否则等于没玻璃化
// ```
//
// # 为什么②要单独立一条
// ```text
// 我第一版把未读数也换成玻璃，把 AppColors.badge（红）当**文字色**叠在深色玻璃上
// ⇒ 截图 `.probe/shots/t66/t66_card_after_chip.png` 里那个「7」几乎看不见。
// 原来"红底白字"对比度很高 ⇒ 这是**功能退化**，不是审美取舍。
// ⇒ 立一条断言把它钉死，防止将来又有人"为了统一而全玻璃"。
// ```
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/poster_card.dart';

Widget host(Widget child) => MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        backgroundColor: const Color(0xFF14151A),
        body: Center(child: SizedBox(width: 168, child: child)),
      ),
    );

void main() {
  group('M 批次：PosterCard 玻璃化不变量', () {
    testWidgets('① 卡片仍然可点（玻璃化没吃掉 onTap）', (t) async {
      var tapped = 0;
      await t.pumpWidget(host(
        PosterCard(
          title: '样本标题',
          subtitle: '更新至 1 集',
          onTap: () => tapped++,
        ),
      ));
      await t.pump();
      await t.tap(find.byType(PosterCard));
      await t.pump();
      expect(tapped, 1, reason: '★ 玻璃化后卡片必须仍然可点');
    });

    testWidgets('② 未读数**不走玻璃**，保持不透明红底（对比度优先）', (t) async {
      await t.pumpWidget(host(
        const PosterCard(
          title: '样本标题',
          unread: 7,
          onTap: _noop,
        ),
      ));
      await t.pump();

      // 未读数「7」必须可见
      expect(find.text('7'), findsOneWidget,
          reason: '★ 未读数必须渲染出来');

      /*
       * ★ 判据：未读数**不能**被包在 GlassChip 里。
       * 做法：找「7」的祖先链里有没有 GlassChip —— 有就是退化了。
       */
      final glassAncestors = find.ancestor(
        of: find.text('7'),
        matching: find.byType(GlassChip),
      );
      expect(glassAncestors, findsNothing,
          reason: '★★ 未读数不许走玻璃 —— 深色玻璃底 + 红色文字'
              '在截图里几乎看不见（这是实测抓到的真实退化）。'
              '未读数是功能性信号，可读性优先于通透感。');
    });

    testWidgets('③ 角标（装饰性）**真的走玻璃**', (t) async {
      await t.pumpWidget(host(
        const PosterCard(
          title: '样本标题',
          badge: 'HD',
          onTap: _noop,
        ),
      ));
      await t.pump();

      expect(find.text('HD'), findsOneWidget, reason: '角标文字必须可见');
      expect(
        find.ancestor(
          of: find.text('HD'),
          matching: find.byType(GlassChip),
        ),
        findsOneWidget,
        reason: '★ 角标必须真的用 GlassChip（否则等于没玻璃化）',
      );
    });

    testWidgets('④ 无角标/无未读时不许凭空多出玻璃层', (t) async {
      await t.pumpWidget(host(
        const PosterCard(title: '样本标题', onTap: _noop),
      ));
      await t.pump();
      expect(find.byType(GlassChip), findsNothing,
          reason: '★ 没有角标就不该有 GlassChip（省一次模糊计算）');
    });

    testWidgets('⑤ 卡片几何不因玻璃而变（t50a C5 的同款判据）', (t) async {
      // 有角标
      await t.pumpWidget(host(
        const PosterCard(
          title: '样本标题',
          subtitle: '更新至 1 集',
          titleLines: 2,
          badge: 'HD',
          unread: 7,
          onTap: _noop,
        ),
      ));
      await t.pump();
      final withChips = t.getRect(find.byType(PosterCard));

      // 无角标
      await t.pumpWidget(host(
        const PosterCard(
          title: '样本标题',
          subtitle: '更新至 1 集',
          titleLines: 2,
          onTap: _noop,
        ),
      ));
      await t.pump();
      final withoutChips = t.getRect(find.byType(PosterCard));

      expect(withChips.width, withoutChips.width,
          reason: '★ 角标是 Positioned（不进布局）⇒ 宽度必须完全一致');
      expect(withChips.height, withoutChips.height,
          reason: '★ 角标不许撑高卡片');
    });
  });
}

void _noop() {}
