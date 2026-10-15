// =======================================================================
//  CR-20 regression gate: blockword field must not rebuild its controller
//  (updated 2026-10-15 for the chip + search redesign)
// =======================================================================
//
// # Original defect (CR-20, fixed 2026-10)
//
// _blockWordsField() used to create a fresh TextEditingController every build,
// seeded with the normalized preference value:
//   TextEditingController(text: DanmakuConfig.blockWords.join('\n'))
// So typing one character triggered onChanged -> setBlockWords -> host rebuild
// -> a NEW controller, and the text was reset to the stored value. The user
// could never type a second blocking word.
//
// # 2026-10-15 redesign (Owner)
//   > danmaku blocking does not support search, and one-word-per-line wastes
//   > far too much space.
// The multi-line blob TextField was replaced by:
//   1. search box (only when there are >= 9 words)
//   2. chip wrap (tap x to delete)
//   3. add field (Enter or the plus button)
//
// # Why this gate was KEPT (this is the important part)
//
// The redesign changed the EDITING SURFACE, but the CR-20 lesson is exactly as
// true as before: the add field's controller must live on the State and
// survive the whole dialog lifetime. If it ever goes back to "new controller
// each build", the symptom is identical -- one keystroke gets wiped, because
// the host rebuilds the panel on every onChanged.
//
// So the original assertions are preserved and retargeted from the multi-line
// blob to the new single-word + Enter path.

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

void main() {
  // Blocking words are global static state => reset so words from one case do
  // not leak into the next (both false reds and false greens start here).
  setUp(() {
    UiPrefs.debugResetForTest();
  });

  const state = DanmakuSettingsState(
    enabled: true,
    appId: '',
    appSecret: '',
    fontScale: 1.0,
    opacity: 1.0,
    speed: 8.0,
    area: 1.0,
  );

  /// The blockword ADD field -- the LAST TextField in the panel.
  ///
  /// It is last because the order is: add field, then search box (only when
  /// there are many words). With few words there is no search box, so the add
  /// field is last; with many, the search box comes BEFORE it (see the
  /// _blockWordsHeader / _blockWordsAddField call order), so last still hits
  /// the add field.
  Finder addField() => find.byType(TextField).last;

  String boxText(WidgetTester t) =>
      t.widget<TextField>(addField()).controller?.text ?? '';

  /// UiPrefs.set() schedules a 300ms debounced flush; without draining it,
  /// flutter_test reports pending timers at teardown.
  Future<void> settle(WidgetTester t) async {
    await t.pump();
    await t.pump(const Duration(milliseconds: 450));
  }

  /// Host: rebuild the whole dialog on every onChanged (the real player_page
  /// path). The returned closure asserts the callback actually fired.
  Future<void Function()> pumpDialog(WidgetTester t) async {
    t.view.physicalSize = const Size(1200, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.reset);
    final rebuild = ValueNotifier<int>(0);
    addTearDown(rebuild.dispose);
    var changed = 0;
    await t.pumpWidget(MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            ValueListenableBuilder<int>(
              valueListenable: rebuild,
              builder: (context, _, __) => DanmakuSettingsDialog(
                state: state,
                onSetEnabled: (_) {},
                onSetFontScale: (_) {},
                onSetOpacity: (_) {},
                onSetSpeed: (_) {},
                onSetArea: (_) {},
                onReload: () {},
                onClose: () {},
                onChanged: () {
                  changed++;
                  rebuild.value++;
                },
              ),
            ),
          ],
        ),
      ),
    ));
    await t.pump();
    return () {
      expect(changed, greaterThan(0), reason: 'changing blockwords must notify the host');
    };
  }

  // ---------------------------------------------------------------------
  //  1. CR-20 original assertions (lesson unchanged, path retargeted)
  // ---------------------------------------------------------------------

  testWidgets('typing character-by-character must not be wiped by a rebuild (CR-20)',
      (t) async {
    await pumpDialog(t);
    await t.showKeyboard(addField());

    var step = '';
    for (final next in <String>['a', 'ab', 'abc', 'abcd']) {
      step = next;
      await t.enterText(addField(), next);
      await settle(t);
      expect(boxText(t), next,
          reason: 'the host rebuilds the dialog on every onChanged; by this step '
              'the field content was wiped (controller created per build again?)');
    }
    expect(step, 'abcd', reason: 'precondition: the loop reached the last step');
    // Not submitted yet => must not be persisted (the redesign submits on Enter)
    expect(DanmakuConfig.blockWords, isEmpty,
        reason: 'typing without pressing Enter must not persist anything');
  });

  testWidgets('changing blockwords must notify the host', (t) async {
    final assertRebuilt = await pumpDialog(t);
    await t.enterText(addField(), 'spoiler');
    await settle(t);
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    assertRebuilt();
  });

  // ---------------------------------------------------------------------
  //  2. New assertions: add / dedupe / exact delete / search
  // ---------------------------------------------------------------------

  testWidgets('Enter adds a word and clears the box (so a second word can be added)',
      (t) async {
    await pumpDialog(t);
    await t.showKeyboard(addField());

    await t.enterText(addField(), 'spoiler');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    expect(DanmakuConfig.blockWords, orderedEquals(<String>['spoiler']),
        reason: 'first word should be persisted');
    expect(boxText(t), '', reason: 'box must clear, otherwise no second word can be added');

    await t.enterText(addField(), 'second');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    expect(
      DanmakuConfig.blockWords,
      orderedEquals(<String>['spoiler', 'second']),
      reason: 'the second word must really be persisted',
    );
    expect(boxText(t), '', reason: 'box must clear again');
  });

  testWidgets('a duplicate word is not added twice', (t) async {
    DanmakuConfig.setBlockWords('spoiler');
    await pumpDialog(t);
    await t.showKeyboard(addField());

    await t.enterText(addField(), 'spoiler');
    await t.testTextInput.receiveAction(TextInputAction.done);
    await settle(t);
    expect(DanmakuConfig.blockWords, orderedEquals(<String>['spoiler']),
        reason: 'an existing word must not be appended again');
  });

  testWidgets('delete removes only the EXACT match (no prefix collateral)', (t) async {
    // 'spoiler' and 'spoiler warning' are both words; deleting 'spoiler' must
    // not also remove 'spoiler warning'.
    DanmakuConfig.setBlockWords('spoiler\nspoiler warning\nother');
    await pumpDialog(t);

    final del = find.descendant(
      of: find.byType(InputChip),
      matching: find.byIcon(Icons.close),
    );
    expect(del, findsNWidgets(3), reason: 'three words => three delete buttons');

    /*
     * Must ensureVisible before tapping.
     *
     * The panel card is capped at maxHeight 620 and the blockword section sits
     * inside a scrolling area -- tapping directly hits empty space or gets
     * caught by the scrim (hit test showed _RenderColoredBox on top), so the
     * delete silently does nothing and the test looks like "delete is broken".
     * That is a TEST artifact, not a product bug (a real user scrolls first).
     */
    await t.ensureVisible(del.first);
    await t.pump();
    await t.tap(del.first);
    await settle(t);

    expect(
      DanmakuConfig.blockWords,
      orderedEquals(<String>['spoiler warning', 'other']),
      reason: 'only spoiler should be gone; a substring delete would eat '
          'spoiler warning too',
    );
  });

  testWidgets('search box appears only with many words, and filters', (t) async {
    // Few words (zero by default) => no search box
    await pumpDialog(t);
    expect(find.byIcon(Icons.search), findsNothing,
        reason: 'when everything fits on screen, no search box (saves space)');

    // Nine words => search box appears
    DanmakuConfig.setBlockWords(
      List<String>.generate(9, (i) => 'word$i').join('\n'),
    );
    await pumpDialog(t);
    expect(find.byIcon(Icons.search), findsOneWidget,
        reason: 'with enough words the search box must appear (what the Owner asked for)');

    // Filter down to word1
    final search = find.byType(TextField).first;
    await t.enterText(search, 'word1');
    await settle(t);
    expect(find.byType(InputChip), findsOneWidget,
        reason: 'search must actually filter out non-matching words');
  });

  testWidgets('search with no results says so (not a blank area)', (t) async {
    DanmakuConfig.setBlockWords(
      List<String>.generate(9, (i) => 'word$i').join('\n'),
    );
    await pumpDialog(t);
    final search = find.byType(TextField).first;
    await t.enterText(search, 'zzz-no-such-word');
    await settle(t);
    expect(find.byType(InputChip), findsNothing, reason: 'no matches');
    expect(find.textContaining('没有匹配'), findsOneWidget,
        reason: 'must say "no match", otherwise users think their words were lost');
  });
}
