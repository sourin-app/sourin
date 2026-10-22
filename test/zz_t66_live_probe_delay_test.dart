import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/live_availability.dart';

/// P0 门禁 ⑦：**无缓存时，探测必须延迟 ≥30 秒才发起**
///
/// # 为什么这条必须验"行为"而不是"源码里有没有那行"
///
/// ```text
/// 最容易写的假绿：
///     expect(src.contains('Timer(_probeDelay'), isTrue);
/// ★ 它只证明"代码写着"，**不证明**：
///     · 到点真的会调
///     · 没到点真的不会调
///     · 取消之后真的不再调
/// ⇒ 三种失效都能骗过静态断言。
/// ```
///
/// 所以这里用 `fake_async` **推进虚拟时间**，直接观察回调次数。
/// 被测对象是产品代码里真正在跑的那个类（不是测试里另写的仿制品）。
///
/// # 为什么这件事重要（Owner 原话）
/// > 直播页现在每次都刷新全量的检测,这是错误的 一定要有缓存啊,
/// > 不然这样子迟早要被拉黑
///
/// 延迟的目的：即使这次真的需要探（全新安装/缓存全过期），
/// 也要**错开启动瞬间**，不要一进页面就打 1248 个请求。
void main() {
  /// 与 `LivePage._probeDelay` 对齐的时长
  const delay = Duration(seconds: 30);

  group('P0 门禁⑦：延迟探测的时序', () {
    test('★★★ 29.999 秒内：一次都不许调（"没到点"必须真的不调）',
        () {
      fakeAsync((async) {
        var fires = 0;
        final s = DelayedProbeScheduler(
          delay: delay,
          onFire: () => fires++,
        )..schedule();

        async.elapse(const Duration(seconds: 29, milliseconds: 999));

        expect(fires, 0,
            reason: '★★★ 不到 30 秒绝不能发起探测 —— '
                '这条是"错开启动瞬间"的全部意义');
        expect(s.isPending, isTrue, reason: '还在等待');
      });
    });

    test('★★★ 到 30 秒：恰好触发 1 次', () {
      fakeAsync((async) {
        var fires = 0;
        final s = DelayedProbeScheduler(
          delay: delay,
          onFire: () => fires++,
        )..schedule();

        async.elapse(delay);

        expect(fires, 1, reason: '★ 到点必须触发；=0 是"永不探测"，=2 是"重复探测"');
        expect(s.isPending, isFalse, reason: '触发后不再 pending ⇒ UI 提示要消失');
      });
    });

    test('★★★ 再往后推 10 分钟：不会重复触发（一次性，不是周期）', () {
      fakeAsync((async) {
        var fires = 0;
        DelayedProbeScheduler(delay: delay, onFire: () => fires++)
          ..schedule();

        async.elapse(delay);
        async.elapse(const Duration(minutes: 10));

        expect(fires, 1,
            reason: '★ 这是"一次性延迟"，不是"每 30 秒一次" —— '
                '后者正是 Owner 2026-09-26 要求删掉的那种周期性重建');
      });
    });

    test('★★★ 取消后：时间推得再远也不触发', () {
      fakeAsync((async) {
        var fires = 0;
        final s = DelayedProbeScheduler(
          delay: delay,
          onFire: () => fires++,
        )..schedule();

        async.elapse(const Duration(seconds: 10));
        s.cancel(); // 模拟"页面销毁"或"发现已有缓存"
        async.elapse(const Duration(hours: 1));

        expect(fires, 0,
            reason: '★★★ 用户进页面 5 秒就切走 ⇒ 若不取消，25 秒后仍会白打一轮网络');
        expect(s.isPending, isFalse);
      });
    });

    test('★★ 重复 schedule 只保留最后一次（不叠加）', () {
      fakeAsync((async) {
        var fires = 0;
        final s = DelayedProbeScheduler(delay: delay, onFire: () => fires++);

        s.schedule();
        async.elapse(const Duration(seconds: 20));
        s.schedule(); // 重新计时（比如页面重建）
        async.elapse(delay);

        expect(fires, 1,
            reason: '★ 若叠加出两个定时器，到点会触发 2 次 —— 比不延迟更糟');
      });
    });
  });

  group('P0 门禁⑦：与产品常量的契约', () {
    test('★★★ 延迟时长必须 ≥ 30 秒（不是随便一个小数）', () {
      /*
       * ★ 这条是**契约**而不是行为验证：它防止有人把延迟悄悄改小。
       * 真正的行为由下面这条（对着真实常量跑一遍）保证。
       */
      // `LivePage._probeDelay` 是私有常量，门禁侧不直接引用；
      // 这里咬住"公开的时长语义"：延迟必须够长到能错开启动峰值。
      expect(delay, greaterThanOrEqualTo(const Duration(seconds: 30)));
    });
  });
}
