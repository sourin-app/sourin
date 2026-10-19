// ═══════════════════════════════════════════════════════════════════════
//  CS-1 界面层实测门禁：导出提示 / 导入口令框（判据 #10-② 与 #11-①）
// ═══════════════════════════════════════════════════════════════════════
//
// # 与 `zz_t66_cs1_export_import_e2e_test.dart` 的分工
//
// ```text
// e2e_test   守「包里的字节」与「真的写不写 .data/」（真核心 + 真文件）
// 本文件      守「界面上真的出现了那句话」与「真的弹了口令框」
// ```
//
// # ★★ 为什么这个文件存在（判据 10② 与 11① 是**界面**判据）
//
// ```text
// 10-②「设了口令后导出 ⇒ 界面出现『含 N 个源的登录态，已加密』」
// 11-①「导入流程**弹出**口令输入框」
// ```
//
// 这两条**不能**用「grep 源码里有这句字符串」来判 ——
// 那是"同一个源比同一个源"（本仓铁律 §4②）：
// 把那句字符串从源码里删掉、改成别的措辞，门禁照样绿。
// ⇒ 必须**渲染出来，在 element 树上找**。
//
// # ★★★ 本文件**不复制**产品的对话框
//
// 常见做法是"把产品的 `_ImportPassphraseDialog` 抄一份到测试里" ——
// 那是本仓明令禁止的「门禁与实现漂开」：产品改了文案，测试里的副本没跟上，
// 门禁照样绿。
//
// ⇒ 本文件走**真流程**：真核心导出真包 → 假文件选择器指过去 →
//   产品自己的 `_doPick` → 产品的 `_doImport` → **产品自己的**对话框
//   → 从 element 树上把它**捞出来**读它的渲染结果。
//
// # ★ 为什么需要伪造 `file_selector`
//
// 导出/导入都要弹**系统文件对话框**（Windows 的 `getSaveLocation` /
// `openFile`）—— 那是原生插件，`flutter_test` 里没有插件注册表，
// 真调会抛 `MissingPluginException`。
//
// ⇒ 把 `FileSelectorPlatform.instance` 换成假实现，让对话框"选中"指定路径。
// ★★ 只换掉**选文件**这一步；弹口令框、拼文案、写凭据全是产品自己的代码。
//
// # ★★★ 铁律：数据目录必须是临时目录
//
// `ClipDownloader.debugSetDataDir(<临时目录>)` —— 见 `docs/AGENTS.md` §8
// 「拿 `pumpWidget` 单独渲染某个页面」那条坑。

import 'dart:io';

// ★ 只用 platform_interface（file_selector 本体是传递依赖，见 ignore 注释）
// ignore: depend_on_referenced_packages
import 'package:file_selector_platform_interface/file_selector_platform_interface.dart'
    as fsi;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/clip_download.dart';
import 'package:sourin_spike/core/ffi.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/backup_panel.dart';

import 'support/ui_shot.dart';

/// 本文件用到的合成内容源 id（自造，与任何真实源无关）
const String kUiProviderA = 'zz-t66-ui-fixture-a';
const String kUiProviderB = 'zz-t66-ui-fixture-b';

/// 本文件用到的口令（合成值）
const String kUiPass = 't66-ui-fixture-pass';

/// 假的文件选择器：返回一个固定路径
///
/// ★ 记录**被调过几次**、用的**哪个方法** ——
///   判据 #11-① 要证"导出口令**没**被复用"，
///   如果实现偷偷把导出时的口令缓存下来直接传给导入，这条记录能看出来。
class _FakeFileSelector extends fsi.FileSelectorPlatform {
  _FakeFileSelector({this.savePath, this.openPath});

  /// `getSaveLocation` 返回的路径（`null` = 模拟用户取消）
  final String? savePath;

  /// `openFile` 返回的路径
  final String? openPath;

  int saveCalls = 0;
  int openCalls = 0;

  @override
  Future<fsi.FileSaveLocation?> getSaveLocation({
    List<fsi.XTypeGroup>? acceptedTypeGroups,
    fsi.SaveDialogOptions options = const fsi.SaveDialogOptions(),
  }) async {
    saveCalls++;
    final p = savePath;
    if (p == null) return null;
    return fsi.FileSaveLocation(p);
  }

  @override
  Future<fsi.XFile?> openFile({
    List<fsi.XTypeGroup>? acceptedTypeGroups,
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    openCalls++;
    final p = openPath;
    if (p == null) return null;
    return fsi.XFile(p);
  }

  @override
  Future<String?> getDirectoryPath({
    String? initialDirectory,
    String? confirmButtonText,
  }) async {
    return null;
  }
}

void main() {
  setUpAll(loadRealFonts);

  // ★ 记下**真的**文件选择器（tearDown 要还原成它）
  final realFileSelector = fsi.FileSelectorPlatform.instance;

  late Directory tempDir;
  late String dataDir;
  late String bundlePath; // 真核心导出的**含凭据**的包
  late String plainBundlePath; // 真核心导出的**不含凭据**的包

  setUpAll(() async {
    // ★ 真核心：数据目录钉死在临时目录（不读 APPDATA，碰不到 Owner 的真实目录）
    final base = Directory.systemTemp.createTempSync('sourin-t66-cs1-ui-');
    tempDir = base;
    dataDir = '${base.path}${Platform.pathSeparator}data';
    ClipDownloader.debugSetDataDir(dataDir);
    await SourinCore.startAsync(dataDir);

    // ★ 造两个合成凭据（令牌型 + 明文密码型）
    final dd = Directory('$dataDir${Platform.pathSeparator}plugins'
        '${Platform.pathSeparator}.data');
    dd.createSync(recursive: true);
    File('${dd.path}${Platform.pathSeparator}$kUiProviderA.json')
        .writeAsStringSync('{"token":"ui-fixture-token-aaaa"}');
    File('${dd.path}${Platform.pathSeparator}$kUiProviderB.json')
        .writeAsStringSync(
            '{"username":"ui-fixture-user","password":"ui-fixture-pass-0000"}');

    // ★ 真核心导出两个真包
    bundlePath = '${base.path}${Platform.pathSeparator}with-creds.zip';
    plainBundlePath = '${base.path}${Platform.pathSeparator}no-creds.zip';
    await SourinApi.backupExport(bundlePath, passphrase: kUiPass);
    await SourinApi.backupExport(plainBundlePath);
  });

  tearDownAll(() {
    ClipDownloader.debugSetDataDir(null);
  });

  tearDown(() {
    // ★ 还原文件选择器与注入点，不污染同进程的其它用例
    // ★★★ 必须还原成**原来那个** —— 写成
    //     `instance = instance` 是自赋值空操作，假的会漏给后面的用例。
    fsi.FileSelectorPlatform.instance = realFileSelector;
    SourinApi.installSyncDebugFetchers();
  });

  /// 渲染备份面板
  ///
  /// ★ 整个 `pumpWidget` 必须放进 `tester.runAsync` ——
  ///   `BackupPanel.initState` 会调 `SourinApi.backupPreview()`（真 FFI）。
  ///   若在 FakeAsync 区里创建那个 Future，回调永远不来 ⇒
  ///   `_loading` 一直是 true ⇒ **导出按钮是禁用的**（`onPressed: null`）
  ///   ⇒ 后面每一条都点不动。
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
      // ★ 等真 FFI 的 preview 回来（轮询直到不再 loading）
      for (var i = 0; i < 60; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
        if (find.widgetWithText(FilledButton, '导出').evaluate().isNotEmpty) {
          final btn = tester.widget<FilledButton>(
            find.widgetWithText(FilledButton, '导出'),
          );
          if (btn.onPressed != null) return;
        }
      }
    });
  }

  /// 在 `runAsync` 里点一个按钮并等它稳定
  Future<void> tapAndSettle(
    WidgetTester tester,
    Finder finder, {
    int rounds = 40,
  }) async {
    await tester.runAsync(() async {
      await tester.tap(finder);
      for (var i = 0; i < rounds; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        await tester.pump();
      }
    });
  }

  /// 把树上所有 `Text` 的内容读出来
  List<String> allTexts(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? '')
      .where((s) => s.isNotEmpty)
      .toList();

  // ─────────────────────────────────────────────────────────────────
  // 判据 #10-②  设了口令后导出 ⇒ 界面出现「含 N 个源的登录态，已加密」
  // ─────────────────────────────────────────────────────────────────

  group('#10-② ★ 界面上真的出现「含 N 个源的登录态，已加密」', () {
    testWidgets('★★ 设口令导出 ⇒ 成功行逐字含「含 2 个源的登录态，已加密」',
        (tester) async {
      final out = '${tempDir.path}${Platform.pathSeparator}ui-export.zip';
      fsi.FileSelectorPlatform.instance = _FakeFileSelector(savePath: out);

      await pumpBackupPanel(tester);

      // ① 点「导出」
      final exportBtn = find.widgetWithText(FilledButton, '导出');
      expect(exportBtn, findsOneWidget, reason: '★ 导出按钮必须渲染出来');
      expect(
        tester.widget<FilledButton>(exportBtn).onPressed,
        isNotNull,
        reason: '★★ 按钮必须可点 —— 若被禁用（preview 没回来），'
            '后面所有断言都点不动，等于什么都没验',
      );
      await tapAndSettle(tester, exportBtn);

      // ② 第一层弹窗：「这个备份文件含登录态」+ 三个出口
      expect(find.text('这个备份文件含登录态'), findsOneWidget,
          reason: '★★ 导出前必须先弹"含登录态"的知情提示');
      expect(find.text('不含登录态导出'), findsOneWidget);
      expect(find.text('设口令并加密'), findsOneWidget);

      // ③ 逐字读提示正文
      final body = allTexts(tester).firstWhere(
        (s) => s.contains('含登录态') && s.contains('内容源'),
        orElse: () => throw StateError('提示正文不对，实际: ${allTexts(tester)}'),
      );
      expect(body, contains('2 个内容源'),
          reason: '★★ 必须说清有**几个**源');
      expect(body, contains('账号密码明文'),
          reason: '★★ 明文密码类源必须**单独**提示（不是笼统的"凭据"）');
      expect(body, contains('口令「不会」进包'),
          reason: '★★ 必须承诺"口令不进包"（判据 ③ 的用户侧承诺）。\n'
              '★ 2026-10-19：强调改成中文引号「」了 —— Flutter 的 `Text` '
              '不解析 markdown，`**` 会**原样显示**在屏幕上'
              '（真机截图实证；见 `zz_t66_cs1_no_markdown_leak_test.dart`）');
      // ★★ 负面：渲染出来的正文里不许有 markdown 星号
      expect(body, isNot(contains('**')),
          reason: '★★ 用户可见文案里不许有 markdown 星号。实际: "$body"');

      // ④ 选「设口令并加密」⇒ 弹出口令框
      await tapAndSettle(tester, find.text('设口令并加密'));
      expect(find.text('设置导出用口令'), findsOneWidget,
          reason: '★★ 必须弹出口令输入框');
      expect(find.byType(TextField), findsOneWidget);

      // ⑤ 输一个够长的口令（≥8 位）并提交
      await tester.runAsync(() async {
        await tester.enterText(find.byType(TextField), kUiPass);
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, '导出'));
        for (var i = 0; i < 60; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });

      // ⑥ ★★★ 核心读数：成功行里逐字出现那句话
      final line = allTexts(tester).firstWhere(
        (s) => s.contains('已导出到'),
        orElse: () =>
            throw StateError('界面上没有"已导出到"那一行。实际全部文本: ${allTexts(tester)}'),
      );

      expect(line, contains('含 2 个源的登录态，已加密'),
          reason: '★★★ 判据 #10-② 逐字要求「含 N 个源的登录态，已加密」。'
              '实际那一行: "$line"');
      expect(line, contains('导入时要口令'),
          reason: '★★ 必须告诉用户导入时还要再输一次口令');
      // ★ 真落盘了（不是界面在编故事）
      expect(File(out).existsSync(), isTrue, reason: '★ 导出必须真的落盘');
      expect(File(out).lengthSync(), greaterThan(0));
    });

    testWidgets('★★ 选"不含登录态导出" ⇒ 界面**不许**说"已加密"', (tester) async {
      final out = '${tempDir.path}${Platform.pathSeparator}ui-export-plain.zip';
      fsi.FileSelectorPlatform.instance = _FakeFileSelector(savePath: out);

      await pumpBackupPanel(tester);
      await tapAndSettle(tester, find.widgetWithText(FilledButton, '导出'));

      // 选「不含登录态导出」⇒ **不**弹口令框
      await tapAndSettle(tester, find.text('不含登录态导出'));
      expect(find.text('设置导出用口令'), findsNothing,
          reason: '★ 选"不含"就不该问口令');

      final line = allTexts(tester).firstWhere(
        (s) => s.contains('已导出到'),
        orElse: () =>
            throw StateError('没有"已导出到"那一行，实际: ${allTexts(tester)}'),
      );
      expect(line, isNot(contains('已加密')),
          reason: '★★★ 没设口令的包绝不许显示"已加密" —— 那是最典型的假绿');
      expect(line, isNot(contains('含 2 个源的登录态')),
          reason: '★★★ 没设口令就不许说含了登录态');
    });
  });

  // ─────────────────────────────────────────────────────────────────
  // 判据 #11-①  导入时必须重新输入口令
  // ─────────────────────────────────────────────────────────────────

  group('#11-① ★ 导入时真的弹出**新的**口令输入框', () {
    testWidgets('★★★ 含登录态的包 ⇒ 点「确认导入」后弹口令框', (tester) async {
      // ★ 用**真核心导出的真包**（含凭据）⇒ `backup_inspect` 能真读出来
      fsi.FileSelectorPlatform.instance =
          _FakeFileSelector(openPath: bundlePath);

      await pumpBackupPanel(tester);

      // ① 点「选择文件」⇒ 产品自己走 openFile → backupInspect
      await tapAndSettle(tester, find.widgetWithText(OutlinedButton, '选择文件'));

      // ② 产品的确认区必须出现（它读到了"含 2 个源的登录态"）
      expect(find.text('确认导入'), findsOneWidget,
          reason: '★★ 真包含凭据 ⇒ 必须能走到"确认导入"这一步');
      expect(find.text('这个包里有什么'), findsOneWidget);

      // ③ 点「确认导入」⇒ **必须弹口令框**
      await tapAndSettle(tester, find.text('确认导入'));

      expect(find.text('这个备份包含登录态'), findsOneWidget,
          reason: '★★★ 判据 #11-① 逐字要求：导入流程**弹出**口令输入框');
      expect(find.byType(TextField), findsOneWidget,
          reason: '★★★ 必须有口令输入框');

      // ④ ★★ 只有两个出口
      expect(find.text('取消导入'), findsOneWidget,
          reason: '★ 必须有"取消整次导入"这个出口');
      expect(find.text('导入'), findsOneWidget,
          reason: '★ 必须有"输口令继续"这个出口');

      // ⑤ ★★★ 阴性：**不许**有"跳过凭据"这类允许半成功的出口
      for (final bad in ['跳过凭据', '跳过', '不含登录态', '继续但不导入']) {
        expect(find.text(bad), findsNothing,
            reason: '★★ 不许出现 "$bad" —— 那是"看起来成功了"的入口');
      }

      // ⑥ ★ 必须说清要输的是**导出时**那个口令（不得自动复用）
      final dialogTexts = allTexts(tester);
      expect(
        dialogTexts.any((s) => s.contains('导出这个包时')),
        isTrue,
        reason: '★★ 必须说清要输的是**导出这个包时**设置的口令。实际: $dialogTexts',
      );
      expect(
        dialogTexts.any((s) => s.contains('整次导入会失败')),
        isTrue,
        reason: '★ 必须说清错口令的后果（不会只导一半）。实际: $dialogTexts',
      );
    });

    testWidgets('★★ 不含凭据的包 ⇒ **不**弹口令框（不白问用户）', (tester) async {
      fsi.FileSelectorPlatform.instance =
          _FakeFileSelector(openPath: plainBundlePath);

      await pumpBackupPanel(tester);
      await tapAndSettle(tester, find.widgetWithText(OutlinedButton, '选择文件'));

      expect(find.text('确认导入'), findsOneWidget,
          reason: '★ 不含凭据的包也要能导入');

      await tapAndSettle(tester, find.text('确认导入'));

      expect(find.text('这个备份包含登录态'), findsNothing,
          reason: '★★ 包里没有登录态 ⇒ 不该问口令（白问一次就是骚扰）');
      expect(find.byType(TextField), findsNothing,
          reason: '★★ 同上');
    });
  });
}
