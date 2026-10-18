// ═══════════════════════════════════════════════════════════════════════
//  播放页右侧「弹幕信息」面板
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 在播放页面右侧显示加载了哪些弹幕,方便排查问题(要优化ui)
// ```
//
// # 它回答哪四个问题（这决定了字段，不是先画框再想填什么）
// ```text
// ① 来自于谁      —— bili直连 / danmaku-service / 本机弹弹play / 插件 / 已载入文件
// ② 载入了多少    —— 条数（0 与"没问过"必须能区分，见 count 的可空性）
// ③ 怎么对上的    —— 手动绑定 / 自动匹配 / 番剧季(season)兜底 / 未匹配
// ④ 为什么没来    —— 失败原因原文（服务端的 X-Error-Message 照透）
// ```
//
// # 为什么单独抽一个 widget 而不是塞进 player_page
// ```text
// player_page.dart 已经两万行。这块是**纯展示**（不碰网络/播放器/令牌），
// 抽出来才能被单独挂载、单独截图、单独断言 —— 也才可能在真机外验证。
// 分工与 danmaku_settings_dialog 一致：宿主持有状态，面板只管画。
// ```
//
// # ⚠️ 为什么不用 Material 的 Card/ListTile
// 这一层浮在**视频画面**上（底下是任意颜色/运动的像素），Material 的
// `surfaceContainerHighest` 在亮画面里会糊成一团。所以这里用
// **高不透明度的深色底 + 亮描边 + 白字**（与播放器其余浮层同款），
// 不读取主题的 surface 槽位 —— 那是给"页面底"用的，不是给"画面浮层"用的。
library;

import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    show GlassContainer, LiquidRoundedRectangle;
import 'package:material_ui/material_ui.dart';

import '../../design/widgets/app_ink_well.dart';
import '../tokens.dart';
import '../../design/icons/app_icons.dart';

/// 一条弹幕来源
enum DanmakuFeedKind {
  /// 外部视频站直连（cid ⇒ comment.xml），**不需要任何凭证**
  bili,

  /// danmaku-service（要 AppId/AppSecret；没配就是用户看到的那句 403）
  service,

  /// 本机内嵌的弹弹play 桌面端（127.0.0.1，免签名）
  localDanmaku,

  /// 自建的 danmaku-service 兼容后端
  selfHosted,

  /// 本地弹幕库里的某个文件
  library,

  /// 还没取 / 不知道
  none,
}

/// 宿主侧别名 —— 让 `player_page.dart` 读作 `DanmakuInfoSource.bili`，
/// 与那几个 `_infoXxx` 字段同一个家族（它们都叫 `DanmakuInfo*`）。
typedef DanmakuInfoSource = DanmakuFeedKind;
typedef DanmakuInfoMatch = DanmakuPairKind;

extension DanmakuFeedKindX on DanmakuFeedKind {
  String get label => switch (this) {
        DanmakuFeedKind.bili => '外部视频站直连',
        DanmakuFeedKind.service => 'danmaku-service',
        DanmakuFeedKind.localDanmaku => '本机弹弹play',
        DanmakuFeedKind.selfHosted => '自建弹幕服务',
        DanmakuFeedKind.library => '本地弹幕库',
        DanmakuFeedKind.none => '未取到',
      };

  /// 图标：让人**不看字**也能认出是哪一类
  IconData get icon => switch (this) {
        DanmakuFeedKind.bili => AppIcons.cloud_download_outlined,
        DanmakuFeedKind.service => AppIcons.dns_outlined,
        DanmakuFeedKind.localDanmaku => AppIcons.computer_outlined,
        DanmakuFeedKind.selfHosted => AppIcons.storage_outlined,
        DanmakuFeedKind.library => AppIcons.folder_open_outlined,
        DanmakuFeedKind.none => AppIcons.help_outline,
      };
}

/// 这一集是怎么和某个弹幕源对上的
enum DanmakuPairKind {
  /// 用户自己填 cid / BV / 选了一条搜索结果
  manual,

  /// 自动按标题搜索匹配
  autoSearch,

  /// 自动走 pgc/view/web/season（search 不可用时的兜底）
  autoSeason,

  /// 直接指定（外部传入 / 本地文件），没有"匹配"这一步
  direct,

  /// 没对上
  none,
}

extension DanmakuPairKindX on DanmakuPairKind {
  String get label => switch (this) {
        DanmakuPairKind.manual => '手动绑定',
        DanmakuPairKind.autoSearch => '自动匹配',
        DanmakuPairKind.autoSeason => '番剧季兜底',
        DanmakuPairKind.direct => '直接指定',
        DanmakuPairKind.none => '未匹配',
      };

  /// 兜底链路要**显眼** —— 它是"正经路走不通才走的"，排查时最该被看见
  bool get isFallback => this == DanmakuPairKind.autoSeason;
}

/// 面板要显示的全部事实
///
/// ⚠️ 全都是**只读快照**：面板不回调、不改状态。要操作请去弹幕设置面板。
///    这条分工让本 widget 可以在任何宿主里被单独挂载（含纯截图）。
@immutable
class DanmakuInfoData {
  const DanmakuInfoData({
    this.source = DanmakuFeedKind.none,
    this.match = DanmakuPairKind.none,
    this.count,
    this.total,
    this.title,
    this.cid = 0,
    this.detail,
    this.error,
    this.loading = false,
    this.enabled = false,
    this.aggregate = const <DanmakuAggregateFeed>[],
  });

  final DanmakuFeedKind source;
  final DanmakuPairKind match;

  /// 已载入条数。
  ///
  /// ⚠️ **可空**：`null` = 压根没问过这个源（例如没绑定外部视频站时
  ///    "外部站有几条"是未知，不是 0）。把未知画成 0 就是在撒谎，
  ///    排查问题的人会照着 0 去查一个根本不存在的空数据。
  final int? count;

  /// 服务端声称的总数（有就显示 `已载入 N / 共 M`）
  final int? total;

  /// 绑到了哪个作品/哪一集（给"绑错了吧"这类问题提供第一现场）
  final String? title;

  /// 外部视频站的 cid（0 = 没有）。排查时最常用的那串数字。
  final int cid;

  /// 附加说明（版本号 / 端点 / 文件名…）
  final String? detail;

  /// 失败原因**原文**（服务端的 X-Error-Message 等照样透出，不要改写）
  final String? error;

  final bool loading;

  /// 弹幕总开关是否开着 —— 关着时即使有数据也不会上屏，这一点必须说出来
  final bool enabled;

  /// ★★★ 2026-10-17（Owner 第 9 条）：**聚合**时每一路来源的读数。
  ///
  /// # 为什么必须逐路列出来
  /// ```text
  /// Owner 原话：「有些网站本身也提供弹幕,我们要支持弹幕的聚合」
  /// ⇒ 只显示一个总数是不够的：用户看到"1900 条"，
  ///   但想知道**这 1900 条分别来自谁**（插件给了多少、dan-api 给了多少、
  ///   哪一路失败了）。这正是「方便排查问题」的全部意义。
  /// ```
  ///
  /// ⚠️ 空列表 = 没聚合（单源），面板退化成原来的样子。
  /// ⚠️ 这里的元素**必须**包含失败的那几路 —— 悄悄少显示一路，
  ///    用户会以为"聚合只来了一半，不知道为什么"。
  final List<DanmakuAggregateFeed> aggregate;

  bool get hasError => error != null && error!.isNotEmpty;

  /// 面板是否该有内容（全空时宿主可以直接不画）
  bool get isBlank =>
      source == DanmakuFeedKind.none &&
      count == null &&
      !hasError &&
      !loading &&
      aggregate.isEmpty;
}

/// 面板要显示的一路聚合来源（与 core 的 `DanmakuFeedStat` 同形，
/// 但**不直接引用 core** —— 理由见文件头「为什么单独抽一个 widget」）。
@immutable
class DanmakuAggregateFeed {
  const DanmakuAggregateFeed({
    required this.label,
    required this.count,
    this.detail = '',
    this.error = '',
    this.loaded = true,
  });

  /// 给用户看的来源名（例：`插件` / `dan-api` / `本机`）
  final String label;

  /// 这一路贡献的条数（**去重前**）
  final int count;

  /// 附加说明（来源名 / 端点 / 版本）
  final String detail;

  /// 失败原文（空 = 没失败）
  final String error;

  /// 这一路是否真的被尝试过（false = 没试，例如插件不支持弹幕）
  final bool loaded;

  bool get failed => error.isNotEmpty;
}

/// 播放页右侧那个可折叠的「弹幕信息」面板
///
/// # 交互（只有三件事，刻意做少）
/// ```text
/// 收起态  一枚窄条（图标 + 条数），点一下展开
/// 展开态  一张卡片（来源 / 条数 / 匹配 / 失败原因 / cid）
/// 关闭    展开态右上角 ×，收回到窄条（面板**不会消失**，避免用户找不到）
/// ```
///
/// ⚠️ 它**不挡内容**：收起态只有一枚窄条；展开态的宽度有上限（[maxWidth]），
///    并且整体贴右边缘 —— 播放器控件都在中/下部，右上角是空的。
class DanmakuInfoPanel extends StatefulWidget {
  const DanmakuInfoPanel({
    super.key,
    required this.data,
    this.maxWidth = 300,
    this.initiallyExpanded = false,
    this.onRequestClose,
  });

  final DanmakuInfoData data;

  /// 展开态的最大宽度 —— 窄屏（手机竖屏）时宿主应传更小的值
  final double maxWidth;

  final bool initiallyExpanded;

  /// 收起回调 —— 宿主借它把面板收起来（顶栏那枚 pill 就是这么用的：
  /// 点一次开、再点一次关，**同一个**回调）。
  ///
  /// ⚠️ 与内部那枚 × 的区别：× 只把**本面板**收成窄条（面板还在），
  ///    而本回调让宿主决定要不要整块隐藏。两者刻意分开 ——
  ///    "收起"与"不要它了"是两件事。
  final VoidCallback? onRequestClose;

  @override
  State<DanmakuInfoPanel> createState() => _DanmakuInfoPanelState();
}

class _DanmakuInfoPanelState extends State<DanmakuInfoPanel>
    with SingleTickerProviderStateMixin {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    return AnimatedSize(
      duration: Motion.fast,
      curve: Motion.easeOut,
      alignment: Alignment.topRight,
      child: _expanded ? _buildExpanded(context) : _buildCollapsed(context),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  收起态 —— 一枚窄条
  // ══════════════════════════════════════════════════════════════════
  Widget _buildCollapsed(BuildContext context) {
    final d = widget.data;
    final bad = d.hasError;
    return Tooltip(
      message: bad ? '弹幕信息（有失败，点开看原因）' : '弹幕信息',
      child: _Surface(
        onTap: () => setState(() => _expanded = true),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Sp.x3,
            vertical: Sp.x2,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                bad ? AppIcons.error_outline : d.source.icon,
                size: 15,
                color: bad ? _danger : _fgDim,
              ),
              const SizedBox(width: Sp.x2),
              Text(
                bad ? '弹幕' : _shortCount(d),
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: bad ? _danger : _fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: Sp.x1),
              const Icon(AppIcons.chevron_left, size: 15, color: _fgDim),
            ],
          ),
        ),
      ),
    );
  }

  String _shortCount(DanmakuInfoData d) {
    if (d.loading) return '取弹幕…';
    final c = d.count;
    if (c == null) return '弹幕 —';
    return '弹幕 $c';
  }

  // ══════════════════════════════════════════════════════════════════
  //  展开态 —— 一张卡片
  // ══════════════════════════════════════════════════════════════════
  Widget _buildExpanded(BuildContext context) {
    final d = widget.data;
    return _Surface(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxWidth: widget.maxWidth),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x3, Sp.x2, Sp.x2, Sp.x3),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _header(),
              const SizedBox(height: Sp.x2),
              if (d.loading) _loadingRow(),
              if (d.loading) const SizedBox(height: Sp.x2),
              _sourceRow(d),
              if (d.title != null && d.title!.isNotEmpty) ...[
                const SizedBox(height: Sp.x2),
                _kv(
                  label: '作品',
                  value: d.title!,
                ),
              ],
              const SizedBox(height: Sp.x2),
              _countRow(d),
              if (d.aggregate.isNotEmpty) ...[
                const SizedBox(height: Sp.x2),
                _aggregateRows(d),
              ],
              const SizedBox(height: Sp.x2),
              _matchRow(d),
              if (d.cid > 0) ...[
                const SizedBox(height: Sp.x2),
                _kv(label: 'cid', value: '${d.cid}'),
              ],
              if (d.detail != null && d.detail!.isNotEmpty) ...[
                const SizedBox(height: Sp.x2),
                _kv(label: '详情', value: d.detail!),
              ],
              if (d.hasError) ...[
                const SizedBox(height: Sp.x3),
                _errorBox(d.error!),
              ],
              if (!d.enabled && !d.hasError) ...[
                const SizedBox(height: Sp.x3),
                _hint(
                  AppIcons.pause_circle_outline,
                  '弹幕开关是关的 —— 有数据也不会上屏。',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _header() => Row(
        children: [
          const Icon(AppIcons.subtitles_outlined, size: 16, color: _fg),
          const SizedBox(width: Sp.x2),
          const Padding(
            padding: EdgeInsets.only(top: 1),
            child: Text(
              '弹幕信息',
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: _fg,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.2,
              ),
            ),
          ),
          const Spacer(),
          _IconHit(
            icon: AppIcons.close,
            tooltip: '收起',
            // 宿主给了回调就交给宿主（整块隐藏），否则只收成窄条。
            onTap: widget.onRequestClose ??
                () => setState(() => _expanded = false),
          ),
        ],
      );

  Widget _loadingRow() => const Row(
        children: [
          SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: _fgDim),
          ),
          SizedBox(width: Sp.x2),
          Text(
            '正在取弹幕…',
            style: TextStyle(fontSize: FontSizes.cap, color: _fgDim),
          ),
        ],
      );

  Widget _sourceRow(DanmakuInfoData d) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(d.source.icon, size: 15, color: _accent),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              d.source.label,
              style: const TextStyle(
                fontSize: FontSizes.sm,
                color: _fg,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      );

  Widget _countRow(DanmakuInfoData d) {
    final c = d.count;
    final text = c == null
        ? '—（未查询）'
        : (d.total != null && d.total! > 0 ? '$c / 共 ${d.total} 条' : '$c 条');
    return _kv(
      label: '已载入',
      value: text,
      // 条数是有信息量的主数据，稍微重一点
      strong: c != null && c > 0,
    );
  }

  /// 聚合的每一路来源（Owner 第 9 条）
  ///
  /// # 为什么用"标签列 + 每路一行"而不是一句话
  /// ```text
  /// 一行话（"2 路 · 插件 1200 + 导入 800 = 1900 条"）在窄面板里会折成三行，
  /// 而且**失败的那一路**没法突出（它是排查时最该被看见的）。
  /// ⇒ 每路一行，失败的用橙色 + 原文，能一眼扫到。
  /// ```
  ///
  /// ⚠️ 条数是**这一路自己**的条数（去重前），与 `_countRow` 的合并条数
  ///    不是同一个数 —— 两者同时显示才说明"合并掉了多少重复"。
  Widget _aggregateRows(DanmakuInfoData d) {
    final feeds = d.aggregate;
    final sum = feeds.fold<int>(0, (a, f) => a + f.count);
    final deduped = sum - (d.count ?? sum);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(
              width: 52,
              child: Text(
                '来源',
                style: TextStyle(fontSize: FontSizes.cap, color: _fgDim),
              ),
            ),
            Expanded(
              child: Text(
                feeds.length > 1
                    ? '${feeds.where((f) => f.loaded && !f.failed && f.count > 0).length} 路'
                        '${deduped > 0 ? "（合并去重 $deduped 条）" : ""}'
                    : '单源',
                style: const TextStyle(fontSize: FontSizes.cap, color: _fgDim),
              ),
            ),
          ],
        ),
        for (final f in feeds)
          Padding(
            padding: const EdgeInsets.only(top: Sp.x1),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(width: 52),
                Icon(
                  f.failed
                      ? AppIcons.error_outline
                      : (f.loaded
                          ? AppIcons.check_circle_outline
                          : AppIcons.remove),
                  size: 12,
                  color: f.failed ? _warn : _fgDim,
                ),
                const SizedBox(width: Sp.x1),
                Expanded(
                  child: Text(
                    /*
                     * ★ 2026-10-18（task-66 看图台抓到的排版缺陷）
                     *
                     * # 改前
                     * ```text
                     * '${f.label}：失败 · ${f.error}' 配 maxLines:3
                     * ⇒ 错误原文一长（"这个源没有提供弹幕数据"就够长了）
                     *   就折成两行半、**压到下一行「匹配」上**，
                     *   两段文字叠在一起，谁都读不出来。
                     *   实测截图见 .probe/shots_t66/（改前那张已覆盖）。
                     * ```
                     * # 改后
                     * ```text
                     * 失败那一路只在这行说"谁失败了"（单行）；
                     * 上游原文**独占下一行**（见下面第二个 for）。
                     * ⇒ 原文再长也只往下长，不横向挤压别的字段。
                     * ```
                     * ⚠️ 原文仍然**照透**，只是给了它自己的行 —— 不是截断它。
                     */
                    f.failed
                        ? '${f.label}：失败'
                        : (f.loaded
                            ? '${f.label}：${f.count} 条'
                            : '${f.label}：未提供'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: f.failed ? _warn : _fg,
                      fontFeatures: const <FontFeature>[
                        FontFeature.tabularFigures(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        // 失败那一路的上游原文：**独占一行**（理由见上面那段）
        for (final f in feeds)
          if (f.failed && f.error.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 与上面那个 count/label 文本的左边对齐：
                  // 52（label 栏）+ 12（图标）+ Sp.x1（图标后间距）
                  const SizedBox(width: 52 + 12 + Sp.x1),
                  Expanded(
                    child: Text(
                      f.error,
                      style: const TextStyle(
                        fontSize: FontSizes.cap,
                        color: _warn,
                      ),
                    ),
                  ),
                ],
              ),
            ),
      ],
    );
  }

  Widget _matchRow(DanmakuInfoData d) {
    final m = d.match;
    final fallback = m.isFallback;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(
          width: 52,
          child: Text(
            '匹配',
            style: TextStyle(fontSize: FontSizes.cap, color: _fgDim),
          ),
        ),
        Expanded(
          child: Row(
            children: [
              Flexible(
                child: Text(
                  m.label,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: fallback ? _warn : _fg,
                    fontWeight: fallback ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              if (fallback) ...[
                const SizedBox(width: Sp.x2),
                _pill(
                  text: '备用链路',
                  color: _warn,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _kv({
    required String label,
    required String value,
    bool strong = false,
  }) =>
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 52,
            child: Text(
              label,
              style: const TextStyle(fontSize: FontSizes.cap, color: _fgDim),
            ),
          ),
          Expanded(
            child: Text(
              value,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: strong ? _fg : _fgDim,
                fontWeight: strong ? FontWeight.w600 : FontWeight.w400,
                fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      );

  Widget _pill({required String text, required Color color}) => Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 1),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.16),
          borderRadius: BorderRadius.circular(Radii.xs),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 11,
            color: color,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  Widget _hint(IconData icon, String text) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 14, color: _fgDim),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: Text(
              text,
              style: const TextStyle(fontSize: 11, color: _fgDim, height: 1.35),
            ),
          ),
        ],
      );

  /// 失败原因 —— 整块换色 + 可滚动，因为服务端原文可能很长
  Widget _errorBox(String error) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(Sp.x2),
        decoration: BoxDecoration(
          color: _danger.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(Radii.xs),
          border: Border.all(color: _danger.withValues(alpha: 0.45)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(AppIcons.error_outline, size: 14, color: _danger),
                SizedBox(width: Sp.x2),
                Text(
                  '失败原因',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: _danger,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: Sp.x1),
            ConstrainedBox(
              // 原文可能几百字；给个上限，用户仍可读全（换行不限行数）
              constraints: const BoxConstraints(maxHeight: 140),
              child: SingleChildScrollView(
                child: Text(
                  error,
                  style: const TextStyle(
                    fontSize: 11,
                    color: _danger,
                    height: 1.4,
                  ),
                ),
              ),
            ),
          ],
        ),
      );
}

// ══════════════════════════════════════════════════════════════════════
//  画面上浮层的取色 —— 刻意**不**读 colorScheme
// ══════════════════════════════════════════════════════════════════════
//
// ⚠️ 为什么不用主题槽位：面板浮在**视频画面**上，底下的像素可以是白的
//    （雪景）、红的（爆炸）、彩的（动画）。Material 的 surface 角色是给
//    "页面底"设计的，放在画面上会糊掉。所以这里是一套**固定的暗浮层色**，
//    与 player_popover / 播放器底栏同源（它们也不读 surface）。
/// ★ 2026-10-18（任务 B-3）：**不再使用** —— 玻璃化后遮光由
/// `GlassContainer` + 一层 40% 的淡染色承担（见 `_Surface`）。
///
/// 保留这个常量是为了记录**原来那个 90% 的值**：
/// 将来若要回退玻璃、回到"实色浮层"，直接用它就是改前的观感。
// ignore: unused_element
const Color _scrim = Color(0xE6101216);
const Color _fg = Color(0xFFF2F4F8);
const Color _fgDim = Color(0xFF9BA2AE);
const Color _accent = Color(0xFF7FB2FF);
const Color _warn = Color(0xFFFFB454);
const Color _danger = Color(0xFFFF6B6B);

/// 面板的"外壳"：玻璃材质 + 1px 描边 + 圆角 + 极轻阴影
///
/// ★★ 2026-10-18（任务 B-3，Owner 要玻璃材质）
/// ```text
/// 改前：`color: _scrim` = Color(0xE6101216)，即 **90% 不透明**的深色。
///   那个不透明度下"玻璃"和"实色"在视觉上几乎无法区分 ——
///   透不出底下的画面，材质就没有意义。
///
/// 改后：外面套 `GlassContainer`（模糊 + 半透明 + 描边），
///   `_scrim` 降为**很淡**的一层染色（不再承担遮光职责）。
/// ```
/// ⚠️ 为什么仍保留一层淡色：本面板浮在**视频画面**上，
///    画面可能是雪景（亮）也可能是夜景（暗）。纯玻璃在亮画面上
///    会让白字失去对比度 ⇒ 用一层淡染色兜底（`t27_w1` 的对比度口径）。
class _Surface extends StatelessWidget {
  const _Surface({required this.child, this.onTap});

  final Widget child;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final box = DecoratedBox(
      decoration: BoxDecoration(
        /*
         * ★ 2026-10-18：0xE6（90%）→ 0x66（40%）。
         *   模糊与半透明由外层 GlassContainer 提供，
         *   这一层只做"保底压暗"，不再独自遮光。
         */
        color: const Color(0x66101216),
        borderRadius: BorderRadius.circular(Radii.sm),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 18,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(Radii.sm),
        // ★ 去 Material（Owner 第 4/8/9 条，2026-10-17）
        //   这里 Material 完全透明、只给水波提供绘制面 ⇒ 换 AppInkWell 自绘高亮。
        //   ⚠️ 分类脚本把它归成 B 类（看到 color: 就判"真卡片"），
        //      但那是 Colors.transparent —— 脚本判据不精确，人工判断为准。
        child: AppInkWell(
          onTap: onTap,
          child: child,
        ),
      ),
    );
    /*
     * ★★ 2026-10-18（任务 B-3）：玻璃材质。
     *
     * 放在**最外层**，里面仍是原来的 DecoratedBox + ClipRRect + AppInkWell
     * ⇒ 布局与交互一字未改，只是多了一层材质。
     */
    return GlassContainer(
      shape: LiquidRoundedRectangle(borderRadius: Radii.sm),
      padding: EdgeInsets.zero,
      child: box,
    );
  }
}

/// 小图标按钮（36 命中区，视觉 22）—— 展开态右上角那枚 ×
class _IconHit extends StatelessWidget {
  const _IconHit({
    required this.icon,
    required this.onTap,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final t = Tooltip(
      message: tooltip ?? '',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(Radii.xs),
        child: SizedBox(
          width: 26,
          height: 26,
          child: Icon(icon, size: 16, color: _fgDim),
        ),
      ),
    );
    return tooltip == null ? t : t;
  }
}
