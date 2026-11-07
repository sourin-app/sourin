// Product appearance has one light/dark/system choice; old packs are preview-only.
import 'package:material_ui/material_ui.dart';

import '../app_theme.dart';
import '../theme/theme_language.dart' show kDefaultRadius, kDefaultBorderWidth, kDefaultDividerThickness;
import '../theme/theme_pack.dart';
import '../tokens.dart';
import '../widgets/settings_kit.dart';
import '../widgets/settings_sub_page.dart';
import '../../design/icons/app_icons.dart';

class ThemeSettingsPage extends StatefulWidget {
  const ThemeSettingsPage({super.key});

  @override
  State<ThemeSettingsPage> createState() => _ThemeSettingsPageState();
}

class _ThemeSettingsPageState extends State<ThemeSettingsPage> {
  bool _previewEnabled = true;
  void _pickMode(AppThemeMode mode) {
    AppTheme.setMode(mode);
    notifyThemeChanged();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) => SettingsSubPage(
    title: '外观',
    subtitle: '简洁的界面，舒适的明暗',
    children: [
      SettingsBlock(
        title: '显示模式',
        children: [
          Wrap(spacing: Sp.x3, runSpacing: Sp.x3, children: [
            for (final mode in AppThemeMode.values)
              SettingsGesturePill(
                text: mode.label,
                selected: AppTheme.mode == mode,
                onTap: () => _pickMode(mode),
              ),
          ]),
          const SizedBox(height: Sp.x4),
          Text('跟随系统会自动切换明暗，所有页面即时生效。',
            style: TextStyle(fontSize: FontSizes.sm,
              color: Theme.of(context).colorScheme.onSurfaceVariant)),
        ],
      ),
      SettingsBlock(title: '界面预览', children: [
        SettingsGestureToggle(label: '试试开关', hint: '预览当前外观的控件样式',
          value: _previewEnabled,
          onChanged: (value) => setState(() => _previewEnabled = value)),
      ]),
    ],
  );

}

// Legacy pack previews remain usable by the explicit preview tooling.
class ThemeGrid extends StatelessWidget {
  const ThemeGrid({
    required this.packs,
    required this.selectedId,
    required this.onPick,
    required this.onDelete,
    this.onPreview,
    super.key,
  });

  final List<ThemePack> packs;
  final String selectedId;
  final ValueChanged<ThemePack> onPick;
  final ValueChanged<ThemePack> onDelete;

  /// 打开某套主题的大预览（可空：不给就不显示预览按钮）
  final ValueChanged<ThemePack>? onPreview;

  /// 按 `familyId` 分组 —— 同一套设计的浅/深两版放一组
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-31 / 11-B 第 3 步：从「16 张平铺」改成「8 组 × 2 张」
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 为什么必须分组
  /// ```text
  /// 11-A 给 8 套主题各补了浅色版 ⇒ 16 张卡平铺。
  /// 但平铺之后用户看不出「樱粉」和「樱粉·浅」是**同一套设计的两档明暗**，
  /// 只会以为是两套互不相干的主题 ⇒ 11-A 的「双色」价值完全没传达到。
  /// ```
  ///
  /// # 分组顺序
  /// ```text
  /// ① 保持 `packs` 的原始顺序（第一套 = 默认值，这个契约不能破）
  /// ② 组内**浅色在前、深色在后** ——
  ///    这样同一组的卡片按「亮 → 暗」排列，视觉上像一条渐变，
  ///    比忽明忽暗更容易看出「这是一套」。
  /// ```
  ///
  /// # 单档家族
  /// ```text
  /// 只有一档的（外部导入包、或未来只有深色的包）自成一族，
  /// 组内只有一张卡，**表现与分组前完全一致**（宽度也不变，不会变窄）。
  /// ```
  List<List<ThemePack>> _grouped() {
    final order = <String>[];
    final map = <String, List<ThemePack>>{};
    for (final p in packs) {
      if (!map.containsKey(p.familyId)) {
        order.add(p.familyId);
        map[p.familyId] = <ThemePack>[];
      }
      map[p.familyId]!.add(p);
    }
    final out = <List<ThemePack>>[];
    for (final fam in order) {
      final g = map[fam]!;
      // 浅色在前、深色在后；同明暗时保持原序（稳定排序）
      final sorted = <ThemePack>[
        ...g.where((e) => e.brightness == Brightness.light),
        ...g.where((e) => e.brightness != Brightness.light),
      ];
      out.add(sorted);
    }
    return out;
  }

  /// 家族显示名 —— 去掉「·浅」「·深」后缀
  ///
  /// 例：`樱粉·浅` / `樱粉` ⇒ `樱粉`；`极简留白·深` / `极简留白` ⇒ `极简留白`
  ///
  /// ⚠️ 用**名称**而不是 familyId 做标题：familyId 是内部键（`neoBrutal`），
  ///    给用户看的是中文名。
  ///
  /// ★ 但**不能**取排序后（浅色在前）的第一张 —— 我第一版就是那样，结果
  ///   midnight 家族标题显示成「日间」，因为它的浅色版叫「日间」。
  ///   那是错的：这一族的基名是「午夜」（`builtin.midnight`，且它是默认那套）。
  ///
  /// ⇒ 改为取**原始声明顺序**里的第一张（即深色基版，`packs` 里先前那个），
  ///   再剥掉「·浅 / ·深」后缀。
  ///   对「午夜 ⇄ 日间」这种浅深两版名字**完全不同**的族，
  ///   这样能稳定拿到基名「午夜」而不是「日间」。
  static String _familyLabel(List<ThemePack> g) {
    // g 已按「浅前深后」排过 ⇒ 原始基版要按 brightness 反查一次。
    // 优先用深色那张（基版几乎都是深色声明在前的），没有深色再退回第一张。
    final base = g.firstWhere(
      (e) => e.brightness == Brightness.dark,
      orElse: () => g.first,
    );
    final n = base.name;
    for (final suffix in <String>['·浅', '·深', ' · 浅', ' · 深']) {
      if (n.endsWith(suffix)) return n.substring(0, n.length - suffix.length);
    }
    return n;
  }

  @override
  Widget build(BuildContext context) {
    final groups = _grouped();
    return LayoutBuilder(
      builder: (context, box) {
        /*
         * ★ 布局：**每行一个家族**，家族名在左、浅深两张在右。
         *
         * # 为什么不是「每组占一整行、两张卡横排到全宽」
         * ```text
         * 第一版我按「每张至少 150 宽 ⇒ 全宽能放 5 张」算卡宽，
         * 于是每组只有 2 张卡却每张都按 1/5 屏宽，
         * 结果每组右边空出一大片（实测 grid_grouped.png 第 1 版就是这样）。
         * 那种"两张小卡 + 半屏空白"看起来很散，也不像"一组"。
         * ```
         *
         * # 现在的做法
         * ```text
         * 左边固定一个家族名列（宽 96），右边两张卡并排。
         * ⇒ 8 个家族形成整齐的两列矩阵，组与组之间一眼能看出分界，
         *   而且卡片尺寸统一、不会因为列数变化而忽大忽小。
         * ```
         *
         * # 卡片宽度
         * ```text
         * 实测 150 与 130 宽下，66px 预览仍能看出设计语言差异
         * （sweep_w150 / sweep_w130：新粗野的方角粗边、极简的发丝线、
         *   玻璃的胶囊圆角，130px 下依旧一眼可分）
         * ⇒ 不必为此放大预览高度，保持 66px。
         * ```
         */
        const double labelW = 96.0;
        final gap = Sp.x2;
        /*
         * ★ 卡片宽度**固定**，不再按可用宽度均分。
         *
         * # 为什么（这是我第三次改这个值，前两次都错）
         * ```text
         * 第 1 版：按「每张至少 150」均分 ⇒ 每组 2 张各占 1/5 屏宽，右边空一片
         * 第 2 版：改成「左侧家族名 + 右侧均分」⇒ 单卡被拉到 392px
         *         ⇒ 预览(190 定宽)只占卡片左半，**卡片大半是空白**，很散
         * 现在：卡片宽度 = 预览宽 + 左右内边距，**卡片贴合预览**
         * ```
         *
         * 结果：一组 = [家族名 96][卡片 206][卡片 206]，
         *       卡片不多不少刚好包住预览，视觉上是一条整齐的矩阵。
         * 右侧那片留白是「预览必须定宽保比例」的必然代价 ——
         * 留白可以接受，拉伸失真不能接受（Lead 的判断，我同意）。
         */
        final cardW = ThemeCard.preferredWidth;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var gi = 0; gi < groups.length; gi++) ...[
              if (gi > 0) SizedBox(height: Sp.x3),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── 左：家族名（不带 ·浅/·深）──
                  SizedBox(
                    width: labelW,
                    child: Padding(
                      padding: const EdgeInsets.only(top: Sp.x1),
                      child: Text(
                        _familyLabel(groups[gi]),
                        style: TextStyle(
                          fontSize: FontSizes.sm,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: Sp.x3),
                  // ── 右：浅深并排 ──
                  Expanded(
                    child: Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final p in groups[gi])
                          SizedBox(
                            width: cardW,
                            child: ThemeCard(
                              pack: p,
                              selected: p.id == selectedId,
                              onTap: () => onPick(p),
                              onDelete: p.builtin ? null : () => onDelete(p),
                              onPreview:
                                  onPreview == null ? null : () => onPreview!(p),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 单套主题的卡片（缩略预览 + 名称/深浅标签 + 选中勾 + 预览按钮）
///
/// ══════════════════════════════════════════════════════════════════
/// ⚠️ **必须放在 `Material` 祖先之下**（Lead 2026-10-17 实测要求写清）
/// ══════════════════════════════════════════════════════════════════
///
/// ```text
/// 实测（.probe/probe_tests 里的 A/B 对照）：
///   A 只有 Directionality、无 Material  => 抛 "No Material widget found."
///   B 外面包一层 Material                => 正常
/// ```
/// 原因：本卡片用 `InkWell` 做点击反馈，而**水波要画在最近的 Material 上**。
/// 设置页本身有 Scaffold（内含 Material），所以当前不会出问题；
/// 但若有人把它放进纯 `Container` 页面（例如自绘的浮层），就会直接崩。
///
/// ⇒ 需要这么做的场景：外面套 `Material(type: MaterialType.transparency)`。
class ThemeCard extends StatelessWidget {
  const ThemeCard({
    required this.pack,
    required this.selected,
    required this.onTap,
    this.onDelete,
    this.onPreview,
    super.key,
  });

  final ThemePack pack;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  /// 打开「单套大预览」弹窗
  ///
  /// 与 [onTap] 分开是**有意的**：点卡片 = 真的切换主题（立即生效），
  /// 点预览图标 = 只看不换。两者合并会让用户没法「先看再选」。
  final VoidCallback? onPreview;

  /// 预览的**固定宽度**（px）
  ///
  /// ⚠️ 必须固定，不能跟卡片宽度走 —— 详见 build() 里那段注释：
  ///    卡片宽度会随列数变化（手机 ~300、桌面 ~390），
  ///    若预览跟着变宽而高度恒为 66，宽高比就从 2.88 被拉到 5.9，
  ///    圆角变扁椭圆、2.5px 粗边被摊薄 ⇒ 设计语言看不出来。
  ///
  /// 190 = 原始设计基线（与 `_Preview` 的 height 66 配套，比值 2.88:1）。
  /// 改这里要同步改 `zz_t31b_preview_aspect_test.dart` 的断言区间。
  static const double previewWidth = 190.0;

  /// 卡片**期望宽度** = 预览宽 + 两边内边距（Sp.x2 = 8）
  ///
  /// 为什么不让卡片跟着可用宽度均分：那样单卡会到 ~390px，
  /// 而预览是定宽 190 ⇒ 卡片右边空掉一半，看起来像「预览贴左、其余留白」，
  /// 很散。卡片贴合预览宽度后，一组就是 [家族名][卡][卡] 的整齐矩阵。
  static const double preferredWidth = previewWidth + Sp.x2 * 2;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Semantics(
      selected: selected,
      button: true,
      label: '${pack.name}（${pack.brightness == Brightness.dark ? '深色' : '浅色'}）',
      child: InkWell(
        onTap: onTap,
        borderRadius: Radii.rMd,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: Radii.rMd,
            border: Border.all(
              // 选中态用**主色描边**，不靠换底色 —— 换底色会与卡片自己的
              // 预览色打架（预览本来就是那个颜色，看不出变化）。
              color: selected ? cs.primary : cs.outlineVariant,
              width: selected ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(Sp.x2),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              /*
               * ══════════════════════════════════════════════════════════
               * ★★★ 预览必须**保持宽高比**，不许随卡片拉伸（2026-10-17）
               * ══════════════════════════════════════════════════════════
               *
               * # 改前的 bug（Lead 在整屏截图里看出来的）
               * ```text
               * 卡片宽度会随列数变化。900 宽、每行 2 张时单卡约 392px，
               * 而预览是 `height: 66` + 自适应宽 ⇒ 宽高比 5.94:1；
               * 设计基线是 190/66 = 2.88:1 ⇒ **横向被拉伸 2.06 倍**。
               *
               * 后果（这是关键，不是"难看一点"）：
               *   · 圆角从"圆"被拉成"扁椭圆"
               *   · 2.5px 描边在 392px 宽下视觉占比只剩 3.8%（190 时是 6.6%）
               *   ⇒ 新粗野的"粗硬边"被摊薄，看起来和液态玻璃的细边差不多
               *   ⇒ **专门为"看出设计语言"做的预览，反而看不出设计语言了**
               * ```
               *
               * # 修法：固定宽度 + 居中（不选等比放大）
               * ```text
               * 等比放大的话，392px 宽会让高度到 144px，一屏放不下 8 组，
               * 而且组与组之间高度不一，反而更难横向比较。
               * ⇒ 固定 `_kPreviewW = 190`（= 设计基线），卡片变宽时两侧留白。
               *    留白不丑，拉伸失真才丑。
               * ```
               *
               * ⚠️ 191 与 66 这两个数字是**配套契约**：
               *    比值必须落在 `zz_t31b_preview_aspect_test.dart` 断言区间内。
               *    改任一个都要同时改那条门禁，否则预览又会失真。
               */
              Center(
                child: SizedBox(
                  width: ThemeCard.previewWidth,
                  child: _Preview(pack: pack, selected: selected),
                ),
              ),
              const SizedBox(height: Sp.x2),
              Row(
                children: [
                  Expanded(
                    child: Text(
                      // ★ 只标「浅 / 深」—— 家族名已经由外层组标题给了，
                      //   卡片里再写一遍「樱粉·浅」是信息冗余（Lead 指出）。
                      pack.brightness == Brightness.light ? '浅' : '深',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: FontSizes.sm,
                        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                        color: cs.onSurface,
                      ),
                    ),
                  ),
                  /*
                   * ★ 2026-10-17（Lead 指出的不一致，我已目视确认）：
                   *
                   * 原来「预览」只在**未选中**卡上出现、选中卡显示 ✓，
                   * 于是并排时一组两张会出现：左边 ✓、右边 👁。
                   * 实测截图 `.probe/shots/t31b/eye_when_light_selected.png` 里
                   * 看着像「这一组少了个按钮」—— 因为两者图标形状与占位都不同。
                   *
                   * ⇒ 改成：**预览按钮永远在**（只要给了 onPreview），
                   *   选中态用「主色 ✓ + 更暗的预览图标」表达，位置恒定。
                   *   这样一组两张的右侧永远对齐，不再有"缺一块"的错觉。
                   *
                   * ⚠️ 选中那张也保留预览按钮：用户可能想「先看清楚当前这套」
                   *   再决定要不要换。之前认为"重复"是我判断错了。
                   */
                  if (selected)
                    Padding(
                      padding: const EdgeInsets.only(right: Sp.x1),
                      child: Icon(AppIcons.check, size: 16, color: cs.primary),
                    ),
                  if (onPreview != null)
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      child: InkWell(
                        onTap: onPreview,
                        child: Icon(AppIcons.visibility_outlined,
                            size: 16,
                            color: selected
                                ? cs.onSurfaceVariant.withValues(alpha: 0.55)
                                : cs.onSurfaceVariant),
                      ),
                    ),
                  if (onDelete != null)
                    // 命中区域比图标大 —— 16px 的 ✕ 在电视遥控器上点不中
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                      child: InkWell(
                        onTap: onDelete,
                        child: Icon(AppIcons.close, size: 16, color: cs.onSurfaceVariant),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 卡片里的**真实配色 + 真实设计语言**缩略图
///
/// ⚠️ 刻意不用 `Image`/截图：直接用主题自己的 `AppPalette` 画，
///   所以预览与切换后的实际效果**逐色一致**，且零成本。
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ task-31 / 11-B：从「只有颜色」升级为「颜色 + 设计语言」
/// ══════════════════════════════════════════════════════════════════
///
/// # 改前的病灶（Owner 第 14 条要「三套看起来像不同 App」，预览却看不出）
/// ```text
/// 改前本组件只用 `Radii.rSm`(12) 和恒定 1px 描边 ⇒
/// grep 结果：pack.radius / borderWidth / dividerThickness / buttonPadding
///            在本文件里出现 **0 次**
/// ⇒ 新粗野（radius 0 / 2.5px 硬边）与极简（radius 4 / 1px 细边）
///   在预览里**长得几乎一样**，用户根本无法凭预览选出这两套。
/// ```
///
/// # 现在画什么
/// ```text
/// ① 外框     圆角/描边跟 pack（折算，见下）
/// ② 顶栏     主色条（模拟标题栏）
/// ③ 卡片块   圆角跟 pack、描边跟 pack
/// ④ 按钮样本 实心 primary 药丸 + 描边药丸   ← 这是最能体现 borderWidth 的
/// ⑤ 分隔线   粗细 = pack.dividerThickness
/// ⑥ 文字块   正文色 + 次要色
/// ```
///
/// # ⚠️ 折算比例 `_kScale = 0.5`（Lead 已批准）
/// ```text
/// 缩略图只有 66px 高，**不能直接用原值**：
///   玻璃主题 radius=22 ⇒ 直接用会把这张小图挤成胶囊，完全失真。
/// ⇒ **只有圆角乘 0.5**：radius 22 → 11、4 → 2、0 → 0
///
/// ⚠️ 描边与分隔线**不乘**（保原值 1 / 2.5 / 3）：
///    它们本身就在 1~3px 的量级，再乘 0.5 会掉到亚像素 0.5~1.25，
///    抗锯齿后糊成一片灰 —— 反而把「新粗野 2.5px 硬边」这个信号抹掉了，
///    而那一行按钮样本存在的意义正是显示它。
/// ```
///
/// ⚠️ **这是「示意」，不是「像素级还原」** —— 别拿这张图当基准去调真实圆角。
///    真实圆角永远以 `pack.radius` 为准（`theme_language.dart` 里应用）。
class _Preview extends StatelessWidget {
  const _Preview({required this.pack, required this.selected});

  final ThemePack pack;
  final bool selected;

  /// 缩略图里「像素类」维度（圆角）的折算比例
  ///
  /// 只折算圆角，**不折算描边与分隔线** —— 那两者本身就在 1~3px，
  /// 再乘 0.5 会掉到亚像素，抗锯齿后糊成一片灰，反而看不出设计语言差异。
  static const double _kScale = 0.5;

  @override
  Widget build(BuildContext context) {
    final p = pack.palette;
    // ★ 直接取字段，**不解析 cardTheme.shape** ——
    //   shape 的真实类型是 RoundedSuperellipseBorder，不是 RoundedRectangleBorder，
    //   按后者的类型去取 radius 会拿到 -1（我在并排图探针里踩过这个坑）。
    final double r = (pack.radius ?? kDefaultRadius) * _kScale;
    final double bw = pack.borderWidth ?? kDefaultBorderWidth;
    final double div = pack.dividerThickness ?? kDefaultDividerThickness;
    return Container(
      height: 66,
      decoration: BoxDecoration(
        color: p.background,
        borderRadius: BorderRadius.all(Radius.circular(r)),
        border: Border.all(color: p.border, width: bw),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // ① 顶栏：主色（模拟标题栏 / 强调区域）
          Container(height: 12, color: p.primary),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(5, 4, 5, 3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // ② 左：一张"卡片" —— 圆角与描边都跟 pack
                        Container(
                          width: 26,
                          decoration: BoxDecoration(
                            color: p.card,
                            borderRadius:
                                BorderRadius.all(Radius.circular(r)),
                            border: Border.all(color: p.border, width: bw),
                          ),
                        ),
                        const SizedBox(width: 5),
                        // ③ 右：两行文字块（正文色 + 次要色）
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Container(height: 4, color: p.foreground),
                              const SizedBox(height: 3),
                              FractionallySizedBox(
                                widthFactor: 0.62,
                                child:
                                    Container(height: 4, color: p.mutedForeground),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 3),
                  // ④ 按钮样本 —— **最能体现 borderWidth 的一行**
                  //
                  //    实心药丸 = 主色底；描边药丸 = 只有边、无填充。
                  //    新粗野(2.5px) 与极简(1px) 在这一行的差别最明显。
                  Row(
                    children: [
                      Container(
                        width: 22,
                        height: 8,
                        decoration: BoxDecoration(
                          color: p.primary,
                          borderRadius: BorderRadius.all(
                            Radius.circular(r == 0 ? 0 : 999),
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Container(
                        width: 18,
                        height: 8,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.all(
                            Radius.circular(r == 0 ? 0 : 999),
                          ),
                          border: Border.all(color: p.primary, width: bw),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 3),
                  // ⑤ 分隔线样本 —— 粗细跟 pack.dividerThickness
                  Container(height: div, color: p.border),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 单套主题的**大预览** —— 用真实组件展示这套主题长什么样
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ task-31 / 11-B 第 2 步：把「只有色块」升级为「真实组件」
/// ══════════════════════════════════════════════════════════════════
///
/// # 为什么需要它
/// ```text
/// 66px 缩略图能看出「设计语言」，但看不出「组件实际手感」：
/// 按钮多高、描边多粗、输入框圆不圆、开关什么比例 —— 都得真画出来。
/// 而当前唯一能「看结果」的方式是点一下卡（整站真的换主题），
/// 换错了还得再点回来 ⇒ 那是「试了就换」，不是「先看再换」。
/// ```
///
/// # 三条实现约束（Lead 明确要求）
/// ```text
/// ① **不用 ListTile 家族**：它的水波画在最近的 Material 祖先上，
///    中间隔一层带底色的 DecoratedBox 就被盖住（Flutter 会直接断言
///    "ListTile background color or ink splashes may be invisible"）。
///    ⇒ 全部用 Container + Row 自己拼。
/// ② 按钮**必须真的可点**（onPressed 不能传 null）：
///    传 null 会渲染成禁用态（灰掉、降透明度），那看不出主题的真实按钮。
/// ③ 外面包一层 `Theme(data: 该 pack 的 ThemeData)`，
///    这样里面所有 Material 组件都按该主题渲染，而不是当前站点的主题。
/// ```
///
/// ⚠️ 这里用的是 `AppTheme.themeForPack(pack.brightness, pack)`，
///    与站点实际切换后**完全同一个函数** ⇒ 预览与实物逐像素同源，
///    不会出现「预览好看、切过去不一样」。
class ThemePreviewBody extends StatelessWidget {
  const ThemePreviewBody({required this.pack, super.key});

  final ThemePack pack;

  @override
  Widget build(BuildContext context) {
    // ★ 与真实切换同源：同一个 themeForPack，不是自己拼一份近似主题。
    final td = AppTheme.themeForPack(pack.brightness, pack);
    final p = pack.palette;
    final double r = pack.radius ?? kDefaultRadius;
    final double bw = pack.borderWidth ?? kDefaultBorderWidth;
    final double div = pack.dividerThickness ?? kDefaultDividerThickness;

    Widget label(String text) => Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text(
            text,
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: p.mutedForeground,
            ),
          ),
        );

    return Theme(
      data: td,
      child: Container(
        width: 460,
        color: p.background,
        padding: const EdgeInsets.all(Sp.x4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 按钮三态 ──
            label("按钮"),
            Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                FilledButton(
                  onPressed: () {},
                  child: const Text("主按钮"),
                ),
                OutlinedButton(
                  onPressed: () {},
                  child: const Text("次按钮"),
                ),
                TextButton(
                  onPressed: () {},
                  child: const Text("文字按钮"),
                ),
              ],
            ),
            const SizedBox(height: Sp.x4),

            // ── 开关两态 ──
            label("开关"),
            Row(
              children: [
                Switch(value: true, onChanged: (_) {}),
                const SizedBox(width: Sp.x3),
                Switch(value: false, onChanged: (_) {}),
              ],
            ),
            const SizedBox(height: Sp.x4),

            // ── 输入框（只读展示，不抢焦点）──
            label("输入框"),
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: Sp.x3),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.all(Radius.circular(r)),
                border: Border.all(color: p.border, width: bw),
              ),
              child: Text(
                "占位提示文字",
                style: TextStyle(fontSize: FontSizes.sm, color: p.mutedForeground),
              ),
            ),
            const SizedBox(height: Sp.x4),

            // ── 卡片（标题 + 正文 + 分隔线）──
            label("卡片"),
            Container(
              padding: const EdgeInsets.all(Sp.x3),
              decoration: BoxDecoration(
                color: p.card,
                borderRadius: BorderRadius.all(Radius.circular(r)),
                border: Border.all(color: p.border, width: bw),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    "卡片标题",
                    style: TextStyle(
                      fontSize: FontSizes.base,
                      fontWeight: FontWeight.w600,
                      color: p.foreground,
                    ),
                  ),
                  const SizedBox(height: Sp.x1),
                  Text(
                    "这是正文，用正文色；下一行是次要说明，用次要色。",
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: p.foreground,
                    ),
                  ),
                  const SizedBox(height: Sp.x2),
                  // 分隔线：粗细跟 pack.dividerThickness
                  Container(height: div, color: p.border),
                  const SizedBox(height: Sp.x2),
                  Text(
                    "分隔线之下 · mutedForeground",
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: p.mutedForeground,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
