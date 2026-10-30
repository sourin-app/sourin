// ═══════════════════════════════════════════════════════════════════════
//  task-3 门禁：中文 IME 组合期**行为级**证据（非源码级断言）
// ═══════════════════════════════════════════════════════════════════════
//
// 为什么需要这一层（计划 .probe/plan-2026-10-30-field-feedback-batch.md 任务 3）：
//
// `test/ime_field_gate_test.dart` 是**源码级**断言（"源码里没有 maxLength"）。
// 它证明"我们没写 maxLength"，但证明不了"没写 maxLength 之后，IME 组合态真的不丢字"。
// 本文件补上后者：用真实 TextField + 真实 TextInput 通道驱动 IME 组合态，
// 断言 40/80/120 字的组合文本**完整保留**。
//
// # 缺陷机理实测（本文件组②固化，2026-10-30 实测读数）
//
// ```text
// 无 maxLength：  80 字组合态 => 完整保留（characters=78）        full=true
// maxLength: 60： 80 字组合态 => 被截到 60（characters=60）        full=false  ← 组合中被削断
// ```
// ⇒ Flutter 的 `maxLength`（LengthLimitingTextInputFormatter）**对 composing 区间同样计数并截断**，
//   拼音/候选还没上屏合成就被削短，组合被打断 ⇒ Owner 现场看到的"中文输入失效"。
//   这正是 task-3 把 maxLength 换成**提交时**截断（`clampNoteTo60`）的原因。
//
// # 门禁纪律（禁止假绿）
//
// 组②本身就是"缺陷形态对照"：它在**同一门禁里**驱动 `maxLength: 60` 的形态并断言
// "截断确实发生"。若哪天有人把 maxLength 加回生产代码，组①的 `full` 断言必然红
// （因为组②已证明该形态会截断）。两组合起来 = 判据真的能区分好坏形态，不是恒绿。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/settings/tvbox_aggregate_page.dart'
    show clampNoteTo60;

/// 40 字（中文字形簇计数，断言一律用 characters 而非 length）
const String forty = '中文输入法连续输入测试用于验证备注框与搜索框在长文本下不失效不截断一次三';

/// 80 字（超过 60 上限，用于触发截断形态）
const String eighty = '中文输入法连续输入测试用于验证备注框与搜索框在长文本下不失效不截断一次三十字以上的连续输入测试文本再加一些字凑够八十个字符总量用于验证组合态超限时的行为表现';

/// 120 字（远超上限，长连打）
const String oneTwenty = '$eighty$forty';

/// 驱动真实 TextField 的 IME 组合态更新。
Future<TextEditingController> _driveComposing(
  WidgetTester tester,
  String text, {
  int? maxLength,
}) async {
  final ctrl = TextEditingController();
  addTearDown(ctrl.dispose);
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: TextField(
        key: const ValueKey<String>('ime-field'),
        controller: ctrl,
        maxLength: maxLength,
      ),
    ),
  ));
  await tester.tap(find.byKey(const ValueKey<String>('ime-field')));
  await tester.pump();
  // IME 组合态：全文落在 composing 区间（拼音上屏前的那一刻）
  tester.testTextInput.updateEditingValue(TextEditingValue(
    text: text,
    selection: TextSelection.collapsed(offset: text.length),
    composing: TextRange(start: 0, end: text.length),
  ));
  await tester.pump();
  return ctrl;
}

void main() {
  group('③task-3 IME 组合期行为门禁（生产形态）', () {
    testWidgets('40 字组合态：完整保留、composing 区间在、不被打断', (tester) async {
      final ctrl = await _driveComposing(tester, forty);
      expect(ctrl.text, equals(forty), reason: '40 字组合文本必须逐字保留');
      expect(ctrl.value.composing.isValid, isTrue, reason: '组合态必须仍然有效（未被清空/打断）');
    });

    testWidgets('80 字组合态（超 60 上限）：完整保留 —— 无 maxLength 的关键证据', (tester) async {
      final ctrl = await _driveComposing(tester, eighty);
      expect(ctrl.text.characters.length, equals(eighty.characters.length),
          reason: '无 maxLength 时组合态不该被截断；截断即 Owner 反馈的"中文输入失效"');
      expect(ctrl.text, equals(eighty));
      expect(ctrl.value.composing.isValid, isTrue);
    });

    testWidgets('120 字组合态（长连打）：完整保留', (tester) async {
      final ctrl = await _driveComposing(tester, oneTwenty);
      expect(ctrl.text, equals(oneTwenty));
      expect(ctrl.value.composing.isValid, isTrue);
    });

    testWidgets('组合中逐段追加（40 → 80 → 120）不丢前文', (tester) async {
      final ctrl = TextEditingController();
      addTearDown(ctrl.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TextField(
            key: const ValueKey<String>('ime-field'),
            controller: ctrl,
          ),
        ),
      ));
      await tester.tap(find.byKey(const ValueKey<String>('ime-field')));
      await tester.pump();
      for (final s in <String>[forty, eighty, oneTwenty]) {
        tester.testTextInput.updateEditingValue(TextEditingValue(
          text: s,
          selection: TextSelection.collapsed(offset: s.length),
          composing: TextRange(start: 0, end: s.length),
        ));
        await tester.pump();
        expect(ctrl.text, equals(s), reason: '追加到 ${s.characters.length} 字时前文不许丢');
      }
    });
  });

  group('③task-3 缺陷形态对照（证明判据真能区分好坏）', () {
    testWidgets('maxLength: 60 时 80 字组合态被截断 —— 组①断言的判据在此形态下必红', (tester) async {
      final ctrl = await _driveComposing(tester, eighty, maxLength: 60);
      // 缺陷形态：组合中被削到 60 ⇒ 若生产代码把 maxLength 加回，组①的 equals(eighty) 必然失败。
      expect(ctrl.text.characters.length, equals(60),
          reason: '实测读数（2026-10-30）：maxLength=60 会把 80 字组合态截到 60；'
              '这条断言是组①判据的有效性证明');
      expect(ctrl.text, isNot(equals(eighty)));
    });

    testWidgets('maxLength: 60 时 40 字组合态不截断（未超限）—— 说明缺陷只在长文本触发', (tester) async {
      final ctrl = await _driveComposing(tester, forty, maxLength: 60);
      expect(ctrl.text, equals(forty));
    });
  });

  group('③clampNoteTo60（提交时截断，替代 maxLength）', () {
    test('不超过 60 字形簇：原样（仅 trim）', () {
      final s = '  $forty  ';
      expect(clampNoteTo60(s), equals(forty));
    });

    test('超过 60 字形簇：截到 60', () {
      final out = clampNoteTo60(eighty);
      expect(out.characters.length, equals(60));
      expect(eighty.startsWith(out), isTrue, reason: '必须是前缀截断，不许中间挖字');
    });

    test('emoji / 组合字符不被截出半个（字形簇边界）', () {
      final s = '🎬' * 70; // 70 个 emoji（每个是代理对 + 变体选择符族）
      final out = clampNoteTo60(s);
      expect(out.characters.length, lessThanOrEqualTo(60));
      // 不许出现半个代理对：重新编码后仍是合法 UTF-16
      expect(out.runes.every((r) => r != 0xFFFD), isTrue);
      expect(out.characters.every((c) => c.isNotEmpty), isTrue);
    });

    test('空串与纯空白：返回空串', () {
      expect(clampNoteTo60(''), equals(''));
      expect(clampNoteTo60('     '), equals(''));
    });
  });
}
