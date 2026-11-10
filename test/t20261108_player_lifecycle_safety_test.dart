import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/player/player_settings_portal.dart';
import 'package:sourin_spike/ui/titlebar_visibility.dart';

void main() {
  testWidgets(
    'mount and disposal never notify title-bar ancestors during build',
    (tester) async {
      final current = ValueNotifier<int?>(null);
      addTearDown(current.dispose);
      await tester.pumpWidget(_titleBarHost(current));
      for (var cycle = 0; cycle < 4; cycle++) {
        current.value = cycle;
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(titleBarDark.value, isTrue);
        expect(titleBarVisible.value, isTrue);
        current.value = null;
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(titleBarDark.value, isFalse);
        expect(titleBarVisible.value, isTrue);
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('replacing a player keeps the newer title-bar claim', (
    tester,
  ) async {
    final current = ValueNotifier<int?>(0);
    addTearDown(current.dispose);
    await tester.pumpWidget(_titleBarHost(current));
    final first = tester.state<_PlayerLifecycleState>(
      find.byType(_PlayerLifecycle),
    );
    first.session.setFullscreen(true);
    await tester.pump();
    expect(titleBarVisible.value, isFalse);

    // New initState happens before the previous state's end-of-frame dispose.
    current.value = 1;
    await tester.pump();
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(titleBarDark.value, isTrue);
    expect(titleBarVisible.value, isTrue);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(titleBarDark.value, isFalse);
  });

  testWidgets('a stale exit cannot release a newer fullscreen player', (
    tester,
  ) async {
    final first = PlayerTitleBarSession();
    final second = PlayerTitleBarSession()..setFullscreen(true);
    first.release();
    await tester.pump();
    expect(titleBarDark.value, isTrue);
    expect(titleBarVisible.value, isFalse);
    first.release();
    await tester.pump();
    expect(titleBarVisible.value, isFalse);
    second.release();
    await tester.pump();
    expect(titleBarDark.value, isFalse);
    expect(titleBarVisible.value, isTrue);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'settings portal survives repeated visibility and layout changes',
    (tester) async {
      final mode = ValueNotifier<int>(0);
      addTearDown(mode.dispose);
      await tester.pumpWidget(_portalHost(mode));
      for (final value in [1, 2, 1, 0, 2, 0, 1]) {
        mode.value = value;
        await tester.pump();
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(
          find.text('Settings panel'),
          value == 0 ? findsNothing : findsOneWidget,
        );
        expect(find.byType(OverlayPortal), findsOneWidget);
      }
      // Dispose while a post-frame visibility change is pending.
      mode.value = 0;
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'outgoing and incoming settings portals own separate controllers',
    (tester) async {
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Overlay(
            initialEntries: [
              OverlayEntry(
                builder: (_) => Stack(
                  children: [
                    for (final label in ['Outgoing', 'Incoming'])
                      PlayerSettingsPortal(
                        key: ValueKey(label),
                        visible: true,
                        overlayChildBuilder: (_) => Text(label),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
      expect(find.text('Outgoing'), findsOneWidget);
      expect(find.text('Incoming'), findsOneWidget);
      final portals = tester
          .widgetList<OverlayPortal>(find.byType(OverlayPortal))
          .toList();
      expect(portals[0].controller, isNot(same(portals[1].controller)));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}

Widget _titleBarHost(ValueNotifier<int?> current) => Directionality(
  textDirection: TextDirection.ltr,
  child: Column(
    children: [
      ValueListenableBuilder<bool>(
        valueListenable: titleBarDark,
        builder: (_, dark, __) => ValueListenableBuilder<bool>(
          valueListenable: titleBarVisible,
          builder: (_, visible, __) => Text('$dark / $visible'),
        ),
      ),
      Expanded(
        child: ValueListenableBuilder<int?>(
          valueListenable: current,
          builder: (_, value, __) => value == null
              ? const SizedBox.shrink()
              : _PlayerLifecycle(key: ValueKey(value)),
        ),
      ),
    ],
  ),
);

class _PlayerLifecycle extends StatefulWidget {
  const _PlayerLifecycle({super.key});
  @override
  State<_PlayerLifecycle> createState() => _PlayerLifecycleState();
}

class _PlayerLifecycleState extends State<_PlayerLifecycle> {
  late final PlayerTitleBarSession session;
  @override
  void initState() {
    super.initState();
    session = PlayerTitleBarSession();
  }

  @override
  void dispose() {
    session.release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.expand();
}

Widget _portalHost(ValueNotifier<int> mode) => Directionality(
  textDirection: TextDirection.ltr,
  child: Overlay(
    initialEntries: [
      OverlayEntry(
        builder: (_) => ValueListenableBuilder<int>(
          valueListenable: mode,
          builder: (_, value, __) {
            final portal = PlayerSettingsPortal(
              key: const ValueKey('settings'),
              visible: value != 0,
              overlayChildBuilder: (_) => const Text('Settings panel'),
            );
            return value == 2
                ? Row(children: [Expanded(child: portal)])
                : Column(children: [Expanded(child: portal)]);
          },
        ),
      ),
    ],
  ),
);
