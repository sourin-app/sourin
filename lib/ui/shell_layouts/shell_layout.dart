// ═══════════════════════════════════════════════════════════════════════
//  布局骨架抽象（Owner 第 14 条 · 2026-10-17 确认选 A）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 要的是什么（先划清边界，避免做成换肤）
// ```text
// ❌ 不是：换颜色 / 换圆角 / 换字体   ← 那是现有 9 套配色主题做的事
// ✅ 是：换**页面骨架** —— 导航位置、内容区组织方式
// ```
// ⇒ 判据：三套骨架在**同一页面上，控件位置不同**。
//
// # 为什么抽这一层（而不是在 ShellPage 里 if/else 三份）
// ```text
// ShellPage 的 build 里有大量**与骨架无关**的东西：
//   · 保活 Stack（_stackOrder / Offstage / TickerMode / _KeepAliveTransition）
//   · 顶部安全区 SafeArea
//   · ClipRect / 转场动画 / 页面缓存 _contentFor
// ⇒ 这些**三套骨架共用**。若每套各写一份，保活逻辑就有三份副本，
//   迟早漂移（本项目已有『两处同构必须一起改』的教训）。
//
// 所以：ShellPage 只负责**算出 body**（已保活的内容区），
//       然后 layout.build(body: ...) 决定「body 怎么摆、导航放哪」。
// ⇒ 切骨架**不动页面代码**，也不动保活逻辑。
// ```
//
// # ⚠️ 与配色主题**正交**
// ```text
// 配色：9 套（theme_pack.dart）    骨架：3 套（本目录）
// ⇒ 27 种组合。骨架存 UiPrefs，**不放进 ThemePack** ——
//   用户导入别人的配色主题时，不该被改掉布局。
// ```

import 'package:flutter/widgets.dart';

import '../../shell.dart' show AppTab;

/// 布局骨架 —— 决定「内容区 + 导航」怎么摆
///
/// 实现必须满足：
/// ```text
/// ① 不持有 body 的 State（body 由 ShellPage 保活，骨架只是摆放）
/// ② 切骨架时 body **不能重建**（判据 3：当前页不丢失）
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
