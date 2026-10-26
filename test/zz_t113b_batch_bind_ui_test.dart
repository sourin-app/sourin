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
          isTrue,
          reason: '** 类型必须是可空的 `ValueChanged<List<DanmakuMatch>>?`：'
              '「声明成必填」和「声明成非空类型」是两条独立的破坏路径，'
              '前者让旧调用点编译不过，后者让宿主无法表达"这次不绑定"');
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
      // ★ 2026-10-25（审计 B13）：下面四条原来是从旧文件迁移时**丢了 reason** 的
      //   裸 expect。补回的理由写的是"这条断言到底守哪个不变量"，不是复述代码。
      expect(body, isNotEmpty,
          reason: '★ 前置：brace-balanced 提取必须真的取到 build 方法体。'
              '取空 ⇒ 后面所有 contains 都会恒假/恒真，整组判据同时失效');
      expect(body.contains("'预览批量绑定'"), isTrue,
          reason: '★★ 预览入口必须**有用户可见的文案**：声明了回调却没有任何按钮，'
              '就是"有这个功能但用户点不到"的死特性（迁移前的原话：'
              'declaring the callback but never using it = dead feature）');
      expect(body.contains('if (_preview)'), isTrue,
          reason: '★★ 确认区只在**预览之后**才渲染：没有这一层，'
              '用户会绕过"当前视频剧集 → 弹幕剧集"映射直接提交，'
              '等于回到"按列表顺序盲绑"的老毛病');
      expect(body.contains("'确认并交由播放器绑定'"), isTrue,
          reason: '★★ 确认按钮必须带**后果说明**的文案（"交由播放器绑定"）：'
              '只写「确定」会让用户不知道这一下会改播放器的绑定状态');
      expect(RegExp(r'widget\.onBatchBind\(selected\)').allMatches(body).length, 1,
          reason: '只有明确确认可提交；预览不得触发绑定。');
      /*
       * 2026-10-26（第 11 项：提交改走"用户确认的映射"）：
       * 这条原来钉的是一整行长字符串 —— 而判据本身是**三件事**，不该钉成一行。
       * ⇒ 拆成三条独立断言（**强度只增不减**：原来一处 substring 命中就算过，
       *   现在三件缺一即红；且"空计划"的判据从 `plan.items` 换成
       *   `_planItems()` —— 提交的是用户改过的映射，不是自动计划）。
       */
      expect(body.contains('conflicts.isNotEmpty'), isTrue,
          reason: '冲突未解决不得提交');
      expect(body.contains('_planItems().isEmpty'), isTrue,
          reason: '空计划不得提交（判据改成用户映射后的计划）');
      expect(body.contains('s.searchLoading || s.searchStale ? null'), isTrue,
          reason: '在途或过期结果都不得提交');
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
