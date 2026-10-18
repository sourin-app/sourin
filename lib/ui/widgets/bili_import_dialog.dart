// ═══════════════════════════════════════════════════════════════════════
//  外部视频源弹幕导入面板（task-28）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个面板干什么
//
// 用户原话：「支持一下 外部视频源填入链接导入弹幕，并且自动绑定剧集和
// 自动更新弹幕」。
//
// 一个输入框（BV 号 / av 号 / 链接 / b23 短链都能吃）→ 一个「导入」
// 按钮 → 面板显示「绑到哪个视频、哪一集对哪一 P、有多少条弹幕」。
//
// # 形态为什么照抄 DanmakuSettingsDialog
//
// 它们在同一个页面里互为邻居（都挂在播放页的浮层里），用户不该为两个
// 面板学两套操作。所以：外壳走全仓统一的 AppDialogShell
// （app_dialog_shell.dart —— 遮罩 / 定位 / 标题栏 / 卡片几何都归它），
// 面板只留 _divider / _sectionTitle / _hint 这套内容级排版。
//
// # 这个文件是**纯 UI**
//
// 与 DanmakuSettingsDialog 同一条设计：状态由宿主传进来，动作以回调
// 形式回宿主。好处是面板能脱离播放页单测（不需要真的发网络请求）。
//
// 网络那一层在 lib/core/bili/bili_api.dart，绑定在 bili_bind.dart，
// 增量更新在 bili_auto_update.dart。
//
// # 禁止 package:flutter/material.dart
//
// 项目用拆包后的 material_ui（见 test/material_split_test.dart）。

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../core/bili/bili_api.dart';
import '../../core/bili/bili_auto_update.dart';
import '../../core/bili/bili_bind.dart';
import '../../core/danmaku.dart';
import '../tokens.dart';
// ★ 缩略图必须走这个 helper，不要自己起网络图 ——
//   test/t74_cover_image_test.dart 的 D3 会**不剥注释**地扫全 lib/，
//   断言网络图构造只许出现在 cover_image.dart 一处（连注释里都不许写）。
import 'cover_image.dart';
import 'app_dialog_section.dart';
import 'app_dialog_shell.dart';
import '../../design/icons/app_icons.dart';

/// 导入面板要展示的全部状态。
///
/// 与 DanmakuSettingsState 一样由宿主构造 —— 面板不自己读偏好，
/// 这样打开面板**没有副作用**。
class BiliImportState {
  const BiliImportState({
    this.input = '',
    this.loading = false,
    this.busyLabel = '',
    this.error,
    this.binding,
    this.info,
    this.pages = const <BiliPage>[],
    this.selectedPage = 0,
    this.result,
    this.episodeIndex = 0,
    this.episodeTitle = '',
    this.episodeCount = 0,
    this.autoUpdate = true,
    this.intervalMinutes = defaultIntervalMinutes,
    this.trace = const <BiliHttpTrace>[],
    this.comments = 0,
    this.searchResults = const <BiliSearchItem>[],
    this.searchKeyword = '',
  });

  /// 输入框里的原始文本。
  final String input;

  /// 正在发请求。
  final bool loading;

  /// 正在做什么（「正在拉视频信息…」）—— 给按钮上的转圈配一句人话。
  final String busyLabel;

  /// 上一次失败的原因（null = 没有）。
  final DanmakuException? error;

  /// 当前作品的绑定（null = 还没绑）。
  final BiliBinding? binding;

  /// 某视频站视频信息（绑上了才有）。
  final BiliVideoInfo? info;

  /// 可选的 P 列表（手动指定用）。
  final List<BiliPage> pages;

  /// 用户手动选中的 P（0 = 自动）。
  final int selectedPage;

  /// 最近一次更新的结果。
  final BiliUpdateResult? result;

  /// 当前在放第几集（0 基）。
  final int episodeIndex;

  /// 当前这一集的标题（展示用）。
  final String episodeTitle;

  /// 本地一共有多少集。
  final int episodeCount;

  /// 自动更新开关。
  final bool autoUpdate;

  /// 自动更新间隔（分钟）。
  final int intervalMinutes;

  /// 最近几次真实请求（「真实请求证据」区）。
  final List<BiliHttpTrace> trace;

  /// 当前这一集绑定的弹幕条数。
  final int comments;

  /// 「搜 某视频站视频」的结果（空 = 还没搜过）。
  ///
  /// 搜索**由宿主发**（面板是纯 UI，自己不碰网络，见文件头）——
  /// 面板只负责把结果显示出来、把点中的那条回传。
  final List<BiliSearchItem> searchResults;

  /// 上一次搜的关键词（用来决定结果区那句话怎么写）。
  final String searchKeyword;

  bool get bound => binding != null && !binding!.isEmpty;

  BiliImportState copyWith({
    String? input,
    bool? loading,
    String? busyLabel,
    DanmakuException? error,
    bool clearError = false,
    BiliBinding? binding,
    bool clearBinding = false,
    BiliVideoInfo? info,
    List<BiliPage>? pages,
    int? selectedPage,
    BiliUpdateResult? result,
    int? episodeIndex,
    String? episodeTitle,
    int? episodeCount,
    bool? autoUpdate,
    int? intervalMinutes,
    List<BiliHttpTrace>? trace,
    int? comments,
    List<BiliSearchItem>? searchResults,
    String? searchKeyword,
  }) {
    return BiliImportState(
      input: input ?? this.input,
      loading: loading ?? this.loading,
      busyLabel: busyLabel ?? this.busyLabel,
      error: clearError ? null : (error ?? this.error),
      binding: clearBinding ? null : (binding ?? this.binding),
      info: info ?? this.info,
      pages: pages ?? this.pages,
      selectedPage: selectedPage ?? this.selectedPage,
      result: result ?? this.result,
      episodeIndex: episodeIndex ?? this.episodeIndex,
      episodeTitle: episodeTitle ?? this.episodeTitle,
      episodeCount: episodeCount ?? this.episodeCount,
      autoUpdate: autoUpdate ?? this.autoUpdate,
      intervalMinutes: intervalMinutes ?? this.intervalMinutes,
      trace: trace ?? this.trace,
      comments: comments ?? this.comments,
      searchResults: searchResults ?? this.searchResults,
      searchKeyword: searchKeyword ?? this.searchKeyword,
    );
  }
}

/// 外部视频源弹幕导入面板。
class BiliImportDialog extends StatefulWidget {
  const BiliImportDialog({
    super.key,
    required this.state,
    required this.onImport,
    required this.onSelectPage,
    required this.onSetAutoUpdate,
    required this.onSetInterval,
    required this.onUpdateNow,
    required this.onUnbind,
    required this.onClose,
    this.onSearch,
    this.fill = true,
  });

  final BiliImportState state;

  /// 用户点了「导入」。宿主负责解析 + 拉取 + 落盘，然后回传新 state。
  final Future<void> Function(String input, int page) onImport;

  /// 用户在 P 列表里选了某一 P（0 = 自动按序对齐）。
  final ValueChanged<int> onSelectPage;

  final ValueChanged<bool> onSetAutoUpdate;
  final ValueChanged<int> onSetInterval;

  /// 立即重拉一次弹幕（无视缓存时效）。
  final Future<void> Function() onUpdateNow;

  /// 解除绑定。
  final VoidCallback onUnbind;

  final VoidCallback onClose;

  /// 「搜 某视频站视频」—— 宿主去发请求，结果通过 [BiliImportState.searchResults]
  /// 回传（与其它动作同一条分工：面板不碰网络）。
  ///
  /// 可空：老宿主不接这个回调时，「搜索」按钮**不显示**（而不是点了没反应）。
  final ValueChanged<String>? onSearch;

  /// 根节点是否由**本面板**写成 `Positioned.fill`（默认 true，= 既有行为）
  ///
  /// ★ 传 `false` 的唯一场景：宿主用 `SheetExitMotion` 包住本面板
  ///   （退场淡出）。那时面板的父链里多了 `Opacity` / `IgnorePointer`
  ///   （都产生 RenderObject）⇒ 面板**不能再**自己写 `Positioned`
  ///   —— 它只能做 `Stack` 的直接孩子，否则两个 ParentDataWidget 争同一个
  ///   StackParentData ⇒ 抛 `Incorrect use of ParentDataWidget`
  ///   （阻断级教训：`player_page.dart` 的 `_SheetScrim` 类文档）。
  ///   `fill: false` 时定位交给宿主（本面板的 `Center` 撑满有界约束 ⇒
  ///   与 `Positioned.fill` 几何等价）。
  final bool fill;

  @override
  State<BiliImportDialog> createState() => _BiliImportDialogState();
}

/// 搜索结果缩略图的显示尺寸（16:9）
const double _thumbWidth = 96;
const double _thumbHeight = 54;

class _BiliImportDialogState extends State<BiliImportDialog> {
  /// 本面板的**取色唯一入口** —— 全部走主题角色，不写死任何颜色。
  ///
  /// # ★ task-13（2026-10-16）：为什么必须有这个 getter
  ///
  /// 改前本文件有 **24 处** `Colors.white*` 写死白。本面板的底色是
  /// `colorScheme.surface`（**跟随主题**），所以浅色主题下：
  /// ```text
  /// 白字 压 白底  ⇒ 标题/正文/状态行全部隐形
  /// 白线 压 白底  ⇒ 输入框 hint、分隔线、卡片描边全部隐形
  /// ```
  /// ⇒ 现在统一从这里取色。映射（旧 → 新）：
  /// ```text
  /// Colors.white      → colors.onSurface
  /// Colors.white70    → colors.onSurfaceVariant
  /// Colors.white60    → colors.onSurfaceVariant   （并入 70 档）
  /// Colors.white38    → colors.onSurfaceVariant   （并入 70 档）
  /// Colors.white24    → colors.outlineVariant     （hint / 描边 / 分隔线）
  /// Colors.white10    → colors.onSurface.withValues(alpha: 0.04)（chip 未选中底）
  /// ```
  ///
  /// ⚠️ **保留写死色的三处**（理由逐条见各自调用点）：
  /// `Colors.black.withValues(alpha: 0.5)` ×2（等宽代码块底 —— 那块底是
  /// **本文件自己写死的黑**，里面的文字必须与主题解耦）、
  /// `Colors.lightBlueAccent`（选中态强调）、`Colors.orangeAccent`（错误/解绑）。
  ///
  /// ⚠️ 不用 `AppPalette.of(context)`：ColorScheme 由
  /// `theme_bridge.dart` 从 AppPalette 派生（onSurface←foreground、
  /// onSurfaceVariant←mutedForeground、outlineVariant←border），
  /// 走 ColorScheme 与全仓其它弹窗一致，且 `theme_regression_test` 的
  /// 对比度门禁盯的就是这几个角色。
  ColorScheme get _colors => Theme.of(context).colorScheme;
  late final TextEditingController _input = TextEditingController(
    text: widget.state.input,
  );

  /// 搜索框。⚠️ 独立于 [_input]（视频链接）——
  /// 两者语义不同，合并成一个框会让"我到底在搜还是在导"变得含糊。
  late final TextEditingController _searchInput = TextEditingController(
    text: widget.state.searchKeyword,
  );

  @override
  void dispose() {
    _input.dispose();
    _searchInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    /*
     * ★ task-104：根节点形态由 `fill` 决定（理由见 `fill` 字段的文档）
     *   fill = true （默认，= 改前行为）  Positioned.fill(...) → 只能直接挂在 Stack 下
     *   fill = false（SheetExitMotion 包着） 直接返回内容 → 定位交给宿主
     */
    /*
     * ★ 2026-10-16（Owner：「弹窗样式没统一」）
     *
     * 外壳改走全仓统一的 `AppDialogShell`（docs/AGENTS.md 第 3.5 节）。
     * 改前这里自己写了一整套 GestureDetector + ColoredBox(scrim) + Center +
     * SizedBox(560) + ConstrainedBox(620) + Material + 自写 `_header()`，
     * 与另外 6 个弹窗各写各的（宽度 560 / maxHeight 620 都是硬编码）。
     *
     * ⚠️ 本面板的内容是**一整条连续**的滚动体（输入 → 搜索 → 状态 → 分 P →
     *    自动更新 → 动作 → 真实请求 → 错误），没有需要钉死不滚的区块
     *    ⇒ 直接交给外壳的 `SingleChildScrollView`（`scrollable` 默认 true），
     *    本方法自己不再套一层。
     */
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _inputSection(),
        if (widget.onSearch != null) ...[
          const AppDialogSection.divider(),
          _searchSection(),
        ],
        const AppDialogSection.divider(),
        _statusSection(),
        if (s.pages.length > 1) ...[
          const AppDialogSection.divider(),
          _pageSection(),
        ],
        const AppDialogSection.divider(),
        _autoUpdateSection(),
        const AppDialogSection.divider(),
        _actionSection(),
        if (s.trace.isNotEmpty) ...[
          const AppDialogSection.divider(),
          _traceSection(),
        ],
        if (s.error != null) ...[
          const AppDialogSection.divider(),
          _errorSection(s.error!),
        ],
      ],
    );

    // ★ 外壳接管遮罩 / 定位 / 标题栏 / 卡片几何（标题栏由外壳的 _Header 画）；
    //   `fill: widget.fill` 必须**原样透传** —— 本面板的挂载点有两种形态
    //   （Stack 的直接孩子 = true；被 SheetExitMotion 包着 = false），
    //   语义逐字见 `fill` 字段的文档。
    final body = AppDialogShell(
      title: '外部视频源弹幕',
      onClose: widget.onClose,
      fill: widget.fill,
      child: content,
    );

    /*
     * ★ 默认形态与改前**逐像素相同**（fill 语义由外壳接管）。
     *
     * ⚠️⚠️ 这里**不能**再写 `Positioned.fill(child: body)` —— 实测直接抛
     *    `Incorrect use of ParentDataWidget`（两个 ParentDataWidget 争同一个
     *    StackParentData）：
     *
     *     _GestureSemantics -> RawGestureDetector -> GestureDetector
     *       -> Positioned -> AppDialogShell -> Positioned -> BiliImportDialog
     *       -> Stack
     *
     * 根因：外壳在 `fill: true` 时**自己**已经写了 `Positioned.fill`，而它的
     * 根节点就是 `GestureDetector`（StatelessWidget 不产生 RenderObject）
     * ⇒ 面板再套一层，两层 `Positioned` 会落到**同一个** RenderObject 上。
     * 这与 `player_page.dart` 的 `_SheetScrim` / `SheetExitMotion` 类文档记的
     * 是**同一个坑**（那里的结论同样是「面板自己不许再写 Positioned」）。
     * ⇒ 定位一律由外壳负责：`fill: true` 由它写 `Positioned.fill`，
     *   `fill: false` 时它只返回卡片、定位交给宿主的 `SheetExitMotion`。
     */
    return body;
  }

  /*
   * ★ task-13（2026-10-16）：这里的 `_divider()` 与 `_sectionTitle()` 已删除。
   *
   * 两段实现与另外两个弹窗**逐字相同**，已抽成共享件：
   * ```text
   * _sectionTitle  bili_import_dialog.dart:345（改前）
   *                danmaku_settings_dialog.dart:957
   *                player_settings_sheet.dart:806
   * _divider       bili_import_dialog.dart:340（改前）
   *                player_settings_sheet.dart:800
   * ```
   * ⇒ 现在统一走 `lib/ui/widgets/app_dialog_section.dart`：
   *   `AppDialogSection.title(...)` / `AppDialogSection.divider()`。
   *
   * ★ 顺带修掉的缺陷：这两个方法原来写死了 `Colors.white` /
   *   `Colors.white38` / `Colors.white24` —— 本面板的底色是
   *   `colorScheme.surface`（跟随主题），**浅色主题下白字白线直接隐形**。
   *   共享件按主题角色取色（onSurface / onSurfaceVariant / outlineVariant）。
   */


  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Text(
        text,
        // 说明文字：Colors.white38 → onSurfaceVariant（浅色下白 38% 压白底=隐形）
        style: TextStyle(color: _colors.onSurfaceVariant, fontSize: FontSizes.cap),
      ),
    );
  }

  // ── 输入区 ─────────────────────────────────────────────────────────

  Widget _inputSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppDialogSection.title('视频链接', note: 'BV 号 / av 号 / 完整链接 / b23.tv 短链都行'),
        TextField(
          controller: _input,
          enabled: !s.loading,
          style: TextStyle(
            fontFamily: 'monospace',
            fontSize: FontSizes.sm,
            color: _colors.onSurface,
          ),
          decoration: InputDecoration(
            hintText: 'https://www.bilibili.com/video/BV1GJ411x7h7',
            // 占位符：Colors.white24 → outlineVariant（浅色下白 24% 压白底=隐形）
            hintStyle: TextStyle(color: _colors.outlineVariant),
            border: const OutlineInputBorder(),
          ),
          onSubmitted: (v) => _submit(v),
        ),
        _hint('弹幕是免登录抓的，不需要外部站账号。'),
      ],
    );
  }

  void _submit(String v) {
    if (widget.state.loading) return;
    final t = v.trim();
    if (t.isEmpty) return;
    // 不 await：面板不阻塞，宿主通过 state.loading 回传进度。
    unawaited(widget.onImport(t, widget.state.selectedPage));
  }

  // ── 搜索区 ─────────────────────────────────────────────────────────

  /// 按关键词搜 某视频站视频，点一条直接绑定
  ///
  /// 为什么要有这一块：原来的面板只吃"链接"，用户得先去 某视频站自己搜、
  /// 复制链接、再回来粘贴。多一个搜索框就把这三步省掉了。
  ///
  /// 状态全部来自宿主（[BiliImportState.searchResults] / [searchKeyword]），
  /// 面板只负责显示 + 把点中的那条回传（[BiliImportDialog.onSearch] /
  /// [BiliImportDialog.onImport]）。
  Widget _searchSection() {
    final s = widget.state;
    final kw = s.searchKeyword;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppDialogSection.title('搜索视频', note: '按关键词找，点一条就绑定'),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _searchInput,
                enabled: !s.loading,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  color: _colors.onSurface,
                ),
                decoration: InputDecoration(
                  hintText: '片名 / 关键词',
                  hintStyle: TextStyle(color: _colors.outlineVariant),
                  border: const OutlineInputBorder(),
                ),
                onSubmitted: (v) => _searchSubmit(v),
              ),
            ),
            const SizedBox(width: Sp.x3),
            FilledButton.icon(
              onPressed: s.loading
                  ? null
                  : () => _searchSubmit(_searchInput.text),
              icon: const Icon(AppIcons.search, size: 18),
              label: const Text('搜索'),
            ),
          ],
        ),
        if (kw.isNotEmpty && s.searchResults.isEmpty && !s.loading)
          _hint('没搜到「$kw」相关的视频，换个关键词试试。'),
        if (s.searchResults.isNotEmpty) ...[
          const SizedBox(height: Sp.x3),
          for (final item in s.searchResults) _searchResultTile(item),
        ],
      ],
    );
  }

  void _searchSubmit(String v) {
    if (widget.state.loading) return;
    final t = v.trim();
    if (t.isEmpty) return;
    // 不 await：与 _submit 同一条分工 —— 面板不阻塞，宿主用 state.loading 回传进度
    unawaited(Future<void>.sync(() => widget.onSearch!(t)));
  }

  /// 一条搜索结果：缩略图 + 标题 + UP 主 + 时长
  ///
  /// 点整条 = 把它的 BV 号当输入喂给导入流程（宿主接
  /// [BiliImportDialog.onImport]），所以这里不需要额外的"绑定"按钮。
  Widget _searchResultTile(BiliSearchItem item) {
    return GestureDetector(
      // 透明区域也要能点（缩略图之间有空隙）
      behavior: HitTestBehavior.opaque,
      onTap: widget.state.loading ? null : () => _submit(item.bvid),
      child: Padding(
        padding: const EdgeInsets.only(bottom: Sp.x2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 封面：16:9 小图。coverImage 需要 MediaQuery 祖先（MaterialApp 自带）
            ClipRRect(
              borderRadius: Radii.rSm,
              child: SizedBox(
                width: _thumbWidth,
                height: _thumbHeight,
                child: item.cover.isEmpty
                    ? _thumbPlaceholder()
                    : coverImage(
                        context,
                        url: item.cover,
                        layoutWidth: _thumbWidth,
                        layoutHeight: _thumbHeight,
                        fit: BoxFit.cover,
                        // ★ errorBuilder 必须给：Flutter 的 Image 只在
                        //   errorBuilder == null 时才上报错误
                        //   （见 SDK image.dart:1233 的 reportErrors 参数）——
                        //   不给的话，封面加载失败会在单测里变成一条未捕获异常，
                        //   而用户其实只想看到"这条没封面"。
                        errorBuilder: (_, __, ___) => _thumbPlaceholder(),
                      ),
              ),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _colors.onSurface,
                      fontSize: FontSizes.sm,
                    ),
                  ),
                  const SizedBox(height: Sp.x1),
                  Text(
                    _searchMeta(item),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: _colors.onSurfaceVariant,
                      fontSize: FontSizes.cap,
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

  /// 没有封面 / 封面加载失败时的占位（深色块，与面板底色同系）
  ///
  /// ★ task-13：**故意不跟随主题** —— 这块底是下面那行写死的半透明黑
  ///   （它压在缩略图位、不属于主题化容器），里面的图标必须跟它配对。
  ///   若把图标改成 `_colors.onSurfaceVariant`，浅色主题下会变成
  ///   #60626B 压在黑底上 —— 对比度掉到 2:1 以下，图标消失。
  ///   ⇒ 保留固定白 + alpha（与 `Colors.black.withValues` 同族）。
  Widget _thumbPlaceholder() => ColoredBox(
    color: Colors.black.withValues(alpha: 0.5),
    child: const Center(
      child: Icon(
        AppIcons.movie_outlined,
        size: 18,
        color: Colors.white24,
      ),
    ),
  );

  /// 「UP 主 · 时长」—— 缺哪个就少写哪个，不留孤零零的分隔点
  String _searchMeta(BiliSearchItem item) {
    final parts = <String>[
      if (item.author.isNotEmpty) item.author,
      if (item.duration.isNotEmpty) item.duration,
    ];
    return parts.isEmpty ? item.bvid : parts.join(' · ');
  }

  // ── 状态区 ─────────────────────────────────────────────────────────

  Widget _statusSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppDialogSection.title('状态'),
        Row(
          children: [
            _dot(s.bound),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                _statusText(s),
                style: TextStyle(
                  color: _colors.onSurfaceVariant,
                  fontSize: FontSizes.sm,
                ),
              ),
            ),
          ],
        ),
        if (s.binding != null) ...[
          _hint('某视频站视频：${s.binding!.title}'),
          _hint(
            '本机第 ${s.episodeIndex + 1} 集 / 共 ${s.episodeCount} 集'
            '　→　某视频站 P${_pageOfCurrent(s)}（cid ${_cidOfCurrent(s)}）',
          ),
          if (s.comments > 0) _hint('这一集挂了 ${s.comments} 条弹幕'),
        ],
        if (s.result != null) _hint(s.result!.summary),
      ],
    );
  }

  int _pageOfCurrent(BiliImportState s) {
    final b = s.binding;
    if (b == null) return 0;
    final p = b.pageFor(s.episodeIndex);
    if (p > 0) return p;
    return b.episodes.isEmpty ? 0 : b.episodes.first.page;
  }

  int _cidOfCurrent(BiliImportState s) {
    final b = s.binding;
    if (b == null) return 0;
    final c = b.cidFor(s.episodeIndex);
    if (c > 0) return c;
    return b.episodes.isEmpty ? 0 : b.episodes.first.cid;
  }

  Widget _dot(bool on) {
    return Container(
      width: Sp.x2,
      height: Sp.x2,
      decoration: BoxDecoration(
        // ★ on（已绑定）**故意保留** Colors.lightBlueAccent：它是跨主题的
        //   「已连接」信号色，不是主题色（同族的还有下面 chip 的选中态）。
        //   关态白点则必须走主题 —— Colors.white24 在浅色底上是个白点。
        color: on ? Colors.lightBlueAccent : _colors.outlineVariant,
        shape: BoxShape.circle,
      ),
    );
  }

  String _statusText(BiliImportState s) {
    if (s.loading) {
      return s.busyLabel.isEmpty ? '正在取…' : s.busyLabel;
    }
    if (s.error != null) return '上次导入失败（下方有服务端原文）';
    if (!s.bound) return '还没绑定外部弹幕';
    if (s.autoUpdate) {
      return '已绑定 · 自动更新每 ${s.intervalMinutes} 分钟一次';
    }
    return '已绑定 · 自动更新已关';
  }

  // ── P 列表（只在多 P 时出现）───────────────────────────────────────

  Widget _pageSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppDialogSection.title('分 P 对齐', note: '默认按顺序一集对一 P'),
        Wrap(
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          children: [
            _pageChip(0, '自动'),
            for (final p in s.pages) _pageChip(p.page, 'P${p.page}'),
          ],
        ),
        _hint(
          '这个 某视频站视频有 ${s.pages.length} P。选「自动」时：'
          '多 P 按顺序对齐；只有 1 P 时所有集共用这一条时间轴。',
        ),
      ],
    );
  }

  Widget _pageChip(int page, String label) {
    final sel = widget.state.selectedPage == page;
    return GestureDetector(
      onTap: widget.state.loading ? null : () => widget.onSelectPage(page),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x1),
        decoration: BoxDecoration(
          // ★ 选中态**故意保留** Colors.lightBlueAccent（跨主题的强调色，
          //   与状态点同族）；未选中态则走主题 —— 改前 Colors.white10 的
          //   底 + Colors.white24 的描边在浅色主题下等于没有边界。
          color: sel
              ? Colors.lightBlueAccent.withValues(alpha: 0.22)
              : _colors.onSurface.withValues(alpha: 0.04),
          borderRadius: Radii.rSm,
          border: Border.all(
            color: sel ? Colors.lightBlueAccent : _colors.outlineVariant,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: sel ? Colors.lightBlueAccent : _colors.onSurfaceVariant,
            fontSize: FontSizes.cap,
          ),
        ),
      ),
    );
  }

  // ── 自动更新 ───────────────────────────────────────────────────────

  Widget _autoUpdateSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const AppDialogSection.title('自动更新'),
        /*
         * ★ 2026-10-15（Owner：「…换成 ui 框架提供的…不手写组件」）
         *
         * 改前是手写 Row：**开关在左、文字在右**，整行只有开关能点。
         * 换成 `SwitchListTile`：文字在左、开关在右、整行可点、
         * 带涟漪与读屏语义。文案与禁用逻辑（`s.loading`）逐字不变。
         */
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          value: s.autoUpdate,
          onChanged: s.loading ? null : widget.onSetAutoUpdate,
          title: Text(
            '重新进入这一集时自动比对增量',
            style: TextStyle(color: _colors.onSurfaceVariant, fontSize: FontSizes.sm),
          ),
        ),
        _slider(
          '间隔',
          s.intervalMinutes.toDouble(),
          5,
          240,
          s.loading ? null : (v) => widget.onSetInterval(v.round()),
          '${s.intervalMinutes} 分钟',
        ),
        _hint(
          '某视频站的弹幕接口没有「只取新增」的参数，每次都是全量返回；'
          '「增量」是在本机按弹幕 ID 求差集算出来的。',
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double>? onChanged,
    String readout,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 72,
          child: Text(
            label,
            style: TextStyle(
              color: _colors.onSurfaceVariant,
              fontSize: FontSizes.sm,
            ),
          ),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            onChanged: onChanged,
          ),
        ),
        SizedBox(
          width: 72,
          child: Text(
            readout,
            textAlign: TextAlign.right,
            style: TextStyle(
              // white60 并入 white70 档（同一语义：次要读数）
              color: _colors.onSurfaceVariant,
              fontSize: FontSizes.cap,
            ),
          ),
        ),
      ],
    );
  }

  // ── 动作区 ─────────────────────────────────────────────────────────

  Widget _actionSection() {
    final s = widget.state;
    return Row(
      children: [
        FilledButton.icon(
          onPressed: s.loading ? null : () => _submit(_input.text),
          icon: const Icon(AppIcons.download, size: 18),
          label: const Text('导入并绑定'),
        ),
        const SizedBox(width: Sp.x3),
        TextButton.icon(
          onPressed: s.loading || !s.bound
              ? null
              : () => unawaited(widget.onUpdateNow()),
          // ★ Colors.white → onSurface。这里**必须**显式给色：
          //   TextButton.icon 的 iconColor 不读 foregroundColor（见
          //   theme_bridge.dart 同款注释），不给就落到主题兜底色。
          icon: Icon(AppIcons.refresh, color: _colors.onSurface, size: 18),
          label: const Text('立即更新'),
        ),
        const Spacer(),
        if (s.loading)
          const SizedBox(
            width: 16,
            height: 16,
            // T27-07：无 color 的 CPI 走主题灰（#E5E5E5 on #14161C 仅 1.6:1），
            // 显式给白 #FAFAFA（对 #14161C ≈ 15.9:1）。
            child: CircularProgressIndicator(color: Color(0xFFFAFAFA), strokeWidth: 2),
          ),
        if (s.bound && !s.loading)
          TextButton(
            onPressed: widget.onUnbind,
            child: const Text(
              '解除绑定',
              style: TextStyle(color: Colors.orangeAccent),
            ),
          ),
      ],
    );
  }

  // ── 真实请求证据 ───────────────────────────────────────────────────

  Widget _traceSection() {
    final t = widget.state.trace;
    // 只显示最近 5 条，倒序（最新的在上）
    final recent = t.length <= 5
        ? t.reversed.toList()
        : t.sublist(t.length - 5).reversed.toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        AppDialogSection.title('真实请求', note: '共 ${t.length} 条，显示最近 ${recent.length} 条'),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Sp.x3),
          /*
           * ★ task-13：这一块**整块保留写死色**（底/描边/文字），不改主题色。
           *
           * 判据是「底色的来源」：它是**固定深色的代码块**（半透明黑压出来的
           * 等宽原文证据区），与主题无关 —— 就像播放器遮罩上的那种。
           *
           * 逐条反证（为什么三样都不能单独改主题色）：
           * ```text
           * 底 → onSurface@低alpha  深色下会从「明显更暗的凹陷」变成「更亮」
           *                         ⇒ 证据区在深色主题里消失（观感回归）
           * 描边 → outlineVariant   深色 #222222 压在黑块上 ≈ 看不见
           * 文字 → onSurfaceVariant 浅色 #60626B 压在黑块上 ≈ 1.6:1，更差
           * ```
           * ⇒ 三样是一个整体，要改只能整块改；而整块改会动深色主题的观感
           *   （超出「修浅色下隐形」的范围）⇒ 保留，已报 lead 裁决。
           */
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: Radii.rSm,
            border: Border.all(color: Colors.white24),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final e in recent)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x1),
                  child: Text(
                    e.line,
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: FontSizes.cap,
                      color: Colors.white70,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _errorSection(DanmakuException e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          e.message,
          style: const TextStyle(
            color: Colors.orangeAccent,
            fontSize: FontSizes.sm,
          ),
        ),
        const SizedBox(height: Sp.x2),
        // ★ task-13：与上面的「真实请求」同款 —— 固定深色代码块，整块保留
        //   写死色（底/描边/文字），理由逐条见 _traceSection 里的长注释。
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: Radii.rSm,
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            e.detail,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: FontSizes.cap,
              color: Colors.white70,
            ),
          ),
        ),
      ],
    );
  }
}
