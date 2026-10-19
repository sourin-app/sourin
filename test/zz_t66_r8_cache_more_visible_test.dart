// ═══════════════════════════════════════════════════════════════════════
//  task-66 R8 ·「已缓存」页「更多」按钮的**可见性**门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 原话
// ```text
// 已缓存页删除徽标看不清
// ```
//
// # 根因（已查实，本文件只负责钉住修好后的行为）
// ```text
// 改前：AnimatedOpacity(opacity: _hover ? 1 : 0) + IgnorePointer(ignoring: !_hover)
//       `_hover` **只**由 MouseRegion.onEnter/onExit 驱动（鼠标专属事件）
// ⇒ 触屏 / 遥控(TV) / 键盘用户拿不到 hover ⇒ 恒 0 + 恒忽略指针
// ⇒ 那枚「更多」**从未出现过**（它背后挂着「删除整部」）。
//
// 对比度本身是合格的（深色 18.86:1 / 浅色 5.89:1，远超 AA）——
// 所以 Owner 说的「看不清」= 根本没显示，不是配色问题。
// ```
//
// # 判据为什么必须读**树上的 widget**，不能 grep 源码
// ```text
// 旧写法的特征串 `_hover ? 1 : 0` 在新写法里可以"看起来改过"却仍然走老分支
// （例如把判据算出来又丢掉、或者忽略指针忘了改）。
// ⇒ 本文件直接从渲染树上取 **AnimatedOpacity.opacity** 与
//   **IgnorePointer.ignoring** 两个真值，两个 case 各断言一遍。
// ```
//
// ⚠️ 只渲 `_CacheWorkCard`（私有）—— 通过真 CachePage + 真扫盘挂上去，
//    不 mock 文件系统（同目录既有探针的纪律）。

import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:flutter/gestures.dart'
    show
        PointerAddedEvent,
        PointerDeviceKind,
        PointerHoverEvent,
        PointerRemovedEvent;
import 'package:flutter/widgets.dart' show Brightness, Size, ValueKey, Widget;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart' as mui;

import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/cache_page.dart';

// ══════════════════════════════════════════════════════════════════════
//  沙盒（绝对路径 + 收尾自清理，绝不落仓库根）
// ══════════════════════════════════════════════════════════════════════

Directory _sandbox() {
  final p = '${Directory.systemTemp.absolute.path}'
      '${Platform.pathSeparator}sourin_t66_r8';
  final d = Directory(p);
  if (!d.isAbsolute) fail('★ 沙盒必须是绝对路径，实际 = $p');
  d.createSync(recursive: true);
  return d;
}

Widget _appWith({required Widget home}) {
  final theme = AppTheme.themeFor(Brightness.dark);
  return mui.MaterialApp(theme: theme, home: home);
}

void _claim(WidgetTester t) {
  while (t.takeException() != null) {}
}

// ══════════════════════════════════════════════════════════════════════
//  从**真树**上读那两个值
// ══════════════════════════════════════════════════════════════════════

/// 目标卡片上那枚「更多」的 opacity
double _moreOpacity(WidgetTester t, String dirName) {
  final f = find.byKey(ValueKey<String>('cache-card-more:$dirName'));
  expect(f, findsOneWidget,
      reason: '★ 「更多」按钮必须在树上（它现在只是"透明度/命中"不同）');
  final w = t.widget<mui.AnimatedOpacity>(f);
  return w.opacity;
}

/// 目标卡片上那枚「更多」外层 `IgnorePointer.ignoring`
bool _moreIgnoring(WidgetTester t, String dirName) {
  final f = find.ancestor(
    of: find.byKey(ValueKey<String>('cache-card-more:$dirName')),
    matching: find.byType(mui.IgnorePointer),
  );
  expect(f, findsWidgets, reason: '★ 「更多」外面必须包着 IgnorePointer');
  // 取**最近的那一层**（.first 是离它最近的祖先）
  final w = t.widget<mui.IgnorePointer>(f.first);
  return w.ignoring;
}

// ══════════════════════════════════════════════════════════════════════
//  挂载
// ══════════════════════════════════════════════════════════════════════

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;

  setUp(() {
    UiPrefs.remove(DownloadDir.kDirKey);
    DownloadDir.debugReset();
    DownloadQueue.debugReset();
    root = Directory(
      '${_sandbox().path}${Platform.pathSeparator}'
      'case-${DateTime.now().microsecondsSinceEpoch}',
    )..createSync(recursive: true);
    CachePage.debugScanRootOverride = root.path;
    DownloadDir.setConfiguredDir(root.path);
  });

  tearDown(() {
    CachePage.debugScanRootOverride = null;
    // ★ R8：粘滞位是**进程级**的 ⇒ 不复位会串到下个用例
    CachePage.debugResetHoverCapability();
    UiPrefs.remove(DownloadDir.kDirKey);
    DownloadDir.debugReset();
    DownloadQueue.debugReset();
  });

  tearDownAll(() {
    final d = Directory(
      '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
      'sourin_t66_r8',
    );
    if (!d.isAbsolute) fail('★ 清理路径必须是绝对路径，实际 = ${d.path}');
    if (d.existsSync()) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {
        // 句柄仍被占用 ⇒ 留在 TEMP（下次 setUp 会用新 case 目录）
      }
    }
  });

  /// 造一部剧（真文件，走真扫盘）
  String makeWork(String name) {
    final dir = Directory('${root.path}${Platform.pathSeparator}$name')
      ..createSync(recursive: true);
    File('${dir.path}${Platform.pathSeparator}第01集 a.mp4')
        .writeAsBytesSync(List<int>.filled(1024 * 512, 0x41));
    return name;
  }

  /// 挂真 CachePage，等真扫盘落定
  ///
  /// ⚠️ 必须 runAsync：扫盘是真 IO，fake 时钟里那 future 永不完成。
  Future<void> pumpPage(WidgetTester t, {required bool hwHover}) async {
    await t.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => t.binding.setSurfaceSize(null));

    // ★ 注入的只有「这台设备有没有能悬停的指针」这一个能力位；
    //   分支逻辑仍是 cache_page.dart 里那一份（不是测试自己写的 if）。
    CachePage.debugHoverableOverride = hwHover;
    addTearDown(() => CachePage.debugHoverableOverride = null);

    await t.runAsync(() async {
      await t.pumpWidget(_appWith(home: const mui.Scaffold(body: CachePage())));
      for (var i = 0; i < 30; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await t.pump();
      }
    });
    await t.pump(const Duration(milliseconds: 400));
    _claim(t);

    final st = t.state<CachePageState>(find.byType(CachePage));
    expect(st.debugWorkCount, greaterThan(0),
        reason: '★ 前置：真扫盘必须扫到剧（否则测的是一个空页面）');
  }

  // ══════════════════════════════════════════════════════════════════
  //  case ①：**不能悬停**（触屏 / 遥控 / 键盘）⇒ 常显 + 可点
  // ══════════════════════════════════════════════════════════════════

  testWidgets('★★★ case ① hoverable=false ⇒ 「更多」常显（opacity 1）且可点',
      (t) async {
    final name = makeWork('触屏上的剧');
    await pumpPage(t, hwHover: false);

    final op = _moreOpacity(t, name);
    final ig = _moreIgnoring(t, name);
    debugPrint('[R8] hoverable=false ⇒ opacity=$op ignoring=$ig');

    expect(op, 1.0,
        reason: '★★★ 触屏/遥控用户拿不到 hover ⇒ 必须**常显**。'
            '改前这里是 0.0（按钮从未出现过）');
    expect(ig, isFalse,
        reason: '★★★ 常显必须同时可点 —— 背后挂着「删除整部」，'
            'IgnorePointer.ignoring=true 等于没有删除入口');
  });

  // ══════════════════════════════════════════════════════════════════
  //  case ②：**能悬停**（桌面有鼠标）⇒ 保持原行为：hover 才显形
  // ══════════════════════════════════════════════════════════════════

  testWidgets('★★★ case ② hoverable=true ⇒ 未悬停时隐藏（opacity 0、不可点）',
      (t) async {
    final name = makeWork('鼠标上的剧');
    await pumpPage(t, hwHover: true);

    final op = _moreOpacity(t, name);
    final ig = _moreIgnoring(t, name);
    debugPrint('[R8] hoverable=true 未悬停 ⇒ opacity=$op ignoring=$ig');

    expect(op, 0.0,
        reason: '★★★ 有鼠标时**必须保持** Owner 要的"危险操作按需浮现"，'
            '不能因为修触屏就把桌面也改成常显');
    expect(ig, isTrue,
        reason: '★★★ 隐藏时必须忽略指针，否则透明按钮仍然吃掉点击');
  });

  // ══════════════════════════════════════════════════════════════════
  //  case ② 续：悬停后显形（证明「能悬停」这一支**真的还在走 hover**
  // ══════════════════════════════════════════════════════════════════

  testWidgets('★★ case ② 续：hoverable=true + 真悬停 ⇒ 显形且可点', (t) async {
    final name = makeWork('悬停显形的剧');
    await pumpPage(t, hwHover: true);

    // 前置：悬停前是隐藏的
    expect(_moreOpacity(t, name), 0.0, reason: '前置：悬停前必须隐藏');

    // 发一个真 hover 事件到卡片上
    final poster = find
        .ancestor(
          of: find.text(name),
          matching: find.byType(mui.Column),
        )
        .last;
    await t.sendEventToBinding(
      PointerHoverEvent(
        position: t.getCenter(poster),
        kind: PointerDeviceKind.mouse,
      ),
    );
    await t.pumpAndSettle();

    final op = _moreOpacity(t, name);
    final ig = _moreIgnoring(t, name);
    debugPrint('[R8] hoverable=true 悬停后 ⇒ opacity=$op ignoring=$ig');
    expect(op, 1.0, reason: '★★ 有鼠标时悬停仍必须显形（原行为不许回退）');
    expect(ig, isFalse, reason: '★★ 显形后必须可点');
  });

  // ══════════════════════════════════════════════════════════════════
  //  case ④：粘滞位 —— 首帧"未知"不许造成按钮闪一下
  // ══════════════════════════════════════════════════════════════════
  //
  // # 这条为什么必须存在
  // ```text
  // 直接每帧读 mouseIsConnected 的话：
  //   桌面用户第一次进本页、此前从未动过鼠标
  //     ⇒ false ⇒ 按钮常显
  //     ⇒ 鼠标一动 ⇒ 变回"hover 才显" ⇒ **按钮闪一下就不见了**
  //   而且 mouseIsConnected 会反复翻转（鼠标移出窗口 → PointerRemovedEvent
  //   → _mouseStates 清空 → false → 又常显）⇒ 那就不是闪一次，是一直抖。
  // ⇒ 判据改成**单调粘滞**：见过鼠标就永久走 hover 逻辑，不再回退。
  // ```
  //
  // ⚠️ 这里走的是**真信号路径**（不注入 debugHoverableOverride），
  //    否则测的就是注入点自己、不是粘滞位。

  testWidgets('★★★ case ④ 从未见过鼠标 ⇒ 常显；见过一次后 ⇒ 恢复 hover 逻辑',
      (t) async {
    final name = makeWork('粘滞位的剧');

    // ── ① 进程刚启动、从没见过鼠标 ──
    CachePage.debugResetHoverCapability();
    CachePage.debugHoverableOverride = null; // 走真信号
    expect(CachePage.debugSeenMouse, isFalse, reason: '前置：粘滞位必须是干净的');

    await _pumpWithRealSignal(t);

    final opCold = _moreOpacity(t, name);
    final igCold = _moreIgnoring(t, name);
    debugPrint('[R8] case④ 从未见鼠标 ⇒ opacity=$opCold ignoring=$igCold '
        'seenMouse=${CachePage.debugSeenMouse}');
    expect(opCold, 1.0,
        reason: '★★★ 首帧"未知"必须按触屏处理（常显），'
            '否则鼠标一动按钮会闪一下就不见');
    expect(igCold, isFalse, reason: '★★ 常显必须可点');

    // ── ② 观察到一个鼠标设备事件 ⇒ 粘滞位置位 ──
    //
    // ★ 用**真** PointerAddedEvent 喂给 MouseTracker：这是它记录
    //   _mouseStates 的唯一入口（mouse_tracker.dart:318 _monitorMouseConnection）。
    t.binding.mouseTracker.updateWithEvent(
      PointerAddedEvent(
        position: t.getCenter(find.text(name)),
        // ★ 必须显式给 mouse：PointerAddedEvent.kind 默认是 touch，
        //   而 MouseTracker.updateWithEvent 第一行就把非 mouse/stylus 丢掉
        //   （mouse_tracker.dart:302-304）⇒ 默认值会让这条判据永远假阴性。
        kind: PointerDeviceKind.mouse,
      ),
      null,
    );
    t.binding.mouseTracker.updateAllDevices();
    await t.pump();
    debugPrint('[R8] case④ 喂入 PointerAddedEvent 后 '
        'seenMouse=${CachePage.debugSeenMouse}');
    expect(CachePage.debugSeenMouse, isTrue,
        reason: '★★ 见过鼠标之后粘滞位必须置位（ChangeNotifier 已 notify）');

    // ── ③ 粘滞位一旦置位：即使"鼠标没了"也不许回退 ──
    //
    // 这正是"反复翻转"会造成的抖动：MouseTracker 因 PointerRemovedEvent
    // 清空 _mouseStates ⇒ mouseIsConnected 回到 false。
    t.binding.mouseTracker.updateWithEvent(
      PointerRemovedEvent(
        position: t.getCenter(find.text(name)),
        kind: PointerDeviceKind.mouse,
      ),
      null,
    );
    t.binding.mouseTracker.updateAllDevices();
    await t.pump();
    debugPrint('[R8] case④ 鼠标移除后 mouseIsConnected='
        '${t.binding.mouseTracker.mouseIsConnected} '
        'seenMouse=${CachePage.debugSeenMouse}');
    expect(t.binding.mouseTracker.mouseIsConnected, isFalse,
        reason: '前置：PointerRemovedEvent 之后底层信号确实回落');
    expect(CachePage.debugSeenMouse, isTrue,
        reason: '★★★ 粘滞位必须**只升不降** —— 否则按钮会随鼠标进出窗口反复显隐');

    // ── ④ 重建页面：应走 hover 逻辑（未悬停 ⇒ 隐藏） ──
    await _pumpWithRealSignal(t, rebuild: true);
    final opWarm = _moreOpacity(t, name);
    final igWarm = _moreIgnoring(t, name);
    debugPrint('[R8] case④ 见过鼠标后重挂 ⇒ opacity=$opWarm ignoring=$igWarm');
    expect(opWarm, 0.0,
        reason: '★★★ 粘滞位置位后必须恢复"hover 才显形"（桌面的原行为），'
            '且**不再**随鼠标事件翻转');
    expect(igWarm, isTrue, reason: '★★ 隐藏时必须忽略指针');
  });
}

/// 走**真信号**路径挂页（不注入 debugHoverableOverride）
Future<void> _pumpWithRealSignal(WidgetTester t, {bool rebuild = false}) async {
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  CachePage.debugHoverableOverride = null;

  await t.runAsync(() async {
    if (rebuild) {
      // ★ 强制换一棵树：让卡片 State 重建，重新读粘滞位
      await t.pumpWidget(_appWith(home: const mui.SizedBox.shrink()));
      await t.pump();
    }
    await t.pumpWidget(_appWith(home: const mui.Scaffold(body: CachePage())));
    for (var i = 0; i < 30; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await t.pump();
    }
  });
  await t.pump(const Duration(milliseconds: 400));
  _claim(t);

  final st = t.state<CachePageState>(find.byType(CachePage));
  expect(st.debugWorkCount, greaterThan(0),
      reason: '★ 前置：真扫盘必须扫到剧');
}
