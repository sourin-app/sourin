// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R2「内置代理没起来」文案撒谎 —— **独立复核**
// ═══════════════════════════════════════════════════════════════════════
//
// # 被复核的东西（`f47d2ed`，计划标 ✅ 已修，但没人独立复核过）
// ```text
// lib/core/sourin_api.dart · PlaybackErrorText.classify（:4000）
//   :4028  final text    = stripHostErrorNoise(raw);      ← 归因输入
//   :4036  final display = hideInternalUrls(text);        ← 给用户看的正文
//   :4037  final lower   = text.toLowerCase();            ← ★ 判据读的是它
// ```
//
// # 原缺陷（自我强化的误判环）
// ```text
// 改前：`final lower = display.toLowerCase();`
//   ① hideInternalUrls 把 `127.0.0.1:57106` 改写成「内置代理取不到这条流」
//   ② ①段 proxyDown 判据当时含 lower.contains('内置代理')
//   ③ ⇒ **恒命中** ⇒ kind=proxy ⇒ UI 永远说「内置代理没起来」
// 而 Owner 实测：同一端口 57106 在 43 秒 / 4 分钟 / 6 分钟后都成功起播
//   ⇒ 代理一直是活的 ⇒ 「没起来」是假的。
// ```
//
// # 本文件只**复核**，不改 lib/ 一行。
//   核心是**分家**这件事，而且是**双向**的：
//     · 单向（把 display 喂回判据）⇒ 只有"改坏"会被抓到
//     · 双向（还须抓"把该给用户的净化版漏出去"）⇒ 才算真的分家
//
// ⚠️ 判据纪律（Lead 立的方法论）：每条都要能回答
//   「**这个缺陷存在时，它凭什么会红**」—— 答不上来的判据多半恒真。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/sourin_api.dart';

/// 读仓库文件（只读复核，不写任何东西）
String _readRepo(String rel) => File(rel).readAsStringSync();

void main() {
  // Owner 真机报的那条原始错误（逐字，R2 的锚点）
  const loopbackOpenFail = 'Failed to open http://127.0.0.1:57106/s/18df9acc/.';
  const localhostOpenFail = 'Failed to open http://localhost:2080/s/abc/.';
  const connectionRefused = 'Connection refused (os error 61)';

  // ══════════════════════════════════════════════════════════════════
  // ① 正向：**确实分家了** —— 判据读原文，展示读净化版
  // ══════════════════════════════════════════════════════════════════
  group('① 分家成立：同一份错误串，判定与展示各取所需', () {
    test('★★★ 环回地址「打不开」⇒ 归 proxy（判据看到了原文里的地址）', () {
      final r = PlaybackErrorText.classify(loopbackOpenFail);
      expect(r.kind, PlaybackFailureKind.proxy,
          reason: '★★★ 判 proxy 的依据是**原文里的 127.0.0.1**，'
              '不是展示文案。若判据改成读 display，这条会红。');
    });

    test('★★★ 同一条错误，用户看到的是净化版（内部地址不外泄）', () {
      final r = PlaybackErrorText.classify(loopbackOpenFail);
      expect(r.detail, isNot(contains('127.0.0.1')),
          reason: '★★★ 用户可见正文不许含内部地址（Owner 第 6 条）');
      expect(r.detail, isNot(contains('57106')));
      expect(r.detail, contains('内置代理'),
          reason: '★★ 替换成中性说明而不是留空（留空像被截断）');
    });

    test('★★ localhost 形态同样归 proxy（三种环回写法都要认）', () {
      expect(PlaybackErrorText.classify(localhostOpenFail).kind,
          PlaybackFailureKind.proxy);
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ② ★ 反向判据：把 display 喂回判据 ⇒ **必须红**
  //    这一半是「分家」的双向性：只做①的话，改坏了测不出来
  // ══════════════════════════════════════════════════════════════════
  group('② 双向判据（第一半）：判据若读 display，这两条必须红', () {
    test('★★★ 「Failed to open + 非环回地址」不该归 proxy', () {
      // ★★ 这条是**分离器**：它含 "failed to open"（proxyDown 的第一个条件）
      //    但**不含**环回地址 ⇒ 若 lower 读 display，display 里有
      //    「内置代理」而旧判据含它 ⇒ 会被错归 proxy。
      const notLoopback = 'Failed to open http://example.invalid/s/x/.';
      final r = PlaybackErrorText.classify(notLoopback);
      expect(r.kind, isNot(PlaybackFailureKind.proxy),
          reason: '★★★ 分离器：目标不是环回地址 ⇒ 不该判代理。'
              '若这条红了，说明 lower 又变回 display.toLowerCase() '
              '并让展示文案参与了判定。');
    });

    test('★★ 「Connection refused」仍归 proxy（这是真的代理层问题）', () {
      final r = PlaybackErrorText.classify(connectionRefused);
      expect(r.kind, PlaybackFailureKind.proxy);
      expect(r.detail, connectionRefused,
          reason: '非环回场景下 display 与原文同形（没有可抹的内部地址）');
    });

    test('★★ 展示文案里的「内置代理」**不得**参与判定（自我强化环已断）', () {
      // 具体形态：正文里本来就有「内置代理」四个字，但**没有**环回地址、
      // 也没有 refused / failed to open ⇒ 绝不能因为这四个字就判 proxy。
      const mentionsProxyWordOnly =
          'error sending request for url (http://example.invalid/a) 内置代理';
      final r = PlaybackErrorText.classify(mentionsProxyWordOnly);
      expect(r.kind, isNot(PlaybackFailureKind.proxy),
          reason: '★★★ 「内置代理」这四个字是**展示层的词**，'
              '它出现在输入里不应改变归因 —— '
              '这正是 R2 那个自我强化环的核心。');
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ③ ★ 反向判据（第二半）：该净化的没净化 ⇒ **也必须红**
  //    「分家」是双向的：只抓"判据别读 display"不够，
  //    还要抓"用户可见的别忘了净化"—— 否则会把原始内部地址直接吐给用户
  // ══════════════════════════════════════════════════════════════════
  group('③ 双向判据（第二半）：用户可见的那一份必须净化', () {
    test('★★ R2 那个形态：环回地址被抹掉、换成中性说明', () {
      final r = PlaybackErrorText.classify(loopbackOpenFail);
      expect(r.detail, isNot(contains('127.0.0.1')));
      expect(r.detail, isNot(contains('57106')));
    });

    // ⚠️★★ 以下两条是本轮复核**查出的真实缺陷**，不是我的期望值。
    // 证据：hideInternalUrls 的正则只认 `/s/<id>` 这一种形态
    //   （sourin_api.dart:3886-3889  r'https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/s/\S*'）
    //   ⇒ **其它路径形态的环回地址不会被抹**。
    // 实测（本轮探针跑出来的原文）：
    //   '<h1>403 Forbidden</h1><p>denied</p> http://127.0.0.1:1/'  ⇒ 原样输出（泄漏）
    //   'boom http://127.0.0.1:9999/api/v2/thing'                   ⇒ 原样输出（泄漏）
    //   '取流失败 http://localhost:2080/movie/x.mp4'                ⇒ 原样输出（泄漏）
    //
    // ⇒ 这**不影响 R2 的分家结论**（那说的是"判据别读 display"，已成立），
    //    但它是一条**真实的用户可见泄漏**，且本文件不修（不在写入范围）。
    //    这里用 `expect(..., isTrue)` **如实钉住现状（= 确实在泄漏）**，
    //    并写清它凭什么会红：等有人把正则放宽到"任意环回 URL"时，
    //    这两条会红 —— 那正是**修复发生**的那一刻 ⇒ 请把断言改成 isFalse。
    // ⚠️★★ 这条是**第二轮注入抓出来的洞**（2026-10-19）：
    //   我原先只验"403 那条分支的 detail 不含环回地址"，
    //   而它用的样本是 `http://127.0.0.1:1/` —— 这种形态
    //   **hideInternalUrls 本来就抹不掉**（正则只认 `/s/<id>`），
    //   所以无论 detail 用 display 还是 text，输出都含地址 ⇒ **恒绿**。
    // ⇒ 真正的判据必须用**能被抹掉的那个形态**：
    //    只有 `text` 会含 127.0.0.1，`display` 一定不含 ⇒ 才分得开两种写法。
    // 这也是 Lead 立的方法论那条：判据要能回答「缺陷存在时它凭什么会红」。
    test('★★★ 分支里的 detail 必须用 display：把 text 塞进来这条必须红', () {
      // 403 + 环回 /s/ 形态 ⇒ 走 4070 那条 permission 分支
      const sample = '<h1>403 Forbidden</h1> http://127.0.0.1:57106/s/abc/';
      final r = PlaybackErrorText.classify(sample);
      expect(r.kind, PlaybackFailureKind.permission,
          reason: '前置：确认走的是 403 ⇒ permission 分支，否则本条测不到东西');
      expect(r.detail, isNot(contains('127.0.0.1')),
          reason: '★★★ 分支里的 detail 若被换成 text，内部地址就会直接吐给用户。'
              '实测 kind=${r.kind} detail=${r.detail}');
      expect(r.detail, isNot(contains('57106')),
          reason: '★★★ 同上：端口号也是内部信息');
    });

    test('★★ 同类分支（429/5xx、404/410）也不许用原文', () {
      const sample = 'HTTP 502 http://127.0.0.1:57106/s/xyz/';
      final r = PlaybackErrorText.classify(sample);
      expect(r.kind, isNot(PlaybackFailureKind.permission),
          reason: '前置：这条不是 403，走的是后面的分支');
      expect(r.detail, isNot(contains('57106')),
          reason: '★★ 任何分支的 detail 都得是净化版。实测 detail=${r.detail}');
    });

    test('★★★ 非 /s/ 形态的环回地址也**不许**泄漏（缺陷已修）', () {
      const leaking = '<h1>403 Forbidden</h1><p>denied</p> http://127.0.0.1:1/';
      final r = PlaybackErrorText.classify(leaking);
      expect(
        r.detail.contains('127.0.0.1'),
        isFalse,
        reason: '★★★ 这条曾是「断言缺陷存在」（isTrue）。\n'
            '★ 2026-10-19 Lead 已修 `hideInternalUrls`：原正则只认 `/s/<id>` 一种形态，\n'
            '  换端口/换路径就直接漏 ⇒ 与该函数自己写的三条理由冲突。\n'
            '  新正则不锚定任何路径：环回 host + 端口后面一律吃掉（但不吃尾随标点）。\n'
            '⇒ 按原作者留下的指示，此时本条应变红 ⇒ 已改成 isFalse。\n'
            '当前实测 kind=${r.kind} detail=${r.detail}',
      );
    });

    test('★★ localhost 的非 /s/ 形态也**不许**泄漏（缺陷已修）', () {
      final out = PlaybackErrorText.hideInternalUrls(
        '取流失败 http://localhost:2080/movie/x.mp4',
      );
      expect(
        out.contains('localhost'),
        isFalse,
        reason: '同上：原为 isTrue（钉住缺陷），缺陷已修 ⇒ 改成 isFalse。'
            '当前实测 out=$out',
      );
    });

    test('★★ 修法不许「贪吃过头」：尾随标点与外部地址必须保住', () {
      // 只吃 URL 自身字符集 ⇒ 紧跟的句读要留着
      expect(
        PlaybackErrorText.hideInternalUrls('地址是 http://[::1]:8080/x，重试。'),
        contains('，重试。'),
        reason: '★ 正则若用 `\\S*` 会把「，」「。」一起吞掉，句子读起来像被截断',
      );
      // 外部地址不在环回表里 ⇒ 一个字都不许动
      const external = '普通 https://example.com/a/b 不该被动';
      expect(
        PlaybackErrorText.hideInternalUrls(external),
        external,
        reason: '★ 环回净化不得误伤任何外部 URL',
      );
    });
  });

  // ══════════════════════════════════════════════════════════════════
  // ④ 源码级核对：分家在**代码里**是真的（不靠行为巧合）
  // ══════════════════════════════════════════════════════════════════
  group('④ 源码核对：lower 读 text 而不是 display', () {
    /// 按大括号配对截出一个成员/函数的**函数体**（不按固定长度取 —— 见 R8 的教训）
    ///
    /// ⚠️ 第二、三版修的坑：`classify(` 的签名里有**命名参数块** `{`。
    /// 实测这一段的真实形态（**别用正则猜，先打印**）：
    /// ```text
    /// 'static PlaybackFailure classify(\n    Object? error, {\n
    ///   String? kindHint,\n    bool hadCandidates = false,\n  }) {\n    f…'
    /// ```
    /// 命名参数块的 `{` 与函数体的 `{` **花括号深度都会归零**，
    /// 靠「第一个 `{`」或「越过一层再找 `{`」都会取错范围。
    /// ⇒ 判据：**跟着圆括号走** —— 形参的 `)` 结束签名，
    ///    它后面的第一个 `{` 才是函数体；之后按花括号深度配对。
    ///
    /// ★ 另外带一条**自检**：截出的函数体长度必须够大（R2 的 classify 很长），
    ///    否则明确报错而不是静默返回一个片段 —— 那是本文件第一版的失败方式。
    String bodyOf(String src, String signature) {
      final start = src.indexOf(signature);
      expect(start, greaterThan(0), reason: '锚点不存在：$signature');

      // ① 找到签名的收尾 `)`：期间跳过命名参数块的 `{`/`}`（它们成对，不影响圆括号深度）
      // ⚠️ 签名 `classify(` **自带结尾的 `(`** ⇒ 起点要从那个 `(` 开始算，
      //    否则会漏掉它、导致形参深度算错（我第二版就栽在这，报「没找到形参列表」）。
      var parenDepth = 0;
      var sawAnyParen = false;
      var i = start + signature.length - 1; // 指向 classify 的 '('
      for (; i < src.length; i++) {
        final c = src[i];
        if (c == '(') {
          parenDepth++;
          sawAnyParen = true;
        } else if (c == ')') {
          if (parenDepth == 1) break; // ← 形参列表收尾（depth 1 → 0）
          parenDepth--;
        }
      }
      expect(sawAnyParen, isTrue, reason: '$signature 签名里没找到形参列表');

      // ② 形参 `)` 之后的第一个 `{` 就是函数体
      final open = src.indexOf('{', i);
      expect(open, greaterThan(0), reason: '找不到 $signature 的函数体大括号');

      var depth = 0;
      for (var j = open; j < src.length; j++) {
        final c = src[j];
        if (c == '{') depth++;
        if (c == '}') {
          depth--;
          if (depth == 0) {
            final body = src.substring(open, j + 1);
            expect(body.length, greaterThan(500),
                reason: '$signature 截出的函数体只有 ${body.length} 字符，'
                    '几乎可以肯定是截错了范围（第一版踩过这个坑）');
            return body;
          }
        }
      }
      fail('$signature 大括号不配对');
    }

    test('★★★ `final lower = text.toLowerCase();`（不是 display）', () {
      final src = _readRepo('lib/core/sourin_api.dart');
      final body = bodyOf(src, 'static PlaybackFailure classify(');
      expect(body, contains('final lower = text.toLowerCase();'),
          reason: '★★★ 归因输入必须是原文。'
              '这是 R2 那条缺陷的**唯一**分界线。');
      expect(body, isNot(contains('final lower = display.toLowerCase();')),
          reason: '★★★ 分家被合回去了 —— 这就是 R2 的原缺陷');
    });

    test('★★ display 仍然是用户可见那一份（两处都在，不是只剩一个）', () {
      final src = _readRepo('lib/core/sourin_api.dart');
      final body = bodyOf(src, 'static PlaybackFailure classify(');
      expect(body, contains('final display = hideInternalUrls('),
          reason: '净化版必须仍然存在（分家 = 两个都在，不是删一个）');
      expect(body, contains('final text = stripHostErrorNoise('));
    });

    test('★★ proxyDown 判据里**没有**「内置代理」（那是展示词，不是判据词）', () {
      final src = _readRepo('lib/core/sourin_api.dart');
      final body = bodyOf(src, 'static PlaybackFailure classify(');
      // 只看代码行（剥掉注释行），否则会命中那段描述旧缺陷的注释
      final codeLines = body
          .split('\n')
          .where((l) {
            final t = l.trimLeft();
            return !t.startsWith('//') &&
                !t.startsWith('*') &&
                !t.startsWith('/*');
          })
          .join('\n');
      expect(codeLines, isNot(contains('内置代理')),
          reason: '★★ 判据里出现「内置代理」= 展示词又参与了判定 '
              '⇒ 自我强化环复发。');
      expect(codeLines, contains('loopbackFailed'),
          reason: '★★ 真正的判据是环回地址本身');
    });
  });
}
