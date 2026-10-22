// 门禁：人工确认稿（docs/release-notes/<TAG>.md）本身必须合格
//
// # 为什么需要它
//
// 2026-10-22 引入「人工确认稿通道」后，本版更新有两种来源：
//
//   ① 自动归纳（tools/gen_release_notes.py 从 git log 归纳）—— 默认
//   ② 人工确认稿（docs/release-notes/<TAG>.md）—— 存在就用它
//
// ② 一旦存在，它就是**用户唯一会读到的本版说明**。而它是人写的：
//
//   · 漏写条目 ⇒ 那一版又变成「默认说明」（Owner 2026-10-19 报过的形态）
//   · 写了表格 / 图片 / HTML 标签 / 代码块 ⇒ 客户端渲染器不支持，原样漏出
//   · 写了分隔线 / HTML 注释 ⇒ 渲染器虽会跳过，但那是人工稿的输入约束：
//     稿子只该有给用户逐条读的话（注解落在笔记里），且不剥注释才能保证
//     报错行号对得上原文件
//   · 混进开发用语（门禁 / 探针 / 修复…）⇒ 用户读到的是工程黑话
//   · 混进具体站名 ⇒ 违反仓库硬约束（AGENTS §4）
//   · 残留占位符 ⇒ GitHub Release 正文里出现「{{CHANGELOG}}」
//
// ⇒ 这条门禁把「人工稿的合格性」做成**机械判定**，不靠人自觉。
//
// ★ 判据来源：不在这里重写规则，而是**调用生成器自己的校验函数**
//   （tools/gen_release_notes.py 的 validate_manual_notes）。
//   规则只写一份 ⇒ 不会出现「门禁抄了一份规则、两边各说一套」。
//
// ★ 为什么用「跑一遍生成器看退出码」而不是在 Dart 里复刻规则：
//   生成器的校验是权威口径；Dart 复刻必然漂移。
//   （CI 的 Windows/macOS job 都装了 python，见 build.yml 的 setup-python@v5。）

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 人工稿目录（相对仓库根）。
const _manualDir = 'docs/release-notes';

/// 目录里的说明文件（不是稿子，不参与校验）。
const _readmeName = 'README.md';

/// 找可用的 python（macOS 只有 python3，Windows 上可能是 python / py）。
String? findPython() {
  for (final exe in <String>['python', 'python3', 'py']) {
    try {
      if (Process.runSync(exe, <String>['-c', 'print(1)']).exitCode == 0) {
        return exe;
      }
    } on ProcessException {
      continue;
    }
  }
  return null;
}

/// 本目录下的稿子（排除 README）。
List<File> manualNoteFiles() {
  final dir = Directory(_manualDir);
  if (!dir.existsSync()) return <File>[];
  return dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.md'))
      .where((f) => !f.path.endsWith(_readmeName))
      .toList()
    ..sort((a, b) => a.path.compareTo(b.path));
}

/// 跑一次生成器，返回结果。
///
/// ★ 必须显式指定 UTF-8 解码：`Process.runSync` 默认按**系统编码**解子进程输出，
///   Windows 上是 cp1252 / GBK ⇒ 生成器打的中文会变成乱码或 `\uXXXX`，
///   于是断言「第 4 行」永远失败（本门禁在 CI 上真的这样红过一次）。
///   生成器侧也做了对应的 `_force_utf8_stdio()` —— 两边都钉住才算钉住。
ProcessResult runGenerator(String py, File file) {
  return Process.runSync(
    py,
    <String>[
      'tools/gen_release_notes.py',
      '--manual',
      file.path,
      '--out',
      '${file.parent.path}/out.md',
    ],
    workingDirectory: Directory.current.path,
    stdoutEncoding: const Utf8Codec(),
    stderrEncoding: const Utf8Codec(),
  );
}

void main() {
  final py = findPython();

  test('人工确认稿目录存在（否则这条门禁扫不到东西）', () {
    final dir = Directory(_manualDir);
    expect(dir.existsSync(), isTrue,
        reason: '$_manualDir 不存在 —— 人工确认稿通道的落点没了。'
            '「没查」不能渲染成「没问题」，所以这里必须红。');
  });

  test('CI 上必须有 python（否则整组门禁静默跳过）', () {
    // ★ 这条是给「假绿」设的。
    //   下面每条用例都在 `py == null` 时 markTestSkipped —— 本机没有 python
    //   是合理的（跳过会显示在汇总里），但 CI 上缺 python 就意味着
    //   **整组门禁自动跳过**：构建照样绿，人工稿完全没人校验。
    //   ⇒ CI 环境（GITHUB_ACTIONS / CI）下缺 python 必须判红。
    final inCi = (Platform.environment['GITHUB_ACTIONS'] ?? '').isNotEmpty ||
        (Platform.environment['CI'] ?? '').isNotEmpty;
    if (!inCi) {
      if (py == null) {
        markTestSkipped('本机没有 python（仅本地可接受；CI 上会判红）');
      }
      return;
    }
    expect(py, isNotNull,
        reason: 'CI 上没有 python ⇒ 人工稿门禁整组静默跳过 ⇒ 构建绿但没人校验稿子。'
            'build.yml 的 setup-python@v5 是不是被删了？');
  });

  test('每一份人工确认稿都能通过生成器的校验（退出码 0）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从调用生成器校验人工稿');
      return;
    }
    final files = manualNoteFiles();
    expect(files, isNotEmpty,
        reason: '$_manualDir 下一份稿都没有 —— 人工稿通道建了却没人用。');

    for (final f in files) {
      final r = Process.runSync(
        py,
        <String>[
          'tools/gen_release_notes.py',
          '--manual',
          f.path,
          '--out',
          '${Directory.systemTemp.path}/manual_notes_gate_out.md',
        ],
        workingDirectory: Directory.current.path,
        stdoutEncoding: const Utf8Codec(),
        stderrEncoding: const Utf8Codec(),
      );
      expect(r.exitCode, 0,
          reason: '人工稿 ${f.path} 没通过生成器校验（退出码 ${r.exitCode}）：\n'
              '${r.stderr.toString()}');
    }
  });

  test('人工稿目录里的文件名是版本号（防止随手丢一份文件进去）', () {
    for (final f in manualNoteFiles()) {
      final name = f.path.split(RegExp(r'[/\\]')).last.replaceAll('.md', '');
      expect(RegExp(r'^v\d+\.\d+\.\d+(-[A-Za-z0-9.]+)?$').hasMatch(name), isTrue,
          reason: '人工稿文件名 ${f.path} 不是版本号（应形如 v1.4.0-rc4.md）——'
              'CI 按 tag 找稿，名字不对就永远不会被读到。');
    }
  });

  test('不合格的人工稿会被生成器拒掉（守卫本身不是恒绿）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      // 三处违规：表格行 + 开发用语「门禁」+ 没有可用的分类小标题
      final bad = File('${tmpDir.path}/bad.md');
      bad.writeAsStringSync('### 修复\n\n'
          '| 平台 | 说明 |\n'
          '|---|---|\n'
          '- 门禁改成结构锚了\n');
      final r = runGenerator(py, bad);
      expect(r.exitCode, 1,
          reason: '带表格 + 开发用语的人工稿竟然通过了（退出码 ${r.exitCode}）'
              '⇒ 生成器的守卫恒绿 ⇒ 这条门禁没有意义。\n'
              '${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('未知的小标题会被拒（文档承诺的规则，校验必须与它一致）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      final f = File('${tmpDir.path}/bad_heading.md');
      f.writeAsStringSync('### 性能\n\n- 播放更顺畅。\n');
      final r = runGenerator(py, f);
      expect(r.exitCode, 1,
          reason: '「### 性能」这种未知小标题竟然通过了 ⇒ '
              '文档里写的「只许四个分类」与校验不一致。\n'
              '${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('HTML 注释会被拒（守人工稿输入约束，与渲染器能力无关）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      final f = File('${tmpDir.path}/bad_comment.md');
      f.writeAsStringSync('### 修复\n\n'
          '<!-- 跨两行的注释\n'
          '第二行\n'
          '-->\n\n'
          '- 某条说明。\n');
      final r = runGenerator(py, f);
      expect(r.exitCode, 1,
          reason: '含 HTML 注释的稿竟然通过了 ⇒ 注释里的占位符会逃过检查，'
              '写给维护者的注解也会混进发版稿。\n'
              '${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('条目正文里的图片与 HTML 标签也会被拒（不只行首）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      final f = File('${tmpDir.path}/bad_inline.md');
      f.writeAsStringSync('### 修复\n\n'
          '- 更新好了<i>提示</i>\n'
          '- 封面图 ![封面](https://x.app/a.png)\n');
      final r = runGenerator(py, f);
      expect(r.exitCode, 1,
          reason: '条目正文里的图片/HTML 标签竟然通过了 ⇒ '
              '这些内容会被原样漏给用户。\n'
              '${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('空条目会被拒（只有符号没有内容）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      // 关键：**同一份稿里还有一条真条目**。
      // 只写空条目的稿会被「整份稿里一条条目都没有」那条拦住 ——
      // 那条红不能证明本判据存在。这里必须让 `bullets` 非空，
      // 才能证明「空条目不靠别的判据兜」。
      final f = File('${tmpDir.path}/empty_bullet.md');
      f.writeAsStringSync('### 修复\n'
          '\n'
          '- 播放更顺畅。\n'
          '- \n');
      final r = runGenerator(py, f);
      expect(r.exitCode, 1,
          reason: '混着真条目的空条目竟然通过了 ⇒ 用户会看到一条什么都没有的项目符号。\n'
              '${r.stderr.toString()}');
      expect(r.stderr.toString(), contains('空条目'),
          reason: '拒掉了但没说清是什么问题 ⇒ 报错读不懂等于没有报错。\n'
              '${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('渲染器不认识的 Markdown 会被拒（引用块 / 删除线 / 下划线粗体）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守门会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      // 这三种都不是「非法 Markdown」，而是渲染器的 `_inline()` / 行首分支
      // 不认识 ⇒ 会原样漏给用户。判据按「渲染器认不认」写，不按 Markdown 规范写。
      // 每份稿都保留一条正常条目，避免被「整份稿里一条条目都没有」那条兜住。
      final cases = {
        'quote.md': ('### 修复\n\n- 播放更顺畅。\n- 说明如下：\n\n> 旧版需要手动重连。\n', '引用块'),
        'strike.md': ('### 修复\n\n- ~~旧的说明~~ 换成新的。\n', '删除线'),
        'underscore.md': ('### 修复\n\n- __重要__ 提示。\n', '下划线粗体'),
      };
      for (final entry in cases.entries) {
        final (body, needle) = entry.value;
        final f = File('${tmpDir.path}/${entry.key}');
        f.writeAsStringSync(body);
        final r = runGenerator(py, f);
        expect(r.exitCode, 1,
            reason: '${entry.key} 竟然通过了 ⇒ 渲染器会把它原样显示给用户。\n'
                '${r.stderr.toString()}');
        expect(r.stderr.toString(), contains(needle),
            reason: '${entry.key} 被拒了但没说清是哪种语法 ⇒ 报错读不懂等于没有报错。\n'
                '${r.stderr.toString()}');
      }
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('渲染器认识的写法不许被误拒（`**粗**` / 反引号 / 链接 / 有序列表）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守门不会误伤');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      // 收紧判据的代价必须被钉住：这几种渲染器确实认识，拒了就是逼人改写稿子。
      final f = File('${tmpDir.path}/ok.md');
      f.writeAsStringSync('### 修复\n'
          '\n'
          '- **重要**：播放更顺畅。\n'
          '- 设置里搜索 `自动播放` 即可。\n'
          '- 详见 [帮助页](https://example.com/help)。\n'
          '1. 打开设置。\n'
          '2. 打开自动播放。\n');
      final r = runGenerator(py, f);
      expect(r.exitCode, 0,
          reason: '渲染器认识的写法被拒了 ⇒ 判据按 Markdown 规范而不是按渲染器能力写。\n'
              '${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('校验用的行号对得上原文件（报错不能指错行）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      // 第 3 行放违规内容；前面有 2 行合法内容 + 1 行空行
      final f = File('${tmpDir.path}/line_no.md');
      f.writeAsStringSync('### 修复\n'
          '\n'
          '- 正常的一条说明。\n'
          '- 门禁改成了结构锚。\n');
      final r = runGenerator(py, f);
      expect(r.exitCode, 1, reason: '违规稿竟然通过了');
      expect(r.stderr.toString(), contains('第 4 行'),
          reason: '报错行号不是 4 ⇒ 行号被前移了（剥注释/跳空行）⇒ '
              '人工稿是人写的，报错指错行比报错本身更坑人。\n'
              '${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('只有一条分隔线的稿会被拒（`- - -` 不是条目）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      // `- - -` 满足「- 开头且后面有非空白」⇒ 旧判据会把它当成一条真条目，
      // 于是整份稿只有一条横线也能过「至少一条条目」。这里四种写法都钉住。
      for (final sep in <String>['- - -', '---', '***', '___']) {
        final f = File('${tmpDir.path}/sep.md');
        f.writeAsStringSync('### 修复\n\n$sep\n');
        final r = runGenerator(py, f);
        expect(r.exitCode, 1,
            reason: '只写「$sep」的稿竟然通过了 ⇒ '
                '用户会收到一版只有一条横线的更新说明。\n'
                '${r.stderr.toString()}');
      }
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('空小标题会被拒（`###` 会渲染成一节空白）', () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证守卫会红');
      return;
    }
    final tmpDir = Directory.systemTemp.createTempSync('sourin_manual_gate');
    try {
      // 条目本身完全合法（不含任何开发用语），这样才能证明红的原因是小标题。
      final f = File('${tmpDir.path}/empty_heading.md');
      f.writeAsStringSync('###\n- 播放更顺畅。\n');
      final r = runGenerator(py, f);
      expect(r.exitCode, 1,
          reason: '「###」空小标题竟然通过了 ⇒ 用户会看到一节什么都没有的空白。\n'
              '${r.stderr.toString()}');
      expect(r.stderr.toString(), contains('第 1 行'),
          reason: '拒掉了但没指出是小标题那一行。\n${r.stderr.toString()}');
    } finally {
      try {
        tmpDir.deleteSync(recursive: true);
      } catch (_) {
        // 临时目录删不掉不影响结论
      }
    }
  });

  test('非 UTF-8 控制台下 --help 不炸（argparse 的中文帮助也在 UTF-8 兜底之后）',
      () {
    if (py == null) {
      markTestSkipped('本机没有 python ⇒ 无从验证编码兜底');
      return;
    }
    // ★ 这条钉的是「_force_utf8_stdio() 必须在 parse_args() 之前」：
    //   `--help` 的中文 help 文本是 argparse 自己打印的，
    //   兜底放在 parse_args() 之后，cp1252 标准输出会直接 UnicodeEncodeError。
    final r = Process.runSync(
      py,
      <String>['tools/gen_release_notes.py', '--help'],
      workingDirectory: Directory.current.path,
      stdoutEncoding: const Utf8Codec(),
      stderrEncoding: const Utf8Codec(),
      environment: <String, String>{'PYTHONIOENCODING': 'cp1252'},
    );
    expect(r.exitCode, 0,
        reason: '--help 在 cp1252 下退出码 ${r.exitCode} ⇒ '
            '中文帮助文本打印时炸了（UTF-8 兜底调用得太晚）。\n'
            '${r.stdout.toString()}\n${r.stderr.toString()}');
    expect(r.stdout.toString(), contains('人工确认稿'),
        reason: '--help 里读不到中文说明 ⇒ 帮助文本没正常输出。\n'
            '${r.stdout.toString()}');
  });

  test('CI 接上了人工稿通道（build.yml 里能查到 --manual 与目录约定）', () {
    final f = File('.github/workflows/build.yml');
    expect(f.existsSync(), isTrue, reason: '.github/workflows/build.yml 不存在');
    final yml = f.readAsStringSync();
    expect(yml.contains('--manual'), isTrue,
        reason: 'build.yml 里没有 --manual ⇒ 人工稿写了也不会被用上。');
    expect(yml.contains('docs/release-notes/'), isTrue,
        reason: 'build.yml 里没有 docs/release-notes/ 的目录约定 ⇒ '
            '人工稿与 CI 约定对不上。');
  });
}
