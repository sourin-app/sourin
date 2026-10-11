// ═══════════════════════════════════════════════════════════════════════
//  ★ 底栏瘦身重做（Owner 2026-10-09 第 12 条）
// ═══════════════════════════════════════════════════════════════════════
//
//  这里是**新写的**底栏。旧版（三档宽度 × 每档一份重复按钮）整段被替换掉了，
//  改动前后的清单见交付报告。核心变化：
//
//  ```text
//  ① 「选择类」操作全部换成 popover（倍速 / 线路 / 字幕音轨 / 弹幕 / 更多）
//     —— 不再弹窗、不再抽屉（B 站 / 腾讯视频那一档）
//  ② 低频项收进一个「更多」浮层；功能**一个没删**，只是换了入口
//  ③ 四个档位共用**同一套按钮定义**（`_barActions`），不再三份复制
//     —— 改一处就三处生效，也终于能保证各档功能集合一致
//  ④ 时间与进度条用 `ValueListenableBuilder` 局部重建：
//     播放位置每 250ms 推进一次，但**不再**每 tick 重建整页
//  ```
//
//  # 档位与判据
//
//  ```text
//  宽（≥ _kBottomBarRowWidth=830）  桌面 1280 / TV：单行，常驻项全露出
//  中（≥ _kBottomBarMiniWidth=528） 桌面窄窗 / 手机横屏：两行
//  窄（< _kBottomBarRowWidth）      手机竖屏：两行 + 条件项横滑
//  ```
//
//  # 深色系（永远）
//  播放器画面区不跟随浅色主题 —— 见 `_BottomBarIcon` / `PlayerPopoverSurface`，
//  全部写死白/深灰，不读 `Theme.of(context).colorScheme`。

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';

import '../../core/danmaku.dart' show DanmakuConfig;
import '../../core/models.dart' show StreamCandidate;
import '../tokens.dart';
import 'player_more_menu.dart';
import 'player_popover.dart';

/// popover 的 id 常量 —— 开关与按钮用**同一份**字符串
class PlayerPopoverIds {
  const PlayerPopoverIds._();

  static const rate = 'rate';
  static const quality = 'quality';
  static const tracks = 'tracks';

  /// ★★★ Owner 1011 反馈第 1 条：弹幕**轻量悬浮窗**的 id
  ///
  /// # 为什么又加回来了（上一轮刚删）
  /// ```text
  /// 上一轮把弹幕做成「开关 + 设置」两枚**直连**按钮（开关直连 onDanmakuToggle、
  /// 设置直连 onDanmakuSettings 进全屏大卡片），于是 `danmaku` 这个 popover id
  /// 被判为死常量、删掉了（见 t27_w14 A4）。
  /// 但 Owner 这次的原话要的是 B 站那种**贴按钮的小卡片**（图 1）：
  ///   点齿轮 ⇒ 弹出「按类型过滤 + 四个滑杆 + 高级设置」的轻量窗；
  ///   最后一行「高级设置」⇒ 才进现在的全屏大卡片。
  /// ⇒ 弹幕重新需要一个 popover 入口，id 取 `danmakuQuick`（不是旧的 `danmaku`
  ///   —— 旧名会与「弹幕开关」那枚混淆，且旧名在 t27_w14 里被钉过"已下线"）。
  /// ```
  static const danmakuQuick = 'danmakuQuick';

  static const more = 'more';
}

/// 底栏一个动作的描述（icon / 文字 / 可点性）
class _BarAction {
  const _BarAction({
    required this.icon,
    this.label,
    this.tooltip,
    this.onTap,
    this.enabled = true,
    this.active = false,
    this.popoverId,
    this.key,
  });

  final IconData icon;
  final String? label;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool enabled;
  final bool active;

  /// 非 null ⇒ 这枚按钮的点击改由 popover 控制器接管（点一下开小窗）
  final String? popoverId;

  /// 门禁/测试用 key（弹幕开关 / 弹幕设置两枚按 id 对齐；
  /// 见 test/t27_w14_danmaku_bar_form_test.dart）
  final Key? key;
}

/// 「更多」浮层需要的数据（宿主算好传进来）
///
/// ★ 2026-10-10：这里原来还有 `castUrl` / `castHeaders` / `castTitle`
///   三个字段，是底栏还没瘦身前「底栏上直接画一枚投屏按钮」的遗留。
///   瘦身后投屏收进「更多」浮层，数据由宿主算好的 `MoreMenuEntry`
///   （`player_page.dart` 的 `castEntry`，带真的 `CastButton`）带进来
///   ⇒ 这三个字段**声明了但一次都没读过**，属于死接线。
///   删掉，免得下一个人以为「改这里就能改投屏行为」。
class PlayerMoreMenuData {
  const PlayerMoreMenuData({
    required this.groups,
  });

  final List<MoreMenuGroup> groups;
}

/// ★★★ Owner 1011 反馈第 1 条：弹幕**轻量悬浮窗**要展示的全部状态与回调
///
/// # 形态（对齐 B 站图 1）
/// ```text
/// ① 按类型过滤：滚动 / 顶部 / 底部（三枚一键开关）
/// ② 四根滑杆（**可直接拖**）：字号 / 不透明度 / 速度 / 显示区域
/// ③ 最后一行「高级设置」⇒ 进现在的全屏大卡片（DanmakuSettingsDialog）
/// ```
///
/// # 为什么收成一个数据对象，而不是像底栏那样再摊成十几个参数
/// ```text
/// PlayerBottomBar 的构造参数已经很长（20+）。这次纯新增一组「弹幕快捷项」，
/// 摊平会再长 14 行、且这 14 行永远一起传一起不传 ⇒ 收成 `DanmakuQuickPanelData`
/// 一个可空参数：宿主不传（老调用点 / 测试夹具）⇒ 齿轮退回「直达大卡片」的
/// 旧行为，一个字都不用改（见 `_actions` 里那枚齿轮的注释）。
/// ```
///
/// # 值从哪来 —— 与全屏大卡片**同一份真源**（不许各读各的）
/// ```text
/// 四个滑杆的值 = player_page 的 `_danmakuSettings.fontScale/opacity/speed/area`
/// （它本身就是 `DanmakuConfig` 的快照）；
/// 三个类型开关 = `DanmakuConfig.showScroll/showTop/showBottom`。
/// 拖动/点开关 ⇒ 走 `DanmakuConfig.setXxx` + 宿主 setState ⇒ 实时生效
/// （DanmakuOverlay 的 `_ensureLayout` 会因 key 变化重排，与面板同一条路）。
/// ```
///
/// ⚠️ 本项目**没有**的能力（B 站图 1 里有、这里如实不画假开关）：
///   「彩色 / 高级」类型过滤、「弹幕随屏幕缩放」「防挡字幕」「智能防挡弹幕」
///   「同步屏蔽列表」——`DanmakuConfig` / `DanmakuComment` 里都没有对应字段。
class DanmakuQuickPanelData {
  const DanmakuQuickPanelData({
    required this.fontScale,
    required this.opacity,
    required this.speed,
    required this.area,
    required this.showScroll,
    required this.showTop,
    required this.showBottom,
    required this.colorOnly,
    required this.onSetFontScale,
    required this.onSetOpacity,
    required this.onSetSpeed,
    required this.onSetArea,
    required this.onSetShowScroll,
    required this.onSetShowTop,
    required this.onSetShowBottom,
    required this.onSetColorOnly,
    required this.onOpenAdvanced,
    this.onAreaGuide,
  });

  /// 字号缩放（对应 `DanmakuConfig.fontScale`）
  final double fontScale;

  /// 不透明度（对应 `DanmakuConfig.opacity`）
  final double opacity;

  /// 一条弹幕从右到左的秒数（对应 `DanmakuConfig.speed`，越大越慢）
  final double speed;

  /// 纵向可占用比例（对应 `DanmakuConfig.area`）
  final double area;

  /// 三类弹幕的显示开关（对应 `DanmakuConfig.showScroll/showTop/showBottom`）
  final bool showScroll;
  final bool showTop;
  final bool showBottom;

  /// ★ 2026-10-11：「只显示彩色弹幕」开关（对应 `DanmakuConfig.colorOnly`）
  final bool colorOnly;

  final ValueChanged<double> onSetFontScale;
  final ValueChanged<double> onSetOpacity;
  final ValueChanged<double> onSetSpeed;
  final ValueChanged<double> onSetArea;

  final ValueChanged<bool> onSetShowScroll;
  final ValueChanged<bool> onSetShowTop;
  final ValueChanged<bool> onSetShowBottom;

  /// ★ 2026-10-11：写「只显示彩色弹幕」
  final ValueChanged<bool> onSetColorOnly;

  /// ★ 2026-10-11（Owner 第 ④ 条）：拖动「显示区域」滑杆的**开始/结束**通知。
  ///
  /// 宿主（player_page）据此在拖动期间点亮画面上的引导遮罩
  /// （`DanmakuOverlay.areaGuide`）。**不传**（null，老调用点 / 测试夹具）⇒
  /// 滑杆照常拖动、逐帧回调 `onSetArea`，只是**不画**遮罩 —— 与只加遮罩前
  /// 逐字一致，不会让老调用点编译不过。
  final ValueChanged<bool>? onAreaGuide;

  /// 「高级设置」⇒ 宿主打开全屏大卡片（`_openDanmakuSettings`）
  final VoidCallback onOpenAdvanced;
}

/// 底栏（桌面 / 手机 / TV 共用）
class PlayerBottomBar extends StatelessWidget {
  const PlayerBottomBar({
    super.key,
    required this.controller,
    required this.playing,
    required this.positionListenable,
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
    required this.onEpisodes,
    required this.hasEpisodes,
    required this.showEpisodeNav,
    required this.onNext,
    required this.hasNext,
    required this.more,
    this.streams = const <StreamCandidate>[],
    this.currentStream,
    this.onPickStream,
    this.qualityOptions = const <PopoverOption<String>>[],
    this.onPickQuality,
    this.currentQuality = '',
    this.trackGroups = const <String, List<PopoverOption<String>>>{},
    this.onPickTrack,
    this.danmakuEnabled = false,
    this.danmakuBusy = false,
    this.onDanmakuToggle = _noop,
    this.onDanmakuSettings = _noop,
    this.danmakuQuick,
    this.zoomOpen = false,
    this.videoZoom = 100,
    this.onVideoZoom,
    this.onZoomToggle,
    this.fade,
    this.buffered,
    this.bufferBarKey,
  });

  static void _noop() {}

  final PopoverController controller;

  final bool playing;

  /// ★ 播放位置的**局部**真源（）
  ///
  /// 为什么不是 ：改前这里是普通字段，每秒一次整页 。
  /// 改成 listenable 之后只有「时间 + 进度条」那一小块在重建。
  final ValueListenable<Duration> positionListenable;
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

  final bool hasEpisodes;
  final VoidCallback onEpisodes;
  final bool showEpisodeNav;
  final bool hasNext;
  final VoidCallback onNext;

  final PlayerMoreMenuData more;

  final List<StreamCandidate> streams;
  final StreamCandidate? currentStream;
  final void Function(StreamCandidate)? onPickStream;

  final List<PopoverOption<String>> qualityOptions;
  final void Function(String)? onPickQuality;
  final String currentQuality;

  /// 字幕 / 音轨：分组 → 选项
  final Map<String, List<PopoverOption<String>>> trackGroups;
  final void Function(String group, String id)? onPickTrack;

  final bool danmakuEnabled;
  final bool danmakuBusy;
  final VoidCallback onDanmakuToggle;
  final VoidCallback onDanmakuSettings;

  /// ★★★ Owner 1011 反馈第 1 条：齿轮那枚弹出的**轻量悬浮窗**数据。
  ///
  /// 传 null（老调用点 / 测试夹具）⇒ 齿轮退回「直达全屏大卡片」的旧行为。
  /// 传非 null ⇒ 齿轮变成 popover 入口（`PlayerPopoverIds.danmakuQuick`），
  /// 弹出的面板里最后一行「高级设置」仍回到 [onDanmakuSettings]。
  final DanmakuQuickPanelData? danmakuQuick;

  final bool zoomOpen;
  final double videoZoom;
  final ValueChanged<double>? onVideoZoom;
  final VoidCallback? onZoomToggle;

  final Animation<double>? fade;
  final PlayerBufferedRange? buffered;
  final Key? bufferBarKey;

  static String _fmt(Duration d) {
    final h = d.inHours;
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60);
    String two(int n) => n.toString().padLeft(2, '0');
    return h > 0 ? '$h:${two(m)}:${two(s)}' : '${two(m)}:${two(s)}';
  }

  /// 常用的倍速档位（与旧版**逐字同一份**，不许各写各的）
  static const List<double> kRates = <double>[
    0.5,
    0.75,
    1.0,
    1.25,
    1.5,
    2.0,
    3.0,
  ];

  /// ★ Owner 1011 反馈第 1 条：弹幕的**两枚直连入口**（开关 / 设置）
  ///
  /// 与 `PlayerProgressSlider.thumbKey` 同款 —— 给门禁一个稳定的抓手，
  /// 免得测试靠 tooltip（开关那枚是普通 `TextButton`，没有 `Tooltip` 祖先，
  /// `find.byTooltip` 找不到）。见 test/t27_w14_danmaku_bar_form_test.dart。
  static const Key danmakuToggleKey = ValueKey<String>('t27-danmaku-toggle');
  static const Key danmakuSettingsKey =
      ValueKey<String>('t27-danmaku-settings');

  List<PopoverOption<double>> rateOptions() => [
    for (final r in kRates)
      PopoverOption<double>(
        value: r,
        label: '${_trimRate(r)}x',
        checked: (r - rate).abs() < 0.001,
      ),
  ];

  static String _trimRate(double r) =>
      r == r.roundToDouble() ? r.toStringAsFixed(0) : '$r';

  List<PopoverOption<String>> streamOptions() => [
    for (final s in streams)
      PopoverOption<String>(
        value: s.url,
        label: s.label ?? s.quality ?? s.url,
        checked: currentStream != null && currentStream!.url == s.url,
      ),
  ];

  /// 底栏的常驻 + 条件动作（宽档）
  ///
  /// ★ 低频项（截图 / 设置 / 弹幕设置 / 缩放 / 片头片尾 / 画中画 / 换源 /
  ///   投屏）**一个都没删** —— 它们只是搬进了「更多」浮层。
  List<_BarAction> _actions(BuildContext context) {
    final isTouch = MediaQuery.of(context).size.shortestSide < 600;
    return [
      if (hasEpisodes && !isTouch)
        _BarAction(
          icon: Icons.list,
          label: '选集',
          tooltip: '选集',
          onTap: onEpisodes,
        ),
      if (streams.length > 1)
        _BarAction(
          icon: Icons.high_quality,
          label: '清晰度',
          tooltip: '清晰度',
          popoverId: PlayerPopoverIds.quality,
          active: controller.isOpen(PlayerPopoverIds.quality),
        ),
      /*
       * ★ OPS-5 ②（Owner 2026-10-10 反馈第 2 条）：这里原来还有一枚「倍速」
       *   `_BarAction`，**没有任何 if 门控** ⇒ 恒渲染，于是底栏上出现
       *   两个倍速入口（截图：左边「▶ 🔊 ──●── 1x」+ 右边那排又一枚 1x）。
       *   常驻高频组（`primary`，本文件下面的 `_PopoverButton`）里那枚才是
       *   「任何宽度都在第一行、永不折叠」的正主（test/t80_cast_wiring_test.dart
       *   A⑩ 钉着它的顺序）⇒ 删这一枚，不是删那一枚。
       */
      if (trackGroups.isNotEmpty)
        _BarAction(
          icon: Icons.closed_caption,
          tooltip: '字幕与音轨',
          popoverId: PlayerPopoverIds.tracks,
          active: controller.isOpen(PlayerPopoverIds.tracks),
        ),
      _BarAction(
        // ★★★ Owner 1011 反馈第 1 条（弹幕做成 B 站那种形态）：
        //   「一个开关,一个设置」⇒ 开关这枚**直接开关弹幕**（onTap 而不是
        //   popoverId）—— 点一下就是开/关，不再弹那个「关闭弹幕 / 弹幕设置」
        //   两层小菜单。设置那枚（下面紧接着的全新一枚）才是「弹出来面板
        //   直接操作」。
        //
        //   图标/高亮沿用改前：开=subtitle 图标 + 青色高亮，关=subtitles_off。
        key: danmakuToggleKey,
        icon: danmakuEnabled ? Icons.subtitles : Icons.subtitles_off,
        label: '弹幕',
        tooltip: danmakuBusy ? '弹幕加载中…' : (danmakuEnabled ? '关闭弹幕' : '开启弹幕'),
        active: danmakuEnabled,
        onTap: onDanmakuToggle,
      ),
      _BarAction(
        // ★★★ Owner 1011 反馈第 1 条（弹幕做成 B 站那种形态）：
        //   设置这枚点开的是一个**轻量悬浮窗**（B 站图 1 那种贴按钮的小卡片：
        //   按类型过滤 + 四个可直接拖的滑杆 + 最后一行「高级设置」）。
        //
        //   ⚠️ 与「开关」那枚的区别（别照抄）：
        //     开关那枚是**纯动作**（onTap，直连开关，不弹任何东西）；
        //     设置这枚是 **popover 入口**（popoverId，点击/悬停弹小窗）。
        //   ⚠️ 这里**不能**同时给 onTap：`_PopoverButton` 里一旦 onTap 非空
        //      （player_bottom_bar.dart 的 `onPressed: onTap ?? toggle`），
        //      点击就走 onTap、面板永远打不开 —— 于是「高级设置」那行就没了意义
        //      （齿轮本该先弹小窗）。
        //
        //   宿主没给 `danmakuQuick`（老调用点 / 测试夹具）⇒ 退回旧行为：
        //   直连 `onDanmakuSettings`（一次点开全屏大卡片），保兼容。
        key: danmakuSettingsKey,
        icon: Icons.tune,
        tooltip: '弹幕设置',
        popoverId: danmakuQuick == null ? null : PlayerPopoverIds.danmakuQuick,
        onTap: danmakuQuick == null ? onDanmakuSettings : null,
      ),
      _BarAction(
        icon: Icons.more_horiz,
        label: '更多',
        tooltip: '更多',
        popoverId: PlayerPopoverIds.more,
        active: controller.isOpen(PlayerPopoverIds.more),
      ),
      if (showEpisodeNav)
        _BarAction(
          icon: Icons.skip_next,
          tooltip: '下一集',
          enabled: hasNext,
          onTap: onNext,
        ),
      _BarAction(
        icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
        tooltip: fullscreen ? '退出全屏' : '全屏',
        onTap: onToggleFullscreen,
      ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final anim = fade ?? kAlwaysCompleteAnimation;
    /*
     * ★★★ 2026-10-12：opacity 与 ignoring **必须每帧现读**，不能 build 期定格
     *
     * # 根因（逐帧实测确认）
     * ```text
     * 宿主用 `ListenableBuilder(listenable: _controlsAnim, child: _BottomBar(...))`
     * 挂底栏，`child` 是**预建实例**。动画 tick 时 builder 只 `return child!`
     * ⇒ Flutter canonicalization 发现 `identical(old, new)` ⇒ 底栏子树不重建。
     * 于是 build() 里算好的 `opacity` / `ignoring` 被 builder 捕获成**常量**：
     *   隐藏：底栏恒 1.0，直到整条被硬卸载；
     *   显示：底栏恒 0.0，永不回来。
     * ⇒ 顶栏（每帧现读 `fade.value`）已经对了，底栏这份必须**同形**。
     * ```
     * ⚠️ `IgnorePointer.ignoring` 也一并搬进 builder —— 否则会跟着冻结成
     *    「看不见但能点到」（见 `player_page.dart:15649-15653` 顶栏那份警告）。
     *    改前 build 期判 `opacity < 0.5`、改后每帧判 `o < 0.5`；两者用的都是
     *    同一个 `fade.value`，阈值与判据完全一致，只是**采样时机**由「最后一次
     *    整页 build」变成「每一帧」—— 正是与顶栏对齐所要求的语义，无行为回归。
     */
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedBuilder(
        animation: anim,
        builder: (context, child) {
          final o = (fade?.value ?? 1.0).clamp(0.0, 1.0);
          return IgnorePointer(
            ignoring: o < 0.5,
            child: Opacity(opacity: o, child: child),
          );
        },
        /*
         * ★ Stack：渐变条在下、popover 在上。
         *   popover 不放在 `Container` 里 —— 那样它的背景渐变会盖住面板底部，
         *   而且 `clipBehavior` 一变就会把超出条高的面板裁掉。
         *   这里用 `clipBehavior: Clip.none` + `Stack`，面板可以自由地
         *   长到条的上方去。
         */
        child: _body(context),
      ),
    );
  }

  /// ★★ popover 层 —— **由播放页那个 Stack 承载**，不是底栏自己
  ///
  /// # 为什么必须提到那一层（实测出来的，不是猜的）
  /// ```text
  /// 底栏在播放页里是 `Positioned(bottom:0)`、高约 106px 的一个盒子。
  /// 面板若作为它的子件（第一版就是这么写的），它能长到的上界就被那 106px
  /// 卡死 ⇒ 无头截图里 popover 与「没展开」的截图 **md5 完全相同**，
  /// 一像素都没画出来（widget 树里 `PlayerMoreMenu` 是有的，就是画不出来）。
  /// ⇒ 提到同一个 Stack 里当**兄弟**：面板从底栏上沿往上长，
  ///   而那个 Stack 是整屏（`SizedBox.expand`）⇒ 不会被任何祖先裁掉。
  /// ```
  Widget buildPopoverLayer() {
    final id = controller.openId;
    final body = switch (id) {
      PlayerPopoverIds.rate => _panelSurface(
        rateOptions().map(_rateRow).toList(),
      ),
      PlayerPopoverIds.quality when qualityOptions.isNotEmpty => _panelSurface(
        _qualityRows(),
      ),
      PlayerPopoverIds.tracks when trackGroups.isNotEmpty => _panelSurface([
        for (final entry in trackGroups.entries) ...[
          PopoverGroupLabel(entry.key),
          for (final o in entry.value) _trackRow(entry.key, o),
        ],
      ], width: 220),
      PlayerPopoverIds.danmakuQuick when danmakuQuick != null =>
        _danmakuQuickPanel(danmakuQuick!),
      PlayerPopoverIds.more => _morePanel(),
      _ => const SizedBox.shrink(),
    };
    return _PopoverAnchorLayer(
      controller: controller,
      id: id,
      child: PopoverKeepAlive(
        controller: controller,
        child: PopoverMotion(visible: id != null, child: body),
      ),
    );
  }

  Widget _panelSurface(List<Widget> rows, {double width = 168}) =>
      PlayerPopoverSurface(
        width: width,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: rows,
        ),
      );

  // ═══════════════════════════════════════════════════════════════════════
  //  ★★★ Owner 1011 反馈第 1 条：弹幕轻量悬浮窗（B 站图 1 那种）
  // ═══════════════════════════════════════════════════════════════════════
  //
  //  # 宽度为什么是 300（不是默认的 168）
  //  ```text
  //  168 只够放「一行文字 + 一个对勾」的倍速 / 清楚度选单。
  //  这里每根滑杆都要三样东西并排：标签(56) + 滑杆(Expanded) + 读数(46)
  //  ⇒ 168 会把滑杆挤成一根几乎拖不动的短棍（Owner 明确要「直接拖」
  //    的操作感）。300 下中间那段滑杆约 150px，拖动手感够。
  //  ```
  //
  //  # 最后一行「高级设置」
  //  ```text
  //  它**不关**面板（不像选清晰度那样点完 close）—— 用户进的是更深的一层，
  //  关不关小窗无所谓，但保留小窗更自然（回来后还在原位）。
  //  真正的关面板交给宿主的 `_openDanmakuSettings`（它会先把控制条收起来、
  //  再挂全屏大卡片）。
  //  ```
  static const Key danmakuQuickPanelKey =
      ValueKey<String>('t27-danmaku-quick-panel');
  static const Key danmakuQuickAdvancedKey =
      ValueKey<String>('t27-danmaku-quick-advanced');

  /// 三类弹幕「一键开关」的 key（门禁抓手，按 id 对齐）
  static const Key danmakuQuickScrollKey =
      ValueKey<String>('t27-danmaku-quick-scroll');
  static const Key danmakuQuickTopKey =
      ValueKey<String>('t27-danmaku-quick-top');
  static const Key danmakuQuickBottomKey =
      ValueKey<String>('t27-danmaku-quick-bottom');

  /// ★ 2026-10-11（Owner 第 1 条续）：第四枚类型开关「彩色」
  /// （= 只显示彩色弹幕，对应 `DanmakuConfig.colorOnly`）
  static const Key danmakuQuickColorOnlyKey =
      ValueKey<String>('t27-danmaku-quick-coloronly');

  /// 四根滑杆的 key（门禁抓手）
  static const Key danmakuQuickFontScaleKey =
      ValueKey<String>('t27-danmaku-quick-fontscale');
  static const Key danmakuQuickOpacityKey =
      ValueKey<String>('t27-danmaku-quick-opacity');
  static const Key danmakuQuickSpeedKey =
      ValueKey<String>('t27-danmaku-quick-speed');
  static const Key danmakuQuickAreaKey =
      ValueKey<String>('t27-danmaku-quick-area');

  /// 弹幕轻量悬浮窗的本体
  Widget _danmakuQuickPanel(DanmakuQuickPanelData d) => PlayerPopoverSurface(
    width: 300,
    child: Column(
      key: danmakuQuickPanelKey,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const PopoverGroupLabel('显示哪几类'),
        // ① 按类型过滤 —— 四枚一键开关（滚动 / 顶部 / 底部 / 彩色）
        //
        // ★ 2026-10-11（Owner 第 1 条续）：补上第四枚「彩色」。
        //   B 站图 1 里就是四枚；本项目的 `DanmakuComment.color` **有**颜色字段，
        //   所以「彩色」是**有数据支持**的真开关（不是假开关）——
        //   语义 = 只显示彩色弹幕（白色弹幕隐藏），见 `DanmakuConfig.colorOnly`。
        //   ⚠️ 「高级」这一枚**不做**：`DanmakuComment` 里没有任何能区分
        //   "高级弹幕"的字段（无样式/定位/动画信息）⇒ 无数据支持，如实不画。
        Padding(
          padding: const EdgeInsets.fromLTRB(Sp.x3, 0, Sp.x3, Sp.x1),
          child: Row(
            children: [
              _quickTypeChip(
                key: danmakuQuickScrollKey,
                label: '滚动',
                on: d.showScroll,
                onTap: () => d.onSetShowScroll(!d.showScroll),
              ),
              const SizedBox(width: Sp.x2),
              _quickTypeChip(
                key: danmakuQuickTopKey,
                label: '顶部',
                on: d.showTop,
                onTap: () => d.onSetShowTop(!d.showTop),
              ),
              const SizedBox(width: Sp.x2),
              _quickTypeChip(
                key: danmakuQuickBottomKey,
                label: '底部',
                on: d.showBottom,
                onTap: () => d.onSetShowBottom(!d.showBottom),
              ),
              const SizedBox(width: Sp.x2),
              _quickTypeChip(
                key: danmakuQuickColorOnlyKey,
                label: '彩色',
                on: d.colorOnly,
                onTap: () => d.onSetColorOnly(!d.colorOnly),
              ),
            ],
          ),
        ),
        const PopoverDivider(),
        const PopoverGroupLabel('显示'),
        // ② 四根滑杆 —— **直接拖**（拖动中每一帧都回调，实时生效）
        _quickSlider(
          key: danmakuQuickFontScaleKey,
          label: '字号',
          value: d.fontScale,
          min: DanmakuConfig.fontScaleMin,
          max: DanmakuConfig.fontScaleMax,
          readout: '${(d.fontScale * 100).round()}%',
          onChanged: d.onSetFontScale,
        ),
        _quickSlider(
          key: danmakuQuickOpacityKey,
          label: '不透明度',
          value: d.opacity,
          min: DanmakuConfig.opacityMin,
          max: DanmakuConfig.opacityMax,
          readout: '${(d.opacity * 100).round()}%',
          onChanged: d.onSetOpacity,
        ),
        _quickSlider(
          key: danmakuQuickSpeedKey,
          label: '速度',
          value: d.speed,
          min: DanmakuConfig.speedMin,
          max: DanmakuConfig.speedMax,
          readout: _speedLabel(d.speed),
          onChanged: d.onSetSpeed,
        ),
        _quickSlider(
          key: danmakuQuickAreaKey,
          label: '显示区域',
          value: d.area,
          min: DanmakuConfig.areaMin,
          max: DanmakuConfig.areaMax,
          readout: '${(d.area * 100).round()}%',
          onChanged: d.onSetArea,
          // ★ 2026-10-11（Owner 第 ④ 条）：拖动期间点亮画面上的引导遮罩
          //   （起手 = 开始拖 ⇒ 显示；松手 = 结束拖 ⇒ 淡出）。
          //   `onAreaGuide` 为 null（老调用点 / 测试夹具）⇒ 传 null，不画遮罩。
          onGuideStart: d.onAreaGuide == null
              ? null
              : () => d.onAreaGuide!(true),
          onGuideEnd:
              d.onAreaGuide == null ? null : () => d.onAreaGuide!(false),
        ),
        const PopoverDivider(),
        // ③ 高级设置 ⇒ 进全屏大卡片（AppId / 屏蔽词 / 重新获取…都在那）
        PopoverRow(
          key: danmakuQuickAdvancedKey,
          label: '高级设置',
          hint: '凭证 / 屏蔽词',
          onTap: d.onOpenAdvanced,
        ),
      ],
    ),
  );

  /// 类型一键开关（B 站那种小图标按钮；开 = 青色高亮）
  Widget _quickTypeChip({
    required Key key,
    required String label,
    required bool on,
    required VoidCallback onTap,
  }) {
    const accent = Color(0xFF32C7FF);
    return Expanded(
      child: InkWell(
        key: key,
        onTap: onTap,
        borderRadius: Radii.rSm,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: Sp.x1),
          decoration: BoxDecoration(
            color: on ? accent.withValues(alpha: 0.18) : Colors.transparent,
            borderRadius: Radii.rSm,
            border: Border.all(
              color: on ? accent : const Color(0x33FFFFFF),
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: on ? accent : const Color(0xFFB9BEC6),
              fontSize: FontSizes.cap,
            ),
          ),
        ),
      ),
    );
  }

  /// 弹幕速度读数：B 站是「极慢/慢/标准/快/极快」这种档位词。
  /// 本项目的 `speed` 是「走完一屏的秒数」（越大越慢）⇒ 按分档给出中文，
  /// 与全屏大卡片里那根滑杆显示的 `8.0s` 并存（档位词更好懂，秒数更精确）。
  static String _speedLabel(double seconds) {
    if (seconds >= 14) return '极慢';
    if (seconds >= 10) return '慢';
    if (seconds >= 6.5) return '标准';
    if (seconds >= 4.5) return '快';
    return '极快';
  }

  /// 面板里的一根滑杆：标签 + 滑杆（直接拖）+ 右侧读数
  ///
  /// [onGuideStart] / [onGuideEnd]：只在「显示区域」那根上传 —— 起手/松手时
  /// 通知宿主开关画面上的引导遮罩（其它滑杆传 null，行为不变）。
  Widget _quickSlider({
    required Key key,
    required String label,
    required double value,
    required double min,
    required double max,
    required String readout,
    required ValueChanged<double> onChanged,
    VoidCallback? onGuideStart,
    VoidCallback? onGuideEnd,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(Sp.x3, 0, Sp.x3, 0),
      child: Row(
        children: [
          SizedBox(
            width: 56,
            child: Text(
              label,
              style: const TextStyle(
                color: Color(0xFFB9BEC6),
                fontSize: FontSizes.cap,
              ),
            ),
          ),
          Expanded(
            // ★ 用 Listener 抓"起手/松手"，包住 Slider —— 拖动中每一帧的 onChanged
            //   仍由 Slider 自己发（实时生效那条线一个字没动）；
            //   这里只**额外**加一对边界事件，去驱动引导遮罩的显隐。
            child: Listener(
              onPointerDown: onGuideStart == null
                  ? null
                  : (_) => onGuideStart(),
              onPointerUp: onGuideEnd == null ? null : (_) => onGuideEnd(),
              onPointerCancel: onGuideEnd == null ? null : (_) => onGuideEnd(),
              child: Slider(
                key: key,
                value: value.clamp(min, max),
                min: min,
                max: max,
                onChanged: onChanged,
              ),
            ),
          ),
          SizedBox(
            width: 46,
            child: Text(
              readout,
              textAlign: TextAlign.right,
              style: const TextStyle(
                color: Color(0xFF8C8C8C),
                fontSize: FontSizes.cap,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 清晰度行 —— [labelOverride] 用来把「只显示清晰度」的显示文字塞进来
  /// （见 [_qualityRows] 的取舍说明）；传 null 时退回 `o.label`。
  ///
  /// ⚠️ **`labelOverride` 非空时必须同时抑制 `hint`**（Owner 1011 复报：
  ///    「bilibili 的怎么还是两个重复的 1080p?」）。
  /// ```text
  /// 我第一版只换了 `label` 却仍传 `hint: o.hint` ⇒ 行里画出
  ///   「1080P        1080P」——左边是 override、右边是原 hint，**同一个值画两遍**。
  /// ⇒ override 非空时传 `hint: null`（那份信息已经在 label 里了）。
  /// ```
  Widget _row(PopoverOption<String> o, {String? labelOverride}) => PopoverRow(
    label: labelOverride ?? o.label,
    // ★ 只在**没被 override** 时才把 hint 画在右端，否则同一档会重复两次
    hint: labelOverride == null ? o.hint : null,
    checked: o.checked,
    onTap: o.enabled
        ? () {
            onPickQuality?.call(o.value);
            controller.close();
          }
        : null,
  );

  /// ★★★ Owner 1011 反馈第 4 条：清晰度面板**只显示清晰度**，不再显示来源名。
  ///
  /// # Owner 原话（逐字）
  /// ```text
  /// > 4.然后还有这个清晰度,前面的无关紧要的信息就不用展示了吧?
  /// ```
  /// 他后来澄清：「前面的无关紧要的信息」= 每行左侧的**来源名**
  /// （截图里那个被省略号截断的「哔哩哔哩 …」），只保留「1080P / 720P / 480P」。
  ///
  /// # 数据口径（为什么 `hint` 才是清晰度、`label` 是来源名）
  /// ```text
  /// player_page.dart 的 `_qualityPopoverOptions()`：
  ///   label: s.label ?? s.quality ?? '默认线路'   ← 来源 / 线路名（长，被 ellipsis 截断）
  ///   hint : s.quality                            ← 清晰度档位（1080P）
  /// 而 StreamCandidate（models.dart:393-398）里：
  ///   quality = 清晰度标签（如 "1080P"）  ← 真正想给用户看的
  ///   label   = 线路名（如 "官方 HLS" / "CDN 直连" / "声明式"）← Owner 说的「无关紧要」
  /// ```
  /// 所以「只显示清晰度」= 主文字取 `hint`（quality），
  /// 而不是继续用 `label` 再补一个 hint。
  ///
  /// # ⚠️ 一个必须处理的坑：同清晰度多线路
  /// ```text
  /// 直接无脑丢掉来源名，会在「同一档清晰度来自不同线路」时**无法区分**
  /// （两行都写 1080P，用户不知道该点哪个）。
  /// ```
  /// ## 这在本仓的真实数据里会发生吗 —— 已核实（读源码，不是猜）
  /// ```text
  /// ① declarative.rs:165 `variants: HashMap<String, String>` ⇒ 变体键**唯一**
  ///    （键就是 quality，`.with_quality(label)`，label 恒为来源名 "声明式"）。
  /// ② cctv.rs:593 的 [("hls1","高清"),("hls2","标清")] 与 :705 的四档 CDN
  ///    （超清/高清/标清/流畅）—— 同一来源内 quality 逐条**不同**。
  /// ③ `resolve_stream`（playback.rs:149）**不做任何去重或合并**：
  ///    它只把一个 provider 的 `resolve()` 结果原样返回（仅套代理）。
  /// ⇒ 内置源当前**不会**产生「同 quality 不同 label」。
  /// ```
  /// ## 但插件（JS）是**用户可装**的，不能假设这个不变量永远成立
  /// ```text
  /// 插件出口的 StreamCandidate 完全由脚本自己写（见 plugins/*.js），
  /// 一个第三方插件完全可以返回两条 quality 都叫 "1080P"、label 不同的候选。
  /// 与其赌「不可能」，这里做成**按需消歧**：
  ///   默认 只显示清晰度；**仅当某一档清晰度出现不止一次**时，
  ///   才给**那几行**附上来源名，保证任何情况下都点得对。
  /// ⇒ 常见形态（Owner 截图那种每档一条）与他的要求**逐字一致**；
  ///   罕见形态（同档多来源）也不会变成两行一模一样的字。
  /// ```
  ///
  /// ⚠️ 复用 [_row]（不是新写一套）：`_row` 的 onTap / checked 逻辑必须原样保留
  ///    （`_trackRow` 是 CR-17 明确要求**分开**的，别动它）。
  List<Widget> _qualityRows() {
    // 清晰度的显示文字：优先 quality（hint），退回 label，再退回占位。
    String tierOf(PopoverOption<String> o) {
      final q = o.hint;
      if (q != null && q.isNotEmpty) return q;
      return o.label.isEmpty ? '默认' : o.label;
    }

    final tiers = <String, int>{};
    for (final o in qualityOptions) {
      final t = tierOf(o);
      tiers[t] = (tiers[t] ?? 0) + 1;
    }

    return [
      for (final o in qualityOptions)
        if ((tiers[tierOf(o)] ?? 0) > 1)
          // 同档多条 ⇒ 附来源名消歧（`label` 就是来源名）。
          _row(o, labelOverride: '${tierOf(o)} · ${o.label}')
        else
          _row(o, labelOverride: tierOf(o)),
    ];
  }

  /// ★ CR-17：字幕 / 音轨的行**不能**复用 [_row]。
  ///
  /// [_row] 的 onTap 写死了 `onPickQuality`，所以复用它等于「选一条字幕 = 把
  /// 清晰度切成字幕 id」，而 `onPickTrack(group, id)` 一次都不会被调用。
  Widget _trackRow(String group, PopoverOption<String> o) => PopoverRow(
    label: o.label,
    hint: o.hint,
    checked: o.checked,
    onTap: o.enabled
        ? () {
            onPickTrack?.call(group, o.value);
            controller.close();
          }
        : null,
  );

  Widget _rateRow(PopoverOption<double> o) => PopoverRow(
    label: o.label,
    checked: o.checked,
    onTap: () {
      onRate(o.value);
      controller.close();
    },
  );

  Widget _morePanel() =>
      PlayerMoreMenu(groups: more.groups, onDismiss: controller.close);

  Widget _body(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    return Container(
      padding: EdgeInsets.fromLTRB(Sp.x4, Sp.x6, Sp.x4, Sp.x4 + bottomInset),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [Colors.black87, Colors.transparent],
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (zoomOpen)
            PlayerZoomSliderCard(
              zoom: videoZoom,
              onChanged: (v) => onVideoZoom?.call(v),
              onDone: (v) => onVideoZoom?.call(v),
              onClose: () => onZoomToggle?.call(),
            ),
          if (!isLive) _progressRow(),
          _buttonsRow(context),
        ],
      ),
    );
  }

  /// 进度条 + 两侧时间
  ///
  /// ★ 时间与滑杆**同一行**（进度条占 Expanded）：手机上时间让位给滑杆，
  ///   桌面两端对齐 —— 两种形态都只需要这一行，字号同样取 `FontSizes.cap`。
  Widget _progressRow() {
    final total = Text(
      _fmt(duration),
      style: const TextStyle(color: Colors.white, fontSize: FontSizes.cap),
    );
    // ★ 整块进度区（含「已播放时间」与滑杆）由 listenable 驱动：
    //   播放位置每秒变一次 ⇒ 只有这一小块重建，底栏按钮行与整页都不动。
    return ValueListenableBuilder<Duration>(
      valueListenable: positionListenable,
      builder: (context, position, _) => Row(
        children: [
          Text(
            _fmt(position),
            style: const TextStyle(
              color: Colors.white,
              fontSize: FontSizes.cap,
            ),
          ),
          const SizedBox(width: Sp.x2),
          Expanded(
            child: PlayerProgressSlider(
              position: position,
              duration: duration,
              buffered: buffered,
              onSeek: onSeek,
              barKey: bufferBarKey,
            ),
          ),
          const SizedBox(width: Sp.x2),
          total,
        ],
      ),
    );
  }

  Widget _buttonsRow(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final avail = c.maxWidth;
        final actions = _actions(context);

        // ── 常驻高频组（任何宽度都在第一行，永不折叠）──
        final primary = <Widget>[
          _BarIconButton(
            icon: playing ? Icons.pause : Icons.play_arrow,
            tooltip: '播放 / 暂停',
            onTap: onTogglePlay,
            big: true,
          ),
          _VolumeControl(
            muted: muted,
            volume: volume,
            onToggleMute: onToggleMute,
            onVolume: onVolume,
            compact: avail < 400,
          ),
          _PopoverButton(
            controller: controller,
            id: PlayerPopoverIds.rate,
            icon: Icons.speed,
            label: '${_trimRate(rate)}x',
            tooltip: '倍速',
          ),
        ];

        // ── 条件项（选集 / 清晰度 / 字幕 / 弹幕 / 更多 / 下一集）──
        final secondary = <Widget>[
          for (final a in actions)
            if (a.popoverId == null && a.onTap == null)
              _BarIconButton(
                key: a.key,
                icon: a.icon,
                tooltip: a.tooltip,
                enabled: a.enabled,
                active: a.active,
              )
            // ★ CR-18：`popoverId != null` 就要走 [_PopoverButton]。
            //   以前这里只判 `label != null`，于是「字幕与音轨」这类
            //   **只有图标 + popoverId** 的条目落到下面的 `_BarIconButton`,
            //   而它的 onTap 本来就是 null ⇒ `IconButton.onPressed == null`
            //   ⇒ 永远点不动、永远灰着，弹层也就永远打不开。
            else if (a.label != null || a.popoverId != null)
              _PopoverButton(
                key: a.key,
                controller: controller,
                id: a.popoverId ?? '',
                icon: a.icon,
                label: a.label,
                tooltip: a.tooltip,
                active: a.active,
                onTap: a.onTap,
              )
            else
              _BarIconButton(
                key: a.key,
                icon: a.icon,
                tooltip: a.tooltip,
                enabled: a.enabled,
                active: a.active,
                onTap: a.onTap,
              ),
        ];

        final wide = avail >= _kBarRowWidth;
        if (wide) {
          return Row(children: [...primary, const Spacer(), ...secondary]);
        }
        // 窄 / 中档：第一行常驻 + 弹性 + 全屏，其余条件项横滑兜底
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                ...primary,
                const Spacer(),
                _BarIconButton(
                  icon: fullscreen ? Icons.fullscreen_exit : Icons.fullscreen,
                  tooltip: fullscreen ? '退出全屏' : '全屏',
                  onTap: onToggleFullscreen,
                ),
              ],
            ),
            const SizedBox(height: Sp.x1),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: secondary),
            ),
          ],
        );
      },
    );
  }

  /// 单行放得下全部常驻项所需的最小宽度
  ///
  /// ★ 比改前的 830 小：低频项收进「更多」之后，单行的固有宽只剩播放/音量/
  ///   倍速/全屏 + 条件项 ⇒ 桌面 1280 与手机横屏都能一行放下。
  static const double _kBarRowWidth = 720;
}

/// ★★ OPS-5 ②：把面板**挪到它那枚按钮上方**，并保证整块留在窗口里。
///
/// # 为什么必须是「布局期」而不是「build 期读 Rect」
/// ```text
/// 面板这一层挂在页面整屏 Stack 里，而按钮在底栏里 —— 两者是**兄弟**。
/// 兄弟节点之间没有先后保证：面板 build 的时候按钮可能还没布局，
/// 读到的 rect 会是上一帧的旧值（横竖屏切换时会闪到错误位置）。
/// ⇒ 走 `CustomSingleChildLayout`：它的 `getPositionForChild` 在
///   **子件布局完之后**才被调用，且子件尺寸已经确定（能拿到面板真实宽高
///   去 clamp）。这一步只是平移，不再触发一轮布局，没有循环风险。
/// ```
///
/// # 对齐规则（Owner 1011 第 4 条后的**终版**契约）
/// ```text
/// ① 横向**居中对齐到触发它的那枚按钮**（Owner 亲口澄清）：
///    面板中心 = 按钮中心。这是"贴近按钮"与"看起来正"之间的平衡——
///    既不像「右缘贴按钮」那样明显偏、也不会跑到屏幕正中离按钮很远。
/// ② 贴边放不下 ⇒ 往中间挪（clamp 进 [Sp.x2, 窗口宽 - Sp.x2]）——
///    正是 Owner 说的「除了太侧边的没空间富裕的,可以不居中」。
/// ③ 上下：面板底边贴在按钮上沿上方 Sp.x2 —— 由宿主的 `bottom: 96` 保证；
///    按钮因安全区抬高时再补一个 Δ，保证缝隙恒定
/// ```
/// ⚠️ **一次判据反转的记录**（别照着上一版回退）：
/// ```text
/// 上一版把 ① 实现成「居中于**播放器/屏幕**」——那是照 Owner 原话
///   「明明空间很多…为什么不居中」的字面理解。Owner 复核截图后澄清：
///   他要的是「居中于**按钮**（贴近但避开边缘）」，不是屏幕正中。
/// ⇒ 差别是**基准点**：屏幕宽/2  vs  按钮中心。
/// ```
/// ⚠️ 这一层被**五个** popover 共用（倍速/清晰度/字幕/弹幕/更多）⇒
///    该规则是**通用**的，见 [_PopoverAnchorDelegate.getPositionForChild]。
///
/// ⚠️ 锚点还没登记（面板先于按钮挂载的那一帧）⇒ 退回宿主给的右下角基准，
///    绝不猜一个横向位置。
class _PopoverAnchorLayer extends StatelessWidget {
  const _PopoverAnchorLayer({
    required this.controller,
    required this.id,
    required this.child,
  });

  final PopoverController controller;
  final String? id;
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomSingleChildLayout(
    // 这一层是「面板坐标系的原点」：探针量到的全局矩形要减掉它的全局原点
    key: controller.layerKey,
    delegate: _PopoverAnchorDelegate(
      anchor: controller.anchorRectOf(id),
      viewport: MediaQuery.sizeOf(context),
      viewPadding: MediaQuery.viewPaddingOf(context),
      spacing: Sp.x2,
    ),
    child: child,
  );
}

/// 面板的定位代理：读按钮的屏幕矩形，把面板平移过去
class _PopoverAnchorDelegate extends SingleChildLayoutDelegate {
  const _PopoverAnchorDelegate({
    required this.anchor,
    required this.viewport,
    required this.viewPadding,
    required this.spacing,
  });

  /// 当前展开那枚按钮的屏幕矩形（null = 还没上报 ⇒ 走宿主的默认定位）
  final Rect? anchor;
  final Size viewport;
  final EdgeInsets viewPadding;
  final double spacing;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      constraints.loosen();

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    // 宿主给的是「面板右下角贴窗口右下角（留 Sp.x2）」⇒ 竖向基准与锚点缺失时沿用
    final fallback = Offset(
      size.width - spacing - childSize.width,
      size.height - spacing - childSize.height,
    );

    // 左右可放区间（宿主本来就留了 `right: Sp.x2` 的边距，这里再兜一次底）
    final minLeft = spacing;
    final maxLeft = size.width - spacing - childSize.width;

    /*
     * ══════════════════════════════════════════════════════════════════
     * ★★★ Owner 1011 反馈第 4 条：面板横向**居中对齐到按钮**
     * ══════════════════════════════════════════════════════════════════
     *
     * # Owner 原话（逐字）
     * ```text
     * > 然后命名空间很多,侧边又不是没空间了,为什么不居中,请修复,
     * > 除了太侧边的没空间富裕的,可以不居中,其他都应该居中显示
     * ```
     * （「命名空间」是打字错误，本意是「明明左右空间很充裕、
     *   面板却没居中」。）
     *
     * # ★★ 基准点 = **按钮中心**，不是屏幕中心（Owner 复核后澄清）
     * ```text
     * 我上一版按字面理解做成了「居中于播放器/屏幕」——
     * Owner 看完截图明确纠正：「居中于**按钮**（贴近但避开边缘）」。
     * ⇒ 基准从 `size.width / 2` 换成 `a.center.dx`。
     *   两者在按钮本身就在屏幕中间时结果相同，但底栏按钮多在左侧，
     *   差别很大（屏幕居中会让面板离按钮很远）。
     * ```
     *
     * # 规则
     * ```text
     * ① 面板中心 = 按钮中心（`a.center.dx - childSize.width / 2`）
     * ② 这个位置放不下（贴边 / 窄屏）⇒ clamp 进 `[minLeft, maxLeft]`
     *    —— 正是 Owner 说的「太侧边的没空间富裕的,可以不居中」
     * ③ 锚点还没登记 ⇒ 退回宿主给的右下角基准（并 clamp）
     * ```
     *
     * # 为什么是**所有** popover 共用的通用规则（而不是只给清晰度）
     * ```text
     * · 定位逻辑就在这一个 delegate 里，五个 popover（倍速/清晰度/字幕/弹幕/更多）
     *   共用它 ⇒ 改成通用规则是**顺带**的，不需要任何按 id 的分支。
     * · Owner 的措辞是通用规则（「其他都应该居中显示」），且面板都是同一种
     *   小卡片形态 ⇒ 一致比「只有清晰度居中、别的贴按钮」更不割裂。
     * ★ 这一点由 `test/t26_w5_popover_anchor_reposition_test.dart` 与
     *   `test/zz_cr_speed_dup_anchor_test.dart` 钉住。
     * ```
     *
     * ⚠️ 竖向**不动**：Owner 只说了横向。底边仍贴按钮上沿上方 Sp.x2
     *    （由宿主的 `bottom: 96` 保证），否则面板会跑到屏幕顶上去。
     */
    final a = anchor;
    double left;
    if (a != null) {
      // ① 面板中心对齐按钮中心（Owner 要的形态）
      left = a.center.dx - childSize.width / 2;
      // ② 贴边放不下 ⇒ 往中间挪（clamp）
      if (left > maxLeft) left = maxLeft;
      if (left < minLeft) left = minLeft;
    } else {
      // 锚点还没登记（面板先于按钮挂载的那一帧）⇒ 沿用宿主给的右下角基准
      left = fallback.dx;
      if (left > maxLeft) left = maxLeft;
      if (left < minLeft) left = minLeft;
    }

    // 底边贴按钮上沿上方 Sp.x2（按钮被安全区抬高时跟着抬）
    final desiredBottom = a == null ? size.height - spacing : a.top - spacing;
    var top = fallback.dy - (size.height - spacing - desiredBottom);
    final maxTop = size.height - spacing - childSize.height;
    if (top > maxTop) top = maxTop;
    // 上沿还要让开状态栏 / 刘海（viewPadding 在无安全区时是 0）
    final minTop = viewPadding.top + spacing;
    if (top < minTop) top = minTop;

    return Offset(left, top);
  }

  /// ★ 必须**恒为 true**，不能逐字段比较！
  ///
  /// 面板收起时 body 是 `SizedBox.shrink()` ⇒ 布局盒当时是按 childSize
  /// (0,0) 算出位置的；面板展开后 delegate 的四个字段**一个都没变**
  /// （anchorKey 在面板未展开时本来就是 null），逐字段比较会返回 false ⇒
  /// 渲染对象认为不需要重新布局，面板就带着「按 0×0 算出来的旧偏移」被画出去。
  /// 实测（修复前）：面板画在 Rect.fromLTRB(1384, 796, 1552, 1017) ——
  /// 正是 `size - spacing - 0`，一半在窗口外，点不到。
  /// 这里返回 true 只是「内容换了就必须重算位置」，代价是子件重新布局一次
  /// （只有一个子件，且只在 build 出新的 delegate 时才触发），可以忽略。
  @override
  bool shouldRelayout(covariant _PopoverAnchorDelegate old) =>
      old.anchor != anchor ||
      old.viewport != viewport ||
      old.viewPadding != viewPadding ||
      old.spacing != spacing;
}

/// 底栏图标按钮（深色系，不读主题）
class _BarIconButton extends StatelessWidget {
  const _BarIconButton({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onTap,
    this.enabled = true,
    this.active = false,
    this.big = false,
  });

  final IconData icon;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool enabled;
  final bool active;
  final bool big;

  @override
  Widget build(BuildContext context) => IconButton(
    onPressed: enabled ? onTap : null,
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    icon: Icon(
      icon,
      size: big ? 30 : 20,
      color: !enabled
          ? Colors.white24
          : (active ? const Color(0xFF32C7FF) : Colors.white),
    ),
  );
}

/// 带下划文字的入口（选集 / 清晰度 / 弹幕 / 更多）
///
/// ★ CR-18：[label] 现在可以是 **null** —— 「字幕与音轨」只有图标 +
///   `popoverId`（底栏横向空间有限，不给它排文字），但它同样需要
///   「点击 / 悬停 → 控制器切换 → 弹层开合」的完整接线。
class _PopoverButton extends StatelessWidget {
  const _PopoverButton({
    super.key,
    required this.controller,
    required this.id,
    required this.icon,
    this.label,
    this.tooltip,
    this.active = false,
    this.onTap,
  });

  final PopoverController controller;
  final String id;
  final IconData icon;
  final String? label;
  final String? tooltip;
  final bool active;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final color = active ? const Color(0xFF32C7FF) : Colors.white;
    final child = Padding(
      padding: const EdgeInsets.symmetric(horizontal: Sp.x1, vertical: Sp.x1),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: color),
          if (label != null) ...[
            const SizedBox(width: Sp.x1),
            Text(
              label!,
              style: TextStyle(color: color, fontSize: FontSizes.sm),
            ),
          ],
        ],
      ),
    );
    final button = TextButton(
      onPressed: onTap ?? () => controller.toggle(id),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        padding: const EdgeInsets.symmetric(horizontal: Sp.x1),
      ),
      child: child,
    );
    // 有 popover 的入口才包一层悬停展开；纯动作按钮不包（悬停开一个空面板很怪）
    if (onTap != null || id.isEmpty) return button;
    return PopoverAnchorButton(
      controller: controller,
      id: id,
      tooltip: tooltip,
      child: button,
    );
  }
}

/// 音量：静音键 + 滑杆
class _VolumeControl extends StatelessWidget {
  const _VolumeControl({
    required this.muted,
    required this.volume,
    required this.onToggleMute,
    required this.onVolume,
    required this.compact,
  });

  final bool muted;
  final double volume;
  final VoidCallback onToggleMute;
  final ValueChanged<double> onVolume;
  final bool compact;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      _BarIconButton(
        icon: muted || volume == 0
            ? Icons.volume_off
            : (volume < 50 ? Icons.volume_down : Icons.volume_up),
        tooltip: '静音',
        onTap: onToggleMute,
      ),
      if (!compact)
        SizedBox(
          width: 72,
          child: Slider(
            value: muted ? 0 : volume,
            max: 100,
            onChanged: onVolume,
          ),
        ),
    ],
  );
}

/// 画面缩放滑条（从旧 `_ZoomSliderCard` 平移过来，形态不变）
class PlayerZoomSliderCard extends StatelessWidget {
  const PlayerZoomSliderCard({
    super.key,
    required this.zoom,
    required this.onChanged,
    required this.onDone,
    required this.onClose,
  });

  final double zoom;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onDone;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) => Container(
    margin: const EdgeInsets.only(bottom: Sp.x2),
    padding: const EdgeInsets.symmetric(horizontal: Sp.x3, vertical: Sp.x1),
    decoration: BoxDecoration(
      color: Colors.black.withValues(alpha: 0.85),
      borderRadius: Radii.rSm,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          '画面缩放',
          style: TextStyle(color: Colors.white, fontSize: FontSizes.cap),
        ),
        Expanded(
          child: Slider(
            value: zoom.clamp(50.0, 200.0),
            min: 50,
            max: 200,
            onChanged: onChanged,
            onChangeEnd: onDone,
          ),
        ),
        Text(
          '${zoom.round()}%',
          style: const TextStyle(color: Colors.white, fontSize: FontSizes.cap),
        ),
        IconButton(
          onPressed: onClose,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.close, size: 16, color: Colors.white),
          tooltip: '关闭',
        ),
      ],
    ),
  );
}

/// 进度条上那段「已缓冲」的区间
///
/// ⚠️ 与 `player_page.dart` 里那个同名类是**两个类型**（那边的是 nullable
///   的读数快照，这边只要能画的两端）—— 转换在宿主的调用点做一次。
class PlayerBufferedRange {
  const PlayerBufferedRange({required this.start, required this.end});

  final Duration start;
  final Duration end;
}

/// 进度条 —— 拖动 = seek
///
/// # ★ T27-02：白色定位点（thumb）
///
/// 业主原话：「2.进度条这里的白色那个定位的没了」（fig2 996x49 全带扫描
/// 无 >200 亮块 ⇒ 不是被盖住，是从来没画）。thumb 与已播进度走**同一份**
/// `pos/total` 比例、同一条 `ValueListenableBuilder<Duration>` 重建路径
/// （`_progressRow`），position 一变 thumb 同步走到新位置；seek 时
/// 播放器把真实位置写回 notifier，视觉上即「拖到哪、点停在哪」。
class PlayerProgressSlider extends StatelessWidget {
  /// thumb 直径：轨道高 2px，圆点上下各溢出 5px（Stack 高 18 够放）
  static const double thumbDiameter = 12;

  /// thumb 颜色：与已播进度同色系但更亮 —— 完全不透明白，fig2 场景下
  /// 对近黑底是最高对比（业主找的就是这枚白点）
  static const Color thumbColor = Colors.white;

  /// 门禁/测试用 key（test/t27_w2_progress_thumb_test.dart 按 id 对齐）
  static const Key thumbKey = ValueKey<String>('t27-progress-thumb');

  const PlayerProgressSlider({
    required this.position,
    required this.duration,
    required this.onSeek,
    this.buffered,
    this.barKey,
  });

  final Duration position;
  final Duration duration;
  final ValueChanged<Duration> onSeek;
  final PlayerBufferedRange? buffered;
  final Key? barKey;

  @override
  Widget build(BuildContext context) {
    final totalMs = duration.inMilliseconds;
    final total = totalMs <= 0 ? 1.0 : totalMs.toDouble();
    final pos = position.inMilliseconds.toDouble().clamp(0.0, total);
    return LayoutBuilder(
      builder: (context, c) {
        final w = c.maxWidth <= 0 ? 1.0 : c.maxWidth;
        /*
         * ══════════════════════════════════════════════════════════════════
         * ★★★ Owner 1011 反馈②：thumb 在**两端被截掉半个**
         * ══════════════════════════════════════════════════════════════════
         *
         * # Owner 原话（逐字）
         * ```text
         * > 进度条那个圆圈在初始阶段被截掉了半个
         * ```
         *
         * # 根因：thumb 中心跑到了 Stack 边界上/外，而 Stack **默认裁剪**
         * ```text
         * 旧写法：left = (pos/total)*w - thumbDiameter/2
         *   pos = 0  ⇒ left = -6   ⇒ 圆的左半边在 Stack 左边界外
         *   pos = 满 ⇒ left = w-6  ⇒ 圆的右半边在 Stack 右边界外
         * 而 Stack 的 clipBehavior 默认 = Clip.hardEdge
         * ⇒ 两端的圆都被**裁成半圆**（Owner 在初始位置看到的就是这个）。
         * ```
         *
         * # 修法：把行进区间**内缩一个半径**（滑杆的标准几何）
         * ```text
         * 轨道与 thumb 都只在 [r, w-r] 这段里排布：
         *   圆的**中心**最左只能到 r、最右只能到 w-r
         *   ⇒ 圆的左端 = r - r = 0，右端 = (w-r) + r = w ⇒ **始终完整可见**。
         * ```
         * ★ 关键：`trackW` 与**坐标映射**必须一起用这段内缩区间，
         *   否则「看得见的圆点位置」与「点下去跳到的位置」会差一个半径
         *   （拖动时圆点会比手指偏 6px —— 那正是这类改动最常见的次生缺陷）。
         */
        const double r = thumbDiameter / 2;
        final trackW = (w - thumbDiameter) <= 0 ? 1.0 : w - thumbDiameter;
        /// 比例 → **圆点中心**的 x（内缩区间内）
        double centerX(double ratio) => r + ratio * trackW;
        /// **圆点中心**的 x → 比例（与 centerX 严格互逆）
        double ratioAt(double dx) => (dx - r) / trackW;
        Duration at(double dx) =>
            Duration(milliseconds: (ratioAt(dx).clamp(0.0, 1.0) * total).round());
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => onSeek(at(d.localPosition.dx)),
          onHorizontalDragUpdate: (d) => onSeek(at(d.localPosition.dx)),
          child: SizedBox(
            height: 18,
            child: Stack(
              children: [
                Positioned(
                  left: r,
                  width: trackW,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    decoration: BoxDecoration(
                      color: Colors.white24,
                      borderRadius: Radii.rSm,
                    ),
                  ),
                ),
                // 缓冲条：起点 → 终点，用像素而不是 FractionallySizedBox
                // （后者在 start > 0 时算出的偏移会随宽度漂）
                if (buffered != null)
                  Positioned(
                    left: centerX(
                      buffered!.start.inMilliseconds.toDouble().clamp(
                            0.0,
                            total,
                          ) /
                          total,
                    ),
                    width:
                        ((buffered!.end.inMilliseconds.toDouble() -
                                    buffered!.start.inMilliseconds.toDouble())
                                .clamp(0.0, total) /
                            total) *
                        trackW,
                    top: 8,
                    bottom: 8,
                    child: Container(
                      decoration: BoxDecoration(
                        color: Colors.white38,
                        borderRadius: Radii.rSm,
                      ),
                    ),
                  ),
                // 已播进度：从轨道左端画到 thumb 中心
                Positioned(
                  left: r,
                  width: (pos / total) * trackW,
                  top: 8,
                  bottom: 8,
                  child: Container(
                    key: barKey,
                    decoration: BoxDecoration(
                      color: const Color(0xFF32C7FF),
                      borderRadius: Radii.rSm,
                    ),
                  ),
                ),
                // ★ T27-02 补画定位点：中心 = centerX(pos/total)（内缩区间内，
                // 两端都留了一个半径 ⇒ 不再被 Stack 裁掉）。
                Positioned(
                  key: thumbKey,
                  left: centerX(pos / total) - r,
                  top: (18 - thumbDiameter) / 2,
                  child: GestureDetector(
                    // ★ 纯视觉件：裸 DecoratedBox（RenderProxyBox、
                    //   hitTestSelf=false）不会进命中路径，门禁就没法在
                    //   (thumbX, centerY) 定位到它。translucent 只保证
                    //   hitTest 命中自身、返回 false 不挡下层，拖/点 seek
                    //   仍由整条进度条的 GestureDetector 统一处理（坐标
                    //   映射只有一份，拇指不重复注册手势）。
                    behavior: HitTestBehavior.translucent,
                    child: const DecoratedBox(
                      decoration: BoxDecoration(
                        color: thumbColor,
                        shape: BoxShape.circle,
                      ),
                      child: SizedBox(
                        width: thumbDiameter,
                        height: thumbDiameter,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
