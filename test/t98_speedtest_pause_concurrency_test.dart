// ═══════════════════════════════════════════════════════════════════════
//  测速：暂停 / 并发 / 退出安全 —— 回归守卫（Owner 2026-10-13）
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字）
// ```text
// > 在测速的过程中允许暂停；测速的过程中如果直接退出会导致窗口无响应，
// > 并且测速应该多线程 多个并发,但要考虑实际带宽
// ```
//
// # 三条需求 → 三组判据
// ```text
// ① 暂停       → `SpeedTestCancelToken`：cancel 后 isCancelled 为 true、幂等
// ② 退出安全    → `cancelAll()` 一次停掉所有在飞令牌；退出流程真的调它
// ③ 并发       → `_allConcurrency` 存在且是**有上限的小值**（不是"全开"）
// ```
//
// ⚠️ 这些是**契约测试**（读源码 + 单测纯逻辑），不跑真网络 ——
//    真网络测速既慢又不稳定，而这三条改动的**形状**才是要钉的东西。
//    （测速的数字是否正确由 `_measure` 决定，与本文件无关。）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/widgets/plugin_speedtest.dart'
    show SpeedTestCancelToken;

/// 读取源码（测试 cwd = 包根）
String _src(String p) => File(p).readAsStringSync();

/// 剥掉注释 —— 防止"注释里提到"被当"代码里有"（本仓踩过至少四次）
String _code(String src) => src
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

void main() {
  group('① 暂停：取消令牌', () {
    test('cancel() 后 isCancelled 为 true', () {
      final t = SpeedTestCancelToken.registered();
      addTearDown(t.unregister);
      expect(t.isCancelled, isFalse, reason: '新建令牌默认不在取消态');
      t.cancel();
      expect(t.isCancelled, isTrue);
    });

    test('cancel() 幂等（重复调无副作用）', () {
      final t = SpeedTestCancelToken.registered();
      addTearDown(t.unregister);
      t.cancel();
      t.cancel();
      expect(t.isCancelled, isTrue);
    });

    test('register / unregister 维护全局表（不许泄漏）', () {
      final before = SpeedTestCancelToken.liveCount;
      final t = SpeedTestCancelToken.registered();
      expect(SpeedTestCancelToken.liveCount, before + 1,
          reason: '注册后必须在全局表里 —— 否则 cancelAll() 停不到它');
      t.unregister();
      expect(SpeedTestCancelToken.liveCount, before,
          reason: '注销后必须从全局表摘掉 —— 否则长期开设置页会攒死令牌');
    });

    test('★ cancelAll() 一次停掉所有在飞令牌', () {
      final a = SpeedTestCancelToken.registered();
      final b = SpeedTestCancelToken.registered();
      addTearDown(a.unregister);
      addTearDown(b.unregister);
      expect(a.isCancelled || b.isCancelled, isFalse);
      SpeedTestCancelToken.cancelAll();
      expect(a.isCancelled, isTrue, reason: 'cancelAll 必须停掉 a');
      expect(b.isCancelled, isTrue, reason: 'cancelAll 必须停掉 b');
    });
  });

  group('② 退出安全：退出流程必须调 cancelAll', () {
    late String tray;

    setUpAll(() => tray = _code(_src('lib/core/app_tray.dart')));

    test('★ quitNow() 里必须出现 SpeedTestCancelToken.cancelAll()', () {
      expect(
        tray.contains('SpeedTestCancelToken.cancelAll()'),
        isTrue,
        reason: '★★★ Owner 报的「测速中退出 ⇒ 窗口无响应」：'
            '退出流程原来**完全不通知测速** ⇒ 它继续写盘、继续 setState ⇒ '
            '与退出 flush 交叉（脏写/丢数据）、或 setState 到已 dispose 的树。'
            '⇒ `quitNow()` 必须先 cancelAll()。',
      );
    });

    test('★ cancelAll 必须在 flush 偏好**之前**（否则脏写仍会发生）', () {
      final i = tray.indexOf('SpeedTestCancelToken.cancelAll()');
      final j = tray.indexOf('await _flushPrefsBeforeExit()');
      expect(i, greaterThanOrEqualTo(0));
      expect(j, greaterThanOrEqualTo(0));
      expect(
        i,
        lessThan(j),
        reason: '★ 测速每完成一个源就 append ⇒ UiPrefs.set ⇒ 300ms 去抖写盘。'
            '若 cancelAll 晚于 flush，那次写盘仍会后到 ⇒ 脏写/丢数据。',
      );
    });

    test('cancelAll 必须是**同步**调用（不许 await）—— 别把退出拖慢', () {
      expect(
        RegExp(r'await\s+SpeedTestCancelToken\.cancelAll\(\)').hasMatch(tray),
        isFalse,
        reason: '★ cancelAll 只置标志位（同步），await 它没有意义；'
            '我们要的是"让它自己收手"，不是"等它跑完"。',
      );
    });
  });

  group('③ 并发：有上限的小值', () {
    late String src;

    setUpAll(() => src = _code(_src('lib/ui/widgets/plugin_speedtest.dart')));

    test('★ `_allConcurrency` 存在且是 2~4 之间的常数', () {
      final m = RegExp(r'const int _allConcurrency = (\d+);').firstMatch(src);
      expect(m, isNotNull,
          reason: '★ 并发路数必须是**命名常量**（便于对照推导与改一处生效）');
      final n = int.parse(m!.group(1)!);
      expect(n, greaterThanOrEqualTo(2),
          reason: '★ Owner 要"多线程 多个并发" ⇒ 不能是 1（原串行行为）');
      expect(n, lessThanOrEqualTo(4),
          reason: '★★ 但"要考虑实际带宽" ⇒ 不能"N 路全开"（15 个源并发会互相抢'
              '带宽、每条读数都被污染 —— 原始注释的顾虑成立）。'
              '选 3 是折中，见常量注释。',
      );
    });

    test('★ 「全部测速」用 worker-pool 并发，不再是纯串行 for-await', () {
      expect(
        src.contains('Future.wait<void>('),
        isTrue,
        reason: '★ 并发必须用 `Future.wait` 起多个 worker，'
            '而不是原来的 `for (...) { await run(...) }` 纯串行。',
      );
      // 反面：旧的"前一个没回来绝不开始下一个"注释+循环不许回来
      expect(
        RegExp(r'// ★ 顺序：前一个 await 没回来').hasMatch(src),
        isFalse,
        reason: '★ 那条注释描述的是**已改掉的串行行为**，留着会误导。',
      );
    });

    test('★ 共享游标（不是"切成 N 段各跑一段"）', () {
      expect(
        src.contains('cursor++') || src.contains('cursor +='),
        isTrue,
        reason: '★ 必须用**共享游标**派活：切成 N 段时，某个源特别慢会让那一路'
            '拖尾 ⇒ 实际并发掉到 1~2（共享游标则某路一空就取下一个）。',
      );
    });
  });

  group('④ 顺带修掉的两个模板串 bug', () {
    late String src;

    setUpAll(() => src = _code(_src('lib/ui/widgets/plugin_speedtest.dart')));

    test(r'不许再出现多一个花括号的模板串（如 成功 N} ）', () {
      expect(RegExp(r'\$_ok\}').hasMatch(src), isFalse,
          reason: '原来会显示成「成功 3}」');
      expect(RegExp(r'\$n\}').hasMatch(src), isFalse,
          reason: '原来会显示成「已清空 3} 个源…」');
    });
  });
}
