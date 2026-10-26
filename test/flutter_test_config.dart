// ══════════════════════════════════════════════════════════════════════
//  全局测试配置 —— **所有** `flutter test` 用例共同的隔离层
// ══════════════════════════════════════════════════════════════════════
//
// # 这个文件在解决什么（2026-10-26 实测）
// ```text
// 跑 Dart 测试会往**真实数据目录**写日志：
//   %APPDATA%\app.sourin.player\logs\sourin-2026-10-26.log
// 当天那份里混进了 3060 行 `[DL] 探针日志` 和单测假地址
// （`127.0.0.1:1/never-played.mp4`）。
// ⇒ 用户在自己的日志里看到根本不存在的播放/下载；而"日志里有什么"
//   本来是我们唯一能拿来做取证的东西 —— 一试跑就被污染。
// ```
//
// # 为什么放在这里（而不是每个测试文件自己设）
// ```text
// `flutter_test_config.dart` 是 flutter_test 的**全局入口**：同目录下所有
// 用例运行前都会先执行它。放在这里 ⇒ 一条规则覆盖全部现有/将来用例，
// 不会出现"新写的测试忘了设隔离"。
// ```
//
// # 为什么用注入口而不是改产品逻辑
// ```text
// `AppLog.logDir()` 的优先级是：
//   ① 测试注入口 `AppLog.debugLogDirOverride`   ← 本文件设它
//   ② 环境变量 `SOURIN_LOG_DIR`（与 Rust 侧 SOURIN_LOG_FILE 同一思路）
//   ③ `<dataDir>/logs`（生产默认）
// 产品代码不知道"测试"这回事；③ 在生产里逐字未变。
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:sourin_spike/core/app_log.dart';

/*
 * ★ 2026-10-26 修（本文件的第二个坑）：`FutureOr` 在 `dart:async` 里，
 *   但只 `import` 不导出到本文件的**顶层类型作用域**时，某些编译路径会报
 *   `Type 'FutureOr' not found`（实测：全量跑到 `t70_bili_danmaku_test.dart`
 *   ⇒ `Failed to load … test/flutter_test_config.dart:41:29`，把该文件与之后
 *   一批用例**全部**变成 "Compilation failed"）。
 *   显式 `show FutureOr` 把它带进作用域，避免依赖 import 的间接可见性。
 */
import 'dart:async' show FutureOr;

/// `flutter_test` 的全局钩子：返回一个包装过的 `testMain`
///
/// 这里直接把日志目录钉到系统临时目录下的 `sourin-test-logs/`，
/// 再调用各测试文件自己的 `main`。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  final dir = Directory(
    '${Directory.systemTemp.absolute.path}${Platform.pathSeparator}'
    'sourin-test-logs',
  );
  if (!dir.existsSync()) dir.createSync(recursive: true);
  // ★ 必须在任何用例**第一次**写日志之前设好（本钩子就是最早的位置）
  AppLog.debugLogDirOverride = dir.path;

  // 单条用例结束后清空内存缓冲：避免上一条的行被带到下一条（跨用例污染）
  tearDownAll(AppLog.debugClear);

  await testMain();
}
