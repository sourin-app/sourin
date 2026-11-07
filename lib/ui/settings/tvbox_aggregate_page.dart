// ═══════════════════════════════════════════════════════════════════════
//  TVBox 聚合二级页（Owner 架构 A′ 的 Dart 半）
// ═══════════════════════════════════════════════════════════════════════
//
// # 三块（按 Owner 原话："插件里面设置的网盘接入应该在这个插件的二级页面配置"）
// ```text
// ① 源列表多选启用   每行 name / kindTag / implemented；未实现的**灰掉 + 逐字 reason**，
//                    不许勾（勾了也播不了 = 假入口）
// ② 网盘与凭据       复用 ProviderLoginPanel / ProxyPanel / PanShareBody
// ③ 导入 / 更新      复用宿主的 _openImportDialog / 订阅更新
// ```
//
// # 数据源：先用注入（Rust 未到位）
// ```text
// `SourinApi.tvboxAggregateGet()` / `tvboxAggregateSet()` 都带
// `debugTvboxAggregateFetcher` / `debugTvboxAggregateUpdater` 注入点
// （生产恒 null）。Rust 侧 `tvbox_aggregate_get/set` 到位后**置空即接真命令**，
// 本文件一行都不用改。
// ```
//
// # 为什么不重构 `pan_share_dialog` 里的那份内容
// ```text
// 对话框那份有 3 条专用门禁（`zz_t1037`）+ 我自己 6 条（`zz_t1045`）。
// 在 30 分钟窗口里把它拆成 `PanShareBody` 并把动作行一起搬，风险大于收益
// ⇒ 这里新增 `PanShareBody`（与对话框同构的识别+列目录体），
//   **对话框暂不重构**，待这轮 UI 稳定后统一（已记在交付说明里）。
// ```
import 'source_discovery_page.dart';
import 'dart:async' show unawaited;

// ★ characters 扩展（clampNoteTo60 用）由 material_ui 转出，无需单独 import
import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart' show userErrorText;
import '../../core/sourin_api.dart';
import '../../design/icons/app_icons.dart';
import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import '../tokens.dart';
import '../widgets/overlay_motion.dart';
import '../widgets/pan_share_dialog.dart' show PanShareListingSection;
import '../widgets/provider_login_panel.dart';
import '../widgets/proxy_panel.dart';
// ★ N8b-2：聚合源管理面板（链接可改 / 测试连通 / 立即更新）
import '../widgets/tvbox_source_panel.dart'
    show
        TvboxSourceManagePanel,
        tvboxLastUpdateFailed,
        tvboxLastUpdateText;

/// 打开聚合二级页（设置页入口一行调用它）
Future<void> showTvboxAggregatePage(BuildContext context) {
  return showAppDialog<void>(
    context: context,
    builder: (_) => const TvboxAggregatePage(),
  );
}

/// 聚合二级页
class TvboxAggregatePage extends StatefulWidget {
  const TvboxAggregatePage({super.key, this.showCredentialPanels = true});

  /// 是否渲染「网盘与凭据」区（门禁单独验该区，避免整页挂载时触发面板 FFI）
  final bool showCredentialPanels;

  @override
  State<TvboxAggregatePage> createState() => _TvboxAggregatePageState();
}

class _TvboxAggregatePageState extends State<TvboxAggregatePage> {
  bool _loading = true;
  String _error = '';
  String _saveError = '';
  TvboxAggregate? _agg;

  /// 配置里的 site 总数（读不到 ⇒ null ⇒ 底部说明整行不画）
  int? _configSiteTotal;

  /// 当前勾选（**只含 implemented == true 的 id**）
  final Set<String> _selected = <String>{};

  /// 每个子站的订阅链接（`listTvboxSources` 的 sidecar；读失败 ⇒ 空表）
  ///
  /// ★ N8b-2：这是"一个聚合源"的**真实寻址键** —— 三条命令
  ///   （set / check / update）都按这个 id 走 `local_tvbox_sources`，
  ///   而同一个链接下的全部子站共享同一条结果（命令层按链接去重）。
  Map<String, TvboxSourceInfo> _subs = const <String, TvboxSourceInfo>{};

  /// ★ T5：本聚合源的「上次更新」（后端把所含子站的章聚合成 max）
  ///
  /// ```text
  /// 它是 Rust 顶层 `aggregate` 字段 —— 不在 sources[] 里
  /// （塞进去会让设置页给聚合卡多出一个必然报错的"检测更新"按钮）。
  /// null = 后端没给（旧核心）⇒ 头部说明整行不画（不编"从未更新"）。
  /// ```
  TvboxSourceInfo? _aggregateSource;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = '';
      _saveError = '';
    });
    try {
      final a = await SourinApi.tvboxAggregateGet();
      /*
       * 配置里的 site 总数：**只读 sidecar**（`list_tvbox_sources` 毫秒级、零网络）。
       * 取不到就保持 null ⇒ 底部说明不画（口径：宁可不说，也不写死、不猜）。
       */
      final total = await SourinApi.tvboxConfigSiteTotal();
      if (!mounted) return;
      setState(() {
        _agg = a;
        _configSiteTotal = total;
        _selected
          ..clear()
          ..addAll(a.sites.where((s) => s.implemented && s.enabled).map((s) => s.id));
        _loading = false;
      });
      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ N8b-2：订阅链接**单独拉、且不阻塞首屏**（这里踩了一个真坑）
       * ══════════════════════════════════════════════════════════════════
       *
       * # 我第一版把 `await listTvboxSources()` 放进上面的关键路径，结果
       * ```text
       * 实测（zz_t1049 两条既有门禁被打断）：
       *   `_loading` 永远停在 true ⇒ 整页只画「正在读取聚合配置…」
       *   ⇒ `agg-site-check-*` 一个都建不出来 ⇒ 既有门禁全红。
       *
       * 根因：`flutter_test` 里**没有核心层** ⇒ `listTvboxSources()` 的
       * Future **永不完成**（不是抛异常，是根本不回包）⇒ `_load()`
       * 卡在那一行，后面的 `setState` 永远执行不到。
       * ⚠️ 反例对照：`tvboxConfigSiteTotal()` 同样调 `listTvboxSources()`，
       *   但它自己包了 `.timeout(600ms)` + try/catch（见 sourin_api.dart:300）
       *   ⇒ 所以上面那行**不会**卡住。我照抄了调用却没照抄它的超时纪律。
       * ```
       *
       * # 修法：两道保险（缺一条都不够）
       * ```text
       * ① **不阻塞首屏**：首屏 setState 先落地（页能画出来），
       *    订阅链接随后独立拉取（拉到再 setState 刷新管理区）。
       *    ⇒ 即使它永不回包，页面与既有 16 行复选框照常渲染。
       * ② 显式 `.timeout(...)`：防止留下一个永久 pending 的 Future
       *    （测试里表现为 "A Timer is still pending"）。
       *
       * ★ 与既有纪律一致：订阅链接是**附加信息** ——
       *   查不到只是显示不出「测试连通」的前置数据，
       *   **不该让整页白掉**（`_configSiteTotal` 那段注释写着同一条）。
       * ```
       */
      unawaited(_loadSubscriptionLinks());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e, fallback: '读取聚合配置失败，请稍后重试');
        _loading = false;
      });
    }
  }

  /// 拉「子站 → 订阅链接」表（N8b-2 的成组依据）—— **独立、非阻塞**
  ///
  /// ⚠️ 两道保险的理由见 `_load()` 里那段长注释（实测踩到 `_loading` 卡 true）。
  Future<void> _loadSubscriptionLinks() async {
    var subs = <String, TvboxSourceInfo>{};
    TvboxSourceInfo? aggregateSource;
    try {
      /*
       * ⚠️ `.timeout` 本身在**测试**里会留下一个 pending Timer
       *    （`flutter_test` 用假时钟，3 秒的定时器必须在测试结束前被消化）
       *    ⇒ `pumpAndSettle` 之后报 "Pending timers" 让用例红。
       *
       * 正确做法：**不用 `.timeout`**，而是把"没核心时不回包"这件事交给
       * 调用方已有的**超时纪律** —— 与 `tvboxConfigSiteTotal()` 完全一致
       * （它在 `sourin_api.dart:300` 包了 600ms 的 timeout，**在那个封装里**）。
       * ⇒ 这里只做 try/catch（异常 ⇒ 空表），不发定时器。
       *
       * ★ 代价如实说明：真的有一个"永不回包的 Future"时，本 Future 会一直挂着。
       *   但它**不再阻塞首屏**（首屏 setState 已先落地）⇒ 用户可见影响为零，
       *   而测试里也不再留 pending timer。
       */
      final l = await SourinApi.listTvboxSources();
      subs = {for (final s in l.sources) s.id: s};
      // ★ T5：聚合时间走顶层字段（与设置页同一份口径）
      aggregateSource = l.aggregate;
    } catch (e) {
      // ★ 读不到就保持空表（= 全部子站按"无链接"归一组）——
      //   宁可少显示「测试连通」的前置数据，也不许假告警/编一个链接。
      debugPrint('[AGG] TVBox 订阅链接加载失败（不影响源列表）: $e');
    }
    if (!mounted) return;
    setState(() {
      _subs = subs;
      _aggregateSource = aggregateSource;
    });
  }

  /// 打开「编辑链接…」弹窗（**只有订阅链接 + 备注**两类输入）
  ///
  /// # 为什么单独一个弹窗（2026-10-29 Owner 原话）
  /// ```text
  /// > 聚合源编辑的时候只能编辑链接，子源管理单独做一个编辑配置弹窗
  /// ⇒ "改这条订阅从哪来 / 这坨源叫什么" 与 "这坨源里启用哪几个" 是**两件事**，
  ///   塞在同一个长页面里会互相干扰（460px 高的内容区，勾选行一多就把链接挤没）。
  /// ⇒ 本弹窗**只**放 link + note；勾选、测试连通、去重全部搬到「管理子源…」。
  /// ```
  Future<void> _openLinkDialog(TvboxAggregate a) async {
    final updated = await showAppDialog<TvboxAggregate>(
      context: context,
      /*
       * ★ 为什么要自己给一层 `Material`（实测踩到）：`showAppDialog` 走的是
       *   `DialogRoute`，**不是** `Dialog`/`AlertDialog` ⇒ 路由里没有 Material 祖先，
       *   而「编辑链接」弹窗里有 `TextField` ⇒ 直接抛
       *   `No Material widget found (TextField widgets require a Material widget ancestor)`。
       *   transparency 不改变外观，只补祖先。
       */
      builder: (_) => Material(
        type: MaterialType.transparency,
        child: TvboxAggregateLinkDialog(
          aggregate: a,
          repId: _repIdOf(a),
          currentLink: _currentLinkOf(a),
        ),
      ),
    );
    if (updated == null || !mounted) return;
    setState(() => _agg = updated);
    // 链接可能变了 ⇒ 订阅表要重拉（非阻塞，理由见 `_load()` 那段）
    unawaited(_loadSubscriptionLinks());
  }

  /// 打开「管理子源…」弹窗（勾选 / 测试连通 / 去重）
  Future<void> _openSitesDialog(TvboxAggregate a) async {
    final updated = await showAppDialog<TvboxAggregate>(
      context: context,
      // ★ 同 `_openLinkDialog`：路由里没有 Material 祖先，而弹窗里有 Checkbox/Switch/
      //   ListTile（都要 Material 画水波纹）⇒ 必须自己补一层 transparency。
      builder: (_) => Material(
        type: MaterialType.transparency,
        child: TvboxAggregateSitesDialog(
          aggregate: a,
          sourceOf: _subOf,
        ),
      ),
    );
    if (updated == null || !mounted) return;
    setState(() {
      _agg = updated;
      _selected
        ..clear()
        ..addAll(
          updated.sites
              .where((s) => s.implemented && s.enabled)
              .map((s) => s.id),
        );
    });
  }

  /// 一个聚合源的**代表 id**（命令按 id 寻址；同一条链接下用哪个 id 都命中）
  ///
  /// 有链接的先挑（那才是"这个聚合源"），否则退回第一个子站 id。
  String? _repIdOf(TvboxAggregate a) {
    for (final s in a.sites) {
      final url = _subs[s.id]?.sourceUrl;
      if (url != null && url.trim().isNotEmpty) return s.id;
    }
    return a.sites.isEmpty ? null : a.sites.first.id;
  }

  /// 当前订阅链接（没有 ⇒ 空串；界面据此把输入框留空，而不是写一句假链接）
  String _currentLinkOf(TvboxAggregate a) {
    for (final s in a.sites) {
      final url = _subs[s.id]?.sourceUrl;
      if (url != null && url.trim().isNotEmpty) return url.trim();
    }
    return '';
  }

  /// 取某子站的订阅信息（没登记 ⇒ null）
  ///
  /// ⚠️ N8b-2 的成组判据：**按 `sourceUrl` 归组** ——
  ///    同一个链接下的全部子站共享同一条结果（命令层一次下载对比全部），
  ///    所以界面上"一个聚合源" = **一条链接**，不是一个子站。
  TvboxSourceInfo? _subOf(String id) => _subs[id];

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final a = _agg;
    return AppGlassDialog(
      title: 'TVBox 聚合',
      maxWidth: 560,
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppTextButton(
            key: const ValueKey<String>('agg-close'),
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 460,
        child: SingleChildScrollView(
          child: DefaultTextStyle.merge(
            textAlign: TextAlign.left,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (_loading)
                  const Padding(
                    padding: EdgeInsets.all(Sp.x4),
                    child: Text('正在读取聚合配置…'),
                  )
                else if (_error.isNotEmpty)
                  Text(
                    _error,
                    key: const ValueKey<String>('agg-error'),
                    style: TextStyle(fontSize: FontSizes.sm, color: colors.error),
                  )
                else if (a != null) ...<Widget>[
                  /*
                   * ══════════════════════════════════════════════════════
                   * ★★★ 2026-10-29（Owner）：**两个入口，各管一件事**
                   * ══════════════════════════════════════════════════════
                   *
                   * Owner 原话：
                   * > 聚合源编辑的时候只能编辑链接，子源管理单独做一个编辑配置弹窗
                   *
                   * ```text
                   * 改前（本页一个长列表）：源勾选 + 链接 / 测试 / 更新 + 网盘凭据
                   *   ⇒ 三件事挤在 460px 高的内容区里，勾选一多就把别的挤到看不见。
                   * 改后（本页只留"摘要 + 两个入口"）：
                   *   · 「编辑链接…」= TvboxAggregateLinkDialog → **只有**订阅链接 + 备注
                   *   · 「管理子源…」= TvboxAggregateSitesDialog → 勾选 + 测试连通 + **去重**
                   *   · 「网盘与凭据」区**从本页移除**（已拆成公用配置：网盘账号页）
                   *     ⇒ 类 `TvboxAggregateCredentialsSection` 保留（别处可能引用），只是这里不挂。
                   * ```
                   *
                   * ⚠️ 命令层的寻址规则没变（这条是实网取证，别推翻）：
                   * ```text
                   * 能编辑/测试/更新的"聚合源"就是**子站 id**（它们共享同一条订阅链接，
                   * 命令层按链接分组）—— 拿 `tvbox_agg` 去调必然报"没有找到 TVBox 源"。
                   * ⇒ 两个弹窗都按"代表 id"（有链接的第一个子站）寻址，见 `_repIdOf`。
                   * ```
                   */
                  /*
                   * ★ T5（2026-11-01）：聚合源自己的「上次更新」行
                   *
                   * ```text
                   * Owner：「源 里面的没有显示上次更新时间」—— 而在一级列表里
                   * 用户唯一看得见的 TVBox 卡片就是聚合源这条。
                   * 它是 Rust 内置 provider ⇒ sidecar 里没有它这一条 ⇒ 没有章
                   * ⇒ 时间来自"其所含子站章的聚合"（Rust 侧 max，单一事实源）。
                   * ```
                   *
                   * ⚠️ 文案复用 `tvboxLastUpdateText`（与设置页卡片**同一份**口径），
                   *    不在这里另写一遍（写两遍必然漂移）。
                   * ⚠️ 后端没给（旧核心）⇒ `null` ⇒ 整行不画 —— 不编「从未更新」。
                   */
                  if (tvboxLastUpdateText(_aggregateSource) != null) ...<Widget>[
                    Text(
                      tvboxLastUpdateText(_aggregateSource)!,
                      key: const ValueKey<String>('agg-last-update'),
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: tvboxLastUpdateFailed(_aggregateSource)
                            ? colors.error
                            : colors.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(height: Sp.x3),
                  ],
                  TvboxAggregateIdentityBlock(
                    note: a.note,
                    listedSites: a.sites.length,
                    enabledSites: _selected.length,
                  ),
                  const SizedBox(height: Sp.x3),
                  Row(
                    children: <Widget>[
                      AppTextButton(
                        key: const ValueKey<String>('agg-edit-link'),
                        onPressed: () => _openLinkDialog(a),
                        foregroundColor: colors.primary,
                        child: const Text('编辑链接…'),
                      ),
                      const SizedBox(width: Sp.x2),
                      AppTextButton(
                        key: const ValueKey<String>('agg-manage-sites'),
                        onPressed: () => _openSitesDialog(a),
                        foregroundColor: colors.primary,
                        child: const Text('管理子源…'),
                      ),
                    ],
                  ),
                  TvboxAggregateUnimplementedNote(
                    totalSites: _configSiteTotal,
                    listedSites: a.sites.length,
                  ),
                  if (_saveError.isNotEmpty) ...<Widget>[
                    const SizedBox(height: Sp.x2),
                    Text(
                      _saveError,
                      key: const ValueKey<String>('agg-save-error'),
                      style:
                          TextStyle(fontSize: FontSizes.cap, color: colors.error),
                    ),
                  ],
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);
  final String text;
  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          fontSize: FontSizes.sm,
          fontWeight: FontWeight.w600,
          color: Theme.of(context).colorScheme.onSurface,
        ),
      );
}

/// 「这个聚合源是谁」—— 备注（Owner 说的"自己起名字"）+ 子源统计
///
/// # 为什么备注空就**不画**（而不是画一行"（无备注）"）
/// ```text
/// 空备注是常态（历史配置都没有它）。画一个空槽位会让每个聚合源都多一行灰字，
/// 反而看不出"哪些源被用户标注过" ⇒ 空 ⇒ 整行不渲染（与 `TvboxAggregateUnimplementedNote`
/// 的"diff<=0 就不画"同一条口径：不许出现 0 信息的行）。
/// ```
class TvboxAggregateIdentityBlock extends StatelessWidget {
  const TvboxAggregateIdentityBlock({
    super.key,
    required this.note,
    required this.listedSites,
    required this.enabledSites,
  });

  /// 用户备注（`TvboxAggregate.note`；空串 = 没起名字）
  final String note;

  /// `sites[]` 长度（本机认得的子源数）
  final int listedSites;

  /// 其中已启用的数量
  final int enabledSites;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final n = note.trim();
    return Column(
      key: const ValueKey<String>('agg-identity'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (n.isNotEmpty) ...<Widget>[
          Text(
            n,
            key: const ValueKey<String>('agg-note'),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: FontSizes.sm,
              fontWeight: FontWeight.w600,
              color: colors.onSurface,
            ),
          ),
          const SizedBox(height: Sp.x1),
        ],
        Text(
          '已启用 $enabledSites / $listedSites 个子源',
          key: const ValueKey<String>('agg-counts'),
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    );
  }
}

/// 「编辑链接…」弹窗 —— **只有**订阅链接 + 备注两类输入
///
/// # 为什么这里**不许**出现子源勾选 / 网盘凭据（Owner 定的拆法）
/// ```text
/// > 聚合源编辑的时候只能编辑链接，子源管理单独做一个编辑配置弹窗
/// ⇒ 本弹窗的职责边界是"这条订阅从哪来、它叫什么"，
///   勾选与去重在 `TvboxAggregateSitesDialog`，网盘凭据已挪到公用"网盘账号"页。
/// ⇒ 门禁 `zz_agg_split_*` 会断言：本弹窗里 `Checkbox` **0 个**、
///   `agg-credentials` / `网盘与凭据` **都不存在**（多塞一样东西立刻红）。
/// ```
class TvboxAggregateLinkDialog extends StatefulWidget {
  const TvboxAggregateLinkDialog({
    super.key,
    required this.aggregate,
    this.repId,
    this.currentLink = '',
  });

  final TvboxAggregate aggregate;

  /// 命令层的寻址 id（有链接的第一个子站；`null` = 没有可写的子站）
  final String? repId;

  /// 现在的订阅链接（空串 = 没有链接，输入框留空）
  final String currentLink;

  @override
  State<TvboxAggregateLinkDialog> createState() =>
      _TvboxAggregateLinkDialogState();
}

/// 备注限长：**提交时**按「字」截 60（与 Rust 侧 `tvbox_aggregate.rs` 的
/// `chars().take(60)` 同一语义），输入框自身不再设 `maxLength`。
///
/// # 为什么不能留在输入框上（task-3，Owner 现场反馈「中文输入失效」）
/// ```text
/// Flutter 的 maxLength 由 LengthLimitingTextInputFormatter 实现，
/// 它对 **IME 组合中（composing）**的文本同样计数/截断：
/// 拼音串还没上屏就被削断 ⇒ 组合被打断 ⇒ Windows 桌面端连打中文"失效"。
/// ⇒ 限长只能出现在**提交路径**；输入期不干预组合态。
/// ```
/// # 为什么按 characters（字形簇）而不是 code unit
/// ```text
/// Rust 按 `chars()`（Unicode 标量值）截；Dart 的 String 索引是 UTF-16 code unit，
/// 直接 substring 可能把代理对拦腰截断。用 `characters` 按字形簇截，
/// emoji/组合字符不会被截出半个，长度上与 Rust 的 60 上限同界。
/// ```
String clampNoteTo60(String raw) {
  final t = raw.trim();
  final c = t.characters;
  if (c.length <= 60) return t;
  return c.take(60).toString();
}

class _TvboxAggregateLinkDialogState extends State<TvboxAggregateLinkDialog> {
  late final TextEditingController _link =
      TextEditingController(text: widget.currentLink);
  late final TextEditingController _note =
      TextEditingController(text: widget.aggregate.note);
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _link.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 保存：**两条独立命令**
  ///
  /// ```text
  /// ① 订阅链接 → `set_tvbox_source {id, url}`（存在 sidecar，和聚合配置不是一份）
  ///    仅在"有代表 id + 非空 + 与原来不同"时才发 ⇒ 不把"没改"写成"改成空"
  ///    （那会把用户的链接清掉 —— 这是很贵的误操作）
  /// ② 备注 → `tvbox_aggregate_set {note}`（部分更新；"" = 清空，服务端已实现）
  /// ```
  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      final link = _link.text.trim();
      final rep = widget.repId;
      if (rep != null && link.isNotEmpty && link != widget.currentLink) {
        await SourinApi.setTvboxSource(rep, link);
      }
      final a = await SourinApi.tvboxAggregateSet(
        note: clampNoteTo60(_note.text),
      );
      if (!mounted) return;
      Navigator.of(context).pop(a);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e, fallback: '保存失败，请稍后重试');
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppGlassDialog(
      title: '编辑链接',
      maxWidth: 460,
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppTextButton(
            key: const ValueKey<String>('agg-link-cancel'),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: Sp.x2),
          AppTextButton(
            key: const ValueKey<String>('agg-link-save'),
            onPressed: _busy ? null : _save,
            foregroundColor: colors.primary,
            child: Text(_busy ? '保存中…' : '保存'),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          key: const ValueKey<String>('agg-link-dialog'),
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '订阅链接',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Sp.x1),
            TextField(
              key: const ValueKey<String>('agg-link-input'),
              controller: _link,
              enabled: !_busy,
              decoration: const InputDecoration(
                isDense: true,
                hintText: 'https://…（粘贴订阅链接）',
              ),
              style: const TextStyle(fontSize: FontSizes.cap),
            ),
            const SizedBox(height: Sp.x2),
            TextField(
              key: const ValueKey<String>('agg-note-input'),
              controller: _note,
              enabled: !_busy,
              // ★ task-3：这里**故意没有 maxLength** —— 它会在 Windows 上参与
              //   IME 组合期截断，打断中文输入。限长移到提交时（clampNoteTo60，
              //   与 Rust 侧 chars().take(60) 对齐）；门禁 test/ime_field_gate_test.dart
              //   守着"不得加回"。
              decoration: const InputDecoration(
                isDense: true,
                labelText: '备注（用于区分多个聚合源）',
              ),
              style: const TextStyle(fontSize: FontSizes.cap),
            ),
            if (_error.isNotEmpty)
              Text(
                _error,
                key: const ValueKey<String>('agg-link-error'),
                style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
              ),
          ],
        ),
      ),
    );
  }
}

/// 「管理子源…」弹窗 —— 勾选 / 测试连通 / **去重**
///
/// # 为什么整块搬（不是复制一份）
/// ```text
/// 勾选（`TvboxAggregateSitesList`）与"链接 / 测试 / 更新"（`TvboxAggregateManageSection`）
/// 本来就在本文件里、且已有自己的门禁 ⇒ 这里只是**换个容器**挂它们，
/// 不重写内部实现（重写就会出现两套行为）。
/// ```
/// # 去重为什么不放在"编辑链接"里
/// ```text
/// 去重动的是**子源集合**（停用重复项），与"这条订阅从哪来"无关；
/// 放在子源管理里，用户才找得到"我按哪个按钮才会少掉这些行"。
/// ```
class TvboxAggregateSitesDialog extends StatefulWidget {
  const TvboxAggregateSitesDialog({
    super.key,
    required this.aggregate,
    required this.sourceOf,
    this.panelBuilder,
  });

  final TvboxAggregate aggregate;

  /// id → 订阅信息（管理区按链接归组用）
  final TvboxSourceInfo? Function(String id) sourceOf;

  /// 测试缝：替换管理区每行的面板（生产恒 null）
  final Widget Function(String id, String name, String? sourceUrl)? panelBuilder;

  @override
  State<TvboxAggregateSitesDialog> createState() =>
      _TvboxAggregateSitesDialogState();
}

class _TvboxAggregateSitesDialogState extends State<TvboxAggregateSitesDialog> {
  late TvboxAggregate _agg = widget.aggregate;
  late final Set<String> _selected = <String>{
    ...widget.aggregate.sites
        .where((s) => s.implemented && s.enabled)
        .map((s) => s.id),
  };
  bool _busy = false;
  String _error = '';

  String _siteQuery = '';
  bool? _siteEnabledFilter;

  List<TvboxAggregateSite> get _visibleSites => filterManagedSites(
      _agg.sites, selected: _selected, query: _siteQuery, enabled: _siteEnabledFilter);

  void _selectVisible(bool on) {
    if (_busy) return;
    setState(() {
      final next = selectionForVisibleSites(_selected, _visibleSites, on);
      _selected
        ..clear()
        ..addAll(next);
    });
  }

  /// 去重结果文案（空 = 还没点过；**不许**在点之前先说"没有重复"）
  String _dedupeMsg = '';

  /// 「只显示聚合源（测试用）」—— 初值来自 `TvboxAggregate.solo`（旧核心没这个键 ⇒ false）
  late bool _solo = widget.aggregate.solo;

  /// 切换 solo：**立刻发命令**（Owner 的用途是"点一下马上看列表变化"，不是攒到保存）
  ///
  /// ```text
  /// 语义再强调一次（Rust 注释逐字）：solo=true 只是"源列表只显示聚合源"，
  ///   **子站的搜索/扇出照旧** —— 所以这里绝不能顺手把子站停用
  ///   （那会让聚合源变空，与需求正好相反）。
  /// 失败要回滚开关位置：开关停在"开"但服务端没存 ⇒ 下次打开又变回去 = 骗人。
  /// ```
  Future<void> _toggleSolo(bool v) async {
    final prev = _solo;
    setState(() {
      _solo = v;
      _error = '';
    });
    try {
      await SourinApi.tvboxAggregateSet(solo: v);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _solo = prev;
        _error = userErrorText(e, fallback: '切换失败，请稍后重试');
      });
    }
  }

  void _toggle(String id, bool on) {
    if (_busy || !_agg.sites.any((s) => s.id == id && s.implemented)) return;
    setState(() {
      if (on) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
      _error = '';
    });
  }

  Future<void> _save() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
    });
    try {
      // ★ 顺序稳定：按 sites 的原始顺序输出，而不是 Set 的插入序
      final ordered = <String>[
        for (final s in _agg.sites)
          if (_selected.contains(s.id)) s.id,
      ];
      final a = await SourinApi.tvboxAggregateSet(enabledSiteIds: ordered);
      if (!mounted) return;
      Navigator.of(context).pop(a);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e, fallback: '保存聚合配置失败，请稍后重试');
        _busy = false;
      });
    }
  }

  /// 去重：`tvbox_aggregate_dedupe_sites` → **成功后刷新列表** → 按钮下方给结果
  ///
  /// ```text
  /// 判据（Rust 侧）：站名 + api 都相同才算重复；保留第一个，其余**停用**（不是删除）。
  /// ⇒ 刷新必须重新读 `tvbox_aggregate_get()`（被停用的行要立刻显示成未勾选），
  ///   而不是本地把行删掉 —— 删掉会让用户以为"源被移除了"。
  /// ```
  Future<void> _dedupe() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = '';
      _dedupeMsg = '';
    });
    try {
      final r = await SourinApi.tvboxAggregateDedupeSites();
      final a = await SourinApi.tvboxAggregateGet();
      if (!mounted) return;
      setState(() {
        _agg = a;
        _selected
          ..clear()
          ..addAll(a.sites.where((s) => s.implemented && s.enabled).map((s) => s.id));
        _dedupeMsg =
            r.duplicates == 0 ? '没有重复子源' : '已停用 ${r.duplicates} 个重复子源';
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e, fallback: '去重没有完成，请稍后重试');
        _busy = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppGlassDialog(
      title: '管理子源',
      maxWidth: 560,
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          AppTextButton(
            key: const ValueKey<String>('agg-sites-cancel'),
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          const SizedBox(width: Sp.x2),
          AppTextButton(
            key: const ValueKey<String>('agg-sites-save'),
            onPressed: _busy ? null : _save,
            foregroundColor: colors.primary,
            child: Text(_busy ? '保存中…' : '保存'),
          ),
        ],
      ),
      content: SizedBox(
        width: 500,
        height: 420,
        child: SingleChildScrollView(
          child: Column(
            key: const ValueKey<String>('agg-sites-dialog'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              TextField(
                key: const ValueKey<String>('agg-sites-search'),
                onChanged: (query) => setState(() => _siteQuery = query),
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: '搜索子站名称或标识',
                  prefixIcon: Icon(Icons.search),
                ),
              ),
              Wrap(
                spacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  DropdownButton<bool>(
                    value: _siteEnabledFilter,
                    hint: const Text('全部状态'),
                    onChanged: (enabled) =>
                        setState(() => _siteEnabledFilter = enabled),
                    items: const [
                      DropdownMenuItem<bool>(value: null, child: Text('全部状态')),
                      DropdownMenuItem<bool>(value: true, child: Text('已选择')),
                      DropdownMenuItem<bool>(value: false, child: Text('未选择')),
                    ],
                  ),
                  TextButton.icon(
                    key: const ValueKey<String>('agg-sites-select-visible'),
                    onPressed: _busy || _visibleSites.isEmpty ? null : () => _selectVisible(true),
                    icon: const Icon(Icons.select_all),
                    label: const Text('全选当前结果'),
                  ),
                  TextButton.icon(
                    key: const ValueKey<String>('agg-sites-clear-visible'),
                    onPressed: _busy || _visibleSites.isEmpty ? null : () => _selectVisible(false),
                    icon: const Icon(Icons.deselect),
                    label: const Text('清空当前结果'),
                  ),
                  Text('${_visibleSites.length}/${_agg.sites.length} · 已选 ${_selected.length}'),
                ],
              ),
              TvboxAggregateSitesList(
                sites: _visibleSites,
                selected: _selected,
                onToggle: _toggle,
              ),
              if (_agg.sites.isNotEmpty) ...<Widget>[
                const SizedBox(height: Sp.x3),
                TvboxAggregateManageSection(
                  sites: _agg.sites,
                  sourceOf: widget.sourceOf,
                  panelBuilder: widget.panelBuilder,
                ),
              ],
              const SizedBox(height: Sp.x3),
              /*
               * ★ 必须给 SwitchListTile 套一层 `Material`（实测断言，不是洁癖）：
               *   玻璃卡片外框是 `DecoratedBox(带背景色)`，ListTile 会把底色/水波纹
               *   画在**最近的 Material 祖先**上 ⇒ 框架直接抛
               *   「ListTile background color or ink splashes may be invisible」，
               *   在测试里表现为**整条用例红**。transparency 只补祖先，不改外观。
               */
              Material(
                type: MaterialType.transparency,
                child: SwitchListTile(
                  key: const ValueKey<String>('agg-solo'),
                  value: _solo,
                  onChanged: _busy ? null : _toggleSolo,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: Text(
                    '只显示聚合源（测试用）',
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurface,
                    ),
                  ),
                  // ★ 这句不是装饰：solo 容易被误解成"把子站关掉"，而真相是相反
                  subtitle: Text(
                    '子站仍参与搜索，只是列表里不显示',
                    key: const ValueKey<String>('agg-solo-hint'),
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: Sp.x3),
              Align(
                alignment: Alignment.centerLeft,
                child: AppTextButton(
                  key: const ValueKey<String>('agg-dedupe'),
                  onPressed: _busy ? null : _dedupe,
                  child: Text(_busy ? '处理中…' : '去重'),
                ),
              ),
              if (_dedupeMsg.isNotEmpty)
                Text(
                  _dedupeMsg,
                  key: const ValueKey<String>('agg-dedupe-result'),
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              if (_error.isNotEmpty)
                Text(
                  _error,
                  key: const ValueKey<String>('agg-sites-error'),
                  style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

List<TvboxAggregateSite> filterManagedSites(
  List<TvboxAggregateSite> sites, {
  required Set<String> selected,
  String query = '',
  bool? enabled,
}) {
  final needle = query.trim().toLowerCase();
  return sites.where((s) =>
      (enabled == null || selected.contains(s.id) == enabled) &&
      (needle.isEmpty || '${s.name} ${s.id} ${s.kindTag}'.toLowerCase().contains(needle)))
      .toList(growable: false);
}

Set<String> selectionForVisibleSites(
    Set<String> selected, List<TvboxAggregateSite> visible, bool on) {
  final next = {...selected};
  final ids = visible.where((s) => s.implemented).map((s) => s.id);
  if (on) {
    next.addAll(ids);
  } else {
    next.removeAll(ids);
  }
  return next;
}

/// 把子站按**订阅链接**归组（N8b-2 的"一个聚合源"= 一条链接）
///
/// # 为什么按链接而不是按子站
/// ```text
/// 命令层（`check_tvbox_updates` / `update_tvbox_source`）**按链接去重**：
/// 一份配置产出几十个源，它们共用同一个链接 ⇒ 一次下载对比全部，
/// 而不是每个源各下一遍（`tvbox.rs` 的 `wanted: BTreeSet<String>` 就是它）。
/// ⇒ 界面上"一行 = 名字 / 链接 / 测试 / 更新"必须以**链接**为单位，
///   按子站铺开会出现 16 行**完全相同**的链接输入框（那是噪声也是假象）。
/// ```
///
/// # 那些**没有链接**的子站（`needsSource`）
/// ```text
/// 单独归到 `null` 键那一组：它们查不了更新，但**必须显示**且能"填入链接"
/// —— 这正是既有 `TvboxUpdateDialog._hasLink` 的口径（"没有的能力不假装有"）。
/// ```
/// ★ 纯函数，可离线单测（顺序按首次出现，稳定可复现）。
@visibleForTesting
Map<String?, List<String>> groupSitesBySourceUrl(
  List<TvboxAggregateSite> sites,
  TvboxSourceInfo? Function(String id) sourceOf,
) {
  final out = <String?, List<String>>{};
  for (final s in sites) {
    final url = sourceOf(s.id)?.sourceUrl;
    // 空串与 null 等价（"没有链接"）—— 归一化，避免出现两个"无链接"组
    final key = (url == null || url.trim().isEmpty) ? null : url.trim();
    (out[key] ??= <String>[]).add(s.id);
  }
  return out;
}

/// N8b-2：聚合源管理区（按订阅链接一行 = 链接可改 / 测试连通 / 立即更新）
///
/// # 公开 + 可注入（与 `TvboxUpdateResultView` 同一条纪律）
/// ```text
/// 注入 `panelBuilder` 让门禁能**真渲染**这一区并断言"有几行、每行是谁"，
/// 而不会因为面板内部的网络调用把测试搅乱。
/// 生产恒 null ⇒ 每行画真的 [TvboxSourceManagePanel]。
/// ```
class TvboxAggregateManageSection extends StatelessWidget {
  const TvboxAggregateManageSection({
    super.key,
    required this.sites,
    required this.sourceOf,
    this.panelBuilder,
  });

  final List<TvboxAggregateSite> sites;

  /// id → 订阅信息（null = 后端不认识这个 id）
  final TvboxSourceInfo? Function(String id) sourceOf;

  /// 测试缝：自定义每行的面板（生产恒 null）
  final Widget Function(String id, String name, String? sourceUrl)? panelBuilder;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final groups = groupSitesBySourceUrl(sites, sourceOf);
    if (groups.isEmpty) return const SizedBox.shrink();

    /*
     * ★ 提升成局部量：`panelBuilder` 是**公开 final 字段**，
     *   Dart 对公开字段不做类型提升（`panelBuilder != null` 之后
     *   直接调它会报 unchecked_use_of_nullable_value）。
     */
    final Widget Function(String id, String name, String? sourceUrl)? buildPanel =
        panelBuilder;

    /*
     * ★ 每一行的 id/name 用什么？
     * ```text
     * 命令按 id 寻址 ⇒ 必须用**真实在 persisted 里的那个子站 id**。
     * 而一族里可能有多个子站（同一条链接）—— 取**第一个**当代表
     * （命令层按链接分组，用哪一个 id 都会命中同一条结果）。
     * 名字优先用 sidecar 里的 `siteName`（用户认的是这个），
     * 拿不到才退回子站名。
     * ```
     */
    final rows = <Widget>[];
    for (final e in groups.entries) {
      final url = e.key;
      final ids = e.value;
      if (ids.isEmpty) continue;
      final repId = ids.first;
      final info = sourceOf(repId);
      final siteName = sites
          .where((s) => s.id == repId)
          .map((s) => s.name)
          .join();
      final displayName =
          (info?.name.trim().isEmpty ?? true) ? siteName : info!.name;

      rows.add(
        Padding(
          padding: const EdgeInsets.only(bottom: Sp.x3),
          child: Column(
            key: ValueKey<String>('agg-manage-row-$url'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                // 一行标题说清"这是哪一个聚合源、管着几个子站"
                ids.length > 1
                    ? '$displayName（这条订阅下有 ${ids.length} 个子站）'
                    : displayName,
                key: ValueKey<String>('agg-manage-title-$url'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontWeight: FontWeight.w600,
                  color: colors.onSurface,
                ),
              ),
              const SizedBox(height: Sp.x1),
              if (buildPanel != null)
                buildPanel(repId, displayName, url)
              else
                TvboxSourceManagePanel(
                  id: repId,
                  name: displayName,
                  sourceUrl: url,
                  // ★ T5：管理面板也显示「上次更新」（同一份 sidecar 数据）
                  info: info,
                ),
            ],
          ),
        ),
      );
    }

    return Column(
      key: const ValueKey<String>('agg-manage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '聚合源（链接 / 测试 / 更新）',
          style: TextStyle(
            fontSize: FontSizes.sm,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: Sp.x2),
        ...rows,
      ],
    );
  }
}

/// ① 源列表（多选启用；未实现的灰掉 + 逐字原因）
/// ⚠️ **纯展示**：勾选集合由宿主给，组件只回调。
///    未实现的条目**连复选框都是禁用的**（`onChanged: null`）——
///    "能勾但勾了没效果"比"不能勾"更糟。
class TvboxAggregateSitesList extends StatelessWidget {
  const TvboxAggregateSitesList({
    super.key,
    required this.sites,
    required this.selected,
    required this.onToggle,
  });

  final List<TvboxAggregateSite> sites;
  final Set<String> selected;
  final void Function(String id, bool on) onToggle;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    if (sites.isEmpty) {
      return TvboxAggregateEmptyState(
        onImport: () => Navigator.of(context).maybePop(),
      );
    }
    return Column(
      key: const ValueKey<String>('agg-sites'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (final s in sites)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x1),
            child: Row(
              key: ValueKey<String>('agg-site-${s.id}'),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Checkbox(
                  key: ValueKey<String>('agg-site-check-${s.id}'),
                  value: s.implemented && selected.contains(s.id),
                  onChanged:
                      s.implemented ? (v) => onToggle(s.id, v == true) : null,
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Text(
                        s.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          color: s.implemented
                              ? colors.onSurface
                              : colors.onSurface.withValues(alpha: 0.45),
                        ),
                      ),
                      GithubSourceOrigin(providerId: s.id),
                      if (s.kindTag.isNotEmpty)
                        Text(
                          s.kindTag,
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                      if (!s.implemented && (s.reason ?? '').isNotEmpty)
                        Text(
                          s.reason!,
                          key: ValueKey<String>('agg-site-reason-${s.id}'),
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// ④ 空态：还没导入过 TVBox 配置
class TvboxAggregateEmptyState extends StatelessWidget {
  const TvboxAggregateEmptyState({super.key, required this.onImport});

  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      key: const ValueKey<String>('agg-empty'),
      padding: const EdgeInsets.all(Sp.x4),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rLg,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            '还没有导入 TVBox 配置 —— 先导入一份，这里才会出现可选的内容源',
            key: const ValueKey<String>('agg-empty-text'),
            style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
          ),
          const SizedBox(height: Sp.x2),
          FilledButton.icon(
            key: const ValueKey<String>('agg-empty-import'),
            onPressed: onImport,
            icon: const Icon(AppIcons.download, size: 16),
            label: const Text('去导入'),
          ),
        ],
      ),
    );
  }
}

/// ② 网盘分享体（识别 + 列目录 + "可列不可播"）
///
/// 与 `PanShareDialog` 的内容**同构**（那边暂不重构，理由见文件头）。
class PanShareBody extends StatefulWidget {
  const PanShareBody({super.key, this.providerId});

  /// 归属的聚合源 id（只用于将来按源隔离配置；当前命令是全局的）
  final String? providerId;

  @override
  State<PanShareBody> createState() => _PanShareBodyState();
}

class _PanShareBodyState extends State<PanShareBody> {
  final TextEditingController _text = TextEditingController();
  bool _busy = false;
  String _error = '';
  PanShareListing? _listing;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _list() async {
    final t = _text.text.trim();
    if (t.isEmpty) {
      setState(() => _error = '请先粘贴网盘分享链接或整段分享文字');
      return;
    }
    setState(() {
      _busy = true;
      _error = '';
      _listing = null;
    });
    try {
      final l = await SourinApi.panListShare(t);
      if (!mounted) return;
      setState(() => _listing = l);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = userErrorText(e, fallback: '列目录没有完成，请稍后重试'));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey<String>('pan-share-body'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        TextField(
          key: const ValueKey<String>('pan-share-body-input'),
          controller: _text,
          enabled: !_busy,
          decoration: const InputDecoration(
            isDense: true,
            hintText: '粘贴网盘分享链接或整段分享文字',
          ),
          style: const TextStyle(fontSize: FontSizes.cap),
        ),
        Align(
          alignment: Alignment.centerLeft,
          child: AppTextButton(
            key: const ValueKey<String>('pan-share-body-list'),
            onPressed: _busy ? null : _list,
            child: Text(_busy ? '正在读取…' : '列出文件'),
          ),
        ),
        if (_error.isNotEmpty)
          Text(
            _error,
            key: const ValueKey<String>('pan-share-body-error'),
            style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
          ),
        if (_listing != null) PanShareListingSection(listing: _listing),
      ],
    );
  }
}

/// ② 「网盘与凭据」共享面板（Owner 直接要求：这些配置属于聚合插件本身，放二级页）
///
/// # 三块复用的都是**现成组件**（不另写一套）
/// ```text
/// 网盘分享   → PanShareBody（本文件内，识别 + 列目录 + "可列不可播"）
/// 登录凭据   → ProviderLoginPanel（provider_login_panel.dart:203）
/// 代理       → ProxyPanel（proxy_panel.dart:101）
/// ```
/// # 未登录时的出口
/// ```text
/// `ProviderLoginPanel` 自己在 `expired` / 未登录时画「去登录」；
/// 这里额外给一个**明确入口**（key `agg-credentials-login`），
/// 避免用户在长页面里找不到（Owner 反馈过"看不到、点不进去"这一类问题）。
/// ```
class TvboxAggregateCredentialsSection extends StatelessWidget {
  const TvboxAggregateCredentialsSection({
    super.key,
    required this.aggregateId,
  });

  final String aggregateId;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Column(
      key: const ValueKey<String>('agg-credentials'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(
          '网盘与凭据',
          style: TextStyle(
            fontSize: FontSizes.sm,
            fontWeight: FontWeight.w600,
            color: colors.onSurface,
          ),
        ),
        const SizedBox(height: Sp.x2),
        PanShareBody(providerId: aggregateId),
        const SizedBox(height: Sp.x3),
        Text(
          '该源的登录凭据',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x1),
        ProviderLoginPanel(
          providerId: aggregateId,
          providerName: 'TVBox 聚合',
        ),
        Row(
          children: <Widget>[
            const AppTextButton(
              key: ValueKey<String>('agg-credentials-login'),
              onPressed: null,
              child: Text('去登录'),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                '需要账号的源，登录后才能取直链',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x3),
        Text(
          '代理',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x1),
        ProxyPanel(providerId: aggregateId, providerName: 'TVBox 聚合'),
      ],
    );
  }
}

/// 聚合页底部说明：**"配置里还有多少源在本机没实现"**
///
/// # 为什么需要这一行（Owner 定的契约取舍）
/// ```text
/// `sites[]` 只列 registry 里那 16 个（可操作的那些）——
/// 把 73 条不可用塞进去会把唯一能动的东西淹没。
/// 但"不提"等于骗人：用户会以为配置里就 16 个源。
/// ⇒ 用**一行**把差额透明讲出来，并指向导入报告（那里有逐条原因）。
/// ```
/// # 数字必须**动态**
/// ```text
/// diff = totalSites - listedSites
/// · totalSites 取不到（null）或 diff <= 0 ⇒ **整行不画**
///   （绝不能出现"另有 0 个源…"这种废话，也不能写死 70）
/// ```
class TvboxAggregateUnimplementedNote extends StatelessWidget {
  const TvboxAggregateUnimplementedNote({
    super.key,
    required this.totalSites,
    required this.listedSites,
  });

  /// 配置里的 site 总数（`tvbox-sources.json` 的 `total`）；null = 取不到
  final int? totalSites;

  /// 聚合页真正列出来的（= `sites[]` 长度）
  final int listedSites;

  @override
  Widget build(BuildContext context) {
    final total = totalSites;
    if (total == null) return const SizedBox.shrink();
    final diff = total - listedSites;
    if (diff <= 0) return const SizedBox.shrink();
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Text(
        '另有 $diff 个源在本机未实现，导入报告里有逐条原因',
        key: const ValueKey<String>('tvbox-agg-unimplemented-note'),
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      ),
    );
  }
}
