// ═══════════════════════════════════════════════════════════════════════
//  task-3 门禁：中文 IME 不被输入框打断（源码级）
// ═══════════════════════════════════════════════════════════════════════
//
// 背景（Owner 现场反馈，计划 .probe/plan-2026-10-30-field-feedback-batch.md 任务 3）：
// Windows 桌面端连续输入中文会"失效"。两条线索都在**代码里可证伪**，故做源码级门禁：
//
//   线索一（备注框）：`maxLength: 60` 在 Windows 上参与 IME 组合期截断 ——
//     Flutter 的 maxLength 由 LengthLimitingTextInputFormatter 实现，它对
//     **组合中（composing）**的文本同样计数/截断，拼音还没上屏就被削断，
//     组合被打断 ⇒ 输入"失效"。修法：去 maxLength，限长移到**提交时**
//     （Rust 侧 tvbox_aggregate.rs:264 本来就用 chars().take(60) 截）。
//
//   线索二（搜索框）：排查 inputFormatters（全 lib 为 0 处，排除）、
//     controller 重建（`final _controller` 单实例，排除）、父级 setState ——
//     **真嫌疑**：`onChanged: (_) => setState(() {})` 让 IME 组合期的每一次
//     组合更新都触发**全页** setState，连带 SliverPersistentHeaderDelegate
//     （shouldRebuild 因 child 恒为新实例而为 true）每帧重建。
//     修法：只在「文本是否为空」**翻转**时 setState（清空按钮的可见性、
//     搜索按钮的可用性只依赖这一点）。
//
// 门禁纪律（禁止假绿）：
//   ① 先在**改动前**的源码上跑本文件 ⇒ 必须红（maxLength 在、onChanged 无条件
//      setState 在、clampNoteTo60 缺失）—— 修好后转绿；
//   ② 绿之后**反向注入**（把 maxLength 加回 / 把 setState 放开）⇒ 必须再红
//      （证据记录在决策笔记），证明门禁不是恒绿。
//
// 断言只对**剥注释后**的代码做（本仓铁律 170：必须用 _support/strip_comments.dart，
// 不许自抄一份）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '_support/strip_comments.dart';

void main() {
  group('task-3 中文 IME 源码门禁', () {
    late final String aggCode;
    late final String searchCode;

    setUpAll(() {
      aggCode = stripComments(
        File('lib/ui/settings/tvbox_aggregate_page.dart').readAsStringSync(),
      );
      searchCode = stripComments(
        File('lib/ui/search_page.dart').readAsStringSync(),
      );
    });

    // ── 线索一：备注框 ──────────────────────────────────────────────

    test('备注框（agg-note-input）不带 maxLength', () {
      expect(
        aggCode.contains('maxLength:'),
        isFalse,
        reason:
            'maxLength 在 Windows 上参与 IME 组合期截断（拼音未上屏就被削断），'
            '会打断中文输入。限长必须移到提交时（Rust 侧已截 60）。',
      );
    });

    test('备注框限长在提交时做：clampNoteTo60 必须存在且被 _save 调用', () {
      expect(
        aggCode.contains('clampNoteTo60'),
        isTrue,
        reason: '去掉 maxLength 后，备注限长必须落在提交路径（_save）里，'
            '否则卡片一行放不下的约束就丢了。',
      );
      // _save 的提交参数必须经过 clampNoteTo60（不是直接 _note.text.trim()）
      expect(
        RegExp(r'tvboxAggregateSet\(\s*note:\s*clampNoteTo60\(')
            .hasMatch(aggCode),
        isTrue,
        reason: 'tvboxAggregateSet 的 note 参数必须经 clampNoteTo60 截断后再发。',
      );
    });

    // ── 线索二：搜索框 ──────────────────────────────────────────────

    test('搜索框不带 maxLength，也没有任何 inputFormatters', () {
      expect(searchCode.contains('maxLength:'), isFalse);
      expect(searchCode.contains('inputFormatters'), isFalse);
    });

    test('搜索框 controller 单实例（不得在 build 里重建）', () {
      // build 内每次 new TextEditingController 是丢 IME 组合态的另一个经典成因；
      // 这里锁死"字段级 final、只此一处构造"。
      final news = RegExp('TextEditingController\\(').allMatches(searchCode);
      expect(
        news,
        hasLength(1),
        reason: '搜索页只允许一处 TextEditingController 构造（State 字段级单实例）。',
      );
      expect(
        searchCode.contains('final _controller = TextEditingController();'),
        isTrue,
      );
    });

    test('搜索框 onChanged 不得无条件全页 setState', () {
      final unconditional = RegExp(
        r'onChanged:\s*\([^)]*\)\s*=>\s*setState',
      );
      expect(
        unconditional.hasMatch(searchCode),
        isFalse,
        reason: 'IME 组合期每个组合更新都会触发 onChanged；无条件全页 setState '
            '连带 SliverPersistentHeaderDelegate 每帧重建。'
            '必须只在「文本是否为空」翻转时重建（_onSearchChanged）。',
      );
      expect(
        searchCode.contains('_onSearchChanged'),
        isTrue,
        reason: '组合期重建闸门必须存在且被 onChanged 引用。',
      );
      expect(
        searchCode.contains('void _onSearchChanged()'),
        isTrue,
        reason: '闸门是 State 方法（不是内联 lambda），保证可被门禁按名定位。',
      );
    });
  });
}
