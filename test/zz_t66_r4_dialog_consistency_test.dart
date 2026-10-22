// ═══════════════════════════════════════════════════════════════════════
//  R4 门禁：全仓弹窗一致性（机械可核对）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个门禁守的是什么
//
// Owner 原话：「弹窗样式不统一」「太丑了 丑爆了！」
// 规范见 `docs/AGENTS.md` §3.5 + `app_dialog_shell.dart` 文件头：
// ```text
// 宽度      默认 560；窄弹窗 460、宽版面 820 需显式传 width 并注释原因
// 最大高度  绝对值 620，再按视口夹取（maxHeight 可覆盖，须写清原因）
// 圆角      Radii.rLg = 22
// 标题栏    title + subtitle + 右侧关闭 IconButton
// 内容区    SingleChildScrollView
// 底部操作  可选 actions，与内容区分隔、按钮靠右
// ```
//
// # 三条断言（每条都做过故障注入，见文件末尾）
// ```text
// ① lib/ui/widgets/ 下每个 *dialog*.dart
//    · 不许裸 `AlertDialog(`（Material 原生外壳）
//    · 不许裸 `Dialog(`（自建外壳）
//    · width / maxHeight 取值必须落在白名单，或带 `// R4-EXCEPTION: <理由>`
// ② 白名单本身必须非空（空条款 = 假绿 —— 本仓有先例）
// ③ `AppDialogShell._kMaxHeight == 620`（防有人改回"视口 × 0.8"）
// ```
//
// ⚠️ **注释里的 `Dialog(` 不算**（`skip_marker_dialog.dart` 的注释里
//    留了改前写法的记录，那是文档不是代码）。所以扫描前先剥注释 ——
//    只剥 `//` 行注释与 `/* */` / `///` 文档注释，**不碰字符串字面量**。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/app_update/release.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/ui/widgets/source_composer_dialog.dart';
import 'package:sourin_spike/ui/widgets/update_dialog.dart';

import 'support/ui_shot.dart';

/// 允许的弹窗宽度档位（§3.5：默认 560 / 窄 460 / 宽版面 820）
///
/// ⚠️ 用 `int` 而不是 `double`：`const <double>{460}` 会报
///    "The element '460.0' does not have a primitive equality"
///    （double 的 `==` 不是原始相等，不能进 const Set）。
///    弹窗尺寸都是整数值，取整比较足够。
const _allowedWidths = <int>{460, 560, 820};

/// 允许的最大高度（§3.5：绝对值 620）
const _allowedMaxHeights = <int>{620};

/// 允许**不走外壳**的文件（每个都必须写清理由）
///
/// # 为什么这里**必须有**两个条目（不是洁癖）
/// ```text
/// app_dialog_shell.dart    ← 它**就是外壳本身**，不能要求它再走自己
/// app_dialog_section.dart  ← 分区标题/容器组件，不是弹窗
/// 把它们列进来是语义正确；同时也让下面的 ②「白名单非空」**真的有内容**
/// —— 一个恒空的集合没法被断言"非空"。
/// ```
///
/// ⚠️ 这是**空条款假绿**的防线：本仓有过"白名单空 ⇒ 门禁看起来全绿
///    其实什么都没守"的先例，所以 ② 强制 `isNotEmpty`。
const _bareShellWhitelist = <String, String>{
  'app_dialog_shell.dart': '它本身就是统一外壳 —— 不能要求外壳去使用外壳',
  'app_dialog_section.dart': '分区标题/容器组件，不是弹窗，没有卡片外壳',
};

/// ★★★ 逐**处**豁免表（2026-10-19 第二阶段）
///
/// # 为什么从「按文件」升级成「按处」
/// ```text
/// 改前：`_dialogFiles()` 只扫 `lib/ui/widgets/` 下**文件名含 "dialog"** 的文件。
/// 实测：那 13 个文件（settings_page / sync_panel / backup_panel …）的
///   basename 里一个 "dialog" 都没有 ⇒ **绕过外壳的弹窗对它完全不可见**。
/// ⇒ 门禁全绿，而全仓有一批 `AlertDialog(` / 裸 `Dialog(` 在它视野之外。
/// ★★ 2026-10-19 复核校正：此处原文写的是「22 处」，那是**剥注释之前**、
///   且按旧口径数出来的。复核复刻本门禁口径（剥注释 + 逐行至多计 1 + 5 个 pattern）
///   实跑 ⇒ **15 处**；注册表 15 条 ⇔ 门禁 15 处 ⇒ 当前自洽
///   （2026-10-20 独立复核插桩实测 `SCANNED_TOTAL=15 registry=15`，15 行全 `hit=Y`；
///    配套口径：**收拢 11 处 / 豁免 15 处，漏网 0**）。
///   ⇒ 「22」已作废，**别拿它对账**（下面 `_siteExemptions` 那句也要按 15 读）。
/// ⇒ 按文件豁免救不了这种情况：一个文件里可能既有该换的、也有该留的。
/// ```
///
/// # 键的格式：`相对路径#特征字符串`（2026-10-19 从「路径:行号」改来）
///
/// ★★ **为什么必须改掉行号**（Lead 已批准的设计变更）
/// ```text
/// 上一版键是「路径:行号」，结果出现一个**自相矛盾**的死结：
///   ① ④-b 要求「豁免必须在原地有注释」
///   ② 而"写注释"本身会把 `AlertDialog(` 往下推 5~9 行
///      ⇒ 我登记的行号**当场过期** ⇒ ④-b 立刻报红
///   ③ 我把邻域窗口从 ±12/14 放宽到 ±40 只是治标 —— 下一个人照样会撞
/// ⇒ 根因是**用不稳定的标识（行号）去锚定一个会变的位置**。
///
/// ⇒ 改成「路径 + 一段特征字符串」：只要那段文字还在，登记就有效；
///   注释增删只改行号、不改特征串 ⇒ 永不过期。
/// ```
///
/// # 特征串怎么选（必须能唯一定位那一处）
/// ```text
/// ✓ 用该处**独有的字面量**：函数名、标题文案、构造参数名
/// ✗ 不用 'AlertDialog('（同一文件里可能有多处）
/// ```
const _siteExemptions = <String, String>{
  'lib/ui/settings_page.dart#这一处**刻意保留** Material':
      '轨道 E 实测结论：这一处**刻意保留** Material 的 AlertDialog。'
          '实测依据（源码同处有完整记录）：AppGlassDialog 里放 TextField 会抛'
          '"TextField widgets require a Material widget ancestor"。'
          '它不是「单行提示卡」—— 是一个带输入框的表单区，换过去会崩。'
          '源码同处有完整实测记录。',
  // ═══ R4 第二步 · 第一批「简单确认框」收拢后，逐处登记剩下不合形态的 ═══
  'lib/t104_overlay_exit_probe.dart#真机探针，验证统一入口本身':
      '真机探针，**故意验证统一入口本身**：它已经在走 showAppDialog（:300），'
          '这里的 AlertDialog 只是 builder 里的内容。换成 AppGlassDialog 会让'
          '探针测不到它真正要测的那条路径。',
  'lib/ui/settings/theme_page.dart#contentPadding: EdgeInsets.zero':
      'content 是整个主题预览面板 ThemePreviewBody（重内容），且用了 '
          'contentPadding: EdgeInsets.zero + 自定义 backgroundColor: p.palette.card。'
          'AppGlassDialog 的内边距写死 fromLTRB(24,22,24,16) 且**没有 backgroundColor '
          '参数** ⇒ 换过去会把预览塞进 24px 边距、玻璃底盖掉调色板底色（会变丑）。'
          '★ 待办①：组件补 padding/backgroundColor 两个可选参数后才可收拢。',
  'lib/ui/settings/theme_page.dart#粘贴主题包 JSON':
      '★★ 2026-10-19 复核：**也是两条机制叠加**，此前只写了 textAlign（分类不完整）。'
          '机制④：content 外面包了 `SizedBox(width:460)`（实测两处都是 460）。'
          '机制②：content 是**表单**，实测含 **2 个 `TextField`** '
          '（maxLines:10/minLines:6 的 JSON 粘贴框）⇒ 换过去**同样会抛** '
          '"require a Material widget ancestor"。'
          '★ **先解②、再解④**。'
          '机制④口径：装 460 需传 `maxWidth: 508`（content 宽 = maxWidth − 48）。'
          '另有一条独立问题：`DefaultTextStyle` 写死 `textAlign:center`，'
          '多行输入框居中会很难用 ⇒ 属「组件待办 textAlign 可控」，与上面两条并列。',
  'lib/ui/widgets/sync_panel.dart#配置云盘（WebDAV）':
      '★★ 2026-10-19 复核：这是**两条机制叠加**，此前只写了机制④（分类不完整）。'
          '机制④：content 是 `SizedBox(width:420)` + 自带 '
          '`SingleChildScrollView(clipBehavior)` + 预设 pill 的 Wrap + 表单字段。'
          '机制②：content **含 4 个 `TextField`** ⇒ 换过去**同样会抛** '
          '"require a Material widget ancestor"。'
          '★ **先解②、再解④**（顺序不能反：②不解决，弹窗根本打不开，'
          '传再宽的 maxWidth 也没用）。'
          '机制④可绕的实测口径：`AppGlassDialog` 卡片左右 padding 各 24 ⇒ '
          'content 实测宽 = maxWidth − 48 ⇒ 装 420 需传 `maxWidth: 468`（非 420）。',
  // ── R4 第二步 · 第二批：逐处登记（机制 + 具体数字，Lead 裁决 ①②）──
  // 机制② 缺 Material 祖先（外壳零 Material ⇒ ListTile / InkWell 一路也抛）
  'lib/ui/settings_page.dart#调整内容源顺序':
      '★★ 2026-10-20 **改判：机制②（缺 Material 祖先），此前写「可以收拢」是错的**。'
          'content 是 SizedBox(420x400) + ListView.builder，每行是 **`ListTile`** '
          '（`ListTile` 内部是 `InkWell`，而 `InkWell` 要求 Material 祖先）。'
          '`AppGlassDialog` 是零 Material 的纯玻璃卡片，不提供 Material 宿主 ⇒ '
          '在**真的 showAppDialog 路由**里实测抛 '
          '"No Material widget found. ListTile widgets require a Material '
          'widget ancestor" ⇒ 弹窗根本打不开，「上移」按钮连建都没建出来'
          '（实测找到「上移」= 0 个）。'
          '★ 为什么上一版会判错（如实记录）：那次把 `AppGlassDialog` 放在 '
          '`MaterialApp(home: Scaffold(body: Center(...)))` 里跑，Scaffold '
          '**提供了 Material 祖先** ⇒ 「点第 2 行『上移』顺序真的变了」是仪器造成的，'
          '不是外壳能用。重测脚本：`.probe/r4f_order_material_test.dart`。'
          '⚠️ 宽度**不是**拦路石：装 420 传 `maxWidth: 468` 即可（content 宽 = maxWidth − 48）。'
          '⇒ 给 `AppGlassDialog` 补「透明 Material 宿主」之后才可收拢。',
  // 机制① 固定尺寸 + 自带滚动区
  // ⚠️ 2026-10-20：外壳默认值已从 380/420 抬到 **460/620**（对齐 §3.5），
  //    下列理由里的"装不下"要按新默认重新算，别再用旧的 380/420 对账。
  'lib/ui/settings_page.dart#插件更新 · ':
      '机制①：content 是 SizedBox(width:480, height:460) + Column，'
          '源码注释写明「有界高度（照 _SkipHistoryDialog）：内容再多也只占 460px」。'
          '外壳默认 maxWidth 460 / maxHeight 620 ⇒ 装 480 宽需显式传 '
          '`maxWidth: 528`（content 宽 = maxWidth − 48）⇒ 属调用点决策，本轮不动。',
  'lib/ui/settings_page.dart#配置「':
      '机制①：content 是 SizedBox(width:420) + SingleChildScrollView'
          '(clipBehavior) + 动态字段循环（for (final f in widget.config.fields)）。'
          '外壳默认 maxWidth 460 ⇒ 420 宽的内容只剩 460 − 48 = 412，差 8px；'
          '装得下需显式传 `maxWidth: 468` ⇒ 属调用点决策，本轮不动。',
  'lib/ui/widgets/tvbox_source_panel.dart#订阅更新 · ':
      '★★ 2026-10-19 复核：这是**两条机制叠加**，此前只写了机制④（分类不完整）。'
          '机制④：content 是 `SizedBox(width:560, height:480)` + 自带滚动，'
          '源码注释写明「有界高度（照 _PluginUpdateDialog）：内容再多也只占 480px」。'
          '机制②：content **含 `TextField`** ⇒ 换过去**同样会抛** '
          '"require a Material widget ancestor"。'
          '★ **必须先解②**（不解决则弹窗打不开，宽度无关）。'
          '⚠️ 机制④的可绕代价：装 560 需传 `maxWidth: 608`'
          '（实测口径：content 宽 = maxWidth − 48）⇒ **608 不在 §3.5 白名单 '
          '{460,560,820} 内** ⇒ 真要换，得先决定「破白名单」还是「缩内容」。',
  // 机制② 表单 / 输入框（AppGlassDialog 缺 Material 祖先 ⇒ TextField 抛异常）
  "lib/ui/widgets/backup_panel.dart#title: const Text('设置导出用口令')":
      '机制②：content 含 **TextField**（设置导出用口令），包在 SizedBox(width:380) '
          '的 Column 里。实测：AppGlassDialog 里放 TextField 会抛 '
          '"TextField widgets require a Material widget ancestor" ⇒ 换过去直接崩。',
  'lib/ui/widgets/backup_panel.dart#这个备份包含登录态':
      '机制②：content 含 **TextField**（输入导出时设的口令），包在 SizedBox(width:380) '
          '的 Column 里。同上：换过去会抛 "require a Material widget ancestor"。'
          '★ **别与下面那条搞混**（verify-34 在这里误判过一次「机制写反」，'
          '根因是两个标题只差一个字）：'
          '本条 = `title: const Text(\'这个备份包含登录态\')`，'
          '在 `_ImportPassphraseDialog`（有 TextField）⇒ **机制②**；'
          '另一条 = `title: const Text(\'这个备份文件含登录态\')`，'
          '是 `showAppDialog` 里那段 StringBuffer 清单（无输入框）⇒ **机制⑤**。'
          '两条是**两个不同的弹窗**，不是同一处的两种说法。',
  'lib/ui/widgets/provider_login_panel.dart#constraints: const BoxConstraints(maxWidth: 460)':
      '★ 2026-10-19 复核**改判**（此前写的是「机制②」，实测**不成立**）。'
          '**不属于机制②**：按括号块逐字量过，`Dialog(` 的 1706 字符块内 '
          '`TextField` / `TextFormField` / `EditableText` / `InputDecoration` '
          '各 **0** 个，控件只有 Align/Column/ConstrainedBox/'
          'SingleChildScrollView/SizedBox/Text/TextButton —— '
          '正文是**确认问句**（"…源需要登录才能使用，是否已登录？"），'
          '**没有任何输入框** ⇒ 换过去**不会**抛 Material 祖先异常。'
          '★ 归类：属**裸 `Dialog(`（自建外壳）**那一类 ⇒ 归「R4 收尾换壳」。'
          '真实障碍：标题是**自绘** `Text("登录 ' r'$providerName' '")`，'
          '而 `AppGlassDialog.title` 只收 `String`，没有可对位的参数 ⇒ '
          '**属调用点改动**（把自绘标题改成 title 参数），**不需改组件**。',
  // 机制③ 内联 TextStyle 定颜色 ⇒ 被外壳 DefaultTextStyle 覆盖
  'lib/ui/widgets/download_panel.dart#删除整部剧的下载？':
      '机制③：content 是结构化 Column（含条件子项 if (p.episodeCount > 0) 与 '
          'p.fileNames.take(5) 列表），其中「此操作不可恢复。」用**内联** '
          "TextStyle(color: Colors.red) 定警示色。AppGlassDialog 的内容区被 "
          'DefaultTextStyle 统一覆盖字色/字重 ⇒ 那个红色会被冲掉，'
          '警示语义丢失。'
          '★ **这一条提醒的不只是这一处**：任何「用内联 TextStyle 定颜色」的弹窗内容，'
          '换外壳后颜色都会被覆盖 ⇒ 这是**收拢前要先查**的一个通用检查项。',
  'lib/ui/widgets/sync_panel.dart#width: 380,':
      '★★ 2026-10-19 复核：这是**两条机制叠加**，此前只写了 textAlign（分类不完整）。'
          '机制④：content 包在 `SizedBox(width:380)` 的 Column 里。'
          '机制②：content **含 3 个 `TextField`**（口令表单）⇒ 换过去**同样会抛** '
          '"require a Material widget ancestor"。'
          '★ **先解②、再解④**。'
          '⚠️ 另有一条独立问题（不在本次三条机制内，单列）：'
          '`AppGlassDialog` 内容区 `DefaultTextStyle` 写死 `textAlign: center`，'
          '会让两个输入框居中（注册表此前提过，本条保留提醒）。'
          '机制④口径：装 380 需传 `maxWidth: 428`（content 宽 = maxWidth − 48）。',
  // 机制⑤ 内容区 `DefaultTextStyle` 写死 `textAlign: center` ⇒ 多行左对齐正文被逐行居中
  'lib/ui/widgets/backup_panel.dart#builder: (ctx) => AlertDialog':
      '机制⑤：正文是**多行左对齐清单**，外壳会把每一行居中对齐。'
          'body 由 StringBuffer 逐行 writeln 拼成（约 460 字）：`·` 项目符号行、'
          '「特别注意」警示段、以及**靠行首两个空格**做续行缩进的源名列表。'
          '`AppGlassDialog` 内容区的 DefaultTextStyle 写死 `textAlign: center` ⇒ '
          '项目符号不再对齐、行首续行缩进失去意义，一段**靠左才成立**的警示清单'
          '会被逐行居中。'
          '⚠️ 如实交代另两点**不是**拦路石（免得下一个人重复查宽度/按钮）：'
          '宽度：正文 `SizedBox(width:460)` ⇒ 传 `maxWidth: 508` 即可容纳；'
          '三个按钮（继续 / 取消 / 不导入）：`actions` 是自由 Widget，可照 app_tray 自己拼 Row。'
          '⇒ 补齐「内容区 textAlign 可控（至少能左对齐）」之后才可收拢。',
};

/// 把「剥注释后的行号」还原成**原文**那一处的上下文，供特征串匹配
///
/// ★ 为什么需要它：`_bypassLines` 跑在**剥掉注释**的文本上（否则注释里记的
///   改前写法会被当成违规），而豁免的特征串写在**注释里** ⇒
///   必须在**原文**里找特征串，两者靠"同一行号"对齐。
String _rawLineAt(String file, int strippedLine) {
  final raw = File(file).readAsStringSync().split('\n');
  final code = _stripComments(File(file).readAsStringSync()).split('\n');
  final idx = strippedLine - 1;
  if (idx < 0 || idx >= code.length) return '';
  // ★ 剥注释不改变**行数**（每个换行都保留），所以下标可直接对齐。
  //   这一点是刻意的：`_stripComments` 遇到注释里的换行会补 '\n'。
  return idx < raw.length ? raw[idx] : '';
}

/// 该处是否被豁免（按「路径 + 特征串」匹配）—— ★ **双向可达**
///
/// # 为什么必须是「双向」而不是「从 AlertDialog 往下找」（2026-10-19 实测缺陷）
/// ```text
/// 第一版：`_isExempt(那行, anchor)` 只在「那行往后 6 行」里找特征串。
/// 实测两种排布都会漏：
///   ① 特征串在 AlertDialog 的**下方很远**：
///      theme_page —— AlertDialog 在 :199，而唯一字面量
///      `contentPadding: EdgeInsets.zero` 在 :214（**差 15 行**）⇒ 漏判
///   ② 特征串在**另一条** AlertDialog 附近：
///      sync_panel —— `width: 380,` 在 :1433，挨着的是 :1426 那条；
///      而 :1187 那条若登记了同一特征串也会被误判 ⇒ 关联关系必须双向验
///
/// ⇒ 现在两条都查：
///   · 从 AlertDialog 行往上/往下找特征串
///   · **并且**从特征串行往上找，确认它确实归属这条 AlertDialog
///     （往上必须能碰到该 `AlertDialog`，否则说明特征串属于另一条）
/// ```
///
/// # 「归属」的判据：特征串行往上最近的一个 `AlertDialog(` 就是它所属的那条
bool _isExempt(String file, int strippedLine, String anchorText) {
  final i = anchorText.indexOf('#');
  if (i < 0) return false;
  final path = anchorText.substring(0, i);
  final feat = anchorText.substring(i + 1);
  if (path != file) return false;

  final src = File(path).readAsStringSync().split('\n');
  final n = src.length;

  bool isBypassLine(int k) =>
      RegExp(r'(?<![A-Za-z0-9_.])(AlertDialog|Dialog|showDialog)\(')
          .hasMatch(src[k - 1]);

  bool featAt(int k) => src[k - 1].contains(feat);

  // 方向一：从这条 AlertDialog 往上/往下找特征串（窗口放宽到 ±20，
  //         真正的「关联」由下面的方向二兜底）
  for (var k = strippedLine - 20;
      k <= strippedLine + 20 && k >= 1 && k <= n;
      k++) {
    if (!featAt(k)) continue;
    // 方向二：确认这条特征串**归属于**本条 AlertDialog ——
    //         从特征串往上，最近的那个 AlertDialog 必须就是 strippedLine
    var owner = -1;
    for (var j = k; j >= 1; j--) {
      if (isBypassLine(j)) {
        owner = j;
        break;
      }
    }
    if (owner == strippedLine) return true;
  }
  return false;
}

/// 全仓 `lib/` 下所有含弹窗构造调用的 `.dart`（剥注释后）
///
/// ★ 2026-10-19：从「文件名含 dialog」改成「**全仓 lib/**」。
///   理由见 [_siteExemptions] 的注释 —— 旧范围漏掉了 13 个文件。
/// ★ 那 13 个文件里的弹窗，复核复刻本门禁口径实跑共 **15 处**（不是旧注释里的 22）。
///   2026-10-20 独立复核插桩：`SCANNED_TOTAL=15 registry=15`，15 行全 `hit=Y`
///   ⇒ 口径：**收拢 11 处 / 豁免 15 处，漏网 0**。
List<String> _dialogFiles() {
  final out = <String>[];
  void walk(Directory d) {
    for (final e in d.listSync()) {
      if (e is Directory) {
        if (e.path.endsWith('.dart_tool') || e.path.endsWith('build')) continue;
        walk(e);
      } else if (e is File && e.path.endsWith('.dart')) {
        out.add(e.path.replaceAll('\\', '/'));
      }
    }
  }

  walk(Directory('lib'));
  out.sort();
  return out;
}

/// 在 `file` 里找出所有「绕过外壳的弹窗构造」的行号
///
/// ★ 剥注释后才数（否则注释里记的改前写法会被当成违规）。
/// ⚠️ 负向前瞻排除 `showDialog` 之外的同族：`AppDialogShell(` / `showAppDialog(`。
List<int> _bypassLines(String code, String file) {
  final pats = <RegExp>[
    RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\('),
    RegExp(r'(?<![A-Za-z0-9_.])CupertinoAlertDialog\('),
    RegExp(r'(?<![A-Za-z0-9_.])Dialog\('),
    RegExp(r'(?<![A-Za-z0-9_.])showDialog\('),
    RegExp(r'(?<![A-Za-z0-9_.])showCupertinoDialog\('),
  ];
  final out = <int>[];
  final lines = code.split('\n');
  for (var i = 0; i < lines.length; i++) {
    for (final p in pats) {
      if (p.hasMatch(lines[i])) {
        out.add(i + 1);
        break;
      }
    }
  }
  return out;
}

/// 剥掉注释，只留**可执行代码**
///
/// ★ 为什么必须剥（否则门禁是假红）：
/// ```text
/// skip_marker_dialog.dart:2222 的注释里留着改前写法
///   「改前这里是自建的 `Dialog(backgroundColor: …」
/// 不剥注释的话，① 这条会对**已经修好的文件**报红 ⇒ 只能靠白名单消掉
/// ⇒ 白名单一旦为了"修门禁"而加，门禁就失效了。
/// ```
String _stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  var inString = false;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && next == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (inString) {
      out.write(c);
      if (c == r'\') {
        // 转义：下一个字符原样写入
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) inString = false;
      i++;
      continue;
    }
    // 非注释、非字符串
    if (c == '/' && next == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && next == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == '"' || c == "'") {
      inString = true;
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 从代码里抽出 `AppDialogShell(` 调用里的 `width:` / `maxHeight:` 数值
///
/// ⚠️ **只认第一层的**参数，不进嵌套的花括号/圆括号。
///
/// # 为什么必须限"第一层"（2026-10-19 实测踩到）
/// ```text
/// 第一版是"截到配平的右括号，然后在整段里找 width:" ——
/// 结果扫到的是**正文里缩略图/色点**的宽度，不是外壳的宽度：
///   provider_import_dialog.dart width=16.0   ← 那是某张封面的宽
///   source_switch_dialog.dart  width=14.0   ← 那是色点的宽
/// ⇒ 门禁对着**已经正确的文件**报红，只能靠加白名单消掉
/// ⇒ 白名单一旦为"修门禁"而加，门禁就失效了（正是本仓记过的假绿形态）。
/// ```
/// ⇒ 判据：只在 `AppDialogShell(` 的**直接实参**里找，遇到
///    `{`/`[`/`(` 就跳过整段。
({double? width, double? maxHeight, bool hasShell}) _shellArgs(String code) {
  final i = code.indexOf('AppDialogShell(');
  if (i < 0) return (width: null, maxHeight: null, hasShell: false);

  // 取 AppDialogShell( 之后、**第一层**配平右括号之前的文本，
  // 但跳过所有嵌套的 {} [] () 内容（那些属于 child / actions 的子树）
  final buf = StringBuffer();
  var depth = 1; // 已经在 AppDialogShell( 里
  var skip = 0;
  for (var j = i + 'AppDialogShell('.length; j < code.length; j++) {
    final c = code[j];
    if (skip > 0) {
      // 在嵌套结构里：只跟踪配平
      if (c == '(' || c == '{' || c == '[') skip++;
      if (c == ')' || c == '}' || c == ']') skip--;
      continue;
    }
    if (c == '(' || c == '{' || c == '[') {
      if (c == '(' && depth == 1) {
        // 需要区分：这是参数列表的延续还是嵌套调用？
        // 直接进 skip，避免把嵌套调用的同名参数算进来
        skip = 1;
        continue;
      }
      skip = 1;
      continue;
    }
    if (c == ')') {
      depth--;
      if (depth == 0) break;
      continue;
    }
    buf.write(c);
  }

  final body = buf.toString();
  final w = RegExp(r'\bwidth:\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(body);
  final h = RegExp(r'\bmaxHeight:\s*([0-9]+(?:\.[0-9]+)?)').firstMatch(body);
  return (
    width: w == null ? null : double.parse(w.group(1)!),
    maxHeight: h == null ? null : double.parse(h.group(1)!),
    hasShell: true,
  );
}

/// 一条弹窗的**实测**几何/外观（全部来自渲染树）
///
/// ⚠️ 为什么放在**文件顶层**而不是 `group()` 里：
///   Dart 不允许在函数体内声明 class（`group((){ class X{} })` 报
///   "'class' can't be used as an identifier because it's a keyword"）。
class _Meas {
  _Meas(this.name, this.rect, this.radius, this.color, this.maxHeight);
  final String name;
  final Rect rect;
  final double? radius;
  final Color? color;
  final double? maxHeight;

  @override
  String toString() => '$name(w=${rect.width.toStringAsFixed(1)}'
      ',h=${rect.height.toStringAsFixed(1)}'
      ',r=$radius,c=${color?.toARGB32().toRadixString(16)}'
      ',maxH=$maxHeight)';
}

void main() {
  group('R4 弹窗一致性', () {
    late List<String> files;

    setUpAll(() {
      files = _dialogFiles();
    });

    // ═══════════════════════════════════════════════════════════════
    //  ② 白名单必须非空（**必须第一个跑** —— 它是另外两条的前提）
    // ═══════════════════════════════════════════════════════════════
    test('② 白名单非空校验（空条款 = 假绿）', () {
      /*
       * ★ 为什么单独一条：`_bareShellWhitelist` 是 `Map`，
       *   `isEmpty` 为真时 ① 里那句 `where((f) => !wl.containsKey(...))`
       *   会把**所有**文件都当成违规 —— 看起来"门禁很严"，
       *   实际是配置丢了。本仓有过"空条款假绿"的先例。
       *
       * ⚠️ 我第一版写的是 `src.contains('const _bareShellWhitelist = ...{')`
       *    —— 那是**子串匹配**，注入「把 Map 清空成 {}」之后它**仍然为真**
       *    ⇒ 门禁没红 = 假绿（本轮注入 ② 实测抓到）。
       *    ⇒ 判据改成**读真实值**：`_bareShellWhitelist.isNotEmpty`
       *       + 每个条目的文件名真的在扫描范围内（防"写了不存在的文件"凑数）。
       */
      expect(_bareShellWhitelist, isNotEmpty,
          reason: '★★ 白名单**不许为空** —— 空 Map 会让 ① 把所有文件判违规'
              '（"红得莫名其妙"），而 ② 本身也就失去了被验证的意义。'
              '本仓有过"空条款假绿"的先例。');

      // 白名单里提到的文件必须**真实存在**（防用不存在的文件名凑数）
      for (final name in _bareShellWhitelist.keys) {
        final path = 'lib/ui/widgets/$name';
        expect(File(path).existsSync(), isTrue,
            reason: '★ 白名单里的「$name」在 lib/ui/widgets/ 下**不存在** —— '
                '这种条目什么都没豁免，只是让白名单看起来非空');
      }

      // 阴性对照：白名单里的文件**必须真的**是"不需要外壳"的那两个
      // （防止有人为了消红把自己的弹窗塞进来）
      expect(
        _bareShellWhitelist.keys.toSet(),
        {'app_dialog_shell.dart', 'app_dialog_section.dart'},
        reason: '★★ 白名单只允许这两个**非弹窗**文件。\n'
            '新增条目 = 允许某个弹窗绕过统一外壳 ⇒ 必须先在本注释里'
            '写清原因，并同步改本断言的期望集合。',
      );

      // 每条理由都要够具体（"占位"式理由等于没写）
      for (final e in _bareShellWhitelist.entries) {
        expect(e.value.trim().length, greaterThan(8),
            reason: '★ 白名单条目「${e.key}」的理由太短 —— 等于没写');
      }
    });

    // ═══════════════════════════════════════════════════════════════
    //  ④-c/d ★ 收拢后的**尺寸**与三键不溢出（Lead 第二步要求新增）
    // ═══════════════════════════════════════════════════════════════
    testWidgets('④-c ★★ 收拢后的卡片尺寸读数（钉住「换了之后长什么样」）',
        (t) async {
      /*
       * ★ Lead 要求的**新增**判据，理由：
       * ```text
       * 现有门禁只管「有没有绕过外壳」，**不管「换了之后长什么样」**。
       * 而 `AppGlassDialog.maxWidth` 默认 460（§3.5 窄弹窗档，2026-10-20 由 380 收敛）
       * ⇒ 换过去后卡片宽度从 Material 的 ~318.8 变成 460；
       *   将来若有人改 `maxWidth`，**没有任何门禁会发现**。
       * ```
       * ★ 判据形态是「换了外壳之后卡片宽度是多少」，
       *   **不是**「宽度没变」—— 460 本来就是新行为。
       * ★ 实测基准（getRect 读卡片本体那层，2026-10-20 复测）：
       *   skip_page._confirm / cache_page 删除整部 / app_tray 三键
       *   ⇒ 卡片 `maxWidth` = 460，**量到 412**（= 460 − 左右各 24 的 padding）；
       *   改前（maxWidth 380）量到的是 332。
       * ★ 为什么钉 412 而不是「跟 maxWidth 联动算」：联动算的话，
       *   有人把默认改回 380 也依然成立 ⇒ 判据失去判别力。
       */
      // ── 默认值本身：必须先落在 §3.5 白名单里（不用 pump 就能读） ──
      const probe = AppGlassDialog(
        title: '默认值探针',
        content: SizedBox(),
        actions: SizedBox(),
      );
      expect(const [460.0, 560.0, 820.0], contains(probe.maxWidth),
          reason: '★ docs/AGENTS.md §3.5：弹窗宽度只允许 460 / 560 / 820；'
              '实测 ${probe.maxWidth}（改前是 380，不在白名单里）');
      expect(probe.maxWidth, 460, reason: '★ 确认框 = §3.5「窄弹窗」档 460');
      expect(probe.maxHeight, 620,
          reason: '★ §3.5：最大高度 = 绝对值 620（改前 420 也是拍出来的数）');

      const view = Size(1280, 800);
      t.view.physicalSize = view;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      const title = '收拢基准';
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppGlassDialog(
                title: title,
                content: const Text('用于读取卡片实际尺寸的正文。'),
                actions: AppGlassDialogActions(
                  confirmLabel: '确定',
                  confirmIsDestructive: false,
                  onCancel: () {},
                  onConfirm: () {},
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      final f = find.text(title);
      expect(f, findsOneWidget, reason: '★ 没渲染出标题 ⇒ 后面全是空谈');
      RenderObject? ro = f.first.evaluate().first.renderObject;
      Rect? card;
      while (ro != null && ro.parent != null) {
        ro = ro.parent;
        if (ro is! RenderBox || !ro.hasSize) continue;
        final r = ro.localToGlobal(const Offset(0.0, 0.0)) & ro.size;
        if (r.width <= 0 || r.height <= 0) continue;
        if (r.width >= view.width - 1 && r.height >= view.height - 1) continue;
        card ??= r;
      }
      expect(card, isNotNull, reason: '★ 没量到卡片矩形');
      final w = card?.width ?? -1;
      final h = card?.height ?? -1;
      expect(w, inInclusiveRange(404, 420),
          reason: '★★ 收拢后卡片宽度 = $w，不在 [404, 420]。'
              '§3.5 窄弹窗 460 − 左右 padding 48 ⇒ 期望 412；'
              '改前（maxWidth 380）是 332。'
              '⚠️ 别改成「跟 maxWidth 联动算」—— 那样把默认改回 380 也绿。');
      expect(h, inInclusiveRange(100, 260),
          reason: '★★ 收拢后卡片高度 = $h，不在 [100, 260]。'
              '改前实测基准 2026-10-19 = 143.0。');
    });

    testWidgets('④-d ★★ 三键确认框（app_tray 形态）不许换行或溢出', (t) async {
      // ★ Lead 指令：app_tray 三键（tray/quit/null）语义与「取消+确认」不同
      //   ⇒ 用 actions: Row([...3 个 AppTextButton])；但 tray 弹窗窄，
      //   必须证明**不换行、不溢出**。
      const view = Size(1280, 800);
      t.view.physicalSize = view;
      t.view.devicePixelRatio = 1.0;
      addTearDown(t.view.reset);

      const title = '要关闭还是彻底退出？';
      await t.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: AppGlassDialog(
                title: title,
                content: const Text('最小化到托盘 / 彻底退出 / 取消'),
                actions: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    AppTextButton(
                        onPressed: () {}, child: const Text('最小化到托盘')),
                    const SizedBox(width: 4),
                    AppTextButton(
                        onPressed: () {}, child: const Text('彻底退出')),
                    const SizedBox(width: 4),
                    AppTextButton(onPressed: () {}, child: const Text('取消')),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('最小化到托盘'), findsOneWidget);
      expect(find.text('彻底退出'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(t.takeException(), isNull,
          reason: '★★ 三键确认框抛了异常 ⇒ 在窄宽度下换行/溢出了。'
              '若确实需要更宽，给 `AppGlassDialog(maxWidth: …)` 传值并更新本判据。');
    });

    // ═══════════════════════════════════════════════════════════════
    //  ④ ★ 豁免表的防空转：每条理由都必须有信息量
    // ═══════════════════════════════════════════════════════════════
    test('④ ★ 逐处豁免的理由不许是「占位话」（防空转假绿）', () {
      // ★★ 本条是**第二道**防空转：第一道（②）是「表不许空」，
      //    这道是「表里的每条**不许没内容**」——
      //    一张全填「暂时不处理」的表同样等于没登记。
      const vacuous = [
        '暂时不处理',
        '以后再说',
        '先放着',
        'TODO',
        '待定',
        '暂不处理',
        '保持现状',
      ];
      for (final e in _siteExemptions.entries) {
        final reason = e.value.trim();
        expect(reason.length, greaterThan(24),
            reason: '★ 豁免「${e.key}」的理由只有 ${reason.length} 字 —— '
                '太短，多半等于没写。'
                '要具体到「为什么它**不需要** AppDialogShell」。');
        for (final v in vacuous) {
          expect(reason.contains(v), isFalse,
              reason: '★★ 豁免「${e.key}」的理由是占位话「$v」—— '
                  '这种理由等于没登记（本轮明确不许）。');
        }
      }
    });

    test('④-b ★ 豁免的键（路径#特征串）必须指向**真实存在**的那一处', () {
      for (final key in _siteExemptions.keys) {
        // ★ 2026-10-19：键结构从「路径:行号」改成「路径#特征串」。
        //   理由见 [_siteExemptions] 的文档 —— 行号会因"在原地写注释"而漂，
        //   造成「④-b 要求有注释」与「我被禁止改那个文件」互斥的死结。
        final i = key.indexOf('#');
        expect(i > 0, isTrue,
            reason: '★ 豁免键「$key」格式不对（应为 路径#特征串）');
        final path = key.substring(0, i);
        final feat = key.substring(i + 1);
        expect(feat.trim().isNotEmpty, isTrue,
            reason: '★ 豁免键「$key」的特征串是空的');

        expect(File(path).existsSync(), isTrue,
            reason: '★★ 豁免键「$key」指向的文件**不存在** —— '
                '这种条目什么都没豁免，只是让表看起来非空');

        // 特征串必须**真的出现在该文件里**（否则是凭空登记）
        final src = File(path).readAsStringSync();
        expect(src.contains(feat), isTrue,
            reason: '★★ 豁免「$key」的特征串「$feat」在 $path 里**找不到**。\n'
                '⇒ 这条登记指向一个不存在的位置（多半是那处被改名/删除了）。\n'
                '请把特征串更新成该处现在真实存在的字面量。');

        // ★★★ 特征串必须**唯一**（Lead 第三条指令，2026-10-19）
        //
        // # 为什么这条必须有（我这一轮真踩到了）
        // ```text
        // 我给 theme_page 那处选的 `ThemePreviewBody` 在文件里出现 **3 次**
        //   （:215 用它 / :904 class 声明 / :905 构造器）
        // ⇒「它存在」成立，但「它唯一定位这一处」**不成立**
        //   ⇒ 将来别处也用它，② 会把**别的地方**误判成豁免 —— 新的假绿。
        // 同轮 `sync_panel` 的 `同步口令` 也出现 **3 次**（:605 / :1365 / :1431）。
        // ⇒ 与其"记住要验证唯一"，不如**让门禁强制**：出现 ≠ 1 次直接红。
        // ```
        var occurrences = 0;
        for (final line in src.split('\n')) {
          if (line.contains(feat)) occurrences++;
        }
        expect(occurrences, 1,
            reason: '★★ 豁免「$key」的特征串「$feat」在 $path 里出现 '
                '**$occurrences 次**，必须**恰好 1 次**。\n'
                '非唯一 ⇒ 它定位不到「这一处」，将来别处出现同名字面量时会被误判豁免。\n'
                '请换成该处**邻近且唯一**的字面量'
                '（例如紧跟 R4-EXCEPTION 注释的那行参数）。');

        // ★ 该特征串附近必须有豁免注释（证明"有人在那儿写下了理由"）
        final lines = src.split('\n');
        var foundAt = -1;
        for (var k = 0; k < lines.length; k++) {
          if (lines[k].contains(feat)) {
            foundAt = k;
            break;
          }
        }
        expect(foundAt, isNot(equals(-1)),
            reason: '★ 内部矛盾：上一条说特征串存在，这里说找不到');
        final lo = (foundAt - 14).clamp(0, lines.length);
        final hi = (foundAt + 14).clamp(0, lines.length);
        final near = lines.sublist(lo, hi).join('\n');
        expect(near.contains('R4-EXCEPTION') ||
            near.contains('刻意保留') ||
            near.contains('为什么不换') ||
            near.contains('不能换'),
            isTrue,
            reason: '★★ 豁免「$key」的特征串附近**找不到**豁免注释。\n'
                '⇒ 这条登记是"凭空登记"，门禁就等于在放行一个不存在的问题。\n'
                '请在该处附近补一行 `// R4-EXCEPTION: <理由>`。');
      }
    });

    // ═══════════════════════════════════════════════════════════════
    //  ① 不许裸 AlertDialog / Dialog + 尺寸必须落在白名单
    // ═══════════════════════════════════════════════════════════════
    test('①-b ★ 全仓逐处：绕过外壳的弹窗必须逐处登记豁免', () {
      final bad = <String>[];
      var scanned = 0;
      for (final f in files) {
        final name = f.split('/').last;
        if (_bareShellWhitelist.containsKey(name)) continue;
        final code = _stripComments(File(f).readAsStringSync());
        for (final ln in _bypassLines(code, f)) {
          scanned++;
          final key = '$f:${_rawLineAt(f, ln).trim()}';
          var hit = false;
          for (final anchor in _siteExemptions.keys) {
            if (_isExempt(f, ln, anchor)) {
              hit = true;
              break;
            }
          }
          if (hit) continue;
          bad.add(key);
        }
      }
      expect(bad, isEmpty,
          reason: '★★ 这几处**绕过**了 `AppDialogShell`，且没有在\n'
              '    `_siteExemptions` 里逐处登记理由：\n'
              '${bad.map((e) => '      · $e').join('\n')}\n'
              '规矩（AGENTS §3.5）：弹窗必须走 `AppDialogShell`。\n'
              '确实需要保留的，**在该处附近**写一行：\n'
              '    // R4-EXCEPTION: <为什么它不需要外壳，要具体>\n'
              '并把 `路径:行号` 登记进本文件的 `_siteExemptions`。\n'
              '⚠️ 不接受「暂时不处理」这种没有信息量的理由（见测试 ④）。\n'
              '本次扫描了 $scanned 处构造调用。');
    });

    test('①-b2 ★ 裸 `showDialog(` 必须为零（AGENTS §4：统一走 showAppDialog）',
        () {
      final bad = <String>[];
      for (final f in files) {
        final name = f.split('/').last;
        if (_bareShellWhitelist.containsKey(name)) continue;
        final code = _stripComments(File(f).readAsStringSync());
        for (final ln in code.split('\n').asMap().entries) {
          if (RegExp(r'(?<![A-Za-z0-9_.])showDialog\(').hasMatch(ln.value) ||
              RegExp(r'(?<![A-Za-z0-9_.])showCupertinoDialog\(')
                  .hasMatch(ln.value)) {
            bad.add('${f}:${ln.key + 1}');
          }
        }
      }
      expect(bad, isEmpty,
          reason: '★★ 这些地方直接调了裸 `showDialog(`：$bad\n'
              '弹窗入场动效由 `showAppDialog`（overlay_motion.dart）统一提供，'
              '裸调用会绕过它 ⇒ 动效不一致。\n'
              '改法：`showDialog` → `showAppDialog`。');
    });

    test('①-b3 ★ 裸 `Dialog(`（自建外壳）也必须逐处登记', () {
      final bad = <String>[];
      for (final f in files) {
        final name = f.split('/').last;
        if (_bareShellWhitelist.containsKey(name)) continue;
        final code = _stripComments(File(f).readAsStringSync());
        for (final ln in code.split('\n').asMap().entries) {
          // 判据只认**代码里**的 `Dialog(`：前面不能是标识符字符或 `.`
          //（排除 `showDialog(` / `AppDialogShell(` / `foo.Dialog(`）
          if (!RegExp(r'(?<![A-Za-z0-9_.])Dialog\(').hasMatch(ln.value)) {
            continue;
          }
          final key = '${f}:${ln.key + 1}';
          var hit = false;
          for (final anchor in _siteExemptions.keys) {
            if (_isExempt(f, ln.key + 1, anchor)) {
              hit = true;
              break;
            }
          }
          if (hit) continue;
          bad.add(key);
        }
      }
      expect(bad, isEmpty,
          reason: '★★ 这些地方自建了 `Dialog(` 外壳：$bad\n'
              '自建外壳是"宽度四种、高度三种"的来源（见 app_dialog_shell.dart 文件头）。\n'
              '改法：换成 `AppDialogShell`，尺寸用它的 width / maxHeight 参数。');
    });

    test('①-c width / maxHeight 必须落在白名单，或带 R4-EXCEPTION 注释', () {
      final violations = <String>[];
      for (final f in files) {
        final name = f.split('/').last;
        if (_bareShellWhitelist.containsKey(name)) continue;
        final raw = File(f).readAsStringSync();
        final code = _stripComments(raw);
        final args = _shellArgs(code);
        if (!args.hasShell) {
          // 没走外壳的文件已由 ①-a / ①-b 负责；这里不重复报
          continue;
        }
        final hasException = raw.contains('// R4-EXCEPTION:');

        if (args.width != null &&
            !_allowedWidths.contains(args.width!.round())) {
          if (!hasException) {
            violations.add('$name width=${args.width}');
          }
        }
        if (args.maxHeight != null &&
            !_allowedMaxHeights.contains(args.maxHeight!.round())) {
          if (!hasException) {
            violations.add('$name maxHeight=${args.maxHeight}');
          }
        }
      }
      expect(violations, isEmpty,
          reason: '★★ 这些弹窗的尺寸不在 §3.5 白名单里：$violations\n'
              '允许：width ∈ ${_allowedWidths.toList()}、'
              'maxHeight ∈ ${_allowedMaxHeights.toList()}。\n'
              '确实需要破例的，在**同一个文件**里写一行：\n'
              '    // R4-EXCEPTION: <为什么这个数不能改，以及实测依据>\n'
              '（只写"因为看起来更好"不算理由 —— 要能被下一个人验证。）');
    });

    // ═══════════════════════════════════════════════════════════════
    //  ③ 外壳的高度上限必须是绝对值 620
    // ═══════════════════════════════════════════════════════════════
    test('③ `AppDialogShell._kMaxHeight` 必须是绝对值 620', () {
      final src = File('lib/ui/widgets/app_dialog_shell.dart').readAsStringSync();
      final code = _stripComments(src);

      /*
       * ★ 这条守的是**算错方向**：改回"视口 × 0.8"是一种很容易犯的直觉错误
       *   （"按屏幕比例更自适应"），但 800×600 的测试视口下只有 480
       *   —— **比改前的 620 更矮**，内容被挤、Slider 出视口。
       *   见 `app_dialog_shell.dart` 里 `_kMaxHeight` 的注释（t70 三条红）。
       */
      final m = RegExp(r'_kMaxHeight\s*=\s*([0-9]+(?:\.[0-9]+)?)')
          .firstMatch(code);
      expect(m, isNotNull,
          reason: '★ 找不到 `_kMaxHeight = <数值>` —— 常量被改名/删掉了？');
      expect(double.parse(m!.group(1)!), 620,
          reason: '★★ `_kMaxHeight` 必须是 **620（绝对值）**，实际是 ${m.group(1)}。\n'
              '2026-10-17 的更正：改前文档写的是"视口 × 0.8"，那是**被证伪**的数：\n'
              '  800x600 测试视口下 0.8*600 = 480 < 620 ⇒ 内容被挤，t70 三条 tap 红。\n'
              '⇒ 不许改回比例式，除非同时改 AGENTS.md §3.5 并重跑 t70。');

      // 阳性对照：这个常量**真的被用**（不是定义了没人读）
      expect(RegExp(r'maxHeight\s*\?\?\s*_kMaxHeight').hasMatch(code), isTrue,
          reason: '★★ `_kMaxHeight` 必须在 `maxHeight ?? _kMaxHeight` 里被**读**——'
              '定义了却不使用 = 改了半天没生效（本仓有过这个坑）');
    });

    // ═══════════════════════════════════════════════════════════════
    //  阳性对照：三个本轮收拢的弹窗**真的**走了外壳
    // ═══════════════════════════════════════════════════════════════
    test('阳性对照：update / skip / composer 三个弹窗都走 AppDialogShell', () {
      for (final n in const [
        'update_dialog.dart',
        'skip_marker_dialog.dart',
        'source_composer_dialog.dart',
      ]) {
        final code = _stripComments(
            File('lib/ui/widgets/$n').readAsStringSync());
        expect(code.contains('AppDialogShell('), isTrue,
            reason: '★★ $n 必须走统一外壳 —— 这是 R4 的核心成果');
      }
    });
  });

  // ═════════════════════════════════════════════════════════════════════
  //  ★★★ 渲染判据（2026-10-19 补）★★★ —— 读**真实渲染结果**，不是源码
  // ═════════════════════════════════════════════════════════════════════
  //
  // # 为什么上面那组静态检查**不够**（这是本组存在的理由）
  // ```text
  // 上面 ①-a/①-b/①-c 扫的是**源码文本**。它们能证明"写了 AppDialogShell("，
  // 但证明不了"渲染出来的卡片是同一个样子"。
  // 真正决定 Owner 说的「不统一、丑」的，是**像素**：
  //   卡片实际多宽 / 什么圆角 / 什么底色 / 吃的是不是同一个高度上限。
  // 假想一种真实存在的坑（源码全对、像素不对）：
  // ```text
  //   外壳把 width 写成 SizedBox(width: w * 0.9)，
  //   或 forceDarkCard/glass 分支让底色走另一条路，
  //   或某个弹窗传的 maxHeight 悄悄吃掉了默认值
  // ⇒ ①-c 全绿，但三个弹窗并排一看就是三个尺寸。
  // ```
  //
  // # 本组的判据
  // ```text
  // ④ 三个弹窗各自真渲染一遍（真挂载、真 pump），读：
  //      · 卡片 Rect（tester.getRect）
  //      · 圆角（Material.shape 的 borderRadius）
  //      · 底色（Material.color）
  //    断言三者**逐项相等**（圆角/底色）且宽度落在 §3.5 白名单。
  // ⑤ 只有 skip_marker 允许传 maxHeight（实测反证），另两个必须吃默认。
  // ```
  //
  // ⚠️ 判据全部取自 `Material` 的**渲染实例**，不是源码常量 ——
  //    源码字符串当判据是本仓明确记过的假绿形态。
  group('R4 弹窗一致性（渲染判据）', () {
    /// 卡片 = 外壳里那层 `Material(type: card)`。
    ///
    /// ★ 为什么取「标题 Text 的最近 Material 祖先」而不是"第一个 Material"：
    ///   `AppDialogShell` 的子树里可能先出现别的 Material（如 Chip/SnackBar），
    ///   "第一个"不一定是卡片。标题栏一定在卡片里，且卡片是它的**最近** Material 祖先。
    Finder _cardFinder() {
      final shell = find.byType(AppDialogShell);
      final title = find.descendant(of: shell, matching: find.byType(Text)).first;
      final mat = find.ancestor(of: title, matching: find.byType(Material));
      return mat.first;
    }

    _Meas _measure(WidgetTester t, String name) {
      final card = _cardFinder();
      final r = t.getRect(card);
      final m = t.widget<Material>(card);
      final shape = m.shape;
      double? radius;
      if (shape is RoundedRectangleBorder) {
        // ⚠️ `material_ui` 遮蔽了 `BorderRadius` 这个名字 ⇒ 只能按 `is` 判断
        final br = shape.borderRadius;
        if (br is BorderRadius && br.topLeft == br.bottomRight) {
          radius = br.topLeft.x;
        }
      }
      final shellW = t.widget<AppDialogShell>(find.byType(AppDialogShell));
      return _Meas(name, r, radius, m.color, shellW.maxHeight);
    }

    /// ★ `key` 是**必须**的（2026-10-19 实测踩到）：
    ///   `showUpdateDialog` 走的是 **route**，而 route 挂在 `MaterialApp` 的
    ///   `Navigator` 里。连续 pump 两个形状相同的 `MaterialApp` 时，Flutter
    ///   **复用**同一个 Element 子树 ⇒ 上一个 dialog 的 route 还在 overlay 里，
    ///   `find.byType(AppDialogShell)` 命中 2 个 ⇒
    ///   `Bad state: Too many elements`（WidgetController.widget 抛的）。
    ///   给每次挂载一个**不同的 key** ⇒ 旧子树整个 dispose，Navigator 一并销毁。
    Widget _host(String keyName, Widget child) => MaterialApp(
          key: ValueKey(keyName),
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            brightness: Brightness.dark,
            fontFamily: 'Microsoft YaHei UI',
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF7C4DFF),
              brightness: Brightness.dark,
            ),
          ),
          home: Scaffold(body: Center(child: child)),
        );

    ReleaseInfo _rel() => parseReleaseJson({
          'tag_name': 'v1.1.0',
          'name': 'v1.1.0',
          'body': '## 本次更新\n\n- 修了些东西',
          'draft': false,
          'prerelease': false,
          'html_url': '',
          'published_at': null,
          'assets': [
            {
              'name': 'Sourin-Setup-1.1.0.exe',
              'size': 12345678,
              'browser_download_url': 'https://example.invalid/a.exe',
            }
          ],
        } as Map<String, dynamic>);

    setUpAll(loadRealFonts);

    setUp(() async {
      final tmp = await Directory.systemTemp.createTemp('sourin_r4');
      await UiPrefs.load(tmp.path);
      AppUpdateController.instance.loadPrefs();
      AppUpdateController.instance.debugResetAvailable();
      AppUpdateController.instance
          .debugSetDownloadState(UpdateDownloadState.idle);
    });

    /// 三个弹窗各真渲染一遍，返回实测值（按名字索引）
    Future<Map<String, _Meas>> _measureAll(WidgetTester t) async {
      final out = <String, _Meas>{};

      // update：走真实 showUpdateDialog 入口（与 app_update_ui_test 同路子）
      await setShotViewport(t, const Size(1440, 900));
      await t.pumpWidget(_host('update', Builder(builder: (ctx) => TextButton(
            onPressed: () =>
                showUpdateDialog(ctx, _rel(), platform: UpdatePlatform.windows),
            child: const Text('打开'),
          ))));
      await t.tap(find.text('打开'));
      await t.pumpAndSettle();
      out['update'] = _measure(t, 'update');

      // composer
      await setShotViewport(t, const Size(1600, 1000));
      await t.pumpWidget(_host('composer', const SourceComposerDialog()));
      await t.pumpAndSettle();
      out['composer'] = _measure(t, 'composer');

      // skip
      SourinApi.debugSkipMarkerFetcher = (p, i) async => null;
      addTearDown(() => SourinApi.debugSkipMarkerFetcher = null);
      await setShotViewport(t, const Size(1280, 800));
      await t.pumpWidget(_host('skip', const SkipMarkerDialog(
        provider: 'tyyszy',
        id: '70260',
        title: '怒鲨狂潮',
        streamUrl: 'file:///nonexistent.mp4',
        duration: Duration(seconds: 600),
      )));
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      await t.pump(const Duration(milliseconds: 50));
      out['skip'] = _measure(t, 'skip');

      return out;
    }

    testWidgets('④ 三弹窗卡片：圆角/底色一致 + 宽度落在白名单（渲染实测）',
        (t) async {
      final m = await _measureAll(t);

      // —— 宽度：必须落在 §3.5 白名单（460 窄 / 560 默认 / 820 宽）——
      for (final e in m.entries) {
        expect(_allowedWidths.contains(e.value.rect.width.round()),
            isTrue,
            reason: '★★ ${e.key} 的**卡片实测宽** = ${e.value.rect.width}，'
                '不在 §3.5 白名单 ${_allowedWidths.toList()}。\n'
                '这是 `tester.getRect` 读出来的真实渲染宽度，不是源码里的 `width:` '
                '—— 源码可能写对了而渲染被别的约束改掉。');
      }

      // —— 圆角：三者必须完全相同（实测）——
      final radii = m.values.map((x) => x.radius).toSet();
      expect(radii.length, 1,
          reason: '★★ 圆角不一致：${m.values.join(" / ")}\n'
              '三个弹窗并排看圆角不一样，正是 Owner 说的「样式不统一」。'
              '统一走 AppDialogShell 的 `Radii.rLg`。');
      expect(radii.single, isNotNull,
          reason: '★ 圆角读不到 —— `Material.shape` 不是 RoundedRectangleBorder，'
              '或 `borderRadius` 不是等角圆。外壳必须写死 Radii.rLg。');
      // 等角圆时把三档具体数值也钉住（§3.5：Radii.rLg = 22）
      expect(radii.single, 22,
          reason: '★★ 卡片圆角实测 = ${radii.single}，§3.5 规定 Radii.rLg = 22。');

      // —— 底色：三者必须完全相同（实测）——
      final colors = m.values.map((x) => x.color).toSet();
      expect(colors.length, 1,
          reason: '★★ 底色不一致：${m.values.join(" / ")}\n'
              '卡片底色必须由外壳一处决定（`surfaceContainerHighest`，'
              '玻璃档/深色档走各自的实色），不许各弹窗自己写。');
      expect(colors.single, isNotNull,
          reason: '★ 底色读不到 —— `Material.color` 是 null。'
              '不允许"透明卡片"（R3-①② 的教训：transparent 让底下色块透上来，'
              '把文字对比度打穿）。');
      // 不许透明（alpha 必须足够高，R3-①② 的实测教训）
      expect(colors.single!.a, greaterThanOrEqualTo(0.98),
          reason: '★★ 卡片底色实测 alpha = ${colors.single!.a}，'
              '必须 ≥ 0.98。R3-①② 实测：玻璃档曾用 Colors.transparent，'
              '底下高饱和色块透上来，把 #8E939B 的对比度打到 2.09:1（正文线 4.5）。');
    });

    testWidgets('⑤ 只有 skip_marker 传 maxHeight，另两个吃默认值（渲染实测）',
        (t) async {
      final m = await _measureAll(t);

      // update / composer 必须吃默认（maxHeight 字段为 null ⇒ 外壳用 _kMaxHeight）
      expect(m['update']!.maxHeight, isNull,
          reason: '★★ update_dialog 不许传 `maxHeight` —— 必须吃外壳默认的 '
              '`_kMaxHeight`（620）。实测 = ${m['update']!.maxHeight}。\n'
              '§3.5 只有在有**实测反证**时才允许覆盖，且必须在同文件写清理由。');
      expect(m['composer']!.maxHeight, isNull,
          reason: '★★ source_composer_dialog 不许传 `maxHeight` —— 必须吃默认。'
              '实测 = ${m['composer']!.maxHeight}。');

      // skip 是本轮唯一有实测反证的破例，必须传且必须是 740
      expect(m['skip']!.maxHeight, isNotNull,
          reason: '★ skip_marker_dialog 应当显式传 `maxHeight`（740）——'
              '620 会把第四行挤出视口、预览只剩 116px。'
              '若这里变 null，说明有人把破例删了。');
      expect(m['skip']!.maxHeight, 740,
          reason: '★★ skip 的 `maxHeight` 实测 = ${m['skip']!.maxHeight}，应为 740'
              '（= `kDialogMaxH`）。改这个数前先跑 '
              '`skip_history_dialog_test.dart` 与 orchestrator 系列。');

      // 高度上限的**实际生效值**也钉一下：另两个的高度必须 <= 620（默认值）
      expect(m['update']!.rect.height, lessThanOrEqualTo(620),
          reason: '★★ update 卡片高 ${m['update']!.rect.height} 超过默认上限 620');
      expect(m['composer']!.rect.height, lessThanOrEqualTo(620),
          reason: '★★ composer 卡片高 ${m['composer']!.rect.height} 超过默认上限 620');
    });
  });
}
