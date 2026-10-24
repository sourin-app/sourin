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

  final search = stripComments(File('lib/ui/danmaku_search_page.dart').readAsStringSync());

  group('T113b-1 independent search page', () {
    test('** onBatchBind is declared optional (old hosts must still compile)', () {
      expect(panel.contains('this.onBatchBind,'), isTrue,
          reason: '** required would break every existing call site');
      expect(panel.contains('final ValueChanged<List<DanmakuMatch>>? onBatchBind;'),
          isTrue);
    });

    // 第12项将搜索与批量绑定迁入独立页；旧面板不再渲染提交按钮。
    test('independent search requires the host binding callback', () {
      expect(search.contains('required this.onBatchBind'), isTrue,
          reason: '独立页必须由宿主提供真实绑定回调，不渲染空操作按钮。');
      expect(panel.contains('if (widget.onBatchBind != null)'), isFalse,
          reason: '旧面板不得重复渲染批量绑定表单。');
    });

    test('preview is separate from guarded explicit confirmation', () {
      final body = bodyOf(search, 'Widget build(BuildContext context)');
      expect(body, isNotEmpty);
      expect(body.contains("'预览批量绑定'"), isTrue);
      expect(body.contains('if (_preview)'), isTrue);
      expect(body.contains("'确认并交由播放器绑定'"), isTrue);
      expect(RegExp(r'widget\.onBatchBind\(selected\)').allMatches(body).length, 1,
          reason: '只有明确确认可提交；预览不得触发绑定。');
      expect(body.contains('conflicts.isNotEmpty || plan.items.isEmpty || s.searchLoading || s.searchStale ? null'), isTrue,
          reason: '冲突、空计划、在途或过期结果都不得提交。');
      expect(body.contains('onChanged: s.searchLoading || s.searchStale ? null'), isTrue,
          reason: '过期或在途结果不可选择。');
      expect(body.contains('buildBatchBindPlan(localTitles:'), isTrue,
          reason: '独立页预览必须复用核心对齐算法。');
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
      /*
       * 2026-10-15 (corrected): this used to assert `saveBinding(`, which is
       * the EXTERNAL VIDEO SITE store.  That was the bug, not the contract --
       * writing dandanplay episodeIds there makes the next play call the other
       * site's comment API with the wrong id.  The store separation itself is
       * pinned in zz_t113c; here we only require that SOMETHING persists.
       */
      expect(body.contains('saveDanmakuBind('), isTrue,
          reason: '*** a plan that is never persisted does nothing');
    });

    test('*** the binding records which work it came from', () {
      final body = bodyOf(page, 'Future<void> _batchBindDanmaku(');
      /*
       * 2026-10-15 (corrected): `manual: true` belonged to the video-site
       * binding model.  The danmaku store has no auto-overwrite path at all,
       * so the durable contract here is that the work title is recorded --
       * that is what tells the user (and us) which show got bound.
       */
      expect(body.contains('workTitle:'), isTrue,
          reason: '*** without it there is no record of what was bound');
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
