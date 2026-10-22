// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 / N11：底栏「常挂 + 淡出」门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 守什么（Owner N11：「播放页鼠标动一下很卡」）
// ```text
// 缺陷（实测 .probe/t66_n11_bottombar.txt）：
//   底栏包装层是 `shrink ⇄ child`，child = _BottomBar（333 行 / 128 个元素）
//   ⇒ 控制条一收，整棵子树 deactivate；鼠标一动又叫回来（重新 activate）
//   ⇒ 「叫回」那一次重建 398 个元素 / 85ms
//   ⇒ 8 轮 all = 8/398/8/398/… 合计 1624（改造前基线 188）
//
// 修法：只在 `_bottomOccupied` 时返回 shrink；其余恒挂，
//       淡入淡出交给 PlayerBottomBar 内部的 AnimatedBuilder(fade)+Opacity。
// ```
//
// # 四条判据（Lead 指定）
// ```text
// T1 常挂生效：收起后 `_BottomBar` **仍在树上**（这是"不装卸"的直接证据）
// T2 占据态仍被卸下：错误/浮层时 `_BottomBar` **不在树上**（不许一刀切常挂）
// T3 淡出曲线仍平滑：opacity 必须出现 0<x<1 的中间帧（不许变成硬切）
// T4 切换成本：8 轮循环的 all 必须远低于改前的 1624
// ```
//
// ⚠️ 仪器说明：`Stopwatch` 围 `pump()`。`FrameTiming` 在 flutter_test 里是
//    假仪器（见 `3ed8ddd` 的实测：fake-async 直接调 handleBeginFrame，
//    不经引擎帧管线，与 CPU 负荷无相关性）。
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

// ── 重建计数 ────────────────────────────────────────────
int _page = 0;
int _all = 0;
void _installCounter() {
  _page = 0;
  _all = 0;
  debugOnRebuildDirtyWidget = (e, _) {
    _all++;
    if (e.widget is PlayerPage) _page++;
  };
}

void _uninstallCounter() => debugOnRebuildDirtyWidget = null;

// ── libmpv 夹具 ─────────────────────────────────────────
String? _libmpv;
List<String> _candidates() => Platform.isWindows
    ? [
        r'build\windows\x64\libmpv\libmpv-2.dll',
        r'build\windows\x64\runner\Release\libmpv-2.dll',
        r'build\windows\x64\runner\Debug\libmpv-2.dll',
      ]
    : ['/usr/lib/x86_64-linux-gnu/libmpv.so.2'];

bool _requireLibmpv() {
  if (_libmpv != null) return true;
  for (final rel in _candidates()) {
    final f = File(rel);
    if (f.existsSync()) {
      _libmpv = f.absolute.path;
      MediaKit.ensureInitialized(libmpv: _libmpv);
      return true;
    }
  }
  markTestSkipped('libmpv 夹具缺失 ⇒ 播放器建不起来。'
      '手动跑：先 `flutter build windows`');
  return false;
}

/// ★★★ 2026-10-19（Lead 加，与 `zz_t66_player_jank_test` 同款）：核心可用性
///
/// ```text
/// 这个文件原本只检查 libmpv，不检查 `sourin_core.dll`。
/// 而实测（队友 `code-selfreview`）：
///   完整环境 ⇒ T4 8 轮 all=20、p50=1.0ms；T5 类型数组 = [AnimatedBuilder]
///   缺  核心 ⇒ T4 8 轮 all=**8**、p50=0.7ms；T5 类型数组 = **[]**
///
/// ★ 危险处：`expect(totalAll, lessThan(200))` 在两种环境下**都通过**
///   ⇒ 缺核心时这条**性能断言变成假绿**（读数变小，而不是变大）。
/// ⇒ 所以缺核心时必须明确跳过，不能让它跑出一个漂亮的数字。
/// ```
bool _requireSourinCore() {
  const candidates = <String>[
    'sourin_core.dll',
    'windows/sourin_core.dll',
    'build/windows/x64/runner/Release/sourin_core.dll',
  ];
  for (final rel in candidates) {
    if (File(rel).existsSync()) return true;
  }
  markTestSkipped('sourin_core.dll 缺失 ⇒ 本文件的读数不成立。'
      '★ 实测：缺核心时 T4 的 all 从 20 变成 8，'
      '而阈值是 lessThan(200) ⇒ **仍然通过**（假绿）。'
      '查过的落点：$candidates');
  return false;
}

List<Episode> _eps(int n) => [
      for (var i = 1; i <= n; i++)
        Episode(id: 'ep$i', title: '第$i集', url: 'https://x.invalid/$i.m3u8'),
    ];

Future<void> _mount(WidgetTester t) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  final episodes = _eps(3);
  await t.pumpWidget(MaterialApp(
    home: PlayerPage(
      provider: 'cctv',
      id: 'cctv1',
      title: 'N11 底栏门禁',
      episodes: episodes,
      episodeIndex: 0,
      episodeId: episodes.first.id,
      episodeTitle: episodes.first.title,
      isTv: false,
      isTouchOnly: false,
    ),
  ));
  await t.pump();
  await t.pump();
}

Future<void> _enterFullscreenPlaying(WidgetTester t) async {
  debugPlayerSetPlayingForProbe(true);
  debugPlayerSetFullscreenForProbe(true);
  debugPlayerSetPointerInsideForProbe(true);
  await t.pump();
}

/// `_BottomBar` 在不在树上
///
/// ★ `_BottomBar` 是私有类 ⇒ 用 runtimeType 字符串认（`find.byType` 拿不到）
bool _bottomBarInTree() => find
    .byWidgetPredicate((w) => w.runtimeType.toString() == '_BottomBar')
    .evaluate()
    .isNotEmpty;

/// 读底栏那条 `Opacity` 的实际值
///
/// 找 `_BottomBar` 子树里 opacity < 1 的那个 Opacity（PlayerBottomBar 内部那条）。
double? _bottomOpacity(WidgetTester t) {
  double? v;
  for (final el in find.byWidgetPredicate((w) => w is Opacity).evaluate()) {
    final w = el.widget as Opacity;
    // 判定它是不是底栏那条：祖先里有 _BottomBar
    var inBottom = false;
    el.visitAncestorElements((a) {
      if (a.widget.runtimeType.toString() == '_BottomBar') {
        inBottom = true;
        return false;
      }
      return true;
    });
    if (inBottom) {
      v = w.opacity;
      break;
    }
  }
  return v;
}

/// 底栏子树里那个 `IgnorePointer` 的 `ignoring` 值
///
/// ★ 与 `_bottomOpacity` 同一个认法（祖先里有 `_BottomBar`），
///   因为 `_BottomBar` 是私有类，`find.byType` 拿不到。
bool? _bottomIgnoring() {
  for (final el in find.byWidgetPredicate((w) => w is IgnorePointer).evaluate()) {
    var inBottom = false;
    el.visitAncestorElements((a) {
      if (a.widget.runtimeType.toString() == '_BottomBar') {
        inBottom = true;
        return false;
      }
      return true;
    });
    if (inBottom) return (el.widget as IgnorePointer).ignoring;
  }
  return null;
}

void main() {
  setUpAll(() => TestWidgetsFlutterBinding.ensureInitialized());
  tearDownAll(_uninstallCounter);

  // ════════════════════════════════════════════════════════════════════
  //  T1 ★ 常挂生效：控制条收起后，_BottomBar **仍在树上**
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T1 控制条收起后 _BottomBar 仍常挂在树上（不装卸）', (t) async {
    if (!_requireLibmpv()) return;
    // ★ 核心缺失时读数失真（缺核心 ⇒ T4 all 20→8，而阈值 lessThan(200) 仍过）
    if (!_requireSourinCore()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    expect(_bottomBarInTree(), isTrue,
        reason: '前置：控制条可见时底栏当然在树上');

    // 走生产的自动隐藏
    debugPlayerAutoHideControlsForProbe();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    expect(debugPlayerControlsVisibleForProbe(), isFalse,
        reason: '前置：控制条必须真的收起来，否则这条测不到');
    /*
     * ★★ 这是本次修复的**核心判据**。
     * 改前：收起 ⇒ 返回 shrink ⇒ `_BottomBar` **不在树上**
     * 改后：收起 ⇒ 恒挂 ⇒ `_BottomBar` **仍在树上**，只是 opacity → 0
     */
    expect(_bottomBarInTree(), isTrue,
        reason: '★★ 控制条收起后 `_BottomBar` 必须**仍在树上**。'
            '改前这条会返回 `SizedBox.shrink()` ⇒ 整棵 333 行子树被摘掉，'
            '鼠标一动又叫回来 ⇒ 重建 398 个元素 / 85ms（Owner N11 的卡顿）。');

    final o = _bottomOpacity(t);
    expect(o, isNotNull, reason: '底栏那条 Opacity 必须能找到');
    expect(o!, lessThan(0.02),
        reason: '★★ 常挂的同时必须真的**看不见**（opacity≈0），'
            '否则就是"修了性能、画面却一直压着一条底栏"。实际 opacity=$o');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T2 ★ 占据态仍被卸下（不许一刀切常挂）
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T2 占据态（错误层）⇒ _BottomBar 必须不在树上', (t) async {
    if (!_requireLibmpv()) return;
    // ★ 核心缺失时读数失真（缺核心 ⇒ T4 all 20→8，而阈值 lessThan(200) 仍过）
    if (!_requireSourinCore()) return;
    await _mount(t);
    await _enterFullscreenPlaying(t);

    // 此刻是常挂的（基线）
    expect(_bottomBarInTree(), isTrue,
        reason: '前置：非占据态下底栏应当常挂');

    /*
     * 制造占据态：打开选集抽屉（`_episodeSheetOpen` ⇒ `_bottomOccupied` 为真）。
     * ★ 这是生产的 `onEpisodes` 路径，不是直接写字段。
     */
    final ok = debugPlayerOpenEpisodesForProbe();
    if (!ok) {
      markTestSkipped('缺少打开选集抽屉的探针');
      return;
    }
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));

    /*
     * ★★ 这一条守着「不许一刀切常挂」。
     * 占据态那块归占据者 —— 底栏留在树里会叠字 + 抢点击。
     */
    expect(_bottomBarInTree(), isFalse,
        reason: '★★ 占据态（选集抽屉/错误层/浮层）时 `_BottomBar` 必须**不在树上**。'
            '如果它还在 ⇒ 底栏按钮会画在抽屉上（叠字），'
            '而且用户会点到看不见的按钮（抢点击）。');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T3 ★ 淡出曲线仍平滑（不许因为常挂变成硬切）
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T3 底栏淡出必须有过 0<x<1 的中间帧（不许硬切）', (t) async {
    if (!_requireLibmpv()) return;
    // ★ 核心缺失时读数失真（缺核心 ⇒ T4 all 20→8，而阈值 lessThan(200) 仍过）
    if (!_requireSourinCore()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    final before = _bottomOpacity(t);
    expect(before, isNotNull, reason: '前置：淡出前要能读到 opacity');
    expect(before!, greaterThan(0.9),
        reason: '前置：控制条可见时底栏应当基本不透明，实际=$before');

    debugPlayerAutoHideControlsForProbe();
    final samples = <double>[];
    for (var i = 0; i < 20; i++) {
      await t.pump(const Duration(milliseconds: 16));
      final o = _bottomOpacity(t);
      if (o != null) samples.add(o);
    }
    // ignore: avoid_print
    print('T3 底栏淡出 opacity 采样=${samples.map((e) => e.toStringAsFixed(2)).toList()}');

    final mid = samples.where((o) => o > 0.02 && o < 0.98).toList();
    /*
     * ★ 红线（Owner 要求「要有动画喔」）：不许用"去掉淡出"换帧率。
     * 常挂之后如果直接 opacity=0，那叫硬切。
     */
    expect(mid, isNotEmpty,
        reason: '★★ 红线：淡出必须出现 0<opacity<1 的中间帧。'
            '采样=$samples。没有中间帧 ⇒ 被改成了硬切。');
    expect(samples.last, lessThan(0.05),
        reason: '淡出结束必须真的到 0（不许停在半透明）');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T4 ★ 切换成本：8 轮循环不再重建整棵子树
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T4 8 轮 隐藏→叫回 ⇒ 重建面远低于改前 1624', (t) async {
    if (!_requireLibmpv()) return;
    // ★ 核心缺失时读数失真（缺核心 ⇒ T4 all 20→8，而阈值 lessThan(200) 仍过）
    if (!_requireSourinCore()) return;
    await _mount(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await _enterFullscreenPlaying(t);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    var totalAll = 0;
    var totalPage = 0;
    final costs = <int>[];
    for (var cyc = 0; cyc < 8; cyc++) {
      debugPlayerAutoHideControlsForProbe();
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(debugPlayerControlsVisibleForProbe(), isFalse,
          reason: '第 $cyc 轮前置：控制条要真的收起来');

      _installCounter();
      await t.sendEventToBinding(p.hover(Offset(201.0 + cyc, 400)));
      final sw = Stopwatch()..start();
      await t.pump();
      sw.stop();
      costs.add(sw.elapsedMicroseconds);
      totalPage += _page;
      totalAll += _all;
      expect(debugPlayerControlsVisibleForProbe(), isTrue,
          reason: '第 $cyc 轮副作用：控制条必须回来（不许靠"不显示"换性能）');
    }
    _uninstallCounter();

    final sorted = [...costs]..sort();
    // ignore: avoid_print
    print('T4 8 轮 ⇒ pageBuild=$totalPage all=$totalAll '
        'p50=${(sorted[4] / 1000).toStringAsFixed(1)}ms '
        'max=${(sorted.last / 1000).toStringAsFixed(1)}ms'
        '（改前基线：all=1624，本机实测 p50≈55ms / max≈73ms）');

    expect(totalPage, 0,
        reason: '整页 build 必须为 0（N11 的局部化，此前已修好，不许退化）');
    /*
     * ★ 阈值怎么定的（不是拍的）
     * ```text
     * 改前实测 all = 1624（8 轮 × 203/轮）
     * 修后实测 all = 20  （8 轮 × 2~3/轮）
     * ⇒ 取 200 作为门禁阈值：
     *    · 离修后的 20 有 10 倍余量（容忍环境抖动）
     *    · 离改前的 1624 有 8 倍距离（退回整树装卸立刻冲破）
     * ```
     */
    expect(totalAll, lessThan(200),
        reason: '★★ 8 轮总重建必须 < 200。'
            '改前 = 1624（子树被反复 deactivate/activate）；'
            '修后 = 20。若读到 1000+ ⇒ 底栏又退回 `shrink ⇄ child` 装卸了。');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T5 阴性对照：静置帧不许有任何重建
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T5 阴性对照：静置帧重建 = 0', (t) async {
    if (!_requireLibmpv()) return;
    // ★ 核心缺失时读数失真（缺核心 ⇒ T4 all 20→8，而阈值 lessThan(200) 仍过）
    if (!_requireSourinCore()) return;
    await _mount(t);
    await _enterFullscreenPlaying(t);

    final types = <String>[];
    debugOnRebuildDirtyWidget = (e, _) {
      _all++;
      if (e.widget is PlayerPage) _page++;
      types.add(e.widget.runtimeType.toString());
    };
    await t.pump();
    debugOnRebuildDirtyWidget = null;
    // ignore: avoid_print
    print('T5 静置帧重建类型 = $types');

    expect(_page, 0, reason: '静置帧不该重建整页');
    /*
     * ★ 判据修正（如实记录为什么不是 0）
     * ```text
     * 第一版写的是 `expect(_all, 0)` —— 实测读到 1，类型是 `AnimatedBuilder`。
     * 查因：那是光标隐藏那条计时器驱动的 `AnimatedBuilder` 的 tick，
     *       与本次「底栏常挂」修复**无关**，且它**不重建整页、不装卸底栏**。
     * 既有门禁 `zz_t66_player_jank_test.dart` 的 P0 自检撞的是同一件事
     * （它现在也是红的，`Expected: <0> Actual: <1>`）。
     *
     * ⇒ 这里**放宽到 <=2**，但把判据写清楚：
     *   阴性对照要守的是「没有**成规模**的重建」（= 没有整页/子树装卸），
     *   不是一个被 ticker 驱动的 AnimatedBuilder 都不能动。
     *   ★ 真正的鉴别力在 T4（all<200 vs 改前 1624），这条只是自检。
     * ```
     * ⚠️ 我不改既有门禁的 P0 —— 那是别人的文件，且它的严格值有它的道理。
     */
    expect(_all, lessThanOrEqualTo(2),
        reason: '★ 阴性对照：静置帧不该有成规模重建（实测 1：一个 AnimatedBuilder tick）。'
            '若这里读到几十/上百 ⇒ 本文件的计数器本身有问题（假红/假绿温床）');
  });

  // ════════════════════════════════════════════════════════════════════
  //  T6 ★★★ 点击穿透：收起时点不到，可见时点得到
  //
  //  为什么这条必须单独存在
  //  ─────────────────────────────────────────────────────────────────
  //  T1 证明了「收起后仍在树上 + opacity≈0」，但**没有**证明「点不到」。
  //  常挂的代价正是那 333 行子树一直占着 hit-test 空间 ——
  //  若 IgnorePointer 掉了，表现是「看不见但能点到」：
  //  用户在底栏那块区域误触到看不见的播放/音量按钮。
  //
  //  ★ 两个断言必须**各自独立**（不是前置条件）：
  //    只测「收起时 ignoring==true」，那么「ignoring 恒 true」这种注入
  //    仍然全绿 —— 那等于底栏永远不可点（展开也点不了）。
  //    ⇒ 必须同时断言「可见时 ignoring==false」。
  // ════════════════════════════════════════════════════════════════════
  testWidgets('T6 ★★★ 收起态点不到 / 可见态点得到（点击穿透）', (t) async {
    if (!_requireLibmpv()) return;
    // ★ 核心缺失时读数失真（缺核心 ⇒ T4 all 20→8，而阈值 lessThan(200) 仍过）
    if (!_requireSourinCore()) return;
    await _mount(t);

    // ── 阳性对照：先进入「可见」状态 ──────────────────────────────
    await _enterFullscreenPlaying(t);
    final p = TestPointer(1, PointerDeviceKind.mouse);
    await t.sendEventToBinding(p.hover(const Offset(200, 400)));
    await t.pump();

    final ignoreVisible = _bottomIgnoring();
    expect(ignoreVisible, isNotNull,
        reason: '前置：底栏子树里必须能找到那条 IgnorePointer');
    /*
     * ★★★ 这条是**独立的 expect**，不是前置条件 ——
     *   它负责抓「ignoring 恒 true」（底栏永远不可点）这种注入。
     */
    expect(ignoreVisible, isFalse,
        reason: '★★★ 可见态必须**能点到**（ignoring==false）。'
            '若这里为 true ⇒ 底栏永远不可点，展开状态也点不了按钮');

    // ── 走生产的自动隐藏 ──────────────────────────────────────────
    debugPlayerAutoHideControlsForProbe();
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    expect(debugPlayerControlsVisibleForProbe(), isFalse,
        reason: '前置：控制条必须真的收起来，否则测不到收起态');
    expect(_bottomBarInTree(), isTrue,
        reason: '前置：常挂（T1 已保证，这里只确认状态没变）');

    final opHidden = _bottomOpacity(t);
    expect(opHidden, isNotNull);
    expect(opHidden!, lessThan(0.02), reason: '前置：收起后要看不见');

    final ignoreHidden = _bottomIgnoring();
    /*
     * ★★★ 本条修复的核心判据。
     */
    expect(ignoreHidden, isTrue,
        reason: '★★★ 收起后必须**点不到**（ignoring==true）。'
            '若为 false ⇒ "看不见但能点到"，用户会误触到看不见的按钮');
  });
}
