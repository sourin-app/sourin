// ═══════════════════════════════════════════════════════════════════════
//  R2-#4 · N9 渠道条的**液态玻璃** —— 逐像素 + 结构 + reduced-motion 门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 权威依据
// Owner 2026-10-27 在场亲测（`.probe/owner-review-r2-feedback.md` 第 4 条，逐字）：
// ```text
// > 4.二级横向渠道条应该还是液态玻璃
// ```
// 任务卡 `task-8`（R2-#4）四条硬约束。
//
// # 这条门禁守什么（三条腿，缺一条就是假绿）
// ```text
// ① **玻璃确实贡献可感知像素**：挂玻璃 vs 不挂玻璃，Δpeak 落在窗口内、
//    且**整条**都受影响（内层药丸是透明的 ⇒ 模糊照进整条带）。
//    ⇒ 有人把玻璃摘掉（注入 A：debugSkipGlassAggChannelRail=true）
//      ⇒ Δpeak 掉到 0 ⇒ **红**。
// ② **reduced-motion 对照**：声明「减少动效」时玻璃**不挂**，
//    且与"显式摘玻璃"逐像素一致；同时用"vs 挂玻璃"做**阳性对照**
//    证明样本不是瞎的。
// ③ **结构**：玻璃容器**恰好一层**、且在 `SourinHorizontalRail` **外面**；
//    药丸里**没有**第二层 `GlassContainer`（不许引重复模糊层，旧13）。
// ```
//
// ══════════════════════════════════════════════════════════════════════
//  ★★ 为什么判据**不能**照抄 `zz_t1044` / `zz_t1059`（形态不同）
// ══════════════════════════════════════════════════════════════════════
//
// N7 笔记第 ② 条逐字记着：「`zz_t1044` 的两条像素判据**不能直接搬**」。
// 本件是**第三种形态**，两个窗口参数都得按它自己定：
//
// ```text
// 形态对照（三件都不同）：
//   t1044 对话框外壳：内层有**不透明实色垫层**（#14161B@0.98）
//                    ⇒ 玻璃只剩边缘一圈可见（Δpeak 58 / interiorΔpeak ≤ 1）
//   t1059 菜单条目  ：没有垫层，条目就是压在菜单面上的一块玻璃
//                    ⇒ 模糊照进整块条目（Δpeak 102 / affectedInItem 97.9%）
//   本件  渠道条胶囊：**药丸是透明的**（材质在外层 GlassContainer 上），
//                    且玻璃轮廓**只在切口内切到内容**（superellipse 999）
//                    ⇒ 模糊同样照进整条；但**带比条目矮**（44 vs 40+ 行），
//                      且左右两端是**全圆角**（被切掉一圈）
//                    ⇒ interior/edge 两个带的**比例**要按 44 高的窄带重定。
// ```
// ⇒ 本文件按实测重定窗口与带，并在下面逐条写明**为什么是这个数**
//   （不是照抄别人的数）。
//
// ══════════════════════════════════════════════════════════════════════
//  ★★★ 仪器纪律（前四条来自 t1044/t1059，第⑤条是本件新增）
// ══════════════════════════════════════════════════════════════════════
// ```text
// ① `boundary.toImage()` / `image.toByteData()` 在 FakeAsync zone 里**永不返回**
//    ⇒ 两者必须包在 `t.runAsync` 里，且**一起**取完再比较；
// ② 两次截图**尺寸必须相同**（同一 host / 同一 viewport），否则像素索引对不上；
// ③ 背景必须是**高低频混合**的图案：纯色背景下模糊前后本来就一样，
//    那样的 Δpeak=0 是假绿（模糊没有东西可糊）；
// ④ ★ 玻璃 shader **异步加载** ⇒ 进程内**第一棵**玻璃树画的是"染色直通"
//    （实测 33 vs 135）⇒ 正式取字节前**必须先渲染一棵弃用树**；
// ⑤ ★★ **本件新增**：`GlassContainer` 在 `flutter_test` 里**需要 `GlassPage`
//    之类的祖先**才走真玻璃路径吗？—— 实测结论：**不需要**（见 `_host` 的说明），
//    但**必须**给它一个**有界的**父约束：`GlassContainer` 的模糊采样依赖
//    `RenderRepaintBoundary` 的尺寸，无界约束下 `toImage` 会拿到空图 ⇒
//    读数为 0（那是仪器坏，不是产品坏）。本文件用固定 viewport + 固定高度规避。
// ```
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/home_page.dart';
import 'package:sourin_spike/ui/widgets/sourin_scroll_behavior.dart';

const Size _kView = Size(520, 300);
const ValueKey<String> _kBoundary = ValueKey<String>('r2n9-boundary');
const ValueKey<String> _kRailKey = ValueKey<String>('r2n9-rail');

class _Shot {
  const _Shot(this.width, this.height, this.rgba);
  final int width;
  final int height;
  final Uint8List rgba;
}

// ── 判据窗口（值都有实测出处，见 ① 组的说明）────────────────────────────
//
// ```text
// 实测（2026-10-27，先渲染弃用树之后的热身稳定值）：
//   挂玻璃 vs 不挂玻璃   Δpeak≈104   meanAbs>1.5   受影响>10%（整条带）
//   glass vs glass       Δpeak=0     （引擎确定，不抖）
//   reduced vs 摘玻璃    Δpeak=0     （逐像素一致）
//   reduced vs 挂玻璃    Δpeak≈104   （阳性对照）
// ```
//
// ⚠️ 窗口 `[8, 150]`：**不是照抄** t1044(80) / t1059(150)，而是本件实测后取的
//    同量级窗口。窗口的**作用**不变：
// ```text
// 为 0   ⇒ 玻璃被摘了（注入 A 红）
// 过大   ⇒ 换成了别的东西（例如整条被不透明底盖住）—— 也红
// ```
const int _kPeakMin = 8;
const int _kPeakMax = 150;

/// 渠道条玻璃容器在视口里的**实测矩形**（由 `_shot` 用 `t.getRect` 真量填入）
Rect? _measuredRect;

Rect _rect(WidgetTester t) {
  final r = _measuredRect;
  expect(r, isNotNull, reason: '★ 必须先量到渠道条矩形（`_shot` 里量）');
  return r!;
}

/// 条的**内部中心带** —— 相对条矩形**按比例**定义（不写死绝对像素）
///
/// ⚠️ 与 t1059 的 `_interiorOf`（0.27~0.73 / 0.30~0.70）**不同值**：
///    本件条高只有 **44**（t1059 条目高 ~48~52），且左右端是全圆角
///    ⇒ 先横向量到 0.15~0.85（避开圆角切掉的两端）、纵向 0.25~0.75。
///    若这里 ≈0 ⇒ 说明条里其实有一层不透明底把模糊盖住了（那就不是玻璃条）。
Rect _interiorOf(Rect r) => Rect.fromLTRB(
      r.left + r.width * 0.15,
      r.top + r.height * 0.25,
      r.left + r.width * 0.85,
      r.top + r.height * 0.75,
    );

/// 条的**上边缘带** —— 证明材质覆盖到边（不是只在中间糊了一团）
///
/// ⚠️ 取条矩形**内部**靠上的一条窄带（不伸到条外，那会恒 0 —— t1059 踩过）。
Rect _edgeOf(Rect r) => Rect.fromLTRB(
      r.left + r.width * 0.15,
      r.top + r.height * 0.06,
      r.left + r.width * 0.85,
      r.top + r.height * 0.20,
    );

class _Diff {
  const _Diff({
    required this.peak,
    required this.meanAbs,
    required this.affectedInRail,
    required this.interiorPeak,
    required this.edgePeak,
  });

  final int peak;
  final double meanAbs;

  /// 受影响的**条内**比例（占条面积）—— 材质覆盖的广度
  final double affectedInRail;
  final int interiorPeak;
  final int edgePeak;

  @override
  String toString() => 'Δpeak=$peak interiorΔpeak=$interiorPeak '
      'edgeΔpeak=$edgePeak meanAbs=${meanAbs.toStringAsFixed(3)} '
      'affectedInRail=${(affectedInRail * 100).toStringAsFixed(1)}%';
}

_Diff _diff(_Shot a, _Shot b, {required Rect rail}) {
  expect(a.width, b.width, reason: '★ 两张图宽度必须一致（同 host / 同 viewport）');
  expect(a.height, b.height, reason: '★ 两张图高度必须一致');

  final interior = _interiorOf(rail);
  final edge = _edgeOf(rail);

  var peak = 0;
  var interiorPeak = 0;
  var edgePeak = 0;
  var sum = 0;
  var affectedInRail = 0;
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
      if (pixelMax > 1 && inBand(rail, x, y)) affectedInRail++;
      if (inBand(interior, x, y) && pixelMax > interiorPeak) {
        interiorPeak = pixelMax;
      }
      if (inBand(edge, x, y) && pixelMax > edgePeak) edgePeak = pixelMax;
    }
  }
  final railArea = (rail.width * rail.height).clamp(1, double.infinity);
  return _Diff(
    peak: peak,
    meanAbs: sum / (pixels * 3),
    affectedInRail: affectedInRail / railArea,
    interiorPeak: interiorPeak,
    edgePeak: edgePeak,
  );
}

/// 高低频混合的测试底图 —— 只有这种底图上，模糊才会真的改变像素。
///
/// ⚠️ 纯色底下图前图后本来就一样 ⇒ 那样的 Δpeak=0 是**假绿**
///  （模糊没有东西可糊），这是 t1044 头部的第 ③ 条坑。
Widget _backdrop() => Stack(
      children: <Widget>[
        Positioned.fill(child: Container(color: const Color(0xFF0E1116))),
        for (var row = 0; row < 6; row++)
          for (var col = 0; col < 8; col++)
            Positioned(
              left: col * 66.0,
              top: row * 52.0,
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

/// 造几个渠道（名字长度不一 ⇒ 条宽随内容变，更接近真实）
List<AggChannel> _channels() => <AggChannel>[
      AggChannel.fromJson({'id': 'c1', 'name': '子站甲', 'enabled': true})!,
      AggChannel.fromJson({'id': 'c2', 'name': '子站乙乙', 'enabled': true})!,
      AggChannel.fromJson({'id': 'c3', 'name': '子站丙丙丙', 'enabled': true})!,
      AggChannel.fromJson({'id': 'c4', 'name': '子站丁', 'enabled': true})!,
    ];

/// 生产叠层：底图 + **渠道条那一条**（走**产品路径** `AggChannelsBlock`）
///
/// # 为什么挂整块 `AggChannelsBlock` 而不是只挂 rail
/// ```text
/// `_AggChannelRail` 是**私有**（`_` 前缀）⇒ 门禁够不到。
/// 而玻璃层在 rail 里面/外面这件事**只有**走生产路径才能验到
///   ⇒ 挂 `AggChannelsBlock`（它内部就画这条条）。
/// ★ 与既有 N9 门禁同一条做法（那也是真挂载 AggChannelsBlock）。
/// ```
/// # 为什么不需要 `GlassPage` 祖先（本文件新增的第 ⑤ 条仪器说明）
/// ```text
/// 本仓其它玻璃点（shell / source_bar）在生产里也**没有**套 `GlassPage`
/// —— `GlassContainer(useOwnLayer: false)` 的默认路径在无 `GlassPage` 时
///   走**逐容器**的 group，实测能画出真玻璃（本文件的 ① 组就是证据：
///   挂 vs 不挂 Δpeak≈104，若走"直通"那条路径差会是 0）。
/// ⇒ 门禁不该为了"让玻璃生效"而改变生产树形态（那会验到一棵用户看不到的树）。
/// ```
Widget _host(WidgetBuilder strip) => Directionality(
      textDirection: TextDirection.ltr,
      child: MediaQuery(
        data: const MediaQueryData(size: _kView),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          home: Scaffold(
            backgroundColor: const Color(0xFF0E1116),
            body: RepaintBoundary(
              key: _kBoundary,
              child: SizedBox(
                width: _kView.width,
                height: _kView.height,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(child: _backdrop()),
                    Positioned(
                      left: 0,
                      top: 80,
                      width: _kView.width,
                      /*
                       * ⚠️ 高度给**够**（不是 44）：`AggChannelsBlock` 是个 Column
                       *    （渠道条 44 + 间距 + 该渠道的区块），塞进 44 高的槽
                       *    会 `RenderFlex overflowed` —— 那是**夹具**的错，
                       *    不是产品的错（实测抓到过：报 overflow 36px）。
                       * ⇒ 给足高度，让它自然布局；测量时只取**渠道条那一条**
                       *    （`find.byType(SourinHorizontalRail)`）的矩形。
                       */
                      height: 200,
                      // ★ 覆盖层在**树内**构建（读 MediaQuery 判断 reduced-motion；
                      //   在测试体里先建好再 pump 会拿上一棵树的失活 element）
                      child: Builder(builder: strip),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );

/// 一条渠道条（**走产品路径**）—— `glass` 决定玻璃挂不挂
///
/// ⚠️ 渠道清单走**既有的** `debugSetAggChannelFetchers` 注入点
///    （N9 那条门禁建的，生产恒 null ⇒ 真 FFI）。本门禁只验**视觉**，
///    不重造第二个数据 seam（那会让两个文件各自维护一份契约）。
Widget _stripBody(
  BuildContext context, {
  required bool glass,
  bool reducedMotion = false,
}) {
  debugSkipGlassAggChannelRail = !glass;
  final inner = SizedBox(
    key: _kRailKey,
    height: 44,
    child: AggChannelsBlock(
      provider: kTvboxAggregateId,
      onOpenDetail: (_) {},
      itemsOf: (_, __) => const <MediaItem>[],
      loadItems: (Section s) async {},
    ),
  );
  if (!reducedMotion) return inner;
  // ★ 声明「减少动效」：只改 MediaQuery，**不改**产品判据
  //   （产品那侧走 MotionPrefs.reduce ⇒ disableAnimations）
  return MediaQuery(
    data: const MediaQueryData(size: _kView, disableAnimations: true),
    child: inner,
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

bool _sameBytes(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// 拍一张**稳定**的图 —— 反复取字节，直到相邻两张**逐字节相同**
///
/// 见文件头第 ④ 条：玻璃 shader 异步加载 ⇒ 不等就绪会量到**偶然值**。
Future<_Shot> _grabStable(WidgetTester t) async {
  _Shot last = await _grab(t);
  for (var i = 0; i < 8; i++) {
    await t.pump(const Duration(milliseconds: 60));
    final next = await _grab(t);
    if (next.width == last.width &&
        next.height == last.height &&
        _sameBytes(last.rgba, next.rgba)) {
      return next;
    }
    last = next;
  }
  return last;
}

/// 出图：**先渲染一棵弃用树**（把 shader 程序加载好），再挂目标树
///
/// 见文件头第 ④ 条（t1059 的四条仪器纪律之一）。
Future<_Shot> _shot(
  WidgetTester t, {
  required bool glass,
  bool reducedMotion = false,
}) async {
  // ① 弃用树（结果丢掉，只为 shader 就绪）
  await t.pumpWidget(_host((c) => _stripBody(c, glass: true)));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
  await _grab(t); // 弃用
  await t.pumpWidget(const SizedBox.shrink());
  await t.pump();

  // ② 正式树
  await t.pumpWidget(
    _host((c) => _stripBody(c, glass: glass, reducedMotion: reducedMotion)),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));

  /*
   * 条矩形**由测试真量**（不靠推算 —— t1059 第一版推错、把真断言变假红）。
   *
   * ⚠️ 量的是**渠道条那一条**（`find.byType(SourinHorizontalRail)` 的**最外层**
   *    玻璃胶囊），不是 `AggChannelsBlock` 整块 —— 后者还含下面的内容区，
   *    整块当"条"会让"条内受影响比例"被内容区的空白稀释（假读数）。
   *    高度本来就是 44（`SizedBox(height: 44)`）⇒ 量到的是那条胶囊。
   */
  final railFinder = find.byType(SourinHorizontalRail).first;
  _measuredRect = t.getRect(railFinder);
  return _grabStable(t);
}

void main() {
  setUp(() {
    debugSkipGlassAggChannelRail = false;
    // ★ 渠道清单：用 N9 门禁建的那个注入点（生产恒 null ⇒ 真 FFI）
    debugSetAggChannelFetchers(
      channels: () async =>
          AggChannelsPayload(ok: true, channels: _channels()),
      channelHome: (id) async =>
          AggChannelHome(ok: true, channelId: id, channelName: '子站$id'),
    );
  });
  tearDown(() {
    // ★ 注入点必须复原（进程级，泄漏会影响同进程后面跑的文件）
    debugSkipGlassAggChannelRail = false;
    debugSetAggChannelFetchers();
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ⓪ 仪器自检（防"判据空转"）
  // ═══════════════════════════════════════════════════════════════════
  group('★ R2-#4 ⓪ 仪器自检', () {
    testWidgets('样本不是瞎的：同一状态连拍两张必须逐字节一致', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final a = await _shot(tester, glass: true);
      final b = await _shot(tester, glass: true);
      final d = _diff(a, b, rail: _rect(tester));
      expect(
        d.peak,
        0,
        reason: '★★ 引擎必须**确定**：同一状态两张图逐像素一致。\n'
            '不为 0 ⇒ 本门禁读数是噪声（后面所有断言都不可信）。',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 玻璃真的贡献可感知像素（注入 A 的落点）
  // ═══════════════════════════════════════════════════════════════════
  group('★ R2-#4 ① 玻璃贡献可感知像素', () {
    testWidgets('★★★ 挂玻璃 vs 不挂玻璃：Δpeak 在窗口内 + 材质覆盖整条', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final withGlass = await _shot(tester, glass: true);
      final without = await _shot(tester, glass: false);
      final d = _diff(withGlass, without, rail: _rect(tester));

      // eslint-disable-next-line avoid_print
      print('R2N9_GLASS_DIFF $d');

      expect(
        d.peak,
        greaterThanOrEqualTo(_kPeakMin),
        reason: '★★★ 玻璃必须贡献**可感知**像素（Δpeak ≥ $_kPeakMin）。\n'
            '为 0 ⇒ 玻璃被摘了（注入 A）⇒ 本条红。实际：$d',
      );
      expect(
        d.peak,
        lessThanOrEqualTo(_kPeakMax),
        reason: '★★ Δpeak ≤ $_kPeakMax：过大说明换成了别的东西'
            '（例如整条被不透明底盖住）。实际：$d',
      );
      expect(
        d.interiorPeak,
        greaterThan(8),
        reason: '★★★ **条内部**也必须有贡献（interiorΔpeak > 8）。\n'
            '≈0 说明条里有一层不透明底把模糊盖住了 —— 那就**不是玻璃条**。\n'
            '★ 与 t1044 的"interior 零贡献"**相反**：那件的内层有不透明垫层，'
            '本件的药丸是透明的（材质在外层）⇒ 模糊照进整条。实际：$d',
      );
      expect(
        d.edgePeak,
        greaterThan(4),
        reason: '★ 上边缘那一圈也要有贡献（材质覆盖到边，不是只在中间糊一团）。\n'
            '实际：$d',
      );
      expect(
        d.affectedInRail,
        greaterThan(0.10),
        reason: '★★★ 受影响的**条内**像素必须 > 10%（材质覆盖整条，不是一条细线）。\n'
            '实际：$d',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② reduced-motion 档不挂玻璃（旧13 的取舍）
  // ═══════════════════════════════════════════════════════════════════
  group('★ R2-#4 ② reduced-motion 档不挂玻璃', () {
    testWidgets('★★★ 声明减少动效 ⇒ 与"显式摘玻璃"逐像素一致', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final reduced = await _shot(tester, glass: true, reducedMotion: true);
      final without = await _shot(tester, glass: false);
      final d = _diff(reduced, without, rail: _rect(tester));
      expect(
        d.peak,
        0,
        reason: '★★★ reduced-motion 档必须**真的不挂玻璃** —— '
            '与"显式摘玻璃"逐像素一致（Δpeak=0）。\n'
            '不为 0 ⇒ 该档没生效（那是对"减少动效"用户的承诺没兑现）。实际：$d',
      );
    });

    testWidgets('★★ 阳性对照：reduced 档 vs 挂玻璃**必须不同**', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final reduced = await _shot(tester, glass: true, reducedMotion: true);
      final withGlass = await _shot(tester, glass: true);
      final d = _diff(reduced, withGlass, rail: _rect(tester));
      expect(
        d.peak,
        greaterThanOrEqualTo(_kPeakMin),
        reason: '★★ 阳性对照：若 reduced 档与"挂玻璃"也一样，'
            '说明上面那条 Δpeak=0 是**因为样本本身就没差异**（假绿）。\n'
            '实际：$d',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 结构：材质**只落一层**，且在 rail 外面
  // ═══════════════════════════════════════════════════════════════════
  group('★ R2-#4 ③ 结构：材质只落一层', () {
    testWidgets('★★★ 渠道条里恰好 **1 个** GlassContainer（不引重复模糊层）', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _shot(tester, glass: true);

      final n = find
          .descendant(
            of: find.byType(AggChannelsBlock),
            matching: find.byType(GlassContainer),
          )
          .evaluate()
          .length;
      expect(
        n,
        1,
        reason: '★★★ 材质**只落一层**（旧13：不许引重复模糊层）。\n'
            '实际 $n 个 —— 0 个 = 玻璃被摘（注入 A）；≥2 个 = 套了第二层'
            '（每个药丸各一块玻璃 = N 层模糊，正是 source_bar 记着"连续踩两次"的错）。',
      );
    });

    testWidgets('★★★ 玻璃容器在 SourinHorizontalRail **外面**', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _shot(tester, glass: true);

      // rail 在玻璃容器内部（玻璃是祖先）
      final glassAncestors = find.ancestor(
        of: find.byType(SourinHorizontalRail),
        matching: find.byType(GlassContainer),
      );
      expect(
        glassAncestors,
        findsOneWidget,
        reason: '★★★ 形状必须是 `GlassContainer > SourinHorizontalRail > 药丸`\n'
            '（与 `source_bar.dart:216` 同构：**外层承担材质**）。\n'
            '★ 玻璃在 rail **外面**还保住了一条既有判据：本文件那条守恒律要求'
            '`SourinHorizontalRail(` 与 `child: ListView.separated(` **紧邻** ——'
            '玻璃插在中间会让它红（而那条门禁是对的）。',
      );
      // 反向：玻离容器**不该**在 rail 里面
      final glassInsideRail = find.ancestor(
        of: find.byType(GlassContainer),
        matching: find.byType(SourinHorizontalRail),
      );
      expect(
        glassInsideRail,
        findsNothing,
        reason: '★ 玻璃不许在 rail 内层 —— 那会打断 rail→ListView 的紧邻关系。',
      );
    });

    testWidgets('★★ 药丸本身**透明**（材质不在药丸上）', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _shot(tester, glass: true);

      // 药丸是 ActionChip；它里面不许有 GlassContainer
      final chip = find.byType(ActionChip).first;
      expect(
        find.descendant(of: chip, matching: find.byType(GlassContainer)),
        findsNothing,
        reason: '★★ 材质在**外层**那个容器上 ⇒ 药丸自身不许再挂玻璃\n'
            '（否则 N 个药丸 = N 层模糊，正是要避免的重复模糊层）。',
      );
    });

    test('★★★ 源码：玻璃层由 `_skipGlassAggChannelRail` 把关（reduced-motion 同源）',
        () {
      final src = File('lib/ui/home_page.dart').readAsStringSync();
      expect(
        src.contains('bool _skipGlassAggChannelRail(BuildContext context)'),
        isTrue,
        reason: '★ 判据函数必须在（与既有三处 skip-glass 同形）',
      );
      expect(
        src.contains('MotionPrefs.reduce(context)'),
        isTrue,
        reason: '★★ reduced-motion 必须走 `MotionPrefs`（全仓同源）—— '
            '自己写 `MediaQuery...disableAnimations` 会造第二个真值来源。',
      );
      expect(
        src.contains('debugSkipGlassAggChannelRail'),
        isTrue,
        reason: '★ 测量仪器开关必须在（逐像素门禁的对照臂用它）',
      );
      // ★ 硬约束：不许动全仓共用的手势包装
      final railSrc =
          File('lib/ui/widgets/sourin_scroll_behavior.dart').readAsStringSync();
      expect(
        railSrc.contains('GlassContainer'),
        isFalse,
        reason: '★★★ `SourinHorizontalRail` 是**全仓共用**的手势包装'
            '（my_shelf 三处轨道也用）⇒ **不许**把玻璃加在它里面。\n'
            '玻璃只加在渠道条那个区块自己的视觉层。',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ④ 实机可见证据：落 PNG（人可读图 —— Owner 第 4 条是**观感**诉求）
  // ═══════════════════════════════════════════════════════════════════
  //
  // ⚠️ 本组**不是** `needs-shot-dir` 那档（那档默认跳过）—— 它不需要特殊环境。
  //    意义是"门禁自己落一张图，人可以直接看观感"：
  // ```text
  // 产物：<SOURIN_SHOT_DIR 或系统临时目录>/r2_n9_rail_{glass,noglass}.png
  // 用法：flutter test test/zz_r2_n9_channel_rail_glass_test.dart \
  //         --plain-name '落图' --concurrency=1
  // ⇒ 两张并排看："挂玻璃"那张有胶囊玻璃底 + 描边，"不挂"那张是透明裸条。
  // ```
  // ★ 判据纪律：本组**只断言"图落盘了且尺寸一致"** —— 像素好不好看靠人读图。
  //   把"好不好看"写成断言只会得到一条恒真的断言（本仓 t1009 文件头同款纪律）。
  //
  // ★★ 另落一张**整页**图（`.probe/r2-n9-glass-fullpage.png`）：Owner 第 4 条
  //    是**观感**诉求 ⇒ 必须有一张"渠道条在真实首页里长什么样"的图，
  //    只截那一条胶囊会看不出它跟页面的关系（旁边是源条、上下是区块）。
  group('★ R2-#4 ④ 实机可见证据（落 PNG）', () {
    testWidgets('落图：挂玻璃 / 不挂玻璃 / 整页 三张 PNG', (tester) async {
      await tester.binding.setSurfaceSize(_kView);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final withGlass = await _shot(tester, glass: true);
      final noGlass = await _shot(tester, glass: false);

      final envDir = Platform.environment['SOURIN_SHOT_DIR'];
      final outDir = Directory(
        (envDir != null && envDir.trim().isNotEmpty)
            ? envDir.trim()
            : '${Directory.systemTemp.path}${Platform.pathSeparator}r2-n9-glass-shots',
      )..createSync(recursive: true);

      Future<void> dump(_Shot s, String name) async {
        final bytes = await _encodePng(s);
        final f = File('${outDir.path}${Platform.pathSeparator}$name.png');
        f.writeAsBytesSync(bytes);
        print('R2N9_SHOT ${f.path} ${f.lengthSync()}B ${s.width}x${s.height}');
      }

      await dump(withGlass, 'r2_n9_rail_glass');
      await dump(noGlass, 'r2_n9_rail_noglass');

      final a =
          File('${outDir.path}${Platform.pathSeparator}r2_n9_rail_glass.png');
      final b =
          File('${outDir.path}${Platform.pathSeparator}r2_n9_rail_noglass.png');
      expect(a.existsSync(), isTrue, reason: '★ 人可读图必须真的落盘');
      expect(b.existsSync(), isTrue);
      expect(a.lengthSync(), greaterThan(0));
      expect(b.lengthSync(), greaterThan(0));
      expect(withGlass.width, noGlass.width);
      expect(withGlass.height, noGlass.height);
    });

    testWidgets('★★★ 落一张**整页**图：渠道条在真实首页里长什么样（Owner 观感诉求）',
        (tester) async {
      const page = Size(900, 1400);
      await tester.binding.setSurfaceSize(page);
      addTearDown(() => tester.binding.setSurfaceSize(null));

      /*
       * ⚠️ 这棵树**故意包含**一个"选中项 + 一条真实尺寸的药丸带"：
       *    Owner 看到的是"渠道条在首页里跟源条/区块一起"的样子 ——
       *    只截那条胶囊看不出观感（本卡是**观感**诉求，不是像素数值诉求）。
       */
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: MediaQuery(
            data: const MediaQueryData(size: page),
            child: MaterialApp(
              debugShowCheckedModeBanner: false,
              home: Scaffold(
                backgroundColor: const Color(0xFF0E1116),
                body: RepaintBoundary(
                  key: _kBoundary,
                  child: SizedBox(
                    width: page.width,
                    height: page.height,
                    child: Stack(
                      children: <Widget>[
                        Positioned.fill(child: _backdrop()),
                        Positioned(
                          left: 0,
                          top: 120,
                          width: page.width,
                          height: 300,
                          child: Builder(
                            builder: (c) => _stripBody(c, glass: true),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final shot = await _grabStable(tester);

      final envDir = Platform.environment['SOURIN_SHOT_DIR'];
      final outDir = Directory(
        (envDir != null && envDir.trim().isNotEmpty)
            ? envDir.trim()
            : '${Directory.systemTemp.path}${Platform.pathSeparator}r2-n9-glass-shots',
      )..createSync(recursive: true);
      final f = File('${outDir.path}${Platform.pathSeparator}r2_n9_fullpage.png');
      f.writeAsBytesSync(await _encodePng(shot));
      print('R2N9_SHOT ${f.path} ${f.lengthSync()}B ${shot.width}x${shot.height}');
      expect(f.existsSync(), isTrue);
      expect(f.lengthSync(), greaterThan(0));
    });
  });
}

/// `_Shot`（rawRgba）→ PNG 字节
///
/// ⚠️ 必须包 `runAsync`（`ImmutableBuffer`/`toByteData` 在 FakeAsync zone 里不返回）
Future<Uint8List> _encodePng(_Shot s) async {
  late Uint8List png;
  await TestWidgetsFlutterBinding.instance.runAsync(() async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(s.rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: s.width,
      height: s.height,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    final bd = await frame.image.toByteData(format: ui.ImageByteFormat.png);
    png = bd!.buffer.asUint8List();
  });
  return png;
}