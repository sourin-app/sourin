// ══════════════════════════════════════════════════════════════════════
//  门禁：写路径（保存 / 重置）—— 失败不许伪装成成功
// ══════════════════════════════════════════════════════════════════════
//
// 2026-10-18 第 66 轮。
//
// # 守的是什么
//
// ```text
// 改前 _reset()：
//   try { await clearSkipMarker(...) } catch (e) { debugPrint(...) }  // 只记日志
//   setState(四值全清)        ← 失败也清
//   _toast('已重置')          ← ★ 失败也报"已重置"
//
// ⇒ 用户以为清掉了，实际根本没删
// ⇒ 下次打开发现跳过点还在 ⇒ 判定"这软件有 bug"
// ★ 重置是**删数据**的操作 ⇒ 静默失败不只是体验问题，是隐私风险
// ```
//
// # 第④条为什么是关键
//
// ```text
// 它不仅要求"失败时不报成功"，还要求"失败后 UI 显示**服务器真实状态**"。
// ⇒ 本地值不可信（可能上游刚被改过、可能是上次超时留下的陈旧值）
// ⇒ 失败后必须重读服务器
// ```

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/app_scaffold.dart';
import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/widgets/skip_marker_dialog.dart';

Widget _host(Widget child) {
  final theme = AppTheme.themeFor(Brightness.light);
  return MaterialApp(
    theme: theme,
    builder: (_, c) => AppThemeHost(data: theme, child: c ?? const SizedBox()),
    home: Scaffold(body: child),
  );
}

/// 打开弹窗（读已成功，四值 = null 的"未设置"态）
///
/// [setDefaultFetcher] = false 时**不覆盖**调用方已设的 fetcher
/// （④ 需要自定义"首次读到 null、第二次读到真值"的序列）。
Future<void> _open(WidgetTester t, {bool setDefaultFetcher = true}) async {
  t.view.physicalSize = const Size(1400, 900);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.reset);

  // 读路径用 fake 保证快且稳（本文件不测读路径）
  if (setDefaultFetcher) {
    SourinApi.debugSkipMarkerFetcher = (provider, id) async => null;
  }

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

void main() {
  tearDown(() {
    SourinApi.debugSkipMarkerFetcher = null;
    SourinApi.debugSkipMarkerWriter = null;
    SourinApi.debugSkipMarkerClearer = null;
  });

  // ══════════════════════════════════════════════════════════════════
  //  ① 保存超时 ⇒ 失败态 + _saving 复位（按钮回到可点）
  // ══════════════════════════════════════════════════════════════════
  testWidgets('① 保存超时 ⇒ 显式失败 + _saving 复位（按钮恢复可点）', (t) async {
    SourinApi.debugSkipMarkerWriter = ({String? title, int? introStart,
            int? introEnd, int? outroStart, int? outroEnd, bool? autoSkip}) =>
        Completer<void>().future; // 永不完成

    await _open(t);
    expect(find.text('确认设置'), findsOneWidget);

    await t.tap(find.text('确认设置'));
    await t.pump();
    // 保存中：按钮应禁用（_canSave == false）
    expect(find.text('保存中…'), findsOneWidget);

    // 推进超过 10 秒超时
    await t.pump(const Duration(seconds: 11));
    await t.pump(const Duration(milliseconds: 100));

    // ★ 超时后必须复位 ⇒ 文案回到「确认设置」
    expect(find.text('保存中…'), findsNothing,
        reason: '★★ 超时后必须复位 _saving，否则按钮永久「保存中…」');
    expect(find.text('确认设置'), findsOneWidget,
        reason: '复位后按钮文案应回到正常态');

    // 必须有失败说明（底栏 _saveError 的实际文案是「核心层 N 秒无响应」）
    expect(find.textContaining('无响应'), findsWidgets,
        reason: '★★ 超时必须如实说（底栏 _saveError）');
    // 且绝不能显示「已保存」「成功」这类词
    expect(find.textContaining('已保存'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ② 阴性对照：保存成功 ⇒ 正常关闭
  // ══════════════════════════════════════════════════════════════════
  testWidgets('② 阴性对照：保存成功 ⇒ 弹窗正常关闭（没被失败态弄坏）', (t) async {
    var called = 0;
    SourinApi.debugSkipMarkerWriter = ({String? title, int? introStart,
        int? introEnd, int? outroStart, int? outroEnd, bool? autoSkip}) async {
      called++;
    };

    await _open(t);
    await t.tap(find.text('确认设置'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));

    expect(called, 1, reason: '必须真的调用了 writer');
    // 成功后应该 pop 掉弹窗
    expect(find.text('确认设置'), findsNothing,
        reason: '★★ 成功后弹窗应关闭 —— 这条防"加了失败态把成功态弄坏"');
    expect(find.textContaining('失败'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ③ 重置超时 ⇒ **不显示「已重置」**
  // ══════════════════════════════════════════════════════════════════
  testWidgets('③ 重置超时 ⇒ 绝不显示「已重置」', (t) async {
    SourinApi.debugSkipMarkerClearer = () => Completer<void>().future;

    await _open(t);
    await t.tap(find.text('重置'));
    await t.pump();
    expect(find.text('重置中…'), findsOneWidget);

    await t.pump(const Duration(seconds: 11));
    await t.pump(const Duration(milliseconds: 100));

    // ★ 最关键的断言
    expect(find.text('已重置'), findsNothing,
        reason: '★★★ 重置失败时**绝不**能说「已重置」—— '
            '用户会以为删掉了，实际没删（隐私风险）');
    // 必须显式说失败
    expect(find.textContaining('重置失败'), findsWidgets,
        reason: '失败必须如实说');
    // 组件要复位
    expect(find.text('重置中…'), findsNothing,
        reason: '超时后必须复位 _resetting');
  });

  // ══════════════════════════════════════════════════════════════════
  //  ④ ★★★ 重置失败 ⇒ UI 显示**服务器真实值**（本地值不可信）
  // ══════════════════════════════════════════════════════════════════
  testWidgets('④ 重置失败 ⇒ 重读服务器，UI 显示真实值（不是本地猜的）', (t) async {
    // 场景：服务器上**还有**跳过点（片头开始 = 12）
    //       → 清除**失败**
    //       → 若只"保留本地值"或"清空本地值"都会显示错
    //       → 唯一正确：重读 ⇒ 又读到 12 ⇒ UI 显示 12

    // 首次读：先给一个"看起来没有"的状态（模拟陈旧/失败过的读）
    var readCount = 0;
    SourinApi.debugSkipMarkerFetcher = (provider, id) async {
      readCount++;
      // 第 1 次（打开弹窗）：被当作"未设置"
      // 第 2 次（重置失败后重读）：返回服务器的真实值
      if (readCount == 1) return null;
      return const SkipMarker(
        key: 'p::1',
        provider: 'p',
        nativeId: '1',
        introStart: 12,
        introEnd: 30,
      );
    };
    SourinApi.debugSkipMarkerClearer = () async {
      throw Exception('核心层拒绝');
    };

    await _open(t, setDefaultFetcher: false);
    await t.pump(const Duration(milliseconds: 100));

    // 记下"打开弹窗"时已经发生的读次数
    final beforeClear = readCount;

    await t.tap(find.text('重置'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));
    await t.pump(const Duration(milliseconds: 100));

    // ★ 必须重读 —— 用"次数必须恰好 +1"而不是 greaterThan，
    //   否则 beforeClear 若已是 1、重读没发生时 greaterThan(1) 仍为 false，
    //   但若中间有别的读混进来，greaterThan 可能被"别的读"满足而**假绿**
    //   （实测过：把"失败后重读"整段删掉，greaterThan 版本仍然全绿）
    expect(readCount, beforeClear + 1,
        reason: '★★ 重置失败后**必须恰好重新读取一次**——'
            '本地值不可信（可能上游刚改过，或上次超时留下陈旧值）');

    // ★ UI 必须显示服务器的真实值 00:12
    expect(find.text('00:12'), findsOneWidget,
        reason: '★★★ 重置失败后 UI 必须显示**服务器真实值**（片头开始=12s），'
            '而不是本地保留值、更不是清空。'
            '这条证明"失败后 UI 不撒谎"');

    // 且绝不能显示"已重置"
    expect(find.text('已重置'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑤ 阴性对照：重置成功 ⇒ 显示「已重置」+ 本地清空
  // ══════════════════════════════════════════════════════════════════
  testWidgets('⑤ 阴性对照：重置成功 ⇒ 显示「已重置」且本地清空', (t) async {
    var cleared = 0;
    SourinApi.debugSkipMarkerClearer = () async {
      cleared++;
    };

    await _open(t);
    await t.pump(const Duration(milliseconds: 100));
    await t.tap(find.text('重置'));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100));

    expect(cleared, 1, reason: '必须真的调用了 clearer');

    /*
     * ★ 不测 toast「已重置」—— 测试宿主没有 ToastHost，
     *   `showAppToast` 在那里是静默 no-op（设计如此）。
     *   改用**可见的 UI 结果**：重置成功后四值被清空 ⇒ 显示「片头未设」。
     *   这比断言一个可能在无宿主时被吞掉的 toast 可靠得多。
     */
    expect(find.textContaining('片头未设'), findsWidgets,
        reason: '★★ 重置成功后四值必须清空（UI 显示「片头未设」）—— '
            '这条与④成对：④是"失败后显示真实值"，⑤是"成功后真的清空"');
    // 成功不该留下失败文案
    expect(find.textContaining('重置失败'), findsNothing);
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑥ 源码级：超时必须真接线（不只是定义常量）
  // ══════════════════════════════════════════════════════════════════
  test('⑥ 源码级：保存与重置都真的 .timeout()，且失败分支存在', () {
    final src =
        File('lib/ui/widgets/skip_marker_dialog.dart').readAsStringSync();

    // 保存路径超时
    expect(
      RegExp(r'setSkipMarker\([\s\S]{0,400}?\.timeout\(_kLoadTimeout\)')
          .hasMatch(src),
      isTrue,
      reason: '★★ setSkipMarker 必须真的 .timeout()（定义常量不算接线）',
    );
    // 重置路径超时
    expect(
      RegExp(r'clearSkipMarker\([^)]*\)\s*\n?\s*\.timeout\(_kLoadTimeout\)')
          .hasMatch(src),
      isTrue,
      reason: '★★ clearSkipMarker 必须真的 .timeout()',
    );
    // 重置失败分支必须重读
    expect(
      RegExp(r'重置失败[\s\S]{0,700}?_loadExisting\(\)').hasMatch(src),
      isTrue,
      reason: '★★★ 重置失败后必须重读服务器真实状态',
    );
    // 不许再有"失败也报已重置" —— 必须先剥掉注释行，否则会命中文档里的示例
    final codeOnly = src
        .split('\n')
        .where((l) {
          final t = l.trimLeft();
          return !t.startsWith('//') &&
              !t.startsWith('*') &&
              !t.startsWith('/*');
        })
        .join('\n');
    expect(
      RegExp(r"catch \(e\) \{[\s\S]{0,200}?_toast\('已重置'\)")
          .hasMatch(codeOnly),
      isFalse,
      reason: '★★★ 不许在 catch 里报「已重置」（已剥注释，防命中文档示例）',
    );
  });

  // ══════════════════════════════════════════════════════════════════
  //  ⑦ ★ 保存进行中**不许**显示「区间不合法」
  // ══════════════════════════════════════════════════════════════════
  testWidgets('⑦ 保存进行中不显示「区间不合法」（假报错）', (t) async {
    SourinApi.debugSkipMarkerWriter = ({String? title, int? introStart,
            int? introEnd, int? outroStart, int? outroEnd, bool? autoSkip}) =>
        Completer<void>().future;

    await _open(t);
    // 打开时区间是合法的（没有不合法组合）⇒ 本来就不该显示这句
    expect(find.textContaining('区间不合法'), findsNothing);

    await t.tap(find.text('确认设置'));
    await t.pump();

    // ★ 保存中（_canSave == false 因为 _saving），但**输入是合法的**
    expect(find.textContaining('区间不合法'), findsNothing,
        reason: '★★ 保存进行中不许显示「区间不合法」—— '
            '此时区间明明是合法的（用户刚因为合法才点的保存）。'
            '改前 _canSave 混了"是否在忙"⇒ 这里会闪假报错');
    expect(find.text('保存中…'), findsOneWidget);

    // 收尾：把 10 秒超时定时器跑完，避免 "Pending timers" 让测试失败
    // （那不是断言失败，是 fake async 的卫生要求）
    await t.pump(const Duration(seconds: 11));
    await t.pump(const Duration(milliseconds: 100));
  });
}
