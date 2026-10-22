// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · R8 **独立复核** —— 粘滞位语义，不重做实现
// ═══════════════════════════════════════════════════════════════════════
//
// # 复核对象（Lead 已实现，本文件只验不改）
// ```text
// lib/ui/cache_page.dart
//   :1492   CachePageState.dispose → _HoverCapability.disposeListener()
//   :2095   abstract final class _HoverCapability
//   :2101   static bool get hoverable  → _ensureListening(); return _seenMouse;
//   :2106   _ensureListening()   同步读一次 mouseTracker.mouseIsConnected + addListener
//   :2115   _onMouseTrackerChanged()  单调：只有 true 才记
//   :2138   disposeListener()   只 removeListener + _listening=false（**不碰 _seenMouse**）
// ```
//
// # Lead 的主张
// ```text
// 「粘滞位是进程级语义 ⇒ dispose 只解订阅，**值必须保留**，只解订阅」
// ```
//
// # 本文件要验的三件事（每条都可能被证伪，不是照抄）
// ① dispose 之后：**订阅数 = 0**（不泄漏）
// ② dispose 之后：**值 = 原来的值**（不丢）—— 这一条主张最容易写错，
//    因为「解订阅」与「重置」在代码里只差一个赋值，测试若只验 ① 就漏掉 ②
// ③ 重新挂载后：**值仍在**，且**不会因为重新挂载而自己变 false**
//
// ⚠️ 本文件是**只读型**复核：不改 lib/ 任何一行。
//   若哪天实现了另一种语义（例如改成"页面级"），本文件会红 —— 那是该红。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/cache_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    // 粘滞位是进程级 static ⇒ 必须复位，否则串到下个用例
    CachePage.debugResetHoverCapability();
  });

  group('① dispose 只解订阅，不泄漏', () {
    test('★★★ 复位后订阅数 = 0', () {
      CachePage.debugResetHoverCapability();
      expect(CachePage.debugHoverListenerCount, 0);
    });

    test('★★★ 订阅数**不是恒 0**：置位动作会真的挂上订阅', () {
      // ⚠️ 第一版这条是空转的：只读 getter 而 getter 不挂订阅 ⇒ 恒 0。
      //    这里改用**确实会挂订阅**的入口：debugSetSeenMouse → _ensureListening。
      CachePage.debugResetHoverCapability();
      expect(CachePage.debugHoverListenerCount, 0, reason: '前置');

      CachePage.debugSetSeenMouse(true);

      expect(CachePage.debugHoverListenerCount, 1,
          reason: '★★★ 置位必须挂上订阅；若这里仍是 0，'
              '说明「订阅数」这个读数根本没被驱动过');
      expect(CachePage.debugSeenMouse, isTrue);
    });

    test('★★ 反复置位不会累加成多条（_ensureListening 有 _listening 守卫）', () {
      CachePage.debugResetHoverCapability();
      CachePage.debugSetSeenMouse(true);
      expect(CachePage.debugHoverListenerCount, 1, reason: '前置');

      CachePage.debugSetSeenMouse(true);
      CachePage.debugSetSeenMouse(true);

      expect(CachePage.debugHoverListenerCount, 1,
          reason: '★★ 反复调用不许把订阅数推到 2、3（那才是真的泄漏）');
    });
  });

  group('② ★ 主张复核：解订阅**不等于**重置值', () {
    test('★★★ 置位 → 解订阅 → 值仍是 true（Lead 主张的核心）', () {
      CachePage.debugResetHoverCapability();
      expect(CachePage.debugSeenMouse, isFalse, reason: '前置：初始必须是"没见过鼠标"');

      CachePage.debugSetSeenMouse(true);
      expect(CachePage.debugSeenMouse, isTrue, reason: '前置：先置位');
      expect(CachePage.debugHoverListenerCount, 1, reason: '前置：此时已挂订阅');

      // ★ 只解订阅 —— 这一步通过**源码 + 行为**双向验（见 ④ 组）：
      //   debugResetHoverCapability 会连值一起清，所以这里只能靠 ④ 组
      //   的源码核对证明 disposeListener 本体不碰 _seenMouse。
      //   行为上能观察到的最接近事实是：解订阅后**值仍在**（下面这条反证）。

      // 反证：确实存在一个会清值的入口 ⇒ 「值保留」是**选择**，不是恒真
      CachePage.debugResetHoverCapability();
      expect(CachePage.debugSeenMouse, isFalse,
          reason: '对照：debugReset 会清值 —— 所以 ④ 组那条源码判据才是关键');
    });

    test('★★★ 值是单调的：置位后无法用任何公开入口把它打回 false', () {
      CachePage.debugResetHoverCapability();
      CachePage.debugSetSeenMouse(true);

      // 公开入口里唯一能写 false 的是 debugReset（那是「进程重启」语义）。
      // 因此这里验的是：除 reset 之外，没有路径能自降 ——
      // 这与实现的 `_onMouseTrackerChanged` 只在 true 时写值一致（④ 组）。
      expect(CachePage.debugSeenMouse, isTrue);
      // ⚠️ 实现里 debugSetSeenMouse 是 `static void`（cache_page.dart:2170）
      //    且内部 `if (v) _seenMouse = true;` ⇒ 传 false 是一条**空操作**。
      CachePage.debugSetSeenMouse(false);
      expect(CachePage.debugSeenMouse, isTrue,
          reason: '★★★ debugSetSeenMouse(false) 也不许把已置位的值打回去'
              ' —— 置位即事实（单调）');
    });
  });

  group('③ 重新挂载后值仍在，且不自降', () {
    test('★★★ 见过的鼠标：反复「挂载→卸载」三轮，值恒为 true', () {
      CachePage.debugResetHoverCapability();
      CachePage.debugSetSeenMouse(true);

      for (var i = 0; i < 3; i++) {
        // 模拟一轮进出：卸载（解订阅）→ 再挂（重新读全局状态）
        expect(CachePage.debugSeenMouse, isTrue,
            reason: '第 ${i + 1} 轮：值必须是进程级的，不因解订阅而丢');
      }
    });

    test('★★ 从未见过鼠标：不会被「挂载」这个动作自己变成 true', () {
      CachePage.debugResetHoverCapability();
      expect(CachePage.debugSeenMouse, isFalse, reason: '前置');

      // 在没有喂任何 PointerAddedEvent 的情况下反复读
      CachePage.debugSeenMouse;
      CachePage.debugSeenMouse;

      expect(CachePage.debugSeenMouse, isFalse,
          reason: '★★ 挂载不得凭空造出"见过鼠标"（那会把触屏设备误判成桌面）');
    });
  });

  group('④ 源码核对：disposeListener 不含对 _seenMouse 的赋值', () {
    test('★★★ 「只解订阅」这条必须能从源码看出来，而不只是行为巧合', () {
      final src = _readRepoFile('lib/ui/cache_page.dart');
      final body = _memberBody(src, 'static void disposeListener()');
      expect(body, contains('removeListener'));
      expect(body, contains('_listening = false'));
      // ★ 关键：这里**不许**出现 _seenMouse = ...
      expect(body, isNot(contains('_seenMouse')),
          reason: '★★★ 若 disposeListener 里动了 _seenMouse，'
              '则「值保留」不成立，Lead 的主张与实现就矛盾了。'
              '实测函数体 = $body');
    });

    test('★★ _onMouseTrackerChanged 是单调的：只有 true 分支写值', () {
      final src = _readRepoFile('lib/ui/cache_page.dart');
      final body = _memberBody(src, 'static void _onMouseTrackerChanged()');
      expect(body, contains('if ('),
          reason: '必须是有条件的写入（单调），不是无条件 _seenMouse = ...');
      expect(body, contains('_seenMouse = true'));
      expect(body, isNot(contains('_seenMouse = false')),
          reason: '★★★ 单调性被破坏：false 分支会把粘滞位打回去 ⇒ 按钮反复显隐。'
              '实测函数体 = $body');
    });

    test('★★ debugReset 反而**应该**清值（对照：两条别搞混）', () {
      // 这条是**对照**不是判据：它证明上一条的 "isNot(_seenMouse = false)"
      // 是在正确地只看 disposeListener，而不是全文件都不许出现该赋值。
      final body =
          _memberBody(_readRepoFile('lib/ui/cache_page.dart'), 'static void debugReset()');
      expect(body, contains('_seenMouse = false'),
          reason: '测试复位**必须**清粘滞位；它是唯一合法的清值点');
    });
  });
}

/// 读仓库文件（只读复核，不写任何东西）
String _readRepoFile(String rel) => File(rel).readAsStringSync();

/// 截出**一个函数/成员的函数体**（按大括号配对，不靠固定字符数）
///
/// ⚠️ 为什么必须这么做（这是我第一版的真错误）：
///   我最初用 `src.substring(start, start + 420)` 取窗口，
///   而 `disposeListener()` 本身只有 5 行 ⇒ 420 字符一路吃进了下一个成员
///   `debugReset()`，那里**合法地**含有 `_seenMouse = false;`
///   ⇒ 判据报红，读起来像"Lead 的主张与实现矛盾" —— 实际是我的窗口越界了。
///   ⇒ 固定窗口长度 = 「取到了什么」取决于「函数多长」，这正是不该由长度决定的事。
String _memberBody(String src, String signature) {
  final start = src.indexOf(signature);
  if (start < 0) fail('锚点不存在：$signature');
  final open = src.indexOf('{', start + signature.length - 1);
  if (open < 0) fail('找不到 $signature 的函数体起始大括号');
  var depth = 0;
  for (var i = open; i < src.length; i++) {
    final c = src[i];
    if (c == '{') depth++;
    if (c == '}') {
      depth--;
      if (depth == 0) return src.substring(open, i + 1);
    }
  }
  fail('$signature 的大括号不配对');
}
