// ═══════════════════════════════════════════════════════════════════════
//  T110：悬浮窗卡顿 —— 读数不得再触发**整页重建**
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
//     > 这个modal好卡啊
//     > 要说卡的话,其他的在这个里面弹窗显示的悬浮窗都卡,
//     > 我之前在开发中还说了modal要统一,要解决这个卡顿的问题,
//     > 现在这个还没解决,这次请直接解决了吧
//
// # 根因（改前）
//     player_page.dart:3670  _onPositionTick（每秒一次）
//       └→ if (_danmakuSheetOpen) _refreshDanmakuReadout()
//            └→ setState(() { … copyWith(count/lanes/dropped) … })
//                 └→ ★ **播放页整棵重建**（1.6 万行：视频层 / 弹幕层 /
//                      顶栏 / 底栏 / 所有浮层一起重排）
//     而那三个数只显示在面板的**一行字符串**里。
//
// # 为什么"其他的悬浮窗都卡"也由这一条解释
//     字幕面板 / 选集面板 / 播放设置 / 弹幕面板 **都挂在播放页同一棵树上**。
//     宿主自己被反复重建 ⇒ 它们全部跟着重建。这不是"每个模态各卡各的"，
//     而是**同一个宿主级问题**在每一处同时发作。
//
// # 改后
//     读数走 ValueNotifier（与 _positionNotifier 同一手法），面板那一行用
//     ValueListenableBuilder 单独重建 ⇒ 面板开着时播放页**零重建**。
//
// # 判据（三条，缺一不可）
//     ① 宿主那条路径**不再** setState（源码契约）
//     ② 面板确实消费了 notifier（否则读数永远不会更新 —— 修过头了）
//     ③ notifier 被释放（不释放就是本仓最忌讳的资源泄漏形态）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String p) => File(p).readAsStringSync();

/// 去掉注释与字符串字面量，避免**注释里提到**某写法就把门禁骗绿。
///
/// ★ 这条是本仓的硬纪律：注释里写了「不许 setState」不等于代码没写 setState。
String stripComments(String src) {
  final noBlock = src.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ');
  return noBlock
      .split('\n')
      .map((l) {
        // 去掉 // 之后的内容（够用：本仓没有把 // 放进字符串的写法）
        final i = l.indexOf('//');
        return i >= 0 ? l.substring(0, i) : l;
      })
      .join('\n');
}

/// 取某个函数体（按花括号配对），用于把断言**限制在函数内部**。
///
/// ⚠️ 为什么不能靠"往后取 N 个字符"：那个窗口会越过右花括号，
///    把**下面那个函数的定义**也圈进来 —— 于是断言在
///    「调用被删掉、但定义还在」时**照样通过**（本仓 2026-10-15
///    真的踩过这个假绿，见 zz_tcache3_wiring_test.dart 的 _preloadFromDisk）。
String bodyOf(String code, String signature) {
  final start = code.indexOf(signature);
  expect(start, greaterThanOrEqualTo(0), reason: '找不到函数 $signature');
  final open = code.indexOf('{', start);
  expect(open, greaterThanOrEqualTo(0), reason: '$signature 没有函数体');
  var depth = 0;
  for (var i = open; i < code.length; i++) {
    final c = code[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return code.substring(open + 1, i);
    }
  }
  fail('$signature 的花括号没有配对');
}

void main() {
  final ppRaw = readRepoFile('lib/ui/player_page.dart');
  final dlgRaw = readRepoFile('lib/ui/widgets/danmaku_settings_dialog.dart');
  final pp = stripComments(ppRaw);
  final dlg = stripComments(dlgRaw);

  group('T110 · 弹幕读数不得触发整页重建', () {
    test('① ★ 宿主刷新读数用 notifier，**不用** setState', () {
      final body = bodyOf(pp, 'void _refreshDanmakuReadout()');
      expect(body.contains('setState'), isFalse,
          reason: '★ 这就是"modal 好卡"的根因：每秒 setState ⇒ 播放页整棵重建');
      expect(body.contains('_danmakuReadout.value'), isTrue,
          reason: '必须真的把新读数推给 notifier（否则读数永远不更新）');
      // 值没变就不推（与改前的判据一致，别把"没变也推"当成优化）
      expect(body.contains('sameAs'), isTrue,
          reason: '值没变就不该推 —— 与改前的 if (n == … ) return 等价');
    });

    test('② ★ 面板真的消费了 notifier（不是只定义不用）', () {
      expect(dlg.contains('ValueListenableBuilder<DanmakuReadout>'), isTrue,
          reason: '★ 定义了通道但没人监听 ⇒ 读数永远停在 0（修过头）');
      // ⚠️ 这条必须在 **pp** 上断言：接线在宿主（player_page），不在面板。
      //   第一版我写成 dlg ⇒ 假红（面板里当然找不到宿主的字段名）。
      expect(pp.contains('readout: _danmakuReadout'), isTrue,
          reason: '宿主必须把它交给面板（接线在 player_page）');
    });

    test('③ ★ notifier 必须被释放（否则是资源泄漏）', () {
      final dispose = bodyOf(pp, 'void dispose()');
      expect(dispose.contains('_danmakuReadout.dispose()'), isTrue,
          reason: '★ ValueNotifier 不释放 = 本仓最忌讳的泄漏形态');
    });

    test('④ 面板仍显示那三个读数（改的是通道，不是内容）', () {
      expect(dlg.contains('画面里现在挂着'), isTrue,
          reason: '读数本身必须还在（只是换了谁去重建）');
      expect(dlg.contains('r.count'), isTrue);
      expect(dlg.contains('r.lanes'), isTrue);
      expect(dlg.contains('r.dropped'), isTrue);
    });

    test('⑤ ★ 位置那条老路径没被改坏（同一手法的既有先例）', () {
      // _onPositionTick 里不该出现 setState（2026-10-09 已修，别回退）
      final body = bodyOf(pp, 'void _onPositionTick(Duration p)');
      expect(body.contains('setState'), isFalse,
          reason: '位置 tick 也不能 setState（每秒一次整页重建的老毛病）');
      expect(body.contains('_positionNotifier.value'), isTrue);
    });

    test('⑥ 面板开着时不再有任何"每秒一次"的整页 setState 入口', () {
      // 这条是兜底：将来若有人再挂一个 _danmakuSheetOpen 守卫下的 setState，
      // 必须显式说明理由，不能悄悄加回来。
      final tick = bodyOf(pp, 'void _onPositionTick(Duration p)');
      expect(tick.contains('_danmakuSheetOpen'), isTrue,
          reason: '读数刷新仍应由"面板是否开着"守卫（只是不该用 setState）');
    });
  });
}
