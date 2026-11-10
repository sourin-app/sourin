// Miuix scaffold owns page surfaces and header/footer layout. The app keeps
// keyboard inset handling explicit because the product also hosts native video.

import 'package:material_ui/material_ui.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;

import 'theme/miuix_palette.dart';
import 'theme/miuix_framework_bridge.dart';

/// 页面外壳
class AppScaffold extends StatelessWidget {
  const AppScaffold({
    required this.child,
    this.backgroundColor,
    this.header,
    this.sidebar,
    this.footer,
    this.resizeToAvoidBottomInset = true,
    super.key,
  });

  /// 主内容区
  final Widget child;

  /// 页面底色
  final Color? backgroundColor;

  final Widget? header;
  final Widget? sidebar;
  final Widget? footer;

  /// 软键盘弹出时是否让 body 避开
  final bool resizeToAvoidBottomInset;

  @override
  Widget build(BuildContext context) {
    final bottom = resizeToAvoidBottomInset
        ? MediaQuery.viewInsetsOf(context).bottom
        : 0.0;
    // Consume the keyboard inset once so nested media/player scaffolds do not
    // shrink twice. Keep these wrappers mounted at zero inset too: opening the
    // keyboard must not replace the page's stateful subtree.
    final body = Padding(
      padding: EdgeInsets.only(bottom: bottom),
      child: MediaQuery.removeViewInsets(
        context: context,
        removeBottom: resizeToAvoidBottomInset,
        child: child,
      ),
    );

    Widget column = miuix.MiuixScaffold(
      // MiuixScaffold defaults to a surface; page gutters use the background.
      containerColor:
          backgroundColor ?? miuix.MiuixTheme.of(context).colors.background,
      contentWindowInsets: EdgeInsets.zero,
      topBar: header,
      bottomBar: footer,
      content: (padding) => Padding(padding: padding, child: body),
    );

    if (sidebar != null) {
      column = Row(
        children: [
          sidebar!,
          Expanded(child: column),
        ],
      );
    }

    // Miuix surfaces publish MiuixContentColor for MiuixText. Existing Flutter
    // Text children also need a theme-aware default, including list contents.
    return DefaultTextStyle.merge(
      style: TextStyle(color: miuix.MiuixTheme.of(context).colors.onSurface),
      child: column,
    );
  }
}

/// 把一套 [ThemeData] 注入子树（取代 forui 的 `FTheme`）
///
/// ⚠️ 这一层**不是**多余的：播放页用它把浮层面板强制成深色皮肤，
///    与外层的主题无关（见 `player_page.dart`）。
class AppThemeHost extends StatelessWidget {
  const AppThemeHost({required this.data, required this.child, super.key});

  final ThemeData data;
  final Widget child;

  @override
  Widget build(BuildContext context) => Theme(
    data: data,
    child: miuix.MiuixTheme(
      data: miuixThemeData(data.brightness),
      child: MiuixFrameworkBridge(child: child),
    ),
  );
}
