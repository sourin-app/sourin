import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'miuix_controls.dart' as ui;

List<String> sourceBackupUrls(String text) => text
    .split(RegExp(r'[\r\n]+'))
    .map((value) => value.trim())
    .where((value) => value.isNotEmpty)
    .toSet()
    .toList(growable: false);

/// One address form for TVBox, live subscriptions and JS installation/editing.
class SourceAddressFields extends StatelessWidget {
  const SourceAddressFields({
    super.key,
    required this.name,
    required this.primary,
    required this.backups,
    this.enabled = true,
    this.acceptConfiguration = false,
    this.onChanged,
  });

  final TextEditingController name;
  final TextEditingController primary;
  final TextEditingController backups;
  final bool enabled;
  final bool acceptConfiguration;
  final VoidCallback? onChanged;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      ui.TextField(
        key: const ValueKey('source-address-name'),
        controller: name,
        enabled: enabled,
        decoration: const InputDecoration(
          labelText: '来源名称',
          hintText: '可选，用于区分聚合来源',
        ),
      ),
      const SizedBox(height: Sp.x3),
      ui.TextField(
        key: const ValueKey('source-address-primary'),
        controller: primary,
        enabled: enabled,
        minLines: acceptConfiguration ? 3 : 1,
        maxLines: acceptConfiguration ? 6 : 1,
        onChanged: (_) => onChanged?.call(),
        decoration: InputDecoration(
          labelText: acceptConfiguration ? '主地址或配置 JSON' : '主地址',
          hintText: 'https://',
        ),
      ),
      const SizedBox(height: Sp.x3),
      ui.TextField(
        key: const ValueKey('source-address-backups'),
        controller: backups,
        enabled: enabled,
        minLines: 3,
        maxLines: 6,
        onChanged: (_) => onChanged?.call(),
        decoration: const InputDecoration(
          labelText: '备用地址',
          hintText: '每行一个，最多 8 个；主地址不可用时按顺序尝试',
        ),
      ),
    ],
  );
}
