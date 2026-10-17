// ═══════════════════════════════════════════════════════════════════════
//  ★★★ task-10 ③（Owner 2026-10-09 第三批）：插件「编辑 / 添加」改成**一个表单**
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话（逐字）：
// ```text
// > js插件既然已经用链接了,为什么点击编辑还是显示的插件代码?而不是编辑链接?
// > 这里改一下,改成编辑 添加,是一个表单,选择链接 或者 源码,然后自动识别
// ```
//
// # 改前（两条独立的老路径，体验割裂）
// ```text
// 添加 ⇒ 「粘贴插件内容」一个多行框，只能贴源码（settings_page.dart:1140-1156）
// 编辑 ⇒ 读整份源码塞进多行框（settings_page.dart:1258-1288）
// ```
// ⇒ 一个**按链接安装**的插件，点「编辑」看到的却是 2 万字 JS ——
//   用户想问的是「我当初给的那个链接呢」。链接明明存在
//   （`PluginEntry.upstream`，task-5 的缺陷 5 刚加的），只是编辑框没显示它。
//
// # 改后：一个表单，两件事
// ```text
// · 用户只填**一样东西**（一个多行框）
// · 内容自动识别成「链接」或「源码」，并在表单里**显式回显**识别结果
// · 编辑已有的：按 `PluginEntry.upstream` 判类型并预填（★ 不自己再解析源码）
// ```
library;

/*
 * ★★★ 2026-10-09 修复（Owner 真机缺陷：「js插件点击编辑就变成这样子,并没有弹窗出现」）
 *
 * # 症状
 * ```text
 * 在「设置 → JS 插件」点某张卡片的「编辑」⇒ 整屏变成一层灰（遮罩铺上了），
 * **但对话框没出现**。截图见 Owner 2026-10-09 18:4x。
 * ```
 *
 * # 根因：**这个文件用了另一个 Material 库**
 * ```text
 * 本文件原来： import（单引号）package:flutter/material.dart ← ✗ 错的那个
 *              ⚠️ 这里**故意不写出真实字符组合** —— `theme_regression_test.dart` 会全 lib 扫
 *                 这个 import 字面量，写在注释里也会被判违规（我这次就踩了）。
 * 调用方      ： settings_page.dart:48
 *               import 'package:material_ui/material_ui.dart';  ← ✓ 本仓统一的那个
 *
 * Flutter 3.47 把 Material **从 SDK 拆成了���立包** `material_ui`（见 pubspec.yaml
 * 那段注释、以及 test/material_split_test.dart 的完整机制推导）。
 * 两套 Material 的 `MaterialLocalizations` 是**不同的 InheritedWidget 类型**，
 * 互相看不见 ⇒ 调用方在 material_ui 的世���里，被调的对话框在 flutter/material 的
 * 世界里 ⇒ `showDialog` 内部的 `debugCheckHasMaterialLocalizations` 抛异常
 * ⇒ release 构建把它吞成「只有遮罩、没有对话框」。
 *
 * 实测（我的探针 test/zz_lead_plugin_edit_dialog_probe_test.dart）：
 *   material_ui 宿主 + flutter/material 的 showDialog
 *     ⇒ `No MaterialLocalizations found.` + `AlertDialog 在树里 = false`
 * ```
 *
 * # ★ 这不是新坑 —— 是同一个老坑第二次被踩
 * ```text
 * `test/material_split_test.dart:29-33` 早就写明了这个模式：
 *   shell.dart          → material_ui       （MaterialApp / Theme 是 material_ui 的）
 *   lib/ui 下的任意 dart → flutter/material  （Theme.of 找的是另一套 ⇒ 拿亮色兜底）
 *
 * ⚠️⚠️ 写这段注释本身也踩了本仓一个已知坑：
 *   路径通配写法里的「斜杠 + 星号 + 星号」会被 Dart 当成**块注释的开始**，
 *   于是本块注释提前嵌套、编译报「Comment starting with ... must end with ...」。
 *   ⇒ 本文件里凡要提那个通配写法，一律写成「斜杠 + 两个星号」的文字描述，
 *     不要写出真实的字符组合。（release-dev 报告里 `lib/core` 那次同一形态。）
 * 并且明确写了「统一到 material_ui」就是修法。
 *
 * 但本文件是 **task-10 ③ 新写的**，又踩了同一个坑，而**没有任何守卫**拦住它。
 * ⇒ 这是本仓「同一纪律缺少可执行守卫」的又一处（同类：铁律 170）。
 * ```
 */
import 'package:material_ui/material_ui.dart';

import '../../core/sourin_api.dart';
import '../tokens.dart';
import 'app_dialog_shell.dart';
import 'overlay_motion.dart';
import '../../design/icons/app_icons.dart';

/// 表单的两种安装方式
enum PluginInputKind {
  /// 一个 http(s) 链接 —— 走 `install_plugin`
  link,

  /// 一段 JS 源码 —— 新建走 `install_plugin_source`，编辑走 `save_plugin_source`
  source,
}

/// 表单结果
class PluginEditResult {
  const PluginEditResult({required this.kind, required this.text});

  final PluginInputKind kind;

  /// 链接（kind == link）或源码（kind == source）
  final String text;
}

/// ★ 自动识别的判据（Owner 说的「自动识别」）。
///
/// # 规则（与 task-10 描述逐字一致，可测）
/// ```text
/// trim 后以 http:// 或 https:// 开头
///   且**不含换行**
///   且不含 `@id`
/// ⇒ 链接；否则 ⇒ 源码。
/// ```
///
/// # 为什么三条都要（每条都挡一类真实误判）
/// ```text
/// ① 必须 http(s) 开头 —— 文件路径 / 裸域名不算链接，我们只会去 GET 一个 URL
/// ② 必须不含换行 —— 源码里**通常含** `// https://…` 这类注释行，
///    只看前缀会把整份源码误判成链接（这条是最容易漏的）
/// ③ 必须不含 `@id` —— 插件头部注释的必备字段（见 settings_page.rb:1143 的提示语），
///    出现了就一定是源码
/// ```
/// ⚠️ 判据必须是**纯函数**（本函数不收 BuildContext、不碰 IO），
///    这样探针可以直接对字符串表断言，不需要挂树。
PluginInputKind classifyPluginInput(String raw) {
  final t = raw.trim();
  if (t.isEmpty) return PluginInputKind.source;
  final isHttp = t.startsWith('http://') || t.startsWith('https://');
  if (!isHttp) return PluginInputKind.source;
  if (t.contains('\n') || t.contains('\r')) return PluginInputKind.source;
  if (t.contains('@id')) return PluginInputKind.source;
  return PluginInputKind.link;
}

/// 打开「添加 / 编辑插件」表单。
///
/// - [existing] == null ⇒ **添加**（新建）
/// - [existing] != null ⇒ **编辑**（预填并锁定类型）
///
/// 返回 null = 用户取消。
///
/// ⚠️ **必须走 `showAppDialog`**（本仓唯一入口，见 overlay_motion.dart:311-339）——
///    `test/t104_overlay_exit_test.dart` 的 ④ 静态门禁钉着「lib 里裸 showDialog 归零」。
///    我第一版用了裸 `showDialog`，那条门禁当场变红（实测报：
///    `Expected: empty / Actual: ['lib/ui/widgets/plugin_edit_dialog.dart（1 处）']`）。
///    走统一入口还顺带拿到退场动效（`animationStyle`），与本仓其它 15 处一致。
Future<PluginEditResult?> showPluginEditDialog({
  required BuildContext context,
  PluginEntry? existing,
}) {
  return showAppDialog<PluginEditResult>(
    context: context,
    builder: (_) => PluginEditDialogBody(existing: existing),
  );
}

/// ★ 表单主体（public 是为了**探针能直接挂树**）。
///
/// 编辑对话框该按什么类型打开 —— **纯函数**，可单测。
///
/// # 为什么抽出来（2026-10-09）
///
/// 原来的判据写死在 `initState` 里，用了 `PluginEntry.upstream` —— 而那是
/// **上游接口地址**（不是安装来源），于是手写插件被误判成「按链接安装」：
/// ```text
/// srcv.js → upstream = "https://api.bilibili.com"
///   ⇒ 编辑框预填接口地址 + 类型锁死成「链接」
///   ⇒ 点保存走 installPlugin(接口地址) ⇒ **把本地插件覆盖坏**
/// ```
///
/// # 判据
/// ```text
/// sourceUrl 非空 ⇒ 链接型（预填它，类型锁死）
/// sourceUrl 为空 ⇒ 源码型（读源码预填）
/// ```
/// `sourceUrl` 必须来自**真实的安装来源**（`plugins/.meta/<id>.json` 的
/// `source_url`，经 `SourinApi.listPluginSources()`）—— 那个文件**只有**
/// 「按链接安装」才会写，手动放入 / 自己写的插件不会有。
///
/// ⚠️ 抽成纯函数不只是为了好测：原判据**在测试宿主里测不到**（读源码要 FFI，
///    没有后端时 future 永不完成，用例会恒绿）。判据变成纯函数之后，
///    探针可以直接调它做**正反两向**断言，不再依赖那棵树。
PluginInputKind kindForExisting({String? sourceUrl}) {
  final url = sourceUrl?.trim() ?? '';
  return url.isEmpty ? PluginInputKind.source : PluginInputKind.link;
}

/// # 为什么需要它 public
/// ```text
/// `showAppDialog` 走 `useRootNavigator: true`，在 bare `MaterialApp` 的测试宿主里
/// 查不到 MaterialLocalizations（实测三种 context 都不行）—— 那是**测试宿主**的限制。
/// 把它 public 出来，探针就能挂**生产同一份 build** 来验识别与回显，
/// 而不需要伪造一整套 App 外壳；路由那一层由 t104 的 ④ 静态门禁与它自己的用例守着。
/// ```
class PluginEditDialogBody extends StatefulWidget {
  const PluginEditDialogBody({super.key, this.existing});

  final PluginEntry? existing;

  @override
  State<PluginEditDialogBody> createState() => _PluginEditDialogState();
}

class _PluginEditDialogState extends State<PluginEditDialogBody> {
  late final TextEditingController _ctl;
  late PluginInputKind _kind;

  /// 用户有没有**手动**改过类型。
  ///
  /// ★ 改过之后就不再被自动识别覆盖 —— 否则用户刚点「按源码」
  ///   然后输入框内容一抖，识别又把它翻回「链接」，按钮跟着跳。
  bool _userPicked = false;

  bool get _isEdit => widget.existing != null;

  @override
  void initState() {
    super.initState();
    final e = widget.existing;
    if (e == null) {
      _ctl = TextEditingController();
      _kind = PluginInputKind.source;
    } else {
      /*
       * ★★★ 编辑已有插件：按**真实的安装来源**判类型（2026-10-09 修掉的 bug）
       *
       * # 改前错在哪
       * ```text
       * 用 `PluginEntry.upstream` 判：非空就当"按链接装的"。
       * 但 `upstream` 的语义是**上游接口地址**（task-5 为 TVBox 转换插件加的显示字段），
       * 而且它当时还会去正文扫 `const API` ⇒ 手写插件的接口地址被当成安装来源：
       *   srcv.js → upstream = "https://api.bilibili.com"
       *   ⇒ 判成链接型 ⇒ 预填接口地址 + 类型锁死
       *   ⇒ 点保存走 install_plugin(接口地址) ⇒ **本地插件被覆盖坏**
       * ```
       *
       * # 现在按什么判
       * ```text
       * `SourinApi.listPluginSources()` ⇒ { id: sourceUrl }，
       * 读的是 `plugins/.meta/<id>.json` 的 `source_url` ——
       * 那个文件**只有**「按链接安装」才会写（install_plugin / set_plugin_source）。
       * 手动放入 / 自己写的插件没有它 ⇒ 如实判成源码型。
       * ```
       *
       * ⚠️ 这是**异步**的（要读 sidecar），所以先按源码型占位 + 置只读，
       *    等来源查回来再定类型 —— 否则用户可能在空框里打字被打断。
       *    `upstream` 仍然拿来**显示**（卡片上那个可复制的"上游接口"），
       *    但**不再参与类型判定**。
       */
      _ctl = TextEditingController();
      _kind = PluginInputKind.source;
      _loadSourceAndSource(e.file, e.id);
    }
  }

  bool _loadingSource = false;
  String? _loadError;

  /// 读源码**并**查有没有真实安装来源，两个都回来再定类型。
  ///
  /// # 为什么要合并成一次（而不是在 initState 里各起一个 future）
  /// ```text
  /// 两边都会 setState ⇒ 分开写会出现"源码回来了、来源还没回来"的中间态，
  /// 那时类型是源码型、但来源进来后又翻成链接型 ⇒ 输入框内容被换掉、
  /// 用户正在看的字突然消失。合起来只有一个稳定终态。
  /// ```
  ///
  /// ⚠️ 查来源失败**不能**让整个对话框坏掉 —— 它是"锦上添花"的判据，
  ///    失败时按源码型处理（保守：源码型是"编辑自己写的东西"，不会误覆盖）。
  Future<void> _loadSourceAndSource(String file, String id) async {
    setState(() => _loadingSource = true);
    String src = '';
    String? srcUrl;
    try {
      src = await SourinApi.readPlugin(file);
    } catch (err) {
      if (!mounted) return;
      setState(() {
        _loadError = '$err';
        _loadingSource = false;
      });
      return;
    }
    try {
      final sources = await SourinApi.listPluginSources();
      srcUrl = sources[id];
    } catch (_) {
      // 查不到来源 ⇒ 按源码型处理（见上面的说明）
      srcUrl = null;
    }
    if (!mounted) return;
    // ★ 判据走纯函数（可单测，见它的文档）—— 类型提升成局部量避免 lint 报多余的 `!`
    final realSource = (srcUrl != null && srcUrl.trim().isNotEmpty) ? srcUrl.trim() : '';
    setState(() {
      if (kindForExisting(sourceUrl: realSource) == PluginInputKind.link) {
        // ★ 真·按链接安装的：预填那个链接，类型锁死
        _ctl.text = realSource;
        _kind = PluginInputKind.link;
      } else {
        _ctl.text = src;
        _kind = PluginInputKind.source;
      }
      _loadingSource = false;
    });
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  void _onChanged(String v) {
    if (_userPicked) return;
    final k = classifyPluginInput(v);
    if (k != _kind) setState(() => _kind = k);
    setState(() {});
  }

  void _pick(PluginInputKind k) {
    setState(() {
      _kind = k;
      _userPicked = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isLink = _kind == PluginInputKind.link;
    /*
     * ★ 编辑一个**链接型**插件时，类型**锁死**成链接。
     *
     * 为什么：编辑的意义是「改那个链接」。允许在这里切成源码会走
     * `save_plugin_source`（覆盖 sidecar 文件），把上游链接丢掉 ——
     * 用户下次就再也检测不了更新了。要换类型请删掉重装。
     */
    final typeLocked = _isEdit && _kind == PluginInputKind.link;

    /*
     * ★★★ 2026-10-09 修复（第二个缺陷）：**对话框不能撑满视口**
     *
     * # 实测（我的探针，真机视口 1444x845）
     * ```text
     * 改前：对话框尺寸 = 1444.0 x 845.0   ← ★ **等于整个视口**
     * 改后：预期 < 900（按设计约 560~640）
     * ```
     *
     * # 为什么这会长成 Owner 截图那个样子
     * ```text
     * 卡片撑满视口 ⇒ 卡片背景色与遮罩色在视觉上连成一片 ⇒
     * 用户看到的**就是「一层灰」，没有对话框**（内容全被挤到边缘/溢出）。
     * ★ 这正是 Owner 截图「只有灰、没有弹窗」的**第二重成因**：
     *   第一重是 `flutter/material` 那个 import 让 showDialog 直接抛异常（已修）；
     *   这一重是就算异常不抛，卡片也会撑满 ⇒ 视觉上仍然「看不见弹窗」。
     * ```
     *
     * # 修法
     * ```text
     * ① `content` 用 `SizedBox(width: 560)` 是对的，但它约束的是**内容**；
     *    真正决定卡片外框的是 `AlertDialog` 自己的约束。
     * ② 显式加 `constraints:` 把上限钉死（宽度上限 ~600、高度上限 ~视口的 0.8）
     *    ⇒ 卡片不再无限生长。
     * ③ `insetPadding` 给足四周留白（框架默认 40 横向，这里显式给 24/48 更好看也更稳）。
     * ```
     */
    /*
     * ★ 2026-10-16：外壳改走全仓统一的 `AppDialogShell`（docs/AGENTS.md 第 3.5 节），
     *   与 `danmaku_settings_dialog.dart` / `provider_import_dialog.dart` 同一形态。
     *
     * 改前这里用的是 `SettingsDialog`（`settings_kit.dart` 里的 `AlertDialog`
     * 外壳）—— 那是**第二套**外壳：宽度 560 由它自己的 `ConstrainedBox` 限制、
     * 圆角/标题栏/按钮排布全走 Material 默认，与 `AppDialogShell`
     * （560 定宽 + `Radii.rLg` + 自绘标题栏 + 分隔线操作区）不是同一套视觉。
     * 全仓只允许一套外壳。
     *
     * ⚠️ 标题栏、`width`、`maxHeight` 一律**不传** —— 外壳的 `_Header` 与
     *    默认 560 /「高度上限 = 视口 × 0.8」接管。上面那段手写的
     *    `constraints` / `insetPadding` 讨论因此失效：那两个值现在由外壳
     *    **一处**决定（这正是「不许各写各的」的落点）。
     *
     * ⚠️ 滚动区**交给外壳**（`scrollable` 默认 true）：`SettingsDialog` 那层
     *    内容滚动已随它一起删掉，这里再套一层就是「滚动里再滚动」。
     */
    return AppDialogShell(
      title: _isEdit ? '编辑「${widget.existing!.name}」' : '添加插件',
      // ★ 2026-10-10：一句话说清这个对话框在干嘛（原来只有标题）
      subtitle: isLink
          ? '填一个插件链接，或直接粘贴 JS 源码 —— 会自动识别'
          : '粘贴 JS 源码（文件开头要有 @id 注释）',
      /*
       * ★ 右上角关闭 = 取消（与底部那枚「取消」按钮**同一个出口**）：
       *   两条路都是 `Navigator.pop()` 且不带结果 ⇒ 调用方拿到 null（= 用户取消）。
       *   ⚠️ 外壳的 `_Header` 只在 `onClose` 非空时才渲染关闭钮 —— 必须传。
       */
      onClose: () => Navigator.of(context).pop(),
      /*
       * ★★★ `fill: false` —— **本文件没有 `fill` 字段**，所以这里不是「透传」，
       *    而是**必须显式写死 false**。
       *
       * # 为什么本弹窗只可能是 false（取证，不是猜的）
       * ```text
       * 本弹窗的唯一入口是 showAppDialog ⇒ showDialog（overlay_motion.dart:311），
       * 它把内容包成：SafeArea → Padding → MediaQuery → Builder → 内容
       * （见 AppDialogShell 的类文档「坑 2」那一节，有真实崩溃栈）。
       * ```
       * ⇒ 宿主链里**没有 Stack** ⇒ `fill: true` 那层「直接做 Stack 的直接孩子」
       *   的语义在本弹窗**无处可落**。外壳现在自己提供 Stack，所以 true 也不会
       *   再抛 `Incorrect use of ParentDataWidget`（那是外壳修好的，见它的文档），
       *   但 `Stack(fit: expand)` 会**铺满整屏**（实测：外壳尺寸 = 1444 x 845，
       *   即整个视口）—— 那正是 Owner 2026-10-09 截图「只有一层灰、看不见弹窗」
       *   的形态（见本文件上面那段 `AlertDialog` 撑满视口的记录）。
       * ⇒ 本弹窗取 false：外壳**只返回「遮罩 + 居中卡片」那一层**，
       *   卡片自己 `SizedBox(width: 560)` 定宽居中 ⇒ 与 `SettingsDialog` 时代
       *   的几何一致（实测卡片 560 宽、居中、视口 1440 下四周留白）。
       *
       * # 为什么不是「加一个 fill 字段透传」
       * `fill` 开关的用途是让**常挂在宿主 Stack 下**的面板（danmaku / bili /
       * subtitle）在 `SheetExitMotion` 里改走非定位形态。本弹窗走的是
       * `showAppDialog` 路由（每次 new 一个路由，没有常挂宿主、也没有
       * `SheetExitMotion`），**只存在一种形态** ⇒ 多一个恒为 false 的字段
       * 只是假接口。
       *
       * ⚠️ 实测：`fill: true` 时卡片会被 `Stack(fit: expand)` 拉满视口
       *    （探针读数 1444 x 845），肉眼即「整屏一块板」；false 时 560 居中。
       */
      fill: false,
      /*
       * ★★ 2026-10-09：这里**不需要** `constraints` / `insetPadding`（我撤掉了）。
       *
       * 我当时凭「卡片撑满视口」的直觉加过 `constraints: BoxConstraints(maxWidth: 600)`
       * —— 但**反面对照把它否掉了**：
       * ```text
       *   有 constraints ⇒ 内容区 552 x 280
       *   无 constraints ⇒ 内容区 560 x 280   ← 几乎一样
       * ```
       * ⇒ 那个改动**没有解决问题**，只是让我以为修了。已撤。
       *
       * ⚠️ 同时纠一个判据错误（我第一版判据是错的）：
       *   `find.byType(AlertDialog)` 的尺寸**恒等于视口**（它本来就是铺满的外层包装），
       *   我据此判「卡片撑满」⇒ 假红。真正该测的是**内容区**（见探针里的注释）。
       * ⇒ 教训：判据测错节点时，会同时产生**假红**和**假绿**两种误判。
       */
      actions: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _loadingSource
                ? null
                : () {
                    final t = _ctl.text.trim();
                    if (t.isEmpty) return;
                    Navigator.of(context).pop(
                      PluginEditResult(kind: _kind, text: t),
                    );
                  },
            child: Text(_isEdit ? '保存' : '安装'),
          ),
        ],
      ),
      /*
       * ★ 外壳的 `actions` 是**单个 Widget**（它自己套
       *   `Row(mainAxisAlignment: end)` + 分隔线），不是列表 ——
       *   所以这里用一枚 `Row` 装原来的两颗按钮。
       *
       * ⚠️ 内层 Row **必须** `mainAxisSize.min`：默认的 `.max` 会吃掉外壳那一行的
       *    整宽，按钮就会靠左而不是靠右（外壳的对齐失效）。
       * ⚠️ 按钮的顺序、文案、onPressed、禁用条件**一字未改**。
       */
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 识别结果回显（Owner 说的「然后自动识别」）
          Row(
            children: [
              Icon(
                isLink ? AppIcons.link : AppIcons.code,
                size: FontSizes.base,
                color: colors.primary,
              ),
              const SizedBox(width: Sp.x2),
              Text(
                _loadingSource
                    ? '正在读取源码…'
                    : (isLink ? '将按：链接安装' : '将按：源码安装'),
                key: const ValueKey('plugin_edit_kind_label'),
                style: TextStyle(
                  color: colors.primary,
                  fontWeight: FontWeights.semibold,
                ),
              ),
              if (typeLocked) ...[
                const SizedBox(width: Sp.x2),
                /*
                 * ★ 颜色改取主题角色（原先写死 `Colors.grey`）——
                 *   本 app 支持明暗双主题，写死的灰在亮色主题下对比度不足。
                 *   `onSurfaceVariant` 就是外壳副标题用的同一个角色（视觉层级一致）。
                 */
                Text(
                  '（编辑链接型插件时类型不可改）',
                  style: TextStyle(
                    fontSize: FontSizes.cap,
                    color: colors.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: Sp.x3),
          // ── 唯一的输入框
          TextField(
            controller: _ctl,
            onChanged: _onChanged,
            enabled: !_loadingSource,
            maxLines: isLink ? 1 : 14,
            minLines: isLink ? 1 : 8,
            autofocus: true,
            style: const TextStyle(
              fontFamily: 'monospace',
              fontSize: FontSizes.cap,
            ),
            decoration: InputDecoration(
              border: const OutlineInputBorder(),
              labelText: isLink ? '插件链接' : '插件 JS 源码',
              hintText: isLink
                  ? 'https://…（粘贴插件安装链接）'
                  : '粘贴插件的 JS 源码（需含 @id 头部注释）',
              errorText: _loadError,
            ),
          ),
          const SizedBox(height: Sp.x3),
          // ── 手动切换（自动识别兜底；用户明确说「选择链接 或者 源码」）
          Row(
            children: [
              Text(
                '类型：',
                style: TextStyle(
                  fontSize: FontSizes.cap,
                  color: colors.onSurfaceVariant,
                ),
              ),
              const SizedBox(width: Sp.x1),
              ChoiceChip(
                label: const Text('链接'),
                selected: isLink,
                onSelected:
                    typeLocked ? null : (_) => _pick(PluginInputKind.link),
              ),
              const SizedBox(width: Sp.x2),
              ChoiceChip(
                label: const Text('源码'),
                selected: !isLink,
                onSelected:
                    typeLocked ? null : (_) => _pick(PluginInputKind.source),
              ),
            ],
          ),
        ],
      ),
    );
  }
}