// ═══════════════════════════════════════════════════════════════════════
//  T27-⑤：悬浮 popover 开着时底栏不得自动隐藏 —— 回归门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话（逐字，2026-10-11）
//
// > 鼠标悬浮在这里，然后不动之后控件消失，但是这个倍速的面板没消失，
// > 其他悬浮的面板应该也是一样的
//
// # 症状
//
//     鼠标悬浮底栏「倍速」按钮 → 面板（0.5x…3x）弹出 → 鼠标停住不动 →
//     3 秒后「停手自动隐藏」把顶/底栏一起收掉，**但面板还浮在画面上**。
//
// # 根因（两份守卫都漏了 popover）
//
//     `_autoHideNow()`（生产 Timer 回调）与 `debugAutoHideControlsForProbe`
//     探针（同一判据的同步副本）都只判 `_hintsOpen` / `_zoomOpen`，
//     漏了 `_popover.openId`。而倍速/清晰度/字幕/弹幕/「更多」五个悬浮面板
//     全走同一个 `PopoverController _popover`（真值 `_popover.openId`）。
//     ⇒ 面板开着、底栏照收 —— 面板挂在底栏按钮旁边，底栏一收面板即悬空。
//
// # 门禁口径
//
//     A 源码契约：`_autoHideNow` 的 if 守卫里**必须**出现 `_popover.openId == null`
//       （剥注释后断言，避免注释里引用旧写法造成假绿）。
//     B 两处一致：探针文档块与 `_autoHideNow` 的守卫条件逐字一致
//       （本仓纪律：探针验的必须是生产路径）。
//     C 行为契约：`PopoverController` 的开→关确实会触发一次回调
//       ⇒ 页面能借这个边沿重装隐藏计时器（缺陷 ⑤ 的第二半，见下）。
//
// # 缺陷 ⑤ 的第二半：关闭后计时器必须重装
//
//     守卫加严后，用户开着面板停手 3 秒 ⇒ `_hideTimer` 到点烧掉但被守卫拦下
//     ⇒ 底栏留着（对）。可 `_hideTimer` 已经**没了** ⇒ 若关闭面板时不重装，
//     底栏就**再也不会自动隐藏**（把「3 秒」推迟成「永久」）。
//     ⇒ 门禁 D：源码里必须存在 `_popover.addListener(...)` 的注册 + 一个
//       「开→关边沿 ⇒ _armHideTimer()」的处理函数，且 dispose 里成对摘除。
//
// ★ 为什么不做真渲染测：本机没有 libmpv-2.dll，构造 PlayerPage 必然抛异常，
//   仓库既有做法就是「读源码 + 剥注释 + 正则断言」的静态契约门禁
//   （见 test/t27_w2_progress_thumb_test.dart 与 zz_cr_play_bottom_bar_test.dart）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/player/player_popover.dart';

/// 读生产源码并剥掉注释（本仓惯例：注释里常引用旧写法，不剥会假绿/假红）
String _src(String path) {
  final raw = File(path).readAsStringSync();
  return raw
      .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), ' ')
      .replaceAll(RegExp(r'//[^\n]*'), ' ');
}

/// `_autoHideNow` 那个 if 守卫的条件串（剥注释后，从 `void _autoHideNow` 起）
String _autoHideGuard(String stripped) {
  final start = stripped.indexOf('void _autoHideNow(');
  expect(start, greaterThan(0), reason: '找不到 _autoHideNow');
  final open = stripped.indexOf('if (', start);
  final close = stripped.indexOf(') {', open);
  expect(close, greaterThan(open), reason: '找不到 _autoHideNow 的 if 守卫');
  return stripped.substring(open, close);
}

void main() {
  // PopoverController.toggle 会走 watchAnchorGeometry ⇒ 读 SchedulerBinding.instance，
  // 纯 test()（非 testWidgets）里必须先把 binding 拉起来，否则 C 会红在 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  // ────────────────────────────────────────────────────────────────
  // A：源码契约 —— 守卫**必须**含 popover 判据
  // ────────────────────────────────────────────────────────────────
  test('A：_autoHideNow 守卫必须含 _popover.openId == null（缺陷 ⑤ 的门）', () {
    final src = _src('lib/ui/player_page.dart');
    final guard = _autoHideGuard(src);

    // 修复前这里会红：守卫只有 _playing / _hintsOpen / _zoomOpen 三条。
    expect(
      guard.contains('_popover.openId == null'),
      isTrue,
      reason: '★ Owner 第⑤条：悬浮面板（倍速/清晰度/字幕/弹幕/更多）开着时，'
          '停手 3 秒不得收掉底栏 —— 守卫里必须有 _popover.openId == null。'
          '\n实际守卫：$guard',
    );
    // 既有的三条判据一条都不能丢（本任务只加不减）
    expect(guard.contains('_playing'), isTrue, reason: '_playing 判据丢了');
    expect(guard.contains('!_hintsOpen'), isTrue, reason: '_hintsOpen 判据丢了');
    expect(guard.contains('!_zoomOpen'), isTrue, reason: '_zoomOpen 判据丢了');
  });

  // ────────────────────────────────────────────────────────────────
  // B：两处守卫一致 —— 生产 Timer 回调 与 测试探针文档块
  // ────────────────────────────────────────────────────────────────
  test('B：探针文档块与 _autoHideNow 的守卫判据必须一致（都含 popover）', () {
    final src = _src('lib/ui/player_page.dart');

    // 探针文档里那段「逐字相同」的代码块被剥注释后仍在源码字符串里
    // （剥的是 / * * / 与 //，而 ```text``` 里的代码是普通文本行）
    // —— 找 `debugAutoHideControlsForProbe` 附近那段守卫文本。
    final probe = src.indexOf('void debugAutoHideControlsForProbe');
    expect(probe, greaterThan(0), reason: '找不到 debugAutoHideControlsForProbe');
    // 探针本体调用 _autoHideNow()，两者共用同一条判据
    final probeBody = src.substring(probe, probe + 120);
    expect(probeBody.contains('_autoHideNow()'), isTrue,
        reason: '探针必须调生产同一个 _autoHideNow()，不许自己再写一份判据');

    // 源码里任何一处 `_zoomOpen` 守卫都必须同时带上 popover —— 反向钉死
    // 「只改了一处、漏了另一处」这个最容易复发的情形。
    final guardSites =
        RegExp(r'if \(mounted[^\)]*_playing[^\)]*_zoomOpen[^\)]*\)')
            .allMatches(src)
            .toList();
    expect(guardSites, isNotEmpty, reason: '一个带 _zoomOpen 的守卫都没找到');
    for (final m in guardSites) {
      expect(
        m.group(0)!.contains('_popover.openId == null'),
        isTrue,
        reason: '★ 每一处 `_playing && ... && _zoomOpen` 守卫都必须同时带 '
            '`_popover.openId == null`（两处不许只改一处）。\n实际：${m.group(0)}',
      );
    }
  });

  // ────────────────────────────────────────────────────────────────
  // C：行为契约 —— PopoverController 开→关会 notify（页面靠它重装计时器）
  // ────────────────────────────────────────────────────────────────
  test('C：PopoverController 开→关会 notifyListeners（边沿可被监听）', () {
    final c = PopoverController();
    addTearDown(c.dispose);
    var n = 0;
    var lastOpen = false;
    c.addListener(() {
      n++;
      lastOpen = c.openId != null;
    });

    c.toggle(PlayerPopoverIds.rate); // 开
    expect(c.openId, PlayerPopoverIds.rate);
    final afterOpen = n;
    expect(afterOpen, greaterThan(0), reason: '开面板必须 notify（否则按钮不刷新）');

    c.close(); // 关
    expect(c.openId, isNull);
    expect(n, greaterThan(afterOpen),
        reason: '关面板必须 notify —— 页面据此在「开→关」边沿重装隐藏计时器');
    expect(lastOpen, isFalse, reason: '最后一次回调应看到的是「已关闭」');
  });

  // ────────────────────────────────────────────────────────────────
  // D：源码契约 —— 注册了监听、且在开→关边沿重装计时器、dispose 成对摘除
  // ────────────────────────────────────────────────────────────────
  test('D：页面必须监听 popover 并在开→关边沿重装隐藏计时器', () {
    final src = _src('lib/ui/player_page.dart');

    // ① 注册监听
    expect(
      RegExp(r'_popover\.addListener\(').hasMatch(src),
      isTrue,
      reason: '★ 缺陷 ⑤ 第二半：必须监听 _popover，否则关闭面板后计时器不重装',
    );
    // ② 摘除监听（dispose 里，且必须在 _popover.dispose() 之前 —— 顺序）
    expect(
      RegExp(r'_popover\.removeListener\(').hasMatch(src),
      isTrue,
      reason: '监听必须成对摘除，否则 dispose 后回调打到已卸载的 State',
    );
    final removeAt = src.indexOf('_popover.removeListener(');
    final disposeAt = src.indexOf('_popover.dispose()');
    expect(removeAt, greaterThan(0));
    expect(disposeAt, greaterThan(0));
    expect(removeAt, lessThan(disposeAt),
        reason: 'removeListener 必须在 _popover.dispose() **之前**（反了会撞已 dispose 的断言）');

    // ③ 那个监听处理函数里，判「开→关」之后必须 _armHideTimer()
    final handlerStart = src.indexOf('void _onPopoverChanged(');
    expect(handlerStart, greaterThan(0), reason: '找不到 _onPopoverChanged 处理函数');
    final handlerBody = src.substring(handlerStart, handlerStart + 400);
    expect(
      handlerBody.contains('_prevPopoverOpen') &&
          handlerBody.contains('_armHideTimer()'),
      isTrue,
      reason: '★ 监听处理必须是「开→关边沿 ⇒ _armHideTimer()」：'
          '没有 _prevPopoverOpen 做边沿过滤会把「面板开着」也当成关闭反复续命',
    );
    // 真值判据必须读 openId（与守卫同源）
    expect(handlerBody.contains('openId != null'), isTrue,
        reason: '边沿判据必须读 _popover.openId（与 _autoHideNow 同源）');
  });
}
