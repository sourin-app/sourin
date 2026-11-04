import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/ffi.dart' show userErrorText;
import '../../design/widgets/app_glass_dialog.dart';
import '../widgets/overlay_motion.dart';
import 'webhome_store.dart';

Future<bool> showWebHomeTemplateEditor(
  BuildContext context, {
  WebHomeTemplate? template,
  WebHomeController? controller,
}) async =>
    await showAppDialog<bool>(
      context: context,
      builder: (_) => WebHomeTemplateEditor(
        template: template,
        controller: controller ?? WebHomeController.instance,
      ),
    ) ??
    false;

/// Compatibility entry; homepage views no longer mount this action.
Future<void> showWebHomeSettingsSheet(BuildContext context) async {
  await showWebHomeTemplateEditor(context);
}

class WebHomeTemplateEditor extends StatefulWidget {
  const WebHomeTemplateEditor({
    super.key,
    this.template,
    required this.controller,
  });

  final WebHomeTemplate? template;
  final WebHomeController controller;

  @override
  State<WebHomeTemplateEditor> createState() => _WebHomeTemplateEditorState();
}

class _WebHomeTemplateEditorState extends State<WebHomeTemplateEditor> {
  final _name = TextEditingController();
  final _html = TextEditingController();
  final _path = TextEditingController();
  bool _busy = false;
  bool _activate = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _name.text = widget.template?.name ?? '';
    if (widget.template != null) _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      _html.text = await widget.controller.readTemplate(widget.template!.id);
    } catch (e) {
      if (mounted) {
        setState(() => _error = userErrorText(e, fallback: '读取首页配置失败，请稍后重试'));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _import() async {
    if (_path.text.trim().isEmpty) {
      setState(() => _error = '请填写 HTML 文件路径');
      return;
    }
    setState(() => _busy = true);
    try {
      final file = File(_path.text.trim());
      if (await file.length() > webhomeHtmlMaxBytes) {
        throw const FormatException('HTML exceeds size limit');
      }
      final html = await file.readAsString();
      if (!webhomeHtmlAcceptable(html)) {
        if (mounted) setState(() => _error = 'HTML 不能为空，且不能超过 2MB');
        return;
      }
      if (!mounted) return;
      _html.text = html;
      if (_name.text.trim().isEmpty) {
        _name.text = file.uri.pathSegments.last.replaceFirst(
          RegExp(r'\.html?$', caseSensitive: false),
          '',
        );
      }
      setState(() => _error = null);
    } catch (e) {
      AppLog.write('WEBHOME', 'import from file failed: $e');
      if (mounted) {
        setState(
          () => _error = userErrorText(e, fallback: '读取 HTML 文件失败，请检查路径或文件大小'),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_name.text.trim().isEmpty || _name.text.trim().length > 128) {
      setState(() => _error = '请填写首页名称（最多 128 个字符）');
      return;
    }
    if (!webhomeHtmlAcceptable(_html.text)) {
      setState(() => _error = 'HTML 不能为空，且不能超过 2MB');
      return;
    }
    setState(() => _busy = true);
    final saved = await widget.controller.saveTemplate(
      id: widget.template?.id,
      name: _name.text,
      html: _html.text,
      activate: _activate,
    );
    if (!mounted) return;
    if (saved != null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _busy = false;
        _error = widget.controller.lastStorageError ?? '保存失败，请稍后重试';
      });
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _html.dispose();
    _path.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: AppGlassDialog(
      title: widget.template == null ? '添加 HTML 首页' : '编辑 HTML 首页',
      maxWidth: 680,
      content: SizedBox(
        width: 620,
        height: (MediaQuery.sizeOf(context).height * 0.6).clamp(240.0, 420.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextField(
              key: const ValueKey<String>('webhome-template-name'),
              controller: _name,
              enabled: !_busy,
              decoration: const InputDecoration(labelText: '首页名称'),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: const ValueKey<String>('webhome-template-path'),
                    controller: _path,
                    enabled: !_busy,
                    decoration: const InputDecoration(labelText: 'HTML 文件路径'),
                  ),
                ),
                IconButton(
                  tooltip: '载入 HTML 文件',
                  onPressed: _busy ? null : _import,
                  icon: const Icon(Icons.file_open_outlined),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: TextField(
                key: const ValueKey<String>('webhome-template-html'),
                controller: _html,
                enabled: !_busy,
                maxLines: null,
                expands: true,
                decoration: const InputDecoration(
                  labelText: 'HTML 内容',
                  alignLabelWithHint: true,
                ),
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
              ),
            ),
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                value: _activate,
                onChanged: _busy
                    ? null
                    : (value) => setState(() => _activate = value == true),
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: const Text('保存后启用'),
              ),
            ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
          ],
        ),
      ),
      actions: Wrap(
        spacing: 8,
        children: [
          TextButton(
            onPressed: _busy ? null : () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            key: const ValueKey<String>('webhome-template-save'),
            onPressed: _busy ? null : _save,
            icon: const Icon(Icons.save_outlined),
            label: Text(_busy ? '保存中…' : '保存'),
          ),
        ],
      ),
    ),
  );
}
