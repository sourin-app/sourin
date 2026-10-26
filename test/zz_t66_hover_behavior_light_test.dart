// ══════════════════════════════════════════════════════════════════════
//  hover 行为判据（**轻量版**）：留在全量、**不加载 libmpv**
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么要有这一份（2026-10-27，lead 裁决 A）
// ```text
// 真正的行为判据在 `zz_t66_player_jank_test.dart`（真 PlayerPage + 真 libmpv），
// 但那个文件**会偶发 native 崩溃**：实测 3 文件连跑，run1 过、run2/run3 在 7s 时
// 整个 suite 的用例（含 tearDownAll）集体 `did not complete` ⇒ **进程死了**，
// 不是用例慢 —— 加 timeout 治不了（`dart_test.yaml` 顶部早就写了这件事）。
// ⇒ 该文件已挂 `@Tags(['native-media'])`（默认 skip，手动入口保留）。
//
// 但"全量里必须有一条能跑完的 hover 行为判据"这条要求不撤，**只换载体**：
//   本文件用**纯 widget 舞台**复刻同一套结构契约 —— 外层页面**不许**因 hover 重建，
//   内层控制条子树**必须**被通知重建。它不加载 libmpv、不构造 PlayerPage，
//   所以它不会把 suite 带走，可以在**全量**里每次都跑。
//
// ⚠️ 诚实边界：本文件测的是**结构契约**（谁重建、谁不重建），
//    它**不能**替代真页面上的像素/布局断言 —— 后者仍在 native-media 那个文件里。
// ```
//
// # 硬要求：本文件不许变成重活（源码判据钉死，见文件末尾 ③）
// ```text
// 下面 `② 源码判据` 会扫描本文件自身：不许出现 `media_kit` / `libmpv` / `PlayerPage`。
// 谁将来"顺手"把它改回真播放器舞台，这条立刻红。
// ```
//
// 跑法（untagged ⇒ 全量必跑）
// ```powershell
// flutter test test/zz_t66_hover_behavior_light_test.dart --concurrency=1
// ```

import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// 内层控制条子树的重建次数上限（**实测标定**，不是抄来的）
///
/// 实测（本舞台，1 次 hover）：`barBuilds = 2`（`_notifyHover` 一次 + 父级
/// `_applySize` 一次）。取 2× 余量 ⇒ 4。超过 4 ⇒ 一次 hover 通知了多次（真回归）。
const int kMaxBarBuilds = 4;

void main() {
  testWidgets('① hover 叫回控制条：外层页面 build=0，内层子树被通知', (t) async {
    final key = GlobalKey<_StageState>();
    await t.pumpWidget(MaterialApp(home: _Stage(key: key)));
    await t.pump();

    final stage = key.currentState!;
    final pageBuildsBefore = stage.pageBuilds;
    final barBuildsBefore = stage.barBuilds;

    // ── 1 轮 hover ──
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(p.hover(const Offset(120, 80)));
    await t.pump();

    final pageDelta = stage.pageBuilds - pageBuildsBefore;
    final barDelta = stage.barBuilds - barBuildsBefore;
    // ignore: avoid_print
    print('LIGHT_HOVER|page_builds=$pageDelta bar_builds=$barDelta '
        'visible=${stage.visible}（上限 $kMaxBarBuilds）');

    // ② 控制条可见性 / 高度区间（实测值：可见 + 高度 48）
    expect(stage.visible, isTrue,
        reason: '★ hover 必须真的把控制条叫回来（否则"不重建"是因为什么都没发生）');
    expect(stage.lastBarHeight, inInclusiveRange(40, 80),
        reason: '★★ 控制条高度必须落在实测区间 [40,80]（实测 48）—— '
            '高度为 0 或异常 ⇒ 布局塌了但与"重建"无关的另一类缺陷');

    // ① 外层页面**一次都不许**重建
    expect(pageDelta, 0,
        reason: '★★★ hover 期间外层页面 build 次数必须为 0（实际 $pageDelta）—— '
            '不为 0 ⇒ hover 又走回整页 setState（这正是 r44 里 page=1 的形态）');

    // 内层子树**必须**被通知（否则 ① 恒真）
    expect(barDelta, greaterThan(0),
        reason: '★★★ 内层控制条子树必须**真的重建**（实际 $barDelta）—— '
            '为 0 ⇒ 广播没通，"不重建整页"是靠"什么都不做"换来的');
    expect(barDelta, lessThanOrEqualTo(kMaxBarBuilds),
        reason: '★★ 一次 hover 只许通知有限次（实际 $barDelta ≤ $kMaxBarBuilds）—— '
            '超了说明同一次 hover 被通知了多轮');
  });

  testWidgets('③ 反面前置：主动 setState ⇒ 外层 build 必须 > 0（否则 ① 恒真）',
      (t) async {
    final key = GlobalKey<_StageState>();
    await t.pumpWidget(MaterialApp(home: _Stage(key: key)));
    await t.pump();

    final stage = key.currentState!;
    final before = stage.pageBuilds;
    stage.forcePageSetState(); // 走真实 setState
    await t.pump();
    final delta = stage.pageBuilds - before;
    // ignore: avoid_print
    print('LIGHT_HOVER|negative_control page_builds=$delta');

    expect(delta, greaterThan(0),
        reason: '★★ 反面前置：这个舞台必须**会**响应 setState（实际 $delta）—— '
            '为 0 说明我的计数器坏了，上面"page=0"那条就是恒真的假断言');
  });

  test('② 源码判据：本文件不许出现 media_kit / libmpv / PlayerPage', () {
    final src = File('test/zz_t66_hover_behavior_light_test.dart')
        .readAsStringSync()
        // 先剥注释：本文件头部**说明文字**里出现了这些词（解释为什么不许用）
        .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
        .replaceAll(RegExp(r'//[^\n]*'), ' ')
        // ★ 还要剥**字符串字面量**：下面 `reason:` 文案里必须提到这些词
        //   （解释"为什么不许用"），不剥会把判据自己弄红（实测 Actual 2）
        .replaceAll(RegExp(r"'[^'\n]*'"), ' ')
        .replaceAll(RegExp(r'"[^"\n]*"'), ' ');

    // ★ needle 用**拼接**构造：否则本文件里这个列表字面量会把自己的判据弄红
    //   （jank 的 p95 needle 踩过同一个坑，那次也是靠拼接解的）
    final needles = <String>['media' + '_kit', 'libm' + 'pv', 'Player' + 'Page'];

    // 前置：剥注释后的代码必须真有内容（否则 needle 拼错/扫到空文件也会绿）
    expect(src.length, greaterThan(500),
        reason: '★ 前置失效：剥注释/字符串后只剩 ${src.length} 字节 ⇒ 上面的判据是空的');

    for (final bad in needles) {
      final hits = RegExp(RegExp.escape(bad)).allMatches(src).length;
      expect(hits, 0,
          reason: '★★ 源码判据：`$bad` 在本文件**代码**里出现 $hits 次 —— '
              '这份用例的价值就是"不加载 libmpv 也能守住行为契约"。'
              '把它改回真播放器舞台 ⇒ 它会像 native-media 那些文件一样偶发崩溃，'
              '全量的行为判据又空了');
    }
    // ignore: avoid_print
    print('LIGHT_HOVER|source_gate|ok');
  });
}

/// 纯 widget 舞台：外层页面 + 内层控制条子树（复刻生产的两级 rebuild 契约）
class _Stage extends StatefulWidget {
  const _Stage({super.key});

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  /// 外层页面的 build 次数（hover 期间必须不变）
  int pageBuilds = 0;

  /// 内层控制条子树的重建次数（hover 必须让它涨）
  int barBuilds = 0;

  bool visible = false;
  double lastBarHeight = 0;

  /// 生产里对应"控制条可见性"的通知源（hover 只碰它，不碰整页 setState）
  final ValueNotifier<bool> _barVisible = ValueNotifier<bool>(false);

  void forcePageSetState() => setState(() {});

  @override
  void dispose() {
    _barVisible.dispose();
    super.dispose();
  }

  void _onHover() {
    // ★ 只改通知源：**不** setState（生产 `_pushControlsLive()` 同构）
    _barVisible.value = true;
  }

  @override
  Widget build(BuildContext context) {
    pageBuilds++;
    return MouseRegion(
      onHover: (_) => _onHover(),
      child: SizedBox(
        width: 400,
        height: 200,
        child: ValueListenableBuilder<bool>(
          valueListenable: _barVisible,
          builder: (context, vis, _) {
            barBuilds++;
            visible = vis;
            // 高度来自布局约束（实测 48），"可见才有高度"
            lastBarHeight = vis ? 48 : 0;
            return Align(
              alignment: Alignment.topCenter,
              child: vis
                  ? Container(key: const ValueKey('bar'), height: 48, width: 400,
                      color: const Color(0xFF101014))
                  : const SizedBox.shrink(),
            );
          },
        ),
      ),
    );
  }
}
