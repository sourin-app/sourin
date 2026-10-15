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
import '../tokens.dart';
import 'cover_image.dart';
import 'overlay_motion.dart';

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
    this.fill = true,
  });

  final DanmakuSettingsState state;

  /// Live readout channel (null => fall back to the static values on state).
  ///
  /// 2026-10-15: split out so the host no longer needs setState once per
  /// second just to refresh one line of text (see DanmakuReadout).
  final ValueListenable<DanmakuReadout>? readout;

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
  void dispose() {
    _blockWords.dispose();
    _blockSearch.dispose();
    _searchKeyword.dispose();
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
    final body = GestureDetector(
      // 点背景关闭（与播放页其它面板一致）
      onTap: widget.onClose,
      // ★ task-99：遮罩**淡入**（原来是一帧硬切 —— Owner 说的「生硬」）
      //   颜色/覆盖范围一字不改，动画结束后 Opacity 恒为 1.0。
      child: OverlayScrim(
        color: Colors.black.withValues(alpha: 0.72),
        child: Center(
          child: GestureDetector(
            // 卡片内部的点击不能穿透到背景（否则点滑块也会关掉面板）
            onTap: () {},
            // ★ task-99：卡片**淡入 + 轻微上浮**（24px，Motion.base）
            child: OverlayCardMotion(
              child: Container(
                width: 560,
                constraints: const BoxConstraints(maxHeight: 620),
                decoration: BoxDecoration(
                  color: DanmakuTextColors.panelBg.withValues(alpha: 0.98),
                  borderRadius: Radii.rLg,
                  border: Border.all(color: DanmakuTextColors.border),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _header(),
                    Flexible(
                      child: SingleChildScrollView(
                        clipBehavior: Clip.antiAlias,
                        padding: const EdgeInsets.fromLTRB(
                          Sp.x6,
                          0,
                          Sp.x6,
                          Sp.x4,
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            _statusSection(),
                            _divider(),
                            // ★ 「数据源」状态行（T27-05）—— 原来是凭证节的一部分，
                            //   凭证输入框整节删掉后单独保留（只读状态，与凭证无关）。
                            //   sourceLine 为空时 _sourceSection() 返回 SizedBox.shrink()。
                            _sourceSection(),
                            _divider(),
                            _switchSection(),
                            _divider(),
                            /*
                             * ★★★ 2026-10-14（Owner）：「凭证」节 —— 恢复输入框
                             *
                             * Owner 原话：> 本地播放提示 [弹幕服务] 没有收到凭证,
                             *            说明 [弹幕服务] 流程根本没走通
                             *
                             * 排在「显示」之上、紧接开关 —— 没配凭证时它是
                             * 用户最先要做的一件事；配好之后就退成一块普通设置
                             * （状态行会如实说"当前用的是内置/用户填写"）。
                             *
                             * 回调没接时整节不画（与搜索区同一条门控）。
                             */
                            if (_showCredentialsSection) ...[
                              _credentialsSection(),
                              _divider(),
                            ],
                            _displaySection(),
                            _divider(),
                            _filterSection(),
                            _divider(),
                            _requestSection(),
                            /*
                             * ★★★ 2026-10-14（Owner）：「手动搜索番剧」
                             *
                             * Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
                             *
                             * 紧跟在「请求」下面 —— 两节是同一件事的两半：
                             * 「请求」= 让程序自己去找（自动匹配），
                             * 本节    = 用户**手动**指定要哪一集。
                             * 自动匹配不中时，用户顺着往下看就能找到手动的路。
                             */
                            if (_showSearchSection) ...[
                              _divider(),
                              _searchSection(),
                            ],
                            /*
                               * ★★ Owner 第 1 条：把 403/401 翻成**能照着做**的中文
                               *
                               * 位置有讲究：排在「服务端返回」**上面** ——
                               * 原文（Missing Authentication Headers）是证据，
                               * 中文指引是结论；用户先看到结论才知道证据在说什么。
                               */
                            if (s.error?.hint != null) ...[
                              _divider(),
                              _hintSection(s.error!.hint!),
                            ],
                            if (s.error != null) ...[
                              _divider(),
                              _errorSection(s.error!),
                            ],
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    // ★ 默认形态与改前**逐像素相同**（只多一个局部变量）
    return widget.fill ? Positioned.fill(child: body) : body;
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
  Widget _header() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x6, Sp.x4, Sp.x3, Sp.x2),
      child: Row(
        children: [
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  '弹幕设置',
                  style: TextStyle(
                    color: DanmakuTextColors.body,
                    fontSize: FontSizes.lg,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                SizedBox(height: Sp.x1),
                Text(
                  '显示 / 过滤 / 请求',
                  style: TextStyle(
                    color: DanmakuTextColors.muted,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: DanmakuTextColors.body),
            tooltip: '关闭',
          ),
        ],
      ),
    );
  }

  Widget _divider() => const Padding(
    padding: EdgeInsets.symmetric(vertical: Sp.x4),
    child: Divider(height: 1, color: DanmakuTextColors.border),
  );

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

  Widget _switchSection() {
    return Row(
      children: [
        Switch(value: widget.state.enabled, onChanged: widget.onSetEnabled),
        const SizedBox(width: Sp.x2),
        const Expanded(
          child: Text(
            '显示弹幕',
            style: TextStyle(color: DanmakuTextColors.secondary, fontSize: FontSizes.sm),
          ),
        ),
      ],
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
  Widget _typeSwitch(String label, bool value, void Function(bool) set) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          Expanded(
            child: Text(label, style: const TextStyle(color: DanmakuTextColors.muted, fontSize: 13)),
          ),
          Switch(
            value: value,
            onChanged: (v) {
              set(v);
              // 立刻重建对话框，让开关与渲染同步（父层也会收到回调）
              widget.onChanged?.call();
            },
          ),
        ],
      ),
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
                fontSize: 13,
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
              label: Text(w, style: const TextStyle(fontSize: 12)),
              labelStyle: const TextStyle(color: DanmakuTextColors.muted),
              deleteIcon: const Icon(Icons.close, size: 14),
              // Delete by exact value (shown holds the original strings).
              onDeleted: () => _removeBlockWord(w),
              visualDensity: VisualDensity.compact,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              side: const BorderSide(color: DanmakuTextColors.border),
              backgroundColor: Colors.transparent,
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
              fontSize: 13,
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
          color: stale ? null : Colors.white.withValues(alpha: 0.02),
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
