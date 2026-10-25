// ═══════════════════════════════════════════════════════════════════════
//  第 17 项验收：视频未填满与上下黑边
// ═══════════════════════════════════════════════════════════════════════
//
// # 计划原文（判据）
// ```text
// 17 视频未填满与上下黑边：先测容器尺寸/视频显示尺寸/fit 策略，
//    区分布局留白与片源自带黑边；控制条在视口内、不额外挤占视频高度。
//    4 种窗口尺寸都要成立。
// ```
//
// # 两种黑边为什么必须分开（本文件的判据核心）
// ```text
// · 片源自带黑边（**正常**）：mpv 在纹理内部按 `BoxFit.contain` 缩放，
//   视频**槽位**矩形仍然等于播放器盒子 ⇒ 黑边是画面内容的一部分。
// · 布局留白（**缺陷**）：有人给视频套了 `AspectRatio` / `Padding` / `Center`
//   ⇒ 槽位矩形**自己变小**，上下露出父级黑底；控制条还会被挤。
// ⇒ 只用截图看"有没有黑边"是分不开的（两种看起来一模一样）。
//   必须量三个盒子：容器（黑底）/ 视频槽位 / 控制条。
// ```
//
// # 四个窗口尺寸（计划要求"4 种窗口尺寸都要成立"）
// ```text
// 320x180（16:9 最小、窄窗口）  360x202（任务栏里的小窗）
// 480x270（中等）               640x360（默认尺寸附近）
// 都走 `tester.view.physicalSize` —— 不是拿 `SizedBox` 包一层假装窄窗
// （`live_consistency_narrow_layout_test.dart` 记过那个假象）。
// ```
//
// # ⚠️ 这里**不能**验的（如实写在交付说明里，不写成已完成）
// ```text
// 真实视频纹理的显示尺寸（画面里那块像）需要 libmpv 解码器：
//   `flutter test` 里 `VideoController` 建不出来（native-media 标签整体跳过）
// ⇒ 本文件验的是「布局层没有给视频加留白 / 控制条不挤占视频」，
//   以及「缩放策略是 contain（不拉伸、不裁切）」这两件**能证**的事；
//   "某一路源在某个窗口下上下黑了多少像素"属于片源属性，必须真机看。
// ```

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/design/icons/app_icons.dart';
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

/// 计划要求的 4 种窗口尺寸（16:9 全系）
const _sizes = <Size>[
  Size(320, 180),
  Size(360, 202.5),
  Size(480, 270),
  Size(640, 360),
];

void main() {
  // ────────────────────────────────────────────────────────────────
  // ① fit 策略：不拉伸、不裁切（黑边只能来自片源）
  // ────────────────────────────────────────────────────────────────
  test('① 视频缩放策略是 contain（不拉伸、不裁切）', () {
    /*
     * 判据线：`Video(fit: liveEmbeddedVideoFit)` 与这里读的是同一个常量。
     * · `BoxFit.fill`   ⇒ 画面变形（4:3 源被拉成 16:9）
     * · `BoxFit.cover`  ⇒ 画面被裁掉上下/左右
     * · `BoxFit.contain`⇒ 完整画面 + 由 mpv 补齐黑边 = 片源自带黑边
     */
    expect(liveEmbeddedVideoFit, BoxFit.contain,
        reason: '★ fit 改成 $liveEmbeddedVideoFit ⇒ '
            '不再是"完整画面 + 片源自带黑边"的语义（拉伸/裁切都属于新缺陷）');

    // 三个测量锚点必须互不相同，否则下面的几何判据会退化成同一条
    expect(liveVideoSlotKey, isNot(liveVideoGroundKey));
    expect(liveVideoSlotKey, isNot(liveEmbedBarKey));
  });

  for (final size in _sizes) {
    final tag = '${size.width.toInt()}x${size.height.round()}';

    // ──────────────────────────────────────────────────────────────
    // ② 容器尺寸 == 视频显示尺寸（没有任何布局留白）
    // ──────────────────────────────────────────────────────────────
    testWidgets('② $tag：视频槽位铺满容器（零布局留白）', (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = size;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });

      await t.pumpWidget(_host(
        const LiveEmbeddedPlayer(stream: null, title: '第17项'),
      ));
      await t.pump();

      expect(t.takeException(), isNull, reason: '$tag 不许出现渲染异常/RenderFlex 溢出');

      final ground = t.getRect(find.byKey(liveVideoGroundKey));
      final slot = t.getRect(find.byKey(liveVideoSlotKey));

      /*
       * 黑底 = 播放器盒子（占满整个 body）。
       * 槽位必须**逐边相等** —— 任何一边变短都是布局留白：
       * 上下变短 ⇒ 上下黑边由布局产生；左右变短 ⇒ 左右黑边由布局产生。
       */
      expect(ground, rectMoreOrLessEquals(Offset.zero & size, epsilon: 0.51),
          reason: '★ 播放器没有占满 $tag 窗口（$ground）'
              '⇒ 视口里先有了留白，无从判断黑边来源');

      expect(slot, rectMoreOrLessEquals(ground, epsilon: 0.51),
          reason: '★ 视频槽位 $slot ≠ 容器 $ground ⇒ '
              '布局层给视频加了留白（AspectRatio/Padding/Center），'
              '这里的黑边不是片源自带的');

      // 槽位的四边都要贴住容器：这是"未填满"最直接的可测形式
      expect(slot.top - ground.top, lessThanOrEqualTo(0.51),
          reason: '$tag 顶部留白 ${slot.top - ground.top}px');
      expect(ground.bottom - slot.bottom, lessThanOrEqualTo(0.51),
          reason: '$tag 底部留白 ${ground.bottom - slot.bottom}px');
      expect(slot.left - ground.left, lessThanOrEqualTo(0.51),
          reason: '$tag 左侧留白 ${slot.left - ground.left}px');
      expect(ground.right - slot.right, lessThanOrEqualTo(0.51),
          reason: '$tag 右侧留白 ${ground.right - slot.right}px');
    });

    // ──────────────────────────────────────────────────────────────
    // ③ 控制条在视口内、叠在视频上、不挤占视频高度
    // ──────────────────────────────────────────────────────────────
    testWidgets('③ $tag：控制条在视口内且不挤占视频高度', (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = size;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });

      await t.pumpWidget(_host(
        const LiveEmbeddedPlayer(stream: null, title: '第17项'),
      ));
      await t.pump();

      expect(t.takeException(), isNull);

      final viewport = Offset.zero & size;
      final slot = t.getRect(find.byKey(liveVideoSlotKey));
      final bar = t.getRect(find.byKey(liveEmbedBarKey));

      // ① 控制条必须在视口内（不许被裁掉一半）
      expect(_contains(viewport, bar), isTrue,
          reason: '★ 控制条 $bar 超出视口 $viewport ⇒ 用户点不到');

      // ② 控制条必须真的在（不是 0 高）
      expect(bar.width, greaterThan(0));
      expect(bar.height, greaterThan(0),
          reason: '$tag 控制条高度为 0 ⇒ 看似存在实则点不到');

      // ③ ★ 核心：控制条**叠在**视频槽位里，而不是排在视频下面
      expect(_contains(slot, bar), isTrue,
          reason: '★ 控制条 $bar 不在视频槽位 $slot 内 ⇒ '
              '它是排下去的（Column），把视频顶矮了');

      // ④ 底边对齐：叠加形态的必然结果
      expect((bar.bottom - slot.bottom).abs(), lessThanOrEqualTo(0.51),
          reason: '★ 控制条底边 ${bar.bottom} ≠ 视频槽位底边 ${slot.bottom}'
              ' ⇒ 视频下方有额外占位');

      // ⑤ 视频高度没有因为控制条而变矮：槽位高度 == 容器高度
      expect(slot.height, moreOrLessEquals(size.height, epsilon: 0.51),
          reason: '★ 视频槽位高度 ${slot.height} ≠ 窗口高度 ${size.height} ⇒ '
              '控制条挤占了视频高度（计划第 17 条明确禁止）');

      // ⑥ 控制条宽度撑满（不是缩在角落的一条）
      expect((bar.width - slot.width).abs(), lessThanOrEqualTo(0.51),
          reason: '控制条宽度 ${bar.width} 没有撑满视频槽位 ${slot.width}');

      // ⑦ 控制条比视频矮得多（护栏：别把"控制条=全屏层"这种形态当成通过）
      expect(bar.height, lessThan(slot.height),
          reason: '控制条高度 ${bar.height} ≥ 视频高度 ${slot.height} ⇒ '
              '这已经不是控制条了');
    });
  }

  // ──────────────────────────────────────────────────────────────
  // ④ 控制条在每种尺寸下都**可点**（不只是"矩形在视口内"）
  // ──────────────────────────────────────────────────────────────
  for (final size in _sizes) {
    final tag = '${size.width.toInt()}x${size.height.round()}';
    testWidgets('④ $tag：静音与音量控件可命中（未被裁/未挡）', (t) async {
      t.view.devicePixelRatio = 1.0;
      t.view.physicalSize = size;
      addTearDown(() {
        t.view.resetPhysicalSize();
        t.view.resetDevicePixelRatio();
      });

      await t.pumpWidget(_host(
        const LiveEmbeddedPlayer(stream: null, title: '第17项'),
      ));
      await t.pump();

      expect(t.takeException(), isNull);

      final slider = find.byKey(const ValueKey('live-volume-slider'));
      expect(slider, findsOneWidget);
      expect(slider.hitTestable(), findsOneWidget,
          reason: '★ $tag 下音量滑块不可命中 ⇒ 被裁出视口或被别的层挡住');

      final srect = t.getRect(slider);
      expect(srect.right, lessThanOrEqualTo(size.width + 0.51),
          reason: '滑块右边界 ${srect.right} 超出视口 ${size.width}');
      expect(srect.bottom, lessThanOrEqualTo(size.height + 0.51),
          reason: '滑块下边界 ${srect.bottom} 超出视口 ${size.height}');

      // 静音按钮同理（图标随静音态变化 ⇒ 两种都找）
      final mute = find.byIcon(AppIcons.volume_off_outlined);
      final muteOn = find.byIcon(AppIcons.volume_up_outlined);
      final muteBtn = mute.evaluate().isNotEmpty ? mute : muteOn;
      expect(muteBtn, findsOneWidget, reason: '$tag 找不到静音按钮');
      expect(muteBtn.first.hitTestable(), findsOneWidget,
          reason: '★ $tag 下静音按钮不可命中');
    });
  }
}

/// `outer` 是否完整包含 `inner`（容差 0.6px，抗浮点抖动）
bool _contains(Rect outer, Rect inner) =>
    inner.left >= outer.left - 0.6 &&
    inner.top >= outer.top - 0.6 &&
    inner.right <= outer.right + 0.6 &&
    inner.bottom <= outer.bottom + 0.6;
