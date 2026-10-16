// ═══════════════════════════════════════════════════════════════════════
//  首页空态文案 —— 必须**分情况**（2026-10-15，Owner 报的真 bug）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//
// > 某个动画源不登录都可以看,只不过视频播放需要登录而已,这应该是bug!
//
// # 这个 bug 的两半
//
// ① **核心侧**：`Registry::home_all()` 拿 `session_usable()` 当首页门禁。
//    而 `login_required` 的定义是「需要登录才能**取流**」——它管**播放**，
//    不管**浏览**。于是「游客态能正常浏览」的源被整个跳过。
//    ⇒ 已由 `rust/sourin_core/src/registry.rs` 的
//      `home_keeps_guest_source_whose_home_works` 守着。
//
// ② **界面侧**：源被跳过后 `visible` 为空，界面落回那句
//    「还没有可用的内容源 / 在设置里启用或导入一个内容源即可开始」。
//    ★ 但用户**明明启用了源**（源切换条上就有它）——
//      这句话把「没装源」和「这个源这次没给内容」混为一谈。
//    本文件守的是这一半。
//
// # 为什么这个文件值得存在
//
// 本文件早先的注释自己就承认过这句话是误导的：
// ```text
// ⚠️ 但空态那句文案…在这种情形下**是误导的** —— 用户明明启用了源。
//    本轮**不改**（超出「一处过滤」的范围），已记入交付报告。
// ```
// 记了报告但没修 —— 于是它真的被 Owner 撞到了。
// 这正是「已知缺陷必须当场修掉，而不是记进报告」的活教材。
//
// ⚠️ 断言用 `emptyStateText`（顶层纯函数）而不是 widget 树：
//    这个判据是**纯逻辑**（启用列表 + 当前源 → 一句话），
//    纯函数能直接被红度证明打到，widget 树反而要搭一堆脚手架。
//    渲染那一层由 `core_error_test.dart` 的既有用例覆盖。

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/home_page.dart';

/// 造一个最小的源清单（只用到 id / name / capabilities.vod）
ProviderManifest _p(String id, String name, {bool vod = true}) => ProviderManifest(
      id: id,
      name: name,
      version: '1',
      kind: 'test',
      capabilities: Capabilities(vod: vod),
    );

void main() {
  group('首页空态文案分情况', () {
    test('★ 启用了源但当前源没内容 → 说「暂时没有内容」，不说「还没有可用的内容源」', () {
      final (title, _, noSource) = emptyStateText(
        enabled: [_p('cycani', '源甲')],
        current: 'cycani',
      );
      expect(
        title,
        '「源甲」暂时没有内容',
        reason: '★ 用户明明启用了源（源条上就有它），说「还没有可用的内容源」是误导 —— '
            '这正是 Owner 撞到的那个 bug 的界面侧。',
      );
      expect(noSource, isFalse, reason: '不该被当成「一个源都没启用」');
    });

    test('★ 当前源的 id 不在启用列表里 → 不猜源名，退回通用文案', () {
      final (title, _, noSource) = emptyStateText(
        enabled: [_p('a', '甲源')],
        current: 'ghost',
      );
      expect(title, '还没有可用的内容源');
      expect(noSource, isTrue);
    });

    test('真的一个源都没启用 → 保留原文案（这句才是真的）', () {
      final (title, desc, noSource) = emptyStateText(enabled: const [], current: '');
      expect(title, '还没有可用的内容源');
      expect(desc, '在设置里启用或导入一个内容源即可开始');
      expect(noSource, isTrue);
    });

    test('★ 只启用了纯直播源 → 也不能说「还没有可用的内容源」之外的原话（判据是 enabled 非空）', () {
      // 纯直播源不会出现在 _enabled 里（homeSourceList 已排除），
      // 但 current 可能仍留着它的 id —— 此时必须走兜底分支而不是崩。
      final (title, _, noSource) = emptyStateText(
        enabled: [_p('iptv', 'IPTV', vod: false)],
        current: 'iptv',
      );
      expect(title, '「IPTV」暂时没有内容', reason: 'enabled 非空 ⇒ 不该说「还没有可用的内容源」');
      expect(noSource, isFalse);
    });
  });
}
