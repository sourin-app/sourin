// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R3 文案门禁：**不许指向不存在的控件**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条修的是什么（Lead 2026-10-20 裁决「问题 1」）
// ```text
// `_errorSection` 在 401/403 时给用户一段"可行的几步"：
//   改前：'…或在上面的「凭证」节填一对 AppId / AppSecret 并保存，再点「重新获取弹幕」。'
//
// 而「凭证」那一节 `_credentialsSection` **是死代码**：
//   · 全文件只有定义 + 注释提及，**零调用点**
//   · 注释自己写着「保留但不调用」
//   · 全仓 UI 层**没有任何地方**调 `setAppId` / `setAppSecret`
// ⇒ 用户照着这句话去找，**找不到**；整个客户端无处可填。
// ```
//
// # 裁决：只删那半句，**不恢复**凭证入口
// ```text
// 恢复 `_credentialsSection` 是功能改动（要把 setAppId/setAppSecret 接回 UI），
// 而它当初被摘掉是有原因的。现在恢复 = 重开一个已被有意关掉的入口
// ⇒ 那是产品决策，不是文案修复。
// ```
//
// # 本门禁钉什么
// ```text
// ① 那句 remedy 里**不出现「凭证」二字**
//    （依据：全仓 UI 无处可填凭证 ⇒ 提它就是指向不存在的东西）
// ② 保留下来的两条路径**仍在**（不许为了删一句把有用的也删了）
// ③ ★ 结构性判据：`_credentialsSection` 若仍零调用点，
//    则任何用户可见文案都不许让用户"去填凭证"
//    ⇒ 一旦将来真的把凭证入口接回来（它有了调用点），本组会自动放宽 ——
//      这是**设计内的**：那时文案可以再提它。
// ```
//
// # 故障注入（已实测）
// ```text
// 把「或在上面的「凭证」节…」加回去 ⇒ ① 组红
// 把「改用本机外部弹幕」也删掉       ⇒ ② 组红（删过头）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥注释（字符串里的 `//` 不算）
String _strip(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    } else {
      out.write(c);
    }
    i++;
  }
  return out.toString();
}

const _dialogPath = 'lib/ui/widgets/danmaku_settings_dialog.dart';

/// 那段「这是凭证问题」的 remedy 全文（从第一个引号到最后一个）
String authRemedyText() {
  final s = _strip(File(_dialogPath).readAsStringSync());
  final anchor = s.indexOf('这是凭证问题');
  expect(anchor, greaterThanOrEqualTo(0),
      reason: '找不到「这是凭证问题」这段 remedy —— 判据失效（它被改名/删了？）');
  // 往前找到开引号
  var start = anchor;
  while (start > 0 && s[start] != "'") {
    start--;
  }
  // 往后找到该字符串字面量链结束（最后一个闭引号后不是相邻的 '）
  var i = anchor;
  var lastQuote = anchor;
  while (i < s.length) {
    if (s[i] == "'") {
      lastQuote = i;
      // 看看后面紧接的是不是 `'`（相邻字面量拼接）
      var j = i + 1;
      while (j < s.length && (s[j] == '\n' || s[j] == ' ')) {
        j++;
      }
      if (j < s.length && s[j] == "'") {
        i = j + 1;
        continue;
      }
      break;
    }
    i++;
  }
  return s.substring(start, lastQuote + 1);
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  ① 不许提「凭证」
  // ═══════════════════════════════════════════════════════════════════
  group('① 401/403 的可行步骤里不许指向不存在的「凭证」节', () {
    test('★★★ `_credentialsSection` 仍是零调用点（判据的前提）', () {
      /*
       * 这条是**前提检查**：如果它已经有调用点了（有人把入口接回来了），
       * 那么下面的"不许提凭证"就失去依据 —— 那时应该放宽本组。
       * ⇒ 先断言前提，前提变了会立刻红，提醒复核。
       */
      final s = _strip(File(_dialogPath).readAsStringSync());
      final defs = RegExp(r'Widget _credentialsSection\(\)').allMatches(s).length;
      final calls = RegExp(r'_credentialsSection\s*\(\)')
          .allMatches(s)
          .length;
      expect(defs, 1, reason: '定义应该恰好一处');
      // 调用 = 总出现次数 - 定义那次
      final callCount = calls - 1;
      expect(callCount, 0,
          reason: '★★★ `_credentialsSection` 现在有 $callCount 个调用点 —— '
              '前提变了：若真的把凭证入口接回来了，本组「不许提凭证」应放宽，'
              '请复核后同步改文案与断言');
    });

    test('★★★ remedy 里**不许把「凭证」当作一个可去的地方**', () {
      final text = authRemedyText();
      /*
       * # 为什么不能简单断言"不含「凭证」二字"
       * ```text
       * 文案开头是「这是**凭证**问题」—— 那是**诊断结论**（说这是什么病），
       * 它不指向任何控件，是必要的、正确的。
       *
       * 要禁的是**把它当作可去之处**：
       *   「在上面的「凭证」节填…」「去凭证页…」「到凭证里…」
       * ⇒ 判据 = 出现「凭证」时，**不许**与"节/页/栏/里/中/上面"这类
       *    **位置词**相邻，也不许与"填/保存"这类**动作词**直接搭配。
       * ```
       */
      // ① 不许出现「凭证」节 / 凭证页 / 凭证栏 这类**位置指代**
      for (final bad in <String>[
        '「凭证」节',
        '凭证节',
        '凭证页',
        '凭证栏',
        '上面的凭证',
        '上面的「凭证」',
      ]) {
        expect(text.contains(bad), isFalse,
            reason: '★★★ 文案把「凭证」当作**可去的地方**（命中「$bad」），'
                '但那一节零调用点、全仓 UI 无处填 AppId。\n实际文案：$text');
      }
      // ② 不许出现"填一对 AppId"这类**指向不存在控件**的动作
      expect(
        RegExp(r'填.{0,6}AppId').hasMatch(text),
        isFalse,
        reason: '★★★ 文案让用户"填 AppId"，但全仓 UI 没有任何地方能填。\n'
            '实际文案：$text',
      );
      // ③ 反证：确认取到的确实是那段文案（不是空串假绿）
      expect(text.contains('这是凭证问题'), isTrue,
          reason: '★ 切片必须包含开头 —— 否则上面几条是假绿\n实际切片：$text');
    });

    test('★★ 保留的两条路径必须还在（不许删过头）', () {
      final text = authRemedyText();
      // ① 改用本机外部弹幕 / 外部视频源弹幕（免签名，不需要 AppId）
      expect(text.contains('本机外部弹幕') || text.contains('外部视频源弹幕'), isTrue,
          reason: '★★ 删掉凭证那半句时，不许把这条**真实可用**的路径一起删掉');
      // ② 「重新获取弹幕」按钮（在「请求」节，可达）
      expect(text.contains('重新获取弹幕'), isTrue,
          reason: '★★ 这条也是可达的，必须保留');
    });

    test('★★ 文案仍以「这是凭证问题」开头（诊断结论不能丢）', () {
      final text = authRemedyText();
      expect(text.contains('这是凭证问题'), isTrue,
          reason: '★ 删的是"去哪儿填"，不是"这是什么问题" —— 结论要留着');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 同类排查：全仓 UI 还有没有别的"让用户去填凭证"
  // ═══════════════════════════════════════════════════════════════════
  group('② 全仓 UI：既然无处填凭证，就不该有文案让用户去填', () {
    test('★★★ `setAppId` / `setAppSecret` 在 UI 层仍然零调用', () {
      /*
       * 这是上面所有判断的**根依据**：
       * 用户根本没有任何入口能填 AppId ⇒ 任何"去填"的指引都指向空。
       * 若将来这里出现了调用点 ⇒ 说明入口接回来了，本门禁应同步放宽。
       */
      final uiDir = Directory('lib/ui');
      final offenders = <String>[];
      for (final f in uiDir.listSync(recursive: true)) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final src = _strip(f.readAsStringSync());
        for (final m in RegExp(r'\bset(AppId|AppSecret)\s*\(').allMatches(src)) {
          offenders.add('${f.path}: ${m.group(0)}');
        }
      }
      expect(offenders, isEmpty,
          reason: '★★★ UI 层出现了 setAppId/setAppSecret 调用：\n'
              '${offenders.join("\n")}\n'
              '⇒ 前提变了（凭证入口被接回来了）—— 请复核文案门禁是否该放宽');
    });
  });
}
