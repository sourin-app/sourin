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
    required this.onBiliSelectPage, required this.onClose, this.draft,
    this.onReload, this.onOpenLocal});
  final DanmakuSettingsState state;
  final BiliImportState biliState;
  final List<String> localTitles;
  final ValueChanged<String> onSearch;
  final ValueChanged<String> onBiliSearch;
  final ValueChanged<DanmakuMatch> onPickMatch;
  final ValueChanged<List<DanmakuMatch>> onBatchBind;
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
  void _search() {
    final keyword = _keyword.text.trim();
    if (keyword.isEmpty) return;
    setState(() { _selected.clear(); _preview = false; _saveDraft(); });
    widget.onSearch(keyword);
    widget.onBiliSearch(keyword);
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
              if (s.searchError != null) Text(s.searchError.toString()),
              if (s.searchSearched && !s.searchLoading && s.searchResults.isEmpty)
                const Text('dan-api 未找到匹配剧集'),
              for (final match in s.searchResults)
                CheckboxListTile(
                  value: _selected.contains(match.episodeId),
                  title: Text(match.label),
                  subtitle: const Text('渠道：dan-api'),

                  onChanged: s.searchLoading || s.searchStale ? null : (checked) => setState(() {
                    if (checked == true) { _selected.add(match.episodeId); }
                    else { _selected.remove(match.episodeId); }
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
              OutlinedButton(onPressed: selected.isEmpty || s.searchLoading || s.searchStale ? null : () => setState(() { _preview = true; _saveDraft(); }),
                child: const Text('预览批量绑定')),
              if (_preview) ...[
                Text('将匹配 ${plan.items.length} / ${widget.localTitles.length} 集；未匹配 ${plan.unmatchedLocal.length} 集'),
                for (final item in plan.items) Text(item.toString()),
                for (final conflict in conflicts.entries) ...[
                  Text('第${conflict.key}集有多个候选，请明确选择一个：'),
                  for (final candidate in conflict.value)
                    TextButton(onPressed: s.searchLoading || s.searchStale ? null : () => setState(() {
                      _selected.removeAll(conflict.value.map((m) => m.episodeId));
                      _selected.add(candidate.episodeId);
                      _saveDraft();
                    }), child: Text('选择 ${candidate.label} (#${candidate.episodeId})')),
                ],
                FilledButton(onPressed: conflicts.isNotEmpty || plan.items.isEmpty || s.searchLoading || s.searchStale ? null : () {
                  setState(() { _preview = false; _saveDraft(); });
                  widget.onBatchBind(selected);
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
