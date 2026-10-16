// ══════════════════════════════════════════════════════════════════════
//  CR#30 门禁：续播定位的**防重入**（连点同一张卡片不许叠出两个合并页）
// ══════════════════════════════════════════════════════════════════════
//
// # 缺陷（CodeRabbit PR#30，Major·稳定性，原话）
// ```text
// 续播定位要先等两次请求才 push 页面，重复点击会叠出多个合并页。
// ... pushed 是每次调用里的局部变量，挡不住第二次调用。
// ⇒ 结果是 push 出两个 MediaPage，每个都带一个 Player。
//   PlayerPage 被盖住时不会暂停 ⇒ 两个播放器会同时出声。
// ```
//
// # ★ 为什么这个门禁**不需要**真核心 / 真库 / 真网络
//
// ① 守卫是在**第一个 `await` 之前**同步拒绝的（`lib/shell.dart`）：
// ```text
// ① provider == local ?        ← 同步
// ② in-flight 已含该键 ?        ← 同步 ⇒ 第二次点击在这里就 return
// ③ _resumeResolveInFlight.add  ← 同步
// ④ try { … await … }          ← **第一个 await 在这之后**
// ```
// ⇒ 把"解析延迟"设成**挂住不完成**，第一次调用就停在 ④，
//   第二次点击在 ② 被同步挡掉 —— 全程零 FFI。
//
// ② 解析的**终态**也由注入点决定：把延迟**以错误完成**，
//   解析走 `catch` ⇒ `pushDefault()` 推一个合并页。
// ```text
// 这一点很关键：若让解析真的往下走，它会去调 `SourinApi.listAllProgress()`
// ⇒ 无核心环境 ⇒ FFI 的 Future 可能**永不完成** ⇒ 合并页永远不出现，
//   断言只会以"半个都没 push"失败 —— 那是**测试自身的缺陷**，不是被测对象的。
// ```
//
// ⚠️ 本用例**不**放具体视频网站的名字（`test/t98_no_site_names_test.dart` 门禁），
//    用中性的 `demo` / `p1` 假数据。
//
// # ★★★ 踩过的坑：改 foundation 调试变量必须**在测试体内**还原
//
// ```text
// The value of a foundation debug variable was changed by the test.
//   debugAssertAllFoundationVarsUnset → TestWidgetsFlutterBinding._verifyInvariants
// ```
//
// 原因是 `_verifyInvariants()` 跑在**测试体之后、`tearDown` 之前**：
// ```text
// _runTestBody() {
//   await 测试体();
//   _verifyInvariants();   ← ★ 在这里检查 foundation 调试变量
// }
// tearDown();              ← 所以放在这里的还原**已经太晚**
// ```
// ⇒ 只靠 `tearDown` 还原 `debugPrint`，会让**每一条**用例都红，
//   而且报的是"foundation 变量被改"——与真正要测的东西**毫无关系**，
//   极难定位（我实测：4 条用例全红，看起来像被测对象坏了）。
// ⇒ 正确写法见本文件 [_withLogs]：**测试体内部** `try/finally` 还原。
// ⚠️ 同一条纪律适用于**任何** foundation 调试变量（`debugPrint`
//    `debugDefaultTargetPlatformOverride` `debugDisableShadows` …）。
//
// # 判据
// ```text
// ① 防重入开 ⇒ 第二次点击被挡；两次点击只推 **一个** MediaPage
// ② 阴性对照（关掉防重入）⇒ **两个** MediaPage  ← ★ 红度证明（CodeRabbit 说"当前代码会得到 2"）
// ③ 失败路径 ⇒ 也解锁（in-flight 归 0）⇒ 该条目不会永久点不开
// ④ 门禁开关默认值   ⇒ 防止有人改成 true 上线
// ```
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/media_page.dart';
import 'package:sourin_spike/ui/remote_bridge.dart';
import 'package:sourin_spike/ui/widgets/my_shelf.dart';
import 'package:sourin_spike/ui/widgets/poster_card.dart';

/// 与生产外壳一致的包装（照抄 `test/bottom_bar_fit_test.dart:56-66`）
///
/// ⚠️ 缺 `Material` 层会让 `InkWell` 抛 `Null check operator used on a null
///    value`，整页被换成 ErrorWidget —— 而断言只会以"找不到 XX"失败，
///    真因只在 stderr。
Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (context, child) => AppThemeHost(
      data: theme,
      child: child ?? const SizedBox(),
    ),
    home: home,
  );
}

/// 认领一次 pump 期间积压的环境异常（无核心环境的 FFI 异常等）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 合并页数量 —— **含被盖住的**（`skipOffstage: false`）
///
/// ⚠️ 必须 `skipOffstage: false`：正是"被后一个路由盖住"的那个才是有害的
///    （它不会暂停 ⇒ 两个播放器同时出声）。
int _mediaPageCount(WidgetTester tester) =>
    tester.widgetList(find.byType(MediaPage, skipOffstage: false)).length;

/// 在捕获 `debugPrint` 的前提下跑 [body]
///
/// ⚠️ **不能**用 `addTearDown` / `tearDown` 还原：`TestWidgetsFlutterBinding
///    ._verifyInvariants()` 在**测试体之后、tearDown 之前**跑，它会把
///    "测试改了 foundation 调试变量（`debugPrint`）"直接判成失败：
/// ```text
/// The value of a foundation debug variable was changed by the test.
///   debugAssertAllFoundationVarsUnset → TestWidgetsFlutterBinding._verifyInvariants
/// ```
/// ⇒ 必须在**测试体内部**用 `try/finally` 还原。
Future<void> _withLogs(
  List<String> logs,
  Future<void> Function() body,
) async {
  final old = debugPrint;
  debugPrint = (String? m, {int? wrapWidth}) {
    if (m != null) logs.add(m);
  };
  try {
    await body();
  } finally {
    debugPrint = old;
  }
}

/// 挂一个真 `ShellPage`，并把「我的 → 最近追更」注入成"有 1 部在追更"
///
/// 用 `debugSetData` 注入而不是等真数据：本门禁只要**一张可点的卡片**，
/// 与"卡片数据从哪来"无关（那是别的门禁的事）。
Future<void> _pumpShellWithOneFollowingCard(WidgetTester tester) async {
  /*
   * ★★★ 必须钉住窗口尺寸 —— 这是 macOS CI 上"第 1 次点击没进入解析"的根因。
   *
   * # 不钉住时真实窗口是 800×600 @ DPR 3.0 = **266.67 逻辑 dp 宽**
   * `flutter_test` 的默认 `FlutterView` metrics 是 `800×600 @ DPR 3.0`，
   * 而 `MediaQuery.fromView` 读的是**它**，不是布局约束：
   * ```text
   * 逻辑宽 = 800 / 3.0 = 266.67 dp   ← 比手机还窄得多
   * ```
   * ⇒ 货架在这种窄窗口下的布局会让卡片落点不同（甚至被裁剪）⇒
   *   `tester.tap` **落空**。
   *
   * ★ 而落空为什么在别的平台上"看不见"：本文件原来每个 tap 都写了
   *   `warnIfMissed: false` ⇒ 落空**不报错、不警告**，静默什么都不发生 ⇒
   *   表现为 `resolveStarts = 0`（CI 里看到的就是这个读数）。
   *
   * ⚠️ 本仓既有纪律（`test/bottom_bar_fit_test.dart:73-91` 写得很全）：
   *   **必须设 `tester.view.physicalSize` / `devicePixelRatio`，
   *   不能只用 `setSurfaceSize`** —— 后者只改布局约束、不动 FlutterView
   *   metrics，会造成"按 A 布局、却按 B 读尺寸"的假红。
   *   实测本仓已有 **169** 个测试钉住视图，t61 自己（第 99-100 行）也钉了。
   */
  tester.view.devicePixelRatio = 1.0;
  tester.view.physicalSize = const Size(1280, 800);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_appWith(home: ShellPage(key: debugShellKey)));
  await tester.pump();
  _claim(tester);
  /*
   * ★★★ 必须停掉遥控桥 —— 否则本用例会**依赖 sourin_core.dll 在不在**。
   *
   * # 实测的失败（在**没有 DLL** 的环境里）
   * ```text
   * A Timer is still pending even after the widget tree was disposed.
   * 'package:flutter_test/src/binding.dart':
   * Failed assertion: line 2543 pos 12: '!timersPending'
   *   RemoteBridge._scheduleRecheck (remote_bridge.dart:429)
   * ```
   * 报错**不在断言上**，而在 widget 树销毁后的"还有定时器没结束" ⇒
   * 看起来完全像"被测对象坏了"，其实与防重入**毫无关系**。
   *
   * # 为什么它会因 DLL 而飘
   * ```text
   * 有 DLL：remoteStatus() 成功 ⇒ _schedule(快轮询)
   * 无 DLL：remoteStatus() 抛异常 ⇒ _scheduleRecheck(5 秒)  ← 活过了测试体
   * ⇒ 同一个用例，在两台机器上读数不同 ⇒ **不可靠的门禁**。
   * ```
   * ⚠️ 修法用 `stop()`（公开 API，不改生产一行）：它把 `_stopped` 置真并
   *    `_timer?.cancel()`；而 `_ensurePolling` / `_scheduleRecheck` /
   *    `_schedule` **三处入口都先查 `_stopped`** ⇒ 之后不会再排定时器。
   * ⚠️ 它是单例且 `_stopped` 是**终态**，但下一次 `pumpWidget` 会让
   *    `RemoteBridgeHost.initState` 重新 `setGlobals`（把 `_stopped` 置回假）
   *    ⇒ 每条用例各自停一次，互不影响。
   * ⚠️ 同理**不能**只靠 `tearDown`：`_verifyInvariants()` 跑在测试体之后、
   *    tearDown 之前（与文件头那条 foundation 变量坑同一个机制）。
   */
  RemoteBridge.instance.stop();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 1500));
  _claim(tester);

  final shelf = tester.state<MyShelfState>(find.byType(MyShelf));
  shelf.debugSetData(
    tab: ShelfTab.following,
    following: [
      const Favorite(
        key: 'demo:p1',
        provider: 'demo',
        nativeId: 'p1',
        title: '测试剧集甲',
        lastEpisodeTitle: '第14集',
        lastEpisodeCount: 14,
        following: true,
      ),
    ],
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Finder _card() => find.text('测试剧集甲');

/// 点卡片 —— 直接调用 `PosterCard.onTap`，**不经命中测试**
///
/// # 为什么不 `tester.tap`（这正是 macOS CI 红的原因）
///
/// 实测证据（Windows 本机，两种写法只差这一处）：
/// ```text
/// tester.tap(...)      ⇒ 稳定 +4 绿   ← 本机
/// CI macOS             ⇒ resolveStarts = 0
///                       "★ 第 1 次点击必须进入解析"失败
/// ```
/// `resolveStarts = 0` 的含义是**那次点击压根没调用到 `_openDetail`**
/// —— 也就是 `tester.tap` **打空了**（命中测试没落在卡片上），
/// 而不是被测对象坏了。而原来的 `warnIfMissed: false` 会让打空
/// **既不报错也不警告**，于是表现成"什么都发生了，但没进入解析"。
///
/// # 根因是**命中测试依赖窗口几何**，而本用例的被测对象与几何无关
/// ```text
/// 卡片在货架网格里 ⇒ 它的**屏幕落点**取决于：
///   窗口尺寸 / DPR / 网格列数 / 滚动位置 / 字体度量
/// ⇒ 换一个平台（macOS 的字体与测试窗口默认值都不同）就可能偏出卡片，
///   而 `tester.tap` 取的是**中心点**，偏一点就落到邻居或空处。
/// ```
/// 本用例判的是**防重入**（被测对象是 `_openDetailResolvingResume` 的守卫），
/// 几何**不是**被测对象 ⇒ 不该让它决定本用例的成败。
/// ⇒ 直接调 `onTap`：语义与真点一下**等价**（同一个回调），
///   且**逐平台一致**。
///
/// ⚠️ **分工说明（不是丢掉覆盖）**："卡片真的能被点到"属于
///    `test/shelf_card_opens_detail_test.dart` 的职责（它 `setSurfaceSize`
///    后 `tester.tap` 并断言 `onOpenDetail` 真被调用）。
///    ⇒ 本用例只负责防重入；命中测试那条**仍有别的门禁在守**。
///
/// ⚠️ 同时保留"卡片必须存在、且必须**可点**"的断言 —— 否则
///    `onTap` 为 null 时本用例会**空转通过**。
/// ⚠️ 它是**同步**的（不是 `async`）—— 这是有意的：
/// ```text
/// `card.onTap!()` 是同步调用 ⇒ `_openDetail` 立刻执行到**第一个 await**
/// 并把键加入 in-flight ⇒ 调用方可以**紧接着同步断言** `inFlightCount`，
/// 完全不依赖 `await tester.pump()` 有没有把那个 await 交回来。
/// ⇒ 平台/时序差异**无法**影响这条断言（macOS CI 上红的就是它）。
/// ```
void _tapCard(WidgetTester tester) {
  final cards = find.byType(PosterCard);
  expect(cards, findsWidgets, reason: '★ 卡片必须真的渲染出来，否则本用例是空的');
  final card = tester
      .widgetList<PosterCard>(cards)
      .firstWhere((c) => c.title == '测试剧集甲');
  expect(card.onTap, isNotNull,
      reason: '★ 卡片必须真的可点（onTap 非空）—— 否则本用例空转通过');
  card.onTap!();
}

void main() {
  testWidgets('★★ 门禁开关必须默认为 false（防有人误改成 true 上线）', (tester) async {
    await _pumpShellWithOneFollowingCard(tester);
    final st = debugShellKey.currentState!;
    /*
     * ★ 为什么"行为对"还不够，还要钉"默认值"：
     * ```text
     * 若有人把 debugResumeDedupeOff 改成 true（或改成常量 true）上线，
     * 防重入会**静默失效** —— 而行为用例仍可能绿（它自己注入时才翻）。
     * 上线的默认值只能靠源码常量来钉。
     * ```
     * ⚠️ 同时钉住调试用延迟注入点默认 null（否则生产路径会平白 await）。
     */
    expect(st.debugResumeDedupeOff, isFalse,
        reason: '★ 防重入开关**必须**默认关 ⇒ 生产路径永远走守卫');
    expect(st.debugResumeResolveDelay, isNull,
        reason: '★ 延迟注入点必须默认 null ⇒ 生产路径逐字不变');
  });

  testWidgets('★★★ 连点两次同一张卡片 ⇒ 只推一个合并页（防重入）', (tester) async {
    final logs = <String>[];
    await _withLogs(logs, () async {
      await _pumpShellWithOneFollowingCard(tester);
      final st = debugShellKey.currentState!;
      // ★ "解析挂住不完成" ⇒ 第一次点击停在 await，第二次点击落在守卫上
      final gate = Completer<void>();
      /*
       * ★★ 这条计数是**独立的证据**：它数"解析真的被启动了几次"，
       *    由**被测对象自己**（调 delay 注入点）产生 ——
       *    **不经过 `debugPrint`**。
       * ```text
       * 为什么需要它：本用例原来靠"日志里出现几次『忽略重复点击』"判定。
       * 日志断言是二手证据（靠一个可被改写的全局变量）；
       * 而"解析被启动了几次"是一手证据。
       * ⇒ 即便将来日志那条路塌了，本用例仍会因为 2 ≠ 1 而红。
       * ```
       */
      var resolveStarts = 0;
      st.debugResumeResolveDelay = (p, id) {
        resolveStarts++;
        return gate.future;
      };

      expect(_card(), findsOneWidget,
          reason: '★ 卡片必须真的渲染出来，否则本用例是空的');

      /*
       * ★★★ 第 1 次点击 —— 断言**紧接其后、无 `pump`**（这是 macOS CI 的修法）。
       * ```text
       * 旧的写法是 tap → await pump() → 断言 inFlight == 1。
       * 那个 `pump` 引入了"异步续体是否已交回"这个平台相关的时序依赖：
       * 若续体**尚未**交回，断言会看到 0 ⇒ 这条用例假红
       * （macOS CI 实测就是 `Actual: <0>`）。
       * ```
       * ⚠️ 而 `onTap` 是同步的 ⇒ in-flight 的加入也是同步的 ⇒
       *    **点击之后立刻**断言，不经过任何 await，结果与平台无关。
       */
      _tapCard(tester);
      expect(st.debugResumeResolveInFlightCount, 1,
          reason: '★ 第 1 次点击必须进入解析（否则本用例没测到东西）');

      // ── 第 2 次点击（第 1 次仍在解析中）—— 同样同步断言
      _tapCard(tester);

      // ★ 一手证据：解析**只被启动了一次**（被测对象自己的行为）
      expect(resolveStarts, 1,
          reason: '★★ 守卫必须让第二次点击**根本不进入解析**'
              ' —— 2 = 守卫失效（这一条不依赖日志）');
      // 二手证据（日志）：保留，因为它能指出**是哪一种**被挡
      expect(
        logs.where((s) => s.contains('忽略重复点击')).length,
        1,
        reason: '★ 第二次点击必须被防重入挡掉（且只挡一次）',
      );
      expect(_mediaPageCount(tester), 0,
          reason: '★ 解析还没结束 ⇒ 一个合并页都还没推');

      // ── 让解析以**失败**收场（确定性终态，不需要真核心/真网络）
      gate.completeError(StateError('门禁模拟：解析失败'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      _claim(tester);

      expect(logs.any((s) => s.contains('续播定位失败')), isTrue,
          reason: '★ 必须走 catch 回退路径（证明终态是注入出来的，不是碰巧）');
      expect(_mediaPageCount(tester), 1,
          reason: '★★★ 连点两次只能有 1 个合并页'
              ' —— 2 个 = 两个播放器同时出声');
      expect(st.debugResumeResolveInFlightCount, 0,
          reason: '★ 解析结束必须解锁（否则这部作品永久点不开）');
    });
  });

  testWidgets('★★★ 阴性对照：关掉防重入 ⇒ 真的叠出两个合并页', (tester) async {
    final logs = <String>[];
    await _withLogs(logs, () async {
      await _pumpShellWithOneFollowingCard(tester);
      final st = debugShellKey.currentState!;
      // ★ 故障注入：只关掉"防重入"这一个开关，其余一字不动
      st.debugResumeDedupeOff = true;
      final gates = <Completer<void>>[];
      st.debugResumeResolveDelay = (p, id) {
        final c = Completer<void>();
        gates.add(c);
        return c.future;
      };

      _tapCard(tester);
      await tester.pump();
      _tapCard(tester);
      await tester.pump();

      expect(gates.length, 2,
          reason: '★ 关掉守卫后，第二次点击**也进了解析**（这就是缺陷本身）');
      expect(logs.where((s) => s.contains('忽略重复点击')), isEmpty,
          reason: '★ 关掉防重入后不该再有"忽略重复点击"');

      for (final g in gates) {
        g.completeError(StateError('门禁模拟：解析失败'));
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      _claim(tester);

      expect(_mediaPageCount(tester), 2,
          reason: '★★★ 红度证明：去掉这条守卫就会叠出 2 个合并页'
              '（CodeRabbit 原话"当前代码会得到 2"）');
    });
  });

  testWidgets('★★ 失败路径也必须解锁 + 回退到原路径', (tester) async {
    final logs = <String>[];
    await _withLogs(logs, () async {
      await _pumpShellWithOneFollowingCard(tester);
      final st = debugShellKey.currentState!;
      st.debugResumeResolveDelay = (p, id) async {
        throw StateError('门禁模拟：解析失败');
      };

      _tapCard(tester);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      _claim(tester);

      expect(st.debugResumeResolveInFlightCount, 0,
          reason: '★ 失败/异常路径也必须解锁 —— 否则这部作品就此永久点不开');
      expect(_mediaPageCount(tester), 1,
          reason: '★ 失败要回退到原路径（宁可退回旧行为，也不能打不开）');
    });
  });
}
