import 'package:material_ui/material_ui.dart';
import '../core/danmaku.dart';
import '../core/batch_bind.dart';
import 'widgets/danmaku_settings_dialog.dart';
import 'widgets/bili_import_dialog.dart';
import 'widgets/cover_image.dart';

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
    this.onReload, this.onOpenLocal, this.workTitle});
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

class _DanmakuSearchPageState extends State<DanmakuSearchPage> {
  final _keyword = TextEditingController();
  final _selected = <int>{};
  bool _preview = false;

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
    if (oldWidget.state.searchResults != widget.state.searchResults) _preview = false;
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

  void _search() {
    final keyword = _keyword.text.trim();
    if (keyword.isEmpty) return;
    setState(() { _selected.clear(); _preview = false; _saveDraft(); });
    widget.onSearch(keyword);
    widget.onBiliSearch(keyword);
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
         * ★ 原文**必须留着**（归因是结论，原文是证据）。
         * `test/zz_t1028_danmaku_search_page_test.dart:88` 用
         * `find.textContaining('dan-api 这一路超时') == findsOneWidget` 钉住
         * 「渠道失败原因必须透出」—— 那是第 11 项的验收原文。
         * ⇒ 这一行是它**唯一**的承载点（详情区那块同名文本在收起时是
         *   offstage，默认 finder 会跳过）。删了它会把别人的门禁弄红。
         */
        Text(e.toString(), style: const TextStyle(fontSize: 12)),
      ],
    );
  }
  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    final b = widget.biliState;
    final selected = s.searchResults.where((m) => _selected.contains(m.episodeId)).toList();
    final conflicts = batchBindConflicts(selected);
    final plan = buildBatchBindPlan(localTitles: widget.localTitles, matches: selected);
    return Material(
      child: SafeArea(
        child: Column(children: [
          Row(children: [
            IconButton(onPressed: widget.onClose, icon: const Icon(Icons.close)),
            /*
             * ★★★ 2026-10-28（N4-3 #1）：**顶栏要有"我在给哪部剧搜"**
             *
             * 改前：只有 `搜索弹幕与绑定剧集`，右侧 800px 空白（真机截图）⇒ 用户无法核对。
             * 现在：宿主传了 `workTitle` 就并进标题；没传就还是原来那句
             *      （占位/无剧上下文时不该出现"搜索弹幕 · " 这种半截标题）。
             * ⚠️ 标题**只加信息、不改可点区**：关闭按钮与列表位置一格没动。
             */
            Expanded(
              child: Text(
                (widget.workTitle == null || widget.workTitle!.trim().isEmpty)
                    ? '搜索弹幕与绑定剧集'
                    : '搜索弹幕 · ${widget.workTitle!.trim()}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ]),
          Expanded(child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextField(controller: _keyword, onSubmitted: (_) => _search(),
                decoration: const InputDecoration(labelText: '跨渠道搜索关键词')),
              FilledButton(onPressed: s.searchLoading || b.loading ? null : _search,
                child: const Text('搜索 dan-api 与视频站')),
              const Text('搜索、启用、绑定与加载是不同状态；确认绑定前请核对剧集。'),
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
                          '结果已过期：搜索页开着期间换了集或换了源，'
                          '下面这些条目已不能再绑定。请重新点「搜索 dan-api 与视频站」。',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                ),
              const Text('dan-api 剧集'),
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
                  '还没有结果：输入剧名后点上面的按钮。',
                  style: TextStyle(fontSize: 12),
                ),
              if (s.searchSearched && !s.searchLoading && s.searchResults.isEmpty)
                const Text('dan-api 未找到匹配剧集'),
              for (final match in s.searchResults)
                CheckboxListTile(
                  value: _selected.contains(match.episodeId),
                  // 2026-10-26（Owner：只返回数字没有名字）：
                  // 一律显示"番剧名 · 第N集"，不再出现裸 #123456。
                  title: Text(_candidateTitle(match)),
                  subtitle: Row(children: <Widget>[
                    // ★ 保留**逐字**的 '渠道：dan-api'：既有门禁用 find.text 精确匹配它
                    const Text('渠道：dan-api'),
                    const Text(' · 对应本地'),
                    const SizedBox(width: 8),
                    DropdownButton<int>(
                      value: _assign[match.episodeId] ?? -1,
                      items: <DropdownMenuItem<int>>[
                        const DropdownMenuItem<int>(value: -1, child: Text('不绑定')),
                        for (var i = 0; i < widget.localTitles.length; i++)
                          DropdownMenuItem<int>(
                              value: i, child: Text('第${i + 1}集')),
                      ],
                      onChanged: s.searchLoading || s.searchStale
                          ? null
                          : (v) => setState(() {
                                _assign[match.episodeId] = v ?? -1;
                                _preview = false;
                                _saveDraft();
                              }),
                    ),
                  ]),

                  onChanged: s.searchLoading || s.searchStale ? null : (checked) => setState(() {
                    if (checked == true) {
                      _selected.add(match.episodeId);
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
                    TextButton(onPressed: s.searchLoading || s.searchStale ? null : () => widget.onPickMatch(match),
                      child: const Text('绑定当前集')),
                  ]),
                ),
              OutlinedButton(onPressed: selected.isEmpty || s.searchLoading || s.searchStale ? null : () => setState(() { _seedAssign(); _preview = true; _saveDraft(); }),
                child: const Text('预览批量绑定')),
              if (_preview) ...[
                Text('将匹配 ${plan.items.length} / ${widget.localTitles.length} 集；未匹配 ${plan.unmatchedLocal.length} 集'),
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
                FilledButton(onPressed: conflicts.isNotEmpty || _planItems().isEmpty || s.searchLoading || s.searchStale ? null : () {
                  setState(() { _preview = false; _saveDraft(); });
                  /*
                   * ★ 2026-10-26：这里曾有 `..sort((a,b) => a.episodeId.compareTo(...))` ——
                   *   那是**注入验证（④ 拖动顺序）时留下的残留**，它不是功能代码。
                   *   危害很直接：它把用户拖动出来的顺序重新按 episodeId 排回去 ⇒
                   *   门禁 ④「预览区改顺序 ⇒ 提交顺序跟着变」一直红，而其它三条绿。
                   *   ⇒ 提交必须**原样用 `_planItems()` 的顺序**（顺序 = 拖动结果）。
                   */
                  final items = _planItems();
                  if (widget.onBatchBindPlan != null) {
                    widget.onBatchBindPlan!(
                      items,
                      items.isEmpty ? '' : items.first.workTitle,
                    );
                  } else {
                    widget.onBatchBind(selected);
                  }
                }, child: const Text('确认并交由播放器绑定')),
              ],
              const Divider(),
              const Text('视频站视频与分P'),
              if (b.error != null) Text(b.error.toString()),
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
              const Text('视频站使用既有视频导入与分P绑定链路，不转换成 dan-api 剧集编号。'),
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
                      SelectableText(error.toString()),
                      if (error.body.isNotEmpty) SelectableText(error.body),
                      if (error.statusCode == 401 || error.statusCode == 403)
                        // 补救动作位于本诊断区，不再引用旧设置弹窗的请求节或凭证入口。
                        Text('这是凭证问题。可行的几步（按代价从低到高）：'
                          '${widget.onOpenLocal != null ? "点「改用本机外部弹幕」（免签名）。" : ""}'
                          '${widget.onReload != null ? "再点「重新获取弹幕」。" : ""}'),
                    ],
                  if (b.error != null) SelectableText(b.error.toString()),
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
          )),
        ]),
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
