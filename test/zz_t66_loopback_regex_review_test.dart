// ═══════════════════════════════════════════════════════════════════════
//  独立复核：`_loopbackProxyUrl` 正则（Lead 2026-10-19 修）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守/证的是什么
//
// Lead 今天修了 `lib/core/sourin_api.dart` 的 `hideInternalUrls` 正则：
// 原正则只认 `https?://<环回>:<端口>/s/\S*` **一种形态**，换端口/换路径就漏。
// 本文件**只复核、不改实现**（实现归 Lead），回答三个问题：
//
// ```text
// ① 新正则会不会**过度匹配** —— 有没有把不该抹的东西抹掉了？
//    （外部 URL / 带标点的句子 / 同段多个地址 / 中英混排）
// ② 注入验证：把正则退回旧版 ⇒ 门禁必须红
//    （`zz_t66_r2_attribution_review_test.dart` 里两条「缺陷已修」是 isFalse）
// ③ `classify` 的判据读的是 `text`（未净化）还是 `display`（已净化）？
//    ⚠️ AGENTS.md §4 硬规矩：**别让同一个源比同一个源**
// ```
//
// # 为什么不把这些断言塞进 r2 那条门禁
// 那个文件的职责是「归因链路」（text vs display 的分工）；
// 本文件职责是「正则本身的行为矩阵」。混在一起 ⇒ 谁坏了都难定位。
//
// ⚠️ 判据全部**读真实函数输出**（`PlaybackErrorText.hideInternalUrls`），
//    不复制粘贴正则到本文件重算 —— 那是「同一个源比同一个源」。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/sourin_api.dart';

void main() {
  group('① 过度匹配：该抹的抹了，不该抹的一个字都不能少', () {
    // ── 必须被抹掉的（Lead 报的三条实测泄漏 + IPv6）──
    const mustHide = <String, String>{
      '端口1根路径': 'http://127.0.0.1:1/',
      'api路径': 'http://127.0.0.1:9999/api/v2/thing',
      'localhost+路径': 'http://localhost:2080/movie/x.mp4',
      'IPv6回环': 'http://[::1]:8080/x',
      '无端口': 'http://127.0.0.1/',
      '带query': 'http://127.0.0.1:57106/s/18df9acc/?a=1',
      '大写Host': 'HTTP://LOCALHOST:2080/s/abc',
    };
    mustHide.forEach((k, v) {
      test('抹掉：$k', () {
        final out = PlaybackErrorText.hideInternalUrls(v);
        expect(out.contains('127.0.0.1'), isFalse, reason: '$k 泄漏了 127.0.0.1：$out');
        expect(out.contains('localhost'), isFalse,
            reason: '$k 泄漏了 localhost：$out');
        expect(out.contains('::1'), isFalse, reason: '$k 泄漏了 ::1：$out');
      });
    });

    // ── ⚠️ 绝不能被抹掉的（过度匹配就是这里）──
    const mustKeep = <String, String>{
      '外部https': 'https://example.com/s/abc',
      '外部http': 'http://example.com:2080/movie/x.mp4',
      '外部带端口': 'http://cdn.example.org:8080/a',
      '非环回IP': 'http://192.168.1.10:8080/s/abc',
      '公网IP': 'http://8.8.8.8/s/abc',
      '纯文本无URL': '取流失败，请稍后重试。',
      '中文句子': '内置代理取不到这条流，换个网络再试。',
    };
    mustKeep.forEach((k, v) {
      test('保留：$k', () {
        final out = PlaybackErrorText.hideInternalUrls(v);
        expect(out, v,
            reason: '★★ 过度匹配：这条**不该**被改写，却变成了「$out」。\n'
                '原文：$v\n'
                '本函数只该抹「环回 host 的内置代理地址」，'
                '外部地址被抹掉会让用户失去可排查的信息（正是它自己写的理由②）。');
      });
    });

    // ── 尾随标点必须**保住**（:2203 注释：不能用 \S*）──
    //
    // ★★★ 复核结论（2026-10-19，本文件查出来的**真缺陷**）：
    // 新正则的字符集是 `[^\s，。；、）】」』]*` —— 它**只挡了中文/全角标点**，
    // **ASCII 标点仍在被吃**：
    // ```text
    //   IN : 取流失败(http://127.0.0.1:8080/s/x)后重试
    //   OUT: 取流失败(（内置代理地址）          ← ')' 连同后面的「后重试」全没了
    //   IN : see http://127.0.0.1:8080/s/x, retry
    //   OUT: see （内置代理地址） retry           ← ', ' 被吃
    //   IN : 尾随 http://127.0.0.1:8080/s/x.
    //   OUT: 尾随 （内置代理地址）                ← 句末 '.' 被吃
    // ```
    // ⇒ `:2203` 那段注释说「不吃尾随标点」，**对 CJK 成立、对 ASCII 不成立**。
    // 修法建议（实现归 Lead，本文件只标红不改）：把 ASCII 标点也排掉，例如
    //   `(?:[/?#][^\s，。；、）】」』,.;:!?'")\]]*)?`
    // ⚠️ 注意别把 URL **自身**的 `?a=1` / `#frag` 里的字符误排（它们在 `/` 之后）。
    //
    // ⇒ 下面这两条因此**是红的**（红得有道理：它们在如实记录一个未修的缺陷）。
    //   等 Lead 修完 ASCII 标点，这两条会自然转绿 ⇒ **不需要再改判据**。
    const punctCases = <String, List<String>>{
      '半角括号': ['取流失败(http://127.0.0.1:8080/s/x)后重试', ')'],
      'ASCII逗号': ['see http://127.0.0.1:8080/s/x, retry', ','],
      'ASCII句点': ['尾随 http://127.0.0.1:8080/s/x.', '.'],
    };
    punctCases.forEach((k, pair) {
      test('尾随标点保留：$k', () {
        final input = pair[0];
        final mark = pair[1];
        final out = PlaybackErrorText.hideInternalUrls(input);
        expect(out.contains(mark), isTrue,
            reason: '★★ 正则吃掉了尾随标点「$mark」：\n'
                '输入：$input\n输出：$out\n'
                '⇒ 用户会看到缺字句（如「取流失败(（内置代理地址）」）。'
                '`:2203` 注释只挡了中文标点，ASCII 标点漏网。');
      });
    });

    // ── 这三条 Lead 确实做到了（CJK 标点），作为**阳性对照**钉住，
    //    免得将来修 ASCII 时把 CJK 也改坏。
    const cjkOk = <String, String>{
      '全角括号': '取流失败（http://127.0.0.1:8080/s/x）后重试',
      '中文逗号': '地址 http://127.0.0.1:8080/s/x，然后重试',
      '中文句号': '地址是 http://127.0.0.1:8080/s/x。',
    };
    cjkOk.forEach((k, v) {
      test('CJK 标点保留（阳性对照）：$k', () {
        final out = PlaybackErrorText.hideInternalUrls(v);
        expect(out.contains('127.0.0.1'), isFalse, reason: '地址没抹：$out');
        expect(out.endsWith('后重试') || out.endsWith('。')
            || out.endsWith('，然后重试'), isTrue,
            reason: '★ CJK 尾随文字/标点被吃掉了：$out\n'
                '（这条现在绿 —— 将来修 ASCII 时别把它改坏）');
      });
    });

    // ── 同段多个地址 ──
    test('同段多个地址：两个都抹，互不吞对方', () {
      const two = 'a http://127.0.0.1:1111/s/x b http://localhost:2222/s/y c';
      final out = PlaybackErrorText.hideInternalUrls(two);
      expect(out.contains('127.0.0.1'), isFalse, reason: '第一个没抹：$out');
      expect(out.contains('localhost'), isFalse, reason: '第二个没抹：$out');
      // ⚠️ 断**分隔符两侧**的原文还在 ⇒ 证明没有贪婪吞到段尾。
      //    （第一版我写成 `out.contains(' a ')` —— 那是**我自己的错**：
      //      替换文本本身带前导空格，`a ` 后面直接跟的是「（」，`' a '` 根本不存在。
      //      这正是 AGENTS.md §8 记的「采样异常先问『该是什么』」。）
      for (final frag in const ['a ', ' b ', ' c']) {
        expect(out.contains(frag), isTrue,
            reason: '吞掉了片段「$frag」：$out\n'
                '⇒ 正则贪婪，把两个地址之间的分隔文字一起吃了。');
      }
    });

    // ── 中英混排 ──
    test('中英混排：抹地址、留中文', () {
      const s = '取流失败 http://127.0.0.1:8080/s/x please retry 稍后';
      final out = PlaybackErrorText.hideInternalUrls(s);
      expect(out.contains('127.0.0.1'), isFalse, reason: '地址没抹：$out');
      expect(out.contains('取流失败'), isTrue, reason: '中文被吞：$out');
      expect(out.contains('please retry'), isTrue, reason: '英文被吞：$out');
      expect(out.contains('稍后'), isTrue, reason: '尾部中文被吞：$out');
    });
  });

  group('② 注入验证：正则本身（旧版只认 /s/ ⇒ 必须红）', () {
    test('★ 注入对照：非 /s/ 形态在**旧正则**下会泄漏（证明本组有判别力）', () {
      // 把 Lead 修前的正则**原样**写一份，验证「旧版确实漏」
      // ⇒ 若旧版也能抹掉，说明 Lead 的「泄漏」结论不成立，本组判据无意义。
      final old = RegExp(r'https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/s/\S*');
      const leak = 'LEAK http://127.0.0.1:1/';
      expect(leak.replaceAll(old, 'X'), leak,
          reason: '★ 旧正则竟然抹掉了这条 ⇒ Lead 的「泄漏」前提不成立，'
              '请重新核对历史读数（否则下面那些断言是在给一个不存在的问题盖章）。');
      // 而新实现必须抹掉它
      expect(PlaybackErrorText.hideInternalUrls(leak).contains('127.0.0.1'),
          isFalse,
          reason: '★★ 当前实现没抹掉非 /s/ 形态 ⇒ 修复未生效或已回归');
    });

    test('★ 旧正则 vs 新正则：三条已知泄漏逐条对照', () {
      final old = RegExp(r'https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/s/\S*');
      const cases = <String>[
        'http://127.0.0.1:1/',
        'http://127.0.0.1:9999/api/v2/thing',
        'http://localhost:2080/movie/x.mp4',
      ];
      for (final c in cases) {
        expect(c.replaceAll(old, 'X'), c,
            reason: '旧正则本该漏掉「$c」');
        expect(PlaybackErrorText.hideInternalUrls(c).contains('127.0.0.1'),
            isFalse,
            reason: '★★ 新正则必须抹掉「$c」');
      }
    });
  });

  group('③ classify 的判据读哪一份文本（AGENTS §4 同源比较）', () {
    test('★ 源码级：classify 必须用**两份**文本（display 净化 / lower 原文）', () {
      final src = _readLib('lib/core/sourin_api.dart');
      expect(src.contains('final display = hideInternalUrls(text);'), isTrue,
          reason: '★★ classify 必须先算出净化版 `display` 供用户看');
      expect(src.contains('final lower = text.toLowerCase();'), isTrue,
          reason: '★★ 归因判据必须读**原文** `text`，'
              '否则 hideInternalUrls 的产物会让 proxyDown 恒真（源码注释记的那个误判环）');
    });

    test('★ 行为级：环回地址的归因仍是 proxyDown（不是被「内置代理」文案带跑）', () {
      const raw = 'Failed to open http://127.0.0.1:57106/s/18df9acc/.';
      final r = PlaybackErrorText.classify(raw);
      // 展示侧必须已净化
      expect(r.detail.contains('127.0.0.1'), isFalse,
          reason: '★★ 展示给用户的 detail 仍带内部地址：${r.detail}');
      // 归因侧必须仍认得出 proxy
      expect(r.kind, PlaybackFailureKind.proxy,
          reason: '环回地址导致的失败应归到 proxy 档，实际 kind=${r.kind}');
    });

    test('★ 反证：若把判据改成读 display，proxy 归因会坏（证明两份文本确有必要）', () {
      const raw = 'Failed to open http://127.0.0.1:57106/s/18df9acc/.';
      final display = PlaybackErrorText.hideInternalUrls(raw);
      // display 里已经没有 host/端口了 ⇒ 任何靠地址判 proxy 的逻辑都会失效
      expect(display.contains('127.0.0.1'), isFalse);
      expect(display.toLowerCase().contains('proxy'), isFalse,
          reason: '若净化后的文本里连 proxy 字样都没有，'
              '说明「读 display 判 proxy」这条路走不通 ⇒ 两份文本确有必要');
    });
  });
}

/// 读仓库内文件（判据要读**真实源码**，不复制粘贴）
String _readLib(String path) {
  for (final prefix in const ['', '../']) {
    final f = File('$prefix$path');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('读不到 $path');
}
