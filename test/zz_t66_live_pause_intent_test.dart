// ═══════════════════════════════════════════════════════════════════════
//  门禁：全屏播放页的「用户暂停意图」必须传回直播页
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（2026-10-18 12:55）
// > 进直播详情页,点击暂停,出来还在播放,状态没统一,切换页面之后
// > 直播应该暂停播放,而不是继续播放
//
// # 改前的缺陷（**状态源**不通）
// ```text
// `_userPaused` 只由**内嵌播放器**上报（onUserPause 回调），
// 而那个回调又被可见性门控挡住 ⇒ 用户在**播放页**里按的暂停
// 永远写不进 `_userPaused` ⇒ `if (_userPaused) return;` 恒不成立
// ⇒ 走到 `await st.resume()` ⇒ 出来还在播。
// ```
//
// # 两条自动续播路径（只删一条没用）
// ```text
// ① `_watchLive` 收尾的 `await st.resume();`           （全屏返回）
// ② `_onVisibilityChanged` 里的 `unawaited(st.resume())`（切走再切回）
// ⇒ 所以修的是**状态源**（_userPaused），不是出口。
// ```
//
// # 这组断言的价值
// ```text
// ★ 核心不是「true 时置位」—— 那太简单。
//   核心是 **null ≠ false** 这条语义：
//     null  = 没有信号（其他入口/降级）⇒ **不改变**现有状态
//     false = 用户明确表达了"要播放"    ⇒ 必须把 true 改回 false
//   如果只写 `if (x == true) _userPaused = true;`，
//   会出现**状态泄漏**：上一次的 true 压住这一次的 false。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 复刻产品代码里的判据（`lib/ui/live_page.dart` 的 `_watchLive` 收尾）
///
/// ```dart
/// if (pausedInFullscreen != null) {
///   _userPaused = pausedInFullscreen;
/// }
/// ```
///
/// ⚠️ 这个函数**故意与产品代码同形**：如果产品改成 `== true` 才置位，
///    本文件的 ② 组会红（见下面的源码断言）。
bool applyUserPaused(bool current, bool? fromPlayer) {
  if (fromPlayer == null) return current; // 未知 ⇒ 不改变
  return fromPlayer; // true / false 都改
}

void main() {
  group('① 纯函数语义：null ≠ false', () {
    test('pop(true) ⇒ 置 true（回来不续播）', () {
      expect(applyUserPaused(false, true), isTrue);
      expect(applyUserPaused(true, true), isTrue);
    });

    test('pop(false) ⇒ 置 false（回来照旧续播）', () {
      expect(applyUserPaused(true, false), isFalse,
          reason: '★ 必须能把上一次的 true 清回 false');
      expect(applyUserPaused(false, false), isFalse);
    });

    test('★★ pop(null) ⇒ **不改变**现有状态', () {
      expect(applyUserPaused(true, null), isTrue,
          reason: '★ null = 未知，不能当成"要播放"去清掉用户的暂停意图');
      expect(applyUserPaused(false, null), isFalse,
          reason: '★ null 也不能当成"要暂停"');
    });

    test('★★ 状态泄漏回归：连续两次进入，第二次没暂停 ⇒ 必须能续播', () {
      /*
       * Leader 指出的真实泄漏路径：
       * ```text
       * 第 1 次进全屏：用户按了暂停 ⇒ pop(true)  ⇒ _userPaused = true
       * 第 2 次进全屏：用户**没**按暂停 ⇒ pop(false)
       *   若只写「== true 才置位」⇒ false 分支什么都不做
       *   ⇒ _userPaused 仍是 true ⇒ 这次不该暂停却被上次的意图拦住
       * ```
       */
      var s = false;
      s = applyUserPaused(s, true); // 第 1 次：暂停
      expect(s, isTrue);
      s = applyUserPaused(s, false); // 第 2 次：没暂停
      expect(s, isFalse, reason: '★★ 这是状态泄漏的回归点');
    });
  });

  group('★★ ② 源码断言：产品代码真的用了这个语义', () {
    late String src;

    setUpAll(() {
      final f = File('lib/ui/live_page.dart');
      expect(f.existsSync(), isTrue,
          reason: '读不到 live_page.dart（cwd=${Directory.current.path}）'
              '—— 本判据依赖从仓库根运行 flutter test');
      src = f.readAsStringSync();
    });

    test('签名必须是 Future<bool?>（不是 Future<void>）', () {
      expect(
        src.contains('final Future<bool?> Function('),
        isTrue,
        reason: '★ 签名退回 Future<void> ⇒ 播放页的意图传不回来 ⇒ '
            'Owner 的 bug 复活',
      );
      expect(
        src.contains('final Future<void> Function(String provider'),
        isFalse,
        reason: '★ 旧签名不许留着',
      );
    });

    test('_watchLive 里必须接管返回值并赋给 _userPaused', () {
      expect(src.contains('final pausedInFullscreen = await cb('), isTrue,
          reason: '★ 必须接住 push 的返回值');
      expect(src.contains('_userPaused = pausedInFullscreen;'), isTrue,
          reason: '★ 必须赋给状态源（这是"修状态源不修出口"的落点）');
    });

    test('★★ 不许写成 `== true` 才置位（那会状态泄漏）', () {
      /*
       * 反例（都是错的）：
       *   if (pausedInFullscreen == true) { _userPaused = true; }
       *   if (shouldMark(r)) _userPaused = true;
       * ⇒ 它们只置 true 不清 false ⇒ 上一次的意图压住这一次。
       */
      final badPatterns = <String>[
        'if (pausedInFullscreen == true)',
        '_userPaused = pausedInFullscreen == true',
      ];
      for (final bad in badPatterns) {
        expect(src.contains(bad), isFalse,
            reason: '★★ 出现 `$bad` ⇒ 有状态泄漏风险，见 Lead 2026-10-18 的指正');
      }
      // 正例必须在
      expect(src.contains('if (pausedInFullscreen != null)'), isTrue,
          reason: '★ 正确写法是 != null');
    });

    test('★ 两条续播路径都仍然判 _userPaused（防止有人删掉其中一条的守卫）', () {
      /*
       * 路径 ①：`_watchLive` 收尾的 `await st.resume();` 前必须有 `if (_userPaused)`
       * 路径 ②：`_onVisibilityChanged` 里的 `st.resume()` 前也必须有
       *
       * 判据：全文件里 `_userPaused` 的**读取**（守卫）至少 2 处，
       *       而**写入**（赋值）不应该把守卫撑掉。
       */
      final guardCount = RegExp(r'if \(_userPaused\)').allMatches(src).length;
      expect(guardCount, greaterThanOrEqualTo(2),
          reason: '★★ 两条自动续播路径都必须有 `if (_userPaused)` 守卫，'
              '现在只找到 $guardCount 处 —— 少一条就有一条路会绕过修复');
    });

    test('★ `_pendingFullscreenChannel` 那条路必须仍在 _userPaused 之前', () {
      /*
       * 全屏里切过台 ⇒ 回来要 `_select(新台)` 并起播。
       * 那条路必须在 `if (_userPaused) return;` **之前**，
       * 否则"用户切台 + 恰好暂停过"⇒ 回来黑屏。
       */
      final pendingAt = src.indexOf('final pending = _pendingFullscreenChannel;');
      final userPausedAt = src.indexOf('if (_userPaused)', pendingAt);
      expect(pendingAt, greaterThan(0),
          reason: '找不到 _pendingFullscreenChannel 那段，判据失效');
      expect(userPausedAt, greaterThan(pendingAt),
          reason: '★★ `if (_userPaused)` 必须排在 pending 之后 —— '
              '否则切台回来会黑屏');
    });
  });
}
