// ═══════════════════════════════════════════════════════════════════════
//  CS-1 · 备份「导出 → 设口令 → 导入 → 错口令 → 对口令」—— **驱动探针**
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件存在的原因
//
// CS-1 的验收一直在自报「真机 56 项通过 / 7 张截图」，但按自报路径去找
// （`t66-cs1*`）**一个文件都没有** —— 也就是说那 7 张图没落在它自称的位置上。
// 根因不在"图丢了"，而在**没人驱动得了这 5 步**：
//
// ```text
// tools/e2e_shots.ps1 只能到「页签级」（切到某个设置页、截一张），
// 而这 5 步要在同一个面板里连续输入两次口令、还要故意输错一次 ——
// 页签级脚本做不到，OS 级点击脚本又禁用（AGENTS §8）。
// ```
//
// ⇒ 本探针用**进程内**手段把这 5 步真跑一遍，并同时留下两类证据：
//   · 文件/请求事实（写没写出文件、多少字节、sha256、包内到底有没有登录态）
//   · UI 事实（面板上那时那刻**渲染出来的文字**，从 Element 树里捞）
//
// # 怎么把「系统文件对话框」换成可自动化的替身
//
// ```text
// 系统保存/打开框是**模态**的：它一直等用户点，探针点不了；也不能用
// OS 级输入注入（禁用）。所以这里替换的是 **file_selector 官方留的注入点**
//   FileSelectorPlatform.instance
// —— 不是本面板的代码。面板仍然走它自己那条真实分支：
//   导出：_doExport → _exportConsent → _pickSavePath → getSaveLocation
//   导入：_doPick   → openFile → backupInspect
//         _doImport → （含登录态时）_ImportPassphraseDialog → backupImport
// 替身只替「操作系统对话框」这个**外部环境**那一跳。
// ```
//
// ★ 这不是"测了影子实现"：业务逻辑只有一份（产品里的那份），
//   探针里**没有**任何一份平行的导入/导出实现。
//
// # 五步与判据（每步都必须两类证据同时成立）
//
// ```text
// ① 导出          面板「导出」→ 知情提示 → 设口令 → 真的落盘
//                 文件事实：文件存在 / bytes>0 / ZIP 魔数 / sha256
//                 UI 事实 ：「已导出到 …（含 1 个源的登录态，已加密…）」
// ② 设置导出口令  假口令（绝不使用任何真实凭据）
//                 文件事实：同一次导出里 credentialsIncluded=true；
//                          对照：不给口令导出的包 credentialsIncluded=false
//                 UI 事实 ：「设置导出用口令」对话框真的出现过
// ③ 导入同一文件  先删掉本机的登录态（providers=0）再导入
//                 文件事实：providers 由 0 回到 ≥1（登录态真的回来了）
//                 UI 事实 ：「导入完成」+ 结果区
// ④ 输错口令      必须被拒，且文案不撒谎
//                 文件事实：providers 仍为 0（**没有**只导一半）
//                 UI 事实 ：「口令不正确…登录态没有导入」，且没有「导入完成」
// ⑤ 再输对口令    必须成功
//                 文件事实：providers 回到 ≥1
//                 UI 事实 ：「导入完成」
// ```
//
// # 数据隔离（不许碰真实用户数据）
//
// ```text
// 必须传 --dart-define=DATA_DIR_OVERRIDE=…/round66_cs1/<run>
// 路径里不含 round66_cs1 ⇒ 直接 exit(3)，一条判据都不跑。
// 本探针会**真的**写备份包、真的删/写 plugins/.data 下的一个假登录态。
// ```
//
// # 用法（由持有 build 窗口的人执行）
//
// ```powershell
// flutter build windows --release -t lib/t107_cs1_flow_probe.dart `
//   "--dart-define=DATA_DIR_OVERRIDE=D:\...\.probe\round66_cs1\run1"
// .\build\windows\x64\runner\Release\sourin_spike.exe
// ```
// 产物：`<数据目录>/shots/cs1_*.png`（1280×800）与
//       `<数据目录>/cs1-report.txt`（人读）+ 同目录 `cs1-lines.txt`（机读）。
//
// ⚠️ 本文件是**探针**（临时脚手架），不是产品代码：它只 import 产品文件、
//    不改它们。它**不**参与 `lib/main.dart` 的启动路径。

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
// ★ 只为了拿 `FileSelectorPlatform.instance` 这个**官方注入点**（替掉系统对话框）。
//   它是 `file_selector` 的传递依赖，不在 pubspec 的直接依赖里 ⇒ 只对本行 ignore。
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';
import 'package:window_manager/window_manager.dart';

import 'core/device.dart';
import 'core/ffi.dart';
import 'core/sourin_api.dart';
import 'core/ui_prefs.dart';
import 'shell.dart';
import 'ui/app_theme.dart';
import 'ui/settings_page.dart';
import 'ui/widgets/backup_panel.dart';

// ══════════════════════════════════════════════════════════════════════
//  常量 / 全局
// ══════════════════════════════════════════════════════════════════════

/// 本探针**唯一**允许使用的口令（假值，绝不来自任何真实凭据）
const String kFakePass = 'cs1-probe-pass-1';

/// 故意输错时用的口令（与 [kFakePass] 不同，长度也够）
const String kWrongPass = 'cs1-wrong-pass-9';

/// 撒进隔离目录的**假**登录态所属的源 id（不是任何真实站点）
const String kFakeProvider = '__cs1_probe__';

int pass = 0;
int fail = 0;

/// 人读的全部行（最后落 cs1-report.txt）
final List<String> _lines = <String>[];

/// 机读行（最后落 cs1-lines.txt）
final List<String> _machine = <String>[];

final GlobalKey _rootKey = GlobalKey();

/// 截图目录（`<数据目录>/shots`）
late Directory _shotDir;

/// 同步落盘的进度追踪文件
///
/// # 为什么不能用 debugPrint 当唯一通道
/// ```text
/// Windows 上 Flutter 产物是 **GUI 子系统** exe ⇒ 不挂控制台 ⇒
/// debugPrint 写进的 stdout **没有接收端**（实测 `*> out.txt` 得到 0 字节）。
/// 探针卡死时进程不会正常退出 ⇒ 只有每行 flush 的追踪文件才能说明"卡在哪"。
/// ```
final List<String> _traceBuf = <String>[];

File get _traceFile => File('${_shotDir.parent.path}${Platform.pathSeparator}'
    'cs1-trace.txt');

void trace(String s) {
  final line = '${DateTime.now().toIso8601String()}  $s';
  _traceBuf.add(line);
  try {
    _traceFile.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {
    // 追踪失败绝不能影响主流程
  }
}

void say(String s) {
  _lines.add(s);
  debugPrint('[CS1] $s');
}

void note(String s) => say('·  $s');

void ok(String label, bool cond, [String extra = '']) {
  if (cond) {
    pass++;
  } else {
    fail++;
  }
  say('${cond ? '✓' : '✗'} $label${extra.isEmpty ? '' : '   $extra'}');
}

// ══════════════════════════════════════════════════════════════════════
//  纯函数（可被 flutter test 直接自检，见文件尾注释）
// ══════════════════════════════════════════════════════════════════════

/// sha256 的**前 16 位十六进制**（机器可读行里用它做"同一份文件"的指纹）
String cs1Sha256Short(List<int> bytes) =>
    sha256.convert(bytes).toString().substring(0, 16);

/// 机器可读行。
///
/// 格式（与派活约定逐字一致，便于脚本 `grep`）：
/// ```text
/// CS1|<step>|file=<path>|bytes=<n>|sha256=<16>|ui=<断言>|verdict=OK|BAD
/// ```
String cs1LogLine({
  required String step,
  String file = '—',
  int? bytes,
  String? sha256,
  required String ui,
  required bool verdict,
}) {
  final line = 'CS1|$step'
      '|file=$file'
      '|bytes=${bytes ?? -1}'
      '|sha256=${sha256 ?? '—'}'
      '|ui=${ui.replaceAll('\n', ' ').replaceAll('|', '/')}'
      '|verdict=${verdict ? 'OK' : 'BAD'}';
  _machine.add(line);
  say(line);
  return line;
}

/// 双证据判据：**文件/请求事实** 与 **UI 事实** 必须同时成立才算 OK。
///
/// 只断言其中一个都会给出假绿：
/// ```text
/// 只看文件事实 → 面板可能根本没走真实入口（例如探针自己调 API 写了个包）
/// 只看 UI 事实 → 文案对了但数据没回来（"导入完成"但登录态还在包里）
/// ```
bool cs1BothFacts({required bool fileFact, required bool uiFact}) =>
    fileFact && uiFact;

// ══════════════════════════════════════════════════════════════════════
//  Element 树 / 几何 / 帧 / 事件
// ══════════════════════════════════════════════════════════════════════

Element? findWidget(Element root, bool Function(Widget w) test) {
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    if (test(e.widget)) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(root);
  return hit;
}

List<Element> findAll(Element root, bool Function(Widget w) test) {
  final out = <Element>[];
  void walk(Element e) {
    if (test(e.widget)) out.add(e);
    e.visitChildren(walk);
  }

  walk(root);
  return out;
}

Element? findText(Element root, String text) =>
    findWidget(root, (w) => w is Text && w.data == text);

Element? findTextContains(Element root, String needle) =>
    findWidget(root, (w) => w is Text && (w.data?.contains(needle) ?? false));

void collectTexts(Element root, List<String> out) {
  void walk(Element e) {
    final w = e.widget;
    if (w is Text) {
      final d = w.data;
      if (d != null) out.add(d);
    } else if (w is RichText) {
      // 少数文字走 RichText —— 也要收，否则"UI 里有没有这句话"会漏判
      final p = w.text.toPlainText();
      if (p.isNotEmpty) out.add(p);
    }
    e.visitChildren(walk);
  }

  walk(root);
}

List<String> textsIn(Element? scope) {
  if (scope == null) return const <String>[];
  final out = <String>[];
  collectTexts(scope, out);
  return out;
}

/// 顺着父链找最近的 [type] 祖先（用来把「对话框」与「面板」分开取范围）
Element? ancestorOfType(Element e, Type type) {
  Element? hit;
  e.visitAncestorElements((a) {
    if (a.widget.runtimeType == type) {
      hit = a;
      return false;
    }
    return true;
  });
  return hit;
}

Rect? rectOf(Element? e) {
  if (e == null) return null;
  final ro = e.findRenderObject();
  if (ro is! RenderBox || !ro.hasSize) return null;
  return ro.localToGlobal(Offset.zero) & ro.size;
}

String rectStr(Rect? r) => r == null
    ? 'null'
    : '(${r.left.toStringAsFixed(1)},${r.top.toStringAsFixed(1)})'
        '-(${r.right.toStringAsFixed(1)},${r.bottom.toStringAsFixed(1)})'
        ' ${r.width.toStringAsFixed(1)}x${r.height.toStringAsFixed(1)}';

bool _subtreeHasText(Element e, String s) {
  var hit = false;
  void walk(Element x) {
    if (hit) return;
    final w = x.widget;
    if (w is Text && w.data == s) hit = true;
    x.visitChildren(walk);
  }

  walk(e);
  return hit;
}

/// 在 [scope] 子树里按**可见文字**找按钮（而不是按类型顺序猜）。
///
/// 产品里的按钮有两类：填充（[FilledButton]）与描边（[OutlinedButton]）。
/// `label` 传精确文字（`Text.data == label`）。
Element? buttonByText(
  Element? scope,
  String label, {
  bool filled = true,
}) {
  if (scope == null) return null;
  Element? hit;
  void walk(Element e) {
    if (hit != null) return;
    final w = e.widget;
    final isBtn = filled ? (w is FilledButton) : (w is OutlinedButton);
    if (isBtn && _subtreeHasText(e, label)) {
      hit = e;
      return;
    }
    e.visitChildren(walk);
  }

  walk(scope);
  return hit;
}

ScrollableState? scrollableIn(Element scope) {
  final el = findWidget(scope, (w) => w is Scrollable);
  if (el is StatefulElement && el.state is ScrollableState) {
    return el.state as ScrollableState;
  }
  return null;
}

/// ★ 必须带 timeout：万一没人请求帧，`endOfFrame` 会一直挂着 ⇒ 静默停住。
Future<void> pumpFrame() async {
  SchedulerBinding.instance.scheduleFrame();
  await SchedulerBinding.instance.endOfFrame
      .timeout(const Duration(seconds: 2), onTimeout: () {});
}

Future<bool> waitUntil(
  bool Function() cond, {
  Duration timeout = const Duration(seconds: 25),
  String label = '',
}) async {
  final t0 = DateTime.now();
  while (DateTime.now().difference(t0) < timeout) {
    if (cond()) return true;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await pumpFrame();
  }
  if (label.isNotEmpty) note('等待超时: $label');
  return cond();
}

/// ★ 两次事件之间必须让出事件循环 —— 同一 microtask 里连发 down/up 会漏掉 up。
Future<void> tapAt(Offset globalPos) async {
  WidgetsBinding.instance.handlePointerEvent(PointerDownEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
    buttons: kPrimaryMouseButton,
  ));
  await Future<void>.delayed(const Duration(milliseconds: 40));
  WidgetsBinding.instance.handlePointerEvent(PointerUpEvent(
    pointer: 91,
    position: globalPos,
    kind: PointerDeviceKind.mouse,
  ));
}

/// `onTap` 要过 `kDoubleTapTimeout`(300ms) 才派发 ⇒ 多等 700ms。
Future<void> tapAndSettle(Offset globalPos) async {
  await tapAt(globalPos);
  await Future<void>.delayed(const Duration(milliseconds: 700));
  await pumpFrame();
}

/// 点一个元素（先把它滚进安全带再点）。
Future<bool> tapElement(
  Element rootEl,
  Element? target, {
  String label = '',
}) async {
  if (target == null) {
    note('点不到「$label」：元素不在树上');
    return false;
  }
  final sc = _settingsScope(rootEl);
  await bringIntoBand(sc ?? rootEl, () => target);
  final r = rectOf(target);
  if (r == null) {
    note('点不到「$label」：没有尺寸（可能被裁剪/未布局）$r');
    return false;
  }
  trace('点「$label」 rect=${rectStr(r)}');
  await tapAndSettle(r.center);
  await Future<void>.delayed(const Duration(milliseconds: 400));
  await pumpFrame();
  return true;
}

/// 把元素滚进内容带（避开标题栏 / 底部条）。
Future<bool> bringIntoBand(
  Element scope,
  Element? Function() find, {
  double lo = 130,
  double hi = 700,
  int tries = 10,
}) async {
  final pos = scrollableIn(scope)?.position;
  if (pos == null || !pos.hasContentDimensions) return rectOf(find()) != null;
  for (var i = 0; i < tries; i++) {
    final r = rectOf(find());
    if (r != null && r.center.dy >= lo && r.center.dy <= hi) return true;
    if (r == null) {
      final want = (pos.pixels + 240).clamp(0.0, pos.maxScrollExtent);
      if ((want - pos.pixels).abs() < 1) return false;
      pos.jumpTo(want);
    } else {
      final delta = r.center.dy - (lo + hi) / 2;
      final want = (pos.pixels + delta).clamp(0.0, pos.maxScrollExtent);
      if ((want - pos.pixels).abs() < 1) return false;
      pos.jumpTo(want);
    }
    await pumpFrame();
    await Future<void>.delayed(const Duration(milliseconds: 90));
  }
  return rectOf(find()) != null;
}

Element? _settingsScope(Element rootEl) =>
    findWidget(rootEl, (w) => w is SettingsPage);

// ══════════════════════════════════════════════════════════════════════
//  口令输入（**进程内**事件流，不用 OS 级输入）
// ══════════════════════════════════════════════════════════════════════

/// 把口令填进 [scope] 里的那个密码框。
///
/// # 为什么走 `EditableTextState.updateEditingValue`
/// ```text
/// 系统输入法（IME）那一层在真机上由 OS 提供，探针拿不到也不需要 ——
/// `updateEditingValue` 正是 IME **输入结果**进入 Flutter 的入口
/// （flutter_test 的 enterText 最终也是这条路）。
/// 它会同时更新可见文字（截图里能看到圆点）并触发 `TextField.onChanged`，
/// 而产品逻辑只读 onChanged 传来的值 ⇒ 走的仍是产品自己那条路。
/// ```
///
/// 返回 `(是否成功, 用了哪条通道)` —— 通道要如实写进读数，
/// 因为"只调了 onChanged（界面看不到字）"与"真的进了编辑值"证据强度不同。
Future<(bool, String)> typePassphrase(Element? scope, String text) async {
  if (scope == null) return (false, 'no-scope');
  final et = findWidget(scope, (w) => w is EditableText);
  if (et is StatefulElement && et.state is EditableTextState) {
    final st = et.state as EditableTextState;
    try {
      st.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ));
      await Future<void>.delayed(const Duration(milliseconds: 120));
      await pumpFrame();
      return (true, 'EditingValue');
    } catch (e) {
      note('updateEditingValue 失败: $e');
    }
  }
  // 退路：只触发产品自己的 onChanged（界面不会显示字，读数里会标明）
  final tf = findWidget(scope, (w) => w is TextField);
  if (tf != null) {
    final w = tf.widget as TextField;
    w.onChanged?.call(text);
    return (true, 'onChanged-only');
  }
  return (false, 'no-field');
}

// ══════════════════════════════════════════════════════════════════════
//  替身：只替「操作系统文件对话框」这一跳
// ══════════════════════════════════════════════════════════════════════

/// 假的**保存**对话框：不弹窗，直接返回 [targetPath]。
///
/// ⚠️ 必须 `extends`（不是 `implements`）—— file_selector 的 platform
///    interface 用 token 校验实现方式，`implements` 会在赋值时抛
///    `AssertionError`（`plugin_platform_interface` 的 verify）。
class _SaveStub extends FileSelectorPlatform {
  _SaveStub(this.targetPath);

  final String targetPath;

  /// 被调用次数 —— 这是"面板真的走到了选路径那一步"的唯一证据
  int calls = 0;

  /// 面板传进来的建议文件名（证明默认文件名真的流到了对话框）
  String? lastSuggestedName;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    calls++;
    lastSuggestedName = options.suggestedName;
    return FileSaveLocation(targetPath);
  }
}

/// 假的**打开**对话框：不弹窗，直接返回 [filePath] 那份文件。
class _OpenStub extends FileSelectorPlatform {
  _OpenStub(this.filePath);

  final String filePath;

  int calls = 0;

  @override
  Future<XFile?> openFile({
    List<XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    calls++;
    return XFile(filePath);
  }
}

// ══════════════════════════════════════════════════════════════════════
//  截图
// ══════════════════════════════════════════════════════════════════════

class Shot {
  Shot(this.path, this.w, this.h, this.colors);

  final String path;
  final int w;
  final int h;
  final int colors;

  bool get is1280x800 => w == 1280 && h == 800;
}

/// 抓一帧并落成 PNG。
///
/// # 为什么按 `1280/size.width` 算 pixelRatio 而不是写死 1.0
/// ```text
/// 窗口尺寸是**逻辑**像素；显示器 DPR≠1 时 `pixelRatio: 1.0` 产出的是
/// 逻辑尺寸（1024×640），不是约定的 1280×800 ⇒ 交付前先把物理尺寸对齐，
/// 再断言 w/h 精确等于 1280×800（断言失败就记为 BAD，不许默默放过）。
/// ```
Future<Shot> shoot(String name) async {
  final ctx = _rootKey.currentContext;
  if (ctx == null) throw StateError('root context 为 null');
  final ro = ctx.findRenderObject();
  if (ro is! RenderRepaintBoundary) {
    throw StateError('根不是 RenderRepaintBoundary，而是 ${ro.runtimeType}');
  }
  final size = ro.size;
  final ratio = size.width <= 0 ? 1.0 : 1280.0 / size.width;
  final image = await ro.toImage(pixelRatio: ratio);
  final raw = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
  final png = await image.toByteData(format: ui.ImageByteFormat.png);
  if (raw == null || png == null) throw StateError('toByteData 返回 null');

  final w = image.width;
  final h = image.height;
  final path = '${_shotDir.path}${Platform.pathSeparator}$name';
  await File(path).writeAsBytes(png.buffer.asUint8List(), flush: true);

  // 仪器自检：每 9 像素采样一次数颜色（全黑/全白的退化图只有 1~2 色）
  final bytes = raw.buffer.asUint8List();
  final set = <int>{};
  for (var y = 0; y < h; y += 9) {
    for (var x = 0; x < w; x += 9) {
      final o = y * w * 4 + x * 4;
      set.add((bytes[o] << 16) | (bytes[o + 1] << 8) | bytes[o + 2]);
    }
  }
  final shot = Shot(path, w, h, set.length);
  note('截图 $name → ${w}x$h，颜色种数 ${shot.colors}');
  return shot;
}

// ══════════════════════════════════════════════════════════════════════
//  数据目录 / 假登录态
// ══════════════════════════════════════════════════════════════════════

Future<String> resolveDataDir() async {
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    stderr.writeln('CS1|bad-dir|reason=DATA_DIR_OVERRIDE 未设置|verdict=BAD');
    exit(3);
  }
  // 安全阀：只允许写在明确的隔离目录下（与 t105/t106 同一条约定）
  if (!override.toLowerCase().contains('round66_cs1')) {
    stderr.writeln(
        'CS1|bad-dir|reason=数据目录必须包含 round66_cs1|path=$override|verdict=BAD');
    exit(3);
  }
  final d = Directory(override);
  if (!await d.exists()) await d.create(recursive: true);
  return d.path;
}

Directory _pluginsDataDir(String dataDir) => Directory(
    '$dataDir${Platform.pathSeparator}plugins${Platform.pathSeparator}.data');

File _seedFile(String dataDir) => File('${_pluginsDataDir(dataDir).path}'
    '${Platform.pathSeparator}$kFakeProvider.json');

/// 撒一份**假**登录态，让导出流程走到「这个东西含登录态」那一步。
///
/// # 为什么必须撒
/// ```text
/// `_exportConsent()` 的第一句是 `credentialsStatus().providers == 0`
///   ⇒ 直接跳过整个知情提示与口令设置（"别拿空警告烦用户"）。
/// 隔离目录里本来一个源都没登录过 ⇒ 不撒就永远测不到 ②③④⑤ 步。
/// 这里撒的是 **假 token**（provider id 也带 __cs1_probe__ 前缀），
/// 不来自任何真实账号，也不出这个隔离目录。
/// ```
Future<void> seedFakeCredential(String dataDir) async {
  final dir = _pluginsDataDir(dataDir);
  if (!await dir.exists()) await dir.create(recursive: true);
  final f = _seedFile(dataDir);
  await f.writeAsString(
    const JsonEncoder.withIndent('  ').convert(<String, Object>{
      'cookie': 'fake-probe-token-not-a-real-account',
      'savedAt': '2026-10-20T00:00:00Z',
    }),
    flush: true,
  );
  trace('已撒假登录态 ${f.path} (${await f.length()} B)');
}

Future<void> forgetFakeCredential(String dataDir) async {
  final f = _seedFile(dataDir);
  if (await f.exists()) {
    await f.delete();
    trace('已删掉假登录态 ${f.path}');
  }
}

Future<int> providersNow() async {
  try {
    final s = await SourinApi.credentialsStatus();
    return s.providers;
  } catch (e) {
    note('credentialsStatus 读失败: $e');
    return -1;
  }
}

// ══════════════════════════════════════════════════════════════════════
//  main
// ══════════════════════════════════════════════════════════════════════

/// 看门狗：探针卡死时也要留下读数（外面否则只看到"超时"）。
void armWatchdog() {
  Timer(const Duration(minutes: 6), () {
    trace('★★ WATCHDOG 触发（6 分钟未跑完）⇒ 强制落盘并退出');
    try {
      _writeReports();
    } catch (_) {}
    exit(9);
  });
}

void _writeReports() {
  _traceBuf.add('---- 结果：OK=$pass BAD=$fail');
  File('${_shotDir.parent.path}${Platform.pathSeparator}cs1-report.txt')
      .writeAsStringSync('${_lines.join('\n')}\n---- 结果：OK=$pass BAD=$fail\n',
          flush: true);
  File('${_shotDir.parent.path}${Platform.pathSeparator}cs1-lines.txt')
      .writeAsStringSync('${_machine.join('\n')}\n', flush: true);
}

Future<Never> finish(int code) async {
  try {
    _writeReports();
  } catch (e) {
    debugPrint('[CS1] 报告写入失败: $e');
  }
  say('');
  say('---- 结果：OK=$pass BAD=$fail');
  debugPrint('[CS1] RESULT ok=$pass bad=$fail');
  await Future<void>.delayed(const Duration(milliseconds: 250));
  exit(code);
}

/*
 * ★★ 外层守卫：`main()` 里任何**逃出的异常**都必须留下读数。
 *    GUI 子系统的 exe 没有 stdout（见 `trace` 的注释）⇒
 *    try/catch 把异常与栈同步写进追踪文件是唯一的诊断通道。
 */
Future<void> main() async {
  try {
    await _main();
  } catch (e, st) {
    trace('★★ main() 逃出异常：$e');
    trace('$st');
    try {
      _writeReports();
    } catch (_) {}
    exit(2);
  }
}

Future<void> _main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final dir = await resolveDataDir();
  _shotDir = Directory('$dir${Platform.pathSeparator}shots');
  if (!await _shotDir.exists()) await _shotDir.create(recursive: true);
  trace('══════ main() 进入，数据目录 = $dir ══════');
  armWatchdog();

  await UiPrefs.load(dir);
  // 强制浅色：去掉"跑的那一刻系统主题"这个外部变量（写的是隔离目录）
  AppTheme.setMode(AppThemeMode.light);

  String? coreError;
  try {
    final r = await SourinCore.startAsync(dir);
    trace('SourinCore.startAsync = $r');
  } catch (e) {
    coreError = e.toString();
    trace('★ 核心启动失败 = $coreError');
  }

  try {
    await Device.init();
    trace('Device.init 完成');
  } catch (e) {
    trace('Device.init 失败（继续）: $e');
  }

  try {
    MediaKit.ensureInitialized();
    trace('MediaKit.ensureInitialized 完成');
  } catch (e) {
    trace('MediaKit.ensureInitialized 失败（继续）: $e');
  }

  try {
    await LiquidGlassWidgets.initialize();
    trace('LiquidGlassWidgets.initialize 完成');
  } catch (e) {
    trace('LiquidGlassWidgets.initialize 失败（继续）: $e');
  }

  if (Platform.isWindows) {
    await windowManager.ensureInitialized();
    /*
     * 窗口选项逐字复刻生产（`titleBarStyle.hidden` 会去掉系统标题栏，
     * 自绘标题栏才占得住顶部约 39px；否则点击坐标全部错位）。
     * ⚠️ 刻意**不**调 `windowManager.focus()` —— 会抢别人的焦点。
     * ★ 必须 show()：窗口不可见时引擎可能整帧不产出。
     */
    const windowOptions = WindowOptions(
      size: Size(1280, 800),
      minimumSize: Size(900, 600),
      center: true,
      titleBarStyle: TitleBarStyle.hidden,
      backgroundColor: Colors.transparent,
      title: 'CS-1 备份流程驱动',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.show();
    });
    await Future<void>.delayed(const Duration(milliseconds: 600));
    trace('窗口已 show');
  }

  // ★ 外壳 = 生产本体（不是复刻）
  runApp(RepaintBoundary(
    key: _rootKey,
    child: SourinApp(coreError: coreError, coreDataDir: dir),
  ));
  trace('runApp 之后 ⇒ 进 _body');

  try {
    await _body(dir);
  } catch (e, st) {
    ok('探针异常逃出（必须报出来，不能静默停住）', false, '$e');
    say('$st');
    await finish(1);
  }
}

// ══════════════════════════════════════════════════════════════════════
//  正文
// ══════════════════════════════════════════════════════════════════════

Future<void> _body(String dir) async {
  say('');
  say('──────── ⓪ 仪器自检 ────────');

  ok('⓪ 数据目录是隔离目录（绝不写真实用户库）',
      dir.toLowerCase().contains('round66_cs1'), dir);
  if (!dir.toLowerCase().contains('round66_cs1')) {
    say('★ 不是隔离目录 ⇒ 立刻中止');
    await finish(1);
  }

  try {
    say('核心版本 = ${SourinApi.version}');
  } catch (e) {
    note('版本读不到: $e');
  }

  final shellUp = await waitUntil(
    () => debugShellKey.currentState != null,
    timeout: const Duration(seconds: 45),
    label: 'shell 挂载',
  );
  ok('⓪ 生产外壳挂载（debugShellKey.currentState != null）', shellUp);
  final root0 = _rootKey.currentContext;
  if (!shellUp || root0 == null) {
    say('★ 外壳没起来 ⇒ 中止');
    await finish(1);
  }
  final rootEl = root0 as Element;
  await Future<void>.delayed(const Duration(seconds: 2));
  await pumpFrame();

  // ── 进「备份与恢复」二级页 ─────────────────────────────────────────
  say('');
  say('──────── ⓪ 进「备份与恢复」二级页 ────────');

  final dynamic shell = debugShellKey.currentState;
  shell.debugSwitchTo(AppTab.settings);
  await Future<void>.delayed(const Duration(milliseconds: 1500));
  await pumpFrame();

  final settingsUp = await waitUntil(
    () => findText(rootEl, '内容源、网络与同步') != null,
    timeout: const Duration(seconds: 30),
    label: '设置页页头',
  );
  ok('⓪ 设置页已渲染', settingsUp);
  if (!settingsUp) await finish(1);

  Element? entryFinder() =>
      findText(rootEl, '备份与恢复') ?? findTextContains(rootEl, '导出 / 导入本机数据');
  final settingsEl = _settingsScope(rootEl);
  final entryIn = await bringIntoBand(settingsEl ?? rootEl, entryFinder);
  final entryEl = entryFinder();
  ok('⓪ 入口行可达', entryIn && entryEl != null, rectStr(rectOf(entryEl)));
  if (!entryIn || entryEl == null) {
    say('★ 入口行点不到 ⇒ 中止');
    await finish(1);
  }
  await tapElement(rootEl, entryEl, label: '备份与恢复');

  final panelUp = await waitUntil(
    () => findWidget(rootEl, (w) => w is BackupPanel) != null,
    timeout: const Duration(seconds: 25),
    label: 'BackupPanel 挂载',
  );
  ok('⓪ 点了入口行 ⇒ BackupPanel 真的挂上来了', panelUp);
  if (!panelUp) await finish(1);
  final panelEl = findWidget(rootEl, (w) => w is BackupPanel)!;
  await Future<void>.delayed(const Duration(milliseconds: 800));
  await pumpFrame();

  final panelShot = await shoot('cs1_00_panel.png');
  ok('⓪ 截图是 1280×800', panelShot.is1280x800,
      '${panelShot.w}x${panelShot.h}');

  // ── ① 导出（产品真实入口）────────────────────────────────────────
  say('');
  say('──────── ① 导出 ────────');

  // 起点：隔离目录里还没有登录态
  final providers0 = await providersNow();
  note('起点 providers = $providers0');
  await seedFakeCredential(dir);
  final providers1 = await providersNow();
  ok('① 撒入假登录态后 providers ≥ 1（否则知情提示与口令步根本不会出现）',
      providers1 >= 1, 'providers=$providers1');

  final exportPath = '$dir${Platform.pathSeparator}cs1_backup.sourin.zip';
  final saveStub = _SaveStub(exportPath);
  FileSelectorPlatform.instance = saveStub;

  final exportBtn = buttonByText(panelEl, '导出');
  ok('① 面板上有「导出」按钮（填充按钮）', exportBtn != null,
      rectStr(rectOf(exportBtn)));
  await tapElement(rootEl, exportBtn, label: '导出');

  // 知情提示（本机有登录态才会出现）
  final consentUp = await waitUntil(
    () => findText(rootEl, '这个备份文件含登录态') != null,
    timeout: const Duration(seconds: 15),
    label: '含登录态知情提示',
  );
  ok('① 出现「这个备份文件含登录态」提示（说明它知道包里有凭据）', consentUp);
  if (!consentUp) await finish(1);
  final consentShot = await shoot('cs1_01_export_consent.png');
  ok('① 知情提示截图是 1280×800', consentShot.is1280x800,
      '${consentShot.w}x${consentShot.h}');

  final consentTexts = textsIn(rootEl);
  ok('① 提示里写清了「要加密这些登录态吗？」',
      consentTexts.any((t) => t.contains('要加密这些登录态吗')));
  ok('① 提示里写清了「口令不会进包」',
      consentTexts.any((t) => t.contains('不会') && t.contains('进包')));

  // ── ② 设口令（假口令）──────────────────────────────────────────────
  say('');
  say('──────── ② 设置导出口令 ────────');

  final encryptBtn = buttonByText(rootEl, '设口令并加密');
  await tapElement(rootEl, encryptBtn, label: '设口令并加密');
  final passUp = await waitUntil(
    () => findText(rootEl, '设置导出用口令') != null,
    timeout: const Duration(seconds: 15),
    label: '设置导出用口令对话框',
  );
  ok('② 出现「设置导出用口令」对话框', passUp);
  if (!passUp) await finish(1);
  final passTitleEl = findText(rootEl, '设置导出用口令');
  final passDialogEl = passTitleEl == null
      ? null
      : (ancestorOfType(passTitleEl, AlertDialog) ?? rootEl);

  final (typed, typedVia) = await typePassphrase(passDialogEl, kFakePass);
  ok('② 口令已填入（假口令，长度 ${kFakePass.length}）', typed, 'via=$typedVia');
  final passShot = await shoot('cs1_02_passphrase.png');
  ok('② 口令对话框截图是 1280×800', passShot.is1280x800,
      '${passShot.w}x${passShot.h}');

  final dialogExportBtn = buttonByText(passDialogEl, '导出');
  await tapElement(rootEl, dialogExportBtn, label: '对话框里的「导出」');

  // 面板真的走了"选路径"那一跳（替身点数），并真的落了盘
  final saved = await waitUntil(
    () => saveStub.calls >= 1 && File(exportPath).existsSync(),
    timeout: const Duration(seconds: 60),
    label: '导出落盘',
  );
  final exportFile = File(exportPath);
  final exitBytes = exportFile.existsSync() ? exportFile.lengthSync() : -1;
  final exportSha = exportFile.existsSync()
      ? cs1Sha256Short(exportFile.readAsBytesSync())
      : '—';
  note('导出：替身 calls=${saveStub.calls} 建议名=${saveStub.lastSuggestedName}');
  note('导出产物 $exportPath  bytes=$exitBytes  sha256=$exportSha');

  var isZip = false;
  if (exportFile.existsSync()) {
    final head = exportFile.openSync()..setPositionSync(0);
    final magic = head.readSync(4);
    head.closeSync();
    isZip = magic.length == 4 &&
        magic[0] == 0x50 &&
        magic[1] == 0x4B &&
        magic[2] == 0x03 &&
        magic[3] == 0x04;
  }
  ok('① 导出产物是合法 ZIP（魔数 PK\\x03\\x04）', isZip);

  // UI 事实：面板自己的成功回执
  final doneUp = await waitUntil(
    () => textsIn(panelEl).any((t) => t.contains('已导出到')),
    timeout: const Duration(seconds: 30),
    label: '导出成功回执',
  );
  final doneText = textsIn(panelEl).firstWhere(
    (t) => t.contains('已导出到'),
    orElse: () => '',
  );
  ok('① 面板显示「已导出到 …」（UI 事实）', doneUp, doneText);
  final doneShot = await shoot('cs1_03_export_done.png');
  ok('① 导出完成截图是 1280×800', doneShot.is1280x800,
      '${doneShot.w}x${doneShot.h}');

  // 包内真的含登录态（文件事实）
  var inspected = false;
  var credIncluded = false;
  var credProviders = 0;
  try {
    final info = await SourinApi.backupInspect(exportPath);
    inspected = info.version > 0;
    credIncluded = info.credentials.included;
    credProviders = info.credentials.providers;
    note('检视：v${info.version} device=${info.deviceId} '
        'credentials.included=$credIncluded providers=$credProviders');
  } catch (e) {
    note('检视失败: $e');
  }
  ok('② 包内确实含「加密后的登录态」（credentialsIncluded=true）',
      inspected && credIncluded, 'providers=$credProviders');

  cs1LogLine(
    step: '1_export',
    file: exportPath,
    bytes: exitBytes,
    sha256: exportSha,
    ui: doneText.isEmpty ? '面板回执缺失' : '面板回执=已导出到',
    verdict: cs1BothFacts(
      fileFact: saved && exitBytes > 0 && isZip && credIncluded,
      uiFact: doneUp,
    ),
  );

  // ── ②' 对照：不给口令的包不含登录态（证明②的口令真的起作用）────────
  say('');
  say('──────── ②′ 对照：不给口令 ⇒ 包里不含登录态 ────────');
  final plainPath = '$dir${Platform.pathSeparator}cs1_plain_export.sourin';
  var plainIncluded = true;
  var plainNote = '';
  try {
    final r = await SourinApi.backupExport(plainPath);
    plainNote = r.credentialsNote ?? '';
    final info = await SourinApi.backupInspect(plainPath);
    plainIncluded = info.credentials.included;
    note('对照包：included=${info.credentials.included} note=$plainNote');
  } catch (e) {
    note('对照导出失败: $e（作废，不影响主判据）');
    plainIncluded = true; // 读不到就当"没证明"，不造绿
  }
  ok('②′ 不给口令导出的包里「不含」登录态（对照成立）', !plainIncluded);
  if (plainNote.isNotEmpty && plainNote.contains('**')) {
    note('★ 对照包的 credentialsNote 里出现了 Markdown 星号「**」'
        '—— 界面会原样显示（本轮只记录，不在本任务范围内改）');
  }
  final plainFile = File(plainPath);
  if (plainFile.existsSync()) plainFile.deleteSync();

  cs1LogLine(
    step: '2_passphrase',
    file: exportPath,
    bytes: exitBytes,
    sha256: exportSha,
    ui: '对话框=设置导出用口令 via=$typedVia',
    verdict: cs1BothFacts(
      fileFact: credIncluded && !plainIncluded,
      uiFact: passUp && typed,
    ),
  );

  // ── ③ 导入（正确口令）──────────────────────────────────────────────
  say('');
  say('──────── ③ 导入同一文件（正确口令）────────');

  // 先让本机"没有登录态"，导入才有可观测的恢复量
  await forgetFakeCredential(dir);
  final providersBefore = await providersNow();
  ok('③ 导入前本机 providers = 0（否则"恢复"没有证据）',
      providersBefore == 0, 'providers=$providersBefore');

  final openStub = _OpenStub(exportPath);
  FileSelectorPlatform.instance = openStub;

  final pickBtn = buttonByText(panelEl, '选择文件', filled: false);
  ok('③ 面板上有「选择文件」按钮（描边按钮）', pickBtn != null,
      rectStr(rectOf(pickBtn)));
  await tapElement(rootEl, pickBtn, label: '选择文件');

  final pickedUp = await waitUntil(
    () => openStub.calls >= 1 && buttonByText(panelEl, '确认导入') != null,
    timeout: const Duration(seconds: 40),
    label: '选包 + 确认区',
  );
  ok('③ 选完文件 ⇒ 面板出现确认区（「确认导入」）', pickedUp,
      'openStub.calls=${openStub.calls}');
  if (!pickedUp) await finish(1);
  final pickShot = await shoot('cs1_04_import_confirm.png');
  ok('③ 确认区截图是 1280×800', pickShot.is1280x800,
      '${pickShot.w}x${pickShot.h}');

  final confirmBtn = buttonByText(panelEl, '确认导入');
  await tapElement(rootEl, confirmBtn, label: '确认导入');

  final importPassUp = await waitUntil(
    () => findText(rootEl, '这个备份包含登录态') != null,
    timeout: const Duration(seconds: 20),
    label: '导入口令对话框',
  );
  ok('③ 包内含登录态 ⇒ 先要口令（对话框出现）', importPassUp);
  if (!importPassUp) await finish(1);
  final importTitleEl = findText(rootEl, '这个备份包含登录态');
  final importDialogEl = importTitleEl == null
      ? null
      : (ancestorOfType(importTitleEl, AlertDialog) ?? rootEl);
  final (typed3, via3) = await typePassphrase(importDialogEl, kFakePass);
  ok('③ 口令已填入（正确口令）', typed3, 'via=$via3');
  await tapElement(rootEl, buttonByText(importDialogEl, '导入'),
      label: '对话框里的「导入」');

  final importOkUp = await waitUntil(
    () => textsIn(panelEl).any((t) => t.contains('导入完成')),
    timeout: const Duration(seconds: 60),
    label: '导入完成',
  );
  final providersAfterOk = await providersNow();
  final okTexts = textsIn(panelEl);
  ok('③ 面板显示「导入完成」（UI 事实）', importOkUp,
      okTexts.firstWhere((t) => t.contains('导入完成'), orElse: () => ''));
  ok('③ 登录态真的回到本机（providers ≥ 1）', providersAfterOk >= 1,
      'providers=$providersAfterOk');
  final importOkShot = await shoot('cs1_05_import_ok.png');
  ok('③ 导入成功截图是 1280×800', importOkShot.is1280x800,
      '${importOkShot.w}x${importOkShot.h}');

  cs1LogLine(
    step: '3_import_ok',
    file: exportPath,
    bytes: exitBytes,
    sha256: exportSha,
    ui: '面板=导入完成 providers=$providersAfterOk',
    verdict: cs1BothFacts(
      fileFact: providersBefore == 0 && providersAfterOk >= 1,
      uiFact: importOkUp,
    ),
  );

  // ── ④ 错口令 ⇒ 必须被拒，且文案不撒谎 ──────────────────────────────
  say('');
  say('──────── ④ 错口令 ⇒ 必须被拒 ────────');

  await forgetFakeCredential(dir);
  final providersBeforeBad = await providersNow();
  ok('④ 先把本机登录态清成 0（这样"没被恢复"才可观测）',
      providersBeforeBad == 0, 'providers=$providersBeforeBad');

  // 上一轮成功后 `_picked` 已被清空 ⇒ 重新选一次包
  await tapElement(rootEl, buttonByText(panelEl, '选择文件', filled: false),
      label: '选择文件（错口令这一轮）');
  final pickedAgain = await waitUntil(
    () => buttonByText(panelEl, '确认导入') != null,
    timeout: const Duration(seconds: 40),
    label: '确认区（错口令这一轮）',
  );
  ok('④ 重新选包后确认区又出现了', pickedAgain);
  if (!pickedAgain) await finish(1);
  await tapElement(rootEl, buttonByText(panelEl, '确认导入'), label: '确认导入');

  final badPassUp = await waitUntil(
    () => findText(rootEl, '这个备份包含登录态') != null,
    timeout: const Duration(seconds: 20),
    label: '导入口令对话框（错口令）',
  );
  ok('④ 对话框再次出现（要口令）', badPassUp);
  if (!badPassUp) await finish(1);
  final badTitleEl = findText(rootEl, '这个备份包含登录态');
  final badDialogEl = badTitleEl == null
      ? null
      : (ancestorOfType(badTitleEl, AlertDialog) ?? rootEl);
  final (typed4, via4) = await typePassphrase(badDialogEl, kWrongPass);
  ok('④ 已填入错口令（与正确口令不同）', typed4, 'via=$via4');
  await tapElement(rootEl, buttonByText(badDialogEl, '导入'),
      label: '对话框里的「导入」（错口令）');

  final errUp = await waitUntil(
    () => textsIn(panelEl).any((t) => t.contains('口令不正确')),
    timeout: const Duration(seconds: 60),
    label: '错口令错误文案',
  );
  final errText = textsIn(panelEl).firstWhere(
    (t) => t.contains('口令不正确'),
    orElse: () => '',
  );
  final providersAfterBad = await providersNow();
  final textsAfterBad = textsIn(panelEl);
  ok('④ 面板显示了「口令不正确…登录态没有导入」（UI 事实）', errUp, errText);
  ok('④ 错口令时登录态**没有**被恢复（providers 仍为 0）',
      providersAfterBad == 0, 'providers=$providersAfterBad');
  ok('④ 错口令这一轮**没有**出现「导入完成」（不许撒谎）',
      !textsAfterBad.any((t) => t.contains('导入完成')));

  final badShot = await shoot('cs1_06_wrong_pass.png');
  ok('④ 错口令截图是 1280×800', badShot.is1280x800,
      '${badShot.w}x${badShot.h}');

  // ★ 如实记录：错口令时界面显示的是异常的 toString（带宿主类名）
  if (errText.contains('Exception') || errText.contains('SourinCore')) {
    note('★ 错口令文案里带了宿主类名（逐字：「$errText」）—— '
        '它与「只显示原文」的口径不一致，本轮只记录');
  }

  cs1LogLine(
    step: '4_wrong_pass',
    file: exportPath,
    bytes: exitBytes,
    sha256: exportSha,
    ui: '被拒=${errUp ? '是' : '否'} providers=$providersAfterBad',
    verdict: cs1BothFacts(
      fileFact: providersBeforeBad == 0 && providersAfterBad == 0,
      uiFact: errUp && !textsAfterBad.any((t) => t.contains('导入完成')),
    ),
  );

  // ── ⑤ 再输对口令 ⇒ 必须成功 ────────────────────────────────────────
  say('');
  say('──────── ⑤ 再输对口令 ⇒ 必须成功 ────────');

  await tapElement(rootEl, buttonByText(panelEl, '选择文件', filled: false),
      label: '选择文件（对口令这一轮）');
  final pickedThird = await waitUntil(
    () => buttonByText(panelEl, '确认导入') != null,
    timeout: const Duration(seconds: 40),
    label: '确认区（对口令这一轮）',
  );
  ok('⑤ 重新选包后确认区出现', pickedThird);
  if (!pickedThird) await finish(1);
  await tapElement(rootEl, buttonByText(panelEl, '确认导入'), label: '确认导入');

  final okPassUp = await waitUntil(
    () => findText(rootEl, '这个备份包含登录态') != null,
    timeout: const Duration(seconds: 20),
    label: '导入口令对话框（对口令）',
  );
  ok('⑤ 对话框出现（要口令）', okPassUp);
  if (!okPassUp) await finish(1);
  final okTitleEl = findText(rootEl, '这个备份包含登录态');
  final okDialogEl = okTitleEl == null
      ? null
      : (ancestorOfType(okTitleEl, AlertDialog) ?? rootEl);
  final (typed5, via5) = await typePassphrase(okDialogEl, kFakePass);
  ok('⑤ 已填入正确口令', typed5, 'via=$via5');
  await tapElement(rootEl, buttonByText(okDialogEl, '导入'),
      label: '对话框里的「导入」（对口令）');

  final finalOkUp = await waitUntil(
    () => textsIn(panelEl).any((t) => t.contains('导入完成')),
    timeout: const Duration(seconds: 60),
    label: '最终导入完成',
  );
  final providersFinal = await providersNow();
  ok('⑤ 面板显示「导入完成」', finalOkUp);
  ok('⑤ 登录态恢复到本机（providers ≥ 1）', providersFinal >= 1,
      'providers=$providersFinal');
  final finalShot = await shoot('cs1_07_final_ok.png');
  ok('⑤ 最终截图是 1280×800', finalShot.is1280x800,
      '${finalShot.w}x${finalShot.h}');

  cs1LogLine(
    step: '5_ok',
    file: exportPath,
    bytes: exitBytes,
    sha256: exportSha,
    ui: '面板=导入完成 providers=$providersFinal',
    verdict: cs1BothFacts(
      fileFact: providersFinal >= 1,
      uiFact: finalOkUp,
    ),
  );

  // ── 收尾 ───────────────────────────────────────────────────────────
  say('');
  say('──────── 收尾 ────────');
  final shots = _shotDir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.toLowerCase().endsWith('.png'))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  note('截图 ${shots.length} 张：');
  for (final f in shots) {
    note('  ${f.path.split(Platform.pathSeparator).last}  '
        '${f.lengthSync()} B');
  }
  ok('截图 ≥ 5 张（约定要求 5 张以上）', shots.length >= 5, '${shots.length} 张');
  ok('截图命名不以 tabshot_ 开头（否则会被 stale 清理）',
      shots.every((f) => !f.path.split(Platform.pathSeparator).last
          .startsWith('tabshot_')));

  await finish(fail == 0 ? 0 : 1);
}

// ══════════════════════════════════════════════════════════════════════
//  自检说明（给跑 `flutter test` 的人）
// ══════════════════════════════════════════════════════════════════════
//
// 本文件是**探针**，真正的判据必须在真窗口里跑（见文件头用法）。
// 但它有三个纯函数可以在 `flutter test` 里直接验证逻辑自洽：
// ```text
// cs1Sha256Short(bytes)   —— 指纹算法与长度
// cs1LogLine(...)         —— 机器可读行的字段顺序/分隔符/verdict 取值
// cs1BothFacts(...)       —— 双证据必须"与"起来，任一为假即判 BAD
// ```
// 这三条不替代真机读数，只保证"探针自己不会把 OK/BAD 算错"。
