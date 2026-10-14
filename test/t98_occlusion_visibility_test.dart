// ═══════════════════════════════════════════════════════════════════════
//  t98 路由遮挡 → shell 可见性 —— 回归守卫（2026-10-13）
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件守的是什么（两个已交付的提交）
//
// ```text
// 8726ddd  修复：从播放页返回卡顿 —— 路由遮挡未计入直播页可见性
// 9441f71  优化：从播放页返回卡顿 —— 离场页光栅快照
// ```
// 根因（Owner 报「从播放页返回还是会卡卡的」）：
// ```text
// _ShellPageState._syncVisibility() 的可见性投影**只认 tab**：
//     final v = _activeTab.value == AppTab.live;
// 但「选中直播 tab」≠「直播画面真的在被看」：
//   在直播 tab 上 push 播放页 ⇒ _activeTab **没变** ⇒ _liveVisible 仍是 true
//   ⇒ 直播内嵌播放器继续解码 + 继续驱动**原生视频输出层**
//     （那层不画进 Flutter 层 ⇒ Offstage / TickerMode 管不到）
//   ⇒ push / pop 两帧都要把这层仍活着的画面合成进去 ⇒ 卡
// ```
// 修法（已在 lib/shell.dart 里）：
// ```text
// ① ShellOcclusionObserver（NavigatorObserver）维护
//    「盖在 shell 上面的路由条数」ValueNotifier<int> occluders：
//      didPush(_, previousRoute.isFirst)         ⇒ +1
//      didPop / didRemove(_, previousRoute.isFirst) ⇒ -1（夹到 0）
// ② _syncVisibility() 改为
//      v = (tab == live) && (occlusion?.value ?? 0) == 0
// ③ _ShellPageState.initState 订阅 widget.occlusion?.addListener(_syncVisibility)
// ④ ShellPage 新增构造参数 final ValueListenable<int>? occlusion
// ```
//
// ═══════════════════════════════════════════════════════════════════════
// ★★★ 红度验证（本仓铁律「判据测不出反面 ⇒ 结论作废」）
// ═══════════════════════════════════════════════════════════════════════
//
// 每条判据都**必须**能测出反面。把 shell.dart 里那行改回
// ```dart
// final v = _activeTab.value == AppTab.live;   // ← 去掉遮挡维
// ```
// 则本文件的 group-2「端到端」用例**必须变红**；把观察者的 `_bump` 去掉
// 则 group-1 必红。实测红度输出见交付报告。
//
// # 为什么分两层
// ```text
// group-1  ShellOcclusionObserver 单测（不挂 widget）
//          ⇒ 只测「计数逻辑」本身，快、无环境依赖
// group-2  端到端（挂真 ShellPage + ShellScope + LivePage）
//          ⇒ 测「接线」—— 即 notifier 变化后 LivePage 收到的 visible 跟着变
// ```
// ★ 两层缺一不可：group-1 绿 + group-2 绿才能证明「观察者算对了 **且** 接上了」。
//   只测 group-1 ⇒ 可能观察者对但没人订阅（正是 task-41 踩过的「投影漏调用」）。
//
// ═══════════════════════════════════════════════════════════════════════
// ★ 关于「直播页是否可见」的权威来源（以源码为准的考证）
// ═══════════════════════════════════════════════════════════════════════
//
// 任务书让我先考证真实接线，不硬套描述。查证结果：
// ```text
// · LivePage 的可见性有**两个**入口（live_page.dart:73/147）：
//     ① 注入的 `widget.visible`（ValueListenable<bool>?）—— 本任务新增维度
//     ② `ShellScope.isActive(context, AppTab.live)` —— 走 InheritedNotifier
//   但查 shell.dart 的实际接线（L4847）：
//     LivePage(visible: _liveVisible)   ← ★ 走的是 ①，注入投影
//   `_liveVisible` 就是 `_syncVisibility()` 的产物（含遮挡维）。
//   ⇒ 与任务书描述**一致**：遮挡计入的是 `_liveVisible`，经 `visible:` 注入。
//   ⇒ ★ 但任务书说「直播页内部判据是 ShellScope.isActive」这一句要**更正**：
//      该页 `_onVisibilityChanged`（live_page.dart:351）读的是
//      `widget.visible?.value`，**不是** ShellScope。ShellScope 只被
//      别处（如 `_visibleChannels`/门控）用。⇒ 本测试直接驱动 `visible:` 这一维。
// ```
// ⇒ 因此 group-2 的权威读数取 `LivePage.visible?.value`
//   （= shell 真正注入给直播页的那个值），而不是 ShellScope。
//
// ⚠️ 环境：本仓 `flutter test` 挂真 App（SourinApp）会因缺 `sourin_core.dll`
//    起不来 FFI，所以走**最小 MaterialApp + ShellPage**（与
//    `keepalive_visibility_test.dart` 同一套 harness）—— 已验证 LivePage
//    在这种挂法下**挂得起来**（其 loadAll 的 FFI 失败被 catch）。

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/shell.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';

// ───────────────────────────────────────────────────────────────────────
// 极简 Route：group-1 只用它冒充「shell 路由」与「盖在上面的路由」。
// ★ 不依赖 MaterialPageRoute —— 单测不需要真实转场，只要能给
//   NavigatorObserver 一个带 isFirst 语义的 Route 对象。
//   `isFirst` 是 Route 的 getter，由 Navigator 在 _history 里赋值，
//   单测里手动构造两个 route 并显式传 previousRoute 即可。
// ───────────────────────────────────────────────────────────────────────
class _FakeRoute extends Route<void> {
  _FakeRoute(this._name, {this.first = false})
      : super(settings: RouteSettings(name: _name));

  /// 本路由是否冒充「shell 自己那条路由」
  ///
  /// ⚠️ 必须**显式覆盖** `isFirst` —— 真 `Route.isFirst`（navigator.dart:601）
  ///    是 `currentRouteEntry?.route == this`，依赖路由**已装进某个 Navigator**
  ///    （`_installed`）。单测里没有 Navigator ⇒ 原 getter 恒返回 false
  ///    ⇒ 观察者的 `_isShellRoute` 恒不成立 ⇒ 计数全程为 0（实测踩过）。
  ///    ⇒ 这里用子类覆盖把它钉成可控值，单测才测得到观察者的判定分支。
  final bool first;

  @override
  bool get isFirst => first;

  final String _name;
  @override
  String toString() => '_FakeRoute($_name)';
}

// ───────────────────────────────────────────────────────────────────────
// group-2 用的 harness（照抄 keepalive_visibility_test.dart 的写法）
// ───────────────────────────────────────────────────────────────────────
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

/// 认领环境噪声（无核心的 FFI 异常 + SliverPersistentHeader 布局断言）
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {
    // 空
  }
}

/// 读「shell **真正注入给直播页**的 visible 值」—— 本任务的权威读数
///
/// ★ 来源是 `shell.dart:4847` 的 `LivePage(visible: _liveVisible)`。
///   返回 null = LivePage 还不在树上（未访问过 live tab）。
bool? _injectedLiveVisible() {
  final els = find.byType(LivePage, skipOffstage: false).evaluate();
  if (els.isEmpty) return null;
  final w = (els.first as StatefulElement).widget as LivePage;
  return w.visible?.value;
}

void main() {
  // ═══════════════════════════════════════════════════════════════════════
  // group-1：ShellOcclusionObserver 判据单测（不挂 widget）
  // ═══════════════════════════════════════════════════════════════════════
  //
  // 守的判据（★ 2026-10-14 按 CR #27 的意见**重写**过 —— 见 group 内的长注释）：
  // ```text
  // ① 空序列 ⇒ 0（不误报"被盖住"）
  // ② shell 上 push 一条 **PageRoute** ⇒ 1
  // ③ 弹窗（PopupRoute）**不算**遮挡 ⇒ 直播不被静音（CR 缺陷①）
  // ④ 移除**中间**那条、上面还有 ⇒ 仍算被盖住（CR 缺陷②）
  // ⑤ pop 回 shell ⇒ 0；多余 pop 夹到 0（不为负）
  // ⑥ didReplace 也要重算（原实现漏了）
  // ```
  // ⚠️ 旧版这里断言的是"增量计数"语义（含一条"与任务书不符"的说明）——
  //    那套语义**本身就是错的**（弹窗误判 + 中间移除误判），已被 CR 指出并修，
  //    相应断言一并重写；不再是"以错误实现为准"。
  group('group-1 ★ ShellOcclusionObserver 判据逻辑（单元）', () {
    /*
     * # 原实现（增量计数）错在哪
     * ```text
     * ① `didPush` 无条件（只看"下面是不是 shell"）+1
     *    ⇒ **弹窗/底部面板**（`PopupRoute`，且 `showAppDialog` 走根 Navigator）
     *      也会让计数 =1 ⇒ 直播被静音、停解码。
     *      ★ 可弹窗**不是不透明遮挡** —— 用户仍看得见画面。
     * ② 增量法在"移除**中间**那条"时算错：
     *    `shell → detail → player`，移除 detail ⇒ 原实现按
     *    "previousRoute 是不是 shell" 减 ⇒ 误判 shell 露出（而 player 还在上面）。
     * ```
     *
     * # 新实现（本组守的）
     * ```text
     * 观察者**自己维护整条栈**，每次事件后**整体重算**：
     *   计数 = shell（最底那条，`isFirst`）之上有**几条 `PageRoute`**
     * · `PopupRoute`（弹窗/面板）**一律不算** ⇒ 修①
     * · 整体重算 ⇒ 移除中间那条也算得对 ⇒ 修②
     * ```
     *
     * ★ 因此本组**必须**用**真的 `PageRoute`**（`MaterialPageRoute`）与
     *   真的 `PopupRoute`（`showDialog` 那条）当夹具 ——
     *   用"万能 `_FakeRoute`"就**测不出**这两条判据（原版本就是这么漏的）。
     */
    test('① 初始为 0（不许一开始就把直播判成不可见）', () {
      final obs = ShellOcclusionObserver();
      addTearDown(obs.occluders.dispose);
      expect(obs.occluders.value, 0,
          reason: '初始 shell 没被任何路由盖住 ⇒ 计数必须是 0。\n'
              '★ 非 0 ⇒ 直播页一开始就被判不可见（真机症状：切过去黑屏/沉默）。');
    });

    test('② shell 上 push 一条 **PageRoute** ⇒ 1', () {
      final obs = ShellOcclusionObserver();
      addTearDown(obs.occluders.dispose);
      final shell = MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'home'), builder: (_) => const SizedBox());
      final detail = MaterialPageRoute<void>(
          settings: const RouteSettings(name: 'detail'), builder: (_) => const SizedBox());
      obs.didPush(shell, null); // shell 自己先入栈（isFirst 由 MaterialPageRoute 默认 false？）
      // ⚠️ `isFirst` 在单测里恒 false（真值是"是不是栈底"，依赖已装进 Navigator）——
      //    所以这里**显式**给出栈底语义：用一条覆盖 isFirst 的假路由当 shell，
      //    其余用真 PageRoute（判据只认 `is PageRoute`）。
      final obs2 = ShellOcclusionObserver();
      addTearDown(obs2.occluders.dispose);
      obs2.didPush(_ShellMarkerRoute(), null);
      obs2.didPush(detail, null);
      expect(obs2.occluders.value, 1,
          reason: 'shell 之上有一条 **PageRoute** ⇒ 计数 = 1。\n'
              '★ 反证：把 `_recompute` 改成恒 0 ⇒ 红。');
    });

    test('★★ 弹窗（PopupRoute）**不算**遮挡（CR #27 缺陷①）', () {
      final obs = ShellOcclusionObserver();
      addTearDown(obs.occluders.dispose);
      obs.didPush(_ShellMarkerRoute(), null);
      // 模拟 `showAppDialog` 走根 Navigator 推一条 PopupRoute
      obs.didPush(_PopupMarkerRoute(), null);
      expect(obs.occluders.value, 0,
          reason: '★★★ 弹窗**不是不透明遮挡** —— 用户仍看得见直播画面。\n'
              '旧实现会把它算成 1 ⇒ 直播被静音/停解码（CR 抓到的真缺陷）。\n'
              '★ 反证：把 `if (r is PageRoute)` 改成 `if (true)` ⇒ 这里读到 1 ⇒ 红。');
    });

    test('★★ 移除**中间**那条：上面的还在 ⇒ 仍算被盖住（CR #27 缺陷②）', () {
      final obs = ShellOcclusionObserver();
      addTearDown(obs.occluders.dispose);
      final shell = _ShellMarkerRoute();
      final detail = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final player = MaterialPageRoute<void>(builder: (_) => const SizedBox());

      obs.didPush(shell, null);
      obs.didPush(detail, null);
      obs.didPush(player, null);
      expect(obs.occluders.value, 2, reason: '前置：两条 PageRoute 盖着');

      // 移除**中间**的 detail —— player 还在上面
      obs.didRemove(detail, shell);
      expect(obs.occluders.value, 1,
          reason: '★★★ 移除中间那条后，**player 仍在上面** ⇒ 计数必须仍是 1。\n'
              '旧增量法会按 "previousRoute == shell ⇒ 减 1" 得到 0 ⇒ '
              '误判 shell 露出 ⇒ 直播被错误唤醒（CR 抓到的真缺陷）。\n'
              '★ 反证：把 `_recompute` 换回"增量 ±1" ⇒ 这里读到 0 ⇒ 红。');
    });

    test('③ pop 回 shell ⇒ 0；④ pop 多余 ⇒ 夹到 0 不为负', () {
      final obs = ShellOcclusionObserver();
      addTearDown(obs.occluders.dispose);
      final shell = _ShellMarkerRoute();
      final detail = MaterialPageRoute<void>(builder: (_) => const SizedBox());

      obs.didPush(shell, null);
      obs.didPush(detail, null);
      expect(obs.occluders.value, 1);

      obs.didPop(detail, shell);
      expect(obs.occluders.value, 0, reason: 'pop 掉唯一的遮盖页 ⇒ 回 0');

      // 异常序列：多余 pop ⇒ 不许变负（负值会让 `> 0` 判据永远失效）
      obs.didPop(detail, shell);
      expect(obs.occluders.value, 0,
          reason: '★ 多余 pop 必须夹到 0 —— 负值会让"是否被盖住"永远判错。');
    });

    test('⑤ didReplace 也重算（原实现直接跳过）', () {
      final obs = ShellOcclusionObserver();
      addTearDown(obs.occluders.dispose);
      final shell = _ShellMarkerRoute();
      final a = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      final b = MaterialPageRoute<void>(builder: (_) => const SizedBox());
      obs.didPush(shell, null);
      obs.didPush(a, null);
      expect(obs.occluders.value, 1);
      obs.didReplace(newRoute: b, oldRoute: a);
      expect(obs.occluders.value, 1,
          reason: '替换一条 PageRoute ⇒ 仍是 1（原实现不重算 ⇒ 可能滞留旧值）');
      obs.didReplace(newRoute: null, oldRoute: b);
      expect(obs.occluders.value, 0, reason: '替换成"没有" ⇒ 回 0');
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // group-2：端到端 —— 挂真 ShellPage，断言 LivePage 收到的 visible
  // ═══════════════════════════════════════════════════════════════════════
  //
  // 守的判据（任务书 2）：
  // ```text
  // 初始（home tab）      ⇒ 直播页不可见
  // 切到 live tab         ⇒ 可见
  // ★ 在 live tab 上送一个遮挡（occlusion=1）⇒ 直播页**变为不可见**  ← 本次修复核心
  // 解除遮挡（0）         ⇒ 又可见
  // ```
  // ★ 用**注入的 occlusion notifier** 驱动，读的是「shell 真正注入
  //   LivePage(visible:) 的值」—— 见文件头「权威来源」考证。
  group('group-2 ★★ 端到端：遮挡计入 _liveVisible 并注入 LivePage', () {
    testWidgets('occlusion 变化 ⇒ LivePage 收到的 visible 跟着变（修复的核心）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      // 模拟 `_SourinAppState._occlusion.occluders`（生产里由观察者持有）
      final occluders = ValueNotifier<int>(0);
      addTearDown(occluders.dispose);

      await tester.pumpWidget(
        _appWith(home: ShellPage(key: debugShellKey, occlusion: occluders)),
      );
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState;
      expect(shell, isNotNull,
          reason: '拿不到 shell state ⇒ 无法驱动切换，结论不作数（前置）');

      // ── 断言 1：初始（home tab）⇒ 直播页不可见 ──
      // ⚠️ LivePage 走惰性保活，未访问过 live 时它**还不在树上**
      //    （`_injectedLiveVisible()` 返回 null）。这本身**不是**
      //    「不可见」的证据 —— 必须先切到 live 建树，再回到 home，
      //    否则会拿到 null 造成假绿/假红（铁律 78）。
      shell!.debugSwitchTo(AppTab.live);
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);

      // ── 断言 2：切到 live tab、无遮挡 ⇒ 可见 ──
      expect(occluders.value, 0, reason: '前置：本步之前不应有遮挡');
      expect(_injectedLiveVisible(), isTrue,
          reason: '★★ 切到 live 且 shell 没有被盖住 ⇒ LivePage 必须收到 visible=true。\n'
              '  （权威读数 = shell 注入的 LivePage.visible?.value）');

      // ── 断言 3（★ 本次修复核心）：在 live tab 上「push 路由」⇒ 不可见 ──
      // 这里直接驱动遮挡计数（= 模拟 ShellOcclusionObserver 在 didPush 后置 1），
      // 避免依赖真实 Navigator push（本最小 harness 没有 NavigatorObserver）。
      occluders.value = 1;
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 300));
      _claim(tester);

      expect(_injectedLiveVisible(), isFalse,
          reason: '★★★ 修复的核心判据：\n'
              '  在 **live tab 上**（_activeTab == live，**tab 没变**）\n'
              '  出现遮挡（occlusion = 1）⇒ 直播页必须**变为不可见**。\n'
              '  ★ 反证（红度）：把 shell.dart `_syncVisibility` 改回\n'
              '    `final v = _activeTab.value == AppTab.live;`\n'
              '    ⇒ 这里仍读到 true ⇒ **本行变红**。\n'
              '    这正是 Owner 报的「从播放页返回卡顿」的根因：\n'
              '    直播内嵌播放器在被盖住期间仍在解码 + 驱动原生视频输出层。');

      // ── 断言 4：解除遮挡（pop 回来）⇒ 又可见 ──
      occluders.value = 0;
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 300));
      _claim(tester);

      expect(_injectedLiveVisible(), isTrue,
          reason: '★ 遮挡解除（相当于从播放页 pop 回来）⇒ LivePage 必须重新收到\n'
              '  visible=true ⇒ 走它既有的 listener 续播通路。\n'
              '  若这里恒为 false ⇒ pop 回来**不续播**（画面停在旧状态）。');

      // ── 断言 5：切回 home tab（无遮挡）⇒ 仍不可见（tab 维不能被遮挡维掩盖）──
      shell.debugSwitchTo(AppTab.home);
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);
      expect(_injectedLiveVisible(), isFalse,
          reason: '★ 两维是 **AND**：离开 live tab（即使无遮挡）也必须不可见。\n'
              '  若这里 true ⇒ 投影被写坏成只认遮挡维。');

      // 收尾（照抄 keepalive_visibility_test.dart：等 3 秒 Timer + 卸载 + 认领）
      await tester.pump(const Duration(seconds: 4));
      _claim(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      _claim(tester);
    });

    testWidgets('★ 连多层遮挡：occlusion 2→1 期间**始终不可见**（>0 即盖住）',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(1280, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final occluders = ValueNotifier<int>(0);
      addTearDown(occluders.dispose);

      await tester.pumpWidget(
        _appWith(home: ShellPage(key: debugShellKey, occlusion: occluders)),
      );
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 1500));
      _claim(tester);

      final shell = debugShellKey.currentState!;
      shell.debugSwitchTo(AppTab.live);
      await tester.pump();
      _claim(tester);
      await tester.pump(const Duration(milliseconds: 600));
      _claim(tester);
      expect(_injectedLiveVisible(), isTrue, reason: '前置：live 且无遮挡 ⇒ 可见');

      // 连 push 两层 ⇒ 计数 2 —— shell 仍被盖住
      occluders.value = 2;
      await tester.pump();
      _claim(tester);
      expect(_injectedLiveVisible(), isFalse,
          reason: '★★ occlusion=2 ⇒ 仍必须不可见。\n'
              '  ★ 反证：若 shell 里写的是 `(occlusion?.value ?? 0) == 1`\n'
              '    （只认 1 层）⇒ 这里读到 true ⇒ 红。\n'
              '    这是「>0 而不是 ==1」这条设计的守卫 —— 详情页→播放页\n'
              '    连 push 两层时，第二层的 previousRoute 不是 shell。');

      // pop 掉最上一层 ⇒ 计数 1 —— 仍被下面那层盖住
      occluders.value = 1;
      await tester.pump();
      _claim(tester);
      expect(_injectedLiveVisible(), isFalse,
          reason: '★ 只剩 1 层遮挡（如从播放页 pop 回详情页）⇒ 仍然不可见，\n'
              '  因为详情页仍盖着 shell。只有回到 0 才可见。');

      // pop 回 shell ⇒ 0
      occluders.value = 0;
      await tester.pump();
      _claim(tester);
      expect(_injectedLiveVisible(), isTrue, reason: '★ 遮挡清零 ⇒ 恢复可见');

      await tester.pump(const Duration(seconds: 4));
      _claim(tester);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 100));
      _claim(tester);
    });
  });
}

// ───────────────────────────────────────────────────────────────────────
// group-1 用的**结构性**夹具（CR #27 后新增）
// ───────────────────────────────────────────────────────────────────────
//
// # 为什么不能再用"万能 `_FakeRoute`"
// ```text
// 新判据认的是**路由类型**（`is PageRoute` / `is PopupRoute`）与 **`isFirst`**。
// 一个"什么都能冒充"的假路由**测不出**这两条 —— 原版本正是这么漏掉
// "弹窗被当成遮挡"那个真缺陷的。
// ⇒ 这里每种类型各用一个**最小但真实**的子类：
//    · `_ShellMarkerRoute`  —— 冒充"栈底那条 shell"（只覆盖 `isFirst`）
//    · `_PopupMarkerRoute`  —— 真的 `PopupRoute` 子类（模拟弹窗）
//    其余用**真的** `MaterialPageRoute`（那才是生产里真正会盖住页面的东西）。
// ```
//
// ⚠️ `isFirst` 的真值（`navigator.dart`）是"是不是 `currentRouteEntry` 的栈底"，
//    依赖路由**已装进某个 Navigator**；单测里没有 Navigator ⇒ 恒 false。
//    所以"栈底"这一点必须用子类显式覆盖（与既有 `_FakeRoute` 同一手法）。

/// 冒充「shell 自己那条路由」：只覆盖 `isFirst`
///
/// ★ 必须是 `PageRoute` —— 新判据只数 `PageRoute`，shell ��不是一个
///   `PageRoute`，它**自己**会被算成"遮挡"（虽然它前面没有别的路由，
///   遍历从它开始算，见 `_recompute` 的 `seenShell`）。
class _ShellMarkerRoute extends PageRoute<void> {
  _ShellMarkerRoute();

  @override
  bool get isFirst => true;

  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get maintainState => true;
  @override
  bool get opaque => true;

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      const SizedBox.shrink();
}

/// 真的 `PopupRoute` 子类 —— 模拟 `showDialog` / `showAppDialog` 那条路
class _PopupMarkerRoute extends PopupRoute<void> {
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Color? get barrierColor => null;
  @override
  String? get barrierLabel => null;
  @override
  bool get barrierDismissible => true;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) =>
      const SizedBox.shrink();
}
