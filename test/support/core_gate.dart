// ═══════════════════════════════════════════════════════════════════════
//  门禁公共件：**缺 dll 与缺件不是一回事**（审计 B9 的统一处置）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么 Windows 上缺 `sourin_core.dll` 必须 fail，而不是 skip
//
// ```text
// sourin_core.dll 是**本仓的提交物**：
//   仓库根 / windows/ / build/windows/x64/runner/Debug / …/Release
// 四份必须存在且 SHA256 一致（那条判据在 test/zz_t1040_csp_route_test.dart ⑦）。
//
// 它缺了，说明的是「有人没同步产物」或「检出被弄脏了」——
// 那是**仓库状态坏了**，不是这台机器缺能力。
//
// 一旦把这种情形写成 markTestSkipped：
//   CI 的结论从「红」变成「绿（有 N 项跳过）」⇒ 「核心没同步」可以一路混进发布。
//   这正是反假绿审计 B9 的原始缺陷：**把"门禁跑不起来"伪装成"通过"**。
// ```
//
// # 非 Windows 为什么可以 skip
//
// ```text
// 本仓只发 Windows 核心产物（Windows 是唯一支持的桌面目标）。
// 在 macOS/Linux 上跑 flutter test 时，缺 dll 是**平台事实**，不是仓库缺陷。
// 但 skip 的 reason 必须点名两件事，读者才知道空白在哪：
//   ① 缺的是哪个文件
//   ② 本次**没有校验到什么**
// ```
//
// # 收窄 catch：只认「动态库加载失败」这一类
//
// ```text
// `catch (e) { markTestSkipped(...) }` 会把
//   · 核心自己报的错（SourinCoreException）
//   · FFI 契约坏了（符号签名变了）
//   · IO 错误（数据目录不可写）
// 也变成一行 skip —— 那是**红变绿**，比不做门禁更糟。
// 判据词表与 test/zz_dialog18_unified_shell_test.dart 的 `_isLibMissing`
// 逐字一致：同一件事在本仓只该有一个判据。
// ```
//
// 用法（三条分支各一句，别在每个文件里重写一遍）：
// ```dart
// if (!requireCoreFiles(<String>['sourin_core.dll'], notVerified: '库往返')) return;
// ...
// } catch (e, st) {
//   coreStartFailedThenSkip(e, st, notVerified: '库往返');   // 缺件⇒按平台处置；其它⇒fail
//   return;
// }
// ```
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 本仓核心产物应当存在的平台（Windows）
///
/// ⚠️ 用 `Platform.isWindows` 而不是 `Platform.environment` 之类的探测：
///    判据要的是"这个平台本来有没有这份产物"，不是"这台机器碰巧有没有"。
bool get coreArtifactExpectedHere => Platform.isWindows;

/// 默认的四份 dll 路径（与 zz_t1040 ⑦ 组同一张表）
const List<String> kCoreDllPaths = <String>[
  'sourin_core.dll',
  'windows/sourin_core.dll',
  'build/windows/x64/runner/Debug/sourin_core.dll',
  'build/windows/x64/runner/Release/sourin_core.dll',
];

/// 判定异常是否属于「动态库加载失败 / 符号缺失」
///
/// 只认这一类才允许走"缺件"处置；其余一律交给调用方 fail。
bool isLibMissingForGate(Object e) {
  final s = e.toString().toLowerCase();
  const marks = <String>[
    'failed to load dynamic library',
    'cannot open shared object',
    'the specified module could not be found',
    '找不到指定的模块',
    'undefined symbol',
    'error code: 126',
  ];
  return marks.any(s.contains);
}

/// 缺核心时的统一处置：Windows ⇒ `fail`；其它平台 ⇒ `markTestSkipped`
///
/// ⚠️ 返回 `void`（不是 `Never`）：`markTestSkipped` 在 flutter_test 里
///    **不改变控制流**（它只登记一条 skip，然后继续往下跑）。
///    ⇒ 调用方在这之后必须自己 `return;`，两个分支都写成同一形状：
///    ```dart
///    } catch (e, st) {
///      coreStartFailedThenSkip(e, st, notVerified: '…');
///      return;
///    }
///    ```
void handleMissingCore({
  required String missing,
  required String notVerified,
  Object? error,
}) {
  final detail = error == null ? '' : '\n原始异常：$error';
  if (coreArtifactExpectedHere) {
    fail(
      'Windows 上缺 `sourin_core.dll`（缺：$missing）：这是**仓库提交物**'
      '（根 / windows / Debug / Release 四份，SHA256 须一致），不是环境缺件 '
      '—— 因此不许 skip。「门禁跑不起来」必须是一个可见的红。\n'
      '本次没有校验到：$notVerified。$detail',
    );
  }
  markTestSkipped(
    '非 Windows 平台：缺 $missing（本仓核心产物只有 Windows 版）'
    '⇒ 本次没有校验到：$notVerified。$detail',
  );
}

/// 核心文件存在性检查：都在 ⇒ `true`（继续跑）；缺 ⇒ 按平台处置并 `false`
bool requireCoreFiles(
  List<String> paths, {
  required String notVerified,
}) {
  final missing = <String>[for (final p in paths) if (!File(p).existsSync()) p];
  if (missing.isEmpty) return true;
  handleMissingCore(missing: missing.join('、'), notVerified: notVerified);
  return false;
}

/// `SourinCore.startAsync` 抛出的异常该怎么处置
///
/// - 命中 [isLibMissingForGate]（dlopen/符号缺失）⇒ 缺件，按平台处置；
/// - 其余（核心自报错、FFI 契约坏、IO）⇒ **fail**，不许降级成 skip。
///
/// 调用方随后自己 `return;`（理由见 [handleMissingCore] 的注释）。
void coreStartFailedThenSkip(
  Object error,
  StackTrace stack, {
  required String notVerified,
  List<String> paths = kCoreDllPaths,
}) {
  if (!isLibMissingForGate(error)) {
    fail(
      '核心启动失败，但**不是**缺件（不许降级成 skip）：$error\n$stack\n'
      '本次没有校验到：$notVerified。',
    );
  }
  handleMissingCore(
    missing: paths.join('、'),
    notVerified: notVerified,
    error: error,
  );
}
