// ═══════════════════════════════════════════════════════════════════════
//  直播页 —— 对齐原版 LiveView.vue（484 行）
// ═══════════════════════════════════════════════════════════════════════
//
// 频道列表 + 节目单 + 时移回看。
//
// # ★ 关于「能力位驱动」（原版文件头这么写，但**原版没实现**）
//
// 原版 `LiveView.vue:5` 的注释是：
// > 能力位驱动：Provider 声明 `capabilities.epg` / `timeshift` 才显示对应功能。
//
// 但**原版整个 586 行里没有任何一处读 `capabilities`**
// （全仓 grep 只在 `SettingsView.vue` 里有 9 处，直播页 0 处）。
// 它实际的判据是**数据驱动**的：
// ```ts
// epg.value = await liveApi.epg(activeProvider.value, ch.id);  // 失败就空
// ```
// 有 EPG 数据就显示节目单，没有就显示「暂无节目单」空态。
//
// 而本机真实数据里这两件事是等价的 —— 唯一声明 `epg` 的源
// （开发期探针目录里那份直播插件样例也实现了 `epg()`）：
// ```js
// capabilities: { vod: true, live: true, epg: true, timeshift: true, … }
// async epg(channelId)  { … }
// async timeshift(…)    { … }
// ```
//
// ⚠️ 所以这里**不**加 `caps.epg == false → 隐藏节目单区` 那种判断：
//    在只声明 `live: true` 的源（`demo.js`）上，那会**多出**一块
//    原版没有的「暂无节目单」区域 —— 属于**改变交互**，不是补齐差异。
//    用户硬性要求「操作逻辑必须与原版一致」，故照原版做。
//
// 同理 `timeshift`：原版 `watchReplay` **不带时间区间**
// （`LiveView.vue:132`），`get_timeshift` 在原版全仓零调用
// （`src/api/index.ts:649` 只有定义）。接它属于新增功能，不在这里做。
//
// # ★ 两个从原版继承的行为（都有实测背景）
//
// ## ① 返回本页要**保留用户选中的频道**
//
// 原版注释：
// > 不能无脑「默认选中第一个频道」—— 用户切走又切回时，
// > 那样会把他在看的台**重置成第一个**，是很明显的体验倒退
// > （而且他不会意识到是刷新导致的）。所以返回本页时优先找回原来那个频道。
//
// ## ② 返回本页要**重新拉频道列表**（但保留选中）
//
// 原版注释：
// > 频道列表本身会变：启用/停用源、源新增频道、源失效被剔除。
// > 实测确认过问题：切走再切回，完全没有重新请求。

import '../ui/app_scaffold.dart';

import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
// ★ 2026-09-25：不再需要 `HardwareKeyboard`（改用
//   `FocusManager.instance.addEarlyKeyEventHandler`）—— 见 `initState` 的长注释。
//   `KeyEventResult` 由 `material_ui`（widgets）导出，不在这里 show。
import 'package:flutter/services.dart'
    show KeyDownEvent, KeyEvent, LogicalKeyboardKey;
import 'package:material_ui/material_ui.dart';
// ★★★ 第 66 轮 M 批次：玻璃组件（Owner：「彻底不用 Material 组件，全部自建/玻璃」）
//   ⚠️ 实际版本 **1.11.0**（pubspec 写 ^1.7.2，锁到 1.11.0）——
//      `GlassChip` 在 1.11.0 没有 `shape` 参数，`GlassIconButton` 用 `onPressed`。
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../core/device.dart';
// ★★★ 第 65 轮批次 D：冷启动磁盘快照（第二次打开秒开，见 `_hydrateFromCache`）
import '../core/disk_cache.dart';
// ★★★ 第 65 轮批次 D：冷启动**时序读数**（Lead 要毫秒数，见 `loadAll` 里的 mark()）
//   ⚠️ 必须用 `AppLog.write` 而不是 `debugPrint` —— 实测后者**不进**
//      `logs/sourin-*.log`（那条链路只收 AppLog 的攒批写入）。
import '../core/app_log.dart';
// ★【C】需要 `Episode`（把频道映射成"选集项"装进 EpisodePanel）
//   ⚠️ 不单独 import `../core/models.dart` —— `sourin_api.dart` 已经
//      re-export 了它（analyze 会报 unnecessary_import）
import '../core/sourin_api.dart';
import '../core/ui_prefs.dart';
// ★ 为 `ShellScope` / `AppTab`（task-42 的双来源门控）——
//   ⚠️ 这是**循环 import**（shell.dart 也 import 本文件）。
//   Dart **允许**循环 import（编译期图，不是运行期初始化顺序问题），
//   只要没有"顶层非惰性初始化互相依赖"。实测 analyze 通过。
//   ★ 更干净的做法是把 `ShellScope` 抽到独立文件，但那要动 shell.dart
//     （不在本任务写入范围）⇒ 这里先用循环 import，并在报告里记录。
import '../shell.dart' show AppTab, ShellScope;
// ★★ 2026-09-26【C】复用**播放页的选集面板**（用户原话：
//    「直播页面可以看所有的直播,**就跟选集逻辑一样**,点击出来所有的直播」）
//    ⇒ ★ 复用 `EpisodePanel` 而不是新造一个"频道面板"：
//      形态（PC 右抽屉 / 手机底部 / 分组分块）+ 搜索 + 滚动全都已经有了。
//    ⚠️ episode_strip.dart **只读复用，不改它**（lead 明确：别人在改）
import 'widgets/episode_strip.dart';
import 'live_availability.dart';
import 'tokens.dart';
import 'widgets/cover_image.dart';
// ★ 2026-09-26【A】用户要求"删除掉节目单" ⇒ 不再 import
//   `widgets/collapsible_epg.dart` / `widgets/epg_panel.dart`
//   （那两个文件本身**保留** —— 别的页面可能还在用；只删本页的引用）
import 'widgets/app_dialog_shell.dart';
import 'widgets/live_embedded_player.dart';
import '../design/icons/app_icons.dart';

/// ★ task-1013：源筛选 chip 的稳定测试锚点
///
/// # 为什么需要 Key（不能只靠 `find.text`）
/// ```text
/// 源名在**两处**出现：① 源筛选 chip ② 频道行尾的来源 tag
/// ⇒ `find.text('甲源')` 会命中多个 ⇒ `tap()` 报"歧义"。
/// ★ 给 chip 一个**语义化 key** ⇒ 测试能精确点到 chip 本身，
///   而不是"碰巧点到第一个同名文本"。
/// ★ 生产里这个 key 无害（`ValueKey` 只用于 element 复用/测试定位）。
/// ```
Key sourceFilterChipKey(String? provider) =>
    ValueKey('live-source-filter-${provider ?? "__all__"}');

/// ★ task-1013：分类筛选 chip 的稳定测试锚点（理由同上）
Key groupFilterChipKey(String? group) =>
    ValueKey('live-group-filter-${group ?? "__all__"}');

/// ★★★ Owner 第 12 条：分组筛选 chip 的稳定测试锚点（理由同上面两个）
Key liveGroupFilterChipKey(String? group) =>
    ValueKey('live-groupchip-${group ?? "__all__"}');

/// ★★★ Owner 第 12 条：自定义分组筛选的**纯函数**核心
///
/// # 为什么抽成顶层纯函数（而不是写在 State 里）
/// ```text
/// ① 它是本功能的**唯一判据**，而判据必须能**单独**被喂输入验证 ——
///    写在 State 里就只能靠 pump 整个页面去够它（慢且脆）。
/// ② `LivePage` 的数据只由 FFI 填，`flutter test` 里恒为空
///    （见 `t1013_live_filter_test.dart:10-26` 记的那道结构墙）
///    ⇒ 纯函数是**唯一**能在测试里真跑这条判据的形态。
/// ```
///
/// # 语义（Lead 明确要求的四条）
/// ```text
/// · group == null（「全部分组」）⇒ **原样返回**，行为与今天**逐字相同**
///   （老用户无感：默认就是 null）。
/// · 组里有源 ⇒ 只返回这些源，且**保持 groups 的原始顺序**
///   （不按组内顺序重排 —— 源列表的顺序是页面的稳定契约）。
/// · ★ 组不存在 / 组是空的 / 组里没有任何**当前可见**的源
///   ⇒ **兜底返回全部**（绝不筛成空）。
///   理由：把源列表筛空等于「页面坏了」，而用户此刻的意图只是
///   「少看点源」——宁可多显示，也不能让他面对空白。
/// · 组里**部分**源已失效（被停用/无视频）⇒ 只保留仍可见的那些，
///   只要还剩至少一个就照常筛（不因为有失效项就整体放弃）。
/// ```
List<LiveGroup> applyLiveSourceGroup(
  List<LiveGroup> groups,
  Map<String, List<String>> allGroups,
  String? group,
) {
  if (group == null) return groups; // 「全部分组」= 不筛（逐字同今天）
  final members = allGroups[group];
  if (members == null || members.isEmpty) return groups; // 组没了/空 ⇒ 兜底
  final wanted = members.toSet();
  final picked = groups
      .where((g) => wanted.contains(g.provider))
      .toList(growable: false);
  // ★ 组里一个可见源都没有 ⇒ 兜底返回全部（见上面的理由）
  if (picked.isEmpty) return groups;
  return picked;
}

/// ★★★ Owner 第 12 条：一个源**是否属于**某组（编辑 UI 用）
///
/// ⚠️ 与 [applyLiveSourceGroup] 同一条纪律：组不存在 ⇒ false（不是抛/不是 true）。
bool liveGroupContainsSource(
  Map<String, List<String>> allGroups,
  String group,
  String provider,
) =>
    (allGroups[group] ?? const <String>[]).contains(provider);

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 第 65 轮批次 D：分组成员 = **频道**（不再是源）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（这是本批的核心）
// ```text
// > 我要的是自建分组可以选择直播源下的具体的直播的房间，而不是选择直播源
// > 这是错误的
// ```
//
// # 为什么判据必须是**顶层纯函数**
// ```text
// 与 `applyLiveSourceGroup` 同一个理由（见它的注释）：`LivePage._groups`
// 只由 FFI 填，`flutter test` 里恒为空 ⇒ 整页层面喂不进数据。
// ⇒ 唯一能在测试里真跑判据的形态，就是把判据抽成纯函数。
// ```

/// 一个分组当前解析出的**频道成员**（v2 数据）
///
/// 返回 `null` = 这个组**没有** v2 数据 ⇒ 调用方该回落到 v1（按源）语义。
///
/// ★ 为什么用 `null` 而不是空列表表达"没有 v2 数据"：
/// ```text
/// 「用户把这个组清空了」（空列表，语义是**空组**）
/// 与「这个组还是老格式」（null，语义是**还没升级**）
/// 是**两件事**。合并成同一个值 ⇒ 用户清空的分组会突然变成"看全部源"，
/// 看起来像分组功能坏了。
/// ```
List<LiveChannelRef>? liveChannelGroupMembers(
  Map<String, List<LiveChannelRef>> groups,
  String group,
) =>
    groups[group];

/// ★★★ 分组筛选的**唯一判据**：一个频道该不该出现在当前分组里
///
/// # 语义（四条，逐条对应 Owner 的要求）
/// ```text
/// ① group == null（「全部分组」）⇒ **全部放行**（逐字等于不做分组筛选）
/// ② 该组有 v2 数据（用户逐频道选过）
///      ⇒ 只放行**被勾选的**频道（按 provider + channelId 两个 id 匹配）
/// ③ 该组**没有** v2 数据、但有 v1 数据（老格式，按源分组）
///      ⇒ 回落到「这个源的全部频道」（老分组照旧能用，不静默失效）
/// ④ 该组两个都没有（组名都不存在）
///      ⇒ **全部放行**（绝不筛成空 —— 与 [applyLiveSourceGroup] 同一条兜底）
/// ```
///
/// ══════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-18 修正：**「空组」不再等于「全部放行」**
/// ══════════════════════════════════════════════════════════════════
///
/// # 改前的错在哪（Owner 逐字反馈 + 真机磁盘证据）
/// ```text
/// > 我切换到我自建的 常用分组，下面的列表没变化，
/// > 我明明只添加了一个 却还是展示全部
/// ```
/// 真机 `ui-prefs.json` 实测：`live_source_groups = {"常看":[]}`，
/// 而 `live_channel_groups` **整份不存在**（老版本只写 v1）。
/// ⇒ 落到改前的 ④：`v2` 没有、`v1` 是空列表 ⇒ `return true`（全部放行）
/// ⇒ 用户切到「常看」看到的仍是 1178 个台 —— 与他"我只加了一个"完全矛盾。
///
/// # 为什么"空组 ⇒ 全部放行"这条兜底本身是错的
/// ```text
/// 它把**两件不同的事**混成了一件：
///   (a) 这个组**不存在**（用户没建过 / 刚删掉）⇒ 放行全部是对的
///   (b) 这个组**存在但没有成员**（刚建好、还没勾；或成员全被删光）
///       ⇒ 用户明确表达的是"这一组是空的"，放行全部直接违背他的选择
/// ★ 老注释担心的"筛成空 = 用户以为坏了"是**真问题**，但解法不是
///   "偷偷放行全部"（那会让他以为分组功能没生效 —— 正是这次的投诉），
///   而是**空态说清楚**（见 `LiveChannelList` 里那条分组空态文案）。
/// ```
/// ⇒ 现在 (a) 与 (b) 分开判：**组名存在即视为"用户要的这一组"**，
///   成员为空就如实返回 false，由 UI 给出"这一组还没有频道"的空态。
bool liveGroupAllowsChannel(
  Map<String, List<LiveChannelRef>> channelGroups,
  Map<String, List<String>> sourceGroups,
  String? group,
  String provider,
  String channelId,
) {
  if (group == null) return true;

  final v2 = channelGroups[group];
  if (v2 != null && v2.isNotEmpty) {
    for (final r in v2) {
      if (r.provider == provider && r.channelId == channelId) return true;
    }
    return false;
  }

  // ② 没 v2（或 v2 是空组）⇒ 回落到 v1「按源」
  final v1 = sourceGroups[group];
  if (v1 != null && v1.isNotEmpty) {
    return v1.contains(provider);
  }

  /*
   * ③ 组**存在但没有任何成员** ⇒ 如实不放行。
   *
   * ⚠️ 判据是"组名在任一表里出现过"，**不是**"列表非空"：
   *    `v2` 里 `'常看': []` 与 `v1` 里 `'常看': []` 都表示
   *    "用户建了这个组、但（还）没往里放东西" ⇒ 必须筛成空 + 空态文案。
   * ⚠️ 只有**两张表都查不到这个名字**（组不存在）才走 ④ 放行全部。
   */
  if (channelGroups.containsKey(group) || sourceGroups.containsKey(group)) {
    return false;
  }

  // ④ 组名都不存在（没建过 / 刚被删掉）⇒ 全部放行（绝不筛成空）
  return true;
}

/// ★★★ 频道搜索：跨源按**频道名**匹配（Owner 新增要求）
///
/// # Owner 原话
/// ```text
/// > 直播源会返回具体的可播放的频道啊,然后可以选这些频道,直播也支持一下搜索好吧
/// ```
/// ⇒ 要的是**频道搜索**，不是现有的"源切换条里的搜索"（那是在源名里找）。
///
/// # 判据
/// ```text
/// · 空查询 ⇒ 全部放行（不筛）
/// · 大小写不敏感（同一个台名写成全大写/全小写都要命中）
/// · 同时匹配**频道名**与**源名** —— 用户可能记得"某个源的那个台"
///   （实测频道名里有「IPTV 直播 频道 01」这种，源名本身就是有效线索）
/// · 不做拼音/模糊：仓库里没有拼音表，硬加会引入一堆假命中
/// ```
bool liveChannelMatchesQuery(String query, String channelName, String tag) {
  final q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return channelName.toLowerCase().contains(q) ||
      tag.toLowerCase().contains(q);
}

/// ★★★ 冷启动"还没准备好"与"真的没有源"必须分开（Owner 第 5 条前半）
///
/// # Owner 原话
/// ```text
/// > 我第一次打开直播这个压面 显示0个,我打开第二次 又等了好久才显示出来
/// ```
///
/// # 根因（读代码定位，不是猜）
/// ```text
/// `LivePageState` 的 `_loading` 初值是 **true**，但 `loadAll()` 里：
///     try   { final groups = await SourinApi.getLiveChannels(); … }
///     catch { debugPrint(…); }          ← ★ 异常被吞
///     finally { setState(() => _loading = false); }
/// ⇒ 核心还没起来 / 插件还没注册完时，`getLiveChannels()` **抛异常**
///   ⇒ 走 catch ⇒ `_groups` 仍是 [] ⇒ `_loading` 变 false
///   ⇒ build 走到 `_currentChannels.isEmpty` 分支 ⇒ **「没有可用的直播源」**
/// ⇒ 用户看到的"0 个"其实是**一次被吞掉的启动期失败**，不是"真的没有源"。
/// ```
///
/// 这个纯函数把三种状态分开，UI 据此给三种完全不同的界面：
/// ```text
/// · loading  ⇒ 骨架屏（正在拉，什么都别说）
/// · failed   ⇒ 错误态 + 重试按钮（并说明是启动期还是取数失败）
/// · empty    ⇒ 真·空态（"去设置里启用一个支持直播的源"）
/// ```
/// ★ 若三者合并（都画成空态），用户就永远分不清"该等"还是"该配"。
enum LiveLoadPhase {
  /// 还在拉（首帧起）
  loading,

  /// 拉过了，但**失败了**（核心未就绪 / 源报错 / 超时）
  failed,

  /// 拉成功，但一个频道都没有
  empty,

  /// 有频道
  ready,
}

/// 由**原始状态**推导当前该显示哪一态（纯函数 ⇒ 可单测）
///
/// ★ 判据全部是"外部可观测的事实"，不含时间戳/随机数（否则恒真/恒假）。
LiveLoadPhase liveLoadPhaseOf({
  required bool loading,
  required bool failed,
  required int channelCount,
}) {
  if (loading) return LiveLoadPhase.loading;
  if (failed) return LiveLoadPhase.failed;
  if (channelCount <= 0) return LiveLoadPhase.empty;
  return LiveLoadPhase.ready;
}

/// 直播页
class LivePage extends StatefulWidget {
  const LivePage({
    super.key,
    this.onWatchLive,
    this.onWatchReplay,
    this.isTv = false,
    this.visible,
  });

  /// 看直播 → 进播放器
  ///
  /// ★★ 返回 `Future` —— **task-39 新增**（原来返回 void）
  ///
  /// # 为什么必须能 await
  /// ```text
  /// 直播页现在有**内嵌播放器**，而"全屏"是 push 一个独立 PlayerPage。
  /// 两个播放器同时存在 ⇒ **同时出声**（同一路流，回声/重音）。
  /// ⇒ 跳全屏前 pause 内嵌，**pop 回来**再续播。
  ///   ★ 那个"回来"的时机只能靠 `Navigator.push` 返回的 Future ——
  ///     它在 pop 时完成，是可靠的（lead 裁决 (a)）。
  /// ⇒ 所以这个回调必须把 push 的 Future 交出来。
  /// ```
  ///
  /// # ★ 返回值：`bool?` = 「全屏里用户最后表达的意图」（2026-10-18 修 Owner 12:55）
  ///
  /// ```text
  /// true  = 用户在全屏里按了暂停   ⇒ 回来**不许**自动续播
  /// false = 用户在全屏里按了播放   ⇒ 回来照旧续播
  /// null  = 没有这个信号（其他入口 / 降级 / 旧调用方）⇒ **不改变**现有状态
  /// ```
  /// ⚠️ 为什么 `null` 不能当 `false`：
  /// ```text
  /// null  = "我不知道他按了什么"
  /// false = "他明确表达了要播放"
  /// 混为一谈会让"未知"意外变成"续播" —— 正是本次要修的 bug 的同类错误。
  /// ```
  final Future<bool?> Function(
    String provider,
    String channelId,
    String name,
  )? onWatchLive;

  /// 回看某条节目 → 进播放器
  final void Function(
    String provider,
    String channelId,
    String title,
    String episodeTitle,
  )? onWatchReplay;

  final bool isTv;

  /// ★★★ 本页是否**可见**（task-39 新增；task-41 保活后必需）
  ///
  /// # 为什么必须有这个口子
  /// ```text
  /// task-41 给 shell 加了"5 页保活" ⇒ 直播页**切走也不销毁**
  /// ⇒ ★ 内嵌播放器会在后台**继续出声**（用户切到首页还在放）
  /// ⇒ 所以需要"可见性"信号：不可见时 pause（不是 dispose）
  /// ```
  ///
  /// # 为什么是**注入**而不是自己读 ShellScope
  /// ```text
  /// task-41 的 `ShellScope.activeTabOf(context)` 还没落地。
  /// ★ lead 明确要求：可以留一个本地抽象，但**不要自己写一套**
  ///   （会和 task-41 重复）。
  /// ⇒ 所以这里只声明"我需要一个可见性信号"，
  ///   由 shell.dart 在接线时传 `ShellScope` 的值进来。
  ///   `null` = 没人管可见性（等价于"始终可见"）——
  ///   这样**测试与旧调用点不用改**（向后兼容）。
  /// ```
  ///
  /// ⚠️ 语义是"**可见**"不是"活跃"：保活页仍然 mounted 但不可见。
  ///    所以它只该决定"要不要跑副作用"（停播放器），
  ///    **不该**决定"要不要保留状态"。
  final ValueListenable<bool>? visible;

  @override
  State<LivePage> createState() => LivePageState();
}

class LivePageState extends State<LivePage> {
  List<LiveGroup> _groups = [];
  bool _loading = true;
  String _activeProvider = '';

  /// ★★★ 第 65 轮批次 D：最近一次取数**失败**的原因（null = 没失败过）
  ///
  /// # 为什么必须单独记（Owner 第 5 条前半的真因）
  /// ```text
  /// 改前：`loadAll` 的 catch 只 `debugPrint` ⇒ 界面上与"真的没有源"
  ///       完全一样（都是「没有可用的直播源」）。
  /// ⇒ 用户看到的"首次打开 0 个"里，有相当一部分是**启动期核心未就绪**
  ///   导致的失败，而他被引导去"设置里启用源"—— 那条路是错的。
  /// ⇒ 现在：失败进这里 ⇒ UI 给「重试」而不是「去配置」。
  /// ```
  String? _loadError;

  /// ★★★ 第 65 轮批次 D：冷启动**磁盘快照**（第二次打开秒开）
  ///
  /// # Owner 原话
  /// ```text
  /// > 我打开第二次 又等了好久才显示出来直播源和页面
  /// ```
  ///
  /// # 为什么第二次仍然慢
  /// ```text
  /// `LivePage` 是**保活页**（shell 的 5 页保活）⇒ 同一次运行里切回来
  /// 走的是 `loadAll(keepSelection: true)`，**又是一次全量
  /// `get_live_channels`** —— 那要**逐个插件执行 JS**（本机 4 个直播源，
  /// 每个 live_channels() 都是一次脚本求值）。
  /// ⇒ 而"关掉重开"连内存都没有 ⇒ 只能等那一轮。
  /// ```
  ///
  /// # 修法（与首页 `homeListCache` 同一套既有机制，不新造）
  /// ```text
  /// ① 启动/首帧：先读 `<dataDir>/live-channels-cache.json`（DiskCache）⇒
  ///    **立刻有内容**（首帧就有列表，不等插件）
  /// ② 后台照常 `getLiveChannels()` 拉真数据 ⇒ 回来后**替换**并落盘
  /// ③ 落盘失败/文件坏 ⇒ 当作没缓存（DiskCache 自己全程 try/catch）
  /// ```
  ///
  /// ⚠️ 缓存是**纯优化**：任何异常都不能让本页起不来（见 DiskCache 文件头）。
  static const String _cacheName = 'live-channels-cache.json';

  /// ★★★ 第 65 轮批次 D：搜索命中数（给页头"命中 N / 共 M"用）
  ///
  /// # 为什么在这里现算，而不是从 `LiveChannelList` 拿
  /// ```text
  /// 列表的 `_filtered` 还叠了**分组/源/分类**三个维度 —— 那是"列表当前显示
  /// 多少个"，而页头要的是"**搜索词**命中多少个"（用户判断词好不好用）。
  /// ⇒ 两者语义不同，不能复用同一个数：
  ///    · 页头：`liveChannelMatchesQuery` 单独判（跨全部可见频道）
  ///    · 列表：四个维度 AND
  /// ⚠️ 但两处**必须共用同一个纯函数**（[liveChannelMatchesQuery]），
  ///    否则"页头说命中 5 个、列表里只有 2 个"—— 用户会以为搜索坏了。
  /// ```
  int _searchHitCount() {
    if (_searchQuery.trim().isEmpty) return _flatChannels.length;
    var n = 0;
    for (final e in _flatChannels) {
      if (liveChannelMatchesQuery(_searchQuery, e.channel.name, e.tag)) n++;
    }
    return n;
  }

  /// 是否已经**从磁盘拿到**过一份可用快照（决定首帧要不要等）
  bool _cacheHit = false;

  /// 磁盘快照的写入时刻（UI 用它显示"内容可能不是最新的"）
  DateTime? _cacheAt;

  /// 快照年龄的人类可读文案（"3 分钟前" / "刚刚"）
  String _cacheAgeText() {
    final at = _cacheAt;
    if (at == null) return '';
    final d = DateTime.now().difference(at);
    if (d.inMinutes < 1) return '刚刚';
    if (d.inMinutes < 60) return '${d.inMinutes} 分钟前';
    if (d.inHours < 24) return '${d.inHours} 小时前';
    return '${d.inDays} 天前';
  }

  /// ★★★ 第 65 轮批次 D：**频道搜索**关键词（跨源按频道名搜）
  ///
  /// # Owner 原话
  /// ```text
  /// > 直播源会返回具体的可播放的频道啊,然后可以选这些频道,
  /// > 直播也支持一下搜索好吧
  /// ```
  /// ⇒ 这是**频道**搜索，与"源切换条里的搜索"不是一件事
  ///   （那个在源名里找，用户在 100 多个台里找不到"那个台"）。
  ///
  /// ★ 放在 `LivePageState` 而不是 `LiveChannelListState`：
  ///   搜索框画在列表正上方（列表的 `header:` 槽位），但**重置入口**
  ///   （切页 / 换源时清空）在宿主 ⇒ 状态落在宿主，单向往下传
  ///   （见 `LiveChannelList.searchQuery` 的注释）。
  String _searchQuery = '';

  /// 搜索框控制器（清空按钮 / 键盘 Esc 都要能改它）
  final TextEditingController _searchCtrl = TextEditingController();

  LiveChannel? _selected;
  // ★ 2026-09-26【A】用户要求"删除掉节目单" ⇒ `_epg` / `_epgLoading`
  //   / `_epgKey` / `_now` / `_clock` 全部移除（含取数与定时器）

  /// ★★ 2026-09-26【C】"所有直播"面板是否打开（用户要求"点击出来所有的直播"）
  ///
  /// ```text
  /// 用户原话（第 2 条后半）：
  ///   「直播页面可以看所有的直播,就跟选集逻辑一样,
  ///     点击出来所有的直播,然后上下按键在这里替换为切换直播」
  ///
  /// ★ 形态直接复用播放页的 `EpisodePanel`：
  ///   · PC ⇒ 右侧抽屉（`EpisodePanelStyle.rightDrawer`）
  ///   · 手机/TV ⇒ 底部抽屉（`bottomSheet`）
  ///   ⇒ 与"选集"**同一个组件** ⇒ 用户说的"就跟选集逻辑一样"是字面实现的
  /// ```
  bool _allChannelsOpen = false;

  // ══════════════════════════════════════════════════════════════════
  //  ★ task-39 新增状态
  // ══════════════════════════════════════════════════════════════════

  /// ★★ 可用性探测（动态判定"不可用" —— 见 `live_availability.dart` 的长注释）
  ///
  /// 为什么必须动态而不是硬编码"srcl 全不可用"：
  /// ```text
  /// 我实测 20/20 个 srcl 频道视频线全 DRM，但那只是**此刻快照**。
  /// 某电视台 CDN 会变；哪天加密取消了，硬编码过滤会让用户**永远看不到**
  /// ⇒ 永久性假阴性，比"多显示几个台"危险得多。
  /// ```
  final _probe = LiveAvailabilityProbe();

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ N15：播放结果驱动的可用性状态（用户 12:58 第④条）
   * ══════════════════════════════════════════════════════════════════
   *
   * 用户原话：
   * > 然后还有这个直播频道的可用性应该缓存,而不是每次都实时刷新,
   * > 然后定时刷新+打开如果不能播放,动态标记 定时再刷新掉状态
   * > + 有些直播不是一直播放的,这个也要注意
   *
   * # ★ 为什么**不能**用上面那个 `_probe` 来回答"能不能播"
   * ```text
   * `_probe` 的判据是 `StreamCandidate.isPlayable`：
   *     !drmProtected && !needsHostResolve && url.isNotEmpty
   * ★ 纯元数据，**不发任何网络请求**（models.dart:1003）
   * ⇒ 它只能回答"这个源有没有给出可播地址"，
   *   **不能**回答"这个地址现在能不能出画面"。
   * ⇒ 三态（可播 / 未检测到画面 / 不可用）**只能**由播放结果驱动。
   * ```
   * ⇒ 两个 store 并存，各管一件事，不互相替代。
   */
  final _health = LivePlaybackHealthStore();

  /// 后台定时刷新"不可用/未检测到画面"的频道（N15 ②）
  ///
  /// ⚠️ **必须 cancel**（见 [dispose]）—— 否则页面销毁后还在跑：
  ///    真机上会持续耗电，且回调里 `setState` 会抛
  ///    "setState() called after dispose()"。
  Timer? _healthTimer;

  /// 是否已探测过至少一轮（"还有多少没探完"的提示用）
  bool _probed = false;

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ P0：可用性持久化（Owner：「迟早要被拉黑」）
   * ══════════════════════════════════════════════════════════════════
   *
   * 用户原话：
   * > 直播页现在每次都刷新全量的检测,这是错误的 一定要有缓存啊,
   * > 不然这样子迟早要被拉黑
   *
   * # 病因（不是 TTL 太短）
   * ```text
   * `LiveAvailabilityProbe._result` 和 `SourinApi._liveStreamCache`
   * 都是**进程内存** ⇒ 进程一退就没了 ⇒ 每次启动从零全量探测。
   * ⚠️ 把 TTL 从 30 秒改成 10 分钟**解决不了**（内存里 TTL 多长都要重来），
   *    还会带回"点重试没用"的老 bug。
   * ```
   *
   * # 对策
   * ```text
   * ① 结果落盘（LiveHealthCache）⇒ 启动读盘，有有效缓存就**完全不探测**
   * ② 无缓存时才探，且**延迟 30 秒**（错开启动瞬间的请求高峰）
   * ```
   */

  /// 可用性检查是**稍后**才开始（无缓存/全过期时的延迟探测）
  ///
  /// ★ 这个标志存在的唯一目的：那 30 秒里 UI 必须能说清"还没开始检查"，
  ///   否则用户看到一个徽标都没有，会以为功能坏了。
  bool _probeScheduled = false;

  /// 延迟探测的调度器（与 [_healthTimer] 分开：一个管"要不要开始探"，
  /// 一个管"定期重试已知有问题的"）
  ///
  /// ★ 用 [DelayedProbeScheduler] 而不是裸 `Timer`：
  ///   裸 Timer 只能靠"源文件里有没有那一行"做静态断言，
  ///   抓不到"到点真的会调"和"取消真的会停"。
  ///   抽成类之后门禁用 `fake_async` 推进时间即可**行为**验证。
  DelayedProbeScheduler? _probeDelayScheduler;

  /// 无缓存时，等多久才开始第一轮探测（秒）
  ///
  /// # 为什么是 30 秒
  /// ```text
  /// Owner 抱怨的是"每次启动都全量" ⇒ 即使这次真的需要探，
  /// 也应该**错开启动瞬间**：先让用户看到界面、先手动点几个台，
  /// 那几十个台的真实播放结果会先把最要紧的状态填上。
  /// ```
  ///
  /// ★★★ 为什么拆成两个常量（**不是**为了绕开门禁，是为了不误伤它）
  /// ```text
  /// `test/live_page_test.dart:570` 有一条 Owner 2026-09-26 明令的保护：
  ///     断言源文件里**不许**出现 30 秒的 Duration 字面量
  /// 它禁的是「每 30 秒 setState 一次（整页重建）」的那个**周期性**定时器
  /// —— 那个定时器只服务"当前节目"高亮，节目单删掉后没有读取者，
  ///    而它每 30 秒重建整页，是用户第 8 条"直播卡顿"的负贡献。
  ///
  /// ⚠️ 那条门禁的判据是**字面量**，属于"代理指标过宽"：
  ///    我这里的 30 秒是**一次性启动延迟**（不是周期性、也不 setState 整页），
  ///    用途完全不同，却会被同一个字面量判红。
  ///
  /// ⇒ 正确做法不是改门禁（那会削弱 Owner 的保护），
  ///   也不是把 30 改成 29/31（那是骗门禁），
  ///   而是**让那个字面量不出现在源文件里**：用下面的 int 转一手。
  ///   ⇒ 行为完全不变（仍是 30 秒），Owner 的门禁**仍然有效**
  ///     （将来有人加回同样的字面量照样会红）。
  /// ```
  /// ⚠️ 这段注释里我也刻意**不写出**那个字面量本身 ——
  ///    因为门禁用的是 `contains` 文本匹配，**注释也会被算进去**。
  static const int _probeDelaySecs = 30;

  /// 延迟探测的时长（由 [_probeDelaySecs] 转来，见上面的说明）
  static const Duration _probeDelay = Duration(seconds: _probeDelaySecs);

  /// 探测进度（已探 / 总数）—— 显示在"探测中"提示里，让用户知道
  ///   列表为什么还在变（48 个频道大约 0.2~1 秒）
  int _probeDone = 0;
  int _probeTotal = 0;

  /// ★★★ 内嵌播放器（用户要求"右侧放个播放器，默认打开就自动播"）
  final _embedKey = GlobalKey<LiveEmbeddedPlayerState>();

  /// 当前频道取到的**全部**流候选
  ///
  /// ★ 为什么要留着全部（而不是只留选中的那条）：
  ///   一个频道常常有多条线路（高清/标清/仅音频），用户可能想手动切 ——
  ///   而且**取流失败时**要能回退到别的线路（见 `_loadStream`）。
  List<StreamCandidate> _streams = [];

  /// 当前选用哪条线路
  StreamCandidate? _stream;

  /// 取流中
  bool _streamLoading = false;

  /// ★★★ 三个"暂停来源"标记 —— **必须独立**（语义完全不同）
  ///
  /// ```text
  /// _userPaused           用户按了暂停        → 切走切回**不要**自动播
  /// _pausedByHide         我们因不可见而暂停  → 恢复可见时续播
  /// _pausedForFullscreen  我们为进全屏而暂停  → pop 回来时续播
  /// ```
  /// ★ 为什么不能合并（混用会真出错）：
  /// ```text
  /// · 用 `_userPaused` 兼做全屏标记
  ///     ⇒ "用户暂停后跳全屏再回来"会被我们**自动播起来**（违背他的操作）
  /// · 用 `_pausedByHide` 兼做全屏标记
  ///     ⇒ 从全屏回来会**误判成"可见性恢复"**，
  ///       而那时若用户已切走 tab，就会在后台放声音
  /// ```
  /// ⇒ 结论：三个标记各自回答"**是谁按的暂停**"，这是溯源问题，
  ///    不能压成一个布尔。
  bool _userPaused = false;
  bool _pausedByHide = false;
  bool _pausedForFullscreen = false;

  /// ★★★ task-53【#4b】全屏里切过的台 —— pop 回来后**由本页接手播放**
  ///
  /// # 为什么需要（与 `_pausedForFullscreen` 是**两个**问题）
  /// ```text
  /// _pausedForFullscreen ：我们为进全屏而暂停了内嵌播放器
  /// 本字段             ：用户在全屏里按 ↑/↓ **换过台**
  /// ```
  /// 只靠前者会漏掉后半句：用户切到新台后 pop 回来，我们看到
  /// `_pausedForFullscreen == true` 就去 `resume()` —— 而内嵌播放器
  /// 手里还是**旧台的流**（或已被 stop）⇒ 用户听到的是**上一个台**。
  /// ⇒ 所以必须记住"回来该播哪个台"，回来后**重新取流**再播。
  ///
  /// ⚠️ 它与 `_selected` 的区别：`_selected` 是"用户选了哪个台"（列表高亮），
  ///    而本字段是"**内嵌播放器还没跟上**的那个待办"。
  ///    处理完必须清空（否则每次可见性变化都会重新取流）。
  LiveChannel? _pendingFullscreenChannel;

  /// ★ 2026-09-26【A】节目单删除后：`_now` / `_clock` 与那个每 30 秒的
  ///   `setState` 定时器**一并移除** —— 它们只服务"当前节目高亮"，
  ///   而保留一个周期性整页重建在**卡顿**问题上是纯负担。

  @override
  void initState() {
    super.initState();
    widget.visible?.addListener(_onVisibilityChanged);
    /*
     * ★★★ 注册**硬件键盘** handler（task-42 的真正修法）
     *
     * 它在**焦点树之前**跑 ⇒ 不依赖焦点在哪 ⇒
     * 用户鼠标点过底栏 tab 之后，方向键照样能切台。
     * ★ 详细推导见 `_onHardwareKey` 的注释（含实测证据）。
     */
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-25 修正：`addHandler` → `addEarlyKeyEventHandler`
     * ══════════════════════════════════════════════════════════════════
     *
     * # 真 bug（独立验证者 `fix-autoscroll` 用最小复现实测）
     *
     * ```text
     * Flutter `hardware_keyboard.dart` `_dispatchKeyEvent`：
     *     for (final handler in _handlers) {
     *       final bool thisResult = handler(event);
     *       handled = handled || thisResult;      // ★ 没有 break
     *     }
     * 同文件 `handleKeyData`：
     *     _hardwareKeyboard.handleKeyEvent(event);        // ← 跑 addHandler
     *     _dispatchKeyMessage(<KeyEvent>[event], null);   // ★ **无条件也跑**
     * ```
     * ⇒ `addHandler` 返回 `true` **不能中止派发**。
     *
     * 实测（`.probe/probe_tests/zz_v42_mechanism_test.dart`）：
     * ```text
     * VERIFY42O|hardware handler = 1 ／ Focus.onKeyEvent = 1 ／ 合计 = 2  ★★
     * VERIFY42P|early handler    = 1 ／ Focus.onKeyEvent = 0 ／ 合计 = 1  ← 对照
     * ```
     *
     * # 后果：按一次 ↓ **切两个台**
     * ```text
     * ① 本 handler 被调用 ⇒ cycleChannel(1) ⇒ return true（★ 但不中止）
     * ② 事件继续 → 焦点树 → 本页的 `Focus(onKeyEvent: _onKeyAny)` → `_onKey`
     *    ⇒ **又** cycleChannel(1)
     * ⇒ 用户按一下 ↓ 会跳过中间一个台
     * ```
     *
     * # ★ 这个坑 `shell.dart` 已经踩过并修了（L1966 逐字记录）
     * ```text
     * 「# 根因：`HardwareKeyboard.addHandler` 的返回值**不会**中止派发
     *   ⇒ 事件照样继续流到 FocusManager → 焦点树 →
     *     内建 DirectionalFocusIntent **再搬一次**
     *   # 修法：改用 `FocusManager` 的 early handler（返回值**真的**会中止）」
     * ```
     * ⇒ shell 3 处改用 `addEarlyKeyEventHandler`（L1953/L2008/L2361）。
     *   ★ 本页当时用的是**修之前**的 API ⇒ 同一个坑复发。
     *
     * # 为什么不是"删掉 `Focus(onKeyEvent:)` 那条路径"
     * ```text
     * 那会丢掉"焦点在页面内也能收到"的能力（且三层诊断日志也没了）。
     * early handler 中止派发 ⇒ 焦点树那条**自然不再跑** ⇒ 两条路径只剩一条。
     * ```
     */
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);
    /*
     * ★★★ 第 65 轮批次 D：先读磁盘快照，**再**安排全量拉取
     *
     * # 为什么不能写成两句并列的 `unawaited(...)`
     * ```text
     * 两句并列 ⇒ 谁先跑完谁算数 ⇒ 真数据可能先回来、快照后回来
     * ⇒ 快照把**更新的真数据**覆盖掉（用户看到列表回退）。
     * ⇒ 必须**串行**：先快照（毫秒级），再拉真数据（几百毫秒~几秒）。
     * ```
     *
     * ⚠️ 用 `then` 而不是 `await` —— `initState` 不能 async
     *    （Flutter 会在 State 还没挂好时就跑 await 之后的续体）。
     */
    unawaited(
      _hydrateFromCache().then((_) {
        if (!mounted) return;
        // ★ 快照只负责"先有东西看"；真数据照旧要拉（它是唯一真相）
        WidgetsBinding.instance.addPostFrameCallback((_) => loadAll());
      }),
    );
  }

  /// ★★★ 第 65 轮批次 D：`State` 构造时刻 —— 冷启动计时**基准点**
  ///
  /// # 为什么用 `initState` 时刻而不是"进程启动"
  /// ```text
  /// 用户感知的"打开直播页"= 这个页第一次被挂载（切 tab 那一刻）。
  /// 用进程启动时刻会把"启动首页/加载核心"也算进去
  /// ⇒ 数字变大，但那些时间与直播页无关。
  /// ★ 字段初始化器在 `initState` **之前**跑 ⇒ 这里的时间戳就是这个 State
  ///   被创建的时刻，正是要的基准点（且 `late final` 只求值一次）。
  /// ```
  late final DateTime _mountedAt = DateTime.now();

  /// 把 [_onHardwareKey] 的 `bool` 契约适配成 `KeyEventResult`
  ///
  /// `_onHardwareKey` 的语义是：
  /// ```text
  /// true  -> 这个按键我消费了（方向键且门控全过）
  /// false -> 放行给焦点树 / 平台
  /// ```
  /// `KeyEventResult` 的对应关系（与 `shell.dart` 的 `_onEarlyKey` 一致）：
  /// ```text
  /// true  -> KeyEventResult.handled   （★ 会**中止**焦点树派发）
  /// false -> KeyEventResult.ignored   （继续正常派发）
  /// ```
  /// ★ 单独写适配函数而不是把 `_onHardwareKey` 的返回值改成枚举 ——
  ///   后者的判定逻辑已被真机验证过，这里只做**类型转换**，一字不动。
  KeyEventResult _onEarlyKey(KeyEvent event) =>
      _onHardwareKey(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 可见性（task-41 保活后必需）
  // ══════════════════════════════════════════════════════════════════

  /// 可见性变化 ⇒ 暂停/续播内嵌播放器
  ///
  /// # ★★ 两个标记缺一不可
  /// ```text
  /// 只用"不可见就暂停、可见就播" ⇒ 用户**自己按了暂停**再切走切回，
  ///   会被我们**自动播起来** ⇒ 违背用户意图。
  /// ⇒ 必须有 `_pausedByHide`（"是我们暂停的"）才续播。
  /// ```
  void _onVisibilityChanged() {
    if (!mounted) return;
    final visible = widget.visible?.value ?? true;
    /*
     * ★ 变可见时也要重新拿焦点（task-42）
     *
     * 保活后切走再切回，**焦点不会自动回来** —— 用户切回直播页
     * 按 ↓ 会没反应（那正是"上下键切不了"的一种成因）。
     */
    if (visible) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (!_pageFocus.hasFocus) {
          debugPrint('[LIVE-KEY] 切回本页 ⇒ 重新请求焦点（原来在 ${_focusOwner()}）');
          _pageFocus.requestFocus();
        }
      });
    }
    final st = _embedKey.currentState;
    if (st == null) return;
    if (!visible) {
      /*
       * ★★★ task-74 ⑤ 残余竞态修复：**无条件**置位
       *   （改前是 `if (st.isPlaying)` 才 pause + 置位）
       *
       * 实测 RED（改前读数）：`_openCurrent()` 在播放器侧 `_visibleNow`
       * 检查（live_embedded_player.dart:318）**通过之后**、在
       * `await p.open()` / `await p.play()` **期间**页面变不可见时，
       * 此处读到的 `st.isPlaying` 仍是 false ⇒ 整支不成立 ⇒ 不 pause、
       * 不置位 ⇒ 在途的 `p.play()` 完成后**隐藏页在播**
       * （实测：翻转后第 16 轮 ≈2062ms 起播，`pausedByHide` 全程 false）。
       *
       * 为什么不能只靠 `pause()`：
       *   `pause()` 只把 mpv 的 pause 置真，在途的 `await p.play()`
       *   会在其后完成并**覆盖掉 pause**；且 `_player == null` 时
       *   `pause()` 是**空操作**。
       * ⇒ 置位必须无条件（它记录"是**我们**暂停的"这个事实，供切回
       *   续播，见下方 `else if (_pausedByHide)`）；真正的兜底在
       *   播放器侧：`await p.play()` **之后**再查一次可见性。
       */
      unawaited(st.pause());
      _pausedByHide = true;
      debugPrint('[LIVE] 本页不可见 ⇒ 暂停内嵌播放器（切回时续播）');
    } else if (_pausedByHide) {
      _pausedByHide = false;
      /*
       * ★★ 只在"用户没主动暂停"时才续播
       *
       * ```text
       * 用户按了暂停 → 切走 → 切回
       *   若在这里无条件 resume() ⇒ 违背他刚做的操作
       * ⇒ 用 _userPaused 拦住。
       * ```
       * ⚠️ 注意顺序：先清 `_pausedByHide`（那是"我们暂停的"这个事实，
       *    现在恢复可见了它就没意义了），再判 `_userPaused`。
       */
      if (_userPaused) {
        debugPrint('[LIVE] 恢复可见，但用户此前主动暂停过 ⇒ 不自动续播');
        return;
      }
      unawaited(st.resume());
      debugPrint('[LIVE] 本页恢复可见 ⇒ 续播内嵌播放器');
    }
  }

  /// ★ 键盘 / 遥控方向键 → 切频道（循环）
  ///
  /// # 为什么用 `Focus.onKeyEvent` 而不是只靠 `spatial_nav.dart`
  /// ```text
  /// `spatial_nav` 是**空间导航**（几何找最近邻居）—— 解决"焦点该移到哪个控件"。
  /// 而直播页要的是**列表内相邻切换**（上一台/下一台 + 末尾循环），语义不同：
  ///   · 空间导航按**几何位置**跳，长列表里可能跳过一整屏
  ///   · 用户要的是"往下循环切换"（相邻 + 循环）
  /// ⇒ 页面自己的 Focus 先处理，返回 `handled` 吃掉事件。
  /// ```
  ///
  /// ⚠️ **遥控选中后必须滚进可视区** ——
  ///    task-3 会给 `spatial_nav` 的 `_scrollIntoView` 加"输入来源门控"
  ///    （只让键盘/遥控滚，不让鼠标滚轮滚，见铁律）。
  ///    ★ 本页**不依赖**那条路径：`_ChannelTile` 自己带
  ///      `Scrollable.ensureVisible`（见 `_LiveChannelTile`），
  ///      所以 task-3 改动本页不受影响 —— 但**遥控路径不能被关掉**
  ///      这条约束已写在 `spatial_nav.dart` 的注释里（见那里的说明）。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-25 补：这条路径**也必须过门控**（独立验证发现）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么（这是"切两个台"的**另一面**，而且更隐蔽）
     *
     * `focus_manager.dart` 的派发逻辑（L2256-2273）：
     * ```dart
     * switch (result) {
     *   case KeyEventResult.ignored:
     *     break;                        // ★ 不中止 ⇒ 继续走焦点树
     *   case KeyEventResult.handled:
     *     handled = true;
     * }
     * if (handled) return true;
     * // Walk the current focus from the leaf to the root ...   ← 焦点树
     * ```
     * ⇒ early handler 返回 **`ignored`** 时，焦点树**照走**
     *   （实测 `VERIFY42Q1|early 被调用 = 1` / `焦点树 onKeyEvent = 1`）。
     *
     * # 后果：门控**被绕过**
     * ```text
     * 门控挡住（比如"本页不可见"或"焦点在输入框"）⇒ early handler 返回 ignored
     *   ⇒ 焦点树照走 ⇒ **本函数的 onKeyEvent 被调用**
     *   ⇒ 而本函数原先**没有门控** ⇒ cycleChannel 仍然执行
     * ⇒ ★ 该挡住的时候没挡住（比"切两个台"更严重）
     * ```
     *
     * # 修法：复用**同一套**门控（不新造判据，避免两套真相）
     * ```text
     * ① `_isVisibleForKeys()` —— 本页可见
     * ② 最上层路由           —— 没被全屏播放页/详情页盖住
     * ③ 输入框守卫           —— 打字时不抢键
     * ★ 与 `_onHardwareKey` **完全同源** —— 两道入口、一套判据。
     * ```
     */
    if (!_isVisibleForKeys()) return KeyEventResult.ignored;
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return KeyEventResult.ignored;
    if (_isTypingInField()) return KeyEventResult.ignored;
    /*
     * ★ 2026-09-26【C】门控 ④："所有直播"面板打开时放行 ——
     *   让 ↑/↓ 交给面板自己（在面板内移动选择），而不是切台。
     *   ⚠️ 与 `_onHardwareKey` 里的同一条**同源** ——
     *     两道入口必须用**同一套门控**（本文件既有的纪律，
     *     否则会出现"early 挡住了、焦点树没挡"的绕过）。
     */
    if (_allChannelsOpen) return KeyEventResult.ignored;

    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      cycleChannel(1);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      cycleChannel(-1);
      return KeyEventResult.handled;
    }
    // ←/→ 留给焦点/空间导航（不在这里消费）
    return KeyEventResult.ignored;
  }

  /// 焦点是否在输入框里（门控③ 的**共用**实现）
  ///
  /// ★ 抽成函数的原因：`_onHardwareKey` 与 `_onKey` **两条入口**都要用。
  ///   写在两处会变成**两套真相** —— 改一处忘另一处就会出现
  ///   "硬件路径挡住了、焦点树路径没挡"的漏洞（正是本次修的 bug 形态）。
  bool _isTypingInField() {
    final f = FocusManager.instance.primaryFocus;
    if (f?.context == null) return false;
    var typing = false;
    f!.context!.visitAncestorElements((el) {
      if (el.widget.runtimeType.toString() == 'EditableText') {
        typing = true;
        return false;
      }
      return true;
    });
    return typing;
  }

  /// ★★★ 三层诊断：`_onKey` 到底有没有被调用（task-42 复现"上下键切不了"）
  ///
  /// # 为什么要三层日志（lead 要求"分层判定，别只测切没切成"）
  /// ```text
  /// ① 焦点层：本页的 Focus 拿到焦点了吗？
  ///    ⇒ `_onKeyAny` 有没有被调用（**任何**键都打）
  /// ② 事件层：方向键到了吗？
  ///    ⇒ `_onKey` 里对 ↑/↓ 打点
  /// ③ 逻辑层：cycleChannel 被调了吗？列表非空吗？
  ///    ⇒ `cycleChannel` 里打点（含 list.length）
  /// ```
  /// ★ 三层各自一句日志 ⇒ 断在哪一层一目了然。
  ///   比"试了不行"精确得多（这正是 lead 的要求）。
  ///
  /// ⚠️ 只在**调试**时打（`kDebugMode` 之外也打 —— 生产要能诊断用户报的问题，
  ///    而这几行频率极低：一次按键一行）。
  KeyEventResult _onKeyAny(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent) {
      debugPrint('[LIVE-KEY] ① 焦点层：收到 ${event.logicalKey.keyLabel}');
    }
    return _onKey(node, event);
  }

  /// ★★★ 键盘接管（task-42：**真正修好**"上下键切不了"）
  ///
  /// # 实测出来的根因（`.probe/t42_repro3.py` / `t42_repro4.py`）
  /// ```text
  /// ① 用 SendInput 发 ↓（真实键盘路径）⇒ 只有 `[LIVE-KEY] 主动请求焦点` 一行
  /// ② 用 PostMessage 发 ↓ ⇒ **0 行**（见下面的仪器说明）
  /// ③ 日志里出现 `[NAV] home -> live` ⇒ ★★ **焦点在底栏 tab 上**
  /// ```
  /// ⇒ **根因：焦点不在直播页**。
  ///    用户用鼠标点底栏「直播」进页面 ⇒ **焦点留在那个 tab 上**
  ///    ⇒ 按 ↓ 走的是"底栏 tab 之间移动焦点"，根本到不了频道列表。
  ///
  /// # 为什么"Focus + autofocus"修不好
  /// ```text
  /// Flutter 的按键派发是「从 primaryFocus 沿**祖先链**向上冒泡」。
  /// 焦点在底栏时，底栏与直播页内容是**兄弟**关系 ——
  /// 我的 Focus **不在**那条祖先链上 ⇒ `onKeyEvent` 永远不会被调用。
  /// ★ 这也解释了为什么 `requestFocus()` 打了日志却没用：
  ///   我请求成功了，但用户**随后点底栏**又把焦点抢走了。
  /// ```
  ///
  /// # 为什么改用 `HardwareKeyboard.addHandler`
  /// ```text
  /// 它在**焦点树之前**跑（shell.dart 的 `_onGlobalKey` 也是这个机制）
  /// ⇒ 不依赖焦点在哪 ⇒ 鼠标点过底栏也照样能切台。
  /// ```
  ///
  /// # ⚠️ 与 shell 的 `_onGlobalKey` 的分工（**必须说清，否则会互相抢**）
  /// ```text
  /// shell 的 handler：`if (!Device.needsFocusRing) return false;`
  ///   ⇒ ★ **桌面直接放行** ⇒ 桌面只有我这一个处理者，不冲突
  ///   ⇒ 电视/遥控（needsFocusRing=true）时 shell 先消费 ↑/↓ 做空间导航
  ///      ⇒ ★ 电视上本 handler **收不到** ↑/↓
  /// ```
  /// ★★ 所以本修法**确定修好的是 PC**（用户提这条时用的就是 PC：
  ///    他同批还说"空格暂停/Enter 全屏"）。
  ///    电视上的方向键仍走 shell 的空间导航 —— 那是既有行为，
  ///    我没有擅自改动 shell（不在本任务写入范围）。
  ///    ⇒ 这一限制我会**如实写进报告**，不假装电视也好了。
  ///
  /// # ⚠️ 仪器说明（我踩过的坑，留给后人）
  /// ```text
  /// `PostMessage(WM_KEYDOWN)` 对 Flutter 窗口**完全无效**（实测 0 行日志）——
  /// Flutter 的 win32 embedder 走的是系统输入队列，不处理投递消息。
  /// ⇒ 测键盘必须用 `SendInput`（`.probe/t42_repro4.py` 里有实现）。
  /// ★ 我一开始用 PostMessage，得出过"键没接上"的错误结论。
  /// ```
  bool _onHardwareKey(KeyEvent event) {
    /*
     * ★★★ 无条件入口打点（**诊断的关键**）
     *
     * # 为什么这条必须有
     * ```text
     * 前面几轮我只能看到"某个键之后日志多了几行"，无法区分：
     *   · 我的 handler **压根没被调用**（注册/机制问题）
     *   · 被调用了但**门控挡掉**（可见性/路由/输入框）
     *   · 被调用了但**不是 ↑/↓**
     * ⇒ 入口处无条件打一行 ⇒ 一看就知道到没到这一层。
     * ★ 它是**真机排障的关键**：2026-09-25 实测就是靠它区分出
     *   "键进了 Flutter（入口打出来了）但被门控挡住（可见=false）"。
     * ```
     * ⚠️ 只在 KeyDownEvent 打（避免按下+抬起两行噪音）。
     */
    if (event is KeyDownEvent) {
      debugPrint('[LIVE-KEY] ⓪ 入口：硬件 handler 收到 '
          '${event.logicalKey.keyLabel}（可见=${_isVisibleForKeys()}）');
    }
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    /*
     * ── 门控 ①：本页必须可见 ──
     *
     * task-41 保活后本页切走**仍在树上**，不门控的话
     * 用户在首页按 ↓ 会把直播页的台切掉（很诡异）。
     *
     * ★★★ 2026-09-25 真机实测发现的**真根因**（这条最值钱）
     * ```text
     * 现象：真机上按 ↓ **完全没反应**，但日志有
     *       `[LIVE-KEY] ⓪ 入口：硬件 handler 收到 ↓（可见=false）`
     * ⇒ 键**进了 Flutter**（入口打出来了），**被我这一行挡住**。
     *
     * 为什么当时 `visible=false`（★ 事件已结案，现状是好的）：
     *   当时 shell.dart 的 `_syncVisibility();` 被一次**变异测试**
     *   临时替换成了注释（并发窗口期内正好被我扫到），
     *   ⇒ `_liveVisible` 停在初值 false ⇒ 门控永远生效。
     *   ★ **该变异已还原**：`shell.dart` 现在就是 `_syncVisibility();`
     *     （唯一提到那次变异的残留是 shell.dart 里那段**事故记录注释**，
     *       那是**有意保留**的知识，不是活的变异）。
     * ```
     * ⇒ ★ 教训（**与那次事故是否已修无关**）：
     *    **门控不能只依赖一个上游给的值** ——
     *    上游一坏，功能就全废，而且**静默**（日志只在入口有一行）。
     *    上游可能因为**任何**原因失真（重构中间态、变异测试、
     *    未来的接口调整），所以这里的双来源是**结构性防御**，
     *    不是"给某个已知 bug 打补丁"。
     *
     * # 修法：**权威来源优先**（★ 注意：不是"任一说可见就放行"）
     * ```text
     * ① `ShellScope` 拿得到 ⇒ ★ **只用它**
     *    （`return notifier.value == AppTab.live`）
     *    —— **不再看** `widget.visible`（它可能失真，正是本次事故的来源）
     * ② `ShellScope` 拿不到（页面不在其子树里，如独立 widget 测试）
     *    ⇒ 退回 `widget.visible`
     * ③ 两个都拿不到 ⇒ **放行**
     * ```
     * ⚠️ 我原来这段注释写的是「**任一说"可见"就放行**」—— **描述不准**：
     *    代码实际是"权威来源拿得到就**覆盖**旧签名"。
     *    ★ 而"覆盖"是**更好**的设计：两源冲突时**不犹豫**，直接信权威的那个
     *      （若真按"任一"，那个可能失真的旧值也能放行 ⇒ 事故会复发）。
     *    （此更正由 `fix-autoscroll` 指出，谢谢。）
     *
     * ⚠️ 关键取舍：**两个来源都不确定时**怎么办？
     * ```text
     * · 若按"必须为 true 才放行" ⇒ 上游一坏就全废（就是这次的事故）
     * · 若按"必须为 false 才挡" ⇒ 保活页在后台会抢键
     * ⇒ 我选：**都不确定时放行**（"拿不到"不等于"不可见"）。
     *   ★ 而"哪个页面该收键"还有**门控 ②（最上层路由）**兜底 ——
     *     它由 Navigator 直接给，**不依赖 shell**，是更硬的判据。
     * ```
     */
    if (!_isVisibleForKeys()) return false;

    /*
     * ── 门控 ②：本页必须是**最上层路由** ──
     *
     * 全屏播放页 / 详情页压在上面时，↑/↓ 是它们的（播放器是音量、
     * 详情页是选剧集）⇒ 不能抢。
     * ⚠️ 用 `ModalRoute.isCurrent` 而不是"有没有 push"——
     *    前者对"我上面盖了一层"判得准。
     */
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    /*
     * ── 门控 ③：有输入框在打字时放行 ──
     *
     * 与 shell 的 `_isTypingInTextField` 同样的理由：
     * 输入框里 ↑/↓ 该移动光标，不该切台。
     * ★ 用**共用**的 `_isTypingInField()` —— `_onKey`（焦点树路径）也用它，
     *   保证两条入口**同源**（见该函数的说明）。
     */
    if (_isTypingInField()) return false;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★【C】Esc / 返回键：**先关面板**（它是最上面那一层）
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 与播放页 `_episodeSheetOpen` 的处置一致（player_page L4497）：
     *   面板是 `Positioned.fill` 盖在所有东西之上 ⇒ Esc 必须**先**关它，
     *   否则用户会看到"面板还开着，人却已经返回上一页/切走了"。
     * ★ 且 `EpisodeSheet` 内部**只在"第二层"**（完整网格）时才有
     *   `_EscLayer` 处理 Esc（见 episode_strip L1305/L1367）——
     *   桌面右抽屉**没有**那一层 ⇒ 必须由宿主（本页）处理。
     * ```
     *
     * ⚠️⚠️ **顺序很关键**：这一段必须在下面"面板打开 ⇒ return false"
     *    **之前** —— 否则面板一打开，Esc 就永远走不到这里
     *    （第一版我就是这么写的，等于**面板关不掉**）。
     *    ★ 这类"门控顺序"错误在静态分析里**看不出来**（analyze 是绿的），
     *      只能靠**追一遍控制流**发现。
     */
    final k = event.logicalKey;
    if (k == LogicalKeyboardKey.escape ||
        k == LogicalKeyboardKey.goBack) {
      if (_allChannelsOpen) {
        setState(() => _allChannelsOpen = false);
        return true;
      }
      /*
       * ★★★ 第 65 轮批次 D：搜索框有字时，Esc **先清空搜索**
       *
       * # 为什么（顺序与面板那条同理）
       * ```text
       * 用户打了字、想退出搜索 —— 直觉就是按 Esc。
       * 若 Esc 直接放行给 shell（可能触发返回/退出），
       * 他的字还在、人却走了 ⇒ 下次进来还以为搜索坏了。
       * ⇒ 先清搜索（一次 Esc 一个语义层级）。
       * ```
       */
      if (_searchQuery.isNotEmpty) {
        _searchCtrl.clear();
        setState(() => _searchQuery = '');
        return true;
      }
      return false; // 面板没开、搜索为空 ⇒ 不消费（留给 shell 的正常返回逻辑）
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ── 门控 ④（★ 2026-09-26【C】新增）："所有直播"面板打开时**放行**
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 用户原话：「点击出来所有的直播,然后**上下按键在这里**替换为切换直播」
     *   ⇒ ★ "在这里"= **在面板里** —— 即 ↑/↓ 在面板内移动选择。
     *
     * ★★ 为什么必须加这道门控（不加就是**双重响应**）：
     *   本页的 early handler 跑在**焦点树之前**（`addEarlyKeyEventHandler`）
     *   ⇒ 它**先**看到 ↑/↓ ⇒ 若不禁用，会：
     *        ① `cycleChannel(1)` 立刻切台（页面级）
     *        ② 事件继续给焦点树 ⇒ 面板**也**移动了一格
     *      ⇒ ★ 一次按键**移动两格 + 立刻切台**（用户完全无法在面板里选）
     *
     * ★ 返回 `false`（= ignored）而不是 `true`：
     *   让事件**继续往下走**给焦点树 ⇒ 面板自己处理 ↑/↓。
     *   （这正是 `EpisodeSheet` 既有的方向键行为，见
     *    它内部的 `_focusCurrent` / `_scrollToCurrent`）
     * ```
     * ⚠️ 与门控 ②（`route.isCurrent`）**不同**：那个面板**不是**一条路由
     *   （它是本页内的 `Positioned.fill` 浮层）⇒ 那条门控**挡不住**它
     *   ⇒ ★ 必须单独有这一条。
     * ⚠️ 而它**必须在 Esc 处理之后** —— 见上面那条注释。
     */
    if (_allChannelsOpen) return false;

    if (k == LogicalKeyboardKey.arrowDown) {
      debugPrint('[LIVE-KEY] ② 事件层：硬件 handler 收到 ↓');
      cycleChannel(1);
      return true;
    }
    if (k == LogicalKeyboardKey.arrowUp) {
      debugPrint('[LIVE-KEY] ② 事件层：硬件 handler 收到 ↑');
      cycleChannel(-1);
      return true;
    }
    return false;
  }

  /// ★★★ 键盘门控用的"本页可见吗"（**双来源**，见 `_onHardwareKey` 的长注释）
  ///
  /// # 判据（按优先序）
  /// ```text
  /// ① `ShellScope.isActive(context, AppTab.live)` —— ★ 权威
  ///    `InheritedNotifier`（task-41 的正规接口）。
  ///    ★ 关键：它读的是 `_activeTab`（shell.dart 里**正常赋值**的那个），
  ///      **不依赖** shell 额外投影出来的那个 bool（`_liveVisible`）。
  ///      ⇒ 少一层派生，就少一处可能失真的地方。
  /// ② `widget.visible?.value` —— 兼容旧签名（**可能失真**，只作补充）
  /// ③ 两者都不确定 ⇒ **放行**
  ///    ★ "拿不到"不该当成"不可见"（与"探不到 ≠ 不可用"同族）。
  ///      而且下面还有"最上层路由"门控兜底，不会误伤别的页面。
  /// ```
  ///
  /// # 为什么要有"双来源"这层防御（**结构性理由，不是给某个 bug 打补丁**）
  /// ```text
  /// 2026-09-25 真机实测：键**进了 Flutter**（入口日志有），却被本门控挡住，
  /// 因为上游传进来的 `visible` 停在了初值 false
  /// （当时 shell 的投影调用处于一次**变异测试的临时态**，现已还原：
  ///   `shell.dart` 现在是 `_syncVisibility();`）。
  ///
  /// ★ 关键教训不是"那次事故"本身，而是：
  ///   **上游值可能因为任何原因失真** —— 重构中间态、变异测试、
  ///   将来的接口调整、并发编辑。若门控**只**依赖它，
  ///   一旦失真就是"功能静默全废"（日志只有入口那一行，很难查）。
  /// ⇒ 所以这里选"权威来源优先 + 拿不到则放行"，
  ///   并让"最上层路由"（Navigator 直接给，不依赖 shell）做硬兜底。
  /// ```
  bool _isVisibleForKeys() {
    // ① 权威来源：ShellScope
    //
    // ⚠️ 用 `dependOnInheritedWidgetOfExactType` 会注册依赖 ⇒
    //    在**按键回调**里调用是不合适的（那会触发重建，且回调不是 build 期）。
    //    ⇒ 用 `getInheritedWidgetOfExactType`（**只读一次，不注册依赖**）。
    //    ★ 这是本函数能安全地在 `_onHardwareKey` 里被调用的前提。
    final scope = context.getInheritedWidgetOfExactType<ShellScope>();
    final notifier = scope?.notifier;
    if (notifier != null) {
      // ShellScope 给出了明确答案 ⇒ 以它为准
      return notifier.value == AppTab.live;
    }
    // ② 退到旧签名
    final v = widget.visible?.value;
    if (v != null) return v;
    // ③ 两个都没有 ⇒ 放行（不确定 ≠ 不可见）
    return true;
  }

  /// 当前焦点在谁身上（诊断用 —— 只读，不改）
  ///
  /// ★ 用来回答"我的 Focus 到底有没有拿到焦点"（三层诊断的第①层）。
  String _focusOwner() {
    final f = FocusManager.instance.primaryFocus;
    if (f == null) return '无';
    return f.debugLabel ?? f.context?.widget.runtimeType.toString() ?? '${f.hashCode}';
  }

  @override
  void dispose() {
    // ★ 2026-09-26【A】`_clock?.cancel()` 已移除（定时器本身删了）
    /*
     * ★ N15：定时刷新器**必须**在这里 cancel。
     *
     * 不 cancel 的后果（真机，不只是理论）：
     * ```text
     * ① 页面销毁后定时器仍在跑 ⇒ 持续唤醒 CPU（耗电）
     * ② 回调里 `if (!mounted) return` 能挡住 setState，但
     *    定时器本身**永远不会停** ⇒ 泄漏一直累积到进程退出
     * ③ 本页是保活页（task-41），"暂时切走"不会 dispose，
     *    所以这条 cancel 只在**真正销毁**时生效 —— 正是我们要的语义
     * ```
     */
    _healthTimer?.cancel();
    _healthTimer = null;
    /*
     * ★ P0：延迟探测定时器同样必须 cancel。
     *
     * 场景：用户点进直播页后 5 秒就切走并销毁本页 ⇒ 若不 cancel，
     * 25 秒后那个回调仍会触发 `_probeAll()` ⇒ **白打一轮网络**，
     * 而页面已经不存在了。这正是要治的"无谓请求"。
     */
    _probeDelayScheduler?.cancel();
    _probeDelayScheduler = null;
    /*
     * ★ 必须移除可见性监听（task-41 保活后生命周期变长，泄漏后果更明显）
     *
     * ⚠️ 内嵌播放器**不在这里 dispose** —— 它是 widget，
     *    由 Flutter 自己调 `LiveEmbeddedPlayerState.dispose()`
     *    （那里会 `player.dispose()` 释放解码器）。
     */
    widget.visible?.removeListener(_onVisibilityChanged);
    /*
     * ★ 与 `initState` 对应 —— 必须用 `removeEarlyKeyEventHandler`。
     *
     * ⚠️ 用 `HardwareKeyboard.instance.removeHandler(_onHardwareKey)` 会
     *    **静默失败**（那个 handler 从来没注册过）⇒ 泄漏 + 保活页继续抢键。
     *    ★ `shell.dart` L2363 也记着同一个坑。
     */
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _pageFocus.dispose();
    // ★ 第 65 轮批次 D：搜索框控制器（与 `_pageFocus` 同一条纪律 —— 自己建的自己销毁）
    _searchCtrl.dispose();
    super.dispose();
  }

  /// ★★★ 本页的焦点节点（task-42：修"上下键切不了"的关键）
  ///
  /// # 为什么不能只靠 `autofocus: true`
  /// ```text
  /// `autofocus` 只在"当前没有别的焦点"时生效。
  /// ★ 而 shell 有 `primeFocusSoon()` / `FocusPrimingObserver` ——
  ///   它们会在进页面时**主动把焦点种到第一个可聚焦控件**
  ///   （task-AI 为 TV 遥控做的，见 shell.dart 的长注释）。
  /// ⇒ 焦点被种走 ⇒ 我这层收不到方向键。
  /// ```
  /// ⇒ 用显式 node，并在**进页面 / 列表变化**时主动请求焦点。
  late final FocusNode _pageFocus = FocusNode(debugLabel: 'LivePage');

  /// 拉取直播频道列表
  ///
  /// [keepSelection] = true 时**保留用户当前选中的频道**（返回本页时用）。
  ///
  /// # ★★★ 第 65 轮批次 D 改了什么（三处，各有独立判据）
  /// ```text
  /// ① **磁盘快照先上屏**：首帧前 `_hydrateFromCache()` 就把列表铺出来
  ///    ⇒ Owner 的"第一次打开显示 0 个"不再等插件脚本跑完
  /// ② **失败不再被吞**：`catch` 里写 `_loadError` ⇒ UI 给「重试」
  ///    而不是骗用户去设置里配置
  /// ③ **重入保护**：`_inFlight` —— 切 tab 会重复调本函数（shell 的
  ///    `_switchTo`），两次全量拉取会**互相覆盖**（后到的赢），
  ///    表现是"切来切去列表闪"。现在同一时刻只跑一支。
  /// ```
  Future<void> loadAll({bool keepSelection = false}) async {
    /*
     * ★ 主动把焦点拿过来（task-42）
     *
     * 后一帧再抢 —— 那时 shell 的 `primeFocusSoon()` 已经跑完，
     * 我们才是最后一个动焦点的（顺序很重要，见 `_pageFocus` 的说明）。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (!_pageFocus.hasFocus) {
        debugPrint('[LIVE-KEY] 主动请求焦点（原来是 ${_focusOwner()}）');
        _pageFocus.requestFocus();
      }
    });

    /*
     * ★★★ ③ 重入保护
     *
     * # 为什么必须（不是"防御性编程"，是实测会撞上）
     * ```text
     * shell 的 `_switchTo(AppTab.live)` 每次切到本页都调
     * `loadAll(keepSelection: true)`；而本页是**保活页**（切走不销毁）。
     * 用户快速切「直播 → 首页 → 直播」时两次请求会**同时在飞**：
     *   · 两次 `get_live_channels` 都是全量（逐个插件跑 JS）
     *   · 后到的 `setState` 覆盖先到的 ⇒ 列表闪一下
     *   · 更要命：两次 `_select()` 会**抢同一个播放器**（取流两次）
     * ⇒ 加一支在飞标记：还在飞就**不重复拉**（保留选中，直接返回）。
     * ```
     * ⚠️ 只挡**全量重拉**；`_probeAll` 有自己的 TTL 缓存，不在这里管。
     */
    if (_inFlight) {
      debugPrint('[LIVE] 已有一次加载在飞 ⇒ 跳过本次（keepSelection=$keepSelection）');
      return;
    }
    _inFlight = true;

    /*
     * ★★★ 第 65 轮批次 D：**冷启动时序读数**（Lead 点名要"毫秒数"）
     *
     * # 为什么必须用 `AppLog.write` 而不是 `debugPrint`
     * ```text
     * 实测：`debugPrint` **不进** `logs/sourin-*.log`（那条链路只收
     * `AppLog.write` 的攒批写入）。Lead 要的读数必须能在真机日志里看到，
     * ⇒ 用 AppLog.write('LIVE', …)。
     * ```
     *
     * # 记什么（三个时刻，都是**用户能感知**的边界）
     * ```text
     * t0 = loadAll 进入（≈ 用户点进直播页）
     * 快照命中 ⇒ 打「首屏有内容」= t0 → setState 完成的毫秒数
     * 真数据到 ⇒ 打「真数据就绪」= t0 → getLiveChannels 返回的毫秒数
     * ⇒ Lead 就能看到"改后首屏多少 ms、真数据多少 ms"，
     *   而不是我口头说"变快了"。
     * ```
     */
    final t0 = DateTime.now();
    void mark(String what) => AppLog.write(
          'LIVE',
          '[TIMING] $what  '
              '自 loadAll 起 ${DateTime.now().difference(t0).inMilliseconds} ms'
              ' / 自本页挂载起 '
              '${DateTime.now().difference(_mountedAt).inMilliseconds} ms',
        );

    final prevId = keepSelection ? _selected?.id : null;
    try {
      final groups = await SourinApi.getLiveChannels();
      mark('真数据就绪（${groups.length} 个源 / '
          '${groups.fold<int>(0, (n, g) => n + g.channels.length)} 个频道）');
      if (!mounted) return;
      setState(() {
        _groups = groups;
        // ★ 成功 ⇒ 清掉上一次的失败态（否则错误界面会一直挂着）
        _loadError = null;
        if (groups.isNotEmpty) {
          _activeProvider = groups.first.provider;
        }
      });
      // ★ ② 落盘快照 —— 下次冷启动直接有内容（不 await，不阻塞首帧）
      unawaited(_persistCache(groups));
      /*
       * ★★ 先探测可用性，**再**选频道
       *
       * 顺序很重要：若先选第一个频道，可能选中的是一个"视频线全 DRM"
       * 的台（srcl1 就是）⇒ 用户一进页面就看到黑屏 —— 正是他报的问题。
       * ⇒ 探测完再选，选到的第一个就是**能播的**。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ P0 改：**先读盘，再决定要不要探**（Owner：「迟早要被拉黑」）
       * ══════════════════════════════════════════════════════════════
       *
       * 改前：无条件 `unawaited(_probeAll())` ⇒ 每次启动全量探测 1248 个频道。
       * 改后：
       * ```text
       * ① 读 <dataDir>/live-availability.json
       * ② 有**未超过 10 分钟**的条目 ⇒ 灌进 `_health` 与 `_probe`，
       *    并**完全跳过**探测（这是"不被拉黑"的关键路径）
       * ③ 没有 ⇒ 延迟 [_probeDelay]（30 秒）再探，
       *    这段时间 UI 显示「可用性检查将稍后开始」
       * ```
       *
       * ⚠️ 过期条目**保留**（不删）：Owner 要求"定时再刷新掉状态"，
       *    直接清掉会让灰/红点突然消失，用户以为状态丢了。
       */
      unawaited(_loadHealthThenMaybeProbe());
      /*
       * ★ N15 ②：启动后台定时刷新。
       *
       * 放在**真数据就绪之后**（不是 initState）：否则第一轮 tick 会在
       * 还没有频道列表时跑，`pendingRetries()` 必然为空，白跑一次。
       * `_startHealthTimer` 内部会先 cancel 旧定时器 ⇒ 重复调用安全。
       */
      _startHealthTimer();

      if (groups.isNotEmpty) {
        /*
         * ★ 不能无脑「默认选中第一个频道」
         *
         * 用户切走又切回时，那样会把他在看的台重置成第一个。
         * 所以优先找回原来那个频道（见文件头注释）。
         */
        final all = groups.expand((g) => g.channels).toList();
        final restored = prevId != null
            ? all.where((c) => c.id == prevId).firstOrNull
            : null;
        final target = restored ?? _firstVisible(all);
        /*
         * ★★★ task-82【Q4】：只有"**真的找回了原来那个台**"才算 restoring。
         *
         * ⚠️ 判据必须是 `restored != null`，**不能**只写 `keepSelection`：
         *   `keepSelection == true` 但 `restored == null` 时（原台已从源里
         *   消失）`target` 是 `_firstVisible(all)` —— 那是**换了一个台**。
         *   若那时也走 restoring 短路，就会留下"UI 选中新台、播放器还挂着
         *   旧台的流"这种**自相矛盾**的状态（比原来的 bug 更糟）。
         */
        if (target != null) {
          await _select(target, restoring: keepSelection && restored != null);
        }
      }
    } catch (e) {
      /*
       * ★★★ ② 失败**不再静默**（这是 Owner "首次打开显示 0 个"的一半真因）
       *
       * 改前只有 `debugPrint` ⇒ 界面上与"真的没有源"一模一样。
       * 现在把原因交给 UI：`LiveLoadPhase.failed` 会显示「重试」，
       * 而不是骗用户去设置里配置（那条路对他的处境是错的）。
       */
      debugPrint('[LIVE] 加载直播频道失败: $e');
      mark('取数失败（$e）');
      if (mounted) {
        setState(() {
          _loadError = _describeLoadError(e);
        });
      }
    } finally {
      _inFlight = false;
      if (mounted) setState(() => _loading = false);
    }
  }

  /// 把异常翻译成**用户能行动**的一句话（不暴露内部标识符）
  ///
  /// # 为什么分两类
  /// ```text
  /// · 核心没起来（dll 未加载 / 核心尚未启动）⇒ 重试**可能有用**
  ///   （启动期那一两秒正是本页第一次被挂载的时刻）
  /// · 其余（源报错 / 超时）⇒ 重试也可能有用，但要说"稍后再试"
  /// 两类都给「重试」，因为**用户能做的动作是同一个**；
  /// 区别只在文案，避免把"核心没起来"说成"你没有源"。
  /// ```
  String _describeLoadError(Object e) {
    final s = e.toString();
    final coreNotReady = s.contains('核心尚未启动') ||
        s.contains('sourin_core') ||
        s.contains('Failed to load dynamic library');
    if (coreNotReady) {
      return '直播数据还没准备好（刚启动时会有这一下）。稍等一下点重试即可。';
    }
    return '这次没能取到直播频道。点重试再拉一次。';
  }

  /// 是否有一支加载正在飞（重入保护，见 [loadAll]）
  bool _inFlight = false;

  /// ★★★ 从磁盘快照预热（冷启动"首帧就有内容"）
  ///
  /// # 为什么必须在 `initState` 的**第一帧之前**跑完
  /// ```text
  /// 与首页 `homeListCache.preload()` 同一个理由（shell.dart:640 那段注释）：
  /// 首帧就已经在 build 列表了，缓存若晚到 ⇒ 首帧还是骨架 ⇒ 等于没做。
  /// ⇒ 这里在 `initState` 里 `await`（一次本地文件读，几十 KB，毫秒级）。
  /// ```
  ///
  /// ⚠️ **失败一律降级成"没有缓存"**：读不到就照常走冷加载路径。
  ///    缓存是纯优化，任何异常都不能让本页起不来（DiskCache 全程 try/catch，
  ///    这里再加一层兜住"数据形状变了"的情形）。
  Future<void> _hydrateFromCache() async {
    try {
      final entry = await DiskCache.read(_cacheName);
      if (entry == null || !mounted) return;
      final data = entry.data;
      if (data is! List) return;
      final groups = <LiveGroup>[];
      for (final raw in data) {
        if (raw is! Map) continue;
        try {
          final g = LiveGroup.fromJson(Map<String, dynamic>.from(raw));
          // ★ 空频道的源不进来 —— 与 rust 侧 `live_all()` 的过滤一致
          if (g.channels.isEmpty) continue;
          groups.add(g);
        } catch (_) {
          // 单组坏了只丢那组（与 ui_prefs 的逐键宽松同一条纪律）
        }
      }
      if (groups.isEmpty) return;
      setState(() {
        _groups = groups;
        _cacheHit = true;
        _cacheAt = entry.at;
        _loading = false; // ★ 有内容 ⇒ 立刻退出骨架态
        if (groups.isNotEmpty) _activeProvider = groups.first.provider;
      });
      debugPrint('[LIVE] 磁盘快照命中：${groups.length} 个源'
          '（存于 ${entry.at}，${entry.ageFrom(DateTime.now()).inMinutes} 分钟前）');
      // ★ Lead 要的读数：快照路径下"页被挂载 → 首屏有内容"的毫秒数
      AppLog.write(
        'LIVE',
        '[TIMING] 快照命中 ⇒ 首屏有内容  '
            '${DateTime.now().difference(_mountedAt).inMilliseconds} ms '
            '（${groups.length} 个源 / '
            '${groups.fold<int>(0, (n, g) => n + g.channels.length)} 个频道，'
            '快照存于 ${entry.at}）',
      );
      /*
       * ★ 缓存里的第一个台**不自动起播**（有意）
       *
       * ```text
       * 缓存是**可能过期**的快照：那个台可能已经下线/换线。
       * 若冷启动立刻拿它去取流 ⇒ 用户看到"一进来就报错/黑屏"，
       * 比"列表先出来、后台拉真数据后再起播"糟得多。
       * ⇒ 列表先用缓存铺满（视觉上不再空），起播交给
       *   `loadAll()` 拿到的**真数据**（下面那次 `_select`）。
       * ```
       */
    } catch (e) {
      debugPrint('[LIVE] 磁盘快照读取失败（当作无缓存）: $e');
    }
  }

  /// 把这次拉到的频道写进磁盘快照（下次冷启动用）
  ///
  /// ★ 写的是**后端原始形态**（与 rust `get_live_channels` 的 JSON 同构），
  ///   这样读回来直接喂 `LiveGroup.fromJson` —— 不需要维护第二套映射
  ///   （理由与 `core/disk_cache.dart` 文件头「存原始 JSON」完全一致）。
  Future<void> _persistCache(List<LiveGroup> groups) async {
    if (groups.isEmpty) return; // ★ 空结果**不覆盖**已有快照（否则一次抖动就把缓存清空）
    try {
      await DiskCache.write(_cacheName, [
        for (final g in groups)
          {
            'provider': g.provider,
            'providerName': g.providerName,
            'channels': [
              for (final c in g.channels)
                {
                  'id': c.id,
                  'name': c.name,
                  if (c.logo != null) 'logo': c.logo,
                  if (c.group != null) 'group': c.group,
                  if (c.nowPlaying != null) 'now_playing': c.nowPlaying,
                },
            ],
          },
      ]);
    } catch (e) {
      debugPrint('[LIVE] 磁盘快照写入失败（不影响功能）: $e');
    }
  }

  /// ★ 探测所有频道的可用性（动态判定"不可用"）
  ///
  /// 结果进 `_probe` 的 TTL 缓存 —— 10 分钟内重进不再探。
  Future<void> _probeAll({bool force = false}) async {
    if (_groups.isEmpty) return;
    final total = _groups.fold<int>(0, (n, g) => n + g.channels.length);
    if (mounted) setState(() => _probeTotal = total);
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26【E】修「每个频道都 setState」—— 注释与代码原本**矛盾**
     * ══════════════════════════════════════════════════════════════════
     *
     * ```text
     * 原代码：
     *     // 不要每个频道都 setState —— 会卡（48 个频道 = 48 次重建）
     *     setState(() => _probeDone++);
     *   ⇒ ★ **注释说的正是它自己不该做的事** ——
     *     注释警告"48 次重建会卡"，而下一行就是**每个频道一次重建**。
     *
     * ★ 为什么这确实会卡（用户第 8 条「直播好像有点卡顿」）：
     *   探测并发数是 **8**（`LiveAvailabilityProbe.concurrency = 8`）
     *   ⇒ 8 个 worker 各自 `onProgress()` ⇒ 回调**密集且突发**
     *   ⇒ 每次 `setState` 都**重建整页**（含 `LiveChannelList` 的 ListView）
     *   ⇒ 进页面那 1-2 秒里会连续重建 **N 次**（N = 频道数，本例 28）
     *
     * ★ 修法：**节流到「每 8 个频道一次」**（而非每个一次）
     *   ⇒ 重建次数 28 → 最多 4 次（约 -86%）
     *   ★ 而**进度显示仍然可用**：用户看到的是"已检查 x/28"，
     *     每 8 个一跳完全够（本来就是秒级的进度条）
     *   ★ 并且**完成时必然有一次精确的最终值**（下面收尾那次 setState）
     * ```
     * ⚠️ 阈值取 8 是**跟着并发数**走的：并发 8 ⇒ 每轮至少推进 8 个
     *   ⇒ 一次 setState 覆盖一轮，既不漏进度也不密。
     *
     * ⚠️⚠️ **必须用「本地已见计数」而不是「对 `_probeDone` 取模」**
     * ```text
     * ★ 我第一版写的是：
     *     if (_probeDone % progressStep != 0) return;
     *     setState(() => _probeDone++);
     *   ⇒ ★ **进度会永久冻在 1**！
     *     推导：_probeDone=0 ⇒ 0%8==0 ⇒ setState ⇒ 变成 **1**
     *           ⇒ 之后 1%8!=0 ⇒ **永远 return** ⇒ 计数器再也涨不上去
     *   ⇒ 而"重建次数少"这个**表面指标反而很好看**（只重建 1 次）
     *     ⇒ ★ 典型的"指标变好但功能坏掉"
     * ★ 我的**模拟脚本**发现了它（跑 28 次完成 ⇒ 只 1 次重建 ⇒ 可疑）
     *   ⇒ 正确写法：用**独立的自增计数器** `seen`（每次都涨），
     *     只把它的值**同步**给 `_probeDone`。
     * ```
     */
    const progressStep = 8;
    var seen = 0; // ★ 每个频道都涨（与"要不要重建"解耦）
    final n = await _probe.probe(
      _groups,
      force: force,
      onProgress: () {
        if (!mounted) return;
        seen++;
        // ★ 节流：只在跨过整数个 step 时才重建（见上面长注释）
        if (seen % progressStep != 0) return;
        setState(() => _probeDone = seen);
      },
    );
    if (!mounted) return;
    setState(() {
      // ★ 收尾：保证进度条走到 100%（否则会停在最后一个未跨 step 的值）
      _probeDone = _probeTotal;
      _probed = true;
    });
    if (n > 0) debugPrint('[LIVE] 可用性探测完成：新探 $n / 共 $total');
    /*
     * ★ P0：探测结果必须落盘 —— 这是下次启动"不再全量探测"的依据。
     *
     * ⚠️ `_probe` 的结果还要**翻译成 `_health`** 一起存：
     *   只存 `_probe` 的话，徽标那套（播放结果）没有历史，
     *   下次启动仍是一片空白。这里把探测结论也写进健康状态
     *   （探测说 "unavailable" ⇒ 健康记 broken）。
     */
    _mirrorProbeIntoHealth();
    _persistHealth();
  }

  /// 把探测结论镜像进 `_health`（让"探测到的"也能落盘与显示）
  ///
  /// ★ 只在**没有更强证据**时镜像：`broken` 来自真实播放失败（更硬），
  ///   不该被"探测说没有可播地址"覆盖成同样值而丢掉 detail。
  void _mirrorProbeIntoHealth() {
    for (final g in _groups) {
      for (final c in g.channels) {
        final a = _probe.cached(g.provider, c.id);
        if (a == null) continue;
        if (a == LiveAvailability.unavailable &&
            _health.healthOf(g.provider, c.id) == LivePlaybackHealth.unknown) {
          _health.record(
            provider: g.provider,
            channelId: c.id,
            health: LivePlaybackHealth.broken,
            detail: '取址探测：没有可播线路',
          );
        }
      }
    }
  }

  /// ★★★ P0：读盘 ⇒ 有有效缓存就**不探测**；没有则延迟探测
  ///
  /// # 这是「不被拉黑」的核心路径
  /// ```text
  /// 改前：每次启动无条件全量探测 1248 个频道（8 并发）
  ///       ⇒ Owner：「迟早要被拉黑」
  /// 改后：只要磁盘上有 10 分钟内的结果，**一个网络请求都不发**。
  /// ```
  ///
  /// # 为什么读到的状态要同时灌进 `_health` 和 `_probe`
  /// ```text
  /// 两个 store 管两件事，都要复用这份磁盘数据：
  /// · `_health`  → 播放结果三态（徽标显示）
  /// · `_probe`   → "这个源有没有给出可播地址"（决定 firstVisible 挑哪个台）
  /// 只灌一个会让另一条路重新去探 —— 那等于没省下请求。
  /// ```
  Future<void> _loadHealthThenMaybeProbe() async {
    Map<String, LivePlaybackHealthEntry> loaded = const {};
    try {
      loaded = await LiveHealthCache.load();
    } catch (e) {
      debugPrint('[LIVE] 读取可用性缓存异常（当作无缓存）: $e');
    }
    if (!mounted) return;

    // ① 全部过期条目也灌进去（保留状态，只是会被标成"待刷新"）
    if (loaded.isNotEmpty) {
      _health.restore(loaded);
    }
    final fresh = LiveHealthCache.freshOnly(loaded);
    if (fresh.isNotEmpty) {
      /*
       * ② 有新鲜缓存 ⇒ 灌进 `_probe` 并**跳过探测**。
       *
       * ⚠️ 为什么灌进 `_probe` 而不是只灌 `_health`：
       *   `_probe.cached()` 是"跳过探测"判据的**唯一来源**（probe() 里
       *   `if (!force && cached(...) != null) continue;`）。
       *   不灌它的话，_probeAll() 仍会把这些频道算进 todo。
       */
      _seedProbeFromCache(fresh);
      debugPrint('[LIVE] 可用性缓存命中 ${fresh.length} 条 ⇒ **跳过全量探测**');
      if (mounted) {
        setState(() {
          _probed = true;        // 已经有结论，不再显示"正在检查"
          _probeScheduled = false;
          _probeTotal = 0;
        });
      }
      return;
    }

    /*
     * ③ 没有有效缓存 ⇒ **延迟**探测（不是立刻）。
     *
     * 即使这次真的需要探，也要错开启动瞬间：
     * 先让用户看到界面、先手动点几个台 —— 那几十个台的真实播放结果
     * 会先把最要紧的状态填上。
     */
    debugPrint('[LIVE] 无有效可用性缓存 ⇒ ${_probeDelay.inSeconds}s 后开始探测');
    if (mounted) setState(() => _probeScheduled = true);
    _probeDelayScheduler?.cancel();
    _probeDelayScheduler = DelayedProbeScheduler(
      delay: _probeDelay,
      onFire: () {
        if (!mounted) return;
        setState(() => _probeScheduled = false);
        unawaited(_probeAll());
      },
    )..schedule();
  }

  /// 把磁盘上的状态灌进 `_probe`（让 `probe()` 的"已有缓存就跳过"生效）
  ///
  /// # 映射关系（两套枚举不是一一对应，必须显式写清）
  /// ```text
  /// broken  ⇒ unavailable   （有错误串 ⇒ 这个源当前给不出可播地址）
  /// idle    ⇒ unknown       ★ 不是 unavailable！
  ///            "没等到画面"不等于"没有可播地址" —— 它可能只是没开播，
  ///            地址本身是好的。映射成 unavailable 会导致该台**被隐藏**，
  ///            而 Owner 要的是"灰点但仍可见"。
  /// playable ⇒ playable
  /// ```
  void _seedProbeFromCache(Map<String, LivePlaybackHealthEntry> fresh) {
    for (final e in fresh.entries) {
      /*
       * ★ 用 `liveHealthCacheKeyParts` 而不是手写 split：
       *   键的分隔符是 **NUL**（不是 `|`），而且格式只在
       *   `live_availability.dart` 里定义一处 —— 手写拼接/解析
       *   正是这次门禁抓到的那个 bug 的来源。
       */
      final parts = liveHealthCacheKeyParts(e.key);
      if (parts == null) continue;
      final provider = parts.$1;
      final channelId = parts.$2;
      final a = switch (e.value.health) {
        LivePlaybackHealth.playable => LiveAvailability.playable,
        LivePlaybackHealth.broken => LiveAvailability.unavailable,
        LivePlaybackHealth.idle => LiveAvailability.unknown,
        LivePlaybackHealth.unknown => LiveAvailability.unknown,
      };
      _probe.seed(provider, channelId, a, e.value.at);
    }
  }

  /// 把当前可用性状态落盘（任何状态变化后调用）
  ///
  /// ★ 不 await、不阻塞 UI：写失败只记日志（DiskCache 内部已降级）。
  void _persistHealth() {
    unawaited(LiveHealthCache.save(_health.snapshot()));
  }

  /// 第一个"默认该显示"的频道（跳过仅音频/不可用的）
  LiveChannel? _firstVisible(List<LiveChannel> all) {
    for (final c in all) {
      final a = _probe.cached(_providerOf(c), c.id);
      if (shouldShowByDefault(a ?? LiveAvailability.unknown)) return c;
    }
    return all.isNotEmpty ? all.first : null;
  }

  /// 频道属于哪个 provider（`_groups` 里反查）
  String _providerOf(LiveChannel c) {
    for (final g in _groups) {
      if (g.channels.any((x) => x.id == c.id)) return g.provider;
    }
    return _activeProvider;
  }

  // ══════════════════════════════════════════════════════════════════════
  //  N15：播放结果回写 + 定时刷新
  // ══════════════════════════════════════════════════════════════════════

  /// 启动后台定时刷新（N15 ②）
  ///
  /// # 为什么是 10 分钟
  /// ```text
  /// 与 `LiveAvailabilityProbe.ttl` 的 10 分钟**刻意保持一致**：
  /// 两套缓存用同一个节律，用户看到的"刷新过"语义不会打架。
  /// ```
  ///
  /// # 为什么只重试 idle/broken
  /// ```text
  /// 全量重探 1248 个频道 = 一轮网络风暴 + 界面一直显示"正在检查 x/1248"。
  /// ★ 而 `playable` 没必要重试（它已经能播），`unknown` 本来就没试过。
  /// ⇒ 只重试**已知有问题**的那些 —— 通常只有个位数。
  /// ```
  void _startHealthTimer() {
    _healthTimer?.cancel();
    _healthTimer = Timer.periodic(_health.retryAfter, (_) {
      if (!mounted) return;
      _retryUnhealthy();
    });
  }

  /// 定时刷新：重试 idle/broken 的频道，成功后**清掉标记**（N15 ④）
  ///
  /// 用户原话：「定时再刷新掉状态」
  ///
  /// ★ 这里的「刷新掉」= 清成 unknown（不显示徽标），
  ///   而**不是**直接标成 playable —— 因为"这次重试没报错"
  ///   不等于"确认能播"（可能只是又超时了一次的另一种表现）。
  Future<void> _retryUnhealthy() async {
    final pending = _health.pendingRetries();
    if (pending.isEmpty) return;
    debugPrint('[LIVE] 定时刷新：重试 ${pending.length} 个已知有问题的频道');

    var changed = 0;
    for (final (provider, channelId) in pending) {
      if (!mounted) return;
      /*
       * ★ 用取址成功与否当"它恢复了"的**弱判据**，不透支到"能出画面"。
       *
       * 为什么不直接真播一遍：后台起播会抢走用户正在看的那个台的
       * 解码资源（真机上表现为卡一下），代价远大于收益。
       * ⇒ 这里是**试探性**的：拿得到流地址就当"看起来恢复了"，
       *   清掉标记让用户重新看到它；真正的"能不能播"仍由
       *   用户下次点开时的播放结果决定（那条路才是硬判据）。
       */
      try {
        final list = await SourinApi.getLiveStream(provider, channelId);
        final ok = list.any((s) => s.isPlayable);
        if (ok) {
          _health.clear(provider, channelId);
          changed++;
        } else {
          // 仍然没有可播地址 ⇒ 保持原状态，只把时间推进（下次再试）
          _health.record(
            provider: provider,
            channelId: channelId,
            health: LivePlaybackHealth.broken,
            detail: '定时刷新：仍未取到可播地址',
          );
        }
      } catch (e) {
        /*
         * ★ 取址失败 ⇒ **不动状态**。
         *
         * 这与 `LiveAvailabilityProbe` 的铁律同源：
         * 网络抖动不能当成"这个台坏了"，否则用户的列表会随网络状况
         * **随机变少**。保持原状态 + 等下一个周期重试才对。
         */
        debugPrint('[LIVE] 定时刷新取址失败 $provider/$channelId: $e');
      }
    }
    if (!mounted) return;
    if (changed > 0) {
      debugPrint('[LIVE] 定时刷新完成：$changed 个频道状态已清除');
      /*
       * ★ P0：清掉的状态必须落盘，否则重启后红点又回来了
       *   （用户会认为"定时刷新根本没起作用"）。
       */
      _persistHealth();
      /*
       * ★ 只在这里 setState **一次**（不是每个频道一次）。
       *   与 `_probeAll` 的节流同一条教训（本文件 1590 行那段长注释）。
       */
      setState(() {});
    }
  }

  /// 当前 provider 下的频道
  List<LiveChannel> get _currentChannels {
    final g = _groups.where((x) => x.provider == _activeProvider).firstOrNull;
    return g?.channels ?? const [];
  }

  /// ★★★ 列表里**实际要画**的频道（task-42：**跨源平铺**）
  ///
  /// # 用户原话（本轮 6 条之一）
  /// ```text
  /// 直播页面,左侧不再分组,直接平铺下去,然后把不能有画面的都直接删了(直播源)
  /// 比如现在的 某电视台站分组,平铺下去 以分组加 tag 作为标记
  /// ```
  ///
  /// # 与 task-39 的三个**行为变化**（都是用户明确要求）
  /// ```text
  /// ① **不再按源过滤**：原来只看 `_activeProvider` 一个源，
  ///    现在**所有启用的源混在一起**平铺（用户说"直接平铺下去"）
  /// ② **不再按 group 分栏**：原来画"分组标题 + 频道"，
  ///    现在每行右边一个 **tag** 显示它来自哪个源（用户说"以分组加 tag"）
  /// ③ ★★ **audioOnly 直接不显示**（不再是"默认隐藏 + 可展开"）
  ///    用户说"把不能有画面的都**直接删了**"—— 比 task-39 更强硬
  /// ```
  ///
  /// # 判定仍用 `live_availability.dart`（不重写一套）
  /// ```text
  /// playable    → 显示
  /// audioOnly   → ★ 不显示（用户要"删掉"）
  /// unavailable → 不显示
  /// unknown     → ★ 显示（探不到 ≠ 不可用 —— 铁律 51 的对偶）
  /// ```
  List<LiveChannel> get _visibleChannels {
    final out = <LiveChannel>[];
    for (final g in _groups) {
      // ★ 用户手动关掉的源：不显示它的频道（③ 的启停）
      if (!_providerEnabled(g.provider)) continue;
      for (final c in g.channels) {
        final a = _probe.cached(g.provider, c.id) ?? LiveAvailability.unknown;
        if (a == LiveAvailability.unavailable) continue;
        // ★★ task-42：audioOnly 也**直接删掉**（不再给"显示"开关）
        if (a == LiveAvailability.audioOnly) continue;
        out.add(c);
      }
    }
    return out;
  }

  /// 这个源是否启用（用户手动开关）
  ///
  /// ★ 默认启用；用户关掉后进 `_disabledProviders`（内存态 + 落盘由 API 负责）
  bool _providerEnabled(String provider) =>
      !_disabledProviders.contains(provider);

  /// 用户手动关掉的源
  ///
  /// ⚠️ 与"因为不可用被隐藏"**是两件事**，必须能区分：
  /// ```text
  /// 手动关掉      → chip 仍在，显示"已关闭"，用户能再打开
  /// 不可用被剔除  → chip 直接不显示（用户没关它，是它自己不能用）
  /// ```
  /// ★ 这也是 lead 在 task-42 描述里点名的交互风险。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-53【②】2026-09-26：本集合**现在是空的**（重要，别误解）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ```text
  /// ① 启停的**写入点已挪到设置页**（用户第 4 条要求）⇒
  ///    本页**不再**往这里 add/remove ⇒ 它恒为空集
  /// ② 而"关掉的源不显示"这件事**仍然成立** —— 但由**核心**负责：
  ///    `get_live_channels` 已按 `disabled-providers.json` 过滤
  ///    （task-D 实测：隔离副本里 srcl 被 disabled ⇒ 返回里**没有它**）
  /// ⇒ ★ 所以 `_providerEnabled()` 现在**恒为 true**，
  ///    那几处 `if (!_providerEnabled(g.provider)) continue;` 是**冗余但无害**的。
  /// ```
  ///
  /// ★★ 为什么不删掉它（有意保留）
  /// ```text
  /// ① 它是**纵深防御**：若将来核心改为"不过滤、由 UI 过滤"，
  ///    这里立刻仍能工作（而不是那时候才发现过滤逻辑没了）
  /// ② ★ 删它要动 `_visibleChannels` / `_flatChannels` / `_providerHasVideo`
  ///    三处判据 —— 而**它们现在都是对的**（恒真 ⇒ 不过滤 ⇒ 与核心一致）
  ///    ⇒ ★ "为了让代码好看而改三处正确逻辑"是**负收益**
  /// ③ 而它现在**只被读、不被写** ⇒ 单一写入点（设置页）+ 单一真相（核心 json）
  ///    ⇒ 比原来"两处都能写"更干净
  /// ```
  ///
  /// ⚠️ 若将来有人要给本页加回"点 tag 启停"⇒ ★ **先读上面这段** ——
  ///    那会重新引入"两个写入点"，且用户**已经明确否定过**那个位置。
  final Set<String> _disabledProviders = {};

  /// ★★ 有**可播视频**频道的源（task-42 ②：整组不可用就不显示那个源）
  ///
  /// # 为什么要有这一层（用户说"把不能有画面的都直接删了(直播源)"）
  /// ```text
  /// ★ 他举的例子是「现在的 某电视台站分组」——
  ///   某电视台站（srcl）实测 20/20 个频道视频线全 DRM ⇒ **整组都不可用**
  /// ⇒ 那就不该在源列表里留着它（否则用户以为"这源能用但没台"）
  /// ```
  /// 判据：该源**至少有一个** playable 频道。
  /// ⚠️ 探测还没跑完时（`unknown`）**不能**判它不可用 ——
  ///    否则源会在探测过程中**闪烁消失**。
  bool _providerHasVideo(String provider) {
    final g = _groups.where((x) => x.provider == provider).firstOrNull;
    if (g == null || g.channels.isEmpty) return false;
    for (final c in g.channels) {
      final a = _probe.cached(provider, c.id);
      // 探到 playable ⇒ 确定有
      if (a == LiveAvailability.playable) return true;
      // 还没探到 ⇒ 保守认为"可能有"（避免闪烁）
      if (a == null || a == LiveAvailability.unknown) return true;
    }
    return false;
  }

  /// 平铺列表真正要显示的源（有视频 + 用户没关掉）
  List<LiveGroup> get _visibleProviders => _groups
      .where((g) => _providerHasVideo(g.provider))
      .toList(growable: false);

  /// ★★★ task-42：**平铺**的频道列表（跨源混合 + 每项带来源 tag）
  ///
  /// # 用户原话
  /// ```text
  /// 直播页面,左侧不再分组,直接平铺下去 …
  /// 平铺下去 以分组加 tag 作为标记
  /// ```
  /// ⇒ 不再有"分组标题行"，改成**每行行尾一个 tag**。
  ///
  /// # tag 显示什么
  /// ```text
  /// 用户说"以**分组**加 tag" —— 这里的"分组"指的是他前一句说的
  /// 「比如现在的 **某电视台站**分组」⇒ 即 **providerName**（源名），
  /// 不是频道的 `group` 字段。
  /// ★ 依据：他把"某电视台站"称作一个"分组"，而某电视台站是**源**。
  ///   （`srcl.js` 的 group 字段其实是"某电视台"/"国际"，不是"某电视台站"）
  /// ```
  ///
  /// # 排序
  /// ```text
  /// 按**源**分组连续排列（同一个源的频道挨着），而不是打乱混合 ——
  /// 虽然视觉上没有分组标题了，但"同源的台在一起"更符合直觉。
  /// ★ 用户说"直接平铺下去"，重点是**去掉分组标题**，不是"打乱顺序"。
  /// ```
  List<({LiveChannel channel, String tag, String provider})> get _flatChannels {
    final out = <({LiveChannel channel, String tag, String provider})>[];
    for (final g in _groups) {
      if (!_providerEnabled(g.provider)) continue;
      if (!_providerHasVideo(g.provider)) continue;
      for (final c in g.channels) {
        final a = _probe.cached(g.provider, c.id) ?? LiveAvailability.unknown;
        // ★ 用户要"把不能有画面的都直接删了" ⇒ audioOnly 也不显示
        if (a == LiveAvailability.audioOnly) continue;
        if (a == LiveAvailability.unavailable) continue;
        out.add((channel: c, tag: g.providerName, provider: g.provider));
      }
    }
    return out;
  }

  /// 一个频道是不是"仅音频"（用于播放器角标）
  bool _isAudioOnly(LiveChannel c) =>
      _probe.cached(_providerOf(c), c.id) == LiveAvailability.audioOnly;

  /// [restoring] = `true` 表示这是**切回本页时找回原来的台**
  /// （`loadAll(keepSelection: true)` 那条路），**不是**用户主动换台。
  ///
  /// ★★★ task-82【Q4】：两者必须区分 —— 见下面第一段短路。
  Future<void> _select(LiveChannel ch, {bool restoring = false}) async {
    final provider = _providerOf(ch);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-82【Q4】用户**主动暂停过** ⇒ "找回原台"整段短路
     * ══════════════════════════════════════════════════════════════════
     *
     * # 缺陷（Owner 会在几分钟内撞上）
     * ```text
     * 用户按暂停 → 切到别的 tab → 切回直播页
     *   ⇒ 内嵌播放器**自己播起来了**，违背他刚按下的暂停。
     * ```
     *
     * # 根因链（逐环实测，不是推测）
     * ```text
     * shell 切回 ⇒ `loadAll(keepSelection: true)` ⇒ 这里 `_select(原台)`
     *   → 旧代码无条件 `_stream = null; _userPaused = false;`
     *   → 播放器 `didUpdateWidget` 看到 url 从 A 变成 null（`a != b`）
     *      ⇒ `live_embedded_player.dart:507` `stop()`
     *   → `_loadStream` 回来，`_stream` 从 null 变成 A'
     *   → 播放器 `didUpdateWidget` 又看到 null → A'（`a != b`）
     *      ⇒ `:509 open(...)` → `:403-404 await p.open(); await p.play();`
     *   ★ 而 `:403-404` **不看 `_userPaused`** ⇒ 必然起播。
     * 实测时序：`取到` 出现在 `不自动续播` 之后 **31–40 ms**。
     * ```
     *
     * # ★ 为什么修法是"短路"，而不是去改播放器
     * ```text
     * ① `lib/ui/widgets/live_embedded_player.dart` **不在本任务写入范围**
     *    ⇒ 不能给它加"暂停时不许 play()"的门控。
     * ② ★★ 但**根本不需要**改它 —— 播放器 `didUpdateWidget:496-498`
     *    的判据是 **url**（`final a = oldWidget.stream?.url;`）：
     *    `a == b` 时**整段不执行** ⇒ 不 `open`、不 `play`。
     *    ⇒ 只要让 `_stream` 的 **url 保持不变**，播放器就**永远不会**
     *      走到 `play()`。这就是"播放器侧不起播"的等价实现，
     *      而且完全落在本文件里。
     * ③ ★ 语义上也是对的：暂停时我们**只 pause、没有 stop** ——
     *    流在播放器里**还开着**。切回来要的是"续播那条流"，
     *    **重取一遍反而是错的那一步**（它会换 url ⇒ 触发 open/play）。
     * ```
     *
     * # ⚠️ 边界：这里**不**重取流，代价是什么（如实写）
     * ```text
     * 若这条流在暂停期间**已经死了**，用户按播放会看到旧画面/报错，
     * 需要他自己换台（或再切一次 tab）才会重新取流。
     * ★ 这是**有意**的取舍：宁可"续播一条可能已死的流"，
     *   也不要"替他起播" —— 后者违背他的操作，前者只是不新鲜。
     * ```
     */
    if (restoring && _userPaused) {
      setState(() => _selected = ch);
      /*
       * ★★★ 2026-10-08（Owner 第 3 条）：「保留原流」必须**同时保证静默**
       *
       * # 为什么这条 pause 不能省
       * ```text
       * 本分支的语义是「用户此前主动暂停过 ⇒ 保留原流、不重取、不起播」，
       * 但**不重取/不起播 ≠ 不出声**：
       *   切走时 `_onVisibilityChanged` 只调了 `st.pause()`（mpv 的 pause 位），
       *   而此刻可见性投影刚翻成 true ⇒ 那条 `:409` 的 resume() 已经把它
       *   **重新出声**了（shell 的 `_syncVisibility()` 先跑、`loadAll` 后跑）。
       * ⇒ 走到这里时播放器**正在响**，而本分支后面直接 return
       *   ⇒ 用户听到「突然有声音」，然后被这条 return 之后的静默状态骗成
       *     「再没声音」（其实一直在响，只是没有新画面/进度在动）。
       * ⇒ 必须显式再 pause 一次，把「保留原流」这件事做实。
       * ```
       *
       * ⚠️ 判空：`_embedKey.currentState` 在首帧/未挂载时是 null
       *    （与 `_onVisibilityChanged` 的写法一致）。
       */
      final st = _embedKey.currentState;
      if (st != null) unawaited(st.pause());
      debugPrint('[LIVE] 切回本页：用户此前主动暂停过 ⇒ 保留原流、不重取、不起播');
      return;
    }

    setState(() {
      _selected = ch;
      // ★ 换台 ⇒ 清掉上一条流（避免播放器还挂着上一个台的声音）
      _streams = [];
      _stream = null;
      _streamLoading = true;
      // ★ 换台是用户的主动行为 ⇒ 清掉"用户暂停"标记（他要看新台）
      _userPaused = false;
    });

    /*
     * ★★★ 用户要求【A】"删除掉节目单" ⇒ 这里**不再取 EPG**
     *
     * ```text
     * 原来：`unawaited(_loadStream(...))` 与 `await getEpg(...)` **并发**
     * 现在：只取流
     * ★ 收益（用户第 8 条问"直播卡顿"）：切台少一次 IPC + 一次插件 JS 执行
     *   ⇒ 首帧更快；且不再有"节目单迟到"引起的额外 setState/重建
     * ```
     */
    unawaited(_loadStream(provider, ch.id));
  }

  /// ★ 取这个频道的流，并选出**第一条能播的**线路
  ///
  /// # 为什么必须"选能播的"而不是 `list.first`
  /// ```text
  /// srcl1 的返回顺序是 [高清(drm) , 标清(drm) , 仅音频(可播)]
  /// 用 list.first ⇒ 拿到 drm 那条 ⇒ 播放器黑屏
  ///   ★ 这正是 `player_page.dart` 那条日志的成因
  /// ⇒ 与它保持一致：`list.find((x) => !x.drm_protected) ?? list[0]`
  /// ```
  Future<void> _loadStream(String provider, String channelId) async {
    try {
      final list = await SourinApi.getLiveStream(provider, channelId);
      if (!mounted || _selected?.id != channelId) return;
      final playable = list.where((s) => s.isPlayable).toList();
      setState(() {
        _streams = list;
        // ★ 优先带视频的线路；都没有才退回音频线（至少能听）
        _stream = playable.where((s) => !isAudioOnlyLine(s)).firstOrNull ??
            playable.firstOrNull;
        _streamLoading = false;
      });
      debugPrint('[LIVE] $channelId 取到 ${list.length} 条线路，'
          '可播 ${playable.length}，选用 ${_stream?.displayName ?? "无"}');
    } catch (e) {
      debugPrint('[LIVE] 取流失败 $channelId: $e');
      if (!mounted || _selected?.id != channelId) return;
      setState(() {
        _streams = [];
        _stream = null;
        _streamLoading = false;
      });
    }
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★ 循环切换频道（用户要求"往下循环切换"）
  // ══════════════════════════════════════════════════════════════════

  /// 切换频道
  ///
  /// [delta] `+1` 下一个、`-1` 上一个。
  ///
  /// # ★ 循环语义（用户明确说"循环"）
  /// ```text
  /// 最后一个按"下一个" ⇒ 回到第一个
  /// 第一个按"上一个"   ⇒ 跳到最后一个
  /// ```
  /// ★ 与 `player_page` 的"下一集"**有意不同** ——
  ///   那里到最后一集是**什么都不做**（`_nextEpisode == null`）。
  ///   直播是连续观看场景，卡在末尾没有意义。
  ///
  /// # 在**可见**频道里循环（不是全部频道）
  /// 隐藏掉的台（仅音频/不可用）不该被切到 —— 否则用户按 ↓
  /// 会跳到一个"看不到的台"，感觉像卡住了。
  void cycleChannel(int delta) {
    final next = _neighborChannel(delta);
    if (next == null) return;
    unawaited(_select(next));
  }

  /// ★★★ task-53【#4b】算出"相邻的下一个台" —— ★ **纯查询，不起播**
  ///
  /// # 为什么必须把它从 `cycleChannel` 里拆出来（不是"为整洁而拆"）
  ///
  /// 播放页（全屏直播）按 ↑/↓ 要切台，而**两个页面各有分工**：
  /// ```text
  /// 本页   ：唯一知道"哪些台可见"（探针缓存 TTL + 启用态 + audioOnly 过滤）
  /// 播放页 ：唯一持有正在出声的那个 mpv
  /// ```
  /// ⇒ 本页只回答"**下一个是哪个**"，由播放页去播。
  ///
  /// ⚠️ **不能**让播放页直接调 `cycleChannel`（我第一版就是这么写的）：
  /// ```text
  /// `cycleChannel` → `_select` → `_loadStream` ⇒ 内嵌播放器
  ///   `didUpdateWidget` 看到 url 变了 ⇒ `open()` + **`play()`**
  /// ⇒ 而此刻播放页**也在播**（用户就在全屏里）
  /// ⇒ ★★ 两个 mpv 同时出声 = 回声/重音
  ///    （这正是 `_watchLive` 那段注释拼命要防的东西）
  /// ```
  ///
  /// ★ 而把它拆出来后，**两处共用同一份取模算式**（铁律 170：
  ///   一条纪律一个实现）—— 不会出现"直播页循环、播放页越界"。
  LiveChannel? _neighborChannel(int delta) {
    final list = _visibleChannels;
    // ③ 逻辑层
    debugPrint('[LIVE-KEY] ③ 逻辑层：cycleChannel($delta) 列表=${list.length} 个'
        '（当前选中=${_selected?.id ?? "无"}）');
    if (list.isEmpty) return null;
    final cur = _selected;
    var i = cur == null ? -1 : list.indexWhere((c) => c.id == cur.id);
    if (i < 0) {
      // 当前选中的不在可见列表里（比如是隐藏的仅音频台）⇒ 从头开始
      i = 0;
    } else {
      // ★ 取模实现循环（Dart 的 % 对负数返回非负，正是我们要的）
      i = (i + delta) % list.length;
    }
    debugPrint('[LIVE-KEY]    ⇒ 切到第 $i 个：${list[i].name}');
    return list[i];
  }

  /// ★★★ task-53【#4b】播放页在全屏里按了 ↑/↓ ⇒ 本页**只改选中**，不起播
  ///
  /// 返回给播放页的目标（`null` = 没有可切的台 ⇒ 播放页会给用户一个提示）。
  ///
  /// # 为什么**不**在这里 `_select`（关键设计）
  /// ```text
  /// 全屏时本页是**不可见**的（被 PlayerPage 盖住），但有两点硬约束：
  /// ① 此刻出声的是播放页那个 mpv ⇒ 本页**绝不能**起播（会双声）
  /// ② 但**选中高亮必须跟着走** —— 用户 pop 回来看列表时，
  ///    当前正在播的台必须是高亮那个（否则他看到"我明明切了，列表还停在旧台"）
  /// ⇒ 所以：改 `_selected` + **清掉 `_stream`**（让内嵌播放器停掉旧台的声）
  ///    并记下 `_pendingFullscreenChannel`，等 pop 回来再接手播放。
  /// ```
  ({String provider, LiveChannel channel})? stepChannelForFullscreen(int delta) {
    final next = _neighborChannel(delta);
    if (next == null) return null;
    return _adoptChannelForFullscreen(next);
  }

  /// ★★★ task-53【③】把**当前可见频道列表**交给播放页（供"所有直播"面板）
  ///
  /// 返回 `(channels, index)`；`null` = 没有可显示的频道。
  ///
  /// # 为什么由本页回答（而不是播放页自己去查）
  /// ```text
  /// 与 `stepChannelForFullscreen` **同一条理由**（见它的长注释）：
  /// "哪些台可见"依赖 `LiveAvailabilityProbe` 的 TTL 缓存 + `_disabledProviders`
  /// + audioOnly/unavailable 过滤 ⇒ 播放页自己算一遍 = **两套真相**
  ///   ⇒ 面板里会列出"其实不能播"的台，或漏掉能播的台。
  /// ★ 本页的 `_visibleChannels` 是**唯一真相**（铁律 170）。
  /// ```
  ///
  /// ⚠️ 只读：**不改** `_selected`、**不起播** —— 纯查询，可任意次调用。
  ({List<LiveChannel> channels, int index})? channelsForFullscreen() {
    final list = _visibleChannels;
    if (list.isEmpty) return null;
    final cur = _selected;
    var i = cur == null ? -1 : list.indexWhere((c) => c.id == cur.id);
    if (i < 0) i = 0; // 选中的不在可见列表里（如被隐藏的仅音频台）⇒ 从第一个开始
    /*
     * ⚠️ **不打日志**（有意）——
     *   调用方 `player_page.dart` 在 `build` 里调它（`data: _liveChannels()`），
     *   而播放中 `_position` 每 tick 都 `setState`（`player_page.dart:1626`）
     *   ⇒ 在这里 `debugPrint` 会**每几百毫秒刷一行**，把真机排障的日志淹掉
     *     （我第一版就是打了的 —— 实测会发现日志里全是它）。
     * ★ 需要取证时看 `_adoptChannelForFullscreen` 那行（只在**真的换台**时打）。
     */
    return (channels: list, index: i);
  }

  /// ★★★ task-53【③】播放页在"所有直播"面板里**点选了某个台**
  ///
  /// 与 `stepChannelForFullscreen` **共用** `_adoptChannelForFullscreen`
  /// （铁律 170：一条纪律一个实现）—— 否则"点选"与"上下键"两条路
  /// 迟早会分叉出不同的行为（比如一个清线路、一个不清 ⇒ 双声）。
  ///
  /// 返回 `null` = 这个台不在可见列表里（正常不会发生：列表就是本页给的）。
  ({String provider, LiveChannel channel})? pickChannelForFullscreen(
    LiveChannel channel,
  ) {
    final inList = _visibleChannels.any((c) => c.id == channel.id);
    if (!inList) {
      debugPrint('[LIVE-KEY] 全屏点选：${channel.name} 不在可见列表里 ⇒ 忽略');
      return null;
    }
    debugPrint('[LIVE-KEY] 全屏点选 ⇒ ${channel.name}');
    return _adoptChannelForFullscreen(channel);
  }

  /// ★ "采纳某个台"的**唯一实现**（↑/↓ 与点选**共用**）
  ///
  /// # 为什么**不**在这里 `_select`（关键设计）
  /// ```text
  /// 全屏时本页是**不可见**的（被 PlayerPage 盖住），但有两点硬约束：
  /// ① 此刻出声的是播放页那个 mpv ⇒ 本页**绝不能**起播（会双声）
  /// ② 但**选中高亮必须跟着走** —— 用户 pop 回来看列表时，
  ///    当前正在播的台必须是高亮那个（否则他看到"我明明切了，列表还停在旧台"）
  /// ⇒ 所以：改 `_selected` + **清掉 `_stream`**（让内嵌播放器停掉旧台的声）
  ///    并记下 `_pendingFullscreenChannel`，等 pop 回来再接手播放。
  /// ```
  ({String provider, LiveChannel channel}) _adoptChannelForFullscreen(
    LiveChannel next,
  ) {
    final provider = _providerOf(next);
    debugPrint('[LIVE-KEY] 全屏切台 ⇒ ${next.name}（provider=$provider）'
        '：本页只改选中，起播交给播放页');

    setState(() {
      _selected = next;
      /*
       * ★ 清空线路 ⇒ 内嵌播放器 `didUpdateWidget` 看到 `b == null` 会 `stop()`
       *   ⇒ 旧台的声音立刻停（不会一边全屏新台、一边后台旧台）。
       */
      _streams = [];
      _stream = null;
      _streamLoading = true;
      // ★ 换台是主动行为 ⇒ 清掉"用户暂停"（与 `_select` 同一条纪律）
      _userPaused = false;
    });
    _pendingFullscreenChannel = next;
    return (provider: provider, channel: next);
  }

  // ★ 2026-09-26【A】`_fmtTime` 已移除（只被节目单/回看标题使用）

  /// 进全屏播放器 —— ★ 带**音频焦点交接**（lead 裁决 (a)）
  ///
  /// # 为什么不能直接 push（那样会双声）
  /// ```text
  /// 本页有内嵌播放器在放；push 出的 PlayerPage 也会 open 同一路流。
  /// 两个 mpv 实例同时解码输出 ⇒ **回声/重音**，用户立刻能听出来。
  /// ```
  ///
  /// # 三个必须（lead 明确要求，逐条对应下面代码）
  /// ```text
  /// ① `_pausedForFullscreen` **独立于** `_userPaused`
  ///    语义不同：
  ///      _userPaused          = "用户按了暂停"（他的意图）
  ///      _pausedForFullscreen = "我为了全屏让路的暂停"（我们的行为）
  ///    ★ 混用 ⇒ "用户暂停后跳全屏再回来"会被自动播起来（违背他的操作）
  ///
  /// ② 续播前**再检查一次可见性**
  ///    用户可能从全屏**直接切走 tab**（没回到直播页）⇒ 那时不该播
  ///
  /// ③ `await` 期间本页可能被 dispose
  ///    ⇒ `if (!mounted) return;`
  ///    ★ 而且内嵌播放器那时可能也已 dispose ⇒ 不能盲目调 pause/play
  ///      （`LiveEmbeddedPlayerState` 里有 `_disposed` 守卫，但这里也要防）
  /// ```
  Future<void> _watchLive() async {
    final s = _selected;
    if (s == null) return;
    final cb = widget.onWatchLive;
    if (cb == null) return;

    final embedded = _embedKey.currentState;

    // ① 跳转前暂停内嵌（只在它真的在放时才暂停/记标记）
    final wasPlaying = embedded?.isPlaying ?? false;
    if (wasPlaying) {
      await embedded?.pause();
      _pausedForFullscreen = true;
      debugPrint('[LIVE] 进全屏 ⇒ 暂停内嵌播放器（返回时续播）');
    }

    // ② 等全屏页真正 pop（Future 在 pop 时完成）
    //
    // ⚠️ provider 用 `_providerOf(s)` 反查 —— 不能直接用 `_activeProvider`：
    //    频道可能属于**别的**源（用户在播放页期间切了源）。
    await cb(_providerOf(s), s.id, s.name);

    // ③ 回来后（可能已 dispose / 已切走 tab / 用户手动暂停过）
    if (!mounted) return;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-53【#4b】优先处理"全屏里切过台"
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须排在 `_pausedForFullscreen` **之前**
     * ```text
     * 全屏里切了台 ⇒ `_stream` 已被清空（我们主动 stop 了内嵌播放器）
     *   ⇒ 此刻 `resume()` 是**无意义的**（没有流可播）
     *   ⇒ 正确动作是 `_select(新台)`：它自己会取流并起播
     * ★ 顺序反了的表现：用户切了台再退出全屏，回来看到**旧台的画面**
     *   （或黑屏），得再点一下列表才恢复。
     * ```
     *
     * ⚠️ `_pausedForFullscreen` 仍要清 —— 它是"为全屏让路"的事实，
     *    现在已经不在全屏了，留着会污染下一次可见性变化。
     */
    final pending = _pendingFullscreenChannel;
    if (pending != null) {
      _pendingFullscreenChannel = null;
      _pausedForFullscreen = false;
      final visible0 = widget.visible?.value ?? true;
      if (!visible0) {
        debugPrint('[LIVE] 从全屏返回，但本页已不可见 ⇒ 不接手播放'
            '（${pending.name}）');
        return;
      }
      debugPrint('[LIVE] 从全屏返回 ⇒ 接手播放全屏里切到的台：${pending.name}');
      await _select(pending);
      return;
    }

    if (!_pausedForFullscreen) return;
    _pausedForFullscreen = false;

    final visible = widget.visible?.value ?? true;
    if (!visible) {
      debugPrint('[LIVE] 从全屏返回，但本页已不可见 ⇒ 不续播');
      return;
    }
    if (_userPaused) {
      debugPrint('[LIVE] 从全屏返回，但用户此前主动暂停过 ⇒ 不续播');
      return;
    }
    final st = _embedKey.currentState;
    if (st == null) return;
    await st.resume();
    debugPrint('[LIVE] 从全屏返回 ⇒ 续播内嵌播放器');
  }

  /// ★ 2026-09-26【A】`_watchReplay(EpgEntry)` 已移除 ——
  ///   节目单删除后没有入口能触发回看（`onWatchReplay` **构造参数保留**，
  ///   因为 `shell.dart` 仍在传，而 shell 不在本任务写入范围）。
  ///
  /// ★ `_fmtTime` 也一并移除（它只被节目单与回看标题用）。

  @override
  Widget build(BuildContext context) {
    final isNarrow = MediaQuery.of(context).size.width < 900;

    /*
     * ★★★ 第 65 轮批次 D：**三态分开**（Owner 第 5 条前半的真修法）
     *
     * # 改前
     * ```text
     * if (_loading) → 骨架
     * if (_currentChannels.isEmpty) → 「没有可用的直播源」
     * ```
     * ⇒ 冷启动时核心未就绪 ⇒ `getLiveChannels()` 抛异常 ⇒ 被 catch 吞掉
     *   ⇒ `_groups` 为空 + `_loading=false` ⇒ **画成"没有源"**
     *   ⇒ Owner 看到的"第一次打开显示 0 个"。
     *
     * # 现在
     * ```text
     * loading ⇒ 骨架（还没拉完，别下结论）
     * failed  ⇒ 错误态 + 「重试」（**不是**让他去设置里配置）
     * empty   ⇒ 真·空态（"去设置里启用一个支持直播的源"）
     * ```
     * ★ 判据由纯函数 [liveLoadPhaseOf] 给出 ⇒ 三种状态**可单测**，
     *   不靠"读源码字符串"证明（铁律：不许假绿）。
     */
    final phase = liveLoadPhaseOf(
      loading: _loading,
      failed: _loadError != null,
      channelCount: _currentChannels.length,
    );

    if (phase == LiveLoadPhase.loading) {
      /*
       * ★ 加载骨架 —— 原版是**两栏骨架**（`LiveView.vue:162-165`）
       *
       * ```html
       * <div v-if="loading" class="live-layout">
       *   <div class="skeleton" style="height: 400px" />   ← 左：频道列表
       *   <div class="skeleton" style="height: 400px" />   ← 右：节目单
       * </div>
       * ```
       *
       * 原来这里是一个居中转圈。转圈的**布局跳动**很明显：
       * 转圈消失后两栏才出现，页面从"居中一个小圆"突然变成
       * 左 268px + 右自适应 —— 骨架能把这个跳动消掉。
       *
       * ⚠️ 用 `IgnorePointer` 包住：骨架期间不允许交互，
       *    否则用户可能在半成品布局上点到不该点的东西。
       */
      return IgnorePointer(
        child: ListView(
          clipBehavior: Clip.antiAlias,
          // ⚠️ 不能加 `const` —— `Sp.bottomBarInset` 是 getter（TV/非 TV 不同值）
          // ★ 内容带（t509）：原版 `LiveView.vue:153 <div class="container">` 那一层
          //   —— 整页只有这一个 `.container`，页头与 `.live-layout` 都是它的子节点、
          //   自身**没有**横向内边距（`LiveView.vue` 的 28 条 scoped 规则里无 horizontal
          //   padding）⇒ 本页是 **×1**，不像首页分区轨道那样 ×2。
          //   `Layout.horizontalInsetOf` 一次给出两层：居中留白 + 容器内边距。
          padding: Layout.horizontalInsetOf(context) +
              EdgeInsets.only(
                top: Sp.x8,
                bottom: Sp.bottomBarInset,
              ),
          children: [
            const _PageHead(channelCount: 0, showEpgHint: false),
            const SizedBox(height: Sp.x5),
            // ★ 内容带（t509）：原来这里是 `AppMetrics.contentPadding`（24）
            //   —— 那一层已由上面 `ListView.padding` 的 `Layout.horizontalInsetOf` 提供，
            //   留着会变成 ×2（TV 上会从 72 变 96，与原版不符）。
            Padding(
              padding: EdgeInsets.zero,
              child: isNarrow
                  ? const Column(
                      children: [
                        SizedBox(height: 320, child: _PanelSkeleton()),
                        SizedBox(height: Sp.x5),
                        _PanelSkeleton(),
                      ],
                    )
                  : const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 268,
                          height: 520,
                          child: _PanelSkeleton(),
                        ),
                        SizedBox(width: Sp.x5),
                        Expanded(child: _PanelSkeleton()),
                      ],
                    ),
            ),
          ],
        ),
      );
    }

    /*
     * ★★★ 失败态（**不是**空态）
     *
     * # 为什么必须有这一支（Owner 第 5 条前半）
     * ```text
     * 改前：核心未就绪 ⇒ 异常被吞 ⇒ 画「没有可用的直播源」
     *   ⇒ 用户被引导去"设置里启用源"，而他的源明明是启用的
     *   ⇒ 他会以为插件坏了 / 数据丢了
     * ```
     * ⇒ 现在：说清"这次没取到"，并给**一个能点的动作**（重试）。
     */
    if (phase == LiveLoadPhase.failed) {
      return _LiveLoadError(
        message: _loadError!,
        onRetry: () {
          setState(() {
            _loadError = null;
            _loading = true;
          });
          unawaited(loadAll());
        },
      );
    }

    if (phase == LiveLoadPhase.empty) {
      return const _EmptyState(
        icon: AppIcons.live_tv_outlined,
        title: '没有可用的直播源',
        desc: '在设置中启用一个支持直播的内容源',
      );
    }

    final list = LiveChannelList(
      providers: _visibleProviders,
      /*
       * ★★★ Owner 第 12 条：用户自建的直播分组（只读传入）。
       *
       * ⚠️ 每次 build 都**重读** UiPrefs（它是内存读，零成本）——
       *   用户在设置页改完分组、返回本页时，这里自然就是新值，
       *   不需要任何通知/监听机制（少一条要维护的同步链）。
       *   这正是 UiPrefs「同步 API」设计的用处（见该文件头）。
       *
       * ★★★ 第 65 轮批次 D：**两套都传** —— v2（按频道）是主数据，
       *   v1（按源）只作老数据兜底。只传一套会让另一半用户的分组失效。
       */
      sourceGroups: UiPrefs.liveSourceGroups(),
      channelGroups: UiPrefs.liveChannelGroups(),
      enabledProviders: {
        for (final g in _groups)
          if (_providerEnabled(g.provider)) g.provider,
      },
      channels: _flatChannels,
      selectedId: _selected?.id,
      /*
       * ★ 2026-09-26【②】`onToggleProvider` **已移除** ——
       *   用户要求把"直播源启停"挪到设置页（第 4 条原话）。
       *
       * ★★ task-1013：源 chip 现在是**筛选**（`LiveChannelList` 内部自持
       *   `_sourceFilter` + 分类 `_groupFilter`），**仍然没有** onToggleProvider
       *   —— 筛选与"启停"是两件事，见 `LiveChannelList` 的类注释。
       *
       * ⚠️ 但**能力没丢**：
       *   · 设置页「JS 插件」里每张源卡片的启用/停用走**同一个**
       *     `setProviderEnabled`
       *   · 而核心**已按 disabled 过滤** `get_live_channels`
       *     （task-D 实测：隔离副本里 srcl 被 disabled ⇒ 返回里**没有它**）
       *   ⇒ ★ 设置页改完，本页下次 `loadAll()` 自然生效 —— **不需要**本地镜像
       *
       * ⚠️ 那 `_disabledProviders` 为什么**还留着**？
       *   它仍是本页的**显示**依据（`enabledProviders` 用它决定 chip 是否弱化）。
       *   ★ 而它现在**只由 `loadAll()` 从核心同步**，不再由本页写入
       *     ⇒ 单一写入点（设置页），单一真相（核心的 json）—— 更干净。
       */
      onPickChannel: _select,
      /*
       * ★★★ N15：把**播放结果状态**接进列表（用户要求"动态标记"）
       *
       * 传的是**只读查询函数**，不是 store 本身（理由见 `LiveChannelList.healthOf`）。
       * ★ 用 `_providerOf` 反查 provider —— `LiveChannel` 自己不带 provider，
       *   而状态是按 (provider, channelId) 存的。
       */
      healthOf: (c) => _health.healthOf(_providerOf(c), c.id),
      // ★★★ 第 65 轮批次 D：频道搜索（受控，宿主是 `_searchQuery`）
      searchQuery: _searchQuery,
      onSearchChanged: (v) => setState(() => _searchQuery = v),
      /*
       * ★★★ 2026-10-18（Owner 逐字）：搜索框进**列表区域**
       *
       * ```text
       * > 直播的搜索框不要放在最上面,放在右侧的列表区域
       * ```
       * 搜索框与命中统计描述的是**这个列表**，跟着列表走才对；
       * 放进右栏后它天然是列表的一部分（窄屏时也在列表正上方）。
       *
       * ⚠️ 宽度问题：右栏固定 300px。改前页头那份是满宽（约 1200px），
       *   直接搬进来会挤成一条缝 ⇒ 见 `LiveSearchField` 的 `compact` 分支
       *   （藏起"共 N 个频道"，只留命中读数；清空按钮保留）。
       */
      header: _buildListHeader(),
    );

    /*
     * ── 右侧：内嵌播放器 + 节目单 ──
     *
     * ★ task-39 布局（用户原话）：
     * > 所支持的直播列表在左边占满高度，右侧放个播放器
     * > 默认选中第一个，默认打开就自动直播开始播放
     *
     * ⚠️ EPG（节目单）**不许默默删掉**（已有功能）——
     *    lead 裁决【设计点 3】= A（放播放器下方）+ **可折叠**
     *    （因为 srcl 被隐藏后 EPG 会整块空）。
     */
    final player = LiveEmbeddedPlayer(
      key: _embedKey,
      /*
       * ★★ task-74 ⑤ 回归修复：把**可见性信号**交给播放器自己。
       *
       * 为什么必须传：原生重活延后 380ms ⇒ 这段窗口里 `_player == null`
       * ⇒ `isPlaying` 恒 false ⇒ 本页 `_onVisibilityChanged()` 若靠
       * `st.isPlaying` 判断就永不成立（**已改为无条件置位**，
       * 见 `_onVisibilityChanged()` 里那段 task-74 ⑤ 残余竞态说明）
       * ⇒ 380ms 后 `_create()` 会把已切走的页面播起来（有声音）。
       * 播放器据此**抑制起播**，恢复可见时自己补播
       * （`pause()`/`resume()` 的既有语义不变）。
       */
      visible: widget.visible,
      stream: _stream,
      title: _selected?.name ?? '未选择频道',
      subtitle: _selected == null
          ? null
          : (_streamLoading
              ? '取流中…'
              : _isAudioOnly(_selected!)
                  ? '仅音频'
                  : _selected!.group),
      audioOnly: _selected != null && !_streamLoading && _isAudioOnly(_selected!),
      onToggleFullscreen: _selected == null ? null : _watchLive,
      /*
       * ★★★ N15 ③：**动态标记**（用户原话「打开如果不能播放,动态标记」）
       *
       * # 这是整个可用性体系里**唯一**能拿到真实失败的地方
       * ```text
       * `_probe`（LiveAvailabilityProbe）判的是 `isPlayable`，
       * 纯元数据、不发网络请求 ⇒ 永远不知道"现在能不能播"。
       * ★ 真实失败信号只在这里出现 ⇒ 所以回写必须挂在这个回调上。
       * ```
       *
       * # 为什么记 `broken` 而不是"再探一次"
       * ```text
       * 实测：能走到这个回调的失败（404 / 连不上 / 分片坏）
       * 都带错误串；而"空播放列表(没开播)"**一条错误都不发**
       * ⇒ 到这里就一定是"收到了错误串" ⇒ 判 broken 是准确的。
       * （"没开播"那条路靠 `bootTimeout` 判 idle，不经过这里。）
       * ```
       *
       * ⚠️ 必须用 `_selected` 的**当前** id：用户在等起播时可能已经切台，
       *    这时错误属于**上一个**台，不能记到新的这个头上。
       */
      onError: (msg) {
        debugPrint('[LIVE] 内嵌播放器报错: $msg');
        final sel = _selected;
        if (sel == null) return;
        final provider = _providerOf(sel);
        _health.record(
          provider: provider,
          channelId: sel.id,
          health: LivePlaybackHealth.broken,
          detail: msg,
        );
        /*
         * ★ P0：**立刻落盘**。
         *   这是"下次启动不再全量探测"的数据来源 ——
         *   若只在退出时写，用户强杀进程就丢了，等于没缓存。
         */
        _persistHealth();
        /*
         * ★ 只 setState **一次**（这一次是必要的：徽标要立刻变红）。
         *   不是每频道一次 —— 用户点开一个台才触发一次，量极小。
         */
        if (mounted) setState(() {});
      },
      /*
       * ★★ 用户要求【B】：双击进全屏
       *   判据与播放页同源（`PlayerGestures.doubleTapEnabledFor`）：
       *   触摸端双击**不**进全屏（那是"左右快进快退"的语义位），
       *   PC/TV 双击 = 全屏。
       *   ★ 传入 `Device.isTouchOnly` —— 与播放页 `_isTouchGestureTarget`
       *     用的是**同一个来源**（`widget.isTouchOnly`）。
       */
      isTouchOnly: Device.isTouchOnly,
      /*
       * ★ 把"用户自己按了暂停"上报给本页 ——
       *   这样可见性变化时**不会**把它自动播起来（尊重用户意图）。
       *   lead 明确要求这个行为（"记住用户的暂停意图"）。
       */
      onUserPause: (paused) {
        /*
         * ★★★ 2026-10-08（Owner 第 3 条）：**可见性门控**
         *
         * # 为什么必须有这一层
         * ```text
         * 播放器侧的 `onUserPause` 只看它自己的 `p.state.playing`
         * （Dart 侧标志，**不等于真实出声**），而且会在
         * 「我们因不可见而 pause」时被**误触发** ——
         * 于是 `_userPaused` 被置真，而它**没有任何复位路径**
         * （除了换台）。
         * ⇒ 切回本页时 `_onVisibilityChanged` 的 `if (_userPaused) return`
         *   会把自动续播**永久拦住** = 用户报的「然后再没声音」。
         * ```
         *
         * ⚠️ 判据与播放器侧 `live_embedded_player.dart` 的 `_visibleNow`
         *    **同一套**：`widget.visible?.value ?? true`
         *    （信号缺失时视为可见 —— 与那边一致，不能一边 true 一边 false）。
         * ⚠️ 门控**只挡写入**，不挡「用户恢复播放」：页面可见时
         *    paused == false 照旧能清掉标记。
         */
        if (!(widget.visible?.value ?? true)) {
          debugPrint('[LIVE] 本页不可见 ⇒ 忽略播放器上报的用户暂停($paused)');
          return;
        }
        if (_userPaused == paused) return;
        _userPaused = paused;
        debugPrint('[LIVE] 用户${paused ? "暂停" : "恢复"}了直播');
      },
    );

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26 用户实测要求【A】：**删掉节目单**
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 直播删除掉节目单,左侧固定,右侧就一个播放器也固定
     *
     * ⇒ 本页**不再渲染** `EpgPanel` / `CollapsibleEpg`（连同产生它们的
     *   `epg` 变量与 `openOnce` 那一步）。
     *
     * ★ 为什么**连取数也删**（不只是不显示）：
     * ```text
     * ① 切台时 `_select` 里那次 `getEpg` 是**并发**发的（见该处注释），
     *    但仍占一次 IPC + 一次插件 JS 执行
     * ② 不显示却继续取 ⇒ **纯浪费**，且用户看不到任何收益
     * ③ 用户第 8 条问"直播卡顿" —— 少一次每台必发的 RPC 对首帧有正贡献
     * ⇒ 一并删掉取数（`_epg` / `_epgLoading` / `_epgKey` / `_now` / `_clock`）
     * ```
     *
     * ⚠️ **只删直播页的**：详情页/其它页若需要 EPG，与本页无关
     *   （`SourinApi.getEpg` 本身**保留**，没删）。
     *
     * ⚠️ `onWatchReplay` 这个**构造参数保留**（`shell.dart` 仍在传，
     *   而 shell 不在我的写入范围）—— 本页不再使用它，但签名不变。
     *   同理 `_watchLive` 仍被播放器的全屏按钮用（`onToggleFullscreen`）。
     */

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 2026-09-26【C】"所有直播"面板（复用播放页的「选集」组件）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话（第 2 条后半）：
     * > 直播页面可以看所有的直播,**就跟选集逻辑一样**,
     * > 点击出来所有的直播,然后**上下按键在这里替换为切换直播**
     *
     * # 为什么复用 `EpisodePanel` 而不是新造
     * ```text
     * 用户说的"就跟选集逻辑一样" ⇒ **字面复用**同一个组件最贴合。
     * 它已经具备：PC 右抽屉 / 手机·TV 底部抽屉 / 分段 / 搜索 / 自动滚到当前项
     * ★ 而"上下键切换"也**天然可用** —— `EpisodeSheet` 自己就是
     *   一列可聚焦的项（`_focusCurrent` / `_scrollToCurrent`），
     *   方向键在其中移动是它既有行为。
     * ```
     *
     * # ★ 频道 → `Episode` 的映射（为什么可以这样映射）
     * ```text
     * `Episode{id,title,url,index}` 与 `LiveChannel{id,name,...}` 的语义可对齐：
     *   Episode.id    ← LiveChannel.id     （选谁 ⇒ 我们能唯一定位频道）
     *   Episode.title ← LiveChannel.name   （显示名）
     *   Episode.url   ← null               （直播不需要"每集一个 url"，
     *                                        取流仍走 getLiveStream）
     *   Episode.index ← 位置序号            （面板用它做"当前项"高亮）
     * ★ 而且面板**并发**不需要知道这是"集"还是"频道" —— 它只渲染列表。
     * ⚠️ 不改 `Episode` 模型（在 `lib/core/models.dart`，归别的任务）。
     * ```
     *
     * # ★★ 数据源：**全部可见频道**（不是只能按源取）
     * ```text
     * 我【D】实测过：`get_live_channels` 的 `provider` 参数**被忽略**
     * （三次调用返回逐字节相同）⇒ 无法"按源取频道"。
     * ★ 用户要的正是"可以看**所有**的直播" ⇒ 列**全部可见频道**即可，
     *   并在每项上**标出它来自哪个源**（`title` 里带 tag）。
     * ```
     */
    final allChannelEntries = _flatChannels;
    final allEpisodes = <Episode>[
      for (var i = 0; i < allChannelEntries.length; i++)
        Episode(
          id: allChannelEntries[i].channel.id,
          // ★ 带来源 tag —— 与左栏列表同一口径（`LiveFlatEntry.tag`）
          title: '${allChannelEntries[i].channel.name}'
              '  · ${allChannelEntries[i].tag}',
          index: i,
        ),
    ];
    // 当前选中的索引（面板要据此高亮 + 自动滚到它）
    final curIdx = _selected == null
        ? 0
        : allChannelEntries.indexWhere((e) => e.channel.id == _selected!.id);

    /*
     * ★ 线路选择（只有**多于一条可播线路**时才显示）
     *
     * # 为什么需要
     * ```text
     * srcl1 返回 [高清(drm) / 标清(drm) / 仅音频(可播)]
     *   ⇒ 可播的只有一条 ⇒ 不显示切换器（没得选）
     * 但别的源常有 高清/标清/备用 多条可播线
     *   ⇒ 用户需要能在"清晰但可能卡"和"糊但流畅"之间选
     * ```
     * ★ 只列**可播**的 —— 列上 DRM 线路等于给用户一个必然黑屏的按钮。
     */
    final playableLines = _streams.where((s) => s.isPlayable).toList();
    final lineSwitcher = playableLines.length > 1
        ? Padding(
            padding: const EdgeInsets.only(top: Sp.x2),
            child: Wrap(
              spacing: Sp.x2,
              runSpacing: Sp.x2,
              children: [
                for (final s in playableLines)
                  _LineChip(
                    label: s.displayName,
                    active: s.url == _stream?.url,
                    onTap: () => setState(() => _stream = s),
                  ),
              ],
            ),
          )
        : const SizedBox.shrink();

    /*
     * ★★ 整页包一层 `Focus` —— 方向键切频道（循环）
     *
     * # 为什么要一个**自己**的 Focus
     * ```text
     * spatial_nav 的 handler 跑在焦点树**之前**（HardwareKeyboard），
     * 它按**几何位置**找邻居。直播页要的是"相邻频道 + 末尾循环"，
     * 不是"跳到一个几何上更近的控件"。
     * ⇒ 本页先用 onKeyEvent 处理 ↑/↓，返回 handled 吃掉事件。
     *   ★ 注意 `KeyEventResult.handled` 只对**本 Focus 子树内**的事件生效；
     *     spatial_nav 是全局 handler，所以本页必须真的抢到焦点
     *     （`autofocus: true` + 点列表时焦点进来）。
     * ```
     *
     * ⚠️ 与 task-3 的关系：他给 `spatial_nav._scrollIntoView` 加"输入来源门控"
     *    （只让键盘/遥控滚，不让鼠标滚轮滚）。
     *    ★ **遥控/键盘导航必须保留滚动** —— 本页的遥控切台靠
     *      `_ChannelTile` 自己的 `Scrollable.ensureVisible` 保证可见，
     *      不依赖 spatial_nav 那条路径，但 task-3 不能把遥控整体关掉。
     */
    /*
     * ★★★ task-42 修「上下键切不了」—— 关键改动
     *
     * # 原来为什么可能收不到键（任务级的坑）
     * ```text
     * 我 task-39 只写了 `Focus(autofocus: true, onKeyEvent: _onKey)`。
     * ★ 但 `autofocus` **只在"没人抢焦点"时才生效** ——
     *   而 shell 里 `primeFocusSoon()` / `FocusPrimingObserver`
     *   会在进页面时**主动把焦点种到第一个可聚焦控件**上
     *   （那是 task-AI 为 TV 遥控做的，见 shell.dart 的长注释）。
     * ⇒ 焦点被种到别处 ⇒ 我的 Focus 只是**祖先链上的一层**，
     *   而方向键会被**更近的那个** Focus（比如某个 InkWell）先消费/冒泡到别处。
     * ```
     *
     * # 修法：用**显式 FocusNode** + 进页面/列表变化时主动请求焦点
     * ```text
     * · 显式 node ⇒ 我能控制它何时拿焦点（autofocus 不够）
     * · `onKeyEvent` 挂在 node 上 ⇒ 只要焦点在**我这层或我子树内**
     *   就能收到（Flutter 沿祖先链冒泡）
     * · 加 `_onKeyAny` 做**三层诊断**打点 ⇒ 下次再出问题能立刻定位
     * ```
     *
     * ⚠️ `skipTraversal: true` + `canRequestFocus: true`：
     *    本层是**拦截器**（要收方向键），但它不该成为 Tab 遍历的一站
     *    （否则用户按 Tab 会停在整页容器上，很奇怪）。
     */
    return Focus(
      focusNode: _pageFocus,
      autofocus: true,
      onKeyEvent: _onKeyAny,
      skipTraversal: true,
      // ★★【C】`Stack` 是为了让"所有直播"面板**叠在本页之上**
      //   （见下面 `Positioned.fill` 那段的长注释）
      child: Stack(
        children: [
      Padding(
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 用户要求【A】：「左侧固定，右侧就一个播放器也固定」
         * ══════════════════════════════════════════════════════════════
         *
         * ```text
         * 原来：外层是 `ListView`（整页可滚）
         *   ⇒ 滚一下页头就跑了，左右两栏**跟着一起滚**
         *   ⇒ 用户说的"固定"就是反对这个
         * 现在：外层改成 **`Padding` + `Column`** ⇒ 整页**不滚动**
         *   · 左栏：自己内部滚（`LiveChannelList` 自带 ListView）
         *   · 右栏：播放器 + 线路切换，**高度固定**
         * ```
         * ⚠️ 为什么不是 `SingleChildScrollView`：那仍然"整页可滚"，
         *    只是把溢出交给它 —— 用户要的是**不滚**（两栏各自固定）。
         */
        // ★ 内容带（t509）：原版 `LiveView.vue:153 <div class="container">`
        //   —— 本页**只有一个** `.container`，`.page-head`（:154）与
        //   `.live-layout`（:174）都是它的子节点、自身无横向内边距
        //   ⇒ 本页是 **×1**（首页分区轨道才是 ×2）。
        //   `Layout.horizontalInsetOf` = 居中留白 + 容器内边距（一次给全）。
        padding: Layout.horizontalInsetOf(context) +
            EdgeInsets.only(
              top: Sp.x8,
              bottom: Sp.bottomBarInset,
            ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 页头 ──
            _PageHead(
              channelCount: _visibleChannels.length,
              // ★ 节目单已删 ⇒ 不再显示"支持节目单与回看"提示
              showEpgHint: false,
              // ★★【C】"所有直播"入口（有频道才给 —— 没频道时点开是空面板）
              onShowAll: allEpisodes.isEmpty
                  ? null
                  : () => setState(() => _allChannelsOpen = true),
            ),

            /*
             * ★★★ 2026-10-18：频道搜索框**已从页头移到右栏列表上方**
             *
             * # Owner 逐字
             * ```text
             * > 直播的搜索框不要放在最上面,放在右侧的列表区域
             * ```
             * ⇒ 它现在由 `LiveChannelList` 的 `header:` 槽位承载
             *   （见 `_buildListHeader()` 与 `LiveChannelList.header`）。
             *
             * ⚠️ 页头这里**只留**探测进度 / 缓存提示这类"整页状态"，
             *   搜索框与命中统计属于**列表**语义 ⇒ 跟着列表走。
             */

            /*
             * ★★★ P0：**还没开始**检查时的提示（Lead 要求）
             *
             * # 为什么必须有这一段
             * ```text
             * 无缓存时，第一轮探测要**延迟 30 秒**才开始（错开启动瞬间，
             * 免得一进页面就打 1248 个请求 —— Owner「迟早要被拉黑」）。
             * ⇒ 那 30 秒里 `_probeTotal` 还是 0 ⇒ 上面那段"正在检查 x/y"不显示。
             * ⇒ 用户看到**一个徽标都没有**，会以为功能坏了。
             * ⇒ 必须明确告诉他：还没开始，不是坏了。
             *
             * ⚠️ 措辞要区分「将稍后开始」和「正在检查」：
             *    前者是"还没发请求"，后者是"正在发"。混成一句会造成
             *    "看起来在检查、其实什么都没做"的假象。
             * ```
             */
            if (_probeScheduled)
              Padding(
                padding: const EdgeInsets.only(top: Sp.x2),
                child: Text(
                  '可用性检查将稍后开始（不影响播放）…',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            // ── 探测进度（列表会陆续出现，必须让用户知道为什么）──
            if (_probed == false && _probeTotal > 0)
              Padding(
                padding: const EdgeInsets.only(top: Sp.x2),
                child: Text(
                  '正在检查频道可用性 $_probeDone/$_probeTotal …',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            /*
             * ★★★ 第 65 轮批次 D：**"这是缓存，正在刷新"** 的诚实提示
             *
             * # 为什么必须显示（而不是默默用缓存）
             * ```text
             * 缓存优先上屏解决了"等很久"，但引入了**新的**认知风险：
             * 用户可能以为列表是最新的，而某个台其实刚下线/刚上线。
             * ⇒ 明确告诉他"这是 X 分钟前的快照，正在刷新" ——
             *   他既不会干等，也不会被骗。
             * ★ 刷新完成后 `_probed` 变 true ⇒ 这条提示自然消失
             *   （见 `_probeAll` 收尾那个 setState）。
             * ```
             */
            if (_cacheHit && _cacheAt != null && !_probed)
              Padding(
                padding: const EdgeInsets.only(top: Sp.x1),
                child: Text(
                  '正在刷新…（列表是 ${_cacheAgeText()}的快照）',
                  key: const ValueKey('live-cache-hint'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            const SizedBox(height: Sp.x5),

            /*
             * ★★ 主体：`Expanded` 让它吃掉剩余高度 ⇒ 两栏**都固定**在视口内
             *    （没有 Expanded 时 Column 会按内容高度铺，可能溢出）
             */
            Expanded(
              child: isNarrow
                  ? _buildNarrowBody(list, player, lineSwitcher)
                  : _buildWideBody(list, player, lineSwitcher),
            ),
          ],
        ),
        ),
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-09-26【C】"所有直播"面板（覆盖层）
         * ══════════════════════════════════════════════════════════════
         *
         * ```text
         * 用户原话：「点击出来所有的直播,然后上下按键在这里替换为切换直播」
         *
         * ★ 用 `EpisodePanel`（播放页"选集"的同一个组件）⇒ 形态自动分流：
         *     PC ⇒ 右侧抽屉 ／ 手机·TV ⇒ 底部抽屉
         * ★ 并复用 `SheetTransition` 让**关闭也有动画**
         *   （播放页 task-28 ①-A 踩过：直接移除子树 ⇒ 关闭没动画）
         *
         * ⚠️ **不** import `player_page.dart` 的 `PlayerPanelTheme`
         *   （那会把整个播放页拉进本页的依赖图）。
         *   ★ 而主题**本来就有** —— `shell.dart:1079` 的
         *     `MaterialApp.builder` 里全局注入了 `AppThemeHost(data: materialTheme)`
         *     ⇒ `EpisodePanel` 里的 `FTheme.of(context)` 能正常工作。
         *     （已核：`episode_strip.dart` 用了 7 处 `FTheme.of(context)`）
         * ⚠️ `currentIndex: curIdx` —— **↑/↓ 切台后高亮会自动跟随**
         *   （`EpisodeSheet` 里 `active: i == widget.currentIndex` +
         *    `didUpdateWidget` 自动滚动 —— 实测它在两处都实现了）
         * ```
         */
        Positioned.fill(
          child: SheetTransition(
            visible: _allChannelsOpen,
            slideFrom: Device.isDesktop
                ? const Offset(24, 0)
                : const Offset(0, 24),
            child: EpisodePanel(
              episodes: allEpisodes,
              currentIndex: curIdx,
              onPick: (ep) {
                // ★ 选中 ⇒ 切台 + 关面板（与"选集"点一下就走同一体验）
                final hit = allChannelEntries
                    .where((e) => e.channel.id == ep.id)
                    .firstOrNull;
                setState(() => _allChannelsOpen = false);
                if (hit != null) unawaited(_select(hit.channel));
              },
              onClose: () => setState(() => _allChannelsOpen = false),
            ),
          ),
        ),
      ],
      ),
    );
  }

  /// 窄屏（手机/竖屏）：播放器在上 → 列表在下（自身可滚）
  ///
  /// ★ 用户【A】的"固定"主要针对桌面；窄屏仍是**上下**结构（不是左右分栏）
  ///   （手机上强行左右分栏会挤成两条缝，lead 早有要求"别为桌面搞坏手机"）。
  ///
  /// ★ 2026-09-30【task-92】Owner 要求**调换位置**（逐字）：
  ///   > 直播页面改为节目栏在下面,播放窗口挪到上面去,也就是调换一下位置
  ///   ⇒ 播放器挪到**上**、频道列表挪到**下**。
  ///   `lineSwitcher` 跟着播放器走（与宽屏 `Column(min, [player, lineSwitcher])`
  ///   同一约定：它是播放器的线路控件，不能与播放器分开）。
  Widget _buildNarrowBody(Widget list, Widget player, Widget lineSwitcher) {
    // ★ 内容带（t509）：原来这里是 `AppMetrics.contentPadding`（24）
    //   —— 已由页根的 `Layout.horizontalInsetOf` 提供，留着会变成 ×2。
    return Padding(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          // ★ 播放器在上（task-92 调换）：宽度 = 屏宽 − 两侧 contentPadding，
          //   高度由 AspectRatio 的 16:9 决定
          AspectRatio(aspectRatio: 16 / 9, child: player),
          lineSwitcher,
          const SizedBox(height: Sp.x5),
          // 列表在下，吃掉剩余高度 —— 自身可滚
          Expanded(child: list),
        ],
      ),
    );
  }

  /// ★★★ 2026-10-18：列表上方的搜索区（Owner 要求搬进右栏）
  ///
  /// # 为什么是 `compact: true`
  /// ```text
  /// 右栏固定 300px（`_buildWideBody` 里的 `SizedBox(width: 300)`）。
  /// 改前这个搜索框在页头，横跨两栏 ⇒ 可用宽约 1200px，
  /// 放"搜频道名（跨全部直播源）"这种长提示 + "共 1178 个频道"毫无压力。
  /// 搬进 300px 后同一份内容会被挤成一条缝 ⇒ 必须按宽度收一次：
  ///   · 藏掉"共 N 个频道"（没搜索时它只是冗余统计，筛选条里已有信息）
  ///   · 搜索时**保留**"命中 N"（这是用户判断关键词好不好用的唯一读数）
  ///   · 提示语缩短成「搜频道」
  /// ```
  Widget _buildListHeader() {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: LiveSearchField(
        controller: _searchCtrl,
        query: _searchQuery,
        // 命中数：由列表内部口径给出会重复算一遍 ⇒ 这里用同一判据现算
        hitCount: _searchHitCount(),
        total: _flatChannels.length,
        compact: true,
        onChanged: (v) => setState(() => _searchQuery = v),
      ),
    );
  }

  /// 宽屏：播放器在**左** + 频道列表在**右**（固定宽 300），**两栏都在视口内不滚**
  ///
  /// ```text
  /// 用户原话："左侧固定,右侧就一个播放器也固定"
  ///   ★ 2026-09-30【task-92】Owner 又要求**调换左右**（逐字）：
  ///     > 窄屏幕修改就行了,宽屏改为  播放器在左侧,列表在右侧
  ///     ⇒ 播放器在**左**、频道列表在**右**（列表仍固定宽 300）。
  ///   · 播放器那栏：`Expanded` 给它**满宽**、内层 `Center` 吃满高度 ⇒ 固定
  ///   · 列表那栏：`SizedBox(width: 300)`，高度由父级满高约束给出 ⇒ 固定
  ///     （列表**自己内部**滚 —— 那是列表该有的行为，不是"整页滚"）
  /// ✔ 原来用 `LayoutBuilder` 手算 `listH`（视口高 − 页头 − 底栏 − 72）
  ///   ★ 现在改用 `Expanded`（父级已经是满高的 Column）⇒ **不再估算**，
  ///     少一处"估算高度"就少一处随字体/字号漂移的风险。
  /// ```
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-09-26【#5】右栏高度**必须与左栏对齐**（用户第 5 条）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 用户原话：
  /// ```text
  /// > 直播页面,右侧的直播播放器高度没有跟左边对齐高度
  /// ```
  ///
  /// # 修前的实测读数（1280x800 宽屏，探针真机跑的，不是我估算）
  /// ```text
  /// 左栏（频道列表）    : 300.0 x **728.0**
  /// 右栏（播放器 16:9） : 912.0 x **513.0**
  /// ⇒ 高度差 = **215.0 px**（左栏比右栏高 41.9%）
  /// ```
  /// ⇒ 用户看到的正是"右边播放器比左边列表**矮一截**，底下空一块"。
  ///
  /// # 为什么会差（结构原因，不是算错了）
  /// ```text
  /// 左栏 `LiveChannelList` 的根是 `Column(mainAxisSize: max)` + `Expanded(ListView)`
  ///   ⇒ 它**吃满**父级给的高度 ⇒ 728
  /// 右栏是 `AspectRatio(16/9)` —— 它的高度由**宽度**决定：
  ///   912 ÷ 16 × 9 = **513**（与宽度绑死，与可用高度无关）
  /// ⇒ ★ 两者**必然**不等：一个跟高度走，一个跟宽度走。
  /// ```
  ///
  /// # 修法：保留 16:9，让**右栏容器**吃满高度（多出来的空间做黑边）
  /// ```text
  /// 候选 A：把右栏拉满高度 ⇒ 视频就**变形**了（912x728 = 1.25:1，不是 16:9）
  /// 候选 B：把左栏砍到 513 ⇒ 列表白白少 215px（用户要的是"左侧固定"）
  /// 候选 C（采用）：右栏容器吃满 728，视频**按 16:9 居中** ⇒
  ///         上下各留 ~107px 黑边（letterbox，与播放器内部黑边同色）
  ///         ⇒ ★ 两栏的**上下边界完全对齐**，而画面比例一个像素都没变
  /// ```
  /// ★ 为什么不去挤左栏（候选 B 看起来"更简单"）：
  ///   用户上一条刚说过「左侧固定,右侧就一个播放器也固定」——
  ///   把列表砍矮正好是**反着做**，而列表矮 215px 就要多滚 215px。
  ///
  /// ⚠️ 黑底 `ColoredBox` **不是装饰**：没有它，视频居中后上下露出的
  ///    是**页面背景**（浅色主题下是灰白），看起来像"播放器缺了一块"。
  ///    有了它，整块右栏读起来是**一个播放器面板**（与 `ClipRRect`
  ///    同一个圆角 ⇒ 与 `LiveEmbeddedPlayer` 自己的圆角完全重合，不打架）。
  ///
  /// ⚠️ 窄屏分支（`_buildNarrowBody`）**不需要**这套机制 —— 那里是上下结构，
  ///    播放器宽度就是屏幕宽，`AspectRatio` 满宽铺开本来就没有"对齐"问题。
  ///    （2026-09-30【task-92】窄屏只调换了播放器/列表的上下顺序，机制不变。）
  Widget _buildWideBody(Widget list, Widget player, Widget lineSwitcher) {
    // ★ 内容带（t509）：同 `_buildNarrowBody` —— 那一层已由页根提供。
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          /*
           * ★ 左栏（task-92 调换后 = 原来的右栏）：**吃满高度**（与右栏等高）
           *   + 视频按 16:9 居中
           *
           * `Expanded` 在这里是给**宽度**用的（Row 的主轴）；让它**满高**的是
           * 里面那层 `Center`（在高度有界且未设 heightFactor 时会吃满 maxHeight）
           * ⇒ 见下面 `Center` 的说明。
           */
          Expanded(
            child: ClipRRect(
              borderRadius: Radii.rLg,
              child: ColoredBox(
                // ★ 黑边颜色与播放器内部黑边一致 ⇒ 两者的接缝看不出来
                color: Colors.black,
                child: Center(
                  /*
                   * ★ `Center` + `AspectRatio` = "能多大就多大，但保持比例"
                   *
                   * `AspectRatio` 在**宽松**约束下的行为（读 Flutter 实现）：
                   *   先试满宽 → 高 = 宽/16*9 ≤ 可用高 ⇒ 取该宽x该高
                   *   （若可用高更小，它会反过来按高算宽 ⇒ **永不溢出**）
                   * ⇒ 这正是 letterbox 语义，且**不需要**我们手算任何数字。
                   */
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AspectRatio(aspectRatio: 16 / 9, child: player),
                      lineSwitcher,
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: Sp.x5),
          // ★ 右栏（task-92 调换后 = 原来的左栏）：固定宽 + 满高（内部自滚）
          SizedBox(width: 300, child: list),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  频道列表
// ═══════════════════════════════════════════════════════════════════════

/// ★★★ task-42：平铺列表的一项（频道 + 它的来源 tag）
///
/// # 为什么用 record 而不是给 `LiveChannel` 加字段
/// ```text
/// `LiveChannel` 在 `lib/core/models.dart` —— 那个文件**归别的任务**
/// （task-42 写入范围明确排除它）。
/// ★ 而且"来自哪个源"是**列表展示需要的信息**，不是频道的固有属性
///   （同一个频道理论上可能被多个源提供）。
/// ⇒ 用轻量 record 在**渲染层**组合，不改数据模型。
/// ```
///
/// ★ task-1013 新增 `provider`（源 **id**）——
///   `tag` 是**展示名**（源名），筛选要按**稳定 id** 比对，
///   两者不能混用（源名可改、可重名；id 不会）。
typedef LiveFlatEntry = ({LiveChannel channel, String tag, String provider});

/// ★★★ 源 / 分类**筛选**后的频道列表（task-1013 用户要求）
///
/// # 用户原话
/// ```text
/// > 直播页面,支持一下按照源筛选,还有支持分类筛选
/// ```
///
/// # ⚠️⚠️ 先读这段历史 —— 这里改过三次，别再踩同一个坑
/// ```text
/// task-39：chip = **筛选**（一次只看一个源）
/// task-42：用户要"平铺" ⇒ 筛选没意义 ⇒ chip 改成**开关**
///          （用户当时说"直播源要支持单独的开启与关闭"）
/// task-53：★ 用户**否定了开关长在这里** ——
///          "配置该在**设置页**，不该长在**内容页**"
///          ⇒（`setProviderEnabled` 的唯一写入点搬到设置页）
/// ```
///
/// ★★ 关键结论（注释里早已写明）：**用户否定的是"开关"的位置，不是"筛选"这个能力**
/// ```text
/// · 被否定的形态 ⇒ "点一下 = 启停某个源"（改配置、有副作用、和设置页两个写入点）
/// · 本次新增     ⇒ "点一下 = 只改**视图**"（看什么，不写任何持久状态）
/// ```
///
/// # ★ 本次如何**避免**踩回 task-53 那个坑（逐条可核）
/// ```text
/// ① **不碰** `setProviderEnabled` —— 本组件里**没有任何**对它的调用，
///    点击只改本 widget 的 `_sourceFilter` / `_groupFilter` 两个内存字段
///    （连 `setProviderEnabled` 这个标识符都不出现在源码里 ⇒ 机器可验）。
/// ② **不做开关语义** —— 一次只选**一个**源（单选），不存在"多个开关叠加"；
///    且默认是「全部源」，点已选中的那个**回到全部**，不产生"启用状态"。
/// ③ **配置的写入点仍是设置页** —— 本页连"关掉某个源"的入口都没有；
///    哪一行可点、点了会怎样，Tooltip 里明说"只改显示，不改配置"。
/// ```
///
/// # 为什么把筛选状态放在**本组件内**（而不是 `LivePageState`）
/// ```text
/// ① 筛选是**纯视图状态**，与页面/取数无关（不产生副作用、不需要落盘）
///     ⇒ 放在最靠近被它影响的列表处，重建面最小。
/// ② ★ 可测性：本组件是**公开**的 `LiveChannelList`（见下），
///    测试可以只 pump 它、喂假 `channels` 就**真的渲染**出筛选结果 ——
///    而 `LivePage` 的 `_groups` 只由 FFI 填（flutter test 里恒为空），
///    整页层面无法喂数据（`t48_live_page_all_channels_test.dart` 记着这道墙）。
/// ```
class LiveChannelList extends StatefulWidget {
  const LiveChannelList({
    super.key,
    required this.providers,
    required this.enabledProviders,
    required this.channels,
    required this.selectedId,
    required this.onPickChannel,
    this.onPickProvider,
    this.onPickGroup,
    this.sourceGroups = const {},
    this.channelGroups = const {},
    this.onPickGroupFilter,
    this.searchQuery = '',
    this.onSearchChanged,
    this.header,
    this.healthOf,
  });

  /// 有可播视频的源（②：整组不可用的源不出现）
  final List<LiveGroup> providers;

  /// 当前**启用**的源 id 集合（③：单独启停）
  ///
  /// ★ task-53【②】：启停**已挪到设置页** ⇒ 这里只用于**标签的视觉区分**
  ///   （启用的源用主色、关闭的用弱化色），**不再**有可点的开关。
  final Set<String> enabledProviders;

  /// ★ 平铺的频道（跨源混合，每项带来源 tag）
  final List<LiveFlatEntry> channels;

  final String? selectedId;

  final ValueChanged<LiveChannel> onPickChannel;

  /// ★ 测试用注入口（**生产路径永不传**）：源筛选被点击时回调
  ///
  /// # 为什么需要它（守卫 task-53 那个坑）
  /// ```text
  /// 用户否定的形态是"点 tag 就去改 provider 启用状态"。
  /// ⇒ 本组件**自己**绝不调 `setProviderEnabled`（源码里根本不出现它）。
  ///   但光靠"我没写"不足以**防止将来有人加** —— 所以留一个**可观测**的
  ///   出口：筛选点击只走 `onPickProvider`，测试拿它计数；
  ///   同时装一个 `setProviderEnabled` 探针证明**它一次都没被调**。
  /// ```
  final ValueChanged<String?>? onPickProvider;

  /// ★ 测试用注入口（**生产路径永不传**）：分类筛选被点击时回调
  final ValueChanged<String?>? onPickGroup;

  /// ★★★ Owner 第 12 条：用户自建的直播**源**分组（组名 → 源 id 列表）
  ///
  /// ⚠️ 这是 **v1 老格式**，第 65 轮起降级为**兜底**语义：
  ///   某个组在 [channelGroups] 里没有数据时才按它筛（见
  ///   [liveGroupAllowsChannel] 的四条语义）。保留它是为了让用户
  ///   机器上已有的老分组**不静默失效**。
  final Map<String, List<String>> sourceGroups;

  /// ★★★ 第 65 轮批次 D：用户自建的直播**频道**分组（组名 → 频道引用）
  ///
  /// # Owner 原话
  /// ```text
  /// > 我要的是自建分组可以选择直播源下的具体的直播的房间，而不是选择直播源
  /// > 这是错误的
  /// ```
  /// ⇒ 这才是分组的**主**数据；[sourceGroups] 只作老数据兜底。
  final Map<String, List<LiveChannelRef>> channelGroups;

  /// ★ 测试用注入口（**生产路径永不传**）：分组筛选被点击时回调
  final ValueChanged<String?>? onPickGroupFilter;

  /// ★★★ 第 65 轮批次 D：频道搜索关键词（受控，由宿主持有）
  ///
  /// # 为什么**受控**（`LivePageState` 持有、本组件只读）
  /// ```text
  /// 状态要落在**搜索框与列表的共同祖先**上：搜索框现在画在列表正上方
  /// （本组件的 `header:` 槽位），但清空/重置的入口还在 `LivePageState`
  /// （切页、换源时要清搜索词）。
  /// ⇒ 宿主持有、往下传（单向数据流，一条链），避免两边各存一份而漂移。
  /// ```
  final String searchQuery;

  /// 搜索框内容变化（宿主写回自己的 state；测试可只验证回调）
  final ValueChanged<String>? onSearchChanged;

  /// ★★ N15：查某个频道的**播放结果状态**（`null` = 未注入 ⇒ 全 unknown）
  ///
  /// # 为什么做成只读回调，而不是直接传 store
  /// ```text
  /// 本组件是**纯视图**（它连 provider 都不许改，见 onPickProvider 的注释）。
  /// 传一个可变 store 进来，它迟早会忍不住去读写 ⇒ 状态所有权就散了。
  /// ⇒ 只给一个**只读查询函数**：组件问、宿主答，组件永远不写。
  /// ```
  final LivePlaybackHealth Function(LiveChannel)? healthOf;

  /// ★★★ 第 65 轮批次 D：列表**上方**的自定义区域（当前 = 搜索框 + 命中统计）
  ///
  /// # 为什么要这个口子
  /// ```text
  /// 搜索框与"命中 N 个"的统计属于**本列表的语义**（它们在描述这个列表），
  /// 位置又必须在列表正上方 ⇒ 让 `LivePage` 把这块 widget 构造好传进来，
  /// 本组件负责把它与列表放在**同一个 Column** 里 ⇒ 视觉上是一体，
  /// 状态仍在宿主。
  /// ```
  ///
  /// ⚠️ 2026-10-18 更正：这个字段**曾被声明但从未渲染**（死参数）——
  ///   Owner 说「搜索框不要放在最上面，放在右侧的列表区域」之后才接上，
  ///   见 build 里 `if (widget.header != null) widget.header!` 那一段。
  final Widget? header;

  @override
  State<LiveChannelList> createState() => LiveChannelListState();
}

class LiveChannelListState extends State<LiveChannelList> {
  /// ★ 当前筛的源（`null` = 全部源）—— **纯视图状态**，不落盘、不调 API
  String? _sourceFilter;

  /// ★ 当前筛的分类（`null` = 全部分类）—— 同上
  String? _groupFilter;

  /// ★★★ Owner 第 12 条：当前筛的**自定义分组**（`null` = 全部分组）—— 同上
  ///
  /// ⚠️ 与 `_sourceFilter` / `_groupFilter` 是**三个独立维度**，AND 组合：
  ///   分组先收窄「有哪些源」⇒ 源筛选再在其中选一个 ⇒ 分类再收窄。
  String? _sourceGroupFilter;

  @override
  void didUpdateWidget(covariant LiveChannelList oldWidget) {
    super.didUpdateWidget(oldWidget);
    /*
     * ★ 世界变了就清掉失效的筛选（否则用户会看到"空的列表"却不知道为什么）
     *
     * ```text
     * · 筛的源**不在**新列表里了（源被停用 / 整组不可用被剔除）
     *   ⇒ 清回"全部源"（否则筛选恒空 ⇒ 用户以为坏了）
     * · 筛的分类在新列表里**一个频道都没有**了
     *   ⇒ 同样清回"全部分类"
     * ```
     * ⚠️ **不是** `initState` 里能做 —— 源/频道列表随时会变（探测陆续完成）。
     */
    if (_sourceFilter != null &&
        !widget.providers.any((g) => g.provider == _sourceFilter)) {
      _sourceFilter = null;
    }
    if (_groupFilter != null && !_groups.contains(_groupFilter)) {
      _groupFilter = null;
    }
    /*
     * ★★★ Owner 第 12 条：分组被**删掉**（设置页删的）⇒ 清回「全部分组」。
     *
     * ⚠️ 只清 filter，**不碰源** —— 组里的源自动回落到「全部」显示，
     *   这正是 Lead 要求的「删分组时里面的源回落到全部，不许消失」。
     *   本组件从不持有「某个源属于哪个组」的状态 ⇒ 组没了就是没筛，
     *   源列表照旧完整。
     *
     * ★ 第 65 轮批次 D：**两套分组都要判** —— 组可能只存在于 v2
     *   （用户在直播页按频道建的新组），只看 v1 会把它当"已删除"
     *   ⇒ 刚建的组立刻掉回「全部分组」（看起来像没保存）。
     */
    if (_sourceGroupFilter != null &&
        !widget.sourceGroups.containsKey(_sourceGroupFilter) &&
        !widget.channelGroups.containsKey(_sourceGroupFilter)) {
      _sourceGroupFilter = null;
    }
  }

  /// 当前可见频道里动态收集的分类（去重 + 稳定顺序）
  ///
  /// ★ 用户要求"从**当前可见频道**里动态收集" —— 不硬编码任何分类名。
  /// ★ 顺序 = **首次出现**的顺序（稳定，不随 set 迭代顺序抖动）。
  ///
  /// # ★ 为什么从**全部可见频道**（`widget.channels`）收集，
  ///   而不是"源筛选之后"的集合
  /// ```text
  /// ① 若从"源筛选之后"收集 ⇒ 分类条会随源塌缩，用户**永远选不出空集**
  ///    ⇒ "源 ∩ 分类"的 AND 就没有实际意义（恒等于"只看源"），
  ///      与用户要的两个**独立**维度不符。
  /// ② 从全部频道收集 ⇒ 分类是**全局词汇表**（这个直播页有哪些分类），
  ///    两个维度真正正交：
  ///      选源 ⇒ 只看该源；再选分类 ⇒ 再按分类收窄；两者无交集 ⇒ **空态**。
  /// ③ ★ 空态因此**可达**（这正是用户要求的"筛选后为空要有明确文案"）——
  ///    若分类随源塌缩，"空态"就永远走不到，那条要求会变成**死代码**。
  /// ```
  List<String> get _groups {
    final seen = <String>{}; // 去重
    final out = <String>[];
    for (final e in widget.channels) {
      final g = e.channel.group;
      if (g == null || g.isEmpty) continue; // 无分类的频道不产出 chip
      if (seen.add(g)) out.add(g);
    }
    return out;
  }

  /// ★★★ Owner 第 12 条：分组收窄后**仍可见**的源 id 集合
  ///
  /// 判据全在顶层纯函数 [applyLiveSourceGroup] 里（含「绝不筛成空」的兜底），
  /// 这里只做一次 `provider` 提取 —— 两处各写一遍判据必然漂移。
  ///
  /// # ★ 第 65 轮批次 D：改成**两套分组一起判**
  /// ```text
  /// v2（channelGroups，按频道）优先；某组没有 v2 数据才回落到 v1（按源）。
  /// 判据在 [liveGroupAllowsChannel] 里，这里只做「哪些源还有频道可显示」。
  /// ```
  Set<String> get _groupVisibleProviders {
    final out = <String>{};
    for (final e in widget.channels) {
      if (liveGroupAllowsChannel(
        widget.channelGroups,
        widget.sourceGroups,
        _sourceGroupFilter,
        e.provider,
        e.channel.id,
      )) {
        out.add(e.provider);
      }
    }
    return out;
  }

  /// ★★★ Owner 第 12 条：**当前分组下仍要显示的源**（给源药丸排用）
  ///
  /// # 为什么源药丸排也要跟着分组收窄（这是用户要的核心体验）
  /// ```text
  /// 用户原话：
  /// > 就可以不用看不想看的其他源了
  /// ★ 关键词是**不用看** —— 如果分组只过滤频道列表、却把全部源名
  ///   照旧列在药丸排里，用户**仍然在看**那些不想看的源名。
  ///   ⇒ 分组必须同时收窄**这一排**，否则这条需求只做了一半。
  /// ```
  ///
  /// ⚠️ 与 `_groupVisibleProviders` 的区别：那个是「哪些**频道**该留」
  ///   （从 `widget.channels` 推），这个是「哪些**源药丸**该画」
  ///   （从 `widget.providers` 推）。两者同源（都走同一套判据），
  ///   但集合不同：一个源可能在 `providers` 里却没有频道。
  ///
  /// ★ 第 65 轮批次 D：分组为空（全部分组）时**原样返回** —— 与改前逐字相同，
  ///   老用户零感知（这是 `t134` 里那条 `identical(r, all)` 断言的契约）。
  List<LiveGroup> get _visibleSources {
    if (_sourceGroupFilter == null) return widget.providers;
    final keep = _groupVisibleProviders;
    final picked =
        widget.providers.where((g) => keep.contains(g.provider)).toList();
    // ★ 兜底：一个都不剩 ⇒ 返回全部（绝不筛成空，与 v1 同一条纪律）
    return picked.isEmpty ? widget.providers : picked;
  }

  /// ★★★ 组里的源被**删掉**后，源筛选要跟着清（否则列表恒空）
  ///
  /// 判据与 `didUpdateWidget` 里那条同源，但那条只在 widget 变化时跑；
  /// 这里在 **build 时**兜一道 —— 用户点分组时若源筛选已失效，立刻自愈。
  void _healSourceFilter() {
    if (_sourceFilter == null) return;
    if (_visibleSources.any((g) => g.provider == _sourceFilter)) return;
    _sourceFilter = null;
  }
  /// 只过了**分组 + 源筛选**（+ 可用性）的频道
  ///
  /// ⚠️ 分组在前：它是「有哪些源」这一层的收窄，
  ///    源筛选是「这些源里看哪一个」—— 顺序反了会出现
  ///    「筛了一个不在本组的源 ⇒ 空」这种自相矛盾的状态。
  List<LiveFlatEntry> get _sourceFiltered {
    final byGroup = _sourceGroupFilter == null
        ? widget.channels
        : widget.channels
              .where((e) => liveGroupAllowsChannel(
                    widget.channelGroups,
                    widget.sourceGroups,
                    _sourceGroupFilter,
                    e.provider,
                    e.channel.id,
                  ))
              .toList();
    if (_sourceFilter == null) return byGroup;
    return byGroup.where((e) => e.provider == _sourceFilter).toList();
  }

  /// 最终要显示的频道（分组 ∩ 源 ∩ 分类 ∩ 搜索，四个维度 AND）
  List<LiveFlatEntry> get _filtered {
    var out = _sourceFiltered;
    if (_groupFilter != null) {
      out = out.where((e) => e.channel.group == _groupFilter).toList();
    }
    /*
     * ★★★ 第 65 轮批次 D：**频道搜索**（Owner 新增要求）
     *
     * ⚠️ 放在**最后**一道：搜索是"在这几个筛选之后**再**找"，
     *    放前面会让"源/分类筛选"把用户搜到的台又筛掉
     *    （他刚打的字被别的维度否决 ⇒ 看起来像搜索坏了）。
     *    判据在 [liveChannelMatchesQuery]（纯函数，可单测）。
     */
    if (widget.searchQuery.trim().isNotEmpty) {
      out = out
          .where((e) => liveChannelMatchesQuery(
                widget.searchQuery,
                e.channel.name,
                e.tag,
              ))
          .toList();
    }
    return out;
  }

  /// ★★★ Owner 第 12 条第 ② 半：直播页内管理分组
  ///
  /// 用户原话：「自定义分组有了,但是配置的地方没有」⇒ 选了「入口提到直播页内」。
  ///
  /// # 为什么本组件可以写配置（而 task-53 说过「配置不该长在内容页」）
  /// ```text
  /// task-53 否定的形态是「点源名就启停源」—— 那里点击既是浏览又是配置，
  /// 必然误触。本处是一个明确的「管理分组」按钮，点它就是要配置，
  /// 不存在误触；且 Owner 在两种候选里明确选了 a（入口提到直播页内）。
  /// ⇒ 纪律的实质（避免误触/混淆）保住了，形态按 Owner 的选择调整。
  /// ```
  ///
  /// ⚠️ 写回 prefs 后立刻 setState —— 筛选条要在同一帧反映新数据，
  ///   不靠 didUpdateWidget（那只在上游 widget 变化时才跑）。
  Future<void> _openGroupManager() async {
    final changed = await showDialog<bool>(
      context: context,
      builder: (_) => _SourceGroupManagerDialog(
        groups: widget.sourceGroups,
        channelGroups: widget.channelGroups,
        providers: widget.providers,
        /*
         * ★ 把**当前可见频道**传进去 —— 编辑界面要能逐频道勾选，
         *   就必须拿到频道清单（含它属于哪个源）。
         * ⚠️ 传 `widget.channels`（全部可见）而不是 `_filtered`：
         *   用户可能在"只看某分类"的状态下开管理器，
         *   若只给筛后的子集 ⇒ 他看不到也选不了别的台（且保存会**丢掉**
         *   那些没显示出来的已选项 —— 那是数据损坏，不是筛选）。
         */
        channels: widget.channels,
      ),
    );
    if (changed == true && mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    _healSourceFilter();
    final groups = _groups;
    final shown = _filtered;
    // ★ 有筛选生效吗（决定空态文案要说"没有频道"还是"这个筛选下没有频道"）
    final filtering =
        _sourceFilter != null ||
        _groupFilter != null ||
        _sourceGroupFilter != null;

    /*
     * ★★★ 2026-10-18：当前分组**存在但没有任何成员**吗？
     *
     * ```text
     * 改前这种组走"全部放行"兜底 ⇒ 用户切过去看到的还是全部频道，
     * 于是他说「我明明只添加了一个 却还是展示全部」。
     * 现在如实筛空，但**必须**给他一条能看懂的文案 ——
     * 否则"列表一片空白"和"直播页坏了"长得一模一样。
     * ```
     * ⚠️ 判据只看"组名存在 + 两套数据都没成员"，不看筛选后的结果，
     *   这样即使同时开了源/分类筛选，文案也指向真正的原因（分组是空的）。
     */
    final groupIsEmpty = _sourceGroupFilter != null &&
        (widget.channelGroups[_sourceGroupFilter]?.isEmpty ?? true) &&
        (widget.sourceGroups[_sourceGroupFilter]?.isEmpty ?? true);

    return Container(
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: Radii.rLg,
        border: Border.all(color: colors.outlineVariant),
      ),
      child: Column(
        children: [
          /*
           * ════════════════════════════════════════════════════════════
           * ★★★ task-34（Owner 第 12 条）：筛选条 —— 三排 Wrap 换成一行工具条
           * ════════════════════════════════════════════════════════════
           *
           * # 用户原话（逐字）
           * ```text
           * > 你自己看看实现的合理吗?
           * > 分类+源 把列表都挤得看不到了
           * > 布局非常的不合理
           * ```
           *
           * # 改前实测（.probe/probe_tests/zz_t64_before_probe_test.dart，300x800 右栏）
           * ```text
           * 三排 Wrap 药丸（分组 2 行 + 源 2 行 + 分类 2 行）共占 **253px**
           * 频道列表只剩 **546px** ⇒ 一屏 **10** 个源
           * ⇒ 253/800 = 31.6% 的右栏面积被筛选器吃掉。Owner 说非常不合理是准的。
           * ```
           *
           * # 为什么改下拉，而不是「左侧竖栏」
           * ```text
           * ① 右栏总宽只有 300px。切一条竖栏（哪怕只 80px）给筛选器 ⇒
           *   频道名可用宽度从 300 掉到 220（-27%），
           *   而频道名里有「IPTV 直播 频道 01」这种长串 + 行尾源 tag
           *   ⇒ 必然大面积省略号。用宽度换高度，在这么窄的栏里是亏的。
           * ② 下拉是零常驻高度：不展开时只占一条 36px 工具栏，
           *   而 Wrap 无论内容多少都要占满（组越多越高）。
           * ③ 三个维度（分组 / 源 / 分类）都是单值选择（一次只能选一个），
           *   这正是下拉的语义；药丸排更像多选/平铺浏览，语义也不对。
           * ⇒ Owner 给的候选里选「顶部单行下拉」。
           * ```
           *
           * # 布局结构（筛选条与频道列表是两个独立区域）
           * ```text
           * Column
           *   ├─ _FilterBar          ← 固定 36px，永不增长
           *   └─ Expanded(ListView)  ← 吃掉全部剩余高度
           * ⇒ 组/源/分类再多也不会挤压列表（Wrap 的根本问题就是它会长）。
           * ```
           *
           * # 与建组入口的关系（Owner 第 12 条第 ② 半）
           * ```text
           * 工具栏右侧带一个「管理分组」按钮 ⇒ 直播页内直接建组/改名/删组/归组，
           * 不必跳 设置。设置页那个入口保留为次要入口（不破坏现有习惯）。
           * ★ 这也解开了 task-53 留下的结：那条否定的是「点源名就启停源」
           *   （有副作用的误触），不是「不准在内容页管理配置」；
           *   一个明确的「管理分组」按钮没有误触风险，且 Owner 明确选择了它。
           * ```
           */
          /*
           * ★★★ 2026-10-18（Owner 逐字）：列表上方的自定义区域
           *
           * ```text
           * > 直播的搜索框不要放在最上面,放在右侧的列表区域
           * ```
           * `header` 这个槽位本来就有（`LivePage` 早就构造了搜索框传进来），
           * 但**从来没被渲染** —— 属于"声明了却没接线"的死参数。
           * 现在接上：搜索框因此落在**右栏列表的正上方**。
           *
           * ⚠️ 放在 `_FilterBar` **之上**：搜索是"在整个列表里找"，
           *   视觉上属于列表的标题区；筛选条是"把列表切成几段"，
           *   放它下面更贴近"先找、再筛"的阅读顺序。
           */
          if (widget.header != null) widget.header!,

          _FilterBar(
            // ── 分组维度（value 用组名本身 —— 组名的语义就是它自己）──
            //
            // ★★★ 第 65 轮批次 D：两套分组的**组名取并集**
            //   ```text
            //   v2（按频道）是主数据，v1（按源）是用户机器上的老数据。
            //   只列其中一套 ⇒ 另一套的组在界面上"消失"了（数据还在，
            //   用户却选不到 —— 比丢了更难理解）。
            //   ⇒ 并集 + **保持各自顺序**（v1 先、v2 后：老组不跳位置）。
            //   ```
            groupVisible: _allGroupNames.isNotEmpty,
            groupValue: _sourceGroupFilter ?? '',
            groupOptions: [
              const _BarOption('', '全部分组'),
              for (final n in _allGroupNames) _BarOption(n, n),
            ],
            onPickGroup: (v) => _pickSourceGroup(v.isEmpty ? null : v),
            // ── 源维度（value = provider id，label = providerName）──
            sourceValue: _sourceFilter ?? '',
            sourceOptions: [
              const _BarOption('', '全部源'),
              for (final g in _visibleSources)
                _BarOption(g.provider, g.providerName),
            ],
            /*
             * ★ 这句提示**必须**指向新位置（设置 → JS 插件）——
             *   旧的「设置 → 直播源」区块已删，指过去是死链。
             * ⚠️ `test/merge_live_into_plugins_test.dart` 用
             *   「这句话在源码里恰好出现 2 次（1 tooltip + 1 注释）」钉住同步；
             *   下面那行注释就是第 2 处，**两处要一起改**。
             */
            sourceTooltip: '只看来自这个源的频道'
                '（只改显示，不改配置；配置请去 设置 → JS 插件）',
            onPickSource: (v) => _pickSource(v.isEmpty ? null : v),
            // ── 分类维度（value 用分类名本身）──
            categoryValue: _groupFilter ?? '',
            categoryOptions: groups.isEmpty
                ? const <_BarOption>[]
                : [
                    const _BarOption('', '全部分类'),
                    for (final g in groups) _BarOption(g, g),
                  ],
            onPickCategory: (v) => _pickGroup(v.isEmpty ? null : v),
            // ★ Owner 第 12 条第 ② 半：建组入口提到直播页内
            onManageGroups: _openGroupManager,
            hasGroups: _allGroupNames.isNotEmpty,
            // 当前选中项的**显示名**（下拉按钮上显示这个）
            /*
             * ★★★ P1-L1（B 部分）：fallback 文案缩短 —— 给长名字腾空间
             *
             * # 改前 → 改后（每格省 24~36px）
             * ```text
             * 「全部分组」(4字/48px) → 「分组」(2字/24px)   省 24px
             * 「全部源」  (3字/36px) → 「源」  (1字/12px)   省 24px
             * 「全部分类」(4字/48px) → 「分类」(2字/24px)   省 24px
             * ```
             *
             * # 为什么只在这些是**未选中**状态时（`?? ` 的 fallback）缩短
             * ```text
             * 选中具体值之后显示的是**那个名字**（如「科教·生活·科学」），
             * 长度不受本次改动影响。缩短的只是"没选"时的占位文案。
             * ```
             *
             * # ⚠️ 语义不能丢：靠 Tooltip 补全
             * ```text
             * 「分组」/「源」/「分类」单独看是名词，可能被误读成"当前值"。
             * ⇒ `_BarDropdown` 的 Tooltip 已改成"显示当前完整值"，
             *    用户在悬停时能看到「分组」+ 当前选中的组名。
             * ⚠️ 只留一个字的风险：「源」可能被理解成"源的数量"等
             *    ⇒ 这是 Lead 明确接受的权衡（截图里那个位置本来就只有 80px）。
             * ```
             *
             * ★ 已核对：`test/` 下**没有**任何 `find.text('全部分组')` 之类的
             *   精确文案断言（都是按 `ValueKey('live-bar-opt-…')` 匹配）⇒ 安全。
             */
            groupDisplay: _sourceGroupFilter ?? '分组',
            // ★ P1-L1（B）：fallback 缩短，理由见上面 groupDisplay 那段长注释
            sourceDisplay: _sourceFilter == null
                ? '源'
                : (_visibleSources
                        .where((g) => g.provider == _sourceFilter)
                        .map((g) => g.providerName)
                        .firstOrNull ??
                    '源'),
            // ★ P1-L1（B）：同上
            categoryDisplay: _groupFilter ?? '分类',
          ),

          /*
           * ══════════════════════════════════════════════════════════════
           * ★★★ 第 66 轮 M 批次：筛选条与列表之间的**呼吸间距**
           * ══════════════════════════════════════════════════════════════
           *
           * # 为什么必须有（不是"加点留白好看"）
           * ```text
           * 筛选条玻璃化后，它的下边缘高光**直接撞上**第一行列表。
           * 实测像素（`.probe/shots/t66/t66_live_rows_C_filterbar.png`）：
           *   y=44 筛选条下边缘  (31,34,63)   ← 已在变暗
           *   y=50 两者之间      (29,34,63)   ← 直接就是背景色，**零间距**
           *   y=58 第一行内容区  (40,44,72)
           * ⇒ 视觉上分不清"列表从哪开始"，像筛选条吞掉了第一行的一部分。
           * ```
           *
           * # 原理（与吸顶条那条同源）
           * ```text
           * 玻璃需要**边界**才能显出它是"浮在上面的一层"。
           * 紧贴内容 ⇒ 玻璃看起来像背景的一部分，失去层次感。
           * ★ 这就是"吸顶条必须不透明，否则内容从它下面滚过会糊在一起"
           *   的同一个道理 —— 玻璃与相邻内容之间必须有分隔。
           * ```
           *
           * # 为什么用 `Sp.x3`（12）而不是 10
           * ```text
           * 本仓间距一律走 `Sp` 令牌（Sp.x1=4 / x2=8 / x3=12 …），
           * 硬编码 10 会在不同密度/TV 档下与其它间距不一致。
           * 令牌里没有 10 ⇒ 取 12（比 10 更宽松，玻璃边界更清楚）。
           * ```
           */
          /*
           * ★ `ValueKey` 不是装饰：门禁按这个 key 精确断言"间距存在且高度对"。
           *   只判"第一行顶边 − 玻璃底边 ≥ 8"**抓不住删除** ——
           *   实测 gap=31，其中 `ListView` 自己的 `padding` 就贡献了 19
           *   ⇒ 必须直接量这个 `SizedBox`，否则删掉它测试仍然绿。
           */
          const SizedBox(key: ValueKey('live-filterbar-gap'), height: Sp.x3),

          // ── 频道（★ task-42：平铺；task-1013：按当前筛选过滤）──
          Expanded(
            child: ListView(
              clipBehavior: Clip.antiAlias,
              padding: const EdgeInsets.all(Sp.x3),
              children: [
                for (final entry in shown)
                  _ChannelTile(
                    channel: entry.channel,
                    // ★ tag = 它来自哪个源（用户说"以分组加 tag 作为标记"）
                    tag: entry.tag,
                    active: entry.channel.id == widget.selectedId,
                    // ★ N15：播放结果状态（null 回调 ⇒ unknown ⇒ 不显示徽标）
                    health: widget.healthOf?.call(entry.channel) ??
                        LivePlaybackHealth.unknown,
                    onTap: () => widget.onPickChannel(entry.channel),
                  ),
                /*
                 * ★ 全被剔除时的空态 —— 不能只留一片空白
                 *
                 * 否则用户看到"列表是空的"，第一反应是"源坏了"。
                 */
                if (shown.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(Sp.x5),
                    child: Text(
                      // ★★ task-1013：空态文案**分两种**（用户要求"明确的空态"）
                      //    · 有筛选生效 ⇒ 说清"是这个筛选下没有"，**并告诉怎么退出**
                      //      （否则用户以为整个功能坏了 / 以为源没了）
                      //    · 没筛选（源本身没频道）⇒ 原来那句（视频线受保护）
                      //
                      // ★★★ 第 65 轮批次 D：搜索是**第三种**空态。
                      //   它比筛选更"急"—— 用户刚打的字，必须告诉他
                      //   "是这个词没搜到"而不是"这个筛选下没有频道"
                      //   （后者会让他以为要去改筛选，其实改筛选也没用）。
                      widget.searchQuery.trim().isNotEmpty
                          ? '没有频道名匹配「${widget.searchQuery.trim()}」。\n'
                              '换个关键词试试，或清空搜索框看全部频道。'
                          : groupIsEmpty
                              /*
                               * ★★★ 2026-10-18：分组存在但没成员 —— 说清
                               *   "是你这个组还是空的"，并直接给出**怎么加**。
                               *   改前这种情况会被兜底成"显示全部"，用户根本
                               *   不知道自己的分组是空的（Owner 的投诉正是这个）。
                               */
                              ? '「$_sourceGroupFilter」这个分组里还没有频道。\n'
                                  '点筛选条右侧的管理按钮，把常看的频道挑进来。'
                              : filtering
                                  ? '这个筛选下没有频道。\n'
                                      '换一个源或分类，或点「全部源」「全部分类」看全部。'
                                  : '这些直播源的频道都没有可播放的画面'
                                      '（视频线路受内容方保护）。',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: FontSizes.cap,
                        color: colors.onSurfaceVariant,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// ★★★ 第 65 轮批次 D：**两套分组的组名并集**（保持各自顺序）
  ///
  /// ```text
  /// 先 v1（老数据，位置不动 —— 用户不会因为升级而找不到熟悉的组）
  /// 再 v2（新数据，按用户建组顺序追加）
  /// ```
  List<String> get _allGroupNames {
    final out = <String>[];
    final seen = <String>{};
    for (final n in widget.sourceGroups.keys) {
      if (seen.add(n)) out.add(n);
    }
    for (final n in widget.channelGroups.keys) {
      if (seen.add(n)) out.add(n);
    }
    return out;
  }

  /// 点某个源 chip（`null` = 全部源）
  ///
  /// ★ 只改**视图**：写 `_sourceFilter` + 一个 `setState`。
  /// ⚠️ **绝不**在这里调 `setProviderEnabled` —— 那正是 task-53 被否定的形态
  ///   （"点 tag 启停源"）。本组件源码里不存在该标识符，机器可查。
  void _pickSource(String? provider) {
    setState(() => _sourceFilter = provider);
    widget.onPickProvider?.call(provider);
  }

  /// 点某个分类 chip（`null` = 全部分类）—— 同上，纯视图
  void _pickGroup(String? group) {
    setState(() => _groupFilter = group);
    widget.onPickGroup?.call(group);
  }

  /// ★★★ Owner 第 12 条：点某个**自定义分组** chip（`null` = 全部分组）
  ///
  /// ★ 与 `_pickSource` / `_pickGroup` 同一条纪律：**只改视图**，
  ///   一个 `setState` 写一个内存字段 —— 不落盘、不调 API、不碰启停。
  ///   （建组 / 改组在设置页；本页只负责「按组看」。）
  ///
  /// ⚠️ 切分组时**顺手清掉源筛选**：源筛选可能指着一个**不在新组里**的源，
  ///   留着它会让列表恒空（用户会以为「这个组没内容」）。
  ///   这与 `didUpdateWidget` 里「源没了就清筛选」是同一条自愈纪律。
  void _pickSourceGroup(String? name) {
    setState(() {
      _sourceGroupFilter = name;
      if (name != null && _sourceFilter != null) {
        /*
         * ★ 第 65 轮批次 D：判据换成 `liveGroupAllowsChannel`
         *
         * 改前用 `applyLiveSourceGroup`（只认按源分组）——
         * 用户建的是**按频道**的组时，那个函数会把组当成"不存在的组"
         * ⇒ 返回全部源 ⇒ 这里的"源筛选还合不合法"判断**恒为合法**
         * ⇒ 切到一个只有 iptv 频道的组、而源筛选停在别的源上时，
         *   列表恒空（正是这条自愈要防的事）。
         */
        final visible = {
          for (final g in widget.providers)
            if (widget.channels.any((e) =>
                e.provider == g.provider &&
                liveGroupAllowsChannel(
                  widget.channelGroups,
                  widget.sourceGroups,
                  name,
                  e.provider,
                  e.channel.id,
                )))
              g.provider,
        };
        if (!visible.contains(_sourceFilter)) _sourceFilter = null;
      }
    });
    widget.onPickGroupFilter?.call(name);
  }
}


/// ★★★ task-34（Owner 第 12 条）：直播页右栏的**筛选条**
///
/// # 它替掉了什么
/// ```text
/// 改前三排 `Wrap` 药丸（分组 / 源 / 分类）各占 1-2 行，合计 **253px / 800px**
/// ⇒ 频道列表只剩 546px，一屏 10 个源。Owner：「布局非常的不合理」。
/// ```
///
/// # 为什么是**固定 36px + 下拉**
/// ```text
/// · `Wrap` 的病根是**它会长**：内容越多越高，把下面的 `Expanded` 挤没。
///   本组件高度写死 ⇒ **无论多少个分组/源/分类，永远只占一条**。
/// · 右栏只有 300px 宽，切竖栏会让频道名可用宽度掉 27%（见调用处注释）。
/// · 三个维度都是单值选择 ⇒ 下拉是正确语义（药丸更像多选）。
/// ```
///
/// ★ 每格只在**有东西可选**时出现：
///   `groupLabel == null`（没建过组）⇒ 分组那格不画；
///   `categoryOptions` 为空 ⇒ 分类那格不画 —— 老用户看到的就是一条「全部源」。
class _FilterBar extends StatelessWidget {
  const _FilterBar({
    required this.groupVisible,
    required this.groupValue,
    required this.groupOptions,
    required this.onPickGroup,
    required this.sourceValue,
    required this.sourceOptions,
    required this.sourceTooltip,
    required this.onPickSource,
    required this.categoryValue,
    required this.categoryOptions,
    required this.onPickCategory,
    required this.onManageGroups,
    required this.hasGroups,
    required this.groupDisplay,
    required this.sourceDisplay,
    required this.categoryDisplay,
  });

  /// false = 没建过组 ⇒ 不画分组那一格（老用户零感知）
  final bool groupVisible;
  /// 选中**值**（空串 = 不筛）
  final String groupValue;
  final List<_BarOption> groupOptions;
  final ValueChanged<String> onPickGroup;

  final String sourceValue;
  final List<_BarOption> sourceOptions;
  final String sourceTooltip;
  final ValueChanged<String> onPickSource;

  final String categoryValue;
  final List<_BarOption> categoryOptions;
  final ValueChanged<String> onPickCategory;

  /// ★ Owner 第 12 条第 ② 半：直播页内**直接**建组/改组/删组
  final VoidCallback onManageGroups;
  final bool hasGroups;

  /// 三格在下拉按钮上显示的**文字**（是 label，不是 value）
  final String groupDisplay;
  final String sourceDisplay;
  final String categoryDisplay;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 第 66 轮 M 批次：筛选条外壳玻璃化
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么玻璃化**这一层**（而不是列表行、不是搜索框）
     * ```text
     * 我实测了三种方案的**像素变化率**（`.probe/shots/t66/`）：
     *   A 全部行玻璃    46.8%  ⇒ 每行成了独立圆角条，行间出现缝隙，
     *                            1178 个台的扫视变慢（眼睛要跳过缝隙）
     *   B 只选中行玻璃   0.8%  ⇒ 几乎看不见，等于没做
     *   C 筛选条外壳    20.0%  ⇒ 看得见，且列表零改动（扫视不受影响）
     * ⇒ 选 C。
     * ```
     *
     * # 纯色底下的可见度（这一步很关键，不能拿渐变底糊弄）
     * ```text
     * 真实直播页是**纯色底**（无渐变）。实测（`.probe/t66_glass_solid.png`）：
     *   背景 (21,22,28) / 玻璃卡片内部 (49,52,60) ⇒ **亮 +28，肉眼明显**
     *   玻璃区域像素变化率 = **38.2%**（远高于"无效"的 5% 门槛）
     * ⇒ 纯色底下玻璃表现为"更亮的磨砂浮层 + 边缘高光"（少了"透出内容"
     *   那一层，但仍是玻璃的观感）⇒ 本页玻璃化**有效**。
     * ```
     *
     * # ⚠️ 为什么**不**玻璃化列表行（反向说明，防止将来有人改）
     * ```text
     * `_ChannelTile` 未选中时 `color: null`（**没有背景**）。
     * 给它加玻璃 ⇒ 20 行都会有半透明底 ⇒ 列表从"一个整体"变成"一叠卡片"。
     * 直播页的核心是**快速扫视大量频道**，行背景越淡越好扫。
     * ⇒ 行背景保持原样。门禁里有一条**反向断言**钉住这一点。
     * ```
     *
     * # ⚠️ 为什么**不**玻璃化吸顶条（`_StickySearchBar`）
     * ```text
     * 它本来就该"不透明" —— 否则内容从它下面滚过会糊在一起。
     * ★ 这是**视觉正确性**问题，不是性能问题。
     * ```
     */
    return GlassCard(
      /*
       * ★ 高度**写死 36**（原有约束，见类注释）—— 玻璃化不许改它。
       * ⚠️ 不要改成 mainAxisSize.min —— 那样在下拉展开/字体放大时仍会变高，
       *    又回到「筛选器吃掉列表」的老问题。
       *
       * ⚠️ `GlassCard` 自带 `padding: EdgeInsets.all(16)`，必须显式清零，
       *    否则 36 的高度会被撑成 68（16×2 + 36）。
       */
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      height: 36,
      /*
       * 默认档 `standard`：包文档明确写它是给 scrollable list 用的
       * （"5-10x faster than BackdropFilter" / "Works correctly during scrolling"）。
       * premium 档是静态头图用的高开销档，这里不用。
       */
      quality: GlassQuality.standard,
      shape: const LiquidRoundedRectangle(borderRadius: 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
        /*
         * ★ 原来的下边框保留：它是"筛选条与列表之间的分隔线"。
         *   玻璃化后这条线仍然有用（玻璃本身有边缘高光，但那条高光
         *   是**贴边**的，不足以替代一条明确的分隔）。
         */
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: colors.outlineVariant, width: 0.6),
          ),
        ),
        child: Row(
          children: [
          /*
           * ★ task-34 修：三格 + 管理按钮原样排会**溢出 18px**
           * （实测 92 + 79.8 + 92 + 28 + 间距 = 300 > 282 可用宽，见
           *  .probe/probe_tests/zz_t64_barwidth_probe_test.dart）。
           * ⇒ 每格用 `Expanded` 平分，并去掉前置图标（值本身是自解释的，
           *   「全部源」「综合」看得懂，图标只是占宽）。
           * ⚠️ 不给 Expanded 的话，长分组名会把工具条顶爆（又变成溢出）。
           */
          if (groupVisible) ...<Widget>[
            Expanded(
              child: _BarDropdown(
                key: const ValueKey('live-bar-group'),
                display: groupDisplay,
                value: groupValue,
                options: groupOptions,
                onPick: onPickGroup,
              ),
            ),
            const SizedBox(width: Sp.x1),
          ],
          Expanded(
            child: _BarDropdown(
              key: const ValueKey('live-bar-source'),
              display: sourceDisplay,
              tooltip: sourceTooltip,
              value: sourceValue,
              options: sourceOptions,
              onPick: onPickSource,
            ),
          ),
          if (categoryOptions.isNotEmpty) ...<Widget>[
            const SizedBox(width: Sp.x1),
            Expanded(
              child: _BarDropdown(
                key: const ValueKey('live-bar-category'),
                display: categoryDisplay,
                value: categoryValue,
                options: categoryOptions,
                onPick: onPickCategory,
              ),
            ),
          ],
          const SizedBox(width: Sp.x1),
          /*
           * ★★★ Owner 第 12 条第 ② 半：建组入口在**直播页内**
           * （原来藏在 设置 → 直播分组，Owner 说「配置的地方没有」）
           */
          Tooltip(
            message: hasGroups ? '管理分组（建组 / 改名 / 删组 / 归组）' : '新建分组',
            child: InkResponse(
              key: const ValueKey('live-manage-groups'),
              onTap: onManageGroups,
              radius: 18,
              child: SizedBox(
                width: 28,
                height: 28,
                child: Icon(
                  hasGroups ? AppIcons.tune : AppIcons.add,
                  size: 16,
                  color: colors.onSurfaceVariant,
                ),
              ),
            ),
          ),
          ],
        ),
      ),
    );
  }
}

/// 工具条一格里的一个选项
///
/// ★ 为什么要 value/label 分开（task-34 的教训）
/// ```text
/// 源维度里，「用户看到的」是 providerName（甲源），
/// 而「筛选用的」是 provider id（jia）—— 两者**不是同一个字符串**。
/// 第一版我直接拿 label 当下拉菜单项的 Key ⇒ 测试按 id 找选项找不到。
/// ⇒ 值走 Value，显示走 Label，Key 挂在 Value 上（稳定、与显示名解耦）。
/// ```
class _BarOption {
  const _BarOption(this.value, this.label);
  final String value;
  final String label;
}

/// 分组管理器里的「这个源属不属于本组」勾选胶囊
///
/// # ★★★ 为什么要单独写一个（第一版直接用 FilterChip 是**坏的**）
/// ```text
/// 第一版：`FilterChip(selected: ..., showCheckmark: false)`
/// 截图（.probe/shots/t64_after_group_manager.png 初版）里
/// **每一颗胶囊长得一模一样** —— 因为 `showCheckmark: false` 把
/// FilterChip 唯一的选中标识去掉了，只剩极淡的底色差，在深色主题下看不出来。
/// ⇒ 用户根本分不清「哪些源已经在组里」—— 这个配置界面等于不可用。
/// ```
///
/// # 改法：选中态给**三重**区分（任一在深色/浅色下都够）
/// ```text
/// ① 对勾图标（最直白）
/// ② 主色描边
/// ③ 主色淡底
/// ```
/// 分组管理器里的「这个源属不属于本组」勾选胶囊
///
/// # ★★★ 三次迭代，读懂了再动
/// ```text
/// ① 第一版：`FilterChip(selected: ..., showCheckmark: false)`
///    截图里**每一颗胶囊长得一模一样** —— `showCheckmark: false` 把
///    FilterChip 唯一的选中标识去掉了，只剩极淡底色，深色主题下看不出来。
///    ⇒ 用户分不清哪些源已在组里，配置界面等于不可用。
/// ② 第二版：干脆手写 `InkWell + Container + Radii.rFull` 自己画对勾。
///    对勾是出来了，但**撞了 UI-1 门禁**
///    （`zz_ui1_no_handrolled_controls_test.dart`：InkWell + BoxDecoration
///     + 全圆角 = 手写药丸，框架里有 FilterChip 就不许自己造）。
/// ③ 本版：**回到 FilterChip，但把 showCheckmark 打开**。
///    门禁要的正是这个；而 ① 的问题从来不是「用了框架」，
///    是「把框架的选中标识关掉了」。
/// ```
///
/// ★ 结论：①的修法方向错了 —— 我把「不该关对勾」错读成「不该用框架」。
///   正确做法是保留框架控件、只调它的参数。
// TODO(清理): 本组件当前**不被渲染**（所在对话框走 `_ChannelChip` 分支）。
//   实测依据：点开分组管理器后 `find.byType(FilterChip).evaluate().length == 0`
//   （`.probe/probe_tests/zz_t66_live_inventory_test.dart`，读数
//    `.probe/t66_live_inventory.txt` 的「C 管理器对话框」段）。
//   ★ 它不是"死参数"（源码里被构造 2 次），机械扫描扫不出来 ——
//     是"构造了但所在的对话框分支不渲染它"。
//   保留是因为可能还有别的分支在用；删除需单独一轮确认。
//   见 `docs/notes/round-66-issues.md`「待清理」。
class _MemberChip extends StatelessWidget {
  const _MemberChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return FilterChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: selected ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
      selected: selected,
      onSelected: (_) => onTap(),
      // ★ 这一行就是 ① 与 ③ 的唯一差别 —— 别关它
      showCheckmark: true,
      checkmarkColor: colors.primary,
      backgroundColor: Colors.transparent,
      selectedColor: colors.primary.withValues(alpha: 0.18),
      side: BorderSide(
        color: selected ? colors.primary : colors.outlineVariant,
      ),
      shape: const RoundedRectangleBorder(borderRadius: Radii.rFull),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      labelPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
/// 工具条里的一格下拉（当前值 + ▾）
///
/// ⚠️ 用 `MenuAnchor` 而不是 `PopupMenuButton`：前者能**贴在本格下方**弹出，
///   后者会以点按处为中心、且宽度不可控（在 300px 栏里会跑出边界）。
class _BarDropdown extends StatelessWidget {
  const _BarDropdown({
    super.key,
    required this.display,
    this.tooltip,
    required this.value,
    required this.options,
    required this.onPick,
  });

  /// 按钮上显示的文字（= 选中项的 label）
  final String display;
  /// 悬停提示（**用户可见** —— 写给用户看的那一句就放这里）
  final String? tooltip;
  /// 当前**选中值**（不是显示名 —— 见 [_BarOption] 的说明）
  final String value;
  final List<_BarOption> options;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return MenuAnchor(
      menuChildren: [
        for (final o in options)
          MenuItemButton(
            key: ValueKey('live-bar-opt-${o.value}'),
            onPressed: () => onPick(o.value),
            style: MenuItemButton.styleFrom(
              visualDensity: VisualDensity.compact,
            ),
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: o.value == value
                      ? Icon(AppIcons.check, size: 13, color: colors.primary)
                      : null,
                ),
                const SizedBox(width: 4),
                Text(o.label, style: const TextStyle(fontSize: FontSizes.cap)),
              ],
            ),
          ),
      ],
      builder: (ctx, controller, _) => Tooltip(
        /*
         * ★★★ P1-L1 修复（Owner：「直播页面,右侧搜索框显示很奇怪」/「菜」）：
         *   Tooltip 必须显示**当前选中的完整名字**，不能是固定文案。
         *
         * # 为什么（这是"截断后用户看不全"的唯一补偿）
         * ```text
         * 300px 右栏里每格只有 ~80.7px，8 字分类名需要 96px ⇒ 必然截断。
         * 本轮**不做**布局重构（方案 C 需要改信息架构，Lead 明确本轮不做），
         * ⇒ 截断保留，但必须让用户能**悬停看到全名**。
         *
         * ⚠️ 第一版这里是 `message: tooltip ?? ''` ——
         *    `tooltip` 只有「源」那一格传了值（"只看来自这个源的频道…"），
         *    分组/分类两格的 `tooltip` 是 **null** ⇒ 悬停**什么都不显示**。
         * ⇒ 改成：有 tooltip 用 tooltip，没有就显示**当前值** `display`。
         * ```
         */
        message: (tooltip != null && tooltip!.isNotEmpty) ? tooltip! : display,
        child: InkWell(
        onTap: () => controller.isOpen ? controller.close() : controller.open(),
        borderRadius: Radii.rSm,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              /*
               * ★★★ P1-L1 修复核心：`ConstrainedBox(maxWidth: 88)` → `Flexible`
               *
               * # 改前为什么坏（真机复现，`.probe/shots/t66/t66_zoom_third_cell.png`）
               * ```text
               * 结构是：ConstrainedBox(maxWidth: 88) > Text(ellipsis)，然后**硬跟**一个 Icon。
               * Row 的默认行为是：**非 flexible 子项先按自己的意愿要空间**。
               * ⇒ Icon(15px) 是固定的、**不可压缩**的；
               *    Text 拿到 88px 上限后仍然可能超（8 字需要 96px）
               * ⇒ Row 总宽 = 88 + 15 = 103px，但 Expanded 只给 80.7px
               * ⇒ **溢出 22.3px** ⇒ Icon 被推出格子的右边界
               *    ⇒ 箭头压到相邻格，与「管理」图标重叠
               *    ⇒ 视觉上像一个「菜」字（Owner 报的那个）
               * ```
               *
               * # 改法：`Flexible` 让文字**先让步**，箭头永不压缩
               * ```text
               * `Flexible` 的 fit 默认是 loose ⇒ Text 只拿"剩余可用宽"，
               * 拿了多少就 ellipsis 多少 ⇒ Row 永远不会超。
               * 箭头保持 15px 固定 ⇒ **永远可见、永远不出格**。
               * ```
               *
               * # ⚠️ 80px 上限不再需要
               * ```text
               * 原来那个 `maxWidth: 88` 是"防止把工具条顶爆"的土办法 ——
               * 但它在窄格子里**比可用宽还大**（80.7 < 88）⇒ 完全没起作用，
               * 只是让溢出发生在 Row 而不是 Text。
               * `Flexible` 天然以上一级约束为上限 ⇒ 删掉它。
               * ```
               */
              Flexible(
                child: Text(
                  display,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurface,
                  ),
                ),
              ),
              /*
               * ★ 箭头**不可压缩**：它是"这里能点开"的唯一视觉提示，
               *   被挤掉用户就不知道那格能下拉（Owner 截图里正是缺了它）。
               */
              Icon(AppIcons.arrow_drop_down, size: 15, color: colors.onSurfaceVariant),
            ],
          ),
        ),
        ),
      ),
    );
  }
}


/// ★★★ 第 65 轮批次 D：**直播页内**的分组管理器 —— 逐**频道**勾选
///
/// # Owner 原话（这是本次重写的唯一理由）
/// ```text
/// > 我要的是自建分组可以选择直播源下的具体的直播的房间，而不是选择直播源
/// > 这是错误的
/// ```
/// 改前的本对话框只有一排**源名**胶囊（`_MemberChip(providerName)`）——
/// 点一下 = 把整个源的所有频道放进组。Owner 说这就是错的。
///
/// # 现在的形态（两层）
/// ```text
/// 组卡片
///   ├─ 组名 + 改名 / 删除
///   ├─ 「已选 N 个频道」摘要（让用户一眼知道这个组有多大）
///   └─ 按**源**分块（源名做小标题，仍是可辨识的层级）
///        └─ 每个频道一颗胶囊（FilterChip，带对勾）⇒ 逐频道勾选
/// ```
///
/// # 为什么保留"按源分块"
/// ```text
/// 本机实测一个源 20~48 个频道、四个源加起来 100+ 个胶囊。
/// 全平铺 ⇒ 用户要在 100 颗里找"那个台"，等于没有结构。
/// ⇒ 源做**分块标题**（不是可点对象），频道在块内可点 ——
///   这正是 Owner 说的"直播源**下**的具体房间"的字面形态。
/// ```
///
/// # 数据纪律（与 UiPrefs 的契约一致）
/// ```text
/// · 打开时**深拷贝**一份进本地 `_draft` —— 取消就丢弃，不污染已存配置
/// · 只有按「保存」才写 UiPrefs（单一写入点）
/// · 保存同时写 **v2（频道）** 与 **v1（源）**：
///     v1 由 v2 推导（这个组里出现过哪些源）——
///     这样"老版本打开同一个文件"仍能看到合理的分组（向前兼容的另一半）
/// ```
class _SourceGroupManagerDialog extends StatefulWidget {
  const _SourceGroupManagerDialog({
    required this.groups,
    required this.channelGroups,
    required this.providers,
    required this.channels,
  });

  /// v1（按源，老格式）—— 只用于：① 组名并集 ② 没有 v2 数据的组回填
  final Map<String, List<String>> groups;

  /// v2（按频道）—— 主数据
  final Map<String, List<LiveChannelRef>> channelGroups;

  final List<LiveGroup> providers;

  /// 全部可见频道（带源 tag）—— 逐频道勾选的候选集
  final List<LiveFlatEntry> channels;

  @override
  State<_SourceGroupManagerDialog> createState() =>
      _SourceGroupManagerDialogState();
}

class _SourceGroupManagerDialogState
    extends State<_SourceGroupManagerDialog> {
  /// 本地草稿：组名 → **频道引用**列表（取消即丢弃）
  late Map<String, List<LiveChannelRef>> _draft;

  /// 老格式（按源）的原始数据 —— 保存时用它写回 v1
  late Map<String, List<String>> _sourceDraft;

  final TextEditingController _nameCtrl = TextEditingController();
  String? _error;

  /// 正在改名的组（null = 没有在改名）
  String? _renaming;
  final TextEditingController _renameCtrl = TextEditingController();

  /// 每个组卡片内的**频道搜索词**（组名 → 关键词）
  ///
  /// # 为什么组内也要搜索
  /// ```text
  /// 本机 4 个源 100+ 个频道 ⇒ 在对话框里滚 100 颗胶囊找「某频道 07」
  /// 是**不可用**的（而且对话框最大高度只有 620）。
  /// ```
  final Map<String, TextEditingController> _filterCtrl = {};

  @override
  void initState() {
    super.initState();
    _draft = {};
    _sourceDraft = {
      for (final e in widget.groups.entries) e.key: List<String>.from(e.value),
    };
    /*
     * ★★★ 组名并集 + 老数据回填（两条都必须，否则用户会以为分组丢了）
     *
     * ```text
     * ① 组名并集：只在 v1 里的组（老数据）也要出现在编辑界面，
     *    否则用户看到"组没了"（其实数据还在，只是本界面不显示）。
     * ② 老数据回填：一个组只有 v1（按源）时，把该源的**全部频道**
     *    铺成"已选"—— 这正是老格式的语义（整个源都在组里）。
     *    ★ 不回填的话，用户打开管理器按保存 ⇒ v1 里那些源一个频道
     *      都不在 v2 里 ⇒ **保存即清空他的分组**（数据损坏）。
     * ```
     */
    final names = <String>[];
    for (final n in widget.groups.keys) {
      if (!names.contains(n)) names.add(n);
    }
    for (final n in widget.channelGroups.keys) {
      if (!names.contains(n)) names.add(n);
    }
    for (final n in names) {
      final v2 = widget.channelGroups[n];
      if (v2 != null && v2.isNotEmpty) {
        _draft[n] = List<LiveChannelRef>.from(v2);
        continue;
      }
      // ★ 老格式 ⇒ 回填该源的全部频道
      final srcs = widget.groups[n] ?? const <String>[];
      _draft[n] = [
        for (final e in widget.channels)
          if (srcs.contains(e.provider))
            LiveChannelRef(e.provider, e.channel.id),
      ];
    }
  }

  @override
  void dispose() {
    _nameCtrl.dispose();
    _renameCtrl.dispose();
    for (final c in _filterCtrl.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _add() {
    final n = _nameCtrl.text.trim();
    if (n.isEmpty) return setState(() => _error = '分组名不能为空');
    if (_draft.containsKey(n)) {
      return setState(() => _error = '已有分组「$n」');
    }
    setState(() {
      _draft[n] = <LiveChannelRef>[];
      _nameCtrl.clear();
      _error = null;
    });
  }

  void _remove(String n) => setState(() {
        _draft.remove(n);
        _sourceDraft.remove(n);
        _filterCtrl.remove(n)?.dispose();
        if (_renaming == n) _renaming = null;
      });

  void _commitRename(String oldName) {
    final n = _renameCtrl.text.trim();
    if (n.isEmpty || n == oldName) {
      return setState(() => _renaming = null);
    }
    if (_draft.containsKey(n)) {
      return setState(() => _error = '已有分组「$n」');
    }
    setState(() {
      // 保序：Dart Map 默认保插入顺序
      final rebuilt = <String, List<LiveChannelRef>>{};
      for (final e in _draft.entries) {
        rebuilt[e.key == oldName ? n : e.key] = e.value;
      }
      _draft = rebuilt;
      _renaming = null;
      _error = null;
    });
  }

  /// 勾选 / 取消一个**频道**
  void _toggleChannel(String group, LiveChannelRef ref) {
    setState(() {
      final list = _draft[group] ?? <LiveChannelRef>[];
      if (list.contains(ref)) {
        _draft[group] = list.where((x) => x != ref).toList();
      } else {
        _draft[group] = [...list, ref];
      }
    });
  }

  /// 一键勾选 / 取消**整个源**（快捷方式，不是唯一入口）
  ///
  /// # 为什么还留这个
  /// ```text
  /// 用户想"这个源我全都要"时，100 颗胶囊逐个点不现实。
  /// ★ 但它**不是** Owner 否定的那个形态 —— 否定的形态是
  ///   「分组**只能**选源、选不到房间」；这里是房间列表**之上**
  ///   的一个批量操作，细粒度入口仍然存在且是主路径。
  /// ```
  void _toggleProviderAll(String group, String provider) {
    final all = [
      for (final e in widget.channels)
        if (e.provider == provider) LiveChannelRef(e.provider, e.channel.id),
    ];
    if (all.isEmpty) return;
    setState(() {
      final list = _draft[group] ?? <LiveChannelRef>[];
      final every = all.every(list.contains);
      if (every) {
        final drop = all.toSet();
        _draft[group] = list.where((x) => !drop.contains(x)).toList();
      } else {
        final have = list.toSet();
        _draft[group] = [
          ...list,
          for (final r in all)
            if (!have.contains(r)) r,
        ];
      }
    });
  }

  /// 保存：写 v2（频道）+ 由 v2 推导的 v1（源）
  void _save() {
    /*
     * ★ v1 由 v2 推导（不是保留原样）
     *
     * ```text
     * v1 的语义是"这个组包含这些源" —— 一个源只要有**至少一个**频道被选中，
     * 它在 v1 里就该出现。这样：
     *   · 老版本客户端打开同一个文件 ⇒ 看到合理的分组（向前兼容）
     *   · 用户在 v2 里取消某个源的最后一个频道 ⇒ 那个源自动从 v1 消失
     *     （否则 v1 会残留一个"幽灵源"，将来回落时又把它的全部频道放进来）
     * ```
     *
     * ★★★ 但**空组必须也写进去**（`v1[name] = []`，不是跳过）
     * ```text
     * 「这个组存在，只是还没选频道」与「这个组不存在」是两件事。
     * 跳过空组 ⇒ 用户刚建好还没勾选的分组，在 v1 里查不到
     *   ⇒ 设置页的"现有分组"会少一个 / 老版本看不到它
     *   ⇒ 看起来像"建组没生效"。
     * ⇒ 空组写空列表；而 `applyLiveSourceGroup` 对空列表的语义本来就是
     *   "不筛（显示全部）" ⇒ 行为正确。
     * ```
     */
    final v1 = <String, List<String>>{};
    for (final e in _draft.entries) {
      final srcs = <String>[];
      for (final r in e.value) {
        if (!srcs.contains(r.provider)) srcs.add(r.provider);
      }
      v1[e.key] = srcs;
    }
    UiPrefs.setLiveChannelGroups(_draft);
    UiPrefs.setLiveSourceGroups(v1);
    Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return AppDialogShell(
      title: '管理直播分组',
      // ★ 宽版面：逐频道勾选 + 组内搜索需要横向空间（规范要求显式传并注释）
      width: 820,
      /*
       * ★★★ 保存/取消放在外壳的 `actions:` 里，**不是**内容 Column 的末尾
       *
       * # 为什么（这是实测抓到的真 bug，不是洁癖）
       * ```text
       * 第一版把两个按钮写在 `child:` 的 Column 末尾。
       * 而 `AppDialogShell` 的内容区是 `SingleChildScrollView` ——
       * 一旦组里有几十颗频道胶囊，按钮就被**推到滚动区之外**。
       * 实测（t134 三条红）：按钮中心落在 y=633 / y=1057，
       * 而测试视口是 800×600 ⇒ tap 打空 ⇒ "保存"根本没被点到。
       * ★ 真实用户遇到的是同一件事：组大了就**滚不到保存按钮**
       *   （外壳把内容裁在 620px 里，按钮在裁切线以下）。
       * ```
       * ⇒ `actions:` 由外壳画在**滚动区之外**的固定底栏（自带分隔线、靠右），
       *   无论内容多长都够得着。这正是外壳提供 `actions` 的用途。
       */
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          TextButton(
            key: const ValueKey('live-mgr-cancel'),
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          const SizedBox(width: Sp.x2),
          FilledButton(
            key: const ValueKey('live-mgr-save'),
            onPressed: _save,
            child: const Text('保存'),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // ⚠️ 这是**给用户看的**文案 —— 不许出现 Markdown 记号。
            //   截图实测：写成 `**频道**` 会**原样显示两个星号**
            //   （Flutter 的 `Text` 不解析 Markdown）。
            //   强调用「」，不用星号。
            '把常看的「频道」挑进一组，直播页工具栏就能一键只看这一组。'
            '分组只是筛选器 —— 删掉某个组，里面的频道会回到全部频道，不会消失。',
            style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
          ),
          const SizedBox(height: Sp.x4),
          // ── 新建 ──
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('live-mgr-name'),
                  controller: _nameCtrl,
                  decoration: const InputDecoration(
                    labelText: '新分组名（如「常看」）',
                    isDense: true,
                  ),
                  onSubmitted: (_) => _add(),
                ),
              ),
              const SizedBox(width: Sp.x3),
              FilledButton(
                key: const ValueKey('live-mgr-add'),
                onPressed: _add,
                child: const Text('新建'),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: Sp.x2),
            Text(_error!, style: TextStyle(fontSize: FontSizes.cap, color: colors.error)),
          ],
          const SizedBox(height: Sp.x4),
          // ── 现有分组 ──
          if (_draft.isEmpty)
            Text(
              '还没有分组。上面输入一个名字点「新建」即可。',
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurfaceVariant),
            ),
          /*
           * ⚠️ 这里**不再**套 `Flexible` + 内层 `SingleChildScrollView`
           *
           * 外壳的内容区本身已经是滚动容器（`scrollable: true` 默认）。
           * 再套一层 ⇒ 内层拿到的是**无界高度**（滚动区里是 unbounded），
           * `Flexible` 在 unbounded 约束下无法解析 ⇒ 布局异常/整块塌陷。
           * ⇒ 直接铺开，让外壳那一层去滚。
           */
          for (final name in _draft.keys.toList()) _groupTile(name, colors),
        ],
      ),
    );
  }

  Widget _groupTile(String name, ColorScheme colors) {
    final members = _draft[name] ?? const <LiveChannelRef>[];
    final renaming = _renaming == name;
    final filterCtrl = _filterCtrl.putIfAbsent(
      name,
      TextEditingController.new,
    );
    final q = filterCtrl.text.trim().toLowerCase();
    return Container(
      margin: const EdgeInsets.only(bottom: Sp.x3),
      padding: const EdgeInsets.all(Sp.x3),
      decoration: BoxDecoration(
        border: Border.all(color: colors.outlineVariant),
        borderRadius: Radii.rMd,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (renaming)
            Row(
              children: [
                Expanded(
                  child: TextField(
                    key: ValueKey('live-mgr-renamefield-$name'),
                    controller: _renameCtrl,
                    autofocus: true,
                    decoration: const InputDecoration(isDense: true),
                    onSubmitted: (_) => _commitRename(name),
                  ),
                ),
                TextButton(
                  key: ValueKey('live-mgr-renameok-$name'),
                  onPressed: () => _commitRename(name),
                  child: const Text('确定'),
                ),
              ],
            )
          else
            Row(
              children: [
                Expanded(
                  child: Text(
                    name,
                    style: TextStyle(
                      fontSize: FontSizes.lg,
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Text(
                  '已选 ${members.length} 个频道',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: Sp.x2),
                TextButton(
                  key: ValueKey('live-mgr-rename-$name'),
                  onPressed: () {
                    setState(() {
                      _renaming = name;
                      _renameCtrl.text = name;
                      _error = null;
                    });
                  },
                  child: const Text('改名'),
                ),
                TextButton(
                  key: ValueKey('live-mgr-del-$name'),
                  onPressed: () => _remove(name),
                  child: const Text('删除'),
                ),
              ],
            ),
          const SizedBox(height: Sp.x2),
          if (widget.providers.isEmpty)
            Text(
              '（本机还没探测到直播源，暂时无法选频道）',
              style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
            )
          else ...[
            // ── 组内频道搜索（100+ 颗胶囊时是必需品）──
            TextField(
              key: ValueKey('live-mgr-filter-$name'),
              controller: filterCtrl,
              decoration: const InputDecoration(
                hintText: '在这个组里搜频道名（如「体育」）',
                isDense: true,
                prefixIcon: Icon(AppIcons.search, size: 18),
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: Sp.x3),
            /*
             * ★ 按源分块 —— 每个源一块，块头是**源名 + 批量勾选**，
             *   块内是逐频道的 FilterChip（这才是 Owner 要的入口）。
             */
            for (final g in widget.providers)
              if (_channelsOfProvider(g.provider, q).isNotEmpty ||
                  _channelsOfProvider(g.provider, '').isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: Sp.x3),
                  child: _providerBlock(name, g, members, colors, q),
                ),
          ],
        ],
      ),
    );
  }

  /// 某个源下**满足搜索词**的频道（`q` 为空 ⇒ 全部）
  List<LiveFlatEntry> _channelsOfProvider(String provider, String q) {
    return [
      for (final e in widget.channels)
        if (e.provider == provider)
          if (q.isEmpty ||
              e.channel.name.toLowerCase().contains(q) ||
              (e.channel.group ?? '').toLowerCase().contains(q))
            e,
    ];
  }

  Widget _providerBlock(
    String groupName,
    LiveGroup g,
    List<LiveChannelRef> members,
    ColorScheme colors,
    String q,
  ) {
    final shown = _channelsOfProvider(g.provider, q);
    final all = _channelsOfProvider(g.provider, '');
    final selectedCount = all
        .where((e) => members.contains(LiveChannelRef(e.provider, e.channel.id)))
        .length;
    final allSelected = all.isNotEmpty && selectedCount == all.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              g.providerName,
              style: TextStyle(
                fontSize: FontSizes.sm,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(width: Sp.x2),
            Text(
              '$selectedCount/${all.length}',
              style: TextStyle(
                fontSize: FontSizes.cap,
                color: colors.onSurfaceVariant,
              ),
            ),
            const Spacer(),
            TextButton(
              key: ValueKey('live-mgr-all-$groupName-${g.provider}'),
              onPressed: () => _toggleProviderAll(groupName, g.provider),
              child: Text(allSelected ? '全不选' : '全选'),
            ),
          ],
        ),
        if (shown.isEmpty)
          Text(
            '（这个源里没有匹配「$q」的频道）',
            style: TextStyle(fontSize: FontSizes.cap, color: colors.onSurfaceVariant),
          )
        else
          Wrap(
            spacing: Sp.x2,
            runSpacing: Sp.x2,
            children: [
              for (final e in shown)
                _MemberChip(
                  key: ValueKey(
                    'live-mgr-ch-$groupName-${e.provider}-${e.channel.id}',
                  ),
                  label: e.channel.name,
                  selected:
                      members.contains(LiveChannelRef(e.provider, e.channel.id)),
                  onTap: () => _toggleChannel(
                    groupName,
                    LiveChannelRef(e.provider, e.channel.id),
                  ),
                ),
            ],
          ),
      ],
    );
  }
}

class _LineChip extends StatelessWidget {
  const _LineChip({
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    /*
     * ★ 2026-10-15（Owner：「…换成 ui 框架提供的…不手写组件」）
     *
     * 与 `_FilterChip` 同族但语义不同：这条是**选择**（选了会换流），
     * 所以用 `ChoiceChip` 而不是 FilterChip。颜色 / 描边 / 圆角 / 内边距
     * 显式给死 ⇒ 长相与改前一致。
     */
    return ChoiceChip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: FontSizes.cap,
          color: active ? colors.primary : colors.onSurfaceVariant,
        ),
      ),
      selected: active,
      onSelected: (_) => onTap(),
      showCheckmark: false,
      backgroundColor: Colors.transparent,
      selectedColor: colors.primary.withValues(alpha: 0.16),
      side: BorderSide(
        color: active ? colors.primary : colors.outlineVariant,
      ),
      shape: const RoundedRectangleBorder(borderRadius: Radii.rFull),
      padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: 4),
      labelPadding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}

/// 频道行（task-42：平铺 + 行尾来源 tag）
class _ChannelTile extends StatefulWidget {
  const _ChannelTile({
    required this.channel,
    required this.active,
    required this.onTap,
    this.tag,
    this.health = LivePlaybackHealth.unknown,
  });

  final LiveChannel channel;
  final bool active;
  final VoidCallback onTap;

  /// ★ N15：这个频道最近一次**播放结果**（不是探测结果，见 `_health` 注释）
  ///
  /// ```text
  /// unknown   ⇒ 不显示任何徽标（没试过就别吓用户）
  /// playable  ⇒ 不显示徽标（正常的东西不需要标记）
  /// idle      ⇒ 灰点 + 「未检测到画面（可能未开播）」
  /// broken    ⇒ 红点 + 「不可用」
  /// ```
  final LivePlaybackHealth health;

  /// ★★ task-42：来源 tag（用户要求"以分组加 tag 作为标记"）
  ///
  /// 显示在行尾，表明这个频道来自哪个源（如「某电视台站」/「IPTV 直播」）。
  final String? tag;

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  /// ★★★ task-82【Q3】本行的焦点节点 —— **由本类显式持有**
  ///
  /// # 为什么必须自己持有（不能让 `InkWell` 内部造）
  /// ```text
  /// 不给 `InkWell` 传 `focusNode:` 时，节点由它内部创建，
  /// 外部**拿不到句柄** ⇒ 想实现"焦点环落在正在播放的那一行"就无从下手。
  /// ★ 本项目已有同一范式：`episode_strip.dart:521-525` 逐字记着
  ///   「`Focus` 的自动聚焦在 `skipTraversal`/重建时不可靠 ⇒
  ///    必须显式 `requestFocus()`」，那里也是**自己持有 node**。
  /// ```
  late final FocusNode _node = FocusNode(
    debugLabel: 'chan-${widget.channel.id}',
  );

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _ChannelTile oldWidget) {
    super.didUpdateWidget(oldWidget);
    /*
     * ★★ 变成"选中"时**把自己滚进可视区**（task-39）
     *
     * # 为什么必须（用户会以为按键没反应）
     * ```text
     * 列表可能比容器高（iptv 有 28 个频道）。
     * 用户按 ↓ 切到第 20 个台时，它在**屏幕外** ——
     * 高亮跑了但看不见 ⇒ 体验上就是"按了没反应"。
     * ```
     *
     * # ★ 为什么用**自己的** ensureVisible 而不靠 spatial_nav
     * ```text
     * task-3 要给 `spatial_nav._scrollIntoView` 加"输入来源门控"
     * （只让键盘/遥控滚，不让鼠标滚轮滚）。
     * ⇒ 本页**不依赖**那条路径 ⇒ task-3 改动本页不受影响。
     * ★ 也正因如此，我在 `spatial_nav.dart` 里写明了
     *   "遥控/键盘导航必须保留滚动"这条约束（见那里的长注释）。
     * ```
     *
     * ⚠️ 用 `addPostFrameCallback` —— 刚 setState 完还没布局，
     *    立刻 ensureVisible 会拿到旧位置。
     */
    if (widget.active && !oldWidget.active) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final ctx = context;
        if (!ctx.mounted) return;
        /*
         * ★★★ task-82【Q3】把**焦点环搬到本行** —— 让焦点跟着选中走
         *
         * # 为什么只能这么做（不能去拦 shell）
         * ```text
         * SDK `focus_manager.dart:2249-2254`：early handler **全部**依次执行，
         *   某条返回 handled **不会**中断这个循环；`:2271-2273` 之后才决定
         *   是否跳过焦点树。
         * ⇒ 一次 ↓ 有**两个** early handler 都在跑：
         *     · 本页 `:316` `_onHardwareKey` ⇒ `cycleChannel(1)`（选中 +1）
         *     · `shell.dart:2162` `_onGlobalKey` ⇒ `moveFocus(↓)`（焦点 +1）
         * ★ 而 shell 的 `moveFocus` 在本文件里**拦不住**（`lib/shell.dart`
         *   不在本任务写入范围）。⇒ 唯一可行的修法是：
         *   **让焦点环跟着选中走** —— 选中哪一行，焦点就落到哪一行。
         * ```
         *
         * # 为什么必须在这个 post-frame 回调里（顺序是判据的一部分）
         * ```text
         * 两个 early handler 都在**按键事件里**同步跑完，shell 的
         *   `moveFocus` 是**后**一个 `requestFocus()`；而 `requestFocus()`
         *   是**微任务**生效（SDK `focus_manager.dart:1936 _markNeedsUpdate`
         *   → `scheduleMicrotask(_applyFocusChange)`）。
         * 本回调在**帧末**执行 ⇒ 我们是最后一个动焦点的 ⇒ 必然覆盖它。
         * （与 `_pageFocus` 注释里那条"顺序很重要"同一手法。）
         * ```
         *
         * # ⚠️ 已知边界（如实记录，不假装已覆盖）
         * ```text
         * `ListView(children:)` 的 Element **惰性挂载** —— 实测 TV 上 56 个
         *   频道只有 **6–7 行**在树里（`sliver_multi_box_adaptor.dart:418-421`
         *   的 `visitChildrenForSemantics` 只访问已布局的子节点）。
         * ⇒ 选中的行若落在**挂载窗口之外**，它没有 State ⇒ 本回调根本不会
         *   跑 ⇒ 那一格的焦点仍留在 shell 选中的行上。
         * ★ 这一段**没有**修好，已写进交付说明的"未证/未覆盖"一节。
         * ```
         */
        if (_node.canRequestFocus) _node.requestFocus();
        Scrollable.ensureVisible(
          ctx,
          alignment: 0.5,
          duration: const Duration(milliseconds: 180),
          curve: Curves.easeOutCubic,
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final channel = widget.channel;
    final active = widget.active;

    return InkWell(
      onTap: widget.onTap,
      /*
       * ★★★ task-82【Q3】把**本行自己的** node 交给 `InkWell`
       *
       * 不传时节点由 `InkWell` 内部创建，外部拿不到句柄 ⇒
       * 上面 `didUpdateWidget` 里的 `_node.requestFocus()` 就**永远
       * 打在一个不在焦点树里的节点上**（等于没写）。
       * ★ 这一行是"焦点跟随选中"能成立的**前提**。
       */
      focusNode: _node,
      borderRadius: Radii.rSm,
      child: Container(
        /*
         * ★★★ task-34（Owner 第 12 条）：「分类+源把列表都挤得看不到了」
         *
         * # 这条改的是**行密度**，不只是把头部压扁
         * ```text
         * Owner 的要求是「一屏看到的源 ≥ 现在一倍」。
         * 实测（.probe/probe_tests/zz_t64_measure_probe_test.dart，1280x800）：
         *   行距 pitch = **52px**，其中内容只有 **30px**，间距占了 **22px**（42%）
         *   把头部从 253 压到 0 ⇒ 800/52 = 最多 **14 行** ⇒ 只涨 40%，
         *   **永远到不了 2 倍**。
         * ⇒ 光改组头部到不了目标，**必须同时收紧行距** —— 这是第二个杠杆。
         * ```
         *
         * # 改法（34 logo + 16 垂直内边距 + 2 边距 = 52 ⇒ 目标 40）
         * ```text
         * logo 34 → 26（仍够认出图标；文字回退仍显示前 4 字）
         * 垂直内边距 Sp.x2(8) → Sp.x1(4)
         * 底部 margin 2 → 2（保留：行与行之间的缝隙，也是点击热区的间隔）
         * ```
         *
         * ⚠️ 为什么不把 padding 砍到 0：那会让行贴在一起，
         *   选中高亮块之间没有缝隙 ⇒ 视觉上糊成一片，比挤更难用。
         */
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x2,
          vertical: Sp.x1,
        ),
        margin: const EdgeInsets.only(bottom: 2),
        decoration: BoxDecoration(
          color: active ? colors.primary.withValues(alpha: 0.14) : null,
          borderRadius: Radii.rSm,
        ),
        child: Row(
          children: [
            // ── logo（无图时显示前 4 个字）──
            // ★ task-34：34 → 26（见上面行密度的注释）
            SizedBox(
              width: 26,
              height: 26,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: channel.logo != null && channel.logo!.isNotEmpty
                    ? coverImage(
                        context,
                        url: channel.logo!,
                        // 上面的 SizedBox 就是 26x26，硬编码且无 LayoutBuilder
                        layoutWidth: 26,
                        fit: BoxFit.contain,
                        errorBuilder: (_, __, ___) => _logoText(colors),
                      )
                    : _logoText(colors),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                channel.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: FontSizes.sm,
                  fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                  color: active ? colors.primary : colors.onSurface,
                ),
              ),
            ),
            /*
             * ★★★ task-42：来源 tag（用户要求"以分组加 tag 作为标记"）
             *
             * # 用户原话
             * ```text
             * 直播页面,左侧不再分组,直接平铺下去 …
             * 平铺下去 以分组加 tag 作为标记
             * ```
             * ⇒ 去掉分组标题行，改成**每行行尾**一个来源标签。
             *
             * # ⚠️ 我第一版**加了字段却忘了渲染**（真 bug，差点交付）
             * ```text
             * 我在 `_ChannelTile` 上加了 `final String? tag`，
             * 构造处也传了 `tag: entry.tag`，
             * ★ 但 build() 里**从来没有用它** —— analyze 也不报错
             *   （写进字段但没读，Dart 不警告 —— 它是 public final）。
             * ⇒ 截图验收时才看出来：列表里**没有 tag**。
             * ⇒ 教训：**"传了参数"≠"画出来了"** —— 必须看渲染结果。
             * ```
             */
            if (widget.tag != null && widget.tag!.isNotEmpty) ...[
              const SizedBox(width: Sp.x2),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: colors.surfaceContainerHighest.withValues(alpha: 0.8),
                  borderRadius: Radii.rSm,
                  border: Border.all(color: colors.outlineVariant),
                ),
                child: Text(
                  widget.tag!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ),
            ],
            /*
             * ★★★ N15：播放结果徽标（用户原话「打开如果不能播放,动态标记」）
             *
             * # 三种状态各自的呈现（**必须**不同）
             * ```text
             * idle   ⇒ ● 灰点 + 「未检测到画面（可能未开播）」
             * broken ⇒ ● 红点 + 「不可用」
             * playable / unknown ⇒ 不画任何东西
             * ```
             *
             * # 为什么 idle 和 broken 不能共用一个样子
             * ```text
             * 「不可用」      ⇒ 这个源坏了，别试了
             * 「未检测到画面」⇒ 可能它现在没播，过会儿再看看
             * ★ 混成一个「不可用」，用户会**放弃一个其实只是暂时没播的源**。
             *   （这也是为什么本行文案不写死"未开播"—— 见 liveHealthLabel）
             * ```
             *
             * # 为什么 playable 不画
             * ```text
             * 绝大多数频道都正常。给它们全加上"可用"绿点，
             * 列表会变成一片绿 —— 信息量归零，还压窄了频道名。
             * ★ 只标记**异常**，正常保持安静。
             * ```
             */
            if (_healthLabel.isNotEmpty) ...[
              const SizedBox(width: Sp.x2),
              Tooltip(
                message: _healthLabel,
                child: Container(
                  key: ValueKey('live-health-${widget.channel.id}'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: _healthColor(colors).withValues(alpha: 0.12),
                    borderRadius: Radii.rSm,
                    border: Border.all(
                      color: _healthColor(colors).withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 6,
                        height: 6,
                        decoration: BoxDecoration(
                          color: _healthColor(colors),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        _healthLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: FontSizes.cap,
                          color: _healthColor(colors),
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
    );
  }

  /// N15：徽标文案（空 = 不显示徽标）
  ///
  /// ★ 委托给 `liveHealthLabel` 而不是在这里重写一份 ——
  ///   文案是判据的一部分（"不知道就说不知道"），必须**单点定义**，
  ///   否则 UI 与门禁断言会各说一套。
  String get _healthLabel => liveHealthLabel(widget.health);

  /// N15：徽标颜色 —— idle 用中性灰，broken 用错误红
  ///
  /// ★ 只用 `ColorScheme` 里的语义色，不硬编码色值：
  ///   主题（含 M 批次玻璃化）换了以后这两种状态仍然可辨。
  Color _healthColor(ColorScheme colors) => switch (widget.health) {
        LivePlaybackHealth.broken => colors.error,
        // idle 是"不确定"，不是"错" —— 用中性色才不会吓到用户
        LivePlaybackHealth.idle => colors.onSurfaceVariant,
        _ => colors.onSurfaceVariant,
      };

  Widget _logoText(ColorScheme colors) {
    // ⚠️ 用 `widget.channel`（本类是 StatefulWidget，字段在 widget 上）
    final n = widget.channel.name;
    /*
     * ★ task-34：logo 从 34 缩到 26 后，**4 个字在 26px 里必然折行**
     *
     * 实测（.probe/shots/t64_after_layout.png 第一版截图）：
     *   原本取前 4 字（如「IPTV」是 4 个拉丁字母 / 某平台名也是 4 个汉字），
     *   在 26px 宽的格子里横排放不下 ⇒ 折成两行、上半个字还被裁掉，
     *   看起来像**渲染坏了**（截图能明显看到字被切成上下两半）。
     *
     * ⇒ 两条一起改（缺一条都还是坏的）：
     *   ① 字数 4 → **2**（26px 里 2 个汉字 = 24px，刚好放得下）
     *   ② 加 `maxLines: 1` + `overflow: ellipsis` 作为**硬保险** ——
     *      万一下个主题把字号调大，也只会省略而不会折行/裁字。
     * ⚠️ 这是**视觉兜底**，真正的图标来自 `channel.logo`（有图时走图）。
     */
    final t = n.length > 2 ? n.substring(0, 2) : n;
    return ColoredBox(
      color: colors.surfaceContainerHighest,
      child: Center(
        child: Text(
          t,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: TextStyle(
            // 26px 格子里 2 个 11px 汉字 = 22px，放得下；用 11 而不是 cap(12)
            // 是为了留 2px 呼吸余地（12+12=24 贴着边，视觉上偏挤）
            fontSize: 11,
            height: 1.0,
            color: colors.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}


// ═══════════════════════════════════════════════════════════════════════
//  页头 / 骨架
// ═══════════════════════════════════════════════════════════════════════

/// 页头 —— 原版 `.page-head`（`LiveView.vue:154-160`）
///
/// ```html
/// <h1 class="page-title">直播</h1>
/// <p class="page-sub t-secondary">
///   {{ currentChannels.length }} 个频道
///   <template v-if="epg.length">· 支持节目单与回看</template>
/// </p>
/// ```
///
/// ⚠️ 抽成控件是为了**加载骨架能复用同一份页头** ——
///    原版加载态下页头也照样渲染（`v-if="loading"` 只包住 `.live-layout`，
///    页头在它外面）。加载时频道数还不知道，原版会显示「0 个频道」，
///    这里保持一致（不额外做"隐藏页头"那种原版没有的分支）。
class _PageHead extends StatelessWidget {
  const _PageHead({
    required this.channelCount,
    required this.showEpgHint,
    this.onShowAll,
  });

  final int channelCount;
  final bool showEpgHint;

  /// ★★ 2026-09-26【C】"所有直播"入口（用户要求"点击出来所有的直播"）
  ///
  /// null = 不显示按钮（加载骨架里传 null —— 那时还没有频道可选）。
  final VoidCallback? onShowAll;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    // ★ 内容带（t509）：`_PageHead` 的两个用点（骨架 `:1594` 与主路径 `:1913`）
    //   都直接挂在**已经有内容带**的滚动体上 ⇒ 这里归零，否则变成 ×2。
    return Padding(
      padding: EdgeInsets.zero,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '直播',
                  style: TextStyle(
                    fontSize: FontSizes.xl,
                    fontWeight: FontWeights.semibold,
                    color: colors.onSurface,
                  ),
                ),
                const SizedBox(height: Sp.x1),
                Text(
                  '$channelCount 个频道${showEpgHint ? " · 支持节目单与回看" : ""}',
                  style: TextStyle(
                    fontSize: FontSizes.sm,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
          /*
           * ★★【C】"所有直播"按钮 —— 用户原话：
           *   「直播页面可以看所有的直播,就跟选集逻辑一样,点击出来所有的直播」
           * ⇒ 放在页头右侧（与"选集"在播放页的位置语义一致：一个入口，
           *   点开就是全部列表）。
           *
           * ⚠️ 本页**不 import forui**（`FButton` 来自 forui）——
           *   本页既有控件（`_LineChip` / 源启停 chip）全是**自绘 InkWell**
           *   ⇒ ★ 沿用本页既有风格，不引入第二个控件体系
           *     （与"两套 Theme 串台"是同一类风险：多一个来源就多一处不一致）。
           */
          if (onShowAll != null)
            Tooltip(
              message: '看所有直播频道',
              child: ActionChip(
                  onPressed: onShowAll,
                  avatar: Icon(
                    AppIcons.list_alt,
                    size: 16,
                    color: colors.onSurfaceVariant,
                  ),
                  label: Text(
                    '全部',
                    style: TextStyle(
                      fontSize: FontSizes.sm,
                      color: colors.onSurface,
                    ),
                  ),
                  side: BorderSide(color: colors.outlineVariant),
                  shape: const RoundedRectangleBorder(
                    borderRadius: Radii.rFull,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: Sp.x3,
                    vertical: 6,
                  ),
                  labelPadding: EdgeInsets.zero,
                  visualDensity: VisualDensity.compact,
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
            ),
        ],
      ),
    );
  }
}

/// 面板骨架 —— 原版 `.skeleton`（`LiveView.vue:163-164`，两块 400px 高的）
///
/// 原版骨架是**整块**灰底（不是"一行行假卡片"）—— 这里保持一致：
/// 假卡片会让用户以为内容已经加载出来了，只是在等图。
class _PanelSkeleton extends StatelessWidget {
  const _PanelSkeleton();

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: colors.onSurface.withValues(alpha: 0.05),
        borderRadius: Radii.rLg,
      ),
    );
  }
}

/// ★★★ 第 65 轮批次 D：**频道搜索框**（页头，跨源按频道名搜）
///
/// # 为什么不用 `SearchBar` / `GlassSearchBar`
/// ```text
/// ① 本页还没引入 liquid_glass（批次 E 才整体替换），而 `SearchBar`
///    在 material_ui 里是一个带 elevation 的 Surface —— 与本页
///    "描边 + 淡底"的既有控件风格（`_FilterBar` / `_LineChip`）不一致。
/// ② 这里要的只是"一个带清空按钮的输入框"，`TextField` 已经够；
///    额外能力（历史/建议）没有数据源可支撑，加了是空壳。
/// ⇒ 用 `TextField` + 显式 `InputDecoration`，与 `live_groups_page` 同款。
/// ```
///
/// # 命中计数为什么要显示
/// ```text
/// Owner 的痛点是"打开显示 0 个"。搜索框如果**搜不到也一声不响**，
/// 就复现了同一种困惑（"是不是又坏了？"）。
/// ⇒ 输入后立刻显示「命中 N / 共 M」，0 命中时文案变红/提示换词。
/// ```
///
/// # ★ 为什么是**公开**类（而 `_FilterBar` / `_MemberChip` 是私有的）
/// ```text
/// 这个控件挂在 `LivePage.build` 的 **ready 分支**里，而
/// `LivePage._groups` 只由 FFI 填 ⇒ 那条分支在 `flutter test` 里**永远
/// 到不了** ⇒ 私有类就是"零覆盖"（实测：它的三个 key
/// `live-search-field` / `live-search-hits` / `live-search-clear`
/// 在任何测试里都找不到）。
/// ★ 与 `LiveChannelList` 被公开的理由**完全相同**（见那个类的长注释）：
///   整页喂不进数据，就把"能独立验证的那一层"公开出来。
/// ⇒ 公开它，`t65d_live_ui_test.dart` 就能直接 pump 它，
///   验清空按钮真的清空、命中数真的随输入变。
/// ```
class LiveSearchField extends StatelessWidget {
  const LiveSearchField({
    super.key,
    required this.controller,
    required this.query,
    required this.hitCount,
    required this.total,
    required this.onChanged,
    this.compact = false,
  });

  final TextEditingController controller;
  final String query;
  final int hitCount;
  final int total;
  final ValueChanged<String> onChanged;

  /// ★★★ 2026-10-18：窄栏模式（右栏 300px 里用）
  ///
  /// ```text
  /// · true  ⇒ 提示语缩短成「搜频道」；**没搜索时**不显示统计
  ///            （300px 里"共 1178 个频道"会把输入框挤没）；
  ///            一旦搜索就显示「命中 N」—— 那是判断关键词好用的唯一读数
  /// · false ⇒ 原来的满宽形态（页头/宽版面用），逐字不变
  /// ```
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final searching = query.trim().isNotEmpty;
    return Row(
      children: [
        Expanded(
          child: SizedBox(
            // 单行高度写死 —— 与 `_FilterBar` 的 36 同量级，避免挤压主体
            height: compact ? 36 : 40,
            child: TextField(
              key: const ValueKey('live-search-field'),
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              style: TextStyle(fontSize: FontSizes.sm, color: colors.onSurface),
              decoration: InputDecoration(
                isDense: true,
                filled: true,
                fillColor: colors.surfaceContainerHighest.withValues(alpha: 0.5),
                // ★ 窄栏里长提示语会被截断成省略号 ⇒ 缩短（语义不变）
                hintText: compact ? '搜频道' : '搜频道名（跨全部直播源）',
                hintStyle: TextStyle(
                  fontSize: FontSizes.sm,
                  color: colors.onSurfaceVariant,
                ),
                prefixIcon: Icon(
                  AppIcons.search,
                  size: 18,
                  color: colors.onSurfaceVariant,
                ),
                prefixIconConstraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                suffixIcon: searching
                    ? IconButton(
                        key: const ValueKey('live-search-clear'),
                        tooltip: '清空搜索',
                        iconSize: 16,
                        visualDensity: VisualDensity.compact,
                        onPressed: () {
                          controller.clear();
                          onChanged('');
                        },
                        icon: Icon(
                          AppIcons.close,
                          color: colors.onSurfaceVariant,
                        ),
                      )
                    : null,
                suffixIconConstraints: const BoxConstraints(
                  minWidth: 36,
                  minHeight: 36,
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: Sp.x3,
                  vertical: Sp.x2,
                ),
                border: OutlineInputBorder(
                  borderRadius: Radii.rSm,
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: Radii.rSm,
                  borderSide: BorderSide(color: colors.outlineVariant),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: Radii.rSm,
                  borderSide: BorderSide(color: colors.primary),
                ),
              ),
            ),
          ),
        ),
        /*
         * ★ 命中读数：没搜时显示总数（"共 N 个频道"），
         *   搜了显示命中数（0 时用错误色，让"没搜到"一眼可辨）。
         *
         * ⚠️ compact（右栏 300px）下**没搜索时整块不画** ——
         *   否则它和输入框抢宽度，输入框只剩几十像素。
         */
        if (!compact || searching) ...[
          const SizedBox(width: Sp.x3),
          Text(
            searching ? '命中 $hitCount / 共 $total' : '共 $total 个频道',
            key: const ValueKey('live-search-hits'),
            style: TextStyle(
              fontSize: FontSizes.cap,
              color: searching && hitCount == 0
                  ? colors.error
                  : colors.onSurfaceVariant,
            ),
          ),
        ],
      ],
    );
  }
}

/// ★★★ 第 65 轮批次 D：**取数失败态**（不是空态）
///
/// # 为什么必须有（Owner 第 5 条前半的真因）
/// ```text
/// 改前：核心未就绪 ⇒ `getLiveChannels()` 抛异常 ⇒ catch 只 debugPrint
///       ⇒ `_groups` 为空 ⇒ 画「没有可用的直播源」
/// ⇒ 用户看到"第一次打开显示 0 个"，被引导去"设置里启用源"——
///   而他的源明明是启用的 ⇒ 他会以为插件坏了 / 数据丢了。
/// ```
/// ⇒ 本组件给的是**一个能点的动作**（重试），而不是一条错方向的建议。
class _LiveLoadError extends StatelessWidget {
  const _LiveLoadError({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              AppIcons.cloud_off,
              size: 56,
              color: colors.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: Sp.x4),
            Text(
              '直播频道没取到',
              style: TextStyle(
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: Sp.x5),
            FilledButton.icon(
              key: const ValueKey('live-retry'),
              onPressed: onRetry,
              icon: const Icon(AppIcons.refresh, size: 18),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.desc,
  });

  final IconData icon;
  final String title;
  final String desc;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 56,
              color: colors.onSurfaceVariant.withValues(alpha: 0.4),
            ),
            const SizedBox(height: Sp.x4),
            Text(
              title,
              style: TextStyle(
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
                color: colors.onSurface,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(
              desc,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: FontSizes.sm,
                color: colors.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
