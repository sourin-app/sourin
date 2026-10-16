// ═══════════════════════════════════════════════════════════════════════
//  OPS-17 回归门禁：退出路径必须把「最后一次偏好」真的写进磁盘
// ═══════════════════════════════════════════════════════════════════════
//
// # 现象（OPS-15 的 agent 主动上报，Lead 采纳）
// 用户点一下开关 / 关窗行为刚被记住，只要在 **300ms 内退出进程**，
// 这一次偏好就永远丢了 —— 下次打开还是旧值。
//
// # 根因（一句话）
// `lib/core/ui_prefs.dart:107-113` 的 `_flushSoon()` 是
// `Future.delayed(300ms)` 去抖；而退出路径
// （`lib/core/app_tray.dart:446 _destroyAndClose()`）从不等它 ——
// 进程一退，那次 `writeAsString` 永远不会发生。
//
// # 判据口径（★ 唯一合法的证据）
// 断言「**盘上** ui-prefs.json 里 key 的值就是 v」——直接从文件读回来，
// 绕开 `UiPrefs` 的内存。
// ✗ 「调了 flush 不抛异常」不算证据；
// ✗ 「内存里 `UiPrefs.get(k) == v`」也不算（`set()` 本来就先改内存）。
//
// # ⚠️ 测试自身的两个坑（OPS-15 踩过，别重踩）
// 1. `flush()` / `load()` 是**真文件 I/O**：`testWidgets` 的 body 跑在
//    FakeAsync 下，真 I/O 的 Future 永远不会在假时钟下完成 ⇒
//    退出路径与读盘都必须放进 `tester.runAsync`（放回真实事件循环）。
// 2. `UiPrefs.set()` 会起一个 300ms 的 `_flushSoon` 定时器；用例结束时
//    它还挂着 ⇒ flutter_test 直接判「A Timer is still pending even after
//    the widget tree was disposed」。每次写完偏好都要 `drainPrefs()` 排干。
//
// ★ 而**正是**坑 1 让本文件成为真门禁：假时钟不推过 300ms，
//   于是「用户 300ms 内退出」这个时序被精确复现 —— 退出路径不补 flush，
//   盘上就什么都没有（RED 见报告）。
//
// # 覆盖的退出路径（完整清单见报告）
//   ① 点 X ⇒ `onWindowClose()` ⇒ `_handleClose()` ⇒ action==quit ⇒ `quitNow()`
//   ② 托盘右键菜单「退出」⇒ `onTrayMenuItemClick(key:'quit')` ⇒ `quitNow()`
//   ③ 直调 `quitNow()`（漏斗本身，`_askOnce` 的两条分支也走它）
//   ④ 退出中再来一次关闭事件 ⇒ `onWindowClose()` 的 `_quitting` 重入分支
// 四条最终都汇聚到 `_destroyAndClose()`。
//
// # ★ 2026-10-15 适配：快照点从 destroy 改到「关窗调用」
// ```text
// OPS-18 修「右键托盘退出卡死」时把收尾从 destroy() 改成了 close()：
//   destroy() → PostQuitMessage(0)                   不销毁窗口 ⇒ 引擎拆除死锁
//   close()   → PostMessage(WM_SYSCOMMAND, SC_CLOSE) 走正常关窗 ⇒ 干净退出
// 且 close() 是**异步投递**、会被托盘菜单的模态循环吃掉 ⇒ 改成「确认落地 +
// 重投最多 3 次」，destroy() 退化成最后兜底。
//
// ⇒ 本文件原来的快照点（destroy 那一刻）在新实现里**不再是必经之路**，
//   于是 ①②③④ 全红 —— 那是判据的**前提**过期，不是判据本身错。
//   处置不是放宽判据，而是把快照点挪到**等价的终结点**：
//   「进程即将没了的那个瞬间」= 真正请求关窗的那一刻（close 或 destroy），
//   两者都记快照，并断言**每一个快照**都已经带着那次 set（比原来更强）。
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:sourin_spike/core/app_tray.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 与关闭行为无关的「普通偏好」—— 模拟用户刚拨的那一下开关
const String kProbeKey = 'dsh.zzCrExitFlushProbe';

/// 盘上必须出现的值
const String kProbeValue = 'on';

/// 偏好文件所在的临时「数据目录」
late Directory _dataDir;

/// 原生侧桩：`window_manager` 收到过哪些方法（顺带证明真的走到了 destroy）
final List<String> wmCalls = <String>[];

/// 原生侧桩：`tray_manager` 收到过哪些方法
final List<String> trayCalls = <String>[];

/// 是否真的**请求过关窗**（新实现的主路径：`windowManager.close()`）
bool closeCalled = false;

/// 关窗请求次数（④ 重入分支要求 2 次）
int closeCount = 0;

/// `window_manager.destroy()`（最后兜底）真的被调用过
bool destroyCalled = false;

/// destroy 被调用的次数（兜底路径的证据，保留）
int destroyCount = 0;

/// 终结点总次数（close + destroy）—— 「进程即将没了」的次数
int terminateCount = 0;

/// ★★ 每一次终结点调用（close / destroy）**那一刻**盘上的偏好原文。
///
/// 用列表而不是单个值：新实现里 close 可能重投多次，
/// 强判据要求**每一次**都已经带着那次 set（任何一次为空都说明 await 顺序错了）。
List<String> terminateTimePrefs = <String>[];

/// 认领 pump 期间积压的环境异常
void _claim(WidgetTester tester) {
  while (tester.takeException() != null) {}
}

/// 偏好文件的绝对路径（`UiPrefs.load` 拼的就是这个名字）
String prefsPath() => _dataDir.path + Platform.pathSeparator + 'ui-prefs.json';

/// 读一次盘上偏好原文（终结点快照用）
String _snapshotPrefs() {
  final f = File(prefsPath());
  return f.existsSync() ? f.readAsStringSync() : '';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    _dataDir = Directory.systemTemp.createTempSync('sourin_exit_flush');
    addTearDown(() {
      // Windows 上偶尔还会被上一轮未收尾的写句柄占住 —— 临时目录清不掉
      // 与被测行为无关，不该判测试失败。
      try {
        if (_dataDir.existsSync()) {
          _dataDir.deleteSync(recursive: true);
        }
      } catch (_) {}
    });

    wmCalls.clear();
    trayCalls.clear();
    closeCalled = false;
    closeCount = 0;
    destroyCalled = false;
    destroyCount = 0;
    terminateCount = 0;
    terminateTimePrefs = <String>[];

    // 从干净初值开始（UiPrefs._data 是 static，跨用例共享）
    UiPrefs.debugResetForTest();
    // ★ 必须先 load：set() 只改内存，flush() 要有 _file 才能落盘
    await UiPrefs.load(_dataDir.path);

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      const MethodChannel('window_manager'),
      (MethodCall call) async {
        wmCalls.add(call.method);
        if (call.method == 'close') {
          closeCalled = true;
          closeCount++;
          terminateCount++;
          // ★★ 强判据的快照点（新实现的主路径）：请求关窗这一刻，
          // 偏好必须**已经在盘上**。只有退出路径真的 await 过 flush
          // 才可能成立；写成 unawaited(UiPrefs.flush()) 发出去就 close，
          // 这里会是空。
          terminateTimePrefs.add(_snapshotPrefs());
        }
        if (call.method == 'destroy') {
          destroyCalled = true;
          destroyCount++;
          terminateCount++;
          // 兜底路径同样要过强判据（真跑到这里也是「进程即将没了」的瞬间）。
          terminateTimePrefs.add(_snapshotPrefs());
        }
        if (call.method == 'isPreventClose') {
          return true;
        }
        return null;
      },
    );
    messenger.setMockMethodCallHandler(
      const MethodChannel('tray_manager'),
      (MethodCall call) async {
        trayCalls.add(call.method);
        return null;
      },
    );
    addTearDown(() {
      messenger.setMockMethodCallHandler(
        const MethodChannel('window_manager'),
        null,
      );
      messenger.setMockMethodCallHandler(
        const MethodChannel('tray_manager'),
        null,
      );
    });
  });

  /// 排干 UiPrefs 的延迟落盘。
  ///
  /// 顺序**不能反**：
  ///   ① 先在 runAsync 里把待写的偏好真正落盘（FakeAsync 下真 I/O 的
  ///      Future 永不完成，会把文件截成 0 字节）；
  ///   ② 再推 400ms 假时钟，让 _flushSoon 那个 300ms 定时器**真的到期**
  ///      （此时 _dirty 已是 false，flush 直接返回，不会再起 I/O）。
  ///
  /// ⚠️ 断言必须在本函数**之前**完成：本函数会把内存里剩下的东西写下去。
  Future<void> drainPrefs(WidgetTester t) async {
    await t.runAsync(() => UiPrefs.flush());
    await t.pump(const Duration(milliseconds: 400));
    _claim(t);
  }

  /// ★ 走一次退出路径，等原生 destroy 真的被调用，再把**盘上**的偏好读回来。
  ///
  /// 整个过程都在 `t.runAsync` 里 —— 真文件 I/O + 真 MethodChannel 回调
  /// 都必须在真实事件循环上，否则 FakeAsync 下永远不完成。
  Future<Map<String, dynamic>> runExitAndReadDisk(
    WidgetTester t,
    Future<void> Function() exit,
  ) async {
    final raw = await t.runAsync(() async {
      // onWindowClose() / onTrayMenuItemClick() 内部是 unawaited，
      // 这里发起之后靠下面的轮询等它跑完（最多 3s，正常几十毫秒）。
      final int before = terminateCount;
      await exit();
      // 等**本轮**这次退出真的走到终结点（close 或 destroy；
      // ④ 之前已经走过一次，所以不能只看布尔）
      for (int i = 0; i < 300 && terminateCount == before; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      // destroy 之后让退出流程把剩下的 await 走完，避免和读盘抢时序
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final f = File(prefsPath());
      return f.existsSync() ? await f.readAsString() : null;
    });
    if (raw == null) return <String, dynamic>{};
    final m = jsonDecode(raw);
    return m is Map ? m.map((k, v) => MapEntry(k.toString(), v)) : {};
  }

  /// 挂一棵空树（让 `tester.pump` 有帧可推），并把托盘/窗口接管打开。
  Future<void> boot(WidgetTester t) async {
    await t.pumpWidget(const SizedBox());
    await t.runAsync(() => AppTray.instance.start());
    _claim(t);
  }

  /// 断言「退出前那次 set 真的落盘了」的公共判据
  void expectLanded(Map<String, dynamic> onDisk, {required String where}) {
    expect(
      onDisk[kProbeKey],
      kProbeValue,
      reason: '★★★ $where：退出前那次 UiPrefs.set 必须落进 ui-prefs.json'
          '（key=$kProbeKey，期望值 $kProbeValue）；'
          '否则「刚拨的开关 / 刚记住的关闭行为」在 300ms 内退出就丢了。'
          '文件内容=' + jsonEncode(onDisk),
    );
  }

  /// ★★ 强判据：**每一次**终结点调用（close / destroy）**那一刻**，
  /// 偏好必须已经在盘上。
  ///
  /// 为什么需要它：只断言「退出跑完 + 盘上有值」的话，
  /// `unawaited(UiPrefs.flush())` 也能过 —— 退出流程里那一长串 await
  /// 会顺手把写盘跑完，测试变成假门禁。
  /// 但真机上关窗之后进程就没了，没有「顺手跑完」这回事，
  /// 所以必须把快照点钉在「真正请求关窗」的那一刻。
  ///
  /// ★ 断言**每一个**快照（而不是最后一个）：新实现会重投 close，
  ///   只要有任何一次是空的，就说明 await 顺序错了。
  /// [from] 用于 ④：那里会先跑一次完整退出，而那次退出**发生在**
  /// `UiPrefs.set(kProbeKey, …)` 之前 —— 它的快照本来就不该有这次的值，
  /// 只检查本轮（第二次）退出产生的快照。
  void expectLandedAtTerminate({required String where, int from = 0}) {
    expect(terminateTimePrefs.length, greaterThan(from),
        reason: '★★★ $where：退出路径一次关窗请求都没发出（close/destroy 都没调用）');
    for (var i = from; i < terminateTimePrefs.length; i++) {
      expect(
        terminateTimePrefs[i],
        contains('"' + kProbeKey + '":"' + kProbeValue + '"'),
        reason: '★★★ $where：第 ${i + 1} 次关窗请求被调用时，偏好必须**已经在盘上**'
            '（证明退出路径真的 await 过 flush，而不是 unawaited 发出去就退）。'
            '那一刻的盘上内容=' + terminateTimePrefs[i],
      );
    }
  }

  // ① 点 X ⇒ onWindowClose()（上次记住的是「彻底退出」）

  testWidgets('★★① 点 X（上次记住=彻底退出）⇒ 退出前那次 set 必须落盘', (t) async {
    await boot(t);

    // ★ 用户刚拨的开关（与退出无关的普通偏好）
    UiPrefs.set(kProbeKey, kProbeValue);
    // ★ 关闭行为被记住 = 退出前的最后一次 set（rememberCloseAction）
    UiPrefs.set(AppTray.closeActionKey, 'quit');
    expect(UiPrefs.get(AppTray.closeActionKey), 'quit',
        reason: '前置：内存里已经记住了（set 先改内存，这一步不是证据）');

    // ★ 300ms 还没到就退出 —— 假时钟不推过 300ms，去抖定时器不会触发
    final onDisk = await runExitAndReadDisk(
      t,
      () async => AppTray.instance.onWindowClose(),
    );

    expect(closeCalled, isTrue,
        reason: '前置：退出路径真的请求过关窗（windowManager.close()）'
            '（调用序列=' + wmCalls.join(',') + '）');
    expect(onDisk[AppTray.closeActionKey], 'quit',
        reason: '★★★ 关闭行为必须落盘：文件内容=' + jsonEncode(onDisk));
    expectLanded(onDisk, where: '点 X');
    expectLandedAtTerminate(where: '点 X');

    await drainPrefs(t);
  });

  // ② 托盘右键菜单「退出」

  testWidgets('★★② 托盘菜单「退出」⇒ 退出前那次 set 必须落盘', (t) async {
    await boot(t);

    UiPrefs.set(kProbeKey, kProbeValue);

    final onDisk = await runExitAndReadDisk(
      t,
      () async => AppTray.instance.onTrayMenuItemClick(
        MenuItem(key: 'quit', label: '退出'),
      ),
    );

    expect(closeCalled, isTrue,
        reason: '前置：托盘「退出」真的请求过关窗（windowManager.close()）'
            '（调用序列=' + wmCalls.join(',') + '）');
    expectLanded(onDisk, where: '托盘菜单退出');
    expectLandedAtTerminate(where: '托盘菜单退出');

    await drainPrefs(t);
  });

  // ③ 直调漏斗 quitNow()（_askOnce 的两条分支也走它）

  testWidgets('★★③ 直调 quitNow() ⇒ 退出前那次 set 必须落盘', (t) async {
    await boot(t);

    UiPrefs.set(kProbeKey, kProbeValue);

    final onDisk = await runExitAndReadDisk(
      t,
      () => AppTray.instance.quitNow(),
    );

    expect(closeCalled, isTrue,
        reason: '前置：close 被调用（调用序列=' + wmCalls.join(',') + '）');
    expectLanded(onDisk, where: 'quitNow 漏斗');
    expectLandedAtTerminate(where: 'quitNow 漏斗');

    await drainPrefs(t);
  });

  // ④ 退出流程中又来了一个关闭事件（用户再点一下 X）⇒ _quitting 重入分支

  testWidgets('★★④ 退出中再来一次关闭事件 ⇒ 重入分支也要落盘', (t) async {
    await boot(t);

    // 先真的退出一次 ⇒ _quitting 置位（真实场景：用户已经点了退出）
    await runExitAndReadDisk(t, () => AppTray.instance.quitNow());
    expect(closeCalled, isTrue, reason: '前置：第一次退出已请求关窗（close）');

    // 退出收尾期间又有东西写了偏好（例：关闭确认对话框刚记住选择），
    // 紧接着第二个 WM_CLOSE 到达 ⇒ 走 onWindowClose() 的 _quitting 重入分支
    UiPrefs.set(kProbeKey, kProbeValue);

    // ★ 只检查本轮退出产生的终结点快照（上一次退出早于这次 set）
    final int snapBefore = terminateTimePrefs.length;

    final onDisk = await runExitAndReadDisk(
      t,
      () async => AppTray.instance.onWindowClose(),
    );

    expectLanded(onDisk, where: '退出中的重入关闭事件');
    expect(closeCount, 2,
        reason: '前置：重入分支确实又请求了一次关窗（close 次数=$closeCount）');
    expectLandedAtTerminate(where: '退出中的重入关闭事件', from: snapBefore);

    await drainPrefs(t);
  });
}
