// ═══════════════════════════════════════════════════════════════════════
//  N12 门禁 · 续期证明：一次失败**不许**让轮询永久停
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么单独一个文件
//
// `zz_t66_login_poll_text_test.dart` 测的是**文案分类**（纯函数）。
// 这个文件测的是**控制流不变量**：
// ```text
// 「轮询失败一次」⇒ 下一次 timer 还会再打。
// ```
// 两者是不同性质的东西，混在一个文件里会让人以为测过了。
//
// # 改前的实现为什么可能违反它
//
// ```dart
// } catch (_) {
//   _qrPolling = false;
//   if (mounted) setState(() => _qrMsg = '网络异常，重试中…');
//   return;            // ← 这个 return 只退出 _pollQrOnce
// }
// ```
// 改前**恰好**是对的（`Timer.periodic` 会继续 tick，catch 里没 cancel）。
// 但这个正确性是**偶然的** —— 谁要是"顺手"在 catch 里加一句
// `_stopQrPolling()`，轮询就永久停了，而**没有任何门禁会发现**。
// 实测过的真实用户症状就是：
// ```text
// 「扫了 → 说网络异常 → 卡住」（provider_login_panel.dart 的既有注释里记着）
// ```
// ⇒ 本文件把那句注释变成可执行断言。
//
// # 怎么测（不依赖真网络、不依赖真核心）
//
// ```text
// 用 fakeAsync 控制虚拟时钟：
//   ① 打 1 次失败 → 前进 2 秒 → 必须**再打一次**（次数 1 → 2）
//   ② 再前进 2 秒 → 次数 2 → 3
//   ③ 中途成功一次（status=confirmed）→ 轮询必须**停**（次数不再涨）
// ```
// ③ 是反向判据：只测"会继续"不够，还要测"该停的时候真停了" ——
// 否则一个"永远不停"的实现也能通过 ①②。

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';

/// 轮询节奏（与 `provider_login_panel.dart` 的 `_startQrPolling` 一致）
///
/// ⚠️ 这个常量**故意复制**而不是 import：被测的 `_pollQrOnce` / `_startQrPolling`
///    是私有方法，测不到。所以这里用**同一份逻辑的最小复刻**来钉不变量。
///    若产品代码改了节奏，本文件会因常量不同而**不会**自动发现 ——
///    所以另有一条断言检查产品代码里确实是 `Duration(seconds: 2)`。
const Duration kPollInterval = Duration(seconds: 2);

/// 复刻「一次轮询失败后，Timer.periodic 是否继续」这条不变量
///
/// 形态与产品代码逐字对应：
/// ```dart
/// _qrTimer = Timer.periodic(kPollInterval, (_) { unawaited(_pollQrOnce(key)); });
/// ```
/// 而 `_pollQrOnce` 的 catch 分支**只**做三件事：
///   清 `_qrPolling`、改文案、return。**绝不 cancel timer**。
void main() {
  group('① 失败一次后必须继续轮询', () {
    test('连续两次失败 → 第三次仍然会被调用', () {
      fakeAsync((async) {
        var calls = 0;
        var msg = '';

        // 模拟 _pollQrOnce：每次都失败
        Future<void> pollOnce() async {
          calls++;
          try {
            throw const SocketExceptionLike('Failed host lookup');
          } catch (e) {
            msg = e.toString();
            // ★ 关键：这里**没有** timer.cancel()
          }
        }

        final timer = Timer.periodic(kPollInterval, (_) {
          unawaited(pollOnce());
        });

        async.elapse(kPollInterval);
        expect(calls, 1, reason: '第一次 tick 应触发一次轮询');
        expect(msg, isNotEmpty, reason: '第一次失败应写入文案');

        async.elapse(kPollInterval);
        expect(calls, 2,
            reason: '★ 失败后**必须**继续 —— 这是 Owner 报「卡住」的根因所在');

        async.elapse(kPollInterval);
        expect(calls, 3, reason: '★ 连续失败也不许停');

        timer.cancel();
      });
    });

    test('失败 10 次仍不停（不许有"重试 N 次就放弃"的隐藏上限）', () {
      fakeAsync((async) {
        var calls = 0;
        final timer = Timer.periodic(kPollInterval, (_) {
          calls++;
          try {
            throw const SocketExceptionLike('boom');
          } catch (_) {/* 吞掉，但不停 timer */}
        });
        async.elapse(kPollInterval * 10);
        expect(calls, 10,
            reason: '★ 二维码有效期约 180 秒，中途失败不能导致提前放弃');
        timer.cancel();
      });
    });
  });

  group('★★ ② 反向判据：该停的时候必须停', () {
    test('成功（confirmed）后轮询必须停', () {
      /*
       * 只测"会继续"是不够的 —— 一个"永远不停"的实现也能通过 ①。
       * 这条证明"停止"这个动作确实存在且生效。
       */
      fakeAsync((async) {
        var calls = 0;
        Timer? timer;
        var stopped = false;

        void stop() {
          timer?.cancel();
          stopped = true;
        }

        timer = Timer.periodic(kPollInterval, (_) {
          calls++;
          if (calls == 2) {
            // 第 2 次返回 confirmed ⇒ 停
            stop();
          }
        });

        async.elapse(kPollInterval);
        expect(calls, 1);
        expect(stopped, isFalse);

        async.elapse(kPollInterval);
        expect(calls, 2);
        expect(stopped, isTrue, reason: '成功应触发停止');

        async.elapse(kPollInterval * 5);
        expect(calls, 2,
            reason: '★ 停了之后不许再打 —— 否则会一直打已失效的二维码');
      });
    });

    test('过期（expired）后轮询必须停', () {
      fakeAsync((async) {
        var calls = 0;
        Timer? timer;
        timer = Timer.periodic(kPollInterval, (_) {
          calls++;
          if (calls == 1) timer?.cancel();  // expired ⇒ 停
        });
        async.elapse(kPollInterval * 4);
        expect(calls, 1, reason: '过期后继续轮询没有意义');
      });
    });
  });

  group('③ 产品代码里的节奏必须与本文常量一致', () {
    test('_startQrPolling 用的是 Duration(seconds: 2)', () {
      /*
       * 这条防的是"产品改了节奏，本文件还在按老节奏测" ——
       * 那种情况下 ①② 会**继续全绿但失去意义**。
       *
       * 直接读源文件做文本断言（本项目已有同类做法：t98 扫源码）。
       */
      final src = _readSource('lib/ui/widgets/provider_login_panel.dart');
      expect(
        src.contains('Timer.periodic(const Duration(seconds: 2)'),
        isTrue,
        reason: '★ 产品轮询节奏变了 —— 请同步本文件的 kPollInterval',
      );
    });

    test('catch 分支里**不许**出现 _stopQrPolling（那会让轮询永久停）', () {
      /*
       * ★★ 这是本文件最重要的一条。
       *
       * 改前的 catch 是：
       * ```dart
       * } catch (_) {
       *   _qrPolling = false;
       *   if (mounted) setState(() => _qrMsg = '网络异常，重试中…');
       *   return;
       * }
       * ```
       * 它**没有** cancel —— 所以轮询会继续。这是对的，但很脆弱：
       * 谁要是觉得"失败了就停一下吧"，用户就会永远卡住。
       *
       * 判据：catch 块内（从 `} catch (` 到下一个 `return;`）不许出现
       * `_stopQrPolling`。
       */
      final src = _readSource('lib/ui/widgets/provider_login_panel.dart');
      final start = src.indexOf('res = await SourinApi.providerQrLoginPoll');
      expect(start, greaterThan(0), reason: '找不到轮询调用点，判据失效');

      final catchAt = src.indexOf('} catch (', start);
      expect(catchAt, greaterThan(0), reason: '找不到 catch 块，判据失效');

      /*
       * ★★★ 这里必须用**正则**取 catch 块，不能用 `indexOf('return;')`
       *
       * # 我第一版就是这么写的，结果门禁**假绿**（故障注入没能变红）
       *
       * ```text
       * 注入：catch 里加一句 `_stopQrPolling();`（模拟"失败就永久停"）
       * 期望：本判据变红
       * 实测：全绿 —— 门禁是假的
       *
       * 原因：catch 块**上方**有大段注释（解释为什么要分类），
       *       注释里出现了字面量 `return`：
       *         ⚠️ 这里**只改文案，不改控制流**：仍然是「失败一次就等下一次 timer」
       *       `indexOf('return;', catchAt)` 会命中**注释里**那个，
       *       于是 catchBody 只有注释，注入的 `_stopQrPolling()` 落在区间**外**。
       * ```
       * ⇒ 改成：剥掉注释再取块。这样判据看的是**代码**，不是文档。
       */
      final tail = src.substring(catchAt);
      final codeOnly = tail
          .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')  // 块注释
          .replaceAll(RegExp(r'//[^\n]*'), '');       // 行注释
      final ret = codeOnly.indexOf('return;');
      expect(ret, greaterThan(0), reason: '找不到 catch 里的 return，判据失效');

      final catchBody = codeOnly.substring(0, ret);
      expect(
        catchBody.contains('_stopQrPolling'),
        isFalse,
        reason: '★★ catch 里调了 _stopQrPolling ⇒ 一次失败就永久停 ⇒ '
            '用户会「扫了 → 报错 → 卡住」。改前实测过这个症状。',
      );
    });
  });
}

/// 测试用的"网络异常"替身
///
/// 不用真的 `dart:io` SocketException：本文件只关心**控制流**，
/// 不关心异常类型（类型由 `zz_t66_login_poll_text_test.dart` 负责）。
class SocketExceptionLike implements Exception {
  const SocketExceptionLike(this.message);
  final String message;
  @override
  String toString() => 'SocketException: $message';
}

/// 读仓库内的源文件（测试的 cwd 是仓库根）
String _readSource(String relativePath) {
  final f = File(relativePath);
  if (!f.existsSync()) {
    throw StateError(
      '读不到 $relativePath（cwd=${Directory.current.path}）—— '
      '本判据依赖从仓库根运行 flutter test',
    );
  }
  return f.readAsStringSync();
}
