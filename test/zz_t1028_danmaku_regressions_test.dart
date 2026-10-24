import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

const state = DanmakuSettingsState(enabled: true, appId: '', appSecret: '',
  fontScale: 1, opacity: 1, speed: 8, area: 1);
Widget host(Widget child) => MaterialApp(theme: AppTheme.themeFor(Brightness.dark),
  home: Scaffold(body: child));
Future<void> openSources(WidgetTester t) async {
  await t.pumpWidget(host(DanmakuSettingsDialog(state: state,
    onSetEnabled: (_) {}, onSetFontScale: (_) {}, onSetOpacity: (_) {},
    onSetSpeed: (_) {}, onSetArea: (_) {}, onReload: () {}, onClose: () {},
    feedSamples: const {
      DanmakuFeedChannel.biliSource: [DanmakuComment(cid: 1, time: 1, text: 'source')],
      DanmakuFeedChannel.danApi: [DanmakuComment(cid: 2, time: 2, text: 'api')],
    })));
  await t.pumpAndSettle();
  await t.tap(find.descendant(of: find.byType(SegmentedButton<DanmakuPanelTab>),
    matching: find.text('高级')));
  await t.pumpAndSettle();
}
Finder sourceRow(String label) => find.ancestor(
  of: find.text(label), matching: find.byType(Row)).first;
bool sourceEnabled(String label) => find.descendant(
  of: sourceRow(label), matching: find.byIcon(AppIcons.check_box_rounded)).evaluate().isNotEmpty;
Future<void> toggleApi(WidgetTester t) async {
  final row = sourceRow('dan-api');
  await t.ensureVisible(row);
  await t.tap(row);
  await t.pumpAndSettle();
}
void main() {
  setUp(() => UiPrefs.debugResetForTest());
  testWidgets('first use enables every available feed', (t) async {
    await openSources(t);
    expect(sourceEnabled('本片源自带'), isTrue,
      reason: '空偏好下四路皆勾：视频自带来源也必须保留默认勾选。');
    expect(sourceEnabled('dan-api'), isTrue);
    expect(sourceEnabled('某个视频站'), isTrue);
    expect(sourceEnabled('本机服务'), isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 400));
  });
  testWidgets('explicit feed disable survives disk reload and remount', (t) async {
    final dir = await t.runAsync(() => Directory.systemTemp.createTemp('danmaku-prefs-'));
    addTearDown(() async { UiPrefs.debugResetForTest(); await dir!.delete(recursive: true); });
    await t.runAsync(() => UiPrefs.load(dir!.path));
    await openSources(t);
    // Normalize to enabled before explicitly disabling, independent of the old default.
    if (!sourceEnabled('dan-api')) await toggleApi(t);
    expect(sourceEnabled('dan-api'), isTrue);
    await toggleApi(t);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 400));
    await t.runAsync(() => UiPrefs.flush());
    expect(await t.runAsync(() => File('${dir!.path}/ui-prefs.json').exists()), isTrue,
      reason: 'The explicit selection must use the real preference persistence path.');
    UiPrefs.debugResetForTest();
    await t.runAsync(() => UiPrefs.load(dir!.path));
    await openSources(t);
    expect(sourceEnabled('dan-api'), isFalse);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 400));
  });
  testWidgets('duplicate episode numbers require explicit selection before confirmation', (t) async {
    final batches = <List<DanmakuMatch>>[];
    await t.pumpWidget(host(DanmakuSearchPage(
      state: const DanmakuSettingsState(enabled: true, appId: '', appSecret: '',
        fontScale: 1, opacity: 1, speed: 1, area: 1, searchSearched: true,
        searchResults: [
          DanmakuMatch(episodeId: 11, animeTitle: '作品A', episodeTitle: '第1话'),
          DanmakuMatch(episodeId: 22, animeTitle: '作品B', episodeTitle: '第1话'),
        ]),
      biliState: const BiliImportState(), localTitles: const ['第1集'],
      onSearch: (_) {}, onBiliSearch: (_) {}, onPickMatch: (_) {},
      onBatchBind: batches.add, onBiliImport: (_) {}, onBiliSelectPage: (_) {}, onClose: () {},
    )));
    for (var i = 0; i < 2; i++) {
      await t.tap(find.byType(CheckboxListTile).at(i));
      await t.pump();
    }
    await t.ensureVisible(find.text('预览批量绑定'));
    await t.tap(find.text('预览批量绑定'));
    await t.pump();
    final confirm = find.widgetWithText(FilledButton, '确认并交由播放器绑定');
    expect(t.widget<FilledButton>(confirm).onPressed, isNull,
      reason: 'Two distinct IDs for episode 1 must not silently bind the first.');
    expect(batches, isEmpty);
    final choice = find.textContaining('选择 ').last;
    await t.ensureVisible(choice);
    await t.tap(choice);
    await t.pump();
    expect(t.widget<FilledButton>(confirm).onPressed, isNotNull);
    await t.ensureVisible(confirm);
    await t.tap(confirm);
    await t.pump();
    expect(batches.single.map((m) => m.episodeId), [22]);
  });
  testWidgets('session draft survives unmount and remount', (t) async {
    final draft = DanmakuSearchDraft();
    Widget page() => host(DanmakuSearchPage(
      draft: draft,
      state: const DanmakuSettingsState(enabled: true, appId: '', appSecret: '',
        fontScale: 1, opacity: 1, speed: 1, area: 1, searchSearched: true,
        searchResults: [DanmakuMatch(episodeId: 11, animeTitle: '作品A', episodeTitle: '第1话')]),
      biliState: const BiliImportState(), localTitles: const ['第1集'],
      onSearch: (_) {}, onBiliSearch: (_) {}, onPickMatch: (_) {},
      onBatchBind: (_) {}, onBiliImport: (_) {}, onBiliSelectPage: (_) {}, onClose: () {},
    ));
    await t.pumpWidget(page());
    await t.enterText(find.byType(TextField), '保留关键词');
    await t.tap(find.byType(CheckboxListTile));
    await t.pump();
    await t.ensureVisible(find.text('预览批量绑定'));
    await t.tap(find.text('预览批量绑定'));
    await t.pump();
    expect(draft.keyword, '保留关键词');
    expect(draft.selectedEpisodeIds, {11});
    expect(draft.previewing, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(page());
    expect(t.widget<TextField>(find.byType(TextField)).controller!.text, '保留关键词');
    expect(t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value, isTrue);
    expect(find.text('确认并交由播放器绑定'), findsOneWidget);
  });

  testWidgets('诊断区可展开收起且凭证补救动作真实可达', (t) async {
    var reloads = 0;
    var locals = 0;
    await t.pumpWidget(host(DanmakuSearchPage(
      state: DanmakuSettingsState(enabled: true, appId: '', appSecret: '',
        fontScale: 1, opacity: 1, speed: 1, area: 1,
        status: '请求失败', error: DanmakuException('凭证校验失败',
          statusCode: 401, body: 'server-auth-detail')),
      biliState: const BiliImportState(), localTitles: const [],
      onSearch: (_) {}, onBiliSearch: (_) {}, onPickMatch: (_) {},
      onBatchBind: (_) {}, onBiliImport: (_) {}, onBiliSelectPage: (_) {},
      onClose: () {}, onReload: () => reloads++, onOpenLocal: () => locals++,
    )));
    final diagnostics = find.text('请求与服务端详情');
    await t.ensureVisible(diagnostics);
    expect(find.text('服务端返回详情'), findsNothing);
    await t.tap(diagnostics);
    await t.pumpAndSettle();
    expect(find.text('请求状态：请求失败'), findsOneWidget);
    expect(find.text('服务端返回详情'), findsOneWidget);
    expect(find.text('server-auth-detail'), findsOneWidget);
    final remedy = find.textContaining('这是凭证问题');
    expect(remedy, findsOneWidget);
    final text = t.widget<Text>(remedy).data!;
    expect(text, contains('改用本机外部弹幕'));
    expect(text, contains('重新获取弹幕'));
    expect(RegExp(r'填.{0,6}AppId').hasMatch(text), isFalse);
    final local = find.widgetWithText(TextButton, '改用本机外部弹幕');
    await t.ensureVisible(local);
    await t.tap(local);
    expect(locals, 1);
    final reload = find.widgetWithText(TextButton, '重新获取弹幕');
    await t.ensureVisible(reload);
    await t.tap(reload);
    expect(reloads, 1);
    await t.ensureVisible(diagnostics);
    await t.tap(diagnostics);
    await t.pumpAndSettle();
    expect(find.text('服务端返回详情'), findsNothing);
  });
}
