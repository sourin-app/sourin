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
//   · 写了表格 / HTML / 代码块 ⇒ 客户端渲染器不支持，原样漏出
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

void main() {
  final py = findPython();

  test('人工确认稿目录存在（否则这条门禁扫不到东西）', () {
    final dir = Directory(_manualDir);
    expect(dir.existsSync(), isTrue,
        reason: '$_manualDir 不存在 —— 人工确认稿通道的落点没了。'
            '「没查」不能渲染成「没问题」，所以这里必须红。');
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
      final bad = File('${tmpDir.path}/bad.md');
      // 三处违规：表格行 + 开发用语「门禁」+ 没有可用的分类小标题
      bad.writeAsStringSync('### 修复\n\n'
          '| 平台 | 说明 |\n'
          '|---|---|\n'
          '- 门禁改成结构锚了\n');
      final r = Process.runSync(
        py,
        <String>[
          'tools/gen_release_notes.py',
          '--manual',
          bad.path,
          '--out',
          '${tmpDir.path}/out.md',
        ],
        workingDirectory: Directory.current.path,
      );
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
