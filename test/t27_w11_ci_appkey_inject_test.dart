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
//     开源代码里只留占位符；构建时（GitHub Actions）从 secrets 注入真值。
//     ★ 凭证 env 只挂在三条 flutter build **步骤级**（不挂 job 级）——
//       CodeRabbit #5 指出：job 级 env 会注入到该 job 的每一个步骤，
//       「全量测试」与第三方 Action 都能读到 Secret（CWE-94 注入面）。
//       且用**对应 shell 的语法**引用（不经 ${{ }} 文本插值）：
//         step env    ← DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}
//         Windows(pwsh)  ← --dart-define=DANDANPLAY_APP_ID="$env:DANDANPLAY_APP_ID"
//         macOS/Android  ← --dart-define=DANDANPLAY_APP_ID="$DANDANPLAY_APP_ID"
//       这样 Secret 内容作为**环境变量值**被 dart 直接取用（命令行是参数
//       数组，不经 shell 二次解析）⇒ 含引号 / $ / 反引号也不会改变命令解析。
//     fork PR（pull_request 事件）拿不到 secrets ⇒ env 自动为空串，
//     String.fromEnvironment 缺省也是空串 ⇒ 行为与改前逐字一致
//     （回落到用户自填 / 本机弹弹play），不需要额外 if 判断。
//
// # 本门禁钉住什么
//     ① build.yml 里凭证 env 取自 secrets.* 且**只挂在三条 flutter build 步骤**
//       （步骤级最小权限：job 级不许出现凭证 env）
//     ② 三条 flutter build 各追加两个 --dart-define，且值用对应 shell 语法
//       引用（Windows $env:NAME、macOS/Android $NAME），不得回退成 ${{ }} 文本插值
//     ③ 既有 SOURIN_VERSION 注入通道未被破坏
//     ④ README：变量名入表 + 发版说明；全文不落真实凭证值
//     ⑤ 阴性对照：凭证行只能是 ${{ secrets.* }} 表达式，不许明文写死
//       （防泄漏）＋ 扫描器自检（对坏样本必须报警，防正则空转假绿）

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String kWorkflowPath = '.github/workflows/build.yml';
const String kReadmePath = 'README.md';

/// ★ 2026-10-15：配置与环境变量说明从 README 拆到了 `docs/CONFIG.md`。
///   本组断言跟着文档走（判据不变，只是换了承载文件），
///   并额外要求 README 仍指向它 —— 否则索引一改，这条门禁就悄悄失效了。
const String kConfigDocPath = 'docs/CONFIG.md';

/// 凭证 env 声明（三段必须逐字一致；挂在三条 build 步骤上）
const String kAppIdEnvLine =
    r'DANDANPLAY_APP_ID: ${{ secrets.DANDANPLAY_APP_ID }}';
const String kAppSecretEnvLine =
    r'DANDANPLAY_APP_SECRET: ${{ secrets.DANDANPLAY_APP_SECRET }}';

/// 三条 flutter build 追加的 dart-define（三段必须逐字一致）
/// ★ Windows 是 pwsh ⇒ $env:NAME；macOS / Android 是 bash ⇒ $NAME
const String kAppIdDefineWin =
    r'--dart-define=DANDANPLAY_APP_ID="$env:DANDANPLAY_APP_ID"';
const String kAppSecretDefineWin =
    r'--dart-define=DANDANPLAY_APP_SECRET="$env:DANDANPLAY_APP_SECRET"';
const String kAppIdDefineSh =
    r'--dart-define=DANDANPLAY_APP_ID="$DANDANPLAY_APP_ID"';
const String kAppSecretDefineSh =
    r'--dart-define=DANDANPLAY_APP_SECRET="$DANDANPLAY_APP_SECRET"';

/// 阴性对照：凭证 env 行的取值必须是 ${{ ... }} 表达式（逐行扫）
final RegExp kSecretValueMustBeExpression =
    RegExp(r'DANDANPLAY_(APP_ID|APP_SECRET):\s*(\S.*)$', multiLine: true);

/// 旧写法（${{ env.NAME }} 文本插值）出现即违规：
/// Secret 里若含引号 / $ / 反引号会改变生成脚本的解析（CWE-94）。
final RegExp kLegacyInterpolatedAppIdDefine =
    RegExp(r'--dart-define=DANDANPLAY_APP_ID="\$\{\{');
final RegExp kLegacyInterpolatedAppSecretDefine =
    RegExp(r'--dart-define=DANDANPLAY_APP_SECRET="\$\{\{');

int occurrences(String haystack, String needle) =>
    haystack.split(needle).length - 1;

/// 去掉**整行注释**之后的行。
///
/// ★ 2026-10-21（PR #32）：本仓 build.yml 的注释是「判据的唯一权威说明处」，
///   里面会**原样引用**被守的文本 —— 例如把注入片段贴进 ```yaml 块里讲清楚
///   「空串照样能编进二进制」。整文件计数会把注释一起数进分母：
///   实测注释让 kAppIdEnvLine 从 5 变成 6、kAppIdDefineWin 从 1 变成 2，
///   门禁于是红在「注释写得太详细」上 —— 而那正是它最该鼓励的东西。
///   ⇒ 计数只在**可执行行**上做；注释不构成注入，也不构成违规。
List<String> codeOnlyLines(List<String> allLines) =>
    allLines.where((l) => !l.trimLeft().startsWith('#')).toList();

/// 一个 job 级步骤块（以 6 空格缩进的 `- name:` 为界）。
class StepBlock {
  const StepBlock(this.header, this.text);

  final String header;
  final String text;

  bool get hasCredentials => occurrences(text, kAppIdEnvLine) > 0;
}

List<StepBlock> stepBlocks(List<String> codeLines) {
  final blocks = <StepBlock>[];
  for (var i = 0; i < codeLines.length; i++) {
    if (!codeLines[i].startsWith('      - name:')) continue;
    var end = i + 1;
    while (end < codeLines.length &&
        !codeLines[end].startsWith('      - name:')) {
      end++;
    }
    blocks.add(StepBlock(codeLines[i], codeLines.sublist(i, end).join('\n')));
  }
  return blocks;
}

/// 「凭据预检」步骤：它**必须**拿到凭证值才能判定空不空（判的是值，不是名字）。
/// 把凭据挂在这一步上是**有意的**步骤级最小权限，不是漏配到 job 级。
bool _isPreflightLine(String l) => l.contains('凭据预检');


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

/// 返回 workflow 里**需要注入凭证**的那三个发布构建步骤块的完整文本
///
/// （从 build 命令行向前找到步骤头 `- name:`，向后到下一个同级步骤为止）。
/// 用来断言「dart-define 与 step env 出现在同一步骤块内」。
///
/// ⚠️⚠️ 2026-10-12（PR #6）：判据从「**所有** flutter build 步骤」收窄到
///    「**发布用**的那三个」—— 起因是 native-media 诊断 job 需要
///    `flutter build windows --debug` 来触发 CMake 供出 libmpv-2.dll
///    （光 `flutter pub get` 供不出来，已实测；见 build.yml 里那段说明）。
///    那一步**不注入任何凭证**，把它算进来会误报"每个 build 步骤都要有 env"。
///
/// ★ 收窄的是**范围**，不是**判据**：三条发布构建（windows/macos/apk）
///   仍然逐个要求「恰好一次 AppId + 恰好一次 AppSecret，且在本步骤块内」。
///   新增的无凭证构建步**不削弱**任何一条既有断言。
///
/// ★ 判据怎么认"发布用"：那三条都是 `--release`。诊断步用 `--debug`。
///   （写死 `--release` 而不是"排除某个 job 名"—— job 名会改，语义不会。）
bool _isReleaseBuildLine(String l) {
  final isBuild = l.contains('flutter build windows') ||
      l.contains('flutter build macos') ||
      l.contains('flutter build apk');
  return isBuild && l.contains('--release');
}

List<String> buildStepBlocks(List<String> allLines) {
  final blocks = <String>[];
  for (var i = 0; i < allLines.length; i++) {
    final l = allLines[i];
    if (!_isReleaseBuildLine(l)) {
      continue;
    }
    // 向前找到本步骤的起始（`      - name:` 行，缩进 6 个空格）
    var start = i;
    while (start > 0 && !allLines[start].startsWith('      - name:')) {
      start--;
    }
    // 向后找到下一个同级步骤（`      - name:`）或遇到更浅缩进的非空行
    var end = i + 1;
    while (end < allLines.length) {
      if (allLines[end].startsWith('      - name:')) break;
      if (allLines[end].trim().isNotEmpty &&
          !allLines[end].startsWith('        ') &&
          !allLines[end].startsWith('      ')) {
        break;
      }
      end++;
    }
    blocks.add(allLines.sublist(start, end).join('\n'));
  }
  return blocks;
}

void main() {
  final workflow = readRepoFile(kWorkflowPath);
  final readme = readRepoFile(kReadmePath);
  final configDoc = readRepoFile(kConfigDocPath);
  final allLines = workflow.split('\n');
  final codeLines = codeOnlyLines(allLines);
  final codeText = codeLines.join('\n');

  group('T27-11 · build.yml 注入通道', () {
    test('① 凭证 env 只挂在三条发布构建 + 两条凭据预检上（步骤级最小权限）', () {
      // ★ 2026-10-21（PR #32）：白名单从「三条 build」扩到「三条 build + 两条预检」。
      //   预检（tools/check_required_secrets.sh）判的是**值空不空**，
      //   而 Actions 不提供「列 secret 名」的能力 ⇒ 它只能拿到值。
      //   扩白名单的同时，下面把「谁带着凭据」逐个点名，绝不放开成「随便几步都行」。
      final blocks = stepBlocks(codeLines);
      final publish = blocks
          .where((b) => b.text.split('\n').any(_isReleaseBuildLine))
          .toList();
      final preflight =
          blocks.where((b) => _isPreflightLine(b.header)).toList();

      expect(publish.length, 3, reason: '改动面收敛：恰好三条**发布用** flutter build 步骤');
      expect(preflight.length, 2,
          reason: '凭据预检应恰好两步：windows 与 macos 各一份（同一份脚本）');

      for (final block in [...publish, ...preflight]) {
        expect(occurrences(block.text, kAppIdEnvLine), 1,
            reason: '「${block.header.trim()}」块内应恰含一次 AppId env 声明（步骤级）');
        expect(occurrences(block.text, kAppSecretEnvLine), 1,
            reason: '「${block.header.trim()}」块内应恰含一次 AppSecret env 声明（步骤级）');
      }

      // 反向：除这 5 步之外，任何步骤都**不许**带凭证 env（将来新增步骤不能顺手加）
      final allowed = {...publish.map((b) => b.header), ...preflight.map((b) => b.header)};
      for (final block in blocks.where((b) => b.hasCredentials)) {
        expect(allowed.contains(block.header), isTrue,
            reason: '「${block.header.trim()}」带着凭证 env，但它既不是发布构建也不是凭据预检 '
                '⇒ 凭证注入面被扩散了（要么去掉，要么在白名单里显式说明理由）');
      }
      expect(blocks.where((b) => b.hasCredentials).length, 5,
          reason: '带凭证的步骤应恰好 5 个（3 发布构建 + 2 预检）');
    });

    test('①b 凭证 env 不出现在 job 级（6 空格缩进即 job 级，违规）', () {
      for (var i = 0; i < allLines.length; i++) {
        final l = allLines[i];
        if (RegExp(r'^      DANDANPLAY_(APP_ID|APP_SECRET):').hasMatch(l)) {
          fail('第 ${i + 1} 行把凭证声明在 job 级 env：$l\n'
              '  ⇒ job 级 env 会注入到该 job 的每个步骤，「全量测试」与第三方 '
              'Action 都能读到 Secret（CWE-94，最小权限）。应下移到 build 步骤级。');
        }
      }
    });

    test('② 三条发布用 flutter build 各追加两个 dart-define，且用对应 shell 语法引用', () {
      // ★ 只取**发布用**那三条（--release）—— 诊断 job 那条 --debug 不注入凭证，
      //   不该被要求带 dart-define。理由见 buildStepBlocks 的说明。
      // ★ 只在**可执行行**上取（注释里的示例不构成注入），见 codeOnlyLines。
      final buildLines = codeLines.where(_isReleaseBuildLine).toList();
      expect(buildLines.length, 3, reason: '改动面收敛：恰好三条**发布用** flutter build 命令');
      for (final line in buildLines) {
        final i = codeLines.indexOf(line);
        final end = codeLines.indexWhere((l) => l.trim().isEmpty, i + 1);
        final block = codeLines.sublist(i + 1, end).join('\n');
        final isWindows = line.contains('flutter build windows');
        final appIdDefine = isWindows ? kAppIdDefineWin : kAppIdDefineSh;
        final appSecretDefine =
            isWindows ? kAppSecretDefineWin : kAppSecretDefineSh;
        expect(block.contains(appIdDefine), isTrue,
            reason: '「$line」的续行块缺对应 shell 语法'
                '（${isWindows ? 'pwsh \$env:' : 'bash \$'}）的 AppId dart-define');
        expect(block.contains(appSecretDefine), isTrue,
            reason: '「$line」的续行块缺对应 shell 语法的 AppSecret dart-define');
      }
      // 三段逐字一致：Windows 一份 + 两个非 Windows 平台各一份
      expect(occurrences(codeText, kAppIdDefineWin), 1);
      expect(occurrences(codeText, kAppSecretDefineWin), 1);
      expect(occurrences(codeText, kAppIdDefineSh), 2,
          reason: 'macOS 与 Android 各一份 \$NAME 形态');
      expect(occurrences(codeText, kAppSecretDefineSh), 2);
      // 旧写法（${{ env.NAME }} 文本插值）必须绝迹 —— Secret 含元字符会改解析
      expect(kLegacyInterpolatedAppIdDefine.allMatches(codeText), isEmpty,
          reason: 'dart-define 不得回退成 \${{ env.NAME }} 文本插值：'
              'Secret 含双引号 / \$ / 反引号时会改变生成脚本的解析（CWE-94）');
      expect(kLegacyInterpolatedAppSecretDefine.allMatches(codeText), isEmpty,
          reason: 'dart-define 不得回退成 \${{ env.NAME }} 文本插值');
    });

    test('③ 既有 SOURIN_VERSION 注入通道未被破坏', () {
      // ★ 仍是 3：只有那三条**发布用**构建带 SOURIN_VERSION，
      //   诊断 job 的 --debug 构建不带（它不发版，不需要知道自己是谁）。
      expect(occurrences(workflow, r'--dart-define=SOURIN_VERSION='), 3);
      expect(occurrences(workflow, r'${{ env.SOURIN_VERSION }}'), 3);
    });

    test('⑤ 阴性对照：凭证不许明文写死（只能取自 secrets 表达式）', () {
      // ★ 只在可执行行上扫：注释里那段 ```yaml 示例讲的是「空串照样能编进去」，
      //   它不是注入点。放开注释不会放过任何真实明文（真明文只会出现在可执行行）。
      for (final m in kSecretValueMustBeExpression.allMatches(codeText)) {
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
          kLegacyInterpolatedAppIdDefine.hasMatch(
              r'--dart-define=DANDANPLAY_APP_ID="${{ env.DANDANPLAY_APP_ID }}"'),
          isTrue,
          reason: '旧插值写法必须被识别（阴性对照不许空转）');
      expect(kLegacyInterpolatedAppIdDefine.hasMatch(kAppIdDefineWin), isFalse,
          reason: '新的 \$env: 形态不得误报');
      expect(kLegacyInterpolatedAppIdDefine.hasMatch(kAppIdDefineSh), isFalse,
          reason: '新的 \$NAME 形态不得误报');
    });
  });

  group('T27-11 · 文档（docs/CONFIG.md + README 索引）', () {
    test('④ 两个变量名入表且给出发版说明（全文不含真实凭证值）', () {
      expect(occurrences(configDoc, 'DANDANPLAY_APP_ID'), greaterThanOrEqualTo(2),
          reason: '至少出现在表格 + 发版说明两处');
      expect(occurrences(configDoc, 'DANDANPLAY_APP_SECRET'),
          greaterThanOrEqualTo(2));
      expect(configDoc.contains('Secrets'), isTrue,
          reason: '发版说明应指向 GitHub Settings → Secrets and variables → Actions');
      expect(occurrences(configDoc, '--dart-define=DANDANPLAY_APP_ID'), isNonZero,
          reason: '应给出构建注入的用法示例');
      expect(configDoc.contains('xgmriqmqcq'), isFalse,
          reason: '不得写出真实 AppId —— 仓库里永远不落凭证值');
      // ★ README 必须仍然指得到这份文档（文档搬家后索引不许悬空）
      expect(readme.contains('docs/CONFIG.md'), isTrue,
          reason: 'README 必须指向 docs/CONFIG.md，否则凭证说明对读者不可达');
      expect(readme.contains('xgmriqmqcq'), isFalse,
          reason: 'README 不得写出真实 AppId —— 仓库里永远不落凭证值');
    });
  });
}
