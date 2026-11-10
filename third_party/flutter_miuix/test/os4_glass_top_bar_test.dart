import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';

Widget app(Widget child) => MiuixTheme(
  data: MiuixThemeData.light(),
  child: MaterialApp(home: Scaffold(body: child)),
);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(MiuixGlassRendering.load);
  testWidgets('顶栏交互槽只挂载一次，回到页顶清除材质而非强制展开标题', (tester) async {
    final anchor = MiuixGlassPopupAnchor(), bottom = GlobalKey();
    final behavior = MiuixExitUntilCollapsedScrollBehavior();
    var scrolled = false;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Align(
              alignment: Alignment.topCenter,
              child: MiuixGlassTopAppBar(
                title: 'OS4 title',
                scrollBehavior: behavior,
                isContentScrolled: scrolled,
                actions: [
                  MiuixGlassIconButton(
                    anchor: anchor,
                    onPressed: () {},
                    child: const Icon(Icons.more_horiz),
                  ),
                ],
                bottomContent: SizedBox(
                  key: bottom,
                  height: 40,
                  child: const Text('single bottom'),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(anchor.key, skipOffstage: false), findsOneWidget);
    expect(find.byKey(bottom, skipOffstage: false), findsOneWidget);
    expect(
      tester.widget<MiuixGlassPanel>(find.byType(MiuixGlassPanel)).alpha,
      0,
    );
    behavior.state.heightOffset = behavior.state.heightOffsetLimit;
    update(() => scrolled = true);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MiuixGlassPanel>(find.byType(MiuixGlassPanel)).alpha,
      1,
    );
    update(() => scrolled = false);
    await tester.pumpAndSettle();
    expect(
      tester.widget<MiuixGlassPanel>(find.byType(MiuixGlassPanel)).alpha,
      0,
    );
    expect(behavior.state.collapsedFraction, 1);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    anchor.dispose();
    behavior.state.dispose();
  });
  testWidgets('BlurTopAppBar 模糊大标题，原 TopAppBar 默认不模糊', (tester) async {
    final behavior = MiuixExitUntilCollapsedScrollBehavior();
    await tester.pumpWidget(
      app(
        Align(
          alignment: Alignment.topCenter,
          child: MiuixTopAppBar(title: 'Title', scrollBehavior: behavior),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsNothing);
    await tester.pumpWidget(
      app(
        Align(
          alignment: Alignment.topCenter,
          child: MiuixBlurTopAppBar(title: 'Title', scrollBehavior: behavior),
        ),
      ),
    );
    await tester.pumpAndSettle();
    behavior.state.heightOffset = behavior.state.heightOffsetLimit * .2;
    await tester.pumpAndSettle();
    expect(find.byType(ImageFiltered), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    behavior.state.dispose();
  });
  testWidgets('导航空列表与缩减项目在 RTL 大字体下安全释放', (tester) async {
    var count = 0;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Directionality(
              textDirection: TextDirection.rtl,
              child: MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(2.5)),
                child: Center(
                  child: SizedBox(
                    width: 300,
                    child: MiuixGlassNavigationBar(
                      items: [
                        for (var i = 0; i < count; i++)
                          const MiuixGlassNavigationItem(
                            icon: Icon(Icons.home),
                            label: 'A long wrapping label',
                          ),
                      ],
                      selectedIndex: 12,
                      onSelect: (_) {},
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    update(() => count = 3);
    await tester.pumpAndSettle();
    update(() => count = 1);
    await tester.pumpAndSettle();
    update(() => count = 0);
    await tester.pumpAndSettle();
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
