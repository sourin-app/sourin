// ═══════════════════════════════════════════════════════════════════════
//  搜索页 —— 对齐原版 SearchView.vue（400 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 跨 Provider 聚合搜索。
//
// # 关键设计：**错误隔离**
//
// 单个源失败不影响其他源的结果，且失败的源会明确列在下方
//（而非静默消失）。
//
// # ★★★ 流式搜索（Owner 的要求，2026-09-19）
//
// 原版注释：
// > 搜索页面,不应该等待所有源一起搜索完毕再显示出来,
// > **搜索结束一个就显示一个**,后面的往里面 push 就行了
//
// ```text
// 改之前:  [等 25 个源全部跑完，可能十几秒] → 一次性显示全部
// 改之后:  [0.5 秒] 出现第 1 个源的结果 → 用户已经能点了
//          [1.3 秒] 又冒出 3 个
//          [2.1 秒] 再 5 个 …
// ```
//
// # ★★ 三个容易写错的点（原版都踩过）
//
// ## ① 新搜索必须**取消**上一次
//
// 原版注释：
// > 用户连续改关键词时，旧的那次还在跑 —— 不取消的话旧结果会
// > **混进新结果里**（"幽灵结果"）。
//
// ## ② 立刻清空旧结果，而不是等第一个源回来再清
//
// 原版注释：
// > 否则用户改了关键词后，会先看到**旧关键词的结果**挂在那里，
// > 几秒后才被替换 —— 看起来像"搜索没生效"。
//
// ## ③ 骨架屏只在「一个源都还没回来」时显示
//
// 原版注释：
// > 改之前是无条件「只要还在搜就盖住全部结果」。
// > 但流式搜索下，**第一个源回来后就应该能看到内容**，
// > 如果骨架还盖着，用户仍然要等全部跑完才看得见 —— 白改了。
// > 所以条件收紧成：**正在搜 且 目前一个结果都没有**。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../core/ffi.dart';
import '../core/sourin_api.dart';
import '../core/title_match.dart';
import 'tokens.dart';
import 'widgets/fade_in_sliver.dart';
import 'widgets/poster_card.dart';
import 'widgets/settings_kit.dart';
import '../design/icons/app_icons.dart';

/// 一个命中源的结果组：(provider 标识, 源显示名, 该源返回的条目)
///
/// ★ 提成 typedef 是为了让**排序判据**能作为参数传递并被单独测试，
///   而不是把 record 字面量散落在 build 与回调里。
typedef SearchHitGroup = ({
  String provider,
  String name,
  List<MediaItem> items,
});

/// ★★ 按**匹配度**给整组排序（task-73 的核心判据）
///
/// # 判据
/// ```text
/// 组的分数 = 组内**最高**分（`bestTitleScore`）
/// 降序；**同分保持到达顺序**（稳定排序）
/// ```
///
/// # 为什么用组内最高分而不是平均分
///
/// 一个源返回 30 条时通常只有 1~2 条是用户要的，取平均会让
/// 「准确命中了 1 条、其余是噪声」的这种**最准的源**排到后面。
/// 详见 `lib/core/title_match.dart` 的 `bestTitleScore`。
///
/// # 为什么排序判据要提成**顶层函数**
///
/// `_hits` 的重排在 widget 测试里没有 FFI 就走不到（见 `debugBeginSearch`），
/// 而排序规则本身是纯逻辑 ⇒ 提出来可以直接喂输入断言输出。
/// ★ 但**只有这个函数被测是不够的**（那是"测了个没人用的东西"）——
///   所以另有 `debugFeedHit` 让真 widget 树走**同一条代码路径**
///   （`_addHit`），用 `tester.getRect` 读坐标断言渲染顺序。
List<SearchHitGroup> rankHitGroups(
  String keyword,
  List<SearchHitGroup> groups,
) =>
    stableRankDesc(groups, (g) => bestTitleScore(keyword, g.items));

/// 搜索页
class SearchPage extends StatefulWidget {
  const SearchPage({
    super.key,
    this.onOpenDetail,
    this.isTv = false,
  });

  /// 点结果卡片 → 详情页
  ///
  /// ⚠️ 与首页一致：**必须跳详情页**而非直接开播放器，
  ///    否则多集内容无法选集、多源内容无法换源。
  final void Function(String provider, String id)? onOpenDetail;

  final bool isTv;

  @override
  State<SearchPage> createState() => SearchPageState();
}

class SearchPageState extends State<SearchPage> {
  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 第 66 轮轨道 F / L2：搜索页的内容区上限 + 搜索框上限
   * ══════════════════════════════════════════════════════════════════════
   *
   * # Owner 的原话（本轮投诉）
   * > 所有内容都在左边，右边全空
   * > 输入框太丑，什么都没有
   *
   * # 取证（`.probe/probe_tests/zz_t66_l1*.dart`，真渲染树实测）
   * ```text
   * 视口 800  ⇒ 搜索框 w=620   右空 117
   * 视口 1920 ⇒ 搜索框 w=1740  右空 117   ← 一条 1740px 的长条
   * 视口 2560 ⇒ 搜索框 w=2380  右空 117   ← 一条 2380px 的长条
   * ```
   * ⇒ 输入框**跟着窗口无限拉伸**，文字全挤在左端 ⇒ 正是"丑"的主因。
   *
   * # 为什么这个常量写在**本页**，而不是复用 `tokens.dart:684`
   * ```text
   * tokens.dart 那个 `Layout.contentMaxWidth = 1440` 自己的文档明写：
   *   「生产代码已不再引用本常量…不要在当代代码里引用它」
   * （它保留只是为留下原版数值。2026-10-04 Owner 要求"两侧占满"后废弃）
   * ⇒ 引用它会与该文档冲突；而**改**它更不行（会动 20+ 调用点，
   *   且等于撤销 Owner 那次决定）。
   * ⇒ 在本页新建一个页面内常量：**值同 1440，语义是本页自己的**。
   * ```
   *
   * # 为什么是 1440（这个数**不是**我拍的）
   * ```text
   * 它来自原版 CSS 的 `--content-max-w: 1440px`（见 tokens.dart:679 的出处说明），
   * 是这套设计语言原本就有的"内容带"宽度。我沿用它，不再另造数字。
   * ```
   */
  static const double _kContentMaxWidth = 1440;

  /*
   * ══════════════════════════════════════════════════════════════════════
   * ★★★ 为什么**没有**"搜索框独立宽度上限"（第一版有 720，已删）
   * ══════════════════════════════════════════════════════════════════════
   *
   * # 第一版做法（已废弃）
   * ```text
   * 给搜索框单独设 cap = 720，用 Align(center) 居中。
   * 想法是"单行输入框宽到 720 就够了，再宽是空槽"。
   * ```
   *
   * # 实测把它否掉了（`.probe/probe_tests/zz_t66_l2_after_test.dart`）
   * ```text
   * 量"搜索框左缘 − 页头标题左缘"（错位量）：
   *   视口 800  : cap=720 ⇒ 16px  |  cap=960 ⇒ 0    |  满宽 ⇒ 0
   *   视口 1400 : cap=720 ⇒ 316px |  cap=960 ⇒ 196  |  满宽 ⇒ 0
   *   视口 1920 : cap=720 ⇒ 336px |  cap=960 ⇒ 216  |  满宽 ⇒ 0
   *   视口 2560 : cap=720 ⇒ 336px |  cap=960 ⇒ 216  |  满宽 ⇒ 0
   * ```
   * 截图 `.probe/shots/t66/` 第一版产物：页头「搜索」在 x=584，
   * 搜索框在 x=920 —— **错位 336px**，框浮在中间、标题在左边，看着像坏了。
   *
   * # 根因（这条是通用的，不只是本页）
   * ```text
   * 页头标题 / 搜索框 / 结果栅格**共用同一条内容带内边距**
   * （:580-581 / :615 / :1011-1012 / :1064 全调 Layout.contentPaddingOf
   *   或 contentInsetOf）⇒ 它们天然左对齐。
   * 而"框自己居中"意味着框的左缘 = 内容带左缘 + (内容带宽 − cap)/2
   * ⇒ 只要 cap < 内容带宽，就**必然**与左对齐的页头错位。
   * ⇒ 这不是"720 太小"，是"自己居中"与"左基线对齐"二者不可兼得。
   * ```
   *
   * # 结论
   * ```text
   * 搜索框吃满内容带（不设独立 cap）⇒ 与页头、与结果栅格三者一条基线。
   * "框会不会太宽"由 `_kContentMaxWidth = 1440` 统一约束，
   * 不需要、也不应该再给单行输入框设第二个上限。
   * ```
   */

  final _controller = TextEditingController();
  final _focusNode = FocusNode();

  /// 搜索框那层 `Container` 的 GlobalKey
  ///
  /// ★ task-74：搜索框现在住在 `SliverPersistentHeader` 里，而
  ///   `SliverPersistentHeaderDelegate.build()` 在**滚动过程中会被反复调用**
  ///   （`shrinkOffset` 每帧都在变），每次都返回一棵新子树。
  ///
  ///   没有显式 key 时，Flutter 靠 runtimeType 相同 + 位置稳定复用 Element
  ///   —— `TextField` 内部的 `EditableTextState`（光标、选区、输入法组合态）
  ///   **通常**能保住。这里是把这个身份**显式化**，不再依赖"通常"。
  ///
  ///   ⚠️ 诚实说明：我**没有**在本次改动里复现出"不加 key 就丢状态"的现场。
  ///   加它的依据是本仓库已有的同款真实事故
  ///   （`lib/ui/home_page.dart:752-769`：`SliverPersistentHeader` 里
  ///     `SourceBar` 的 `ScrollController` 被重建 ⇒ 用户滚到第 10 个源，
  ///     一滚动全跳回第 1 个），代价为零而收益是消除一类隐患。
  final _searchBoxKey = GlobalKey();

  bool _searching = false;
  bool _searched = false;

  /// 命中的源：(provider, providerName, items)
  ///
  /// ★ 顺序 = **匹配度降序**（不是到达顺序）—— 见 `rankHitGroups`。
  List<SearchHitGroup> _hits = [];

  /// 被跳过的源：(provider, reason)
  List<({String provider, String name, String reason})> _skipped = [];

  /// 已搜完的源数（用于"已搜 12/25 个源"的进度提示）
  ///
  /// 流式搜索下，用户能实时看到"还在搜，已经搜了 12 个"，
  /// 而不是干等一个转圈 —— 这是流畅感的关键。
  int _settled = 0;
  int _totalProviders = 0;

  /// 当前这次搜索的关键词
  ///
  /// ★ task-73 ⑤：排序判据是 `titleSimilarity(keyword, item.title)`，
  ///   所以关键词必须能到达**处理事件的代码**（`_addHit`）。
  ///   它原来是 `_doSearch()` 的**局部变量** —— 局部变量到不了那里。
  ///
  /// ⚠️ 为什么**不能**改在渲染时才排序：
  ///   用户改了关键词后，**上一次搜索的延迟结果仍会到达**
  ///   （`_cancelCurrent()` 实际取消不掉 —— `_currentToken` 从来没被
  ///     赋成真实 token，见 `_doSearch` 的说明）。
  ///   若在渲染时排序，那些旧结果会被**新关键词**打分 —— 顺序更乱。
  ///   ⇒ 一律在**收到事件的那一刻**用**当时那个关键词**算分并固化。
  String _lastKeyword = '';

  /// 当前这次搜索的 token（用于取消）
  ///
  /// ⚠️ 用户连续改关键词时，旧的那次还在跑 ——
  ///    不取消的话旧结果会**混进新结果里**（"幽灵结果"）。
  int? _currentToken;

  @override
  void initState() {
    super.initState();
    _loadProviderCount();
    /*
     * ★★★ 第 66 轮轨道 F / L2-c：让搜索框**看得出自己被聚焦**
     *
     * # 改之前的真缺陷（取证：`.probe/t66_l1g_inputs.txt`）
     * ```text
     * search_page.dart 原来把 InputDecoration 的**每一级**边框都压成 none：
     *   border / enabledBorder / focusedBorder / errorBorder /
     *   focusedErrorBorder / disabledBorder = InputBorder.none
     * （原因见那段注释：全局主题给各级都设了 OutlineInputBorder，
     *   不压掉就会在外层 Container 的描边里面**再多画一条**主色描边）
     * ⇒ 副作用：**聚焦时零视觉变化**。用户点进搜索框，界面上什么都没发生。
     * ```
     * Owner 说「输入框太丑，什么都没有」—— 无焦点反馈是其中一项。
     *
     * # 改法：边框由**外层 Container** 画（这是它原本的职责，见 :520）
     * ```text
     * 外层 Container 的 border 颜色改为：
     *   聚焦 ? colors.primary : colors.outlineVariant
     * ⇒ 焦点态回到"一条主色描边"，且**仍然只有一条**（InputDecoration
     *   那几级继续是 none）—— 不会重蹈"奇怪的边界线"。
     * ```
     *
     * # 为什么用 `addListener` + `setState`，而不是 `Focus` widget / ValueListenable
     * ```text
     * ① 本页**已经**有 `_focusNode`（:119，给 TextField 用的）——
     *    复用它是零新增状态。另建一个会变成两份焦点来源，必然不同步。
     * ② `Focus` widget 会**再插一层**焦点节点，与 TextField 自带的那个
     *    形成父子焦点，`hasFocus` 语义变复杂（要从 `FocusScope` 取）。
     * ③ `setState` 的代价可忽略：焦点一进一出，一共两次重建。
     * ⇒ 用最直接的：listener 里 setState，build 里读 `_focusNode.hasFocus`。
     * ```
     * ⚠️ 只在本页局部做 —— 没引任何全局 FocusNode 管理。
     */
    _focusNode.addListener(_onFocusChanged);
  }

  /// 焦点变化 ⇒ 重画搜索框描边（见 [initState] 的说明）
  void _onFocusChanged() {
    if (!mounted) return;
    setState(() {});
  }

  @override
  void dispose() {
    // 离开页面时取消 —— 别让搜索在后台白跑
    _cancelCurrent();
    /*
     * ★ 与 initState 的 addListener 成对（自己加的自己摘）
     * ⚠️ 必须在 `_focusNode.dispose()` **之前**摘 —— dispose 之后
     *    再 removeListener 会断言（listener 表已经释放了）。
     */
    _focusNode.removeListener(_onFocusChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _loadProviderCount() async {
    try {
      final providers = await SourinApi.listProviders();
      final enabled = providers.where((p) => p.enabled).length;
      if (mounted) setState(() => _totalProviders = enabled);
    } catch (e) {
      debugPrint('[SEARCH] 取源数失败: $e');
    }
  }

  void _cancelCurrent() {
    final t = _currentToken;
    if (t != null) {
      SourinCore.cancelStream(t);
      _currentToken = null;
    }
  }

  Future<void> _doSearch() async {
    final kw = _controller.text.trim();
    if (kw.isEmpty) return;

    // ★ 取消上一次（否则旧源的延迟结果会追加到新列表里）
    _cancelCurrent();

    setState(() {
      _searching = true;
      _searched = true;
      _settled = 0;
      /*
       * ⚠️ 这里**立刻清空**结果，而不是等第一个源回来再清。
       *    否则用户改了关键词后，会先看到**旧关键词的结果**挂在那里，
       *    几秒后才被替换 —— 看起来像"搜索没生效"。
       */
      _hits = [];
      _skipped = [];
      // ★ 事件的打分基准 —— 必须在清空结果的同时定下来
      _lastKeyword = kw;
    });

    try {
      await SourinApi.searchAllStream(kw, (ev) {
        if (!mounted) return false;

        switch (ev.kind) {
          case SearchEventKind.hit:
            /*
             * ★ 每搜到一个源就追加 —— 这就是"搜完一个显示一个"的实现点
             *
             * ★ task-73：追加之后**按匹配度重排**（见 `_addHit`）。
             *
             * ⚠️ 关键词传的是**闭包捕获的 kw**，不是 `_lastKeyword` ——
             *    上一次搜索的延迟结果到达时，必须用**它自己那次**的
             *    关键词打分，否则会被新关键词错误地重排。
             */
            _addHit(kw, ev);

          case SearchEventKind.miss:
            setState(() {
              /*
               * ⚠️ reason 为空 = 搜到了但没结果，**不算"跳过"**
               *
               * 原版：`if (r.reason) { ... }`
               * 把"没结果"也列进"未能返回结果"会让用户以为源坏了。
               */
              if (ev.reason != null && ev.reason!.isNotEmpty) {
                _skipped = [
                  ..._skipped,
                  (
                    provider: ev.provider,
                    name: ev.providerName,
                    reason: ev.reason!,
                  ),
                ];
              }
              _settled++;
            });

          case SearchEventKind.done:
          case SearchEventKind.error:
            // 这两个由 callStream 内部处理，不会走到这里
            break;
        }
        return true;
      });

      if (mounted) {
        setState(() {
          _searching = false;
          _currentToken = null;
        });
      }
    } catch (e) {
      debugPrint('[SEARCH] 搜索失败: $e');
      if (mounted) {
        setState(() {
          _searching = false;
          _currentToken = null;
        });
      }
    }
  }

  /// 收到**一个源**的命中结果：追加 + 按匹配度重排
  ///
  /// # ★★ 流式回填 vs 排序的取舍（task-73 ③ —— 这是**明确的**产品决策）
  ///
  /// ```text
  /// 选的是：**保留流式回填，并在每次回填后重排**
  ///
  /// 理由：流式是 Owner 2026-09-19 亲自提的要求（见文件头 L12-23 的原话）——
  ///       "搜索结束一个就显示一个"，实测首个结果 0.25 秒就到，
  ///       而非流式版要干等 37 秒。**为了排序而放弃流式是明显的倒退。**
  ///
  /// 代价（如实说明，不掩盖）：先到的组可能被后到的更匹配的组**挤下去**，
  ///       所以用户在搜索过程中会看到结果列表重排。
  ///
  /// 为什么这个代价可接受：
  ///   · 用户明确要求"匹配度高的排上面"——重排正是他要的效果
  ///   · 重排只发生在**新结果到达**时（不是每帧），一个源只触发一次
  ///   · 同分组用稳定排序 ⇒ 不会出现"两个同分的结果来回换位"的抖动
  ///   · 搜索通常在 1~3 秒内结束，之后顺序就稳定了
  ///
  /// ❌ 已考虑并否决的方案：先缓冲、等全部源返回再排序显示
  ///      （那会退回"干等 37 秒"的体验，Owner 已经为此提过一次意见）
  /// ```
  ///
  /// ⚠️ 用「新列表」而不是 `_hits.add(...)` —— 后者在某些情况下
  ///    不会触发重建（列表引用没变）。
  void _addHit(String keyword, SearchStreamEvent ev) {
    setState(() {
      _hits = rankHitGroups(keyword, [
        ..._hits,
        (
          provider: ev.provider,
          name: ev.providerName,
          /*
           * ★ 组内也排（task-73 ②）—— 与组间**同一套判据**。
           *
           * ⚠️ 用 `item.title` 算，**不是** `item.note`
           *    （`note` 是"全 27 集"这类副标题，与匹配度无关。
           *      卡片副标题显示的确实还是 note —— 那是对的，
           *      但**排序**不能用它）。
           */
          items: rankItemsByTitleDesc(keyword, ev.items),
        ),
      ]);
      _settled++;
    });
  }

  /// ★ 测试注入口（`@visibleForTesting`）：等于真实链路里
  /// `_doSearch()` 开头那段 setState 的效果（清空 + 记录关键词 + 进入结果态）。
  ///
  /// # 为什么必须有这个口子
  ///
  /// 真实结果来自 `SourinApi.searchAllStream()`（走 FFI 到 Rust 核心）。
  /// `flutter test` 里**没有核心 DLL** ⇒ 该调用必然抛异常
  /// （项目已知：`Failed to load dynamic library 'sourin_core.dll'`）
  /// ⇒ `_hits` 恒为空 ⇒ 所有"顺序"断言都变成对**空列表**的断言。
  ///
  /// ⚠️ 这正是铁律 149 的陷阱：**候选集为空时，全称断言恒真**
  ///    （"排对了"和"根本没数据"看起来一模一样）。
  ///
  /// ⚠️ 生产代码**永远不调用**这两个 debug 方法 ⇒ 行为不变。
  ///    本仓既有同款先例：`my_shelf.dart:253`、`skip_page.dart:92`、
  ///    `detail_page.dart:501`、`follow_page.dart:552`。
  @visibleForTesting
  void debugBeginSearch(String keyword) {
    setState(() {
      _searching = true;
      _searched = true;
      _settled = 0;
      _hits = [];
      _skipped = [];
      _lastKeyword = keyword;
    });
  }

  /// ★ 测试注入口：喂一个 `hit` 事件 —— 走的是**真实那条代码路径**
  /// （`_addHit`），不是测试里另写一份排序。
  @visibleForTesting
  void debugFeedHit(SearchStreamEvent ev) => _addHit(_lastKeyword, ev);

  /// ★ 测试注入口：喂一条"该源失败/被跳过"事件 ⇒ 写进 `_skipped`
  ///
  /// # 为什么必须有它（门禁缺口的实证）
  /// ```text
  /// `debugFeedHit` → `_addHit` **只碰 `_hits`**，从来不写 `_skipped`
  /// ⇒ 在测试里喂 `failed(...)` 只会建出一个**空组**（组标题照样显示源名），
  ///   `_SkippedList`（`源名 · 原因` 那段）**从未被任何门禁执行过**：
  ///     ① 把 `'· ${s.reason}'` 换成固定串 ⇒ 测试仍绿
  ///     ② 整段删掉 `for (final s in skipped)` ⇒ 测试仍绿
  ///   这是"门禁看着绿、其实没覆盖"的又一例。
  /// ```
  /// ⚠️ 写入逻辑与真实流回调**同一份**（见上方 `case SearchEventKind.hit` 那段）：
  ///    reason 为空 = 搜到了但没结果，**不算"跳过"**。
  @visibleForTesting
  void debugFeedSkipped(SearchStreamEvent ev) {
    final reason = ev.reason;
    if (reason == null || reason.isEmpty) return;
    setState(() {
      _skipped = [
        ..._skipped,
        (provider: ev.provider, name: ev.providerName, reason: reason),
      ];
      _settled++;
    });
  }

  /// ★ 测试注入口：等于 `_loadProviderCount()` **成功**时的效果。
  ///
  /// # 为什么单独开一个口子（而不是塞进 `debugBeginSearch`）
  ///
  /// 因为 `build` 里的分支顺序是：
  /// ```
  ///   if (_totalProviders == 0)       ← 先判这个
  ///     『当前没有支持搜索的内容源』
  ///   else if (_searching && _hits.isEmpty)
  ///     骨架
  ///   else if (_searched) … 结果 …
  /// ```
  /// ⇒ `_totalProviders == 0` 会**挡住整个结果区**：
  ///    一个源明明回来了、`_hits` 里也真有数据，
  ///    界面上却还是那句"没有支持搜索的内容源"。
  ///
  /// ⚠️ 而 `flutter test` 里 `listProviders()` 必然抛异常（无核心 DLL）⇒
  ///    `_totalProviders` 恒为 0 ⇒ 结果区**永远不渲染** ⇒
  ///    所有"顺序"断言都会退化成对空树的断言（铁律 149）。
  ///
  /// ⇒ 这个口子只补**环境前置条件**，不改任何渲染逻辑；
  ///    与 `debugBeginSearch` 各对应真实链路里的一段（`_doSearch` / `_loadProviderCount`）。
  @visibleForTesting
  void debugSetProviderCount(int n) {
    setState(() => _totalProviders = n);
  }

  /// ★ 测试注入口：模拟**流结束**（真实链路里 `_doSearch` 的 try 结束分支，见 :394-400）
  ///
  /// # 为什么必须有它（而不是把断言放宽）
  /// ```text
  /// 界面上「没有找到相关内容」只在 `_totalResults == 0 && !_searching` 时渲染；
  /// 而 `_searching` 只由**流结束**置 false。没有这个口子时，门禁只能断言
  /// "空结果不白屏"（空态文案 or 进度行）—— 那比"必须是空态文案"弱一档。
  /// ⇒ 补这一段环境前置条件，**不改任何渲染逻辑**（生产从不调用）。
  /// ```
  @visibleForTesting
  void debugEndSearch() {
    setState(() {
      _searching = false;
      _currentToken = null;
    });
  }

  void _clear() {
    _cancelCurrent();
    setState(() {
      _controller.clear();
      _hits = [];
      _skipped = [];
      _searched = false;
      _searching = false;
      _settled = 0;
      _lastKeyword = '';
    });
  }

  void _open(MediaItem item) {
    final i = item.id.indexOf(':');
    if (i < 0) return;
    widget.onOpenDetail?.call(
      item.id.substring(0, i),
      item.id.substring(i + 1),
    );
  }

  int get _totalResults =>
      _hits.fold(0, (n, h) => n + h.items.length);

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ★ 原版是「内容带 1440px 上限 + 居中」（`base.css:549-558` 的
     *   `.container { max-width: var(--content-max-w); margin: 0 auto }`）。
     *   ★ 2026-10-04（业主：改为两侧占满）起 [Layout.bandFor] 不再封顶
     *   ⇒ `Layout.sideInsetOf` **恒返回 0**，这一层现在是空操作。
     *
     * 为什么是**外层 `Padding`**：`RenderViewport.sizedByParent == true`
     * （SDK `rendering/viewport.dart:1676`）⇒ 视口取 `constraints.biggest`，
     * `Center` 传下来的 `maxWidth` 还是整窗宽 ⇒ 空操作；`Padding` 先把
     * `maxWidth` 减掉 `2*side` ⇒ 视口真的变窄（★ 现在 `side == 0`，
     * 逐字节等于改动前的树）。
     * ⚠️ `CustomScrollView` **没有** `padding` 参数，只能这样写。
     */
    return Padding(
      padding: Layout.sideInsetOf(context),
      child: Align(
        /*
         * ★★★ 第 66 轮轨道 F / L2-a：结果区内容带**上限 1440 + 居中**
         *
         * # 为什么加在 `CustomScrollView` **外面**（而不是每个 sliver 里）
         * ```text
         * 结果区由**三类 sliver** 拼成（页头 / 搜索框 / 结果组），
         * 它们各自有自己的左右 padding（`Layout.contentInsetOf`）。
         * 若在每个 sliver 内部各加一次上限，三点会**各自居中但互相错位**
         * （页头 1440、结果组 1440，但两者用的约束来源不同就漂）。
         * ⇒ 在滚动视图**外层**收一次，三处自动同宽同位置。
         * ```
         *
         * # 为什么这里 `Align` 不会是空操作（重要）
         * ```text
         * tokens.dart:765 记着"套在滚动体外面的 Center 是空操作"——
         * 那是 **Center 直接包 CustomScrollView** 的情形：
         *   Center 给 loose 约束 ⇒ 视口仍取 constraints.biggest ⇒ 整窗宽。
         * ★ 我这里用的是 `Align` + **`ConstrainedBox` 先收紧 maxWidth**：
         *   收紧后 constraint.biggest == 1440 ⇒ 视口**真的**变 1440。
         * ⇒ 关键不是"Align 还是 Padding"，而是"maxWidth 有没有真的变小"。
         * ```
         *
         * ⚠️ 视口 ≤ 1440 时上限不生效 ⇒ 行为与改前**逐字节相同**
         *    （Owner 的窄窗体验不会被这条改动碰到）。
         */
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: _kContentMaxWidth),
          child: CustomScrollView(
            // ★ 主滚动区**显式 key**：门禁按 key 定位它再滚动
            //
            // 为什么不能靠 `find.byType(Scrollable).first`：
            // ```text
            // 那是**隐式假设"页面只有一个滚动区"**。将来加横向分类条 / rails 时，
            // `.first` 会滚到**错的**那个 Scrollable，且**不报错**（滚了没反应）
            // —— 典型假绿来源。⇒ 主滚动区必须有 key。
            // ```
            key: const ValueKey<String>('search-results-scroll'),
            clipBehavior: Clip.antiAlias,
            slivers: [
        // ── 页头 ──（随内容滚走）
        SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.only(
              top: Sp.x8,
              // ★ 窄屏收一档（16）—— 与原版 `.container` 的 640px 断点一致
              left: Layout.contentPaddingOf(context),
              right: Layout.contentPaddingOf(context),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '搜索',
                  style: TextStyle(
                    fontSize: FontSizes.xl,
                    fontWeight: FontWeights.semibold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  '同时搜索全部已启用内容源',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),

        // ── 搜索框 ──（★ pinned：滚到哪都留在视口顶）
        SliverPersistentHeader(
          pinned: true,
          delegate: _StickySearchBar(
            minExtent: _searchBarHeight,
            maxExtent: _searchBarHeight + AppMetrics.homeTopPadding,
            background: colors.surface,
            child: Padding(
              padding: Layout.contentInsetOf(context),
              /*
               * ★★★ 第 66 轮轨道 F / L2-b：搜索框**不再跟着窗口无限拉伸**
               *
               * # 改前（实测，`.probe/t66_l1g_inputs.txt`）
               * ```text
               * 800  ⇒ w=620     1920 ⇒ w=1740     2560 ⇒ w=2380
               * ```
               * 一条 2380×48 的长条，hint 挤在左端，右边 2000px 全是同质空槽。
               *
               * # 改法：**跟着内容带走**（不另设小上限）
               * ```text
               * 外层已经用 `_kContentMaxWidth = 1440` 把内容带收窄并居中
               * （见 build 里那个 Align + ConstrainedBox）⇒ 本框直接吃满内容带，
               * 自然就跟着一起居中，**不需要**再设一个 720 的独立上限。
               * ```
               *
               * # ★★★ 为什么放弃"720 上限 + 框自己居中"（第一版就是这么写的）
               * ```text
               * 实测截图 `.probe/shots/t66/t66_after_2560.png`：
               *   页头「搜索」标题在 x=584，搜索框却在 x=920 —— **错位 336px**
               * 因为它居中的参照是"内容带"（584..1976），而页头文字是
               * **左对齐**在同一内容带上 ⇒ 框浮在中间、标题在左边，看着像坏了。
               * ⇒ 一个输入框不该比它自己的标题更"居中"。
               *
               * 另外：720 在 1400 视口（t75 测试用的那档）也会生效，
               * 会把 left 从 24 挤到 340 ⇒ 与"内容带左缘对齐"这个不变量冲突。
               * ```
               * ⇒ 现在：**搜索框与页头、结果栅格共用同一条左基线**，
               *   三者一起被内容带的上限带着居中。这才是"对齐"，不是"各自居中"。
               */
              child: Container(
                key: _searchBoxKey,
                padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
                  borderRadius: Radii.rLg,
                  /*
                   * ★ L2-c：聚焦时描边转主色（改前恒为 outlineVariant）
                   *
                   * 改前用户点进搜索框**界面毫无变化**（InputDecoration
                   * 各级都被压成 none，见下面 TextField 的那段长注释）。
                   * ⇒ 焦点态由**这一层**负责 —— 它本来就是画描边的那一层。
                   *
                   * ⚠️ 只改**颜色**，不加粗：加粗会让框宽高变化 1px，
                   *    而 `_searchBarHeight = 50` 是写死的紧约束
                   *    ⇒ 加粗必然 `RenderFlex overflowed`（见那个常量的说明）。
                   */
                  border: Border.all(
                    color: _focusNode.hasFocus
                        ? colors.primary
                        : colors.outlineVariant,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      AppIcons.search,
                      size: 18,
                      color: colors.onSurfaceVariant,
                    ),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: TextField(
                        controller: _controller,
                        focusNode: _focusNode,
                        // ★ TV / 键盘唯一的入口：没有它遥控器永远进不了输入框
                        //  （`_searchBoxKey` 只用来 ensureVisible 滚动，不管焦点）
                        autofocus: true,
                        textInputAction: TextInputAction.search,
                        onSubmitted: (_) => _doSearch(),
                        onChanged: (_) => setState(() {}),
                        decoration: const InputDecoration(
                          hintText: '输入片名、剧名或关键词…',
                          /*
                           * ⚠️⚠️ 2026-10-13 修（Owner 反馈「聚焦时有奇怪的边界线」）：
                           *      **只写 `border: none` 不够！**
                           *
                           * `InputDecoration` 的各级描边**优先级高于 `border`**：
                           * ```text
                           * focusedBorder > enabledBorder > border
                           * ```
                           * 而全局主题（`theme_bridge.dart:480-505`）给这几级**都**设了
                           * `OutlineInputBorder`（聚焦还转主色）⇒ 本框一聚焦就画出
                           * 一条**主色圆角描边**，叠在外层 `Container` 已有的
                           * `outlineVariant` 描边里面 ⇒ 看上去就是"奇怪的边界线"。
                           *
                           * ⇒ 本框的边框由**外层 Container** 负责（见上面
                           *   `Border.all(color: colors.outlineVariant)`），
                           *   所以这里要把**每一级**都显式压成 `none`。
                           * ```
                           * ★ 教训：`InputBorder.none` 是"默认态"的开关，不是"全部态"的。
                           * ```
                           */
                          border: InputBorder.none,
                          enabledBorder: InputBorder.none,
                          focusedBorder: InputBorder.none,
                          errorBorder: InputBorder.none,
                          focusedErrorBorder: InputBorder.none,
                          disabledBorder: InputBorder.none,
                        ),
                      style: const TextStyle(fontSize: FontSizes.base),
                      ),
                    ),
                    if (_controller.text.isNotEmpty)
                      IconButton(
                        onPressed: _clear,
                        icon: const Icon(AppIcons.close, size: 16),
                        tooltip: '清空',
                      ),
                    const SizedBox(width: Sp.x1),
                    FilledButton(
                      onPressed:
                          (_searching || _controller.text.trim().isEmpty)
                              ? null
                              : _doSearch,
                      child: Text(_searching ? '搜索中…' : '搜索'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),

        const SliverToBoxAdapter(child: SizedBox(height: Sp.x6)),

        // ── 无可搜索源 ──
        if (_totalProviders == 0)
          const SliverToBoxAdapter(
            child: EmptyState(
              icon: AppIcons.travel_explore_outlined,
              title: '当前没有支持搜索的内容源',
              hint: '某电视台官方无公开搜索接口。启用其它内容源后即可在这里一起搜索。',
            ),
          )

        // ── ★★ 骨架只在「一个源都还没回来」时显示 ──
        else if (_searching && _hits.isEmpty)
          const SliverToBoxAdapter(child: _SearchSkeleton())

        // ── 结果 ──
        //
        // ★ task-80：骨架 → 内容 的淡入（与首页 `home_page.dart` 同款）
        //
        // ## 为什么只包**内容侧**，不包骨架侧
        //
        // 骨架屏是**立刻反馈** —— 它的职责是马上告诉用户"在加载了"。
        // 给它加 200ms 淡入等于**延迟反馈**，与它存在的目的相反。
        // 该淡入的是**取代它的内容**（首页也是这么做的）。
        //
        // ## 为什么是 `FadeInSliver` 而不是 `AnimatedOpacity`
        //
        // 这里是**首次挂载**（初值 == 目标值）⇒ `AnimatedOpacity` 要等
        // "目标值变化"才补间 ⇒ **不会播**。`FadeInSliver` 内部的
        // `TweenAnimationBuilder` 首帧就开始补间 ⇒ 天然"出现"动画。
        //
        // ⚠️ 而且它包的是 **sliver 版**（`SliverFadeTransition`）——
        //    换成盒模型的 `Opacity` 就得套 `SliverToBoxAdapter`，
        //    那会把整个 `SliverList` 变成盒模型孩子 ⇒ **丢掉懒加载**。
        //
        // ## Reduce Motion
        //
        // `FadeInSliver` 内部走 `MotionPrefs.duration` ⇒ 系统关掉动画时
        // duration 变 `Duration.zero`，**第 0 帧就到位**（不播）。
        else if (_searched)
          FadeInSliver(
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                /*
                 * 「没找到」只在**搜索全部结束**后才下结论
                 *
                 * ⚠️ 如果一有结果就判空，搜索刚开始（还没源回来）就会
                 *    闪一下"没有找到相关内容" —— 那是误报。
                 */
                if (_totalResults == 0 && !_searching)
                  const _NoResult()
                else if (_totalResults > 0)
                  for (final h in _hits) _ResultGroup(group: h, onOpen: _open),

                /*
                 * ★ 还在搜：进度行**与「有没有结果」无关**，一律显示
                 *
                 * 原来它被关在 `else if (_totalResults > 0)` 里面 ⇒
                 * 「一个源都还没命中、但后面还有源在搜」的那两三秒里，
                 * 结果区**整块是空的** —— 用户看到的是"搜了但什么都没发生"。
                 * 现在连「暂无结果，先给你个进度」这一段也一起给。
                 */
                if (_searching) _SearchProgress(settled: _settled, total: _totalProviders),

              ]),
            ),
          )

        // ── 未搜索：空态引导（对齐 SearchView.vue 的 `未搜索` 分支）──
        //
        // ⚠：`slivers:` 里只能放 Sliver。这里用
        //    `SliverToBoxAdapter` 包一个普通 Box widget（同 `_NoResult`）。
        else
          const SliverToBoxAdapter(child: _IdleHint()),

        /*
         * ★★ 2026-10-26（可诊断性缺口）：**被跳过的源**与"有没有结果 / 是否还在搜"
         * **无关** —— 所以它是上面整条 if/else 链的**并列元素**，不是替身：
         * ```text
         * · 还在搜（骨架）且已有源失败  ⇒ 现在也能看到"哪几路挂了"
         *   （改前：骨架分支吃掉整条 else-if 链 ⇒ skipped 一个都不显示）
         * · 全部源失败（空态）        ⇒ 「没有找到相关内容」+ 失败清单**同时**出现
         * · 正常有结果                ⇒ 结果之后照旧列出失败源
         * ```
         * ⚠️ 判据见 `zz_t1052` ④：全源失败时**两者都必须在**；没有 skipped 时**不许**画空列表头。
         */
        if (_searched && _skipped.isNotEmpty)
          SliverToBoxAdapter(child: _SkippedList(skipped: _skipped)),
        // ── 底部让位（悬浮底栏盖在所有路由之上）──
        //
        // ⚠️ 这里**不能**加 `const`：`Sp.bottomBarInset` 是 getter
        //    （`Device.isTv ? 110 : 90`，见 `lib/ui/tokens.dart:73`），
        //    不是编译期常量 ⇒ `const SliverToBoxAdapter(...)` 会报
        //    `invalid_constant`。同款写法见 `settings_sub_page.dart:275`。
        SliverToBoxAdapter(child: SizedBox(height: Sp.bottomBarInset)),
          ],
        ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★ task-74：搜索框吸顶条
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（m04668）：
// > 搜索页面,搜索框固定在上面,下面内容区域滚动
//
// # 为什么用 `SliverPersistentHeader(pinned: true)` 而不是自己监听滚动偏移
//
// 与 `lib/ui/widgets/settings_sub_page.dart:220-227` 的结论同源（照抄既有惯用法）：
// ```text
// ① Flutter 的**惯用法**（用户说"参考 github 开源项目"）
// ② pinned 的语义就是"滚到哪都留在视口顶" —— 正是用户要的
// ③ 比"监听滚动偏移 + AnimatedPositioned 自己摆"稳：
//    后者要与滚动物理/回弹/焦点滚动打架，本项目已有 `spatial_nav`
//    的 `ensureVisible` 与滚轮互相干扰的前例（task-3）
// ```
// `ListView` 的所有子项是平级的，没有一个能"钉住"；
// `CustomScrollView` 的子项是 sliver，而 `SliverPersistentHeader` 正是
// Flutter 里对应 CSS `position: sticky` 的东西
// （同款改造见 `lib/ui/home_page.dart:565-594` 的源条吸附）。

/// 搜索框吸顶条的**吸顶高度**（= 搜索框自身的高度）
///
/// ★ 实测值，不是估的：探针 `.probe/probe_tests/t75_measure_probe_test.dart`
///   在视口 1400×900 下量得搜索框那个 `Container` 高 **50**
///   —— `TextField` / `FilledButton` 各 48（高度由主题决定）+ 上下各 1px 边框。
///
/// ⚠️ `SliverPersistentHeader` 给子件的是**紧约束**：子件高度不等于 extent
///   就会报 `RenderFlex overflowed`。所以这个数字必须与真实高度一致 ——
///   `test/t75_search_pinned_test.dart` 会渲染整页并滚动，溢出会直接让测试变红。
const double _searchBarHeight = 50;

/// 搜索框的吸顶条
class _StickySearchBar extends SliverPersistentHeaderDelegate {
  const _StickySearchBar({
    required this.minExtent,
    required this.maxExtent,
    required this.background,
    required this.child,
  });

  /// 吸顶后的高度（= 搜索框自身高度）
  @override
  final double minExtent;

  /// 未滚动时的展开高度（= 吸顶高度 + [AppMetrics.homeTopPadding]）
  @override
  final double maxExtent;

  /// ★★ pinned 条**必须不透明**
  ///
  /// 它 pinned 在顶部、内容从**它下面**滚过 —— 若透明，
  /// 结果卡片会与搜索框叠在一起。用 `colors.surface`
  /// （与页面底色同源，见 `lib/ui/app_theme.dart:350`：浅色下
  /// `surface = LightTokens.bgBase = #EEF0F6`）。
  ///
  /// ⚠️ 不要拿搜索框**自身**那层
  ///    `surfaceContainerHighest.withValues(alpha: 0.35)` 当条背景：
  ///    那是框内填充（设计的一部分，保留），但它透光 ——
  ///    滚动时内容会从框外那 [AppMetrics.homeTopPadding] 里透出来。
  ///
  /// ⚠️ 也不要用 `FTheme.colors.background` —— forui 的
  ///    `neutral.light.background` 是**纯白 #FFFFFF**，会白叠白
  ///    （见 `lib/ui/app_theme.dart:191-196`）。
  final Color background;

  final Widget child;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    /*
     * `maxExtent - shrinkOffset` 随滚动从 maxExtent 递减到 minExtent；
     * 多出来的那截（= homeTopPadding）通过 padTop 还给子件 ⇒
     * 展开时顶距 20、吸顶后收到 0，且子件**始终**是 minExtent 高。
     *
     * ★ 这与 `settings_sub_page.dart` 的 `_StickyBackBar` 是同一套算法
     *   （那里是"返回条 + 大标题收起"，这里是"搜索框 + 顶距收起"）。
     */
    final h = (maxExtent - shrinkOffset).clamp(minExtent, maxExtent);
    final padTop = ((maxExtent - shrinkOffset) - minExtent)
        .clamp(0.0, maxExtent - minExtent);
    return Container(
      height: h,
      color: background,
      padding: EdgeInsets.only(top: padTop),
      child: child,
    );
  }

  @override
  bool shouldRebuild(_StickySearchBar old) =>
      old.minExtent != minExtent ||
      old.maxExtent != maxExtent ||
      old.background != background ||
      old.child != child;
}

// ═══════════════════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════════════════

class _ResultGroup extends StatelessWidget {
  const _ResultGroup({required this.group, required this.onOpen});

  final SearchHitGroup group;
  final void Function(MediaItem) onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    /*
     * ★ 列数与间距都与**真实网格**同源（`Layout`）—— 等价原版
     *   `base.css:1020-1024` 的
     *   `repeat(auto-fill, minmax(calc(var(--poster-w) - 16px), 1fr))`。
     *
     * 旧写法 `(w - 48) / 160` 到 2560px 宽的屏幕上仍是 12 列（列数被上限截住、
     * 单张被拉到 ~198px = 原版 160px 的 1.24 倍：`(2560-48-11×12)/12`）；
     * 现在同一个 2560px 由 Layout 算：inner = 2560−48 = 2512，
     * cols = min(⌊(2512+16)/(152+16)⌋, 12) = min(15, 12) = **12**，
     * cell = (2512−16×11)/12 = **194.67** —— 与 t493 探针实测逐值相同
     * (`page=browse size=2560x1440 cols=12 cell=194.67 gap=16.00 left=24.00 span=2512.00`，Layout 同源)。
     *
     * ⚠️ 入参是**内容带宽度**（`bandFor(窗口宽)`，★ 2026-10-04 起恒等于窗口宽）
     *    —— 减左右内边距那一步在 `Layout` 里只做一次（task-74⑤ 那个双重相减的坑）。
     */
    /*
     * ★★★ 第 66 轮轨道 F / L2-a：列数必须按**本组真实可用宽度**算
     *
     * # 改之前
     * ```text
     * band = Layout.bandFor(MediaQuery.sizeOf(context).width)   ← 窗口宽
     * ```
     * 2026-10-04 起 `bandFor` 恒等于窗口宽 ⇒ 那时它是对的（内容也铺满窗口）。
     *
     * # 为什么现在必须换
     * ```text
     * 本轮给搜索页加了 `_kContentMaxWidth = 1440` 的内容区上限。
     * 若仍按**窗口宽**（2560）算列数：
     *   cols = 12（2560 算出来是 12）
     *   而实际可用只有 1440 − 48 = 1392
     *   ⇒ 每张卡 = (1392 − 16×11) / 12 = **101.33px**
     *   ⇒ ★ 低于 `Layout.minCellWide = 152` 的下限，海报被压扁
     * ⇒ 这正是本仓反复踩的"两个数不同源"的坑（task-74⑤ 的双重相减同类）。
     * ```
     * # 修法：改用 `LayoutBuilder` 的真实约束（本组实际拿到的宽度）
     * ```text
     * 不受上限影响时（窗口 ≤ 1440）：约束宽 == 窗口宽 ⇒ 与旧行为**逐值相同**
     *   例：视口 800 ⇒ 约束 800 ⇒ cols 4（改前也是 4）
     * 受上限影响时（窗口 > 1440）：约束宽 == 1440 ⇒ cols 8、cell 160
     *   ⇒ 卡片回到正常尺寸，而不是被压成 101px
     * ```
     * ⚠️ `LayoutBuilder` 的 `maxWidth` 是**本组拿到的宽度**（已扣过内容区上限，
     *   但**还没**扣 `contentPadding`）⇒ 与 `columnsForBand` 的入参语义一致
     *   （它内部自己减内边距，只减一次）。
     */
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final band = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(ctx).width;
        final cols = Layout.columnsForBand(band);

        return Padding(
          // ★ 组间距用 Sp.x8；底部让位由 CustomScrollView 末尾那个
          //   SliverToBoxAdapter 统一给（见 build 的最后一条 sliver）。
          //   原来每一组都带 Sp.bottomBarInset(90) ⇒ 组间凭空多出 90px 空白，
          //   结果一多就变成"结果之间裂开"，与"不闪不跳"的要求正好相反。
          padding: const EdgeInsets.only(bottom: Sp.x8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
          Padding(
            padding: EdgeInsets.only(
              bottom: Sp.x2,
              left: Layout.contentPaddingOf(context),
              right: Layout.contentPaddingOf(context),
            ),
            child: Row(
              children: [
                Container(
                  width: 4,
                  height: 18,
                  decoration: BoxDecoration(
                    color: colors.primary,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  group.name,
                  style: TextStyle(
                    /*
                     * ★★★ 2026-10-09（Owner 第 12 条「文字大小/粗细不一致」）
                     *     这里原本是 `FontSizes.base`(16)，已统一为 `lg`(20)。
                     * ```text
                     * 判据（同语义同刻度，不是审美偏好）：
                     *   本行与本页 home 首页的 rail 标题（home_page.dart:1069）
                     *   是**同一个视觉角色**——「一屏里可重复出现的区块标题」，
                     *   且两处除字号外的三个属性**逐项相同**：
                     *     home_page.dart:1069  lg + w600 + colors.onSurface
                     *     search_page.dart:850  base + w600 + colors.onSurface
                     *   ⇒ 只有字号漂移过，属于需要修的「不一致」。
                     *   同类区块标题（设置页:2439 / 我的片库 / 快捷键 / 字幕面板）
                     *   全体都是 lg ⇒ 这一处是唯一的例外。
                     * ```
                     * ⚠️ 这是**已裁决的统一**（lead 已独立核实两处源码），
                     *    不要因为「搜索页字小一点更紧凑」再把它改回 base ——
                     *    那会让同角色刻度再次分裂。
                     */
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(width: Sp.x2),
                Text(
                  '${group.items.length} 个结果',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: Sp.x4),
          Padding(
            padding: Layout.contentInsetOf(context),
            child: GridView.builder(
              clipBehavior: Clip.antiAlias,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: cols,
                // ★ 宽档 16（原版 `--poster-gap`）/ 窄档 12，与列数同源
                crossAxisSpacing: Layout.gapFor(band),
                mainAxisSpacing: Sp.x5,
                // 高度 = 海报高 + 标题两行（原版 base.css:844-854 固定两行）
                childAspectRatio: AppMetrics.posterWidth /
                    (AppMetrics.posterWidth /
                        AppMetrics.posterAspect +
                        AppMetrics.posterMetaHeight(titleLines: 2)),
              ),
              itemCount: group.items.length,
              itemBuilder: (_, i) => PosterCard(
                title: group.items[i].title,
                cover: group.items[i].cover,
                subtitle: group.items[i].note,
                titleLines: 2,
                onTap: () => onOpen(group.items[i]),
              ),
            ),
          ),
        ],
          ),
        );
      },
    );
  }
}

/// 搜索进行中的进度行
///
/// # 为什么单独一个零件
///
/// 它现在**与「有没有结果」无关**地显示（见 build 里那处改动），
/// 两种情形下文案不一样：
/// ```text
/// 命中过 → 「还在搜索…（已搜 3/12 个源）」
/// 一条没中 → 「正在搜索 12 个内容源…」（不能写"已搜"，还没结果）
/// ```
class _SearchProgress extends StatelessWidget {
  const _SearchProgress({required this.settled, required this.total});

  final int settled;
  final int total;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final label = settled > 0
        ? '还在搜索…（已搜 $settled${total > 0 ? "/$total" : ""} 个源）'
        : '正在搜索 ${total > 0 ? "$total " : ""}个内容源…';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Sp.x8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 15,
            height: 15,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: colors.primary,
            ),
          ),
          const SizedBox(width: Sp.x3),
          Text(
            label,
            style: TextStyle(
              fontSize: FontSizes.sm,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _SkippedList extends StatelessWidget {
  const _SkippedList({required this.skipped});

  final List<({String provider, String name, String reason})> skipped;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: Layout.contentInsetOf(context),
      child: Container(
        padding: const EdgeInsets.all(Sp.x4),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
          borderRadius: Radii.rLg,
          border: Border.all(color: colors.outlineVariant),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(AppIcons.error_outline, size: 14, color: colors.error),
                const SizedBox(width: Sp.x2),
                Text(
                  '${skipped.length} 个源未能返回结果',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    fontWeight: FontWeight.w600,
                    color: colors.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Sp.x3),
            for (final s in skipped)
              Padding(
                padding: const EdgeInsets.only(bottom: 2),
                child: Row(
                  children: [
                    Text(
                      s.name.isEmpty ? s.provider : s.name,
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: Sp.x2),
                    Expanded(
                      child: Text(
                        '· ${s.reason}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: colors.onSurfaceVariant.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _NoResult extends StatelessWidget {
  const _NoResult();

  @override
  Widget build(BuildContext context) => const EmptyState(
        icon: AppIcons.search_off,
        title: '没有找到相关内容',
        hint: '换个关键词试试，或检查是否已启用对应内容源',
      );
}

/// 搜索页的「还没搜」引导
///
/// ★ 与 [_NoResult] 走**同一个** [EmptyState] 零件 —— 两个空态的
///   图标 / 标题 / 说明三层节奏必须一致，否则用户会以为
///   「换了页面」（其实只是没搜 vs 搜了没找到）。
class _IdleHint extends StatelessWidget {
  const _IdleHint();

  @override
  Widget build(BuildContext context) => const EmptyState(
        icon: AppIcons.search,
        title: '搜索全部内容源',
        hint: '输入关键词后回车即可同时搜索',
      );
}

class _SearchSkeleton extends StatelessWidget {
  const _SearchSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    /*
     * ★★ 骨架必须与真实结果**逐值同形**，否则骨架→内容那一帧会跳高
     *
     * 原实现画的是**横向** `ListView`（一排 6 张，`posterWidth` 宽），
     * 真实结果却是**网格**（`cols` 列、每行 `cols` 张）：
     * ```text
     * 骨架行高 = railHeight(2)        = 148/0.667 + meta(2)
     * 网格行高 = posterWidth/aspect + meta(2) —— 同一个值 ✓
     * ```
     * 行高对得上，但**列数与每行张数**对不上（6 vs cols），
     * 换成内容时整块宽度重排 ⇒ 肉眼可见的"一跳"。
     *
     * ⇒ 这里也按 `Layout.columnsForBand` 铺成同样的网格，
     *    并且条数取 `cols × 2`（两整行），落位与内容逐格一致。
     */
    final band = Layout.bandFor(MediaQuery.sizeOf(context).width);
    final cols = Layout.columnsForBand(band);
    final inset = Layout.contentInsetOf(context);
    final gap = Layout.gapFor(band);

    Widget bar(double w, double h) => Container(
          width: w,
          height: h,
          decoration: BoxDecoration(
            color: colors.onSurface.withValues(alpha: 0.07),
            borderRadius: BorderRadius.circular(4),
          ),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (var g = 0; g < 2; g++)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: EdgeInsets.only(
                    left: inset.left,
                    right: inset.right,
                    bottom: Sp.x2,
                  ),
                  child: Row(
                    children: [
                      bar(4, 18),
                      const SizedBox(width: Sp.x2),
                      bar(110, 18),
                    ],
                  ),
                ),
                Padding(
                  padding: inset,
                  child: GridView.builder(
                    clipBehavior: Clip.antiAlias,
                    shrinkWrap: true,
                    physics: const NeverScrollableScrollPhysics(),
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: cols,
                      crossAxisSpacing: gap,
                      mainAxisSpacing: Sp.x5,
                      childAspectRatio: AppMetrics.posterWidth /
                          (AppMetrics.posterWidth /
                              AppMetrics.posterAspect +
                              AppMetrics.posterMetaHeight(titleLines: 2)),
                    ),
                    itemCount: cols * 2,
                    itemBuilder: (_, __) => DecoratedBox(
                      decoration: BoxDecoration(
                        color: colors.onSurface.withValues(alpha: 0.07),
                        borderRadius: Radii.rMd,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
