// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · **批末前全仓自审**（只读型门禁，不改任何产品代码）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这份门禁守什么
// ```text
// 本轮队友多、门禁多（未跟踪新增 26+），**没人做过"全仓静态一致性"检查**。
// ⇒ 这里钉住三件最容易悄悄坏掉的事：
//   ① 脱敏掩码**永远不许**被当成 markdown 改掉（判据分裂 = 逼人泄露 AppId）
//   ② 门禁之间对「同一事实」不能给出相反要求
//   ③ 未跟踪文件里不许混进本机路径/二进制产物
// ```
//
// # ★ 本轮实测出的**真问题**（不是假想）
// ```text
// 同一个问题「这段字面量是不是 markdown 粗体」，仓库里有**两种判别式**：
//   A（dan_asterisk_gate）：`**…**` 且 `…` 里有**非星号**字符 ⇒ 成对才算
//   B（md_gate / cs1_no_markdown_leak / data_manage_md_review /
//      playback_page_asterisk_gate）：朴素 `contains('**')`
//
// 实测三条脱敏掩码：
//   '****'                  A=false（是掩码）   B=true（被当成 markdown！）
//   '${id.substring(0,4)}****'  A=false        B=true
//   '***'                   A=false           B=true
//
// ⇒ 若有人拿 B 去扫 danmaku.dart，它会**要求**把掩码改成「」
//   ⇒ 那就是「为了让门禁变绿而泄露凭证」。本门禁把这条钉死。
// ```
//
// ⚠️ 判据纪律：每条都要能回答「**这个缺陷存在时，它凭什么会红**」。
//   （本会话已出四次恒真：R7 非递归扫描 / R8 不挂订阅的 getter /
//     R2 不可辨样本 / cs1 恒真断言。）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ★ 唯一实现（铁律 170）：判据必须落在**代码**上，不是原始文本上
import '_support/strip_comments.dart';

/// 取 [code] 里第一处含 [needle] 的那几行（用于失败信息，便于定位）
String _snippetAround(String code, String needle) {
  final i = code.indexOf(needle);
  if (i < 0) return '（剥注释后没有 `**`）';
  final start = i - 40 < 0 ? 0 : i - 40;
  final end = i + 120 > code.length ? code.length : i + 120;
  return code.substring(start, end).replaceAll('\n', ' ⏎ ');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 判别式 A：`**…**` 且中间有非星号字符（掩码的星号之间是空的 ⇒ 不算）
  bool isPairedBold(String lit) =>
      lit.contains('**') && RegExp(r'\*\*[^*]*[^*][^*]*\*\*').hasMatch(lit);

  /// 判别式 B：朴素 `contains('**')`（仓库里另四家在用）
  bool naiveHasAsterisk(String lit) => lit.contains('**');

  group('① 脱敏掩码：判据必须能把它与 markdown 区分开', () {
    // ★ 注意：这三串是**掩码的字面内容**，不是要在测试里复现的 Dart 表达式
    final masks = <String>[
      '****', // maskedAppId，id ≤ 4
      '***', // _safeUri 的 token 掩码
      r'${id.substring(0,4)}****', // maskedAppId，带前缀（★ 掩码里也含 ${}）
    ];

    test('★★★ 三条掩码在判据 A 下**不是** markdown 粗体', () {
      for (final m in masks) {
        expect(isPairedBold(m), isFalse,
            reason: '★★★ "$m" 是**脱敏掩码**（maskedAppId / _safeUri）。'
                '若它被判成 markdown 粗体 ⇒ 会有人"顺手改成「」" '
                '⇒ 那就是**把打码后的 AppId 明文暴露给用户**。');
      }
    });

    test('★★★ ★ 而朴素判据 B 会误伤它们 —— 这就是两家门禁的分歧点', () {
      // 本条**断言分歧存在**，不是断言"B 是错的"。
      // 目的是：将来有人把 B 推广到 danmaku.dart 时，这条会提醒他去看 ①。
      final fooled = masks.where(naiveHasAsterisk).toList();
      expect(fooled, isNotEmpty,
          reason: '★★★ 朴素 contains 会把掩码误判 ⇒ 这就是分歧本身。');
    });

    test('★★ 真 markdown 粗体在**两条**判据下都成立（别把 A 写得过严）', () {
      const real = <String>[
        '限制**同时进行**的片段下载任务数',
        '这些源把**账号密码明文**存在本机：',
        '⚠️ 这些源把**账号密码明文**存在本机：',
      ];
      for (final r in real) {
        expect(isPairedBold(r), isTrue, reason: '★ "$r" 是真的 markdown 粗体，A 必须抓到');
        expect(naiveHasAsterisk(r), isTrue, reason: '★ B 也抓到（两者在此一致）');
      }
    });

    test('★★ 仓库里现存的 danmaku.dart 掩码**逐字未被动过**', () {
      // 实测基线（danmaku.dart:1431 / 1432 / 2223）
      final src = File('lib/core/danmaku.dart').readAsStringSync();
      expect(src.contains("return '****';"), isTrue,
          reason: '★★ maskedAppId 的短 id 掩码必须原样存在');
      expect(src.contains(r"'${id.substring(0, 4)}****'"), isTrue,
          reason: '★★ maskedAppId 的长 id 掩码');
      expect(src.contains("'***'"), isTrue,
          reason: '★★ _safeUri 的 token 掩码');
    });
  });

  group('② 门禁之间不得对同一事实给出相反要求', () {
    test('★★★ 「剥掉 `**`」类门禁必须在文件里写明掩码红线', () {
      // md_gate 刻意不扫 danmaku.dart 并写下红线（:22-25）。这是正确做法。
      final md = File('test/zz_t66_md_gate_test.dart').readAsStringSync();
      expect(md.contains('脱敏掩码不在范围内'), isTrue,
          reason: '★★★ 若这句被删，后人会扩大扫描范围 ⇒ 直接打到掩码。'
              '这条就是「防止红线被悄悄删掉」的守卫。');
      expect(md.contains('danmaku.dart'), isTrue);
    });

    test('★★ dan_asterisk_gate 必须同时具备「成对判据」与「掩码保留」两条断言', () {
      final src =
          File('test/zz_t66_dan_asterisk_gate_test.dart').readAsStringSync();
      // ★★ 2026-10-19（Lead 修）：判据锚点从「dan_asterisk_gate 文件里有那条正则」
      //   改成「**唯一实现**里有那条正则，且 dan_asterisk_gate **调用**它」。
      //
      // ```text
      // 改前：要求那个文件里出现字面量 r'\*\*[^*]*[^*][^*]*\*\*'
      //   ⇒ 本轮把判据抽到 test/_support/markdown_bold.dart（铁律 170）之后，
      //     这个字面量**不在那儿了** ⇒ 门禁红。
      //   ⇒ 红的原因不是缺陷，是**判据锚在了会漂移的位置**。
      // 改后：锚在唯一实现上（它才是「判别式在哪」的权威），
      //   并额外断言 dan_asterisk_gate **确实调用**它（防止"实现了但没接线"）。
      // ```
      final impl = File('test/_support/markdown_bold.dart').readAsStringSync();
      // ★★ 2026-10-19（复核抓出，Lead 修）：**剥掉注释再判**。
      //
      // ```text
      // 改前：impl.contains(精确正则) —— 读的是**原始文本**
      //   ⇒ 只要文件里**任何地方**（包括注释）留着那条字面量就绿
      //   ⇒ 实测：把 3 处**代码**降级成 `\*\*.*?\*\*`、
      //     保留第 60 行注释里的原样 ⇒ 本条**仍然绿**，而判别力已坏
      //     （`****`、`${id.substring(0,4)}****` 都被误判成粗体）
      // ```
      //
      // ⇒ 判据必须落在**代码**上。这是本仓第三次「锚点匹配到注释」
      //   （前两次：`MaterialApp(`、`child: _loading`）。
      final implCode = stripComments(impl);
      expect(implCode.contains(r'\*\*[^*]*[^*][^*]*\*\*'), isTrue,
          reason: '★★ 唯一实现的**代码**里必须有那条精确正则 —— '
              '它是「掩码不会被误伤」的权威。\n'
              '⚠️ 判的是剥注释后的代码：若连注释一起判，'
              '把代码降级成通配正则而留着注释里的原样也会绿。\n'
              '实测那条代码片段：\n${_snippetAround(implCode, r'\*\*')}');
      expect(impl.contains('INJECT'), isFalse,
          reason: '★ 注入残留检查：上一次注入实验的标记不许留在实现里');
      expect(src.contains('markdown_bold'), isTrue,
          reason: '★★ dan_asterisk_gate 必须**调用**唯一实现（铁律 170）；\n'
              '若它自己另抄一份正则，两份会漂开 ⇒ '
              '其中一个开始要求把脱敏掩码改成「」。');
      expect(src.contains('脱敏掩码'), isTrue,
          reason: '★★ 掩码红线的断言必须在');
    });
  });

  group('③ 未跟踪文件：隐私与产物', () {
    test('★★★ 本轮新增门禁里不许出现本机绝对路径', () {
      // ★ 判据串**拼接**出来，而不是直接写在本文件里 ——
      //   否则这条门禁会**把自己判成违规**（自指假红，本会话已踩过多次）。
      final markers = <String>[
        'iuuuuuuu' + 'u', // 本机用户名
        'D:' + r'\WishProject', // 本仓绝对路径
        'C:' + r'\Users',
      ];
      final offenders = <String>[];
      for (final f in Directory('test').listSync()) {
        if (f is! File || !f.path.endsWith('.dart')) continue;
        final base = f.path.split(RegExp(r'[/\\]')).last;
        if (!base.contains('zz_t66')) continue;
        // ★ 跳过本文件自己（它按构造就含这些判据串）
        if (base.contains('selfaudit')) continue;
        final s = f.readAsStringSync();
        if (markers.any(s.contains)) offenders.add(base);
      }
      expect(offenders, isEmpty,
          reason: '★★★ 这些新门禁里写了本机绝对路径 ⇒ 提交前必须清理：$offenders');
    });

    test('★★ 新增门禁不得是二进制产物（exe/dll/png 混进 test/）', () {
      final bad = <String>[];
      for (final f in Directory('test').listSync()) {
        if (f is! File) continue;
        final p = f.path.toLowerCase();
        if (p.endsWith('.exe') || p.endsWith('.dll') || p.endsWith('.png')) {
          bad.add(f.path);
        }
      }
      expect(bad, isEmpty, reason: '★★ test/ 里混进了产物：$bad');
    });
  });

  group('④ 自检：这条门禁自己不是恒真', () {
    test('★★★ 判据 A 对真 markdown 与掩码给出**不同**结论（否则 A 写废了）', () {
      expect(isPairedBold('限制**同时进行**的片段'), isTrue,
          reason: '★ 对照 1：真 markdown ⇒ true');
      expect(isPairedBold('****'), isFalse,
          reason: '★ 对照 2：掩码 ⇒ false。两者不同 ⇒ 判据有分辨力。');
    });

    test('★★★ 读得到真实文件（防空转）', () {
      expect(File('lib/core/danmaku.dart').readAsStringSync().length,
          greaterThan(1000));
      expect(File('test/zz_t66_md_gate_test.dart').readAsStringSync().length,
          greaterThan(500));
      expect(File('test/zz_t66_dan_asterisk_gate_test.dart')
          .readAsStringSync().length, greaterThan(500));
    });
  });
}
