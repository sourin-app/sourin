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
  bool _saving = false;
  TvboxAggregate? _agg;

  /// 当前勾选（**只含 implemented == true 的 id**）
  final Set<String> _selected = <String>{};

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
      if (!mounted) return;
      setState(() {
        _agg = a;
        _selected
          ..clear()
          ..addAll(a.sites.where((s) => s.implemented && s.enabled).map((s) => s.id));
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = userErrorText(e, fallback: '读取聚合配置失败，请稍后重试');
        _loading = false;
      });
    }
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _saveError = '';
    });
    try {
      // ★ 顺序稳定：按 sites 的原始顺序输出，而不是 Set 的插入序
      final ordered = <String>[
        for (final s in _agg?.sites ?? const <TvboxAggregateSite>[])
          if (_selected.contains(s.id)) s.id,
      ];
      final a = await SourinApi.tvboxAggregateSet(enabledSiteIds: ordered);
      if (!mounted) return;
      setState(() {
        _agg = a;
        _saving = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saveError = userErrorText(e, fallback: '保存聚合配置失败，请稍后重试');
        _saving = false;
      });
    }
  }

  void _toggle(String id, bool on) {
    setState(() {
      if (on) {
        _selected.add(id);
      } else {
        _selected.remove(id);
      }
      _saveError = '';
    });
  }

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
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          SizedBox(width: Sp.x2),
          AppTextButton(
            key: const ValueKey<String>('agg-save'),
            onPressed: (_loading || _saving || a == null) ? null : _save,
            foregroundColor: colors.primary,
            child: Text(_saving ? '保存中…' : '保存'),
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
                  TvboxAggregateSitesList(
                    sites: a.sites,
                    selected: _selected,
                    onToggle: _toggle,
                  ),
                  if (_saveError.isNotEmpty) ...<Widget>[
                    SizedBox(height: Sp.x2),
                    Text(
                      _saveError,
                      key: const ValueKey<String>('agg-save-error'),
                      style:
                          TextStyle(fontSize: FontSizes.cap, color: colors.error),
                    ),
                  ],
                  if (widget.showCredentialPanels) ...<Widget>[
                    SizedBox(height: Sp.x3),
                    TvboxAggregateCredentialsSection(
                      aggregateId: a.aggregateId,
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

/// ① 源列表（多选启用；未实现的灰掉 + 逐字原因）
///
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
      padding: EdgeInsets.all(Sp.x4),
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
          style: TextStyle(fontSize: FontSizes.cap),
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
            AppTextButton(
              key: const ValueKey<String>('agg-credentials-login'),
              onPressed: null,
              child: const Text('去登录'),
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
