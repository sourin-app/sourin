// ═══════════════════════════════════════════════════════════════════════
//  T6 webHome：设置面板 + 原生首页的入口按钮
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么不进 settings_page
// settings_page.dart 是他人在制品（P1/P3），本批改动清单限定
// 「新文件 + home_page 接入点 + pubspec」—— 面板做成独立文件，
// 入口按钮由 home_page 浮层与 webhome_page 工具条两处挂。
//
// # HTML 来源（V1）
// 粘贴 / 本地文件路径（零新依赖，不引 file_picker）；
// 远程 URL 一期明确不做（供应链面，见设计书第五节）。
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../core/app_log.dart';
import '../../core/ffi.dart' show userErrorText;
import 'webhome_store.dart';

/// 打开 webHome 设置面板
Future<void> showWebHomeSettingsSheet(BuildContext context) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => const _WebHomeSettingsSheet(),
  );
}

/// 原生首页右上角的浮层入口（home_page 挂）
class WebHomeEntryButton extends StatelessWidget {
  const WebHomeEntryButton({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: colors.surface.withValues(alpha: 0.75),
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => showWebHomeSettingsSheet(context),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(Icons.tune, size: 18, color: colors.onSurface),
        ),
      ),
    );
  }
}

class _WebHomeSettingsSheet extends StatefulWidget {
  const _WebHomeSettingsSheet();

  @override
  State<_WebHomeSettingsSheet> createState() => _WebHomeSettingsSheetState();
}

class _WebHomeSettingsSheetState extends State<_WebHomeSettingsSheet> {
  final _htmlCtrl = TextEditingController();
  final _pathCtrl = TextEditingController();
  String? _status;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    final c = WebHomeController.instance;
    // ensureLoaded 早已被 home_page 触发；这里只回填现有值。
    _htmlCtrl.text = c.html;
  }

  @override
  void dispose() {
    _htmlCtrl.dispose();
    _pathCtrl.dispose();
    super.dispose();
  }

  Future<void> _importFromFile() async {
    final path = _pathCtrl.text.trim();
    if (path.isEmpty) {
      setState(() => _status = '先填 HTML 文件路径');
      return;
    }
    try {
      final f = File(path);
      if (!await f.exists()) {
        setState(() => _status = '文件不存在：$path');
        return;
      }
      final html = await f.readAsString();
      if (!webhomeHtmlAcceptable(html)) {
        setState(() => _status =
            'HTML 不合规格：为空或超过 ${(webhomeHtmlMaxBytes / 1024 / 1024).toStringAsFixed(0)}MB 上限');
        return;
      }
      setState(() {
        _htmlCtrl.text = html;
        _status = '已载入文件（${html.length} 字符），点「保存并启用」生效';
      });
    } catch (e) {
      // ★ 门禁（zz_t66_user_error_text_gate）：异常原文不进用户可见桶，
      //   收口到 userErrorText；原文只落日志。
      AppLog.write('WEBHOME', 'import from file failed: $e');
      setState(() =>
          _status = userErrorText(e, fallback: '读取 HTML 文件失败，请稍后重试'));
    }
  }

  Future<void> _saveAndEnable() async {
    setState(() => _busy = true);
    try {
      final ok = await WebHomeController.instance
          .saveAndEnable(_htmlCtrl.text);
      if (!mounted) return;
      if (ok) {
        AppLog.write('WEBHOME', 'enabled via settings sheet');
        Navigator.of(context).pop();
      } else {
        setState(() => _status =
            'HTML 不合规格：为空或超过 ${(webhomeHtmlMaxBytes / 1024 / 1024).toStringAsFixed(0)}MB 上限');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _disable() async {
    await WebHomeController.instance.disable();
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final c = WebHomeController.instance;
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SizedBox(
        width: 640,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('自定义 HTML 首页',
                    style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                        color: colors.onSurface)),
                const Spacer(),
                _StateChip(
                    label: c.enabled ? '已启用' : '未启用',
                    active: c.enabled),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '用你自己的 HTML 页面替代原生首页。页面里可用 window.fm 桥'
              '（player.playVod / net.request / cache / log / toast 等）。',
              style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _pathCtrl,
                    style: const TextStyle(fontSize: 13),
                    decoration: const InputDecoration(
                      isDense: true,
                      border: OutlineInputBorder(),
                      labelText: '本地 HTML 文件路径（可选）',
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                    onPressed: _busy ? null : _importFromFile,
                    child: const Text('载入文件')),
              ],
            ),
            const SizedBox(height: 10),
            Expanded(
              child: TextField(
                controller: _htmlCtrl,
                maxLines: null,
                expands: true,
                style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  labelText: '粘贴 HTML（保存并启用后生效）',
                  alignLabelWithHint: true,
                ),
              ),
            ),
            if (_status != null) ...[
              const SizedBox(height: 8),
              Text(_status!,
                  style: TextStyle(fontSize: 12, color: colors.error)),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton(
                  onPressed: _busy ? null : _saveAndEnable,
                  child: const Text('保存并启用'),
                ),
                const SizedBox(width: 8),
                OutlinedButton(
                  onPressed: _busy ? null : _disable,
                  child: const Text('停用（回到原生首页）'),
                ),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('关闭'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StateChip extends StatelessWidget {
  const _StateChip({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: active ? colors.primaryContainer : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(label,
          style: TextStyle(fontSize: 12, color: colors.onSurfaceVariant)),
    );
  }
}
