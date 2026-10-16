// ═══════════════════════════════════════════════════════════════════════
//  T27-15：弹弹play 凭证「构建期注入」通道 —— 静态契约
// ═══════════════════════════════════════════════════════════════════════
//
// # Owner 诉求（逐字）
//     > 使用内置的,这个我在历史会话中提交过
//     > 你帮我看看开发声明中允不允许内置,如果不允许 就算了,就还是保留输入框
//     > 这个你也帮我做了吧
//
// # 开发声明怎么说（官方《开放弹幕网络》§7 安全注意事项，原文）
//     尽量不在客户端应用中硬编码您的 AppSecret。
//     如果您正在开发开源的客户端项目，可以选择：
//       · 在开源代码中使用占位符，之后在构建时（如使用 GitHub Actions）
//         从机密中读取 AppSecret 后替换此占位符。
//   ⇒ **允许内置**，前提是「占位符 + 构建期注入」。
//
// # 本文件守什么
//
// ① CI 那条通道（build.yml）已经由 t27_w11 守着；
//    本文件守**本机**那条（tools/run_client.ps1）—— 原先根本没有，
//    所以本地构建永远拿不到凭证，面板只能让用户手填。
// ② ★ 最要紧的一条：**仓库里永远不许出现真值**。
//    这条比"注入通不通"更重要 —— 注入不通只是功能缺失，
//    密钥进库是不可撤销的安全事故。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String p) => File(p).readAsStringSync();

void main() {
  group('T27-15 · 本机构建注入通道', () {
    test('① run_client.ps1 真的把凭证转成 --dart-define（不是只读不用）', () {
      final src = readRepoFile('tools/run_client.ps1');

      // 读本机凭证文件（而不是硬编码）
      expect(src.contains('.dandanplay.local.json'), isTrue,
          reason: '必须从本机文件读凭证（仓库里不能有真值）');
      expect(src.contains('DANDANPLAY_APP_ID'), isTrue);
      expect(src.contains('DANDANPLAY_APP_SECRET'), isTrue);

      // ★ 关键：读到了要**真的用上** —— 拼进 --dart-define。
      //   只读不拼是本通道最容易漏的一环（凭证读进来了、App 还是没有）。
      expect(src.contains('--dart-define=DANDANPLAY_APP_ID='), isTrue,
          reason: '★ 必须拼进 --dart-define，否则等于没注入');
      expect(
          src.contains('--dart-define=DANDANPLAY_APP_SECRET='), isTrue,
          reason: '★ AppSecret 也必须拼进去（只有 AppId 签不了名）');

      // 且两条构建路径都要带上（-Dev 与 Release 各一处 + 定义处）
      final uses = RegExp(r'@credArgs').allMatches(src).length;
      expect(uses, greaterThanOrEqualTo(2),
          reason: '★ -Dev(flutter run) 与 Release(flutter build) 两条路都要注入；'
              '实际出现 $uses 次');
    });

    test('② ★★ 仓库里绝不含真 AppSecret（安全底线，按形状扫）', () {
      /*
       * # 判据为什么要收窄（第一版是错的）
       *
       * 第一版写的是「32+ 位连续字母数字 ⇒ 疑似 Secret」。
       * 实测**假红**：真实命中全是无害的长 hex ——
       *   · lib/core/danmaku.dart 里 SHA-256 的**测试向量**
       *     （e3b0c442… 是空串的 SHA-256，教科书常量）
       *   · build.yml 里的**提交哈希**（fcdce322…）
       * ⇒ 拿「长度」当判据太糙，会把正经代码全判红，
       *   而假红会让人把门禁关掉 —— 那才是真的失去防护。
       *
       * # 收窄后的判据（两条，都要成立才算泄漏）
       *     ① 长度 ≥ 24 的连续字母数字
       *     ② 且出现在**赋值/引用语境**（appId/appSecret/secret/token 那一行）
       * ⚠️ 真泄漏一定出现在「把密钥交给某个变量」的位置 ⇒ 只扫那种行。
       *    全文件裸扫会把 SHA-256 测试向量与提交哈希全判成密钥。
       */
      final risky = <String>[
        'tools/run_client.ps1',
        'README.md',
        'lib/core/danmaku.dart',
        '.github/workflows/build.yml',
      ];
      // 赋值语境：出现这些词的那一行，才检查有没有长随机串
      final assignCtx = RegExp(
          r'(appsecret|app_secret|appid|app_id|secret|token)',
          caseSensitive: false);
      final looksRandom = RegExp(r'[A-Za-z0-9]{24,}');

      for (final f in risky) {
        if (!File(f).existsSync()) continue;
        final lines = readRepoFile(f).split('\n');
        for (var i = 0; i < lines.length; i++) {
          final line = lines[i];
          // 只看「把凭证交给谁」的那一行
          if (!assignCtx.hasMatch(line)) continue;
          for (final m in looksRandom.allMatches(line)) {
            final v = m.group(0)!;
            // 引用 secret 的合法写法（这些都不是真值）
            if (line.contains(r'secrets.') ||
                line.contains(r'.env:') ||
                line.contains('String.fromEnvironment') ||
                line.contains('builtin') ||
                line.contains('DANDANPLAY_APP_ID=') ||
                line.contains('DANDANPLAY_APP_SECRET=') ||
                line.contains('dandanplay.local.json')) {
              continue;
            }
            fail('★ 疑似 AppSecret 泄漏：' + f + ':' + (i + 1).toString() +
                ' —— 赋值语境里出现长随机串 (' + v.length.toString() + ' 位)。' +
                '密钥绝不允许进仓库。');
          }
        }
      }
    });

    test('③ 本机凭证文件必须被 .gitignore 挡住（否则一次 add 就进库）', () {
      final gi = readRepoFile('.gitignore');
      expect(gi.contains('.dandanplay.local.json'), isTrue,
          reason: '★ 凭证文件必须被忽略；漏了就是密钥进库级别的事故');
    });

    test('④ 没有凭证时构建照常（不注入即可，不是报错退出）', () {
      final src = readRepoFile('tools/run_client.ps1');
      // credArgs 初值必须是**空数组**（而不是 throw / exit）
      expect(src.contains(r'$credArgs = @()'), isTrue,
          reason: '★ 缺凭证要退化成「不注入」，不能让整个构建失败 —— '
              '外部弹幕源那条路不依赖官方凭证，不该被连坐');
    });
  });
}
