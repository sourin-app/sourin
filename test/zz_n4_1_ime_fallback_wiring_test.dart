// ═══════════════════════════════════════════════════════════════════════
//  N4-1：runner 侧 IME 兜底 —— 源码守则
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁守什么
// ```text
// 这台机器上 Flutter 的 Windows IME 路径**读不出合成串**（实测：
// 窗口层有 WM_IME_COMPOSITION(RESULTSTR)，Dart 侧只收到 len=0 的空更新；
// 把 runner 里我们自己的 ImmAssociateContextEx 删掉之后仍然一样）。
// 修法是 runner 自己读 GCS_RESULTSTR 并通过 `sourin/ime` 的 `commit` 交给 Dart。
//
// 这条门禁钉住这个"三段链路"的存在：
//   ① runner 读串：ImmGetCompositionStringW + GCS_RESULTSTR
//   ② 有通道：SetImeCommitSink 必须在**匿名 namespace 之外**（否则 LNK2019）
//             + FlutterWindow 里建 `sourin/ime` 通道 + UTF-16→UTF-8
//   ③ Dart 收：ime_fallback.dart 注册 commit 并**下一帧**插入
//      （同一毫秒同步插入会被引擎的空更新覆盖 —— 实测过两次）
// ```
// 注入：把 win32_window.cpp 里 `SetImeCommitSink` 挪回匿名 namespace ⇒ ①/② 红
//       （这条判据本质是"别把它挪回去、别把链路改断"）。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String p) => File(p).readAsStringSync();

void main() {
  test('① runner 真的读了合成串（ImmGetCompositionStringW + GCS_RESULTSTR）', () {
    final src = _read('windows/runner/win32_window.cpp');
    expect(src.contains('ImmGetCompositionStringW'), isTrue,
        reason: '★★ N4-1 的核心：runner 必须自己读合成串（引擎这条路读不出来）');
    expect(src.contains('GCS_RESULTSTR'), isTrue,
        reason: '★ 只处理"提交"（RESULTSTR）；拼音预览仍交给引擎，避免重复插入');
    expect(src.contains('g_ime_commit_sink'), isTrue,
        reason: '★ 读出来的串必须有去处（否则等于没修）');
  });

  test('② SetImeCommitSink 必须在匿名 namespace 之外（否则 LNK2019）', () {
    final src = _read('windows/runner/win32_window.cpp');
    final defIdx = src.indexOf('void SetImeCommitSink(');
    expect(defIdx, greaterThan(0), reason: '★ 定义必须存在');
    final anonIdx = src.indexOf('namespace {');
    expect(anonIdx, greaterThan(0), reason: '★ 本文件确实有匿名 namespace（判据前提）');
    /*
     * 判据：定义出现在匿名 namespace 的**前面**。
     *   放在里面 = 内部链接 ⇒ flutter_window.cpp 链接不到（实测 LNK2019）。
     */
    expect(defIdx, lessThan(anonIdx),
        reason: '★★ SetImeCommitSink 被挪进匿名 namespace 了 —— 那会让别的 TU '
            '链接不到（LNK2019: 无法解析的外部符号 SetImeCommitSink）');
  });

  test('③ FlutterWindow 建了 sourin/ime 通道并做 UTF-16→UTF-8', () {
    final src = _read('windows/runner/flutter_window.cpp');
    expect(src.contains('sourin/ime'), isTrue, reason: '★ 通道名必须逐字一致（Dart 侧按它注册）');
    expect(src.contains('SetImeCommitSink'), isTrue, reason: '★ 必须把 sink 接上');
    expect(src.contains('0xE0 | (cp >> 12)'), isTrue,
        reason: '★ 中文是 3 字节 UTF-8，这条分支缺了就会把汉字变成问号');
  });

  test('④ Dart 侧"下一帧"插入（同步插入会被引擎的空更新覆盖）', () {
    final src = _read('lib/core/ime_fallback.dart');
    expect(src.contains('addPostFrameCallback'), isTrue,
        reason: '★★ 必须推到下一帧：同一毫秒同步插入会被引擎的 len=0 更新覆盖'
            '（实测两次，框里什么都没有）');
    expect(src.contains("MethodChannel('sourin/ime')"), isTrue,
        reason: '★ 通道名要与 runner 逐字一致');
  });
}
