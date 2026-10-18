// ══════════════════════════════════════════════════════════════════════
//  门禁：读取跳过点的三态 —— 「读取失败」不许伪装成「未设置」
// ══════════════════════════════════════════════════════════════════════
//
// 2026-10-18 第 66 轮。
//
// # 守的是什么
//
// ```text
// 改前：_loading 只有两态，「读取失败」被塞进"读完了"那一档，
//       四个值保持 null ⇒ UI 画成「片头未设 / 片尾未设」
//       ⇒ 与「用户从没设过」在屏幕上一模一样
//       ⇒ 用户以为配置丢了，很可能重设一遍 ⇒ **覆盖真实配置**
// 改后：三态 loading / ok / failed，
//       failed 走独立分支（错误 + 重试），绝不渲染"未设置"
// ```
//
// # 为什么必须有「阴性对照」（第④条）
//
// ```text
// 如果只测"失败时不显示未设置"，把 UI 改成什么都不显示也能过。
// ⇒ 必须同时测"真·未设置时要显示未设置"，
//   两条成对才证明：**这是两种不同的显示**，而不是一种被删掉了。
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';
import 'package:sourin_spike/core/models.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 打开弹窗，但不等待 `_loadExisting` 完成（让调用方控制时序）
Future<void> _open(WidgetTester t) async {
  t.view.physicalSize = const Size(1280, 800);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  await t.pumpWidget(_host(Builder(
    builder: (ctx) => ElevatedButton(
      onPressed: () => showDialog<SkipMarkerResult>(
        context: ctx,
        barrierDismissible: false,
        builder: (_) => const SkipMarkerDialog(
          provider: 'p',
          id: '1',
          title: 'T',
          streamUrl: 'file:///nonexistent.mp4',
          duration: Duration(seconds: 600),
        ),
      ),
      child: const Text('open'),
    ),
  )));
  await t.tap(find.text('open'));
  await t.pump();
  await t.pump(const Duration(milliseconds: 50));
}

/// 弹窗里「未设置」的文案（四行默认态会显示这个）
const _kUnset = '片头未设';

void main() {
  tearDown(() {
    // 每个用例后复位，避免串扰
    SourinApi.debugSkipMarkerFetcher = null;
  });

  // ══════════════════════════════════════════════════════════════════
  //  ① 正常返回 ⇒ ok 态，四行渲染
  // ══════════════════════════════════════════════════════════════════
  testWidgets('① 正常返回 ⇒ ok 态，四行标签都在', (t) async {
    SourinApi.debugSkipMarkerFetcher = (provider, id) async => null;

    await _open(t);
    await t.pump(const Duration(milliseconds: 50));

    for (final label in ['片头开始', '片头结束', '片尾开始', '片尾结束']) {
      expect(find.text(label), findsOneWidget,
          reason: 'ok 态下「$label」必须渲染');
    }
    // ok + null ⇒ 这里**应该**显示"未设置"（真·未设置）
    expect(find.textContaining(_kUnset), findsWidgets,
        reason: 'ok 态且值为 null ⇒ 这才是真的"未设置"');
    // 不该有错误面板
    expect(find.text('重试'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 超时 ⇒ failed 态，且**不出现**「未设置」
  //     ★ 本文件最关键的一条
  // ══════════════════════════════════════════════════════════════════
  testWidgets('② 超时 ⇒ failed 态，UI 上不出现「未设置」', (t) async {
    // 永不完成 ⇒ 触发 10 秒超时
    SourinApi.debugSkipMarkerFetcher = (provider, id) =>
        Completer<SkipMarker?>().future;

    await _open(t);

    // 推进超过超时时长（10s）—— 但不必真等 10 秒，
    // fake async 下 pump 会推进时钟
    await t.pump(const Duration(seconds: 11));
    await t.pump(const Duration(milliseconds: 100));

    // ★ 关键断言：失败时**绝不能**画成"未设置"
    expect(find.textContaining(_kUnset), findsNothing,
        reason: '★★★ 读取失败时**不许**显示「未设置」—— '
            '否则用户会以为配置丢了并重设，覆盖真实配置');

    // 四行标签也不该出现（它们属于 ok 态）
    expect(find.text('片头开始'), findsNothing,
        reason: '失败态不是"正常的空状态"，四行不该渲染');

    // 必须有错误说明 + 重试出路
    expect(find.textContaining('读取跳过点失败'), findsWidgets,
        reason: '失败必须如实说明，不能静默');
    expect(find.text('重试'), findsWidgets,
        reason: '必须给用户出路');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 重试 ⇒ 重新调用 fetcher，成功后进 ok 态
  // ══════════════════════════════════════════════════════════════════
  testWidgets('③ 重试按钮真的重新发请求，成功后进 ok 态', (t) async {
    var calls = 0;
    SourinApi.debugSkipMarkerFetcher = (provider, id) {
      calls++;
      if (calls == 1) return Completer<SkipMarker?>().future; // 第一次挂住
      return Future.value(null); // 第二次成功
    };

    await _open(t);
    await t.pump(const Duration(seconds: 11));
    await t.pump(const Duration(milliseconds: 100));
    expect(find.text('重试'), findsWidgets, reason: '先进入失败态');
    expect(calls, 1, reason: '到这时只调了一次');

    // 点重试
    await t.tap(find.text('重试'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 50));

    expect(calls, 2, reason: '★★ 重试必须**真的**重新调用 fetcher，'
        '只改状态不重发请求等于按钮没作用');
    // 成功后回到 ok 态：四行出现
    expect(find.text('片头开始'), findsOneWidget,
        reason: '重试成功后必须进 ok 态');
    expect(find.text('重试'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ ★ 阴性对照：真·未设置 ⇒ 必须显示「未设置」
  //     与 ② 成对，证明两种状态是**不同**的显示
  // ══════════════════════════════════════════════════════════════════
  testWidgets('④ 阴性对照：真·未设置 ⇒ 显示「未设置」（与②成对）', (t) async {
    // 返回 null = 核心层明确回答"没有跳过点"（与超时完全不同）
    SourinApi.debugSkipMarkerFetcher = (provider, id) async => null;

    await _open(t);
    await t.pump(const Duration(milliseconds: 50));

    expect(find.textContaining(_kUnset), findsWidgets,
        reason: '★★ 真·未设置**必须**显示「未设置」—— '
            '若这条也红，说明 ② 的"不显示"只是因为 UI 被删空了，不是真的区分了两种状态');
    expect(find.textContaining('读取跳过点失败'), findsNothing,
        reason: '未设置不是失败，不该报错');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ 源码级：failed 分支不许被并进 ok 分支
  // ══════════════════════════════════════════════════════════════════
  test('⑤ 源码级：switch 必须三分支，且 failed 走独立面板', () {
    final src = File('lib/ui/widgets/skip_marker_dialog.dart')
        .readAsStringSync();

    // 三态必须都在 switch 里
    expect(src.contains('_LoadState.loading =>'), isTrue);
    expect(src.contains('_LoadState.failed =>'), isTrue);
    expect(src.contains('_LoadState.ok =>'), isTrue);

    // failed 必须走独立面板（而不是回退到正常渲染）
    expect(src.contains('_loadFailedPanel('), isTrue,
        reason: 'failed 必须有独立的渲染分支');

    // 超时必须真的接上（不是定义了个常量不用）
    expect(
      RegExp(r'\.timeout\(_kLoadTimeout\)').hasMatch(src),
      isTrue,
      reason: '★★ 光定义 _kLoadTimeout 不算接线 —— 必须真的 .timeout() 它',
    );

    // 重试必须真的重新调用 _loadExisting
    expect(
      RegExp(r'void _retryLoad\(\)[\s\S]{0,300}?_loadExisting\(\)')
          .hasMatch(src),
      isTrue,
      reason: '重试必须重新发请求',
    );
  });
}
