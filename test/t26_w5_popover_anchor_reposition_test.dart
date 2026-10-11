// ═══════════════════════════════════════════════════════════════════════
//  T26-W5 / CR-10 —— popover 锚点矩形必须在**全局几何变化后**重新量取
// ═══════════════════════════════════════════════════════════════════════
//
// # CodeRabbit 原始意见（未解决线程）
// ```text
// lib/ui/player/player_popover.dart:516 —— reportAnchorRect 只在
// _RenderPopoverAnchorProbe.paint 里调用；祖先 RepaintBoundary 只改偏移时
// Flutter 可复用 layer 不重跑 paint ⇒ controller 留旧矩形，面板停在旧位置。
// ```
//
// # 先复核：这条意见到底怎么成立（含一次**否定**的复核）
// ```text
// ① 只改**窗口尺寸**（1000→1400）：**不成立** —— 实测探针的 paint 会重跑。
//    原因：窗口一变，底栏那行 RenderFlex 的宽度跟着变 ⇒ 行自身尺寸变了
//    ⇒ markNeedsPaint 往下走到按钮 ⇒ 探针 paint 重跑 ⇒ 上报是新鲜的。
//    只改窗口**高度**（1000→1300）也一样：外层 RenderStack 尺寸变了。
//    ⇒ 把「窗口缩放」直接当成复现构造是错的，会得到假绿。
//
// ② 「祖先只改偏移、子树既不重排也不重画」：**成立** —— 这才是缺陷本体。
//    最干净的真实构造 = 祖先里有一层 repaint boundary（子树被合成成独立
//    图层）+ 这层只改**偏移**：
//      object.dart 的 _compositeChild 在子层已存在且子层没脏时，
//      只做 childOffsetLayer.offset = offset 就复用整棵子层
//      ⇒ 探针的 paint 一次都不跑 ⇒ 控制器留着旧矩形。
//    生产里这层是**现成的**：底栏外面就是 Opacity
//    （player_bottom_bar.dart:311，opacity 由 _controlsFade 驱动），
//    而 RenderOpacity.isRepaintBoundary == (alpha > 0)
//    （proxy_box.dart:884/887）⇒ 淡入完成后它就是一个 repaint boundary。
//    任何把底栏整体挪位置的**变换型**祖先（滑入/滑出、缩放舞台、拖拽位移）
//    都会命中这条路径。
// ```
//
// # 本探针的构造（为什么不是「为了变红塞布景」）
// ```text
// 祖先链照抄生产：Stack([底栏, 面板层])，浮层是底栏的**兄弟**。
// 唯一新增的是「把底栏整体平移一段」的祖先：
//     Transform.translate(offset: (dx, 0), child: RepaintBoundary(child: 底栏))
// dx 由 ValueNotifier 驱动 ⇒ 只改**偏移**：
//   · 子树约束不变、尺寸不变 ⇒ 不重排；
//   · RepaintBoundary 让子树成为独立图层 ⇒ 框架只改 layer.offset；
//   · ⇒ 探针的 paint 不跑（改前），上报留在旧位置。
// 这与「窗口缩放」的区别是决定性的：后者会顺带把行宽改掉、触发一次真重画，
// 于是把缺陷盖住。
// ```
//
// # 判据的独立来源（不许拿「结论」当「前提」）
// ```text
// 期望值从**渲染树现算**：锚点按钮那个 element 自己的 RenderObject
// （find.byType(PopoverAnchorButton) → MouseRegion，与探针同尺寸同位置）
// 取 localToGlobal，再按控制器**同一条换算**转成面板层局部坐标。
// 控制器里存的则是「上一次上报时」算出的局部矩形 ⇒
// 两者相等 ⟺ 上报是**新鲜的**。
// ```
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/models.dart' show StreamCandidate;
import 'package:sourin_spike/ui/app_scaffold.dart' show AppThemeHost;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';
import 'package:sourin_spike/ui/tokens.dart' show Sp;

/// 认领 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

class _Spy {
  final List<String> qualities = <String>[];

  void pickQuality(String id) => qualities.add(id);
}

final List<PopoverOption<String>> _qualityOptions = <PopoverOption<String>>[
  const PopoverOption<String>(value: 'q1', label: '1080P'),
  const PopoverOption<String>(value: 'q2', label: '720P'),
];

PlayerBottomBar _bar(PopoverController controller, _Spy spy) => PlayerBottomBar(
      controller: controller,
      playing: true,
      positionListenable: ValueNotifier<Duration>(Duration.zero),
      duration: const Duration(minutes: 24),
      isLive: false,
      rate: 1.0,
      volume: 60,
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
      streams: const <StreamCandidate>[
        StreamCandidate(url: 'https://a/1.m3u8'),
        StreamCandidate(url: 'https://a/2.m3u8'),
      ],
      qualityOptions: _qualityOptions,
      onPickQuality: spy.pickQuality,
    );

/// 底栏整体平移多少 —— 只改**偏移**的那条通道
typedef _Shift = ValueNotifier<double>;

/// 生产里浮层是底栏的**兄弟**节点（player_page.dart 的全屏 Stack）
///
/// ★★★ dx != 0 就是 CR-10 的触发条件：底栏整体被平移，
///     但它自己（含探针）既不重排、也不重画。
///     RepaintBoundary 是生产里**本来就有**的那一层：
///     player_bottom_bar.dart:311 的 Opacity（RenderOpacity
///     在 alpha > 0 时 isRepaintBoundary == true）。
Widget _host(
  PlayerBottomBar bar,
  PopoverController controller,
  _Shift shift,
) =>
    Stack(
      children: <Widget>[
        /*
         * ★ 底栏自己返回的是一个 Positioned（player_bottom_bar.dart:303），
         *   所以它必须是某个 Stack 的**直接**子件 —— 不能直接塞进
         *   Transform/Opacity，否则 Positioned 失去定位语义、
         *   底栏会跑到顶上（实测 y=46）。这里补一层内层 Stack。
         */
        Positioned.fill(
          child: ValueListenableBuilder<double>(
            valueListenable: shift,
            builder: (context, dx, _) => Transform.translate(
              offset: Offset(dx, 0),
              child: RepaintBoundary(
                child: Stack(children: <Widget>[bar]),
              ),
            ),
          ),
        ),
        ListenableBuilder(
          listenable: controller,
          builder: (context, _) => Positioned.fill(
            child: Align(
              alignment: Alignment.bottomRight,
              child: bar.buildPopoverLayer(),
            ),
          ),
        ),
      ],
    );

/// 在**指定**窗口尺寸下挂起底栏
///
/// ★ 必须用 tester.view.*：它同时驱动 RenderView 的约束与 MediaQuery；
///   setSurfaceSize 只改前者，两者不一致会造成假红
///   （见 test/bottom_bar_fit_test.dart 的长注释）。
Future<void> _pumpBarAt(
  WidgetTester tester,
  PopoverController controller,
  _Spy spy,
  Size logical,
  _Shift shift,
) async {
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = logical;
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.dark);
  await tester.pumpWidget(
    mui.MaterialApp(
      theme: theme,
      builder: (context, child) => AppThemeHost(
        data: theme,
        child: child ?? const SizedBox(),
      ),
      home: mui.Scaffold(
        body: mui.Material(
          type: mui.MaterialType.transparency,
          child: _host(_bar(controller, spy), controller, shift),
        ),
      ),
    ),
  );
  _claim(tester);
}

/// 锚点按钮（**就是探针包着的那个盒子**）此刻的全局矩形
///
/// 判据用 find.ancestor(of: 文本, matching: PopoverAnchorButton) —— 定位到
/// **清晰度那一枚**，而不是树上随便哪一枚（字幕与音轨也是一枚锚点按钮）。
Rect _anchorButtonRect(WidgetTester t) => t.getRect(
      find.ancestor(
        of: find.text('清晰度'),
        matching: find.byType(PopoverAnchorButton),
      ),
    );

/// 控制器**应该**存的那个矩形：拿按钮**此刻**的全局矩形，按控制器同一条
/// 换算（layer.globalToLocal(topLeft) & size）转成面板层局部坐标
Rect _expectedAnchorRect(WidgetTester t, PopoverController controller) {
  final layer = t.renderObject<RenderBox>(find.byKey(controller.layerKey));
  final r = _anchorButtonRect(t);
  return layer.globalToLocal(r.topLeft) & r.size;
}

void main() {
  testWidgets(
    '★★★ CR-10 祖先只改偏移（层复用、不重跑 paint）后锚点必须重新量取',
    (t) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      final shift = ValueNotifier<double>(0);
      addTearDown(shift.dispose);

      await _pumpBarAt(t, controller, spy, const Size(1000, 900), shift);
      expect(controller.openId, isNull);

      await t.tap(find.text('清晰度'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(controller.openId, 'quality', reason: '★ 前提：清晰度面板真的开了');
      expect(find.byType(PopoverRow), findsNWidgets(_qualityOptions.length),
          reason: '★ 前提：面板里有内容');

      final before = controller.anchorRectOf('quality');
      final truth0 = _expectedAnchorRect(t, controller);
      final btn0 = _anchorButtonRect(t);
      debugPrint('GEOM 平移前 btn=$btn0'
          ' anchor=$before'
          ' truth=$truth0');
      expect(before, isNotNull,
          reason: '★ 前提：探针已经上报过（否则测的是没上报而不是没重报）');
      expect(before, truth0, reason: '★ 前提：平移前锚点就是准的');

      // ★★★ 只改**祖先偏移**：按钮的全局几何变了，
      //     但按钮自身尺寸、约束、子树绘制一次都没变。
      shift.value = -220;
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      final after = controller.anchorRectOf('quality');
      final truth1 = _expectedAnchorRect(t, controller);
      final btn1 = _anchorButtonRect(t);
      final panel = t.getRect(find.byType(PlayerPopoverSurface));
      debugPrint('GEOM 平移后 btn=$btn1'
          ' anchor=$after'
          ' truth=$truth1'
          ' panel=$panel');

      expect(btn1.right, lessThan(btn0.right - 100),
          reason: '★ 前提：按钮真的往左挪了 100px 以上（本探针的触发条件）');
      expect(after, truth1,
          reason: '★★★ CR-10：祖先只改偏移后，锚点矩形必须**重新量取上报**。'
              '改前只有 paint 会上报，而层被复用时 paint 不重跑 ⇒'
              ' 控制器留着旧矩形，面板停在旧位置。');

      // ★ 端到端：面板必须贴在**新**按钮的上方（右缘对齐 + 缝隙 Sp.x2）
      expect(panel.right, closeTo(btn1.right, 1.0),
          reason: '★★ CR-10：面板右缘必须对齐按钮右缘（改前差 220px）');
      expect(panel.bottom, closeTo(btn1.top - Sp.x2, 1.0),
          reason: '★ 面板底边 = 按钮上沿上方 Sp.x2');
      expect(panel.left, greaterThanOrEqualTo(Sp.x2 - 0.01),
          reason: '★ 面板必须整块留在窗口里');

      _claim(t);
    },
  );

  testWidgets(
    '★ 回归：真机那条窗口缩放路径（本来就会重画）也必须保持新鲜',
    (t) async {
      final controller = PopoverController();
      addTearDown(controller.dispose);
      final spy = _Spy();
      final shift = ValueNotifier<double>(0);
      addTearDown(shift.dispose);

      await _pumpBarAt(t, controller, spy, const Size(1000, 900), shift);
      await t.tap(find.text('清晰度'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(controller.openId, 'quality', reason: '★ 前提：面板开了');

      final btn0 = _anchorButtonRect(t);
      t.view.physicalSize = const Size(1400, 900);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));

      final btn1 = _anchorButtonRect(t);
      final truth1 = _expectedAnchorRect(t, controller);
      final after = controller.anchorRectOf('quality');
      debugPrint('GEOM 缩放后 btn=$btn1'
          ' anchor=$after'
          ' truth=$truth1');

      expect(btn1.right, greaterThan(btn0.right + 100),
          reason: '★ 前提：按钮真的往右挪了 100px 以上');
      expect(after, truth1, reason: '★ 锚点必须新鲜（真机路径）');

      _claim(t);
    },
  );
}
