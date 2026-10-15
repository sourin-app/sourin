// ═══════════════════════════════════════════════════════════════════════
//  托盘「彻底退出」必须走 close() 且必须**确认落地**（否则卡死但不退出）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 反应（逐字）
// ```text
// > 右键任务栏退出会导致卡死,但是并不退出
// ```
//
// # 真根因（2026-10-14 实测定位，非侵入探针；同一构建按 SOURIN_QUIT_MODE 二分）
// ```text
// ① destroy() → PostQuitMessage(0)：只往线程队列塞 WM_QUIT，**不销毁窗口**。
//    消息循环退出（wWinMain 返回 EXIT_SUCCESS）但主窗口还在、Flutter 引擎还挂在
//    它上面 ⇒ 拆除时死锁 ⇒ 进程不退出、窗口也不再响应。
//      实测：destroyonly → HANG；close → EXIT 1452ms
//
// ② 只用一次 close() 也不够：close() 原生侧是
//    PostMessage(hWnd, WM_SYSCOMMAND, SC_CLOSE, 0)，**异步投递**；
//    而托盘菜单是 TrackPopupMenu（同步模态、自带嵌套消息循环）——
//    用户从菜单点「退出」时那个 SC_CLOSE 是在菜单还开着时投出去的，会被吃掉。
//      实测：整条 Dart 流程都跑完了（连 close() 已返回都打出来了）进程却仍活着。
//    ⇒ 必须**确认落地**，没落地就再投。落地判据见 _windowStillAlive 的注释
//      （用 getBounds() 而不是 isVisible()：藏到托盘时窗口是 SW_HIDE）。
// ```
//
// # 本文件锁什么（判据必须是结构性的）
// ```text
// 不许写成「文件里出现 windowManager.close() 就通过」—— 把 close() 写在
// 注释里、或写在 catch 兜底里都能骗过判据。必须按**位置 + 结构**判：
//   ① setPreventClose(false) 必须在 close() **之前**（否则 WM_CLOSE 被拦下）
//   ② close() 必须在重投循环里（有界 for/while 循环包着）
//   ③ 循环里必须有提前返回（确认落地就停）
//   ④ destroy() 不许出现在主路径的第一次 close() **之前**
//      （它不销毁窗口，只能是最后的兜底）
// ```
//
// # 假绿防线（用例②）
// ```text
// 判据自己必须能变红：拿修复前的真实形态（destroy 当主路径）当合成样例喂进
// **同一套判据**，必须被判违规。本项目铁律：禁止假绿门禁，新门禁先做故障注入。
// ⚠️ 本判据第一次写出来时是「destroy 只许在 catch 兜底里」—— 在**加了重投之后**
//    误红了（重投后 destroy 合理地落在主路径尾部当兜底）。
//    ⇒ 判据的前提跟着实现变，必须重写：这次直接断言「重投 + 确认落地」这个真不变量。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _src(String p) => File(p).readAsStringSync();

/// 剥掉注释 —— 本仓铁律：源码级判据必须先剥注释。
///
/// 正确实现的注释里为了解释缺陷，一定会写到 destroy() 与 close()，
/// 不剥的话判据会被自己的说明文字误伤（假红）。
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

/// 取 _destroyAndClose 的函数体（从签名到类结束的那个右花括号之前）。
String _destroyAndCloseBody(String src) {
  final i = src.indexOf('Future<void> _destroyAndClose()');
  if (i < 0) return '';
  final rest = src.substring(i);
  final end = rest.indexOf('\n}');
  return end > 0 ? rest.substring(0, end) : rest;
}

const String _setPc = 'await windowManager.setPreventClose(false);';
const String _close = 'await windowManager.close();';
const String _destroy = 'windowManager.destroy()';

/// 判据本体：合规返回 null，违规返回原因。
///
/// 抽成纯函数是为了让合成样例能喂进同一套判据（用例②的故障注入）。
String? _violation(String body) {
  if (body.trim().isEmpty) return '找不到 _destroyAndClose 的函数体';

  final closeAt = body.indexOf(_close);
  if (closeAt < 0) {
    return '主路径没有走 close() ⇒ 只剩 destroy()（PostQuitMessage）⇒ 窗口不销毁、卡死';
  }

  final pcAt = body.indexOf(_setPc);
  if (pcAt < 0) {
    return '没有先 setPreventClose(false) ⇒ WM_CLOSE 会被 window_manager 拦下，窗口关不掉';
  }
  if (pcAt > closeAt) {
    return 'setPreventClose(false) 在 close() 之后 ⇒ 关窗时拦截还没解除';
  }

  // ② close() 必须在重投循环里 —— 否则一次投递丢了就卡死（实测复现过）
  final loopBefore = RegExp(r'for\s*\(|while\s*\(')
      .allMatches(body.substring(0, closeAt))
      .isNotEmpty;
  if (!loopBefore) {
    return 'close() 不在重投循环里 ⇒ SC_CLOSE 被菜单模态循环吃掉时就永久卡死';
  }

  // ③ 循环里必须有「确认落地就停」的提前返回
  final afterClose = body.substring(closeAt);
  if (!RegExp(r'return\s*;|return\s+\S').hasMatch(afterClose)) {
    return 'close() 之后没有提前返回 ⇒ 无法确认关窗是否落地';
  }

  // ④ destroy() 不许在第一次 close() 之前（它不销毁窗口，只能是最后兜底）
  final destroyAt = body.indexOf(_destroy);
  if (destroyAt >= 0 && destroyAt < closeAt) {
    return 'destroy() 在 close() 之前 ⇒ 仍会走 PostQuitMessage 那条卡死路';
  }
  return null;
}

void main() {
  const path = 'lib/core/app_tray.dart';

  test('① 真实源码：退出走 close() + 重投 + 确认落地（剥注释后）', () {
    final body = _destroyAndCloseBody(_code(_src(path)));
    expect(_violation(body), isNull, reason: '实际抽到的函数体：\n' + body);
  });

  test('② 故障注入：这些形态都必须被判违规（否则是假绿门禁）', () {
    // (a) 修复前的真实形态：destroy() 当主路径，close() 只在 catch 兜底
    const buggy = '''
      try {
        await windowManager.setPreventClose(false);
        await windowManager.destroy();
      } catch (e) {
        try { await windowManager.close(); } catch (_) {}
      }
    ''';
    expect(_violation(buggy), isNotNull);

    // (b) 只用一次 close()，没有重投循环（实测会卡死的那版）
    const singleShot = '''
      try {
        await windowManager.setPreventClose(false);
        await windowManager.close();
      } catch (e) {}
    ''';
    expect(_violation(singleShot), isNotNull);

    // (c) 有循环但没有确认落地 / 没有提前返回
    const noConfirm = '''
      await windowManager.setPreventClose(false);
      for (var attempt = 0; attempt < 3; attempt++) {
        await windowManager.close();
      }
    ''';
    expect(_violation(noConfirm), isNotNull);

    // (d) 忘了解除拦截
    const noPc = '''
      for (var attempt = 0; attempt < 3; attempt++) {
        await windowManager.close();
        if (!await alive()) { return; }
      }
    ''';
    expect(_violation(noPc), isNotNull);

    // (e) 顺序反了
    const wrongOrder = '''
      for (var attempt = 0; attempt < 3; attempt++) {
        await windowManager.close();
        if (!await alive()) { return; }
        await windowManager.setPreventClose(false);
      }
    ''';
    expect(_violation(wrongOrder), isNotNull);

    // (f) destroy() 跑到 close() 前面
    const destroyFirst = '''
      await windowManager.setPreventClose(false);
      for (var attempt = 0; attempt < 3; attempt++) {
        await windowManager.destroy();
        await windowManager.close();
        if (!await alive()) { return; }
      }
    ''';
    expect(_violation(destroyFirst), isNotNull);

    // (g) 空体（抽取失败）
    expect(_violation(''), isNotNull);
  });

  test('③ 剥注释：注释里出现 destroy()/close() 不得造成假红', () {
    final stripped = _code(_src(path));
    expect(stripped.contains('//'), isFalse);
    expect(_violation(_destroyAndCloseBody(stripped)), isNull);

    // ★ 反向证明「剥注释」这一步真的在起作用：合成一段**只有注释里**出现
    //   destroy() 的函数体 —— 不剥注释会被判违规（假红），剥掉之后必须合规。
    const withComment = '''
      // 以前这里写的是 windowManager.destroy()，会卡死
      await windowManager.setPreventClose(false);
      for (var attempt = 0; attempt < 3; attempt++) {
        await windowManager.close();
        if (!await alive()) { return; }
      }
    ''';
    expect(_violation(withComment), isNotNull,
        reason: '不剥注释时，注释里的 destroy() 会误伤判据（这正是要防的假红）');
    expect(_violation(_code(withComment)), isNull, reason: '剥掉注释后必须放行');
  });
}
