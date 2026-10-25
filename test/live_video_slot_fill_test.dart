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
