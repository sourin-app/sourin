// T113c: the batch-bind PERSISTENCE round trip.
//
// Why this file exists (a real defect I introduced and then found):
//
//   The first version of the batch handler wrote the dandanplay episodeIds
//   through saveBinding() -- the EXTERNAL VIDEO SITE store (BiliBinding).
//   That store is consumed by _loadBiliDanmaku(cid), i.e. the other site's
//   comment API.  So the next play would take a dandanplay id and ask the
//   wrong service for comments.
//
//   Both id families happen to be ints.  The compiler cannot tell them apart;
//   only separate storage can.  These gates pin that separation, and pin that
//   the store is actually READ (a write-only store is a fake feature: the user
//   taps "bind whole series", sees a success toast, and the next episode
//   fuzzy-matches by title anyway).

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/batch_bind.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// Strip comments so prose mentioning a form cannot satisfy an assertion.
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

/// Body of a function by brace matching.
///
/// A fixed-width substring runs past the closing brace into the NEXT function
/// and yields a false green -- already made that mistake once this session.
String bodyOf(String code, String signature) {
  final i = code.indexOf(signature);
  if (i < 0) return '';
  var depth = 0;
  var started = false;
  for (var j = i; j < code.length; j++) {
    final c = code[j];
    if (c == '{') {
      depth++;
      started = true;
    } else if (c == '}') {
      depth--;
      if (started && depth == 0) return code.substring(i, j + 1);
    }
  }
  return code.substring(i);
}

void main() {
  group('T113c-1 store model', () {
    test('round trip keeps every episode mapping', () {
      const s = DanmakuBindStore(
        workTitle: '某番',
        episodes: <int, int>{0: 101, 1: 102, 11: 112},
        updatedAt: 123,
      );
      final back = DanmakuBindStore.fromJson(s.toJson());
      expect(back, isNotNull);
      expect(back!.workTitle, '某番');
      expect(back.episodes, <int, int>{0: 101, 1: 102, 11: 112});
      expect(back.updatedAt, 123);
    });

    test('** fromJson rejects non-map / missing-map shapes', () {
      expect(DanmakuBindStore.fromJson(null), isNull);
      expect(DanmakuBindStore.fromJson('not a map'), isNull);
      expect(DanmakuBindStore.fromJson(<String, dynamic>{}), isNull);
      expect(DanmakuBindStore.fromJson(<String, dynamic>{'e': 'nope'}), isNull);
    });

    test('*** loadDanmakuBind survives INVALID JSON (hits the catch, not the type check)', () {
      /*
       * ⚠️ Why this test is separate from the one above.
       *
       * The first version of this gate fed malformed *shapes* to fromJson and
       * claimed to cover "corrupt data".  Fault injection proved that was a
       * FALSE GREEN: replacing the catch body with `rethrow` left the suite
       * green, because fromJson returns null on the type check and never
       * reaches jsonDecode at all.
       *
       * To actually exercise the catch, the raw string in prefs has to be
       * invalid JSON -- that is the only path that throws.
       */
      const p = 'test-provider';
      const id = 't113c-invalid-json';
      UiPrefs.set('$kDanmakuBindPrefix.$p:$id', '{ this is not json');
      expect(loadDanmakuBind(p, id), isNull,
          reason: '*** unparseable prefs must degrade to "never bound", not crash');
      UiPrefs.remove('$kDanmakuBindPrefix.$p:$id');
    });

    test('*** loadDanmakuBind round-trips through real prefs', () {
      const p = 'test-provider';
      const id = 't113c-roundtrip';
      saveDanmakuBind(p, id, const DanmakuBindStore(
        workTitle: '某番',
        episodes: <int, int>{0: 11, 5: 66},
      ));
      final back = loadDanmakuBind(p, id);
      expect(back, isNotNull);
      expect(back!.episodes[5], 66);
      clearDanmakuBind(p, id);
      expect(loadDanmakuBind(p, id), isNull, reason: 'clear must really clear');
    });

    test('** entries with a non-positive id are dropped, not stored', () {
      final s = DanmakuBindStore.fromJson(<String, dynamic>{
        't': 'x',
        'e': <String, dynamic>{'0': 5, '1': 0, '2': -3, '3': 'bad'},
      });
      expect(s, isNotNull);
      expect(s!.episodes, <int, int>{0: 5},
          reason: '** 0 / negative / non-int are not valid episode ids');
    });

    test('** an empty map is reported as empty', () {
      const s = DanmakuBindStore(workTitle: '', episodes: <int, int>{});
      expect(s.isEmpty, isTrue);
    });
  });

  group('T113c-2 storage separation (the defect)', () {
    test('*** the danmaku store uses its OWN key namespace', () {
      expect(kDanmakuBindPrefix, 'dsh.danmaku.bind');
      expect(kDanmakuBindPrefix.contains('bili'), isFalse,
          reason: '*** must NOT live under the external video site namespace');
      expect(kDanmakuBindPrefix.startsWith('dsh.danmaku.'), isTrue,
          reason: 'danmaku-library data belongs in the danmaku namespace');
    });

    test('*** the host writes the danmaku store, NOT the video-site binding', () {
      final page = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      final body = bodyOf(page, 'Future<void> _batchBindDanmaku(');
      expect(body, isNotEmpty, reason: 'handler must exist');
      expect(body.contains('saveDanmakuBind('), isTrue,
          reason: '*** must write the danmaku-library store');
      expect(body.contains('saveBinding('), isFalse,
          reason: '*** writing the video-site store would send a danmaku id '
              'to the wrong service on the next play');
    });

    test('*** the host READS the store back (otherwise the feature is fake)', () {
      final page = stripComments(File('lib/ui/player_page.dart').readAsStringSync());
      expect(page.contains('loadDanmakuBind('), isTrue,
          reason: '*** write-only = user sees success, next episode ignores it');
      expect(page.contains('dmBind?.episodes['), isTrue,
          reason: '*** must look up THIS episode, not just load the object');
    });
  });

  group('T113c-3 no cross-contamination', () {
    test('*** batch_bind.dart does not import the video-site binding module', () {
      final src = stripComments(File('lib/core/batch_bind.dart').readAsStringSync());
      expect(src.contains("bili/bili_bind.dart"), isFalse,
          reason: '*** importing it invites reusing BiliBinding for danmaku ids');
      expect(src.contains('BiliBinding'), isFalse);
      expect(src.contains('BiliEpisodeBinding'), isFalse);
    });
  });
}
