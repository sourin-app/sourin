import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide Page;
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

Widget _host(Widget child, {Brightness brightness = Brightness.light}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(data: theme, child: child!),
    home: Scaffold(body: child),
  );
}

ProviderGroup _group() => ProviderGroup(
  provider: 'fixture',
  providerName: '测试源',
  sections: [
    for (final id in ['good', 'bad', 'empty'])
      Section(
        id: id,
        title: '分类 $id',
        source: SectionSource(type: 'category', categoryId: id),
      ),
  ],
);

void main() {
  var enabled = true;
  setUp(() {
    enabled = true;
    UiPrefs.debugResetForTest();
    homeListCache.clear();
    debugShelfLoadOverride = () async =>
        (<Favorite>[], <Favorite>[], <Progress>[]);
    SourinCore.debugCallAsyncTransport = (command, _) async {
      if (command == 'list_providers') {
        return [
          {
            'id': 'fixture',
            'name': '测试源',
            'kind': 'tvbox',
            'enabled': enabled,
            'capabilities': {'vod': true},
          },
        ];
      }
      if (command == 'list_all_progress') return <dynamic>[];
      if (command == 'repair_library_covers') return 0;
      throw StateError(command);
    };
    SourinApi.debugHomeFetcher = () async => [_group()];
  });
  tearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    SourinApi.debugHomeFetcher = null;
    SourinApi.debugSetListFetchers();
    debugShelfLoadOverride = null;
    homeListCache.clear();
    UiPrefs.debugResetForTest();
  });

  testWidgets(
    'failed sections show one retry and keep successful empty distinct',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(1280, 1200);
      addTearDown(tester.view.reset);
      final calls = <String, int>{};
      final retry = Completer<Page<MediaItem>>();
      SourinApi.debugSetListFetchers(
        getList: (_, category, {int page = 1}) async {
          final attempt = calls.update(
            category,
            (value) => value + 1,
            ifAbsent: () => 1,
          );
          if (category == 'bad') {
            if (attempt == 1) {
              throw SourinCoreException(
                'HTTP 444 (https://fixture.invalid/?token=private-fixture)',
                'other',
              );
            }
            return await retry.future;
          }
          return Page(
            items: category == 'empty'
                ? []
                : [const MediaItem(id: 'fixture:good', title: '正常内容')],
          );
        },
      );
      await tester.pumpWidget(_host(const HomePage()));
      await tester.pumpAndSettle();
      expect(find.text('正常内容'), findsOneWidget);
      expect(
        find.text('暂无内容'),
        findsOneWidget,
        reason: 'only a successful empty list is empty',
      );
      expect(find.textContaining('HTTP 444'), findsOneWidget);
      expect(find.textContaining('private-fixture'), findsNothing);
      expect(find.textContaining('fixture.invalid'), findsNothing);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('重试'));
      await tester.pump();
      final retryButton = tester.widget<ui.TextButton>(
        find.ancestor(
          of: find.text('正在重试'),
          matching: find.byType(ui.TextButton),
        ),
      );
      expect(retryButton.onPressed, isNull);
      expect(calls, {'good': 1, 'bad': 2, 'empty': 1});
      retry.complete(
        const Page(
          items: [MediaItem(id: 'fixture:bad', title: '恢复内容')],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('恢复内容'), findsOneWidget);
      expect(find.textContaining('HTTP 444'), findsNothing);
      expect(find.text('重试'), findsNothing);
      expect(find.text('暂无内容'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('refresh failure retains existing cards and reports failure', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 1200);
    addTearDown(tester.view.reset);
    var fail = false;
    SourinApi.debugHomeFetcher = () async => [
      ProviderGroup(
        provider: 'fixture',
        providerName: '测试源',
        sections: [_group().sections.first],
      ),
    ];
    SourinApi.debugSetListFetchers(
      getList: (_, __, {int page = 1}) async {
        if (fail) throw SourinCoreException('HTTP 503', 'other');
        return const Page(
          items: [MediaItem(id: 'fixture:cached', title: '已有内容')],
        );
      },
    );
    final key = GlobalKey<HomePageState>();
    await tester.pumpWidget(_host(HomePage(key: key)));
    await tester.pumpAndSettle();
    fail = true;
    await key.currentState!.loadAll(force: true, reason: 'user-refresh');
    await tester.pumpAndSettle();
    expect(find.text('已有内容'), findsOneWidget);
    expect(find.textContaining('HTTP 503'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);
    expect(find.text('暂无内容'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disabled source ignores a late section failure', (tester) async {
    final pending = Completer<Page<MediaItem>>();
    SourinApi.debugSetListFetchers(
      getList: (_, __, {int page = 1}) async => await pending.future,
    );
    final key = GlobalKey<HomePageState>();
    await tester.pumpWidget(_host(HomePage(key: key)));
    await tester.pump();
    enabled = false;
    await key.currentState!.loadAll(force: true, reason: 'providers-changed');
    pending.completeError(SourinCoreException('HTTP 444', 'other'));
    await tester.pumpAndSettle();
    expect(find.textContaining('HTTP 444'), findsNothing);
    expect(find.text('重试'), findsNothing);
    expect(find.text('测试源'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    testWidgets('failed source summary fits a narrow $brightness page', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(411, 900);
      addTearDown(tester.view.reset);
      SourinApi.debugSetListFetchers(
        getList: (_, __, {int page = 1}) async {
          throw SourinCoreException('HTTP 444', 'other');
        },
      );
      await tester.pumpWidget(_host(const HomePage(), brightness: brightness));
      await tester.pumpAndSettle();
      expect(find.text('3 个分类暂时无法加载'), findsOneWidget);
      expect(find.text('暂无内容'), findsNothing);
      expect(find.text('重试').hitTestable(), findsOneWidget);
      final retryRect = tester.getRect(find.text('重试'));
      expect(retryRect.left, greaterThan(0));
      expect(retryRect.right, lessThan(411));
      expect(tester.takeException(), isNull);
    });
  }
}
