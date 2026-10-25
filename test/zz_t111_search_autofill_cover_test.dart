// ═══════════════════════════════════════════════════════════════════════
//  T111：弹幕面板 —— 自动填名 + 结果带封面
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//     > 要自动填充名字,然后还有 我怎么记得他这个可以有封面的?你看看能不能
//
// # ① 自动填名
//
// 改前面板打开时搜索框是**空的** —— 用户得自己重打一遍剧名，
// 而他正在看的那一集叫什么，应用明明知道（_liveTitle，标题栏那串）。
// bili 面板从 2026-10-09 起就有预填（player_page.dart 那条长注释是当时写的），
// 弹弹play 这条一直没有。
//
// # ② 封面（Owner 问「能不能」——查了，能）
//
// 实测官方 API 三个端点的字段：
//     /api/v2/search/episodes   animes[] = animeId, animeTitle, type,
//                               typeDescription, episodes      ← **没有封面**
//                               且 episodes[] 只有 episodeId + episodeTitle
//     /api/v2/search/anime      animes[] 带 imageUrl          ← 可以，但只有列表
//     /api/v2/bangumi/{animeId} bangumi.imageUrl              ← ★ 封面 + episodes
//  ⇒ 走第三条：一次请求同时拿到封面和剧集。
//
// 端到端实测：搜索「葬送的芙莉莲」→ animeId 17617 → imageUrl 下载
//   HTTP 200 / 30345 bytes / image/jpeg（不是死链）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/danmaku.dart';

String readRepoFile(String p) => File(p).readAsStringSync();

/// 去掉注释，避免『注释里提到某写法』把断言判红/判绿。
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

/// Take a function BODY by brace matching.
///
/// Why not 'substring from the signature for N characters': that window runs
/// past the closing brace and swallows the NEXT function too, so the
/// assertion still passes when the target function is broken. This repo has
/// already been burned by exactly that (zz_tcache3_wiring_test).
String bodyOf(String code, String signature) {
  final start = code.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: 'signature not found: $signature');
  final open = code.indexOf('{', start);
  expect(open, greaterThanOrEqualTo(0), reason: 'no body for $signature');
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return code.substring(open + 1, i);
    }
  }
  fail('unbalanced braces in $signature');
}

void main() {
  group('T111-① DanmakuMatch.cover 模型', () {
    test('默认空串（老调用点不传 = 行为逐字不变）', () {
      const m = DanmakuMatch(episodeId: 1);
      expect(m.cover, '');
    });

    test('fromJson 不吃 cover（该端点本来就没这个字段）', () {
      final m = DanmakuMatch.fromJson(<String, dynamic>{
        'episodeId': 7,
        'animeTitle': 'A',
        'episodeTitle': 'B',
      });
      expect(m, isNotNull);
      expect(m!.cover, '', reason: 'match 端点没有封面 ⇒ 只能是空串');
    });

    test('cover 可显式传入并被保留', () {
      const m = DanmakuMatch(episodeId: 1, cover: 'https://x/y.jpg');
      expect(m.cover, 'https://x/y.jpg');
    });

    test('label 不受 cover 影响（它只描述集数/偏移）', () {
      const a = DanmakuMatch(episodeId: 1, animeTitle: 'A', episodeTitle: 'B');
      const b = DanmakuMatch(
          episodeId: 1, animeTitle: 'A', episodeTitle: 'B', cover: 'https://x');
      expect(a.label, b.label);
    });
  });

  group('T111-② 取封面的那条链路', () {
    test('★ searchEpisodes 会去 bangumi/{animeId} 取封面', () {
      final src = stripComments(readRepoFile('lib/core/danmaku.dart'));
      expect(src.contains('/api/v2/bangumi/'), isTrue,
          reason: '★ 封面只在这个端点（search/episodes 没有 imageUrl）');
      expect(src.contains('_fetchCover'), isTrue);
      expect(src.contains('bangumi.imageUrl'), isFalse,
          reason: '要按键取 j[\'bangumi\'][\'imageUrl\']，不是点号写法');
      // 真的把 cover 填进 DanmakuMatch
      final se = src.substring(src.indexOf('Future<List<DanmakuMatch>> searchEpisodes'));
      expect(se.contains('cover: cover'), isTrue,
          reason: '★ 取到了必须真的塞进结果对象，否则等于没取');
    });

    test('★★ 取封面失败绝不打断搜索（装饰品不该让主功能挂）', () {
      final src = stripComments(readRepoFile('lib/core/danmaku.dart'));
      /*
       * Only the BODY of _fetchCover (brace matched).
       *
       * The first version used substring(i, i + 1200), and fault injection
       * proved it was a false green: changing the catch to rethrow still
       * PASSED, because the 1200-char window ran past the closing brace and
       * picked up the catch belonging to the NEXT function.
       */
      final body = bodyOf(src, 'Future<String> _fetchCover');
      expect(body.contains('catch'), isTrue,
          reason: 'must swallow errors: search has to work offline');
      expect(body.contains('rethrow'), isFalse,
          reason: 'never rethrow: the cover is decoration, it must not take search down');
      expect(body.contains("return ''"), isTrue,
          reason: 'failures must return an empty string so the UI can show a placeholder');
    });
  });

  group('T111-③ 面板渲染', () {
    test('★ 结果行真的画封面，且失败有占位（不留空洞）', () {
      final dlg = stripComments(
          readRepoFile('lib/ui/danmaku_search_page.dart'));
      expect(dlg.contains('coverImage('), isTrue,
          reason: '要用本仓统一的 coverImage()（按布局尺寸解码，避免糊/浪费）');
      expect(dlg.contains('match.cover.isEmpty'), isTrue,
          reason: '★ 空封面要有明确分支，否则会拿空 URL 去请求');
      expect(dlg.contains('errorBuilder'), isTrue,
          reason: '★ 死链要能降级，不能把整行弄崩');
      /*
       * ★ Must actually RENDER, not merely "have a branch".
       *
       * Fault injection proved the first version of this test was a false
       * green: replacing the non-empty branch with SizedBox.shrink() still
       * passed, because it only checked for the existence of strings like
       * 'coverImage(' -- text that can remain in the file while the code path
       * is unreachable or replaced.
       * => pin the non-empty branch to a widget that really draws the image.
       */
      expect(dlg.contains(': ClipRRect('), isTrue,
          reason: '★ 非空封面必须裁圆角并真的渲染（不是 shrink 掉）');
      expect(dlg.contains('child: coverImage('), isTrue,
          reason: '★ 图片必须由 coverImage 产出');
      // 2:3 比例（海报比例）—— 传 layoutHeight 才会按高度解码
      expect(dlg.contains('layoutHeight: 42'), isTrue,
          reason: '海报是 2:3 ⇒ 要传 layoutHeight，否则按宽度解码会取错缩略图');
    });

    test('★ 拆成两行显示（标题 + 集数），不再用「·」拼成一行', () {
      final dlg = stripComments(
          readRepoFile('lib/ui/danmaku_search_page.dart'));
      expect(dlg.contains(r"'\$title · \$ep'"), isFalse,
          reason: '改版后标题与集数分两行（有了封面，横排空间不够）');
    });
  });

  // ══════════════════════════════════════════════════════════════════════
  //  T111-④ 搜索框自动填名
  //
  // ★★★ 2026-10-25（审计 B5：真·恒真断言）：这一段原来是
  // ```dart
  // final i = src.indexOf('_danmakuSearchKeyword.isNotEmpty');
  // final cond = src.substring(i, i + 60);
  // expect(cond.contains('_danmakuSearchKeyword'), isTrue);   // ← 恒真
  // ```
  // 举证：`i` 就是**那个 needle 自己的位置**，而 `substring(i, i+60)` 从它起点开始
  // 切 60 个字符 ⇒ 切出来的串**必然**包含 needle 本身（除非 i<0 先抛 RangeError）。
  // ⇒ 它只证明"文件里有这串字"，对「条件方向对不对、两个分支谁是谁」零判别力：
  //   把 `isNotEmpty` 改成 `isEmpty`（条件反转）、或把两个分支互换，
  //   这条断言**仍然全绿** —— 那正是"封面/预填只在有关键词时才生效"要守的不变量。
  //
  // 改法：**结构化提取**整条三元表达式（条件 / 真分支 / 假分支三段），
  // 三段分别与期望逐字比对（去空白后），并配一条常驻的"等价注入"自检：
  // 把条件反转 / 分支互换 / 回退改空的样本喂给**同一套**判据，必须判红。
  // ══════════════════════════════════════════════════════════════════════
  group('T111-④ 搜索框自动填名', () {
    /// 去掉所有空白，便于对"结构"而不是"排版"做比对
    String n(String s) => s.replaceAll(RegExp(r'\s+'), '');

    /// 取 `start` 之后到**顶层逗号**为止的表达式文本（跨行，跳过字符串/括号里的逗号）
    ///
    /// 为什么不用固定窗口：本仓已实测过多次——固定 N 字符的窗口会
    /// 吞到**下一个**成员上去，于是"目标写坏了"仍然绿（见本文件 bodyOf 的注释）。
    String expressionFrom(String code, int start) {
      var depth = 0;
      String? quote;
      for (var i = start; i < code.length; i++) {
        final c = code[i];
        if (quote != null) {
          if (c == r'\') {
            i++; // 跳过转义字符
            continue;
          }
          if (c == quote) quote = null;
          continue;
        }
        if (c == "'" || c == '"') {
          quote = c;
          continue;
        }
        if (c == '(' || c == '[' || c == '{') depth++;
        if (c == ')' || c == ']' || c == '}') depth--;
        if (c == ',' && depth == 0) return code.substring(start, i);
      }
      fail('没找到表达式结尾（顶层逗号）');
    }

    /// 定位 `searchKeyword:` 里**唯一那条三元**，返回冒号后的下标
    ///
    /// ⚠️ 不能直接 `indexOf('searchKeyword:')`：本仓 `player_page.dart` 里有 5 处
    ///    `searchKeyword:`（其余是简单赋值）。第一版就栽在这里：唯一性前提没断，
    ///    取到的是**另一处**，于是断言对错了地方。⇒ 先按"这段后面是不是三元"筛，
    ///    再要求筛出来的**恰好一处**。
    int searchKeywordTernaryStart(String code) {
      final hits = <int>[];
      for (final m in RegExp(r'searchKeyword:').allMatches(code)) {
        final tail = expressionFrom(code, m.end);
        if (tail.contains('?')) hits.add(m.end);
      }
      expect(hits.length, 1,
          reason: '★★ `searchKeyword:` 里带三元的必须**恰好一处**（实测 ${hits.length} 处）；'
              '多了说明预填逻辑被复制了，少了说明它被删了 —— 两种情况都要先看人的决定');
      return hits.single;
    }

    /// 把 `cond ? then : else` 拆成三段（本仓这几处三元都不嵌套）
    ({String cond, String thenBranch, String elseBranch}) splitTernary(
        String expr) {
      var depth = 0;
      String? quote;
      var q = -1;
      for (var i = 0; i < expr.length; i++) {
        final c = expr[i];
        if (quote != null) {
          if (c == r'\') {
            i++;
            continue;
          }
          if (c == quote) quote = null;
          continue;
        }
        if (c == "'" || c == '"') {
          quote = c;
          continue;
        }
        if (c == '(' || c == '[' || c == '{') depth++;
        if (c == ')' || c == ']' || c == '}') depth--;
        if (c == '?' && depth == 0) {
          q = i;
          break;
        }
      }
      expect(q, greaterThan(0), reason: '★ 这里必须是三元表达式（找不到顶层 ?）');
      var d2 = 0;
      String? q2;
      var colon = -1;
      for (var i = q + 1; i < expr.length; i++) {
        final c = expr[i];
        if (q2 != null) {
          if (c == r'\') {
            i++;
            continue;
          }
          if (c == q2) q2 = null;
          continue;
        }
        if (c == "'" || c == '"') {
          q2 = c;
          continue;
        }
        if (c == '(' || c == '[' || c == '{') d2++;
        if (c == ')' || c == ']' || c == '}') d2--;
        if (c == ':' && d2 == 0) {
          colon = i;
          break;
        }
      }
      expect(colon, greaterThan(q), reason: '★ 三元缺 else 分支（找不到顶层 :）');
      return (
        cond: n(expr.substring(0, q)),
        thenBranch: n(expr.substring(q + 1, colon)),
        elseBranch: n(expr.substring(colon + 1)),
      );
    }

    /// 判据本体：**真源与"注入样本"共用同一套 expects**
    ///
    /// 只有这样才能证明判据有判别力：同一段代码喂进反转样本时必须抛 TestFailure。
    void expectPrefill(String code, {required String label}) {
      final expr = expressionFrom(code, searchKeywordTernaryStart(code));
      final t = splitTernary(expr);
      expect(t.cond, '_danmakuSearchKeyword.isNotEmpty',
          reason: '★★★ [$label] 条件必须是「用户已经搜过」（isNotEmpty）。\n'
              '反转成 isEmpty ⇒ 用户自己打的关键词会被 _liveTitle 覆盖掉。\n'
              '实测条件段 = ${t.cond}');
      expect(t.thenBranch, '_danmakuSearchKeyword',
          reason: '★★★ [$label] 真分支必须是**用户自己打的关键词**'
              '（实测真分支 = ${t.thenBranch}）');
      expect(t.elseBranch, '_liveTitle.trim()',
          reason: '★★★ [$label] 假分支必须是 _liveTitle.trim() 预填'
              '（实测假分支 = ${t.elseBranch}）');
    }

    test('★★ 打开面板用 _liveTitle 预填（而不是空串）', () {
      final pp = stripComments(readRepoFile('lib/ui/player_page.dart'));
      final t = splitTernary(expressionFrom(pp, searchKeywordTernaryStart(pp)));
      expect(t.elseBranch, '_liveTitle.trim()',
          reason: '★ 打开弹幕面板时必须预填 —— 这正是 Owner 要的「自动填充名字」；'
              '预填值取 _liveTitle（标题栏那串 = 最贴近用户认知），'
              '空串或别的字段都不算（实测假分支 = ${t.elseBranch}）');
    });

    test('★★★ 已有搜索关键词时优先用它（别覆盖用户自己打的字）', () {
      final pp = stripComments(readRepoFile('lib/ui/player_page.dart'));
      expectPrefill(pp, label: '真源');
    });

    // ══════════════════════════════════════════════════════════════════
    //  ★★★ 常驻"等价注入"：把三种改坏的样本喂给**同一套**判据，必须判红
    //
    //  为什么把它写进测试而不是做一次性注入：一次性注入只证明"那天能红"，
    //  而这条自检**每次跑**都会重新证明判据有判别力 —— 将来谁把判据改软
    //  （例如退回 substring(i, i+60) 那种恒真写法），这里立刻红。
    //  ⚠️ 不动 lib/**（生产文件归别人），所以"注入"发生在样本上，而不是改产品代码。
    // ══════════════════════════════════════════════════════════════════
    test('★★★ 判据自检：条件反转 / 分支互换 / 回退改空 ⇒ 必须判红', () {
      // ⚠️ 必须用 `${head}`：`$head_danmakuSearchKeyword` 会被当成一个标识符
      //    （`_` 是合法标识符字符）—— 第一版就是这么编译不过的。
      const head = 'searchKeyword: ';
      final fixtures = <String, String>{
        '条件反转（isEmpty 才用关键词）':
            '${head}_danmakuSearchKeyword.isEmpty\n  ? _danmakuSearchKeyword\n  : _liveTitle.trim(),',
        '两个分支互换':
            '${head}_danmakuSearchKeyword.isNotEmpty\n  ? _liveTitle.trim()\n  : _danmakuSearchKeyword,',
        '回退改成空串':
            '${head}_danmakuSearchKeyword.isNotEmpty\n  ? _danmakuSearchKeyword\n  : "",',
        '回退改成别的字段':
            '${head}_danmakuSearchKeyword.isNotEmpty\n  ? _danmakuSearchKeyword\n  : _danmakuFileName,',
      };
      for (final e in fixtures.entries) {
        expect(() => expectPrefill(e.value, label: e.key),
            throwsA(isA<TestFailure>()),
            reason: '★★★ 样本「${e.key}」必须判红 —— 否则上面那条真源断言没有判别力');
      }
      // 阳性对照：同一套判据喂**正确**样本必须通过（否则上面的"必须红"是恒真）
      expectPrefill(
          '${head}_danmakuSearchKeyword.isNotEmpty ? _danmakuSearchKeyword : _liveTitle.trim(),',
          label: '正确样本');

      // ══════════════════════════════════════════════════════════════════
      //  ★★★ B5 的**可执行举证**：旧写法在"分支互换"样本上**依然为真**
      //
      //  这就是"真·恒真断言"的意思：不是写法丑，而是它对**最要命的一种改坏**
      //  （两个分支方向反了）零判别力。把这段留在门禁里，是为了下次谁想
      //  退回 `substring(i, i+60).contains(...)` 时，能立刻看到它为什么不行。
      // ══════════════════════════════════════════════════════════════════
      final swapped = fixtures['两个分支互换']!;
      final oldI = swapped.indexOf('_danmakuSearchKeyword.isNotEmpty');
      expect(oldI, greaterThanOrEqualTo(0), reason: '前提：互换样本里仍有这个 needle');
      final oldFormVerdict =
          swapped.substring(oldI, oldI + 60).contains('_danmakuSearchKeyword');
      expect(oldFormVerdict, isTrue,
          reason: '★★★ 旧写法的读数：它对这个"分支方向反了"的样本仍然判真 '
              '⇒ 它对本次修复要守的不变量没有任何判别力（这就是 B5 的举证）');
      // 同一份样本，新判据必须判红（两条判据的差别就是本次修复的全部意义）
      expect(() => expectPrefill(swapped, label: '分支互换'),
          throwsA(isA<TestFailure>()),
          reason: '★★★ 新判据必须在同一份样本上判红 —— 否则这次修复没有意义');
    });


    test('★ 预填不是锁定：用户仍可编辑后再搜', () {
      final dlg = stripComments(
          readRepoFile('lib/ui/danmaku_search_page.dart'));
      // 输入框必须绑 controller（用户可改），而不是显示一个静态 Text
      expect(dlg.contains('controller: _keyword'), isTrue,
          reason: '★ 必须是可编辑输入框（预填只是初值）');
    });
  });
}
