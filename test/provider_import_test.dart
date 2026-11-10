// ═══════════════════════════════════════════════════════════════════════
//  Provider 导入 / 编辑入口 + 插件区块缺失的 3 个按钮（任务 R）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么
//
// 审计（635 行报告）认定两处**真缺口**：
// ```text
// 缺口组① Provider 导入 / 编辑 —— 4 个命令无 UI 入口
//   import_declarative_provider  原版 SettingsView.vue:1458
//   install_http_provider        原版 SettingsView.vue:1474
//   get_provider_config          原版 SettingsView.vue:1384
//   get_provider_order           原版 SettingsView.vue:1586
//
// 缺口组② JS 插件区块缺 3 个按钮（原版共 5 个）
//   健康检测 health_sweep     —— 包装一直存在，设置页调用数 = 0
//   导入源   openAdd          —— 声明式 JSON / HTTP 的唯一界面入口
//   重新加载 reload_plugins   —— 包装一直存在，设置页调用数 = 0
// ```
//
// # 为什么要断言「真的调了 API」而不只是「按钮存在」
//
// 项目里踩过这个坑（见 `settings_panels_test.dart` 的开头）：
// **"代码写完了"和"功能可用了"之间差一次接线**。
// `healthSweep()` 的包装在 `sourin_api.dart:145` 躺了很久，
// 但设置页里调用数为 0 —— 光断言"有这个按钮"是抓不到的。
//
// # ⚠️ 断言前必须先剥注释（本项目踩过至少四次）
//
// 这些新增代码的注释里**大量提到** `SourinApi.healthSweep()` /
// `reloadPlugins` 这些标识符（因为要把"为什么"写清楚）。
// 纯文本匹配会把注释当成真实调用 → **假通过**。
// 所以下面所有源码断言都走 [_code]（先剥注释）。
//
// # 分层
//
// ```text
// 静态接线断言  → 本文件（不需要真核心）
// 纯函数行为断言 → 本文件（parseHeaders / fromJson / toast）
// 真实观感与网络 → 真机截图 + 真实健康检测（单测做不到，需要 FFI）
// ```

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/services.dart';
import 'package:flutter_miuix/miuix.dart' as miuix;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/widgets/provider_import_dialog.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/device.dart';
import 'package:sourin_spike/core/source_discovery.dart';
import 'package:sourin_spike/core/ui_prefs.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/widgets/miuix_controls.dart' as ui;
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/settings/source_manager_page.dart';
import 'package:sourin_spike/ui/widgets/app_dialog_shell.dart';
import 'package:sourin_spike/ui/widgets/app_toast.dart';
import 'package:sourin_spike/ui/widgets/plugin_edit_dialog.dart';

import 'support/miuix_finders.dart';

/// 剥掉注释 —— 静态断言里做文本匹配**必须先剥**
///
/// 比 `settings_panels_test.dart` 的 `_code` 更彻底：那个只过滤
/// **整行**以 `//` / `*` / `/*` 开头的行，抓不到
/// ```dart
/// final x = 1; // 这里提到 SourinApi.healthSweep()
/// ```
/// 这种**行尾注释**。本文件用正则把块注释与行注释都去掉。
///
/// ⚠️ 代价：字符串字面量里的 `//`（如 `'http://...'`）也会被截断。
///    所以本文件**不对含 `//` 的字符串做断言** —— 这是有意的取舍，
///    宁可少断言两条，也不要一条假通过的。
String _code(String src) => src
    .replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')
    .replaceAll(RegExp(r'//[^\n]*'), '');

Widget _providerTestHost(Widget child, {Brightness brightness = Brightness.light}) {
  final theme = AppTheme.themeFor(brightness);
  return MaterialApp(
    theme: theme,
    builder: (_, child) => AppThemeHost(
      data: theme,
      child: ToastHost(child: child!),
    ),
    home: child,
  );
}

// Pending source actions keep progress animations active. Wait for the actual
// content with a finite bound instead of waiting for every animation to stop.
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  required String reason,
}) async {
  for (var frame = 0; frame < 30; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().length == 1) return;
  }
  expect(finder, findsOneWidget, reason: reason);
}

/// Only native transport is replaced; settings, callbacks, menus and dialogs are real.
class _SourceActionFixture {
  final commands = <String>[];
  final unexpected = <String>[];
  Completer<int>? reloadCompletion;
  int changes = 0;

  Future<dynamic> call(String command, Map<String, dynamic>? args) async {
    commands.add(command);
    switch (command) {
      case 'list_providers':
        return [
          {
            'id': 'tvbox-test',
            'name': 'TVBox 测试源',
            'kind': 'tvbox',
            'enabled': true,
            'capabilities': {'vod': true, 'search': true},
          },
          {
            'id': 'http-disabled',
            'name': 'HTTP 历史源',
            'kind': 'http',
            'enabled': false,
            'capabilities': {'vod': true, 'search': true},
          },
          {
            'id': 'js-disabled',
            'name': '禁用 JS',
            'kind': 'js',
            'enabled': false,
            'capabilities': {'vod': true, 'search': true},
          },
        ];
      case 'source_catalog_get':
        return {'origins': <dynamic>[], 'groups': <dynamic>[]};
      case 'list_tvbox_sources':
        return {'sources': <dynamic>[]};
      case 'list_plugins':
        return {'plugins': <dynamic>[], 'failed': <dynamic>[]};
      case 'global_proxy_migration_choices':
      case 'list_skip_markers':
      case 'restore_failures':
        return <dynamic>[];
      case 'remote_auto_start':
        return false;
      case 'remote_status_cmd':
      case 'list_plugin_sources':
      case 'list_proxy_configs':
      case 'source_discovery_status':
      case 'tvbox_update_schedule_get':
        return <String, dynamic>{};
      case 'reload_plugins':
        return reloadCompletion == null ? 2 : await reloadCompletion!.future;
      default:
        unexpected.add(command);
        throw StateError('Unexpected native command: $command');
    }
  }
}

Future<void> _openSourcesForTest(
  WidgetTester tester,
  _SourceActionFixture fixture,
) async {
  UiPrefs.debugResetForTest();
  Device.overrideKind(DeviceKind.desktop);
  ProxyCache.invalidate();
  SourceDiscoveryService.current.value = null;
  SourinCore.debugCallAsyncTransport = fixture.call;
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1280, 1100);
  addTearDown(() {
    SourinCore.debugCallAsyncTransport = null;
    Device.overrideKind(null);
    ProxyCache.invalidate();
    SourceDiscoveryService.current.value = null;
    UiPrefs.debugResetForTest();
    tester.view.reset();
  });
  await tester.pumpWidget(
    _providerTestHost(
      AppScaffold(child: SettingsPage(onProvidersChanged: () => fixture.changes++)),
    ),
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(find.text('源'));
  await tester.tap(find.text('源'));
  await tester.pumpAndSettle();
  expect(find.byType(SourceManagerPage), findsOneWidget);
}

void _expectSourceEnabledStates(WidgetTester tester) {
  for (final entry in const {
    'tvbox-test': true,
    'http-disabled': false,
    'js-disabled': false,
  }.entries) {
    expect(
      tester.widget<ui.Switch>(find.byKey(ValueKey('source-enabled-${entry.key}'))).value,
      entry.value,
    );
  }
}

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  缺口组②：插件区块的 3 个按钮 + 接线
  // ═══════════════════════════════════════════════════════════════════
  group('插件区块缺的 3 个按钮', () {
    late String src;
    late String code;

    setUpAll(() {
      src = File('lib/ui/settings_page.dart').readAsStringSync();
      code = _code(src);
    });

    test('★★ 健康检测：按钮存在 + 真的逐项探活（不许假接线）', () {
      /*
       * 原版 `SettingsView.vue:1716`：
       * ```html
       * <button class="btn btn--ghost" :disabled="sweepping" @click="sweep">
       *   {{ sweepping ? "检测中…" : "健康检测" }}
       * </button>
       * ```
       *
       * ⚠️ 关键是**第二半** —— `healthSweep()` 的包装在
       *    `sourin_api.dart:145` 一直存在，缺的是调用点。
       *    只断言按钮文案会**假通过**（注释里就写着这四个字）。
       *
       * # ★★★ 2026-10-18（第 66 轮 · 轨道 C · Owner 第 13 条）：换载体，不换用意
       *
       * 本条原来钉 `code.contains('SourinApi.healthSweep()')`。
       * 改它的理由**不是**"测试挡路了"，而是那个实现被实测证明是错的
       * （读数与后端证据见下），用意「不许假接线」原样保留。
       *
       * ## 为什么批量 health_sweep 不能用（Lead 已复核的三条代码证据）
       * ```text
       * rust/sourin_core/src/provider.rs:571
       *     trait 默认实现 async fn health_check() -> bool { true }
       * rust/sourin_core/src/providers/declarative.rs:688  有真实现
       * rust/sourin_core/src/providers/http.rs:485         有真实现
       * ⇒ 只有 declarative / http 两类有真探活；
       *   **JS 插件全部落到 trait 默认 ⇒ 恒 true**。
       * ```
       * 真机读数（真核心 + 32 个本机插件，全部是 js）：
       * ```text
       * health_sweep           → 32 条全 true，耗时 3 ms（什么都没测）
       * 逐项 get_categories    → 31 可用 / 0 不可用，耗时 1981 ms（真的跑了插件）
       * ```
       * 工程上还有一条独立的否决理由：批量入口的耗时是 `源数 × 15s`
       * （后端每源 15s 超时），而 FFI 兜底超时是 120s
       * （`lib/core/ffi.dart:685`）⇒ 源一多必然抛超时、**所有结果全丢**。
       * 那正是 Owner 看到的「健康失败」。
       *
       * ## 新判据（用意 = 「必须真的探测，不能只有文案」）
       * ```text
       * _probeProviderHealth(  必须存在且被 _healthSweep 调用（真探测）
       * SourinApi.healthSweep() 必须**不**出现在剥注释后的代码里（禁回旧路）
       * ```
       * ⚠️ 反向断言是在 `code`（= `_code(src)`，**已剥注释**）上判的 ——
       *    所以将来谁在注释里写「不要用 SourinApi.healthSweep()」也不会假红。
       *    （这条正是 Lead 特别要求的：反向断言必须在剥注释后的文本上判。）
       */
      expect(code.contains('健康检测'), isTrue, reason: '按钮文案必须是「健康检测」');

      // ① 正向：必须存在逐项探活，且**真的被健康检测调用**
      expect(
        code.contains('_probeProviderHealth('),
        isTrue,
        reason: '★★ 必须逐项探活（单个源一次调用）—— 这样才有"N/总数"，'
            '也不会把 N 个源的最坏耗时堆进一个 120s 兜底的 FFI 调用里',
      );
      final iSweep = code.indexOf('Future<void> _healthSweep() async {');
      expect(iSweep, greaterThan(0), reason: '★ 找不到 _healthSweep —— 结构变了');
      final sweepBody = code.substring(iSweep, code.indexOf('\n  }', iSweep));
      expect(
        sweepBody.contains('_probeProviderHealth(p.id)'),
        isTrue,
        reason: '★★ 光**定义**了 _probeProviderHealth 不算接线 —— '
            '必须在 _healthSweep 的循环里真的调用它（这就是"不许假接线"）',
      );

      // ② 反向：禁回批量老路（判在已剥注释的 `code` 上）
      expect(
        code.contains('SourinApi.healthSweep()'),
        isFalse,
        reason: '★★★ **不许**再用批量 healthSweep —— 实测对 32 个 js 源返回恒 true、'
            '3 ms 什么也没测（JS 插件无 health_check 覆盖，落到 trait 默认实现）',
      );

      // 探测期间禁用 + 文案变「检测中…」（原版 `:disabled="sweepping"`）
      expect(code.contains('检测中'), isTrue, reason: '探测中要有「检测中…」文案');
      expect(code.contains('_sweeping'), isTrue, reason: '必须有 _sweeping 状态位');
    });

    test('★★★ 健康检测的反馈必须报出「几个源不可用」或「全部正常」', () {
      /*
       * 原版 `SettingsView.vue:1490`（这是这个功能的**全部价值**）：
       * ```ts
       * const r = await provApi.healthSweep();
       * const bad = Object.entries(r).filter(([, ok]) => !ok);
       * flash(bad.length ? `${bad.length} 个源不可用` : "全部正常");
       * ```
       *
       * ⚠️ 只显示"检测完成"等于没做 —— 用户点这个按钮就是想知道
       *    **哪些源挂了**。本机 26 个源，没法逐个点进去试。
       *
       * # ★ 2026-10-18（轨道 C）：换载体，不换用意
       *
       * 本条原来钉 `code.contains('where((e) => !e.value)')` ——
       * 那个判据依附批量返回值 `id → bool` 这个 Map。逐项调用后
       * 后端不再返回这个 Map，所以载体必须换。
       *
       * **用意完全没变**：`全好` 与 `全坏` 不能颠倒，
       * 即「失败的源必须被挑出来记进 bad」。
       * 新载体是 `if (!ok) bad.add(` —— 它是同一个意思：
       * `ok == false` 才进 bad。
       */
      expect(
        code.contains('全部正常'),
        isTrue,
        reason: '★ 全好时必须说「全部正常」',
      );
      expect(
        code.contains('个源不可用'),
        isTrue,
        reason: '★ 有坏的必须报出数量（原版文案是 bad.length 个源不可用）',
      );
      expect(
        code.contains('if (!ok) bad.add('),
        isTrue,
        reason: '★★ 必须把**失败**（ok == false）的源挑出来记进 bad —— '
            '判据写反成 `if (ok)` 的话"全好"和"全坏"会颠倒。'
            '（等价于改前的 `where((e) => !e.value)`，只是载体从 Map 变成逐项 bool）',
      );
      // 反面：不许把成功也塞进 bad（那会让"全好"报成"全坏"）
      expect(
        code.contains('if (ok) bad.add('),
        isFalse,
        reason: '★★ 判据写反的**字面形态**：成功的不许进 bad',
      );
    });

    testWidgets('导入 TVBox 从设置页真实入口打开，空表单禁用且取消不导入', (tester) async {
      final fixture = _SourceActionFixture();
      await _openSourcesForTest(tester, fixture);
      _expectSourceEnabledStates(tester);
      final entry = find.widgetWithText(ui.FilledButton, '导入 TVBox');
      expect(tester.widget<ui.FilledButton>(entry).onPressed, isNotNull);
      await tester.tap(entry);
      await _pumpUntilFound(
        tester,
        find.descendant(
          of: find.byType(ProviderImportDialog),
          matching: find.widgetWithText(ui.TextButton, '取消'),
        ).hitTestable(),
        reason: 'TVBox 弹窗必须在 1.5 秒内出现可点击的取消按钮',
      );
      // The covered source page must stop its indeterminate progress ticker.
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );

      expect(find.byType(ProviderImportDialog), findsOneWidget);
      expect(find.text('导入 TVBox 配置'), findsOneWidget);
      expect(find.text('TVBox 配置'), findsOneWidget);
      expect(find.text('填入模板'), findsNothing);
      expect(find.text('可视化编排'), findsNothing);
      expect(find.textContaining('声明式'), findsNothing);
      for (final key in ['source-address-name', 'source-address-primary', 'source-address-backups']) {
        final field = tester.widget<ui.TextField>(find.byKey(ValueKey(key)));
        expect(field.controller!.text, isEmpty);
        expect(field.enabled, isTrue);
      }
      expect(
        tester.widget<ui.FilledButton>(find.widgetWithText(ui.FilledButton, '导入并探测')).onPressed,
        isNull,
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderImportDialog), findsNothing);
      expect(fixture.commands, isNot(contains('import_tvbox_config')));
      expect(fixture.commands, isNot(contains('install_http_provider')));
      expect(fixture.unexpected, isEmpty);
      _expectSourceEnabledStates(tester);
      expect(tester.takeException(), isNull);
    });

    testWidgets('重新加载 JS 调用真实命令，等待期间禁用动作并在完成后恢复', (tester) async {
      final fixture = _SourceActionFixture()..reloadCompletion = Completer<int>();
      await _openSourcesForTest(tester, fixture);
      final providerReads = fixture.commands.where((command) => command == 'list_providers').length;
      final pluginReads = fixture.commands.where((command) => command == 'list_plugins').length;
      await tester.tap(miuixTooltip('更多操作'));
      await tester.pumpAndSettle();
      expect(find.text('重新加载 JS'), findsOneWidget);
      await tester.tap(find.text('重新加载 JS'));
      for (var i = 0; i < 30 && !fixture.commands.contains('reload_plugins'); i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(fixture.commands.where((command) => command == 'reload_plugins'), hasLength(1));
      await tester.pump();
      expect(find.byType(miuix.MiuixLinearProgressIndicator), findsOneWidget);
      expect(
        tester.widget<ui.FilledButton>(find.widgetWithText(ui.FilledButton, '导入 TVBox')).onPressed,
        isNull,
      );
      for (final label in ['安装 JS', '添加直播', '调整顺序']) {
        expect(tester.widget<ui.OutlinedButton>(find.widgetWithText(ui.OutlinedButton, label)).onPressed, isNull);
      }

      await tester.tap(miuixTooltip('更多操作'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      for (final label in ['重新加载 JS', '健康检测']) {
        final item = tester.widget<miuix.MiuixBasicComponent>(
          find.ancestor(of: find.text(label), matching: find.byType(miuix.MiuixBasicComponent)),
        );
        expect(item.enabled, isFalse);
        expect(item.onClick, isNull);
      }
      await tester.tap(find.text('重新加载 JS'), warnIfMissed: false);
      await tester.pump();
      expect(fixture.commands.where((command) => command == 'reload_plugins'), hasLength(1));
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      fixture.reloadCompletion!.complete(2);
      await tester.pumpAndSettle();
      expect(find.byType(miuix.MiuixLinearProgressIndicator), findsNothing);
      expect(find.text('已重新加载 2 个插件'), findsOneWidget);
      await tester.pump(const Duration(seconds: 4));
      await tester.pumpAndSettle();
      expect(fixture.commands.where((command) => command == 'list_providers').length, greaterThan(providerReads));
      expect(fixture.commands.where((command) => command == 'list_plugins').length, greaterThan(pluginReads));
      expect(fixture.changes, greaterThan(0));
      expect(
        tester.widget<ui.FilledButton>(find.widgetWithText(ui.FilledButton, '导入 TVBox')).onPressed,
        isNotNull,
      );
      await tester.tap(miuixTooltip('更多操作'));
      await tester.pumpAndSettle();
      final reload = tester.widget<miuix.MiuixBasicComponent>(
        find.ancestor(of: find.text('重新加载 JS'), matching: find.byType(miuix.MiuixBasicComponent)),
      );
      expect(reload.enabled, isTrue);
      expect(reload.onClick, isNotNull);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      _expectSourceEnabledStates(tester);
      expect(fixture.unexpected, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('源操作在窄屏实际折行，低频菜单与 JS 安装编辑和排序仍可达', (tester) async {
      final fixture = _SourceActionFixture();
      await _openSourcesForTest(tester, fixture);
      tester.view.physicalSize = const Size(411, 1100);
      await tester.pumpAndSettle();
      final controls = [
        find.widgetWithText(ui.FilledButton, '导入 TVBox'),
        find.widgetWithText(ui.OutlinedButton, '安装 JS'),
        find.widgetWithText(ui.OutlinedButton, '添加直播'),
        find.widgetWithText(ui.OutlinedButton, '调整顺序'),
        miuixTooltip('更多操作'),
      ];
      final rects = [for (final control in controls) tester.getRect(control)];
      for (final rect in rects) {
        expect(rect.left, greaterThanOrEqualTo(0));
        expect(rect.right, lessThanOrEqualTo(411));
        expect(rect.height, greaterThan(0));
      }
      expect(rects.map((rect) => rect.top).reduce(math.max), greaterThan(rects.first.top),
          reason: '窄屏操作必须实际排成多行，单行溢出或裁剪不能通过');
      expect(find.text('健康检测'), findsNothing);
      expect(find.text('重新加载 JS'), findsNothing);
      expect(find.text('粘贴 JS 源码'), findsNothing);
      await tester.tap(miuixTooltip('更多操作'));
      await tester.pumpAndSettle();
      for (final label in ['健康检测', '重新加载 JS', '粘贴 JS 源码']) {
        expect(find.text(label), findsOneWidget);
        final item = tester.widget<miuix.MiuixBasicComponent>(
          find.ancestor(of: find.text(label), matching: find.byType(miuix.MiuixBasicComponent)),
        );
        expect(item.enabled, isTrue);
        expect(item.onClick, isNotNull);
      }
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);

      tester.view.physicalSize = const Size(1280, 1100);
      await tester.pumpAndSettle();
      await tester.tap(find.text('安装 JS'));
      await tester.pumpAndSettle();
      expect(find.byType(SourceAddressDialog), findsOneWidget);
      expect(tester.widget<SourceAddressDialog>(find.byType(SourceAddressDialog)).origin.kind, 'js');
      expect(find.byKey(const ValueKey('source-address-primary')), findsOneWidget);
      expect(find.byKey(const ValueKey('source-address-backups')), findsOneWidget);
      await tester.tap(miuixTooltip('关闭'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('调整顺序'));
      await tester.pumpAndSettle();
      expect(find.byType(SourceOrderPage), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('page-header-back')));
      await tester.pumpAndSettle();
      await tester.tap(miuixTooltip('更多操作'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('粘贴 JS 源码'));
      await _pumpUntilFound(
        tester,
        find.descendant(
          of: find.byType(PluginEditDialogBody),
          matching: find.widgetWithText(ui.TextButton, '取消'),
        ).hitTestable(),
        reason: 'JS 源码弹窗必须在 1.5 秒内出现可点击的取消按钮',
      );
      await tester.pumpAndSettle(
        const Duration(milliseconds: 50),
        EnginePhase.sendSemanticsUpdate,
        const Duration(seconds: 2),
      );
      expect(find.byType(PluginEditDialogBody), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(fixture.commands, isNot(contains('install_plugin')));
      expect(fixture.commands, isNot(contains('install_plugin_source')));
      expect(fixture.unexpected, isEmpty);
      _expectSourceEnabledStates(tester);
      expect(tester.takeException(), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  缺口组①：Provider 导入 / 编辑入口
  // ═══════════════════════════════════════════════════════════════════
  group('Provider 导入 / 编辑入口', () {
    late String code;

    setUpAll(() {
      code = _code(File('lib/ui/settings_page.dart').readAsStringSync());
    });

    test('★★ 编辑入口：调 get_provider_config 回填', () {
      /*
       * 原版 `SettingsView.vue:1384`：
       * ```ts
       * const cfg = await provApi.config(p.id);      // get_provider_config
       * if (!cfg) { flash("该源没有可编辑的配置"); return; }
       * ```
       *
       * ⚠️ 原版注释解释了为什么必须回填**原始配置**：
       * > manifest 只是解析后的结果（名称、能力位等），
       * > 用户真正要改的是**请求地址、JSONPath 映射、自定义头**这些，
       * > 它们只存在原始配置里。不回填的话用户只能删了重建 ——
       * > 打错一个字就得全部重来（这正是加这个功能的起因）。
       */
      expect(
        code.contains('SourinApi.getProviderImportSeed('),
        isTrue,
        reason: '★ 必须调 get_provider_config（包装名为 getProviderImportSeed）',
      );
      expect(
        code.contains('该源没有可编辑的配置'),
        isTrue,
        reason: '★ 原版兜底文案，逐字对齐',
      );
      expect(
        code.contains('ProviderImportDialog.showEdit('),
        isTrue,
        reason: '★ 必须用编辑态打开弹窗（预填），不是 showAdd',
      );
    });

    test('★★★ JS 插件走源码编辑器（原版 edit() 的第一条分支）', () {
      /*
       * 原版 `SettingsView.vue:1365`：
       * ```ts
       * if (p.kind === "js") {
       *   const info = pluginList.value.find((x) => x.id === p.id);
       *   if (!info) {
       *     flash("找不到该插件的文件（可能刚被删除，试试「重新加载」）");
       *     return;
       *   }
       *   await editPlugin(info);   // ← 源码编辑器
       *   return;
       * }
       * ```
       *
       * ⚠️ 这条分支是原版**修过的真 bug**：原先编辑按钮的条件是
       *    `kind === 'http' || kind === 'declarative'`，而 JS 插件的
       *    kind 是 `"js"` → 编辑按钮**不显示**。JS 插件当然该能编辑 ——
       *    它就是磁盘上的一个 .js 文件。
       */
      expect(
        code.contains("p.kind == 'js'"),
        isTrue,
        reason: '★ 必须有 JS 插件的分派分支',
      );
      expect(
        code.contains('_editPlugin(info)'),
        isTrue,
        reason: '★ JS 插件必须转给源码编辑器，不是配置弹窗',
      );
      expect(
        code.contains('找不到该插件的文件'),
        isTrue,
        reason: '★ 原版兜底文案（还提示了「重新加载」）',
      );
    });

    test('★★ 「编辑」按钮的判据必须**正向列举**可编辑的', () {
      /*
       * 原版 `canEdit`（`SettingsView.vue:1354`）注释（照抄）：
       * > ⚠️ 判据要**正向列举可编辑的**，而不是「不等于 builtin」——
       * >    后者在将来新增源类型时会误放行（点了报错比不放更糟）。
       *
       * 后端的 `kind` 是 String 不是 enum，将来加新形态时
       * `!= 'builtin'` 会立刻放行，用户点进去才发现没配置可改。
       */
      expect(code.contains('bool get _canEdit'), isTrue, reason: '缺 _canEdit 判据');
      final canEdit = RegExp(r'bool get _canEdit\s*=>[^;]+;')
          .firstMatch(code)!
          .group(0)!;
      expect(canEdit, contains("provider.kind == 'http'"));
      expect(canEdit, contains("provider.kind == 'js'"));
      expect(canEdit, isNot(contains('declarative')));
      // ⚠️ 不能写成「不等于 builtin」
      expect(
        code.contains("provider.kind != 'builtin'"),
        isFalse,
        reason: '★ 禁止用 `!= builtin` 当判据（原版注释明确否定了这种写法）',
      );
    });

    test('★ 卡片真的把 onEdit 接出去了', () {
      /*
       * ⚠️ 这条断言原先锁死字面量 `onEdit: () => _editProvider(p)`。
       *
       * 2026-09-25 拖动排序落地后，卡片改成按下标取（`_providers[i]`）——
       * 因为 `ReorderableListView` 的拖拽需要下标。
       * 于是这条断言**假红**了：功能完好，只是变量名从 `p` 变成了
       * `_providers[i]`。
       *
       * 教训：断言锁死**变量名**会把重构误报成回归。
       * 这里改成锁**结构**（用正则允许任意实参），
       * 既保住"必须接上 onEdit"这个真契约，又不会因为改名而假红。
       */
      expect(
        RegExp(r'onEdit:\s*\(\)\s*=>\s*_editProvider\(').hasMatch(code),
        isTrue,
        reason: '★ 卡片必须接上 onEdit，否则按钮点了没反应',
      );
      expect(
        code.contains('required this.onEdit'),
        isTrue,
        reason: '_ProviderCard 必须声明 onEdit 参数',
      );
      // 声明了还必须**用**上，否则按钮是死的
      expect(
        code.contains("if (v == 'edit') onEdit()"),
        isTrue,
        reason: '★ 光声明不够 —— 编辑按钮必须真的调用 onEdit',
      );
    });

    test('★★★ toast 必须让开**悬浮底栏**的高度（否则反馈全看不见）', () {
      /*
       * # 这是我在验证任务 R 时实测发现的真缺陷（2026-09-24）
       *
       * 底栏是**悬浮**的（`shell.dart` 用 Stack，不占布局空间）。
       * toast 原先只让了 `Sp.x10` = **40px**，而底栏占 58 + 间隙 12 = 70px
       * → toast 正好落在玻璃底下，被模糊层糊住。
       *
       * 截图证据：底部只看得见一团黑色圆角矩形，文字**完全不可辨认**
       *（`.probe/rK-sweep.png` 与放大图 `.probe/rN-toast.png`）。
       *
       * 后果不只是我的任务 —— **所有 `_flash()` 都失效**：
       * ```text
       * 我这轮加的   「N 个源不可用」「全部正常」「已重新加载 N 个插件」
       * 原有的       「已停用」「顺序已保存」「已移除」
       * ```
       * 提示发出来了、用户看不见 = 等于没发。
       *
       * 修法用 `Sp.bottomBarInset` 而不是把数字调大：那个 token 的注释
       * 写着它的存在理由**就是这件事**（「给悬浮底栏让位」），
       * 且它已被 ListView 的 padding 用 —— 同一个值两边一致，
       * 而且 TV 自动取 110（写死 90 在 TV 上仍会被盖）。
       */
      expect(
        code.contains('bottom: Sp.bottomBarInset'),
        isTrue,
        reason: '★ toast 的 bottom 必须用 Sp.bottomBarInset 让开悬浮底栏',
      );
      expect(
        code.contains('bottom: Sp.x10'),
        isFalse,
        reason: '★ 不许退回写死的 40px —— 那会被底栏盖住（实测过）',
      );
    });

    test('★★ 导入成功后必须重新拉列表（同 id 覆盖语义）', () {
      /*
       * 后端 `import_declarative_provider` 是**同 id 覆盖**：
       * ```rust
       * list.retain(|x| x.id() != manifest.id);   // 先删旧的
       * list.push(PersistedProvider::Declarative { ... });
       * ```
       * 所以本地插入一条会**留下两条同名源**。必须重新拉。
       */
      expect(
        code.contains('await loadAll()'),
        isTrue,
        reason: '★ 导入/编辑后必须 loadAll()，不能本地插入',
      );
      expect(
        code.contains('widget.onProvidersChanged?.call()'),
        isTrue,
        reason: '★ 要通知首页刷新（源变了，首页分区要重拉）',
      );
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  项目铁律
  // ═══════════════════════════════════════════════════════════════════
  group('项目铁律', () {
    test('★★★ 新文件禁止 import package:flutter/material.dart', () {
      /*
       * Flutter 3.47 把 Material 从 SDK 里**拆成独立包** `material_ui`。
       * `package:flutter/material.dart` 仍然存在（同一 SDK 里两份源码），
       * 于是同一个 app 里可以**同时存在两套 Material** ——
       * 两套 `Theme` 串台，症状是颜色/对比度莫名其妙不对。
       *
       * 本项目实测踩过：设置页标题对比度只剩 **1.16:1**（不可读）。
       * 详见 `pubspec.yaml` 里 `material_ui` 那段注释 +
       * `test/material_split_test.dart`。
       */
      for (final f in [
        'lib/ui/widgets/provider_import_dialog.dart',
        'lib/ui/settings_page.dart',
        'lib/core/sourin_api.dart',
      ]) {
        final s = File(f).readAsStringSync();
        expect(
          s.contains("package:flutter/material.dart"),
          isFalse,
          reason: '★ $f 混用了两套 Material —— 必须统一 material_ui',
        );
      }
    });

    test('★ 新文件必须 import material_ui（不是别的 Material 来源）', () {
      final s = File('lib/ui/widgets/provider_import_dialog.dart').readAsStringSync();
      expect(
        s.contains("package:material_ui/material_ui.dart"),
        isTrue,
        reason: '★ 必须走 material_ui（与其余 35 个 UI 文件一致）',
      );
    });

    test('★★ 没有新增依赖（file_selector 已够用）', () {
      /*
       * 任务约束：禁止加新依赖。
       * 这个断言防的是"顺手引一个包"—— 本项目体积预算紧张
       *（release 7z 目标 50 MB，见 pubspec 注释）。
       */
      final pubspec = File('pubspec.yaml').readAsStringSync();
      for (final forbidden in ['file_picker', 'flutter_highlight', 'code_text_field']) {
        expect(
          pubspec.contains(forbidden),
          isFalse,
          reason: '★ 不应该引入 $forbidden',
        );
      }
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  纯函数行为（不碰 FFI，可真跑）
  // ═══════════════════════════════════════════════════════════════════
  group('parseHeaders（原版 :1440）', () {
    test('空 / 纯空白 → null（= 无自定义头）', () {
      /*
       * 原版：`const t = text.trim(); if (!t) return undefined;`
       *
       * 返回 null 而不是空 Map：Rust 侧是
       * `headers: Option<HashMap<String,String>>` —— 传缺省
       * 与传空对象语义不同（前者走"没头"，后者会覆盖成空）。
       */
      expect(parseHeaders(''), isNull);
      expect(parseHeaders('   \n  '), isNull);
    });

    test('★ 合法对象 → Map<String,String>', () {
      final h = parseHeaders('{"Authorization": "Bearer xxx", "X-A": 1}');
      expect(h, isNotNull);
      expect(h!['Authorization'], 'Bearer xxx');
      // 非字符串值会被 stringify（后端要 HashMap<String,String>）
      expect(h['X-A'], '1');
    });

    test('★★ 非法 JSON → 报错，且文案与原版逐字一致', () {
      /*
       * 原版：
       * ```ts
       * try { v = JSON.parse(t); }
       * catch { throw new Error("自定义头不是合法 JSON"); }
       * if (!v || typeof v !== "object" || Array.isArray(v))
       *   throw new Error('自定义头必须是 JSON 对象，如 {"Authorization":"Bearer xxx"}');
       * ```
       */
      expect(
        () => parseHeaders('{not json'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            '自定义头不是合法 JSON',
          ),
        ),
      );
    });

    test('★★ 是数组/标量 → 报错（必须是对象）', () {
      // `Array.isArray(v)` 那条守卫
      expect(
        () => parseHeaders('[1,2]'),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains('必须是 JSON 对象'),
          ),
        ),
      );
      expect(() => parseHeaders('123'), throwsA(isA<FormatException>()));
      expect(() => parseHeaders('"str"'), throwsA(isA<FormatException>()));
    });
  });

  group('ProviderImportSeed.fromJson（Rust PersistedProvider 契约）', () {
    test('★ declarative 形态', () {
      /*
       * Rust（`model.rs:1040`）：
       * ```rust
       * #[serde(tag = "kind", rename_all = "snake_case")]
       * pub enum PersistedProvider {
       *     Declarative { id: String, json: String },
       *     Http { id, base_url, #[serde(default)] headers },
       * }
       * ```
       */
      final s = ProviderImportSeed.fromJson({
        'kind': 'declarative',
        'id': 'demo',
        'json': '{"id":"demo"}',
      });
      expect(s, isNotNull);
      expect(s!.isDeclarative, isTrue);
      expect(s.isHttp, isFalse);
      expect(s.id, 'demo');
      expect(s.json, '{"id":"demo"}');
    });

    test('★ http 形态（含 headers）', () {
      final s = ProviderImportSeed.fromJson({
        'kind': 'http',
        'id': 'x',
        'base_url': 'http://127.0.0.1:8787',
        'headers': {'Authorization': 'Bearer t'},
      });
      expect(s, isNotNull);
      expect(s!.isHttp, isTrue);
      expect(s.baseUrl, 'http://127.0.0.1:8787');
      expect(s.headers['Authorization'], 'Bearer t');
    });

    test('★★ http 形态缺 headers → 空 Map（后端 `#[serde(default)]`）', () {
      /*
       * Rust 侧 headers 有 `#[serde(default)]` —— 所以**真的会缺**。
       * 不兜底会 NPE，而症状是"打开编辑弹窗就崩"。
       */
      final s = ProviderImportSeed.fromJson({
        'kind': 'http',
        'id': 'x',
        'base_url': 'http://a',
      });
      expect(s, isNotNull);
      expect(s!.headers, isEmpty);
    });

    test('★★★ kind 不认识 → null（不许默认当成声明式）', () {
      /*
       * 为什么要**正向列举** kind 而不是"默认当声明式"：
       * 后端将来加第三种形态时，误当成声明式会让用户看到一个
       * **空白的 JSON 编辑框**，点保存就把原源覆盖成一个坏配置。
       *
       * 返回 null → UI 不给「编辑」按钮 —— 这是**安全的失败方式**
       *（原版 `canEdit` 的注释也是这个思路：点了报错比不放更糟）。
       */
      expect(
        ProviderImportSeed.fromJson({'kind': 'wasm', 'id': 'x', 'json': '{}'}),
        isNull,
      );
      expect(
        ProviderImportSeed.fromJson({'kind': 'declarative', 'id': 'x'}),
        isNull,
        reason: 'declarative 缺 json → null（不是空串）',
      );
      expect(
        ProviderImportSeed.fromJson({'kind': 'http', 'id': 'x'}),
        isNull,
        reason: 'http 缺 base_url → null',
      );
      expect(ProviderImportSeed.fromJson({'id': 'x'}), isNull, reason: '缺 kind');
      expect(ProviderImportSeed.fromJson({'kind': 'declarative'}), isNull,
          reason: '缺 id');
    });
  });

  group('ProviderImportDone.toast（原版 flash 文案）', () {
    test('★ 声明式：导入 / 保存 —— **不**带契约版本', () {
      /*
       * 原版 `doImport`：
       * ```ts
       * flash(wasEditing ? `已保存「${m.name}」` : `已导入「${m.name}」`);
       * ```
       *
       * ⚠️ 声明式源**没有契约版本**这个概念（契约是 HTTP 源的）。
       *    它 manifest 里的 `version` 是用户在 JSON 里自己写的，
       *    拼上去会显示成"契约 v1.0" —— 那是误导。
       */
      const a = ProviderImportDone(
        name: '示例站',
        wasEditing: false,
        version: '1.0',
      );
      expect(a.toast, '已导入「示例站」');

      const b = ProviderImportDone(
        name: '示例站',
        wasEditing: true,
        version: '1.0',
      );
      expect(b.toast, '已保存「示例站」');
    });

    test('★ HTTP：安装 / 保存 —— 带「（契约 v…）」', () {
      /*
       * 原版 `doInstallHttp`：
       * ```ts
       * flash(wasEditing
       *   ? `已保存「${m.name}」（契约 v${m.api_version}）`
       *   : `已安装「${m.name}」（契约 v${m.api_version}）`);
       * ```
       */
      const a = ProviderImportDone(
        name: '我的服务',
        wasEditing: false,
        version: '1',
        isHttp: true,
      );
      expect(a.toast, '已安装「我的服务」（契约 v1）');

      const b = ProviderImportDone(
        name: '我的服务',
        wasEditing: true,
        version: '1',
        isHttp: true,
      );
      expect(b.toast, '已保存「我的服务」（契约 v1）');
    });
  });

  // 直接构造旧 seed 也必须关闭声明式提交；HTTP 回填和 TVBox 新增仍可用。
  group('导入入口与历史配置兼容（真渲染）', () {
    late List<String> commands;

    setUp(() {
      commands = [];
      SourinCore.debugCallAsyncTransport = (command, args) async {
        commands.add(command);
        throw StateError('Unexpected command: $command');
      };
    });

    tearDown(() {
      SourinCore.debugCallAsyncTransport = null;
    });

    Widget host(Widget child) {
      final theme = AppTheme.themeFor(Brightness.light);
      return MaterialApp(
        theme: theme,
        builder: (_, child) => AppThemeHost(data: theme, child: child!),
        home: child,
      );
    }

    Future<void> pumpDialog(
      WidgetTester tester, {
      ProviderImportSeed? seed,
      String? name,
    }) async {
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Stack(
              children: [
                ProviderImportDialog(seed: seed, editingName: name),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('直接传入旧声明式 seed 只显示停止支持提示且不可提交', (tester) async {
      const raw = '{"id":"old","base":"https://legacy.test"}';
      const seed = ProviderImportSeed(
        kind: 'declarative',
        id: 'old',
        json: raw,
      );
      await pumpDialog(tester, seed: seed, name: '旧源');

      expect(find.text('声明式源已停止支持'), findsOneWidget);
      expect(find.text('关闭'), findsOneWidget);
      expect(find.byType(ui.TextField), findsNothing);
      expect(find.byType(ui.FilledButton), findsNothing);
      expect(find.text('保存'), findsNothing);
      expect(find.text('导入并探测'), findsNothing);
      expect(find.text('可视化编排'), findsNothing);
      expect(find.text('填入模板'), findsNothing);
      expect(seed.json, raw);
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('未知 seed 不得回退成可提交的 TVBox 表单', (tester) async {
      await pumpDialog(
        tester,
        seed: const ProviderImportSeed(kind: 'future', id: 'unknown'),
      );
      expect(find.text('该源没有可编辑的配置'), findsOneWidget);
      expect(find.byType(ui.TextField), findsNothing);
      expect(find.byType(ui.FilledButton), findsNothing);
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('旧声明式 showEdit 可以关闭并返回纯取消', (tester) async {
      ProviderImportResult? result;
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Builder(
              builder: (context) => ui.TextButton(
                onPressed: () async {
                  result = await ProviderImportDialog.showEdit(
                    context,
                    seed: const ProviderImportSeed(
                      kind: 'declarative',
                      id: 'old',
                      json: '{broken json',
                    ),
                    name: '旧源',
                  );
                },
                child: const Text('EDIT'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('EDIT'));
      await tester.pumpAndSettle();
      expect(find.text('声明式源已停止支持'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(find.byType(ProviderImportDialog), findsNothing);
      expect(result, isA<ProviderImportCancelled>());
      expect((result as ProviderImportCancelled).done, isNull);
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HTTP 编辑保留 URL 和请求头回填及保存入口', (tester) async {
      await pumpDialog(
        tester,
        seed: const ProviderImportSeed(
          kind: 'http',
          id: 'http-old',
          baseUrl: 'http://127.0.0.1:8787',
          headers: {'Authorization': 'Bearer test'},
        ),
        name: 'HTTP 源',
      );
      final fields = tester.widgetList<ui.TextField>(find.byType(ui.TextField)).toList();
      expect(fields, hasLength(2));
      expect(fields[0].controller!.text, 'http://127.0.0.1:8787');
      expect(jsonDecode(fields[1].controller!.text), {'Authorization': 'Bearer test'});
      expect(find.text('编辑「HTTP 源」'), findsOneWidget);
      expect(find.text('TVBox 配置'), findsNothing);
      final save = tester.widget<ui.FilledButton>(
        find.widgetWithText(ui.FilledButton, '保存'),
      );
      expect(save.onPressed, isNotNull);
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('HTTP 空请求头保持空输入', (tester) async {
      await pumpDialog(
        tester,
        seed: const ProviderImportSeed(
          kind: 'http',
          id: 'http-old',
          baseUrl: 'http://127.0.0.1:8787',
        ),
      );
      final fields = tester.widgetList<ui.TextField>(find.byType(ui.TextField)).toList();
      expect(fields[1].controller!.text, isEmpty);
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('新增仅有 TVBox，主地址和备用地址初始为空', (tester) async {
      await pumpDialog(tester);
      expect(find.text('导入 TVBox 配置'), findsOneWidget);
      expect(find.text('TVBox 配置'), findsOneWidget);
      expect(find.textContaining('声明式'), findsNothing);
      expect(find.text('可视化编排'), findsNothing);
      expect(find.text('填入模板'), findsNothing);
      final fields = tester.widgetList<ui.TextField>(find.byType(ui.TextField));
      expect(fields, hasLength(3));
      expect(fields.every((field) => field.controller!.text.isEmpty), isTrue);
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('关闭 HTTP 编辑后新增不携带旧配置', (tester) async {
      await tester.pumpWidget(
        host(
          Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  ui.TextButton(
                    onPressed: () => ProviderImportDialog.showEdit(
                      context,
                      seed: const ProviderImportSeed(
                        kind: 'http',
                        id: 'a',
                        baseUrl: 'http://127.0.0.1:8787',
                        headers: {'X-Test': 'old'},
                      ),
                      name: '源 A',
                    ),
                    child: const Text('EDIT'),
                  ),
                  ui.TextButton(
                    onPressed: () => ProviderImportDialog.showAdd(context),
                    child: const Text('ADD'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('EDIT'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<ui.TextField>(find.byType(ui.TextField).first).controller!.text,
        'http://127.0.0.1:8787',
      );
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('ADD'));
      await tester.pumpAndSettle();
      expect(find.text('导入 TVBox 配置'), findsOneWidget);
      final fields = tester.widgetList<ui.TextField>(find.byType(ui.TextField));
      expect(fields, hasLength(3));
      expect(fields.every((field) => field.controller!.text.isEmpty), isTrue);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('TVBox 提交可用性跟随主地址输入', (tester) async {
      await pumpDialog(tester);
      ui.FilledButton submitButton() => tester.widget<ui.FilledButton>(
        find.widgetWithText(ui.FilledButton, '导入并探测'),
      );
      expect(submitButton().onPressed, isNull);
      await tester.enterText(
        find.byKey(const ValueKey('source-address-primary')),
        'https://config.test/tvbox.json',
      );
      await tester.pumpAndSettle();
      expect(submitButton().onPressed, isNotNull);
      await tester.enterText(find.byKey(const ValueKey('source-address-primary')), '  ');
      await tester.pumpAndSettle();
      expect(submitButton().onPressed, isNull);
      expect(commands, isEmpty);
      expect(tester.takeException(), isNull);
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  API 层：包装的参数名必须与 Rust 契约一致
  // ═══════════════════════════════════════════════════════════════════
  group('sourin_api.dart 的命令与参数名', () {
    late String code;

    setUpAll(() {
      code = _code(File('lib/core/sourin_api.dart').readAsStringSync());
    });

    test('★★ getProviderImportSeed 用 get_provider_config + 参数 id', () {
      /*
       * Rust/FFI（`ffi.rs:1248`）：
       * ```rust
       * "get_provider_config" => { let id = a.str("id")?; ... }
       * ```
       * 参数名写错 → `a.str("id")` 报错，或（更糟）静默拿到默认值。
       */
      expect(code.contains("'get_provider_config'"), isTrue);
      expect(code.contains("{'id': id}"), isTrue);
    });

    test('★★★ 必须用 jmapOrNull 而不是 jmap（后端返回 Option）', () {
      /*
       * 后端签名是 `Result<Option<PersistedProvider>, String>` ——
       * **内置源返回 JSON null**，那是正常情况不是错误。
       *
       * `jmap` 对 null 会抛「期望对象，实际收到 Null」，
       * 症状是"点内置源的编辑就报错"。
       *
       * ⚠️ 这个坑在本文件里已经踩过**三次**
       *（getProgress / getSkipMarker / providerSession）——
       *    所以这里专门钉一条断言。
       */
      final fn = code.substring(
        code.indexOf('getProviderImportSeed'),
        code.indexOf('getProviderImportSeed') + 400,
      );
      expect(
        fn.contains('jmapOrNull(r)'),
        isTrue,
        reason: '★ Option 返回必须用 jmapOrNull，用 jmap 会在 null 时抛异常',
      );
      expect(
        fn.contains('jmap(r)'),
        isFalse,
        reason: '★ 不能退回 jmap',
      );
    });

    test('★ 四个命令包装都存在（原版 index.ts 的对照）', () {
      /*
       * ⚠️ 更正一条审计措辞：这 4 个命令的**包装一直都有**，
       *    缺的是 UI 入口。这里断言包装在，是为了防止
       *    "补 UI 时误删/改名"。
       * ```text
       * 原版 src/api/index.ts:99   order()             → get_provider_order
       * 原版 src/api/index.ts:102  importDeclarative() → import_declarative_provider
       * 原版 src/api/index.ts:111  installHttp()       → install_http_provider
       * 原版 src/api/index.ts:125  config()            → get_provider_config
       * ```
       */
      for (final cmd in [
        "'get_provider_order'",
        "'import_declarative_provider'",
        "'install_http_provider'",
        "'get_provider_config'",
        "'health_sweep'",
        "'reload_plugins'",
      ]) {
        expect(code.contains(cmd), isTrue, reason: '缺命令包装 $cmd');
      }
    });
  });
  // ═══════════════════════════════════════════════════════════════════
  //  B4（CodeRabbit PR#5）：FilledButton 内的加载指示器取色**对比度门禁**
  // ═══════════════════════════════════════════════════════════════════
  //
  // # 意见原文（PR#5）
  // ```text
  // `CircularProgressIndicator(color: colors.onPrimary)` 在 FilledButton 内
  // 与按钮前景同色 ⇒ 对比度可能不足；建议改 `colors.onSurface`。
  // ```
  //
  // # ★ 核实结果：**误报**（onPrimary 才是对的，onSurface 反而不可读）
  //
  // FilledButton 的实心底**就是** `primary`（见 theme_bridge.dart `_shared` 里
  // `backgroundNColor: dim(c.primary, …)`），而 `onPrimary == primaryForeground`
  // 正是"主色之上的前景"（app_palette.dart `toColorScheme`）。实测 WCAG 对比度：
  // ```text
  //   深色  onPrimary(#171717) on 主色(#E5E5E5) = 14.23:1  ✅ 远超 3:1（非文字）
  //   浅色  onPrimary(#FFFFFF) on 主色(#3B6FE0) =  4.63:1  ✅
  //   若改成 onSurface：
  //   深色  onSurface(#FAFAFA) on #E5E5E5 = 1.21:1  ✗ 几乎不可见
  //   浅色  onSurface(#1E2028) on #3B6FE0 = 3.51:1  ✗ 低于 4.5
  // ```
  // ⇒ 采纳建议会**制造**对比度缺陷。本组两个用例把"为什么必须用 onPrimary"
  //   钉成门禁：① 两个主题下 onPrimary/主色 ≥ 3:1；② onPrimary 严格优于
  //   onSurface（防未来被"顺手改成 onSurface"）。
  group('B4 加载指示器取色对比度（PR#5 意见的核实）', () {
    double linC(double c) {
      final n = c / 255.0;
      return n <= 0.03928 ? n / 12.92 : math.pow((n + 0.055) / 1.055, 2.4).toDouble();
    }

    double lumC(Color c) =>
        0.2126 * linC(c.r * 255) + 0.7152 * linC(c.g * 255) + 0.0722 * linC(c.b * 255);

    double contrastC(Color a, Color b) {
      final la = lumC(a), lb = lumC(b);
      final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
      return (hi + 0.05) / (lo + 0.05);
    }

    test('两个主题下 onPrimary 对 FilledButton 实心底(primary) ≥ 3:1', () {
      for (final b in [Brightness.dark, Brightness.light]) {
        final cs = AppTheme.themeFor(b).colorScheme;
        final r = contrastC(cs.onPrimary, cs.primary);
        // ignore: avoid_print
        print('B4 读数：${b.name} onPrimary=${cs.onPrimary} primary=${cs.primary} '
            '对比度=${r.toStringAsFixed(2)}:1');
        expect(r, greaterThanOrEqualTo(3.0),
            reason: '★ ${b.name} 下加载指示器（onPrimary）对实心底 '
                '对比度 ${r.toStringAsFixed(2)}:1 < 3:1 ⇒ 用户看不清转圈');
      }
    });

    test('★ onPrimary 严格优于 onSurface（钉死"为什么不是 onSurface"）', () {
      for (final b in [Brightness.dark, Brightness.light]) {
        final cs = AppTheme.themeFor(b).colorScheme;
        final onP = contrastC(cs.onPrimary, cs.primary);
        final onS = contrastC(cs.onSurface, cs.primary);
        // ignore: avoid_print
        print('B4 读数：${b.name} onPrimary=${onP.toStringAsFixed(2)}:1 '
            'onSurface=${onS.toStringAsFixed(2)}:1');
        expect(onP, greaterThan(onS),
            reason: '★ ${b.name} 下 onPrimary(${onP.toStringAsFixed(2)}:1) 必须优于 '
                'onSurface(${onS.toStringAsFixed(2)}:1) —— PR#5 建议的 onSurface '
                '在本主题上**更差**，采纳它就是制造对比度缺陷');
      }
    });

    for (final brightness in Brightness.values) {
      for (final isHttp in [false, true]) {
        testWidgets('${brightness.name} ${isHttp ? 'HTTP 保存' : 'TVBox 导入'}的真实加载指示器使用 onPrimary', (tester) async {
          final pending = Completer<dynamic>();
          final commands = <String>[];
          final expectedCommand = isHttp ? 'install_http_provider' : 'import_tvbox_config';
          SourinCore.debugCallAsyncTransport = (command, args) {
            commands.add(command);
            expect(command, expectedCommand);
            return pending.future;
          };
          addTearDown(() => SourinCore.debugCallAsyncTransport = null);
          final theme = AppTheme.themeFor(brightness);
          await tester.pumpWidget(
            _providerTestHost(
              Scaffold(
                body: Builder(
                  builder: (context) => ui.TextButton(
                    onPressed: () => isHttp
                        ? ProviderImportDialog.showEdit(
                            context,
                            seed: const ProviderImportSeed(
                              kind: 'http',
                              id: 'http-test',
                              baseUrl: 'http://127.0.0.1:8787',
                              headers: {'X-Test': 'value'},
                            ),
                            name: 'HTTP 测试源',
                          )
                        : ProviderImportDialog.showAdd(context),
                    child: const Text('OPEN'),
                  ),
                ),
              ),
              brightness: brightness,
            ),
          );
          await tester.tap(find.text('OPEN'));
          await tester.pumpAndSettle();
          if (!isHttp) {
            await tester.enterText(
              find.byKey(const ValueKey('source-address-primary')),
              'https://configuration.invalid/tvbox.json',
            );
            await tester.pump();
          }
          final dialog = find.byType(ProviderImportDialog);
          final submit = find.descendant(of: dialog, matching: find.byType(ui.FilledButton));
          expect(tester.widget<ui.FilledButton>(submit).onPressed, isNotNull);
          await tester.tap(submit);
          await tester.pump();
          expect(commands, [expectedCommand]);
          final spinner = find.descendant(of: submit, matching: find.byType(ui.CircularProgressIndicator));
          await _pumpUntilFound(
            tester,
            spinner,
            reason: '请求未完成时，提交按钮必须在 1.5 秒内显示加载指示器',
          );
          expect(tester.widget<ui.FilledButton>(submit).onPressed, isNull);
          expect(spinner, findsOneWidget);
          expect(tester.widget<ui.CircularProgressIndicator>(spinner).color, theme.colorScheme.onPrimary);
          final nativeSpinner = tester.widget<miuix.MiuixCircularProgressIndicator>(
            find.descendant(of: submit, matching: find.byType(miuix.MiuixCircularProgressIndicator)),
          );
          expect(nativeSpinner.colors!.foregroundColor, theme.colorScheme.onPrimary);
          for (final field in tester.widgetList<ui.TextField>(find.descendant(of: dialog, matching: find.byType(ui.TextField)))) {
            expect(field.enabled, isFalse);
          }
          expect(
            tester.widget<ui.TextButton>(find.widgetWithText(ui.TextButton, '取消')).onPressed,
            isNull,
          );
          expect(tester.widget<AppDialogShell>(find.descendant(of: dialog, matching: find.byType(AppDialogShell))).onClose, isNull);
          pending.completeError(StateError('结束模拟请求'));
          await tester.pumpAndSettle();
          expect(spinner, findsNothing);
          expect(tester.widget<ui.FilledButton>(submit).onPressed, isNotNull);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(find.byType(ProviderImportDialog), findsNothing);
          expect(tester.takeException(), isNull);
        });
      }
    }
  });
}
