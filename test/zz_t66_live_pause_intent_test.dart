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
       *
       * ══════════════════════════════════════════════════════════════
       * ★★★ 2026-10-18 这条断言被代理审查用故障注入抓出，**修了三轮**
       * ══════════════════════════════════════════════════════════════
       *
       * ```text
       * 【第 1 版（原版，纸糊）】
       *   src.indexOf('if (_userPaused)', pendingAt)
       *   ⇒ 起始位置把搜索范围限制在 pending 之后
       *   ⇒ 守卫被挪到 pending 之前时**永远搜不到** ⇒ 恒真 ⇒ 门禁废掉
       *
       * 【第 2 版（我改的，假红）】
       *   全局 indexOf('if (_userPaused)')
       *   ⇒ 命中的是 `_onVisibilityChanged`（:928）那处守卫，不在 _watchLive 内
       *
       * 【第 3 版（我改的，仍是假红）】
       *   圈定 _watchLive 方法体后再 indexOf
       *   ⇒ ★ 命中的还是**注释**！
       *     实测 offset 1110/1786/1849 全是 JSDoc 里引用的字符串
       *     真正的代码在 offset 2853（pending）与 3539（守卫）
       * ```
       *
       * ⇒ 最终做法：**逐行扫描、剔除注释行**，在真实代码行上定位。
       *   这是 danmaku 清单 §A-3「注释命中」的典型，也是本文件第 2 次踩到。
       */
      final lines = src.split('\n');
      var inBlock = false;
      int? pendingLine;
      final guardLines = <int>[];
      for (var i = 0; i < lines.length; i++) {
        final raw = lines[i];
        final t = raw.trim();
        if (inBlock) {
          if (t.contains('*/')) inBlock = false;
          continue;
        }
        if (t.startsWith('/*')) {
          if (!t.contains('*/')) inBlock = true;
          continue;
        }
        if (t.startsWith('//') || t.startsWith('*')) continue;

        // ★ 只认「真正的语句行」：不能有反引号（注释里引用代码都带反引号）
        final code = raw.split('//').first;
        if (code.contains('`')) continue;

        if (pendingLine == null &&
            code.contains('final pending = _pendingFullscreenChannel;')) {
          pendingLine = i;
        }
        if (code.contains('if (_userPaused)')) {
          guardLines.add(i); // ★ 记录**所有**代码行里的守卫
        }
      }

      expect(pendingLine, isNotNull,
          reason: '★ 找不到 `final pending = _pendingFullscreenChannel;` 的**代码行**'
              '（若只找到注释里的引用，说明它被删了或改名了）');
      expect(guardLines, isNotEmpty,
          reason: '★ 找不到任何 `if (_userPaused) return;` 的**代码行**守卫');

      /*
       * ★ 关键：全仓有**两处**真实守卫（`_onVisibilityChanged` 与 `_watchLive`）。
       *   ⇒ 必须断言「存在**一个**守卫落在 pending 之后的同一段流程里」，
       *     而不是拿"第一个守卫"去比（那会命中文件的另一处，产生假红）。
       *
       * 实测踩到：
       *   guardLine=927（_onVisibilityChanged），pendingLine=2652（_watchLive）
       *   ⇒ 927 < 2652 ⇒ 假红。这正是我第 4 次改这条断言的原因。
       */
      final guardAfterPending =
          guardLines.where((g) => g > pendingLine! && g < pendingLine + 40);
      expect(guardAfterPending, isNotEmpty,
          reason: '★★ 在 `_watchLive` 的 pending 之后（40 行窗口内）必须有 '
              '`if (_userPaused)` 守卫 —— 否则"切台 + 恰好暂停过"⇒ 回来黑屏。\n'
              '  实测守卫行=$guardLines，pending 行=$pendingLine');
    });

    /*
     * ★★★ 2026-10-18（代理审查发现整条链路**没有测试**）：
     *
     * ```text
     * `_userWantsPause` 是整条链路的**数据源头**：
     *   player_page.dart  _togglePlay 写它（暂停置 true / 播放置 false）
     *   player_page.dart  _exitPlayer  pop<bool>(_userWantsPause) 发它
     *   live_page.dart    消费它 → _userPaused
     *
     * ★ 而在这之前，本文件里 `_userWantsPause` 出现 **0 次**。
     * 实测：删掉 `_togglePlay` 里那两行赋值 ⇒ 9/9 **全绿**
     *   ⇒ 链路永远送 false ⇒ Owner 的 bug 原样回来。
     * ```
     */
    test('★★ `_userWantsPause` 的数据源头必须双向赋值（true 与 false）', () {
      final player = File('lib/ui/player_page.dart').readAsStringSync();

      /*
       * ⚠️⚠️ 这里原来写的是 `player.contains('bool _userWantsPause')`。
       * 那是**假绿**：`bool? _userWantsPause` 里也含有子串 `bool _userWantsPause`
       * ⇒ 无论写 `bool` 还是 `bool?` 它都通过 ⇒ 断言对被测对象**没有鉴别力**。
       * ★ 与本仓反复出现的「断言没真正作用在被测对象上」是同一类。
       * ⇒ 改用正则，显式区分有没有 `?`。
       */
      expect(
        RegExp(r'bool\??\s+_userWantsPause').hasMatch(player),
        isTrue,
        reason: '★ 字段必须存在 —— 它是整条链路的数据源头',
      );

      /*
       * 必须是"暂停时置 true、播放时置 false"两向都有。
       * 只置 true ⇒ 状态泄漏（上一次暂停泄漏到下一次）；
       * 只置 false ⇒ 永远送不出 true（用户暂停被忽略）。
       */
      expect(RegExp(r'_userWantsPause\s*=\s*true').hasMatch(player), isTrue,
          reason: '★★ 必须有 `_userWantsPause = true`（用户按暂停）—— '
              '删掉它则暂停意图永远送不出去，Owner 的 bug 原样回来');
      expect(RegExp(r'_userWantsPause\s*=\s*false').hasMatch(player), isTrue,
          reason: '★★ 必须有 `_userWantsPause = false`（用户按播放）—— '
              '只置 true 会状态泄漏');

      /*
       * ★ 赋值必须在 `_togglePlay` 里 —— 那是**用户手势的唯一入口**。
       * 放到别处（比如监听 _playing 变化）会把"我们自己暂停的"也算成用户意图，
       * 导致全屏里切台后 pop(true) ⇒ 回来黑屏。
       */
      final toggleAt = player.indexOf('void _togglePlay(');
      expect(toggleAt, greaterThan(0), reason: '找不到 _togglePlay');
      final toggleBody =
          player.substring(toggleAt, (toggleAt + 3000).clamp(0, player.length));
      expect(toggleBody.contains('_userWantsPause'), isTrue,
          reason: '★★ 赋值必须在 `_togglePlay` 里（用户手势唯一入口）');
    });

    // ────────────────────────────────────────────────────────────────
    //  Lead 2026-10-18 要求的三条（场景 C 的护栏）
    // ────────────────────────────────────────────────────────────────

    test('★★★ (a) 源头必须是可空且**无初始值** `bool? _userWantsPause;`', () {
      final player = File('lib/ui/player_page.dart').readAsStringSync();
      expect(
        RegExp(r'bool\?\s+_userWantsPause\s*;').hasMatch(player),
        isTrue,
        reason: '★★★ 必须是 `bool? _userWantsPause;`（可空、无初始值）。\\n'
            '无初始值 ⇒ 默认 null ⇒ 表示「用户没碰过播放键」',
      );
    });

    test('★★★ (b) 不许给初始值（给了就不是三态）', () {
      final player = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * 反例：
       *   bool? _userWantsPause = false;   ← 又变成两态
       *   bool? _userWantsPause = null;    ← 合法但多余，允许
       */
      final badInit =
          RegExp(r'bool\?\s+_userWantsPause\s*=\s*false').hasMatch(player);
      expect(
        badInit,
        isFalse,
        reason: '★★★ 找到 `bool? _userWantsPause = false;` —— '
            '给了初始值就丢掉了「没表态」这个状态，场景 C 复活',
      );
    });

    test('★★★ (c) 不许在出口把 null 压成 false', () {
      final player = File('lib/ui/player_page.dart').readAsStringSync();
      /*
       * 反例：
       *   pop<bool>(_userWantsPause ?? false)      ← null 被压成 false
       *   pop<bool>(_userWantsPause == true)       ← 同上
       *   pop<bool>(_userWantsPause!)
       */
      for (final bad in <String>[
        '_userWantsPause ?? false',
        '_userWantsPause == true',
        '_userWantsPause!',
      ]) {
        expect(
          player.contains(bad),
          isFalse,
          reason: '★★★ 出现 `$bad` ⇒ 把「没表态」压成「要播放」⇒ 场景 C 复活',
        );
      }
    });

    test('★★ `_exitPlayer` 必须把 _userWantsPause 作为 pop 的返回值', () {
      final player = File('lib/ui/player_page.dart').readAsStringSync();

      /*
       * 如果 pop 不带值（或带别的值），整条链路断在出口：
       * 用户在详情页按的暂停传不回去。
       */
      expect(player.contains('pop<bool>(_userWantsPause)'), isTrue,
          reason: '★★ 必须 `pop<bool>(_userWantsPause)` —— '
              '不带值则用户意图丢失，整条链路断在出口');
    });
  });

  group('★★★ ③ 场景 C：三态不能压成两态（Lead 2026-10-18 派）', () {
    late String playerSrc;

    setUpAll(() {
      final f = File('lib/ui/player_page.dart');
      expect(f.existsSync(), isTrue,
          reason: '读不到 player_page.dart（cwd=${Directory.current.path}）');
      playerSrc = f.readAsStringSync();
    });

    /*
     * ★ 这条是**缺陷检测器**：现在应该是**红**的。
     *   红 = 场景 C 的缺陷存在。修好后它变绿。
     *
     * 判据：`_userWantsPause` 的类型必须是 `bool?`（三态），不是 `bool`。
     */
    test('★★★ `_userWantsPause` 必须是 bool? 而不是 bool（否则场景 C 必然发生）', () {
      // 必须存在三态声明
      expect(
        playerSrc.contains('bool? _userWantsPause'),
        isTrue,
        reason: '★★★ 场景 C：`_userWantsPause` 若声明成 `bool`，'
            '初始的 false 会同时表示「要播放」和「没表态」；'
            '⇒ 用户「进详情页什么都不做就退出」会被 pop(false)；'
            '⇒ 直播页把用户按过的暂停强制解除 ⇒ 自动续播。'
            '★ 修法：`bool? _userWantsPause;`（无初始值 = null = 没表态）',
      );
      // 不许留两态声明
      final hasTwoState = RegExp(r'bool\s+_userWantsPause\s*=\s*false').hasMatch(playerSrc);
      expect(
        hasTwoState,
        isFalse,
        reason: '★★★ 找到了 `bool _userWantsPause = false;` —— '
            '这正是场景 C 的缺陷根源',
      );
    });

    test('★★★ `_exitPlayer` 必须原样把三态带出去（不许压成 bool）', () {
      /*
       * 反例（都错）：
       *   pop<bool>(_userWantsPause ?? false)    ← 把「没表态」当成「要播放」
       *   pop<bool>(_userWantsPause == true)     ← 同上
       * 正解：
       *   pop<bool?>(_userWantsPause)
       */
      final badNull = RegExp(r'pop<bool>\s*\(\s*_userWantsPause\s*\?\?').hasMatch(playerSrc);
      expect(
        badNull,
        isFalse,
        reason: '★★★ `pop<bool>(x ?? false)` 把「没表态」压成「要播放」⇒ 场景 C 复活',
      );
      expect(
        playerSrc.contains('_userWantsPause ?? false'),
        isFalse,
        reason: '★★★ 任何 `?? false` 都会丢掉「没表态」这个状态',
      );
    });

    test('★★★ live_page 侧的三态判据必须保留（它已兼容，防被改回 != null 之外）', () {
      final live = File('lib/ui/live_page.dart').readAsStringSync();
      expect(
        live.contains('if (pausedInFullscreen != null)'),
        isTrue,
        reason: '★ live_page 侧必须是 `!= null` 才赋值 —— 这是三态的下游',
      );
    });
  });
}

// ══════════════════════════════════════════════════════════════════════
//  ★★★ 场景 C（2026-10-18，Lead 派）：**三态**不能压成两态
// ══════════════════════════════════════════════════════════════════════
//
// # 缺陷（静态可证，不需要运行时）
// ```text
// player_page.dart:1485   bool _userWantsPause = false;   ← 初始值 false
// 它只在 _togglePlay 的两个分支被改（:11261 / :11264）
// _exitPlayer 无条件 pop<bool>(_userWantsPause)
//
// ⇒ 用户「打开详情页什么都不做就退出」必然 pop(false)
// ⇒ live_page: if (false != null) ⇒ _userPaused = false
// ⇒ 把用户**在直播页里按过的暂停**强制解除 ⇒ 自动续播
// ```
//
// # 正确的语义是**三态**
// ```text
// null  = 用户没碰过播放键（「我没表态」）
// true  = 用户明确要暂停
// false = 用户明确要播放
//
// ★ 用 `bool` 时，初始的 false 同时表示「要播放」和「没表态」
//   ⇒ 这两种情况**必须**分开，否则场景 C 必然发生
// ```
//
// # live_page 侧**不用改**
// ```text
// 它已经写的是 `if (pausedInFullscreen != null) _userPaused = pausedInFullscreen;`
// ⇒ null 时不动，true/false 时才动 —— 三态天然兼容
// ```
