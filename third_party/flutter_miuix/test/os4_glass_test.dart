import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart';

Widget app(Widget child) => MiuixSystemTheme(
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await MiuixGlassRendering.load();
  });
  test('OS4 保留 35 组 token 与 176 个五字重图标', () {
    expect(MiuixGlassStyles.values.length, 35);
    expect(MiuixIcons.os4.names.length, 176);
    for (final name in MiuixIcons.os4.names) {
      for (final weight in MiuixIconWeight.values) {
        final icon = MiuixIcons.os4.byName(name, weight)!;
        expect(icon.paths, isNotEmpty);
        final metrics = icon.paths.single.build().computeMetrics().toList();
        expect(metrics, isNotEmpty, reason: '$name / $weight');
        expect(
          metrics.every((m) => m.isClosed),
          isTrue,
          reason: '$name / $weight',
        );
      }
    }
    expect(MiuixIcons.os4.chevronBackward.autoMirror, isTrue);
    expect(MiuixIcons.os4.search.autoMirror, isFalse);
  });
  testWidgets('捕获子树不重绘时 backdrop 坐标仍跟随布局变化', (tester) async {
    // 捕获节点是重绘边界：内容不变时它被移动只会更新图层变换，不会再 paint。
    // 坐标必须在读取时算，否则消费者会按旧原点采样快照（表面被切成一半有背景、一半全透）。
    final backdrop = MiuixLayerBackdrop();
    addTearDown(backdrop.dispose);
    var top = 0.0;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                Positioned(
                  left: 0,
                  top: top,
                  width: 200,
                  height: 100,
                  child: MiuixLayerBackdropCapture(
                    backdrop: backdrop,
                    child: const ColoredBox(color: Color(0xFF2196F3)),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final before = backdrop.globalOffset;
    final snapshot = backdrop.snapshot;
    expect(before, isNotNull);
    update(() => top = 120);
    await tester.pumpAndSettle();
    expect(
      identical(backdrop.snapshot, snapshot),
      isTrue,
      reason: '前提：内容没变，捕获子树不应重绘，快照仍是旧的',
    );
    expect(backdrop.globalOffset!.dy - before!.dy, 120);
  });
  testWidgets('卸载后挂起的捕获回调不抛异常', (tester) async {
    final backdrop = MiuixLayerBackdrop();
    addTearDown(backdrop.dispose);
    await tester.pumpWidget(
      app(
        const SizedBox(
          width: 200,
          height: 100,
          child: ColoredBox(color: Color(0xFF2196F3)),
        ),
      ),
    );
    await tester.pumpWidget(
      app(
        SizedBox(
          width: 200,
          height: 100,
          child: MiuixLayerBackdropCapture(
            backdrop: backdrop,
            child: const ColoredBox(color: Color(0xFF2196F3)),
          ),
        ),
      ),
    );
    await tester.pumpWidget(app(const SizedBox.shrink()));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
  testWidgets('独立标签、连体标签和图标按钮可交互', (tester) async {
    var selected = 0, taps = 0;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) => Center(
            child: SizedBox(
              width: 360,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MiuixGlassTabRow(
                    tabs: const ['A', 'B'],
                    selectedIndex: selected,
                    onSelect: (i) => setState(() => selected = i),
                  ),
                  MiuixGlassSegmentedTabRow(
                    tabs: const ['C', 'D'],
                    selectedIndex: selected,
                    onSelect: (i) => setState(() => selected = i),
                  ),
                  MiuixGlassIconButton(
                    onPressed: () => taps++,
                    child: const Icon(Icons.search),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(selected, 1);
    await tester.tap(find.text('C'));
    await tester.pumpAndSettle();
    expect(selected, 0);
    await tester.tap(find.byType(MiuixGlassIconButton));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('玻璃导航允许拖拽、动态缩减项目与显隐', (tester) async {
    var selected = 0, visible = true;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  visible: visible,
                  items: const [
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.home),
                      label: 'Home',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.settings),
                      label: 'Settings',
                    ),
                  ],
                  selectedIndex: selected,
                  onSelect: (i) => setState(() => selected = i),
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byType(MiuixGlassNavigationBar));
    final gesture = await tester.startGesture(
      Offset(bar.left + 50, bar.center.dy),
    );
    await gesture.moveTo(Offset(bar.right - 50, bar.center.dy));
    await tester.pump();
    expect(selected, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(selected, 1);
    update(() => visible = false);
    await tester.pumpAndSettle();
    update(() => visible = true);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
  testWidgets('拖拽滑块只预览不切换，松手才提交', (tester) async {
    var selected = 0;
    final calls = <int>[];
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  items: const [
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.home),
                      label: 'A',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.search),
                      label: 'B',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.settings),
                      label: 'C',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.more_horiz),
                      label: 'More',
                    ),
                  ],
                  selectedIndex: selected,
                  onSelect: (i) {
                    calls.add(i);
                    setState(() => selected = i);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Offset centerOf(String label) => tester.getCenter(find.text(label));
    double indicatorLeft() => tester
        .widget<Positioned>(
          find
              .ancestor(
                of: find.byType(AnimatedContainer),
                matching: find.byType(Positioned),
              )
              .first,
        )
        .left!;
    final gesture = await tester.startGesture(centerOf('A'));
    await tester.pump();
    final leftAtA = indicatorLeft();
    await gesture.moveTo(centerOf('B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(calls, isEmpty);
    expect(selected, 0);
    final leftAtB = indicatorLeft();
    expect(leftAtB, isNot(leftAtA));
    await gesture.moveTo(centerOf('C'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(calls, isEmpty);
    expect(selected, 0);
    expect(indicatorLeft(), isNot(leftAtB));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, [2]);
    expect(selected, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets('点按未选中项提交一次，点按当前项不回调', (tester) async {
    var selected = 0;
    final calls = <int>[];
    List<MiuixGlassNavigationItem> items() => const [
      MiuixGlassNavigationItem(icon: Icon(Icons.home), label: 'A'),
      MiuixGlassNavigationItem(icon: Icon(Icons.search), label: 'B'),
      MiuixGlassNavigationItem(icon: Icon(Icons.settings), label: 'C'),
    ];
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  items: items(),
                  selectedIndex: selected,
                  onSelect: (i) {
                    calls.add(i);
                    setState(() => selected = i);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(selected, 1);
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(calls, [1]);
    calls.clear();
    await tester.pumpWidget(
      app(
        Center(
          child: SizedBox(
            width: 320,
            child: MiuixGlassNavigationBar(
              items: items(),
              selectedIndex: 0,
              onSelect: calls.add,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('拖拽取消与越界松手不提交，拖回内可提交', (tester) async {
    var selected = 0;
    final calls = <int>[];
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  items: const [
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.home),
                      label: 'A',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.search),
                      label: 'B',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.settings),
                      label: 'C',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.more_horiz),
                      label: 'More',
                    ),
                  ],
                  selectedIndex: selected,
                  onSelect: (i) {
                    calls.add(i);
                    setState(() => selected = i);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byType(MiuixGlassNavigationBar));
    Offset centerOf(String label) => tester.getCenter(find.text(label));
    var gesture = await tester.startGesture(centerOf('A'));
    await tester.pump();
    await gesture.moveTo(centerOf('More'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(calls, isEmpty);
    await gesture.cancel();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(selected, 0);
    gesture = await tester.startGesture(centerOf('A'));
    await tester.pump();
    await gesture.moveTo(centerOf('C'));
    await gesture.moveTo(Offset(bar.center.dx, bar.bottom + 30));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(selected, 0);
    gesture = await tester.startGesture(centerOf('A'));
    await tester.pump();
    await gesture.moveTo(Offset(bar.center.dx, bar.bottom + 30));
    await gesture.moveTo(centerOf('B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('RTL 下拖拽仍按视觉位置提交', (tester) async {
    var selected = 0;
    final calls = <int>[];
    await tester.pumpWidget(
      app(
        Directionality(
          textDirection: TextDirection.rtl,
          child: StatefulBuilder(
            builder: (context, setState) {
              return Center(
                child: SizedBox(
                  width: 320,
                  child: MiuixGlassNavigationBar(
                    items: const [
                      MiuixGlassNavigationItem(
                        icon: Icon(Icons.home),
                        label: 'A',
                      ),
                      MiuixGlassNavigationItem(
                        icon: Icon(Icons.search),
                        label: 'B',
                      ),
                      MiuixGlassNavigationItem(
                        icon: Icon(Icons.settings),
                        label: 'C',
                      ),
                      MiuixGlassNavigationItem(
                        icon: Icon(Icons.more_horiz),
                        label: 'More',
                      ),
                    ],
                    selectedIndex: selected,
                    onSelect: (i) {
                      calls.add(i);
                      setState(() => selected = i);
                    },
                  ),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final gesture = await tester.startGesture(tester.getCenter(find.text('A')));
    await tester.pump();
    await gesture.moveTo(tester.getCenter(find.text('C')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    expect(calls, isEmpty);
    expect(selected, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, [2]);
    expect(selected, 2);
    expect(tester.takeException(), isNull);
  });
  testWidgets('拖动中隐藏或缩减项目时松手不提交，恢复后点按可用', (tester) async {
    var selected = 0, visible = true, itemCount = 4;
    final calls = <int>[];
    const allItems = [
      MiuixGlassNavigationItem(icon: Icon(Icons.home), label: 'A'),
      MiuixGlassNavigationItem(icon: Icon(Icons.search), label: 'B'),
      MiuixGlassNavigationItem(icon: Icon(Icons.settings), label: 'C'),
      MiuixGlassNavigationItem(icon: Icon(Icons.more_horiz), label: 'More'),
    ];
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  visible: visible,
                  items: allItems.take(itemCount).toList(),
                  selectedIndex: selected,
                  onSelect: (i) {
                    calls.add(i);
                    setState(() => selected = i);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Offset centerOf(String label) => tester.getCenter(find.text(label));
    var gesture = await tester.startGesture(centerOf('A'));
    await tester.pump();
    update(() => visible = false);
    await tester.pumpAndSettle();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    expect(selected, 0);
    update(() => visible = true);
    await tester.pumpAndSettle();
    await tester.tap(find.text('B'));
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(selected, 1);
    gesture = await tester.startGesture(centerOf('A'));
    await tester.pump();
    update(() => itemCount = 2);
    await tester.pump();
    await gesture.up();
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(tester.takeException(), isNull);
  });
  testWidgets('第二根手指不抢占拖动，只有原指针松手提交', (tester) async {
    var selected = 0;
    final calls = <int>[];
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  items: const [
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.home),
                      label: 'A',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.search),
                      label: 'B',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.settings),
                      label: 'C',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.more_horiz),
                      label: 'More',
                    ),
                  ],
                  selectedIndex: selected,
                  onSelect: (i) {
                    calls.add(i);
                    setState(() => selected = i);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Offset centerOf(String label) => tester.getCenter(find.text(label));
    final finger1 = await tester.startGesture(centerOf('A'));
    await tester.pump();
    await finger1.moveTo(centerOf('B'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 80));
    final finger2 = await tester.startGesture(centerOf('C'));
    await tester.pump();
    await finger2.up();
    await tester.pump();
    expect(calls, isEmpty);
    await finger1.up();
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(selected, 1);
    expect(tester.takeException(), isNull);
  });
  for (final direction in TextDirection.values) {
    testWidgets('拖动逐帧跟手且跨项与反向不跳跃：$direction', (tester) async {
      final calls = <int>[];
      await tester.pumpWidget(
        app(
          Directionality(
            textDirection: direction,
            child: Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  items: const [
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.home),
                      label: 'A',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.search),
                      label: 'B',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.settings),
                      label: 'C',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.more_horiz),
                      label: 'D',
                    ),
                  ],
                  selectedIndex: 0,
                  onSelect: calls.add,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bar = tester.getRect(find.byType(MiuixGlassNavigationBar));
      final panel = tester.widget<MiuixGlassPanel>(
        find.byType(MiuixGlassPanel),
      );
      Rect indicator() => tester.getRect(find.byType(AnimatedContainer));
      final gesture = await tester.startGesture(
        tester.getCenter(find.text('A')),
      );
      await tester.pumpAndSettle();
      for (final x in [
        60.0,
        82.0,
        84.0,
        86.0,
        130.0,
        158.0,
        160.0,
        162.0,
        220.0,
        240.0,
        218.0,
        162.0,
        160.0,
        158.0,
        84.0,
        60.0,
      ]) {
        await gesture.moveTo(Offset(bar.left + x, bar.center.dy));
        await tester.pump(const Duration(milliseconds: 8));
        expect(indicator().left - bar.left, closeTo(x - 43, .01));
        expect(indicator().width, closeTo(86, .01));
        expect(calls, isEmpty);
        expect(
          identical(
            tester.widget<MiuixGlassPanel>(find.byType(MiuixGlassPanel)),
            panel,
          ),
          isTrue,
        );
      }
      await gesture.cancel();
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(
        indicator().left - bar.left,
        closeTo(direction == TextDirection.ltr ? 3 : 231, .01),
      );
      expect(tester.binding.hasScheduledFrame, isFalse);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('键盘激活与无障碍点按仍可提交选择', (tester) async {
    var selected = 0;
    final calls = <int>[];
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            return Center(
              child: SizedBox(
                width: 320,
                child: MiuixGlassNavigationBar(
                  items: const [
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.home),
                      label: 'A',
                      contentDescription: '目的地A',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.search),
                      label: 'B',
                      contentDescription: '目的地B',
                    ),
                    MiuixGlassNavigationItem(
                      icon: Icon(Icons.settings),
                      label: 'C',
                      contentDescription: '目的地C',
                    ),
                  ],
                  selectedIndex: selected,
                  onSelect: (i) {
                    calls.add(i);
                    setState(() => selected = i);
                  },
                ),
              ),
            );
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    Actions.invoke(tester.element(find.text('B')), const ActivateIntent());
    await tester.pumpAndSettle();
    expect(calls, [1]);
    expect(selected, 1);
    calls.clear();
    final semantics = tester.ensureSemantics();
    final node = tester.getSemantics(find.bySemanticsLabel(RegExp('目的地C')));
    tester.binding.renderViews.first.owner!.semanticsOwner!.performAction(
      node.id,
      ui.SemanticsAction.tap,
    );
    await tester.pumpAndSettle();
    expect(calls, [2]);
    expect(selected, 2);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });
  testWidgets('普通弹窗关闭后恢复底层触摸，支持重复打开和 Escape', (tester) async {
    var show = false, taps = 0, actions = 0;
    late StateSetter update;
    await tester.pumpWidget(
      app(
        StatefulBuilder(
          builder: (context, setState) {
            update = setState;
            return Stack(
              children: [
                Center(
                  child: TextButton(
                    onPressed: () => taps++,
                    child: const Text('underneath'),
                  ),
                ),
                MiuixGlassPopup(
                  show: show,
                  onDismissRequest: () => setState(() => show = false),
                  anchorBounds: const Rect.fromLTWH(150, 100, 44, 44),
                  child: MiuixGlassPopupItem(
                    text: 'Action',
                    onPressed: () {
                      actions++;
                      setState(() => show = false);
                    },
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
    for (var i = 0; i < 2; i++) {
      update(() => show = true);
      await tester.pumpAndSettle();
      expect(find.text('Action'), findsOneWidget);
      await tester.tap(find.text('Action'));
      await tester.pumpAndSettle();
      expect(find.text('Action'), findsNothing);
      await tester.tap(find.text('underneath'));
      await tester.pump();
    }
    expect(actions, 2);
    expect(taps, 2);
    update(() => show = true);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(show, isFalse);
    expect(find.text('Action'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
