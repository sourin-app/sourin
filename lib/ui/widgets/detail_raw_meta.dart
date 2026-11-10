// ═══════════════════════════════════════════════════════════════════════
//  详情页的线路选择器（支持任意深度嵌套）
// ═══════════════════════════════════════════════════════════════════════
//
// # 本文件的历史（**绕行已撤除，根因已修**）
//
// 这里原本是「原始 JSON 读取层」—— 因为 `models.dart` 的 `PlaySource`
// 三个键名全错、`MediaDetail` 缺 `badges` / `meta`，所以它自己按 Rust
// 真名读原始 JSON，并定义了 `DetailSourceNode` / `DetailRawMeta` /
// `parseDetailSources` / `sourcesFromModels` 一整套**平行的类型**。
//
// 那层绕行**已经撤掉**：`models.dart` 的根因修好了（`PlaySource` 补上
// `title` / `count` / `nested`，`MediaDetail` 补上 `badges` / `meta`）。
//
// ★ 为什么必须撤（不是"能用就行"）：
// ```text
// 留着就是仓库里的**第二份契约** ——
// 以后 Rust 改了字段名，两处都要改，而漏掉哪一处都不报错。
// 那正是这个文件原本要修的那类静默 bug，不能自己再造一个。
// ```
// 前两批（`ProxyCfg` / `_call`）也是这么处理的：**没有留兼容层**。
//
// 现在这里只剩**纯渲染**：`DetailSourcePicker` + `_Level` + `_SourceButton`，
// 数据一律用 `models.dart` 的 `PlaySource`。
//
// # 与原版 `SourcePicker.vue` 的逐条对应
//
// | 原版（SourcePicker.vue） | 这里 |
// |---|---|
// | `:35` `visible = sources.length > 1` 单选项隐藏该层 | [_Level] 的 `_show` |
// | `:38-44` 收集所有子层的 `nested` 平铺成下一层 | [PlaySource.nested] 直接用 |
// | `:49-52` `containsActive` 命中子树即高亮 | [_Level] 的 `_containsActive` |
// | `:60-69` `s.title \|\| s.code` + `v-if="s.count"` 角标 | [PlaySource.label] / `count > 0` |
// | `:74-80` 递归渲染子层 | [_Level] 递归 `_Level` |
//
// ⚠️ 原版把「所有父项的子线路**合并**成一个平铺层」（`:38-44`），
//    而不是"点开某一项才展开它的子层"。这里**照抄合并**——
//    否则交互就与原版不一致了（原版没有"展开/收起"这个概念）。

import 'package:material_ui/material_ui.dart';

import '../../core/models.dart';

import 'package:flutter_miuix/miuix.dart' as miuix;

import 'miuix_controls.dart' as ui;
import '../tokens.dart';

/// 线路选择器（支持任意深度嵌套）
class DetailSourcePicker extends StatelessWidget {
  const DetailSourcePicker({
    super.key,
    required this.sources,
    required this.active,
    required this.onPick,
  });

  /// 顶层线路
  final List<PlaySource> sources;

  /// 当前选中的 code（任意层级）
  final String active;

  /// 用户点了某一项（可能是嵌套里的）
  final ValueChanged<PlaySource> onPick;

  @override
  Widget build(BuildContext context) {
    return _Level(sources: sources, active: active, depth: 0, onPick: onPick);
  }
}

/// 一层线路 + 它下面的所有层
class _Level extends StatelessWidget {
  const _Level({
    required this.sources,
    required this.active,
    required this.depth,
    required this.onPick,
  });

  final List<PlaySource> sources;
  final String active;
  final int depth;
  final ValueChanged<PlaySource> onPick;

  /// 单选项的层**不渲染**（原版 `SourcePicker.vue:35`）
  bool get _show => sources.length > 1;

  /// 收集所有子线路，合并成下一层（原版 `:38-44`）
  List<PlaySource> get _children => [for (final s in sources) ...s.nested];

  /// 该项自己或其子树里含选中项（原版 `:49-52`）
  bool _containsActive(PlaySource s) {
    if (s.code == active) return true;
    return s.nested.any(_containsActive);
  }

  @override
  Widget build(BuildContext context) {
    final children = _children;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (_show)
          Padding(
            // 非首层缩进，让"层级"看得见（原版靠 CSS 的 `.src-level` 间距区分）
            padding: EdgeInsets.only(
              left: AppMetrics.contentPadding + depth * Sp.x4,
              right: AppMetrics.contentPadding,
              bottom: Sp.x3,
            ),
            child: Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                for (final s in sources)
                  _SourceButton(
                    label: s.label,
                    count: s.count,
                    active: _containsActive(s),
                    onTap: () => onPick(s),
                  ),
              ],
            ),
          ),

        // 递归：子层
        if (children.isNotEmpty)
          _Level(
            sources: children,
            active: active,
            depth: depth + 1,
            onPick: onPick,
          ),
      ],
    );
  }
}

/// A source option uses the shared Miuix choice control, including TV focus.
class _SourceButton extends StatelessWidget {
  const _SourceButton({
    required this.label,
    required this.count,
    required this.active,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = miuix.MiuixTheme.of(context).colors;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 260),
      child: ui.ChoiceChip(
        selected: active,
        onSelected: (_) => onTap(),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (count > 0) ...[
              const SizedBox(width: Sp.x2),
              miuix.MiuixBadge(
                containerColor: active
                    ? colors.onPrimary.withValues(alpha: 0.18)
                    : colors.surfaceContainer,
                contentColor: active ? colors.onPrimary : colors.onSurface,
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: active ? colors.onPrimary : colors.onSurface,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
