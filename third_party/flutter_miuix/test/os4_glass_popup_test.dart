import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';
import 'package:flutter_miuix/src/theme/miuix/glass/internal/popup_presenter.dart';

Widget app(Widget child, {MediaQueryData? media}) => MiuixTheme(
  data: MiuixThemeData.light(),
  child: MaterialApp(
    builder: media == null
        ? null
        : (context, child) => MediaQuery(data: media, child: child!),
    home: Scaffold(body: child),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(MiuixGlassRendering.load);
  test('菜单终点、RTL 二级定位与物理像素拖拽上限', () {
    for (final kind in MiuixGlassPopupMotion.values) {
      final frame = miuixGlassPopupFrame(
        motion: kind,
        anchor: const Rect.fromLTWH(290, 450, 44, 44),
        end: const Size(200, 160),
        bounds: const Rect.fromLTWH(12, 24, 336, 400),
        progress: 1,
        positionProgress: 1,
      );
      expect(frame.rect.width, closeTo(200, .001));
      expect(frame.rect.height, closeTo(160, .001));
      expect(frame.rect.top, greaterThanOrEqualTo(24));
      expect(frame.rect.bottom, lessThanOrEqualTo(424));
    }
    final rtl = miuixGlassPopupFrame(
      motion: MiuixGlassPopupMotion.secondary,
      anchor: const Rect.fromLTWH(180, 90, 100, 44),
      end: const Size(200, 160),
      bounds: const Rect.fromLTWH(12, 24, 336, 600),
      progress: 1,
      positionProgress: 1,
      direction: TextDirection.rtl,
    );
    expect(rtl.rect.left, 80);
    final drag = miuixGlassNavigationDragTarget(
      left: 100,
      width: 60,
      containerWidth: 320,
      delta: 50,
      changedItem: false,
      devicePixelRatio: 3,
    );
    expect(drag.left, 80);
    expect(drag.right, 160);
    expect(drag.following, isTrue);
    expect(
      miuixGlassNavigationIndicatorBounds(-100, 500, 320, 3),
      const Offset(3, 317),
    );
    expect(
      MiuixGlassMotion.navIndicator.stiffness,
      closeTo(math.pow(2 * math.pi / .4, 2), 1e-8),
    );
    expect(() => MiuixGlassMotion.springOf(1, 0), throwsArgumentError);
  });
  testWidgets('变形弹窗快速反向、返回与卸载后恢复锚点', (tester) async {
    final anchor = MiuixGlassPopupAnchor();
    var show = false, mountedPopup = true;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                Align(
                  alignment: Alignment.topRight,
                  child: MiuixGlassIconButton(
                    anchor: anchor,
                    onPressed: () => setState(() => show = true),
                    child: const Icon(Icons.more_horiz),
                  ),
                ),
                const Center(child: Text('route-stays')),
                if (mountedPopup)
                  MiuixGlassTransformPopup(
                    show: show,
                    anchor: anchor,
                    anchorContent: const Icon(Icons.more_horiz),
                    onDismissRequest: () => setState(() => show = false),
                    child: MiuixGlassPopupItem(
                      text: 'Transform action',
                      onPressed: () => setState(() => show = false),
                    ),
                  ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => show = true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 30));
    update(() => show = false);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    update(() => show = true);
    await tester.pumpAndSettle();
    expect(find.text('Transform action'), findsOneWidget);
    expect(anchor.contentHidden, isTrue);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(show, isFalse);
    expect(anchor.contentHidden, isFalse);
    expect(find.text('route-stays'), findsOneWidget);
    update(() => show = true);
    await tester.pumpAndSettle();
    update(() => mountedPopup = false);
    await tester.pumpAndSettle();
    expect(anchor.contentHidden, isFalse);
    expect(find.text('Transform action'), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    anchor.dispose();
  });
  testWidgets('预测性返回取消保留弹窗，完成只发出一次关闭请求', (tester) async {
    final anchor = MiuixGlassPopupAnchor();
    var show = false, dismissals = 0;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                MiuixGlassIconButton(
                  anchor: anchor,
                  onPressed: () {},
                  child: const Icon(Icons.more_horiz),
                ),
                MiuixGlassTransformPopup(
                  show: show,
                  anchor: anchor,
                  anchorContent: const Icon(Icons.more_horiz),
                  onDismissRequest: () {
                    dismissals++;
                    setState(() => show = false);
                  },
                  child: const Text('preview menu'),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => show = true);
    await tester.pumpAndSettle();
    final observer =
        tester.state(find.byType(GlassPopupPresenter))
            as WidgetsBindingObserver;
    PredictiveBackEvent event(double progress) => PredictiveBackEvent.fromMap({
      'progress': progress,
      'swipeEdge': 0,
      'touchOffset': <Object?>[1.0, 100.0],
    });
    expect(observer.handleStartBackGesture(event(0)), isTrue);
    observer.handleUpdateBackGestureProgress(event(.7));
    await tester.pump();
    observer.handleCancelBackGesture();
    await tester.pumpAndSettle();
    expect(show, isTrue);
    expect(dismissals, 0);
    expect(observer.handleStartBackGesture(event(0)), isTrue);
    observer.handleUpdateBackGestureProgress(event(.8));
    await tester.pump();
    observer.handleCommitBackGesture();
    await tester.pumpAndSettle();
    expect(show, isFalse);
    expect(dismissals, 1);
    expect(anchor.contentHidden, isFalse);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    anchor.dispose();
  });
  testWidgets('下拉菜单限制于安全区与键盘之上，超长内容可滚动', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    const media = MediaQueryData(
      size: Size(360, 640),
      viewPadding: EdgeInsets.only(top: 24, bottom: 20),
      viewInsets: EdgeInsets.only(bottom: 300),
    );
    var show = true;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) => MiuixGlassDropdownPopup(
            show: show,
            anchorBounds: const Rect.fromLTWH(290, 510, 44, 44),
            onDismissRequest: () => setState(() => show = false),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (var i = 0; i < 30; i++)
                  MiuixGlassPopupItem(text: 'Choice $i', onPressed: () {}),
              ],
            ),
          ),
        ),
        media: media,
      ),
    );
    await tester.pumpAndSettle();
    final rect = tester.getRect(find.byType(MiuixGlassPanel));
    expect(rect.left, greaterThanOrEqualTo(12));
    expect(rect.right, lessThanOrEqualTo(348));
    expect(rect.top, greaterThanOrEqualTo(36));
    expect(rect.bottom, lessThanOrEqualTo(328));
    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(0, -500),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(show, isFalse);
  });
  testWidgets('禁用菜单项不响应，reduced motion 关闭不会残留遮罩', (tester) async {
    var show = false, taps = 0;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return MiuixGlassDialog(
              visible: show,
              onDismissRequest: () => setState(() => show = false),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MiuixGlassPopupItem(
                    text: 'disabled',
                    enabled: false,
                    onPressed: () => taps++,
                  ),
                  TextButton(
                    onPressed: () => setState(() => show = false),
                    child: const Text('done'),
                  ),
                ],
              ),
            );
          },
        ),
        media: const MediaQueryData(disableAnimations: true),
      ),
    );
    update(() => show = true);
    await tester.pumpAndSettle();
    final panel = tester.widget<MiuixGlassPanel>(find.byType(MiuixGlassPanel));
    expect(panel.stroke, isNull);
    expect(panel.material, isNull);
    await tester.tap(find.text('disabled'));
    expect(taps, 0);
    await tester.tap(find.text('done'));
    await tester.pumpAndSettle();
    expect(find.text('done'), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('旧级联图标菜单透传自定义表面且旧调用继续工作', (tester) async {
    var surfaces = 0, taps = 0;
    await tester.pumpWidget(
      MiuixSystemTheme(
        child: MaterialApp(
          home: MiuixScaffold(
            content: (_) => Center(
              child: MiuixOverlayIconCascadingDropdownMenu.entries(
                entries: [
                  MiuixDropdownEntry(
                    items: [
                      MiuixDropdownItem(
                        text: 'legacy action',
                        onClick: () => taps++,
                      ),
                    ],
                  ),
                ],
                surfaceBuilder: (context, shape, child) {
                  surfaces++;
                  return DecoratedBox(
                    decoration: ShapeDecoration(
                      color: Colors.pink,
                      shape: shape,
                    ),
                    child: child,
                  );
                },
                child: const Icon(Icons.more_horiz),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byType(MiuixIconButton));
    await tester.pumpAndSettle();
    expect(surfaces, greaterThan(0));
    await tester.tap(find.text('legacy action'));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('弹窗关闭期间不能通过键盘再次激活菜单项', (tester) async {
    var show = true, taps = 0;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return MiuixGlassPopup(
              show: show,
              anchorBounds: const Rect.fromLTWH(200, 100, 44, 44),
              onDismissRequest: () => setState(() => show = false),
              child: MiuixGlassPopupItem(
                text: 'keyboard action',
                onPressed: () {
                  taps++;
                  setState(() => show = false);
                },
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump(const Duration(milliseconds: 16));
    expect(taps, 1);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(find.text('keyboard action'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
