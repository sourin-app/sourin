// ═══════════════════════════════════════════════════════════════════════
//  R4 弹窗统一外壳 —— **真机像素验收**探针（第 66 轮 · r4-device）
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么问题
// ```text
// R4 把 `AlertDialog` 换成了自建外壳（`AppGlassDialog`）。而
// `MaterialLocalizations` / `Material` 祖先 / `DefaultTextStyle` 这三类问题
// **只在真机暴露** —— `flutter test` 里可能全绿（第 66 轮 4131 个用例
// 一个都没抓到 `MaterialLocalizations.of` 的 null check 崩溃，见 AGENTS §8）。
// ⇒ 必须有一份**真机 + 真实产品根 + 真实渲染管线**的取证。
// ```
//
// # 取证手段（按 docs/AGENTS.md §8 第 ① 条，**不用屏幕截图**）
// ```text
// ❌ CopyFromScreen —— 抓的是屏幕像素，会把 Owner 桌面拍进 .probe/（2026-10-18 事故）
// ❌ PrintWindow    —— 对 Flutter 常返回 1×1 / 纯黑（§8 原文）
// ✅ 本文件：`RenderRepaintBoundary.toImage()`，在**进程内**光栅化
//    （与产品自带的 `SOURIN_SHOT=1` 同一条链路，见 shell.dart:8517）
//    ⇒ 写进 .probe/ 的 png **一定是产品自身的渲染结果**。
// ```
//
// # ★★★ 为什么不是「在探针里搭一个 MaterialApp」
// ```text
// 那样测的是**探针的根**，不是产品的根。R4 的故障点恰恰在「根上有没有
// 提供 MaterialLocalizations / Material 祖先」这一层：
//   产品的根是 `SourinApp`（内部 `WidgetsApp` + `_AnyLocaleMaterialDelegate()`
//   + GlobalWidgets/Cupertino delegates，见 shell.dart:1941 / :2151），
//   **不是** `MaterialApp`（R7 已把 MaterialApp 彻底去掉，真实调用 0 处）。
// ⇒ 本探针直接 `runApp(RepaintBoundary(child: SourinApp()))` ——
//   用的是**产品自己的根**，一个字段都不复刻。
//   弹窗也走**产品自己的入口** `showAppDialog` + 产品自己的 `navigatorKey`
//   （`AppTray.navigatorKey`），与 app_tray.dart:241 那条真实调用点同一个 context。
// ```
//
// # 每个框取证的 4 件事
// ```text
// ① 渲染异常收集器 —— `FlutterError.onError` 全量收；**出现任何异常 ⇒ 整条验收作废**
//    （`RenderFlex overflowed` 也走这里，所以「文字/按钮挤出卡片」抓得到）
// ② 卡片几何 —— 从渲染树读 `AppGlassDialog` / `AlertDialog` 的 RenderBox rect
//    （不是"看起来差不多"，是精确 w/h/left/top）
// ③ 像素事实 —— 同一帧 `toImage()` 出的 RGBA：
//    卡片底色 hex / 圆角拐角剖面 / 文字墨迹 bbox（判「不裁切」）/
//    颜色种数（判「不是空白」）/ 最大亮度（判「不是纯黑」）/ 卡片占屏比（判「不是全屏遮罩」）
// ④ 缩略图 —— 卡片区域 2× 裁切另存 `card_<id>.png`，给人眼看细节
// ```
//
// # 用法（**必须**带隔离数据目录，否则本程序拒绝启动）
// ```powershell
// flutter build windows --release -t lib/t105_r4_dialogs_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\WishProject\sourin-flutter-spike\.probe\round66_r4_device\data"
// # 外层再把 APPDATA / USERPROFILE 指进同一个隔离目录（AGENTS §8「收尾必做」配方），
// # 然后直接跑 build\windows\x64\runner\Release\sourin_spike.exe
// ```
// 产物：`.probe/round66_r4_device/*.png` + `probe.log`（本文件自己写，不依赖控制台）
//
// ⚠️ 本探针**不改产品代码、不写用户真实数据目录**：数据目录解析结果必须落在
//    `.probe/round66_r4_device` 下，否则 `exit(3)` 什么都不做。
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart'
    show GestureBinding, PointerAddedEvent, PointerDownEvent, PointerUpEvent;
import 'package:flutter/rendering.dart' show RenderBox, RenderRepaintBoundary;
import 'package:flutter/widgets.dart';
// 只为**类型判据**（`is AlertDialog`）——本文件不构造任何 Material 弹窗，
// 豁免对照那两个框由产品自己的页面点出来（见 case 09 的注释）。
import 'package:material_ui/material_ui.dart' show AlertDialog;
import 'package:window_manager/window_manager.dart';

import 'core/app_tray.dart' show AppTray, CloseAction;
import 'core/clip_download.dart' show ClipDownloader;
import 'core/ffi.dart' show SourinCore;
import 'core/ui_prefs.dart' show UiPrefs;
import 'design/widgets/app_glass_dialog.dart';
import 'design/widgets/app_text_button.dart';
import 'shell.dart' show SourinApp;
// 豁免对照要驱动**真实页面**（真实 AlertDialog 由产品代码自己 show）
import 'ui/settings/theme_page.dart' show ThemeSettingsPage;
import 'ui/tokens.dart' show Radii;
import 'ui/widgets/app_dialog_shell.dart' show AppDialogShell;
import 'ui/widgets/overlay_motion.dart' show showAppDialog;

// ═══════════════════════════════════════════════════════════════════════
//  日志 / 计数
// ═══════════════════════════════════════════════════════════════════════

/// 产物目录（`main()` 里定），日志与 png 都写这里
late Directory _outDir;

/// 日志文件 —— **不依赖控制台**：release 的 windows runner 是 GUI 子系统，
/// 从 PowerShell 直接起进程时 stdout 不一定接到父控制台上。
/// ⇒ 外层脚本一律读这个文件，不读 stdout。
File? _logFile;

/// 产物文件名前缀（`SOURIN_T105_PREFIX`，例如 `fix0_` / `fix1_`）——
/// 让「修前/修后」两轮图共存、互不覆盖，且不用重编 exe。
String _prefix = '';

/// 渲染异常收集器（`FlutterError.onError`）
final List<String> _errs = <String>[];

/// 当前正在取证的框（给异常打归属用）
String _currentCase = '-';

/// 统计
int _nCase = 0;
int _nOk = 0;
int _nBad = 0;

void _say(String s) {
  final line = '[T105] $s';
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  debugPrint('$ts $line');
  try {
    _logFile?.writeAsStringSync('$ts $line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // 日志写不进去不该让探针挂掉（但下面会体现在产物缺失上）
  }
}

void _ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    _nOk++;
    _say('  ✓ $label${extra.isEmpty ? '' : '  $extra'}');
  } else {
    _nBad++;
    _say('  ✗ $label${extra.isEmpty ? '' : '  $extra'}');
  }
}

void _bad(String msg) {
  _nBad++;
  _say('  ✗ $msg');
}

// ═══════════════════════════════════════════════════════════════════════
//  根上的自拍 key（与 shell.dart:8230 的 `_probeShotKey` 同一条链路）
// ═══════════════════════════════════════════════════════════════════════

final GlobalKey _shotKey = GlobalKey();

// ═══════════════════════════════════════════════════════════════════════
//  像素工具
// ═══════════════════════════════════════════════════════════════════════

class _Pix {
  _Pix(this.w, this.h, this.b);

  final int w;
  final int h;

  /// RGBA8888，行优先
  final Uint8List b;

  int idx(int x, int y) => (y * w + x) * 4;

  (int, int, int) rgb(int x, int y) {
    final i = idx(x, y);
    return (b[i], b[i + 1], b[i + 2]);
  }

  int lum(int x, int y) {
    final c = rgb(x, y);
    return (c.$1 * 299 + c.$2 * 587 + c.$3 * 114) ~/ 1000;
  }

  String hex(int x, int y) {
    final c = rgb(x, y);
    String p(int v) => v.toRadixString(16).padLeft(2, '0');
    return '#${p(c.$1)}${p(c.$2)}${p(c.$3)}';
  }

  /// 两点 RGB 的最大通道差
  int diff(int x1, int y1, int x2, int y2) {
    final a = rgb(x1, y1);
    final c = rgb(x2, y2);
    return [
      (a.$1 - c.$1).abs(),
      (a.$2 - c.$2).abs(),
      (a.$3 - c.$3).abs(),
    ].reduce((x, y) => x > y ? x : y);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  探针用例
// ═══════════════════════════════════════════════════════════════════════

class _Case {
  const _Case(
    this.id,
    this.src,
    this.note, {
    this.build,
    this.trigger,
    this.cleanup,
    this.expectWidth,
    this.narrow = false,
    this.isShell = false,
  });

  /// 产物文件名（也是日志里的标签）
  final String id;

  /// 被复刻的真实调用点（源码位置）
  final String src;

  /// 人读说明
  final String note;

  /// 内容构造（复刻真实 builder）
  final Widget Function(BuildContext)? build;

  /// 真实触发（不复刻 builder，直接调产品代码）
  final Future<void> Function()? trigger;

  /// 收尾（例如把触发时 push 的真实页面 pop 掉）
  final Future<void> Function()? cleanup;

  /// 期望卡片宽度（null = 只报不判）
  final double? expectWidth;

  /// 这一档在窄视口（800×600）下跑，额外判「四边不贴边」
  final bool narrow;

  /// 是否 R4 收拢后的 `AppGlassDialog`（true）/ 豁免的 Material `AlertDialog`（false）
  final bool isShell;

  @override
  String toString() => '$id ← $src';
}

/// `AppGlassDialogActions` 逐字复刻（两键：取消 / 确认）
AppGlassDialogActions _acts({
  required String confirmLabel,
  bool destructive = false,
  String cancelLabel = '取消',
}) =>
    AppGlassDialogActions(
      cancelLabel: cancelLabel,
      confirmLabel: confirmLabel,
      confirmIsDestructive: destructive,
      onCancel: () => AppTray.navigatorKey.currentState?.pop(false),
      onConfirm: () => AppTray.navigatorKey.currentState?.pop(true),
    );

/// `skip_page.dart:295 _confirm()` 的逐字复刻（含 `cancelLabel == null` 档）
Widget _skipConfirm({
  required String title,
  required String message,
  String okLabel = '确定',
  String? cancelLabel = '取消',
}) =>
    AppGlassDialog(
      title: title,
      content: Text(message),
      actions: cancelLabel == null
          ? AppTextButton(
              onPressed: () => AppTray.navigatorKey.currentState?.pop(true),
              child: Text(okLabel),
            )
          : AppGlassDialogActions(
              cancelLabel: cancelLabel,
              confirmLabel: okLabel,
              confirmIsDestructive: false,
              onCancel: () => AppTray.navigatorKey.currentState?.pop(false),
              onConfirm: () => AppTray.navigatorKey.currentState?.pop(true),
            ),
    );

/// `sync_panel.dart:645 _confirm()` 的逐字复刻（含 `cancelLabel == null` 档）
Widget _syncConfirm({
  required String title,
  required String message,
  String okLabel = '确定',
  String? cancelLabel = '取消',
}) =>
    _skipConfirm(
      title: title,
      message: message,
      okLabel: okLabel,
      cancelLabel: cancelLabel,
    );

List<_Case> _cases() => <_Case>[
      // ── ① 托盘关闭三键框：**真实触发**，不复刻任何 builder ──────────
      _Case(
        '01_tray_close',
        'lib/core/app_tray.dart:241（真实调用 AppTray.instance.onWindowClose）',
        '托盘关闭三键框（最小化到托盘 / 彻底退出 / 取消）',
        trigger: () async => AppTray.instance.onWindowClose(),
        expectWidth: 380,
        isShell: true,
      ),
      // ── ② 缓存「删除整部？」─────────────────────────────────────
      _Case(
        '02_cache_delete',
        'lib/ui/cache_page.dart:1878',
        '缓存页删除整部',
        expectWidth: 380,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '删除整部？',
          content: const Text(
            '「三体（2023）」\n'
            '将删除 12 集 / 共 8.4 GB。\n'
            '文件会从磁盘上真正删除，此操作不可恢复。',
          ),
          actions: _acts(confirmLabel: '删除'),
        ),
      ),
      // ── ③ 设置·清理数据 ────────────────────────────────────────
      _Case(
        '03_data_manage_clear',
        'lib/ui/settings/data_manage_page.dart:195',
        '设置·数据管理清理分类',
        expectWidth: 380,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '清理「图片缓存」',
          content: const Text(
            '将删除 128 项，释放 316.0 MB。\n\n'
            '海报 / 剧照的本地缓存，删掉后滚动时会重新下载。\n\n此操作不可撤销。',
          ),
          actions: _acts(confirmLabel: '清理'),
        ),
      ),
      // ── ④ 设置·删除源 ──────────────────────────────────────────
      _Case(
        '04_emby_delete_source',
        'lib/ui/settings/emby_page.dart:643',
        '设置·Emby 删除源',
        expectWidth: 380,
        isShell: true,
        build: (_) => AppGlassDialog(
          title: '删除源「客厅 Emby」？',
          content: const Text(
            '会删掉插件文件 emby.js，这个源会从首页源栏消失。\n\n'
            '它的配置与登录凭据（plugins/.data/emby-live.json）不会被删 —— '
            '以后用同一个 id 再装回来，地址和账号还在。',
          ),
          actions: _acts(confirmLabel: '删除'),
        ),
      ),
      // ── ⑤ 跳过点确认（cancelLabel != null）────────────────────
      _Case(
        '05_skip_confirm_2btn',
        'lib/ui/settings/skip_page.dart:301 + 调用点 :233',
        '跳过点清除确认（两键）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _skipConfirm(
          title: '清除片头片尾',
          message: '确定清除「三体（2023）」的片头片尾设置吗？\n\n'
              '清除后播放这个作品时不再自动跳过。此操作无法撤销。',
          okLabel: '清除',
        ),
      ),
      // ── ⑥ 跳过点确认（cancelLabel == null 档）─────────────────
      // 注：产品当前**没有**调用点传 cancelLabel: null（全仓 grep 只有
      // settings_page.dart:2207 是另一个 helper）⇒ 本条是**分支构造档**，
      // 只为把这一档的画法验一遍；标题自带「构造档」字样，避免被当成产品文案。
      _Case(
        '06_skip_confirm_1btn',
        'lib/ui/settings/skip_page.dart:301 `_confirm()` 的 `cancelLabel == null`'
            ' 分支（无真实调用点 ⇒ 构造档）',
        '跳过点确认 —— 只画一个确认钮的那一档（构造）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _skipConfirm(
          title: '（构造档）单键确认',
          message: '这一档只画一个确认按钮。\n\n'
              '产品里 skip_page / sync_panel 的 _confirm() 目前都传了 cancelLabel，'
              '所以这一档是探针造出来验分支的。',
          okLabel: '知道了',
          cancelLabel: null,
        ),
      ),
      // ── ⑦ 同步面板确认（两键）─────────────────────────────────
      _Case(
        '07_sync_confirm_2btn',
        'lib/ui/widgets/sync_panel.dart:651 + 调用点 :370',
        '云同步删除云端备份确认（两键）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _syncConfirm(
          title: '删除云端备份',
          message: '确定删掉云端的这一份备份吗？\n\n'
              'sourin-backup-20261019-2155.zip\n\n'
              '⚠️ 云盘上的删除一般不进回收站，删了就找不回来了。',
          okLabel: '删除',
        ),
      ),
      // ── ⑧ 同步面板确认（cancelLabel == null 档）───────────────
      // 同 ⑥：这一档产品里没有调用点 ⇒ 构造档。
      _Case(
        '08_sync_confirm_1btn',
        'lib/ui/widgets/sync_panel.dart:645 `_confirm()` 的 `cancelLabel == null`'
            ' 分支（无真实调用点 ⇒ 构造档）',
        '同步面板确认 —— 只画一个确认钮的那一档（构造）',
        expectWidth: 380,
        isShell: true,
        build: (_) => _syncConfirm(
          title: '（构造档）单键确认',
          message: '这一档只画一个确认按钮。\n\n'
              'sync_panel 里三个调用点都能取消，所以这一档靠探针构造。',
          cancelLabel: null,
        ),
      ),
      // ── ⑨ 豁免对照：theme_page 的 AlertDialog —— **真触发**，不复制控件 ──
      //
      // ```text
      // 做法：push 产品自己的 ThemeSettingsPage（真实页面类），
      //       在**进程内**用 GestureBinding 合成一次 tap 打在它真实的
      //       「粘贴 JSON」按钮上（不是 SetCursorPos / 鼠标事件 / 抢焦点）。
      //       ⇒ 弹出的是 `_pasteJson()` 里那个真实的 AlertDialog。
      // ```
      _Case(
        '09_exempt_theme_paste_json',
        'lib/ui/settings/theme_page.dart:269（真实路径：ThemeSettingsPage →'
            ' tap「粘贴 JSON」→ _pasteJson）',
        '豁免对照 —— 主题包 JSON 粘贴窗（产品自己的 Material AlertDialog）',
        isShell: false,
        trigger: () async {
          _pushRealPage(const ThemeSettingsPage());
          await _settle(frames: 2, ms: 600);
          final hit = await _tapByText('粘贴 JSON');
          if (!hit) throw StateError('真实页面里找不到「粘贴 JSON」按钮');
          await _settle(frames: 2, ms: 700);
        },
        cleanup: () async {
          AppTray.navigatorKey.currentState?.maybePop();
          await _settle(frames: 1, ms: 400);
        },
      ),
      // ── ⑩ 豁免对照 B：backup_panel —— **无法真机取证**（已删掉复制品）──
      //
      // ```text
      // 为什么无法取证（代码依据，不是推测）：
      //   backup_panel.dart:460  `_exportConsent()` 是**私有方法**，探针调不到；
      //   它唯一的调用入口是「导出备份」按钮 → 该按钮前面要求**本机已有登录态**：
      //     backup_panel.dart:535-540「本机没有登录态 ⇒ 直接走」
      //   ⇒ 隔离数据目录里没有凭据（也不能为它伪造登录，那是另一条假证据），
      //     这个 AlertDialog 在真机上根本弹不出来。
      // ⇒ 如实登记为「未取证」，见 docs/notes/round-66-r4-device.md。
      // ```

      // ── ⑩ 窄视口复核：800×600 ────────────────────────────────────
      //
      // ```text
      // 「小屏贴边/被裁」是 §3.5「最大高度 620 再按视口夹取」的下半句；
      // 1280×800 看不出问题，所以把窗口缩到 800×600 再弹同一个框。
      // 判据：卡片四边都不贴边（>2px）。满屏折叠时这条必红。
      // ```
      _Case(
        '10_narrow800x600_tray_close',
        'lib/core/app_tray.dart:241（同 01，只是视口换成 800×600）',
        '窄视口复核 —— 托盘三键框在 800×600 下不贴边',
        narrow: true,
        isShell: true,
        trigger: () async => AppTray.instance.onWindowClose(),
      ),
      // ── ⑪ AppDialogShell 的**玻璃档**圆角（r4-finish 把内层
      //      `LiquidRoundedRectangle` 20 → `Radii.lg`，无像素证据）──
      //
      // ```text
      // 为什么是组件级直渲、不是驱动某个产品弹窗：
      //   全仓 `glass: true` 只有一处 —— danmaku_settings_dialog.dart:1654
      //   「弹幕设置」，它要**活的播放器控制器**才打得开（隔离数据目录里没有
      //   可播视频）⇒ 真机上是打不出来的。这里直接渲染**产品自己的**
      //   AppDialogShell(glass: true)，走的就是那一行的同一个构造成员与同一段
      //   外壳代码（不是复刻、不是自造控件），只为量圆角与几何。
      //   ⚠️ 结论只覆盖「外壳玻璃档的轮廓」，不覆盖弹幕设置面板的内容排版。
      // ```
      _Case(
        '11_shell_glass_corner',
        'lib/ui/widgets/app_dialog_shell.dart:377 `LiquidRoundedRectangle('
            'borderRadius: Radii.lg)`（玻璃档，产品里仅 danmaku_settings_dialog'
            '.dart:1654 使用）',
        'AppDialogShell 玻璃档 —— 量圆角是否是 Radii.lg(22)',
        isShell: true,
        build: (_) => AppDialogShell(
          title: '弹窗外壳 · 玻璃档',
          subtitle: '轮廓取样：圆角应为 Radii.lg（22）',
          glass: true,
          width: 460,
          scrollable: false,
          onClose: () => AppTray.navigatorKey.currentState?.pop(),
          child: const Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, 16),
            child: Text(
              '这张卡片由产品自己的 AppDialogShell(glass: true) 渲染。\n'
              '探针只读它的圆角拐角剖面与卡片 rect。',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    ];

// ═══════════════════════════════════════════════════════════════════════
//  同步节奏：为什么要「等帧 + sleep + 再等帧」
// ═══════════════════════════════════════════════════════════════════════
//
// ```text
// ① `endOfFrame` 只是「这一帧画完了」，**不含动效时间**。
//    `showAppDialog` 带 entrance 动效（overlaySheetAnimationStyle，~200ms）
//    ⇒ 弹完立刻抓会抓到「卡片还在放大 / 半透明」的中间帧：
//      尺寸比 380 小、底色被 barrier 混过 ⇒ 读数全是错的。
// ② 单纯 `Future.delayed` 又不够：那一帧可能还没光栅化，
//    `toImage()` 会拿到上一帧的旧内容（列表页滚动中就吃过这个）。
// ③ 所以顺序是：endOfFrame → 等动效时长 → endOfFrame → 再等一小段 → endOfFrame。
//    多等的那一小段是给「动效结束那一帧的 raster」落地用的。
// ⇒ 本探针统一 `_settle()`：3 帧 + 450ms，和 t104 探针里的节奏同一思路。
// ```
Future<void> _settle({int frames = 2, int ms = 450}) async {
  for (var i = 0; i < frames; i++) {
    await WidgetsBinding.instance.endOfFrame;
  }
  await Future<void>.delayed(Duration(milliseconds: ms));
  await WidgetsBinding.instance.endOfFrame;
}

/// 从**渲染树**读对话框卡片的精确 rect（不是靠颜色猜边界）
///
/// 为什么不能直接用 `AppGlassDialog` / `AlertDialog` 自己的 renderObject：
/// ```text
/// `showDialog(builder:)` 把 builder 的产物放进一个**满屏**的路由页面里，
/// 传给它的约束是 tight(整窗)。所以这两个组件的 renderObject 报回来的是
/// 「整窗 1280×760」，测出来永远是"全屏遮罩" —— 那是**测量错**，不是产品错。
/// ⇒ 玻璃卡片取 `GlassContainer`（产品自己的面板，尺寸=卡片）；
///   Material 弹窗取它内部第一块 `Material`（Dialog 的卡片本体）。
/// ```

/// 遮罩亮度：在卡片四周外 30px 取 8 点，返回中位数。
/// 不用 (4,4)——那是应用自定义标题栏，与遮罩无关。
int _barrierLum(_Pix p, int l, int t, int r, int b, int vw, int vh) {
  const gap = 30;
  final cy = (t + b) ~/ 2, cx0 = (l + r) ~/ 2;
  final cand = <(int, int)>[
    (cx0, t - gap), (cx0, b + gap), (l - gap, cy), (r + gap, cy),
    (l - gap, t - gap), (r + gap, t - gap), (l - gap, b + gap), (r + gap, b + gap),
  ];
  final lums = <int>[];
  for (final (x, y) in cand) {
    if (x < 2 || y < 2 || x >= vw - 2 || y >= vh - 2) continue;
    // 落在卡片内就跳过（窄窗下四周余量小，可能兜到卡上）
    if (x >= l && x <= r && y >= t && y <= b) continue;
    lums.add(p.lum(x, y));
  }
  if (lums.isEmpty) return -1;
  lums.sort();
  return lums[lums.length ~/ 2];
}

// ═══ 图像专用的「文本行 → 对比度」量具 ═══
// 不依赖渲染树 ⇒ 同一把尺子既能量当场渲染的帧，也能量**存档 PNG**
// （量具自检就是靠这一点：拿已知合格 / 已知坏的两张旧图复算）。

/// 卡片底色 = 全卡遍采样的众数色（每通道量化 5bit）。
(int, int, int) _cardBg(_Pix p, int l, int t, int r, int b) {
  final cnt = <int, int>{};
  final rep = <int, (int, int, int)>{};
  for (var y = t + 3; y < b - 3; y += 2) {
    for (var x = l + 3; x < r - 3; x += 2) {
      final c = p.rgb(x, y);
      final k = ((c.$1 >> 3) << 10) | ((c.$2 >> 3) << 5) | (c.$3 >> 3);
      cnt[k] = (cnt[k] ?? 0) + 1;
      rep[k] = c;
    }
  }
  var bestK = -1, bestN = -1;
  cnt.forEach((k, n) {
    if (n > bestN) {
      bestN = n;
      bestK = k;
    }
  });
  return bestK < 0 ? p.rgb(l + 4, t + (b - t) ~/ 2) : rep[bestK]!;
}

int _lumOf((int, int, int) c) => (c.$1 * 299 + c.$2 * 587 + c.$3 * 114) ~/ 1000;

/// 逐行数墨迹（与卡底色亮度差 > 40 的像素），连续行合成文本带。
List<({int y0, int y1, int ink})> _textBands(
    _Pix p, int l, int t, int r, int b, int bgL) {
  final bands = <({int y0, int y1, int ink})>[];
  var start = -1, ink = 0;
  for (var y = t + 2; y < b - 2; y++) {
    var n = 0;
    for (var x = l + 2; x < r - 2; x++) {
      if ((p.lum(x, y) - bgL).abs() > 40) n++;
    }
    if (n >= 3) {
      if (start < 0) {
        start = y;
        ink = 0;
      }
      ink += n;
    } else if (start >= 0) {
      if (y - start >= 4) bands.add((y0: start, y1: y, ink: ink));
      start = -1;
    }
  }
  if (start >= 0 && b - 2 - start >= 4) {
    bands.add((y0: start, y1: b - 2, ink: ink));
  }
  return bands;
}

/// 一行文本的对比度：文字色 = 带内离卡底色**最远**的那个像素（取真实 RGB）。
({(int, int, int) ink, double ratio, int y}) _bandContrast(
    _Pix p, int l, int r, int y0, int y1, (int, int, int) bg, int bgL) {
  var bestD = -1;
  var best = bg;
  var bestY = y0;
  for (var y = y0; y < y1; y++) {
    for (var x = l + 2; x < r - 2; x++) {
      final d = (p.lum(x, y) - bgL).abs();
      if (d > bestD) {
        bestD = d;
        best = p.rgb(x, y);
        bestY = y;
      }
    }
  }
  return (ink: best, ratio: _wcag(best, bg), y: bestY);
}

/// 对一张 _Pix 的卡片区域出一行 `CONTRAST|...` 读数。
/// title = 最上面那条文本带；body = 其余带里**墨迹最多的前 3 条**中比值最差的
/// 那条（Lead 要求「同一段正文多取几行、取最差的一行」，避免抽样走运）。
({double title, double body, String line, String note}) _contrastOfCard(
    _Pix p, int l, int t, int r, int b) {
  final bg = _cardBg(p, l, t, r, b);
  final bgL = _lumOf(bg);
  // 跳过卡片上沿 12px：那圈是玻璃**描边/高光/阴影**，不是文字
  // （2026-10-20 自检踩到：first band 落在 y15..37 读到的是边沿灰 #6A6B6E）。
  final bands = _textBands(p, l, t, r, b, bgL)
      .where((bd) => bd.y0 >= t + 12 && bd.y1 - bd.y0 >= 6)
      .toList();
  if (bands.length < 2) {
    return (
      title: -1,
      body: -1,
      line: 'CONTRAST|skipped|bands=${bands.length}|card=${_hx(bg)}',
      note: 'reason=卡内文本行带不足 2 条',
    );
  }
  final tb = bands.first;
  final tc = _bandContrast(p, l, r, tb.y0, tb.y1, bg, bgL);
  final rest = bands.skip(1).toList()..sort((a, b2) => b2.ink - a.ink);
  final cands = rest.take(3).toList();
  var worst = _bandContrast(p, l, r, cands.first.y0, cands.first.y1, bg, bgL);
  var worstBand = cands.first;
  for (final bd in cands.skip(1)) {
    final cc = _bandContrast(p, l, r, bd.y0, bd.y1, bg, bgL);
    if (cc.ratio < worst.ratio) {
      worst = cc;
      worstBand = bd;
    }
  }
  final ok = tc.ratio >= 4.5 && worst.ratio >= 4.5;
  return (
    title: tc.ratio,
    body: worst.ratio,
    line: 'CONTRAST|CASE|card=${_hx(bg)}|title=${_hx(tc.ink)}'
        '|titleRatio=${tc.ratio.toStringAsFixed(2)}|body=${_hx(worst.ink)}'
        '|bodyRatio=${worst.ratio.toStringAsFixed(2)}'
        '|verdict=${ok ? "OK" : "BAD"}',
    note: 'bands=${bands.length} titleBand=y${tb.y0}..${tb.y1}'
        ' bodyBand=y${worstBand.y0}..${worstBand.y1}(ink=${worstBand.ink})'
        '|阈值=4.5|底=全卡众数色|文字=带内离底最远像素(偏饱和，偏保守)',
  );
}

double _relLum((int, int, int) c) {
  double f(int v) {
    final s = v / 255.0;
    return s <= 0.04045 ? s / 12.92 : math.pow((s + 0.055) / 1.055, 2.4).toDouble();
  }

  return 0.2126 * f(c.$1) + 0.7152 * f(c.$2) + 0.0722 * f(c.$3);
}

/// WCAG 2.1 对比度：(L1+0.05)/(L2+0.05)，1.00 ~ 21.00
double _wcag((int, int, int) a, (int, int, int) b2) {
  final la = _relLum(a), lb = _relLum(b2);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

String _hx((int, int, int) c) {
  final s = '#${c.$1.toRadixString(16).padLeft(2, '0')}'
      '${c.$2.toRadixString(16).padLeft(2, '0')}'
      '${c.$3.toRadixString(16).padLeft(2, '0')}';
  return s.toUpperCase();
}

Rect? _dialogRect() {  Rect? rectOf(Element e) {
    final ro = e.renderObject;
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  double winW = 1280;
  final root = _shotKey.currentContext?.findRenderObject();
  if (root is RenderBox && root.hasSize) winW = root.size.width;

  Element? dialogEl;
  void findDialog(Element e) {
    if (dialogEl != null) return;
    final w = e.widget;
    if (w is AppGlassDialog || w is AlertDialog || w is AppDialogShell) {
      dialogEl = e;
      return;
    }
    e.visitChildElements(findDialog);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(findDialog);
  if (dialogEl == null) return null;

  Element? glass;
  Element? mat;
  void findPanel(Element e) {
    if (glass != null) return;
    final n = e.widget.runtimeType.toString();
    if (n == 'GlassContainer') {
      glass = e;
      return;
    }
    if (mat == null && n == 'Material') {
      final r = rectOf(e);
      // 排除"铺满整窗"的 Material（那不是卡片）
      if (r != null && r.width < winW * 0.985) mat = e;
    }
    e.visitChildElements(findPanel);
  }

  dialogEl!.visitChildElements(findPanel);

  final g = glass == null ? null : rectOf(glass!);
  if (g != null && g.width > 1 && g.height > 1) {
    _say('   rect源=GlassContainer（产品玻璃面板自身，非满屏路由）');
    return g;
  }
  final m = mat == null ? null : rectOf(mat!);
  if (m != null && m.width > 1 && m.height > 1) {
    _say('   rect源=Material（AlertDialog 卡片本体）');
    return m;
  }
  _say('   ⚠️ rect源=${dialogEl!.widget.runtimeType}（退回外壳根 ⇒ 可能是满屏）');
  return rectOf(dialogEl!);
}

/// 把**产品自己的页面**push 到真实 Navigator（不是自建弹窗）
void _pushRealPage(Widget page) {
  final nav = AppTray.navigatorKey.currentState;
  if (nav == null) throw StateError('navigator 还没就绪');
  nav.push(
    PageRouteBuilder<void>(
      pageBuilder: (_, __, ___) => page,
      transitionDuration: Duration.zero,
      reverseTransitionDuration: Duration.zero,
    ),
  );
}

/// 取某个 Text 的**全局矩形**（用于判「三键是不是同一行、有没有出卡片」）。
/// 只读渲染树，不点、不抢焦点。
Rect? _textGlobalRect(String text) {
  Element? hit;
  void visit(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  final ro = hit?.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

/// 进程内合成一次 tap —— **不碰** OS 光标 / 不抢焦点 / 不用 mouse_event。
/// 打在真实按钮上 ⇒ 走产品自己的 handler ⇒ 弹出产品自己 show 的弹窗。
Future<bool> _tapByText(String text) async {
  Element? hit;
  void visit(Element e) {
    if (hit != null) return;
    final w = e.widget;
    if (w is Text && w.data == text) {
      hit = e;
      return;
    }
    e.visitChildElements(visit);
  }

  WidgetsBinding.instance.rootElement?.visitChildElements(visit);
  if (hit == null) return false;

  // ① 先滚到可见（主题页的目标按钮在滚动区里，实测 y=1506 已经出了窗口）
  try {
    await Scrollable.ensureVisible(hit!, alignment: 0.5);
  } catch (_) {
    // 不在滚动区里就算了
  }
  await _settle(frames: 2, ms: 250);

  final ro = hit!.renderObject;
  if (ro is! RenderBox || !ro.hasSize) return false;
  final pos = ro.localToGlobal(ro.size.center(Offset.zero));
  final root = _shotKey.currentContext?.findRenderObject();
  if (root is RenderBox && root.hasSize) {
    final inside = pos.dx > 0 &&
        pos.dy > 0 &&
        pos.dx < root.size.width &&
        pos.dy < root.size.height;
    if (!inside) {
      _say('   ✗「$text」滚到可见后仍在窗外 '
          '(${pos.dx.toStringAsFixed(0)}, ${pos.dy.toStringAsFixed(0)})'
          ' / 窗口 ${root.size.width.toStringAsFixed(0)}×'
          '${root.size.height.toStringAsFixed(0)}');
      return false;
    }
  }
  _say('   合成 tap「$text」@ (${pos.dx.toStringAsFixed(0)},'
      ' ${pos.dy.toStringAsFixed(0)}) —— 进程内，无 OS 输入');
  const ptr = 7;
  final g = GestureBinding.instance;
  g.handlePointerEvent(const PointerAddedEvent(pointer: ptr, position: Offset.zero));
  g.handlePointerEvent(PointerDownEvent(pointer: ptr, position: pos));
  await Future<void>.delayed(const Duration(milliseconds: 60));
  g.handlePointerEvent(PointerUpEvent(pointer: ptr, position: pos));
  return true;
}

/// 说明：旧实现（直接取 `AppGlassDialog`/`AlertDialog` 的 renderObject）
/// 已被上面 `_dialogRect` 取代 —— 旧实现会命中满屏路由根，测出"整窗=卡片"。

// ═══════════════════════════════════════════════════════════════════════
//  抓图 + 像素判读
// ═══════════════════════════════════════════════════════════════════════

Future<void> _capture(_Case c, Rect? rect) async {
  final ro = _shotKey.currentContext?.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    _bad('${c.id}: 根上不是 RenderRepaintBoundary（拿不到可 toImage 的层）');
    return;
  }
  final ui.Image img = await ro.toImage(pixelRatio: 1.0);
  final png = await img.toByteData(format: ui.ImageByteFormat.png);
  final raw = await img.toByteData(format: ui.ImageByteFormat.rawRgba);
  if (png == null || raw == null) {
    _bad('${c.id}: toImage/toByteData 返回 null');
    return;
  }
  final path = '${_outDir.path}${Platform.pathSeparator}${_prefix}${c.id}.png';
  File(path).writeAsBytesSync(png.buffer.asUint8List(), flush: true);
  _say('  SHOT $path  ${img.width}x${img.height}  '
      '${(png.lengthInBytes / 1024).toStringAsFixed(1)} KB');

  final pix = _Pix(img.width, img.height, raw.buffer.asUint8List());

  // 卡片区域 2× 裁切另存，给人眼看细节（同一帧、同一份像素）
  if (rect != null) {
    await _cropCard(img, rect, '${_outDir.path}${Platform.pathSeparator}${_prefix}card_${c.id}.png');
  }

  _analyze(c, pix, rect);
  img.dispose();
}

Future<void> _cropCard(ui.Image src, Rect r, String path) async {
  final scale = 2.0;
  final w = (r.width * scale).roundToDouble();
  final h = (r.height * scale).roundToDouble();
  const pad = 12.0;
  final rec = ui.PictureRecorder();
  final cv = Canvas(rec);
  cv.drawRect(
    Rect.fromLTWH(0, 0, w + pad * 2, h + pad * 2),
    Paint()..color = const Color(0xFF1B1A1F),
  );
  cv.drawImageRect(
    src,
    r,
    Rect.fromLTWH(pad, pad, w, h),
    Paint()..filterQuality = FilterQuality.none,
  );
  final pic = rec.endRecording();
  final out = await pic.toImage((w + pad * 2).round(), (h + pad * 2).round());
  final bd = await out.toByteData(format: ui.ImageByteFormat.png);
  if (bd != null) {
    File(path).writeAsBytesSync(bd.buffer.asUint8List(), flush: true);
    _say('  CROP $path  ${out.width}x${out.height}');
  }
  pic.dispose();
  out.dispose();
}

void _analyze(_Case c, _Pix p, Rect? rect) {
  final w = p.w;
  final h = p.h;

  // ① barrier 参考色（屏幕四角，卡片碰不到那里）
  final barrier = p.hex(4, 4);
  _say('  PX img=${w}x$h barrier=$barrier '
      'corner2=${p.hex(w - 5, h - 5)}');

  if (rect == null) {
    _bad('${c.id}: 渲染树里找不到卡片 rect ⇒ 无法判读几何');
    return;
  }

  final l = rect.left.round().clamp(0, w - 2);
  final t = rect.top.round().clamp(0, h - 2);
  final r = rect.right.round().clamp(l + 2, w - 1);
  final b = rect.bottom.round().clamp(t + 2, h - 1);
  final cw = r - l;
  final ch = b - t;
  _say('  PX card rect=(x=$l,y=$t,w=${rect.width.toStringAsFixed(1)},'
      'h=${rect.height.toStringAsFixed(1)})');

  // ★ 采样矩形内缩 1px —— 2026-10-20 用像素证过的根因：
  //   rect（y..y+h）把卡片**自身那 1px 描边**圈进了采样区。460 宽的玻璃卡底边
  //   整条 460-26×2=408px 全是描边色 (117,119,125)，和卡片底色的差 >45
  //   ⇒ 被当成「文字墨迹」，报出 ringInk=408 的假红（跨 9 个不同高度的卡片
  //   恒为 408 就是证据：那不是字，是边框）。
  //   SOURIN_T105_NOSHRINK=1 关掉内缩 ⇒ 必须把 9 条红原样跑回来（双向自证）。
  final noShrink = Platform.environment['SOURIN_T105_NOSHRINK'] == '1';
  final shrink = noShrink ? 0 : 1;
  final sl = l + shrink, st = t + shrink;
  final sr = r - shrink, sb = b - shrink;
  _say('  SHRINK|case=${c.id} inset=${shrink}px noshrink=${noShrink ? "1" : "0"}');

  // ② 几何判据（口径按 docs/AGENTS.md §3.5，380 已作废）
  //
  // ```text
  // §3.5：宽度 默认 560；窄弹窗 460、宽版面 820；最大高度 绝对值 620。
  // 机器可读三行，便于修前/修中/修后直接 diff：
  //   CENTER|case=NN rect=WxH viewport=WxH centered=yes/no dx=..
  //   WIDTH |case=NN w=NNN whitelist={460,560,820} verdict=ok/bad
  //   FILL  |case=NN pct=NN.N verdict=good/bad
  // ```
  const whitelist = <double>[460, 560, 820];
  final leftGap = l.toDouble();
  final rightGap = (w - r).toDouble();
  final dx = (leftGap - rightGap).abs();
  final centered = dx <= 2.0;
  final fillPct = cw / w * 100;
  _say('  CENTER|case=${c.id} rect=${cw}x$ch viewport=${w}x$h '
      'centered=${centered ? "yes" : "no"} dx=${dx.toStringAsFixed(1)}');
  final wHit = whitelist
      .where((e) => (rect.width - e).abs() <= 2.0)
      .toList(growable: false);
  final wOk = wHit.isNotEmpty || !c.isShell;
  _say('  WIDTH|case=${c.id} w=${rect.width.toStringAsFixed(0)} '
      'whitelist={460,560,820} verdict=${wOk ? "ok" : "bad"}');
  _say('  FILL|case=${c.id} pct=${fillPct.toStringAsFixed(1)} '
      'verdict=${fillPct < 90 ? "good" : "bad"}');

  if (c.isShell) {
    // 产品框：宽度必须在 §3.5 白名单里（380 与 1280 都红，460 绿）
    _ok('${c.id} 宽度落在 §3.5 白名单 {460,560,820}（实测 '
        '${rect.width.toStringAsFixed(0)}）', wOk);
  } else {
    // 对照组（Material AlertDialog）：自带 24 内边距 + 内容定宽，
    // 不按产品白名单判 —— 它在这里只证明「测量器能看见一张正常卡片」
    _say('  （对照组不按产品白名单判：Material Dialog 宽度由内容+24 内边距决定）');
  }
  _ok('${c.id} 卡片水平居中（左右留白差 ${dx.toStringAsFixed(1)}px ≤2）', centered);
  _ok('${c.id} 卡片没铺满视口（占宽 ${fillPct.toStringAsFixed(1)}% <90%）',
      fillPct < 90);
  if (c.narrow) {
    _ok('${c.id} 窄视口下四边都不贴边（L$leftGap T$t R$rightGap B${h - b}）',
        leftGap > 2 && t > 2 && rightGap > 2 && (h - b) > 2);
  }

  // ②-b 三键同排：托盘关闭框是唯一的三键框，判「一行、x 递增、都在卡片内」。
  //      只读渲染树里的 Text 矩形（不点、不抢焦点）；像素侧的「不裁切」由
  //      下面的 10px 边环判据兜底。
  if (c.id.contains('tray_close')) {
    const labels = ['最小化到托盘', '彻底退出', '取消'];
    final rs = <String, Rect>{};
    for (final lb in labels) {
      final rr = _textGlobalRect(lb);
      if (rr != null) rs[lb] = rr;
    }
    if (rs.length != labels.length) {
      _bad('${c.id} 三键没全部出现在渲染树里（找到 ${rs.length}/3）');
    } else {
      final ys = rs.values.map((e) => e.center.dy).toList(growable: false);
      final dyMax =
          ys.reduce((a2, b2) => a2 > b2 ? a2 : b2) -
              ys.reduce((a2, b2) => a2 < b2 ? a2 : b2);
      final sameY = dyMax <= 1.0;
      final inside = rs.values.every((e) =>
          e.left >= l + 2 && e.right <= r - 2 && e.top >= t + 2 && e.bottom <= b - 2);
      final cx = labels.map((e) => rs[e]!.center.dx).toList(growable: false);
      final ordered = cx[0] < cx[1] && cx[1] < cx[2];
      _say('  KEYS|case=${c.id} n=3 sameY=${sameY ? "yes" : "no"} '
          'dy=${dyMax.toStringAsFixed(1)} inside=${inside ? "yes" : "no"} '
          'order=${ordered ? "yes" : "no"}');
      _ok('${c.id} 三键同排（y 相同 ≤1px、x 递增）', sameY && ordered);
      _ok('${c.id} 三键都在卡片内（各留 2px）', inside);
    }
  }

  // ③ 底色：卡片内部三点取样（避开文字：取左右内边距带 + 底部内边距带）
  final bgSamples = <String>[
    p.hex(l + 6, t + ch ~/ 2),
    p.hex(r - 6, t + ch ~/ 2),
    p.hex(l + cw ~/ 2, b - 6),
    p.hex(l + 6, t + 6),
  ];
  _say('  PX card bg samples=${bgSamples.join(" ")}');

  // ④ 圆角：只对**纯色底**卡片估（白底 Material 可靠）。
  //    玻璃卡片底色本身是渐变+模糊背景，逐行找「首像素」会一路误命中（首版实测
  //    给已知圆角 18 的 AlertDialog 报 0，属探针缺陷，不是产品缺陷）⇒ 这里如实跳过。
  final bgc = p.rgb(l + cw ~/ 2, b - 6);
  int dmax((int, int, int) a, (int, int, int) b2) => [
        (a.$1 - b2.$1).abs(),
        (a.$2 - b2.$2).abs(),
        (a.$3 - b2.$3).abs(),
      ].reduce((x2, y2) => x2 > y2 ? x2 : y2);
  final solid = dmax(p.rgb(l + 6, t + ch ~/ 2), bgc) <= 10 &&
      dmax(p.rgb(r - 6, t + ch ~/ 2), bgc) <= 10 &&
      dmax(p.rgb(l + cw ~/ 2, t + 6), bgc) <= 10;
  if (solid) {
    final profile = <int>[];
    var radius = 0;
    for (var dy = 0; dy < 28 && t + dy < h; dy++) {
      var inset = -1;
      for (var dx = 0; dx < 34 && l + dx < w; dx++) {
        if (dmax(p.rgb(l + dx, t + dy), bgc) <= 10) {
          inset = dx;
          break;
        }
      }
      profile.add(inset);
      if (inset > radius) radius = inset;
    }
    _say('  PX cornerInset(top→down 28px)=${profile.join(",")}');
    // 标定（两次已知真值的真机读数，不是我拍的常数）：
    //   R=20（fix0 树：`borderRadius: 20`）⇒ raw 16
    //   R=22（fix1 树：`Radii.lg`）        ⇒ raw 18
    //   两次差 2 = 源码差 2 ⇒ 线性；偏置恒 −4（圆角处的玻璃高光/抗锯齿让
    //   「首个吃到卡片底色」的像素提前 4px 命中）⇒ 还原 raw + 4。
    final rawR = radius;
    final calR = rawR + 4;
    final dR = (calR - Radii.lg).abs();
    // 对照组（AppDialogShell 玻璃档）的卡片是**深色玻璃压在浅页上**，
    // 边缘对比度低、还有高光带；±10 容差分类器在这条边上不可靠
    // （2026-10-20 实测 raw=1 ⇒ 明显是分类失败，不是圆角=1）。
    // 故对照组只报读数、不判；产品框（cases 01-08）照常判 ok/bad。
    final isCtrl = c.id.contains('shell_glass');
    _say('  RADIUS|case=${c.id} raw=$rawR calibrated=$calR '
        'target=Radii.lg(${Radii.lg}) diff=${dR.toStringAsFixed(1)} '
        'verdict=${isCtrl ? "info" : (dR <= 2 ? "ok" : "bad")}');
    if (isCtrl) {
      _say('  RADIUS-NOTE|case=${c.id} 对照组深色玻璃边对比度低 ⇒ 分类器不可靠，'
          '只作信息；圆角以 card_${c.id}.png 人眼判');
    }
  } else {
    _say('  PX 圆角：卡片底色是渐变/透背景 ⇒ 探针不估（看图判）');
    _say('  RADIUS|case=${c.id} raw=skip target=Radii.lg(${Radii.lg}) '
        'verdict=skip');
  }

  // ⑤ 文字墨迹 bbox —— 判「文字/按钮有没有被裁掉」。
  //    阈值 45：卡片自身的1px描边/阴影与底色的差 <25，只有真正的字/按钮才超过；
  //    首版用 26 会把描边算成墨迹 ⇒ 已知完好的 AlertDialog 也报「余量 0」。
  final bg = p.rgb(l + cw ~/ 2, sb - 6);
  var x0 = 1 << 20, y0 = 1 << 20, x1 = -1, y1 = -1, ink = 0;
  var ringInk = 0;
  // 采样区已经内缩 1px（见上）⇒ 这里的最外圈是卡片内部，不再是它自己的描边。
  // 判据：**卡片外圈 10px 内不许有「和底色差 >45」的像素**（文字/按钮按设计有
  // 16~24px 内边距，进不去这一圈）。如果内缩后这里仍有像素，那就是真的贴边/裁切，
  // 探针会把前几个像素的坐标与颜色打出来，交给人眼判。
  final edgeHist = List<int>.filled(8, 0);
  final ringSamples = <String>[];
  var maxLum = 0;
  final colorSet = <int>{};
  for (var y = st; y < sb; y += 1) {
    for (var x = sl; x < sr; x += 1) {
      // 圆角四角外的那块是「卡片没盖到的地方」，颜色天然等于遮罩/背景
      // ⇒ 会被误当成墨迹把 bbox 顶到边缘（首版就这么把已知完好的 AlertDialog
      //    报成「余量 0」）。这里把每个角 26×26 的方块排除，只看卡片本体。
      final nearL = x - sl < 26, nearR = sr - 1 - x < 26;
      final nearT = y - st < 26, nearB = sb - 1 - y < 26;
      if ((nearL || nearR) && (nearT || nearB)) continue;
      final cx = p.rgb(x, y);
      final d = [
        (cx.$1 - bg.$1).abs(),
        (cx.$2 - bg.$2).abs(),
        (cx.$3 - bg.$3).abs(),
      ].reduce((a2, b2) => a2 > b2 ? a2 : b2);
      final lu = p.lum(x, y);
      if (lu > maxLum) maxLum = lu;
      if (x % 3 == 0 && y % 3 == 0) {
        colorSet.add((cx.$1 >> 3 << 16) | (cx.$2 >> 3 << 8) | (cx.$3 >> 3));
      }
      final edgeD = [
        x - sl,
        sr - 1 - x,
        y - st,
        sb - 1 - y,
      ].reduce((a2, b2) => a2 < b2 ? a2 : b2);
      if (edgeD < 16) {
        if (d > 45) {
          edgeHist[edgeD ~/ 2] += 1;
          if (edgeD < 10) {
            ringInk += 1;
            if (ringSamples.length < 3) {
              ringSamples.add('($x,$y)#${p.hex(x, y)}@d$edgeD');
            }
          }
        }
        continue;
      }
      if (d > 45) {
        ink++;
        if (x < x0) x0 = x;
        if (y < y0) y0 = y;
        if (x > x1) x1 = x;
        if (y > y1) y1 = y;
      }
    }
  }
  _say('  PX ink bbox=(x=$x0,y=$y0..x=$x1,y=$y1) count=$ink ring=$ringInk');
  _say('  PX edge-band ink hist 0-2/2-4/4-6/6-8/8-10/10-12/12-14/14-16 = $edgeHist');
  if (ringSamples.isNotEmpty) {
    _say('  PX ring 样例像素=${ringSamples.join(" ")}');
  }

  _ok('${c.id} 有文字/按钮像素（不是空白卡片）', ink > 300, 'ink=$ink');
  _ok('${c.id} 卡片不是纯黑（最大亮度 $maxLum）', maxLum > 40);
  _ok('${c.id} 文字/按钮没进出 10px 边缘圈（内缩 1px 后仍无墨迹 ⇒ 内边距没塌陷、没裁切）',
      ringInk == 0, 'ringInk=$ringInk');

  if (ink > 300) {
    final ml = x0 - l, mt = y0 - t, mr = r - x1, mb = b - y1;
    // 环外已排除 ⇒ 这四个数必然 ≥10，只作信息行（不再当判据，否则是「恒真断言」）。
    _say('  PX 墨迹到卡片边缘的余量 L=$ml T=$mt R=$mr B=$mb'
        '（含 10px 边环；判据见上一行的 ringInk）');
  } else {
    _bad('${c.id} 卡片内几乎没有墨迹 ⇒ 疑似空白渲染');
  }

  _ok('${c.id} 颜色种数 ${colorSet.length}（>12 说明不是纯色空白）',
      colorSet.length > 12);

  // ⑥ 玻璃质感：卡片内部亮度/色彩**有变化**（玻璃 + 内容），
  //    且卡片与遮罩明显不同（不是没画出来）。
  //    ⚠️ 遮罩采样不能取 (4,4)：应用自带自定义标题栏，窗口左上角是标题栏
  //    （恒为亮白），拿它当 barrier 会给出与弹窗无关的读数（2026-10-20 实测
  //    (4,4)=235 而卡片 231 ⇒ 判据恒红/无判别力）。改成在卡片**四周外 30px**
  //    取 8 点中位数，天然落在遮罩上。
  final topLum = p.lum(l + cw ~/ 2, t + 4);
  final botLum = p.lum(l + cw ~/ 2, b - 4);
  final barLum = _barrierLum(p, l, t, r, b, p.w, p.h);
  _say('  PX 卡片内亮度 top=$topLum bottom=$botLum '
      'barrierLum=$barLum（卡片外 30px 8 点中位数）');
  _ok('${c.id} 卡片与遮罩可区分（|Δ亮度|>6）', (topLum - barLum).abs() > 6);
  _say('  PX 备注：玻璃的"模糊"无法用像素断言，'
      '靠 card_${c.id}.png 人眼判（本探针已另存 2× 裁切）');

  // ⑦ 对比度（Lead 2026-10-20 指出的真缺陷维度）——**纯像素量，不看渲染树**：
  //    底 = 全卡众数色；文字 = 文本带内离底最远的像素。
  //    局限（如实登记）：小字号最暗/最亮像素仍可能是半覆盖的抗锯齿像素
  //    ⇒ 读数偏保守（真实对比度只会更好）。
  final cc = _contrastOfCard(p, sl, st, sr, sb);
  if (cc.title < 0) {
    _say('  ${cc.line.replaceFirst("CONTRAST|", "CONTRAST|${c.id}|")}');
  } else {
    _say('  ${cc.line.replaceFirst("CONTRAST|CASE|", "CONTRAST|${c.id}|")}');
    _say('  CONTRAST-NOTE|${c.id}|${cc.note}');
    _ok('${c.id} 对比度 ≥4.5（title ${cc.title.toStringAsFixed(2)} / '
        'body ${cc.body.toStringAsFixed(2)}）',
        cc.title >= 4.5 && cc.body >= 4.5);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  单个用例
// ═══════════════════════════════════════════════════════════════════════

Future<void> _runCase(_Case c) async {
  _say('');
  _say('── ${c.id}  ${c.note}');
  _say('   来源: ${c.src}');
  _currentCase = c.id;
  _nCase++;

  final errBefore = _errs.length;

  if (c.trigger != null) {
    // 真实路径：不改写任何东西，直接调产品代码
    // ⚠️ 前置闸：只有 closeAction == ask 时点 X 才会弹框；
    //    别的档位会真的最小化/退出（探针会当场死掉）
    if (AppTray.instance.action != CloseAction.ask) {
      _bad('${c.id}: closeAction=${AppTray.instance.action}（不是 ask）'
          '⇒ 调 onWindowClose 会真的退出，跳过本框');
      return;
    }
    _say('   trigger=产品真实入口（closeAction=ask ✓）');
    await c.trigger!();
  } else {
    final ctx = AppTray.navigatorKey.currentContext;
    if (ctx == null) {
      _bad('${c.id}: 拿不到 navigatorKey.currentContext');
      return;
    }
    _say('   context=AppTray.navigatorKey.currentContext '
        '(与 app_tray.dart:241 同一个)');
    // 不复刻 pop 逻辑，直接挂上去；返回值不用（本探针用 navigator.pop 收尾）
    // ⚠️ 不用 `unawaited`：`showAppDialog<void>` 的返回是 `Future<void?>`，
    //    类型上不是 `Future<void>`；`Future.ignore()` 才是这里要的语义
    //    （框留在树上供取证，出错由 FlutterError 收集器记账）。
    showAppDialog<void>(
      context: ctx,
      barrierDismissible: false,
      builder: c.build!,
    ).ignore();
  }

  await _settle();
  final rect = _dialogRect();
  await _capture(c, rect);

  // 收尾：把框关掉，再等退场动效走完（否则下一框会叠在这个上面）
  final nav = AppTray.navigatorKey.currentState;
  if (nav != null && nav.canPop()) nav.pop();
  await _settle(frames: 1, ms: 420);
  if (c.cleanup != null) await c.cleanup!();

  final added = _errs.length - errBefore;
  if (added > 0) {
    _bad('${c.id}: 本框期间新增 ${added} 条渲染异常');
  } else {
    _ok('${c.id}: 本框期间渲染异常 = 0', true);
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  main
// ═══════════════════════════════════════════════════════════════════════

int _selfTestBad = 0;

/// 离线量具自检：对**存档 PNG** 复算对比度（与当场渲染的帧共用同一个
/// `_contrastOfCard()`，所以它证明的是「尺子有判别力」，不是另写一套）。
/// 规格：`名字[!OK|!BAD]=路径[@l,t,w,h]`，多条用 `;` 分隔；省略 rect 时
/// 按 `card_*.png` 的 2× 裁切几何（四周各 12px 暗底 pad）。
Future<void> _selfTest(String spec) async {
  _say('');
  _say('══ 量具自检：同一把尺子跑「已知合格」与「已知坏」两张存档图 ══');
  for (final raw in spec.split(';')) {
    final s = raw.trim();
    if (s.isEmpty) continue;
    var name = s, path = s;
    final eq = s.indexOf('=');
    if (eq > 0) {
      name = s.substring(0, eq);
      path = s.substring(eq + 1);
    }
    String? expect;
    for (final tag in const ['!OK', '!BAD']) {
      if (name.endsWith(tag)) {
        expect = tag.substring(1);
        name = name.substring(0, name.length - tag.length);
      }
    }
    var rect = const Rect.fromLTRB(12, 12, 932, 542);
    final at = path.lastIndexOf('@');
    if (at > 0) {
      final nums = path
          .substring(at + 1)
          .split(',')
          .map((e) => double.parse(e.trim()))
          .toList(growable: false);
      path = path.substring(0, at);
      if (nums.length == 4) {
        rect = Rect.fromLTWH(nums[0], nums[1], nums[2], nums[3]);
      }
    }
    final f = File(path);
    if (!f.existsSync()) {
      _say('  !! 自检缺图: $path');
      _selfTestBad++;
      continue;
    }
    final codec = await ui.instantiateImageCodec(f.readAsBytesSync());
    final frame = await codec.getNextFrame();
    final im = frame.image;
    final bd = await im.toByteData(format: ui.ImageByteFormat.rawRgba);
    if (bd == null) {
      _say('  !! 自检解码失败: $path');
      _selfTestBad++;
      continue;
    }
    final p = _Pix(im.width, im.height, bd.buffer.asUint8List());
    final l = rect.left.round().clamp(0, p.w - 4);
    final t = rect.top.round().clamp(0, p.h - 4);
    final r = rect.right.round().clamp(l + 4, p.w - 1);
    final bb = rect.bottom.round().clamp(t + 4, p.h - 1);
    final c = _contrastOfCard(p, l + 1, t + 1, r - 1, bb - 1);
    final verdict = c.title < 0 ? 'SKIP' : (c.line.split('verdict=').last);
    _say('  ${c.line.replaceFirst("CONTRAST|CASE|", "CONTRAST|selftest:$name|")}');
    _say('  CONTRAST-NOTE|selftest:$name|${c.note}'
        '|img=${p.w}x${p.h}|rect=($l,$t,$r,$bb)'
        '${expect == null ? "" : "|expect=$expect"}');
    if (expect != null && verdict != expect) {
      _say('  ✗ 自检失配: $name 期望 $expect 实得 $verdict ⇒ 量具没有判别力');
      _selfTestBad++;
    }
    im.dispose();
  }
  _say('SELFTEST ${_selfTestBad == 0 ? "PASS" : "FAIL"} bad=$_selfTestBad');
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  _prefix = Platform.environment['SOURIN_T105_PREFIX'] ?? '';

  // 产物目录 = <cwd>/.probe/round66_r4_device
  _outDir = Directory(
      '${Directory.current.path}${Platform.pathSeparator}.probe'
      '${Platform.pathSeparator}round66_r4_device');
  if (!_outDir.existsSync()) _outDir.createSync(recursive: true);
  _logFile = File('${_outDir.path}${Platform.pathSeparator}${_prefix}probe.log');
  _logFile!.writeAsStringSync(''); // 每次跑清空，避免误读上一轮的 DONE

  // ── 渲染异常收集器（**判据**：全程必须 0）─────────────────────────
  FlutterError.onError = (FlutterErrorDetails d) {
    final msg = '${d.exceptionAsString()}';
    _errs.add('[$_currentCase] $msg');
    _say('  !! FLUTTER ERROR ($_currentCase): $msg');
    final lib = d.context?.toString() ?? d.library;
    _say('     ctx=$lib');
    final st = d.stack;
    if (st != null) {
      final lines = st.toString().split('\n').take(8).join('\n        ');
      _say('     strace:\n        $lines');
    }
  };
  ui.PlatformDispatcher.instance.onError = (Object e, StackTrace st) {
    _errs.add('[$_currentCase] zone: $e');
    _say('  !! ZONE ERROR ($_currentCase): $e');
    return true; // 吞掉，让探针继续跑完（但上面已记账 ⇒ 整条验收作废）
  };

  _say('══════ T105 · R4 弹窗真机像素验收 ══════');
  _say('cwd=${Directory.current.path}');
  _say('产物目录=${_outDir.path}');

  // ── 量具自检（离线）：同一个「文本带 → 对比度」量具跑存档 PNG ────────
  //    Lead 的要求：已知**合格**的图必须报 OK，已知**坏**的图必须报 BAD，
  //    否则量具本身没有判别力。规格：`名字=相对路径@l,t,w,h`，多条用 `;` 分隔；
  //    不给 rect 时按 card_*.png 的 2× 裁切几何（pad=12，2 倍图）。
  final st = Platform.environment['SOURIN_T105_SELFTEST'];
  if (st != null && st.trim().isNotEmpty) {
    await _selfTest(st);
    _say('DONE');
    await Future<void>.delayed(const Duration(milliseconds: 200));
    exit(_selfTestBad == 0 ? 0 : 1);
  }

  // ── 隔离数据目录硬闸（不许碰用户真实目录）────────────────────────
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  _say('DATA_DIR_OVERRIDE(编译期)=${override.isEmpty ? "<未设>" : override}');
  _say('APPDATA=${Platform.environment["APPDATA"]}');
  final dataDir = await ClipDownloader.dataDir();
  _say('解析后的数据目录=$dataDir');
  final isolated = dataDir
      .replaceAll('\\', '/')
      .contains('.probe/round66_r4_device');
  if (!isolated) {
    _say('★★★ 拒绝运行：数据目录不在隔离目录下（会在用户真实目录里留东西）');
    _say('RESULT FAIL dataDir=$dataDir');
    exit(3);
  }
  _say('数据目录隔离闸 ✓');

  // 兜底看门狗：任何一段卡住都不许让外层脚本无限等
  Timer(const Duration(seconds: 240), () {
    _say('★★★ TIMEOUT 240s ⇒ 强制退出');
    _say('RESULT FAIL timeout');
    exit(4);
  });

  // ── 与产品 main() 对齐的最小初始化（顺序同 shell.dart）───────────
  try {
    await UiPrefs.load(dataDir);
  } catch (e) {
    _say('UiPrefs.load 失败（不影响弹窗取证）: $e');
  }
  try {
    await SourinCore.startAsync(dataDir);
    _say('SourinCore.startAsync ✓');
  } catch (e) {
    // 核心起不来时产品会显示"核心未能启动"接管页 —— 弹窗照样能验
    _say('SourinCore.startAsync 失败（弹窗取证不受影响）: $e');
  }

  // 托盘「第一次点 X 要问」这一档要求 closeAction == ask
  _say('AppTray.action=${AppTray.instance.action}');

  // 窗口：只 show，**不 focus**（不抢宿主焦点）
  try {
    await windowManager.ensureInitialized();
    await windowManager.setSize(const Size(1280, 800));
    await windowManager.center();
    await windowManager.show();
    _say('窗口已 show（1280x800，不抢焦点）');
  } catch (e) {
    _say('windowManager 调用失败（继续，toImage 不依赖窗口可见）: $e');
  }

  // ── 产品自己的根：SourinApp（内部 WidgetsApp + Material 本地化委托）──
  runApp(RepaintBoundary(key: _shotKey, child: const SourinApp()));
  _say('runApp(RepaintBoundary(SourinApp)) ✓ —— 根是产品的，不是探针搭的');

  // 等 Navigator 可用（首帧 + 首页异步初始化）
  for (var i = 0; i < 80; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await WidgetsBinding.instance.endOfFrame;
    if (AppTray.navigatorKey.currentContext != null) break;
  }
  if (AppTray.navigatorKey.currentContext == null) {
    _bad('Navigator 8s 内没起来 ⇒ 无法弹窗');
    _say('RESULT FAIL navigator_not_ready');
    exit(5);
  }
  _say('Navigator ready ✓');
  await _settle(frames: 2, ms: 1200); // 让首页首屏把异步内容落完

  // ── 逐框取证 ──────────────────────────────────────────────────
  _say('── 未取证：10_exempt_backup_login_choice —— backup_panel.dart 里'
      '「这个备份文件含登录态」那个 AlertDialog 只由私有 _exportConsent() 弹出，'
      '而它要求面板已连上云盘并选到 .sourin 备份文件（无凭据时 :535 直接 return）。');
  _say('   探针不造云端凭据、也不复制它的 builder，故本项如实记为未取证。');
  for (final c in _cases()) {
    if (c.narrow) {
      _say('');
      _say('── 把视口缩到 800×600（窄视口复核；§3.5「按视口夹取」那半句）');
      await windowManager.setSize(const Size(800, 600));
      await _settle(frames: 3, ms: 800);
    } else {
      // 窄视口是「一次性的」：处理完必须复原，否则后面所有用例都在
      // 800×600 里拍（2026-10-20 实测 case11 就这样被拍成 800×600）。
      final sz = await windowManager.getSize();
      if (sz.width != 1280 || sz.height != 800) {
        await windowManager.setSize(const Size(1280, 800));
        await _settle(frames: 3, ms: 800);
      }
    }
    await _runCase(c);
  }

  // ── 收尾 ──────────────────────────────────────────────────────
  await _settle(frames: 1, ms: 300);
  final e = _errs.length;
  _say('');
  _say('══════ 汇总 ══════');
  _say('用例=$_nCase 判据通过=$_nOk 判据失败=$_nBad 渲染异常=$e');
  if (e > 0) {
    _say('渲染异常明细：');
    for (final s in _errs) {
      _say('  - $s');
    }
    _say('★★ 按验收规则：出现任何异常 ⇒ 整条验收作废');
  }
  final pass = e == 0 && _nBad == 0;
  _say('RESULT ${pass ? "PASS" : "FAIL"} cases=$_nCase ok=$_nOk bad=$_nBad errors=$e');
  _say('DONE');

  await Future<void>.delayed(const Duration(milliseconds: 400));
  exit(pass ? 0 : 1);
}
