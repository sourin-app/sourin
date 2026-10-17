/// 声明式源的可视化编排器 —— UI 层（**一屏分区卡片** + 实时 JSON 预览）
///
/// 数据模型见 [source_composer_model.dart]（本文件只做界面）。
///
/// # 2026-10-17（Owner 第 9 条）：为什么从「三步向导」改成「一屏」
/// ```text
/// Owner 原话：
/// > 点击编辑还是老样子的配置,没有可见的可视化编排,这里肯定也要用到modal,一起给换了
///
/// 改前是三步（站点 → 端点 → 字段映射），每步一屏，必须点「下一步」。
/// 问题不在「丑」，在**它逼用户按实现的顺序思考**：
///   · 想改一个 JSONPath，得先点两次「下一步」走过去
///   · 走到第 3 步时看不到第 1 步填了什么（想核对要退回去）
///   · 端点顺序决定了 JSON 里 endpoints 的键序，而三步表单里**根本排不了序**
/// ⇒ 全部摊在一屏：左栏分区卡片（可滚动），右栏常驻实时预览。
///
/// # 为什么是「左右两栏」而不是「上下堆叠」
/// ```text
/// 上下堆叠时，用户改上面的字段、预览在下面**看不见**（要滚动）。
/// 而本条的核心验收是「改字段 → 预览立即更新」——
/// 看不见的更新，等于没更新。
/// ⇒ 右栏必须**常驻可见**，所以用两栏。
/// ```
///
/// ⚠️ 窄屏（< 760dp）退化成**上下**：弹窗在 411dp 的手机上放两栏，
///    每栏都不到 200dp，输入框会被挤成一条缝 —— 那比向导更难用。
///    退化后预览仍在**同一屏**（不是另一步），只是位置在下方。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'app_dialog_section.dart';
import 'app_dialog_shell.dart';
import 'source_composer_model.dart';

/// 每个字段的示例 JSONPath —— **按字段给不同例子**，
/// 比全部填同一个 `$.data.vod_id` 更能说明「这一行该填什么」。
const Map<String, String> kComposerFieldHints = {
  'items': r'$.data.list',
  'id': r'$.data.vod_id',
  'title': r'$.data.vod_name',
  'cover': r'$.data.vod_pic',
  'subtitle': r'$.data.vod_remarks',
  'episodes': r'$.data.vod_play_url',
  'categories': r'$.data.class',
};


/// 从一份**声明式源 JSON** 还原成编排草稿（编辑入口用）
///
/// # 为什么放在本文件、而不是给 ComposerDraft 加 factory
/// ```text
/// source_composer_model.dart 是**纯数据**层，被单测与 rust 侧契约共同依赖。
/// 解析「用户磁盘上的那份 JSON」属于 **UI 适配**（要容忍缺字段、类型不对），
/// 放这里可以随手改，不动跨文件契约。
/// ```
///
/// # 容错原则：**缺什么就空着**，绝不抛
/// ```text
/// 磁盘上的 JSON 可能来自手写 / 旧版本 / 别的工具，字段不齐是常态。
/// 抛异常 ⇒ 编辑入口直接崩；空着 ⇒ 用户看到空框，自己补。
/// ⚠️ 但 id/name/base 必须**原样**带回来 —— 丢了它们，「保存」会变成
///    「新建一个空 id 的源」，那是破坏性的。
/// ```
ComposerDraft composerDraftFromJson(Map<String, Object?> j) {
  String str(Object? v) => v is String ? v : '';
  Map<String, String> strMap(Object? v) {
    if (v is! Map) return <String, String>{};
    return <String, String>{
      for (final e in v.entries)
        if (e.value is String) e.key.toString(): e.value as String,
    };
  }

  final draft = ComposerDraft(
    id: str(j['id']),
    name: str(j['name']),
    base: str(j['base']),
    headers: strMap(j['headers']),
  );

  final eps = j['endpoints'];
  if (eps is Map) {
    /*
     * ★ 按 JSON 里的**原始键序**重建 Map —— 这是「拖拽顺序」的持久化来源。
     *   若按 ComposerEndpoint.values 遍历，用户上次排的顺序就丢了。
     */
    final rebuilt = <ComposerEndpoint, ComposerEndpointDraft>{};
    for (final key in eps.keys) {
      final e = ComposerEndpoint.values.where((x) => x.key == key).firstOrNull;
      if (e == null) continue; // 认不出的键：跳过，不抛
      final v = eps[key];
      final m = v is Map ? v : const <String, Object?>{};
      rebuilt[e] = ComposerEndpointDraft(
        enabled: true,
        path: str(m['path']),
        params: strMap(m['params']),
        map: strMap(m['map']),
      );
    }
    // 补上 JSON 里没出现的端点（保持「能勾选」的能力）
    for (final e in ComposerEndpoint.values) {
      rebuilt.putIfAbsent(e, ComposerEndpointDraft.new);
    }
    draft.endpoints
      ..clear()
      ..addAll(rebuilt);
  }
  return draft;
}

/// 两栏布局的宽度阈值（dp）
///
/// # 这个数是怎么来的（算出来的，不是试出来的）
/// ```text
/// 弹窗 width 860 − 内容区左右 padding（Sp.x6 × 2 = 48）= 812 dp
/// 两栏 + 中间 Sp.x5(20) 间距 ⇒ 每栏 (812 − 20) / 2 = 396 dp
/// 左栏里「字段标签 132 + 输入框」⇒ 输入框还有 264 dp —— 够填一个 JSONPath。
/// 再窄：手机 411 dp − 48 = 363 dp，两栏各 171 dp ⇒ 输入框只剩 39 dp，**不可用**。
/// ⇒ 取 760：比 812 略小留余量，且明显高于任何手机宽度。
/// ```
const double kComposerTwoPaneMinWidth = 760;

/// 可视化编排弹窗
class SourceComposerDialog extends StatefulWidget {
  const SourceComposerDialog({
    super.key,
    this.initial,
    this.onSubmit,
    this.fill = true,
    this.submitLabel = '创建',
  });

  /// 编辑态初值（null = 新建）
  final ComposerDraft? initial;

  /// 用户点了提交 —— 交回编排结果（调用方负责落盘）
  final void Function(Map<String, Object?> json)? onSubmit;

  final bool fill;

  /// 主按钮文案（编辑态传「保存」，新建态用缺省「创建」）
  final String submitLabel;

  @override
  State<SourceComposerDialog> createState() => _SourceComposerDialogState();
}

class _SourceComposerDialogState extends State<SourceComposerDialog> {
  late final ComposerDraft _d = widget.initial ?? ComposerDraft();
  late final TextEditingController _id = TextEditingController(text: _d.id);
  late final TextEditingController _name = TextEditingController(text: _d.name);
  late final TextEditingController _base = TextEditingController(text: _d.base);

  /// 预览用的是**真** toJson（不是另写一套格式化）—— 保证编出来 == 手写
  String get _preview {
    const enc = JsonEncoder.withIndent('  ');
    return enc.convert(_d.toJson());
  }

  bool get _canSubmit =>
      _d.id.trim().isNotEmpty &&
      _d.name.trim().isNotEmpty &&
      _d.base.trim().isNotEmpty &&
      _d.enabled.any((e) => _d.endpoints[e]!.map.containsKey('items'));

  /// 端点的**显示顺序** —— 拖拽改这个列表，**同时重建 `_d.endpoints` 的插入序**
  ///
  /// # 为什么重建 Map 就够了（实测过，不是推断）
  /// ```text
  /// 写了条临时探针跑了一遍：
  ///   DEFAULT keys = [categories, list, detail, search]
  ///   REBUILT keys = [search, detail, list, categories]
  /// ⇒ Dart 的 Map 是 LinkedHashMap，**插入序即迭代序**，
  ///   而 toJson() 的 `for (final e in enabled)` 正是在迭代它。
  /// ⇒ 重建 Map 就足够，**不必**改 model 的跨文件契约（风险最小）。
  /// ```
  /// ⚠️ 但「UI 动了、数据没动」是这里最容易犯的错 —— 见 _reorder 的注释。
  List<ComposerEndpoint> _order = ComposerEndpoint.values.toList();

  @override
  void initState() {
    super.initState();
    /*
     * 编辑态：把初值里 Map 的**插入序**读出来（LinkedHashMap 保序）。
     * 新建态：保持枚举序。
     */
    _order = _d.endpoints.keys.toList();
  }

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _base.dispose();
    /*
     * ★ 2026-10-17（CodeRabbit CR）：`_mapCtls` 里的 controller **必须一起释放**。
     *
     * 它们按「端点 × 字段」懒建（见 `_mapCtl` 的 `putIfAbsent`），
     * 每次打开再关闭编排器都会遗留一批 —— 连同它们挂的 listener。
     * 长会话里反复开关会持续泄漏。
     */
    for (final c in _mapCtls.values) {
      c.dispose();
    }
    _mapCtls.clear();
    super.dispose();
  }

  void _sync() {
    _d.id = _id.text;
    _d.name = _name.text;
    _d.base = _base.text;
  }

  /// 拖拽结束后落定新顺序
  ///
  /// ⚠️ 这里**必须**真的改 `_order` 并 setState ——
  ///    只让 ReorderableListView 自己动，预览 JSON 的键序不会变，
  ///    那就是「假拖拽」（UI 动了、数据没动）。
  ///
  /// ⚠️ 用 `onReorderItem`（不是已弃用的 `onReorder`）：
  ///    旧 API 的 newIndex 是「移除前」的下标，要自己 `if (newIndex > oldIndex) newIndex -= 1`；
  ///    新 API **已经**替我们调整过，再减一次就会错位一格。
  void _reorder(int oldIndex, int newIndex) {
    setState(() {
      final e = _order.removeAt(oldIndex);
      _order.insert(newIndex, e);
      /*
       * ★★★ 关键的一步：把新顺序**写回 Map**。
       *
       * 只动 _order 就是「假拖拽」—— 界面上的行换了位置，
       * 但 _d.endpoints 的插入序没变 ⇒ toJson() 输出的键序照旧。
       * 用户拖了三下，保存出来的 JSON 一个字都没变。
       *
       * 做法：按新序**整体重建** Map 再换掉。
       * 不逐个 remove/insert 是因为那种写法的顺序语义很容易写错，
       * 而整体重建的结果是确定的。
       */
      final rebuilt = <ComposerEndpoint, ComposerEndpointDraft>{
        for (final x in _order) x: _d.endpoints[x]!,
      };
      _d.endpoints
        ..clear()
        ..addAll(rebuilt);
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppDialogShell(
      title: '可视化编排',
      subtitle: '左边改，右边实时看；不用下一步',
      icon: Icons.auto_fix_high_outlined,
      width: 860,
      fill: widget.fill,
      motion: true,
      onClose: () => Navigator.of(context).maybePop(),
      actions: Row(mainAxisSize: MainAxisSize.min, children: _actions(context)),
      child: LayoutBuilder(
        builder: (context, box) {
          final twoPane = box.maxWidth >= kComposerTwoPaneMinWidth;
          final editor = _editorPane(colors);
          final preview = _previewPane(colors);
          if (!twoPane) {
            /*
             * 窄屏：上下堆叠。⚠️ 仍是**同一屏**（不是另一步）——
             * 预览就在下方，滚动即可见，不需要点任何按钮。
             */
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [editor, const SizedBox(height: Sp.x5), preview],
            );
          }
          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: editor),
              const SizedBox(width: Sp.x5),
              Expanded(child: preview),
            ],
          );
        },
      ),
    );
  }

  List<Widget> _actions(BuildContext context) => [
        TextButton(
          onPressed: () => Navigator.of(context).maybePop(),
          child: const Text('取消'),
        ),
        const SizedBox(width: Sp.x2),
        FilledButton(
          onPressed: _canSubmit
              ? () {
                  _sync();
                  widget.onSubmit?.call(_d.toJson());
                }
              : null,
          child: Text(widget.submitLabel),
        ),
      ];
  // ═══════════════════════════════════════════════════════════════════
  //  左栏：分区卡片（站点 / 端点 / 字段映射）—— 全部在一屏内
  // ═══════════════════════════════════════════════════════════════════

  Widget _editorPane(ColorScheme colors) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _siteCard(colors),
          const SizedBox(height: Sp.x4),
          _endpointsCard(colors),
          const SizedBox(height: Sp.x4),
          _mappingCard(colors),
        ],
      );

  /// 分区卡片的统一外壳
  ///
  /// ⚠️ 底色/描边都**显式给**，不落主题兜底 —— 弹窗本身已有 surface 底，
  ///    再叠一层必须靠 alpha 区分，否则卡片和背景糊在一起看不出「分区」。
  ///
  /// ★★★ 为什么用 `Material` 而不是 `Container(decoration:)`
  /// ```text
  /// 第一版用的是 Container + BoxDecoration，测试直接抛断言：
  ///   ListTile background color or ink splashes may be invisible.
  ///   The ListTile is wrapped in a DecoratedBox that has a background color.
  /// ⇒ 卡片里放了 CheckboxListTile（端点行），而 ListTile 的底色/水波纹
  ///   是画在**最近的 Material 祖先**上的。中间隔一层带底色的 DecoratedBox，
  ///   那些效果就全被盖住 —— 用户点复选框时看不到任何反馈。
  /// ⇒ 用 Material 同时承担「底色」和「祖先」两个角色，一步解决。
  ///   （这比「保留 Container + 再套一层 Material」少一层 widget，也更不易写错。）
  /// ```
  Widget _card(ColorScheme colors, {required List<Widget> children}) => Material(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(Radii.md),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Sp.x4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(Radii.md),
            border: Border.all(color: colors.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      );

  Widget _siteCard(ColorScheme colors) => _card(
        colors,
        children: [
          const AppDialogSection.title('① 站点'),
          const SizedBox(height: Sp.x3),
          _field(colors, 'id', '唯一标识（英文，如 mysite）', _id, (v) => _d.id = v),
          const SizedBox(height: Sp.x3),
          _field(colors, 'name', '显示名（如 我的影视）', _name, (v) => _d.name = v),
          const SizedBox(height: Sp.x3),
          _field(colors, 'base', '接口地址（如 https://api.example.com）', _base, (v) => _d.base = v),
        ],
      );

  Widget _field(
    ColorScheme colors,
    String label,
    String hint,
    TextEditingController ctl,
    ValueChanged<String> onChanged,
  ) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
            ),
          ),
          Expanded(
            child: TextField(
              controller: ctl,
              /*
               * ★ 每次输入都 setState —— 右侧预览就是靠这个**立即**更新的。
               *   这一条是验收判据 3（改字段 → 预览立即更新，不点保存）。
               */
              onChanged: (v) => setState(() => onChanged(v)),
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
              ),
            ),
          ),
        ],
      );

  /// ② 端点卡片 —— 勾选 + **拖拽排序**
  ///
  /// # 为什么顺序有意义（不是装饰）
  /// ```text
  /// `endpoints` 在 JSON 里是个对象，键序本身不改变语义；
  /// 但它决定了**用户读这份配置时先看到哪个端点**，
  /// 也决定了「列表 → 详情 → 搜索」这种**取数链**的书写顺序。
  /// Owner 要的是「可见的编排」，顺序是编排最直观的表达。
  /// ```
  Widget _endpointsCard(ColorScheme colors) => _card(
        colors,
        children: [
          const AppDialogSection.title('② 端点', note: '勾上的才写进 JSON；可拖动排序'),
          const SizedBox(height: Sp.x2),
          /*
           * ⚠️ ReorderableListView 在 Column 里必须**给定高度**（它要无限长）。
           *    这里用 shrinkWrap + physics: NeverScrollable：
           *    条目数固定是 4 个，不会长到需要自己滚。
           *    外层（弹窗外壳）已经在滚，这里再滚会出现嵌套滚动 —— 鼠标滚轮
           *    停在卡片上时页面不动，用户会以为卡住了。
           */
          ReorderableListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            buildDefaultDragHandles: false,
            itemCount: _order.length,
            onReorderItem: _reorder,
            proxyDecorator: (child, index, animation) => Material(
              color: colors.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(Radii.sm),
              elevation: 4,
              child: child,
            ),
            itemBuilder: (context, i) {
              final e = _order[i];
              return _endpointRow(colors, e, i);
            },
          ),
        ],
      );

  Widget _endpointRow(ColorScheme colors, ComposerEndpoint e, int index) {
    final draft = _d.endpoints[e]!;
    return Padding(
      // ⚠️ key 必须挂在**每个 item 的根节点**上，ReorderableListView 靠它认条目
      key: ValueKey<String>('ep-${e.key}'),
      padding: const EdgeInsets.only(bottom: Sp.x1),
      child: Row(
        children: [
          /*
           * 拖拽手柄 —— 显式给色。
           * ⚠️ 不给色会落到 IconTheme 的兜底，在深色主题下几乎看不见，
           *    用户根本不知道这里能拖（等于拖拽功能对用户不存在）。
           */
          ReorderableDragStartListener(
            index: index,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: Sp.x2,
                  vertical: Sp.x2,
                ),
                child: Icon(
                  Icons.drag_indicator,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          Expanded(
            child: CheckboxListTile(
              value: draft.enabled,
              onChanged: (v) => setState(() => draft.enabled = v ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              secondary: Icon(e.icon, size: 18, color: colors.onSurfaceVariant),
              title: Text(
                e.label,
                style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// ③ 字段映射 —— 只列**已勾选**的端点
  Widget _mappingCard(ColorScheme colors) {
    // 按用户排好的顺序列，与 ② 卡片一致（不然左栏两个区块的顺序会互相矛盾）
    final on = _order.where((e) => _d.endpoints[e]!.enabled).toList();
    if (on.isEmpty) {
      return _card(
        colors,
        children: [
          const AppDialogSection.title('③ 字段映射'),
          const SizedBox(height: Sp.x2),
          Text(
            '还没勾任何端点 —— 在上面 ② 里勾一个，这里就会出现它的映射行。',
            style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
          ),
        ],
      );
    }
    return _card(
      colors,
      children: [
        const AppDialogSection.title('③ 字段映射', note: '每行填一个 JSONPath'),
        for (final e in on) ...[
          const SizedBox(height: Sp.x3),
          Row(
            children: [
              Icon(e.icon, size: 14, color: colors.onSurfaceVariant),
              const SizedBox(width: Sp.x1),
              Text(
                e.label,
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  fontWeight: FontWeights.semibold,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ),
          const SizedBox(height: Sp.x1),
          for (final f in kComposerFieldLabels.keys) _mapRow(colors, e, f),
        ],
      ],
    );
  }

  Widget _mapRow(ColorScheme colors, ComposerEndpoint e, String field) {
    final draft = _d.endpoints[e]!;
    final ctl = _mapCtl(e, field);
    final required = field == 'items';
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Row(
        children: [
          SizedBox(
            width: 132,
            child: Text(
              kComposerFieldLabels[field]!,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: required ? colors.onSurface : colors.onSurfaceVariant,
                fontWeight: required ? FontWeights.semibold : FontWeights.regular,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: ctl,
              // ★ 同 _field：setState 让右侧预览立即跟随（验收判据 3）
              onChanged: (v) => setState(() {
                if (v.trim().isEmpty) {
                  draft.map.remove(field);
                } else {
                  draft.map[field] = v.trim();
                }
              }),
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: FontSizes.cap,
                color: colors.onSurface,
              ),
              decoration: InputDecoration(
                hintText: kComposerFieldHints[field] ?? r'$.data.vod_id',
                hintStyle: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
              ),
            ),
          ),
        ],
      ),
    );
  }

  final Map<String, TextEditingController> _mapCtls = {};
  TextEditingController _mapCtl(ComposerEndpoint e, String field) {
    final k = '${e.key}:$field';
    return _mapCtls.putIfAbsent(
      k,
      () => TextEditingController(text: _d.endpoints[e]!.map[field] ?? ''),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  右栏：实时预览
  // ═══════════════════════════════════════════════════════════════════

  Widget _previewPane(ColorScheme colors) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          const AppDialogSection.title('实时预览', note: '改左边立刻变，不用保存'),
          const SizedBox(height: Sp.x2),
          Container(
            width: double.infinity,
            /*
             * ⚠️ 给一个**上限**而不是固定高度：内容少时不该撑出一大片空白，
             *    内容多时自己滚（外层已经在滚，这里用 maxHeight 让它不无限长）。
             */
            constraints: const BoxConstraints(maxHeight: 420),
            padding: const EdgeInsets.all(Sp.x3),
            decoration: BoxDecoration(
              // ★ 显式给底色，不落主题兜底（弹窗本身就是 surface，会糊在一起）
              color: colors.surfaceContainerHighest.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(Radii.sm),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: SingleChildScrollView(
              child: SelectableText(
                _preview,
                style: TextStyle(
                  fontFamily: 'monospace',
                  fontSize: FontSizes.cap,
                  color: colors.onSurface,
                  height: 1.5,
                ),
              ),
            ),
          ),
        ],
      );
}