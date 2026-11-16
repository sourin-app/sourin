import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/widgets/detail_raw_meta.dart';

// Real DetailPage parent updates and original source/episode transport. There
// is no injected State, native player, external network or playback operation.
const _provider = 'owned-detail-source-sync';
const _sources = <Map<String, dynamic>>[
  {'code': 'line-a', 'title': 'line-a', 'count': 2},
  {'code': 'line-b', 'title': 'line-b', 'count': 2},
  {'code': 'line-c', 'title': 'line-c', 'count': 1},
];

List<Map<String, dynamic>> _episodes(String work) => [
  {'id': '$work:line-a:1', 'title': '$work line-a 正片', 'flag': 'line-a'},
  {'id': '$work:line-a:2', 'title': '$work line-a 国语', 'flag': 'line-a'},
  {'id': '$work:line-b:1', 'title': '$work line-b 英语', 'flag': 'line-b'},
  {'id': '$work:line-b:2', 'title': '$work line-b 中字', 'flag': 'line-b'},
  {'id': '$work:line-c:1', 'title': '$work line-c 1080P', 'flag': 'line-c'},
];

Future<void> _advance(WidgetTester tester) async {
  for (var index = 0; index < 15; index++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

void main() {
  final previousTransport = SourinCore.debugCallAsyncTransport;
  final calls = <String>[];
  final played = <Object>[];
  final pickedLines = <String>[];
  final held = <String, Completer<Object?>>{};
  final consumed = <String>{};
  var noSources = false;
  var nestedSources = false;
  var expectedPreference = '';

  setUp(() {
    calls.clear();
    played.clear();
    pickedLines.clear();
    held.clear();
    consumed.clear();
    noSources = false;
    nestedSources = false;
    expectedPreference = '';
    UiPrefs.debugResetForTest({});
    SourinCore.debugCallAsyncTransport = (command, args) async {
      final work = (args?['id'] ?? 'work').toString();
      switch (command) {
        case 'get_detail':
          return {
            'id': '$_provider:$work',
            'title': 'Owned $work',
            'description': 'Owned source selection fixture.',
            'episodes': noSources
                ? [
                    {'id': '$work:single:1', 'title': '$work 单线路一'},
                    {'id': '$work:single:2', 'title': '$work 单线路二'},
                  ]
                : _episodes(work),
            'sources': noSources
                ? <Object>[]
                : nestedSources
                ? [
                    {'code': 'group', 'title': 'Group', 'nested': _sources},
                  ]
                : _sources,
          };
        case 'get_episodes':
          final source =
              (args?['sourceCode'] ?? args?['source_code'] ?? '').toString();
          final key = '$work:$source';
          calls.add(key);
          if (held.containsKey(key)) {
            consumed.add(key);
            return await held[key]!.future;
          }
          return _episodes(work)
              .where((episode) => episode['flag'] == source)
              .toList();
        case 'get_progress':
          return null;
        case 'list_favorites':
        case 'list_providers':
          return <Object>[];
        default:
          throw SourinCoreException('Unexpected fixture command: $command', 'other');
      }
    };
  });

  tearDown(() {
    for (final entry in held.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(<Object>[]);
      }
    }
    SourinCore.debugCallAsyncTransport = previousTransport;
    UiPrefs.debugResetForTest();
  });

  Future<void> mount(
    WidgetTester tester,
    String? episode, {
    String work = 'work',
  }) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(860, 904);
    final theme = AppTheme.themeFor(Brightness.light);
    await tester.pumpWidget(
      MaterialApp(
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: Scaffold(
          body: DetailPage(
            // Matches MediaPage's actual per-provider/per-work remount key.
            key: ValueKey('detail:$_provider:$work'),
            provider: _provider,
            id: work,
            embedded: true,
            compactHeader: true,
            currentEpisodeId: episode,
            onPlay: played.add,
            onPickLine: pickedLines.add,
          ),
        ),
      ),
    );
    await _advance(tester);
  }

  void expectSilent() {
    expect(played, isEmpty);
    expect(pickedLines, isEmpty);
    expect(UiPrefs.sourcePref(_provider, 'work'), expectedPreference);
  }

  bool episodeActive(WidgetTester tester, String title) {
    final button = find.ancestor(
      of: find.text(title),
      matching: find.byWidgetPredicate(
        (widget) => widget.runtimeType.toString() == '_EpisodeButton',
      ),
    );
    expect(button, findsOneWidget);
    // Read the actual rendered button's active flag, without a State adapter.
    // ignore: avoid_dynamic_calls
    return (tester.widget(button) as dynamic).active as bool;
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await _advance(tester);
    tester.view.reset();
  }

  testWidgets('initial player episode chooses its declared source before preferences', (tester) async {
    expectedPreference = 'line-a';
    UiPrefs.debugResetForTest({'dsh.srcpref.$_provider:work': 'line-a'});
    try {
      await mount(tester, 'work:line-b:2');
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-b');
      expect(find.text('work line-b 中字').hitTestable(), findsOneWidget);
      expect(episodeActive(tester, 'work line-b 中字'), isTrue);
      expect(episodeActive(tester, 'work line-b 英语'), isFalse);
      expect(find.text('work line-a 正片'), findsNothing);
      expect(calls, ['work:line-b']);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('line-a to line-b to line-c follows source and current episode without restarting play', (tester) async {
    try {
      await mount(tester, 'work:line-a:1');
      final titleBefore = tester.getTopLeft(find.text('Owned work'));
      await mount(tester, 'work:line-b:2');
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-b');
      expect(find.text('work line-b 中字').hitTestable(), findsOneWidget);
      await mount(tester, 'work:line-c:1');
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-c');
      expect(find.text('work line-c 1080P').hitTestable(), findsOneWidget);
      expect(episodeActive(tester, 'work line-c 1080P'), isTrue);
      expect(find.text('work line-b 中字'), findsNothing);
      expect(calls, ['work:line-a', 'work:line-b', 'work:line-c']);
      expect(tester.getTopLeft(find.text('Owned work')), titleBefore);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('late line-b response cannot replace the newer line-c source or episode', (tester) async {
    final delayed = Completer<Object?>();
    try {
      await mount(tester, 'work:line-a:1');
      held['work:line-b'] = delayed;
      await mount(tester, 'work:line-b:2');
      expect(consumed, contains('work:line-b'));
      await mount(tester, 'work:line-c:1');
      expect(find.text('work line-c 1080P').hitTestable(), findsOneWidget);
      expect(episodeActive(tester, 'work line-c 1080P'), isTrue);
      delayed.complete(_episodes('work').where((ep) => ep['flag'] == 'line-b').toList());
      await _advance(tester);
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-c');
      expect(find.text('work line-c 1080P').hitTestable(), findsOneWidget);
      expect(find.text('work line-b 中字'), findsNothing);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      if (!delayed.isCompleted) delayed.complete(<Object>[]);
      await finish(tester);
    }
  });

  testWidgets('unknown reported episode preserves the selected source without guessing a request', (tester) async {
    try {
      await mount(tester, 'work:line-a:1');
      await mount(tester, 'not-in-this-work');
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-a');
      expect(calls, ['work:line-a']);
      expect(find.text('work line-a 正片'), findsOneWidget);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('late line-b failure cannot finish a newer line-c episode load', (tester) async {
    final oldRequest = Completer<Object?>();
    final newRequest = Completer<Object?>();
    try {
      await mount(tester, 'work:line-a:1');
      held['work:line-b'] = oldRequest;
      held['work:line-c'] = newRequest;
      await mount(tester, 'work:line-b:2');
      expect(consumed, contains('work:line-b'));
      await mount(tester, 'work:line-c:1');
      expect(consumed, contains('work:line-c'));
      oldRequest.completeError(StateError('Owned old-line rejection'));
      await _advance(tester);
      // While the authoritative line-c request is pending, the old list must not
      // reappear because the obsolete line-b request cleared its loading flag.
      expect(find.text('work line-a 正片'), findsNothing);
      expect(find.text('work line-b 中字'), findsNothing);
      expect(tester.takeException(), isNull);
      newRequest.complete(_episodes('work').where((ep) => ep['flag'] == 'line-c').toList());
      await _advance(tester);
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-c');
      expect(find.text('work line-c 1080P').hitTestable(), findsOneWidget);
      expect(episodeActive(tester, 'work line-c 1080P'), isTrue);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      if (!oldRequest.isCompleted) oldRequest.complete(<Object>[]);
      if (!newRequest.isCompleted) newRequest.complete(<Object>[]);
      await finish(tester);
    }
  });

  testWidgets('empty source tree keeps authoritative unflagged detail episodes', (tester) async {
    noSources = true;
    try {
      await mount(tester, 'work:single:1');
      await mount(tester, 'work:single:2');
      expect(find.byType(DetailSourcePicker), findsNothing);
      expect(find.text('work 单线路一'), findsOneWidget);
      expect(find.text('work 单线路二').hitTestable(), findsOneWidget);
      expect(episodeActive(tester, 'work 单线路二'), isTrue);
      expect(calls, isEmpty);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });

  testWidgets('failed current source request keeps its known catalogue episodes', (tester) async {
    final delayed = Completer<Object?>();
    try {
      await mount(tester, 'work:line-a:1');
      held['work:line-b'] = delayed;
      await mount(tester, 'work:line-b:2');
      expect(consumed, contains('work:line-b'));
      delayed.completeError(StateError('Owned current-line rejection'));
      await _advance(tester);
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-b');
      expect(find.text('work line-a 正片'), findsNothing);
      expect(find.text('work line-b 中字').hitTestable(), findsOneWidget);
      expect(episodeActive(tester, 'work line-b 中字'), isTrue);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      if (!delayed.isCompleted) delayed.complete(<Object>[]);
      await finish(tester);
    }
  });

  testWidgets('per-work remount rejects a previous work pending episode result', (tester) async {
    final delayed = Completer<Object?>();
    held['first:line-a'] = delayed;
    try {
      await mount(tester, 'first:line-a:1', work: 'first');
      expect(consumed, contains('first:line-a'));
      await mount(tester, 'second:line-a:2', work: 'second');
      delayed.complete(_episodes('first').where((ep) => ep['flag'] == 'line-a').toList());
      await _advance(tester);
      expect(find.text('Owned second'), findsOneWidget);
      expect(find.text('second line-a 国语').hitTestable(), findsOneWidget);
      expect(find.text('first line-a 正片'), findsNothing);
      expect(calls, ['first:line-a', 'second:line-a']);
      expect(played, isEmpty);
      expect(pickedLines, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      if (!delayed.isCompleted) delayed.complete(<Object>[]);
      await finish(tester);
    }
  });

  testWidgets('player source lookup follows the declared nested source code', (tester) async {
    nestedSources = true;
    try {
      await mount(tester, 'work:line-b:2');
      expect(tester.widget<DetailSourcePicker>(find.byType(DetailSourcePicker)).active, 'line-b');
      expect(find.text('work line-b 中字').hitTestable(), findsOneWidget);
      expect(calls, ['work:line-b']);
      expectSilent();
      expect(tester.takeException(), isNull);
    } finally {
      await finish(tester);
    }
  });
}
