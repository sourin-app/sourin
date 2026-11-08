// Historical filename retained for existing test selectors. Current assertions
// use actual Miuix controls and preserve Detail action behavior.
import 'dart:ui' as raster;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' as sdk;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as material;
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/design/widgets/app_outlined_button.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

const _actionKeys = [
  'detail-action-favorite',
  'detail-action-follow',
  'detail-action-switch-source',
  'detail-action-download',
];
const _captureKey = ValueKey('outlined-surface-capture');

Widget _host(Widget child, {Brightness brightness = Brightness.dark}) {
  final theme = AppTheme.themeFor(brightness);
  return material.MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    themeAnimationDuration: Duration.zero,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: material.Scaffold(body: child),
  );
}

Future<void> _mountDetail(WidgetTester tester) async {
  NetworkStatus.debugProbe = () async => true;
  addTearDown(NetworkStatus.debugResetForTest);
  await tester.binding.setSurfaceSize(const Size(433, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final key = GlobalKey<State<DetailPage>>();
  await tester.pumpWidget(
    _host(DetailPage(key: key, provider: 'cycani', id: '3862', embedded: true)),
  );
  await tester.pump(const Duration(milliseconds: 50));
  expect(tester.takeException(), isNull);
  const detail = MediaDetail(
    id: '3862',
    title: '在线剧',
    episodes: [Episode(id: 'ep-1', title: '第01集')],
  );
  // Inject data only; the real DetailPage builds its production action row.
  // ignore: avoid_dynamic_calls
  (key.currentState! as dynamic).debugSetDetail(
    detail,
    episodes: detail.episodes,
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  expect(tester.takeException(), isNull);
}

bool _primaryFocusWithin(Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final elements = finder.evaluate().toSet();
  var found = elements.contains(context);
  context.visitAncestorElements((element) {
    if (elements.contains(element)) found = true;
    return !found;
  });
  return found;
}

Future<void> _tabTo(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 8 && !_primaryFocusWithin(finder); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(
    _primaryFocusWithin(finder),
    isTrue,
    reason: 'Button must be reachable by Tab',
  );
}

void _expectMiuixButton(Finder action) {
  expect(
    find.descendant(of: action, matching: find.byType(miuix.MiuixButton)),
    findsOneWidget,
  );
  expect(
    find.descendant(of: action, matching: find.byType(material.OutlinedButton)),
    findsNothing,
  );
  expect(
    find.descendant(of: action, matching: find.byType(sdk.OutlinedButton)),
    findsNothing,
  );
}

Future<Color> _surfacePixel(WidgetTester tester) async {
  final rect = tester.getRect(find.byType(miuix.MiuixButton));
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(_captureKey),
  );
  // Inside the top-center surface, above text and clear of the curved edge.
  final point = boundary.globalToLocal(Offset(rect.center.dx, rect.top + 4));
  final result = await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    try {
      final bytes = (await image.toByteData(
        format: raster.ImageByteFormat.rawRgba,
      ))!;
      final offset = (point.dy.floor() * image.width + point.dx.floor()) * 4;
      return Color.fromARGB(
        bytes.getUint8(offset + 3),
        bytes.getUint8(offset),
        bytes.getUint8(offset + 1),
        bytes.getUint8(offset + 2),
      );
    } finally {
      image.dispose();
    }
  });
  return result!;
}

void main() {
  testWidgets(
    'real Detail actions render Miuix buttons with equal Windows and Android geometry',
    (tester) async {
      final downloadSizes = <TargetPlatform, Size>{};
      try {
        for (final platform in [
          TargetPlatform.windows,
          TargetPlatform.android,
        ]) {
          debugDefaultTargetPlatformOverride = platform;
          await _mountDetail(tester);
          expect(find.byType(DetailPage), findsOneWidget);
          Size? baseline;
          for (final key in _actionKeys) {
            final action = find.byKey(ValueKey(key));
            expect(action, findsOneWidget);
            _expectMiuixButton(action);
            final rect = tester.getRect(action);
            baseline ??= rect.size;
            expect(
              rect.size,
              baseline,
              reason: '$platform: $key must match its siblings',
            );
            expect(rect.width, inInclusiveRange(40, 100));
            expect(
              rect.height,
              greaterThanOrEqualTo(
                platform == TargetPlatform.android ? 48 : 32,
              ),
            );
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(433));
          }
          final download = tester.getSize(
            find.byKey(const ValueKey('detail-action-download')),
          );
          final follow = tester.getSize(
            find.byKey(const ValueKey('detail-action-follow')),
          );
          expect((download.width - follow.width).abs(), lessThan(8));
          downloadSizes[platform] = download;
          await tester.pumpWidget(const SizedBox.shrink());
        }
        expect(
          downloadSizes[TargetPlatform.android]!.height,
          greaterThan(downloadSizes[TargetPlatform.windows]!.height),
          reason: 'The platform override must exercise both compact and touch geometry',
        );
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    },
  );

  testWidgets(
    'real download action shows and removes its actual Miuix tooltip',
    (tester) async {
      await _mountDetail(tester);
      final download = find.byKey(const ValueKey('detail-action-download'));
      expect(
        find.descendant(
          of: download,
          matching: find.byType(miuix.MiuixTooltipBox),
        ),
        findsOneWidget,
      );
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      final before = find.text('下载').evaluate().length;
      final mouse = await tester.createGesture(
        kind: raster.PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: Offset.zero);
      try {
        await mouse.moveTo(tester.getCenter(download));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 600));
        await tester.pumpAndSettle();
        expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(miuix.MiuixPlainTooltip),
            matching: find.text('下载'),
          ),
          findsOneWidget,
        );
        expect(find.text('下载').evaluate().length, before + 1);
        await mouse.moveTo(Offset.zero);
        await tester.pumpAndSettle();
        expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        await mouse.removePointer();
      }
    },
  );

  testWidgets(
    'real download callback opens both menu choices and Escape dismisses the popup',
    (tester) async {
      await _mountDetail(tester);
      await tester.tap(find.byKey(const ValueKey('detail-action-download')));
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixWindowListPopup), findsOneWidget);
      expect(find.text('下载本集'), findsOneWidget);
      expect(find.text('下载全部集（1 集）'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixWindowListPopup), findsNothing);
      expect(find.byType(DetailPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outlined action preserves pointer keyboard remote and semantic activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var activations = 0;
        await tester.pumpWidget(
          _host(
            Center(
              child: AppOutlinedButton(
                onPressed: () => activations++,
                child: const Text('返回'),
              ),
            ),
          ),
        );
        final action = find.byType(AppOutlinedButton);
        _expectMiuixButton(action);
        final node = tester.getSemantics(find.bySemanticsLabel('返回').first);
        expect(
          node.hasFlag(raster.SemanticsFlag.isButton),
          isTrue,
          reason: node.owner?.rootSemanticsNode?.toStringDeep(),
        );
        expect(node.hasFlag(raster.SemanticsFlag.isEnabled), isTrue);
        expect(
          node.getSemanticsData().hasAction(raster.SemanticsAction.tap),
          isTrue,
        );
        await tester.tap(action);
        await tester.pump();
        expect(activations, 1);
        await _tabTo(tester, action);
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.select,
        ]) {
          await tester.sendKeyEvent(key);
          await tester.pump();
        }
        expect(activations, 4);
        node.owner!.performAction(node.id, raster.SemanticsAction.tap);
        await tester.pump();
        expect(activations, 5);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'real Detail error action returns to its previous route by keyboard',
    (tester) async {
      late BuildContext home;
      await tester.binding.setSurfaceSize(const Size(800, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _host(
          Builder(
            builder: (context) {
              home = context;
              return const Center(child: Text('前一页'));
            },
          ),
        ),
      );
      final detailKey = GlobalKey<State<DetailPage>>();
      Navigator.of(home).push<void>(
        material.MaterialPageRoute<void>(
          builder: (_) => DetailPage(
            key: detailKey,
            provider: 'test-provider',
            id: 'test-id',
          ),
        ),
      );
      // Mount the route before injecting its deterministic error state. An
      // indeterminate loading animation cannot settle while data is pending.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(detailKey.currentState, isNotNull);
      // ignore: avoid_dynamic_calls
      (detailKey.currentState! as dynamic).debugSetError('详情暂时不可用');
      await tester.pumpAndSettle();
      expect(find.text('详情暂时不可用'), findsOneWidget);
      final back = find.widgetWithText(AppOutlinedButton, '返回');
      expect(back, findsOneWidget);
      _expectMiuixButton(back);
      await _tabTo(tester, back);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.byType(DetailPage), findsNothing);
      expect(find.text('前一页'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'disabling the same outlined action removes pointer keyboard and semantic activation',
    (tester) async {
      final semantics = tester.ensureSemantics();
      final enabled = ValueNotifier(true);
      final before = FocusNode();
      final after = FocusNode();
      addTearDown(() {
        enabled.dispose();
        before.dispose();
        after.dispose();
      });
      try {
        var activations = 0;
        await tester.pumpWidget(
          _host(
            Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: enabled,
                builder: (_, value, __) => Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ui.TextButton(
                      focusNode: before,
                      onPressed: () {},
                      child: const Text('前一项'),
                    ),
                    AppOutlinedButton(
                      onPressed: value ? () => activations++ : null,
                      child: const Text('执行'),
                    ),
                    ui.TextButton(
                      focusNode: after,
                      onPressed: () {},
                      child: const Text('后一项'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        final action = find.byType(AppOutlinedButton);
        before.requestFocus();
        await tester.pump();
        await _tabTo(tester, action);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        expect(activations, 1);
        enabled.value = false;
        await tester.pumpAndSettle();
        _expectMiuixButton(action);
        final disabled = tester.getSemantics(find.bySemanticsLabel('执行').first);
        expect(disabled.hasFlag(raster.SemanticsFlag.isButton), isTrue);
        expect(disabled.hasFlag(raster.SemanticsFlag.hasEnabledState), isTrue);
        expect(disabled.hasFlag(raster.SemanticsFlag.isEnabled), isFalse);
        expect(
          disabled.getSemanticsData().hasAction(raster.SemanticsAction.tap),
          isFalse,
        );
        await tester.tap(action, warnIfMissed: false);
        await tester.pump();
        for (final key in [
          LogicalKeyboardKey.enter,
          LogicalKeyboardKey.space,
          LogicalKeyboardKey.select,
        ]) {
          await tester.sendKeyEvent(key);
        }
        expect(activations, 1);
        before.requestFocus();
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(
          after.hasPrimaryFocus,
          isTrue,
          reason: 'Tab must skip the disabled action',
        );
        enabled.value = true;
        await tester.pumpAndSettle();
        before.requestFocus();
        await tester.pump();
        await _tabTo(tester, action);
        await tester.sendKeyEvent(LogicalKeyboardKey.select);
        await tester.pump();
        await tester.tap(action);
        await tester.pump();
        expect(
          activations,
          3,
          reason: 'Re-enabling must restore both input paths',
        );
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    },
  );

  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'actual Miuix button surface paints enabled and disabled colors in $brightness',
      (tester) async {
        final painted = <Color>[];
        for (final enabled in [true, false]) {
          await tester.pumpWidget(
            _host(
              Center(
                child: RepaintBoundary(
                  key: _captureKey,
                  child: SizedBox(
                    width: 180,
                    height: 80,
                    child: Center(
                      child: AppOutlinedButton(
                        onPressed: enabled ? () {} : null,
                        child: const Text('操作'),
                      ),
                    ),
                  ),
                ),
              ),
              brightness: brightness,
            ),
          );
          await tester.pumpAndSettle();
          _expectMiuixButton(find.byType(AppOutlinedButton));
          final colors = miuix.MiuixTheme.of(
            tester.element(find.byType(miuix.MiuixButton)),
          ).colors;
          final pixel = await _surfacePixel(tester);
          expect(
            pixel,
            enabled ? colors.secondaryVariant : colors.disabledSecondaryVariant,
          );
          painted.add(pixel);
        }
        expect(
          painted.last,
          isNot(painted.first),
          reason: 'Disabled state must change the painted surface',
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
