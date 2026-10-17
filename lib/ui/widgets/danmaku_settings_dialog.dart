// ═══════════════════════════════════════════════════════════════════════
//  弹幕设置对话框（task-13 ⑦）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么入口在**播放页**而不是全局设置页
//
// 弹幕的字号 / 透明度 / 速度 / 占用区域，都要**看着画面**调才知道合不合适。
// 放在全局设置页意味着用户必须退出播放器才能调 —— 那等于调不了。
// 所以齿轮挂在播放页底栏的「弹幕」按钮旁边，面板是 `Positioned.fill` 的
// 全屏浮层（与「播放设置」「片头片尾」同一套视觉语言，**不暂停播放**）。
//
// # ★★★ 凭证从哪来（2026-10-14 Owner 反馈后：面板上**恢复**凭证输入框）
//
// # Owner 原话（逐字）
// ```text
// > 本地播放提示 [弹幕服务] 没有收到凭证,说明 [弹幕服务] 流程根本没走通
// ```
//
// # 走不通的根因（改前）
// ```text
// ① 2026-10-11 把面板上的凭证输入框**整节删除**了 —— 当时的设想是
//    "客户端已内置官方凭证（构建期 --dart-define 注入），用户不必手填"；
// ② 但那把"内置已注入"当成了**普遍**成立。本地构建没有 --dart-define ⇒
//    `DanmakuConfig.hasBuiltinCredentials == false`，而 `UiPrefs` 也没值
//    ⇒ 打官方那条边**必然** 403「弹幕服务没收到凭证」；
// ③ 更糟的是写入口（`setAppId` / `setAppSecret` / `clearCredentials`）
//    虽然定义还在，却**全仓 0 个调用者** ⇒ 用户**无路可走**。
// ⇒ 所以本节恢复：两个输入框 + 「保存」/「清除」，让没有内置凭证的构建也能用。
// ```
//
// # 三样东西现在**都在**（优先级从高到低）
// ```text
// ① `UiPrefs` 用户覆盖（键 `dsh.danmaku.appId` / `dsh.danmaku.appSecret`）  ← 本面板写
// ② 构建期 `--dart-define=DANDANPLAY_APP_ID/SECRET`（`String.fromEnvironment`）
// ③ 两者都空 ⇒ 未配置（官方边会失败，面板必须**如实**说）
// ```
//
// 内置值仍然只在 CI Secrets 里 —— 仓库里**只有占位符 / 空串**
// （官方文档 doc.dandanplay.com/open/ 允许开源客户端「用占位符，
//  构建时从机密读取后替换」）。面板给用户填的是**他自己的**配置。
//
// 保留的只读链路（`DanmakuConfig` 的 getter / `usingBuiltin*` /
// `maskedAppId` / `isConfigured` / `statusText`）是签名与状态展示的来源。
//
// # 为什么没配凭证也**照样**发请求
//
// 见 `lib/core/danmaku.dart` 里 `ExternalDanmakuClient` 的类注释：
// 本地短路会永久埋掉服务端给的**具体**原因（缺头 / 时间戳错 / AppId 无效 /
// 签名错），而那正是用户排错唯一能拿到的信息。
// ⇒ 所以本面板把 `DanmakuException.detail`（含 `X-Error-Message` 原文）
//   原样显示出来，**一个字都不改写**。
//
// # ⚠️ AppSecret 的存储
//
// 用户手填的 AppSecret 是**明文**存在数据目录的 `ui-prefs.json` 里的
// —— 这是**用户自己的本机配置**，不进仓库（仓库纪律见上）。
// 迁移到系统凭据存储仍是**独立的一项工作**，不在本任务范围内。
//
// # 禁止 `package:flutter/material.dart`
//
// 项目用拆包后的 `material_ui`（见 `test/material_split_test.dart`）。

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../core/danmaku.dart';
import '../../core/ui_prefs.dart';
import '../tokens.dart';
import 'cover_image.dart';
import 'app_dialog_shell.dart';
import '../../design/widgets/app_icon_button.dart';

/// T27-01：弹幕面板文字统一灰阶 —— 全文件取色只走这里
///
/// # 为什么收口成一个常量类
///
/// 修复前文本色散落 Colors.white / white70 / white60 / white54 / white38，
/// 还有两处 TextStyle 干脆没给 color；white38 一档对底色实测只有 3.30:1
/// —— 业主原话「弹幕这里的文字都看不清」。现在每档对 panelBg
/// （业主 fig1 实测 rgb(20,22,27)）的 WCAG 对比度钉在
/// test/t27_w1_danmaku_contrast_test.dart：
/// body 14.5:1 · secondary 9.7:1 · muted 5.9:1（正文线 4.5:1），
/// border 2.2:1（边框线 ≥1.6:1 —— 弱化但可辨，不做正文）。
abstract final class DanmakuTextColors {
  /// 正文/强调文本与主动作 icon（旧 Colors.white 档）
  static const Color body = Color(0xFFE6E6E6);

  /// 次要文本/交互标签（旧 white70 档）
  static const Color secondary = Color(0xFFB9BEC6);

  /// 说明/占位/辅助 icon（旧 white60 / white54 / white38 档）
  static const Color muted = Color(0xFF8E939B);

  /// 边框/分隔线/关态指示点（旧 white24 档 —— 纯装饰）
  static const Color border = Color(0xFF4A4E56);

  /// 角标文字：叠在 black55 角标底上（任务口径：对纯黑 ≥4.5:1）
  static const Color badgeText = body;

  /// 面板卡片底色 —— 业主 fig1 实测 rgb(20,22,27)
  static const Color panelBg = Color(0xFF14161B);

  // ---- ★ 2026-10-11：显示区域引导遮罩（DanmakuAreaGuide）的三档色 ----
  //
  // 遮罩画在**视频画面**上，不是面板里 —— 所以对比度要求不是 WCAG 文本线，
  // 而是"看得见、又不挡画面"：色相统一走白，靠 alpha 分档。
  // 与 overlay 里弹幕描边（black α0.85）配套：白色遮罩在深色画面上同样可辨。

  /// 边界线（半透明白，1.5px）—— 标出"弹幕区到此为止"
  static const Color areaGuideLine = Color(0xCCFFFFFF);

  /// 弹幕区内填充（极淡白 6%）—— 提示"这里能放弹幕"
  static const Color areaGuideInside = Color(0x0FFFFFFF);

  /// 区外填充（更暗的白 16%）—— "遮罩"感主体，提示"这里不再有弹幕"
  static const Color areaGuideOutside = Color(0x29FFFFFF);
}

/// 对话框要展示的全部状态
///
/// # 为什么由宿主传进来、而不是对话框自己读 `DanmakuConfig`
///
/// ```text
/// ① 对话框变成**纯 UI** ⇒ 可以脱离播放页单测
/// ② 一次请求的状态（加载中 / 报错 / 命中结果）本来就属于宿主
/// ③ 打开面板不该有副作用 —— 自己读偏好会诱发"读一下就改了观感"
/// ```
class DanmakuSettingsState {
  const DanmakuSettingsState({
    required this.enabled,
    required this.appId,
    required this.appSecret,
    required this.fontScale,
    required this.opacity,
    required this.speed,
    required this.area,
    this.loading = false,
    this.error,
    this.status = '',
    this.count = 0,
    this.lanes = 0,
    this.dropped = 0,
    this.sourceLine = '',
    this.searchLoading = false,
    this.searchError,
    this.searchSearched = false,
    this.searchResults = const <DanmakuMatch>[],
    this.searchKeyword = '',
    this.searchStale = false,
    this.credentialSaved = false,
  });

  /// 从当前偏好构造（打开面板时的初值）
  ///
  /// ★ 2026-10-14（Owner 反馈「凭证流程根本没走通」）：凭证输入框**恢复**了
  /// ⇒ 这两个字段重新用来**预填**输入框（用户此前填过值，打开面板要能看见）。
  /// 预填只看**用户自己的覆盖**（`UiPrefs` 那两个键），不看 [DanmakuConfig.appId]
  /// 的**生效值** —— 生效值可能是内置凭证（构建期注入），把它塞进输入框会
  /// 让用户误以为"这是我自己填的"，他一点保存反而用**打码前的真内置值**
  /// 覆盖掉原值。真正的生效值走 `maskedAppId` 在状态行里展示。
  factory DanmakuSettingsState.fromPrefs() => DanmakuSettingsState(
    enabled: DanmakuConfig.enabled,
    appId: DanmakuConfig.userAppId,
    appSecret: DanmakuConfig.userAppSecret,
    fontScale: DanmakuConfig.fontScale,
    opacity: DanmakuConfig.opacity,
    speed: DanmakuConfig.speed,
    area: DanmakuConfig.area,
  );

  final bool enabled;

  /// 凭证输入框的**预填值** —— 只放**用户自己的覆盖**（`UiPrefs`），
  /// 不含内置凭证（见 [DanmakuSettingsState.fromPrefs] 的说明）。
  final String appId;
  final String appSecret;
  final double fontScale;
  final double opacity;
  final double speed;
  final double area;

  /// 正在取弹幕
  final bool loading;

  /// 上一次取弹幕的失败原因（null = 没有）
  final DanmakuException? error;

  /// 上一次取弹幕的结果摘要（`某番 第3集（偏移 +90.0s）· 842 条弹幕`）
  final String status;

  /// 当前挂载的弹幕条数 / 排版轨道数 / 丢弃条数（实时读数，来自渲染层）
  final int count;
  final int lanes;
  final int dropped;

  /// 弹幕数据源状态行（T27-05）：「检测到本机外部弹幕 未运行」或
  /// 「本机外部弹幕（127.0.0.1:2080）已就绪」。空串 = 不显示该行。
  final String sourceLine;

  // ── ★★★ 2026-10-14（Owner）：手动搜索番剧 ─────────────────────────
  //
  // Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  //
  // 后端 弹幕客户端的 `searchEpisodes()`（core/danmaku.dart）**早就实现**了，
  // 但**没有任何 UI 能调用它** ⇒ 用户只能等 `loadFor()` 自动匹配，匹配不中就没辙。
  // ⇒ 这一组字段就是那次搜索的状态（加载中 / 失败 / 命中结果），
  //   由宿主（player_page）持有 —— 与 `loading` / `error` / `status` 同一条分工。

  /// 正在搜索（与 [loading] 分开：搜索**不该**复用取弹幕那个 loading，
  /// 否则「正在取弹幕…」会在搜索时误报，用户以为弹幕在重载）。
  final bool searchLoading;

  /// 上一次搜索失败原因（null = 没有）。沿用 `DanmakuException` 通路 ⇒
  /// 服务端原文一样能透出来（与 [error] 同一套 UI）。
  final DanmakuException? searchError;

  /// 上一次搜索是否**已经搜过**（用来区分「还没搜」和「搜了但没结果」）。
  ///
  /// ⚠️ 只看 `searchResults.isEmpty` 判断空态会**一打开面板就显示
  ///   「没搜到」**（那时用户还没搜）—— 那是假空态，比空白更糊涂。
  ///   所以空态文案挂在 `searchLoading == false && searchSearched &&
  ///   searchResults.isEmpty` 三条同时成立时。
  final bool searchSearched;

  /// 上一次搜索命中的剧集列表（`loadFor` 那条路返回的同一份 [DanmakuMatch]）。
  final List<DanmakuMatch> searchResults;

  /// 宿主最近一次搜索用的关键词（用来把输入框回填成"正在搜的那个词"）。
  ///
  /// ⚠️ 这是个**受控回填**，不是输入框的真源 —— 用户正在敲的字在
  ///   `_searchKeyword` controller 里（见 [_syncKeyword]：只在两者不同时才写，
  ///   否则每次 setState 都会把光标顶到末尾）。
  final String searchKeyword;

  /// 搜索过程中播放页是否**已经换集 / 换源**（真错位的警示）。
  ///
  /// # 为什么这个提示非画不可
  /// ```text
  /// 搜索是网络请求，用户完全可以搜到一半就切到下一集 —— 这时
  /// 「点一条载入」载入的是**上一集**的弹幕，画面上却是新一集：
  /// 时间轴对不上、弹幕全错位，而界面上看不出任何异常。
  /// 宿主用令牌（`_danmakuFetchToken`）判这件事，判到了就把这一位置真，
  /// 面板画一句「搜索期间已换集…」，让用户知道要重搜 ——
  /// 而不是无声地把错位的弹幕挂上去。
  /// ```
  final bool searchStale;

  /// ★ 2026-10-14：用户**本次会话里刚保存过凭证** ⇒ 面板提示
  /// 「已保存，点『重新获取弹幕』生效」。
  ///
  /// 为什么不自动重取：保存凭证是"改配置"，重取是"发一次网络请求"。
  /// 自动重取会让用户正在看的画面**忽然换一批弹幕**（甚至换到另一集），
  /// 比"什么都不发生"更糟。⇒ 明确提示一次，把时机留给用户。
  final bool credentialSaved;

  DanmakuSettingsState copyWith({
    bool? enabled,
    String? appId,
    String? appSecret,
    double? fontScale,
    double? opacity,
    double? speed,
    double? area,
    bool? loading,
    DanmakuException? error,
    bool clearError = false,
    String? status,
    int? count,
    int? lanes,
    int? dropped,
    String? sourceLine,
    bool? searchLoading,
    DanmakuException? searchError,
    bool clearSearchError = false,
    bool? searchSearched,
    List<DanmakuMatch>? searchResults,
    String? searchKeyword,
    bool? searchStale,
    bool? credentialSaved,
    bool clearCredentialSaved = false,
  }) {
    return DanmakuSettingsState(
      enabled: enabled ?? this.enabled,
      appId: appId ?? this.appId,
      appSecret: appSecret ?? this.appSecret,
      fontScale: fontScale ?? this.fontScale,
      opacity: opacity ?? this.opacity,
      speed: speed ?? this.speed,
      area: area ?? this.area,
      loading: loading ?? this.loading,
      error: clearError ? null : (error ?? this.error),
      status: status ?? this.status,
      count: count ?? this.count,
      lanes: lanes ?? this.lanes,
      dropped: dropped ?? this.dropped,
      sourceLine: sourceLine ?? this.sourceLine,
      searchLoading: searchLoading ?? this.searchLoading,
      // ★ 与 `clearError` 同款：搜索失败要能被显式清掉（下一次搜索开始 / 点中一条时）
      searchError:
          clearSearchError ? null : (searchError ?? this.searchError),
      searchSearched: searchSearched ?? this.searchSearched,
      searchResults: searchResults ?? this.searchResults,
      searchKeyword: searchKeyword ?? this.searchKeyword,
      searchStale: searchStale ?? this.searchStale,
      credentialSaved:
          clearCredentialSaved ? false : (credentialSaved ?? this.credentialSaved),
    );
  }
}

/// 弹幕设置面板
///
/// 形态与 `PlayerSettingsSheet` **一致**（全屏 scrim + 居中卡片），
/// 因为它们在同一个页面里互为邻居 —— 用户不该为两个面板学两套操作。
/// Live readout for the panel status line (visible / lanes / dropped).
///
/// Why this is a separate class rather than fields on DanmakuSettingsState:
/// these three numbers change EVERY SECOND (they come from the render layer),
/// while the rest of DanmakuSettingsState only changes on user action.
/// Mixing them meant the host called setState once per second, rebuilding the
/// entire 16k-line player page -- exactly the "this modal is so laggy" the
/// Owner reported.
///
/// Splitting it out lets the host push updates through a ValueNotifier so
/// only the one Text showing these numbers rebuilds.
///
/// NOTE: same semantics as count/lanes/dropped on DanmakuSettingsState --
/// this changes HOW the update is delivered, not WHAT is displayed.
class DanmakuReadout {
  const DanmakuReadout({
    this.count = 0,
    this.lanes = 0,
    this.dropped = 0,
  });

  final int count;
  final int lanes;
  final int dropped;

  /// All three equal => nothing to notify (avoids a pointless rebuild).
  bool sameAs(DanmakuReadout o) =>
      count == o.count && lanes == o.lanes && dropped == o.dropped;

  @override
  String toString() =>
      'DanmakuReadout(count: $count, lanes: $lanes, dropped: $dropped)';
}

/// Key of the "add a block word" input (see [_blockWordsAddField]).
///
/// Exposed so tests can target the field without depending on layout
/// properties that the 2026-10-15 redesign changed.
const Key blockWordsAddFieldKey = Key('danmaku-blockwords-add-field');

/// 外部弹幕源的显示名。
///
/// Owner 2026-10-15：「bilibili 这个**弹幕**允许使用，别的不允许」。  // site-ok: danmaku-source
/// 弹幕服务与「本软件对接的视频网站」性质不同（同 `弹弹play`），
/// 所以这一个名字可以直接写出来 —— 用户一眼就知道当前挂的是哪个弹幕源。
///
/// ⚠️ 只有这一个名字被豁免（见 test/t98_no_site_names_test.dart 的行级豁免）；
///    同文件里再写别的站名**照样会被抓**。
const String _kBiliSourceLabel = 'bilibili'; // 弹幕源（Owner 明确允许具名）  // site-ok: danmaku-source

/// 弹幕面板的**三个**页签（2026-10-15 第二版，Owner）。
///
/// # Owner 原话（第二版，逐字）
/// ```text
/// > 我的意思,弹幕的配置就不要在这里了左边的挪到那个悬浮小窗里面去,快捷的操作
/// > 然后这个tabs,一个是bilibili的弹幕配置,一个是弹弹play的弹幕配置,  // site-ok: danmaku-source
/// > 如果必须要有的话,那就拆分成三个tab,第一个是配置,二三分别是bilib和弹弹,
/// > 好像确实少不了,那就拆分成三个tab吧,然后上面显示状态,
/// > 只有tab的内容区域上下滚动,其他区域不滚动
/// ```
///
/// # 三个页签各自负责什么
/// ```text
/// ① 配置   —— 跨来源的东西：开关、屏蔽词、正则
/// ② bilibili —— **这个弹幕源自己**的：请求 / 搜索 / 绑定  // site-ok: danmaku-source
/// ③ 弹弹play  —— 同上，另一个源：数据源探测 / 凭证
/// ```
///
/// # 为什么把“显示设置”从面板拿走（而不是留一份）
/// ```text
/// 字号 / 不透明度 / 速度 / 显示区域 / 类型过滤（滚动·顶部·底部·彩色）
/// —— 这些在悬浮小窗里**已经是全套**（四根可拖滑杆 + 四枚类型开关）。
///
/// 留一份在面板里，就是**同一个 bool 的第二道门** —— Owner 已经因同一理由
/// 叫我删过一次（「更多」里那个重复的弹幕开关）。
/// ```
///
/// ⚠️ 上面把 Owner 原话里的弹幕源名保留了 `bilibili`（Owner 2026-10-15 明确  // site-ok: danmaku-source
///    「弹幕这个允许使用」）；其余地方仍用中性词。
enum DanmakuPanelTab {
  /// 配置：跨来源的通用项（开关 / 屏蔽词 / 正则）
  general,

  /// bilibili：外部弹幕源自己的配置  // site-ok: danmaku-source
  bili,

  /// 弹弹play：本机数据源探测 + 官方凭证
  dandan,
}

class DanmakuSettingsDialog extends StatefulWidget {
  const DanmakuSettingsDialog({
    super.key,
    required this.state,
    required this.onSetEnabled,
    required this.onSetFontScale,
    required this.onSetOpacity,
    required this.onSetSpeed,
    required this.onSetArea,
    required this.onReload,
    required this.onClose,
    this.onOpenBili,
    this.onSearch,
    this.onPickMatch,
    this.onHintAction,
    this.onChanged,
    this.readout,
    this.biliCount,
    this.onBatchBind,
    this.fill = true,
    this.probeOverride,
  });

  final DanmakuSettingsState state;

  /// Live readout channel (null => fall back to the static values on state).
  ///
  /// 2026-10-15: split out so the host no longer needs setState once per
  /// second just to refresh one line of text (see DanmakuReadout).
  final ValueListenable<DanmakuReadout>? readout;

  /// How many danmaku the external video site has for this episode.
  ///
  /// null means "unknown" and renders as a dash. Do NOT default it to 0:
  /// "this source has none" and "we never asked" are different facts, and the
  /// status strip exists precisely to tell them apart.
  final int? biliCount;

  /// Called with the current search results when the user asks to bind the
  /// WHOLE work instead of one episode.
  ///
  /// The panel deliberately does NOT build the plan itself: alignment is a
  /// core concern with its own gate (lib/core/batch_bind.dart), and having a
  /// second implementation here would let the two drift.
  final ValueChanged<List<DanmakuMatch>>? onBatchBind;

  final ValueChanged<bool> onSetEnabled;
  final ValueChanged<double> onSetFontScale;
  final ValueChanged<double> onSetOpacity;
  final ValueChanged<double> onSetSpeed;
  final ValueChanged<double> onSetArea;

  /// 重新取一次弹幕（想重试时用）
  final VoidCallback onReload;

  final VoidCallback onClose;

  /// 打开「外部视频源弹幕」面板（task-31 ④）。
  ///
  /// 传 null ⇒ 按钮**不画** —— 面板本身不认识 某视频站，也不知道宿主有没有接。
  /// 这只是「另一个弹幕源」的入口，与 弹弹play 凭证同层。
  final VoidCallback? onOpenBili;

  /// ★★★ 2026-10-14（Owner）：用户点了「搜索番剧」区的「搜索」按钮。
  ///
  /// Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  ///
  /// 面板**自己不发请求**（与 [onReload] 同一条分工）：它把关键词原样递出去，
  /// 宿主去调客户端的 `searchEpisodes(anime: keyword)` 并把
  /// 结果写回 [DanmakuSettingsState.searchResults]。
  ///
  /// 传 null ⇒ 整个「搜索番剧」区**不画**（与 [onOpenBili] 同一条规矩：
  /// 面板不认识宿主的开关，也不该猜）。这样既有测试里的 6 处挂载点
  /// 不用跟着改，也不会出现"按钮点了没反应"的假 UI。
  final ValueChanged<String>? onSearch;

  /// ★★★ 2026-10-14（Owner）：用户点了搜索结果里的**某一条** ⇒ 载入那一集的弹幕。
  ///
  /// 递出去的是**整个** [DanmakuMatch]（不是只给 id）——因为宿主写状态行
  /// 要 `match.label`（「某番 第 3 集」），只给 id 的话宿主得自己抄一遍
  /// 拼装逻辑，两份就会漂移。
  ///
  /// 与 [onSearch] 同时为 null 才不画搜索区 —— 单有 [onSearch] 而没有
  /// [onPickMatch] 时结果列表面板画得出来、点了却没路走，所以两个
  /// **一起**给才显示（见 [_searchSection] 的门控）。
  final ValueChanged<DanmakuMatch>? onPickMatch;

  /// 用户点了「中文指引」里的动作按钮（Owner 第 1 条）。
  ///
  /// 传 null ⇒ 那枚按钮**不画**（与 [onOpenBili] 同一条规矩：面板不认识
  /// 宿主的开关，也不该猜）。动作本身由宿主执行 —— 面板只负责把
  /// `DanmakuHint.action` 原样递出去。
  final ValueChanged<DanmakuHintAction>? onHintAction;

  /*
   * 2026-10-15: onSetCredentials / onClearCredentials were removed.
   *
   * Owner: "I told you to delete those two input boxes and use the built-in
   * credentials." The developer agreement allows built-in credentials via
   * placeholder + build-time injection, so the panel no longer offers manual
   * entry and these callbacks lost their only caller.
   *
   * Removing them is not just dead-code cleanup: keeping them would mean the
   * panel still HAS a credential write path with no UI to reach it -- the
   * "visible interface, no way in" half-state this repo treats as a defect.
   *
   * Visibility is not lost: the status line (_credentialStatusText) still
   * reports "built-in credentials in effect" or "not configured".
   */

  /// 用户改了「显示哪些弹幕 / 屏蔽词」时回调 —— 让宿主重建播放页，
  /// 好让新的过滤规则**立刻**反映到正在播的那一集上。
  ///
  /// ⚠️ 这些项**不走** `onSetXxx` 那一套（那套是"宿主持有状态、面板只管显示"）：
  ///    屏蔽规则直接读写 `DanmakuConfig`（静态偏好），面板自己就能落盘，
  ///    所以只需要一个"我改过了，你重建一下"的信号。
  ///    与上面几个回调**不是**同一层抽象，这是有意的 ——
  ///    把六个开关也塞进 `onSetXxx` 会让宿主的构造参数再长六行，收益为零。
  final VoidCallback? onChanged;

  /// 根节点是否由**本面板**写成 `Positioned.fill`（默认 true，= 既有行为）
  ///
  /// ★ 传 `false` 的唯一场景：宿主用 `SheetExitMotion` 包住本面板
  ///   （退场淡出）。那时面板的父链里多了 `Opacity` / `IgnorePointer`
  ///   （都产生 RenderObject）⇒ 面板**不能再**自己写 `Positioned`
  ///   —— 它只能做 `Stack` 的直接孩子，否则两个 ParentDataWidget 争同一个
  ///   StackParentData ⇒ 抛 `Incorrect use of ParentDataWidget`
  ///   （阻断级教训：`player_page.dart` 的 `_SheetScrim` 类文档）。
  ///   `fill: false` 时定位交给宿主（本面板的 `Center` 撑满有界约束 ⇒
  ///   与 `Positioned.fill` 几何等价）。
  final bool fill;

  /// 连通性测试的注入口（测试用；null = 走真实的 [DanmakuLocalService.describe]）。
  ///
  /// # 为什么要可注入（而不是面板直接调真探针）
  /// ```text
  /// 面板本身**零网络**是本仓既有纪律（t103 的注入式用例不许被真探针拖住）。
  /// 而「测试连接」这个按钮语义上就是要发一次请求 ⇒ 唯一两头都成立的做法：
  /// 生产走真探针，测试注入假探针。
  /// ```
  /// ⚠️ 与 [_endpointUrl] 同一条：面板不认识宿主的开关，但**认得出**这是
  ///    一次由用户点击触发的、针对用户自己填的地址的请求 ——
  ///    它不读任何宿主状态，所以自持无妨。
  final Future<DanmakuLocalStatus> Function(DanmakuEndpoint?)? probeOverride;

  @override
  State<DanmakuSettingsDialog> createState() => _DanmakuSettingsDialogState();
}

class _DanmakuSettingsDialogState extends State<DanmakuSettingsDialog> {
  /// ★ 屏蔽词必须是**同一个** controller 活过整个对话框的生命周期。
  ///
  /// 原来 `_blockWordsField()` 每次 build 都 `TextEditingController(text:
  /// DanmakuConfig.blockWords.join('\n'))`：
  /// 用户敲一个字 → onChanged → setBlockWords → widget.onChanged 触发宿主重建
  /// → build 又造一个新 controller，而 EditableText 显示的就是
  /// `controller.value`（editable_text.dart:4028），didUpdateWidget 还会
  /// 重新把 controller 的监听器接上去 ⇒ **每敲一个字就被刷回规范化后的值**，
  /// 第二个屏蔽词根本输不进去。
  late final TextEditingController _blockWords = TextEditingController();

  /// Search box for blocking words (only shown when there are many).
  ///
  /// Same lesson as [_blockWords]: creating a new controller every build
  /// wipes what the user just typed.
  final TextEditingController _blockSearch = TextEditingController();

  /*
   * 2026-10-15 redesign: _blockWords is now the ADD field (a single word),
   * not the whole multi-line blob => its initial value MUST be empty.
   * If it were still seeded with blockWords.join(), every existing word would
   * appear in the add box and pressing Enter would re-add them all as one word.
   */
  /// ★★★ 2026-10-14：搜索关键词输入框的 controller。
  ///
  /// 与 [_blockWords] **完全同一条教训**（那个字段的注释里有实测）：
  /// 每帧 new 一个 controller 会让用户敲一个字就被刷回初值。
  /// 这里更明显 —— 搜索框被 `searchResults` / `searchLoading` 的
  /// 状态变化带着重建（搜索一返回就 setState），用局部 controller
  /// 会把用户刚敲的关键词整段吃掉。
  final TextEditingController _searchKeyword = TextEditingController();

  /// 自建弹幕服务地址输入框（owner 第 6 条的落地点）。
  ///
  /// ⚠️ 同 [_blockWords] / [_searchKeyword] 的教训：每帧 new 一个 controller
  ///    会让用户敲一个字就被刷回初值。
  final TextEditingController _endpointUrl = TextEditingController();

  /// 自建弹幕服务 token 输入框（可选；某些自建服务把它放在路径前缀上）。
  final TextEditingController _endpointToken = TextEditingController();

  /// 「测试连接」的结果（null = 还没测过 / 用户改过地址后已作废）。
  DanmakuLocalStatus? _probeResult;

  /// 走不到 [DanmakuLocalStatus] 的那种结果（目前只有「地址格式不对」）。
  ///
  /// ⚠️ 单独一个字段，是因为**不能**拿 status 硬凑：地址非法时探针根本没跑，
  ///    而 `DanmakuLocalStatus(online: false).line` 会说「检测到本机外部弹幕
  ///    未运行」—— 那是**本机 2080** 的结论，与用户填错的地址无关。
  ///    对用户来说这是最坏的一种假话：他会以为自己的地址没问题、是服务没起来。
  String? _probeCustomMessage;

  /// 正在测试连接 —— 记录**是哪个序号**的请求在跑（null = 没有在途请求）。
  ///
  /// # 为什么不是 bool（★ 这条是修竞态时暴露出来的第二个 bug）
  /// ```text
  /// 只挡「过期结果不许写状态」还不够：过期请求 return 之后，
  /// 那个 bool 永远停在 true ⇒ **转圈图标永远转下去**（pumpAndSettle 超时）。
  /// ⇒ 必须让 spinner 有明确的归属：哪个序号发起的，只有它（或接管者）
  ///    才能把它关掉。
  /// ```
  int? _probeRunningSeq;

  /// 有没有在途请求（btn 的禁用态 / 转圈图标都读它）
  bool get _probeRunning => _probeRunningSeq != null;

  /// 「测试连接」的**请求序号**（防旧结果覆盖新输入）。
  ///
  /// # 它守的是什么（CodeRabbit PR #30 抓到的真竞态）
  /// ```text
  /// 填 A 点测试（请求在途）→ 用户改成 B → A 的结果回来
  /// ⇒ 旧代码会把 A 的结论写进 _probeResult、还把 A 写进偏好。
  /// 结果：输入框 B、偏好 A、状态行显示 A 的结论 —— 三者互相矛盾。
  /// ```
  ///
  /// # 判据为什么是**序号**而不是「地址字符串变没变」
  /// ```text
  /// 用户可能 A → B → A：字符串比出来相同，但 B 那一轮的结论
  /// 语义上已经作废（它属于上一轮）。字符串判据会**漏放**这种。
  /// ```
  ///
  /// ⚠️ 每次发起测试 / 用户改输入 / 点清除 都要 ++，见各自的调用点。
  int _probeSeq = 0;

  /// 当前页签。默认「配置」。
  ///
  /// 为什么不默认到某个源：两个源是**互斥**的，
  /// 默认点哪一个都等于假设了用户用哪个；
  /// 而「配置」是两边都成立的中立落点。
  DanmakuPanelTab _tab = DanmakuPanelTab.general;

  /// 外部视频站这一集的弹幕条数。
  ///
  /// 为什么面板自己不去取：弹幕数据在**宿主**那侧（两条路各自写不同的字段），
  /// 面板再去读一遍就是第二份真源 ⇒ 必然会漂移。这里只是个只读展示位。
  ///
  /// ⚠️ 取不到就是 null（显示「—」），**不用 0 冒充** ——
  ///    0 是“这个源真的没弹幕”，两者对用户意义完全不同。
  int? get _biliCount => widget.biliCount;

  /*
   * 2026-10-15: the credential input boxes (and these two controllers) were
   * deleted -- Owner: "I told you to delete those two input boxes and use the
   * built-in credentials." The developer agreement allows built-in credentials
   * via placeholder + build-time injection, which is what this repo does.
   * See the long note in _credentialsSection.
   *
   * NOTE: deleting the boxes MUST delete the controllers too -- leaving them
   * would mean two TextEditingControllers that nobody ever disposes, which is
   * exactly the resource-leak shape this repo treats as a defect (same lesson
   * as _controlsAnim and _danmakuBadgeTimer).
   */

  @override
  void initState() {
    super.initState();
    /*
     * ★ 自建服务地址/token 的预填放在 initState（**不是** build 里）。
     *
     * 在 build 里写 controller.text 会让它的 listener 触发 setState ——
     * 也就是 "setState() or markNeedsBuild() called during build"。
     * 本文件 [_syncKeyword] 遇到同一个坑时用的是 addPostFrameCallback（会闪一帧），
     * 而这里没有"值来自宿主、会变"的问题（只读一次偏好）⇒
     * 直接在 initState 里定下初值，一帧都不闪。
     */
    _endpointUrl.text = UiPrefs.danmakuEndpoint;
    _endpointToken.text = UiPrefs.danmakuToken;
  }

  @override
  void dispose() {
    _blockWords.dispose();
    _blockSearch.dispose();
    _searchKeyword.dispose();
    _endpointUrl.dispose();
    _endpointToken.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.state;
    /*
     * ★ task-104：根节点形态由 `fill` 决定
     *   fill = true （默认，= 改前行为）  Positioned.fill(...) → 只能直接挂在 Stack 下
     *   fill = false（SheetExitMotion 包着） 直接返回内容 → 定位交给宿主
     * 两者内容**逐字相同**，只是少/多一层 `Positioned.fill`
     * （理由见 `fill` 字段的文档）。
     */
    /*
     * ★ 2026-10-16（Owner：「弹幕设置这里非常的丑」+ 「弹窗样式没统一」）
     *
     * 外壳改走全仓统一的 `AppDialogShell`（docs/AGENTS.md 第 3.5 节）。
     * 改前这里自己写了一整套 Container + Material + OverlayScrim +
     * OverlayCardMotion + Positioned.fill，与另外 6 个弹窗各写各的
     * （宽度 560 硬编码、maxHeight 620 硬编码）。
     *
     * ⚠️ 本面板**不是**「标题 + 整块内容滚动」的标准形态：
     *    `_statusSection` / `_sourceStatusStrip` / `_tabBar` 三块必须
     *    **钉死不滚**（切页签时它们要一直在），只有下面的设置项滚。
     *    ⇒ 所以 `scrollable: false`，滚动区由本方法自己套。
     */
    final settings = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_tab == DanmakuPanelTab.general) ...[
          _group(_switchSection()),
          _gap(),
          /*
           * ★★ 2026-10-16：补上 [_displaySection]（字号/透明度/速度/显示区域）
           *
           * 改前它**全仓零调用** —— 「配置」页签里只有开关和屏蔽词，
           * 四个滑块加两条说明一整节都没渲染出来（Owner 截图可见）。
           * 这不是本次重构改坏的：`grep -rn _displaySection lib/ test/`
           * 改前只有定义处一行命中。
           */
          _group(_displaySection()),
          _gap(),
          _group(_filterSection()),
        ] else if (_tab == DanmakuPanelTab.bili) ...[
          _group(_requestSection()),
          if (_showSearchSection) ...[
            _gap(),
            _group(_searchSection()),
          ],
        ] else ...[
          _group(_sourceSection()),
          if (_showCredentialsSection) ...[
            _gap(),
            _group(_credentialsSection()),
          ],
          /*
           * ★★★ 2026-10-17（Owner 第 6 条「搜索弹幕提示失败」）：
           * 自建弹幕服务入口落在这个页签 —— 它与「凭证」是**同一个问题的两条路**：
           * 官方边要凭证（这构建没有）、自建边免凭证。
           * 放在一处，用户才看得见"此路不通、但那条通"。
           */
          _gap(),
          _group(_selfHostedSection()),
        ],
        _gap(),
        /*
         * ★★ Owner 第 1 条：把 403/401 翻成**能照着做**的中文
         *
         * 位置有讲究：排在「服务端返回」**上面** ——
         * 原文（Missing Authentication Headers）是证据，
         * 中文指引是结论；用户先看到结论才知道证据在说什么。
         *
         * ⚠️ 错误/指引**不受页签影响**：它们是“出事了”的反馈，
         *    而不是“一项设置”。藏在某个页签后面 ⇒ 用户在另一页签时
         *    只看到“没弹幕”而看不到为什么。
         */
        if (s.error?.hint != null) ...[
          _gap(),
          _group(_hintSection(s.error!.hint!)),
        ],
        if (s.error != null) ...[
          _gap(),
          _group(_errorSection(s.error!)),
        ],
      ],
    );

    /*
     * 三块固定 + 一块滚动（见上面说明）。
     *
     * ★★ 2026-10-16：左右内边距提到这一层（卡片级）——
     *   见 `contentPadding` 处的说明。三块固定区与滚动区因此**共享**
     *   同一个 Sp.x6，谁都不会贴到卡片圆角上。
     *   ⚠️ 上下留白也收在这里：固定区之间 / 与滚动区之间不再各自加
     *      （否则会与外壳的 contentPadding 叠成双份）。
     */
    final body = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x6),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _statusSection(),
          _sourceStatusStrip(),
          _tabBar(),
          Flexible(
            child: SingleChildScrollView(
              clipBehavior: Clip.antiAlias,
              padding: const EdgeInsets.only(top: Sp.x3, bottom: Sp.x4),
              child: settings,
            ),
          ),
        ],
      ),
    );

    // ★ 外壳接管遮罩/动效/定位；标题与副标题逐字不变
    final shelled = AppDialogShell(
      title: '弹幕设置',
      subtitle: '显示 / 过滤 / 请求',
      onClose: widget.onClose,
      fill: widget.fill,
      // ★ 本面板改前就用 OverlayScrim + OverlayCardMotion（t99 门禁钉着）
      motion: true,
      // ★★ 强制深色卡片（2026-10-16 Owner 实测「字都看不清了」的修复）
      //
      // 本面板文字走 `DanmakuTextColors` —— 那是**为深色底 #14161B 设计的固定灰阶**
      // （body #E6E6E6 / secondary #B9BEC6 / muted #8E939B），
      // t27_w1_danmaku_contrast_test 钉着它们对那个底的对比度。
      //
      // 外壳把卡片底统一成跟随主题的 surfaceContainerHighest 之后，**浅色主题**
      // 下底变浅、灰阶仍是浅色 ⇒ 几乎看不见。
      // 不能靠"把灰阶改主题色"解决：41 处灰阶与 t27_w1 门禁是一起设计的。
      // ⇒ 让它保持原本的深色（业主 fig1 实测底色就是 #14161B）。
      forceDarkCard: true,
      // 本面板自管滚动（三块钉死不滚）⇒ 不套外壳的 SingleChildScrollView
      scrollable: false,
      /*
       * ★★ 2026-10-16（Owner 实测截图：「弹幕设置这个两边没有边距」）
       *
       * 根因：`contentPadding` 只管**滚动区**（外壳把它交给
       * `SingleChildScrollView`），而本面板三块**固定区**
       * （`_statusSection` / `_sourceStatusStrip` / `_tabBar`）在
       * `scrollable: false` 下**原样透传**、吃不到那个 padding
       * ⇒ 它们左右直接顶到卡片圆角上（实测：状态条与 Tab 栏贴边）。
       *
       * ⇒ 左右内边距必须提到**卡片级**（`body` 外面那一层），让三块固定区
       *   与滚动区**吃到同一个** Sp.x6。滚动区的左右 padding 同步归零
       *   （否则左右变成 48，比改前还宽）。
       */
      contentPadding: const EdgeInsets.only(top: Sp.x3),
      child: body,
    );

    // ★ 默认形态与改前**逐像素相同**（fill 语义由外壳接管）
    return shelled;

  }

  /// 面板标题 —— 缺陷 17：**细节说明的落点**
  ///
  /// ══════════════════════════════════════════════════════════════
  /// ★★★ 为什么这里要多一个副标题（2026-10-09 · 缺陷 17 / Lead 裁决）
  /// ══════════════════════════════════════════════════════════════
  /// 播放页底栏那枚 `Icons.tune` 按钮的 tooltip 改前是一长串：
  /// ```text
  /// '弹幕设置（AppId / 字号 / 透明度）'   <- player_page.dart 旧写法
  /// ```
  /// 它有两个毛病（Lead 裁决里点名）：
  /// ```text
  /// ① 与同一页「更多」菜单项 `Text('弹幕设置')` 不是同一个叫法；
  /// ② 括号里那串**是误导性摘要** —— 面板实际有：状态 / 数据源 / 显示开关 /
  ///    字号 / 透明度 / 速度 / 占用区域 / 重新获取弹幕。三个词既不全、
  ///    又不是最需要知道的。
  /// ```
  /// ⇒ tooltip 截成 `'弹幕设置'`（与菜单项逐字一致），细节挪到**这里** ——
  ///   面板标题下方的 `note`，用户一打开就看见，也不用悬停才出现。
  ///
  /// ⚠️ 标题文字本身仍是 `'弹幕设置'` 四个字**一字不改**（副标题是**新增**）：
  ///    既有测试 `test/t99_overlay_motion_test.dart:538/542/569` 用的是
  ///    `find.text('弹幕设置')` ⇒ 多一个 `Text('显示 / 过滤 / 请求')`
  ///    之类的新串不会撞上它（那是不同的字符串，`find.text` 是精确匹配）。
  /// 顶部状态条：两个源各自多少条（Owner：「最上面显示状态」）
  ///
  /// 为什么放在**页签之外**：“现在挂的是哪个源、各有多少条”是用户
  /// **决定点哪个页签**前就要看的信息 ⇒ 不能跟着页签内容一起滚走。
  ///
  /// ⚠️ 取不到的一边显示「—」，**不用 0 冒充** ——
  ///    0 是“这个源真的没弹幕”，两者对用户意义完全不同。
  Widget _sourceStatusStrip() {
    final s = widget.state;
    // 哪个源在生效：看状态行里有没有外部视频站的字样。
    final biliLive = _biliCount != null;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(
        horizontal: Sp.x3,
        vertical: Sp.x2,
      ),
      decoration: BoxDecoration(
        borderRadius: Radii.rSm,
        border: Border.all(color: DanmakuTextColors.border),
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03),
      ),
      child: Row(
        children: [
          _sourceChip(
            label: '弹弹play',
            count: biliLive ? null : s.count,
            live: !biliLive,
          ),
          const SizedBox(width: Sp.x2),
          _sourceChip(
            label: _kBiliSourceLabel,
            count: _biliCount,
            live: biliLive,
          ),
          const Spacer(),
          if (widget.readout != null)
            ValueListenableBuilder<DanmakuReadout>(
              valueListenable: widget.readout!,
              builder: (_, r, __) => Text(
                '画面 ${r.count} 条 · 轨道 ${r.lanes}',
                style: const TextStyle(
                  color: DanmakuTextColors.muted,
                  fontSize: FontSizes.cap,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _sourceChip({
    required String label,
    required int? count,
    required bool live,
  }) {
    final n = count == null ? '—' : '$count';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            // 当前生效那一个才点亮（与底栏「当前源」高亮同一语言）
            color: live ? const Color(0xFF4FD1C5) : DanmakuTextColors.border,
          ),
        ),
        const SizedBox(width: Sp.x1),
        Text(
          '$label $n 条',
          style: TextStyle(
            color: live ? DanmakuTextColors.body : DanmakuTextColors.muted,
            fontSize: FontSizes.cap,
            fontWeight: live ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  /// 三个页签。用 `SegmentedButton` 而不是自写一套：
  /// 它自带选中态语义、键盘导航与无障碍读屏支持，
  /// 而且与本仓其他地方的选择控件同一套。
  ///
  /// ⚠️ 三个弹幕相关标签都很短（配置 / bilibili / 弹弹play），  // site-ok: danmaku-source
  ///    但卡片宽 560、内容区还要扣掉左右 padding，
  ///    所以**不给图标** —— 三个图标会把文字挤成省略号，
  ///    而省略号比没图标难认得多。
  Widget _tabBar() {
    return SizedBox(
      width: double.infinity,
      child: SegmentedButton<DanmakuPanelTab>(
        segments: const <ButtonSegment<DanmakuPanelTab>>[
          ButtonSegment<DanmakuPanelTab>(
            value: DanmakuPanelTab.general,
            label: Text('配置'),
          ),
          ButtonSegment<DanmakuPanelTab>(
            value: DanmakuPanelTab.bili,
            label: Text(_kBiliSourceLabel),
          ),
          ButtonSegment<DanmakuPanelTab>(
            value: DanmakuPanelTab.dandan,
            label: Text('弹弹play'),
          ),
        ],
        selected: <DanmakuPanelTab>{_tab},
        showSelectedIcon: false,
        /*
         * ★★ 2026-10-16（Owner 实测截图：「未选中的 tab 文字看不清」）
         *
         * 根因：不给 `style` 时，未选中项走框架默认的
         * `_SegmentedButtonDefaultsM3` —— 它的前景色是
         * `colorScheme.onSurface`。本面板是**强制深色卡片**
         * （`forceDarkCard: true`），而灰色档是给 #14161B 这个
         * 深底设计的固定灰阶 ⇒ 未选中项与卡片底几乎同色（实测均值 ≈ 卡片底）。
         *
         * ⇒ 显式给色，两档都走 `DanmakuTextColors`：
         *     未选中  secondary #B9BEC6（对深底 9.7:1，t27_w1 门禁钉着）
         *     选中    body      #E6E6E6（对深底 14.5:1）
         *   ⚠️ 面板是强制深色 ⇒ **不许**用 colorScheme（明暗主题下会各取一色，
         *      浅色主题下又变成看不清 —— 那正是本面板上一次的回归）。
         *   ⚠️ 用 `styleFrom` 而不是手写 `ButtonStyle`：
         *      它是框架提供的那条路（见 `segmented_button.dart:281`）。
         *      底纹/边框仍由主题给 —— 只改**文字色**，不动几何。
         */
        style: SegmentedButton.styleFrom(
          foregroundColor: DanmakuTextColors.secondary,
          selectedForegroundColor: DanmakuTextColors.body,
        ),
        onSelectionChanged: (v) => setState(() => _tab = v.first),
      ),
    );
  }


  /// 段间距。
  ///
  /// ★ 2026-10-16（Owner：「弹幕设置这里非常的丑」）：
  ///   改前这里是 `Divider`（一条横线 + 上下各 16px）。全面板共 7 处，
  ///   加起来 7 条横线贯穿整页 —— 这是"丑"的主要来源。
  ///   现在改为**纯留白**：分组靠 [_group] 的卡片底色区分，不再画线。
  Widget _gap() => const SizedBox(height: Sp.x3);

  /// 分组卡片 —— 一组设置一个浅底圆角容器。
  ///
  /// 为什么用底色而不是横线（2026-10-16 改）：
  /// ```text
  /// 改前：标题 + 内容 + ─────────────── + 标题 + 内容 …
  ///       ⇒ 7 条横线把面板切成一长条，像表格，视觉噪音大
  /// 改后：┌ 标题 ─────────┐  ┌ 标题 ─────────┐
  ///       │ 内容            │  │ 内容            │
  ///       └───────────────┘  └───────────────┘
  ///       ⇒ 分组靠"块"区分，一眼能数出几组
  /// ```
  /// 底色用 `onSurface` 的极低 alpha（而非写死白/黑）⇒ 明暗主题都成立。
  Widget _group(Widget child) {
    final scheme = Theme.of(context).colorScheme;
    final bg = scheme.onSurface.withValues(alpha: 0.04);
    /*
     * ★★ 必须用 `Material` 而不是 `Container` + `BoxDecoration`（2026-10-16）
     *
     * 我第一版写的是 `Container(decoration: BoxDecoration(color: bg))` ——
     * 里面装着 `SwitchListTile`（内部是 ListTile）⇒ 框架当场抛断言：
     * ```text
     * ListTile background color or ink splashes may be invisible.
     * The ListTile is wrapped in a DecoratedBox that has a background color.
     * Because ListTile paints its background and ink splashes on the nearest
     * Material ancestor, this DecoratedBox will hide those effects.
     * ```
     * t99 因此红了 4 条（①②③④ 全部断言「首帧 <1 → 中间态 → 终态」时被异常打断）。
     *
     * 同一个坑 `bili_import_dialog.dart:275` 早就记过，我又踩了一次：
     * 「同样的背景色/圆角/边框/尺寸，但 Material **就是** Material 面
     *  ⇒ 涟漪、水波纹、裁剪都正常」。
     *
     * `Material` 不接 padding ⇒ 内边距挂在外层 `Padding` 上。
     */
    return Padding(
      padding: const EdgeInsets.all(Sp.x4),
      /*
       * ⚠️ 2026-10-17：**这里不能换 AppSurface**（我换过一次，被测试打回）
       *
       * # 缺陷现场
       * ```text
       * 换成 AppSurface 后测试抛：
       *   "ListTile background color or ink splashes may be invisible.
       *    The ListTile is wrapped in a DecoratedBox that has a background color."
       *
       * 原因：AppSurface 内部是 DecoratedBox(带底色)，
       *       而 ListTile 的底色与水波纹画在**最近的 Material 祖先**上。
       *       中间隔一层带底色的 DecoratedBox ⇒ 效果被盖住 ⇒ 用户点上去看不到反馈。
       * ```
       *
       * ★ 这暴露了「Material 分类」的根本盲点：
       *   Material 不只是"提供底色"，它同时是 **ListTile 家族的绘制祖先**。
       *   ⇒ 判断能否删，必须看**子树里有没有 ListTile/CheckboxListTile/SwitchListTile**，
       *     而不是看它自己有没有 color。
       */
      child: Material(
        color: bg,
        type: MaterialType.card,
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(borderRadius: Radii.rMd),
        child: SizedBox(width: double.infinity, child: child),
      ),
    );
  }

  /// 统一开关行 —— 全面板的开关都走这里。
  ///
  /// ★ 2026-10-16：改前同一种"开关行"有**三套**写法，实测差异：
  /// ```text
  /// _switchSection  FontSizes.sm（14）  color: secondary（0xFFB9BEC6）
  /// _typeSwitch     硬编码 13          color: muted（0xFF8E939B）
  /// ```
  /// 同一个面板里同一类控件两种字号、两种颜色 —— 这是 Owner 说的
  /// 「设计没统一」。现在收敛到一处。
  Widget _switchRow({
    required String label,
    required bool value,
    required void Function(bool) onChanged,
    String? hint,
  }) {
    return SwitchListTile(
      contentPadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      value: value,
      onChanged: onChanged,
      title: Text(
        label,
        style: const TextStyle(
          color: DanmakuTextColors.secondary,
          fontSize: FontSizes.sm,
        ),
      ),
      subtitle: hint == null
          ? null
          : Text(
              hint,
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.cap,
              ),
            ),
    );
  }

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 2026-10-17：自建弹幕服务（Owner 第 6 条「搜索弹幕提示失败」）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么这是**解法**而不是绕路
  // ```text
  // Owner 第 6 条的根因是官方边 403「Missing Authentication Headers」——
  // **没有凭证**（本构建没注入 AppId/AppSecret）。
  // 而自建弹幕服务（danmu_api 这类）**免凭证**、且协议同构：
  // 实测 10157/10157 条弹幕全部解析通过（见 .probe/danapi-research/REPORT.md）。
  // ⇒ 给用户一个「填地址就能用」的入口，是该问题的直接解法。
  // ```
  //
  // # 三种来源的区别（用户排错时唯一要分清的事）
  // ```text
  // ① 自建弹幕服务   —— 用户填的地址，**免凭证**；没起来 ⇒ 连接被拒
  // ② 本机弹弹play   —— 127.0.0.1:2080，**免凭证**；没起来 ⇒ 连接被拒
  // ③ 官方弹弹play   —— api.dandanplay.net，**要** AppId/AppSecret；没有 ⇒ 403
  // ```
  // 本节的连通性测试 + 状态行就是让用户一眼知道**自己现在挂在哪条上**。
  Widget _selfHostedSection() {
    final saved = UiPrefs.danmakuEndpoint;
    final res = _probeResult;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('自建弹幕服务', note: '免凭证 · 可选'),
        // ── 地址 ──
        TextField(
          controller: _endpointUrl,
          style: const TextStyle(
            color: DanmakuTextColors.body,
            fontSize: FontSizes.sm,
          ),
          keyboardType: TextInputType.url,
          decoration: const InputDecoration(
            labelText: '服务地址',
            hintText: 'http://127.0.0.1:9321',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          // 地址一改，上一次的测试结果就**作废** —— 否则会显示一个
          // 与当前地址无关的「已就绪」，那是撒谎。
          onChanged: (_) {
            /*
             * ★★ 输入一变：① 序号前进（在途结果作废）② 交出 spinner 归属
             *    （用户既然改了地址，那个在途请求就与他无关了 ⇒ 按钮要能再点）。
             *
             * ⚠️ 两件事都**必须无条件执行**，不能包在下面的 if 里：
             *    判据是「输入变过」，不是「当前显示了什么」。
             */
            _probeSeq++;
            _probeRunningSeq = null;
            if (_probeResult != null || _probeCustomMessage != null) {
              setState(() {
                _probeResult = null;
                _probeCustomMessage = null;
              });
            } else {
              setState(() {});
            }
          },
          onSubmitted: (_) => _runProbe(),
        ),
        const SizedBox(height: Sp.x2),
        // ── token（可选）──
        TextField(
          controller: _endpointToken,
          style: const TextStyle(
            color: DanmakuTextColors.body,
            fontSize: FontSizes.sm,
          ),
          decoration: const InputDecoration(
            labelText: 'Token（可选）',
            hintText: '默认服务不用填',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onChanged: (_) {
            // token 也参与探测 ⇒ 改了同样让在途结果过期、同交还 spinner
            _probeSeq++;
            _probeRunningSeq = null;
            setState(() {
              _probeResult = null;
              _probeCustomMessage = null;
            });
          },
        ),
        const SizedBox(height: Sp.x3),
        // ── 动作行 ──
        Row(
          children: [
            FilledButton.icon(
              onPressed: _probeRunning ? null : _runProbe,
              icon: _probeRunning
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: DanmakuTextColors.body,
                        strokeWidth: 2,
                      ),
                    )
                  : const Icon(Icons.wifi_tethering, size: 18),
              label: const Text('测试连接'),
            ),
            const SizedBox(width: Sp.x2),
            TextButton(
              // 没有存过地址 ⇒ 「清除」无意义，禁用比画一个点了没反应的按钮好
              onPressed: saved.isEmpty ? null : _clearEndpoint,
              child: const Text('清除'),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        // ── 如实结果行 ──
        if (res != null) _probeResultRow(res),
        if (_probeCustomMessage != null) ...[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Icon(Icons.error_outline,
                  size: 14, color: Colors.orangeAccent),
              const SizedBox(width: Sp.x2),
              Flexible(
                child: Text(
                  _probeCustomMessage!,
                  style: const TextStyle(
                    color: Colors.orangeAccent,
                    fontSize: FontSizes.sm,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (res == null && _probeCustomMessage == null && saved.isNotEmpty) ...[
          Row(
            children: [
              const Icon(Icons.check_circle_outline,
                  size: 14, color: DanmakuTextColors.muted),
              const SizedBox(width: Sp.x2),
              Flexible(
                child: Text(
                  '当前生效：${_maskedEndpoint(saved)}（点「测试连接」确认）',
                  style: const TextStyle(
                    color: DanmakuTextColors.secondary,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ),
            ],
          ),
        ],
        if (saved.isEmpty)
          _hint('没填就按内置路径走：本机 弹弹play（127.0.0.1:2080，免凭证）→ 官方（要凭证）。'),
      ],
    );
  }

  /// 地址的**打码**展示（状态行用）。
  ///
  /// ★ 与本仓既有的 `DanmakuConfig.maskedAppId` 同一条纪律：
  ///   地址本身通常不是秘密，但**token 是** ⇒ 这里只展示 `scheme://host:port`，
  ///   去掉 path —— token 就在 path 前缀上（见 `DanmakuEndpoint.prefixedPath`）。
  String _maskedEndpoint(String raw) {
    final ep = DanmakuEndpoint.tryParse(raw, token: _endpointToken.text);
    if (ep == null) return raw;
    return ep.display;
  }

  Widget _probeResultRow(DanmakuLocalStatus res) {
    final ok = res.online;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(
          ok ? Icons.check_circle : Icons.error_outline,
          size: 14,
          color: ok ? Colors.greenAccent : Colors.orangeAccent,
        ),
        const SizedBox(width: Sp.x2),
        Flexible(
          child: Text(
            // ★ res.line 是 core 给的**如实**文案（自建/本机分开说），
            //   面板不自己拼字符串判断 —— 拼一遍就是第二份判据。
            res.line,
            style: TextStyle(
              color: ok ? Colors.greenAccent : Colors.orangeAccent,
              fontSize: FontSizes.sm,
            ),
          ),
        ),
      ],
    );
  }

  /// 测一次连通性。
  ///
  /// ⚠️ 地址非法 ⇒ **提示用户**，不要静默回退到内置路径去测一个他没填的地址
  ///    （那样会显示「本机外部弹幕已就绪」，用户以为自己填对了）。
  Future<void> _runProbe() async {
    /*
     * ★★ 2026-10-17（CodeRabbit PR #30）：**作废所有在途请求**并记下本次序号。
     *
     * # 原来漏掉的竞态（真 bug，不是洁癖）
     * ```text
     * ① 填地址 A，点「测试连接」⇒ 请求在途
     * ② 用户把地址改成 B（onChanged 把 _probeRunning 放回 false ⇒ 按钮可再点）
     * ③ A 的请求返回 ⇒ 旧代码 setState(_probeResult = A 的结果)
     *    并且 UiPrefs.setDanmakuEndpoint(A)
     * ⇒ 输入框里是 B、偏好里存的是 A、状态行显示的是 A 的结论 —— 三者互相矛盾
     * ```
     *
     * # 为什么用**序号**而不是比较地址字符串
     * ```text
     * 用户可能 A → B → A：字符串比出来相同，但 B 那一轮的结果
     * 语义上早已作废（它属于「上一轮」）⇒ 字符串判据会**漏放**这种。
     * 序号判据对「任何一次输入变化」都成立，不依赖值的形状。
     * ```
     *
     * # 谁会让序号前进
     * ```text
     * · 每次发起测试（这里）
     * · 地址框 / token 框 的 onChanged（用户改了输入 ⇒ 在途结果过期）
     * · 「清除」（用户要求回到内置路径 ⇒ 在途结果绝不许把它写回来）
     * ```
     */
    final mySeq = ++_probeSeq;
    final raw = _endpointUrl.text.trim();
    // ⚠️ token 也要**在发起时**捕获：落盘时再读 _endpointToken.text 会拿到
    //    用户后来敲的值（与地址同一类竞态，同一条纪律）。
    final rawToken = _endpointToken.text;
    final ep = DanmakuEndpoint.tryParse(raw, token: rawToken);
    if (raw.isNotEmpty && ep == null) {
      setState(() {
        _probeRunningSeq = null;
        _probeResult = null;
        // ★ 不说「本机外部弹幕未运行」——那与用户填的地址无关，是误导。
        _probeCustomMessage = '地址格式不对（例：http://127.0.0.1:9321）';
      });
      return;
    }
    // ★ spinner 归属本次序号：只有发起它的这一轮（或接管者）能关掉
    setState(() => _probeRunningSeq = mySeq);
    final probe = widget.probeOverride ??
        (DanmakuEndpoint? e) => DanmakuLocalService.describe(endpoint: e);
    DanmakuLocalStatus st;
    try {
      st = await probe(ep);
    } catch (e) {
      /*
       * ★ 过期 ⇒ 一个字都不改（失败结论同样属于旧地址，写上去也是撒谎）。
       * ⚠️ 也**不要**在这里关 spinner：此刻 _probeRunningSeq 已经不属于
       *    本次（要么被 onChanged 置空、要么被新一轮接管）。关它就是
       *    去动别人的状态 —— 那正是这个竞态的另一半。
       */
      if (!mounted || mySeq != _probeSeq) return;
      setState(() {
        _probeRunningSeq = null;
        _probeResult = null;
        // 探针自己异常（不是「服务没起来」）⇒ 如实说这次测试失败了
        _probeCustomMessage = '测试失败：$e';
      });
      return;
    }
    // ★★ 核心守卫：await 期间输入变过 ⇒ 这次结果作废。
    //    不 setState、不落盘、**也不关 spinner** —— 三件事都必须被挡住。
    if (!mounted || mySeq != _probeSeq) return;
    setState(() {
      _probeRunningSeq = null;
      _probeResult = st;
    });
    // 测通了 ⇒ 落盘（用户点的就是「这个地址可用」，不落盘等于白填）
    // ⚠️ 落盘用**发起时捕获**的 raw/rawToken，不是当前输入框的值。
    if (st.online) {
      UiPrefs.setDanmakuEndpoint(raw);
      UiPrefs.setDanmakuToken(rawToken);
    }
  }

  /// 清除 ⇒ 回到内置路径（本机 2080 → 官方）。
  void _clearEndpoint() {
    // ★ 在途的测试结果绝不许把清空后的偏好写回来（同一条竞态纪律）；
    //   spinner 同时交还 —— 用户已经要求回到内置路径，那个请求与他无关了。
    _probeSeq++;
    _probeRunningSeq = null;
    UiPrefs.setDanmakuEndpoint('');
    UiPrefs.setDanmakuToken('');
    setState(() {
      _endpointUrl.text = '';
      _endpointToken.text = '';
      _probeResult = null;
      _probeCustomMessage = null;
    });
    widget.onChanged?.call();
  }

  /// 段落标题
  Widget _sectionTitle(String text, {String? note}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x3),
      child: Row(
        children: [
          Text(
            text,
            style: const TextStyle(
              color: DanmakuTextColors.body,
              fontSize: FontSizes.base,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (note != null) ...[
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                note,
                style: const TextStyle(
                  color: DanmakuTextColors.muted,
                  fontSize: FontSizes.cap,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _hint(String text) {
    return Padding(
      padding: const EdgeInsets.only(top: Sp.x2),
      child: Text(
        text,
        style: const TextStyle(color: DanmakuTextColors.muted, fontSize: FontSizes.cap),
      ),
    );
  }

  Widget _statusSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('状态'),
        Row(
          children: [
            _dot(s.enabled),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                _statusText(s),
                style: const TextStyle(
                  color: DanmakuTextColors.secondary,
                  fontSize: FontSizes.sm,
                ),
              ),
            ),
          ],
        ),
        /*
         * 2026-10-15 (Owner: "this modal is so laggy").
         *
         * BEFORE: this line read state.count/lanes/dropped, which the host
         * refreshed once per second via setState -- rebuilding the whole
         * 16k-line player page for one line of text.
         * AFTER: the host only updates a ValueNotifier (no setState) and this
         * ValueListenableBuilder rebuilds just this Text.
         *
         * The readout semantics are unchanged (same once-per-second cadence,
         * same skip-when-unchanged rule) -- only the rebuild target changed.
         */
        if (widget.readout != null)
          ValueListenableBuilder<DanmakuReadout>(
            valueListenable: widget.readout!,
            builder: (_, r, __) => _hint(
              '画面里现在挂着 ${r.count} 条 · 轨道 ${r.lanes} 条 · 丢弃 ${r.dropped} 条',
            ),
          )
        else
          _hint('画面里现在挂着 ${s.count} 条 · 轨道 ${s.lanes} 条 · 丢弃 ${s.dropped} 条'),
      ],
    );
  }

  Widget _dot(bool on) {
    return Container(
      width: Sp.x2,
      height: Sp.x2,
      decoration: BoxDecoration(
        color: on ? Colors.lightBlueAccent : DanmakuTextColors.border,
        shape: BoxShape.circle,
      ),
    );
  }

  String _statusText(DanmakuSettingsState s) {
    if (!s.enabled) return '弹幕已关闭';
    if (s.loading) return '正在取弹幕…';
    if (s.error != null) return '取弹幕失败（下方有服务端原文）';
    if (s.status.isNotEmpty) return s.status;
    /*
     * ★ 2026-10-14（Owner 反馈「凭证流程根本没走通」）：判据仍是**生效**的
     *   凭证（用户覆盖 > 内置，见 `DanmakuConfig.isConfigured`），但口径改了：
     *   改前（输入框被删的那版）说「凭证未就绪（…不需要凭证）」——
     *   听着像"不用管"，而用户真去打官方边就是 403。
     *   现在有输入框了 ⇒ 缺凭证时**如实**说是缺凭证，并给出两条出路
     *   （下面填 / 改用免签名的那两条路）。
     */
    if (!DanmakuConfig.isConfigured) {
      return '弹幕已开启，但凭证未配置（官方边会失败）';
    }
    if (DanmakuConfig.usingBuiltinAppId) {
      return '弹幕已开启（内置凭证 AppId ${DanmakuConfig.maskedAppId}）';
    }
    return '弹幕已开启（用户填写 AppId ${DanmakuConfig.maskedAppId}）';
  }

  /*
   * ★ 2026-10-15（Owner：「这个弹窗好丑…换成 ui 框架提供的」）
   *
   * 改前这里是手写 `Row`：**开关在左、文字在右**；而紧挨着的下面三行
   * （`_typeSwitch`）是**文字在左、开关在右**。同一个面板里两种相反布局，
   * 看着就是「没对齐」。
   *
   * 现在四处开关统一走 `SwitchListTile` —— 它带来三样手写 Row 没有的东西：
   * ```text
   * ① 整行可点（不只是那枚 52×32 的开关本身）
   * ② 点击涟漪 + 水波纹（Material 交互反馈）
   * ③ 读屏语义（会读成「显示弹幕，开关，已开启」）
   * ```
   *
   * ⚠️ `contentPadding: EdgeInsets.zero`：面板自己已有 24 的左右内边距，
   *    再叠一层 ListTile 默认的 16 就会比别的行缩进一截。
   * ⚠️ `dense: true`：面板窄（560），默认行高会让四处开关之间空隙过大。
   */
  Widget _switchSection() {
    return _switchRow(
      label: '显示弹幕',
      value: widget.state.enabled,
      onChanged: widget.onSetEnabled,
    );
  }

  /// 「数据源」状态行（T27-05）—— 本机跑着外部弹幕 就优先用本地源（免签名），
  /// 没跑就退回官方 API。
  ///
  /// ★ 2026-10-11（Owner 反馈）：这里**原来**还挂着 弹弹play 开放平台的
  ///   AppId / AppSecret 两个输入框 + 那枚删除按钮，当次整节移除了。
  /// ★ 2026-10-14（Owner 反馈「凭证流程根本没走通」）：输入框**恢复**，
  ///   但不再挂在这一节里 —— 它独立成 [_credentialsSection]（可门控、带如实
  ///   状态行）。本节现在只剩这一行**只读**的本机探测结果。
  Widget _sourceSection() {
    if (widget.state.sourceLine.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('数据源', note: widget.state.sourceLine),
        const SizedBox(height: Sp.x3),
      ],
    );
  }

  /// Whether the credentials section is shown.
  ///
  /// 2026-10-15: always shown now. It used to be gated on both credential
  /// callbacks being present (because it contained the input boxes), but the
  /// section is read-only status now -- and users must always be able to see
  /// whether built-in credentials are in effect.
  bool get _showCredentialsSection => true;

  /// ★★★ 2026-10-14（Owner）：「凭证」节 —— 两个输入框 + 保存 / 清除 + **如实**状态行
  ///
  /// Owner 原话：> 本地播放提示 [弹幕服务] 没有收到凭证,说明 [弹幕服务] 流程根本没走通
  ///
  /// # 状态行逐字段都从 `DanmakuConfig` 的**真实 getter** 读
  /// ```text
  /// 内置是否可用 ⇒ hasBuiltinCredentials（不是猜"有没有注入"）
  /// 生效的是哪一份 ⇒ usingBuiltinAppId ? 内置 : 用户填写
  /// 两者都没有     ⇒ 明说"官方边会失败"，并给两条**真实存在**的免签名路
  /// ```
  /// 这三档与 [_statusText] 是**两个不同的问题**：[_statusText] 说"弹幕现在
  /// 什么状态"，本节说"凭证这个配置项现在什么情况"。两条都如实、且都不许
  /// 在 UI 里自己拼字符串判断 —— 判据全在 `DanmakuConfig`。
  Widget _credentialsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('凭证', note: '弹弹play'),
        // ── 状态行（如实）──
        Row(
          children: [
            _dot(DanmakuConfig.isConfigured),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                _credentialStatusText,
                style: const TextStyle(
                  color: DanmakuTextColors.secondary,
                  fontSize: FontSizes.sm,
                ),
              ),
            ),
          ],
        ),
        /*
         * 2026-10-15 (Owner): "I told you to delete those two input boxes and
         * use the built-in credentials -- it is still not done."
         *
         * Before deleting, the developer agreement was checked (the Owner
         * asked for that explicitly: "check whether the developer statement
         * allows built-in; if not, keep the input boxes").
         *
         * The official Open Danmaku Network docs, section 7 (Security Notes),
         * say in full:
         *
         *   > Try not to hard-code your AppSecret in a client application.
         *   > If you are developing an open-source client project, you can:
         *   >   - use a placeholder in the open-source code to keep the
         *   >     AppSecret from leaking, then at build time (e.g. with GitHub
         *   >     Actions) read the AppSecret from a secret store and
         *   >     substitute the placeholder.
         *
         * So built-in credentials ARE allowed -- provided they go through
         * "placeholder + build-time injection". That is exactly what this
         * repo already does (String.fromEnvironment in core/danmaku.dart, plus
         * build.yml pulling from GitHub Secrets, plus tools/run_client.ps1 for
         * local builds) => the input boxes can go.
         *
         * The credentials were verified against the live API before deleting
         * anything (a signed request to /api/v2/comment/123450001 returned
         * HTTP 200), so removing the manual entry point does not leave users
         * without a working path.
         *
         * WHAT IS KEPT: the status line below. Users still need to be able to
         * tell whether built-in credentials are in effect or nothing is
         * configured. What was deleted is the INPUT, not the VISIBILITY.
         */
        // When this build has no built-in credentials (local build without
        // --dart-define), say so honestly and point at the paths that work
        // without credentials.
        if (!DanmakuConfig.isConfigured) ...[
          _hint(
            '本构建没有内置凭证，官方边会失败（服务端会回「没收到凭证」）。'
            '改用本机外部弹幕 / 外部视频源弹幕 —— 那两条路**免签名**、不需要凭证。',
          ),
        ],
        if (DanmakuConfig.isConfigured)
          _hint('凭证由客户端内置（官方允许：开源代码放占位符，构建时注入）。无需手填。'),
      ],
    );
  }

  /// 凭证状态的一句话 —— 三档，逐字段读 `DanmakuConfig` 真实 getter。
  String get _credentialStatusText {
    // ① 生效的是**用户填写**的（优先级最高，压过内置）
    if (DanmakuConfig.isConfigured && !DanmakuConfig.usingBuiltinAppId) {
      return '当前生效：用户填写（AppId ${DanmakuConfig.maskedAppId}）';
    }
    // ② 只剩内置可用
    if (DanmakuConfig.usingBuiltinAppId) {
      return '当前生效：内置凭证（AppId ${DanmakuConfig.maskedAppId}）';
    }
    // ③ 内置也没注入（本地构建常见）—— 如实说
    return '未配置凭证';
  }

  Widget _displaySection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('显示', note: '即时生效'),
        _slider(
          '字号',
          s.fontScale,
          DanmakuConfig.fontScaleMin,
          DanmakuConfig.fontScaleMax,
          widget.onSetFontScale,
          '${(s.fontScale * 100).round()}%',
        ),
        _slider(
          '透明度',
          s.opacity,
          DanmakuConfig.opacityMin,
          DanmakuConfig.opacityMax,
          widget.onSetOpacity,
          '${(s.opacity * 100).round()}%',
        ),
        _slider(
          '速度',
          s.speed,
          DanmakuConfig.speedMin,
          DanmakuConfig.speedMax,
          widget.onSetSpeed,
          '${s.speed.toStringAsFixed(1)}s',
        ),
        _hint('一条弹幕从右边缘走到左边缘的秒数（越大越慢）'),
        _slider(
          '显示区域',
          s.area,
          DanmakuConfig.areaMin,
          DanmakuConfig.areaMax,
          widget.onSetArea,
          '${(s.area * 100).round()}%',
        ),
        _hint('弹幕从画面**顶部往下**能占用的高度比例（对齐 某视频站）。'
            '默认 50% = 只占上半屏，下半屏留给画面与字幕；拖到 100% 才铺满全屏。'),
      ],
    );
  }

  /// ★★★ 2026-10-09 新增：屏蔽与分类开关（对齐 某视频站的弹幕设置）
  ///
  /// Owner 原话：「弹幕管理 还要支持指定区域的屏幕不显示 大小 屏蔽 速度 等等,
  ///            这些都参考某视频站的弹幕设置就行了」
  ///
  /// 与上面「显示」那一节的分工：
  /// ```text
  /// 显示  ⇒ 字号/透明度/速度/占用区域（"长什么样"）
  /// 本节点 ⇒ 显示哪几类 + 屏蔽哪些词（"留哪些"）
  /// ```
  /// ⚠️ 与 某视频站的差异：某视频站把"显示类型"和"屏蔽类型"分成两处（容易让人困惑
  ///    为什么同一类要开关两次）。这里合并成一组三态开关：
  ///    关 = 不显示（等价于 某视频站两个开关都关）。
  Widget _filterSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('显示哪些弹幕', note: '即时生效'),
        _typeSwitch('滚动弹幕', DanmakuConfig.showScroll, DanmakuConfig.setShowScroll),
        _typeSwitch('顶部弹幕', DanmakuConfig.showTop, DanmakuConfig.setShowTop),
        _typeSwitch('底部弹幕', DanmakuConfig.showBottom, DanmakuConfig.setShowBottom),
        _hint('关掉某一类 ⇒ 那一类的弹幕不再进入渲染（也不占轨道）'),
        const SizedBox(height: 8),
        _blockWordsHeader(),
        _blockWordsWrap(),
        _blockWordsAddField(),
        const SizedBox(height: Sp.x2),
        _typeSwitch('按正则匹配', DanmakuConfig.blockRegex, DanmakuConfig.setBlockRegex),
        _hint(
          DanmakuConfig.blockRegex
              ? '当前按正则解释（写错了会自动跳过那一条，不会屏蔽全部）'
              : '当前按"包含"匹配（勾上右边开关可改用正则）',
        ),
      ],
    );
  }

  /// 三类弹幕的显示开关
  /// 三类弹幕的显示开关 + 「按正则匹配」
  ///
  /// ★ 2026-10-15：与 `_switchSection()` 统一成 `SwitchListTile`
  ///   （原来这里是手写 Row + Switch）。四处开关现在**同一套布局**：
  ///   文字在左、开关在右、整行可点、带涟漪与读屏语义。
  Widget _typeSwitch(String label, bool value, void Function(bool) set) {
    return _switchRow(
      label: label,
      value: value,
      onChanged: (v) {
        set(v);
        // 立刻重建对话框，让开关与渲染同步（父层也会收到回调）
        widget.onChanged?.call();
      },
    );
  }

  // =====================================================================
  //  2026-10-15 (Owner): "danmaku blocking does not support search, and
  //  one-word-per-line wastes far too much space."
  // =====================================================================
  //
  // BEFORE: one multi-line TextField (maxLines 4 / minLines 3), one word per
  // line.  - words beyond the 4th were hidden behind a scroll
  //        - no search, so deleting one word meant scanning the whole blob
  //        - every keystroke rewrote the entire preference string
  //
  // AFTER, in three parts:
  //   1. search box      -- only appears when there are many words
  //   2. chip wrap       -- a dozen+ words visible at once, tap x to delete
  //   3. add field       -- type a word, press Enter
  //
  // NOTE: the underlying storage is UNCHANGED -- still the newline-separated
  // string under dsh.danmaku.blockWords. Existing user preferences keep
  // working with no migration, and DanmakuConfig.blockWords still does the
  // trim/dedupe parsing. This only changes the editing surface.

  /// Below this many words there is no point showing a search box.
  ///
  /// Most people block two or three words (e.g. 剧透 / 前方高能); adding a
  /// search field for those just takes up space when everything is visible
  /// at a glance anyway.
  static const int _kBlockSearchMinWords = 9;

  Widget _blockWordsHeader() {
    final words = DanmakuConfig.blockWords;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('屏蔽词', note: '${words.length} 个'),
        if (words.length >= _kBlockSearchMinWords)
          Padding(
            padding: const EdgeInsets.only(bottom: Sp.x2),
            child: TextField(
              controller: _blockSearch,
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.sm,
              ),
              decoration: InputDecoration(
                hintText: '搜索屏蔽词（共 ${words.length} 个）',
                prefixIcon: const Icon(Icons.search, size: 18),
                suffixIcon: _blockSearch.text.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: '清除搜索',
                        onPressed: () => setState(_blockSearch.clear),
                      ),
                border: const OutlineInputBorder(),
                isDense: true,
              ),
              onChanged: (_) => setState(() {}),
            ),
          ),
      ],
    );
  }

  /// The words currently shown (filtered by the search box when non-empty).
  List<String> get _visibleBlockWords {
    final all = DanmakuConfig.blockWords;
    final q = _blockSearch.text.trim().toLowerCase();
    if (q.isEmpty) return all;
    return all.where((w) => w.toLowerCase().contains(q)).toList();
  }

  /// Chip wrap -- a dozen+ words visible at once, tap x to delete.
  Widget _blockWordsWrap() {
    final all = DanmakuConfig.blockWords;
    final shown = _visibleBlockWords;
    if (all.isEmpty) {
      return _hint('还没有屏蔽词。在下面的框里输入，回车即可添加。');
    }
    if (shown.isEmpty) {
      return _hint('没有匹配「${_blockSearch.text.trim()}」的屏蔽词。');
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Wrap(
        spacing: Sp.x1,
        runSpacing: Sp.x1,
        children: [
          for (final w in shown)
            InputChip(
              /*
               * ⚠️ The TextStyle MUST carry a colour. `t27_w1_danmaku_contrast_test`
               * scans the source for `TextStyle(` without `color:`/`foreground:` and
               * fails on it -- a style with no colour silently inherits the theme's
               * default, which on this dark panel can end up unreadable.
               * `labelStyle` below sets the colour too; this one is the label's own
               * override and has to stand on its own.
               */
              label: Text(
                w,
                style: const TextStyle(
                  color: DanmakuTextColors.body,
                  fontSize: 12,
                ),
              ),
              /*
               * ★★ 2026-10-16（Owner 实测截图：「屏蔽词」下面的药丸看不清）
               *
               * 改前 `labelStyle` 是 muted 而 `backgroundColor` 是
               * `Colors.transparent` ⇒ 药丸**没有自己的底**，直接露出分组卡片的
               * 浅底；而「1 个」这种计数与药丸挤在同一行时，整体就是一片浅灰
               * ⇒ 药丸与文字都糊在一起。
               *
               * ⇒ 三处都收到 `DanmakuTextColors` 既有灰阶上：
               *     药丸底  border @35%（比分组卡片略抬一档 ⇒ 看得出是个`药丸`）
               *     描边    border（与分组卡片同一支灰，1.6:1 装饰线）
               *     文字    body #E6E6E6（14.5:1，t27_w1 门禁钉着）
               *     ✕       secondary #B9BEC6（9.7:1）
               * ⚠️ 面板强制深色 ⇒ 一律不引 colorScheme（见外壳 forceDarkCard）。
               */
              labelStyle: const TextStyle(color: DanmakuTextColors.body),
              deleteIcon: const Icon(
                Icons.close,
                size: 14,
                color: DanmakuTextColors.secondary,
              ),
              // Delete by exact value (shown holds the original strings).
              onDeleted: () => _removeBlockWord(w),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              side: const BorderSide(color: DanmakuTextColors.border),
              backgroundColor: DanmakuTextColors.border.withValues(alpha: 0.35),
            ),
        ],
      ),
    );
  }

  /// Append one word, keeping the newline-separated storage format intact.
  void _addBlockWord(String raw) {
    final w = raw.trim();
    if (w.isEmpty) return;
    final all = DanmakuConfig.blockWords;
    // Already present => do not add twice (blockWords dedupes on read anyway,
    // this just avoids making the user think something happened).
    if (all.contains(w)) return;
    DanmakuConfig.setBlockWords('${all.join('\n')}\n$w');
    widget.onChanged?.call();
  }

  /// Remove one word by EXACT match -- not substring.
  ///
  /// Substring deletion would make removing 剧透 also remove 剧透警告, which
  /// the user did not ask for.
  void _removeBlockWord(String w) {
    final all = DanmakuConfig.blockWords.where((x) => x != w).toList();
    DanmakuConfig.setBlockWords(all.join('\n'));
    widget.onChanged?.call();
  }

  /// Add field (Enter or the plus button appends).
  ///
  /// NOTE: the controller is held by the State (see [_blockWords]) -- do NOT
  /// create it in build. A fresh controller each build makes the field show
  /// the normalized preference value forever, so users cannot type anything.
  Widget _blockWordsAddField() {
    return Row(
      children: [
        Expanded(
          child: TextField(
            /*
             * Stable key for tests. Before the 2026-10-15 redesign the block
             * word box was the panel's only maxLines==4 EditableText, so tests
             * found it by that property. The redesign turned it into a set of
             * chips plus this one-line add field, so the old finder matches
             * nothing. Keying the field keeps the lookup unambiguous without
             * pinning a layout detail that may change again.
             */
            key: blockWordsAddFieldKey,
            controller: _blockWords,
            style: const TextStyle(
              color: DanmakuTextColors.muted,
              fontSize: FontSizes.sm,
            ),
            decoration: const InputDecoration(
              hintText: '添加屏蔽词，回车确认',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            onSubmitted: (v) {
              _addBlockWord(v);
              _blockWords.clear();
              setState(() {});
            },
          ),
        ),
        const SizedBox(width: Sp.x1),
        IconButton(
          tooltip: '添加',
          icon: const Icon(Icons.add, size: 20),
          onPressed: () {
            _addBlockWord(_blockWords.text);
            _blockWords.clear();
            setState(() {});
          },
        ),
      ],
    );
  }

  Widget _slider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged,
    String readout,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: Sp.x2),
      child: Row(
        children: [
          SizedBox(
            width: 84,
            child: Text(
              label,
              style: const TextStyle(
                color: DanmakuTextColors.secondary,
                fontSize: FontSizes.sm,
              ),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 52,
            child: Text(
              readout,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.cap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 搜索区是否显示 —— 两个回调**都在**才画。
  ///
  /// 只给 `onSearch` 会出现「结果列表画得出来、点一条却没反应」的假 UI；
  /// 只给 `onPickMatch` 则连搜索框都没有、列表永远是空的。两头都是残废形态，
  /// 所以门控取"与"。
  bool get _showSearchSection =>
      widget.onSearch != null && widget.onPickMatch != null;

  Widget _requestSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('请求'),
        /*
         * ★★★ 2026-10-14（Owner 第 2 条）：「外部弹幕…」降一层
         *
         * # Owner 原话（逐字）
         * ```text
         * > [外部]弹幕搜索绑定交互太麻烦
         * ```
         *
         * # 改前要三层才摸得到
         * ```text
         * 齿轮 → 轻量悬浮窗「高级设置」 → 全屏卡片里那颗「外部弹幕…」
         * 最坏 6 次交互（开 popover、点高级设置、点按钮、再搜索、再选、再绑）。
         * ```
         * # 现在：它就在面板第一屏的「请求」节里
         * ```text
         * 齿轮 → 轻量悬浮窗「高级设置」 → 全屏卡片 → 「外部弹幕…」 ← 少一层
         * 而且它与旁边的「重新获取弹幕」**同层同权重**（都是弹幕相关动作），
         * 不再藏在"高级"里 —— 弹幕的事本来就该在弹幕面板里一眼可见。
         * ```
         *
         * ⚠️ **只改位置，不改能力**：`onOpenBili` 与 `BiliImportDialog`
         *    一字未动（既有 t73/t100 那几条测试照旧跑）。
         */
        Row(
          children: [
            TextButton.icon(
              onPressed: s.loading ? null : widget.onReload,
              icon: const Icon(Icons.refresh, color: DanmakuTextColors.body, size: 18),
              label: const Text(
                '重新获取弹幕',
                style: TextStyle(color: DanmakuTextColors.body),
              ),
            ),
            if (s.loading) ...[
              const SizedBox(width: Sp.x3),
              const SizedBox(
                width: 16,
                height: 16,
                // T27-07：显式给色 —— body #E6E6E6 对面板底 #14161B ≥4.5:1（t27_w1 钉过）。
                child: CircularProgressIndicator(
                  color: DanmakuTextColors.body,
                  strokeWidth: 2,
                ),
              ),
            ],
            if (widget.onOpenBili != null) ...[
              const SizedBox(width: Sp.x3),
              TextButton.icon(
                onPressed: widget.onOpenBili,
                icon: const Icon(
                  Icons.play_circle_outline,
                  color: DanmakuTextColors.body,
                  size: 18,
                ),
                label: const Text(
                  '外部弹幕…',
                  style: TextStyle(color: DanmakuTextColors.body),
                ),
              ),
            ],
          ],
        ),
        _hint(
          '当前片源没有本地文件（播放的是流地址），拿不到文件哈希，'
          '所以只用片名去匹配 —— 匹配不到时会自动退到按番剧名 + 集数搜索。'
          '自动匹配总是不中时，用下面的「搜索番剧」手动指定。',
        ),
      ],
    );
  }

  /// ★★★ 2026-10-14（Owner）：「搜索番剧」—— 手动搜索 + 选中即载入
  ///
  /// Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  ///
  /// # 后端早就有了，缺的只是这层 UI
  /// ```text
  /// 客户端那侧的 `searchEpisodes()`（core/danmaku.dart）是**真 HTTP**
  /// （`GET /api/v2/search/episodes`），返回 `List<DanmakuMatch>`（番剧名 + 集名 + episodeId）；
  /// 但全仓**没有一个 UI 调它** ⇒ 用户只能等 `loadFor()` 自动匹配。
  /// 本区就是那层 UI：搜索 → 列结果 → 点一条 → 宿主用它的 episodeId 取弹幕。
  /// ```
  ///
  /// # 四种状态都要有**明确**的显示（空/载入/失败/有结果）
  /// ```text
  /// 载入中 ⇒ 一行「正在搜索…」+ 转圈（按钮同时禁用，防连点）
  /// 失败   ⇒ 沿用 `searchError.message` 的**真实原文**（不翻译成"网络错误"）
  /// 空结果 ⇒ 明确空态文案「没搜到，换个关键词试试」——空白会让人以为没反应
  /// 有结果 ⇒ 每条一行（番剧名 + 集名 + 库#id），点一条即载入
  /// ```
  Widget _searchSection() {
    final s = widget.state;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('搜索番剧', note: '手动指定要哪一集'),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: TextField(
                controller: _searchKeyword,
                style: const TextStyle(
                  color: DanmakuTextColors.body,
                  fontSize: FontSizes.sm,
                ),
                decoration: const InputDecoration(
                  hintText: '番剧名 / 关键词',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                // 回车 = 点「搜索」（键盘用户少摸一次鼠标）
                onSubmitted: (v) => _submitSearch(v),
              ),
            ),
            const SizedBox(width: Sp.x2),
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: FilledButton.icon(
                // 载入中禁用 ⇒ 防连点（同时也把"正在搜"这件事画在按钮上）
                onPressed:
                    s.searchLoading ? null : () => _submitSearch(_searchKeyword.text),
                icon: s.searchLoading
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          color: DanmakuTextColors.body,
                          strokeWidth: 2,
                        ),
                      )
                    : const Icon(Icons.search, size: 18),
                label: const Text('搜索'),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        // 关键词来自宿主最近一次搜索 ⇒ 把它回填进输入框
        // （用户在别处改了关键字 / 面板重开时，输入框要跟上；本地输入时
        //  两者相同 ⇒ 不打断光标）
        if (s.searchKeyword.isNotEmpty && s.searchKeyword != _searchKeyword.text)
          _syncKeyword(s.searchKeyword),
        _searchResultBody(s),
      ],
    );
  }

  /// 把宿主的关键词同步进输入框（见调用点注释：只在两者不同时才写）
  Widget _syncKeyword(String kw) {
    // ⚠️ 不能在 build 里直接改 controller（会触发 "setState during build"）⇒
    //    排到这一帧之后（addPostFrameCallback）。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _searchKeyword.text != kw) {
        _searchKeyword.text = kw;
      }
    });
    return const SizedBox.shrink();
  }

  void _submitSearch(String raw) {
    final kw = raw.trim();
    if (kw.isEmpty) return; // 空关键词不发请求（后端空搜必然搜不到，白跑一趟）
    widget.onSearch?.call(kw);
  }

  /// 搜索结果的四种状态显示
  Widget _searchResultBody(DanmakuSettingsState s) {
    if (s.searchLoading) {
      return _hint('正在搜索…');
    }
    final err = s.searchError;
    if (err != null) {
      return Text(
        '搜索失败：${err.message}',
        style: const TextStyle(color: Colors.orangeAccent, fontSize: FontSizes.sm),
      );
    }
    if (!s.searchSearched) {
      return _hint('输入番剧名或关键词后点「搜索」，从结果里点一集即可载入它的弹幕');
    }
    if (s.searchResults.isEmpty) {
      return _hint('没搜到，换个关键词试试');
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (s.searchStale) ...[
          const SizedBox(height: Sp.x1),
          // 见 `DanmakuSettingsState.searchStale` 的长注释：错位是真缺陷，
          // 必须显式告诉用户"这一批结果已经对不上了"。
          const Text(
            '搜索期间画面已换集，这批结果可能对不上 —— 建议重新搜索',
            style: TextStyle(color: Colors.orangeAccent, fontSize: FontSizes.cap),
          ),        ],
        const SizedBox(height: Sp.x1),
        for (final m in s.searchResults) _matchTile(m, s.searchStale),
        /*
         * 2026-10-15 (Owner): batch binding.
         *
         * Placed right under the result list because that is where the user
         * has just decided WHICH work this is.  Asking them to bind 12
         * episodes one at a time after that is busywork -- the results are
         * the same every time, only the episode number changes.
         *
         * Only shown when there is something to batch, and only when the host
         * actually wired the callback (same gating rule as every other action
         * in this panel: no callback, no button).
         */
        if (widget.onBatchBind != null) ...[
          const SizedBox(height: Sp.x2),
          TextButton.icon(
            onPressed: () => widget.onBatchBind!(s.searchResults),
            icon: const Icon(
              Icons.playlist_add_check,
              color: DanmakuTextColors.body,
              size: 18,
            ),
            label: const Text(
              '整部绑定',
              style: TextStyle(color: DanmakuTextColors.body),
            ),
          ),
        ],
      ],
    );
  }

  /// 结果列表里的一条 —— 点它 ⇒ 载入这一集的弹幕
  Widget _matchTile(DanmakuMatch m, bool stale) {
    final title = m.animeTitle.isNotEmpty ? m.animeTitle : '未命名作品';
    final ep = m.episodeTitle.isNotEmpty ? m.episodeTitle : '未命名剧集';
    return InkWell(
      // stale 时**仍然可点**（用户可能有自己的判断），但那一行的文字已经
      // 标了"可能对不上" ⇒ 是知情选择，不是误点。
      onTap: () => widget.onPickMatch?.call(m),
      borderRadius: Radii.rSm,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: Sp.x1),
        padding: const EdgeInsets.symmetric(
          horizontal: Sp.x3,
          vertical: Sp.x2,
        ),
        decoration: BoxDecoration(
          borderRadius: Radii.rSm,
          border: Border.all(color: DanmakuTextColors.border),
          color: stale
              ? null
              : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.03),
        ),
        child: Row(
          children: [
            /*
             * 2026-10-15 (Owner: "I remember it could show covers? see if you
             * can.") -- yes it can, via /api/v2/bangumi/{animeId}.
             *
             * The poster is 2:3, so the box is 2:3 (28x42).  That ratio
             * matters: coverImage() picks cacheHeight based on layoutHeight,
             * and ResizeImage keeps the aspect ratio, so a 2:3 box decodes a
             * 2:3 thumbnail rather than scaling a 16:9 still down.
             *
             * cover == '' means the lookup failed (offline, unknown work, or
             * the request was swallowed on purpose so search still works) =>
             * fall back to a neutral placeholder rather than an empty gap,
             * so the rows keep a consistent baseline.
             */
            SizedBox(
              width: 28,
              height: 42,
              child: m.cover.isEmpty
                  ? Container(
                      decoration: BoxDecoration(
                        borderRadius: Radii.rSm,
                        border: Border.all(color: DanmakuTextColors.border),
                      ),
                      child: const Icon(
                        Icons.movie_outlined,
                        size: 14,
                        color: DanmakuTextColors.muted,
                      ),
                    )
                  : ClipRRect(
                      borderRadius: Radii.rSm,
                      child: coverImage(
                        context,
                        url: m.cover,
                        layoutWidth: 28,
                        layoutHeight: 42,
                        fit: BoxFit.cover,
                        // A broken poster URL must not blow up the row.
                        errorBuilder: (_, __, ___) => Container(
                          decoration: BoxDecoration(
                            borderRadius: Radii.rSm,
                            border:
                                Border.all(color: DanmakuTextColors.border),
                          ),
                          child: const Icon(
                            Icons.movie_outlined,
                            size: 14,
                            color: DanmakuTextColors.muted,
                          ),
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DanmakuTextColors.body,
                      fontSize: FontSizes.sm,
                    ),
                  ),
                  Text(
                    ep,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: DanmakuTextColors.muted,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Sp.x2),
            // 库 id 对用户没意义，但排错时要能说清"载的是哪一条"⇒ 弱化显示
            Text(
              '#${m.episodeId}',
              style: const TextStyle(
                color: DanmakuTextColors.muted,
                fontSize: FontSizes.cap,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 中文可操作指引（Owner 第 1 条）—— 原文照旧留在 [_errorSection] 里
  ///
  /// 文案与动作**全部**来自 `core/danmaku.dart` 的 `DanmakuHint`
  /// （纯函数，有单测钉住），这里只负责画，不做任何判断 ——
  /// 判断散到 UI 里就会与库侧的判据漂移。
  Widget _hintSection(DanmakuHint h) {
    final a = h.action;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.info_outline, size: 18, color: DanmakuTextColors.muted),
            const SizedBox(width: Sp.x2),
            Flexible(
              child: Text(
                h.title,
                style: const TextStyle(
                  color: DanmakuTextColors.body,
                  fontSize: FontSizes.base,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: Sp.x2),
        Text(
          h.text,
          style: const TextStyle(color: DanmakuTextColors.secondary, fontSize: FontSizes.sm),
        ),
        if (h.url.isNotEmpty) ...[
          const SizedBox(height: Sp.x2),
          SelectableText(
            h.url,
            style: const TextStyle(
              color: Colors.lightBlueAccent,
              fontSize: FontSizes.cap,
            ),
          ),
        ],
        if (a != null && widget.onHintAction != null) ...[
          const SizedBox(height: Sp.x3),
          FilledButton.icon(
            onPressed: () => widget.onHintAction!(a),
            icon: const Icon(Icons.settings, size: 18),
            label: Text(a.label),
          ),
        ],
      ],
    );
  }

  /// 服务端返回的原文 —— **一个字都不改写**（这是排错的唯一线索）
  Widget _errorSection(DanmakuException e) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle('服务端返回'),
        Text(
          e.message,
          style: const TextStyle(
            color: Colors.orangeAccent,
            fontSize: FontSizes.sm,
          ),
        ),
        const SizedBox(height: Sp.x2),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(Sp.x3),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: Radii.rSm,
            border: Border.all(color: DanmakuTextColors.border),
          ),
          child: Text(
            e.detail,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: FontSizes.cap,
              color: DanmakuTextColors.secondary,
            ),
          ),
        ),
        if (e.isAuthProblem)
          _hint(
            '这是凭证问题。可行的几步（按代价从低到高）：'
            '改用本机外部弹幕（免签名）或 外部视频源弹幕；'
            '或在上面的「凭证」节填一对 AppId / AppSecret 并保存，'
            '再点「重新获取弹幕」。',
          ),
      ],
    );
  }
}
