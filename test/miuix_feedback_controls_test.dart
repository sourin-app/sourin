import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Widget feedbackHost(Widget child, {VoidCallback? onEscape}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    themeAnimationDuration: Duration.zero,
    builder: (_, child) => AppThemeHost(
      data: theme,
      child: Shortcuts(
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.escape): DismissIntent(),
        },
        child: ToastHost(child: child!),
      ),
    ),
    // Page actions belong below the route and Scaffold dismissal actions.
    // Keeping only the shortcut outside the toaster preserves toast priority.
    home: Scaffold(
      body: Actions(
        actions: {
          DismissIntent: CallbackAction<DismissIntent>(
            onInvoke: (_) {
              onEscape?.call();
              return null;
            },
          ),
        },
        child: Center(child: child),
      ),
    ),
  );
}

bool primaryFocusWithin(Finder finder) {
  final context = FocusManager.instance.primaryFocus?.context;
  if (context == null) return false;
  final targets = finder.evaluate().toSet();
  var found = targets.contains(context);
  context.visitAncestorElements((element) {
    if (targets.contains(element)) found = true;
    return !found;
  });
  return found;
}

Future<void> tabTo(WidgetTester tester, Finder target) async {
  for (var i = 0; i < 8 && !primaryFocusWithin(target); i++) {
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
  }
  expect(
    primaryFocusWithin(target),
    isTrue,
    reason: 'Control must be reachable by Tab',
  );
}

void main() {
  testWidgets(
    'actual Miuix snackbars give a later entry its complete lifetime',
    (tester) async {
      late BuildContext page;
      await tester.pumpWidget(
        feedbackHost(
          Builder(
            builder: (context) {
              page = context;
              return const Text('页面');
            },
          ),
        ),
      );
      showAppToast(page, '第一条', duration: const Duration(milliseconds: 800));
      await tester.pump();
      expect(find.byType(miuix.MiuixSnackbar), findsOneWidget);
      expect(find.text('第一条'), findsOneWidget);

      // Enqueue between shared 100ms fade ticks. A shared rounded expiration
      // would remove this second entry at 950ms instead of its full 1000ms.
      await tester.pump(const Duration(milliseconds: 550));
      showAppToast(page, '第二条', duration: const Duration(milliseconds: 1000));
      await tester.pump();
      expect(find.byType(miuix.MiuixSnackbar), findsNWidgets(2));
      await tester.pump(const Duration(milliseconds: 999));
      expect(find.text('第一条'), findsNothing);
      expect(find.text('第二条'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(miuix.MiuixSnackbar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Escape dismisses newest notification then reaches the page action',
    (tester) async {
      final pageFocus = FocusNode();
      addTearDown(pageFocus.dispose);
      late BuildContext page;
      var escapes = 0;
      await tester.pumpWidget(
        feedbackHost(
          Builder(
            builder: (context) {
              page = context;
              return ui.TextButton(
                focusNode: pageFocus,
                onPressed: () {},
                child: const Text('页面操作'),
              );
            },
          ),
          onEscape: () => escapes++,
        ),
      );
      pageFocus.requestFocus();
      await tester.pump();
      showAppToast(page, '较早的通知');
      showAppToast(page, '最新的通知');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.text('最新的通知'), findsNothing);
      expect(find.text('较早的通知'), findsOneWidget);
      expect(escapes, 0);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(miuix.MiuixSnackbar), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      expect(escapes, 1);
    },
  );

  testWidgets(
    'notification action supports click Enter and remote Select; Escape works from its focus',
    (tester) async {
      final pageFocus = FocusNode();
      addTearDown(pageFocus.dispose);
      late BuildContext page;
      var actions = 0;
      await tester.pumpWidget(
        feedbackHost(
          Builder(
            builder: (context) {
              page = context;
              return ui.TextButton(
                focusNode: pageFocus,
                onPressed: () {},
                child: const Text('页面操作'),
              );
            },
          ),
        ),
      );
      showAppToast(
        page,
        '需要重试',
        duration: const Duration(seconds: 10),
        style: AppToastStyle(actionLabel: '重试', onAction: () => actions++),
      );
      await tester.pump();
      final action = find.widgetWithText(miuix.MiuixTextButton, '重试');
      expect(action, findsOneWidget);
      await tester.tap(action);
      await tester.pump();
      expect(actions, 1);
      expect(find.text('需要重试'), findsOneWidget);

      pageFocus.requestFocus();
      await tester.pump();
      await tabTo(tester, action);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(actions, 2);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      await tester.pump();
      expect(actions, 3);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(find.byType(miuix.MiuixSnackbar), findsNothing);
      expect(actions, 3);
    },
  );

  testWidgets(
    'Tab reaches a notification without an action and Enter closes it',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final pageFocus = FocusNode();
        addTearDown(pageFocus.dispose);
        late BuildContext page;
        await tester.pumpWidget(
          feedbackHost(
            Builder(
              builder: (context) {
                page = context;
                return ui.TextButton(
                  focusNode: pageFocus,
                  onPressed: () {},
                  child: const Text('页面操作'),
                );
              },
            ),
          ),
        );
        showAppToast(page, '可由键盘关闭');
        await tester.pump();
        pageFocus.requestFocus();
        await tester.pump();
        expect(find.bySemanticsLabel('关闭提示：可由键盘关闭'), findsOneWidget);
        final close = find.ancestor(
          of: find.byType(miuix.MiuixSnackbar),
          matching: find.byType(FocusableActionDetector),
        );
        expect(close, findsOneWidget);
        await tabTo(tester, close);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();
        expect(find.byType(miuix.MiuixSnackbar), findsNothing);
      } finally {
        semantics.dispose();
      }
    },
  );

  testWidgets(
    'notification focus follows a pushed page and restores after that page is removed',
    (tester) async {
      final firstFocus = FocusNode();
      final nextFocus = FocusNode();
      addTearDown(() {
        firstFocus.dispose();
        nextFocus.dispose();
      });
      late BuildContext page;
      await tester.pumpWidget(
        feedbackHost(
          Builder(
            builder: (context) {
              page = context;
              return ui.TextButton(
                focusNode: firstFocus,
                onPressed: () {},
                child: const Text('原页面操作'),
              );
            },
          ),
        ),
      );
      firstFocus.requestFocus();
      await tester.pump();
      showAppToast(page, '跨页通知', duration: const Duration(seconds: 10));
      await tester.pump();
      expect(firstFocus.hasPrimaryFocus, isTrue);

      final navigator = Navigator.of(page);
      navigator.push<void>(
        MaterialPageRoute<void>(
          builder: (_) => Scaffold(
            body: Center(
              child: ui.TextButton(
                focusNode: nextFocus,
                autofocus: true,
                onPressed: () {},
                child: const Text('新页面操作'),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(nextFocus.hasPrimaryFocus, isTrue);
      final close = find.ancestor(
        of: find.byType(miuix.MiuixSnackbar),
        matching: find.byType(FocusableActionDetector),
      );
      await tabTo(tester, close);
      navigator.pop();
      await tester.pumpAndSettle();
      firstFocus.requestFocus();
      await tester.pump();
      await tabTo(tester, close);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('跨页通知'), findsNothing);
      expect(firstFocus.hasPrimaryFocus, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'first and last toast preserve local page state; disposal cancels all timers',
    (tester) async {
      await tester.pumpWidget(
        feedbackHost(
          const SizedBox.expand(
            child: ToastHost(child: Center(child: _CounterProbe())),
          ),
        ),
      );
      await tester.tap(find.text('计数 0'));
      await tester.pump();
      expect(find.text('计数 1'), findsOneWidget);
      final page = tester.element(find.byType(_CounterProbe));
      showAppToast(page, '短通知', duration: const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('计数 1'), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('计数 1'), findsOneWidget);
      expect(find.text('短通知'), findsNothing);
      for (var i = 0; i < 5; i++) {
        showAppToast(page, '长通知 $i', duration: const Duration(seconds: 10));
      }
      await tester.pump();
      expect(find.byType(miuix.MiuixSnackbar), findsNWidgets(4));
      expect(find.text('长通知 0'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 11));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'tooltip appears after delay, exits cleanly and cancels a pending hover',
    (tester) async {
      await tester.pumpWidget(
        feedbackHost(
          const ui.Tooltip(
            message: '延迟提示',
            waitDuration: Duration(milliseconds: 300),
            showDuration: Duration(seconds: 2),
            child: SizedBox(width: 100, height: 40, child: Text('悬停目标')),
          ),
        ),
      );
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(find.text('悬停目标')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 299));
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixTooltipBox), findsOneWidget);
      expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
      expect(find.text('延迟提示'), findsOneWidget);
      await mouse.moveTo(Offset.zero);
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);

      await mouse.moveTo(tester.getCenter(find.text('悬停目标')));
      await tester.pump(const Duration(milliseconds: 100));
      await mouse.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('延迟提示'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  for (final visible in [false, true]) {
    testWidgets(
      'disposing a ${visible ? 'visible' : 'pending'} tooltip leaves no overlay or timer',
      (tester) async {
        final mounted = ValueNotifier(true);
        addTearDown(mounted.dispose);
        await tester.pumpWidget(
          feedbackHost(
            ValueListenableBuilder<bool>(
              valueListenable: mounted,
              builder: (_, show, __) => show
                  ? const ui.Tooltip(
                      message: '将被销毁',
                      waitDuration: Duration(milliseconds: 300),
                      child: SizedBox(
                        width: 100,
                        height: 40,
                        child: Text('临时目标'),
                      ),
                    )
                  : const Text('已移除'),
            ),
          ),
        );
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: Offset.zero);
        addTearDown(mouse.removePointer);
        await mouse.moveTo(tester.getCenter(find.text('临时目标')));
        await tester.pump();
        await tester.pump(Duration(milliseconds: visible ? 300 : 100));
        if (visible) {
          await tester.pumpAndSettle();
          expect(find.byType(miuix.MiuixPlainTooltip), findsOneWidget);
        }
        mounted.value = false;
        await tester.pumpAndSettle();
        await tester.pump(const Duration(seconds: 3));
        expect(find.byType(miuix.MiuixTooltipBox), findsNothing);
        expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
        expect(find.text('将被销毁'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'keyboard tooltip keeps anchor activation, hides on blur, and lets Escape reach page',
    (tester) async {
      final before = FocusNode();
      final anchor = FocusNode();
      final after = FocusNode();
      addTearDown(() {
        before.dispose();
        anchor.dispose();
        after.dispose();
      });
      var activations = 0;
      var escapes = 0;
      await tester.pumpWidget(
        feedbackHost(
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ui.TextButton(
                focusNode: before,
                onPressed: () {},
                child: const Text('前一项'),
              ),
              ui.Tooltip(
                message: '键盘提示',
                waitDuration: const Duration(milliseconds: 300),
                child: ui.TextButton(
                  focusNode: anchor,
                  onPressed: () => activations++,
                  child: const Text('焦点目标'),
                ),
              ),
              ui.TextButton(
                focusNode: after,
                onPressed: () {},
                child: const Text('后一项'),
              ),
            ],
          ),
          onEscape: () => escapes++,
        ),
      );
      before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 299));
      expect(
        anchor.hasPrimaryFocus,
        isTrue,
        reason: 'Tooltip must not add a separate Tab stop',
      );
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      await tester.pumpAndSettle();
      expect(find.text('键盘提示'), findsOneWidget);
      expect(anchor.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(activations, 1);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('键盘提示'), findsNothing);
      expect(escapes, 1);
      expect(anchor.hasPrimaryFocus, isTrue);

      before.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pumpAndSettle();
      expect(find.text('键盘提示'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(after.hasPrimaryFocus, isTrue);
      expect(find.byType(miuix.MiuixPlainTooltip), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

class _CounterProbe extends StatefulWidget {
  const _CounterProbe();
  @override
  State<_CounterProbe> createState() => _CounterProbeState();
}

class _CounterProbeState extends State<_CounterProbe> {
  int count = 0;
  @override
  Widget build(BuildContext context) => ui.TextButton(
    onPressed: () => setState(() => count++),
    child: Text('计数 $count'),
  );
}
