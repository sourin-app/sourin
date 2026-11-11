import 'dart:async';
import 'dart:math' as math;

import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart' show userErrorText;
import '../../core/source_discovery.dart';
import '../../core/sourin_api.dart';
import '../tokens.dart';
import '../widgets/app_dialog_shell.dart';
import '../widgets/app_menu.dart';
import '../widgets/miuix_controls.dart' as ui;
import '../widgets/overlay_motion.dart';
import '../widgets/plugin_speedtest.dart';
import '../widgets/settings_dropdown.dart';
import '../widgets/settings_sub_page.dart';
import '../widgets/source_bar.dart' show sourceDisplayLabel;
import '../widgets/source_address_fields.dart';
import 'source_discovery_page.dart';

enum ManagedSourceType {
  all('全部'),
  js('JS'),
  tvbox('聚合来源'),
  live('直播');

  const ManagedSourceType(this.label);
  final String label;
}

enum ManagedSourceStatus {
  all('全部'),
  enabled('已启用'),
  disabled('已停用');

  const ManagedSourceStatus(this.label);
  final String label;
}

/// The provider id remains the routing and persistence identity. A display name
/// never merges providers; only catalog groups may identify shared upstreams.
List<ProviderManifest> managedSourceList(
  List<ProviderManifest> providers, {
  ManagedSourceType type = ManagedSourceType.all,
  ManagedSourceStatus status = ManagedSourceStatus.all,
  String query = '',
  SourceOrigin? origin,
}) {
  final needle = query.trim().toLowerCase();
  return providers
      .where((p) {
        if (p.id == 'tvbox_agg' || p.kind == 'declarative' || p.hidden)
          return false;
        if (status == ManagedSourceStatus.enabled && !p.enabled) return false;
        if (status == ManagedSourceStatus.disabled && p.enabled) return false;
        if (origin != null &&
            !origin.providerIds.contains(p.id) &&
            !origin.relatedProviderIds.contains(p.id)) {
          return false;
        }
        if (needle.isNotEmpty &&
            !'${p.name} ${p.id}'.toLowerCase().contains(needle))
          return false;
        return switch (type) {
          ManagedSourceType.all => true,
          ManagedSourceType.js => p.kind == 'js',
          ManagedSourceType.tvbox => p.kind == 'tvbox',
          ManagedSourceType.live => p.capabilities.live,
        };
      })
      .toList(growable: false);
}

bool _hasRemoteSourceAddress(SourceOrigin origin) {
  final uri = Uri.tryParse(origin.primaryUrl.trim());
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

/// Catalog origins also own individual JS/live address settings. Only TVBox
/// subscriptions belong in the aggregate-origin filter, even with 0/1 children.
bool isTvboxSubscriptionOrigin(SourceOrigin origin) =>
    origin.kind == 'tvbox' && _hasRemoteSourceAddress(origin);

String sourceOriginDescription(
  SourceOrigin? origin,
  ProviderManifest provider, {
  List<SourceOrigin> origins = const [],
}) {
  final parents = origins.where(
    (o) =>
        isTvboxSubscriptionOrigin(o) &&
        o.relatedProviderIds.contains(provider.id),
  );
  if (parents.isNotEmpty) {
    final names = parents
        .map((o) => o.name.trim().isEmpty ? 'TVBox 订阅' : o.name.trim())
        .toSet();
    return '来自 ${names.join('、')}';
  }
  if (origin != null && isTvboxSubscriptionOrigin(origin)) {
    final name = origin.name.trim();
    return '来自 ${name.isEmpty ? 'TVBox 订阅' : name}';
  }
  final remote = origin != null && _hasRemoteSourceAddress(origin);
  return switch (provider.kind) {
    'js' => remote ? 'JS 源' : '本地 JS',
    'tvbox' => '本地 TVBox',
    'm3u_live' => remote ? '直播订阅' : '本地直播',
    _ => provider.capabilities.live ? (remote ? '直播订阅' : '本地直播') : '内置源',
  };
}

class SourceManagerPage extends StatefulWidget {
  const SourceManagerPage({
    super.key,
    required this.onSourcesChanged,
    required this.onImportTvbox,
    required this.onPasteJs,
    required this.onEditProvider,
    required this.onConfigureProvider,
    required this.onRemoveProvider,
    this.onHealthCheck,
    this.onReload,
    this.onSortBySpeed,
    this.onPanShare,
    this.onSpeedTestFinished,
    this.activity,
    this.initialType = ManagedSourceType.all,
    this.subscriptionSettings,
  });

  final ManagedSourceType initialType;
  final VoidCallback onSourcesChanged;
  // Delegated actions own their save/cancel/error outcome and notify the shell
  // after persistence. Returning from a dialog is not a source mutation.
  final Future<void> Function() onImportTvbox;
  final Future<void> Function() onPasteJs;
  final Future<void> Function(ProviderManifest) onEditProvider;
  final Future<void> Function(ProviderManifest) onConfigureProvider;
  final Future<void> Function(ProviderManifest) onRemoveProvider;
  final Future<void> Function()? onHealthCheck;
  final Future<void> Function()? onReload;
  final Future<void> Function()? onSortBySpeed;
  final Future<void> Function()? onPanShare;
  final void Function(int ok, int total)? onSpeedTestFinished;
  final Widget? activity;
  final Widget? subscriptionSettings;

  @override
  State<SourceManagerPage> createState() => _SourceManagerPageState();
}

class _SourceManagerPageState extends State<SourceManagerPage> {
  List<ProviderManifest> _providers = const [];
  SourceCatalog? _catalog;
  Map<String, SourceOrigin> _originsByProvider = const {};
  Map<String, SourceOriginGroup> _groupsByProvider = const {};
  ManagedSourceType _type = ManagedSourceType.all;
  ManagedSourceStatus _status = ManagedSourceStatus.all;
  String _query = '';
  final _searchController = TextEditingController();
  String? _originId;
  bool _loading = true;
  bool _busy = false;
  String? _error;
  int _loadEpoch = 0;

  @override
  void initState() {
    super.initState();
    _type = widget.initialType;
    unawaited(_load());
    // Read persisted provenance; opening source management must not start a scan.
    unawaited(
      SourceDiscoveryService.refresh().then<void>(
        (_) {},
        onError: (Object _) {},
      ),
    );
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final epoch = ++_loadEpoch;
    try {
      final results = await Future.wait<Object>([
        SourinApi.listProviders(),
        SourinApi.sourceCatalogGet(),
      ]);
      if (!mounted || epoch != _loadEpoch) return;
      setState(() {
        _providers = results[0] as List<ProviderManifest>;
        _catalog = results[1] as SourceCatalog;
        final origins = <String, SourceOrigin>{};
        final groups = <String, SourceOriginGroup>{};
        for (final origin in _catalog!.origins) {
          for (final id in origin.providerIds) {
            origins.putIfAbsent(id, () => origin);
          }
        }
        for (final group in _catalog!.groups) {
          if (group.providerIds.length < 2) continue;
          for (final id in group.providerIds) {
            groups.putIfAbsent(id, () => group);
          }
        }
        _originsByProvider = origins;
        _groupsByProvider = groups;
        if (!_catalog!.origins.any(
          (o) => o.id == _originId && isTvboxSubscriptionOrigin(o),
        )) {
          _originId = null;
        }
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (mounted && epoch == _loadEpoch) {
        setState(() {
          _error = userErrorText(e);
          _loading = false;
        });
      }
    }
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
      if (mounted) await _load();
    } catch (e) {
      if (mounted) setState(() => _error = userErrorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _retryLoad() async {
    if (!mounted || _loading || _busy) return;
    setState(() => _loading = true);
    await _load();
  }

  Future<void> _change(Future<void> Function() persist) => _run(() async {
    await persist();
    // Home/search must reject old work before the catalog reload can finish.
    widget.onSourcesChanged();
  });

  SourceOrigin? _originOf(String providerId) => _originsByProvider[providerId];

  SourceOriginGroup? _groupOf(String providerId) =>
      _groupsByProvider[providerId];

  SourceOrigin? get _selectedOrigin => _catalog?.origins
      .where((o) => o.id == _originId && isTvboxSubscriptionOrigin(o))
      .firstOrNull;

  Future<void> _editOrigin(SourceOrigin origin) async {
    final changed = await showAppDialog<bool>(
      context: context,
      builder: (_) => SourceAddressDialog(
        origin: origin,
        onSave: (name, primary, backups) async {
          await SourinApi.sourceCatalogSetOrigin(
            origin.id,
            name: name,
            primaryUrl: primary,
            backupUrls: backups,
          );
          widget.onSourcesChanged();
        },
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _installJs() async {
    final changed = await showAppDialog<bool>(
      context: context,
      builder: (_) => SourceAddressDialog(
        origin: const SourceOrigin(id: '', kind: 'js'),
        title: '安装 JS',
        onSave: (name, primary, backups) async {
          await SourinApi.installPlugin(
            primary,
            name: name,
            backupUrls: backups,
          );
          widget.onSourcesChanged();
        },
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _importLive() async {
    final changed = await showAppDialog<bool>(
      context: context,
      builder: (_) => SourceAddressDialog(
        origin: const SourceOrigin(id: '', kind: 'live'),
        title: '添加直播',
        onSave: (name, primary, backups) async {
          await SourinApi.importLiveSource(
            primary,
            name: name,
            backupUrls: backups,
          );
          widget.onSourcesChanged();
        },
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _selectProviders(SourceOriginGroup group) async {
    if (_busy) return;
    final changed = await showAppDialog<bool>(
      context: context,
      builder: (_) => SourceProvidersDialog(
        group: group,
        providers: _providers,
        origins: _catalog!.origins,
        onSave: (selected) async {
          await SourinApi.sourceCatalogSelectProviders(group.id, selected);
          widget.onSourcesChanged();
        },
      ),
    );
    if (changed == true && mounted) await _load();
  }

  Future<void> _openOrder() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute<void>(
        builder: (_) => SourceOrderPage(
          providers: managedSourceList(_providers),
          origins: _catalog?.origins ?? const [],
          onSaved: widget.onSourcesChanged,
          onSortBySpeed: widget.onSortBySpeed,
        ),
      ),
    );
    if (mounted) await _load();
  }

  Widget _filters() => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Wrap(
        spacing: Sp.x2,
        runSpacing: Sp.x2,
        children: [
          for (final type in ManagedSourceType.values)
            ui.ChoiceChip(
              key: ValueKey('source-type-${type.name}'),
              label: Text(type.label),
              selected: _type == type,
              onSelected: (_) => setState(() => _type = type),
            ),
          SearchableSourceOriginPicker(
            origins: _catalog?.origins ?? const [],
            selected: _originId,
            onSelected: (id) => setState(() => _originId = id),
          ),
          SizedBox(
            width: 180,
            child: Row(
              children: [
                const Text('状态：'),
                Expanded(
                  child: SettingsDropdown<ManagedSourceStatus>(
                    key: const ValueKey('source-status-filter'),
                    value: _status,
                    options: [
                      for (final status in ManagedSourceStatus.values)
                        SettingsDropdownOption(status, status.label),
                    ],
                    onChanged: (status) => setState(() => _status = status),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      if (_selectedOrigin case final origin?) ...[
        const SizedBox(height: Sp.x3),
        Wrap(
          key: const ValueKey('source-origin-summary'),
          spacing: Sp.x2,
          runSpacing: Sp.x2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              '${origin.name.trim().isEmpty ? 'TVBox 订阅' : origin.name} · ${({...origin.providerIds, ...origin.relatedProviderIds}).length} 个源',
            ),
            ui.TextButton(
              key: const ValueKey('source-origin-edit'),
              onPressed: _busy ? null : () => _editOrigin(origin),
              child: const Text('编辑地址'),
            ),
          ],
        ),
      ],
      const SizedBox(height: Sp.x3),
      ui.TextField(
        key: const ValueKey('source-manager-search'),
        controller: _searchController,
        onChanged: (value) => setState(() => _query = value),
        decoration: const InputDecoration(
          hintText: '搜索源名称',
          prefixIcon: Icon(Icons.search),
        ),
      ),
      const SizedBox(height: Sp.x3),
      Wrap(
        spacing: Sp.x2,
        runSpacing: Sp.x2,
        children: [
          ui.FilledButton.icon(
            onPressed: _busy ? null : () => _run(widget.onImportTvbox),
            icon: const Icon(Icons.add),
            label: const Text('导入 TVBox'),
          ),
          ui.OutlinedButton(
            onPressed: _busy ? null : _installJs,
            child: const Text('安装 JS'),
          ),
          ui.OutlinedButton(
            onPressed: _busy ? null : _importLive,
            child: const Text('添加直播'),
          ),
          ui.OutlinedButton(
            onPressed: _busy ? null : _openOrder,
            child: const Text('调整顺序'),
          ),
          AppMenuButton<String>(
            tooltip: '更多操作',
            onSelected: (value) {
              if (value == 'paste') unawaited(_run(widget.onPasteJs));
              if (value == 'health' && widget.onHealthCheck != null) {
                unawaited(_run(widget.onHealthCheck!));
              }
              if (value == 'reload' && widget.onReload != null) {
                unawaited(_run(widget.onReload!));
              }
              if (value == 'pan') widget.onPanShare?.call();
              if (value == 'auto-update' &&
                  widget.subscriptionSettings != null) {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => SettingsSubPage(
                      title: '订阅自动更新',
                      subtitle: '定时检查 TVBox 订阅并应用更新',
                      children: [widget.subscriptionSettings!],
                    ),
                  ),
                );
              }
              if (value == 'discover') {
                Navigator.of(context).push<void>(
                  MaterialPageRoute<void>(
                    builder: (_) => SourceDiscoveryPage(
                      onSourcesChanged: () {
                        widget.onSourcesChanged();
                        unawaited(_load());
                      },
                    ),
                  ),
                );
              }
            },
            items: [
              if (widget.onHealthCheck != null)
                AppMenuItem(value: 'health', label: '健康检测', enabled: !_busy),
              if (widget.onReload != null)
                AppMenuItem(value: 'reload', label: '重新加载 JS', enabled: !_busy),
              if (widget.subscriptionSettings != null)
                const AppMenuItem(value: 'auto-update', label: '订阅自动更新'),
              if (widget.onPanShare != null)
                const AppMenuItem(value: 'pan', label: '识别网盘链接'),
              const AppMenuItem(value: 'paste', label: '粘贴 JS 源码'),
              const AppMenuItem(value: 'discover', label: 'GitHub 源发现'),
            ],
          ),
          PluginSpeedTestAllButton(
            pluginIds: managedSourceList(_providers)
                .where((p) => p.enabled && p.capabilities.vod)
                .map((p) => p.id)
                .toList(),
            onFinished: widget.onSpeedTestFinished,
          ),
        ],
      ),
      const SizedBox(height: Sp.x3),
    ],
  );

  Widget _sourceRow(ProviderManifest provider) {
    final origin = _originOf(provider.id);
    final group = _groupOf(provider.id);
    return Padding(
      key: ValueKey('managed-source-row-${provider.id}'),
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: miuix.MiuixCard(
        key: ValueKey('managed-source-${provider.id}'),
        child: Padding(
          padding: const EdgeInsets.all(Sp.x4),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      sourceDisplayLabel(provider.name),
                      style: const TextStyle(
                        fontSize: FontSizes.base,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: Sp.x1),
                    Text(
                      '${sourceOriginDescription(origin, provider, origins: _catalog?.origins ?? const [])}${provider.capabilities.live && provider.kind != 'm3u_live' ? ' · 直播' : ''}',
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                    ValueListenableBuilder<DiscoverySnapshot?>(
                      valueListenable: SourceDiscoveryService.current,
                      builder: (context, snapshot, _) {
                        final discovered = snapshot?.candidates
                            .where(
                              (candidate) =>
                                  candidate.installed &&
                                  candidate.providerId == provider.id,
                            )
                            .firstOrNull;
                        if (discovered == null) return const SizedBox.shrink();
                        final repository = discovered.repository.trim();
                        return Text(
                          repository.isEmpty
                              ? '来自 GitHub'
                              : '来自 GitHub · $repository',
                          key: ValueKey('source-github-origin-${provider.id}'),
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                        );
                      },
                    ),
                    if (!provider.working && provider.brokenReason != null)
                      Text(
                        provider.brokenReason!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    Wrap(
                      spacing: Sp.x2,
                      runSpacing: Sp.x1,
                      children: [
                        if (origin != null)
                          ui.TextButton(
                            onPressed: _busy ? null : () => _editOrigin(origin),
                            child: Text(
                              origin.backupUrls.isEmpty
                                  ? '主地址与备用地址'
                                  : '地址 · ${origin.backupUrls.length} 个备用',
                            ),
                          ),
                        if (group != null)
                          ui.TextButton(
                            onPressed: _busy
                                ? null
                                : () => _selectProviders(group),
                            child: Text(
                              '提供方 ${group.selectedProviderIds.length}/${group.providerIds.length}',
                            ),
                          ),
                        if (provider.kind == 'js')
                          ui.TextButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => widget.onEditProvider(provider),
                                  ),
                            child: const Text('编辑 JS'),
                          ),
                        ui.TextButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  await widget.onConfigureProvider(provider);
                                  if (mounted) await _load();
                                },
                          child: const Text('源设置'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: Sp.x3),
              ui.Switch(
                key: ValueKey('source-enabled-${provider.id}'),
                value: provider.enabled,
                onChanged: _busy
                    ? null
                    : (value) => _change(() async {
                        final saved = await SourinApi.setProviderEnabled(
                          provider.id,
                          value,
                        );
                        if (!saved) throw StateError('源已不存在，请重新加载列表');
                      }),
              ),
              AppMenuButton<String>(
                tooltip: '源操作',
                items: const [AppMenuItem(value: 'remove', label: '移除源')],
                onSelected: (_) =>
                    unawaited(_run(() => widget.onRemoveProvider(provider))),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final origin = _selectedOrigin;
    final visible = managedSourceList(
      _providers,
      type: _type,
      status: _status,
      query: _query,
      origin: origin,
    );
    // On touch-sized pages the multi-row filters must share the scroll area
    // with results, so a soft keyboard cannot consume the whole list viewport.
    final scrollFilters = Layout.isNarrow(MediaQuery.sizeOf(context).width);
    final rowStart = scrollFilters ? 2 : 1;
    final rowIndices = <Key, int>{
      for (final (index, provider) in visible.indexed)
        ValueKey('managed-source-row-${provider.id}'): index + rowStart,
    };
    return SettingsSubPage(
      title: '源',
      subtitle: '启用、来源与地址 · 调整后立即应用到首页和搜索',
      pinnedHeader: scrollFilters ? null : _filters(),
      scrollBody: ListView.builder(
        key: const PageStorageKey('source-manager-list'),
        padding: EdgeInsets.only(bottom: Sp.bottomBarInset),
        itemCount: visible.length + rowStart,
        findChildIndexCallback: (key) =>
            scrollFilters && key == const ValueKey('source-manager-filters')
            ? 0
            : key == const ValueKey('source-manager-status')
            ? rowStart - 1
            : rowIndices[key],
        itemBuilder: (context, index) {
          if (scrollFilters && index == 0) {
            return KeyedSubtree(
              key: const ValueKey('source-manager-filters'),
              child: _filters(),
            );
          }
          if (index >= rowStart) return _sourceRow(visible[index - rowStart]);
          return Column(
            key: const ValueKey('source-manager-status'),
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (_loading || _busy)
                TickerMode(
                  // Import/edit dialogs own their progress while covering this page.
                  enabled: ModalRoute.isCurrentOf(context) ?? true,
                  child: const miuix.MiuixLinearProgressIndicator(),
                ),
              if (widget.activity != null) widget.activity!,
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: Sp.x3),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                      const SizedBox(height: Sp.x2),
                      ui.TextButton(
                        key: const ValueKey('source-manager-retry'),
                        onPressed: _loading || _busy ? null : _retryLoad,
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                ),
              if (!_loading && _error == null && visible.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(Sp.x6),
                  child: Text('没有匹配的源'),
                ),
            ],
          );
        },
      ),
    );
  }
}

/// A searchable dropdown is scoped to the anchor's overlay. The field and
/// results remain in one popover instead of navigating to another screen.
class SearchableSourceOriginPicker extends StatelessWidget {
  const SearchableSourceOriginPicker({
    super.key,
    required this.origins,
    required this.selected,
    required this.onSelected,
  });
  final List<SourceOrigin> origins;
  final String? selected;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) => Builder(
    builder: (anchor) {
      final subscriptions = origins
          .where(isTvboxSubscriptionOrigin)
          .toList(growable: false);
      final name = subscriptions
          .where((o) => o.id == selected)
          .firstOrNull
          ?.name;
      return ui.OutlinedButton(
        key: const ValueKey('source-origin-picker'),
        onPressed: () async {
          final box = anchor.findRenderObject() as RenderBox?;
          final overlay =
              Overlay.of(anchor).context.findRenderObject() as RenderBox?;
          if (box == null || overlay == null) return;
          final rect =
              box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
          final themes = InheritedTheme.capture(
            from: context,
            to: Navigator.of(context, rootNavigator: true).context,
          );
          final id = await showGeneralDialog<String>(
            context: context,
            barrierColor: Colors.transparent,
            transitionDuration: Duration.zero,
            pageBuilder: (_, __, ___) => themes.wrap(
              _SourceOriginPopup(
                anchor: rect,
                origins: subscriptions,
                selected: selected,
              ),
            ),
          );
          if (id != null) onSelected(id.isEmpty ? null : id);
        },
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                name ?? '全部聚合来源',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const Icon(Icons.arrow_drop_down),
          ],
        ),
      );
    },
  );
}

class _SourceOriginPopup extends StatefulWidget {
  const _SourceOriginPopup({
    required this.anchor,
    required this.origins,
    required this.selected,
  });
  final Rect anchor;
  final List<SourceOrigin> origins;
  final String? selected;
  @override
  State<_SourceOriginPopup> createState() => _SourceOriginPopupState();
}

class _SourceOriginPopupState extends State<_SourceOriginPopup> {
  bool _show = true;
  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final viewport = Rect.fromLTRB(
      math.max(media.viewPadding.left, media.viewInsets.left),
      math.max(media.viewPadding.top, media.viewInsets.top),
      media.size.width -
          math.max(media.viewPadding.right, media.viewInsets.right),
      media.size.height -
          math.max(media.viewPadding.bottom, media.viewInsets.bottom),
    );
    return miuix.MiuixWindowListPopup(
      show: _show,
      anchorBounds: widget.anchor,
      alignment: miuix.MiuixPopupAlign.start,
      // The window-level host uses its root overlay's full-screen MediaQuery.
      // Keep this editor's popup inside the actual keyboard-free viewport.
      popupPositionProvider: _SourceOriginPopupPositionProvider(viewport),
      enableWindowDim: false,
      maxHeight: math.max(
        miuix.MiuixListPopupDefaults.minPopupHeight,
        viewport.height - Sp.x6,
      ),
      minWidth: 280,
      onDismissRequest: () => setState(() => _show = false),
      onDismissFinished: () {
        if (mounted) Navigator.of(context).pop();
      },
      surfaceBuilder: (_, __, child) => miuix.MiuixCard(child: child),
      content: Padding(
        padding: const EdgeInsets.all(Sp.x3),
        child: _OriginSearchResults(
          origins: widget.origins,
          selected: widget.selected,
        ),
      ),
    );
  }
}

class _SourceOriginPopupPositionProvider
    implements miuix.MiuixPopupPositionProvider {
  const _SourceOriginPopupPositionProvider(this.viewport);
  final Rect viewport;

  @override
  EdgeInsetsGeometry get margins =>
      miuix.MiuixListPopupDefaults.dropdownPosition.margins;

  @override
  Offset calculatePosition({
    required Rect anchorBounds,
    required Rect windowBounds,
    required TextDirection textDirection,
    required Size popupContentSize,
    required EdgeInsets popupMargin,
    required miuix.MiuixPopupAlign alignment,
  }) => miuix.MiuixListPopupDefaults.dropdownPosition.calculatePosition(
    anchorBounds: anchorBounds,
    windowBounds: windowBounds.intersect(viewport),
    textDirection: textDirection,
    popupContentSize: popupContentSize,
    popupMargin: popupMargin,
    alignment: alignment,
  );
}

class _OriginSearchResults extends StatefulWidget {
  const _OriginSearchResults({required this.origins, required this.selected});
  final List<SourceOrigin> origins;
  final String? selected;
  @override
  State<_OriginSearchResults> createState() => _OriginSearchResultsState();
}

class _OriginSearchResultsState extends State<_OriginSearchResults> {
  String _query = '';
  @override
  Widget build(BuildContext context) {
    final matches = widget.origins
        .where(
          (o) => '${o.name} ${o.kind}'.toLowerCase().contains(
            _query.toLowerCase(),
          ),
        )
        .toList();
    return SizedBox(
      width: 280,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ui.TextField(
            autofocus: true,
            onChanged: (value) => setState(() => _query = value),
            decoration: const InputDecoration(hintText: '搜索聚合来源'),
          ),
          Flexible(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 280),
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    ui.ListTile(
                      title: const Text('全部聚合来源'),
                      onTap: () => Navigator.of(context).pop(''),
                    ),
                    for (final origin in matches)
                      ui.ListTile(
                        key: ValueKey('source-origin-option-${origin.id}'),
                        title: Text(origin.name),
                        subtitle: Text(
                          '${origin.kind.toUpperCase()} · ${({...origin.providerIds, ...origin.relatedProviderIds}).length} 个源',
                        ),
                        trailing: origin.id == widget.selected
                            ? const Icon(Icons.check)
                            : null,
                        onTap: () => Navigator.of(context).pop(origin.id),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class SourceAddressDialog extends StatefulWidget {
  const SourceAddressDialog({
    super.key,
    required this.origin,
    this.title = '来源与地址',
    this.onSave,
  });
  final SourceOrigin origin;
  final String title;
  final Future<void> Function(
    String name,
    String primary,
    List<String> backups,
  )?
  onSave;
  @override
  State<SourceAddressDialog> createState() => _SourceAddressDialogState();
}

class _SourceAddressDialogState extends State<SourceAddressDialog> {
  late final _name = TextEditingController(text: widget.origin.name);
  late final _primary = TextEditingController(text: widget.origin.primaryUrl);
  late final _backups = TextEditingController(
    text: widget.origin.backupUrls.join('\n'),
  );
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _primary.dispose();
    _backups.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final backups = sourceBackupUrls(_backups.text);
      if (backups.length > 8) throw const FormatException('备用地址最多 8 个');
      if (widget.onSave != null) {
        await widget.onSave!(_name.text.trim(), _primary.text.trim(), backups);
      } else {
        await SourinApi.sourceCatalogSetOrigin(
          widget.origin.id,
          name: _name.text.trim(),
          primaryUrl: _primary.text.trim(),
          backupUrls: backups,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted)
        setState(() {
          _saving = false;
          _error = userErrorText(e);
        });
    }
  }

  @override
  Widget build(BuildContext context) => AppDialogShell(
    title: widget.title,
    subtitle: '主地址不可用时，按顺序尝试备用地址',
    onClose: _saving ? null : () => Navigator.of(context).pop(),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SourceAddressFields(
          name: _name,
          primary: _primary,
          backups: _backups,
          enabled: !_saving,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x3),
            child: Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
      ],
    ),
    actions: ui.FilledButton(
      onPressed: _saving ? null : _save,
      child: Text(_saving ? '正在保存…' : '保存'),
    ),
  );
}

class SourceProvidersDialog extends StatefulWidget {
  const SourceProvidersDialog({
    super.key,
    required this.group,
    required this.providers,
    required this.origins,
    required this.onSave,
  });
  final SourceOriginGroup group;
  final List<ProviderManifest> providers;
  final List<SourceOrigin> origins;
  final Future<void> Function(List<String>) onSave;
  @override
  State<SourceProvidersDialog> createState() => _SourceProvidersDialogState();
}

class _SourceProvidersDialogState extends State<SourceProvidersDialog> {
  late final Set<String> _selected = widget.group.selectedProviderIds.toSet();
  bool _saving = false;
  String? _error;

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSave(
        widget.group.providerIds.where(_selected.contains).toList(),
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userErrorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AppDialogShell(
      title: '${sourceDisplayLabel(widget.group.name)} · 提供方',
      subtitle: '可选一个或多个；全部取消会关闭这个源',
      onClose: () => Navigator.of(context).pop(),
      closeEnabled: !_saving,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              ui.TextButton(
                onPressed: _saving
                    ? null
                    : () => setState(
                        () => _selected.addAll(widget.group.providerIds),
                      ),
                child: const Text('全部启用'),
              ),
              ui.TextButton(
                onPressed: _saving ? null : () => setState(_selected.clear),
                child: const Text('全部关闭'),
              ),
            ],
          ),
          for (final id in widget.group.providerIds)
            miuix.MiuixSwitchPreference(
              key: ValueKey('source-provider-choice-$id'),
              title:
                  widget.origins
                      .where((o) => o.providerIds.contains(id))
                      .firstOrNull
                      ?.name ??
                  id,
              summary: widget.providers
                  .where((p) => p.id == id)
                  .firstOrNull
                  ?.name,
              value: _selected.contains(id),
              enabled: !_saving,
              onChanged: (value) => setState(() {
                if (_saving) return;
                value ? _selected.add(id) : _selected.remove(id);
              }),
            ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: Sp.x3),
              child: Text(
                _error!,
                key: const ValueKey('source-providers-error'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
      actions: ui.FilledButton(
        onPressed: _saving ? null : _save,
        child: Text(_saving ? '正在保存…' : '保存'),
      ),
    ),
  );
}

class SourceOrderPage extends StatefulWidget {
  const SourceOrderPage({
    super.key,
    required this.providers,
    required this.origins,
    required this.onSaved,
    this.onSortBySpeed,
  });
  final List<ProviderManifest> providers;
  final List<SourceOrigin> origins;
  final VoidCallback onSaved;
  final Future<void> Function()? onSortBySpeed;
  @override
  State<SourceOrderPage> createState() => _SourceOrderPageState();
}

class _SourceOrderPageState extends State<SourceOrderPage> {
  late final _draft = [...widget.providers];
  bool _saving = false;
  String? _error;
  Future<void> _sortBySpeed() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.onSortBySpeed!();
      final providers = await SourinApi.listProviders();
      if (!mounted) return;
      setState(() {
        _draft
          ..clear()
          ..addAll(managedSourceList(providers));
      });
      // The delegated sort reports a successful save itself. It may also
      // return without writing when there are no measurements to sort by.
    } catch (e) {
      if (mounted) setState(() => _error = userErrorText(e));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  void _move(int from, int to) {
    if (_saving ||
        from < 0 ||
        from >= _draft.length ||
        to < 0 ||
        to >= _draft.length ||
        from == to) {
      return;
    }
    setState(() => _draft.insert(to, _draft.removeAt(from)));
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await SourinApi.setProviderOrder(_draft.map((p) => p.id).toList());
      widget.onSaved();
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = userErrorText(e);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => SettingsSubPage(
    title: '源排序',
    subtitle: '拖动或使用箭头调整首页与搜索的源顺序，每项均显示来源',
    pinnedHeader: Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: Row(
        children: [
          ui.FilledButton(
            onPressed: _saving ? null : _save,
            child: Text(_saving ? '正在保存…' : '保存顺序'),
          ),
          if (widget.onSortBySpeed != null) ...[
            const SizedBox(width: Sp.x3),
            ui.TextButton(
              onPressed: _saving ? null : _sortBySpeed,
              child: const Text('按速度排序'),
            ),
          ],
          if (_error != null)
            Expanded(
              child: Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
        ],
      ),
    ),
    scrollBody: ReorderableListView.builder(
      padding: EdgeInsets.only(bottom: Sp.bottomBarInset),
      buildDefaultDragHandles: false,
      itemCount: _draft.length,
      onReorder: (oldIndex, newIndex) {
        _move(oldIndex, newIndex > oldIndex ? newIndex - 1 : newIndex);
      },
      itemBuilder: (context, index) {
        final provider = _draft[index];
        final origin = widget.origins
            .where((o) => o.providerIds.contains(provider.id))
            .firstOrNull;
        return Padding(
          key: ValueKey(provider.id),
          padding: const EdgeInsets.only(bottom: Sp.x3),
          child: miuix.MiuixCard(
            child: ui.ListTile(
              title: Text(sourceDisplayLabel(provider.name)),
              subtitle: Text(
                '${sourceOriginDescription(origin, provider, origins: widget.origins)}${provider.enabled ? '' : ' · 已关闭'}',
              ),
              leading: Text('${index + 1}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ui.IconButton(
                    key: ValueKey('source-order-up-${provider.id}'),
                    tooltip: '上移',
                    onPressed: _saving || index == 0
                        ? null
                        : () => _move(index, index - 1),
                    icon: const Icon(Icons.keyboard_arrow_up),
                  ),
                  ui.IconButton(
                    key: ValueKey('source-order-down-${provider.id}'),
                    tooltip: '下移',
                    onPressed: _saving || index == _draft.length - 1
                        ? null
                        : () => _move(index, index + 1),
                    icon: const Icon(Icons.keyboard_arrow_down),
                  ),
                  ReorderableDragStartListener(
                    key: ValueKey('source-order-drag-${provider.id}'),
                    index: index,
                    enabled: !_saving,
                    child: const ui.Tooltip(
                      message: '拖动排序',
                      child: Padding(
                        padding: EdgeInsets.all(Sp.x3),
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );
}
