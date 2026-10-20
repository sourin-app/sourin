// ═══════════════════════════════════════════════════════════════════════
//  R3-④ 补漏：**每一个**全屏遮罩面板关闭时都必须装 350ms 守卫
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条补的是什么（Lead 2026-10-19 自查发现）
//
// ```text
// R3-④ 的修法是「接受透传，但让落点无害」：
//   面板关闭 ⇒ 播放/暂停守卫多站 350ms（_sheetGuardHold）
//   ⇒ 遮罩双击的第 2 击落到播放区时是**空操作**
//
// ★ 但第一版只给**两个**面板装了守卫：
//     _danmakuSheetOpen（弹幕设置）
//     _biliSheetOpen   （外部弹幕导入）
//
// 而播放页里 `Positioned.fill` 的全屏 scrim 一共有 **5 个**：
//     _danmakuSheetOpen / _biliSheetOpen / _streamSheetOpen
//     _liveChannelsOpen / _subtitlePanelOpen
//
// ⇒ 剩下 3 个（线路面板 / 直播频道抽屉 / 字幕面板）**照样会透传**。
//   而线路面板恰恰是操作最频繁的一个（换线路、看清晰度几乎每次都要
//   点遮罩关窗）⇒ 漏它等于这个修复在最常用的场景上不起作用。
// ```
//
// # 为什么用源码级断言（而不是行为门禁）
//
// ```text
// 行为门禁要在 flutter_test 里挂整个 PlayerPage 并让面板开合 ——
// 实测不可行：PlayerPage 依赖 libmpv（原生库），
// 在 flutter_test 里挂起来会停在 loading（本仓 `.probe` 已验过同一现象，
// 见 `test/zz_t66_r5_player_no_overlap_test.dart` 的文件头）。
// ⇒ 只能读源码。这与本仓「源码级断言只守'有没有接线'、不守语义」的口径一致。
// ```
//
// # 判据设计（为什么要成对）
//
// ```text
// ① 找出所有 `Positioned.fill` 全屏 scrim 的关闭回调（按 `_xxxOpen = false` 定位）
// ② 每个关闭回调里必须出现 `_holdSheetGuard()`
// ③ 反向：`_holdSheetGuard()` 的出现次数必须 >= scrim 数
//    —— 只靠 ② 会被"漏扫一个 scrim"骗过（扫不到 = 不用加）
// ④ 白名单必须为空或带理由（空条款 = 假绿）
// ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 播放页里所有 `Positioned.fill` 全屏浮层的开关字段
///
/// ★ 这份清单必须与 `player_page.dart` 里 `_anySheetOpen` 的定义一致 ——
///   下面 `S1` 会**机械核对**这一点，防止两边漂开。
const _scrimFlags = <String>[
  '_danmakuSheetOpen',
  '_biliSheetOpen',
  '_streamSheetOpen',
  '_liveChannelsOpen',
  '_subtitlePanelOpen',
];

/// 剥掉注释（本仓惯例：注释里引用的旧代码不许被数进去）
String _stripComments(String s) {
  final out = StringBuffer();
  var i = 0;
  String? q;
  while (i < s.length) {
    final c = s[i];
    if (q != null) {
      out.write(c);
      if (c == r'\' && i + 1 < s.length) {
        out.write(s[i + 1]);
        i += 2;
        continue;
      }
      if (c == q) q = null;
      i++;
      continue;
    }
    if (c == "'" || c == '"') {
      q = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '/') {
      while (i < s.length && s[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && i + 1 < s.length && s[i + 1] == '*') {
      i += 2;
      while (i + 1 < s.length && !(s[i] == '*' && s[i + 1] == '/')) {
        i++;
      }
      i += 2;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

void main() {
  late String src;

  setUpAll(() {
    src = _stripComments(File('lib/ui/player_page.dart').readAsStringSync());
  });

  group('R3-④ 守卫覆盖', () {
    test('S0 ★ 本门禁的边界声明（它证明了什么 / 没证明什么）', () {
      /*
       * ★★★ 2026-10-21 追加（Lead 裁决：措辞修正）。
       *
       * # 为什么必须把这句话打出来
       * ```text
       * 本文件叫「守卫覆盖」，读起来像「验证了守卫**有效**」。
       * 而它实际只验证了「17 处关闭点**都调用了** `_holdSheetGuard()`」。
       *
       * ★ 这两件事不是一回事：
       *   · 「每处都调用了」   ⇒ 源码扫描能证
       *   · 「调用后真的拦住」 ⇒ 需要真机双击，本门禁**碰不到**
       * ```
       * # 为什么不能升级成行为门禁（试过并放弃的理由）
       * ```text
       * 行为门禁要挂整个 `PlayerPage` 并让 5 个面板开合 ——
       * `PlayerPage` 依赖 libmpv（原生库），在 `flutter_test` 里挂起来会停在
       * loading（见本文件头那段与 `zz_t66_r5_player_no_overlap_test.dart`）。
       * ⇒ 只能读源码。
       *
       * ⚠️ 而 Lead 明确否决了「补一条单元级验证（构造 350ms 内的 click，
       *    断言 guard 返回 true）」这个升级方案，理由是：
       *    它证明了「guard 这个函数会返回 true」，
       *    但**仍然不证明**「用户在真机上双击不会误触到下面」——而那才是 ④ 的诉求。
       * ⇒ 判据：**不要为一个"证明不到目标"的升级花时间。**
       * ```
       */
      // ignore: avoid_print
      print('═══ R3-④ 门禁边界 ═══');
      // ignore: avoid_print
      print('  ✓ 本门禁证明：5 个全屏 scrim 的每一处关闭点都调用了 _holdSheetGuard()');
      // ignore: avoid_print
      print('  ✗ 本门禁**不**证明：调用后运行时真的拦住了落点');
      // ignore: avoid_print
      print('    ⇒ 「双击透传」的运行时行为**仍未验证**（证据等级 4：读源码）');
      // ignore: avoid_print
      print('    ⇒ 要升级需真机双击（等级 1），本门禁碰不到那一层');
    });

    test('S1 前置：scrim 清单必须与 _anySheetOpen 的定义一致', () {
      /*
       * ★ 这条防的是「清单漂移」：有人新加一个全屏浮层、
       *   顺手加进 `_anySheetOpen`，但忘了加进本文件的 `_scrimFlags`
       *   ⇒ 下面 ② 会**扫不到**它 ⇒ 门禁绿而缺陷在。
       *
       * 判据：`_anySheetOpen` 的 getter 体里出现的 `_xxxOpen` 标识符集合，
       *       必须**包含** `_scrimFlags` 里的每一个。
       *   （允许 getter 里有本文件没列的多余项 —— 那可能是非全屏的小浮层，
       *     例如 `_zoomOpen` / `_hintsOpen` / `_episodeSheetOpen`；
       *     它们是否也该加守卫由 ④ 的注释说明，不强制。）
       */
      final i = src.indexOf('bool get _anySheetOpen');
      expect(i, greaterThan(0), reason: '找不到 _anySheetOpen 的定义');
      final body = src.substring(i, src.indexOf(';', i));
      for (final f in _scrimFlags) {
        expect(
          body.contains(f),
          isTrue,
          reason: '★★ `$f` 在 _scrimFlags 里但不在 _anySheetOpen 里。\n'
              '  ⇒ 要么它已经不是全屏浮层（那就从本清单删掉），\n'
              '     要么 getter 漏了它（那播放页的其它守卫也有问题）。',
        );
      }
    });

    for (final flag in _scrimFlags) {
      test('S2 $flag 的**每一处**关闭点都必须装 _holdSheetGuard()', () {
        /*
         * ★★ 第一版这条门禁只查 `indexOf`（第一处），当场被自己抓到：
         *     `_streamSheetOpen = false` 在文件里有 **3 处**（遮罩 onClose /
         *     选线路 onPick / 面板内关闭按钮 onClose），
         *     `_liveChannelsOpen = false` 有 **2 处**，`_danmakuSheetOpen` 有 **2 处**。
         *     ⇒ 只查第一处会漏掉后面那些 ⇒ 假绿（而它正好漏掉的是
         *       **点遮罩关窗**那条路，也就是双击透传的真正入口）。
         *
         * ⇒ 改为**遍历全部**，逐个判定。
         */
        final marker = 'setState(() => $flag = false);';
        final hits = <int>[];
        var from = 0;
        while (true) {
          final i = src.indexOf(marker, from);
          if (i < 0) break;
          hits.add(i);
          from = i + marker.length;
        }
        expect(hits, isNotEmpty, reason: '找不到 `$marker`（$flag 的关闭回调）');

        final missing = <int>[];
        for (final idx in hits) {
          /*
           * ★★ 窗口必须**截到下一个关闭点之前**，不能用固定 600 字符。
           *
           * 实测教训（2026-10-19，我自己踩的）：
           *   `_StreamSheet` 的 `onPick` 与 `onClose` 是相邻的两个回调，
           *   `onPick` 的 setState 之后 600 字符内**已经包含了 onClose 的守卫**
           *   ⇒ 把 onPick 的守卫删掉，固定窗口仍然看到 `_holdSheetGuard()`
           *   ⇒ S2 **假绿**（那次是 S3 的总数交叉校验抓到的）。
           *
           * ⇒ 窗口上界 = 下一个关闭点的起点（含尾部少量余量给注释），
           *   保证「这一处的守卫」不会被下一处的守卫冒充。
           */
          final nextSite = hits
              .where((h) => h > idx)
              .fold<int>(
                  src.indexOf('setState(() => ', idx + 1) < 0
                      ? src.length
                      : src.indexOf('setState(() => ', idx + 1),
                  (a, b) => a < b ? a : b);
          final end = nextSite.clamp(idx, src.length);
          final window = src.substring(idx, end);
          if (!window.contains('_holdSheetGuard()')) missing.add(idx);
        }

        expect(
          missing,
          isEmpty,
          reason: '★★ `$flag` 有 ${hits.length} 处关闭点，其中 '
              '${missing.length} 处**没装** 350ms 守卫（字符偏移 $missing）。\n'
              '  ⇒ 遮罩双击的第 2 击会落到播放区 ⇒ 视频被暂停（就是 R3-④ 那个缺陷）。\n'
              '  ⇒ 在每个 `setState(() => $flag = false);` 之后补 `_holdSheetGuard();`。',
        );
      });
    }

    test('S3 守卫调用数必须 >= 每个 scrim 的关闭点数之和（防"漏扫一个"）', () {
      /*
       * ② 是按清单逐个查「每一处」。若清单本身漏了一个 scrim，
       * ② 会全绿而缺陷在 ⇒ 用总数做交叉校验。
       *
       * ★ 注意口径：这里比的是「**调用点数**」而不是「scrim 数」——
       *   因为一个 scrim 可能有多处关闭点（遮罩 / 面板内按钮 / 选中即关）。
       *   第一版按 scrim 数比，`5 >= 5` 恒真 ⇒ 恒真断言 = 假绿。
       */
      final calls = RegExp(r'_holdSheetGuard\(\);').allMatches(src).length;
      var totalCloseSites = 0;
      for (final flag in _scrimFlags) {
        totalCloseSites +=
            RegExp('setState\\(\\(\\) => ${RegExp.escape(flag)} = false\\);')
                .allMatches(src)
                .length;
      }
      expect(
        calls,
        greaterThanOrEqualTo(totalCloseSites),
        reason: '★★ `_holdSheetGuard();` 只出现 $calls 次，'
            '而 scrim 关闭点共 $totalCloseSites 处。\n'
            '  ⇒ 有面板关闭时没装守卫。',
      );
    });

    test('S4 自检：剥注释后不许还看得到注释里的旧代码', () {
      /*
       * 阳性对照：注释里写 `_holdSheetGuard();`，剥完必须看不见。
       * 否则 ② 会被注释骗成绿（本仓已记过这个坑）。
       */
      const fake = '''
      // _holdSheetGuard();
      /* _holdSheetGuard(); */
      setState(() => _streamSheetOpen = false);
      ''';
      final stripped = _stripComments(fake);
      expect(stripped.contains('_holdSheetGuard();'), isFalse,
          reason: '★ 剥注释失败 ⇒ S2 可能被注释里的示例骗成绿（假绿）');
      expect(stripped.contains('setState'), isTrue, reason: '剥注释不能把真代码剥掉');
    });
  });
}
