// ShellPage owns page state; layouts only place its cached content and navigation.
import 'package:flutter/widgets.dart';

import '../../shell.dart' show AppTab;

/// 布局骨架 —— 决定「内容区 + 导航」怎么摆
///
/// 实现必须满足：
/// ```text
/// ① 不持有 body 的 State（body 由 ShellPage 保活，骨架只是摆放）
/// ② 切换布局后当前页状态和滚动位置必须保留。
/// ③ 导航必须能切全部 6 个 tab（判据 2）
/// ```
abstract class ShellLayout {
  const ShellLayout();

  /// 骨架的稳定标识（落盘用，**改名字会让老用户的选择失效**）
  String get id;

  /// 设置界面里显示的名字
  String get label;

  /// 摆放 body 与导航
  ///
  /// ⚠️ [body] 是**已经构造好**的内容区 widget —— 实现**不许**重建它，
  ///    只能把它放进自己的布局里（否则保活失效、滚动位置丢失）。
  Widget build({
    required BuildContext context,
    required AppTab current,
    required ValueChanged<AppTab> onSelect,
    required Widget body,
    required List<AppTab> tabs,
  });
}
