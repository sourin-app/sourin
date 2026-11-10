import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

const _providers = [
  ProviderManifest(id: 'a', name: '甲站', kind: 'tvbox'),
  ProviderManifest(id: 'b', name: '乙站', kind: 'js', enabled: false),
  ProviderManifest(id: 'c', name: '丙站', kind: 'tvbox'),
];
const _origins = [
  SourceOrigin(
    id: 'first',
    name: '订阅甲',
    kind: 'tvbox',
    primaryUrl: 'https://first.test/config',
    providerIds: ['a'],
  ),
  SourceOrigin(
    id: 'second',
    name: '订阅乙',
    kind: 'tvbox',
    primaryUrl: 'https://second.test/config',
    providerIds: ['c'],
  ),
];

Finder _move(String id, String direction) =>
    find.byKey(ValueKey('source-order-$direction-$id'));
List<String> _visibleOrder(WidgetTester tester) {
  final ids = ['a', 'b', 'c'];
  ids.sort(
    (a, b) => tester
        .getTopLeft(find.byKey(ValueKey(a)))
        .dy
        .compareTo(tester.getTopLeft(find.byKey(ValueKey(b))).dy),
  );
  return ids;
}

Future<void> _mount(WidgetTester tester, {VoidCallback? onSaved}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(720, 900);
  addTearDown(tester.view.reset);
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: AppScaffold(
        child: Builder(
          builder: (context) => ui.TextButton(
            onPressed: () => Navigator.of(context).push<void>(
              MaterialPageRoute<void>(
                builder: (_) => SourceOrderPage(
                  providers: _providers,
                  origins: _origins,
                  onSaved: onSaved ?? () {},
                ),
              ),
            ),
            child: const Text('打开排序'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开排序'));
  await tester.pumpAndSettle();
}

Future<void> _tabTo(WidgetTester tester, Key key) async {
  bool focused() {
    final context = FocusManager.instance.primaryFocus?.context;
    if (context == null) return false;
    var found = context.widget.key == key;
    context.visitAncestorElements((e) {
      if (e.widget.key == key) found = true;
      return !found;
    });
    return found;
  }

  for (var i = 0; i < 30 && !focused(); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(focused(), isTrue, reason: 'Order arrows must be keyboard reachable');
}

void main() {
  setUp(() => Device.overrideKind(DeviceKind.desktop));
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    Device.overrideKind(null);
  });

  testWidgets(
    'Miuix arrows move the actual row and keep origin and disabled state',
    (tester) async {
      await _mount(tester);
      expect(find.text('来自 订阅甲'), findsOneWidget);
      expect(find.text('来自 订阅乙'), findsOneWidget);
      expect(find.text('本地 JS · 已关闭'), findsOneWidget);
      expect(tester.widget<ui.IconButton>(_move('a', 'up')).onPressed, isNull);
      expect(
        tester.widget<ui.IconButton>(_move('c', 'down')).onPressed,
        isNull,
      );
      expect(
        find.descendant(
          of: _move('b', 'up'),
          matching: find.byType(miuix.MiuixIconButton),
        ),
        findsOneWidget,
      );
      final original = tester.element(find.byKey(const ValueKey('b')));
      await tester.tap(_move('b', 'up'));
      await tester.pumpAndSettle();
      expect(_visibleOrder(tester), ['b', 'a', 'c']);
      expect(tester.element(find.byKey(const ValueKey('b'))), same(original));
      expect(tester.widget<ui.IconButton>(_move('b', 'up')).onPressed, isNull);
      await tester.tap(_move('b', 'down'));
      await tester.pumpAndSettle();
      expect(_visibleOrder(tester), ['a', 'b', 'c']);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('keyboard selection moves and saves the displayed order', (
    tester,
  ) async {
    List<String>? saved;
    var notifications = 0;
    SourinCore.debugCallAsyncTransport = (command, args) async {
      expect(command, 'set_provider_order');
      saved = (args!['ids'] as List).cast<String>();
      return saved;
    };
    await _mount(tester, onSaved: () => notifications++);
    await _tabTo(tester, const ValueKey('source-order-up-b'));
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(_visibleOrder(tester), ['b', 'a', 'c']);
    await tester.tap(find.text('保存顺序'));
    await tester.pumpAndSettle();
    expect(saved, ['b', 'a', 'c']);
    expect(notifications, 1);
    expect(find.byType(SourceOrderPage), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('leaving a changed draft does not persist it', (tester) async {
    final calls = <String>[];
    SourinCore.debugCallAsyncTransport = (command, args) async {
      calls.add(command);
      return <String>[];
    };
    await _mount(tester);
    await tester.tap(_move('a', 'down'));
    await tester.pumpAndSettle();
    expect(_visibleOrder(tester), ['b', 'a', 'c']);
    await tester.tap(find.byKey(const ValueKey('page-header-back')));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
    await tester.tap(find.text('打开排序'));
    await tester.pumpAndSettle();
    expect(_visibleOrder(tester), ['a', 'b', 'c']);
  });

  testWidgets(
    'pending save freezes arrows and drag, failure retains draft for retry',
    (tester) async {
      final pending = Completer<List<String>>();
      final orders = <List<String>>[];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        expect(command, 'set_provider_order');
        orders.add((args!['ids'] as List).cast<String>().toList());
        return orders.length == 1 ? pending.future : orders.last;
      };
      await _mount(tester);
      await tester.tap(_move('b', 'up'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保存顺序'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (final button
          in tester
              .widgetList<ui.IconButton>(find.byType(ui.IconButton))
              .where(
                (w) =>
                    w.key is ValueKey<String> &&
                    (w.key! as ValueKey<String>).value.startsWith(
                      'source-order-',
                    ),
              )) {
        expect(button.onPressed, isNull);
      }
      for (final handle in tester.widgetList<ReorderableDragStartListener>(
        find.byType(ReorderableDragStartListener),
      )) {
        expect(handle.enabled, isFalse);
      }
      final lockedHandle = find.descendant(
        of: find.byKey(const ValueKey('b')),
        matching: find.byType(ReorderableDragStartListener),
      );
      final drag = await tester.startGesture(tester.getCenter(lockedHandle));
      await drag.moveBy(const Offset(0, 180));
      await tester.pump(const Duration(milliseconds: 400));
      await drag.up();
      await tester.pump();
      expect(_visibleOrder(tester), ['b', 'a', 'c']);
      expect(orders, hasLength(1));
      pending.completeError(StateError('order save failed'));
      await tester.pumpAndSettle();
      expect(find.text('操作没有完成，请稍后重试'), findsOneWidget);
      expect(_visibleOrder(tester), ['b', 'a', 'c']);
      await tester.tap(find.text('保存顺序'));
      await tester.pumpAndSettle();
      expect(orders, [
        ['b', 'a', 'c'],
        ['b', 'a', 'c'],
      ]);
      expect(find.byType(SourceOrderPage), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('actual drag handle moves the row across two positions', (
    tester,
  ) async {
    await _mount(tester);
    final start = tester.getCenter(
      find.descendant(
        of: find.byKey(const ValueKey('a')),
        matching: find.byType(ReorderableDragStartListener),
      ),
    );
    final target = tester.getCenter(
      find.descendant(
        of: find.byKey(const ValueKey('c')),
        matching: find.byType(ReorderableDragStartListener),
      ),
    );
    final gesture = await tester.startGesture(start);
    await gesture.moveBy(const Offset(0, 12));
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.moveTo(
      Offset(
        target.dx,
        tester.getBottomLeft(find.byKey(const ValueKey('c'))).dy +
            tester.getSize(find.byKey(const ValueKey('a'))).height / 2 +
            4,
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(_visibleOrder(tester), ['b', 'c', 'a']);
    expect(tester.takeException(), isNull);
  });
  testWidgets('narrow order page keeps all actions inside the viewport', (
    tester,
  ) async {
    await _mount(tester);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pumpAndSettle();
    for (final direction in ['up', 'down']) {
      final rect = tester.getRect(_move('b', direction));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(360));
    }
    await tester.tap(_move('b', 'up'));
    await tester.pumpAndSettle();
    expect(_visibleOrder(tester), ['b', 'a', 'c']);
    expect(tester.takeException(), isNull);
  });
}
