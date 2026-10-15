// T113b: the batch-bind UI wiring (panel button + host handler).
//
// The alignment math has its own gate (zz_t113_batch_bind_test.dart).  This
// file guards the WIRING, which is where a correct core can still be
// disconnected -- exactly the failure mode found earlier in this session when
// hasPrev/onPrev existed on the host but the bottom bar never rendered them.
//
// A comment saying "the button is there" is not evidence; these assertions use
// brace-balanced bodies so an explanatory comment cannot satisfy them.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

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

/// Body of a function, found by brace matching from its signature.
///
/// A fixed-width substring would run past the closing brace into the NEXT
/// function and report a false green -- that mistake was already made once in
/// this session, so this helper is mandatory here.
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
  final panel = stripComments(
      File('lib/ui/widgets/danmaku_settings_dialog.dart').readAsStringSync());
  final page = stripComments(File('lib/ui/player_page.dart').readAsStringSync());

  group('T113b-1 panel side', () {
    test('** onBatchBind is declared optional (old hosts must still compile)', () {
      expect(panel.contains('this.onBatchBind,'), isTrue,
          reason: '** required would break every existing call site');
      expect(panel.contains('final ValueChanged<List<DanmakuMatch>>? onBatchBind;'),
          isTrue);
    });

    test('** the button only renders when the host wired the callback', () {
      expect(panel.contains('if (widget.onBatchBind != null)'), isTrue,
          reason: '** no callback, no button -- same rule as onOpenBili');
    });

    test('*** the button is inside the search-results body (not somewhere dead)', () {
      final body = bodyOf(panel, 'Widget _searchResultBody(');
      expect(body, isNotEmpty, reason: 'helper must find the function');
      expect(body.contains('widget.onBatchBind'), isTrue,
          reason: '*** declaring the callback but never using it = dead feature');
      expect(body.contains("'整部绑定'"), isTrue,
          reason: 'the button must have user-visible copy');
    });

    test('** the panel does NOT re-implement alignment (single definition)', () {
      expect(panel.contains('buildBatchBindPlan'), isFalse,
          reason: '** alignment lives in core with its own gate; a second copy drifts');
    });
  });

  group('T113b-2 host side', () {
    test('** host actually passes onBatchBind', () {
      expect(page.contains('onBatchBind:'), isTrue,
          reason: '** without this the panel button never renders');
    });

    test('*** the handler builds a plan via core and saves it', () {
      final body = bodyOf(page, 'Future<void> _batchBindDanmaku(');
      expect(body, isNotEmpty, reason: 'handler must exist');
      expect(body.contains('buildBatchBindPlan('), isTrue,
          reason: '*** must use the core alignment, not hand-rolled pairing');
      expect(body.contains('saveBinding('), isTrue,
          reason: '*** a plan that is never persisted does nothing');
    });

    test('*** manual: true -- a user action must not be overwritten later', () {
      final body = bodyOf(page, 'Future<void> _batchBindDanmaku(');
      expect(body.contains('manual: true'), isTrue,
          reason: '*** without this the next auto pass silently rebinds it');
    });

    test('*** unbound episodes are reported to the user, not swallowed', () {
      final body = bodyOf(page, 'Future<void> _batchBindDanmaku(');
      expect(body.contains('unmatchedLocal'), isTrue,
          reason: '*** "bound 9" while hiding "3 unbound" makes the user think it is done');
    });

    test('** refuses to run before the episode list is known', () {
      final body = bodyOf(page, 'Future<void> _batchBindDanmaku(');
      expect(body.contains('titles.isEmpty'), isTrue,
          reason: '** binding against an empty local list would align nothing');
    });
  });
}
