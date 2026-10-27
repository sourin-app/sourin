// test/zz_t1058_playback_owner_badge_render_test.dart
//
// ══════════════════════════════════════════════════════════════════════════
//  N5b 行为级：归属徽标**真的上屏**（2026-10-27）
// ══════════════════════════════════════════════════════════════════════════
//
// # 为什么纯函数门禁（t1057）不够
// ```text
// t1057 只证明 `ownerOf(kind)` 的映射对 —— 但**映射对 ≠ 界面显示**。
// 典型的假绿形态：
//   · 徽标写了却没挂进 build（类是死的）
//   · 挂了但条件是 `if (failure == null)`（永远不画）
//   · 挂了但顺序在正文**之后**（用户先读一堆原文才看到分诊）
// ⇒ 本文件把真的 `PlaybackFailure` 交给**产线那个 widget**
//   （`PlayerErrorCardForProbe`，零逻辑转发 `_ErrorOverlay`），
//   再读真的 widget 树。
// ```
//
// # 守什么
// ```text
// ① 七档逐档：每档渲染出的归属文案 == ownerOf(kind).label（真树上的文本）
// ② 顺序：归属徽标必须在 headline **之下**、正文 **之上**
//    （分诊必须早于细节）
// ③ 没归类（failure == null）⇒ 树上**找不到**任何归属徽标（不许猜）
// ④ 徽标只有一个（不许重复渲染）
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/player_page.dart';

const ValueKey<String> kBadgeKey = ValueKey<String>('playback-owner-badge');

Widget host(PlaybackFailure? failure) => MaterialApp(
  home: Scaffold(
    body: PlayerErrorCardForProbe(
      failure: failure,
      onRetry: () {},
      onBack: () {},
    ),
  ),
);

void main() {
  testWidgets('★★★ 七档逐档：真树上渲染出的归属文案与 ownerOf(kind).label 逐档一致',
      (t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));

    for (final kind in PlaybackFailureKind.values) {
      final f = PlaybackFailure(kind: kind, detail: '原文夹具');
      await t.pumpWidget(host(f));
      await t.pump();

      final badges = find.byKey(kBadgeKey, skipOffstage: false);
      expect(badges, findsOneWidget,
          reason: '★★★ 档位 $kind 必须渲染出**恰好一个**归属徽标 —— '
              '0 个说明徽标没挂进 build（纯函数对但界面不显示＝假绿）');

      expect(
        find.descendant(of: badges, matching: find.text(ownerOf(kind).label)),
        findsOneWidget,
        reason: '★ 档位 $kind 的徽标文案必须是 ${ownerOf(kind).label}',
      );
    }
  });

  testWidgets('★★★ 顺序：归属徽标在 headline 之下、正文之上（分诊早于细节）',
      (t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));

    /*
     * ⚠️ 夹具的 detail **不许**与 `headline` 文本相同 ——
     * 否则 `find.text(f.detail)` 会同时命中标题行与正文行（两处），
     * `getRect` 报 "ambiguously found multiple matching widgets"。
     * 第一版就踩了这个（fixture 写成了 `'这一条流取不到'`，
     * 而 proxy 档的 headline 逐字也是它）。
     */
    const f = PlaybackFailure(
      kind: PlaybackFailureKind.proxy,
      detail: '夹具原文：这条流的转发在 3 次重试后仍然失败，源站没有给出更多信息',
    );
    await t.pumpWidget(host(f));
    await t.pump();

    final badgeY = t.getRect(find.byKey(kBadgeKey)).top;
    final headlineY = t.getRect(find.text(f.headline)).top;
    final bodyY = t.getRect(find.text(f.detail)).top;

    expect(headlineY, lessThan(badgeY),
        reason: '★★★ 归属必须在 headline（发生了什么）**下面** —— '
            '用户先要知道发生了什么，再问这是谁的锅');
    expect(badgeY, lessThan(bodyY),
        reason: '★★★ 归属必须在正文（插件原文）**上面** —— '
            '反过来就是"先读一堆细节再告诉你是谁的问题"，认知顺序是反的');
  });

  testWidgets('★★★ 没归类（failure == null）⇒ 树上找不到归属徽标（不许猜）',
      (t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(host(null));
    await t.pump();

    expect(
      find.byKey(kBadgeKey, skipOffstage: false),
      findsNothing,
      reason: '★★★ 没归类就不许画归属 —— 归属判断错了比不显示更糟；'
          '注入「failure == null 时也塞一个默认归属」本条立刻红',
    );
    // 对照：树本身是活的（否则上面那条恒真）
    expect(find.text('播放失败'), findsOneWidget,
        reason: '★ 对照：没归类时仍走 headline 默认文案 ⇒ 证明树渲染了，'
            '上面那条 findsNothing 不是"整棵树是空的"造成的');
  });

  testWidgets('★★ 阴性对照：本片源自带那类"没归类"路径不许被兜底成某个归属', (t) async {
    await t.binding.setSurfaceSize(const Size(900, 700));
    addTearDown(() => t.binding.setSurfaceSize(null));

    await t.pumpWidget(host(null));
    await t.pump();

    for (final o in PlaybackFailureOwner.values) {
      expect(find.text(o.label), findsNothing,
          reason: '★ 没归类时任何归属文案都不许出现（兜底归属＝猜）');
    }
  });
}