// ═══════════════════════════════════════════════════════════════════════
//  CR-1015B · 开发模式不许自动查更新、不许弹窗（Owner 2026-10-15）
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 原话：「而且开发模式不应该弹这个」。
//
// # 为什么开发模式**必然**每次都弹（不是偶发）
// ```text
// 启动检查的节流靠 appupdate.lastCheckAt（24 小时一次）。
// 而 -Dev 用的是一间**空**数据目录 ⇒ 那个键根本不存在 ⇒
// shouldAutoCheck 恒为 true ⇒ 每起一次开发版就查一次、弹一次。
// 偏偏本地 HEAD 永远比线上最新版新（线上 v1.2.0，本地早过了）
// ⇒ 这个弹窗对开发者**恒为噪声**，没有一次是有用的。
// ```
//
// # 判据为什么不写成「跑一次 run() 看它弹不弹」
// ```text
// 那样测的是**网络**：run() 里有 3 秒延迟 + 一次真实 HTTP，
// 断网/镜像挂了的机器上它本来就不弹 ⇒ 一条永远绿的假门禁。
// 这里改测**闸门本身**：shouldAutoCheck 在开发模式下必须为 false，
// 且它**先于**任何网络动作被判断（见下面那条源码级接线判据）。
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_update/app_update_controller.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sourin_devmode');
    UiPrefs.debugResetForTest();
    await UiPrefs.load(tmp.path);
    AppUpdateController.debugSetDevModeForTest(null);
  });

  tearDown(() async {
    AppUpdateController.debugSetDevModeForTest(null);
    try {
      tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('CR-1015B · 开发模式（DATA_DIR_OVERRIDE 非空）', () {
    test('★ 空数据目录 + 开发模式 ⇒ 不自动查（这正是「每次都弹」的成因）', () {
      // 先摆出那个真实条件：目录是空的，没有任何 lastCheckAt
      final c = AppUpdateController.instance..loadPrefs();
      expect(c.lastCheckAt, isNull, reason: '前提：空目录里没有上次检查时间');

      // 非开发模式下，这个前提**确实**会让它去查 —— 证明判据不是恒假
      AppUpdateController.debugSetDevModeForTest(false);
      expect(c.shouldAutoCheck, isTrue,
          reason: '正常模式下空目录就该查一次（否则这条判据恒假，测不出东西）');

      // 开发模式下同一个状态必须**不查**
      AppUpdateController.debugSetDevModeForTest(true);
      expect(c.shouldAutoCheck, isFalse,
          reason: '★ 开发模式仍然自动查 ⇒ 每起一次开发版就弹一次（Owner 报的就是这个）');
    });

    test('开发模式即使**从没查过**也不查（不是靠节流挡住的）', () {
      AppUpdateController.debugSetDevModeForTest(true);
      final c = AppUpdateController.instance..loadPrefs();
      expect(c.autoCheck, isTrue, reason: '用户开关本身是开着的（挡它的不是这个开关）');
      expect(c.lastCheckAt, isNull, reason: '确实从没查过');
      expect(c.shouldAutoCheck, isFalse);
    });

    test('开发模式不影响**手动**检查：关于页那条路照样能用', () async {
      AppUpdateController.debugSetDevModeForTest(true);
      final c = AppUpdateController.instance..loadPrefs();

      // 不出网：把 API 指到一个必然连不上的地址，只验「它**真的去试了**」。
      // 判据：连不上时 check() 返回 checked=false + 一句人话，而不是被
      // 「开发模式」提前掐断（那样调用方会以为在开发模式下手动也没用）。
      AppUpdateController.debugSetApiBaseForTest('http://127.0.0.1:9');
      addTearDown(() => AppUpdateController.debugSetApiBaseForTest(null));

      final res = await c.check(manual: true);
      expect(res.checked, isFalse);
      expect(res.message, isNotNull,
          reason: '手动检查失败也要给一句人话，不能静默');
    });
  });

  group('CR-1015B · 接线：判据必须真的挡在启动路径上', () {
    test('★ 启动挂钩在**任何网络动作之前**就按开发模式退出', () {
      final src = File('lib/ui/app_update_bootstrap.dart').readAsStringSync();

      final int iDev = src.indexOf('isDevMode');
      final int iDelay = src.indexOf('Future<void>.delayed');
      final int iCheck = src.indexOf('c.check(');

      expect(iDev, greaterThan(-1),
          reason: '★ 启动挂钩里找不到 isDevMode ⇒ 开发模式根本没被挡');
      expect(iDelay, greaterThan(-1), reason: '找不到那段 3 秒延迟（锚点漂了）');
      expect(iCheck, greaterThan(-1), reason: '找不到 c.check()（锚点漂了）');
      expect(iDev, lessThan(iDelay),
          reason: '★ 开发模式判据必须排在 3 秒延迟**之前** —— 否则还是要等、还是要建连接');
      expect(iDev, lessThan(iCheck),
          reason: '★ 开发模式判据必须排在 c.check() **之前** —— 否则网络请求照发');
    });

    test('★ 判据只有一份：isDevMode 读的是 DATA_DIR_OVERRIDE', () {
      final src =
          File('lib/core/app_update/app_update_controller.dart').readAsStringSync();

      expect(src.contains("String.fromEnvironment('DATA_DIR_OVERRIDE')"), isTrue,
          reason: '★ 判据必须是那个编译期常量 —— 换别的信号（如 kDebugMode）在''-Dev 与探针构建里都不成立');
      // 与 shell.dart 的 _resolveDataDir 同一判据（那里是 override.isNotEmpty）
      expect(src.contains("String.fromEnvironment('DATA_DIR_OVERRIDE') != ''"), isTrue,
          reason: '必须与 shell.dart 的「override.isNotEmpty」逐字一致，否则两处判据会漂');
    });
  });
}
