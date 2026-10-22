// ═══════════════════════════════════════════════════════════════════════
//  门禁：用户可见文案里不许有 Markdown 星号（清单 A · 第二批）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么
//
// ```text
// Flutter 的 `Text` **不解析 markdown** ⇒ `**粗体**` 会**原样显示**在屏幕上。
// ★ 本仓**几乎**没有 markdown 渲染器 ⇒ 凡是要显示给用户的 `**` 都是露馅。
// ★★ 但**有一个**例外：`lib/ui/widgets/release_notes.dart:98`
//   （`RegExp(r'\*\*(.+?)\*\*')` ⇒ TextSpan 粗体），**只用于「发行说明」**。
//   我第一版写的是「全仓没有」⇒ 被 Lead 复核推翻（2026-10-19）。
// ★ 教训：「没有 X」比「有 X」**更需要证据** —— 证明「没有」要把所有可能的
//   实现都排除掉；判"有没有"要 grep **行为**（RegExp/TextSpan），不是 grep **名字**。
// ★ 本文件负责的三个文件里**没有**发行说明那处 ⇒ 这里确实没有渲染器。
// ```
//
// ★ 真机截图实证（2026-10-19，第 66 轮）：备份面板上逐字是
//   「这个备份文件会**含登录态**（2 个内容源）。」
//   而当时 +27 条门禁**全绿** —— 它们断言的是**行为**，不是"文案长什么样"。
//
// # ★★ 这个文件守的是**三个不同渲染路径**
//
// ```text
// sync_panel.dart            _note() / _confirm() 的 message / 口令对话框的 Text
// danmaku_source_page.dart   DanmakuProbeReport.remedy → Text(report.remedy)
// danmaku.dart                DanmakuHint.text → Text(h.text)
// ```
//
// ⇒ 三条路径**各**要一条判据，且**每条都读渲染结果**。
//
// # ★★★ 最要紧的一条：**不许误伤脱敏掩码**
//
// `lib/core/danmaku.dart` 里有**三处有意的打码/脱敏**：
//
// ```text
// :1431  '****'                     ← maskedAppId 打码掩码
// :1432  '${id.substring(0,4)}****' ← 同上
// :2223  '***'                      ← URL 脱敏（把路径首段换成 ***）
// ```
//
// ★★ 这三处**一个字都不能动** —— 动了就是把 AppId 与真实域名暴露给用户。
// ⇒ 判据必须能区分「markdown 粗体」与「脱敏掩码」：
//
// ```text
// markdown 粗体  = **  + 非空内容 + **      （中间夹着真文字）
// 脱敏掩码      = 只由星号组成（*** / ****）  （中间是空的）
// ```
//
// # ★ 防空转自检（本会话已出三次恒真/假绿判据）
//
// 「不含 `**`」在**树为空**时**也为真** ⇒ 门禁必须先断言
// 树**非空**且含**已知文案**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/danmaku.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';

import 'package:sourin_spike/ui/widgets/danmaku_settings_dialog.dart';
import 'package:sourin_spike/ui/widgets/sync_panel.dart';

import 'support/ui_shot.dart';

// ★ 唯一判别式（铁律 170）
import '_support/markdown_bold.dart';

/// ★ 读源码：剥掉注释行
///
/// ⚠️ 必须剥注释 —— 本仓的注释里**故意**写着 `**粗体**` 讲这个坑
///   （`lib/shell.dart:6955`），不剥会把它们当成命中。
String _codeOf(String path) => File(path)
    .readAsStringSync()
    .split('\n')
    .where((l) {
      final t = l.trimLeft();
      return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
    })
    .join('\n');

/// ★★ 找出**真正的 markdown 粗体**（脱敏掩码不算）
///
/// # ★★★ 为什么不能用正则去"找 `**…**`"
///
/// ```text
/// 试过的三条正则都**跨行**匹配，把脱敏掩码吃进去了：
///   \*\*([^*]+)\*\*                        ← 跨行 + 掩码四个星号里挑两个
///   \*\*(?!\*)([^*](?:[^*]*[^*])?)(?<!\*)\*\* ← 加了两侧守卫，仍然跨行
///   逐条字面量 + "纯星号才放过"            ← 「前缀 + 掩码」仍被误伤
///
/// # 根因：脱敏掩码的形态是「一段前缀 + 一串星号」
///
/// ```text
///   '****'                        ← 纯星号
///   '${id.substring(0, 4)}****'   ← 前缀 + 星号
/// ```
///
/// 而 markdown 粗体是「`**` + **文字** + `**`」——
/// ★ 两者**唯一的结构差别**是：**星号之间夹不夹着非星号的文字**。
///   掩码：星号之间**什么都没有**（全是星号）
///   粗体：星号之间**有文字**
///
/// ⇒ 判据（逐条字面量地查）：
///   1. 该字面量含 `**`
///   2. 且存在一处 `**…**`，其中 `…` **含非星号字符**
///   3. ⇒ 命中
///
/// ⇒ 这样 `****` 与 `${id.substring(0, 4)}****` 都不会被误伤，
///   而 `'这是**粗体**文字'` 会被抓到。
///
/// ★★ 2026-10-19（Lead）：判据**已抽到** `_support/markdown_bold.dart`
///   （铁律 170：同一纪律只能有一个实现）。这里保留函数名是为了不改调用点，
///   但**不再自己维护一份正则** —— 两份实现会漂开，而漂开的后果是
///   某个门禁开始要求把脱敏掩码改成「」（= 明文暴露 AppId）。
List<String> markdownBolds(String code) => markdownBoldLiterals(code);

/// 渲染一个 widget 并读树上所有可见 `Text`
List<String> visibleTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

void main() {
  setUpAll(loadRealFonts);

  setUp(() {
    ClipDownloader.debugSetDataDir(
      '${Directory.systemTemp.path}${Platform.pathSeparator}sourin-t66-dan-md',
    );
  });

  tearDown(() {
    ClipDownloader.debugSetDataDir(null);
    SourinApi.installSyncDebugFetchers();
  });

  // ─────────────────────────────────────────────────────────────────
  // ⓪ 仪器自检：判据本身不是恒真
  // ─────────────────────────────────────────────────────────────────

  group('⓪ 仪器自检：判据有分辨率', () {
    test('★★ 空树/空串上「不含 markdown 粗体」**也为真** ⇒ 它是恒真判据', () {
      // ★ 阳性对照：空输入上判据什么也不报
      expect(markdownBolds(''), isEmpty,
          reason: '★ 阳性对照：空输入上判据确实什么也不报');
      // ★ 而**真的**有粗体时它必须报出来 —— 否则它恒真
      expect(markdownBolds("'这是**粗体**文字'"), hasLength(1),
          reason: '★★ 阳性对照：真的有粗体时必须抓到，否则它恒真');
    });

    test('★★ 掩码（*** / ****）**不算** markdown 粗体（绝不能误伤脱敏）', () {
      // ★★★ 这条是本文件最要紧的断言 ——
      //   `danmaku.dart` 有三处**有意**的打码/脱敏，
      //   判据若把它们当成命中，就会逼着人把它们改掉 ⇒ 泄露 AppId 与真实域名。
      expect(markdownBolds("'****'"), isEmpty,
          reason: '★★ 打码掩码 **** 不是 markdown 粗体');
      expect(markdownBolds(r"'${id.substring(0,4)}****'"), isEmpty,
          reason: '★★ 带前缀的打码掩码也不是 markdown 粗体'
              '（★ 这条是我第一版漏掉的：判据只放过"纯星号"，'
              '而真实形态是"前缀 + 星号" ⇒ 静态门禁报了一个**假命中**）');
      expect(markdownBolds("['***', ...segs.skip(1)]"), isEmpty,
          reason: '★★ URL 脱敏 *** 不是 markdown 粗体');
      // ★ 而真正的 markdown 粗体必须被抓到
      expect(markdownBolds("'这是**粗体**文字'"), hasLength(1),
          reason: '★★ 阳性对照：真正的 markdown 粗体必须被抓到');
      // ★★ 同一行里多个粗体也要抓到
      expect(markdownBolds("'前**甲**中**乙**后'"), hasLength(1),
          reason: '★★ 同一行里多个粗体也要抓到');
    });

    testWidgets('★★ 空的树 ⇒ 「整棵树不含粗体」**也为真**（所以要自检）',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();
      final texts = visibleTexts(tester);
      expect(texts, isEmpty, reason: '★ 前置：树确实是空的');
      expect(texts.every((s) => !s.contains('**')), isTrue,
          reason: '★★ 这条正是"光断言不含 `**`"的毛病：空树也满足');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // ★ 路径 ①：sync_panel.dart
  // ─────────────────────────────────────────────────────────────────

  group('★ sync_panel.dart（_note / _confirm / 口令对话框）', () {
    testWidgets('★★ 同步面板整棵树不含 markdown 粗体', (tester) async {
      // ★ 注入：本机有明文密码类源 ⇒ 那条 `_note` 才会渲染
      SourinApi.installSyncDebugFetchers(
        status: () async => const SyncStatus(
          connected: true,
          backend: 'WebDAV',
          deviceId: 'dev-a',
        ),
        settings: () async => const SyncSettings(
          connected: true,
          baseUrl: 'https://dav.example.invalid/dav/',
          username: 'u@example.invalid',
          remoteDir: 'sourin',
        ),
        backups: () async => const <SyncBackupEntry>[],
        credentials: () async => const CredentialsStatus(
          enabled: true,
          passphraseSet: true,
          providers: 2,
          plaintextPasswordProviders: ['zz-t66-fixture-b'],
        ),
      );

      await setShotViewport(tester, const Size(1440, 1200));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(Brightness.dark),
          home: const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(24),
              child: SingleChildScrollView(child: SyncPanel()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      final texts = visibleTexts(tester);

      // ★★ 防空转自检：树非空 + 含已知文案
      expect(texts.length, greaterThan(0), reason: '★★ 树为空 ⇒ 判据空转');
      expect(
        texts.any((s) => s.contains('凭据')),
        isTrue,
        reason: '★★ 必须含本面板的已知文案（证明渲染的是**这个**面板）。'
            '实际: $texts',
      );

      final offenders = texts.where((s) => s.contains('**')).toList();
      expect(
        offenders,
        isEmpty,
        reason: '★★★ Flutter 的 `Text` 不解析 markdown ⇒ `**` 会原样显示。\n'
            '要强调就用中文引号「」（仓库先例：lib/shell.dart:6955）。\n'
            '实测露馅的文案:\n${offenders.join('\n---\n')}',
      );
    });

    test('★★ 源码里没有 markdown 粗体（静态兜底）', () {
      final code = _codeOf('lib/ui/widgets/sync_panel.dart');
      final bolds = markdownBolds(code);
      expect(
        bolds,
        isEmpty,
        reason: '★★★ 用户可见字符串里不许有 markdown 粗体。\n'
            '实测命中:\n${bolds.join('\n---\n')}',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // ★ 路径 ②：danmaku_source_page.dart
  // ─────────────────────────────────────────────────────────────────

  group('★ danmaku_source_page.dart（report.remedy）', () {
    test('★★ 源码里没有 markdown 粗体（静态）', () {
      final code = _codeOf('lib/ui/settings/danmaku_source_page.dart');
      final bolds = markdownBolds(code);
      expect(
        bolds,
        isEmpty,
        reason: '★★★ remedy 是用户可见的（Text(report.remedy)）。\n'
            '实测命中:\n${bolds.join('\n---\n')}',
      );
    });

    testWidgets('★★ 探测报告的 remedy 渲染出来不含 markdown 粗体',
        (tester) async {
      /*
       * ★ 为什么**不**渲染整个 DanmakuSourcePage
       *
       * 那条路要真的探一次网络（`_probe()` → `Socket.connect`），
       * 在测试里既慢又不确定（还会往页面上塞各种别的报错文案）。
       *
       * ⇒ 改为**照页面的渲染方式**把 remedy 画出来：
       *   `danmaku_source_page.dart:728` 是 `Text(report.remedy, …)`
       * ★ 静态那条（上面）负责"源码里没有粗体"，
       *   这条负责"**画出来**的那句话没有粗体" —— 两条互补。
       */
      const report = DanmakuProbeReport(
        failure: DanmakuProbeFailure.serverError,
        url: 'https://example.invalid/api',
        detail: 'TCP 443 可以连上，但探测端点没有给出可用响应',
        remedy: '网络是通的（TCP 连得上）⇒ 这次的问题在「服务端」：'
            '它可能正在冷启动、或者这个实例的接口变了。'
            '等几秒重试，或换一个实例。',
      );

      await setShotViewport(tester, const Size(700, 500));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(Brightness.dark),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(report.remedy),
            ),
          ),
        ),
      );
      await tester.pump();

      final texts = visibleTexts(tester);
      expect(texts.length, greaterThan(0), reason: '★★ 树为空 ⇒ 判据空转');
      expect(texts.first, isNot(contains('**')),
          reason: '★★★ 用户可见文案里不许有 markdown 粗体。实际: "${texts.first}"');
      // ★ 而且强调确实改成了中文引号
      expect(texts.first, contains('「服务端」'),
          reason: '★ 强调应改成中文引号「」。实际: "${texts.first}"');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // ★ 路径 ③：danmaku.dart（DanmakuHint.text）
  // ─────────────────────────────────────────────────────────────────

  group('★ danmaku.dart（DanmakuHint.text）', () {
    test('★★★ 源码里没有 markdown 粗体（静态，且**不误伤**脱敏掩码）', () {
      final code = _codeOf('lib/core/danmaku.dart');
      final bolds = markdownBolds(code);
      expect(
        bolds,
        isEmpty,
        reason: '★★★ DanmakuHint.text 是用户可见的（Text(h.text)）。\n'
            '实测命中:\n${bolds.join('\n---\n')}',
      );
    });

    test('★★★ 三处脱敏掩码**原样保留**（判红就是泄露 AppId / 真实域名）', () {
      final code = _codeOf('lib/core/danmaku.dart');
      // ★ maskedAppId 的两种形态
      expect(code.contains("return '****';"), isTrue,
          reason: '★★★ 打码掩码 **** 必须保留 —— 改掉等于把 AppId 暴露给用户');
      expect(code.contains(r"${id.substring(0, 4)}****"), isTrue,
          reason: '★★★ 带前缀的打码掩码必须保留');
      // ★ URL 脱敏
      expect(code.contains("'***', ...segs.skip(1)"), isTrue,
          reason: '★★★ URL 脱敏 *** 必须保留 —— 改掉等于把真实域名暴露给用户');
    });

    testWidgets('★★ DanmakuHint 的 text 渲染出来不含 markdown 粗体',
        (tester) async {
      // ★ 直接验那个**渲染路径**：Text(h.text)
      //   （danmaku_settings_dialog.dart:4253 消费它）
      const h = DanmakuHint(
        title: '凭证没通过',
        text: '弹幕服务说这次请求的凭证不对（unauthorized）。'
            '本次请求用的是客户端「内置」的官方凭证；'
            '★ 若要换成你自己的，去弹幕设置的「凭证」一节填一对 AppId / AppSecret'
            '（构建期没注入内置凭证时，那一节就是「唯一」的补救入口）。',
        action: DanmakuHintAction(label: '去弹幕设置'),
      );

      await setShotViewport(tester, const Size(700, 500));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.themeFor(Brightness.dark),
          home: Scaffold(
            body: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(h.text),
            ),
          ),
        ),
      );
      await tester.pump();

      final texts = visibleTexts(tester);
      expect(texts.length, greaterThan(0), reason: '★★ 树为空 ⇒ 判据空转');
      expect(texts.first, isNot(contains('**')),
          reason: '★★★ 用户可见文案里不许有 markdown 粗体。实际: "${texts.first}"');
    });
  });
}
