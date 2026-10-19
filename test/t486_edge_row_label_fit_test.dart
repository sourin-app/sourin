// ═══════════════════════════════════════════════════════════════════════
//  t486 行为级：四行标签在手机宽度下**不得**被省略
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条测试要钉住的真机缺陷（task-96 取证）
//
// 手机（1080x2400 @420dpi，逻辑宽 411）上，四个端点一旦设了值，
// 四行标签**全部**渲染成 `片…` —— 只画出第一个字。
// 像素取证：标签列墨迹宽 **144px → 68px**（-52.8%）。
//
// 根因：`_EdgeRow` 里 `labelW = textSpace * 72/(72+76)` —— **按比例**分。
// 值一设上，`fixedW` 变大 ⇒ `textSpace` 变小 ⇒ `labelW` 被压到 45px，
// 而四个汉字要 56px（`FontSizes.sm = 14`）。
//
// # 为什么不能只断言"源码里改成按需分配了"
//
// 那是**语法层**断言（lesson #562：一次让功能变强的重构会把它判红，
// 而真正的回归它又抓不住）。这里断言的是**渲染层**的性质：
// 标签的 `RenderParagraph.didExceedMaxLines` —— 这正是驱动
// `TextOverflow.ellipsis` 画那三个点的**同一个**布尔量。
//
// ★ 仪器自检（本文件必须自己证明尺子灵敏）：
//   最后一组在**极窄**宽度下断言标签**确实**被省略 ——
//   若那里也报"没省略"，说明这条测试永远会绿，等于没有守卫。
//
// ⚠️ 本仓纪律：断言必须与证据**同层**。
//    真机像素是最终证据（`.probe\t471_label_truncate.txt`）；
//    这里用 `didExceedMaxLines` 把同一条性质搬进自动化测试，
//    这样下次谁再把分配改回"按比例"，`flutter test` 就会红。
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

/// 与 `t462` 同构的宿主 —— 生产外壳的**最小**复刻
Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (context, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: child,
  );
}

const _labels = ['片头开始', '片头结束', '片尾开始', '片尾结束'];

/// 在**捕获窗口**内执行 [body]：把渲染异常正文记进 [sink]，并照旧转发
///
/// ★ 为什么必须从 `FlutterError.onError` 取正文：
///   同一个 `pump` 里抛出**多条**时，`takeException()` 只给一句
///   ```text
///   Multiple exceptions (2) were detected during the running of the current
///   test, and at least one was unexpected.
///   ```
///   —— 正文全丢（第一次改完就是这样：sink 里只有这一句，
///   而我们要断言的恰恰是正文里的 `overflowed by N pixels` 与出错位置）。
///
/// ★ 转发给 `prev` 是**刻意**的：flutter_test 自己的异常账本不受影响，
///   本文件只是"顺带记一份"。
Future<void> _guard(
  List<String> sink,
  Future<void> Function() body,
) async {
  final prev = FlutterError.onError;
  FlutterError.onError = (details) {
    sink.add(details.exceptionAsString().split('\n').first);
    prev?.call(details);
  };
  try {
    await body();
  } finally {
    FlutterError.onError = prev;
  }
}

/// 泵帧，并把**被吞掉的异常**逐条记进 [sink]
///
/// # 为什么不能写 `while (tester.takeException() != null) {}`
///
/// `takeException()` 是**取走即清除** —— 写成一个空循环等于把整条
/// 渲染异常通道静音。这不是理论问题：本文件第一次跑的时候，
/// 极窄 300 那一组抛了
/// ```text
/// A RenderFlex overflowed by 37 pixels on the right.
///   Row Row:...skip_marker_dialog.dart:2203:16   ← 顶部徽章
/// ```
/// 而测试**照绿**（读数见 `.probe\t486_run.txt`）。
/// ⇒ 一个吞异常的 helper 就是**掩盖布局回归的通道**：
///   将来谁再引入一个溢出，同样不会红。
Future<void> _pumpDrain(WidgetTester tester, int frames, List<String> sink) =>
    _guard(sink, () async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 250));
        // 取走 = 不再让 flutter_test 在收尾时重复报；断言由本文件自己做
        while (tester.takeException() != null) {}
      }
    });

/// `pumpWidget` 也要进捕获窗口 —— 首帧的异常同样会进 flutter_test 的账本
Future<void> _pumpWidgetDrain(
  WidgetTester tester,
  Widget w,
  List<String> sink,
) =>
    _guard(sink, () => tester.pumpWidget(w));

/// 把四个端点都设上值 —— 这是缺陷的**触发条件**
///
/// ⚠️ 未设置时 `labelW` 会触到上限 72，四行完好；
///    一设值 `fixedW` 变大（多了清除按钮），缺陷才现形。
///    所以测试**必须**先设值，否则它会假绿。
///
/// ⚠️⚠️ **每一次 pump 都必须走 `_pumpDrain`**。
///    溢出是在点 `+` 之后的那一帧抛的；第一版把 4 次 tap 的 pump
///    写在外面（用裸 `tester.pump`），异常就被 flutter_test 记进
///    待处理账本，随后被 `takeException()` 悄悄取走 ⇒ sink 里 0 条，
///    断言 `ovf isNotEmpty` 反而红。**捕获窗口要覆盖异常真正发生的那一帧。**
Future<void> _setAllFour(WidgetTester tester, List<String> sink) async {
  final plus = find.byIcon(Icons.add);
  for (var i = 0; i < 4; i++) {
    await tester.tap(plus.at(i), warnIfMissed: false);
    await _pumpDrain(tester, 1, sink);
  }
  await _pumpDrain(tester, 8, sink);
}

/// 溢出类异常（`RenderFlex overflowed by N pixels`）
List<String> _overflows(List<String> caught) =>
    caught.where((e) => e.contains('overflowed')).toList();

/// 打印本组捕获到的全部异常 —— 让"没有异常"和"没在量"可区分
void _reportCaught(String group, List<String> caught) {
  if (caught.isEmpty) {
    // ignore: avoid_print
    print('T486|$group 捕获异常 0 条');
    return;
  }
  // ignore: avoid_print
  print('T486|$group 捕获异常 ${caught.length} 条：');
  for (final e in caught) {
    // ignore: avoid_print
    print('T486|    $e');
  }
}

/// 读出每个标签的「可用宽 / 实际需要宽 / 是否被省略」
///
/// 这是本文件的**尺子**。三个读数一起报，是为了让失败时能直接看出
/// 是"宽度不够"还是"根本没量到"。
List<String> _probeLabels(WidgetTester tester) {
  final out = <String>[];
  for (final label in _labels) {
    final f = find.text(label);
    if (f.evaluate().isEmpty) {
      out.add('$label MISSING');
      continue;
    }
    final rp = tester.renderObject<RenderParagraph>(f);
    final avail = rp.constraints.maxWidth;
    final need = rp.getMaxIntrinsicWidth(double.infinity);
    final clipped = rp.didExceedMaxLines;
    out.add('$label avail=${avail.toStringAsFixed(1)} '
        'need=${need.toStringAsFixed(1)} '
        '${clipped ? "CLIPPED" : "fits"}');
  }
  return out;
}

/// 手机逻辑宽 411（1080 / 2.625）—— 真机缺陷就是在这个宽度上出现的
const _phone = Size(1080 / 2.625, 2400 / 2.625);

void main() {
  /*
   * ★★★ 第 66 轮：注入 `debugSkipMarkerFetcher`
   * ```text
   * 不注入时 `SkipMarkerDialog._loadExisting()` 调真 FFI：异常落在**真实时间**轴上，
   * 而 `_kLoadTimeout`=10s（skip_marker_dialog.dart:733）被建成 **FakeTimer**，
   * 本文件预算不足 10s ⇒ `_LoadState` 卡在 loading ⇒ 时间轴/四行不挂载。
   * ⇒ 注入 `(_, __) async => null` = "没设过跳过点"（**正常结果**）⇒ 直接 ok，
   *   不需要 runAsync，也不需要 libmpv/FFI（故不打 native-media 标签）。
   * ⚠️ tearDown 必须置回 null —— 它是**进程级 static**，不复位会串到别的用例。
   */
  setUp(() => SourinApi.debugSkipMarkerFetcher = (_, __) async => null);
  tearDown(() => SourinApi.debugSkipMarkerFetcher = null);

  group('t486 四行标签在手机宽度下不得被省略', () {
    testWidgets('★ 手机宽度（1080x2400 @2.625）设满四个值后，标签全部完整',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1080, 2400);
      tester.view.devicePixelRatio = 2.625;
      addTearDown(tester.view.reset);

      final caught = <String>[];
      await tester.pumpWidget(_host(
        const SkipMarkerDialog(
          provider: 'demo',
          id: 't486',
          title: 't486 标签完整性',
          streamUrl: '',
          duration: Duration(minutes: 10),
        ),
      ));
      await _pumpDrain(tester, 14, caught);

      await _setAllFour(tester, caught);

      final rows = _probeLabels(tester);
      // ignore: avoid_print
      print('T486|手机 ${_phone.width.toStringAsFixed(1)} 逻辑宽：');
      for (final r in rows) {
        // ignore: avoid_print
        print('T486|  $r');
      }
      _reportCaught('手机', caught);

      final clipped = rows.where((r) => r.contains('CLIPPED')).toList();
      expect(
        clipped,
        isEmpty,
        reason: '★★★ 真机缺陷：设满四个值后标签被渲染成 `片…`。'
            '四行标签必须完整显示 —— 若这里红了，说明 `_EdgeRow` 的宽度'
            '分配又回到了"按 72:76 比例瓜分"（值一设上就把标签压到 45px，'
            '而四个汉字要 56px）。实测读数见上面 T486| 那几行。',
      );

      // ★ 手机宽度是**真机**宽度 ⇒ 这里不许有任何溢出
      //   （`t471` 真机取证：1080x2400 @420dpi 上四行、徽章都完好）
      expect(
        _overflows(caught),
        isEmpty,
        reason: '★ 手机宽度下不该有 RenderFlex 溢出 —— '
            '真机取证时徽章与四行都是完好的。'
            '若有溢出，说明某个 Row 在 411 逻辑宽下放不下。',
      );
    });

    testWidgets('★ 桌面宽度下结果不变（不许为修手机而改坏桌面）',
        (WidgetTester tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final caught = <String>[];
      await tester.pumpWidget(_host(
        const SkipMarkerDialog(
          provider: 'demo',
          id: 't486d',
          title: 't486 桌面',
          streamUrl: '',
          duration: Duration(minutes: 10),
        ),
      ));
      await _pumpDrain(tester, 14, caught);

      await _setAllFour(tester, caught);

      final rows = _probeLabels(tester);
      // ignore: avoid_print
      print('T486|桌面 1280 逻辑宽：');
      for (final r in rows) {
        // ignore: avoid_print
        print('T486|  $r');
      }
      _reportCaught('桌面', caught);

      expect(rows.where((r) => r.contains('CLIPPED')), isEmpty,
          reason: '★ 桌面下标签本来就没问题，改动不许把它弄坏');
      // 桌面下应当**没有任何一行**因为宽度不足而缩水
      expect(rows.where((r) => r.contains('MISSING')), isEmpty,
          reason: '★ 四行都要在（桌面高度足够，不该有行被裁掉）');
      expect(_overflows(caught), isEmpty,
          reason: '★ 桌面 1280 逻辑宽下不该有 RenderFlex 溢出');
    });

    testWidgets('★★ 仪器自检：极窄宽度下标签**确实**会被省略（尺子必须灵敏）',
        (WidgetTester tester) async {
      /*
       * 这一条是**本文件的阳性对照**。
       *
       * 若没有它，上面两条断言有可能只是"永远为真"（比如
       * `find.text` 找不到、或 `didExceedMaxLines` 恒为 false），
       * 那样的话真缺陷回来了测试也不会红。
       *
       * 宽度取 300 逻辑 —— 桌面弹窗最小宽度附近，四行必然挤。
       */
      tester.view.physicalSize = const Size(300, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final caught = <String>[];
      await tester.pumpWidget(_host(
        const SkipMarkerDialog(
          provider: 'demo',
          id: 't486n',
          title: 't486 极窄',
          streamUrl: '',
          duration: Duration(minutes: 10),
        ),
      ));
      await _pumpDrain(tester, 14, caught);

      await _setAllFour(tester, caught);

      final rows = _probeLabels(tester);
      // ignore: avoid_print
      print('T486|极窄 300 逻辑宽（阳性对照，期望看到 CLIPPED）：');
      for (final r in rows) {
        // ignore: avoid_print
        print('T486|  $r');
      }
      _reportCaught('极窄 300', caught);

      // 至少有一个标签被省略 —— 证明 `didExceedMaxLines` 这条尺子会动
      expect(
        rows.where((r) => r.contains('CLIPPED')),
        isNotEmpty,
        reason: '★★ 阳性对照失败：300 逻辑宽下四行**本该**挤到省略，'
            '这里却没量到 CLIPPED ⇒ 说明 `didExceedMaxLines` 这条尺子'
            '在本环境不灵敏，上面两条"没被省略"的断言因此**没有证明力**。'
            '（这正是"阴性读数需要一个已被证明灵敏的仪器"那条纪律。）',
      );

      /*
       * ★★★ 2026-10-19：极窄组的溢出**已归零**，判据随之升级。
       *
       * # 改前是什么样（留作历史，别再照抄）
       * ```text
       * 极窄 300 逻辑宽下，徽章那一行会报 RenderFlex overflowed。
       * 判据写死「溢出条数 > 0 且恰好是 `overflowed by 41 pixels`」——
       *   即把已知缺陷**钉成指纹**：只允许这一处、这一个数值。
       * 读数沿革：37（更早一次修复后的陈旧值）→ 41（真值）→ 8.5。
       * ```
       *
       * # 根因不是「头部徽章 Row」（那是这条注释原来的说法，属**误标**）
       * ```text
       * 用 debugDumpRenderTree 读 OVERFLOWING 节点的 creator 链，真值是：
       *   Row ← Padding ← DecoratedBox ← Container ← Wrap ← Expanded ← Row
       * ⇒ 溢出的是**每个 badge 内部那一行**
       *   （skip_marker_dialog.dart 里 badge() 的 child: Row），不是头部那行。
       * 该行：色点 7 + Sp.x1 4 + 文字 199.5 = 210.5，可用宽只有 202.0 ⇒ 溢出 8.5。
       *   （HEAD 当时可用宽 170.0 ⇒ 溢出 41；我删掉头部那个 32px 关闭钮后
       *     徽章多出 32 ⇒ 溢出从 41 缩到 8.5。**变小不等于修好**。）
       * ```
       *
       * # 修法（实现侧，skip_marker_dialog.dart 的 badge()）
       * 文字外包 `Flexible` + `TextOverflow.ellipsis` ⇒ 放不下就压缩并出省略号。
       * ⚠️ **不是**缩字号、**不是**砍掉省略号 —— 那样会把本文件要守的
       *    「标签放不下时怎么处理」这个可见行为一起弄没（见下面 ②）。
       *
       * # 所以本组现在断言「零溢出」，而不是某个数值
       * ★ 判据本意一直是「**不许有溢出**」，数值只是缺陷期的指纹。
       *   缺陷修好后继续钉指纹 = 把尺子的刻度改短，将来谁再撑宽徽章它就不响了。
       */
      final ovf = _overflows(caught);
      // ① 极窄组：溢出条数必须 == 0（**不是**删掉这条断言 —— 删了就没人守极窄组）
      expect(
        ovf,
        isEmpty,
        reason: '★★ 极窄 300 逻辑宽下**不许有任何溢出**。\n'
            '徽章文字已改成 `Flexible` + `TextOverflow.ellipsis`，'
            '放不下时应当省略而不是溢出。\n'
            '实测捕获到 ${ovf.length} 条：$ovf\n'
            '★ 若溢出的是**徽章内部那一行**'
            '（creator 链 = `Row ← Padding ← DecoratedBox ← Container ← Wrap`），'
            '多半是有人把 badge() 里的 `Flexible` 又删了 ⇒ 立刻查。\n'
            '若是**别的**行 ⇒ 那是新引入的布局回归。',
      );
      // ③ 与「手机/桌面零溢出」**分开**断言并各自写明理由：
      //    三种宽度的失效模式不同（手机=竖屏窄、桌面=宽而全、极窄=徽章挤压），
      //    合成一条就看不出是哪一种坏了。
      expect(
        caught.where((e) => !e.contains('overflowed')).toList(),
        isEmpty,
        reason: '★ 极窄组：非溢出类异常（抛异常/断言失败等）也不该出现。'
            '注意这条与上面那条**分开**：上面只管布局溢出，'
            '这条管「别的坏事」，两者失效原因不同。实测：$caught',
      );
    });
  });
}
