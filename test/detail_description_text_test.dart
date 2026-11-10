import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';

Future<MediaDetail> _mount(
  WidgetTester tester,
  String description, {
  bool embedded = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 900);
  addTearDown(tester.view.reset);
  UiPrefs.debugResetForTest(<String, String>{});
  final previous = SourinCore.debugCallAsyncTransport;
  final commands = <String>[];
  SourinCore.debugCallAsyncTransport = (command, args) async {
    commands.add(command);
    switch (command) {
      case 'get_detail':
        final request = args!;
        expect(request['provider'], 'description-fixture');
        expect(request['id'], 'work');
        return {
          'id': 'description-fixture:work',
          'title': '简介展示样本',
          'description': description,
          'episodes': <dynamic>[],
          'sources': <dynamic>[],
        };
      case 'get_progress':
        return null;
      case 'list_favorites':
        return <dynamic>[];
      case 'list_providers':
        return [
          {
            'id': 'description-fixture',
            'name': '测试来源',
            'kind': 'tvbox',
            'enabled': true,
          },
        ];
      default:
        throw StateError('Unexpected detail fixture command: $command');
    }
  };
  addTearDown(() {
    SourinCore.debugCallAsyncTransport = previous;
    UiPrefs.debugResetForTest(<String, String>{});
  });
  MediaDetail? loaded;
  final theme = AppTheme.themeFor(Brightness.light);
  await tester.pumpWidget(
    MaterialApp(
      theme: theme,
      builder: (_, child) => AppThemeHost(data: theme, child: child!),
      home: Scaffold(
        body: Align(
          alignment: Alignment.topRight,
          child: SizedBox(
            width: embedded ? 480 : 1100,
            child: DetailPage(
              provider: 'description-fixture',
              id: 'work',
              embedded: embedded,
              onLoaded: (detail) => loaded = detail,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  expect(commands.where((command) => command == 'get_detail'), hasLength(1));
  expect(loaded, isNotNull);
  expect(loaded!.description, description,
      reason: 'Plain-text rendering must not rewrite source metadata.');
  expect(find.text('简介展示样本'), findsOneWidget);
  return loaded!;
}

void main() {
  const cases = <(String, String, String, bool)>[
    (
      'styled HTML in the embedded detail panel',
      '<p><span style="color: rgb(88, 88, 88); font-family: Tahoma, Arial; '
          'font-size: 12px;">匿名角色&nbsp;重返赛场。</span></p>'
          '<p>新的伙伴<br>继续前行。</p>',
      '匿名角色 重返赛场。\n新的伙伴\n继续前行。',
      true,
    ),
    (
      'entities and explicit paragraph or line boundaries',
      '<div>甲&amp;乙&#xFF0C;第一行<br/>第二行&#12290;</div>'
          '<p>第三行&quot;示例&quot;</p>',
      '甲&乙，第一行\n第二行。\n第三行"示例"',
      false,
    ),
    (
      'script style and comment content is omitted',
      '<style>.private-style { color: red; }</style>'
          '<p>可见<script>privateScript("do not display");</script>正文</p>'
          '<!-- private comment --><p>后段</p>',
      '可见正文\n后段',
      true,
    ),
    (
      'quoted tag attributes do not leak into text',
      '<p><span title="1 > 0" style="color: gray">有效文字</span></p>',
      '有效文字',
      true,
    ),
    (
      'plain text comparisons spacing and existing one-pass entities survive',
      '普通说明第一行。\n第二行  2 < 3，5 > 4，A & B，字面量 &amp;nbsp;',
      '普通说明第一行。\n第二行  2 < 3，5 > 4，A & B，字面量 &nbsp;',
      false,
    ),
    (
      'encoded literal tags stay text after one entity decode',
      '&lt;p&gt;示例文本&lt;/p&gt; &amp;nbsp;',
      '<p>示例文本</p> &nbsp;',
      true,
    ),
    (
      'plain comparisons and unknown tag-like text remain literal',
      '比较 x<y && y>z。\n未知 <custom-note data-kind="sample">原样文本</custom-note>。',
      '比较 x<y && y>z。\n未知 <custom-note data-kind="sample">原样文本</custom-note>。',
      true,
    ),
  ];
  for (final (name, source, expected, embedded) in cases) {
    testWidgets('DetailPage description: $name', (tester) async {
      final loaded = await _mount(tester, source, embedded: embedded);
      final description = find.descendant(
        of: find.byType(DetailPage),
        matching: find.text(expected),
      );
      expect(description, findsOneWidget);
      final text = tester.widget<Text>(description);
      expect(text.data, expected);
      expect(text.maxLines, 2);
      expect(text.overflow, TextOverflow.ellipsis);
      expect(loaded.description, source);
      for (final hidden in ['privateScript', 'private-style', 'private comment']) {
        expect(
          find.descendant(
            of: find.byType(DetailPage),
            matching: find.textContaining(hidden),
          ),
          findsNothing,
        );
      }
      if (source != expected) {
        expect(find.text(source), findsNothing);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  }
}
