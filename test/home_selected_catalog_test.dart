import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' hide Page;
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

List<dynamic> _catalog(String id, [String section = 'recent']) => [
  {
    'provider': id,
    'providerName': '源$id',
    'sections': [
      {
        'id': section,
        'title': '分区$id',
        'source': {'type': 'category', 'category_id': section},
      },
    ],
  },
];

Future<void> _pump(WidgetTester tester) async {
  // Bounded pumps also work while a deliberately pending catalog shows a spinner.
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

class _Fixture {
  final key = GlobalKey<HomePageState>();
  final calls = <String>[];
  final pending = <String, List<Completer<List<dynamic>>>>{};
  final enabled = <String, bool>{'a': true, 'b': true};
  final lists = <String>[];
  final pendingLists = <String, List<Completer<Page<MediaItem>>>>{};
  DateTime now = DateTime(2026, 11, 9);

  Completer<List<dynamic>> delay(String id) {
    final result = Completer<List<dynamic>>();
    pending.putIfAbsent(id, () => []).add(result);
    return result;
  }

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    if (command == 'list_providers') {
      return [
        for (final e in enabled.entries)
          {
            'id': e.key,
            'name': '源${e.key}',
            'kind': 'tvbox',
            'enabled': e.value,
            'capabilities': {'vod': true},
          },
      ];
    }
    if (command == 'get_home' || command == 'get_provider_home') {
      final id = command == 'get_home' ? '*' : args!['provider'] as String;
      calls.add(id);
      final queue = pending[id];
      if (queue != null && queue.isNotEmpty) return queue.removeAt(0).future;
      return id == '*' ? [..._catalog('a'), ..._catalog('b')] : _catalog(id);
    }
    if (command == 'list_all_progress') return <dynamic>[];
    if (command == 'repair_library_covers') return 0;
    throw StateError(command);
  }

  Future<void> mount(WidgetTester tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1280, 900);
    addTearDown(tester.view.reset);
    SourinCore.debugCallAsyncTransport = call;
    SourinApi.debugSetListFetchers(
      getList: (provider, section, {int page = 1}) async {
        lists.add('$provider:$section');
        final queue = pendingLists[provider];
        if (queue != null && queue.isNotEmpty) return queue.removeAt(0).future;
        return Page(
          items: [
            MediaItem(id: '$provider:$section', title: '内容$provider-$section'),
          ],
        );
      },
    );
    debugShelfLoadOverride = () async =>
        (<Favorite>[], <Favorite>[], <Progress>[]);
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: Scaffold(
          body: HomePage(key: key, catalogClock: () => now),
        ),
      ),
    );
    await _pump(tester);
  }
}

void main() {
  setUp(() {
    UiPrefs.debugResetForTest();
    homeListCache.clear();
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
    'startup requests only the selected provider; cold switch loads the next',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      expect(f.calls, ['a']);
      expect(find.text('内容a-recent'), findsOneWidget);
      expect(f.lists, ['a:recent']);
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      expect(f.calls, ['a', 'b']);
      expect(find.text('内容b-recent'), findsOneWidget);
      expect(find.text('内容a-recent'), findsNothing);
    },
  );

  testWidgets('rapid A B A switch drops obsolete metadata and errors', (
    tester,
  ) async {
    final f = _Fixture();
    final firstA = f.delay('a');
    final oldB = f.delay('b');
    await f.mount(tester);
    f.key.currentState!.debugSwitchSource('b');
    await _pump(tester);
    f.key.currentState!.debugSwitchSource('a');
    await _pump(tester);
    expect(f.calls, ['a', 'b', 'a']);
    expect(find.text('内容a-recent'), findsOneWidget);
    firstA.complete(_catalog('a', 'obsolete'));
    oldB.completeError(StateError('obsolete failure'));
    await _pump(tester);
    expect(f.lists, ['a:recent']);
    expect(find.text('内容a-recent'), findsOneWidget);
    expect(find.textContaining('obsolete'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'catalog freshness belongs to each provider and cache hits do not extend it',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      f.now = f.now.add(const Duration(seconds: 20));
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      f.now = f.now.add(const Duration(seconds: 5));
      f.key.currentState!.debugSwitchSource('a');
      await _pump(tester);
      expect(f.calls, ['a', 'b']);
      f.now = f.now.add(const Duration(seconds: 6));
      await f.key.currentState!.loadAll(reason: 'tab-switch');
      await _pump(tester);
      expect(f.calls, ['a', 'b', 'a']);
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      expect(f.calls, ['a', 'b', 'a']);
      expect(find.text('内容b-recent'), findsOneWidget);
    },
  );

  testWidgets(
    'configuration change removes a disabled source and invalidates its pending response',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final b = f.delay('b');
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      f.enabled['b'] = false;
      await f.key.currentState!.loadAll(
        force: true,
        reason: 'providers-changed',
      );
      await _pump(tester);
      b.complete(_catalog('b', 'disabled'));
      await _pump(tester);
      expect(f.calls, ['a', 'b', 'a']);
      expect(find.text('内容a-recent'), findsOneWidget);
      expect(f.lists.where((s) => s.startsWith('b:')), isEmpty);
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      expect(f.calls, ['a', 'b', 'a']);
    },
  );
  testWidgets(
    'an older content response cannot replace cards after returning to a source',
    (tester) async {
      final f = _Fixture();
      final firstList = Completer<Page<MediaItem>>();
      f.pendingLists['a'] = [firstList];
      await f.mount(tester);
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      f.key.currentState!.debugSwitchSource('a');
      await _pump(tester);
      expect(find.text('内容a-recent'), findsOneWidget);
      expect(f.lists, ['a:recent', 'b:recent', 'a:recent']);
      firstList.complete(
        const Page(
          items: [MediaItem(id: 'a:obsolete', title: '过期内容')],
        ),
      );
      await _pump(tester);
      expect(find.text('内容a-recent'), findsOneWidget);
      expect(find.text('过期内容'), findsNothing);
    },
  );
  testWidgets(
    'a fresh sparse snapshot retries missing sections and never reports empty while pending',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      final snapshot = HomeSnapshot(
        fingerprint: 'b:recent',
        groups: [
          ProviderGroup.fromJson(_catalog('b').single as Map<String, dynamic>),
        ],
        items: const {},
        at: DateTime.now().subtract(const Duration(seconds: 2)),
      );
      homeListCache.put('b', snapshot);
      final request = Completer<Page<MediaItem>>();
      f.pendingLists['b'] = [request];
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      expect(f.lists, ['a:recent', 'b:recent']);
      expect(find.text('暂无内容'), findsNothing);
      expect(find.text('正在加载'), findsOneWidget);
      request.completeError(SourinCoreException('HTTP 444', 'other'));
      await _pump(tester);
      expect(find.textContaining('HTTP 444'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      expect(find.text('暂无内容'), findsNothing);
      expect(
        homeListCache
            .take('b', fingerprint: 'b:recent', now: DateTime.now())!
            .at,
        snapshot.at,
        reason: 'failure must not renew the content freshness timestamp',
      );
    },
  );

  testWidgets(
    'a cached successful empty section remains distinct from a missing section',
    (tester) async {
      final f = _Fixture();
      await f.mount(tester);
      homeListCache.put(
        'b',
        HomeSnapshot(
          fingerprint: 'b:recent',
          groups: [
            ProviderGroup.fromJson(
              _catalog('b').single as Map<String, dynamic>,
            ),
          ],
          items: const {'b::recent': <MediaItem>[]},
          at: DateTime.now(),
        ),
      );
      f.key.currentState!.debugSwitchSource('b');
      await _pump(tester);
      expect(f.lists, ['a:recent']);
      expect(find.text('暂无内容'), findsOneWidget);
      expect(find.text('正在加载'), findsNothing);
      expect(find.text('重试'), findsNothing);
    },
  );
}
