// ═══════════════════════════════════════════════════════════════════════
//  切 tab 的离场页快照 —— **已回退**，本文件守住"不许加回来"
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景：它一度是个"性能优化"
// ```text
// `SOURIN_TABS=1` 实测：切 tab 那几帧 raster 冲到 20~45ms（超预算），
// 而 build 只有 0.4~1.5ms ⇒ 全是光栅成本。
// ⇒ 试了"离场页光栅快照"（Flutter 官方 Zoom 的 allowSnapshotting 那招），
//   读数确实变好（raster p50 17022 → 5400）。
// ```
//
// # 为什么回退（Owner 报 + 截图）
// ```text
// > 页面切换出现这个情况
// 截图：切页时**两页叠在一起**（首页与直播页同时可见，且停在那儿）。
//
// 实测复现（同一驱动、同一时刻）：
//   · 挂快照   ⇒ 叠影
//   · 不挂快照 ⇒ 正常
// ⇒ `SnapshotWidget` 与本层的过渡结构**不兼容**：
//   它把子树换成一张光栅图（引入新 layer 边界），而本层的
//   FadeTransition / SlideTransition / 离场放大是作用在**子树**上的 ——
//   换成图之后那条变换链与快照层没有正确复合 ⇒ 离场页以
//   **全不透明、未变换**的形态留在屏幕上。
// ```
//
// # 本文件锁什么
// ```text
// ★ 断言这个位置**不许**再出现 `SnapshotWidget` / 光栅快照。
//
// # 为什么值得专门写一条（而不是"删掉优化就行"）
// ```text
// 这条优化的**诱惑力很大**：读数好、单测绿、编译过。
// 唯一能证伪它的是**看像素** —— 而像素不会在 CI 上说话。
// ⇒ 把它写成"禁止"的契约，并在下面写清"为什么"，下次有人想加时
//   会先读到这段，知道"加之前必须先做真机截图对比"。
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

  test('★ 切 tab 的离场页**不许**再挂光栅快照（曾因叠影回退）', () {
    /*
     * 反面（= 曾经的真实缺陷）：把下面任意一个加回去 ⇒ 红。
     * ⚠️ `page_transition_route.dart`（**路由**那处）的快照**不在**本条范围：
     *    那条链形状不同，且已由它自己的测试与真机验证守着。
     *    本条只管 **shell 的 tab 过渡**这一处。
     */
    expect(
      shell.contains('_SnapshotOnce'),
      isFalse,
      reason: '★★★ shell 的 tab 过渡里**不许**再挂离场页光栅快照 ——\n'
          '它曾让"切页时两页叠在一起"（Owner 报 + 截图，已实测复现）。\n'
          '根因：`SnapshotWidget` 把子树换成光栅图（新 layer 边界），\n'
          '而本层的 Fade/Slide/离场放大是作用在**子树**上的 ⇒ 变换链没复合。\n'
          '★ 它**读数确实更好**（raster p50 17022 → 5400）—— 所以诱惑力很大。\n'
          '  若将来真要再做，**必须**先做真机截图 A/B（像素优先于读数），\n'
          '  而不是"单测绿 + 读数降了就上"。',
    );
    expect(
      shell.contains('SnapshotWidget'),
      isFalse,
      reason: '★ 同上：shell 里不许有 SnapshotWidget（tab 过渡这处）。',
    );
    expect(
      shell.contains('allowSnapshotting'),
      isFalse,
      reason: '★ 同上。',
    );
  });

  test('★ 阴性对照：路由那处的快照**不受**本条约束（它是对的）', () {
    // 证明本条不是"全仓禁快照"——路由处在 `page_transition_route.dart`，
    // 那条链形状不同、已验证。本测试只读 shell.dart，故这里做一次声明式对照。
    final route = File('lib/ui/widgets/page_transition_route.dart');
    expect(route.existsSync(), isTrue,
        reason: '路由过渡那个文件必须还在（它的快照是**保留**的）');
    expect(
      route.readAsStringSync().contains('SnapshotWidget'),
      isTrue,
      reason: '★ 路由处的离场页快照应当**仍然在** —— 本条只管 shell 的 tab 过渡，'
          '不要顺手把它也删了（那会让路由的返回卡顿重新出现）。',
    );
  });
}
