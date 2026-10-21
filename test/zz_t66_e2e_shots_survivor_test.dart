// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮：`tools/e2e_shots.ps1` 收尾「存活进程数」可判性门禁
// ═══════════════════════════════════════════════════════════════════════
//
//  # 守什么
//  ```text
//  改前（双重失效）：
//    :193  Stop-OurProcesses 末尾  $script:StartedPids = @()
//    :626  $left = @($script:StartedPids | …)     ← 读的是**已清空**的集合
//    :627  非 0 时只 Warn，随后仍走 :794 的 exit 0
//  ⇒ 既看不见幸存者，也拦不住 —— 一条恒真的检查。
//  ```
//
//  # ★ 本文件怎么验「不真起客户端」
//  ```text
//  脚本的收尾逻辑只有两个可测单元：
//    ① Stop-OurProcesses 会不会**先留档再清空**
//    ② 收尾的存活复查会不会**Fail（exit 非 0）**
//  ⇒ 本文件把脚本按文本抽出这两段，在 pwsh 里用**真实的、可控的**
//     长驻进程（pwsh 自己 sleep）驱动它 —— 不起客户端、不占端口、
//     不碰数据目录，且跑完必清理。
//  ```
//
//  # 判据纪律
//  ```text
//  · 读**脚本源码形态**（Stop-OurProcesses 的留档必须早于清空）
//  · 读**真实进程读数**（用一个必然活着的进程做幸存者）
//  · 每条都打印实测值，便于报告逐字引用
//  ```
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _scriptPath = 'tools/e2e_shots.ps1';

String _script() {
  final f = File(_scriptPath);
  expect(f.existsSync(), isTrue, reason: '★ 前置：$_scriptPath 必须存在');

  // ★★★ 必须先把行尾统一成 LF 再解析 —— 下面的 `indexOf('\n}\n')` 是**写死 LF 的**。
  //
  //   `.gitattributes` 里写着 `*.ps1 text eol=crlf` ⇒ **全新 checkout 出来的
  //   工作副本是 CRLF**（本机那份一度是历史遗留的 LF：
  //   `git ls-files --eol` 曾显示 `i/lf w/lf attr/text eol=crlf`）。
  //
  //   ⇒ 于是「本机绿、CI 红」：实测（CI run 39538011233，macOS）
  //       Expected: a value greater than <13947>
  //         Actual: <-1>
  //     即 `indexOf('\n}\n', start)` 一行都没命中，然后报「函数体未正常闭合」。
  //
  //   ⚠️ 这不是 macOS 专有问题：Windows 的全新 checkout 同样是 CRLF。
  //      本机之所以一直绿，只是那份文件还没被 git 重写过。
  //      ⇒ 判据：**读文本文件的解析器不能假设行尾**，除非当场归一。
  //      已用故障注入验证：把本行改回 `return f.readAsStringSync();`
  //      （脚本置 CRLF）⇒ 逐字复现上面那三行 CI 报错 ⇒ 这行是承重的。
  return f.readAsStringSync().replaceAll('\r\n', '\n');
}

/// 脚本里 `Stop-OurProcesses` 函数的原文（**已剔除注释行**）
///
/// ★ 为什么必须剔注释：本脚本在修复处写了长注释，里面**逐字提到**
///   `$script:StartedPids = @()` 与 `PidListForManifest`。
///   不剔注释时，第一版门禁匹配到的是**注释里的那份**，
///   实测偏移 1042（注释）vs 300（真代码）⇒ 判据抓错了对象（假红）。
///   剔除注释后判的才是**真正执行的语句顺序**。
String _stopFnCodeLines(String src) {
  final start = src.indexOf('function Stop-OurProcesses {');
  expect(start, greaterThanOrEqualTo(0),
      reason: '★ 前置：脚本里找不到 Stop-OurProcesses 定义');
  final end = src.indexOf('\n}\n', start);
  expect(end, greaterThan(start), reason: '函数体未正常闭合');
  return src
      .substring(start, end + 3)
      .split('\n')
      .where((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'))
      .join('\n');
}

/// 找一个能跑 PowerShell 的可执行（`pwsh` 不一定在 Dart 测试进程的 PATH 上）
///
/// ★ 实测踩坑：直接 `Process.start('pwsh', …)` 抛
///   `ProcessException: 系统找不到指定的文件`
///   （flutter test 的环境里 pwsh 不在 PATH）⇒ 门禁自己先红。
String _psExe() {
  for (final cand in [
    r'C:\Program Files\PowerShell\7\pwsh.exe',
    r'C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe',
  ]) {
    if (File(cand).existsSync()) return cand;
  }
  return 'powershell.exe'; // 退回 PATH
}

void main() {
  group('① Stop-OurProcesses：留档必须早于清空', () {
    test('留档（PidListForManifest）在 StartedPids 清空之前', () {
      // ★ 只看**真正执行的代码行**（剔注释）—— 见 _stopFnCodeLines 的说明
      final body = _stopFnCodeLines(_script());
      final archive = body.indexOf(r'$script:PidListForManifest = @($script:StartedPids)');
      final clear = body.indexOf(r'$script:StartedPids = @()');

      expect(archive, greaterThanOrEqualTo(0),
          reason: '★★ Stop-OurProcesses 里必须留档 PidListForManifest；'
              '没有留档 ⇒ 收尾读已清空的集合 ⇒ 存活检查恒为 0。');
      expect(clear, greaterThanOrEqualTo(0), reason: '前置：应仍有清空那行');
      expect(
        archive,
        lessThan(clear),
        reason: '★★ 留档必须在清空**之前**。实测：'
            '留档在偏移 $archive，清空在偏移 $clear。'
            '顺序反了 ⇒ 留档到的是空集合，等于没留。',
      );
      // ignore: avoid_print
      print('SURV|① 留档偏移=$archive < 清空偏移=$clear  ⇒ 顺序正确（已剔注释）');
    });

    test('收尾存活复查读的是 PidListForManifest，不是 StartedPids', () {
      final src = _script();
      // 收尾那段：以 **真正打印的那行** 为锚
      // ★ 不能锚在裸 "SURVIVORS=" 上：修复处的注释里也写了 `SURVIVORS=<n>`，
      //   `indexOf('SURVIVORS=')` 会先命中**注释**（实测 :656），
      //   往前往后都找错对象。必须锚在 Write-Host 那一行。
      final anchor = src.indexOf(r'Write-Host ("SURVIVORS=');
      expect(anchor, greaterThanOrEqualTo(0),
          reason: r'★ 前置：脚本必须打印机器可读的 SURVIVORS=<n>'
              r'（锚点取 Write-Host 那一行，避免命中注释）');

      // 取 $left 那一行（它就在 SURVIVORS= 上面几行）
      final leftLineIdx = src.lastIndexOf(r'$left = @($script:PidListForManifest', anchor);
      expect(leftLineIdx, greaterThanOrEqualTo(0),
          reason: r'★ 前置：SURVIVORS 附近必须能看到 $left 的定义行。');

      // 只看那一行（剔注释），判它读的是哪一份
      final leftLine = src
          .substring(leftLineIdx, src.indexOf('\n', leftLineIdx))
          .trimLeft();
      expect(
        leftLine.startsWith('#') ? false : true,
        isTrue,
        reason: r'★ $left 定义行不应是注释',
      );
      expect(
        leftLine,
        contains(r'$script:PidListForManifest'),
        reason: '★★ 存活复查必须读留档的 PidListForManifest。'
            r'读 $script:StartedPids 会恒为 0（它刚被清空）。'
            '实测该行：$leftLine',
      );
      expect(
        leftLine,
        isNot(contains(r'$script:StartedPids')),
        reason: r'★★ 存活复查不得再读已清空的 $script:StartedPids。'
            '实测该行：$leftLine',
      );
      // ignore: avoid_print
      print('SURV|① 存活复查行 = $leftLine  ⇒ 读留档，不是已清空的 StartedPids');
    });

    test('★ 阴性对照：StartedPids 的留档变量已在声明处初始化', () {
      // 若没初始化，启动前失败时收尾会读 $null ⇒ $null | Where-Object …
      // 在 PowerShell 里不会报错但会给空 ⇒ 恒 0（又一条假绿）。
      final src = _script();
      expect(
        src.contains(r'$script:PidListForManifest = @()'),
        isTrue,
        reason: '★★ PidListForManifest 必须在声明处初始化为 @()，'
            r'否则「启动前就失败」的路径读到 $null，存活检查又退回恒 0。',
      );
      // ignore: avoid_print
      print('SURV|① PidListForManifest 已在声明处初始化');
    });
  });

  group('② SURVIVORS 输出与非 0 退出', () {
    test('打印机器可读的 SURVIVORS=<n>，且非 0 时走 Fail', () {
      final src = _script();
      expect(src.contains('SURVIVORS='), isTrue,
          reason: '必须打印 SURVIVORS=<n>（机器可 grep + 人能一眼看出）');

      final anchor = src.indexOf('SURVIVORS=');
      final tail = src
          .substring(anchor, anchor + 1200)
          .split('\n')
          .where((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#'))
          .join('\n');
      // 打印之后紧跟的分支必须是 Fail（exit 非 0），不能是 Warn
      final branch = tail.indexOf(r'if ($left.Count -gt 0)');
      expect(branch, greaterThanOrEqualTo(0),
          reason: r'★ 前置：SURVIVORS 之后应对 $left.Count 判分支');
      final afterBranch = tail.substring(branch, branch + 700);
      expect(
        afterBranch,
        contains('Fail ('),
        reason: '★★ SURVIVORS 非 0 必须 **Fail**（⇒ exit 非 0），'
            '不能只 Warn —— 只 Warn 会一路走到末尾的 exit 0。',
      );
      expect(
        afterBranch,
        isNot(contains('Warn ("still alive after kill')),
        reason: '★★ 旧的「只 Warn」分支必须删干净，否则它会先于 Fail 生效。',
      );
      // ignore: avoid_print
      print('SURV|② SURVIVORS 非 0 ⇒ Fail（exit 非 0）');
    });
  });

  // ★★★ ③ 必须在 Windows 上跑：它要起一个**真进程**（`pwsh ... Start-Sleep`）
  //   再用 `taskkill` 收尾 —— 两者都是 Windows 专属。
  //
  //   实测（CI run 39526450290，macOS job）：
  //     ProcessException: No such file or directory
  //   原因：`_psExe()` 在非 Windows 上回落到字面量 `'powershell.exe'`，
  //   而 macOS 没有这个可执行文件；`taskkill` 同理。
  //
  //   ⚠️ 为什么是「显式跳过」而不是「放宽判据」：
  //     放宽（比如"找不到 pwsh 就把 survivor 当 0 也算过"）会让这条门禁
  //     在任何平台恒绿地空转 —— 那正是「假绿门禁」。
  //     ①② 是纯静态读 `tools/e2e_shots.ps1` 原文 ⇒ **不跳过**，macOS 上照跑。
  group('③ ★ 真跑一段收尾逻辑（用真实可控进程，不起客户端）',
      skip: Platform.isWindows
          ? false
          : '本组要起真进程 + taskkill（Windows 专属）⇒ 非 Windows 上显式跳过，'
              '避免把"没法测"伪装成"通过"', () {
    late int shimPid;

    setUpAll(() async {
      // 起一个**必然活着**的进程充当"幸存者"：pwsh 自己 sleep。
      // ★ 绝不用客户端（那会占端口/留孤儿）；跑完必杀。
      final p = await Process.start(
        _psExe(),
        ['-NoProfile', '-Command', 'Start-Sleep -Seconds 120'],
      );
      shimPid = p.pid;
    });

    tearDownAll(() {
      // 只杀**我们自己起的那个 PID**（铁律：绝不按进程名批量杀）
      try {
        Process.runSync('taskkill', ['/PID', '$shimPid', '/F', '/T']);
      } catch (_) {
        // 忽略：它可能已经自己退出了
      }
    });

    test('收尾逻辑：把 shim 当成"该杀但没死"的 pid ⇒ 必须算成 survivor', () {
      // 抽出脚本里那一段真实的收尾表达式，原样喂进 pwsh 跑。
      // 判据 = **真实进程读数**，不是字符串匹配。
      final expr = r'''
$ids = @(%PID%)
$left = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
Write-Host ("SURVIVORS=" + $left.Count)
if ($left.Count -gt 0) { Write-Host "WOULD-FAIL"; exit 3 } else { Write-Host "WOULD-PASS"; exit 0 }
'''.replaceAll('%PID%', '$shimPid');

      final r = Process.runSync(_psExe(), ['-NoProfile', '-Command', expr]);
      final out = '${r.stdout}';
      // ignore: avoid_print
      print('SURV|③ 真实收尾逻辑读数: ${out.trim()}');
      // ignore: avoid_print
      print('SURV|③ exitCode=${r.exitCode}');

      expect(out, contains('SURVIVORS=1'),
          reason: '★ 一个真实存活进程必须被算成 1 个 survivor；'
              '读到 0 就说明这段表达式仍然是恒 0 的假检查。');
      expect(out, contains('WOULD-FAIL'),
          reason: '★ 有幸存者 ⇒ 必须走 Fail 分支（exit 非 0）');
      expect(r.exitCode, isNot(0),
          reason: '★★ 有幸存者时退出码必须非 0（实测 ${r.exitCode}）');
    });

    test('收尾逻辑：不存在的 pid ⇒ SURVIVORS=0 且 exit 0（反向对照）', () {
      // 用一个必然不存在的 PID（极大值），证明计数不是恒 1。
      final expr = r'''
$ids = @(%PID%)
$left = @($ids | Where-Object { Get-Process -Id $_ -ErrorAction SilentlyContinue })
Write-Host ("SURVIVORS=" + $left.Count)
if ($left.Count -gt 0) { Write-Host "WOULD-FAIL"; exit 3 } else { Write-Host "WOULD-PASS"; exit 0 }
'''.replaceAll('%PID%', '4294967');

      final r = Process.runSync(_psExe(), ['-NoProfile', '-Command', expr]);
      final out = '${r.stdout}';
      // ignore: avoid_print
      print('SURV|③ 反向对照读数: ${out.trim()}');

      expect(out, contains('SURVIVORS=0'),
          reason: '★ 不存在的 pid 必须算 0；否则上一条就是恒 1。');
      expect(r.exitCode, 0, reason: '没有幸存者 ⇒ 允许 exit 0');
    });
  });
}