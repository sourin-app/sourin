// ═══════════════════════════════════════════════════════════════════════
//  CR-1015 · 「忽略此版本」必须真的记住（Owner 2026-10-15 实测）
// ═══════════════════════════════════════════════════════════════════════
//
// 用户报的现象：点了「忽略此版本」，下次打开**照样弹**。
//
// # 根因（两层，缺一不可）
// ```text
// ① 写盘是**去抖**的：UiPrefs.set() 只改内存，300ms 后由定时器落盘
//    （lib/core/ui_prefs.dart:107-113）。用户点完「忽略」随即关窗 ——
//    退出前的 flush 只挂在托盘退出路径上，走别的退出路径就丢了。
// ② 开发/探针构建（-Dev）用的是**空**数据目录 ⇒ 里面没有
//    appupdate.lastCheckAt ⇒ 24 小时节流形同不存在 ⇒ 每次启动都重新查、
//    重新弹（这一点由 isDevMode 那组用例守）。
// ```
//
// ⚠️ 这两条都会让用户看到**同一个现象**，但修法完全不同：① 是落盘时机，
//    ② 是「开发版根本不该查」。所以本文件分开守，不合并成一条。

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sourin_ignore_persist');
    UiPrefs.debugResetForTest();
    await UiPrefs.load(tmp.path);
  });

  tearDown(() async {
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  File prefsFile() => File('${tmp.path}${Platform.pathSeparator}ui-prefs.json');

  group('CR-1015 · 「忽略此版本」的落盘时机', () {
    test('点完忽略，**不等去抖**就已经在磁盘上了', () async {
      final c = AppUpdateController.instance..loadPrefs();

      await c.ignoreVersion('v9.9.9');

      // ★ 判据：ignoreVersion 返回时，磁盘上就该有它 ——
      //   用户随时可能在这一刻关窗，晚 300ms 就等于丢了。
      expect(prefsFile().existsSync(), isTrue,
          reason: '点完忽略磁盘上还没有 ui-prefs.json ⇒ 这一刻关窗就白按了');
      final disk = jsonDecode(prefsFile().readAsStringSync()) as Map;
      expect(disk['appupdate.ignoredVersion'], 'v9.9.9',
          reason: '★ 「忽略此版本」的全部意义就是「下次别再弹」，''没落盘 = 没记住');
    });

    test('模拟「点完立刻关窗」：新进程读回来仍是忽略态', () async {
      final c = AppUpdateController.instance..loadPrefs();
      await c.ignoreVersion('v9.9.9');

      // 新进程：内存清空、从同一份磁盘文件重新加载
      UiPrefs.debugResetForTest();
      await UiPrefs.load(tmp.path);
      final c2 = AppUpdateController.instance..loadPrefs();

      expect(c2.ignoredVersion, 'v9.9.9',
          reason: '重启后读不回忽略态 ⇒ 用户看到的还是「每次都弹」');
    });

    test('忽略态跨多次重启都还在（不是只活一次）', () async {
      final c0 = AppUpdateController.instance..loadPrefs();
      await c0.ignoreVersion('v9.9.9');

      for (var i = 0; i < 3; i++) {
        UiPrefs.debugResetForTest();
        await UiPrefs.load(tmp.path);
        final c = AppUpdateController.instance..loadPrefs();
        expect(c.ignoredVersion, 'v9.9.9', reason: '第 ' + (i + 1).toString() + ' 次重启丢了');
      }
    });
  });
}
