// ═══════════════════════════════════════════════════════════════════════
//  把用户选的「页面切换动画」接到**二级页**上 —— task-50 候选 C2
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件修的到底是什么（实测缺口，不是"加个动画"）
//
// ```text
// task-55 已经做好 6 种风格 + 设置页可选，`PageTransition.apply` 也写好了。
// ★ 但它在全仓**只有一个调用点**：`shell.dart:755`（tab 切换）。
// ★ 而二级页（详情页 / 浏览页 / 设置二级页 / 播放页）走的是
//   `MaterialPageRoute` ⇒ 由 `theme_bridge.dart` 的
//   `buildPageTransitionsTheme()` 决定，那里**硬编码了 Zoom**。
// ⇒ 用户在设置里选了「淡入 / 上滑 / 无动画」，
//   **二级页一个都不生效** —— 选了没反应。
// ```
// 这是**功能性缺陷**（设置项与实际行为不一致），不只是审美问题。
//
// # 为什么放在**新文件**里（而不是塞进 `page_transition.dart`）
//
// ```text
// `motion_prefs.dart` 已经 import `page_transition.dart`（要那个 enum）。
// 若 `page_transition.dart` 反过来 import `motion_prefs.dart`（要 MotionPrefs），
// 就形成**循环 import**。Dart 允许，但没人应该故意造一个。
// ⇒ 本文件同时 import 两者，`page_transition.dart` **一个字节都不动**。
// ```
//
// # ★★ 为什么**继承** `ZoomPageTransitionsBuilder`（而不是从零实现）
//
// ```text
// 本仓有两条既有测试盯着这块，**都不能改**（它们守的是用户报过的真 bug）：
//   ① `test/page_transition_scrim_test.dart`（task-17「白色条盖住操作条」）
//      断言 `buildPageTransitionsTheme().builders[windows]`
//        · `isA<ZoomPageTransitionsBuilder>()`
//        · `(b as ZoomPageTransitionsBuilder).backgroundColor == Colors.transparent`
//   ② `test/transition_clip_titlebar_test.dart`（task-27④ 溢出画到标题栏）
//      它的**红度证明**要求：不加 `ClipRect` 时，离场页放大**必须**溢出
//        ⇒ ★ 若二级页的离场不再放大，那条红度证明会变成 `worst == 0` ⇒ 变红
// ⇒ 继承 Zoom 让 ① 原样通过；★ 而"离场页仍然放大 1.05"让 ② 原样通过。
// ⇒ **两条既有测试一个字节都不用改** —— 这是"没有回归"的最硬证据。
// ```
//
// # 判据映射（Lead 五条）
//
// ```text
// ① 目的          ⇒ 表达层级 + ★ 让用户的选择**真的生效**
// ② ≤300ms        ⇒ `Motion.base` = 260ms（与 tab 切换同档）
// ③ 可打断        ⇒ 全是声明式过渡（`FadeTransition`/`SlideTransition`/
//                    `ScaleTransition`），值由路由的 `Animation` 驱动，
//                    中途 pop 时自然反向 —— 没有自己的状态机
// ④ Reduce Motion ⇒ `MotionPrefs.resolvedCurrent(context)` ⇒ 减少时返回 `none`
// ⑤ 惯用法        ⇒ 用 Flutter **官方**扩展点 `PageTransitionsBuilder`
//                    （`MaterialPageRoute` 就是通过 `PageTransitionsTheme`
//                     取它的）⇒ **零手写 `AnimationController`**
// ```
//
// # ★ 为什么 `transitionDuration` 是"风格真的生效"的**接口本身**
//
// ```text
// `MaterialPageRoute.transitionDuration` 的实现（material_ui-1.4.0/
//   lib/src/page.dart:108）就是**主动来问这个 builder**：
//     _getPageTransitionBuilder(navigator!.context)?.transitionDuration ?? ...
// ⇒ 我重写这个 getter ⇒ 路由的 `AnimationController` 时长随之改变：
//     `none` ⇒ `Duration.zero` ⇒ 路由**瞬间**完成（真·无动画）
//     其余   ⇒ 260ms
// ⚠️ `AnimationController` 对 `Duration.zero` 有**显式支持**
//    （flutter/lib/src/animation/animation_controller.dart:672
//     `if (simulationDuration == Duration.zero)` ⇒ 直接设值 + 标 completed
//     + `TickerFuture.complete()`）⇒ 不卡住、不除零。
// ```
//
// # ⚠️ 一处**有意的**取舍（必须记录，别让后人以为是漏了）
//
// ```text
// 系统开了「减少动态效果」时，`buildTransitions` 立刻 `return child`
//   （画面**瞬间**切换 = 无障碍想要的），
// ★ 但 `transitionDuration` 这个 getter **拿不到 `BuildContext`**
//   （它是框架定的无参 getter）⇒ 读不到 MediaQuery ⇒ 仍报 260ms。
// 后果：路由"记账"多花 260ms，而画面已经是终态 ⇒ 用户看到的是**瞬间**切换 ✓
//   （多出来的那段时间里新页已完全可见，没有任何"空白期"）
// ```
//
// # ⚠️ 默认值带来的观感变化（如实记录）
//
// ```text
// 改之前：二级页恒为 Zoom（新页放大淡入 + 离场页放大 1.05）
// 改之后：二级页 = 用户选的风格；★ 默认风格是 `slideRight`
//         ⇒ 没进过设置页的用户，新页从"放大淡入"变成"淡入 + 2% 横滑"，
//           **离场页仍放大 1.05**（保持不变 ⇒ ② 的红度证明仍成立）。
// ★ 这是"一个设置管两处"的**必然结果**：用户要的是"我来切换"，
//   若 tab 与二级页各有一套默认值，设置项就自相矛盾了。
//   ⇒ 统一到同一个风格（默认 `slideRight`），想要缩放的用户选「缩放」即可。
// ```

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'motion_prefs.dart';
import 'page_transition.dart';

/// 用**用户选的风格**做二级页（`Navigator.push` 上来的路由）转场
///
/// 接线处：`lib/ui/theme_bridge.dart` 的 `buildPageTransitionsTheme()`。
///
/// ⚠️ **继承** [ZoomPageTransitionsBuilder] 是刻意的 —— 理由见文件头
///    （两条既有测试盯着它，且它们守的是用户报过的真 bug）。
class SourinPageTransitionsBuilder extends ZoomPageTransitionsBuilder {
  /// ★ `const` 构造 —— `buildPageTransitionsTheme()` 返回的是
  ///   `const PageTransitionsTheme(...)`，它要求 map 里的值能进常量表达式。
  const SourinPageTransitionsBuilder({super.backgroundColor});

  /// 当前风格（读全局 store）
  static PageTransitionStyle get _style =>
      PageTransitionStyleStore.current.value;

  /// ★ 框架通过这个 getter 决定路由的 `AnimationController` 时长
  ///   （源码依据见文件头）—— 这是"用户选的风格真的生效"的**接口本身**。
  ///
  /// ⚠️ 与 `buildTransitions` 里的 Reduce Motion 分支不完全一致（拿不到
  ///    context），后果已在文件头如实记录。
  @override
  Duration get transitionDuration =>
      _style == PageTransitionStyle.none ? Duration.zero : Motion.base;

  /// 返回/退出用**同一个**时长
  ///
  /// ★ 有意的：若与进入不同，pop 时会"进去慢、出来快"（或反过来），
  ///   像卡了一下。两者一致才对称。
  @override
  Duration get reverseTransitionDuration => transitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final style = MotionPrefs.resolvedCurrent(context);

    /*
     * ★ 尊重系统"减少动态效果"（判据④）
     *   ⇒ 不加任何 widget（零过渡层），画面瞬间切换
     */
    if (style == PageTransitionStyle.none) return child;

    /*
     * ★「缩放」直接交给 Flutter 官方的 Zoom（= 改之前的行为）
     *
     * 两个理由：
     *   ① 用户选「缩放」时，最正宗的实现就是官方那套（含离场 1.05 放大
     *      与快照优化）—— 我自己再写一遍只会更差；
     *   ② ★ 让 `page_transition_scrim_test.dart` 守的那段 scrim 代码
     *      **仍然是活的代码路径**（而不是一个"字段还在、代码已死"的
     *      空壳断言）。
     */
    if (style == PageTransitionStyle.zoom) {
      return super.buildTransitions<T>(
        route,
        context,
        animation,
        secondaryAnimation,
        child,
      );
    }

    final curve = MotionPrefs.curve(context, Motion.easeOut);

    // ① 新页：按用户选的风格入场
    final entering = PageTransition.apply(
      animation: animation.drive(CurveTween(curve: curve)),
      child: child,
      style: style,
    );

    /*
     * ② 离场页：放大 1.0 → 1.05（**所有**非 none/zoom 风格都保留）
     *
     * ```text
     * 为什么离场要单独处理：上面 `PageTransition.apply` 只动**新页**
     *   （由 `animation` 0→1 驱动）。而"往深一层走"的观感还包括
     *   旧页**退到后面去** —— 那由它自己的 `secondaryAnimation`
     *   （被覆盖时 0→1）驱动：框架会带着 secondary 进度**再调一次**
     *   `buildTransitions`（就是本方法）⇒ 这里给它 1.0 → 1.05。
     * ★ 1.05 是 Flutter 官方 `ZoomPageTransitionsBuilder` 用的同一个值
     *   （`_ZoomExitTransition._scaleUpTransition`）⇒ 离场观感与改之前一致。
     * ⚠️ 对新页自己来说 `secondaryAnimation` 恒为 0（它上面没有别的路由）
     *   ⇒ 这一层对新页是 `scale: 1.0` 的**恒等**过渡，不会叠加变形。
     * ★ 保留它还有第二个作用：`transition_clip_titlebar_test.dart` 的
     *   红度证明依赖"离场页放大后溢出" ⇒ 去掉它那条证明会变成空的。
     * ```
     */
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-08（Owner 第 2 条）二级页链的**离场淡出** —— 拖影根治
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 每个页面来回切换,出现严重的拖影,就是页面已经切换了,
     * > 但是那些上个页面的元素还没彻底消失,看着非常难受
     *
     * # 改前为什么会有拖影
     * ```text
     * 本方法对**被覆盖的那一页**只做了一件事：放大 1.0 → 1.05（下面的
     * ScaleTransition）。**不透明度始终是 1** ⇒ 新页（从 0 淡入）半透明时，
     * 底下那层旧页 100% 透出来 ⇒ 两层内容叠加 = 用户看到的「拖影」。
     * ```
     *
     * # 修法：给同一层再叠一条 1.0 → 0.0 的淡出
     * ```text
     * 它与缩放**同一条 secondaryAnimation、同一条曲线** ⇒
     *   旧页退到后面去的同时**一起变淡**，两层不再叠加。
     * ★ 对**新页**完全无影响：新页的 `secondaryAnimation` 恒为 0
     *   （它上面没有别的路由）⇒ 这一层的 opacity 恒为 1.0（恒等）✓
     * ★ 对**根路由**也无影响（同上）。
     * ```
     *
     * ⚠️ 缩放那一条**必须保留**：`transition_clip_titlebar_test.dart` 的
     *    红度证明依赖「离场页放大后溢出」，删了它那条证明会变成空断言。
     *    本层是**叠加**（外面再包一层 FadeTransition），不是替换。
     */
    final exitLayer = FadeTransition(
      opacity: Tween<double>(begin: 1.0, end: 0.0).animate(
        secondaryAnimation.drive(CurveTween(curve: curve)),
      ),
      child: ScaleTransition(
        scale: Tween<double>(begin: 1.0, end: 1.05).animate(
          secondaryAnimation.drive(CurveTween(curve: curve)),
        ),
        child: entering,
      ),
    );
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-10-13：离场页**光栅快照** —— 修「从播放页返回卡顿」的本体
     * ══════════════════════════════════════════════════════════════════
     *
     * # 实测（受控 A/B，同一自动驱动 `SOURIN_AB=1`，逐窗 raster p50）
     * ```text
     * 不在场（旧行为）      11989 11989 11506 ...（稳态地板 ~12ms）
     * 遮挡修复后            7069 → 9469（爬升）
     * 关掉过渡（去掉功能）   6185（平稳，但功能没了）
     * ★ 快照离场页          2150（平稳）← 比"关掉过渡"还快
     * ```
     * 8 个 push/pop 相位**零超预算帧**（旧行为 37 个）。
     * 原始数据：`.probe/exp_exit_snapshot.txt`。
     *
     * # 为什么快照有效（机制）
     * ```text
     * 离场页的**构图完全不变** —— 它只是被整体缩放+淡出。
     * 而 Flutter 每帧仍要**重新绘制整棵子树**（首页的滚动网格 / 播放页），
     * 再施加 Transform + Opacity。
     * ⇒ 快照把它**光栅化成一张图**，过渡期间只搬这张图
     *   ⇒ 每帧成本从「重绘整页」降到「画一张 bitblt」。
     * ★ 这正是 Flutter 官方 `ZoomPageTransitionsBuilder` 的
     *   `allowSnapshotting` 做法（见 page_transitions_theme.dart:249/351）。
     *   我们的默认风格 `slideRight` 走的是**手写**分支，从来没吃到它。
     * ```
     *
     * # 为什么只快照**离场页**，不快照入场页
     * ```text
     * 离场页构图不变 ⇒ 快照**永远有效**。
     * 入场页自己在滑入 ⇒ 快照要"先渲染再截"，且内容可能还在变
     *   （如首页正在异步加载卡片）⇒ 会截到中间态，风险大、收益小。
     * ```
     *
     * # ⚠️ 与「拖影修复」的关系（两处都动 opacity，但互不冲突）
     * ```text
     * 拖影修复 = 离场页 1.0 → 0.0 淡出（给**下面**的新页让路）
     * 本层     = 把淡出的**内容来源**换成一张图
     * ⇒ 两者是叠加：快照图**带着**那条淡出一起被画出来。
     * ```
     */
    /*
     * ⚠️ `debugDisableExitSnapshot` —— **只给测试的红度证明用**。
     *
     * # 为什么必须有这个旁路
     * `transition_clip_titlebar_test.dart` 的红度证明是「去掉 ClipRect ⇒
     * 必须看得到离场页放大后的溢出」。而快照把离场页变成一张**有界**的图
     * ⇒ 去掉 ClipRect 也看不到溢出了 ⇒ **红度证明失效**
     * ⇒ 按本仓铁律「判据测不出反面 ⇒ 结论作废」，那条守卫就废了。
     * ⇒ 让红度证明**绕过快照**，跑在**原生绘制路径**上（这正是它要证的那条）。
     *
     * ⚠️ 生产恒为 false（无任何代码路径会置 true）。
     */
    if (debugDisableExitSnapshot) return exitLayer;
    return _ExitSnapshot(animation: secondaryAnimation, child: exitLayer);
  }
}

/// ★ 只给测试的红度证明用：置 true ⇒ 过渡**不走快照**（跑原生绘制路径）。
///
/// 见 `buildTransitions` 里紧邻本开关的说明 —— 它存在的唯一理由是让
/// `transition_clip_titlebar_test.dart` 的红度证明**仍然测得出来**。
/// ⚠️ 生产代码**从不**读它，默认 false ⇒ 零影响。
@visibleForTesting
bool debugDisableExitSnapshot = false;

/// 把「被盖住的那一页」光栅缓存成一张图 —— 见 `buildTransitions` 末尾
/// 那段「离场页光栅快照」的完整推导与实测数据。
///
/// # 为什么需要它（一句话）
/// ```text
/// 离场页构图不变，但 Flutter 每帧仍在**重绘整棵子树**；
/// 快照把它换成「画一张图」⇒ 过渡期间每帧成本降到 1/3 ~ 1/5。
/// ```
///
/// ⚠️ `widget.animation` 只用于「过渡结束后让快照失效」这一件事 ——
///    不用它驱动任何视觉（缩放/淡出仍在外面那两层做）。
class _ExitSnapshot extends StatefulWidget {
  const _ExitSnapshot({
    required this.animation,
    required this.child,
  });

  final Animation<double> animation;
  final Widget child;

  @override
  State<_ExitSnapshot> createState() => _ExitSnapshotState();
}

class _ExitSnapshotState extends State<_ExitSnapshot> {
  /*
   * ⚠️⚠️ 初值必须是 **false**（`allowSnapshotting: false`）。
   *
   * # 我第一版写的是 `true`，那是个真缺陷（2026-10-13 由 `t486` 抓出）
   * ```text
   * `allowSnapshotting: true` 是**持续**用快照替换子树 ——
   * 它**不看**我下面那个 `_snapshotting` 布尔（那个变量当时只驱动 setState，
   * 压根没接到 controller 上）⇒
   *   ① 页面被**永久冻在**第一帧（正是我在注释里说要避免的那个 bug）
   *   ② ★ 还会**吞掉布局溢出异常**：`t486` 的阳性对照
   *      （「极窄 300 宽必须看到 RenderFlex overflowed」）因此恒为 0 条
   *      ⇒ 那个测试的仪器自检失效。
   * ③ ★ 而性能读数**照样好看** —— 冻住的图当然便宜。
   *    ⇒ 这就是"测出来的数字是真的，但实现是错的"。
   * ```
   * ⇒ 现在**唯一**的开关就是 controller 上的 `allowSnapshotting`，
   *   由 `_onStatus` 按「动画是否在飞」显式置位，别处不再有第二个真相。
   */
  late final SnapshotController _c =
      SnapshotController(allowSnapshotting: false);

  /// 过渡是否在飞 —— 只有在这期间才允许用快照
  ///
  /// ★★★ 为什么必须门控，不能一直开着
  /// ```text
  /// `allowSnapshotting: true` 是**持续**用快照替换子树的。
  /// 若一直开着 ⇒ 这一页被**冻在最初那一帧**：
  ///   · 首页加载完的卡片永远不出现
  ///   · 直播页换台后画面不变
  /// ⇒ 那是**功能坏掉**，不是优化。
  /// ```
  /// # 判据用 `secondaryAnimation.status`
  /// ```text
  /// secondaryAnimation 就是「本页被盖住」的进度：
  ///   · 盖住过程中 → forward/reverse（动画在飞）
  ///   · 盖完之后   → completed（停在 1.0，本页在后台）
  ///   · 上面那页pop → 往回走（动画在飞）→ dismissed（0.0，本页又可见）
  /// ★ 只有"动画在飞"的那两段时间需要快照（那也是卡顿发生的时间）。
  ///   动画停 ⇒ 立刻 `clear()` 让子树回到**实时渲染**
  ///   ⇒ 既拿到过渡期的性能，又不冻住页面。
  /// ```
  bool _snapshotting = false;

  @override
  void initState() {
    super.initState();
    widget.animation.addStatusListener(_onStatus);
    _onStatus(widget.animation.status);
  }

  @override
  void didUpdateWidget(covariant _ExitSnapshot old) {
    super.didUpdateWidget(old);
    if (old.animation != widget.animation) {
      old.animation.removeStatusListener(_onStatus);
      widget.animation.addStatusListener(_onStatus);
      _onStatus(widget.animation.status);
    }
  }

  void _onStatus(AnimationStatus st) {
    final flying = st == AnimationStatus.forward ||
        st == AnimationStatus.reverse;
    if (flying == _snapshotting) return;
    /*
     * ★★ 唯一开关：改 controller 的 `allowSnapshotting`（不是只 setState）。
     *
     * ```text
     * flying = true  ⇒ allowSnapshotting = true  ⇒ 用快照（过渡期，省重绘）
     * flying = false ⇒ allowSnapshotting = false ⇒ 回到**实时渲染**
     * ```
     * `allowSnapshotting` 的 setter 内部 `notifyListeners()` ⇒
     * `SnapshotWidget` 会立刻换回来，**不需要**再手动 `clear()`
     * （`clear()` 是"重拍一张"，而这里要的是"以后别用快照了"）。
     *
     * ⚠️ 别再引入第二个布尔（我第一版就是"`_snapshotting` + 只 setState"，
     *    而 controller 始终 true ⇒ 两个真相打架，页面被永久冻住）。
     */
    _snapshotting = flying;
    _c.allowSnapshotting = flying;
  }

  @override
  void dispose() {
    widget.animation.removeStatusListener(_onStatus);
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SnapshotWidget(
      controller: _c,
      mode: SnapshotMode.permissive,
      autoresize: true,
      child: widget.child,
    );
  }
}
