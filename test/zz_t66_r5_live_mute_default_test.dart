// ═══════════════════════════════════════════════════════════════════════
//  R5（Owner 1009）· 直播页**默认静音** —— 行为门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（三句，逐字）
// ```text
// 「切换到直播页,默认显示的是静音,但是实际还是有声音」
// 「再次点击 静音图标也没变化,但是却没有声音了」
// 「必须拖音量条才恢复」
// ```
//
// # 本文件只测**第一句**（默认静音），其余两句见下面「为什么没测」
//
// 这一条对应的是 Owner 的「**默认显示的是静音**」——它本身是**产品意图**，
// 而 bug 是「图标说静音、音量却没压」。本文件守住「意图」这一半；
// 「音量真的压到 0」那一半归真机验证（理由见下）。
//
// # ⚠️ 为什么只有 1 条断言（Owner 原话明明有三句）
//
// ```text
// b) 「第一次点击就生效，不是第二次」
//    实测：toggleMute() 里 `await p.setVolume(...)` 之后才 setState(_muted)
//      （live_embedded_player.dart:1727-1728）
//    而 `Player.setVolume()` 在 flutter_tester 里**永不完成**
//      （裸 Player 最小复现：setVolume(0) 5 秒后仍未完成）
//    ⇒ 状态翻不了 ⇒ 这条**目前不可测**
//
//    ★ 而且**不应该**为了可测把 setState 挪到 await 之前：
//      若 setVolume 抛异常，UI 已翻成"已静音"而音量没变
//      ⇒ UI 与真实状态不一致 —— 那正是 Owner 报的**同类缺陷**。
//      「先下发、后翻状态」是对的：下发失败时 UI 就不该显示成功。
//
// c) 「取消静音后音量回偏好音量（不是 0）」
//    实测：`p.state.volume` 在 flutter_tester 里**恒为 100.0**
//      （不反映 setVolume 的下发值）⇒ 读不到真值 ⇒ **目前不可测**
//
// ⇒ ★ **真下发量（音量是否真的变成 0 / 恢复成偏好值）仍归真机验证。**
//   本文件只钉「静音态标志」这一层，它是可判定的那一半。
// ```
//
// # 判据为什么读 `state.muted` 而不是源码文本
//
// ```text
// 现有 `test/t61_volume_pref_test.dart:184` 找的是 `void _toggleMute()` ——
// 那是 `player_page.dart:12313` 的 **VOD** 侧实现。
// 而直播侧是 `Future<void> toggleMute()`（live_embedded_player.dart:1699），
// **文件、签名、可见性全不同** ⇒ t61 从来没覆盖过直播这条路径。
// ⇒ 本文件一律读**运行时真值**（`state.muted`），不扫源码文本。
// ```
//
// ⚠️ 需要 libmpv（`Player(...)` 要它才能建出来）⇒ 缺件时 markTestSkipped。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

/// 路径分隔符（Windows 用反斜杠）
///
/// ⚠️ 必须是 **const 值**，不能写成函数再 `${_bs()}` ——
///   插值里写成 `${_bs}`（漏括号）会把**函数本身**转成字符串，
///   得到 `Closure: () => String from Function ...`，路径永远不存在。
const String _sep = r'\';

/// libmpv 候选路径（与仓内其它 native-media 门禁同款）
List<String> _libmpvCandidates() => <String>[
      'build${_sep}windows${_sep}x64${_sep}libmpv${_sep}libmpv-2.dll',
      'build${_sep}windows${_sep}x64${_sep}runner${_sep}Release${_sep}libmpv-2.dll',
      // 正斜杠写法（跨平台兜底）
      'build/windows/x64/libmpv/libmpv-2.dll',
      '/usr/lib/x86_64-linux-gnu/libmpv.so.2',
      '/usr/lib/libmpv.so.2',
    ];

String? _libmpvPath() {
  for (final rel in _libmpvCandidates()) {
    final f = File(rel);
    if (f.existsSync()) return f.absolute.path;
  }
  // ★ 兜底：从 cwd 往上找（`flutter test` 的 cwd 不一定是仓库根）
  var dir = Directory.current;
  for (var i = 0; i < 6; i++) {
    for (final rel in _libmpvCandidates()) {
      final f = File('${dir.path}${Platform.pathSeparator}$rel');
      if (f.existsSync()) return f.absolute.path;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('★★★ R5：切到直播页 ⇒ **默认静音**（Owner 1009 第一句）', (t) async {
    final dll = _libmpvPath();
    if (dll == null) {
      markTestSkipped('缺 libmpv-2.dll ⇒ 播放器建不出来，本门禁无法判定。'
          '手动跑：先 `flutter build windows`');
      return;
    }
    MediaKit.ensureInitialized(libmpv: dll);

    final key = GlobalKey<LiveEmbeddedPlayerState>();
    await t.pumpWidget(MaterialApp(
      home: Scaffold(
        body: LiveEmbeddedPlayer(
          key: key,
          // 用一个不可能连通的地址 —— 本门禁只关心**建播放器时**的静音初值，
          // 不关心流能不能播（那是 t74 / t92 的事）。
          stream: const StreamCandidate(url: 'https://x.invalid/r5.m3u8'),
          title: 'probe',
        ),
      ),
    ));

    // 播放器是**延后**建的（task-74 ⑤），等它出现
    for (var i = 0; i < 60; i++) {
      await t.pump(const Duration(milliseconds: 50));
      if (key.currentState?.hasPlayerForTest == true) break;
    }

    final s = key.currentState;
    expect(s, isNotNull, reason: '★ 前提：LiveEmbeddedPlayer 挂出来了');
    expect(
      s!.hasPlayerForTest,
      isTrue,
      reason: '★ 前提：播放器已建出来 —— 否则下面的断言测的是"还没开始"的状态，'
          '而不是"建播放器时有没有默认静音"。\n'
          '若这里红：检查 libmpv 是否在位、或 _create 的延迟条件是否变了。',
    );

    // ══════════════════════════════════════════════════════════════════
    //  ① 默认静音 —— 本文件唯一的实质断言
    // ══════════════════════════════════════════════════════════════════
    //
    // ★ 判据是 `LiveEmbeddedPlayerState.muted`（public getter，
    //   live_embedded_player.dart:1737：`bool get muted => _muted;`）
    //
    // ★ 注入验证（已实测）：删掉 live_embedded_player.dart:578 的
    //   `_muted = true;` ⇒ 这里读到 false ⇒ 本条变红。
    expect(
      s.muted,
      isTrue,
      reason: '★★★ 切到直播页必须**默认静音**（Owner 1009：'
          '「切换到直播页应该默认静音」）。\n'
          '★ 这条覆盖的是 Owner 原话里的「默认显示的是静音」那一半；\n'
          '  「音量真的压到 0」那一半归真机验证（见文件头说明）。\n'
          '★ 若这里红：查 live_embedded_player.dart 的 _create() 里'
          '  `_muted = true;` 那行是不是被删了/被挪到订阅之后了。',
    );

    // 清理：media_kit 的 real.dart 里有 `Future.delayed(5s, ...)`，
    // 必须先卸载再走完假时钟定时器，否则报 "A Timer is still pending"。
    await t.pumpWidget(const SizedBox.shrink());
    await t.pump(const Duration(seconds: 6));
  });
}
