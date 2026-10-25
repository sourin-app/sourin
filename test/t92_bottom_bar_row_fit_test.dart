@Tags(['native-media'])
library;

// ══════════════════════════════════════════════════════════════════════
//  t92 行为级：底栏按钮行「单行真放得下吗」——不换形就不许画出边界
// ══════════════════════════════════════════════════════════════════════
//
// # 这条测试要钉住的缺陷（task-33 真渲染探针取证，不是静态推断）
//
// 播放页底栏的按钮行有两种形态：**单行**（常驻项 + 条件项同一 Row，行内带
// `Spacer`）/ **两行**（常驻项一行 + 条件项自己一行、带横向滚动兜底）。
// 选哪一种由**可用宽**决定。缺陷期判据是 `fits = 约束有界 && 约束宽 >= 480`：
// 它只回答「约束有界吗」，**不回答「单行真放得下吗」**。
// 900 dp 视口（媒体页在 900 处切左右分栏 ⇒ 底栏可用宽只剩 528 dp）
// 走的是单行：`Spacer`（`Expanded`）被压到 0，行仍按**固有宽**布局并
// **画出边界**，超出的按钮被祖先 `Stack` 裁掉 —— 用户看到的是按钮凭空消失，
// 而且没有滚动条可滑。
//
// 读数（`.probe/android_fix/diag_bar11.txt`，真渲染探针，textScale 1.0）：
// ```text
// 视口    底栏可用宽   行固有宽   溢出
//  800      768.00     771.43     3.4 px
//  900      528.00     771.43   243   px   ← 最窄（媒体页在 900 处切分栏）
//  960      588.00     771.43   183   px
// 1024      652.00     771.43   119   px
// 1152      774.40     771.43     0
// 1280      864.00     771.43     0
// ```
// ⇒ 死区是「底栏可用宽 ∈ [528, 771.43)」，对应视口约 [900, 1152) dp。
// ★ 溢出量**不单调**：1024 的 119 < 960 的 183（因为可用宽在 900 处
//   反而被分栏压到最小）—— 所以只测一个宽度是不够的。
//
// # 为什么这一条以前抓不到
// `RenderFlex` 的溢出**只是 debug 诊断**（release 里静默裁切、无任何提示），
// 而当时所有测试都跑在 1280x800（可用 864 > 固有宽）⇒ 永远不触发。
// ⇒ 本文件是**唯一**覆盖 [528, 830) 这一段的守卫。
//
// ══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-25（task-38）：判定 **D 已过期**，判据已重写
// ══════════════════════════════════════════════════════════════════════
//
// # 判 D 的证据（实测，不是"看着像"）
// ```text
// 旧档位的四个标记（tooltip '截图' / Icons.photo_camera / Icons.tune /
// Icons.more_vert）在**今天的底栏里一个都不存在**：
//   · 截图 与 弹幕设置(tune) 已搬进「更多」菜单
//     （player_page.dart:6385 / :6467，都在 `_moreMenuGroups` 里），不在底栏按钮行；
//   · 「更多」那枚用的是 `AppIcons.more_horiz`（0xe402），**不是** more_vert（0xe404）。
// 实测（`.probe/final-t92-diag.log`，逐档 dump 底栏图标码点集）：
//   1280/1152/1024/960/900/800 六档的底栏图标集里都没有 0xe4b6 / 0xe683 / 0xe404，
//   但都有 0xe57f(`settings`) ⇒ **底栏渲染正常**（不是产品没画），
//   是**旧断言在找已经搬走的按钮** ⇒ 原来那 5 条红全是测试自身过期。
// ```
//
// # 同时确认：那条真缺陷确实**已经修好了**（所以几何判据继续有意义）
// ```text
// 形态选择现在在 `PlayerBottomBar._buttonsRow`
// （lib/ui/player/player_bottom_bar.dart:1477-1580）：
//     final wide = avail >= _kBarRowWidth;   // 720
//     wide  ⇒ Row([...primary, Spacer(), ...secondary])
//     否则  ⇒ Column([Row(primary + Spacer + 全屏),
//                     SingleChildScrollView(Row(secondary))])
// ⇒ 窄档把条件项放进**横向滚动**里，结构上不可能溢出。
// 实测（同一次诊断）：900/960/1024 可用宽 528/588/652 全 < 720 ⇒ 两行 + 1 个横向滚动；
//   1152/1280 可用宽 774/864 ≥ 720 ⇒ 单行 + 0 个横向滚动。
// 所有档位的行几何：size == avail == maxRight（毫厘不差），**零溢出**。
// ```
//
// # 因此本文件现在断言什么（都仍是"渲染层事实"，不写源码字符串）
// ```text
// ① 底栏真的渲染了：PlayerBottomBar ≥ 1、量到 ≥ 1 根横向行、齿轮(settings)在。
// ② 形态确实跟着可用宽换：available ≥ 720 ⇒ 单行（**整页 0 个横向 ScrollView**）；
//    < 720 ⇒ 两行（**整页恰好 1 个横向 ScrollView** = 条件项那条兜底）。
// ③ 任何宽度下都不许画出边界：每根行 maxRight ≤ avail + 0.01、size ≤ avail + 0.01。
// ④ 尺子自证（两条对照，缺一条本文件就可能是恒绿）：
//    · 合成一个**已知溢出**的 Row ⇒ `_guard` 必须抓到 'overflowed'；
//    · 旧标记必须**一个都不在** ⇒ D 的判定可复算（谁把它们搬回底栏，这条会红）。
// ```
//
// ⚠️ 视口必须用 `tester.view.physicalSize` / `devicePixelRatio`，
//    **不能**用 `setSurfaceSize` —— 后者只改布局约束、不改 FlutterView
//    的 metrics，两者打架会让修好的代码也报红（bottom_bar_fit_test.dart:71-87
//    用 3 个假红换来的铁律）。
import 'dart:io';

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/ui/player/player_bottom_bar.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';

/// 底栏某一根**横向** `RenderFlex` 的真几何
class _BarRow {
  _BarRow(this.avail, this.size, this.maxRight, this.kids);

  /// 它拿到的约束上限（`constraints.maxWidth`）
  final double avail;

  /// 它自己的宽度
  final double size;

  /// 最右子项的右缘（`offset.dx + size.width` 的最大值）
  final double maxRight;

  /// 子项个数
  final int kids;

  @override
  String toString() => 'avail=' +
      avail.toStringAsFixed(2) +
      ' size=' +
      size.toStringAsFixed(2) +
      ' maxRight=' +
      maxRight.toStringAsFixed(2) +
      ' kids=' +
      kids.toString();
}

/// 收集渲染树里所有「横向 `RenderFlex` 且 creator 链含 `_BottomBar`」的行
///
/// 判据与 `.probe/android_fix/zz_diag_bar11_test.dart:50-99` 逐字同源：
/// 只看 `debugCreator` 链，不看 widget 类型（`_BottomBar` 是私有的）。
///
/// ⚠️ 必须在**首帧**量：`_load()` 挂在 `addPostFrameCallback` 上，
///    flutter_tester 里 `sourin_core.dll` 加载不了 ⇒ `_load()` 必失败
///    ⇒ `_error` 置上 ⇒ **底栏整条消失**（`t63_shot_ui_test.dart:99-110`
///    记过同一件事）。
List<_BarRow> _barRows(WidgetTester t) {
  final out = <_BarRow>[];

  void walk(RenderObject ro, int depth) {
    if (ro is RenderFlex && ro.direction == Axis.horizontal) {
      final dc = ro.debugCreator;
      if (dc is DebugCreator &&
          dc.element.debugGetCreatorChain(30).contains('_BottomBar')) {
        var maxRight = 0.0;
        var kids = 0;
        ro.visitChildren((RenderObject c) {
          if (c is RenderBox) {
            final pd = c.parentData;
            final off = pd is FlexParentData ? pd.offset.dx : 0.0;
            final r = off + c.size.width;
            if (r > maxRight) maxRight = r;
            kids++;
          }
        });
        out.add(_BarRow(ro.constraints.maxWidth, ro.size.width, maxRight, kids));
      }
    }
    if (depth < 45) {
      ro.visitChildren((RenderObject c) => walk(c, depth + 1));
    }
  }

  for (final rv in t.binding.renderViews) {
    walk(rv, 0);
  }
  return out;
}

/// 在**捕获窗口**内执行 [body]：渲染异常正文记进 [sink]，并照旧转发
///
/// ★ 逐字照抄 `t486_edge_row_label_fit_test.dart:49-76`（连同它踩过的坑）：
///   同一个 pump 抛**多条**时 `takeException()` 只给一句
///   `Multiple exceptions (2) were detected…` —— 正文全丢，
///   而我们要断言的恰恰是正文里的 `overflowed by N pixels`。
/// ★ 转发给 prev 是**刻意**的：flutter_test 自己的异常账本不受影响。
Future<void> _guard(List<String> sink, Future<void> Function() body) async {
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

/// 认领一次 pump 期间积压的环境异常（无核心环境下的 FFI 异常等）
void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

/// 挂载**真实** `MediaPage`（⇒ 真实 `PlayerPage` ⇒ 真实 `_BottomBar`）
///
/// ★ 用 `MediaPage` 而不是直接挂 `PlayerPage`：底栏最窄的那一刻就是
///   `media_page.dart` 把视口切成分栏之后（视频列只剩 视口−32−detailW）——
///   直接挂 PlayerPage 会漏掉这个「越宽反而越窄」的拐点（900 的可用宽 528 < 800 的 768）。
Future<void> _mountMedia(WidgetTester t, double w, double h) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = Size(w, h);
  addTearDown(t.view.reset);
  await t.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: const MediaPage(provider: 'cycani', id: '3862', title: '无题'),
  ));
}

/// 推帧，把后续的渲染异常也收进 [sink]（首帧之后的都算补充证据）
Future<void> _moreFrames(WidgetTester t) async {
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 200));
  }
}

/// 首帧的一次完整取证
///
/// ⚠️ widget 计数**不能**等 `_moreFrames` 之后再取：`_load()` 挂在
///    `addPostFrameCallback` 上，flutter_tester 里 `sourin_core.dll`
///    加载不了 ⇒ `_load()` 必失败 ⇒ `_error` 置上 ⇒ 底栏整条消失
///    （`t63_shot_ui_test.dart` 的 `frames: 1` 就是为同一件事）。
///    第一版 t92 正是在 8 帧之后才做 finder 断言 ⇒ 五条全红在
///    「Found 0 widgets」—— 那是**仪器**问题。
Future<({List<_BarRow> rows, List<String> ovf, int gear, int scrolls})> _probe(
  WidgetTester t,
  double w,
) async {
  final sink = <String>[];
  late List<_BarRow> rows;
  late int gear;
  late int scrolls;
  await _guard(sink, () async {
    await _mountMedia(t, w, 900);
    // ★ 首帧：底栏一定还在（`_load()` 的 post-frame 回调还没跑）
    rows = _barRows(t);
    gear = find.byIcon(Icons.settings).evaluate().length;
    scrolls = find.byType(SingleChildScrollView).evaluate().length;
    await _moreFrames(t);
  });
  _claim(t);
  return (
    rows: rows,
    ovf: sink.where((s) => s.contains('overflowed')).toList(),
    gear: gear,
    scrolls: scrolls,
  );
}

/// 底栏「单行」所需的可用宽（= `player_bottom_bar.dart` 的 `_kBarRowWidth`）
///
/// ⚠️ 这是**复制**进测试的常量（原常量私有）。它只用来解释档位分界，
///   判据本身用的是"可观测的后果"（单行 / 两行），且两侧都留了余量：
///   1024 可用 652（<720 ⇒ 两行）、1152 可用 774（≥720 ⇒ 单行）。
const double _kRowFitExplainWidth = 720;

void main() {
  setUpAll(() {
    final dll = File('build/windows/x64/libmpv/libmpv-2.dll');
    if (dll.existsSync()) {
      MediaKit.ensureInitialized(libmpv: dll.absolute.path);
    }
  });
  setUp(() => RemoteBridge.instance.stop());
  tearDown(() => RemoteBridge.instance.stop());

  testWidgets('t92 ① 仪器自检：1280 dp 底栏渲染且走**单行**（几何必须量到东西）',
      (t) async {
    final r = await _probe(t, 1280);
    final barRows = r.rows.where((x) => x.avail.isFinite).toList();

    // ★★★ 阳性对照：底栏必须真的在。
    //   旧版这里断的是 tooltip '截图'，而截图已搬进「更多」菜单 ⇒ 那条早已失效
    //   （见文件头 D 的判定）：空转的阳性对照比没有更糟。
    expect(find.byType(PlayerBottomBar), findsWidgets,
        reason: '★★ 阳性对照：底栏组件本身必须挂上（否则下面所有几何断言都是空转）');
    expect(r.gear, 1,
        reason: '★★ 阳性对照：底栏的齿轮（Icons.settings，0xe57f）必须在 —— '
            '它在两种形态里都渲染，是最稳的"底栏真的画出来了"标记。实测 '
            'gear=${r.gear} rows=${r.rows}');
    expect(barRows, isNotEmpty,
        reason: '★ 必须量到「约束有界」的横向行（否则断言空转）');

    // ★ 形态判据：可用 864 ≥ 720 ⇒ 单行 ⇒ 整页没有横向滚动兜底
    expect(r.scrolls, 0,
        reason: '★ 1280 可用宽 ${barRows.first.avail.toStringAsFixed(0)} ≥ '
            '$_kRowFitExplainWidth ⇒ 必须走**单行**（条件项直接排在常驻项后面），'
            '也就是整页不该出现横向 ScrollView。实测 scrolls=${r.scrolls}');

    expect(r.ovf, isEmpty,
        reason: '★ 1280x800 可用 864 > 固有宽，修前修后都不该溢出（「没修坏」对照）');
    for (final x in barRows) {
      expect(x.maxRight, lessThanOrEqualTo(x.avail + 0.01),
          reason: '★ 最右子项右缘不得超出行宽：' + x.toString());
      expect(x.size, lessThanOrEqualTo(x.avail + 0.01),
          reason: '★ 行自身宽度不得超出可用宽：' + x.toString());
    }
    // ignore: avoid_print
    print('[t92] 1280 rows=${r.rows.map((x) => x.toString()).join(' | ')} '
        'gear=${r.gear} scrolls=${r.scrolls}');
  });

  group('t92 ② 换形守卫（可用宽 < $_kRowFitExplainWidth ⇒ 两行 + 横向兜底）', () {
    for (final w in <double>[900, 960, 1024]) {
      testWidgets('视口 ' + w.toInt().toString() + ' dp：换形、不画出边界', (t) async {
        final r = await _probe(t, w);
        final barRows = r.rows.where((x) => x.avail.isFinite).toList();
        final avail = barRows.isEmpty ? 0.0 : barRows.first.avail;

        expect(barRows, isNotEmpty, reason: '★ 必须量到底栏（否则断言空转）');
        expect(avail, lessThan(_kRowFitExplainWidth),
            reason: '★ 这一档的可用宽必须 < $_kRowFitExplainWidth 才叫"窄档"'
                '（实测 avail=${avail.toStringAsFixed(0)}）');
        expect(r.scrolls, 1,
            reason: '★ 窄档必须换形到「常驻项一行 + 条件项一行（横向滚动兜底）」'
                '⇒ 整页恰好 1 个横向 ScrollView。实测 scrolls=${r.scrolls} '
                '（0 = 还在单行 ⇒ 换形失效；>1 = 底栏之外又多出滚动容器，需人看）');
        expect(barRows.length, greaterThanOrEqualTo(2),
            reason: '★ 两行形态：至少量到 2 根有界横向行，实测 ${barRows.length} 根');

        expect(r.ovf, isEmpty,
            reason: '★ 这一档**不许**有 RenderFlex 溢出（缺陷期读数：900 ⇒ 243 px、'
                '960 ⇒ 183 px、1024 ⇒ 119 px）。实测：' + r.ovf.join(' / '));
        for (final x in barRows) {
          expect(x.maxRight, lessThanOrEqualTo(x.avail + 0.01),
              reason: '★ [' +
                  w.toInt().toString() +
                  '] 最右子项右缘不得超出行宽：' +
                  x.toString());
          expect(x.size, lessThanOrEqualTo(x.avail + 0.01),
              reason: '★ [' +
                  w.toInt().toString() +
                  '] 行自身宽度不得超出可用宽：' +
                  x.toString());
        }
        // ignore: avoid_print
        print('[t92] ${w.toInt()} rows=${r.rows.map((x) => x.toString()).join(' | ')} '
            'gear=${r.gear} scrolls=${r.scrolls}');
      });
    }
  });

  testWidgets('t92 ③ 边界：1152 dp 可用 774 ≥ $_kRowFitExplainWidth ⇒ 回到单行',
      (t) async {
    final r = await _probe(t, 1152);
    final barRows = r.rows.where((x) => x.avail.isFinite).toList();
    expect(barRows, isNotEmpty);
    expect(barRows.first.avail, greaterThanOrEqualTo(_kRowFitExplainWidth),
        reason: '★ 1152 的可用宽必须回到 ≥ $_kRowFitExplainWidth（实测 '
            '${barRows.first.avail.toStringAsFixed(0)}）');
    expect(r.scrolls, 0, reason: '★ 单行档不该有横向滚动兜底，实测 ${r.scrolls}');
    expect(r.ovf, isEmpty, reason: '★ 不许溢出：' + r.ovf.join(' / '));
    for (final x in barRows) {
      expect(x.maxRight, lessThanOrEqualTo(x.avail + 0.01),
          reason: '★ 最右子项右缘不得超出行宽：' + x.toString());
    }
    // ignore: avoid_print
    print('[t92] 1152 rows=${r.rows.map((x) => x.toString()).join(' | ')}');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ 尺子自证 —— 两条对照，缺一条本文件就可能恒绿
  // ══════════════════════════════════════════════════════════════════
  testWidgets('t92 ④-a 阴性对照：合成一个已知溢出的 Row ⇒ _guard 必须抓到', (t) async {
    // 反面：把 `_guard` 的 sink 丢掉 / 把 `contains('overflowed')` 写错 ⇒ 这条红。
    final sink = <String>[];
    await _guard(sink, () async {
      await t.pumpWidget(Directionality(
        textDirection: TextDirection.ltr,
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: 100,
            child: Row(children: const [SizedBox(width: 400, height: 10)]),
          ),
        ),
      ));
    });
    _claim(t);
    expect(sink.where((s) => s.contains('overflowed')), isNotEmpty,
        reason: '★★ 阴性对照失败：合成溢出没被 _guard 抓到 ⇒ 上面所有 '
            '"ovf 为空" 的断言都是空转（这条是本文件的尺子）');
  });

  testWidgets('t92 ④-b 阳性对照：旧档位标记必须**已不在**底栏（D 判定可复算）',
      (t) async {
    // 2026-10-25 判本文件「D 已过期」的依据就是这四个标记都没了。
    // 钉住它们 ⇒ 谁把「截图 / 弹幕设置 / 更多(竖点)」搬回底栏，这条会红，
    // 提醒重新评估本文件的档位判据（而不是让判据悄悄漂）。
    await _mountMedia(t, 1280, 900);
    final shot = find.byTooltip('截图').evaluate().length;
    final cam = find.byIcon(Icons.photo_camera).evaluate().length;
    final tune = find.byIcon(Icons.tune).evaluate().length;
    final mv = find.byIcon(Icons.more_vert).evaluate().length;
    // ignore: avoid_print
    print('[t92] 旧标记复算 shot=$shot cam=$cam tune=$tune more_vert=$mv');
    expect(shot + cam + tune + mv, 0,
        reason: '★ 四个旧标记应当**都不在**底栏：截图/弹幕设置已搬进「更多」菜单'
            '（player_page.dart:6385 / :6467），「更多」那枚是 more_horiz(0xe402) '
            '不是 more_vert(0xe404)。实测 shot=$shot cam=$cam tune=$tune '
            'more_vert=$mv ⇒ 若有任何一个非 0，说明产品或已回退，'
            '本文件的档位判据需要重新评估');
    await _moreFrames(t);
    _claim(t);
  });
}
