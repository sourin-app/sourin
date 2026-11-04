import 'package:material_ui/material_ui.dart';

import '../../design/widgets/app_glass_dialog.dart';
import '../widgets/overlay_motion.dart';
import '../widgets/settings_sub_page.dart';
import 'webhome_settings_sheet.dart';
import 'webhome_store.dart';

class WebHomeSettingsPage extends StatefulWidget {
  const WebHomeSettingsPage({super.key});

  @override
  State<WebHomeSettingsPage> createState() => _WebHomeSettingsPageState();
}

class _WebHomeSettingsPageState extends State<WebHomeSettingsPage> {
  final _controller = WebHomeController.instance;
  bool _loading = true;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_changed);
    _load();
  }

  Future<void> _load() async {
    await _controller.ensureLoaded();
    if (mounted) setState(() => _loading = false);
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _select(String? id) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (id == null) {
        await _controller.disable();
      } else if (!await _controller.activateTemplate(id)) {
        _error = _controller.lastStorageError ?? '启用失败，请稍后重试';
      }
    } catch (_) {
      _error = '切换失败，原配置已保留';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(WebHomeTemplate template) async {
    final confirmed = await showAppDialog<bool>(
      context: context,
      builder: (context) => AppGlassDialog(
        title: '删除首页',
        content: Text(
          _controller.activeId == template.id && _controller.enabled
              ? '删除“${template.name}”后将使用原生首页。'
              : '删除“${template.name}”？',
        ),
        actions: Wrap(
          spacing: 8,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    final ok = await _controller.deleteTemplate(template.id);
    if (mounted) {
      setState(() {
        _busy = false;
        _error = ok ? null : _controller.lastStorageError;
      });
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SettingsSubPage(
    title: '自定义 HTML 首页',
    subtitle: '${_controller.templates.length} 个配置',
    children: [
      if (_loading)
        const Center(child: CircularProgressIndicator())
      else ...[
        Wrap(
          spacing: 8,
          children: [
            FilledButton.icon(
              key: const ValueKey<String>('webhome-add-template'),
              onPressed: _busy
                  ? null
                  : () => showWebHomeTemplateEditor(context),
              icon: const Icon(Icons.add),
              label: const Text('添加首页'),
            ),
            IconButton(
              tooltip: '重新读取配置',
              onPressed: _busy ? null : () => _controller.reload(),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Material(
          type: MaterialType.transparency,
          child: ListTile(
            key: const ValueKey<String>('webhome-native'),
            leading: Icon(
              !_controller.enabled
                  ? Icons.radio_button_checked
                  : Icons.radio_button_unchecked,
            ),
            title: const Text('原生首页'),
            onTap: _busy ? null : () => _select(null),
          ),
        ),
        for (final template in _controller.templates)
          Material(
            type: MaterialType.transparency,
            child: ListTile(
              key: ValueKey<String>('webhome-template-${template.id}'),
              leading: Icon(
                _controller.enabled && _controller.activeId == template.id
                    ? Icons.radio_button_checked
                    : Icons.radio_button_unchecked,
              ),
              title: Text(
                template.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              onTap: _busy ? null : () => _select(template.id),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '编辑首页',
                    onPressed: _busy
                        ? null
                        : () => showWebHomeTemplateEditor(
                            context,
                            template: template,
                          ),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: '删除首页',
                    onPressed: _busy ? null : () => _delete(template),
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          ),
        if (_controller.lastStorageError != null || _error != null)
          Text(
            _error ?? _controller.lastStorageError!,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        if (_controller.fallbackThisSession && _controller.enabled)
          Text(
            _controller.lastFallbackReason == 'user-request'
                ? '本次会话已使用原生首页'
                : '当前配置加载失败，本次会话已回到原生首页',
          ),
      ],
    ],
  );
}
