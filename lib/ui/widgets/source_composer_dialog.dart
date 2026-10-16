/// 声明式源的可视化编排器 —— UI 层（三步表单 + 实时 JSON 预览）
///
/// 数据模型见 [source_composer_model.dart]（本文件只做界面）。
/// 设计取舍见该文件顶部注释（为什么不做拖拽流程图）。
library;

import 'dart:convert';

import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'app_dialog_section.dart';
import 'app_dialog_shell.dart';
import 'source_composer_model.dart';

/// 每个字段的示例 JSONPath —— **按字段给不同例子**，
/// 比全部填同一个 `$.data.vod_id` 更能说明"这一行该填什么"。
const Map<String, String> kComposerFieldHints = {
  'items': r'$.data.list',
  'id': r'$.data.vod_id',
  'title': r'$.data.vod_name',
  'cover': r'$.data.vod_pic',
  'subtitle': r'$.data.vod_remarks',
  'episodes': r'$.data.vod_play_url',
  'categories': r'$.data.class',
};

/// 可视化编排弹窗
class SourceComposerDialog extends StatefulWidget {
  const SourceComposerDialog({
    super.key,
    this.initial,
    this.onSubmit,
    this.fill = true,
  });

  /// 编辑态初值（null = 新建）
  final ComposerDraft? initial;

  /// 用户点了「创建」—— 交回编排结果（调用方负责落盘）
  final void Function(Map<String, Object?> json)? onSubmit;

  final bool fill;

  @override
  State<SourceComposerDialog> createState() => _SourceComposerDialogState();
}

class _SourceComposerDialogState extends State<SourceComposerDialog> {
  late final ComposerDraft _d = widget.initial ?? ComposerDraft();
  late final TextEditingController _id = TextEditingController(text: _d.id);
  late final TextEditingController _name = TextEditingController(text: _d.name);
  late final TextEditingController _base = TextEditingController(text: _d.base);

  /// 当前步（0/1/2）—— 分步是为了不把 12 个输入框一次糊在用户脸上
  int _step = 0;

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

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _base.dispose();
    super.dispose();
  }

  void _sync() {
    _d.id = _id.text;
    _d.name = _name.text;
    _d.base = _base.text;
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppDialogShell(
      title: '可视化编排',
      subtitle: '拼一个源，不用手写 JSON',
      icon: Icons.auto_fix_high_outlined,
      width: 860,
      fill: widget.fill,
      motion: true,
      onClose: () => Navigator.of(context).maybePop(),
      actions: Row(mainAxisSize: MainAxisSize.min, children: _actions(context)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          _stepper(colors),
          const SizedBox(height: Sp.x4),
          switch (_step) {
            0 => _stepSite(colors),
            1 => _stepEndpoints(colors),
            _ => _stepMapping(colors),
          },
          const SizedBox(height: Sp.x5),
          const AppDialogSection.title('生成的 JSON', note: '可直接粘贴到「粘贴 JSON」入口'),
          const SizedBox(height: Sp.x2),
          _jsonPreview(colors),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context) => [
        if (_step > 0)
          TextButton(
            onPressed: () => setState(() => _step--),
            child: const Text('上一步'),
          ),
        if (_step < 2)
          FilledButton(
            onPressed: () => setState(() { _sync(); _step++; }),
            child: const Text('下一步'),
          )
        else
          FilledButton(
            onPressed: _canSubmit
                ? () {
                    _sync();
                    widget.onSubmit?.call(_d.toJson());
                  }
                : null,
            child: const Text('创建'),
          ),
      ];

  // ── 步骤指示 ──
  Widget _stepper(ColorScheme colors) {
    const labels = ['站点', '端点', '字段映射'];
    return Row(
      children: [
        for (var i = 0; i < labels.length; i++) ...[
          if (i > 0)
            Expanded(
              child: Container(
                height: 1,
                margin: const EdgeInsets.symmetric(horizontal: Sp.x2),
                color: i <= _step ? colors.primary : colors.outlineVariant,
              ),
            ),
          _stepDot(colors, i, labels[i]),
        ],
      ],
    );
  }

  Widget _stepDot(ColorScheme colors, int i, String label) {
    final on = i <= _step;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 20,
          height: 20,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? colors.primary : Colors.transparent,
            border: Border.all(
              color: on ? colors.primary : colors.outlineVariant,
            ),
          ),
          child: Text(
            '${i + 1}',
            style: TextStyle(
              fontSize: 11,
              color: on ? colors.onPrimary : colors.onSurfaceVariant,
            ),
          ),
        ),
        const SizedBox(width: Sp.x2),
        Text(
          label,
          style: TextStyle(
            fontSize: FontSizes.sm,
            color: on ? colors.onSurface : colors.onSurfaceVariant,
            fontWeight: on ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }

  // ── 第 1 步：站点 ──
  Widget _stepSite(ColorScheme colors) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppDialogSection.title('这个源叫什么'),
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
            child: Text(label, style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant)),
          ),
          Expanded(
            child: TextField(
              controller: ctl,
              onChanged: (v) => setState(() => onChanged(v)),
              decoration: InputDecoration(
                hintText: hint,
                isDense: true,
                border: const OutlineInputBorder(),
                contentPadding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x3),
              ),
            ),
          ),
        ],
      );

  // ── 第 2 步：端点 ──
  Widget _stepEndpoints(ColorScheme colors) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const AppDialogSection.title('这个源支持哪些能力', note: '勾上的才写进 JSON'),
          const SizedBox(height: Sp.x3),
          for (final e in ComposerEndpoint.values)
            CheckboxListTile(
              value: _d.endpoints[e]!.enabled,
              onChanged: (v) => setState(() => _d.endpoints[e]!.enabled = v ?? false),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              secondary: Icon(e.icon, size: 18, color: colors.onSurfaceVariant),
              title: Text(e.label, style: const TextStyle(fontSize: FontSizes.sm)),
            ),
        ],
      );

  // ── 第 3 步：字段映射 ──
  Widget _stepMapping(ColorScheme colors) {
    final on = _d.enabled.toList();
    if (on.isEmpty) {
      return Text(
        '还没勾任何端点 —— 回上一步勾一个。',
        style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in on) ...[
          AppDialogSection.title(e.label, note: '每行填一个 JSONPath'),
          const SizedBox(height: Sp.x2),
          for (final f in kComposerFieldLabels.keys)
            _mapRow(colors, e, f),
          const SizedBox(height: Sp.x4),
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
                fontWeight: required ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Expanded(
            child: TextField(
              controller: ctl,
              onChanged: (v) => setState(() {
                if (v.trim().isEmpty) {
                  draft.map.remove(field);
                } else {
                  draft.map[field] = v.trim();
                }
              }),
              style: const TextStyle(fontFamily: 'monospace', fontSize: FontSizes.cap),
              decoration: InputDecoration(
                hintText: kComposerFieldHints[field] ?? r'$.data.vod_id',
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

  Widget _jsonPreview(ColorScheme colors) => Container(
        width: double.infinity,
        constraints: const BoxConstraints(maxHeight: 200),
        padding: const EdgeInsets.all(Sp.x3),
        decoration: BoxDecoration(
          color: colors.surfaceContainerHighest.withValues(alpha: 0.4),
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
      );
}
