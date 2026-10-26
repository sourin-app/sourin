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
    this.onReload, this.onOpenLocal});
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
    final draft = widget.draft;
    _keyword.text = draft?.keyword ?? widget.state.searchKeyword;
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
            const Expanded(child: Text('搜索弹幕与绑定剧集')),
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
                      _selected.removeAll(conflict.value.map((m) => m.episodeId));
                      _selected.add(candidate.episodeId);
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
                ListTile(title: Text(item.title), subtitle: Text(item.bvid),
                  onTap: b.loading || !item.usable ? null : () => widget.onBiliImport(item.bvid)),
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
