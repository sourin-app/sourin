// ═══════════════════════════════════════════════════════════════════════
//  CS-1 门禁：用户可见文案里不许有 Markdown 星号
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守的是什么
//
// ```text
// Flutter 的 `Text` **不解析 markdown** ⇒ `**粗体**` 会**原样显示**在屏幕上。
// ★★ 本仓**几乎**没有 markdown 渲染器 —— 但**有一个**例外：
//   `lib/ui/widgets/release_notes.dart:98` 有一个真的
//   （`RegExp(r'\*\*(.+?)\*\*')` ⇒ TextSpan 粗体），
//   **只用于「发行说明」**。
// ★ 我第一版写的是「全仓没有」⇒ **被 Lead 复核推翻**（2026-10-19）。
//   我错在：用 `grep` 找 "markdown" 这个**单词**，而那个文件里
//   "markdown" 只出现在**注释**里 ⇒ grep 命中注释，我据此断定"没有"。
// ★★ 教训：「没有 X」比「有 X」**更需要证据** ——
//   证明「没有」要把所有可能的实现都排除掉，证明「有」只要一个实例。
//   ⇒ 判"有没有"要 grep **行为**（RegExp/TextSpan/调用点），不是 grep **名字**。
// ⇒ 凡是要显示给用户的 `**` 都是露馅。
// ```
//
// ★ 这是**真机截图**抓到的真缺陷（2026-10-19，第 66 轮 CS-1 收尾）：
//   截图上逐字是「这个备份文件会**含登录态**（2 个内容源）。」
//   「请输入 **导出这个包时** 设置的口令。」
//   而当时 CS-1 的 +27 条门禁**全绿** —— 它们断言的是**行为**
//   （弹框 / 报错 / 不写入任何凭据），**没有一条断言"文案长什么样"**。
//
// # ★★ 为什么判据要读**整棵树**而不是那几条常量
//
// ```text
// 只断言「:1474 那条常量不含 `**`」⇒ 改了这一处，:548 还露着，门禁照样绿
// ⇒ 这正是本轮这族的教训：**改一处漏一处**。
// ```
//
// ⇒ 本文件渲染**真面板**，把树上**所有**可见 `Text` 的内容读出来，
//   断言**整棵树**不含 `**`。
//
// # ★★★ 为什么要加"仪器自检"（Lead 明确要求）
//
// 本会话已出**三次恒真判据**（R7 非递归扫描面为空 / R8 读不挂订阅的 getter /
// 一条空转断言）⇒ 「不含 `**`」在**树为空**时也是真的。
// ⇒ 所以先断言：树的 Text **数量 > 0**，且**包含本面板的已知文案**。
//   没有这条，门禁退化成空转时**没有任何症状**。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/clip_download.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/backup_panel.dart';

import 'support/ui_shot.dart';

// ★ 唯一判别式（铁律 170）
import '_support/markdown_bold.dart';

/// ★ 装上假文件选择器 —— 让「导出」那条路**能走到弹框**，
///   否则知情提示与两个口令框根本不会渲染出来（= 树是空的）。
///
/// ⚠️ 假的**只**替掉「操作系统文件对话框」这一跳（file_selector 官方注入点），
///    产品代码一行没动。
class _FakeFileSelector extends FileSelectorPlatform {
  _FakeFileSelector({this.savePath});

  final String? savePath;

  @override
  Future<FileSaveLocation?> getSaveLocation({
    List<XTypeGroup>? acceptedTypeGroups,
    SaveDialogOptions options = const SaveDialogOptions(),
  }) async {
    final p = savePath;
    if (p == null) return null;
    return FileSaveLocation(p);
  }
}

/// 在 `runAsync` 里点一个 finder 并等它稳定
///
/// ★ 为什么必须 `runAsync`：`_exportConsent()` 会 `await` 一次
///   **真 FFI 调用**（`SourinApi.credentialsStatus()`）。
///   在 FakeAsync 区里创建的那个 Future 永远不会完成 ⇒
///   知情提示**永远不弹** ⇒ 后面所有断言都在空树上跑。
///   （`docs/AGENTS.md` §8「`pumpWidget` 后页面一直停在 loading」那条坑）
Future<void> tapAndSettle(
  WidgetTester tester,
  Finder finder, {
  int rounds = 30,
}) async {
  await tester.runAsync(() async {
    await tester.tap(finder);
    for (var i = 0; i < rounds; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
    }
  });
}

/// 把树上所有**可见** `Text` 的内容读出来
List<String> visibleTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty)
    .toList();

/// 渲染备份面板
///
/// ★★ 整个 `pumpWidget` **必须**放进 `tester.runAsync` ——
///   `BackupPanel.initState` 会调 `SourinApi.backupPreview()`（真 FFI）。
///   若在 FakeAsync 区里创建那个 Future，回调永远不来 ⇒
///   `_loading` 一直是 true ⇒ **导出按钮是禁用的**（`onPressed: null`）
///   ⇒ 点它**什么都不会发生** ⇒ 知情提示不弹 ⇒
///   后面每一条断言都在空树上跑（= 假绿）。
///   详见 `docs/AGENTS.md` §8「`pumpWidget` 后页面一直停在 loading」。
Future<void> pumpBackupPanel(WidgetTester tester) async {
  await setShotViewport(tester, const Size(1440, 1200));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.themeFor(Brightness.dark),
        home: const Scaffold(
          body: Padding(
            padding: EdgeInsets.all(24),
            child: SingleChildScrollView(child: BackupPanel()),
          ),
        ),
      ),
    );
    // ★ 等真 FFI 的 preview 回来（轮询到导出按钮可点为止）
    for (var i = 0; i < 80; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await tester.pump();
      final f = find.widgetWithText(FilledButton, '导出');
      if (f.evaluate().isNotEmpty &&
          tester.widget<FilledButton>(f).onPressed != null) {
        return;
      }
    }
  });
}

void main() {
  setUpAll(loadRealFonts);

  setUp(() {
    // ★ 铁律：渲染前把数据目录钉到临时目录（见 docs/AGENTS.md §8）
    ClipDownloader.debugSetDataDir(
      '${Directory.systemTemp.path}${Platform.pathSeparator}sourin-t66-cs1-md',
    );
  });

  tearDown(() {
    ClipDownloader.debugSetDataDir(null);
    SourinApi.installSyncDebugFetchers();
  });

  /// ★ 装上"本机有登录态"的状态
  ///
  /// ★★ **为什么必须装**：`_exportConsent()` 在 `providers == 0` 时
  ///   **直接返回**（不弹知情提示）—— 那是正确的产品行为
  ///   （本机没登录态 ⇒ 没什么好提示的）。
  ///   ⇒ 不装的话，知情提示与口令框**根本不会渲染**，
  ///   门禁就变成在断言一棵**空树**（假绿）。
  ///
  /// ⚠️ 注入的是**只读**接口（`credentialsStatus`），与本仓既有纪律一致。
  void installCredentials() {
    SourinApi.installSyncDebugFetchers(
      credentials: () async => const CredentialsStatus(
        enabled: true,
        passphraseSet: true,
        providers: 2,
        plaintextPasswordProviders: ['zz-t66-fixture-b'],
      ),
    );
  }

  // ─────────────────────────────────────────────────────────────────
  // ⓪ 仪器自检：门禁本身不是恒真
  // ─────────────────────────────────────────────────────────────────

  group('⓪ 仪器自检：判据有分辨率（树为空时必须红）', () {
    testWidgets('★ 空树上「不含 `**`」**照样为真** ⇒ 它是恒真判据',
        (tester) async {
      // ★ 故意**不**渲染面板 ⇒ 树上什么都没有
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      final texts = visibleTexts(tester);
      expect(texts, isEmpty,
          reason: '★ 前置：这棵树确实是空的（所以下面的自检有必要）');

      // ★★ 阳性对照：空树也满足"不含 `**`" ⇒ 光靠它挡不住任何东西
      expect(texts.every((s) => !s.contains('**')), isTrue,
          reason: '★★ 这条正是"光断言不含 `**`"的毛病：'
              '它在空树上也为真 ⇒ 所以门禁**必须**先断言"树非空"');
    });

    testWidgets('★★ 防空转的锚：空树上「树非空」这条**必须红**',
        (tester) async {
      // ★ 用 try/catch 把"应当失败"变成"可观测的读数" ——
      //   直接写 expect(greaterThan(0)) 会让**本用例**红，
      //   而那不是"证明判据会红"，是"我写错了"。
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump();

      final texts = visibleTexts(tester);
      var guardFailed = false;
      try {
        expect(texts.length, greaterThan(0),
            reason: '这条在空树上必须红 —— 它就是防"空转"的锚');
      } on TestFailure {
        guardFailed = true;
      }
      expect(guardFailed, isTrue,
          reason: '★★ 防空转的锚在空树上必须失败；'
              '若它通过了 ⇒ 锚写错了（恒真）');
    });

    testWidgets('★ 真面板渲染出来的树**非空**且含已知文案', (tester) async {
      await pumpBackupPanel(tester);
      final texts = visibleTexts(tester);

      expect(texts.length, greaterThan(0),
          reason: '★★ 树为空 ⇒ 后面那条"整棵树不含 `**`"就是空转');
      expect(
        texts.any((s) => s.contains('备份')),
        isTrue,
        reason: '★★ 必须包含本面板的已知文案（证明渲染的是**这个**面板，'
            '不是别的空壳）。实际: $texts',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // ★ 主体判据：整棵树不含 `**`
  // ─────────────────────────────────────────────────────────────────

  group('★★ 用户可见文案里不许有 Markdown 星号', () {
    testWidgets('★ 备份面板整棵树不含 `**`', (tester) async {
      await pumpBackupPanel(tester);
      final texts = visibleTexts(tester);

      // ★★ 先自检：树非空 + 含已知文案（否则这条是恒真）
      expect(texts.length, greaterThan(0),
          reason: '★★ 树为空 ⇒ 判据空转');
      expect(texts.any((s) => s.contains('备份')), isTrue,
          reason: '★★ 必须渲染的是**这个**面板');

      final offenders = texts.where((s) => s.contains('**')).toList();
      expect(
        offenders,
        isEmpty,
        reason: '★★★ Flutter 的 `Text` 不解析 markdown ⇒ `**` 会原样显示。\n'
            '本仓几乎没有 markdown 渲染器（唯一一个是发行说明那个）。\n'
            '要强调就用中文引号「」（仓库先例：lib/shell.dart:6955）。\n'
            '实测露馅的文案:\n${offenders.join('\n---\n')}',
      );
    });

    testWidgets('★★ 导出知情提示（含明文密码那段）不含 `**`', (tester) async {
      // ★ 走到知情提示：点「导出」⇒ 弹「这个备份文件含登录态」
      final out = '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}sourin-t66-cs1-md-out.zip';
      FileSelectorPlatform.instance = _FakeFileSelector(savePath: out);
      installCredentials();

      await pumpBackupPanel(tester);
      await tapAndSettle(tester, find.widgetWithText(FilledButton, '导出'));

      // ★ 前置：知情提示真的弹出来了
      expect(find.text('这个备份文件含登录态'), findsOneWidget,
          reason: '★★ 前置：知情提示没弹出来 ⇒ 后面断言的是空树');

      final texts = visibleTexts(tester);
      expect(texts.length, greaterThan(0), reason: '★★ 树为空 ⇒ 判据空转');
      // ★★ 知情提示正文（那段被 StringBuffer 拼出来的）
      final body = texts.firstWhere(
        (s) => s.contains('内容源'),
        orElse: () => throw StateError('没找到知情提示正文，实际: $texts'),
      );
      expect(body, isNot(contains('**')),
          reason: '★★★ 知情提示正文里不许有 markdown 星号。实际: "$body"');
      // ★ 强调改用中文引号了
      expect(body, contains('「'),
          reason: '★ 强调应该用中文引号「」（仓库先例）');
    });

    testWidgets('★★ 导入口令框不含 `**`', (tester) async {
      final out = '${Directory.systemTemp.path}'
          '${Platform.pathSeparator}sourin-t66-cs1-md-out.zip';
      FileSelectorPlatform.instance = _FakeFileSelector(savePath: out);
      installCredentials();

      await pumpBackupPanel(tester);
      await tapAndSettle(tester, find.widgetWithText(FilledButton, '导出'));
      await tapAndSettle(tester, find.text('设口令并加密'));

      // ★ 前置：口令框真的弹出来了
      expect(find.text('设置导出用口令'), findsOneWidget,
          reason: '★★ 前置：口令框没弹出来 ⇒ 后面断言的是空树');

      final texts = visibleTexts(tester);
      expect(texts.length, greaterThan(0), reason: '★★ 树为空 ⇒ 判据空转');
      final offenders = texts.where((s) => s.contains('**')).toList();
      expect(offenders, isEmpty,
          reason: '★★★ 导出口令框里不许有 markdown 星号。实际:\n'
              '${offenders.join('\n---\n')}');
      expect(
        texts.any((s) => s.contains('「不会」进包')),
        isTrue,
        reason: '★ 那句强调应改成中文引号。实际: $texts',
      );
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // ★★ 静态侧兜底：源码里的用户可见字符串不许带 `**`
  //
  // 为什么要这一层：widget 判据只覆盖**渲染到树上**的那些。
  // 而有些带 `**` 的文案是**运行时才拼出来**的（知情提示正文就是），
  // 静态这一层能在它还没被渲染到的那条路上也拦一道。
  // ─────────────────────────────────────────────────────────────────

  test('★★ 源码里的用户可见字符串不含 `**`（静态兜底）', () {
    final src = File('lib/ui/widgets/backup_panel.dart').readAsStringSync();
    // ★ 去掉注释行（注释里讲 markdown 的那些是**故意**的）
    final code = src
        .split('\n')
        .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('//') && !t.startsWith('*') && !t.startsWith('/*');
        })
        .join('\n');

    // ★ 找**字符串字面量**里的 markdown 粗体
    //
    // ★★ 2026-10-19（Lead）：改用 `_support/markdown_bold.dart` 的唯一判别式。
    //   朴素 `contains('**')` 会把脱敏掩码（`'****'`）判成 markdown，
    //   进而要求把掩码改成「」= 明文暴露打码后的 AppId。
    final offenders = <String>[];
    for (final m in RegExp(r"'([^'\\\n]*)'").allMatches(code)) {
      final lit = m.group(1) ?? '';
      if (isMarkdownBoldLiteral(lit)) offenders.add(lit);
    }
    expect(
      offenders,
      isEmpty,
      reason: '★★★ 用户可见字符串里不许有 markdown 星号：\n'
          '${offenders.join('\n---\n')}',
    );
  });
}
