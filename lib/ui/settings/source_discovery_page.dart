import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import '../../core/ffi.dart' show userErrorText;
import '../../core/source_discovery.dart';
import '../app_scaffold.dart';
import '../tokens.dart';
import '../widgets/miuix_controls.dart' as ui;
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';
import 'global_proxy_settings_page.dart';

class SourceDiscoveryPage extends StatefulWidget {
  const SourceDiscoveryPage({super.key, this.onSourcesChanged});
  final VoidCallback? onSourcesChanged;
  @override
  State<SourceDiscoveryPage> createState() => _SourceDiscoveryPageState();
}

class _SourceDiscoveryPageState extends State<SourceDiscoveryPage> {
  bool? _automatic;
  bool _busy = false;
  int _actionRevision = 0;
  String? _error;
  Timer? _poll;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
    _poll = Timer.periodic(const Duration(seconds: 5), (_) {
      if (SourceDiscoveryService.current.value?.running ?? false) {
        unawaited(_load());
      }
    });
  }

  Future<void> _load() async {
    final revision = _actionRevision;
    try {
      await SourceDiscoveryService.refresh();
    } catch (e) {
      if (mounted && revision == _actionRevision) {
        setState(() => _error = userErrorText(e));
      }
    }
  }

  Future<void> _saveAutomatic() async {
    try {
      await SourceDiscoveryService.configure(
        _automatic ?? SourceDiscoveryService.current.value?.automatic ?? false,
      );
    } finally {
      // Once saving settles, show the confirmed setting. A rejected save must
      // not leave an unsaved switch value looking like the active preference.
      if (mounted) setState(() => _automatic = null);
    }
  }

  Future<void> _run(Future<void> Function() work) async {
    if (_busy) return;
    _actionRevision++;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await work();
    } catch (e) {
      if (mounted) setState(() => _error = userErrorText(e));
    } finally {
      _actionRevision++;
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(
    BuildContext context,
  ) => ValueListenableBuilder<DiscoverySnapshot?>(
    valueListenable: SourceDiscoveryService.current,
    builder: (context, data, _) => SettingsSubPage(
      title: 'GitHub 源发现',
      subtitle: '代理发现与校验 · 通过后由你启用',
      children: [
        SettingsBlock(
          title: '发现设置',
          children: [
            ui.OutlinedButton.icon(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => const GlobalProxySettingsPage(),
                ),
              ),
              icon: const Icon(Icons.vpn_lock_outlined),
              label: const Text('全局代理设置'),
            ),
            const SizedBox(height: Sp.x3),
            const Text('跟随全局代理。所有发现与校验请求必须经过代理，代理不可用时停止。'),
            miuix.MiuixSwitchPreference(
              title: '每天自动发现',
              summary: '应用运行时检查，发现结果先进入候选列表',
              insideMargin: EdgeInsets.zero,
              enabled: !_busy,
              value: _automatic ?? data?.automatic ?? false,
              onChanged: (v) {
                if (!_busy) setState(() => _automatic = v);
              },
            ),
            Wrap(
              spacing: Sp.x3,
              runSpacing: Sp.x2,
              children: [
                ui.OutlinedButton(
                  onPressed: _busy
                      ? null
                      : () => _run(_saveAutomatic),
                  child: const Text('保存设置'),
                ),
                ui.FilledButton(
                  onPressed: _busy || (data?.running ?? false)
                      ? null
                      : () => _run(() async {
                          await _saveAutomatic();
                          await SourceDiscoveryService.scan();
                        }),
                  child: Text(
                    _busy || (data?.running ?? false) ? '正在处理…' : '发现并校验',
                  ),
                ),
              ],
            ),
            if (_busy || (data?.running ?? false))
              const Padding(
                padding: EdgeInsets.only(top: Sp.x3),
                child: miuix.MiuixLinearProgressIndicator(),
              ),
            if (_error != null || (data?.lastError.isNotEmpty ?? false))
              Padding(
                padding: const EdgeInsets.only(top: Sp.x3),
                child: Text(
                  _error ?? data!.lastError,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
        if (data != null && data.notices.isNotEmpty)
          SettingsBlock(
            title: '消息 · ${data.unread} 条未读',
            trailing: ui.TextButton(
              onPressed: () => _run(() async {
                await SourceDiscoveryService.markRead();
              }),
              child: const Text('全部已读'),
            ),
            children: [
              for (final n in data.notices.take(8))
                miuix.MiuixBasicComponent(
                  insideMargin: const EdgeInsets.symmetric(vertical: Sp.x2),
                  startAction: Icon(
                    n.unread
                        ? Icons.notifications_active_outlined
                        : Icons.notifications_none,
                  ),
                  title: n.text,
                  summary: _date(n.at),
                ),
            ],
          ),
        Text(
          '候选源 · ${data?.candidates.length ?? 0}',
          style: const TextStyle(
            fontSize: FontSizes.lg,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: Sp.x3),
        const Text('分类与内容接口通过校验才可启用。此检查不代表所有影片都能播放；需要执行专用脚本的源暂不自动校验。'),
        const SizedBox(height: Sp.x3),
        if (data?.candidates.isEmpty ?? true) const Text('尚无候选。设置全局代理后开始发现。'),
        for (final c in data?.candidates ?? <DiscoveredSource>[])
          SettingsBlock(
            title: c.name,
            trailing: ui.FilledButton(
              onPressed: !_busy && c.canEnable
                  ? () => _run(() async {
                      await SourceDiscoveryService.enable(c.id);
                      widget.onSourcesChanged?.call();
                    })
                  : null,
              child: Text(
                c.installed
                    ? '已加入源页面'
                    : c.canEnable
                    ? '启用'
                    : '暂不可用',
              ),
            ),
            children: [
              Text('来自 GitHub · ${c.repository}'),
              const SizedBox(height: Sp.x2),
              Text(c.message),
              Text(
                '校验时间：${_date(c.checkedAt)}',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
      ],
    ),
  );
}

String _date(int seconds) => seconds <= 0
    ? '尚未检查'
    : DateTime.fromMillisecondsSinceEpoch(seconds * 1000)
          .toLocal()
          .toString()
          .split('.')
          .first;

/// Local status polling surfaces persisted notices without issuing discovery requests.
class SourceDiscoveryEntry extends StatefulWidget {
  const SourceDiscoveryEntry({
    super.key,
    this.noticeOnly = false,
    this.onSourcesChanged,
  });
  final bool noticeOnly;
  final VoidCallback? onSourcesChanged;
  @override
  State<SourceDiscoveryEntry> createState() => _SourceDiscoveryEntryState();
}

class _SourceDiscoveryEntryState extends State<SourceDiscoveryEntry> {
  Timer? _poll;
  void _refresh() {
    unawaited(
      SourceDiscoveryService.refresh().then<void>(
        (_) {},
        onError: (Object _) {},
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _refresh();
    _poll = Timer.periodic(const Duration(minutes: 1), (_) => _refresh());
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<DiscoverySnapshot?>(
        valueListenable: SourceDiscoveryService.current,
        builder: (context, data, _) {
          if (widget.noticeOnly && (data?.unread ?? 0) == 0) {
            return const SizedBox.shrink();
          }
          return SettingsEntryRow(
            icon: Icons.travel_explore,
            title: widget.noticeOnly
                ? '源发现 · ${data!.unread} 条新消息'
                : 'GitHub 源发现',
            subtitle: data != null && data.unread > 0
                ? data.notices.first.text
                : '代理发现 / 校验 / 手动启用',
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AppScaffold(
                  child: SourceDiscoveryPage(
                    onSourcesChanged: widget.onSourcesChanged,
                  ),
                ),
              ),
            ),
          );
        },
      );
}

class GithubSourceOrigin extends StatelessWidget {
  const GithubSourceOrigin({super.key, required this.providerId});
  final String providerId;
  @override
  Widget build(BuildContext context) =>
      ValueListenableBuilder<DiscoverySnapshot?>(
        valueListenable: SourceDiscoveryService.current,
        builder: (context, data, _) {
          final matches = data?.candidates.where(
            (c) => c.providerId == providerId,
          );
          final origin = matches != null && matches.isNotEmpty
              ? matches.first.repository
              : null;
          if (origin == null && !providerId.startsWith('github-')) {
            return const SizedBox.shrink();
          }
          return Text(
            origin == null ? '来自 GitHub' : '来自 GitHub · $origin',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: Theme.of(context).colorScheme.primary,
            ),
          );
        },
      );
}
