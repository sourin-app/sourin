// task-66 / 轨道 I：**手动绑定**外部源之后的弹幕聚合
//
// ⚠️ **不带任何 @Tags** —— 这是一条纯源码契约测试，不产 PNG、不连网。
//    带了 `needs-shot-dir` / `needs-network` 会被 CI **默认跳过**，
//    那就等于这条门禁根本不存在（假绿）。
//
// # 这条门禁补的是第 65 轮漏掉的那一半
// ```text
// 第 65 轮（c836356）做了 DanmakuAggregator 并接在**两条**路上：
//   · :6580  pinned 弹幕库支
//   · :6621  dan-api / 官方主路径
//
// 但 `_loadBiliDanmaku()` 与 `_biliApplyComments()` 这两条**外部源**路径
// 直接 `_danmakuComments = r.comments;` ⇒ **绕过了聚合器**，
// `_setDanmakuInfo` 也没传 `aggregate:`。
//
// 后果：用户**手动绑定**外部源之后（aedc29c 取消了自动绑定 ⇒ 绑定一定手动），
// 这一集只有外部源那一份弹幕，插件那份**不会**并进来。
// 而 Owner 第 11 条要的正是「插件自带 + 导入源同时加载并**合并**」。
// ```
//
// # 这份测试怎么咬人（源码契约，因为 PlayerPage 构造需要 libmpv）
// ```text
// ⚠️ `flutter_tester` 里构造 PlayerPage 会加载 libmpv-2.dll 偶发 native 崩溃
//    （见 dart_test.yaml 顶部）。所以这里断言**源码形态**，
//    行为正确性由 `DanmakuAggregator` 的单测（t65b，21 例）保证。
//
// 判据不是"文件里出现过 _aggregateDanmaku"（那种写法换个函数就假绿），
// 而是：**每一个喂 `_danmakuComments` 的成功支，右边都必须是聚合结果**。
// ```
//
// 跑法：
//   flutter test test/zz_t66_danmaku_bili_aggregate_gate_test.dart --concurrency=1
//
// # 故障注入（改前必须先红）
// ```text
// 本文件的判据在**改前就是红的**（这正是它存在的理由）：
//   `_danmakuComments = r.comments;` 出现 3 次，而聚合器只被调用 2 次。
// 改完（两个成功支走聚合）⇒ 绿。
// 反向注入：把任一成功支退回 `= r.comments;` ⇒ 必须重新红（已实测）。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _pagePath = 'lib/ui/player_page.dart';

/// 剥掉 `//` 与 `/* */` 注释（照抄 t73 的 stripComments，逐字一致）
///
/// ⚠️ 必须剥：本文件的判据是**代码形态**，而我在修复里写了
///    「改前这里是 `_danmakuComments = r.comments;`」这类注释 ——
///    不剥的话注释会把自己数进去。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 取某个函数从 `开头` 到**下一个同级函数开头**的切片
///
/// # 为什么不用 `substring(i0, i0 + 2600)` 那种魔数窗口
/// ```text
/// 第 65 轮实测过它的坏处：窗口是**字符数**，一旦有人在函数里加注释，
/// 后面的内容就被推出窗口 ⇒ 断言平白无故变红（t73 的 P2-10 就是这病）。
/// ⇒ 按"下一个函数开头"切，与字符数无关。
/// ```
String functionBody(String src, String signature) {
  final i0 = src.indexOf(signature);
  expect(i0, greaterThanOrEqualTo(0), reason: '找不到 `$signature`');
  // 下一个 `\n  Future<` / `\n  void _` / `\n  String ` 等「同级成员开头」
  final rest = src.substring(i0 + signature.length);
  final m = RegExp(r'\n  (?:Future<[^\n]*?>|void|bool|int|String|double) _?[A-Za-z]')
      .firstMatch(rest);
  final end = m == null ? src.length : i0 + signature.length + m.start;
  return src.substring(i0, end);
}

void main() {
  late String page;

  setUpAll(() {
    page = stripComments(File(_pagePath).readAsStringSync());
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 核心判据：所有"喂给渲染层"的赋值，右边都得是聚合结果
  // ═══════════════════════════════════════════════════════════════════
  group('① 每一条成功支都必须经过聚合器', () {
    test('★★★ 不存在「把某一源的 comments 直接灌进 _danmakuComments」的成功支', () {
      /*
       * 这是本文件最硬的一条。
       *
       * 改前实测：`_danmakuComments = r.comments;` 出现 **3** 次
       *          （7904 失败支 / 7938 `_loadBiliDanmaku` 成功 / 7980 `_biliApplyComments`）
       * 改后：只剩 **1** 次（7904 失败支，那里 `r.comments` 是空列表，不需要聚合）
       *
       * ⚠️ 失败支为什么可以留：`BiliUpdateResult` 在失败时 `comments` 是
       *    `old?.comments ?? const []`（bili_auto_update.dart:220-222），
       *    也就是"保留上一次的"，它本来就不该被当成新数据去聚合。
       *
       * ⚠️ `debugDanmakuSetComments(cs)` 为什么不在此列：
       *    那是**探针注入口**（:8269），灌的是本地构造数据、走假数据链路，
       *    没有"第二个源"可聚合。把它算进来是**误伤**——
       *    我第一版就是这个毛病：判据写成"直灌总数必须=1"，实测 2 ⇒ 假红。
       *    ⇒ 判据收窄到 `r.comments`（真网络取回的那一份）。
       */
      final rComments = '_danmakuComments = r.comments;'.allMatches(page).length;
      final resComments =
          '_danmakuComments = res.comments;'.allMatches(page).length;
      expect(rComments, 1,
          reason: '★★★ `_danmakuComments = r.comments;` 应当只剩 1 处（失败支）。'
              '实测 $rComments 处 —— 多出来的就是**绕过聚合器**的成功支：'
              '用户手动绑定外部源后插件那份弹幕会消失（Owner 第 11 条）');
      expect(resComments, 0,
          reason: '★ `res.comments` 是 dan-api 主路径的原始产物，'
              '它必须经过聚合器才能落到 `_danmakuComments`');
    });

    test('★★★ `_danmakuComments = agg.comments;` 至少 4 处（两条老路 + 两条外部源路）', () {
      /*
       * 改前的 2 处：pinned 支（:6589）、dan-api 主路径（:6636）
       * 本次新增的 2 处：`_loadBiliDanmaku` 成功支、`_biliApplyComments`
       *
       * ⚠️ 这条与上一条**成对**才有意义：
       *    上一条说"直灌的少了"，这一条说"聚合的多了" ——
       *    只钉住其中一条，把整段删掉也能绿（那是假绿）。
       */
      final n = '_danmakuComments = agg.comments;'.allMatches(page).length;
      expect(n, greaterThanOrEqualTo(4),
          reason: '★★★ 至少四条路要走聚合：pinned / dan-api 主路径 / '
              '外部源首载 / 外部源增量。实测只有 $n 条');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 两个外部源支真的调了聚合器（不只是"文件里出现过"）
  // ═══════════════════════════════════════════════════════════════════
  group('② 外部源那两条路逐个验证（按函数切片，不按字符数）', () {
    test('★★★ `_loadBiliDanmaku` 体内调用了 `_aggregateDanmaku`', () {
      final body = functionBody(page, 'Future<void> _loadBiliDanmaku(');
      expect(body.contains('_aggregateDanmaku('), isTrue,
          reason: '★★★ 首载外部源必须走聚合 —— 否则绑定之后只有外部源那一份');
      expect(body.contains('_danmakuComments = agg.comments;'), isTrue,
          reason: '★ 而且灌进去的得是聚合结果，不是 `r.comments`');
    });

    test('★★★ `_biliApplyComments` 体内调用了 `_aggregateDanmaku`', () {
      /*
       * ⚠️ 签名在本次修复里从 `void …` 变成了 `Future<void> … async`：
       *    聚合要 `await` 插件的弹幕。这条测试因此必须按**新**签名取切片。
       *
       *    这个变化本身值得钉 —— 有人把它改回 `void`，就没法 await，
       *    聚合只能靠 `.then()` 那种更绕的写法（或干脆漏掉聚合）。
       */
      final body = functionBody(page, 'Future<void> _biliApplyComments(');
      expect(page.contains('Future<void> _biliApplyComments('), isTrue,
          reason: '★ 必须是 async 形态（聚合要 await 插件那一路）');
      expect(body.contains('_aggregateDanmaku('), isTrue,
          reason: '★★★ 增量更新（用户点「立即更新」/ 自动刷新）同样要聚合 —— '
              '否则点一次更新，插件那份弹幕就消失了');
      expect(body.contains('_danmakuComments = agg.comments;'), isTrue);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ Lead 特别提醒的一条：合并之后**分路统计不能丢**
  // ═══════════════════════════════════════════════════════════════════
  group('③ 合并后仍要把每一路的条数交给面板', () {
    test('★★★ 每个用 `agg.comments` 的地方都同时传了 `aggregate:`', () {
      /*
       * # 这条防的是什么
       * ```text
       * 很容易写成：
       *   _danmakuComments = agg.comments;      // 合并了
       *   _setDanmakuInfo(source: ...);          // ← 忘了传 aggregate
       * ⇒ 面板显示「已载入 1900 条」，但"来源"那栏是空的 ——
       *   用户知道总数、不知道**哪来的**，而这正是面板存在的意义。
       *
       * 第 65 轮我在两条老路上做对了（:6597 / :6690 都有 aggregate: agg），
       * 外部源那两条是**新接的**，最容易漏。
       * ```
       */
      // 把每个 agg.comments 赋值点向后取 12 行，检查同一块里有没有 aggregate:
      final re = RegExp(r'_danmakuComments = agg\.comments;');
      final matches = re.allMatches(page).toList();
      expect(matches.length, greaterThanOrEqualTo(4),
          reason: '前置条件：先得有 4 处聚合赋值（见 ①）');

      final missing = <String>[];
      for (final m in matches) {
        final tail = page.substring(m.start, (m.start + 1400).clamp(0, page.length));
        if (!tail.contains('aggregate: agg')) {
          // 报出行号方便定位
          final line = '\n'.allMatches(page.substring(0, m.start)).length + 1;
          missing.add('line ~$line');
        }
      }
      expect(missing, isEmpty,
          reason: '★★★ 这些聚合赋值点没有把 `aggregate: agg` 交给面板：$missing。'
              '合并后分路统计丢了，用户看到总数却不知道哪来的');
    });

    test('★★ `_setDanmakuInfo` 把每一路的 count 原样保留（不被合并总数覆盖）', () {
      final body = functionBody(page, 'void _setDanmakuInfo(');
      expect(body.contains('count: f.count'), isTrue,
          reason: '★★ 面板要的是**每一路自己**的条数（去重前）。'
              '若这里写成合并总数，用户就无法核对「插件 N + 导入 M = 总 K」');
      expect(body.contains('aggregate.feeds'), isTrue,
          reason: '★ 必须遍历 feeds 而不是只取一个总数');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 反向保护：别把失败支也改了
  // ═══════════════════════════════════════════════════════════════════
  group('④ 失败支保持原样（它不该被聚合）', () {
    test('★★ 失败支仍然直接赋 `r.comments`（那是"保留旧数据"）', () {
      final body = functionBody(page, 'Future<void> _loadBiliDanmaku(');
      /*
       * 失败支里 `r.comments` 是 `old?.comments ?? const []` —— 保留上一次的数据。
       * 那不是"新取到的一路"，拿去聚合会把旧数据当成新源重复计一遍。
       */
      final okIdx = body.indexOf('if (!r.ok)');
      final failIdx = body.indexOf('_danmakuComments = r.comments;', okIdx);
      expect(failIdx, greaterThan(okIdx),
          reason: '★ 失败支的 `= r.comments` 必须还在 `if (!r.ok)` 那一块里');
    });
  });
}
