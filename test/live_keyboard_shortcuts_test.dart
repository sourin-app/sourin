// ═══════════════════════════════════════════════════════════════════════
//  第 16 项（缺口 2）：**键盘快捷键** —— 只验生产真的实现了的那些
// ═══════════════════════════════════════════════════════════════════════
//
// # 生产实现清单（先摆事实，再决定测什么）
// ```text
// `lib/ui/live_page.dart:1183` `_onHardwareKey(KeyEvent)`：
//   · `:1301-1324` Esc / goBack：先关"所有直播"面板 → 再清搜索词 → 否则放行
//   · `:1354-1363` ArrowDown / ArrowUp ⇒ `cycleChannel(±1)`（切台）
//   · 其余键 **return false**（放行）
// `lib/ui/widgets/live_embedded_player.dart`：**零** KeyEvent / 无空格暂停、
//   无 M 静音、无控件自动隐藏（`grep -n "KeyEvent|MouseRegion|autoHide"` 命中 0）
// ```
//
// # 所以本文件**只**验 ↑/↓ 切台 与 Esc 清搜索（真实路径）
// ```text
// ⚠️ 「空格暂停 / M 静音 / 控件自动隐藏 + 鼠标唤起」**生产未实现**，
//    因此**不写**用例假装覆盖（计划第 16 项的那两条缺口如实记为"未实现"，
//    源码位置见上）。反过来也不写"断言它没实现"的用例 ——
//    那会在将来真的实现时误红，等于给改进上锁。
// ```
//
// # 为什么键盘链路能在这里真跑
// ```text
// `_onHardwareKey` 的门控 ① 在**没有 ShellScope** 的独立 widget 测试里
// 会走"两个来源都拿不到 ⇒ 放行"（live_page.dart:1240-1252 的取舍），
// 门控 ② 在唯一路由上成立，门控 ③（输入框有焦点）在新 pump 里不成立
// ⇒ `sendKeyEvent` 真的能打到 `_onEarlyKey` → `_onHardwareKey`。
// ★ 这不是"绕过门控"：那三条门控的代码一行都没改，走的就是它们的放行分支。
// ```

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/live_page.dart';
import 'package:sourin_spike/ui/widgets/live_embedded_player.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

const _p = 'iptv';
final _channels = <LiveChannel>[
  const LiveChannel(id: 'c1', name: '频道一'),
  const LiveChannel(id: 'c2', name: '频道二'),
  const LiveChannel(id: 'c3', name: '频道三'),
];

/// 当前**被高亮**的频道 id 集合（真实渲染结果，不是内部字段）
Set<String> _highlighted() {
  const prefix = 'live-channel-highlight-';
  final out = <String>{};
  for (final e in find.byType(Container).evaluate()) {
    final w = e.widget;
    if (w is! Container) continue;
    final d = w.decoration;
    if (d is! BoxDecoration || d.color == null) continue;
    final k = w.key;
    if (k is! ValueKey<String>) continue;
    if (!k.value.startsWith(prefix)) continue;
    // key = live-channel-highlight-<provider>:<id>
    final row = k.value.substring(prefix.length);
    out.add(row.split(':').last);
  }
  return out;
}

Future<LivePageState> _pumpPage(WidgetTester t) async {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = const Size(1000, 680);
  addTearDown(() {
    t.view.resetPhysicalSize();
    t.view.resetDevicePixelRatio();
  });
  await t.pumpWidget(_host(const LivePage()));
  await t.pump();
  await t.pump();
  return t.state<LivePageState>(find.byType(LivePage));
}

void main() {
  setUp(() {
    LivePageState.debugLiveGroupsFetcher = () async => [
          LiveGroup(provider: _p, providerName: 'IPTV 直播', channels: _channels),
        ];
  });
  tearDown(() {
    LivePageState.debugLiveGroupsFetcher = null;
  });

  testWidgets('① ↓ 切到下一个台、↑ 切回来（真实键盘事件）', (t) async {
    await _pumpPage(t);

    // loadAll 会默认选中第一个频道
    expect(_highlighted(), {'c1'},
        reason: '前提：进页面默认选中第一个台（不然下面的"切台"无从判断）');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(_highlighted(), {'c2'},
        reason: '★★★ 按 ↓ 没切到下一个台 ⇒ `_onHardwareKey` 的 ArrowDown 分支'
            '（live_page.dart:1354）没生效，或高亮没跟着选中走');

    await t.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await t.pump();
    expect(_highlighted(), {'c3'});

    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    expect(_highlighted(), {'c2'},
        reason: '★ 按 ↑ 没回到上一个台');

    // 高亮必须**只有一个**（切台不许留下两处选中）
    expect(_highlighted().length, 1);

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('② ↑ 从第一个台回绕（不许"按了没反应"，也不许切到列表外）', (t) async {
    await _pumpPage(t);
    final before = _highlighted();
    expect(before, {'c1'});

    await t.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await t.pump();
    final after = _highlighted();

    /*
     * ★ 判据两条一起：
     *   ① 必须**真的换了台**（否则"按了没反应"与"回绕到列表外"分不开）；
     *   ② 仍然**恰好一个**台被高亮（不许 0 个 = 切到列表外，也不许 2 个 = 幽灵选中）。
     * ⚠️ 回绕到**哪一个**不由这里定：那是设计选择（首个 ⇄ 末个），
     *    把具体目标写死会把"改回绕方向"这种合法调整误判成回归。
     */
    expect(after.length, 1,
        reason: '★★ 回绕后没有任何台被高亮 ⇒ 用户按 ↑ 到了列表外（黑屏风险）');
    expect(after, isNot(before),
        reason: '★★★ 按 ↑ 什么都没发生 ⇒ 回绕分支没生效（本条与 ① 一起才能把'
            '"切台失效"和"切到列表外"分开）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('⑤ 空格 = 播放/暂停（共享动作入口，不是本页自己判键）', (t) async {
    final page = await _pumpPage(t);
    final emb =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));

    expect(page.lastPlaybackActionForProbe, isNull,
        reason: '前提：还没派发过任何动作');

    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();

    /*
     * ★ 判据用"派发了哪个动作"而不是"播放器状态变了"：
     *   测试环境没有 libmpv（`_player == null`）⇒ 真实播放态无从观测。
     *   而"动作被派发到 LivePlaybackTarget"正是**共享入口**这一层的契约：
     *   内嵌与全屏都实现同一个 `LivePlaybackTarget`，判定表只有一份。
     */
    expect(page.lastPlaybackActionForProbe, LivePlaybackAction.togglePlayPause,
        reason: '★★★ 空格没有派发播放/暂停 ⇒ `livePlaybackActionForKey` 或'
            '`_onHardwareKey` 的接线断了（第 16 项"快捷键"缺失）');
    // 按键后控件必须被唤起（否则"按了没反应"）
    expect(emb.controlsVisibleForProbe, isTrue,
        reason: '★ 按键后控件没有出现 ⇒ 用户不知道状态变了');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('⑥ M = 静音/取消静音（真实状态翻转）', (t) async {
    final page = await _pumpPage(t);
    final emb =
        t.state<LiveEmbeddedPlayerState>(find.byType(LiveEmbeddedPlayer));
    final before = emb.muted;

    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await t.pump();

    expect(page.lastPlaybackActionForProbe, LivePlaybackAction.toggleMute);
    expect(emb.muted, isNot(before),
        reason: '★★★ 按 M 静音位没变 ⇒ 动作没被真正执行（只派发没调用）');

    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await t.pump();
    expect(emb.muted, before,
        reason: '★★ 再按一次必须切回来（toggle 语义）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('⑦ 打字态按空格 / M **不许**抢键（门控③对播放键同样生效）', (t) async {
    final page = await _pumpPage(t);
    final field = find.byType(TextField).first;
    await t.enterText(field, '频道');
    await t.pump();

    // 前置：确认确实处于"打字中"（与生产 `_isTypingInField()` 同源判据）
    final primary = FocusManager.instance.primaryFocus;
    var typing = false;
    primary?.context?.visitAncestorElements((el) {
      if (el.widget.runtimeType.toString() == 'EditableText') {
        typing = true;
        return false;
      }
      return true;
    });
    expect(typing, isTrue, reason: '前置未成立：焦点不在输入框里，测的不是打字态');

    await t.sendKeyEvent(LogicalKeyboardKey.space);
    await t.pump();
    expect(page.lastPlaybackActionForProbe, isNull,
        reason: '★★★ 打字时按空格被本页抢去当播放/暂停 ⇒ 用户在输入框里打不出空格'
            '（门控③ `live_page.dart:1300 if (_isTypingInField()) return false;` 被绕过）');

    await t.sendKeyEvent(LogicalKeyboardKey.keyM);
    await t.pump();
    expect(page.lastPlaybackActionForProbe, isNull,
        reason: '★★ 打字时按 M 也不许抢（否则英文单词里带 m 就会触发静音）');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('③ 输入框有焦点时 Esc 被放行（不抢用户正在打的字）', (t) async {
    await _pumpPage(t);
    final field = find.byType(TextField).first;
    await t.enterText(field, '频道二');
    await t.pump();

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();

    /*
     * 门控 ③（live_page.dart:1278 `if (_isTypingInField()) return false;`）
     * 的语义：**打字时所有键都放行** —— 包括 Esc。
     * ★ 这是设计选择（Esc 在输入框里要先给 IME/选区用），
     *   所以断言"字还在"而不是"字被清掉"。
     * ⚠️ 我第一版就写成"Esc 一定清词"，实测红在这里（`Actual: '频道二'`）
     *    —— 那不是产品 bug，是我把门控顺序想当然了。
     */
    expect(t.widget<TextField>(field).controller!.text, '频道二',
        reason: '★ 打字时 Esc 被页抢走 ⇒ 用户没法用 Esc 取消输入法/选区');

    await t.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('④ 焦点离开输入框后 Esc 清搜索词（真实分支 live_page.dart:1318）',
      (t) async {
    await _pumpPage(t);
    final field = find.byType(TextField).first;
    await t.enterText(field, '频道二');
    await t.pump();

    /*
     * 把焦点从输入框移走（= 用户点了别处）⇒ 门控 ③ 不再拦。
     *
     * ⚠️ 这里必须 **pumpAndSettle** 而不是 `pump()`：`unfocus()` 只是把
     *    "需要更新焦点"标记上，真正的 `_applyFocusChange` 在**微任务/下一帧**。
     *    只 pump 一帧在快机器上够、在慢机器/并行跑时**不够**
     *    ⇒ 门控 ③ 仍判"在打字" ⇒ Esc 被放行 ⇒ 搜索词没清（**flaky 红**）。
     *    ★ Lead 独立复跑就撞上了这一条（+3 -1）。门禁不许 flaky。
     */
    FocusManager.instance.primaryFocus?.unfocus();
    /*
     * ⚠️ 这里**不能** `pumpAndSettle()`：它会把虚拟时间推过
     *    `LiveEmbeddedPlayerState._createDelay`（380ms），
     *    于是 `_create()` 真的去 `Player()` ⇒
     *    `Exception: MediaKit.ensureInitialized must be called …`
     *    （生产由 shell 启动时初始化；flutter_test 里没有 libmpv）。
     *    ★ 我第一次写 `pumpAndSettle()` 就是这么红的（`.probe/fixlive-keys-run1.log`），
     *      红的形式还是"搜索词没清"，很容易被误读成 Esc 分支有问题 —— 其实不是。
     * ⇒ 只推进"焦点切换"需要的那几帧（微任务 + 一帧）。
     */
    await t.pump();
    await t.pump();

    /*
     * ★ 把**前置条件本身**断言出来：焦点必须真的不在 `EditableText` 里。
     *   判据与生产 `_isTypingInField()`（live_page.dart:1367）**同源**
     *   （都是"沿 primaryFocus 的祖先找 EditableText"），
     *   所以这一条红了 = 前置没成立，下面的 ④ 结论无效 —— 不会把
     *   "前置没做到"误读成"产品缺陷"。
     */
    final primary = FocusManager.instance.primaryFocus;
    var stillTyping = false;
    primary?.context?.visitAncestorElements((el) {
      if (el.widget.runtimeType.toString() == 'EditableText') {
        stillTyping = true;
        return false;
      }
      return true;
    });
    expect(stillTyping, isFalse,
        reason: '前置未成立：焦点仍在输入框里（primaryFocus=${primary?.debugLabel}）'
            ' ⇒ 门控 ③ 会放行 Esc，测不出 ④ 要验的分支');
    expect(primary?.context?.widget.runtimeType.toString(), isNot('EditableText'));

    await t.sendKeyEvent(LogicalKeyboardKey.escape);
    await t.pump();

    expect(t.widget<TextField>(field).controller!.text, isEmpty,
        reason: '★★★ 焦点不在输入框、搜索词非空时，Esc 必须清词'
            '（`live_page.dart:1318` 那条分支；否则用户以为搜索坏了）');
    // 清完搜索后列表回到全量（不是停在"筛不出来"的空态）
    expect(find.byKey(liveChannelTileKey(_p, 'c1')), findsOneWidget);

    await t.pumpWidget(const SizedBox.shrink());
  });
}
