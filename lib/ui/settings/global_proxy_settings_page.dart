import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart';
import '../../core/sourin_api.dart';
import '../widgets/miuix_controls.dart' as ui;
import '../widgets/proxy_panel.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';

class GlobalProxySettingsPage extends StatefulWidget {
  const GlobalProxySettingsPage({super.key});
  @override
  State<GlobalProxySettingsPage> createState() =>
      _GlobalProxySettingsPageState();
}

class _GlobalProxySettingsPageState extends State<GlobalProxySettingsPage> {
  List<Map<String, dynamic>> _choices = const [];
  String? _error;
  int _revision = 0;
  bool _migrationResolved = false;

  @override
  void initState() {
    super.initState();
    _loadChoices();
  }

  Future<void> _loadChoices() async {
    try {
      final value = await SourinCore.callAsync(
        'global_proxy_migration_choices',
      );
      if (mounted && !_migrationResolved) {
        setState(
          () => _choices = (value as List)
              .map((e) => Map<String, dynamic>.from(e as Map))
              .toList(),
        );
      }
    } catch (e) {
      if (mounted && !_migrationResolved) {
        setState(() => _error = userErrorText(e));
      }
    }
  }

  Future<void> _choose(Map<String, dynamic> choice) async {
    try {
      await SourinApi.setProxyConfig(
        SourinApi.globalProxyProvider,
        ProxyConfig.fromJson(
          Map<String, dynamic>.from(choice['config'] as Map),
        ),
      );
      if (mounted) {
        setState(() {
          _migrationResolved = true;
          _choices = const [];
          _error = null;
          _revision++;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = userErrorText(e));
    }
  }

  void _onSaved() {
    setState(() {
      _migrationResolved = true;
      _choices = const [];
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) => SettingsSubPage(
    title: '全局代理',
    subtitle: '视频源、弹幕、更新下载和 GitHub 源发现共用',
    children: [
      if (_choices.isNotEmpty)
        SettingsBlock(
          title: '选择沿用的代理',
          children: [
            const Text('检测到多个不同的旧代理配置。选择一个统一使用，或在下方填写并保存新的配置。'),
            for (final choice in _choices)
              ui.OutlinedButton(
                onPressed: () => _choose(choice),
                child: Text(
                  '${choice['source']} · ${(choice['config'] as Map)['url'] ?? '跟随系统'}',
                ),
              ),
          ],
        ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      SettingsBlock(
        key: const ValueKey('global-proxy-connection-settings'),
        title: '连接设置',
        children: [
          ProxyPanel(
            key: ValueKey(_revision),
            providerId: SourinApi.globalProxyProvider,
            providerName: '全局',
            defaultOpen: true,
            onSaved: _onSaved,
          ),
        ],
      ),
      const Text(
        'GitHub 发现与校验始终经过代理；未配置或连接失败时停止。'
        '本机弹幕服务直连。视频是否经过代理由作用范围决定。',
      ),
    ],
  );
}
