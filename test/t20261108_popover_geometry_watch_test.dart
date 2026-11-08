import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/player/player_popover.dart';

// Count the real coordinate transformations requested from the render tree.
// No production counters or scheduler internals are used as the oracle.
class _TransformReads extends SingleChildRenderObjectWidget {
  const _TransformReads({required this.onRead, required super.child});

  final VoidCallback onRead;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderTransformReads(onRead);
}

class _RenderTransformReads extends RenderProxyBox {
  _RenderTransformReads(this.onRead);

  final VoidCallback onRead;

  @override
  void applyPaintTransform(RenderBox child, Matrix4 transform) {
    onRead();
    super.applyPaintTransform(child, transform);
  }
}

void main() {
  testWidgets('panel switches keep one geometry read per existing frame', (
    tester,
  ) async {
    final controller = PopoverController();
    addTearDown(controller.dispose);
    final firstKey = GlobalKey();
    final secondKey = GlobalKey();
    var reads = 0;
    Future<void> nextExistingFrame() async {
      // This isolated controller has no ListenableBuilder to schedule a build.
      // Supply a frame like a video/control animation would; the watcher itself
      // must not request one, which is asserted after each measured pump.
      tester.binding.scheduleFrame();
      await tester.pump();
    }

    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Positioned(
              left: 40,
              top: 40,
              child: _TransformReads(
                onRead: () => reads++,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(key: firstKey, width: 80, height: 40),
                    SizedBox(key: secondKey, width: 80, height: 40),
                  ],
                ),
              ),
            ),
            Positioned.fill(child: SizedBox(key: controller.layerKey)),
          ],
        ),
      ),
    );
    final first = firstKey.currentContext!.findRenderObject()! as RenderBox;
    final second = secondKey.currentContext!.findRenderObject()! as RenderBox;
    final firstRect = first.localToGlobal(Offset.zero) & first.size;
    final secondRect = second.localToGlobal(Offset.zero) & second.size;
    controller.reportAnchorRect('first', first, firstRect);
    controller.reportAnchorRect('second', second, secondRect);
    await nextExistingFrame();

    controller.toggleOpen('first');
    reads = 0;
    await nextExistingFrame();
    expect(reads, 1, reason: 'One open panel reads its real anchor once.');

    // All these changes happen while the previous watcher is still pending.
    // Before the fix, every switch adds another self-perpetuating chain.
    for (var i = 0; i < 6; i++) {
      controller.toggleOpen('second');
      controller.toggle('first');
    }
    controller.toggleOpen('second');
    reads = 0;
    await nextExistingFrame();
    expect(reads, 1, reason: 'Switching panels must not multiply render work.');
    expect(controller.anchorRectOf(controller.openId), secondRect);
    reads = 0;
    await nextExistingFrame();
    expect(
      reads,
      1,
      reason: 'Only one watcher should survive on later frames.',
    );
    expect(tester.binding.hasScheduledFrame, isFalse);

    controller.close();
    controller.toggleOpen('first');
    reads = 0;
    await nextExistingFrame();
    expect(reads, 1, reason: 'Closing and reopening within a frame reuses it.');
    expect(controller.anchorRectOf(controller.openId), firstRect);

    controller.close();
    reads = 0;
    await nextExistingFrame();
    expect(reads, 0, reason: 'Closed panels stop reading render geometry.');
    expect(tester.binding.hasScheduledFrame, isFalse);
    controller.toggleOpen('second');
    reads = 0;
    await nextExistingFrame();
    expect(reads, 1, reason: 'A stopped watcher restarts on a later opening.');
    controller.close();
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
