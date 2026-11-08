import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/danmaku.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/danmaku_search_page.dart';
import 'package:sourin_spike/ui/widgets/bili_import_dialog.dart';
import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';

const state = DanmakuSettingsState(
  enabled: true,
  appId: '',
  appSecret: '',
  fontScale: 1,
  opacity: 1,
  speed: 8,
  area: 1,
);
Widget host(Widget child) => MaterialApp(
  builder: (_, child) =>
      AppThemeHost(data: AppTheme.themeFor(Brightness.dark), child: child!),
  theme: AppTheme.themeFor(Brightness.dark),
  home: Scaffold(body: child),
);
Future<void> openSources(WidgetTester t) async {
  await t.pumpWidget(
    host(
      DanmakuSettingsDialog(
        state: state,
        onSetEnabled: (_) {},
        onSetFontScale: (_) {},
        onSetOpacity: (_) {},
        onSetSpeed: (_) {},
        onSetArea: (_) {},
        onReload: () {},
        onClose: () {},
        feedSamples: const {
          DanmakuFeedChannel.biliSource: [
            DanmakuComment(cid: 1, time: 1, text: 'source'),
          ],
          DanmakuFeedChannel.danApi: [
            DanmakuComment(cid: 2, time: 2, text: 'api'),
          ],
        },
      ),
    ),
  );
  await t.pumpAndSettle();
  await t.tap(
    find.descendant(
      of: find.byKey(const ValueKey('danmaku-settings-tabs')),
      matching: find.text('弹幕来源'),
    ),
  );
  await t.pumpAndSettle();
}

Finder sourceRow(DanmakuFeedChannel channel) =>
    find.byKey(ValueKey('danmaku-feed-${channel.name}'));

bool sourceEnabled(DanmakuFeedChannel channel) {
  final row = sourceRow(channel);
  expect(row, findsOneWidget);
  final indicator = find.descendant(
    of: row,
    matching: find.byWidgetPredicate(
      (widget) =>
          widget is Icon &&
          const [
            AppIcons.check_box_rounded,
            AppIcons.check_box_outline_blank_rounded,
          ].contains(widget.icon),
    ),
  );
  expect(
    indicator,
    findsOneWidget,
    reason: 'Each source must render its actual checked or unchecked state.',
  );
  return (indicator.evaluate().single.widget as Icon).icon ==
      AppIcons.check_box_rounded;
}

Future<void> toggleApi(WidgetTester t) async {
  const channel = DanmakuFeedChannel.danApi;
  final wasEnabled = sourceEnabled(channel);
  // The source indicator is an Icon row; its surrounding MiuixPressable owns
  // the gesture. Tapping the decorative Row reports a hit-test miss.
  final control = find
      .ancestor(
        of: sourceRow(channel),
        matching: find.byType(miuix.MiuixPressable),
      )
      .first;
  expect(control, findsOneWidget);
  await t.ensureVisible(control);
  await t.pumpAndSettle();
  // _toggleFeed starts UiPrefs.flush synchronously inside the tap callback.
  // Start and join that file I/O in the same real async zone, before pumping
  // fake time; joining a write already started in FakeAsync can deadlock.
  await t.runAsync(() async {
    await t.tap(control);
    await UiPrefs.flush();
  });
  expect(t.takeException(), isNull);
  await t.pumpAndSettle();
  expect(sourceEnabled(channel), !wasEnabled);
}

Future<void> selectResult(WidgetTester t, Finder tile) async {
  final checkbox = find.descendant(
    of: tile,
    matching: find.byType(miuix.MiuixCheckbox),
  );
  expect(checkbox, findsOneWidget);
  await t.ensureVisible(checkbox);
  await t.pumpAndSettle();
  await t.tap(checkbox);
  await t.pump();
  expect(t.widget<ui.CheckboxListTile>(tile).value, isTrue);
}

void main() {
  setUp(() => UiPrefs.debugResetForTest());
  testWidgets('first use enables every available feed', (t) async {
    await openSources(t);
    expect(
      sourceEnabled(DanmakuFeedChannel.biliSource),
      isTrue,
      reason: '空偏好下四路皆勾：视频自带来源也必须保留默认勾选。',
    );
    expect(sourceEnabled(DanmakuFeedChannel.danApi), isTrue);
    expect(sourceEnabled(DanmakuFeedChannel.biliExternal), isTrue);
    expect(sourceEnabled(DanmakuFeedChannel.localService), isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 400));
  });
  testWidgets('explicit feed disable survives disk reload and remount', (
    t,
  ) async {
    final dir = (await t.runAsync(
      () => Directory.systemTemp.createTemp('danmaku-prefs-'),
    ))!;
    const preferenceKey = 'danmaku.feeds.enabled';
    try {
      await t.runAsync(() => UiPrefs.load(dir.path));
      await openSources(t);
      // Normalize before explicitly disabling, independent of the default test.
      if (!sourceEnabled(DanmakuFeedChannel.danApi)) await toggleApi(t);
      expect(sourceEnabled(DanmakuFeedChannel.danApi), isTrue);
      await toggleApi(t);
      expect(sourceEnabled(DanmakuFeedChannel.danApi), isFalse);
      await t.pumpWidget(const SizedBox());

      final persisted = await t.runAsync(() async {
        final file = File('${dir.path}/ui-prefs.json');
        expect(
          await file.exists(),
          isTrue,
          reason:
              'The explicit selection must use real preference persistence.',
        );
        return jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      });
      expect(persisted, isNotNull);
      expect(
        (persisted![preferenceKey] as String).split(','),
        unorderedEquals([
          DanmakuFeedChannel.biliSource.name,
          DanmakuFeedChannel.biliExternal.name,
          DanmakuFeedChannel.localService.name,
        ]),
        reason: 'The actual disk snapshot must retain every other feed and omit dan-api.',
      );
      UiPrefs.debugResetForTest();
      expect(
        UiPrefs.get(preferenceKey),
        isNull,
        reason:
            'Reload must recover from disk rather than surviving static state.',
      );
      await t.runAsync(() => UiPrefs.load(dir.path));
      expect(UiPrefs.get(preferenceKey), persisted[preferenceKey]);
      await openSources(t);
      expect(sourceEnabled(DanmakuFeedChannel.danApi), isFalse);
      expect(sourceEnabled(DanmakuFeedChannel.biliSource), isTrue);
      expect(sourceEnabled(DanmakuFeedChannel.biliExternal), isTrue);
      expect(sourceEnabled(DanmakuFeedChannel.localService), isTrue);
    } finally {
      await t.pumpWidget(const SizedBox());
      await t.runAsync(() async {
        await UiPrefs.flush();
        UiPrefs.debugResetForTest();
        await dir.delete(recursive: true);
      });
    }
  });
  testWidgets(
    'duplicate episode numbers require explicit selection before confirmation',
    (t) async {
      final batches = <List<DanmakuMatch>>[];
      await t.pumpWidget(
        host(
          DanmakuSearchPage(
            state: const DanmakuSettingsState(
              enabled: true,
              appId: '',
              appSecret: '',
              fontScale: 1,
              opacity: 1,
              speed: 1,
              area: 1,
              searchSearched: true,
              searchResults: [
                DanmakuMatch(
                  episodeId: 11,
                  animeTitle: '作品A',
                  episodeTitle: '第1话',
                ),
                DanmakuMatch(
                  episodeId: 22,
                  animeTitle: '作品B',
                  episodeTitle: '第1话',
                ),
              ],
            ),
            biliState: const BiliImportState(),
            localTitles: const ['第1集'],
            onSearch: (_) {},
            onBiliSearch: (_) {},
            onPickMatch: (_) {},
            onBatchBind: batches.add,
            onBiliImport: (_) {},
            onBiliSelectPage: (_) {},
            onClose: () {},
          ),
        ),
      );
      await t.pumpAndSettle();
      for (var i = 0; i < 2; i++) {
        await selectResult(t, find.byType(ui.CheckboxListTile).at(i));
      }
      await t.ensureVisible(find.text('预览批量绑定'));
      await t.pumpAndSettle();
      await t.tap(find.text('预览批量绑定'));
      await t.pump();
      final confirm = find.widgetWithText(ui.FilledButton, '确认并交由播放器绑定');
      expect(
        t.widget<ui.FilledButton>(confirm).onPressed,
        isNull,
        reason:
            'Two distinct IDs for episode 1 must not silently bind the first.',
      );
      expect(batches, isEmpty);
      final choice = find.textContaining('选择 ').last;
      await t.ensureVisible(choice);
      await t.pumpAndSettle();
      await t.tap(choice);
      await t.pump();
      expect(t.widget<ui.FilledButton>(confirm).onPressed, isNotNull);
      await t.ensureVisible(confirm);
      await t.pumpAndSettle();
      await t.tap(confirm);
      await t.pump();
      expect(batches.single.map((m) => m.episodeId), [22]);
    },
  );
  testWidgets('session draft survives unmount and remount', (t) async {
    final draft = DanmakuSearchDraft();
    Widget page() => host(
      DanmakuSearchPage(
        draft: draft,
        state: const DanmakuSettingsState(
          enabled: true,
          appId: '',
          appSecret: '',
          fontScale: 1,
          opacity: 1,
          speed: 1,
          area: 1,
          searchSearched: true,
          searchResults: [
            DanmakuMatch(episodeId: 11, animeTitle: '作品A', episodeTitle: '第1话'),
          ],
        ),
        biliState: const BiliImportState(),
        localTitles: const ['第1集'],
        onSearch: (_) {},
        onBiliSearch: (_) {},
        onPickMatch: (_) {},
        onBatchBind: (_) {},
        onBiliImport: (_) {},
        onBiliSelectPage: (_) {},
        onClose: () {},
      ),
    );
    await t.pumpWidget(page());
    await t.pumpAndSettle();
    final keyword = find.descendant(
      of: find.byType(DanmakuSearchPage),
      matching: find.byType(ui.TextField),
    );
    expect(keyword, findsOneWidget);
    await t.enterText(keyword, '保留关键词');
    await selectResult(t, find.byType(ui.CheckboxListTile));
    await t.ensureVisible(find.text('预览批量绑定'));
    await t.pumpAndSettle();
    await t.tap(find.text('预览批量绑定'));
    await t.pump();
    expect(draft.keyword, '保留关键词');
    expect(draft.selectedEpisodeIds, {11});
    expect(draft.previewing, isTrue);
    await t.pumpWidget(const SizedBox());
    await t.pumpWidget(page());
    // Miuix registers dialog content after the mount frame on each new route.
    await t.pumpAndSettle();
    expect(keyword, findsOneWidget);
    expect(t.widget<ui.TextField>(keyword).controller!.text, '保留关键词');
    expect(
      t.widget<ui.CheckboxListTile>(find.byType(ui.CheckboxListTile)).value,
      isTrue,
    );
    expect(find.text('确认并交由播放器绑定'), findsOneWidget);
  });

  testWidgets('诊断区可展开收起且凭证补救动作真实可达', (t) async {
    var reloads = 0;
    var locals = 0;
    await t.pumpWidget(
      host(
        DanmakuSearchPage(
          state: DanmakuSettingsState(
            enabled: true,
            appId: '',
            appSecret: '',
            fontScale: 1,
            opacity: 1,
            speed: 1,
            area: 1,
            status: '请求失败',
            error: DanmakuException(
              '凭证校验失败',
              statusCode: 401,
              body: 'server-auth-detail',
            ),
          ),
          biliState: const BiliImportState(),
          localTitles: const [],
          onSearch: (_) {},
          onBiliSearch: (_) {},
          onPickMatch: (_) {},
          onBatchBind: (_) {},
          onBiliImport: (_) {},
          onBiliSelectPage: (_) {},
          onClose: () {},
          onReload: () => reloads++,
          onOpenLocal: () => locals++,
        ),
      ),
    );
    await t.pumpAndSettle();
    final diagnostics = find.text('请求与服务端详情');
    expect(diagnostics, findsOneWidget);
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
    final local = find.widgetWithText(ui.TextButton, '改用本机外部弹幕');
    await t.ensureVisible(local);
    await t.pumpAndSettle();
    await t.tap(local);
    expect(locals, 1);
    final reload = find.widgetWithText(ui.TextButton, '重新获取弹幕');
    await t.ensureVisible(reload);
    await t.pumpAndSettle();
    await t.tap(reload);
    expect(reloads, 1);
    await t.ensureVisible(diagnostics);
    await t.pumpAndSettle();
    await t.tap(diagnostics);
    await t.pumpAndSettle();
    expect(find.text('服务端返回详情'), findsNothing);
  });
}
