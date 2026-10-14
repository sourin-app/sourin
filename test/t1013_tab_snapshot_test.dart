// ═══════════════════════════════════════════════════════════════════════
//  切 tab 时的离场页快照 —— 逐页性能回归（Owner 2026-10-14）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 然后上面的问题解决完,再死磕每个页面的性能,确保性能已经优化
// > 无可优化的地步了,才能停止!
// ```
//
// # 实测（`SOURIN_TABS=1` 自动轮流切 tab，逐页 raster p50）
// ```text
// 切 tab 那几帧 raster 冲到 20~45ms（超预算），而 build 只有 0.4~1.5ms
// ⇒ **纯光栅成本**：过渡期间两页各自整页重绘（离场页构图不变，只是淡出）。
// 与「从播放页返回卡顿」同一个根因，同一招修：离场页**光栅快照**。
// ```
//
// # 实测收益（同一驱动，逐窗口 raster p50）
// ```text
// 改前：11241 11657 17022 15275 …（稳态爬升到 ~17000）
// 改后：  6333  5487  5400  …       （稳态 ~5400，且不再爬升）
// ⇒ 约 -50%。
// ```
//
// # 本文件锁什么
// ```text
// ① 契约：退场动画期间，离场页必须被 `SnapshotWidget` 包住
// ② 契约：**只在**"有离场页且正在淡出"时包 —— 其余情况下不得改变
//    widget 结构（当前页/隐藏页/未访问页的树与改前逐层一致）
// ③ ★ 关键的正确性风险：快照**不许**把页面冻住 ——
//    必须证明它在动画结束后**不残留**（否则用户会看到一页不动的内容）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

void main() {
  late String shell;

  setUpAll(() => shell = _code(File('lib/shell.dart').readAsStringSync()));

  test('① 退场时挂快照：`_SnapshotOnce` 存在且只在 leaving 支上', () {
    expect(shell.contains('class _SnapshotOnce'), isTrue,
        reason: '★ 应有离场页快照组件（切 tab 时把构图不变的旧页光栅成图，'
            '过渡期每帧只搬图 —— 与路由那处同一招）');
    expect(
      RegExp(r'widget\.leaving\s*&&\s*lf\s*!=\s*null\s*\?\s*_SnapshotOnce')
          .hasMatch(shell),
      isTrue,
      reason: '★★ 必须**同时**满足"是离场页"且"有淡出动画"才挂 —— '
          '只在 lf != null 时加，其余四种情况的树与改前逐层一致',
    );
  });

  test('② 快照必须用 `SnapshotMode.permissive`（平台视图时自动回落）', () {
    expect(shell.contains('SnapshotMode.permissive'), isTrue,
        reason: '★ permissive ⇒ 快照不了时**自动回落**到正常绘制，'
            '最坏等于"没优化"，不会画错（normal 会抛）',
    );
  });

  test('③ ★ 正确性：快照组件必须**随退场结束而卸载**（不许冻住页面）', () {
    /*
     * 判据（**静态**，但抓的正是那个真风险）：
     *   `_SnapshotOnce` 的 `allowSnapshotting` 是**常开**的
     *   （构造时 `SnapshotController(allowSnapshotting: true)`）。
     *   这在**本处**安全 —— 因为它的生命周期被父级的 `widget.leaving`
     *   精确框住：不再离场 ⇒ 这个组件整体从树上消失。
     *   ★ 而路由那处的离场页是**常驻**的，所以那里必须由动画状态显式门控
     *     （见 `page_transition_route.dart` 的 `_onStatus`）。
     *
     * ⇒ 本条钉住"本处依赖父级的 leaving 条件"，防止有人把 `_SnapshotOnce`
     *   挪到别处（或去掉那个 `widget.leaving &&` 条件）而不加门控。
     */
    expect(
      RegExp(r'widget\.leaving\s*&&\s*lf\s*!=\s*null').hasMatch(shell),
      isTrue,
      reason: '★★★ 若把 `widget.leaving &&` 去掉 ⇒ 快照会在**当前页**上也挂着，'
          '而它 `allowSnapshotting: true` 常开 ⇒ **当前页被冻住**（灾难）。'
          '本组件"常开也安全"的前提就是这个条件。',
    );
  });

  test('④ 反面守卫：不许把这个快照挪成"无条件挂"', () {
    // 反面：`_SnapshotOnce` 出现在 `lf == null ? transitioned : ...` 的**两支**里
    expect(
      RegExp(r'lf\s*==\s*null\s*\?\s*_SnapshotOnce').hasMatch(shell),
      isFalse,
      reason: '★ 不许在任何一支上无条件挂快照 —— 那会冻住正常页面',
    );
  });
}
