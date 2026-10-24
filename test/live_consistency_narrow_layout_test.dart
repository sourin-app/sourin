import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

/// 第 16/17 项的布局守卫：内嵌直播控制条在窄窗口下不许把控件挤出可视区。
///
/// 背景：音量滑块（`live-volume-slider`）是后加的，被 `Flexible` 包住、
/// 最大宽 120。既有控件测试只覆盖 532×356 一种尺寸，窄窗口没有任何断言。
///
/// ⚠️ 第一版用 `SizedBox(320,180)` 包住组件来"模拟窄窗口"，结果滑块落在
/// y≈334、x 到 444 —— 组件并没有被 SizedBox 约束，测出来的是假象。
/// 正确做法是改 `tester.view.physicalSize`，让窄尺寸真的进入 MediaQuery
/// 与布局约束，断言才有意义。
void main() {
  const widths = <double>[320, 360, 480, 640];

  for (final w in widths) {
    final h = w * 9 / 16;
    testWidgets('embedded bar stays inside the viewport at ${w.toInt()}x${h.toInt()}',
        (tester) async {
      tester.view.devicePixelRatio = 1.0;
      tester.view.physicalSize = Size(w, h);
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LiveEmbeddedPlayer(stream: null, title: '窄窗口'),
        ),
      ));
      await tester.pump();

      expect(tester.takeException(), isNull,
          reason: '窄窗口下不许出现 RenderFlex 溢出');

      final slider = find.byKey(const ValueKey('live-volume-slider'));
      expect(slider, findsOneWidget);
      expect(tester.widget<Slider>(slider).onChanged, isNotNull);

      final rect = tester.getRect(slider);
      // 滑块必须在可视区内，且没有被压成 0 宽的死控件。
      expect(rect.left, greaterThanOrEqualTo(0),
          reason: '滑块左边界跑出视口 ⇒ 控件被裁掉');
      expect(rect.right, lessThanOrEqualTo(w),
          reason: '滑块右边界 ${rect.right} 超出视口 $w ⇒ 控件被裁掉');
      expect(rect.width, greaterThan(0),
          reason: '滑块宽度为 0 ⇒ 看似存在实则点不到');

      // 静音按钮同样不许被挤出。
      final mute = find.byIcon(
        tester.widget<Slider>(slider).value == 0
            ? Icons.volume_off_outlined
            : Icons.volume_up_outlined,
      );
      if (mute.evaluate().isNotEmpty) {
        final mrect = tester.getRect(mute.first);
        expect(mrect.right, lessThanOrEqualTo(w),
            reason: '静音按钮被挤出视口');
      }

      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
