// 三态可访问性静态检查：点击目标尺寸 + 方向键可达
//
// # 判据
// ```text
// ① 每个选项的点击目标高度 ≥ 44px（Windows 触摸/TV 遥控的常见下限）
// ② 三个选项都必须**能被焦点访问**（RadioListTile 内建 InkWell ⇒ 天然可聚焦）
// ③ 方向键顺序 = 视觉顺序（keyboardDismissBehavior / FocusTraversal 无阻断）
// ```
//
// # ★★★ 覆盖边界（2026-10-20，`verify-34` 复核时要求写明）
// ```text
// 本文件渲染的是 `_Probe` —— 与产品页**同构的最小副本**，不是 `DanmakuSourcePage`。
// ⇒ 上面三条判据**不覆盖产品页**：
//   · 产品页里那三个 RadioListTile 的实际高度
//   · 产品页里的真实焦点顺序 / 真实回调接线
//   · 产品页里地址框的出现条件
//
// 产品页的覆盖由 **test/zz_t66_verify_danmaku_proxy_shots_test.dart** 承担
// （`pumpWidget` 真 `DanmakuSourcePage()`：读真实渲染文本 + 三张图 hash 互不相等
//   + 地址框只在 custom 下出现）。
// ⇒ 本文件末尾有一条机械自检守着这件事：那个文件一旦不再挂产品页，这里就红。
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/danmaku.dart';

/// 单独搭一个与产品页同构的最小三态，测尺寸
///
/// ★ 为什么不直接 pump 产品页：那个页面 initState 会读数据目录（见 AGENTS.md §8），
///   而本测试只关心**控件尺寸**，不需要整页。用同构最小样例更干净、也不碰真实数据。
class _Probe extends StatelessWidget {
  const _Probe({required this.mode, required this.onChanged});
  final DanmakuProxyMode mode;
  final ValueChanged<DanmakuProxyMode?> onChanged;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: ListView(
          children: [
            RadioGroup<DanmakuProxyMode>(
              groupValue: mode,
              onChanged: onChanged,
              child: const Column(
                children: [
                  RadioListTile<DanmakuProxyMode>(
                    value: DanmakuProxyMode.direct,
                    title: Text('直连'),
                    subtitle: Text('不经过代理，也不受系统代理设置影响'),
                    dense: true,
                  ),
                  RadioListTile<DanmakuProxyMode>(
                    value: DanmakuProxyMode.system,
                    title: Text('跟随系统代理'),
                    subtitle: Text('读取环境变量里的 HTTP_PROXY / HTTPS_PROXY'),
                    dense: true,
                  ),
                  RadioListTile<DanmakuProxyMode>(
                    value: DanmakuProxyMode.custom,
                    title: Text('自定义代理'),
                    subtitle: Text('只让弹幕请求走这个地址（填 HTTP 代理，不支持 socks）'),
                    dense: true,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

void main() {
  testWidgets('三态：每个选项点击目标高度 ≥ 44px', (t) async {
    await t.pumpWidget(_Probe(
      mode: DanmakuProxyMode.direct,
      onChanged: (_) {},
    ));
    await t.pumpAndSettle();

    final tiles = find.byType(RadioListTile<DanmakuProxyMode>);
    expect(tiles, findsNWidgets(3));

    for (var i = 0; i < 3; i++) {
      final box = t.getSize(tiles.at(i));
      // ignore: avoid_print
      print('[A11Y] 选项 $i 尺寸 ${box.width}x${box.height}');
      expect(
        box.height,
        greaterThanOrEqualTo(44),
        reason: '选项 $i 高度 ${box.height} < 44 ⇒ 触摸/遥控不易点中',
      );
    }
  });

  testWidgets('三态：三个选项都可被焦点访问（方向键可到）', (t) async {
    await t.pumpWidget(_Probe(
      mode: DanmakuProxyMode.direct,
      onChanged: (_) {},
    ));
    await t.pumpAndSettle();

    /*
     * 判据：每个 RadioListTile 内部应有可聚焦节点。
     * `RadioListTile` 由 `InkWell` + `MergeSemantics` 组成 ⇒ 天然可聚焦。
     * ⇒ 这里验"确实存在"，而不是验样式。
     */
    final focusables = find.descendant(
      of: find.byType(RadioListTile<DanmakuProxyMode>),
      matching: find.byType(Focus),
    );
    final n = focusables.evaluate().length;
    // ignore: avoid_print
    print('[A11Y] RadioListTile 内 Focus 节点数=$n');
    expect(n, greaterThanOrEqualTo(3),
        reason: '三个选项都要有可聚焦节点，否则方向键到不了');
  });

  testWidgets('三态：点选后回调真的被调用（RadioGroup 接线验证）', (t) async {
    /*
     * # 为什么必须有这一条
     * ```text
     * 从「每个 tile 传 groupValue/onChanged」改成「RadioGroup 包住」时，
     * 最容易犯的错是：**包了 RadioGroup，但忘了把 onChanged 接上**
     *   ⇒ 界面看起来完全正常（选中态会变），但**值没落盘**
     *   ⇒ 用户选了"自定义"，实际还是直连 —— 静默失效
     *
     * 这正是 AGENTS.md §4 硬规矩 ①：写了 ≠ 接线了。
     * ```
     */
    DanmakuProxyMode? got;
    await t.pumpWidget(_Probe(
      mode: DanmakuProxyMode.direct,
      onChanged: (v) => got = v,
    ));
    await t.pumpAndSettle();

    // 点第二个选项（跟随系统）
    final tiles = find.byType(RadioListTile<DanmakuProxyMode>);
    await t.tap(tiles.at(1));
    await t.pumpAndSettle();

    // ignore: avoid_print
    print('[A11Y] 点选后回调收到=$got');
    expect(got, DanmakuProxyMode.system,
        reason: 'RadioGroup 的 onChanged 必须真的被调用，否则选择不落盘');
  });

  // ───────────────────────────────────────────────────────────────────
  // ★★★ 覆盖边界自检（2026-10-20，`verify-34`）
  //
  // 本文件的 `_Probe` 是**同构副本** ⇒ 它证明的只是「这套控件写法可达」，
  // **不证明产品页可达**。真实页的覆盖被外包给了另一个文件 ——
  // 那条外包关系以前只写在注释里，谁删了那个文件都不会有人发现。
  // 这条把它变成机械判据：那个文件不再 pump 产品页 ⇒ 这里立刻红。
  // ───────────────────────────────────────────────────────────────────
  test('★ 覆盖边界：产品页三态的覆盖者必须仍然存在且真的挂产品页', () {
    final f = File('test/zz_t66_verify_danmaku_proxy_shots_test.dart');
    expect(
      f.existsSync(),
      isTrue,
      reason: '★★ 这个文件是本文件**不覆盖产品页**时的唯一补位者；'
          '删掉它 ⇒ 「三态在产品页上可达/可见」就**没有任何门禁**了。\n'
          '（本文件只测 `_Probe` 副本，见文件头的「覆盖边界」。）',
    );
    final src = f.readAsStringSync();
    expect(
      src.contains('DanmakuSourcePage('),
      isTrue,
      reason: '★★ 补位者必须**真的 pump 产品页**（`DanmakuSourcePage(`）。\n'
          '若它被改成只挂副本，那么产品页的三态就只剩本文件这条副本判据 ⇒ '
          '等于「用副本给自己作证」。',
    );
  });
}
