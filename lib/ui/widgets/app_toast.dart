// ═══════════════════════════════════════════════════════════════════════
//  统一的 toast
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么自己写，而不是用 Material 的 SnackBar
//
// ```text
// SnackBar  只能挂在 ScaffoldMessenger 上 —— 而本项目有 5 个 tab 页 +
//           若干 push 出来的全屏页，各自带 Scaffold，且播放页是全屏视频。
//           ⇒ 「谁是当前 ScaffoldMessenger」这件事本身就不确定，
//           会偶发弹在错误的页面上。
// 手写 _Toast  四个页面各抄了一份（detail / follow / settings / settings\skip），
//           只能同时显示一条、样式四份、关不掉。
// ```
//
// 现在统一到这里：**一条 Overlay**（挂在 `MaterialApp.builder` 里，全路由可见），
// 支持多条堆叠、各自计时、可手动关闭。
//
// # 与旧版的差别（有意为之，Owner 的第 11 条「整体 ui 优化」）
//
// ```text
// 旧  黑底胶囊 @82%，2.4s 后消失，只有最后一条
// 新  跟随主题的浮层卡片；多条同时堆叠（新的在下面），
//     常驻关闭按钮，键盘也能关（Esc / Tab 到提示卡片回车）
// ```
//
// ⚠️ **刻意不做「进度条」**：计时条每帧重绘，在低端 Android TV 上是纯开销，
//    而 toast 本来就是几秒的信息。

import 'package:flutter_miuix/miuix.dart' as miuix;

import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../tokens.dart';
import '../../design/icons/app_icons.dart';

/// 挂在 `MaterialApp.builder` 里的 toast 宿主
///
/// 用法：`toastHost(child)` 包住 `builder` 的返回值即可。
class ToastHost extends StatelessWidget {
  const ToastHost({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) => AppToaster(child: child);
}

/// 一条 toast 的外观参数
@immutable
class AppToastStyle {
  AppToastStyle({this.icon, this.accent, this.actionLabel, this.onAction});

  /// 左侧图标（成功/错误语义用）
  final IconData? icon;

  /// 图标与边框的强调色
  final Color? accent;

  /// 右侧动作（如「重试」）
  final String? actionLabel;
  final VoidCallback? onAction;
}

/// 弹一条 toast
///
/// 调用方式和旧版一样简单：
/// ```dart
/// showAppToast(context, '已收藏');
/// ```
///
/// - [context] 用来找到 [AppToaster]；找不到就静默忽略（**不抛异常**）——
///   toast 是锦上添花，绝不该把调用方搞崩。
void showAppToast(
  BuildContext context,
  String message, {
  Duration duration = const Duration(milliseconds: 2600),
  AppToastStyle? style,
}) {
  AppToaster.maybeOf(context)?.show(message, duration: duration, style: style);
}

/// 最多同时显示几条
///
/// ⚠️ 不是「装饰」而是**防止刷屏**：某些失败路径会连着弹十几条
/// （比如批量操作里每一项都失败），那时前 5 条早已过期，占的却是最新信息。
const int _maxVisible = 4;

class AppToaster extends StatefulWidget {
  const AppToaster({required this.child, super.key});

  final Widget child;

  /// 找到当前可见的 toast 宿主；找不到返回 null（调用方静默忽略）
  static _AppToasterState? maybeOf(BuildContext context) =>
      context.findAncestorStateOfType<_AppToasterState>();

  @override
  State<AppToaster> createState() => _AppToasterState();
}

class _ToastEntry {
  _ToastEntry(this.message, this.style, this.remainingTicks) : id = Object();

  final Object id;
  final String message;
  final AppToastStyle? style;

  /// Shared ticks only update fading. Expiry starts at this entry's enqueue
  /// time, so arriving between ticks cannot shorten the requested lifetime.
  int remainingTicks;
  Timer? expiration;
}

class _AppToasterState extends State<AppToaster> {
  final _entries = <_ToastEntry>[];
  FocusScopeNode? _notificationFocusParent;

  @override
  void initState() {
    super.initState();
    FocusManager.instance.addListener(_followPageFocus);
  }

  FocusScopeNode? _activePageScope() {
    final focus = FocusManager.instance.primaryFocus;
    final focusedContext = focus?.context;
    if (focusedContext == null ||
        !focusedContext.mounted ||
        AppToaster.maybeOf(focusedContext) != this) {
      return null;
    }
    return focus?.nearestScope;
  }

  void _followPageFocus() {
    if (!mounted || _entries.isEmpty) return;
    final scope = _activePageScope();
    if (scope != null && scope != _notificationFocusParent) {
      setState(() => _notificationFocusParent = scope);
    }
  }

  /// 每 100ms 更新淡出外观；每条提示自己的定时器负责到期移除。
  ///
  /// ⚠️ 用 `Timer.periodic` 而**不是** `AnimationController.repeat()`：
  ///    后者只要在跑就永远有下一帧 —— ① 空闲时白烧 CPU；
  ///    ② widget 测试里 `pumpAndSettle` 会**永远等不到静止**而超时。
  Timer? _clock;

  void _startClock() {
    _clock ??= Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _tick(),
    );
  }

  void _stopClock() {
    _clock?.cancel();
    _clock = null;
  }

  void _tick() {
    if (!mounted) {
      _stopClock();
      return;
    }
    setState(() {
      for (final entry in _entries) {
        entry.remainingTicks--;
      }
    });
  }

  void show(
    String message, {
    Duration duration = const Duration(milliseconds: 2600),
    AppToastStyle? style,
  }) {
    // ⚠️ 在 build 期间调用 setState 会抛 "setState() called during build"。
    //    调用点可能是任意位置（包括某个 Builder 里顺手弹提示），把这件事
    //    兜在组件内部，调用方就不必记得"要延后一帧"。
    if (SchedulerBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) show(message, duration: duration, style: style);
      });
      return;
    }
    final e = _ToastEntry(
      message,
      style,
      (duration.inMilliseconds / 100).ceil(),
    );
    e.expiration = Timer(duration, () => _dismiss(e.id));
    setState(() {
      _notificationFocusParent = _activePageScope();
      _entries.add(e);
      // 新的排在**下面**（视觉上更近底栏，视线不用往上找）
      while (_entries.length > _maxVisible) {
        _entries.removeAt(0).expiration?.cancel();
      }
    });
    _startClock();
  }

  /// 现在有没有 toast（Esc 的 Action 用它决定 enabled，见 [ToastDismissShortcut]）
  bool get hasToasts => _entries.isNotEmpty;

  /// 手动关掉最上面那条（Esc 键）
  void dismissTop() {
    if (_entries.isEmpty) return;
    _dismiss(_entries.last.id);
  }

  void _dismiss(Object id) {
    if (!mounted) return;
    setState(() {
      _entries.removeWhere((e) {
        if (e.id != id) return false;
        e.expiration?.cancel();
        return true;
      });
    });
    if (_entries.isEmpty) _stopClock();
  }

  @override
  void dispose() {
    FocusManager.instance.removeListener(_followPageFocus);
    _stopClock();
    for (final entry in _entries) {
      entry.expiration?.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep the page at the same element path as notifications come and go.
    // The shortcut also surrounds the notification actions, not just the page.
    return ToastDismissShortcut(
      child: Stack(
        fit: StackFit.passthrough,
        children: [
          widget.child,
          if (_entries.isNotEmpty)
            Positioned(
              left: 0,
              right: 0,
              bottom: Sp.x10,
              // WidgetsApp's Navigator Scope is a closed traversal loop. The
              // global visual overlay joins the active page's focus scope so
              // Tab can reach it without moving focus when a toast appears.
              child: FocusTraversalGroup(
                parentNode: _notificationFocusParent,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final e in _entries)
                      _ToastCard(
                        key: ValueKey(e.id),
                        message: e.message,
                        style: e.style,
                        // 剩余寿命：只剩最后一秒时才开始变淡（先别急着消失）
                        fade: _fadeFor(e),
                        onClose: () => _dismiss(e.id),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  double _fadeFor(_ToastEntry e) {
    final left = e.remainingTicks * 100;
    if (left > 1200) return 1;
    return (left / 1200).clamp(0.25, 1.0);
  }
}

class _ToastCard extends StatefulWidget {
  const _ToastCard({
    required this.message,
    required this.style,
    required this.fade,
    required this.onClose,
    super.key,
  });

  final String message;
  final AppToastStyle? style;
  final double fade;
  final VoidCallback onClose;

  @override
  State<_ToastCard> createState() => _ToastCardState();
}

class _ToastCardState extends State<_ToastCard> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final colors = miuix.MiuixSnackbarDefaults.snackbarColors(context);
    return Opacity(
      opacity: widget.fade,
      child: Padding(
        padding: const EdgeInsets.only(top: Sp.x2, left: Sp.x3, right: Sp.x3),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: FocusableActionDetector(
              onShowFocusHighlight: (focused) {
                if (_focused != focused) setState(() => _focused = focused);
              },
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.numpadEnter):
                    ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
                SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
              },
              actions: {
                ActivateIntent: CallbackAction<ActivateIntent>(
                  onInvoke: (_) {
                    widget.onClose();
                    return null;
                  },
                ),
              },
              child: DecoratedBox(
                position: DecorationPosition.foreground,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    miuix.MiuixSnackbarDefaults.cornerRadius,
                  ),
                  border: _focused
                      ? Border.all(
                          color: miuix.MiuixTheme.of(context).colors.primary,
                          width: 2,
                        )
                      : null,
                ),
                child: Semantics(
                  liveRegion: true,
                  button: true,
                  label: '关闭提示：${widget.message}',
                  onTap: widget.onClose,
                  child: miuix.MiuixSnackbar(
                    data: _ToastData(
                      widget.message,
                      widget.style,
                      widget.onClose,
                    ),
                    colors: miuix.MiuixSnackbarColors(
                      containerColor: colors.containerColor,
                      contentColor: colors.contentColor,
                      actionContentColor: colors.actionContentColor,
                      dismissActionContentColor: colors.contentColor,
                      actionContainerColor:
                          widget.style?.accent ?? colors.actionContainerColor,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ToastData implements miuix.MiuixSnackbarData {
  _ToastData(String message, this.style, this.close)
    : visuals = miuix.MiuixSnackbarVisuals(
        message: message,
        actionLabel: style?.onAction == null ? null : style?.actionLabel,
        withDismissAction: true,
      );
  final AppToastStyle? style;
  final VoidCallback close;
  @override
  final miuix.MiuixSnackbarVisuals visuals;
  @override
  Future<void> dismiss() async => close();
  @override
  Future<void> performAction() async => style?.onAction?.call();
}

AppToastStyle okToastStyle() =>
    AppToastStyle(icon: AppIcons.check_circle_outline);

AppToastStyle errToastStyle() =>
    AppToastStyle(icon: AppIcons.error_outline, accent: Colors.redAccent);

/// Esc 关掉最上面那条（TV 遥控器上比鼠标 hover 更靠谱）
///
/// ★ 两个关键点（都是修出来的 bug，勿回退）：
///
/// 1. **必须挂在 AppToaster 里面**。反过来（Shortcuts 在外）时
///    `AppToaster.maybeOf(context)` 是 `findAncestorStateOfType`，
///    只会往**父**里找，找不到自己的子节点 ⇒ `dismissTop()` 是死代码，
///    Esc 按了没反应。
/// 2. **Action 必须"没 toast 时 disabled"**。`CallbackAction` 不覆写
///    `isEnabled`，恒为 true ⇒ 即使一条 toast 都没有，这个 Focus 也会
///    返回 `KeyEventResult.handled`，把 Esc 吃掉 ⇒ 全应用的
///    `Esc → DismissIntent`（关弹窗/关抽屉）彻底失效。
///    `ActionDispatcher` 只会调用 enabled 的 action，所以这里覆写
///    `isEnabled` 就够了，`consumesKey` 不用管。
class ToastDismissShortcut extends StatelessWidget {
  const ToastDismissShortcut({required this.child, super.key});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final toaster = AppToaster.maybeOf(context);
    return Shortcuts(
      shortcuts: <ShortcutActivator, Intent>{
        const SingleActivator(LogicalKeyboardKey.escape):
            const _DismissToastIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _DismissToastIntent: _DismissTopToastAction(toaster),
        },
        child: child,
      ),
    );
  }
}

/// 只在**确实有 toast 要关**时才 enabled；enabled 才允许 invoke。
class _DismissTopToastAction extends Action<_DismissToastIntent> {
  _DismissTopToastAction(this._toaster);

  final _AppToasterState? _toaster;

  @override
  bool isEnabled(_DismissToastIntent intent) => _toaster?.hasToasts ?? false;

  @override
  Object? invoke(_DismissToastIntent intent) {
    _toaster?.dismissTop();
    return null;
  }
}

class _DismissToastIntent extends Intent {
  const _DismissToastIntent();
}
