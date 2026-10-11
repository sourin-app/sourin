// ═══════════════════════════════════════════════════════════════════════
//  Owner 2026-10-11 第 2 条（第三次报）：「从播放页返回还是非常卡顿」
//  + Owner 追加：「缓存下来不用重建，是不是能缓冲很大压力」
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件守什么（`lib/ui/widgets/my_shelf.dart::load()` 的数据指纹守卫）
//
// 根因（`.probe/zz_return_quant_probe_test.dart` 同 run 因果 A/B 实测）：
// ```text
// 从播放页 pop 回来的**第 2 帧**重建 458 个元素（墙钟 25~42ms）；
// 关掉「返回自动刷新」⇒ 458 → 61（−87%）、墙钟 → 6~9ms。
// ⇒ 那 397 个元素全来自 `load()` 尾巴上**无条件**的 setState ——
//   刚看完片返回，三份数据**一个字节都没变**，却把整棵「我的」子树
//   （液态玻璃 tab + 卡片 SliverList）重建了一遍。
// ```
//
// # 为什么必须**双向**断言（只测一半是最危险的）
// ```text
// ① 数据没变 ⇒ 不重建   ← 本次修复的交付物（性能）
// ② 数据变了 ⇒ 必须重建 ← 刷新语义不许被守卫吃掉（正确性）
// ```
// 只守 ① 的守卫若写成"永远不 setState"，测试照样绿，但返回后
// 收藏/追更的新数据**永远不会出现** —— 那是比卡顿更严重的回归。
//
// ⚠️ 用 `debugShelfLoadOverride` 喂数据（FFI 在 flutter_test 里恒失败，
//    测不到"成功且数据变了"这一路）。
@Tags(['native-media'])
library;
// ignore_for_file: avoid_print

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

Favorite fav(String id, String title, {int unread = 0}) => Favorite(
      key: 'cctv:$id',
      provider: 'cctv',
      nativeId: id,
      title: title,
      following: true,
      unreadCount: unread,
    );

Progress prog(String id, String title, {int pos = 120}) => Progress(
      key: 'cctv:$id',
      provider: 'cctv',
      nativeId: id,
      title: title,
      position: pos,
      duration: 600,
    );

Future<void> _mount(WidgetTester t, GlobalKey<MyShelfState> key) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MyShelf(
          key: key,
          onOpenDetail: (_, __) {},
          onPlay: (_, __, ___, ____, _____) {},
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

void main() {
  tearDown(() {
    debugOnRebuildDirtyWidget = null;
    debugShelfLoadOverride = null;
  });

  testWidgets('① 数据没变 ⇒ load() 不重建「我的」子树（卡顿修复交付物）',
      (t) async {
    final key = GlobalKey<MyShelfState>();
    await _mount(t, key);

    // 先注入初始数据（绕 FFI）
    final seed = [fav('a1', '追更片', unread: 2)];
    key.currentState!.debugSetData(following: seed, favorites: seed);
    await t.pump();

    // 之后每次 load() 都返回**等价**数据（新对象、内容相同 —— 模拟后端每次反序列化）
    debugShelfLoadOverride = () async => (
          [fav('a1', '追更片', unread: 2)],
          [fav('a1', '追更片', unread: 2)],
          <Progress>[],
        );

    // ── 阳/阴对照：先证明仪器看得见重建（阳性），再证明"没变不重建"（被测）──
    // 阴性对照：静置一帧，不该有任何重建
    var n = 0;
    debugOnRebuildDirtyWidget = (Element e, bool b) => n++;
    await t.pump();
    print('Q1|阴性对照（静置）重建=$n');
    final neg = n;
    debugOnRebuildDirtyWidget = null;
    expect(neg, 0, reason: '静置帧不该重建 —— 否则仪器或页面有问题');

    // ★ 被测行为：load() 拿到**等价**数据 ⇒ 不 setState ⇒ 0 重建
    n = 0;
    debugOnRebuildDirtyWidget = (Element e, bool b) => n++;
    await key.currentState!.load();
    await t.pump();
    final unchanged = n;
    debugOnRebuildDirtyWidget = null;
    print('Q1|数据未变 load() 后重建=$unchanged');

    // ★ 阳性对照：数据**变了** ⇒ 必须重建（证明仪器有区分力 + 刷新语义仍在）
    debugShelfLoadOverride = () async => (
          [fav('a1', '追更片', unread: 9)], // ← unread 变了
          [fav('a1', '追更片', unread: 9)],
          <Progress>[],
        );
    n = 0;
    debugOnRebuildDirtyWidget = (Element e, bool b) => n++;
    await key.currentState!.load();
    await t.pump();
    final changed = n;
    debugOnRebuildDirtyWidget = null;
    print('Q1|数据已变 load() 后重建=$changed');

    expect(changed, greaterThan(0),
        reason: '★★ 阳性对照失败 ⇒ 仪器没有区分力 ⇒ 上面的"0"证明不了任何事');
    expect(unchanged, 0,
        reason: '★★★ 数据没变却重建了「我的」子树 —— 这正是 Owner 报的'
            '「从播放页返回卡顿」：每次返回都无条件重建整棵树。'
            '实测该帧 458 个元素 / 25~42ms。');
  });

  testWidgets('①b 数据变了（新增收藏）⇒ 卡片真的出现在屏幕上', (t) async {
    final key = GlobalKey<MyShelfState>();
    await _mount(t, key);

    debugShelfLoadOverride = () async => (
          <Favorite>[],
          <Favorite>[],
          <Progress>[],
        );
    key.currentState!.debugSetData(tab: ShelfTab.following);
    await t.pump();
    await key.currentState!.load();
    await t.pump();
    expect(find.text('新追更片'), findsNothing,
        reason: '前置：开始时不该有这张卡（否则下面的"出现了"证明不了什么）');

    // 数据变了：新增一条
    debugShelfLoadOverride = () async => (
          <Favorite>[],
          [fav('x9', '新追更片')],
          <Progress>[],
        );
    await key.currentState!.load();
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('新追更片'), findsOneWidget,
        reason: '★ 数据变了却没更新到屏幕 ⇒ 刷新语义被守卫吃掉了（漏刷新）');
  });

  testWidgets('①c 数据变了（进度位置变）⇒ 历史卡片的进度更新', (t) async {
    final key = GlobalKey<MyShelfState>();
    await _mount(t, key);

    debugShelfLoadOverride = () async => (
          <Favorite>[],
          <Favorite>[],
          [prog('h1', '历史片', pos: 120)],
        );
    key.currentState!.debugSetData(tab: ShelfTab.history);
    await t.pump();
    await key.currentState!.load();
    await t.pump();
    expect(find.text('历史片'), findsOneWidget, reason: '前置：历史卡要在');

    // 进度位置变了 —— 「渲染指纹」必须能捕捉到
    debugShelfLoadOverride = () async => (
          <Favorite>[],
          <Favorite>[],
          [prog('h1', '历史片', pos: 480)],
        );
    final before = key.currentState!.debugSignatureForTest();
    await key.currentState!.load();
    await t.pump();
    final after = key.currentState!.debugSignatureForTest();
    expect(after, isNot(equals(before)),
        reason: '★ 进度位置变了但渲染指纹没变 ⇒ 守卫会漏刷新（卡片停在旧进度）');
  });
}
