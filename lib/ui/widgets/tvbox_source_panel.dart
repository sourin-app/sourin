// ═══════════════════════════════════════════════════════════════════════
//  TVBox 订阅链接 + 检测更新（task-12）
// ═══════════════════════════════════════════════════════════════════════
//
// # 用户拍板
//
// > 填入 tvbox 源的链接，然后他有更新我们也能收得到，
// > 不至于更新失效了，之前的插件也是一样的处理
//
// # 与插件那套（`_PluginUpdateDialog`，task-23）的关系
//
// 完全同构，只差一处：
// ```text
// 插件    1 个 .js   ↔ 1 个安装链接 → 一个 id 一个 sidecar 文件
// TVBox   1 份配置   ↔ 1 个订阅链接 → 一份配置产出几十个源
// ```
// 所以 TVBox 的「检测更新」是**按链接**做的：一次下载对比全部源，
// 而不是每个源各下一遍。用户从任意一张卡点进来，看到的都是
// **同一条链接的同一份结果**。
//
// # ★★ 最重要的产品原则：没有的能力不假装有
//
// ```text
// 直接贴 JSON 文本导入的源 → 没有链接可查
//   → 卡片上**不画**「检测更新」入口，只如实说明「无订阅链接」
//   → 绝不显示成「已是最新」（那是假装查过了）
// ```
// 这条与 `settings_page.dart` 的 `onPluginUpdate == null` 是同一条：
// 宁可少一个按钮，也不能给一个点了没反应的按钮。
//
// # 为什么抽成独立 widget 文件
//
// `settings_page.dart` 上同时有 3~4 个代理在改（task-13 / task-14）。
// 把「订阅更新」做成**自包含** widget（只依赖 `SourinApi`），页面那边
// 只留「打开它」一行，冲突面最小 —— 理由与 `provider_import_dialog.dart`
// 的头部注释完全一致。
//
// # 三种结局都不许静默（与 `PluginUpdateInfo` 同一条）
//
// ```text
// ① 没有订阅链接     → 进 skipped，如实说「查不了」
// ② 网络 / 解析失败   → 红字显示**失败原因**
// ③ 查到了           → 新增 / 变更 / 已消失 / 未变，逐条列出来
// ```

import 'package:material_ui/material_ui.dart';

import '../../core/ffi.dart' show userErrorText;
import '../../core/sourin_api.dart';
import '../../design/widgets/app_glass_dialog.dart';
import '../../design/widgets/app_text_button.dart';
import 'overlay_motion.dart';
import '../tokens.dart';
import '../../design/icons/app_icons.dart';

/// 把一条检测结果压成一行中文摘要（面板与弹窗共用）
///
/// ⚠️ **失败绝不返回「已是最新」** —— 那是本功能唯一不能犯的错。
String tvboxUpdateSummary(TvboxUpdateItem it) {
  if (it.multiRepo) {
    return '远端现在是一份「多仓」配置（只有 urls，没有 sites）';
  }
  if (!it.ok) {
    final why = (it.error ?? '').trim();
    return why.isEmpty ? '检测失败（后端没有给出原因）' : '检测失败：$why';
  }
  final parts = <String>[];
  if (it.added.isNotEmpty) parts.add('新增 ${it.added.length}');
  if (it.changed.isNotEmpty) parts.add('变更 ${it.changed.length}');
  if (it.removed.isNotEmpty) parts.add('远端已消失 ${it.removed.length}');
  if (parts.isEmpty) {
    return '已是最新（远端 ${it.remoteConvertible} 个可转换站点）';
  }
  return parts.join(' · ');
}

// ═══════════════════════════════════════════════════════════════════════
//  N8b-2（2026-10-27）：聚合源一行 = 链接可改 / 测试连通 / 立即更新
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// > tvbox聚合源本来就是一个链接，要主动更新的，现在我都不能编辑和替换地址了。
// > tvbox聚合源应该可以自己起名字、可以编辑链接、可以测试这个聚合源是否能用。
// ```
//
// # 本项交付三个操作（**第四个「名字可改」本批做不了，见下**）
// ```text
// ① 链接可改     set_tvbox_source(id, url)          —— 命令已有
// ② 测试连通     check_tvbox_updates(id)            —— 命令已有（真网络三态）
// ③ 立即更新     update_tvbox_source(id, ...)       —— 命令已有
// ```
//
// # ★★★ 「名字可改」——**点名 Rust 侧缺口，不做假入口**（Lead 裁定 A）
// ```text
// 取证：ffi.rs 全部 131 条 dispatch 里**没有任何** rename / set_name / alias 命令；
//      `set_tvbox_source` 只收 {id,url}、`update_tvbox_source` 只收
//      {id,applyNew,deleteMissing}；`save_override_layer` 是**数据变换层**
//      （overrides.rs:312 `apply_override` 按 call_js 方法名作用于 list/detail
//      的结果数据），**不碰 manifest.name** —— 而 `list_providers` 下发的
//      正是 manifest.name。
//      `TvboxSourceMeta.site_name` 字段存在（tvbox.rs:2113），但**没有任何
//      命令写它**（只有 `set_tvbox_source` 在 old.site_name 为空时用 manifest 名兜底）。
// ⇒ 本批**不画**改名入口（画一个点了没反应的输入框 = 假 UI，
//   与仓库既有原则「没有的能力不假装有」一致）。
// ⇒ 如实地在 UI 上说明这件事（见 [TvboxAggregateManageNote]）。
// ```
//
// # 为什么「测试连通」用 `check_tvbox_updates` 而不是 plan 字面写的「csp home 探测」
// ```text
// （Lead 裁定 A，我复核过两条指控均成立）
// ① `probe_site` / `csp::provider::probe_categories` 只被导入路径内部调用，
//    **无任何命令暴露**给 Dart。
// ② 已导入的 csp 源走 `get_categories` 时，`categories_or_probe()` 有短路：
//    `if !self.classes.is_empty() { return Ok(self.classes.clone()) }`
//    （csp/provider.rs:191-194）—— classes 由导入时的配置预填 ⇒ **零网络**。
//    ⇒ 拿它当"测试连通"会**恒绿**（假门禁）。
// ③ `health_sweep` → `health_check()` 基类**默认恒 return true**
//    （provider.rs:571-573），csp/tvbox 均未覆写 ⇒ 对死掉的源**假报 true**。
// ⇒ 三者都测不出"这个聚合源还能不能用"。
// `check_tvbox_updates(id)` 是**唯一**真发网络请求、且三态齐全（无链接 /
// 失败带原因 / ok+变更）的原语，语义上也吻合「聚合源本来就是一个链接」。
// ```

/// 「测试连通」的**三态**结论（纯数据 + 纯函数 ⇒ 门禁可离线断定）
///
/// # 为什么必须三态而不是布尔
/// ```text
/// 布尔把两件事挤成一件：
///   · 「没有订阅链接」= 查不了（用户要补链接，不是"坏掉了"）
///   · 「网络/解析失败」= 真失败（要重试或换链接）
/// 而"失败"若显示成"已是最新"就是这个功能唯一不能犯的错
/// （`tvboxUpdateSummary` 的注释记着同一条）。
/// ```
enum TvboxProbeState {
  /// 还没测过（**与"测了但失败"是两回事**）
  idle,

  /// 正在测
  running,

  /// ① 这个源没有订阅链接 ⇒ 如实说"查不了"，并指出怎么补
  noLink,

  /// ② 真发请求了，但失败（网络 / 解析 / 多仓）⇒ 带**后端给的原因**
  failed,

  /// ③ 真发请求了，成功 ⇒ 报远端可转换站点数 / 变更多少
  ok,
}

/// 「测试连通」的结果（三态 + 文案 + 是否「不能用」）
class TvboxProbeResult {
  const TvboxProbeResult({
    required this.state,
    required this.text,
    this.detail,
  });

  final TvboxProbeState state;

  /// 一行结论（界面直接显示）
  final String text;

  /// 失败时的**具体原因**（后端原文；没有就 null —— 不编一个）
  final String? detail;

  /// ★ 判据：这个聚合源现在**用不了**吗？
  ///
  /// ```text
  /// noLink / failed ⇒ true（要用户动作：补链接 / 重试）
  /// ok             ⇒ false
  /// idle / running ⇒ false（还没结论，不能诬告）
  /// ```
  /// ⚠️ `running`/`idle` 必须 false —— 否则刚点下去就红一片，
  ///    用户会以为源坏了（"没结论"不等于"坏"）。
  bool get unusable =>
      state == TvboxProbeState.noLink || state == TvboxProbeState.failed;

  /// 按**状态**给配色用的语义（不是颜色值：配色归 UI，判据归这里）
  bool get isBad => unusable;
}

/// 把 [TvboxUpdateItem] 判成三态结论（**纯函数**）
///
/// `it == null` 表示"这个 id 没有任何检测结果" ⇒ 没有链接（查不了）。
/// ⚠️ 与 `tvboxUpdateSummary` **同源不重复**：本函数负责**分类**，
///    文案复用那边的结论串（单一事实源）。
TvboxProbeResult tvboxProbeOf(TvboxUpdateItem? it) {
  if (it == null) {
    return const TvboxProbeResult(
      state: TvboxProbeState.noLink,
      text: '查不了：这个源没有订阅链接',
      detail: '填入它当初的配置地址即可检测',
    );
  }
  if (it.multiRepo) {
    return const TvboxProbeResult(
      state: TvboxProbeState.failed,
      text: '远端现在是一份「多仓」配置，不能直接用',
      detail: '换一个子仓的地址（下面可以点）',
    );
  }
  if (!it.ok) {
    final why = (it.error ?? '').trim();
    return TvboxProbeResult(
      state: TvboxProbeState.failed,
      text: '连不上：${why.isEmpty ? '后端没有给出原因' : why}',
      // ★ 不编原因：后端没给就如实说没给
      detail: why.isEmpty ? null : why,
    );
  }
  final parts = <String>[
    if (it.added.isNotEmpty) '新增 ${it.added.length}',
    if (it.changed.isNotEmpty) '变更 ${it.changed.length}',
  ];
  return TvboxProbeResult(
    state: TvboxProbeState.ok,
    text: parts.isEmpty
        ? '能用（远端 ${it.remoteConvertible} 个可转换站点）'
        : '能用，且远端有更新：${parts.join(' · ')}',
    detail: null,
  );
}

/// 「上次更新」的一行文案（**纯函数**，源卡片与管理面板共用口径）
///
/// ```text
/// info == null            → null（整行不画 —— 非 TVBox 源 / 宿主没给）
/// 没有订阅链接（needsSource）→ 「无法定时更新：…（去补链接）」
/// 从未更新（at == 0）      → 「从未更新」
/// 成功                    → 「上次更新：MM-dd HH:mm」
/// 失败                    → 「上次更新失败 MM-dd HH:mm」（调用方红色渲染）
/// ```
///
/// # ★★ 为什么"没有订阅链接"不能显示成「从未更新」（2026-11-01 真机打回）
///
/// ```text
/// 真机那 64 条是**贴配置文本导入**的 ⇒ sidecar 里 source_url = None
/// ⇒ 定时器第一道闸就把它们全跳过 ⇒ 它们**永远**不会有章。
/// 若统一显示「从未更新」，用户读到的是"还没轮到更新"，
/// 而真相是"这条根本没有可更新的来源，也永远不会自动更新" ——
/// ⇒ 那是把"不可能"说成"还没发生"（读数说谎），
///   且用户不知道该去哪里补救（静默黑洞）。
/// ⇒ 如实报原因 + 给出路：本仓一贯口径（宁可少一个按钮，也不给假的）。
/// ```
String? tvboxLastUpdateText(TvboxSourceInfo? info) {
  if (info == null) return null;
  // ★ 没有可更新的来源 ≠ 还没更新过 —— 这两件事不许合并成一句
  if (info.needsSource) return tvboxNoSourceHint;
  if (info.lastUpdateAt <= 0) return '从未更新';
  final t = tvboxShortTime(info.lastUpdateAt);
  return info.lastUpdateOk ? '上次更新：$t' : '上次更新失败 $t';
}

/// 「没有订阅链接」时的如实文案（原因 + 出路，**单一事实源**）
///
/// 聚合源/源卡片/管理面板三处共用同一句 —— 各写一遍必然漂移。
/// ⚠️ 必须含"为什么"和"去哪儿补"，缺一半用户就卡住。
const String tvboxNoSourceHint = '无法定时更新：这条没有订阅链接（去聚合页补填）';

/// 是否处于"没有订阅链接"这一态（调用方据此不用失败红渲染 —— 它不是失败）
///
/// ```text
/// 「从没查过」和「上次查失败了」是两件事：
///   前者是配置缺失（提示去补），后者是运行故障（要报红）。
///   都染成红色，用户会以为定时更新一直在出错。
/// ```
bool tvboxLastUpdateNoSource(TvboxSourceInfo? info) =>
    info != null && info.needsSource;

/// Unix 秒 → 「MM-dd HH:mm」（跨年带年份，避免"去年"读成"今年"）
String tvboxShortTime(int secs) {
  final l = DateTime.fromMillisecondsSinceEpoch(secs * 1000).toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  final md = '${two(l.month)}-${two(l.day)}';
  final hm = '${two(l.hour)}:${two(l.minute)}';
  return l.year == DateTime.now().year ? '$md $hm' : '${l.year}-$md $hm';
}

/// 「上次更新」是否处于**失败态**（调用方据此红色渲染；纯函数）
bool tvboxLastUpdateFailed(TvboxSourceInfo? info) =>
    info != null && info.lastUpdateAt > 0 && !info.lastUpdateOk;

/// 打开「TVBox 订阅更新」弹窗
///
/// 返回 `true` 表示**本地源列表变过**（用户点了一键更新），调用方要刷新。
///
/// # 为什么用 `show` 静态方法而不是让调用方自己 `showDialog`
///
/// 与 `ProviderImportDialog.showAdd` 同一个理由：页面那边只留一行，
/// 弹窗内部的布局/状态全部收在这个文件里，别的代理改设置页时不会碰到。
class TvboxUpdateDialog extends StatefulWidget {
  const TvboxUpdateDialog({
    super.key,
    required this.id,
    required this.name,
    this.sourceUrl,
  });

  /// 源 id（后端按它查 sidecar 里的订阅链接）
  final String id;

  /// 显示用名字
  final String name;

  /// 打开时已知的订阅链接（null = 这个源没有链接）
  final String? sourceUrl;

  static Future<bool> show(
    BuildContext context, {
    required String id,
    required String name,
    String? sourceUrl,
  }) async {
    final r = await showAppDialog<bool>(
      context: context,
      builder: (_) =>
          TvboxUpdateDialog(id: id, name: name, sourceUrl: sourceUrl),
    );
    return r ?? false;
  }

  @override
  State<TvboxUpdateDialog> createState() => _TvboxUpdateDialogState();
}

class _TvboxUpdateDialogState extends State<TvboxUpdateDialog> {
  late final TextEditingController _urlCtl;

  bool _savingLink = false;
  bool _checking = false;
  bool _updating = false;

  /// 检测结果（`null` = **还没检测过** —— 与「检测了但失败」是两回事）
  TvboxUpdateCheck? _check;

  /// 一键更新的结果
  TvboxSourceUpdate? _applied;

  /// 弹窗级错误（保存链接失败 / 命令本身抛异常）
  ///
  /// ⚠️ 与「检测失败」分开：检测失败是**这次检测的结论**，
  ///    要显示在检测区域（紧挨着按钮），混在一起用户分不清
  ///    「是链接查不到还是弹窗坏了」。与 `_PluginUpdateDialogState` 一致。
  String? _error;

  /// 后端是否认这个源有订阅链接（保存成功后更新）
  late bool _hasLink;

  /// 有没有改动过本地源列表（关闭时告诉父级要不要刷新）
  bool _changed = false;

  /// 一键更新的两个开关
  ///
  /// ★ 默认值刻意选**最保守**的一侧：
  ///   ```text
  ///   applyNew      = true  → 远端新增的站也一起注册（用户点「更新」就是想要这个）
  ///   deleteMissing = false → 远端已经没有的站**只报告、不删**
  ///   ```
  ///   配置作者临时删掉一个站又加回来是常事；静默删掉用户本地的东西
  ///   是不可逆的伤害。要删必须由用户明确勾选。
  bool _applyNew = true;
  bool _deleteMissing = false;

  @override
  void initState() {
    super.initState();
    _hasLink = (widget.sourceUrl ?? '').trim().isNotEmpty;
    _urlCtl = TextEditingController(text: widget.sourceUrl ?? '');
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  /// 保存 / 清除订阅链接
  ///
  /// ⚠️ 传空字符串是**清除**链接（回到「贴文本导入」状态），不是错误。
  Future<void> _saveLink() async {
    if (_savingLink) return;
    final url = _urlCtl.text.trim();
    setState(() {
      _savingLink = true;
      _error = null;
    });
    try {
      await SourinApi.setTvboxSource(widget.id, url);
      if (!mounted) return;
      setState(() {
        _savingLink = false;
        _hasLink = url.isNotEmpty;
        _check = null;
        _applied = null;
      });
      if (url.isNotEmpty) {
        // 刚填上链接，顺手查一次 —— 用户填链接的**目的**就是想知道有没有更新
        await _checkNow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _savingLink = false;
        _error = '保存订阅链接失败：$e';
      });
    }
  }

  /// 检测更新（用户**点了才**联网）
  ///
  /// ⚠️ `keepApplied` —— 一键更新后会自动再查一次（让对比数据显示成最新的），
  ///    那次**不能**把更新结果面板清掉，否则用户刚看到的「已更新 3 个」
  ///    会在半秒后消失，像是没生效。
  Future<void> _checkNow({bool keepApplied = false}) async {
    if (_checking) return;
    setState(() {
      _checking = true;
      _error = null;
      if (!keepApplied) _applied = null;
    });
    try {
      final r = await SourinApi.checkTvboxUpdates(id: widget.id);
      if (!mounted) return;
      setState(() {
        _check = r;
        _checking = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _checking = false;
        _error = '检测更新失败：$e';
      });
    }
  }

  /// 一键应用远端的变化
  Future<void> _applyUpdate() async {
    if (_updating) return;
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final r = await SourinApi.updateTvboxSource(
        widget.id,
        applyNew: _applyNew,
        deleteMissing: _deleteMissing,
      );
      if (!mounted) return;
      setState(() {
        _applied = r;
        _updating = false;
        if (r.updated) _changed = true;
      });
      if (r.updated) {
        await _checkNow(keepApplied: true);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _updating = false;
        _error = '更新失败：$e';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final it = _check?.itemOf(widget.id);
    final busy = _savingLink || _checking || _updating;

    // ★ 2026-10-24（总计划第 18 项 · 弹窗外壳统一）：Material AlertDialog
    //   → 统一外壳 AppGlassDialog。逐项等价（先读原语义，不是机械替换）：
    //   · 返回值 `bool?` 不变（「关闭」pop(context, _changed)；静默关闭 = null
    //     ⇒ `show()` 里 `r ?? false` 一字未改）。
    //   · 宽度：原内容固定 560 宽、超 §3.5 默认 460 档 ⇒ **显式传 maxWidth: 560**
    //     （§3.5 白名单三档之一）。外壳内容区可用宽 = 560 − 48(左右各 24) = 512
    //     ⇒ 内层再写 `width: 560` 会被夹到 512（写了是误导），故只保留高度约束。
    //   · 高度：仍是「有界高度（照 _PluginUpdateDialog）：内容再多也只占 480px，
    //     内部滚动」——原样保留；外壳默认 maxHeight 620 > 480 + 标题/按钮，不夹。
    //   ⚠️ 两处能力缺口在原处补齐，**不改共享组件**（组件不在本项写入范围）：
    //     ① 机制②「外壳零 Material ⇒ TextField/ListTile 抛 No Material widget
    //        found」⇒ content 外包一层 `MaterialType.transparency`（只作墨水/光标
    //        宿主，不画底色、不裁剪，外壳视觉不变）。
    //     ② 内容区 DefaultTextStyle 写死 `textAlign: center` ⇒ 显式 merge 回
    //        左对齐（原 content 是 crossAxisAlignment.start 的左对齐表单）。
    //   ⚠️ 已知微差：原 title 是 `Row + Flexible + ellipsis`（长名字单行截断），
    //      AppGlassDialog.title 只收 String 且不设 maxLines ⇒ 超长名字改为**换行**
    //      而不是截断（不会溢出、不会抛异常，仅观感差异）。
    return AppGlassDialog(
      maxWidth: 560,
      title: '订阅更新 · ${widget.name}',
      content: Material(
        type: MaterialType.transparency,
        child: DefaultTextStyle.merge(
          textAlign: TextAlign.left,
          child: SizedBox(
            // ★ 有界高度（照 _PluginUpdateDialog）：内容再多也只占 480px，内部滚动
            height: 480,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ── 订阅链接（可编辑：贴文本导入的源在这里补链接）──
                  Text(
                    '订阅链接',
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: Sp.x1),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _urlCtl,
                          enabled: !busy,
                          decoration: const InputDecoration(
                            isDense: true,
                            hintText: 'https://example.com/tvbox.json',
                          ),
                          style: const TextStyle(fontSize: FontSizes.cap),
                          onSubmitted: (_) => _saveLink(),
                        ),
                      ),
                      const SizedBox(width: Sp.x2),
                      FilledButton.tonal(
                        onPressed: busy ? null : _saveLink,
                        child: Text(
                          _savingLink ? '保存中…' : (_hasLink ? '保存' : '填入'),
                        ),
                      ),
                      if (_hasLink) ...[
                        const SizedBox(width: Sp.x2),
                        TextButton(
                          onPressed: busy
                              ? null
                              : () {
                                  _urlCtl.text = '';
                                  _saveLink();
                                },
                          child: const Text('清除'),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: Sp.x1),
                  Text(
                    _hasLink
                        ? '这个链接下的全部源共用同一条订阅，检测一次对比全部。'
                        : '这个源是贴文本导入的，没有订阅链接 —— 查不了更新。填入当初的配置地址即可。',
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: Sp.x3),

                  // ── 检测按钮 + 结果 ──
                  Row(
                    children: [
                      FilledButton.tonalIcon(
                        onPressed: (busy || !_hasLink) ? null : () => _checkNow(),
                        icon: const Icon(AppIcons.refresh, size: 16),
                        label: Text(_checking ? '检测中…' : '检测更新'),
                      ),
                      const SizedBox(width: Sp.x3),
                      Expanded(child: _checkSummary(colors, it)),
                    ],
                  ),
                  const SizedBox(height: Sp.x2),

                  /*
                   * ★ 有变化才出现「更新」区 —— **绝不自动应用**
                   *
                   * 与 _PluginUpdateDialog 同一条：用户要的是「检测更新」，
                   * 不是「自动更新」。看到结果再决定要不要改本地。
                   */
                  if (it != null && it.ok && it.hasChanges) ...[
                    _applyBox(colors, it),
                    const SizedBox(height: Sp.x2),
                  ],

                  if (_applied != null) ...[
                    TvboxUpdateResultView(result: _applied!),
                    const SizedBox(height: Sp.x2),
                  ],

                  if (it != null &&
                      it.ok &&
                      !it.hasChanges &&
                      it.removed.isNotEmpty) ...[
                    _removedPanel(colors, it.removed),
                    const SizedBox(height: Sp.x2),
                  ],

                  if (it != null && it.multiRepo) ...[
                    _multiRepoPanel(colors, it),
                    const SizedBox(height: Sp.x2),
                  ],

                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.error,
                      ),
                    ),
                    const SizedBox(height: Sp.x2),
                  ],
                ],
              ),
            ),
          ),
        ), // ← DefaultTextStyle.merge(textAlign: TextAlign.left) 收尾
      ), // ← Material(type: MaterialType.transparency) 收尾
      actions: AppTextButton(
        onPressed: () => Navigator.pop(context, _changed),
        child: const Text('关闭'),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  局部渲染
  // ═══════════════════════════════════════════════════════════════════

  /// 检测结果的**一句话结论** —— 三种结局都不许静默
  ///
  /// ```text
  /// 还没查（null）  → 「还没检测过 —— 点「检测更新」才会联网」
  /// 查了但失败      → 红色 + 后端给的**具体原因**（绝不显示成"已是最新"）
  /// 查到了，有变化  → 「发现更新：新增 N · 变更 N」
  /// 查到了，无变化  → 「已是最新（远端 N 个可转换站点）」
  /// ```
  Widget _checkSummary(ColorScheme colors, TvboxUpdateItem? it) {
    if (_checking) {
      return Text(
        '正在检查订阅链接…',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    }
    if (it == null) {
      return Text(
        _hasLink ? '还没检测过 —— 点「检测更新」才会联网' : '没有订阅链接，查不了更新',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      );
    }
    if (it.multiRepo) {
      return Text(
        '远端现在是一份「多仓」配置',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
      );
    }
    if (!it.ok) {
      return _failLine(colors, it.error);
    }
    final text = it.hasChanges
        ? '发现更新：新增 ${it.added.length} · 变更 ${it.changed.length}'
        : '已是最新（远端 ${it.remoteConvertible} 个可转换站点）';
    return Text(
      text,
      style: TextStyle(
        fontSize: FontSizes.cap,
        color: it.hasChanges ? colors.primary : colors.onSurfaceVariant,
      ),
    );
  }

  /// 红色失败行（后端没给原因时也**如实说**没给，不编一个）
  Widget _failLine(ColorScheme colors, String? why) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(AppIcons.error_outline, size: 14, color: colors.error),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            why == null || why.trim().isEmpty ? '检测失败（后端没有给出原因）' : '检测失败：$why',
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
          ),
        ),
      ],
    );
  }

  /// 一块灰底面板（与 `SettingsEntryRow` 同一套视觉）
  Widget _box(ColorScheme colors, List<Widget> children) =>
      // ★ 与公开的结果面板（[TvboxUpdateResultView]）**共用同一份外壳样式**，
      //   两处各写一份的话，"结果区"迟早出现两种底色/圆角。
      _resultBox(colors, children);

  /// 一行开关
  ///
  /// ★ 2026-10-15（Owner：「…换成 ui 框架提供的…不手写组件」）：
  ///   改前这里的注释写着「照 `settings_kit.dart` 的 `SettingsGestureToggle`」
  ///   —— 也就是它是**照抄**出来的第二份手写 Row。
  ///   现在与 `SettingsGestureToggle` 一起换成框架的 `SwitchListTile`，
  ///   两处不再各写一份。
  Widget _toggleRow(
    ColorScheme colors, {
    required String label,
    required String hint,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      value: value,
      onChanged: _updating ? null : onChanged,
      title: Text(
        label,
        style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
      ),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          hint,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }

  /// 「更新」区 —— **有变化才出现，且绝不自动应用**
  Widget _applyBox(ColorScheme colors, TvboxUpdateItem it) {
    final gone = it.removed.length;
    return _box(colors, [
      Text(
        '远端有 ${it.added.length + it.changed.length} 处变化',
        style: TextStyle(
          fontSize: FontSizes.sm,
          fontWeight: FontWeight.w600,
          color: colors.onSurface,
        ),
      ),
      const SizedBox(height: Sp.x1),
      Text(
        '新增 ${it.added.length} 个站 · 变更 ${it.changed.length} 个接口'
        '${gone > 0 ? ' · 远端已消失 $gone 个' : ''}',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: Sp.x3),
      _toggleRow(
        colors,
        label: '同时加入新增站点',
        hint: '关掉则只更新已有源的接口，不注册新站',
        value: _applyNew,
        onChanged: (v) => setState(() => _applyNew = v),
      ),
      const SizedBox(height: Sp.x2),
      _toggleRow(
        colors,
        label: '同时删除远端已消失的站',
        hint: '默认不删 —— 配置作者临时删站又加回来是常事',
        value: _deleteMissing,
        onChanged: (v) => setState(() => _deleteMissing = v),
      ),
      const SizedBox(height: Sp.x3),
      FilledButton.icon(
        onPressed: _updating ? null : _applyUpdate,
        icon: const Icon(AppIcons.download_done, size: 16),
        label: Text(_updating ? '更新中…' : '应用更新'),
      ),
    ]);
  }

  /// 一键更新的结果（**如实报**：新增/变更/删除/失败/没应用，一个都不省）
  ///
  /// ★ 2026-10-25（第 19 项 P2 第二次）：方法体搬进**公开** widget
  ///   [TvboxUpdateResultView] —— 与导入面板同一条纪律：
  ///   私有方法让"警示到底画没画"在测试里摸不到，只能退化为源码字符串判据，
  ///   而那种判据抓不到任何跨层断链（上一轮的缺陷就是这么溜过去的）。

  /// 「远端已经没有这些站」清单（默认**只报告**）
  Widget _removedPanel(ColorScheme colors, List<TvboxLocalSite> removed) {
    return _box(colors, [
      Text(
        '远端配置里已经没有这些站（默认不删，只报告）：',
        style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
      ),
      const SizedBox(height: Sp.x1),
      for (final s in removed.take(8))
        Text(
          '· ${s.name.isEmpty ? s.id : s.name}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      if (removed.length > 8)
        Text(
          '…另有 ${removed.length - 8} 个',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      const SizedBox(height: Sp.x1),
      Text(
        '要删的话，勾上「同时删除远端已消失的站」再点更新。',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      ),
    ]);
  }

  /// 远端变成了「多仓」配置 —— 列子仓给用户挑，**不假装能一键更新**
  Widget _multiRepoPanel(ColorScheme colors, TvboxUpdateItem it) {
    return _box(colors, [
      Text(
        '远端现在是一份「多仓」配置（只有 urls，没有 sites），不能直接更新。',
        style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
      ),
      const SizedBox(height: Sp.x1),
      Text(
        '点一个子仓，地址会填到上面的输入框，再点「填入」保存。',
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: colors.onSurfaceVariant,
        ),
      ),
      const SizedBox(height: Sp.x2),
      for (final repo in it.repos.take(20))
        InkWell(
          onTap: _updating
              ? null
              : () {
                  setState(() {
                    _urlCtl.text = repo.url;
                    _error = null;
                    _check = null;
                    _applied = null;
                  });
                },
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: Sp.x1),
            child: Row(
              children: [
                Icon(
                  AppIcons.folder_outlined,
                  size: 14,
                  color: colors.onSurfaceVariant,
                ),
                const SizedBox(width: Sp.x2),
                Expanded(
                  child: Text(
                    repo.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: FontSizes.cap,
                      color: colors.onSurface,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      if (it.repos.length > 20)
        Text(
          '…另有 ${it.repos.length - 20} 个子仓未列出',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
    ]);
  }
}

/// 结果区的统一外壳（`_box` 与公开面板共用同一份样式，防两处漂移）
Widget _resultBox(ColorScheme colors, List<Widget> children) {
  return Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: Sp.x4, vertical: Sp.x3),
    decoration: BoxDecoration(
      color: colors.surfaceContainerHighest.withValues(alpha: 0.3),
      borderRadius: Radii.rLg,
      border: Border.all(color: colors.outlineVariant),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        /*
         * ★ 上次启动没能恢复的源（第19项第 4 处「不告知」的出口）
         *
         * 挂在结果盒子顶部而不是各视图里各写一遍：这个盒子是
         * 「源对话框」与「更新结果面板」**共用**的容器 ⇒ 一处插入两处生效，
         * 也不会因为将来新增第三个视图再漏一次。
         * 空清单时它渲染 `SizedBox.shrink()` ⇒ 不占位、不画（阴性对照见单测）。
         */
        const TvboxRestoreFailuresView(),
        ...children,
      ],
    ),
  );
}

/// 订阅「应用更新」的结果面板（**公开**，可被 widget test 直接渲染）
///
/// # 为什么必须是公开 widget（2026-10-25，第 19 项 P2 第二次）
/// ```text
/// 它原来是 `_TvboxSourcePanelState._appliedPanel` 私有方法 ⇒
/// "那句警示到底画没画"在测试里摸不到 ⇒ 只能退化成"源码里有这个字符串"的伪判据。
/// 而那正是这一轮缺陷（Rust 说了、Dart 没接）溜过整轮门禁的原因。
/// ⇒ 与导入面板同一条纪律：行为判据要能**真渲染**，判据对象必须公开。
/// ```
///
/// # 它会说的两件事
/// ```text
/// ① 新增/变更/删除/失败/没应用 —— 一条都不省（原有行为，逐字保留）
/// ② 新增或变更里**不落盘**的源（csp）—— 文案与导入面板**同一份常量**
///    （`tvboxUnpersistedWarningText` / `kTvboxUnpersistedHint`）
/// ```
/// ⚠️ 更新路径**没有 toast**（这个弹窗不关，结果就留在面板里），
///    所以这里没有"关窗后还看得见"的问题 —— 但用户下次启动仍会找不到这些源，
///    因此提示必须写在**面板里**且点名。
///
/// # 为什么叫 `…View` 而不是 `…Panel`（刻意的，不是笔误）
/// ```text
/// 通用守卫（test/t94_emby_entry_test.dart）要求：每个公开的
/// `*Page / *Panel / *Sheet / *Dialog` 都必须被 lib/ 里**其它文件**引用
/// （防"写完二级页却没接入口"）。
/// 本类是**订阅更新对话框内部的结果视图**，只在本文件内实例化，
/// 本来就不该有外部入口 ⇒ 叫 Panel 会被守卫判成"漏接"。
/// 不加白名单：给一条真缺陷开例外，守卫就废了。
///
/// ⚠️ 若将来它真的成为**可导航入口**，就该改叫回 `TvboxUpdateResultPanel`
///   并接到某个屏幕上 —— 那时守卫会替我们检查"到底接没接"。
/// ```
class TvboxUpdateResultView extends StatelessWidget {
  const TvboxUpdateResultView({super.key, required this.result});

  final TvboxSourceUpdate result;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final r = result;
    if (!r.updated) {
      return _resultBox(colors, [
        Text(
          r.reason ?? '远端与本地一致，没有改动',
          style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
        ),
        if (r.removed.isNotEmpty) ...[
          const SizedBox(height: Sp.x1),
          Text(
            '远端已消失 ${r.removed.length} 个站（未删除）',
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ]);
    }

    /*
     * 「本次可用、但重启后需重新导入」的源 = added + changed 里 persisted==false 的。
     * ⚠️ 只扫 added/changed：notApplied 是**没注册**的，removed/deleted 是删掉的 ——
     *    它们都不属于"现在能用、重启就没了"这一类，混进来会让提示失真。
     */
    final unpersisted = tvboxUnpersistedNames(<TvboxRemoteSite>[
      ...r.added,
      ...r.changed,
    ]);

    return _resultBox(colors, [
      Text(
        '已更新',
        style: TextStyle(
          fontSize: FontSizes.sm,
          fontWeight: FontWeight.w600,
          color: colors.primary,
        ),
      ),
      const SizedBox(height: Sp.x1),
      Text(
        '新增 ${r.added.length} · 变更 ${r.changed.length} · 删除 ${r.deleted.length}',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurface),
      ),
      // ★ 「重启后需重新导入」—— 与导入面板逐字相同的共用文案
      if (unpersisted.isNotEmpty) ...[
        const SizedBox(height: Sp.x2),
        Text(
          tvboxUnpersistedWarningText(unpersisted),
          key: const ValueKey<String>('tvbox-update-not-persisted'),
          style: TextStyle(
            fontSize: FontSizes.cap,
            height: 1.4,
            fontWeight: FontWeight.w600,
            color: colors.error,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          kTvboxUnpersistedHint,
          key: const ValueKey<String>('tvbox-update-not-persisted-hint'),
          style: TextStyle(
            fontSize: FontSizes.cap,
            height: 1.4,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
      if (r.failed.isNotEmpty) ...[
        const SizedBox(height: Sp.x1),
        Text(
          '有 ${r.failed.length} 个新站探测失败，没有注册',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
        ),
      ],
      if (r.notApplied.isNotEmpty) ...[
        const SizedBox(height: Sp.x1),
        Text(
          '按你的选择跳过了 ${r.notApplied.length} 个新增站',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
      if (r.removed.isNotEmpty) ...[
        const SizedBox(height: Sp.x1),
        Text(
          r.deleted.isEmpty
              ? '远端已消失 ${r.removed.length} 个站：只报告，没有删'
              : '远端已消失 ${r.removed.length} 个站，其中 ${r.deleted.length} 个已按你的选择删除',
          style: TextStyle(
            fontSize: FontSizes.cap,
            color: colors.onSurfaceVariant,
          ),
        ),
      ],
    ]);
  }
}

/// 「聚合源」一行管理面板（N8b-2）—— 链接可改 / 测试连通 / 立即更新
///
/// # 为什么是**独立公开组件**（而不是塞进弹窗里）
/// ```text
/// 与 `TvboxUpdateResultView` 同一条纪律（那个类的注释写得很长）：
/// 私有方法让"这三个操作到底画没画、点了真发请求没有"在测试里摸不到，
/// 只能退化成"源码里有这个字符串"的伪判据 —— 而那正是
/// 「Rust 说了、Dart 没接」那轮缺陷溜过整轮门禁的原因。
/// ⇒ 公开 + 可注入 [linkSaver] / [probeRunner] / [updater] 三个测试缝，
///   门禁直接渲染真组件、真点按钮、真断言"请求发出去了"。
/// ```
///
/// # 三个注入缝（**生产恒 null**，与全仓同一纪律）
/// ```text
/// linkSaver      set_tvbox_source(id, url)
/// probeRunner    check_tvbox_updates(id)   ← 真网络
/// updater        update_tvbox_source(id, applyNew, deleteMissing)
/// ```
class TvboxSourceManagePanel extends StatefulWidget {
  const TvboxSourceManagePanel({
    super.key,
    required this.id,
    required this.name,
    this.sourceUrl,
    this.info,
    this.linkSaver,
    this.probeRunner,
    this.updater,
  });

  /// 源 id（后端按它查 sidecar）
  final String id;

  /// 显示用名字
  final String name;

  /// 打开时已知的订阅链接（null / 空 = 没有链接）
  final String? sourceUrl;

  /// ★ T5：这个源的订阅信息（`listTvboxSources` sidecar；null = 宿主没给 ⇒ 不画更新时间行）
  final TvboxSourceInfo? info;

  /// 测试缝：保存链接（生产 null ⇒ 走 `SourinApi.setTvboxSource`）
  final Future<void> Function(String id, String url)? linkSaver;

  /// 测试缝：测试连通（生产 null ⇒ 走 `SourinApi.checkTvboxUpdates`）
  final Future<TvboxUpdateCheck> Function(String id)? probeRunner;

  /// 测试缝：立即更新（生产 null ⇒ 走 `SourinApi.updateTvboxSource`）
  final Future<TvboxSourceUpdate> Function(
    String id, {
    bool applyNew,
    bool deleteMissing,
  })? updater;

  @override
  State<TvboxSourceManagePanel> createState() =>
      _TvboxSourceManagePanelState();
}

class _TvboxSourceManagePanelState extends State<TvboxSourceManagePanel> {
  late final TextEditingController _urlCtl;

  bool _saving = false;
  bool _probing = false;
  bool _updating = false;

  /// 连通结论（null = 还没测过 —— 与"测了但失败"是两回事）
  TvboxProbeResult? _probe;

  /// 更新结果（null = 没更新过）
  TvboxSourceUpdate? _applied;

  /// 面板级错误（保存失败 / 命令抛异常）
  String? _error;

  /// 后端是否认这个源有链接（保存成功后更新）
  late bool _hasLink;

  /*
   * ⚠️ 这里**刻意没有** `_changed` 这种"告诉父级要刷新"的字段（我第一版留了一个，
   *    `flutter analyze` 报 unused_field —— 已删）。
   *
   * 理由：本面板是**内嵌**在聚合二级页里的一行（不是自带 `Navigator.pop` 的弹窗），
   *   它没有"返回值"这个出口。上面对照的 `TvboxUpdateDialog` 之所以有 `_changed`，
   *   是因为它是弹窗、`pop(context, _changed)` 把结果交回调用方（见 :566）。
   *   ⇒ 内嵌组件的刷新属**宿主页**的职责（重进该页即重新 `_load()`）；
   *     在组件里留一个没人读的 `_changed` 只会让下一个人以为"这里会通知刷新"。
   */

  @override
  void initState() {
    super.initState();
    _hasLink = (widget.sourceUrl ?? '').trim().isNotEmpty;
    _urlCtl = TextEditingController(text: widget.sourceUrl ?? '');
  }

  @override
  void dispose() {
    _urlCtl.dispose();
    super.dispose();
  }

  /// ① 链接可改 —— 保存 / 清除
  ///
  /// ⚠️ 传空串是**清除**（回到"贴文本导入"状态），不是错误。
  Future<void> _saveLink() async {
    if (_saving) return;
    final url = _urlCtl.text.trim();
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final save = widget.linkSaver ?? SourinApi.setTvboxSource;
      await save(widget.id, url);
      if (!mounted) return;
      setState(() {
        _saving = false;
        _hasLink = url.isNotEmpty;
        // 链接变了 ⇒ 旧的结论失效（否则显示的是**上一条链接**的结果）
        _probe = null;
        _applied = null;
      });
      if (url.isNotEmpty) {
        // 刚填上链接，顺手测一次 —— 用户填链接的**目的**就是想知道能不能用
        await _testNow();
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        /*
         * ★★ 收口（zz_t66_user_error_text_gate ③）：**不许把异常原文倒进用户可见字段**。
         *
         * 改前是把 catch 变量直接插进文案（模板里那句「保存链接失败：」+ 变量）
         * ⇒ 用户看到 `SourinCoreException(other): …`（宿主类名 + 内部地址）。
         * 本仓唯一入口是 `userErrorText(e, fallback:)`（`lib/core/ffi.dart:257`）：
         *   核心异常 ⇒ 只剩插件原文；非核心 ⇒ 兜底人话；原始串只进 `debugPrint`。
         * ⚠️ 与 `provider_login_panel.dart` / `proxy_panel.dart` 同批同写法。
         *
         * ⚠️⚠️ 本注释**刻意不写出那个插值字面量** —— 门禁的扫描器会把
         *    行内**引号里的内容**也当候选字面量（它只跳过 `//` 之后的，不跳块注释），
         *    所以把那个「文案 + 变量」的写法原样抄进注释会被**计入犯规条数**
         *    （我第一版就这么又红了一次）。描述行为用中文即可，别复现那个字面量。
         */
        _error = userErrorText(e, fallback: '保存订阅链接失败，请稍后重试');
      });
    }
  }

  /// ② 测试连通 —— **真发一次请求**（用户点了才联网，与全仓同一条）
  Future<void> _testNow({bool keepApplied = false}) async {
    if (_probing) return;
    setState(() {
      _probing = true;
      _error = null;
      if (!keepApplied) _applied = null;
    });
    try {
      final probe = widget.probeRunner ??
          (String id) => SourinApi.checkTvboxUpdates(id: id);
      final check = await probe(widget.id);
      if (!mounted) return;
      setState(() {
        _probe = tvboxProbeOf(check.itemOf(widget.id));
        _probing = false;
      });
    } catch (e) {
      if (!mounted) return;
      // ★ 命令本身抛异常也算"连不上"，但**原因如实说是命令失败**
      //   （不伪装成"源坏了" —— 那是把工具故障诬告给用户的源）
      /*
       * ★★ 收口（zz_t66_user_error_text_gate ③）：`detail` 也是**用户可见**字段
       *    （它会在三态结论行下渲染出来）⇒ 不许把 catch 变量直接插进去。
       *    ⇒ 人话进 `detail`（收口后），原始串留在 `debugPrint`（`userErrorText` 内部做）。
       * ⚠️ 同上一处：注释里**不复现那个插值字面量**（扫描器会把它计入犯规）。
       */
      final human = userErrorText(e, fallback: '检测命令失败，请稍后重试');
      setState(() {
        _probe = TvboxProbeResult(
          state: TvboxProbeState.failed,
          text: '连不上：检测命令失败',
          detail: human,
        );
        _probing = false;
      });
    }
  }

  /// ③ 立即更新 —— 应用远端变化
  Future<void> _applyUpdate() async {
    if (_updating) return;
    setState(() {
      _updating = true;
      _error = null;
    });
    try {
      final run = widget.updater ??
          (String id, {bool applyNew = true, bool deleteMissing = false}) =>
              SourinApi.updateTvboxSource(
                id,
                applyNew: applyNew,
                deleteMissing: deleteMissing,
              );
      final r = await run(widget.id, applyNew: true, deleteMissing: false);
      if (!mounted) return;
      setState(() {
        _applied = r;
        _updating = false;
      });
      if (r.updated) await _testNow(keepApplied: true);
    } catch (e) {
      if (!mounted) return;
      // ★ 收口（zz_t66_user_error_text_gate ③）：与上面两处同一条
      setState(() {
        _updating = false;
        _error = userErrorText(e, fallback: '更新失败，请稍后重试');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final busy = _saving || _probing || _updating;
    final probe = _probe;

    return Column(
      key: const ValueKey<String>('tvbox-manage'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        // ── ① 链接可改 ──
        Text(
          '订阅链接',
          key: const ValueKey<String>('tvbox-manage-link-label'),
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
        const SizedBox(height: Sp.x1),
        Row(
          children: <Widget>[
            Expanded(
              child: TextField(
                key: const ValueKey<String>('tvbox-manage-link-input'),
                controller: _urlCtl,
                enabled: !busy,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'https://example.com/tvbox.json',
                ),
                style: const TextStyle(fontSize: FontSizes.cap),
                onSubmitted: (_) => _saveLink(),
              ),
            ),
            const SizedBox(width: Sp.x2),
            FilledButton.tonal(
              key: const ValueKey<String>('tvbox-manage-link-save'),
              onPressed: busy ? null : _saveLink,
              child: Text(_saving ? '保存中…' : (_hasLink ? '保存' : '填入')),
            ),
            if (_hasLink) ...<Widget>[
              const SizedBox(width: Sp.x2),
              TextButton(
                key: const ValueKey<String>('tvbox-manage-link-clear'),
                onPressed: busy
                    ? null
                    : () {
                        _urlCtl.text = '';
                        _saveLink();
                      },
                child: const Text('清除'),
              ),
            ],
          ],
        ),
        const SizedBox(height: Sp.x1),
        Text(
          _hasLink
              ? '这个链接下的全部源共用同一条订阅，检测一次对比全部。'
              : '这个源是贴文本导入的，没有订阅链接 —— 查不了更新。填入当初的配置地址即可。',
          style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
        ),
        // ── ★ T5：上次更新时间（失败红色；原因进 Tooltip，一个字节不丢）──
        if (tvboxLastUpdateText(widget.info) != null) ...<Widget>[
          const SizedBox(height: Sp.x1),
          Tooltip(
            message: tvboxLastUpdateFailed(widget.info)
                ? '失败原因：${widget.info!.lastUpdateError ?? '后端没有给出原因'}'
                : (tvboxLastUpdateNoSource(widget.info)
                    /*
                     * ★ 没有链接时的**完整**解释（行内 60 字放不下，Tooltip 补）：
                     *   它是什么时候装的 / 为什么不能自动更新 / 去哪儿补。
                     *   行内那句只讲"为什么 + 去哪儿"，这里补"它从哪来"。
                     */
                    ? '这条是粘贴配置文本导入的，没有记录订阅来源 ⇒ 无法定时核对。\n'
                        '到「TVBox 聚合」页填入它当初的配置地址即可开始定时更新。'
                    : ''),
            child: Text(
              tvboxLastUpdateText(widget.info)!,
              key: const ValueKey<String>('tvbox-manage-last-update'),
              style: TextStyle(
                fontSize: FontSizes.cap,
                // ★ 三态三色：失败=红 / 缺链接=onSurfaceVariant（提示，不是故障）/ 正常
                color: tvboxLastUpdateFailed(widget.info)
                    ? colors.error
                    : colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
        const SizedBox(height: Sp.x3),

        // ── ② 测试连通 + ③ 立即更新 ──
        Row(
          children: <Widget>[
            FilledButton.tonalIcon(
              key: const ValueKey<String>('tvbox-manage-probe'),
              onPressed: (busy || !_hasLink) ? null : () => _testNow(),
              icon: const Icon(AppIcons.refresh, size: 16),
              label: Text(_probing ? '正在测试…' : '测试连通'),
            ),
            const SizedBox(width: Sp.x3),
            Expanded(child: _probeLine(colors, probe)),
          ],
        ),
        const SizedBox(height: Sp.x2),

        /*
         * 「立即更新」**只在测试连通成功且有变化时**出现 ——
         * 与 `_TvboxUpdateDialogState` 同一条：用户要的是"先看能不能用"，
         * 再决定要不要改本地。没有变化时画一个"更新"按钮是假入口。
         */
        if (probe != null && probe.state == TvboxProbeState.ok) ...<Widget>[
          FilledButton.icon(
            key: const ValueKey<String>('tvbox-manage-update'),
            onPressed: _updating ? null : _applyUpdate,
            icon: const Icon(AppIcons.download_done, size: 16),
            label: Text(_updating ? '更新中…' : '立即更新'),
          ),
          const SizedBox(height: Sp.x2),
        ],

        if (_applied != null) ...<Widget>[
          TvboxUpdateResultView(result: _applied!),
          const SizedBox(height: Sp.x2),
        ],

        if (_error != null)
          Text(
            _error!,
            key: const ValueKey<String>('tvbox-manage-error'),
            style: TextStyle(fontSize: FontSizes.cap, color: colors.error),
          ),

        // ── 名字可改：**如实说明缺口**，不画假入口 ──
        const TvboxAggregateManageNote(),
      ],
    );
  }

  /// 三态结论行（**颜色随状态**，文案来自纯函数 [tvboxProbeOf]）
  Widget _probeLine(ColorScheme colors, TvboxProbeResult? probe) {
    if (_probing) {
      return Text(
        '正在连订阅链接…',
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      );
    }
    if (probe == null) {
      return Text(
        _hasLink ? '还没测过 —— 点「测试连通」才会联网' : '没有订阅链接，测不了',
        key: const ValueKey<String>('tvbox-manage-probe-idle'),
        style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
      );
    }
    return Text(
      probe.text,
      key: const ValueKey<String>('tvbox-manage-probe-result'),
      style: TextStyle(
        fontSize: FontSizes.cap,
        color: probe.isBad ? colors.error : colors.primary,
      ),
    );
  }
}

/// 「名字可改」缺口说明（N8b-2）—— 如实说，不画假入口
///
/// # 为什么用一条**常显**的说明而不是干脆不提
/// ```text
/// Owner 明确要求「聚合源应该可以自己起名字」。
/// 本批做不了（Rust 侧无改名命令，见文件头取证）。
/// 若**什么都不说**，用户会以为自己没找到入口 —— 那是"不告知"，
/// 仓库已经为此修过 4 处（详见 `TvboxRestoreFailuresView` 的注释）。
/// 若**画一个输入框**，点了没反应 = 假 UI（更糟）。
/// ⇒ 唯一诚实的做法：说出来，并指明这是后端能力缺口。
/// ```
/// ⚠️ 一旦 Rust 侧补上改名命令，删掉本组件 + 接上真入口即可
///    （门禁 `zz_t1058` 钉了"这一条必须存在直到能力到位"）。
class TvboxAggregateManageNote extends StatelessWidget {
  const TvboxAggregateManageNote({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Text(
        '改名暂未开放：当前版本还没有给源改名的接口，名字由导入的配置决定。',
        key: const ValueKey<String>('tvbox-manage-rename-note'),
        style: TextStyle(
          fontSize: FontSizes.cap,
          height: 1.4,
          color: colors.onSurfaceVariant,
        ),
      ),
    );
  }
}

/// 「上次启动没能恢复的源」提示条 —— 有才画，没有就一行都不占
///
/// # 为什么必须有它（第19项第 4 处「不告知」）
/// csp 源重启恢复失败时，以前只有日志一句 warn 和磁盘上一个文件，
/// 界面上什么都不说 ⇒ 用户只知道「我的源没了」，不知道是**哪个、为什么**。
///
/// # 两种数据来源
/// ```text
/// failures == null  → 自己去问核心（SourinApi.restoreFailures，纯本地读）
/// failures != null  → 直接用（单测用它喂「有清单」「空清单」两种情形）
/// ```
/// ★ 读不到（无核心/命令未接）时**什么都不画**：宁可不说，也不假告警。
class TvboxRestoreFailuresView extends StatefulWidget {
  const TvboxRestoreFailuresView({super.key, this.failures});

  /// 直接给定的清单（测试注入；null ⇒ 走核心）
  final List<RestoreFailure>? failures;

  @override
  State<TvboxRestoreFailuresView> createState() =>
      _TvboxRestoreFailuresViewState();
}

class _TvboxRestoreFailuresViewState extends State<TvboxRestoreFailuresView> {
  List<RestoreFailure> _rows = const <RestoreFailure>[];

  @override
  void initState() {
    super.initState();
    final given = widget.failures;
    if (given != null) {
      _rows = given;
      return;
    }
    _load();
  }

  Future<void> _load() async {
    try {
      final rows = await SourinApi.restoreFailures();
      if (!mounted || rows.isEmpty) return;
      setState(() => _rows = rows);
    } catch (_) {
      // 读不到就说不了 —— 不许用「猜测」填出告警
    }
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ★ 阴性判据：清单为空 ⇒ **不画**（返回零尺寸）。
     *   反过来（常驻一条红字）会让用户学会无视它，警示就失效了。
     */
    if (_rows.isEmpty) return const SizedBox.shrink();

    final colors = Theme.of(context).colorScheme;
    final shown = _rows.take(5).toList(growable: false);
    return Container(
      key: const ValueKey<String>('tvbox-restore-failures'),
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: Sp.x2),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x2),
      decoration: BoxDecoration(
        color: colors.errorContainer.withValues(alpha: 0.35),
        borderRadius: Radii.rLg,
        border: Border.all(color: colors.error.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '上次启动没能恢复 ${_rows.length} 个源',
            style: TextStyle(
              fontSize: FontSizes.cap,
              height: 1.4,
              fontWeight: FontWeight.w600,
              color: colors.onErrorContainer,
            ),
          ),
          const SizedBox(height: 2),
          for (final f in shown)
            Text(
              '${f.displayName}：${f.reason}',
              key: ValueKey<String>('tvbox-restore-failure-${f.displayName}'),
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.4,
                color: colors.onSurfaceVariant,
              ),
            ),
          if (_rows.length > shown.length) ...[
            const SizedBox(height: 2),
            Text(
              '还有 ${_rows.length - shown.length} 个没列出',
              style: TextStyle(
                fontSize: FontSizes.cap,
                height: 1.4,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: Sp.x1),
          Text(
            '重新导入一次即可；如果还是不行，把上面这句原因发给我们。',
            style: TextStyle(
              fontSize: FontSizes.cap,
              height: 1.4,
              color: colors.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}
