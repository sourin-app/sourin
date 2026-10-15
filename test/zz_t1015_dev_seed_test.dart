// ═══════════════════════════════════════════════════════════════════════
//  T1015 · 开发数据目录播种：把真实内容带进 -Dev，且**只读**真实目录
// ═══════════════════════════════════════════════════════════════════════
//
// Owner 2026-10-15：「你打开的时候没有之前的 js 插件和数据」。
// ⇒ 加了 `tools/seed_dev_data.ps1`，由 `run_client.ps1 -Dev` 在起 flutter
//   run 之前调一次。本文件守它的**三条契约**：
//
// ```text
// ① ★ 只读真实目录：跑完源目录必须**一个字节都没变**（用户数据铁律）
// ② 目标护栏：-Target 指到源目录（或与之互相包含）必须**硬失败**
// ③ 白名单 + 幂等 + 云同步自动开关强制关掉
// ```
//
// # 为什么①要按**哈希**逐文件核对，而不是「看代码里没有写操作」
// ```text
// 「源码里没有写」是**读代码**得出的结论，而用户数据铁律要的是**实测**。
// 两者差得很远：Copy-Item 的目标参数写错一个变量、-Force 作用在错的路径上，
// 源码看着照样「没写源目录」。⇒ 这里真的跑一遍，逐文件比 sha256。
// ```

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

const String kScript = 'tools/seed_dev_data.ps1';
const String kRunner = 'tools/run_client.ps1';

/// PowerShell 可执行文件（与 zz_cr_nit_run_client_core_test.dart 同一套探测）
String? resolvePowerShell() {
  for (final exe in <String>['pwsh', 'powershell']) {
    try {
      final r = Process.runSync(exe, <String>['-NoProfile', '-Command', 'exit 0']);
      if (r.exitCode == 0) return exe;
    } on ProcessException {
      // PATH 上没有，试下一个
    }
  }
  const String winAbs =
      'C:/Windows/System32/WindowsPowerShell/v1.0/powershell.exe';
  if (File(winAbs).existsSync()) return winAbs;
  return null;
}

String sha256Of(File f) => sha256.convert(f.readAsBytesSync()).toString();

/// 源目录的「全文件 → 哈希」快照（跳过 logs/ 与 backup-* —— 脚本本就不碰它们）
Map<String, String> snapshot(Directory root) {
  final m = <String, String>{};
  for (final e in root.listSync(recursive: true, followLinks: false)) {
    if (e is! File) continue;
    final rel = e.path.substring(root.path.length + 1).replaceAll('\\', '/');
    if (rel.startsWith('logs/') || rel.startsWith('backup-')) continue;
    m[rel] = sha256Of(e);
  }
  return m;
}

/// 搭一棵假「真实数据目录」
Directory buildFakeSource() {
  final d = Directory.systemTemp.createTempSync('t1015_src_');
  Directory(d.path + '/plugins/.data').createSync(recursive: true);
  Directory(d.path + '/logs').createSync(recursive: true);
  Directory(d.path + '/backup-20260101-000000').createSync(recursive: true);
  Directory(d.path + '/mpv-cache').createSync(recursive: true);

  // （ui-prefs 夹具见下 —— 要与「观看痕迹」区分开）
  File(d.path + '/provider-order.json').writeAsStringSync('["a","b"]');
  File(d.path + '/dsh-media.db')
      .writeAsBytesSync(List<int>.generate(512, (i) => i % 251));
  File(d.path + '/device-id').writeAsStringSync('REAL-DEVICE-ID');
  // ★ 以下三样是**故意摆出来的诱饵**：它们是仓库安全规矩点名不许拷的，
  //   夹具里必须有，否则「没拷过去」这条断言是空的（测不出东西）。
  File(d.path + '/sync-settings.json').writeAsStringSync(
      '{"baseUrl":"https://dav.example.com/dav/","username":"u",'
      '"autoEnabled":true,"autoOnChange":true,"retainCount":10}');
  File(d.path + '/remote-pref.json')
      .writeAsStringSync('{"auto_start":true,"port":8642}');

  File(d.path + '/plugins/mine.js').writeAsStringSync('// user plugin');
  File(d.path + '/plugins/.data/mine.json')
      .writeAsStringSync('{"token":"REAL-SECRET-TOKEN"}');

  // ui-prefs 夹具：界面偏好（该带走）+ 观看痕迹/绑定（不该带走）各占一半
  File(d.path + '/ui-prefs.json').writeAsStringSync(jsonEncode(<String, String>{
        'dsh.theme': 'dark',
        'dsh.danmaku.enabled': '1',
        'dsh.bili.bind.someprovider:42': '{"b":"BV1xx"}',
        'dsh.speedtest.someprovider': '{"items":[]}',
        'dsh.srcpref.someprovider:id': 'x',
        'dsh.homeSource': 'someprovider',
      }));
  File(d.path + '/logs/old.log').writeAsStringSync('SHOULD NOT BE COPIED');
  File(d.path + '/backup-20260101-000000/x.json').writeAsStringSync('{}');
  File(d.path + '/mpv-cache/tmp.bin').writeAsBytesSync(List<int>.filled(64, 7));
  return d;
}

void main() {
  final String? ps = resolvePowerShell();

  late Directory src;
  late Directory dst;

  setUp(() {
    src = buildFakeSource();
    dst = Directory.systemTemp.createTempSync('t1015_dst_');
  });

  tearDown(() {
    for (final d in <Directory>[src, dst]) {
      try {
        d.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  ProcessResult runSeed(List<String> extra) {
    return Process.runSync(ps!, <String>[
      '-NoProfile',
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      kScript,
      '-Source',
      src.path,
      '-Target',
      dst.path,
      ...extra,
    ]);
  }

  /// 前提不成立就 skip（macOS 上可能真没有 PowerShell）
  bool requirePs() {
    if (ps == null) {
      markTestSkipped('本机没有 PowerShell ⇒ 跑不了 ' + kScript);
      return false;
    }
    if (!File(kScript).existsSync()) {
      markTestSkipped('找不到 ' + kScript);
      return false;
    }
    return true;
  }

  group('T1015 · 开发数据目录播种', () {
    test('★ 跑完源目录一个字节都没变（用户数据铁律，逐文件哈希）', () {
      if (!requirePs()) return;
      final before = snapshot(src);
      expect(before, isNotEmpty, reason: '前提：夹具得有文件可比');

      final r = runSeed(<String>[]);
      expect(r.exitCode, 0, reason: '播种失败：' + r.stdout.toString() + r.stderr.toString());

      final after = snapshot(src);
      expect(after, equals(before),
          reason: '★ 源目录被改了！播种脚本必须**只读**真实数据目录 —— 这是用户数据的铁律');
    });

    test('★ -Force 也不许碰源目录（覆盖只作用在目标上）', () {
      if (!requirePs()) return;
      final before = snapshot(src);

      expect(runSeed(<String>[]).exitCode, 0);
      expect(runSeed(<String>['-Force']).exitCode, 0);

      expect(snapshot(src), equals(before),
          reason: '★ -Force 的语义是「覆盖**目标**里的同名文件」，不是「改写源」');
    });

    test('内容真的播进来了：插件源码与偏好都在', () {
      if (!requirePs()) return;
      expect(runSeed(<String>[]).exitCode, 0);

      expect(File(dst.path + '/plugins/mine.js').existsSync(), isTrue,
          reason: '用户自己装的插件必须带进来 —— 这正是 Owner 报的「没有之前的 js 插件」');
      expect(File(dst.path + '/plugins/.data/mine.json').existsSync(), isFalse,
          reason: '★ 插件私有存储**必须不带** —— 它含真实凭据（夹具里就放了 token）');
      expect(File(dst.path + '/ui-prefs.json').existsSync(), isTrue);
      expect(File(dst.path + '/dsh-media.db').existsSync(), isTrue);

      final prefs = File(dst.path + '/ui-prefs.json').readAsStringSync();
      expect(prefs.contains('dsh.theme'), isTrue, reason: '偏好得是**内容**，不是空文件');
    });

    test('不该带的没带：日志 / 备份 / 缓存 / device-id', () {
      if (!requirePs()) return;
      expect(runSeed(<String>[]).exitCode, 0);

      expect(File(dst.path + '/logs/old.log').existsSync(), isFalse,
          reason: '旧日志对开发没有意义，别带（真实目录里 20+ MB）');
      expect(Directory(dst.path + '/backup-20260101-000000').existsSync(), isFalse);
      expect(Directory(dst.path + '/mpv-cache').existsSync(), isFalse);
      expect(File(dst.path + '/device-id').existsSync(), isFalse,
          reason: '★ 开发实例要有**自己的**设备身份，不能冒用用户的');
    });

    test('★★ 仓库安全规矩点名的那三样：一个都不许进开发目录', () {
      if (!requirePs()) return;
      expect(runSeed(<String>[]).exitCode, 0);

      // 夹具里三样诱饵都摆好了（sync-settings / remote-pref / plugins/.data）。
      // ★ 断言是「不存在」，不是「存在且字段被改成安全值」——
      //   后者仍然把用户的网盘账号、端口占用搬进了临时目录。
      expect(File(dst.path + '/sync-settings.json').existsSync(), isFalse,
          reason: '★ sync-settings.json 含 WebDAV 地址 + 账号，且会自动往真实网盘推数据');
      expect(File(dst.path + '/remote-pref.json').existsSync(), isFalse,
          reason: '★ remote-pref.json 的 auto_start=true 会让开发实例占住 8642 端口');
      expect(Directory(dst.path + '/plugins/.data').existsSync(), isFalse,
          reason: '★ plugins/.data/ 是插件私有存储，含真实凭据');
    });

    test('★★ ui-prefs 按 key 过滤：界面偏好带走，观看痕迹/绑定不带', () {
      if (!requirePs()) return;
      expect(runSeed(<String>[]).exitCode, 0);

      final f = File(dst.path + '/ui-prefs.json');
      expect(f.existsSync(), isTrue, reason: '界面偏好要带 —— 否则每次开发都是默认主题');

      final bytes = f.readAsBytesSync();
      expect(bytes.sublist(0, 3), isNot(equals(<int>[0xEF, 0xBB, 0xBF])),
          reason: '★ 不能带 BOM：Dart 的 jsonDecode 见到 U+FEFF 直接抛，这份文件是给 App 读的');

      final j = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      expect(j.containsKey('dsh.theme'), isTrue, reason: '整键匹配：dsh.theme 没有结尾点');
      expect(j.containsKey('dsh.danmaku.enabled'), isTrue, reason: '前缀匹配');

      expect(j.containsKey('dsh.bili.bind.someprovider:42'), isFalse,
          reason: '★ 分P绑定是用户观看痕迹，不该进开发目录');
      expect(j.containsKey('dsh.speedtest.someprovider'), isFalse,
          reason: '★ 按源分组的测速历史同理');
      expect(j.containsKey('dsh.srcpref.someprovider:id'), isFalse,
          reason: '★ 源级偏好的键里带源标识');
      expect(j.containsKey('dsh.homeSource'), isFalse,
          reason: '★ 首页当前选中的源标识');
    });

    test('幂等：再跑一次不动已存在的文件（开发期自己的数据不被冲掉）', () {
      if (!requirePs()) return;
      expect(runSeed(<String>[]).exitCode, 0);

      final mine = File(dst.path + '/ui-prefs.json');
      mine.writeAsStringSync('{"dsh.theme":"LIGHT-EDITED-BY-DEV"}');

      expect(runSeed(<String>[]).exitCode, 0);
      expect(mine.readAsStringSync().contains('LIGHT-EDITED-BY-DEV'), isTrue,
          reason: '★ 默认不覆盖：开发期自己改的偏好必须留住，否则每次启动都被打回');

      expect(runSeed(<String>['-Force']).exitCode, 0);
      expect(mine.readAsStringSync().contains('LIGHT-EDITED-BY-DEV'), isFalse,
          reason: '-Force 就该真的覆盖');
    });

    test('★ 护栏：-Target 指到源目录本身 ⇒ 硬失败，且源目录仍然没变', () {
      if (!requirePs()) return;
      final before = snapshot(src);

      final r = Process.runSync(ps!, <String>[
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', kScript,
        '-Source', src.path, '-Target', src.path, '-Force',
      ]);

      expect(r.exitCode, isNot(0),
          reason: '★ 目标=源必须硬失败 —— 否则 -Force 会拿文件盖自己，而且下面那步会改写用户真实的 sync-settings.json');
      expect(snapshot(src), equals(before), reason: '拒绝执行后源目录必须原封不动');
      expect(r.stdout.toString().contains('拒绝执行'), isTrue,
          reason: '失败要给出人话，不能静默退出');
    });

    test('源目录不存在时安静跳过（首次运行 / 别人机器上没装过）', () {
      if (!requirePs()) return;
      final gone = Directory.systemTemp.createTempSync('t1015_none_');
      final gonePath = gone.path;
      gone.deleteSync(recursive: true);

      final r = Process.runSync(ps!, <String>[
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', kScript,
        '-Source', gonePath, '-Target', dst.path,
      ]);

      expect(r.exitCode, 0, reason: '没装过 App 的机器不该因此起不来开发模式');
    });
  });

  group('T1015 · ★ 两个 .ps1 的编码底线（BOM + CRLF）', () {
    test('★ run_client.ps1 与 seed_dev_data.ps1 都必须是 UTF-8 **带 BOM**', () {
      // ★★ 这条是**我自己踩出来的**：编辑这两个文件时只要经过一次
      //   「读成字符串再写回」，BOM 就会掉 —— 而 Windows PowerShell 5.1
      //   对**没有 BOM** 的 UTF-8 文件按 ANSI 解码 ⇒ 文件里的中文全成乱码
      //   ⇒ ParserError「意外的标记」⇒ **脚本一行都跑不起来**。
      //
      //   而它有一条极强的误导性：脚本源码看上去完全正常（编辑器按 UTF-8 显示），
      //   只有**真的执行**才会炸。
      //
      //   run_client.ps1 这条底线已有 zz_cr_nit_run_client_core_test.dart 守着；
      //   本文件补的是 seed_dev_data.ps1 —— 它是新增的，此前没有任何门禁。
      for (final String p in <String>[kRunner, kScript]) {
        final bytes = File(p).readAsBytesSync();
        expect(bytes.length, greaterThan(3), reason: p + ' 读不到内容');
        expect(bytes.sublist(0, 3), equals(<int>[0xEF, 0xBB, 0xBF]),
            reason: '★ ' + p + ' 少了 UTF-8 BOM ⇒ PowerShell 5.1 按 ANSI 解码 ⇒ '
                '中文变乱码、ParserError、脚本完全跑不起来（编辑器里看不出来）');
      }
    });

    test('★ 两个 .ps1 都不含裸 LF（统一 CRLF）', () {
      // 混合行尾本身不至于跑不起来，但会让「按行 grep 定位」与
      // git diff 的观感失真 —— 本仓对脚本一律 CRLF（见 .gitattributes）。
      for (final String p in <String>[kRunner, kScript]) {
        final bytes = File(p).readAsBytesSync();
        int crlf = 0;
        for (int i = 0; i + 1 < bytes.length; i++) {
          if (bytes[i] == 0x0D && bytes[i + 1] == 0x0A) crlf++;
        }
        int lf = 0;
        for (final int b in bytes) {
          if (b == 0x0A) lf++;
        }
        expect(lf - crlf, 0, reason: '★ ' + p + ' 里有 ' + (lf - crlf).toString() + ' 个裸 LF');
      }
    });

    test('★ 脚本真的能被 PowerShell **解析**（不只是「文件存在」）', () {
      if (!requirePs()) return;
      // 编码对不对、括号配不配平 —— 只有真解析一遍才知道。
      // 上面那条 BOM 断言查的是**原因**，这条查的是**结果**。
      for (final String p in <String>[kRunner, kScript]) {
        final r = Process.runSync(ps!, <String>[
          '-NoProfile',
          '-Command',
          r'$e=$null; $t=$null; '
              r'$null=[System.Management.Automation.Language.Parser]::ParseFile(' +
              r'(Resolve-Path "' +
              p +
              r'").Path,[ref]$t,[ref]$e); ' +
              r'if ($e.Count -eq 0) { exit 0 } else { Write-Host $e[0].Message; exit 1 }',
        ]);
        expect(r.exitCode, 0,
            reason: '★ ' + p + ' 解析失败 ⇒ 脚本跑不起来：' + r.stdout.toString() + r.stderr.toString());
      }
    });
  });

  group('T1015 · 接线：-Dev 必须真的调它', () {
    test('★ run_client.ps1 的 -Dev 分支里调了 seed_dev_data.ps1，且在 flutter run 之前', () {
      final src2 = File(kRunner).readAsStringSync();
      expect(src2.contains('seed_dev_data.ps1'), isTrue,
          reason: '★ 脚本存在但没人调 ⇒ -Dev 起来还是空目录（Owner 报的就是这个）');

      final int iDev = src2.indexOf(r'if ($Dev) {');
      final int iSeed = src2.indexOf('seed_dev_data.ps1');
      final int iRun = src2.indexOf('flutter run -t lib/shell.dart');
      expect(iDev, greaterThan(-1));
      expect(iSeed, greaterThan(iDev), reason: '必须在 -Dev 分支**里面**');
      expect(iSeed, lessThan(iRun),
          reason: '★ 必须在 flutter run **之前**播种 —— 否则 App 先起来，读到的还是空目录');
    });

    test('★ 播种失败要挡住启动（不是警告一下继续跑空目录）', () {
      final src2 = File(kRunner).readAsStringSync();
      final int iSeed = src2.indexOf('seed_dev_data.ps1');
      final int iThrow = src2.indexOf('seed_dev_data.ps1 失败', iSeed);
      expect(iThrow, greaterThan(iSeed),
          reason: '★ 失败必须 throw（本仓 -Dev 的其它步骤也是这个风格）');
    });
  });
}
