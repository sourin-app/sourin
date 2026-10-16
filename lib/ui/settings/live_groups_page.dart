//  二级页：直播分组 —— Owner 第 12 条
//
// # 用户原话（逐字）
// > 然后支持一下自定义直播源拆分组
// > （就是自定义常用的然后切换分组 就可以不用看不想看的其他源了）
//
// # 为什么编辑入口在设置页而不是直播页（task-53 纪律）
//   task-53 用户否定的正是「配置长在内容页」。
//   ⇒ 直播页只保留筛选（纯视图）；建组 / 改组 / 删组收在本页。
//
// # 数据落点：UiPrefs.liveSourceGroupsKey（lib/core/ui_prefs.dart）

import 'package:material_ui/material_ui.dart';

import '../../core/ui_prefs.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

/// 直播分组设置页
///
/// 本页不读「本机有哪些直播源」—— 那要走 FFI，在无核心库的环境里必失败。
/// ⇒ 分组编辑用手输源 id 的方式，这样本页在任何环境下都能渲染与操作。
class LiveGroupsPage extends StatefulWidget {
  const LiveGroupsPage({super.key});

  @override
  State<LiveGroupsPage> createState() => _LiveGroupsPageState();
}
class _LiveGroupsPageState extends State<LiveGroupsPage> {
  late Map<String, List<String>> _groups;
  final TextEditingController _nameCtrl = TextEditingController();
  final Map<String, TextEditingController> _srcCtrl = {};
  String? _toast;

  @override
  void initState() {
    super.initState();
    _groups = UiPrefs.liveSourceGroups();
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    for (final c in _srcCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 落盘（本页是唯一写入口 —— 单一写入点，少一处漂移）
  void _save() {
    UiPrefs.setLiveSourceGroups(_groups);
    setState(() {});
  }

  void _flash(String msg) => setState(() => _toast = msg);

  void _addGroup() {
    final name = _nameCtrl.text.trim();
    if (name.isEmpty) {
      _flash('分组名不能为空');
      return;
    }
    if (_groups.containsKey(name)) {
      _flash('已经有叫「$name」的分组了');
      return;
    }
    _groups[name] = <String>[];
    _nameCtrl.clear();
    _save();
    _flash('已新建分组「$name」（还没放源，切到它会显示全部源）');
  }

  /// Lead 明确要求：删分组时里面的源回落到「全部」，不许消失
  ///
  /// 本实现天然满足：源列表从来不依赖分组而存在 —— 分组只是筛选器，
  /// 删掉筛选器 ⇒ 全部源照旧显示。所以这里只需删键，不需要搬运任何源。
  void _removeGroup(String name) {
    setState(() {
      _groups.remove(name);
      _srcCtrl.remove(name)?.dispose();
    });
    _save();
    _flash('已删除分组「$name」；里面的源已回到「全部源」');
  }

  void _addSource(String group) {
    final ctrl = _srcCtrl[group];
    final id = (ctrl?.text ?? '').trim();
    if (id.isEmpty) {
      _flash('源 id 不能为空');
      return;
    }
    final list = _groups[group] ?? <String>[];
    if (list.contains(id)) {
      _flash('「$group」里已经有 $id 了');
      return;
    }
    setState(() => _groups[group] = [...list, id]);
    ctrl?.clear();
    _save();
  }

  void _removeSource(String group, String id) {
    setState(() {
      final list = [...?_groups[group]]..remove(id);
      _groups[group] = list;
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return SettingsSubPage(
      title: '直播分组',
      subtitle: '把常用的直播源分成组，直播页可一键只看某一组',
      children: [
        SettingsBlock(
          title: '新建分组',
          children: [
            Text(
              '分好组之后，直播页右侧会出现一排分组按钮；'
              '点某一个就只显示该组里的源，不用在一长串源名里翻。',
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: Sp.x4),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _nameCtrl,
                    decoration: const InputDecoration(
                      labelText: '分组名（如「常看」）',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _addGroup(),
                  ),
                ),
                const SizedBox(width: Sp.x3),
                FilledButton(onPressed: _addGroup, child: const Text('新建')),
              ],
            ),
          ],
        ),
        const SizedBox(height: Sp.x5),
        SettingsBlock(
          title: '现有分组（${_groups.length}）',
          children: [
            if (_groups.isEmpty)
              Text(
                '还没有分组。上面新建一个，再把常用的源 id 放进去。',
                style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
              )
            else
              for (final name in _groups.keys.toList()) ...[
              _groupRow(name, colors),
              const SizedBox(height: Sp.x4),
            ],
          ],
        ),
        const SizedBox(height: Sp.x5),
        SettingsBlock(
          title: '关于「源 id」',
          children: [
            Text(
              '源 id 就是设置 → JS 插件里那张卡片标识的源（如 iptv）。'
              '这里手输而不用勾选，是因为读取本机源列表要走核心接口，'
              '在核心不可用的环境下会让整页打不开 —— 手输让本页永远可用。',
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
            ),
          ],
        ),
        if (_toast != null) ...[
          const SizedBox(height: Sp.x4),
          Text(_toast!, style: TextStyle(fontSize: FontSizes.sm, color: colors.primary)),
        ],
      ],
    );
  }

  Widget _groupRow(String name, ColorScheme colors) {
    final members = _groups[name] ?? const <String>[];
    final ctrl = _srcCtrl.putIfAbsent(name, TextEditingController.new);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: FontSizes.lg,
                  color: colors.onSurface,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton.icon(
              key: ValueKey('live-group-del-$name'),
              onPressed: () => _removeGroup(name),
              icon: const Icon(Icons.delete_outline, size: 18),
              label: const Text('删除分组'),
            ),
          ],
        ),
        if (members.isEmpty)
          Text(
            '（空组 —— 切到它会显示全部源，不会筛成空）',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          ),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            for (final id in members)
              Chip(
                key: ValueKey('live-group-src-$name-$id'),
                label: Text(id),
                onDeleted: () => _removeSource(name, id),
              ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: ValueKey('live-group-addsrc-$name'),
                controller: ctrl,
                decoration: const InputDecoration(
                  hintText: '加一个源 id，如 iptv',
                  isDense: true,
                ),
                onSubmitted: (_) => _addSource(name),
              ),
            ),
            const SizedBox(width: Sp.x3),
            OutlinedButton(
              key: ValueKey('live-group-addbtn-$name'),
              onPressed: () => _addSource(name),
              child: const Text('加入'),
            ),
          ],
        ),
      ],
    );
  }
}
