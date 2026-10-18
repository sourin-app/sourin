//  二级页：直播分组 —— Owner 第 12 条 + 第 65 轮批次 D 重做
//
// # 用户原话（逐字）
// > 然后支持一下自定义直播源拆分组
// > （就是自定义常用的然后切换分组 就可以不用看不想看的其他源了）
//
// # ★★★ 第 65 轮 Owner 推翻了"按源分组"这个模型（逐字）
// > 我要的是自建分组可以选择直播源下的具体的直播的房间，而不是选择直播源
// > 这是错误的
//
// ⇒ 本页从"手输源 id"改成"**逐频道勾选**"。数据落点也从
//   `UiPrefs.liveSourceGroupsKey`（按源）迁到
//   `UiPrefs.liveChannelGroupsKey`（按频道）。
//
// # ★ 本页怎么拿到"本机有哪些频道"（这是本页最关键的一处设计）
//
// 老注释写的是：
// > 本页不读「本机有哪些直播源」—— 那要走 FFI，在无核心库的环境里必失败。
// > ⇒ 分组编辑用手输源 id 的方式，这样本页在任何环境下都能渲染与操作。
//
// ★ 那条约束**依然成立**（FFI 在 `flutter test` / 核心未就绪时必失败），
//   但结论不必是"只能手输" —— 因为**直播页已经有一份磁盘快照**：
// ```text
//   lib/ui/live_page.dart  →  DiskCache  'live-channels-cache.json'
//                                    ↑ 后端原始 JSON（provider/providerName/channels）
//   本页读它 ─────────────────────────┘ 纯 dart:io 读文件，**零 FFI**
// ```
// ⇒ 有快照 ⇒ 逐频道勾选（主路径）
// ⇒ 没快照（第一次装、还没进过直播页）⇒ 回落到手输源 id（老路径，永远可用）
//
// ★ 为什么不用"直接调 `SourinApi.getLiveChannels()`"：
//   那正是老注释说的那道墙 —— 核心没起来时它抛异常，整页就渲染不出来。
//   而读缓存文件失败只会返回 null（DiskCache 全程 try/catch）⇒ 页面照常。

import 'package:material_ui/material_ui.dart';

import '../../core/disk_cache.dart';
import '../../core/models.dart';
import '../../core/ui_prefs.dart';
import '../live_page.dart' show LiveFlatEntry, liveChannelMatchesQuery;
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';
import '../../design/icons/app_icons.dart';

/// 直播分组设置页
///
/// # 数据纪律（与直播页内的管理器**同一套**）
/// ```text
/// · 打开时读 prefs 进本地状态，改动立刻落盘（本页没有"取消"语义，
///   因为它是设置页的一个区块 —— 用户的心理模型是"改了就是改了"）
/// · 写 v2（按频道）+ 由 v2 推导的 v1（按源）—— 向前兼容
/// · 删组**不需要搬运频道**：分组只是筛选器，删掉 ⇒ 频道自动回到全部
/// ```
class LiveGroupsPage extends StatefulWidget {
  const LiveGroupsPage({super.key});

  @override
  State<LiveGroupsPage> createState() => _LiveGroupsPageState();
}

class _LiveGroupsPageState extends State<LiveGroupsPage> {
  /// 组名 → 频道引用（v2 主数据）
  late Map<String, List<LiveChannelRef>> _groups;

  /// 组名 → 源 id（v1 老数据，用于组名并集与回填）
  late Map<String, List<String>> _sourceGroups;

  /// 从磁盘快照读到的频道（null = 没有快照 ⇒ 回落到手输源 id）
  List<LiveFlatEntry>? _channels;

  /// 快照年龄（UI 上诚实标注"可能不是最新的"）
  DateTime? _cacheAt;

  final TextEditingController _nameCtrl = TextEditingController();
  final Map<String, TextEditingController> _srcCtrl = {};
  final Map<String, TextEditingController> _filterCtrl = {};
  String? _toast;

  /// ★★★ 2026-10-18（Owner 逐字）：正在改名的组（null = 没有在改名）
  ///
  /// ```text
  /// > 并且不能对已有的编辑
  /// ```
  /// 改前本页对已有分组**只有「删除分组」一个动作** —— 名字打错了、
  /// 想往里加台，都没有入口。现在补上「改名」。
  ///
  /// ★ 用"就地编辑"而不是弹窗：设置页是长列表，弹窗会遮住上下文，
  ///   用户改完还得确认一次；就地编辑改完回车即生效，少一次往返。
  String? _renaming;

  /// 改名输入框控制器（进入改名时填入原名）
  final TextEditingController _renameCtrl = TextEditingController();

  @override
  void initState() {
    super.initState();
    _groups = UiPrefs.liveChannelGroups();
    _sourceGroups = UiPrefs.liveSourceGroups();
    // ★ 首帧前把老格式回填进 v2 草稿（否则用户一保存就把老分组清空了）
    _backfillFromV1();
    unawaited(_loadChannels());
  }

  /// 从磁盘快照读频道清单（**零 FFI**，见文件头）
  Future<void> _loadChannels() async {
    try {
      final entry = await DiskCache.read('live-channels-cache.json');
      if (entry == null || !mounted) return;
      final data = entry.data;
      if (data is! List) return;
      final out = <LiveFlatEntry>[];
      for (final raw in data) {
        if (raw is! Map) continue;
        try {
          final g = LiveGroup.fromJson(Map<String, dynamic>.from(raw));
          for (final c in g.channels) {
            out.add((channel: c, tag: g.providerName, provider: g.provider));
          }
        } catch (_) {
          // 单组坏了只丢那组（与 UiPrefs 的逐键宽松同一条纪律）
        }
      }
      if (!mounted) return;
      setState(() {
        _channels = out.isEmpty ? null : out;
        _cacheAt = entry.at;
      });
      // ★ 拿到真频道清单后**再回填一次** —— 第一次回填时还没有频道清单，
      //   老格式（按源）的组会回填成空；现在能按源展开成具体频道了。
      if (out.isNotEmpty) _backfillFromV1();
    } catch (e) {
      debugLog('直播分组页读频道快照失败（回落到手输源 id）: $e');
    }
  }

  /// 把 v1（按源）里**只存在于老格式**的组展开成具体频道
  ///
  /// # 为什么必须做（否则保存即损坏用户数据）
  /// ```text
  /// 用户的老组是"这个组包含 iptv 这个源"（= iptv 的全部频道）。
  /// 若本页不把它展开成具体频道，用户点一下保存 ⇒ v2 里那个组是空的
  /// ⇒ 他下次进直播页选这个组 ⇒ 按 v2 判 ⇒ **一个台都不显示**。
  /// ```
  /// ★ 只回填**还没有 v2 数据**的组：已有 v2 的组以 v2 为准（不覆盖用户的编辑）。
  ///
  /// ★★ 两段式（缺了第二段就是"老分组凭空消失"）
  /// ```text
  /// ① 频道清单**还没到**（`_channels == null`）⇒ 先把**组名**建出来，
  ///    成员留空。否则用户在等快照的那一瞬间看到"现有分组（0）"
  ///    —— 他的老分组像是被删了。
  /// ② 清单到了 ⇒ 再按源展开成具体频道（`_loadChannels` 会再调一次）。
  /// ```
  void _backfillFromV1() {
    final chans = _channels;
    for (final e in _sourceGroups.entries) {
      final existing = _groups[e.key];
      if (existing != null && existing.isNotEmpty) continue;
      if (chans == null) {
        // ① 只建组名（成员待清单到达后再展开）
        _groups.putIfAbsent(e.key, () => <LiveChannelRef>[]);
        continue;
      }
      // ② 展开成具体频道
      _groups[e.key] = [
        for (final c in chans)
          if (e.value.contains(c.provider))
            LiveChannelRef(c.provider, c.channel.id),
      ];
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _renameCtrl.dispose();
    for (final c in _srcCtrl.values) {
      c.dispose();
    }
    for (final c in _filterCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// 落盘（本页是设置侧唯一写入口 —— 单一写入点，少一处漂移）
  ///
  /// # v1（按源）怎么算 —— 三条分支，缺一条就会丢用户数据
  /// ```text
  /// ① v2 里有频道         ⇒ 由 v2 反推源集合（真源：用户逐个勾过的）
  /// ② v2 空、但老 v1 有源 ⇒ **保留老 v1 原样**
  ///    ★ 这一条是「加源 / 删源」那条老路径的生命线：
  ///      没有频道清单时，用户只能手输源 id，那份数据**只在 v1 里**。
  ///      若这里用"v2 反推"覆盖它 ⇒ v2 空 ⇒ v1 也被清空 ⇒
  ///      **用户刚加的源当场消失**（实测抓到的真 bug）。
  /// ③ 都没有（新建的空组）    ⇒ 写空列表（组存在，只是还没内容）
  /// ```
  void _save() {
    UiPrefs.setLiveChannelGroups(_groups);
    final v1 = <String, List<String>>{};
    for (final e in _groups.entries) {
      final srcs = <String>[];
      for (final r in e.value) {
        if (!srcs.contains(r.provider)) srcs.add(r.provider);
      }
      if (srcs.isNotEmpty) {
        v1[e.key] = srcs;
      } else {
        // ② / ③：v2 空 ⇒ 老 v1 说了算（可能是手输的源，也可能是空组）
        v1[e.key] = List<String>.from(_sourceGroups[e.key] ?? const []);
      }
    }
    UiPrefs.setLiveSourceGroups(v1);
    _sourceGroups = v1;
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
    _groups[name] = <LiveChannelRef>[];
    _nameCtrl.clear();
    _save();
    _flash('已新建分组「$name」（还没选频道，切到它会显示全部频道）');
  }

  /// 删分组 —— 里面的频道回落到「全部」，不消失
  ///
  /// 本实现天然满足：频道列表从来不依赖分组而存在 —— 分组只是筛选器。
  void _removeGroup(String name) {
    setState(() {
      _groups.remove(name);
      _sourceGroups.remove(name);
      _srcCtrl.remove(name)?.dispose();
      _filterCtrl.remove(name)?.dispose();
      if (_renaming == name) _renaming = null;
    });
    _save();
    _flash('已删除分组「$name」；里面的频道已回到全部频道');
  }

  /// ★★★ 2026-10-18（Owner 逐字「不能对已有的编辑」）：开始改名
  void _startRename(String name) {
    setState(() {
      _renaming = name;
      _renameCtrl.text = name;
      _renameCtrl.selection = TextSelection(
        baseOffset: 0,
        extentOffset: name.length,
      );
    });
  }

  /// 提交改名（空 / 未变 ⇒ 静默退出；撞名 ⇒ 明确提示且**不改**）
  ///
  /// # 为什么要搬 `_filterCtrl` / `_srcCtrl`
  /// ```text
  /// 这两张表都是**以组名为键**的控制器缓存。只改 `_groups` 的键而不搬它们：
  ///   · 新名字那一行会 `putIfAbsent` 出一个新控制器 ⇒ 组内搜索词丢失（可接受）
  ///   · 老名字那个控制器永远留在表里 ⇒ dispose 漏掉（泄漏）
  /// ⇒ 一起搬，搬不动就删。
  /// ```
  void _commitRename(String oldName) {
    final n = _renameCtrl.text.trim();
    if (n.isEmpty || n == oldName) {
      setState(() => _renaming = null);
      return;
    }
    if (_groups.containsKey(n) || _sourceGroups.containsKey(n)) {
      _flash('已经有叫「$n」的分组了，换个名字');
      return;
    }
    setState(() {
      // 保序：Dart Map 默认保持插入顺序 ⇒ 改名不会让这一行跳位置
      final rebuilt = <String, List<LiveChannelRef>>{};
      for (final e in _groups.entries) {
        rebuilt[e.key == oldName ? n : e.key] = e.value;
      }
      _groups = rebuilt;

      final rebuiltSrc = <String, List<String>>{};
      for (final e in _sourceGroups.entries) {
        rebuiltSrc[e.key == oldName ? n : e.key] = e.value;
      }
      _sourceGroups = rebuiltSrc;

      // 控制器跟着搬（老键的必须 dispose，否则泄漏）
      final f = _filterCtrl.remove(oldName);
      if (f != null) {
        _filterCtrl[n] = f;
      }
      final s = _srcCtrl.remove(oldName);
      if (s != null) {
        _srcCtrl[n] = s;
      }
      _renaming = null;
    });
    _save();
    _flash('已改名为「$n」');
  }

  /// 勾选 / 取消一个频道
  void _toggleChannel(String group, LiveChannelRef ref) {
    setState(() {
      final list = _groups[group] ?? <LiveChannelRef>[];
      if (list.contains(ref)) {
        _groups[group] = list.where((x) => x != ref).toList();
      } else {
        _groups[group] = [...list, ref];
      }
    });
    _save();
  }

  /// 一键全选 / 全不选某个源（快捷方式）
  void _toggleProviderAll(String group, String provider) {
    final chans = _channels ?? const <LiveFlatEntry>[];
    final all = [
      for (final c in chans)
        if (c.provider == provider) LiveChannelRef(c.provider, c.channel.id),
    ];
    if (all.isEmpty) return;
    setState(() {
      final list = _groups[group] ?? <LiveChannelRef>[];
      if (all.every(list.contains)) {
        final drop = all.toSet();
        _groups[group] = list.where((x) => !drop.contains(x)).toList();
      } else {
        final have = list.toSet();
        _groups[group] = [
          ...list,
          for (final r in all)
            if (!have.contains(r)) r,
        ];
      }
    });
    _save();
  }

  // ── 老路径：手输源 id（没有磁盘快照时唯一可用的编辑方式）──

  void _addSource(String group) {
    final ctrl = _srcCtrl[group];
    final id = (ctrl?.text ?? '').trim();
    if (id.isEmpty) {
      _flash('源 id 不能为空');
      return;
    }
    final list = _sourceGroups[group] ?? <String>[];
    if (list.contains(id)) {
      _flash('「$group」里已经有 $id 了');
      return;
    }
    setState(() => _sourceGroups[group] = [...list, id]);
    ctrl?.clear();
    _save();
  }

  void _removeSource(String group, String id) {
    setState(() {
      final list = [...?_sourceGroups[group]]..remove(id);
      _sourceGroups[group] = list;
    });
    _save();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chans = _channels;
    return SettingsSubPage(
      title: '直播分组',
      subtitle: '把常看的直播频道分成组，直播页可一键只看某一组',
      children: [
        SettingsBlock(
          title: '新建分组',
          children: [
            Text(
              chans == null
                  ? '分好组之后，直播页工具栏可以一键只看某一组。'
                      '（还没读到频道清单 —— 先去直播页看一眼，本页就能逐频道勾选了）'
                  : '分好组之后，直播页工具栏可以一键只看某一组。'
                      '下面是本机直播源返回的全部频道，勾选你要的即可。',
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
                '还没有分组。上面新建一个，再勾选要放进来的频道。',
                style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
              )
            else
              for (final name in _groups.keys.toList()) ...[
                _groupRow(name, colors, chans),
                const SizedBox(height: Sp.x4),
              ],
          ],
        ),
        if (chans == null) ...[
          const SizedBox(height: Sp.x5),
          SettingsBlock(
            title: '关于「源 id」',
            children: [
              Text(
                '源 id 就是设置 → JS 插件里那张卡片标识的源（如 iptv）。'
                '这里手输而不用勾选，是因为还没读到频道清单'
                '（读它要核心接口，核心不可用时会让整页打不开）。'
                '先去直播页看一眼，回来这里就会变成逐频道勾选。',
                style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
              ),
            ],
          ),
        ],
        if (_cacheAt != null) ...[
          const SizedBox(height: Sp.x3),
          Text(
            '频道清单来自 ${_ageText(_cacheAt!)}的快照；'
            '在直播页刷新一次会更新它。',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          ),
        ],
        if (_toast != null) ...[
          const SizedBox(height: Sp.x4),
          Text(_toast!, style: TextStyle(fontSize: FontSizes.sm, color: colors.primary)),
        ],
      ],
    );
  }

  static String _ageText(DateTime at) {
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  Widget _groupRow(
    String name,
    ColorScheme colors,
    List<LiveFlatEntry>? chans,
  ) {
    final members = _groups[name] ?? const <LiveChannelRef>[];
    final renaming = _renaming == name;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            // ★ 改名时就地换成输入框（见 `_renaming` 的说明）
            if (renaming)
              Expanded(
                child: TextField(
                  key: ValueKey('live-group-rename-$name'),
                  controller: _renameCtrl,
                  autofocus: true,
                  decoration: const InputDecoration(
                    isDense: true,
                    hintText: '新的分组名',
                  ),
                  onSubmitted: (_) => _commitRename(name),
                ),
              )
            else
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
            if (chans != null)
              Text(
                '已选 ${members.length} 个频道',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            const SizedBox(width: Sp.x2),
            if (renaming) ...[
              TextButton(
                key: ValueKey('live-group-rename-ok-$name'),
                onPressed: () => _commitRename(name),
                child: const Text('保存名字'),
              ),
              TextButton(
                key: ValueKey('live-group-rename-cancel-$name'),
                onPressed: () => setState(() => _renaming = null),
                child: const Text('取消'),
              ),
            ] else
              TextButton.icon(
                key: ValueKey('live-group-rename-$name-btn'),
                onPressed: () => _startRename(name),
                icon: const Icon(AppIcons.edit_outlined, size: 18),
                label: const Text('改名'),
              ),
            TextButton.icon(
              key: ValueKey('live-group-del-$name'),
              onPressed: () => _removeGroup(name),
              icon: const Icon(AppIcons.delete_outline, size: 18),
              label: const Text('删除分组'),
            ),
          ],
        ),
        if (chans == null)
          _legacySourceEditor(name, colors)
        else
          _channelPicker(name, members, colors, chans),
      ],
    );
  }

  /// 主路径：逐频道勾选（有磁盘快照时）
  Widget _channelPicker(
    String name,
    List<LiveChannelRef> members,
    ColorScheme colors,
    List<LiveFlatEntry> chans,
  ) {
    final ctrl = _filterCtrl.putIfAbsent(name, TextEditingController.new);
    final q = ctrl.text.trim();
    // 按源分块（一个源 20~48 个台，平铺等于没有结构）
    final providers = <String, String>{}; // provider -> providerName
    for (final c in chans) {
      providers.putIfAbsent(c.provider, () => c.tag);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        /*
         * ★★★ 2026-10-18（Owner 逐字「不能对已有的编辑」）：**已选频道**独立成行
         *
         * # 为什么不能只靠下面的勾选胶囊
         * ```text
         * 一个源有 900+ 个台（真机快照：1178 个），已选的 3 个散落其中。
         * 想删掉其中一个 ⇒ 用户得先想起它在哪个源、再滚过去找 ——
         * 这在"编辑已有的分组"这个场景里等于不可用。
         * ⇒ 把已选项**集中列在顶部**，点 × 直接移除。
         * ```
         * ★ 与下面的胶囊是**同一个数据源**（`_toggleChannel`）——
         *   两处各写一套增删逻辑必然漂移。
         */
        if (members.isNotEmpty) ...[
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final r in members)
                InputChip(
                  key: ValueKey('live-group-picked-$name-${r.provider}-${r.channelId}'),
                  label: Text(
                    _nameOf(chans, r),
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.primary,
                    ),
                  ),
                  onDeleted: () => _toggleChannel(name, r),
                  deleteIcon: const Icon(AppIcons.close, size: 14),
                  deleteButtonTooltipMessage: '从这个分组里移除',
                  backgroundColor: colors.primary.withValues(alpha: 0.12),
                  side: BorderSide(color: colors.primary.withValues(alpha: 0.5)),
                  shape: const RoundedRectangleBorder(
                    borderRadius: Radii.rFull,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 5,
                  ),
                  labelPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ],
          ),
          const SizedBox(height: Sp.x3),
        ],
        if (members.isEmpty)
          Text(
            '（空组 —— 切到它会显示"这一组还没有频道"，不会把全部频道放进来）',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          ),
        TextField(
          key: ValueKey('live-group-filter-$name'),
          controller: ctrl,
          decoration: const InputDecoration(
            hintText: '搜频道名（如「体育」）',
            isDense: true,
            prefixIcon: Icon(AppIcons.search, size: 18),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: Sp.x3),
        for (final e in providers.entries)
          if (_visibleOf(chans, e.key, q).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: Sp.x3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        e.value,
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          fontWeight: FontWeight.w600,
                          color: colors.onSurface,
                        ),
                      ),
                      const SizedBox(width: Sp.x2),
                      Text(
                        '${_countSelected(chans, e.key, members)}'
                        '/${_visibleOf(chans, e.key, '').length}',
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: colors.onSurfaceVariant,
                        ),
                      ),
                      const Spacer(),
                      TextButton(
                        key: ValueKey('live-group-all-$name-${e.key}'),
                        onPressed: () => _toggleProviderAll(name, e.key),
                        child: const Text('全选 / 全不选'),
                      ),
                    ],
                  ),
                  Wrap(
                    spacing: Sp.x2,
                    runSpacing: Sp.x2,
                    children: [
                      for (final c in _visibleOf(chans, e.key, q))
                        _ChannelChip(
                          key: ValueKey(
                            'live-group-ch-$name-${c.provider}-${c.channel.id}',
                          ),
                          label: c.channel.name,
                          selected: members
                              .contains(LiveChannelRef(c.provider, c.channel.id)),
                          onTap: () => _toggleChannel(
                            name,
                            LiveChannelRef(c.provider, c.channel.id),
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
      ],
    );
  }

  static List<LiveFlatEntry> _visibleOf(
    List<LiveFlatEntry> chans,
    String provider,
    String q,
  ) =>
      [
        for (final c in chans)
          if (c.provider == provider)
            if (liveChannelMatchesQuery(q, c.channel.name, c.tag)) c,
      ];

  static int _countSelected(
    List<LiveFlatEntry> chans,
    String provider,
    List<LiveChannelRef> members,
  ) =>
      chans
          .where((c) =>
              c.provider == provider &&
              members.contains(LiveChannelRef(c.provider, c.channel.id)))
          .length;

  /// 已选频道的**显示名**（现取，不存进偏好 —— 见 `LiveChannelRef` 的注释）
  ///
  /// ⚠️ 快照里找不到（换了源 / 台改名 / 快照过期）⇒ 回落到 id 本身。
  ///   绝不返回空串 —— 用户会看到一颗没有字的胶囊，无从判断那是什么。
  static String _nameOf(List<LiveFlatEntry> chans, LiveChannelRef r) {
    for (final c in chans) {
      if (c.provider == r.provider && c.channel.id == r.channelId) {
        return c.channel.name;
      }
    }
    return r.channelId;
  }

  /// 老路径：手输源 id（没有磁盘快照时唯一可用）
  ///
  /// ⚠️ 保留它有三个理由，缺一不可：
  /// ```text
  /// ① 第一次装 / 还没进过直播页 ⇒ 没有快照 ⇒ 没有它就没法编辑
  /// ② `flutter test` 里 DiskCache 没 init ⇒ 同样没有快照
  ///    ⇒ 既有回归测试（t134 的 `live-group-addsrc-*` 那几条）靠它
  /// ③ 快照可能过期（用户刚装了新源）⇒ 手输是兜底
  /// ```
  ///
  /// ★★★ 这里显示的是 **v1（源 id）**，不是从 v2 反推
  /// ```text
  /// 这条路径下**根本没有频道清单** ⇒ v2 必然为空
  /// ⇒ 若从 v2 反推"这个组有哪些源"，结果**恒为空**
  ///   ⇒ 用户刚加的源不显示、也删不掉（实测抓到的真 bug）。
  /// ⇒ 直接读 v1，它才是这条路径的唯一真相。
  /// ```
  Widget _legacySourceEditor(String name, ColorScheme colors) {
    final ctrl = _srcCtrl.putIfAbsent(name, TextEditingController.new);
    final srcs = _sourceGroups[name] ?? const <String>[];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (srcs.isEmpty)
          Text(
            '（空组 —— 切到它会显示全部源，不会筛成空）',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          ),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            for (final id in srcs)
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

/// 逐频道勾选胶囊
///
/// ★ 与直播页内管理器的 `_MemberChip` **同一条教训**：
///   `showCheckmark: false` 会让每颗胶囊长得一模一样（深色主题下分不清
///   哪些已选）⇒ 必须留对勾 + 主色描边 + 主色淡底三重区分。
class _ChannelChip extends StatelessWidget {
  const _ChannelChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FilterChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: selected ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      showCheckmark: true,
      checkmarkColor: colors.primary,
      backgroundColor: Colors.transparent,
      selectedColor: colors.primary.withValues(alpha: 0.18),
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
      ),
      shape: const RoundedRectangleBorder(borderRadius: Radii.rFull),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      labelPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 轻量日志（本文件不直接依赖 AppLog 的落盘链路）
void debugLog(String msg) {
  // ignore: avoid_print
  print('[LIVE-GROUPS] $msg');
}

/// `unawaited` 的本地别名 —— 本文件只用一个 Future，不值得为它 import dart:async
void unawaited(Future<void> f) {
  f.catchError((Object _) {});
}
