// ═══════════════════════════════════════════════════════════════════════
//  Owner 2026-10-12（第四/五次报）：「播放页返回还是卡顿，继续优化」
//
//  fix/return-jank-signature —— ① 指纹含**秒级 position** ② 指纹不分 tab
//                              ③ `load()` 头部的多余 setState
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件守什么（都落在「**重建面**」这个可测量上）
//
// 上一轮加了"数据没变就不 setState"的守卫（`t27_w15_*`），但**判据太粗**：
// ```text
// ① 指纹里有裸 `p.position`（秒级）—— 播完一集回来，进度多走 1 秒
//    ⇒ 指纹判"变了" ⇒ 整棵「我的」重建（实测 F1 = 442 元素 / 26~33ms）
// ② 指纹把 favs/fols/his **三份**全纳入 —— 可 `_cards` 只渲染**当前 tab**
//    ⇒ 在「追更」tab 上「历史」进度变了也全量重建（屏幕上看不见的东西）
// ③ `load()` 头部 `if (!_loadedOnce && mounted) setState(_loading = true)`
//    —— 后端慢/失败时 `_loadedOnce` 不置位 ⇒ **每次返回**都无条件 setState
// ```
//
// # ★ 每条都配阴性 + 阳性对照（本仓铁律：假门禁比没门禁更危险）
// ```text
// 阴性：只有 position 多走几秒（percent 不变）⇒ **不重建**（≤ 阈值）
// 阳性：改 unreadCount / 换 tab      ⇒ **必须**重建（> 100）
//   —— 没有阳性对照，"0 重建"可能是"页面根本没渲染"或"仪器坏了"
// ```
//
// # 为什么用 `debugShelfLoadOverride`（而不是真 FFI）
// `flutter test` 里 `sourin_core.dll` 必失败（error code: 126）⇒ 三路恒 null
// ⇒ 数据永远不变 ⇒ 只能测"不重建"，测不到"该重建时重建"。注入器让两个方向
// 都能量（与 `t27_w15_*` 同一手法）。
@Tags(['native-media'])
library;
// ignore_for_file: avoid_print

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/player_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';

// ═══════════════════════════════════════════════════════════════════════
//  仪器：元素重建计数器（与 `t74_perf_synth_test.dart` 同源）
// ═══════════════════════════════════════════════════════════════════════

/// 这一帧**所有**元素的重建次数之和
int _all = 0;

void _install([Type? watch]) {
  _all = 0;
  debugOnRebuildDirtyWidget = (Element e, bool builtOnce) {
    _all++;
    if (watch != null && e.widget.runtimeType == watch) _all++;
  };
}

void _uninstall() => debugOnRebuildDirtyWidget = null;

/// pump 一帧，返回墙钟微秒（只代表 build 侧，不含 raster —— 见 t74 铁律）
Future<int> _pumpMicros(WidgetTester t) async {
  final sw = Stopwatch()..start();
  await t.pump();
  sw.stop();
  return sw.elapsedMicroseconds;
}

void _claim(WidgetTester t) {
  var n = 0;
  while (t.takeException() != null) {
    if (++n > 200) break;
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  数据构造
// ═══════════════════════════════════════════════════════════════════════

Favorite fav(String id, String title, {int unread = 0}) => Favorite(
      key: 'cctv:$id',
      provider: 'cctv',
      nativeId: id,
      title: title,
      following: true,
      unreadCount: unread,
    );

/// 一条续播记录。`pos` 是**秒**，`dur` 是**秒**。
/// ★ `percent = ((pos*100) ~/ dur)` —— 真正的**渲染**输入（进度条）。
///
/// ⚠️ 默认 `dur: 24000`（不是 2400）是**刻意的** —— 见 `his10` 的注释。
Progress prog(String id, String title, {required int pos, int dur = 24000}) =>
    Progress(
      key: 'cctv:$id',
      provider: 'cctv',
      nativeId: id,
      title: title,
      position: pos,
      duration: dur,
    );

/// 10 部追更（模拟 Owner 的真实规模 —— 442 元素那次就是 10 张卡）
List<Favorite> favs10({int unread = 0}) =>
    [for (var i = 0; i < 10; i++) fav('f$i', '追更片$i', unread: unread)];

/// 10 条历史，position 推进 `step` 秒、每条 `dur` 秒。
///
/// ★★ 关键：`dur = 24000` ⇒ `percent` 每 **240 秒** 才跳 1，且
///   `basePos = 120`（正好落在 band 中点）、`step = 720`（= 3 个 band）
///   ⇒ 10 条的 percent 各为 0/3/6/…/27（互不相同），
///   而 **+30 秒绝不跨档**。
///   ⇒ 这正是"播了 30 秒回来、进度条逐像素不变"的最小复现。
///
/// ⚠️ 踩过的坑（两版才选对粒度）：
/// ```text
/// 第一版 dur:2400（band=24s）+ step:30 ⇒ 条目直接跨档（h3: 8→9）⇒ 红得"有理"
/// 第二版 dur:24000 + base:1200 + step:30 ⇒ 1200 距 band 边界只有 30s，
///        h7 的 1410→1440 正好踩到 6.0 ⇒ 又跨档 ⇒ 仍红
/// ⇒ 必须 base 落在**band 正中间**、step 取 band 的整数倍，才不受边界影响。
/// ```
List<Progress> his10({int basePos = 120, int step = 720, int dur = 24000}) =>
    [for (var i = 0; i < 10; i++) prog('h$i', '历史片$i', pos: basePos + i * step, dur: dur)];

/// 抖动 30 秒后的同一批历史（percent **逐条不变** —— 见 `his10` 的粒度说明）
List<Progress> his10Jittered() =>
    [for (var i = 0; i < 10; i++) prog('h$i', '历史片$i', pos: 150 + i * 720, dur: 24000)];

/// `debugShelfLoadOverride` 的返回值 —— **顺序是 (收藏, 追更, 历史)**！
///
/// ⚠️ 踩过的坑：`load()` 里是
/// `final (f, fo, h) = await ov(); results = [f, fo, h]`
/// 且 `results[0] as List<Favorite>?` 是**收藏**（`listFavorites(followingOnly:
/// false)`）—— 把 `favs10()`（其实是追更数据）放进第 0 位，会被当成"收藏"，
/// 而追更位变成空 ⇒ 指纹判"追更从 10 条变 0 条" ⇒ 假阳性。
/// ⇒ 这个 helper 把位置固定下来，杜绝再错。
(List<Favorite>, List<Favorite>, List<Progress>) shelfData({
  List<Favorite>? favorites,
  List<Favorite>? following,
  List<Progress>? history,
}) =>
    (favorites ?? <Favorite>[], following ?? <Favorite>[], history ?? <Progress>[]);

/// 挂 `MyShelf`（裸，不经过 shell）
Future<void> _mount(WidgetTester t, GlobalKey<MyShelfState> key) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MyShelf(
          key: key,
          onOpenDetail: (_, __) {},
          onPlay: (_, __, ___, ____, _____) {},
        ),
      ),
    ),
  );
  await t.pump();
  await t.pump(const Duration(milliseconds: 100));
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ 核心用例
// ═══════════════════════════════════════════════════════════════════════

void main() {
  /*
   * ★ ④ 要 push 真 PlayerPage ⇒ 必须先 `MediaKit.ensureInitialized()`
   *   （否则 build 抛 "MediaKit.ensureInitialized must be called..."）。
   *   与 `test/pc_arrow_keys_test.dart:209` 同一手法：指向仓库自带的 libmpv。
   * ⚠️ 这就是本文件被标 `native-media` 的原因（加载 libmpv 会让
   *   flutter_tester 偶发 native 崩溃）⇒ 默认不跑，跑时
   *   `--run-skipped --tags native-media --concurrency=1`。
   */
  setUpAll(() {
    /*
     * ⚠️ worktree 里没有 `build/` 产物（那是主检出的）⇒ 若本地找不到，
     *    回退到主检出路径 —— 只为让"在 worktree 里跑"也能跑起来。
     */
    final candidates = [
      File('build/windows/x64/libmpv/libmpv-2.dll'),
      // worktree 是 `.claude/worktrees/<name>/` ⇒ 主检出往上是三级
      File('../../../build/windows/x64/libmpv/libmpv-2.dll'),
      File('../../build/windows/x64/libmpv/libmpv-2.dll'),
    ];
    for (final dll in candidates) {
      if (dll.existsSync()) {
        MediaKit.ensureInitialized(libmpv: dll.absolute.path);
        print('RJ|libmpv = ${dll.absolute.path}');
        return;
      }
    }
    print('RJ|★ 警告：没找到 libmpv-2.dll ⇒ ④ 会被跳过（前置不成立）');
  });

  tearDown(() {
    _uninstall();
    debugShelfLoadOverride = null;
    RemoteBridge.instance.stop();
  });

  // ───────────────────────────────────────────────────────────────────
  //  ① position-only 变更 ⇒ 不重建
  // ───────────────────────────────────────────────────────────────────
  //
  // 判据：favs/fols 全等（都是空），**只有 history 的 position 多走几秒**
  //       而 percent **保持不变** ⇒ 屏幕上每个像素都一样 ⇒ 不该重建。
  //
  // ⚠️ 用 `pos: 1200 → 1230`（dur 24000）：percent 都是 5 ⇒ **渲染输入全等**。
  testWidgets('① position 秒级抖动（percent 不变）⇒ 不重建（≤ 20 元素）',
      (t) async {
    final key = GlobalKey<MyShelfState>();
    await _mount(t, key);

    // 前置：history tab 上真的渲染了 10 张卡（否则下面是"空树"读数）
    key.currentState!.debugSetData(
      following: favs10(),
      history: his10(),
      tab: ShelfTab.history,
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('历史片0'), findsOneWidget,
        reason: '★ 前置不成立：history tab 没渲染出卡片 ⇒ 下面的读数全是空树的');

    // 之后每次 load() 都是**等价**数据、只有 position 秒级前进（percent 不变）
    // 120→126（dur 2400）：percent 都是 5 ⇒ 渲染输入全等
    debugShelfLoadOverride = () async => shelfData(
          following: favs10(),
          history:
              his10Jittered(),
        );

    // ★ 阴性对照：先泵两帧让动画/首帧稳定，再静置一帧读基线
    await t.pump(const Duration(milliseconds: 100));
    _install();
    await t.pump();
    final settle = _all;
    _uninstall();
    print('RJ①|阴性对照（静置）重建=$settle');

    // ★ 被测：position 秒级抖动、percent 不变 ⇒ 不重建
    _install();
    await key.currentState!.load();
    await t.pump();
    final jitter = _all;
    _uninstall();
    print('RJ①|position 秒级抖动（percent 不变）load() 后重建=$jitter');
    expect(jitter, lessThanOrEqualTo(20),
        reason: '★★★ 只有 position 秒级前进、卡片渲染的 percent 没变，'
            '却重建了 $jitter 个元素 —— 这正是 Owner 报的「返回卡顿」：'
            '播完一集回来，进度多走 1 秒 ⇒ 指纹判"变了" ⇒ 整棵「我的」重建。'
            '（修复前实测 F1 = 442 元素 / 26~33ms）');

    // ★★ 阳性对照（必须有 —— 证明仪器真有区分力）
    //    改 unreadCount（**同规模**列表，只改徽标数）⇒ 必须重建
    debugShelfLoadOverride = () async => shelfData(
          following: favs10(unread: 7),
          history:
              his10Jittered(),
        );
    key.currentState!.debugSetData(tab: ShelfTab.following);
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    _install();
    await key.currentState!.load();
    await t.pump();
    final changed = _all;
    _uninstall();
    print('RJ①|阳性对照：unreadCount 变了 load() 后重建=$changed');
    expect(changed, greaterThan(100),
        reason: '★★ 阳性对照失败：数据真的改了却不重建 ⇒ '
            '仪器没有区分力 ⇒ 上面"不重建"的读数证明不了任何事'
            '（也可能刷新语义被守卫吃掉了）');
  });

  // ───────────────────────────────────────────────────────────────────
  //  ② 按当前 tab 分栏 + 切 tab 仍会刷新
  // ───────────────────────────────────────────────────────────────────
  //
  // ⚠️ 这一条守的是**双向**：
  //   (a) 在 following tab 上改 history ⇒ **不**重建（省的是看不见的东西）
  //   (b) 切到 history tab            ⇒ **必须**重建（防"切 tab 不刷新"回归）
  testWidgets('② following tab 上改 history ⇒ 不重建；切到 history tab ⇒ 重建',
      (t) async {
    final key = GlobalKey<MyShelfState>();
    await _mount(t, key);

    // 初始：following 有 10 部、history 有 10 条；停在 following tab
    key.currentState!.debugSetData(
      following: favs10(),
      history: his10(),
      tab: ShelfTab.following,
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('追更片0'), findsOneWidget, reason: '前置：following tab 有卡');

    // 数据没变，但换一个 history 数组（position 大改、percent 也变）
    // —— following tab 上看不见 history ⇒ 不该重建
    debugShelfLoadOverride = () async => shelfData(
          following: favs10(),
          history: [for (var i = 0; i < 10; i++) prog('h$i', '历史片$i', pos: 900)],
        );
    _install();
    await key.currentState!.load();
    await t.pump();
    final hiddenChange = _all;
    _uninstall();
    print('RJ②|following tab 上 history 大变 load() 后重建=$hiddenChange');
    expect(hiddenChange, lessThanOrEqualTo(20),
        reason: '★★★ 在「追更」tab 上，「历史」的进度变了也重建了整页 —— '
            '那 10 条历史根本不在屏幕上（`_cards` 只渲染当前 tab）。');

    /*
     * ★ 阳性对照：走**真实** tab 切换路径（点 tab 栏上的「播放历史」）。
     *
     * `_ShelfTabs` 的 onSelect = `_selectTab`（**私有**，没有测试钩子）⇒
     * 只能点 UI。这也更真实 —— 它验证的是"用户点了 tab 真的会刷新"，
     * 而不是"我调了某个内部方法"。
     */
    _install();
    await t.tap(find.text('播放历史'));
    await t.pump(); // setState(_tab = history) 生效
    // `_selectTab` 内部 `unawaited(load())` —— 这里等它跑完落帧
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    final afterSwitch = _all;
    _uninstall();
    print('RJ②|点「播放历史」tab 后重建=$afterSwitch');
    expect(afterSwitch, greaterThan(100),
        reason: '★★ 切到 history tab 却没有重建（$afterSwitch）—— '
            '指纹只比当前 tab 那份后，"切 tab 必刷新"必须仍然成立');
    expect(find.text('历史片0'), findsOneWidget,
        reason: '★★ 切到 history tab 后没有渲染出历史卡 ⇒ 切 tab 刷新被弄坏了');
  });

  // ───────────────────────────────────────────────────────────────────
  //  ③ `load()` 头部的多余 setState（首屏之外不再 setState）
  // ───────────────────────────────────────────────────────────────────
  //
  // 场景：`_loadedOnce == false`（首屏一直没成功，比如后端慢/无核心库）
  //       反复返回时，旧写法**每次都** setState(_loading=true)。
  testWidgets('③ 未加载成功时反复 load()：头部不再无条件 setState',
      (t) async {
    final key = GlobalKey<MyShelfState>();
    await _mount(t, key);

    /*
     * 让三路**全失败**（override 返回 null 等价于 FFI 失败 —— 用抛异常模拟）
     * ⇒ `_loadedOnce` 永远不置位 ⇒ 每次都走到"头部 setState"那条老路。
     */
    debugShelfLoadOverride = () async {
      throw Exception('模拟后端不可用（三路全失败）');
    };

    // 第一次：首屏骨架路径，允许 setState（应该显示骨架）
    _install();
    await key.currentState!.load();
    await t.pump();
    final first = _all;
    _uninstall();
    print('RJ③|首屏（未加载过）load() 后重建=$first');

    // 第二次、第三次：`_loadedOnce` 仍为 false（全失败），但**已经显示过骨架**
    // ⇒ 修复后**不再**每次都 setState(_loading=true)。
    final reps = <int>[];
    for (var i = 0; i < 3; i++) {
      _install();
      await key.currentState!.load();
      await t.pump();
      reps.add(_all);
      _uninstall();
    }
    print('RJ③|全失败下反复 load() 重建面=${reps}');
    expect(reps.every((n) => n <= 20), isTrue,
        reason: '★★★ 后端一直失败（`_loadedOnce` 不置位）时，每次 load() 都'
            '无条件 setState(_loading=true) ⇒ 每次返回都白重建整棵子树。'
            '实测该帧 134 元素。读数=$reps');
  });

  // ───────────────────────────────────────────────────────────────────
  //  ④ shell 路径：真 ShellPage + push/pop 真 PlayerPage ⇒ F1 上界
  // ───────────────────────────────────────────────────────────────────
  testWidgets('④ shell：push 真 PlayerPage 再 pop ⇒ 返回帧 F1 元素数上界',
      (t) async {
    await t.binding.setSurfaceSize(const Size(1280, 900));
    addTearDown(() => t.binding.setSurfaceSize(null));

    RemoteBridge.instance.stop();
    addTearDown(() => RemoteBridge.instance.stop());

    await t.pumpWidget(
      MaterialApp(
        home: ShellPage(key: debugShellKey),
      ),
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 200));
    _claim(t);

    // 让「我的」有 10 部追更 + 10 条历史（模拟真实规模）
    final shelf = _findShelf(t);
    expect(shelf, isNotNull,
        reason: '★ 前置：shell 里没找到 MyShelf ⇒ 读数无意义');
    shelf!.debugSetData(
      following: favs10(),
      history: his10(),
      tab: ShelfTab.following,
    );
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    _claim(t);

    // push 真 PlayerPage
    final nav = Navigator.of(t.element(find.byType(ShellPage)));
    _install();
    nav.push(MaterialPageRoute<void>(
      builder: (_) => const PlayerPage(
        provider: 'cctv',
        id: 'cctv1',
        title: '返回卡顿验收',
        isTv: false,
        isTouchOnly: false,
      ),
    ));
    for (var i = 0; i < 6; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    _uninstall();
    _claim(t);
    expect(find.byType(PlayerPage), findsOneWidget,
        reason: '★ 前置：PlayerPage 没 push 上去 ⇒ 下面没有"返回"可言');

    /*
     * ★ pop 回来的第 2 帧（F1）—— Owner 感到"不卡"的判据落在这一帧。
     *
     * 帧编号口径（与 `.probe` 逐帧探针一致）：
     *   F0 = pop 触发的第一帧（这是**框架层**：路由过渡/`_ModalScopeStatus`
     *        变更，实测 149 元素 / 14~18ms，**无法从应用层消除**）
     *   F1 = 紧随其后的一帧（应用层的全量重建落在这里 —— 修复前 442 元素）
     */
    // 数据**没变**（override 返回等价数据，只有 history 秒级抖动）
    debugShelfLoadOverride = () async => shelfData(
          following: favs10(),
          history: his10Jittered(),
        );

    // ★ 真 pop —— 这才是"从播放页返回"
    nav.pop();
    _install();
    final f0 = await _pumpMicros(t); // F0：pop 帧（框架层）
    final f0n = _all;
    _install();
    final f1 = await _pumpMicros(t); // F1：应用层刷新落点（关键帧）
    final f1n = _all;
    _install();
    final f2 = await _pumpMicros(t);
    final f2n = _all;
    _uninstall();
    _claim(t);

    print('RJ④|shell push/pop 逐帧：'
        'F0=$f0n el/${f0}us  F1=$f1n el/${f1}us  F2=$f2n el/${f2}us');

    // ★ 等 pop 过渡动画走完（F0/F1/F2 三帧不够 —— 过渡还在跑）
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 50));
    }
    _claim(t);

    // ★ 前置复核：pop 之后 PlayerPage 必须真的没了（否则量的是别的帧）
    expect(find.byType(PlayerPage), findsNothing,
        reason: '★ pop 之后 PlayerPage 还在 ⇒ 帧编号口径不成立');

    /*
     * ★ 上界：修复前 F1 = 442 元素（`PosterCard×10` + `Text×27` + …）。
     *   修复后 F1 应回到 55 附近的框架层水平。
     *   阈值取 120 —— 松到能容测试环境抖动，紧到能在"没修"时**必红**
     *   （442 ≫ 120）。
     */
    expect(f1n, lessThanOrEqualTo(120),
        reason: '★★★ 返回帧 F1 重建了 $f1n 个元素（修复前实测 442）—— '
            '这正是 Owner 感到的「播放页返回卡顿」。'
            '见本文件头 ①②③ 三条根因。');
  });
}

/// 在 shell 树里找 `MyShelfState`（home tab 上）。
MyShelfState? _findShelf(WidgetTester t) {
  for (final e in t.allElements) {
    final s = e;
    if (s is StatefulElement && s.state is MyShelfState) {
      return s.state as MyShelfState;
    }
  }
  return null;
}
