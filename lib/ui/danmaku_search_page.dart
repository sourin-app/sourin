import 'package:material_ui/material_ui.dart';
import 'package:flutter/foundation.dart' show listEquals;
import '../core/danmaku.dart';
import '../core/batch_bind.dart';
import '../core/sourin_api.dart' show PlaybackErrorText;
import 'widgets/danmaku_settings_dialog.dart';
import 'widgets/app_dialog_shell.dart';
import 'widgets/bili_import_dialog.dart';
import 'widgets/cover_image.dart';
import 'tokens.dart';

/// Session-owned, in-memory search draft. The host controls its lifetime.
class DanmakuSearchDraft {
  DanmakuSearchDraft({this.keyword = '', Set<int>? selectedEpisodeIds,
    this.previewing = false}) : selectedEpisodeIds = {...?selectedEpisodeIds};
  String keyword;
  final Set<int> selectedEpisodeIds;
  bool previewing;
}

/// Host-owned search and binding state with an optional session draft.
class DanmakuSearchPage extends StatefulWidget {
  const DanmakuSearchPage({super.key, required this.state, required this.biliState,
    required this.localTitles, required this.onSearch, required this.onBiliSearch,
    required this.onPickMatch, required this.onBatchBind, required this.onBiliImport,
    this.onBatchBindPlan,
    required this.onBiliSelectPage, required this.onClose, this.draft,
    this.onReload, this.onOpenLocal, this.workTitle, this.onBack});
  final DanmakuSettingsState state;
  final BiliImportState biliState;
  final List<String> localTitles;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onBiliSearch;
  final ValueChanged<DanmakuMatch> onPickMatch;
  final ValueChanged<List<DanmakuMatch>> onBatchBind;

  /// 第 11 项：把**用户确认过的映射**交给宿主（含改号与拖动后的顺序）
  ///
  /// 与 [onBatchBind] 的区别：那个交的是"原始候选列表"，宿主会**重算**映射
  /// （用户改过的对应关系会被覆盖）。有它就走它 —— 宿主不再重算。
  final void Function(List<BatchBindPlanItem> items, String workTitle)?
      onBatchBindPlan;
  final ValueChanged<String> onBiliImport;
  final ValueChanged<int> onBiliSelectPage;
  final VoidCallback onClose;
  final VoidCallback? onBack;
  final VoidCallback? onReload;
  final VoidCallback? onOpenLocal;
  final DanmakuSearchDraft? draft;

  /// 当前在给**哪一部作品**搜弹幕（宿主传进来；空 = 未知）
  ///
  /// # 为什么需要它（N4-3 #1，真机截图 `.probe/n4-3-layout/n4-3-wide-results.png`）
  /// ```text
  /// 顶栏只有「✕ 搜索弹幕与绑定剧集」，右侧 800px 是空白 ——
  /// 用户在这个页面上**看不到自己在给哪部剧搜**：
  /// 搜到两条同名剧时无从核对，绑错了也看不出。
  /// ```
  /// # 为什么由宿主传，不在这里去查
  /// ```text
  /// 页面拿到的只有 `localTitles`（每一集的标题），
  /// 作品名只有宿主（播放页）知道 ⇒ 单一数据源，不在这里拼。
  /// ```
  final String? workTitle;

  @override
  State<DanmakuSearchPage> createState() => _DanmakuSearchPageState();
}

enum _SearchChannel { all, danApi, video }

class _DanmakuSearchPageState extends State<DanmakuSearchPage> {
  final _keyword = TextEditingController();
  final _selected = <int>{};
  bool _preview = false;
  bool _dispatching = false;
  _SearchChannel _channel = _SearchChannel.all;

  /// 候选 episodeId → 本地集下标（-1 = 明确不绑定）；缺省由计划决定
  final Map<int, int> _assign = <int, int>{};

  /// 预览行的**用户顺序**（本地集下标）；拖动改它
  List<int> _order = <int>[];
  @override
  void initState() {
    super.initState();
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ N4-2（2026-10-27）：**默认必须填剧名**（Owner 原话："默认没有
     *      填充剧的名字"）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 根因（读码即可证，不是猜）
     * ```text
     * 改前：_keyword.text = draft?.keyword ?? widget.state.searchKeyword;
     *
     * `??` 只在**左侧是 null** 时右转。而 `DanmakuSearchDraft()` 的
     * 默认 `keyword = ''`（**空串，不是 null**，见本文件 :10）⇒
     * 挂载点 `player_page.dart:2131` 造的正是一个默认 draft ⇒
     * 左侧 '' 赢，右侧 `state.searchKeyword`（宿主已经算好的剧名，
     * 见 `player_page.dart:7934` 那段长注释）**永远拿不到**。
     * ⇒ 页面打开是空的。这就是 Owner 看到的现象。
     * ```
     *
     * # 修法：把"空"和"有内容"分开判，而不是靠 `??`
     * ```text
     * draft.keyword 非空  ⇒ 用它的（跨卸载恢复用户自己打的词，旧11 语义）
     * draft.keyword 为空  ⇒ 回退宿主的 `state.searchKeyword`（剧名预填）
     * 两者都为空          ⇒ 保持空（阴性对照：没有剧名时不许报错、不许填占位串）
     * ```
     *
     * # 为什么改判据而不是改默认值
     * ```text
     * 把 `DanmakuSearchDraft.keyword` 默认改成 null 也能过，但那要动
     * 一个**被两处宿主共用的模型**，且会让"用户主动清空输入框"这一态
     * 与"从没输入过"混在一起（清空后 draft.keyword == '' 又会去回退
     * 宿主剧名 ⇒ 用户清不掉）。在**消费点**判空是范围最小、语义最准的。
     * ```
     */
    final draft = widget.draft;
    final restored = draft?.keyword ?? '';
    _keyword.text =
        restored.isNotEmpty ? restored : widget.state.searchKeyword;
    _selected.addAll(draft?.selectedEpisodeIds ?? <int>{});
    _preview = draft?.previewing ?? false;
    if (_preview) _seedAssign();
    _keyword.addListener(_saveDraft);
  }
  void _saveDraft() {
    final draft = widget.draft;
    if (draft == null) return;
    draft.keyword = _keyword.text;
    draft.selectedEpisodeIds
      ..clear()
      ..addAll(_selected);
    draft.previewing = _preview;
  }
  @override
  void dispose() {
    _saveDraft();
    _keyword.removeListener(_saveDraft);
    _keyword.dispose();
    super.dispose();
  }
  @override
  void didUpdateWidget(covariant DanmakuSearchPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final available = widget.state.searchResults.map((m) => m.episodeId).toSet();
    _selected.removeWhere((id) => !available.contains(id));
    if (oldWidget.state.searchResults != widget.state.searchResults ||
        oldWidget.state.searchKeyword != widget.state.searchKeyword ||
        !listEquals(oldWidget.localTitles, widget.localTitles)) {
      _preview = false;
      _assign.clear();
      _order.clear();
    }
    if (!widget.state.searchLoading && !widget.biliState.loading &&
        (oldWidget.state.searchLoading || oldWidget.biliState.loading ||
            oldWidget.state.searchResults != widget.state.searchResults ||
            oldWidget.state.searchError != widget.state.searchError ||
            oldWidget.biliState.searchResults != widget.biliState.searchResults ||
            oldWidget.biliState.error != widget.biliState.error)) {
      _dispatching = false;
    }
    _saveDraft();
  }
  /// 候选行的标题：番剧名 · 第N集（解析不出集号就用原集名；都没有就说"无集名"）
  ///
  /// ⚠️ 集号**只能从 `episodeTitle` 解析** —— 这个结论来自
  /// `danmaku.dart` 的实测注释与真实响应夹具（`episodes[]` 只有
  /// `episodeId` / `episodeTitle` 两个键），**不是本次实网读数**
  /// （2026-10-26 两个公共实例都连不上，见 `.probe/item11-*.log`）。
  String _candidateTitle(DanmakuMatch m) {
    final no = episodeNumberFrom(m.episodeTitle);
    final work = m.animeTitle.trim();
    final epTitle = m.episodeTitle.trim();
    final ep = no != null
        ? '第$no集'
        : (epTitle.isNotEmpty ? epTitle : '无集名');
    return work.isEmpty ? ep : '$work · $ep';
  }

  /// 用计划给 `_assign` 播种（只在用户还没改过时；改过的不覆盖）
  void _seedAssign() {
    final plan = buildBatchBindPlan(
      localTitles: widget.localTitles,
      matches: _selected.isEmpty
          ? widget.state.searchResults
          : widget.state.searchResults
              .where((m) => _selected.contains(m.episodeId))
              .toList(),
    );
    for (final it in plan.items) {
      _assign.putIfAbsent(it.episodeId, () => it.episodeIndex);
    }
    if (_order.isEmpty) {
      _order = <int>[
        for (final it in plan.items)
          if (_assign[it.episodeId] == it.episodeIndex) it.episodeIndex,
      ];
    }
  }

  /// 用户确认后的映射（**顺序 = 拖动结果**）
  List<BatchBindPlanItem> _planItems() {
    final byLocal = <int, DanmakuMatch>{};
    for (final m in widget.state.searchResults) {
      final idx = _assign[m.episodeId];
      if (idx == null || idx < 0) continue;
      if (!_selected.contains(m.episodeId)) continue;
      byLocal[idx] = m;
    }
    final order = <int>[
      for (final i in _order)
        if (byLocal.containsKey(i)) i,
      for (final i in byLocal.keys)
        if (!_order.contains(i)) i,
    ];
    return <BatchBindPlanItem>[
      for (final i in order)
        BatchBindPlanItem(
          episodeIndex: i,
          episodeId: byLocal[i]!.episodeId,
          episodeTitle: byLocal[i]!.episodeTitle,
          shift: byLocal[i]!.shift,
          workTitle: byLocal[i]!.animeTitle,
        ),
    ];
  }

  Map<int, List<DanmakuMatch>> _assignmentConflicts() {
    final byLocal = <int, List<DanmakuMatch>>{};
    for (final match in widget.state.searchResults) {
      final index = _assign[match.episodeId];
      if (!_selected.contains(match.episodeId) || index == null ||
          index < 0 || index >= widget.localTitles.length) {
        continue;
      }
      byLocal.putIfAbsent(index, () => []).add(match);
    }
    byLocal.removeWhere((_, matches) => matches.length < 2);
    return byLocal;
  }

  /// 底部动作按钮的排布规范：**内容宽 + 左对齐**（与搜索按钮同一条）
  ///
  /// # 为什么抽成函数而不是两处各写一个 `Align`
  /// ```text
  /// 规范要"一处可读、一处可改"：同一条版式规则散在两处时，
  /// 下一轮只会改到其中一处（搜索按钮窄了、动作按钮还通栏 —— 这正是本轮返工的原因）。
  /// ```
  void _search() {
    final keyword = _keyword.text.trim();
    if (keyword.isEmpty || widget.state.searchLoading ||
        widget.biliState.loading || _dispatching) {
      return;
    }
    setState(() {
      _selected.clear();
      _assign.clear();
      _order.clear();
      _preview = false;
      _dispatching = true;
      _saveDraft();
    });
    widget.onSearch(keyword);
    widget.onBiliSearch(keyword);
  }

  Widget _queryBar() => Padding(
    key: const ValueKey('danmaku-search-group'),
    padding: const EdgeInsets.fromLTRB(Sp.x4, 0, Sp.x4, Sp.x3),
    child: Column(children: [
      Row(children: [
        Expanded(child: TextField(
          controller: _keyword,
          textInputAction: TextInputAction.search,
          onSubmitted: (_) => _search(),
          decoration: const InputDecoration(
            labelText: '剧名或关键词',
            isDense: true,
            border: OutlineInputBorder(),
          ),
        )),
        const SizedBox(width: Sp.x2),
        IconButton.filled(
          tooltip: '搜索 dan-api 与视频站',
          onPressed: widget.state.searchLoading || widget.biliState.loading ||
              _dispatching ? null : _search,
          icon: const Icon(Icons.search),
        ),
      ]),
      const SizedBox(height: Sp.x3),
      SizedBox(width: double.infinity, child: SegmentedButton<_SearchChannel>(
        segments: [
          const ButtonSegment(value: _SearchChannel.all, label: Text('全部')),
          ButtonSegment(value: _SearchChannel.danApi,
            label: Text('dan-api ${widget.state.searchResults.length}')),
          ButtonSegment(value: _SearchChannel.video,
            label: Text('视频 ${widget.biliState.searchResults.length}')),
        ],
        selected: {_channel},
        showSelectedIcon: false,
        onSelectionChanged: (value) => setState(() => _channel = value.first),
      )),
    ]),
  );

  void _confirmBinding() {
    final selected = widget.state.searchResults
        .where((match) => _selected.contains(match.episodeId)).toList();
    if (!_preview || widget.state.searchLoading || widget.state.searchStale ||
        _assignmentConflicts().isNotEmpty ||
        batchBindConflicts(selected).isNotEmpty) {
      return;
    }
    final items = _planItems();
    if (items.isEmpty) return;
    if (widget.onBatchBindPlan != null) {
      widget.onBatchBindPlan!(items, items.first.workTitle);
    } else {
      widget.onBatchBind(selected);
    }
  }

  /// 热路径失败的**归因块**（零网络）—— 第 05 项复核修复 B 的接线点
  ///
  /// # 为什么这里可以直接用 [DanmakuProbeReport.fromDanmakuException]
  /// ```text
  /// 它是**纯函数**：只读 `DanmakuException` 里已有的字段
  /// （`resolvedAddress` / `statusCode` / `body`），不构造 transport、
  /// 不调 DoH、不看代理。
  /// ⇒ 放在 build 里随帧重算是安全的（不产生任何 I/O），
  ///   也不会把"搜索失败"变成一次网络往返。
  /// ```
  ///
  /// # 为什么必须接（而不是只画 `error.toString()`）
  /// ```text
  /// `toString()` 是**服务端/异常原文**，它不含归因：
  ///   · 本机 DNS 被劫持   ⇒ 原文说"服务没起来" ⇒ 用户去查服务（方向错）
  ///   · 解析与真值一致     ⇒ 原文也说"服务没起来" ⇒ 用户可能去改 DNS（更错）
  /// ⇒ 归因由 `DanmakuProbeReport` 给（单一文案源，与设置页同一份）。
  /// ```
  Widget _hotPathFailure(DanmakuException e) {
    final r = DanmakuProbeReport.fromDanmakuException(e);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          r.failure.title,
          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
        Text(r.remedy, style: const TextStyle(fontSize: 12)),
        /*
         * ★ 原错误原因保留（归因是结论，原文是证据），凭据仅在展示时脱敏。
         * `test/zz_t1028_danmaku_search_page_test.dart:88` 用
         * `find.textContaining('dan-api 这一路超时') == findsOneWidget` 钉住
         * 「渠道失败原因必须透出」—— 那是第 11 项的验收原文。
         * ⇒ 这一行是它**唯一**的承载点（详情区那块同名文本在收起时是
         *   offstage，默认 finder 会跳过）。删了它会把别人的门禁弄红。
         */
        Text(PlaybackErrorText.forDisplay(e.toString()),
          style: const TextStyle(fontSize: 12)),
      ],
    );
  }
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final b = widget.biliState;
    final selected = s.searchResults.where((m) => _selected.contains(m.episodeId)).toList();
    final conflicts = batchBindConflicts(selected);
    final assignments = _assignmentConflicts();
    final items = _planItems();
    return AppDialogShell(
      title: (widget.workTitle == null || widget.workTitle!.trim().isEmpty)
          ? '搜索弹幕与绑定剧集'
          : '搜索弹幕 · ${widget.workTitle!.trim()}',
      fill: false,
      // Mapping rows need the shared wide-dialog size.
      width: 820,
      margin: const EdgeInsets.all(Sp.x4),
      scrollable: false,
      onClose: widget.onClose,
      footer: Padding(
        padding: const EdgeInsets.fromLTRB(Sp.x4, Sp.x2, Sp.x4, Sp.x3),
        child: Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (widget.onBack != null)
              IconButton(
                tooltip: '返回弹幕设置',
                onPressed: widget.onBack,
                icon: const Icon(Icons.arrow_back),
              ),
            Text('已选 ${selected.length} 集'),
            OutlinedButton(
              onPressed: selected.isEmpty || s.searchLoading || s.searchStale
                  ? null : () => setState(() {
                    _seedAssign();
                    _preview = true;
                    _channel = _SearchChannel.danApi;
                    _saveDraft();
                  }),
              child: const Text('预览批量绑定'),
            ),
            if (_preview)
              FilledButton(
                onPressed: conflicts.isNotEmpty || assignments.isNotEmpty ||
                    items.isEmpty || s.searchLoading || s.searchStale
                    ? null : _confirmBinding,
                child: const Text('确认并交由播放器绑定'),
              ),
          ],
        ),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
          _queryBar(),
          Expanded(child: SingleChildScrollView(
            key: const ValueKey('danmaku-search-results-scroll'),
            /*
             * ★★★ 2026-10-28（N4-3 #9）：**左右必须对称、内容要吃到边**
             *
             * 改前（真机截图 `.probe/n4-3-layout/n4-3-wide-results.png`）：条目文字从
             * x≈170 起（左缩进 ~200），右侧空 ~260 —— 一条结果被挤在中间偏左的一条窄带里，
             * 而**同一页的输入框/按钮却是通栏**⇒ 三块内容的左右边界各不相同。
             * 现在：整页统一 16 的水平内边距，条目行 `contentPadding: zero` 吃到边，
             * 于是"标题 / 输入组 / 条目行"三条边界对齐。
             */
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            /*
             * ★ 为什么是 `SingleChildScrollView + Column`，不是 `ListView`
             * ```text
             * `ListView(children:)` 仍是**懒构建**：视口 + cacheExtent 之外的子项
             * **根本不在元素树里**。本页有两处依赖"能 ensureVisible 到页面下半截"的
             * 既有门禁（诊断区的补救按钮、预览区的确认按钮），页面一长就会
             * `find` 到 0 个元素 —— 那不是产品缺陷，是"没构建所以不存在"。
             * 本页内容量是**有界**的（一次搜索的候选 + 诊断区），全部构建没有性能问题；
             * 换成 `SingleChildScrollView` 后"滚得到 = 构建得出"，门禁与技术栈同义。
             * ```
             */
            child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (s.searchLoading || b.loading) const LinearProgressIndicator(),
              /*
               * ★★★ 2026-10-28（N4-3 #11）：**过期态必须说出原因**
               *
               * # 改前是什么样（真机截图 `.probe/n4-3-layout/n4-3-wide-stale.png`）
               * ```text
               * `searchStale` 为真时，复选框 / 「绑定当前集」/ 批量按钮全部
               * `onPressed: null` ⇒ **整列变灰**，而页面上**没有一个字**说明为什么点不动。
               * 用户只能猜：没搜到？搜索中？还是坏了？
               * ```
               * # 为什么算缺陷而不算"观感"
               * ```text
               * 一个"点不动且不说原因"的界面把排障成本转嫁给用户；
               * 与"失败必须可读"那一族判据同源（见 `.agents/notes/implemented/bug-fix/`）。
               * ```
               * # 为什么放在加载条**下面**
               * ```text
               * 它解释的是"下面那份结果列表"的状态 ⇒ 必须紧邻那份列表；
               * 且与"搜索中"互斥（搜索中不显示过期）⇒ 不会抢同一个位置。
               * ```
               * # "换了集或换了源"是对 `searchStale` 语义的如实转述
               * （宿主在换集 / 换源 / 重新搜索时把旧结果置为过期）。
               */
              if (!s.searchLoading && !b.loading && s.searchStale && s.searchResults.isNotEmpty)
                Container(
                  margin: const EdgeInsets.only(top: 8, bottom: 4),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: const Color(0x55808080)),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(Icons.info_outline, size: 18),
                      SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '结果已过期：播放会话已变化，请重新搜索。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              /*
               * ★★★ 2026-10-28（N4-3 #8）：**分组标题要有层级差 + 分隔线**
               *
               * 改前：`dan-api 剧集` 是默认字号的裸 Text，紧贴第一条结果 ⇒
               *   6 条结果读成一片，标题看起来像"第 0 条"。
               * 现在：标题加粗 + 上留白，并且**下面一条 Divider** 把它与条目分开。
               * ⚠️ 文案逐字不变（既有门禁按 `dan-api` 匹配分区标题）。
               */
              if (_channel != _SearchChannel.video) ...[
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(
                  'dan-api 剧集',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
              const Divider(height: 12),
              /*
               * ★★★ 2026-10-25（第 05 项复核修复 B）：**热路径的三档归因真接线**
               *
               * # 改前（复核查到的缺陷）
               * ```text
               * 这里只画 `s.searchError.toString()` —— 也就是 DanmakuException
               * 的 message 原文（"连不上弹幕服务（地址不通或服务没起来）"）。
               * ⇒ 而 `DanmakuProbeReport.fromDanmakuException` 写好了归因逻辑，
               *   却**零生产调用点**；注释里指的 `_searchResultBody` 在 lib/ 里
               *   根本不存在 ⇒ "热路径三档文案"从来没接上。
               * ```
               * # 现在
               * ```text
               * 走 `_hotPathFailure`：判据仍来自 `fromDanmakuException`
               * （**纯函数、零网络**：只用 exception 里已有的 resolvedAddress，
               *   DoH 只留在"用户主动点测试连接"那条路）。
               * ⇒ 劫持/一致/无法比较三档在搜索页就能看见，并且都指向正确动作。
               * ```
               */
              if (s.searchError != null) _hotPathFailure(s.searchError!),
              /*
               * ★★★ 2026-10-28（N4-3 #10）：**空态要给出下一步**
               *
               * # 改前是什么样（`.probe/n4-3-layout/n4-3-wide-empty.png`）
               * ```text
               * 没搜过时，这一块只有一条**灰色禁用**的「预览批量绑定」按钮，
               * 再往下 400px 全空 ⇒ 用户看到的是"这里什么都没有"，
               * 而不是"接下来该做什么"。
               * ```
               * # 为什么与下面那条 `dan-api 未找到匹配剧集` 分成两句
               * ```text
               * 这条 = **还没搜**（该怎么做）；下面那条 = **搜过了但没匹配**（没找到）。
               * 合成一句会把没搜过的人推去怀疑源里到底有没有内容。
               * ```
               */
              if (!s.searchSearched && !s.searchLoading && s.searchResults.isEmpty)
                const Text(
                  '尚未搜索',
                  style: TextStyle(fontSize: 12),
                ),
              if (s.searchSearched && !s.searchLoading && s.searchResults.isEmpty)
                const Text('dan-api 未找到匹配剧集'),
              for (final match in s.searchResults)
                /*
                 * ★★★ 2026-10-28（N4-3 #5/#6/#7）：条目行的三处改动
                 *
                 * # 改前（真机截图 `.probe/n4-3-layout/n4-3-wide-results.png`）
                 * ```text
                 * [封面][绑定当前集]  作品甲·第1集  ………700px………  [☐]
                 * ```
                 * · 每条都钉一个「绑定当前集」按钮（6 条 = 6 个同样的按钮，扫读全是噪声）
                 * · 复选框在最右（x≈1200），与文字相距 700+px ⇒ 眼手分离
                 * · 「对应本地 不绑定 ▾」没有描边 ⇒ 看起来像纯文本，不知道能点
                 *
                 * # 现在
                 * ```text
                 * [☐] 作品甲·第1集                       [封面][⋯]
                 *     渠道：dan-api · 对应本地 [第2集 ▾]
                 * ```
                 * · 复选框 `controlAffinity: leading` ⇒ 勾选与条目同一视觉组（#6）
                 * · 单条绑定收进 `⋯` 菜单；批量入口仍在下面、未动（#5）
                 * · 「对应本地」的下拉套一层描边容器、触达高度 ≥32（#7）
                 *
                 * # 为什么仍用 `CheckboxListTile` 而不是自制 Row
                 * ```text
                 * 既有 6 份门禁按 `find.byType(CheckboxListTile)` 驱动"点条目即勾选"。
                 * 换成自制 Row 会把"整行可点"从框架能力变成手写手势，还得同步改 6 份锚点
                 * —— 收益为零、风险全是回归。`CheckboxListTile` 本来就支持
                 * `controlAffinity.leading` + `secondary`（secondary 落在勾选框的**反侧**）。
                 * ```
                 */
                CheckboxListTile(
                  key: ValueKey<int>(match.episodeId),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 4),
                  value: _selected.contains(match.episodeId),
                  // 2026-10-26（Owner：只返回数字没有名字）：
                  // 一律显示"番剧名 · 第N集"，不再出现裸 #123456。
                  title: Text(_candidateTitle(match)),
                  /*
                   * ★★★ 2026-10-28（N4-3 #9 续）：**副标题占满整行**，把中段那块空洞吃掉
                   *
                   * # 改前（Lead 复核点名）
                   * ```text
                   * 「渠道：dan-api · 对应本地」在 x≈76..530 就结束了，下拉被 `Spacer`
                   * 推到 x≈1067 —— 中间 ~500px 是纯空白。读者会以为"这一行断成两截"：
                   * **标签在左、它的控件在右**，中间没有任何东西把它们连起来。
                   * ```
                   *
                   * # 取舍：选「副标题吃满 + 右侧控件靠右不变」（不选"行内 chip"）
                   * ```text
                   * ① 行内 chip 要把「对应本地」下拉**推进条目行的中间带**：
                   *    800 宽窗口下它的落点正好压住行的几何中心（实测 x≈335..407，
                   *    中心 400）—— 而"点条目本身选中"就靠那条中心线，
                   *    结果是"点中间没选中、弹出了个下拉"。
                   *    两害相权：要么牺牲整行可点（真行为），要么把既有门禁的点击点
                   *    从"整行"改成"点勾选框"（= 放宽判据）。两条都不接受。
                   * ② 所以改成：**副标题自己铺一条满宽的极浅底纹带**，标签在带子左端、
                   *    下拉在带子右端 —— 视觉上它是一条**连续的带子**而不是"文字+空洞+控件"；
                   *    右侧的封面/`⋯` 位置一格没动（仍靠右）。
                   * ③ 这条带子**不接手势**（`Container` 不是可点控件）⇒ 中心线仍是纯装饰，
                   *    "点整行选中"与既有 6 份门禁全部保持原样。
                   * ```
                   */
                  subtitle: Container(
                    key: ValueKey<String>('danmaku-subtitle-band-${match.episodeId}'),
                    width: double.infinity,
                    margin: const EdgeInsets.only(top: 4),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Theme.of(context)
                          .colorScheme
                          .surfaceContainerHighest
                          .withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Row(children: <Widget>[
                      // ★ 保留**逐字**的 '渠道：dan-api'：既有门禁用 find.text 精确匹配它
                      const Expanded(child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('渠道：dan-api'),
                          Text('对应本地'),
                        ],
                      )),
                      /*
                       * 下拉仍在带子的右端（`Spacer` 把它推到尽头）——
                       * 但它现在**在带子里**：中间那段不再是"空白"，而是同一条底纹。
                       */
                      _LocalPick(
                        value: _assign[match.episodeId] ?? -1,
                        titles: widget.localTitles,
                        onChanged: s.searchLoading || s.searchStale
                            ? null
                            : (v) => setState(() {
                                  _assign[match.episodeId] = v ?? -1;
                                  _preview = false;
                                  _saveDraft();
                                }),
                      ),
                    ]),
                  ),

                  onChanged: s.searchLoading || s.searchStale ? null : (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(match.episodeId);
                      _seedAssign();
                    } else {
                      _selected.remove(match.episodeId);
                      /*
                       * 2026-10-26（第 11 项复核）：**取消勾选时清掉这一条的映射**。
                       * 不清的后果：下拉框还显示"上次选过的第5集" ⇒ 用户以为它还有效，
                       * 而这一条其实已不在勾选集合里。重新勾选时应当回到**默认映射**，
                       * 不是上次的脏值。
                       */
                      _assign.remove(match.episodeId);
                      _order = <int>[];
                    }
                    _preview = false;
                    _saveDraft();
                  }),
                  secondary: Row(mainAxisSize: MainAxisSize.min, children: [
                    SizedBox(width: 28, height: 42,
                      child: match.cover.isEmpty
                        ? const Icon(Icons.movie_outlined)
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: coverImage(context, url: match.cover, layoutWidth: 28, layoutHeight: 42,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) => const Icon(Icons.movie_outlined)),
                          )),
                    /*
                     * ★ N4-3 #5：单条「绑定当前集」收进这里。
                     * `enabled` 只影响**菜单项**（置灰但菜单仍可打开）——
                     * 用户点开能看到"这个动作现在不可用"，比"点了没反应"清楚。
                     * 菜单本身仍可展开：禁用态下把整个按钮置灰会让用户以为界面坏了。
                     */
                    PopupMenuButton<String>(
                      key: ValueKey<String>('danmaku-match-menu-${match.episodeId}'),
                      tooltip: '这条的更多操作',
                      onSelected: (_) {
                        if (s.searchLoading || s.searchStale) return;
                        widget.onPickMatch(match);
                      },
                      itemBuilder: (_) => <PopupMenuEntry<String>>[
                        PopupMenuItem<String>(
                          value: 'bind',
                          enabled: !(s.searchLoading || s.searchStale),
                          child: const Text('绑定当前集'),
                        ),
                      ],
                    ),
                  ]),
                ),
              /*
               * ★★★ 2026-10-28（N4-3 #2 续）：**底部动作区与搜索按钮同一套规范**
               *
               * # 为什么还要改（Lead 复核后点名的残留）
               * ```text
               * 搜索按钮已经收窄到内容宽，但"预览批量绑定 / 确认并交由播放器绑定"
               * 仍是**通栏**（同等宽 1200+）⇒ 同一页里两条"按钮"规范不一致：
               * 一条是"按内容"，另一条是"按版面"。用户会把通栏那条读成"这一页的主按钮"，
               * 而它其实只是结果区的一个步骤。
               * ```
               * # 规范（与搜索按钮同一条）
               * ```text
               * 按钮宽 = 内容宽，左对齐到内容左边线；**只有输入类控件**（输入框）才吃满。
               * 例外保持原样：结果行里的 `⋯` 菜单是图标按钮、冲突里的「选择 xxx」是文本链接。
               * ```
               * ⚠️ 只包一层 `Align`：**不动** `onPressed` 的禁用条件、不动按钮文案、
               *    不动它在列表里的位置（空态引导 #10 与诊断区的高度因此一格没变）。
               */
              if (_preview) ...[
                Text('将匹配 ${items.length} / ${widget.localTitles.length} 集；未匹配 ${widget.localTitles.length - items.length} 集'),
                for (final conflict in assignments.entries)
                  Text('本地第${conflict.key + 1}集有多个候选，请修改对应集数。',
                    style: TextStyle(color: Theme.of(context).colorScheme.error)),
                // 2026-10-26：预览行带名字，且**可拖动**（顺序 = 提交顺序）
                ReorderableListView(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  buildDefaultDragHandles: true,
                  onReorder: (from, to) => setState(() {
                    final items = _planItems();
                    if (to > from) to -= 1;
                    final moved = items.removeAt(from);
                    items.insert(to, moved);
                    _order = <int>[for (final it in items) it.episodeIndex];
                    _saveDraft();
                  }),
                  children: <Widget>[
                    for (var i = 0; i < _planItems().length; i++)
                      Text(_planItems()[i].displayName,
                          key: ValueKey<int>(_planItems()[i].episodeIndex)),
                  ],
                ),
                for (final conflict in conflicts.entries) ...[
                  Text('第${conflict.key}集有多个候选，请明确选择一个：'),
                  for (final candidate in conflict.value)
                    TextButton(onPressed: s.searchLoading || s.searchStale ? null : () => setState(() {
                      /*
                       * 2026-10-26（冲突解决的回归修复）：**选完必须把映射也定下来**。
                       * 只改 `_selected` 不改 `_assign` 的后果：`_planItems()` 里
                       * 这条候选没有目标集 ⇒ 计划为空 ⇒ 确认按钮一直禁用（用户
                       * 明明选完了却不能提交）—— 这是三条既有门禁抓到的真回归。
                       * 目标集按**集号**定：本地标题里集号等于该冲突号的集。
                       */
                      final no = conflict.key;
                      var local = widget.localTitles
                          .indexWhere((t) => episodeNumberFrom(t) == no);
                      if (local < 0 && no >= 1 && no <= widget.localTitles.length) {
                        local = no - 1;
                      }
                      _selected.removeAll(conflict.value.map((m) => m.episodeId));
                      _selected.add(candidate.episodeId);
                      for (final m in conflict.value) {
                        _assign.remove(m.episodeId);
                      }
                      if (local >= 0) _assign[candidate.episodeId] = local;
                      _order = <int>[];
                      _saveDraft();
                    }), child: Text('选择 ${candidate.label} (#${candidate.episodeId})')),
                ],
              ],
              ],
              if (_channel != _SearchChannel.danApi) ...[
              const Divider(),
              const Text('视频站视频与分P'),
              if (b.error != null)
                Text(PlaybackErrorText.forDisplay(b.error.toString())),
              for (final item in b.searchResults)
                /*
                 * ★★ 2026-10-27（R2-#7 Owner 实测）：**「搜索出来的视频站条目**
                 *    **没有封面」**（原话逐字留档在 `.probe/owner-review-r2-feedback.md`
                 *    与 `.probe/r2-bili-cover-rootcause.md` —— 本行**不写站名**：
                 *    `t98_no_site_names_test.dart` 的语义是"产品代码与用户可见文档里
                 *    不许出现具体站名"，而注释**改了不会坏** ⇒ 按该门禁自己的准入标准
                 *    （"只有真正负载、必须逐字保留的字符串才配豁免"）不该占豁免额度）。
                 *
                 * # 根因（取证，不是猜）
                 * ```text
                 * 改前这里是**光板 `ListTile`** —— 只有 title + bvid：
                 *     ListTile(title: Text(item.title), subtitle: Text(item.bvid), onTap: …)
                 * `BiliSearchItem.cover` **根本没人读**。
                 * ⇒ 数据层是好的：把**真** API 响应喂给产品自己的
                 *   `biliSearchItemFromJson` ⇒ **17/17 条都带非空 cover**。
                 * ⇒ 也不是防盗链：实测 8/8 个 `i*.hdslb.com` URL **不带任何
                 *   headers 全部 200**（与本仓 `bili_api.dart:98` 那句
                 *   「必须带 Referer」矛盾 —— 那句对**接口**成立，对**图床**不成立）。
                 * ⇒ 就是**本页漏画了这一格**（同页 dan-api 分支
                 *   `:331-343` **有**封面；`bili_import_dialog.dart:519`
                 *   **也有** ⇒ 本仓早就会画，只是这里没抄）。
                 * ```
                 * # 为什么样式照抄同页 dan-api 分支
                 * ```text
                 * 同一个页面里两块结果**必须同构**，否则用户会以为"bili 这一路是残缺的"。
                 * 但**长宽比不同**：dan-api 是番剧海报（28×42，2:3），
                 * bili 是视频（16:9）⇒ 用 64×36。尺寸跟内容形态走，不跟邻块硬对齐。
                 * ```
                 * # 三条硬要求（都是从既有代码抄的规矩，不是自创）
                 * ```text
                 * ① **必须给 `errorBuilder`** —— `bili_import_dialog.dart:533-537`
                 *    逐字记着：Flutter 的 Image 只在 `errorBuilder == null` 时才
                 *    上报错误（SDK image.dart:1233 的 reportErrors）⇒ 不给的话，
                 *    封面加载失败会在单测里变成一条**未捕获异常**，
                 *    而用户其实只想看到"这条没封面"。
                 * ② 必须包 `ClipRRect`（与两处既有画法一致）。
                 * ③ 无封面给**占位图标** —— 不给会"塌一块"（空白），
                 *    用户分不清"加载中"与"这条没有封面"。
                 * ```
                 * ⚠️ 本改动**不碰** `item.cover` 的取值：它仍是
                 *    `biliSearchItemFromJson` 里 `biliSearchCoverUrl(_str(j['pic']))`
                 *    的产物（含 `//` → `https:` 补全）。
                 */
                ListTile(
                  leading: SizedBox(
                    width: 64,
                    height: 36,
                    child: item.cover.isEmpty
                        ? const _BiliThumbPlaceholder()
                        : ClipRRect(
                            borderRadius: BorderRadius.circular(4),
                            child: coverImage(context, url: item.cover,
                              layoutWidth: 64, layoutHeight: 36,
                              fit: BoxFit.cover,
                              errorBuilder: (_, __, ___) =>
                                  const _BiliThumbPlaceholder()),
                          ),
                  ),
                  title: Text(item.title),
                  subtitle: Text(item.bvid),
                  onTap: b.loading || !item.usable
                      ? null
                      : () => widget.onBiliImport(item.bvid),
                ),
              for (final page in b.pages)
                ListTile(title: Text('P${page.page}'),
                  onTap: b.loading ? null : () => widget.onBiliSelectPage(page.page)),
              ],
              const Divider(),
              ExpansionTile(
                title: const Text('请求与服务端详情'),
                children: [
                  Text('请求状态：${s.loading ? "正在获取弹幕" : s.status.isEmpty ? "尚无请求状态" : s.status}'),
                  Text('搜索状态：${s.searchLoading ? "正在搜索" : s.searchSearched ? "搜索完成" : "尚未搜索"}'),
                  const Text('服务端返回详情'),
                  for (final error in [s.error, s.searchError])
                    if (error != null) ...[
                      /*
                       * ★ 修复 B 的第二处接线：取弹幕失败（`s.error`）与
                       *   搜索失败（`s.searchError`）都先给**归因**，再给原文。
                       *   顺序与设置页一致（结论在前、证据在后）。
                       */
                      /*
                       * ⚠️ 这里**故意只画原文**，不再插入归因块（2026-10-25 实测）：
                       *   诊断区里加一块（标题+建议+原文）会把下面两个动作按钮
                       *   （「改用本机外部弹幕」「重新获取弹幕」）的中心点从
                       *   y=560 推到 y≈645，而 800x600 窗口的底边是 600
                       *   ⇒ 按钮落到视口外、`hitTestable()` 为 0，
                       *     实测把 `zz_t1028_danmaku_regressions_test` 的
                       *     「凭证补救动作真实可达」弄红。
                       * ⇒ 归因放在**列表层**（搜索失败那处 `_hotPathFailure`），
                       *   诊断区仍是"原文证据"，不再挤占可点区域。
                       */
                      SelectableText(
                        PlaybackErrorText.forDisplay(error.toString())),
                      if (error.body.isNotEmpty)
                        SelectableText(PlaybackErrorText.forDisplay(error.body)),
                      if (error.statusCode == 401 || error.statusCode == 403)
                        // 补救动作位于本诊断区，不再引用旧设置弹窗的请求节或凭证入口。
                        Text('这是凭证问题。可行的几步（按代价从低到高）：'
                          '${widget.onOpenLocal != null ? "点「改用本机外部弹幕」（免签名）。" : ""}'
                          '${widget.onReload != null ? "再点「重新获取弹幕」。" : ""}'),
                    ],
                  if (b.error != null)
                    SelectableText(
                      PlaybackErrorText.forDisplay(b.error.toString())),
                  if (widget.onOpenLocal != null)
                    TextButton(onPressed: widget.onOpenLocal,
                      child: const Text('改用本机外部弹幕')),
                  TextButton(onPressed: () => widget.onBiliSearch(_keyword.text.trim()),
                    child: const Text('搜索外部视频源弹幕')),
                  if (widget.onReload != null)
                    TextButton(onPressed: s.loading ? null : widget.onReload,
                      child: const Text('重新获取弹幕')),
                ],
              ),
            ],
            ),
          )),
        ]),
    );
  }
}

/// 「对应本地 [第N集 ▾]」—— 带描边的可点下拉（N4-3 #7）
///
/// # 改前
/// ```text
/// 裸 `DropdownButton`（只有文字 + 一个细箭头）⇒ 截图里读起来像
/// 「渠道：dan-api · 对应本地 不绑定 ▾」这样一句**纯文本**，
/// 用户不知道"不绑定"三个字是可以点的。
/// ```
///
/// # 现在
/// ```text
/// 外面套一层 1px 描边 + `minHeight: 32` 的容器：
///   · 描边 = "这是一个控件"的通用视觉语言（与输入框同一套）
///   · 32 = 可用触达下限
/// 只在**不可用**时把描边与箭头降为 `outlineVariant`（而不是整块消失），
/// 这样过期态仍看得出"这里本来有个下拉，只是现在不能动"。
/// ```
class _LocalPick extends StatelessWidget {
  const _LocalPick({
    required this.value,
    required this.titles,
    required this.onChanged,
  });

  final int value;
  final List<String> titles;
  final ValueChanged<int?>? onChanged;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onChanged != null;
    // 值来自 `_assign`；本地集列表换了之后旧下标可能越界 ⇒ 回落到"不绑定"
    final safe = value >= titles.length ? -1 : value;
    return Container(
      key: const ValueKey<String>('danmaku-local-pick'),
      width: 100,
      constraints: const BoxConstraints(minHeight: 32),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: enabled ? scheme.outline : scheme.outlineVariant,
          width: 1,
        ),
      ),
      child: DropdownButton<int>(
        value: safe,
        isExpanded: true,
        isDense: true,
        underline: const SizedBox.shrink(),
        icon: Icon(
          Icons.arrow_drop_down,
          color: enabled ? scheme.onSurface : scheme.outline,
        ),
        items: <DropdownMenuItem<int>>[
          const DropdownMenuItem<int>(value: -1, child: Text('不绑定')),
          for (var i = 0; i < titles.length; i++)
            DropdownMenuItem<int>(value: i, child: Text('第${i + 1}集',
              maxLines: 1, overflow: TextOverflow.ellipsis)),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

/// 视频站搜索条目**没有封面**时的占位（16:9 格子里的一枚暗底图标）。
///
/// # 为什么不直接用裸 `Icon`
/// ```text
/// 同页 dan-api 分支用的是裸 `const Icon(Icons.movie_outlined)`（番剧海报位）。
/// 而这里要给**和封面同一块 16:9 格子**一个"这不是空白、是没图"的视觉：
///   裸 Icon 在 64×36 里会居中飘着，看起来像"加载失败"而不是"没有封面"。
///   ⇒ 给一块与封面同形的暗底 + 图标（与 `bili_import_dialog` 的
///     `_thumbPlaceholder` 同一意图；那边是黑 0.5 底 + 图标）。
/// ```
///
/// ★ 颜色**写死**（跟 `bili_import_dialog._thumbPlaceholder` 一样不跟随主题）：
///   它压在一块半透明黑底上、不属于主题化容器；改成 `onSurfaceVariant`
///   在浅色主题下会变成浅灰压黑底 ⇒ 图标消失（那边注释逐字记着这条，
///   对比度会掉到 2:1 以下）。
class _BiliThumbPlaceholder extends StatelessWidget {
  const _BiliThumbPlaceholder();

  @override
  Widget build(BuildContext context) => ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.5),
          child: const Center(
            child: Icon(
              Icons.movie_outlined,
              size: 16,
              color: Colors.white24,
            ),
          ),
        ),
      );
}
