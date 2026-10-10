// ═══════════════════════════════════════════════════════════════════════
//  T21 / task-47：F2「悬停才显形的垃圾桶」硬门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要这个文件（这是**补缺**，不是加料）
//
// ```text
// F2（Owner-1009：「本地播放页面,进去之后 可以选择批量删除,也可以单集删除」）
// 已有两处门禁：
//   test/zz_media_delete_guard_test.dart   D-0…D-4 删除守卫（逻辑面）
//   test/zz_cr_local_select_ui_test.dart   5 用例（「管理」入口 + 选择态操作条）
// 但**普通态每行右侧那枚垃圾桶是「悬停才显形」**：
//   lib/ui/detail_page.dart:4511-4513 注释  onDelete != null ⇒ 普通态右侧一枚
//                                          垃圾桶，**悬停才显形**
//   lib/ui/detail_page.dart:4656 注释      每一行右边常驻一个垃圾桶正是"不优化"
// ⇒ 若有人把悬停逻辑改坏（垃圾桶永远透明 = 用户永远点不到单集删除），
//   上面两处门禁**全绿**。本文件补的就是这一支。
// ```
//
// # 产品形态（实现原文，lib/ui/detail_page.dart）
//
// ```text
// :3383-3387   onDelete: _localSelectMode ? null : () => unawaited(
//                              _confirmDeleteLocalEpisode(e)),
// :4620        if (onDelete != null) _LocalRowDeleteButton(onTap: onDelete!),
// :4662-4669   class _LocalRowDeleteButton extends StatefulWidget
// :4671-4697   class _LocalRowDeleteButtonState extends State<...> {
//                bool _hover = false;                       // :4672
//                build => MouseRegion(                      // :4677
//                  cursor: SystemMouseCursors.click,        // :4678
//                  onEnter: (_) => setState(() => _hover = true),   // :4679
//                  onExit:  (_) => setState(() => _hover = false),  // :4680
//                  child: Tooltip(message: '删除这一集',      // :4682
//                    child: IconButton(                      // :4683
//                      constraints: BoxConstraints.tightFor(width: 28, height: 28),
//                      iconSize: 16, onPressed: widget.onTap,   // :4687-4688
//                      icon: Icon(Icons.delete_outline_rounded, // :4689
//                        color: _hover ? colors.error : Colors.transparent, // :4691
//                      ))))
// ```
// ★ 判据 = 图标颜色（Colors.transparent ⇄ colors.error），**不是**透明度动画、
//   **不是** hit-test 开关（IconButton 一直都在命中测试里）。
//
// # 读色为什么不能靠 find.byIcon
//
// find.byIcon 只匹配**图标码点**，与颜色无关 ⇒ 用它读「是否显形」是假绿
// （颜色改恒真/恒假它都 findsOneWidget）。本文件用
// t.widgetList<Icon>(...) 取出 Icon 的 color 字段，与**实现真正用的那个值**
// 比对：Colors.transparent（未悬停）⇄ Theme.of(context).colorScheme.error（悬停）。
//
// # 悬停事件的可靠派发（★ 逐字照抄 test/t50c_poster_hover_test.dart:29-36 的纪律）
//
// ```text
// ① t.sendEventToBinding(p.hover(...)) 派发**真的** PointerHoverEvent
//    （⚠️ t.startGesture(...).moveTo(...) 发的是 PointerMoveEvent，
//     而 MouseTracker.updateWithEvent 只认 PointerHoverEvent
//     ⇒ 用 TestPointer.hover，这是 t72_jank_test.dart 验证过的写法）
// ② pump() 一帧 ⇒ setState(_hover = true) 生效
// ③ ★★ 前置条件断言：证明 onEnter 真的接上了
//    —— 不成立就直接失败并说明"前提不成立"，
//      而不是含糊地报"颜色不对"（那是把两种完全不同的故障混为一谈）
// ```
//
// # ★ 悬停目标为什么必须用 t.getCenter 算出来，而不是硬编码坐标
//
// ```text
// 本页在 SizedBox(height: kLocalEpsViewportH) 里有**内部滚动**
// （lib/ui/detail_page.dart:3349-3357）。
// 若把 t.getCenter(...) 直接当悬停点，第 1 行会被 SingleChildScrollView
// 上沿夹掉、第 3 行会落在视口之外 ⇒ onEnter 根本不触发
// （本文件第一版就是这样：悬停后**仍然透明**，是"前提不成立"而不是产品缺陷）。
// ⇒ 必须按 Scrollable.of(rowContext).position.pixels 把**全局中心**换算成
//   该行在**视口内**的可见点。
// ```
//
// # 反假绿（两次阳性对照，都必须在**断言真正执行的那一态**跑）
//
// ```text
// 对照 A：把 :4691 的三目条件改成恒真（true ? colors.error : …）
//         ⇒ 未悬停那一态**应当**读到不透明色 ⇒ 「未悬停必须透明」必须红。
// 对照 B：改成恒假（false ? …）
//         ⇒ 悬停那一态**应当**读到透明色 ⇒ 「悬停必须显形」必须红。
// 两次的原始输出与逐字节还原见 .probe/ops/t21-f2-hover-gate.md。
// ```
//
// # 为什么断言的是**颜色**而不是"透明度"（★ 必须如实说清）
//
// _LocalRowDeleteButtonState 用的是 MouseRegion.onEnter/onExit + setState
// ⇒ _hover 是**同步**翻转的：派发 hover 事件后**一帧**就已经是新颜色。
// 也就是说：**本文件的悬停断言抓不到"异步竞态"这一类缺陷**（例如有人把
// onEnter 改成延时生效）。抓得到的是：条件被改死、_hover 没接上、
// onEnter/onExit 被删、MouseRegion 被换成 InkWell 之类
// —— 而这正是 Lead 点名的「垃圾桶永远透明 ⇒ 用户永远点不到」那一种。
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/network_status.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/cache_page.dart';
import 'package:sourin_spike/ui/detail_page.dart';
import 'package:sourin_spike/ui/theme_bridge.dart';

// ══════════════════════════════════════════════════════════════════════════
//  0. 夹具（与 test/zz_cr_local_select_ui_test.dart 同款沙盒纪律）
// ══════════════════════════════════════════════════════════════════════════

/// 系统临时目录下的沙盒（**绝不碰** %APPDATA% 与业主真实下载目录）
Directory _sandbox(String name) {
  final p = '${Directory.systemTemp.absolute.path}$Platform.pathSeparator$name';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  d.createSync(recursive: true);
  return d;
}

late Directory _root;
late Directory _workDir;
late CachedWork _work;
late List<LocalEpisodeRef> _eps;

const int _epCount = 3;

String _epName(int i) => '第0$i集';

/// 三枚垃圾桶图标（按树序）
///
/// ★ 用 Icon 而不是 find.byIcon：后者与**颜色**无关，读不出"是否显形"。
List<Icon> _trashIcons(WidgetTester t) =>
    t.widgetList<Icon>(find.byIcon(Icons.delete_outline_rounded)).toList();

/// 把积压的框架异常收走（诊断用：只打印，不做断言）
///
/// ⚠️ 本地模式的 DetailPage 会去调 SourinApi.getProgress（FFI）——
///   仓库根没有 sourin_core.dll（CI 也没有）⇒ 抛「Failed to load dynamic
///   library 'sourin_core.dll'」。那条异常与本地选集 UI 无关，
///   让它在 _pump 之后堆积会把后续断言染红成别的东西。
List<String> _drain(WidgetTester t) {
  final out = <String>[];
  Object? e;
  while ((e = t.takeException()) != null) {
    out.add('$e');
  }
  return out;
}

Future<void> _pumpLocal(WidgetTester t,
    {Size size = const Size(1440, 900)}) async {
  t.view.physicalSize = size;
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  await t.pumpWidget(MaterialApp(
    theme: buildAppTheme(Brightness.light),
    home: DetailPage(
      provider: kLocalProvider,
      id: _work.episodes.first.fileName,
      localFile: '${_workDir.path}${Platform.pathSeparator}${_epName(1)}.mp4',
      localMeta: _work,
      localEpisodes: _eps,
      localEpisodeCount: _eps.length,
      // ★ 不传 onPlayLocalEpisode：普通态每行的 onTap 就是 null
      //   ⇒ 普通态点行**不会**有任何副作用，悬停读数才是干净的。
    ),
  ));
  await t.pump(const Duration(milliseconds: 50));
  _drain(t);
}

/// 主题里那个 error 色（**实现真正用的就是它**，不是我们编的常量）
Color _errorOf(WidgetTester t) {
  final ctx = t.element(find.text('已下载'));
  return Theme.of(ctx).colorScheme.error;
}

/// 第 [i] 行垃圾桶在**视口内**的可见点（全局坐标）
///
/// ★ 为什么不能直接用 t.getCenter(iconFinder)：见文件头「悬停目标」那一节。
Offset _visiblePointOfRow(WidgetTester t, int i) {
  final icons = find.byIcon(Icons.delete_outline_rounded);
  expect(icons.evaluate().length, _epCount,
      reason: '夹具前置：普通态每行一枚垃圾桶（实测 ${icons.evaluate().length} 枚）');

  final rowFinder = find.ancestor(
    of: icons.at(i),
    matching: find.byWidgetPredicate(
        (w) => w.runtimeType.toString() == '_LocalEpisodeRow'),
  );
  final rowCenter = t.getCenter(rowFinder);
  final vp = t.getRect(find.byType(SingleChildScrollView));
  /*
   * ★★ 悬停点必须落在**垃圾桶自己**的 MouseRegion 上，而不是行中心
   *
   * `_LocalRowDeleteButton` 的 MouseRegion 只包那枚 28×28 的按钮
   * （detail_page.dart:4677-4693），它在行的**最右侧**；
   * 悬停"行的中心"只会命中行的 InkWell ⇒ `onEnter` 根本不触发
   * （本文件第二版就是这样：③④ 的悬停后仍然透明）。
   * ⇒ x 取**图标自身**的横向中心，y 取行在视口内的可见中心
   *   （行被滚动夹掉时，图标中心 y 也会跑出视口，而按钮在行内是垂直居中的，
   *     所以"行中心 y"才是稳的那个读数）。
   */
  final iconRect = t.getRect(icons.at(i));
  final at = Offset(iconRect.center.dx, rowCenter.dy);
  expect(
    at.dy >= vp.top && at.dy <= vp.bottom,
    isTrue,
    reason: '★★ 前提不成立：第 ${i + 1} 行的中心 y=${at.dy.toStringAsFixed(1)}'
        ' 不在选集视口 [${vp.top.toStringAsFixed(1)}, ${vp.bottom.toStringAsFixed(1)}] 内'
        ' ⇒ 指针落不到那一行的 MouseRegion 上，'
        'onEnter 不会触发（★ 这与"产品缺陷"是两件事，必须分开报）',
  );
  return at;
}

/// 派发**真的**鼠标悬停，并把指针停在该行垃圾桶上
Future<void> _hoverRow(WidgetTester t, int i, {String tag = ''}) async {
  final p = TestPointer(1, PointerDeviceKind.mouse);
  await t.sendEventToBinding(p.addPointer(location: const Offset(1, 1)));
  final at = _visiblePointOfRow(t, i);
  await t.sendEventToBinding(p.hover(at));
  await t.pump();
  // ★★ 前提断言（照 t50c:167-175 的手法）：证明 onEnter **真的**接上了。
  //    ⚠️ 这里**不能**拿"颜色已变"当前提 —— 那会与结论同义反复（阳性对照 B
  //      把它改成恒假时，前提会先红，就分不清"前提不成立"与"产品缺陷"）。
  //      ⇒ 前提改用**结构性事实**：该行的 MouseRegion 两个回调都在。
  // ★ 定位"**这一个** MouseRegion"：生产代码里它的 child 就是那个 Tooltip
  //   （detail_page.dart:4677-4682 `MouseRegion(… child: Tooltip(…))`）。
  //   ⚠️ 不能只写 find.byType(MouseRegion)：IconButton 内部还有自己的
  //      MouseRegion ⇒ 祖先链上不止一个（实测 `Bad state: Too many elements`）。
  final region = t.widget<MouseRegion>(find.ancestor(
    of: find.byIcon(Icons.delete_outline_rounded).at(i),
    matching: find.byWidgetPredicate(
        (w) => w is MouseRegion && w.child is Tooltip),
  ));
  expect(region.onEnter, isNotNull,
      reason: '★★ $tag 前提不成立：垃圾桶的 MouseRegion 没有 onEnter'
          '（_LocalRowDeleteButtonState 里 _hover 永远翻不过来）');
  expect(region.onExit, isNotNull,
      reason: '★★ $tag 前提不成立：垃圾桶的 MouseRegion 没有 onExit');
  expect(region.cursor, SystemMouseCursors.click,
      reason: '★★ $tag 前提不成立：垃圾桶的 MouseRegion 不是 click 手型'
          '（detail_page.dart:4678）');
}

/// 撤销悬停（把指针移出该行）—— 用于「悬停后再移开」的往返读数
Future<void> _unhover(WidgetTester t) async {
  final p = TestPointer(1, PointerDeviceKind.mouse);
  await t.sendEventToBinding(p.hover(const Offset(2, 2)));
  await t.pump();
}

void main() {
  setUpAll(() {
    /*
     * ★ 本文件**刻意不碰 media_kit / libmpv**（与 zz_cr_local_select_ui_test.dart
     *   那条"dll 在就初始化"不同）：
     * ```text
     * DetailPage 的本地模式**不会**构造 Player ⇒ 不需要 libmpv；
     * 而 setUpAll 里那句 MediaKit.ensureInitialized 会真的去
     * DynamicLibrary.open 夹具 dll —— 一旦夹具正被别的进程改名/替换
     * （本仓的阳性对照手法就是 File.Move），整个测试文件会**卡在
     * setUpAll**（实测：一次 23s "did not complete"、同目录既有门禁
     * 也出现过 52s 的同款挂起）。
     * ⇒ 去掉这一句，本门禁就与 libmpv 夹具**彻底解耦**：
     *   干净 runner（CI 无 dll）与有 dll 的机器上行为完全一致。
     * ```
     */
    UiPrefs.debugResetForTest();
  });

  setUp(() {
    final sep = Platform.pathSeparator;
    _root = _sandbox('sourin_t21_row_trash_hover');
    for (final e in _root.listSync()) {
      e.deleteSync(recursive: true);
    }
    _workDir = Directory('${_root.path}$sep无职转生 第三季')
      ..createSync(recursive: true);
    for (var i = 1; i <= _epCount; i++) {
      File('${_workDir.path}$sep${_epName(i)}.mp4')
          .writeAsBytesSync(List<int>.filled(1024, 0x42));
    }
    // ★ 造 CachedWork 用同步 listSync（绝不在 fake-async 区里 await 真 IO）
    _work = CachedWork(
      dirName: '无职转生 第三季',
      path: _workDir.path,
      title: '无职转生 第三季',
      episodes: <CachedEpisode>[
        for (final f in _workDir.listSync().whereType<File>())
          CachedEpisode(
            fileName: f.uri.pathSegments.last,
            bytes: f.lengthSync(),
            isComplete: true,
          ),
      ],
      description: 'T21 悬停门禁夹具',
    );
    _eps = <LocalEpisodeRef>[
      for (var i = 1; i <= _epCount; i++)
        LocalEpisodeRef(
          fileName: '${_epName(i)}.mp4',
          episodeTitle: _epName(i),
          absolutePath: '${_workDir.path}$sep${_epName(i)}.mp4',
          bytes: 1024,
        ),
    ];

    NetworkStatus.debugResetForTest();
    NetworkStatus.debugProbe = () async => true;
    DownloadQueue.debugReset();
  });

  tearDown(() {
    NetworkStatus.debugProbe = null;
    debugSetLocalOriginRecords(null);
  });

  tearDownAll(() {
    final d = Directory(
        '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}sourin_t21_row_trash_hover');
    if (d.isAbsolute && d.existsSync()) d.deleteSync(recursive: true);
  });

  group('★ T21 F2：普通态垃圾桶「悬停才显形」', () {
    testWidgets('★ ① 未悬停：三枚垃圾桶全部透明（不显形）', (t) async {
      await _pumpLocal(t);

      // ── 夹具前置 ──
      expect(_trashIcons(t).length, _epCount,
          reason: '夹具前置：普通态每行右侧一枚垃圾桶（detail_page.dart:4620）');
      final err = _errorOf(t);

      // ── ① 被测断言：未悬停 ⇒ 颜色必须是 Colors.transparent ──
      for (var i = 0; i < _epCount; i++) {
        final c = _trashIcons(t)[i].color;
        expect(
          c,
          Colors.transparent,
          reason: '★★ ① 第 ${i + 1} 行垃圾桶在**未悬停**时必须是透明'
              '（detail_page.dart:4691 三目：_hover ? colors.error : Colors.transparent）。'
              '实测 = $c。'
              '它若不透明 ⇒ 每一行右边都挂一个红图标，列表会很吵'
              '（这正是 :4656 那条注释说"不优化"的形态）——'
              '★ 本断言就是「悬停条件被改成恒真」那一态的判据。',
        );
        expect(c, isNot(err),
            reason: '★ ① 未悬停时**不许**是主题的 error 色（= 显形态）');
      }
    });

    testWidgets('★ ② 悬停第 2 行：那一行显形（error 色），其余两行仍透明', (t) async {
      await _pumpLocal(t);
      final err = _errorOf(t);

      await _hoverRow(t, 1, tag: '②');

      final colors = _trashIcons(t).map((e) => e.color).toList();
      expect(
        colors[1],
        err,
        reason: '★★ ② 悬停后第 2 行垃圾桶必须变成主题 error 色（= 显形）。'
            '实测 = ${colors[1]}，期望 = $err。'
            '它若仍是透明 ⇒ **用户永远点不到单集删除**'
            '（图标还在、也能命中测试，但看不见 ⇒ 等于功能没了）。'
            '★ 本断言就是「悬停条件被改成恒假」那一态的判据。',
      );
      expect(colors[0], Colors.transparent,
          reason: '★ ② 悬停一行不许连带显形别的行（第 1 行仍须透明）');
      expect(colors[2], Colors.transparent,
          reason: '★ ② 悬停一行不许连带显形别的行（第 3 行仍须透明）');
    });

    testWidgets('★ ③ 移开后回落：悬停 ⇒ 显形，移出 ⇒ 重新透明（往返一次）', (t) async {
      await _pumpLocal(t);
      final err = _errorOf(t);

      await _hoverRow(t, 0, tag: '③-hover');
      expect(_trashIcons(t)[0].color, err,
          reason: '★★ ③ 悬停第 1 行后必须显形（否则本用例的"回落"无从谈起）');

      await _unhover(t);
      expect(
        _trashIcons(t)[0].color,
        Colors.transparent,
        reason: '★★ ③ 指针移出后必须**回落**到透明（onExit ⇒ _hover = false）。'
            '不回落 ⇒ 用户只要碰过一次，整张列表就永远挂着垃圾桶。',
      );
    });

    testWidgets('★★ ④ 悬停后点垃圾桶：真的弹出「删除这一集？」确认框', (t) async {
      await _pumpLocal(t);

      await _hoverRow(t, 1, tag: '④');
      // ★ 前提断言：此刻必须真的处于"显形"态，否则下面"点得到"是假绿
      final err = _errorOf(t);
      expect(_trashIcons(t)[1].color, err,
          reason: '★★ ④ 前提不成立：悬停后第 2 行仍未显形 ⇒ 后面"点到了"'
              '就不是"悬停让它可点"的证据（两件事必须分开报）');

      await t.tap(find.byIcon(Icons.delete_outline_rounded).at(1));
      await t.pump();
      await t.pump(const Duration(milliseconds: 50));
      _drain(t);

      expect(
        find.text('删除这一集？'),
        findsOneWidget,
        reason: '★★ ④ 悬停显形后点它，**必须**弹出单集删除确认框'
            '（detail_page.dart:4688 onPressed: widget.onTap ⇒'
            ' :3385 _confirmDeleteLocalEpisode(e)）。'
            '弹不出来 ⇒ 悬停显形只是装饰，单集删除在 UI 面上仍然不可达。',
      );
      expect(find.textContaining('文件会从磁盘上真正删除'), findsOneWidget,
          reason: '★ ④ 确认框必须写明不可恢复（业主删的是真文件）');

      // 收尾：取消掉，别把弹窗留给下一条用例
      // ⚠️ showAppDialog 走带过渡动画的 showDialog ⇒ 点「取消」后必须把
      //    关闭动画跑完（照 zz_cr_local_select_ui_test.dart:379-384 的教训）。
      await t.tap(find.text('取消'));
      for (var i = 0; i < 12; i++) {
        await t.pump(const Duration(milliseconds: 50));
      }
      _drain(t);
      expect(find.text('删除这一集？'), findsNothing,
          reason: '收尾：点「取消」后确认框必须关闭');
    });
  });
}
