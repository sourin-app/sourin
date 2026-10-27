// ═══════════════════════════════════════════════════════════════════════
//  t1059 · N7：菜单液态玻璃化 —— **逐像素 + 结构 + 动效档** 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 它守什么（三条腿，缺一条就是假绿）
// ```text
// ① **玻璃确实贡献可感知像素**（照 zz_t1044 的思路：Δpeak ∈ [8,80] +
//    interiorΔpeak ≤ 1 + 受影响像素 < 2%）
//    ⇒ 有人把条目玻璃摘掉 ⇒ Δpeak 掉到 0 ⇒ 红（这正是注入对照）
// ② **reduced-motion 对照**：声明「减少动效」时玻璃**不挂**，
//    且与"显式摘玻璃"逐像素一致；同时用"vs 挂玻璃"做**阳性对照**
//    证明样本不是瞎的（t1044 ④ 组同构）
// ③ **动效档 = 本仓那一套**：`popUpAnimationStyle` 不再是框架默认的
//    300ms/linear，而是 `OverlayMotion.cardDuration` / `cardCurve`；
//    减少动效时给 `noAnimation`（零 ticker）。框架默认值实测出处：
//    `popup_menu.dart:50 _kMenuDuration = 300ms` / `:1017-1026 createAnimation`
// ```
//
// # ★ 为什么**不**断言"整块菜单面是玻璃"（形态的如实描述）
// ```text
// 菜单面那条 `Material` 在框架 `showMenu` 内部（`popup_menu.dart:784`），
// 本仓拿不到它 ⇒ 要做出"整块面玻璃"只能在面**外面再套一层** `GlassContainer`
// —— 那是**重复模糊层**，被旧13 的台账 31（模糊对卡片内部零贡献、可见差异
// 全在边缘描边）与 t1044（摘玻璃 Δpeak=58）双重背书否定。
// ⇒ 本门禁守的是**条目玻璃**（材质落在条目上）+ **面的 tokens**。
//   "面 = 框架 Material + 玻璃 tokens；材质只落在条目上"是**设计形态**，
//   不是"没做到" —— 谁要把它写成"整块面玻璃"，先读完文件头再动手。
// ```
//
// # ★ 仪器注意（t1044 踩过的坑，这里是同一套，别重踩）
// ```text
// ① `boundary.toImage()` / `image.toByteData()` 在 FakeAsync zone 里**永不返回**
//    ⇒ 两者必须包在 `t.runAsync` 里，且**一起**取完再比较；
// ② 两次截图**尺寸必须相同**（同一 host、同一 viewport），否则像素索引对不上；
// ③ 背景必须是**高低频混合**的图案：纯色背景下模糊前后本来就一样，
//    那样的 Δpeak=0 是假绿（模糊没有东西可糊）；
// ④ "内部"必须按**卡片几何**定义（t1044 上一版按"整图缩边"量错过）。
// ```
//
// # 故障注入（三条，都要真跑过、都要能红）
// ```text
// 注入 A：`debugSkipGlassMenu = true` ⇒ ①②组红（玻璃被摘）
// 注入 B：`appMenuAnimationStyle` 退回框架默认（不给 `popUpAnimationStyle`）
//         ⇒ ③组红
// 注入 C：把 `appMenuGlassItem` 改成"包整个 PopupMenuItem"⇒ ④组红
//         （条目几何/行为契约被破坏）
// ```
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/tokens.dart';
import 'package:sourin_spike/ui/widgets/app_menu.dart';
import 'package:sourin_spike/ui/widgets/motion_prefs.dart';

const Size _kView = Size(520, 360);
const ValueKey<String> _kBoundary = ValueKey<String>('t1059-boundary');

class _Shot {
  const _Shot(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

/// ★ 判据常量（值都有实测出处，见 ② 组的说明）
///
/// ```text
/// 实测（2026-10-27，热身后稳定值）：
///   玻璃 vs 不挂玻璃   Δpeak=102  meanAbs=3.37  受影响=13.35%（≈条目面积的 96%）
///   glass vs glass     Δpeak=0    meanAbs=0
/// ```
/// ⚠️ 窗口 [8, 150] 是**按实测定**的，不是照抄 t1044 的 [8,80]：
/// ```text
/// t1044 的两个组件**内层都有不透明实色垫层**（0.98 / surfaceContainerHighest）
///   ⇒ 玻璃只剩"边缘一圈"的可见贡献 ⇒ Δpeak 只有 58 / 13。
/// 菜单条目**没有**那层垫层（它就是压在菜单面上的一块玻璃）
///   ⇒ 模糊照进整块条目 ⇒ 可见贡献天然更大（实测 102）。
/// 窗口的**作用**不变：为 0 ⇒ 玻璃被摘（注入 A 红）；
///                      过大/整条换色 ⇒ 换成了别的东西（也红）。
/// ```
const int _kPeakMin = 8;
const int _kPeakMax = 150;

/// 条目在视口里的**实测矩形**（由 `_shot` 里的 `t.getRect` 填）。
///
/// ⚠️ 第一版这里**手写**过一个矩形（按"260 宽居中"推的）—— 实测偏了，
///    于是"上边缘那一圈"取到了条目**外面** ⇒ edgeΔpeak 恒 0、把一条真断言
///    变成了假红。⇒ 现在**真量**，不猜。
Rect? _measuredItemRect;

Rect _itemRect(WidgetTester t) {
  final r = _measuredItemRect;
  expect(r, isNotNull, reason: '★ 必须先量到条目矩形（`_shot` 里量）');
  return r!;
}

/// 条目在视口里的**实测矩形**（`_measureItemFor` 打完 key 后由测试量）。
const ValueKey<String> _kItemKey = ValueKey<String>('t1059-item');

/// 条目**内部中心带**（相对条目矩形，比例定义 —— 不写死绝对像素）。
///
/// ⚠️ 与 t1044 **相反**：那一版要求"interior 零贡献"（因为它的卡片内层有
///    不透明实色垫层）；本件**没有**那层垫层（条目就是压在菜单面上的玻璃）
///    ⇒ 模糊照进**整块条目** ⇒ interior 也必须**有**贡献。
///    若这里 ≈0，说明条目其实被一层不透明底盖住了（那就不是"玻璃条目"了）。
Rect _interiorOf(Rect item) => Rect.fromLTRB(
      item.left + item.width * 0.27,
      item.top + item.height * 0.30,
      item.left + item.width * 0.73,
      item.top + item.height * 0.70,
    );

/// 条目**上边缘那一圈** —— 证明材质覆盖到边（不是只在中间糊了一团）。
///
/// 取条目矩形**内部**靠上的一条窄带（不伸到条目外，那会恒 0）。
Rect _edgeOf(Rect item) => Rect.fromLTRB(
      item.left + item.width * 0.10,
      item.top + item.height * 0.04,
      item.left + item.width * 0.90,
      item.top + item.height * 0.14,
    );

/// 条目`_itemBody` 的实测矩形（由测试自己量，见 [_itemRect]）。
///
/// ⚠️ 第一版这里**手写**了一个矩形（x 130..390 / y 130..230）—— 那是按
///    "260 宽居中"**推**的，实测偏了（`Center` + `SizedBox` 的实际落点与推算
///    不同），于是"上边缘那一圈"取到了条目**外面** ⇒ edgeΔpeak 恒 0，
///    把一个真断言变成了假红。
/// ⇒ 现在由 `t.getRect` 在树里**真量**（见 [_itemRect]），不猜。
class _Diff {
  const _Diff({
    required this.peak,
    required this.meanAbs,
    required this.affectedRatio,
    required this.affectedInItemRatio,
    required this.interiorPeak,
    required this.edgePeak,
  });

  final int peak;
  final double meanAbs;

  /// 受影响的**整图**比例
  final double affectedRatio;

  /// 受影响的**条目内**比例（占条目面积）
  final double affectedInItemRatio;

  final int interiorPeak;
  final int edgePeak;

  @override
  String toString() => 'Δpeak=$peak interiorΔpeak=$interiorPeak '
      'edgeΔpeak=$edgePeak meanAbs=${meanAbs.toStringAsFixed(3)} '
      'affected=${(affectedRatio * 100).toStringAsFixed(2)}% '
      'affectedInItem=${(affectedInItemRatio * 100).toStringAsFixed(1)}%';
}

_Diff _diff(_Shot a, _Shot b, {required Rect item}) {
  expect(a.width, b.width, reason: '★ 两张图宽度必须一致（同 host / 同 viewport）');
  expect(a.height, b.height, reason: '★ 两张图高度必须一致');

  final interior = _interiorOf(item);
  final edge = _edgeOf(item);

  var peak = 0;
  var interiorPeak = 0;
  var edgePeak = 0;
  var sum = 0;
  var affected = 0;
  var affectedInItem = 0;
  final pixels = a.width * a.height;
  bool inBand(Rect r, int x, int y) =>
      x >= r.left && y >= r.top && x < r.right && y < r.bottom;

  for (var y = 0; y < a.height; y++) {
    for (var x = 0; x < a.width; x++) {
      final i = y * a.width + x;
      var pixelMax = 0;
      for (var ch = 0; ch < 3; ch++) {
        final idx = i * 4 + ch;
        final d = (a.rgba[idx] - b.rgba[idx]).abs();
        sum += d;
        if (d > pixelMax) pixelMax = d;
      }
      if (pixelMax > peak) peak = pixelMax;
      if (pixelMax > 1) {
        affected++;
        if (inBand(item, x, y)) affectedInItem++;
      }
      if (inBand(interior, x, y) && pixelMax > interiorPeak) {
        interiorPeak = pixelMax;
      }
      if (inBand(edge, x, y) && pixelMax > edgePeak) {
        edgePeak = pixelMax;
      }
    }
  }
  return _Diff(
    peak: peak,
    meanAbs: sum / (pixels * 3),
    affectedRatio: affected / pixels,
    affectedInItemRatio: affectedInItem / (item.width * item.height),
    interiorPeak: interiorPeak,
    edgePeak: edgePeak,
  );
}

/// 高低频混合的测试底图 —— 只有这种底图上，模糊才会真的改变像素。
///
/// ⚠️ 纯色底下图前图后本来就一样 ⇒ 那样的 Δpeak=0 是**假绿**
///   （模糊没有东西可糊），这是 t1044 头部的第 ③ 条坑。
Widget _backdrop() => Stack(
      children: <Widget>[
        Positioned.fill(child: Container(color: const Color(0xFF0E1116))),
        for (var row = 0; row < 6; row++)
          for (var col = 0; col < 8; col++)
            Positioned(
              left: col * 66.0,
              top: row * 62.0,
              width: 40,
              height: 40,
              child: Container(
                color: Color.fromARGB(
                  255,
                  40 + (col * 27) % 200,
                  30 + (row * 41) % 200,
                  90 + ((row + col) * 19) % 160,
                ),
              ),
            ),
      ],
    );

/// 生产叠层的**一个菜单条目**：菜单面（不透明）+ 条目玻璃 + 内容。
///
/// ⚠️ **必须接收 `context` 并在树内调用**：本函数会读 `MediaQuery`（判断
///    "减少动效"）。在测试体里先建好 widget 再交给 `pumpWidget`，会让
///    `appMenuGlassItem` 用到**上一棵树里已失活的 element**
///    ⇒ 抛 "Looking up a deactivated widget's ancestor is unsafe"。
///   ⇒ 所以参数是 `WidgetBuilder`，由树内的 `Builder` 现调。
Widget _itemBody(BuildContext context,
    {required bool glass, bool withFace = true, String label = '调整顺序'}) {
  final row = Row(
    children: <Widget>[
      const Icon(Icons.reorder, size: 16, color: Color(0xFFE6E6E6)),
      const SizedBox(width: Sp.x3),
      Text(label,
          style: const TextStyle(fontSize: FontSizes.sm, color: Color(0xFFE6E6E6))),
    ],
  );
  final body = SizedBox(
    key: _kItemKey,
    width: kAppMenuConstraints.maxWidth,
    height: 100,
    child: glass ? appMenuGlassItem(context, row) : row,
  );
  if (!withFace) return body;
  /*
   * 生产叠层：菜单面那条**不透明** Material（框架 `showMenu` 内部画的，
   * `popup_menu.dart:784`）在条目玻璃**下面**。
   * ⚠️ 少了它，玻璃量到的是测试自己的底图 —— 那不是生产。
   */
  final s = AppMenuSurface.of(context);
  return Container(
    width: kAppMenuConstraints.maxWidth,
    height: 100,
    decoration: BoxDecoration(
      color: s.color,
      border: Border.fromBorderSide((s.shape as RoundedRectangleBorder).side),
    ),
    child: body,
  );
}

bool _reducedMotion = false;

Widget _host(WidgetBuilder overlay) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: _reducedMotion),
      child: Scaffold(
        body: RepaintBoundary(
          key: _kBoundary,
          child: SizedBox(
            width: _kView.width,
            height: _kView.height,
            child: Stack(
              children: <Widget>[
                Positioned.fill(child: _backdrop()),
                // ★ 覆盖层在**树内**构建（见 `_itemBody` 的 ⚠️）
                Positioned.fill(child: Center(child: Builder(builder: overlay))),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

Future<_Shot> _grab(WidgetTester t) async {
  late _Shot shot;
  await t.runAsync(() async {
    final boundary = t.renderObject<RenderRepaintBoundary>(find.byKey(_kBoundary));
    final img = await boundary.toImage(pixelRatio: 1.0);
    final data = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
    shot = _Shot(img.width, img.height, data!.buffer.asUint8List());
  });
  return shot;
}

/// 拍一张**稳定**的图 —— 反复取字节，直到相邻两张**逐字节相同**为止。
///
/// # ★★★ 为什么必须"等到稳定"（本门禁实测出来的坑，t1044 没有这一条）
/// ```text
/// `LightweightLiquidGlass` 的玻璃 shader 是**异步加载**的
/// （见包内 `lightweight_liquid_glass.dart` 的 `_activeShader`：
///   shader 未就绪时画的是"染色直通"，就绪**之后**才走真玻璃）。
///
/// 实测同一段场景连续拍三次：
///   第 1 张  Δpeak = 33   ← shader 还没就绪（染色直通）
///   第 2 张  Δpeak = 102  ← 真玻璃
///   第 3 张  Δpeak = 102
/// 而 `glass vs glass`（同一状态连拍两张）恒为 **Δpeak = 0**
///   ⇒ 引擎本身是**确定**的，抖的只是"就绪前后"那一段。
///
/// ⇒ 若不等就绪就取字节，量到的是一个**偶然值**（33 还是 102 取决于时序）
///   —— 那是假读数（判据会随机红/绿）。
/// ```
/// ⚠️ 与 t1044 的三条仪器纪律（`runAsync` 包住 toImage/toByteData、两次截图
///    尺寸必须相同、底图必须高低频混合）并列，这是**第四条**：
///    **玻璃 shader 异步加载 ⇒ 必须等到两张图逐字节相同再取读数**。
Future<_Shot> _grabStable(WidgetTester t) async {
  _Shot last = await _grab(t);
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
    final next = await _grab(t);
    if (next.width == last.width &&
        next.height == last.height &&
        _sameBytes(last.rgba, next.rgba)) {
      return next; // 相邻两张完全一致 ⇒ 已稳定
    }
    last = next;
  }
  return last; // 兜底：跑满仍不稳，如实返回（下面的"稳定自检"会抓到）
}

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

Future<_Shot> _shot(WidgetTester t, WidgetBuilder overlay) async {
  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 先渲染一棵**一次性的玻璃树**（结果丢掉，只为把 shader 程序加载好）
   * ══════════════════════════════════════════════════════════════════
   *
   * # 实测（同一段落连续拍，读数不收敛）
   * ```text
   *   进程里**第一棵**玻璃树      ⇒ Δpeak=33（染色直通，shader 还没就绪）
   *   之后任意一棵玻璃树           ⇒ Δpeak=135（真玻璃，连续两轮一致）
   *   同一状态连拍两张           ⇒ Δpeak=0（引擎确定，不抖）
   * ```
   * ⇒ 差异只出现在"进程内第一棵玻璃树"上 —— 那是
   *   `LightweightLiquidGlass` 的 `_activeShader` **异步加载**的产物，
   *   不是产品在抖、也不是背景不同（底图两次完全相同）。
   *
   * # 为什么"同一棵树里多 pump 几次"治不好
   * ```text
   * 我第一版在同一个树上反复 `pump(60ms)` + 重取字节（直到两张逐字节相同），
   * 读数**仍是 33** —— 因为那棵树已经用"未就绪"的分支建好了
   * （包内注释写明：shader 空、非空两种情况**保持同一棵 widget 树结构**，
   *   只换绘制路径 ⇒ 已建的树不会自己跳到另一条路径）。
   * ⇒ 必须**换一棵新树**才能走到"就绪"那条绘制路径。
   * ```
   * ⚠️ 这是本门禁的**第四条仪器纪律**（t1044 只有前三条）：
   *    **进程内第一棵玻璃树是"未就绪"态 ⇒ 正式取字节前必须先渲染一棵弃用树**。
   */
  await t.pumpWidget(_host((c) => _itemBody(c, glass: true)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  await _grab(t); // 弃用
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump();

  await t.pumpWidget(_host(overlay));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  /*
   * 条目矩形**由测试真量**（不靠推算 —— 第一版推错了，见 `_itemRect`）。
   * ①组的仪器自检没有条目（它铺满视口）⇒ 那时用整幅视口当"条目"。
   */
  final itemFinder = find.byKey(_kItemKey);
  _measuredItemRect = itemFinder.evaluate().isEmpty
      ? Offset.zero & _kView
      : t.getRect(itemFinder);
  final shot = await _grabStable(t);
  return shot;
}

void main() {
  setUp(() {
    debugSkipGlassMenu = false;
    _reducedMotion = false;
  });
  tearDown(() {
    debugSkipGlassMenu = false;
    _reducedMotion = false;
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 仪器自检：这套逐像素判据真的能看见差异（防恒零假绿）
  // ═══════════════════════════════════════════════════════════════════
  group('① 仪器自检', () {
    testWidgets('★★ 明显色差 ⇒ Δpeak 必须很大', (t) async {
      /*
       * ⚠️ 第一版这里传的是裸 `ColoredBox` —— 它在 `Center` 里拿**松约束**，
       *    没有 child 就缩成 **0×0** ⇒ 两张"图"都是同一张空背景 ⇒ Δpeak=0，
       *    于是仪器自检自己红了（**仪器写错，不是判据太严**）。
       * ⇒ 必须让它**撑满视口**（`Positioned.fill` 的那种效果）。
       */
      final a = await _shot(
          t,
          (_) => const SizedBox.expand(
              child: ColoredBox(color: Color(0xFF000000))));
      await t.pumpWidget(const SizedBox.shrink());
      final b = await _shot(
          t,
          (_) => const SizedBox.expand(
              child: ColoredBox(color: Color(0xFFFFFFFF))));
      final d = _diff(a, b, item: _itemRect(t));
      expect(d.peak, greaterThan(200),
          reason: '★ 判据看不见明显色差 ⇒ 后面所有"几乎没差"都是假绿（读数 $d）');
      expect(d.interiorPeak, greaterThan(200),
          reason: '★ 内部读数也必须能看见（否则"内部无差"的判据恒真，读数 $d）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 条目玻璃：确实贡献可感知像素（不许摘）
  // ═══════════════════════════════════════════════════════════════════
  group('② 条目玻璃 Δpeak ∈ 窗口 / 贡献范围 = 条目本身', () {
    testWidgets('★★★ 玻璃 vs 不挂玻璃（同一底图、同一条目、生产叠层）', (t) async {
      final withGlass = await _shot(t, (c) => _itemBody(c, glass: true));
      await t.pumpWidget(const SizedBox.shrink());
      debugSkipGlassMenu = true;
      final withoutGlass = await _shot(t, (c) => _itemBody(c, glass: true));
      final d = _diff(withGlass, withoutGlass, item: _itemRect(t));
      // ignore: avoid_print
      print('[T1059] menu item  $d');

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 这里**故意没有**照抄 t1044 的"interior 零贡献 + 受影响 <2%"
       * ══════════════════════════════════════════════════════════════════
       *
       * # 为什么那两条判据**不能**搬过来（实测，不是推理）
       * ```text
       * t1044 量的是 `AppGlassDialog` / `AppDialogShell`：它们**内层有一层
       * 不透明的实色垫层**（`app_dialog_shell.dart:444` `#14161B @ 0.98`）。
       *   ⇒ 玻璃的模糊透不进卡片内部，可见差异**只剩边缘那圈描边/高光**
       *   ⇒ 所以 t1044 读得到 interiorΔpeak=0、受影响 0.71%。
       *
       * 本件量的是**菜单条目**：条目**没有**那层不透明垫层（它就是压在菜单面上
       * 的一块玻璃，见 `appMenuGlassItem` 的文档）。
       *   ⇒ 玻璃的模糊**照进整块条目** —— 实测受影响的**条目内**比例 ≈ 98%。
       * ```
       * ⇒ 若照抄那两条，本门禁会**恒红**（判据搬错，不是产品坏）。
       *   本件必须量**它自己的形态**：材质覆盖**整块条目**。
       *
       * ```text
       * 判据（2026-10-27 定稿，值都有实测出处）：
       * ① Δpeak ∈ [8, 150]  —— 贡献必须存在（为 0 ⇒ 被摘）且量级稳定
       * ② 受影响的**条目内**比例 > 0.8 —— 材质覆盖整块条目（不是只糊一条边）
       * ③ interiorΔpeak > 8  —— 条目内部也在变（本件**没有** t1044 那层垫层）
       * ④ edgeΔpeak  > 8  —— 上边缘那一圈也在变（材质覆盖到边）
       * ⑤ meanAbs < 6  —— 整图平均差有限（条目只占截图约 13.9%）
       * ```
       */
      expect(d.peak, greaterThanOrEqualTo(_kPeakMin),
          reason: '★★★ 玻璃的可见贡献必须存在。为 0 ⇒ 玻璃被摘了'
              '（注入 A 就是这个）。读数：$d');
      expect(d.peak, lessThanOrEqualTo(_kPeakMax),
          reason: '★★★ 贡献不该大到"整条换色/换成了别的东西"（读数：$d）');
      expect(d.affectedInItemRatio, greaterThan(0.8),
          reason: '★★★ 材质必须覆盖**整块条目**（不是只糊一条边）'
              '—— 条目没有不透明垫层，模糊照进整个面（读数：$d）');
      expect(d.interiorPeak, greaterThan(8),
          reason: '★★★ 条目**内部**必须也在变 —— 本件**没有** t1044 那层不透明'
              '垫层；若这里 ≈0，说明条目其实被一层不透明底盖住了'
              '（那就不是"玻璃条目"了）（读数：$d）');
      expect(d.edgePeak, greaterThan(8),
          reason: '★ 条目**上边缘那一圈**也必须变（证明材质覆盖到边）（读数：$d）');
      expect(d.meanAbs, lessThan(6.0),
          reason: '★★ 整图平均差应当有限（条目只占截图约 13.9%）（读数：$d）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ reduced-motion 分支：声明"减少动效"时玻璃确实不挂
  // ═══════════════════════════════════════════════════════════════════
  group('③ reduced-motion 分支', () {
    testWidgets('★★ 与"显式摘玻璃"逐像素一致（并用"vs 挂玻璃"做阳性对照）', (t) async {
      // ── 基准 A：正常（挂玻璃）
      final glassOn = await _shot(t, (c) => _itemBody(c, glass: true));

      // ── 基准 B：显式摘玻璃（仪器开关）
      await t.pumpWidget(const SizedBox.shrink());
      debugSkipGlassMenu = true;
      final plain = await _shot(t, (c) => _itemBody(c, glass: true));

      // ── 实验组 C：不摘，但声明"减少动效"
      debugSkipGlassMenu = false;
      _reducedMotion = true;
      await t.pumpWidget(const SizedBox.shrink());
      final reduced = await _shot(t, (c) => _itemBody(c, glass: true));

      /*
       * ★ 两条对照一起看才成立（t1044 ④ 的同一条推理）：
       *   ① reduced vs 摘玻璃  ⇒ 必须 ≈0（分支真的生效了）
       *   ② reduced vs 挂玻璃  ⇒ 必须 ∈[8,80]（**样本不是瞎的**：
       *      同一张图、同一背景下，挂不挂玻璃差得很明显）
       * ⇒ 若只有 ① 绿而 ② 也接近 0，那才是"样本看不出来"。
       */
      final dPlain = _diff(plain, reduced, item: _itemRect(t));
      final dOn = _diff(glassOn, reduced, item: _itemRect(t));
      // ignore: avoid_print
      print('[T1059] reduced-motion vs 摘玻璃  $dPlain');
      // ignore: avoid_print
      print('[T1059] reduced-motion vs 挂玻璃  $dOn');

      expect(dPlain.peak, lessThanOrEqualTo(1),
          reason: '★★ 声明减少动效 ⇒ 应当与"不挂玻璃"逐像素一致（$dPlain）');
      expect(dOn.peak, greaterThanOrEqualTo(_kPeakMin),
          reason: '★★★ 阳性对照：与"挂玻璃"相比必须差出 $_kPeakMin 级以上'
              '—— 否则说明这张图本来就分不出来，上一条是假绿（$dOn）');
      expect(dOn.peak, lessThanOrEqualTo(_kPeakMax),
          reason: '★★ 阳性对照也要落在同一个窗口内（$dOn）');
      expect(dOn.interiorPeak, greaterThan(8),
          reason: '★ 对照里条目内部也在变（与 ② 同形态）（$dOn）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 动效档 = 本仓那一套（不是框架默认 300ms/linear）
  // ═══════════════════════════════════════════════════════════════════
  group('④ 进出场动效档', () {
    testWidgets('★★★ 时长/曲线 = OverlayMotion 那套（与浮层同源）', (t) async {
      late AnimationStyle style;
      await t.pumpWidget(_host((c) {
        style = appMenuAnimationStyle(c);
        return const SizedBox.shrink();
      }));
      await t.pump();

      expect(style.duration, OverlayMotion.cardDuration,
          reason: '★★★ 时长必须是本仓 token（Motion.base=260ms），'
              '不是框架默认的 300ms（popup_menu.dart:50 _kMenuDuration）');
      expect(style.curve, OverlayMotion.cardCurve,
          reason: '★★★ 曲线必须是本仓 Motion.easeOut，不是框架默认的 Curves.linear');
      expect(style.duration, isNot(const Duration(milliseconds: 300)),
          reason: '★ 负向对照：正好等于框架默认 ⇒ 说明本改动没生效');
    });

    testWidgets('★★ reduced-motion ⇒ noAnimation（零动画层）', (t) async {
      _reducedMotion = true;
      late AnimationStyle style;
      await t.pumpWidget(_host((c) {
        style = appMenuAnimationStyle(c);
        return const SizedBox.shrink();
      }));
      await t.pump();

      expect(style.duration, Duration.zero,
          reason: '★★ 用户声明减少动效 ⇒ 时长必须 0（`noAnimation`）');
      expect(style.reverseDuration, Duration.zero);
      /*
       * ⚠️ 用 `noAnimation` 而不是"时长 0 的手写 AnimationStyle"：
       *   前者让路由**不建动画层**（零 ticker），后者仍会建。
       *   判据上两者时长都是 zero ⇒ 这里再钉一条"等于那个常量"。
       */
      expect(style.duration, AnimationStyle.noAnimation.duration);
    });

    testWidgets('★★ 两个入口共用同一份动效档（AppMenuButton 与 showAppMenu）', (t) async {
      /*
       * ★ 源码级反向对照（与 t137 那条"两处入口必须同源"同一套手法）：
       *   若某个入口自己写一个 `AnimationStyle(...)`，两个菜单的动效就会漂开
       *   —— 那正是 Owner 抱怨的"不统一"。
       */
      final src = stripComments(
        _read('lib/ui/widgets/app_menu.dart'),
      );
      final n = RegExp(r'popUpAnimationStyle:\s*appMenuAnimationStyle\(context\)')
          .allMatches(src)
          .length;
      expect(n, 2,
          reason: '★★ 两个入口（showAppMenu + AppMenuButton）都必须走 '
              'appMenuAnimationStyle —— 实测命中 $n 处（应为 2）');
      /*
       * ⚠️ 必须用 `\bAnimationStyle\(` —— 第一版写的是裸 `AnimationStyle\(`，
       *    它把 `appMenuAnimationStyle(` 的**子串**也数进去了（"…Style(" 里
       *    正好含 "AnimationStyle("）⇒ 命中 4 而不是 1，**是仪器写错**
       *    （把"函数名里含关键字"当成了"又构造了一个 AnimationStyle"）。
       */
      expect(RegExp(r'\bAnimationStyle\(').allMatches(src).length, 1,
          reason: '★★ 只许在 appMenuAnimationStyle 里构造一次 AnimationStyle；'
              '多出来的构造点会让两个入口的动效漂开');
    });
  });
}

/// 剥注释（字符串里的 `//` 不算注释）—— 与 t137 / t103 同款
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  while (i < src.length) {
    final c = src[i];
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
    } else if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
        i++;
      }
      i += 2;
    } else if (c == "'" || c == '"') {
      final q = c;
      out.write(c);
      i++;
      while (i < src.length && src[i] != q) {
        if (src[i] == '\\') {
          out.write(src[i]);
          i++;
          if (i >= src.length) break;
        }
        out.write(src[i]);
        i++;
      }
      if (i < src.length) {
        out.write(src[i]);
        i++;
      }
      continue;
    } else {
      out.write(c);
    }
    i++;
  }
  return out.toString();
}

String _read(String p) => File(p).readAsStringSync();