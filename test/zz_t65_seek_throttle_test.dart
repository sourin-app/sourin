// ═══════════════════════════════════════════════════════════════════════
//  门禁：进度条拖动时 seek 次数（Owner 第 17 条「进度条拖动很卡顿」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁防什么
// ```text
// 改前的实现：
//   onHorizontalDragUpdate: (d) => onSeek(at(d.localPosition.dx))
// ⇒ 拖动时**每一个 pointer move** 都直接 seek 一次。
//   一次 2 秒的拖动 = 上百次 seek 请求，每次都走 mpv seek + 重新解码，
//   而且宿主 onSeek 里还会 setState 整条底栏。
//   ⇒ 用户感到的「卡顿」是**自己把播放器打爆了**，不是渲染慢。
//
// 改后：拖动中只更新本地预览（_dragMs），松手才 seek 一次。
// ```
//
// # 判据为什么是「计数」而不是「看着不卡」
// ```text
// 「不卡」是主观的，没法进门禁。可测的客观量是：一次拖动产生几次 onSeek 调用。
//   改前 ≥ N（每次移动一次）
//   改后 == 1（松手一次）
// ⇒ 计数从 N 降到 1，这就是「不卡」的机制性原因。
// ```
//
// # ★ 撤销验证（本仓硬规矩）
// ```text
// 把 onHorizontalDragUpdate 改回「直接 onSeek」⇒ 本测试必须变红。
// 若仍绿 ⇒ 假绿 ⇒ 说明测的不是真实路径。
// ```

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/player/player_bottom_bar.dart';

void main() {
  /// 把滑杆挂起来，返回一个记录 onSeek 调用的列表
  Future<List<Duration>> mountSlider(
    WidgetTester tester, {
    Duration position = Duration.zero,
    Duration duration = const Duration(minutes: 10),
  }) async {
    final seeks = <Duration>[];
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Center(
          child: SizedBox(
            width: 400,
            child: PlayerProgressSlider(
              position: position,
              duration: duration,
              onSeek: seeks.add,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    return seeks;
  }

  group('第 17 条：拖动进度条不得每次移动都 seek', () {
    testWidgets('★★★ 一次连续拖动只产生 1 次 onSeek', (tester) async {
      final seeks = await mountSlider(tester);

      final slider = find.byType(PlayerProgressSlider);
      expect(slider, findsOneWidget);

      final start = tester.getCenter(slider);
      // 按下并拖动一段距离（中间多次 move，模拟真实拖动）
      final g = await tester.startGesture(start);
      await tester.pump();
      for (var i = 1; i <= 10; i++) {
        await g.moveBy(const Offset(12, 0));
        await tester.pump();
      }
      // 拖动过程中**一次都不该 seek**
      expect(seeks, isEmpty,
          reason: '★★★ 拖动中不该 seek —— 改前这里是每次 move 一次，'
              '正是「卡顿」的根因。若这条红，说明又退回逐帧 seek 了。');

      // 松手：恰好一次
      await g.up();
      await tester.pump();
      expect(seeks.length, 1,
          reason: '★ 松手应恰好 seek 一次（改后行为）');
    });

    testWidgets('★★ 单击仍然立即 seek 一次（这条行为不能丢）', (tester) async {
      final seeks = await mountSlider(tester);
      final slider = find.byType(PlayerProgressSlider);
      await tester.tapAt(tester.getCenter(slider));
      await tester.pump();
      expect(seeks.length, 1,
          reason: '点击跳转是原有能力，不能被「拖动优化」顺手改掉');
    });

    testWidgets('★★ 拖动中的预览位置会随手指变化（不是只有松手才动）', (tester) async {
      final seeks = await mountSlider(tester);
      final slider = find.byType(PlayerProgressSlider);
      final thumb = find.byKey(PlayerProgressSlider.thumbKey);

      final before = tester.getCenter(thumb);
      final g = await tester.startGesture(tester.getCenter(slider));
      await tester.pump();
      await g.moveBy(const Offset(80, 0));
      await tester.pump();
      final during = tester.getCenter(thumb);

      expect(during.dx, greaterThan(before.dx),
          reason: '★ 拖动中圆点必须跟手（否则用户看不到拖到哪了）');
      // 但仍然没有 seek
      expect(seeks, isEmpty);

      await g.up();
      await tester.pump();
      expect(seeks.length, 1);
    });

    testWidgets('★ 松手后预览被清空，圆点回到真实位置', (tester) async {
      // position 固定为 0 ⇒ 松手 seek 后若预览没清空，圆点会停在拖到的位置
      final seeks = await mountSlider(tester, position: Duration.zero);
      final slider = find.byType(PlayerProgressSlider);
      final thumb = find.byKey(PlayerProgressSlider.thumbKey);

      final origin = tester.getCenter(thumb);
      final g = await tester.startGesture(tester.getCenter(slider));
      await tester.pump();
      await g.moveBy(const Offset(100, 0));
      await tester.pump();
      await g.up();
      await tester.pump();

      final after = tester.getCenter(thumb);
      expect(after.dx, closeTo(origin.dx, 0.5),
          reason: '★★ 松手后必须清空 _dragMs —— 否则圆点冻在松手处，'
              '看起来像卡住（真实 position 还是 0，没有追上来）');
      expect(seeks.length, 1);
    });
  });
}
