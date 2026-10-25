// ═══════════════════════════════════════════════════════════════════════
//  第 17 项（缺口 3）：视频**层**是否被留白层包住 —— 从祖先链断言
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么原来的判据不够（复核查到的真缺口）
// ```text
// `live_video_fill_test.dart` 只量「外层槽位 == 黑底」——
// 而把 `AspectRatio` / `Padding` / `Center` / `FittedBox` 套在**槽位内部**
// （即包住 `Video` 那一层）时，外层槽位仍然等于黑底 ⇒ 那个文件**照样全绿**。
// ⇒ 缺口在"槽位**内部**"这一段，必须从 `Video`（视频层）那一端往下量。
// ```
//
// # 本文件怎么验
// ```text
// ① 叶子矩形 == 播放器黑底矩形（4 种窗口尺寸）—— 视频层铺满容器
// ② 叶子到 `Positioned.fill` 之间**不许**出现任何留白层
//    （AspectRatio / Padding / Center / FittedBox / Align / FractionallySizedBox）
// ③ 叶子**直接**父级就是 `Positioned.fill(key: liveVideoSlotKey)`
//    （四条边都是 0 ⇒ 真·fill，不是 `Positioned(left: 8, …)`）
// ```
//
// # 2026-10-26 追加：与**全屏侧**的三层对照（第 17 项最后的边界）
// ```text
// ① 结构：内嵌 = `Positioned.fill > 叶子`（无中间层，已由 ② ③ 钉住）
//          全屏 = `Positioned.fill > Center > Video`（`player_page.dart:15700`）
//          ⇒ **不同构**（全屏多一个 `Center`）。本文件用**源码判据**把这件事钉住：
//            不是"谁错了"，而是"两边结构不同，必须记录"。
// ② 几何：内嵌用注入叶子量 4 种尺寸（叶子矩形 == 槽位矩形、上下无黑边）；
//          全屏**量不了**（`Video` 要 libmpv，`flutter test` 里挂不起来）⇒ 如实留空。
// ③ 一致性：内嵌 fit 常量 == `BoxFit.contain`；全屏 `Video(...)` **不传 `fit:`**
//          ⇒ 吃 media_kit 默认（也是 contain）；两者语义相同、写法不同。
// ```

// # ⚠️ 这里**没有**验什么（如实写，不宣称）
// ```text
// `Video` 本体在 `flutter test` 里**挂不起来**：它要 `VideoController` → `Player()`
// → libmpv，而测试环境加载 libmpv 会让 flutter_tester 偶发 native 崩溃
// （`dart_test.yaml` 因此默认 skip `native-media`）。
// ⇒ 本文件用一个**同位置的叶子**（`debugVideoSlotOverride`，生产恒 null）
//   替换"视频层"，验的是**容器与祖先链**这一层；
//   「真实视频纹理的显示尺寸 / 片源自带黑边到底多少像素」仍然**缺真实流**。
// ★ 这是"能证的证到底、不能证的说清楚"，不是"用替身假装验过视频"。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 注入的"视频层"替身 —— 位置与 `Video` **完全相同**
const _leafKey = ValueKey('probe-video-leaf');

const _sizes = <Size>[
  Size(320, 180),
  Size(360, 202.5),
  Size(480, 270),
  Size(640, 360),
];

void main() {
  setUp(() {
    // 只替换槽位里的**叶子**；`Positioned.fill` 那层保持生产实现
    debugVideoSlotOverride = const SizedBox.expand(key: _leafKey);
  });

  tearDown(() {
    debugVideoSlotOverride = null;
  });

  for (final size in _sizes) {
    final tag = '${size.width.toInt()}x${size.height.round()}';

    testWidgets('① $tag：视频层矩形 == 黑底矩形（铺满容器）', (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = size;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });

      await t.pumpWidget(_host(
        const LiveEmbeddedPlayer(stream: null, title: '第17项缺口3'),
      ));
      await t.pump();
      expect(t.takeException(), isNull);

      final ground = t.getRect(find.byKey(liveVideoGroundKey));
      final leaf = t.getRect(find.byKey(_leafKey));

      expect(leaf, rectMoreOrLessEquals(ground, epsilon: 0.51),
          reason: '★ 视频层 $leaf ≠ 容器 $ground ⇒ 布局层给视频加了留白'
              '（这正是"上下黑边由布局产生"的形态）');
      expect(leaf.height, moreOrLessEquals(size.height, epsilon: 0.51),
          reason: '★ 视频层高度 ${leaf.height} ≠ 窗口高度 ${size.height}');
    });
  }

  testWidgets('② 视频层到槽位之间没有任何留白层（祖先链）', (t) async {
    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '祖先链'),
    ));
    await t.pump();

    final leafFinder = find.byKey(_leafKey);
    expect(leafFinder, findsOneWidget,
        reason: '★ 叶子注入口没生效 ⇒ 下面的祖先链断言会恒真，先修门禁');

    final leafElement = leafFinder.evaluate().single;
    final offenders = <String>[];
    var reachedSlot = false;
    leafElement.visitAncestorElements((el) {
      final w = el.widget;
      if (w is Positioned) {
        // 槽位那层就是 `Positioned.fill(key: liveVideoSlotKey)`
        reachedSlot = w.key == liveVideoSlotKey &&
            w.left == 0 &&
            w.top == 0 &&
            w.right == 0 &&
            w.bottom == 0;
        return false; // 到槽位即止：再往上就是页面，不在本判据范围
      }
      if (w is AspectRatio ||
          w is Padding ||
          w is Center ||
          w is Align ||
          w is FittedBox ||
          w is FractionallySizedBox ||
          w is SizedBox) {
        /* SizedBox 也抓：`SizedBox(width: 100%)` 之外的定尺会把视频缩掉 */
        offenders.add(w.runtimeType.toString());
      }
      return true;
    });

    expect(offenders, isEmpty,
        reason: '★★★ 视频层与槽位之间出现了留白层：$offenders ⇒ '
            '黑边由**布局**产生，不是片源自带（计划第 17 项要区分的就是这两者）');
    expect(reachedSlot, isTrue,
        reason: '★★★ 视频层的直接父级不是 `Positioned.fill(key: liveVideoSlotKey)` '
            '（或四条边不全是 0）⇒ 槽位不是"铺满"，fill 语义被破坏');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 几何：4 种尺寸下"叶子 == 槽位"，且**上下无黑边**
  // ══════════════════════════════════════════════════════════════════
  //
  // # 判据为什么这么写
  // ```text
  // `BoxFit.contain` 的黑边应该由**片源宽高比**在纹理内部产生，
  // 而不是由布局把视频盒子压小。⇒ 只要"叶子盒 == 槽位盒"，就证明
  // **布局层没有制造黑边**；至于画面里有没有黑边，取决于片源，不在这里断言。
  // ```
  for (final size in _sizes) {
    final tag = '${size.width.toInt()}x${size.height.round()}';
    testWidgets('④ $tag：叶子盒 == 槽位盒，且叶子高度 == 视口高度（无布局黑边）',
        (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = size;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });

      await t.pumpWidget(_host(
        const LiveEmbeddedPlayer(stream: null, title: '④'),
      ));
      await t.pump();
      expect(t.takeException(), isNull);

      final slot = t.getRect(find.byKey(liveVideoSlotKey));
      final leaf = t.getRect(find.byKey(_leafKey));

      expect(leaf, rectMoreOrLessEquals(slot, epsilon: 0.51),
          reason: '★ 叶子 $leaf ≠ 槽位 $slot ⇒ 布局在视频层上加了约束');
      expect(leaf.height, moreOrLessEquals(size.height, epsilon: 0.51),
          reason: '★★ 叶子高度 ${leaf.height} ≠ 视口高度 ${size.height} ⇒ '
              '**上下黑边是布局制造的**（片源黑边不该改变盒子尺寸）');
      expect(leaf.width, moreOrLessEquals(size.width, epsilon: 0.51));
    });
  }

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ 结构：全屏侧槽位与内嵌**不同构**（源码判据，给行号口径）
  // ══════════════════════════════════════════════════════════════════
  test('⑤ 全屏侧槽位 = Positioned.fill > Center > Video（与内嵌不同构，记录在案）', () {
    final src = File('lib/ui/player_page.dart').readAsStringSync();
    /*
     * 全屏侧真实写法（`player_page.dart:15699-15707`）：
     *   Positioned.fill(
     *     child: Center(
     *       child: Video(controller: _controller, controls: NoVideoControls, fill: Colors.black),
     *     ),
     *   ),
     * ⇒ 中间**有** `Center`。内嵌侧没有（`Positioned.fill > Video`）。
     * ★ 这条断言钉的是"结构差异存在且被记录"，不是"全屏错了"：
     *   `Center` 给的是 **loose** 约束，media_kit 的 `Video` 会撑到 max
     *   ⇒ 功能上等价；但**结构上不同构**，将来谁想统一必须知道这一层。
     */
    expect(src.contains('child: Center('), isTrue,
        reason: '全屏槽位里那个 Center 不见了？若被移除，请同步更新本条与结论');
    final i = src.indexOf('controls: NoVideoControls');
    expect(i, greaterThan(0), reason: '全屏侧找不到 Video(controls: NoVideoControls)');
    final block = src.substring((i - 400).clamp(0, src.length), i + 200);
    // 中间约束层：Center 有，其余留白层不许有
    expect(block.contains('Center('), isTrue,
        reason: '★ 全屏槽位 = Positioned.fill > Center > Video（`player_page.dart:15700`）');
    for (final bad in ['AspectRatio', 'FittedBox', 'Padding', 'FractionallySizedBox']) {
      expect(block.contains(bad), isFalse,
          reason: '★ 全屏槽位里出现了 $bad ⇒ 给视频加了额外约束（第 17 项要排除的形态）');
    }
    // 内嵌侧对照：同一段里**没有** Center
    final emb = File('lib/ui/widgets/live_embedded_player.dart').readAsStringSync();
    final j = emb.indexOf('key: liveVideoSlotKey');
    expect(j, greaterThan(0));
    final embBlock = emb.substring(j, (j + 400).clamp(0, emb.length));
    expect(embBlock.contains('Center('), isFalse,
        reason: '★ 内嵌槽位不该出现 Center（它的槽位是 Positioned.fill 直包）');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑥ 一致性：两侧的缩放语义必须是同一个（contain）
  // ══════════════════════════════════════════════════════════════════
  test('⑥ 内嵌与全屏的缩放语义一致（都 = BoxFit.contain）', () {
    // 内嵌：显式常量（单点定义）
    expect(liveEmbeddedVideoFit, BoxFit.contain,
        reason: '★ 内嵌缩放策略变了（cover/fill 都会改变"画面是否被裁/被拉"）');

    final src = File('lib/ui/player_page.dart').readAsStringSync();
    final i = src.indexOf('controls: NoVideoControls');
    expect(i, greaterThan(0));
    final block = src.substring((i - 400).clamp(0, src.length), i + 200);
    /*
     * 全屏：`Video(...)` **不传 `fit:`** ⇒ 吃 media_kit 的默认 `BoxFit.contain`。
     * ⚠️ 这条只能证明"没显式改成别的"，默认值是依赖包的契约（本仓不可执行验证）
     *    ⇒ 所以下面再补一条**间接证据**：本页自己的弹幕层用
     *      `danmakuContainRect` 复刻 contain —— 说明全屏的预期语义确实是 contain。
     */
    expect(RegExp(r'\bfit\s*:').hasMatch(block), isFalse,
        reason: '★★ 全屏 Video 若显式传了 fit，就必须与内嵌常量比对；'
            '现在它不传 ⇒ 依赖 media_kit 默认值');
    expect(src.contains('danmakuContainRect'), isTrue,
        reason: '★ 全屏弹幕层按 contain 复刻几何 ⇒ 印证"全屏预期语义 = contain"');
  });

  testWidgets('③ 槽位 key 就在视频层的直接父级上（不是隔着几层）', (t) async {
    await t.pumpWidget(_host(
      const LiveEmbeddedPlayer(stream: null, title: '直接父级'),
    ));
    await t.pump();

    // `find.ancestor` 取最近的槽位；它必须与叶子的直接父级是同一个 element
    final slotAncestor = find.ancestor(
      of: find.byKey(_leafKey),
      matching: find.byKey(liveVideoSlotKey),
    );
    expect(slotAncestor, findsOneWidget);

    Element? directParent;
    find.byKey(_leafKey)
        .evaluate()
        .single
        .visitAncestorElements((el) {
      directParent = el;
      return false; // 只取第 1 个祖先
    });
    expect(directParent, isNotNull);
    expect(directParent!.widget.key, liveVideoSlotKey,
        reason: '★ 直接父级是 ${directParent!.widget.runtimeType}（key='
            '${directParent!.widget.key}）⇒ 中间又插了一层');
  });
}
