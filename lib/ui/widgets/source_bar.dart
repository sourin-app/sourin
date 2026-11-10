// ═══════════════════════════════════════════════════════════════════════
//  多源切换条 —— 对齐原版 SourceBar.vue
// ═══════════════════════════════════════════════════════════════════════
//
// # 它管什么
//
// 「**下面的内容区显示哪个源**」—— 通栏横排，放在「我的」之后、
// 内容之前。位置上贴着内容，而不是贴着页头。
//
// # ★ 单源也显示（2026-10-31 Owner 改判）
//
// 原版 `visible` 计算属性：`sources.length > 1` 才显示，理由是
// "只有一个源时这一条是纯噪音"。**2026-10-31 Owner 明确推翻**：
// ```text
// > 首页就算只有一个源也要显示那个液态选择的
// ```
// ⇒ 单源也渲染这条液态玻璃（默认选中该源；再点它 = 重选，无副作用）。
//   "多少个源"信息（`_showCount`）仍 >3 才显示，噪音判据不变。
//
// # 为什么用横向滚动而不是下拉
//
// 源可能有 20+ 个，下拉要多两次点击；横向条一次点击直达，
// 而且当前选中项**始终可见**（滚动位置自动跟随）。

import 'miuix_controls.dart' as ui;

import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import 'motion_prefs.dart';
import '../../core/sourin_api.dart';
import '../../design/icons/app_icons.dart';

/// ★★★ 源条的**可见性判据** —— 照抄原版 `stores/app.ts` 的 `enabledProviders`
///
/// # 原版那个真 bug（务必照抄语义，不要"简化"）
///
/// 原版 `src/stores/app.ts:259-283` 的注释原文：
/// > ## ⚠️ 这里曾是一个真 bug：用了 `working` 而不是 `enabled`
/// >
/// > 两个字段是**完全不同**的东西：
/// >
/// > | 字段 | 含义 | 谁能改 |
/// > |---|---|---|
/// > | `working` | **站点自身**是否可用（探测出来的）| 用户改不了 |
/// > | `enabled` | **用户**是否要使用它（持久化的偏好）| 用户的选择 |
/// >
/// > 原实现用 `working` 过滤 —— 后果：**用户在设置里停用的源
/// > 仍然出现在首页/搜索/直播里**（`enabled=false` 被完全忽略）。
/// >
/// > 实测证据：停用 srcl 后 `get_provider_enabled('srcl')` 返回 `false`，
/// > 但首页的切换条里它还在，`list_providers` 也把它算作可用。
/// >
/// > 修法：`working` 与 `enabled` **都要**满足。
/// > `enabled` 缺省（undefined）时按启用处理 —— 兼容老数据，
/// > 且内置源若没写这个字段也不会被误判为停用。
///
/// 也就是判据必须是**两个条件的合取**：
/// ```text
/// working && enabled !== false
///   ↑ 站点能用    ↑ 用户要它（缺省 = 要）
/// ```
///
/// # ⚠️ 为什么写成 `enabled != false` 而不是直接 `enabled`
///
/// 这就是原版那个 `!== false` 的字面翻译，而且它**对未来是稳的**：
/// ```text
/// 现在  models.dart: bool  enabled（非空，缺省 true）→ 两者等价
/// 将来  若改成 bool?（Z 正在改 models.dart）
///       · `p.enabled`        → 编译不过 / 或 null 被当 false 用 ✗
///       · `p.enabled != false` → null != false → true = 启用 ✓
/// ```
/// 后者的语义正好是原版要的「缺省按启用处理」。
///
/// ⚠️ **不要**把这里改成只看 `enabled`：那会让 `working=false` 的
///    坏源继续留在切换条里（用户点了没内容，且不知道原因）。
bool sourceIsUsable(ProviderManifest p) => p.working && p.enabled != false;

/// 从源列表里挑出**该出现在切换条里的**那些（顺序保持不变）
///
/// ⚠️ 顺序**原样保留** —— 那是用户保存的排序（`provider-order.json`），
///    前端绝不能再 sort 一次（原版 `loadProviders` 注释强调过）。
List<ProviderManifest> visibleSourceList(List<ProviderManifest> all) =>
    all.where(sourceIsUsable).toList();

/// Compare the ordered inputs used by the source pills, including availability.
/// Provider refreshes return new model instances even when nothing has changed.
bool sourceBarSourcesEqual(List<ProviderManifest> a, List<ProviderManifest> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    final left = a[i], right = b[i];
    if (left.id != right.id ||
        left.name != right.name ||
        left.icon != right.icon ||
        left.enabled != right.enabled ||
        left.working != right.working ||
        left.brokenReason != right.brokenReason) {
      return false;
    }
  }
  return true;
}

/// 源切换条
class SourceBar extends StatefulWidget {
  const SourceBar({
    super.key,
    required this.sources,
    required this.current,
    required this.onSelect,
    this.focusedIndex = -1,
  });

  /// 可切换的源（**已启用的**，顺序即显示顺序）
  ///
  /// ⚠️ 调用方传进来的可能仍含**不该显示的**源（`enabled=false` 或
  ///    `working=false`）—— 本组件在渲染前**自己再过一遍**
  ///    [visibleSourceList]（见 [visible]）。这样"什么该显示"
  ///    只有**一处**判据，不依赖每个调用方都记得过滤。
  final List<ProviderManifest> sources;

  /// 当前选中的源 id
  final String current;

  final ValueChanged<String> onSelect;

  /// TV 遥控：当前聚焦的下标（-1 = 无）
  final int focusedIndex;

  bool hasSameConfiguration(SourceBar other) =>
      key == other.key &&
      current == other.current &&
      focusedIndex == other.focusedIndex &&
      onSelect == other.onSelect &&
      sourceBarSourcesEqual(sources, other.sources);

  @override
  State<SourceBar> createState() => _SourceBarState();
}

class _SourceBarState extends State<SourceBar> {
  final _controller = ScrollController();
  final _pillKeys = <String, GlobalKey>{};
  int _revealRevision = 0;
  bool _reduceMotion = false;

  @override
  void initState() {
    super.initState();
    _scrollToCurrent();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final reduceMotion = MotionPrefs.reduce(context);
    if (_reduceMotion != reduceMotion) {
      _reduceMotion = reduceMotion;
      _scrollToCurrent();
    }
  }

  @override
  void dispose() {
    _revealRevision++;
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(SourceBar old) {
    super.didUpdateWidget(old);
    if (old.current != widget.current ||
        old.focusedIndex != widget.focusedIndex ||
        !sourceBarSourcesEqual(old.sources, widget.sources)) {
      _scrollToCurrent();
    }
  }

  // Note: .agents/notes/implemented/bug-fix/2026-11-10-source-selection-reveal.md
  // Use real pill geometry. A fixed width estimate can move a clicked source
  // offscreen, and does not reveal a restored selection in a lazy list.
  void _scrollToCurrent() {
    final revision = ++_revealRevision;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted || revision != _revealRevision || !_controller.hasClients) {
        return;
      }
      // A newer, already-visible choice must also stop an older driven scroll.
      if (_controller.position.isScrollingNotifier.value) {
        _controller.jumpTo(_controller.position.pixels);
      }
      final sources = _visible;
      final focused = widget.focusedIndex;
      final index = focused >= 0 && focused < sources.length
          ? focused
          : sources.indexWhere((s) => s.id == widget.current);
      if (index < 0) return;
      for (var pass = 0; pass <= sources.length; pass++) {
        if (!mounted ||
            revision != _revealRevision ||
            !_controller.hasClients) {
          return;
        }
        final position = _controller.position;
        final selected = _pillKeys[sources[index].id]?.currentContext
            ?.findRenderObject();
        if (selected is RenderBox && selected.attached && selected.hasSize) {
          final viewport = RenderAbstractViewport.of(selected);
          final start = viewport.getOffsetToReveal(selected, 0).offset;
          final end = viewport.getOffsetToReveal(selected, 1).offset;
          final target =
              (end <= start ? position.pixels.clamp(end, start) : start).clamp(
                position.minScrollExtent,
                position.maxScrollExtent,
              );
          // A fully visible selection stays put, including after a mouse click.
          if ((target - position.pixels).abs() > .5) {
            final duration = MotionPrefs.duration(context, Motion.base);
            if (duration == Duration.zero) {
              position.jumpTo(target);
            } else {
              await position.animateTo(
                target,
                duration: duration,
                curve: MotionPrefs.curve(context, Motion.easeOut),
              );
            }
          }
          return;
        }

        // Only nearby lazy children have geometry. Use them to approach an
        // unmounted selection, then correct using its actual bounds. No eager
        // Row of every Miuix surface and no duplicated text-width calculation.
        final laidOut = <({int index, double offset, double width})>[];
        for (var i = 0; i < sources.length; i++) {
          final box = _pillKeys[sources[i].id]?.currentContext
              ?.findRenderObject();
          if (box is! RenderBox || !box.attached || !box.hasSize) continue;
          final viewport = RenderAbstractViewport.of(box);
          laidOut.add((
            index: i,
            offset: viewport.getOffsetToReveal(box, 0).offset,
            width: box.size.width,
          ));
        }
        if (laidOut.isEmpty) return;
        final first = laidOut.first, last = laidOut.last;
        final mean = last.index > first.index
            ? (last.offset - first.offset) / (last.index - first.index)
            : first.width + Sp.x2;
        var target = first.offset + (index - first.index) * mean;
        target = target.clamp(
          position.minScrollExtent,
          position.maxScrollExtent,
        );
        if ((target - position.pixels).abs() <= .5) return;
        position.jumpTo(target);
        await WidgetsBinding.instance.endOfFrame;
      }
    });
  }

  /// ★ 真正要渲染的源 —— **已停用的不在里面**
  ///
  /// # 这就是原版修掉的那个 bug 的落点
  ///
  /// 原版实测：停用 srcl 后 `get_provider_enabled('srcl')` 返回 `false`，
  /// 但首页切换条里**它还在**（旧实现只看 `working`）。
  ///
  /// ⚠️ 过滤放在**组件内部**而不是只靠调用方传干净的列表：
  ///    调用方有首页/直播/搜索多处，漏一处那个 bug 就回来 ——
  ///    这正是原版把它收进 store 计算属性的理由（"集中判定才不会漏"）。
  List<ProviderManifest> get _visible => visibleSourceList(widget.sources);

  /// 是否显示源数量（原版 `showCount`）
  ///
  /// > 源少时不显示 —— 3 个源一眼就数完了，
  /// > 再挂一个"3 个源"是纯噪音。
  ///
  /// ⚠️ 用**过滤后**的数量 —— 否则会出现「停用了 5 个源，
  ///    条上只剩 2 个药丸，右下角却写着 7 个源」这种自相矛盾。
  bool get _showCount => _visible.length > 3;

  @override
  Widget build(BuildContext context) {
    final sources = _visible;
    final indexes = <Key, int>{};
    final ids = sources.map((source) => source.id).toSet();
    _pillKeys.removeWhere((id, _) => !ids.contains(id));
    for (var i = 0; i < sources.length; i++) {
      indexes[_pillKeys.putIfAbsent(sources[i].id, GlobalKey.new)] = i;
    }

    /*
     * ★ 单源**也渲染**（2026-10-31 Owner 改判，见文件头说明）
     *
     * 改前这里是 `if (sources.length <= 1) return SizedBox.shrink()`。
     * 单源时唯一那颗药丸默认就是选中态（`current` 必然等于它）；
     * 再点它 = `_switchSource` 的同源守卫（`home_page.dart:2115`
     * `if (id == _currentSource) return`）直接短路 ⇒ **无谓重载不存在**，
     * 重选天然无害。多源同款：点当前源也是零成本 no-op。
     */

    final colors = Theme.of(context).colorScheme;

    // A single source should occupy only its label, not a page-wide white card.
    return Align(
      alignment: Alignment.centerLeft,
      child: ConstrainedBox(
        // `max-width: 100%` —— 源很多时不要把屏幕撑破
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width - Sp.x8,
        ),
        child: SizedBox(
          height: 44,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── 可横向滚动的 pill 列表 ──
              Flexible(
                child: ScrollConfiguration(
                  /*
                     * ══════════════════════════════════════════════════
                     * ★★★ 允许**鼠标拖拽**横滑（2026-09-24 用户要求）
                     * ══════════════════════════════════════════════════
                     *
                     * 用户原话：
                     * > 鼠标拖动,也不能左右滑动
                     *
                     * # 为什么默认不行
                     *
                     * Flutter 的 `ScrollBehavior.dragDevices` 默认**只含
                     * touch/stylus** —— 鼠标只能滚轮，拖拽不滚动。
                     * 这是移动优先的默认值，在桌面上就成了功能缺失。
                     *
                     * 加 `PointerDeviceKind.mouse` 即可。
                     *
                     * ⚠️ 会不会和点击 pill 冲突？
                     *    不会 —— 手势竞技场按"是否超过拖拽阈值"裁决：
                     *    ```text
                     *    按下后几乎没动（< kTouchSlop） → 点击 wins → InkWell.onTap
                     *    按下后拖动了超过阈值            → 拖拽 wins → 列表滚动
                     *    ```
                     *    这正是用户直觉（点=选源，拖=滚动）。
                     */
                  behavior: const MaterialScrollBehavior().copyWith(
                    dragDevices: {
                      PointerDeviceKind.touch,
                      PointerDeviceKind.mouse,
                      PointerDeviceKind.stylus,
                      PointerDeviceKind.trackpad,
                    },
                  ),
                  child: ListView.separated(
                    clipBehavior: Clip.antiAlias,
                    controller: _controller,
                    shrinkWrap: true,
                    scrollDirection: Axis.horizontal,
                    // 原版 `.srcbar { padding: 5px }` + 内层 `padding: 0 var(--sp-2)`
                    padding: EdgeInsets.zero,
                    itemCount: sources.length,
                    findItemIndexCallback: (key) => indexes[key],
                    separatorBuilder: (_, __) => const SizedBox(width: Sp.x2),
                    itemBuilder: (context, i) {
                      // ⚠️ 用**过滤后**的 `sources`（任务 AE）——
                      //    用 `widget.sources` 会把停用的源渲染回药丸里
                      final s = sources[i];
                      final active = s.id == widget.current;
                      final focused = i == widget.focusedIndex;
                      final working = s.working;

                      return Center(
                        key: _pillKeys[s.id],
                        child: SourcePill(
                          label: s.name,
                          icon: s.icon,
                          active: active,
                          focused: focused,
                          // 源探测失败 ⇒ 药丸上画感叹号（tooltip 给原因）
                          errorTooltip: working
                              ? null
                              : (s.brokenReason ?? '该源当前不可用'),
                          onTap: () => widget.onSelect(s.id),
                        ),
                      );
                    },
                  ),
                ),
              ),

              /*
                 * ── 数量显示（原版 `showCount`）──
                 *
                 * 原版：
                 * ```ts
                 * const showCount = computed(() => props.sources.length > 3);
                 * ```
                 * > 源少时不显示 —— 3 个源一眼就数完了，
                 * > 再挂一个"3 个源"是纯噪音。
                 *
                 * 样式照抄原版 `.srcbar__count`：
                 * ```css
                 * padding: 0 var(--sp-4) 0 var(--sp-3);
                 * margin-left: var(--sp-1);
                 * font-size: var(--fs-cap);
                 * color: var(--text-tertiary);
                 * border-left: 1px solid var(--divider);   ← 左侧分隔线
                 * ```
                 * 注意它在**滚动区之外**（`flex: none`）——
                 * 滚到第 20 个源时数量仍然可见。
                 */
              if (_showCount) ...[
                const SizedBox(width: Sp.x2),
                Container(height: 18, width: 1, color: colors.outlineVariant),
                Padding(
                  padding: const EdgeInsets.only(left: Sp.x3, right: Sp.x4),
                  child: Text.rich(
                    TextSpan(
                      children: [
                        TextSpan(
                          // ⚠️ 过滤后的数量（任务 AE）—— 见 `_showCount` 的说明
                          text: '${sources.length}',
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            fontWeight: FontWeight.w600,
                            color: colors.onSurfaceVariant,
                          ),
                        ),
                        TextSpan(
                          text: ' 个源',
                          style: TextStyle(
                            fontSize: FontSizes.cap,
                            color: colors.onSurfaceVariant.withValues(
                              alpha: 0.7,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 源 / 渠道**共用**的选择药丸（2026-10-31 从 `_SourcePill` 抽公共件）
///
/// # 为什么必须是公共件（Owner 原话，逐字）
/// ```text
/// > tvbox 聚合源下面的也要跟那个液态玻璃选择的样式一样，这里样式都不一样，
/// > 要优化和矫正
/// ```
/// 判据是"改一处两处同变" —— 样式参数（选中高亮、圆角、字号字重、
/// 焦点环、失效标记）**只活在这一个类里**，两个消费方都不许自带一份：
/// ```text
/// · source_bar.dart  SourceBar        —— 首页液态玻璃源条（本文件）
/// · home_page.dart   _AggChannelRail  —— TVBox 聚合渠道条（替代 ActionChip）
/// ```
/// 照原版 `.srcbar__pill` / `.srcbar__pill.is-active`：
/// ```css
/// .srcbar__pill            { background: transparent; color: var(--text-secondary); }
/// .srcbar__pill.is-active  { background: var(--surface-4); box-shadow: var(--shadow-sm); }
/// ```
/// Each pill owns one Miuix glass surface, shared by source and channel rails.
class SourcePill extends StatelessWidget {
  const SourcePill({
    super.key,
    required this.label,
    this.icon,
    required this.active,
    this.focused = false,
    this.errorTooltip,
    this.secondary = false,
    required this.onTap,
  });

  /// 药丸文字（源名 / 渠道名）
  final String label;

  /// 源图标（emoji/单字短文本才画；URL 或超长文本 ⇒ 忽略，见 build 内规则）
  final String? icon;

  /// 是否选中（选中 ⇒ "更亮一层"的 `--surface-4` 底 + 加粗）
  final bool active;

  /// TV 遥控焦点（-1 语义在调用方；true ⇒ 画焦点环）
  final bool focused;

  /// 非 null ⇒ 画失效感叹号，tooltip 用它的文本；源/渠道可用时传 null
  final String? errorTooltip;

  final VoidCallback onTap;
  final bool secondary;

  /// 短文本图标（emoji/单字才画）；null / 空串 / >4 字符 / http 开头 ⇒ null
  ///
  /// ⚠️ 判定落在这里（局部变量做判空链）：实例字段 Dart 不做空安全提升。
  String? get _shortIconText {
    final ic = icon;
    if (ic == null || ic.isEmpty) return null;
    if (ic.length > 4 || ic.startsWith('http')) return null;
    return ic;
  }

  @override
  Widget build(BuildContext context) {
    final colors = miuix.MiuixTheme.of(context).colors;
    final iconText = _shortIconText;
    final dark = colors.background.computeLuminance() < .5;
    final selectedText = dark
        ? const Color(0xff9dbfff)
        : Color.alphaBlend(const Color(0x1f000000), colors.primary);
    final selectedFill = Color.alphaBlend(
      colors.primary.withValues(alpha: dark ? .20 : .09),
      colors.surface,
    );
    final button = ui.ChoiceChip(
      selected: active,
      onSelected: (_) => onTap(),
      backgroundColor: Colors.transparent,
      selectedColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(999)),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x2),
      labelStyle: TextStyle(
        color: active ? selectedText : colors.onSurfaceSecondary,
        fontSize: FontSizes.sm,
        fontWeight: active ? FontWeight.w600 : FontWeight.w400,
        height: 1.25,
      ),
      avatar: iconText == null ? null : Text(iconText),
      label: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 168),
        child: Text(
          sourceDisplayLabel(label),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ),
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(999),
        border: focused ? Border.all(color: colors.primary, width: 2) : null,
      ),
      child: errorTooltip == null
          ? miuix.MiuixGlassPanel(
              shape: const miuix.MiuixGlassShape(
                cornerRadius: 999,
                smoothing: 0,
              ),
              fill: active
                  ? selectedFill
                  : colors.surface.withValues(alpha: .72),
              stroke: miuix.MiuixGlassStrokes.small(dark),
              shadow: miuix.MiuixGlassShadows.floating,
              child: button,
            )
          : ui.Tooltip(
              message: errorTooltip!,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  button,
                  Icon(
                    AppIcons.error_outline,
                    size: FontSizes.sm,
                    color: colors.error,
                  ),
                ],
              ),
            ),
    );
  }
}

/// Channel providers often decorate names with repeated emoji and full-width
/// separators. Keep identifiers and stored names intact; simplify only display.
String sourceDisplayLabel(String label) {
  final display = label
      .replaceFirst(RegExp(r'^[^\p{L}\p{N}]+', unicode: true), '')
      .replaceAll(RegExp(r'\s*[丨|｜]\s*'), ' · ')
      .trim();
  return display.isEmpty ? label.trim() : display;
}
