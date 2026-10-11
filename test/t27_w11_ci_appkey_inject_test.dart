// ═══════════════════════════════════════════════════════════════════════
//  T27-11 凭证构建期注入 —— 门禁（纯源码级断言，读文件文本，不跑网络）
// ═══════════════════════════════════════════════════════════════════════
//
// # 业主原话
//     #5「弹弹play 那边配置好了，输入框可以删了」
//     #8「提示没获取到凭证」
//   同一条根因：客户端从未拿到过官方弹弹play 凭证（AppId/AppSecret）。
//
// # 方案（官方文档 doc.dandanplay.com/open/「安全注意事项」明确允许）
//     开源代码里只留占位符；构建时（GitHub Actions）从 secrets 注入真值：
//       job env      ← DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}
//       flutter build ← --dart-define=DANDANPLAY_APP_ID="${{ env.DANDANPLAY_APP_ID }}"
//     fork PR（pull_request 事件）拿不到 secrets ⇒ env 自动为空串，
//     String.fromEnvironment 缺省也是空串 ⇒ 行为与改前逐字一致
//     （回落到用户自填 / 本机弹弹play），不需要额外 if 判断。
//
// # 本门禁钉住什么
//     ① build.yml 三个平台 job（windows/macos/android）各自声明两条凭证
//       env，取值必须来自 secrets.*（三段逐字一致 —— 同一份约定不许
//       三个平台各写各的）
//     ② 三条 flutter build 各追加两个 --dart-define，且值带双引号
//       —— AppSecret 若含 shell 元字符，不加引号会截断命令
//     ③ 既有 SOURIN_VERSION 注入通道未被破坏
//     ④ README：变量名入表 + 发版说明；全文不落真实凭证值
//     ⑤ 阴性对照：凭证行只能是 ${{ secrets.* }} 表达式，不许明文写死
//       （防泄漏）＋ 扫描器自检（对坏样本必须报警，防正则空转假绿）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kWorkflowPath = '.github/workflows/build.yml';
const String kReadmePath = 'README.md';

/// 三个平台 job 的凭证 env 声明（三段必须逐字一致）
const String kAppIdEnvLine =
    r'DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}';
const String kAppSecretEnvLine =
    r'DANDANPLAY_APP_SECRET: ${{ secrets.DANDANPLAY_APP_SECRET }}';

/// 三条 flutter build 追加的 dart-define（三段必须逐字一致；值带双引号）
const String kAppIdDefine =
    r'--dart-define=DANDANPLAY_APP_ID="${{ env.DANDANPLAY_APP_ID }}"';
const String kAppSecretDefine =
    r'--dart-define=DANDANPLAY_APP_SECRET="${{ env.DANDANPLAY_APP_SECRET }}"';

/// 阴性对照：凭证 env 行的取值必须是 ${{ ... }} 表达式（逐行扫）
final RegExp kSecretValueMustBeExpression =
    RegExp(r'DANDANPLAY_(APP_ID|APP_SECRET):\s*(\S.*)$', multiLine: true);

/// 无引号的 dart-define（出现即违规）
final RegExp kUnquotedAppIdDefine =
    RegExp(r'--dart-define=DANDANPLAY_APP_ID=[^"]');
final RegExp kUnquotedAppSecretDefine =
    RegExp(r'--dart-define=DANDANPLAY_APP_SECRET=[^"]');

int occurrences(String haystack, String needle) =>
    haystack.split(needle).length - 1;

String readRepoFile(String path) {
  final f = File(path);
  if (!f.existsSync()) {
    fail('找不到 $path（工作目录 ${Directory.current.path}）');
  }
  return f.readAsStringSync();
}

bool isSecretExpression(String value) {
  final v = value.trim();
  return v.startsWith(r'${{') && v.endsWith('}}');
}

void main() {
  final workflow = readRepoFile(kWorkflowPath);
  final readme = readRepoFile(kReadmePath);

  group('T27-11 · build.yml 注入通道', () {
    test('① 三个平台 job 各声明两条凭证 env（取值来自 secrets）', () {
      expect(occurrences(workflow, kAppIdEnvLine), 3,
          reason: 'DANDANPLAY_APP_ID 的 env 声明应恰好在 windows/macos/android 三个 job 各一次');
      expect(occurrences(workflow, kAppSecretEnvLine), 3,
          reason: 'DANDANPLAY_APP_SECRET 的 env 声明应恰好在三个 job 各一次');
    });

    test('② 三条 flutter build 各追加两个带引号的 --dart-define（三平台逐字一致）', () {
      final allLines = workflow.split('\n');
      final buildLines = allLines
          .where((l) => l.contains('flutter build windows') ||
              l.contains('flutter build macos') ||
              l.contains('flutter build apk'))
          .toList();
      expect(buildLines.length, 3, reason: '改动面收敛：恰好三条 flutter build 命令');
      for (final line in buildLines) {
        // run: >- 折叠块：--dart-define 写在 flutter build 的续行上，
        // 运行时 yaml 折叠成同一条命令 ⇒ 按续行块断言（块到下一个空行为止）。
        final i = allLines.indexOf(line);
        final end = allLines.indexWhere((l) => l.trim().isEmpty, i + 1);
        final block = allLines.sublist(i + 1, end).join('\n');
        expect(block.contains(kAppIdDefine), isTrue,
            reason: '「$line」的续行块缺带引号的 AppId dart-define');
        expect(block.contains(kAppSecretDefine), isTrue,
            reason: '「$line」的续行块缺带引号的 AppSecret dart-define');
      }
      expect(occurrences(workflow, kAppIdDefine), 3);
      expect(occurrences(workflow, kAppSecretDefine), 3);
      expect(kUnquotedAppIdDefine.allMatches(workflow), isEmpty,
          reason: 'dart-define 的值必须带双引号：AppSecret 含 shell 元字符时不加引号会截断命令');
      expect(kUnquotedAppSecretDefine.allMatches(workflow), isEmpty,
          reason: 'dart-define 的值必须带双引号');
    });

    test('③ 既有 SOURIN_VERSION 注入通道未被破坏', () {
      expect(occurrences(workflow, r'--dart-define=SOURIN_VERSION='), 3);
      expect(occurrences(workflow, r'${{ env.SOURIN_VERSION }}'), 3);
    });

    test('⑤ 阴性对照：凭证不许明文写死（只能取自 secrets 表达式）', () {
      for (final m in kSecretValueMustBeExpression.allMatches(workflow)) {
        expect(isSecretExpression(m.group(2)!), isTrue,
            reason: '「${m.group(1)}」的取值必须是 \${{ secrets.* }} 表达式，不许明文写死（防泄漏）');
      }
    });

    test('⑤b 扫描器自检：坏样本必须报警、好样本必须放行（防正则空转假绿）', () {
      const bad = 'DANDANPLAY_APP_SECRET: "its-a-literal-secret"';
      const good =
          r'DANDANPLAY_APP_SECRET: ${{ secrets.DANDANPLAY_APP_SECRET }}';
      bool leaks(String src) => kSecretValueMustBeExpression
          .allMatches(src)
          .any((m) => !isSecretExpression(m.group(2)!));
      expect(leaks(bad), isTrue, reason: '明文凭证必须被识别');
      expect(leaks(good), isFalse, reason: 'secrets 表达式必须放行');
      expect(
          kUnquotedAppIdDefine.hasMatch('--dart-define=DANDANPLAY_APP_ID=abc'),
          isTrue,
          reason: '无引号形态必须被识别');
      expect(kUnquotedAppIdDefine.hasMatch(kAppIdDefine), isFalse,
          reason: '带引号的合法形态不得误报');
    });
  });

  group('T27-11 · README 文档', () {
    test('④ 两个变量名入表且给出发版说明（全文不含真实凭证值）', () {
      expect(occurrences(readme, 'DANDANPLAY_APP_ID'), greaterThanOrEqualTo(2),
          reason: '至少出现在表格 + 发版说明两处');
      expect(occurrences(readme, 'DANDANPLAY_APP_SECRET'), greaterThanOrEqualTo(2));
      expect(readme.contains('Secrets'), isTrue,
          reason: '发版说明应指向 GitHub Settings → Secrets and variables → Actions');
      expect(occurrences(readme, '--dart-define=DANDANPLAY_APP_ID'), isNonZero,
          reason: 'README 应给出构建注入的用法示例');
      expect(readme.contains('xgmriqmqcq'), isFalse,
          reason: 'README 不得写出真实 AppId —— 仓库里永远不落凭证值');
    });
  });
}
