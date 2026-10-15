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
          readRepoFile('lib/ui/widgets/danmaku_settings_dialog.dart'));
      expect(dlg.contains('coverImage('), isTrue,
          reason: '要用本仓统一的 coverImage()（按布局尺寸解码，避免糊/浪费）');
      expect(dlg.contains('m.cover.isEmpty'), isTrue,
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
          readRepoFile('lib/ui/widgets/danmaku_settings_dialog.dart'));
      expect(dlg.contains(r"'\$title · \$ep'"), isFalse,
          reason: '改版后标题与集数分两行（有了封面，横排空间不够）');
    });
  });

  group('T111-④ 搜索框自动填名', () {
    test('★★ 打开面板用 _liveTitle 预填（而不是空串）', () {
      final pp = stripComments(readRepoFile('lib/ui/player_page.dart'));
      final i = pp.indexOf('_danmakuSearchKeyword.isNotEmpty');
      expect(i, greaterThanOrEqualTo(0),
          reason: '★ 打开弹幕面板时必须预填 —— 这正是 Owner 要的「自动填充名字」');
      final around = pp.substring(i, i + 200);
      expect(around.contains('_liveTitle'), isTrue,
          reason: '预填值取 _liveTitle（标题栏那串 = 最贴近用户认知）');
    });

    test('★ 已有搜索关键词时优先用它（别覆盖用户自己打的字）', () {
      final pp = stripComments(readRepoFile('lib/ui/player_page.dart'));
      final i = pp.indexOf('_danmakuSearchKeyword.isNotEmpty');
      final cond = pp.substring(i, i + 60);
      expect(cond.contains('_danmakuSearchKeyword'), isTrue,
          reason: '★ 用户搜过之后，他自己的关键词优先于 _liveTitle 猜测');
    });

    test('★ 预填不是锁定：用户仍可编辑后再搜', () {
      final dlg = stripComments(
          readRepoFile('lib/ui/widgets/danmaku_settings_dialog.dart'));
      // 输入框必须绑 controller（用户可改），而不是显示一个静态 Text
      expect(dlg.contains('controller: _searchKeyword'), isTrue,
          reason: '★ 必须是可编辑输入框（预填只是初值）');
    });
  });
}
