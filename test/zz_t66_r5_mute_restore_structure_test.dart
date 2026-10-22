// ═══════════════════════════════════════════════════════════════════════
//  R5（Owner 1009）· 直播页「再点一次静音图标要恢复声音」—— 结构门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话第三句（本文件的目标）
// ```text
// 「必须拖音量条才恢复」
// ⇒ 期望：再点一次静音图标，音量回到**静音前那个值**，不是 0、也不是写死的 100。
// ```
//
// # ⚠️ 为什么这里钉的是**结构**而不是「跑一遍听声音」
//
// ```text
// flutter_tester 里 `Player.setVolume()` **永不完成**，`p.state.volume` **恒 100.0**。
//   本轮（verify-34，2026-10-20 19:20）两次独立实测：
//     ① 挂真 LiveEmbeddedPlayer + await toggleMute() ⇒ 两条用例各撞 5 分钟超时；
//     ② 裸 Player（真 libmpv）+ `t.runAsync` 里 setVolume(37)/setVolume(0)
//        ⇒ 3 秒后 done=false，state.volume 仍然 100.0。
//   仓内既有门禁 `test/zz_t66_r5_live_mute_default_test.dart` 的文件头也记录了
//   同一结论（那里因此只钉 `muted` 标志，不钉音量真值）。
// ⇒ 「音量真的变成 37」在 flutter_tester **结构性不可判定**；
//   真音量属性归**真机**验证（判据见 `docs/notes/round-66-verify-34.md`）。
// ```
//
// → 本文件守**能自动判定的那一半**：`toggleMute()` 的实现必须
//   ① 走「快照 → 偏好 → 兜底」三级瀑布（顺序不能反）；
//   ② 取消静音**不得**写死常量下发；
//   ③ 先下发、后翻 `_muted`（下发失败时 UI 不许显示成功）；
//   ④ 静音分支先抓快照、再压 0；
//   ⑤ 快照用完即清（`_volumeBeforeMute = null`），否则第二次静音会用过期值。
//
// # 判据可测出反面（防空转）
//
// ```text
// `violationsIn()` 是纯函数，输入是 toggleMute 的函数体源码（已剥注释）。
// 自带 1 份 GOOD 样本 + 6 份各违反一条规则的 BAD 样本，
// 逐条断言「BAD 必须被点名、GOOD 必须干净」——规则自身坏掉会立刻变红。
// 真源码那几条最后跑，断言违规为空。
// ```
//
// 覆盖边界：本文件**不**覆盖运行时的音量真值（见上）；默认静音那一半由
// `test/zz_t66_r5_live_mute_default_test.dart` 覆盖，末尾有「覆盖边界」用例盯着它。
// ═══════════════════════════════════════════════════════════════════════

@TestOn('vm')
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 剥掉 `//` 行注释与 `/* */` 块注释（含 `///` 文档注释）
///
/// ★ 必须剥：本仓踩过多次「断言匹配到注释里的示例代码 ⇒ 假通过」。
String codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var depth = 0;
  var inLine = false;
  while (i < src.length) {
    final c = src[i];
    final n = i + 1 < src.length ? src[i + 1] : '';
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (depth > 0) {
      if (c == '/' && n == '*') {
        depth++;
        i += 2;
        continue;
      }
      if (c == '*' && n == '/') {
        depth--;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (c == '/' && n == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && n == '*') {
      depth++;
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 从整份源码里抠出 `toggleMute()` 的函数体（大括号配对，字符串内括号不计）
String? toggleMuteBody(String src) {
  final code = codeOnly(src);
  final m = RegExp(r'Future<void>\s+toggleMute\s*\(\s*\)\s*(?:async\s*)?\{')
      .firstMatch(code);
  if (m == null) return null;
  var i = m.end; // 指向 `{` 之后
  var depth = 1;
  final start = i;
  var inStr = false;
  var quote = '';
  var esc = false;
  while (i < code.length) {
    final c = code[i];
    if (inStr) {
      if (esc) {
        esc = false;
      } else if (c == r'\') {
        esc = true;
      } else if (c == quote) {
        inStr = false;
      }
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      inStr = true;
      quote = c;
      i++;
      continue;
    }
    if (c == '{') {
      depth++;
    } else if (c == '}') {
      depth--;
      if (depth == 0) return code.substring(start, i);
    }
    i++;
  }
  return null;
}

/// 取消静音分支（`if (_muted) {` 与 `} else {` 之间）
String unmuteBranch(String body) {
  final a = body.indexOf('if (_muted)');
  final b = body.indexOf('} else {', a < 0 ? 0 : a);
  if (a < 0 || b < 0) return '';
  return body.substring(a, b);
}

/// 静音分支（`} else {` 之后）
String muteBranch(String body) {
  final b = body.indexOf('} else {');
  if (b < 0) return '';
  return body.substring(b);
}

/// 五条规则；返回违反项代码（空 = 合规）。纯函数，便于自检。
List<String> violationsIn(String body) {
  final v = <String>[];
  final un = unmuteBranch(body);
  final mu = muteBranch(body);
  if (un.isEmpty) v.add('V0-找不到取消静音分支');
  if (mu.isEmpty) v.add('V0-找不到静音分支');

  final iSnapshot = un.indexOf('_volumeBeforeMute');
  final iPref = un.indexOf('dsh.playprefs.lastVolume');
  final iSet = un.indexOf('setVolume(');
  final iFlip = un.indexOf('setState(() => _muted = false)');
  final iClear = un.indexOf('_volumeBeforeMute = null');

  // ① 三级瀑布：快照 → 偏好
  if (iSnapshot < 0) v.add('V1-取消静音没用静音前快照');
  if (iPref < 0) v.add('V2-取消静音没读偏好音量');
  if (iSnapshot >= 0 && iPref >= 0 && iPref < iSnapshot) {
    v.add('V3-瀑布顺序反了（偏好先于快照）');
  }
  // ② 不许写死常量下发
  if (RegExp(r'setVolume\(\s*(?:100|0)\s*\)').hasMatch(un)) {
    v.add('V4-取消静音写死了常量音量');
  }
  // ③ 先下发、后翻状态
  if (iSet >= 0 && iFlip >= 0 && iFlip < iSet) {
    v.add('V5-先翻状态后下发（失败时会显示成功）');
  }
  if (iSet < 0) v.add('V5b-取消静音没有下发音量');
  if (iFlip < 0) v.add('V5c-取消静音没有把 _muted 翻回 false');
  // ④ 静音分支：先抓快照再压 0
  final iCur = mu.indexOf('p.state.volume');
  final iZero = mu.indexOf('setVolume(0)');
  if (iCur < 0 || iZero < 0 || iZero < iCur) {
    v.add('V6-静音分支没先抓快照就压 0');
  }
  // ⑤ 快照用完即清
  if (iClear < 0 || (iSet >= 0 && iClear > iSet)) {
    v.add('V7-快照没在下发前清空');
  }
  return v;
}

const String _goodFixture = '''
    if (_muted) {
    var restore = _volumeBeforeMute ?? 0;
    if (restore <= 0) {
      final v = double.tryParse(UiPrefs.get('dsh.playprefs.lastVolume') ?? '');
      restore = (v != null && v >= 0 && v <= 1) ? v * 100 : 100;
    }
    if (restore <= 0) restore = 100;
    _volumeBeforeMute = null;
    await p.setVolume(restore.clamp(1, 100));
    if (mounted) setState(() => _muted = false);
  } else {
    final cur = p.state.volume;
    if (cur > 0) _volumeBeforeMute = cur;
    await p.setVolume(0);
    if (mounted) setState(() => _muted = true);
  }
''';

void main() {
  final src =
      File('lib/ui/widgets/live_embedded_player.dart').readAsStringSync();
  final body = toggleMuteBody(src);

  group('⓪ 仪器自检（判据必须能测出反面）', () {
    test('GOOD 样本必须零违规', () {
      expect(violationsIn(_goodFixture), isEmpty,
          reason: '★ 自检：合规样本都不干净 ⇒ 规则写错了（过严）');
    });

    test('六条 BAD 样本必须逐条被点名', () {
      final cases = <String, String>{
        'V1-取消静音没用静音前快照': _goodFixture
            .replaceFirst('var restore = _volumeBeforeMute ?? 0;', 'var restore = 0.0;')
            .replaceFirst('_volumeBeforeMute = null;', ''),
        'V2-取消静音没读偏好音量': _goodFixture.replaceFirst(
            "UiPrefs.get('dsh.playprefs.lastVolume')", "UiPrefs.get('x')"),
        'V4-取消静音写死了常量音量': _goodFixture.replaceFirst(
            'setVolume(restore.clamp(1, 100))', 'setVolume(100)'),
        'V5-先翻状态后下发（失败时会显示成功）': _goodFixture
            .replaceFirst('await p.setVolume(restore.clamp(1, 100));', '')
            .replaceFirst('if (mounted) setState(() => _muted = false);',
                'if (mounted) setState(() => _muted = false);\n    await p.setVolume(restore);'),
        'V6-静音分支没先抓快照就压 0': _goodFixture.replaceFirst(
            'final cur = p.state.volume;\n    if (cur > 0) _volumeBeforeMute = cur;',
            ''),
        'V7-快照没在下发前清空':
            _goodFixture.replaceFirst('_volumeBeforeMute = null;', ''),
      };
      cases.forEach((code, fixture) {
        expect(violationsIn(fixture), contains(code),
            reason: '★ 自检：$code 这条规则没能点名对应的坏样本 ⇒ 该规则恒绿');
      });
    });

    test('提取器必须真的抠到函数体（防空转）', () {
      expect(body, isNotNull,
          reason: '★ 防空转：`Future<void> toggleMute()` 没找到 —— '
              '要么签名变了、要么提取器坏了。');
      expect(body!.length, greaterThan(300),
          reason: '★ 防空转：函数体太短，不像真实现');
      expect(body, contains('_volumeBeforeMute'));
      expect(body, contains('setVolume('));
    });
  });

  group('① 真实现：toggleMute 的五条结构约束', () {
    test('★ 取消静音走「快照 → 偏好 → 兜底 100」三级瀑布，且顺序不反', () {
      final un = unmuteBranch(body!);
      final iSnap = un.indexOf('_volumeBeforeMute');
      final iPref = un.indexOf('dsh.playprefs.lastVolume');
      final iFallback = un.indexOf('restore = 100');
      expect(iSnap, greaterThanOrEqualTo(0),
          reason: '★ 取消静音必须优先用**静音前快照**');
      expect(iPref, greaterThan(iSnap),
          reason: '★ 偏好只能是快照缺失时的第二级（顺序反了就永远用偏好）');
      expect(iFallback, greaterThan(iPref), reason: '★ 出厂 100 只能是最后兜底');
    });

    test('★ 取消静音**不得**下发写死的常量音量（Owner 的 bug 就是回到 100）', () {
      final un = unmuteBranch(body!);
      expect(RegExp(r'setVolume\(\s*(?:100|0)\s*\)').hasMatch(un), isFalse,
          reason: '★★ 取消静音把音量写死成 100/0 ⇒ 拖过音量条再静音、'
              '再点一次就被打回 100。');
      expect(un, contains('setVolume('), reason: '★ 取消静音必须真的下发音量');
    });

    test('★ 先下发、后翻 _muted（下发失败时 UI 不许显示成功）', () {
      final un = unmuteBranch(body!);
      final iSet = un.indexOf('setVolume(');
      final iFlip = un.indexOf('setState(() => _muted = false)');
      expect(iSet, greaterThanOrEqualTo(0));
      expect(iFlip, greaterThan(iSet),
          reason: '★★ 顺序反了：先翻状态再下发 ⇒ setVolume 抛异常时'
              '图标说「有声」而实际静音');
    });

    test('★ 静音分支先抓快照、再压 0', () {
      final mu = muteBranch(body!);
      final iCur = mu.indexOf('p.state.volume');
      final iZero = mu.indexOf('setVolume(0)');
      expect(iCur, greaterThanOrEqualTo(0), reason: '★ 压 0 之前必须先读当前音量');
      expect(iZero, greaterThan(iCur),
          reason: '★★ 顺序反了：先压 0 再读 ⇒ 快照永远是 0，取消静音必然回落兜底值');
    });

    test('★ 快照用完即清，且清在下发之前', () {
      final un = unmuteBranch(body!);
      final iClear = un.indexOf('_volumeBeforeMute = null');
      final iSet = un.indexOf('setVolume(');
      expect(iClear, greaterThanOrEqualTo(0),
          reason: '★ 用了快照却不清理 ⇒ 下次静音会拿过期值');
      expect(iClear, lessThan(iSet),
          reason: '★ 清理应在下发之前（下发抛异常也不会留下脏快照）');
    });

    test('★ 真实现的 violations 必须为空（汇总判据）', () {
      final v = violationsIn(body!);
      expect(v, isEmpty, reason: '★ toggleMute 结构违规：$v');
    });
  });

  group('② 覆盖边界（谁负责真音量属性）', () {
    test('★ 默认静音那一半的覆盖者必须仍然存在，且仍写明 setVolume 不可判定', () {
      final f = File('test/zz_t66_r5_live_mute_default_test.dart');
      expect(f.existsSync(), isTrue,
          reason: '★ 覆盖边界失效：默认静音的覆盖文件不见了');
      final t = f.readAsStringSync();
      expect(t, contains('默认静音'));
      expect(t, contains('setVolume'),
          reason: '★ 该文件应继续记录「setVolume 在 tester 里不完成」的依据');
      expect(
        File('lib/ui/widgets/live_embedded_player.dart')
            .readAsStringSync()
            .contains('clamp(1, 100)'),
        isTrue,
        reason: '★ 下发前必须 clamp(1, 100)：别把 0 下发出去'
            '（那就等于「静音却显示有声」）',
      );
    });
  });
}
