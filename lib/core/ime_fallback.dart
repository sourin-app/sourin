// ═══════════════════════════════════════════════════════════════════════
//  runner 侧 IME 兜底通道（`sourin/ime` 的 `commit`）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它
// ```text
// 真机读数（2026-10-28）：
//   窗口层  WM_IME_STARTCOMPOSITION → WM_IME_COMPOSITION(GCS_RESULTSTR) → ENDCOMPOSITION
//   Dart 层 收到一次 `len=0` 的 value 更新 —— **合成串是空的**
//   把 runner 里我们自己的 ImmAssociateContextEx 整个删掉后仍然一样
//   ⇒ 这不是"我们抢了上下文"，是这条 Flutter 版本的 Windows IME 路径读不出合成串。
// ```
// 于是 runner 自己用 `ImmGetCompositionStringW(GCS_RESULTSTR)` 读出来，
// 通过本通道把**已提交的字符串**发过来，由这里插进当前焦点输入框。
//
// # 边界（三条，都是为了不制造新缺陷）
// ```text
// ① 只处理**提交**（GCS_RESULTSTR）。拼音预览仍交给引擎 ——
//    两边都接管会出现"预览一段、提交又插一段"的重复。
// ② 找不到焦点输入框 ⇒ 什么都不做（不许乱插到别处）。
// ③ 收到空串 ⇒ 直接丢（发包方已拦一次，这里再拦一次：
//    空串会把用户已经打好的字清掉）。
// ```
//
// # 怎么验证它真的插进去了
// ```text
// 打开 `SOURIN_IME_FALLBACK=1` 后再打中文：
//   · 输入框里出现中文 = 兜底生效；
//   · 出现两次（重复） = 说明引擎那条路也在工作 ⇒ 立刻关掉兜底，
//     改成"引擎给过非空值就不再兜底"的联动。
// ```

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 注册 `sourin/ime` 的 `commit` 处理。可在多处重复调用（幂等）。
void installImeFallbackChannel() {
  if (_installed) return;
  _installed = true;
  _channel.setMethodCallHandler((call) async {
    if (call.method != 'commit') return null;
    final text = call.arguments;
    if (text is! String || text.isEmpty) return null;
    insertIntoFocusedEditable(text);
    return null;
  });
}

bool _installed = false;
const MethodChannel _channel = MethodChannel('sourin/ime');

/// 把 [text] 插进当前焦点所在的 `EditableText`。
///
/// # 为什么必须**推到下一帧**再插（2026-10-28 实测的坑）
/// ```text
/// runner 已经读出了合成串（日志 `ime-fallback commit chars=2`），
/// 但同一毫秒 Dart 侧收到一次 `len=0` 的 value 更新 —— 那是引擎对
/// WM_IME_COMPOSITION 的反应：它把"空串"写进输入框。
/// 如果我们在通道回调里**同步**插入，就会被紧接着的这次空更新**覆盖掉**，
/// 现象就是"打了中文，框里什么都没有"（实测两次都是 len=0）。
/// ⇒ 推到当前帧渲染之后再写，让引擎那次空更新先落地。
/// ```
void insertIntoFocusedEditable(String text) {
  if (text.isEmpty) return;
  WidgetsBinding.instance.addPostFrameCallback((_) {
    _insertNow(text);
  });
  // 若此刻没有已排队的帧（纯输入事件常常不触发重绘），主动要一帧，
  // 否则 addPostFrameCallback 会一直挂着不执行。
  SchedulerBinding.instance.ensureVisualUpdate();
}

/// 同步插入（测试与"下一帧插入"共用同一份实现）。
@visibleForTesting
bool insertIntoFocusedEditableNow(String text) => _insertNow(text);

bool _insertNow(String text) {
  if (text.isEmpty) return false;
  final state = _focusedEditable();
  if (state == null) return false;

  final value = state.currentTextEditingValue;
  /*
   * ★ 防双插（2026-10-28）：如果引擎**正在合成**（composing 区间非空且未折叠），
   *   说明这条 Flutter 版本的 IME 路径其实是活的 ⇒ 这次提交交给它，我们不插。
   *   现在这台机器上它恒为 collapsed（引擎读不出串），所以这里不会挡掉正常路径；
   *   将来 Flutter 修好了，这条会自动让位，不会出现"打一个词出两遍"。
   */
  if (value.composing.isValid && !value.composing.isCollapsed) {
    return false;
  }
  final sel = value.selection;
  final start = sel.isValid ? sel.start : value.text.length;
  final end = sel.isValid ? sel.end : value.text.length;
  final next = value.text.replaceRange(start, end, text);
  state.userUpdateTextEditingValue(
    TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + text.length),
      // 合成区间必须清空：这段字已经"提交"了，不是还在拼的预览
      composing: TextRange.empty,
    ),
    SelectionChangedCause.keyboard,
  );
  return true;
}

/// 深度优先找**当前有焦点**的 `EditableText` 的 State。
EditableTextState? _focusedEditable() {
  EditableTextState? found;
  void visit(Element e) {
    if (found != null) return;
    if (e is StatefulElement && e.state is EditableTextState) {
      final s = e.state as EditableTextState;
      if (s.widget.focusNode.hasFocus) {
        found = s;
        return;
      }
    }
    e.visitChildren(visit);
  }

  final root = WidgetsBinding.instance.rootElement;
  if (root == null) return null;
  root.visitChildren(visit);
  return found;
}
