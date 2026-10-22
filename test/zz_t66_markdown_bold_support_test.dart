// ═══════════════════════════════════════════════════════════════════════
//  `_support/markdown_bold.dart` 的自检（含**阳性对照**）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么这个文件必须存在
//
// 批末自审（`r3-dns`）查出仓库里有**两种**「是不是 markdown 粗体」的判别式，
// 且在真实脱敏掩码上**结论相反**。若有人拿朴素那版去扫 `danmaku.dart`，
// 门禁会要求把掩码改成「」，等于**明文暴露打码后的 AppId**。
//
// ⇒ 本文件把「唯一实现」钉住：
//   ① 掩码必须判为 **false**
//   ② 真粗体必须判为 **true**（★ 阳性对照，否则判据可能是恒 false）
//   ③ 两者**结论必须不同** —— 这是判据有没有分辨力的直接证明

import 'package:flutter_test/flutter_test.dart';

import '_support/markdown_bold.dart';

void main() {
  group('① 脱敏掩码必须**不**被判成 markdown 粗体', () {
    test('三处真实掩码逐个判 false', () {
      for (final mask in kRedactionMaskSamples) {
        expect(
          isMarkdownBoldLiteral(mask),
          isFalse,
          reason: '★★★ 「$mask」是**脱敏掩码**，不是 markdown 粗体。\n'
              '若这里变 true ⇒ 判据退化成了朴素 contains("**") ⇒\n'
              '任何拿它扫 danmaku.dart 的门禁都会**要求改掉掩码** ⇒\n'
              '把打码后的 AppId / 真实域名明文暴露给用户。',
        );
      }
    });

    test('源码扫描：掩码那三行一个都不许进结果', () {
      const src = """
  if (id.length <= 4) return '****';
  return '\${id.substring(0, 4)}****';
  return u.replace(pathSegments: <String>['***', ...segs.skip(1)]).toString();
""";
      final hits = markdownBoldLiterals(src);
      expect(
        hits,
        isEmpty,
        reason: '★★ 这三行是 danmaku.dart:1431/1432/2223 的**原样**形态，'
            '扫描结果必须为空。实际：$hits',
      );
    });
  });

  group('② 阳性对照：真粗体必须被抓到（否则判据恒 false）', () {
    test('普通粗体', () {
      expect(isMarkdownBoldLiteral('这是**粗体**文字'), isTrue);
    });

    test('句首句尾都有文字', () {
      expect(isMarkdownBoldLiteral('**注意**：这样做会失败'), isTrue);
    });

    test('源码扫描能抓到', () {
      const src = "  text: '这是**粗体**文字',\n";
      expect(markdownBoldLiterals(src), hasLength(1));
    });
  });

  group('③ 分辨力：掩码与粗体的结论**必须不同**', () {
    test('同一批输入下两者结论不重合', () {
      final maskVerdicts = kRedactionMaskSamples.map(isMarkdownBoldLiteral);
      final boldVerdicts = <bool>[
        isMarkdownBoldLiteral('**粗体**'),
        isMarkdownBoldLiteral('前**粗体**后'),
      ];
      expect(
        maskVerdicts.every((v) => v == false),
        isTrue,
        reason: '掩码必须全 false',
      );
      expect(
        boldVerdicts.every((v) => v == true),
        isTrue,
        reason: '粗体必须全 true',
      );
      // ★ 若两边结论相同 ⇒ 判据没有分辨力（恒 false 或恒 true）
      expect(
        maskVerdicts.toSet().intersection(boldVerdicts.toSet()),
        isEmpty,
        reason: '★★★ 掩码与粗体的判定结果**不能重合** —— '
            '重合说明判据退化成恒值，那就等于没判。',
      );
    });
  });
}
