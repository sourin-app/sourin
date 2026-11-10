import 'package:flutter/material.dart' as sdk;
import 'package:flutter/services.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/theme/miuix_palette.dart';
import 'package:sourin_spike/ui/theme/miuix_framework_bridge.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Widget host(Widget child, {Brightness brightness = Brightness.light}) =>
    MaterialApp(
      theme: ThemeData(brightness: brightness),
      home: miuix.MiuixTheme(
        data: miuixThemeData(brightness),
        child: Scaffold(
          body: Center(child: SizedBox(width: 320, child: child)),
        ),
      ),
    );

void main() {
  for (final brightness in [Brightness.light, Brightness.dark]) {
    testWidgets(
      'list typography and disabled colors follow Miuix in $brightness',
      (tester) async {
        var activations = 0;
        await tester.pumpWidget(
          host(
            DefaultTextStyle(
              style: const TextStyle(fontSize: 11, color: Colors.red),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ui.ListTile(
                    title: const Text('可用标题'),
                    subtitle: const Text('可用说明'),
                    leading: const Text('1'),
                    onTap: () => activations++,
                  ),
                  ui.ListTile(
                    title: const Text('禁用标题'),
                    subtitle: const Text('禁用说明'),
                    leading: const Text('2'),
                    enabled: false,
                    onTap: () => activations++,
                  ),
                  const ui.ListTile(
                    title: Text(
                      '定制标题',
                      style: TextStyle(fontSize: 20, color: Colors.green),
                    ),
                  ),
                ],
              ),
            ),
            brightness: brightness,
          ),
        );
        await tester.pumpAndSettle();
        TextStyle rendered(String text) =>
            tester.renderObject<RenderParagraph>(find.text(text)).text.style!;
        expect(find.byType(miuix.MiuixBasicComponent), findsNWidgets(3));
        expect(rendered('可用标题').fontSize, 17);
        expect(rendered('可用标题').fontWeight, FontWeight.w500);
        expect(rendered('可用说明').fontSize, 14);
        expect(rendered('禁用标题').fontSize, 17);
        expect(rendered('可用标题').color, isNot(Colors.red));
        expect(rendered('禁用标题').color, isNot(rendered('可用标题').color));
        expect(rendered('禁用说明').color, rendered('禁用标题').color);
        expect(rendered('1').color, rendered('可用标题').color);
        expect(rendered('2').color, rendered('禁用标题').color);
        expect(rendered('定制标题').color, Colors.green);
        expect(rendered('定制标题').fontSize, 20);
        await tester.tap(find.text('可用标题'));
        await tester.tap(find.text('禁用标题'));
        expect(activations, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'nested dark input uses its local palette and keeps separate label and hint',
    (tester) async {
      await tester.pumpWidget(
        host(
          MiuixFrameworkBridge(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const ui.TextField(key: ValueKey('light-editor')),
                miuix.MiuixTheme(
                  data: miuixThemeData(Brightness.dark),
                  child: const ui.TextField(
                    key: ValueKey('dark-editor'),
                    decoration: InputDecoration(
                      labelText: '服务器地址',
                      hintText: 'https://example.test',
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dark = find.descendant(
        of: find.byKey(const ValueKey('dark-editor')),
        matching: find.byType(EditableText),
      );
      final light = find.descendant(
        of: find.byKey(const ValueKey('light-editor')),
        matching: find.byType(EditableText),
      );
      expect(sdk.Theme.of(tester.element(dark)).brightness, Brightness.dark);
      expect(sdk.Theme.of(tester.element(light)).brightness, Brightness.light);
      expect(find.text('服务器地址'), findsOneWidget);
      expect(find.text('https://example.test'), findsOneWidget);
      await tester.enterText(dark, 'https://local.test');
      await tester.pumpAndSettle();
      expect(find.text('服务器地址'), findsOneWidget);
      expect(
        tester.widget<EditableText>(dark).controller.text,
        'https://local.test',
      );
    },
  );

  testWidgets(
    'button retains selected border, disabled icon color and compact icon geometry',
    (tester) async {
      await tester.pumpWidget(
        host(
          Center(
            child: ui.OutlinedButton.icon(
              onPressed: null,
              icon: const Icon(Icons.check),
              label: const Text('已选'),
              style: ui.OutlinedButton.styleFrom(
                disabledForegroundColor: Colors.grey,
                minimumSize: const Size(80, 32),
                padding: EdgeInsets.zero,
                side: const BorderSide(color: Colors.blue, width: 2),
                shape: const RoundedRectangleBorder(
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
            ),
          ),
        ),
      );
      final paintedBorders = tester
          .widgetList<DecoratedBox>(find.byType(DecoratedBox))
          .where(
            (w) =>
                w.position == DecorationPosition.foreground &&
                w.decoration is ShapeDecoration &&
                (w.decoration as ShapeDecoration).shape
                    is miuix.MiuixSquircleBorder,
          );
      expect(paintedBorders, hasLength(1));
      final border =
          (paintedBorders.single.decoration as ShapeDecoration).shape
              as miuix.MiuixSquircleBorder;
      expect(border.side.color, Colors.blue);
      expect(border.side.width, 2);
      expect(border.cornerRadius, 12);
      expect(
        IconTheme.of(tester.element(find.byIcon(Icons.check))).color,
        Colors.grey,
      );
      await tester.pumpWidget(
        host(
          Center(
            child: ui.IconButton(
              onPressed: () {},
              icon: const Icon(Icons.add),
              iconSize: 16,
              style: ui.IconButton.styleFrom(
                minimumSize: const Size(28, 28),
                padding: EdgeInsets.zero,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byType(miuix.MiuixIconButton)),
        const Size(28, 28),
      );
    },
  );

  testWidgets(
    'clickable row keeps independent trailing actions in keyboard traversal',
    (tester) async {
      final row = FocusNode(debugLabel: 'row');
      final edit = FocusNode(debugLabel: 'edit');
      final remove = FocusNode(debugLabel: 'remove');
      addTearDown(() {
        row.dispose();
        edit.dispose();
        remove.dispose();
      });
      final calls = <String>[];
      await tester.pumpWidget(
        host(
          ui.ListTile(
            focusNode: row,
            title: const Text('模板'),
            onTap: () => calls.add('row'),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ui.IconButton(
                  focusNode: edit,
                  icon: const Icon(Icons.edit),
                  onPressed: () => calls.add('edit'),
                ),
                ui.IconButton(
                  focusNode: remove,
                  icon: const Icon(Icons.delete),
                  onPressed: () => calls.add('remove'),
                ),
              ],
            ),
          ),
        ),
      );
      row.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(edit.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      expect(remove.hasPrimaryFocus, isTrue);
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(calls, ['row', 'edit', 'remove']);
    },
  );

  for (final cancelSecondary in [false, true]) {
    testWidgets(
      'secondary pointer ${cancelSecondary ? 'cancel' : 'up'} cannot finish an active slider drag',
      (tester) async {
        var value = .2;
        var cancels = 0;
        final ends = <double>[];
        await tester.pumpWidget(
          host(
            StatefulBuilder(
              builder: (context, setState) => ui.Slider(
                value: value,
                onChanged: (v) => setState(() => value = v),
                onChangeEnd: ends.add,
                onChangeCancel: () => cancels++,
              ),
            ),
          ),
        );
        final rect = tester.getRect(find.byType(miuix.MiuixSlider));
        final primary = await tester.startGesture(
          Offset(rect.left + 60, rect.center.dy),
          pointer: 11,
        );
        await primary.moveBy(const Offset(50, 0));
        await tester.pump();
        final secondary = await tester.startGesture(rect.center, pointer: 12);
        if (cancelSecondary) {
          await secondary.cancel();
        } else {
          await secondary.up();
        }
        await tester.pump();
        expect(
          ends,
          isEmpty,
          reason: 'Only the initiating pointer can commit a seek',
        );
        expect(cancels, 0);
        await primary.moveBy(const Offset(70, 0));
        await tester.pump();
        final finalValue = value;
        await primary.up();
        await tester.pumpAndSettle();
        expect(ends, [finalValue]);
        expect(cancels, 0);
      },
    );
  }

  testWidgets('Miuix input edits Chinese text and submits through SDK bridge', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    String? changed;
    String? submitted;
    await tester.pumpWidget(
      host(
        ui.TextField(
          controller: controller,
          decoration: const InputDecoration(hintText: '搜索片名'),
          textInputAction: TextInputAction.search,
          onChanged: (v) => changed = v,
          onSubmitted: (v) => submitted = v,
        ),
        brightness: Brightness.dark,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(miuix.MiuixTextField), findsOneWidget);
    final editor = find.byType(EditableText);
    expect(sdk.Theme.of(tester.element(editor)).brightness, Brightness.dark);
    expect(sdk.MaterialLocalizations.of(tester.element(editor)), isNotNull);
    await tester.enterText(editor, '星夜 02');
    expect(controller.text, '星夜 02');
    expect(changed, '星夜 02');
    await tester.testTextInput.receiveAction(TextInputAction.search);
    expect(submitted, '星夜 02');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Form initializes, validates and resets the actual Miuix editor',
    (tester) async {
      final form = GlobalKey<FormState>();
      await tester.pumpWidget(
        host(
          Form(
            key: form,
            child: ui.TextFormField(
              initialValue: '原值',
              validator: (v) => v!.isEmpty ? '不能为空' : null,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '原值',
      );
      await tester.enterText(find.byType(EditableText), '');
      expect(form.currentState!.validate(), isFalse);
      await tester.pump();
      expect(find.text('不能为空'), findsOneWidget);
      form.currentState!.reset();
      await tester.pump();
      expect(
        tester.widget<EditableText>(find.byType(EditableText)).controller.text,
        '原值',
      );
      expect(find.text('不能为空'), findsNothing);
    },
  );

  testWidgets(
    'Miuix button responds once to pointer and remote Select; disabled stays inert',
    (tester) async {
      var calls = 0;
      final focus = FocusNode();
      addTearDown(focus.dispose);
      await tester.pumpWidget(
        host(
          ui.FilledButton(
            focusNode: focus,
            onPressed: () => calls++,
            child: const Text('启用'),
          ),
        ),
      );
      expect(find.byType(miuix.MiuixButton), findsOneWidget);
      await tester.tap(find.text('启用'));
      expect(calls, 1);
      focus.requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.select);
      expect(calls, 2);
      await tester.pumpWidget(
        host(const ui.FilledButton(onPressed: null, child: Text('禁用'))),
      );
      await tester.tap(find.text('禁用'));
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      expect(calls, 2);
    },
  );

  testWidgets('slider tap, drag and keyboard each commit once', (tester) async {
    var value = .2;
    final ends = <double>[];
    final focus = FocusNode();
    addTearDown(focus.dispose);
    await tester.pumpWidget(
      host(
        StatefulBuilder(
          builder: (context, setState) => ui.Slider(
            value: value,
            divisions: 10,
            focusNode: focus,
            onChanged: (v) => setState(() => value = v),
            onChangeEnd: ends.add,
          ),
        ),
      ),
    );
    expect(find.byType(miuix.MiuixSlider), findsOneWidget);
    final rect = tester.getRect(find.byType(miuix.MiuixSlider));
    await tester.tapAt(Offset(rect.left + rect.width * .7, rect.center.dy));
    await tester.pumpAndSettle();
    expect(ends, hasLength(1));
    expect(ends.last, closeTo(.7, .11));
    final drag = await tester.startGesture(
      Offset(rect.left + rect.width * .3, rect.center.dy),
    );
    await drag.moveBy(const Offset(40, 0));
    await drag.moveBy(const Offset(40, 0));
    await drag.up();
    await tester.pumpAndSettle();
    expect(ends, hasLength(2));
    focus.requestFocus();
    await tester.pump();
    final before = value;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(ends, hasLength(3));
    expect(value, closeTo(before + .1, .001));
  });

  testWidgets(
    'cancelled slider drag does not seek and accepts subsequent external progress',
    (tester) async {
      var value = .2;
      var cancels = 0;
      var commits = 0;
      late StateSetter update;
      await tester.pumpWidget(
        host(
          StatefulBuilder(
            builder: (context, setState) {
              update = setState;
              return ui.Slider(
                value: value,
                onChanged: (v) => setState(() => value = v),
                onChangeEnd: (_) => commits++,
                onChangeCancel: () => cancels++,
              );
            },
          ),
        ),
      );
      final rect = tester.getRect(find.byType(miuix.MiuixSlider));
      final drag = await tester.startGesture(rect.center);
      await drag.moveBy(const Offset(70, 0));
      await drag.cancel();
      await tester.pumpAndSettle();
      expect(commits, 0);
      expect(cancels, 1);
      update(() => value = .1);
      await tester.pumpAndSettle();
      expect(
        tester.widget<miuix.MiuixSlider>(find.byType(miuix.MiuixSlider)).value,
        .1,
      );
      await tester.tapAt(Offset(rect.left + rect.width * .8, rect.center.dy));
      await tester.pumpAndSettle();
      expect(commits, 1);
      expect(value, greaterThan(.7));
    },
  );

  testWidgets('zero-range and disabled sliders cannot commit', (tester) async {
    var commits = 0;
    await tester.pumpWidget(
      host(
        ui.Slider(
          value: 0,
          min: 0,
          max: 0,
          onChanged: (_) => commits++,
          onChangeEnd: (_) => commits++,
        ),
      ),
    );
    await tester.tap(find.byType(miuix.MiuixSlider));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pumpAndSettle();
    expect(commits, 0);
    expect(tester.takeException(), isNull);
  });
}
