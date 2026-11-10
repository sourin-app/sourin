import 'package:flutter/rendering.dart' show RenderParagraph;
import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(
    Brightness.light,
  ).copyWith(platform: TargetPlatform.windows);
  return MaterialApp(
    theme: theme,
    themeAnimationDuration: Duration.zero,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: Center(child: child)),
  );
}

// A stretched RenderParagraph can occupy the button's entire height while
// painting its text at the top. Measure the laid-out text, not its render box.
Rect _textBounds(WidgetTester tester, String text) {
  final paragraph = tester.renderObject<RenderParagraph>(find.text(text));
  final boxes = paragraph.getBoxesForSelection(
    TextSelection(baseOffset: 0, extentOffset: text.length),
  );
  expect(boxes, isNotEmpty);
  final local = boxes
      .map((box) => box.toRect())
      .reduce((first, next) => first.expandToInclude(next));
  return Rect.fromPoints(
    paragraph.localToGlobal(local.topLeft),
    paragraph.localToGlobal(local.bottomRight),
  );
}

void _expectCentered(Rect content, Rect button) {
  expect(content.center.dx, closeTo(button.center.dx, 0.5));
  expect(content.center.dy, closeTo(button.center.dy, 0.5));
}

Widget _checkUpdateButton({
  required VoidCallback? onPressed,
  FocusNode? focusNode,
}) => ui.FilledButton(
  onPressed: onPressed,
  focusNode: focusNode,
  // The production About page's "检查更新" configuration.
  style: ui.FilledButton.styleFrom(
    minimumSize: const Size(0, 40),
    padding: const EdgeInsets.symmetric(horizontal: Sp.x5),
  ),
  child: const Text('检查更新', style: TextStyle(fontSize: FontSizes.sm)),
);

void main() {
  testWidgets('About check-update text is centered inside its 40px button', (
    tester,
  ) async {
    await tester.pumpWidget(_host(_checkUpdateButton(onPressed: () {})));
    await tester.pumpAndSettle();

    final button = tester.getRect(find.byType(miuix.MiuixButton));
    final text = _textBounds(tester, '检查更新');
    expect(button.height, 40);
    expect(button.width, closeTo(text.width + Sp.x5 * 2, 0.5));
    _expectCentered(text, button);
    expect(tester.takeException(), isNull);
  });

  for (final kind in ['filled', 'outlined', 'text']) {
    testWidgets('$kind icon and label stay centered with min and fixed sizes', (
      tester,
    ) async {
      final style = ui.FilledButton.styleFrom(
        minimumSize: const Size(180, 48),
        fixedSize: const Size(200, 52),
        maximumSize: const Size(220, 56),
        padding: const EdgeInsets.symmetric(horizontal: Sp.x5),
      );
      const icon = Icon(Icons.download, size: 18);
      const label = Text('下载本集', style: TextStyle(fontSize: FontSizes.sm));
      final button = switch (kind) {
        'filled' => ui.FilledButton.icon(
          onPressed: () {},
          icon: icon,
          label: label,
          style: style,
        ),
        'outlined' => ui.OutlinedButton.icon(
          onPressed: () {},
          icon: icon,
          label: label,
          style: style,
        ),
        _ => ui.TextButton.icon(
          onPressed: () {},
          icon: icon,
          label: label,
          style: style,
        ),
      };
      await tester.pumpWidget(_host(button));
      await tester.pumpAndSettle();

      final buttonBounds = tester.getRect(find.byType(miuix.MiuixButton));
      final iconBounds = tester.getRect(find.byIcon(Icons.download));
      final textBounds = _textBounds(tester, '下载本集');
      expect(buttonBounds.size, const Size(200, 52));
      expect(iconBounds.size, const Size(18, 18));
      expect(textBounds.left - iconBounds.right, closeTo(Sp.x2, 0.5));
      _expectCentered(iconBounds.expandToInclude(textBounds), buttonBounds);
      expect(iconBounds.center.dy, closeTo(textBounds.center.dy, 0.5));
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('maximum width and a narrower parent still constrain long text', (
    tester,
  ) async {
    const label = '检查更新并查看当前版本的完整信息';
    for (final width in [160.0, 120.0]) {
      await tester.pumpWidget(
        _host(
          SizedBox(
            width: width,
            child: ui.TextButton(
              onPressed: () {},
              style: ui.TextButton.styleFrom(
                minimumSize: const Size(0, 40),
                maximumSize: const Size(160, 44),
                padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
              ),
              child: const Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: FontSizes.sm),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final button = tester.getRect(find.byType(miuix.MiuixButton));
      final paragraph = tester.renderObject<RenderParagraph>(find.text(label));
      expect(button.size, Size(width, 40));
      expect(paragraph.size.width, lessThanOrEqualTo(width - Sp.x3 * 2));
      expect(paragraph.didExceedMaxLines, isTrue);
      expect(_textBounds(tester, label).center.dy, closeTo(button.center.dy, 0.5));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('disabled and keyboard-focused buttons preserve their geometry', (
    tester,
  ) async {
    final focus = FocusNode();
    addTearDown(focus.dispose);
    var calls = 0;
    await tester.pumpWidget(
      _host(_checkUpdateButton(onPressed: null, focusNode: focus)),
    );
    await tester.pumpAndSettle();

    final disabled = tester.getRect(find.byType(miuix.MiuixButton));
    _expectCentered(_textBounds(tester, '检查更新'), disabled);
    expect(focus.canRequestFocus, isFalse);
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(calls, 0);

    await tester.pumpWidget(
      _host(_checkUpdateButton(onPressed: () => calls++, focusNode: focus)),
    );
    focus.requestFocus();
    await tester.pumpAndSettle();
    expect(focus.hasFocus, isTrue);
    final focused = tester.getRect(find.byType(miuix.MiuixButton));
    expect(focused, disabled);
    _expectCentered(_textBounds(tester, '检查更新'), focused);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.tap(find.text('检查更新'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(tester.getRect(find.byType(miuix.MiuixButton)), focused);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
