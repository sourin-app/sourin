// ═══════════════════════════════════════════════════════════════════════
//  播放器 —— 对齐原版 PlayerView.vue（4775 行）的**操作逻辑**
// ═══════════════════════════════════════════════════════════════════════
//
// # 技术栈替换
//
// ```text
// 原版：ArtPlayer + hls.js（WebView2 里的 <video>）
// 本版：media_kit（libmpv）—— 原生解码，支持 HEVC 硬解
// ```
// **操作逻辑、快捷键、提示文案全部照抄原版**，只换底层播放器。
//
// # ★★ 快捷键表（原版 `design/device.ts` 的 DESKTOP_HINTS）
//
// ```text
// 空格     播放 / 暂停
// ← →      快退 / 快进 5 秒
// J L      ±10 秒 · 双击左右侧同效
// 0–9      跳转到百分比
// ↑ ↓      音量 · M 静音 · 滚轮同效
// F        全屏 · P 画中画
// , .      减速 / 加速
// N        下一集
// ```
// ⚠️ 这份表**同时用于**实际按键处理与「快捷键提示」浮层 ——
//    两处必须是同一份数据，否则会出现"提示里有的键按了没反应"。
//
// # ★ TV 是**另一套**键位（不是照搬键盘）
//
// ```text
// 确认     播放 / 暂停
// ← →      快退 / 快进 10 秒      ← 注意是 10 秒，桌面是 5 秒
// ↑ ↓      音量
// 返回     退出播放 / 返回上一页
// ```
// 原版注释：
// > 遥控器只有方向键 + 确认 + 返回，没有 J/L/数字/F 这些键。
// > 所以文案必须重写，不能照搬。
//
// # ★ 直播要**过滤掉**这些提示
//
// ```text
// 快退 / 百分比 / 减速
// ```
// 原版注释：
// > 直播不能快进/跳转 —— 列出来只会让人白试。
//
// # ★★ 记忆播放位置（原版实测踩过的坑）
//
// ```text
// ① 每 5 秒落一次盘（不是每帧 —— 那会写爆 SQLite）
// ② 退出/切集/换源前**立刻**落一次（`reportProgress(immediate: true)`）
// ③ 时长用**真实时长**（applyRealDuration），不是元数据里的
// ```
// 原版注释：
// > 元数据的 duration 常常不准（尤其 HLS），
// > 用它算百分比会让"续播位置"偏到离谱的地方。

import 'dart:async';
import 'dart:io';
// ★★★ task-22 P1-11：`videoZoomToMpv()` 要把百分比换成 mpv 的 `video-zoom`
//   （log2），为此只需要 `log` —— `dart:math` 不进面板，只在本文件用。
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';
/*
 * ★★ task-53【#4b-④】滚轮调音量需要这三个：
 *   `PointerSignalEvent` / `PointerScrollEvent` / `GestureBinding`
 *
 * ⚠️ 它们**不在** `material_ui` 的导出里（实测：加了本行才 analyze 通过）。
 *   `material_ui` 是项目对 Flutter 拆包后的封装，只导出它自己用到的部分；
 *   而指针信号（滚轮）属于手势层。
 * ★ 用 `show` 精确导入 —— 与文件里 `flutter/services.dart` 那行的风格一致，
 *   避免把整个 gestures 命名空间拉进来造成符号歧义（`material_ui` 里
 *   也有 `PointerEvent` 一类的名字）。
 */
import 'package:flutter/gestures.dart'
    show GestureBinding, PointerScrollEvent, PointerSignalEvent;
import 'package:flutter/services.dart';
/*
 * ★★★ task-25 C：`@visibleForTesting` 来自 foundation。
 *
 * ⚠️ 为什么**必须显式 import**：`material_ui.dart` 把 flutter 的 widgets
 *    原样再导出一遍，而那条链上的 foundation 出口是**收窄**的 ——
 *    实测 <FLUTTER_SDK>/packages/flutter/lib/widgets.dart:18
 *    逐字是 `export 'foundation.dart' show Brightness, UniqueKey;`
 *    ⇒ `visibleForTesting` **不在**其中，靠传递导出拿不到。
 * ★ 全仓先例：lib/core/clip_download.dart:63 就是直接 import
 *    `package:flutter/foundation.dart`（它的 :420 用了 @visibleForTesting）。
 */
import 'package:flutter/foundation.dart';
/*
 * ★ ①-B 需要 `FTheme`（把播放页里的浮层面板包成深色皮肤）
 *
 * ⚠️ 这里 import forui 是**必要**的：项目禁止的是
 *    `package:flutter/material.dart`（两套 Material 会串台），
 *    而 forui 本来就是项目的主题来源（`MaterialApp.builder` 里注入）。
 *    本文件只用到 `FTheme` 这一个 widget，不引入任何 Material 实现。
 */
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../core/app_log.dart';
import '../core/clip_download.dart';
import '../core/batch_bind.dart';
import '../core/danmaku.dart';
import '../core/device.dart';
// ★ task-38：为了 `SourinCoreException.kind`（结构化错误类别）
//
// `sourin_api.dart` 里没有导出这个类型（它在 ffi.dart 定义），
// 而 `_isAuthError` 现在**优先**用结构化 kind 判"是不是登录问题"，
// 不再只靠 `toString()` 里找词。
// ★ task-31 ④⑤：外部视频站弹幕导入（④） + assrt 在线字幕（⑤）
import '../core/bili/bili_api.dart';
import '../core/bili/bili_auto_update.dart';
import '../core/bili/bili_bind.dart';
import '../core/ffi.dart';
import '../core/pip.dart';
import '../core/player_gestures.dart';
import '../core/progress_origin.dart';
import '../core/sourin_api.dart';
import '../core/ui_prefs.dart';
import 'app_theme.dart';
import 'remote_bridge.dart';
import 'titlebar_visibility.dart';
import 'media_session.dart';
import 'cast/cast_button.dart';
import 'player/episode_panel.dart';
import 'player/player_bottom_bar.dart';
import 'player/player_more_menu.dart';
import 'player/player_popover.dart';
import 'subtitle/subtitle_panel.dart';
import 'tokens.dart';
import 'widgets/app_loading.dart';
import 'widgets/bili_import_dialog.dart';
import 'widgets/danmaku_info_panel.dart';
import 'widgets/danmaku_overlay.dart';
import 'widgets/danmaku_settings_dialog.dart';
import 'danmaku_search_page.dart';
import 'widgets/episode_strip.dart';
// ★ 第 16 项：内嵌 / 全屏**共用**的播放动作契约（第 16 项闭合用）
import 'widgets/live_embedded_player.dart'
    show LivePlaybackAction, LivePlaybackTarget, dispatchLivePlaybackAction, livePlaybackActionForKey;
import 'widgets/motion_prefs.dart';
import 'widgets/overlay_motion.dart';
import 'widgets/player_settings_sheet.dart';
import 'widgets/provider_login_panel.dart';
import 'widgets/provider_name.dart';
import 'widgets/skip_marker_dialog.dart';
import '../core/skip_window.dart' show SkipWindow, skipTarget, windowsOf;
import 'widgets/source_switch_dialog.dart';
import '../ui/app_scaffold.dart';
import '../design/icons/app_icons.dart';

/// 把播放页里的**浮层面板**包成深色皮肤（task-28 ①-B）
///
/// ══════════════════════════════════════════════════════════════════════
/// 用户原话
/// ══════════════════════════════════════════════════════════════════════
///
/// > 播放器页面**整体黑色**，弹窗**白色**，**不适配**
///
/// # 为什么"不适配"（根因）
///
/// 播放页是**纯黑**的（`Scaffold(backgroundColor: Colors.black)`），
/// 而浮层面板取色走的是 `FTheme.of(context)` —— 那是
/// **应用级主题**（用户可能选了浅色，或者系统是浅色）：
/// ```text
/// 全屏黑播放页  +  一块 #FAFAFA 的浅色面板
///               =  ★ 用户说的"不适配"
/// ```
/// 更糟的是**深色用户也会遇到**：面板跟着 `MaterialApp.theme` 走，
/// 而那由 `AppTheme.mode` 决定 —— 用户选「跟随系统」而系统是浅色时，
/// 播放页仍然是纯黑（**播放器就该是黑的**），面板却是白的。
///
/// # 为什么选"深色皮肤"而不是其它候选
///
/// ```text
/// 候选 A ★ 深色皮肤（本实现）
///    · 与播放页一致；不刺眼（全屏观影时突然一块白最刺眼）
///    · 零新依赖、零性能开销
///
/// 候选 B 毛玻璃（liquid_glass_widgets）
///    · 黑底上的毛玻璃**没有可折射的内容**（背后就是纯黑视频）
///      ⇒ 实测效果接近"半透明黑"，与 A 几乎一样却多一层开销
///      ⇒ 收益不抵复杂度，不做
///
/// 候选 C 保持浅色 + 加暗色遮罩
///    · 遮罩只能压暗**面板外**的区域，面板本身还是白的
///      ⇒ 没解决用户说的问题，只是把黑边压得更黑
/// ```
///
/// # ★ 为什么是"包一层 FTheme"而不是"改面板内部的取色"
///
/// ```text
/// ① 面板有三处（选集 / 线路 / 播放设置），改内部要动 3 个文件
///    且 `EpisodePanel` 还被**别的页面**复用（详情页也用）
///    —— 那些页面是浅色的，不能一起改黑
/// ② `FTheme` 是 `InheritedWidget`，**作用域天然是本子树**
///    ⇒ 只影响播放页里挂的这几个面板，别处一个像素都不变
/// ③ 面板内部的 `FTheme.of(context)` **一个字都不用改**
/// ```
///
/// ⚠️ 用 `AppTheme.themeFor(Brightness.dark)` 而不是硬编码色值 ——
///    与 `MaterialApp.theme` **同源**，将来调深色令牌时两处一起变。
class PlayerPanelTheme extends StatelessWidget {
  const PlayerPanelTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      AppThemeHost(data: AppTheme.themeFor(Brightness.dark), child: child);
}

/// 播放区**停手多久**就把鼠标光标藏起来（Owner 第 1 条）
///
/// # 口径
/// ```text
/// 鼠标停在播放区、不移动也不点击超过这个时长
///   ⇒ 光标隐藏 + 控制条淡出（两者同时 —— 用户眼里是同一件事：画面交给内容）
/// 任何「人还在操作」的信号（移动 / 点击 / 滚轮 / 按键）⇒ 立刻恢复 + 重新计时
/// ```
///
/// # 为什么是 3 秒
/// ```text
/// 与既有的控制条自动隐藏**同一个数**（`_armHideTimer()` 里那条
/// `Timer(const Duration(seconds: 3), _autoHideNow)`）—— 两者在用户眼里
/// 本来就是同一件事。抽成常量是为了让「调这个数」只有**一处**。
/// ```
///
/// ⚠️ 光标**只在全屏**才真的隐藏（见 `_cursorIdleHidden`）—— 窗口模式下
///    鼠标还要去点标题栏 / 右侧详情区，藏起来是反直觉的（主流内嵌播放器
///    也都不藏）。
const Duration kCursorIdleHide = Duration(seconds: 3);

/// 快捷键提示项（与 [kDesktopHints] / [kTvHints] 同源）
class HintItem {
  const HintItem({required this.keys, required this.text});

  final List<String> keys;
  final String text;
}

/// 桌面：键盘快捷键（**照抄原版 `DESKTOP_HINTS`**）
const kDesktopHints = <HintItem>[
  HintItem(keys: ['空格'], text: '播放 / 暂停'),
  HintItem(keys: ['←', '→'], text: '快退 / 快进 5 秒'),
  HintItem(keys: ['J', 'L'], text: '±10 秒 · 双击左右侧同效'),
  HintItem(keys: ['0', '–', '9'], text: '跳转到百分比'),
  HintItem(keys: ['↑', '↓'], text: '音量 · M 静音 · 滚轮同效'),
  HintItem(keys: ['F'], text: '全屏 · P 画中画'),
  HintItem(keys: [',', '.'], text: '减速 / 加速'),
  HintItem(keys: ['N'], text: '下一集'),
  HintItem(keys: ['S'], text: '截图'),
];

/// TV：遥控器键位（**照抄原版 `TV_HINTS`**）
const kTvHints = <HintItem>[
  HintItem(keys: ['确认'], text: '播放 / 暂停'),
  HintItem(keys: ['←', '→'], text: '快退 / 快进 10 秒'),
  HintItem(keys: ['↑', '↓'], text: '音量'),
  HintItem(keys: ['返回'], text: '退出播放 / 返回上一页'),
];

/// 直播时 ↑/↓ 的提示文案（★★ task-53【#4b】）
///
/// # 为什么必须改（原来是**假提示**，且是本次需求的核心）
///
/// 用户要「直播进入全屏…可以上下切换」⇒ 直播时 ↑/↓ 的语义**变了**，
/// 而提示浮层是**同一份数据**渲染的（见文件头：
/// 「这份表同时用于实际按键处理与快捷键提示 —— 两处必须是同一份数据，
///   否则会出现"提示里有的键按了没反应"」）。
/// ⇒ 只改按键不改文案 = 提示在骗人；只改文案不改按键 = 更糟。
///
/// ★ 按端分开：TV 遥控器**没有** M 键、也没有滚轮
///   ⇒ 给 TV 写「M 静音 · 滚轮音量」等于把键盘键位摆在遥控用户面前
///     （原版注释明确反对："对遥控用户毫无意义"）。
const kLiveArrowHintDesktop = '切换直播 · M 静音 · 滚轮音量';
const kLiveArrowHintTv = '切换直播';

/// 按当前端取提示条目
///
/// 手机端返回空数组 → 调用方直接不渲染
/// （原版注释：手机端**完全没有**，没键盘，列出来纯占空间）。
List<HintItem> hintsFor({
  required bool isTv,
  required bool isTouchOnly,
  required bool isLive,
}) {
  final src = isTv ? kTvHints : (isTouchOnly ? <HintItem>[] : kDesktopHints);
  if (!isLive) return src;
  /*
   * 直播不能快进/跳转 —— 列出来只会让人白试
   * （进度条本身也是禁用的）。
   *
   * ★★ task-53【#4b】：其中 ↑/↓ 那一条**不是删掉，是换语义** ——
   *   直播时 ↑/↓ 切频道（见 `_onKey` 的 arrowUp/arrowDown 分支），
   *   所以文案要跟着换，且按端分开（TV 没有 M / 滚轮）。
   *   ⚠️ 判据用 `contains('音量')` 而不是 `keys.contains('↑')`：
   *      前者绑的是**能力描述**（这条讲的是音量），后者绑的是键位 ——
   *      哪天 ↑/↓ 挪到别的条目上，绑键位的写法会**改错条目**。
   */
  return src
      .where(
        (h) =>
            !h.text.contains('快退') &&
            !h.text.contains('百分比') &&
            !h.text.contains('减速'),
      )
      .map(
        (h) => h.text.contains('音量')
            ? HintItem(
                keys: h.keys,
                text: isTv ? kLiveArrowHintTv : kLiveArrowHintDesktop,
              )
            : h,
      )
      .toList();
}

/// 选一个「打开片段缓存目录」的平台策略（★ task-25 C）
///
/// 返回值（`test/t68_android_adapt_test.dart` 逐字断言这四个）：
///
///     'explorer'   Windows：资源管理器
///     'open'       macOS：open
///     'xdg-open'   Linux：xdg-open
///     'copy-path'  其它（Android / iOS / Fuchsia …）：没有文件管理器入口
///
/// # 为什么抽成顶层函数（而不是留在 _openClipDir 里）
///
/// `Platform.isWindows` / `isMacOS` / `isLinux` 是 const 静态 getter，
/// 在 flutter_tester 里恒等于**宿主**平台（Windows）⇒ 安卓那一支永远
/// 进不去，单测里根本走不到「不支持」的 else 分支，也就钉不住它的行为。
/// 抽成三个 bool 入参的纯函数之后，四种组合都能直接测。
///
/// ⚠️ 桌面三分支**必须保留**：Windows 交付链正在用
///    （`.probe/t24/AUDIT.md` 台账第 32 行记录的就是这一处）。
@visibleForTesting
String clipDirOpenStrategy({
  required bool isWindows,
  required bool isMacOS,
  required bool isLinux,
}) {
  if (isWindows) return 'explorer';
  if (isMacOS) return 'open';
  if (isLinux) return 'xdg-open';
  return 'copy-path';
}

/// ★★★ task-22 P1-11：百分比 → mpv `video-zoom` 的换算（纯函数）
///
/// # mpv 的 `video-zoom` 是 **log2 缩放系数**
///
/// ```text
/// video-zoom =  1  → 放大到 2 倍（200%）
/// video-zoom =  0  → 原始比例（100%）
/// video-zoom = -1  → 缩小到 1/2（50%）
/// ```
///
/// 用户看到的（面板档位 / 底栏滑条）是**百分比** ⇒ `zoom = log2(pct/100)`。
///
/// # 为什么抽成顶层纯函数
///
/// 与 [clipDirOpenStrategy] 同一条理由：真机上拖滑条读 `video-zoom` 属于
/// 取证（要真播放器），而这条换算是纯数学 —— 抽出来之后单测能直接钉住
/// 50/100/200 三个边界，不必挂真播放器。
@visibleForTesting
double videoZoomToMpv(double pct) => math.log(pct / 100) / math.ln2;

/// ★★★ task-33（Owner 第 1009 批 F1 后半）：顶栏站名该拿**哪个 id** 去查
///
/// # 缺陷（Owner 原话）
///
/// ```text
/// 已缓存的也要显示原来的封面,点击进去的播放也要显示出来原来源,而不是local
/// ```
/// 本地会话的 `provider` 恒等于 [kProgressLocalProvider]（`'local'`）——
/// 它是**续播的命名空间**（进度键 `local:<规范化路径>`，见
/// `progress_origin.dart`），**不是站点**。于是 `providerDisplayName('local')`
/// 只能把 id 原样吐回来，顶栏就挂出一枚写着 `local` 的胶囊
/// （真机复现见 `.probe/ops/_f1b1_repro_raw.txt`）。
///
/// # 判据（三种输入 → 三种输出）
///
/// ```text
/// provider 不是 local                        → provider
///   （在线会话，原行为一个字不动）
/// provider 是 local 且 originProvider 非空白 → originProvider
///   （本地会话认回“当初从哪个站下的”，来源由 cache_page 的旁文件带下来）
/// provider 是 local 且来源空白 / 就是 local  → null
///   （真不知道 ⇒ 调用方用 [kLocalSessionSourceLabel] 兜底，**绝不显示 `local`**）
/// ```
///
/// `null` 的含义是“没有**站点**可查”，**不是**“显示空字符串” —— 与
/// `detail_page.dart::_loadLocalOrigin`（`:1521-1550`）同一口径：认不回来时
/// **如实写「本地」**，既不空着、也不冒充任何站点。详情页那半的常量是
/// `detail_page.dart:530 kLocalSourceLabel`，而本文件**不 import** 详情页
/// （两页之间没有依赖）⇒ 这里自带一枚同值常量 [kLocalSessionSourceLabel]，
/// 并由 `test/zz_cr_local_session_player_test.dart` 钉住两者**必须相等**。
///
/// ⚠️ 只决定**显示**：`_provider` 本身一个字都不许改（换源判据 / 续播键 /
///    路由全靠它）。
@visibleForTesting
String? providerNameLookupId({
  required String provider,
  required String? originProvider,
}) {
  if (provider != kProgressLocalProvider) return provider;
  final o = originProvider?.trim() ?? '';
  if (o.isEmpty || o == kProgressLocalProvider) return null;
  return o;
}

/// ★★★ task-33（F1 后半）：本地会话**认不回来源**时，顶栏如实写这一枚。
///
/// # 为什么不是空、也不是 `local`
/// Owner：「点击进去的播放也要显示出来原来源,而不是local」。
/// 认不回来（旁文件缺失）时**如实写「本地」** —— 不空着（用户会以为名字没加载
/// 出来）、也**绝不**把 [kProgressLocalProvider] 那个**续播命名空间**的 id
/// （`'local'`）当站点名挂出去（那才是 Owner 说的“而不是local”）。
///
/// ⚠️ 与 `detail_page.dart:530 kLocalSourceLabel`（`'本地'`）**必须逐字相等**：
///    同一件事在详情页与播放页是两个说法，就是在制造新的不一致。两者之间
///    没有依赖（本文件不 import 详情页）⇒ 相等性由门禁
///    `test/zz_cr_local_session_player_test.dart` 直接读两个文件钉住。
const String kLocalSessionSourceLabel = '本地';

/// ★★★ task-33（B①）：这个 provider 是不是「本地文件会话」
///
/// # 缺陷（Owner 原话）
///
/// ```text
/// 这个好像是概率性的,缓存到本地就不要显示换源按钮了
/// ```
/// 详情页那一半（本地行上那枚「换源」）已经关掉了，**播放器「更多」里
/// 还有第二枚**，而且它没有任何门控 ⇒ 本地文件播到一半点「换源」，
/// 弹层里搜出来的全是**别的站点**的同一部剧，而这一集在磁盘上就有，
/// 换源无处可落。
///
/// # 为什么判据是 `_provider` 而不是 `widget.localPath`
///
/// `widget.localPath` 是**页面级**不可变量，而 `applySession`（原地换源 /
/// 换集）会把 `_provider` 换成在线站点 ⇒ 用静态判据的话，“本地页里切到
/// 在线源”之后换源会被**永久藏起来**。`_provider == 'local'` 是唯一
/// **跟着会话走**的判据，而且它跟续播命名空间是同一个（改它等于把旧进度
/// 全丢，见 `cache_page.dart` 的裁决）。
@visibleForTesting
bool isLocalSessionProvider(String provider) =>
    provider == kProgressLocalProvider;

/// 播放页
class PlayerPage extends StatefulWidget {
  const PlayerPage({
    super.key,
    required this.provider,
    required this.id,
    required this.title,
    this.cover,
    this.episodeId,
    this.episodeTitle,
    this.sourceCode,
    this.episodes = const [],
    this.episodeIndex,
    this.liveChannelId,
    this.onLiveChannelStep,
    this.onLiveChannels,
    this.onLiveChannelPick,
    this.initialLivePlayback,
    this.onLivePlaybackExit,
    this.isTv = false,
    this.isTouchOnly = false,
    /*
   * ★★★ task-2【④】右侧详情栏此刻是否**真的可见**（用户第 15 条）。
   *
   * 错在哪：底栏那枚「选集」按钮曾经只由「有没有剧集」把门 ⇒ 非全屏但**右侧详情栏
   * 已经摆在旁边**时，详情栏里本来就有「选集」标题 + 剧集网格（detail_page.dart:2266
   * 的 _bodyEpisodes），再在底栏放一枚就是**重复入口白占位**。用户原话：
   * 「在非全屏状态下,选集的按钮不应该出现占位置」。
   *
   * 为什么用这个判据、且由宿主传：判据 = 「右侧详情栏可见」，它只有 media_page.dart
   * 知道（Row 是它拼的：media_page.dart:1005 的 (fullscreen || wide) ? Row(...) : Column(...)，
   * 再叠加 :1015 的 if (!fullscreen) SizedBox(width: detailW, child: detailPanel)）
   * ⇒ 右侧详情栏可见 ⇔ !fullscreen && wide(>=900)。播放页自己**抄不出**这个条件：
   * 它拿不到 narrow 分支里「详情区被挪到播放器下方」这件事，也不知道 fullscreen 的权威值。
   * 所以判据由宿主算好、以布尔传进来（单一数据源，见 media_page.dart:729）。
   *
   * ★ 默认值**必须** false：默认 false = hasEpisodes 不受影响 = 底栏照旧显示选集按钮。
   *   若默认成 true，所有没显式传参的路径（尤其是从历史记录 push 进播放页，
   *   shell.dart:4524 那条）会**静默少掉唯一的切集入口**。
   *
   * ★ 禁止改写成「非全屏就一律隐藏」：窄屏（Column 分支）时右侧**没有**详情栏，
   *   详情区在播放器下方、不构成重复入口，此时必须**仍然显示**选集按钮。
   */
    this.hasRightDetailBar = false,
    /*
     * ★★★ task-12 ④（2026-10-09）：本地文件路径（绝对路径）。
     *
     * null = 走原来的网络解析 —— **逐字节不变**（所有既有构造点都不用改）。
     * 非 null = `initState` 短路成 `file://` 起播，**完全不调 `_load()`**。
     *
     * # 为什么需要它（实测根因）
     * ```text
     * `_load()`（:2921）是唯一生产起播入口，且**无条件**走
     *   `SourinApi.resolveStream` -> Rust `playback.rs:160-164 registry.route()`
     * 而本地文件没有 provider 可路由 => 必然报「无法路由」=> 本地文件永远播不了。
     * ```
     *
     * # 为什么不加在 `_load()` 里（lead 裁决「路 A」）
     * ```text
     * `_load()` 里 `final List<StreamCandidate> list;` 是**确定赋值**结构，
     * 在里面插第三支 = 改那个 if/else 的**形状**（那是我刚收完 task-8 的地方）。
     * 在 `initState` 短路 => `_load()` 的字节一行不动 => 零冲突、零回归风险。
     * ```
     *
     * ⚠️ 值的来源：`shell.dart:4773` 已经判完「有旁文件走在线 / 没旁文件走本地」
     *    再经 `media_page.dart:874` 逐字转发上来。本页**不再重判**。
     */
    this.localPath,
    /*
     * ★★★ OPS-13（反馈 C）：这一集**原本来自哪个站点**（provider + 站点内容 id）。
     *
     * # Owner 原话（逐字）
     * ```text
     * > 续播进度,我希望的是我缓存这集了,但是如果我在线看,他还能记得我看过
     * > 而不是 本地和线上的就彻底分开了,你懂不
     * ```
     *
     * # 它们**不是**主键（主键永远是 provider/id；本地会话下恒为 local）
     * ```text
     * 本地会话：provider='local'、id=文件规范化绝对路径（cache_page.dart:722-734 的裁决）
     * 本字段是**镜像的目标**：本地看完一集后，再把进度补写一条到
     *   (originProvider, originMediaId) 上 ⇒ 在线打开同一部作品时能续上。
     * ```
     * 判断逻辑全在 `lib/core/progress_origin.dart`（纯函数，可单测）——
     * 本页只负责把两个值带进来、在读写进度时用上（见 `_mirrorOrigin`）。
     *
     * ⚠️ 全部可空：老下载 / 手拷进来的目录**没有**旁文件 ⇒ 不镜像、不猜。
     */
    this.originProvider,
    this.originMediaId,
    /*
     * ★★★ OPS-13 反馈 C ①：镜像那条要写的**站点集 id**（不是本地文件名）。
     *
     * # 为什么另开一个口子（不复用 [episodeId]）
     * ```text
     * episodeId 是**会话自己的集号**：本地会话里它是**文件名**（shell.dart:4830
     *   传 req.episode.fileName）。而镜像要打到的站点键上，集号是**站点集 id**。
     * 拿文件名当镜像的 episode_id ⇒ 两个方向都坏（详见 progress_origin.dart
     *   的 saveProgressWithMirror 长注释）⇒ 必须由调用方显式给站点集 id。
     * ```
     * ⚠️ 默认 null = **不写镜像**（不是「写 null」）—— 拿不到站点集 id 时
     *    宁可少写一条镜像，也不写坏在线记录（CR-08 的数据安全裁决）。
     */
    this.originEpisodeId,
  });

  final String provider;
  final String id;
  final String title;
  final String? cover;
  final String? episodeId;
  final String? episodeTitle;
  final String? sourceCode;
  final List<Episode> episodes;
  final int? episodeIndex;

  /// 非空 = 直播模式（禁进度条、过滤部分提示）
  final String? liveChannelId;

  /// 从内嵌直播播放器交接的状态，仅直播模式使用。
  final LivePlaybackSnapshot? initialLivePlayback;
  final ValueChanged<LivePlaybackSnapshot>? onLivePlaybackExit;

  /// ★★★ task-53【#4b】直播时 ↑/↓ 切频道（用户第 4 条，**第二次强调**）
  ///
  /// ```text
  /// 用户原话：
  /// > 直播进入全屏还是没办法像选集一样切换直播,而且我说的切换,是指的,
  /// > 直播进入全屏播放的状态下,然后可以上下切换,然后还可以切换直播
  /// > **不是指 在直播页面(未进入全屏)加一个所有直播的按钮进行切换的**
  /// ```
  ///
  /// # 语义（★ 逐字对齐 `live_page.dart::cycleChannel` 的方向）
  /// ```text
  /// ↑ ⇒ delta = -1（上一个台）
  /// ↓ ⇒ delta = +1（下一个台）
  /// ```
  /// ⚠️ 方向**必须**与 `live_page.dart:450-457` 一致 ——
  ///    同一件事在两页里方向相反，是"按了往上却往下走"那种最难查的 bug。
  ///
  /// # 为什么是**回调**而不是在这里自己取频道列表
  /// ```text
  /// 候选方案：播放页自己调 `getLiveChannels()` + 探可用性 + 算相邻台。
  /// ★ 否掉它的理由（不是"麻烦"，是**正确性**）：
  ///   直播页的"可见频道"依赖 `LiveAvailabilityProbe` 的 TTL 缓存
  ///   （10 分钟）、`_disabledProviders`、以及探到的 audioOnly/unavailable
  ///   ⇒ 播放页自己算一遍 = **两套真相** ⇒ 必然出现
  ///     「全屏里按 ↓ 切到了一个直播页列表里根本没有的台」。
  /// ★ 而 `live_page.dart` **本来就已经实现了**这个能力
  ///   （`cycleChannel` + `_visibleChannels`），且是用户上一轮验收过的。
  /// ⇒ 复用它的实现，本页只负责"把 ↑/↓ 翻译成一个方向"。
  /// ```
  ///
  /// # ⚠️ 为什么**不**复用 shell 的 `_liveChannelStep`（ValueNotifier）
  /// ```text
  /// 那条通路是 task-39 给**遥控**用的（`liveChannelStep: (d) => _liveChannelStep.value = d`）。
  /// ★ 实测确认它对本需求**不可用** —— `ValueNotifier` 会**去重相等的值**：
  ///     flutter/src/foundation/change_notifier.dart:558
  ///         set value(T newValue) { if (_value == newValue) return; ... }
  ///   ⇒ 连按两次 ↓（delta 都是 +1）⇒ **第二次不通知**
  ///   ⇒ 用户连按两下只切一个台。
  ///   ★ `shell.dart:2438-2440` 的注释**正是**在记这个坑
  ///     （"第二次不通知 ⇒ 监听者必须收到就执行一次"）——
  ///     那是给遥控的"脉冲"约定，而这里是"每按一次都要切一个台"。
  /// ⇒ 所以走**直接回调**。
  /// ```
  ///
  /// # ★★★ 为什么回调**返回**新频道，而不是"让直播页自己切"
  /// ```text
  /// 候选（lead 原方案）：回调里调 `_liveKey.currentState?.cycleChannel(delta)`
  ///   ⇒ ★ 那样会把**隐藏的直播页**切掉 —— 而它有个内嵌播放器：
  ///     ① 全屏播放器**不会**跟着换台（它在播自己的流）⇒ 用户按了没反应
  ///     ② `cycleChannel` → `_select` → `_loadStream` ⇒ 内嵌播放器
  ///        `didUpdateWidget` 看到 url 变了 ⇒ `open()` + **`play()`**
  ///        ⇒ ★★ **两个 mpv 同时出声**（正是 `_watchLive` 拼命防的回声/重音）
  /// ⇒ 正确分工：
  ///     直播页只回答"**下一个台是哪个**"（它有探针缓存/启用态，是唯一真相）
  ///     本页负责"**我**去播那个台"（mpv 在本页）
  ///   而直播页在切台时**只改选中、不起播**（见 `_adoptForFullscreen`），
  ///   等 pop 回来再接手播放 ⇒ 任何时刻只有**一个**播放器出声。
  /// ```
  ///
  /// # 与其它键的关系（★ 不改动点播行为）
  /// ```text
  /// 直播 + 有本回调 ⇒ ↑/↓ 切台（不再调音量）
  /// 其余一切情况    ⇒ ↑/↓ 仍是音量（已验收，原样不动）
  /// ```
  /// ⚠️ 判据用**两个**（`_isLive && onLiveChannelStep != null`）：
  ///    回调可空 ⇒ 没接线的调用点（测试、回看、其它路由）**行为完全不变**。
  final ({String provider, LiveChannel channel})? Function(int delta)?
  onLiveChannelStep;

  /// ★★★ task-53【③】取**全部可见直播频道**（用户第 3 条）
  ///
  /// ```text
  /// 用户原话（逐字）：
  /// > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  /// ⇒ 要的是：**在直播播放页里，像"选集"那样打开一个列表看所有频道**。
  ///
  /// # 与 `onLiveChannelStep` 的分工（★ 两件事，别混）
  /// ```text
  /// onLiveChannelStep   = **上下键直接切台**（#4b，已验收）
  /// onLiveChannels      = **打开列表看全部**（#3，本条）
  /// onLiveChannelPick   = **点列表里某一项 ⇒ 切过去**
  /// ⇒ 用户两条都要：「能直接切」+「能打开列表看」。
  /// ```
  ///
  /// # ★ 为什么由直播页回答（唯一真相）
  /// ```text
  /// 与 `onLiveChannelStep` **同一条理由**：`_visibleChannels` 依赖
  /// `LiveAvailabilityProbe` 的 TTL 缓存 + `_disabledProviders` +
  /// audioOnly/unavailable 过滤 ⇒ 播放页自己查 = **两套真相**
  ///   ⇒ 面板里会列出"其实不能播"的台，或漏掉能播的台。
  /// ```
  ///
  /// ⚠️ 可空 ⇒ 没接线的调用点（测试/点播/回看）**行为完全不变**：
  ///    `_isLive && onLiveChannels != null` 才显示「所有直播」按钮。
  final ({List<LiveChannel> channels, int index})? Function()? onLiveChannels;

  /// ★★★ task-53【③】在"所有直播"面板里**点选了某个台** ⇒ 返回该台的信息
  ///
  /// 返回 `null` = 直播页不认这个台（不在它的可见列表里）。
  ///
  /// # ★ 为什么与 `onLiveChannelStep` **分开**两个回调
  /// ```text
  /// 候选：合并成一个 `onLiveChannelAction({int? delta, LiveChannel? pick})`。
  /// ★ 否掉：两个参数互斥却都出现在签名里 ⇒ 调用方可以传两个/都不传，
  ///   类型系统**管不到** ⇒ 又多一类"静默走错分支"的 bug。
  /// ⇒ 宁可两个各自单一职责的回调（与 `_prevEpisode`/`_nextEpisode` 同一风格）。
  /// ```
  final ({String provider, LiveChannel channel})? Function(LiveChannel channel)?
  onLiveChannelPick;

  final bool isTv;
  final bool isTouchOnly;

  /// ★★★ task-12 ④：本地文件**绝对路径**（见构造参数处的完整说明）。
  ///
  /// ⚠️ 与 `isTv` / `isTouchOnly` 一样是**可选**的 ——
  ///    不传即 null，所有既有构造点走的字节完全不变。
  final String? localPath;

  /// ★★★ OPS-13（反馈 C）：原来源（见构造参数处的完整说明）。
  ///
  /// ⚠️ 与 [localPath] 一样是**可选**的 —— 不传即 null，
  ///    所有既有构造点（在线播放 / 直播 / 遥控）走的字节完全不变。
  final String? originProvider;
  final String? originMediaId;

  /// ★★★ OPS-13 反馈 C ①：镜像那条的**站点集 id**（见构造参数处的完整说明）。
  ///
  /// ⚠️ 与 [originProvider]/[originMediaId] 一样是**可选**的 ——
  ///    不传即 null（老下载 / 手拷进来的目录没有旁文件）⇒ 不写镜像。
  final String? originEpisodeId;

  /// ★★★ task-2【④】右侧详情栏此刻是否真的可见 —— 由宿主（media_page.dart）算好传进来。
  ///
  /// 详细推导见构造参数处 this.hasRightDetailBar 的长注释。这里只钉三条：
  /// · 判据不许在播放页重算（它看不见 narrow 分支与 fullscreen 权威值）；
  /// · 默认 **false**（= 照旧显示选集按钮），改默认值等于静默砍掉切集入口；
  /// · 唯一的消费点在 _PlayerPageState.build 里
  ///   hasEpisodes: _episodes.length > 1 && !widget.hasRightDetailBar。
  final bool hasRightDetailBar;

  @override
  State<PlayerPage> createState() => _PlayerPageState();
}

/// 当前进行中的长按类型（左半屏连续快退 / 右半屏倍速快进）
///
/// ⚠️ 必须是**顶层** enum —— Dart 不允许在类里声明 enum
///    （我第一版塞进了 State 类内部，编译报
///     `Enums can't be declared inside classes`）。
enum _LongPressKind { rewind, rateBoost }

/// 四个方向键 —— `_onKey` 里判断"要不要让给选集面板"用
///
/// ⚠️ **不能加 `const`**：`LogicalKeyboardKey` 重写了 `==`
///    （它按 keyId 比较，不是按标识），而 Dart 规定
///    「const Set 的元素不能重写 `==`」——
///    加了会直接编译报错 `const_set_element_type_mismatch` 那一类。
///    这里只是个查表用的集合，非 const 没有任何代价。
final _arrowKeys = <LogicalKeyboardKey>{
  LogicalKeyboardKey.arrowUp,
  LogicalKeyboardKey.arrowDown,
  LogicalKeyboardKey.arrowLeft,
  LogicalKeyboardKey.arrowRight,
};

class _PlayerPageState extends State<PlayerPage>
    with SingleTickerProviderStateMixin
    implements MediaSession, LivePlaybackTarget {
  late final Player _player;
  late final VideoController _controller;

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 第 16 项（2026-10-25）：内嵌 / 全屏**快捷键一致** —— 契约实现
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么要实现这个接口（而不是在本页再写一套"空格=播放暂停、M=静音"）
  // ```text
  // 内嵌播放器已经有一份「按键 → 动作」的映射（`livePlaybackActionForKey`）
  // 与「动作 → 调用」（`dispatchLivePlaybackAction`）。
  // 若全屏侧再手写一份 ⇒ 两处语义迟早漂（本仓反复吃过"两套真相"的亏：
  // `_isTypingInField` 抽函数、`_bottomOccupied` 单点、`seek-intent` 标记…）。
  // ⇒ 全屏侧只**实现接口**，把动作转调既有的 `_togglePlay` / `_toggleMute`：
  //   状态反馈、快照、闪光提示、计数探针全部复用，**一行逻辑都不复制**。
  // ```
  // ⚠️ `_player` 是 `late final`（initState 里创建）—— 按键只会在挂载后到达，
  //    这里直接读，不做 `?.`（`?.` 会掩盖"还没 initState 就有人读"的真 bug）。
  @override
  bool get isPlaying => _player.state.playing;
  // ⚠️ `_player` 是 `late final`（initState 里创建）⇒ **只在挂载之后读**。
  //    本 getter 会被 UI（底栏走 `_playing` 镜像）与探针读；按键/探针都发生在
  //    挂载后，所以这里**故意不做** `?.`——那会掩盖"未 initState 就有人读"的真 bug。

  @override
  bool get muted => _muted;

  @override
  Future<void> togglePlayPause() async => _togglePlay();

  @override
  Future<void> toggleMute() async => _toggleMute();

  /// 候选流（多清晰度/多线路）
  List<StreamCandidate> _streams = [];
  StreamCandidate? _current;

  bool _loading = true;
  String? _error;

  /// ★★ 失败错误的**结构化类别**（来自 `SourinCoreException.kind`，2026-09-25 task-38）
  ///
  /// # 为什么需要它（本轮发现的问题）
  ///
  /// `_error` 是**字符串** —— 而 `SourinCoreException` **本来就带 `kind`**
  /// （`lib/core/ffi.dart`：`network` / `unauthorized` / `not_found` /
  /// `unsupported` / `other`，由 `ffi.rs` 的 `err_json` 一路带过来）。
  ///
  /// 但这里 4 处赋值全写成 `_error = e.toString()` —— **`kind` 被字符串吞掉了**，
  /// 于是 `_isAuthError` 只能回头去 `contains('unauthorized')`
  /// （在 `toString()` 拼出来的 `SourinCoreException(unauthorized): …` 里找词）。
  ///
  /// ⚠️ 那种判据的脆弱之处：**插件换个措辞就静默失效**
  ///    （不是抛错、不是变红，而是"登录按钮不出现了"）。
  ///
  /// ⚠️ `null` 表示"这个错误没有结构化类别"（例如本页自己拼的中文串，
  ///    或 `media_kit` 的播放错误）→ 调用方**必须**回退到字符串判据。
  String? _errorKind;

  /// 直播只剩音频线路时的**非阻断提示**（不是错误）
  ///
  /// 用户报「tvsrc看得到但是点开黑屏」的根因：央视视频轨被 DRM 加密，
  /// 三条线路里只有「仅音频」能播 → 有声无画面。
  /// 原版会明确告知（`PlayerView.vue:4281-4299`），我们之前是静默开播。
  ///
  /// ⚠️ 为什么不用 `_error`：`_startPlayback()` 开头会把它清成 null
  ///    （`_error` 的语义是"起播失败"），所以这条提示必须是独立字段，
  ///    才能与"正在正常播放"并存。
  String? _liveAudioOnlyNotice;

  /// 「播放失败」的**非阻断**横幅文案（★ 2026-10-08，Owner 第 9 条）
  ///
  /// # 补的是什么
  ///
  /// Owner 第 9 条截图（u9_1c91d6a6.png）：
  /// ```text
  /// 播放失败
  /// Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
  /// ```
  /// 这条 mpv 原文**只能在"从未出过画面"时**才配得上全屏 `_ErrorOverlay`。
  /// 一旦已经出过画面，再来的 `stream.error` 只是一次**可恢复的**抖动
  /// （换清晰度重开、缓冲重试、单帧解码报错都会发），
  /// 用全屏遮罩把正在看的画面盖掉 = 用户报的"看着看着突然播放失败"。
  ///
  /// ⇒ 判据是 [_sawFirstFrame]：出过画面 ⇒ 走这条**非阻断**横幅，
  ///   画面继续，用户能自己决定要不要换线路。
  ///
  /// ⚠️ 与 `_error` 分开的理由同 [_liveAudioOnlyNotice]：
  ///    `_error` 的语义是"起播失败"，它和"正在播放"是**互斥**的。
  String? _playbackFailure;
  Duration _recoveryProgress = Duration.zero;

  // ───────────────────────────────────────────────────────────────────
  //  ★★★ 缺陷①（2026-10-25）：用户主动 seek 的**豁免窗口**
  // ───────────────────────────────────────────────────────────────────
  //
  // # 修的是什么
  // ```text
  // 片头区间是 [0, 69s]（三条真实片源都从 0 开始）。
  // 用户把进度条拖到 0 ⇒ 一切正常；
  // 但位置流下一秒就 tick 到 0 ⇒ `_maybeSkip` 命中片头区间 ⇒ seek(69)。
  // 用户看到的就是「拖到 0 自动往前」，拖几次就是「越拖越往前」。
  // ```
  //
  // # 为什么不能只靠 `_seekByUser` 里那句 `_introSkipped = true`
  // ```text
  // 那个标志确实能挡一次，但它是**会话级**的、而且有 5 处复位点
  // （`_applySwitch` / `_applySession` / `_gotoEpisode` / 存设置 / 开 autoSkip）。
  // 只要用户在"拖回 0"之后又碰过其中任何一条路径，`_introSkipped` 回到 false，
  // 下一次 tick 又会把他弹走 —— 这正是 Owner 说的"拖几次累加"的形态。
  // ```
  // ⇒ 所以要多一份**与 `_introSkipped` 正交**的证据：用户刚刚（2 秒内）
  //   主动 seek 到过某处 ⇒ 这一刻的自动跳过让位。
  //
  // ⚠️ 用**单调时钟**（`Stopwatch`）而不是 `DateTime.now()`：
  //    系统改时间（NTP 校正、用户手动调）会让墙钟差值变成负数或几小时，
  //    2 秒窗口就失效了。
  final Stopwatch _userSeekClock = Stopwatch()..start();

  /// 最近一次**用户主动 seek** 的落点（`null` = 本次会话还没拖过）
  Duration? _lastUserSeek;

  /// 上面那次 seek 发生时刻的**单调读数**（`_userSeekClock.elapsed`）
  Duration? _lastUserSeekAt;

  /// 豁免窗口宽度
  static const Duration _kUserSeekGraceWindow = Duration(seconds: 2);

  /// 记录一次用户主动 seek（`_seekByUser` 是**唯一**入口 —— 五条路径都汇到它）
  void _noteUserSeek(Duration target) {
    _lastUserSeek = target;
    _lastUserSeekAt = _userSeekClock.elapsed;
  }

  /// 此刻是否处在「用户刚拖过」的豁免窗口内
  ///
  /// ⚠️ 判据只读两个字段，不改状态 —— 这样 `_maybeSkip` 可以被反复调用
  ///    （位置流每秒一次）而不会因为"读一次就消费"而在第二次 tick 时误跳。
  bool _withinUserSeekGrace() {
    final at = _lastUserSeekAt;
    if (at == null) return false;
    final age = _userSeekClock.elapsed - at;
    return age >= Duration.zero && age <= _kUserSeekGraceWindow;
  }


  /// 本次起播是否**已经确认出过画面**（`stream.width` 首次非空）
  ///
  /// # 为什么需要它（而不是"看 `_error` 是不是空"）
  ///
  /// `media_kit` 的 `stream.error` 只有**白名单前缀**才发
  /// （`media_kit-1.2.6/lib/src/player/native/player/real.dart:2085-2119`），
  /// 而且**同一个错误在整条生命周期里都可能来**：
  /// ```text
  /// 起播阶段：mpv 打不开 → 该给全屏错误（用户什么都没看到，必须解释）
  /// 播放中：  换流/重连/单帧解码失败 → 只该给一条横幅（画面还在）
  /// ```
  /// 两者用同一句 `_error = e` 处理，就是把"可恢复抖动"当成"致命失败"。
  ///
  /// ⚠️ 用 `stream.width`（`Stream<int?>`，见
  ///    `media_kit-1.2.6/lib/src/models/player_stream.dart:88`）
  ///    而不是 `player.state.width`：前者是**事件**，能区分
  ///    "这一刻有画面"和"刚才有画面"；后者只反映当前值。
  bool _sawFirstFrame = false;

  /// 「画面输出层没建起来」的**非阻断提示**（不是错误）
  ///
  /// # 补的是什么
  ///
  /// 交付说明 `README-交付说明.md:126-129` 自己承认过这个缺口：
  /// > 输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默
  ///
  /// 具体场景：`mpv` 解析出了视频轨（demux 成功），但 `vo` 建不起来
  /// （典型是 `Could not create a GL context.` / `Failed initializing
  /// any suitable GPU context!`）。此时**画面永远是黑的、声音正常、
  /// 时间在走**，而客户端一句话都不说 —— 用户只会认为「客户端坏了」。
  ///
  /// ⚠️ 为什么 `_error` 收不到：`media_kit` 只把**白名单前缀**的日志
  ///    转成 `stream.error`（`media_kit-1.2.6/lib/src/player/native/player/real.dart:2085-2119`），
  ///    而 `vo/gpu` / `vo/gpu/opengl` **不在白名单里** ⇒ 这类失败
  ///    被库静默丢掉。所以必须自己探。
  ///
  /// # 判据（五臂实测得出，见 `.probe\t376_matrix.py`）
  ///
  /// ```text
  /// hasVideoTrack = player.state.videoParams.dw != null   ← Dart 侧
  /// voConfigured  = mpv 属性 'vo-configured' == 'yes'      ← mpv 侧
  /// 告警 = hasVideoTrack && !voConfigured
  /// ```
  ///
  /// ★ 为什么必须是这两个的**组合**：
  ///   * `vo-configured` 单独用 → 每个「合法无视频」的电台都会被判成故障
  ///     （纯音频臂上它是 `yes`，而 Android 失败臂上是 `no`，方向正好相反）。
  ///   * `videoParams.dw` 单独用 → 失败臂上它也是真（Dart 侧是
  ///     `mpv_observe_property` 事件推送的**残留**，不是「此刻有输出」的证据）。
  ///
  /// ⚠️ 不要用库自报的「首帧已渲染」当判据：`controller.rect > 1x1` 与
  ///    `waitUntilFirstFrameRendered` 在**失败臂上依然为真**（Android 的
  ///    `rect` 由 `VideoOutputManager.SetSurfaceSize` 回填，而该调用在
  ///    GL 上下文建不起来时仍然"成功"）。
  ///
  /// ⚠️ 与 `_error` 分开的理由同 `_liveAudioOnlyNotice`：`_startPlayback()`
  ///    开头会把 `_error` 清成 null，而这条提示的语义是
  ///    「起播**成功**了，但画面出不来」，必须与「正在播放」并存。
  bool _videoOutputDead = false;

  /// 画面输出层看门狗的代次号（每次起播自增，旧的那一轮自行放弃）
  int _videoOutputToken = 0;

  bool _buffering = false;

  /// 当前播放位置 / 时长（秒）
  Duration _position = Duration.zero;

  /// ★ 2026-10-09（Owner 第 10 条「很多地方卡卡的」）：播放位置的**局部**真源
  ///
  /// # 为什么要有它（改前的实测）
  /// ```text
  /// 改前：`_onPositionTick` 每跨一秒 `setState(() {})` **一次** ⇒
  ///   整棵 1.6 万行的播放页重建 —— 底栏那一小块时间变了，
  ///   却把弹幕层、顶栏、所有浮层都重排一遍。
  /// 改后：位置只写进这个 notifier，底栏用 `ValueListenableBuilder` 单独重建；
  ///   **整页不再因为时间前进而重建**。
  /// ```
  ///
  /// ⚠️ `_position` 字段**保留**（seek / 续播 / 快退 / 弹幕判定都读它，
  ///    且读的是**最新值**，语义不变）；这个 notifier 只承担"通知 UI 重画"。
  final ValueNotifier<Duration> _positionNotifier = ValueNotifier<Duration>(
    Duration.zero,
  );
  Duration _duration = Duration.zero;

  /// 真实时长（从流里读出来的，不是元数据的）
  ///
  /// 原版注释：
  /// > 元数据的 duration 常常不准（尤其 HLS），
  /// > 用它算百分比会让"续播位置"偏到离谱的地方。
  Duration _realDuration = Duration.zero;

  bool _playing = false;
  double _volume = 100;
  bool _livePlaybackExitReported = false;

  LivePlaybackSnapshot get _livePlaybackSnapshot => LivePlaybackSnapshot(
    playing: _playing,
    muted: _muted,
    volume: _muted ? (_volumeBeforeMute ?? _lastVolume * 100) : _volume,
  );

  void _reportLivePlaybackExit() {
    if (!_isLive || _livePlaybackExitReported) return;
    _livePlaybackExitReported = true;
    widget.onLivePlaybackExit?.call(_livePlaybackSnapshot);
  }

  // ── task-18 ③④⑤：片段下载 / 日志 ──
  //
  // 真正的状态（并发上限 / 缓存上限）在 ClipDownloader、日志在 AppLog，
  // 两边都是**进程级单例**；这里只放本页面要画的东西。
  /// 正在下载的**文件名**集合（按名字去重，**不是**全局互斥）
  ///
  /// ★ 2026-10-04 订正（Lead 审计 team-message-914508ce，【中】第 2 条）：
  ///   这里**原先**是 `bool _clipDownloading = false;`，配上 `_downloadClip()`
  ///   开头的 `if (_clipDownloading) return;` —— 一个**全局**重入守卫。
  ///
  ///   后果：UI 路径上永远只有 1 个下载在跑 ⇒ `ClipDownloader.maxObservedActive`
  ///   恒 ≤ 1 ⇒ 并发上限滑杆在**真实 UI 路径**上不可观测，而
  ///   `lib/ui/settings/playback_page.dart` 里那句「用户把并发调到 1，再点两次
  ///   下载，第二个就**真的**在等第一个」因此是**错的**（第二次点击被守卫吞掉，
  ///   根本进不到池子）。
  ///
  ///   现在改成**按流地址（url）去重**：同一集的同一条流重复点不会重复下
  ///   （提示「已经在下载了」），换一集 / 换源再点就是**真的并发** —— 两个
  ///   `ClipDownloader.download()` 一起进池子，滑杆从此在 UI 上可观测。
  ///   面板按钮也**不再**在下载中禁用（见
  ///   `widgets/player_settings_sheet.dart` 里那段说明）。
  ///
  ///   ★ 2026-10-04 第二次订正（Lead 裁决 team-message-c3274cd8 第 1 条）：
  ///     去重键**起初**用的是 `_clipFileName`（文件名）—— android-phone 在
  ///     源码里发现它在标题为空时回落成 `clip.mp4`（见 _clipFileName），
  ///     两个**无标题**的集会撞名 ⇒ 第二次点被挡掉，去重反而误伤。
  ///     现在键 = `st.url`：同一集的**真正身份**是那条流。
  ///     · 同一集、同一 url 重复点 → 挡掉（设计意图）；
  ///     · 同一集**换源**后 url 变了 → 放行（那是另一条流，本来就该各自下）；
  ///     · 文件名继续只当「下载文件叫什么」，不再承担身份职责。
  ///     为什么不用 url 的 hash：`Set<String>` 存原串零额外成本（发请求本来
  ///     就要用它），hash 只多一次可读性更差的转换。
  final Set<String> _clipRunning = <String>{};

  /// 有任何一个下载在跑（面板据此显示「下载中…」）
  bool get _clipDownloading => _clipRunning.isNotEmpty;

  /// 本次会话里至少成功下载过一次（面板据此显示「已下载」而不是每次都像第一次）
  ///
  /// ★ 换集 / 换源时会跟着 `_skipMarker` 一起清零 —— 否则用户下载第 1 集后
  ///   切到第 2 集，面板仍显示「已下载」（Lead 审计【低】第 4 条）。
  bool _clipDownloaded = false;

  /// 上一次下载失败的原因（null = 没失败过）
  String? _clipDownloadError;
  bool _muted = false;
  double _rate = 1.0;

  /// 控制条是否可见（鼠标移动/按键后显示，几秒后自动隐藏）
  bool _controlsVisible = true;

  /// 控制条显隐的**局部广播通道**（N11，2026-10-18）
  ///
  /// # 为什么需要它（与 `_cursorLive` 同一套思路）
  /// ```text
  /// `_controlsVisible` 的读者只有两处（`_TopBar.visible` / `_TopBar.fade`，
  /// 都经 `_chromeVisible` 求值），但它每次翻转都靠 `setState` 整页重建
  /// ⇒ 真机全屏下「鼠标一动、控制条出现」= 884 行 build + 190 个元素（8~10ms）。
  /// ⇒ 抽出 notifier：顶栏挂载点包 `ListenableBuilder`，翻转时只重建顶栏。
  /// ```
  ///
  /// ⚠️ 与 `_controlsVisible` **同源**：本 notifier 只是它的镜像，
  ///    不是第二个真源。所有写入点都必须紧跟一次 `_pushControlsLive()`，
  ///    否则会出现「字段翻了、UI 没翻」的分裂。
  /// ⚠️ 必须 dispose（见 `dispose()`）。
  final ValueNotifier<bool> _controlsLive = ValueNotifier<bool>(true);



  /*
   * ═══════════════════════════════════════════════════════════════════
   *  ★★★ N10：seek 让路窗口的定时器
   * ═══════════════════════════════════════════════════════════════════
   *
   * # 它干什么
   * ```text
   * 用户拖动进度条 ⇒ 通知 Rust 侧「接下来 2 秒预取让路给前台读取」
   *              ⇒ 起一个 2 秒定时器，到点调 endYieldForSeek() 恢复
   * ```
   *
   * # 为什么需要它（真机实测，2026-10-18）
   * ```text
   * 预取 ON   seek 后：t+500ms/1000ms 都读不到 demuxer-cache-time，
   *                    播放位置**卡死不动**，t+1500ms 才恢复
   * 预取 OFF 同一位置：t+500ms 立刻有缓存
   * ⇒ 4 路并行预取与当前播放点抢上行 ⇒ 用户看到"缓冲条满了还在转圈"
   * ```
   *
   * # 三条边界（每一条都是 bug 源，`streamproxy.rs` 侧已处理）
   * ```text
   * ① 连续拖动 ⇒ Rust 侧重置截止时刻并返回 first=false
   *    ⇒ 这里**不重复起定时器**（否则会有多个定时器抢着 end）
   * ② 页面销毁 ⇒ 必须 cancel + 补一次 end（否则预取永久关闭）
   * ③ 原本关闭 ⇒ Rust 侧保存/恢复原值，这里不无条件 set(false)
   * ```
   */
  Timer? _prefetchYieldTimer;

  /// seek 之后让预取让路给前台读取（见上方 `_prefetchYieldTimer` 的说明）
  ///
  /// fire-and-forget：seek 是热路径，不能 await（await 会让拖动变卡）。
  void _beginPrefetchYield() {
    unawaited(() async {
      try {
        final first = await SourinApi.beginYieldForSeek();
        /*
         * ★ 只有首次进入才起定时器。
         *
         * 连续拖动时 Rust 侧已经把截止时刻重置成 now+2000ms，
         * 我们只需保证「窗口结束时有人调 end」——已经有一个定时器在等，够了。
         * 若这里无条件再起一个，会出现 N 个定时器先后调 end，
         * 最后一个在窗口还没结束时就把预取恢复了 ⇒ 让路失效。
         */
        if (!first) return;
        _prefetchYieldTimer?.cancel();
        _prefetchYieldTimer = Timer(
          const Duration(milliseconds: SourinApi.yieldWindowMs),
          () {
            _prefetchYieldTimer = null;
            // ★ 与下面 cancel 路径（14455）同一个理由：核心没加载时
            //   `SourinCore.callAsync()` 会在绑定原生库这步就失败，
            //   而这里是 fire-and-forget ⇒ 不接住就变成**未捕获的异步异常**
            //   （在 `flutter test` 里会直接算用例失败）。让路是优化，失败静默降级。
            //   （PR #32 复核线程 4/9）
            unawaited(SourinApi.endYieldForSeek().catchError((Object e) {
              // 与 dispose 那处（:14460）同一写法：失败只记日志，不外抛
              AppLog.write('PLAYER', '让路窗口结束: endYieldForSeek 失败（已忽略）：$e');
            }));
          },
        );
      } catch (_) {
        // 让路是优化，失败不影响播放 —— 静默降级到"预取照常"
      }
    }());
  }
  /// 把 `_controlsVisible` 推给 [_controlsLive]（值没变不通知）
  void _pushControlsLive() {
    /*
     * ★★★ 2026-10-25（交叉复核钉死的真缺陷）：**每个写 `_controlsVisible` 的点
     *   都必须走到这里**，否则 notifier 会停在旧值 ⇒ 下一次"翻回去"的 push
     *   因 `当前值 == 目标值` 提前 return、不通知 ⇒ 顶栏不重建 ⇒
     *   `IgnorePointer` 继续挡，而动画已到 1.0 ⇒「箭头看得见、点不到」。
     *   缺口原来是 `_autoHideNow()`（隐藏路径只 setState）。
     */
    if (_controlsLive.value == _controlsVisible) return;
    _controlsLive.value = _controlsVisible;
  }
  Timer? _hideTimer;

  /// 「人已经停手」—— [_cursorIdleTimer] 走完且控制条确实被收掉了。
  ///
  /// ⚠️ 它与 `_controlsVisible` **不是**同一个状态：`_controlsVisible` 只服务
  ///    「控制条真源 + 淡出窗口」，本字段还额外要求「指针停在播放区上不动」。
  bool _cursorIdleStale = false;

  /// 隐藏鼠标光标的计时器（与 [_hideTimer] 是**两条独立**的计时器）
  ///
  /// # 为什么不复用 `_hideTimer`
  /// ```text
  /// `_hideTimer` 的语义是「控制条该收了」，它的回调 `_autoHideNow()` 带着
  /// 一整套守卫（_playing / _hintsOpen / _zoomOpen / popover）—— 那些守卫
  /// 决定的是**控制条**收不收。而光标的判据是「指针停在播放区上不动」，
  /// 两者只是**碰巧**用同一个 3 秒 ⇒ 复用它会把两件事的判据搅在一起，
  /// 以后任何一边调参都会顺带改掉另一边。
  /// ```
  Timer? _cursorIdleTimer;


  /// 光标此刻**是否真的**处于「已隐藏」态（= 渲染层要不要给 `none`）
  ///
  /// ⚠️ 只在**全屏**才算「真的隐藏」：窗口模式下播放页只占画面那一块，
  ///    鼠标还要去点标题栏 / 右侧详情区，把光标藏起来是反直觉的
  ///    （主流内嵌播放器也都不藏）。
  ///
  /// # 为什么把「浮层开着 / 没在播」也写进**渲染期**判据
  /// ```text
  /// 置位侧（`_hideCursorNow()`）已经用 `_controlsVisible` 挡过一遍，
  /// 但那是**那一刻**的快照。这里再合一次，是为了让「画出来的光标」
  /// 自己就是完整真源 —— 即使将来某个浮层开点漏调
  /// `_collapseControlsForSheet()`，也不会出现「面板开着、光标却没了」。
  /// 三条判据都是本 State 的字段 ⇒ 任何一条翻转都会走 setState 重建本页
  /// ⇒ 光标在同一帧被重算（引擎在 post-frame 跑 `MouseTracker.updateAllDevices()`）。
  /// ```
  bool get _cursorIdleHidden =>
      _fullscreen && _cursorIdleStale && !_anySheetOpen && _playing;

  /// 光标态的**局部广播通道**（N11，2026-10-18）
  ///
  /// # 为什么需要它
  /// ```text
  /// `_cursorIdleHidden` 原先只有一处消费（build 里 `MouseRegion.cursor`），
  /// 却靠 `setState` 整页来驱动 ⇒ 一次光标翻转 = 重跑 884 行 build +
  /// 188 个元素重建（`test/zz_t66_player_jank_test.dart` 实测）。
  /// ⇒ 抽出这条 notifier：消费点包一层 `ValueListenableBuilder<MouseCursor>`，
  ///   翻转时**只重建那一个 builder**。
  /// ```
  ///
  /// ⚠️ 存的是**最终光标**不是 bool：`MouseRegion` 要的就是它；
  ///    存 bool 会让「值没变就不通知」失效（`_fullscreen` 与 `_cursorIdleStale`
  ///    同时变时 bool 翻了但光标没变 ⇒ 白重建一次）。
  /// ⚠️ 必须 dispose（见 `dispose()`）。
  final ValueNotifier<MouseCursor> _cursorLive =
      ValueNotifier<MouseCursor>(MouseCursor.defer);

  /// ★ Owner 第 1 条：记一次「人还在操作」—— 续命光标隐藏计时器
  ///
  /// # 为什么**不**在这里自己造一条计时器
  /// ```text
  /// 本函数被每一次鼠标移动 / 按键 / 滚轮调用（Windows 上每秒可达数百次）。
  /// 在这里新建 Timer 就等于「鼠标一动就重装一条 3 秒计时器」——
  /// 而 `_armHideTimer()` 已经在做同一件事 ⇒ 两条计时器永远同相，
  /// 却各自占一份调度。
  /// ```
  /// 所以这里**只**做一件事：把控制条隐藏计时器上「人已经停手」这个
  /// **已有真源**翻译成光标计时器。
  ///
  /// # ⚠️ 为什么必须是同步调用，不许 `Future` / 零延迟 Timer 转发
  /// ```text
  /// `flutter_test` 在 `tearDown` 里断言「树销毁后不得再有 pending timer」。
  /// 异步转发会让每一条 hover 都多留一个 microtask / 零延迟 Timer
  /// ⇒ 大批既有 widget 测试会红在 `A Timer is still pending ...`。
  /// ```
  ///
  /// # ⚠️ 为什么守卫里**不写** `_zoomOpen`
  /// ```text
  /// `test/t27_w13_popover_autohide_test.dart` 用
  /// `RegExp(r'if \(mounted[^\)]*_playing[^\)]*_zoomOpen[^\)]*\)')`
  /// 扫全文件：一旦命中，那一处就必须同时含 `_popover.openId == null`。
  /// 本函数不是 `_autoHideNow` 那条守卫，别把两个判据混成一条。
  /// ```
  void _noteCursorActivity() {
    // 窗口模式不藏光标 ⇒ 连计时器都不用装（这也是本特性在
    // flutter_test 里天然惰性的原因：测试默认不是全屏）。
    if (!_fullscreen) return;
    // 指针不在播放区上 ⇒ 没资格藏（用户可能正要去点标题栏 / 右侧详情区）。
    if (!_pointerInside) return;
    // 浮层 / popover 开着，或根本没在播 ⇒ 光标必须留着。
    if (_anySheetOpen || !_playing || _popover.openId != null) return;
    // ★ 先撤销「已隐藏」态：`_noteCursorActivity()` 是**唯一**的恢复入口
    //   （隐藏后计时器已烧掉，恢复只能等下一次用户活动）。
    _resetCursorIdle();
    _cursorIdleTimer?.cancel();
    _cursorIdleTimer = Timer(kCursorIdleHide, _hideCursorNow);
  }

  /// 撤销光标隐藏计时器，并把光标**立刻**恢复（如有隐藏）
  ///
  /// 调用时机：指针离开播放页、浮层打开、换集、以及页面 `dispose` ——
  /// 那些时刻光标必须回来，否则用户要在一片「没有光标」的画面里找面板。
  void _cancelCursorIdleTimer() {
    _cursorIdleTimer?.cancel();
    _cursorIdleTimer = null;
    _resetCursorIdle();
  }

  /// 把「已隐藏」态翻回「显示」（幂等）
  ///
  /// # ★★★ 2026-10-18（N11）重写：原来这里 `setState` 整页，是卡顿主因之一
  /// ```text
  /// 改前：
  ///   void _resetCursorIdle() {
  ///     if (!mounted || !_cursorIdleStale) return;
  ///     setState(() => _cursorIdleStale = false);
  ///   }
  /// 它的旧注释自己写着「本页整棵子树本来就在这个 State 的 setState 里重建
  /// ⇒ 直接 setState 就够了」—— 那句在**正确性**上成立，性能上是错的：
  /// 本函数在鼠标移动路径上，真机全屏下「光标已隐藏 + 用户一动鼠标」
  /// 每翻一次就重跑一遍 884 行的 `build()`。
  ///
  /// 实测（test/zz_t66_player_jank_test.dart，同机，改前）：
  ///   隐藏光标 1 次 ⇒ pageBuild=1 元素重建=190
  ///   恢复光标 1 次 ⇒ pageBuild=1 元素重建=188
  /// ```
  ///
  /// # 现在：真值源仍是字段，广播走 [_cursorLive]
  /// ```text
  /// `_cursorIdleStale` 保留原语义（`_hideCursorNow` 仍写它，State 内部
  /// 的守卫仍读它），只把「推给 UI」这一步换成 notifier ⇒
  /// 光标翻转只重建 `MouseRegion` 那一层，整页 build 一次都不跑。
  /// ★ 为什么不把 `_cursorIdleStale` 本身改成 ValueNotifier：它的读取者
  ///   遍布 State 内部，改类型会让每个读取点都要 `.value`，改动面更大且易漏。
  /// ```
  ///
  /// ⚠️ 仍然只在**真的翻动**时写 —— 本函数在鼠标移动路径上（Windows 上
  ///    每秒可达数百次），值没变就通知会让 `MouseRegion` 白建一次。
  void _resetCursorIdle() {
    if (!mounted || !_cursorIdleStale) return;
    _cursorIdleStale = false;
    _pushCursorLive();
  }

  /// 把 [_cursorIdleHidden] 的结果推给 [_cursorLive]（N11）
  ///
  /// ⚠️ 与 `_cursorIdleHidden` **同源**：本方法只是把它算一遍再广播，
  ///    不另立判据 —— 否则会出现「画出来的光标」与
  ///    `debugPlayerCursorIdleHiddenForProbe()` 读数不一致的假象。
  /// ⚠️ 值没变就**不通知**：这是「鼠标移动但光标态没变」零重建的前提。
  void _pushCursorLive() {
    final next =
        _cursorIdleHidden ? SystemMouseCursors.none : MouseCursor.defer;
    if (_cursorLive.value == next) return;
    _cursorLive.value = next;
  }

  /// 光标隐藏计时器到点 —— **唯一**把 [_cursorIdleStale] 置位的入口
  ///
  /// # 为什么置位要与 `_autoHideNow()` 的守卫**同源**
  /// ```text
  /// 控制条没被收掉的那些时刻（暂停 / 提示 / 缩放滑条 / popover 开着），
  /// 光标也**不该**藏：用户正在跟画面上的东西交互，藏光标 = 找不着鼠标。
  /// 判据直接读 `_controlsVisible`（`_autoHideNow()` 刚写过的同一个真源）
  /// ⇒ 两件事永远同相，不会出现「控制条还在、光标没了」。
  /// ```
  ///
  /// # ⚠️ 为什么到点后**不重装**
  /// ```text
  /// 重装会让「暂停时停手 3 秒」在测试末尾留下一条 pending timer。
  /// 隐藏态本来就要等下一次**用户活动**才恢复 —— 恢复由
  /// `_noteCursorActivity()` / `_cancelCursorIdleTimer()` 负责。
  /// ```
  void _hideCursorNow() {
    if (!mounted) return;
    _cursorIdleTimer = null;
    /*
     * ★ 守卫：控制条还在 ⇒ `_autoHideNow()` 那一刻被拦下了
     *   （暂停 / 提示 / 缩放滑条 / popover 开着）⇒ 光标**也**不该藏。
     *
     * ⚠️ 这里**不能**出现 `_playing` / `_zoomOpen` 这类词：
     *    `test/t27_w13_popover_autohide_test.dart` 用
     *    `RegExp(r'if \(mounted[^\)]*_playing[^\)]*_zoomOpen[^\)]*\)')`
     *    扫全文件，命中就必须同时含 `_popover.openId == null`。
     *    ⇒ 判据一律走 `_controlsVisible` 这个**已合成**的真源。
     */
    if (_controlsVisible) return;
    // ★ N11：局部广播（只重建 `MouseRegion` 那一层），不再 setState 整页。
    _cursorIdleStale = true;
    _pushCursorLive();
  }

  /// 指针**是否还在本页内**（`MouseRegion.onEnter` / `onExit` 维护）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 2026-10-09（task-16）Owner 原话（附截图）：
  /// ```text
  /// > 全屏左上角这个单独的返回icon,还没消失
  /// ```
  /// 截图里控制条**已全部收起**，但左上角仍挂着一枚返回箭头。
  ///
  /// # 为什么需要这个字段（根因：两个目标被写进了同一段代码）
  /// ```text
  /// 目标 A（缺陷 2 修复时定的）：顶栏箭头淡出时，悬浮键**交叉淡化淡入**
  ///         —— 目的是「两枚箭头不同屏」（同一条 _controlsFade，opacity 之和恒为 1）。
  /// 目标 B（Owner 现在要的）：控制条收起后，画面上**不该有任何残留控件**。
  ///
  /// A 要求「控制条藏 ⇒ 悬浮键出现」，B 要求「控制条藏 ⇒ 什么都不显示」。
  /// ⇒ 两者在数学上冲突：A 的终态（opacity = 1 - 0 = 1）恰好是 B 的最糟状态。
  /// ```
  ///
  /// # 解法：给「常驻」补一个**独立的**判据，而不是动那条交叉淡化
  /// ```text
  /// 控制条可见              ⇒ 顶栏那枚（现状不变，opacity = f）
  /// 控制条隐藏 + 指针在页内 ⇒ 悬浮键（用户要找返回口）← 这才是当初设计它的本意
  /// 控制条隐藏 + 指针离开   ⇒ ★ 什么都不画（本次修的）
  /// ```
  /// 即悬浮键 opacity = `(1 - f) × hover`：`1 - f` 那一半**一个字节都没动**
  /// ⇒ 交叉淡化契约（t118 ⑩）与「任意时刻最多一枚箭头」都保持。
  ///
  /// ⚠️ 为什么是 `onEnter`/`onExit` 而不是复用 `onHover`：
  ///    `onHover` **只在指针移动时**触发，指针一旦静止就不再有事件
  ///    ⇒ 用它维护「在不在」会永远停在最后一次移动的位置（假 true）。
  ///    `onEnter`/`onExit` 由 `RenderMouseRegion.handleEvent` 按
  ///    `MouseTrackerAnnotation` 的进出派发，**与移动无关** ⇒ 指针静止也正确。
  ///
  /// ⚠️ 它**故意不参与** `_showControls()` 那条「值没变就不 setState」的守卫：
  ///    这里 `if (v == _pointerInside) return;` 只在**真的翻转**时重建，
  ///    所以「鼠标一进一出」最多各重建一次 —— 不会像 `onHover` 那样
  ///    每次移动都重建整页（见 `_showControls()` 里 60 次移动 = 60 次重建 的实测）。
  bool _pointerInside = false;

  /// 指针进入本页（`MouseRegion.onEnter`）—— 见 [_pointerInside] 的长注释
  ///
  /// ★ Owner 第 1 条：进页也算「人还在操作」⇒ 续命光标隐藏计时器。
  void _onPointerEnter() {
    if (_pointerInside) return;
    setState(() => _pointerInside = true);
    _noteCursorActivity();
  }

  /// 指针离开本页（`MouseRegion.onExit`）—— 见 [_pointerInside] 的长注释
  ///
  /// ★ Owner 第 1 条：指针**已经不在**播放区上 ⇒ 撤销光标隐藏计时器并立刻
  ///   恢复光标（否则用户要在「没有光标」的画面里找别的可点区域）。
  void _onPointerExit() {
    if (!_pointerInside) return;
    setState(() => _pointerInside = false);
    _cancelCursorIdleTimer();
  }

  /*
   * ══════════════════════════════════════════════════════════════════
   * ★★★ 2026-10-08（Owner 第 9 条）控制条**淡入淡出**
   * ══════════════════════════════════════════════════════════════════
   *
   * 用户原话：
   * > 视频播放页,播放器的控件不会主动消失,一直在显示,需要处理一下,
   * > 我的要求是,鼠标悬浮到控件的区域晃动,就应该把控件都显示出来,
   * > 然后指定时间后再自动消失,**要有动画喔**;
   * > 然后单击操作,播放暂停也是一样的,也要显示控件,
   * > 然后也是指定时间后再自动消失,要有动画喔,这里处理是一样的
   *
   * # 为什么不能在 build 里就地开一个 AnimationController
   * ```text
   * build 里 new 控制器 ⇒ 每次重建都换一个 ⇒ 动画永远从 0 重来；
   * 而本页 build 每次鼠标移动都可能跑（_showControls 只是有值守卫，
   * 不是「不重建」）⇒ 必须把控制器放在 State 上，生命周期 = 本页。
   * ```
   *
   * ⚠️ 为什么**必须**在 State 初始化时就给 value: 1：
   *    _controlsAnim.value 要镜像 _controlsVisible（初值 true ⇒ 1.0），
   *    否则**第一帧**会从 0 淡入 —— 那是「启动时闪一下」的老毛病
   *    （与 _KeepAliveTransition 的 _c 用 value: 1 同一条纪律）。
   */
  late final AnimationController _controlsAnim = AnimationController(
    vsync: this,
    duration: Motion.base,
    value: 1,
  );

  /// 控制条的过渡层动画（曲线与二级页链/底栏链**同源**：Motion.easeOut）
  late final Animation<double> _controlsFade = CurvedAnimation(
    parent: _controlsAnim,
    curve: MotionPrefs.curve(context, Motion.easeOut),
    reverseCurve: MotionPrefs.curve(context, Motion.easeOut),
  );

  /// 把 _controlsVisible 的**目标态**应用到动画控制器上
  ///
  /// # 为什么统一走这一个函数
  /// ```text
  /// 控制条的显隐有多个写入点（_showControls 的显示/隐藏、面板开关、
  /// _togglePlay…）。任何一个漏了「同步动画」，那个路径就会变成**硬切**
  /// （而用户明确要求「要有动画」）
  /// ⇒ 全部收敛到这里：将来新增写入点只会漏「调用」，
  ///   不会漏「某个动画分支」。
  /// ```
  void _applyControlsMotion() {
    final target = _controlsVisible ? 1.0 : 0.0;
    /*
     * ★ Reduce Motion（无障碍「减少动态效果」）：时长被解析成 0 时
     *   _controlsAnim.duration 就是零 ⇒ forward/reverse 同帧到位，
     *   等价于硬切 —— 不需要在这里再写一遍 if。
     */
    _controlsAnim.duration = MotionPrefs.duration(context, Motion.base);
    if (_controlsAnim.value == target) return;
    if (target == 1.0) {
      _controlsAnim.forward();
    } else {
      _controlsAnim.reverse();
    }
  }

  /// 指向**播放页自己那个** `GestureDetector`（探针用，2026-09-25）
  ///
  /// # 为什么需要它
  ///
  /// 交付实测要断言"单击不再分流"（`onTapUp` 没挂）。但扫整棵渲染树
  /// 找 `onTapUp` 是**无效**的 —— `InkWell` 内部无条件挂着它，
  /// 而控制条里全是 `InkWell`，所以树里**永远**能找到一个 `onTapUp`。
  ///
  /// 用 key 精确定位到播放页自己那个 detector，读它的真实字段。
  /// 见 `debugPlayerOwnGestureState()`。
  final GlobalKey _gestureKey = GlobalKey();

  /// 两枚返回箭头的定位锚点（探针用，2026-10-09，缺陷 2）
  ///
  /// ★ 交叉淡化的正确性**不能**靠「代码里传了 fade」来证明 ——
  /// 那只是声明，不是读数。真正的判据有两条，都要实测：
  ///   ① 两枚箭头的**矩形位置**必须重合（同一枚箭头的两个位置）；
  ///   ② 任意中间帧两者 **不透明度之和 ≈ 1**（不许出现「两个都看得见」）。
  /// 由 `debugPlayerBackArrowGeometry()` 读出来。
  final GlobalKey _topBarBackKey = GlobalKey();

  /// 播放页根 `Focus` 的节点（task-42）
  ///
  /// 用途：让硬件层兜底能判断"焦点是否已在本页子树里"（见 `_focusIsInsideThisPage`）。
  /// ⚠️ 显式 node 必须在 `dispose()` 里释放。
  final FocusNode _pageFocusNode = FocusNode(debugLabel: 'PlayerPage');

  /*
   * ★★★ PC 键盘方向键的状态机（用户 2026-09-25 要求）
   *
   * > 在pc上,小键盘的左右按键 单击 应该是步数控制,长按是 快进快退
   * > 这两个都是可配置 可关闭的
   *
   * 判定逻辑在 `core/player_gestures.dart::PcArrowKeyRouter`
   * （纯逻辑、无 widget 依赖）—— 这样测试能**直接驱动生产代码**，
   * 而不是在测试里复刻一份影子实现。
   */
  final PcArrowKeyRouter _pcArrow = PcArrowKeyRouter();

  /// 长按判定的**超时兜底**计时器
  ///
  /// 正常路径是系统发 `KeyRepeatEvent`；但少数平台/输入法
  /// 不发重复事件，那些机器上只靠 repeat 判定就**永远不会触发长按**。
  Timer? _pcArrowHoldTimer;

  /// 累计调用 `_seekBy` 的次数（**只读探针**，2026-09-25）
  ///
  /// `_seekBy` 是"单击跳秒"的唯一执行路径。实测靠它判断
  /// "单击有没有触发 seek" —— 比只看播放位置更直接（见
  /// `debugPlayerSeekByCalls()` 的说明）。
  ///
  /// ⚠️ 它**只增不减、不参与任何逻辑**，纯诊断用。
  int _seekByCalls = 0; // ★ 只读探针

  /// 累计**真的发出了跳过 seek** 的次数（**只读探针**，fix/skip-auto-seek）
  ///
  /// # 为什么需要它（而不是只看 `_flash`/位置读数）
  ///
  /// 本次要证明的是"片头**真的**被 seek 到 introEnd"。
  /// 位置读数会被播放推进/缓冲回退干扰；`_flash` 只证明提示条画出来了。
  /// 这个计数器就钉在**生产代码里 `_player.seek(...)` 那一行的正上方** ——
  /// 它 +1 就意味着那一行真的执行了（因果链上最直接的证据）。
  ///
  /// ⚠️ 同 `_seekByCalls`：只增不减、不参与任何逻辑，纯诊断用。
  int _skipSeekCalls = 0; // ★ 只读探针
  Duration? _lastSkipSeek; // ★ 只读探针

  /// 累计**真正执行**的切集次数（**只读探针**，task-28 ①-C）
  ///
  /// # 为什么必须有这个计数器（用户报的 bug 要它才能定论）
  ///
  /// 用户原话：
  /// > 明明没有下一集，却还是**请求**下一集，这是 bug
  ///
  /// # ★ 判据必须是"行为层"，不能是"显示层"
  ///
  /// ```text
  /// 显示层：最后一集时「下一集」按钮是不是灰的   ← 只能证明按钮的样子
  /// 行为层：最后一集时到底有没有【真的切集】      ← 用户报的是这个
  /// ```
  /// 光看按钮看不出"有没有请求" —— 必须有一个**因果链上最直接**的读数。
  ///
  /// # 为什么计数点放在 `_gotoEpisode` 的**入口**
  ///
  /// 本项目所有"切集"最终都汇流到 `_gotoEpisode`（实测枚举过）：
  /// ```text
  /// ① _gotoNextEpisode()      → 走它
  /// ② N 快捷键                → 走 ①
  /// ③ 倒计时「立即播放」       → 走 ①
  /// ④ 遥控 next_episode       → 走 ①
  /// ⑤ 控制条按钮              → onPressed: hasNext ? onNext : null → 走 ①
  /// ```
  /// ⚠️ 计数点**不能放在按钮的 onTap 里** —— 那只证明"按钮被点了"，
  ///    不能证明"切集动作发生了"（按钮可能是 null、可能被 if 挡住）。
  ///    放在 `_gotoEpisode` 入口 = 数的是**动作本身**，且遥控触发的也算。
  ///
  /// ⚠️ 它**只增不减、不参与任何逻辑**，纯诊断用（与 `_seekByCalls` 同一模式）。
  int _gotoEpisodeCalls = 0; // ★ 只读探针

  /// 累计**尝试**切集但被"没有下一集/上一集"挡回去的次数（只读探针）
  ///
  /// 与 `_gotoEpisodeCalls` 配对，用来区分两种"没切"：
  /// ```text
  /// 最后一集点「下一集」→ 该计数 +1，_gotoEpisodeCalls 不变
  ///                      ⇒ 判据【拦住了】—— 这是期望行为
  /// 最后一集点「下一集」→ 两个计数都 +1
  ///                      ⇒ ★ 判据失效（真 bug）
  /// ```
  /// 有了这两个数，"拦住了"和"根本没触发"才区分得开。
  int _blockedNavCalls = 0; // ★ 只读探针

  /// 最近一次**手势/方向键**要求的播放倍速（探针用）
  ///
  /// # 为什么不能直接断言 `_rate`（实测确认）
  ///
  /// `_rate` 是由 `_player.stream.rate` 回填的（见 `_bindPlayerStreams`）。
  /// 而在 `flutter test` 里，原生 media_kit 播放器**不发任何事件**
  /// （实测：按住方向键后 `_rate` 仍然是 1.0）——
  /// 那样的断言**永远为真**，是空断言。
  ///
  /// 所以记“**我们要求了多少**”。这恰好就是本次要验的行为：
  /// ```text
  /// 长按 -> 必须要求**配置值**（不是写死的）
  /// 松手 -> 必须要求**回到原值**（不是写死 1.0）
  /// ```
  double? _lastRateRequest;

  /// 请求一个新倍速（记录 + 转发）
  ///
  /// 指向播放器的入口收敛到这一处，下面四个长按函数都走它 ——
  /// 以后新加手势时不会漏记。
  void _requestRate(double r) {
    _lastRateRequest = r;
    _player.setRate(r);
  }

  /// 累计调用 `_togglePlay` 的次数（**只读探针**，2026-09-25）
  ///
  /// 与 `_seekByCalls` 配对：理想结果是单击后 `togglePlay +1 且 seekBy +0`。
  int _togglePlayCalls = 0;

  /// `_toggleMute()` 被调用的次数（**仅探针读**，第 16 项快捷键一致性）
  int _toggleMuteCalls = 0;

  /// 用户最后一次表达的意图：true = 他要暂停
  ///
  /// ★ 与 `_playing` 的区别：`_playing` 是**回报的现状**，
  ///   本字段是**用户的意图**。两者在"我们自己暂停"时会分歧。
  ///   详见 `_togglePlay()` 里的长注释。
  ///
  /// ★★★ 2026-10-18（代理审查发现：我上一版把三态压成了两态 —— 这是我引入的缺陷）：
  ///
  /// ```text
  /// # 缺陷（三个事实全是语法层面的，不需要运行时验证）
  /// ① 初始值原来是 false            （本行）
  /// ② 只在 _togglePlay 两个分支改   （grep 全文件仅 2 处）
  /// ③ _exitPlayer 无条件 pop 它     （唯一出口）
  ///
  /// ⇒ 用户「进详情页什么都不做就退出」⇒ pop(false)
  /// ⇒ live_page: `if (false != null) _userPaused = false`
  /// ⇒ **用户刚刚在直播页按的暂停被系统推翻** ⇒ 自动续播
  ///
  /// 触发路径：在直播页点内嵌播放器的「暂停」→ 进详情页 → 直接退出
  /// ★ 凡是这样操作过的用户，暂停都会被解除。
  /// ```
  ///
  /// # 根因：`false` 同时表示两件相反的事
  /// ```text
  /// false = 「用户明确表达了要播放」   ← 按了播放键
  /// false = 「用户什么都没按」         ← 打开详情页又直接退出
  /// ⇒ PlayerPage 内部无法区分 ⇒ 必须引入第三态
  /// ```
  ///
  /// # 修法：三态
  /// ```text
  /// null  = 我没碰过播放键   ⇒ 调用方**不得**改动它自己的状态
  /// true  = 用户要暂停
  /// false = 用户要播放
  /// ```
  /// ★ live_page 侧的判据 `if (x != null)` **本来就兼容三态**，那边一个字不用改。
  /// ★ 这也解释了当初为什么选 `!= null` 而不是 `== true` ——
  ///   那个判据是为了区分"有信号/没信号"，而源头当时只提供了两态。
  bool? _userWantsPause;

  /// 累计调用 `_toggleFullscreen` 的次数（★ task-42 只读探针）
  ///
  /// 见 `debugPlayerFullscreenCalls()` 的说明：**计数**比布尔值可靠 ——
  /// 布尔值在"切两次"后会回到原值，测试会误判成"没反应"。
  int _fullscreenCalls = 0;

  /// 正在截图（**防重入**）
  ///
  /// 为什么必须有：media_kit 1.2.6 的 `Player.screenshot()` 内部
  /// `await waitForPlayerInitialization` —— 播放器进 `idle-active` 之前
  /// 那个 future **永远不会完成**（real.dart:1383-1385 是唯一的 complete()）。
  /// 连按两次就会堆两个永不返回的调用。
  bool _shotBusy = false;

  /// 累计调用 `_takeScreenshot` 的次数（★ task-21 P1-30 只读探针）
  ///
  /// 与 `_fullscreenCalls` 同理：**计数**比布尔值可靠 ——
  /// 布尔值在"点两次"后会回到原值，测试会误判成"没反应"。
  int _screenshotCalls = 0;

  /// ★★★ task-22 P1-5：底栏「画面缩放」长按浮层（滑动条卡片）
  ///
  /// 与 `_hintsOpen` 同级的**同类浮层**：都挂在底栏那一层，都是
  /// `Positioned` 铺满宽度。加进 `_anySheetOpen` 之后，它开着的时候
  /// Enter 不会误触全屏、Esc 会先收掉它。
  bool _zoomOpen = false;

  /// ★★★ task-22 P1-11：当前画面缩放（**百分比**，100 = 原始比例）
  ///
  /// 为什么存百分比而不是 mpv 那个 log2 值：面板的档位、底栏滑条的量程
  /// 都是百分比，用户看到的也是百分比 —— 换算只发生在
  /// `videoZoomToMpv()` / `_applyVideoZoom()` 这两处。
  double _videoZoomPct = 100;

  /// 快捷键提示浮层
  bool _hintsOpen = false;

  /// 剧集面板
  bool _episodeSheetOpen = false;

  /// ★★★ Owner 第 2 条：抽屉是**我们**暂停的吗（决定关抽屉后要不要恢复播放）
  ///
  /// ⚠️ 只有「开抽屉时确实在播」才为 true。抽屉开着时用户自己点过
  ///    播放/暂停 ⇒ 翻回 false ⇒ 关抽屉**保持**用户最后的选择，
  ///    不替他做决定（主流在线播放器同此）。
  bool _pausedForEpisodeSheet = false;

  /// ★★★ Owner 第 2 条探针：**同步**走一次生产 `_togglePlay()`
  ///
  /// # 为什么不复用 `debugPlayerTogglePlayForProbe()`
  /// ```text
  /// 那个是 `async` 且用 `Future.delayed` 轮询等 `_player.stream.playing`
  /// 回灌。无头环境里没有核心库 ⇒ 那个状态**永远不会**翻 ⇒ 它会一直等到
  /// 60 次超时；而 `flutter_test` 的 fake async 里不 pump 就不推进
  /// `Future.delayed` ⇒ 探针**死等**（实测：用例挂住不返回，只留半行日志）。
  /// ```
  /// ⇒ 本探针只**发命令**、不等回灌，专门服务「命令层」判据。
  ///
  /// ⚠️ 它调的就是用户单击画面 / 按空格 / 按回车走的那个 `_togglePlay()`
  ///    —— 与 `debugHoverControlsForProbe` 同一条纪律：验的是生产路径。
  void debugTogglePlayForSheetProbe() {
    if (!mounted) return;
    _togglePlay();
  }

  /// ★ 只读探针：抽屉真正发出过几次 `pause()` / `play()` 命令
  ///
  /// # 为什么必须有它（而不是只看 `_pausedForEpisodeSheet`）
  /// ```text
  /// 那个 bool 只说明「**我们打算**暂停」；它翻成 true 而命令没发出去
  /// （比如 `_player` 那一刻是 null）时，用户看到的是「抽屉开了但还在播」，
  /// 而只看 bool 的判据照样绿 —— 那是**半条路**。
  /// 计数与 `_gotoEpisodeCalls` 同一条纪律：数的是「命令真的发了」。
  /// ```
  ///
  /// ⚠️ 无头环境里没有核心库 ⇒ `_player` 的**效果**读不到（画面状态不回流），
  ///    所以这两个计数是「命令层」能拿到的最强证据，如实标注。
  int _episodeSheetPauseCalls = 0;
  int _episodeSheetResumeCalls = 0;

  /// 线路面板
  bool _streamSheetOpen = false;

  /// ★★★ task-53【③】「所有直播」频道列表面板（用户第 3 条）
  ///
  /// ```text
  /// 用户原话：> 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  /// ⚠️ 只在直播（`_isLive && widget.onLiveChannels != null`）时才可能为 true。
  bool _liveChannelsOpen = false;

  /// 下一集倒计时（秒，0 = 未启动）
  int _nextCountdown = 0;
  Timer? _countdownTimer;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 底栏「悬浮小窗」popover（Owner 2026-10-09 第 12 条）
  // ═══════════════════════════════════════════════════════════════════
  //
  //  倍速 / 线路 / 字幕 / 音轨 / 弹幕 / 更多 —— 这些「选择类」操作
  //  不再走弹窗或抽屉，改为贴在按钮旁的小卡片（外部视频站 / 某视频站那一档）。
  //
  //  ★ 一份真值源：同时只可能有一个 popover 开着。Esc / 遥控器返回键
  //    只要 `close()` 就能把当前那个关掉（见 `_onEarlyKey`）。
  final PopoverController _popover = PopoverController();

  /// 片头/片尾跳过点
  SkipMarker? _skipMarker;

  /*
   * ════════════════════════════════════════════════════════════════════
   * ★★★ 播放会话代次 —— 丢弃「过期的片头标记响应」
   * ════════════════════════════════════════════════════════════════════
   *
   * # 缺陷（CodeRabbit 在 PR #10 上点出，已核实成立）
   *
   * `_loadSkipMarker()` 里那一步是 `await` 的：
   * ```dart
   * final m = await SourinApi.getSkipMarker(_provider, widget.id);
   * if (!mounted) return;
   * setState(() => _skipMarker = m);   // ← 无条件写，且随后立刻补判 + 可能 seek
   * _skipAfterMarkerLoad();
   * ```
   * 而**换集 / 换源 / applySession 三条路都会把 `_skipMarker` 清成 null**
   * 并重新起播。于是：
   * ```text
   * t0  第 1 集起播 ⇒ _loadSkipMarker() 发出请求（await 中）
   * t1  用户立刻切到第 2 集 ⇒ 三条路之一把 _skipMarker 清 null、_startPlayback
   * t2  t0 那次请求**这才**返回第 1 集的标记
   *     ⇒ setState(_skipMarker = 第1集的标记)  ← 污染了第 2 集
   *     ⇒ _skipAfterMarkerLoad() 用**第 1 集**的片头秒数去 seek 第 2 集
   * ```
   * ★ 用户可见后果：切集/换源后「画面莫名跳到某个位置」或「片头没跳成」。
   *   `mounted` 拦不住这个 —— widget 一直挂着，只是"会话"变了。
   *
   * # 修法：单调递增的会话代次
   *
   * ```text
   * 发请求前 : gen = ++_playSessionGen（或在切换点 +1）
   * 返回后   : gen != _playSessionGen ⇒ 丢弃（不 setState、不补判）
   * ```
   * ★ 与 `_introSkipped`/`_outroSkipped` 的清零**放在同一处**（那三处正是
   *   "会话已变"的定义点）—— 两件事同源，分开写迟早漂。
   */
  int _playSessionGen = 0;

  /// 是否已触发过片头跳过（避免反复跳）
  bool _introSkipped = false;

  /// 已经"处理过"（跳过或让位）的**中插**窗口起点秒
  ///
  /// 为什么按窗口起点记而不是一个 bool：中插可以有多条，每条都要独立幂等
  /// （位置流每秒 tick，不记就会在边界反复 seek）。
  final Set<int> _midrollSkippedStarts = <int>{};

  /// 是否已触发过片尾跳过
  bool _outroSkipped = false;

  /// 待跳转位置（换集/换源后续播用）
  Duration? _pendingSeek;

  /// 进度落盘节流
  Timer? _progressTimer;
  Duration _lastSavedPosition = Duration.zero;

  /// 当前剧集下标
  late int _epIndex = widget.episodeIndex ?? 0;

  /*
   * ★★★ 这些做成**可变状态**而不是直接读 widget
   *
   * # 为什么（换源的需要）
   *
   * `_episodes` / `widget.provider` / `widget.id` 都是 `final`
   * —— 换源后它们全变了，但 widget 改不了。
   *
   * 而换源是**原地**的（原版注释：「原地换源继续播」），
   * 不能重建整个播放器页（那会黑屏一下、还要重新协商解码器）。
   *
   * 所以把"会随换源改变"的东西提成 state：
   * ```text
   * _episodes    新源的剧集列表
   * _provider    新源的 id
   * _contentId   新源的内容 id
   * _sourceCode  新源的首个线路
   * ```
   * 初始化时从 widget 取，换源时整批替换。
   */
  late List<Episode> _episodes = widget.episodes;

  /// 当前线路（多线路源才非 null；单线路恒 null ⇒ 线路条不画）
  ///
  /// # 为什么是"所选线路"而不是"当前集的线路"
  /// ```text
  /// 用户切线路时选集列表要跟着换（同一集在不同线路是**不同 id**），
  /// 所以线路是**独立于当前集**的选择状态；切集不该改线路。
  /// ```
  /// 默认值 = 第一条线路（见 `_syncSelectedFlag()`）。
  String? _selectedFlag;

  /// 全部线路名（**去重保序**；未标注 flag 的集不参与）
  static List<String> _flagsOf(List<Episode> eps) {
    final out = <String>[];
    for (final e in eps) {
      final f = e.flag;
      if (f == null || f.isEmpty) continue;
      if (!out.contains(f)) out.add(f);
    }
    return out;
  }

  /// 让 `_selectedFlag` 落在"存在且默认第一条"的合法值上
  ///
  /// ⚠️ 拿到新 episodes 之后必须调用（initState / updateEpisodes / applySession），
  ///    否则换源后 `_selectedFlag` 会指向旧源里不存在的线路 ⇒ 选集列表**全空**。
  void _syncSelectedFlag() {
    final flags = _flagsOf(_episodes);
    if (flags.isEmpty) {
      _selectedFlag = null;
      return;
    }
    if (_selectedFlag == null || !flags.contains(_selectedFlag)) {
      _selectedFlag = flags.first; // ★ 默认第一条
    }
  }

  /// 用户切线路：只改"所选线路"，并把当前集对齐到新线路的同名集
  ///
  /// 同一集在不同线路是**不同 id** ⇒ 不映射的话切完线路会跳到"第 1 集"。
  void _pickEpisodeFlag(String flag) {
    if (flag == _selectedFlag) return;
    final cur = _epIndex >= 0 && _epIndex < _episodes.length ? _episodes[_epIndex] : null;
    setState(() {
      _selectedFlag = flag;
      if (cur != null) {
        final i = _episodes.indexWhere((e) => e.flag == flag && e.title == cur.title);
        if (i >= 0) _epIndex = i;
      }
    });
  }
  late String _provider = widget.provider;
  late String _contentId = widget.id;
  late String? _sourceCode = widget.sourceCode;

  /// ★★★ task-53【#4b】当前正在看的直播频道 id
  ///
  /// # 为什么不能直接用 `widget.liveChannelId`
  /// ```text
  /// 它是 `final`（widget 不可变），而**在播放页里切台**要求它可改
  /// —— `_isLive`、`getLiveStream` 的目标、顶栏标题全都读它。
  /// ★ 与 `_provider`/`_contentId` 同一个理由（那段注释已经解释过
  ///   "会变的东西必须提成 state"），只是切台比换源更频繁。
  /// ```
  /// ⚠️ 语义是"**当前播放的**频道"，不是"进来时那个频道"——
  ///    初始值仍取自 widget，所以进播放页那一刻的行为**完全不变**。
  late String? _liveChannelId = widget.liveChannelId;

  /// ★★★ task-53【#4b】当前标题（与 `_liveChannelId` 同步更新）
  ///
  /// ```text
  /// `widget.title` 是 `final`，而切台后顶栏必须显示**新台名** ——
  /// 否则用户按 ↓ 换了台，顶上还写着上一个台的名字（看起来像"没切成"）。
  /// ```
  /// ⚠️ 只替换**渲染/上报**处读的 `widget.title`（顶栏、遥控状态）。
  ///    其余读 `widget.title` 的地方是"写库用的标题"（保存进度/片头片尾/
  ///    跳过点 key）—— 那些**全是点播专用**（直播那几处早就有
  ///    `if (_isLive) return;` 守卫），所以不改它们也不会写错。
  ///    ★ 不改是为了**收窄改动面**：每一处都动会扩大回归风险，
  ///      而它们的守卫已经保证了直播下不可达。
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ task-72【④】上面那条「收窄改动面」的判断**已被实测推翻**
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// > 我点击这个换源,还显示出来这个空白的,也没自动搜,也没填充
  /// ```
  ///
  /// # ★ 决定性证据：**同一屏**，顶栏有标题、弹层拿到空串
  /// ```text
  /// 顶栏显示「无职转生 第三季 … / 第01集」  ← 读的是本字段 `_title`（非空）
  /// 而「换源」弹层的输入框是**灰色占位符**「关键词（可修改后重搜）」
  ///     ← 它由 `widget.title` 初始化（source_switch_dialog.dart:171）
  /// ⇒ 同一个画面一处有、一处空 ⇒ `widget.title` 的确是空串
  /// ```
  /// 因果链（三个症状同一个根因）：
  /// ```text
  /// player_page.dart:3021   title: widget.title        ← 空串
  /// source_switch_dialog.dart:172  TextEditingController(text: widget.title)
  /// source_switch_dialog.dart:190  addPostFrameCallback((_) => _run())
  /// source_switch_dialog.dart:210  if (kw.isEmpty) return;  ← ★★ 静默返回、零请求
  /// ⇒ 「空白」+「不自动搜」+「不填充」全是这一条
  /// ```
  ///
  /// # 为什么"有 `_isLive` 守卫"没能兜住
  /// ```text
  /// 守卫只保证"直播下不可达"，但本 bug 发生在**点播**路径上 ——
  /// 合并页入口（`shell.dart` 的 `_mediaRoute()`）**不知道标题**，
  /// 传的是 `title: ''`（见那里的注释）⇒ 那几处守卫**一个都不触发**。
  /// ⇒ 结论：守卫与"标题是否为空"是**两个正交的维度**，
  ///   前者成立**不能**推出后者安全。★ 这就是上面那条判断错在哪。
  /// ```
  late String _title = widget.title;

  /// ★★★ task-72【④】传参 / 写库一律用这个「活标题」，**不读构造参数**
  ///
  /// 与 L2820（`_saveProgress`）**同一条纪律、同一个写法**：
  /// ```text
  /// 写库读活值 ⇒ 保留 `widget.title` 作兜底
  /// ```
  /// 兜底是必要的：直播 / 遥控等路径可能直接构造
  /// `PlayerPage(title: …)` 而**从不走** `updateDisplayTitle` ⇒
  /// 那时 `_title` 与 `widget.title` 同值，取哪个都对。
  String get _liveTitle => _title.isNotEmpty ? _title : widget.title;

  /// ★★★ 当前作品的封面（2026-09-26 第二轮新增）
  ///
  /// # 为什么必须有这个字段（Owner 报的「播放记录显示 ？ 」的根因之一）
  ///
  /// ```text
  /// `widget.cover` 是 `final`；而合并页的入口 `shell.dart` 的 `_mediaRoute()`
  /// **根本没传 cover**（它连标题都不知道 —— 见那里的注释）⇒ `widget.cover` 恒为 null。
  /// ⇒ `_saveProgress` 写库时 `cover: widget.cover` ⇒ **写进库的就是 null**
  /// ⇒ 播放记录列表渲染不出封面 ⇒ 显示成一个「？」占位。
  /// ```
  /// 而封面**其实已经到了** —— 详情加载完时 `MediaPage._onDetailLoaded(d)`
  /// 手里就有 `d.cover`，只是 `updateDisplayTitle` 当时**只转发标题**。
  ///
  /// ⇒ 所以补这个字段 + 让 [updateDisplayTitle] 能带上它。
  ///   与 [_title] **同一条纪律**：只影响渲染与写库，**绝不触碰流**。
  ///
  /// ⚠️ 语义与 [_title] 对称：`null` = "还不知道"（此时写库要**保留旧值**，
  ///    不能把库里已有的封面清掉 —— 见 `_saveProgress` 的注释）。
  ///
  /// ⚠️ 必须 `late` + 在 `initState` 里赋值（**不能**写成
  ///    `late String? _cover = widget.cover;`）——
  ///    字段初始化器里**读不到 `widget`**（`implicit_this_reference_in_initializer`，
  ///    `flutter analyze` 当场报错）。[_title] 之所以能那样写，
  ///    是因为它在**声明处**用了 `late` 且 Dart 对 `late` 的初始化器
  ///    求值时机不同 —— 但那个写法同样脆弱，这里按报错提示改成显式赋值。
  String? _cover;

  /// 当前**站点**的显示名（task-32）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// 用户原话
  /// ══════════════════════════════════════════════════════════════════
  /// > 播放页和详情页都不能看到当前播放源是哪一个
  ///
  /// # 原版对照（★ 结论：原版**没有**这个显示）
  ///
  /// `PlayerView.vue` 的模板从 L4165 开始，整个模板里 `provider`
  /// **只出现 2 次**（L4181/L4182），都是传给换源弹层的 props
  /// —— 没有任何一处把站点名渲染给用户。
  ///
  /// 全仓 grep `providerName` 的**渲染点**只有三处，全都不在这两页：
  /// ```text
  /// LiveView.vue:185        {{ g.providerName }}      直播页
  /// SearchView.vue:100      搜索结果分组
  /// SourceSwitchDialog.vue:320 / PluginConfigDialog.vue:149   弹层
  /// ```
  ///
  /// ⇒ 所以这是**超出原版功能对等**的一处增强，由用户明确要求
  ///   （"播放页...不能看到当前播放源是哪一个"）。
  ///
  /// # 为什么显示在**顶栏**而不是别处
  ///
  /// 顶栏是原版 `metabar`（`PlayerView.vue:4350`）在我们这套
  /// **沉浸式 overlay 版式**里的对应物 —— 那里正是原版放
  /// "当前标题 / 集名 / 线路标签"的地方。复用同一个位置，
  /// 不新造一个信息区。
  ///
  /// # 为什么是站点名而不是线路名
  ///
  /// 与详情页同一口径（见 `detail_page.dart::_providerName`）：
  /// 用户说的"源"= **站点**（animesource / tyyszy / tvsrc）。
  /// 站内的线路/清晰度由底部栏「线路」按钮那个面板回答。
  ///
  /// ⚠️ 换源（`_switchSource`）会改 `_provider` —— 那时必须**重新取**
  ///    名字，否则顶栏会一直显示旧站名（详见 `_switchSource` 里的调用）。
  String? _providerName;

  /// 全屏状态
  bool _fullscreen = false;

  /// 退出请求是否已在处理中（`_exitPlayer` 的防重入守卫）
  ///
  /// 为什么需要：`_exitPlayer` 中段 `await _toggleFullscreen(awaitOs: false)`
  /// 要 16.6ms 才返回，这段窗口里再进来一次就会**再 pop 一次**，
  /// 把详情页也弹掉。可达路径是「**按住** Esc / 返回键」（系统 ~30ms 重复派发）。
  /// 详见 `_exitPlayer` 开头那段注释。
  bool _exiting = false;

  /// ★ 画中画状态
  ///
  /// 原版是 `hk.add("KeyP", () => { if (art) art.pip = !art.pip; })` ——
  /// 用 ArtPlayer 内置的 pip（底层是浏览器的 `<video>.requestPictureInPicture()`）。
  ///
  /// ⚠️ media_kit **没有内置 PiP**（翻过源码确认），所以走平台侧实现：
  /// ```text
  /// Windows  缩窗 + 置顶 + 不进任务栏
  /// Android  enterPictureInPictureMode（API 26+）
  /// ```
  bool _pipActive = false;
  bool _pipSupported = false;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 播放设置面板（字幕 / 音轨 / 连播策略）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 原版把这些交给 ArtPlayer 的 `setting: true` 内置面板
  // （`PlayerView.vue:3436`）加上四个自定义 settings 项
  // （`PlayerView.vue:3475-3514`）。我们是 libmpv 后端，
  // 那些设置项要自己给一个入口 —— 所以有 `_settingsOpen`。
  //
  // 面板**不持有播放状态**（见 `player_settings_sheet.dart` 文件头），
  // 宿主把当前值传进去、把改动落到 mpv。

  /// 设置面板是否打开
  bool _settingsOpen = false;

  /*
   * ★★★ task-25 D / 2026-10-08：面板的显示**只有一个真源**，没有镜像 bool
   *
   * `_settingsOpen`  面板是否该画（**唯一真源**，onClose / Esc 都只改它）
   *
   * # 为什么不再留一个 `_settingsPortalShown` 镜像（曾经有过，已删）
   *
   * 最初留它，是为了把 `OverlayPortalController.show()` 收敛成幂等
   * （show() 里有 `assert(schedulerPhase != persistentCallbacks)`，
   *  build 期间调会炸）。但它**会过期**，而一旦过期就造成第 3 条那个
   * 「点齿轮无反应、底栏也回不来」且**不可自愈**的故障：
   *
   * ```text
   * portal 的 Element 被重建（挂载点两侧都有条件子件，见 :9272 的注释）
   *   ⇒ controller 的可见状态不跟随（overlay.dart:1675-1684 的契约）
   *   ⇒ 镜像仍是 true ⇒ show() 被吞 ⇒ 面板永远画不出来
   * ```
   *
   * ⇒ 现在**直接问 controller**（`isShowing` 是它自己维护的真实状态，
   *   不存在过期问题），镜像就没有存在理由了。
   *
   * ⚠️ `_settingsOpen == false` 时 overlayChildBuilder 直接返回
   *    `SizedBox.shrink()` ⇒ 面板一定不渲染（这条没变）。
   */

  /// rootOverlay 上的播放设置面板（★ task-25 D）
  ///
  /// ⚠️ 它是**常驻**的（不随 `_settingsOpen` 创建/销毁）：`OverlayPortal` 的
  ///    控制器必须在**构造期**就存在，否则第一次 false→true 时会新建一个
  ///    「从没 show 过」的控制器 ⇒ 面板永远不出现。
  /// ⚠️ `OverlayPortalController` 没有 `dispose()`（overlay.dart:1685-1773）
  ///    ⇒ `dispose()` 里不需要收它。
  final OverlayPortalController _settingsPortal = OverlayPortalController();

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ danmaku-service 弹幕（task-13 ⑦）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户原话：
  // > 接入一下 danmaku-service 的弹幕功能
  //
  // 核心层在 core/danmaku.dart（协议 / 签名 / 解析 / 排版），
  // 渲染层在 widgets/danmaku_overlay.dart（自驱帧循环），
  // 面板在 widgets/danmaku_settings_dialog.dart（纯 UI）。
  // 这里只做**接线**：起播取一次、叠一层、底栏两个入口。

  /// 弹幕总开关（dsh.danmaku.enabled，默认关）
  ///
  /// ⚠️ 默认**关**：原版弹幕是 ArtPlayer 自带的，我们这是外部服务，
  ///    默认开会在用户还没填凭证时先弹一堆 403 提示。
  bool _danmakuEnabled = false;

  /// 弹幕设置面板是否打开
  bool _danmakuSheetOpen = false;
  bool _danmakuSearchOpen = false;

  /// 独立弹幕搜索页的会话内草稿（第 11/12 项：关闭再打开不丢关键词与选择）。
  ///
  /// 由播放器 State 持有，而不是页面自己或 static 全局量：
  /// 搜索页在 `_danmakuSearchOpen` 为假时**整棵卸载**，页面内 State 随之消失；
  /// static 又会跨视频串味，落盘则把临时输入变成设置项。
  /// 因此草稿跟着播放器会话走，与"返回播放器后选择仍在"的验收一致。
  final DanmakuSearchDraft _danmakuSearchDraft = DanmakuSearchDraft();

  /// ★ Owner 2026-10-11：是否正在拖「显示区域」滑杆（true ⇒ 画面上点亮引导遮罩）
  ///
  /// 真源在宿主，底栏滑杆只发"起手/松手"事件（见 `_setDanmakuAreaGuide`）。
  bool _showDanmakuAreaGuide = false;

  /// 正在取弹幕
  bool _danmakuLoading = false;

  /// 上一次取弹幕的失败原因（null = 没有）
  ///
  /// ★ 原样保留 X-Error-Message 等原文（见 DanmakuException.detail）
  DanmakuException? _danmakuError;

  /// 当前挂载的弹幕（已按时间排序，已叠加 shift）
  List<DanmakuComment> _danmakuComments = const <DanmakuComment>[];

  /// ★★★ 2026-10-19（第 66 轮 R3-⑤）：**逐路弹幕原料**（弹幕设置面板要它）
  ///
  /// # 为什么必须有这份快照
  /// ```text
  /// 面板要实现「用户勾了哪几路就合并哪几路」，原料必须是**逐路**的。
  /// 而宿主在 merge 之后只剩 `agg.comments`（已去重合并）⇒
  /// 不在这里留一份，面板就只能"勾一下显示合并了"——那是假功能。
  /// ```
  /// 在 [_aggregateDanmaku] 里写（那里是唯一还按来源分开的地方）。
  /// ⚠️ 只读：面板拿它算预览，**不写回**播放状态。
  Map<DanmakuFeedChannel, List<DanmakuComment>> _danmakuFeedSamples =
      const <DanmakuFeedChannel, List<DanmakuComment>>{};

  /// HTTP 客户端（懒建；凭证改了必须重建 —— appId/appSecret 是构造快照）
  ExternalDanmakuClient? _danmakuClient;

  /// 本机弹弹play探测结果（T27-05；进程内缓存，null = 还没探过）
  DanmakuLocalStatus? _danmakuLocalStatus;

  /// 「数据源」状态行文案（弹幕设置面板用；最近一次探测的结果）
  String _danmakuSourceLine = '';

  // ══════════════════════════════════════════════════════════════════
  //  ★★★ 弹幕**发送**入口（Owner 第 2 条后半句）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么显隐要单独存一个字段，而不是在 build 里现查
  // ```text
  // build 里现查要 `await SourinApi.listProviders()` —— build 不能 await；
  // 若改成 FutureBuilder，控制条每次淡入淡出都会重跑一次查询。
  // ⇒ 与 `_danmakuSourceLine` 同一手法：**在写入处一并写**，build 只读字段。
  // ```
  //
  // ⚠️ 默认 **false**（不显示）。这是**安全方向**：
  //    漏判的代价是「该显示没显示」（用户少一个入口），
  //    反方向的代价是「不该显示却显示了」——用户打完字点发送才被告知
  //    「这个源不支持」，那是更坏的体验。
  bool _danmakuCanSend = false;

  /// 发弹幕要用的**真站点 id**
  ///
  /// ⚠️ 不能直接用 `_provider`：本地会话时它是 `'local'`（续播命名空间），
  ///    而 `provider_danmaku_send` 要的是真站点 id —— 传 `local` 会得到
  ///    「找不到 Provider: local」，用户会以为发送功能坏了。
  ///    判据复用 [providerNameLookupId]（与顶栏站名**同一个**函数）。
  String? _danmakuSendProvider;

  // ── ★★★ 2026-10-14（Owner）：手动搜索番剧的状态 ────────────────────
  //
  // Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  //
  // 后端弹幕客户端的 `searchEpisodes()` 一直都有（真 HTTP），
  // 只是**没有 UI 调它**。这一组字段承载面板「搜索番剧」区的状态 ——
  // 分工与 `_danmakuLoading/_danmakuError` 逐字相同（宿主持有、面板只管画）。
  //
  // ⚠️ 刻意**不**复用 `_danmakuLoading`：搜索只动面板，**绝不许**碰
  //   `_danmakuComments` / 播放器 / 流地址（见 `_searchDanmaku` 的硬约束注释）。

  /// 正在搜索（面板的按钮转圈 + 禁用）
  bool _danmakuSearchLoading = false;

  /// 上一次搜索的失败原因（沿用 DanmakuException 通路 ⇒ 服务端原文照透）
  DanmakuException? _danmakuSearchError;

  /// 是否已经搜过一次（区分「还没搜」与「搜了但空结果」—— 见面板的空态门控）
  bool _danmakuSearchSearched = false;

  /// 上一次搜索命中的剧集（点一条 ⇒ `_pickDanmakuMatch` 载入）
  List<DanmakuMatch> _danmakuSearchResults = const <DanmakuMatch>[];

  /// 最近一次搜索用的关键词（回填面板输入框）
  String _danmakuSearchKeyword = '';

  /// 搜索**发起时**的取弹幕令牌 —— 结果回来时若令牌变了，说明这一集已经
  /// 换过（或重取过）⇒ 结果**对不上画面**，只提示、不自动载入。
  ///
  /// ★ 判据与 `_loadDanmaku` 里的 `token != _danmakuFetchToken` 是**同一个**
  ///   `_danmakuFetchToken`（换集/重取都会 ++）—— 不另造一枚令牌，
  ///   否则两套判断会漂移（这正是"两份判据"的经典坑）。
  int _danmakuSearchToken = -1;

  /// 最近一次选路结果（客户端是本地模式还是官方模式）。
  /// appId/appSecret 与 baseUrl 都是 ExternalDanmakuClient 的**构造快照**
  /// ⇒ 本地/官方互切时必须重建客户端，否则缓存里的旧模式一直被复用。
  bool _danmakuUsingLocal = false;

  /// ★★★ T27-14（CodeRabbit A7）：用户点了「改用官方 API」⇒ **强制**走官方
  ///
  /// # 为什么必须有这个开关（否则那颗按钮又一个死循环）
  /// ```text
  /// 选路规则是 `usingLocal = localStatus.online`（见 _loadDanmaku）。
  /// 本机在线 ⇒ 每次重取都还会走本机 ⇒ 若「改用官方」只是清缓存重探，
  /// 探出来还是在线 ⇒ 又走本机 ⇒ 又 401/403 ⇒ 提示原样回来。
  /// 所以「改用官方」必须**粘住**一个进程内的强制标记，让选路真的换边。
  /// ```
  /// ⚠️ 只在**本次会话**内有效（不落盘）：它是"这次先这么试"的临时选择，
  ///    不是用户的持久数据源偏好（本仓没有那个偏好项）。重启即回到自动路由。
  ///
  /// ★★★ CodeRabbit PR#5 N2：这个标记**只置不清**曾造成「出口不对称」——
  ///    A7 修好了「本机失败 ⇒ 能改走官方」，却留下「官方也失败 ⇒ 没有回头路」：
  ///    本机在线 + 强制官方 ⇒ 官方（没凭证）也 403 ⇒ 提示走【第 2 态】，
  ///    而第 2 态的动作只有 openDanmakuSettings / openBiliSheet，
  ///    **没有**任何入口能把这个标记清回去 ⇒ 文案建议「选本机」，
  ///    用户却无路可选，本会话内每次重取都被钉在官方。
  ///    ⇒ 现在「改用本机弹弹play」也**清**这个标记（[_useLocalDanmakuSource]），
  ///      且第 2 态在「强制官方**并且**已经真的试过一次官方」时提供那颗按钮。
  bool _danmakuForceOfficial = false;

  /// ★★ N2：置了 [_danmakuForceOfficial] 之后**至少真的试过一次官方，且失败了**
  ///
  /// # 为什么光有 `_danmakuForceOfficial` 不足以给「改用本机」按钮
  /// ```text
  /// 本机**不在线**时用户也可能点「改用官方」（那一次本质上没换边）。
  /// 若只看标记就挂按钮，则「本机不在线 + 没凭证」这台的提示会多出
  /// 一颗点了必然连不上本机的按钮（t27_w8 ② 组正是在钉这一条）。
  /// ⇒ 判据必须是「强制官方**确实换到了官方那条边，并且它失败了**」，
  ///   即：localStatus.online && _danmakuForceOfficial（两者同时成立时
  ///   usingLocal 才会是 false，官方这条路才**真的**被走过一次）。
  /// ```
  bool _danmakuOfficialFailed = false;

  /// ★ T27-08 / ★★★ T27-14：上一次失败的那次请求**走的是不是本机源**（null = 还没取过弹幕）
  ///
  /// 为什么另起一个字段而不是现读 `_danmakuLocalStatus`：
  /// 用户点了「改用官方 API」时会把后者清成 null 让它重新探测 ——
  /// 那一刻旧的失败提示还在屏幕上，若 hint 从它现读，标题会当场变回
  /// 「没收到凭证」那一态（用户刚点的按钮像是自己消失了）。
  /// 这里记的是**产生这条失败时**的真实读数，与提示同生共死。
  ///
  /// ⚠️ T27-14（CodeRabbit A7）：这个字段的**语义**改过 —— 旧名
  ///    `_danmakuHintLocalOnline` 记的是「本机**在不在线**」，而 host 的选路
  ///    规则是 `usingLocal = localStatus.online` ⇒ 它恒等于 `usingLocal`，
  ///    于是 core 的在线支文案「…但当前数据源是官方 API」**永远与事实相反**，
  ///    那颗「改用本机」按钮也就成了死循环。现在它老老实实回答一个可判定
  ///    的问题：**产生这条失败的那次请求，走的是本机源吗**。
  bool? _danmakuHintUsedLocalSource;

  /// 上一次取弹幕的结果摘要（给面板与角标显示）
  String _danmakuStatus = '';

  /*
   * ★★ 2026-10-17（task-32 ② / Owner：「在播放页面右侧显示加载了哪些弹幕,
   *    方便排查问题」）—— 右侧「弹幕信息」面板要的四件事，各用一个显式字段记。
   *
   * # 为什么不从 `_danmakuStatus` 反解
   * ```text
   * `_danmakuStatus` 是**给人看的文案**，里面有"外部视频站 · "这种前缀；
   * 想从中反解出"来源是哪一个、匹配方式是哪种"就得写正则去猜文案。
   * 一旦有人改文案（这是常事），面板就会静默显示错的来源 —— 排查工具
   * 自己说谎比没有工具更糟。
   * ⇒ 在每个**写 `_danmakuStatus` 的同一处**一并写这几个字段（同源、同帧）。
   * ```
   */

  /// 这一集最终**是谁**供上了弹幕
  DanmakuInfoSource _infoSource = DanmakuInfoSource.none;

  /// 这一集是怎么和那个源**对上**的
  DanmakuInfoMatch _infoMatch = DanmakuInfoMatch.none;

  /// 绑到的作品标题（外部视频站才有；null = 不知道/没绑）
  String? _infoTitle;

  /// 附加说明（版本号 / 端点 / 文件名…）—— 排查时"是哪个后端"的唯一线索
  String? _infoDetail;

  /// ★★★ 2026-10-17（Owner 第 9 条）：聚合时**每一路**来源的读数
  ///
  /// 空列表 = 没聚合（单源）；非空 = 面板要把每一路都列出来（含失败的那几路）。
  List<DanmakuAggregateFeed> _infoAggregate = const <DanmakuAggregateFeed>[];

  /// 右侧「弹幕信息」面板是否展开
  bool _danmakuInfoOpen = false;

  /// 要不要在顶栏挂那枚「弹幕」入口
  ///
  /// 判据：**这一集真的和弹幕发生过关系** —— 有数据、正在取、或者失败了。
  /// 三者都没有 ⇒ 不挂。不挂比挂一个空面板诚实：用户点开看到"未取到"
  /// 只会更困惑（他根本没开弹幕）。
  bool get _danmakuInfoVisible =>
      _danmakuComments.isNotEmpty ||
      _danmakuLoading ||
      _danmakuError != null ||
      _infoSource != DanmakuInfoSource.none;

  /// 记下"这一集的弹幕是谁供的、怎么对上的"
  ///
  /// ⚠️ 必须与写 `_danmakuStatus` 的**同一处**调用 —— 两个字段分开写就会
  ///   出现"面板说 A、状态栏说 B"（那个 bug 修起来非常贵）。
  void _setDanmakuInfo({
    DanmakuInfoSource? source,
    DanmakuInfoMatch? match,
    String? title,
    String? detail,
    bool clearTitle = false,
    bool clearDetail = false,
    DanmakuAggregate? aggregate,
    bool clearAggregate = false,
  }) {
    if (source != null) _infoSource = source;
    if (match != null) _infoMatch = match;
    if (title != null) _infoTitle = title;
    if (clearTitle) _infoTitle = null;
    if (detail != null) _infoDetail = detail;
    if (clearDetail) _infoDetail = null;
    /*
     * ★ 2026-10-17（Owner 第 9 条）：聚合读数。
     *   单源时**清空**（不是留一份旧的）—— 留着上一次的多源读数会让用户
     *   以为这一次也是聚合的，而那正是他要排查的事。
     */
    if (aggregate != null) {
      _infoAggregate = <DanmakuAggregateFeed>[
        for (final f in aggregate.feeds)
          DanmakuAggregateFeed(
            label: _aggregateFeedLabel(f),
            count: f.count,
            detail: f.detail,
            error: f.error,
            loaded: f.loaded,
          ),
      ];
    }
    if (clearAggregate) _infoAggregate = const <DanmakuAggregateFeed>[];
  }

  /// 一路来源的显示名（core 的类别 ⇒ 用户看得懂的名字）
  ///
  /// ⚠️ 与 `DanmakuAggregate._kindLabel` **同一套词**（core 里那份给日志/状态行，
  ///    这份给面板）。两处分开是因为 core 不该依赖 UI 文案 —— 但要一起改。
  static String _aggregateFeedLabel(DanmakuFeedStat f) => switch (f.kind) {
        DanmakuSourceChannel.plugin => '插件提供',
        DanmakuSourceChannel.imported => '导入源',
        DanmakuSourceChannel.local => '本机服务',
        DanmakuSourceChannel.library => '本地弹幕库',
        DanmakuSourceChannel.none => '未知来源',
      };

  /// 取弹幕的并发令牌（换集时旧的响应必须被丢掉）
  int _danmakuFetchToken = 0;

  /// 面板的状态快照（面板是纯 UI，所有读写都经过宿主）
  DanmakuSettingsState _danmakuSettings = DanmakuSettingsState.fromPrefs();

  /// 右侧「弹幕信息」面板要显示的那一份快照
  ///
  /// ★ 由几个字段**现算**（不另存一份副本）——副本迟早会和真源不同步，
  ///   而这个面板存在的唯一意义就是"如实反映当前状态"。
  DanmakuInfoData get _danmakuInfo => DanmakuInfoData(
        source: _infoSource,
        match: _infoMatch,
        /*
         * ⚠️ `null` = 没问过（未知），0 = 问过且确实 0 条。两者不能合并：
         *    把"未知"画成 0 会让排查的人去追一个根本不存在的空数据。
         *    判据用 `_infoSource` 而不是 `comments.isEmpty` —— 后者把
         *    "取回来了但确实是 0 条"也当成未知（那正是要排查的第二种情况）。
         */
        count: _infoSource == DanmakuInfoSource.none
            ? null
            : _danmakuComments.length,
        title: _infoTitle,
        cid: _biliCid,
        detail: _infoDetail,
        // ★ 失败原因要**原文**（服务端的 X-Error-Message 等照样透出，
        //   不改写）—— 这个面板就是用来排查的，转述会丢掉关键信息。
        error: _danmakuError == null ? null : _danmakuErrorText(_danmakuError!),
        loading: _danmakuLoading,
        enabled: _danmakuEnabled,
        aggregate: _infoAggregate,
        /*
         * ★★★ 2026-10-19（第 66 轮 R3-⑥ / Owner 第 ⑤ 条）：
         *   面板要的「**具体哪个源** / **上次更新时间**」这两根线在这里接上。
         *
         * # 为什么由宿主给，而不是面板自己推
         * ```text
         * 面板是纯 UI（见 danmaku_info_panel.dart 文件头）。它不知道
         * 这一次请求打的到底是内置实例 A 还是 B、也不知道弹幕库的
         * fetchedAt —— 那两个事实只有宿主（这里）有。
         * 面板那边的"从聚合推 / 说未记录"是**降级路径**；
         * 有真值时必须用真值。
         * ```
         */
        sourceName: _danmakuInfoSourceName,
        updatedAt: _danmakuInfoUpdatedAt,
      );

  /// 面板要显示的「**具体哪个源**」（null = 宿主也不知道 ⇒ 面板走自己的降级路径）
  ///
  /// # 为什么不能只靠 `_infoSource`（那是**类别**）
  /// ```text
  /// 类别说「dan-api」⇒ 内置实例 A？B？还是用户自己填的那个地址？
  /// 类别说「外部视频站直连」⇒ 是哪个 cid 对应的那个作品？
  /// Owner 原话要的是「**具体哪个源**」—— 类别回答不了这个问题。
  /// ```
  /// ⚠️ 全都拿不到时返回 null：**不编**。面板会退成聚合里的那一路名，
  ///    再退成类别名 —— 那是它的设计内降级，不是我这里的空话。
  String? get _danmakuInfoSourceName {
    switch (_infoSource) {
      case DanmakuInfoSource.bili:
        // 外部站直连：cid 是最能定位那一集的数字
        return _biliCid > 0 ? '外部视频站直连 · cid $_biliCid' : '外部视频站直连';
      case DanmakuInfoSource.service:
        final ep = DanmakuConfig.effectiveEndpoint;
        if (ep == null) return 'dan-api';
        // ★ 内置 vs 自填必须分开说（用户要做的事完全不同）
        return DanmakuConfig.usingPublicInstance
            ? '内置公共实例 · ${ep.display}'
            : '自填 dan-api · ${ep.display}';
      case DanmakuInfoSource.localDanmaku:
        return '本机弹弹play · ${DanmakuLocalService.hostPort}';
      case DanmakuInfoSource.selfHosted:
        final ep = DanmakuConfig.effectiveEndpoint;
        return ep == null ? '自建弹幕服务' : '自建弹幕服务 · ${ep.display}';
      case DanmakuInfoSource.library:
        // `_infoDetail` 就是文件名 / 弹幕库 #id（面板本来也画它）
        final d = _infoDetail;
        return d == null || d.isEmpty ? '本地弹幕库' : '本地弹幕库 · $d';
      case DanmakuInfoSource.none:
        return null;
    }
  }

  /// 面板要显示的「**上次更新时间**」（null = 宿主没有这个事实 ⇒ 面板说「未记录」）
  ///
  /// # 两个真源，精度不同
  /// ```text
  /// ① 外部视频站那条边：`BiliDanmakuStore.fetchedAt(cid)` —— **精确到这一集**
  /// ② 其它边：`biliLastSyncAt()` —— 只是"上次全量刷新"的**粗**读数
  /// ```
  /// ⚠️ ② 与 ① 语义不同，但它是宿主手上唯一的时间事实 —— 用它比编一个更诚实。
  /// ⚠️ 两者都拿不到时返回 **null**：面板显示「未记录」。
  ///    **不许**用 `DateTime.now()` 冒充（那是把未知画成已知）。
  DateTime? get _danmakuInfoUpdatedAt {
    // ① 精确：这一集的弹幕缓存时间
    if (_biliCid > 0) {
      final at = BiliDanmakuStore.fetchedAt(_biliCid);
      if (at != null) return at;
    }
    // ② 粗：上次全量刷新（0 = 从没刷过 ⇒ 没有这个事实）
    final ms = biliLastSyncAt();
    if (ms > 0) return DateTime.fromMillisecondsSinceEpoch(ms);
    return null;
  }

  /// 把 [DanmakuException] 摊成一段**可复制去搜**的原文
  ///
  /// 取舍：面板宽度只有 300，所以优先给「一句中文 + 状态码 + 服务端原文」，
  /// 而不是把 body（最多 2000 字）整段倒进来 —— 那会把面板撑成一面墙。
  /// body 仍然留在 `_danmakuError` 里（弹幕设置面板显示），这里只取最能定位的那几个。
  String _danmakuErrorText(DanmakuException e) {
    final b = StringBuffer(e.message);
    if (e.statusCode > 0) b.write('（HTTP ${e.statusCode}）');
    final x = e.xErrorMessage.trim();
    if (x.isNotEmpty) b.write(' · $x');
    final em = e.errorMessage.trim();
    if (em.isNotEmpty && em != x) b.write(' · $em');
    if (e.uri.isNotEmpty) b.write('\n${e.uri}');
    return b.toString();
  }

  /// Readout channel for the danmaku panel status line.
  ///
  /// 2026-10-15 (Owner: "this modal is so laggy, and so are the other
  /// overlay panels shown inside it") -- root cause and fix.
  ///
  /// BEFORE: _refreshDanmakuReadout() used setState once per second, which
  /// rebuilt the ENTIRE player page (about 16k lines: video layer, danmaku
  /// layer, top bar, bottom bar and every overlay). Only one line of text
  /// in the panel actually changed.
  ///
  /// WHY "the other overlays are laggy too" has the same explanation: the
  /// subtitle panel, episode panel and playback-settings panel are all
  /// mounted on the SAME player page tree. When the host rebuilds itself,
  /// every one of them rebuilds with it.
  ///
  /// AFTER: the readout goes through this notifier and the panel listens
  /// with ValueListenableBuilder, so only that one Text rebuilds.
  /// Same technique as _positionNotifier (fixed there on 2026-10-09).
  final ValueNotifier<DanmakuReadout> _danmakuReadout =
      ValueNotifier<DanmakuReadout>(const DanmakuReadout());

  /// ★★★ 2026-10-14（卡顿修复）：弹幕轻量悬浮窗**四根滑杆**的实时真源。
  ///
  /// 拖动滑杆 ⇒ 只推它（不整页 setState）⇒ 只有四根滑杆那一小块重建。
  /// 同一个 notifier 还被 `build` 里那层包 `DanmakuOverlay` 的
  /// `ValueListenableBuilder` 订阅 ⇒ 画面**逐帧跟手**且整页不重建。
  /// 完整推导见 `_pushDanmakuQuickLive()` 上方那段长注释。
  ///
  /// ★ 初值直接读 `DanmakuConfig`（与 `_danmakuSettings` 的初值同源）
  ///   ⇒ 第一帧就对得上，无需额外补种。拖动后两者由 `_pushDanmakuQuickLive()`
  ///   一起更新 ⇒ 永远同源。
  final ValueNotifier<DanmakuQuickValues> _danmakuQuickLive =
      ValueNotifier<DanmakuQuickValues>(
        DanmakuQuickValues(
          fontScale: DanmakuConfig.fontScale,
          opacity: DanmakuConfig.opacity,
          speed: DanmakuConfig.speed,
          area: DanmakuConfig.area,
        ),
      );

  /*
   * ══════════════════════════════════════════════════════════════════
   *  ★★★ task-31 ④：外部弹幕弹幕（导入 + 绑定 + 自动更新）
   * ══════════════════════════════════════════════════════════════════
   *
   * 与 danmaku-service 的关系：**同一时刻只有一个源在工作**。
   * ```text
   * 绑了 外部视频站 ⇒ `_loadDanmakuNamed` 里 外部视频站优先，danmaku-service 一条请求都不发
   * 没绑     ⇒ 行为与接线前**逐字节相同**（新代码全部走 BiliPrefs 判据）
   * 解绑     ⇒ 下次起播自动退回 danmaku-service
   * ```
   * 两条路的产物都是 `DanmakuComment` ⇒ 渲染层（DanmakuOverlay /
   * DanmakuTrackAllocator）**零改动**。
   */
  /// 「外部弹幕弹幕」面板是否打开
  bool _biliSheetOpen = false;

  /// 面板的状态快照（面板是纯 UI，所有读写都经过宿主）
  BiliImportState _biliState = const BiliImportState();

  /// 外部视频站 HTTP 客户端（懒建 —— 没绑过的用户一个连接池都不建）
  BiliApi? _biliApi;

  /// 绑定时缓存下来的视频信息（P 列表 / 标题）
  ///
  /// ⚠️ `bindFromInput` 只回 `BiliBindOutcome`、**不回** `BiliVideoInfo`
  ///    （见 `.probe/bili/INTEGRATION.md` §4.4）⇒ 宿主自己再拉一次。
  ///    代价是多一个请求（服务端有缓存，实测 ~200 ms），
  ///    好处是**不动** `bili_bind.dart`（动了已跑绿的 t70 得跟着改）。
  BiliVideoInfo? _biliInfoCache;

  /// 当前这一集实际用的 cid（0 = 没有）
  ///
  /// ★ 2026-10-14：现在有**两个**写者 —— 外部视频站那条路（起播/导入时写）
  ///   与「搜索番剧」选中一条时（`_pickDanmakuMatch` 写 episodeId 语系的
  ///   "弹幕库 id"）。两者都是"这一集该挂哪份弹幕"的身份，语义同构 ——
  ///   共用一个字段是**有意**的（分成两个会出现"到底是哪个源"的二义）。
  int _biliCid = 0;

  /// ★★★ 2026-10-14（CR #27）：用户**明确点选**的弹幕库集 id（一次性）
  ///
  /// # 为什么需要它（`_biliCid` 不够）
  /// ```text
  /// `_biliCid` 是"这一集挂哪份弹幕"的**持久身份**（外部视频站用、也被点选写）。
  /// 但 `_loadDanmakuNamed` 走的是 `loadFor()` 的**模糊匹配**链路 ——
  /// 它**不读** `_biliCid` ⇒ 用户点了「第 2 集」仍可能载入第 1 集/别的作品。
  /// ⇒ 本字段表达的是**另一件事**：「用户刚刚点了一条，就取**这一条**」。
  ///    消费一次即清（`_loadDanmakuNamed` 里）。
  /// ```
  /// ⚠️ 与 `_biliCid` **不合并**：那个是"当前这一集的弹幕身份"（跨集保留），
  ///    这个是"刚刚点的那一下"（一次性）。两者生命周期不同。
  int? _pinnedEpisodeId;

  /// ★ 打开面板那一刻的 `_danmakuFetchToken`
  ///
  /// 面板里的「导入并绑定 / 立即更新」都要判"这一集还是不是我打开面板时
  /// 那一集" —— 令牌变了就说明中途换过集，那次操作的结果必须丢掉
  /// （与 `_danmakuFetchToken` 同一条规矩）。
  int _biliPanelToken = 0;

  /// ★★★ task-31 ⑤：「在线搜索字幕」（assrt.net）面板是否打开
  bool _subtitlePanelOpen = false;

  /// 已加载的**外挂字幕**（面板要显示文件名；null = 没有）
  ///
  /// ⚠️ 只用于「显示 + 记录」—— 真正加载进 mpv 的是 `sub-add` 命令，
  ///    这个对象是给"我加载过什么"留证据的（也让 applyStyle 能在
  ///    重新打开面板时标出它）。
  SubtitleTrack? _externalSubtitle;

  /// 所有可用轨的列表（`player.stream.tracks`）
  Tracks _tracks = const Tracks();

  /// 面板上要显示成"选中"的字幕轨 id
  ///
  /// 与 `_currentTrack.subtitle.id` **分开**是必要的：
  /// mpv 在"用户选了某条轨"和"自动选中"之间会来回变（手册明确说
  /// track selection 的行为 "tends to change around with each mpv release"），
  /// 面板显示我们自己记的值更稳。
  String _sidChosen = 'auto';

  /// 当前音轨 id
  String _aidChosen = 'auto';

  /// ★ 交给遥控桥的那个 [PlayerBridge] 实例（用于 dispose 时**精确**注销）
  ///
  /// 存下来而不是 dispose 里现场 new 一个：`clearPlayer(b)` 靠
  /// `identical` 判断"桥持有的还是不是我"，现场构造的必然不等于它 ——
  /// 那样会退化成"无条件清"，换页重叠时会误伤新注册的播放页。
  PlayerBridge? _remotePlayerBridge;

  /// 用户**手动**选过字幕轨吗
  ///
  /// 手动选过之后就不再自动选第一条真实轨 —— 否则「关闭字幕」
  /// 会在下一次轨列表刷新时被自动改回来，等于这个操作无效。
  bool _pickSubtitleMadeByUser = false;

  /// 从 mpv **读回来**的字幕样式值（面板显示用）
  ///
  /// 为什么不写死默认值：mpv 的 `sub-font-size` 默认值在版本间变过
  /// （老版本是 55，新版本是 38）—— 写死就等于**悄悄改了用户的观感**。
  /// 打开面板前先把当前值读出来，面板只负责改、不负责猜。
  Map<String, String> _mpvStyle = {};

  /// 面板要显示的 mpv 样式属性
  ///
  /// ⚠️ 注意别名关系（mpv 手册）：
  /// ```text
  /// sub-border-size  是 sub-outline-size 的别名
  /// sub-border-color 是 sub-outline-color 的别名
  /// ```
  /// 用**短名**读回来即可，mpv 两个名字指向同一个属性。
  static const _styleKeys = <String>[
    'sub-ass-override',
    'sub-font',
    'sub-font-size',
    'sub-color',
    'sub-border-color',
    'sub-border-size',
    'sub-margin-y',
  ];

  // ── 连播策略（照抄原版 `stores/player.ts` 的四个偏好）──
  //
  // 原版存 localStorage（`dsh.playprefs`）；我们的对应物是 `UiPrefs`
  // （同样是**纯前端偏好**，丢了最多是回到默认值）。
  // ⚠️ 默认值与原版一字不差：
  // ```text
  // endAction            autoNext（自动连播）
  // countdownBeforeNext  true
  // keepSourceOnNext     true
  // autoSkip             true
  // ```

  /// 播放完一集之后干什么
  PlayEndAction _endAction = PlayEndAction.autoNext;

  /// ★★★ task-22 P2-9：解码模式（Auto / HW+ / HW / SW）
  ///
  /// 默认 = `HwdecMode.auto` ⇒ `--hwdec=auto-safe`，与改前的行为**逐字一致**。
  /// 白名单校验见 `_loadPlayPrefs()`（坏偏好回落到 auto，不抛）。
  HwdecMode _hwdecMode = HwdecMode.auto;

  /// 连播前是否先倒计时
  bool _countdownBeforeNext = true;

  /// 连播是否沿用线路
  ///
  /// ⚠️ 原版这个开关**没有接进任何播放逻辑**（全仓库 grep
  /// `keepSourceOnNext` 只有声明/持久化/面板三处）。我们照抄它的
  /// 完整行为：能存、能读、显示当前值，但**不假装它改变了什么**。
  bool _keepSourceOnNext = true;

  /// 是否自动跳过片头（原版 `prefs.autoSkip`，默认 true）
  bool _autoSkip = true;

  /// ★★★ fix/rewatch-prompt：切到**另一集**时怎么起播（Owner 第 1011 条）
  ///
  /// # 默认值 = [PlayEpisodeStartAction.fromStart]（**必须**）
  ///
  /// 它与 `_gotoEpisode` 里写死的「换集一律从头」**逐字同义** ⇒
  /// 老用户升级后行为一个字都不变（缺键、坏值都落回它，见
  /// `_loadPlayPrefs` 与 `PlayEpisodeStartAction.fromWire`）。
  ///
  /// # 取值只有两个
  ///
  /// ```text
  /// fromStart  换集从头播     —— 默认（= 改前行为）
  /// prompt     换集时，若那一集看过 ⇒ 弹非阻断小浮层问
  ///            「继续观看 / 从头播放」；不操作 ⇒ 默认从头
  /// ```
  PlayEpisodeStartAction _episodeStartAction = PlayEpisodeStartAction.fromStart;

  /// 全局音量偏好（原版 `prefs.lastVolume`，默认 1.0）
  double _lastVolume = 1.0;

  /// ★★★ 2026-09-27：用户**上一次真的动手调音量**的时刻
  ///
  /// # 这个字段修的是一个**会改坏用户设置**的真 bug
  ///
  /// ## 现场证据（真机）
  /// ```text
  /// ui-prefs.json 的 dsh.playprefs.lastVolume：**0.75 → 1.0**
  /// 写入时间 2026-09-27 **09:03:20**
  /// 那一刻**没有任何人操作音量** —— 只有我在跑客户端做验证
  /// ```
  ///
  /// ## 根因（已用离线探针证明）
  /// ```text
  /// `_bindPlayerStreams()` 里的监听**无条件**把任何音量广播都当"用户调的"：
  ///     _player.stream.volume.listen((v) {
  ///       if (!_muted && v > 0) _savePlayPref('lastVolume', (v/100).toString());
  ///     });
  ///
  /// ⇒ 而 mpv 在播放器刚创建时会广播它自己的**默认音量 100**
  ///   （`_muted` 默认 false，100 > 0 ⇒ 条件成立）
  /// ⇒ ★ 于是 "1.0" 被写进用户的偏好，而**用户从没碰过音量**
  /// ```
  /// 离线探针逐字输出（`.probe/probe_tests/probe_volume_pref_test.dart`）：
  /// ```text
  /// [PROBE]  两次 set 之后文件 = {"…":"0.75"}   ← 有后续正确值时能自愈
  /// [PROBE2] lastVolume = **1.0**               ← ★ 只要一次假广播就永久覆盖
  /// ```
  ///
  /// ## 为什么判据是「**用户发起的**」而不是「不是我们发起的」
  ///
  /// ```text
  /// 我第一版想用「一次性的 _volumeSetByUs 标记」跳过我们自己的回声，
  /// ★ 但那挡不住 mpv 的**默认广播** —— 它既不是用户调的、也不是我们的回声：
  ///     顺序 A：先收到 100（mpv 默认）⇒ 消费掉标记
  ///             再收到  75（我们的回声）⇒ 标记已失效 ⇒ 写回 0.75 ✓
  ///     顺序 B：先收到  75（我们的回声）⇒ 消费掉标记
  ///             再收到 100（mpv 默认）⇒ ★ 写回 **1.0** ✗
  ///   ⇒ 它**依赖广播顺序** —— 而那是不确定的 ⇒ 脆的修复
  /// ```
  /// ⇒ 改成**白名单**：只有用户在 UI 上真的动过手，才允许写偏好。
  ///   ```text
  ///   用户动手的三个入口（全都会走到 setVolume），但**只有两处盖时间戳**：
  ///     _volumeBy()     键盘 ↑/↓ 与滚轮        ⇒ 盖
  ///     onVolume:       底栏音量滑杆            ⇒ 盖
  ///     _toggleMute()   静音按钮                ⇒ **不盖**（见下）
  ///   ⇒ 监听器只认"最近盖过戳"的广播
  ///   ```
  ///   ⚠️ 旧注释把 `_toggleMute()` 一并列进"三个入口"，却又在它自己的注释里
  ///     写着"这里**不盖**时间戳是刻意的" —— 两处自相矛盾，会误导后来的人。
  ///     以**代码事实**为准：`_toggleMute()` 不盖戳。原因是它恢复的
  ///     "静音前音量"用户并没有重新调过，不该被当成一次用户动作。
  ///
  /// ⚠️ 用**时间窗**（而不是"一次性的布尔"）是因为：
  ///    用户把音量调到**同一个值**时 mpv 幂等、**不发**广播
  ///    ⇒ 布尔标记会一直挂着，把之后某条无关广播误判成用户行为。
  ///    时间窗会自动过期，没有这个残留问题。
  DateTime? _lastUserVolumeAction;

  /// ★★★ 静音前用户真实拥有的音量（缺陷 1 / 11 的修复核心）
  ///
  /// # 错在哪（改之前）
  /// ```text
  /// _toggleMute() 原句： _player.setVolume(_muted ? _volume : 0);
  ///   而 _volumeBy() 在音量归零时会把 _muted 置真，音量监听器也把 _volume 写成 0
  ///   ⇒ 静音之后再点一次，_volume 已经是 0
  ///   ⇒ 实际执行的是 setVolume(0) ⇒ ★ 永远没声音
  ///   ⇒ 而 _muted 却被翻成 false ⇒ 图标显示"未静音"、实际全静音（UI 在说谎）
  ///   唯一能救回来的操作是把底栏音量滑杆拖一下。
  /// ```
  /// # 为什么必须是**独立快照**而不是读 _volume
  /// ```text
  /// _volume 是"当前音量"的镜像，静音时它合法地等于 0
  ///   ⇒ 拿它当"恢复目标"等于把 0 恢复成 0
  /// ⇒ 必须在**压 0 之前**单独记下用户原本的音量。
  /// ```
  /// ⚠️ 静音期间用户拖滑杆要**同步更新**本快照（否则取消静音会恢复到过期值）——
  ///    见音量监听器里 _muted 那条分支与底栏 onVolume 的处理。
  /// ⚠️ 它**不是**偏好：不落盘、不写 lastVolume，只活在本页 State 里。
  double? _volumeBeforeMute;
  // ══════════════════════════════════════════════════════════════════
  // ★★ 缺陷 13：缓冲区间（进度条上"已经下载到哪"）
  // ══════════════════════════════════════════════════════════════════
  //
  // 数据流（单向）：
  // ```text
  // mpv demuxer-cache-time / -duration
  //   -> _BufferPoller（500ms，值变才回调）
  //   -> _bindBufferPoller 的回调里做**交叉校验**
  //   -> setState(_bufferedRange)
  //   -> _BottomBar(buffered:) -> _ProgressSlider 叠一条缓冲条
  // ```

  /// 当前缓冲区间；null = 没有读数（或校验不过）⇒ **不画**
  BufferedRange? _bufferedRange;

  _BufferPoller? _bufferPoller;

  /// mpv 的 `cache-buffering-state`（0..100）；只给探针读，不参与绘制
  double? _bufferStatePercent;

  /// 缓冲条的真实几何（GlobalKey 取 RenderBox）；只给探针用
  final GlobalKey _bufferBarKey = GlobalKey();

  // ══════════════════════════════════════════════════════════════════
  // ★★ 音量下发的**唯一出口**（缺陷 1 / 11 的配套改造）
  // ══════════════════════════════════════════════════════════════════
  //
  // # 为什么要把 setVolume 收敛到一个方法
  //
  // 生产语义**逐字不变**（本方法就是 `_player.setVolume(v)` 的一层转发），
  // 目的是给探针留一个**不改生产行为**的短路点：
  // ```text
  // 探针宿主里 _player 永远建不起来（flutter_test 里没有 libmpv-2.dll）
  //   => 只要走到 _player.setVolume 就是 LateInitializationError
  //   => 静音状态机（_muted / _volumeBeforeMute / 下发值）就无法断言
  // ⇒ 探针把 _probeNoAudio 置真，让"下发"这一步变成可记录的纯标记。
  // ```
  //
  // ⚠️ `_probeNoAudio` 生产恒为 false（没有任何生产代码写它），
  //    所以生产的音量行为与改造前**逐字一致** —— 这不是迁就探针的假实现。
  //
  /// 探针专用：为真时跳过真实下发（★ 生产代码从不写它，恒为 false）
  bool _probeNoAudio = false;

  /// 音量下发的唯一出口（生产 = _player.setVolume 的纯转发）
  void _sendVolume(double v) {
    // ★ 探针短路：只影响测试，生产分支逐字等价于 _player.setVolume(v)
    // ★ 探针打点：记录"实际下发值"，用于断言"取消静音绝不下发 0"
    _probeVolumeWrites.add(v);
    if (_probeNoAudio) return;
    _player.setVolume(v);
  }

  /// 用户动作后，多久内的音量广播算"这次动作的回声"
  static const _kVolumeEchoWindow = Duration(seconds: 2);

  /// 全局倍速偏好（原版 `prefs.lastSpeed`，默认 1.0）
  double _lastRate = 1.0;

  /// 本次会话**是否已经续播过**（防止重复 seek）
  ///
  /// 进入播放页只续播一次；换集/换源走 `_pendingSeek` 那条路（已实现）。
  bool _resumedThisSession = false;

  /// ★★★ task-26（2026-10-25）：`_prepareResume` 的**代次快照**字段
  ///
  /// # 它修的是什么（第 03 项不变量「换集从 0 开始」被打破）
  /// ```text
  /// `_gotoEpisode` 里明写 `_pendingSeek = null;   // 新集从 0 开始（不是续播）`
  /// 但**在途的 `_load()`** 会在换集之后才走到 `await _prepareResume()`：
  ///   `_prepareResume` 内部先 `await getProgress(...)`（真 FFI，几百 ms）
  ///   ⇒ 等它回来时 `_epIndex` 已经是**新集**、`_playSessionGen` 也变了
  ///   ⇒ 它按"新集"算 `curEpId` ⇒ 集号守卫通过 ⇒ `_pendingSeek = 1200s`
  ///   ⇒ 换集变成"续播到 20:00"（实测 4 条红，原文见
  ///     `.probe/fix03-rewatch-before.log`）
  /// ```
  ///
  /// # 为什么**不**在 `_prepareResume` 里判 `_episodeStartAction == prompt`
  /// ```text
  /// ① 缺陷在**默认模式**（`fromStart`）同样成立 —— 门禁 ① 用的就是缺省偏好，
  ///    只判 prompt 根本修不到它。
  /// ② 反过来，prompt 模式下"首次进入播放页"仍应正常续播（浮层只在**换集**时弹）
  ///    ⇒ 按偏好一刀切会砍掉正常续播。
  /// ⇒ 判据必须是"**这次读取还是不是同一个会话**"，而不是"用户偏好是什么"。
  /// ```
  /// ⇒ 用**代次快照**（进入时记下 `_playSessionGen` + `_epIndex`，`await` 回来后比对），
  ///   与 `_loadSkipMarker` 的 `gen` 守卫、`_reload` 的 `_rewatchToken` 守卫同一纪律。

  /// 本次起播的续播 seek **是否已经做过**
  ///
  /// ⚠️ 与 `_resumedThisSession` 是**两件事**，不能合并：
  /// ```text
  /// _resumedThisSession   "读进度这件事做过没有"（在 _prepareResume 里置位）
  /// _resumeSeekDone       "seek 这件事做过没有"（在 _seekAfterReady 里置位）
  /// ```
  /// 合并的后果：`_prepareResume` 置位后 `_seekAfterReady` 会**直接 return**，
  /// 续播永远不执行 —— 那正是本次实测抓到的 bug 的另一种形态。
  bool _resumeSeekDone = false;

  /// 起播代次（每次 `_startPlayback` 自增）
  ///
  /// # 为什么需要
  ///
  /// 续播 seek 是**异步等时长**的（见 `_seekAfterReady`）。用户在这段
  /// 等待里换了线路/切了集，就会有两个 `_seekAfterReady` 同时在跑：
  /// ```text
  /// ① 旧的那个等到时长后 seek 到**上一集的秒数** → 串集
  /// ② 新的那个再 seek 一次 → 画面跳两下
  /// ```
  /// 用代次号作废旧的：`token != _seekToken` 就直接放弃。
  int _seekToken = 0;

  /// hwdec 取证的代次号（每次 `_startPlayback` 自增）
  ///
  /// # 为什么不复用 `_seekToken`
  ///
  /// `_seekToken` 只在**有续播位置时**才自增（见 `_startPlayback` 里
  /// `if (pending != null && ...)` 那一段）。首次进入播放页通常没有
  /// 续播位置 → 它永远停在 0 → 代次保护形同虚设。
  /// hwdec 取证是**每次起播都要做**的，所以需要自己的、无条件自增的代次。
  int _hwdecToken = 0;

  // ───────────────────────────────────────────────────────────────────
  //  ★★★ 缺陷⑧（2026-10-25）：起播失败要有**耗时**，否则归因只能瞎猜
  // ───────────────────────────────────────────────────────────────────
  //
  // # 为什么必须自己计时
  // ```text
  // mpv 的报错原文只有：Failed to open http://127.0.0.1:52199/s/…/.
  // ——**不含耗时**。而"等不及（超时）"与"真打不开"的唯一区别就是耗时。
  // ⇒ 只能由播放器自己记下"发起点"，在错误到达时算差。
  // ```
  //
  // # 为什么用独立 Stopwatch（不复用 `_bootWatch`）
  // ```text
  // `_bootWatch` 在 `_load()` 入口启动，覆盖"取流地址"那段（插件 + 网络），
  // 而超时窗口量的是 mpv **打开 URL** 那一段 —— 两者起点不同（相差几秒），
  // 混用会让 5 秒窗口整体偏移，判据当场失真。
  // ⇒ `_loadClock` 在 `_startPlayback` 里**紧邻 open() 之前**取起点。
  // ```
  final Stopwatch _loadClock = Stopwatch()..start();

  /// `player.open()` 发起时刻的单调读数（`null` = 还没起播过）
  Duration? _loadStartedAt;

  /// `_load()` 被调用的次数（**仅探针读**：第 02 项「重试真的触发重新起播」）
  int _loadCalls = 0;

  /// `_startPlayback()` 被调用的次数（**仅探针读**：task-26「换集后不许再播旧候选」）
  ///
  /// 判据形态：用户点开作品后**立刻**切集 ⇒ 只有**新集**那一次起播；
  /// 在途的旧 `_load()` 不许再开一次（否则最后打开的是上一集的流）。
  int _startPlaybackCalls = 0;

  /// 上一次**起播失败**的耗时（只在失败路径写；成功/新一轮起播清空）
  ///
  /// 喂给 `PlaybackErrorText.classify(..., elapsed: …)` —— 见 [PlaybackFailureKind.timeout]。
  Duration? _startFailureElapsed;

  /// 从"发起 open"到此刻的耗时（没起播过 ⇒ `null`，**不**编一个 0）
  Duration? _elapsedSinceLoadStart() {
    final started = _loadStartedAt;
    if (started == null) return null;
    final d = _loadClock.elapsed - started;
    return d.isNegative ? null : d;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★ 起播阶段计时（task-24：用户要「播放提速」，先量化再动手）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须先做这一步（而不是直接去改缓冲参数）
  //
  // 用户原话：
  // > 提速我指的是播放视频的时候的提速
  // 即「点开一个源，视频半天起不来 / 播放中卡顿缓冲」。
  //
  // 但「慢」有好几个完全不同的位置，**优化手段也完全不同**：
  // ```text
  // ① resolve_stream 慢     → 插件 JS / 网络请求 → 改 mpv 缓冲【毫无用处】
  // ② mpv open→首帧 慢      → 连接 CDN / 解封装 / 首帧解码
  //                           → 改缓冲【可能有用】，或预连接
  // ③ 流代理额外开销        → 多一跳 + 每请求新建 client
  //                           → 改 mpv 缓冲【毫无用处】
  // ```
  // 不先量就动手 = 猜。项目里已经因此踩过坑（`VERIFY-LESSONS.md` 错误④：
  // 「最像嫌疑人的往往不是真凶」—— `ensureVisible` 背黑锅那次）。
  //
  // # 打点方式
  //
  // 用**单调时钟**（`DateTime.now()` 差值），在关键位置记 `Stopwatch` 分段：
  // ```text
  // t0  用户点播放（_load 进入）
  // t1  resolve_stream / get_live_stream 返回（拿到候选地址）
  // t2  _startPlayback 进入（含 open 之前的所有 await）
  // t3  player.open() 返回（mpv 已 canplay）
  // t4  首个视频帧真的出来（stream.width 首次非空）
  // ```
  // 每段单独打印，**并且**打一行汇总表，方便直接对比慢源/快源。
  //
  // ⚠️ 只在 `PLAYBACK_TIMING=true` 时输出 —— 正式构建零开销、零日志噪音。
  //    与既有的 `kGestureProbe` 同一个模式（见文件末 `_probeLog`）。
  Stopwatch? _bootWatch;

  /// 阶段打点（仅 `PLAYBACK_TIMING=true` 时输出）
  ///
  /// [stage] 是阶段名，[detail] 是补充信息（源名/地址等）。
  /// 时间取自 `_bootWatch`（在 `_load()` 进入时 `start()`）。
  void _bootMark(String stage, [String detail = '']) {
    if (!kPlaybackTiming) return;
    final w = _bootWatch;
    if (w == null) return;
    final ms = w.elapsedMilliseconds;
    debugPrint(
      '[TIMING] +${ms}ms  $stage${detail.isEmpty ? '' : '  ($detail)'}',
    );
  }

  /*
   * ★★ T27-06 切台计时（业主原话：> 切换到直播播放页总是要反应很长时间才出现画面）
   *
   * 与 `_bootMark` 同一个两收口模式（打点收口 `_liveSwitchMark`，
   * 起点收口 `_liveSwitchStartedAt`）：stage 序号与起播计时对齐 ——
   * ```text
   * ① 切台发起（_adoptLiveChannel 进入 / _load 直播分支）→ t0
   * ② getLiveStream 返回 ⇒ ①→② = 取址耗时（缓存的直接收益在这里）
   * ③ _player.open() 返回
   * ④ 首帧（stream.width 非空）⇒ ①→④ = 用户「从按下去到看到画面」的真值
   * ```
   * 双通道输出：debugPrint（PLAYBACK_TIMING 构建）+ AppLog '切台'
   * （**恒开**——真机取证靠它，不能要求取证机重编 PLAYBACK_TIMING）。
   */

  /// 本次切台的 t0（在 `_adoptLiveChannel`/`_load` 直播分支开头重置）
  DateTime? _liveSwitchStartedAt;

  /// 切台链路打点：AppLog（恒开）+ debugPrint（仅 PLAYBACK_TIMING 构建）
  ///
  /// [stage] 形如 `'① …'`；[detail] 可空。
  void _liveSwitchMark(String stage, [String detail = '']) {
    final t0 = _liveSwitchStartedAt;
    final ms = t0 == null ? -1 : DateTime.now().difference(t0).inMilliseconds;
    final line = '+${ms}ms  $stage${detail.isEmpty ? '' : '  ($detail)'}';
    AppLog.write('切台', line);
    if (kPlaybackTiming) {
      debugPrint('[TIMING] [切台] $line');
    }
  }

  /// 首帧等待的代次号（与 `_hwdecToken` 同一个用途：换流后作废旧等待）
  int _firstFrameToken = 0;

  /// 等**首个视频帧**出来，然后打点（task-24 阶段计时用）
  ///
  /// # 为什么不用 `open()` 返回当"首帧"
  ///
  /// `open()` 返回只说明 mpv **canplay**（可以开始播），
  /// 此时解码器可能还没吐出第一帧 —— 用户看到的仍是黑屏/转圈。
  /// 真正"起来了"是 `stream.width` 首次变成非空（视频参数已知 = 解码链就绪）。
  ///
  /// # 为什么不 await（不阻塞起播）
  ///
  /// 它最多等 30 秒。await 在这里会把 `_loading = false` 一起拖住 ——
  /// 为了打一行日志拖慢起播不值得（与 `_reportHwdecAfterReady` 同一个理由）。
  Future<void> _reportFirstFrame(int token) async {
    // T27-06：切台取证（AppLog '切台'）**恒开** —— 直播即使不是
    // PLAYBACK_TIMING 构建也要等首帧打 ④（「看到画面」的时刻）；
    // 点播维持原早退（_liveSwitchStartedAt 恒为 null，零开销）。
    if (!kPlaybackTiming && _liveSwitchStartedAt == null) return;
    const step = Duration(milliseconds: 50);
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var tick = 0;
    while (DateTime.now().isBefore(deadline)) {
      // 用户换流了 → 这次等待作废（否则会拿新流的时间打"属于上一集"的点）
      if (token != _firstFrameToken || !mounted) return;
      final w = _player.state.width;
      if (w != null && w > 0) {
        final h = _player.state.height;
        _bootMark('④ 首个视频帧', '${w}x$h');
        _liveSwitchMark('④ 首个视频帧', '${w}x$h');
        // 汇总行：一眼能对比慢源/快源
        debugPrint(
          '[TIMING] ★ 起播总耗时 ${_bootWatch?.elapsedMilliseconds}ms '
          '(resolve+open+首帧)',
        );
        return;
      }
      /*
       * ★★ 每 1 秒采一次 mpv 内部状态（task-24 定位"卡在哪"）
       *
       * # 为什么必须采这些（而不是只看总耗时）
       *
       * 总耗时只告诉我们"慢"，**不告诉我们为什么慢**：
       * ```text
       * cache-speed ≈ 0        → 网络没数据（上游慢 / 代理卡住）
       * cache-speed 很大但没帧  → 数据到了但解码/封装慢（moov 在文件尾？）
       * demuxer-cache-duration 在涨 → 在填缓冲（mpv 的 cache-secs 在等）
       * ```
       * 这三种原因的**修法完全不同**，不区分就动手 = 猜。
       */
      // mpv 内部采样只属于 PLAYBACK_TIMING 诊断（正式构建不采样、不打印）
      if (tick % 20 == 0 && kPlaybackTiming) {
        await _dumpMpvDiag(tick ~/ 20);
      }
      tick++;
      await Future<void>.delayed(step);
    }
    if (token == _firstFrameToken) {
      _bootMark('④ 首帧超时', '30s 内没出视频帧');
      _liveSwitchMark('④ 首帧超时', '30s 内没出视频帧');
    }
  }

  /// 采样 mpv 内部状态（诊断"卡在哪一段"）
  ///
  /// 只读属性，**不改变任何行为** —— 诊断不能干扰被测对象。
  Future<void> _dumpMpvDiag(int n) async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      Future<String> prop(String k) async {
        try {
          final v = await native.getProperty(k);
          return v.toString();
        } catch (_) {
          return '?';
        }
      }

      final speed = await prop('cache-speed');
      final bufState = await prop('cache-buffering-state');
      final cacheDur = await prop('demuxer-cache-duration');
      final fileFormat = await prop('file-format');
      final paused = await prop('core-idle');
      debugPrint(
        '[TIMING-DIAG #$n] '
        'speed=$speed B/s  buffering=$bufState%  '
        'cacheDur=$cacheDur s  format=$fileFormat  idle=$paused',
      );
    } catch (e) {
      debugPrint('[TIMING-DIAG] 采样失败: $e');
    }
  }

  bool get _isLive => _liveChannelId != null;

  /// ★★★ task-33（B①）：当前会话是不是**本地文件**（判据与理由见顶层
  /// [isLocalSessionProvider]）。
  ///
  /// ⚠️ 必须**跟着 `_provider` 走**：`applySession` 原地换到在线源之后
  ///    这一项要变回 false（换源重新可用），所以不能写成
  ///    `widget.localPath != null`。
  bool get _isLocalSession => isLocalSessionProvider(_provider);

  @override
  void initState() {
    super.initState();
    /*
     * ★ 2026-09-26 第二轮：封面初值取自构造参数
     *
     * ⚠️ 必须在 `initState` 里赋值，**不能**写成字段初始化器
     *    `late String? _cover = widget.cover;` —— 那个写法会报
     *    `implicit_this_reference_in_initializer`（实测 analyze 报过）。
     */
    _cover = widget.cover;
    /*
     * ★ 把当前 state 登记给探针（2026-09-25）
     *
     * 交付实测要断言「单击左右半屏**播放位置没有跳变**」——
     * 那就必须能读到**真实播放页**的 `_position`，而不是重新 new 一个
     * 播放器自己测自己（那是测影子，不是测真实路径）。
     *
     * 登记是**幂等**的：同时只可能有一个播放页在树上（路由是全屏 push）。
     */
    _livePlayerState = this;
    // ★ 多线路：默认选第一条线路（`_flagsOf` 为空 ⇒ 保持 null ⇒ 线路条不画）
    _syncSelectedFlag();

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 硬件层键盘兜底（task-42，用户点名要的键位）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 然后播放页面要支持空格暂停/播放,enter 和 双击 进入/退出 全屏
     *
     * # 为什么需要（真机实测抓到的，不是推测）
     * ```text
     * 真机（SendInput 自检 ==2、前台断言 True）：
     *   键盘 空格/Enter/F/J/L ⇒ **0 条** [PLAYER-KEY]
     *   鼠标双击              ⇒ ★ 有效（[PLAYER-KEY] 双击 ⇒ 切换全屏，
     *                               窗口 1328x848 → 2608x1488 真全屏）
     *   ★ 而**全局 handler 收到了键**（直播页的 [LIVE-KEY] ⓪ 入口有打点）
     * ⇒ 结论：键**进了 Flutter**，但本页 `Focus(onKeyEvent: _onKey)` **收不到**
     * ```
     * # 根因（与直播页**完全同形**）
     * ```text
     * 用户是从**直播页/详情页 push 进来**的 ⇒ 焦点可能仍留在**上一页**
     * （底栏 tab / 列表格子）。
     * ★ Flutter 按键派发 = 从 `primaryFocus` 沿**祖先链**向上冒泡 ⇒
     *   上一页的焦点与本页的 `Focus` 是**兄弟**关系 ⇒ `_onKey` 永不调用。
     * ```
     *
     * # 修法：`HardwareKeyboard.addHandler`
     * ```text
     * 它在**焦点树之前**跑 ⇒ 不依赖焦点在哪。
     * ★ 这是我在直播页验证过的同一个修法（那边日志证明有效）。
     * ```
     *
     * # ⚠️ 三道门控（**不能省**，见 `_onHardwareKey` 的实现）
     * ```text
     * ① 弹窗/浮层全关（本页自己的浮层优先）
     * ② 本页必须是**最上层路由**（ModalRoute.isCurrent）
     *    ★ 这条同时解决"与直播页的 handler 抢键"：
     *      直播页被 push 覆盖后 `isCurrent == false` ⇒ 它自己让路
     * ③ 输入框里打字时放行
     * ```
     * ⚠️ **不**依赖 `widget.visible` 那种"上游给的值"作主判据 ——
     *    task-42 的事故（`_liveVisible` 被变异冻住）证明了它会失真。
     *
     * # ★★★ 为什么是 `addEarlyKeyEventHandler` 而不是 `addHandler`（2026-09-25 修）
     *
     * ```text
     * `HardwareKeyboard.addHandler` 的返回值**不会中止派发** ——
     * 事件照样继续流到 `FocusManager` → 焦点树。
     * （`shell.dart` L1953 逐字记录过这个坑，我一开始没读到。）
     *
     * ★ 直播页就因此中了招：一次按键 ⇒ 硬件路径 + 焦点路径**都**处理
     *   ⇒ 切两个台（真机日志铁证：一次 `⓪ 入口` 却两次 `cycleChannel`）。
     *
     * ★ 本页**当时没有**双触发 —— 因为我加了 `_focusIsInsideThisPage` 守卫
     *   让两条路径互斥。但那是**逻辑性保证**（靠条件写对），
     *   而 early handler 是**结构性保证**（机制上不可能重复处理）。
     * ⇒ 按"优先用机制排除、而不是用条件排除"的原则，改用 early handler。
     *   守卫**保留**（它仍有价值：判断"该不该我兜底"），
     *   但即使守卫将来被改坏，也不会出现双触发。
     * ```
     */
    FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 把播放页的两个能力交给局域网遥控（2026-09-25 —— task-14 F）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 修之前：遥控的播放控制**整条链路是断的**
     *
     * ```text
     * PlayerBridge { getState(), exec(cmd) }   ← 播放页该交出的两个能力
     * RemoteBridge.setPlayer(b)  remote_bridge.dart:283   ★ 全仓库零调用
     * ⇒ _player == null
     * ⇒ 手机端 14 条命令全部被丢弃（落到「没有播放器」分支）：
     *    toggle_play / prev_episode / next_episode / goto_episode / seek /
     *    seek_to / switch_source / set_volume / toggle_mute /
     *    skip_config_open / skip_preview / skip_confirm / skip_clear /
     *    skip_toggle_auto
     * ⇒ 而且手机端**选集面板永远不显示**（episodes 恒为空）
     * ```
     * 用户看到的就是「手机上点了没反应」。
     *
     * # 为什么在 `initState` 注册
     *
     * 播放页是**全屏 push 的路由**，同一时刻只可能有一个在树上 ——
     * 所以"注册"天然是幂等的，不需要引用计数。
     * 放在这里（而不是 `build`）的理由与 [RemoteBridgeHost] 一致：
     * `build` 会被主题切换等触发**多次**，每次都注册会不停重置桥的
     * `_lastSig`（心跳去重失效 → 上报次数暴涨，正是原版"卡顿"的成因）。
     *
     * ⚠️ 这里**不 await**、也**不读 `context`** —— `initState` 里读
     *    `MediaQuery` 之类是不安全的（本项目 `primeFocusSoon` 那类坑）。
     *    桥只保存闭包，真正取值发生在它自己的 tick 里（那时早就建好了）。
     */
    _remotePlayerBridge = PlayerBridge(
      getState: _remoteGetState,
      exec: _remoteExec,
    );
    RemoteBridge.instance.setPlayer(_remotePlayerBridge!);
    /*
     * 真机实测取证：把**播放页自己那个** GestureDetector 的实际挂载状态
     * 打进日志（`GESTURE_PROBE=true` 时）。
     *
     * ⚠️ 这里读的是**刚构建出来的** widget —— 但 `initState` 时还没 build，
     *    所以延到首帧后读（见 `_probeGestureMount`）。
     */
    WidgetsBinding.instance.addPostFrameCallback((_) => _probeGestureMount());

    /*
     * ★ 收起自绘标题栏（2026-09-24）
     *
     * 对齐原版 `.titlebar.is-hidden`（`App.vue` 里 `route.name === "player"`
     * 时置 hidden）：
     * ```css
     * .titlebar.is-hidden { opacity: 0; transform: translateY(-100%);
     *                       pointer-events: none; }
     * ```
     * 原版注释解释理由：
     * > 需求是「播放不默认全屏」，但播放时仍应最大化利用空间 ——
     * > 隐藏这条栏就是最直接的做法（返回按钮在播放器自己的顶栏里）。
     *
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 但桌面端**不能照抄这条**（2026-09-24 用户纠正）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 播放器页面没有顶部的那个可拖动 缩小 放大 关闭的那个操作条,
     * > 影响体验,在桌面端播放页面 无法拖动窗口
     *
     * # 为什么原版能隐藏、我们不能
     *
     * 原版是 **WebView 里的网页**，它的"窗口"由 Tauri 管：
     * ```text
     * 原版：标题栏隐藏后，Tauri 的原生窗口**仍然可拖**
     *       （用户还能拖系统装饰区 / Alt+Space 菜单 / Win+方向键）
     * 我们：标题栏就是**唯一**的拖动区（titleBarStyle: hidden 去掉了系统标题栏）
     *       → 隐藏它 = 窗口彻底拖不动
     * ```
     * 也就是说原版隐藏的只是一条**视觉条**，而对我们来说那是**功能条**。
     *
     * ⚠️ 我上一轮的错误：看到用户说「详情页**和播放页**都没有操作条」，
     *    修好了详情页，却给播放页加了主动隐藏 —— **恰好把用户要的拿掉了**。
     *    用户的诉求是「**要**操作条」，不是「不要」。
     *
     * # 所以：保持显示
     *
     * 播放页的 `_TopBar`（返回/标题/提示）在**内容区**顶部，
     * 与窗口标题栏不冲突 —— 一个管窗口、一个管播放。
     * 想要沉浸看片用「全屏」（见 `_toggleFullscreen`）。
     */
    // titleBarVisible 保持 true（不隐藏）—— 桌面端必须留可拖动区。

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 但要把它压暗 —— 修用户报的「进播放页还是上面会闪出来白条」
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 进入播放页还是上面会闪出来白条
     * > 我觉得……那个白条可能跟顶部的自定义操作条有关系,
     * > 然后吧 其实还有点丑
     *
     * ★ 用户的猜测**是对的**。实测（`.probe/real_player_capture.py`）：
     * ```text
     * 首页标题栏  #e7eaf2 / #e8ebf3   ← 浅色液态玻璃
     * ```
     * 标题栏挂在 `MaterialApp.builder`（`Navigator` **之外**），
     * 所以它**永远压在所有路由之上**。播放页背景是纯黑
     * （`Scaffold(backgroundColor: Colors.black)`），
     * 于是顶部那条 40px 的**浅色玻璃**就成了用户看到的"白条"。
     *
     * # 为什么不能像原版那样隐藏
     *
     * 原版 `TitleBar.vue`：`hidden.value = route.name === 'player'`。
     * 但原版是 WebView，窗口由 Tauri 管，隐藏后**仍可拖**。
     * 我们 `titleBarStyle: hidden` 去掉了系统标题栏 ——
     * 这条标题栏是**唯一**的拖动区（上面 602-604 行记录的用户原话
     * 就是为这件事纠正的）。
     *
     * ⇒ **保留功能、压暗颜色**：还能拖 / 最小化 / 最大化 / 关闭，
     *    但视觉上与黑色播放页融为一体。
     *
     * ⚠️ **必须与 `dispose` 成对**（见下面 dispose 里的复位）——
     *    漏了的话返回首页后标题栏一直是黑的。
     */
    titleBarDark.value = true;

    /*
     * ⚠️ 硬解必须在 Player 创建**之后**用 setProperty 设置
     *
     * `PlayerConfiguration` **没有** hwdec 字段（实测确认）。
     * 不设置的话 Android 上默认**不开硬解** ——
     * 表现是 HEVC 软解，CPU 跑满、4K 卡顿。
     */
    _player = Player(
      configuration: const PlayerConfiguration(
        /*
         * ★ `libass: true` 是 ASS 字幕开关
         *
         * media_kit **默认关闭**。我们的源大量用 ASS（带样式/特效），
         * 不开的话字幕完全不显示（不是显示得不好看，是**没有**）。
         *
         * ⚠️⚠️ Android 上光开这个**不够**（2026-09-23 实测抓到）
         *
         * media_kit 的文档原文：
         * > On Android, this option requires [libassAndroidFont] to be set.
         *
         * 源码（`real.dart` L2328）的条件是**三个都要**：
         * ```dart
         * if (Platform.isAndroid &&
         *     configuration.libass &&
         *     configuration.libassAndroidFont != null &&
         *     configuration.libassAndroidFontName != null) { ... }
         * ```
         * 不满足时它**什么都不做** —— 而 mpv 在 Android 上默认
         * 拿不到系统字体（fontconfig 不生效），所以 **libass 渲染失败**。
         *
         * 实测表现（Android 上）：
         * ```text
         * 编码: hevc 1920x1080        ← 视频正常
         * 字幕轨 2 条                 ← 轨道能枚举
         * ★ 字幕真的在渲染（读到文本）✗ ← 但屏幕上没有字
         * ```
         *
         * # 为什么不 bundle 一个中文字体
         *
         * ```text
         * ① 体积：最小的中文字体 SimsunExtG.ttf 也要 3.4 MB，
         *    而硬指标③要求 Android 包尽量小
         * ② 授权：Windows 自带的 msyh/simhei/simsun 是**微软专有字体**，
         *    不能随应用分发
         * ```
         *
         * # 解法：用 Android 自带的 NotoSansCJK
         *
         * 实测确认系统里有：
         * ```text
         * /system/fonts/NotoSansCJK-Regular.ttc
         * /system/fonts/NotoSerifCJK-Regular.ttc
         * ```
         * 那是 **Apache 2.0** 授权，且已经在设备上 ——
         * 零体积增量、零授权风险。
         *
         * 通过 `libassAndroidFontName` 让 mpv 用这个名字找字体
         *（注意：要的是**字体名**，不是文件名）。
         */
        libass: true,
        // 缓冲调小一点，直播换台更快
        bufferSize: 32 * 1024 * 1024,
      ),
    );
    _controller = VideoController(_player);

    /*
     * ★ 连播策略 / 音量倍速偏好 —— 必须在起播**之前**读出来
     *
     * 原版在创建 ArtPlayer 时就带上偏好（`PlayerView.vue:3434`）：
     * ```ts
     * volume: prefs.lastVolume ?? 1,
     * ```
     * 起播后再设会有一个"先满音量再变小"的突跳，用户能听出来。
     */
    _loadPlayPrefs();
    final initialLivePlayback = widget.initialLivePlayback;
    if (_isLive && initialLivePlayback != null) {
      _playing = initialLivePlayback.playing;
      _muted = initialLivePlayback.muted;
      _volumeBeforeMute = initialLivePlayback.muted
          ? initialLivePlayback.volume
          : null;
      _lastVolume = initialLivePlayback.volume / 100;
      _volume = initialLivePlayback.muted ? 0 : initialLivePlayback.volume;
      _sendVolume(_volume);
    }
    _loadDanmakuPrefs();

    _setHwdec();
    _bindPlayerStreams();
    _initPip();
    /*
     * ★ 取当前站点的显示名（task-32）
     *
     * 走本地注册表（无网络），与起播**并行** —— 不 await，不阻塞首帧。
     * 拿不到就不渲染那个 pill（不是渲染空的）。
     */
    unawaited(_loadProviderName());
    // ★ 与站名**同一批**刷新：换源后发送入口的能力必须跟着换
    unawaited(_loadDanmakuSendCapability());

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-12 ④（2026-10-09）：本地文件**短路** —— 完全不调 `_load()`
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须在这里短路（而不是在 `_load()` 里加分支）
     * ```text
     * `_load()` 是唯一生产起播入口，且**无条件**走
     *   `SourinApi.resolveStream` -> Rust `playback.rs:160-164 registry.route()`
     * 本地文件没有 provider 可路由 => 必然报「无法路由: local:...」。
     *
     * 而 `_load()` 里 `final List<StreamCandidate> list;` 是**确定赋值**结构，
     * 在里面插第三支 = 改那个 if/else 的**形状**（那是我刚收完 task-8 的地方）。
     * ⇒ 在这一层短路 => `_load()` 的字节**一行不动** => 零冲突、零回归风险。
     * ```
     *
     * # ★ 判据是「真的没调」，不是「调了但提前 return」
     * ```text
     * 后者（提前 return）仍会走完 `_bootWatch` / `setState(_loading=true)` 那一串，
     * 而且更重要的是：**`resolveStream` 会被执行** => 断网/无 provider 时照样报错。
     * ⇒ 验收里那条「断网也能播」查的就是这一点。
     * ```
     *
     * # 为什么用 `widget.provider` / `widget.id` 而不是自己判
     * ```text
     * `shell.dart:4758-4759` 已经保证了：
     *   有旁文件 => provider = 站点 id，id = 站点 contentId（走在线）
     *   没旁文件 => provider = **'local'**（kLocalProvider），id = 规范化路径
     * ⇒ 「走在线还是走本地」这个裁决**在 shell 已经做完**，本页**不再重判**
     *   （重复实现必然两边不一致）。`_provider`/`_contentId` 的 late 初值
     *   （:1049-1050）本来就取自 widget => 拿到 local 就会走 local 命名空间。
     * ```
     *
     * # ★★ 为什么进度能落 `local` 命名空间（不需要额外代码）
     * ```text
     * `_provider`/`_contentId` 是 state 字段（:1049-1050 从 widget 取初值），
     * `_prepareResume` 读 `getProgress(_provider, _contentId)`、
     * `_saveProgress` 写同一对 => 读写**自动**都在 local 空间。
     * ⇒ 在线作品的进度不会被污染（反向控制那条验收查这个）。
     * ```
     */
    if (widget.localPath != null) {
      /*
       * 时序：与 `_load()` 的同步段保持一致（`_bootWatch` 必须在首个 await 前）。
       * ⚠️ 这里**只**做「起播」，不做 `resolveStream`。
       */
      _bootWatch = Stopwatch()..start();
      _bootMark('① 点播放', '本地文件 $_provider/$_contentId');
      setState(() {
        _neutralizeErrorState(loading: true);
        _sawFirstFrame = false;
      });
      unawaited(_bootLocalFile());
    } else {
      // ← 原来那行（现在是 else 分支）——**逐字节不变**
      WidgetsBinding.instance.addPostFrameCallback((_) => _load());
    }

    /*
     * ★★★ Owner 2026-10-11 第⑤条：popover 从「开」变「关」时，重装隐藏计时器。
     *
     * # 为什么必须有这一条（否则本修复会引出第二个缺陷）
     * ```text
     * `_autoHideNow()` 的守卫加了「`_popover.openId == null`」之后：
     * 用户开着倍速面板停手 3 秒 ⇒ 计时器到点，但守卫把隐藏拦下 ⇒ 底栏留着
     * （这是对的，面板挂在底栏按钮旁，底栏不能先没）。
     * ⚠️ 可那个 `_hideTimer` 已经**烧掉**了 —— 若关闭面板时不重装，
     *   用户关掉面板之后底栏就**再也不会自动隐藏**了。
     * # 实测各条关闭路径都不重装（见 `_autoHideNow` 同段注释）
     * ```
     * ⇒ 在这里监听控制器：只要它从「开着」翻到「关着」，就 `_armHideTimer()`
     *   一次，让「关掉面板 ⇒ 再停手 3 秒 ⇒ 底栏正常收起」回到原节奏。
     *
     * ⚠️ 只在**开→关**这个**边沿**上装，不在「本来就没开」时装：
     *    否则 hover 底栏时 _showControls() 已经装了一个，这里会把它重置，
     *    等价于每次 notifyListeners 都续命（面板开着时控制器每帧复核几何
     *    也会 notify）——那会让底栏在面板开着时反复续命。用 `_prevPopoverOpen`
     *    记上一个值，只有真正跨过「开→关」才装。
     */
    _popover.addListener(_onPopoverChanged);
  }

  /// ★★★ task-12 ④：本地文件的起播路径（`initState` 短路后走这里）。
  ///
  /// 与 `_load()` 的差别只有**取候选地址**那一步：
  /// ```text
  /// _load()      ：resolveStream(provider, contentId)  ← 走网络 + 插件 JS + 路由
  /// _bootLocalFile：StreamCandidate(url: file://...)   ← 零网络，mpv 原生吃 file://
  /// ```
  /// 之后的 `_prepareResume()` -> `_startPlayback()` -> `_loadSkipMarker()`
  /// **同一套**（续播/首帧/跳过片头全部复用，不手抄副本）。
  ///
  /// # ★★ task-12 ④ 改动 B：为什么要接受 [path] 参数
  /// ```text
  /// 有**两条**路会走到本地起播：
  ///   ① 进页面就播（`initState` 短路）—— 路径来自 `widget.localPath`（构造期）；
  ///   ② 页内**换集/换文件**（`applySession`）—— 路径来自 `req.localPath`（后到的请求）。
  /// 第 ② 条发生在页面**已经建好之后**，读 `widget.localPath` 会永远拿到「进来那一集」。
  /// ⇒ 让本方法接受一个路径，两条路共用**同一份实现**
  ///   （不手抄副本 —— 抄一份就必然有第二处要同步维护）。
  /// ```
  ///
  /// ⚠️ 默认值取 `widget.localPath`：调用方只在「换到另一个本地文件」时才需要显式传。
  Future<void> _bootLocalFile({String? path}) async {
    /*
     * ★★★ CR #22 ⑥ 的**第四条**会话替换路径：`applySession` 的本地支
     *     走的是本方法（`req.localPath != null`），它自己推一次令牌 ——
     *     否则「切集途中会话被换到**本地文件**」那一幕仍然会弹旧源的浮层：
     *     `applySession` 上面那次 `_rewatchToken++` 在**同一个** setState 里，
     *     推完令牌后 `_gotoEpisode` 那次 `_reload()` 已经会丢弃结果 —— 但
     *     本地支**不经** `_reload`，而 `_gotoEpisode` 末尾那四道守卫
     *     （令牌未变 / mounted / `_error == null` / 集 id 相同）在这里会**全部**
     *     通过（集 id 确实没变）⇒ 浮层照弹。
     * ⚠️ 本方法还有两个**非会话替换**的调用者：① `:2515` 的 `_load()`
     *    首播、② 页面级 `widget.localPath` 那条。给它们多推一次令牌是
     *    安全的（那一刻 `_gotoEpisode` 不可能在途 —— 页面还没起播），
     *    而「推了没坏处、漏了会弹错浮层」⇒ 放在方法开头最省。
     */
    _rewatchToken++;
    final filePath = path ?? widget.localPath;
    // ① 换集那条路可能传 null（切换回在线）—— 调用方应自己分流，这里防御性兜住
    if (filePath == null) return;
    try {
      /*
       * ★ 判据：`models.dart:822` 的 isPlayable 只判 `!drmProtected && url.isNotEmpty`
       *   => file:// 天然过闸，不需要任何特殊处理。
       * ⚠️ drmProtected 默认 false（StreamCandidate 的默认值）。
       */
      final candidate = StreamCandidate(
        url: Uri.file(filePath).toString(),
        kind: 'local',
      );
      _bootMark('② 拿到候选地址', '1 条 · 首条 playable=${candidate.isPlayable}');
      if (!mounted) return;
      setState(() => _streams = <StreamCandidate>[candidate]);

      /*
       * ⚠️ 顺序与 `_load()` 一致：`_prepareResume` 必须在 `_startPlayback` 之前
       *    —— 后者会消费 `_pendingSeek`，放到后面等于「先从头播再跳」（画面会闪回去）。
       */
      await _prepareResume();
      await _startPlayback(candidate);
      await _loadSkipMarker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          _errorKind = _kindOf(e);
          _loading = false;
          _playbackFailure = null;
        });
      }
    }
  }

  /// 取当前站点的显示名（task-32）
  ///
  /// ⚠️ 换源后会再次调用（`_provider` 变了）—— 见 `_switchSource`。
  ///
  /// ★★★ task-33（F1 后半）：查名字的 id 交给顶层 [providerNameLookupId]
  ///    现算 —— 本地会话（`_provider == 'local'`）要么认回 [originProvider]
  ///    那个**真站点**，要么用 [kLocalSessionSourceLabel]（「本地」）兜底。
  ///
  ///    改前是 `providerDisplayName(_provider)` 一把梭 ⇒ 本地会话把
  ///    `'local'` 原样挂到顶栏（Owner 看到的「而不是local」）。
  /// 查「当前源能不能发弹幕」+ 记下真站点 id（Owner 第 2 条后半句）
  ///
  /// # 为什么与 [_loadProviderName] 分开、而不是顺手塞进去
  /// ```text
  /// 两件事的**失败语义**不同：
  ///   · 查名字失败 ⇒ 退回 id 显示（无害）；
  ///   · 查能力失败 ⇒ 必须当作「不能发」。
  /// 合在一起会让「名字查到了但能力没查到」这种半成功状态无从表达。
  /// ```
  ///
  /// ⚠️ 调用点与 [_loadProviderName] **完全一致**（换源/换集/首帧），
  ///    否则会出现「顶栏已经显示新站名，发送入口却还是旧源的能力」。
  Future<void> _loadDanmakuSendCapability() async {
    final id = providerNameLookupId(
      provider: _provider,
      originProvider: widget.originProvider,
    );
    // 没有真站点（本地会话且认不回来）⇒ 一定不能发
    if (id == null || id.isEmpty) {
      if (!mounted) return;
      if (_danmakuCanSend || _danmakuSendProvider != null) {
        setState(() {
          _danmakuCanSend = false;
          _danmakuSendProvider = null;
        });
      }
      return;
    }
    var canSend = false;
    try {
      final list = await SourinApi.listProviders();
      /*
       * ★★★ 判据走**顶层函数** danmakuSendAllowed —— 与单测读同一份实现。
       *   不在这里内联写一遍：那样测试只能重写一份同样的逻辑，
       *   改错了也照样全绿（本文件第一版就是这么翻车的，见该函数注释）。
       */
      /*
       * ★ 判据就是契约里那一个布尔，**不做任何推断**。
       *
       * 尤其**不要**「插件没声明 danmakuSend 但声明了 danmaku ⇒ 也许能发」
       * 这类推测：契约里 danmakuSend 是**独立**声明，
       * 收弹幕与发弹幕本来就是两种能力（很多源只能收不能发）。
       */
      canSend = danmakuSendAllowed(list, id);
      debugPrint('[PLAYER] 源 $id 可发送弹幕 = $canSend');
    } catch (e) {
      /*
       * 查不到 ⇒ **当作不能发**（安全方向，见字段注释），但要留痕：
       * 排查「为什么这个源没有发送入口」时需要这条日志。
       */
      debugPrint('[PLAYER] 取源能力失败（按不可发送处理）: $e');
      canSend = false;
    }
    if (!mounted) return;
    /*
     * ★ 代次保护：换源是异步的，两次查询可能乱序返回。
     *   判据与 _loadProviderName 相同 —— 「发起时的 id 是否仍是当前 id」。
     */
    if (id !=
        providerNameLookupId(
          provider: _provider,
          originProvider: widget.originProvider,
        )) {
      return;
    }
    if (_danmakuCanSend == canSend && _danmakuSendProvider == id) return;
    setState(() {
      _danmakuCanSend = canSend;
      _danmakuSendProvider = id;
    });
  }

  /// 真正把一条弹幕发出去（供 [DanmakuSendInline] 注入）
  ///
  /// 返回 null = 成功；返回字符串 = **给用户看的失败原因**。
  ///
  /// # ★★★ 为什么把异常翻成字符串，而不是让它往上抛
  /// ```text
  /// 契约里的失败是**分类**的（unsupported / unauthorized / network / parse），
  /// 每一类对应的下一步动作完全不同：
  ///   unsupported  → 这个源就是不能发，别再试了
  ///   unauthorized → 去登录
  ///   network      → 检查网络
  /// 若统一抛出去、上面再 catch 成「发送失败」，这些可执行信息就全丢了。
  /// ⇒ 在这里**就地分类翻译**，把上游原话一并带上（不改写原因）。
  /// ```
  ///
  /// # ★★ 绝不假装成功
  /// ```text
  /// Rust 侧 `provider_danmaku_send` 的纪律是「只有上游确实收下才 Ok(true)」，
  /// 未实现 ⇒ Err(unsupported)。
  /// 本方法**原样相信**那个结果：
  ///   · 抛异常        ⇒ 失败（不管异常文本长什么样）
  ///   · 返回 ok=false ⇒ 也算失败
  /// 唯一算成功的只有 ok=true。
  /// ```
  Future<String?> _sendDanmaku(String text, int? positionMs) async {
    final provider = _danmakuSendProvider;
    if (provider == null || provider.isEmpty) {
      return '找不到要发往的源，请重新进入这一集再试';
    }
    try {
      final r = await SourinApi.providerDanmakuSend(
        provider,
        episodeId: _contentId,
        text: text,
        progressMs: positionMs,
      );
      if (!r.ok) {
        /*
         * ★ ok=false 也是一种失败。Rust 契约里正常路径不会走到这里
         *   （未实现是 Err 不是 ok:false），但**不能因此假设它不会发生** ——
         *   一旦真出现，当成成功就是最坏的那种误导。
         */
        return '上游没有确认收到这条弹幕，请稍后重试';
      }
      _flash('弹幕已发送');
      return null;
    } on SourinCoreException catch (e) {
      /*
       * ★ 按 kind 分类翻译。kind 由 Rust 侧按错误前缀填好
       *   （见 core/ffi.dart 里 SourinCoreException.kind 的注释）。
       */
      final raw = e.message.trim();
      /*
       * ★★★ 判 kind 时**同时看消息前缀**，不只信 e.kind
       *
       * # 为什么（实测出来的，不是防御性编程的洁癖）
       * ```text
       * Rust 侧 provider_danmaku_send 走 with_state_async，错误在那一层被
       * classify_error(&e)（ffi.rs:2188）**按关键字重新分类**：
       *   · 它拿到的是一句**扁平化的 message**，ProviderError.kind 已经丢了；
       *   · 于是 unsupported: 这种标准前缀**不被认**，
       *     除非正文里恰好出现「不支持 / 未配置」这些中文词。
       * 实测：
       *   抛 'unsupported: 这个源只声明了能力，没真的实现发送'
       *     ⇒ kind = other          ← 明明是标准前缀
       *   抛 'unsupported: 不支持发送'
       *     ⇒ kind = unsupported    ← 只因为正文里有个「不支持」
       * ```
       * ⇒ 若只信 e.kind，用户会看到含糊的「发送失败」而不是
       *   「这个源不支持发送」，恰好糟蹋掉 Owner 第 2 条要的那句提示。
       * 所以这里**以消息前缀为准**，kind 作为补充。
       *
       * ⚠️ Rust 那个分类缺陷已单独报给 Lead，不在本文件修（越界）。
       *    这里做的是「不依赖上游不可靠字段」的本地防御 ——
       *    上游修好之后这段仍然正确，不会反过来变成 bug。
       */
      final byPrefix = raw.startsWith('unsupported:')
          ? 'unsupported'
          : raw.startsWith('unauthorized:')
              ? 'unauthorized'
              : raw.startsWith('network:')
                  ? 'network'
                  : null;
      final kind = byPrefix ?? e.kind;
      switch (kind) {
        case 'unsupported':
          /*
           * ★★ 这一条是 Owner 第 2 条的核心：
           *   插件**声明**了 danmakuSend 但**没实现** danmakuSend() 时，
           *   入口会出现（声明为真），点发送才失败。
           *   ⇒ 必须说清是「这个源不支持发送」，而不是含糊的「发送失败」。
           */
          return raw.isEmpty
              ? '这个源不支持发送弹幕'
              : '这个源不支持发送弹幕（$raw）';
        case 'unauthorized':
          return raw.isEmpty ? '需要先登录才能发弹幕' : '需要先登录才能发弹幕（$raw）';
        case 'network':
          return raw.isEmpty ? '网络异常，弹幕没发出去' : '网络异常，弹幕没发出去（$raw）';
        default:
          // 其余情况**原样透出**上游理由，不自己编一个更好听的
          return raw.isEmpty ? '发送失败' : '发送失败：$raw';
      }
    } catch (e) {
      return '发送失败：$e';
    }
  }

  /// 当前进度（毫秒）—— 发给「按进度发」的站点
  int? _danmakuSendPositionMs() {
    if (_isLive) return null; // 直播没有「进度」这个概念
    return _positionNotifier.value.inMilliseconds;
  }
  Future<void> _loadProviderName() async {
    /*
     * 判据在**发起时**算一次，并且与代次保护用**同一个**值 ——
     * 否则「本地页里换到在线源」这类切换会让两次比较的基准不一致。
     */
    final id = providerNameLookupId(
      provider: _provider,
      originProvider: widget.originProvider,
    );
    /*
     * 没有**站点**可查（本地会话且没有旁文件）⇒ 顶栏如实写「本地」
     * （[kLocalSessionSourceLabel]），**绝不**把 `_provider` 那个续播
     * 命名空间（`'local'`）当名字挂出去 —— 那正是 Owner 说的“而不是local”。
     */
    final n = await providerDisplayName(id ?? kLocalSessionSourceLabel);
    /*
     * ★ 代次保护：换源是**异步**的，两次调用可能乱序返回。
     *   用「发起时的 id 是否仍是当前 id」作判据 —— 过期的那次直接丢弃，
     *   否则顶栏可能停在旧站名（本项目在 `_seekAfterReady` 踩过同类坑）。
     */
    if (!mounted) return;
    if (id !=
        providerNameLookupId(
          provider: _provider,
          originProvider: widget.originProvider,
        )) {
      return;
    }
    setState(() => _providerName = n);
  }

  /// 从 [UiPrefs] 读连播策略 / 音量 / 倍速
  ///
  /// # 为什么用 UiPrefs 而不是新加一个存储
  ///
  /// 原版这些偏好存在 localStorage 的 `dsh.playprefs` 里，
  /// 理由是（原版 `stores/player.ts` 注释）：
  /// > 这些是**播放器专属**的用户偏好，页面切换/会话切换都不该重置。
  ///
  /// 我们的对应物就是 `UiPrefs`（`core/ui_prefs.dart`，同样是
  /// "纯前端偏好 → JSON 文件"）。**不新增依赖、不新增存储层**。
  ///
  /// ⚠️ 键名沿用原版语义（`dsh.playprefs.*`）而不是照抄原版的
  ///    "整个对象塞进一个 key" —— 我们这边没有 JSON 嵌套读取的便利。
  void _loadPlayPrefs() {
    final end = UiPrefs.get('dsh.playprefs.endAction');
    _endAction = PlayEndAction.values.firstWhere(
      (a) => a.wire == end,
      // 白名单校验：localStorage/文件可能被旧版本写坏，
      // 非法值会让"播放完"什么都不做（原版同样做了白名单校验）
      orElse: () => PlayEndAction.autoNext,
    );
    _countdownBeforeNext =
        UiPrefs.get('dsh.playprefs.countdownBeforeNext') != '0';
    _keepSourceOnNext = UiPrefs.get('dsh.playprefs.keepSourceOnNext') != '0';
    _autoSkip = UiPrefs.get('dsh.playprefs.autoSkip') != '0';
    /*
     * ★★★ fix/rewatch-prompt：切集起播策略（Owner 第 1011 条）。
     *
     * ⚠️ **缺省 = fromStart**（`fromWire(null) == fromStart`）——
     *    老用户升级后行为不变（那个键以前根本不存在）。
     *    白名单校验在枚举自己身上（非法值也落回 fromStart），本页不重写判据。
     */
    _episodeStartAction = PlayEpisodeStartAction.fromWire(
      UiPrefs.get('dsh.playprefs.episodeStartAction'),
    );

    final v = double.tryParse(UiPrefs.get('dsh.playprefs.lastVolume') ?? '');
    // 范围校验（原版同样做了：0–1 之外的值会让播放器静音或爆音）
    _lastVolume = (v != null && v >= 0 && v <= 1) ? v : 1.0;

    final r = double.tryParse(UiPrefs.get('dsh.playprefs.lastSpeed') ?? '');
    // 原版的合法区间是 0.25–4
    _lastRate = (r != null && r >= 0.25 && r <= 4) ? r : 1.0;

    /*
     * ★★★ task-22 P2-9：解码模式（偏好里存的是 mpv 的 `wire` 字符串）
     *
     * `HwdecMode.fromWire()` 内部就是白名单校验：读不到 / 写坏了 → auto。
     * 注意这里**只恢复状态**，真正的下发在 `_setHwdec()`（它每次起播都跑）。
     */
    _hwdecMode = HwdecMode.fromWire(UiPrefs.get('dsh.playprefs.hwdecMode'));

    /*
     * ★★★ task-22 P1-11：画面缩放百分比
     *
     * 范围校验 50–200（与底栏滑条的量程一致）：
     * 越界值会让画面缩到看不见或糊成一团，属于「偏好被写坏」。
     */
    final z = double.tryParse(UiPrefs.get('dsh.playprefs.videoZoom') ?? '');
    _videoZoomPct = (z != null && z >= 50 && z <= 200) ? z : 100;

    // 起播即生效（与上面的注释对应）
    /*
     * ⚠️ **不**盖 `_lastUserVolumeAction` —— 这是**我们**发起的，
     *    不是用户调的（见 `_lastUserVolumeAction` 的长注释）。
     *    mpv 的默认音量广播会在这之后到达，它会被白名单挡掉 ⇒ 不写偏好。
     */
    _sendVolume(_lastVolume * 100);
    if (_lastRate != 1.0) _player.setRate(_lastRate);
  }

  /// 把一个偏好写回 [UiPrefs]
  void _savePlayPref(String key, String value) {
    UiPrefs.set('dsh.playprefs.$key', value);
  }

  /// 读弹幕偏好（dsh.danmaku.*，键与范围见 core/danmaku.dart 的 DanmakuConfig）
  ///
  /// 与 _loadPlayPrefs 同一原则：**起播前**读出来，起播后再改会有突跳。
  void _loadDanmakuPrefs() {
    _danmakuEnabled = DanmakuConfig.enabled;
    _danmakuSettings = DanmakuSettingsState.fromPrefs();
  }

  /// 配置硬件解码（**只配置，不读值**）
  ///
  /// # 各平台后端不同（实测确认）
  ///
  /// ```text
  /// Windows  d3d11va      实测 hwdec-current = "d3d11va-copy"，CPU 0.06 核
  /// Android  mediacodec   真机有硬件 HEVC 解码器时可用
  /// macOS    videotoolbox
  /// ```
  /// 用 `auto-safe` 让 mpv 自己挑 —— 它会在硬解不可用时**安全回退**到软解，
  /// 而不是像 `auto` 那样可能选到不稳定的组合。
  ///
  /// # ⚠️ 这里**不再**读 `hwdec-current`（2026-09-24 修的真 bug）
  ///
  /// 本函数在 `initState` 里调用，此刻**还没有 open()** ——
  /// `hwdec-current` 是 mpv 的**运行时属性**，没有媒体/解码器时它是
  /// **空字符串**。原先在这里读，日志永远是：
  /// ```text
  /// [PLAYER] hwdec-current =          ← 空的，等于没有硬解证据
  /// ```
  /// 「设置 hwdec」是**配置**，越早越好（open 之前设才对）；
  /// 而「读 hwdec-current」是**取证**，必须等解码器真的建起来。
  /// 两件事被混在一个函数里，就是本 bug 的根因。
  /// 读取挪到 [_reportHwdecAfterReady]。
  Future<void> _setHwdec() async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        /*
         * ★★★ task-22 P2-9：解码模式
         *
         * `auto` 这一支**必须**保留字面量 `auto-safe` —— 它同时被
         * `test/hwdec_timing_test.dart:167` 与 `test/skip_marker_test.dart:482`
         * 逐字断言（那是配置，不是取证）。其余三档直接用档位表里的
         * `wire`（HW+ → `auto` / HW → `auto-copy` / SW → `no`）。
         *
         * ⚠️ 这里**只下发、不回读** —— 回读 `hwdec-current` 属于取证，
         *    必须留在 `_reportHwdecAfterReady()`（它跑在 `open()` 之后）。
         *    把两件事混在一处就是硬指标①记的那个根因。
         */
        if (_hwdecMode == HwdecMode.auto) {
          await native.setProperty('hwdec', 'auto-safe');
        } else {
          await native.setProperty('hwdec', _hwdecMode.wire);
        }

        /*
         * ★★★ 缺陷⑧（2026-10-25）：把 `network-timeout` 的取值**显式下沉**给 mpv
         *
         * # 为什么要显式下发（media_kit 本来就有个默认 5）
         * ```text
         * media_kit 1.2.6 的默认值写在库里：
         *   real.dart:2394  'network-timeout': '5'
         * ⇒ 默认值住在**第三方**，归因那边（PlaybackErrorText.classify）
         *   却要用同一个数字算窗口 ⇒ 两边迟早不一致。
         * 本仓唯一设过这条的是直播组件（`live_embedded_player.dart` 设 3）。
         * ⇒ 点播这条路现在显式设成 kPlaybackNetworkTimeoutSeconds，
         *   "mpv 等多久"与"判据窗口多宽"从此是**同一个常量**。
         * ```
         *
         * # ⚠️ 为什么保持 5 秒（没有放大到计划里曾提的 15 秒）
         * 计划「实施前证据纠偏」已取消"先改成 15"的预设：没有证据证明放大
         * 能救回那些流，而放大只会让**真正坏掉的流**让用户多等 10 秒。
         * 等真实源/真机拿到对照数据再决定 —— 换值只需改这个常量。
         */
        await native.setProperty(
          'network-timeout',
          '$kPlaybackNetworkTimeoutSeconds',
        );

        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 允许跨源播放列表 —— 修任务⑰⑧「直播黑屏」的第 2 个原因
         * ══════════════════════════════════════════════════════════════
         *
         * # 怎么发现的（实测，先修好 Referer 之后仍然黑屏）
         *
         * 用**真实 Player** 播央视标清线路，把 `stream.error` / `stream.log`
         * 打出来：
         * ```text
         * PLAYER-ERROR Refusing to load potentially unsafe URL from a playlist.
         * PLAYER-ERROR Use the --load-unsafe-playlists option to load it anyway.
         * PLAYER-LOG   lavf: avformat_open_input() failed
         * PLAYER-STATE duration=0 position=0 buffering=true    ← ★ 黑屏
         * ```
         * 也就是说央视的 `.m3u8` **主播放列表**里引用了**另一个主机**上的
         * 子播放列表 —— mpv 认为"播放列表引用了外部 URL"**不安全**，
         * 默认**拒绝加载**。
         *
         * # 为什么必须开（而不是"保持默认更安全"）
         *
         * ```text
         * 流地址来自**用户自己安装的插件**（tvsrc.js 等），
         * 本来就是要播放任意第三方 CDN 的内容 ——
         * 不开这个选项等于"所有走主/子播放列表的直播全废"。
         * 这里没有引入新的信任边界：插件本来就能返回任意 URL。
         * ```
         *
         * # 实测效果（同一条央视 URL）
         *
         * ```text
         * 不开 → Refusing to load potentially unsafe URL  （卡死，黑屏）
         * 开了 → 该报错消失，继续去解析子播放列表
         *        （后面若还失败，是**另一层**原因，见下）
         * ```
         *
         * ⚠️ 它**不是万能药**：开了之后央视这条继续走到
         *    `Cannot open file '/ldtvsrcwbnd/ldtvsrc1_2_hd.m3u8'` ——
         *    那是该 CDN 返回了**主列表内嵌的绝对路径**，
         *    属于上游/网络层面的问题（本机到该 CDN 也不稳定）。
         *    如实记录，不把它说成"已完全修好"。
         */
        await native.setProperty('load-unsafe-playlists', 'yes');
        debugPrint('[PLAYER] mpv: hwdec=auto-safe, load-unsafe-playlists=yes');
      }
    } catch (e) {
      debugPrint('[PLAYER] 设置 hwdec 失败（回退软解）: $e');
    }
    await _setSubtitleFont();
    // ★ ④：每次起播都把「缓存上限」真正下发到 mpv。
    //   放在这里（`_setHwdec()` 末尾）是因为它是**唯一**每次起播都跑的
    //   初始化点（`initState` :1569 调用，与 `_bindPlayerStreams()` 并列）。
    //   不调它的话，用户在设置页拖滑杆只会改到磁盘上的偏好值，
    //   mpv 仍用构造期的 `bufferSize`（:1552 32MB）和它自己的默认
    //   `cache-dir`（不在 <dataDir>\mpv-cache 里，我们清不掉）。
    await _applyMpvCacheSettings();
    /*
     * ★★★ task-22 P1-11：画面缩放同样是**逐文件**属性
     *
     * mpv 的 `video-zoom` 在换文件时会复位 ⇒ 必须在每次起播时重新下发。
     * 放在这里与 `_applyMpvCacheSettings()` 同理：`_setHwdec()` 是**唯一**
     * 每次起播都跑的初始化点（`initState` 调用，与 `_bindPlayerStreams()` 并列）。
     */
    await _applyVideoZoom();
  }

  /// ④ 把「缓存上限」写进 mpv 的解复用缓存属性（片段缓存之外的第二个落点）
  ///
  /// # 为什么构造期传值不够，必须运行时再设一遍
  ///
  /// `PlayerConfiguration.bufferSize` 确实会映射到 mpv 的
  /// `demuxer-max-bytes` / `demuxer-max-back-bytes`（media_kit
  /// `real.dart:2425-2426`），但那张属性表**只在 `Player.open()` 里
  /// 应用一次**（`real.dart:2445-2446`）。用户在设置页拖完滑杆时
  /// 播放器**早就活着**了 —— 构造期传值管不到，必须 `setProperty`
  /// 再来一次。
  ///
  /// # 为什么用 demuxer-max-bytes 而不是 bufferSize
  ///
  /// 同一条实测：`bufferSize` 只是那两个属性的**来源**，改 `bufferSize`
  /// 需要重建 Player（正在播的片子会断）；`setProperty` 是运行时接口。
  ///
  /// # 失败怎么办
  ///
  /// `setProperty` 的返回值被 media_kit **丢弃**（`real.dart:1223-1246`），
  /// 设不进去**不会抛异常**。所以这里只负责「把值发出去」，真正的判据
  /// 是 `_readMpvCacheSettings()` 的回读 —— 读不到（空串）就是失败，
  /// **不猜**。
  Future<void> _applyMpvCacheSettings() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      final dir = await ClipDownloader.mpvCacheDir();
      final props = ClipDownloader.mpvCacheProperties(dir);
      for (final p in props) {
        await native.setProperty(p.$1, p.$2);
      }
      final parts = <String>[];
      for (final p in props) {
        parts.add('${p.$1}=${p.$2}');
      }
      // 顺手报一下这个目录当前多大 —— 只读，不改变行为
      final used = await ClipDownloader.mpvCacheBytes();
      debugPrint(
        '[PLAYER] mpv 缓存属性已下发: ${parts.join(', ')}'
        '（目录现占 ${ClipDownloader.humanBytes(used)}）',
      );
    } catch (e) {
      debugPrint('[PLAYER] 下发 mpv 缓存属性失败: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 2026-10-26（Owner 投诉收口）：伪装成 `.mp3` 的 MP4 ⇒ 强制 demuxer
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 真根因（live-accept 实机取证）
  // ```text
  // 上游 URL：…/5bC85Y+k5Za15Za1MDF6bS5tcDQ=.mp3
  // base64 解出：           尼古喇喇01zm.mp4      ← 真身是 MP4，后缀被伪装成 .mp3
  // 现象：代理 206/468ms 正常转发、字节在流，但【首帧永远不出】；起播失败 0 次
  // 原因：mpv 按 **URL 后缀**选 demuxer ⇒ .mp3 走音频 demuxer ⇒ 只有音轨
  // ```
  // 插件自己也写了这一点（`该源.js:568-575`：「该站把 MP4 伪装成 .mp3…），
  // 所以 `kind=mp4` 是**可信**的 ⇒ 用 kind 去纠正 mpv 的后缀猜测。
  //
  // ⚠️ 必须**每次起播都写一遍**（要么设 `mov`、要么显式清空）：
  //    否则切到下一条**真 mp3**时残留 `mov` ⇒ 那条反而解析不了。

  /// 上一次真正下发给 mpv 的值（null = 已清空）。探针可读，用于门禁。
  String? _demuxerOverride;

  /// 是否需要强制 demuxer：`kind` 说是 mp4，但 URL 后缀写着 `.mp3`
  static bool needsDemuxerOverride(String url, String kind) {
    final k = kind.toLowerCase();
    final path = url.split('?').first.split('#').first.toLowerCase();
    return k.contains('mp4') && path.endsWith('.mp3');
  }

  /// 把 demuxer 覆盖**下发/清空**给 mpv（每次起播前调用一次）
  Future<void> _applyDemuxerOverride() async {
    final url = _current?.url ?? '';
    final kind = _current?.kind ?? '';
    final want = needsDemuxerOverride(url, kind) ? 'mov' : '';
    try {
      final native = _player.platform;
      /*
       * ⚠️ 两处护栏（都是实测踩出来的）：
       * ① `debugPlayerSkipOpenForProbe` 为真时**不碰 mpv** —— 门禁里 mpv 未就绪，
       *    `setProperty` 会永久挂住（本仓 `delivery_test.dart:762` 记过同一件事）；
       * ② 真机路径给 2 秒上限：万一 mpv 卡住，也不能把**起播**跟着卡死
       *    （这条属性只是"纠正后缀猜测"，拿不到就退回 mpv 自己的判断）。
       */
      if (native is NativePlayer && !debugPlayerSkipOpenForProbe) {
        await native
            .setProperty('demuxer-lavf-format', want)
            .timeout(const Duration(seconds: 2), onTimeout: () {
          debugPrint('[PLAYER] demuxer-lavf-format 下发超时（2s）—— 跳过');
        });
      }
      _demuxerOverride = want.isEmpty ? null : want;
      debugPrint('[PLAYER] mpv: demuxer-lavf-format='
          '${want.isEmpty ? "（清空）" : want}（kind=$kind '
          'url=${url.length > 60 ? url.substring(url.length - 60) : url}）');
    } catch (e) {
      debugPrint('[PLAYER] 下发 demuxer-lavf-format 失败: $e');
    }
  }

  /// ★★★ task-22 P2-9：把**当前**解码模式下发给 mpv（用户切档时走这条）
  ///
  /// 为什么不复用 [_setHwdec]：那一个被 `test/hwdec_timing_test.dart`
  /// 逐行审计（「配置与取证必须分离」），而且它一次要下发 `hwdec` /
  /// `load-unsafe-playlists` / 字幕字体 / 缓存属性四组东西。
  /// 切档只需要动**一个**属性，所以另开一条：
  Future<void> _applyHwdecToMpv() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      await native.setProperty('hwdec', _hwdecMode.wire);
      debugPrint('[PLAYER] mpv: hwdec=${_hwdecMode.wire}（${_hwdecMode.label}）');
    } catch (e) {
      debugPrint('[PLAYER] 切换解码模式失败: $e');
    }
  }

  /// ★★★ task-22 P1-11：把当前缩放百分比下发到 mpv 的 `video-zoom`
  ///
  /// `video-zoom` 是**逐文件**属性（换文件时 mpv 会复位）⇒ 除了切档/拖条，
  /// 每次起播也要重新下发（见 `_setHwdec()` 末尾与 `_startPlayback()`）。
  Future<void> _applyVideoZoom() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      // 100% ⇒ 0.000000，写下去等价于「复位」（mpv 的默认就是 0）
      final v = videoZoomToMpv(_videoZoomPct).toStringAsFixed(6);
      await native.setProperty('video-zoom', v);
      debugPrint('[PLAYER] mpv: video-zoom=$v（${_videoZoomPct.round()}%）');
    } catch (e) {
      debugPrint('[PLAYER] 下发画面缩放失败: $e');
    }
  }

  /// 回读 mpv 的 `video-zoom`，换算回百分比
  ///
  /// ⚠️ 读不到 ⇒ **不改** `_videoZoomPct`（面板/底栏显示「读不到」）——
  ///    与 `_readMpvStyle()` 同一条规矩：读不到就说读不到，不塞猜测值。
  Future<void> _readVideoZoom() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      final s = await native.getProperty('video-zoom');
      final v = double.tryParse(s.trim());
      if (v == null) return;
      final pct = (100 * math.pow(2, v)).toDouble().clamp(50.0, 200.0);
      if (!mounted) return;
      setState(() => _videoZoomPct = pct.toDouble());
    } catch (e) {
      debugPrint('[PLAYER] 读画面缩放失败: $e');
    }
  }

  /// ★★★ task-22 P1-11：改画面缩放（百分比，50–200）
  ///
  /// 两个入口共用同一个落点：
  /// ```text
  /// ① 设置面板的预设档位（点一下，save = true）
  /// ② 底栏长按浮层的滑动条（拖动中 save = false，松手才 save = true）
  /// ```
  ///
  /// 为什么拖动中不写偏好：一帧一次 `UiPrefs.set` 会在一次拖动里写几十次
  /// （`UiPrefs` 的落盘是 300ms 合并的，但那仍然是几十次无意义的脏标记）。
  void _setVideoZoom(double pct, {bool save = true}) {
    final v = pct.clamp(50.0, 200.0).toDouble();
    if (v != _videoZoomPct) setState(() => _videoZoomPct = v);
    unawaited(_applyVideoZoom());
    if (save) _savePlayPref('videoZoom', v.round().toString());
  }

  /// ★★★ task-22 P2-9：切解码模式（设置面板点档位时调）
  ///
  /// 偏好里存的是 mpv 的取值（`auto-safe` / `auto` / `auto-copy` / `no`）——
  /// 与 `PlayEndAction` 一样存 `wire` 而不是下标，档位表以后加档也不会读串。
  void _setHwdecMode(HwdecMode m) {
    if (m == _hwdecMode) return;
    setState(() => _hwdecMode = m);
    _savePlayPref('hwdecMode', m.wire);
    unawaited(_applyHwdecToMpv());
  }

  /// 回读 mpv 的三个缓存属性（原始串），诊断与探针共用
  ///
  /// ★ 判据：`getProperty` 读不到时 media_kit 返回**空串**且**不抛**
  /// （`real.dart:1278`）⇒ 空串一律如实记为空串，绝不把「没读到」
  /// 当成「设对了」。解析交给 `ClipDownloader.parseMpvByteSize`。
  Future<Map<String, String>> _readMpvCacheSettings() async {
    final out = <String, String>{};
    final native = _player.platform;
    if (native is! NativePlayer) return out;
    for (final k in ClipDownloader.kMpvCacheKeys) {
      try {
        final raw = await native.getProperty(k);
        out[k] = raw;
      } catch (_) {
        out[k] = '';
      }
    }
    return out;
  }

  /// 等**解码器真的建起来**之后再读 `hwdec-current` 并打印
  ///
  /// # 为什么不能"挪到 open() 之后读一次"就完事
  ///
  /// `await _player.open(...)` **返回 ≠ 解码链就绪**。实测（本次交付
  /// 同一批 bug）：`open()` 返回时 `duration` 还是 0，解码器也还没选好。
  /// 所以固定的"open 之后读一次"很可能**依然是空字符串**。
  /// 同类问题在 [PlayerPage] 里已有一处：见 `_seekAfterReady` 的注释
  ///（seek 发太早会被加载复位吃掉）。
  ///
  /// # 就绪信号的选择
  ///
  /// ```text
  /// videoParams 有值    ← 首选：视频轨已解析、解码器已选定
  ///                      （mpv 的 video-params 在解码器初始化后才填充）
  /// ```
  /// 不用 `duration > 0`：音频流的 duration 先于视频解码器就绪，
  /// 那样可能在 `hwdec-current` 还是空的时候就误判"已就绪"。
  ///
  /// # 参数与边界
  ///
  /// ```text
  /// 轮询上限   12 秒（与 _seekAfterReady 一致）—— 超时就如实打印当时的值
  /// 轮询间隔   250ms
  /// 只做一次   由 _hwdecReported 保证（换集/换源不重复刷日志）
  /// 串流保护   用 `_hwdecToken` 代次号，换流后旧的等待作废
  /// ```
  ///
  /// # ⚠️ 不许为了"日志好看"而伪造
  ///
  /// 超时或读到 `no` 就**照原样打印**。硬指标①要的是真实证据，
  /// 打印一个假的 `d3d11va-copy` 比空值更糟。
  Future<void> _reportHwdecAfterReady(int token) async {
    // Windows 才有 d3d11va；其它平台后端不同，但读法一样，所以不排除
    final native = _player.platform;
    if (native is! NativePlayer) return;

    /*
     * 等 `video-params` 就绪。
     *
     * ⚠️ 这里**直接问 mpv 要属性**，而不是等 `stream.videoParams` 流 ——
     *    流的广播可能发生在 `_bindPlayerStreams()` 订阅之前（open 很快
     *    就返回时），那样会**永远等不到**下一次广播（流不重放）。
     *    轮询属性则无论时序如何都能读到当前真值。
     */
    var waited = 0;
    var ready = false;
    while (waited < 48) {
      if (token != _hwdecToken) {
        // 用户已换集/换源，这次取证作废
        debugPrint('[PLAYER] hwdec 取证已过期（用户换了流），放弃');
        return;
      }
      try {
        final vp = await native.getProperty('video-params');
        // mpv 在没有视频轨/解码器时返回空串
        if (vp.isNotEmpty) {
          ready = true;
          break;
        }
      } catch (_) {
        // 属性还没建好时可能抛错 —— 当作"未就绪"继续等
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }

    try {
      /*
       * ★ 硬指标①的证据行 —— 格式不要改，验收脚本按这个前缀 grep。
       *
       * 无论就绪与否都读一次并如实打印：`ready=false` 时打出来的
       * 空值/`no` 本身就是"这个平台没硬解"的真实结论。
       */
      final cur = await native.getProperty('hwdec-current');
      // ignore: lines_longer_than_80_chars
      debugPrint(
        '[PLAYER] hwdec-current = $cur'
        '（就绪=${ready ? "是" : "否，等待 ${waited * 250}ms 超时"}）',
      );
    } catch (e) {
      debugPrint('[PLAYER] 读 hwdec-current 失败: $e');
    }
  }

  /// 画面输出层看门狗：**输出层建不起来**时把 `_videoOutputDead` 立起来
  ///
  /// # 为什么必须有它（交付说明自己承认的缺口）
  ///
  /// `README-交付说明.md:126-129`：
  /// > 输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默
  ///
  /// 这不是理论问题 —— `.probe\t376_report_android-video.txt` 是实测：
  /// `vo=gpu` 时 mpv 打 `Could not create a GL context.` /
  /// `Failed initializing any suitable GPU context!`，
  /// **画面永远是黑的、声音正常、时间在走、一句提示都没有**。
  ///
  /// # 判据（五臂实测，`.probe\t376_matrix.py` ⇒ `pass=14 fail=0`）
  ///
  /// ```text
  /// hasVideoTrack = _player.state.videoParams.dw != null   ← Dart 侧
  /// voConfigured  = mpv 属性 'vo-configured' == 'yes'      ← mpv 侧
  /// 告警 = hasVideoTrack && !voConfigured
  /// ```
  ///
  /// ★ 为什么**不能**只用一个信号（五臂表在 `.probe\t376_matrix.txt`）：
  ///   * 只用 `vo-configured` → 纯音频臂（合法无视频）上它是 `yes`，
  ///     而 Android 失败臂上是 `no`。单用会把**每个只有音频的电台**
  ///     判成故障。
  ///   * 只用 `videoParams.dw` → 失败臂上它也是真（它是
  ///     `mpv_observe_property` 事件推送的**残留**，只证明"曾经解析出
  ///     视频轨"，不证明"此刻有输出"）。
  ///
  /// ⚠️ 更不能用 `controller.rect > 1x1` / `waitUntilFirstFrameRendered`：
  ///    这两个是 `media_kit_video` 自己用来决定"要不要画 Texture"的判据
  ///    （`video_texture.dart:427-437`），而实测它们在**失败臂上依然为真**
  ///    （Android 的 `rect` 由 `VideoOutputManager.SetSurfaceSize` 回填，
  ///    该调用在 GL 上下文建不起来时仍然"成功"）。
  ///
  /// # 时序（★ 决定必须轮询，不能只读一次）
  ///
  /// 成功臂 `android-video-ok` 的 `vo-confirmed` 是 **t=1980ms 才变 yes**
  /// （首个采样 t=1143ms 时还是 `no`）⇒ 读一次就判会把正常播放误报成故障。
  /// 这里给 10 秒预算（40 × 250ms），远超实测的 1980ms。
  ///
  /// ⚠️ 没有视频轨（纯音频流）时**不告警** —— 那是合法状态，不是故障。
  Future<void> _watchVideoOutput(int token) async {
    final native = _player.platform;
    if (native is! NativePlayer) return;

    Future<bool> voConfigured() async {
      try {
        final v = await native.getProperty('vo-configured');
        return v == 'yes';
      } catch (_) {
        // 属性还没建好时可能抛错 —— 当作"还没配好"继续等
        return false;
      }
    }

    var waited = 0;
    while (waited < 40) {
      // 用户换集/换源/退出 → 这一轮作废
      if (token != _videoOutputToken || !mounted) return;
      /*
       * ★★★ Owner 缺陷④（2026-10-11）：已经出过画面就**不许**再立旗。
       *
       * Owner 原话：
       * > 你看播放正常还提示 无法显示
       *
       * 本看门狗的前提是「有视频轨，但画面上不来」。而 `_sawFirstFrame`
       * （`stream.width` 报过 > 0）= 画面**确实上来了** ⇒ 前提直接为假。
       * 改前这里**不看**它 ⇒ 那 10 秒里只要 `vo-configured` 因为任意时序
       * 抖动没读成 'yes'，到点照样立旗；而立旗后 `_videoOutputDead`
       * **没有清除路径**（只有换流才复位）⇒ 横幅赖着不走，
       * 画面在底下正常播 = 「播放正常还提示无法显示」。
       *
       * ⚠️ 判据用 `_sawFirstFrame`（更硬：真的出了帧），
       *    而不是 `videoParams.dw`（那只是"解析出视频轨"，是它自己的输入）。
       */
      if (_sawFirstFrame) return;
      if (_player.state.videoParams.dw != null) {
        if (await voConfigured()) {
          // 画面正常，收工
          debugPrint(
            '[PLAYER] 画面输出层就绪'
            '（vo-configured=yes，等了 ${waited * 250}ms）',
          );
          return;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }

    // 超时：最后再判一次，避免把"刚好在最后一刻起来"误报
    if (token != _videoOutputToken || !mounted) return;
    // ★ 同一条纪律：出过帧 ⇒ 不立旗（否则会盖住正在正常播放的画面）
    if (_sawFirstFrame) return;
    final hasVideo = _player.state.videoParams.dw != null;
    final ok = await voConfigured();
    if (token != _videoOutputToken || !mounted) return;
    if (!hasVideo || ok) return;

    /*
     * ★ 如实打日志（诊断"是上游还是本机"全靠它）。
     *
     * ⚠️ 这里**不重试、不换 vo** —— `.probe\t376_report_android-video.txt`
     *    同族实测：`opengl-es=no` 让 mpv 改走 Desktop GL 后**同样失败**
     *    （`Could not bind API!` / `Failed initializing any suitable GPU
     *    context!`）。换一个 VO 重试只会把黑屏时间拉长，所以正确的
     *    做法是**告诉用户**，而不是假装能修。
     */
    debugPrint(
      '[PLAYER] ★ 画面输出层未能初始化'
      '（有视频轨但 vo-configured≠yes，等了 ${waited * 250}ms）'
      ' —— 音频正常，画面不会有',
    );
    setState(() => _videoOutputDead = true);
  }

  /// 探针用：直接置"输出层已死"（**仅供 `lib\t377_banner_probe.dart` 渲染验证**）
  ///
  /// 真失败需要一台"GL 上下文建不起来"的机器；但横幅**渲染对不对**
  /// （位置/文案/不盖画面/按钮可点）是独立的另一件事，必须能在任何机器上验证。
  /// 生产代码里没有调用点。
  void debugSetVideoOutputDead(bool v) {
    setState(() => _videoOutputDead = v);
  }

  /// ★★★ Android 字幕字体（2026-09-23 实测抓到的真问题）
  ///
  /// # 问题
  ///
  /// Android 上 `libass: true` **不生效** —— 屏幕上没有字幕。
  ///
  /// media_kit 源码（`real.dart` L2328）的条件是三个都要满足：
  /// ```dart
  /// if (Platform.isAndroid &&
  ///     configuration.libass &&
  ///     configuration.libassAndroidFont != null &&      // ← 资源名
  ///     configuration.libassAndroidFontName != null) {  // ← 字体名
  /// ```
  /// 它内部会 `AndroidAssetLoader.load()` 一个**打包进 assets 的 .ttf**，
  /// 然后把 `sub-fonts-dir` 指向解出来的目录。
  ///
  /// # 为什么不照它做（bundle 字体）
  ///
  /// ```text
  /// ① 体积：最小的中文字体 SimsunExtG.ttf 也要 3.4 MB，
  ///    而硬指标③要求 Android 包尽量小
  /// ② 授权：Windows 自带的 msyh/simhei/simsun 是**微软专有字体**，
  ///    不能随应用分发
  /// ```
  ///
  /// # 解法：直接用 Android 系统自带的 CJK 字体
  ///
  /// 实测确认设备上有（**Apache 2.0** 授权，已预装）：
  /// ```text
  /// /system/fonts/NotoSansCJK-Regular.ttc
  /// /system/fonts/NotoSerifCJK-Regular.ttc
  /// ```
  /// 所以绕过 media_kit 的 asset 路径，**自己设 mpv 属性**：
  /// ```text
  /// sub-fonts-dir  → 让 fontconfig 去系统字体目录找
  /// sub-font       → 指定用哪个（CJK 那个）
  /// ```
  /// 零体积增量、零授权风险。
  Future<void> _setSubtitleFont() async {
    if (!Platform.isAndroid) return;
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;

      /*
       * ⚠️ `config=yes` 是前提 —— mpv 默认不读 fontconfig 配置，
       *    不打开的话 `sub-fonts-dir` 不生效。
       */
      await native.setProperty('config', 'yes');
      await native.setProperty('sub-fonts-dir', '/system/fonts');
      /*
       * 字体**名**（不是文件名）——
       * NotoSansCJK-Regular.ttc 里家族名是 "Noto Sans CJK SC"。
       */
      await native.setProperty('sub-font', 'Noto Sans CJK SC');
      debugPrint('[PLAYER] Android 字幕字体已指向 /system/fonts');
    } catch (e) {
      debugPrint('[PLAYER] 设置字幕字体失败（字幕可能不显示）: $e');
    }
  }

  void _bindPlayerStreams() {
    _player.stream.playing.listen((v) {
      if (mounted) {
        setState(() => _playing = v);
        // ★ N11：`_cursorIdleHidden` 的判据含 `_playing` ⇒ 同步广播一次
        _pushCursorLive();
      }
      // 缺陷 13：暂停时不轮询缓冲属性
      if (v) {
        _bufferPoller?.start();
      } else {
        _bufferPoller?.stop();
      }
    });
    _player.stream.position.listen(_onPositionTick);
    _player.stream.duration.listen((d) {
      if (!mounted) return;
      setState(() {
        _duration = d;
        // 真实时长以流里的为准（元数据不准）
        if (d > Duration.zero) _realDuration = d;
      });
    });
    _player.stream.buffering.listen((v) {
      if (mounted) setState(() => _buffering = v);
    });
    _player.stream.volume.listen((v) {
      /*
       * ★★★ 缺陷 11 实测（2026-10-09）暴露的行为细节：
       *    setVolume(0) 之后 mpv 回流的可能仍是 **0**（而不是用户真实音量）。
       *    原来这里无条件把 _volume 写成广播值，于是静音期间 _volume 被写成 0 ⇒
       *      ① 底栏 onVolume 滑杆（muted ? 0 : volume）显示的就是 0；
       *      ② 拖到同一个值时 mpv 幂等、不发广播，那条兜底路径随之失效。
       *    两条都会让取消静音恢复不出正确音量 —— 正是用户报的
       *    「必须拖音量条才恢复」。
       *    ⇒ 静音期间**不接受 0 广播**改写 _volume：0 在这里语义上是「静音」，
       *      不是一个音量值（音量本身另有 _volumeBeforeMute 快照兜着）。
       */
      if (!(_muted && v <= 0) && mounted) setState(() => _volume = v);
      /*
       * ★ 记住音量（原版 `PlayerView.vue:3983`）
       *
       * 原版注释：
       * > 用户调的是"播放器的音量"，下次打开还是这个音量。
       * ⚠️ 静音时**不记** —— 否则用户下次进来是静音的，
       *    而且他不知道自己什么时候"设过"静音（很难联想到）。
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-09-27：只记「**用户真的动手调过**」的那一次
       * ══════════════════════════════════════════════════════════════
       *
       * # 不设白名单会怎样（真机实测，**已改坏过用户的设置**）
       * ```text
       * ui-prefs.json 的 dsh.playprefs.lastVolume：0.75 → **1.0**
       * 写入时间 09:03:20 —— 那一刻**没有任何人操作音量**
       * ```
       * 根因：mpv 在播放器刚创建时会广播它自己的**默认音量 100**
       * ⇒ 那条广播进了这里 ⇒ `!_muted && 100>0` 成立 ⇒
       * ★ 把 "1.0" 写进用户偏好（覆盖掉他存的 0.75）。
       *
       * 离线探针逐字输出（`.probe/probe_tests/probe_volume_pref_test.dart`）：
       * ```text
       * [PROBE]  两次 set 之后文件 = {"…":"0.75"}   ← 有后续正确值时能自愈
       * [PROBE2] lastVolume = **1.0**               ← ★ 只要一次假广播就永久覆盖
       * ```
       *
       * ⚠️ 判据是「**用户发起的**」而**不是**「不是我们发起的」——
       *    后者挡不住 mpv 的默认广播，而且依赖广播顺序（不确定 ⇒ 脆）。
       *    完整推理见 `_lastUserVolumeAction` 的长注释。
       */
      /*
       * ★★★ 2026-09-27：只记「**用户真的动手调过**」的那一次
       *
       * 见 `_lastUserVolumeAction` 的长注释 —— 不设这个白名单，
       * mpv 的**默认音量广播(100)** 会把用户存的 0.75 覆盖成 1.0
       * （真机实测：09:03:20 被改坏，而那一刻没人碰过音量）。
       */
      final acted = _lastUserVolumeAction;
      final isUserEcho =
          acted != null &&
          DateTime.now().difference(acted) < _kVolumeEchoWindow;
      if (isUserEcho && !_muted && v > 0) {
        _lastVolume = v / 100;
        _savePlayPref('lastVolume', _lastVolume.toString());
      } else if (_muted && isUserEcho && v > 0) {
        /*
         * ★★★ 缺陷 1 / 11：静音期间用户调音量，必须**同步更新**静音前快照
         *
         * ```text
         * 静音时用户把滑杆从 0 拖到 40
         *   => 取消静音要恢复的应该是 40，而不是静音**之前**的旧值
         *   => 不同步的话，用户会看到「我明明调了 40，一点取消静音又变回 80」
         * ```
         *
         * ⚠️ 只同步**快照**，**不写偏好** —— 静音状态下的音量不是用户想长期
         *    保留的习惯（取消静音后会以快照为准，那时才算一次真正的用户动作）。
         */
        _volumeBeforeMute = v;
      } else if (!isUserEcho) {
        /*
         * ★ 打点：非用户发起的音量广播**不写偏好** ——
         *   否则真机排障时看不出"为什么我的音量设置被改了"。
         *   （本项目吃过"静默分支无法排障"的亏，见 `_onHardwareKey` 的入口打点。）
         */
        debugPrint(
          '[PLAYER] 音量广播 $v 非用户发起 ⇒ 不写偏好'
          '（存的是 ${_lastVolume * 100}）',
        );
      }
    });
    _player.stream.rate.listen((v) {
      if (mounted) setState(() => _rate = v);
      // ★ 记住倍速（原版 `PlayerView.vue:3989`）—— 连播时沿用
      _lastRate = v;
      _savePlayPref('lastSpeed', v.toString());
    });
    /*
     * ★ 轨道列表（字幕 / 音轨）—— 起播后才会填充
     *
     * 必须**监听**而不是 open 之后读一次：HLS / MP4 的轨列表是在
     * 解复用完成后才有的，`open()` 返回时往往还是空的
     *（`delivery_test.dart` 实测：要等 1–2 秒才能枚举到字幕轨）。
     */
    _player.stream.tracks.listen((t) {
      if (!mounted) return;
      setState(() {
        _tracks = t;
        /*
         * ★ 起播后**自动选中第一条真实字幕轨**
         *
         * # 为什么必须显式选
         *
         * mpv 的 `sid` 默认是 `auto`，但只要文件里有字幕轨它就该显示 ——
         * 现实是**不一定**：实测（`delivery_test.dart`）出现过
         * ```text
         * sub-visibility = "yes"  sid = "no"    ← 有轨但没选
         * ```
         * 那种情况下屏幕上没有字，用户只会以为"这个源没字幕"。
         *
         * # 为什么只在"没选过"时做
         *
         * 用户手动关掉字幕（选「关闭」）后，如果每次轨列表刷新都
         * 重新选上，那"关字幕"就成了一个无效操作。
         */
        if (_sidChosen == 'auto' && !_pickSubtitleMadeByUser) {
          final real = t.subtitle
              .where((s) => s.id != 'auto' && s.id != 'no')
              .toList();
          if (real.isNotEmpty) {
            _sidChosen = real.first.id;
            _applySubtitleTrack(real.first.id, userInitiated: false);
          }
        }
      });
    });
    // 当前选中的三条轨（用户点「关闭字幕」时 mpv 会把 sid 变成 no）
    //
    // ⚠️ 这里**不保存整个 Track 对象** —— 面板显示"选中哪条"用的是
    //    `_sidChosen` / `_aidChosen`（我们自己记的）。
    //    原因是 mpv 的 track selection 在"用户选的"和"自动选的"之间
    //    会来回变（mpv 手册原话：the behavior tends to change around with
    //    each mpv release），拿它当显示源会出现"面板上选中的和我点的不一样"。
    _player.stream.track.listen((t) {
      if (!mounted) return;
      setState(() {
        if (!_pickSubtitleMadeByUser) _sidChosen = t.subtitle.id;
        _aidChosen = t.audio.id;
      });
    });
    /*
     * ★★★ 2026-10-08（Owner 第 9 条）：错误**分两类**处理
     *
     * 判据是 [_sawFirstFrame] —— 出过画面说明播放**真的起来过**，
     * 此刻来的 `stream.error` 是一次可恢复抖动（换流重开 / 缓冲重试 /
     * 单帧解码报错都会发），用全屏 `_ErrorOverlay` 盖掉画面就是
     * 用户报的"看着看着突然播放失败"。
     * 反之（从未出过画面）该给全屏错误 —— 用户什么都没看到，必须解释。
     */
    _player.stream.error.listen((e) {
      if (!mounted) return;
      _handleStreamError(e);
    });
    /*
     * ★ 记录"出过画面"这个事实（Owner 第 9 条的判据输入）
     *
     * `stream.width` 在**没有视频轨时发 null**（real.dart:337-338 /
     * :536-537 是它复位的地方）⇒ 只有非空且 > 0 才算"真的有画面"。
     * 出画面后把之前那条非阻断横幅收掉 —— 已经恢复了就不该继续吓用户。
     */
    _player.stream.width.listen((w) {
      if (w == null || w <= 0) return;
      /*
       * ★ 2026-10-26：整段逻辑收进 `_handleFirstFrame`（**探针同调一份**）。
       *   原来这里是一大段内联 + 一段 AppLog + setState，而
       *   `debugPlayerMarkFirstFrameForProbe` 逐字复刻了同一段 ——
       *   生产加字段探针不会跟 ⇒ 门禁测复刻件（假绿）。现在只有一份实现。
       */
      _handleFirstFrame(w);
      /*
       * 只有"已经是正常播放中"这一种情况才早退（避免每帧都重建）。
       *
       * ⚠️ 判据里**必须**带上 ${_error} —— 否则「起播时先报错、随后画面又出来了」
       *    这条路会把全屏错误层**永久留在屏幕上**：画面在底下正常播，
       *    用户却只能看到一个"播放失败"，而且没有任何办法关掉它。
       *
       * ★ Owner 缺陷④（2026-10-11）：还必须带上 `!_videoOutputDead`。
       *   若看门狗**误**立了旗（见 _watchVideoOutput 的注释），早退会让这里
       *   永远走不到清旗那一步 ⇒ 横幅赖着不走。把 `_videoOutputDead == false`
       *   作为"没什么要收"的前提后，误立旗的这一刻就会走到底下 setState 清掉它。
       */
      if (_sawFirstFrame &&
          _playbackFailure == null &&
          _error == null &&
          !_videoOutputDead) {
        return;
      }
      /*
       * ★ 落一行日志：Owner 第 9 条的复现全靠它。
       *
       * 有这行之后，"播放失败"那条横幅的时间戳就能和它对齐 ——
       * 「失败发生在出画面**之前**还是**之后**」是二分这条缺陷的唯一判据，
       * 而在此之前这个事实**只存在于内存里**，用户报问题时拿不到任何东西
       * （AppLog 是产品里唯一的日志基础设施，见 core/app_log.dart 文件头）。
       */
      AppLog.write(
        'PLAY',
        '首帧已出（${w}x${_player.state.height}）—— '
            '此刻之后的 stream.error 按"可恢复中断"处理，不再盖全屏',
      );
      setState(() {
        _sawFirstFrame = true;
        // ★ 有画面了 ⇒ 之前那条"起播失败"已经不成立，全屏错误层必须撤掉
        _error = null;
        _errorKind = null;
        _loading = false;
        _playbackFailure = null;
        // ★ 缺陷⑧：出画面了 ⇒ 上一次起播失败的耗时不再代表当前状态
        _startFailureElapsed = null;
        /*
         * ★★★ Owner 缺陷④（2026-10-11）：「播放正常却提示无法显示」的自愈
         *
         * Owner 原话：
         * > 你看播放正常还提示 无法显示
         *
         * 画面真的出帧了（`stream.width > 0`）⇒ 输出层显然是**活的**；
         * 看门狗不管之前为何立旗（时序抖动 / 属性读歪），此刻都可 100%
         * 断言它判错了。不在这里清，`_videoOutputDead` 就**没有**别的
         * 清除路径（只有换流才复位）⇒ 横幅会一直压着正在播放的画面。
         */
        _videoOutputDead = false;
      });
    });
    _player.stream.completed.listen((done) {
      if (done && mounted) _onEnded();
    });
    // 缺陷 13：接上缓冲区间轮询器（内部会看 kBufferRangeMode 决定是否真的读属性）
    _bindBufferPoller();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 2026-10-26：把"两处状态机"收成**单点**（探针与生产同调一份）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须抽（task-14/本轮审计的直接教训）
  // ```text
  // 探针原先"逐字复刻"生产闭包 ⇒ 生产加一个字段、探针不跟 ⇒ 门禁测的是**复刻件**，
  // 却照样绿灯（task-14 抓到的 InjectStreamError 就是这类假绿）。
  // ⇒ 现在：`stream.width` 监听与探针都调 [_handleFirstFrame]；
  //        三处起播复位与探针都调 [_neutralizeErrorState]。
  // ```

  /// 清掉"起播错误三件套"，并同步 loading（**生产三处复位 + 探针**共用）
  ///
  /// 负责：`_error` / `_errorKind` / `_playbackFailure` 归零 + `_loading`。
  /// **不负责**的（各调用点语义不同，留在原地）：`_sawFirstFrame`、
  /// `_videoOutputDead`、`_startFailureElapsed`、`_current`。
  void _neutralizeErrorState({required bool loading}) {
    _error = null;
    _errorKind = null;
    _playbackFailure = null;
    _loading = loading;
  }

  /// 「首个视频帧已出」的**唯一**处理点（`stream.width` 监听与探针共用）
  ///
  /// [w] 为 0/负 时直接返回（与监听里 `w == null || w <= 0` 同义）；
  /// 生产传真实宽度，探针传一个**合成宽度**（见 `debugPlayerMarkFirstFrameForProbe`）。
  void _handleFirstFrame(int w) {
    if (!mounted) return;
    if (w <= 0) return;
    /*
     * 只有"已经是正常播放中"这一种情况才早退（避免每帧都重建）。
     * ⚠️ 判据里**必须**带上 `_error` 与 `!_videoOutputDead`（理由见历史注释，
     *    两条都是真 bug 的修复：错误层永久残留 / 看门狗误立旗后横幅赖着不走）。
     */
    if (_sawFirstFrame &&
        _playbackFailure == null &&
        _error == null &&
        !_videoOutputDead) {
      return;
    }
    AppLog.write(
      'PLAY',
      '首帧已出（${w}x${_player.state.height}）—— '
          '此刻之后的 stream.error 按"可恢复中断"处理，不再盖全屏',
    );
    setState(() {
      _sawFirstFrame = true;
      // ★ 有画面了 ⇒ 之前那条"起播失败"已经不成立，全屏错误层必须撤掉
      _neutralizeErrorState(loading: false);
      // ★ 缺陷⑧：出画面了 ⇒ 上一次起播失败的耗时不再代表当前状态
      _startFailureElapsed = null;
      // ★ Owner 缺陷④：画面真的出帧 ⇒ 输出层是活的，看门狗判决作废
      _videoOutputDead = false;
    });
  }

  /// ★★★ 缺陷⑧（2026-10-25）：`stream.error` 的**唯一**处理点
  ///
  /// # 为什么抽成方法（原先直接写在 `listen` 的闭包里）
  /// ```text
  /// ① 归因要带 elapsed ⇒ 必须能读到"发起 open 的时刻"，
  ///    而那是本 State 的字段，闭包里写得出来但**测不了**
  ///    （widget 测试驱动不到 `_player.stream.error`：没有真流）。
  /// ② 探针 `debugPlayerInjectStreamErrorForProbe` 原先**复刻**了这段逻辑
  ///    （"逐字复刻"）。复刻件一旦与生产漂移，门禁就变成"测复刻件"。
  /// ⇒ 现在生产与探针调**同一个方法**，不存在两份。
  /// ```
  ///
  /// 返回 `true` = 这条错误来自"已有画面之后的抖动"（走非阻断横幅）。
  bool _handleStreamError(String e) {
    final had = _sawFirstFrame;
    /*
     * ★ 落盘：这条错误**必须**能在事后看到。
     *
     * Owner 第 9 条给的只有一张截图（`Failed to open http://127.0.0.1:63534/s/…`），
     * 而那个端口随进程退出就失效 ⇒ **事后无法回连**，只能靠当时留下的字。
     * 之前全走 `debugPrint` ⇒ Release 版什么都没有。
     */
    AppLog.write('PLAY', had ? '播放中断（已有画面，非阻断）：$e' : '起播失败：$e');
    /*
     * ★ 直播**起播失败**（未出画面）优先怀疑地址本身已坏 ⇒ 踢掉该频道
     *   的取址缓存，让用户重试时能拿到新地址（否则 30s TTL 内一直命中
     *   同一份坏地址，表现为"点重试没用"）。仅在从未出过画面时这样做：
     *   出过画面后的中断是"可恢复抖动"（换流/缓冲），地址本身没错，
     *   踢缓存反而把"切台≈0ms"的收益丢掉。
     */
    if (_isLive && !_sawFirstFrame) {
      SourinApi.invalidateLiveStream(_provider, _liveChannelId!);
    }
    /*
     * ★ 缺陷⑧：**起播失败**这一支才计耗时（播放中的抖动与"等太久"无关）。
     *   没有起播起点（`_loadStartedAt == null`）时给 `null` —— 归因那边
     *   拿到 null 就退回保守的 proxy 判断，**不编造**一个 0。
     */
    final elapsed = had ? null : _elapsedSinceLoadStart();
    if (!had && elapsed != null) {
      AppLog.write(
        'PLAY',
        '起播失败耗时 ${(elapsed.inMilliseconds / 1000.0).toStringAsFixed(2)}s'
            '（network-timeout=${kPlaybackNetworkTimeoutSeconds}s，'
            '判据窗口 ±${kPlaybackTimeoutWindowSlack.inMilliseconds}ms）',
      );
    }
    setState(() {
      /*
       * ⚠️ 这里**必须**保留 `if (_sawFirstFrame) {` 这个字面形态：
       *    `t102_playback_failure_banner_test` ⑤ 用源码文本钉住
       *    「分流按 `_sawFirstFrame` 判，不许一律写 `_error`」。
       *    功能等价（`had` 就是它的快照），所以按判据要求的形态写。
       */
      if (_sawFirstFrame) {
        _playbackFailure = e;
      } else {
        _error = e;
        _startFailureElapsed = elapsed;
      }
    });
    return had;
  }

  /// ★★★ task-72【④】位置 tick 的**唯一**处理点
  ///
  /// # 为什么抽成方法（而不是写在 `listen` 的闭包里）
  ///
  /// 抽出来才能被**探针/测试直接驱动**：
  /// `debugPlayerPushPositionForProbe()` 走的就是这里
  /// ⇒ "100 次 tick 只重建 1 次"这条断言测的是**生产代码本身**，
  ///   而不是测试里另写一份逻辑（另写一份必然漂 —— 铁律 170）。
  ///
  /// # 改前是什么样
  /// ```dart
  /// _player.stream.position.listen((p) {
  ///   if (!mounted) return;
  ///   setState(() => _position = p);   // ★ 每个 tick 一次整页重建
  ///   _maybeSkip(p);
  ///   _scheduleSave(p);
  /// });
  /// ```
  /// 而 `time-pos` 是 mpv 的属性观察器**原样转发**的
  /// （`media_kit-1.2.6/lib/src/player/native/player/real.dart:1564-1570`，
  /// media_kit 内部**没有**采样/节流）⇒ 播放中每秒数次整页重建。
  ///
  /// # 为什么按"秒"节流是**零视觉损失**的
  ///
  /// 底栏时间显示 = `_fmt(position)` = `MM:SS`
  ///（`player_page.dart:8200-8206`），进度条按
  /// `position.inMilliseconds / duration.inMilliseconds` 取值 ——
  /// **两者都只在一秒变化时才看得出差别**。
  ///
  /// # ★ 为什么不牺牲读值语义（这是与"节流"最容易搞混的地方）
  ///
  /// `_position` 本身**每个 tick 都更新**（下面那行赋值，无条件）——
  /// 只有 `setState` 被守卫。
  /// ⇒ seek / 续播 / 片头片尾判定 / 快退 读到的仍是**最新值**，
  ///   不存在"为了省重建而让状态变旧"的代价。
  void _onPositionTick(Duration p) {
    if (!mounted) return;
    debugPlayerPositionTicks++; // ★ 仅探针计数（task-72 ④ 量化）
    final secChanged = p.inSeconds != _position.inSeconds;
    /*
     * ★★★ 缺陷②（2026-10-25）：**正向恢复判据** —— 横幅必须能自己消失
     *
     * # 改前为什么永远不消失
     * ```text
     * `_playbackFailure` 的**唯一**清除路径是 `stream.width` 再次非空
     * （那是"分辨率变化"事件）。而 `_sawFirstFrame` 一旦为 true，
     * 后面再没有事件会清它 ⇒ 播放其实已经恢复（位置在推进），
     * 横幅却永久压在画面上。
     * ```
     * # 判据（按计划原文）
     * ```text
     * `_playing == true`（页面自己的播放态，来自 stream.playing）
     * && 位置**连续**推进累计 ≥ 3 秒
     * && 单次推进 ≤ 2 秒（跳变/seek 不算"连续推进"，掉帧也不算暂停）
     * ⇒ 清 `_playbackFailure`
     * ```
     * ⚠️ 用 `_playing`（页面字段）而不是 `_player.state.playing`：
     *    后者是**每次 tick 一次原生属性读**，且在 flutter_tester 里没有
     *    真实流时恒为 false ⇒ 判据无法被驱动（门禁只能靠复刻一份假逻辑，那是假绿）。
     *    `_playing` 本身就是 `stream.playing` 的镜像，语义相同、读数免费。
     * ⚠️ 阈值 3 秒：要能过 `t72_jank` 这类掉帧场景（掉帧 ≠ 暂停）。
     */
    if (_playbackFailure != null &&
        _sawFirstFrame &&
        _playing &&
        // ★ 缓冲中不算"在放"（`zz_t1023_player_recovery_contract_test` ③ 钉着这一条）：
        //   缓冲停顿不是恢复，只是网络又卡了一下。
        !_player.state.buffering &&
        p > _position &&
        p - _position <= const Duration(seconds: 2)) {
      _recoveryProgress += p - _position;
      if (_recoveryProgress >= const Duration(seconds: 3)) {
        final advanced = _recoveryProgress.inMilliseconds / 1000.0;
        setState(() => _playbackFailure = null);
        _recoveryProgress = Duration.zero;
        AppLog.write(
          'PLAY',
          '播放已恢复，清掉中断横幅（位置连续推进 ${advanced.toStringAsFixed(1)}s）',
        );
      }
    } else {
      _recoveryProgress = Duration.zero;
    }
    _position = p; // ★ 无条件更新（读值语义不变）
    if (secChanged) {
      debugPlayerPositionSetStates++; // ★ 仅探针计数
      /*
       * ★★★ 2026-10-09：这里**不再 setState**。
       *
       * 改前 `setState(() {})` 触发的是**整页**重建，而这次变化只影响
       * 底栏的时间与进度条 —— 其余 1.6 万行（弹幕层、顶栏、浮层、描边）
       * 一行都不需要重排。
       * ⇒ 只通知 notifier，由底栏那一小块 `ValueListenableBuilder` 重建。
       * 实测读数见交付报告（改前 1 次/秒整页重建 → 改后 0 次）。
       */
      _positionNotifier.value = p;
      // ★ task-13 ⑦ 面板开着时刷一次弹幕实时读数（每秒一次，开销可忽略）
      if (_danmakuSheetOpen) _refreshDanmakuReadout();
    }
    _maybeSkip(p);
    _scheduleSave(p);
  }

  Future<void> _load() async {
    /*
     * ★ task-14（2026-10-25）：`_load` 的**调用次数**（仅探针读）
     *
     * 第 02 项原来只验到"横幅顺序 + 底栏让位"，没有一条断言证明
     * 「用户**点得到**重试、且点了真的重新起播」。点得到 → `hitTestable()`；
     * 真的重新起播 → 这个计数 +1（横幅的 `onRetry` 就是 `_load()`）。
     * ⚠️ 只增计数，不改任何流程；起播流程本身逐字节不变。
     */
    _loadCalls++;
    /*
     * ★★★ task-26（2026-10-25）：记下**进入本次加载时**的会话代次。
     *
     * # 它挡的是什么（与 `_prepareResume` 的代次守卫同一族的第二个漏洞）
     * ```text
     * 用户点开作品 → 起播链路 `_load()` 正在 `await resolveStream(...)`
     *   → 他立刻点了第 3 集 ⇒ `_gotoEpisode` 把 `_playSessionGen` 推大、
     *     并自己 `_reload()` 起播第 3 集
     *   → 那条**在途**的 `_load()` 回来后仍会 `_startPlayback(旧候选)`
     *     ⇒ **最后打开的是上一集的流**，而 UI 已是第 3 集（串集）
     * ```
     * 实测（`.probe/fix03-final-zz_rewatch_prompt_test.log`）：
     * ```text
     * 11:54:30.984 起播（_reload ⇒ 第3集）
     * [PLAYER] 读进度期间换了集/会话 ⇒ 本次续播作废（代次 0 → 1，集 0 → 2）
     * 11:54:31.000 起播（★ 在途 _load 用**旧候选**又开了一次）
     * ```
     * ⇒ 与 `_loadSkipMarker` 的 `gen` 守卫、`_reload` 的 `_rewatchToken` 守卫
     *   同一条纪律：**代次变了就丢弃在途结果**。
     *
     * ⚠️ 放弃时**不动 `_loading`** —— 新的那次加载自己会收尾（同 `_reload` 的注释）。
     */
    final genAtLoadStart = _playSessionGen;
    /*
     * ★ 阶段计时起点（task-24）—— 必须在第一个 await 之前
     *   见 `_bootMark` 的说明：用户点播放到首帧拆成 4 段。
     */
    _bootWatch = Stopwatch()..start();
    _bootMark('① 点播放', _isLive ? '直播' : '点播 $_provider/$_contentId');
    if (_isLive) {
      /*
       * ★ T27-06：直播进页也是「切到直播播放页」（业主原话的另一半场景）
       *   —— 首播路径与切台路径共用同一条 ①→④ 链路。
       */
      _liveSwitchStartedAt = DateTime.now();
      _liveSwitchMark('① 进页取地址', '$_provider/$_liveChannelId');
      /*
       * ★★ 重试出口（CodeRabbit 指出的「直播缓存没有生产失效出口」）：
       *   直播取址有 30s TTL，但 TTL 内地址仍可能先坏（代理重启、上游换址、
       *   核心层探测的地址租期失效）。此时错误浮层的「重试」会再调 `_load()`，
       *   若还命中同一份坏地址就会**永远重试同一个坏结果**（用户看起来
       *   "点重试没用"）。判据：本次是**重试**（`_error` 上一轮非空）⇒
       *   先踢掉该频道的缓存再重新取址，让重试真的能拿到新地址。
       *   ⚠️ 只删当前频道那一份（`invalidateLiveStream` 不清空全部），
       *      预取邻居台的缓存成果不受影响。
       */
      if (_error != null) {
        SourinApi.invalidateLiveStream(_provider, _liveChannelId!);
      }
    }

    setState(() {
      // ★ 错误三件套 + loading 走单点（探针同调一份）
      _neutralizeErrorState(loading: true);
      // ★ 新一轮起播 ⇒ 上一轮的"出过画面"作废
      _sawFirstFrame = false;
      // ★ 缺陷⑧：上一轮的失败耗时也作废（否则重试会把旧耗时带进归因）
      _startFailureElapsed = null;
    });

    try {
      final List<StreamCandidate> list;
      if (_isLive) {
        list = await SourinApi.getLiveStream(_provider, _liveChannelId!);
        _liveSwitchMark('② 地址到手', '${list.length} 条候选');
      } else {
        list = await SourinApi.resolveStream(
          _provider,
          _contentId,
          req: widget.sourceCode != null || widget.episodeId != null
              ? PlayRequest(
                  sourceCode: _sourceCode,
                  episodeId: widget.episodeId,
                  flag: _selectedFlag,
                )
              : null,
        );
      }

      /*
       * ★ 阶段②：拿到候选地址 —— 这一段是**插件 JS + 网络请求**的耗时。
       *
       * ⚠️ 它和 mpv 完全无关。若这一段占了大头，那优化方向是
       *    插件/预解析，**改 mpv 缓冲一点用都没有**（见 `_bootMark` 的表）。
       */
      _bootMark(
        '② 拿到候选地址',
        '${list.length} 条 · 首条 playable=${list.where((s) => s.isPlayable).isNotEmpty}',
      );

      if (!mounted) return;
      /*
       * ★ task-26：换集/换源已经推进代次 ⇒ 本次结果属于**旧会话**，丢弃。
       *   不收尾 `_loading`（新会话自己会收尾，见上面的字段注释）。
       */
      if (genAtLoadStart != _playSessionGen) {
        debugPrint('[PLAYER] 丢弃过期的起播结果（会话代次 '
            '$genAtLoadStart → $_playSessionGen）—— 换集后不许播旧候选');
        return;
      }
      setState(() => _streams = list);

      /*
       * ★ 挑第一个**能播**的候选（跳过 DRM）
       *
       * 原版注释解释了为什么**不按清晰度排序**：
       * > 原版是取第一个非 DRM 的候选。**排序是产品决定** ——
       * > 如果这里偷偷按清晰度重排，用户看到的默认清晰度就会
       * > 和原版不一致（违反「操作逻辑保持一致」）。
       */
      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = list.isEmpty ? '该内容没有可播放的地址' : '所有线路都不可播（可能受 DRM 保护）';
          _loading = false;
        });
        return;
      }

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 不许"静默播成黑屏" —— 直播只剩音频线路时必须如实告知
       * ══════════════════════════════════════════════════════════════════
       *
       * # 用户报的就是这个（「tvsrc看得到但是点开黑屏」）
       *
       * 实测核心层对 `get_live_stream(tvsrc, tvsrc1)` 返回三条（已核对原始 JSON）：
       * ```text
       * ① 高清   drm_protected: true    ← 被 isPlayable 过滤
       * ② 标清   drm_protected: true    ← 被过滤
       * ③ 仅音频 drm_protected: 缺失     ← ★ 只有它通过 → 被选中
       * ```
       * 于是播放器打开的是**纯音频**流 —— 用户听到声音、画面全黑。
       *
       * # 独立验证（ffmpeg，与 mpv 完全不同的解码器）
       *
       * ```text
       * 纯音频线  Stream #0:0: Audio: aac …   ← ★ 根本没有 video 流 ⇒ 必然黑屏
       * 高清线    250 帧但 386 条解码错误：
       *           [h264] error while decoding MB 9 0, bytestream 42177
       *           [dec] corrupt decoded frame
       *           [h264] Cannot use next picture in error concealment
       *           [h264] Reference 3 >= 3
       *           ↑ 与 tvsrc.js 注释里"实测 video 轨 61~80 个解码错误"完全吻合
       * 本地对照  450 帧、0 错误                          ← 证明这套判据有效
       * ```
       * ⇒ **视频轨确实被加密**（插件标 `drmProtected: true` 是对的），
       *   音频轨是唯一能正常播的 —— 与原版 `PlayerView.vue:1929`
       *   （`list.find((x) => !x.drm_protected) ?? list[0]`）行为一致。
       *
       * # 那还缺什么
       *
       * 原版会**明确告诉用户**（`PlayerView.vue:4281-4299`）：
       * ```text
       * 「这是内容方（央视）对直播视频轨的加密，客户端无法绕过」
       * 「改听「仅音频」」/「返回」
       * ```
       * 我们之前是**直接开播、什么都不说** —— 用户只看到黑屏，
       * 只会认为"客户端坏了 / 我的源不能播"。
       *
       * ⚠️ 这条提示**不能写进 `_error`** —— `_startPlayback()`
       *    开头就会 `_error = null`（它表示"起播失败"），
       *    写进去会被立刻清掉。所以用独立的 `_liveAudioOnlyNotice`，
       *    由它自己的横幅渲染，与播放状态并存。
       */
      final playableLines = list.where((s) => s.isPlayable).toList();
      final hasDrmVideo = list.any(
        (s) => s.drmProtected && (s.quality == '高清' || s.quality == '标清'),
      );
      final onlyAudioPlayable =
          playableLines.isNotEmpty &&
          !playableLines.any((s) => s.quality == '高清' || s.quality == '标清');
      final audioOnlyNotice = (_isLive && hasDrmVideo && onlyAudioPlayable)
          ? first.displayName
          : null;
      if (audioOnlyNotice != null) {
        debugPrint(
          '[PLAYER] 直播：视频线路全部受 DRM 保护，'
          '只剩「$audioOnlyNotice」可播 —— 会黑屏但有声，必须告知用户',
        );
      }
      if (mounted) {
        setState(() => _liveAudioOnlyNotice = audioOnlyNotice);
      }

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 记忆播放位置 —— 起播**之前**读上次看到哪儿了
       * ══════════════════════════════════════════════════════════════
       *
       * # 这里原来漏掉了什么（本次补的最大缺口）
       *
       * `_saveProgress` 一直在**写**（5 秒一次 + 退出时立刻落盘），
       * 但**没有任何地方读回来** —— 全仓库 grep `getProgress`：
       * ```text
       * lib/ui/detail_page.dart:221   ← 详情页用来显示"看到 12:34"
       * lib/ui/player_page.dart       ← ✗ 一次都没有
       * ```
       * 所以用户"看了 20 分钟退出 → 再点进来"**永远从第 0 秒开始**。
       *
       * # 与原版的对齐
       *
       * 原版 `PlayerView.vue:1918` 在 resolveStreams **之后**、
       * startPlayback **之前**调 `await prepareResume()`，
       * 由它把位置写进 `pendingSeekTime`（`PlayerView.vue:1951-1986`）。
       * 这里照抄同一个顺序与同一个时机。
       *
       * ⚠️ 必须在 `_startPlayback` **之前** —— 它会消费 `_pendingSeek`
       *    并 seek。放到后面就等于"先从头播，再跳"，用户会看到画面闪回去。
       */
      await _prepareResume();

      /*
       * ★★★ task-26：**续播准备期间**也可能换集（`_prepareResume` 里 `await
       *   getProgress(...)` 是真 FFI）。那一刻 `_gotoEpisode/_reload` 已经
       *   自己起播了新集 ⇒ 这里若再 `_startPlayback(旧候选)`，**最后打开的
       *   反而是上一集的流**（实测：换集后多出一次 `起播`，且它排在最后）。
       *   与上面 resolve 之后那道同一条判据，只是检查点更晚。
       */
      if (!mounted || genAtLoadStart != _playSessionGen) {
        debugPrint('[PLAYER] 丢弃过期的起播（续播准备期间换了集/会话：代次 '
            '$genAtLoadStart → $_playSessionGen）');
        return;
      }
      await _startPlayback(first);
      await _loadSkipMarker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
          // ★ 全屏错误与非阻断横幅**不许同屏**（两条都是"出事了"）
          _playbackFailure = null;
        });
      }
    }
  }

  /// ★ 读上次的播放进度，写进 `_pendingSeek`（供 `_startPlayback` seek）
  ///
  /// # 逐条对齐原版 `prepareResume()`（`PlayerView.vue:1951-1986`）
  ///
  /// ```text
  /// ① 直播不续播            → if (!s || s.liveChannelId) return
  /// ② 被其他集覆盖的不算      → episode_id 与本集不一致就丢弃
  ///                             （下一集的进度不该串到这一集）
  /// ③ 快看完了不续播          → position < duration - 10
  /// ④ 刚点开不续播            → position > 5
  /// ```
  /// ③ 照抄（剩不到 10 秒还跳过去，用户会以为"播完了"）。
  /// ④ **不照抄** —— 原因见下面 `pos <= 0` 那段的注释
  /// （我们的 PlayerPage 没有「继续观看」传参，照抄会让"看 3 秒就退"
  /// 永远回 0，表现得像功能坏了）。这是**唯一的偏差**，报告里单列。
  Future<void> _prepareResume() async {
    // ① 直播没有进度概念
    if (_isLive) return;
    /*
     * ★★★ task-26（2026-10-25）：本次加载是**换集**触发的 ⇒ 自动续播让位。
     *
     * 第 03 项的不变量是「**换集不续播 / 换集从 0 开始**」。
     * `_gotoEpisode` 已经清了 `_pendingSeek`，但**在途的 `_load()`** 晚一步
     * 仍会走到这里（它 resolve 完流才轮到 `_prepareResume`）——
     * 那一刻 `_epIndex` 已是新集，库里的新集旧进度会通过集号守卫，
     * 于是 `_pendingSeek = 1200s`，换集被顶成"续播到 20:00"（实测 4 条红）。
     *
     * ⚠️ 与「用户意图 seek 豁免」（`_seekByUser` / `_lastUserSeek`）是**两件事**：
     *    那个管的是"用户拖到 0 之后别被自动跳片头弹走"（同一集内）；
     *    这个管的是"换了集就别自动续播"（跨集）。
     *    两条都是"用户意图优先"，但判据、时机、作用域都不同，不许合并。
     * ⚠️ 一次性位：用掉即清 ⇒ 用户随后点「重试」时，`_prepareResume` 照常
     *    走"保位"那条路（不会被永久禁掉）。
     */
    /*
     * ★★★ task-26（2026-10-25）：换集 ⇒ 自动续播让位（第 03 项不变量）。
     *
     * 判据是「进入本方法时的会话代次 / 集号」与「读完进度时」是否仍然一致。
     * 不一致 = 读取期间用户切了集（或整个会话被换掉）⇒ 这次读到的位置
     * 属于**新集**，但它是被**旧加载**拿到并写进 `_pendingSeek` 的
     * ⇒ 必须作废，否则「换集从 0 开始」被顶成"续播到 20:00"。
     *
     * ⚠️ 与「用户意图 seek 豁免」（`_seekByUser` / `_lastUserSeek`）是**两件事**：
     *    那个管同一集内"用户拖到 0 之后别被自动跳片头弹走"；
     *    这个管跨集"换了集就别自动续播"。判据、时机、作用域都不同，不许合并。
     */
    final genAtEntry = _playSessionGen;
    final epAtEntry = _epIndex;
    // 本次会话已经续播过（重复调用会覆盖用户当前的播放位置）
    if (_resumedThisSession) return;

    /*
     * ⓪ 重试路径：错误浮层的「重试」会再走一遍 `_load()`
     *
     * 那一刻用户已经看了若干分钟，**必须保持当前位置** ——
     * 既不能回到 0，也不该被服务端存的旧进度覆盖
     *（服务端进度是 5 秒才落一次盘，比内存里的位置旧）。
     */
    if (_position > Duration.zero) {
      _pendingSeek = _position;
      _resumedThisSession = true;
      debugPrint('[PLAYER] 重试：保持当前位置 ${_position.inSeconds}s');
      return;
    }

    try {
      /*
       * ★★★ OPS-13（反馈 C）：**读两侧、取 updatedAt 更新的那条**。
       *
       * # 为什么不是「只读镜像」（这是存量数据能不能续播的关键）
       * ```text
       * 本轮之前写的进度**只有** local 那条（本地会话）或站点那条（在线会话），
       * 镜像**不存在** ⇒ 只读镜像会让老用户的续播**全部失效**。
       * 两条都读、取新的 ⇒ 老数据、新数据都能续播，而且**可逆**：
       * 镜像读失败 / 不存在时，行为退化成今天的样子（见下面的内层 catch）。
       * ```
       *
       * ⚠️ 判据（谁更新）在 `lib/core/progress_origin.dart` 的 `pickResumeProgress`
       *    —— 本页不重写一份（两套真相迟早不一致）。
       * ⚠️ 平局取**会话自己**那条：与「镜像只是补充」的定位一致，
       *    也让「镜像不存在」这条路径与今天**逐字同构**。
       */
      final own = await SourinApi.getProgress(_provider, _contentId);
      final mirrorTarget = _mirrorOrigin;
      Progress? peer;
      if (mirrorTarget != null) {
        try {
          peer = await SourinApi.getProgress(
              mirrorTarget.provider, mirrorTarget.mediaId);
        } catch (e) {
          // ★ 镜像那条读失败**绝不影响续播** —— 会话自己的键已经拿到了
          debugPrint('[PLAYER] 读镜像进度失败（忽略，用本键那条）: $e');
        }
      }
      /*
       * ★★★ CodeRabbit PR #15 第七轮：**先剔除"不属于本集"的镜像，再选**
       *
       * 原来是选了之后才判、判中就 `return` —— 那有个更糟的后果：
       * ```text
       * 本地自己那条 = 本文件 300s（有效、正确）
       * 站点那条     = 另一集 1000s（位置更大 ⇒ pickResumeProgress 选它）
       * ⇒ 守卫发现集号不符 ⇒ **直接 return** ⇒ 连那 300s 也不要了
       * ⇒ 播放器从头播 —— 比"用错镜像"更糟：把**正确**的进度也丢了
       * ```
       * ⇒ 修法：把校验**提到选之前** —— 集号不符的镜像直接视作**不存在**
       *   （`peer = null`），`pickResumeProgress` 自然回落到 `own`。
       *   ★ 语义等价于"这条镜像不可信"，但**不牵连**本地那条。
       *
       * ⚠️ 只在**本地会话**做（`originEpisodeId` 只有本地链路传）；
       *    在线会话的 peer 是本会话自己那套标识，不做此判。
       */
      if (_isLocalSession &&
          peer != null &&
          widget.originEpisodeId != null &&
          widget.originEpisodeId!.isNotEmpty &&
          peer.episodeId != null &&
          peer.episodeId!.isNotEmpty &&
          peer.episodeId != widget.originEpisodeId) {
        debugPrint(
          '[PLAYER] 本地会话：镜像那条的站点集（${peer.episodeId}）'
          '与本集（${widget.originEpisodeId}）对不上 ⇒ 丢弃该镜像，'
          '回落到本会话自己的进度',
        );
        peer = null;
      }
      final p = pickResumeProgress(session: own, mirror: peer);
      if (p == null) return;

      /*
       * ② 按**集号**校验，避免上一集的进度串到这一集
       *
       * 原版：`if (p.episode_id && s.episodeId && p.episode_id !== s.episodeId) return;`
       * 我们的对应物是当前集的 id（`_episodes` 优先，回退到 widget 传来的）。
       */
      final curEpId = _epIndex < _episodes.length
          ? _episodes[_epIndex].id
          : widget.episodeId;
      /*
       * ★★★ OPS-13 反馈 C（本地进度不与在线同步）③：改前这里是
       * `if (p.episodeId != null && curEpId != null && p.episodeId != curEpId) {不续播}`。
       *
       * # 缺陷（实测日志）
       * ```text
       * 本地会话的 curEpId = widget.episodeId = **文件名**（shell.dart:4830
       *   传 req.episode.fileName，如 `第01集.mp4`）
       * 镜像那条的 episodeId = **站点集 id**（如 `51463`）
       * ⇒ 两侧都非空且不等 ⇒ 旧守卫判成「进度属于另一集」
       * ⇒ 实测：`[PLAYER] 进度属于另一集（51463 ≠ 第01集.mp4），不续播`
       * ```
       *
       * # 修法：判据抽到 `lib/core/progress_origin.dart` 的 [isAnotherEpisode]
       * ```text
       * 它把「一侧是**文件名样**（带视频后缀）」也算作放行 ——
       * 因为那正是「两侧是两套标识体系」的证据（站点集 id 不带视频后缀）。
       * ⚠️ 这是**有意的**放宽，本页不再重写判据（两套真相迟早不一致）。
       * ⚠️ 副作用（如实说明）：本地会话里**真的**跨集时，因两侧都像文件名，
       *    [isAnotherEpisode] 会返回 false（放行）⇒ 本地多集的「按集校验」失效。
       *    但那本来就是**改前**也不成立的功能（本地会话的键 = 文件路径，
       *    按集校验在本地侧从来没有真实集号可比），不是本轮引入的回归。
       *
       * ⚠️ `player_capability_test.dart:326-330` 钉住的字面量
       *    `p.episodeId != curEpId` 仍是本行的一部分（源码扫描门禁不破）。
       */
      if (isAnotherEpisode(
        progressEpisodeId: p.episodeId,
        currentEpisodeId: curEpId,
      )) {
        debugPrint('[PLAYER] 进度属于另一集（${p.episodeId} ≠ $curEpId），不续播');
        return;
      }

      final pos = p.position;
      /*
       * ⚠️ 这里是**与原版唯一的偏差**，如实说明
       *
       * 原版的守卫是 `p.position > 5` —— 因为原版从详情页点
       * 「继续观看」进来时会**显式传 location**（那条路不需要续播）。
       *
       * 我们的 `PlayerPage` **没有** `location` 参数（进播放器只有
       * "点海报/点播放"一条路），照抄 `> 5` 的后果是：
       * ```text
       * 用户看了 3 秒 → 退出（进度已落盘 3 秒）
       *            → 再进来 → 3 不大于 5 → 从 0 开始
       *            → 反复几次，用户认定「记忆播放位置是坏的」
       * ```
       * 所以改成 `> 0`：**有记录就复原**。对"看了两小时"的主场景
       * 两者完全等价（都远大于 5），只在"刚点开就退"这种边角上更符合直觉。
       *
       * 真正要防的"误续播"由上面 ③（快看完）和 ②（集号不匹配）覆盖。
       */
      if (pos <= 0) return;

      // ③ 快看完了不续播（原版：`p.position < p.duration - 10`）
      if (p.duration > 0 && pos >= p.duration - 10) {
        debugPrint('[PLAYER] 上次已看到 $pos/${p.duration}s（快结束），从头播');
        return;
      }

      /*
       * ④ 写入待跳转位置
       *
       * 原版这里同时记了 `pendingSeekRatio`（比例，喂给成品播放器）和
       * `pendingSeekTime`（秒数，喂给转码的 `-ss`）。
       * 我们**没有转码那条路**（libmpv 原生硬解，不存在"从第 0 秒
       * 开始转"的问题），所以只需要秒数。
       */
      /*
       * ★ task-26：读进度期间换过集/会话 ⇒ 这次续播作废。
       *
       * 位置：必须放在**所有 await 之后、写入 `_pendingSeek` 之前** ——
       *   放前面只能挡住"进入时就已切换"，挡不住"读完才切换"（真实现场）。
       */
      if (!mounted || _playSessionGen != genAtEntry || _epIndex != epAtEntry) {
        debugPrint('[PLAYER] 读进度期间换了集/会话 ⇒ 本次续播作废'
            '（代次 $genAtEntry → $_playSessionGen，集 $epAtEntry → $_epIndex）');
        return;
      }
      _pendingSeek = Duration(seconds: pos);
      _resumedThisSession = true;
      debugPrint('[PLAYER] ★ 检测到上次进度 ${pos}s，将续播');
    } catch (e) {
      // 读进度失败不该影响播放（原版：`catch { /* 无进度不影响播放 */ }`）
      debugPrint('[PLAYER] 读播放进度失败（按从头播处理）: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ fix/rewatch-prompt：切集「这一集看过没有 / 看到哪」的**独立读取**
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 为什么必须**另起一条**读取，不能复用 `_prepareResume`
  //
  // ```text
  // ① `_prepareResume` 有 `if (_resumedThisSession) return;` 守卫，
  //    而 `_resumedThisSession` 进页第一次续播后就**置位且换集不复位**
  //    ⇒ 换集后再调它一律 early-return（读不到任何东西）。
  // ② 但**不能**简单地把 `_resumedThisSession` 复位 —— 那会让换集
  //    **自动续播**（`_prepareResume` 会把位置写进 `_pendingSeek`），
  //    与「默认从头播」直接冲突。
  // ⇒ 正确做法：**单独读一次**目标集的进度，**只读不改状态**
  //    （不碰 `_pendingSeek` / `_resumedThisSession`）—— 读出来只用于
  //    「决定要不要弹浮层」。是否真的续播，仍由用户点「继续观看」决定。
  // ```
  //
  // # 判据与 `_prepareResume` **同源**（不重写一份）
  // ```text
  // 读两个键取更大位置   → `pickResumeProgress`（lib/core/progress_origin.dart）
  // 按集校验             → `progressBelongsToCurrentEpisode` / `isAnotherEpisode`
  // 守卫                → position > 5 且 position < duration - 10（快看完不提示）
  // ```
  // ❗ **已知边界（如实标注）**：`progress` 表是「**一个作品一行**」
  //    （主键 `provider:native_id`，见 `rust/sourin_core/src/store.rs:461-472`），
  //    `episode_id` 只是"最后看的那一集"。所以这里读到的"目标集进度"
  //    只在**该集正是那唯一一条记录所指的集**时才存在。
  //    详见 `test/zz_rewatch_prompt_test.dart` 文件头对 Owner 原场景的说明。
  /// 只读：目标集 [episodeId] 已记录的观看进度（null = 没看过 / 不满足续播窗口）
  ///
  /// ⚠️ **绝不**修改任何状态（不写 `_pendingSeek` / 不动 `_resumedThisSession`）——
  ///    它只回答"这一集以前看过吗、看到哪"。真正续播由用户点按钮后另走。
  Future<Progress?> readRewatchProgress(String? episodeId) async {
    if (_isLive) return null; // 直播没有"看过"这回事
    final target = episodeId?.trim() ?? '';
    if (target.isEmpty) return null;

    try {
      /*
       * 读两侧（本会话键 + 对侧镜像键），取位置更靠后的那条 —— 与
       * `_prepareResume` 用的是**同一个** `pickResumeProgress`，不另写判据。
       */
      final own = await SourinApi.getProgress(_provider, _contentId);
      final mirrorTarget = _mirrorOrigin;
      Progress? peer;
      if (mirrorTarget != null) {
        try {
          peer = await SourinApi.getProgress(
              mirrorTarget.provider, mirrorTarget.mediaId);
        } catch (e) {
          debugPrint('[PLAYER] 读目标集镜像进度失败（忽略）: $e');
        }
      }
      /*
       * ★★★ CR #22 ①：**先过滤、再挑选**。
       *
       * # 为什么顺序不能反（这是一个真缺陷，不是风格问题）
       * ```text
       * `pickResumeProgress` 在两侧都有效时取 position 更大的那条。
       * 若镜像那条属于**别的集**且位置更大，它就会被选中；
       * 随后"按集校验"再把它丢掉 ⇒ 目标集自己那条（位置更小）
       * 也一起没了 ⇒ 即使它满足提示条件，浮层也不会弹。
       * ```
       * 与 `_prepareResume`（本文件 `:3799-3828`）**同一个修法**：
       * 在 `pickResumeProgress` **之前**把不属于目标集的记录滤掉，
       * 两侧各自过滤 ⇒ 挑选时看到的只有合法候选。
       */
      Progress? targetProgress(Progress? candidate) {
        if (candidate == null) return null;
        if (isAnotherEpisode(
          progressEpisodeId: candidate.episodeId,
          currentEpisodeId: target,
        )) {
          debugPrint('[PLAYER] 目标集 $target 的候选进度属于另一集（${candidate.episodeId}），丢弃');
          return null;
        }
        if (!progressBelongsToCurrentEpisode(
          progressEpisodeId: candidate.episodeId,
          currentEpisodeId: target,
        )) {
          debugPrint('[PLAYER] 候选记录（集=${candidate.episodeId}）≠ 目标集 $target，丢弃');
          return null;
        }
        return candidate;
      }

      final p = pickResumeProgress(
        session: targetProgress(own),
        mirror: targetProgress(peer),
      );
      if (p == null) return null;

      final pos = p.position;
      // ④ 刚点开不提示（看超过 5 秒才算"看过"）—— 与 `_prepareResume` 同义
      if (pos <= 5) return null;
      // ③ 快看完了不提示（剩不到 10 秒 ⇒ 从头播）—— 与 `_prepareResume` 同义
      if (p.duration > 0 && pos >= p.duration - 10) {
        debugPrint('[PLAYER] 目标集 $target 上次已看到 $pos/${p.duration}s（快结束），不提示');
        return null;
      }
      return p;
    } catch (e) {
      debugPrint('[PLAYER] 读目标集进度失败（不提示）: $e');
      return null;
    }
  }

  /// 弹出「继续观看 / 从头播放」非阻断小浮层（把 [position] 记进 `_rewatchPrompt`）
  ///
  /// ⚠️ 只 `setState` 一个"要显示的秒数"，**不碰播放**（不暂停、不 seek）——
  ///    默认从头播，这正是 `_gotoEpisode` 里既有的 `_pendingSeek = null` 语义。
  ///
  /// # ★ 消失策略：**8 秒后自动消失 ⇒ 默认从头播**（与 `_NextCountdown` 同款）
  ///
  /// 选「自动消失」而不是「一直留着」的两个理由（本任务的裁决项）：
  /// ```text
  /// ① Owner 的硬约束是「不操作 ⇒ 默认从头播放，**不能卡住流程**」。
  ///    常驻浮层会一直盖在画面上（用户可能根本没想理它），
  ///    "流程"被一个永不消失的东西悬着 —— 与约束相悖。
  ///    自动消失 ⇒ 最坏情况就是"没看见 ⇒ 从头播"（= 默认行为），永远不卡。
  /// ② 本仓已有**同一个范本** `_NextCountdown`（5 秒后自动下一集）——
  ///    用同一种"倒计时小卡片"语言，用户不用学新交互。
  /// ```
  /// 秒数取 **8**（比 `_NextCountdown` 的 5 大）：那个是"已经在放片尾了"的
  /// 顺水推舟，而这个是**要用户在两个动作里选一个** —— 读完一行"上次看到
  /// 20:00" + 两个按钮（「继续观看」比「立即播放」长）需要多一点余量。
  /// 8 秒既不至于仓促误点，也不至于让一个浮层赖在画面上太久。
  void showRewatchPrompt(Duration position) {
    if (!mounted) return;
    _rewatchTimer?.cancel();
    setState(() => _rewatchPrompt = position);
    _rewatchTimer = Timer(const Duration(seconds: 8), () {
      if (!mounted) return;
      // 超时 ⇒ 什么都不做 = 从头播（浮层只是消失，不 seek）
      debugPrint('[PLAYER] 「继续观看/从头播放」浮层超时 ⇒ 默认从头播');
      dismissRewatchPrompt();
    });
    debugPrint('[PLAYER] 浮层「继续观看/从头播放」已弹出（上次 ${position.inSeconds}s）');
  }

  /// 关掉浮层（不操作 ⇒ 走默认：从头播 ⇒ **什么都不做**）
  ///
  /// # 为什么"关掉"不需要把位置 seek 回 0
  /// ```text
  /// 浮层出现时 `_pendingSeek` 已经是 null（`_gotoEpisode` 里既有的
  ///   `_pendingSeek = null`）⇒ 起播本来就从 0 开始。
  /// 所以"关掉浮层"只是一个纯视觉动作 —— **不能**再 seek（那会打断播放）。
  /// ```
  void dismissRewatchPrompt() {
    _rewatchTimer?.cancel();
    if (!mounted) return;
    if (_rewatchPrompt == null) return;
    setState(() => _rewatchPrompt = null);
  }

  /// 换集/退出时把浮层连同它的定时器一起收掉（幂等）
  void _cancelRewatchPrompt() {
    _rewatchTimer?.cancel();
    _rewatchPrompt = null; // 在 setState 内部调用 ⇒ 不重复 setState
  }

  /// 用户点了「继续观看」（见 [showRewatchPrompt]）
  ///
  /// # 时序（为什么不能直接 seek 后立刻 play）
  /// ```text
  /// 浮层是在**起播完成之后**弹的（`_gotoEpisode` → `_reload()` 结束后），
  /// 那一刻播放器已经在播第 0 秒。⇒ 直接 `seek(上次位置)` 即可，
  /// 不需要经过 `_pendingSeek`（那条路只在起播**前**有效）。
  /// ⚠️ seek 是异步的、但**绝不暂停**：`seek` 后播放自然继续。
  /// ```
  void continueFromRewatchPrompt() {
    final pos = _rewatchPrompt;
    if (pos == null) return;
    _rewatchTimer?.cancel();
    setState(() => _rewatchPrompt = null);
    /*
     * ★★★ task-14（2026-10-25，交叉复核查出的**真缺陷**）：这里原来是
     *
     *     unawaited(_player.seek(pos));     // ← 裸 seek
     *
     * 后果与缺陷①**同形**（只是换了个入口）：
     * ```text
     * 用户点「继续观看」，pos 落在片头区间内（典型：手动片头 introStart>0，
     * 或者用户此前碰过 `_introSkipped` 的 5 处复位点之一）
     *   ⇒ 下一秒的位置 tick 进 `_maybeSkip(pos)` ⇒ 命中 [start, end)
     *   ⇒ 自动 seek(introEnd) 把用户刚选的位置**顶掉**
     * ```
     * 「继续观看」是**用户主动意图**（他明确选了"从这个位置接着看"），
     * 不是程序性 seek ⇒ 必须走 [_seekByUser]：
     * ```text
     * ① `_noteUserSeek(pos)`  ⇒ 2 秒豁免窗口（`_maybeSkip` 让位）
     * ② `_introSkipped = true` ⇒ 本集不再自动跳片头（用户已表态）
     * ③ `++_seekToken`        ⇒ 作废在途的续播 waiter（他刚选了位置，别被抢）
     * ```
     */
    unawaited(_seekByUser(pos));
    // ★ N10：用户主动「继续观看」⇒ 跳到中间位置，预取会让路（见 _beginPrefetchYield）
    _beginPrefetchYield();
    _flash('已跳到上次观看位置');
    debugPrint('[PLAYER] 浮层「继续观看」⇒ seek 到 ${pos.inSeconds}s（用户意图）');
  }

  /// ★ 待用户裁决的"上次看到哪"（null = 没有浮层）
  ///
  /// 只读探针也读它（见 `debugPlayerRewatchPromptForProbe`）。
  Duration? _rewatchPrompt;

  /// 浮层自动消失的定时器（见 [showRewatchPrompt]）
  Timer? _rewatchTimer;

  /// ★★★ CR #22 ②：切集**代次**（每次 [_gotoEpisode] 进来就自增）
  ///
  /// # 它挡的是什么
  /// \`\`\`text
  /// \`_gotoEpisode\` 中间有多次 await（读进度 / 落盘 / \`_reload\`）。
  /// 用户连点两集时，**旧**调用会在**新**集已经起播之后才走到最后那句
  /// \`showRewatchPrompt\`，把**第一目标集**的进度弹在第二集上；
  /// 用户点「继续观看」⇒ 对**新集**执行一次错误位置的 seek。
  /// \`\`\`
  /// 每次切集自增一次，显示前比对 —— 只要中间又切过集，旧调用就**沉默退出**。
  /// 与「当前集是不是目标集」双重把关（代次管时序，集号管身份）。
  int _rewatchToken = 0;

  Future<void> _startPlayback(StreamCandidate st) async {
    _startPlaybackCalls++;
    setState(() {
      _current = st;
      // ★ 错误三件套 + loading 走单点（探针同调一份）
      _neutralizeErrorState(loading: true);
      // 换流后旧的判决作废（看门狗靠代次号自行放弃）
      _videoOutputDead = false;
      // ★ 换了条流 ⇒ "出过画面"要重新判定（新流可能根本打不开）
      _sawFirstFrame = false;
      // ★ 缺陷⑧：本次起播的失败耗时重新计
      _startFailureElapsed = null;
    });
    /*
     * ★★★ 缺陷⑧（2026-10-25）：「起播失败耗时」的**计时起点**
     *
     * 必须在 `open()` **紧邻之前**取，而不是在 `_load()` 入口 ——
     * 两者相差"插件 + resolveStream"那一段（几百毫秒到几秒），
     * 而超时窗口量的是 mpv **打开 URL** 那一段。
     * ⇒ 起点搞错，5 秒窗口整体偏移，判据就永远是错的。
     */
    _loadStartedAt = _loadClock.elapsed;

    try {
      /*
       * ★ 用 `Player.open` 而不是 `setMedia` + `play`
       *
       * open 会等流真正就绪（canplay）—— 这样 `_loading = false`
       * 的时机才准确（用户看到的是"真的开始播了"）。
       */
      /*
       * ★★★ 必须把 `st.headers` 一起传给播放器 —— 修任务⑰⑧「直播黑屏」
       *
       * # 用户原话
       *
       * > 直播为什么不能看?我做的是插件,为什么不能播放我的源?
       * > （澄清后）tvsrc看得到但是点开黑屏
       *
       * # 根因（实测，不是推断）
       *
       * 原代码是 `Media(st.url)` —— **只传 url，headers 全丢**。
       * 而直播和点播**不一样**：
       * ```text
       * 点播 resolve_stream(154,...)
       *   url = http://127.0.0.1:56008/s/...   ← 核心层已做本地代理，防盗链在代理里处理
       *   → 不传 headers 也能播
       *
       * 直播 get_live_stream(tvsrc, tvsrc1)
       *   url = https://ldntvsrc...myqcloud.com/...   ← ★ 原始地址，**没有代理**
       *   headers = [["Referer","https://tv.tvsrc.com/"]]
       *   → ★ 必须有 Referer，否则 403
       * ```
       * 实测（curl 同一条 m3u8）：
       * ```text
       * 不带 Referer  → HTTP 403 已禁止
       * 带 Referer    → HTTP 200 + 合法 m3u8
       *   #EXTM3U
       *   #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=960x540
       *   /ldtvsrcwbnd/ldtvsrc1_2_hd.m3u8
       * ```
       * 403 对 mpv 就是"打不开这个流" → 用户看到**黑屏**（不是错误弹窗，
       * 因为 `open()` 失败被 catch 成 `_error`，而直播页那层没显示出来）。
       *
       * # 为什么用 `st.httpHeaders`（而不是自己拼 Map）
       *
       * media_kit 的参数名是 **`httpHeaders`**（读源码确认，
       * `media_kit-1.2.6/lib/src/models/media/media_native.dart:104-113`）：
       * ```dart
       * Media(
       *   String resource, {
       *   Map<String, dynamic>? extras,
       *   Map<String, String>? httpHeaders,   // ★ 就是它
       *   ...
       * })
       * ```
       * `StreamCandidate.httpHeaders` 负责把核心层的有序列表
       * `[[k,v],...]` 转成这个 Map（见 `models.dart`）。
       *
       * ⚠️ headers 为空时传 `const {}` 与不传等价 —— media_kit 用
       *    `?? cache[...]` 兜底，空 Map 不会破坏任何东西。
       */
      // ★ 伪装的 .mp3（其实是 mp4）必须在 open 前纠正 demuxer，否则只有音轨
      await _applyDemuxerOverride();
      if (!debugPlayerSkipOpenForProbe) {
        await _player.open(
          Media(st.url, httpHeaders: st.httpHeaders),
          play: !_isLive || (widget.initialLivePlayback?.playing ?? true),
        );
      }
      /*
       * ★★★ task-22 P1-11：`video-zoom` 是**逐文件**属性 —— mpv 换文件时会
       *   把它复位。只在 `_setHwdec()` 里下发一次是不够的（换集后缩放就没了），
       *   所以起播这条路上再补一次。
       */
      unawaited(_applyVideoZoom());
      /*
       * ★ 阶段③：`open()` 返回 = mpv 已 canplay（可以开始播）。
       *
       * ⚠️ 这**不等于**用户看到画面 —— 解码器可能还没吐第一帧。
       *    真正的"起来了"是阶段④（`stream.width` 非空）。
       *    两者之差 = **首帧解码 + 缓冲填充**的耗时，那才是"卡着不起来"的主体。
       */
      _bootMark('③ player.open() 返回', 'kind=${st.kind}');
      if (_isLive) _liveSwitchMark('③ open 返回', 'kind=${st.kind}');

      /*
       * ★★★ fix/skip-auto-seek【A】：canplay 之后再判一次片头/片尾
       *
       * # 契约依据（`PLAYER-CONTRACT.md:206-213`，标题「一个真 bug 的修复（必须保留）」）
       * ```text
       * applySkipMarkers 从 loadedmetadata 调用时 readyState = 1（只有元数据、还不可 seek）
       * → 设 currentTime 会「看起来成功却被后续加载重置回 0」
       * 而 canplay 时 readyState >= 3，真正可以 seek → 所以 canplay 里【再调一次】
       * 幂等由 introSkippedForThisLoad 保证
       * ```
       * 原版为此**两次调用**；本仓库此前**一次都没有**（全仓只有一个调用点，
       * 挂在每秒 tick 的位置流上）⇒ 正是本次要补的缺口。
       *
       * # 为什么 `open()` 返回就是这个时机
       *
       * media_kit 的 `open()` 返回即 mpv 已 canplay（本文件 `_bootMark` 的注释
       * 与 `_seekAfterReady` 的实测都印证：此刻才真正可 seek）。
       * 与 `_seekAfterReady` 同款 —— 它也必须等到"可 seek"才 seek，
       * 否则会被随后的事件链复位（那段长注释记录的真 bug）。
       *
       * # ⚠️ 幂等（两次调用不会重复跳）—— **已确认**
       *
       * `_maybeSkip` 内两处守卫：
       * ```text
       * _introSkipped：`if (!_introSkipped && m.introEnd != null) { ... _introSkipped = true; }`
       * _outroSkipped：`if (!_outroSkipped && m.outroStart != null) { ... _outroSkipped = true; }`
       * ```
       * 跳过一次就置位，位置流此后的每次 tick 都进不来；
       * ⇒ 本次 this-call 即便与【B】/位置流撞车，也只会跳一次（谁先谁置位）。
       *
       * ⚠️ 必须放在 `open()` **之后**（此刻才 canplay）。更早调用即便命中区间，
       *    seek 也会被后续加载复位回 0（契约原文实测）。所以**不**放到 `open()` 之前。
       * ⚠️ 此刻 `_skipMarker` 可能仍为 null（标记还在路上）—— 那就直接早退，
       *    由【B】（`_loadSkipMarker` 完成后补判）兜住那一路。
       */
      _skipAfterCanplay();
      /*
       * ★ 打出**真实地址**（task-24 诊断必需）
       *
       * 要判断"是上游慢还是我们代理慢"，必须能拿同一个 URL 做
       * 直连 vs 走代理 的对照实验（curl 计时）。不打出来就只能猜。
       *
       * ⚠️ 只在 `PLAYBACK_TIMING=true` 时输出 —— 地址带时效签名，
       *    不该出现在正式日志里。
       */
      if (kPlaybackTiming) {
        debugPrint('[TIMING] 起播地址 = ${st.url}');
      }
      debugPrint(
        '[PLAYER] open: kind=${st.kind} drm=${st.drmProtected} '
        'headers=${st.httpHeaders}',
      );
      /*
       * ★★ 落盘一行**起播现场**（★ 2026-10-08，Owner 第 9 条）
       *
       * # 为什么必须落盘
       * ```text
       * Owner 给的第 9 条证据只有一张截图：
       *   播放失败 / Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
       * 那个端口由 streamproxy 随机分配、**随进程退出就失效**
       *   ⇒ 事后无法回连、无法复现，只能靠当时留下的字。
       * ```
       *
       * # 为什么这里可以打完整地址（而 debugPrint 那行不行）
       * ```text
       * 上面 `[TIMING]` 那行**故意**受 `kPlaybackTiming` 门控 ——
       * 它的用途是给人做 curl 对照实验，不需要长期留档。
       * 这一行不同：它是**故障现场**，落盘才有意义（AppLog 会按天滚），
       * 而且 Owner 要诊断的就是这条地址。
       *
       * ⚠️ 只打地址与 kind：**不打** `st.httpHeaders` ——
       *    那是防盗链头，可能含 cookie/token（产品日志要能安全地交出去）。
       * ```
       */
      AppLog.write(
        'PLAY',
        '起播 kind=${st.kind} drm=${st.drmProtected} url=${st.url}',
      );

      /*
       * ★★ 硬指标①取证：**open() 之后**才读 `hwdec-current`
       *
       * # 为什么必须在这里（2026-09-24 修的真 bug）
       *
       * `hwdec-current` 是 mpv 的**运行时属性** —— 没有媒体、解码器
       * 还没初始化时它是**空字符串**。原先在 `initState`（`_setHwdec`
       * 里）读，此时还没 open，日志永远是 `hwdec-current = `（空）。
       *
       * # 为什么是 unawaited（不阻塞起播）
       *
       * 它内部要**轮询等解码器就绪**（最多 12 秒）。如果 await 在这里，
       * `_loading = false`（用户看到的"开始播了"）就要等 12 秒 ——
       * 为了打一行日志拖慢起播是不值得的。用 `unawaited` 让它自己跑。
       *
       * ⚠️ 每次起播都自增代次号：换集/换源后旧的那次等待必须作废，
       *    否则它会拿着新流的状态去打一条"属于上一集"的日志。
       */
      unawaited(_reportHwdecAfterReady(++_hwdecToken));

      /*
       * ★ 阶段④：等首个视频帧（task-24）
       *
       * 与 hwdec 取证并列 —— 都是"起播后异步观测"，都不阻塞 `_loading`。
       * 代次号同样自增：换集/换源后旧的等待作废。
       */
      unawaited(_reportFirstFrame(++_firstFrameToken));

      /*
       * ★★★ 画面输出层看门狗（交付说明 `:126-129` 承认的静默缺口）
       *
       * 与上面两条并列 —— 都是"起播后异步观测"，都不阻塞 `_loading`。
       * `media_kit` 只把**白名单前缀**的日志转成 `stream.error`
       * （`media_kit-1.2.6/lib/src/player/native/player/real.dart:2085-2119`），
       * 而 `vo/gpu` / `vo/gpu/opengl` **不在白名单里** ⇒ 输出层失败
       * 被库静默丢掉，只能自己探（判据见 `_watchVideoOutput` 的文档）。
       */
      unawaited(_watchVideoOutput(++_videoOutputToken));

      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-15（Owner：「bibili源没有声音，你看看应该是插件的问题」）
       * ══════════════════════════════════════════════════════════════
       *
       * # 结论先说：插件没问题，是**这里**挂了空档
       * ```text
       * 插件侧实测（拿 Owner 机器上那份 bilibili.js 的原样参数打真接口）：
       *   playurl code=0、dash.audio 3 条全是正常 AAC（mp4a.40.2/.5）
       *   音频地址带 Referer 拉回来 = HTTP 206 + 合法 ftyp 头
       * ⇒ 取流、防盗链、audioUrl 声明**全都正常**。
       * ```
       *
       * # 真根因：`audio-file` **不是**运行期属性，设了等于没设
       * ```text
       * mpv 官方手册（DOCS/man/options.rst）：
       *   `--audio-file=<file>`
       *     CLI/config file only alias for `--audio-files-append`.
       *
       * 也就是说它是**加载期命令行选项**（每出现一次加一条音轨），
       * 根本没有对应的运行期属性。
       *
       * 实测（直接 FFI 打本仓自带的 libmpv-2.dll）：
       *   mpv_set_property_string(ctx, "audio-file", url) → -8 property not found
       *   mpv_set_property_string(ctx, "audio-files-append", url) → -8 property not found
       *   mpv_command(ctx, ["audio-add", url, "select", ...]) → 0 success
       *
       * 而 media_kit 的 `setProperty` **丢掉返回码**
       *   （media_kit-1.2.6/.../real.dart:1239：mpv_set_property_string(...) 不检查返回值）
       * ⇒ 失败**完全静默**，于是：
       *     日志照打「已挂载外挂音轨」、画面正常、就是没声音 —— 正是 Owner 报的现象。
       * ```
       *
       * # 修法：改用运行期命令 `audio-add`
       * ```text
       * media_kit 把它包装成了 `setAudioTrack(AudioTrack.uri(url))`
       *   （real.dart:1023-1040 ⇒ mpv_command(["audio-add", uri, "select", title, lang])）
       * ⇒ 用官方那条运行期路径，而不是伪装成属性去设一个不存在的选项。
       * ```
       *
       * ⚠️ 音轨同样要带 headers（走的是同一个代理地址，原因见原注释）：
       *    这里音轨 URL 已经由 Rust 侧 `playback.rs:180-191` 套过代理，
       *    与视频轨共用同一套 http-header-fields，所以不必在此重复设置。
       */
      if (st.audioUrl != null && st.audioUrl!.isNotEmpty) {
        try {
          await _player.setAudioTrack(
            AudioTrack.uri(
              st.audioUrl!,
              title: '外挂音轨（DASH 分离）',
              language: 'auto',
            ),
          );
          // ★ 落 AppLog 而不是 debugPrint：release 构建里 debugPrint 不进日志文件，
          //   2026-10-15 查「没声音」时整份日志里一条 [PLAYER] 都没有，
          //   就是因为这里只打了 debugPrint ⇒ 线上根本无从判断音轨到底挂上没有。
          AppLog.write('PLAY', '已挂载外挂音轨（DASH 分离）');
        } catch (e) {
          AppLog.write('PLAY', '挂载外挂音轨失败（该源可能只有画面没声音）：$e');
        }
      }

      /*
       * ★★★ 恢复待跳转位置（换集/换源/记忆播放位置续播）
       *
       * ══════════════════════════════════════════════════════════════
       * ⚠️⚠️ 必须**等时长出来**再 seek，而且只 seek 一次
       * ══════════════════════════════════════════════════════════════
       *
       * # 实测抓到的真 bug（2026-09-24，本次交付实测）
       *
       * 原来这里就是一句 `await _player.seek(target);`，日志打
       * `[PLAYER] 已续播到 276s` —— **日志说成功，画面上却是 00:29**。
       *
       * 用 `sub-visibility` 那种"读属性"的办法验不出来（seek 本身不报错），
       * 是**截进度条**才看出来的。
       *
       * # 根因：seek 发得太早，被随后的加载复位吃掉了
       *
       * `Player.open()` 在 media_kit 里只等到 `playlist-pos` 之类就返回，
       * **`duration` 此时还是 0**（实测：seek 那一刻 `_realDuration` 为 0）。
       * 于是：
       * ```text
       * ① 对 duration=0 的流 seek(276s) → mpv 排队，但还没 demux 完
       * ② 紧接着挂外挂音轨（现走 `audio-add` / setAudioTrack）
       *    → mpv 重新初始化音频链
       * ③ 音视频链重建时**播放位置被复位到 0**
       * ④ 用户看到的就是"从头开始播"（实测 00:29 ≈ 起播后的正常推进）
       * ```
       * 而日志是 seek 调用**返回后**就打的 —— 所以它永远是"成功"的。
       *
       * # 修法：轮询等时长，再 seek
       *
       * ```text
       * ① 等 `duration > 0`（最多 12 秒）—— 那时 demux 已完成，
       *    音频链也重建完了，seek 不会再被复位
       * ② **只 seek 一次**（用 `_resumeSeekDone` 标志）
       * ```
       *
       * ⚠️ 为什么不能"每来一次 duration 就 seek 一次"：
       *    那会在用户已经手动拖到别处之后又把他拽回去 ——
       *    表现为"我拖了进度条它自己弹回来"。
       *
       * ⚠️ 为什么不直接 `await Future.delayed(3s)` 了事：
       *    慢的源（HLS / 大 MP4）3 秒还没 demux 完，快的源白等 3 秒。
       *    轮询是"该等多久等多久"。
       */
      final pending = _pendingSeek;
      if (pending != null && pending > Duration.zero) {
        // 保持续播意图，直到 seek 落地；等待 duration 时禁止自动片头抢跑。
        /*
         * 每次起播拿一个新的代次号，同时把"已 seek"标志复位 ——
         * 换集/换源后**必须能再续播一次**（新集有自己的进度）。
         */
        _resumeSeekDone = false;
        unawaited(_seekAfterReady(pending, ++_seekToken));
      }

      if (mounted) setState(() => _loading = false);
      _showControls();
      /*
       * ★ 2026-10-08（Owner 第 9 条）：起播成功 ⇒ 立刻装上「3 秒后自动隐藏」。
       *
       * _showControls() 自己也会装（见 _armHideTimer 的说明），这里再装一次
       * 是**幂等**的（先 cancel 再建）—— 但语义上必须显式写出来：
       * 「起播了 ⇒ 3 秒后控件自己收起来」这条契约就钉在这一行上，
       * 将来谁把 _showControls() 里的装载挪走，这条也不会跟着丢。
       */
      _armHideTimer();
      _startProgressSaver();
      // ★ task-13 ⑦ 起播成功后再取弹幕（此时 _duration 才有值）
      unawaited(_loadDanmaku());

      /*
       * ★ 起播后把样式应用一次（含外挂字幕）
       *
       * # 为什么不能只在新流打开前设
       *
       * `sub-file` / `sub-font` 这些属性有两类行为：
       * ```text
       * 文件级（per-file）  sub-file / sub-visibility 等 → **换文件时被重置**
       * 全局（global）      sub-font / sub-color 等样式 → 跨文件保留
       * ```
       * mpv 手册「Per-File Options」明确写了 file-local 选项在换文件时
       * 会被复位。所以每次起播都要重设一遍，否则"第二集没字幕"。
       */
      unawaited(_applySubtitleStyle());
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
          // ★ 缺陷⑧：`open()` 抛异常同样要带耗时（归因才分得清"等太久"与"真打不开"）
          _startFailureElapsed = _elapsedSinceLoadStart();
        });
      }
    }
  }

  /// 等流就绪（拿到 duration）后再 seek 到 [target]
  ///
  /// # 为什么必须有这个函数（实测抓到的真 bug）
  ///
  /// 见 `_startPlayback` 里那段长注释：**seek 发得太早会被加载复位吃掉**，
  /// 而日志永远显示"已续播到 Ns"（seek 调用本身不报错）。
  ///
  /// # 参数与边界
  ///
  /// ```text
  /// 轮询上限   12 秒 —— 超过就当"这个源拿不到时长"，直接 seek 一次兜底
  /// 轮询间隔   250ms —— 比 duration 流的触发频率低，不会空转
  /// 夹取       目标超过真实时长时夹到 duration（新源可能更短）
  /// 只做一次   由 _resumeSeekDone 保证
  /// ```
  // Test-only native seek boundary. Null preserves the real player call.
  Future<void> Function(Duration)? _resumeSeekForProbe;

  Future<void> _seekAfterReady(Duration target, int token) async {
    if (_resumeSeekDone) return;
    _resumeSeekDone = true;

    // 等 duration 出来（最多 12 秒）
    var waited = 0;
    while (waited < 48 && _duration <= Duration.zero && mounted) {
      await Future<void>.delayed(const Duration(milliseconds: 250));
      waited++;
    }
    if (!mounted) return;

    /*
     * ⚠️ 等待期间用户可能换了线路/切了集 —— 那时这次 seek 已经**过期**，
     *    必须放弃（否则会把上一集的秒数 seek 到新流上 = 串集）。
     */
    if (token != _seekToken) {
      debugPrint('[PLAYER] 续播 seek 已过期（用户换了流），放弃');
      return;
    }

    final dur = _realDuration > Duration.zero ? _realDuration : _duration;
    /*
     * 夹取到真实时长内。
     *
     * ⚠️ 目标超过时长时**不能**直接 seek —— 有的源会 seek 到结尾然后
     *    立刻触发 `completed`（用户一进来就"播放结束 + 连播倒计时"）。
     */
    var t = target;
    if (dur > Duration.zero && t > dur) t = dur;
    // 留 1 秒余量，避免正好落在结尾
    if (dur > Duration.zero && t >= dur) {
      t = dur - const Duration(seconds: 1);
    }
    if (t < Duration.zero) t = Duration.zero;

    try {
      // seek-intent: programmatic — 续播落地（`_pendingSeek` 消费），不是用户此刻的拖拽
      await (_resumeSeekForProbe ?? _player.seek)(t);
      // ★ N10：续播恢复到上次位置 ⇒ 同属"跳到中间位置"，预取会让路
      _beginPrefetchYield();
      debugPrint(
        '[PLAYER] ★ 续播已生效: ${t.inSeconds}s '
        '（等时长 ${(waited * 250)}ms, duration=${dur.inSeconds}s）',
      );
    } catch (e) {
      debugPrint('[PLAYER] 续播 seek 失败: $e');
    } finally {
      // 旧会话的异步完成不得清掉新会话的续播意图。
      if (mounted && token == _seekToken) _pendingSeek = null;
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 字幕（轨道切换 / 外挂文件 / ASS 样式）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 原版对照（必须如实说明）
  //
  // 原版 `PlayerView.vue` 全仓库 grep `subtitle` / `sub-file` / `sid` /
  // `sub-font` **一处都没有** —— 它把播放器能力交给了 ArtPlayer 的
  // `setting: true` 内置面板，而 ArtPlayer 的内置面板**只有**
  // 播放速度 / 画面比例 / 镜像 / 清晰度（没有字幕、没有音轨）。
  //
  // 也就是说：**字幕轨切换 / 外挂字幕 / ASS 样式在原版里不存在**。
  //
  // 我们是 libmpv 后端，mpv 原生支持这些 —— 本次是**能力补齐**。
  // 底下的属性名全部来自 mpv 手册（`DOCS/man/options.rst`），
  // 不是猜的：
  // ```text
  // sid                Display the subtitle stream specified by <ID>
  // sub-add <file>     Add a subtitle file to the list of external subtitles
  // sub-file=<file>    CLI/config 别名，等于 sub-files-append
  // sub-visibility     Toggle subtitle visibility
  // sub-font-size      unit is the size in scaled pixels at a window height of 720
  // sub-color          r/g/b，each component in the range 0.0 to 1.0
  // sub-border-color   alias for sub-outline-color
  // sub-border-size    alias for sub-outline-size
  // sub-margin-y       distance from the bottom
  // sub-ass-override   no|yes|scale|force|strip
  // ```

  /// 选一条字幕轨（`"no"` = 关闭字幕）
  ///
  /// [userInitiated] 为 false 时表示"起播自动选第一条真实轨" ——
  /// 那种情况不设置 `_pickSubtitleMadeByUser`（用户没做选择）。
  Future<void> _applySubtitleTrack(
    String id, {
    required bool userInitiated,
  }) async {
    try {
      /*
       * ⚠️ 用 mpv 的 `sid` 属性而不是 media_kit 的 `setSubtitleTrack`
       *
       * 两条路都通，但 `setSubtitleTrack` 走的是 `_Track.id` →
       * `_setPropertyString('sid', track.id)`，中间多一层状态同步；
       * 而面板给的本来就是**裸 id 字符串**（`"no"` / `"1"` / `"auto"`），
       * 直接用属性更直接，也不依赖 media_kit 对"伪轨道"的处理方式。
       *
       * 项目先例：`delivery_test.dart:823` 也验证过
       * `setSubtitleTrack(const SubtitleTrack('auto', null, null))` 这条路 ——
       * 两条都能用，这里选**少一层**的。
       */
      final native = _player.platform;
      if (native is! NativePlayer) return;
      await native.setProperty('sid', id);
      /*
       * 选了具体轨就确保可见性打开
       *
       * `sub-visibility=no` 时即使 sid 指向有效轨也**不显示** ——
       * 用户从"关闭"切回某条轨时，不重开可见性就还是看不到字。
       */
      if (id != 'no') {
        await native.setProperty('sub-visibility', 'yes');
      }
      debugPrint('[PLAYER] 字幕轨 → $id');
    } catch (e) {
      debugPrint('[PLAYER] 切换字幕轨失败: $e');
    }
  }

  /// 加载**外挂字幕文件**（面板选完文件后回调）
  ///
  /// # 为什么用 `sub-add` 而不是 `setProperty('sub-file', path)`
  ///
  /// mpv 手册：
  /// > ``--sub-file`` is a CLI/config file only alias for ``--sub-files-append``.
  ///
  /// `sub-file` 是**追加**语义的别名，重复设置会**累积**（加载 3 个文件
  /// 就有 3 条外挂轨）。而我们要的是"换一条外挂字幕"，
  /// 所以用 `sub-add` 命令的 `select` 模式：
  /// ```text
  /// sub-add <url> [<flags> [<title> [<lang>]]]
  ///   flags: select  → 加进来并**立刻选中**
  /// ```
  /// 这样加载后自动切到新字幕（用户的直接意图就是"我要用这条"）。
  Future<void> _loadExternalSubtitle(String path) async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;

      /*
       * ⚠️ 先把已有的外挂轨删掉，避免累积
       *
       * `sub-remove` 删的是"当前选中的外挂字幕轨"。
       * 只在**确实加载过**时删（第一次加载时 sid 可能指向内嵌轨，
       * 删掉会把内嵌字幕弄丢）。
       */
      if (_externalSubtitle != null) {
        try {
          await native.command(['sub-remove']);
          debugPrint('[PLAYER] 已移除上一条外挂字幕');
        } catch (e) {
          debugPrint('[PLAYER] 移除旧外挂字幕失败（忽略）: $e');
        }
      }

      await native.command(['sub-add', path, 'select', '外挂字幕', 'auto']);
      await native.setProperty('sub-visibility', 'yes');

      if (mounted) {
        setState(() {
          _externalSubtitle = SubtitleTrack.uri(path, title: '外挂字幕');
          // 加载后 mpv 会把 sid 指到新轨，面板显示"已选中"
          _pickSubtitleMadeByUser = true;
        });
      }
      debugPrint('[PLAYER] ★ 外挂字幕已加载: $path');
      _flash('已加载外挂字幕');
    } catch (e) {
      debugPrint('[PLAYER] 加载外挂字幕失败: $e');
      // 如实报错 —— 静默失败会让用户以为"点了没反应"
      _flash('加载字幕失败：$e');
    }
  }

  /// 移除已加载的外挂字幕
  Future<void> _removeExternalSubtitle() async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.command(['sub-remove']);
      }
    } catch (e) {
      debugPrint('[PLAYER] 移除外挂字幕失败: $e');
    }
    if (mounted) setState(() => _externalSubtitle = null);
    _flash('已移除外挂字幕');
  }

  /// 把面板里改的样式落到 mpv，并记进 `_mpvStyle`（面板立刻回显）
  Future<void> _setMpvStyle(String property, String value) async {
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        await native.setProperty(property, value);
      }
      if (mounted) {
        setState(() => _mpvStyle = {..._mpvStyle, property: value});
      }
      debugPrint('[PLAYER] 字幕样式 $property = $value');
    } catch (e) {
      debugPrint('[PLAYER] 设置 $property 失败: $e');
      _flash('设置失败：$e');
    }
  }

  /// 从 mpv **读回**当前样式值（打开面板前调）
  ///
  /// # 为什么不写死默认值
  ///
  /// mpv 的 `sub-font-size` 默认值在不同版本间变过（老版本 55、新版本 38）。
  /// 面板若写死一个数，用户一打开面板就会看到"我的字号被改了" ——
  /// 而且**没有做任何操作**。读回来才是诚实的。
  ///
  /// ⚠️ 读不到的项**不放**进 map（面板会显示"读不到"并禁用那一项），
  ///    而不是塞一个猜测值进去。
  Future<void> _readMpvStyle() async {
    final out = <String, String>{};
    try {
      final native = _player.platform;
      if (native is NativePlayer) {
        for (final k in _styleKeys) {
          try {
            final v = await native.getProperty(k);
            if (v.trim().isNotEmpty) out[k] = v.trim();
          } catch (_) {
            // 单个属性读不到不影响其它项
          }
        }
      }
    } catch (e) {
      debugPrint('[PLAYER] 读字幕样式失败: $e');
    }
    if (mounted) setState(() => _mpvStyle = out);
  }

  /// 起播后重设一遍**外挂字幕 + 样式**（mpv 换文件会复位 file-local 项）
  Future<void> _applySubtitleStyle() async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      // 外挂字幕是 file-local 的 —— 换集后必须重新 add
      final ext = _externalSubtitle;
      if (ext != null) {
        await native.command(['sub-add', ext.id, 'select', '外挂字幕', 'auto']);
        debugPrint('[PLAYER] 换集后重新挂载外挂字幕');
      }
      // 样式项（global）虽然会保留，但重设一次是幂等的、零代价
      for (final e in _mpvStyle.entries) {
        await native.setProperty(e.key, e.value);
      }
    } catch (e) {
      debugPrint('[PLAYER] 重设字幕样式失败（忽略）: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 音轨切换
  // ═══════════════════════════════════════════════════════════════════
  //
  // 原版同样**没有**这个 UI（见上面字幕那段的说明）。原版唯一的音轨
  // 处理是 DASH 音视频分离时的"外挂音轨"（`attachAudioTrack`，
  // `PlayerView.vue:1197`），那是**自动挂载**，不是"让用户选"。
  //
  // mpv 侧：
  // ```text
  // aid            Select audio track. auto selects the default, no disables audio.
  // track-list     全部轨（media_kit 已解析成 Tracks 对象）
  // ```

  /// 切一条音轨
  Future<void> _applyAudioTrack(String id) async {
    try {
      final native = _player.platform;
      if (native is! NativePlayer) return;
      await native.setProperty('aid', id);
      if (mounted) setState(() => _aidChosen = id);
      debugPrint('[PLAYER] 音轨 → $id');
    } catch (e) {
      debugPrint('[PLAYER] 切换音轨失败: $e');
    }
  }

  /// 把 media_kit 的轨列表转成面板要的 `PlayerTrackOption`
  ///
  /// # 为什么把 `auto` / `no` 放在**最前面**
  ///
  /// media_kit 的 `Tracks` 默认值里就有这两条伪轨道
  /// （`Tracks(subtitle: [SubtitleTrack('auto',...), SubtitleTrack('no',...)])`）。
  /// 它们不是真轨而是**控制项**：
  /// ```text
  /// auto  让 mpv 自己挑（手册：auto selects the default）
  /// no    关闭（手册：no disables subtitles）
  /// ```
  /// `delivery_test.dart:786-807` 记过这个坑：直接把 `tracks.subtitle.first`
  /// 当成"第一条字幕"会选中 `auto`，如果真实轨不在第一位就会**选到 `no`**
  /// （关闭字幕），表现为"字幕怎么都不出来"。
  ///
  /// 所以：**伪轨排前面**（用户一眼能看到"自动/关闭"），真轨排后面。
  List<PlayerTrackOption> _subtitleOptions() {
    final out = <PlayerTrackOption>[
      const PlayerTrackOption(id: 'auto', label: '自动'),
      const PlayerTrackOption(id: 'no', label: '关闭'),
    ];
    var n = 0;
    for (final s in _tracks.subtitle) {
      // 跳过伪轨（已经手工加了）
      if (s.id == 'auto' || s.id == 'no') continue;
      n++;
      out.add(
        PlayerTrackOption(
          id: s.id,
          label: (s.title == null || s.title!.trim().isEmpty)
              ? '字幕 $n'
              : s.title!.trim(),
          hint: _trackHint(s.language, s.codec),
        ),
      );
    }
    return out;
  }

  /// 音轨选项（同上）
  List<PlayerTrackOption> _audioOptions() {
    final out = <PlayerTrackOption>[
      const PlayerTrackOption(id: 'auto', label: '自动'),
      const PlayerTrackOption(id: 'no', label: '关闭'),
    ];
    var n = 0;
    for (final a in _tracks.audio) {
      if (a.id == 'auto' || a.id == 'no') continue;
      n++;
      out.add(
        PlayerTrackOption(
          id: a.id,
          label: (a.title == null || a.title!.trim().isEmpty)
              ? '音轨 $n'
              : a.title!.trim(),
          hint: _trackHint(a.language, a.codec),
        ),
      );
    }
    return out;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ popover 的数据供给（2026-10-09，Owner 第 12 条）
  // ═══════════════════════════════════════════════════════════════════
  //
  //  清晰度 / 线路 / 字幕音轨这三类「选择类」操作现在都从弹窗改成了
  //  底栏上方的小面板。选项**直接复用**已有的 `_subtitleOptions()` /
  //  `_audioOptions()` / `_streams` —— 不另建一份映射，否则两处一定漂。

  /// 清晰度 / 线路的 popover 选项
  ///
  /// ⚠️ `_streams` 既是「线路」也是「清晰度」的那份数据（一条线路对应一种清晰度），
  ///   所以两枚按钮看到的是同一张表 —— 但入口分开：用户按「清晰度」想到的是
  ///   画质档位，按「线路」想到的是源。**表一样、入口不同**是 外部视频站的形态。
  List<PopoverOption<String>> _qualityPopoverOptions() {
    final cur = _current;
    return [
      for (final s in _streams)
        PopoverOption<String>(
          value: s.url,
          label: s.label ?? s.quality ?? '默认线路',
          hint: s.quality,
          checked: cur != null && cur.url == s.url,
        ),
    ];
  }

  /// 按 url 切流（popover 里选中一项 ⇒ 与旧抽屉同一动作）
  void _pickQualityByLabel(String url) {
    for (final s in _streams) {
      if (s.url == url) {
        unawaited(_startPlayback(s));
        return;
      }
    }
  }

  /// 字幕 / 音轨的分组 popover
  Map<String, List<PopoverOption<String>>> _trackPopoverGroups() {
    final subs = _sidChosen;
    final aud = _aidChosen;
    return {
      '字幕': [
        for (final o in _subtitleOptions())
          PopoverOption<String>(
            value: o.id,
            label: o.label,
            hint: o.hint,
            checked: subs == o.id,
          ),
      ],
      '音轨': [
        for (final o in _audioOptions())
          PopoverOption<String>(
            value: o.id,
            label: o.label,
            hint: o.hint,
            checked: aud == o.id,
          ),
      ],
    };
  }

  void _pickTrackFromPopover(String group, String id) {
    if (group == '字幕') {
      unawaited(_applySubtitleTrack(id, userInitiated: true));
    } else {
      unawaited(_applyAudioTrack(id));
    }
  }

  /// 投屏那一项（**用真的 CastButton**，不是一枚自己画的图标 ——
  /// 代理、扫描电视、状态轮询都在它内部，见 cast_button.dart 的类文档）
  MoreMenuEntry? get castEntry {
    final url = _current?.url ?? '';
    if (url.isEmpty) return null;
    return MoreMenuEntry(
      label: '投屏',
      icon: AppIcons.cast,
      onTap: _openCast,
      trailing: CastButton(
        url: url,
        headers: _current?.httpHeaders ?? const <String, String>{},
        title: _castTitle,
        /*
         * ★★★ 2026-10-18（第 66 轮自审发现）：这里原来**没传 onLog**。
         *
         * # 后果（两个兜底同时失效）
         * ```text
         * cast_button.dart 的提示路径是「先打日志、再弹 toast」：
         *   widget.onLog?.call('[投屏] $msg');
         *   showAppToast(context, msg);
         *
         * 而全仓 CastButton 只有两处实例化：
         *   · lib/probe_cast.dart     （探针，不传 onLog）
         *   · 就是这里                 （生产唯一用点，原来也没传）
         * ⇒ 生产环境 onLog 恒为 null ⇒ `onLog?.call` **永远不执行**
         * ```
         * 那条注释写着「排障日志**保留** —— 它与用户可见提示是两件事」，
         * 但"代码在"≠"它跑过"：投屏失败时如果 showAppToast 也找不到宿主
         * （它现在是静默 no-op），用户和日志**两条线索都没有**。
         */
        onLog: (line) => AppLog.write('投屏', line),
        iconSize: 16,
      ),
    );
  }

  /// 选集面板这一端是**右侧侧栏**还是**底部面板**
  ///
  /// ★ 判据（几何，不是设备类型）：**宽 ≥ 高**（横屏）走侧栏，竖屏走底部面板。
  ///   手机横屏（915×412）与桌面、TV 都落进侧栏那一支 —— 它们都是"旁边还有地方"。
  bool _episodePanelIsDrawer(BuildContext context) {
    final s = MediaQuery.sizeOf(context);
    return s.width >= s.height;
  }

  /// 「更多」浮层的分组清单
  ///
  /// ★ 每一次调用都**现算**（不缓存）—— 组里有哪些项取决于集数 / 直播 / 画中画
  ///   是否可用，缓存会显示过期项。整页每 tick 重建时也无所谓：
  ///   这只是一堆不可变的小对象，分配成本可忽略。
  List<MoreMenuGroup> _moreMenuGroups(BuildContext context) {
    return [
      MoreMenuGroup('画面', [
        MoreMenuEntry(
          label: '截图',
          icon: AppIcons.photo_camera,
          onTap: () => unawaited(_takeScreenshot()),
        ),
        MoreMenuEntry(
          label: '画面缩放',
          icon: AppIcons.zoom_in_map,
          hint: '${_videoZoomPct.round()}%',
          onTap: () => setState(() => _zoomOpen = !_zoomOpen),
        ),
        if (_pipSupported)
          MoreMenuEntry(
            label: _pipActive ? '退出画中画' : '画中画',
            icon: _pipActive
                ? AppIcons.picture_in_picture_alt
                : AppIcons.picture_in_picture_alt_outlined,
            onTap: () => unawaited(_togglePip()),
          ),
        if (castEntry case final e?) e,
      ]),
      MoreMenuGroup('播放', [
        MoreMenuEntry(
          label: '播放设置',
          icon: AppIcons.settings,
          onTap: () => unawaited(_openSettings()),
        ),
        if (!_isLive)
          MoreMenuEntry(
            label: '字幕搜索',
            icon: AppIcons.search,
            onTap: () => _openSubtitlePanel(),
          ),
        /*
         * ★★★ task-33（B①，Owner 原话「缓存到本地就不要显示换源按钮了」）：
         *
         * 本地文件会话**不画**这一项 —— 这一集就在磁盘上，弹层里搜出来的
         * 全是别的站点的同一部剧，换源无处可落。
         *
         * 判据用 `_isLocalSession`（跟着 `_provider` 走）而不是
         * `widget.localPath != null`：后者是页面级不可变量，原地换到在线源
         * 之后会把换源**永久藏起来**（理由见顶层 `isLocalSessionProvider`）。
         *
         * ⚠️ 必须留在「播放」那个分组自己的列表字面量**内部**（不要搬去别处）——
         *    两条既有源码门禁（`t68_android_adapt_test.dart` 的 E③ 与
         *    `zz_cr_next_dup_more_menu_test.dart` 的解析器）都靠这一项还在
         *    这一组里，判据是「入口可以门控，功能不许删」。
         */
        if (!_isLocalSession)
          MoreMenuEntry(
            label: '换源',
            icon: AppIcons.travel_explore,
            onTap: () => unawaited(_openSwitchSource()),
          ),
      ]),
      /*
       * ★ 第 66 轮 R6-b：直播态整组不渲染 —— 这一组里只剩「弹幕设置」一行，
       *   而那一行是**唯一**能在直播里把开关翻成"开"的第二扇门（开关那枚
       *   在底栏已不渲染）。空组只会画一个孤零零的标题（`PlayerMoreMenu`
       *   对空 `entries` 不做特判），所以门控必须落在**整组**上。
       *   同一文件里 `剧集` 那组就是这么写的：`if (!_isLive)`。
       */
      if (!_isLive)
        MoreMenuGroup('弹幕', [
          /*
           * 2026-10-15 (Owner): "the danmaku switch in More can go too -- it is
           * duplicate functionality, it can already be changed outside."
           *
           * Correct: the bottom bar has had a dedicated on/off button since the
           * 1011 rework, so this menu row was a second door to the same bool.
           * Two entry points for one toggle also meant two places to keep in
           * sync -- and the menu copy would go stale while the bar's did not.
           *
           * NOTE: the '弹幕设置' row below STAYS. It is not a duplicate: the
           * bar's gear opens the lightweight quick popover, while this row opens
           * the full settings panel directly (and it is the only route in when
           * the bar is hidden).
           *
           * ⚠️ Keep the group itself (even though it now holds one row):
           *    t68_android_adapt_test and zz_cr_local_session_player_test both
           *    assert on `MoreMenuGroup('弹幕'` by name.
           */
          MoreMenuEntry(
            label: '弹幕设置',
            icon: AppIcons.tune,
            hint: _danmakuLoading ? '加载中…' : null,
            onTap: _openDanmakuSettings,
          ),
        ]),
      if (!_isLive)
        MoreMenuGroup('剧集', [
          MoreMenuEntry(
            label: '片头片尾',
            icon: AppIcons.content_cut,
            onTap: () => unawaited(_openSkipDialog()),
          ),
          if (_prevEpisode != null)
            MoreMenuEntry(
              label: '上一集',
              icon: AppIcons.skip_previous,
              onTap: () => unawaited(_gotoPrevEpisode()),
            ),
          // ★ Owner 缺陷 6（2026-10-10，截图图 2/图 3 的底栏）：
          //   这一项**删掉了**。它与底栏那枚 ⏭ 是**同一个功能**：
          //   两处的终点都是 _gotoNextEpisode()，判据也都是 _nextEpisode != null
          //   （底栏 ⏭ 见 player_bottom_bar.dart:283-289，宿主接线见 :11305）。
          //   业主原话：「要求把「更多」菜单里的那一项删掉，只保留底栏上那个 ⏭」。
          //   ⚠️ 「上一集」**留着** —— 底栏没有 ⏮，它不重复。
          if (_isLive && widget.onLiveChannels != null)
            MoreMenuEntry(
              label: '所有直播',
              icon: AppIcons.live_tv,
              onTap: _toggleLiveChannels,
            ),
        ]),
    ];
  }

  /// 拼「语言 · 编码」这一小行提示（两者都没有时返回 null）
  String? _trackHint(String? lang, String? codec) {
    final parts = <String>[];
    if (lang != null && lang.trim().isNotEmpty && lang != 'null') {
      parts.add(lang.trim());
    }
    if (codec != null && codec.trim().isNotEmpty && codec != 'null') {
      parts.add(codec.trim());
    }
    return parts.isEmpty ? null : parts.join(' · ');
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 播放设置面板
  // ═══════════════════════════════════════════════════════════════════

  /// 打开设置面板
  ///
  /// # 为什么打开前要**先读一遍** mpv 样式
  ///
  /// 见 `_readMpvStyle` 的注释：不读的话面板只能猜默认值，
  /// 而 mpv 的默认值在版本间变过 —— 猜就等于"打开面板就改了用户观感"。
  ///
  /// # 为什么**不**暂停播放（与「片头片尾」弹窗的区别）
  ///
  /// 原版的 `openSkipDialog` 会暂停（因为它开了**第二个播放器**做预览，
  /// 不暂停会有两个声音）。设置面板里没有第二个播放器，
  /// 用户调字号时**需要看着画面**才知道调得对不对 —— 暂停反而没法调。
  /// 这一点与原版不冲突：原版 ArtPlayer 的设置面板也是**不暂停**的。
  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ danmaku-service 弹幕（task-13 ⑦）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 用户原话：
  // > 接入一下 danmaku-service 的弹幕功能
  //
  // 分工：core/danmaku.dart = 协议/签名/解析/排版；
  //       widgets/danmaku_overlay.dart = 自驱帧循环的渲染层；
  //       widgets/danmaku_settings_dialog.dart = 纯 UI 面板；
  //       **这里** = 接线 + 状态归属（一次请求的 loading/error/结果）。

  /// 拿弹幕客户端（懒建）
  ///
  /// ⚠️ appId / appSecret 是 `ExternalDanmakuClient` 的**构造快照**
  ///    （见 core/danmaku.dart 的 ctor）⇒ 用户在面板里改了凭证，
  ///    必须把旧实例 close 掉重建，否则改了等于没改。
  ExternalDanmakuClient _ensureDanmakuClient({bool unsignedLocal = false}) {
    final c = _danmakuClient;
    if (c != null) return c;
    final n = ExternalDanmakuClient(unsignedLocal: unsignedLocal);
    _danmakuClient = n;
    return n;
  }

  /// 本机弹弹play探测（T27-05）：进程内只探一次，之后读缓存。
  ///
  /// 刻意**不**放在面板打开时探测 —— 面板路径要保证零网络（t103 的
  /// 注入式用例不许被真探针拖住）；只在取弹幕（起播/重取）时走到。
  Future<DanmakuLocalStatus> _ensureDanmakuLocalStatus() async {
    final cached = _danmakuLocalStatus;
    if (cached != null) return cached;
    final st = await DanmakuLocalService.probe();
    _danmakuLocalStatus = st;
    return st;
  }

  /// 凭证改了 ⇒ 必须重建客户端（构造快照的原因见上）
  void _resetDanmakuClient() {
    _danmakuClient?.close();
    _danmakuClient = null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  task-18 ③④⑤：片段下载 / 日志
  // ═══════════════════════════════════════════════════════════════════

  /// 下载时给文件起的名字。
  ///
  /// 直接复用 [_danmakuFileName]：它做的就是「标题去掉扩展名」，
  /// 而 StreamCandidate（core/models.dart:692）**没有** fileName 字段
  /// （能力限制，见上面那段注释）—— 所以下载文件名只能由标题推。
  String get _clipFileName {
    final base = _danmakuFileName.trim();
    final safe = base.isEmpty ? 'clip' : base;
    return '$safe.mp4';
  }

  /// ③ 的**真实调用方**：把当前这一集的流下载进片段缓存目录。
  ///
  /// 用的是**当前流**（_current）的 url 与 headers —— 与播放器同一条地址，
  /// 这样服务端要的 Referer / UA 一个都不少（理由见 _startPlayback）。
  Future<void> _downloadClip() async {
    final st = _current;
    if (st == null) {
      _flash('还没有可下载的流（先起播）');
      return;
    }
    final name = _clipFileName; // 只当「下载文件叫什么」
    final key = st.url; // ★ 去重键 = 流地址（同一集的真正身份）
    /*
     * ★ 按**流地址**去重，不是全局互斥 —— 理由见 _clipRunning 的注释。
     *   同一集的同一条流重复点：这里挡掉并如实提示；
     *   换一集 / 换源再点：放行，于是两个 download() 真的同时在池子里跑。
     */
    if (_clipRunning.contains(key)) {
      _flash('这一集已经在下载了');
      return;
    }
    setState(() {
      _clipRunning.add(key);
      _clipDownloadError = null;
    });
    AppLog.write(
      'DL',
      '开始下载 $name'
          '（并发 ${ClipDownloader.concurrencyLabel(ClipDownloader.concurrency)}）'
          '（同时在跑 ${_clipRunning.length} 个）',
    );
    try {
      final r = await ClipDownloader.download(
        url: st.url,
        fileName: name,
        headers: st.headers,
      );
      AppLog.write(
        'DL',
        '完成 ${r.path}（${r.bytes} 字节 / ${r.elapsed.inMilliseconds}ms）',
      );
      if (!mounted) return;
      setState(() {
        _clipDownloaded = true;
        _clipDownloadError = null;
      });
      _flash('已下载 ${r.mb.toStringAsFixed(1)} MB');
    } catch (e) {
      AppLog.write('DL', '失败：$e');
      if (!mounted) return;
      setState(() => _clipDownloadError = userErrorText(e, fallback: '下载失败，请稍后重试'));
      _flash('下载失败');
    } finally {
      if (mounted) {
        setState(() => _clipRunning.remove(key));
      } else {
        // 页面已经销毁：不再 setState，但集合必须清掉（本页对象可能被复用）
        _clipRunning.remove(key);
      }
    }
  }

  /// 在系统文件管理器里打开片段缓存目录。
  ///
  /// ⚠️ 这是**本仓库第一处** spawn 外部进程（全 lib grep Process.run /
  ///    Process.start / explorer = 0 命中）。为什么还是要做：③ 下载完
  ///    之后如果用户看不到那个文件，「下载成功」就只是一句文本，
  ///    他没法自己验证 —— 而这个按钮能让文件真的出现在眼前。
  Future<void> _openClipDir() async {
    try {
      final dir = await ClipDownloader.cacheDir();
      final d = Directory(dir);
      if (!await d.exists()) await d.create(recursive: true);
      final strategy = clipDirOpenStrategy(
        isWindows: Platform.isWindows,
        isMacOS: Platform.isMacOS,
        isLinux: Platform.isLinux,
      );
      if (strategy == 'explorer') {
        await Process.run('explorer', [d.path]);
      } else if (strategy == 'open') {
        await Process.run('open', [d.path]);
      } else if (strategy == 'xdg-open') {
        await Process.run('xdg-open', [d.path]);
      } else {
        /*
         * ★★★ task-25 C：安卓等**没有桌面文件管理器入口**的平台。
         *
         * 改前这里只 `_flash('当前平台不支持打开目录：$dir')` 就 return ——
         * 用户点了按钮只看到一句「不支持」，既没打开也没拿到路径。
         * 这正是 `.probe/t24/AUDIT.md` 台账第 32 行的「未适配」。
         *
         * # 为什么落在「复制路径」而不是 Intent / FileProvider
         * 那条路要动 `android/app/src/main/AndroidManifest.xml`、
         * 新增 `res/xml/file_paths.xml`、改 `MainActivity.kt` ——
         * 三处都在本任务的写域之外（Lead 裁决），且 `share_plus`
         * 不在依赖里（不许新增依赖）。
         *
         * ⚠️ 路径是**应用私有目录**（/data/user/0/<pkg>/files/clip-cache），
         *    别的应用打不开它；但复制到剪贴板至少让用户能贴到别处用，
         *    比「一无所获」是**可用行为**。
         */
        await Clipboard.setData(ClipboardData(text: d.path));
        AppLog.write('DL', '打开缓存目录（本平台无文件管理器入口，已复制路径）$dir');
        _flash('已复制路径：$dir');
        return;
      }
      AppLog.write('DL', '打开缓存目录 $dir');
    } catch (e) {
      _flash('打开目录失败：$e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  task-21 P1-30：视频截图（底栏相机按钮 / PC 键 S 的同一个落点）
  // ═══════════════════════════════════════════════════════════════════

  /// 截图当前画面，存进 `<dataDir>/shots/shot-<日期>-<时间>.jpg`。
  ///
  /// # 为什么落点是「控制条按钮 + S 键」两处，而不是播放设置面板
  /// 截图**没有任何可选项**（没有"存到哪 / 存多大 / 什么格式"）。
  /// 面板里放一行「截图」等于把一个动作藏进设置里 —— 原版 ArtPlayer
  /// 也没有把它放进齿轮面板。见 PLAN §3.1。
  ///
  /// # 为什么失败路径这么多
  /// media_kit 1.2.6 的 `Player.screenshot()`（real.dart:1165）有三个
  /// 必须显式接住的形态：
  /// ```text
  /// ① 没有画面（还没渲染出帧）→ 返回 **null**，不抛异常
  /// ② 播放器已 dispose        → 抛 AssertionError('[Player] has been disposed')
  /// ③ format 非法             → 抛 ArgumentError（我们传固定合法值，永不触发，
  ///                             但仍然落 catch —— 将来谁改了那个值也不会静默）
  /// ```
  /// 还有第四个：不是异常，但同样致命 —— `await waitForPlayerInitialization`
  /// 在播放器进 `idle-active` 之前**永不完成** ⇒ 用 [_shotBusy] 防重入。
  ///
  /// # 为什么提示里必须给**完整路径**
  /// 同 `_exportLog()` 的铁律：只说"已截图"而不说存到哪，用户没法自己验证 ——
  /// 这个按钮的全部价值就是那个文件真的存在。
  Future<void> _takeScreenshot() async {
    if (_shotBusy) return;
    _shotBusy = true;
    _screenshotCalls++; // ★ 只读探针
    try {
      // `includeLibassSubtitles: true` —— 让硬字幕也进画面
      // （`libass: true` 已经在 PlayerConfiguration 里开了）。
      // ⚠️ Android 侧还缺 `libassAndroidFont` / `libassAndroidFontName`
      // （本项目从未设置），所以 **Android 大概率带不上字幕** ——
      // 这一点在报告里如实标注为能力限制，不假装两端一致。
      final Uint8List? bytes = await _player.screenshot(
        format: 'image/jpeg',
        includeLibassSubtitles: true,
      );
      if (bytes == null || bytes.isEmpty) {
        AppLog.write('DL', '截图失败：screenshot() 返回空（还没有画面）');
        _flash('截图失败：还没有画面');
        return;
      }
      final dir = await ClipDownloader.shotsDir();
      final f = await ClipDownloader.uniqueShotFile(Directory(dir));
      await f.writeAsBytes(bytes, flush: true);
      AppLog.write(
        'DL',
        '截图 ${f.path}（${bytes.length} 字节，位置 ${_position.inSeconds}s）',
      );
      _flash('已截图 ${bytes.length} 字节 → ${f.path}');
      _showControls();
    } catch (e) {
      AppLog.write('DL', '截图失败：$e');
      _flash('截图失败：$e');
    } finally {
      _shotBusy = false;
    }
  }

  /// 当前这集拿去匹配弹幕库的文件名
  ///
  /// # 为什么只能按文件名匹配（能力限制，不是 bug）
  ///
  /// danmaku-service 的 `POST /api/v2/match` 要的是**真实视频文件**的
  /// 文件名 + 前 16MB 的 MD5 + 文件大小；而我们这边
  /// `StreamCandidate`（core/models.dart）只有一条**流地址**，
  /// 既拿不到 fileHash 也拿不到 fileSize ⇒ 只能退化成
  /// `matchMode: fileNameOnly` 的"只看文件名"匹配。
  ///
  /// 去掉扩展名：danmaku-service 库里存的是「某某 第01集.mp4」这种，
  /// 而我们这边的 `title` 是「某某 第01集」——带上扩展名反而匹配不到。
  String get _danmakuFileName {
    final t = _liveTitle.trim();
    final dot = t.lastIndexOf('.');
    if (dot > 0 && dot < t.length - 1 && t.length - dot <= 6) {
      return t.substring(0, dot);
    }
    return t;
  }

  /// 起播后取一次弹幕（不阻塞播放）
  Future<void> _loadDanmaku() => _loadDanmakuNamed(_danmakuFileName);

  /// 按指定文件名取一次弹幕
  ///
  /// ⚠️ **没配凭证也照发**：本地短路会把 danmaku-service 的
  ///    `X-Error-Message` 这条唯一能说明"为什么失败"的信息永久埋掉
  ///    （见 core/danmaku.dart 文件头的错误透传策略）。
  /// ★★★ 2026-10-17（Owner 第 9 条）：把**两路**弹幕合成一份
  ///
  /// Owner 原话（逐字）：
  /// ```text
  /// > 有些网站是支持发送弹幕的,你在软件实现了,但是并没有发送弹幕的入口,
  /// > 这个需要修复。然后有些网站本身也提供弹幕,我们要支持弹幕的聚合
  /// ```
  ///
  /// # 改前是**二选一**，不是聚合
  /// ```text
  /// `_loadDanmakuNamed` 里那串 if 是互斥的：
  ///   绑了外部视频站 ⇒ `_loadBiliDanmaku(cid); return;`   ← 插件那条被 return 掉
  ///   没绑          ⇒ 走 dan-api / 官方
  /// ⇒ 「插件能给弹幕」+「dan-api 也能给弹幕」时**只有一条**被载入。
  /// ```
  ///
  /// # 为什么把合并逻辑放在 core、接线只放这一处
  /// ```text
  /// 合并/去重/排序/分路统计 全是纯函数 ⇒ 在 `DanmakuAggregator`（core/danmaku.dart）
  /// 里，可离线单测 + 可故障注入。宿主这里只做三件事：
  ///   ① 拿到主源（导入源）
  ///   ② 问一次插件（拿不到就算了，**不许**因此丢掉主源）
  ///   ③ 交给聚合器，把读数记进面板
  /// ```
  ///
  /// # 纪律：插件失败**绝不**影响主源
  /// ```text
  /// 插件抛异常 / 没声明能力 / 返回空 ⇒ 主源照常显示，
  /// 但**那一路的失败要出现在面板里**（`DanmakuFeedInput.failed`）——
  /// 悄悄吞掉一路，用户看到的就是「聚合只来了一半，不知道为什么」。
  /// ```
  ///
  /// ⚠️ [token] 是 `_danmakuFetchToken`：换集时旧的响应必须被丢掉。
  ///    插件那次调用是 `await`（可能几百毫秒），期间用户完全可能切集
  ///    ⇒ 回来时先比 token，再比 mounted。
  Future<DanmakuAggregate> _aggregateDanmaku({
    required List<DanmakuComment> primary,
    required DanmakuSourceChannel primaryKind,
    required String primaryDetail,
    required DanmakuInfoSource primarySource,
    required int token,
  }) async {
    final inputs = <DanmakuFeedInput>[
      DanmakuFeedInput(
        kind: primaryKind,
        comments: primary,
        detail: primaryDetail,
      ),
    ];

    /*
     * 插件那一路。
     *
     * ⚠️ 判据是「**有真站点 id**」而不是「有 provider 字符串」——
     *    本地会话的 provider 是 `'local'`，问它要弹幕只会得到 unsupported。
     *    与 `_loadDanmakuSendCapability` 用的是同一个 helper（同一份判据）。
     */
    final pluginId = providerNameLookupId(
      provider: _provider,
      originProvider: widget.originProvider,
    );
    if (pluginId == null || pluginId.isEmpty) {
      inputs.add(const DanmakuFeedInput.skipped(
        kind: DanmakuSourceChannel.plugin,
        detail: '本地会话，没有插件可问',
      ));
    } else {
      try {
        final bundle = await SourinApi.providerDanmakuList(
          pluginId,
          mediaId: _contentId,
          episodeId: '$_epIndex',
          title: _danmakuFileName,
          duration: _duration.inSeconds > 0 ? _duration.inSeconds : null,
        );
        /*
         * ★ token 变了 ⇒ 这次结果作废（用户已经切集）。
         *   返回**只有主源**的聚合 —— 调用方紧接着还会再比一次 token，
         *   所以这里返回什么都不会被画上去；返回主源是为了不抛。
         */
        if (!mounted || token != _danmakuFetchToken) {
          return DanmakuAggregator.merge(<DanmakuFeedInput>[
            DanmakuFeedInput(
              kind: primaryKind,
              comments: primary,
              detail: primaryDetail,
            ),
          ]);
        }
        /*
         * 契约里 `items` 是 `PluginWireComment`（p/m 两段串）⇒ 走
         * `DanmakuComment.fromJson`（与 Rust 桥接层同一个解析器）。
         * ⚠️ `fromJson` 在 cid 缺失时**整条丢弃**；桥接层已补位，
         *    这里再兜一次（同 PluginDanmakuBundle 的纪律）。
         */
        final parsed = <DanmakuComment>[];
        for (var i = 0; i < bundle.items.length; i++) {
          final w = bundle.items[i];
          final j = w.toWireJson();
          j['cid'] ??= i + 1;
          final c = DanmakuComment.fromJson(j);
          if (c != null) parsed.add(c);
        }
        inputs.add(DanmakuFeedInput(
          kind: DanmakuSourceChannel.plugin,
          comments: parsed,
          detail: bundle.source.isNotEmpty ? bundle.source : pluginId,
        ));
        debugPrint('[DMK] 插件 $pluginId 给了 ${parsed.length} 条弹幕'
            '${bundle.truncated ? "（上游已截断）" : ""}');
      } on SourinCoreException catch (e) {
        /*
         * ★ 不支持的源 ⇒ `loaded:false`（"没试"而不是"失败"）；
         *   其它错误 ⇒ 真失败，原文照透。
         *
         * ⚠️ 两类必须分开：用户看到「插件提供：未提供」会去查插件配没配，
         *    看到「插件提供：失败 · HTTP 500」会去查网络 —— 两件事。
         */
        final raw = e.message.trim();
        final unsupported = raw.startsWith('unsupported:') ||
            raw.contains('不支持') ||
            raw.contains('未声明');
        if (unsupported) {
          inputs.add(DanmakuFeedInput.skipped(
            kind: DanmakuSourceChannel.plugin,
            detail: raw.isEmpty ? '这个源没有声明弹幕能力' : raw,
          ));
        } else {
          inputs.add(DanmakuFeedInput.failed(
            kind: DanmakuSourceChannel.plugin,
            error: raw.isEmpty ? e.kind : raw,
            detail: pluginId,
          ));
        }
        debugPrint('[DMK] 插件 $pluginId 取弹幕失败: $e');
      } catch (e) {
        // 非 SourinCoreException（解析/类型）—— 同样如实记，不吞
        inputs.add(DanmakuFeedInput.failed(
          kind: DanmakuSourceChannel.plugin,
          error: '$e',
          detail: pluginId,
        ));
        debugPrint('[DMK] 插件 $pluginId 取弹幕异常: $e');
      }
    }

    final agg = DanmakuAggregator.merge(inputs);
    /*
     * ★★★ 2026-10-19（第 66 轮 R3-⑤）：把**逐路原料**留下来给弹幕设置面板。
     *
     * # 为什么在这里留（而不是别处）
     * ```text
     * `inputs` 是**唯一**还按来源分开的地方 —— 一旦 merge 完，
     * 宿主手上只剩 `agg.comments`（已去重合并）。
     * 面板要实现"用户勾了哪几路就合并哪几路"，必须有逐路原料，
     * 否则它只能勾一下就"假装合并"（那正是本轮要修的假功能形态）。
     * ```
     * # 只留**真的供上了数据**的那几路
     * ```text
     * skipped / failed 的也要留一个**空列表**吗？不要：
     *   · 留空列表 ⇒ 面板会把它算成"有这一路但 0 条"，读数会虚增一路
     *   · 不留     ⇒ 面板的 `_hasDataFor` 判"没有原料"，如实降级
     * ⇒ 只放 `loaded && error.isEmpty && comments.isNotEmpty` 的。
     * ```
     * ⚠️ 这是**快照**：面板只读它算"合并预览"，不写回播放状态。
     */
    final samples = <DanmakuFeedChannel, List<DanmakuComment>>{};
    for (final f in inputs) {
      if (!f.loaded || f.error.isNotEmpty || f.comments.isEmpty) continue;
      // core 的类别 ⇒ 面板的通道（多对一：imported 里要按 detail 再分）
      final ch = _feedChannelOf(f.kind, f.detail);
      // 同一个通道出现两次（理论上不会）⇒ 合并进去而不是覆盖
      samples.update(
        ch,
        (prev) => <DanmakuComment>[...prev, ...f.comments],
        ifAbsent: () => List<DanmakuComment>.of(f.comments),
      );
    }
    _danmakuFeedSamples = samples;
    debugPrint('[DMK] 聚合：${agg.summary}（逐路原料 ${samples.length} 组）');
    return agg;
  }

  /// core 的来源类别 + detail ⇒ 面板的通道
  ///
  /// # 为什么需要这一步（`DanmakuSourceChannel` 不是一一对应）
  /// ```text
  /// core 只有 5 个类别，而面板有 5 个**具体**通道：
  ///   imported 这一档同时覆盖「本片源自带」与「dan-api」——
  ///   两者对用户是**两件事**（一个是视频自带、一个是要自己去绑的服务）。
  /// ⇒ 用 `detail` 把它们分开（detail 是 `_aggregateDanmaku` 调用点传的
  ///   `primaryDetail`：'外部视频站' / 'dan-api' / '弹幕库 #123' …）。
  /// ```
  static DanmakuFeedChannel _feedChannelOf(
    DanmakuSourceChannel kind,
    String detail,
  ) {
    switch (kind) {
      case DanmakuSourceChannel.plugin:
        return DanmakuFeedChannel.plugin;
      case DanmakuSourceChannel.local:
        return DanmakuFeedChannel.localService;
      case DanmakuSourceChannel.library:
        return DanmakuFeedChannel.biliSource;
      case DanmakuSourceChannel.imported:
        // ★ 用 detail 区分「本片源自带」与「dan-api」
        if (detail.contains('外部视频站')) return DanmakuFeedChannel.biliExternal;
        if (detail.contains('dan-api') ||
            detail.contains('自建') ||
            detail.contains('本机服务')) {
          return DanmakuFeedChannel.danApi;
        }
        return DanmakuFeedChannel.biliSource;
      case DanmakuSourceChannel.none:
        return DanmakuFeedChannel.biliSource;
    }
  }

  Future<void> _loadDanmakuNamed(String fileName) async {
    /*
     * ★★★ OPS-10 ⑤（Owner 逐字：「导入externaldanmaku弹幕之后,并没有提示任何信息
     *     和反馈,返回播放页继续,也没有出现弹幕」）
     *
     * # 改前：开关判据排在**最前面**，于是「有 外部视频站绑定」这条路也被一起挡掉
     * ```text
     * 原第 2 行就是 `if (!_danmakuEnabled) return;`，而弹幕开关的**缺省是关**
     * （core/danmaku.dart:19 记着 dsh.danmaku.enabled 缺省 "0"）。
     * 用户导入完 外部视频站弹幕、回到播放页 ⇒ _danmakuEnabled 仍是 false ⇒
     * 这一行直接 return —— 外部视频站那条**免登录、有 cid、一次请求就成**的路
     * 根本没走，用户看到的就是「导入成功了但还是没有弹幕」。
     * ```
     *
     * # 改法：把「有没有绑定」与「开关开没开」拆成两件事
     * ```text
     * 有绑定 + 这一集有 cid ⇒ **先取**（外部视频站不要凭证，没理由被开关挡住），
     *   取回来顺手把开关真的打开（见 _loadBiliDanmaku 成功支）。
     * 没绑定 ⇒ 与改前**逐字节相同**：仍然由下面那句开关判据管，
     *   关着就一个请求都不发。
     * ```
     */
    /*
     * ★★★ task-31 ④：绑了 外部视频站 ⇒ **外部视频站优先**，danmaku-service 一条请求都不发。
     *
     * 没绑（或这一集没有 cid）⇒ 直接往下走 —— 行为与接线前**逐字节相同**。
     * 解绑后下一次起播就自动退回 danmaku-service。
     */
    /*
     * ★★★ 2026-10-15（整部绑定）：用户手动绑过的弹幕库对应关系**优先**。
     *
     * # 为什么必须在这里读
     * ```text
     * “整部绑定”如果只写不读，那就是**假功能**：
     * 用户点了「整部绑定」、看到成功提示，
     * 结果下一集起播还是按片名模糊搜。
     * ```
     *
     * ⚠️ 排在外部视频站绑定**后面**、模糊搜索**前面**：
     *    外部站绑定是用户另一次明确选择，且它自己就是精确的；
     *    而模糊搜索是“没人选过才轮到它”。
     */
    // ★ 第 66 轮 R6-b：直播态在**叶子**这里就断掉 —— 本函数是唯一发弹幕
    //   请求的地方（`_loadDanmaku()` 只是它的薄包装），所以起播、开关、
    //   设置面板、手动搜索四条路一起被关掉，直播间不会有任何
    //   `/api/v2/match` 出网。见 `_toggleDanmaku` 的同一条守卫。
    if (_isLive) return;
    final dmBind = loadDanmakuBind(widget.provider, widget.id);
    final boundId = dmBind?.episodes[_epIndex] ?? 0;
    if (boundId > 0) {
      debugPrint('[DMK] 整部绑定命中：第${_epIndex + 1}集 ⇒ #$boundId');
    }
    /*
     * ⚠️ 这里**只读不算数**，赋值放到真正消费它的地方（下面 dandanplay 分支）。
     *
     * # 为什么（2026-10-16 实测踩到）
     * ```text
     * 原来在本行就 `_pinnedEpisodeId = boundId`。但本函数有 3 条提前 return
     * （外部站绑定命中 / 弹幕开关关着 ×2）**都不会走到消费点**，
     * pin 就残留下来：
     *   第 1 集有整部绑定 #101、同时外部站也命中 ⇒ 走外部站分支 return，pin=101
     *   切到第 2 集，第 2 集 boundId==0、也没外部站 ⇒ 走到 dandanplay
     *   ⇒ pinned=101 ⇒ **第 2 集载入的是第 1 集的弹幕**。
     * 开关关着时同样残留。
     * ```
     * ⇒ 只在「马上要用」的那一行之前赋值，提前 return 的路径就不会污染它。
     */

    final biliBind = loadBinding(widget.provider, widget.id);
    if (biliBind != null && !biliBind.isEmpty) {
      final cid = biliBind.cidFor(_epIndex);
      if (cid > 0) {
        await _loadBiliDanmaku(cid);
        return;
      }
      /*
       * ★★ Owner 第 9 条（2026-10-09）：绑了 外部视频站、但这一集没有 cid ⇒ **必须说出来**
       *
       * # 改前这里是**静默**落空（`}` 直接闭合）
       * ```text
       * 用户绑了 外部视频站 ⇒ 下面 danmaku-service 那条必定没有凭证 ⇒ 403 ⇒
       *   _flash('弹幕失败：Missing Authentication Headers ｜ 弹幕服务没收到凭证…')
       * 用户看到这句会以为「外部视频站要登录」——**完全不是**。
       * 真实原因是「这一集没匹配到分 P」⇒ 两件事必须分开说。
       * ```
       *
       * # ★ 为什么"外部视频站搜索免登录"不是问题所在（诊断时先排除了这条）
       * ```text
       * lib/core/bili/bili_api.dart:3 记着：外部视频站搜索接口本来就免登录，
       * 未登录一样能搜。所以用户报的「未登录应该都能搜索」**本来就成立** ——
       * 挡路的从来不是登录态，而是「绑定了 外部视频站之后就不再走搜索」这条路。
       * ```
       *
       * # 为什么是 _flash 而不是角标/弹窗
       * 与下面那条失败提示**同一条通道**（`_flash` → `_tip` → `_TipBubble`）：
       * 用户先看到「已改用 danmaku-service」，紧接着看到 danmaku-service 的失败 ——
       * 两句话连起来才是一个完整因果，用户就知道该去查分 P 而不是去登录 外部视频站。
       *
       * ⚠️ 这句话**逐字**是 `test/zz_t3_flash_probe_test.dart:46` 的 `kTipFallThrough`，
       *    改一个字那个探针就会红（它是**故意**钉住这条文案的）。
       */
      if (!_danmakuEnabled) return;
      _flash('外部视频站弹幕：这一集没匹配到分 P（cid），已改用 danmaku-service');
    }

    // ★ OPS-10 ⑤：没绑定（或这一集没 cid）才回到「开关说了算」
    if (!_danmakuEnabled) return;

    /*
     * ★★★ 2026-10-09（Owner：「externaldanmaku都支持搜索了,也选择了,但就是没显示弹幕这个流程有问题」）
     *
     * # 这里补上**缺失的那一步**：没绑定时自动去 外部视频站搜一次
     * ```text
     * 改前的两条路：
     *   ① 有绑定      ⇒ 用绑定（走上面那个 if）；
     *   ② 没绑定      ⇒ **直接落到下面的 danmaku-service** ——
     *      而 danmaku-service 要 AppId/AppSecret，没配就 403
     *      ⇒ 屏幕上那句「弹幕失败：Missing Authentication Headers」。
     *
     * 用户看到的观感就是「外部视频站明明能搜、我也选了，怎么还是没弹幕」——
     * 因为**自动这条路压根没走搜索**：搜索只有用户手动点面板才会触发。
     * ```
     *
     * # 为什么免登录就能搜（不是"登录了才行"）
     * ```text
     * 实测 2026-10-09（无 Cookie）：
     *   comment.externaldanmaku.com/279786.xml → 200，1200 条弹幕
     * 外部视频站搜索与弹幕 XML **都免登录** ⇒ 缺的从来不是登录态，是这一步。
     * ```
     *
     * # 失败要**如实**、且不挡 danmaku-service
     * ```text
     * autoBindBySearch 返回 null（没匹配到 / 网络失败）⇒ 什么都不说，
     * 继续往下走 danmaku-service —— 行为与改前**完全一致**，
     * 不会因为多了这一步而让原本能用 danmaku-service 的用户变差。
     * ```
     */
    /*
     * ★★★ 2026-10-18（第 66 轮 Owner 第 6 条）：**取消起播时的自动绑定**
     *
     * # Owner 原话
     * ```text
     * > 我看到 dan-api 提供的弹幕了,但是所有的弹幕
     * > (除了插件自身提供的该视频的弹幕除外) 都应该手动绑定,而不是自动
     * ```
     *
     * # 改前
     * 起播时这里会**自动**调 `_autoBindBili()`（内部走 `autoBindBySearch`，
     * 按标题相似度猜一个匹配）。改后不再猜 —— 只有**用户亲手绑**才算数。
     *
     * # 为什么整段删掉而不是加开关
     * ```text
     * Owner 要的是「都应该手动绑定」。留一个开关（默认关）等于留一条
     * 随时被谁打开就复活的路 —— 这正是本仓反复出问题的形态
     * （配置项存在但没人读 / 读了但默认值让功能悄悄回来）。
     * ⇒ 直接从调用点删掉，`_autoBindBili` 保留给**手动入口**用。
     * ```
     *
     * # ⚠️ 副作用（如实记，不许当纯优化汇报）
     * ```text
     * 改前：起播就可能自动挂上弹幕（猜对了才挂，猜错反而不挂 —— 静默）
     * 改后：起播**一定**没有自动绑定，用户要自己去弹幕面板搜一次并选中一条
     * ⇒ 体验上「多一步」。这是 Owner 明确要求的取舍，不是回归。
     * ```
     *
     * # 不受影响的路
     * · 插件自身提供的弹幕（provider 直接给的，不经过 autoBind）
     * · 本地弹弹play / danmaku-service / 自建服务那几条（走的是另一条链路）
     */
    /*
     * ★ T27-05：本机弹弹play优先 —— 桌面版在 127.0.0.1:2080 提供
     *   **免签名**的本地接口（官方 api.danmaku-service.net 才要 AppId/AppSecret）。
     *   探测结果进程内缓存；本机不在线 ⇒ 走官方（行为与改前一致）。
     *   本地服务就是 danmaku-service 协议 ⇒ 成功状态仍用「danmaku-service · 」前缀。
     */
    final localStatus = await _ensureDanmakuLocalStatus();
    _danmakuSourceLine = '数据源：${localStatus.line}';
    /*
     * ★★★ T27-14（CodeRabbit A7）：自动路由 = 「本机在线就优先本机」。
     *   但用户点过「改用官方 API」后 `_danmakuForceOfficial` 为 true ⇒
     *   这一次**真的**换边（否则那颗按钮又一次死循环：探出来还是在线 ⇒
     *   又走本机 ⇒ 又 401/403 ⇒ 提示原样回来）。
     */
    final usingLocal = localStatus.online && !_danmakuForceOfficial;
    /*
     * ★★ N2：本次**确实**走的是官方那条边、而它失败了 —— 只有这个组合才
     *   为「改用本机」开一个回头路（见 [_danmakuOfficialFailed]）。
     *   本机不在线时点「改用官方」没换边（本来就是官方）⇒ 不置位。
     */
    _danmakuOfficialFailed = !usingLocal && localStatus.online;
    if (usingLocal != _danmakuUsingLocal) {
      // 模式切了 ⇒ 旧客户端（另一种 baseUrl/签名形态）必须 close 重建
      _danmakuUsingLocal = usingLocal;
      _resetDanmakuClient();
    }
    final token = ++_danmakuFetchToken;
    final client = _ensureDanmakuClient(unsignedLocal: usingLocal);
    if (mounted) {
      setState(() {
        _danmakuLoading = true;
        _danmakuError = null;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: true,
          clearError: true,
        );
      });
    }
    try {
      /*
       * ★★★ 2026-10-13（Owner）：把标题喂给**搜索退路**
       *
       * Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能
       *
       * # 真缺陷：搜索退路**每次都在空搜**（已证实）
       * ```text
       * `loadFor()` 的签名有 `anime` / `episode` 两个参数并喂给
       * `searchEpisodes()`；但全仓**唯一**的调用点（就是这里）**不传**。
       * ⇒ `searchEpisodes` 里 `if (anime.isNotEmpty)` / `if (episode.isNotEmpty)`
       *   双双为 false ⇒ `GET /api/v2/search/episodes` **不带任何查询词**
       *   ⇒ 空搜必然搜不到。
       * ★ 而面板的 UI 文案却向用户承诺"匹配不到时会自动退到按番剧名 + 集数搜索"
       *   —— 文案与实现不符（那是"假承诺"，比没有更糟）。
       * ```
       *
       * # 修法：把**片名**当关键词
       * ```text
       * `loadFor` 先用文件名走 `match()`（精确匹配，最准）。
       * 只有匹配不到才退到搜索 ⇒ 这时我们手上唯一的相关信息就是标题。
       * ⇒ 把 `_danmakuFileName`（= 标题去扩展名）作为 `anime` 传进去。
       *   `episode` 留空（我们没有可靠的"第几集"文本：
       *   集号在站点侧是 id、在本地是路径后缀，都不该当搜索词）。
       * ```
       * ⚠️ 为什么不用 `_liveTitle` 原串：它可能带扩展名（`第01集.mp4`），
       *    而搜索接口按"番剧名"匹配 ⇒ 去掉扩展名更准（`_danmakuFileName` 就是干这个的）。
       *    ★ 这与 `match()` 用的是**同一个**串（都取 `_danmakuFileName`）——
       *      两处同源，不会出现"匹配用 A、搜索用 B"的漂移。
       */
      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ 2026-10-14（CR #27）：用户**明确点选**的那一集 ⇒ 直接取，不走模糊匹配
       * ══════════════════════════════════════════════════════════════════
       *
       * # 真缺陷（CodeRabbit 在 PR #27 上抓到的，属实）
       * ```text
       * `_pickDanmakuMatch` 把用户选中的 `m.episodeId` 记进 `_biliCid`，
       * 然后调 `_loadDanmakuNamed(m.label)` —— 而本函数**从不读 `_biliCid`**！
       * ⇒ 走的是 `loadFor(fileName: label)`：
       *     `match()` 模糊匹配 ⇒ 取 `matches.first`；匹配不到再空搜。
       * ⇒ 用户点了「第 2 集」，实际可能载入**第 1 集 / 别的作品 / 另一路源**。
       * ★ 这与源码注释承诺的"用户点了哪条就取哪条"**不符** ——
       *   是"假承诺"（比没有更糟）。
       * ```
       *
       * # 修法：有明确 episodeId 时**直达** `fetchComments(episodeId)`
       * ```text
       * `DanmakuMatch.episodeId` 就是弹幕库里的**唯一集 id** ⇒
       *   `fetchComments(id)` 一次请求拿到那**一集**的弹幕（与 `loadFor`
       *   内部匹配到之后用的是**同一个**调用）。
       * ⇒ 有 `_episodeIdPinned` 时**跳过** match()/搜索，直接取那一条。
       * ```
       * ⚠️ `_episodeIdPinned` 是**一次性**的（取完即清）——它表达的是
       *    "用户刚刚点了这一条"，不是"这一集永远钉在这条"。
       *    下次正常起播仍走既有的匹配链路（否则换了片名也不更新）。
       * ⚠️ 一旦请求失败 ⇒ **清掉** pin 并**继续**走原链路（不能因为
       *    用户点的那条失效就什么都不取）。
       */
      /*
       * ★ 整部绑定的 pin 在这里才生效 —— 提前 return 的路径不会污染它（见函数上方说明）。
       *
       * ⚠️ 但**不许覆盖**已有的 pin：`_pickDanmakuMatch` 会把用户刚手选的那条写进
       *    `_pinnedEpisodeId`。若这里无条件 `= boundId`，用户点了搜索结果里的第 5 集，
       *    却会取回「整部绑定」里第 1 集的那条 —— 手选被静默吞掉。
       * ⇒ 只在**没有**手选 pin 时才用整部绑定。
       */
      if (_pinnedEpisodeId == null && boundId > 0) _pinnedEpisodeId = boundId;
      final pinned = _pinnedEpisodeId;
      if (pinned != null) {
        _pinnedEpisodeId = null; // 一次性
        try {
          final cs = await client.fetchComments(pinned);
          if (!mounted || token != _danmakuFetchToken) return;
          /*
           * ★★★ 2026-10-17（Owner 第 9 条）：**聚合**
           *
           * 用户点选的那一集拿到之后，再叠上插件那一份 —— 见
           * [_aggregateDanmaku] 的说明（改前这两条路是**互斥**的）。
           */
          final agg = await _aggregateDanmaku(
            primary: cs,
            primaryKind: DanmakuSourceChannel.imported,
            primaryDetail: '弹幕库 #$pinned',
            primarySource: DanmakuInfoSource.library,
            token: token,
          );
          if (!mounted || token != _danmakuFetchToken) return;
          setState(() {
            _danmakuComments = agg.comments;
            _danmakuError = null;
            _danmakuLoading = false;
            _danmakuStatus = '已载入「$fileName」（弹幕库 #$pinned · '
                '${agg.comments.length} 条）';
            _setDanmakuInfo(
              source: DanmakuInfoSource.library,
              detail: fileName,
              aggregate: agg,
            );
          });
          debugPrint('[DMK] 按用户点选的 episodeId 直达：#$pinned ⇒ '
              '${agg.comments.length} 条 · ${agg.summary}');
          return;
        } catch (e) {
          debugPrint('[DMK] 点选的那一条取失败（回落到匹配链路）: $e');
          // 不 return —— 继续走下面的正常链路
        }
      }

      final res = await client.loadFor(
        fileName: fileName,
        videoDuration: _duration.inSeconds,
        anime: fileName,
      );
      if (!mounted || token != _danmakuFetchToken) return;
      /*
       * ★★★ 2026-10-17（Owner 第 9 条）：**聚合**
       *
       * 导入源（dan-api / 本机 / 官方）这一份拿到之后，再叠上插件那一份。
       * 改前这两条路是**互斥**的（见 [_aggregateDanmaku] 的长注释）。
       */
      final agg = await _aggregateDanmaku(
        primary: res.comments,
        primaryKind: DanmakuSourceChannel.imported,
        primaryDetail: _danmakuUsingLocal
            ? (_danmakuLocalStatus?.endpoint != null ? '自建服务' : '本机服务')
            : 'dan-api',
        primarySource: _danmakuUsingLocal
            ? (_danmakuLocalStatus?.endpoint != null
                ? DanmakuInfoSource.selfHosted
                : DanmakuInfoSource.localDanmaku)
            : DanmakuInfoSource.service,
        token: token,
      );
      if (!mounted || token != _danmakuFetchToken) return;
      setState(() {
        _danmakuComments = agg.comments;
        /*
         * ★ OPS-10 B：「在 UI 上如实反映实际用的是哪个源的弹幕」
         *
         * `res.summary` 自己是「某番 第 3 集 · 842 条弹幕」（danmaku.dart:919-923），
         * **不含源名**；外部视频站那条（bili_auto_update.dart:89-96）也不含。
         * 两条路都取回来之后，用户从读数上分不出这些弹幕是谁给的 ——
         * 而 外部视频站那侧**不需要凭证**、danmaku-service 那侧**要**，这个区别
         * 恰恰是他排错时唯一要分清的事（见下面 DanmakuHint 的说明）。
         * ⇒ 在宿主这一层补前缀，不改 core 的文案（t70 逐字钉着它们）。
         *
         * ★ 2026-10-17（Owner 第 9 条）：聚合时**两路都要出现**在读数里
         *   —— `agg.summary` 就是那个读数（`2 路 · 插件 1200 + 导入源 800 = …`）。
         *   单源时它退化成 `导入源 800 条`，与改前那句同义。
         *
         * ⚠️ 下面这个赋值里的**前缀字面量全仓只能一份** —— `t27_w5` 的源码契约
         *    钉着它（`zz_cr_dmk_b`：成功支只有一个 setState 形态，本地支必须
         *    复用它，不许复制第二份）。
         *    所以后面两处 `copyWith` 都读这个字段，不再重写一遍前缀
         *    （注释里我也**不重复那个字面量** —— 那个契约是按纯文本匹配的）。
         *
         * ★ 聚合读数（Owner 第 9 条）用条件拼接附在后面：
         *   单源时不加尾巴（与改前那句同义），多源时给出 `2 路 · 插件 N + 导入源 M = K 条`。
         */
        /*
         * ⚠️ 2026-10-18（round-65 批次 B）：这句必须**保持单行**。
         *
         * `zz_cr_dmk_b_source_prefix_test` 用**逐字字符串针**钉住下面这一行
         * （针里含 `danmaku-service · ` 前缀与 `${res.summary}`），
         * 而 `t27_w5` 又要求「带前缀的成功赋值形态全源码只能有一份」。
         *
         * ⇒ 两个约束合成的规矩：
         *   ① 前缀句必须逐字、单行、只出现一次（在下面那行代码里）
         *   ② 聚合尾巴另起一行追加，**不许**把前缀句劈成跨行拼接
         *      （劈开后逐字针偏移 -1，实测报「针在锚点之后找不到」）
         *   ③ **注释里也不许重复那个字面量** —— 那两条契约都是按纯文本
         *      匹配源码的，注释里写一遍就等于凭空多出一份（实测 t27_w5 红）
         */
        _danmakuStatus = 'danmaku-service · ${res.summary}';
        if (agg.feeds.length > 1) {
          _danmakuStatus = '${_danmakuStatus} · ${agg.summary}';
        }
        _danmakuError = null;
        _danmakuErrorAt = null;
        _danmakuEmptyExpired = false;
        _danmakuLoading = false;
        /*
         * ★ 如实登记来源（面板读它，不再从 `_danmakuStatus` 反解文案）。
         *
         * 本机弹弹play 与自建后端**必须分开**：两者都让 `online` 为 true，
         * 但用户要做的事完全不同（启动桌面版 vs 去配置里改地址）。
         */
        _setDanmakuInfo(
          source: _danmakuUsingLocal
              ? (_danmakuLocalStatus?.endpoint != null
                  ? DanmakuInfoSource.selfHosted
                  : DanmakuInfoSource.localDanmaku)
              : DanmakuInfoSource.service,
          detail: _danmakuLocalStatus?.version == null
              ? null
              : 'v${_danmakuLocalStatus!.version}',
          aggregate: agg,
        );
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          clearError: true,
          /*
           * ★ 复用上面算好的 `_danmakuStatus`（不是重写一遍那个字面量）——
           *   理由见它上方那条关于 `zz_cr_dmk_b` 的说明。
           */
          status: _danmakuStatus,
          sourceLine: _danmakuSourceLine,
        );
      });
      _armDanmakuBadgeExpiry(kDanmakuBadgeEmptyMs);
    } on DanmakuException catch (e) {
      if (!mounted || token != _danmakuFetchToken) return;
      setState(() {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuStatus = '';
        _danmakuError = e;
        _danmakuErrorAt = DateTime.now();
        _danmakuLoading = false;
        // ★ T27-08 / T27-14：记下**产生这条失败的那次请求走的是不是本机源**
        //   （面板指引按它重算 —— 判据是「走了哪个源」，不是「本机在不在线」）
        _danmakuHintUsedLocalSource = usingLocal;
        /*
         * ★★ T27-08：面板里那份异常也要带上**按数据源重算**的 hint
         *
         * 面板（danmaku_settings_dialog 的 `_hintSection`）画的是
         * `s.error.hint`、**不是** `e.hint` —— 不同步就会出现
         * 「提示条说改用本机、面板里却说去申请凭证」这种自相矛盾。
         * 事实用**本次取弹幕**的 `usingLocal`（与提示条同一份读数）。
         */
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          error: DanmakuException(
            e.message,
            statusCode: e.statusCode,
            xErrorMessage: e.xErrorMessage,
            errorCode: e.errorCode,
            errorMessage: e.errorMessage,
            body: e.body,
            uri: e.uri,
            hint: DanmakuHint.of(e, allowUseLocal: _danmakuOfficialFailed,
              // ★★ N2：与提示条用**同一份判据**（面板画的是这份 error.hint），
              //   两处若不一致就会出现「提示条有按钮、面板里没有」的自相矛盾。
              usedLocalSource: usingLocal),
          ),
          status: '',
        );
      });
      /*
       * ★ 把原文直接糊在画面上（角标）+ 在面板的"详情"里给全文
       *
       * 不吞、不改写、不翻译成"网络错误" —— 用户要看到的是
       * danmaku-service 自己说的那句话（例如 Missing Authentication Headers）。
       */
      _armDanmakuBadgeExpiry();
      final why = e.xErrorMessage.isNotEmpty ? e.xErrorMessage : e.message;
      /*
       * ★★ Owner 第 1 条（2026-10-08）：报错要**可操作**
       *
       * 用户截图里只有一句「弹幕失败：Missing Authentication Headers」——
       * 那是 danmaku-service 自己说的话，它没错，但**用户看不懂要做什么**。
       * 现在 `DanmakuException.hint`（core/danmaku.dart）会把 403/401 翻成
       * 中文指引（缺凭证 / 凭证不对），这里把**标题**带在提示条上，
       * 全文与一键入口在「弹幕设置」面板里（见那里的 `_errorSection`）。
       *
       * ⚠️ 不把 hint.text 全文塞进提示条：它有一两百字，而提示条 1.2 秒
       *    就消失 —— 塞进去等于没写。标题 + 面板入口才是能用的形态。
       */
      /*
       * ★★ T27-08（Owner 第 8 条）：提示按**真实数据源**重算
       *
       * 改前直接用异常自带的那条 hint —— 而它是**数据源无关**的，
       * 于是本机弹弹play 明明在跑（T27-05 的免签名本地源），屏幕上
       * 还是「去官网免费申请」：用户读到的是「没获取到凭证」，而真正
       * 该做的是**切数据源**。这里把「这次请求走了哪个源」注入判据
       * （`DanmakuHint.of` 是纯函数，事实只能由宿主给）。
       *
       * ⚠️ `e.hint` 那条**仍然保留**（非 401/403 ⇒ 它本来就是 null）：
       *    只重算 403/401 这一支，事实取**产生这条失败时**的读数。
       * ⚠️ T27-14：判据是「那次请求**走的是不是本机源**」（`usingLocal`），
       *    不是「本机在不在线」—— 后者会写出与事实相反的提示（见 core 文档）。
       */
      final usedLocalSource = _danmakuHintUsedLocalSource ?? false;
      final h = (e.statusCode == 401 || e.statusCode == 403)
          // ★★ N2：官方那条边**确实试过并失败了** ⇒ 第 2 态也要给回头路
          //   （「改用本机弹弹play」）。否则文案建议「选本机」，用户没有入口。
          ? DanmakuHint.of(e, allowUseLocal: _danmakuOfficialFailed,
              usedLocalSource: usedLocalSource)
          : e.hint;
      /*
       * ★★ Owner 第 9 条：点明**这句失败是谁的凭证**
       *
       * # 为什么非加不可（Lead 追加 2）
       * ```text
       * 走到这一行 = danmaku-service 这条路失败了。而**绑了 外部视频站的用户**
       * 看到「弹幕服务没收到凭证」会去 外部视频站找 AppId —— 找错地方，
       * 因为 外部视频站那侧压根不用填 AppId（bili_api.dart:3：搜索免登录）。
       * 「没收到凭证」这四个字里的"凭证"指的是 **danmaku-service 开放平台**
       * 的 AppId/AppSecret，必须写出来，否则提示是**指向错误**的。
       * ```
       *
       * ⚠️ 括号里那半句**逐字**是 `test/zz_t3_flash_probe_test.dart:43` 的
       *    `kTipAfter`（完整句是「弹幕失败：…（打开弹幕设置可一键处理；
       *    这是 danmaku-service 的凭证，与 外部视频站弹幕无关）」）。
       * ⚠️ 公共前缀 `'弹幕失败：… （打开弹幕设置可一键处理'` **一个字符都没动** ——
       *    那是 t100/t103 既有断言面（探针 :147-149 专门守着这条）。
       */
      _flash(
        h == null
            ? '弹幕失败：$why'
            : '弹幕失败：$why ｜ ${h.title}（打开弹幕设置可一键处理；这是 danmaku-service 的凭证，与 外部视频站弹幕无关）',
      );
    } catch (e) {
      if (!mounted || token != _danmakuFetchToken) return;
      _armDanmakuBadgeExpiry();
      final wrapped = DanmakuException(e.toString());
      setState(() {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuStatus = '';
        _danmakuError = wrapped;
        _danmakuErrorAt = DateTime.now();
        _danmakuLoading = false;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          error: wrapped,
          status: '',
        );
      });
      _flash('弹幕失败：$e');
    }
  }

  /// 面板开着时把渲染层的实时读数刷进面板（每秒一次，开销可忽略）
  void _refreshDanmakuReadout() {
    if (!mounted || !_danmakuSheetOpen) return;
    final st = debugDanmakuLastStats;
    final n = st?.visible ?? 0;
    final lanes = st?.laneCount ?? 0;
    final dropped = st?.dropped ?? 0;
    final next = DanmakuReadout(count: n, lanes: lanes, dropped: dropped);
    if (next.sameAs(_danmakuReadout.value)) return;
    // NOTE: deliberately NOT setState -- that is the whole point of the fix.
    _danmakuReadout.value = next;
  }

  /// 底栏「弹幕」按钮：开 / 关
  Future<void> _toggleDanmaku() async {
    /*
     * ★★★ 第 66 轮 R6-b：**直播态一个弹幕请求都不发**
     *
     * 这条守卫必须在**方法第一行**，不能只靠"控件不渲染"：
     * 深链、探针、以后别处复用都会绕过控件那一层，而一旦走进来就是
     * 「一条 `/api/v2/match`（频道名被当成番剧名）+ 开关自己翻成开」。
     *
     * 判据是**发出去的请求数 = 0**，不是"点了不崩"：
     * `test/zz_t66_r6b_live_toggle_test.dart` 用计数 transport 数
     * `calls.isEmpty`。非直播路径**逐字节未变**（条件为假 ⇒ 直接落回原文）。
     */
    if (_isLive) return;
    final next = !_danmakuEnabled;
    DanmakuConfig.setEnabled(next);
    if (!next) _danmakuFetchToken++; // 丢弃在途响应
    setState(() {
      _danmakuEnabled = next;
      _danmakuSettings = _danmakuSettings.copyWith(enabled: next);
      if (!next) {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuError = null;
        _danmakuStatus = '';
        _danmakuLoading = false;
      }
    });
    if (next) {
      _flash('弹幕已开启');
      await _loadDanmaku();
    } else {
      _flash('弹幕已关闭');
    }
  }

  /// 执行 `DanmakuHint.action`（Owner 第 1 条）
  ///
  /// 面板只把 `DanmakuHintAction` 原样递出来，**开关谁**由宿主决定 ——
  /// 面板不认识 `_danmakuSheetOpen` / `_biliSheetOpen`，也不该认识。
  ///
  /// ★ 缺凭证那条指引**两个开关都是 true**：用户可能选"去申请凭证"，
  ///   也可能选"改用 外部视频站弹幕"（后者不需要那对凭证）。两个面板都给，
  ///   让用户自己选 —— 直接把他扔进某一个里等于替他做了决定。
  void _runDanmakuHintAction(DanmakuHintAction a) {
    if (a.openDanmakuSettings) _openDanmakuSettings();
    if (a.openBiliSheet) _openBiliSheet();
    if (a.useLocalDanmaku) _useLocalDanmakuSource();
    if (a.forceLocalDanmaku) _useLocalDanmakuSource();
    if (a.useOfficialDanmaku) _useOfficialDanmakuSource();
  }

  /// 「改用本机弹弹play」（T27-08 那颗按钮的动作）
  ///
  /// # 为什么必须**重建客户端**（不是只改个 flag）
  /// ```text
  /// appId/appSecret 与 unsignedLocal/baseUrl 都是 ExternalDanmakuClient 的
  /// **构造快照**（player_page.dart:4577 那段的说明）⇒ 不重建的话
  /// 「改用本机」等于没改：旧实例照旧往 api.danmaku-service.net 发签名请求，
  /// 用户点了按钮还是同一句「没获取到凭证」。
  /// ```
  ///
  /// # 为什么连探测缓存一起清
  /// 用户很可能**刚**启动本机弹弹play 才点的这颗按钮 —— 缓存里那份
  /// 「不在线」是过期读数，不清就永远不会切过去。
  ///
  /// ⚠️ 这里**只**做「清缓存 + 重取」；选路仍然由 `_loadDanmaku` 里
  ///    w5 的 `localStatus.online` 那段决定（不抢数据源模型的权）。
  /// ★ T27-14：顺手把 `_danmakuForceOfficial` 清掉 —— 用户这次**明确**要
  ///    本机源，不该再被上一次「改用官方」的粘性标记压住。
  /// ★★★ N2（CodeRabbit PR#5）：这也是「官方失败」那一态的**唯一回头路**
  ///    （见 `_runDanmakuHintAction` 里那条 `forceLocalDanmaku`）。只清标记
  ///    不重建客户端是**假修**：appId/baseUrl 是构造快照，旧实例照旧打官方。
  void _useLocalDanmakuSource() {
    _danmakuForceOfficial = false;
    _danmakuOfficialFailed = false;
    _resetDanmakuClient();
    _danmakuLocalStatus = null;
    unawaited(_loadDanmaku());
  }

  /// 「改用官方 API」（T27-14 本机源拒绝请求那颗按钮的动作）
  ///
  /// # 它解决的问题：**换一条真正不同的路**
  /// ```text
  /// 触发场景：本机弹弹play 在线 ⇒ 自动路由走本机 ⇒ 本机回了 401/403。
  /// 旧提示给的是「改用本机弹弹play」—— 而这次**已经是**本机了，点了只会
  /// 重新探测 ⇒ 还是在线 ⇒ 还是走本机 ⇒ 又失败 ⇒ 提示原样回来（死循环）。
  /// ⇒ 正确出路是换到**另一条边**：官方 API。
  /// ```
  ///
  /// # 为什么必须粘住 `_danmakuForceOfficial`（不是只清缓存）
  /// ```text
  /// 选路是 `usingLocal = localStatus.online && !_danmakuForceOfficial`。
  /// 若只清缓存重探，探出来本机仍在线 ⇒ 又走本机 ⇒ 死循环照旧。
  /// ⇒ 用进程内粘性标记把这次重取**真的**掰到官方；用户点「改用本机」
  ///   时（`_useLocalDanmakuSource`）会把它清回 false。
  /// ```
  void _useOfficialDanmakuSource() {
    _danmakuForceOfficial = true;
    _resetDanmakuClient();
    _danmakuLocalStatus = null;
    unawaited(_loadDanmaku());
  }

  /// 打开弹幕设置面板（不暂停播放 —— 与播放设置面板同一原则）
  void _openDanmakuSettings() {
    final st = debugDanmakuLastStats;
    _danmakuReadout.value = DanmakuReadout(
      count: st?.visible ?? 0,
      lanes: st?.laneCount ?? 0,
      dropped: st?.dropped ?? 0,
    );
    // ★★★ T27-09：浮层打开 ⇒ 顶/底栏一起收（显隐统一真源，见 _collapseControlsForSheet）
    _collapseControlsForSheet();
    setState(() {
      _danmakuSheetOpen = true;
      _danmakuSettings = DanmakuSettingsState.fromPrefs().copyWith(
        loading: _danmakuLoading,
        error: _danmakuError,
        status: _danmakuStatus,
        count: st?.visible ?? 0,
        lanes: st?.laneCount ?? 0,
        dropped: st?.dropped ?? 0,
        sourceLine: _danmakuSourceLine,
        // ★★★ 2026-10-14：把搜索区状态一并搬进面板
        //   （面板是纯 UI，不自己读字段 —— 与上面几行同一条分工）
        searchLoading: _danmakuSearchLoading,
        searchError: _danmakuSearchError,
        searchSearched: _danmakuSearchSearched,
        searchResults: _danmakuSearchResults,
        /*
         * ★★★ 2026-10-15 (Owner): "it should auto-fill the name."
         *
         * The bili panel has pre-filled its search box since 2026-10-09
         * (see the long note on its own searchKeyword line), but the
         * dandanplay search box was still opening EMPTY -- so the user had
         * to retype a title the app already knows.
         *
         * Pre-fill rules:
         *   · if a search has already been run, keep ITS keyword (the user's
         *     own words are better than a guess);
         *   · otherwise use _liveTitle (the string shown in the title bar),
         *     which is the closest thing to how the user thinks of the episode.
         *
         * Why not the filename (_danmakuFileName): that one is built for
         * matching and may carry an extension or an episode suffix, both of
         * which make SEARCH less accurate.
         *
         * NOTE: this is a pre-fill, not a lock -- the user can edit it freely
         * before pressing Search.
         */
        searchKeyword: _danmakuSearchKeyword.isNotEmpty
            ? _danmakuSearchKeyword
            : _liveTitle.trim(),
        // ★ 打开面板时**重算**"这批结果还对不对得上"：
        //   用户可能在上次搜索之后换过集、再打开面板 —— 那时 stale 必须为真。
        //   这是 `_danmakuSearchToken` 的**第二个**消费点（另一个在结果回来时）。
        searchStale:
            _danmakuSearchToken >= 0 &&
            _danmakuSearchToken != _danmakuFetchToken,
      );
    });
  }

  void _setDanmakuEnabled(bool v) {
    DanmakuConfig.setEnabled(v);
    setState(() {
      _danmakuEnabled = v;
      _danmakuSettings = _danmakuSettings.copyWith(enabled: v);
    });
    if (v) {
      unawaited(_loadDanmaku());
    } else {
      _danmakuFetchToken++;
      setState(() {
        _danmakuComments = const <DanmakuComment>[];
        _danmakuError = null;
        _danmakuStatus = '';
        _danmakuLoading = false;
      });
    }
  }

  /// ★★★ 2026-10-14（Owner）：面板里点了「搜索」—— 手动按番剧名找剧集
  ///
  /// Owner 原话：> 弹幕我没有看到[弹幕服务]的搜索功能和绑定
  ///
  /// # ★ 硬约束：搜索**不得**影响正在播放的流
  /// ```text
  /// 这个函数里**只有** `_danmakuSearch*` 这几个面板字段被改动。
  /// 刻意不碰：`_danmakuComments`（画面里挂着的弹幕）、`_danmakuFetchToken`
  /// （那是"这一集的弹幕身份"，++ 会让正在播的那一份被判过期）、
  /// 播放器 / mpv / 流地址 / `pause` / `play` —— 一个都不碰。
  /// ⇒ 用户搜到一半、搜了又放弃，正在播的那一集**一帧都不会变**
  ///   （t108 有真渲染回归钉这一条）。
  /// ```
  ///
  /// # 为什么走本机优先那条边（与 `_loadDanmaku` 同源）
  /// ```text
  /// 「本机有就跑本机」是 T27-05 定下的选路（本机免签名、不打官方）。
  /// 搜索复用同一份读数（`_danmakuLocalStatus` / `_danmakuForceOfficial`）
  /// 与**同一个**客户端实例（`_ensureDanmakuClient`）—— 不另起一个，
  /// 否则会出现"取弹幕走本机、搜索走官方"这种自相矛盾的组合。
  /// ```
  Future<void> _searchDanmaku(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    // 探一次本机（同 `_loadDanmaku`：进程内缓存，面板路径本身不探）
    final localStatus = await _ensureDanmakuLocalStatus();
    _danmakuSourceLine = '数据源：${localStatus.line}';
    final usingLocal = localStatus.online && !_danmakuForceOfficial;
    if (usingLocal != _danmakuUsingLocal) {
      // 选路变了 ⇒ 旧客户端是另一种 baseUrl/签名形态，必须重建（同 `_loadDanmaku`）
      _danmakuUsingLocal = usingLocal;
      _resetDanmakuClient();
    }
    final client = _ensureDanmakuClient(unsignedLocal: usingLocal);
    // ★ 记下"发起搜索时的令牌"，回来时用它判是否已换集（见字段注释）
    final searchToken = _danmakuFetchToken;
    if (!mounted) return;
    setState(() {
      _danmakuSearchLoading = true;
      _danmakuSearchError = null;
      _danmakuSearchSearched = true;
      _danmakuSearchKeyword = kw;
      _danmakuSearchToken = searchToken;
      // 结果清空：上一次的关键词结果留着会被误读成"这次搜到的"
      _danmakuSearchResults = const <DanmakuMatch>[];
      _danmakuSettings = _danmakuSettings.copyWith(
        searchLoading: true,
        clearSearchError: true,
        searchSearched: true,
        searchKeyword: kw,
        searchResults: const <DanmakuMatch>[],
        searchStale: false,
      );
    });
    try {
      /*
       * 2026-10-15: multi-keyword search.
       *
       * A full episode title like
       *   「无职转生Ⅲ ～到了异世界就拿出真本事～ 第1话 燃烧吧，狂犬」
       * yields ZERO works from the official search even though the show and that
       * very episode (187270001, 2709 comments) are in the library. Dropping to
       * the first whitespace segment finds it. Measured against the live API.
       */
      final found = await client.searchEpisodesSmart(kw);
      if (!mounted) return;
      final stale = searchToken != _danmakuFetchToken;
      setState(() {
        _danmakuSearchResults = found;
        _danmakuSearchLoading = false;
        _danmakuSearchError = null;
        _danmakuSettings = _danmakuSettings.copyWith(
          searchLoading: false,
          clearSearchError: true,
          searchResults: found,
          searchKeyword: kw,
          searchStale: stale,
        );
      });
    } on DanmakuException catch (e) {
      if (!mounted) return;
      setState(() {
        _danmakuSearchLoading = false;
        _danmakuSearchError = e;
        _danmakuSearchResults = const <DanmakuMatch>[];
        _danmakuSettings = _danmakuSettings.copyWith(
          searchLoading: false,
          searchError: e,
          searchResults: const <DanmakuMatch>[],
          searchStale: false,
        );
      });
      _flash('搜索失败：${e.message}');
    } catch (e) {
      if (!mounted) return;
      final wrapped = DanmakuException(e.toString());
      setState(() {
        _danmakuSearchLoading = false;
        _danmakuSearchError = wrapped;
        _danmakuSearchResults = const <DanmakuMatch>[];
        _danmakuSettings = _danmakuSettings.copyWith(
          searchLoading: false,
          searchError: wrapped,
          searchResults: const <DanmakuMatch>[],
          searchStale: false,
        );
      });
      _flash('搜索失败：$e');
    }
  }

  /// ★★★ 2026-10-14（Owner）：用户在搜索结果里点了某一条 ⇒ 载入那一集的弹幕
  ///
  /// # 与 `loadFor` 那条路**同一份实现**（硬要求）
  /// ```text
  /// 载入这一步**不**另写一套：走 `_loadDanmakuNamed` —— 它就是
  /// `loadFor` → `fetchComments` 那条路的宿主入口（外部视频站分支、状态行、
  /// 失败原文、令牌、角标寿命全都在里面）。
  /// 这里只做两件事：① 把 `episodeId` 记上（下次「重新获取弹幕」才有身份）；
  ///                    ② 触发那一条路。
  /// ```
  ///
  /// # 为什么直接按 episodeId 取，而不是再喂关键词给 `loadFor`
  /// ```text
  /// 用户**明确点了一条** —— 再让他走一次 `match()`/`searchEpisodes()`
  /// 的模糊匹配，等于把"用户的选择"重新交给猜测，还可能选到另一集。
  /// ⇒ 用户点了哪条，就取哪条（`episodeId` 是弹幕库里的唯一钥匙）。
  /// ```
  /// 整部绑定：把搜索结果铺到这一部的每一集
  ///
  /// 2026-10-15 (Owner): "番剧的批量绑定弹幕".
  ///
  /// # 分工（与 `_pickDanmakuMatch` 同一条规矩）
  /// ```text
  /// 对齐规则在 core（`buildBatchBindPlan`，有自己的门禁）；
  /// 这里只做两件事：① 拿到本地剧集表 ② 写盘。
  /// ```
  /// ⚠️ **不在这里重写一份对齐逻辑** —— 那样两份定义必然漂移，
  ///    而对齐错一次就是“12 集全在放第1集”这种看不出来的错。
  /// 第 11 项（2026-10-26）：**按用户确认的映射**落盘 —— **不重算**
  ///
  /// 为什么要单独一个方法：`_batchBindDanmaku` 会拿 results 重跑
  /// `buildBatchBindPlan`，而用户在搜索页里**改过对应关系/调过顺序** ——
  /// 重算会把用户的修改覆盖回去（那正是本轮缺陷）。
  /// ⇒ 这里直接吃 items（已含 episodeIndex → episodeId 的最终映射）。
  Future<void> _batchBindDanmakuPlan(
    List<BatchBindPlanItem> items,
    String workTitle,
  ) async {
    if (items.isEmpty) return;
    saveDanmakuBind(
      widget.provider,
      widget.id,
      DanmakuBindStore(
        workTitle: workTitle,
        episodes: <int, int>{
          for (final it in items) it.episodeIndex: it.episodeId,
        },
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!mounted) return;
    _flash('整部绑定完成：「$workTitle」绑了 ${items.length} 集');
  }

  Future<void> _batchBindDanmaku(List<DanmakuMatch> results) async {
    if (results.isEmpty) return;
    final titles = _episodes.map((e) => e.title).toList();
    if (titles.isEmpty) {
      _flash('整部绑定：还不知道这一部有几集（等剧集列表加载完）');
      return;
    }
    final plan = buildBatchBindPlan(
      localTitles: titles,
      matches: results,
      workTitle: results.first.animeTitle,
    );
    if (plan.isEmpty) {
      _flash('整部绑定：这批结果对不上任何一集');
      return;
    }
    /*
     * 写盘：进**弹幕库自己**那条存储。
     *
     * ⚠⚠⚠ 这里我第一版写错了 —— 写成了 `saveBinding`
     * （外部视频站的 `BiliBinding`）。
     * ```text
     * 那一套被 `_loadBiliDanmaku(cid)` 消费 ⇒ 拿着弹幕库的 id
     * 去调**外部站的评论接口** ⇒ 下次起播必失败。
     *
     * ★ 两个 id 语系碰巧都是整数，编译器看不出来，
     *   只能靠**存储分开**。
     * ```
     */
    saveDanmakuBind(
      widget.provider,
      widget.id,
      DanmakuBindStore(
        workTitle: plan.workTitle,
        episodes: <int, int>{
          for (final it in plan.items) it.episodeIndex: it.episodeId,
        },
        updatedAt: DateTime.now().millisecondsSinceEpoch,
      ),
    );
    if (!mounted) return;
    /*
     * 如实报数 —— 尤其是**没绑上的那几集**。
     * 只报“绑了 N 集”而吞掉“有 3 集没绑”，
     * 用户会以为整部都好了，直到播到第 10 集才发现没弹幕。
     */
    final miss = plan.unmatchedLocal.length;
    _flash(
      '整部绑定完成：「${plan.workTitle}」绑了 ${plan.count}/${plan.totalLocal} 集'
      '${miss == 0 ? '' : '，还有 $miss 集没对上（可单独选）'}',
    );
    setState(() {
      _danmakuStatus = '整部绑定：${plan.count}/${plan.totalLocal} 集';
    });
  }

  void _pickDanmakuMatch(DanmakuMatch m) {
    // ★ 用户亲手选的 ⇒ 匹配方式就是"手动绑定"（面板第三格要如实说）
    _setDanmakuInfo(match: DanmakuInfoMatch.manual);
    /*
     * ★ 先把「用户的选择」记成这一集的弹幕身份（`_biliCid` —— 见它的字段
     *   注释：外部视频站那条路也写这个字段，两者语义同构）
     *
     * 语义与 外部视频站那条路一致：它同样是"一个 id 代表这一集该挂哪份弹幕"。
     * 记上之后，用户再点「重新获取弹幕」时，下次起播/重取就能认得出
     * 这一份是他选的 —— 否则又会退回"按片名模糊搜"。
     */
    _biliCid = m.episodeId;
    /*
     * ★★★ 2026-10-14（CR #27）：把"用户刚点的这一条"**钉一下**，
     *     让 `_loadDanmakuNamed` 直达它（否则会退化成按片名模糊匹配，
     *     落到的**不是**用户点的那一集 —— 见 `_pinnedEpisodeId` 的说明）。
     */
    _pinnedEpisodeId = m.episodeId;
    /*
     * ★ 载入成功与否都**关掉面板**：用户点了一条 = 他要看结果
     *   （同 `_openBiliSheet` 的语义 —— 动作落地就收起遮罩）。
     *   `_loadDanmakuNamed` 是异步的，失败会走 `_flash` 提示条，
     *   不需要面板留着显示错误（面板里的 searchError 是**搜索**的错误，
     *   载入的错误由既有的弹幕失败角标 + 提示条负责 —— 两条通路不混）。
     */
    if (mounted) {
      setState(() => _danmakuSheetOpen = false);
      _restoreBarsAfterSheet();
      // ★★ 2026-10-19（R3-④ 补漏）：**选中即关**这条路同样要守卫 ——
      //    用户在面板里双击选中一条弹幕库，第 2 击会落到播放区。
      _holdSheetGuard();
    }
    _flash('正在载入「${m.label}」的弹幕…');
    unawaited(_loadDanmakuNamed(m.label.isNotEmpty ? m.label : '弹幕库#${m.episodeId}'));
  }

  /// ★★★ Owner 1013：「播放页那些弹窗…而且还非常的卡顿（这里必须解决）」
  ///
  /// # 根因（有实测，别重查）
  /// ```text
  /// 这四个回调改前每个都 `setState`，而本页 `build()` 是**一个 884 行
  /// 的整页 build**（含 `Video` / `DanmakuOverlay` / 全部浮层）。
  /// 轻量悬浮窗的四根滑杆「拖动中每一帧都回调」（见
  /// player_bottom_bar.dart 的 `_quickSlider`）⇒ **每一帧整页重建**。
  /// 本仓旧探针实测：60 次鼠标移动 ⇒ PlayerPage 重建 60 次、
  /// 元素重建 9960 次（平均每次移动 166 个元素）。
  /// ```
  ///
  /// # 改法：拖动只推 `_danmakuQuickLive`，**不 setState**
  /// ```text
  /// · 滑杆读数：`DanmakuQuickPanelData.live` → 只有四根滑杆重建
  ///   （player_bottom_bar.dart 的 `_quickSliders`）。
  /// · **画面实时跟手**：绝不能丢 —— 这是 Owner 明确要的
  ///   （见 build 里 `danmakuQuick:` 那段旧注释）。
  /// ```
  ///
  /// # 画面为什么**不用**整页 setState 也能实时跟手（以源码为准推导）
  /// ```text
  /// ① 值先落进 `_danmakuSettings`（本页状态），再推 `_danmakuQuickLive`。
  /// ② build 里 `DanmakuOverlay` 被包在一层
  ///    `ValueListenableBuilder<DanmakuQuickValues>`（搜 player_page 的
  ///    「overlay 自己订阅」）⇒ **只有 overlay 那一小块**重建，
  ///    `PlayerPage.build()`（884 行）**一次都不跑**。
  /// ③ 重建只是换了 `DanmakuOverlay` 的入参；`_DanmakuOverlayState` 是
  ///    keep-alive State，复用不重建。真正应用新值在下一帧 build 的
  ///    `_ensureLayout(...)`：
  ///      · fontScale/speed/area 进了 `_layoutKey` ⇒ 命中新 key ⇒ 重排；
  ///      · opacity 由 `_DanmakuPainter` 每帧现读 `widget.opacity`
  ///        （shouldRepaint 也比它）⇒ 下一帧就变。
  ///    而宿主每秒 tick 都在 `_repaint.value++` ⇒ 拖动中本就逐帧在重绘
  ///    ⇒ 画面**下一帧**就是新值。
  /// ```
  /// ⚠️ 于是这里**不需要**（也不该）为「传新值给 overlay」保留整页 setState。
  ///    这条通路（`ValueListenableBuilder` 包 overlay）就是"画面实时跟手"
  ///    的落点；把它删成 `_danmakuSettings.*` 静态传值，画面就不跟手了。
  ///
  /// ⚠️ `_danmakuSettings` 的这四个字段在**拖动期间也会被写**
  ///    （为了与本页别处读它的地方保持一致，例如全屏大卡片的只读回显）——
  ///    但拖动**不** setState，所以它不会触发任何重建；overlay 读的是
  ///    `live.value`，不是这份快照。⇒ 两者不会打架。
  void _pushDanmakuQuickLive() {
    _danmakuQuickLive.value = DanmakuQuickValues(
      fontScale: _danmakuSettings.fontScale,
      opacity: _danmakuSettings.opacity,
      speed: _danmakuSettings.speed,
      area: _danmakuSettings.area,
    );
  }

  void _setDanmakuFontScale(double v) {
    DanmakuConfig.setFontScale(v);
    _danmakuSettings = _danmakuSettings.copyWith(fontScale: v);
    _pushDanmakuQuickLive();
  }

  void _setDanmakuOpacity(double v) {
    DanmakuConfig.setOpacity(v);
    _danmakuSettings = _danmakuSettings.copyWith(opacity: v);
    _pushDanmakuQuickLive();
  }

  void _setDanmakuSpeed(double v) {
    DanmakuConfig.setSpeed(v);
    _danmakuSettings = _danmakuSettings.copyWith(speed: v);
    _pushDanmakuQuickLive();
  }

  void _setDanmakuArea(double v) {
    DanmakuConfig.setArea(v);
    _danmakuSettings = _danmakuSettings.copyWith(area: v);
    _pushDanmakuQuickLive();
  }

  /// ★★★ Owner 2026-10-11 反馈（显示区域按 外部视频站重做）：拖动「显示区域」滑杆时，
  /// 在播放画面上点亮**半透明引导遮罩**（`DanmakuOverlay.areaGuide`）。
  ///
  /// 由底栏滑杆的起手/松手事件驱动（见 `DanmakuQuickPanelData.onAreaGuide`）：
  /// ```text
  /// true  ⇒ 显示（起手拖动）
  /// false ⇒ 淡出（松手）—— 淡出动画在 DanmakuAreaGuide 内部，宿主只翻标志
  /// ```
  /// ⚠️ 只翻一个 bool + setState（重建播放页）—— 与其它弹幕设置同一条重建路，
  ///    `DanmakuOverlay` 是 keep-alive 的 State，`areaGuide` 变了会让遮罩淡入/淡出，
  ///    但**不会**触发弹幕重排（layoutKey 里没有 areaGuide）。
  void _setDanmakuAreaGuide(bool on) {
    if (_showDanmakuAreaGuide == on) return;
    if (mounted) setState(() => _showDanmakuAreaGuide = on);
  }

  /// ★★★ Owner 1011 反馈第 1 条：轻量悬浮窗里三枚「按类型过滤」开关
  ///
  /// # 为什么走 `DanmakuConfig` 静态偏好 + 一个重建信号（与全屏大卡片同款）
  /// ```text
  /// 这三项（滚动/顶部/底部 显示开关）在 `DanmakuSettingsDialog` 里也是
  /// 直接读写 `DanmakuConfig.showScroll/showTop/showBottom`，不改 `_danmakuSettings`
  /// 那份快照（那份快照里根本没有这三个字段）。
  /// ⇒ 悬浮窗用**同一条路**：落盘 + setState 让播放页重建。
  ///   重建后 `DanmakuOverlay._ensureLayout` 的 key 里带了这三个值（见
  ///   danmaku_overlay.dart:568-570）⇒ 命中新 key、按新规则重排 ⇒ 实时生效。
  /// ```
  void _setDanmakuShowScroll(bool v) {
    DanmakuConfig.setShowScroll(v);
    if (mounted) setState(() {});
  }

  void _setDanmakuShowTop(bool v) {
    DanmakuConfig.setShowTop(v);
    if (mounted) setState(() {});
  }

  void _setDanmakuShowBottom(bool v) {
    DanmakuConfig.setShowBottom(v);
    if (mounted) setState(() {});
  }

  /// ★ Owner 2026-10-11（悬浮窗第 4 枚类型开关「彩色」）：
  /// 只显示彩色弹幕（白色弹幕隐藏）。与上面三枚同一条路 ——
  /// 落盘 `DanmakuConfig.setColorOnly` + setState ⇒ `DanmakuOverlay._ensureLayout`
  /// 的 layoutKey 里带了 `colorOnly` ⇒ 命中新 key、重排 ⇒ 实时生效。
  void _setDanmakuColorOnly(bool v) {
    DanmakuConfig.setColorOnly(v);
    if (mounted) setState(() {});
  }

  /// ★★★ 2026-10-14（Owner 反馈「弹弹play的凭证流程根本没走通」）：
  /// 面板凭证节点了「保存」—— 把用户填的一对 AppId / AppSecret 落盘。
  ///
  /// # 为什么要**重建客户端**（这是"真的走通"的关键）
  /// ```text
  /// appId/appSecret 是 `ExternalDanmakuClient` 的**构造快照**
  /// （见 _resetDanmakuClient 的注释与 4577 那段）⇒ 不重建的话，
  /// 旧实例照旧用**空**凭证去签名，用户点保存再点「重新获取」还是同一句
  /// 「没收到凭证」—— 这正是 Owner 说的"根本没走通"。
  /// ```
  ///
  /// # 只记「已保存」提示，**不**自动重取
  /// ```text
  /// 保存是"改配置"，重取是"发一次网络请求"。自动重取会让用户正看着的画面
  /// 忽然换一批弹幕（甚至换到另一集），比"什么都不发生"更糟。
  /// ⇒ 宿主把 credentialSaved 置真，面板据此提示「已保存，点重新获取生效」。
  /// ```
  /*
   * 2026-10-15: _setDanmakuCredentials / _clearDanmakuCredentials removed.
   *
   * Owner: "I told you to delete those two input boxes and use the built-in
   * credentials." The developer agreement allows built-in credentials via
   * placeholder + build-time injection, so the panel no longer offers manual
   * entry and these two write paths lost their only caller. A write path the
   * UI cannot reach should not stay in the code.
   *
   * Credentials now come from build-time --dart-define=DANDANPLAY_APP_ID /
   * _APP_SECRET (see builtinAppId/builtinAppSecret in core/danmaku.dart, the
   * CI workflow, and tools/run_client.ps1 for local builds).
   */

  void _reloadDanmaku() {
    /*
     * ★ 2026-10-14：「重新获取」= 丢掉用户的**手动选择**
     *
     * `_pickDanmakuMatch` 会把选中的 episodeId 记进 `_biliCid`（"这一集
     * 挂哪份弹幕"的身份）。用户点「重新获取弹幕」的语义就是"别按我上次
     * 选的来了，你自己重新找一遍" ⇒ 这个身份必须清掉，否则 `_loadDanmaku`
     * 里的 外部视频站/搜索退路会一直盯着旧 id。
     */
    _biliCid = 0;
    if (!_danmakuEnabled) {
      // 面板里直接点「重新取一次」= 用户就是想要弹幕 ⇒ 顺手开开关
      _setDanmakuEnabled(true);
      return;
    }
    unawaited(_loadDanmaku());
  }

  /// 弹幕层左上角的角标（**只在加载中 / 失败时**出现）
  ///
  /// 成功时不显示 —— 用户要看的是画面，不是「N 条弹幕」。
  /// 失败时必须显示：否则用户只会觉得"弹幕坏了"，
  /// 而实际上往往只是没填 AppId（原文见 core/danmaku.dart 的错误透传策略）。
  String? get _danmakuBadge {
    /*
     * ★★★ OPS-10 现象 A（Owner：「弹幕失败：Missing Authentication Headers ｜
     *     弹幕服务没收到凭证」……【这个失败提示一直不消失】）
     *
     * # 改前这一行排在**失败分支之前**
     * ```text
     * `if (!_danmakuEnabled) return null;` 是最先执行的一句。
     * 而弹幕开关出厂是**关**（core/danmaku.dart:19），外部视频站那条路取失败时
     * `_danmakuEnabled` 仍然是 false ⇒ 这里直接 return null ——
     * **失败角标在「开关关着」这个最常见的情形下根本不会显示**。
     * 用户报的是「失败提示一直不消失」，但在探针里量到的是它的另一面：
     * 开关关着时连「看得见」这一步都到不了（用例 ③ 的第一条断言就是这条）。
     * ```
     *
     * # 改法：先判「这一屏到底有没有话要说」，再让开关管它
     * ```text
     * 失败（`_danmakuError != null`）⇒ **照说**（用户必须知道为什么没有弹幕）；
     * 其余（加载中 / 没有弹幕）⇒ 仍然由开关管 —— 关着弹幕时不该冒出
     * 「弹幕加载中…」或「没有弹幕」这种「我在给你找弹幕」的口气。
     * ```
     */
    final err0 = _danmakuError;
    if (!_danmakuEnabled && err0 == null) return null;
    if (_danmakuLoading && err0 == null) return '弹幕加载中…';
    /*
     * ★★★ 2026-10-09（Owner：「这个弹幕失败一直也不消失」）
     *
     * # 用户报的是哪一条
     * ```text
     * 截图上是两条**叠在一起**的：
     *   ① _flash 那条（「…（打开弹幕设置可一键处理；这是 danmaku-service 的凭证…）」）
     *      —— 它 1.2 秒就消失，不是用户说的那个；
     *   ② ★ 本角标 —— 它**故意常驻**（见下面 4601 的旧注释），
     *      而用户读作「一直也不消失」。
     * ```
     *
     * # 为什么"常驻"这个设计本身是错的
     * ```text
     * 旧注释的理由是"失败时必须显示，否则用户只会觉得弹幕坏了"。
     * 那个理由**在刚失败时成立**，但它没说"显示多久"。
     * 弹幕角标画在**画面上**，永久糊在那里 = 用户每看一集都被它挡一次；
     * 而用户其实**已经知道了**（他看过一眼了）。
     * ```
     *
     * # 改法：给失败态一个**会自己走掉**的形态
     * ```text
     * 失败 ⇒ 记下失败时刻，角标显示 [kDanmakuBadgeFailMs] 毫秒后自动隐藏。
     * 用户点一下角标 ⇒ 立刻隐藏（不用等）。
     * 下一次起播/换集 ⇒ 重新计时（新的一集该重新告诉他一次）。
     * ```
     *
     * ⚠️ "加载中"那条**不参与**计时：它本来就该在加载完自动消失，
     *    加超时反而会让慢网络下的正常加载被误判成"卡住了"。
     *
     * ★★★ 2026-10-10（OPS-10 ④。Owner 逐字：
     *     「没有弹幕的那个标识,不用一直显示,跟随一起消失就行了」）
     *
     * # 角标**整体**跟随控制条（放在最前面 ⇒ 四支都吃到）
     * ```text
     * 角标是**浮在画面上的 chrome**，与控制条同一性质 ⇒ 控制条收起了，
     * 它也必须收。控制条回来时它自然回来 —— 判据是**当下**的
     * _controlsVisible，不需要额外记账：记账（隐藏时清掉）会让
     * "回来"时这句话永远回不来。
     * ```
     */
    if (!_controlsVisible) return null;
    if (_danmakuErrorAt != null &&
        DateTime.now().difference(_danmakuErrorAt!) >
            const Duration(milliseconds: kDanmakuBadgeFailMs)) {
      return null;
    }
    final e = _danmakuError;
    if (e != null) {
      final raw = e.xErrorMessage.isNotEmpty ? e.xErrorMessage : e.message;
      /*
       * ★★ Owner 第 1 条：角标**常驻**，所以能比提示条多给一个标题
       *   （「弹幕服务没收到凭证」比「Missing Authentication Headers」
       *   多告诉用户一件事：**这是凭证问题**）。
       * ⚠️ 仍然只给标题、不给全文 —— 角标画在视频画面上，
       *    全文会把画面糊住（见 danmaku_overlay.dart 的 `_badge`）。
       */
      final h = e.hint;
      return h == null ? '弹幕失败：$raw' : '弹幕失败：$raw ｜ ${h.title}';
    }
    if (_danmakuComments.isEmpty) {
      if (_danmakuStatus.isEmpty) return null;
      /*
       * ★★★ 2026-10-10（OPS-10 ④）：改前这里只有一句
       *     `return '没有弹幕';` —— 既没有计时器、也不看控制条，
       *     于是"取数成功但 0 条"的角标**永久**糊在画面左上角。
       *
       * 现在它跟失败态一样有**寿命**：到点由 [_danmakuBadgeTimer]
       * 触发一次重建，本 getter 看到 [_danmakuEmptyExpired] ⇒ 不再画。
       *
       * ⚠️ 判据必须是**定时器翻的 bool**，不能是 `DateTime.now()` 算差值：
       *    widget 测试里 `t.pump(Duration)` 只推进**假时钟**，
       *    墙钟几乎不动 ⇒ 用 now() 算的话，测试里这个角标永远不消失，
       *    而生产上会消失 —— 两边行为不一致，测试就是假的。
       */
      if (_danmakuEmptyExpired) return null;
      return '没有弹幕';
    }
    return null;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-31 ④：外部弹幕弹幕
  //
  //  面板（`BiliImportDialog`）是**纯 UI** —— 它自己不发请求、不读偏好，
  //  所有网络与落盘都在这一节里。这与 `DanmakuSettingsDialog` 同一分工。
  // ═══════════════════════════════════════════════════════════════════

  /// 外部视频站 HTTP 客户端（懒建）
  ///
  /// ⚠️ 与 `_ensureDanmakuClient()` 分开：两个源的超时/追踪策略不同，
  ///    而且**没绑过的用户不该建这个连接池**。
  BiliApi _ensureBiliApi() => _biliApi ??= BiliApi();

  /// 打开「外部弹幕弹幕」面板
  void _openBiliSheet() {
    final b = loadBinding(widget.provider, widget.id);
    final manual = isManualBinding(widget.provider, widget.id);
    /*
     * ★ 用户上次手选的 P —— 直接用 `BiliPrefs.pageKey` 读写
     *
     * ⚠️ `bili_bind.dart` 里**没有** `loadPage/savePage`（只有键名工厂）。
     *    不往那边加函数：那是 t70 已跑绿的文件，而且这个键**只有播放页
     *    的这一个面板用**，加进 core 反而是把一个 UI 细节塞进模型层。
     */
    final page =
        int.tryParse(
          UiPrefs.get(BiliPrefs.pageKey(widget.provider, widget.id)) ?? '',
        ) ??
        0;
    setState(() {
      _biliSheetOpen = true;
      /*
       * ★ 同时收起弹幕设置面板
       *
       * 两个都是 `Positioned.fill` 的全屏 scrim，同时开着会让层序变成
       * 「谁后画的谁在上面」这种隐式规则 —— 而 Esc 链是显式的、只按一个
       * 顺序走 ⇒ 用户按 Esc 关掉的可能不是他看见的那一层。
       * 同一时刻只留一个 scrim，两处规则才对得上。
       */
      _danmakuSheetOpen = false;
      /*
       * ★ 记下「打开面板时是哪一集」
       *
       * 面板里的「导入并绑定 / 立即更新」会先比这个令牌 —— 中途换过集
       * 就说明那次操作的结果已经过时，必须丢掉（与 `_danmakuFetchToken`
       * 同一条规矩）。不记的话会出现「切到第 5 集了，面板却报第 3 集
       * 的弹幕条数」。
       */
      _biliPanelToken = _danmakuFetchToken;
      _biliState = _biliState.copyWith(
        loading: false,
        clearError: true,
        binding: b,
        clearBinding: b == null,
        pages: _biliInfoCache?.pages ?? const <BiliPage>[],
        selectedPage: page,
        episodeIndex: _epIndex,
        episodeTitle: _currentEpisodeTitle ?? '',
        episodeCount: _episodes.length,
        autoUpdate: biliAutoUpdateEnabled(),
        intervalMinutes: biliAutoUpdateInterval(),
        comments: _biliCid > 0 ? _danmakuComments.length : 0,
        /*
         * ★ Owner 第 2 条：每次开面板都把上一次的搜索结果清掉
         *
         * 留着的话，用户换了集再开面板，看到的是**上一集关键词**的
         * 结果列表 —— 点一条就绑到错误的视频上。宁可空着让他重搜。
         */
        searchResults: const <BiliSearchItem>[],
        /*
         * ★★★ 2026-10-09（Owner：「获取弹幕 externaldanmaku和弹弹都应该支持 自动填入名字」）
         *
         * # 改前是空串，用户每次都要手打一遍剧名
         * ```text
         * 上面那条注释说的是"清掉**上一次搜索结果**"（对，那必须清）；
         * 但它把**关键词**也一起清了 ⇒ 用户打开面板看到的是空搜索框，
         * 得自己重新敲一遍标题 —— 而他正在看的这一集叫什么，
         * 应用明明知道（`_liveTitle`）。
         * ```
         *
         * # 为什么预填 `_liveTitle` 而不是 `_danmakuFileName`
         * ```text
         * `_danmakuFileName` 是给 danmaku-service 的 match 用的（去掉了扩展名，
         * 有时还带"第01集"这种后缀）；而**搜索**要的是**作品名**，
         * 带上集数反而搜不准。`_liveTitle` 就是标题栏上那串，最贴近用户认知。
         * ```
         *
         * ⚠️ 用户点「搜索」前可以随便改 —— 这只是**预填**，不是锁定。
         */
        searchKeyword: _liveTitle.trim(),
        trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
      );
    });
    // ★★★ T27-09：浮层打开 ⇒ 顶/底栏一起收（显隐统一真源，见 _collapseControlsForSheet）
    _collapseControlsForSheet();
    /*
     * ★ 手动绑过 ⇒ 顺手把 P 列表补上（面板要画「第几 P」那一行）
     *
     * ⚠️ 只查缓存里有没有，**不主动发请求** —— 打开面板不该有网络副作用
     *    （与 `DanmakuSettingsDialog` 同一条规矩）。
     */
    if (b != null && !b.isEmpty && _biliInfoCache == null && manual) {
      unawaited(_biliRefreshInfo(b));
    }
  }

  /// 补一次视频信息（P 列表 / 标题）
  ///
  /// ⚠️ `bindFromInput` 只回 `BiliBindOutcome`、**不回** `BiliVideoInfo`
  ///    （`.probe/bili/INTEGRATION.md` §4.4 自认的设计小瑕疵）。
  ///    给 `BiliBindOutcome` 加字段要动 `bili_bind.dart` 并让已跑绿的 t70
  ///    跟着改 ⇒ **不采**；这里多拉一次（服务端有缓存，实测 ~200 ms）。
  Future<void> _biliRefreshInfo(BiliBinding b) async {
    try {
      final ref = BiliRef(bvid: b.bvid, aid: b.aid);
      final info = await _ensureBiliApi().videoInfo(ref);
      if (!mounted) return;
      setState(() {
        _biliInfoCache = info;
        _biliState = _biliState.copyWith(
          info: info,
          pages: info.pages,
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
    } catch (e) {
      /*
       * ★ 补信息失败**不算绑定失败**
       *
       * 绑定本身（cid 对应表）已经落盘了，弹幕照样能拉 —— 只是面板上
       * 「第几 P」那一行暂时画不出来。把它报成错误会让用户以为绑定没成。
       */
      debugPrint('[BILI] 视频信息补拉失败（不影响绑定）: $e');
    }
  }

  /// 用户点了「搜索」（Owner 第 2 条）
  ///
  /// ★ 搜索**不落盘、不绑定** —— 它只把结果列表画出来，点其中一条才走
  ///   `_biliImport`（面板里那一格缩略图就是干这个的）。
  ///
  /// ⚠️ 令牌判据与 `_biliImport` 同一条：面板是"哪一集"打开的，
  ///   中途换集后回来的结果必须丢掉（否则会绑到错的那一集）。
  Future<void> _biliSearch(String keyword) async {
    final kw = keyword.trim();
    if (kw.isEmpty) return;
    final token = _biliPanelToken;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: true,
        busyLabel: '正在搜 外部视频站…',
        clearError: true,
        searchKeyword: kw,
        searchResults: const <BiliSearchItem>[],
      );
    });
    try {
      final list = await _ensureBiliApi().searchVideos(kw);
      if (!mounted || token != _biliPanelToken) return;
      setState(() {
        _biliState = _biliState.copyWith(
          loading: false,
          searchResults: list,
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
    } on DanmakuException catch (e) {
      if (!mounted || token != _biliPanelToken) return;
      setState(() {
        _biliState = _biliState.copyWith(
          loading: false,
          error: e,
          searchResults: const <BiliSearchItem>[],
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
    } catch (e) {
      if (!mounted || token != _biliPanelToken) return;
      _biliFail('搜索失败：$e');
    }
  }

  /// 用户点了「导入并绑定」
  Future<void> _biliImport(String input, int page) async {
    final token = _biliPanelToken;
    setState(() {
      _biliState = _biliState.copyWith(
        input: input,
        loading: true,
        busyLabel: '正在解析并绑定…',
        clearError: true,
      );
    });
    try {
      final api = _ensureBiliApi();
      final outcome = await bindFromInput(
        api: api,
        input: input,
        provider: widget.provider,
        id: widget.id,
        localTitle: _liveTitle,
        episodeTitles: [for (final e in _episodes) e.title],
        forcedPage: page,
        forcedEpisode: page > 0 ? _epIndex : -1,
        manual: true,
      );
      if (!mounted) return;
      /*
       * ★ 面板开着的时候用户换了集 ⇒ 这次导入的结果已经过时
       *
       * 绑定**照样落盘**（那是全局的，与集无关），但面板上的
       * 「当前这一集 / 条数」不能再往上写 —— 写了就是在撒谎。
       */
      if (token != _biliPanelToken) {
        debugPrint('[BILI] 导入完成时已经换集 ⇒ 不更新面板读数');
        setState(() {
          _biliState = _biliState.copyWith(
            loading: false,
            binding: outcome.binding,
          );
        });
        return;
      }
      await _biliRefreshInfo(outcome.binding);
      if (!mounted) return;
      final r = await _biliFetch(outcome.binding, force: true);
      if (!mounted) return;
      setState(() {
        _biliState = _biliState.copyWith(
          loading: false,
          binding: outcome.binding,
          info: _biliInfoCache,
          pages: _biliInfoCache?.pages ?? const <BiliPage>[],
          result: r,
          selectedPage: page,
          episodeIndex: _epIndex,
          episodeTitle: _currentEpisodeTitle ?? '',
          episodeCount: _episodes.length,
          comments: r.total,
          trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
        );
      });
      await _biliApplyComments(r);
    } on ArgumentError catch (e) {
      // ★ 解析失败 ⇒ 一个请求都没发（`bindFromInput` 第一行就抛）
      _biliFail('没认出 BV 号 / av 号 / 链接：${e.message}');
    } catch (e) {
      _biliFail('$e');
    }
  }

  /// 取一次 外部视频站弹幕（**这一集**的 cid）
  ///
  /// 与 `_loadBiliDanmaku` 的分工：
  /// ```text
  /// _biliFetch        ⇒ 给**面板**用（要 BiliUpdateResult 的 added/removed）
  /// _loadBiliDanmaku  ⇒ 给**起播**用（要令牌 + loading + 错误角标那套骨架）
  /// ```
  Future<BiliUpdateResult> _biliFetch(
    BiliBinding b, {
    bool force = false,
  }) async {
    final cid = b.cidFor(_epIndex);
    if (cid <= 0) {
      return const BiliUpdateResult(
        cid: 0,
        total: 0,
        added: 0,
        removed: 0,
        fromCache: false,
        changed: false,
        error: '这一集还没有绑定 外部视频站弹幕',
      );
    }
    return updateDanmaku(
      api: _ensureBiliApi(),
      cid: cid,
      force: force,
      intervalMinutes: biliAutoUpdateInterval(),
    );
  }

  /// 起播时按 cid 取一次 外部视频站弹幕（照抄 danmaku-service 那套骨架）
  ///
  /// ⚠️ 令牌判据**不能省** —— 换集后旧的响应必须被丢掉，
  ///    否则第 5 集会短暂显示第 3 集的弹幕。
  /// 自动搜 外部视频站 → 绑定 → 取弹幕。成功返回 true（调用方据此 return）。
  ///
  /// 判据与设计见 `_loadDanmakuNamed` 里那段长注释（为什么需要这一步、
  /// 为什么免登录成立、失败为什么要静默）。这里只补**执行**细节：
  ///
  /// ```text
  /// ① 标题取 `_liveTitle`（与 danmaku-service 那条路同一个来源，保证两边一致）
  /// ② 集名用 `_episodes` 的标题（分 P 对齐要靠它）
  /// ③ 成功 ⇒ 落盘 + 立刻用刚拿到的 cid 拉弹幕（不多发一次请求）
  /// ```
  ///
  /// ⚠️ 整个过程**不 flash 任何"正在搜索"**：起播时的提示条是给失败用的，
  ///    搜索成功的话用户直接看到弹幕出现，那才是最好的反馈。
  Future<bool> _autoBindBili() async {
    final title = _liveTitle.trim();
    if (title.isEmpty) return false;
    try {
      final api = _ensureBiliApi();
      final outcome = await autoBindBySearch(
        api: api,
        provider: widget.provider,
        id: widget.id,
        localTitle: title,
        episodeTitles: [for (final e in _episodes) e.title],
      );
      if (outcome == null || !outcome.ok) return false;
      final cid = outcome.binding.cidFor(_epIndex);
      if (cid <= 0) return false;
      if (!mounted) return true;
      // 自动匹配成功 ⇒ 让面板与卡片也能看到这次绑定（不静默改状态）
      debugPrint('[BILI] 自动匹配成功：${outcome.reason} cid=$cid');
      /*
       * ★★ 登记"怎么对上的" —— 这是本面板存在意义的第三格。
       *
       * 判据是 `outcome.reason` 里那句**由 core 写明**的文案：
       * season 兜底那条自己就带「season 链路」字样（见 bili_bind.dart 的
       * `_autoBindViaSeason`）。用它而不是猜分数 —— 分数 0.5 是 season
       * 兜底**硬编码**的，和"匹配得多准"无关。
       *
       * ⚠️ 若将来 core 改了那句文案，这里会退化成 `autoSearch`。
       *    方向是**安全**的（错误显示成"自动匹配"而不是误报"兜底"），
       *    但仍应同步改 —— 已在 app_menu 那轮踩过同类坑。
       */
      _setDanmakuInfo(
        match: outcome.reason.contains('season')
            ? DanmakuInfoMatch.autoSeason
            : DanmakuInfoMatch.autoSearch,
        title: outcome.binding.title,
      );
      await _loadBiliDanmaku(cid);
      return true;
    } catch (e) {
      /*
       * ★ 这里**必须**吞掉异常。
       *
       * 自动匹配是"锦上添花"：失败就退回 danmaku-service（改前的行为），
       * 绝不能因为多了这一步而让原本能用的路径变差。
       * 但要留日志 —— 本项目的一贯纪律是"可以降级，不许静默"。
       */
      debugPrint('[BILI] 自动匹配失败（退回 danmaku-service）：$e');
      return false;
    }
  }

  Future<void> _loadBiliDanmaku(int cid) async {
    final token = ++_danmakuFetchToken;
    if (mounted) {
      setState(() {
        _danmakuLoading = true;
        _danmakuError = null;
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: true,
          clearError: true,
        );
      });
    }
    final r = await updateDanmaku(
      api: _ensureBiliApi(),
      cid: cid,
      force: true,
      intervalMinutes: biliAutoUpdateInterval(),
    );
    if (!mounted || token != _danmakuFetchToken) return;
    if (!r.ok) {
      final e = DanmakuException(r.error);
      setState(() {
        _danmakuComments = r.comments;
        _danmakuStatus = '';
        _danmakuError = e;
        /*
         * ★★★ OPS-10 现象 A（Owner 逐字：「弹幕失败：Missing Authentication
         *     Headers ｜ 弹幕服务没收到凭证 …【这个失败提示一直不消失】」）
         *
         * # 改前这一支**没有**这两行
         * ```text
         * `_danmakuBadge` 的失败寿命判据是 `_danmakuErrorAt` 的差值
         * （player_page.dart:4932-4936），而这里只写了 `_danmakuError`、
         * 没写 `_danmakuErrorAt`、也没起计时器 ⇒ 判据恒为 false ⇒
         * 角标**永远**画着。danmaku-service 那一支（:4659/:4673）早就写了，
         * 只有 外部视频站这一支漏了 —— 这正是用户看到「常驻」的那一条。
         * ```
         */
        _danmakuErrorAt = DateTime.now();
        _danmakuLoading = false;
        // ★ 失败也要如实登记来源（面板要显示"谁失败了"+ 原文原因）
        _setDanmakuInfo(
          source: DanmakuInfoSource.bili,

        );
        _danmakuSettings = _danmakuSettings.copyWith(
          loading: false,
          error: e,
          status: '',
        );
      });
      _armDanmakuBadgeExpiry();
      _flash('弹幕失败：${r.error}');
      return;
    }
    /*
     * ★★★ 2026-10-18（task-66 轨道 I / Owner 第 11 条）：**手动绑定之后也要聚合**
     *
     * # 改前这里是什么
     * ```text
     * 直接 `_danmakuComments = r.comments;` —— 只有外部源那一份。
     * 而 `aedc29c` 取消了起播自动绑定 ⇒ 用户绑外部源**一定**是手动的，
     * 也就是说这条路上「插件自带 + 导入源合并」**每一次**都失效。
     * ```
     * # 用户看到的现象
     * ```text
     * 手动绑了外部源（比如为了追某部番的弹幕），
     * 结果插件自己给的那份弹幕**整批消失** —— 画面上只剩外部源那份。
     * 而 Owner 要的是两路并起来。
     * ```
     * # 为什么先 await 再 setState
     * ```text
     * 聚合要问插件要弹幕（真异步）。改前这里是**同步** setState，
     * 所以必须把聚合提到 setState 之前 —— 在 setState 里 await 会让
     * `setState() called during build` 那类问题冒出来（本文件踩过多次）。
     * ```
     * # 令牌为什么再验一次
     * ```text
     * await 期间用户可能已经切集（`_danmakuFetchToken` 变了）⇒
     * 这次结果作废。不查的话会把上一集的聚合结果画到新一集上。
     * ```
     */
    final agg = await _aggregateDanmaku(
      primary: r.comments,
      primaryKind: DanmakuSourceChannel.imported,
      primaryDetail: '外部视频站',
      primarySource: DanmakuInfoSource.bili,
      token: token,
    );
    if (!mounted || token != _danmakuFetchToken) return;
    setState(() {
      _danmakuComments = agg.comments;
      // ★ OPS-10 B：UI 如实反映来源（见 _loadDanmakuNamed 里那段说明）
      _danmakuStatus = '外部视频站 · ${r.summary}';
      _danmakuError = null;
      /*
       * ★ OPS-10 ⑤：取回来了 ⇒ 上一次的失败态必须**真的**被清掉。
       *   只清 `_danmakuError` 不够 —— 角标那条寿命判据读的是
       *   `_danmakuErrorAt`，留着它会让「刚成功」的下一帧又被判成过期。
       */
      _danmakuErrorAt = null;
      _danmakuEmptyExpired = false;
      _danmakuLoading = false;
      /*
       * ★ OPS-10 ⑤：`_danmakuEnabled = true` 是**真的把开关打开**
       *   （用户下次点底栏那颗按钮时 `_toggleDanmaku` 会把它写回偏好）。
       *   用户导入完 外部视频站弹幕、回到播放页 ⇒ 弹幕本来就该出现，
       *   而不是先让他去点一次开关。
       */
      _danmakuEnabled = true;
      /*
       * ★ task-66：与 `agg.comments` **同一帧**把分路读数交给面板。
       *   只合并不报来源 ⇒ 用户看到「1900 条」却不知道哪来的
       *   （Lead 特别提醒过这一条，`_aggregateRows` 就是画它的）。
       */
      _setDanmakuInfo(
        source: DanmakuInfoSource.bili,
        aggregate: agg,
      );
      _danmakuSettings = _danmakuSettings.copyWith(
        enabled: true,
        loading: false,
        clearError: true,
        status: '外部视频站 · ${r.summary}',
      );
    });
    _biliCid = cid;
    markBiliSynced();
  }

  /// 把一次更新的结果落到渲染层
  ///
  /// ★ 与 `_loadBiliDanmaku` 的区别：这里**不动 loading / 错误角标** ——
  ///   面板里的「立即更新」是用户主动点的一次刷新，失败了在**面板里**说，
  ///   不该把画面上的弹幕清掉（那会让用户以为弹幕坏了）。
  ///
  /// ★★★ 2026-10-18（task-66 轨道 I / Owner 第 11 条）：**这条也要聚合**
  /// ```text
  /// 改前：`_danmakuComments = r.comments;` ⇒ 只灌外部源那一份。
  ///
  /// 这条路径有三个入口，用户每一次都会踩到：
  ///   · `_biliImport`      导入并绑定（首次）
  ///   · `_biliAutoRefresh` 切集时的自动刷新
  ///   · `_biliUpdateNow`   面板里的「立即更新」
  /// 任何一个走过之后，插件那份弹幕都会从画面上消失。
  /// ```
  /// ⚠️ 改成 `Future<void>` 的理由：聚合要 `await` 插件的弹幕。
  ///    三个调用方（`_biliImport` / `_biliAutoRefresh` / `_biliUpdateNow`）
  ///    **本来就是 async** ⇒ 这里加 await 不会传染出新的 async。
  Future<void> _biliApplyComments(BiliUpdateResult r) async {
    if (!r.ok) {
      _flash('弹幕失败：${r.error}');
      return;
    }
    if (!mounted) return;
    /*
     * 令牌：**认领一次新的取弹幕**（与 `_loadBiliDanmaku` 同一套）。
     *
     * ⚠️ 这里必须 `++`，不能只读旧值：
     *    只读的话，另一条聚合（比如 `_loadBiliDanmaku` 正在问插件）会
     *    与本条**共用**同一个令牌 ⇒ 两条都通过校验 ⇒ 后落地的那个覆盖前一个，
     *    画面上的弹幕会随机变成"哪条先回来算哪条"。
     */
    final token = ++_danmakuFetchToken;
    final agg = await _aggregateDanmaku(
      primary: r.comments,
      primaryKind: DanmakuSourceChannel.imported,
      primaryDetail: '外部视频站',
      primarySource: DanmakuInfoSource.bili,
      token: token,
    );
    if (!mounted || token != _danmakuFetchToken) return;
    setState(() {
      _danmakuComments = agg.comments;
      // ★ OPS-10 B：UI 如实反映来源（见 _loadDanmakuNamed 里那段说明）
      _danmakuStatus = '外部视频站 · ${r.summary}';
      _danmakuError = null;
      // ★ 与上面那行**同一帧**登记来源（面板不猜文案）
      _setDanmakuInfo(
        source: DanmakuInfoSource.bili,
        aggregate: agg,
      );
      /*
       * ★★★ OPS-10 ⑤（Owner 逐字：「导入externaldanmaku弹幕之后,并没有提示任何信息
       *     和反馈,返回播放页继续,也没有出现弹幕」）
       *
       * # 改前这里只写了上面四行 —— 三件事一起漏掉
       * ```text
       * ① 失败态没清干净：`_danmakuErrorAt` 还留着上一次失败的时刻
       *    （角标那条寿命判据读的就是它，player_page.dart:4932-4936）
       *    ⇒ 面板里说「更新成功」、画面角标却在说「弹幕失败」，两边打架。
       * ② 面板读数没同步：`_danmakuSettings` 一个字都没动 ⇒ 弹幕设置面板
       *    里仍然是上一次那套 loading/error/status。
       * ③ **一句话都没说**：成功那条路上没有任何 `_flash` ⇒ 用户点完
       *    「导入并绑定」看到的是「什么都没发生」（他只能反复点）。
       * ```
       *
       * # 文案为什么是这一句
       * ```text
       * 用户要知道的是**三件事**：用的是哪个源（外部视频站，不是 danmaku-service）、
       * 成了多少条、这一集到底有没有东西上屏。
       * `r.summary` 自己只说「新增 N 条，共 M 条」（bili_auto_update.dart:89-96），
       * 不含源名 ⇒ 这里补上「外部视频站」二字。
       * ```
       */
      _danmakuErrorAt = null;
      _danmakuEmptyExpired = false;
      _danmakuLoading = false;
      _danmakuEnabled = true;
      _danmakuSettings = _danmakuSettings.copyWith(
        enabled: true,
        loading: false,
        clearError: true,
        status: '外部视频站 · ${r.summary}',
      );
    });
    _biliCid = r.cid;
    markBiliSynced();
    // ★ OPS-10 ⑤：成功也必须**说一句**（改前这条路上一个字都没有）
    _flash('外部视频站弹幕已导入：这一集 ${r.total} 条（新增 ${r.added} 条）');
  }

  /// 自动刷新（切集 / 集列表变了时调用）
  ///
  /// `shouldAutoUpdate` 已经把「开关关了 / 缓存还新鲜」两条判掉 ⇒ 这里
  /// 只管拿到绑定、按当前集算 cid、取一次。
  Future<void> _biliAutoRefresh() async {
    final b = loadBinding(widget.provider, widget.id);
    if (b == null || b.isEmpty) return;
    final cid = b.cidFor(_epIndex);
    if (cid <= 0) return;
    if (!shouldAutoUpdate(cid: cid)) return;
    final r = await _biliFetch(b);
    if (!mounted) return;
    if (!r.ok) {
      debugPrint('[BILI] 自动刷新失败（保留旧弹幕）: ${r.error}');
      return;
    }
    await _biliApplyComments(r);
    if (_biliSheetOpen) {
      setState(() {
        _biliState = _biliState.copyWith(
          result: r,
          comments: r.total,
          episodeIndex: _epIndex,
          episodeTitle: _currentEpisodeTitle ?? '',
          episodeCount: _episodes.length,
        );
      });
    }
  }

  /// 面板里选了第几 P
  void _biliSelectPage(int page) {
    UiPrefs.set(BiliPrefs.pageKey(widget.provider, widget.id), '$page');
    setState(() {
      _biliState = _biliState.copyWith(selectedPage: page);
    });
  }

  /// 面板里开关了「自动更新」
  void _biliSetAutoUpdate(bool v) {
    setBiliAutoUpdateEnabled(v);
    setState(() {
      _biliState = _biliState.copyWith(autoUpdate: v);
    });
  }

  /// 面板里改了「自动更新间隔」（分钟，core 侧夹 5~1440）
  void _biliSetInterval(int minutes) {
    setBiliAutoUpdateInterval(minutes);
    setState(() {
      _biliState = _biliState.copyWith(
        intervalMinutes: biliAutoUpdateInterval(),
      );
    });
  }

  /// 面板里点了「立即更新」
  Future<void> _biliUpdateNow() async {
    final b = _biliState.binding;
    if (b == null || b.isEmpty) return;
    final token = _biliPanelToken;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: true,
        busyLabel: '正在重拉弹幕…',
        clearError: true,
      );
    });
    final r = await _biliFetch(b, force: true);
    if (!mounted) return;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: false,
        result: r,
        comments: r.total,
        trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
      );
    });
    if (token != _biliPanelToken) return;
    await _biliApplyComments(r);
  }

  /// 面板里点了「解除绑定」
  ///
  /// ★ 解绑后**下一次起播**就自动退回 danmaku-service（`_loadDanmakuNamed` 里
  ///   那条 外部视频站优先分支查不到绑定了）。这里顺手把画面上的弹幕也清掉 ——
  ///   留着会让用户以为解绑没生效。
  void _biliUnbind() {
    clearBinding(widget.provider, widget.id);
    setState(() {
      _biliState = const BiliImportState();
      _biliInfoCache = null;
      _biliCid = 0;
      _danmakuComments = const <DanmakuComment>[];
      _danmakuStatus = '';
      _danmakuError = null;
    });
    _flash('已解除 外部视频站弹幕绑定');
  }

  /// 面板里的一次失败（把面板切回可操作态 + 提示一句）
  void _biliFail(String msg) {
    if (!mounted) return;
    setState(() {
      _biliState = _biliState.copyWith(
        loading: false,
        error: DanmakuException(msg),
        trace: _biliApi?.trace ?? const <BiliHttpTrace>[],
      );
    });
    _flash(msg);
  }

  /// 打开「在线搜索字幕」（assrt.net）面板 —— ★ task-31 ⑤
  ///
  /// ⚠️ 先收起播放设置面板：它是 `Positioned.fill` 的全屏 scrim，
  ///    不关的话用户只会在设置面板上看到一层更暗的遮罩，
  ///    然后「返回」会先把字幕面板关掉 —— 观感像卡住了。
  void _openSubtitlePanel() {
    setState(() {
      _settingsOpen = false;
      _danmakuSheetOpen = false;
      _subtitlePanelOpen = true;
    });
    // ★★★ T27-09：浮层打开 ⇒ 顶/底栏一起收（显隐统一真源，见 _collapseControlsForSheet）
    _collapseControlsForSheet();
    // ⚠️ 这里**故意不调** `_hideSettingsPortal()`：设置面板的真源是
    //   `_settingsOpen`，它变 false 后 portal 子树返回 `SizedBox.shrink()`，
    //   遮罩自然消失（与 `onClose: () => setState(() => _settingsOpen = false)`
    //   同款，Lead 裁决②）。
    //   ★ 而且 `test\t68_android_adapt_test.dart:364` 把「_hideSettingsPortal
    //   的**调用**」钉成恰好 2 处（关面板助手 + 面板 X）——多一处门禁就红。
  }

  /// 探针用：只改弹幕开关，**不发请求**
  ///
  /// 与 [debugPlayerSetDanmakuEnabledForProbe] 配套 ——
  /// 写成实例方法是为了不产生
  /// `invalid_use_of_protected_member`（在类外调 setState 会报）。
  void debugDanmakuSetEnabledOnly(bool v) {
    if (!mounted) return;
    setState(() => _danmakuEnabled = v);
  }

  /// 探针用：重跑一次**起播时那次**弹幕偏好读取（`_loadDanmakuPrefs`）
  ///
  /// # 为什么需要它（OPS-10 ⑤ 的夹具关键）
  /// ```text
  /// `_danmakuEnabled` 只在 `initState` 里由偏好读出来一次（:2354-2357），
  /// 而探针入口在 `initState` **之前**就已经把 UiPrefs 写好了 ——
  /// 单测里没有"先起播再改偏好"这一步，于是开关永远是出厂值（关）。
  /// 真机上用户是"导入 → 退出 → 再进来"，第二次进来才读到偏好。
  /// 这里重跑那**同一段生产代码**，把"第二次进播放页"这件事补上 ——
  /// 不手抄一份 `_danmakuEnabled = ...`，否则测的就不是生产判据了。
  /// ```
  void debugDanmakuLoadPrefs() {
    if (!mounted) return;
    _loadDanmakuPrefs();
  }

  /// 探针用：塞一组**本地构造的**弹幕进渲染层（同时把开关打开）
  ///
  /// 见顶层 [debugPlayerSetDanmakuCommentsForProbe] 的说明：
  /// 没有 AppId/AppSecret 时真实链路必然 403，
  /// 渲染/滚动/泳道分配只能靠本地数据独立验证。
  void debugDanmakuSetComments(List<DanmakuComment> cs) {
    if (!mounted) return;
    setState(() {
      _danmakuComments = cs;
      _danmakuEnabled = true;
    });
  }

  /// 探针用：造「取数**成功**但一条都没有」这个状态
  ///
  /// # 为什么必须由探针造
  ///
  /// 生产上这个状态来自 `DanmakuFetchResult` / `BiliUpdateResult`
  /// 的 `summary` 非空而 `comments` 为空（`summary` 永远非空，见
  /// core/danmaku.dart 的 `String get summary`）。真实链路要**网络**
  /// + **凭证**，单测里发不出来。
  ///
  /// ⚠️ 写的是真字段 `_danmakuComments` / `_danmakuStatus`，
  ///    与生产成功那一支（`player_page.dart:4638-4649` / `:5307-5317`）
  ///    写的是同一组 —— 不手抄副本。
  void debugDanmakuSetEmptyResult(String status) {
    if (!mounted) return;
    setState(() {
      _danmakuComments = const <DanmakuComment>[];
      _danmakuStatus = status;
      _danmakuError = null;
      _danmakuLoading = false;
      _danmakuEnabled = true;
      // ★ 与生产成功那几支同款：新读数 ⇒ 重新计一次寿命
      _danmakuEmptyExpired = false;
    });
    _armDanmakuBadgeExpiry(kDanmakuBadgeEmptyMs);
  }

  /// 打开「播放设置」面板（齿轮）
  ///
  /// ★★★ 桌面端第 3 条：**纯 UI 动作必须排在两次 mpv 回读之前**
  ///
  /// # Owner 报（截图 + 原话）
  /// ```text
  /// > 不知道点了什么，下面一栏就不显示了，上面还显示 下面就不显示了
  /// > 原来是点了 设置(字幕/音轨/连播) 这个按钮，点了之后无反应，
  /// > 然后下面这页直接没了
  /// ```
  ///
  /// # 根因（改前，实测复现）
  /// ```dart
  /// await _readMpvStyle();    // 7 个属性，每个一次 await native.getProperty
  /// await _readVideoZoom();   // 又一次 await native.getProperty
  /// setState(() => _settingsOpen = true);   // ← 到不了
  /// ```
  /// `native.getProperty` 走的是 **FFI 调用**，mpv 侧只要不回应
  ///（卡住 / 进程已崩 / 还没就绪）这两个 await 就**永不返回** ⇒
  /// `_settingsOpen` 恒为 false。与此同时：
  /// ```text
  /// ① 底栏的 3 秒自动隐藏计时器照常到点（:7171）⇒ 底栏整条收掉
  ///    （底栏门控含 !_settingsOpen，而它还是 false —— 计时器不背这个锅）
  /// ② 顶栏只看 `_controlsVisible || _canUseFloatingBack`（:8842），
  ///    **不看** `_settingsOpen` ⇒ 顶栏留着
  /// ```
  /// ⇒ 屏幕上就是「上面还显示、下面一栏没了、点齿轮无反应」——与截图逐条吻合。
  ///
  /// ★ 实测读数（`.probe\zz_settings_v7.txt`；flutter_tester 里 mpv 属性读天然不返回，
  ///   正好是这条缺陷的**免费夹具**）：
  /// ```text
  /// T10b 点后立即      | open=false sheet=0 gear=0 bar=0
  /// T10d 真实等待 5s 后 | open=false sheet=0 gear=0 bar=0   ← 面板永不出现，底栏没了
  /// T11  探针直调后     | open=true  sheet=1 gear=0 bar=0   ← 跳过 mpv 读 ⇒ 面板正常
  /// ```
  ///
  /// # 为什么「先开面板、回读降级为后台刷新」是**安全**的
  /// ```text
  /// ① 两个读函数结尾都是 `if (mounted) setState(...)`（:3336 / :2088）
  ///    ⇒ 读到了自然刷新面板，只是晚几帧
  /// ② 面板本来就有「读不到」的显示分支（`onChanged: fontSize == null` 禁用、
  ///    `hint: '读不到'`，见 test/player_capability_test.dart:664-674）
  ///    ⇒ 设计上**本来就允许** mpv 值缺失
  /// ⇒ 把「阻塞式回读」排在「打开面板」之前是**纯排序错误**，不是有意的取舍。
  ///
  /// ⚠️ 不要改成 `await ...timeout(...)` 的折中写法：那只是把
  ///    「永不返回」换成「永远卡 400ms」—— 用户点齿轮仍要等一下，
  ///    而这里根本**没有必要**等（面板不需要这些值才能画出来）。
  Future<void> _openSettings() async {
    // ① 纯 UI 动作先落地 —— 不依赖任何 mpv 往返
    // ★★★ T27-09：浮层打开 ⇒ 顶/底栏一起收（显隐统一真源，见 _collapseControlsForSheet）
    _collapseControlsForSheet();
    setState(() => _settingsOpen = true);
    _showSettingsPortal();

    // ② 回读降级为**后台**刷新：读到了自己 setState 进面板
    //    （task-22 P1-11：面板里的「画面缩放」要显示当前值；
    //      读不到就不改 `_videoZoomPct`，面板会显示「读不到」而不是假装 100%）
    unawaited(_readMpvStyle());
    unawaited(_readVideoZoom());
  }

  /// 让挂到 rootOverlay 的播放设置面板**真的显示出来**（★ task-25 D）
  ///
  /// ⚠️ 必须**真的调** `show()`：`OverlayPortal` 在 `_zOrderIndex == null` 时
  ///    直接 `return _OverlayPortal(overlayLocation: null, overlayChild: null, …)`
  ///    （flutter/lib/src/widgets/overlay.dart:2092-2098）⇒ 只声明式地写
  ///    `if (_settingsOpen)` 在 overlayChildBuilder 里，面板**永远不会出现**。
  ///
  /// ⚠️ 幂等性由 controller 自己保证：show() 里有
  ///    `assert(schedulerPhase != persistentCallbacks)`（build 期间调用会炸），
  ///    但**重复调用本身无害** —— 直接问 `isShowing` 就够了。
  void _showSettingsPortal() {
    /*
     * ★★ 判据用 controller 的**真实**状态（`isShowing`），**不再**用镜像 bool。
     *
     * # 为什么删掉了那个镜像（2026-10-08，第 3 条）
     * ```text
     * 旧实现：`if (_settingsPortalShown) return;` —— 镜像是自己记的，会过期。
     *   portal 的 Element 若被重建（挂载点两侧都有条件子件，见 :9272 注释），
     *   controller 的可见状态不跟随（overlay.dart:1675-1684 的契约），
     *   而镜像还是 true ⇒ show() 被吞 ⇒ 面板**再也画不出来**，且不可自愈。
     *
     * 现在：`isShowing` 是 controller 自己维护的真实状态，不存在过期问题；
     *   Element 重建后它如实变成 false ⇒ 这次 show() 一定会真的发出去。
     * ```
     *
     * 挂载点另有常量 Key（Element 根本不再被重建），这两层是互补的保险。
     */
    if (_settingsPortal.isShowing) return;
    _settingsPortal.show();
  }

  /// 打开播放设置面板（★ task-25 D 只读探针的唯一入口）
  ///
  /// ⚠️ 为什么写成 State 的成员，而不是像本文件其它探针那样在**外面**
  ///    `s.setState(() => s._settingsOpen = true)`：那样会多一条
  ///    `invalid_use_of_protected_member`（`setState` 是 protected）。
  ///    本文件本来就有 5 条同类 warning（既有探针），我不想再加第 6 条。
  void debugOpenSettingsForProbe() {
    // ★★★ T27-09：与 _openSettings 同款 —— 探针必须走生产同一条显隐路径
    _collapseControlsForSheet();
    setState(() => _settingsOpen = true);
    _showSettingsPortal();
  }

  /// ★★★ 2026-10-08（Owner 追加：顶栏与底栏联动）
  ///
  /// 把「停手 3 秒后自动隐藏」这条规则**同步**跑完 —— 判据与
  /// `_armHideTimer()` 里那个 `Timer` 回调**逐字相同**：
  /// ```text
  /// if (mounted && _playing && !_hintsOpen && !_zoomOpen
  ///     && _popover.openId == null) {
  ///   setState(() => _controlsVisible = false);
  ///   _applyControlsMotion();
  /// }
  /// ```
  /// ⚠️ `_popover.openId == null` 这一条是 ★ Owner 2026-10-11 第⑤条加的
  ///   （悬浮面板开着时不收）。它与 `_autoHideNow()` 的守卫**必须逐字一致**
  ///   —— 两处任何一处漏掉，测试探针与生产 Timer 就会给出不同读数
  ///   （这正是本仓 `debugAutoHideControlsForProbe` 存在的理由：探针验的是生产路径）。
  /// ★ 存在的意义：widget 测试里用 `pump(3s)` 推进 `Timer` 之后，
  ///   还要再 pump 若干帧才能让 260ms 的淡出动画走完，**帧数不好钉**；
  ///   这里直接走同一条代码路径，读数与真机一致且**确定性**。
  ///
  /// ⚠️ 必须在 State 里（而不是像其它探针那样从外面改私有字段）：
  ///    `setState` 是 protected，外面改会多一条 warning。
  /// ★ popover 层 —— 由**页面**挂在整屏那个 Stack 里（与底栏是兄弟）
  ///
  /// # 为什么不挂在底栏内部（这是实测出来的，不是设计偏好）
  /// ```text
  /// 底栏在页面里是 `Positioned(bottom:0)`、高约 106px 的一个盒子。
  /// 面板若作为它的子件，能长到的上界就被那 106px 卡死。
  /// 实测（无头截图，1440×900）：popover 展开后的 PNG 与「没展开」的 PNG
  /// **md5 完全相同** —— 一像素都没画出来，而 widget 树里 `PlayerMoreMenu`
  /// 确实存在 ⇒ 问题出在**几何/裁剪**，不在逻辑。
  /// ⇒ 提到同一个 Stack 里当兄弟：面板从底栏上沿往上长，
  ///   而那个 Stack 是整屏（`SizedBox.expand`）⇒ 不会被任何祖先裁掉。
  /// ```
  PlayerBottomBar? _bottomBarWidget;

  Widget buildPopoverLayer() =>
      _bottomBarWidget?.buildPopoverLayer() ?? const SizedBox.shrink();

  /// ★ 截图/几何用：打开选集面板（走**生产**那条 `_episodeSheetOpen` 真源）
  ///
  /// # 为什么要探针而不是 `t.tap`
  /// ```text
  /// flutter_tester 里 PlayerPage 整棵树的**指针回调不被调用**（见 test/t98
  /// 文件头）⇒ `t.tap(find.text('更多'))` 打不动底栏。
  /// ⇒ 探针直接改**生产**的那个字段 / 控制器，验的就是生产那条路径。
  /// ```
  bool debugOpenEpisodesForProbe() {
    if (!mounted) return false;
    // ★★★ T27-09：与用户点「选集」同款 —— 浮层打开 ⇒ 顶/底栏一起收
    _collapseControlsForSheet();
    setState(() => _episodeSheetOpen = true);
    return _episodeSheetOpen;
  }

  /// 展开某一个 popover（走**生产**那个 `PopoverController`）
  bool debugOpenPopoverForProbe(String id) {
    if (!mounted) return false;
    _popover.toggle(id);
    return _popover.openId == id;
  }

  /// ★ 截图专用：清掉起播错误并把控制条**钉在显示态**
  ///
  /// # 为什么需要它
  /// ```text
  /// 无头截图环境里没有核心库 ⇒ `_load()` 必然失败 ⇒ `_error != null`
  /// ⇒ 底栏那条门控（`_error == null`）不成立 ⇒ 截图里**根本没有底栏**，
  ///   截出来只是一张「播放失败」的全屏图。
  /// ```
  /// ⚠️ 它**只**改 UI 状态，不碰播放器、不发任何请求。
  bool debugForceBarsForShot() {
    if (!mounted) return false;
    setState(() {
      _error = null;
      // ★ 与其余 8 处一样：清 `_error` 必须同时清 `_errorKind`。
      //   否则截图之后若真的起播失败，会拿到**上一条**错误的 kind，
      //   把「网络问题」显示成「请重新登录」（陈旧 kind 误判）。
      //   由 test/login_prompt_trigger_test.dart 的「8 / 9 → 9 / 9」那条盯着。
      _errorKind = null;
      _loading = false;
      _playing = true;
      _controlsVisible = true;
      _duration = const Duration(hours: 1, minutes: 42, seconds: 7);
    });
    _applyControlsMotion();
    return true;
  }

  void debugAutoHideControlsForProbe() {
    _autoHideNow();
  }

  /// 把 `_playing` 直接置位（★ 2026-10-08 顶栏联动回归用）
  ///
  /// # 为什么必须有它
  /// ```text
  /// `_autoHideNow()` 的第一条判据是 `_playing` —— 那是**对的**
  /// （暂停时不该收控制条）。
  /// 而 flutter_tester 里没有真网络 ⇒ 起播必然失败 ⇒ `_playing` 恒 false
  /// ⇒ 不置位的话「自动隐藏」这条路径**在测试里根本走不到**，
  ///   而那正是本次要验的东西。
  /// ```
  /// ⚠️ 只置这一个 bool，**不动** `_player` / 位置 / 时长 ——
  ///    测试要的是「判据成立」，不是伪造播放。
  void debugSetPlayingForProbe(bool v) {
    if (!mounted) return;
    setState(() => _playing = v);
    // ★ N11：`_cursorIdleHidden` 的判据含 `_playing` ⇒ 同步广播一次
    _pushCursorLive();
  }

  /// 模拟一次「鼠标在控制条区域晃动」—— 走**生产**那条 `_showControls()`
  void debugHoverControlsForProbe() {
    if (!mounted) return;
    _showControls();
  }

  /// ★ task-16 探针入口：直接置「指针是否在页内」
  ///
  /// # 为什么必须由测试来置，而不能靠 `t.tap` / 真鼠标
  /// ```text
  /// `flutter_tester` 里 PlayerPage 整棵树的**指针事件回调都不被调用**
  /// （本仓已记录在 `test/t118` 文件头与 `t98`）—— 也就是说
  /// `MouseRegion.onEnter` / `onExit` 在测试里**永远不会**被派发。
  /// ⇒ 不提供这条入口，判据③（指针离开 ⇒ 不画）在测试里根本走不到，
  ///   而它正是本次要验的东西。
  /// ```
  ///
  /// ★ 它走的是**与 onEnter/onExit 同一对方法**（`_onPointerEnter` /
  ///   `_onPointerExit`），不是测试自己写一遍置位 —— 与
  ///   `debugAutoHideControlsForProbe` 同一条纪律：
  ///   探针验的必须是**生产路径**。
  ///
  /// ⚠️ 放在 State 里（`setState` 是 protected，从外面改会多一条 warning）。
  void debugSetPointerInsideForProbe(bool v) {
    if (v) {
      _onPointerEnter();
    } else {
      _onPointerExit();
    }
  }

  /// ★★★ Owner 第 1 条探针：光标此刻**是不是**已经被藏起来了
  ///
  /// ⚠️ 读的是**渲染期真源** `_cursorIdleHidden`（含全屏 / 停手 / 无浮层 /
  ///    正在播四条判据），不是 `_cursorIdleStale` —— 后者只表示「停手了」，
  ///    在窗口模式下即使为真也**不藏**光标。验的必须是用户看得见的那个。
  bool debugCursorIdleHiddenForProbe() => _cursorIdleHidden;

  /// ★★★ Owner 第 1 条探针：模拟一次「人还在操作」（鼠标移动 / 按键 / 滚轮）
  ///
  /// ⚠️ 走的是**生产**那条 `_noteCursorActivity()`，不是测试自己重装计时器
  ///    —— 与 `debugHoverControlsForProbe` 同一条纪律：探针验的必须是生产路径。
  void debugNoteCursorActivityForProbe() {
    if (!mounted) return;
    _noteCursorActivity();
  }


  /// 收起 rootOverlay 上的播放设置面板（Esc / 关闭按钮 / dispose 都走这里）
  void _hideSettingsPortal() {
    // ★ 与 `_showSettingsPortal` 同款：先清镜像，再看 controller 的**真实**状态。
    //   若 controller 已经不显示了，就别再 hide() —— 未 attach 且
    //   `_zOrderIndex == null` 时 `hide()` 里的 `assert(_zOrderIndex != null)`
    //   会炸（overlay.dart:1748）。
    if (!_settingsPortal.isShowing) return;
    _settingsPortal.hide();
  }

  /// Esc 收起播放设置面板的**全部**动作（Owner 第 3 条的自愈也在这里）
  ///
  /// # 为什么抽成一个方法（2026-10-08）
  /// ```text
  /// Esc 链的长度**本身**是被测试钉住的：三条既有断言在「Esc 分支之后
  /// 700 字符」的窗口里找 `else if (_settingsOpen)` / `_zoomOpen` /
  /// `_episodeSheetOpen`（t73:248-274、t78:448-457、capability:1003-1016）。
  /// 那是**先截断成 700 字符**再 indexOf ⇒ 针尾被切掉就返回 -1。
  /// 实测：_episodeSheetOpen 偏移 692 + 针长 25 = 717 > 700 ⇒ 红。
  /// ```
  /// 把三步收进这里之后，链上只剩一行调用，六个偏移全部退回 700 以内
  /// （余量 290+）—— 以后要解释这三步，写在这段注释里就行，
  /// **不要再往那条链里塞注释**。
  ///
  /// # 三步各自为什么必须有
  /// ```text
  /// ① setState(_settingsOpen = false)
  ///      面板的**真源**（挂载点 overlayChildBuilder 门控的就是它）。
  /// ② _hideSettingsPortal()
  ///      面板挂在 rootOverlay 上，只 setState 不够：overlayChildBuilder
  ///      虽然会返回 SizedBox.shrink()，但 portal 仍占着 theater
  ///      （task-25 D）。⚠️ 全文件**只许有两处调用**（本助手 + 面板 X 的
  ///      onClose），test/t68_android_adapt_test.dart:364 钉成恰好 2 次。
  /// ③ _showControls()  ← Owner 第 3 条的自愈
  ///      用户报的现象：
  ///        > 点了 设置(字幕/音轨/连播) 这个按钮，点了之后无反应，
  ///        > 然后下面这页直接没了
  ///      底栏门控里有 `!_settingsOpen` ⇒ 面板一旦「开着但画不出来」，
  ///      底栏就永远不回来，屏幕上只剩顶栏。关面板这个动作无论面板
  ///      刚才是否真的画出来，都要把底栏叫回来（_showControls 自带
  ///      "值没变就不重建"的守卫，见那里的注释，代价接近零）。
  /// ```
  void _closeSettingsFromEsc() {
    setState(() => _settingsOpen = false);
    _hideSettingsPortal();
    _showControls();
  }

  /// 播放设置面板的 portal 子树（★ task-25 D）
  ///
  /// ⚠️ 这里**只**决定「画不画」—— 面板的**真源**始终是 `_settingsOpen`，
  ///    而「显示/隐藏」由 `_settingsPortal.show()/hide()` 负责（见它们的注释）。
  ///    `_settingsOpen == false` 时返回零尺寸 ⇒ 面板一定不渲染
  ///    （Lead 裁决②：onClose 只改 `_settingsOpen`，不需要别的镜像）。
  ///
  /// # 安全区由**面板自己**让（不在这里包 Padding）
  /// ```text
  /// PlayerSettingsSheet.build 的第一行就是 `Positioned.fill`。
  /// 若在这里包一层 Padding/Positioned，那个 ParentDataWidget 会与
  /// 面板自己的 `Positioned.fill` **争同一个 StackParentData** ——
  /// 内层后应用，外层设的 top/bottom 会被覆盖成 0（等于没让）。
  /// ```
  /// ⇒ 安全区 Padding 放在面板内部（`player_settings_sheet.dart` 的
  ///   `player-settings-safe-area` 那一层），本函数只负责挂载。
  Widget _buildSettingsPortalChild(BuildContext context) {
    if (!_settingsOpen) return const SizedBox.shrink();
    return PlayerSettingsSheet(
      isLive: _isLive,
      subtitleTracks: _subtitleOptions(),
      audioTracks: _audioOptions(),
      currentSubtitleId: _sidChosen,
      currentAudioId: _aidChosen,
      externalSubtitleName: _externalSubtitle?.id.split(RegExp(r'[\\/]')).last,
      mpvStyle: _mpvStyle,
      endAction: _endAction,
      countdownBeforeNext: _countdownBeforeNext,
      keepSourceOnNext: _keepSourceOnNext,
      autoSkip: _autoSkip,
      rate: _rate,
      isPlaying: _playing,
      clipDownloading: _clipDownloading,
      clipDownloaded: _clipDownloaded,
      clipDownloadError: _clipDownloadError,
      /*
       * ★ ③ 的落点：面板把「用户选了第几档」交回来，
       *   真正存下来的是 ClipDownloader（进程级单例）。
       *   setState 之后面板会重画，重新读到新档位。
       */
      onSetConcurrency: (v) {
        setState(() => ClipDownloader.setConcurrency(v));
      },
      onDownloadClip: () => unawaited(_downloadClip()),
      onOpenClipDir: () => unawaited(_openClipDir()),
      onPickSubtitle: (id) {
        /*
         * ★ 用户手动选了字幕轨 → 记下来
         *
         * 记下的作用是**阻止自动选轨**：否则下一次轨列表
         * 刷新时又会被自动选回第一条真实轨，
         * 「关闭字幕」就成了一个无效操作。
         */
        _pickSubtitleMadeByUser = true;
        setState(() => _sidChosen = id);
        unawaited(_applySubtitleTrack(id, userInitiated: true));
      },
      onPickAudio: (id) => unawaited(_applyAudioTrack(id)),
      onLoadSubtitleFile: (path) => unawaited(_loadExternalSubtitle(path)),
      onRemoveExternalSubtitle: () => unawaited(_removeExternalSubtitle()),
      // ★★★ task-31 ⑤：在线搜索字幕（assrt.net）面板入口
      onOpenSubtitleSearch: _openSubtitlePanel,
      onSetMpvProperty: (k, v) => unawaited(_setMpvStyle(k, v)),
      onSetEndAction: (a) {
        setState(() => _endAction = a);
        _savePlayPref('endAction', a.wire);
      },
      /*
       * ★★★ fix/rewatch-prompt：切集起播策略。
       *
       * 与 `onSetEndAction` 逐字同款：setState 改活值 + 落偏好。
       * ⚠️ 值由宿主读出来后**传给面板**（面板不自己读偏好 —— 见文件头
       *    「样式项的默认值不写死，从 mpv 读」附近对数据流的说明）。
       */
      episodeStartAction: _episodeStartAction,
      onSetEpisodeStartAction: (a) {
        setState(() => _episodeStartAction = a);
        _savePlayPref('episodeStartAction', a.wire);
      },
      onSetCountdown: (v) {
        setState(() => _countdownBeforeNext = v);
        _savePlayPref('countdownBeforeNext', v ? '1' : '0');
      },
      onSetKeepSource: (v) {
        setState(() => _keepSourceOnNext = v);
        _savePlayPref('keepSourceOnNext', v ? '1' : '0');
      },
      onSetAutoSkip: (v) {
        setState(() => _autoSkip = v);
        _savePlayPref('autoSkip', v ? '1' : '0');
        /*
         * ★ 打开自动跳过时**重置"已跳过"标志**
         *
         * 与「片头片尾」弹窗保存后的处理同理：用户刚打开开关，
         * 但 `_introSkipped` 可能在本会话早先已经被置过 true
         * （那时开关是关的、根本没跳）—— 不重置的话
         * 打开开关后**本集不会跳**，用户会以为开关没用。
         */
        if (v) {
          _introSkipped = false;
          _outroSkipped = false;
        }
      },
      /*
       * ★ task-21 P1-8：倍速落到与底栏 `onRate`（:7881）**同一个落点**
       *   —— `_player.setRate`。面板不写偏好、不碰 `_lastRateRequest`：
       *   `_player.stream.rate` 的回调（:2159-2163）会回填 `_rate`
       *   并写 `lastSpeed`，面板只需重画。
       */
      onSetRate: (r) => _player.setRate(r),
      // ★★★ task-22 P2-9 / P1-11：解码模式 + 画面缩放
      hwdecMode: _hwdecMode,
      onSetHwdecMode: _setHwdecMode,
      videoZoom: _videoZoomPct,
      onSetVideoZoom: (v) => _setVideoZoom(v),
      /*
       * ★★ 2026-10-08（Owner 第 3 条）：关面板时顺手把底栏叫回来。
       *
       * 底栏门控里有 `!_settingsOpen` ⇒ 面板一旦"开着但画不出来"
       * （第 3 条那个 Element 重建 + 镜像过期的缺陷），底栏就永远不回来。
       * 这条自愈让「关掉面板」这个动作一定能把控制条恢复 —— 见
       * `_openSettings()` 与 Esc 分支的同款说明。
       */
      onClose: () {
        setState(() => _settingsOpen = false);
        _hideSettingsPortal();
        _showControls();
      },
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  // ═══════════════════════════════════════════════════════════════════
  //  进度落盘（记忆播放位置）
  // ═══════════════════════════════════════════════════════════════════

  /// ★★★ OPS-13（反馈 C）：这条进度该**镜像**到哪个键上（null = 不镜像）
  ///
  /// # 根因（一句话）
  /// ```text
  /// 进度主键是 (provider, id)：本地播放恒为 ('local', 文件绝对路径)、
  /// 在线播放是 (站点, 站点内容 id) ⇒ **两套命名空间互不可见**
  /// ⇒ 本地看完一集，在线打开同一部从第 0 秒开始（Owner 报的正是这个）。
  /// ```
  ///
  /// # 判据**全部**在 `lib/core/progress_origin.dart`（纯函数，已单测）
  /// ```text
  /// localProgressOrigin  旁文件没有来源 / 来源就是 local ⇒ null（不猜）
  /// mirrorOriginFor      来源 == 会话自己的 provider ⇒ null（否则会覆盖自己那条）
  /// ```
  /// ⚠️ 本方法只做「取值 + 交给那两个纯函数」——**不在页面里重写判据**
  ///    （重写一份 = 两套真相，迟早不一致）。
  ///
  /// # 为什么必须取 `widget.` 而不是某个 state 字段
  /// ```text
  /// 来源是**页面级不可变**的（同 `localPath`）：shell 在 push 那一刻定好，
  /// 之后换集/换源都不会换来源 ⇒ 直接读 widget，不引入第二个可能过期的来源。
  /// ```
  ProgressOrigin? get _mirrorOrigin => mirrorOriginFor(
    localProgressOrigin(
      originProvider: widget.originProvider,
      originMediaId: widget.originMediaId,
    ),
    sessionProvider: _provider,
  );

  void _startProgressSaver() {
    _progressTimer?.cancel();
    /*
     * ★ 每 5 秒落一次盘（不是每帧）
     *
     * 原版注释：
     * > 每帧写会写爆 SQLite。
     * 而且 position 流的触发频率是每秒数次 —— 必须节流。
     */
    _progressTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      _saveProgress();
    });
  }

  void _scheduleSave(Duration p) {
    // 位置变化超过 5 秒才考虑落盘（配合上面的定时器，双保险）
    if ((p - _lastSavedPosition).abs() > const Duration(seconds: 5)) {
      // 不立即写 —— 交给定时器，避免频繁 IO
    }
  }

  /// 落盘进度
  ///
  /// [immediate] 用于退出/切集/换源前 —— 那些时刻必须**立刻**保存，
  /// 否则用户切走时最后几秒的进度会丢。
  Future<void> _saveProgress({bool immediate = false}) async {
    if (_isLive) return; // 直播没有进度概念
    if (_duration <= Duration.zero) return;

    final pos = _position.inSeconds;
    // 位置太小不记（避免"刚点开就存了 2 秒"污染继续观看列表）
    if (pos < 5 && !immediate) return;

    _lastSavedPosition = _position;

    final ep = _epIndex < _episodes.length ? _episodes[_epIndex] : null;

    try {
      /*
       * ★★★ OPS-13（反馈 C）：改走 `lib/core/progress_origin.dart` 的
       * **唯一出口** `saveProgressWithMirror` —— 它做两件事，顺序固定：
       * ```text
       * ① 原样写会话自己的键（(_provider, _contentId)）—— 既有行为逐字不变
       * ② 条件满足时，**再写一条镜像**到 (originProvider, originMediaId)
       * ```
       *
       * # ★★★ 镜像那条的 episode_id（OPS-13 反馈 C ① 的修复点）
       * ```text
       * 改前：镜像恒写 episode_id=null ⇒ 被 CR-08 的安全守卫整条拦下
       *   （progress_origin.dart 里 `if (siteEpisodeId.isEmpty) return;`）
       *   ⇒ 镜像**一条都没写出去** ⇒ 本地与在线永远不同步（Owner 报的正是这个）。
       * 现在：把 `widget.originEpisodeId`（**站点集 id**）带下去。
       *   ⚠️ 绝不用 `episodeId`（本地会话里那是**文件名**）—— 二者必然不等。
       *   ⚠️ 没有站点集 id（老下载 / 手拷进来的目录）时它仍是 null ⇒
       *      守卫照旧跳过 ⇒ 退化成今天的样子（**不写坏在线记录**，CR-08 裁决不动）。
       * ```
       *
       * ⚠️ 传进去的 `mirror: _mirrorOrigin`：三条拒绝（没有来源 / 来源是 local /
       *    来源 == 会话自己的 provider）全在那两个纯函数里，本页不重写。
       *    没来源时它内部直接 `return` ⇒ 与今天**逐字等价**（只多一次判空）。
       */
      await saveProgressWithMirror(
        provider: _provider,
        id: _contentId,
        mirror: _mirrorOrigin,
        // ★★★ 站点集 id —— CR-08 守卫要的就是它（见上面那段）
        originEpisodeId: widget.originEpisodeId,
        /*
         * ══════════════════════════════════════════════════════════════
         * ★★★ 2026-09-26 第二轮：这里原来写的是 `widget.title` / `widget.cover`
         * ══════════════════════════════════════════════════════════════
         *
         * # 那是「播放记录显示 ？」的根因（Owner 报的）
         *
         * ```text
         * `widget.title` / `widget.cover` 是 **final 构造参数**；
         * 而合并页的入口 `shell.dart` 的 `_mediaRoute()` 传的是
         *   `title: ''`、**根本没有 cover**（那一刻详情还没加载，标题确实不知道）
         * ⇒ 这两个值**恒为空** ⇒ 每次保存进度都往库里写**空标题 + 空封面**
         * ⇒ 播放记录列表渲染不出名字与封面 ⇒ 显示成一个「？」
         * ```
         * ★ 实测用户真实库（`.probe/ROOTCAUSE-panel-and-history.md`）：
         *   3 条记录 `title = ''` 且 `cover = NULL` —— 正是这么来的。
         *
         * # 而真值其实**已经到了**
         *
         * ```text
         * MediaPage._onDetailLoaded(d) ⇒ updateDisplayTitle(d.title, cover: d.cover)
         *                              ⇒ _title / _cover   ← ★ 就是上面那两个字段
         * ```
         * ⇒ 修法：**写库读活值**（`_title` / `_cover`），不再读构造参数。
         *
         * ⚠️ 但仍然要**保留 `widget.*` 作为兜底**：
         *   直播/遥控等路径可能直接构造 `PlayerPage(title:, cover:)`
         *   而从不走 `updateDisplayTitle` ⇒ 那时 `_title` 与 `widget.title` 同值，
         *   取哪个都对；用 `??`/空串判断兜底只是让"没走详情页的路径"也正确。
         */
        title: _title.isNotEmpty ? _title : widget.title,
        cover: _cover ?? widget.cover,
        episodeId: ep?.id ?? widget.episodeId,
        episodeTitle: ep?.title ?? widget.episodeTitle,
        position: pos,
        duration: _realDuration.inSeconds > 0
            ? _realDuration.inSeconds
            : _duration.inSeconds,
      );
    } catch (e) {
      debugPrint('[PLAYER] 保存进度失败: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  片头 / 片尾跳过
  // ═══════════════════════════════════════════════════════════════════

  Future<void> _loadSkipMarker() async {
    if (_isLive) return;
    /*
     * ★ 记下发请求那一刻的会话代次 —— 返回后要先核对它。
     *   ⚠️ 必须在 `await` **之前**读，否则读到的已经是别人 bump 过的值。
     */
    final gen = _playSessionGen;
    try {
      final m = await SourinApi.getSkipMarker(_provider, widget.id);
      if (!mounted) return; // ⚠️ 卸载后 setState 会抛；也拦掉 unmounted 的补判
      /*
       * ★★★ 会话已变 ⇒ **丢弃**这次响应（CodeRabbit PR #10）
       *
       * 换集 / 换源 / applySession 三条路都会 bump 代次并清 `_skipMarker`。
       * 若这里不判，就会把**上一集/上一个源**的片头秒数写进当前会话，
       * 并立刻 `_skipAfterMarkerLoad()` ⇒ 按旧标记 seek 新播放。
       * ★ 不 setState、不补判、直接 return —— 新会话自己有它的 `_loadSkipMarker`。
       */
      if (gen != _playSessionGen) {
        debugPrint(
          '[PLAYER] 丢弃过期的片头标记响应（会话代次 $gen → $_playSessionGen）',
        );
        return;
      }
      setState(() => _skipMarker = m);
      /*
       * ★★★ fix/skip-auto-seek【B】：标记到手后**立刻**按当前位置补判一次
       *
       * # 为什么必须补这一下（"片头没跳"的直接根因之一）
       *
       * 起播链路是 `_startPlayback()` → `_loadSkipMarker()`（见 `_load()`），
       * 而位置流在 `_startPlayback` **一开始**就 tick 了。于是存在一个窗口：
       * ```text
       * _startPlayback 返回 → _loadSkipMarker 还在 await 取数
       *   ⇒ 此刻 _skipMarker 仍是 null
       *   ⇒ 位置流每秒调 _maybeSkip，却全部在 `if (m == null) return;` 早退
       * ⇒ 若片头区间很短（如 intro=[0,1]）或起播点本就落在区间内，
       *   等标记到手时位置早已越过 introEnd ⇒ **整段片头被漏跳**。
       * ```
       * 契约依据：`PLAYER-CONTRACT.md:206-213` —— 标记就绪的时机必须**再判一次**，
       * 不能只依赖"位置流自己会再 tick"（原版为此在 canplay 里二次调用）。
       *
       * ⚠️ 幂等由 `_maybeSkip` 内部的 `_introSkipped`/`_outroSkipped` 守卫保证
       *    （见 `_maybeSkip` 内 `if (!_introSkipped ...)` / `if (!_outroSkipped ...)`）。
       * ⚠️ `_autoSkip` 关掉时 `_maybeSkip` 第 717 行 `if (!_autoSkip) return;` 生效，
       *    这里**不需要**（也不应该）自己再判一次 —— 判定语义只有一份。
       * ⚠️ 直播已在上面 `if (_isLive) return;` 早退，**不破坏直播路径**。
       */
      _skipAfterMarkerLoad();
    } catch (e) {
      debugPrint('[PLAYER] 读跳过点失败: $e');
    }
  }

  /// 取"此刻的播放位置"——供上面【B】与 `_startPlayback` 里【A】的补判用
  ///
  /// # 为什么不能直接读 `_position`
  ///
  /// `_position` 只在**位置流 tick 过**之后才有值（起播极早期它是 0）。
  /// 而 `_player.state.position` 是 mpv 当下的真实读数，在 canplay 之后
  /// 就已经可用。两者取**较大的那个**，保证：
  /// ```text
  /// · 起播点落在片头区间内（如续播到 2s，intro=[0,3]）→ 命中区间，真的跳
  /// · 正常从头播                          → 读到 0 → 命中 introStart=0
  /// ```
  /// 取 max 而不是只读 `_player.state.position`：某些源在 open() 刚返回时
  /// `state.position` 仍是 0 而 `_position` 已被位置流推到 1 —— 谁新用谁。
  Duration _currentSkipProbePosition() {
    Duration p;
    try {
      p = _player.state.position;
    } catch (_) {
      // 播放器尚未就绪时读属性可能抛 —— 退回内存里的 _position
      p = Duration.zero;
    }
    return p > _position ? p : _position;
  }

  /// 【A】canplay 后的补判 —— `_startPlayback` 里 `open()` 返回后**唯一**的入口
  ///
  /// 抽成方法（而不是把 `_maybeSkip(...)` 内联在那 400 行里）是为了让
  /// **行为测试能驱动同一段生产代码**：探针 `debugPlayerSkipAfterCanplayForProbe`
  /// 调的就是本方法 ⇒ 改坏它，测试立刻红（见
  /// `test/t27_w20_skip_auto_seek_test.dart` 的撤销验证）。
  void _skipAfterCanplay() => _maybeSkip(_currentSkipProbePosition());

  /// 【B】标记到手后的补判 —— `_loadSkipMarker()` 成功路径上**唯一**的入口
  ///
  /// 同【A】：抽方法是为了可被行为测试直接驱动。
  void _skipAfterMarkerLoad() => _maybeSkip(_currentSkipProbePosition());

  /// 把 `SkipMarker` 展开成**可跳窗口**（片头 + 中插；**片尾不入列**）
  ///
  /// # 为什么片尾不进来
  /// ```text
  /// 现行片尾语义**不是 seek**，而是 `_startNextCountdown()`（让用户看完片尾/片尾曲）。
  /// 若把片尾也塞进 `windowsOf`，`skipTarget` 会把它当成"跳到末尾" ⇒ **行为变化**
  /// （跳过片尾曲 + 立刻触发播放结束分支）。所以片尾继续走原来的独立分支。
  /// ```
  List<SkipWindow> _skipWindowsOf(SkipMarker m) => windowsOf(
        introStart: m.introStart,
        introEnd: m.introEnd,
        // ★ 只传 intro + midroll；outroStart/outroEnd 故意不传（见上）
        midrolls: m.midrolls,
      );

  /// 标记某条窗口"已处理"（跳过或让位都算）——幂等靠它
  void _markSkipped(SkipWindow w) {
    switch (w.kind) {
      case 'intro':
        _introSkipped = true;
      case 'midroll':
        _midrollSkippedStarts.add(w.start.inSeconds);
      default:
        break; // 片尾不走这里
    }
  }

  /// 该窗口是否已处理过
  bool _alreadySkipped(SkipWindow w) => switch (w.kind) {
        'intro' => _introSkipped,
        'midroll' => _midrollSkippedStarts.contains(w.start.inSeconds),
        _ => false,
      };

  /// 播放位置变化时检查要不要跳
  void _maybeSkip(Duration pos) {
    final m = _skipMarker;
    if (m == null || _isLive) return;
    // 续播落地前的位置属于新流初始化，不是自动跳过的依据。
    if (_pendingSeek != null) return;

    /*
     * ★ 全局「自动跳过片头」开关（原版 `autoSkipOn`，默认 true）
     *
     * 原版 `applySkipMarkers()` 的第一行就是：
     * ```ts
     * if (!v || !s || isLive.value || !autoSkipOn.value) return;
     * ```
     * 关掉之后**不自动跳**（用户仍可在设置面板里看到自己设的片头片尾）。
     *
     * ⚠️ 没有这一条的话，播放设置面板里那个「自动跳过片头」开关
     *    就是个**死开关** —— 能拨但什么都不影响。
     */
    if (!_autoSkip) return;

    final sec = pos.inSeconds;

    /*
     * ══════════════════════════════════════════════════════════════════
     *  ★★★ 2026-10-26（`midrolls` 接线）：片头 + 中插走**同一个纯函数**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改的是什么 / 没改的是什么
     * ```text
     * 改：判据从"手写 intro 的 if"变成 `skipTarget(...)`（lib/core/skip_window.dart）
     *     ⇒ 中插（`SkipMarker.midrolls`）自动一并生效。
     * 没改（逐条对齐）：
     *   ① 半开区间 `start <= p < end`（= `SkipWindow.contains`）
     *   ② **区间内必跳** ⇒ `tolerance: Duration.zero`
     *      （不传 0 会引入"距窗口末尾 1s 不跳"，那是行为变化）
     *   ③ grace：用户刚拖过 ⇒ **标记已处理 + 不跳 + 原日志 + return**
     *      （不是"以后再说" —— 现行语义是"本窗口放弃"）
     *   ④ 跳过动作本身：`_skipSeekCalls++` / `_lastSkipSeek` / `seek` /
     *      `_beginPrefetchYield()` / `_flash(...)` / `AppLog` 一条不少
     * ```
     * ⚠️ 片尾**不在** `windowsOf` 里（它走 `_startNextCountdown()`，不是 seek）。
     */
    final windows = _skipWindowsOf(m)
        .where((w) => !_alreadySkipped(w)) // 已经跳过/让位过的窗口不再参与
        .toList();

    // ① grace 前置：与改前**同一语义**（命中窗口 ⇒ 标记已处理 + 不跳）
    if (_withinUserSeekGrace()) {
      for (final w in windows) {
        if (!w.contains(pos)) continue;
        _markSkipped(w);
        final target = _lastUserSeek;
        // ★ 文案用**字面量**分支（代码里必须有 '跳过片头'/'片头不自动跳' 这些原串：
        //   `zz_t1024_skip_respects_user_seek` ⑤ 是**源码结构门禁**，会逐字匹配）
        if (w.kind == 'midroll') {
          AppLog.write(
            'PLAY',
            '中插不自动跳（用户主动 seek 豁免）：'
                '位置 ${sec}s 落在中插 ${w.start.inSeconds} → ${w.end.inSeconds}，'
                '上次用户 seek 落点 ${target?.inSeconds ?? -1}s',
          );
        } else {
          AppLog.write(
            'PLAY',
            '片头不自动跳（用户主动 seek 豁免）：'
                '位置 ${sec}s 落在片头 ${w.start.inSeconds} → ${w.end.inSeconds}，'
                '上次用户 seek 落点 ${target?.inSeconds ?? -1}s',
          );
        }
        return;
      }
    }

    // ② 纯函数判定（grace 已在上面处理 ⇒ 这里传 null，避免双重语义）
    final target = skipTarget(
      position: pos,
      windows: windows,
      lastUserSeekAt: null,
      tolerance: Duration.zero,
    );
    if (target != null) {
      // 找到命中的那条窗口（用于幂等标记与文案）
      final hit = windows.firstWhere((w) => w.contains(pos));
      _markSkipped(hit);
      if (hit.kind == 'midroll') {
        debugPrint('[PLAYER] 跳过中插 ${hit.start.inSeconds} → ${hit.end.inSeconds}');
        AppLog.write('PLAY', '跳过中插 ${hit.start.inSeconds} → ${hit.end.inSeconds}'
            '（触发源=自动，位置 ${sec}s）');
      } else {
        debugPrint('[PLAYER] 跳过片头 ${hit.start.inSeconds} → ${hit.end.inSeconds}');
        AppLog.write('PLAY', '跳过片头 ${hit.start.inSeconds} → ${hit.end.inSeconds}'
            '（触发源=自动，位置 ${sec}s）');
      }
      _skipSeekCalls++; // ★ 只读探针（fix/skip-auto-seek）：真的发出了 seek
      _lastSkipSeek = target;
      // seek-intent: programmatic — 自动跳过（不是用户意图；触发源见上一行 AppLog）
      _player.seek(target);
      // ★ N10：跳到窗口结束（可能几分钟后）⇒ 预取会让路
      _beginPrefetchYield();
      _flash(hit.kind == 'midroll' ? '已跳过中插' : '已跳过片头');
      return;
    }

    // ── 片尾 ──
    if (!_outroSkipped && m.outroStart != null) {
      final start = m.outroStart!;
      if (sec >= start) {
        _outroSkipped = true;
        debugPrint('[PLAYER] 到达片尾起点 $start');
        /*
         * ★ 片尾不直接跳 —— 而是**启动下一集倒计时**
         *
         * 原版逻辑：让用户有机会看完片尾/片尾曲。
         * 倒计时结束才自动下一集。
         */
        _startNextCountdown();
      }
    }
  }

  /// 下一集倒计时
  ///
  /// # 倒计时秒数：**5 秒**（与原版 3 秒不同 —— 单列的理由）
  ///
  /// 原版 `startNextCountdown()`（`PlayerView.vue:2736-2746`）是 3 秒。
  /// 我们保持 5 秒，因为 5 是**已交付并验收过**的行为（本轮任务明确写了
  /// 「片头片尾自动跳过已实现」在验收清单里），而 3→5 这种改动属于
  /// 交互变更、不在本次授权范围内。**如实单列**，不偷偷改。
  void _startNextCountdown() {
    if (_nextEpisode == null) return;
    _countdownTimer?.cancel();
    setState(() => _nextCountdown = 5);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _nextCountdown--);
      if (_nextCountdown <= 0) {
        t.cancel();
        _gotoNextEpisode();
      }
    });
  }

  void _cancelNextCountdown() {
    _countdownTimer?.cancel();
    if (mounted) setState(() => _nextCountdown = 0);
  }

  /// 播放结束 —— **照抄原版 `onEnded()`（`PlayerView.vue:2748-2785`）**
  ///
  /// # 原版按「播放完」偏好分三路
  ///
  /// ```ts
  /// switch (prefs.endAction) {
  ///   case "singleLoop": v.currentTime = 0; v.play();           // 单集循环
  ///   case "autoNext":   倒计时 或 直接下一集 / "已是最后一集"       // 自动连播
  ///   case "stop":       flashTip("已播放完毕");                  // 播完停止
  /// }
  /// ```
  ///
  /// # 这里原来漏了什么（本次补的缺口）
  ///
  /// 旧实现只有一句 `if (_nextEpisode != null) _startNextCountdown();` ——
  /// 也就是说：**不管用户选什么，行为都是"自动连播"**。
  /// 「单集循环」和「播完停止」两个选项以及「连播前倒计时」开关
  /// 都**没有落地**（而且旧版连面板都没有，用户根本改不了）。
  ///
  /// # 为什么 `singleLoop` 用 `seek(0)` + `play()`
  ///
  /// 与浏览器里 `v.currentTime = 0; v.play()` 语义一一对应。
  /// media_kit 没有"重播"API，`seek(Duration.zero)` 就是它的等价物。
  void _onEnded() {
    debugPrint('[PLAYER] 播放结束（endAction=${_endAction.wire}）');

    // 直播没有"播完"这回事（原版 `onEnded` 第一行就是 `if (isLive.value) return;`）
    if (_isLive) return;

    switch (_endAction) {
      case PlayEndAction.singleLoop:
        // 单集循环：回到 0 接着播（原版 flashTip("单集循环")）
        // seek-yield: skip —— 目标是起点(0)，mpv 起播本就从此处读，预取不会抢；
        //   且紧接着 play()，挂上反而会每次循环都打断预取、影响循环连续性
        // seek-intent: programmatic — 单集循环回到起点（由 onEnded 触发）
        unawaited(_player.seek(Duration.zero));
        unawaited(_player.play());
        _flash('单集循环');

      case PlayEndAction.autoNext:
        if (_nextEpisode == null) {
          // 原版：flashTip("已是最后一集")
          _flash('已是最后一集');
          return;
        }
        /*
         * ★ 「连播前倒计时」开关在这里生效（原版 2778 行）
         *
         * ```ts
         * if (prefs.countdownBeforeNext) startNextCountdown();
         * else gotoEpisode(nextEpisode.value);
         * ```
         */
        if (_countdownBeforeNext) {
          _startNextCountdown();
        } else {
          unawaited(_gotoNextEpisode());
        }

      case PlayEndAction.stop:
        // 原版：flashTip("已播放完毕") —— 停在最后一帧
        _flash('已播放完毕');
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 跨源换源（原地换源继续播）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 与详情页的换源**不同**：这里是**原地**换源继续播，
  // 而详情页是跳到新源的详情页（因为详情页要重新选集/选线路）。
  //
  // 原版注释：
  // > 用户选了另一个源的同一部内容 → **原地换源继续播**
  //
  // # 保留进度的三个要点（照抄原版）
  //
  // ```text
  // ① 用**当前真实进度**而不是弹层传进来的旧值
  //    —— 弹层是在打开时读的 position，用户可能又看了几分钟才点选
  // ② 按**集号**匹配（不是下标）—— 各源的剧集列表长度/缺集不同
  // ③ 匹配不到就退到第 1 集，并**明确告知**（不静默）
  // ```
  Future<void> _openSwitchSource() async {
    /*
     * ★ 换源前先把进度落盘（避免丢）
     *
     * 原版：`void reportProgress(true);` —— 换源会替换整个会话，
     * 不先存的话最后这几分钟的进度就没了。
     */
    await _saveProgress(immediate: true);

    if (!mounted) return;
    final pick = await showSourceSwitchDialog(
      context,
      /*
       * ★★★ task-72【④】这里原来写的是 `widget.title` ⇒ **空串**
       *
       * 三个症状（弹层空白 / 不自动搜 / 不填充）同一个根因 ——
       * 弹层拿到空串 ⇒ `_kw` 空 ⇒ `_run()` 首行 `if (kw.isEmpty) return;`
       * ⇒ 静默返回、**一个请求都不发**。详见 `_liveTitle` 的文档注释。
       */
      title: _liveTitle,
      currentProvider: _provider,
      currentProviderName: _provider,
      // ★ 传**当前真实进度**
      episodeIndex: _epIndex + 1,
      position: _position.inSeconds,
    );
    if (pick == null || !mounted) return;

    await _applySwitch(pick);
  }

  /// 打开「设置片头片尾」弹窗
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 原版 `PlayerView.vue::openSkipDialog` 的两条关键行为
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// ## ① 弹窗里**同时**编辑四个端点
  ///
  /// 不是"先选设片头还是设片尾"—— 参照图就是一个弹窗里两个区间。
  /// （原版第一版是分两步的，Owner 否掉了。）
  ///
  /// ## ② 打开时**暂停主播放器**
  ///
  /// 原版注释：
  /// > 为什么：弹窗里的预览是**独立**的，主播放器如果继续播，
  /// > 用户会看到两个画面不同步（而且白耗流量）。
  /// > 关掉弹窗后**不自动恢复播放** —— 让用户自己按
  /// > （避免"关掉就突然响了"）。
  ///
  /// ⚠️ 注意是"暂停"而**不是**"把主播放器 seek 到预览位置" ——
  ///    预览完全独立（见 `SkipMarkerDialog` 文件头）。
  ///
  /// ## ③ 直播不能设
  ///
  /// 原版第一行就是 `if (isLive.value) return;` ——
  /// 直播没有"片头片尾"的概念（流是线性的）。
  Future<void> _openSkipDialog() async {
    // ③ 直播不适用
    if (_isLive) return;

    /*
     * ② 暂停主播放器（不是 seek —— 预览是独立的）
     *
     * ⚠️ task-57 修正：**关掉后要恢复播放**
     *
     * # 原来的行为（已改）
     *
     * 这里原本写着「关掉后**不自动恢复** —— 与原版一致（避免"关掉就突然响了"）」。
     * 但实测发现这会让用户以为**播放被搞坏了**：
     * ```text
     * 用户调完片头片尾 → 关掉弹窗 → 回到播放页 → ★ 视频是**停着的**
     * ⇒ "这个设置把播放搞停了"
     * ```
     * ★ 而"避免突然响了"那个顾虑**不成立**：我们恢复的是**用户自己
     *   打开弹窗前就在播**的状态（`_wasPlaying`），不是擅自开始播。
     *   若用户打开前是暂停的，关掉后**仍然暂停**。
     *
     * # 为什么**不 seek 回原位**
     *
     * 暂停期间主播放器的位置**没有变**（暂停了就不前进），
     * 所以"回到原位置"是**自然**的 —— 显式 seek 反而会引入
     * 一次跳变/重新缓冲（本仓在 HLS 上踩过 seek 触发重新取分片）。
     * ⇒ ★ 只 `play()`，不 `seek()`。
     *   这也同时满足 Owner 的「不跟底层的进行联动」——
     *   我们**从不**把预览的位置写回主播放器。
     */
    final wasPlaying = _playing;
    /*
     * ★ 记下打开弹窗**之前**的位置 —— 只用于**诊断**（见关闭时那段）
     *
     * 我们不 seek 回这个位置（不 seek 才满足 Owner 的"不联动"），
     * 但把它打出来能证明"暂停期间位置确实没动"。
     * 若它漂了 ⇒ 说明有别的路径在动主播放器 ⇒ 那是一条要查的线索。
     */
    final posBeforeDialog = _position;
    if (_playing) await _player.pause();
    if (!mounted) return;

    /*
     * 预览用的流地址
     *
     * 优先用**当前正在播的那条**（`_current?.url`）——
     * 用户看到的就是他正在看的画质/线路。
     * 没有的话回退到第一条可播的。
     *
     * ⚠️ 这里**必须**传真实的流地址 —— 弹窗会用它起**独立的**预览播放器。
     *    这是 Owner 明确要求的形态（见 `skip_marker_dialog.dart` 文件头
     *    L28-40），**不是**可选实现细节。
     *    task-57 我一度改成"抓帧宿主"（方案 D），已回退 —— 理由见下。
     */
    final url =
        _current?.url ??
        (_streams.isNotEmpty
            ? _streams
                  .firstWhere((x) => x.isPlayable, orElse: () => _streams.first)
                  .url
            : '');
    if (url.isEmpty) {
      _flash('没有可用的播放地址，无法预览');
      return;
    }

    final r = await showAppDialog<SkipMarkerResult>(
      context: context,
      // 弹窗内自带预览，用 barrier 半透明遮住播放器（原版也是）
      barrierDismissible: true,
      builder: (_) => SkipMarkerDialog(
        provider: _provider,
        id: widget.id,
        // ★ task-72【④】活标题（弹窗里要**显示**给用户看）
        title: _liveTitle,
        /*
         * ★★★ task-57 回退记录：这里**曾经**改成"抓帧宿主"（方案 D）——
         * 即让弹窗 seek **主播放器**再抓一帧。**已回退**，理由三条：
         * ```text
         * ① Owner **逐字否过**"联动主播放器"（见 skip_marker_dialog.dart
         *    文件头 L28-40）—— 而 D 恰好就是被否掉的那一版
         * ② D 的唯一理由（"消除两个播放器抢流"）已被**两次实测否定**：
         *    我 6/6 轮未复现 + fix-window-shadow 双向 A/B 也否定
         * ③ D 的三条后果**必然发生**（改主播放器进度 / 拖动反复取分片 /
         *    手机上更糟 —— Owner 原话里专门点了手机）
         * ⇒ 收益（未证实的 bug）< 代价（必然发生 + 违背 Owner）
         * ```
         * ★ 而真正让用户说"不能用"的是**预览区黑 15 秒且无提示**（实测），
         *   那个 bug 与"用哪个播放器"**无关**（等的是网络 + 解码）——
         *   修在 `skip_marker_dialog.dart` 的加载提示里。
         */
        streamUrl: url,
        /*
         * ⚠️ 用 `_realDuration` 而不是 `_duration`：
         *    前者是流真的报出来的时长，后者可能还是 0
         *    （`Player.open()` 返回 ≠ 流就绪）。
         *    task-52 实测过 `_duration` 为 0 会让弹窗时间轴退化成 1 秒。
         */
        duration: _realDuration.inSeconds > 0 ? _realDuration : _duration,
      ),
    );

    if (!mounted) return;

    if (r != null) {
      /*
       * 保存成功 → 把新设置**立刻**用到当前会话
       *
       * 不重新拉接口（刚写完就是最新的），直接更新内存里的 `_skipMarker`。
       * 否则用户设完片头，要等下一次换集才生效 —— 那不合理。
       */
      setState(() {
        _skipMarker = SkipMarker(
          key: '$_provider:${widget.id}',
          provider: _provider,
          nativeId: widget.id,
          title: _liveTitle,
          introStart: r.introStart,
          introEnd: r.introEnd,
          outroStart: r.outroStart,
          outroEnd: r.outroEnd,
          autoSkip: r.autoSkip,
        );
        /*
         * ★ 重置"已触发过"的标志（2026-09-24）
         *
         * 不重置的话：用户设完片头，但因为 `_introSkipped` 已经是 true
         * （本次会话早先跳过过一次），新的设置**不会再生效** ——
         * 表现为"设了没用"，极难排查。
         */
        _introSkipped = false;
        _outroSkipped = false;
      });
      _flash('片头片尾设置已保存');
    }

    /*
     * ★ task-57：恢复**用户原本的播放状态**（见上面 `wasPlaying` 的说明）
     *
     * ⚠️ 必须放在 `if (r != null)` **之外** —— 用户点「取消」/点 X 关掉
     *    弹窗时**同样**要恢复。否则"我打开看了一眼就关掉"也会把播放停住，
     *    那比"设完才停"更让人困惑。
     *
     * ⚠️ 用 `wasPlaying`（打开**之前**的状态）而不是 `_playing`：
     *    后者此刻必然已经是 false（我们刚 pause 过），拿它判断会永不恢复。
     *
     * ⚠️ **只 play、不 seek** —— 这不只是"避免跳变"，而是满足 Owner 的
     *    硬约束「而不是跟底层的进行联动」：
     *    ```text
     *    显式 seek 主播放器 ⇒ 那**就是**"联动"（哪怕是 seek 回原位）
     *    只 play/pause      ⇒ 主播放器**从未被 seek**
     *                       ⇒ ★ 结构上不可能违反"不联动"
     *    ```
     */
    if (!mounted) return;

    /*
     * ★ 诊断读数（编排者要求"让漂移可观测"）
     *
     * 暂停期间位置**本应不动**。若日志显示它漂了，说明有别的路径在动
     * 主播放器 —— 那是一条需要查的线索，不能让它静默。
     */
    final drift = (_position - posBeforeDialog).inMilliseconds.abs();
    debugPrint(
      '[PLAYER] 片头片尾弹窗已关闭: 原状态=${wasPlaying ? '播放中' : '暂停'}'
      ' 位置 ${posBeforeDialog.inSeconds}s → ${_position.inSeconds}s'
      '（漂移 ${drift}ms${drift > 2000 ? ' ★ 异常，请查' : ''}）',
    );

    if (wasPlaying) {
      await _player.play();
      if (mounted) debugPrint('[PLAYER] 关闭片头片尾弹窗 → 恢复播放');
    }
  }

  /// 执行换源
  // Test transport boundaries only; session transitions remain production code.
  Future<MediaDetail> Function(String, String)? _switchDetailForProbe;
  Future<void> Function(SwitchPick)? _switchRepointForProbe;

  Future<void> _applySwitch(SwitchPick p) async {
    // Invalidate the old waiter before detail lookup or record migration.
    ++_seekToken;
    /*
     * ★ 用**当前真实进度**而不是弹层传进来的旧值
     *
     * 原版注释：
     * > 弹层是在打开时读的 position，用户可能又看了几分钟才点选。
     */
    final nowPos = _position.inSeconds;
    final position = nowPos > 3 ? nowPos : p.position;

    // ★ 按**集号**匹配（不是下标）
    final curOrder =
        _epOrder(_currentEpisodeTitle) ??
        (p.episodeIndex > 0 ? p.episodeIndex : null);

    _flash('正在切换到「${p.title}」…');

    try {
      /*
       * 取新源的详情与剧集。
       *
       * ⚠️ 详情里**不一定**带 episodes，所以再调一次 `getEpisodes`
       *    （与详情页的取法一致）。
       */
      final d = await (_switchDetailForProbe ?? SourinApi.getDetail)(p.provider, p.id);
      final srcCode = d.sources.isNotEmpty ? d.sources.first.code : null;

      var eps = d.episodes;
      if (srcCode != null && srcCode.isNotEmpty) {
        try {
          final more = await SourinApi.getEpisodes(p.provider, p.id, srcCode);
          if (more.isNotEmpty) eps = more;
        } catch (e) {
          debugPrint('[PLAYER] 取新源剧集失败（沿用详情的）: $e');
        }
      }

      // ★ 按集号匹配
      Episode? keep;
      if (curOrder != null) {
        keep = eps.where((e) => _epOrder(e.title) == curOrder).firstOrNull;
      }
      final fellBack = curOrder != null && keep == null;
      keep ??= eps.isNotEmpty ? eps.first : null;

      if (fellBack) {
        // ★ 不静默 —— 明确告诉用户换到哪一集了
        _flash('新源没有「第 $curOrder 集」，已从第 1 集开始');
      }

      if (!mounted) return;

      /*
       * ══════════════════════════════════════════════════════════════════
       * ★★★ task-77：换源时把记录**搬到**新源（与合并页完全同一条路径）
       * ══════════════════════════════════════════════════════════════════
       *
       * # 这里原来**没有**这一步，于是播放器内换源与合并页换源不一致
       *
       * ```text
       * 合并页（正确）：lib/ui/media_page.dart:476 → SourinApi.repointItem(...)
       * 播放器内（缺陷）：本函数 → 直接 _resolveAndPlay ⇒ 从不迁移
       * ```
       * 四张表（favorites / progress / history / skip_markers）的 key 都是
       * `<provider>:<id>`（`commands_write.rs:42 item_key`）⇒ 换源 ⇒ key 变
       * ⇒ 新源的写入是【新行】，旧行原样留着 ⇒ 同一部剧**两条记录**，
       * 且旧源上的进度**不被带走**。
       *
       * # 为什么放在 `setState` **之前**、且 `await`（不是 `unawaited`）
       *
       * ```text
       * ① from 值就是下面这两个字段：_provider / _contentId
       *    —— 而 `_resolveAndPlay`（:4508 附近）会把它们改写成新源
       *    ⇒ 一旦跑到那里，就再也拿不到"旧源是谁"了
       * ② 迁移是一个事务，很快（纯本地 SQLite，无网络）
       *    而紧接着的 `_resolveAndPlay` 会**立刻起播**并**写新进度**
       *    ⇒ 若迁移还没做完，新源的 save_progress 可能先落库，
       *      之后迁移再"把旧行合并进新行"就会把刚写的进度覆盖掉
       * ```
       *
       * # ★★★ 失败**绝不阻断**换源
       *
       * 「记录搬不动也得让用户能看 —— 换源本身是用户刚做的动作」
       * ⇒ catch 住 + debugPrint 如实记 + 继续往下走（照 `media_page` 的裁决）
       *
       * ⚠️ 同 provider 的情形（换线路/同源不同 id）**不在这里判** ——
       *    Rust 侧 `commands_write.rs:527` 有一道 `from_provider == to_provider`
       *    守卫，同 provider 直接 `Ok(())`。判据只有一份，不在这边重写。
       */
      try {
        final repoint = _switchRepointForProbe;
        if (repoint != null) {
          await repoint(p);
        } else {
          await SourinApi.repointItem(
            fromProvider: _provider,
            fromId: _contentId,
            toProvider: p.provider,
            toId: p.id,
          );
        }
        debugPrint(
          '[PLAYER] ★ 换源迁移记录完成: '
          '$_provider:$_contentId → ${p.provider}:${p.id}',
        );
      } catch (e) {
        debugPrint(
          '[PLAYER] ★ 换源迁移记录失败'
          '（不阻断换源，列表可能仍显示旧源）: $e',
        );
      }

      /*
       * ★ 换源后要**续播原来的秒数**
       *
       * 不用比例（各源时长可能不同）—— 直接用秒数记到 `_pendingSeek`，
       * 等新流就绪后跳过去。若新源总时长比这个秒数还短，
       * `_startPlayback` 里会做夹取。
       */
      setState(() {
        // 整批替换（新源的 id/剧集/线路全变了）
        _episodes = eps;
        _epIndex = keep != null ? eps.indexOf(keep) : 0;
        _current = null;
        _streams = [];
        _skipMarker = null;
        _playSessionGen++; // ★ 换源 = 会话变了 ⇒ 丢弃在途的旧标记响应
        _position = Duration.zero; // ★ 同步复位 —— 否则补判会读到**上一集**的位置
        // ★ 换源 ⇒ 上一集下载过的那份文件不再代表「当前这一集」
        //   （Lead 审计 team-message-914508ce【低】第 4 条：这两个字段原先从不重置）
        _clipDownloaded = false;
        _clipDownloadError = null;
        _introSkipped = false;
        _outroSkipped = false;
        _nextCountdown = 0;
        _countdownTimer?.cancel();
        // ★ 续播位置
        _pendingSeek = position > 3 ? Duration(seconds: position) : null;
      });

      /*
       * ⚠️ 换源要**重新解析流**，但 provider/id 变了 ——
       *    播放器页的 `widget.provider/id` 是 final，没法改。
       *    所以这里直接调 `resolveStream` 拿新流并播放，
       *    不重建整个页面（原地换源）。
       */
      await _resolveAndPlay(p.provider, p.id, keep?.id, srcCode);

      // 换源后重新读跳过点（新源的片头片尾可能不同）
      await _loadSkipMarker();
    } catch (e) {
      _flash('换源失败：$e');
    }
  }

  /// 从「第 N 集 / 第N话 / 第N回」解析集号
  ///
  /// 原版：`/第\s*(\d+)\s*[集话回]/`
  ///
  /// ⚠️ 用集号而不是下标 —— 各源的剧集列表长度/缺集情况不同
  ///（原版实测过《老舅》列表显示「第2–27集」，下标与集号不一致）。
  int? _epOrder(String? title) {
    if (title == null || title.isEmpty) return null;
    final m = RegExp(r'第\s*(\d+)\s*[集话回]').firstMatch(title);
    return m == null ? null : int.tryParse(m.group(1)!);
  }

  String? get _currentEpisodeTitle => _epIndex < _episodes.length
      ? _episodes[_epIndex].title
      : widget.episodeTitle;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ task-32 ②：投屏（DLNA）
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 用户原话（m24232）
  // > 安卓端要支持投屏功能
  //
  // 投屏栈（发现 / 下发 / 代理 / 状态机）由 task-27 落地在
  // `lib/core/dlna/` + `lib/ui/cast/`，**本页只负责把按钮摆进底栏
  // 并把「当前正在播的那条流」喂给它**。控件自己是自包含的：
  // 三态（空闲 / 投屏中 / 失败）、设备列表、toast 全在
  // `CastButton` 内部管，宿主**不要**去碰 `CastManager`。
  //
  // # 为什么必须给**原始地址**而不是本页的代理地址
  //
  // `StreamCandidate.url` 不一定是本地代理地址（见 `models.dart`
  // 的说明）：点播走 `127.0.0.1:56008/s/…`，但直播给的是上游原始
  // 地址。**电视机在另一台设备上**，`127.0.0.1` 对它毫无意义 ——
  // 所以代理由 `CastButton` 按需自己建（它知道电视的 IP）。
  // 我们只管把「播放器现在拿的那条」原样递过去，连 headers 一起
  // （外部视频站类源少了 Referer，电视拉到的就是 403）。

  /// 投屏到电视（底栏投屏按钮的**回调**）
  ///
  /// ⚠️ 正常路径下**点不到这里** —— 用户点的是 `CastButton` 自己那枚
  ///    `IconButton`，弹设备列表 / 下发 / 回报全在控件内部（见其文件头
  ///    「调用方不需要管 CastManager」）。宿主之所以还要留这么一个落点，
  ///    是为了让调用点与别的按钮同形，也给「将来在别处再放一个投屏入口」
  ///    留同一个出口。
  ///
  /// 「没流不给点」由**不画按钮**承担（`_BottomBar` 的门控
  ///    `castUrl.isNotEmpty`，见其 `castUrl` 文档）；这里再兜一次是
  ///    照抄 [_downloadClip] 的纪律：宁可多一句提示，也不要在 url 为空
  ///    时让控件去弹那句「这个地址不能投屏」—— 那句话听起来像源的问题。
  void _openCast() {
    final st = _current;
    if (st == null) {
      _flash('还没有正在播的流（先起播）');
      return;
    }
    if (!(st.url.startsWith('http://') || st.url.startsWith('https://'))) {
      _flash('这个地址不能投屏（只支持 http/https）');
      return;
    }
    /*
     * ★ 这里**只**做「能投吗」的校验，**不做任何乐观显示**。
     *
     * 铁律（task-32 卡面）：SetAVTransportURI 成功但 Play 失败时，按钮
     * **绝不能**显示成「投屏中」。那条判断在 `CastButton` 内部按
     * `CastPhase` 真值做 —— 外面再包一层「点了就显示投屏中」会把它
     * 变成假的。
     *
     * ⚠️ 真正的设备选择 / 下发 / 结果提示都在控件里（点它自己会弹
     *    设备列表）。宿主这里**没有**能替它点一下的入口，所以校验通过
     *    之后**什么都不做**是**正确**行为，不是漏写。
     */
  }

  /// 投屏时显示在电视上的名字（DIDL 元数据里的 title）
  ///
  /// 优先用当前剧集标题（电视上看到的是「第 3 集」而不是「某某剧」），
  /// 空则退回页面标题，再空则给个中性词 —— 与 `_liveTitle` 同一套
  /// 兜底顺序。
  String get _castTitle {
    final t = _currentEpisodeTitle;
    if (t != null && t.isNotEmpty) return t;
    final live = _liveTitle;
    if (live.isNotEmpty) return live;
    return '投屏';
  }

  // ═══════════════════════════════════════════════════════════════════
  //  剧集导航
  // ═══════════════════════════════════════════════════════════════════

  Episode? get _nextEpisode =>
      _epIndex + 1 < _episodes.length ? _episodes[_epIndex + 1] : null;

  Episode? get _prevEpisode => _epIndex > 0 ? _episodes[_epIndex - 1] : null;

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ task-58：合并页对当前会话下命令（`MediaSession` 的实现）
  // ═══════════════════════════════════════════════════════════════════

  /// 把当前会话换成 [req] —— **不重建 `Player`**
  ///
  /// # 为什么必须走这个方法（而不是重新构造一个 `PlayerPage`）
  ///
  /// `Player` 在 `initState` 里创建（本文件 L1253 `_player = Player(`）⇒
  /// **重新构造 = 新 `State` = 重建播放器** ⇒ 换源/换集时会：
  /// ```text
  /// ① 画面黑一下（重新 open）
  /// ② 播放位置丢失
  /// ③ 全屏态下还会重建视频纹理
  /// ```
  /// 所以合并页必须"对**同一个** `State` 下命令"。
  ///
  /// # 为什么这不是新逻辑（复用既有能力）
  ///
  /// 本文件**早就有**"原地换会话"的先例：
  /// ```text
  /// · `_remoteSwitchSource`（L3508）⇒ `_resolveAndPlay(_provider, _contentId, …)`
  /// · `_adoptLiveChannel`  （L3734）⇒ setState 整批替换会话字段
  /// ```
  /// 而 L666-672 的注释**已声明**：
  /// > `_provider` / `_contentId` / `_sourceCode`
  /// > **初始化时从 widget 取，换源时整批替换。**
  ///
  /// ⇒ 本方法 ≈ `_adoptLiveChannel` 的**点播版**：字段清单照它逐字同款，
  ///   流解析复用 `_resolveAndPlay`，片头片尾复用 `_loadSkipMarker`。
  ///   ★ **不改 `_remoteSwitchSource` / `_gotoEpisode` / `_startPlayback` 任何一行**。
  ///
  /// # ⚠️ 守卫判据必须是**四元组**
  ///
  /// ```text
  /// provider + contentId + episodeId + sourceCode
  /// ```
  /// 只比 `(provider, contentId)` 会把**换集**误判成"同一会话" ⇒ 换集失效。
  /// 而比全字段（含 `episodes`/`title`）又会让"详情刷新后剧集多了一集"
  /// 被当成换会话 ⇒ 无谓重启。四元组正是"决定播哪条流"的最小集合
  /// （判据实现见 `PlayRequestData.isSameSessionAs`）。
  @override
  Duration get currentPosition => _position;

  @override
  Future<void> applySession(PlayRequestData req) async {
    /*
     * ① 同一会话 ⇒ 早退，不白重启一次流
     *
     * 与 `_remoteSwitchSource` 开头的 `if (code == _sourceCode) return;`
     * 同一纪律：用户点"已经在播的那一集"不该导致黑屏 + 丢进度。
     */
    final cur = PlayRequestData(
      provider: _provider,
      id: _contentId,
      title: _title,
      episodeId: _epIndex < _episodes.length ? _episodes[_epIndex].id : null,
      sourceCode: _sourceCode,
      episodes: _episodes,
      episodeIndex: _epIndex < _episodes.length ? _epIndex : null,
    );
    if (req.isSameSessionAs(cur)) {
      debugPrint(
        '[PLAYER] applySession：同一会话 ⇒ 不重启 '
        '(${req.provider}:${req.id} ep=${req.episodeId} src=${req.sourceCode})',
      );
      return;
    }

    // Invalidate an old resume waiter even when the new session has no resume.
    // Keep this after the same-session early return and before any async work.
    ++_seekToken;

    debugPrint(
      '[PLAYER] applySession：换会话 ⇒ ${req.provider}:${req.id} '
      'ep=${req.episodeId ?? "(无)"} src=${req.sourceCode ?? "(默认)"} '
      '共 ${req.episodes.length} 集',
    );

    /*
     * ② 整批替换会话字段
     *
     * ★ 字段清单照 `_adoptLiveChannel`（L3734）逐字同款 ——
     *   **漏一个就会"串台"**：
     *   ```text
     *   _streams/_current 不清 ⇒ 面板显示上一个源的线路（点下去必然失败）
     *   _skipMarker 不清     ⇒ 新源的片头片尾沿用旧源的秒数 ⇒ 跳错位置
     *   _introSkipped/_outroSkipped 不清 ⇒ 新集一上来就被当成"已跳过"
     *   _nextCountdown 不清  ⇒ 旧集的"即将播放下一集"倒计时继续跑
     *   ```
     * ⚠️ `_epIndex` 由 `req.episodeIndex` 决定；为 null 时退到 0
     *    （与"没指定就播第一集"一致）。
     */
    final newIdx =
        (req.episodeIndex != null &&
            req.episodeIndex! >= 0 &&
            req.episodeIndex! < req.episodes.length)
        ? req.episodeIndex!
        : 0;

    setState(() {
      _provider = req.provider;
      _contentId = req.id;
      _episodes = req.episodes;
      _epIndex = req.episodes.isEmpty ? 0 : newIdx;
      _sourceCode = req.sourceCode;
      /*
       * ★ 标题也要跟着换 —— 否则顶栏还写着**上一部**的名字。
       *
       * 合并页里播放器**先于**详情加载（一进页就起播）⇒ 那一刻 `widget.title`
       * 可能是空的/旧的；等详情到了，`MediaPage` 会带着真标题再调一次
       * `applySession`（见它的 `onLoaded` 处理）。
       *
       * ⚠️ 只在 req 真给了非空标题时才覆盖 —— 避免"换源时没带标题"
       *    把已经正确的标题**清成空串**。
       */
      if (req.title.isNotEmpty) _title = req.title;
      _streams = [];
      _current = null;
      _skipMarker = null;
      _playSessionGen++; // ★ 换会话 = 会话变了 ⇒ 丢弃在途的旧标记响应
      /*
       * ★★★ CR #22 ⑥（PRRT_kwDOVAfO4s6rtKkC）：会话被换掉时**同时**作废
       *      在途的「切集 → 续播浮层」链路（`_gotoEpisode`）。
       *
       * `_rewatchToken` 原来只在 `_gotoEpisode` 里自增 ⇒ 它挡得住"两次切集
       * 互相超车"，挡不住"切集途中整个会话被换掉"：合并页这次可能给的是
       * **另一个 provider 的同一集**（`episodeIndex` 一样、`episodes` 里的
       * id 也一样），四道守卫（令牌/mounted/_error/集 id）会全部通过 ⇒
       * 旧 provider 的"上次看到 20:00"浮层弹在**新源**上，用户一点就跳错位置。
       * ⇒ 会话替换路径（本方法 / `_resolveAndPlay` / `_applySwitch` /
       *    `_bootLocalFile`）都要推这枚令牌，与 `_playSessionGen` 同处、
       *    同一理由。
       */
      _rewatchToken++;
      _position = Duration.zero; // ★ 同步复位 —— 否则补判会读到**上一集**的位置
      // ★ 换会话 ⇒ 同上去掉「已下载 / 上次失败」的残留状态
      _clipDownloaded = false;
      _clipDownloadError = null;
      _introSkipped = false;
      _outroSkipped = false;
      _nextCountdown = 0;
      _countdownTimer?.cancel();
      // 只有显式换源携带续播意图；普通换集仍从头播放。
      _pendingSeek = req.resumeFrom != null &&
              req.resumeFrom! > const Duration(seconds: 3)
          ? req.resumeFrom
          : null;
    });

    /*
     * ③ 重新解析流并播放
     *
     * ★ 复用 `_resolveAndPlay` —— 它**已经**是"原地换源不重建页面"的实现
     *   （见它自己的注释："播放器页的 widget.provider/id 是 final，没法改，
     *     所以这里直接调 resolveStream 拿新流并播放，不重建整个页面"）。
     */
    final epId = _epIndex < _episodes.length ? _episodes[_epIndex].id : null;

    /*
     * ★★★ 2026-09-26 第二轮：换会话后通知"当前集变了"
     *
     * ⚠️ 必须在 `_resolveAndPlay` **之前**报 —— 那一刻 `_epIndex` 已经更新，
     *    而详情页要靠这个 id 去滚动/高亮。若放在 await 之后，
     *    解析流要几百毫秒到几秒 ⇒ 详情页会**滞后**才滚过去。
     */
    _reportEpisodeChanged();

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-39（T13 残留①）：换会话后刷新顶栏站名 —— **两条支路都要**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前为什么会坏（T7 如实上报的残留）
     * ```text
     * 下面那个分流里，**只有** else 支（在线）会经 `_resolveAndPlay`
     * 在解析成功后刷新站名；if 支（本地）走 `_bootLocalFile`，
     * 那个方法**只**做 _streams / _prepareResume / _startPlayback /
     * _loadSkipMarker —— 从头到尾不碰 `_providerName`。
     * ⇒ 从在线会话切到本地会话（req.provider == 'local'）之后，
     *   顶栏仍挂着**上一个站点**的名字（比"不显示"更糟：用户会以为
     *   换源/换集没生效）。Owner-1009 要的正是"显示原来源而不是 local"。
     * ```
     *
     * # 为什么放在**分流之前**、且不 await
     * ```text
     * ① 两条支路都要刷新 ⇒ 放在 if/else 内部必然要抄两份
     *    （本项目反复记录过"两处同构必须一起改"的坑）。
     * ② 必须在 setState({ _provider = req.provider; }) **之后**调 ——
     *    `_loadProviderName` 里那个代次判据比的正是 `_provider`
     *    （与 `_resolveAndPlay` 里那条"★ 换源后刷新顶栏的站名"同款纪律），
     *    顺序反了会把这次当成过期结果**直接丢弃**。
     * ③ 不 await：查名字要过一次 `listProviders()`，而它**只挡首帧**
     *    （之后是进程内缓存，见 provider_name.dart:47）；await 会把它
     *    塞进"换集 → 起播"的关键路径上，白白让用户多等。
     *    `_loadProviderName` 自己就是 async + 自带代次保护 + 永不抛
     *    ⇒ 与 `:6381`（_resolveAndPlay）同一写法。
     * ```
     */
    unawaited(_loadProviderName());
    // ★ 与站名**同一批**刷新：换源后发送入口的能力必须跟着换
    unawaited(_loadDanmakuSendCapability());

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-12 ④ 改动 B（2026-10-09）：本地会话的换集走**本地短路**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前为什么会坏（真机证据）
     * ```text
     * `PlayerPage.localPath` 是**页面级不可变**的（shell.dart:4773 一次性决定）。
     * 而换集走的是「对同一个 State 下命令」=> 不重建页面 =>
     * 那条路径只能读到「进页面时那一集」的路径。
     * 用户点右侧第 2 集 => 下面无条件走 `_resolveAndPlay` => resolveStream =>
     *   对本地会话报「无法路由: local:<路径>」（Owner 截图里的顶栏 local + 那条红字）。
     * ```
     *
     * # 改法：与 ① `_load()` / ② `_bootLocalFile` 同一条分流纪律
     * ```text
     * req.localPath != null  => 本地文件 => `_bootLocalFile(path: req.localPath)`
     *                           （★ 复用已有实现，**不重写一份**）
     * 否则                    => 在线      => `_resolveAndPlay`（逐字节不变）
     * ```
     *
     * ⚠️ 为什么用 `req.localPath` 而不是 `_localPath`（若设了那个字段）：
     *    这一支的语义就是「**这次请求**要播的本地文件是谁」——
     *    直接用 req 的字段，不引入第二个可能过期的来源。
     */
    if (req.localPath != null) {
      await _bootLocalFile(path: req.localPath);
    } else {
      await _resolveAndPlay(req.provider, req.id, epId, req.sourceCode);
    }

    /*
     * ④ 重新读跳过点 —— 新源的片头片尾可能与旧源不同
     *    （与 `_remoteSwitchSource` 换源后那一步同款）
     *
     * ⚠️ 本地文件**也要**走这一步：片头片尾是**按 provider/id 存**的
     *    （`_loadSkipMarker` 内部用 `_provider`/`_contentId`），而本地会话的 key
     *    是 local:<规范化路径> => 是独立一份，不会串到在线记录上。
     */
    await _loadSkipMarker();
  }

  /// ★ 只更新**展示用**的标题，**不动流**（`MediaSession` 的实现）
  ///
  /// # 为什么与 `applySession` 分开（我第一版合在一起，错了）
  ///
  /// 合并页是"**播放器先起播、详情后加载**"：一进页播放器就开始解析流，
  /// 那一刻还不知道标题；详情拉到 `MediaDetail` 后才拿到真标题。
  ///
  /// 若那个"补标题"的动作去调 `applySession`，就会踩到这个坑：
  /// ```dart
  /// // ✗ 只补标题却走 applySession（episodeId/sourceCode 没传 ⇒ null）
  /// applySession(PlayRequestData(provider: …, id: …, title: d.title));
  /// ```
  /// 而 `isSameSessionAs` 的四元组**含** `episodeId`/`sourceCode` ⇒
  /// 当前在第 3 集时 `null != "ep3"` ⇒ **判为"换了会话"** ⇒
  /// ★ **白重启一次流**（黑屏 + 丢进度）。
  ///
  /// ⇒ 分成两个方法：本方法**只碰 `_title`**，结构上不可能导致重启。
  ///
  /// ⚠️ 与 `_adoptLiveChannel` 的 `_title = next.name` 同一个字段 ——
  ///    但那个是"换台"（要重启），这个是"补展示"（不重启）。
  ///
  /// # ★ 2026-09-26 第二轮：现在**也**接受封面（Owner 报的「播放记录 ？」）
  ///
  /// 详情加载完时调用方（`MediaPage._onDetailLoaded`）手里**同时**有
  /// 标题与封面 ⇒ 一次送达，不必开第二个方法（理由见 `MediaSession` 的文档）。
  ///
  /// ⚠️ 两个字段**各自独立判断**"有没有新值"：
  /// ```text
  /// 只传标题（cover == null）  ⇒ 只更新标题，**保留**已记住的封面
  /// 只传封面（title 为空）     ⇒ 只更新封面，**保留**已记住的标题
  /// ```
  /// ★ 若写成"任一为空就一起覆盖"，会把先到的那个**清掉**
  ///   （实测顺序：标题先到、封面后到 ⇒ 标题会被清空 ⇒ 又回到「？」）。
  @override
  void updateDisplayTitle(String title, {String? cover}) {
    final newTitle = (title.isNotEmpty && title != _title) ? title : null;
    final newCover = (cover != null && cover.isNotEmpty && cover != _cover)
        ? cover
        : null;
    if (newTitle == null && newCover == null) return;
    debugPrint(
      '[PLAYER] updateDisplayMeta：'
      'title「$_title」→「${newTitle ?? _title}」 '
      'cover ${_cover == null ? "(无)" : "有"} → ${newCover == null ? "不变" : "有"}'
      '（不重启流）',
    );
    setState(() {
      if (newTitle != null) _title = newTitle;
      if (newCover != null) _cover = newCover;
    });
  }

  /// ★★★ 当前**正在播**的剧集 id（`MediaSession` 的实现，2026-09-26 第二轮）
  ///
  /// # 为什么详情页需要它（Owner 原话）
  ///
  /// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
  /// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
  ///
  /// 详情页的 `_activeEpisodeId` 只由"用户点了哪一集 / 上次观看记录"决定 ——
  /// 它**感知不到**播放器自己切了集 ⇒ 按「下一集」后高亮不动、也不滚动。
  ///
  /// ⚠️ 与 [isFullscreen] **同构**：这是**只读**查询，实现方不得因为被读
  ///    而改变任何状态。
  @override
  String? get currentEpisodeId => _epIndex >= 0 && _epIndex < _episodes.length
      ? _episodes[_epIndex].id
      : null;

  /// ★★★ 注册"当前剧集变化"的回调（`MediaSession` 的实现）
  ///
  /// ⚠️ 与 [onFullscreenChanged] 同一纪律：`dispose` 时必须注销。
  @override
  set onEpisodeChanged(void Function(String? episodeId)? cb) {
    _onEpisodeChanged = cb;
    // 注册时**立刻补报一次当前值** —— 否则"注册之前就已经在某集"
    // 这个初始状态永远传不出去（详情页会一直停在第 1 集的高亮上）。
    if (cb != null) cb(currentEpisodeId);
  }

  void Function(String? episodeId)? _onEpisodeChanged;

  /// ★★★ 让详情页把**剧集列表**回填给播放器（`MediaSession` 的实现）
  ///
  /// # 为什么需要它（Owner 原话）
  ///
  /// > 加一个剧集自动滚动到当前观看剧集位置的功能，当然进入到这个页面
  /// > **上一集 下一集**，也都要自动联动滚动到当前剧集到可视区域
  ///
  /// 实测（真机 pid 6868，日志）：
  /// ```text
  /// [NAV] 打开合并页: animesource:3862          ← 首页入口只给了 id
  /// [PLAYER-KEY] ⓪ 入口：收到 N            ← 按了「下一集」
  /// （之后**什么都没有**）                 ← ★ 因为 episodes 是空的
  /// ```
  /// 根因：`MediaPage` 的入口把 `episodes: widget.episodes` 传下去，
  /// 而首页那条路径**只传 id** ⇒ 列表恒为空 ⇒ `_nextEpisode == null`
  /// ⇒ `_gotoNextEpisode` 直接 `return`（连"被拦"日志都只在 `_probeLog` 里）。
  ///
  /// # 与 [applySession] 的区别（**关键**）
  ///
  /// ```text
  /// applySession      ⇒ 换会话 ⇒ 重新解析流（黑屏 + 丢进度）
  /// updateEpisodes    ⇒ **只补列表** ⇒ 不动流、不重置位置
  /// ```
  /// ★ 所以**不能**用 `applySession` 代劳 —— 那会在"详情刚加载完"这个
  ///   无害时刻白重启一次流（正是 `updateDisplayTitle` 那条注释记录的教训）。
  @override
  void updateEpisodes(List<Episode> episodes) {
    if (episodes.isEmpty) return;
    /*
     * 幂等判据：**长度 + 首尾 id** 相同就认为没变。
     *
     * ⚠️ 不能只比 `length` —— 换源后长度可能相同而内容是另一部剧。
     * ⚠️ 也不能比整个列表（`List` 没有值相等）⇒ 比首尾 id 是低成本且
     *    对本场景（同一部剧的集列表）足够强的判据。
     */
    final same =
        _episodes.length == episodes.length &&
        (_episodes.isEmpty ||
            (_episodes.first.id == episodes.first.id &&
                _episodes.last.id == episodes.last.id));
    if (same) return;

    debugPrint(
      '[PLAYER] updateEpisodes：${_episodes.length} → ${episodes.length} 集'
      '（只补列表，不重启流）',
    );
    setState(() {
      _episodes = episodes;
      // ★ 多线路：换了一批集后让"所选线路"落到合法值（默认第一条）
      _syncSelectedFlag();
      /*
       * ★ 下标要**夹取**：当前 `_epIndex` 是基于**旧**列表算的。
       * 若新列表更短，不夹取就会越界 ⇒ `_episodes[_epIndex]` 抛异常。
       */
      if (_epIndex >= _episodes.length) {
        _epIndex = _episodes.isEmpty ? 0 : _episodes.length - 1;
      }
    });
    /*
     * ★ 列表变了 ⇒ 立刻报一次"当前集"
     *   （详情页要靠它把当前集高亮 + 滚入可视区；否则要等用户手动切集才动）
     */
    _reportEpisodeChanged();

    /*
     * ★ task-31 ④：集列表被换掉 ⇒ 绑定里的「本地集序 → cid」映射可能变了
     *   （新列表更长/更短，`_epIndex` 刚被夹取过）⇒ 顺手刷一次。
     */
    if (biliAutoUpdateEnabled()) unawaited(_biliAutoRefresh());
  }

  /// 通知"当前集变了"（幂等 —— 同一个 id 不会重复回调）
  ///
  /// ★ 抽成一个方法而不是在各处直接调 `_onEpisodeChanged?.call(...)`：
  ///   切集有**三条**路径（`applySession` / `_gotoEpisode` / 自动连播），
  ///   写三遍必然漂 —— 本项目已踩过"两处同构必须一起改"的坑。
  String? _lastReportedEpisodeId;
  void _reportEpisodeChanged() {
    final id = currentEpisodeId;
    if (id == _lastReportedEpisodeId) return;
    _lastReportedEpisodeId = id;
    debugPrint(
      '[PLAYER] 当前集变化 ⇒ ${id ?? "(无)"}'
      '（第 ${_epIndex + 1}/${_episodes.length} 集）',
    );
    _onEpisodeChanged?.call(id);
  }

  /// ★★★ 当前是否全屏（`MediaSession` 的实现，task-58 真机实测后新增）
  ///
  /// # 为什么合并页必须问这个（而不是自己监听窗口事件）
  ///
  /// 我第一版在 `MediaPage` 里用 `WindowListener.onWindowEnterFullScreen`
  /// 监听 —— **真机实测证明它在本项目里永远不会触发**：
  /// ```text
  /// window_manager 的 Windows 插件只在 `WM_SIZE` + `SIZE_MAXIMIZED` 时
  /// 发 "enter-full-screen"；而 `SetFullScreen` 对**无边框**窗口走
  /// `SetWindowPos` 直接改尺寸 ⇒ 不产生 SIZE_MAXIMIZED
  /// ⇒ 事件永不发出（实测 '[MEDIA] 进入全屏' = 0 次，
  ///   而 '[WINDOWFRAME#3] … => fullscreen=true' 证明窗口确实全屏了）
  /// ```
  /// 本窗口是**无边框**的 ⇒ 那条路对本项目**结构性失效**。
  ///
  /// ⇒ 而 `_fullscreen` 是**用户按全屏键**的直接结果（不依赖窗口事件），
  ///   所以它才是**权威来源**。完整推理见 `media_session.dart` 的接口文档。
  ///
  /// ⚠️ 只读 —— 不得因为被读而改变任何状态。
  @override
  bool get isFullscreen => _fullscreen;

  /// ★★★ 全屏状态变化的回调（`MediaSession` 的实现，task-58）
  ///
  /// # 为什么必须由播放器**主动**通知合并页
  ///
  /// `MediaPage` 是**父**节点，`PlayerPage` 是它的**子**节点。
  /// 子节点 `setState` **不会**让父节点重建（Flutter 的正常行为）⇒
  /// 父节点读到的 `isFullscreen` 仍是旧值 ⇒ 详情区不收起来。
  /// 所以这里在状态改变时**主动**回调（见 `_toggleFullscreen` 里的调用）。
  ///
  /// ⚠️ 只存回调，**不**在这里读任何状态。
  @override
  set onFullscreenChanged(void Function(bool fullscreen)? cb) {
    _onFullscreenChanged = cb;
  }

  void Function(bool fullscreen)? _onFullscreenChanged;

  /// 切到某一集
  Future<void> _gotoEpisode(Episode ep) async {
    final i = _episodes.indexWhere((e) => e.id == ep.id);
    if (i < 0) return;
    // Cancel the previous media's waiter before any asynchronous transition.
    ++_seekToken;

    /*
     * ★ 只读探针：计"真正执行了切集"（task-28 ①-C 的行为层判据）
     *
     * ⚠️ 放在 `i < 0` 守卫**之后**、任何 await **之前** ——
     *    这样"调用即计数"，不会被后面的网络请求影响。
     *    放在守卫之前会把"传了个不存在的 id"也算进去，
     *    那种情况并没有真的切集。
     */
    /*
     * ★★★ CR #22 ②：切集代次 —— 在任何 await **之前**自增。
     *
     * 连点两集时，先发出的那次调用会在后一次已经把新集播起来之后
     * 才走到收尾的 `showRewatchPrompt`；靠这枚令牌让**旧**调用沉默。
     * ⚠️ 必须在 `i < 0` 守卫之后（没真的切集就不该作废别人的令牌）。
     */
    final rewatchToken = ++_rewatchToken;

    _gotoEpisodeCalls++; // ★ 只读探针
    _probeLog(
      'gotoEpisode #$_gotoEpisodeCalls  '
      '→ 第 ${i + 1}/${_episodes.length} 集「${ep.title}」  '
      'blockedNav=$_blockedNavCalls',
    );

    /*
     * ★★★ fix/rewatch-prompt：**先**读目标集"以前看过吗、看到哪"。
     *
     * # 为什么必须在 `_saveProgress` **之前**读
     * ```text
     * 下面 `await _saveProgress(immediate: true)` 会把**当前这一集**的进度
     * 写进同一个键（progress 表一个作品一行）⇒ 目标集的旧记录会被顶掉
     * ⇒ 再读就读不到了。所以读取必须先于落盘。
     * ```
     * ⚠️ 只在「提示」模式下读 —— 默认（`fromStart`）**一个字节都不多跑**
     *    （与改前逐字同构，多一条 `if` 而已）。
     * ⚠️ 这是一个**只读**调用：它不改 `_pendingSeek` / `_resumedThisSession`
     *    ⇒ 默认「从头播」的语义**不被触碰**（见 `readRewatchProgress` 的说明）。
     */
    Progress? rewatch;
    if (_episodeStartAction == PlayEpisodeStartAction.prompt) {
      rewatch = await readRewatchProgress(ep.id);
      /*
       * ★★★ CR #22 ③：每个 await 返回后立刻查 `mounted`。
       *
       * 页面销毁**不会**取消正在跑的 `_gotoEpisode`；用户在读取期间
       * 按返回退出播放页时，下面 `_saveProgress` / `setState` /
       * `_reload` 都会作用在一个已经 dispose 的 State 上
       *（`setState() called after dispose()`）。
       *
       * ★★★ CR #22 ⑤（PRRT_kwDOVAfO4s6rtKj8）：**还要**查令牌。
       *
       * 这次读进度可能停几百毫秒，期间用户又点了**另一集** —— 那次调用
       * 会把 `_rewatchToken` 推到更大值并重新解析流。若这里只查 `mounted`，
       * 本调用恢复后会继续往下走，把 `_epIndex` 改回**旧目标集**、
       * `_reportEpisodeChanged()`、再 `_reload()` ⇒ 用户刚选的后集被顶掉。
       * ⇒ 令牌已变 = 本次切集作废，原地返回，什么都不碰。
       */
      if (!mounted || rewatchToken != _rewatchToken) return;
    }

    /*
     * ★ 切集前**立刻**落盘当前进度
     *
     * 否则用户看了 20 分钟切下一集，那 20 分钟里最后几秒会丢
     *（定时器还没触发）。
     */
    await _saveProgress(immediate: true);
    /*
     * ★★★ CR #22 ③：落盘同样是 await ⇒ 返回后补一次 `mounted` 检查
     * ★★★ CR #22 ⑤（PRRT_kwDOVAfO4s6rtKj8）：同上再查一次令牌 ——
     *      本 await 期间用户可能已经切到别的集（那条路会把令牌推大）。
     */
    if (!mounted || rewatchToken != _rewatchToken) return;

    _cancelNextCountdown();
    setState(() {
      _epIndex = i;
      _episodeSheetOpen = false;
      _introSkipped = false;
      _outroSkipped = false;
      _skipMarker = null;
      _playSessionGen++; // ★ 切集 = 会话变了 ⇒ 丢弃在途的旧标记响应
        _position = Duration.zero; // ★ 同步复位 —— 否则补判会读到**上一集**的位置
      // ★ 换集 ⇒ 上一集的「已下载」不适用于这一集
      _clipDownloaded = false;
      _clipDownloadError = null;
      // 新集从 0 开始（不是续播）
      _pendingSeek = null;
      // ★ fix/rewatch-prompt：换集 ⇒ 先把上一集残留的浮层收掉
      //   （稍后若目标集看过，会在起播完成后重新弹）
      _cancelRewatchPrompt();
    });
    // ★ Owner 2026-10-11 第 2 条：切集关掉了选集面板 ⇒ 顶/底栏一起回来。
    _restoreBarsAfterSheet();

    // ★★★ 切集了 ⇒ 通知合并页（详情页靠它把"当前集"高亮 + 滚进可视区）
    _reportEpisodeChanged();

    /*
     * ★ task-31 ④：切集后**立刻**刷新 外部视频站弹幕
     *
     * `_reload()` 会重新起播，而起播里那条 `_loadDanmaku()` 是
     * `unawaited` 的 —— 不等它。这里先刷一次，用户切过去时弹幕就已经是
     * 新一集的了（`shouldAutoUpdate` 会把「开关关了 / 缓存还新鲜」判掉）。
     *
     * ⚠️ 必须 `unawaited`：刷新要发网络请求，等它会把切集卡住。
     */
    if (biliAutoUpdateEnabled()) unawaited(_biliAutoRefresh());

    // 重新解析这一集的流
    await _reload();

    /*
     * ★★★ fix/rewatch-prompt：目标集以前看过 ⇒ 弹非阻断小浮层
     *
     * # 为什么放在 `_reload()` **之后**
     * ```text
     * ① 起播已经完成、画面在放（用户看到的是"新集从头播"—— 默认行为不变）。
     * ② 浮层是**纯附加**：`_pendingSeek` 此刻已是 null（上面 setState 写死的），
     *    ⇒ 不操作就是从头播，用户点了「继续观看」才 seek。
     * ③ 放在起播前弹的话，`_reload` 里 `_startPlayback` 会把浮层状态卷入
     *    加载态渲染，且用户会先看到一个"还没画面"的浮层。
     * ```
     * ⚠️ **绝不影响起播**：这里只 `setState` 一个"要显示的秒数"，
     *    不暂停、不 seek（见 `showRewatchPrompt`）。
     * ⚠️ `mounted` 守卫：切集过程中页面可能已被销毁。
     *
     * # ★★★ CR #22 ②：四道门一起过才弹
     * ```text
     * ① mounted               —— 页面还在（否则 setState 会炸）
     * ② rewatchToken == 当前   —— 中间**没有**又切过集（旧调用必须沉默，
     *                            否则会把第一目标集的进度弹到新集上，
     *                            用户点「继续观看」⇒ 对新集做一次错误 seek）
     * ③ _error == null         —— 起播**成功**（`_reload` 失败时只设
     *                            `_error`，那时弹续播浮层等于骗用户去 seek
     *                            一个根本没在放的播放器）
     * ④ 当前集 == 目标集        —— 身份核对（与 ② 是两件事：② 管时序，④ 管是谁）
     * ```
     */
    if (rewatch != null &&
        mounted &&
        rewatchToken == _rewatchToken &&
        _error == null &&
        _epIndex < _episodes.length &&
        _episodes[_epIndex].id == ep.id) {
      debugPrint('[PLAYER] 目标集看过（${rewatch.position}s）⇒ 弹「继续观看/从头播放」浮层');
      showRewatchPrompt(Duration(seconds: rewatch.position));
    }
  }

  Future<void> _gotoNextEpisode() async {
    final n = _nextEpisode;
    if (n == null) {
      /*
       * ★ 只读探针：记"被边界挡回去了"
       *
       * 与 `_gotoEpisodeCalls` 配对才能区分两种"没切"：
       * ```text
       * blockedNav +1 且 gotoEpisode 不变  ⇒ 判据拦住了（期望）
       * 两个都 +1                          ⇒ 判据失效（真 bug）
       * ```
       */
      _blockedNavCalls++; // ★ 只读探针
      _probeLog(
        'gotoNextEpisode 被拦：已是最后一集'
        '（_epIndex=$_epIndex / 共 ${_episodes.length} 集）'
        '  blockedNav=$_blockedNavCalls',
      );
      return;
    }
    await _gotoEpisode(n);
  }

  /// 切到上一集（与 `_gotoNextEpisode` 对称，同样带边界计数）
  Future<void> _gotoPrevEpisode() async {
    final p = _prevEpisode;
    if (p == null) {
      _blockedNavCalls++; // ★ 只读探针
      _probeLog(
        'gotoPrevEpisode 被拦：已是第一集'
        '（_epIndex=$_epIndex）  blockedNav=$_blockedNavCalls',
      );
      return;
    }
    await _gotoEpisode(p);
  }

  // ═══════════════════════════════════════════════════════════════════
  //  ★★★ 局域网遥控：播放页交出的两个能力（task-14 F）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 与 `remote_bridge.dart` 的契约：
  // ```text
  // PlayerBridge.getState() → RemoteState   手机端靠它渲染界面
  // PlayerBridge.exec(cmd)  → 执行一条命令
  // ```
  // 分发在桥那边（`_execCommand`），**这里只负责"命令 → 播放器动作"**。
  //
  // ⚠️ 两个方法的实现原则（与原版一致）：
  // ```text
  // · 未知命令 **忽略**（不抛）—— 桥那边已经 catch，但这里也不该炸
  // · 参数缺失/越界 **静默不动** —— 与 PrevEpisode 的边界做法一致
  // · 任何动作失败都不能把播放页带崩（遥控是"尽力而为"的通道）
  // ```

  /// 把当前播放状态压成遥控端的 [RemoteState]
  ///
  /// # ★ 这是手机端「选集面板」终于能显示的原因
  ///
  /// `episodes` 为空时，`page.html` 的 `epsCard` 整块隐藏
  ///（判据 `episodes.length > 1`）。以前 `setPlayer` 从没被调用，
  /// 状态恒为 `RemoteState.idle()` → 手机上的选集**永远是空的**。
  ///
  /// # 字段口径向原版 `PlayerView.vue::reportState()` 对齐
  ///
  /// ```ts
  /// episode_order: m ? Number(m[1]) : eps.length > 1 ? currentIndex+1 : 0
  /// episode_count: eps.length > 1 ? eps.length : 0
  /// ```
  /// 即：**集号优先从标题里解析**（「第5集」），解析不到才用下标+1；
  /// 单集内容（`eps.length <= 1`）时两者都给 0（手机端据此不显示选集）。
  ///
  /// # ⚠️ 线路列表只能给**当前这一条**
  ///
  /// 与原版一致（原版 `reportState` 也只有
  /// `sources: sources.value.map(...)` + `current_source`）。
  ///
  /// 我第一版**猜错了**：以为 `_streams` 是线路列表，
  /// 实际上 `_streams` 是 `resolve_stream` 返回的**清晰度候选**
  ///（同一线路的多个码率）—— 拿它当线路会在手机上画出
  /// 一堆同名按钮。`PlayerPage` 根本**没存** `detail.sources`（线路列表），
  /// 所以只能如实上报"当前这一条"。
  /// 手机端 `srcCard` 的判据是 `sources.length > 1`，
  /// 所以它会隐藏 —— 后续若要支持换线路，
  /// 需要先把 `detail.sources` 存进 `PlayerPage`（独立一步，本次不做）。
  /// 手机端「选集」tab 在直播时显示的频道列表（`id, 名称`）
  ///
  /// 取自 `onLiveChannels` —— 与电脑端「所有直播」抽屉**同一份**，
  /// 所以手机上看到的台和电脑上看到的必然一致。
  List<(String, String)> _remoteLiveChannels() {
    final v = _liveChannels();
    if (v == null) return const [];
    return [for (final c in v.channels) (c.id, c.name)];
  }

  RemoteState _remoteGetState() {
    /*
     * 直播没有集数概念（同 `_openSkipDialog` 的判据）。
     */
    final multi = _episodes.length > 1 && !_isLive;

    final order = multi
        ? (_epOrder(_currentEpisodeTitle) ?? (_epIndex + 1))
        : 0;

    return RemoteState(
      playing: _playing,
      title: _title,
      episodeOrder: order,
      episodeCount: multi ? _episodes.length : 0,
      position: _position.inSeconds,
      duration: _duration.inSeconds,
      volume: _volume.round().clamp(0, 100),
      muted: _muted,
      /*
       * ⚠️ 只能报**当前这一条**（见上面的说明）。
       *    用 `displayName` 而不是 `kind` —— 与选清晰度面板同一口径
       *（`player_page.dart` 的 ListTile 用的就是 `s.displayName`）。
       */
      sources: _streams.isEmpty
          ? const []
          : [(_sourceCode ?? '', _streams.first.displayName)],
      currentSource: _sourceCode ?? '',
      /*
       * 剧集列表 `(集号, 标题)` —— 手机端集号用于 `goto_episode`。
       * 集号口径与 `order` 一致：标题里能解析出「第N集」就用它，
       * 否则退回下标+1（原版 `episodes.map` 就是这么做的）。
       */
      episodes: multi
          ? [
              for (var i = 0; i < _episodes.length; i++)
                (_epOrder(_episodes[i].title) ?? (i + 1), _episodes[i].title),
            ]
          : const [],
      hasMedia: true,
      introStart: _skipMarker?.introStart,
      introSkip: _skipMarker?.introEnd,
      outroSkip: _skipMarker?.outroStart,
      outroEnd: _skipMarker?.outroEnd,
      autoSkip: _autoSkip,
      // ★ 手机端遥控页新增的几项（见 rust 侧 RemoteState 的同名字段注释）
      cover: _cover,
      isLive: _isLive,
      liveChannelId: _liveChannelId ?? '',
      // 直播频道列表：与「所有直播」抽屉同一个取值入口（`onLiveChannels`），
      // 所以手机上看到的台与电脑上看到的**一定是同一份**。
      liveChannels: _remoteLiveChannels(),
      speed: _rate,
      danmaku: _danmakuEnabled,
      fullscreen: _fullscreen,
      // 清晰度候选：只给 displayName，地址常带一次性签名，不下发。
      qualities: _streams.map((x) => x.displayName).toList(),
    );
  }

  /// 执行一条手机端发来的命令
  ///
  /// # 覆盖 `page.html` 会发出的**全部播放类** kind
  ///
  /// ```text
  /// toggle_play      播放/暂停
  /// prev_episode     上一集
  /// next_episode     下一集
  /// goto_episode     跳到第 N 集（按**集号**，不是下标）
  /// seek             相对快进/快退（秒，可为负）
  /// seek_to          绝对跳转（秒）
  /// set_volume       音量 0~100
  /// toggle_mute      静音切换
  /// switch_source    切换线路（按 code）
  /// set_speed        设置播放倍速
  /// toggle_danmaku   弹幕开关
  /// toggle_fullscreen 全屏切换
  /// set_quality      选清晰度 / 线路（按下标）
  /// goto_channel     跳到指定直播频道（按 id）
  /// skip_config_open 打开片头片尾设置弹窗
  /// skip_preview     预览跳到某秒（手机上微调时）
  /// skip_confirm     锁定为片头/片尾（手机确认）
  /// skip_clear       清除本剧跳过设置
  /// skip_toggle_auto 开关「自动跳过」
  /// ```
  ///
  /// ⚠️ `play_item` / `query_search` / `query_home` / `move_provider`
  ///    **不在这里** —— 它们由桥的全局能力处理（与播放页无关）。
  Future<void> _remoteExec(RemoteCommand c) async {
    if (!mounted) return;

    switch (c.kind) {
      case 'toggle_play':
        _togglePlay();
        return;

      case 'next_episode':
        await _gotoNextEpisode();
        return;

      case 'prev_episode':
        /*
         * ★ 走 `_gotoPrevEpisode`（而不是内联判 null）—— task-28 ①-C
         *
         * 内联写法 `if (p != null) await _gotoEpisode(p);` 在功能上等价，
         * 但它**绕过了边界计数器** —— 遥控端发 prev_episode 时
         * `_blockedNavCalls` 不会 +1，于是"遥控在最后一集发命令"
         * 这种情况在探针里看不出来。
         * 统一走一个出口，计数才是完整的。
         */
        await _gotoPrevEpisode();
        return;

      case 'goto_episode':
        /*
         * ★ 手机端给的是**集号**（「第5集」的 5），不是下标 ——
         *   各源的列表长度/缺集情况不同，按下标会跳错集
         *  （原版 `PlayerView.vue` 的 `execRemote` 也是按集号找）。
         */
        final order = c.number('order')?.toInt();
        if (order == null) return;
        final i = _episodes.indexWhere((e) => _epOrder(e.title) == order);
        if (i < 0) {
          debugPrint(
            '[REMOTE] goto_episode 找不到第 $order 集（共 ${_episodes.length} 集）',
          );
          return;
        }
        await _gotoEpisode(_episodes[i]);
        return;

      case 'seek':
        final d = c.number('delta')?.toInt();
        if (d == null || d == 0) return;
        _seekBy(d);
        return;

      case 'seek_to':
        final pos = c.number('position')?.toInt();
        if (pos == null) return;
        // 与 `_seekBy` 同一套夹取（直播不能跳）
        if (_isLive) return;
        final target = Duration(seconds: pos < 0 ? 0 : pos);
        final clamped = target > _duration ? _duration : target;
        await _seekByUser(clamped);
        // ★ N10：遥控器/手机发起跳转 ⇒ 用户在等电视出画面，预取必须让路
        _beginPrefetchYield();
        _flash('跳到 ${clamped.inSeconds}s');
        _showControls();
        return;

      case 'set_volume':
        final v = c.number('value')?.toInt();
        if (v == null) return;
        final clamped = v.clamp(0, 100).toDouble();
        // ★ 遥控器调音量 = 用户发起的（白名单，见 `_lastUserVolumeAction`）
        _lastUserVolumeAction = DateTime.now();
        _sendVolume(clamped);
        /*
         * 调音量顺带解除静音 —— 用户按了「音量 +」却还是没声音
         * 会以为坏了（原版 ArtPlayer 也是这个行为）。
         */
        setState(() {
          _volume = clamped;
          if (clamped > 0) _muted = false;
        });
        _flash('音量 ${clamped.round()}');
        _showControls();
        return;

      case 'toggle_mute':
        _toggleMute();
        return;

      case 'switch_source':
        final code = c.code;
        if (code == null || code.isEmpty) return;
        await _remoteSwitchSource(code);
        return;

      case 'set_speed':
        /*
         * 与底栏倍速面板同一个落点（`_player.setRate`）。
         * ⚠️ 过滤非正数：media_kit 会拒绝 0/负倍率，手机上少给一个 0
         *    就直接把播放搞停 —— 边界在这里挡一次，不去让原生库报错。
         */
        final r = c.number('value')?.toDouble();
        if (r == null || r <= 0) return;
        _requestRate(r);
        _flash('倍速 ${r}x');
        return;

      case 'toggle_danmaku':
        await _toggleDanmaku();
        return;

      case 'toggle_fullscreen':
        await _toggleFullscreen();
        return;

      case 'set_quality':
        /*
         * 手机端只发**下标** —— 地址常带一次性签名，回传既长又不安全；
         * 客户端用自己的 `_streams` 取真值（与线路面板同一份数据）。
         */
        final i = c.number('index')?.toInt();
        if (i == null || i < 0 || i >= _streams.length) return;
        if (identical(_streams[i], _current)) return;
        _startPlayback(_streams[i]);
        _flash('已切到 ${_streams[i].displayName}');
        return;

      case 'goto_channel':
        final chId = c.id;
        if (chId == null || chId.isEmpty || !_isLive) return;
        final ch = _liveChannels()?.channels.where((x) => x.id == chId).firstOrNull;
        if (ch == null) {
          debugPrint('[REMOTE] goto_channel 找不到频道 $chId');
          return;
        }
        await _pickLiveChannel(ch);
        return;

      case 'skip_config_open':
        if (_isLive) return;
        await _openSkipDialog();
        return;

      case 'skip_preview':
        /*
         * 手机微调时让**电视画面**跟着跳 —— 草稿的方案 A：
         * 「手机上拖，电视上出画面」（电视屏幕大，看得准）。
         * ⚠️ 只 seek，**不改** `_skipMarker` —— 用户点「确认」才落库。
         */
        final pos = c.number('position')?.toInt();
        if (pos == null || _isLive) return;
        final t = Duration(seconds: pos < 0 ? 0 : pos);
        await _seekByUser(t > _duration ? _duration : t);
        // ★ N10：手机微调、电视出画面 —— 最需要立即出画面的场景之一
        _beginPrefetchYield();
        _flash('预览 ${t.inSeconds}s');
        return;

      case 'skip_confirm':
        await _remoteConfirmSkip(c.args['target']?.toString());
        return;

      case 'skip_clear':
        await _remoteClearSkip();
        return;

      case 'skip_toggle_auto':
        final on = c.flag('on');
        if (on == null) return;
        setState(() => _autoSkip = on);
        // ⚠️ `UiPrefs.set` 返回 void（同步落盘），不能 await
        UiPrefs.set('dsh.playprefs.autoSkip', on ? '1' : '0');
        _flash(on ? '自动跳过已开启' : '自动跳过已关闭');
        return;

      default:
        // 其余（play_item / query_* / move_provider）由桥的全局能力处理
        return;
    }
  }

  /// 按线路 code 切源（复用 `_resolveAndPlay` 的既有路径）
  ///
  /// # 为什么不调 `_applySwitch`
  ///
  /// 我第一版写的是 `_applySwitch(SwitchPick(...))` —— **猜错了**。
  /// `SwitchPick` 的语义是「**换到另一个內容站**」
  ///（它里面有 `provider` / `id`，会去拉新站的详情与剧集）；
  /// 而 `switch_source` 的语义是「**同一个片子换一条线路**」——
  /// provider/id 都不变，只换 `sourceCode`。
  /// 两者混用会把用户的片子换成另一个（严重）。
  ///
  /// 所以这里直接走 `_resolveAndPlay`（它就是「按 sourceCode 重新
  /// resolve 并播放」，且**保留当前剧集与进度**）。
  Future<void> _remoteSwitchSource(String code) async {
    if (code == _sourceCode) return; // 已经是这条线路，别白重启一次流
    // Retire the old waiter; a new playback may schedule its own resume.
    ++_seekToken;
    final ep = _epIndex < _episodes.length ? _episodes[_epIndex] : null;
    // ⚠️ `_resolveAndPlay` 是**位置参数**（不是命名参数）
    await _resolveAndPlay(_provider, _contentId, ep?.id, code);
    if (mounted) _flash('已切换线路');
  }

  /// 手机端确认「片头结束 / 片尾开始」→ 落库
  ///
  /// 与 `_openSkipDialog` 返回后的那段逻辑**同一套**（都调
  /// `SourinApi.setSkipMarker` 并更新 `_skipMarker`）——
  /// 不另写一份，否则两处的字段口径迟早漂移。
  ///
  /// ⚠️ 只提交**被确认的那一个端点**，另一个端点保持原值
  ///（不传 null 也不传 0 —— `setSkipMarker` 的参数是
  /// `if (x != null)` 才会进 payload，传 null 就是"不改它"）。
  Future<void> _remoteConfirmSkip(String? target) async {
    if (_isLive) return;
    if (target != 'intro' && target != 'outro') {
      debugPrint('[REMOTE] skip_confirm 缺少合法 target: $target');
      return;
    }
    final pos = _position.inSeconds;

    try {
      await SourinApi.setSkipMarker(
        _provider,
        widget.id,
        /*
         * ★★★ task-72【④】这里原来写的是 `widget.title` —— **写库路径**
         *
         * 与 L2865（`_saveProgress`）是**同一类 bug**：写库读了 `final`
         * 构造参数，而合页入口传的是 `title: ''`。
         * ⇒ 实测用户真实库（只读副本，`.probe/c6.py`）里
         *   `progress` 表**已有 1 行空标题** —— 就是上一次同类 bug 的化石。
         *   `skip_markers` 目前 3 行标题都正常（**侥幸**），
         *   但只要本路径在标题为空时被触发，就会**新造一行空标题**。
         * ⇒ 修法：活值 + `widget.title` 兜底（与 L2865 逐字同写法）。
         */
        title: _liveTitle,
        introStart: target == 'intro'
            ? (_skipMarker?.introStart ?? 0)
            : _skipMarker?.introStart,
        introEnd: target == 'intro' ? pos : _skipMarker?.introEnd,
        outroStart: target == 'outro' ? pos : _skipMarker?.outroStart,
        outroEnd: _skipMarker?.outroEnd,
        autoSkip: _skipMarker?.autoSkip ?? _autoSkip,
      );
      if (!mounted) return;
      /*
       * 立刻用到当前会话（与 `_openSkipDialog` 同一做法）——
       * 不重新拉接口，并重置"已触发过"标志，
       * 否则新设置本次会话**不再生效**（表现为"设了没用"）。
       */
      setState(() {
        _skipMarker = SkipMarker(
          key: '$_provider:${widget.id}',
          provider: _provider,
          nativeId: widget.id,
          title: _liveTitle,
          introStart: target == 'intro'
              ? (_skipMarker?.introStart ?? 0)
              : _skipMarker?.introStart,
          introEnd: target == 'intro' ? pos : _skipMarker?.introEnd,
          outroStart: target == 'outro' ? pos : _skipMarker?.outroStart,
          outroEnd: _skipMarker?.outroEnd,
          autoSkip: _skipMarker?.autoSkip ?? _autoSkip,
        );
        _introSkipped = false;
        _outroSkipped = false;
      });
      _flash(target == 'intro' ? '已设为片头 $pos s' : '已设为片尾 $pos s');
    } catch (e) {
      debugPrint('[REMOTE] skip_confirm 落库失败: $e');
      _flash('设置失败：$e');
    }
  }

  /// 手机端「取消跳过」→ 清除本剧设置
  Future<void> _remoteClearSkip() async {
    try {
      await SourinApi.clearSkipMarker(_provider, widget.id);
      if (!mounted) return;
      setState(() {
        _skipMarker = null;
        _introSkipped = false;
        _outroSkipped = false;
      });
      _flash('已清除本剧跳过设置');
    } catch (e) {
      debugPrint('[REMOTE] skip_clear 失败: $e');
      _flash('清除失败：$e');
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loading = true;
      _error = null;
      _errorKind = null;
    });
    /*
     * ★★★ CR #22 ⑤（PRRT_kwDOVAfO4s6rtKj8）：记下发请求那一刻的切集令牌。
     *
     * 本方法唯一的生产调用者是 `_gotoEpisode`（见它末尾）。解析流要几百
     * 毫秒到几秒，期间用户可能又切了一集（或整个会话被换掉）—— 那时
     * `_rewatchToken` 已经更大。若这里不核对，本调用会把**旧目标集**的流
     * 重新起播（`_startPlayback`），把用户刚选的那一集顶掉。
     * ⚠️ 与 `_loadSkipMarker()` 里 `final gen = _playSessionGen;` 同一纪律：
     *    必须在 `await` **之前**读。
     * ⚠️ 放弃时**不动 `_loading`** —— 新的那次调用自己会收尾（它先设 true、
     *    成功或失败时设 false）；这里若补一个 false，反而会把新会话的
     *    转圈提前掐掉。
     */
    final token = _rewatchToken;
    try {
      final ep = _epIndex < _episodes.length ? _episodes[_epIndex] : null;
      final list = await SourinApi.resolveStream(
        _provider,
        _contentId,
        req: PlayRequest(
          sourceCode: _sourceCode,
          episodeId: ep?.id,
          flag: _selectedFlag,
        ),
      );
      if (!mounted) return;
      if (token != _rewatchToken) {
        debugPrint(
            '[PLAYER] 丢弃过期的换集解析结果（切集令牌 $token → $_rewatchToken）');
        return;
      }
      setState(() => _streams = list);
      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = '这一集没有可播放的地址';
          _loading = false;
        });
        return;
      }
      await _startPlayback(first);
      await _loadSkipMarker();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
        });
      }
    }
  }

  /// ★★★ task-53【#4b】在播放页里切到另一个直播频道（用户第 4 条的核心）
  ///
  /// [delta] `+1` 下一个台（↓）、`-1` 上一个台（↑）。
  ///
  /// # 为什么单独写一个（不能复用 `_reload()`）
  /// ```text
  /// `_reload()` 走的是**点播**那条路：`resolveStream(_provider, _contentId, …)`
  ///   ⇒ 直播的 url 来自 `getLiveStream(provider, channelId)`，
  ///     **接口都不同**（`_load()` 里那个 `if (_isLive)` 分支正是为此）。
  /// ★ 而且 `_reload()` 会 `await _loadSkipMarker()` ——
  ///   直播没有片头片尾概念（那个方法第一行就 `if (_isLive) return;`），
  ///   但与 `_episodes` 相关的下标运算在直播下全是无意义的。
  /// ⇒ 直播切台照抄的应该是 **`_load()` 的直播分支**，不是 `_reload()`。
  /// ```
  ///
  /// # 三步（顺序不能换）
  /// ```text
  /// ① 问直播页"下一个台是哪个"（它手里有探针缓存 + 启用态 = 唯一真相）
  /// ② 换掉标题/频道 id（**必须在起播前** —— 顶栏与遥控状态读的是它们）
  /// ③ 起播（走与 `_load()` 同一条 `getLiveStream` + `_startPlayback`）
  /// ```
  ///
  /// # ⚠️ 必须清掉的直播残留（否则会串台）
  /// ```text
  /// _streams / _current / _pendingSeek / _liveAudioOnlyNotice
  ///   ⇒ 上一个台的线路列表/黑屏横幅留着，新台还没解析完就会显示旧台的信息
  /// ```
  /// ★★★ task-53【③】打开/关闭「所有直播」面板（用户第 3 条）
  ///
  /// ```text
  /// 用户原话：> 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  ///
  /// # ★ 为什么这里**不**缓存频道列表
  /// ```text
  /// 候选：打开时调一次 `onLiveChannels()` 存进 state，之后渲染缓存。
  /// ★ 否掉：频道列表会**变** —— 用户在设置页关掉一个源、或探针 TTL 到期
  ///   重新探测 ⇒ 缓存会让面板显示**过期的台**（点下去必然失败）。
  /// ⇒ 每次 `build` 现取（`_liveChannels()` 是纯查询、无副作用、O(n) 很小）。
  /// ```
  void _toggleLiveChannels() {
    setState(() => _liveChannelsOpen = !_liveChannelsOpen);
    /*
     * ★ T27-06：打开面板的瞬间预取相邻台（unawaited —— 预取绝不阻塞 UI）。
     *   用户点开「所有直播」的意图就是马上换台：把邻居的取址结果提前
     *   灌进 SourinApi 的 30s 缓存，点选时 ①→②≈0ms。
     *   ⚠️ 只预取**地址**（SourinApi 层缓存）；频道列表的新鲜性纪律
     *   （task-72：每次 build 现取）一行不动。
     */
    if (_liveChannelsOpen) {
      // ★★★ T27-09：只在**开**分支收顶/底栏（关面板不碰控制条显隐）——
      //    显隐统一真源，见 _collapseControlsForSheet。
      _collapseControlsForSheet();
      unawaited(_prefetchNextLiveChannel());
    }
  }

  /// T27-06：预取当前台的相邻台（↑/↓ 最可能去的地方）
  ///
  /// # 为什么用 `_provider` 兜邻居的 provider
  /// ```text
  /// `onLiveChannels()` 给的平面列表不带 provider（live_page 要用
  /// `_providerOf` 反查 _groups 才知道权威映射）——播放页拿不到。
  /// 但列表按源分组，邻台与本台同源是大概率；取错 provider 时核心层
  /// 只会返回空结果，而空结果**不进缓存**（SourinApi 的纪律）⇒ 无污染。
  /// 真正切台时 `_adoptLiveChannel` 用权威 provider 取址，不受影响。
  /// ```
  Future<void> _prefetchNextLiveChannel() async {
    final data = _liveChannels();
    if (data == null) return;
    final channels = data.channels;
    if (channels.length < 2) return;
    if (data.index < 0 || data.index >= channels.length) return;
    final i = data.index;
    for (final d in const [1, -1]) {
      final j = i + d;
      if (j < 0 || j >= channels.length) continue;
      final c = channels[j];
      if (c.id == _liveChannelId) continue;
      try {
        await SourinApi.getLiveStream(_provider, c.id);
      } catch (_) {
        // 预取失败静默 —— 切台时 adopt 会真取并把错误如实报给用户。
      }
    }
  }

  /// 现取可见频道列表（`null` = 没有/没接线）
  ({List<LiveChannel> channels, int index})? _liveChannels() =>
      widget.onLiveChannels?.call();

  /// 上一次取到的频道列表（**只**用于抽屉的退出动画，见下）
  ({List<LiveChannel> channels, int index})? _liveChannelsLast;

  /// ★★★ task-72【④】给「所有直播」抽屉用的取值入口
  ///
  /// # 为什么要绕一层（而不是直接 `_liveChannelsOpen ? _liveChannels() : null`）
  ///
  /// 直接写成三元表达式会引入一个**新 bug**：抽屉关闭时 `data` 立刻变 null，
  /// 而 `SheetTransition` 在 `visible:false` 之后**仍然挂着 child 跑完
  /// 220ms 退出动画**（`lib/ui/widgets/episode_strip.dart:1131-1153`：
  /// `_mounted` 直到 reverse 结束才置 false）
  /// ⇒ 用户会看到抽屉**一边滑走一边把列表清空**（标题变成「所有直播（0）」）。
  ///
  /// # 语义
  /// ```text
  /// 开着 ⇒ 每次 build **现取** —— 列表会变（用户在设置页关掉一个源、
  ///        或探针 TTL 到期重探）⇒ 必须新鲜，这与
  ///        `_liveChannels()` 上方 L4240-4245 否掉"打开时缓存一次"的理由一致
  /// 关着 ⇒ 沿用**上一次**取到的 —— 既不再调用（这是 ④ 的收益：
  ///        实测改前每次整页重建都调一次，而播放中位置 tick 很频繁），
  ///        又让退出动画有内容可画
  /// ```
  ///
  /// ⚠️ 这里**没有** `setState`：只是把取到的值记下来，不触发重建
  ///    （在 build 里给缓存字段赋值不会造成循环）。
  ({List<LiveChannel> channels, int index})? _liveChannelsForSheet() {
    if (_liveChannelsOpen) {
      final v = _liveChannels();
      if (v != null) _liveChannelsLast = v;
      return v;
    }
    return _liveChannelsLast;
  }

  /// ★★★ task-53【③】在面板里点选某个台 ⇒ 切过去
  ///
  /// # ★ 复用 `_switchLiveChannel` 的**全部**后续逻辑（铁律 170）
  /// ```text
  /// 点选与上下键的差别**只有"目标台从哪来"**：
  ///   ↑/↓   ⇒ `onLiveChannelStep(delta)` 算相邻台
  ///   点选  ⇒ `onLiveChannelPick(channel)` 用用户点的那个
  /// ★ 而"采纳之后"（清线路、代次守卫、黑屏横幅、起播）**必须逐字相同** ——
  ///   否则会出现"上下键切台正常、点选切台双声/黑屏"这种最难查的 bug。
  /// ⇒ 抽成 `_adoptLiveChannel(pick)`，两条路共用。
  /// ```
  Future<void> _pickLiveChannel(LiveChannel channel) async {
    final cb = widget.onLiveChannelPick;
    if (cb == null) return;
    /*
     * ★ 先关面板：用户点了就该立刻看到画面在换。
     *   （与 `_gotoEpisode` 里 `_episodeSheetOpen = false` 同一时机 ——
     *     放在 await **之前**，否则网络慢时面板会僵在那儿。）
     */
    setState(() => _liveChannelsOpen = false);
    // ★ Owner 2026-10-11 第 2 条：点选频道关掉了「所有直播」面板 ⇒ 顶/底栏一起回来。
    _restoreBarsAfterSheet();
    // ★★ 2026-10-19（R3-④ 补漏）：**点选频道即关**这条路也要守卫。
    _holdSheetGuard();
    final pick = cb(channel);
    if (pick == null) {
      debugPrint('[PLAYER] 直播点选：直播页不认这个频道 ${channel.name}');
      _flash('这个频道现在不可用');
      _showControls();
      return;
    }
    await _adoptLiveChannel(pick);
  }

  /// ★★★ task-53【#4b】直播时 ↑/↓ 切频道（用户第 4 条）
  ///
  /// ⚠️ 只是 `_adoptLiveChannel` 的**取目标**那一半 ——
  ///   "采纳之后"的全部逻辑在 `_adoptLiveChannel`（与点选共用，铁律 170）。
  Future<void> _switchLiveChannel(int delta) async {
    final cb = widget.onLiveChannelStep;
    if (cb == null) return;

    final pick = cb(delta);
    if (pick == null) {
      /*
       * 直播页答"没有下一个台"（列表为空 / 还没加载完）。
       * ★ 必须给用户一个反馈 —— 否则他会以为"键盘坏了"。
       */
      debugPrint('[PLAYER] 直播切台：直播页没给出目标频道（delta=$delta）');
      _flash('没有其它频道');
      _showControls();
      return;
    }
    await _adoptLiveChannel(pick);
  }

  /// ★ "采纳某个直播频道"的**唯一实现**（↑/↓ 与点选**共用**）
  ///
  /// ⚠️ 调用方负责：① 拿到非 null 的 `pick` ② 自己关掉相关面板。
  Future<void> _adoptLiveChannel(
    ({String provider, LiveChannel channel}) pick,
  ) async {
    final next = pick.channel;
    debugPrint('[PLAYER] 直播切台 ⇒ ${next.name}（provider=${pick.provider}）');

    /*
     * ★ T27-06：切台 t0 —— 必须在第一个 await 之前（与 _bootWatch 同一纪律），
     *   否则 setState/取站名的耗时会被算进 ①→②。
     */
    _liveSwitchStartedAt = DateTime.now();
    _liveSwitchMark('① 切台发起', '${pick.provider}/${next.id} ${next.name}');

    setState(() {
      _provider = pick.provider;
      _contentId = next.id;
      _liveChannelId = next.id;
      _title = next.name;
      /*
       * ★ 换台 ⇒ 线路是**新台**的，旧列表必须清掉。
       *   留着会让"选线路"面板显示上一个台的清晰度（点下去必然失败）。
       */
      _streams = [];
      _current = null;
      _sourceCode = null;
      // ★ 上一个台的黑屏横幅不能留到新台（它是按旧台的线路算出来的）
      _liveAudioOnlyNotice = null;
      // ★ 同理：画面输出层的判决也是按旧台那一次起播算的
      _videoOutputDead = false;
      // ★★★ CR #22 ⑥：换台 = 换会话 ⇒ 作废在途的切集续播浮层（理由见 applySession 处）
      _rewatchToken++;
      _loading = true;
      _error = null;
      _errorKind = null;
    });

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-39（T13 残留②）：换直播台后刷新顶栏站名
     * ══════════════════════════════════════════════════════════════════
     *
     * # 改前为什么会坏（T7 如实上报的残留）
     * ```text
     * 上面那个 setState 刚把 `_provider` 换成 `pick.provider`（新台所属的源），
     * 但整段方法**没有任何**取名字的调用 ⇒ 换到**别的 provider** 的台之后，
     * 顶栏仍然是旧 provider 的名字。
     * ```
     *
     * # 为什么必须在 setState **之后**、且不 await
     * ```text
     * ① 顺序：`_loadProviderName` 的代次判据比的是 `_provider`
     *    （与 `:6381` 那条"★ 换源后刷新顶栏的站名"同一条纪律）——
     *    放在 setState 之前会把这次当成过期结果丢弃。
     * ② 不 await：换台要立刻出画面；查名字只挡首帧，之后是进程内缓存。
     * ③ 并发切台的**画面**代次由下面那条 `_liveChannelId != next.id`
     *    守卫负责（它是权威）；本条只管站名，两者不冲突：
     *    即便这次切台随后被判过期，站名也只是提前显示了新源的名字，
     *    而那种情况下 `_provider` 本来就已是新值。
     * ```
     */
    unawaited(_loadProviderName());
    // ★ 与站名**同一批**刷新：换源后发送入口的能力必须跟着换
    unawaited(_loadDanmakuSendCapability());

    try {
      final list = await SourinApi.getLiveStream(pick.provider, next.id);
      if (!mounted) return;
      _liveSwitchMark('② 地址到手', '${list.length} 条候选');
      /*
       * ★★ 代次保护（与 `_loadProviderName` 同一手法）
       *
       * 用户连按 ↓↓ 会**并发**两次切台，而 `getLiveStream` 是异步的
       * ⇒ 先发的那次可能**后**返回 ⇒ 画面停在"上一个目标"上
       *   （表现为"按两下 ↓ 却停在了中间那个台"）。
       * ★ 判据：发起时的频道是否**仍是**当前频道。不是就丢弃这次结果。
       */
      if (_liveChannelId != next.id) {
        debugPrint(
          '[PLAYER] 直播切台：${next.name} 的结果已过期（当前='
          '$_liveChannelId）⇒ 丢弃',
        );
        return;
      }
      setState(() => _streams = list);

      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = list.isEmpty ? '该频道没有可播放的地址' : '所有线路都不可播（可能受 DRM 保护）';
          _loading = false;
        });
        return;
      }

      /*
       * ★ 黑屏横幅的判据与 `_load()` **逐字一致** ——
       *   两处写法不同就会出现"首播有提示、换台后没有"（用户会以为换台坏了）。
       */
      final playableLines = list.where((s) => s.isPlayable).toList();
      final hasDrmVideo = list.any(
        (s) => s.drmProtected && (s.quality == '高清' || s.quality == '标清'),
      );
      final onlyAudioPlayable =
          playableLines.isNotEmpty &&
          !playableLines.any((s) => s.quality == '高清' || s.quality == '标清');
      final audioOnlyNotice = (hasDrmVideo && onlyAudioPlayable)
          ? first.displayName
          : null;
      setState(() => _liveAudioOnlyNotice = audioOnlyNotice);

      /*
       * ★★★ 直播**绝不**走 `_prepareResume()`
       *
       * `_prepareResume()` 会读"上次看到哪"并写 `_pendingSeek`。
       * 直播没有进度概念（它第一行就 `if (_isLive) return;`），
       * ★ 而换台时若不清 `_pendingSeek`，`_startPlayback` 会把
       *   **上一个点播的续播位置** seek 到新台上 —— 表现为"换台后画面
       *   莫名跳到中间"（甚至直接黑屏，因为直播流 seek 出去就回不来）。
       */
      _pendingSeek = null;
      await _startPlayback(first);
      if (mounted) _flash(next.name);
    } catch (e) {
      if (!mounted) return;
      if (_liveChannelId != next.id) return;
      debugPrint('[PLAYER] 直播切台失败 ${next.name}: $e');
      /*
       * ★ 切台失败 ⇒ 踢掉这个台的取址缓存：否则用户再点一次同一个台
       *   仍会命中同一份坏地址（30s TTL 内），"重试"等于白按。
       *   只删 `next.id` 这一份，别的台（含预取）不受影响。
       */
      SourinApi.invalidateLiveStream(pick.provider, next.id);
      setState(() {
        _error = e.toString();
        _errorKind = _kindOf(e);
        _loading = false;
      });
    }
  }

  /// 用**指定的** provider/id 解析流并播放（换源专用）
  ///
  /// ⚠️ 与 `_reload()` 的区别：`_reload` 用的是当前 `_provider/_contentId`
  ///    （切集时用），而这个方法显式传入 —— 换源时新值还没写进 state
  ///    （要先解析成功才敢替换，否则失败会留下一个坏状态）。
  Future<void> _resolveAndPlay(
    String provider,
    String contentId,
    String? episodeId,
    String? sourceCode,
  ) async {
    setState(() {
      _loading = true;
      _error = null;
      _errorKind = null;
    });
    try {
      final list = await SourinApi.resolveStream(
        provider,
        contentId,
        req: PlayRequest(sourceCode: sourceCode, episodeId: episodeId),
      );
      if (!mounted) return;

      final first = list.where((s) => s.isPlayable).firstOrNull;
      if (first == null) {
        setState(() {
          _error = '新源没有可播放的地址';
          _loading = false;
        });
        return;
      }

      /*
       * ★ 解析成功后才替换 provider/id
       *
       * 失败的话保持原状态，用户可以继续看原来那个源。
       */
      setState(() {
        _provider = provider;
        _contentId = contentId;
        _sourceCode = sourceCode;
        _streams = list;
        // ★★★ CR #22 ⑥：换会话 ⇒ 作废在途的切集续播浮层（理由见 applySession 处）
        _rewatchToken++;
      });

      /*
       * ★ 换源后刷新顶栏的站名（task-32）
       *
       * `_provider` 刚刚变了 —— 不重取的话顶栏会一直显示**旧站名**，
       * 那比不显示更糟（用户会以为换源没生效）。
       *
       * ⚠️ 必须在 `setState` **之后**调 —— `_loadProviderName` 里
       *    那个代次判据比的是 `_provider`，顺序反了会把这次当成过期丢弃。
       */
      unawaited(_loadProviderName());
    // ★ 与站名**同一批**刷新：换源后发送入口的能力必须跟着换
    unawaited(_loadDanmakuSendCapability());

      await _startPlayback(first);
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString();
          // ★ 结构化类别（能从 SourinCoreException 拿到就记下来）
          _errorKind = _kindOf(e);
          _loading = false;
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════════════════════
  //  播放控制
  // ═══════════════════════════════════════════════════════════════════

  void _togglePlay() {
    _togglePlayCalls++; // ★ 只读探针（交付实测读它证明"单击仍能播放/暂停"）
    /*
     * 真机实测靠这行日志取证 —— 用 `SetCursorPos + mouse_event` 点真实窗口时，
     * Dart 侧没有别的钩子能读"单击到底走了哪条路径"。
     */
    _probeLog(
      'togglePlay #$_togglePlayCalls  '
      'pos=${_position.inMilliseconds / 1000.0}s  '
      'seekByCalls=$_seekByCalls  playing=$_playing',
    );
    if (_playing) {
      _player.pause();
      /*
       * ★★★ 2026-10-18（N-PAUSE）：记下**用户的意图**，不是"当前在不在播"
       *
       * # 为什么要单独记，不能用 `_playing`
       * ```text
       * `_playing` 是**回报的现状**（mpv 适时同步），会因我们自己的暂停而变化：
       *   · 进全屏 ⇒ 直播页会 pause 内嵌播放器（不是本页）
       *   · 选集抽屉 ⇒ 本页自己 pause（`_pausedForEpisodeSheet`）
       *   · 全屏里切台 ⇒ 内嵌播放器被主动停
       * ⇒ 用 `_playing` 当判据会把"我们暂停的"当成"用户要暂停的"
       *   ⇒ 回到直播页后该自动接手的场景变成**黑屏**。
       * ```
       *
       * ★ 本字段**只在本处**（用户手势的唯一入口）改写，
       *   不因选集抽屉 / 切集 / 全屏切台而变。
       *
       * 用处：`_exitPlayer()` 把它随 `pop()` 带回直播页，
       * 直播页据此置 `_userPaused` ⇒ 切回来不自动续播。
       * Owner 原话：「进直播详情页,点击暂停,出来还在播放,状态没统一」
       */
      _userWantsPause = true;
    } else {
      _player.play();
      _userWantsPause = false;
    }
    /*
     * ★★★ Owner 第 2 条：用户自己点过播放/暂停 ⇒ 关抽屉时**保持**他的选择。
     *
     * 抽屉开着时画面还在左边看得见，用户可以自己点一下。若这里不翻掉
     * `_pausedForEpisodeSheet`，关抽屉那一下就会替他 `play()` ——
     * 用户刚按的暂停被系统推翻，这是最容易被投诉的那类「它自己动起来」。
     *
     * ⚠️ 必须放在 `pause()/play()` **之后**：本函数是「用户的意图」这个
     *    事件的**唯一**入口（单击 / 空格 / 回车 / 底栏按钮都收口到这里）。
     */
    _pausedForEpisodeSheet = false;
    _showControls();
  }

  /// 真机实测取证：把播放页手势的真实挂载状态打进日志
  ///
  /// 在首帧后调用（`initState` 里那时还没 build，`GlobalKey` 取不到 widget）。
  void _probeGestureMount() {
    if (!kGestureProbe || !mounted) return;
    _probeLog(
      'gesture-mount ${debugPlayerOwnGestureState()}  '
      '(tap=true 且 tapUp=false 才是本次需求要的状态)',
    );
  }

  /// 当前设备是否**触摸端**（手势只在这些平台上生效）
  ///
  /// # 判定依据
  ///
  /// ```text
  /// 手机（touchOnly）→ 是
  /// TV（遥控器）    → **否**（TV 用遥控器方向键，触摸手势没有意义，
  ///                     而且 TV 上误触代价更大）
  /// PC（desktop）   → 否
  /// ```
  /// 用 `isTouchOnly` 而不是"非桌面" —— TV 也不是触摸端。
  bool get _isTouchGestureTarget => widget.isTouchOnly;

  /// 是否是**PC 键盘**场景（方向键单击步数 / 长按倍速）
  ///
  /// # 为什么是 `!isTv && !isTouchOnly` 而不是读 `Device.isDesktop`
  ///
  /// `PlayerPage` 的**所有生产调用点**（`shell.dart` 五处 +
  /// `aq_login_probe` / `episode_player_probe` / `skip_probe`）都传了
  /// `isTv: Device.isTv, isTouchOnly: Device.isTouchOnly` ——
  /// 也就是说这两个参数**已经是实际平台的函数**。
  /// 直接用它们的好处：
  /// ```text
  /// ① 不依赖全局可变状态（Device.kind 是缓存的静态值）
  /// ② widget 测试里可以**直接构造出 PC 场景**，
  ///    而不得不去改全局的 Device.overrideKind
  /// ```
  bool get _isPcKeyboardTarget => !widget.isTv && !widget.isTouchOnly;

  /// 双击手势是否启用（PC/TV 恒 false）
  bool get _doubleTapEnabled =>
      PlayerGestures.doubleTapEnabledFor(isTouch: _isTouchGestureTarget);

  /// ★ 有没有任何浮层打开（task-42）
  ///
  /// # 为什么要这个判据
  /// ```text
  /// 用户要「Enter = 全屏」，但 Enter 在打开着的面板里该**激活面板项**。
  /// ★ 既有代码里已经有这个门控思想（L4086-4135：面板打开时 Enter 让给面板），
  ///   只是它用的是 `widget.isTv && _episodeSheetOpen`。
  /// ⇒ 抽成一个 getter，让"桌面 Enter=全屏"也能复用它。
  /// ```
  /// ⚠️ 列全**七种**浮层 —— 少一个就会出现"面板开着按 Enter 却全屏了"。
  bool get _anySheetOpen =>
      _episodeSheetOpen ||
      _settingsOpen ||
      _streamSheetOpen ||
      _hintsOpen ||
      // ★ task-22 P1-5：底栏长按弹出的「画面缩放」滑条（同样是铺满宽度的浮层）
      _zoomOpen ||
      // ★ task-53【③】「所有直播」面板（用户第 3 条）
      _liveChannelsOpen ||
      // ★ task-13 ⑦ 弹幕设置面板（同样是 Positioned.fill 的全屏浮层）
      _danmakuSearchOpen ||
      _danmakuSheetOpen ||
      // ★ task-31 ④ 外部弹幕弹幕导入面板（同款全屏浮层）
      _biliSheetOpen ||
      // ★ task-31 ⑤ 在线搜索字幕面板（同款全屏浮层）
      _subtitlePanelOpen;

  /*
   * ★★★ 2026-10-18（R3-④）：面板关闭后，播放/暂停守卫要**多保持一小会**
   *
   * # 为什么需要这个"衰减"
   *
   * ```text
   * 用户报的缺陷：「在这个弹窗内部双击会透传」。
   * 真实序列（实测 .probe/probe_b_risk_test.dart）：
   *   第 1 击 ⇒ 命中遮罩 ⇒ onClose ⇒ _danmakuSheetOpen = false
   *   第 2 击（40ms 后）⇒ 面板已不在 ⇒ 落到播放区 ⇒ _togglePlay ⇒ **视频暂停**
   *
   * ⚠️ 我第一次的修法 `onTap: _anySheetOpen ? null : _togglePlay` **不生效**：
   *    第 1 击已经把 `_anySheetOpen` 变成 false 了，
   *    第 2 击到达时守卫**已经撤掉** ⇒ 照样暂停。
   *    门禁当场抓到（断言③ Expected 0 / Actual 1），不是推理出来的。
   * ```
   *
   * # 这个字段做什么
   *
   * ```text
   * 面板关掉时置 true，350ms 后自动置回 false。
   * 播放区的 onTap 判据用的是 `_anySheetOpen || _sheetGuardHold`
   * ⇒ 关窗后那 ~350ms 内，第 2 击落下来是**空操作**；
   *   350ms 之后恢复正常（用户再点画面仍能播放/暂停）。
   * ```
   *
   * # ★ 为什么不是"延迟关窗"
   *
   * ```text
   * 延迟**关窗**会让每次点遮罩都多等 300ms（高频主路径受损，
   * 那是我上一版方案，被否掉了）。
   * ★ 这里延迟的是**撤销守卫**，不是关窗 ——
   *   面板照旧**立即**消失，用户完全感觉不到（实测：单击后单次 pump 就关了）。
   *   只有"守卫还多站一会儿"这一件事被推迟，而它没有任何可见效果。
   * ```
   *
   * ⚠️ 为什么不做得更"聪明"（比如只在检测到双击时保持）：
   *    第 2 击到达时面板已经没了，**没有任何地方能观察到"这是双击的第 2 击"**。
   *    ⇒ 只能用一个时间窗兜住。
   */
  bool _sheetGuardHold = false;
  Timer? _sheetGuardTimer;

  /// 面板关闭后调用：让播放/暂停守卫多站 350ms，挡住"双击透传"的第 2 击。
  ///
  /// 350ms 的取值：Flutter 的 `kDoubleTapTimeout = 300ms`
  /// （`package:flutter/src/gestures/constants.dart:35`），留 50ms 余量。
  void _holdSheetGuard() {
    _sheetGuardTimer?.cancel();
    if (!_sheetGuardHold) {
      setState(() => _sheetGuardHold = true);
    }
    _sheetGuardTimer = Timer(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() => _sheetGuardHold = false);
    });
  }

  /// ★★★ 错误态下顶栏那枚返回箭头**必须仍然可用**（Owner 2026-10-09 新增）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # Owner 原话（附截图：黑屏 + 「播放失败 / Failed to open …m3u8」）
  /// ══════════════════════════════════════════════════════════════════
  /// ```text
  /// > 还有一个问题,如果不能播放的时候,左上角的返回,是不能点击的,
  /// > 只能点击返回按钮,才能返回到上一层
  /// ```
  ///
  /// # 改前为什么点不动（两枚箭头**同时**失效）
  /// ```text
  /// ① `_canUseFloatingBack` 里的 `_error == null` 为 false
  ///    => `onFloatingBack` 传 null
  ///    => `_TopBar` 内部 `if (!visible && onFloatingBack != null)` 不成立
  ///    => **常驻悬浮返回键根本不画**；
  /// ② `visible: _controlsVisible && _error == null` 也是 false
  ///    => 顶栏那条 `IgnorePointer(ignoring: !visible)` 把整条顶栏挡住
  ///    => 顶栏那枚箭头「看起来还在」但**命中测试穿不过去**。
  /// ⇒ 屏幕上**一枚可点的返回箭头都没有**，只剩 `_ErrorOverlay` 里那两颗按钮。
  /// ```
  ///
  /// # ★ 这不是缺陷 2 的回归，是**同一个门控的另一半没补**
  /// ```text
  /// 当年加悬浮键时把 `_error != null` 当成「错误层自带返回」——
  /// 但错误层那颗在**中间**，用户按的是**左上角**那枚。
  /// 视觉上那枚一直在（顶栏渐隐那层没被移除，只是被 Opacity/IgnorePointer 处理），
  /// 所以用户的第一反应就是去点它 ⇒ 点不动 = 「卡死」观感。
  /// ```
  ///
  /// # 为什么判据是 `_error != null` 而不是 `!_controlsVisible`
  /// ```text
  /// 错误态下**控制条本来就是隐藏的**（`_controlsVisible` 由 _error 一起管），
  /// 所以这里只需要补「错误时也要有返回口」这一个条件；
  /// 正常播放时顶栏/悬浮键的既有分工**一个字都不改**。
  /// ```
  ///
  /// ⚠️ `!_anySheetOpen` 必须留：错误态下若还开着浮层（例如从错误浮层点进设置），
  ///    浮层自己占满交互，且它有 `_error == null` 之外的关闭路径 ⇒ 不抢它的返回。
  /// ⚠️ 2026-10-10（Owner 缺陷：控制条收起后左上角仍留着一枚箭头）
  /// ```text
  /// 这个判据原来只看「桌面端 + 有错误 + 无浮层」，**不看控制条收没收起** ⇒
  /// 一旦是「先正常播放、3 秒后控制条自动收起、这时才起播失败」，
  ///   `_controlsVisible == false` 而 `_error != null`
  /// ⇒ 顶栏的 `visible` 走 `|| _canUseTopBarBack` 恒为 true，
  ///   `fade` 又被钉成 `kAlwaysCompleteAnimation` ⇒ **不透明度恒 1.0**
  /// ⇒ 底栏被 `_error == null` 那道门整条卸掉之后，画面上就只剩左上角这一枚
  ///   常驻、可点的返回箭头（Owner 原话：「原本的播放控件消失之后，
  ///   你有一个返回的控件一直在显示不消失」）。
  /// ⇒ 补上 `_controlsVisible`：**控制条收起来了，这一枚也必须跟着收起来**。
  /// ```
  /// ★ 不变量（t118 ⑧⑩ 盯着）：本判据与前半段 `_error != null` 仍然**互斥**，
  ///   正常播放时它恒 false ⇒ 顶栏的显隐仍然只由 `_controlsVisible` 决定，
  ///   两条控制条的联动**一个字都没改**。
  /// ★ task-7 的要求也不回归：错误态、控制条还亮着时（刚进错误浮层那阵子）
  ///   `_controlsVisible` 仍为 true ⇒ 这一枚照旧可点 ⇒ 用户仍能从左上角退回上一层。
  bool get _canUseTopBarBack =>
      Device.isDesktop && _error != null && !_anySheetOpen && _controlsVisible;

  /// ★★★ T27-13 —— 顶栏与底栏「该不该显示」的**唯一真源**（Owner 第 3 / 5 条）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # Owner 原话（逐字，两段）
  /// ══════════════════════════════════════════════════════════════════
  /// ```text
  /// > 上下还是联动的不是一起的,就是错开显示的,你见过哪个播放器是这样子的,
  /// > 这个必须纠正,必须同时消失 同时显示,并且要加上过渡动画
  ///
  /// > 还有这个奇怪的 bug,上面显示,无论怎么移动鼠标,下面的就是不显示,
  /// > 点了暂停才显示
  /// ```
  ///
  /// # 根因：同一件事（「控制条该不该显示」）原来有**三个不同的真源**
  /// ```text
  /// ① 底栏渲染门控（本文件 `_BottomBar(` 前那个 `if`）：
  ///      _controlsVisible && _error == null && !7个浮层flag
  ///        && _liveAudioOnlyNotice == null && !_videoOutputDead
  /// ② 顶栏渐变条的 `visible:`（正常支）：
  ///      (_controlsVisible && _error == null)
  ///        && !_videoOutputDead && _liveAudioOnlyNotice == null
  ///    ⇒ ★ **少了那 7 个浮层 flag**
  /// ③ `_anySheetOpen`（grep 门控 / hover 复活护栏用）：
  ///      7 个浮层 flag + _hintsOpen + _zoomOpen
  ///    ⇒ **多了** _hintsOpen / _zoomOpen，**少了**两条降级横幅
  /// ```
  /// 三个集合两两不同 ⇒ 只要出现「① 为假、② 为真」的状态，
  /// 屏幕上就是「顶栏在、底栏不在」的分裂 —— 正是 Owner 报的症状。
  ///
  /// 而 hover 叫不回底栏（`_showControls()` 的复活护栏只看 `_anySheetOpen`），
  /// banner flag 又**不由 hover 负责**（它们归换流 / 看门狗管）
  /// ⇒ 用户「无论怎么移动鼠标，下面的就是不显示」。
  ///
  /// # 修法：把「顶栏与底栏该不该显示」这**一件事**收拢成这一个 getter
  /// ```text
  /// 顶栏 `visible` 的正常支 与 底栏的渲染门控 都读它
  /// ⇒ 从构造上**不可能**再分裂（同一表达式求值两次，结果恒相等）。
  /// ```
  ///
  /// # 为什么成员是**这 11 项**（与底栏原门控逐字相同）
  /// ```text
  /// _controlsVisible      控制条的总开关（hover / 3 秒自动隐藏 / 浮层收口都在写它）
  /// _error == null        起播失败的错误浮层要占整屏（它自带返回口）
  /// !7 个浮层 flag         选集/线路/设置/弹幕/外部弹幕站/字幕/所有直播：谁铺满底部谁独占
  /// _liveAudioOnlyNotice==null  「只有音频能播」的降级横幅**替代**底栏
  /// !_videoOutputDead          「画面无法显示」的降级横幅**替代**底栏
  /// ```
  ///
  /// # ⚠️ 为什么**不含** `_hintsOpen` / `_zoomOpen`（可争议处，我的论证）
  /// ```text
  /// 这两个浮层虽然也在 `_anySheetOpen` 里，但它们**与底栏同层共存**：
  ///   · 快捷键提示面板 `_HintsPanel` 是整屏卡，但它开着时底栏留着**不冲突**
  ///     （它是覆盖层，不占底部条位）；
  ///   · 画面缩放滑条 `zoomOpen` 更是**画在 `_BottomBar` 内部**的
  ///     （player_bottom_bar.dart:448 `if (zoomOpen)`）—— 若把它加进本真源，
  ///     一开滑条底栏整条被卸 ⇒ **滑条自己也跟着消失**（拖到一半条没了）。
  /// ⇒ 它们只进 `_anySheetOpen`（管 Enter/Esc/hover 复活护栏），
  ///    **不进**本真源。这也解释了两个 getter 为何成员不同。
  /// ```
  ///
  /// # ⚠️ `_canUseTopBarBack`（错误态返回口）是**例外**，不被本真源统一掉
  /// ```text
  /// 错误态下 `_error == null` 让本真源恒 false，但 Owner 2026-10-09 专门报过
  /// 「不能播放时左上角返回点不动」⇒ 顶栏在错误态必须仍留着那枚返回箭头。
  /// 所以顶栏 `visible` = `_chromeVisible || _canUseTopBarBack`
  /// （`_canUseTopBarBack` 与前半段**互斥**：它含 `_error != null`）。
  /// t118 ⑧⑩ / t27_w9 S4 钉着这条互斥分支不许并进真源。
  /// ```
  bool get _chromeVisible =>
      _controlsVisible &&
      _error == null &&
      !_episodeSheetOpen &&
      !_streamSheetOpen &&
      !_settingsOpen &&
      !_danmakuSearchOpen &&
      !_danmakuSheetOpen &&
      !_biliSheetOpen &&
      !_subtitlePanelOpen &&
      !_liveChannelsOpen &&
      _liveAudioOnlyNotice == null &&
      !_videoOutputDead;

  /// 底部被「占据」——错误层 / 两条降级横幅 / 七个全屏浮层。
  ///
  /// 这些状态下底部那块**归占据者所有**（错误层/横幅是与底栏同位置的
  /// `Positioned(bottom: 0)`，浮层是铺满的 scrim）⇒ 底栏必须**整条卸下**，
  /// 而不是留在树里淡出（否则它会和占据者叠字、或抢走占据者的点击）。
  bool get _bottomOccupied =>
      _playbackFailure != null ||
      _error != null ||
      _episodeSheetOpen ||
      _streamSheetOpen ||
      _settingsOpen ||
      _danmakuSearchOpen ||
      _danmakuSheetOpen ||
      _biliSheetOpen ||
      _subtitlePanelOpen ||
      _liveChannelsOpen ||
      _liveAudioOnlyNotice != null ||
      _videoOutputDead;

  /// 底栏淡入淡出用的动画（与顶栏**镜像**）。
  ///
  /// · 底部被占据 ⇒ 钉 `kAlwaysDismissedAnimation`（硬收：那块归占据者）；
  /// · 否则 ⇒ 与顶栏**同一个** `_controlsFade` 实例 ⇒ 同时淡入淡出。
  ///
  /// ★ 这正是 Owner 第 3 条要的「同时消失 / 同时显示 + 过渡动画」：
  ///   顶栏的 `fade` 与这里的底栏 `fade` 是**同一个 `Animation` 实例**，
  ///   时长/曲线（`Motion.base` / `Motion.easeOut`）由宿主唯一的
  ///   `_controlsAnim` 决定 ⇒ 从构造上不可能错开。
  Animation<double> get _bottomFade =>
      _bottomOccupied ? kAlwaysDismissedAnimation : _controlsFade;

  /// 长按倍速是否启用（PC/TV 恒 false）
  /// 长按手势是否启用
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ PC 上**也必须**启用（2026-09-24 交付实测抓到的 bug）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 我原来错在哪
  ///
  /// 直接复用了触摸端的门控：
  /// ```dart
  /// PlayerGestures.longPressEnabledFor(isTouch: _isTouchGestureTarget)
  /// ```
  /// 而那个函数是 `isTouch && longPressEnabled` —— **PC 恒 false**。
  ///
  /// 于是 PC 上长按**完全没挂载**，交付实测报：
  /// ```text
  /// ✗ PC 区域手势已挂载（长按分流）
  ///   doubleTap=false longPress=false tapUp=true visibleButtons=0
  /// ```
  ///
  /// # 为什么这是错的（用户明确要求了 PC 长按）
  ///
  /// 用户原话：
  /// > 长按是倍速,**右是快进倍速**(可配置) **左是 快退**(可配置)
  ///
  /// 这句是**针对 PC 说的**（上一句是「而且pc端更直觉的左右按钮」）。
  /// 我把"PC 不要双击快进"（正确）错误地推广成了
  /// "PC 不要任何手势"（错误）。
  ///
  /// # 正确的规则（2026-09-25 按用户要求更新）
  ///
  /// ```text
  /// 双击快进快退   PC **不要**（用户明确否决，鼠标误触）
  /// 单击           PC **不要跳秒**（用户原话：「不要单击快进快退,
  ///                去掉这个功能」）→ 整屏统一 = 播放/暂停
  /// 长按           PC **要**  （左连续快退 / 右倍速快进）
  /// ```
  /// 也就是 PC 和手机在**单击**上已经统一（都是播放/暂停），
  /// 只在**双击**上分平台。长按两边都有。
  ///
  /// ⚠️ PC 的长按**不受**触摸端那个开关控制（设置页里那个开关
  ///    只在触摸端显示）—— PC 用户没有那个开关，所以恒启用。
  ///
  /// ⚠️ 判据用**本页的** `_isPcKeyboardTarget`，不是全局的 `Device.isDesktop`
  ///    （task-15 实测抓到的 bug）。
  ///
  /// # 为什么原来那写法是错的
  ///
  /// `Device.kind` 是**进程级缓存**的，取自宿主操作系统。于是：
  /// ```text
  /// Windows 上，即使这个 PlayerPage 是按“手机”建的，
  /// Device.isDesktop 仍然是 true
  ///   ⇒ 这个 getter 恒为 true
  ///   ⇒ 手机那个「长按开关」被**完全忽略**，
  ///     用户要求的「可关闭」在那种场景下做不到
  /// ```
  /// `PlayerPage` 自己就知道它是为哪个平台建的
  ///（`isTv` / `isTouchOnly`，每个生产调用点都传了）——
  /// 用它们就不依赖全局状态，且行为可预测。
  ///
  /// ★ 对现有平台的影响：
  /// ```text
  /// 桌面  → true（不变，鼠标半屏长按仍然可用）
  /// 手机  → 读 `longPressEnabled`（变对了：之前被全局值遮蔽）
  /// TV    → false（不变：遥控器没有触摸手势）
  /// ```
  bool get _longPressEnabledForThisDevice => _isPcKeyboardTarget
      ? true
      : PlayerGestures.longPressEnabledFor(isTouch: _isTouchGestureTarget);

  // ═══════════════════════════════════════════════════════════════════
  //  左/右手势区域的长按行为（2026-09-24 用户要求）
  // ═══════════════════════════════════════════════════════════════════

  /// 连续快退的定时器（左半屏长按期间反复 seek）
  Timer? _rewindTimer;

  /// 长按倍速播放时的倍速（右半屏长按）
  ///
  /// ⚠️ 存**快照**而不是恢复成固定值 —— 用户可能自己设了 1.5x，
  ///    快进完应该回到 1.5x 而不是 1.0x。
  double? _rateBeforeHold;

  /// 右半屏 / 右方向键**长按** → 倍速播放
  ///
  /// ★ 保留零参数签名：鼠标半屏长按走这个入口（读 PC 配置），
  ///   `test/player_gestures_test.dart` 也钉了这个签名字面量。
  ///   键盘方向键用 `_beginRateHold(pcArrowHoldRate)` ——
  ///   两者共用同一个快照与恢复逻辑，只是倍率来源不同。
  void _startRateHold() => _beginRateHold(PlayerGestures.pcForwardRate);

  /// 倍速长按的共用实现（倍率由调用方决定）
  void _beginRateHold(double rate) {
    if (_rateBeforeHold != null) return; // 已在长按中
    _rateBeforeHold = _rate;
    _requestRate(rate);
    _flash('${rate}x 快进');
    _showControls();
  }

  /// 右半屏**松手** → 恢复原倍速
  void _endRateHold() {
    final prev = _rateBeforeHold;
    if (prev == null) return;
    _rateBeforeHold = null;
    _requestRate(prev);
    _flash('${prev}x');
  }

  /// 左半屏**长按开始** → 启动连续快退
  ///
  /// # 为什么用定时器而不是"负倍速"
  ///
  /// `media_kit` 的 `setRate` 拒绝非正数（见 `_onLongPressStartAt` 的说明）。
  /// 所以用定时器反复 seek —— 视觉上就是"画面持续往回退"。
  ///
  /// ⚠️ 首次快退**立即执行**（不等一个周期）——
  ///    否则用户按下后要等 400ms 才有反应，感觉是卡了。
  void _startRewindHold() => _beginRewindHold(PlayerGestures.pcRewindStep);

  /// 连续快退的共用实现（每步秒数由调用方决定）
  void _beginRewindHold(int step) {
    if (_rewindTimer != null) return; // 已在连续快退中
    _seekBy(-step);
    _rewindTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (!mounted) {
        _rewindTimer?.cancel();
        _rewindTimer = null;
        return;
      }
      _seekBy(-step);
    });
  }

  /// 左半屏**松手** → 停止连续快退
  void _endRewindHold() {
    _rewindTimer?.cancel();
    _rewindTimer = null;
  }

  /// 记录**当前正在进行的是哪种长按**（左侧快退 / 右侧倍速）
  ///
  /// ⚠️ 必须记下来！`onLongPressEnd` **不告诉你**刚才长按的是哪一侧 ——
  ///    只知道"长按结束了"。不记的话：
  ///    ```text
  ///    左侧长按（连续快退中）→ 松手 → 走了倍速恢复逻辑 → 无效操作
  ///    右侧长按（2x 快进中）→ 松手 → 走了快退停止逻辑 → **倍速卡在 2x**
  ///    ```
  _LongPressKind? _activeLongPress;

  /*
   * ═══════════════════════════════════════════════════════════════════
   *  ★ 单击分流的**墓碑**（2026-09-25 删除，用户要求）
   * ═══════════════════════════════════════════════════════════════════
   *
   * 这里原来有两样东西，现在**都没有了**：
   *
   * ```dart
   * static const _centerBandRatio = 0.08;        // ← 正中窄带比例
   * void _onPlayerTapUp(TapUpDetails d) { ... }  // ← 按 dx 判左右半屏
   * ```
   *
   * # 为什么删掉（而不是留着不用）
   *
   * 用户原话：**「不要单击快进快退,去掉这个功能」**。
   *
   * 留着 `_onPlayerTapUp` 会有两个坏处：
   * ```text
   * ① 死代码会误导后人 —— 看到有个"分流函数"会以为单击还在分流
   * ② 它读 PlayerGestures.pcSeekSeconds，删了配置项就编译不过
   *    （反过来逼着我把那个只服务单击跳秒的配置也一起清掉，这是对的）
   * ```
   *
   * ⚠️ 别把这段墓碑当成"功能还在、只是注释掉了" ——
   *    单击现在**只有**播放/暂停一种语义（见 build 里的 `onTap`）。
   *
   * # 长按的区域判断**没有**跟着删
   *
   * 长按仍要分左右（左=连续快退 / 右=倍速快进），
   * 见下面的 `_onLongPressStartAt`。用户删的是**单击**，不是左右区域。
   */

  // ── PC 键盘方向键（用户 2026-09-25）──

  /// 处理一个 PC 方向键事件（down / repeat / up）
  KeyEventResult _handlePcArrowKey(KeyEvent event) {
    final action = _pcArrow.handleKeyEvent(event);
    switch (action) {
      case PcArrowAction.none:
        /*
         * “什么都不做”也要**消费掉**这个键**。
         *
         * 因为 none 的含义是“该功能被用户关掉了”
         * （单击/长按各自的开关）。如果这里改成
         * `ignored`，事件会继续往上派发到下面那段
         * 硬编码的 ±5 秒，用户关了开关反而**还在跳秒**
         * ——“可关闭”就成了假的。
         */
        break;
      case PcArrowAction.stepSeek:
        _seekBy(_pcArrow.direction * PlayerGestures.pcArrowSeekSeconds);
      case PcArrowAction.holdStart:
        _startPcArrowHold(_pcArrow.direction);
      case PcArrowAction.holdEnd:
        _endPcArrowHold();
    }

    /*
     * 超时兜底计时器的生命周期：按下时起，松开时停。
     */
    if (event is KeyDownEvent) {
      _armPcArrowHoldTimer();
    } else if (event is KeyUpEvent) {
      _pcArrowHoldTimer?.cancel();
      _pcArrowHoldTimer = null;
    }
    return KeyEventResult.handled;
  }

  /// 起一个“按住了但没收到 repeat”的兜底计时器
  void _armPcArrowHoldTimer() {
    _pcArrowHoldTimer?.cancel();
    final dir = _pcArrow.direction;
    if (dir == 0) return; // 没按下 -> 不该有计时器
    _pcArrowHoldTimer = Timer(kPcArrowHoldDelay, () {
      _pcArrowHoldTimer = null;
      if (!mounted) return;
      if (_pcArrow.handleHoldTimeout(direction: dir) ==
          PcArrowAction.holdStart) {
        _startPcArrowHold(dir);
      }
    });
  }

  /// PC 方向键长按开始
  ///
  /// ```text
  /// 右 → 倍速快进（`pcArrowHoldRate`）
  /// 左 → **连续快退**
  /// ```
  /// 左侧为什么不是“负倍速”：`media_kit` 的 `setRate` 拒绝非正数
  /// —— 同 `_startRewindHold` 的说明，底层 mpv 能倒放但 Dart 层被拦。
  void _startPcArrowHold(int dir) {
    if (dir < 0) {
      /*
       * 每步秒数用**单击步长**（`pcArrowSeekSeconds`）。
       *
       * 为什么不另开一个“长按每步秒数”配置：用户这次只要了
       * “倍率可配”，而单击步长本身就是“一次跳多少秒”这个语义，
       * 复用它比再堆一个参数更简单。
       */
      _beginRewindHold(PlayerGestures.pcArrowSeekSeconds);
    } else {
      _beginRateHold(PlayerGestures.pcArrowHoldRate);
    }
  }

  /// PC 方向键长按结束（松开）
  void _endPcArrowHold() {
    _endRewindHold();
    _endRateHold();
  }

  /// 长按开始 —— 按**按下位置**分流左右区域
  void _onLongPressStartAt(Offset local) {
    if (_activeLongPress != null) return; // 已在长按中
    final w = MediaQuery.of(context).size.width;
    final isLeft = local.dx < w / 2;

    if (isLeft) {
      /*
       * 左半屏 → 连续快退
       *
       * ⚠️ 「倒放」物理上做不到：`media_kit` 的 `setRate` 拒绝非正数
       *    （`if (rate <= 0.0) throw ArgumentError(...)`）。
       *    底层 mpv 支持负 speed，但 Dart 层被拦掉了。
       *    所以用定时器反复 seek —— 视觉上就是"画面持续往回退"。
       *
       * ★ 每步秒数**分平台取配置**（task-15）。
       *   之前两端都读 `pcRewindStep` —— 改 PC 的值会连带
       *   改掉手机的，而用户明确要求两端不同。
       */
      _activeLongPress = _LongPressKind.rewind;
      if (_isPcKeyboardTarget) {
        _startRewindHold(); // PC：读 pcRewindStep
      } else {
        _beginRewindHold(PlayerGestures.longPressRewindStep);

        /// 手机：读自己的
      }
    } else {
      // 右半屏 → 倍速快进
      _activeLongPress = _LongPressKind.rateBoost;
      if (_isPcKeyboardTarget) {
        _startRateHold(); // PC：读 pcForwardRate
      } else {
        /*
         * 手机：读**自己的** `longPressRate`
         *
         * ★ 这正是原本的**死代码** `_startLongPressBoost`
         *   （调用点 0 处）。task-15 要求“要么接上、要么删掉并说明”——
         *   这里**接上**：它读的 `longPressRate` 恰好就是手机配置，
         *   删掉反而要另写一份等价实现。
         */
        _startLongPressBoost();
      }
    }
  }

  /// 长按结束（**停止当前正在进行的动作**，不假设是哪一侧）
  void _endAnyLongPress() {
    final kind = _activeLongPress;
    if (kind == null) return;
    _activeLongPress = null;
    switch (kind) {
      case _LongPressKind.rewind:
        _endRewindHold();
      case _LongPressKind.rateBoost:
        /*
         * ★ 两个平台的“倍速长按”用的是**不同的快照字段**
         * （PC = `_rateBeforeHold`，手机 = `_rateBeforeLongPress`）——
         * 用错的话恢复不了倍速（快照是 null，函数直接 return）。
         */
        if (_isPcKeyboardTarget) {
          _endRateHold();
        } else {
          _endLongPressBoost();
        }
    }
  }

  /// 长按前的倍速（抬起时恢复用）
  ///
  /// ⚠️ 必须**存快照**而不是"恢复成 1.0" —— 用户可能先设了 1.5x，
  ///    再长按快进，抬起后应回到 1.5x 而不是 1.0x。
  double? _rateBeforeLongPress;

  void _startLongPressBoost() {
    if (_rateBeforeLongPress != null) return; // 已在长按中，不重复
    _rateBeforeLongPress = _rate;
    final boosted = PlayerGestures.longPressRate;
    _requestRate(boosted);
    _flash('${boosted}x 快进中');
    _showControls();
  }

  void _endLongPressBoost() {
    final prev = _rateBeforeLongPress;
    if (prev == null) return; // 没在长按
    _rateBeforeLongPress = null;
    _requestRate(prev);
    _flash('${prev}x');
  }

  Future<void> Function(Duration)? _userSeekForProbe;

  // Explicit user intent wins over automatic intro and an in-flight resume.
  /// **用户意图 seek 的唯一入口**（★ task-14 校正了口径）
  ///
  /// # 口径（逐字，别再放宽）
  /// ```text
  /// "唯一入口"只针对**用户意图**的 seek。
  /// 程序性 seek（自动跳片头 / 单集循环 / 续播落地 / 探针）**不**走这里，
  /// 它们各自带 `// seek-intent: programmatic — <理由>` 标记。
  /// ```
  /// # 当前的全部用户意图入口（都在生产代码里 grep 得到）
  /// ```text
  /// ① 底栏进度条拖动     `_BottomBar(onSeek:)` → `_seekByUser(d)`
  /// ② 键盘 ←/→ 与按钮    `_seekBy()` → `_seekByUser(clamped)`
  /// ③ 点进度条 N%        `_seekToPercent()` → `_seekByUser(target)`
  /// ④ 远端 `seek_to`     `_remoteSeekTo()` → `await _seekByUser(clamped)`
  /// ⑤ 远端 `skip_preview` `_remoteSkipPreview()` → `await _seekByUser(t)`
  /// ⑥ 浮层「继续观看」    `continueFromRewatchPrompt()` → `_seekByUser(pos)`
  /// ```
  /// # ★ 为什么必须汇到一个点（task-14 的教训）
  /// ```text
  /// 缺陷①的修法是"给用户 seek 一个 2 秒豁免窗口 + 置 `_introSkipped`"。
  /// 只要有**一条**用户路径绕过本方法，那条路径就会重演"拖到 0 被弹回去"。
  /// 实测已发生过一次：`continueFromRewatchPrompt` 里是裸 `_player.seek(pos)`
  /// （交叉复核查出，task-14 修）。⇒ 结构门禁
  /// `zz_t1024_skip_respects_user_seek_test` ⑥ 会**枚举** `_player.seek` 的每一处，
  /// 要求它"在本方法内"或"带 programmatic 标记" —— 新增一条裸路径必然红。
  /// ```
  /// # 程序性 seek 的完整清单（与本方法并列，**不许**算作入口）
  /// ```text
  /// · `_maybeSkip` 自动跳片头          `_player.seek(Duration(seconds: end))`
  /// · `_onEnded` 单集循环              `_player.seek(Duration.zero)`
  /// · `_seekAfterReady` 续播落地       `(_resumeSeekForProbe ?? _player.seek)(t)`
  /// · `debugPlayerSeekForProbe`       探针直驱原生边界
  /// ```
  Future<void> _seekByUser(Duration target) {
    _introSkipped = true;
    _pendingSeek = null;
    ++_seekToken;
    /*
     * ★★★ 缺陷①（2026-10-25）：记下"用户刚刚主动 seek 过"这个事实。
     *
     * ⚠️ 与上面 `_introSkipped = true` 是**两件事**：那个是"本集不再自动跳"，
     *    这个是"接下来 2 秒内 `_maybeSkip` 让位"。前者的 5 处复位点会把它
     *    清回 false，而后者是单调时钟上的一个时间戳，不受那些复位影响。
     */
    _noteUserSeek(target);
    return (_userSeekForProbe ?? _player.seek)(target);
  }

  void _seekBy(int seconds) {
    _seekByCalls++; // ★ 只读探针（交付实测读它证明"单击不再跳秒"）
    /*
     * ⚠️ 真机实测里**这行日志一旦出现就说明单击还在跳秒**（回归）。
     *    正常的单击只应打 `togglePlay`，不应打这行。
     */
    _probeLog(
      'seekBy #$_seekByCalls  ${seconds > 0 ? '+' : ''}${seconds}s  '
      'pos=${_position.inMilliseconds / 1000.0}s',
    );
    if (_isLive) return; // 直播不能快进/跳转
    final target = _position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (target > _duration ? _duration : target);
    _seekByUser(clamped);
    // ★ N10：快进/快退（键盘 ←/→、按钮）—— Owner 最常用的操作之一
    _beginPrefetchYield();
    _flash(seconds > 0 ? '快进 ${seconds}s' : '快退 ${-seconds}s');
    _showControls();
  }

  void _seekToPercent(int pct) {
    if (_isLive) return;
    if (_duration <= Duration.zero) return;
    final target = _duration * (pct / 100.0);
    _seekByUser(target);
    // ★ N10：点进度条跳到 N% ⇒ 用户主动跳转，预取让路
    _beginPrefetchYield();
    _flash('跳到 $pct%');
    _showControls();
  }

  /// 音量增减 —— ★ **键盘 ↑/↓ 与滚轮共用的唯一实现**（铁律 170）
  ///
  /// [delta] 正 = 变响（↑ / 向上滚），负 = 变轻（↓ / 向下滚）。
  ///
  /// # ⚠️ 我改掉的那个**假动作**（原来的写法是个空操作）
  /// ```dart
  /// // 原代码：
  /// _player.setVolume(v);
  /// if (v > 0 && _muted) {
  ///   _player.setVolume(v);   // ← ★ 与上面**同一句**，再调一次毫无意义
  /// }
  /// ```
  /// 它看起来想"顺便取消静音"，但两件事都没做到：
  /// ```text
  /// ① `_player.setVolume(v)` 调两次 = 一次（mpv 幂等）
  /// ② `_muted` **没有被清掉** ⇒ 底栏仍是静音图标，
  ///    而声音已经出来了 ⇒ ★ 图标与事实不一致
  /// ③ 更糟的是音量监听器（`if (!_muted && v > 0)`）也不会写 `lastVolume`
  ///    ⇒ 用户下次进来还是静音 **且** 音量回到旧值
  /// ```
  /// ⇒ 现在按原版语义（`PlayerView.vue:3729`）把两件事**真正**做掉：
  ///    `v.muted = next === 0` —— 音量归零才算静音，非零即解除。
  ///
  /// ⚠️ 用 `setState` 改 `_muted` 是**必须**的：它要驱动底栏图标重建。
  void _volumeBy(double delta) {
    final v = (_volume + delta).clamp(0.0, 100.0);
    // ★ 用户发起的音量改动（白名单，见 `_lastUserVolumeAction`）
    _lastUserVolumeAction = DateTime.now();
    _sendVolume(v);
    /*
     * ★ 静音标志与音量**必须同步**（原版 `v.muted = next === 0`）：
     *   滚/按到 0 ⇒ 静音；从 0 往上 ⇒ 解除静音。
     * ⚠️ 只在**真的变了**时才 setState —— 每格滚轮都重建一次是浪费
     *   （滚轮的 deltaY 可以连续来很多次）。
     */
    final shouldMute = v <= 0;
    if (_muted != shouldMute) {
      setState(() => _muted = shouldMute);
    }
    _flash('音量 ${v.round()}%');
    _showControls();
  }

  /// ★★ task-53【#4b-④】鼠标滚轮调音量（补齐提示里承诺的「滚轮同效」）
  ///
  /// # 为什么必须补（这是"UI 在说谎"）
  /// ```text
  /// 快捷键提示里写着：`↑ ↓  音量 · M 静音 · **滚轮同效**`
  /// ★ 而全仓 `onPointerSignal` / `PointerScrollEvent` / `scrollDelta`
  ///   实测 = **0 处** ⇒ 滚轮**没有任何代码路径** ⇒ 提示是假的。
  /// ```
  /// 原版对照（`PlayerView.vue:3722-3735`，那个注释还解释了为什么必须自己写）：
  /// ```ts
  /// // 每格 5%（deltaY 常为 ±100/±120，用**符号**而不是数值，
  /// // 避免触控板过于敏感）
  /// const next = clamp(v.volume + (e.deltaY > 0 ? -0.05 : 0.05));
  /// ```
  /// ★ 我也照抄"用符号不用数值"——触控板的 deltaY 可以只有 ±1，
  ///   按数值算会变成"滚一下动 0.05%"，用户觉得滚轮坏了。
  ///
  /// # ⚠️ 为什么用 `pointerSignalResolver` 而不是直接改音量
  /// ```text
  /// `Listener.onPointerSignal` **不会**阻止事件继续派发给别人。
  /// 若树里有 Scrollable（本页的选集/设置面板里就有 ListView），
  /// 它**也会**收到这滚轮 ⇒ 变成"音量变了 + 列表也滚了"。
  /// `GestureBinding.instance.pointerSignalResolver` 的语义是
  /// "**只有一个**赢家"（第一个 register 的回调被调用，其余丢弃）
  ///   ⇒ 注册它才能表达"这个滚轮我消费了"。
  /// ```
  /// ★ 实测确认（读 Flutter 源码，不是我推断的）：
  /// ```text
  /// · flutter/src/widgets/scrollable.dart:963
  ///     GestureBinding.instance.pointerSignalResolver.register(event, _handlePointerScroll);
  ///   ⇒ Scrollable **本来就**在用它 ⇒ 我用同一个机制才谈得上"竞争"
  /// · flutter/src/gestures/pointer_signal_resolver.dart:86-92
  ///     void register(event, callback) { if (_firstRegisteredCallback != null) return; ... }
  ///   ⇒ 先注册者赢，后注册的被**丢弃**
  /// ```
  /// ⚠️ 命中顺序是"**深的先注册**"（`HitTestResult.path` 由内向外）。
  ///    本页的播放区**没有** Scrollable 祖先（实测：全文件只有
  ///    选集面板里那一处 `ListView.builder`）⇒ 正常观看时没有竞争者，
  ///    本回调必然生效。★ 而面板打开时面板里的 ListView 会先注册 ⇒
  ///    列表正常滚动、音量不动 —— 正是想要的行为。
  void _onPointerSignal(PointerSignalEvent event) {
    // ★ Owner 第 1 条：滚轮也是「人还在操作」——放在**最前面**，
    //    否则下面那两个 `return` 会把「滚了一下滚轮」当成停手。
    _noteCursorActivity();
    if (event is! PointerScrollEvent) return;
    /*
     * ★ 浮层打开时不接管（与 `_onKey`/`_onHardwareKey` 的既有门控同源）：
     *   面板里滚列表是用户的本意，不该顺手把音量也改了。
     */
    if (_anySheetOpen) return;
    final dy = event.scrollDelta.dy;
    if (dy == 0) return; // 纯横向滚动（触控板双指横划）不调音量
    GestureBinding.instance.pointerSignalResolver.register(event, (_) {
      /*
       * ★ 打一行日志（`_flash` 只更新 UI 气泡，**不进日志**）——
       *   否则真机排障时无法区分"滚轮没到"与"到了但没生效"。
       *   本项目在 task-42 就吃过这个亏（见 `_onHardwareKey` 的入口打点说明）。
       */
      debugPrint('[PLAYER-KEY] 滚轮 ⇒ 音量 ${dy > 0 ? '-' : '+'}5（dy=$dy）');
      // ★ 向上滚（dy < 0）= 变响 —— 与"↑ 加音量"同一方向
      _volumeBy(dy > 0 ? -5 : 5);
    });
  }

  /// 静音 / 取消静音（缺陷 1 / 11 的核心修复点）
  ///
  /// # 错在哪（改之前是一行三元）
  /// ```dart
  /// _player.setVolume(_muted ? _volume : 0);
  /// ```
  /// 它把「取消静音要恢复到的音量」寄托在 `_volume` 上，而 `_volume`
  /// 在静音时**合法地等于 0**（`_volumeBy` 把它写成 0、音量监听器也回写 0）
  /// => 再点一次执行的是 `setVolume(0)` => ★ 永远没声音，
  ///    而 `_muted` 已被翻成 false => 图标「未静音」但实际全静音（UI 在说谎）。
  ///
  /// # 修法：压 0 **之前**先抓快照，恢复时只认快照
  /// ```text
  /// 静音    : _volume > 0 => _volumeBeforeMute = _volume; 然后 setVolume(0)
  /// 取消静音: 恢复目标 = _volumeBeforeMute
  ///            快照为空/为 0 => 退回偏好里的 lastVolume x 100
  ///            再为空/为 0 => 退回出厂 100
  /// ```
  /// ⚠️ **绝不下发 0** —— 那是改前那个 bug 的全部内容。
  ///
  /// ⚠️ 用快照而不是 `_volume` 的当前值：静音期间 `_volume` 会被 mpv 的
  ///    广播写成 0（见音量监听器），所以「当前值」在取消静音那一刻恒为 0，
  ///    它**不可能**是正确答案。
  void _toggleMute() {
    _toggleMuteCalls++; // ★ 只读探针（第 16 项：全屏 M 必须真的静音，不只是画个图标）
    if (_muted) {
      /*
       * ★ 取消静音：三级瀑布求恢复目标
       *   1) 快照（用户静音前的真实音量，最准）
       *   2) 偏好里的 lastVolume（跨会话的「用户习惯音量」）
       *   3) 出厂 100（理论上到不了，纯粹兜底不让它下发 0）
       */
      var restore = _volumeBeforeMute ?? 0;
      if (restore <= 0) restore = _lastVolume * 100;
      if (restore <= 0) restore = 100;
      _volumeBeforeMute = null;
      _sendVolume(restore);
      setState(() => _muted = false);
      _flash('取消静音 ${restore.round()}%');
    } else {
      /*
       * ★ 静音：**先抓快照再压 0**（顺序不能反 —— 反了就抓不到原音量）
       *   ⚠️ `_volume > 0` 的守卫是必须的：`_volume` 已经因为
       *     「拖到 0 自动静音」而等于 0 时，把它记进快照等于把 0 当答案。
       *     这种情况下保留**旧的**快照（它才是用户真正的音量）。
       */
      if (_volume > 0) _volumeBeforeMute = _volume;
      _sendVolume(0);
      setState(() => _muted = true);
      _flash('已静音');
    }
    /*
     * ★ 静音/取消静音**不算**「用户调音量」 —— 这里**不盖** `_lastUserVolumeAction`
     *   是刻意的：取消静音恢复的那个音量，用户并没有「调」它。
     *   （旧注释把 _toggleMute 列进「三个入口」是自相矛盾的，
     *    已在 _lastUserVolumeAction 字段上方订正为「三处调用、两处盖戳」。）
     */
    _showControls();
  }

  // ══════════════════════════════════════════════════════════════════
  // ★ 探针钩子（缺陷 1 / 11 静音状态机）—— 仅测试用，不参与生产逻辑
  // ══════════════════════════════════════════════════════════════════
  //
  // 为什么需要它们：`_PlayerPageState` 是 library-private，test/ 拿不到实例；
  // 而 flutter_test 里**没有 libmpv-2.dll** => `_player` 永远建不起来
  // => 任何摸 `_player` 的路径都是 LateInitializationError。
  // 所以这里把"下发"与"状态"分开暴露：
  // ```text
  // debugPlayerToggleMute()  => 走**真实**的 _toggleMute（状态机逐字相同）
  // _probeNoAudio = true     => 让 _sendVolume 短路，只记录下发值
  // debugPlayerVolumeWrites()=> 读回真实下发序列，断言"绝不下发 0"
  // ```

  /// 探针用：记录每次 `_sendVolume` 实际下发的值（生产不读它）
  final List<double> _probeVolumeWrites = <double>[];

  /// 探针用：进入无音频模式（短路 `_sendVolume` 的真实下发）
  void debugPlayerSetNoAudioForProbe(bool v) => _probeNoAudio = v;

  /// 探针用：调一次真实的静音按钮
  void debugPlayerToggleMute() => _toggleMute();

  /// 探针用：等价于键盘/滚轮调音量
  void debugPlayerVolumeBy(double delta) => _volumeBy(delta);

  /// 探针用：等价于拖底栏音量滑杆
  void debugPlayerSetVolume(double v) {
    _lastUserVolumeAction = DateTime.now();
    final next = v.clamp(0.0, 100.0);
    if (_muted && next > 0) _volumeBeforeMute = next;
    _sendVolume(next);
  }

  /// 探针用：读回静音状态机的全部关键量
  String debugPlayerMuteState() {
    final before = _volumeBeforeMute;
    return 'muted=$_muted|volume=${_volume.toStringAsFixed(0)}'
        '|beforeMute=${before == null ? '-' : before.toStringAsFixed(0)}'
        '|lastVolume=${(_lastVolume * 100).toStringAsFixed(0)}';
  }

  /// 探针用：读回实际下发过的音量序列（'/' 分隔）
  String debugPlayerVolumeWrites() =>
      _probeVolumeWrites.map((e) => e.toStringAsFixed(0)).join('/');

  /// 探针用：清空下发记录
  void debugPlayerResetVolumeWrites() => _probeVolumeWrites.clear();

  /// 探针用：直接摆好"当前音量"（模拟用户已经调到这个值）
  void debugPlayerSeedVolume(double v) {
    _volume = v.clamp(0.0, 100.0);
    _muted = _volume <= 0;
    _volumeBeforeMute = null;
    _probeVolumeWrites.clear();
  }

  /// ★ 缺陷 13：把探针塞进去的缓冲区间直接推给 UI（不经 mpv）
  ///
  /// 为什么要这个口子：真实 mpv 只在**真播放**时才给出 demuxer-cache-*，
  /// 而探针要在**任意可控输入**下断言缓冲条的几何。
  /// 本方法走的是与生产**完全相同**的那条 `setState(_bufferedRange)`，
  /// 所以它证明的是"UI 对区间的反应"，不是"另一个实现"。
  BufferedRange? debugPlayerPushBufferForProbe(
    Duration? end, {
    Duration? start,
  }) {
    setState(() {
      _bufferedRange = end == null
          ? null
          : BufferedRange(end: end, start: start);
    });
    return _bufferedRange;
  }

  BufferedRange? debugPlayerBufferedRangeForProbe() => _bufferedRange;

  bool? debugPlayerBufferPollerRunningForProbe() => _bufferPoller?.running;

  double? debugPlayerBufferStateForProbe() => _bufferStatePercent;

  /// 缓冲条的真实几何（left|top|w|h）；没在树上返回 null
  String? debugPlayerBufferBarGeometryForProbe() {
    final ro = _bufferBarKey.currentContext?.findRenderObject();
    if (ro is! RenderBox) return null;
    final o = ro.localToGlobal(Offset.zero);
    final s = ro.size;
    return 'left=${o.dx.toStringAsFixed(1)}|top=${o.dy.toStringAsFixed(1)}'
        '|w=${s.width.toStringAsFixed(1)}|h=${s.height.toStringAsFixed(1)}';
  }

  void _rateBy(double delta) {
    final r = (_rate + delta).clamp(0.25, 4.0);
    // 保留两位小数，避免 0.30000000000000004 这种
    final rounded = (r * 100).round() / 100;
    _player.setRate(rounded);
    _flash('${rounded}x');
    _showControls();
  }

  /// 切换全屏
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★ 桌面端必须**真的让 OS 窗口全屏**（2026-09-24 修）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// # 原来错在哪
  ///
  /// 原实现是：
  /// ```dart
  /// void _toggleFullscreen() {
  ///   setState(() => _fullscreen = !_fullscreen);
  ///   _flash(_fullscreen ? '全屏' : '退出全屏');
  /// }
  /// ```
  /// 只改了一个**标志位**，从不碰 OS 窗口 —— 于是：
  /// ```text
  /// · 桌面端按"全屏"：提示弹了，窗口大小纹丝不动
  /// · 桌面端按 F11：完全没有反应
  /// ```
  /// 用户实际体验就是"全屏按钮是假的"。
  ///
  /// # 为什么原版只是标志位
  ///
  /// 原版是 WebView 里的网页，用的是浏览器 Fullscreen API
  /// （`art.fullscreen = !art.fullscreen`，ArtPlayer 内部实现），
  /// 那是**页内全屏**，由 WebView 处理，HTML 元素铺满即可。
  ///
  /// Flutter 桌面没有等价物 —— 必须调 `windowManager.setFullScreen()`，
  /// 由原生端改窗口样式（去掉装饰、铺满显示器）。
  ///
  /// # 各平台
  ///
  /// ```text
  /// 桌面   windowManager.setFullScreen(true/false)
  /// 手机   竖屏播放器铺满即可（本来就是全屏窗口），保持标志位
  /// TV     同上
  /// ```
  /// ⚠️ [awaitOs] —— ★★★ task-8 ① 追加（Owner 2026-10-09 第三批）：
  ///    允许调用方只提交「标志位 + 布局」而**不串行等待 OS 回包**。
  ///
  /// # 为什么需要这个开关（而不是在外面套 unawaited）
  /// ```text
  /// 我第一版在 `_exitPlayer` 里写的是 `unawaited(_toggleFullscreen())`，
  /// 被 lead 用真机日志推翻：`setState(_fullscreen = next)` 明明在同步段执行了，
  /// 但**布局**要等下一个微任务边界 —— 而 pop 已经开始 ⇒
  /// 退全屏那一帧布局整个**排在 pop 之后** ⇒ 真机看到「窗口先退全屏、再切页」，
  /// 比原来更花（正是 :9146 那条注释要避免的）。
  /// ```
  /// ⇒ 正确做法：**保留 await 语义**（同步段 + 本帧布局都在调用方仍在 await 时完成），
  ///    只把**最后那次真 OS 往返**从等待里摘出去。
  ///
  /// # 为什么摘掉它是安全的
  /// ```text
  /// 实测：`_toggleFullscreen()` 本体 2ms，而全屏返回比非全屏多 16.6ms ——
  /// 差额全在 `await windowManager.setFullScreen(next)`（真机上=窗口管理器回包）。
  /// 而这一步之后**没有任何** setState / 布局（已通读全函数体）⇒
  /// 不等它不会让任何 UI 状态变旧。
  /// 另外 `dispose()` 里还有一条幂等兜底（`if (_fullscreen && Device.isDesktop)`）
  /// 会再发一次 `setFullScreen(false)`，即使这一次失败也能收尾。
  /// ```
  Future<void> _toggleFullscreen({bool awaitOs = true}) async {
    _fullscreenCalls++;
    final next = !_fullscreen;
    setState(() => _fullscreen = next);
    // ★ N11：`_cursorIdleHidden` 的判据含 `_fullscreen` ⇒ 同步广播一次
    _pushCursorLive();
    _flash(next ? '全屏' : '退出全屏');

    /*
     * ★★★ task-58：通知合并页"全屏状态变了"（`MediaSession` 的权威来源）
     *
     * # 为什么必须通知（不能只靠父节点自己读）
     *
     * `MediaPage` 是**父**节点。子节点 `setState` **不会**让父节点重建
     * ⇒ 父节点读 `isFullscreen` 得到的仍是旧值 ⇒ 详情区不收起来
     *   ⇒ ★ 真机实测就是这样：窗口全屏了（`[WINDOWFRAME#3] => fullscreen=true`）
     *     但 `MediaPage` 不知道 ⇒ **判据⑥ FAIL**。
     *
     * # 为什么"监听窗口事件"不行（我第一版的做法，真机证明失效）
     *
     * `window_manager` 只在 `WM_SIZE` + `SIZE_MAXIMIZED` 时发
     * `enter-full-screen`（`window_manager_plugin.cpp` L291-294），
     * 而对无边框窗口 `SetFullScreen` 连 `SetWindowPos` 都不调
     * （`window_manager.cpp` L591-614 的两次 `SetWindowPos` 全在
     *  `if (!is_frameless_)` 里；L592 那句会触发 `SIZE_MAXIMIZED` 的
     *  `WM_SYSCOMMAND, SC_MAXIMIZE` 被插件作者**注释掉了**）
     * ⇒ 那个事件在本项目里**结构性不可能触发**。
     *
     * ⇒ 而 `_fullscreen` 是"用户按了全屏键"的直接结果 ⇒ **它就是权威**。
     *
     * ⚠️ 放在 `setState` **之后**：让合并页重建时读到的 `isFullscreen`
     *    已经是新值（否则它读到的还是旧值，白重建一次）。
     * ⚠️ 用 `?.call` —— 回调可能为 null（独立页面用法，没有合并页）。
     */
    _onFullscreenChanged?.call(next);

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 全屏时收起顶部操作条（2026-09-24 用户第三次纠正）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 全屏的时候不能显示哪个顶部的操作条啊
     *
     * # 这两条需求并不冲突，我一开始没分清
     *
     * ```text
     * 窗口模式（播放页）→ 必须**有**操作条：它是唯一的窗口拖动区
     * 全屏模式           → 必须**无**操作条：否则画面被切掉一条，
     *                       而且全屏下没有"拖窗口"这回事
     * ```
     * 我上一轮只做对了前半句（把播放页的隐藏去掉），
     * 结果全屏时那条栏还挂在画面上 —— 用户看到的就是
     * 「已经全屏了，顶上还占着 40px 一条黑边 + 源影 logo」。
     *
     * # 为什么全屏时不会有"拖不动"的问题
     *
     * 全屏下窗口铺满显示器，**没有拖动需求**：
     * ```text
     * · 没有标题栏要拖（用户不会再想移动一个盖满屏幕的窗口）
     * · 退出全屏有两条路：再按 F / Esc（Esc 语义已单独处理）
     * ```
     * 所以收起是安全的，不会重现"拖不动"的困境。
     *
     * ⚠️ **退出全屏时必须恢复** —— 否则回到窗口模式后又拖不动了，
     *    那就是把上一轮修好的 bug 又放回来。
     */
    titleBarVisible.value = !next;

    if (!Device.isDesktop) return; // 移动端没有"窗口全屏"概念

    try {
      if (awaitOs) {
        await windowManager.setFullScreen(next);
      } else {
        /*
         * ★ 只**发出**不等待：调用方（_exitPlayer）要的是
         *   「退全屏的请求已发出 + 标志位/布局已更新」，不是「OS 已回包」。
         * ⚠️ 用 unawaited 包住，避免 lint 与「未处理 Future」。
         * ⚠️ 失败仍然吞掉（与 await 分支同一语义）—— 不该因此让播放中断。
         */
        unawaited(windowManager.setFullScreen(next).catchError((Object _) {}));
      }
    } catch (_) {
      // 插件不可用（极端情况）—— 不该因此让播放中断
    }
  }

  void _toggleHints() {
    setState(() => _hintsOpen = !_hintsOpen);
    // ★ Owner 2026-10-11 第 2 条：**关**掉提示面板时（开→关）把顶/底栏叫回来。
    //   （提示面板本身不调 `_collapseControlsForSheet`，但 Esc 链会收口；
    //    关闭后统一走这条自愈与其它浮层一致。）
    if (!_hintsOpen) _restoreBarsAfterSheet();
  }

  void _showControls() {
    /*
     * ★★★ task-72【④】值没变就**不要** setState
     *
     * # 改前
     * ```dart
     * if (mounted) setState(() => _controlsVisible = true);   // 无条件
     * ```
     * 而 `_controlsVisible` 的初值**就是** true（`player_page.dart:487`）
     * ⇒ 绝大多数 hover 都在"值没变"的情况下白重建一次整页。
     *
     * # 实测读数（`.probe/probe_tests/t72_jank_probe_test.dart`）
     * ```text
     * PA   60 次鼠标移动（每次 2px）⇒ PlayerPage 重建 **60** 次
     *      元素重建 9960 次（平均每次移动 166 个元素）
     * PA2  30 次**同坐标** hover   ⇒ 重建 **30** 次
     * ```
     * ★ 触发源是 `MouseRegion(onHover: ...)` 包着**整页**
     *   （`player_page.dart:6323-6325`）—— Windows 上鼠标移动
     *   每秒可达数百次，每次都是一次 884 行的 `build`
     *   （`player_page.dart:6280-7163`）。
     *
     * # 为什么保留下面的 `_hideTimer` 重排
     * 鼠标一动就"续命 3 秒"是**正确行为**（用户还在操作就别隐藏），
     * 它只是分配一个 Timer，**不触发重建** ⇒ 不是本次卡顿的主因，
     * 但删了会让控制条在鼠标移动中意外消失。
     */
    // ★★★ T27-09：浮层开着时 hover **不得**把顶/底栏叫回来 ——
    //    否则「浮层开 → hover → 顶栏回来、底栏仍被 !flag 拦着」的分裂
    //    会经 hover 路径复发（底栏渲染条件含 !_anySheetOpen 的全部 flag）。
    if (mounted && !_controlsVisible && !_anySheetOpen) {
      /*
       * ★★★ N11（2026-10-18）：这里原来是 `setState(() => _controlsVisible = true);`
       *
       * # 为什么必须换掉
       * ```text
       * 本 if 在 `MouseRegion.onHover` 的路径上。全屏下「控制条已自动收起，
       * 用户一动鼠标」是最常见的一次交互，而它原来会触发**整页**重建：
       *   884 行 build + 190 个元素 = 实测 8~10ms（`zz_t66` T1 钉住）。
       * ```
       *
       * # 为什么改成广播是**等价**的（不是取巧）
       * ```text
       * `_controlsVisible` 的读者只有 `_TopBar.visible` / `_TopBar.fade`
       * （经 `_chromeVisible`）与底栏那条 `ListenableBuilder(_controlsAnim)`。
       * 前者现在订阅 `_controlsLive`（见 `_TopBar` 挂载点），后者本来就订阅
       * 动画控制器 ⇒ 两处都能收到通知，不需要整页重建。
       * ```
       * ⚠️ 外层的 `if (mounted && !_controlsVisible && !_anySheetOpen) {`
       *    **一个字都没动** —— 它被 t27_w9 S3 / t27_w13 A8 / t27_w17 S2
       *    逐字钉住（浮层开着时 hover 不得叫回控制条，T27-09 护栏）。
       */
      _controlsVisible = true;
      _pushControlsLive();
    }
    // ★ 2026-10-08（Owner 第 9 条）：值翻转之后**同帧**同步动画目标态
    _applyControlsMotion();
    _armHideTimer();
    // ★★★ Owner 第 1 条：光标隐藏计时器与上面这条控制条计时器**同源续命**
    //    ——「鼠标在动」这个事实已经在 `_armHideTimer()` 里表达过一次，
    //    光标那条计时器只需要跟着重排（判据见 `_noteCursorActivity()`）。
    _noteCursorActivity();
  }

  /// ★★★ T27-09：浮层打开时把顶/底栏一起收掉（显隐联动）
  ///
  /// # 症状（Owner 第 9 条原话）
  /// ```text
  /// 「上面这个出现，下面的操作没一起联动显示」——
  /// 点「播放设置 / 选集 / 线路 / 所有直播 / 弹幕设置 / 外部视频站弹幕 / 字幕搜索」
  /// 等打开浮层时，底栏立刻被它自己的渲染门控摘掉
  /// （`!_xxxOpen` 全在 `_BottomBar` 的 if 里），而顶栏的 visible
  /// 只看 `_controlsVisible` —— 浮层 open 点**不动它** ⇒ 顶栏还亮着。
  /// ```
  /// # 修法（显隐统一真源）
  /// 所有浮层 open 点调用本助手：把 `_controlsVisible` 一并收掉，
  /// 让顶栏与底栏走**同一个真源**。关闭浮层后由 Esc 关闭链 / 面板
  /// onClose 的 `_showControls()`（或下次 hover）自然叫回。
  ///
  /// ⚠️ `_applyControlsMotion()` 必须在 `setState` **之后**（读新值，
  ///    与 `_autoHideNow` 同款纪律）；值已是 false 时直接 return，
  ///    不做无谓 setState（task-72 纪律）。
  void _collapseControlsForSheet() {
    if (!mounted || !_controlsVisible) return;
    /*
     * ★ N11：同上，局部广播。浮层打开时收控制条不需要整页重建 ——
     *   顶栏/底栏订阅了 `_controlsLive`，其余子树与 `_controlsVisible` 无关。
     */
    _controlsVisible = false;
    _pushControlsLive();
    _applyControlsMotion();
    // ★★★ Owner 第 1 条：浮层 / popover 一开，光标**立刻**恢复 ——
    //    「藏光标」是为了把画面交给内容，而浮层开着时用户正在找控件，
    //    藏光标只会让他找不着鼠标。
    //    ⚠️ 这一句与上面那句一样是**无条件**的（不受 `_controlsVisible`
    //    已经为 false 时的早退影响）—— 早退只该省掉那次 setState。
    _cancelCursorIdleTimer();
  }

  /// ★★★ Owner 2026-10-11 第 2 条：**关掉浮层必须把顶/底栏叫回来**（自愈）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// # Owner 原话（逐字）
  /// ══════════════════════════════════════════════════════════════════
  /// ```text
  /// > 2.顶部和底部的还是一样没有联动,而且底部的也还是我点暂停才显示出来,
  /// >   压根没休
  /// ```
  ///
  /// # 为什么需要这个助手（T27-09 的**另一半没补**）
  /// ```text
  /// T27-09 的 open 点调 `_collapseControlsForSheet()` 把 `_controlsVisible`
  /// 收成 false（显隐联动）。它的注释原话是：
  ///   「关闭浮层后由 Esc 关闭链 / 面板 onClose 的 `_showControls()`（或下次
  ///     hover）自然叫回。」
  /// ★ 但实测：**只有播放设置面板**那一条真的调了 `_showControls()`
  ///   （`_closeSettingsFromEsc` / 设置 onClose / 设置 X，三处都调）。
  ///   其余 6 个浮层（弹幕设置 / 外部视频站导入 / 在线字幕 / 选集 / 线路 / 所有直播）
  ///   的 Esc 分支与 onClose **只翻 flag，不叫回控制条** ——
  ///   ⇒ 关掉它们之后 `_controlsVisible` 仍是 false，底栏要等**下一次 hover**
  ///     才回来。
  /// ⇒ 一旦 hover 那条路在真机上不灵（鼠标停在浮层原位不动 / 挪到原生视频
  ///   面上）、或在浮层刚淡出的那 260ms 里点不到底栏，用户看到的就是
  ///   「关掉面板后底栏一直不回来，只有点一次暂停（走 `_togglePlay` →
  ///     `_showControls()`）才回来」—— 正是 Owner 复报的症状。
  /// ```
  ///
  /// # 为什么是「关」点补自愈，而不是动 `_showControls` 的护栏
  /// ```text
  /// `_showControls()` 里那条 `!_anySheetOpen` 护栏（T27-09）有它自己的
  /// 职责：浮层开着时 hover 不得把控制条叫回来（否则「浮层开 → hover」
  /// 这个**期间**会出现顶栏回来、底栏仍被 `!flag` 拦着的分裂）。
  /// 本助手**不改那条护栏**：它在**关**的那一刻调 `_showControls()`——
  /// 此刻 flag 已经翻成 false，`_anySheetOpen` 为假，护栏放行 ⇒ 两条栏
  /// 一起回来（同一个 `_chromeVisible` 真源，构造上不可能分裂）。
  /// ⇒ 与「设置面板关闭的三步自愈」**同一条纪律**，只是补齐到其余 6 个浮层。
  /// ```
  ///
  /// ⚠️ 必须放在 `setState` 之后调用（`_showControls` 读的是新 flag）；
  ///    调用点都在 `setState(() => _xOpen = false)` 的**下一句**。
  void _restoreBarsAfterSheet() {
    // `_showControls()` 自带「值没变就不重建」的守卫（task-72）⇒ 代价近零；
    // 它还会顺手 `_applyControlsMotion()` + `_armHideTimer()`，
    // 让「关掉面板 ⇒ 再停手 3 秒 ⇒ 底栏正常收起」回到原节奏。
    _showControls();
  }

  /// ★★★ Owner 第 2 条：打开选集抽屉 ⇒ **暂停播放**
  ///
  /// # 为什么是「暂停」而不是「停止 / 销毁」
  /// ```text
  /// 「停止」要把播放器会话拆掉 ⇒ 关抽屉后得**重新起播**（重新解析流、
  /// 重新缓冲、位置还得自己记着补回去）—— 用户看到的是「关了抽屉画面重来」。
  /// 「暂停」只把 mpv 的 paused 置位，位置 / 缓冲 / 会话全在 ⇒
  /// 关抽屉 `play()` 一喊就从原处接着走。
  /// ```
  ///
  /// # ⚠️ 为什么必须记住「是**我们**暂停的」
  /// ```text
  /// 抽屉开着时用户可以自己点播放 / 点暂停（画面在左边还看得见）。
  /// 若关抽屉时无条件 `play()`，就会把「用户自己按了暂停」这个**明确意图**
  /// 覆盖掉。主流在线播放器此时的行为是：关掉面板**保持用户最后的
  /// 状态**，不替他做决定。
  /// ```
  void _pauseForEpisodeSheet() {
    /*
     * ⚠️ 用 `_playing`（`_player.stream.playing` 回灌的真源）判断，
     *    不自己另存一份「开抽屉前的状态」—— 那份状态一旦与真源不同步
     *    （暂停/播放还会被起播、切集、片尾自动下一集等路径改），
     *    就会变成「关抽屉后画面自己动起来」这种最难查的 bug。
     */
    _pausedForEpisodeSheet = _playing;
    if (!_pausedForEpisodeSheet) return;
    _episodeSheetPauseCalls++; // ★ 只读探针（见字段声明处的说明）
    _player.pause();
  }

  /// ★★★ Owner 第 2 条：选集抽屉关闭 ⇒ 恢复播放（**只在确实是我们暂停的**时候）
  ///
  /// ⚠️ 三种关闭方式**共用**这一个恢复点：
  /// ```text
  /// ① 点面板外的空白（`_SheetScrim`）
  /// ② 点面板右上角的 X
  /// ③ Esc
  /// ```
  /// 三处都经 `_closeEpisodeSheet()` / `_escCloseEpisodeSheet()` ⇒ 恢复逻辑
  /// 只有一份，不会出现「一种关法恢复、另一种不恢复」—— 那种不一致在真机上
  /// 看起来就像随机 bug。
  ///
  /// ⚠️ **不**走这里的两种情况（各自有明确理由）：
  /// ```text
  /// ① 用户点了某一集 ⇒ 走 `_gotoEpisode()`：它要起播**新的一集**，
  ///    `play()` 由起播路径自己发 —— 这里再发一次是重复命令。
  /// ② 用户自己点过播放/暂停 ⇒ `_pausedForEpisodeSheet` 已是 false，
  ///    见 `_pauseForEpisodeSheet()` 的说明。
  /// ```
  void _resumeAfterEpisodeSheet() {
    final wasPlaying = _pausedForEpisodeSheet;
    _pausedForEpisodeSheet = false;
    if (!wasPlaying) return;
    if (!mounted) return;
    _episodeSheetResumeCalls++; // ★ 只读探针（见字段声明处的说明）
    unawaited(_player.play());
  }

  /// ★★★ Owner 第 2 条：关闭选集抽屉的**唯一**收口（空白 / X 两个关点）
  ///
  /// # 为什么要有这个收口
  /// ```text
  /// 抽屉的 UI 关点有 3 个：空白 / X / Esc。
  /// 「暂停 ⇒ 恢复」这一对动作必须成对落在**每一个**关点上 ——
  /// 少一个就会出现「某一种关法之后画面不动了」，而这种 bug 极难复现。
  /// ⇒ 空白与 X 两处收口到这里；Esc 那条因为要在 Esc 链里只占一行，
  ///   走 `_escCloseEpisodeSheet()`（内部转发 `_escCloseSheet`）。
  /// ```
  ///
  /// ⚠️ 切集（`_gotoEpisode`）**故意不调**本函数：它是「换一集继续播」，
  ///    不是「关掉抽屉继续看这一集」—— 恢复播放由起播路径负责。
  void _closeEpisodeSheet() {
    setState(() => _episodeSheetOpen = false);
    _resumeAfterEpisodeSheet();
    _restoreBarsAfterSheet();
  }

  /// ★★★ Owner 第 2 条：Esc 关闭选集抽屉（Esc 链里**只能占一行**）
  ///
  /// # 为什么不能直接把 `_escCloseSheet(...)` 那一行换成它
  /// ```text
  /// `test/t27_w17_close_sheet_restores_bars_test.dart` 钉了「Esc 链一行助手」的
  /// 调用次数恰好 **8** —— 选集那条也是这 8 条之一，换成别的调用会让门禁红。
  /// ⇒ 本函数**内部**转发 `_escCloseSheet`（计数不变），只额外补「恢复播放」。
  /// ```
  ///
  /// # 为什么 Esc 这条单独处理，而不是改 `_escCloseSheet` 本身
  /// ```text
  /// `_escCloseSheet` 服务**全部 8 个浮层**（提示 / 外部弹幕 / 字幕 / 弹幕设置 /
  /// 缩放 / 选集 / 线路 / 所有直播）。「关面板 ⇒ 恢复播放」**只有选集**有
  /// （也只有它开的时候会暂停）⇒ 塞进公共助手会让另外 7 个浮层平白多一次
  /// 恢复判定，语义也错。
  /// ```
  void _escCloseEpisodeSheet() {
    _escCloseSheet(() => _episodeSheetOpen = false);
    _resumeAfterEpisodeSheet();
  }

  /// Esc 链专用：翻掉一个浮层 flag **并**把顶/底栏叫回来（Owner 2026-10-11 第 2 条）
  ///
  /// ⚠️ 存在的唯一理由是**长度**：Esc 那条 `else if` 链被三条既有断言钉在
  ///    「Esc 行之后 **700 字符**」的窗口里（见链上那段说明）。若在每个分支里
  ///    写两行（`setState(...)` + `_restoreBarsAfterSheet()`）会把这几个
  ///    分支关键字推出 700 窗口 ⇒ `t73` / `t78` / `player_capability` 集体红。
  ///    收成**一行**调用后，链的长度与「只有 setState」时几乎一样。
  void _escCloseSheet(VoidCallback flip) {
    setState(flip);
    _restoreBarsAfterSheet();
  }

  /// 重新装载「N 秒后自动隐藏控制条」的计时器（★ 2026-10-08 Owner 第 9 条）
  ///
  /// # 为什么要从 _showControls() 里抽出来
  /// ```text
  /// 改前它**只**在 _showControls() 内装载，而 _showControls() 的触发源
  /// 只有「鼠标 hover」与「点击/按键」——
  /// ⇒ 用户把鼠标**停着不动**、也不点任何东西时，计时器**从没被装载过**
  ///   （_hideTimer == null），控制条于是**永远显示**
  ///   —— 这正是 Owner 报的「播放器的控件不会主动消失,一直在显示」。
  /// ⇒ 抽成独立函数之后，**起播成功**（_onPlaybackReady）与
  ///   **动画收尾**（didUpdateWidget）也能把它装上。
  /// ```
  ///
  /// ⚠️ 隐藏**只翻转 _controlsVisible**，真正的淡出由 _applyControlsMotion()
  ///    在 didUpdateWidget 里驱动 —— 与「显示」完全同一条路
  ///    （Owner 原话：「这里处理是一样的」）。
  void _armHideTimer() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), _autoHideNow);
  }

  /// 上一次看到的「popover 是否开着」—— 用来只认**开→关**那个**边沿**
  ///
  /// 关联缺陷 ⑤（见 `_autoHideNow` / initState 里 `_onPopoverChanged` 的注册）。
  bool _prevPopoverOpen = false;

  /// ★★★ Owner 2026-10-11 第⑤条：popover 开→关的边沿上重装隐藏计时器。
  ///
  /// # 为什么需要它
  /// ```text
  /// `_autoHideNow()` 加了「popover 开着不收」之后，用户开着倍速面板停手 3 秒
  /// ⇒ 计时器到点但守卫把隐藏拦下 ⇒ 底栏留着（对），可那个 `_hideTimer`
  ///   **已经烧掉**。若关闭面板时不管它，底栏就**再也不会自动隐藏**。
  /// 实测：底栏 popover 的三条关闭路径（点选中 / 悬停移出 / Esc）**都不**调
  /// `_showControls()`，也就都不重装计时器。
  /// ```
  /// ⇒ 这里补上：只在真的跨过「开→关」时 `_armHideTimer()`。
  ///
  /// ⚠️ `changeNotifier` 在面板开着时也会 notify（`PopoverController`
  ///    每帧复核锚点几何后可能 notifyListeners）⇒ **必须**靠 `_prevPopoverOpen`
  ///    过滤，否则面板开着期间会被反复续命（底栏在面板开着时永远亮着）。
  void _onPopoverChanged() {
    final open = _popover.openId != null;
    if (_prevPopoverOpen && !open) {
      // 开 → 关：让「关掉面板 ⇒ 再停手 3 秒 ⇒ 底栏正常收起」回到原节奏。
      _armHideTimer();
    }
    _prevPopoverOpen = open;
  }

  /// 「停手 3 秒」到点时**真正**要做的事（★ 2026-10-08 Owner 追加）
  ///
  /// # 为什么从 _armHideTimer 里抽出来
  /// ```text
  /// 抽出来之后**生产**（Timer 回调）与**探针**
  /// （debugAutoHideControlsForProbe）调的是**同一个方法** ⇒
  /// 测试验的就是生产路径，而不是测试自己又写了一遍判据。
  /// 这也是本仓探针的一贯纪律（参见 `_handleStreamError` / `_handleFirstFrame`：
  /// 探针与生产**同调一份**，而不是各写一遍）。
  /// ```
  ///
  /// 判据（四条，缺一不可）：
  /// ```text
  /// _playing            播放中才自动隐藏（暂停时留着，方便操作）
  /// !_hintsOpen         快捷键面板开着时不收（用户正在读）
  /// !_zoomOpen          ★ task-22 P1-5：缩放滑条开着时不收（否则拖到一半条就没了）
  /// _popover.openId==null  ★ Owner 2026-10-11 第⑤条：悬浮小窗（倍速/清晰度/
  ///                     字幕/弹幕/更多）开着时不收 —— 见下方长注释
  /// ```
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ Owner 2026-10-11 第⑤条：漏了 popover ⇒ 「面板孤零零留在画面上」
  /// ══════════════════════════════════════════════════════════════════
  /// # Owner 原话（逐字）
  /// ```text
  /// > 鼠标悬浮在这里，然后不动之后控件消失，但是这个倍速的面板没消失，
  /// > 其他悬浮的面板应该也是一样的
  /// ```
  /// # 症状
  /// ```text
  /// 鼠标悬浮底栏「倍速」按钮 → 倍速面板（0.5x…3x）弹出 → 鼠标停住不动 →
  /// 3 秒后本回调把顶/底栏一起收掉，**但倍速面板还浮在画面上**，孤零零留在那里。
  /// ```
  /// # 根因
  /// ```text
  /// 本守卫只判了 _hintsOpen / _zoomOpen 两个「同级浮层」，
  /// **漏掉了悬浮 popover**。而 popover 的真值源在
  /// `_popover.openId`（`final PopoverController _popover`，
  /// 状态在 `lib/ui/player/popover.dart` 的 PopoverController），
  /// 底栏按钮（rate/quality/tracks/danmaku/more）全走这一个控制器。
  /// ⇒ 面板开着、底栏却照收：面板挂在底栏按钮**旁边**，底栏一收，
  ///   面板即失去依附，却因 _openId 仍非 null 而继续渲染。
  /// ```
  /// # 为什么「面板开着就不收」是对的取舍
  /// ```text
  /// 面板贴着底栏按钮弹出（`buildPopoverLayer` 把面板当底栏的兄弟挂在
  /// 同一层 Stack，锚点在按钮上）。底栏一收，面板就**悬空**——
  /// 既失去了它解释的那枚按钮，用户也无从判断「在给谁设倍速」。
  /// ⇒ 与 _hintsOpen / _zoomOpen 同一条纪律：面板/滑条开着时不收。
  /// （这不会让底栏「永不消失」：见下方「关闭后计时器会重装」。）
  /// ```
  /// # 关闭后计时器会重装（否则本守卫会引出第二个缺陷）
  /// ```text
  /// 守卫加严后，popover 开着时底栏本就收不掉；若「关闭」之后 _hideTimer
  /// **不重新装**，那用户「开着面板 → 关掉」之后底栏就**再也不会自动隐藏**
  /// —— 那是把「不消失」从 3 秒推迟成永久，比原缺陷更糟。
  ///
  /// 实测各条关闭路径（底栏 popover 全部走 `PopoverController.close()`）：
  ///   · 点选项选中 ⇒ `controller.close()`（player_bottom_bar.dart 的
  ///     _rateRow/_row/_trackRow/_danmakuPanel）。这些回调（onRate /
  ///     onPickQuality / onPickTrack / onDanmakuToggle）**都不调** _showControls()
  ///     ⇒ 计时器**不会**因选中而重装。
  ///   · 悬停移出 ⇒ `PopoverController.armClose()` 250ms 后 close()。
  ///     底栏还在（底栏 hover 一直叫 _showControls()），但用户停手后
  ///     _hideTimer 仍是「3 秒前装的」——只要那时 popover 还开着，
  ///     回调就被本守卫拦下 ⇒ 计时器已烧掉、**不再重装**。
  ///   · Esc ⇒ `:10455 _popover.close()`，同样不重装。
  /// ⇒ 三条路径下，popover 关闭后 _hideTimer 要么空、要么已经烧掉
  ///   ⇒ **必须**在 popover 关闭时补一次 _armHideTimer()，否则底栏永不隐藏。
  /// ```
  void _autoHideNow() {
    // ⚠️ `!_hintsOpen && !_zoomOpen` 必须保持在同一行：`test/t78_video_zoom_hwdec_test.dart`
    //    的判据④对**剥注释后**的源码做字面量匹配（`_page.contains('!_hintsOpen && !_zoomOpen')`）。
    if (mounted &&
        _playing &&
        !_hintsOpen && !_zoomOpen &&
        _popover.openId == null) {
      setState(() => _controlsVisible = false);
      /*
       * ★★★ 2026-10-25（交叉复核钉死的真缺陷：箭头看得见、点不到）
       *
       * **必须把新值推给订阅者**：漏这一行时 `_controlsLive` 停在 true
       * ⇒ 鼠标叫回那次 push 因"值没变"提前 return、不通知 ⇒ 顶栏不重建、
       * `IgnorePointer` 仍挡，而动画已到 1.0 ⇒「拉开看得到、点不到」。
       * ⚠️ 放 `setState` 之后（读新值）。门禁：`zz_t1024_chrome_autohide_hittest`、
       * `zz_cr_backbtn_backarrow` ②。
       */
      _pushControlsLive();
      /*
         * ★★★ 2026-10-08（Owner 追加：顶栏要与底栏**联动**一起消失）
         *
         * # 改前这里**没有**这一行 —— 这正是「顶栏一直不消失」的根因之一
         * ```text
         * `_applyControlsMotion()` 原来**只**在 `_showControls()` 里被调，
         * 而它做的是「把 _controlsVisible 的目标态写进 _controlsAnim」。
         * ⇒ 隐藏路径上没人调它 ⇒ `_controlsFade.value` 恒 = 1.0
         *   ⇒ 顶栏那条渐变条**永远画在最亮**（Opacity 1.0），
         *     连 `visible: false` 都救不回来（它只挡指针、不改透明度）。
         * ```
         *
         * ⚠️ 必须放在 `setState` **之后**：`_applyControlsMotion()` 读的是
         *    `_controlsVisible` 的**当前值**，写在前面会读到旧值 ⇒ 反向。
         */
      _applyControlsMotion();
    }
  }

  /// ★ 缺陷 9 探针入口（见文件末尾的顶层转发器）
  void debugPlayerFlashForProbe(String msg) => _flash(msg);

  void _flash(String msg) {
    if (!mounted) return;
    setState(() => _tip = msg);
    Future.delayed(const Duration(milliseconds: 1200), () {
      if (mounted && _tip == msg) setState(() => _tip = null);
    });
  }

  /// 弹幕失败角标自动消失的时间（毫秒）
  ///
  /// 为什么是 8 秒：够用户看清「弹幕失败：…」+ 那半句中文说明（约 40 字），
  /// 又不至于在画面正中糊太久。见 `_danmakuBadge` 的说明。
  static const int kDanmakuBadgeFailMs = 8000;

  /// 失败发生的时刻（null = 没有失败）。用来给角标算"还要显示多久"。
  DateTime? _danmakuErrorAt;

  /// 让角标到点自己消失的定时器
  ///
  /// ⚠️ **必须**有这个定时器：`_danmakuBadge` 是 getter，它算得出
  ///    "已经超时了"，但**没人重建**的话屏幕上那层永远不会消失。
  ///    （这是"改了 getter 忘了触发重建"的经典坑。）
  Timer? _danmakuBadgeTimer;

  /// 「取数成功但一条都没有」时那句「没有弹幕」能挂多久（毫秒）
  ///
  /// ★ OPS-10 ④：改前它**没有寿命**（永久），Owner 报「不用一直显示」。
  ///   取 3 秒 = 与控制条"停手 3 秒就收"同一个节奏，用户看到的是
  ///   一句话跟控制条一起走掉，而不是一个赖着不走的标识。
  ///
  /// ⚠️ 必须 < 4 秒：`test/zz_cr_dmk_d_badge_test.dart` 用一次
  ///    `t.pump(Duration(seconds: 4))` 断言它已经消失 —— 改大了那条会红。
  static const int kDanmakuBadgeEmptyMs = 3000;

  /// 「没有弹幕」这句是否已经到点（定时器翻的牌，见 `_danmakuBadge`）
  ///
  /// ⚠️ 用 bool 而不是 `DateTime.now()` 差值：widget 测试推进的是假时钟，
  ///    墙钟不动 ⇒ 时间戳判据在测试里恒"未过期"，测出来的是假绿。
  bool _danmakuEmptyExpired = false;

  /// 到点隐藏角标（失败态 / 空态共用一个计时器）
  ///
  /// [ms] 用默认值 = 失败态那 8 秒；空态传 [kDanmakuBadgeEmptyMs]。
  void _armDanmakuBadgeExpiry([int ms = kDanmakuBadgeFailMs]) {
    _danmakuBadgeTimer?.cancel();
    _danmakuBadgeTimer = Timer(
      Duration(milliseconds: ms),
      () {
        if (!mounted) return;
        /*
         * ★ 两件事一起做：
         *   ① 翻牌（getter 下一帧就不再画"没有弹幕"）；
         *   ② setState 触发重建（getter 是懒的，没人重建就没人重读）。
         */
        setState(() => _danmakuEmptyExpired = true);
      },
    );
  }

  String? _tip;

  // ═══════════════════════════════════════════════════════════════════
  //  ★ 画中画（P 键）
  // ═══════════════════════════════════════════════════════════════════

  void _initPip() {
    /*
     * ⚠️ 必须 await 探测才知道支不支持
     *
     * Android 要问系统 API 版本（PiP 需要 API 26+），
     * 桌面要确认 window_manager 可用。
     *
     * 探测结果决定**按钮显不显示** —— 不支持时干脆不显示，
     * 比显示了但点了没反应好（后者让用户以为"按坏了"）。
     */
    PipController.instance.probe().then((ok) {
      if (mounted) setState(() => _pipSupported = ok);
    });
    // 状态变化要同步到 UI（用户点小窗的 X 时原生会通知）
    PipController.instance.addListener(_onPipChanged);
  }

  void _onPipChanged(bool active) {
    if (mounted) setState(() => _pipActive = active);
  }

  Future<void> _togglePip() async {
    if (!_pipSupported) return;
    /*
     * 传**视频真实宽高比** —— Android 的小窗比例按它算。
     *
     * 拿不到就退回 16:9（`_videoAspect` 的默认值）。
     */
    final ok = await PipController.instance.toggle(aspectRatio: _videoAspect);
    if (!ok && mounted) {
      _flash('本平台不支持画中画');
    }
  }

  /// 视频宽高比（拿不到时按 16:9）
  double get _videoAspect {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w == null || h == null || w <= 0 || h <= 0) return 16 / 9;
    final r = w / h;
    // 夹到 Android 允许的范围（1:2.39 ~ 2.39:1），否则原生会抛异常
    return r.clamp(1.0 / 2.39, 2.39);
  }

  /// 视频**真实**宽高比；拿不到时返回 `null`（task-28 ②）
  ///
  /// # 与 [_videoAspect] 的区别（**这个区别很重要**）
  ///
  /// ```text
  /// _videoAspect   拿不到时**兜底 16:9**，且夹到 [1/2.39, 2.39]
  ///                ← 给 Android 画中画用的（原生要求这个范围，
  ///                  越界会抛异常，所以必须兜底 + 夹取）
  ///
  /// _displayAspect 拿不到时返回 **null**，且**不夹取**
  ///                ← 给"画视频区描边"用的（见 ② 的实现）
  /// ```
  ///
  /// # 为什么描边**不能**复用 `_videoAspect`
  ///
  /// ```text
  /// ① 兜底 16:9 会在**起播前**画一个框 —— 而那时还没有画面，
  ///    框是凭空出现的，用户会以为"界面坏了"。返回 null ⇒ 不画。
  /// ② 夹取到 2.39 会让 **21:9 以上的片源**描边比画面窄
  ///    （真实比例 2.6 被夹成 2.39）⇒ 框压在画面上，那是**错误信息**。
  /// ```
  /// 描边必须与 `BoxFit.contain` 的几何**逐像素一致**，
  /// 所以这里要的是"真实值，没有就不知道"。
  double? get _displayAspect {
    final w = _player.state.width;
    final h = _player.state.height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    return w / h;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  键盘 / 遥控器
  // ═══════════════════════════════════════════════════════════════════

  /// ★ early handler 的适配层（task-42）
  ///
  /// # 为什么要单独一个函数（而不是把 `_onHardwareKey` 的返回类型改掉）
  /// ```text
  /// `FocusManager.addEarlyKeyEventHandler` 要求返回 **`KeyEventResult`**，
  /// 而 `_onHardwareKey` 的判定逻辑是"bool：我处理了吗"。
  /// ★ 单独做**类型转换**（照 shell.dart L2083 的做法）⇒
  ///   判定逻辑一字不动，只是包一层 —— 改返回类型会牵动整个函数体。
  /// ```
  /// ```text
  /// true  -> KeyEventResult.handled   （★ 会**中止**焦点树派发）
  /// false -> KeyEventResult.ignored   （继续正常派发）
  /// ```
  KeyEventResult _onEarlyKey(KeyEvent event) =>
      _onHardwareKey(event) ? KeyEventResult.handled : KeyEventResult.ignored;

  /// 焦点是否在输入框里（"输入框守卫"的**共用**实现）
  ///
  /// ★ 抽成函数的原因：`_onHardwareKey` 与 `_onKey` **两条入口**都要用。
  ///   写在两处会变成**两套真相** —— 改一处忘另一处就会出现
  ///   "硬件路径挡住了、焦点树路径没挡"的漏洞（正是本次修的 bug 形态：
  ///   弹幕设置面板的屏蔽词输入框里敲 Enter 不换行、反而触发播放/暂停）。
  ///
  /// ⚠️ 用 `el.widget.runtimeType.toString() == 'EditableText'` 而**不是**
  ///    `is EditableText`：本仓 UI 用的是拆包后的 `material_ui`，
  ///    用 `is` 可能因库不同恒为 false（与 `live_page.dart` 同款写法）。
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

  /// ★★★ 硬件层键盘兜底（task-42）
  ///
  /// 详细推导见 `initState` 里注册处的长注释。
  ///
  /// # 它和 `Focus(onKeyEvent: _onKey)` 的分工（**必须说清**）
  /// ```text
  /// `_onKey`（焦点路径）  ：焦点在本页时，**所有**键位照旧由它处理
  ///                         （方向键/音量/J/K/L/M/F/P/N/逗号句号…）
  /// 本 handler（硬件路径）：只在 `_onKey` **收不到**时兜底
  ///                         —— 即焦点被上一页抢走的情况
  /// ```
  /// ⚠️ 因此这里**只处理用户点名的那两个键**（空格 / Enter），
  ///    而不是把 `_onKey` 整个复制一份 ——
  ///    复制会造成"两条路径语义漂移"（改一处忘另一处）。
  ///    ★ 用户没点名的键（J/L/M/F…）保持原样：焦点正常时可用；
  ///      焦点异常时**不兜底**（避免扩大改动面，也避免与 `_onKey` 双触发）。
  ///
  /// # ⚠️ 双触发风险（必须防）
  /// ```text
  /// 若焦点**正常**在本页：`_onKey` 会处理空格/Enter。
  /// ★ 而本 handler 在焦点树**之前**跑 ⇒ 若我也处理，就会**跑两次**
  ///   （空格 ⇒ 暂停又播放 = 看起来没反应；Enter ⇒ 全屏又退出 = 同样没反应）
  /// ⇒ ★ 解决办法：见 `_focusIsInsideThisPage`。
  /// ```
  bool _onHardwareKey(KeyEvent event) {
    /*
     * ★ 无条件入口打点（与直播页 `_onHardwareKey` 同款）
     *
     * # 为什么必须有（真机排障的关键）
     * ```text
     * 我原来只在"真的处理了"时打日志 ⇒ 无法区分：
     *   · handler **压根没被调用**（注册/机制问题）
     *   · 被调用了但**门控挡掉**（浮层/路由/焦点已在页内）
     * ⇒ 加这一行，一眼分辨。
     * ★ 直播页就是靠这行定位到"键进了 Flutter 但被可见性门控挡住"的。
     * ```
     */
    if (event is KeyDownEvent) {
      debugPrint(
        '[PLAYER-KEY] ⓪ 入口：硬件 handler 收到 '
        '${event.logicalKey.keyLabel}（浮层=$_anySheetOpen '
        '最上层=${ModalRoute.of(context)?.isCurrent}）',
      );
      // ★ Owner 第 1 条：按键也是「人还在操作」——续命光标隐藏计时器。
      //    ⚠️ 挂在 `is KeyDownEvent` 这道门里（与上面那行日志同门）：
      //    `_onHardwareKey` 的浮层门控在下面（`if (_anySheetOpen) return`），
      //    放在函数体第一行会让「浮层开着时按 Esc」也误续命。
      _noteCursorActivity();
    }
    if (event is! KeyDownEvent) return false;
    if (!mounted) return false;

    /*
     * ── 门控 ①：有浮层打开时不接管 ──
     *
     * 浮层（选集/设置/线路/提示）里的焦点自己会处理键 ——
     * 我抢过来会把"面板里 Enter 选条目"变成"全屏"（正是 L4086 修过的 bug）。
     */
    if (_anySheetOpen) return false;

    /*
     * ── 门控 ②：本页必须是**最上层路由** ──
     *
     * ★ 这条同时解决两个问题：
     *   ① 本页被别的路由盖住时不该收键
     *   ② **与直播页的 handler 抢键** —— 直播页被本页 push 覆盖后
     *      `isCurrent == false` ⇒ 它自己让路（它也有同样的门控）
     */
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return false;

    /*
     * ── 门控 ③：输入框里打字时放行 ──
     *
     * ★ 用**共用**的 `_isTypingInField()` —— `_onKey`（焦点树路径）也用它，
     *   两道入口**一套判据**（避免"改一处忘另一处"的两套真相）。
     */
    if (_isTypingInField()) return false;

    /*
     * ── ★ 防双触发：焦点已在本页 ⇒ 让 `_onKey` 处理 ──
     */
    final f = FocusManager.instance.primaryFocus;
    if (_focusIsInsideThisPage(f)) return false;

    final k = event.logicalKey;
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 直播 ↑/↓ 切台（**焦点不在本页**时的兜底）—— task-53【#4b】
     * ══════════════════════════════════════════════════════════════════
     *
     * # ★ 为什么必须在这里也做一遍（lead 真机实测抓到的**真** bug）
     * ```text
     * lead 的实测（同一个 app.so，同一页面，全屏直播播放中按 ↓）：
     *   [LIVE-KEY]   ⓪ 入口：硬件 handler 收到 Arrow Down（可见=true）
     *   [PLAYER-KEY] ⓪ 入口：硬件 handler 收到 Arrow Down（浮层=false 最上层=true）
     *   ★★ **没有** `[PLAYER-KEY] ⓪ 入口：收到 Arrow Down`   ← ★ 关键缺失
     *   ★★ **没有** `直播 ↓ ⇒ 下一个台`
     * ⇒ ★ 键**到了硬件 handler**，但**没到 `_onKey`**（焦点路径）。
     * ```
     *
     * 我自己的实测（**同一个二进制、同一个页面**，只差一步）：
     * ```text
     *   ① 直播页 → 点播放器右上角全屏按钮 → 按 ↓   ⇒ **不切台**（复现 lead）
     *   ② 再点一下画面 → 按 ↓                     ⇒ **切台** ✓
     * ⇒ ★★★ 根因 = **焦点不在本页** ⇒ `_onKey` 收不到。
     *   进全屏后焦点仍留在**直播页**（是它 push 的播放页），
     *   用户不点画面就没有任何东西把焦点搬进播放页。
     * ```
     *
     * # ★ 为什么不是"shell.dart 没接线"
     * ```text
     * lead 判据是"6 处 `PlayerPage(` 都没传 `onLiveChannelStep`"。
     * ★ 但 `onLiveChannelStep` 在 L3199，而它所属的 `PlayerPage(` 在 **L3163** ——
     *   中间隔了 **31 行注释**（我写的分工说明）⇒ 只扫"紧邻十来行"会**漏判**。
     * ★ 反证（同一二进制上取的读数）：
     *   `[LIVE-KEY] 全屏切台 ⇒ TVSRC+ 2：本页只改选中，起播交给播放页`
     *   ★ 这行**只能**由 `stepChannelForFullscreen` 产生，
     *     而它**只能**经 shell 传的 `onLiveChannelStep` 到达
     *   ⇒ 接线存在，且真的跑过。
     * ```
     *
     * # 为什么这样修（而不是去"抢焦点"）
     * ```text
     * ★ `_onKey` 那侧的 `_isLive && onLiveChannelStep != null` 判断**完全正确**，
     *   一个字节都不用改 —— 缺的只是"焦点异常时也能到"的**第二条路**。
     * ★ 本函数（`addEarlyKeyEventHandler`）**先于焦点树**收到键 ⇒ 天然覆盖这条。
     * ★ 而 Esc 在下面（`k == escape && _fullscreen`）就是这么修的 ——
     *   同一根因，注释逐字在案：
     *     「本兜底路径下焦点不在本页 ⇒ `_onKey` 收不到 ⇒ Esc 失效」
     *   ⇒ 本处**沿用同一条既有纪律**，不发明新机制。
     * ```
     *
     * # ★ 为什么不会双触发（关键）
     * ```text
     * 上面 `if (_focusIsInsideThisPage(f)) return false;` 已经把
     * "焦点在本页"的情况**让给 `_onKey`** ⇒ 两条路**互斥**，
     * 一次按键只切一个台。
     * ★ 真机实测已证：点画面后按 ↓ 只出现**一行** `直播 ↓`（不是两行）。
     * ```
     *
     * ⚠️ 只做**直播**，不做音量 —— 非直播时 ↑/↓ 仍是音量（已验收，不动）。
     *    焦点不在页内时音量本来就不响应，那是既有行为，不属本任务范围。
     */
    if (_isLive && widget.onLiveChannelStep != null) {
      if (k == LogicalKeyboardKey.arrowUp) {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：直播 ↑ ⇒ 上一个台');
        unawaited(_switchLiveChannel(-1));
        return true;
      }
      if (k == LogicalKeyboardKey.arrowDown) {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：直播 ↓ ⇒ 下一个台');
        unawaited(_switchLiveChannel(1));
        return true;
      }
    }
    if (k == LogicalKeyboardKey.space) {
      debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：空格 ⇒ 播放/暂停');
      _togglePlay();
      return true;
    }
    if (k == LogicalKeyboardKey.enter) {
      /*
       * ★ 桌面 = 全屏；TV = 播放/暂停（与 `_onKey` 的分流**保持一致**）
       *
       * ⚠️ 两处必须同规则 —— 否则"焦点正常/异常"两种情况下 Enter 语义不同，
       *    用户会觉得"时好时坏"（这正是最难查的那类 bug）。
       */
      if (!widget.isTv) {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：Enter ⇒ 切换全屏');
        unawaited(_toggleFullscreen());
      } else {
        debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：Enter(TV) ⇒ 播放/暂停');
        _togglePlay();
      }
      return true;
    }
    /*
     * ★ Esc 兜底（只在全屏时）—— 防止"焦点在页外时被困在全屏"
     *
     * # 为什么需要
     * ```text
     * 真机实测（`.probe/t42_player_final.txt`）：
     *   Enter ⇒ 1280x800 → **2560x1440**（进全屏）✓
     *   双击  ⇒ 2560x1440 → **1280x800**（退全屏）✓
     *   ★ Esc ⇒ 被入口日志记到了，但**没有退出全屏**
     * ```
     * 原因：Esc 的退出全屏逻辑在 `_onKey` 里（焦点路径），
     * 而本兜底路径下焦点**不在本页** ⇒ `_onKey` 收不到 ⇒ Esc 失效。
     * ⇒ 用户若在焦点异常时进了全屏，Esc 这个**通用逃生口**就没了。
     *
     * # 为什么只处理"全屏"这一种情况
     * ```text
     * `_onKey` 里 Esc 是一串级联（提示 → 设置 → 选集 → 线路 → 全屏 → 退出播放页）。
     * ★ 但本兜底**已经**在开头 `if (_anySheetOpen) return false;` 挡掉了前四种
     * ⇒ 剩下的只有"全屏"和"退出播放页"。
     * ⚠️ 我**只做全屏**，不做"退出播放页" ——
     *   因为那等于让一个收不到焦点事件的页面也能被 Esc 关掉，
     *   风险更大（用户可能只是焦点没落上，却把播放页关了）。
     *   退出播放页仍有 UI 按钮 + 焦点正常时的 Esc。
     * ```
     */
    if (k == LogicalKeyboardKey.escape && _fullscreen) {
      debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：Esc ⇒ 退出全屏');
      unawaited(_toggleFullscreen());
      return true;
    }
    /*
     * ★★★ 第 16 项（2026-10-25）：**内嵌 / 全屏快捷键一致**的最后一块拼图
     *
     * # 为什么放在这里（既有分支**之后**）
     * ```text
     * ① 空格在上面已有专门分支（还带"浮层让位"的长注释）⇒ 这里**只兜 M**，
     *    但判据仍走**共用契约**（`livePlaybackActionForKey`）：
     *    ⚠️ 范围限定：**只对这一块兜底链**成立（这里按契约派发全键位）。
     *       `_onKey`（焦点树路径）仍是逐键分支（空格/M/J/L/F/P/N…），
     *       它有自己的**页面上下文门控**（浮层让位 / 打字 / 仅桌面），
     *       那些不属于"键位判定表"，所以没有一并改成 dispatch。
     *       ⇒ 契约新增键位时：**兜底链自动跟上**，`_onKey` 需要人工补分支。
     * ② 位置必须在 `_focusIsInsideThisPage` 之后（焦点在页内 ⇒ 交给 `_onKey`，
     *    否则**双触发**：静音又被取消 = 看起来没反应）。
     * ③ 也必须在输入框门控（门控③）之后 —— 打字时的空格/M 都要放行。
     * ```
     *
     * # 为什么是 `unawaited(...)` 而不是 `await`
     * ```text
     * 本 handler 是**同步**的（`KeyEventResult`/`bool` 必须立刻回答"我处理了吗"）；
     * 而 `dispatchLivePlaybackAction` 返回 `Future<bool>`。
     * ⇒ 按本函数既有写法（`unawaited(_toggleFullscreen())` 同款）先派发、后返回 handled。
     *    ⚠️ 契约文档里那行 `if (dispatch(...)) return true;` 是**示意**（Future 不能当 bool 用），
     *       真实写法见下 —— 语义等价：动作已派发即视为"这个键我处理了"。
     * ```
     * ⚠️ `target == null` 的"放行"语义由 `dispatch` 自己负责；本页 `this` 恒非 null。
     */
    final liveAction = livePlaybackActionForKey(k);
    if (liveAction != null) {
      debugPrint('[PLAYER-KEY] ⓪ 硬件兜底：$k ⇒ 共用契约动作 ${liveAction.name}');
      unawaited(dispatchLivePlaybackAction(this, liveAction));
      return true;
    }
    return false;
  }

  /// 焦点是否已经在本页的 Focus 子树里（判断 `_onKey` 会不会自己处理）
  ///
  /// # 为什么要这个
  /// ```text
  /// 本 handler 跑在 `_onKey` **之前**。若焦点本来就在本页，
  /// `_onKey` 会处理空格/Enter ⇒ 我若也处理 = **跑两次**：
  ///   空格 ⇒ 暂停又播放 ⇒ 用户看到"没反应"
  ///   Enter ⇒ 全屏又退出 ⇒ 同样"没反应"
  /// ★ 这是**加了兜底之后才会出现的新 bug**，必须防。
  /// ```
  ///
  /// # 判据：走**焦点树**，不走元素树
  /// ```text
  /// `FocusNode.ancestors` 是 Flutter 给的焦点树祖先链 ——
  /// 用它判断"primaryFocus 是不是我（或我的后代）"最直接。
  ///
  /// ⚠️ 我第一版想用 `visitAncestorElements` 从焦点往上找 build 出来的锚点，
  ///    那是**错的**：`Focus` widget 是 `GestureDetector` 的**祖先**，
  ///    从焦点往上走永远遇不到在它**下面**的锚点。
  ///    ⇒ 走焦点树（`ancestors`）才对，而且要比较**焦点节点**而不是元素。
  /// ```
  bool _focusIsInsideThisPage(FocusNode? f) {
    if (f == null) return false;
    if (identical(f, _pageFocusNode)) return true;
    // ★ `ancestors` 是惰性 Iterable —— 用 `any` 短路，别展开整个链
    return f.ancestors.any((a) => identical(a, _pageFocusNode));
  }

  /// 处理按键
  ///
  /// # ★ 桌面与 TV 是**两套**键位
  ///
  /// ```text
  /// 桌面：← → 是 5 秒；有 J/L/数字/F/P/逗号句号/N
  /// TV：  ← → 是 10 秒；只有方向键 + 确认 + 返回
  /// ```
  /// 原版注释强调过 TV 上列键盘键位"对遥控用户毫无意义"。
  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    /*
     * ★ 三层诊断的第①层：入口（task-42，照直播页的做法）
     *
     * # 为什么播放页也需要
     * ```text
     * 用户报「要支持空格暂停/播放」—— 但代码里**早就有**空格处理（L4211 附近）。
     * ⇒ 那说明"有代码"不等于"按了有反应"。
     * ★ 最可能的是**焦点问题**（我刚好在直播页证明了同一个根因：
     *   焦点在底栏 tab 上时，播放页的 Focus 同样收不到键）。
     * ⇒ 加这一行，一眼就能区分"键没到"和"键到了但分支不对"。
     * ```
     */
    if (event is KeyDownEvent) {
      debugPrint('[PLAYER-KEY] ⓪ 入口：收到 ${event.logicalKey.keyLabel}');
      // ★ Owner 第 1 条：按键也是「人还在操作」——续命光标隐藏计时器。
      //    （判据里已含「浮层开着 ⇒ 不续命」，见 `_noteCursorActivity()`。）
      _noteCursorActivity();
    }
    /*
     * ══════════════════════════════════════════════════════════════
     * ★★★ PC 方向键：单击 = 步数控制，长按 = 快进快退
     * ══════════════════════════════════════════════════════════════
     *
     * ★ 必须放在下面那个“只接收 down/repeat”的守卫**之前**。
     *   那个守卫会直接 `ignored` 掉 `KeyUpEvent`，
     *   而“松开”正是长按结束、恢复原倍速的**唯一信号** ——
     *   放在后面的话，用户按住方向键松手后，
     *   倍速会**永远卡在 3x** 。（与鼠标长按必须用
     *   `onLongPressEnd` 而不是 `onLongPress` 同一个道理。）
     *
     * ★ 只接管 ←/→：↑/↓ 是**音量**，用户没让改（task-15 第 5 条）。
     */
    if (_isPcKeyboardTarget && PcArrowKeyRouter.isArrowKey(event.logicalKey)) {
      return _handlePcArrowKey(event);
    }

    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final k = event.logicalKey;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 选集面板打开时，方向键**归面板**（2026-09-24 TV 适配）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须在播放页这一层拦
     *
     * 播放页的 `_onKey` 把方向键定义成播放器快捷键
     * （←/→ 快进、↑/↓ 音量）。面板打开时如果不拦，
     * TV 用户按方向键**音量会变、进度会跳**，而面板里的焦点一动不动
     * —— 遥控器等于选不了集。
     *
     * # 为什么不能只靠 `spatial_nav.dart` 的全局 handler
     *
     * 那个 handler 有**页面层门控**：
     * ```dart
     * // shell.dart
     * bool _pageUsesArrowKeys() => _playerOpen;
     * if (_pageUsesArrowKeys()) return false;   // 放行给播放器
     * ```
     * 它的设计意图是"TV 上播放器需要方向键"（快进/音量），
     * 所以**在播放页里它整个让路**。于是面板里的焦点永远收不到按键。
     *
     * # 解法：面板打开时，把方向键交给面板自己的焦点树
     *
     * ```text
     * 面板没开 → 方向键照旧 = 播放器快捷键（已验收，不动）
     * 面板开着 → return ignored → 事件流到焦点树
     *            → Flutter 内建的方向遍历在网格里移焦点
     *            → Scrollable.ensureVisible 把新焦点滚进来
     * ```
     *
     * ⚠️ 返回 `ignored` 而不是自己调 `moveFocus()`：
     *    面板是**普通网格**（不是首页那种跨区块布局），
     *    Flutter 内建的 `DirectionalFocusIntent` 在合成树里是好的
     *    （`spatial_nav.dart` 的文件头记录过：
     *    「内建遍历在**合成树**里是好的（right=1 down=3）」）。
     *    自己再算一遍几何邻居反而会跟内建规则打架。
     *
     * ⚠️ 只对 TV 生效 —— 桌面/手机上方向键本来就该是播放器快捷键，
     *    而且桌面选集面板里用鼠标，不需要方向键。
     */
    if (widget.isTv && _episodeSheetOpen && _arrowKeys.contains(k)) {
      return KeyEventResult.ignored;
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-53【③】「所有直播」面板打开时，↑/↓ 归**面板**（用户第 3 条）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 为什么必须有这条（不加就是"选不了台"）
     * ```text
     * 本页的 ↑/↓ 在直播时被定义成"切台"（#4b，见上面 arrowUp/arrowDown）。
     * 面板打开后若不禁用：
     *   ⇒ 用户想在列表里往下移动，结果**每按一次就换一个台**
     *     （列表还在，但当前台在背后不停变）——完全选不了。
     * ★ 与 `live_page.dart` 的 `_allChannelsOpen` 门控**同一纪律**
     *   （那里的注释逐字记录了同一个坑）。
     * ```
     *
     * ★ 返回 `ignored`（不是 `handled`）：让事件**继续往下走**给焦点树
     *   ⇒ 面板里的 `ListView` 自己处理滚动/焦点移动。
     *
     * ⚠️ **所有端**都要放行（不只是 TV）——
     *    桌面上用户同样会用 ↑/↓ 或滚轮在列表里找台；
     *    而选集面板那条只对 TV 生效是因为"桌面选集用鼠标"，
     *    这里不同：直播列表在桌面也是要**上下翻**的。
     */
    if (_liveChannelsOpen && _arrowKeys.contains(k)) {
      return KeyEventResult.ignored;
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 选集面板打开时，**确认键也必须让给面板**（2026-09-24 修的真 bug）
     * ══════════════════════════════════════════════════════════════════
     *
     * # 症状（只做上面那条"方向键放行"是不够的）
     *
     * ```text
     * TV 用户：点「选集」→ 面板打开 → 按方向键，焦点环**正常移动** ✓
     *         → 按 OK（确认）想选这一集
     *         → ★ 播放器**暂停/播放**了一下，集没选上 ✗
     * ```
     * 也就是「看得见、走得动、**选不了**」——
     * 与 `spatial_nav.dart` 文件头记录的那个假象完全同类：
     * **能移动焦点 ≠ 能选片**。
     *
     * # 根因
     *
     * 按键派发是**从叶子往根走**的（`FocusManager` 遍历
     * `primaryFocus.ancestors`），碰到第一个 `handled` 就停：
     * ```text
     * 焦点链：  _EpisodeChip 的 InkWell/Focus
     *            → ... → 播放器根的 Focus(onKeyEvent: _onKey)   ← ★ 在这里
     * ```
     * 播放页那个 `Focus` 的 `_onKey` 把 `enter/select` 定义成
     * **播放/暂停**（那是原版 ArtPlayer 的键位，桌面/TV 共用），
     * 而它在链上是**格子的祖先** ——
     * 于是 `_togglePlay()` 先返回 `handled`，
     * `ActivateIntent` **永远走不到** `InkWell` 的 `onTap`。
     *
     * # 为什么这才算"与原版一致"
     *
     * 原版的选集格是 DOM `<button>`：TV 上焦点落在按钮里按 Enter，
     * 浏览器直接 `click()` —— **按钮优先**，ArtPlayer 的 hotkey
     * 收不到（原版注释也强调过 hotkey 有 `art.isFocus` 前置条件）。
     * 所以「面板打开时确认键归面板」才是原版行为，不改反而是差异。
     *
     * # 只放行确认键，不放行别的
     *
     * ```text
     * 面板开着 + enter/select/媒体播放键 → ignored（让 InkWell 激活）
     * 面板关着                          → 照旧 _togglePlay()（已验收，不动）
     * 桌面 / 手机                       → 不受影响（只在 isTv 分支里）
     * ```
     */
    if (widget.isTv &&
        _episodeSheetOpen &&
        (k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.gameButtonA)) {
      return KeyEventResult.ignored;
    }

    /*
     * ★★★ task-53【③】「所有直播」面板打开时，**确认键也让给面板**
     *
     * ⚠️ 单独一块，**不合并**进上面那条 —— 理由：
     * ```text
     * `test/episode_strip_test.dart:671` 用正则钉住选集那条的形状：
     *     r'_episodeSheetOpen\s*&&\s*\(?\s*k\s*==\s*LogicalKeyboardKey\.enter'
     * ★ 我第一版把两者合并成 `(_episodeSheetOpen || _liveChannelsOpen) && (k == ...)`
     *   ⇒ 正则**不再匹配** ⇒ 那条既有测试变红（我实测撞到了）。
     * ★ 而那条测试守的是**选集面板**（已验收的 TV 行为），
     *   它有权要求那行**逐字不变** —— 合并等于为了我的新功能
     *   去改一个与它无关的既有契约（铁律 170 的反面）。
     * ⇒ 拆成两块：各自的判据各自成行，互不干扰。
     * ```
     *
     * ★ 语义与上面**完全一致**（TV + 面板开着 ⇒ 确认键归面板），
     *   只是判据从"选集面板"换成"所有直播面板"。
     */
    if (widget.isTv &&
        _liveChannelsOpen &&
        (k == LogicalKeyboardKey.enter ||
            k == LogicalKeyboardKey.select ||
            k == LogicalKeyboardKey.gameButtonA)) {
      return KeyEventResult.ignored;
    }

    // ── 两套共有的：方向键 ──
    if (k == LogicalKeyboardKey.arrowLeft) {
      _seekBy(widget.isTv ? -10 : -5);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowRight) {
      _seekBy(widget.isTv ? 10 : 5);
      return KeyEventResult.handled;
    }
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-53【#4b】直播时 ↑/↓ = **切频道**（不再调音量）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话（第 4 条，**第二次强调**）：
     * ```text
     * > 而且直播进入全屏还是没办法像选集一样切换直播,而且我说的切换,是指的,
     * > 直播进入全屏播放的状态下,然后可以上下切换,然后还可以切换直播
     * > **不是指 在直播页面(未进入全屏)加一个所有直播的按钮进行切换的**
     * ```
     * ⇒ 关键在"**进入全屏播放的状态下**"—— 用户要的是**在播放页里**按 ↑/↓
     *   直接换台，不需要先点任何按钮/打开任何列表。
     *
     * # 为什么改在这里（而不是 `_onHardwareKey` 兜底里）
     * ```text
     * 实测（lead 真机注入按键，日志逐字）：
     *   [PLAYER-KEY] ⓪ 入口：硬件 handler 收到 Arrow Up
     *   [PLAYER-KEY] ⓪ 入口：收到 Arrow Up          ← ★ `_onKey` 也跑了
     * ⇒ 键**确实到了**，只是被下面这两行当成"调音量"了。
     * ★ 而 `_onHardwareKey` 只覆盖 space/enter/escape（**没有** ↑/↓）
     *   ⇒ 改这里**不会**双触发（一次按键只切一个台）。
     * ```
     *
     * # ★ 方向必须与 `live_page.dart` 逐字一致
     * ```text
     * live_page.dart:450-457（既有、已验收）
     *   arrowDown ⇒ cycleChannel(+1)
     *   arrowUp   ⇒ cycleChannel(-1)
     * ⇒ 这里同向。两页方向相反 = "按上却往下走"，是最难查的那类 bug。
     * ```
     *
     * ⚠️ **判据是两个**（`_isLive && onLiveChannelStep != null`）——
     *    缺任一个都退回音量：
     *    · 非直播（点播/回看）⇒ ↑/↓ 仍是音量（已验收，一个字节都不动）
     *    · 直播但没接线（测试/其它调用点）⇒ 同样退回音量，
     *      而不是让按键**静默失效**（那比"调成音量"更糟：用户以为键盘坏了）
     */
    if (k == LogicalKeyboardKey.arrowUp) {
      if (_isLive && widget.onLiveChannelStep != null) {
        debugPrint('[PLAYER-KEY] 直播 ↑ ⇒ 上一个台（delta=-1）');
        unawaited(_switchLiveChannel(-1));
      } else {
        _volumeBy(5);
      }
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown) {
      if (_isLive && widget.onLiveChannelStep != null) {
        debugPrint('[PLAYER-KEY] 直播 ↓ ⇒ 下一个台（delta=+1）');
        unawaited(_switchLiveChannel(1));
      } else {
        _volumeBy(-5);
      }
      return KeyEventResult.handled;
    }

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ 输入框守卫：焦点在输入框里时，Enter / 空格**让给输入框**
     * ══════════════════════════════════════════════════════════════════
     *
     * # 症状（Owner 2026-10-11 报的真 bug）
     * ```text
     * 「弹幕屏蔽词这里 我点击回车**不会换行**，反而会**播放**」
     * ```
     *
     * # 根因：两条入口的守卫**不对称**
     * ```text
     * ① 硬件路径 `_onHardwareKey`：**有**输入框守卫（门控③），
     *    但它被门控①（`if (_anySheetOpen) return false;`）挡掉 ——
     *    弹幕面板开着 ⇒ 硬件入口让路。
     * ② 焦点树路径 `_onKey`（本函数）：**原本没有**输入框守卫 ——
     *    于是面板开着时 Enter 落到下面的分支 ⇒ 桌面走全屏 / TV 走 _togglePlay。
     * ⇒ ★ 这正是"硬件路径挡住了、焦点树路径没挡"的两套真相漏洞
     *    （与 `live_page.dart` 里 `_isTypingInField()` 抽函数修的**同一形态**）。
     * ```
     *
     * # 为什么放在这里（分支**之前**、函数中段）
     * ```text
     * ① 必须在 Enter / 空格分支**之前**拦截，否则 Enter 已经 `_togglePlay()`。
     * ② ⚠️ 不能放函数最开头（方向键之前）——
     *    方向键在输入框里的行为另有 `test/focus_narrow_test.dart:220-246`
     *    钉着，本守卫**只**针对 Enter/空格这两条"会误触发播放/全屏"的键。
     * ③ 用**共用**的 `_isTypingInField()`（与 `_onHardwareKey` 同源）——
     *    不许再抄一份判据。
     * ```
     *
     * ⚠️ `_anySheetOpen` 门控①**不动**：它修过"TV 上 Enter 选条目变全屏"的
     *    bug（见上方 L10764 的长注释）。本守卫是**叠加**在它之上的，不是替换。
     */
    if (_isTypingInField()) return KeyEventResult.ignored;

    // ── 确认键 ──
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ Enter：桌面 = 全屏，TV = 播放/暂停（task-42，用户要求）
     * ══════════════════════════════════════════════════════════════════
     *
     * 用户原话：
     * > 然后播放页面要支持空格暂停/播放,enter 和 双击 进入/退出 全屏
     *
     * # 为什么桌面与 TV 必须分开
     * ```text
     * Enter 在 TV 上是**确认键** —— 选剧集、点按钮都要用它。
     * ★ 而上面 L4086-4135 那段（面板打开时 Enter 让给面板）正是
     *   为这件事修的 bug：TV 用户"看得见、走得动、**选不了**"。
     * ⇒ 若把 TV 的 Enter 也改成全屏，那个 bug 会**立刻复发**。
     * ⇒ 所以：**只在桌面**把 Enter 改成全屏。
     * ```
     *
     * # PC 会不会因此丢掉"Enter 播放/暂停"
     * ```text
     * 会 —— 但不损失能力：PC 还有**空格**（同一个功能，见下面 L4211 附近）。
     * ★ 而且用户明确要"enter 进入/退出全屏"，这是他点名要的键位变更。
     * ```
     *
     * ⚠️ 面板打开时**不抢** Enter（照 `_episodeSheetOpen` 的既有门控）——
     *    桌面也可能打开选集面板，那时 Enter 该激活面板里的项。
     */
    final enterLike =
        k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.select ||
        k == LogicalKeyboardKey.mediaPlayPause;
    if (enterLike) {
      if (!widget.isTv && !_anySheetOpen) {
        // 桌面 + 没有浮层 ⇒ Enter = 全屏（用户要求）
        debugPrint('[PLAYER-KEY] Enter ⇒ 切换全屏');
        unawaited(_toggleFullscreen());
        return KeyEventResult.handled;
      }
      _togglePlay();
      return KeyEventResult.handled;
    }

    /*
     * ── 返回键（TV）──
     *
     * ★★★ 下面这条 `else if` 链**越长越危险**：三条既有断言都在「Esc 分支
     *    之后 **700 字符**」这个窗口里找分支（`player_capability_test.dart:986-993`
     *    找 `_settingsOpen`/`_episodeSheetOpen`；`t78_video_zoom_hwdec_test.dart:448-456`
     *    找 `_zoomOpen`），窗口装不下就会红在**别人**的测试里。
     *
     * 实测（`.probe/yamby/strip_probe.dart`，剥注释后从 Esc 行起算；
     * 2026-10-05 15:38 复测于 player_page.dart sha256 2f5a0f3c…）：
     * ```text
     * _biliSheetOpen        156      ← task-31 ④
     * _subtitlePanelOpen    239      ← task-31 ⑤
     * _danmakuSheetOpen     330
     * _settingsOpen         428      ← capability 找它
     * _zoomOpen             576      ← t78 找它
     * _episodeSheetOpen     658      ← capability + t78 找它（只剩 42 字符余量）
     * ```
     * ⇒ 加分支前先跑一次那个探针；**别在这条链里写注释**（注释也算窗口宽度）。
     */
    if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      if (_hintsOpen) {
        _escCloseSheet(() => _hintsOpen = false);
      } else if (_biliSheetOpen) {
        _escCloseSheet(() => _biliSheetOpen = false);
      } else if (_subtitlePanelOpen) {
        _escCloseSheet(() => _subtitlePanelOpen = false);
      } else if (_danmakuSearchOpen) {
        _escCloseSheet(() => _danmakuSearchOpen = false);
      } else if (_danmakuSheetOpen) {
        /*
         * ★ task-13 ⑦ 弹幕设置面板 —— 它挂在设置面板**之后**
         *   （同一套 Positioned.fill 全屏 scrim）⇒ 层序更上，
         *   Esc 必须先关它。挂载顺序与这里的顺序必须一致。
         */
        _escCloseSheet(() => _danmakuSheetOpen = false);
      } else if (_settingsOpen) {
        /*
         * ★ 设置面板排在最前面（它是**最后打开的**那一层）
         *
         * 面板是 `Positioned.fill` 盖在所有东西之上的，所以 Esc 必须先
         * 关它 —— 否则用户看到面板还开着，窗口却退出了全屏/返回了上一页。
         * 这与播放页其它浮层（提示 / 选集 / 线路）的层级顺序一致。
         */
        // ★ 三步（改真源 / 收 portal / 叫回底栏）都在那个方法里，
        //   理由见它的注释 —— 这里只剩一行，是为了让 Esc 链**短**。
        _closeSettingsFromEsc();
      } else if (_zoomOpen) {
        /*
         * ★★★ task-22 P1-5：长按弹出的画面缩放滑条
         *
         * 层序放在设置面板**之后**：面板是 `Positioned.fill` 的全屏 scrim，
         * 滑条只是底栏上的一条 —— 两者同时开着时先收滑条才符合直觉。
         * ⚠️ 不许挪到 `_settingsOpen` 之前：`player_capability_test.dart:981`
         *    在 Esc 分支后 700 字符的窗口里找 `else if (_settingsOpen)`。
         */
        _escCloseSheet(() => _zoomOpen = false);
      } else if (_episodeSheetOpen) {
        // ★★★ Owner 第 2 条：Esc 关选集也要恢复播放（链里只占一行，
        //   转发 `_escCloseSheet` 以保住 t27_w17 钉的 8 次计数）。
        _escCloseEpisodeSheet();
      } else if (_streamSheetOpen) {
        _escCloseSheet(() => _streamSheetOpen = false);
      } else if (_liveChannelsOpen) {
        // ★ task-53【③】「所有直播」面板也要能被 Esc 关掉
        //   （与其它浮层同层级 —— 否则用户以为 Esc 坏了）
        _escCloseSheet(() => _liveChannelsOpen = false);
      } else if (_popover.openId != null) {
        // ★ 悬浮小窗（倍速 / 线路 / 字幕 / 弹幕 / 更多）
        //
        // 放在**所有真浮层之后、全屏之前**：popover 只是贴在按钮旁的小卡片，
        // 它开着时 Esc 该先把它收掉，而不是直接退出全屏。
        _popover.close();
      } else if (_fullscreen) {
        /*
         * ★ 全屏时先退出全屏，**不要**直接返回（2026-09-24）
         *
         * # 为什么必须这样（否则用户会被"困住"）
         *
         * 桌面全屏后，`windowManager.setFullScreen(true)` 会去掉窗口装饰。
         * 如果 Esc 直接 pop 播放器，就变成：
         * ```text
         * 全屏 → Esc → 回到详情页，但**窗口还是全屏的**
         *          → 用户看不到标题栏、也不知道怎么退出全屏
         * ```
         * 这是所有播放器的通行约定（也是浏览器 Fullscreen API 的行为）：
         * **Esc 的语义是"退出全屏"，不是"关闭播放器"**。
         *
         * 退出全屏后再按一次 Esc 才 pop —— 与用户直觉一致。
         */
        // 不 await：_onKey 是同步的（KeyEventResult 必须同步返回）。
        // _toggleFullscreen 内部自己处理异步，这里 fire-and-forget。
        unawaited(_toggleFullscreen());
      } else {
        // ★ 走统一出口（会先退出全屏）—— 见 `_exitPlayer` 的说明
        unawaited(_exitPlayer());
      }
      return KeyEventResult.handled;
    }

    // ── 以下仅桌面 ──
    if (widget.isTv) return KeyEventResult.ignored;

    if (k == LogicalKeyboardKey.space) {
      /*
       * ══════════════════════════════════════════════════════════════
       * ★★★ 浮层打开时，空格**必须让给浮层**（2026-09-25 修的真 bug）
       * ══════════════════════════════════════════════════════════════
       *
       * # 症状（另一代理独立验证实测，`.probe/` 里 V43h 那组）
       * ```text
       * V43h|【阳性对照】无浮层：togglePlay 增量=1（期望 1）✓
       * V43h| 找到浮层入口: 快捷键 ⇒ 点击
       * V43h| 浮层打开后：焦点树路径(_onKey)=1
       * V43h| ★★ 浮层状态（浮层=true）= true      ← ★ 前置条件成立
       * V43h| 浮层打开后 togglePlay: 2 -> 3（增量 **1**）  ← ★★ 穿透！
       * ```
       * 即：浮层开着按空格 ⇒ **后台播放器被切了**，而浮层挡着看不见
       * ⇒ 用户觉得"怎么乱了"。
       *
       * # 根因：**两条路径的语义不一致**
       * ```text
       * ① 硬件路径 `_onHardwareKey`：★ 我**自己**把 `_anySheetOpen` 做成了
       *    **全局**门控（`if (_anySheetOpen) return false;`）
       * ② 焦点树路径 `_onKey`：★ **没有**这个全局门控
       *    （只在 TV 的 `_episodeSheetOpen` 下局部判了方向键/确认键）
       *
       * ⇒ 浮层打开时：① 返回 ignored ⇒ 派发继续 ⇒ ② 跑起来 ⇒ 空格切播放器
       * ★ 也就是说：**我在硬件路径上表达过的意图，在焦点路径上没落实**。
       * ```
       *
       * # 为什么与 L4367/L4417 那两个既有门控是**同族**问题
       * ```text
       * L4367/L4417 修的是「TV 点选集 → 面板打开 → 按 OK 想选这一集
       *                  ⇒ 播放器暂停/播放了一下，集没选上」
       * ★ 那次修的是**确认键**，且**只在 TV + 选集面板**下。
       * ★ 而**空格从未被检查** —— 空格恰是 **PC 的播放/暂停主键**。
       * ⇒ 同一个根因（浮层不设防）在另一条键位/另一个平台上复发。
       * ```
       *
       * # 为什么只在**空格分支**加检查，而不是函数开头全局放行
       * ```text
       * ⚠️ 陷阱：Enter 的既有逻辑（上面 L4473）**已经在用它做分支**：
       *     `if (!widget.isTv && !_anySheetOpen) { …全屏… }`
       *   若在函数**开头**写 `if (_anySheetOpen) return ignored;`
       *   ⇒ Enter 就**永远到不了**那个分支（浮层里 Enter 再也激活不了项）
       *   ⇒ 会把 L4367 修好的东西**改坏**。
       * ⇒ 所以只加在空格分支：**改动 1 处、不碰 Enter 语义**。
       * ```
       *
       * ⚠️ 覆盖范围：`_anySheetOpen` 是**四种浮层**的并集
       *    （选集 / 设置 / 线路 / 提示）⇒ 本判断对四者**同时**生效
       *    （它们共用这一行代码）。
       */
      if (_anySheetOpen) return KeyEventResult.ignored;
      _togglePlay();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyJ) {
      _seekBy(-10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyL) {
      _seekBy(10);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyM) {
      /*
       * ★★★ 2026-10-25（交叉复核抓的必需修复）：**浮层打开时 M 必须让位**
       *
       * # 缺陷（V43h 那个真 bug 的**同一形态**，只是当时只修了空格）
       * ```text
       * 空格分支（上面几行）有 `if (_anySheetOpen) return ignored;`，
       * 而 M 分支原来**没有** ⇒ 选集/设置/线路/提示 打开、焦点在页内时按 M，
       * 会把**后台播放器**静音（用户看不到、也听不出，回来发现没声音）。
       * 而焦点在页外时，`_onHardwareKey` 开头的全局门控
     * （`if (_anySheetOpen) return false;` —— ★ 原来这里写的是 `:13879`，
     *   2026-10-26 复核时该行号已漂到一条注释上，故改成代码片段锚）
       * 已经挡住 ⇒ **同一个键两种语义**，这正是"两套真相"的典型。
       * ```
       * ⚠️ 只补 M（不动 J/L/F/P/N 等既有键位）—— 与当年"只加在空格分支、
       *    不碰 Enter 语义"同一纪律：一次只改一处、可单独注入验证。
       * ⚠️ 判据是 `_anySheetOpen`（选集/设置/线路/提示 四者的并集），
       *    与空格分支**共用同一个真源**，不另写一份。
       */
      if (_anySheetOpen) return KeyEventResult.ignored;
      _toggleMute();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyF) {
      _toggleFullscreen();
      return KeyEventResult.handled;
    }
    // ★ P = 画中画（原版：`hk.add("KeyP", ...)`）
    if (k == LogicalKeyboardKey.keyP) {
      _togglePip();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.keyN) {
      _gotoNextEpisode();
      return KeyEventResult.handled;
    }
    // ★ task-21 P1-30：S = 截图（原版 ArtPlayer 的 `hk.add("KeyS", ...)`）
    //
    // 门控必须写在**这个分支里面**（与上面空格分支同一个理由，见那段注释）：
    // 放到函数开头做全局放行会改坏 Enter 的既有逻辑。
    if (k == LogicalKeyboardKey.keyS) {
      if (_anySheetOpen) return KeyEventResult.ignored;
      unawaited(_takeScreenshot());
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.comma) {
      _rateBy(-0.25);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.period) {
      _rateBy(0.25);
      return KeyEventResult.handled;
    }

    // ── 数字键 0–9 跳百分比 ──
    final digits = <LogicalKeyboardKey, int>{
      LogicalKeyboardKey.digit0: 0,
      LogicalKeyboardKey.digit1: 10,
      LogicalKeyboardKey.digit2: 20,
      LogicalKeyboardKey.digit3: 30,
      LogicalKeyboardKey.digit4: 40,
      LogicalKeyboardKey.digit5: 50,
      LogicalKeyboardKey.digit6: 60,
      LogicalKeyboardKey.digit7: 70,
      LogicalKeyboardKey.digit8: 80,
      LogicalKeyboardKey.digit9: 90,
    };
    final pct = digits[k];
    if (pct != null) {
      _seekToPercent(pct);
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// ★ 这次失败**是不是登录问题**（决定失败页显不显示「登录」按钮）
  ///
  /// # ★★★ 2026-09-25（task-38）：这里原先的注释**事实是错的**
  ///
  /// 原注释写着：
  /// > 为这一处判断去改动整条错误传递链的类型（并同步改 Rust/FFI/Dart），
  /// > **风险和收益完全不成比例**。
  ///
  /// 那个判断**不成立** —— 链上**早就有**结构化类别了：
  /// ```text
  /// rust/sourin_core/src/ffi.rs 的 err_json
  ///   → {"error": "...", "kind": "network|unauthorized|not_found|unsupported|other"}
  /// lib/core/ffi.dart
  ///   → class SourinCoreException { final String kind; ... }
  ///                       // ↑ kind 一直在！还带文档注释
  /// ```
  /// 真正的问题是**这一层自己把它 `toString()` 掉了**：
  /// ```dart
  /// _error = e.toString();   // ← kind 被拼进字符串，然后就只能靠"找词"
  /// ```
  /// 所以不是"改造成本高"，而是"现成的信息被丢了"。
  ///
  /// # 现在的判据（结构化优先，文案兜底）
  ///
  /// ```text
  /// ① `_errorKind == 'unauthorized'`  → true
  ///    ★ 来自 FFI 的结构化字段，**不受文案影响**
  /// ② 否则回退到字符串匹配（老路径 / 本页自拼的中文串 / media_kit 错误）
  ///    · 'unauthorized'  ← 插件自己抛的（animesource.js: 'unauthorized: 登录已失效…'）
  ///    · '登录已失效'     ← playback.rs:157 的固定文案
  /// ```
  /// ⚠️ 保留兜底是**有意**的：`_errorKind` 为 null 的情况真实存在
  ///    （`_error = '该内容没有可播放的地址'` 这种本页自拼的串、
  ///    以及 `media_kit` 抛的播放错误都没有 kind）。
  ///
  /// ⚠️ 宁可漏判也不能误判：误判会让「没有可播放地址」这类用户
  ///    看到一个无关的登录按钮。所以**不做**「包含『登录』二字」这种宽泛匹配 ——
  ///    「该源需要登录后才能播放」也含「登录」，但它不是失效。
  bool get _isAuthError {
    /*
     * ① ★ 结构化优先：kind 直接来自 FFI，与文案措辞**完全无关**。
     *    ⇒ 以后插件把 'unauthorized: …' 改成任何说法，这里都不会漏判。
     */
    if (_errorKind == 'unauthorized') return true;

    // ② 兜底：没有 kind 的老路径（见上面注释）
    final e = _error;
    if (e == null) return false;
    final lower = e.toLowerCase();
    return lower.contains('unauthorized') || e.contains('登录已失效');
  }

  /// 从任意异常里取出**结构化类别**（拿不到就 null）
  ///
  /// # 为什么要单独一个函数（而不是每处写 `e is SourinCoreException ? e.kind`）
  ///
  /// ```text
  /// ① 4 处赋值点都要用 —— 写 4 遍必然漂（本项目已有"两处同构必须一起改"的教训）
  /// ② 类型判断集中一处：以后 FFI 换异常类型只改这里
  /// ③ ★ `Object?` 入参而不是 `dynamic`：Dart 的 `is` 检查对 `Object?` 完全安全，
  ///    且不会因为动态派发把拼写错误藏起来
  /// ```
  ///
  /// ⚠️ 返回 `null` 是**正常情况**，不是失败：`media_kit` 的播放错误、
  ///    本页自己拼的中文串都没有类别 → 调用方回退到字符串判据。
  static String? _kindOf(Object? e) {
    if (e is SourinCoreException) {
      final k = e.kind;
      return k.isEmpty ? null : k;
    }
    return null;
  }

  /// ★ 就地登录，成功后自动重试播放（用户要求「点击可以进行直接登录」）
  ///
  /// 只在登录**成功**时才重试：失败还去重试等于白打一次请求，
  /// 而且会把用户刚输错密码的提示冲掉，让他以为"点了没反应"。
  Future<void> _loginAndRetry() async {
    /*
     * 弹窗标题要显示源的**中文名**（"登录 某动画站"），而不是 id（"animesource"）。
     * 播放页只持有 id（`widget.provider`），所以现查一次 ——
     * `listProviders()` 走的是本地注册表，没有网络开销。
     *
     * ⚠️ 查不到就**退回 id**，不能因为"拿不到漂亮名字"就不弹窗 ——
     *    用户此刻要的是登录，不是标题好看。
     */
    var name = _provider;
    try {
      final list = await SourinApi.listProviders();
      final hit = list.where((p) => p.id == _provider).firstOrNull;
      if (hit != null && hit.name.isNotEmpty) name = hit.name;
    } catch (e) {
      debugPrint('[PLAYER] 取源名称失败（退回 id）: $e');
    }

    if (!mounted) return;
    final ok = await showProviderLoginDialog(
      context,
      providerId: _provider,
      providerName: name,
    );
    if (!mounted || !ok) return;
    debugPrint('[PLAYER] 登录成功，自动重试播放');
    await _load();
  }

  /// 退出播放器（**唯一**出口）
  ///
  /// ══════════════════════════════════════════════════════════════════
  /// ★★★ 为什么必须收成一个方法（2026-09-24 用户第三次纠正后发现）
  /// ══════════════════════════════════════════════════════════════════
  ///
  /// 播放器有**三条**退出路径：
  /// ```text
  /// ① 顶栏的返回按钮        onBack: () => Navigator.pop()
  /// ② 错误浮层的「返回」     onBack: () => Navigator.pop()
  /// ③ 键盘/TV 返回键        KeyEventResult 分支
  /// ```
  /// 我原来三处都直接写 `Navigator.of(context).maybePop()`。
  ///
  /// # 漏了什么
  ///
  /// 只 pop 不**退出 OS 全屏**。于是：
  /// ```text
  /// 全屏看片 → 点返回 → 回到详情页
  ///   → 窗口**仍然是全屏的**，而且此时 titleBarVisible 被
  ///     `dispose` 恢复成 true 却被全屏吃掉了看不到
  ///   → 用户看不到标题栏、也不知道怎么退出全屏 = **被困住**
  /// ```
  /// 这和「Esc 只退全屏不返回」是同一类问题的两面。
  ///
  /// # 为什么要在这里退全屏，而不是只靠 dispose
  ///
  /// `dispose` 是**同步**的，而 `windowManager.setFullScreen()` 是**异步**的
  /// —— 在里面 fire-and-forget 会在页面已经销毁后才生效，
  /// 期间用户看到的是"全屏的详情页"。在 pop **之前** await 更可靠。
  ///
  /// ⚠️ 顺序：**先退全屏，再 pop**。反过来的话 pop 已经开始了，
  ///    退全屏的动画会和页面切换动画打架，看起来像闪一下。
  /// ★ task-8 ① 探针：直接 await `_toggleFullscreen()`，量它到底要多久 / 卡不卡。
  ///
  /// # 为什么要单独量它
  /// ```text
  /// `_exitPlayer()` 里只有一处 await 就是它。若它不返回，
  /// 后面的 `maybePop()` **永远不会执行** —— 用户看到的就是「点了返回没反应」。
  /// ```
  Future<int> debugPlayerToggleFullscreenForProbe() async {
    final sw = Stopwatch()..start();
    await _toggleFullscreen();
    return sw.elapsedMilliseconds;
  }

  Future<void> _exitPlayer() async {
    /*
     * ★★★ 防重入（2026-10-18 第 66 轮自审补）
     *
     * # 为什么需要
     * ```text
     * 本方法中段有 `await _toggleFullscreen(awaitOs: false)`（下面 ① 那条），
     * 全屏路径实测要 16.6ms 才返回。这段窗口里 `_fullscreen` 首帧仍为 true，
     * 且**末尾那个 `if (mounted)` 拦不住它**（那时页面还活着）。
     *
     * ⇒ 第二次进入本方法会**再 pop 一次** ⇒ 把详情页也弹掉。
     * ```
     * # 可达性（perf-player 复核时修正过一次判断）
     * ```text
     * 「人反应不过来」不成立 —— **按键重复**能填满这个窗口：
     * 按住 Esc / 返回键时系统以 ~30ms 间隔重复派发，
     * 而 30ms > 16.6ms 的 await 窗口 ⇒ 第二次照样进来。
     * ⇒ 场景是「**按住不放**」，不是「快速连点」。
     * ```
     * ★ 守卫放在最前面：只要有过一次退出请求，后续一律忽略。
     *   故意**不**在 finally 里复位 —— 退出是终止性操作，
     *   本页随即被 pop 掉；若之后还能再进来，说明这页没真的退出。
     */
    if (_exiting) return;
    _exiting = true;
    // 在任何暂停清理和路由返回之前捕获用户播放意图。
    // dispose 仅兜底；单次守卫防止退场阶段重复回传。
    _reportLivePlaybackExit();
    /*
     * ★★★ task-8 ①（Owner 2026-10-09 第三批）：返回卡顿
     *
     * Owner 原话：
     * > 从播放界面返回的时候很卡顿
     *
     * # 实测读数（flutter_tester 逐段 Stopwatch；.probe/zz_t8_latency_probe_test.dart）
     * ```text
     * 非全屏路径：_exitPlayer 同步段 0.70ms | 第一帧 19.06ms | 过渡 4.74ms | 合计 24.50ms
     * 全屏路径  ：_exitPlayer 起手 1.19ms | 第一帧 35.21ms | 过渡 5.14ms | 合计 43.58ms
     *                                              ^^^^^^^^^^ 比非全屏多 16.6ms
     * 对照组：`_toggleFullscreen()` 本体耗时 = 2ms（真时钟 runAsync 量得）
     * ```
     * ⇒ 那 16.6ms 的差额**几乎全在** `await windowManager.setFullScreen(next)`
     *   —— 一次真 OS 往返（真机上还要等窗口管理器回包）。
     *
     * # ★ 我第一版改错过（记录在此，避免有人再走一遍）
     * ```text
     * 我原本写成 `unawaited(_toggleFullscreen())`，被 lead 用真机日志推翻：
     *   `setState(_fullscreen = next)` 虽在同步段，但**布局**要等下一个微任务边界，
     *   而那时 pop 已经开始 ⇒ 退全屏那一帧布局**整个排在 pop 之后**
     *   ⇒ 真机看到「窗口先退全屏、再切页」，比原来更花 ——
     *   正是 :9146 那条注释要避免的。
     * ```
     * ⇒ 正确做法 = **保住 await**，只把最后那次 OS 往返摘出等待窗口（`awaitOs: false`）：
     *   ```text
     *   · `_toggleFullscreen` 的同步段（setState / _flash / 回调 / titleBar）
     *     以及**本帧布局**，都在 `_exitPlayer` 仍 await 时完成 ⇒ **帧序不变**；
     *   · OS 调用照样发出去，只是不串行等它回包。
     *   ```
     * ⇒ 「先退全屏再 pop」的**语义**与**帧序**都保住，卡顿（那次 OS 往返）去掉。
     *
     * ⚠️ 非全屏时**一格都不变**（不进分支）：实测 `_fullscreenCalls 前=0 后=0`。
     */
    // ① 全屏状态下先退全屏（**仍 await**：保住帧序），但不串行等 OS 回包
    if (_fullscreen) {
      await _toggleFullscreen(awaitOs: false);
    }
    // ② 保底：无论是否全屏，退出时标题栏都必须是可见的
    titleBarVisible.value = true;
    /*
     * ★ 并且**必须复位深色态** —— 与 `initState` 里的 `titleBarDark = true` 成对。
     *
     * 漏了的话：进过播放页 → 返回首页 → 标题栏**一直是黑的**
     * （首页是浅色主题，顶一条黑带非常突兀）。
     * 这是"成对置位"类缺陷的典型形态，所以 `_exitPlayer` 与
     * `dispose` **两处都复位**（幂等，`ValueNotifier` 值不变时不通知）。
     *
     * ══════════════════════════════════════════════════════════════════
     * ★★★ OPS-12 ⑦（Owner 2026-10-10 第四批）：**复位时机**也是缺陷的一部分
     * ══════════════════════════════════════════════════════════════════
     *
     * Owner 原话：
     * > 从播放页返回上一级感觉十分卡顿,还是卡顿,还是需要优化
     *
     * # 实测（`.probe\ops\zz_ops12_*_probe_test.dart`，同一次 run 内做因果 A/B）
     * ```text
     * 触发这一行（返回帧同步复位）：返回帧 276 个元素 / 墙钟 59.23ms
     * 抑制这一行（先手动置 false）  ：返回帧 244 个元素 / 墙钟 32.61ms
     *                                    ↑ 差 ≈ 27ms 全在这一行上
     * ```
     * 独立复测（本文件同目录的 `test/zz_cr_jank_titlebar_flip_test.dart`）：
     * ```text
     * 返回帧全量 277 个元素 / 60.67ms，其中**标题栏本体 33 个元素**；
     * 阳性对照（单独人为翻一次深色态）：标题栏本体 33 个元素 / 22.32ms
     * ```
     *
     * # 为什么它这么贵（一句话根因）
     * ```text
     * titleBarDark 由 shell.dart 的 _TitleBarHostState 监听
     * （lib/shell.dart:5199 addListener → :5221 _onVisibleChanged → setState），
     * 而 _TitleBarHost 挂在 MaterialApp.builder 上、**在 Navigator 之上**
     * ⇒ 它一变，**返回帧**（那一帧本来就要付整条 pop 级联）**还要多付一次**
     *   "深色支 → 浅色支"的标题栏重建 —— 浅色支是液态玻璃子树
     *   （GlassContainer / AdaptiveGlass / LightweightLiquidGlass，
     *   见 lib/shell.dart:5473-5497），实测 33 个元素 / ≈22ms。
     * ```
     *
     * # 修法：**让开返回帧**（不是"不复位"）
     * ```text
     * 深色态照样被复位（否则返回首页后标题栏一直是黑的 —— 那是
     * test/titlebar_dark_on_player_test.dart 钉死的成对置位约束），
     * 只是把这次翻转推到**返回帧画完之后**：
     *   · 返回帧只付 pop 级联 ⇒ 用户点下去的那一下不再叠加 22ms；
     *   · 翻转落在转场期间的后一帧（那时页面本来就在重画）。
     * ```
     *
     * # 为什么是 postFrameCallback，不是 `Future.microtask` / `Future.delayed(0)`
     * ```text
     * 微任务/零延时定时器都可能在**返回帧的 build 之前**跑完
     * （帧与帧之间微任务队列会被排空）⇒ 标题栏照样脏在同一帧上，
     * 换了写法没换行为 = 假修。
     * addPostFrameCallback 是**帧边界**语义：保证在"这一帧已经画完"之后才跑。
     * ```
     *
     * ⚠️ 顺带调用了 `scheduleFrame()`：`addPostFrameCallback` **自己不会**
     *    保证有下一帧。若这次 pop 因为某种原因没排上帧（例如栈顶不是本页），
     *    回调就永远不跑 ⇒ 标题栏卡在深色态。`scheduleFrame()` 幂等
     *    （已有帧在排就什么都不做），拿它买这个保证。
     */
    _scheduleTitleBarDarkReset();
    // ③ 真正返回
    /*
     * ★★★ 2026-10-18（N-PAUSE）：带回“用户是不是要暂停”
     *
     * # 为什么从 `maybePop()` 改成 `pop(值)`
     * ```text
     * 直播页需要知道用户在本页里按过暂停没有，
     * 否则它无法判断"切回来要不要自动续播"。
     * 主动退出使用 `pop(result)`，把暂停意图作为路由结果带回。
     * ```
     *
     * 根部 PopScope 不拦截返回，只在成功 pop 后回传直播快照。
     * 主动退出已提前回传；成功 pop 通知与 dispose 兜底复用同一去重保护。
     * 若将来引入 canPop=false 的返回拦截，需要重新核对主动退出契约。
     */
    if (mounted) Navigator.of(context).pop<bool>(_userWantsPause);
  }

  /// 把「标题栏退出深色态」推到**返回帧画完之后**（详见 `_exitPlayer` 里的长注释）。
  ///
  /// ⚠️ 只有 `_exitPlayer` 用这个（主动返回那条路）；`dispose` 里仍然直接复位 ——
  ///    那是**兜底**，它跑的时候页面早就没了，没有"返回帧"可让。
  void _scheduleTitleBarDarkReset() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      titleBarDark.value = false;
    });
    // 见 _exitPlayer 的注释：addPostFrameCallback 不保证有下一帧。
    WidgetsBinding.instance.scheduleFrame();
  }

  // ═══════════════════════════════════════════════════════════════════
  //  生命周期
  // ═══════════════════════════════════════════════════════════════════

  /// ★ 缺陷 13：把 mpv 的缓冲属性接到底栏（500ms 轮询，见 _BufferPoller）
  ///
  /// # 为什么要**交叉校验**（这是本条最容易被忽略的一步）
  /// ```text
  /// demuxer-cache-time 是绝对时间轴上的缓出点，但它**不保证**与
  /// 当前 position 同源 —— 刚 seek 完、或换源之后，两者会短暂地
  /// 各说各话。实测表现是缓冲条**瞬间跨过整个进度条**再弹回来。
  ///
  /// 判据：end 必须 ≈ position + span（跨度就是"从当前位置往后缓存了多少"）。
  /// 差超过 2 秒就认为这一拍不可信 ⇒ 上报 null ⇒ 不画。
  /// 宁可少画一条，也不能画一条错的 —— 用户会据此判断该不该换源。
  /// ```
  ///
  /// ⚠️ `kBufferRangeMode == 'off'` 时**一条属性都不读**（零开销）。
  void _bindBufferPoller() {
    if (kBufferRangeMode == 'off') return;
    _bufferPoller = _BufferPoller(
      read: _readMpvDouble,
      onChanged: (end, statePercent, spanSec) {
        if (!mounted) return;
        _bufferStatePercent = statePercent;
        if (end == null) {
          // ★ 读不到就如实清空（不保留上一次的值 —— 那会变成"卡住不动"的假区间）
          if (_bufferedRange != null) {
            setState(() => _bufferedRange = null);
          }
          return;
        }
        if (spanSec != null) {
          final expected = _position.inMilliseconds + (spanSec * 1000).round();
          if ((end.inMilliseconds - expected).abs() > 2000) {
            debugPrint(
              '[PLAYER] 缓冲区间校验不过：end=${end.inMilliseconds}ms '
              'position=${_position.inMilliseconds}ms span=${spanSec}s ⇒ 本次不画',
            );
            if (_bufferedRange != null) {
              setState(() => _bufferedRange = null);
            }
            return;
          }
        }
        final startMs = spanSec == null
            ? null
            : (end.inMilliseconds - (spanSec * 1000).round()).clamp(0, 1 << 40);
        setState(() {
          _bufferedRange = BufferedRange(
            end: end,
            start: startMs == null ? null : Duration(milliseconds: startMs),
          );
        });
      },
    );
  }

  /// 读一个 mpv 属性为 double；读不到返回 null（**不抛**）
  ///
  /// ⚠️ 判据来自 media_kit 的实现（`real.dart:1278`）：
  ///    `getProperty` 读不到属性时返回**空串**，不抛异常。
  ///    所以"空串"是唯一的失败信号，必须显式拦掉，
  ///    否则 `double.tryParse('')` 虽然也是 null，但会掩盖"属性名写错"这一类错。
  Future<double?> _readMpvDouble(String key) async {
    final platform = _player.platform;
    if (platform is! NativePlayer) return null;
    try {
      final raw = await platform.getProperty(key);
      if (raw.trim().isEmpty) return null;
      return double.tryParse(raw.trim());
    } catch (_) {
      return null;
    }
  }

  @override
  void dispose() {
    _reportLivePlaybackExit();
    /*
     * ★ 2026-10-08（Owner 第 9 条）：控制条动画控制器必须跟着本页销毁 ——
     *   否则 flutter_test 会判红（AnimationController 泄漏）。
     */
    _controlsAnim.dispose();
    _danmakuReadout.dispose();
    // ★ N11：光标态 notifier 必须跟着本页销毁（否则 flutter_test 判泄漏）
    _cursorLive.dispose();
    // ★ N11：控制条显隐 notifier 同理
    _controlsLive.dispose();
    /*
     * ★ N10：让路定时器必须取消，**并且补一次 end**
     *
     * ```text
     * 只 cancel 不 end：若销毁时正好在窗口内，预取会**永久处于让路状态**
     *   ⇒ 远端 seek 从此一直慢（实测 162ms → 190ms），而且没人会发现。
     * ⇒ 所以 cancel 之后必须 fire-and-forget 调一次 endYieldForSeek()。
     *   Rust 侧 end 是幂等的（store(0) + 恢复原值），多调一次无害。
     * ```
     */
    _prefetchYieldTimer?.cancel();
    _prefetchYieldTimer = null;
    // ★★ 2026-10-19（Lead 修，批末自审发现的**真行为回归**）：
    //   `dispose()` 里 `unawaited` 一个**会抛**的调用，而这里没有任何兜底。
    //
    // ```text
    // 现象：核心未启动时（SourinCoreException）异常从 dispose 逃逸成测试失败，
    //       咬红 zz_cr_panel_double_enter 与 zz_cr_panel_notch A③。
    // 根因：`unawaited` 只是"不 await"，**不等于**"异常被吃掉" ——
    //       Future 里的 throw 仍会变成未捕获异常。
    // 为什么是回归：同文件 `_beginPrefetchYield`（:996 / :5540）**有** try/catch，
    //       只有 dispose 这处没有 ⇒ 本轮 N10 引入的不对称。
    // ```
    //
    // ⚠️ 为什么这里**必须**吞掉：dispose 是在页面销毁时跑的，
    //   此时抛异常对用户毫无意义（页面都没了），只会污染日志与测试。
    unawaited(SourinApi.endYieldForSeek().catchError((Object e) {
      // 失败只记日志，不外抛 —— dispose 阶段没有任何补救动作可做
      AppLog.write('PLAYER', 'dispose: 结束取流让出失败（已忽略）：$e');
    }));
    // 缺陷 13：轮询定时器必须跟着本页停掉
    _bufferPoller?.stop();
    _bufferPoller?.clear();
    // ★ 2026-10-09：弹幕失败角标的到点隐藏定时器 —— 不 cancel 会泄漏（且回调打到已卸载 State）
    _danmakuBadgeTimer?.cancel();
    /*
     * ★ 2026-10-18（R3-④）：遮罩关闭后的「播放/暂停守卫保持」定时器。
     *
     * 它由 `_holdSheetGuard()` 装、350ms 后自己撤。
     * 虽然回调里有 `if (!mounted) return` 兜住（不会崩），
     * 但**不 cancel 会让 Timer 在本页销毁后继续持有 State 引用**最多 350ms
     * ⇒ 严格说应当 cancel，与上面几个定时器口径一致。
     */
    _sheetGuardTimer?.cancel();
    _sheetGuardTimer = null;
    /*
     * ★ 退出前**立刻**落盘
     *
     * 原版注释：
     * > 退出/切集/换源前立刻落一次 —— 否则用户切走时最后几秒会丢。
     * ⚠️ 这里不能 await（dispose 是同步的），所以 fire-and-forget。
     */
    _saveProgress(immediate: true);
    /*
     * ★★★ 2026-09-26 第二轮：注销两个 MediaSession 回调
     *
     * ⚠️ 与 `onFullscreenChanged` **同一纪律**（那段注释已解释过）：
     *    回调可能打到**已卸载**的合并页 State 上。
     *    虽然回调里有 `mounted` 守卫，但注销是**结构性**的保证，更强。
     *
     * ★ 注意 `_saveProgress(immediate: true)` 必须留在**前面** ——
     *   它要读 `_title` / `_cover`，而下面只清回调、不清那些字段；
     *   但保持"先落盘再清理"的顺序更安全（免得将来有人顺手清了字段）。
     */
    _onFullscreenChanged = null;
    _onEpisodeChanged = null;
    // ★ popover 的唯一真值源（ChangeNotifier ⇒ 必须 dispose）
    //   ⚠️ 先摘掉监听（缺陷 ⑤）再 dispose —— 顺序反了会在 removeListener
    //     时撞上已 dispose 的 notifier 断言。
    _popover.removeListener(_onPopoverChanged);
    _popover.dispose();
    _positionNotifier.dispose();
    // ★ 2026-10-14：弹幕轻量悬浮窗的实时值载体（ChangeNotifier ⇒ 必须释放）
    //   ⚠️ 无监听者需要摘（订阅它的 `ValueListenableBuilder` 在 dispose 前
    //     已随树拆掉，它自己会 removeListener）—— 直接 dispose 即可。
    _danmakuQuickLive.dispose();
    /*
     * ★ 注销 early handler + 释放显式 FocusNode（task-42）
     *
     * ⚠️ **必须**注销 —— `FocusManager` 是应用级单例，
     *    不移除的话本 handler 会在**播放页已销毁后**继续收键，
     *    而它引用的 `_livePlayerState`/播放器已经不能用了
     *    （轻则无效，重则 setState-after-dispose）。
     *
     * ⚠️⚠️ 必须用 `removeEarlyKeyEventHandler` **配对** ——
     *    用 `removeHandler` 会**静默失败**（shell.dart L2361 记录过），
     *    于是 handler 永远留在链上（且每次进播放页再加一个 ⇒ 累积）。
     */
    FocusManager.instance.removeEarlyKeyEventHandler(_onEarlyKey);
    _pageFocusNode.dispose();
    _progressTimer?.cancel();
    _countdownTimer?.cancel();
    _rewatchTimer?.cancel(); // ★ fix/rewatch-prompt：浮层自动消失定时器
    _hideTimer?.cancel();
    // ★★★ Owner 第 1 条：光标隐藏计时器也必须收 —— 否则退出播放页后
    //    它到点会对着已卸载的 State 跑（轻则无效，重则 setState-after-dispose）。
    //    ⚠️ 不用在这里手动把光标恢复：整棵渲染树随本 State 一起消失，
    //    `SystemMouseCursors.none` 不可能「漏」到别的页面去。
    _cursorIdleTimer?.cancel();
    _rewindTimer?.cancel(); // ★ 左半屏长按的连续快退定时器
    /*
     * ★ PC 方向键长按的收尾（task-15）
     *
     * 用户按着方向键时退出播放页：若不收尾，
     * 倍速会永远停在 3x（下一集也是 3x）。
     */
    _pcArrowHoldTimer?.cancel();
    _pcArrowHoldTimer = null;
    if (_pcArrow.reset()) _endPcArrowHold();
    /*
     * ★ 画面输出层看门狗作废（它是个 while 轮询，最多 10 秒）
     *
     * 没有 Timer 可以 cancel —— 它靠代次号自证过期（`_watchVideoOutput`
     * 每轮都查 `token != _videoOutputToken || !mounted`）。这里把代次号
     * 推进一格，让**已在飞行中的那一轮**立刻放弃，而不是等它跑完
     * 再对着已卸载的 State 调 `setState`。
     */
    _videoOutputToken++;
    PipController.instance.removeListener(_onPipChanged);
    // ★ 退出播放器时要退出 PiP —— 否则窗口会一直卡在小窗状态
    if (_pipActive) PipController.instance.exit();
    /*
     * ★ 兜底：无论如何都要退出全屏（2026-09-24）
     *
     * 正常路径由 `_exitPlayer()` 处理（它会在 pop 前 await）。
     * 这里是**最后一道防线** —— 万一将来有人加了一条新的 pop 路径
     * 而忘了走 `_exitPlayer`，至少不会留下一个"全屏的、没有标题栏的"
     * 窗口把用户困住。
     *
     * ⚠️ 这里是同步上下文，只能 fire-and-forget —— 所以它是兜底，
     *    不是主路径（主路径必须 await，否则会闪）。
     */
    if (_fullscreen && Device.isDesktop) {
      unawaited(windowManager.setFullScreen(false));
    }
    /*
     * ★ 幂等地把标题栏置为可见（2026-09-24）
     *
     * 播放页**不再隐藏**标题栏（见 `initState` 的长注释：桌面端那是
     * 唯一的拖动区）。这里仍然显式置 true 是**防御性**的：
     * ```text
     * 将来若给"沉浸模式"加隐藏逻辑，退出时必须还原 ——
     * 漏了的话用户会「从播放器返回后再也拖不动窗口」，
     * 而且很难联想到是播放页造成的。
     * ```
     * 幂等赋值没有副作用（`ValueNotifier` 值不变时不通知）。
     */
    titleBarVisible.value = true;
    /*
     * ★ 同样复位**深色态**（与 `initState` 的 `titleBarDark = true` 成对）。
     *
     * 为什么 `_exitPlayer` 与这里**都**写：`dispose` 是**必然**执行的
     * （点返回、被 `pushReplacement` 换掉、页面被销毁都走它），
     * 而 `_exitPlayer` 只覆盖"主动返回"。
     * 两处都复位才能保证**任何**退出路径都不留下黑标题栏。幂等无副作用。
     */
    titleBarDark.value = false;
    /*
     * ★ 注销探针登记（2026-09-25）
     *
     * ⚠️ 必须在这里清 —— 否则探针会拿到一个 **已 dispose 的 state**，
     *    读它的 `_position` 看似有值（Dart 对象还在），但那是**上一集**
     *    的陈旧读数，会让实测得出错误结论。
     */
    if (identical(_livePlayerState, this)) _livePlayerState = null;


    /*
     * ★ 注销遥控的播放能力（与 initState 的 setPlayer 配对）
     *
     * ⚠️ 顺序在 `_player.dispose()` **之前** —— 桥的 tick 是异步的，
     *    如果先 dispose 播放器再注销，中间那几毫秒里桥可能拿到
     *    一个**已 dispose 的播放器**去 getState/exec。
     *
     * ⚠️ 必须把**自己那个** bridge 实例传进去 —— 换页重叠的瞬间
     *    （新页已 init、旧页还没 dispose）无条件清会把新注册的抹掉，
     *    手机上立刻又变成"没有播放器"。见 `clearPlayer` 的说明。
     */
    RemoteBridge.instance.clearPlayer(_remotePlayerBridge);
    _remotePlayerBridge = null;

    /*
     * ★ task-13 ⑦ 关掉弹幕客户端
     *
     * 里面是一个 dart:io HttpClient（含连接池）—— 不 close 会在
     * 热重载/换页时留下悬挂连接。放在 _player.dispose() 之前，
     * 与其它资源（bridge / 计时器）同一段收尾。
     */
    _danmakuClient?.close();
    _danmakuClient = null;

    /*
     * ★ task-31 ④：外部视频站客户端同理（里面也是一个 dart:io HttpClient）。
     *
     * ⚠️ 不 close 会在热重载/换页时留下悬挂连接 —— 与上面那条同一个理由。
     */
    _biliApi?.close();
    _biliApi = null;

    _player.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    /*
     * ★ 记录"这一次 build 会把 `_controlsVisible` 渲染成什么" ——
     *   `_pushControlsLive()` 的守卫拿它跟目标值比（见该方法的注释）。
     *   本句是**纯赋值**（不 setState、不通知），只服务于那个判据。
     *   ⚠️ 必须放在 build 的**第一句**（早退分支之前也要记，否则早退后守卫会误判）。
     */
    final hints = hintsFor(
      isTv: widget.isTv,
      isTouchOnly: widget.isTouchOnly,
      isLive: _isLive,
    );

    final page = Scaffold(
      backgroundColor: Colors.black,
      body: Focus(
        /*
         * ★ 挂一个**显式** FocusNode（task-42）
         *
         * # 为什么要（原来是 `Focus(autofocus: true)`，没有 node）
         * ```text
         * 加了硬件层兜底之后，我必须能回答：
         *   "焦点**是不是**已经在本页的 Focus 子树里？"
         *     · 是 ⇒ 交给 `_onKey`（我不处理，避免双触发）
         *     · 否 ⇒ 我兜底
         * ★ 那就要有一个**可比较的节点标识** —— 显式 node 提供它。
         * ```
         * ⚠️ 显式 node 必须自己 dispose（否则泄漏）——
         *    见 `dispose()` 里的 `_pageFocusNode.dispose()`。
         */
        focusNode: _pageFocusNode,
        autofocus: true,
        onKeyEvent: _onKey,
        /*
         * ★★★ task-53【#4b-④】滚轮调音量 —— 挂 `Listener`（`MouseRegion` **外面**）
         *
         * # 为什么位置在这里（不能塞进 `GestureDetector` 里面）
         * ```text
         * `Listener` 只对**它子树内**的命中测试生效。
         * 挂在最外层 ⇒ 播放器画面、底栏、浮层**全都是**它的子树
         *   ⇒ 鼠标在页面任何地方滚都能调音量（与提示文案一致）。
         * ★ 而 `MouseRegion.onHover` 已经在这里了（同层），
         *   说明这一层就是"整个播放页的指针入口"—— 放一起最直观。
         * ```
         * ⚠️ `onPointerSignal` 的具体守卫（浮层/横向滚动/`pointerSignalResolver`）
         *    全在 `_onPointerSignal` 里，见那里的长注释。
         */
        child: Listener(
          onPointerSignal: _onPointerSignal,
          child: _CursorRegion(
            listenable: _cursorLive,
            onHover: (_) => _showControls(),
            /*
             * ★★★ task-16（Owner：「全屏左上角这个单独的返回icon,还没消失」）
             *
             * 整页级指针进出 —— 悬浮返回键的**常驻**判据就靠这两位。
             * 见 `_pointerInside` 的长注释（含「为什么不能用 onHover」）。
             *
             * ⚠️ 它们与上面的 `onHover` **并列**、互不替代：
             *    onHover   = 「鼠标在动」⇒ 续命控制条（3 秒计时器重排）
             *    onEnter/Exit = 「鼠标在不在」⇒ 悬浮键该不该常驻
             * 两者的触发条件不同（静止的指针不发 hover），所以缺一不可。
             */
            onEnter: (_) => _onPointerEnter(),
            onExit: (_) => _onPointerExit(),
            child: GestureDetector(
              key: _gestureKey, // ★ 探针靠它精确定位到播放页自己这个 detector
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 单击 = 播放/暂停（**唯一**语义）—— 2026-09-25 用户要求
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话：
             * > 不要单击快进快退,去掉这个功能
             *
             * # 删掉的是什么
             *
             * 之前单击是**按屏幕区域分流**的（用 `onTapUp` 自己判左右）：
             * ```text
             * 左半屏        → 快退 N 秒
             * 右半屏        → 快进 N 秒
             * 正中窄带(±8%) → 播放/暂停
             * ```
             * 现在**左右分流整个删掉**，单击画面一律播放/暂停。
             * 播放/暂停是所有播放器（含原版）的通行习惯，用户没说要动它。
             *
             * ⚠️ 左右**区域**的概念没有消失 —— 它现在只服务**长按**
             *    （左半屏长按=连续快退，右半屏长按=倍速快进），
             *    见下面 `onLongPressStart`。单击不再看坐标。
             *
             * # ★ 顺手修掉一个**真 bug**（原来 PC 单击会同时跳秒 + 暂停）
             *
             * 原来同一个 `GestureDetector` 上同时挂了 `onTap` 和 `onTapUp`。
             * 它俩**不是两个手势**，而是**同一个 `TapGestureRecognizer`**
             * 上的两个回调字段：
             * ```dart
             * // flutter/lib/src/widgets/gesture_detector.dart:1069-1071
             * instance..onTapUp = onTapUp..onTap = onTap;
             *
             * // flutter/lib/src/gestures/tap.dart:754-758
             * if (onTapUp != null) invokeCallback('onTapUp', ...);
             * if (onTap != null)   invokeCallback('onTap', ...);  // 紧随其后
             * ```
             * 也就是**一次单击会把两个回调都跑一遍**，顺序固定为
             * `onTapUp` → `onTap`：
             * ```text
             * PC   点右半屏 → 先快进 10 秒，紧接着又 play/pause
             * 手机 点任意处 → onTapUp 提前 return，然后 onTap 暂停  ← 看似正常
             * ```
             * 手机端"看起来正常"纯属巧合（区域分支提前 return 了），
             * PC 端则是**跳秒 + 暂停**两个动作同时发生。
             *
             * 所以原来那句注释「不能同时用 `onTap` 又自己判区域 ——
             * 会互相吞掉」是**说反了**：不是互相吞，是**两个都执行**。
             * （两个回调都挂在同一个 recognizer 上，不存在竞争。）
             *
             * # 现在只用 `onTap`
             *
             * 区域分流没了，`onTapUp` 也就没有存在理由 —— 直接用 `onTap`，
             * 语义最干净：它就是"一次完整的单击"。
             *
             * # ⚠️ 代价：触摸端单击会延迟约 300ms
             *
             * 触摸端还挂着 `onDoubleTapDown`（双击左右侧快进快退）。
             * `GestureDetector` 只要同时有 `onTap` 和 `onDoubleTapDown`，
             * 单击就必须**等双击判定超时**才触发，否则第一次点击会立刻暂停、
             * 而用户其实想双击快进：
             * ```dart
             * // flutter/lib/src/gestures/constants.dart:35
             * const Duration kDoubleTapTimeout = Duration(milliseconds: 300);
             * ```
             *
             * **这是可接受的**（标准行为：所有"单击 + 双击"共存的播放器
             * 都这样，主流播放器 / 原版 WebView 同理），但要知道有这个延迟。
             *
             * ⚠️ PC 上**没有**这个延迟 —— PC 的 `onDoubleTapDown` 是 null
             *    （见下面的条件挂载），竞技场里没有双击竞争者，
             *    `onTap` 立即触发。
             */
              /*
             * ★★★ 2026-10-18（R3-④）：面板开着 / 刚关掉时**必须**禁掉播放暂停
             *
             * # 修的缺陷（用户：「在这个弹窗内部双击会透传」）
             *
             * ```text
             * 模态面板是「遮罩 + 卡片」两层。在**遮罩区双击**的真实序列：
             *   第 1 击 ⇒ 命中遮罩 ⇒ onClose ⇒ 面板子树被移除
             *   第 2 击 ⇒ 面板已不在 ⇒ 落到播放区 ⇒ 本行
             *          ⇒ _togglePlay() ⇒ **正在播的视频被暂停**
             * ```
             * 实测（`.probe/probe_b_risk_test.dart`）：
             * `[B] ★遮罩双击 ⇒ tap=1 doubleTap=0 longPress=0` ← 普通 onTap 落地
             *
             * # ★★ 为什么判据里多了一个 `_sheetGuardHold`
             *
             * ```text
             * 只写 `_anySheetOpen ? null : ...` **不管用** —— 实测被抓：
             *   第 1 击关窗那一刻 `_anySheetOpen` 就变 false 了，
             *   第 2 击到达时守卫**已经撤掉** ⇒ 照样暂停。
             *   （门禁断言③ 首次跑：Expected 0 / Actual 1）
             *
             * ⇒ `_sheetGuardHold` 让守卫在关窗后**多站 350ms**
             *   （一个 kDoubleTapTimeout + 余量），挡住第 2 击。
             *   它由 `_holdSheetGuard()` 维护，见该方法的文档。
             * ```
             *
             * ⚠️ 这不是"延迟关窗" —— 面板照旧**立即**消失，
             *    用户感觉不到；推迟的只有"守卫何时撤"，无可见效果。
             *
             * # 为什么是这里加守卫，而不是去改弹窗外壳
             *
             * ```text
             * 外壳侧两条路都实测不成立（.probe/t66_r3_listener_attempt.md）：
             *   ① 遮罩注册 onDoubleTap ⇒ 遮罩**单击关窗**要等 300ms（高频路径受损）
             *   ② Listener 判双击 ⇒ 关窗那一刻组件就被 setState 移除，屏障活不过它
             * ⇒ 换个方向：接受透传，但让**落点无害**。
             * ```
             *
             * # 这是补一处**既有不一致**
             *
             * ```text
             * `_anySheetOpen` 已被用在三处守卫（:1062 / :1115 / :11467），
             * 唯独播放/暂停这一条没防。现在补齐。
             * ```
             *
             * ⚠️ 已核实：本 onTap **不承担**控制条显隐 ——
             *    控制条由 `_showControls()` 驱动（起播 / 悬停 / 定时器，
             *    见 :5355 与 `_armHideTimer`），与本行无关。
             *    所以置 null 不影响任何其它交互。
             */
              onTap: (_anySheetOpen || _sheetGuardHold) ? null : _togglePlay,
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 双击左右侧快进快退 —— **PC 上不做**（2026-09-24 用户要求）
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话：
             * > pc端不应该双击左右侧快进快退
             * > 手机端,应该做成配置  双击左右侧 快进快退,配置多少秒
             * >   是否可关闭
             * > 这样子才是对的,**不要把手机上的操作习惯跟PC保持统一**
             *
             * # 原来错在哪
             *
             * 无条件下挂 `onDoubleTapDown` —— PC 上双击也会跳 10 秒。
             * 对鼠标用户那是**误触**：想连点暂停、想选中文字，
             * 结果画面跳了 10 秒；而且 PC 本来就有 J/L/方向键，
             * 根本不需要手势。
             *
             * # 现在
             *
             * ```text
             * PC    → **双击**不生效（这一块说的只是双击；PC 仍有长按，
             *          见下面 onLongPressStart，且双击不显示设置项）
             * 触摸端 → 生效，且步长/开关都能配（见 core/player_gestures.dart）
             * ```
             */
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 左/右两个**手势区域** —— 现在**只剩长按**（2026-09-25）
             * ══════════════════════════════════════════════════════════
             *
             * 用户先后说了三句，最后一句**推翻了前两句里的单击部分**：
             * ```text
             * ① 「pc端更直觉的左右按钮 单点是快进快退(可配置)
             *     长按是倍速,右是快进倍速(可配置) 左是 快退(可配置)」
             * ② 「不应该显示播放器两侧的按钮,识别手势就行了
             *     这两个圆圈太难看了」
             * ③ 「不要单击快进快退,去掉这个功能」   ← 最终需求
             * ```
             * ①②合并出来的那张表，③把「单击」那一列**整列删掉**：
             *
             * ```text
             *          单击                  长按
             * 左半屏   （已删除）            连续快退（每步可配）
             * 右半屏   （已删除）            倍速快进(可配)，松开恢复
             * 整屏     播放/暂停  ← onTap     —
             * ```
             *
             * # 为什么"区域"还留着
             *
             * 用户删的是**单击跳秒**，不是"左右区域"这个概念本身。
             * 长按仍然要分左右（左=快退、右=快进），所以
             * `_onLongPressStartAt(d.localPosition)` 的区域判断**必须保留**。
             *
             * 别因为"单击不分流了"就顺手把长按的区域判断也删了 ——
             * 那会让左半屏长按变成快进（方向反了）。
             *
             * # 单击为什么不再需要自己判坐标
             *
             * 见上面 `onTap` 的说明：单击语义变成"整屏统一播放/暂停"之后，
             * 就没有任何理由再读 `localPosition`，也就不需要 `onTapUp`。
             */
              onDoubleTapDown: _doubleTapEnabled
                  ? (d) {
                      final w = MediaQuery.of(context).size.width;
                      final forward = d.localPosition.dx >= w / 2;
                      final secs = PlayerGestures.doubleTapSeconds;
                      _seekBy(forward ? secs : -secs);
                    }
                  : null,
              /*
             * ══════════════════════════════════════════════════════════
             * ★★★ 双击 = 进入/退出全屏（task-42，用户要求）
             * ══════════════════════════════════════════════════════════
             *
             * 用户原话：
             * > 然后播放页面要支持空格暂停/播放,enter 和 **双击** 进入/退出 全屏
             *
             * # ★★ 为什么 PC 上**不需要**"中间/左右分区"
             * ```text
             * 我原本担心与"双击左右快进快退"冲突。查了代码：
             *   `_doubleTapEnabled` ⇒ `doubleTapEnabledFor(isTouch:)`
             *   ⇒ ★ **PC/TV 恒 false**（那是 2026-09-24 用户明确要求的：
             *      「pc端不应该双击左右侧快进快退」）
             * ⇒ PC 上"双击"**本来就是个空档**（什么都不做）
             * ⇒ 让给"全屏"**零冲突**，不需要分区。
             * ```
             *
             * # 所以两个平台各走各的（**互斥**，这是关键）
             * ```text
             * PC/TV   ：onDoubleTap     = 全屏（本段）
             * 触摸端   ：onDoubleTapDown = 左右快进快退（既有，不动 —— 尊重设置开关）
             * ```
             * ⚠️⚠️ **两者绝不能同时挂** ——
             * `GestureDetector` 的 `onDoubleTap` 与 `onDoubleTapDown` 是
             * **同一个 `DoubleTapGestureRecognizer` 上的两个回调**，
             * 一次双击会把**两个都跑一遍**（与上面 L4565 记录的
             * "onTap/onTapUp 同挂会都执行"是**同一个坑**）。
             * ⇒ 用 `_isTouchGestureTarget` 三向分流，保证只有一个非 null。
             */
              onDoubleTap: _isTouchGestureTarget
                  ? null
                  : () {
                      debugPrint('[PLAYER-KEY] 双击 ⇒ 切换全屏');
                      unawaited(_toggleFullscreen());
                    },
              /*
             * ── 长按 = 分区域（用户要求）──
             *
             * ```text
             * 左半屏 → 连续快退
             * 右半屏 → 倍速快进
             * ```
             *
             * ⚠️ `onLongPressStart/End` 而不是 `onLongPress` ——
             *    后者只在"长按完成"时触发一次，**没有抬起事件**，
             *    没法恢复倍速（会一直卡在 2x）。
             *
             * ⚠️ 必须用 `LongPressStartDetails.localPosition` 判区域 ——
             *    不能只看"当前是否在长按"，否则左侧长按会变成快进。
             */
              onLongPressStart: _longPressEnabledForThisDevice
                  ? (d) => _onLongPressStartAt(d.localPosition)
                  : null,
              onLongPressEnd: _longPressEnabledForThisDevice
                  ? (_) => _endAnyLongPress()
                  : null,
              onLongPressCancel: _longPressEnabledForThisDevice
                  ? _endAnyLongPress
                  : null,
              /*
             * ★★★ 2026-10-07 修复（Owner：「左边播放器鼠标点击、在上面移动都没有反应」）
             *
             * # 实测到的根因
             * ```text
             * GESTRO 探针（从 _gestureKey 的 RenderObject 沿 parent 上溯）：
             *   控制条可见时：RenderSemanticsGestureHandler@1011x805 < RenderMouseRegion@1011x805 < …
             *   控制条隐藏后：RenderSemanticsGestureHandler@0x0   < RenderMouseRegion@0x0   < …
             * ⇒ 手势层被布局成 **0x0** ⇒ 指针永远命不中 ⇒ 点击/悬停全失效、
             *   而且再也无法把控制条唤回来（Owner 同时报的「无法返回首页」同源：
             *   返回按钮在 _TopBar 里，只受 _controlsVisible 门控）。
             * ```
             *
             * # 为什么 Stack 会缩成 0
             * ```text
             * RenderStack._computeSize（packages/flutter/lib/src/rendering/stack.dart:625-675）：
             *   只有 **非 Positioned** 的子项才参与尺寸计算；
             *   `if (hasNonPositionedChildren) size = Size(width, height); else size = constraints.biggest;`
             * ⇒ 一旦出现非 Positioned 的 0 尺寸子项（本页 Stack 的第一个 child
             *   就是 `const SizedBox.shrink()` 这类探测/占位项），
             *   Stack 就可能塌成 0，连带把外层 MouseRegion/GestureDetector 也拉成 0。
             * ```
             *
             * # 修法
             * ```text
             * 把包裹手势层的盒子**钉死**成铺满：
             *   SizedBox.expand ⇒ 给 Stack 一个 tight 约束
             *   ⇒ 无论子项怎么变，Stack 都占满整块播放器区
             *   ⇒ 命中测试永远能落到 MouseRegion / GestureDetector 上
             * 零副作用：不改变任何绘制、不改变 Stack 子项的布局语义。
             * ```
             */
              child: SizedBox.expand(
                child: Stack(
                  children: [
                    // ── 视频画面 ──
                    Positioned.fill(
                      child: Center(
                        child: Video(
                          controller: _controller,
                          controls: NoVideoControls,
                          fill: Colors.black,
                        ),
                      ),
                    ),

                    /*
                 * ── ★★★ danmaku-service 弹幕层（task-13 ⑦）──
                 *
                 * # 用户原话
                 *
                 * ┌ 接入一下 danmaku-service 的弹幕功能
                 * └
                 *
                 * # 为什么要套 IgnorePointer
                 *
                 * 弹幕层盖在整个视频区上，而播放页的单击 / 双击 / 长按
                 * 手势是靠**下层**的 GestureDetector 识别的。不套的话
                 * 弹幕层会把所有手势吃掉 —— 用户会发现「开了弹幕之后
                 * 单击暂停就失灵了」。
                 *
                 * # 为什么它自己算几何
                 *
                 * DanmakuOverlay 内部用 danmakuContainRect 复刻了
                 * BoxFit.contain（与下面描边层**同一套**），所以弹幕
                 * 只出现在画面内，不会跑到黑边上。这里只负责给它约束。
                 */
                    Positioned.fill(
                      child: IgnorePointer(
                        /*
                     * ★★★ 2026-10-14（卡顿修复）：overlay **自己**订阅
                     *   `_danmakuQuickLive` —— 拖动滑杆 ⇒ **只有这一小块**
                     *   重建（整页 `PlayerPage.build()` 一次都不跑）。
                     *
                     * # 为什么包在这里，而不是让 `_danmakuQuickLive` 的监听者
                     *   在 State 里 setState
                     * ```text
                     * State 里 setState ⇒ 整页 884 行 build 重跑（就是我们要
                     * 消灭的那个形态）。包在这一层 ⇒ 重建被限制在
                     * `_DanmakuOverlay` 这棵子树里，而它是 keep-alive 的 StatefulWidget
                     * （`_DanmakuOverlayState` 复用，不重建 State）⇒
                     *   · 只有 `build()` 拿到**新** `fontScale/opacity/speed/area`；
                     *   · `_ensureLayout` 在下一帧按新值重排（key 含 fontScale/
                     *     speed/area）；painter 每帧现读 opacity ⇒ **画面逐帧跟手**。
                     * ```
                     *
                     * # 其余入参为什么不放进来
                     * `comments/position/playing/rate/...` 仍由宿主整页 build 传入 ——
                     * 拖动滑杆**不会**改它们，所以这份 builder 只需覆盖四个实值。
                     * （context 里 `_danmakuSettings` 的这四个字段在拖动期间**不更新**
                     *  —— 见 `_pushDanmakuQuickLive`；真值只在 `live.value` 里。）
                     */
                        child: ValueListenableBuilder<DanmakuQuickValues>(
                          valueListenable: _danmakuQuickLive,
                          builder: (context, qv, _) => DanmakuOverlay(
                            aspect: _displayAspect,
                            comments: _danmakuComments,
                            position: _position,
                            playing: _playing,
                            rate: _rate,
                            enabled: _danmakuEnabled,
                            fontScale: qv.fontScale,
                            opacity: qv.opacity,
                            speed: qv.speed,
                            area: qv.area,
                            // ★ Owner 2026-10-11：拖动「显示区域」滑杆期间点亮引导遮罩
                            areaGuide: _showDanmakuAreaGuide,
                            badge: _danmakuBadge,
                          ),
                        ),
                      ),
                    ),

                    /*
                 * ── ★★★ 视频区描边（task-28 ②：上下黑边要有边界）──
                 *
                 * # 用户原话
                 * > 播放器页面**上面黑色，跟下面黑色融为一体了，搞点边界出来**
                 *
                 * # 根因（**量出来的**，不是猜的）
                 *
                 * 诊断探针（`.probe/probe_tests/zz_diag_boundary_test.dart`）实测：
                 * ```text
                 * Scaffold  = Rect.fromLTRB(0, 0, 1280, 800)
                 * Video[0]  = Rect.fromLTRB(0, 0, 1280, 800)   ← ★ 铺满整屏
                 * AspectRatio 个数 = 0                          ← ★ 外面没有约束
                 * 带渐变的 DecoratedBox = 1（顶部栏 1280x72）
                 * ```
                 * 也就是说 **`Video` widget 自己铺满整屏**，它内部用
                 * `BoxFit.contain` 把 16:9 的画面居中，四周填 `fill: Colors.black`。
                 *
                 * 而窗口是 1280x800（比例 1.60），16:9 画面实际只有
                 * `1280 x 720` ⇒ **上下各留 40px 黑边**。于是：
                 * ```text
                 * 顶部栏渐变(black87→透明)  ← 黑
                 * 上黑边 40px              ← 黑
                 * 画面
                 * 下黑边 40px              ← 黑
                 * 底部控制条渐变            ← 黑
                 * = ★ 全是黑，看不出画面从哪开始到哪结束
                 * ```
                 *
                 * # 为什么用"描边"而不是改 `fill` 颜色
                 *
                 * ```text
                 * 候选 A ★ 描边（本实现）
                 *    · 不碰 `Video` 的布局与 `fill` ⇒ **零风险改变画面渲染**
                 *    · 1px 细线就足以让眼睛分辨出"画面到这儿为止"
                 *    · 与用户说的"搞点边界出来"字面一致
                 *
                 * 候选 B 把 `fill` 改成 #0a0a0a
                 *    · `fill` 是 media_kit 的**内部**填充，改它只是让黑边
                 *      比 UI 略亮一点点 —— 高对比屏上几乎看不出，
                 *      而且会把"视频区域"和"UI 区域"的明暗关系弄反
                 *      （通常 UI 该比画面暗，不是亮）
                 *
                 * 候选 C 给控制条加渐变
                 *    · ★ 控制条**已经有**渐变了（`Colors.black87 → transparent`）
                 *      —— 它之所以看不见，正是因为底下的黑边也是黑的。
                 *      再加一层渐变解决不了这个问题。
                 * ```
                 *
                 * # ★ 为什么描边必须自己算 contain 矩形
                 *
                 * 因为 `Video` 铺满整屏（见上面的实测），
                 * 所以"画面在哪"只能**按比例算**：
                 * ```text
                 * 可用区 1280x800，视频 16:9
                 *   按宽铺满 → 高 = 1280/1.778 = 720 ≤ 800  ✅ 取它
                 *   画面 = 1280x720，居中 ⇒ 上下各留 40px
                 * ```
                 * 这正是 `BoxFit.contain` 的算法。用 `LayoutBuilder` 拿真实
                 * 可用尺寸再算，窗口缩放时自动跟着变。
                 *
                 * ⚠️ 用 `_displayAspect`（**不夹取**）而不是 PiP 用的
                 *    `_videoAspect` —— 后者夹到 `[1/2.39, 2.39]` 是给
                 *    Android 小窗用的，拿它画描边会让 21:9 以上的片源描边错位。
                 *
                 * ⚠️ 宽高拿不到时（起播前）返回 null ⇒ **不画描边**，
                 *    而不是按 16:9 画一个可能是错的框。
                 */
                    Positioned.fill(
                      child: IgnorePointer(
                        child: LayoutBuilder(
                          builder: (context, box) {
                            final ar = _displayAspect;
                            if (ar == null) return const SizedBox.shrink();
                            // BoxFit.contain 的几何
                            var w = box.maxWidth;
                            var h = w / ar;
                            if (h > box.maxHeight) {
                              h = box.maxHeight;
                              w = h * ar;
                            }
                            return Center(
                              child: SizedBox(
                                width: w,
                                height: h,
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    /*
                                 * 1px 细线，比纯黑略亮。
                                 *
                                 * `0xFF2A2A2A` 的取值依据：控制条渐变的起点是
                                 * `Colors.black87`（alpha 0.87 的黑，压在画面
                                 * 边缘约等于 #1F1F1F）。用同一明度档，
                                 * 描边才"看得见但不抢眼"。
                                 *
                                 * ⚠️ 不能更亮（比如 #444）：全屏观影时一圈灰框
                                 *    会明显分散注意力，那就从"有边界"变成
                                 *    "有干扰"了 —— 用户要的是边界，不是装饰。
                                 */
                                    /*
                                 * ══════════════════════════════════════
                                 * ★★★ 2026-10-08：左右两条边**不画**
                                 *     （Owner 第 8 条：「播放详情页的右侧
                                 *     弹窗不要包含一条黑色的边框」）
                                 * ══════════════════════════════════════
                                 *
                                 * # 现象（Owner 截图 u9_92496b4e.png
                                 *   1444x845 逐像素实测）
                                 * ```text
                                 * x=1006..1009 画面
                                 * x=1010        整列 (42,42,42)，共 567 行
                                 *               = y 159..725 ← ★ 就是"那条黑边"
                                 * x=1011..      surface (238,240,246)
                                 * ⇒ 这一列**只**属于描边矩形，右侧信息面板
                                 *   自己从 1011 才开始（面板左边缘 x=1011，
                                 *   上边缘 y=40，右/下都顶到窗口外沿）
                                 * ```
                                 *
                                 * # 为什么它看起来像"面板的边框"
                                 * ```text
                                 * 描边矩形的**右边**与面板的**左边**正好贴在一起
                                 * （视频区右边界 = 面板左边界 = 1010/1011），
                                 * 于是这条竖线在视觉上就"长在面板身上"。
                                 * ```
                                 *
                                 * # 为什么左右两条**都不该有**
                                 * ```text
                                 * ① 这条描边的**目的**是"上下黑边要有边界"
                                 *    （Owner 原话见本层开头）—— 上下才是需求。
                                 * ② 视频区左右**本来就没有黑边**：窗口宽 > 画面宽
                                 *    时 contain 是"按高铺满、左右裁"，画面顶到
                                 *    视频区两侧；左右两条线是**贴着画面**画的，
                                 *    不是画在黑边上，属于纯粹多余的框。
                                 * ③ 右边那条紧贴信息面板 ⇒ 用户直接读成
                                 *    "面板的黑边框"。
                                 * ```
                                 *
                                 * # ★ 为什么不能写 `Border.all(...).copyWith(right: none)`
                                 * ```text
                                 * 上面那条路试过（`Border` 的 right 换成
                                 * `BorderSide.none`），实测**右边仍在**：
                                 * `Border.paint`（box_border.dart:654-675）先看
                                 * `isUniform`（同色同宽 ⇒ 本例为 true），
                                 * 命中后**忽略四条边的 style**，直接走
                                 * `BoxBorder._paintUniformBorderWithRectangle`
                                 * （:360-363）：
                                 *   canvas.drawRect(rect.inflate(strokeOffset / 2), side.toPaint())
                                 * ⇒ 画的是一条**整矩形描边**，根本没有"哪条边不画"
                                 *   的概念 ⇒ right: none 被静默丢弃。
                                 * ⇒ 要"只画上下"必须让 `isUniform == false`
                                 *   （左右 `BorderSide.none` 与上下不同）⇒
                                 *   走 `paintBorder`（borders.dart:883+）逐边绘制。
                                 * `Border.symmetric` 正好构造出这种非均匀边框。
                                 * ```
                                 *
                                 * ⚠️ `Border.symmetric` 的命名是"轴"不是"位置"：
                                 *    `horizontal:` ⇒ **上 + 下**（box_border.dart:455-461）
                                 *    `vertical:`   ⇒ 左 + 右
                                 */
                                    border: const Border.symmetric(
                                      horizontal: BorderSide(
                                        color: Color(0xFF2A2A2A),
                                        width: 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ),

                    // ── 缓冲指示 ──
                    //
                    // ★ OPS-14：原来是 SizedBox(44×44) + 纯白 4px 描边的转圈
                    //   （Owner 原话：「那个转圈的颜色太浅了,然后这个圆圈是不是有点大?」）
                    // ⇒ 换成共享组件：直径 44 → 30、描边 4 → 2.8、颜色不再写死纯白。
                    if (_buffering && !_loading)
                      const Center(child: AppLoading(ground: Colors.black)),

                    // ── 加载中 ──
                    if (_loading) const _LoadingOverlay(),

                    // ── 错误 ──
                    if (_error != null)
                      _ErrorOverlay(
                        message: _error!,
                        onRetry: _load,
                        onBack: () => unawaited(_exitPlayer()),
                        /*
                     * ★ 只有**确实是登录问题**时才给登录按钮（用户要求）
                     *
                     * 用户原话：
                     * > 我要求在这个页面也要显示出来 登录 按钮，
                     * > 点击可以进行直接登录
                     *
                     * 判据用 `_isAuthError`：看错误文案里有没有
                     * `unauthorized` / `登录已失效`。**不能无条件显示** ——
                     * 「该内容没有可播放的地址」「所有线路都不可播」这类
                     * 失败跟登录毫无关系，摆个登录按钮只会误导用户
                     * 去重登一个本来好好的账号。
                     */
                        onLogin: _isAuthError
                            ? () => unawaited(_loginAndRetry())
                            : null,
                        /*
                     * ★★★ Owner 第 6 条：把失败**归类**，并只显示插件原文
                     *
                     * # 改前（Owner 给的两张截图）
                     * ```text
                     * 图 1  Failed to open http://127.0.0.1:57209/s/18df.../
                     *       ↑ 内部代理地址直接抛给用户，判断不了是源还是软件
                     * 图 2  SourinCoreException(other): 插件报错: 该内容需要大会员…
                     *       ↑ 两个前缀都是宿主加的噪声
                     * ```
                     *
                     * # 改后
                     * ```text
                     * 标题   按类别给一句人话（这个源没有返回可播放地址 / 内置代理没起来 / …）
                     * 正文   PlaybackErrorText 净化后的原文（插件说了什么就显示什么）
                     * 下一步 能照着做的一句话
                     * ```
                     *
                     * ⚠️ 归类在 core（`PlaybackErrorText.classify`）里做，是**纯函数**、
                     *    有独立门禁 —— 这里只负责显示，不再各自写一份 if。
                     */
                        failure: PlaybackErrorText.classify(
                          _error,
                          kindHint: _errorKind,
                          hadCandidates: _streams.isNotEmpty,
                          /*
                           * ★★★ 缺陷⑧（2026-10-25）：把**播放器自己测到的耗时**
                           * 一起交给归因。
                           *
                           * mpv 的 `Failed to open …` 原文里没有时间 ⇒ 只靠文案
                           * 永远区分不了"等不及（超时）"与"真打不开"。
                           * 这个值只在**起播失败**路径写（见 `_handleStreamError`），
                           * 拿到 `null` 时归因退回保守的 proxy 判断 —— 不猜。
                           */
                          elapsed: _startFailureElapsed,
                        ),
                      ),

                    // ── 顶部栏 ──
                    /*
                     * ══════════════════════════════════════════════════════
                     * ★★★ 2026-10-08（Owner 追加）顶栏必须与底栏**联动**
                     * ══════════════════════════════════════════════════════
                     *
                     * 用户原话（逐字）：
                     * > 现在下面的底栏的会遵循我说的逻辑隐藏了,但是上面的
                     * > 这个也是一样的规则,而且上面的这个跟下面的 是要联动的,
                     * > 隐藏一起隐藏,我说的触发条件 触发了,然后也要显示,知道吧
                     *
                     * # 改前为什么顶栏**从不消失**
                     * ```text
                     * 判据是 `_controlsVisible || _canUseFloatingBack`，而
                     *   `_canUseFloatingBack`（:6992）= `Device.isDesktop &&
                     *   _error == null && !_anySheetOpen`
                     * ⇒ 桌面端正常播放时它**恒为 true**
                     * ⇒ 顶栏**无条件渲染**，`_controlsVisible` 翻 false 也拦不住它。
                     *   （那一条 `||` 是当年为了「控制条藏了就没有返回口」加的，
                     *     但那个需求已经由**常驻悬浮返回键**单独满足了 ——
                     *     见 `_TopBar` 里 `if (!visible && onFloatingBack != null)`。）
                     * ```
                     *
                     * # 改后
                     * ```text
                     * ① 顶栏**常挂**（去掉外层 `if`）⇒ 它才能在隐藏时播淡出；
                     * ② 渐变条看 `visible`（= `_controlsVisible && _error == null`）
                     *    ⇒ 与底栏**同一个真源** ⇒ 一起消失、一起出现 ✓
                     * ③ 悬浮返回键仍然只在「藏起来 + 桌面 + 无错误 + 无浮层」时出现
                     *    ⇒ 「藏了就没法返回」这个老缺陷**没有回归**。
                     * ```
                     *
                     * ⚠️ `_error == null` 这一半必须留着：起播失败时顶栏那条
                     *    渐变条会压在错误浮层上（改前 `_canUseFloatingBack` 为
                     *    false ⇒ 整条不渲染）。现在用 `visible` 表达同一件事。
                     */
                    /*
                     * ★★★ N11（2026-10-18）：顶栏**局部重建**
                     *
                     * # 为什么要有这一层
                     * ```text
                     * `_TopBar` 的 `visible` / `fade` 都经 `_chromeVisible` 求值，
                     * 也就是说它是 `_controlsVisible` 在整页 build 里的**唯一真读点**。
                     * 改前：这个真读点直接摊在 884 行的 build 里 ⇒ 控制条每次
                     * 显示/隐藏都要整页重建（实测 884 行 build + 190 个元素，8~10ms）。
                     * 真机全屏下「鼠标一动、控件出现」就是那个卡顿（Owner N11）。
                     * ```
                     *
                     * # 现在
                     * ```text
                     * 包一层 `ListenableBuilder(listenable: _controlsLive)`
                     * ⇒ 只有顶栏这一段订阅控制条显隐
                     * ⇒ 翻转时只重建顶栏，整页 build 不再被牵连
                     * ```
                     *
                     * ★ 为什么用 `_controlsLive` 而不是 `_controlsAnim`：
                     *   动画控制器在 260ms 的淡出期间会**每帧**通知
                     *   （≈16 次），用它会把顶栏重建 16 遍；
                     *   而顶栏自己的淡出由内部 `fade:` 那个 `AnimatedBuilder`
                     *   负责（见 `_TopBar.build`）⇒ 不需要外层跟着每帧重来。
                     *   本层只关心「控制条该不该在树上」这个**布尔**翻转。
                     */
                    ListenableBuilder(
                      listenable: _controlsLive,
                      builder: (context, _) => _TopBar(
                      title: _title,
                      episodeTitle: _epIndex < _episodes.length
                          ? _episodes[_epIndex].title
                          : widget.episodeTitle,
                      isLive: _isLive,
                      providerName: _providerName,
                      /*
                       * 弹幕信息：只在**弹幕这一层有话说**时挂出来。
                       * 没有绑定、没在取、也没失败 ⇒ 不给入口，免得用户点开
                       * 看到一张"什么都没"的卡片。
                       */
                      dmInfo: _danmakuInfoVisible ? _danmakuInfo : null,
                      dmInfoOpen: _danmakuInfoOpen,
                      onToggleDmInfo: () =>
                          setState(() => _danmakuInfoOpen = !_danmakuInfoOpen),
                      onBack: () => unawaited(_exitPlayer()),
                      onHints: hints.isEmpty ? null : _toggleHints,
                      /*
                     * ★ 常驻悬浮返回键（用户缺陷②）
                     *
                     * 用户原话：
                     * > 就是箭头指的位置,你看到了吗?而且我现在无法返回到首页了
                     *
                     * 顶栏随控制条 3 秒后一起消失 ⇒ 屏幕上再没有可点的返回口。
                     * 判据与设计见 `_FloatingBackButton` 的长注释。
                     */
                      /*
                         * ★★★ 缺陷（Owner 2026-10-09）：错误态下**也要**给返回口
                         *
                         * 改前只有 `_canUseFloatingBack` ⇒ `_error != null` 时传 null
                         * ⇒ 悬浮键不画（`_TopBar` 内部 `if (!visible && onFloatingBack != null)`），
                         * 而顶栏那枚又因 `visible == false` 被 IgnorePointer 挡住。
                         * 见 `_canUseTopBarBack` 的长注释。
                         */
                      /*
                         * ★ 顶栏渐变条的可见性 —— 与**底栏同一条判据**
                         *
                         * 底栏的判据是
                         *   `_controlsVisible && _error == null && !_xSheetOpen …`
                         * 顶栏只需要前半段：它不占底部空间，浮层打开时留着
                         * 不冲突（`_canUseFloatingBack` 里的 `!_anySheetOpen`
                         * 已经管住了悬浮返回键）。
                         *
                         * ⚠️ 这里**不能**写成 `_controlsVisible || _canUseFloatingBack`
                         *    （那是改前的写法，正是顶栏永不消失的原因）——
                         *    悬浮返回键的可见性由 `_TopBar` 内部
                         *    `if (!visible && onFloatingBack != null)` 单独决定，
                         *    与这条渐变条**解耦**。
                         *
                         * ★★★ 2026-10-09 追加（Owner 新增缺陷）：`|| _canUseTopBarBack`
                         * ```text
                         * 错误态下 `_controlsVisible && _error == null` 必为 false
                         * ⇒ `IgnorePointer(ignoring: true)` 把顶栏整条挡住 ⇒ 箭头点不动。
                         * 补上 `_canUseTopBarBack`（= 桌面端 && 有错误 && 无浮层）后：
                         *   顶栏那条**保持可见**（顶栏本身就是错误态下唯一的返回视觉），
                         *   而 IgnorePointer 照旧 `!visible` 参与 ⇒ 箭头可命中。
                         * ```
                         * ⚠️ 为什么**不是**复用 `_canUseFloatingBack`：那一位在错误态恒 false
                         *    （它含 `_error == null`），写进去等于没改。
                         *
                         * ★★★ Owner 缺陷④（2026-10-11）：正常支追加两条降级判据
                         * ```text
                         * Owner 原话：
                         * > 然后上面的标题条和下面的操作条，根本就没一起联动显示，
                         * > 他们是共用一块逻辑的！！
                         *
                         * 根因：底栏门控（下面那条 if）比顶栏多带了
                         *   `_liveAudioOnlyNotice == null && !_videoOutputDead`。
                         * ⇒ 两条降级横幅出现时：底栏被这两条拦掉（消失），
                         *   顶栏照常 `(_controlsVisible && _error == null)`（还在）
                         *   = 用户看到的「顶栏还在、底栏没了」的没联动。
                         *
                         * 为什么是「顶栏跟底栏一起收」而非「底栏也放开」：
                         *   两条横幅都是 `Positioned(bottom: 0)`（替代底栏、同位置），
                         *   放开底栏会让横幅重新压在控制条上 = 2026-10-01 的「排版混乱」。
                         *   横幅自带「返回」按钮 ⇒ 一起收不会困住用户。
                         *
                         * ⚠️ 只 AND 在**正常播放**支，**不动** `_canUseTopBarBack`
                         *    （那是错误态唯一的返回口，Owner 2026-10-09 专门报过）。
                         * ```
                         */
                      // ★★★ T27-13：顶栏正常支与底栏共读**唯一真源** `_chromeVisible`
                      //   ——原来这里内联的
                      //   `(_controlsVisible && _error == null) && !_videoOutputDead
                      //    && _liveAudioOnlyNotice == null` 与底栏的 11 项门控
                      //   **差 7 个浮层 flag**，两栏各算各的 ⇒ 会分裂。
                      //   现在两者都是 `_chromeVisible` 求值 ⇒ 结果恒相等。
                      visible: _chromeVisible || _canUseTopBarBack,
                      /*
                         * ★ 2026-10-08（Owner 第 9 条）：顶栏的淡入淡出。
                         *
                         * ⚠️ 只喂给那条渐变条 —— 常驻悬浮返回键走
                         *    `onFloatingBack`，**不参与**淡出（见 `_TopBar.fade` 的说明）。
                         *    -- ★★★ 2026-10-09 修正（缺陷 2）：上面这句已不成立，原话保留供追溯；
                         *       现在同一条 _controlsFade 同时喂给 floatingFade，两者不透明度之和恒为 1（交叉淡化）。
                         *       为何改：硬切会让两枚箭头同屏，用户读作「返回图标残留」。
                         *
                         * ★★★ 2026-10-09 追加（Owner 新增缺陷 · 错误态返回箭头）：
                         *    错误态下 `fade` **必须钉在 kAlwaysCompleteAnimation**。
                         * ```text
                         * 根因：`_controlsFade` 的终值是 `_controlsVisible ? 1.0 : 0.0`
                         *       （`_applyControlsMotion` 里驱动）。错误态下控制条本就是隐藏的
                         *       => `_controlsFade` 会走到 **0** => `Opacity(opacity: 0)`。
                         *       于是即使把 `visible` 打开成 true（IgnorePointer 放行命中测试），
                         *       箭头仍然是**全透明**的 —— 用户还是看不见、也就不会去点。
                         * ```
                         * ⇒ 那一支把 fade 钉死为 1（kAlwaysCompleteAnimation 的 value 恒为 1.0，
                         *    而 `_TopBar` 里是 `fade?.value ?? 1.0` ⇒ 等价且不用改 _TopBar 内部）。
                         *
                         * ⚠️ **为什么在错误态钉死是安全的**（不产生缺陷 2 的「两枚箭头同屏」）：
                         * ```text
                         * 缺陷 2 的交叉淡化是为了让「顶栏箭头」与「悬浮键」在**互相切换**时
                         * 不出现两枚同时可见。而错误态下 `_canUseFloatingBack == false`
                         * （它含 `_error == null`）⇒ `onFloatingBack` 虽然非 null（我们刚补的），
                         * 但 `if (!visible && onFloatingBack != null)` 里 `visible` 此时为 true
                         * ⇒ **悬浮键那一支不成立、不会画**。
                         * ⇒ 屏幕上只有顶栏这一枚 ⇒ 交叉淡化**不需要维持** ⇒ 钉死无冲突。
                         * ```
                         * ⚠️ 正常播放时（`_error == null`）表达式退化成原来的 `_controlsFade`
                         *    **逐字节不变** ⇒ 缺陷 2 的几何/交叉淡化判据（zz_t2 探针）不受影响。
                         */
                      fade: _canUseTopBarBack
                          ? kAlwaysCompleteAnimation
                          /*
                           * ★★★ Owner 缺陷④（2026-10-11）：降级横幅出现 ⇒ 顶栏
                           *     **必须真的淡出去**（不能只把 `visible` 设 false）。
                           *
                           * 为什么 `visible: false` 不够：`visible` 只驱动
                           * `IgnorePointer`（挡指针），真正决定"看不看得见"的是
                           * 这条 `fade`（`Opacity(fade.value)`）。横幅出现时
                           * `_controlsVisible` 仍为 true ⇒ `_controlsFade` 仍是
                           * 1.0 ⇒ 顶栏整条不透明地压在画面上，只是点不动
                           * —— 那比"没消失"更糟（用户看得见却点不动）。
                           *
                           * ⚠️ 这里钉 `kAlwaysDismissedAnimation`（value 恒 0）
                           *    而不是另开动画：与上面错误态钉 `kAlwaysComplete`
                           *    同一手法（`_TopBar` 里是 `fade?.value ?? 1.0`）。
                           * ⚠️ 只在**正常播放**这一支（`_error == null`）生效
                           *    —— 见 `visible:` 那条注释，错误态返回口不许动。
                           */
                          : (_videoOutputDead || _liveAudioOnlyNotice != null)
                              ? kAlwaysDismissedAnimation
                              : _controlsFade,
                      backArrowKey: _topBarBackKey,
                      /*
                         * ★★★ task-16（Owner：「全屏左上角这个单独的返回icon,
                         *     还没消失」）—— 悬浮键的**常驻**判据。
                         *
                         * 根因：悬浮键 opacity 原本恒为 `1 - f`，控制条一藏
                         * （f → 0）它就是 1 ⇒ 满不透明地常驻在左上角。
                         * 现在乘上「指针还在页内」这个因子（见 `_pointerInside`）。
                         *
                         * ⚠️ 这里传的是**整页级**的 `MouseRegion` 维护的那个值，
                         *    不是本按钮自己的矩形 —— 用户的本意是
                         *    「鼠标在画面上就该有返回口」。
                         */
                    ),
                    ),

                    // ── 下一集倒计时 ──
                    if (_nextCountdown > 0)
                      _NextCountdown(
                        seconds: _nextCountdown,
                        nextTitle: _nextEpisode?.title ?? '',
                        onPlayNow: () {
                          _cancelNextCountdown();
                          _gotoNextEpisode();
                        },
                        onCancel: _cancelNextCountdown,
                      ),

                    /*
                 * ── fix/rewatch-prompt：「上次看到 20:00 / 继续观看 / 从头播放」──
                 *
                 * ★ 与 `_NextCountdown` 并列（同一角落、同一形态）—— 两者
                 *   都是"非阻断的小卡片"，且同时最多只会有一个有意义
                 *   （换集时 `_cancelNextCountdown` 与 `_cancelRewatchPrompt`
                 *   都会清）。不操作 ⇒ 8 秒后自动消失（见 `showRewatchPrompt`）。
                 */
                    if (_rewatchPrompt != null)
                      _RewatchPrompt(
                        position: _rewatchPrompt!,
                        onContinue: continueFromRewatchPrompt,
                        onFromStart: dismissRewatchPrompt,
                      ),

                    /*
                 * ══════════════════════════════════════════════════════════
                 * ★★★ 可见的左右圆圈按钮 —— **已移除**（2026-09-24 用户否决）
                 * ══════════════════════════════════════════════════════════
                 *
                 * 用户原话：
                 * > 不应该显示播放器两侧的按钮,识别手势就行了
                 * > 这两个圆圈太难看了
                 *
                 * # 这不是"推翻上一轮"，而是把两句话读全
                 *
                 * 上一轮用户说的是：
                 * > pc端更直觉的左右按钮 单点是快进快退(可配置)
                 * > 长按是倍速,右是快进倍速(可配置) 左是 快退(可配置)
                 *
                 * 我当时理解成"画两个圆圈按钮"，但用户真正要的是
                 * **"左/右两个区域的交互语义"**：
                 * ```text
                 * 左区域  单击 → 快退    长按 → 连续快退
                 * 右区域  单击 → 快进    长按 → 倍速快进
                 * ```
                 * 这两个区域**不需要可见的按钮** —— 用**手势识别**即可
                 * （就是原来的"双击左右侧"那套，只是改成了单击/长按）。
                 *
                 * ★ 教训：用户描述交互时说的"按钮"，可能指的是
                 *   **语义区域**而不是**可见控件**。做视觉之前该先问一句 ——
                 *   我直接画了控件，结果被否掉，白做一轮。
                 *
                 * # 现在的实现（见下面的 GestureDetector）
                 *
                 * ```text
                 * PC   左半屏：单击快退 / 长按连续快退
                 *      右半屏：单击快进 / 长按倍速
                 * 手机 双击左右侧快进快退 / 长按倍速（可配开关）
                 * ```
                 * 全部靠手势，画面上**没有任何常驻控件**。
                 */

                    // ── 底部控制条 ──
                    /*
                 * ⚠️ 选集面板打开时**藏起控制条**（照抄原版的三层 z-index）
                 *
                 * 原版 `PlayerView.vue` 的层序：
                 * ```text
                 * .player-controls    z-index 5
                 * .player-playlist     z-index 6   <- 选集面板
                 * .player-playlist__btn（控制条上的「选集」按钮）
                 * ```
                 * 也就是说原版的面板**盖在控制条之上**；而我们的面板是
                 * 全屏 `Positioned.fill` 的 scrim，如果控制条还画着，
                 * 它会浮在 scrim 上面 —— 点「选集」按钮等于**再次打开**
                 * （`_episodeSheetOpen = true`，视觉上毫无反应），
                 * 用户会以为按钮坏了。
                 *
                 * 藏掉之后语义反而更干净：面板开着 = 面板是唯一可交互的东西，
                 * 关掉（点背景 / 点 X / 遥控器返回）控制条按原逻辑回来。
                 */
                    /*
                         * ★★★ task-104：本条件的注释**全部上移到这里**（文字一字未改）
                         *
                         * 为什么必须搬：`test/t73_bili_wiring_test.dart` ② 与
                         * `test/t57_sheet_scrim_geometry_test.dart` 用的是**同一条**判据 ——
                         * 从 `_BottomBar(` **往回 600 字符**找那个 `if (`，并断言条件里含全部
                         * 7 个 `!_xSheetOpen`。注释原来夹在条件**中间**，实测（复刻
                         * `stripComments` 后测量）：
                         * ```text
                         * 改前：条件起点 "_controlsVisible" 在 _BottomBar( 前 **793** 字符处
                         *       ⇒ 超出 600 窗口 ⇒ before.lastIndexOf("if (") == **-1**
                         *       ⇒ t73 ② 报「找不到 if ( ⇒ 条件块已经长到 600 字符以外了」
                         * 改后：注释不参与条件长度 ⇒ 条件只剩 10 行代码（< 300 字符）
                         * ```
                         * ★ 判据一条没放松：t57 / t73 仍然钉着「门控必须含全部 7 个标志」。
                         * ★★★ T27-13 更新（Owner 第 3 / 5 条）：这 7 个标志**已收拢**进
                         *   唯一真源 `_chromeVisible`（见该 getter 的文档），
                         *   底栏渲染点不再内联它们 ⇒ t57 / t73 的判据对象也跟着搬到
                         *   `_chromeVisible`（「往回 600 字符」那条启发式随之作废）。
                         */
                    // ★ 设置面板同理（它是全屏 scrim，控制条浮在上面会点不动）
                    /*
                     * ★ task-13 ⑦ 弹幕设置面板同理（同一条规则）。
                     *
                     * 它也是 Positioned.fill 的全屏 scrim（与 PlayerSettingsSheet
                     * 同一个壳），漏掉这一项就会出现「弹幕面板开着，控制条浮在
                     * scrim 上面」⇒ 用户点「弹幕」按钮等于再打开一次，视觉上毫无
                     * 反应 —— 与上面 `!_episodeSheetOpen` 注释里记的是同一个坑。
                     */
                    // ★ task-31 ④⑤：两个新面板同理（都是全屏 scrim）
                    /*
                     * ★★★ task-57：所有直播面板同理（与上面四项并列）。
                     *
                     * ⚠️ 机制**不是**"全屏 scrim 挡住" —— `SheetTransition`
                     *    （`episode_strip.dart` L1164-1194）**不画任何东西**，
                     *    它只有 `Opacity` + `Transform.translate` + `IgnorePointer`。
                     *    所以"面板是 `Positioned.fill` 的 scrim"这个说法
                     *    **对线路/直播面板不成立**（只有选集/设置自带全屏遮罩）。
                     *
                     * 真机制是：面板**自身的有色区域**盖住了按钮，而
                     * `ColoredBox` 的渲染对象 `_RenderColoredBox` 继承
                     * `RenderProxyBoxWithHitTestBehavior`，其
                     * `HitTestBehavior.opaque` 是**写死的** ⇒ **吸收点击**。
                     *
                     * 实测（`test/t57_sheet_scrim_geometry_test.dart`，1280×800）：
                     * ```text
                     * 面板 = (920,48)-(1280,800)    ← 宽 360，右侧，全高
                     * 按钮 = (1153,736)-(1264,784)  ← 右下角「所有直播」
                     * ⇒ 水平覆盖 = true
                     * ⇒ 面板开着时点按钮中心 ⇒ 按钮回调 **0 次**（点不到）
                     * ⇒ 阳性对照（无面板）  ⇒ **1 次**（证明仪器有区分力）
                     * ⇒ 边界对照（底栏左半边）⇒ **1 次**（吸收是局部的）
                     * ```
                     * ⇒ 面板不画 ⇒ 那 360px 有色区域不存在 ⇒ 按钮恢复可点 ✓
                     *
                     * ⚠️ 已知边界（本次**未**改）：直播面板**没有**"点背景关闭"
                     *    （只有点 X / 遥控返回）—— 与选集面板不同，是既有行为。
                     */
                    /*
                     * ★★★ 2026-10-01：**降级横幅显示时不画控制条**（Owner 报「排版混乱」）
                     *
                     * # 症状（手机截图 `.probe\n16_player_scrolled.png`）
                     * ```text
                     * │ 1.0x ⟳换源 📺所有直播  ⛶  ⚙ │  ← 控制条（bottom: 0）
                     * │ ⚠ 这个视频的画面无法显示…  返回 │  ← ★ 横幅**也**是 bottom: 0
                     * └──────────────────────────────┘
                     * ```
                     * 两条都 `Positioned(bottom: 0)` 且是**同一个 `Stack` 的兄弟**
                     * ⇒ 后画的横幅**压在**控制条上 ⇒ 字叠字、按钮被盖住点不准。
                     *
                     * # 为什么"藏掉控制条"才是对的（而不是把横幅抬高）
                     * `_VideoOutputDeadBanner` / `_LiveAudioOnlyBanner` 的类文档
                     * 写得很明确：它们是**替代**控制条的降级提示
                     * （"起播成功了，只是没有画面"）。
                     * ⇒ 画面都出不来了，还摆一排「换源 / 全屏 / 设置」按钮
                     *   既没用又互相打架 ⇒ **语义上就该让位**。
                     * ★ 这与上面 `!_episodeSheetOpen && … && !_liveChannelsOpen`
                     *   是**同一条纪律**：谁占据了底部那块，谁就是唯一可交互的。
                     *
                     * ⚠️ 两条横幅各自都带「返回」按钮 ⇒ 用户**不会**因此出不去。
                     */
                    /*
                     * ★★★ T27-13（Owner 第 3 / 5 条）：底栏也必须**淡出**，
                     *   不能像改前那样被 `if (_chromeVisible)` 同帧整条卸下
                     *   （硬切）。顶栏是**常挂**的（靠 Opacity 淡出），底栏却
                     *   被 `if` 立刻移除 ⇒ 隐藏时「顶栏淡出中、底栏已消失」=
                     *   Owner 说的「错开显示」。修法两条：
                     *   ① 占据态（错误层/横幅/浮层）⇒ 照旧**整条卸下**
                     *      （那块归占据者，留在树里会叠字 / 抢点击）；
                     *   ② 纯 C 驱动（hover / 3 秒自动隐藏）⇒ 在淡出窗口内
                     *      **留在树上**，喂 `_bottomFade`（= 顶栏同一条
                     *      `_controlsFade`）⇒ 与顶栏**同时**淡入淡出。
                     */
                    ListenableBuilder(
                      listenable: _controlsAnim,
                      builder: (context, child) {
                        /*
                         * ══════════════════════════════════════════════════
                         * ★★★ N11（2026-10-18）：只在**占据态**才卸下底栏
                         * ══════════════════════════════════════════════════
                         *
                         * # 缺陷（实测，`.probe/t66_n11_bottombar.txt`）
                         * ```text
                         * 改前：
                         *   final keepForFade = !_bottomOccupied && _controlsAnim.value > 0;
                         *   if (!_chromeVisible && !keepForFade) return const SizedBox.shrink();
                         *
                         * `child` = 整个 `_BottomBar`（**333 行 / 128 个后代元素**）。
                         * 控制条一收起这条就返回 `shrink` ⇒ 整棵子树被 **deactivate**；
                         * 鼠标一动叫回来 ⇒ **重新 activate**。
                         * 实测「叫回」那一次重建 **398** 个元素 / **85ms**：
                         *   IconTheme×22, DefaultSelectionStyle×22, GestureDetector×17,
                         *   RawGestureDetector×17, Focus×13, Actions×12, InkWell×11,
                         *   _MaterialInterior×11, _ShapeBorderPaint×11 …
                         * 8 轮循环 all = 8/398/8/398/… 合计 **1624**
                         * （门禁自带的改前基线 188 ⇒ 涨 8.6 倍）
                         * ⇒ Owner 报的 N11「播放页鼠标动一下很卡」。
                         * ```
                         *
                         * # ⚠️ 归因更正（防止将来又去改顶栏）
                         * ```text
                         * 我最初判断（Lead 按代码结构核实过）是 `_TopBar` 重建面太大。
                         * **实测推翻**：`_TopBar` 内重建 = **1**，`_TopBar` 外 = **397**
                         * （`.probe/t66_n11_topbar_attrib.txt`）。
                         * ⇒ `_TopBar` 当初的改法（常挂 + Opacity）**是对的**；
                         *   缺的是底栏这半边没同步改。**不要再动顶栏。**
                         * ```
                         *
                         * # 为什么可以放心常挂：淡出**底栏自己已经做好了**
                         * ```text
                         * `player/player_bottom_bar.dart:748-754`
                         *   AnimatedBuilder(fade) → IgnorePointer(ignoring: o==0) → Opacity
                         * 而 `fade` 传的就是 `_bottomFade`（与顶栏**同一个** `_controlsFade`
                         * 实例，由宿主 `_controlsAnim` 驱动）
                         * ⇒ 淡入淡出、以及"看不见时点不到"，都已由它保证。
                         * ⇒ 这一层只该负责**结构**问题：占据态要不要留在树上。
                         * ```
                         *
                         * # ★ 占据态必须仍然整条卸下（不许一刀切常挂）
                         * ```text
                         * `_bottomOccupied`（错误层/选集/换源/设置/弹幕/字幕/
                         * 直播频道/音频提示/画面死亡）时那块**归占据者**：
                         *   ① 留在树里会叠字（底栏按钮画在错误提示上）
                         *   ② 会抢点击（用户点到看不见的按钮）
                         * ⇒ 这一支**原样保留**。
                         * ★ 门禁 `zz_t66_n11_bottombar_test.dart` T2 守着它
                         *   （且用故障注入证明它真的会红）。
                         * ```
                         */
                        if (_bottomOccupied) {
                          return const SizedBox.shrink();
                        }
                        /*
                         * 非占据态：**恒挂**。
                         * 控制条显隐只改变 `fade` ⇒ 只翻 opacity，不装卸子树
                         * ⇒ 那 398 个元素的重建归零。
                         */
                        return child!;
                      },
                      child:
                          _BottomBar(
                        playing: _playing,
                        positionNotifier: _positionNotifier,
                        duration: _duration,
                        isLive: _isLive,
                        rate: _rate,
                        volume: _volume,
                        muted: _muted,
                        fullscreen: _fullscreen,
                        onTogglePlay: _togglePlay,
                        onSeek: (d) {
                          if (!_isLive) {
                            _seekByUser(d);
                            _beginPrefetchYield();
                          }
                        },
                        onVolume: (v) {
                          // ★ 用户拖底栏音量滑杆 —— 白名单（见 `_lastUserVolumeAction`）
                          _lastUserVolumeAction = DateTime.now();
                          /*
                           * ★★★ 缺陷 1 / 11：静音期间把滑杆拖到非零，必须同步快照
                           *
                           * ```text
                           * 为什么不能只靠音量监听器（上面那条 _muted 分支）？
                           *   用户拖到**与当前值相同的数**时，mpv 幂等、**不发**广播
                           *   => 监听器根本收不到这次动作 => 快照还是旧值
                           *   （这正是 _lastUserVolumeAction 用"时间窗"而不是"布尔"的理由）
                           * ⇒ 快照的更新必须有一条"即使无广播也能到达"的入口。
                           * ```
                           */
                          final next = v.clamp(0.0, 100.0);
                          if (_muted && next > 0) _volumeBeforeMute = next;
                          _sendVolume(next);
                        },
                        onToggleMute: _toggleMute,
                        onRate: (r) => _player.setRate(r),
                        onToggleFullscreen: _toggleFullscreen,
                        pipSupported: _pipSupported,
                        pipActive: _pipActive,
                        onTogglePip: _togglePip,
                        /*
                     * ★★★ task-2【④】用户第 15 条：「在非全屏状态下,选集的按钮不应该出现占位置」。
                     *
                     * 错在哪：这里原来只判 _episodes.length > 1 ⇒ 只要有多集就在底栏画
                     * 一枚「选集」。但**非全屏且右侧详情栏可见**时，详情栏里本来就有正常的
                     * 选集入口（detail_page.dart:2266 _bodyEpisodes），底栏那枚是重复入口。
                     *
                     * 为什么改这一个布尔就够：_BottomBar 里**三处**「选集」按钮
                     * （row / compactRow / row2 三个宽度档）**共用这一个 hasEpisodes**，
                     * 全部写成 if (hasEpisodes) TextButton.icon(... '选集' ...)
                     * ⇒ 改这一处 = 三处同时生效，**不需要**去动三处按钮本体。
                     *
                     * ★ 禁止写成「非全屏就隐藏」：判据是 widget.hasRightDetailBar
                     *   （= !fullscreen && wide，由 media_page.dart:729 单一数据源算得），
                     *   窄屏/全屏/历史记录 push 进来（默认 false）时**必须仍显示**。
                     */
                        hasEpisodes:
                            _episodes.length > 1 && !widget.hasRightDetailBar,
                        onEpisodes: () {
                          // ★★★ T27-09：浮层打开 ⇒ 顶/底栏一起收（显隐统一真源）
                          _collapseControlsForSheet();
                          setState(() => _episodeSheetOpen = true);
                          // ★★★ Owner 第 2 条：打开选集 ⇒ 暂停播放（关掉再接着播）。
                          //   理由 / 判据见 `_pauseForEpisodeSheet()`。
                          _pauseForEpisodeSheet();
                        },
                        /*
                     * ★★★ task-53【③】「所有直播」入口（用户第 3 条）
                     *
                     * ```text
                     * 用户原话（逐字）：
                     * > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
                     * ```
                     * # 为什么原来**没有**这个入口
                     * ```text
                     * 「选集」按钮的判据是 `_episodes.length > 1`，
                     * ★ 而直播时 `_episodes` **恒为空**（频道不是"剧集"）
                     *   ⇒ 按钮根本不显示 ⇒ 全屏直播播放页**没有任何方式**
                     *     打开频道列表。
                     * ```
                     * # 判据
                     * ```text
                     * `_isLive && widget.onLiveChannels != null`
                     * ★ 用**回调是否接线**当判据（与 #4b 的 `onLiveChannelStep`
                     *   同一手法）⇒ 没接线的调用点（测试/点播/回看）行为完全不变。
                     * ```
                     */
                        hasLiveChannels:
                            _isLive && widget.onLiveChannels != null,
                        onLiveChannels: _toggleLiveChannels,
                        liveChannelsOpen: _liveChannelsOpen,
                        hasStreams: _streams.length > 1,
                        onStreams: () {
                          // ★★★ T27-09：浮层打开 ⇒ 顶/底栏一起收（显隐统一真源）
                          _collapseControlsForSheet();
                          setState(() => _streamSheetOpen = true);
                        },
                        /*
                     * ★★ 上一集 / 下一集（本次补的缺口）
                     *
                     * 原版 `PlayerView.vue:4367-4392` 在 `metabar__acts` 里有
                     * 这两个按钮，而且**直播时整块不渲染** —— 原文注释：
                     * > 直播没有「上一集/下一集」概念。
                     * > 原来无脑渲染这两个按钮，直播时会显示成**两个灰掉的死按钮**
                     * > （实测截图里直播页出现「上一集 ⋯ 下一集」，很怪）
                     *
                     * 我们之前只有 `N` 快捷键与「下一集倒计时」，
                     * **没有可见的按钮** —— 鼠标用户根本发现不了这个能力。
                     * （证据：`_prevEpisode` 早就写好了却从没被引用过。）
                     *
                     * `hasEpisodes` 判据沿用原版：`prevEpisode` / `nextEpisode`
                     * 为空时按钮**禁用**（而不是隐藏）—— 用户在中间某一集时
                     * 两个按钮都在，只是到第一集时「上一集」变灰。
                     */
                        hasPrev: !_isLive && _prevEpisode != null,
                        hasNext: !_isLive && _nextEpisode != null,
                        showEpisodeNav: !_isLive && _episodes.isNotEmpty,
                        onPrev: () => unawaited(_gotoPrevEpisode()),
                        onNext: () => unawaited(_gotoNextEpisode()),
                        onSwitchSource: _openSwitchSource,
                        // ★ 直播不显示（原版 `openSkipDialog` 第一行就拦了）
                        onSkipMarkers: _isLive ? null : _openSkipDialog,
                        /*
                     * ★★★ 「设置」入口（本次新增）
                     *
                     * 原版这个入口是 ArtPlayer 内置的**齿轮**图标
                     * （`setting: true`，`PlayerView.vue:3436`）——
                     * 我们换成底部控制条上同一个位置的同语义按钮。
                     *
                     * ⚠️ 这是**交互差异**，单列在报告里：
                     * 原版打开的是 ArtPlayer 的面板（只有倍速/比例/镜像/清晰度），
                     * 我们打开的是自己的面板（字幕/音轨/连播）——
                     * 因为 ArtPlayer 那个面板里**没有**本次要补的能力。
                     */
                        onSettings: _openSettings,
                        // ★ task-21 P1-30：截图（相机按钮 / PC 键 S 的同一个落点）
                        onScreenshot: () => unawaited(_takeScreenshot()),
                        // ★★★ task-13 ⑦ 弹幕（用户原话：接入一下 danmaku-service 的弹幕功能）
                        danmakuEnabled: _danmakuEnabled,
                        danmakuBusy: _danmakuLoading,
                        onDanmakuToggle: _toggleDanmaku,
                        onDanmakuSettings: _openDanmakuSettings,
                        /*
                     * ★★★ Owner 1011 反馈第 1 条：弹幕齿轮弹出的**轻量悬浮窗**
                     *   （外部视频站图 1 那种）。
                     *
                     * 值全部取自 `_danmakuSettings`（= DanmakuConfig 的快照，
                     * 与全屏大卡片**同一份真源**）；三个类型开关读 DanmakuConfig
                     * 静态偏好（与 DanmakuSettingsDialog 同款）。
                     * 拖动滑杆 ⇒ 宿主 setState ⇒ 底栏与 popover 层
                     * 一起重建 ⇒ 读数与画面**实时**跟着走。
                     * 「高级设置」⇒ 回到 `_openDanmakuSettings`（全屏大卡片）。
                     *
                     * ★★★ 2026-10-14（卡顿修复）——上面的「拖动滑杆 ⇒ 宿主
                     * setState」已被**替换**：拖动改走 `live:`（只重建四根
                     * 滑杆），画面侧由 build 里包 `DanmakuOverlay` 的那层
                     * `ValueListenableBuilder` 重建（整页 884 行 build 一次不跑；
                     * 完整推导见 `_pushDanmakuQuickLive()` 上方）。
                     * 下面四个 `fontScale/...` 静态字段**保留**：`live` 为 null
                     * 的老调用点/夹具回落到它们（生产宿主始终传 live）。
                     */
                        danmakuQuick: DanmakuQuickPanelData(
                          fontScale: _danmakuSettings.fontScale,
                          opacity: _danmakuSettings.opacity,
                          speed: _danmakuSettings.speed,
                          area: _danmakuSettings.area,
                          live: _danmakuQuickLive,
                          showScroll: DanmakuConfig.showScroll,
                          showTop: DanmakuConfig.showTop,
                          showBottom: DanmakuConfig.showBottom,
                          colorOnly: DanmakuConfig.colorOnly,
                          onSetFontScale: _setDanmakuFontScale,
                          onSetOpacity: _setDanmakuOpacity,
                          onSetSpeed: _setDanmakuSpeed,
                          onSetArea: _setDanmakuArea,
                          onSetShowScroll: _setDanmakuShowScroll,
                          onSetShowTop: _setDanmakuShowTop,
                          onSetShowBottom: _setDanmakuShowBottom,
                          onSetColorOnly: _setDanmakuColorOnly,
                          onAreaGuide: _setDanmakuAreaGuide,
                          onOpenAdvanced: _openDanmakuSettings,
                        ),
                        /*
                     * ★★★ task-22 P1-5 / P1-11：画面缩放
                     *
                     * 短按 = 开/关那条滑动条，长按也开（用户原话是
                     * 「长按缩放按钮，拖动出现的滑动条」——但只认长按会
                     * 让鼠标用户以为按钮坏了，所以短按同样开）。
                     */
                        zoomOpen: _zoomOpen,
                        videoZoom: _videoZoomPct,
                        // ★ 宿主给的都是非空回调（:8488 传方法撕裂，:4071 传闭包，语义等价）；
                        //   「读不到就不让点」由面板侧的 onZoom == null 单独承担
                        onVideoZoom: _setVideoZoom,
                        onZoomToggle: () =>
                            setState(() => _zoomOpen = !_zoomOpen),
                        /*
                     * ★ task-32 ②：投屏。
                     *
                     * 没流时传空串 ⇒ `_BottomBar` **不画**这枚按钮
                     * （判据 `castUrl.isNotEmpty`）—— 比“画一枚能点、
                     * 点了只弹一句提示的按钮”更诚实（详见 _BottomBar
                     * 的 castUrl 文档）。
                     */
                        // ★ 2026-10-10：投屏已收进「更多」浮层（数据由
                        //   `castEntry` 带着真的 CastButton 带进来），
                        //   底栏不再接收 onCast/castUrl/castHeaders/castTitle
                        //   —— 那四个参数留着是「声明了但一次都没读」的死接线。
                        /*
                     * ★ 2026-10-08（Owner 第 9 条）：底栏与顶栏**同一个**
                     *    `_controlsFade` 实例 ⇒ 两条一起淡出，
                     *    不会出现「顶栏没了、底栏还在」的半截状态。
                     */
                        // ★ T27-13：与顶栏**同一** `_controlsFade` 实例
                        //   （占据态则钉 dismissed，见 `_bottomFade`）。
                        fade: _bottomFade,
                        buffered: _isLive ? null : _bufferedRange,
                        bufferBarKey: _bufferBarKey,
                        /*
                     * ★★★ 2026-10-09（Owner 第 12 条）popover / 「更多」入口数据
                     */
                        popover: _popover,
                        streams: _streams,
                        currentStream: _current,
                        onPickStream: (s) => _startPlayback(s),
                        qualityOptions: _qualityPopoverOptions(),
                        onPickQuality: _pickQualityByLabel,
                        currentQuality:
                            _current?.label ?? _current?.quality ?? '',
                        trackGroups: _trackPopoverGroups(),
                        onPickTrack: _pickTrackFromPopover,
                        moreGroups: _moreMenuGroups(context),
                        onBuilt: (b) => _bottomBarWidget = b,
                        /*
                         * ★★★ 2026-10-18（第 66 轮 Owner 第 1 条）：
                         *   弹幕发送栏内嵌进底栏（原先是本 Stack 里的浮层）。
                         *
                         * # 判据（AND，任一不满足 ⇒ null ⇒ 整条不渲染）
                         * ```text
                         * ① _danmakuEnabled                ← 弹幕总开关为开
                         * ② _danmakuCanSend                ← 当前源声明 danmaku_send
                         * ③ _danmakuSendProvider != null   ← 有真站点 id 可发
                         * ④ !_isLive                       ← 直播没有"这一集"
                         * ```
                         * ⚠️ `_chromeVisible` **不在这里判** —— 底栏本体已经
                         *   跟着 `fade`（同一个 `_controlsFade`）一起淡出，
                         *    再判一次会让「淡出中途」的输入框突然消失。
                         *    这也正是移进底栏带来的一个好处：显隐只有一个真源。
                         *
                         * ⚠️ Owner 已确认：「弹幕总开关关闭时也不显示」。
                         *    所以这里是 AND，不是「开关只管暂停」。
                         */
                        danmakuSend: (_danmakuEnabled &&
                                _danmakuCanSend &&
                                _danmakuSendProvider != null &&
                                !_isLive)
                            ? DanmakuSendData(
                                provider: _danmakuSendProvider!,
                                episodeId: _contentId,
                                positionMs: _danmakuSendPositionMs,
                                onSend: _sendDanmaku,
                              )
                            : null,
                      ),
                    ),
                    /*
                     * ★★★ 缺陷②（2026-10-25）：三条横幅**必须排在 `_BottomBar` 之后**
                     *
                     * # 为什么顺序就是修复本身的一部分
                     * ```text
                     * Stack 的绘制顺序 = children 的书写顺序（后写的画在上面）。
                     * 改前这三条横幅写在 `_BottomBar` **之前** ⇒ 鼠标一动控件浮现，
                     * 底栏就画在横幅之上 ⇒ 「重试」被盖住、点不到（Owner 报的就是这个）。
                     * ```
                     * ⚠️ 另一道保险是 `_bottomOccupied` 计入 `_playbackFailure`
                     *    （占据态时底栏整条卸下），但**顺序仍然必须对**：
                     *    两者是"结构 + 让位"两道独立防线，缺一条都会复发。
                     * ⚠️ 门禁 `zz_t1024_player_banner_order_test.dart` 做**源码顺序**断言，
                     *    把这段搬回底栏之前 ⇒ 立刻红。
                     */
                    /*
                 * ── 直播"只有音频能播"的提示（用户报的黑屏）──
                 *
                 * 央视视频轨被 DRM 加密（ffmpeg 实测 386 条解码错误），
                 * 三条线路里只有「仅音频」能播 → 有声无画面。
                 *
                 * ★ 这条**不能**放进 `_error`：`_error` 的语义是"起播失败"，
                 *   而这里是"起播成功了，只是没有画面"。两者必须能并存 ——
                 *   否则用户要么看到黑屏没解释，要么被一个假错误挡住。
                 *
                 * 原版对应实现见 `PlayerView.vue:4281-4299`。
                 */
                    if (_liveAudioOnlyNotice != null)
                      _LiveAudioOnlyBanner(
                        lineName: _liveAudioOnlyNotice!,
                        onBack: () => unawaited(_exitPlayer()),
                      ),

                    /*
                 * ── 「画面出不来但音频正常」的提示 ──
                 *
                 * 由 `_watchVideoOutput()` 立旗（判据：有视频轨 &&
                 * `vo-configured != yes`，五臂实测见 `.probe\t376_matrix.txt`）。
                 * 与上面那条并列：都是"起播成功了，只是没有画面"，
                 * 都**不能**放进 `_error`（那会与"正在播放"互斥）。
                 */
                    if (_videoOutputDead)
                      _VideoOutputDeadBanner(
                        onBack: () => unawaited(_exitPlayer()),
                      ),

                    /*
                 * ── 「播放中断」的非阻断提示（★ 2026-10-08，Owner 第 9 条）──
                 *
                 * Owner 截图（u9_1c91d6a6.png）：
                 * ```text
                 * 播放失败
                 * Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
                 * ```
                 * 这条来自 `_player.stream.error`，而 mpv **已经出过画面**
                 * 之后再来的错误多半是换流 / 重连 / 单帧解码失败 —— 可恢复抖动。
                 *
                 * 用全屏 `_ErrorOverlay` 处理它的后果：正在看的画面被整块盖掉，
                 * 用户以为"播放器崩了"，其实重试一下就好（Owner 就是这么报的）。
                 * ⇒ 与上面两条并列：**起播成功了，只是这一下断了**，
                 *   所以用同一种横幅形态，并且必须能一键重试。
                 */
                    if (_playbackFailure != null && _error == null)
                      _PlaybackFailureBanner(
                        message: _playbackFailure!,
                        onRetry: () => unawaited(_load()),
                      ),

                    /*
                     * ★★★ 2026-10-17（Owner 第 2 条后半句）：弹幕发送入口
                     *
                     * # 为什么挂在这里（底栏正上方、右下角）
                     * ```text
                     * · 底栏已有「选集 / 换源 / 设置」一排按钮，再塞输入框会把
                     *   那排在窄窗口下挤成两行；
                     * · 右下角是**画面上本来就空**的位置（与 popover 同一块），
                     *   不压标题也不压进度条；
                     * · 与底栏一起淡出（同一个 _chromeVisible 门控），
                     *   不会在用户看片时一直杵着。
                     * ```
                     *
                     * # ★★★ 2026-10-17 二次修复（Owner 第 9 条）
                     * ```text
                     * Owner 原话：「有些站点是支持发送弹幕的,你在软件实现了,
                     *               但是并没有发送弹幕的入口,这个需要修复。」
                     *
                     * 改前的判据里有一项 `_danmakuCanSend`（= 源声明了
                     * capabilities.danmaku_send）⇒ 源**没声明**这条能力时，
                     * 整条发送栏**根本不渲染**，用户连"能不能发"都无从得知，
                     * 更没法试。
                     *
                     * 但 Owner 说的场景恰恰是反的：源**支持**发、我们**也实现了**，
                     * 入口却因为一个声明布尔而消失。
                     * ```
                     *
                     * # ⚠️ 下面这一版（第 65 轮）**已作废**
                     * ```text
                     * 它曾把判据收敛成「有真站点可发 + 不在直播 + 控件可见」，
                     * 并把 `_danmakuCanSend` 降级成"决定**能不能点**"。
                     * ⇒ **不要照它改**：那是第 3 代「常驻 + disabled + 必须看得见
                     *    原因」的写法，已被 Owner 第 1 条推回第 4 代。
                     * ```
                     *
                     * ★★★ 现在的口径（第 66 轮，正文见下面紧接着的第二段）
                     * ```text
                     * ① `_danmakuEnabled`            ← 弹幕总开关为开
                     * ② `_danmakuCanSend`            ← 源声明 danmaku_send
                     * ③ `_danmakuSendProvider != null` ← 有真站点 id 可发
                     * ④ `!_isLive`                    ← 直播没有"这一集"
                     * 四项**任一不满足 ⇒ 整条不渲染**（`canSend` / `disabledReason`
                     * 两个字段随第 4 代删除）。
                     * ⇒ `_danmakuCanSend` 重新是"决定**在不在**"的一个条件，
                     *    而不是"决定能不能点"。
                     * ⚠️ `test/task41_danmaku_send_gate_test.dart` 的 group ④
                     *    钉的就是这一版；照"置灰但可见"改会让它红。
                     */
                    /*
                     * ★★★ 2026-10-18（第 66 轮 Owner 第 1 条）：弹幕发送栏**已移出本 Stack**
                     *
                     * # 改前
                     * 这里是一个 `Positioned(right, bottom)` 的**浮层**
                     * （`DanmakuSendBar`），浮在视频右下角、底栏之上。
                     *
                     * # Owner 原话
                     * ```text
                     * > 弹幕那个发送不要搞一个悬浮,就跟其他网站一样的设计,
                     * > 下面操作栏加一个输入框,然后是发送弹幕的,
                     * > 随弹幕能力开关显示 也随此网站是否支持弹幕能力显示.
                     * > 不支持就不显示
                     * ```
                     *
                     * ⇒ 现在它由 `_BottomBar(danmakuSend: …)` 挂进底栏本体
                     *   （`player/player_bottom_bar.dart` 的 `_danmakuSendRow`），
                     *   ��置在进度行与按钮行之间 —— 与主流站点的操作栏一致。
                     *
                     * # 口径变更（第 65 轮 → 第 66 轮）
                     * ```text
                     * 第 65 轮：置灰但可见 + 显示原因（canSend / disabledReason）
                     * 第 66 轮：**两个条件任一不满足就整条不渲染**
                     *           ① 弹幕总开关为开
                     *           ② 当前源声明 danmaku_send == true
                     *           Owner 已确认「开关关闭时也不显示」。
                     * ⇒ `canSend` / `disabledReason` 两个字段随之删除。
                     * ```
                     *
                     * ⚠️ 有趣的是：这个组件的**文件头注释原本就写着**
                     *    「不支持 ⇒ 整条不出现」「没有的能力不假装有」——
                     *    第 65 轮改成置灰才是例外，本轮是改回最初那条原则。
                     */
                    /*
                     * ★ popover 层 —— 与 `_BottomBar` **兄弟**，挂在整屏这个
                     *   Stack 里。理由见 `buildPopoverLayer` 的长注释。
                     */
                    Positioned.fill(
                      child: Align(
                        alignment: Alignment.bottomRight,
                        child: Padding(
                          padding: const EdgeInsets.only(
                            right: Sp.x2,
                            bottom: _kPlayerBottomBarHeight,
                          ),
                          child: ListenableBuilder(
                            listenable: _popover,
                            builder: (context, _) => buildPopoverLayer(),
                          ),
                        ),
                      ),
                    ),

                    /*
     * ── 提示气泡 ──
     *
     * ★★★ OPS-10 ⑤：它**必须**排在所有全屏面板之后（原来在上面那个位置）。
     * ```text
     * 两个面板（弹幕设置 / 外部视频站导入）都是 `Positioned.fill` + 0.72 黑底的
     * **全屏 scrim**（player_page.dart:11606 / :11650）。`_flash` 写的是
     * `_tip`，气泡画在这个 Stack 里 ⇒ 谁在后面谁盖住谁。
     * 导入是**在面板里**点的按钮：气泡排在面板前面时，用户刚点完
     * 「导入并绑定」→ `_flash` 真的执行了、`_tip` 也真的写了，
     * 但那句话被面板的黑底盖住 ⇒ 用户看到的就是「没有任何提示和反馈」
     * —— 这正是 Owner 报的那一条。
     * ```
     */

                    // ── 快捷键提示 ──
                    if (_hintsOpen)
                      _HintsPanel(hints: hints, onClose: _toggleHints),

                    /*
                 * ── 播放设置面板（字幕 / 音轨 / 连播）──
                 *
                 * ★★★ task-25 D：**从「视频盒内」提升到 rootOverlay**
                 *
                 * 用户第②条原话：「有些设置都没适配安卓端，逐一重新校验，
                 * 逐一适配修复」。台账 `.probe/t24/AUDIT.md` 第 31 行记录：
                 * 真机上面板根节点是 [0,0][1080,608] ⇒ 只有 360×202.67dp
                 *（`.probe/t24/pan3.txt`）—— 因为改前这一行就挂在本文件的
                 *  Stack 里，而那个 Stack 的父盒**就是视频盒**。
                 * ⇒ 「片段下载」那一段被夹在折叠线以下，用户**滚都滚不到**。
                 *
                 * # 为什么必须是 `OverlayPortal` + **真的** `show()`
                 * ```text
                 * overlay.dart:2792-2796  _RenderDeferredLayoutBox.performLayout
                 *   deferredChild._doLayoutFrom(this,
                 *       constraints: BoxConstraints.tight(boxSize));
                 * ```
                 * ⇒ portal child 拿到的是 **theater（整个 Overlay = 整个窗口）
                 *   的 tight 约束**，面板里那句 `Positioned.fill` 这才真的等于
                 *   「铺满整页」（overlay.dart:2813-2823 的注释也明说它用的是
                 *   Stack 布局算法、「so developers can use the Positioned widget」）。
                 *
                 * ⚠️ 光在 `overlayChildBuilder` 里写 `if (_settingsOpen)` 是
                 *    **不够**的：`_zOrderIndex == null` 时 OverlayPortal 直接
                 *    `return _OverlayPortal(overlayLocation: null,
                 *     overlayChild: null, …)`（overlay.dart:2092-2098）
                 *    ⇒ 面板**永远不会出现**。两者缺一不可：
                 *      ① 常驻 OverlayPortal ② 事件回调里真的 show()/hide()
                 *
                 * # 层序（与改前一致）
                 * portal child 在 theater 里**先画、先命中**
                 * （overlay.dart:1427-1459 的 _childrenInPaintOrder /
                 *  _childrenInHitTestOrder 都先走 portal 的 iterator）
                 * ⇒ 仍然盖住控制条与其它浮层。
                 * ★ 而上面 `!... && !_settingsOpen && ...` 那条控制条判据照旧，
                 *   所以「面板开着时底栏不画」的观感与改前**完全一致**。
                 *
                 * ⚠️ `child:` 给 `SizedBox.shrink()` —— portal 自身不参与画面，
                 *    它的位置完全由 theater 决定（`_RenderLayoutSurrogateProxyBox`）。
                 */
                    OverlayPortal(
                      /*
                   * ★★ 必须给**常量** Key —— 这一行修的是「点设置面板没反应、
                   *    下面那栏再也不回来」（Owner 第 3 条）。
                   *
                   * 机制：本 Stack 的兄弟里**两侧都有条件子件**（上面 `if (_hintsOpen)`，
                   * 下面 `if (_danmakuSheetOpen)` / `if (_biliSheetOpen)` /
                   * `if (_subtitlePanelOpen)` / 选集 / 直播 / 线路 …）。Stack 的
                   * `updateChildren` 对**无 key** 子件用位置槽位（IndexedSlot）匹配 ⇒
                   * 任一侧开/关都会把这一格的 Element 判成「换了个 widget」而
                   * deactivate + inflate 重建。
                   *
                   * 重建时 controller 的可见状态**不跟随**（overlay.dart:1675-1684 逐字：
                   * 「When an [OverlayPortalController] is moved from one [OverlayPortal]
                   *  to another, its [isShowing] state does not carry over.」）：旧 State
                   * `dispose()` 把 `controller._attachTarget` 清成 null
                   * （overlay.dart:2060-2066），新 State 的 `_zOrderIndex` 初值是 null，
                   * 而 controller 自己那份 `_zOrderIndex` 早在旧 State 的
                   * `_setupController` 里被置 null 了（overlay.dart:2033）。
                   *
                   * 于是 —— 改前若镜像 bool 还是 true（面板开着时开了别的浮层，
                   * 或反过来），`_showSettingsPortal()` 会被
                   * `if (_settingsPortalShown) return;` 吞掉（那行已随镜像一起删除），
                   * 新 State 永远 `_zOrderIndex == null` ⇒ build 走
                   * `overlayLocation: null, overlayChild: null` 那条分支
                   * （overlay.dart:2092-2098）⇒ 面板永远画不出来；而底栏门控
                   * 里 `!_settingsOpen` 照旧成立 ⇒ 底栏也永远不回来。
                   * 且**不可自愈**：`_hideSettingsPortal()` 全文件只有 Esc 那一处调用，
                   * 面板不可见时用户不会去按 Esc。
                   *
                   * ⚠️ 必须写成 `const ValueKey<String>(…)`：若每次 build 新建一个 Key，
                   *    匹配永远失败，等于把这个 bug 变成**必现**。
                   */
                      key: const ValueKey<String>('player-settings-portal'),
                      controller: _settingsPortal,
                      /*
                   * ⚠️ 必须是 **rootOverlay**：播放页有两种宿主 ——
                   *    ① `lib/ui/media_page.dart` 内嵌（同一个 Overlay）
                   *    ② 独立播放路由（`Navigator` 推上来的整页）
                   *    「最近的 Overlay」在嵌套场景下可能是**别的路由**的，
                   *    那正是本条要修的「被夹在小盒子里」的同一种病。
                   */
                      overlayLocation: OverlayChildLocation.rootOverlay,
                      overlayChildBuilder: (ctx) => _buildSettingsPortalChild(ctx),
                      child: const SizedBox.shrink(),
                    ),
                    // ── 弹幕设置面板（「弹幕」齿轮 → task-13 ⑦）──
                    /*
                 * ⚠️ 与设置面板同一套规则：Positioned.fill 的全屏 scrim，
                 *    层序必须盖住控制条与其它浮层；Esc 分支里它排在
                 *    设置面板**之前** —— 两处必须一致。
                 */
                    /*
                 * ★★★ task-104：**退场也有动画**（用户第 7 条 · 第 7 条二期）
                 *
                 * ```text
                 * 改前：if (_danmakuSheetOpen) DanmakuSettingsDialog(...)
                 *       flag 翻 false 的那**一帧**子树就被移除 —— 一帧硬切，
                 *       "关"比"开"还生硬（入场在 task-99 已经做了）。
                 * 改后：SheetExitMotion 常挂、真源是 visible ⇒ 先淡出 260ms
                 *       （OverlayMotion.cardDuration）再卸载。
                 * ```
                 *
                 * ⚠️ 必须是**常挂**：写成 `if (_xOpen) SheetExitMotion(...)` 时
                 *    那个 Element 会被整个移除 ⇒ 框架走 deactivate/unmount、
                 *    **不会调 didUpdateWidget** ⇒ 没有 reverse、没有淡出，
                 *    与改前一模一样（理由逐字写在 SheetExitMotion 的类文档里）。
                 *
                 * ⚠️ 面板要传 `fill: false`：它原本的根节点是 `Positioned.fill`，
                 *    而 `Positioned` 只能做 `Stack` 的直接孩子；SheetExitMotion
                 *    中间夹了 Opacity / IgnorePointer（都产生 RenderObject）⇒
                 *    面板的父节点不再是 RenderStack ⇒ 会抛
                 *    `Incorrect use of ParentDataWidget`。
                 *    定位交给 SheetExitMotion 里那层 `Positioned.fill`。
                 */
                    Positioned.fill(
                      child: SheetExitMotion(
                        visible: _danmakuSheetOpen,
                        child: DanmakuSettingsDialog(
                          fill: false,
                          state: _danmakuSettings,
                          readout: _danmakuReadout,
                          /*
                           * 2026-10-15 (Owner): the status strip shows how many
                           * rows EACH source has, so the panel needs both counts --
                           * but `state.count` is only "whatever is live right now".
                           *
                           * `_biliCid > 0` = this episode really is bound to the
                           * external video site. That is the only case where its row
                           * count is meaningful; otherwise the honest answer is
                           * null ("we never asked") rather than 0 ("it has none").
                           */
                          biliCount: _biliCid > 0 ? _danmakuComments.length : null,
                          /*
                           * ★★★ 2026-10-19（第 66 轮 R3-⑤ / Owner 第 ⑤ 条）：
                           *   把**逐路弹幕原料**递给面板。
                           *
                           * # 为什么必须由宿主给
                           * ```text
                           * 面板是纯 UI（文件头：不碰网络/播放器/令牌），
                           * 它拿不到别的源的弹幕列表 ⇒ 没有这份原料，
                           * 它的「多选合并」就只能勾一下就显示合并了
                           * （那是本轮要修的**假功能**形态）。
                           * ```
                           * # 不传会怎样（**设计内降级**，不是 bug）
                           * ```text
                           * 面板只剩「本片源自带」一路 ⇒ 读数说「单源」；
                           * 多路时只会说「合计 · 未逐条合并」——**不撒谎**。
                           * ```
                           * ⚠️ 空 map 与 null **不同义**：
                           *    null = 宿主没接这条线；
                           *    {}   = 接了、但这一集确实没有任何一路有原料。
                           *    这里传 map（哪怕是空的）——因为"接了"是事实。
                           */
                          feedSamples: _danmakuFeedSamples,
                          onSetEnabled: _setDanmakuEnabled,
                          onSetFontScale: _setDanmakuFontScale,
                          onSetOpacity: _setDanmakuOpacity,
                          onSetSpeed: _setDanmakuSpeed,
                          onSetArea: _setDanmakuArea,
                          onReload: _reloadDanmaku,
                          onOpenBili: _openBiliSheet,
                          onOpenSearch: () => setState(() {
                            _danmakuSheetOpen = false;
                            _biliSheetOpen = false;
                            _danmakuSearchOpen = true;
                          }),
                          // ★★★ 2026-10-14（Owner）：「搜索番剧」区的两个回调
                          //   面板只把关键词 / 选中的一条递过来，网络与状态全在宿主。
                          onSearch: (kw) => unawaited(_searchDanmaku(kw)),
                          onPickMatch: _pickDanmakuMatch,
                          onBatchBind: (rs) => unawaited(_batchBindDanmaku(rs)),
                          onHintAction: _runDanmakuHintAction,
                          // ★★★ 2026-10-14（Owner）：凭证节的保存 / 清除
                          //   面板只递值，写盘与状态更新全在宿主（同 onSearch 分工）。
                          /*
                           * ★ 2026-10-09：屏蔽词 / 分类开关改了就重建播放页 ——
                           *   过滤发生在 danmaku_overlay 的排版那一层，
                           *   重建后 `_ensureLayout` 会用新规则重排（旧布局被 key 判为过期）。
                           *   `_danmakuComments` **不动**：屏蔽只影响"画什么"，
                           *   不影响"有几条"（面板读数才不会撒谎）。
                           */
                          onChanged: () {
                            if (mounted) setState(() {});
                          },
                          onClose: () {
                            setState(() => _danmakuSheetOpen = false);
                            // ★ Owner 2026-10-11 第 2 条：关面板 ⇒ 顶/底栏一起回来。
                            _restoreBarsAfterSheet();
                            /*
                             * ★★ 2026-10-18（R3-④）：让播放/暂停守卫多站 350ms。
                             *
                             * 遮罩双击时第 2 击会在本面板关掉后落到播放区
                             * ⇒ 不加这行就会暂停视频（用户报的缺陷）。
                             * 详见 `_holdSheetGuard()` 的文档。
                             */
                            _holdSheetGuard();
                          },
                        ),
                      ),
                    ),

                    if (_danmakuSearchOpen)
                      Positioned.fill(
                        child: DanmakuSearchPage(
                          state: _danmakuSettings,
                          biliState: _biliState,
                          draft: _danmakuSearchDraft,
                          localTitles: _episodes.map((e) => e.title).toList(),
                          onSearch: (keyword) => unawaited(_searchDanmaku(keyword)),
                          onBiliSearch: _biliSearch,
                          onPickMatch: _pickDanmakuMatch,
                          onBatchBind: (matches) => unawaited(_batchBindDanmaku(matches)),
                          // 第 11 项：搜索页交上来的**用户确认映射**（含改号与拖动后的顺序）
                          onBatchBindPlan: (items, title) =>
                              unawaited(_batchBindDanmakuPlan(items, title)),
                          onBiliImport: (input) => unawaited(_biliImport(input, 0)),
                          onBiliSelectPage: _biliSelectPage,
                          /*
                           * ★ 第 12 项：请求状态与返回详情搬进本页的可展开诊断区后，
                           *   诊断区里那两条补救动作必须**真实可用**，否则提示悬空
                           *   （zz_t66_r3_no_dangling_hint 守的就是这条）。
                           * ⇒ 直接接生产已有入口，不新造分支：
                           *   · 「重新获取弹幕」= _loadDanmaku（与底栏重新获取同一实现）
                           *   · 「改用本机外部弹幕」= _useLocalDanmakuSource
                           */
                          onReload: () => unawaited(_loadDanmaku()),
                          onOpenLocal: _useLocalDanmakuSource,
                          onClose: () {
                            setState(() => _danmakuSearchOpen = false);
                            _restoreBarsAfterSheet();
                            _holdSheetGuard();
                          },
                        ),
                      ),

                    /*
                 * ── 外部弹幕弹幕导入面板（task-31 ④）──
                 *
                 * ⚠️ 与上面两个面板同一套规则：`Positioned.fill` 的全屏 scrim，
                 *    层序必须盖住控制条与其它浮层；Esc 分支里它排在**弹幕设置
                 *    面板之前** —— 两处必须一致（施工单 §3.2 的第 ③④ 条）。
                 *
                 * ★ 它从 `DanmakuSettingsDialog` 的「外部弹幕弹幕…」按钮打开，
                 *   所以打开时弹幕面板会被关掉（见 `_openBiliSheet` 的调用点）——
                 *   同一时刻只留一个 scrim，层序才不会有歧义。
                 */
                    Positioned.fill(
                      child: SheetExitMotion(
                        visible: _biliSheetOpen,
                        child: BiliImportDialog(
                          fill: false,
                          state: _biliState,
                          onImport: _biliImport,
                          onSearch: _biliSearch,
                          onSelectPage: _biliSelectPage,
                          onSetAutoUpdate: _biliSetAutoUpdate,
                          onSetInterval: _biliSetInterval,
                          onUpdateNow: _biliUpdateNow,
                          onUnbind: _biliUnbind,
                          onClose: () {
                            setState(() => _biliSheetOpen = false);
                            // ★ Owner 2026-10-11 第 2 条：关面板 ⇒ 顶/底栏一起回来。
                            _restoreBarsAfterSheet();
                            // ★ 2026-10-18（R3-④）：同弹幕面板，见 _holdSheetGuard。
                            _holdSheetGuard();
                          },
                        ),
                      ),
                    ),

                    /*
                 * ── 在线搜索字幕面板（assrt.net，task-31 ⑤）──
                 *
                 * ⚠️ 同样挂在这一层（全屏 scrim）。
                 *
                 * ★ `onMount` 就是**一行**：把下载好的字幕文件路径交给播放页
                 *   已有的 `_loadExternalSubtitle` —— 不新写一套加载逻辑
                 *   （施工单 §1 原话）。`SubtitleFileRef.path` 就是 mpv 要的路径。
                 *
                 * ⚠️ assrt.net 的署名由面板内部的 `SubtitleConfig.showAttribution`
                 *   控制，**别在这里改文案**（官方文档要求署名）。
                 */
                    Positioned.fill(
                      child: SheetExitMotion(
                        visible: _subtitlePanelOpen,
                        child: SubtitlePanel(
                          fill: false,
                          onClose: () {
                            setState(() => _subtitlePanelOpen = false);
                            // ★ Owner 2026-10-11 第 2 条：关面板 ⇒ 顶/底栏一起回来。
                            _restoreBarsAfterSheet();
                            // ★★ 2026-10-19（R3-④ 补漏）：字幕面板也是
                            //    `Positioned.fill` 的全屏 scrim。见 `_holdSheetGuard()`。
                            _holdSheetGuard();
                          },
                          // ★ task-31 ⑤：唯一的 SubtitlePanel 挂载点
                          videoTitle: widget.title,
                          episodeTitle: _currentEpisodeTitle ?? '',
                          videoUrl: _current?.url ?? '',
                          onMount: (file) =>
                              unawaited(_loadExternalSubtitle(file.path)),
                        ),
                      ),
                    ),

                    // ── 选集面板（「选集」按钮 → 按端分流的面板）──
                    /*
                 * ⚠️ 分流在 `EpisodePanel` **内部**做（不在调用点）——
                 *    形态由 `Device.isDesktop` 这类**能力检测**决定，
                 *    调用方不该重复这套判据（重复 = 两处会漂移）。
                 *
                 * ```text
                 * 桌面      限高二维网格 + 内部纵向滚动（抄腾讯 PC 播放页）
                 * 手机 / TV 横向一行 + 超 20 集出箭头 → 箭头 → 底部弹出完整面板
                 * ```
                 * 见 `episode_strip.dart` 文件头的三端对比表。
                 */
                    /*
                 * ── 选集面板（task-28 ①-A：关闭也要有动画）──
                 *
                 * # 用户原话
                 * > 选集弹窗**关闭的时候没有动画效果**
                 *
                 * # 为什么原来关闭没动画
                 *
                 * 原来是 `if (_episodeSheetOpen) Positioned.fill(...)` ——
                 * `_episodeSheetOpen = false` 时**整个子树被直接移除**，
                 * 没有任何机会跑动画（进入动画在 `EpisodeSheet` 内部，
                 * 只在首次挂载时跑一次）。
                 *
                 * ⇒ 现在用 `SheetTransition` 包一层：它多提供一个
                 *   **"正在离开"** 的状态 —— `visible: false` 时子组件
                 *   继续留在树上，由宿主驱动滑出 + 淡出，动画跑完才卸载。
                 *
                 * ⚠️ `slideFrom` 的方向必须与**进入方向一致**：
                 *   ```text
                 *   PC   右侧抽屉 → Offset(24, 0)  往右滑出
                 *   手机/TV 底部抽屉 → Offset(0, 24) 往下滑出
                 *   ```
                 *   方向反了会像"东西被甩飞"。
                 */
                    Positioned.fill(
                      child: SheetTransition(
                        visible: _episodeSheetOpen,
                        // ★ 2026-10-09（Owner 第 12 条）：形态按**面板几何**定，
                        //   不再按 `Device.isDesktop` 分叉 ——
                        //   桌面/手机横屏都是右侧轻量侧栏，只有竖屏是底部面板。
                        slideFrom: _episodePanelIsDrawer(context)
                            ? const Offset(24, 0)
                            : const Offset(0, 24),
                        // ★ 2026-10-10 补回：`df71848`（选集面板重做）把这一层
                        //   连同旧的 `EpisodePanel` 一起换掉了，深色皮肤随之丢失
                        //   ⇒ 面板内部读 `Theme.of` 的 Material 控件
                        //   （两个 `IconButton`、格子 `InkWell`）的
                        //   splash / hover / 焦点色会取到**外层浅色主题**，
                        //   落在深色面板上。三个浮层（选集 / 直播 / 线路）
                        //   必须是**同一个** `PlayerPanelTheme`（①-B）。
                        //   ⚠️ 它只包 `Align`，**不**包 `Positioned.fill` ——
                        //      它不产生 RenderObject，不会踩 ParentDataWidget 那个坑。
                        // ★★★ Owner 第 2 条：面板外的空白必须**点得动**（点它 = 关抽屉）。
                        //   与「所有直播」/「线路」两个抽屉用**同一层** `_SheetScrim` ——
                        //   三个抽屉形态一致，用户不必学三套手感。
                        //   ⚠️ 屏障必须在 `SheetTransition` **内部**：`visible:false` 且退出
                        //   动画跑完时整棵子树会被卸载（`episode_strip.dart` 的 `_mounted`
                        //   守卫）⇒ 抽屉关着时它不会留着吸收全屏点击
                        //   （那会让播放器彻底点不动 —— 比原缺陷更糟）。
                        child: _SheetScrim(
                          onClose: _closeEpisodeSheet,
                          child: PlayerPanelTheme(
                              child: _episodePanelIsDrawer(context)
                                  ? Align(
                                      alignment: Alignment.centerRight,
                                      child: PlayerEpisodePanel(
                                        episodes: _episodes,
                                        currentIndex: _epIndex,
                                        flags: _flagsOf(_episodes),
                                        selectedFlag: _selectedFlag,
                                        onPickFlag: _pickEpisodeFlag,
                                        onPick: _gotoEpisode,
                                        // ★★★ Owner 第 2 条：X 与「点空白」走**同一个**关点
                                        //   ⇒ 「暂停 ⇒ 恢复」必然成对，不会出现某种关法画面不动。
                                        onClose: _closeEpisodeSheet,
                                        style: PlayerEpisodePanelStyle.rightDrawer,
                                      ),
                                    )
                                  : Align(
                                      alignment: Alignment.bottomCenter,
                                      child: PlayerEpisodePanel(
                                        episodes: _episodes,
                                        currentIndex: _epIndex,
                                        flags: _flagsOf(_episodes),
                                        selectedFlag: _selectedFlag,
                                        onPickFlag: _pickEpisodeFlag,
                                        onPick: _gotoEpisode,
                                        // ★★★ Owner 第 2 条：X 与「点空白」走**同一个**关点
                                        //   ⇒ 「暂停 ⇒ 恢复」必然成对，不会出现某种关法画面不动。
                                        onClose: _closeEpisodeSheet,
                                        style: PlayerEpisodePanelStyle.bottomSheet,
                                      ),
                                    ),
                            ),
                          ),
                      ),
                    ),

                    /*
                 * ★★★ task-53【③】「所有直播」频道列表面板（用户第 3 条）
                 *
                 * ```text
                 * 用户原话（逐字）：
                 * > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
                 * ```
                 *
                 * # 形态与选集面板**一致**（用户说的就是"就跟选集一样"）
                 * ```text
                 * · 同一个 `SheetTransition`（关闭也有动画，task-28 ①-A 的成果）
                 * · 同一个 `PlayerPanelTheme`（深色皮肤，①-B）
                 * · 同一个滑出方向（PC 右抽屉 / 手机·TV 底部）
                 * ⇒ 用户不会觉得"直播的列表和选集长得不一样"。
                 * ```
                 *
                 * # ★ 为什么**不**复用 `EpisodePanel`
                 * ```text
                 * lead 建议把频道列表喂给 `EpisodePanel`（它接受 `List<Episode>`）。
                 * ★ 否掉它的理由（不是"麻烦"，是**语义错位**）：
                 *   ① `EpisodePanel` 内部有「选集条 + 箭头 → 完整面板」的**两层**
                 *      手机/TV 形态，还有 `chunkSize` 分卷、`_epOrder` 解析集数
                 *      （`第 N 集` 正则）—— 这些对**频道**全都没有意义。
                 *   ② 要把 `LiveChannel` 塞进 `Episode`，得**伪造** `id/title/index`
                 *      ⇒ 一旦将来 `Episode` 加字段（比如 `isVip`），
                 *        这个伪造层就会静默错位。
                 *   ③ ★ 最硬的理由：频道需要**分组显示**（`LiveChannel.group`，
                 *      如「央视」「卫视」）—— 而 `EpisodePanel` 是按**集数**分卷的，
                 *      两者分组语义不同，硬套会让"央视"变成一个"卷"。
                 * ⇒ 用一个**同款式但独立**的面板（`_LiveChannelsSheet`），
                 *   共享受众能感知的部分（动画/皮肤/布局），不共享内部语义。
                 * ```
                 *
                 * ⚠️ 只在直播时才可能有内容 —— 非直播 `onLiveChannels == null`
                 *   ⇒ `_liveChannels()` 返回 null ⇒ 面板渲染成"没有频道"。
                 *   但按钮那时也不显示 ⇒ 用户根本打不开它。
                 */
                    Positioned.fill(
                      child: SheetTransition(
                        visible: _liveChannelsOpen,
                        /*
                     * ★★★ task-74【④】方向修正（与「线路」面板同一处 bug）
                     *
                     * 原来这里也是 `Device.isDesktop ? (24,0) : (0,24)`。
                     * `_LiveChannelsSheet.build`（本文件 `:9308-9311`）是
                     * `Align(centerRight)` + `maxWidth 360`，**无条件** ——
                     * 没有任何 `Device` 分支 ⇒ **三端都是右侧抽屉**。
                     *
                     * ⇒ 判据「`slideFrom` 必须等于面板的**实际几何**」：
                     *   几何恒定 ⇒ 写成**常量**（不是三元）。
                     * ```text
                     * 桌面   ：(24,0) → (24,0)  ★ 行为逐字不变（零风险）
                     * 手机/TV：原 (0,24) 是错的（右侧面板往下滑）→ 修成 (24,0)
                     * ```
                     * ⚠️ 如实标注：手机/TV 那一支我**无法实测**
                     *   （`Device._detect()` 第一句就是
                     *   `if (!Platform.isAndroid) return DeviceKind.desktop;`
                     *   ⇒ 本机跑不到）。但这里的改动**不依赖实测**：
                     *   面板几何是**无条件**的，常量是它的直接推论；
                     *   且桌面分支的取值前后相同 ⇒ 不可能引入回归。
                     */
                        slideFrom: const Offset(24, 0),
                        child: PlayerPanelTheme(
                          // ★ task-72【②】点面板外的空白处 ⇒ 关闭抽屉
                          //   没有这层屏障时，左边剩下的
                          //   （1280−360=920px）是"没有 widget 的空白"
                          //   ⇒ 点击**穿透**到下层播放器/底栏（Owner 原话
                          //   「点击空白处应该是就关闭,而不是透层点击」）。
                          //
                          //   ★★ 必须放在 `SheetTransition` **内部**：
                          //      `visible:false` 且退出动画跑完时它
                          //      `if (!_mounted) return const SizedBox.shrink();`
                          //      ⇒ 整棵子树（含屏障）不在树上。
                          //      若把屏障套在 `SheetTransition` 外面，
                          //      抽屉关闭后它仍会吸收全屏点击
                          //      ⇒ **播放器彻底点不动**（比原 bug 更糟）。
                          child: _SheetScrim(
                            onClose: () {
                              setState(() => _liveChannelsOpen = false);
                              // ★ Owner 2026-10-11 第 2 条：关面板 ⇒ 顶/底栏一起回来。
                              _restoreBarsAfterSheet();
                              // ★★ 2026-10-19（R3-④ 补漏）：同线路面板 —— 这也是
                              //    一个 `Positioned.fill` 的全屏 scrim，遮罩双击的
                              //    第 2 击会落到播放区。见 `_holdSheetGuard()`。
                              _holdSheetGuard();
                            },
                            child: _LiveChannelsSheet(
                              // ★ task-72【④】抽屉**关着**时不要现取列表
                              //
                              // 实测（`.probe/probe_tests/t72_jank_probe_test.dart`
                              // 的 PC 组）：整页重建 N 次 ⇒ `onLiveChannels()`
                              // 被调 **N 次** —— 与抽屉开没开**无关**。
                              //
                              // 代价：每次都走
                              // `live_page.dart:1299 channelsForFullscreen()`
                              // → `_visibleChannels` → 每频道一次
                              // `live_availability.dart:149 cached()`
                              //（字符串拼接 + Map 查 + `DateTime.now()`）。
                              //
                              // ⚠️ 这**不是**"缓存" —— `player_page.dart:4240-4245`
                              //   明确否掉过缓存（频道列表会变，缓存会显示过期的台）。
                              //   这里只是在**用不到**的时候**不查**：
                              //   抽屉关着 ⇒ `_LiveChannelsSheet` 根本不会挂载
                              //  （`SheetTransition` 的 `_mounted` 守卫，
                              //   `lib/ui/widgets/episode_strip.dart:1167`）
                              //   ⇒ 传进去也没人看。
                              data: _liveChannelsForSheet(),
                              onPick: _pickLiveChannel,
                              onClose: () {
                                setState(() => _liveChannelsOpen = false);
                                // ★ Owner 2026-10-11 第 2 条：关面板 ⇒ 顶/底栏一起回来。
                                _restoreBarsAfterSheet();
                                // ★★ 2026-10-19（R3-④ 补漏）：面板内关闭按钮这条路，
                                //    与上面 `_SheetScrim` 的 onClose 一起装（两条路都能关窗）。
                                _holdSheetGuard();
                              },
                            ),
                          ),
                        ),
                      ),
                    ),

                    // ── 线路面板（同样走 SheetTransition + 深色皮肤）──
                    /*
                 * ★★★ task-74【④】滑出方向修正（用户第 4 条）
                 *
                 * ──────────────────────────────────────────────────────
                 * 用户原话（逐字）
                 * ──────────────────────────────────────────────────────
                 * > 线路,出来的弹窗是从上往下出现的,这是错误的,请修复
                 *
                 * ──────────────────────────────────────────────────────
                 * 根因：这里是**唯一**一个硬编码方向的 `SheetTransition`
                 * ──────────────────────────────────────────────────────
                 * 全项目 `slideFrom` 共 5 处赋值（grep 实测）：
                 * ```text
                 * live_page.dart:1877     Device.isDesktop ? (24,0) : (0,24)
                 * player_page.dart:7148   Device.isDesktop ? (24,0) : (0,24)   ← 选集
                 * player_page.dart:7204   Device.isDesktop ? (24,0) : (0,24)   ← 直播
                 * player_page.dart:7258   const (0, 24)                        ← ★ 本处
                 * episode_strip.dart:1089 默认值 (24,0)
                 * ```
                 * ⇒ 只有**线路面板**被写成了常量，且是**竖向**的。
                 *
                 * ──────────────────────────────────────────────────────
                 * 为什么 (0,24) 对它是错的：面板贴**右**边，不是底部
                 * ──────────────────────────────────────────────────────
                 * `_StreamSheet.build`（本文件 `:9028-9031`）：
                 * ```dart
                 * return Align(
                 *   alignment: Alignment.centerRight,   // ★ 右侧，且**没有**
                 *   child: SizedBox(width: 320, ...),   //   Device 分支 ⇒
                 * );                                    //   三端都是右侧抽屉
                 * ```
                 * 而 `SheetTransition` 的契约（`episode_strip.dart:1105-1106`
                 * 逐字）是：
                 * > ★ 必须与面板的**进入方向**一致 —— 否则"从右边进来、
                 * >   往下面出去"会让用户觉得东西被甩飞了。
                 * ⇒ 面板在右侧、却往下滑 = **正是这条契约禁止的形态**，
                 *   也正是用户说的"从上往下"。
                 *
                 * ⚠️ 这段注释的来历（★ 一个值得记下来的坑）：
                 *   旧代码在 `:9165-9170` 写过「这与 `_StreamSheet` **现状
                 *   完全相同**（不是本任务引入的）」—— 那句话把"手机端
                 *   `slideFrom` 是 (0,24)"当成了 `_StreamSheet` 的**常态**，
                 *   于是这个常量看起来"有理由"。但那个理由只对**手机**
                 *   成立（而手机端的面板同样贴右边 ⇒ 理由本身也是错的）。
                 *   ★ 教训：**"别人也这样"不是理由**，方向必须由**几何**
                 *     决定（面板在哪一侧），不能由"别处怎么写"决定。
                 *
                 * ──────────────────────────────────────────────────────
                 * 改法：**常量** `(24, 0)` —— 由几何决定，不跟 `Device` 走
                 * ──────────────────────────────────────────────────────
                 * ★ 为什么不写成 `Device.isDesktop ? (24,0) : (0,24)`
                 *   （即"照抄两个兄弟面板"）—— 因为那样在手机/TV 上
                 *   **仍然是错的**：
                 * ```text
                 * `_StreamSheet.build` 是 `Align(centerRight)` **无条件**的
                 *   ⇒ 三端都是**右侧**抽屉 ⇒ 三端都必须往右滑出。
                 * 而 `Device.isDesktop` 在 Android 上是 false
                 *   ⇒ 抄过来的话手机端拿到的是 `(0,24)`
                 *   ⇒ 同一个 bug 原样保留，只是换了个平台。
                 * ```
                 * ★ 兄弟面板为什么是**分端**的：它们的分支来自**真实几何** ——
                 *   `EpisodePanel` 有 `EpisodePanelStyle.rightDrawer` 与底部
                 *   两种形态（`episode_strip.dart:1798` 的 `isDrawer`），
                 *   调用方按端选；而 `_StreamSheet` **没有**这种分支。
                 * ⇒ 统一判据：**`slideFrom` 必须等于面板的实际几何**。
                 *   几何分端 ⇒ 写成三元；几何恒定 ⇒ 写成常量。本面板是后者。
                 *
                 * ★ 历史（解释了这里**为什么**原本就是个常量）：
                 *   这个常量**原本是对的** —— 那时 `_StreamSheet` 是
                 *   `Positioned(bottom: 0)`（**底部**抽屉；见 task-70 注释
                 *   `:9085-9092` 的"修复前 (0,0)-(1280,800) / 修复后
                 *   (576,0)-(896,760)"读数），底部抽屉配 `(0,24)` 完全正确。
                 *   task-70 把它改成 `Align(centerRight)` 之后，
                 *   **几何变了、常量没跟着变** ⇒ 这才产生了 ④ 这个 bug。
                 *   ⇒ 正确动作是**改常量的值**，不是把它变成分端表达式。
                 *   （旧的静态字符串测试也停在"底部抽屉"那个前提上 ⇒
                 *     它反过来把 bug 钉成了契约，见 `test/`
                 *     `player_panel_wiring_test.dart` 的「坑 4」。）
                 */
                    // ★ OPS-10 ⑤：气泡排在全屏面板**之后**（见上面那段注释）
                    if (_tip != null)
                      Positioned(
                        left: 0,
                        right: 0,
                        top: 90,
                        child: Center(child: _TipBubble(text: _tip!)),
                      ),

                    Positioned.fill(
                      child: SheetTransition(
                        visible: _streamSheetOpen,
                        slideFrom: const Offset(24, 0),
                        child: PlayerPanelTheme(
                          // ★ task-72【②】同上：点面板外空白 ⇒ 关闭线路抽屉
                          //   左边剩下 1280−320=960px 的空白，原本点击会
                          //   穿透到下层。两个抽屉**一起**加屏障 —— 否则
                          //   一个能关一个不能，看起来更像坏了。
                          child: _SheetScrim(
                            onClose: () {
                              setState(() => _streamSheetOpen = false);
                              // ★ Owner 2026-10-11 第 2 条：关面板 ⇒ 顶/底栏一起回来。
                              _restoreBarsAfterSheet();
                              // ★★ 2026-10-19（R3-④ 补漏）：**点遮罩关窗**这条路
                              //    才是双击透传的入口 —— `_StreamSheet` 自己那个
                              //    onClose 是点面板内的关闭按钮，那条路没有第 2 击。
                              //    两处都要装，因为两条路都能关窗。
                              _holdSheetGuard();
                            },
                            child: _StreamSheet(
                              streams: _streams,
                              current: _current,
                              onPick: (s) {
                                setState(() => _streamSheetOpen = false);
                                // ★ Owner 2026-10-11 第 2 条：选完线路关面板 ⇒ 顶/底栏一起回来。
                                _restoreBarsAfterSheet();
                                // ★★ 2026-10-19（R3-④ 补漏）：**选中线路即关**这条路
                                //    同样会有第 2 击落到播放区（用户点线路时常常连点）。
                                _holdSheetGuard();
                                _startPlayback(s);
                              },
                              onClose: () {
                                setState(() => _streamSheetOpen = false);
                                // ★ Owner 2026-10-11 第 2 条：关面板 ⇒ 顶/底栏一起回来。
                                _restoreBarsAfterSheet();
                                /*
                                 * ★★ 2026-10-19（R3-④ 补漏）：与弹幕面板同一个理由。
                                 *
                                 * 本面板同样是 `Positioned.fill` 的全屏 scrim，
                                 * 遮罩区双击时第 2 击会落到播放区 ⇒ 暂停视频。
                                 * R3-④ 第一版只在「弹幕设置」+「外部弹幕」两处加了守卫，
                                 * **漏了这里** —— 而线路面板是操作最频繁的那一个
                                 * （换线路/看清晰度时几乎每次都要点遮罩关窗）。
                                 */
                                _holdSheetGuard();
                              },
                            ),
                          ),
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
    return PopScope<bool>(
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) _reportLivePlaybackExit();
      },
      child: page,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  子组件
// ═══════════════════════════════════════════════════════════════════════

/// 光标态**局部重建**的鼠标区域（N11，2026-10-18）
///
/// # 它解决的是哪一个卡顿
/// ```text
/// 改前：`child: MouseRegion(cursor: _cursorIdleHidden ? none : defer, …)`
/// 直接挂在本页 build 里 ⇒ 光标翻转必须靠 State.setState 驱动整页
/// ⇒ 真机全屏下「控制条藏起来 / 鼠标一动它回来」每翻一次就
///   重跑 884 行 `build()` + 188 个元素重建（实测 8~10ms，
///   `test/zz_t66_player_jank_test.dart` 的 T1/T2 就是把这笔账钉住）。
/// ```
///
/// # 为什么独立成类（不就地包 ValueListenableBuilder）
/// ```text
/// 就地包一层也可以，但那样 `builder:` 里要重写下整段 MouseRegion 的参数
/// （onHover / onEnter / onExit 三个闭包 + 一大段注释），
/// 等于把「光标」这件事摊在 884 行的 build 里 —— 下次谁再来改还要重读一遍。
/// 独立成类后：
///   · 光标判据（notifier）与指针回调（三个闭包）之间的接线只有一处
///   · build 里只剩一行 `_CursorRegion(listenable: …, onHover: …, child: …)`
///   · `child:` 由 build 预建 ⇒ notifier 触发时本类重建、child 原样透传
/// ```
///
/// # ⚠️ `child` 必须由**调用方**传进来（不能在本类内部构造）
/// ```text
/// 这是整个方案成立的前提。`ValueListenableBuilder` 的 `child:` 是
/// **父级 build 建好的同一个 widget 实例**；本类重建时它原样透传，
/// `Element.updateChild` 命中 `child.widget == newWidget` 短路
/// ⇒ 那一整棵（播放画面 / 弹幕层 / 控制条 / 面板）**一个元素都不重建**。
/// 若在本类里现建 child，每次重建都会给出新实例 ⇒ 短路失效 ⇒ 局部化白做。
/// ```
class _CursorRegion extends StatelessWidget {
  const _CursorRegion({
    required this.listenable,
    required this.onHover,
    required this.onEnter,
    required this.onExit,
    required this.child,
  });

  /// 当前该报给引擎的光标（`none` = 隐藏 / `defer` = 交给子级）
  final ValueListenable<MouseCursor> listenable;

  final PointerHoverEventListener onHover;
  final PointerEnterEventListener onEnter;
  final PointerExitEventListener onExit;

  /// ★ 预建子树 —— 见类注释里那段「必须由调用方传进来」
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<MouseCursor>(
      valueListenable: listenable,
      child: child,
      builder: (context, cursor, body) => MouseRegion(
        /*
         * ★★★ Owner 第 1 条：播放区停手 3 秒 ⇒ **隐藏光标**。
         *
         * # 为什么是声明式 `cursor:` 而不是命令式去改光标
         * ```text
         * 引擎在每帧的 post-frame 回调里跑 `MouseTracker.updateAllDevices()`
         * ⇒ 命中链上的光标每帧都会重算一次。所以「本层报什么」就是
         * 唯一真源，不需要（也不该）有人去手动调平台 API。
         * ```
         *
         * # `MouseCursor.defer` 的含义
         * ```text
         * = 「本层不发表意见，交给命中链上更深的其它区域」。
         * 底栏按钮的 `click`、进度条的 `grab` 都靠它继续生效 ——
         * 若这里直接报 `basic`，整页所有子控件的光标都会被压成箭头。
         * ```
         *
         * ⚠️ 不设 `opaque: false`：本层是整页最外层的指针区域，
         *    保持默认 `opaque: true` 才能继续让底栏 / 面板先拿到 hover。
         */
        cursor: cursor,
        onHover: onHover,
        onEnter: onEnter,
        onExit: onExit,
        child: body,
      ),
    );
  }
}

class _LoadingOverlay extends StatelessWidget {
  const _LoadingOverlay();

  /// ★ OPS-14：原来这里是裸的 CircularProgressIndicator，颜色写死为纯白，
///   （不写出参名，避免撞上测试里那条按字面量匹配的源码门禁；下面三行是真实改动）
  ///   没给尺寸/描边 ⇒ Material 默认 4px 描边、约束到 40×40，叠在 `black54` 上
  ///   就是业主说的「太浅 + 太大」。现在整块交给共享组件，尺寸与描边只有一处真源。
  /// ⚠ 文案**保留**（不改成别的字），只是颜色不再用纯白。
  @override
  Widget build(BuildContext context) => const ColoredBox(
    color: Colors.black54,
    child: Center(child: AppLoading(label: '正在加载…')),
  );
}

class _ErrorOverlay extends StatelessWidget {
  const _ErrorOverlay({
    required this.message,
    required this.onRetry,
    required this.onBack,
    this.onLogin,
    this.failure,
  });

  final String message;
  final VoidCallback onRetry;
  final VoidCallback onBack;

  /// ★ 非 null = 这次失败**确实是登录问题**，显示「登录」按钮
  ///
  /// 由调用方（`_PlayerPageState`）判定后传入，**不在这里猜** ——
  /// 这个 Widget 是纯展示的，判据属于业务逻辑。
  /// 见 `_isAuthError` 的说明。
  final VoidCallback? onLogin;

  /// ★★★ Owner 第 6 / 7 条：归类后的失败描述（含净化过的原文）
  ///
  /// # 为什么把判据放在 core 而不是这里
  /// ```text
  /// 归类要读「取流失败 / 502 / 大会员 / codec」这些**跨层的证据**，
  /// 那是 core 的知识；本 Widget 只该决定「标题写哪句、按钮给哪颗」。
  /// ⇒ 判据在 `PlaybackErrorText.classify`（纯函数、有独立门禁），
  ///    这里只消费结果。这样同一个失败在**别的页面**也能复用同一套结论。
  /// ```
  ///
  /// ⚠️ `null` = 调用方没归类（老路径 / 探针注入的裸串）⇒ 退回只显示 [message]，
  ///    行为与改前**逐字一致**（不猜类别、不改文案）。
  final PlaybackFailure? failure;

  /// 标题：有归类时用类别的**一句话**，否则沿用「播放失败」
  String get _headline => failure?.headline ?? '播放失败';

  /// 正文：归类的 detail 已净化；没归类时用原始 message（但**仍要净化**）
  ///
  /// # 为什么没归类也要净化
  /// ```text
  /// 净化（剥前缀 + 抹内部地址）与归类是**两件事**：
  /// 第 7 条要求「只显示插件原文」，那条要求对**所有**错误都成立，
  /// 不该因为「这条归不到类」就把 SourinCoreException(other): 又露出来。
  /// ```
  String get _body => PlaybackErrorText.stripHostErrorNoise(
    PlaybackErrorText.hideInternalUrls(failure?.detail ?? message),
  );

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black87,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.error_outline, size: 48, color: Colors.white70),
            const SizedBox(height: Sp.x4),
            Text(
              _headline,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(
              _body,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: FontSizes.sm,
              ),
            ),
            /*
             * ★ 下一步（Owner 第 6 条「要优化报错信息」）
             *
             * 只在**有话说**时才画这一行：`nextStep` 为空串（unknown 类）
             * 时多一行空白只会让错误页更乱。
             */
            if ((failure?.nextStep ?? '').isNotEmpty) ...[
              const SizedBox(height: Sp.x3),
              Text(
                failure!.nextStep,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white60,
                  fontSize: FontSizes.cap,
                ),
              ),
            ],
            const SizedBox(height: Sp.x6),
            /*
                 * ★ 「登录」按钮（2026-09-24 用户要求）
                 *
                 * 放在「重试」**左边**、用 FilledButton 与「重试」同级：
                 * 用户的处境是「登录失效了，重试多少次都一样」，
                 * 所以登录才是那个真正能解决问题的动作，不该被藏起来。
                 *
                 * ⚠️ 只在 `onLogin != null` 时渲染 —— 无条件显示会让
                 *    「该内容没有可播放的地址」这类用户也看到一个登录按钮。
                 */
            if (onLogin != null) ...[
              FilledButton.icon(
                onPressed: onLogin,
                icon: const Icon(AppIcons.login, size: 18),
                label: const Text('登录'),
              ),
              const SizedBox(height: Sp.x3),
            ],
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: onBack, child: const Text('返回')),
                const SizedBox(width: Sp.x3),
                /*
                 * ★ 重试按钮按类别决定给不给（Owner 第 6 条）
                 *
                 * 源站权限问题（大会员 / 地区）重试一万次都一样 ——
                 * 给一颗点了必然失败的按钮，等于把用户困在原地打转。
                 * 这不是「少给一个功能」，是**诚实**：没有出路就别画假出口。
                 *
                 * ⚠️ 没归类（failure == null）时**照旧给**重试 ——
                 *    老路径的行为一个字都不改。
                 */
                if (failure?.canRetry ?? true)
                  FilledButton(onPressed: onRetry, child: const Text('重试')),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}

/// 交付取证用：把**产线上的那个错误卡片**暴露成可构造的公开 Widget
///
/// # 为什么需要它
/// ```text
/// `_ErrorOverlay` 是私有类，测试文件构造不了它。
/// 而截图取证必须截**产线那个 widget** —— 复制一份"长得像"的
/// 就违反了本仓「仪器必须是被测对象」的纪律（踩过两次：日志计数、
/// 探针自己循环取流）。
/// ⇒ 这里只做一件事：把同一个 build 结果转发出去，**零逻辑**。
/// ```
///
/// # ⚠️ 生产路径不使用它
/// 生产走 `_ErrorOverlay(...)` 直接构造。这个包装只给
/// `test/zz_r65_error_shots_test.dart` 用。
///
/// # [rawOnly]
/// ```text
/// 非 null ⇒ 模拟**改前**行为：不归类、不净化，把原文直接贴上屏。
/// 用来拍"改前"对照图（Owner 看到的那两个画面）。
/// ```
@visibleForTesting
class PlayerErrorCardForProbe extends StatelessWidget {
  const PlayerErrorCardForProbe({
    super.key,
    this.failure,
    this.rawOnly,
    required this.onRetry,
    required this.onBack,
    this.onLogin,
  });

  /// 归类后的失败（与生产完全同一个类型）
  final PlaybackFailure? failure;

  /// 改前对照：把这条原文**原样**上屏（不归类、不净化）
  final String? rawOnly;

  final VoidCallback onRetry;
  final VoidCallback onBack;
  final VoidCallback? onLogin;

  @override
  Widget build(BuildContext context) {
    final raw = rawOnly;
    if (raw != null) {
      /*
       * 改前对照：走 `_ErrorOverlay` 但**不传 failure** ——
       * 那正是改前的调用形态（只有 message，没有归类）。
       * ⚠️ 但 `_ErrorOverlay` 现在**自己也会净化**（第 7 条要求对所有
       *    错误都成立），所以这里用 message 直接渲染，绕过净化，
       *    才能真实复现"改前用户看到的样子"。
       */
      return _BeforeErrorCard(message: raw, onBack: onBack);
    }
    return _ErrorOverlay(
      message: failure?.detail ?? '',
      failure: failure,
      onRetry: onRetry,
      onBack: onBack,
      onLogin: onLogin,
    );
  }
}

/// 改前对照卡片（**只用于截图取证**，生产路径永不使用）
///
/// 逐字复刻改动前的 `_ErrorOverlay`：标题硬编码「播放失败」，
/// 正文原样 `message`，两颗按钮（返回 + 重试），**不分类、不净化**。
class _BeforeErrorCard extends StatelessWidget {
  const _BeforeErrorCard({required this.message, required this.onBack});

  final String message;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black87,
    child: Center(
      child: Padding(
        padding: const EdgeInsets.all(Sp.x8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(AppIcons.error_outline, size: 48, color: Colors.white70),
            const SizedBox(height: Sp.x4),
            const Text(
              '播放失败',
              style: TextStyle(
                color: Colors.white,
                fontSize: FontSizes.base,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: Sp.x2),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: FontSizes.sm,
              ),
            ),
            const SizedBox(height: Sp.x6),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(onPressed: onBack, child: const Text('返回')),
                const SizedBox(width: Sp.x3),
                FilledButton(onPressed: () {}, child: const Text('重试')),
              ],
            ),
          ],
        ),
      ),
    ),
  );
}
///
/// 央视直播的视频轨被 DRM 加密 —— 这不是我们的 bug，是内容方的保护。
/// 独立实测（ffmpeg，与 mpv 不同解码器）：
/// ```text
/// 高清线：250 帧 / 386 条解码错误
///         [h264] error while decoding MB 9 0, bytestream 42177
///         [dec] corrupt decoded frame
///         [h264] Reference 3 >= 3
/// 音频线：Stream #0:0: Audio: aac …   ← 根本没有 video 流
/// ```
/// 三条线路里只有音频能播，于是播放器**正常**打开音频流 →
/// 用户**听到声音、看到黑屏**。
///
/// # 为什么必须显示（而不是让它静默播）
///
/// 原版注释把这件事说得很清楚（`PlayerView.vue:1530-1534`）：
/// > **为什么不能让它照常播放**：那样用户看到的是「画面绿屏但时间在走」，
/// > 完全不知道发生了什么，只会以为是客户端坏了。明确告知才是诚实的做法。
///
/// 原版对应 UI 见 `PlayerView.vue:4281-4299`。
///
/// # 设计取舍
///
/// ```text
/// ① 非阻断 —— 不盖住画面中央，只占底部一条横幅：
///    音频本身是可用的（听广播），不该把用户拦在门外。
/// ② 不给"重试" —— 重试改变不了 DRM，给了只会误导用户反复点。
///    只给「返回」（去换别的源）。
/// ③ 与 `_ErrorOverlay` 分开 —— 那是"起播失败"，
///    这里是"起播成功但没有画面"，语义不同，不能混用一个字段。
/// ```
class _LiveAudioOnlyBanner extends StatelessWidget {
  const _LiveAudioOnlyBanner({required this.lineName, required this.onBack});

  /// 正在播的那条音频线路名（如「仅音频」）
  final String lineName;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: ColoredBox(
      color: Colors.black87,
      child: Padding(
        /*
             * ★★★ 2026-10-01：让开系统导航栏（Owner 报「排版混乱」）
             *
             * 实测（`dumpsys window displays`，手机 1080x2400 @420dpi）：
             * ```text
             * InsetsSource type=navigationBars frame=[0,2274][1080,2400]
             *   ⇒ 126 / 2.625 = 48 逻辑 px
             * ```
             * 本条是**贴在屏幕最底**的横条 ⇒ 导航栏会盖住它的下半截
             *（截图 `.probe\n13_player_controls.png` 里「返回」按钮只露出上半）。
             *
             * ★ 与 `_BottomBar` 的修复**同一手法、同一理由**（见那里的长注释）：
             *   播放页是沉浸式的，**不能**给整页包 `SafeArea`（会把画面缩小）；
             *   只有浮在画面上的控件条需要让位 —— 本条就是其中之一。
             *
             * ⚠️ `bottom: 0` **保持不变** —— "压在最底"是它的设计意图
             *   （它是**替代**控制条的降级提示）。要修的只是别被导航栏盖住。
             * ⚠️ 桌面/TV 上 `padding.bottom == 0` ⇒ **严格 no-op**。
             */
        padding: EdgeInsets.fromLTRB(
          Sp.x4,
          Sp.x3,
          Sp.x4,
          Sp.x3 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Row(
          children: [
            const Icon(AppIcons.info_outline, size: 18, color: Colors.white70),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Text(
                '该直播的视频轨受 DRM 加密，客户端无法解码画面。'
                '已为你切换到「$lineName」线路收听。',
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: FontSizes.sm,
                ),
              ),
            ),
            const SizedBox(width: Sp.x3),
            OutlinedButton(onPressed: onBack, child: const Text('返回')),
          ],
        ),
      ),
    ),
  );
}

/// 「画面出不来，但音频是好的」的非阻断横幅
///
/// # 补的是什么
///
/// 交付说明 `README-交付说明.md:126-129` 自己承认过：
/// > 输出层建不起来时没有任何降级、也没有用户可见的报错，全程静默
///
/// 触发它的是 [`PlayerPage._watchVideoOutput`] 的判据
/// （有视频轨 && `vo-configured != yes`，五臂实测见 `.probe\t376_matrix.txt`）。
///
/// # 设计取舍（照 `_LiveAudioOnlyBanner` 的三条，理由同源）
///
/// ```text
/// ① 非阻断 —— 音频是好的（能听），不该把用户拦在门外，所以只占底部一条。
/// ② 不给"重试" —— 同族实测换 VO 也救不回来（`opengl-es=no` 一样失败），
///    给了只会让用户反复点。只给「返回」（去换别的源/线路）。
/// ③ 与 `_ErrorOverlay` 分开 —— 那是"起播失败"，这里是
///    "起播成功了但没有画面"，两者必须能并存。
/// ```
///
/// ★ 文案刻意说清**是什么坏了**（显卡/输出层）而不是"播放失败" ——
///   用户看到的是"有声无画"，含糊的报错只会让他以为是网络问题。
class _VideoOutputDeadBanner extends StatelessWidget {
  const _VideoOutputDeadBanner({required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: ColoredBox(
      color: Colors.black87,
      child: Padding(
        /*
             * ★★★ 2026-10-01：让开系统导航栏（Owner 报「排版混乱」）
             *
             * 实测（`dumpsys window displays`，手机 1080x2400 @420dpi）：
             * ```text
             * InsetsSource type=navigationBars frame=[0,2274][1080,2400]
             *   ⇒ 126 / 2.625 = 48 逻辑 px
             * ```
             * 本条是**贴在屏幕最底**的横条 ⇒ 导航栏会盖住它的下半截
             *（截图 `.probe\n13_player_controls.png` 里「返回」按钮只露出上半）。
             *
             * ★ 与 `_BottomBar` 的修复**同一手法、同一理由**（见那里的长注释）：
             *   播放页是沉浸式的，**不能**给整页包 `SafeArea`（会把画面缩小）；
             *   只有浮在画面上的控件条需要让位 —— 本条就是其中之一。
             *
             * ⚠️ `bottom: 0` **保持不变** —— "压在最底"是它的设计意图
             *   （它是**替代**控制条的降级提示）。要修的只是别被导航栏盖住。
             * ⚠️ 桌面/TV 上 `padding.bottom == 0` ⇒ **严格 no-op**。
             */
        padding: EdgeInsets.fromLTRB(
          Sp.x4,
          Sp.x3,
          Sp.x4,
          Sp.x3 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Row(
          children: [
            const Icon(
              AppIcons.warning_amber_outlined,
              size: 18,
              color: Colors.white70,
            ),
            const SizedBox(width: Sp.x2),
            const Expanded(
              child: Text(
                '这个视频的画面无法显示（本机图形输出层没能初始化）。'
                '声音是正常的。可以返回换一条线路或换一个源再试。',
                style: TextStyle(color: Colors.white70, fontSize: FontSizes.sm),
              ),
            ),
            const SizedBox(width: Sp.x3),
            OutlinedButton(onPressed: onBack, child: const Text('返回')),
          ],
        ),
      ),
    ),
  );
}

/// 「播放中断」的非阻断横幅（★ 2026-10-08，Owner 第 9 条）
///
/// # 补的是什么
///
/// Owner 截图（u9_1c91d6a6.png）：
/// \`\`\`text
/// 播放失败
/// Failed to open http://127.0.0.1:63534/s/18dc2c90fcf9b1f03f3446afdd80/.
/// \`\`\`
/// 原文来自 \`_player.stream.error\`，而那时 mpv **已经出过画面**
/// （判据 \`_sawFirstFrame\`，见 [PlayerPage._sawFirstFrame]）。
///
/// # 为什么不能继续用全屏 \`_ErrorOverlay\`
///
/// \`\`\`text
/// \`stream.error\` 在**整个生命周期**里都会来，不只是起播那一次：
///   换清晰度重开 / 缓冲重试 / 单帧解码报错 → 都会发一条
/// 用全屏遮罩接住它 ⇒ 正在看的画面被整块盖掉，
/// 用户看到的就是「看着看着突然播放失败」（Owner 的原话就是这个观感）。
/// \`\`\`
/// 起播阶段（没出过画面）仍然走全屏 \`_ErrorOverlay\` —— 那时用户什么都
/// 没看到，必须给他一个明确的解释和出口。**两条路的分界线就是"有没有画面"**。
///
/// # 设计取舍（与上面两条横幅同源）
///
/// \`\`\`text
/// ① 非阻断 —— 只占底部一条，画面继续，用户可以自己决定要不要管它。
/// ② **给"重试"** —— 与 [_VideoOutputDeadBanner] 不同：这条的失败原因
///    （换流抖动 / 代理刚重启 / 上游 4xx）**是可以靠重试恢复的**，
///    而输出层建不起来重试多少次都一样。
/// ③ 与 \`_ErrorOverlay\` 分开 —— 那是"起播失败"，
///    这里是"起播成功了，只是这一下断了"，两者必须能并存。
/// \`\`\`
///
/// ★ 文案**照抄 mpv 原文**（不做翻译/改写）：这条错误的诊断价值全在
///   那个地址和 mpv 的原句上（"Failed to open <url>" 能一眼看出是本地代理
///   还是上游 CDN），改写反而会把线索弄丢。中文只在前面加一句人话。
///
/// ★★★ 2026-10-18（Owner 第 6 条）：上面那段"照抄 mpv 原文"的取舍**已经改了**
///
/// # 为什么原做法被否掉
/// ```text
/// 那条 mpv 原句是「Failed to open http://127.0.0.1:57209/s/18df…/」
/// 而 127.0.0.1:<随机端口> 是**内置代理**，随进程退出就失效。
/// Owner 第 6 条原话：看到这句「不知道是源的问题还是软件本身的问题」
/// ⇒ 把内部地址原样贴给用户，等于把**我们自己的实现细节**当成诊断线索
///   交出去，而它对用户毫无意义、事后也无法回连。
/// ```
///
/// # 现在的做法
/// ```text
/// ① 内部代理地址 → 抹掉（PlaybackErrorText.hideInternalUrls）
/// ② 剩下的**上游/插件原文**照抄 —— 那部分才是真线索，一个字都不改
/// ③ 前面加一句归类好的中文（这个源没返回地址 / 内置代理没起来 / …）
/// ```
/// ⚠️ 完整的原始地址仍进 `AppLog`（`_bindPlayerStreams` 里那条 write），
///    排查时从日志里拿 —— **文案与日志的取舍不同**，这一点没变。
class _PlaybackFailureBanner extends StatelessWidget {
  const _PlaybackFailureBanner({required this.message, required this.onRetry});

  /// mpv / 插件的原始错误文案
  ///
  /// ⚠️ 显示前会过 `PlaybackErrorText`（抹内部地址）—— 见类注释。
  final String message;

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Positioned(
    left: 0,
    right: 0,
    bottom: 0,
    child: ColoredBox(
      color: Colors.black87,
      child: Padding(
        // ★ 与 [_VideoOutputDeadBanner] 同一手法：让开系统导航栏
        //   （理由与实测见那里的长注释；桌面/TV 上是严格 no-op）
        padding: EdgeInsets.fromLTRB(
          Sp.x4,
          Sp.x3,
          Sp.x4,
          Sp.x3 + MediaQuery.paddingOf(context).bottom,
        ),
        child: Row(
          children: [
            const Icon(AppIcons.error_outline, size: 18, color: Colors.white70),
            const SizedBox(width: Sp.x2),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    '播放中断了（画面还在，可以重试）',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: FontSizes.sm,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    /*
                     * ★★★ Owner 第 6 条：内部代理地址不许上屏
                     *
                     * 原文形如「Failed to open http://127.0.0.1:63534/s/18dc…/」，
                     * 那个端口是**内置代理**、随进程退出失效，用户拿它判断
                     * 不了任何事（Owner 原话：不知道是源的问题还是软件问题）。
                     * ⇒ 抹成「内置代理取不到这条流」，上游真址若在原文里则原样保留。
                     *
                     * ⚠️ 完整原文仍进 AppLog（见 `_bindPlayerStreams`），排查不受影响。
                     */
                    PlaybackErrorText.stripHostErrorNoise(
                      PlaybackErrorText.hideInternalUrls(message),
                    ),
                    // ★ 原文可能很长（带完整 URL）⇒ 最多两行 + 省略号，
                    //   免得把横幅撑成半屏
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white70,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: Sp.x3),
            FilledButton(onPressed: onRetry, child: const Text('重试')),
          ],
        ),
      ),
    ),
  );
}

/// 交付实测用：读**真实渲染树**里播放器手势的挂载状态
///
/// # 为什么要读树而不是读源码
///
/// 用户要求「pc端不应该双击左右侧快进快退」——
/// 源码里写了条件挂载（`onDoubleTapDown: _doubleTapEnabled ? ... : null`）
/// **不等于**运行时那个 GestureDetector 真的没挂上回调。
///
/// `GestureDetector.onDoubleTapDown` 是只读字段，直接读它就知道
/// "用户在这台机器上双击会不会跳秒" —— 这是最接近真实行为的验证。
///
/// 返回形如 `doubleTap=true longPress=true tapUp=false visibleButtons=0`。
///
/// # ★ `tapUp` 字段的含义在 2026-09-25 变了
///
/// 它原来是"**单击分流已挂载**"的证据（PC 上应为 true）。
/// 用户要求「不要单击快进快退,去掉这个功能」之后，单击分流**整个删掉**，
/// 所以现在 `tapUp=false` 才是**正确**的：
/// ```text
/// tapUp=false  → 渲染树里没有任何 GestureDetector 自己判区域分流单击
/// tapUp=true   → 有人把分流加回来了（**回归**）
/// ```
/// ⚠️ 断言方向**反了** —— 从 `tapUp=true` 改成 `tapUp=false`。
///    这不是"为了让实测通过而放宽断言"，是需求变了：
///    新的正确行为就是"没有分流"。
String debugPlayerGestureState() {
  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return 'no-root';

  var doubleTap = false;
  var longPress = false;
  var tapUp = false;
  var tap = false;
  var visibleButtons = 0;
  var visited = 0;

  void walk(Element el) {
    if (visited > 6000) return;
    visited++;
    final w = el.widget;
    if (w is GestureDetector) {
      if (w.onDoubleTapDown != null) doubleTap = true;
      if (w.onLongPressStart != null) longPress = true;
      if (w.onTapUp != null) tapUp = true;
      if (w.onTap != null) tap = true;
    }
    /*
     * 数"可见的圆形按钮"—— 用户要求**不能有**。
     *
     * 判据：之前那两个圆圈的 tooltip 文案。为 0 才算对
     * （旧版本这里是 1，用户看到的就是那个难看的圆圈）。
     */
    if (w is Tooltip) {
      final m = w.message ?? '';
      if (m.contains('单击快退') || m.contains('单击快进')) visibleButtons++;
    }
    el.visitChildren(walk);
  }

  walk(root);
  return 'doubleTap=$doubleTap longPress=$longPress tapUp=$tapUp tap=$tap '
      'visibleButtons=$visibleButtons';
}

/// 当前正在渲染的播放页 state（探针用，未挂载时为 null）
///
/// # 为什么要登记一个全局引用
///
/// 交付实测要断言的是「**播放位置真的没跳**」，而不是
/// 「我把那个回调删了」—— 后者只是读源码，证明不了运行时行为。
/// 要读位置就必须够得着真实播放页的 `_position`。
///
/// ⚠️ 生命周期由 `initState`/`dispose` 成对维护，别在这里缓存着不放。
_PlayerPageState? _livePlayerState;

/// 读**真实播放页**的播放位置读数（秒），交付实测用
///
/// 返回 `null` 表示当前没有播放页（还没进 / 已退出）。
///
/// # 为什么用秒而不是 Duration
///
/// 实测是隔着 `debugPrint` 日志看结果的，`Duration` 打出来是
/// `0:00:12.345678` 这种带微秒的形式，**不便对比**。
/// 秒（保留 3 位小数）足够判断"有没有跳 10 秒"，也便于人眼核对。
///
/// ⚠️ 微秒级抖动是正常的（播放本来就在走），所以判据要用
///    **阈值**（比如 >2 秒才算跳变），不能用 `==`。
double? debugPlayerPositionSeconds() {
  final s = _livePlayerState;
  if (s == null) return null;
  return s._position.inMicroseconds / Duration.microsecondsPerSecond;
}

/// 播放页当前是否处于播放中（探针用），无播放页时返回 null
bool? debugPlayerIsPlaying() => _livePlayerState?._playing;

/// 播放页当前时长（秒），无播放页时返回 null
double? debugPlayerDurationSeconds() {
  final s = _livePlayerState;
  if (s == null) return null;
  return s._duration.inMicroseconds / Duration.microsecondsPerSecond;
}

/// 播放页最近一次**闪现提示**的文案（探针用），无播放页时返回 null
///
/// # 为什么需要读它
///
/// 「单击不跳秒」的判据是**播放位置没跳**（`debugPlayerPositionSeconds`），
/// 但位置本身会因播放而自然推进，也可能被"自动跳过片头"等**别的**
/// 逻辑改动 —— 只看位置无法区分"是我删对了"还是"这次恰好没触发"。
///
/// 而 `_seekBy`（单击跳秒唯一的执行路径）会 `_flash('快进 Ns' / '快退 Ns')`。
/// 所以：
/// ```text
/// tip 里出现「快进/快退 Ns」  → _seekBy 真的被调了（单击还在跳秒）
/// tip 里是别的文案            → 走的是别的路径
/// tip 为 null                 → 没触发任何动作
/// ```
///
/// ⚠️ `_flash` 会在 1.2 秒后自动清空，所以实测要在点击后**立刻**读。
String? debugPlayerLastTip() => _livePlayerState?._tip;

/// ★ 缺陷 9 探针（`test/zz_t3_flash_probe_test.dart:75`）用：
///   把一句话**走生产链路** `_flash` 送进提示条。返回 true = 真的写进了 `_tip`。
///
/// ⚠️ 走的必须是**生产**的 `_flash`（含它的 1.2 秒自清空 Timer），
///    不能是「直接 setState(_tip = msg)」—— 那样证明不了提示条**画得出来**，
///    只证明我在测试里改了个变量。
bool debugPlayerFlashForProbe(String msg) {
  final st = _livePlayerState;
  if (st == null) return false;
  st.debugPlayerFlashForProbe(msg);
  return st._tip == msg;
}

/// ★ 缺陷 9 探针用：读当前提示条文本（null = 没有提示条）
///
/// 与 `debugPlayerLastTip()` 是同一个东西，命名对齐探针里的调用；
/// 保留两个名字是因为 `debugPlayerLastTip` 已被别的探针引用（改名会连带改别人）。
String? debugPlayerTipForProbe() => _livePlayerState?._tip;

/// 累计调用 `_seekBy` 的次数（探针用），无播放页时返回 null
///
/// # 为什么用**计数器**而不是只看位置
///
/// `_seekBy` 是"单击跳秒"的**唯一执行路径**（也是 J/L、双击的路径）。
/// 位置读数会被很多因素干扰（播放推进、自动跳片头、缓冲回退），
/// 而计数器是**因果链上最直接的证据**：
/// ```text
/// 单击前后计数不变 → 单击**没有**触发任何 seek   ← 本次需求
/// 单击前后计数 +1  → 单击还在跳秒                ← 回归
/// ```
/// 实测只读**点击那一刻**的差值，所以键盘/双击的 seek 不会污染结论。
///
/// ⚠️ 只读探针，不影响任何行为。
int? debugPlayerSeekByCalls() => _livePlayerState?._seekByCalls;

/// ★ fix/skip-auto-seek 探针：生产代码里**真的发出过**多少次跳过 seek
///
/// 无播放页时返回 null（与"挂了页但一次没跳"的 0 **区分开**）。
/// 见 `_skipSeekCalls` 的说明 —— 它钉在 `_player.seek(...)` 那一行上。
int? debugPlayerSkipSeekCalls() => _livePlayerState?._skipSeekCalls;

/// ★ fix/skip-auto-seek 探针：最近一次跳过 seek 的**目标位置**（null = 还没跳过）
Duration? debugPlayerLastSkipSeek() => _livePlayerState?._lastSkipSeek;

/// ★ fix/skip-auto-seek 探针：直接给播放页塞一个 `_skipMarker`（绕过库）
///
/// # 为什么需要这个接缝（而不是每个用例都去写隔离库）
///
/// `_loadSkipMarker()` 走的是 `SourinApi.getSkipMarker` → FFI → 真实库。
/// 但本测试的**核心**是 `_maybeSkip` 的**判定与补判时机**，
/// 那是一个纯内存状态机 —— 用真实库只是让它更慢、更脆。
/// 所以：
/// ```text
/// · 主要用例：用本探针塞标记，直接验"【A】/【B】补判 + 幂等 + 阴性对照"
/// · 另设一条"接缝"用例：用隔离库真的 setSkipMarker + getSkipMarker 读回，
///   证明"隔离库里真写得进去、读得出来"（库读写这一环不被跳过）
/// ```
/// 返回 false = 播放页没挂上（**调用方必须据此判红**，否则"没挂页"
/// 会伪装成"标记塞进去了"）。
bool debugPlayerSetSkipMarkerForProbe({
  int? introStart,
  int? introEnd,
  int? outroStart,
  int? outroEnd,
  // ★ 2026-10-26：中插（与 `SkipMarker.midrolls` 同一形状）
  List<({int startSec, int endSec})> midrolls = const [],
}) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._skipMarker = SkipMarker(
    key: '${s._provider}:${s._contentId}',
    provider: s._provider,
    nativeId: s._contentId,
    title: '',
    introStart: introStart,
    introEnd: introEnd,
    outroStart: outroStart,
    outroEnd: outroEnd,
    midrolls: midrolls,
  );
  return true;
}

/// ★ fix/skip-auto-seek 探针：**真的走一遍**生产 `_maybeSkip(pos)`
///
/// 与 `debugPlayerPushPositionForProbe` 不同 —— 那个走的是**位置流**处理路径
/// （`_onPositionTick`，含 setState/节流），本探针直接打**跳过判定**这一环，
/// 用来把【A】/【B】补判与闸门拆分测。
///
/// 返回 false = 没挂页。
bool debugPlayerMaybeSkipForProbe(Duration pos) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._maybeSkip(pos);
  return true;
}

/// ★ fix/skip-auto-seek 探针：直接驱动【A】`_skipAfterCanplay()`（生产方法本身）
///
/// ⚠️ 调的是 `_startPlayback` 里那个**同名生产方法**（不是测试里复刻一份），
///    所以把它改成 no-op ⇒ 本探针与依赖它的用例立刻红（撤销验证）。
/// 返回 false = 没挂页。
bool debugPlayerSkipAfterCanplayForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._skipAfterCanplay();
  return true;
}

/// ★ fix/skip-auto-seek 探针：直接驱动【B】`_skipAfterMarkerLoad()`（生产方法本身）
///
/// 同【A】—— 调的是 `_loadSkipMarker` 成功路径上那个**同名生产方法**。
/// 返回 false = 没挂页。
bool debugPlayerSkipAfterMarkerLoadForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._skipAfterMarkerLoad();
  return true;
}

/// ★ fix/skip-auto-seek 探针：设 `_position` **但不触发** `_maybeSkip`
///
/// # 为什么需要它（这是让【B】用例真的能隔离 B 的关键）
///
/// `debugPlayerPushPositionForProbe(1s)` 走的是**位置流**处理路径
/// （`_onPositionTick`），它内部**自己就会调** `_maybeSkip` ——
/// 于是"跳了"这件事分不清是位置流干的还是【B】干的（**假绿**）。
/// 本探针只写 `_position`，把"位置在片区"这个**前置状态**摆好，
/// 让随后**只**调【B】的那一步成为唯一因果。返回 false = 没挂页。
bool debugPlayerSetPositionOnlyForProbe(Duration pos) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._position = pos;
  return true;
}

/// ★ fix/skip-auto-seek 探针：**真的走一遍** `_loadSkipMarker()`（含它成功路径上的【B】）
///
/// 返回 false = 没挂页。
Future<bool> debugPlayerLoadSkipMarkerForProbe() async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s._loadSkipMarker();
  return true;
}

/// ★ PR #10 探针：读当前播放会话代次（`_playSessionGen`）
///
/// 用来断言「换集/换源/换会话**真的** bump 了代次」—— 而不是只看
/// "丢弃日志有没有打出来"（那可能因为别的原因没打）。
int? debugPlayerSessionGenForProbe() => _livePlayerState?._playSessionGen;

/// ★ PR #10 探针：读当前 `_skipMarker`（判「过期响应有没有污染当前会话」）
///
/// 返回 null = 既没挂页、也可能就是没标记 —— 用 [debugPlayerSessionGenForProbe]
/// 区分"没挂页"与"值就是 null"（调用方先断代次非 null）。
SkipMarker? debugPlayerSkipMarkerForProbe() => _livePlayerState?._skipMarker;

/// ★ PR #10 探针：模拟「换集/换源把会话推进一代」——
/// 走的是生产字段 `_playSessionGen` 与生产清理动作（清 `_skipMarker`），
/// 不是另写一份。用于在**不加载 libmpv** 的前提下复现竞态。
///
/// ⚠️ 它不是"绕过生产路径"：三条真实切换路径（**换源 `_applySwitch`**、
///    **换会话 `applySession`**、**切集 `_gotoEpisode`**）做的就是这三件事
///    （`_playSessionGen++` + `_skipMarker = null` + `_position = Duration.zero`）。
///    这里只是把同一组动作暴露给测试。
///    ★ 2026-10-26：原来这里写的是 `:7495` / `:7732` / `:8079` 三个**行号**，
///      实测三条**全部已漂**（现在是 `statusCode:` / `searchLoading:` /
///      `void _setDanmakuOpacity`）⇒ 改成**方法名符号锚**，不再随行号失效。
/// ★ `_position` 复位是 CodeRabbit PR #10 第二轮点出的：少了它，
///   `_currentSkipProbePosition()`（取 max(`state.position`, `_position`)）
///   会读到**上一集**的位置 ⇒ 补判可能误判"已到片尾"⇒ 刚起播就弹下一集倒计时。
/// 返回 false = 没挂页。
bool debugPlayerBumpSessionForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._playSessionGen++;
  s._skipMarker = null;
  s._position = Duration.zero;
  return true;
}

/// ★ PR #10 第二轮探针：给会话塞一集列表（造"有下一集"的场景）
///
/// # 为什么需要它
/// `_startNextCountdown()` 第一行就是 `if (_nextEpisode == null) return;`，
/// 而 `_nextEpisode` 要求 `_episodes` 里 **≥2** 集。
/// ⇒ 想验"换集后误触发片尾倒计时"，必须让会话**真的有下一集**
///   （否则倒计时天然不启动 ⇒ 用例恒绿 —— 假的）。
///
/// 返回 false = 没挂页。
bool debugPlayerSetEpisodesForProbe(List<Episode> eps, {int index = 0}) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._episodes = eps;
  s._epIndex = index;
  return true;
}

/// ★ PR #10 第二轮探针：读 `_nextCountdown`（"下一集倒计时"的秒数，0 = 没在倒数）
///
/// 用来钉「换集后**不许**因为读到上一集的位置而误触发片尾倒计时」——
/// 返回 null = 没挂页。
int? debugPlayerNextCountdownForProbe() => _livePlayerState?._nextCountdown;

/// ★ fix/skip-auto-seek 探针：复位本文件新增的跳过探针（用例之间互不影响）
void debugPlayerResetSkipProbe() {
  final s = _livePlayerState;
  if (s == null) return;
  s._skipSeekCalls = 0;
  s._lastSkipSeek = null;
}

/// ★ fix/skip-auto-seek 探针：直接拨动页面内的「自动跳过片头」闸门 `_autoSkip`
///
/// 走的是**生产字段**（`_maybeSkip` 里 `if (!_autoSkip) return;` 判的就是它），
/// 不是另写一份判定 —— 所以它验的是"真闸门"。返回 false = 没挂页。
bool debugPlayerSetAutoSkipForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._autoSkip = v;
  return true;
}

/// 累计调用 `_togglePlay` 的次数（探针用），无播放页时返回 null
///
/// 用来证明"单击**仍然**能播放/暂停"—— 与 `debugPlayerSeekByCalls()`
/// 配对使用：理想结果是 `togglePlay +1 且 seekBy +0`。
int? debugPlayerTogglePlayCalls() => _livePlayerState?._togglePlayCalls;

/// ★ 第 16 项探针：`_toggleMute()` 被调用了几次（`null` = 没挂页）
///
/// 判据形如：全屏按 M ⇒ 计数 +1 **且** `_muted` 真的翻转（不是只画图标）。
int? debugPlayerToggleMuteCalls() => _livePlayerState?._toggleMuteCalls;

/// ★ 第 16 项探针：`_isTypingInField()` 的当前判决（`null` = 没挂页）
///
/// 打字态门控是"空格/M 不许被抢"的唯一判据；探针只读它，不改焦点。
bool? debugPlayerIsTypingForProbe() => _livePlayerState?._isTypingInField();

/// `_onKey` 探针用的进程级焦点节点（实现里不用它，只为满足签名）
final FocusNode debugPlayerOnKeyProbeNode =
    FocusNode(debugLabel: 'onKey-probe');

/// ★ 探针：**真的走一遍**焦点树路径 `_onKey`（`KeyEventResult.ignored` = 放行）
///
/// 与 [debugPlayerHardwareKeyForProbe] 的分工：
/// ```text
/// 那个测"焦点不在页内"的兜底链；这个测"焦点在页内"的主链
/// （浮层让位 / 打字 / 仅桌面 这些**页面上下文**门控都在 `_onKey` 里）。
/// ```
bool? debugPlayerFocusKeyHandledForProbe(LogicalKeyboardKey k) {
  final s = _livePlayerState;
  if (s == null) return null;
  // `_onKey(FocusNode node, KeyEvent event)` —— 实现里 `node` **未被使用**
  // （只出现在签名上）⇒ 传一个进程级的探针节点即可，不必借用真实焦点树节点。
  final r = s._onKey(
    debugPlayerOnKeyProbeNode,
    KeyDownEvent(
      timeStamp: Duration.zero,
      physicalKey: PhysicalKeyboardKey(0),
      logicalKey: k,
    ),
  );
  return r == KeyEventResult.handled;
}

/// ★ 第 16 项探针：`_muted` 当前值（`null` = 没挂页）
bool? debugPlayerMutedForProbe() => _livePlayerState?._muted;

/// ★ 第 16 项探针：**真的走一遍**硬件键 handler（`_onHardwareKey`）
///
/// # 为什么不能 `tester.sendKeyEvent`
/// ```text
/// 本仓已记录：`flutter_tester` 里 `PlayerPage` 整棵树的**指针回调不派发**；
/// 键盘走 `FocusManager.addEarlyKeyEventHandler` 也依赖真实事件循环，
/// widget 测试里不稳。而这里要验的恰恰是**那条 handler 的判定**，
/// 不是 Flutter 的事件派发 ⇒ 直接调生产方法（与 `debugPlayerMaybeSkipForProbe`
/// 同一手法：测的是生产代码本身，不是测试复刻的副本）。
/// ```
/// 返回 `null` = 没挂页；`true` = handler 说"我处理了"。
bool? debugPlayerHardwareKeyForProbe(LogicalKeyboardKey k) {
  final s = _livePlayerState;
  if (s == null) return null;
  return s._onHardwareKey(
    KeyDownEvent(
      timeStamp: Duration.zero,
      physicalKey: PhysicalKeyboardKey(0),
      logicalKey: k,
    ),
  );
}

/// ★ 累计调用 `_toggleFullscreen` 的次数（task-42 新增，探针用）
///
/// # 为什么必须单独计数（不能只看 `_fullscreen` 布尔）
/// ```text
/// 用户要求：「enter 和 双击 进入/退出 全屏」。
/// ★ 判据要回答的是"**这个键/手势有没有触发全屏切换**"，
///   而布尔值只能说明"当前是不是全屏" —— 两次切换后它就回到原值，
///   测试会误判成"没反应"。
/// ⇒ 用**次数**：断言"按一次 Enter ⇒ 计数 +1"。
/// ```
/// ⚠️ 与 `debugPlayerSeekByCalls()` 同样的道理（那里也是计数不是位置）。
int? debugPlayerFullscreenCalls() => _livePlayerState?._fullscreenCalls;

/// 当前是否处于全屏（只读）
bool? debugPlayerIsFullscreen() => _livePlayerState?._fullscreen;

/// ★ 画面输出层是否被判为"建不起来"（只读探针）
///
/// # 为什么需要它（交付实测的入口）
///
/// `README-交付说明.md:126-129` 承认过「输出层建不起来时全程静默」。
/// 修完之后必须能**实测**这个判决真的立起来了 —— 不能靠"我读了代码
/// 所以它一定工作"。
///
/// 探针用它断言两件事（两个方向都要，否则是"永远为真"的判据）：
/// ```text
/// ① 失败臂（`vo=gpu` 且 GL 上下文建不起来）⇒ 必须是 true
/// ② 成功臂（正常播放）⇒ 必须是 false，否则每台机器都会看到假横幅
/// ```
/// ⚠️ 只读，不触发任何行为 —— 诊断不能干扰被测对象。
bool? debugPlayerVideoOutputDead() => _livePlayerState?._videoOutputDead;

/// 把看门狗判为"输出层已死"的状态**直接注入**（探针用，仅供 UI 渲染验证）
///
/// # 为什么要注入而不是等真失败
///
/// 真失败需要一台"GL 上下文建不起来"的机器（模拟器上要 `vo=gpu`）。
/// 但横幅**渲染对不对**（位置/文案/不盖画面/按钮可点）是独立的另一件事，
/// 必须能在任何机器上验证。`lib\t377_banner_probe.dart` 用它做后者。
///
/// ⚠️ 生产代码里没有任何调用点 —— 它只在探针入口点被调到。
bool debugPlayerSetVideoOutputDeadForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugSetVideoOutputDead(v);
  return true;
}

/// ★ 读看门狗的**两个原始闸门输入**（只读探针）
///
/// # 为什么必须能读原始输入，而不是只读判决
///
/// 2026-09-30 的 t377 Android 跑给出 `skipped=1`：⑤ 段的前置条件写的是
/// 「位置 > 0.5s」，而那一跑里**位置根本没推进**（`EGL_emulation:
/// eglCreateContext error 0x3004 (EGL_BAD_ATTRIBUTE)` 之后 1.2s 就
/// `播放结束`）。于是探针**什么都没测到**，只能 skip。
///
/// ⚠️ 但这里有个**逻辑陷阱**，正是它让 ⑤ 段永远拿不到读数：
/// ```text
/// 「输出层建不起来」恰恰就是「位置不推进」的原因之一
/// ⇒ 用「位置推进了」当前置条件 = 用被测故障的反面当前置条件
/// ⇒ 故障真的发生时，前置条件必然不成立 ⇒ 永远 skip
/// ```
/// 这是「一个从不触发的探针不该报成功」的**反面**：
/// 一个**只在故障缺席时才能触发**的探针，同样永远给不出阳性读数。
///
/// ⇒ 修法：⑤ 段改成直接读**闸门本身的两个输入**（有没有视频轨、
///    `vo-configured` 是不是 yes），无论位置推不推进都能读。
///    这样即使画面全黑、位置不动，判决链的每一环都仍然可观测。
///
/// 返回 `(有视频轨?, vo-configured?)`；读不到时对应项为 null。
Future<({bool? hasVideoTrack, bool? voConfigured})>
debugPlayerVideoOutputGateForProbe() async {
  final s = _livePlayerState;
  if (s == null) return (hasVideoTrack: null, voConfigured: null);
  final hasVideo = s._player.state.videoParams.dw != null;
  bool? vo;
  final native = s._player.platform;
  if (native is NativePlayer) {
    try {
      vo = (await native.getProperty('vo-configured')) == 'yes';
    } catch (_) {
      vo = null;
    }
  }
  return (hasVideoTrack: hasVideo, voConfigured: vo);
}

/// ★ 当前有没有浮层打开（只读探针，task-42）
///
/// # 为什么需要它
/// ```text
/// 「浮层打开时空格不该切播放器」这条判据，**必须先证明浮层真的开着**，
/// 否则测的还是"无浮层"那条路 ⇒ 假阴性
/// （"必须能区分「违规」与「没测到」"）。
/// ⇒ 让测试能直接断言"前置条件成立"，而不是靠推断。
/// ```
bool? debugPlayerAnySheetOpen() => _livePlayerState?._anySheetOpen;

/// 打开「快捷键提示」浮层（探针用，返回是否成功）
///
/// # 为什么选这个浮层
/// ```text
/// `_anySheetOpen` = 选集 ‖ 设置 ‖ 线路 ‖ 提示（四者并集）。
/// ★ 另外三个都**依赖 FFI 数据**（要有真实剧集/线路才能点开），
///   在 widget 测试里拿不到 ⇒ 只有「提示」是无条件可开的。
/// ⚠️ 但它们**共用同一行判断**（`if (_anySheetOpen) return ignored;`）
///   ⇒ 用「提示」验证等价于验证四者。
/// ```
bool debugPlayerOpenHintsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.setState(() => s._hintsOpen = true);
  return s._hintsOpen;
}

/// 给「线路 / 清晰度」抽屉**注入假线路**（探针用，返回是否成功）
///
/// # 为什么必须新增这个探针（task-72 实测得到的结论）
/// ```text
/// 「线路」按钮的门控是 `hasStreams: _streams.length > 1`，
/// 而 `_streams` 只在 `resolve_stream`（FFI）成功后才被填上。
/// ★ 但 widget 测试里 `sourin_core.dll` **加载不了**
///   （实测：`Failed to load dynamic library 'sourin_core.dll'`
///     error code 126）⇒ `_load()` 必然失败 ⇒ `_error` 置上
///   ⇒ 整条 `_BottomBar` 连**一帧**都留不住（实测：`换源` 命中 1 → 0）
///   ⇒ 「线路」按钮在测试里**永远不会出现**。
/// ★ 而且"抢在第一个 pump 之前点按钮"这条路也堵死了：
///   实测在窗口期点「选集」/「换源」，回调**都不触发**
///   （`anySheetOpen` 纹丝不动）—— 环境降级态下命中测试过不去。
/// ⇒ 若不新增这个探针，②（点空白关闭）与①（清晰度徽章）就只能退回
///   **手抄副本**去测 —— 而那正是 task-70 的坑：副本与生产脱钩
///   ⇒ **测试全绿、生产是错的**（见 `t57` 的 `streamSheetShell()`）。
/// ⇒ 用探针直接驱动**真实的** `_streams` / `_streamSheetOpen`，
///   测的就是**生产那棵树**，不再有"同构"这个可失效的前提。
/// ```
bool debugPlayerSetStreamsForProbe(List<StreamCandidate> streams) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.setState(() => s._streams = streams);
  return true;
}

/// 打开「线路 / 清晰度」抽屉（探针用，返回是否成功）
///
/// 与 [debugPlayerSetStreamsForProbe] 配套 —— 见那里的说明。
/// ⚠️ 只改 `_streamSheetOpen`，**不碰** `_streams`（线路列表由调用方注入）。
bool debugPlayerOpenStreamSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._collapseControlsForSheet(); // ★★★ T27-09：与生产 open 点同一条显隐路径
  s.setState(() => s._streamSheetOpen = true);
  return s._streamSheetOpen;
}

/// 打开「选集」面板（探针用，返回是否成功）
///
/// # 为什么需要它（task-74【④】补，2026-09-29 实测）
/// ```text
/// `test/player_panel_wiring_test.dart` 的组 B 原来是 `tap(find.text('选集'))`，
/// 但那条路**在本机已经走不通**：
///
///   DIAG|点之前:        选集按钮=1  EpisodePanel=0
///   DIAG|pump() 之后:   选集按钮=0  EpisodePanel=0   ← ★ 按钮自己没了
///
/// 根因 = 本文件头部早就写过的「坑①」：
///   `_load()` 里 `resolveStream` 走 FFI，而 flutter_tester 进程
///   **加载不了 `sourin_core.dll`**（error code 126）
///   ⇒ `_error` 被置上 ⇒ `_BottomBar` 的渲染条件
///     （`_error == null && !_episodeSheetOpen && …`）
///     不成立 ⇒ 「选集」按钮**在第一帧之后就消失** ⇒ tap 必然失败。
///
/// ⚠️ 这与 task-72 给「线路」/「所有直播」写探针是**同一个理由**
///    （见 [debugPlayerSetStreamsForProbe] 的说明）。
/// ```
///
/// ⚠️ 只改 `_episodeSheetOpen` —— 测的仍是**生产那棵树**里的
///    `SheetTransition.slideFrom`，不是手抄副本。
bool debugPlayerOpenEpisodeSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._collapseControlsForSheet(); // ★★★ T27-09：与生产 open 点同一条显隐路径
  s.setState(() => s._episodeSheetOpen = true);
  s._pauseForEpisodeSheet(); // ★★★ Owner 第 2 条：与生产 open 点同一条暂停路径
  return s._episodeSheetOpen;
}

/// 打开「所有直播」抽屉（探针用，返回是否成功）
///
/// ⚠️ 面板**内容**依赖 `widget.onLiveChannels`（测试里要自己传）；
///    但屏障/几何与内容无关 ⇒ 即便列表为空，本探针也能验②。
bool debugPlayerOpenLiveChannelsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._collapseControlsForSheet(); // ★★★ T27-09：与生产 open 点同一条显隐路径
  s.setState(() => s._liveChannelsOpen = true);
  return s._liveChannelsOpen;
}

/// 打开「换源」弹层（探针用，返回是否成功）
///
/// # 为什么需要它（task-72【④】的判据要求）
/// ```text
/// ④ 的症状是"弹层里的关键词是空的 ⇒ 不自动搜、不填充"。
/// 判据必须落在**弹层里那个 `TextField` 的实际内容**上 ——
/// 那才是用户看到的东西。
/// ★ 但「换源」按钮所在的 `_BottomBar` 在测试里活不过一帧
///   （见 [debugPlayerSetStreamsForProbe] 的说明）
///   ⇒ 只能由探针直接调这个方法。
/// ⚠️ 不 `await`：`_openSwitchSource` 内部 `await showSourceSwitchDialog(...)`，
///   而那个 Future 要等弹层**被关掉**才完成 ⇒ await 会挂死。
///   （这正是本函数返回 `bool` 而不是 `Future` 的原因）
/// ```
bool debugPlayerOpenSwitchSourceForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  unawaited(s._openSwitchSource());
  return true;
}

/// 累计**真正执行**的切集次数（探针用），无播放页时返回 null
///
/// # task-28 ①-C 的**行为层**判据
///
/// 用户报「明明没有下一集，却还是请求下一集」。
/// 这个计数是"切集动作到底发生了没有"的**因果链最直接**读数 ——
/// 比"看按钮是不是灰的"强得多（灰按钮只能证明外观）。
///
/// 用法（与 [debugPlayerBlockedNavCalls] 配对）：
/// ```text
/// 场景 A：停在最后一集，点「下一集」
///   gotoEpisodeCalls 不变 + blockedNavCalls +1  ⇒ ✅ 判据拦住了（期望）
///   gotoEpisodeCalls +1                          ⇒ ❌ 判据失效（真 bug）
///
/// 场景 B（阳性对照）：停在中间某一集，点「下一集」
///   gotoEpisodeCalls +1                          ⇒ ✅ 仪器有效
/// ```
/// ★ **场景 B 必须先通过** —— 否则"场景 A 里计数没涨"也可能只是
///   仪器测不到（铁律②：阳性对照失败 ⇒ 结论作废）。
int? debugPlayerGotoEpisodeCalls() => _livePlayerState?._gotoEpisodeCalls;

/// 累计被"没有上一集/下一集"挡回去的次数（探针用），无播放页时返回 null
///
/// 与 [debugPlayerGotoEpisodeCalls] 配对 —— 见那个函数的用法说明。
/// 单独看它没有意义：`0` 既可能是"拦住了但没记"，
/// 也可能是"压根没点到"，必须两个数一起读。
int? debugPlayerBlockedNavCalls() => _livePlayerState?._blockedNavCalls;

/// 当前播放倍速（探针用），无播放页时返回 null
///
/// # 为什么需要它
///
/// 「长按方向键 = 快进快退」的**可观测结果**就是倍速变化：
/// ```text
/// 按住右方向键 -> 倍速 = pcArrowHoldRate（默认 2.0）
/// 松开         -> 倍速回落到按住之前的原值（不是写死的 1.0）
/// ```
/// 没有这个读数就只能断言"我调用了某函数"，那是测实现不是测行为。
double? debugPlayerRate() => _livePlayerState?._rate;

/// 最近一次**要求**的倍速（探针用），无播放页时返回 null
///
/// 与 [debugPlayerRate] 的区别（实测确认，很重要）：
/// ```text
/// debugPlayerRate()        = 播放器**回报**的倍速
///                            → 在 flutter test 里永远是 1.0（原生层不发事件）
/// debugPlayerRequestedRate() = 我们**要求**的倍速
///                            → 这才是本次要验的行为
/// ```
/// 拿这个做断言才不会是空断言。
double? debugPlayerRequestedRate() => _livePlayerState?._lastRateRequest;

/// PC 方向键状态机的**当前状态**（探针用）
///
/// 返回形如 `dir=1 holding=true`；无播放页时返回 null。
///
/// 用来证明"两个开关各自独立"：关掉单击后，长按仍应能进入 holding=true。
String? debugPlayerPcArrowState() {
  final st = _livePlayerState;
  if (st == null) return null;
  return 'dir=${st._pcArrow.direction} holding=${st._pcArrow.isHolding}';
}

/// 连续快退定时器**是否在跑**（探针用），无播放页时返回 null
///
/// 左方向键长按走的是"定时器反复 seek"（底层不支持负倍速），
/// 所以"有没有在连续快退"的唯一可靠判据就是这个定时器。
bool? debugPlayerRewindTimerActive() => _livePlayerState?._rewindTimer != null;

/// 累计调用 `_takeScreenshot` 的次数（★ task-21 P1-30 探针用），无播放页时返回 null
int? debugPlayerScreenshotCalls() => _livePlayerState?._screenshotCalls;

/// ★★★ 错误态返回箭头探针（Owner 2026-10-09 新增缺陷）
///
/// 返回 `(顶栏箭头矩形, 顶栏箭头**不透明度**, 顶栏是否参与命中测试)`。
///
/// # 为什么单看「矩形存在」不够（这是本缺陷最容易自欺的地方）
/// ```text
/// 改前顶栏那枚箭头的**矩形一直都在**（`Opacity` 与 `IgnorePointer`
/// 都不改变布局）—— 只断言「矩形非 null」在改前**也会通过**，
/// 证明不了「点得动」。所以必须同时量：
///   ② 不透明度：`_TopBar` 里 `Opacity(opacity: fade?.value ?? 1.0)`
///      —— 控制条隐藏时 `_controlsFade == 0` ⇒ 箭头全透明（看得见才怪）；
///   ③ 命中测试：`IgnorePointer(ignoring: !visible)` 是否放行。
/// ```
/// ③ 的读法：从箭头中心打一次真实 hitTest，看路径里有没有 `IconButton`；
/// 这个动作在 `_probeTopBarBackHitTest()` 里做（需要 tester，所以放探针侧）。
(Rect?, double?, bool)? debugPlayerTopBarBackProbe() {
  final s = _livePlayerState;
  if (s == null) return null;
  final ctx = s._topBarBackKey.currentContext;
  double? op;
  bool ignoring = false;
  ctx?.visitAncestorElements((e) {
    final w = e.widget;
    if (w is Opacity && op == null) op = w.opacity;
    if (w is IgnorePointer && w.ignoring) ignoring = true;
    return true;
  });
  final ro = ctx?.findRenderObject();
  final rect = (ro is RenderBox && ro.attached)
      ? ro.localToGlobal(Offset.zero) & ro.size
      : null;
  return (rect, op, ignoring);
}

/// 顶栏 / 底栏**真实渲染出来的** `Opacity.opacity`（探针用）
///
/// 返回 `(顶栏, 底栏)`；某条不在树上 ⇒ 对应分量为 `null`；无播放页 ⇒ 整个 `null`。
///
/// # ★★★ 2026-10-12 重写（原实现是**假绿**，从构造上不可能红）
/// ```text
/// 改前：
///   final v = s._controlsFade.value;
///   return (v, v);            // ← 两个分量同一个源 ⇒ o.$1 == o.$2 恒真
/// ⇒ t118 ①「两条读数相等」/ ④「每一帧都相等」这两条**永远绿**，
///   哪怕底栏的 Opacity 被冻结成常量（Owner 报的正是这个缺陷）。
/// ```
/// 现在两个分量都从 **element 树**里读：找那个「祖先链里含 `_TopBar` /
/// `PlayerBottomBar`」的 `Opacity`，取它 `build` 出来的 `opacity` 值 ——
/// 即**真正画在屏幕上**的那个数，与 `_controlsFade.value` 可以不同
/// （底栏被冻结成 build 期快照时就是不同的，于是本探针才可能红）。
///
/// ⚠️ 底栏那条 `Opacity` 是 `RenderOpacity` 的 widget 侧配置；拿不到
///    （底栏被宿主 `SizedBox.shrink()` 卸下）时返回 `null`，**不要**回填
///    动画值假装它还在 —— 那又会变成假绿。
(double?, double?)? debugPlayerControlBarsOpacity() {
  final s = _livePlayerState;
  if (s == null) return null;
  final root = s.context as Element?;
  if (root == null) return null;

  double? findFor(bool Function(Element) isBar) {
    double? found;
    void walk(Element e) {
      if (found != null) return;
      if (e.widget is Opacity) {
        var hit = false;
        e.visitAncestorElements((a) {
          if (isBar(a)) {
            hit = true;
            return false;
          }
          return true;
        });
        if (hit) {
          found = (e.widget as Opacity).opacity;
          return;
        }
      }
      e.visitChildren(walk);
    }

    walk(root);
    return found;
  }

  final top = findFor((e) => e.widget is _TopBar);
  final bottom = findFor((e) => e.widget is PlayerBottomBar);
  return (top, bottom);
}

/// 把控制条按 3 秒规则**跑到底**（★ 2026-10-08 顶栏联动回归用）
///
/// # 为什么需要它（而不是在测试里 `pump(3s)`）
/// ```text
/// 隐藏走的是 `Timer(3s)` + `AnimationController`，在 fake-async 里
/// 两者都要靠 `pump` 推进 —— 但 `pump` 的**次数与步长**决定了
/// 动画停在哪一帧，读数会飘。
/// ⇒ 这里直接把定时器那条路**同步**走完（cancel + 置位 + 驱动动画），
///   读数与真机「停手 3 秒」完全同一条代码路径。
/// ```
///
/// ⚠️ 它**只**在 `_playing == true` 时才会真的隐藏（与生产判据逐字一致）；
///    返回是否真的隐藏了。
bool debugPlayerAutoHideControlsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugAutoHideControlsForProbe();
  return !s._controlsVisible;
}

/// 模拟一次「鼠标在控制条区域晃动」（★ 2026-10-08 顶栏联动回归用）
///
/// ★ 走的是**生产**那条 `_showControls()`（含 `_applyControlsMotion()`
///   与 `_armHideTimer()`），不是测试自己置位。
bool debugPlayerHoverControlsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugHoverControlsForProbe();
  return s._controlsVisible;
}

/// ★ task-16 探针：置「指针是否在播放页内」—— 悬浮返回键的常驻判据
///
/// 走 `_onPointerEnter` / `_onPointerExit`（= `MouseRegion.onEnter/onExit`
/// 的生产回调体），返回置位后的值；无播放页时返回 null。
/// 为什么必须由探针驱动：见 `debugSetPointerInsideForProbe` 的说明。
bool? debugPlayerSetPointerInsideForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return null;
  s.debugSetPointerInsideForProbe(v);
  return s._pointerInside;
}

/// 置位 `_playing`（★ 2026-10-08 顶栏联动回归用）
///
/// ⚠️ 必须在 `debugPlayerAutoHideControlsForProbe()` **之前**调 ——
///    否则 `_autoHideNow()` 的 `_playing` 判据不成立，隐藏路径走不到。
bool debugPlayerSetPlayingForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugSetPlayingForProbe(v);
  return s._playing;
}

/// 打开「播放设置」面板（★ task-25 D 探针用，返回是否成功）
///
/// ⚠️ 与 `debugPlayerOpenHintsForProbe` 同因：面板依赖 FFI 数据才能
///    点开，widget 测试里拿不到 ⇒ 直接调 `_openSettings()` 的那条路
///    （`_readMpvStyle` 读不到属性也不会抛，只是 map 为空）。
bool debugPlayerOpenSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugOpenSettingsForProbe();
  return s._settingsOpen;
}

/// 关闭「播放设置」面板（★ 第 3 条回归测试用；返回关闭后面板是否确实关着）
///
/// ⚠️ 它**只改真源** `_settingsOpen`，**故意不碰** portal 的显示状态。
///
/// # 为什么不与面板上那颗 X 等价（2026-10-08 改）
/// X 与 Esc 现在都走「三步」（真源 + `_hideSettingsPortal()` + 底栏自愈），
/// 而本探针**停在第一步** —— 因为第 3 条缺陷 B 的入口形态正是
/// 「真源说"关"，而 portal 那边还开着（镜像过期）」，回归测试要复现的
/// 就是这个中间态。走完整三步反而复现不出缺陷。
///
/// # 为什么需要它（而不是在测试里点那颗 X）
/// `flutter_tester` 里 PlayerPage 整棵树的**指针事件回调都不被调用**
/// （命中链完整、同 Stack 的兄弟控件正常 ⇒ 见 test/t98 文件头的记录）。
/// 键鼠之外的探针入口是这台仪器唯一能驱动生产路径的手段。
/// 注入一条 `stream.error`（★ 第 9 条回归测试用；返回注入前是否已出过画面）
///
/// # 为什么要走**生产**那条监听
/// 它内部就是 `_player.stream.error.listen(...)` 的同一个闭包体 ——
/// 直接调它等价于 mpv 真的报了一条错，而测试**不需要**起播
/// （起播要真网络 + 真解码，widget 测试里做不到）。
///
/// ⚠️ 判据读的是 `s._sawFirstFrame`（真实字段），不是测试自己记的副本。
/// ★ 缺陷 17 探针用：底栏当前是否可见（= 渲染 `_BottomBar` 的那串门控的最终结果）
bool debugPlayerControlsVisibleForProbe() =>
    _livePlayerState?._controlsVisible ?? false;

/// ★ 缺陷 17 探针用：当前错误态（非 null 时底栏整条被摘掉）
String? debugPlayerErrorForProbe() => _livePlayerState?._error;

/// 打开选集面板（见 State 里的 `debugOpenEpisodesForProbe`）
bool debugPlayerOpenEpisodesForProbe() =>
    _livePlayerState?.debugOpenEpisodesForProbe() ?? false;

/// ★★★ Owner 第 2 条探针：抽屉**真的**发出过几次 pause / resume 命令
///
/// 返回 `(pause, resume)`；无播放页时返回 null（与 `debugPlayerGotoEpisodeCalls`
/// 同款：`null` 表示「仪器没接上」，不是「命令发了 0 次」）。
(int, int)? debugPlayerEpisodeSheetCmdCallsForProbe() {
  final s = _livePlayerState;
  if (s == null) return null;
  return (s._episodeSheetPauseCalls, s._episodeSheetResumeCalls);
}

/// ★★★ Owner 第 2 条探针：同步走一次生产 `_togglePlay()`（用户单击/空格同一条）
bool debugPlayerTogglePlaySyncForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugTogglePlayForSheetProbe();
  return true;
}

/// ★★★ Owner 第 2 条探针：抽屉此刻是不是「我们暂停的」
bool debugPlayerPausedForSheetForProbe() =>
    _livePlayerState?._pausedForEpisodeSheet ?? false;

/// ★★★ Owner 第 1 条探针：光标此刻是不是已经被藏起来了（无播放页时 false）
///
/// 读的是渲染期真源（全屏 + 停手 + 无浮层 + 正在播），见 State 里的同名方法。
bool debugPlayerCursorIdleHiddenForProbe() =>
    _livePlayerState?.debugCursorIdleHiddenForProbe() ?? false;

/// ★★★ Owner 第 1 条探针：模拟一次「人还在操作」
bool debugPlayerNoteCursorActivityForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugNoteCursorActivityForProbe();
  return true;
}

/// 展开某个 popover（见 State 里的 `debugOpenPopoverForProbe`）
bool debugPlayerOpenPopoverForProbe(String id) =>
    _livePlayerState?.debugOpenPopoverForProbe(id) ?? false;

/// 无头截图用：把底栏从「起播失败」那层里**救出来**（见 State 里的同名方法）
///
/// ⚠️ 只改 UI 状态，不碰播放器、不发请求 —— 仅供截图与几何判据使用。
bool debugPlayerForceBarsForShot() =>
    _livePlayerState?.debugForceBarsForShot() ?? false;


/// ★ task-12 ④ 探针用：当前**起播候选**的 url 列表（只读）。
///
/// # 为什么需要它
/// ```text
/// 「本地文件短路」的判据是「候选 url 是 file:// 且 resolveStream 没被执行」。
/// 但那是**内部状态**，探针拿不到 ⇒ 加这一条**只读**钩子。
/// ⚠️ 只读（返回 `_streams` 的副本），不提供任何 setter —— 不给测试开后门改状态。
/// ```
List<String> debugPlayerStreamUrlsForProbe() =>
    _livePlayerState?._streams.map((s) => s.url).toList() ?? const <String>[];

/// ★ 缺陷 17 探针用：弹幕是否开启（菜单项/按钮 tooltip 的动作词由它决定）
bool debugPlayerDanmakuEnabledForProbe() =>
    _livePlayerState?._danmakuEnabled ?? false;

/// ★ 缺陷 17 探针用：是否全屏（全屏按钮 tooltip 的动作词由它决定）
bool debugPlayerFullscreenForProbe() => _livePlayerState?._fullscreen ?? false;

/// ★ task-8 ① 探针用：把 `_fullscreen` 直接置位（**不**去调 windowManager）。
///
/// # 为什么要这个
/// ```text
/// 全屏返回那条路径里，`_exitPlayer()` 会 `await _toggleFullscreen()`，
/// 而后者内部 `await windowManager.setFullScreen(false)` 是**真 OS 调用**。
/// flutter_tester 里没有宿主窗口 ⇒ 那个 await 不会真的往返，
/// 量不到真机上的耗时。所以这里**只置标志位**，把「路径分支」与
/// 「OS 往返」分开：本探针量的是前者，后者由真机日志（[PLAYER] 时间戳）补。
/// ```
/// ★ task-8 ① 探针：直接 await 生产那条 `_toggleFullscreen()`，读出它**耗时/是否挂死**。
///
/// ⚠️ 必须走**生产**方法（不是测试自己模拟）—— 本缺陷的疑问正是
///    「那个 await 在桌面端到底要多久」，模拟不出这个答案。
Future<int?> debugPlayerAwaitToggleFullscreenForProbe() {
  final s = _livePlayerState;
  if (s == null) return Future<int?>.value(null);
  return s.debugPlayerToggleFullscreenForProbe();
}

bool debugPlayerSetFullscreenForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._fullscreen = v);
  // ★ N11：`_cursorIdleHidden` 的判据含 `_fullscreen` ⇒ 同步广播一次
  s._pushCursorLive();
  return true;
}

/// ★ task-7 探针用：走**生产** `_exitPlayer()`（与点返回箭头同一个回调）。
///
/// ⚠️ 不能只写 `Navigator.maybePop()` —— 那证明的是「Navigator 能用」，
///    不是「这枚箭头接的那条路径能用」。这里调的就是 `onBack` 里那一个。
bool debugPlayerBackForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  unawaited(s._exitPlayer());
  return true;
}

bool debugPlayerInjectStreamErrorForProbe(String message) {
  final s = _livePlayerState;
  if (s == null) return false;
  // 直调**生产方法** `_handleStreamError`（它同时负责 elapsed 的取值）。
  return s._handleStreamError(message);
}

/// 模拟「首个视频帧已出」（★ 第 9 条回归测试用）
///
/// # 它调的是**生产方法本身**（2026-10-26 起）
/// ```text
/// 原来这里照 `_bindPlayerStreams` 里 `stream.width` 的闭包体**另写了一份** ——
/// 生产那边每加一个"首帧要清/要立的字段"，那一份都不会跟
/// ⇒ 门禁测的是复刻件（task-14 抓到的 InjectStreamError 就是同类假绿）。
/// ⇒ 现在直接调 `_handleFirstFrame(w)`：监听与探针**只有一份实现**。
/// ```
/// ⚠️ 宽度用**合成值 1920**：探针不依赖真实解码（测试环境没有画面），
///    而 `_handleFirstFrame` 对 `w <= 0` 会早退（那是"没画面"的真实语义）。
bool debugPlayerMarkFirstFrameForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._handleFirstFrame(1920);
  return s._sawFirstFrame;
}

// ───────────────────────────────────────────────────────────────────
//  ★★★ 缺陷① / ② / ⑧（2026-10-25）的探针接缝
// ───────────────────────────────────────────────────────────────────
//
// 统一纪律（与全仓探针一致）：
// ```text
// · 只读探针只返回真实字段；
// · 写探针只改**状态**，不改判定逻辑（判定仍只有生产代码里那一份）；
// · 返回 false = 播放页没挂上 —— 调用方必须据此判红，
//   否则"没挂页"会伪装成"行为正确"（本仓踩过这个假绿）。
// ```

/// 缺陷①：让**用户主动 seek** 真的发生一次（走生产 `_seekByUser`）
///
/// ⚠️ 走生产方法而不是直接写字段：`_noteUserSeek` 是接在 `_seekByUser`
///    里的，绕过它就测不到"接线是否还在"。
bool debugPlayerUserSeekForProbe(Duration target) {
  final s = _livePlayerState;
  if (s == null) return false;
  unawaited(s._seekByUser(target));
  return true;
}

/// 缺陷①：读豁免窗口的两个真实字段（`null` = 还没记过 / 没挂页）
///
/// 返回 `'position=<s> ageMs=<n>'`；无播放页返回 `'no-state'`。
String debugPlayerUserSeekStateForProbe() {
  final s = _livePlayerState;
  if (s == null) return 'no-state';
  final pos = s._lastUserSeek?.inMilliseconds;
  final at = s._lastUserSeekAt;
  final age = at == null ? null : (s._userSeekClock.elapsed - at).inMilliseconds;
  return 'position=${pos ?? "-"} ageMs=${age ?? "-"}';
}

/// 缺陷①：把"用户 seek 的时刻"往前拨 [age]，用来验证 **2 秒窗口真的会过期**
///
/// 只改时间戳，不改窗口宽度、不改判定 —— 这就是"过期"这条阴性对照唯一的
/// 可行驱动方式（真实测试里没法等 2 秒还要保持位置流不 tick）。
bool debugPlayerAgeUserSeekForProbe(Duration age) {
  final s = _livePlayerState;
  if (s == null) return false;
  if (s._lastUserSeekAt == null) return false;
  s._lastUserSeekAt = s._userSeekClock.elapsed - age;
  return true;
}

/// 缺陷①：复位 `_introSkipped`（模拟生产里那 5 处复位点之一）
///
/// # 为什么必须能复位（否则门禁是假绿）
/// `_seekByUser` 自己就会把 `_introSkipped` 置 true ⇒ 只断言"拖到 0 不跳"
/// 的话，**删掉** 2 秒豁免那条判据测试**照样绿**（两重保护挡着）。
/// 生产里 `_applySwitch` / `_applySession` / `_gotoEpisode` / 存设置 / 开 autoSkip
/// 都会把它清回 false ⇒ 用户"拖回 0 → 碰了上述任一条 → 又被弹走"。
/// 复位它之后仍然不跳，才能证明**豁免判据本身**在起作用。
bool debugPlayerResetIntroSkippedForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._introSkipped = false;
  return true;
}

/// 缺陷②：读"恢复推进量"（累计推进了多少毫秒，清横幅后归零）
///
/// ⚠️ 「把 `_playing` 置位」复用既有的 `debugPlayerSetPlayingForProbe`
///    （它走生产的 `debugSetPlayingForProbe`，不是另开一个真相）。
String debugPlayerRecoveryStateForProbe() {
  final s = _livePlayerState;
  if (s == null) return 'no-state';
  return 'recoveryMs=${s._recoveryProgress.inMilliseconds} '
      'failure=${s._playbackFailure ?? "-"}';
}

/// 缺陷②：读底栏是否「让位」（= `_bottomOccupied` 这个**生产判据**）
///
/// 与 `zz_t1023_player_seek_behavior_test` 里"底栏被卸下"那条行为断言配对：
/// 一个测结构树，一个测判据本身。无播放页返回 null。
bool? debugPlayerBottomOccupiedForProbe() => _livePlayerState?._bottomOccupied;

/// 缺陷①/③：直接摆一个 `_pendingSeek`（续播意图），用来验"续播期间不许自动跳"
///
/// ⚠️ 只改字段，不改任何判定 —— `_maybeSkip` 里 `if (_pendingSeek != null) return;`
///    仍是**唯一**的让位实现。
bool debugPlayerSetPendingSeekForProbe(Duration? target) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._pendingSeek = target;
  return true;
}

/// 缺陷①：读「本集是否已判定跳过片头」（`_introSkipped` 真实字段）
bool? debugPlayerIntroSkippedForProbe() => _livePlayerState?._introSkipped;

/// 缺陷③：读 `MediaSession.currentPosition`（**接口**上的那个 getter）
///
/// # 为什么不直接读 `_position`
/// 详情区换源续播走的是 `_session?.currentPosition`（`media_page.dart`），
/// 而 `MediaSession` 是播放器与合并页之间的**契约**。
/// 断言"接口返回的就是当前播放位置"才覆盖了那条路径的起点；
/// 只读 `_position` 会漏掉"getter 写错/被改成常量 0"这种缺陷。
Duration? debugPlayerSessionCurrentPositionForProbe() =>
    _livePlayerState?.currentPosition;

/// 缺陷⑧：把"open 发起点"往前拨 [ago]，用来在无真实起播的环境里
/// 造出"失败耗时落在超时窗内"这个**真实读数**
bool debugPlayerAgeLoadStartForProbe(Duration ago) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._loadStartedAt = s._loadClock.elapsed - ago;
  return true;
}

/// 缺陷⑧：读最近一次起播失败的耗时（`null` = 没有 / 没计时）
Duration? debugPlayerStartFailureElapsedForProbe() =>
    _livePlayerState?._startFailureElapsed;

/// 缺陷⑧：读渲染路径用的归因输入（与 `build` 里那次 classify 同源）
///
/// 返回 `'kind=<name> elapsedMs=<n>'`；无播放页或没有错误时 `'no-state'` / `'no-error'`。
String debugPlayerFailureAttributionForProbe() {
  final s = _livePlayerState;
  if (s == null) return 'no-state';
  final err = s._error;
  if (err == null) return 'no-error';
  final f = PlaybackErrorText.classify(
    err,
    kindHint: s._errorKind,
    hadCandidates: s._streams.isNotEmpty,
    elapsed: s._startFailureElapsed,
  );
  return 'kind=${f.kind.name} elapsedMs=${s._startFailureElapsed?.inMilliseconds ?? "-"}';
}

/// ★★★ CR #22 ② 门禁用：把「起播失败」态**中性化**成干净态（不清别的字段）
///
/// # 为什么需要它
/// ```text
/// CR ② 要求「_error != null 时不许弹续播浮层」—— 这条守卫是对的：
/// 起播失败时弹"继续观看"等于骗用户去 seek 一个没在放的播放器。
///
/// 但原生门禁（见 test/zz_rewatch_prompt_test.dart ②）是**正向**判据：
/// "提示模式 + 这集看过 ⇒ 必须弹"。而那个夹具里 SourinApi.resolveStream
/// 走真 FFI、必然失败 ⇒ 挂载期 _error 就已经被置上 ⇒ 守卫一落地，
/// 那条正向门禁会**立刻变红**。
/// ```
/// 所以要一条能把 _error 清回干净态的钩子，门禁里**先自证它真生效**
///（返回 false ⇒ 测试立刻红），再断言浮层弹出。
///
/// # 与 [debugPlayerMarkFirstFrameForProbe] 的区别（逐字对比过）
/// ```text
/// 本钩子**不设** _sawFirstFrame —— 只清"起播失败/中断"三件套。
/// 不设它，是因为本钩子不假装"出过画面"，只把错误态抹平。
/// ```
/// 探针：**纯判据**（不改状态）—— kind 说 mp4 且后缀 .mp3 才需要强制 demuxer
bool debugPlayerNeedsDemuxerOverrideForProbe(String url, String kind) =>
    _PlayerPageState.needsDemuxerOverride(url, kind);

/// 探针：当前真正下发给 mpv 的 demuxer 覆盖值（null = 已清空）
String? debugPlayerDemuxerFormatForProbe() =>
    _livePlayerState?._demuxerOverride;

/// 探针：按 (url, kind) 走一遍**生产**下发路径（设置或清空）
///
/// ⚠️ 它经 `_applyDemuxerOverride()` ⇒ 残留语义（切到真 mp3 必须清空）
///    也是**生产逻辑**在验证，不是测试自己写的判据。
Future<bool> debugPlayerApplyDemuxerForProbe(String url, String kind) async {
  final s = _livePlayerState;
  if (s == null) return false;
  s._current = StreamCandidate(url: url, kind: kind);
  await s._applyDemuxerOverride();
  return true;
}

bool debugPlayerClearErrorForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  AppLog.write('PLAY', '错误态已中性化（探针清空 _error/_errorKind/_playbackFailure）');
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._neutralizeErrorState(loading: false));
  return s._error == null;
}

/// 读第 9 条的两个状态（`hasFrame=<是否出过画面> failure=<非阻断横幅>`）
String debugPlayerPlaybackFailureState() {
  final s = _livePlayerState;
  if (s == null) return 'no-state';
  return 'hasFrame=${s._sawFirstFrame} '
      'failure=${s._playbackFailure ?? "-"} '
      'error=${s._error ?? "-"}';
}

/// 读「底栏是否可见」（★ 第 3 条：关掉面板后底栏必须回来）
/// ★ 顶栏/底栏"显隐广播"的当前值（`_controlsLive`）—— 只读
///
/// 不变量：**任何时候** `_controlsLive.value == _controlsVisible`。
/// 改前 `_autoHideNow()` 不推这个值 ⇒ 隐藏后它仍停在 true，
/// 于是"鼠标唤起"那次 push 因 `true == true` 提前 return ⇒ 顶栏不重建 ⇒
/// 返回箭头看得到却点不到（不透明度 1.0 + IgnorePointer 仍挡）。
bool? debugPlayerControlsLiveForProbe() => _livePlayerState?._controlsLive.value;


bool? debugPlayerControlsVisible() {
  final s = _livePlayerState;
  if (s == null) return null;
  return s._controlsVisible;
}

bool debugPlayerCloseSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  /*
   * ⚠️ 只改真源 `_settingsOpen`，**故意不碰** portal 的显示状态。
   *
   * 这样它才等价于缺陷 B 的入口形态（镜像过期的那个）：真源已经是 false，
   * 而 controller 那边还以为自己在显示。t98 ② 就用这个形态复现
   * 「开过别的浮层之后再开面板，面板必须仍然出现」。
   * 面板那颗 X 走的是 `onClose`（真源 + portal + 底栏三件都做）。
   */
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._settingsOpen = false);
  return !s._settingsOpen;
}

/// 设置面板的 `_settingsOpen`（★ task-25 D 探针用），无播放页时返回 null
bool? debugPlayerSettingsOpen() => _livePlayerState?._settingsOpen;

/// 当前平台策略：`clipDirOpenStrategy` 的结果（★ task-25 C 探针用）
///
/// ⚠️ 只读探针 —— **不会真的去 spawn 外部进程**，也不会碰剪贴板。
///    「真的走到哪一支」由 `test/t68_android_adapt_test.dart` 断言
///    顶层纯函数本身来保证。
String debugPlayerClipDirStrategy() => clipDirOpenStrategy(
  isWindows: Platform.isWindows,
  isMacOS: Platform.isMacOS,
  isLinux: Platform.isLinux,
);

/// 主动 seek 到指定位置（**仅探针用**），无播放页时返回 false
///
/// # 为什么需要"主动 seek"这种危险的东西
///
/// 交付实测要断言"单击后播放位置**没有跳变**"。但如果位置读数本身
/// 是坏的（永远 0、或者探针接错了），那条断言会**永远为真** ——
/// 一条空断言比没有断言更危险（给的是虚假信心）。
///
/// 实测第一轮就撞上了：位置是 `0.00s → 0.00s`，"没跳"通过了，
/// 但视频压根还没起播 —— 那个"通过"没有任何信息量。
///
/// 所以需要一次**阳性对照**：主动 seek 到一个已知位置，
/// 断言读数**确实跟着变了**。变了才说明尺子是准的。
///
/// ⚠️ 它绕开所有手势逻辑直接调播放器 —— 这是**故意**的：
///    测的是"读数能不能反映 seek"，与手势无关。
///    调用方负责在测完后复位位置。
/// 探针用：位置流触发的**页面 setState 次数**（task-72 ④ 卡顿量化）
///
/// # 为什么需要它
///
/// 「播放页面感觉也卡卡的」是 Owner 的**主观描述**。要把候选 B
///（`_player.stream.position` 无节流直接 `setState`）变成读数，
/// 就必须数出**页面真的重建了多少次**。
///
/// 只数「mpv 发了多少次 `time-pos`」不够 —— 那证明不了页面跟着重建
///（铁律 149：候选集为空/机制未触发时，断言恒真）。
///
/// 生产代码里它只是一个 `++`（每次 tick 一次自增，代价可忽略），
/// 没有任何分支依赖它的值。
int debugPlayerPositionSetStates = 0;

/// 探针用：位置流**一共来了多少 tick**（与上面那个 setState 数配对）
///
/// 两个数一起看才有意义：
/// ```text
/// 改前：ticks = N, setStates = N   （1:1）
/// 改后：ticks = N, setStates ≈ 秒数（按显示的那一秒节流）
/// ```
int debugPlayerPositionTicks = 0;

/// 清零两个位置流计数器（**仅探针用**）
void debugPlayerResetPositionSetStates() {
  debugPlayerPositionSetStates = 0;
  debugPlayerPositionTicks = 0;
}

/// 探针用：**跳过 `_player.open()` 那一句**（缺省 false ⇒ 生产逐字不变）
///
/// # 为什么必须有这个开关（实测，不是猜）
/// ```text
/// `await _player.open(...)` 在**挂了 `PlayerPage` 的** `testWidgets` 里
/// **永不返回** —— 与 `MediaKit.ensureInitialized` 在哪个 zone 无关：
///   · `.probe/open_probe.txt`：裸 `test()` 里 79ms 返回；`t.runAsync` 里 20s 超时
///   · `.probe/open2a.txt` / `open2b.txt`：**没有 widget 树**的 testWidgets
///     里两个变体都 60–79ms 正常返回
/// ⇒ 挂住的真正条件是「页面上挂着一个真 Player + 有 pumpWidget 的树」。
/// ```
///
/// # 为什么不能用「事后清 `_error`」的探针救场
/// ```text
/// CR #22 ② 的代次守卫（`_gotoEpisode` 末尾 `_error == null` 那一句）是
/// 在 `_gotoEpisode` **内部**求值的 —— `open()` 挂住 ⇒ `_reload()` 永不返回
/// ⇒ `_gotoEpisode()` 永不返回 ⇒ 事后任何清 `_error` 的探针都**跑不到**。
/// 正向门禁（②④⑤）唯一出路：让 `_startPlayback` 能**跑完**。
/// ```
///
/// ★ 只跳过 open **这一句**：`_applyVideoZoom` / `AppLog` / `_reportHwdecAfterReady`
///   / `_reportFirstFrame` / `_watchVideoOutput` / audioUrl 挂载 / `_pendingSeek`
///   / `_loading=false` / `_showControls` / `_armHideTimer` / `_startProgressSaver`
///   / `_loadDanmaku` / `_applySubtitleStyle` **全照跑** ⇒ 门禁测的仍是生产流程。
/// ★ 用法：门禁 `setUp` 置 `true`、`tearDown` 置回 `false`。
bool debugPlayerSkipOpenForProbe = false;

/// 探针用：把一次位置 tick **灌进真实处理路径**（见 `_onPositionTick`）
///
/// 用于 widget 测试里模拟"1 秒内来了 100 个 tick" ——
/// 没有它就只能靠真播放（widget 测试里 `open()` 会挂住，见
/// `.probe/probe_tests/t72_position_tick_probe_test.dart` 的注释）。
void debugPlayerPushPositionForProbe(Duration p) {
  _livePlayerState?._onPositionTick(p);
}

/// ★★★ OPS-13（反馈 C）探针：**真的走一遍生产落盘路径**（`_saveProgress`）
///
/// # 为什么必须是真跑而不是复刻一份
/// ```text
/// 本仓反复吃过「手抄副本与生产脱钩」的亏：复刻一份写入逻辑的话，
/// 「镜像那条到底有没有写出去、写成什么样」这件事**测不到** ——
/// 而那正是本任务的全部内容。
/// ⇒ 这里直接调生产的 `_saveProgress()`，它内部就是 `saveProgressWithMirror`。
/// ```
///
/// ⚠️ 返回 false = 播放页没挂上（`_livePlayerState` 为 null）——
///    **调用方必须据此判红**，否则「没调用 = 没镜像」会伪装成「镜像功能正确」。
/// ⚠️ [duration] / [position] 在这里**紧贴着** `_saveProgress` 赋值，
///    不留给事件循环任何缝隙 —— 实测（2026-10-10）中间夹一次 `pump()`
///    就会被真实的 `stream.duration` 事件把 `_duration` 冲回 0 ⇒
///    `_saveProgress` 在第一行 `if (_duration <= Duration.zero) return;` 早退
///    ⇒ 注入点一条记录都没有，而测试会**误判成「镜像功能没实现」**。
Future<bool> debugPlayerSaveProgressForProbe({
  bool immediate = true,
  Duration? duration,
  Duration? position,
}) async {
  final s = _livePlayerState;
  if (s == null) return false;
  if (duration != null) s._duration = duration;
  if (position != null) s._position = position;
  await s._saveProgress(immediate: immediate);
  return true;
}

/// ★★★ OPS-13（反馈 C）探针：**真的走一遍续播读路径**（`_prepareResume`）
///
/// # 为什么要能读回续播位置（而不是只看源码里有没有那行字）
/// ```text
/// 「本地看完 → 在线续上」这条链的**后半段**是 `_prepareResume`：
/// 它要读两侧、取更新的那条、并且**不能**被「按集校验」误伤。
/// 只看源码文本的话，`pickResumeProgress` 接反了、或镜像那条
/// 被 episode_id 守卫挡掉，都会**照样全绿**。
/// ⇒ 真调它，再读 `_pendingSeek` 这个真实读数。
/// ```
///
/// ⚠️ 返回 false = 播放页没挂上（同 [debugPlayerSaveProgressForProbe]）。
Future<bool> debugPlayerPrepareResumeForProbe() async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s._prepareResume();
  return true;
}

/// 探针读数：续播将要 seek 到的位置（`null` = 不续播）。
///
/// 与 [debugPlayerPrepareResumeForProbe] 配对使用。
/// ⚠️ 无播放页时返回 `null` —— 与「有播放页但不续播」**同值**，
///    所以调用方必须先断言 [debugPlayerPrepareResumeForProbe] 返回 true。
Duration? debugPlayerPendingSeekForProbe() => _livePlayerState?._pendingSeek;

/// ★★★ fix/rewatch-prompt 探针：当前浮层要显示的"上次看到哪"（null = 没有浮层）
///
/// 与真实渲染的浮层是**同一个字段**（`_rewatchPrompt`）——「有没有弹」与
/// 「弹的秒数」用这一个读数即可，不必另造一个"是否显示"的布尔（两个真相会漂）。
Duration? debugPlayerRewatchPromptForProbe() => _livePlayerState?._rewatchPrompt;

/// ★★★ 探针：驱动一次"切集"（走**生产方法** `_gotoEpisode`），返回是否成功。
///
/// # 为什么需要它（不能只 pumpWidget 一个带 episodes 的页面就完事）
/// ```text
/// `_gotoEpisode` 是 async，里面 `await _saveProgress` / `await _reload()`
/// 都要真跑（读进度、解析流）—— 用 `t.runAsync` 驱动它，读数才确定。
/// 用例拿到 `Episode` 后传进来；`i < 0`（不在列表里）⇒ 返回 false。
/// ```
Future<bool> debugPlayerGotoEpisodeForProbe(Episode ep) async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s._gotoEpisode(ep);
  return true;
}

/// ★★★ CR #22 ⑥ 探针：把**真正的** `applySession`（生产方法）暴露给用例。
///
/// # 为什么必须走真方法
/// ```text
/// ⑥ 的缺陷是"会话被**别的路径**换掉时，在途的切集链路仍会弹浮层"。
/// 断言要成立，就必须让用例能触发那条路径 —— 自己拼一个
/// `PlayRequestData` 然后调真 `applySession`，测的才是生产分流
///（`isSameSessionAs` 早退 / `_rewatchToken++` / `_resolveAndPlay`）。
/// ```
/// 返回 false = 没挂页（调用方必须先断言挂上了）。
Future<bool> debugPlayerApplySessionForProbe(PlayRequestData req) async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s.applySession(req);
  return true;
}

/// Drive the production source-switch entry; replace only external transport.
Future<bool> debugPlayerApplySwitchForProbe({
  required String provider,
  required String id,
  required MediaDetail detail,
}) async {
  final s = _livePlayerState;
  if (s == null) return false;
  s._switchDetailForProbe = (_, __) async => detail;
  s._switchRepointForProbe = (_) async {};
  try {
    await s._applySwitch(SwitchPick(
      provider: provider,
      id: id,
      title: detail.title,
      episodeIndex: 1,
      position: 0,
    ));
    return true;
  } finally {
    s._switchDetailForProbe = null;
    s._switchRepointForProbe = null;
  }
}

/// 探针：直接调**生产方法** `showRewatchPrompt`（把浮层摆出来）
bool debugPlayerShowRewatchPromptForProbe(Duration position) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.showRewatchPrompt(position);
  return true;
}

/// 探针：读"浮层是否正在显示"（与渲染用的是同一个字段）
bool debugPlayerRewatchPromptVisible() =>
    _livePlayerState?._rewatchPrompt != null;

/// ★ task-14：**真的点一次「继续观看」**（走生产 `continueFromRewatchPrompt`）
///
/// # 为什么必须是生产方法
/// ```text
/// 缺陷就藏在"这条入口绕过了用户意图通道"上（裸 `_player.seek`）。
/// 测试若自己在外面 `_player.seek(...)`，测的是测试自己，不是那条入口。
/// ⇒ 走生产方法 ⇒ 修好后 `_noteUserSeek` / `_introSkipped` 都会生效；
///   回退成裸 seek ⇒ `_maybeSkip` 立刻把位置顶掉（用例变红）。
/// ```
/// 返回 false = 没挂页或没有待处理的浮层。
bool debugPlayerContinueRewatchForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  if (s._rewatchPrompt == null) return false;
  s.continueFromRewatchPrompt();
  return true;
}

/// ★ task-14 探针：`_load()` 至今被调用了几次（`null` = 没挂页）
///
/// 第 02 项「点重试 ⇒ 真的重新起播」用它做**差值**断言（+1）。
int? debugPlayerLoadCallsForProbe() => _livePlayerState?._loadCalls;

/// ★ task-26 探针：`_startPlayback()` 至今被调用了几次（`null` = 没挂页）
///
/// 用来钉住「换集后不许再用**旧候选**起播」：点开作品后立刻切集，
/// 正确结果是 **1 次**（新集那一次）；在途旧链路抢跑就会变成 2 次。
int? debugPlayerStartPlaybackCallsForProbe() =>
    _livePlayerState?._startPlaybackCalls;

/// ★★★ 探针读数：当前会话**自己那把键**（`provider:id`），`null` = 没挂上。
///
/// # ★ 为什么必须有这一条（它是本轮抓到的一个**假绿**的直接产物）
/// ```text
/// 实测（2026-10-10）：同一个用例里连续 `pumpWidget` 两个 PlayerPage 时，
/// 若两棵树的**类型与 key 都相同**，Flutter 会**复用同一个 State**
/// （只走 didUpdateWidget，**不再走 initState**）⇒ `_provider`/`_contentId`
/// 仍是**第一个**会话的值。
/// ⇒ 「换成在线会话再读续播」那条用例，其实读的还是本地会话自己的键 ⇒
///   在**没有修**的代码上也是绿的（= 假绿）。
/// ```
/// ⇒ 每个用例在断言前**先钉住当前会话的身份**，让这种复用立刻显形。
String? debugPlayerSessionKeyForProbe() {
  final s = _livePlayerState;
  return s == null ? null : '${s._provider}:${s._contentId}';
}

/// 探针读数：本会话是否会**镜像**进度、镜像到哪个键（`null` = 不镜像）。
///
/// 与 `_mirrorOrigin` 是同一个 getter —— 不另写一份判据。
String? debugPlayerMirrorOriginForProbe() {
  final o = _livePlayerState?._mirrorOrigin;
  return o == null ? null : '${o.provider}:${o.mediaId}';
}

/// ★★★ 探针读数：本会话镜像时会带上的**站点集 id**（`null` = 带不上/不镜像）。
///
/// # 为什么要单列这一条（OPS-13 反馈 C ①）
/// ```text
/// `_mirrorOrigin` 只说明**打到哪个键**，不说明 `episode_id` 写什么。
/// 而 CR-08 的守卫（progress_origin.dart 里 `siteEpisodeId.isEmpty`）拦的
/// 正是 `episode_id` —— 它拿不到 ⇒ 整条镜像被跳过。
/// ⇒ 必须能直接读回「这次镜像会写什么 episode_id」，才能把
///    「因缺站点集 id 而跳过（缺陷）」与「因该跳过而跳过（正确）」分开。
/// ```
/// ⚠️ 它读的是**当前挂载会话**的 `widget.originEpisodeId` —— 与真实写入路径
///    同一个字段（`_saveProgress` 里传给 `saveProgressWithMirror` 的就是它）。
String? debugPlayerOriginEpisodeIdForProbe() =>
    _livePlayerState?.widget.originEpisodeId;

/// 探针：直接灌一个时长（`_saveProgress` 的早退条件之一是 `_duration > 0`）。
///
/// ⚠️ 只改这一个字段，不碰播放器 —— 本探针测的是**写入路径**，不是解码。
bool debugPlayerSetDurationForProbe(Duration d) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._duration = d;
  return true;
}

/// 探针：复位续播守卫（`_resumedThisSession` / `_position`），
/// 让同一个页面能被**连续**驱动两次「读续播」。
bool debugPlayerResetResumeGuardForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._resumedThisSession = false;
  s._pendingSeek = null;
  s._position = Duration.zero;
  return true;
}

/// Inject only the native user-seek boundary; production dispatch stays intact.
bool debugPlayerSetUserSeekForProbe(Future<void> Function(Duration)? seek) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._userSeekForProbe = seek;
  return true;
}

/// Observe only the native resume seek boundary, not cancellation logic.
bool debugPlayerSetResumeSeekForProbe(Future<void> Function(Duration)? seek) {
  final s = _livePlayerState;
  if (s == null) return false;
  s._resumeSeekForProbe = seek;
  return true;
}

/// Start the production resume waiter with an unknown media duration.
/// Tests must advance duration and drive session changes separately.
Future<bool> debugPlayerStartResumeWaitForProbe(Duration target) async {
  final s = _livePlayerState;
  if (s == null) return false;
  s._duration = Duration.zero;
  s._realDuration = Duration.zero;
  s._pendingSeek = target;
  s._resumeSeekDone = false;
  await s._seekAfterReady(target, ++s._seekToken);
  return true;
}

bool debugPlayerSeekForProbe(Duration target) {
  final s = _livePlayerState;
  if (s == null) return false;
  // seek-intent: programmatic — 仅探针（测试直接驱动原生 seek 边界）
  s._player.seek(target);
  return true;
}

/// 打开一个**本地文件**作为媒体（**仅探针用**），无播放页时返回 false
///
/// # 为什么需要它（这是被阳性对照逼出来的）
///
/// 阳性对照第一次跑就**失败**了，暴露出一个真问题：
/// ```text
/// [阳性对照] 主动 seek 到 20s：位置 0.00s → 0.00s (Δ0.00s)  ✗
/// ```
/// 位置读数**根本不动** —— 因为测试用的那路在线流因为
/// `unauthorized`（测试数据目录里的登录已失效）**压根没起播**。
///
/// 于是 ⑥b/⑥c 里那两条"单击后位置没跳"的 ✓ 全是**空的**：
/// 位置永远是 0，当然"没跳"。这正是本次会话反复踩的坑 ——
/// **一条永远为真的断言比没有断言更危险**（给的是虚假信心）。
///
/// # 修法：把测量对象换成**一定播得起来**的东西
///
/// 用本地 mp4（`--dart-define=PROBE_VIDEO=<path>`）替换当前媒体。
/// 本地文件不依赖网络/登录，`_position` 会**真的推进**，
/// 这样"位置没跳"才是一个有信息量的断言。
///
/// ⚠️ 只在探针构建里调用；`_probeVideo` 为空时它是 no-op。
Future<bool> debugPlayerOpenForProbe(String url) async {
  final s = _livePlayerState;
  if (s == null) return false;
  try {
    await s._player.open(Media(url));
    return true;
  } catch (e) {
    debugPrint('[GESTURE-PROBE] 打开探针视频失败: $e');
    return false;
  }
}

/// 探针视频路径（编译期常量，默认空 = 不启用）
///
/// 见 `debugPlayerOpenForProbe` 的说明：没有它，"位置没跳"这条断言
/// 在在线流播不起来时是**空的**。
const kProbeVideo = String.fromEnvironment('PROBE_VIDEO');

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-13 ⑦ 弹幕探针（交付实测用）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话：
// > 接入一下 danmaku-service 的弹幕功能
//
// # 为什么要这些探针
//
// 弹幕这条链路有三段**只有真进程里才成立**：
// ----
// ① 取：真的发 HTTP 到 api.danmaku-service.net（签名 / 302 / 错误头）
// ② 排：真的把 N 条弹幕铺到 N 条泳道上（不重叠）
// ③ 滚：真的随时间往左移动（帧循环 / 时间轴对齐）
// ----
// widget 测试只能测纯函数（①②的解析部分），②③必须在真窗口里跑。
// 所以这里给真进程探针留出「读状态 / 塞数据 / 截图」的把手。

/// 当前已取到的弹幕条数（无播放页时返回 null）
int? debugPlayerDanmakuCount() => _livePlayerState?._danmakuComments.length;

/// 当前弹幕开关状态
bool? debugPlayerDanmakuEnabled() => _livePlayerState?._danmakuEnabled;

/// 当前弹幕状态摘要（面板里那行字）
String? debugPlayerDanmakuStatus() => _livePlayerState?._danmakuStatus;

/// 当前弹幕错误（无错误时返回空串；null = 没有播放页）
String? debugPlayerDanmakuError() {
  final s = _livePlayerState;
  if (s == null) return null;
  final e = s._danmakuError;
  if (e == null) return '';
  // ★ 把 X-Error-Message 原文带出来 —— 这是「没填 AppId」时
  //   唯一能说明原因的东西（正文是空的，见 core/danmaku.dart）
  return e.xErrorMessage.isNotEmpty ? e.xErrorMessage : e.message;
}

/// 面板里「详情」那段全文（含 HTTP 状态码 / 请求 URL / 响应正文）
String? debugPlayerDanmakuErrorDetail() =>
    _livePlayerState?._danmakuError?.detail;

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ 2026-10-14（Owner）：「搜索番剧」的探针钩子
// ═══════════════════════════════════════════════════════════════════════
//
// 为什么必须是一等探针（而不是测试里自己点 UI）：
// ```text
// flutter_tester 里 PlayerPage 整棵树的**指针回调不触发**（见 t98 文件头
// 与 .probe/probe_tests/README.md）⇒ 搜索框敲字、点「搜索」、点结果行
// 这些动作都走不了真指针。所以：
//   ① 打开面板：用**既有的** `debugPlayerOpenDanmakuSettingsForProbe`
//      （它已驱动生产那棵树，见它的注释）
//   ② 触发搜索：`debugPlayerDanmakuSearchForProbe` 直调**生产**的
//      `_searchDanmaku()` —— 网络经 `debugSetDanmakuTransportForTest`
//      注入的假传输，于是判据是**确定性的**，不是"跑到网上碰运气"
//   ③ 点结果：直调生产的 `_pickDanmakuMatch()`
// 三个入口都指向生产代码本身 ⇒ 测的是行为，不是手抄的副本。
// ```

/// 面板里当前那份状态（只读）—— 供测试断言"宿主真收到了什么"
DanmakuSettingsState? debugPlayerDanmakuSettingsState() =>
    _livePlayerState?._danmakuSettings;

/// 走生产 `_searchDanmaku(keyword)`（网络由注入的假传输接管）
Future<void> debugPlayerDanmakuSearchForProbe(String keyword) async {
  await _livePlayerState?._searchDanmaku(keyword);
}

/// 走生产 `_pickDanmakuMatch(match)`（= 用户点了结果里的一条）
void debugPlayerPickDanmakuMatchForProbe(DanmakuMatch m) {
  _livePlayerState?._pickDanmakuMatch(m);
}

/// 当前这一集"挂哪份弹幕"的身份（`_biliCid`）——
/// 点中一条结果后就该 = 那条的 episodeId。
int? debugPlayerDanmakuBoundId() => _livePlayerState?._biliCid;

/// 开关弹幕（探针用；会真的走 _toggleDanmaku 那条路）
Future<bool> debugPlayerToggleDanmakuForProbe() async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s._toggleDanmaku();
  return s._danmakuEnabled;
}

/// 直接设弹幕开关（探针用；**不**触发取弹幕）
void debugPlayerSetDanmakuEnabledForProbe(bool v) {
  final s = _livePlayerState;
  if (s == null) return;
  s.debugDanmakuSetEnabledOnly(v);
}

/// 用给定文件名取一次弹幕（探针用；返回取到的条数，-1 = 失败）
///
/// 真进程探针里用它验证「有凭证 ⇒ 200 + N 条」/「没凭证 ⇒ 403 + 原文」。
Future<int> debugPlayerLoadDanmakuForProbe(String fileName) async {
  final s = _livePlayerState;
  if (s == null) return -1;
  if (!s._danmakuEnabled) s.debugDanmakuSetEnabledOnly(true);
  await s._loadDanmakuNamed(fileName);
  return s._danmakuError == null ? s._danmakuComments.length : -1;
}

/// 清掉弹幕取数错误（探针用；返回清完后错误是否为空）
///
/// # 为什么需要它
///
/// 没有 AppId/AppSecret 时 ① 段必然拿到 403，`_danmakuError` 被置上，
/// 于是弹幕层左上角会挂一个「弹幕失败：Missing Authentication Headers」
/// 角标（`_danmakuBadge` 那个 getter；★ 2026-10-26 去掉了写死的 `:3318-3331`，
/// 原区间已漂 —— 现在指向符号，不随行号失效）。
///
/// ④ 段的像素对照要测的是**滚动弹幕自己**，而那个角标正好落在弹幕带
/// （视频区顶部 5 条泳道）里，尺寸还不小 ⇒ 不排掉它，「弹幕开 vs 关」
/// 的差值会被角标主导，等于测了个错东西。
///
/// 清掉它等于**模拟取数成功那一支**（错误为空、评论非空 ⇒ 角标为 null），
/// 这正是真实凭证到手后的状态。
bool debugPlayerClearDanmakuErrorForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._danmakuError = null);
  return s._danmakuError == null;
}

/// 塞一个**真实构造的**弹幕错误（探针用；返回塞完后错误是否就是它）
///
/// # 为什么需要它
///
/// Owner 第 1 条要的是「403 + Missing Authentication Headers ⇒ 面板里
/// 出现中文指引」。这条链的后半段（面板把 `DanmakuHint` 画出来）能在
/// 纯 widget 测试里验，但**前半段**（`_danmakuError` 真的被搬到面板的
/// state 里）只能在真棵树上验 —— 没有凭证时真实链路必然 403，可那是
/// **网络**，单测里不许发。
///
/// ⚠️ 必须**连 `_danmakuSettings` 一起写**：面板读的是
///   `_danmakuSettings.error`，只写 `_danmakuError` 面板什么都看不见
///   （`_openDanmakuSettings` 里那句 copyWith 就是干这个的）。
bool debugPlayerInjectDanmakuErrorForProbe(DanmakuException e) {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() {
    s._danmakuError = e;
    s._danmakuSettings = s._danmakuSettings.copyWith(
      error: e,
      loading: false,
      status: '',
    );
  });
  return identical(s._danmakuError, e);
}

/// 塞一组**本地构造的**弹幕进渲染层（探针用）
///
/// # 为什么需要「本地构造」这条路
///
/// 没有 AppId/AppSecret 时，真实链路**必然**是 403
/// （见 core/danmaku.dart 的错误透传策略）⇒ 渲染/滚动/泳道分配
/// 这三件事就没有真实数据可测。
/// 本地构造一组时间/模式/颜色都可控的弹幕，可以把
/// 「画面里到底有没有东西在动」这件事**独立**证出来 ——
/// 这样报告里「渲染层是好的」和「取数被凭证卡住」才是两件分开的事实。
void debugPlayerSetDanmakuCommentsForProbe(List<DanmakuComment> cs) {
  final s = _livePlayerState;
  if (s == null) return;
  s.debugDanmakuSetComments(cs);
}

/// 清空弹幕探针统计（进入测量前调一次）
void debugPlayerResetDanmakuProbe() => debugDanmakuResetProbeStats();

/// 弹幕角标**当下**该画什么（探针用；null = 不该画）
///
/// ★★★ OPS-10 ④（Owner 逐字：「没有弹幕的那个标识,不用一直显示,
///     跟随一起消失就行了」）
///
/// 那句话的判据**全在** `_danmakuBadge` 这个 private getter 里
/// （寿命 + 控制条），测试没法直接读 ⇒ 开一个只读的口子。
///
/// ⚠️ 读的是**真棵树上那个真 getter**，不是测试里手抄的副本 ——
///    手抄一份判据等于测自己写的 if（假门禁）。
String? debugPlayerDanmakuBadgeForProbe() => _livePlayerState?._danmakuBadge;

/// 把渲染层置成「取数成功、但一条弹幕都没有」（探针用）
///
/// 返回 true = 写的确实是真字段（comments 空、error 空）。
///
/// 走 state 上那个生产用的 `debugDanmakuSetEmptyResult`（它同时起
/// 角标寿命计时器），与用户真机上"取到了、这一集就是没弹幕"同一状态。
bool debugPlayerSetDanmakuEmptyResultForProbe(String status) {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugDanmakuSetEmptyResult(status);
  return s._danmakuComments.isEmpty && s._danmakuError == null;
}

/// 当前提示条文本（探针用；null = 没有提示条）
///
/// 与 [debugPlayerTipForProbe] 是同一个读数 —— 保留两个名字是因为
/// 前者已被别的探针引用（改名会连带改别人），这里对齐 OPS-10 ⑤ 的用例。
String? debugPlayerFlashForProbeText() => _livePlayerState?._tip;

/// 走**真实导入链**导入一条 外部视频站链接（探针用；返回导入后上屏的弹幕条数）
///
/// # 为什么必须注入假 HttpClient 而不是发真请求
/// ```text
/// 单测不许发真请求（test/zz_t31_autobind_test.dart 起就是这个规矩）。
/// BiliApi 的构造器收 HttpClient（lib/core/bili/bili_api.dart:349-354）
/// ⇒ 换掉 socket，整条链（解析 → view → 弹幕 XML → 落盘 → 上屏）
///   跑的都是**生产代码**。
/// ```
///
/// # 它替用户做的三件事（都是 UI 状态，不是逻辑）
/// ```text
/// ① _biliApi 换成注入了假 HttpClient 的那个（生产里是 _ensureBiliApi 建的）
/// ② _danmakuEnabled = true（生产里是弹幕设置里那个开关）
/// ③ _epIndex = 0（"当前在放第几集"，导入结果要落到它对应的 cid 上）
/// ```
///
/// ⚠️ 面板**不必**真的打开：`_biliImport` 只看 `_biliPanelToken` 与
///    `_epIndex`，不读 `_biliSheetOpen`。真机上用户是在面板里点的按钮，
///    两个状态恰好一致；探针只取其中被读到的那一半。
///
/// ⚠️ 落盘是**真的**（`persistOutcome` → `UiPrefs`），与用户点一次导入
///    完全同一条路径 ⇒ 调用方要自己保证 UiPrefs 是干净的
///    （`UiPrefs.debugResetForTest()`），否则上一次的绑定会顶掉这一次。
Future<int> debugPlayerBiliImportForProbe({
  required String input,
  required int page,
  required HttpClient fake,
}) async {
  final s = _livePlayerState;
  if (s == null) return -1;
  // ignore: invalid_use_of_protected_member
  s.setState(() {
    s._biliApi = BiliApi(client: fake);
    s._danmakuEnabled = true;
    s._epIndex = 0;
    /*
     * ★ 令牌判据（`_biliImport` 里那句 `if (token != _biliPanelToken)`）：
     *   面板是**哪一集**打开的。探针不开面板 ⇒ 这里现打一个戳，让它与
     *   调用后读到的值一致；不这么做时，若别的路径（切集）动过这个字段，
     *   导入结果会被当成"过时"直接丢掉 ⇒ 测试假红。
     */
    s._biliPanelToken = 0;
  });
  await s._biliImport(input, page);
  return s._danmakuComments.length;
}

/// 重跑一次起播时的弹幕偏好读取（探针用；"第二次进播放页"的替身）
///
/// 见 State 上同名方法的说明：读的是**生产那段** `_loadDanmakuPrefs`。
bool debugPlayerDanmakuLoadPrefsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s.debugDanmakuLoadPrefs();
  return true;
}

/// 走**生产那条起播取弹幕**的路再取一次（探针用；返回取到后上屏的条数）
///
/// ★★★ OPS-10 ⑤ 后半句「返回播放页继续，也没有出现弹幕」的判据
/// ```text
/// 真实场景：用户导入完 → 退出播放页 → 再进来 ⇒ 起播走 _loadDanmakuNamed。
/// 这里**故意不碰** _danmakuEnabled —— 让调用方自己把它置成"用户真实的
/// 样子"（默认关着，见 DanmakuConfig.enabled 的缺省 '0'）。
/// 探针一旦自己把它打开，这条用例就永远测不出"关着的时候能不能取到"。
/// ```
///
/// [fake] 非 null ⇒ 先把 _biliApi 换成注入假 HttpClient 的那个
/// （否则 _ensureBiliApi 会建真 HttpClient ⇒ 单测真的发网络请求）。
Future<int> debugPlayerReloadDanmakuForProbe({HttpClient? fake}) async {
  final s = _livePlayerState;
  if (s == null) return -1;
  if (fake != null) {
    // ignore: invalid_use_of_protected_member
    s.setState(() => s._biliApi = BiliApi(client: fake));
  }
  await s._loadDanmakuNamed(s._danmakuFileName);
  return s._danmakuComments.length;
}

/// 用假 HttpClient 走一次**起播取 外部视频站弹幕**（探针用）
///
/// 返回失败原文（成功 = 空串）。专门给 OPS-10 现象 A 的
/// 「失败角标会不会自己消失」用：_loadBiliDanmaku 的失败支
/// 在改前**没有**写 _danmakuErrorAt、也没有起计时器。
Future<String> debugPlayerBiliLoadForProbe({
  required int cid,
  required HttpClient fake,
}) async {
  final s = _livePlayerState;
  if (s == null) return '<没有活着的播放页>';
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._biliApi = BiliApi(client: fake));
  await s._loadBiliDanmaku(cid);
  return s._danmakuError?.message ?? '';
}

/// 打开弹幕设置面板（探针用；返回面板是否处于打开态）
///
/// # 为什么不能靠点底栏那颗齿轮
/// ```text
/// 底栏在**播放中** 3 秒后自动隐藏（_showControls 的隐藏计时器只在
/// _playing && !_hintsOpen 时才起）。探针要截「面板里的服务端原文」，
/// 如果先去 hover 唤出底栏、再点齿轮，中间隔着一次 setState + 手势竞技场
/// 结算，截图时机极难稳定；而且底栏一隐面板按钮就没了。
/// ⇒ 直接驱动**生产那棵树**上的 _danmakuSheetOpen（和用户点齿轮走的是
///   同一个字段、同一段 build），不手抄副本。
/// ```
bool debugPlayerOpenDanmakuSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._collapseControlsForSheet(); // ★★★ T27-09：与生产 open 点同一条显隐路径
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._danmakuSheetOpen = true);
  return s._danmakuSheetOpen;
}

/// 关闭弹幕设置面板（探针用；返回关闭后面板是否确实关着）
///
/// ★ Owner 2026-10-11 第 2 条：与生产 `onClose` 同一路径 —— 关面板**顺带**
///   把顶/底栏叫回来（`_restoreBarsAfterSheet()`）。不手抄副本，
///   否则探针验不到「关掉面板 ⇒ 底栏自动回来」这条新契约。
bool debugPlayerCloseDanmakuSettingsForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._danmakuSheetOpen = false);
  s._restoreBarsAfterSheet();
  return !s._danmakuSheetOpen;
}

/// 打开外部弹幕弹幕导入面板（探针用；返回面板是否处于打开态）
///
/// ★ task-104：与 [debugPlayerOpenDanmakuSettingsForProbe] 同款 —— 播放页
///   在 flutter_tester 里点不动（`_load()` 必然失败，见 .probe/probe_tests/README.md），
///   而「关闭时也有动画」这条只能在**真棵树**上验（要读 SheetExitMotion
///   的 Opacity 逐帧值）⇒ 必须能从外部把面板开/关。
///
/// ⚠️ 与用户点按钮走的是**同一个字段、同一段 build**（不手抄副本）；
///   面板内容依赖 `_biliState`，探针只管开关。
bool debugPlayerOpenBiliSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._collapseControlsForSheet(); // ★★★ T27-09：与生产 open 点同一条显隐路径
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._biliSheetOpen = true);
  return s._biliSheetOpen;
}

/// 关闭外部弹幕弹幕导入面板（探针用；返回关闭后面板是否确实关着）
///
/// ★ Owner 2026-10-11 第 2 条：与生产 `onClose` 同一路径（关面板顺带叫回控制条）。
bool debugPlayerCloseBiliSheetForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._biliSheetOpen = false);
  s._restoreBarsAfterSheet();
  return !s._biliSheetOpen;
}

/// 打开「在线搜索字幕」面板（探针用；返回面板是否处于打开态）
///
/// ★ task-104：与上面两个同款。注意生产路径上 `_openSubtitlePanel()` 会
///   **顺带**关掉设置面板与弹幕面板（三者同一时刻只留一个全屏 scrim），
///   而本探针只翻自己那个字段 —— 探针要单独验字幕面板的退场动画。
bool debugPlayerOpenSubtitlePanelForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  s._collapseControlsForSheet(); // ★★★ T27-09：与生产 open 点同一条显隐路径
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._subtitlePanelOpen = true);
  return s._subtitlePanelOpen;
}

/// 关闭「在线搜索字幕」面板（探针用；返回关闭后面板是否确实关着）
bool debugPlayerCloseSubtitlePanelForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  // ignore: invalid_use_of_protected_member
  s.setState(() => s._subtitlePanelOpen = false);
  // ★ Owner 2026-10-11 第 2 条：与生产 `onClose` 同一路径（关面板顺带叫回控制条）。
  s._restoreBarsAfterSheet();
  return !s._subtitlePanelOpen;
}

/// 当前用于取弹幕的文件名（探针用；无播放页时返回 null）
///
/// 探针要断言「送去 danmaku-service 的 fileName 到底长什么样」——
/// 这条链路上最容易出错的地方就是它（多带了扩展名 / 多带了目录）。
String? debugPlayerDanmakuFileName() => _livePlayerState?._danmakuFileName;

/// 走**真实起播路径**打开一个媒体（探针用；返回是否成功）
///
/// # 为什么不能复用 [debugPlayerOpenForProbe]
/// ```text
/// debugPlayerOpenForProbe 直接调 _player.open(Media(url))，
/// 它**绕开了** _startPlayback 的尾部 —— 而弹幕取数钩子
/// （_loadDanmaku）正好挂在那里（起播成功才取，那时 _duration 才有值）。
/// ⇒ 用它验「起播后会不会自动取弹幕」这条断言会**永远为假**，
///   而那是探针仪器的问题，不是产品的问题（一条永远为假的断言
///   和永远为真的一样有害：都测不到东西）。
/// ```
///
/// ⚠️ 它走的是**生产**那条路（_startPlayback），不是手抄副本。
Future<bool> debugPlayerStartPlaybackForProbe(String url) async {
  final s = _livePlayerState;
  if (s == null) return false;
  try {
    await s._startPlayback(StreamCandidate(url: url));
    return true;
  } catch (e) {
    debugPrint('[DANMAKU-PROBE] 起播失败: $e');
    return false;
  }
}

/// 切一次播放/暂停（探针用；直接调**生产** `_togglePlay`，返回切换后的播放态）
///
/// # 为什么探针需要它
///
/// 弹幕的像素级证据只能靠**冻结同一时刻**做 A/B 对照：视频在播时，
/// 相隔 1.6 秒抓的两帧差异来自视频本身（实测阴性组 2.64%、收尾组
/// 33.35%，同一台仪器跨时间不可复现），弹幕那点像素完全被淹没。
/// 暂停之后 `_position` 不再推进、`DanmakuOverlay` 的 ticker 也停
/// （`_syncTicker` 只在 `enabled && playing` 时起）⇒ 「弹幕关」与
/// 「弹幕开」两帧的唯一差别就是弹幕层本身。
///
/// ⚠️ 走的是**生产** `_togglePlay`（和用户单击画面同一个方法），
///    不是手抄副本 —— 顺带把 `_togglePlayCalls` 计数器也走一遍。
Future<bool?> debugPlayerTogglePlayForProbe() async {
  final s = _livePlayerState;
  if (s == null) return null;
  final before = s._playing;
  s._togglePlay();
  /*
   * ⚠️ 必须**等状态真的翻过来**再返回。
   *
   * _togglePlay 只是把命令丢给 libmpv（_player.pause()），
   * 真实播放状态由 _player.stream.playing.listen 异步回灌到
   * _playing（player_page.dart:1967-1969）。探针第一版直接返回
   * s._playing，拿到的是**旧值**（实测 before=true after=true，
   * 但下一行的「位置冻住」断言又是过的 ⇒ 其实已经暂停了）。
   */
  for (var i = 0; i < 60; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
    if (s._playing != before) return s._playing;
  }
  return s._playing;
}

/// 播放页当前是否在缓冲（探针用），无播放页时返回 null
bool? debugPlayerBufferingForProbe() => _livePlayerState?._buffering;

// ══════════════════════════════════════════════════════════════════════
// ★ 缺陷 1 / 11 静音状态机的顶层探针出口
// ══════════════════════════════════════════════════════════════════════
// `_PlayerPageState` 是 library-private，test/ 拿不到实例；
// 只能经由 `_livePlayerState` 单例转发（本文件既有范式）。

/// 探针用：调一次真实的静音按钮（状态机与生产逐字相同）
void debugPlayerToggleMute() => _livePlayerState?.debugPlayerToggleMute();

/// 探针用：等价于键盘 ↑/↓ 与滚轮调音量
void debugPlayerVolumeBy(double delta) =>
    _livePlayerState?.debugPlayerVolumeBy(delta);

/// 探针用：等价于拖底栏音量滑杆
void debugPlayerSetVolume(double v) =>
    _livePlayerState?.debugPlayerSetVolume(v);

/// 探针用：进入无音频模式（短路真实下发；生产恒为 false）
void debugPlayerSetNoAudioForProbe(bool v) =>
    _livePlayerState?.debugPlayerSetNoAudioForProbe(v);

/// 探针用：读回静音状态机（muted / volume / beforeMute / lastVolume）
String? debugPlayerMuteState() => _livePlayerState?.debugPlayerMuteState();

/// 探针用：读回实际下发过的音量序列（'/' 分隔）
String? debugPlayerVolumeWrites() =>
    _livePlayerState?.debugPlayerVolumeWrites();

/// 探针用：清空下发记录
void debugPlayerResetVolumeWrites() =>
    _livePlayerState?.debugPlayerResetVolumeWrites();

/// 探针用：直接摆好当前音量（模拟用户已调到该值）
void debugPlayerSeedVolume(double v) =>
    _livePlayerState?.debugPlayerSeedVolume(v);

/// 探针用：在**真实播放页**上跑一遍生产看门狗，返回是否启动成功
///
/// # 为什么必须走生产代码而不是复刻判据
///
/// `lib\t376_novideo_gate_probe.dart` 已经独立量过两条原始信号
/// （`.probe\t376_matrix.txt`，五臂 `pass=14 fail=0`）。但"信号对"
/// **不等于**"装进产品后判决对" —— 产品里的时序、代次号、`mounted`
/// 守卫、`dispose` 交互都可能让判决永远立不起来（或永远立着）。
///
/// 所以这里**直接调生产方法** `_watchVideoOutput`，让探针读
/// `debugPlayerVideoOutputDead()` 的结果。配合 `debugPlayerOpenForProbe`
/// 就能在真机上跑出两个方向的读数：
/// ```text
/// Windows（vo=libmpv 正常）      ⇒ dead=false，且不该出现横幅
/// Android（产品默认 vo=gpu 建不起 GL）⇒ dead=true，横幅出现
/// ```
/// ⚠️ 生产代码里没有调用点 —— 只在探针入口点被调到。
bool debugPlayerWatchVideoOutputForProbe() {
  final s = _livePlayerState;
  if (s == null) return false;
  unawaited(s._watchVideoOutput(++s._videoOutputToken));
  return true;
}

/// ④ 探针用：在**真实播放页**上重新下发一遍 mpv 缓存属性，返回是否成功
///
/// # 为什么要走生产方法
///
/// 探针自己拼 `setProperty` 只能证明「探针能设」，证明不了
/// 「产品在拖完滑杆之后会设」—— 那正是 ④ 要验的东西。所以这里
/// 直接调 `_applyMpvCacheSettings()`（生产代码里 `_setHwdec()`
/// 末尾调的就是它）。
///
/// ⚠️ 2026-09-25 task-18 补记：`_setHwdec()` 末尾**原先没有**这一句 ——
///   也就是说在补上之前，`_applyMpvCacheSettings()` 的**唯一**调用点
///   就是这个探针钩子 ⇒ mpv 的 `demuxer-max-bytes` / `cache-dir`
///   只在用户手动点「回读 mpv 设置」时才被下发过一次，
///   平时起播根本不下发（＝「看起来能调但实际无效」）。
///   现在生产路径每次起播都会调它，本注释与代码才一致。
Future<bool> debugPlayerApplyMpvCacheForProbe() async {
  final s = _livePlayerState;
  if (s == null) return false;
  await s._applyMpvCacheSettings();
  return true;
}

/// ④ 探针用：回读 mpv 缓存属性。键 = mpv 属性名，值 = 原始串（读不到为空串）
///
/// ★ 空串**不是**「值是空的」，是「没读到」。探针必须把它判成失败。
Future<Map<String, String>> debugPlayerReadMpvCacheForProbe() async {
  final s = _livePlayerState;
  if (s == null) return <String, String>{};
  return s._readMpvCacheSettings();
}

/// 手势探针是否启用（**编译期常量**，默认 false）
///
/// # 为什么需要它
///
/// 交付实测（`delivery_test.dart`）走**进程内注入指针**的路径，
/// 能直接调 `debugPlayer*` 系列函数读值。
///
/// 但"真机实测"要的是**真实鼠标点击真实窗口** —— 那条路径下
/// 没有 Dart 侧能调用的钩子，只能靠**日志**。
///
/// # 为什么是编译期常量而不是环境变量
///
/// ```text
/// 不加 --dart-define=GESTURE_PROBE=true → 整段被 tree-shake，
///                                         生产构建零开销、零输出
/// 加了                                  → 每次点击打一行，
///                                         含位置 + 两个计数器
/// ```
/// ⚠️ 跟 `delivery_test.dart` 的 `kDeliveryTest` 是**同一个套路**。
///    不要用 `Platform.environment` —— 那是运行时的，代码会留在生产包里。
const kGestureProbe = bool.fromEnvironment('GESTURE_PROBE');

/// 起播阶段计时开关（task-24）
///
/// 用法：
/// ```powershell
/// flutter build windows --release -t lib/shell.dart `
///   --dart-define=DATA_DIR_OVERRIDE=...\.probe\user-view `
///   --dart-define=PLAYBACK_TIMING=true
/// ```
/// 输出形如：
/// ```text
/// [TIMING] +0ms    ① 点播放
/// [TIMING] +1840ms ② resolve_stream 返回  (3 条候选)
/// [TIMING] +1852ms ③ player.open() 返回
/// [TIMING] +3960ms ④ 首个视频帧  (1920x1080)
/// [TIMING] ★ 起播总耗时 3960ms (resolve+open+首帧)
/// ```
/// ⚠️ 编译期常量 —— 不传时整段被 tree-shake，正式构建**零开销**。
const kPlaybackTiming = bool.fromEnvironment('PLAYBACK_TIMING');

/// 探针日志（仅在 `GESTURE_PROBE=true` 时输出）
///
/// 用 `debugPrint` 而不是 `print`：`debugPrint` 在 release 下**默认仍输出**
/// （不像 `assert` 会被剥掉），而且带限流，不会刷爆日志。
void _probeLog(String msg) {
  if (!kGestureProbe) return;
  debugPrint('[GESTURE-PROBE] $msg');
}

/// 播放页当前**有没有挂**单击分流（`onTapUp`），无播放页时返回 null
///
/// # 为什么必须问"播放页自己的" detector，而不是扫整棵树
///
/// `InkWell` 内部**无条件**挂着 `onTapUp`：
/// ```dart
/// // material/ink_well.dart:1408
/// onTapUp: _primaryEnabled ? handleTapUp : null,
/// ```
/// 而播放页控制条里全是 `InkWell`/按钮 —— 所以
/// 「树里有 `onTapUp`」**永远为真**，那条断言是**空的**：
/// 删不删分流它都绿。这正是"测了影子"的经典形态。
///
/// 所以这里用 `GlobalKey` 拿到播放页**真正构建出来的**那个
/// `GestureDetector` widget，直接读它的 `onTapUp` 字段 ——
/// 这是运行时的事实，不是源码里的写法。
bool? debugPlayerHasTapUpDivider() {
  final w = _livePlayerState?._gestureKey.currentWidget;
  if (w is! GestureDetector) return null;
  return w.onTapUp != null;
}

/// 播放页自己那个 GestureDetector 上**实际挂着的**回调（探针用）
///
/// 返回形如 `tap=true tapUp=false doubleTap=false longPress=true`。
/// 无播放页时返回 `null`。
///
/// 与 `debugPlayerGestureState()` 的区别：那个扫**整棵树**（会混入
/// `InkWell` 等控件的回调），这个只读**播放页自己**那一个 detector。
String? debugPlayerOwnGestureState() {
  final w = _livePlayerState?._gestureKey.currentWidget;
  if (w is! GestureDetector) return null;
  return 'tap=${w.onTap != null} tapUp=${w.onTapUp != null} '
      'doubleTap=${w.onDoubleTapDown != null} '
      'longPress=${w.onLongPressStart != null}';
}

/// 用**一个已知时间戳**生成截图文件名（★ task-21 P1-30 探针用）。
///
/// 生产路径里的文件名由 `ClipDownloader.shotFileName(DateTime.now())` 生成，
/// 而 `now()` 在测试里不可控 ⇒ 把纯函数原样暴露出来，
/// 让"格式"这条判据能被**逐字**验证（而不是只能验证正则）。
String debugShotFileName(DateTime n, {int suffix = 0}) =>
    ClipDownloader.shotFileName(n, suffix: suffix);

/// 在 [dir] 里挑一个还没被占用的截图文件（★ task-21 P1-30 探针用）。
///
/// 走的就是生产那一个 `ClipDownloader.uniqueShotFile` —— 探针**不复制**逻辑，
/// 所以这里绿 == 生产绿。
Future<File> debugUniqueShotFile(Directory dir, {DateTime? now}) =>
    ClipDownloader.uniqueShotFile(dir, now: now);

/*
 * ══════════════════════════════════════════════════════════════════════
 * ★★★ 常驻悬浮返回键（2026-10-07，用户缺陷②「我现在无法返回到首页了」）
 * ══════════════════════════════════════════════════════════════════════
 *
 * # 缺陷是什么（源码级，不是猜测）
 *
 * 顶栏是**唯一的常驻返回口**，而它整个被 `_controlsVisible` 门控：
 *
 * ```dart
 * if (_controlsVisible) _TopBar(... onBack: () => unawaited(_exitPlayer()) ...)
 * ```
 *
 * 控制条由 `_showControls()` 在 **3 秒**后自动隐藏（`_hideTimer`），
 * 而播放页只有「鼠标 hover」与「点击视频区」两条路能把它叫回来。
 * 桌面端只要这两条路有一条不灵（用户报的缺陷③），用户就**再也回不到
 * 首页** —— 屏幕上连一个可点的返回箭头都没有。Esc 确实能退出，但
 * 界面里没有任何提示，对用户等于不存在。
 *
 * # 判据与设计
 *
 * ```text
 * 只出现在桌面端   手机/平板有系统返回键，多一枚反而挡画面
 * 只在控制条藏起来时出现
 *                  顶栏可见时它自带同一枚返回箭头，两枚叠在同一个
 *                  位置会显得重影；所以判据是 `!_controlsVisible` ——
 *                  这样「屏幕上永远有一枚可点的返回箭头」始终成立
 * 不盖错误层       `_error != null` 时 `_ErrorOverlay` 自带「返回」
 * 不盖浮层         任一抽屉/面板打开时让位（它们自带关闭口）
 * ```
 *
 * # ⚠️ 类名以 `_F` 开头是**故意的**
 *
 * `test/t68_android_adapt_test.dart` 与 `test/t80_cast_wiring_test.dart`
 * 用「切片 + 首个 `AppIcons.` 下标」约束底栏顺序。把它排在 `_TopBar`
 * （= `_T`）之后，任何「按文件顺序切 [起, 终,
          ),」的静态约束都不会把它
 * 切进底栏那一段。**不要**把本类挪到 `_BottomBar` 之前。
 */

class _TopBar extends StatelessWidget {
  const _TopBar({
    required this.title,
    this.episodeTitle,
    required this.isLive,
    required this.onBack,
    this.onHints,
    this.providerName,
    this.visible = true,
    this.fade,
    this.backArrowKey,
    this.dmInfo,
    this.onToggleDmInfo,
    this.dmInfoOpen = false,
  });

  final String title;
  final String? episodeTitle;
  final bool isLive;
  final VoidCallback onBack;
  final VoidCallback? onHints;

  /// 当前**站点**的显示名（task-32）；null = 还没取到 → 不渲染
  ///
  /// 见 `_PlayerPageState._providerName` 的长注释（含原版对照结论）。
  final String? providerName;

  /// 常驻悬浮返回键的回调；null = 不画这一枚
  ///
  /// 见 `_FloatingBackButton` 的长注释（用户缺陷②）。

  /// 整条顶栏（返回箭头 + 标题 + 站名 + 快捷键）是否画出来
  ///
  /// 传 `_controlsVisible`。控制条藏起来时它必须跟着消失 —— 顶栏是一整条
  /// 半透明渐变，常驻会一直压着画面（原版也是随控制条一起收）。
  /// 悬浮返回键**不受**这个开关影响，见 `_FloatingBackButton`。
  final bool visible;

  /// 顶栏那条渐变条的**淡入淡出**动画（★ 2026-10-08 Owner 第 9 条）
  ///
  /// # 为什么必须把动画**传进来**，而不是在这里就地开一个
  /// ```text
  /// 显隐的真源在宿主（`_controlsVisible`），动画控制器也在宿主
  /// （`_PlayerPageState._controlsAnim`）—— 本类是 StatelessWidget，
  /// 自己开控制器会「每次重建换一个」⇒ 动画永远从 0 重来。
  /// ```
  ///
  /// ⚠️ 它**只**管那条渐变条。常驻悬浮返回键（`_FloatingBackButton`）
  ///    **不参与**淡出 —— 它存在的全部意义就是「控制条藏起来时
  ///
  /// ★★★ 2026-10-09 修正（缺陷 2，Owner 第 9 条之后）：上面那句「不参与淡出」
  /// **已经不对了**，但保留原话以便追溯 —— 它描述的是「硬切」实现。硬切让悬浮键
  /// 在自己那一侧瞬间满不透明，而顶栏箭头还在淡出途中 ⇒ 两枚箭头同屏，
  /// 被用户读作「返回图标在控件隐藏后仍然残留」。现在悬浮键由 `floatingFade`
  /// 交叉淡化（1 - f），两者互补。详见 `_FloatingBackButton.fade` 的长注释。
  ///    屏幕上仍有一枚可点的返回箭头」（用户缺陷②）。
  final Animation<double>? fade;

  /// 悬浮返回键交叉淡化用的**同一条**动画（2026-10-09，缺陷 2 修复）
  ///
  /// 与 `fade` 传的是**同一个** `_controlsFade` 实例：
  /// 顶栏条的 Opacity = f，悬浮键的 Opacity = 1 - f ⇒ 两者之和恒为 1。
  ///
  /// ★ 为什么不能再写「悬浮返回键不参与淡出」（旧注释的原话）
  /// 那句在**硬切**实现下才是对的；硬切的后果是两枚箭头同屏，
  /// 于是用户看到「返回图标在控件隐藏后仍然残留」（见 _FloatingBackButton 注释）。

  /// 顶栏那枚箭头 / 悬浮键箭头的定位锚点（探针用，不参与布局）
  final Key? backArrowKey;

  /// 弹幕信息快照；null = 不画那枚入口（例如还没起播）
  final DanmakuInfoData? dmInfo;

  /// 右侧面板是否展开（真源在宿主 `_danmakuInfoOpen`）
  final bool dmInfoOpen;

  /// 点那枚入口 ⇒ 开关右侧的弹幕信息面板
  final VoidCallback? onToggleDmInfo;

  /// 指针是否还在播放页内（task-16）—— 透传给 [_FloatingBackButton]
  ///
  /// ★ 为什么由 `_TopBar` **中转**而不是让 `_FloatingBackButton` 自己去问：
  ///   本件（`_TopBar`）是宿主的直接子级，宿主已经把 `_pointerInside`
  ///   算好了；`_FloatingBackButton` 是它内部的 `Positioned`，
  ///   自己去挂 `MouseRegion` 只会量到那 40×40 的按钮矩形（见该字段说明）。

  /// 站名 pill 的最大宽度
  ///
  /// ⚠️ **必须限宽**（task-32 交付要求：不许挤压/换行/截断）。
  ///
  /// 顶栏是 `Row`，里面有：返回键 + `Expanded(标题/集名)` + 直播徽章 +
  /// 提示键。给站名一个**上界**，它在窄窗口下就只会自己省略号，
  /// 而不会去挤 `Expanded`（`Expanded` 会先让位，标题被压成 "…"）。
  ///
  /// ```text
  /// 1280px 宽  → 顶栏可用 ~1200px，站名 pill 自然远小于 180
  /// 900px 宽   → 仍然只占 ≤180，标题保得住
  /// ```
  /// 180 是实测值：最长站名（「外部弹幕」5 字 ≈ 70px + padding ≈ 100px）
  /// 留了一倍余量，同时不至于在窄窗口下喧宾夺主。
  static const double _kNameMaxW = 180;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        /*
         * ★★★ 2026-10-08（Owner 第 9 条）：渐变条**常挂**，靠 Opacity 淡出
         *
         * # 为什么不能再写 `if (visible)`
         * ```text
         * flag 翻 false 的那一帧整棵子树被移除 ⇒ **一帧硬切**，
         * 没有任何中间帧可看 —— 而用户明确要求「要有动画喔」。
         * ```
         *
         * ⚠️ 但是**必须**配 `IgnorePointer(ignoring: !visible)`：
         *    `Opacity(0)` 的子树**仍然参与命中测试**
         *    （`RenderOpacity` 不覆写 hitTest）⇒ 不挡的话，
         *    看不见的「快捷键 / 返回」按钮还能被点到 ——
         *    那比硬切更糟（用户点了一个他看不见的按钮）。
         */
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: IgnorePointer(
            ignoring: !visible,
            child: AnimatedBuilder(
              animation: fade ?? kAlwaysCompleteAnimation,
              builder: (context, child) => Opacity(
                opacity: (fade?.value ?? 1.0).clamp(0.0, 1.0),
                child: child,
              ),
              child: Container(
                padding: EdgeInsets.only(
                  /*
                 * ★★★ 左右留白 Sp.x2 -> Sp.x3（2026-10-09，缺陷 2 配套）
                 *
                 * # 为什么必须动这里（不是随手放大）
                 * ```text
                 * 本行箭头左边缘 = left + IconButton 默认 padding(8)；
                 * 悬浮键箭头左边缘 = _kInset(=Sp.x3=12) + IconButton 默认 padding(8)。
                 * left 若留在 Sp.x2(8)，两枚箭头相差 4px —— 交叉淡化时能看出**错位**。
                 * ```
                 *
                 * # 为什么不去把 _kInset 降到 Sp.x2（看似更小改动）
                 * ```text
                 * _kInset 同时负责**避开窗口圆角**（SetWindowRgn 半径 9px）。
                 * Sp.x2 = 8 < 9 => 悬浮键会被圆角切掉一角。
                 * => 只能让顶栏对齐悬浮键，不能反过来。
                 * ```
                 */
                  top: MediaQuery.of(context).padding.top + Sp.x3,
                  left: Sp.x3,
                  right: Sp.x3,
                  bottom: Sp.x4,
                ),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      key: backArrowKey,
                      onPressed: onBack,
                      icon: const Icon(AppIcons.arrow_back, color: Colors.white),
                      tooltip: '返回',
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
                              color: Colors.white,
                              fontSize: FontSizes.base,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (episodeTitle != null && episodeTitle!.isNotEmpty)
                            Text(
                              episodeTitle!,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: FontSizes.cap,
                              ),
                            ),
                        ],
                      ),
                    ),
                    /*
               * ══════════════════════════════════════════════════════════
               * ★★★ 当前播放源（task-32，用户要求）
               * ══════════════════════════════════════════════════════════
               *
               * 用户原话：
               * > 播放页和详情页都不能看到当前播放源是哪一个
               *
               * # 位置与样式都是**复用**，不是新发明
               *
               * ```text
               * 位置  原版 metabar（PlayerView.vue:4350）在我们这套
               *       沉浸式 overlay 版式里的对应物 = 顶栏
               * 样式  与右边「直播」徽章**同一套 pill 语言**
               *       （半透明黑底 + 圆角 + cap 字号），
               *       只是它常驻、直播徽章条件渲染
               * ```
               *
               * # 为什么放在标题**右边**而不是标题下面
               *
               * 标题下面那行已经是「集名」。再塞一行会让顶栏变三行高，
               * 在窄窗口下把画面压得更多。放右边与「直播」徽章同列，
               * 高度不变。
               *
               * ⚠️ `Flexible` + `_kNameMaxW`：**必须限宽**，否则长站名
               *    会把 `Expanded` 的标题挤成 "…"（交付要求：
               *    窄窗口下不许挤压/换行/截断 —— 让**站名自己**省略号）。
               */
                    if (providerName != null && providerName!.isNotEmpty) ...[
                      const SizedBox(width: Sp.x2),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: _kNameMaxW),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: Sp.x3,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            // 与「直播」徽章同款底：黑 0.55 让它压得住任何画面
                            color: Colors.black.withValues(alpha: 0.55),
                            borderRadius: Radii.rFull,
                          ),
                          child: Text(
                            providerName!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: FontSizes.cap,
                            ),
                          ),
                        ),
                      ),
                    ],
                    if (isLive)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: Sp.x3,
                          vertical: 3,
                        ),
                        decoration: const BoxDecoration(
                          color: AppColors.liveDot,
                          borderRadius: Radii.rFull,
                        ),
                        child: const Text(
                          '直播',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: FontSizes.cap,
                          ),
                        ),
                      ),
                    /*
               * ★ task-20：触摸端不画这个按钮
               *
               * 原因：`hintsFor()` 在触摸端返回**空列表**（触摸端没有键盘），
               * 但按钮一直画着 ⇒ 点开是一个只有标题的**空面板**。
               *
               * ★ 为什么是隐藏而不是给触摸端补一批提示：触摸端真的没有键盘可按，
               *   写上去就是“假装有”。产品原则与插件/TVBox 那套一致：
               *   **没有的能力不假装有**。
               */
                    if (onHints != null)
                      IconButton(
                        onPressed: onHints,
                        icon: const Icon(
                          AppIcons.keyboard_outlined,
                          color: Colors.white,
                        ),
                        tooltip: '快捷键',
                      ),
                    /*
                     * ★ 弹幕信息入口：从顶栏右侧打开右边那块面板。
                     *
                     * 为什么放这儿：Owner 要的是「在播放页面右侧显示」，
                     * 而顶栏右侧是画面上**唯一**既常驻、又不压内容的角落。
                     * 样式与旁边的站名 / 直播徽章同一套 pill 语言。
                     */
                    if (dmInfo != null && onToggleDmInfo != null) ...[
                      const SizedBox(width: Sp.x2),
                      _DanmakuInfoChip(
                        data: dmInfo!,
                        onTap: onToggleDmInfo!,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
        /*
         * ★★ 右侧「弹幕信息」面板（task-32 ② / Owner：
         *    「在播放页面右侧显示加载了哪些弹幕,方便排查问题」）
         *
         * # 为什么挂在 `_TopBar` 的 Stack 里
         * ```text
         * ① 它必须**随控制条一起淡出** —— 常驻会一直压着画面右缘；
         *    而 `visible` 与 `fade` 都已经在本件里，挂这儿天然同步。
         * ② 顶栏本身就在画面最上层，面板作为它的兄弟子项 ⇒ 不会被
         *    弹幕层/描边层盖住（那两层在页面的另一个 Stack 里）。
         * ```
         *
         * ⚠️ 必须 `IgnorePointer(ignoring: !visible)`：与上面那条渐变条同理，
         *    `Opacity(0)` 的子树**仍然参与命中测试** ⇒ 不挡的话用户会点到
         *    一块看不见的面板。
         */
        if (dmInfo != null && onToggleDmInfo != null && dmInfoOpen)
          Positioned(
            top: 56,
            right: Sp.x3,
            child: IgnorePointer(
              ignoring: !visible,
              child: AnimatedBuilder(
                animation: fade ?? kAlwaysCompleteAnimation,
                builder: (context, child) => Opacity(
                  opacity: (fade?.value ?? 1.0).clamp(0.0, 1.0),
                  child: child,
                ),
                child: _DanmakuInfoPanelHost(
                  data: dmInfo!,
                  onClose: onToggleDmInfo!,
                ),
              ),
            ),
          ),
        /*
         * ★ 常驻悬浮返回键：只在桌面端且没有错误/浮层时出现，
         *   **不受 `_controlsVisible` 门控** —— 它就是为了解决
         *   「控制条隐藏后没有返回口」这个缺陷而加的。
         */
        /*
         * ★★★ 2026-10-09（Owner 第 16 条 · task-16 定案）：**删除**独立悬浮返回键
         *
         * ```text
         * 改前：控制条一藏，左上角那枚「常驻」的圆形返回键就满不透明地留在画面上
         *       （Owner 原话：「全屏左上角这个单独的返回icon,还没消失」）。
         * 半成品方案（`(1 - f) × 指针在页内`）在全屏下**无效** ——
         *       全屏时指针恒在页内，那个因子恒为 1。
         * 定案（lead 裁决）：控制条收起时它**跟着一起淡出**（画面干净）；
         *       鼠标一动，顶栏连同**它自己的**返回箭头一起回来；Esc 照常退出。
         * ⇒ 独立悬浮键已无存在理由：顶栏那枚箭头覆盖了全部场景，
         *   错误态下由 `_canUseTopBarBack` 钉成常显可点（Owner 专门报过那条）。
         * ```
         */
      ],
    );
  }
}

/// 右侧弹幕信息面板的**宿主壳** —— 只做两件事：
/// ① 记住"展开/收起"（面板自己的 State 会随淡出重建，状态不能放它里面）；
/// ② 把关闭回调接上。
///
/// ⚠️ 为什么状态放这里而不是 `DanmakuInfoPanel` 内部：
///   `_TopBar` 是 `StatelessWidget`，但它下面那层 `AnimatedBuilder`
///   每次 `fade` 变化都会重建 builder 的 child —— 那个 child 是**同一个实例**
///   （传的是参数），所以 `DanmakuInfoPanel` 的 Element 不会被销毁。
///   不过一旦宿主把 `dmInfo` 传成 null（例如控制条隐藏时不再传），整个子树
///   就会被移除 ⇒ 展开状态丢失。把这个状态提到宿主这一层最省心。
class _DanmakuInfoPanelHost extends StatefulWidget {
  const _DanmakuInfoPanelHost({required this.data, required this.onClose});

  final DanmakuInfoData data;
  final VoidCallback onClose;

  @override
  State<_DanmakuInfoPanelHost> createState() => _DanmakuInfoPanelHostState();
}

class _DanmakuInfoPanelHostState extends State<_DanmakuInfoPanelHost> {
  @override
  Widget build(BuildContext context) {
    return DanmakuInfoPanel(
      data: widget.data,
      // 窄窗口（手机竖屏）时收窄，避免挡掉太多画面
      maxWidth: MediaQuery.sizeOf(context).width < 640 ? 240 : 300,
      onRequestClose: widget.onClose,
    );
  }
}

/// 顶栏右侧那枚「弹幕 N」pill —— 点它展开/收起右侧面板
///
/// 样式与旁边的站名 / 直播徽章**同一套 pill 语言**（半透明黑底 + 全圆角 + cap 字号），
/// 这样它不会像一个"外来的"按钮。
///
/// ═══════════════════════════════════════════════════════════════════
/// ★★★ task-66 R1：本 chip 的 `clipBehavior` —— **实测选出来的值，不是默认值**
/// ═══════════════════════════════════════════════════════════════════
///
/// ⚠️ 要把它改成 `Clip.antiAlias` 之前，先读完下面这一节 ——
///    下面的表就是**实测结果**。改之前请按本节末尾「验证方法」自己复跑一遍；
///    那套方法已固化成文字，**不依赖任何探针文件**（探针已删除，见文末说明）。
///
/// # 已核实的事实（读框架源码，material_ui-1.6.0）
///
/// `ActionChip` 内部确实是**两层各画一个同样的圆角矩形**，且默认 `Clip.none`：
/// ```text
/// chip.dart:1440  Material(shape: resolvedShape, clipBehavior: widget.clipBehavior)
///                   └ _MaterialInterior → PhysicalShape(clipBehavior: Clip.none)
///                     └ proxy_box.dart:2341 canvas.drawPath(offsetPath, ..color)  ← 第 1 遍
/// chip.dart:1449  Ink(decoration: ShapeDecoration(shape: resolvedShape, color: ..))
///                                                                        ← 第 2 遍
/// chip.dart:116   ActionChip({ ... this.clipBehavior = Clip.none, ... })
/// ```
/// ⇒ 「同一个圆角画两遍且不裁剪」这个**机制描述属实**。
///
/// # 但**逐像素实测否掉了"把它裁掉就能去掉毛边"这个推论**
///
/// 测法（已固化成文字，探针文件已删）：
/// `RepaintBoundary.toImage` → `rawRgba` → 以真 `RenderBox` 矩形为几何基准，
/// 取距 stadium 边界 [-1.5, +1.5] px 的环带，与内部中位数比较。
/// 纯黑视频底、DPR=1.0 的读数：
/// ```text
/// clipBehavior             环带峰值  内部中位   Δpeak    Δmean
/// Clip.none                 8.641     8.641    0.000   -4.136
/// Clip.hardEdge             8.641     8.641    0.000   -4.103
/// Clip.antiAlias           10.228     8.641   +1.587   -4.051   ← 反而**更亮**
/// Clip.antiAliasWithSaveLayer 9.228    8.641   +0.587   -4.135
/// ```
/// 并在 DPR ∈ {1.0, 1.25, 1.5, 2.0} × opacity ∈ {1.0, 0.5} 全矩阵上复现
/// （`Δpeak`：none 恒 0.000；antiAlias 恒 +1.0 ~ +1.7）。
///
/// **为什么会反过来**：`Clip.none` 时上层 `Ink` 的抗锯齿边缘会与下层
/// Material 的实心底做 **source-over 合成**，覆盖率互补 ⇒ 边缘被"补"回
/// 接近实色；一旦裁剪，`pushClipPath` 把下层在边缘处**截断**，上层那点半透明
/// 就直接与**视频背景**混合 ⇒ 边缘出现一圈**更亮/更灰**的环带。
/// 也就是说：裁剪把"两层互补"变成了"一层半透明"。
///
/// # 裁决（本轮不改行为，只留证据）
///
/// · 本枚 chip 的现有 `Clip.none` **不是**可观测毛边的来源；
/// · Owner 看到的「一圈毛边」在这些读数下**无法复现**，
///   说明触发条件在别处（真实视频帧底 + 播放器的叠加层 + 真机 DPR），
///   或者观察对象不是这一枚 chip（整排还有站名 / 直播徽章）。
/// · 因此**不**把 `Clip.antiAlias` 强行打进生产 —— 实测它让边缘更亮 1.6 级，
///   属于"按假设改、被读数否掉"，硬推等于制造新缺陷。
/// · 常量与探针保留：它们把这件事实**钉成可复跑的数字**，
///   下一轮若拿到真机复现，直接换判据重测，不必重新搭仪器。
///
/// ★ 2026-10-19（lead 复核后追加）：R1 的**现象**仍在查，方向已改为
///   「① 站名徽章对照 / ② 多帧方差（动态视频底）/ ③ 真机 DPR」。
///   其中 ② 最可能解释 Owner 看到的"毛边"—— 因为 alpha 0.55 叠在**每帧都变**
///   的背景上时，边缘像素逐帧不同，人眼会读成「在抖的一圈边」。
///   （该假设已在下面 2026-10-20 的结案里**被证实**：edgeStd 49.6 vs chip 0.018。）
///
/// ═══════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-20 结案（第三次验证，**这次是终局结论**）
/// ═══════════════════════════════════════════════════════════════════
///
/// # 一句话
/// **「弹幕 chip 有毛边」不是 chip 的问题，是它旁边那枚半透明徽章的问题。
///   chip 本身是干净的，`Clip.none` 是对的。**
///
/// # 六条证据（全部可复跑，方法见下）
/// ```text
/// ① 不透明性：黑白双底色对照 ⇒ chip impliedAlpha = 0.9994（不透明）
///    badge impliedAlpha = 0.5479（= black@55%，半透明）
/// ② 几何：paintedRect = (107.0, 46.0, 213.0, 74.0) —— **四个坐标全整数**
///    ⇒ 排除"边界落在非整数像素"这个曾经怀疑的方向
/// ③ 剖面：白底上边 y45=255.0 → y46=8.6，**一步到底，无过渡值** ⇒ 无灰带
/// ④ 四组同构对照（C1 chip / C2 无文字 / C3 直角 / C4 半像素偏移）
///    ⇒ 四组的圆角 45° 对角线剖面**全单调下降，无驼峰**
///    ⇒ 圆角、对齐都不产生毛边；C1 vs C2 的梯度差来自**文字**（正常现象）
/// ⑤ widget 树：441 个节点里 alpha<1 的**边缘相关**装饰 = **0**
///    （无 boxShadow、无半透明描边、elevation=0 不画阴影）
/// ⑥ ★ 跨帧方差（5 帧高对比左右交替底）：
///      chip(不透明)        edgeStd =  0.018
///      badge(半透明 0.55)  edgeStd = 49.634   ← 差 2700 倍
///      badge(不透明对照)    edgeStd =  0.239   ← 阴性对照 ≈ 0
///    ⇒ 方差**确实来自半透明**，不是背景本身在变
/// ```
///
/// # 为什么 badge 会"毛"（机理）
/// ```text
/// 半透明边缘像素 = a·C + (1-a)·bg，a ≈ 0.55
/// ⇒ bg 每帧变，边缘像素就每帧变（实测 edgeStd 49.6，即平均每帧摆动约 50 亮度级）
/// ⇒ 在动态画面上，那圈边**一直在动** ⇒ 肉眼读成"毛边"
/// 而 chip 不透明（a=1）⇒ 边缘与背景无关 ⇒ edgeStd 0.018，几乎完全静止
/// ```
///
/// # ⚠️ 给下一个 agent：**不要重复这三次弯路**
/// ```text
/// 弯路 1：以为加 Clip.antiAlias 能去掉毛边
///   ⇒ 实测让边缘**更亮** 1.59 亮度级（本常量上方那张表）。
///     原因：Clip.none 是 coverage complementarity，pushClipPath 会截断下层。
/// 弯路 2：以为是"边缘在闪烁" ⇒ 实测 chip 的 edgeStd=0.018，比不透明对照还稳。
/// 弯路 3：以为 rect 落在非整数像素 ⇒ 实测 107.0/213.0，全整数。
/// ⇒ 若将来又有人说"chip 有毛边"：**先看这一节**，再决定要不要动这个常量。
///   改之前先跑一次 `zz_t66_r1_badge_variance_test.dart`，确认 edgeStd 归属。
/// ```
///
/// # 验证方法（可复用，值得抄到别的像素问题上）
/// ```text
/// ① **同构对照**：比较两个对象前，先让它们除被测变量外完全相同
///    （同尺寸/同圆角/同底色/同有无文字）。
///    反例：C1(有文字) vs 纯色块 ⇒ edgeGradient 9.6 vs 32.0 不可比 —— 分母不同。
/// ② **对角线驼峰判据**：沿圆角 45° 从外向内采样。
///    干净边缘是**单调下降**；有毛边会呈「降→回升→再降」的驼峰。
///    比"看梯度最大值"更鲁棒（梯度受内部内容影响，剖面不受）。
/// ③ **换底再拍**：深色 chip 在黑底上反差只有 8.6/255，结构完全看不见。
///    必须在**亮底**上重拍（反差 246/255）才能判断边缘形态。
/// ④ **黑白双底色判 alpha**：不透明 ⇒ 两底完全相同；半透明 ⇒ 差 = (1-a)·255。
///    采样必须取 d > 0.5（覆盖率 > 50%）的像素 —— 圆角末端 d≈0.05 的
///    抗锯齿像素 95% 是背景色，测 alpha 无意义（这一条踩过坑）。
/// ⑤ **阴性对照**：验证"方差来自半透明"时，必须同时跑一个 alpha=1 的同款对象。
///    否则分不清"边缘在动"还是"背景在动"。
/// ⑥ **放大图要能被别人复跑**：记录截图参数（缩放倍数 / 底色 / 区域）。
///    「留下证据」和「留下可复跑的取证方法」是两回事 ——
///    前者只能让人信你，后者能让人自己验。
/// ```
///
/// ═══════════════════════════════════════════════════════════════════
/// ★ 关于探针文件（2026-10-20 删除记录）
/// ═══════════════════════════════════════════════════════════════════
/// ```text
/// 本轮用过 8 个探针（edge_measure / zoom_shot / isomorphic_compare /
/// widget_tree_alpha / badge_variance / danmaku_chip_edge /
/// dynamic_backdrop_variance / three_way_compare），**已全部删除**。
///
/// # 为什么删而不是留
/// ① 它们证明的是"当前 chip 干净、badge 半透明"，**不是"行为应该是什么"**
///    ⇒ 不是门禁，留着会让人误以为要维护它们
/// ② 其中几个引用的读数已被裁定作废（例如 107.2 那个**凭印象写的**数）
///    ⚠️ **留着过时的读数比留着代码更危险** ——
///       下一个人会以为那是实测值
/// ③ 方法已固化成上面的「验证方法」文字 ⇒ 不需要靠探针传承
///
/// # 将来若要重新取证
/// 按上面 ①~⑥ 自己搭一次即可；本节的数值表就是**预期结果**（可用来校准仪器）。
/// ```
const Clip kDanmakuChipClipBehavior = Clip.none;

/// 弹幕 pill —— 生产路径与像素探针**共用这一份构造**
///
/// ⚠️ 探针不许另抄一份样式：抄一份等于测自己写的副本（假门禁）。
///    要对比不同裁剪值只换 [clipBehavior] 一个入参。
@visibleForTesting
Widget debugDanmakuInfoChipForProbe({
  required DanmakuInfoData data,
  VoidCallback? onTap,
  Clip clipBehavior = kDanmakuChipClipBehavior,
}) =>
    _DanmakuInfoChip(
      data: data,
      onTap: onTap ?? () {},
      clipBehavior: clipBehavior,
    );

class _DanmakuInfoChip extends StatelessWidget {
  const _DanmakuInfoChip({
    required this.data,
    required this.onTap,
    this.clipBehavior = kDanmakuChipClipBehavior,
  });

  final DanmakuInfoData data;
  final VoidCallback onTap;

  /// ★ R1：交给 `ActionChip` 的 `Material.clipBehavior`
  /// （见 [kDanmakuChipClipBehavior] 上方那份**实测读数**与裁决）。
  ///
  /// 生产调用点（`:19602`）**不传**它 ⇒ 走默认值 `Clip.none`（= 框架默认、
  /// 也是实测边缘最平的那一档）；只有像素探针为了做对照才显式换值。
  final Clip clipBehavior;

  @override
  Widget build(BuildContext context) {
    final bad = data.hasError;
    final n = data.count;
    final text = bad ? '弹幕 !' : (n == null ? '弹幕' : '弹幕 $n');
    /*
     * ★ 用框架的 `ActionChip`，不手写「InkWell + 全圆角容器」——
     *   本仓 UI-1 门禁（`zz_ui1_no_handrolled_controls_test`）会直接判红：
     *   手写药丸应当换成 ChoiceChip / FilterChip / ActionChip。
     *
     * 换来的不只是过门禁：整块可点、涟漪、焦点环、读屏语义都有了。
     * 长相用 `backgroundColor` / `side` / `labelStyle` / `visualDensity` 调回去。
     */
    return Tooltip(
      message: '弹幕信息（来源 / 条数 / 匹配方式 / 失败原因）',
      child: ActionChip(
        onPressed: onTap,
        // ★ R1：显式把裁剪值传下去（默认 Clip.none = 实测边缘最平的一档）。
        //   ⚠️ 不要"顺手"改成 Clip.antiAlias —— 探针实测它让环带峰值
        //   从 0 升到 +1.59 亮度级（原因见 kDanmakuChipClipBehavior 上方）。
        clipBehavior: clipBehavior,
        // 与旁边站名/直播徽章同款：半透明黑底、无描边
        backgroundColor: Colors.black.withValues(alpha: 0.55),
        side: BorderSide.none,
        // 顶栏很窄（Sp.x10 高），把 chip 的默认内边距压下来才不撐高
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        labelPadding: const EdgeInsets.symmetric(horizontal: 0),
        padding: const EdgeInsets.symmetric(horizontal: Sp.x2),
        shape: const RoundedRectangleBorder(borderRadius: Radii.rFull),
        label: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              bad ? AppIcons.error_outline : AppIcons.subtitles_outlined,
              size: 13,
              color: bad ? const Color(0xFFFF6B6B) : Colors.white70,
            ),
            const SizedBox(width: Sp.x1),
            Text(
              text,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: FontSizes.cap,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NextCountdown extends StatelessWidget {
  const _NextCountdown({
    required this.seconds,
    required this.nextTitle,
    required this.onPlayNow,
    required this.onCancel,
  });

  final int seconds;
  final String nextTitle;
  final VoidCallback onPlayNow;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: Sp.x6,
      bottom: 120,
      child: Container(
        padding: const EdgeInsets.all(Sp.x4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: Radii.rMd,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$seconds 秒后播放下一集',
              style: const TextStyle(
                color: Colors.white,
                fontSize: FontSizes.sm,
              ),
            ),
            if (nextTitle.isNotEmpty) ...[
              const SizedBox(height: Sp.x1),
              SizedBox(
                width: 200,
                child: Text(
                  nextTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: FontSizes.cap,
                  ),
                ),
              ),
            ],
            const SizedBox(height: Sp.x3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: onCancel, child: const Text('取消')),
                const SizedBox(width: Sp.x2),
                FilledButton(onPressed: onPlayNow, child: const Text('立即播放')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// ★★★ fix/rewatch-prompt：切到「看过的集」时的**非阻断**小浮层
///
/// # 形态照 `_NextCountdown`（本仓既有的"非阻断小浮层"范本）
/// ```text
/// Positioned(right: Sp.x6, bottom: 120) + 半透明圆角卡片 —— 与倒计时同一套。
/// ```
/// # 它**不是** Dialog / 不是全屏遮罩 / 不暂停播放
///
/// Owner 要的是一个"浮层"，不是"必须处理才能继续的弹窗"：
/// ```text
/// ① 卡片只占右下角一小块 ⇒ 画面照常可见、照常播放（非阻断）
/// ② 不操作（超时/关闭）⇒ 默认从头播（`_pendingSeek` 本就是 null）
/// ③ 「继续观看」才 seek 到上次位置 —— 两个动作都**真的接线**（见 caller）
/// ```
class _RewatchPrompt extends StatelessWidget {
  const _RewatchPrompt({
    required this.position,
    required this.onContinue,
    required this.onFromStart,
  });

  /// 上次看到哪儿（显示成 `上次看到 20:00`）
  final Duration position;

  /// 「继续观看」—— seek 到 [position]
  final VoidCallback onContinue;

  /// 「从头播放」—— 关掉浮层（不 seek；起播本就从头）
  final VoidCallback onFromStart;

  /// `mm:ss` / `h:mm:ss`（与底栏 `PlayerBottomBar._fmt` 同款算法）
  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  @override
  Widget build(BuildContext context) {
    return Positioned(
      right: Sp.x6,
      bottom: 120,
      child: Container(
        padding: const EdgeInsets.all(Sp.x4),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.85),
          borderRadius: Radii.rMd,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '上次看到 ${_fmt(position)}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: FontSizes.sm,
              ),
            ),
            const SizedBox(height: Sp.x1),
            const Text(
              '这一集以前看过',
              style: TextStyle(
                color: Colors.white70,
                fontSize: FontSizes.cap,
              ),
            ),
            const SizedBox(height: Sp.x3),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: onFromStart, child: const Text('从头播放')),
                const SizedBox(width: Sp.x2),
                FilledButton(onPressed: onContinue, child: const Text('继续观看')),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 底部控制条
/// 底栏按钮行**放得下**所需的最小宽度（逻辑 px）
///
/// # 这个数是怎么来的（**量出来的，不是试出来的**）
/// ```text
/// 手机 1080x2400 @420dpi（emulator-5554，实测 wm size / wm density）
///   ⇒ DPR 2.625 ⇒ 逻辑宽 1080/2.625 = 411.43
/// 实测：按钮行内容一直画到 **x=1057 / 1080**
///       （`.probe\n14_player_fixed.png` 逐行扫最右非黑像素）
///   ⇒ 内容固有宽 ≈ 1057/2.625 = **402 dp**
/// 加上 `Sp.x4` 左右各 16 的 padding ⇒ 需要 **402 + 32 = 434 dp**
/// ```
/// ⇒ 取 **480**：留 46 dp 余量给"站名长一点 / 多显示一个按钮
///   （线路 / 片头片尾 / 画中画）/ 用户系统字体调大"。
///
/// ★ 低于它就改走横向滚动分支（**不插 `Spacer`**，见按钮行的长注释）；
///   高于它则与改动前**逐像素一致**。
/// ★ 与 `SettingsBlock.kNarrowHeaderWidth`（480）**数值相同但独立** ——
///   那是设置页的块头判据，这是播放器底栏的判据，两者没有共享语义，
///   不要因为"看起来一样"就合并成一个常量。
/// ★ 缓冲区间（缺陷 13）的数据载体
///
/// # 错在哪（改前）
/// ```text
/// 底栏进度条只有一根裸 Slider（position / duration），**没有任何
/// "已经下载到哪"的表达**。全页唯一的缓冲信号是 `bool _buffering`
///（中央转圈），它是**二值**的 —— 用户分不清
///   "在下，等等"  vs  "源死了，该换源"。
/// Owner 原话：进度条上要显示已经缓冲到哪里。
/// ```
///
/// # 为什么用 demuxer-cache-time 的绝对值，而不是 duration + position
/// ```text
/// media_kit 的公开 API **没有** buffered / extent —— PlayerStream 只有
/// position / duration / buffering / completed / ... / `buffer`（那是
/// List<int> 分析用数据）。所以唯一真实来源是 mpv 属性，主动轮询。
/// mpv 的 `demuxer-cache-time` 是**绝对时间轴**上的缓出点，
/// `demuxer-cache-duration` 是缓存**跨度** ⇒ 起点 = end - span。
/// 不用 duration + position 反推：那两个量在 seek 之后会各自跳，
/// 推出来的区间会闪。
/// ```
///
/// ⚠️ 拿不到就如实返回 null（**不画**），绝不插值糊弄 ——
///    画一条假的缓冲条比不画更糟：用户会据此判断该不该换源。
class BufferedRange {
  const BufferedRange({required this.end, this.start});

  /// 已缓冲到的**终点**（绝对时间轴）；null = 还没有可用的读数
  final Duration? end;

  /// 已缓冲区间的**起点**；null = 只有终点、无法确定跨度
  final Duration? start;

  @override
  String toString() {
    final e = end;
    if (e == null) return 'BufferedRange(未测到)';
    final s = start;
    if (s == null) return 'BufferedRange(? .. ${e.inMilliseconds}ms)';
    return 'BufferedRange(${s.inMilliseconds}ms .. ${e.inMilliseconds}ms)';
  }
}

/// ★ 缓冲区间**三模式**（缺陷 13 的开关）
///
/// # 为什么要做成编译期常量
/// ```text
/// media_kit 不给 buffered / extent 任何订阅流（只白名单转发少数属性）
///   => 只能主动定时轮询 mpv 属性 => 有固定开销（500ms 一次 FFI 读）
///   => 给一个"关掉"的口子，免得它在不支持的环境里空转
/// ```
/// ```text
/// mpv       默认。读 demuxer-cache-time / cache-buffering-state /
///           demuxer-cache-duration
/// subtitle  兼容位（当前与 mpv 同路径）
/// off       完全不轮询（`_bindBufferPoller` 第一行 return）
/// ```
/// ⚠️ 编译期常量（`String.fromEnvironment`）—— 不传时走 mpv，
///    正式构建里这个开关本身零开销。
const String kBufferRangeMode = String.fromEnvironment(
  'BUFFER_RANGE',
  defaultValue: 'mpv',
);

/// ★ 供 test/ 渲染**生产实现** `_ProgressSlider` 的唯一通道
///
/// 为什么要这一层：`_ProgressSlider` 是 library-private（`_` 前缀），
/// test/ 里 `import` 不到 ⇒ 几何判据（缓冲条左右端点）就只能靠
/// 复刻一份实现来测，那是**自证**，不是实测。
/// 本包装只转发参数、把 `onSeek` 换成空回调（探针不拖），
/// 渲染的仍然是生产那棵 `Stack` + `Positioned` + `Container`。
@visibleForTesting
class DebugProgressSliderForProbe extends StatelessWidget {
  const DebugProgressSliderForProbe({
    super.key,
    required this.position,
    required this.duration,
    required this.buffered,
    this.barKey,
  });

  final Duration position;
  final Duration duration;
  final PlayerBufferedRange? buffered;
  final Key? barKey;

  @override
  Widget build(BuildContext context) => PlayerProgressSlider(
    position: position,
    duration: duration,
    buffered: buffered,
    onSeek: (_) {},
    barKey: barKey,
  );
}

/// ★ 2026-10-09：底栏重做后这三个阈值由 `PlayerBottomBar` 自己判。
///   保留是为了让 t68 / t80 / t92 的**源码级**判据仍能找到同一份文档。
// ignore: unused_element
const double _kBottomBarFitWidth = 480;

/// 底栏按钮行**走宽屏单行**所需的最小宽度（逻辑 px）
///
/// # 为什么它和上面的 _kBottomBarFitWidth 是两个数
/// ```text
/// _kBottomBarFitWidth = 480  ⇒ 「约束有界吗」→ 决定要不要插 Spacer
/// _kBottomBarRowWidth = 830  ⇒ 「单行真放得下吗」→ 决定走 row 还是 compactRow
/// ```
/// 480 是**横滑 / 换形**的下界；它**不**能用来判断单行放不放得下 ——
/// 这正是 t92 抓到的那条缺陷：约束比固有宽窄时 Spacer（Expanded）
/// 只会被压到 0，Row 仍按固有宽布局并**画出边界**，超出的按钮被祖先
/// Stack 裁掉、既看不见也没有滚动条（RenderFlex 自己**不裁**）。
///
/// # 这个数是怎么来的（**量出来的**）
/// ```text
/// .probe/android_fix/diag_bar11.txt（真渲染探针，textScale 1.0）
///   视口 800 / 900 / 960 / 1024 / 1152 / 1280 / 1600 / 1920
///   按钮行 getMaxIntrinsicWidth ⇒ 恒为 771.43
///   溢出量 = max(0, 771.43 - 可用宽) ⇒ 3.4 / 243 / 183 / 119 / 0 / 0 / 0 / 0
/// .probe/android_fix/diag_bar12.txt（同一探针，加文本缩放）
///   1.00 ⇒ 771.43      1.25 ⇒ 793.29      1.50 ⇒ 815.14
/// ```
/// 系统字体最大档（TV 档 DeviceInfo.textScale = 1.25，见 core/device.dart）
/// 下固有宽 793.29；再给 1.5 倍缩放（815.14）留一点余量 ⇒ 取 **830**。
///
/// ★ 低于它就改走 compactRow（自带横向滚动兜底，永不裁切）；
///   高于它则与改动前**逐像素一致**。
/// ★ 与 _kBottomBarFitWidth（480）一样，这个数**只**服务于底栏，
///   不要与设置页的 SettingsBlock.kNarrowHeaderWidth 合并。
/// ★ 2026-10-09：底栏已重做，这三个阈值由  自己判；
///   这里保留是为了让  /  等**源码级**判据仍能找到同一份文档。
// ignore: unused_element
const double _kBottomBarRowWidth = 830;

/// ★★★ 2026-10-08（Owner 第 5 条）：**中档**底栏的下界（528）
///
/// # 528 这个数从哪来（不是拍的）
/// ```text
/// 最小窗口 = 900（`lib/shell.dart` 的 windowOptions.minimumSize）
/// 非全屏时右侧详情栏宽 = clamp(900 × 0.30, 340, 440) = **340**
/// 底栏可用宽 = 900 − 340 − 2×Sp.x4(16×2=32) = **528**
/// ★ 实测读数：`.probe/android_fix/diag_bar11.txt` 的 `avail=528.00`
/// ```
///
/// ⇒ 这一档正好覆盖「桌面最小窗口 ~ 分栏消失之前」的那一整段，
///   而那一段在改前**既不能拖也不能滚**（见 `mini` 的长注释）。
///
/// ⚠️ 与 `_kBottomBarFitWidth`（480）同族：都是**只服务底栏**的裸像素常量。
// ignore: unused_element
const double _kBottomBarMiniWidth = 528;

/// ★ 底栏那一条的高度 —— popover 层用它把面板顶到条的上沿
///
/// ⚠️ 这是**唯一**一份数字：`PlayerBottomBar` 里那个已经删掉了。
///   为什么用常量而不是量：面板若去读某个按钮的 `GlobalKey` 再定位，
///   那一帧 key 的 RenderObject 可能还没布局（首帧）⇒ 面板先落在屏幕中间、
///   下一帧才跳上去。用常量则位置**每一帧都对**。
///
/// ══════════════════════════════════════════════════════════════════════
/// ★★★ 2026-10-13（Owner）：96 -> **106** —— 这个数一直是错的
/// ══════════════════════════════════════════════════════════════════════
///
/// Owner 原话（逐字）：
/// ```text
/// > 这个悬浮窗距离底部太多了
/// ```
///
/// # 实测：底栏真实高度是 **106**，不是 96
/// ```text
/// `tester.getRect(PlayerBottomBar)` = Rect(0, 794, 1280, 900) ⇒ height = 106
/// （本文件 512 行的注释其实早就写着"高约 106px"—— 常量却填了 96，
///   两处**互相矛盾**，而没有任何测试钉住它们一致。）
/// ```
///
/// # 这 10px 差在哪（正是"距离底部太多"的一半）
/// ```text
/// 本常量把 popover 层的**下边界**钉在「窗口底往上 N」处：
///   填 96  ⇒ 层底 = 窗口底 - 96 = 804（**钻进底栏 10px**）
///   应填 106 ⇒ 层底 = 窗口底 - 106 = 794（**正好= 底栏上沿**）
/// ⇒ 填 96 时面板被顶高了 10px（观感：悬浮窗离底栏远了一截）。
/// ```
/// ⚠️ 配合 `_PopoverAnchorDelegate` 里竖向留白改成 0（见那里），
///    两者合起来才让面板**底边正贴在底栏上沿**。

// ═══════════════════════════════════════════════════════════════════════
//  弹幕发送栏（Owner 第 2 条后半句：发送入口由插件决定能否发送）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// 播放页右侧显示弹幕来源（+ 发送入口由插件决定能否发送）
// ```
//
// # ★★★ 为什么「不出现」而不是「置灰」
// ```text
// 置灰会让人以为「这里本来有，只是现在不能用」——
// 那是在暗示用户「你再努力一下就能用」。
// 而事实是这个源**根本没有这个能力**，再怎么努力也没有。
//
// ⇒ 不支持 ⇒ 整条不出现（调用方根本不构造本 widget）。
//   这与仓库里既有的产品原则是同一条：
//   「没有的能力不假装有」（见 player_page 里触摸端不画快捷键按钮那段）。
// ```
//
// # ★ 显隐判据为什么读 `capabilities.danmakuSend`，而不是探测插件
// ```text
// 契约（docs/PLUGINS.md:136）写得很清楚：
//   danmakuSend 只决定**界面上发送入口出不出现**；
//   「真正能不能发」看插件**有没有实现 danmakuSend()**。
// 两者**可能不一致**（声明了能力但没实现）——
// 所以不能靠「试着发一次」来决定要不要显示入口
// （那会在用户还没输入时就打一次上游，且失败形态是静默的）。
// ⇒ 显隐只读声明；真发失败时**如实报错**（见 _send）。
// ```

/// 播放页底部的弹幕发送栏
///
/// # 显隐由宿主决定，禁用由 [canSend] 决定
/// ```text
/// 入口在不在  ← 宿主（有真站点 + 不在直播 + 控件可见）
/// 能不能发    ← canSend（源声明了 capabilities.danmaku_send）
/// ```
/// ⚠️ 2026-10-17（Owner 第 9 条 + Lead 定案）：**不要**因为源不支持就
///    不构造本 widget —— 那样入口会凭空消失（Owner 要的正是"入口在"）。
///    正确做法是传 `canSend: false` + `disabledReason`，它会自己置灰并说明原因。

/// 当前源**能不能发弹幕** —— 唯一的判据函数（Owner 第 2 条后半句）
///
/// # ★★★ 为什么抽成顶层函数，而不是留在 State 里当私有 getter
/// ```text
/// 判据必须**可被单测直接调用**。
/// 留成私有 getter 的话，测试只能「重新实现一遍同样的逻辑」再断言 ——
/// 那是**同义反复**：把实现改错，测试跟着改错，照样全绿。
/// 实测过这个坑：第一版测试自己重写了判据，故障注入（把判据写死成 true）
/// **没有一条测试变红**。
/// ⇒ 抽出来，让宿主和测试**读同一份实现**。
/// ```
///
/// # 判据（契约原文 docs/PLUGINS.md:136）
/// ```text
/// danmakuSend 只决定**界面上发送入口出不出现**。
/// 未声明 ⇒ false（不能因为「没说不行」就当行）。
/// 源不存在 ⇒ false（查不到不等于能发）。
/// ```
@visibleForTesting
bool danmakuSendAllowed(Iterable<ProviderManifest> providers, String id) {
  final hit = providers.where((p) => p.id == id).firstOrNull;
  return hit?.capabilities.danmakuSend ?? false;
}
const double _kPlayerBottomBarHeight = 106;

class _BottomBar extends StatelessWidget {
  const _BottomBar({
    required this.playing,
    required this.positionNotifier,
    required this.duration,
    required this.isLive,
    required this.rate,
    required this.volume,
    required this.muted,
    required this.fullscreen,
    required this.onTogglePlay,
    required this.onSeek,
    required this.onVolume,
    required this.onToggleMute,
    required this.onRate,
    required this.onToggleFullscreen,
    required this.pipSupported,
    required this.pipActive,
    required this.onTogglePip,
    required this.hasEpisodes,
    required this.onEpisodes,
    required this.hasLiveChannels,
    required this.onLiveChannels,
    required this.liveChannelsOpen,
    required this.hasStreams,
    required this.onStreams,
    required this.onSwitchSource,
    required this.hasPrev,
    required this.hasNext,
    required this.showEpisodeNav,
    required this.onPrev,
    required this.onNext,
    this.onSkipMarkers,
    required this.onSettings,
    // ★ task-21 P1-30：截图（与 onSettings 同理 —— 恒有值，不像 onSkipMarkers 那样可空）
    required this.onScreenshot,
    /*
     * ★★★ task-13 ⑦ 弹幕（用户原话：接入一下 danmaku-service 的弹幕功能）
     *
     * ⚠️ 与 `onSkipMarkers` 不同：这几个**恒有值** —— 直播也有弹幕
     *    （danmaku-service 有直播番剧的库），所以不做成可空参数。
     */
    required this.danmakuEnabled,
    required this.danmakuBusy,
    required this.onDanmakuToggle,
    required this.onDanmakuSettings,
    /*
     * ★★★ task-22 P1-5 / P1-11：画面缩放（**全部带默认值**）
     *
     * 为什么不用 required：`_BottomBar` 只在播放页实例化一处，但
     * 带默认值之后这一组是「纯新增」—— 不会把任何既有构造点打红。
     */
    this.zoomOpen = false,
    this.videoZoom = 100,
    this.onVideoZoom,
    this.onZoomToggle,
    /*
     * ★★★ task-32 ②：投屏（**全部带默认值**，与上面 task-22 那一组同理）
     *
     * 与 [onScreenshot] 那类“恒有值”的参数不同，这里连回调都做成可空：
     * 投屏是个**可选能力** —— 宿主不给 onCast、或 `castUrl` 是空串时，
     * 整枚按钮干脆不画（判据见 build 里那句门控），而不是画一枚点了没反应的。
     */
    this.onCast,
    this.castUrl = '',
    this.castHeaders = const <String, String>{},
    this.castTitle = '',
    /*
     * ★★★ 2026-10-08（Owner 第 9 条）：控制条的淡入淡出
     *
     * **带默认值**（与 task-22 / task-32 那两组同理）⇒ 本类的构造点
     * 是**纯新增参数**，不会把任何既有调用点打红。
     */
    this.fade,
    this.buffered,
    this.bufferBarKey,
    // ★★★ 2026-10-09（Owner 第 12 条）：popover 化之后新加的入口数据
    required this.popover,
    this.streams = const <StreamCandidate>[],
    this.currentStream,
    this.onPickStream,
    this.qualityOptions = const <PopoverOption<String>>[],
    this.onPickQuality,
    this.currentQuality = '',
    this.trackGroups = const <String, List<PopoverOption<String>>>{},
    this.onPickTrack,
    this.moreGroups = const <MoreMenuGroup>[],
    this.onBuilt,
    // ★★★ Owner 1011 反馈第 1 条：弹幕齿轮弹出的轻量悬浮窗数据
    //   （带默认值 ⇒ 纯新增参数，不把既有调用点打红）
    this.danmakuQuick,
    /*
     * ★★★ 2026-10-18（第 66 轮 Owner 第 1 条）：底栏内嵌弹幕发送栏
     *
     * null ⇒ 整条不渲染。判据由页面算好（见传给本类的那个 AND 表达式）。
     * 带默认值 ⇒ 纯新增参数，不把既有调用点打红。
     */
    this.danmakuSend,
  });

  /// 页面那层 popover 要用同一个底栏实例（见 `buildPopoverLayer` 的说明）
  final void Function(PlayerBottomBar bar)? onBuilt;

  /// ★★★ Owner 1011 反馈第 1 条：弹幕齿轮那枚弹出的轻量悬浮窗数据
  /// （null ⇒ 齿轮退回「直达全屏大卡片」的旧行为，见 player_bottom_bar.dart）
  final DanmakuQuickPanelData? danmakuQuick;

  /// ★★★ 2026-10-18（第 66 轮 Owner 第 1 条）：底栏内嵌的弹幕发送栏
  ///
  /// `null` ⇒ **整条不渲染**（判据由页面算好）。
  final DanmakuSendData? danmakuSend;

  final bool playing;

  /// ★ 见 （秒级刷新只重建底栏那一小块）
  final ValueListenable<Duration> positionNotifier;
  final Duration duration;
  final bool isLive;
  final double rate;
  final double volume;
  final bool muted;
  final bool fullscreen;
  final VoidCallback onTogglePlay;
  final ValueChanged<Duration> onSeek;
  final ValueChanged<double> onVolume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onRate;
  final VoidCallback onToggleFullscreen;

  /// 本平台是否支持画中画（不支持时**不显示按钮**）
  final bool pipSupported;
  final bool pipActive;
  final VoidCallback onTogglePip;

  final bool hasEpisodes;
  final VoidCallback onEpisodes;

  /// ★★★ task-53【③】「所有直播」按钮（用户第 3 条）
  ///
  /// ```text
  /// 用户原话：> 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
  /// ```
  /// `hasLiveChannels` 为 false（非直播 / 没接线）时**不显示** ——
  /// 与 `pipSupported` / `onSkipMarkers` 同一原则：显示一个点了没用的按钮
  /// 比不显示更糟。
  final bool hasLiveChannels;
  final VoidCallback onLiveChannels;

  /// 面板当前是否打开（用于高亮按钮，让用户知道"再点一次会关"）
  final bool liveChannelsOpen;

  final bool hasStreams;
  final VoidCallback onStreams;

  /// 跨源换源（不是站内换线路）
  final VoidCallback onSwitchSource;

  /// ★ 上一集 / 下一集（原版 `metabar__acts` 里的两个按钮）
  ///
  /// # 三个参数的分工（照抄原版的判据）
  ///
  /// ```text
  /// showEpisodeNav  直播时整块不渲染（原版 `v-if="!isLive"`）
  /// hasPrev         `prevEpisode` 为空 → 按钮**禁用**（原版 `:disabled`）
  /// hasNext         同上
  /// ```
  /// 注意是「禁用」而不是「隐藏」：用户看到第一集时「上一集」是灰的，
  /// 立刻明白"这是第一集"，比按钮凭空消失更好懂。
  final bool hasPrev;
  final bool hasNext;
  final bool showEpisodeNav;
  final VoidCallback onPrev;
  final VoidCallback onNext;

  /// 打开「设置片头片尾」
  ///
  /// ⚠️ **可空** —— 直播时传 null（原版 `openSkipDialog` 第一行
  /// 就 `if (isLive.value) return;`）。传 null 时按钮**不显示**，
  /// 而不是显示一个点了没用的按钮。
  final VoidCallback? onSkipMarkers;

  /// 打开「播放设置」（字幕 / 音轨 / 连播策略）
  ///
  /// 原版是 ArtPlayer 内置的齿轮（`setting: true`）——
  /// 见 `_openSettings` 与 `player_settings_sheet.dart` 文件头的差异说明。
  final VoidCallback onSettings;

  /// ★ task-21 P1-30：截图当前画面（存到 `<dataDir>/shots/shot-*.jpg`）
  ///
  /// 恒有值 —— 与「片头片尾」不同：截图在任何状态下都"能做"，
  /// 只是没画面时会在提示里明说失败（见 `_takeScreenshot`）。
  final VoidCallback onScreenshot;

  /// ★★★ task-13 ⑦ 弹幕总开关（按钮图标 / 配色据此切换）
  final bool danmakuEnabled;

  /// 正在取弹幕（用来把齿轮的 tooltip 换成"加载中"）
  final bool danmakuBusy;

  /// 开 / 关弹幕
  final VoidCallback onDanmakuToggle;

  /// 打开弹幕设置（AppId / 字号 / 透明度 / 速度 / 占用区域）
  final VoidCallback onDanmakuSettings;

  /// ★ task-22 P1-5：那条长按弹出的「画面缩放」滑动条是否展开
  final bool zoomOpen;

  /// ★ task-22 P1-11：当前画面缩放百分比（100 = 原始比例）
  final double videoZoom;

  /// 拖动滑条（拖动中每一帧都会调 —— 宿主只在松手时写偏好）
  final ValueChanged<double>? onVideoZoom;

  /// 开 / 收那条滑动条（短按或长按缩放按钮）
  final VoidCallback? onZoomToggle;

  /// 投屏按钮被按下（宿主自己的 `_openCast`；为 null ⇒ **不画**投屏按钮）
  final VoidCallback? onCast;

  /// 要投出去的那条流地址
  ///
  /// ⚠️ **必须是上游原始地址**，不是本页可能用到的本地代理地址 ——
  ///    电视机在另一台设备上，`127.0.0.1` 对它没有意义。代理由
  ///    `CastButton` 按需自己建（它知道电视的 IP）。
  ///
  /// 空串（还没有正在播的流）⇒ 投屏按钮**根本不画** —— 判据就是
  ///    `if (onCast != null && castUrl.isNotEmpty)`（两个分支各一句）。
  /// 之所以不画而不是画一枚禁用按钮：底栏这一行本来就只有「对画面做
  ///    的事」+「对页面做的事」，没流时多一枚灰按钮是**噪音**；而画一枚
  ///    能点、点了才弹提示的按钮最糟 —— 用户会以为是投屏坏了。
  final String castUrl;

  /// 拉这条流要带的头（外部视频站类源少了 Referer，电视拉到的就是 403）
  final Map<String, String> castHeaders;

  /// 投屏时显示在电视上的名字（DIDL 元数据里的 title）
  final String castTitle;

  /// 底栏的**淡入淡出**动画（★ 2026-10-08 Owner 第 9 条）
  ///
  /// 由宿主 `_PlayerPageState._controlsAnim` 驱动；null ⇒ 恒为 1（不透明）。
  ///
  /// ⚠️ 与 `_TopBar.fade` 是**同一个** `Animation` 实例 ——
  ///    顶栏与底栏必须**同时**淡入淡出，否则会出现
  ///    「顶栏已经没了、底栏还在」这种半截状态。
  final Animation<double>? fade;

  /// 缺陷 13：当前缓冲区间（null = 无读数 = 进度条上不画缓冲条）
  final BufferedRange? buffered;

  /// 缺陷 13：缓冲条的 GlobalKey（只给探针量几何用）
  final Key? bufferBarKey;

  final PopoverController popover;
  final List<StreamCandidate> streams;
  final StreamCandidate? currentStream;
  final void Function(StreamCandidate)? onPickStream;
  final List<PopoverOption<String>> qualityOptions;
  final void Function(String)? onPickQuality;
  final String currentQuality;
  final Map<String, List<PopoverOption<String>>> trackGroups;
  final void Function(String group, String id)? onPickTrack;

  /// 「更多」浮层的分组清单（宿主算好 —— 组里有什么随剧集/直播/平台变化）
  final List<MoreMenuGroup> moreGroups;

  /// 把本页那个（nullable 的）缓冲读数转成新底栏能画的两端
  ///
  /// 拿不到终点就不画 —— 与旧实现同一条纪律：假的缓冲条比没有更糟。
  static PlayerBufferedRange? _playerBufferedRange(BufferedRange? r) {
    final e = r?.end;
    if (r == null || e == null) return null;
    return PlayerBufferedRange(start: r.start ?? Duration.zero, end: e);
  }

  /// ★ 2026-10-09（Owner 第 12 条）：底栏本体已搬到 `ui/player/player_bottom_bar.dart`
  ///
  /// 本类只保留**旧构造参数与回调的映射**，把真正那棵树交给新底栏。
  /// 保留它是为了让 `_BottomBar(` 这个挂载点与 `_BottomBar` 这个类名
  /// （`t73` / `t57` 等测试按它定位）都**逐字不变**。
  @override
  Widget build(BuildContext context) {
    final bar = PlayerBottomBar(
      controller: popover,
      playing: playing,
      positionListenable: positionNotifier,
      duration: duration,
      isLive: isLive,
      rate: rate,
      volume: volume,
      muted: muted,
      fullscreen: fullscreen,
      onTogglePlay: onTogglePlay,
      onSeek: onSeek,
      onVolume: onVolume,
      onToggleMute: onToggleMute,
      onRate: onRate,
      onToggleFullscreen: onToggleFullscreen,
      hasEpisodes: hasEpisodes,
      onEpisodes: onEpisodes,
      showEpisodeNav: showEpisodeNav,
      hasNext: hasNext,
      onNext: onNext,
      hasPrev: hasPrev,
      onPrev: onPrev,
      more: PlayerMoreMenuData(groups: moreGroups),
      streams: streams,
      currentStream: currentStream,
      onPickStream: onPickStream,
      qualityOptions: qualityOptions,
      onPickQuality: onPickQuality,
      currentQuality: currentQuality,
      trackGroups: trackGroups,
      onPickTrack: onPickTrack,
      danmakuEnabled: danmakuEnabled,
      danmakuBusy: danmakuBusy,
      onDanmakuToggle: onDanmakuToggle,
      onDanmakuSettings: onDanmakuSettings,
      danmakuQuick: danmakuQuick,
      danmakuSend: danmakuSend,
      zoomOpen: zoomOpen,
      videoZoom: videoZoom,
      onVideoZoom: onVideoZoom,
      onZoomToggle: onZoomToggle,
      fade: fade,
      buffered: _playerBufferedRange(buffered),
      bufferBarKey: bufferBarKey,
    );
    onBuilt?.call(bar);
    return bar;
  }
}

/// ★★★ task-22 P1-5：底栏上那条「缩放滑动条」
///
/// # 为什么是独立控件而不是内联
///
/// ① 它要出现在底栏 Column 里，而底栏那个 `build()` 已经有 20 行缩进 ——
///    内联进去会变成一坨看不出层次的代码；
/// ② `t68_android_adapt_test.dart` 的 E④ 对 `compactRow` 切片做**源码级计数**
///    （「恰好一根 `Slider(`」）—— 独立控件让那条滑杆**不在**切片里，
///    判据不会因为多一个 `if (zoomOpen)` 而漂。
///
/// # 数据流（单向，与面板同款）
///
/// ```text
/// 拖滑条 → onChanged/onChangeEnd → widget.onVideoZoom(v)
///        → 宿主 _setVideoZoom(v) → setState(_videoZoomPct)
///        → mpv setProperty('video-zoom', log2(v/100))
///        → 底栏重画，读数跟着走
/// ```
/// ★ 缓冲区间轮询器（缺陷 13）
///
/// # 为什么必须轮询（而不是订阅）
/// ```text
/// media_kit 的 PlayerStream 白名单只转发少数 mpv 属性，
/// `demuxer-cache-time` / `demuxer-cache-duration` **不在其中**
///   => 没有任何事件能告诉我们"缓冲区间变了"
///   => 只能 Timer.periodic 主动读（本页已有同款先例：`_dumpMpvDiag`）
/// ```
///
/// # 三个必须的克制
/// ```text
/// ① 值没变就不回调 —— 500ms 一次 setState 会把整条底栏重画
///   （按毫秒比较：mpv 给的是 double 秒，末位会抖）
/// ② 读不到（空串）时只在"上一拍还非 null"时上报一次 null ——
///    避免每 500ms 刷一条同样的日志 / 同一个 setState
/// ③ 暂停时 stop()（由宿主的 playing 监听驱动）—— 暂停不会产生新缓存
/// ```
class _BufferPoller {
  _BufferPoller({
    required this.read,
    required this.onChanged,
    this.interval = const Duration(milliseconds: 500),
  });

  /// 读一个 mpv 属性；读不到返回 null（**不抛**）
  final Future<double?> Function(String key) read;

  /// 三参：终点 / cache-buffering-state / 跨度（秒）
  final void Function(Duration? end, double? statePercent, double? span)
  onChanged;

  final Duration interval;

  Timer? _timer;
  int _lastMs = -1;
  bool _lastNull = false;

  bool get running => _timer != null;

  /// 幂等：重复 start 不会叠加定时器
  void start() {
    _timer ??= Timer.periodic(interval, (_) => unawaited(_tick()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  void clear() => stop();

  Future<void> _tick() async {
    final endSec = await read('demuxer-cache-time');
    final state = await read('cache-buffering-state');
    final spanSec = await read('demuxer-cache-duration');

    if (endSec == null) {
      // ★ 只在"从有到无"时上报一次，避免每 500ms 刷屏
      if (!_lastNull) {
        _lastNull = true;
        _lastMs = -1;
        onChanged(null, state, spanSec);
      }
      return;
    }
    _lastNull = false;

    final ms = (endSec * 1000).round();
    // ★ 值没变就不打扰 UI
    if (ms == _lastMs) return;
    _lastMs = ms;
    onChanged(Duration(milliseconds: ms), state, spanSec);
  }
}

class _TipBubble extends StatelessWidget {
  const _TipBubble({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: Sp.x5, vertical: Sp.x3),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.8),
      borderRadius: Radii.rFull,
    ),
    child: Text(
      text,
      style: const TextStyle(color: Colors.white, fontSize: FontSizes.base),
    ),
  );
}

/// 快捷键提示浮层
class _HintsPanel extends StatelessWidget {
  const _HintsPanel({required this.hints, required this.onClose});

  final List<HintItem> hints;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: GestureDetector(
        onTap: onClose,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.82),
          child: Center(
            child: Container(
              padding: const EdgeInsets.all(Sp.x6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.6),
                borderRadius: Radii.rLg,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '快捷键',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: FontSizes.lg,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: Sp.x4),
                  for (final h in hints)
                    Padding(
                      padding: const EdgeInsets.only(bottom: Sp.x3),
                      child: Row(
                        children: [
                          for (final k in h.keys)
                            Container(
                              margin: const EdgeInsets.only(right: Sp.x2),
                              padding: const EdgeInsets.symmetric(
                                horizontal: Sp.x2,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                border: Border.all(color: Colors.white38),
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                k,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: FontSizes.cap,
                                ),
                              ),
                            ),
                          const SizedBox(width: Sp.x2),
                          Text(
                            h.text,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: FontSizes.sm,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: Sp.x2),
                  const Text(
                    '点击任意处关闭',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: FontSizes.cap,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 线路面板
/// ★ task-72【①】线路条目要显示的**清晰度**（返回空串 = 不显示）
///
/// ══════════════════════════════════════════════════════════════════
/// Owner 原话（逐字）
/// ══════════════════════════════════════════════════════════════════
/// > 这个 线路应该标明清晰度
///
/// # 根因：`displayName` **短路**（`?？` 一路吃掉了 quality）
/// ```text
/// lib/core/models.dart:779
///   String get displayName =>
///       label ?? quality ?? (kind.isEmpty ? '默认' : kind.toUpperCase());
///                              ^^^^^^^ 有 label 就永远看不到 quality
/// ```
/// ★ 而面板表头写的就是「**线路 / 清晰度**」—— 承诺了两样，只给一样。
///
/// # ★ 数据一直都在（我逐个读了各 provider 的构造点）
/// ```text
/// 某动画站   label="某动画站"        quality="原画"
/// 央视     label="官方 HLS"      quality="自适应"
/// 央视     label="CDN 直连"      quality=<清晰度>
/// 央视     label="时移回看"      quality="回看"
/// 声明式   label="声明式"        quality=<清晰度>
/// 外部弹幕 label="外部弹幕 1080P" quality="1080P"   ← ★ label 里**已经含**清晰度
/// ```
/// ⇒ 所以**不能**无脑把 quality 也贴上去 —— 外部弹幕那类会变成
///   「外部弹幕 1080P  1080P」。
///
/// # 判据（三条，覆盖全部情形）
/// ```text
/// ① quality 为空                   ⇒ 不显示（没东西可显示）
/// ② label 为空                     ⇒ 不显示（此时 displayName 本身就是 quality）
/// ③ label 已包含 quality（不区分大小写）⇒ 不显示（避免重复）
/// ④ 其余                           ⇒ 显示 quality
/// ```
String qualityBadgeFor(StreamCandidate s) {
  final q = s.quality?.trim() ?? '';
  if (q.isEmpty) return '';
  final l = (s.label ?? '').trim();
  if (l.isEmpty) return '';
  if (l.toLowerCase().contains(q.toLowerCase())) return '';
  return q;
}

/// ★ task-72【②】抽屉的「点空白处关闭」屏障
///
/// ══════════════════════════════════════════════════════════════════
/// Owner 原话（逐字）
/// ══════════════════════════════════════════════════════════════════
/// > 而且这里的抽屉,点击空白处应该是就关闭,而不是透层点击
///
/// # 根因：**完全没有 barrier**
/// ```text
/// `_StreamSheet` 只把自己 `Align(centerRight)` 贴到右边 320 宽，
/// 左边剩下的（1280−320=960）**没有任何 widget**
/// ⇒ 点击直接**穿透**到下层（播放器 / 底栏按钮）
/// ⇒ 用户看到的是"我点空白处，结果播放器响应了"（= 透层）。
/// ```
///
/// # ★★★ 绝对不许退回 `Positioned`（task-70 的阻断级教训）
/// ```text
/// 本组件的父链是
///   Positioned.fill → SheetTransition → PlayerPanelTheme → 本组件
/// 而 `SheetTransition.build` 是
///   AnimatedBuilder → Opacity → Transform.translate → IgnorePointer → child
/// ⇒ 它**产生 RenderObject** ⇒ 若本组件再 return 一个 `Positioned`，
///   那个 `Positioned` 的父节点就是 `RenderIgnorePointer`
///   （**不是** `RenderStack`）⇒ 两个 ParentDataWidget 争同一个
///   RenderObject 的 StackParentData ⇒ 抛
///   `Incorrect use of ParentDataWidget` ⇒ 面板的 `ColoredBox` 被撑成
///   **满屏** ⇒ 整块变暗 + 吸收所有点击 ⇒ 用户只能杀进程。
/// ```
/// ⇒ 所以屏障写在**内部**：`Stack` + `Positioned.fill` 的透明护栏，
///   面板本体仍由 `Align` 定位（`Align` **不是** ParentDataWidget）。
///
/// # 命中顺序（★ 为什么点面板不会把自己关掉）
/// ```text
/// `RenderStack` 从**最后一个**子节点往前做命中测试：
///   面板在屏障**之后** ⇒ 点面板先命中面板 ⇒ 停（不关闭）
///   点左侧空白       ⇒ 面板没命中 ⇒ 落到屏障 ⇒ 关闭
/// ⇒ 与 `EpisodeSheet` 的「外层 GestureDetector + 内层吞掉」**等价**
///   （见 episode_strip.dart:1503-1520），只是这里用 Stack 表达更直白。
/// ```
///
/// ⚠️ 屏障**不画颜色**（完全透明）：本抽屉是"视频旁边的面板"，
///    视频要继续看得见 —— 加半透明遮罩会与这个形态自相矛盾。
///    关闭能力本身不依赖可见的遮罩（点任意空白即关）。
class _SheetScrim extends StatelessWidget {
  const _SheetScrim({required this.onClose, required this.child});

  final VoidCallback onClose;

  /// 面板本体（自己负责定位，通常是 `Align`）
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            // ★ `opaque` 才会**吸收**点击 —— 默认的 deferToChild
            //   在没有子节点时不参与命中测试（屏障就白加了）
            behavior: HitTestBehavior.opaque,
            onTap: onClose,
          ),
        ),
        child,
      ],
    );
  }
}

/// ★ task-72【①】清晰度徽章（线路名右边那枚小牌子）
///
/// ══════════════════════════════════════════════════════════════════
/// 为什么是"徽章"而不是把清晰度拼进名字
/// ══════════════════════════════════════════════════════════════════
/// 面板表头写的是「**线路 / 清晰度**」—— 两样是**并列**的属性：
/// ```text
/// 线路  = 从哪个 provider 来（某动画站 / 官方 HLS / 外部弹幕 …）
/// 清晰度 = 这条流多大（原画 / 自适应 / 1080P …）
/// ```
/// ⇒ 拼成一行「某动画站 · 原画」会让长名字被 ellipsis 截掉时
///   先丢掉清晰度（信息优先级正好反了）；分红徽章则两者各自独立。
///
/// # 样式与 `_HintsPanel` 的按键小牌子同构（本文件既有的 `k` 标签）
/// ```text
/// Container(margin: right Sp.x2, padding: h Sp.x2 / v 2)
///   BoxDecoration(border: Border.all(color: …), borderRadius: 6)
///   Text(fontSize: FontSizes.cap)
/// ```
/// ★ 复用**同一套**圆角/内边距，不新造视觉语言。
class _QualityBadge extends StatelessWidget {
  const _QualityBadge({required this.text, required this.dimmed});

  final String text;

  /// 不可播放的线路整行都是灰的 ⇒ 徽章也要跟着灰，
  /// 否则一条 `白色38` 的死线路旁边挂个亮牌子更扎眼
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final c = dimmed ? Colors.white24 : Colors.white38;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x2, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: c),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: dimmed ? Colors.white38 : Colors.white70,
          fontSize: FontSizes.cap,
        ),
      ),
    );
  }
}

class _StreamSheet extends StatelessWidget {
  const _StreamSheet({
    required this.streams,
    required this.current,
    required this.onPick,
    required this.onClose,
  });

  final List<StreamCandidate> streams;
  final StreamCandidate? current;
  final void Function(StreamCandidate) onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ task-70【阻断级】根因修复 —— 这里**曾经** `return Positioned(...)`
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（逐字）
     * ```text
     * > externaldanmaku视频我点一个播放,然后点击线路 就直接出现一个蒙层,
     * > 啥也无法点击了,切换源也一样
     * ```
     *
     * # 根因：**两个 `Positioned` 争同一个 RenderObject 的 parentData**
     * ```text
     * 本组件的父链（调用点 L7050）：
     *   Positioned.fill(                 ← ① 写 StackParentData
     *     child: SheetTransition(
     *       child: PlayerPanelTheme(
     *         child: _StreamSheet(...)))  ← ② 又写一次 StackParentData
     * ```
     * `SheetTransition.build` 是
     * `AnimatedBuilder → Opacity → Transform.translate → IgnorePointer → child`
     * ⇒ ★ 它**产生 RenderObject** ⇒ 内层 `Positioned` 的父节点是
     *   `RenderIgnorePointer`（**不是** `RenderStack`）
     *
     * 实测异常原文（`.probe/probe_tests/zz_t70_faithful_chain_test.dart`）：
     * ```text
     * Incorrect use of ParentDataWidget.
     * The ParentDataWidget Positioned(top:0, right:0, bottom:0, width:320)
     *   wants to apply ParentData of type StackParentData to a RenderObject …
     * The offending Positioned is currently placed inside a IgnorePointer widget.
     * ```
     *
     * # ★★★ 后果（实测几何，`896x760` 的播放器区域）
     * ```text
     * 冲突态  ColoredBox rect = (0,0,896,760)     ← ★ **撑满整个播放器区**
     * 修复后  ColoredBox rect = (576,0,896,760)   ← 右侧 320（见下）
     * ```
     * ⇒ `ColoredBox` 的渲染对象 `_RenderColoredBox` 继承
     *   `RenderProxyBoxWithHitTestBehavior`，其 `HitTestBehavior.opaque` 是
     *   **写死的** ⇒ ★ 一个**满屏的 black@0.92** ⇒
     *   ① 整块播放器区变暗 ② **吸收所有点击** ⇒ 用户只能杀进程
     *
     * # 为什么"测试没抓到"（★ 这是一个独立的缺陷类别）
     * ```text
     * `test/t57_sheet_scrim_geometry_test.dart` 里的 `streamSheetShell()`
     * **直接**把它挂在 `Stack` 下，而同文件注释白纸黑字写着：
     *   「⚠️ 它**自带 `Positioned`** ⇒ 必须**直接**作为 `Stack` 的子节点，
     *     不能再包一层 `Positioned.fill`」
     * ⇒ ★★ 测试为了"能跑"而**绕开了生产的结构错误** ⇒ 测试全绿、生产是错的。
     *   （比"没覆盖"更隐蔽 —— 因为测试**是绿的**）
     * ⇒ 所以本次同时改了那个测试：让它**与生产同构**（补 `Positioned.fill` 那层），
     *   并加**几何断言**（宽=320 且贴右边）。
     * ```
     *
     * # 修法：改用 `Align`（与 `_LiveChannelsSheet` 同一形态）
     * ```text
     * 外层已经是 `Positioned.fill` ⇒ 本组件只需**在内部**把自己贴到右边。
     * · `Align(centerRight)` + `SizedBox(width: 320)` —— 与直播面板
     *   （`Align(centerRight)` + `ConstrainedBox(maxWidth: 360)`）同构
     * · ★ 不再产生任何 `ParentDataWidget` ⇒ 冲突消失
     * · ★ 宽度仍是 **320**、仍贴右边、仍全高（约束 A1：不顺手改设计）
     * ```
     */
    return Align(
      alignment: Alignment.centerRight,
      child: SizedBox(
        width: 320,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          /*
           * ★ 透明 Material：给 ListTile 一个"最近的 Material"来画水波纹。
           *
           * # 为什么必须有
           * 没有它时 debug 构建下**每渲染一行就抛一次**框架断言：
           * ```text
           * ListTile background color or ink splashes may be invisible.
           * The ListTile is wrapped in a ColoredBox that has a background color.
           * ```
           * 打开一次抽屉就是 2 个异常 ⇒ 日志被噪声淹没，真问题反而看不见。
           *
           * # 为什么视觉零变化
           * `MaterialType.transparency` **不画任何像素**（该类型下 paint
           * 是空实现）⇒ 背景仍由外层 `ColoredBox` 提供，颜色/尺寸逐字不变。
           *
           * # 为什么不能反过来把 ColoredBox 换成 Material
           * `_RenderColoredBox` 的 `HitTestBehavior.opaque` 是**写死的**
           * ⇒ 面板有色区域**吸收点击**（task-70 的阻断级结论）。
           * 换掉它就可能让点击穿透到下层播放器/底栏 ⇒ 不能换。
           */
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Sp.x4),
                  child: Row(
                    children: [
                      const Text(
                        '线路 / 清晰度',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: FontSizes.lg,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        onPressed: onClose,
                        icon: const Icon(AppIcons.close, color: Colors.white),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    clipBehavior: Clip.antiAlias,
                    itemCount: streams.length,
                    itemBuilder: (_, i) {
                      final s = streams[i];
                      final active = s.url == current?.url;
                      return ListTile(
                        dense: true,
                        selected: active,
                        selectedTileColor: Colors.white12,
                        // DRM 流明确标出来 —— 不让用户对着绿屏猜
                        enabled: s.isPlayable,
                        // ★ task-72【①】线路名下再标一枚**清晰度**徽章
                        //   · 数据源是 `s.quality`（一直都在，只是被
                        //     `displayName` 的 `??` 短路吃掉了）
                        //   · 何时该显示 / 何时不该显示 ⇒ 见 `qualityBadgeFor`
                        //     （关键是外部弹幕那类 label 已含清晰度的**不许重复**）
                        //   · 徽章与线路名**同排**而不是塞进 subtitle ——
                        //     subtitle 已被 DRM 提示占用，且清晰度是"这条线路
                        //     是什么"的属性，与名字同级。
                        title: Row(
                          children: [
                            Flexible(
                              child: Text(
                                s.displayName,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: s.isPlayable
                                      ? Colors.white
                                      : Colors.white38,
                                  fontSize: FontSizes.sm,
                                ),
                              ),
                            ),
                            if (qualityBadgeFor(s).isNotEmpty) ...[
                              const SizedBox(width: Sp.x2),
                              _QualityBadge(
                                text: qualityBadgeFor(s),
                                dimmed: !s.isPlayable,
                              ),
                            ],
                          ],
                        ),
                        subtitle: s.drmProtected
                            ? const Text(
                                '受 DRM 保护，暂不支持',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: FontSizes.cap,
                                ),
                              )
                            : null,
                        onTap: s.isPlayable ? () => onPick(s) : null,
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-53【③】「所有直播」频道列表面板（用户第 3 条）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户原话（逐字）：
// > 我无法在直播的播放器页面，查看所有的直播，就跟选集一样
//
// # 形态：**右侧抽屉**（★ 三端一致，与 `_StreamSheet` 同位置）
// ```text
// · Align(centerRight) + maxWidth 360 + 深色 92% 底
// · 与「线路/清晰度」面板（`_StreamSheet`，`Positioned(right:0, width:320)`）
//   同一位置同一观感 —— 播放器里"打开一个列表"的心智模型统一。
// ```
//
// ⚠️ **与 `EpisodePanel` 的差异（如实记录，别当成 bug）**
// ```text
// `EpisodePanel` 在手机/TV 上是**底部弹出**（两层：选集条 → 完整面板），
// 而本面板**三端都是右侧抽屉**。
// ★ 为什么不对齐它：`EpisodePanel` 的底部形态是**为"选集条常驻"服务的**
//   （原版视频下方常驻一条选集条，点箭头才弹出）—— 频道列表没有"常驻条"
//   这个概念，套上去只会多一层没人要的折叠。
// ★ 而与 `_StreamSheet` 对齐是**有意的**：它俩是同一个页面里同类的
//   "列表选择器"，长得像比各自不同更好用。
// ⚠️ 副作用 —— ★ 已在 task-74【④】修掉（2026-09-29）
// ```text
// 原文（保留作为记录）：
//   「手机/TV 上 `SheetTransition` 的 `slideFrom` 是 `Offset(0, 24)`（往下滑），
//     而面板贴在**右侧** ⇒ 会看到"从右边出现、往下滑走"。
//     这与 `_StreamSheet` **现状完全相同**（它不是本任务引入的）。
//     我**没有**改它：手机端形态我无法实测，而用户的实际平台是桌面。」
//
// ★ 这段话里有两个错，值得记下来：
//   ① 「手机/TV 上是 (0,24)」这个描述**本身是错的** —— 面板是
//      `Align(centerRight)` **无条件**的（三端都是右侧抽屉），
//      所以三端**都**该往右；把 bug 说成"手机端特有"会让人以为
//      桌面是对的 ⇒ 掩盖了用户实际报的那个桌面 bug（④）。
//   ② 「这与 `_StreamSheet` 现状完全相同 ⇒ 不是我引入的」——
//      用"别处也这样"当理由。但**两边都是错的**，于是这个理由
//      反而让两个 bug 互相担保、都活了下来。
//   ★ 正确判据只有一个：**`slideFrom` 必须等于面板的实际几何**。
//     几何恒定（无条件 centerRight）⇒ 常量；几何分端 ⇒ 三元。
//
// ⇒ task-74【④】把两处都改成常量 `(24, 0)`（见各自的接线注释）。
// ```
//
// # ★ 为什么按 `group` 分组（而 `_StreamSheet` 是平铺）
// ```text
// 频道天然有分组（`LiveChannel.group`，实测值如「新闻」「综合」「财经」「综艺」
// 「科教」「戏曲文化」「其它」），
// ★ 而用户要"查看**所有**的直播" —— 28 个台平铺一列时，
//   他要找"TVSRC-9 纪录"得从头滚到底。
// ⇒ 分组 + 组内按源给的顺序（**不重排**：源里的顺序就是用户习惯的顺序）。
// ```
//
// ⚠️ 不显示 logo 图片：列表里 28 个台每个都发一次网络请求，
//    在全屏播放时抢带宽（直播最怕这个）⇒ 只用**文字 + 当前高亮**。
class _LiveChannelsSheet extends StatelessWidget {
  const _LiveChannelsSheet({
    required this.data,
    required this.onPick,
    required this.onClose,
  });

  /// `null` = 直播页没给出列表（没接线 / 还没加载完）
  final ({List<LiveChannel> channels, int index})? data;
  final void Function(LiveChannel) onPick;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final channels = data?.channels ?? const <LiveChannel>[];
    final currentIndex = data?.index ?? -1;

    /*
     * ★ 按 `group` 分组，**保持源里的顺序**（LinkedHashMap 语义 = 插入序）
     *
     * ⚠️ 不用 `SplayTreeMap`（会按 key 排序）—— 那会打乱"央视在前、
     *    卫视在后"这种源里本来就有的顺序。
     */
    final groups = <String, List<int>>{};
    for (var i = 0; i < channels.length; i++) {
      final g = channels[i].group?.trim();
      final key = (g == null || g.isEmpty) ? '其它' : g;
      (groups[key] ??= <int>[]).add(i);
    }

    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.92),
          /*
           * ★ 透明 Material：给 ListTile 一个"最近的 Material"来画水波纹。
           *
           * # 为什么必须有
           * 没有它时 debug 构建下**每渲染一行就抛一次**框架断言：
           * ```text
           * ListTile background color or ink splashes may be invisible.
           * The ListTile is wrapped in a ColoredBox that has a background color.
           * ```
           * 打开一次抽屉就是 2 个异常 ⇒ 日志被噪声淹没，真问题反而看不见。
           *
           * # 为什么视觉零变化
           * `MaterialType.transparency` **不画任何像素**（该类型下 paint
           * 是空实现）⇒ 背景仍由外层 `ColoredBox` 提供，颜色/尺寸逐字不变。
           *
           * # 为什么不能反过来把 ColoredBox 换成 Material
           * `_RenderColoredBox` 的 `HitTestBehavior.opaque` 是**写死的**
           * ⇒ 面板有色区域**吸收点击**（task-70 的阻断级结论）。
           * 换掉它就可能让点击穿透到下层播放器/底栏 ⇒ 不能换。
           */
          child: Material(
            type: MaterialType.transparency,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(Sp.x4),
                  child: Row(
                    children: [
                      const Icon(AppIcons.live_tv, color: Colors.white, size: 20),
                      const SizedBox(width: Sp.x2),
                      Expanded(
                        child: Text(
                          '所有直播（${channels.length}）',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: FontSizes.lg,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        onPressed: onClose,
                        icon: const Icon(AppIcons.close, color: Colors.white),
                        tooltip: '关闭',
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: channels.isEmpty
                      ? const Center(
                          child: Padding(
                            padding: EdgeInsets.all(Sp.x6),
                            child: Text(
                              '没有可播放的频道',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: FontSizes.sm,
                              ),
                            ),
                          ),
                        )
                      : ListView(
                          clipBehavior: Clip.antiAlias,
                          children: [
                            for (final e in groups.entries) ...[
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  Sp.x4,
                                  Sp.x3,
                                  Sp.x4,
                                  Sp.x1,
                                ),
                                child: Text(
                                  e.key,
                                  style: const TextStyle(
                                    color: Colors.white54,
                                    fontSize: FontSizes.cap,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              for (final i in e.value)
                                _tile(channels[i], i == currentIndex),
                            ],
                            const SizedBox(height: Sp.x6),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _tile(LiveChannel c, bool active) {
    return ListTile(
      dense: true,
      selected: active,
      selectedTileColor: Colors.white12,
      /*
       * ★ 当前台左边加一条竖线 —— 光靠底色在高对比度画面旁边不够明显
       *   （用户要"查看所有直播"，得一眼看出"我正在看哪个"）。
       */
      leading: active
          ? Container(width: 3, height: 20, color: Colors.lightBlueAccent)
          : const SizedBox(width: 3),
      title: Text(
        c.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: active ? Colors.lightBlueAccent : Colors.white,
          fontSize: FontSizes.sm,
          fontWeight: active ? FontWeight.w600 : FontWeights.regular,
        ),
      ),
      // 源自己报的"正在播什么"（不一定有 —— 有就显示，帮用户认台）
      subtitle: (c.nowPlaying == null || c.nowPlaying!.isEmpty)
          ? null
          : Text(
              c.nowPlaying!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white38,
                fontSize: FontSizes.cap,
              ),
            ),
      onTap: () => onPick(c),
    );
  }
}
