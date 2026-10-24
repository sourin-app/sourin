import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/ui/widgets/sourin_scroll_behavior.dart';

class _ParentBehavior extends ScrollBehavior {
  const _ParentBehavior();

  @override
  Widget buildScrollbar(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return KeyedSubtree(
      key: ValueKey('scrollbar-${details.direction}'),
      child: child,
    );
  }

  @override
  Widget buildOverscrollIndicator(
    BuildContext context,
    Widget child,
    ScrollableDetails details,
  ) {
    return ClipRect(clipBehavior: Clip.none, child: child);
  }
}

void main() {
  test('home mounts local behavior on both interactive horizontal lists', () {
    final home = File('lib/ui/home_page.dart').readAsStringSync();
    expect(
      RegExp(r'child: SourinHorizontalRail\(\s*child: ListView\.separated\(')
          .allMatches(home),
      hasLength(2),
    );
  });

  Future<({ScrollController horizontal, ScrollController vertical})> mount(
    WidgetTester tester, {
    required VoidCallback onTap,
  }) async {
    final horizontal = ScrollController();
    final vertical = ScrollController();
    addTearDown(horizontal.dispose);
    addTearDown(vertical.dispose);
    await tester.pumpWidget(
      Directionality(
        textDirection: TextDirection.ltr,
        child: ScrollConfiguration(
          behavior: const _ParentBehavior(),
          child: Column(
            children: [
              SizedBox(
                height: 140,
                child: SourinHorizontalRail(
                  child: ListView.builder(
                    key: const ValueKey('horizontal'),
                    controller: horizontal,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, index) => GestureDetector(
                      onTap: onTap,
                      child: SizedBox(
                        width: 160,
                        child: ColoredBox(
                          color: const Color(0xff224466),
                          child: Center(child: Text('card $index')),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  key: const ValueKey('vertical'),
                  controller: vertical,
                  itemCount: 40,
                  itemBuilder: (_, index) =>
                      SizedBox(height: 80, child: Text('row $index')),
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return (horizontal: horizontal, vertical: vertical);
  }

  testWidgets(
    'left mouse drag scrolls rail without activating card; click still works',
    (tester) async {
      var taps = 0;
      final controllers = await mount(tester, onTap: () => taps++);
      final rail = find.byKey(const ValueKey('horizontal'));
      await tester.tapAt(
        tester.getTopLeft(rail) + const Offset(80, 60),
        kind: PointerDeviceKind.mouse,
      );
      expect(taps, 1);
      await tester.drag(
        rail,
        const Offset(-350, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controllers.horizontal.offset, greaterThan(100));
      expect(taps, 1);
      expect(controllers.vertical.offset, 0);
    },
  );

  testWidgets(
    'parent rebuild preserves rail position and ScrollPosition identity',
    (tester) async {
      final controller = ScrollController();
      addTearDown(controller.dispose);
      late StateSetter rebuild;
      var generation = 0;
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: ScrollConfiguration(
            behavior: const _ParentBehavior(),
            child: StatefulBuilder(
              builder: (context, setState) {
                rebuild = setState;
                return SourinHorizontalRail(
                  child: ListView.builder(
                    key: const ValueKey('rebuild-rail'),
                    controller: controller,
                    scrollDirection: Axis.horizontal,
                    itemCount: 20,
                    itemBuilder: (_, index) => SizedBox(
                      width: 160,
                      child: Text('generation $generation card $index'),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      controller.jumpTo(320);
      await tester.pump();
      final position = controller.position;
      final scrollable = tester.state<ScrollableState>(find.byType(Scrollable));
      rebuild(() => generation++);
      await tester.pump();
      expect(controller.offset, 320);
      expect(controller.position, same(position));
      expect(
        tester.state<ScrollableState>(find.byType(Scrollable)),
        same(scrollable),
      );
      await tester.drag(
        find.byKey(const ValueKey('rebuild-rail')),
        const Offset(-250, 0),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controller.offset, greaterThan(320));
    },
  );

  testWidgets('touch and trackpad retain horizontal scrolling', (tester) async {
    final controllers = await mount(tester, onTap: () {});
    final rail = find.byKey(const ValueKey('horizontal'));
    await tester.drag(
      rail,
      const Offset(-250, 0),
      kind: PointerDeviceKind.touch,
    );
    await tester.pumpAndSettle();
    expect(controllers.horizontal.offset, greaterThan(0));
    controllers.horizontal.jumpTo(0);
    final gesture = await tester.createGesture(
      kind: PointerDeviceKind.trackpad,
    );
    await gesture.panZoomStart(tester.getCenter(rail));
    await gesture.panZoomUpdate(
      tester.getCenter(rail),
      pan: const Offset(-250, 0),
    );
    await gesture.panZoomEnd();
    await tester.pumpAndSettle();
    expect(controllers.horizontal.offset, greaterThan(0));
  });

  testWidgets(
    'scrollbar suppression and mouse drag are local; parent Clip.none survives',
    (tester) async {
      final controllers = await mount(tester, onTap: () {});
      final rail = find.byKey(const ValueKey('horizontal'));
      final vertical = find.byKey(const ValueKey('vertical'));
      expect(
        find.byKey(const ValueKey('scrollbar-AxisDirection.right')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('scrollbar-AxisDirection.down')),
        findsOneWidget,
      );
      final railContext = tester.element(rail);
      const parent = _ParentBehavior();
      final local = ScrollConfiguration.of(railContext);
      expect(local.dragDevices, containsAll(parent.dragDevices));
      expect(local.dragDevices, contains(PointerDeviceKind.mouse));
      expect(
        ScrollConfiguration.of(tester.element(vertical)).dragDevices,
        isNot(contains(PointerDeviceKind.mouse)),
      );
      expect(
        tester
            .widgetList<ClipRect>(find.byType(ClipRect))
            .where((clip) => clip.clipBehavior == Clip.none),
        hasLength(2),
      );
      await tester.drag(
        vertical,
        const Offset(0, -250),
        kind: PointerDeviceKind.mouse,
      );
      await tester.pumpAndSettle();
      expect(controllers.vertical.offset, 0);
      await tester.drag(
        vertical,
        const Offset(0, -250),
        kind: PointerDeviceKind.touch,
      );
      await tester.pumpAndSettle();
      expect(controllers.vertical.offset, greaterThan(0));
    },
  );
}
