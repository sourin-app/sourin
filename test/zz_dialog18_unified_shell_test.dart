// ═══════════════════════════════════════════════════════════════════════
//  总计划第 18 项 · 弹窗外壳统一（12 处 AlertDialog → AppGlassDialog）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
// ```text
// ① 仪器自检（行为取证）：统一外壳 AppGlassDialog 的内容区**零 Material 宿主**
//    ⇒ 哪些控件放进去会抛？必须真跑一遍拿到名单，不能靠注释里的转述
//    （既有登记里「机制②」就是这么说的，但那是别的文件里的结论）。
// ② 逐处行为测试：打开 → 断言标题/内容 → 点确认/取消 → 断言**返回值与副作用**。
//    走真实组件路径（真挂载宿主 → 真走 showAppDialog 路由 → 真点按钮）。
// ③ 结构断言：这 6 个文件里不许再有裸 `AlertDialog(`。
// ```
//
// ⚠️ 所有断言都读**渲染树/返回值**，不读源码字符串
//    （本仓记过「源码字符串当判据 = 假绿」的教训）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/design/widgets/app_glass_dialog.dart';
import 'package:sourin_spike/design/widgets/app_text_button.dart';
import 'package:sourin_spike/design/icons/app_icons.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings/theme_page.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/theme/theme_pack.dart';
import 'package:sourin_spike/ui/widgets/backup_panel.dart';
import 'package:sourin_spike/ui/widgets/download_panel.dart';
import 'package:sourin_spike/ui/widgets/overlay_motion.dart';
import 'package:sourin_spike/ui/widgets/tvbox_source_panel.dart';

/// 在**真实 showAppDialog 路由**里挂一个 AppGlassDialog，返回该路由的 Future。
///
/// ★ 为什么必须走真路由：`AppGlassDialog` 在 `showDialog` 的**紧约束**下
///   会先被 `Align` 松掉约束才让 maxWidth 生效（见组件里 P1 的注释）。
///   在 `MaterialApp(home: Scaffold(body: Center(...)))` 里直接摆一个，
///   Scaffold 会**白送 Material 祖先** ⇒ 探针会得出"TextField 能用"的**假结论**
///   （本仓 R4 那条改判记录就是因为这个仪器问题判错过一次）。
Future<T?> openGlass<T>(
  WidgetTester t,
  GlobalKey<NavigatorState> key,
  Widget content, {
  Widget? actions,
  String title = '探针',
}) {
  return showAppDialog<T>(
    context: key.currentContext!,
    builder: (ctx) => AppGlassDialog(
      title: title,
      content: content,
      actions: actions ?? AppTextButton(onPressed: () {}, child: const Text('好')),
    ),
  );
}

Future<GlobalKey<NavigatorState>> mountHost(WidgetTester t) async {
  final key = GlobalKey<NavigatorState>();
  await t.pumpWidget(MaterialApp(
    navigatorKey: key,
    theme: AppTheme.themeFor(Brightness.dark),
    themeAnimationDuration: Duration.zero,
    home: const SizedBox(),
  ));
  return key;
}

/// 打开 → pump 到动画结束 → 收异常。返回 null 表示**没有异常**。
Future<Object?> probeContent(
  WidgetTester t,
  Widget content,
) async {
  final key = await mountHost(t);
  openGlass<void>(t, key, content);
  await t.pump();
  await t.pump(const Duration(milliseconds: 900));
  final ex = t.takeException();
  // 关掉，避免影响下一个探针
  await t.pumpWidget(const SizedBox());
  await t.pump();
  return ex;
}

/// 核心是否可用。
///
/// CI 的顺序是「全量测试 → 构建发布版」⇒ 测试阶段没有 `sourin_core.dll`
/// （build.yml 的注释记着这个坑）。那两项用例要驱动真实文件 I/O 与口令框，
/// 缺件时前置不成立 ⇒ 明确 skip，而不是让断言红（那不是缺陷，是缺件）。

/// 「缺件」还是「真失败」？—— 只有前者允许把用例降级成 skip
///
/// # 为什么必须分类（反假绿审计 B2/B3，task-15）
///
/// 改前是 `catch (_) { coreReady = false; }`：**任何**启动异常都被当成
/// 「这台机器没有 sourin_core.dll」⇒ 真缺陷（导出符号改名、bootstrap 报错、
/// FFI 契约破坏）会变成一行 skip —— 也就是**红变成不红**，比不做门禁更糟。
///
/// 判据只认**动态库加载失败**这一类：
/// ```text
/// ArgumentError: Failed to load dynamic library …（dlopen 失败）
/// undefined symbol / cannot open shared object / error code: 126 / 找不到指定的模块
/// ```
/// 其余一切（`SourinCoreException` = 核心自己报的错、IO 错误、断言失败）
/// **必须 fail** —— 那是"核心坏了"，不是"这台机器缺件"。
bool _isLibMissing(Object e) {
  final s = e.toString().toLowerCase();
  const marks = <String>[
    'failed to load dynamic library',
    'cannot open shared object',
    'the specified module could not be found',
    '找不到指定的模块',
    'undefined symbol',
    'error code: 126',
  ];
  return marks.any(s.contains);
}

bool _coreReady = false;

void main() {
  setUpAll(() async {
    try {
      final dir = await Directory.systemTemp.createTemp('sourin_d18_core_');
      final r = await SourinCore.startAsync(dir.path);
      if (r['ok'] != true) {
        fail('核心启动返回 ok!=true（不是缺件）：$r');
      }
      _coreReady = true;
    } catch (e, st) {
      // ★ 只有动态库加载失败才允许 skip（见 _isLibMissing）
      if (!_isLibMissing(e)) {
        fail('核心启动失败（**不是**缺件 ⇒ 不许降级成 skip）：$e\n$st');
      }
      _coreReady = false;
      // ignore: avoid_print
      print('DIALOG18|lib_missing ⇒ 依赖真实核心的 2 项将 skip：$e');
    }
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ① 仪器自检：外壳内容区的 Material 依赖名单（行为取证）
  // ═══════════════════════════════════════════════════════════════════
  group('① 外壳内容区 Material 依赖探针', () {
    testWidgets('裸 TextField 在外壳里**抛**（取证：机制② 成立）', (t) async {
      final ex = await probeContent(t, const TextField());
      expect(ex, isNotNull,
          reason: '★ 实测：AppGlassDialog 内容区放裸 TextField 会抛 —— '
              '这正是登记里「机制②」的依据。若这里变成 null（不抛了），'
              '说明组件补了 Material 宿主，本文件的 _ShellBody 包装可以简化。');
      expect('$ex', contains('Material'),
          reason: '★ 异常内容必须指向 Material 祖先缺失（实测原文：'
              '"No Material widget found. TextField widgets require a '
              'Material widget ancestor"）');
    });

    testWidgets('TextField 包一层 Material(transparency) ⇒ 不抛（这就是补法）',
        (t) async {
      final ex = await probeContent(
        t,
        const Material(type: MaterialType.transparency, child: TextField()),
      );
      expect(ex, isNull,
          reason: '★ 实测：content 自带透明 Material 宿主后 TextField 可用 ⇒ '
              '迁移时在**调用点**补宿主是有效修法（不必改共享组件）。');
    });

    testWidgets('裸 ListTile 在外壳里**抛**（取证：机制② 对 ListTile 也成立）',
        (t) async {
      final ex = await probeContent(t, const ListTile(title: Text('一行')));
      expect(ex, isNotNull,
          reason: '★ _OrderDialog 的 content 每行都是 ListTile（内部 InkWell）'
              '⇒ 不补宿主就会「弹窗根本打不开」（R4 改判记录里的实测结论）。');
      expect('$ex', contains('Material'));
    });

    testWidgets('Material 按钮在外壳里**不抛**（取证：按钮自带墨水宿主）', (t) async {
      final ex = await probeContent(
        t,
        Column(children: [
          FilledButton(onPressed: () {}, child: const Text('主按钮')),
          FilledButton.tonal(onPressed: () {}, child: const Text('次按钮')),
          FilledButton.icon(
              onPressed: () {}, icon: const Icon(Icons.add), label: const Text('带图标')),
          OutlinedButton(onPressed: () {}, child: const Text('描边')),
          TextButton(onPressed: () {}, child: const Text('文字按钮')),
        ]),
      );
      expect(ex, isNull,
          reason: '★ 实测：三种 Material 按钮在外壳内容区**都可用** ⇒ '
              '只含按钮的内容（如主题大预览里的按钮行）不需要额外补宿主。');
    });

    testWidgets('Switch / SwitchListTile 在外壳里**抛**（实测：报 _MaterialSwitch）',
        (t) async {
      final ex = await probeContent(t, const Switch(value: true, onChanged: _noop));
      expect(ex, isNotNull,
          reason: '★ 实测异常原文：「_MaterialSwitch widgets require a Material '
              'widget ancestor」⇒ 主题大预览（含两个 Switch）与 tvbox 的'
              '「同时加入新增站点」开关行都**必须**补透明 Material 宿主。');
      expect('$ex', contains('_MaterialSwitch'));

      final ex2 = await probeContent(
        t,
        SwitchListTile(value: true, onChanged: _noop, title: const Text('一行开关')),
      );
      expect(ex2, isNotNull, reason: '★ SwitchListTile 同理（内含 Switch）');
    });

    testWidgets('InkWell 在外壳里**抛**（实测：_InkResponseStateWidget）', (t) async {
      final ex = await probeContent(
        t,
        InkWell(onTap: () {}, child: const Padding(
          padding: EdgeInsets.all(8),
          child: Text('可点行'),
        )),
      );
      expect(ex, isNotNull,
          reason: '★ 实测异常原文：「_InkResponseStateWidget widgets require a '
              'Material widget ancestor」⇒ 凡内容里带 InkWell 的（可点行 / '
              '手势药丸 / 多仓子仓列表）都必须补透明 Material 宿主，'
              '否则**弹窗根本打不开**。');
      expect('$ex', contains('_InkResponseStateWidget'));
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ② 逐处行为测试（真实组件路径）
  // ═══════════════════════════════════════════════════════════════════
  //
  // 判据形态：真挂载宿主/真调生产入口 → 真走 `showAppDialog` 路由 → 真点按钮
  //          → 断言**返回值语义**与**副作用**（不读源码字符串）。
  //
  // 覆盖分工（13 处迁移）：
  //   · 本组直接驱动（8 处）：
  //       tvbox「订阅更新」、download「删除整部剧」、backup「含登录态」+「导出用口令」、
  //       theme「单套大预览」+「粘贴主题包 JSON」、settings「_promptText（安装 JS 插件）」
  //   · 由既有**真路径**测试驱动（5 处，本项只换型定位件、不重复造轮子）：
  //       sync「配置云盘（WebDAV）」→ t91_sync_presets_test（挂 SyncPanel 真点，
  //         断言"有占位符不关窗"与"取消 pop(null)"）
  //       backup「导入口令」→ zz_t66_cs1_export_import_e2e_test（真导入流程）
  //       theme「预览」的兄弟路径（卡片本体点击）→ theme_pack_test / t31b
  //       settings「插件更新」「配置插件」「调整内容源顺序」→ 需要真 provider/插件数据
  //         （宿主 SettingsPage 的这三个入口挂在"已安装插件"卡片体内），
  //         由 ③ 组的结构断言 + 既有 plugin_update_ui_test / provider 系列覆盖。
  group('② 逐处行为（真路由 + 真按钮）', () {
    setUp(() async {
      final tmp = await Directory.systemTemp.createTemp('sourin_d18');
      await UiPrefs.load(tmp.path);
    });

    // ── ⑫ tvbox「订阅更新」（content 含 TextField ⇒ 机制② 的就地宿主）──
    testWidgets('⑫ tvbox 订阅更新：打开 → 读标题/内容 → 关闭 ⇒ 返回 false', (t) async {
      final key = await mountHost(t);
      // 真入口：TvboxUpdateDialog.show（内部就是 showAppDialog<bool> + r ?? false）
      final fut = TvboxUpdateDialog.show(
        key.currentContext!,
        id: 'tv-fixture',
        name: '测试源',
      );
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));

      expect(t.takeException(), isNull,
          reason: '★★ 打开就抛 ⇒ 内容里的 TextField 没拿到 Material 宿主。'
              '第 18 项在**调用点**补了 `MaterialType.transparency`（不改共享组件）。');
      expect(find.byType(AppGlassDialog), findsOneWidget,
          reason: '★ 必须走统一外壳（改前是 Material 的 AlertDialog）');
      expect(find.text('订阅更新 · 测试源'), findsOneWidget,
          reason: '★ 标题仍然逐字渲染出来（改前是 Row+Flexible+ellipsis 的自绘标题）');
      expect(find.text('订阅链接'), findsOneWidget, reason: '★ 内容确实渲染（不是空白壳）');
      expect(find.byType(TextField), findsWidgets,
          reason: '★★ 输入框必须**真的建出来** —— 缺 Material 宿主时它连建都不建');

      await t.tap(find.text('关闭'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(await fut, isFalse,
          reason: '★★ 返回值语义：`show()` 里 `return r ?? false` ⇒ 没改过时关闭 = false');
      expect(find.byType(AppGlassDialog), findsNothing, reason: '★ 关闭后必须关掉');
    });

    // ── ⑬ download「删除整部剧」（content 是左对齐清单 + 内联红色警示）──
    testWidgets('⑬ download 删除整部剧：真点入口 → 左对齐+红色警示 → 取消不删', (t) async {
      DownloadQueue.debugReset();
      addTearDown(DownloadQueue.debugReset);
      DownloadQueue.enqueue(_task('第01集', DownloadState.done));
      DownloadQueue.enqueue(_task('第02集', DownloadState.done));

      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: Scaffold(
          body: SizedBox(
            width: 420,
            height: 700,
            child: DownloadPanel(
              title: '探针剧',
              callbacks: DownloadPanelCallbacks(onPlay: (_) {}),
            ),
          ),
        ),
      ));
      await t.pump();
      final diag = await t.runAsync(() async {
        final p = await DownloadQueue.previewRemoveWork('探针剧');
        return 'queue=${DownloadQueue.tasks.value.length} '
            'files=${p.fileCount} eps=${p.episodeCount}';
      });
      debugPrint('DIAG $diag');
      final btn = find.byTooltip('删除整部剧的下载');
      debugPrint('DIAG btnFound=${btn.evaluate().length} '
          'rect=${btn.evaluate().isEmpty ? 'n/a' : t.getRect(btn)}');
      await t.tap(btn);
      // ★ 关键：`_confirmRemoveWork` 内部要先 `await DownloadQueue.previewRemoveWork()`
      //   （真实文件系统 I/O），`testWidgets` 的 fake-async 时钟不会推进它。
      //   必须用 `runAsync` 让真实 I/O 落地，再把结果 pump 回 UI ——
      //   否则弹窗永远不会被建出来，断言会误报"没走统一外壳"。
      for (var i = 0; i < 10; i++) {
        await t.runAsync(() => Future<void>.delayed(
              const Duration(milliseconds: 50),
            ));
        await t.pump();
        if (find.byType(AppGlassDialog).evaluate().isNotEmpty) break;
      }
      await t.pump(const Duration(milliseconds: 900));

      expect(t.takeException(), isNull, reason: '★ 打开不许抛');
      expect(find.byType(AppGlassDialog), findsOneWidget,
          reason: '★ 必须走统一外壳（改前是 Material 的 AlertDialog）');
      expect(find.text('删除整部剧的下载？'), findsOneWidget, reason: '★ 标题');
      expect(find.text('此操作不可恢复。'), findsOneWidget, reason: '★ 内容渲染');
      expect(find.text('全部删除'), findsOneWidget, reason: '★ 按钮文案与改前一致');

      // 机制⑤ 的**视觉语义**必须显式传：警示色不能被外壳 DefaultTextStyle 冲掉
      final warn = t.widget<Text>(find.text('此操作不可恢复。'));
      // ★ `Colors.red` 的静态类型是 `MaterialColor`（其 primary value 才是 Color），
      //   直接与 `Color(0xFFFF0000)` 比较会因运行时类型不同而失败。
      //   这里比**色值**，不比类型：既接受 MaterialColor 也接受裸 Color，
      //   同时仍能真正变红（改成别的颜色就不等于 0xFFFF0000）。
      final warnColor = warn.style?.color;
      expect(warnColor, isNotNull, reason: '★★ 警示色必须存在');
      // 实测 `Colors.red` = MaterialColor(0xFFF44336)，不是纯红 0xFFFF0000。
      // 按**真实色值**钉住，既能防"被外壳样式冲掉"，也不会因写成纯红而恒红。
      expect(warnColor!.toARGB32(), Colors.red.toARGB32(),
          reason: '★★ 内联 `TextStyle(color: Colors.red)` 必须仍然生效'
              '（inherit=true ⇒ 与外壳默认样式 merge，显式色胜出）');
      // 左对齐必须显式指定（外壳内容区 DefaultTextStyle 写死 textAlign: center）
      final leftAligned = t.widgetList<DefaultTextStyle>(find.descendant(
        of: find.byType(AppGlassDialog),
        matching: find.byType(DefaultTextStyle),
      ));
      expect(leftAligned.any((d) => d.textAlign == TextAlign.left), isTrue,
          reason: '★★ 必须显式给出左对齐 —— 否则这份清单会被外壳逐行居中'
              '（改前是 Column(crossAxisAlignment.start) 的左对齐清单）');

      // 取消 ⇒ pop(false)（不是 null）⇒ `ok != true` 提前 return ⇒ 队列一条都不许少
      // ★ 用真实的只读快照 `DownloadQueue.tasks.value`（该类的公开读入口），
      //   不是 `items`（不存在）。tasks 是 ValueNotifier，.value 即当前队列。
      final before = DownloadQueue.tasks.value.length;
      await t.tap(find.text('取消'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.byType(AppGlassDialog), findsNothing, reason: '★ 取消应关掉');
      expect(DownloadQueue.tasks.value.length, before,
          reason: '★★ 取消**不能**触发删除（改前取消 pop(false)，判据 `ok != true` 一字未改）');
    });

    // ── ③ backup「含登录态」（三键 + 多行左对齐清单）与「导出用口令」──
    testWidgets('③ backup 含登录态提示：三键语义 + 左对齐 + 走入口令框', (t) async {
      if (!_coreReady) {
        // 环境缺件 ⇒ 允许 skip；点名缺件与替代覆盖（B1 分类表见文件头）
        markTestSkipped('环境缺件：缺 sourin_core.dll（CI 在构建前跑测试）；'
            '替代覆盖：⑬ download 同形态断言 + Rust 端 backup 单测');
        return;
      }
      // 只桩掉"本机有 2 个源、其中 1 个明文存密码"，不桩导出/选择器
      SourinApi.debugCredentialsStatusFetcher = () async => const CredentialsStatus(
            providers: 2,
            plaintextPasswordProviders: ['测试源'],
          );
      addTearDown(() => SourinApi.debugCredentialsStatusFetcher = null);

      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: const Scaffold(body: SingleChildScrollView(child: BackupPanel())),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));

      /*
       * ★★ 先等按钮**可点**再点（B1 修复的必要一环，2026-10-25）
       *
       * `BackupPanel` 的导出按钮是
       * `onPressed: (_busy.isNotEmpty || _loading) ? null : _doExport`，
       * 而 `_loading` 在 `_loadPreview()`（真核心 `backup_preview`）期间为 true。
       * 原来直接 `t.tap(...)`：按钮若还没启用，tap **静默什么都没发生** ⇒
       * 弹窗当然不出现 ⇒ 旧代码就 skip 掉，看起来"环境不具备"。实际是
       * **测试自己没等前置状态**。这属于「用例自身前置状态缺失 ⇒ 必须 fail」那一类。
       */
      final exportBtn = find.widgetWithText(FilledButton, '导出');
      expect(exportBtn, findsOneWidget, reason: '★ 导出按钮必须渲染出来');
      for (var i = 0; i < 20; i++) {
        await t.runAsync(() => Future<void>.delayed(
              const Duration(milliseconds: 50),
            ));
        await t.pump();
        if (t.widget<FilledButton>(exportBtn).onPressed != null) break;
      }
      expect(
        t.widget<FilledButton>(exportBtn).onPressed,
        isNotNull,
        reason: '★★★ 按钮必须可点（_loading/_busy 期间为 null）—— '
            '按钮不可点时点它等于什么都没驱动，后面的断言就没有意义',
      );
      await t.tap(exportBtn);
      // ★ 同 ⑬：导出前要 await 真实的凭证/文件检查（fake-async 不推进），
      //   必须 runAsync 轮询到弹窗真的建出来，否则会误报"标题不存在"。
      for (var i = 0; i < 12; i++) {
        await t.runAsync(() => Future<void>.delayed(
              const Duration(milliseconds: 50),
            ));
        await t.pump();
        if (find.text('这个备份文件含登录态').evaluate().isNotEmpty) break;
      }
      await t.pump(const Duration(milliseconds: 900));

      /*
       * ⚠️ 覆盖边界（如实标注，不造假绿）：
       * 「导出」按钮 → `_export()` 需要真实的凭证状态 + 文件系统写入，
       * 在空数据 + fake-async 环境下不保证到达「这个备份文件含登录态」提示。
       * 入口不可达时明确跳过并说明，而不是把断言弱化成"存在即通过"。
       * 该弹窗的机制⑤（多行左对齐清单）已由 ⑬ download 的同形态断言
       * （显式 `textAlign: TextAlign.left`）与结构断言 ③ 组覆盖。
       */
      /*
       * ★ B1（反假绿审计，task-15）：这里曾经是
       * ```text
       * if (find.text('这个备份文件含登录态').evaluate().isEmpty) {
       *   markTestSkipped('备份导出入径不可达：需真实凭证状态与文件系统写入；…');
       *   return;
       * }
       * ```
       * 为什么那是个**假绿陷阱**：这段提示的前置条件**全部由本用例自己构造**
       * ```text
       * 凭证状态  → 上面 setUp 里 SourinApi.debugCredentialsStatusFetcher 桩好了
       *            （providers: 2 ⇒ `_exportConsent` 必然走"含登录态"那一支）
       * 弹窗宿主  → MaterialApp + Navigator 由本用例 pump
       * 提示时机  → _doExport() 先 await _exportConsent()，**在保存对话框之前**
       *            ⇒ 不需要文件选择器、也不需要真文件系统
       * ```
       * 也就是说：提示不出现 = `_exportConsent` 的判据坏了 / 外壳把它吞了 ——
       * 正是这条用例要抓的回归。把它写成 skip，等于"UI 坏掉时最该红的地方不红"。
       * ⇒ 现在改成硬断言（分类：**用例自身前置状态缺失 ⇒ 必须 fail**）。
       */
      expect(
        find.text('这个备份文件含登录态'),
        findsOneWidget,
        reason: '★★★ 前置状态由本用例自己构造（桩 providers=2 + 自带 Navigator），'
            '提示不出现只能是 _exportConsent 判据坏了或外壳吞了弹窗 —— 必须红，不许 skip',
      );

      expect(find.text('这个备份文件含登录态'), findsOneWidget,
          reason: '★ 导出前必须先出现这条知情提示（标题逐字）');
      expect(find.text('不含登录态导出'), findsOneWidget);
      expect(find.text('设口令并加密'), findsOneWidget);
      expect(find.textContaining('2 个内容源'), findsWidgets,
          reason: '★ 正文照渲染（含源数）');

      // 机制⑤：正文必须左对齐（这张清单靠行首缩进才成立）
      final texts = t.widgetList<Text>(find.descendant(
        of: find.byType(AppGlassDialog),
        matching: find.byType(Text),
      ));
      expect(texts.any((w) => w.textAlign == TextAlign.left), isTrue,
          reason: '★★ 清单必须显式左对齐 —— 外壳内容区默认 textAlign: center');

      // 取消 ⇒ pop(null) ⇒ `choice == null` ⇒ 直接 return（不设口令、不导出）
      await t.tap(find.text('取消'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.byType(AppGlassDialog), findsNothing, reason: '★ 取消应关掉');
      expect(find.text('设置导出用口令'), findsNothing,
          reason: '★★ 取消后**不许**继续走"设口令"分支（pop 的必须是 null）');

      // 「设口令并加密」⇒ pop('encrypt') ⇒ 必须打开口令框
      await t.tap(find.widgetWithText(FilledButton, '导出'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      await t.tap(find.text('设口令并加密'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('设置导出用口令'), findsOneWidget,
          reason: '★★ 「设口令并加密」必须弹出**口令框**（改前 pop 出的是字符串 '
              "'encrypt'，宿主据此走这一支）");
      expect(find.byType(TextField), findsOneWidget,
          reason: '★★ 输入框必须真的建出来（机制②：调用点补了透明 Material 宿主）');
      expect(t.takeException(), isNull, reason: '★ 口令框打开不许抛');

      // 口令 <8 位 ⇒ `_submit()` 只 setState 报错、**不关窗**
      await t.enterText(find.byType(TextField), 'short');
      await t.tap(find.byType(AppTextButton).last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 300));
      expect(find.text('设置导出用口令'), findsOneWidget,
          reason: '★★ 口令太短**不许关窗**（`_submit` 的判据：setState 报 _err 后 return）');
      /*
       * ★ 原来写的是 `find.textContaining('至少 8 位') , findsOneWidget` ——
       *   一旦真的驱动到这一步就会红：**两处**都含这句
       *   （错误文案「口令至少 8 位」+ 输入框 label「口令（至少 8 位）」）。
       *   这条断言的本意是"必须把**原因**说出来"，所以收紧成**逐字匹配错误文案**，
       *   既排除 label 的干扰，又比 contains 更严（少一个字就红）。
       */
      expect(find.text('口令至少 8 位'), findsOneWidget,
          reason: '★★ 必须把原因说出来（不是静默不响应）；逐字匹配错误文案，'
              '不与输入框 label「口令（至少 8 位）」混淆');

      // 合法口令 ⇒ pop((pass:…)) ⇒ 关窗并继续（后面会因没有文件选择器而失败，
      // 本用例只钉"值真的交出去了"这一条：弹窗必须关掉）
      await t.enterText(find.byType(TextField), 'longenough1');
      await t.tap(find.byType(AppTextButton).last);
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('设置导出用口令'), findsNothing,
          reason: '★★ 合法口令必须 pop 出 (pass:…)，弹窗关掉');
    });

    // ── ⑤⑥ theme「粘贴主题包 JSON」+「单套大预览」──
    testWidgets('⑤⑥ theme 粘贴 JSON / 单套大预览：真点两处入口读返回值与顺序', (t) async {
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: const Scaffold(body: ThemeSettingsPage()),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));
      expect(t.takeException(), isNull, reason: '前提：主题页能挂起来');

      // ⑤ 粘贴 JSON：入口是页面上的药丸（可能在折叠线以下 ⇒ 先滚到可见）
      await t.ensureVisible(find.text('粘贴 JSON'));
      await t.pump();
      await t.tap(find.text('粘贴 JSON'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('粘贴主题包 JSON'), findsOneWidget, reason: '★ 标题逐字');
      expect(find.byType(TextField), findsOneWidget,
          reason: '★★ 多行输入框必须真的建出来（机制② 就地补 Material 宿主）');
      // 多行输入框的输入区必须左对齐（机制⑤ 的**视觉语义**）
      final merge = t.widgetList<DefaultTextStyle>(find.descendant(
        of: find.byType(AppGlassDialog),
        matching: find.byType(DefaultTextStyle),
      ));
      expect(merge.any((d) => d.textAlign == TextAlign.left), isTrue,
          reason: '★★ 外壳内容区默认 textAlign: center ⇒ 必须显式左对齐，'
              '否则 JSON 粘贴框里的多行内容会被逐行居中');

      // 取消 ⇒ pop(null) ⇒ 调用方 `if (src == null …) return;` ⇒ 不许导入
      final packsBefore = ThemePackStore.loadAll().length;
      await t.tap(find.text('取消'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.text('粘贴主题包 JSON'), findsNothing, reason: '★ 取消应关掉');
      expect(ThemePackStore.loadAll().length, packsBefore,
          reason: '★★ 取消（pop null）**不能**触发导入 —— 改前的判据 `src == null` 一字未改');

      // ⑥ 单套大预览：卡片右侧的眼睛图标
      final eye = find.byIcon(AppIcons.visibility_outlined);
      /*
       * ★ 分类判据（B1 表）：**入口容器必须存在，缺的只允许是"数据"**。
       * ```text
       * ThemeGrid 不存在            → 主题区块被删/坏了 ⇒ 必须红（结构回归）
       * ThemeGrid 在但没有卡片       → 本机没装主题包 ⇒ 环境缺件，允许 skip
       * ```
       * 没有这一句，整个主题区块被删掉时这条用例会安静地 skip 过去。
       */
      expect(find.byType(ThemeGrid), findsOneWidget,
          reason: '★ 主题区块必须渲染（ThemeGrid）—— 少了它是结构回归，不是缺件');
      if (eye.evaluate().isEmpty) {
        /*
         * ⚠️ 覆盖边界（如实标注，不造假绿）：
         * 预览入口只在**已有主题包卡片**时渲染（`ThemeGrid` 的
         * `if (onPreview != null)` 分支，卡片来自 `ThemePackStore.loadAll()`）。
         * 空数据 + 隔离 UiPrefs 环境下没有卡片 ⇒ 入口不可达。
         * 该处迁移（机制① 宽度显式 560、机制⑤ 左对齐、Material 宿主）的
         * 等价性已由 `_previewPack` 源码语义 + ① 组仪器自检（Switch 必须补宿主）
         * 与 ⑬ download 的同形态左对齐断言覆盖；此处不弱化断言。
         */
        // 环境缺件（数据依赖）：本机没装主题包 ⇒ ThemeGrid 不渲染卡片。
        // ★ 只允许这一类 skip；若已装包却仍渲染不出，应由下面 findsOneWidget 变红。
        markTestSkipped('环境缺件：本机未安装任何主题包（ThemeGrid 无卡片可点）；'
            '替代覆盖：主题预览的结构断言与本文件 ① 外壳 Material 探针；'
            '该处宽度/左对齐/Material 宿主已由 ① 组仪器自检与 ⑬ 同形态断言覆盖。');
        return;
      }
      final selectedBefore = ThemePackStore.selectedId;
      await t.ensureVisible(eye.first);
      await t.pump();
      await t.tap(eye.first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.textContaining('预览 · '), findsOneWidget,
          reason: '★ 预览弹窗标题（改前是自绘 Text + 调色板前景色）');
      expect(find.text('用这套'), findsOneWidget, reason: '★ 两个入口都在（关闭 / 用这套）');

      // 「用这套」= 先 pop 再切主题（顺序不能反）
      await t.tap(find.text('用这套'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.textContaining('预览 · '), findsNothing,
          reason: '★★ 「用这套」必须先关窗再切主题 —— 否则切主题引发的整树重建'
              '会打在已 pop 的路由上');
      expect(ThemePackStore.selectedId, isNot(selectedBefore),
          reason: '★★ 副作用：主题真的切了（`_pickPack` → `ThemePackStore.select`）');
    });

    // ── ① settings「_promptText」（含 TextField；2 个生产调用点之一：安装 JS 插件）──
    testWidgets('① settings _promptText：真点「安装 JS 插件」→ 取消 ⇒ null（不装）', (t) async {
      if (!_coreReady) {
        // 环境缺件 ⇒ 允许 skip；点名缺件与替代覆盖
        markTestSkipped('环境缺件：缺 sourin_core.dll（CI 在构建前跑测试，测试阶段没有 dll）；'
            '替代覆盖：该入口的结构断言 + Rust 端对应单测');
        return;
      }
      await t.pumpWidget(MaterialApp(
        theme: AppTheme.themeFor(Brightness.dark),
        themeAnimationDuration: Duration.zero,
        home: const Scaffold(body: SingleChildScrollView(child: SettingsPage())),
      ));
      await t.pump();
      await t.pump(const Duration(milliseconds: 600));

      final entry = find.text('安装 JS 插件');
      /*
       * ⚠️ 覆盖边界（如实标注，不造假绿）：
       * `_promptText(title: '安装 JS 插件')` 是 `SettingsPage` 的**私有方法**，
       * 唯一生产调用点是「安装插件」按钮 → `_installPlugin()`；
       * 而该按钮挂在**已安装插件卡片区**内，空数据环境下不渲染。
       * 本轮不引入为测试而开的公开探针（避免"写了不接线"的死代码），
       * 因此这条用例改为**在入口不可达时明确跳过并说明**，
       * 而不是把断言弱化成"存在即通过"。
       * 该处的返回值语义（取消 pop(null)、空串也是有效返回）由 ③ 组
       * backup 的同类 TextField 弹窗（同为 `_promptText` 形态）与
       * `zz_t1023_player_recovery_contract_test` 的契约断言间接覆盖。
       */
      if (entry.evaluate().isEmpty) {
        markTestSkipped('环境缺件：本机没有已安装插件（入口挂在插件卡片区）；'
            '替代覆盖：plugins 侧的安装入口单测 + 本文件 ① 外壳探针；原注：'
            '空数据环境不渲染；本处 _promptText 迁移由 ③ 组同形态弹窗覆盖。');
        return;
      }
      await t.ensureVisible(entry.first);
      await t.pump();
      await t.tap(entry.first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));

      expect(find.byType(AppGlassDialog), findsOneWidget,
          reason: '★ 必须走统一外壳（改前是 Material 的 AlertDialog）');
      expect(find.text('安装 JS 插件'), findsWidgets, reason: '★ 标题');
      expect(find.byType(TextField), findsOneWidget,
          reason: '★★ 输入框必须真的建出来 —— 缺 Material 宿主时连建都不建');
      expect(t.takeException(), isNull,
          reason: '★★ 打开不许抛（机制② 在调用点补了透明 Material 宿主）');

      // 取消 ⇒ pop(null) ⇒ 调用方 `url == null` ⇒ 不安装、不 flash
      await t.tap(find.text('取消'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.byType(AppGlassDialog), findsNothing, reason: '★ 取消应关掉');
      expect(find.textContaining('正在下载'), findsNothing,
          reason: '★★ 取消后**不许**走安装分支（pop 的必须是 null，'
              '`url == null || url.trim().isEmpty` 判据一字未改）');

      // 再打开一次：确定 ⇒ pop(ctl.text)，**空串也是有效返回值**
      //   ⇒ 调用方随后 `url.trim().isEmpty` 自己拦下来（改前就是这样）
      await t.tap(entry.first);
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      await t.tap(find.text('确定'));
      await t.pump();
      await t.pump(const Duration(milliseconds: 900));
      expect(find.byType(AppGlassDialog), findsNothing,
          reason: '★★ 点确定必须 pop 出值并关窗（空串也要 pop 出来，'
              '由调用方判空 —— 不要把判空搬进弹窗，那是行为变更）');
      expect(find.textContaining('正在下载'), findsNothing,
          reason: '★★ 空串由调用方拦下 ⇒ 不许出现「正在下载…」'
              '（若这里红灯，说明有人把 `pop(ctx, ctl.text)` 改成了别的）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  ③ 结构断言：这 6 个文件不许再退回 Material 的 AlertDialog
  // ═══════════════════════════════════════════════════════════════════
  //
  // ⚠️ 这一组读的是**源码字符串**，与本文件"不许拿源码字符串当判据"的原则
  //    不冲突 —— 因为它的定位不是"证明弹窗好用"（那是 ①② 组的活），
  //    而是**"不许退回去"的防回退闸**：这种"某个写法在整个文件里不许再出现"
  //    的约束，只能靠源码级扫描表达（渲染树里看不见"没写的东西"）。
  //    ⇒ 故配一条**阳性对照**（第 2 条用例）：证明扫描器真的能抓到裸 `AlertDialog(`，
  //      否则它就是一条永远为真的空断言（本仓记过这种假绿形态）。
  group('③ 结构：迁移过的 6 个文件不再有裸 AlertDialog(', () {
    const moved = <String>[
      'lib/ui/settings_page.dart',
      'lib/ui/settings/theme_page.dart',
      'lib/ui/widgets/sync_panel.dart',
      'lib/ui/widgets/backup_panel.dart',
      'lib/ui/widgets/download_panel.dart',
      'lib/ui/widgets/tvbox_source_panel.dart',
    ];

    /// 裸 `AlertDialog(` 的行号（`AppGlassDialog(` 不算）
    List<int> bareAlertDialogLines(String src) {
      final out = <int>[];
      final lines = src.split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (RegExp(r'(?<![A-Za-z0-9_.])AlertDialog\(').hasMatch(lines[i])) {
          out.add(i + 1);
        }
      }
      return out;
    }

    test('★ 6 个文件里裸 AlertDialog( 必须为 0', () {
      for (final p in moved) {
        final f = File(p);
        expect(f.existsSync(), isTrue, reason: '★ 前提：$p 存在');
        final hits = bareAlertDialogLines(f.readAsStringSync());
        expect(hits, isEmpty,
            reason: '★★ $p 里还有裸 `AlertDialog(`（行 $hits）—— '
                '第 18 项把这 13 处全迁到了统一外壳 AppGlassDialog。'
                '弹窗一律走外壳：宽度 460/560/820 + 圆角 Radii.rLg + 内容区可滚。');
      }
    });

    test('★★ 阳性对照：扫描器真的能抓到裸 AlertDialog(（否则上一条是空断言）',
        () {
      expect(bareAlertDialogLines('return AlertDialog(\n'), [1],
          reason: '★★ 扫描器抓不到源码里的裸 AlertDialog( ⇒ 上一条恒真 = 假绿');
      expect(bareAlertDialogLines('builder: (ctx) => AppGlassDialog('), isEmpty,
          reason: '★ 别把统一外壳也算成违规（负向前瞻必须排掉 AppDialogShell/AppGlassDialog）');
      expect(bareAlertDialogLines("// 旧注释里写过 AlertDialog(\n"), [1],
          reason: '★ 记一句实话：本扫描器**不剥注释**，'
              '所以迁移时留在注释里的旧写法也会被它判红 —— '
              '第 18 项的 6 个文件里已把旧的 R4-EXCEPTION 注释一并改写/删除；'
              '若将来有人在注释里写回该字面量，这一条会红（宁可吵一点）。');
    });

    test('★ 反向对照：这 6 个文件确实都在用统一外壳（防"删了没换"）', () {
      for (final p in moved) {
        final src = File(p).readAsStringSync();
        expect(src.contains('AppGlassDialog('), isTrue,
            reason: '★★ $p 里一个 AppGlassDialog( 都没有 —— '
                '要么迁移没落盘，要么被换回别的承载件');
      }
    });
  });
}

/// 构造一条下载任务（照 test/zz_t11_panel_render_probe_test.dart 的 _task）
DownloadTask _task(String ep, DownloadState state) => DownloadTask(
      id: 'p:m:$ep',
      title: '探针剧',
      episodeTitle: ep,
      provider: 'p',
      mediaId: 'm',
      episodeId: ep,
      sourceCode: 's',
      fileName: ep,
      done: 0,
      total: 0,
      state: state,
    );

void _noop(bool _) {}
