// ★★★ 2026-10-18（E2E 验证发现）：宿主必须能解开 **raw-deflate** 响应
//
// # 真实缺陷（不是理论问题）
// ```text
// 某些站的弹幕接口返回 `Content-Encoding: deflate`，但它是 raw-deflate（无 zlib 头），
// 而 reqwest 的 `deflate` 特性按 **zlib** 格式解
//   ⇒ r.text().await 报 `error decoding response body`
//   ⇒ 插件拿不到任何数据 ⇒ 整个弹幕功能失效。
//
// 实测：同一接口两个不同 id 都是这样（前 2 字节 ecfd / bcfd ⇒ zlib 解压 False、raw 解压 True）
//   ⇒ 是该接口的**固定行为**，不是数据偶坏。
// ```
//
// # 本门禁守什么
// ```text
// ① 源码里必须有 raw-deflate 回退路径（flate2::read::DeflateDecoder）
// ② 回退必须**只在** deflate 响应上走（不许影响正常响应）
// ③ 回退必须**保留 HTTP 状态前缀**（否则插件读不到 401/404）
// ④ ★ 行为断言：真的能用 raw-deflate 数据解出原文
//    —— 这条是本轮教训：只断言"代码里有这行"是**深度太浅**的假绿
// ```
//
// # ⚠️ 为什么要把 ④ 写成独立的 Rust 单测
// ```text
// 本仓的 Dart 测试跑不到 Rust 里。所以：
//   · ①②③ 用源码断言（Dart 侧，剥注释后匹配）
//   · ④   写在 rust/sourin_core/src/plugins/mod.rs 的 #[cfg(test)] 里（真正的解码测试）
// ⇒ 两侧都要有，缺一边就是假绿。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 Rust 注释（行 + 块），避免断言命中注释里的示例文本
///
/// ★ 本仓已有多次教训：断言命中注释 ⇒ 假绿/假红。
String stripRustComments(String s) {
  final out = StringBuffer();
  var i = 0;
  while (i < s.length) {
    if (s.startsWith('//', i)) {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
    } else if (s.startsWith('/*', i)) {
      i += 2;
      while (i < s.length && !s.startsWith('*/', i)) {
        i++;
      }
      i += 2;
    } else if (s[i] == '"') {
      // 跳过字符串字面量（保留内容但避免误判里面的 //）
      out.write(s[i]);
      i++;
      while (i < s.length && s[i] != '"') {
        if (s[i] == r'\') {
          out.write(s[i]);
          i++;
          if (i < s.length) {
            out.write(s[i]);
            i++;
          }
          continue;
        }
        out.write(s[i]);
        i++;
      }
      if (i < s.length) {
        out.write(s[i]);
        i++;
      }
    } else {
      out.write(s[i]);
      i++;
    }
  }
  return out.toString();
}

void main() {
  late String raw;
  late String code;
  late String dartSide;

  setUpAll(() {
    final f = File('rust/sourin_core/src/plugins/mod.rs');
    expect(f.existsSync(), isTrue, reason: '找不到 plugins/mod.rs');
    raw = f.readAsStringSync();
    code = stripRustComments(raw);

    final d = File('rust/sourin_core/Cargo.toml');
    dartSide = d.readAsStringSync();
  });

  group('★★★ raw-deflate 回退：宿主必须能解开无 zlib 头的 deflate', () {
    test('① 必须有 raw-deflate 回退路径', () {
      expect(code.contains('try_raw_deflate_fallback'), isTrue,
          reason: '★ 必须有回退函数：'
              '某些站返回 Content-Encoding: deflate 但内容是 raw-deflate（无 zlib 头），'
              'reqwest 按 zlib 解会失败 ⇒ 插件拿不到数据。');

      expect(code.contains('DeflateDecoder'), isTrue,
          reason: '★ raw-deflate 要用 `flate2::read::DeflateDecoder` 解'
              '（不是 `ZlibDecoder` —— 那正是 reqwest 内部用的、解不开的那个）');
    });

    test('② flate2 必须是**直接**依赖（不能只靠 reqwest 间接引入）', () {
      expect(dartSide.contains('flate2'), isTrue,
          reason: '★ 用了 flate2 就必须在 Cargo.toml 里显式声明 —— '
              '靠 reqwest 的间接依赖是**碰运气**：'
              'reqwest 哪天不开 deflate 特性，这里就编译不过。');
    });

    test('③ 回退必须只在 deflate 响应上触发（不许影响正常响应）', () {
      // 必须检查 content-encoding 是否含 deflate
      expect(
        code.contains('content_encoding') || code.contains('CONTENT_ENCODING'),
        isTrue,
        reason: '★ 回退前必须检查 `Content-Encoding` 是否含 deflate —— '
            '否则一个 gzip 响应的解码失败也会走 raw-deflate，'
            '把正常错误掩盖成乱码。',
      );
      expect(code.contains('contains("deflate")'), isTrue,
          reason: '★ 判据必须是"含 deflate"（允许 `deflate, gzip` 这种组合）');
    });

    test('④ 回退必须保留 HTTP 状态前缀（否则插件读不到 401/404）', () {
      // 在 try_raw_deflate_fallback 函数体内找 __ERR__HTTP
      final fnIdx = code.indexOf('async fn try_raw_deflate_fallback');
      expect(fnIdx, greaterThan(0));
      final fnBody = code.substring(fnIdx, (fnIdx + 3000).clamp(0, code.length));
      expect(fnBody.contains('__ERR__HTTP'), isTrue,
          reason: '★ 回退路径也必须带 `__ERR__HTTP {status}:` 前缀 —— '
              '插件的 getJson 靠这个前缀判断 401/404 并抛对应错误。'
              '漏了它，非 2xx 的 deflate 响应会被当成成功数据。');
    });

    test('⑤ 正常路径不许被改动（`r.text()` 仍是首选）', () {
      expect(code.contains('.text().await'), isTrue,
          reason: '★ 正常路径仍走 `r.text()`（reqwest 自动解压）—— '
              '回退只在前者失败时才走，正常站零影响');
    });

    test('⑥ ★★ 必须有 Rust 侧的真实解码单测（防"只断言代码存在"的假绿）', () {
      expect(raw.contains('raw_deflate'), isTrue,
          reason: '★ 必须在 mod.rs 的 #[cfg(test)] 里有真实解码测试 —— '
              '只断言"Dart 侧看到源码里有 DeflateDecoder"是**深度太浅**的假绿：'
              '代码在但解不出来，断言照样绿。'
              '真实测试要造 raw-deflate 字节流并解回原文。');
    });

    /*
     * ★★★ ⑦ 是补上的：故障注入发现 ①~⑥ **全都没抓到**
     *
     * ```text
     * 注入"删掉 try_raw_deflate_fallback 的调用点、只留函数定义"
     * ⇒ +6 全绿 —— 因为 ① 断言的是"函数存在"，而它确实还在！
     * ⇒ 这是**"深度太浅"**的典型：只查"有没有这个函数"，
     *   不查"有没有人调用它"。
     *
     * 一个永远不会被调用的回退函数，等于没有回退。
     * ```
     */
    test('⑦ ★★★ 回退函数必须被**真正调用**（不只是定义存在）', () {
      final defIdx = code.indexOf('async fn try_raw_deflate_fallback');
      expect(defIdx, greaterThan(0), reason: '回退函数定义不存在');

      // 在函数定义**之外**出现调用点 —— 排除定义行本身
      final before = code.substring(0, defIdx);
      final after = code.substring(defIdx + 1);
      final called = before.contains('try_raw_deflate_fallback(') ||
          after.contains('try_raw_deflate_fallback(');
      expect(called, isTrue,
          reason: '★★ 回退函数被定义了但**从未被调用** —— '
              '那等于没有回退。这个断言是故障注入逼出来的：'
              '删掉调用点后，前面 6 条断言全部仍然绿。');

      // 而且必须在 `r.text()` 失败的 Err 分支里调
      final errBranch = RegExp(r'Err\(e\)\s*=>\s*\{[^}]*try_raw_deflate_fallback',
              dotAll: true)
          .hasMatch(code);
      expect(errBranch, isTrue,
          reason: '★ 调用点必须在 `r.text()` 的 **Err 分支**里 —— '
              '放到别处（比如成功后）逻辑就反了');
    });
  });
}
