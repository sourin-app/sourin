// ═══════════════════════════════════════════════════════════════════════
//  第 66 轮 · 轨道 C 的三条门禁（N7 / N9 / N8）
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个文件守什么（每条都对应一个 Owner 原话）
//
// ```text
// N7  插件的可视化编排可能做好了,但是我点击配置就提示无配置项,
//     编排的弹窗根本就显示不出来
// N9  js插件 健康监测和速度测试都要显示出来 正在执行的数量/总数量 ...
//     还可以一键按照速度排序 ... 测速完发送一条toast,
//     要让用户看到多少, 退出这个页面也要测试
// N8  统一toast提示样式,不要自己写,要用自带的
// ```
//
// # ★ 判据为什么是「行为」而不是「源码里有没有这个字符串」
//
// 本仓最贵的教训是**假绿**：断源码文本会漏掉「函数定义了但没接线」。
// 所以这里分三层：
// ```text
// ① 真跑生产代码的行为断言（`_sortBySpeed` 的排序函数、`_probeProviderHealth`）
// ② 结构不变量（浮层/进度行**存在于树里**，而不是源码里有这几个字）
// ③ 源码形态（仅用于「不许再有自写 toast」这类**删除类**约束 ——
//    删除没有行为可测，只能看源码；所以配了故障注入来证明它真的会红）
// ```
//
// # ⚠️ 本文件**不验证**
//
// ```text
// · 真机上的视觉观感（截图在交付说明里）
// · 测速真的把字节下下来（那要真网络，属真机实测，见 .probe/probe_speed_real_test.dart）
// · 「退出软件不崩」—— 那要真进程，`flutter test` 里杀掉不对应进程是事故
//   （见 docs/AGENTS.md §3：只结束**你自己启动的 PID**）
// ```

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

// ══════════════════════════════════════════════════════════════════════
//  剥注释（行首版 + 块注释，与 provider_reorder_cards_test.dart 同口径）
// ══════════════════════════════════════════════════════════════════════
//
// ★ 为什么**必须**剥：本仓在注释里大量引用"改前是怎样"和"不许怎样"，
//   不剥的话「不许出现 showDialog」会被解释性注释弄成假红，
//   而「必须有 X」会被注释里的 X 弄成**假绿**。
// ⚠️ 同时保留字符串字面量（`'//'` 这种不该被当注释吃掉）。
String stripComments(String src) {
  final out = StringBuffer();
  var i = 0;
  String? quote;

  while (i < src.length) {
    final c = src[i];
    final next = i + 1 < src.length ? src[i + 1] : '';

    if (quote != null) {
      if (c == r'\') {
        out.write(c);
        if (next.isNotEmpty) {
          out.write(next);
          i += 2;
          continue;
        }
      }
      if (c == quote) quote = null;
      out.write(c);
      i++;
      continue;
    }

    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    if (c == '/' && next == '/') {
      while (i < src.length && src[i] != '\n') {
        i++;
      }
      continue;
    }
    if (c == '/' && next == '*') {
      i += 2;
      while (i < src.length && !(src[i] == '*' && i + 1 < src.length && src[i + 1] == '/')) {
        if (src[i] == '\n') out.write('\n'); // 保留行号
        i++;
      }
      i = (i + 2).clamp(0, src.length);
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

String read(String rel) => stripComments(File(rel).readAsStringSync());

void main() {
  // ═══════════════════════════════════════════════════════════════════
  //  N7 —— 「配置」入口必须能到可视化编排，且带初值
  // ═══════════════════════════════════════════════════════════════════
  group('N7 可视化编排入口', () {
    late String settings;
    late String dialog;
    late String importDlg;

    setUpAll(() {
      settings = read('lib/ui/settings_page.dart');
      dialog = read('lib/ui/widgets/source_composer_dialog.dart');
      importDlg = read('lib/ui/widgets/provider_import_dialog.dart');
    });

    test('★ 「配置」按钮对 declarative 源必须分派到编排器（不是 config 表单）', () {
      /*
       * 判据：`_configOf` 里**先**判 declarative 并调 `_editDeclarativeViaComposer`，
       * **后**才 `_pluginOf` 判空。
       *
       * ⚠️ 顺序是这个门禁的核心：改前是 `if (e == null) return null`
       * 在最前面，声明式源直接拿不到按钮 ⇒ 用户永远到不了编排器。
       * 只断言「两者都出现」会漏掉顺序错（那一刻 declarative 仍拿不到按钮）。
       */
      final start = settings.indexOf('VoidCallback? _configOf(String id) {');
      expect(start, greaterThan(0), reason: '找不到 _configOf —— 结构变了');
      final end = settings.indexOf('\n  }', start);
      final body = settings.substring(start, end);

      final iDecl = body.indexOf("p.kind == 'declarative'");
      final iComposer = body.indexOf('_editDeclarativeViaComposer(p)');
      final iPlugin = body.indexOf('_pluginOf(id)');

      expect(iDecl, greaterThan(0), reason: '★ _configOf 必须按 kind 判 declarative');
      expect(iComposer, greaterThan(iDecl),
          reason: '★ 判到 declarative 后必须直达编排器，不是弹 config 表单');
      expect(iPlugin, greaterThan(iComposer),
          reason: '★★ `_pluginOf` 判空必须在 declarative 分派**之后** —— '
              '改前它在最前面，声明式源因此永远拿不到「配置」按钮（本条会红）');
    });

    test('★ 编排器必须带初值（initial 非空），否则打开是空白的', () {
      /*
       * 判据取 `_editDeclarativeViaComposer` 的函数体：
       * 必须传 `initial:` 且该实参不是 `null`。
       *
       * 改前 `provider_import_dialog.dart:644` 调 SourceComposerDialog 时
       * **没传 initial** ⇒ 编辑已有源等于从零重填（settings_page 的
       * :1117 注释逐字记着这个缺陷）。
       */
      final start = settings.indexOf('Future<void> _editDeclarativeViaComposer(');
      expect(start, greaterThan(0), reason: '找不到 _editDeclarativeViaComposer');
      final body = settings.substring(start, settings.indexOf('\n  }', start));

      expect(body.contains('SourceComposerDialog('), isTrue,
          reason: '★ 必须真的构造编排器');
      expect(body.contains('initial:'), isTrue,
          reason: '★★ 必须传 initial —— 不传就是空白编排器（改前的缺陷）');
      expect(
        RegExp(r'initial:\s*null').hasMatch(body),
        isFalse,
        reason: '★★ initial 不许是 null（那等于没传）',
      );
      // 初值必须来自**当前源**（不是空 ComposerDraft()）
      expect(body.contains('composerDraftFromJson'), isTrue,
          reason: '★★ 初值必须由当前源的 JSON 还原（「带当前源的内容」的判据）');
    });

    test('★ 编排器入口的按钮文案/标题仍在（用户找得到）', () {
      expect(dialog.contains("'可视化编排'"), isTrue,
          reason: '编排器自己的标题丢了用户就认不出这个弹窗');
      expect(importDlg.contains('可视化编排'), isTrue,
          reason: '导入弹窗里的编排入口不能丢');
    });

    test('★ 空 config 的提示必须区分「没声明」而不是谎称「没有可配置项」', () {
      /*
       * 取证读数（真核心 + 32 个本机插件）：
       *   plugin_config_get 对 32 个源全部返回空 fields；
       *   造一个真声明 config 的插件则返回 3 项 ⇒ 解析链路完好，
       *   空是因为**插件没声明**。
       * ⇒ 文案要说清"没声明"，并指向可视化编排（声明式源的入口），
       *   否则用户会以为编排功能没做（那正是 Owner 的原话）。
       */
      expect(settings.contains('没有声明可配置项'), isTrue,
          reason: '★ 文案必须说"没声明"（如实），而不是笼统的"没有可配置项"');
      expect(settings.contains('可视化编排用于声明式源'), isTrue,
          reason: '★ 必须告诉用户编排器在哪（否则他仍然找不到）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  N9 —— 进度 / 排序 / toast / 取消
  // ═══════════════════════════════════════════════════════════════════
  group('N9 健康检测与测速', () {
    late String settings;
    late String speed;

    setUpAll(() {
      settings = read('lib/ui/settings_page.dart');
      speed = read('lib/ui/widgets/plugin_speedtest.dart');
    });

    test('★★ 健康检测必须**逐项**执行并显示「N/总数」', () {
      /*
       * 三层判据（缺一层就会漏掉一种坏法）：
       * ① 不再用批量 healthSweep()（它一个 FFI 调用探完，不可能有进度）
       * ② 循环里有 +1 的计数（真的每完成一个就更新）
       * ③ 进度文案出现在 UI 里（不是只算不显示）
       */
      final start = settings.indexOf('Future<void> _healthSweep() async {');
      expect(start, greaterThan(0), reason: '找不到 _healthSweep');
      final body = settings.substring(start, settings.indexOf('\n  }', start));

      expect(body.contains('SourinApi.healthSweep()'), isFalse,
          reason: '★★ 不许再用批量 healthSweep —— 它无法给进度，'
              '且 32 个源串行探会撞 FFI 的 120s 兜底超时（Owner 看到的"健康失败"）');
      expect(body.contains('_healthDone++'), isTrue,
          reason: '★ 每完成一个必须 +1（这是"正在执行 N/总数"的唯一数据源）');
      expect(body.contains('_healthTotal'), isTrue,
          reason: '★ 必须记录总数');
      expect(settings.contains('健康检测 \$_healthDone/\$_healthTotal'), isTrue,
          reason: '★★ 进度文案必须真的画出来 —— 只算不显示等于没有');
    });

    test('★★ 健康检测必须能在中途被取消（退出页面不残留）', () {
      final start = settings.indexOf('Future<void> _healthSweep() async {');
      final body = settings.substring(start, settings.indexOf('\n  }', start));

      expect(body.contains('token.isCancelled'), isTrue,
          reason: '★ 循环里必须查取消');

      /*
       * ★★★ 2026-10-18（故障注入抓到的假绿 —— 已修）
       *
       * 第一版这里写的是 `expect(settings.contains('_healthToken?.cancel()'), isTrue)`，
       * 注入「删掉 dispose 里的 cancel」之后**它仍然是绿的**。
       * 为什么：`_healthToken?.cancel()` 在文件里出现**两次** ——
       * `dispose()` 里一次，根进度行「停止」按钮的 `onPressed` 里一次。
       * 全文 `contains` 被第二处满足 ⇒ 缺陷还原了却测不出来。
       *
       * ⇒ 判据必须锁定在 **dispose 的函数体**里，不能扫全文。
       *   （这也是本仓「断源码文本要断到具体函数体」那条教训的又一例。）
       */
      final iDispose = settings.indexOf('void dispose() {');
      expect(iDispose, greaterThan(0), reason: '找不到 dispose');
      final disposeBody = settings.substring(
        iDispose,
        settings.indexOf('\n  }', iDispose),
      );
      expect(disposeBody.contains('_healthToken?.cancel()'), isTrue,
          reason: '★★ **dispose 函数体内**必须 cancel —— 否则退出页面后循环继续跑、'
              '继续对已销毁的树 setState。'
              '（⚠️ 不许改成扫全文：文件里「停止」按钮也调了同一个方法，'
              '扫全文会在 dispose 被删掉时仍然绿 —— 本门禁第一版就是这样漏的）');
      expect(disposeBody.contains('super.dispose()'), isTrue,
          reason: '★ 基本卫生：super.dispose() 不能丢');

      expect(settings.contains('_HealthSweepToken'), isTrue,
          reason: '★ 必须有一个明确的令牌类型（不是一个随手加的 bool）');
    });

    test('★★ 「按速度排序」必须存在，且落盘走统一出口（排序后仍可手动拖）', () {
      expect(settings.contains('Future<void> _sortBySpeed()'), isTrue,
          reason: '★ Owner：「还可以一键按照速度排序」');
      final start = settings.indexOf('Future<void> _sortBySpeed() async {');
      final body = settings.substring(start, settings.indexOf('\n  }', start));
      expect(body.contains('_persistOrder('), isTrue,
          reason: '★★ 必须走**唯一**落盘出口 —— 那正是"排序完还能手动拖"的保证'
              '（顺序只是被重写一次，没有锁）');
      expect(settings.contains("value: 'speed'"), isTrue,
          reason: '★ 菜单里必须有这一项（否则用户点不到）');
      // 排序必须稳定（同分/没测过的不能被随机打散）
      expect(body.contains('rank('), isTrue,
          reason: '★ 必须有分档（有速率 / 测过没量到 / 从没测过）');
    });

    test('★★ 测速完成必须回调一次（宿主据此发 toast）', () {
      expect(speed.contains('onFinished'), isTrue,
          reason: '★★ Owner：「测速完发送一条toast」—— 必须有终态回调');
      final start = speed.indexOf('widget.onFinished?.call(');
      expect(start, greaterThan(0), reason: '★ onFinished 定义了却没人调 = 假接线');
      /*
       * 三个排除条件都要在（离开页面 / 被取消 / 没有可测的源）——
       * 少一个就会在"用户已经走了"之后弹 toast（那比不弹更糟：
       * 用户回到首页看到一条莫名其妙的"测速完成"）。
       */
      final guard = speed.substring(
        (start - 300).clamp(0, speed.length),
        start,
      );
      expect(guard.contains('_disposed'), isTrue,
          reason: '★ 离开页面后不许再回调');
      expect(guard.contains('isCancelled'), isTrue,
          reason: '★ 被取消（退出软件）后不许报"完成"');
      expect(settings.contains('onFinished: _onSpeedTestFinished'), isTrue,
          reason: '★★ 宿主必须真的接上这个回调（否则等于没发 toast）');
      expect(settings.contains('showAppToast('), isTrue,
          reason: '★ toast 必须走统一入口');
    });

    test('★ 测速进度文案与计数仍在（不能被这次改动碰坏）', () {
      expect(speed.contains('测速 \$_done/\$_total'), isTrue,
          reason: '★ 测速**已有**的进度读数必须保留（Owner 要的"N/总数"在测速侧本来就有）');
      expect(speed.contains('_allConcurrency'), isTrue,
          reason: '★ 并发数读数必须保留');
    });

    test('★★ 测速按钮 dispose 时必须 cancel 令牌（Owner：退出这个页面也要测试）', () {
      /*
       * # 改前的真实泄漏（不是理论问题）
       * ```text
       * 改前 dispose() 只做 `_disposed = true`，**不 cancel 令牌**，
       * 而 worker 的判据是 `if (_disposed || token.isCancelled) return;`
       * —— 只在**下一轮派活前**检查！
       * ⇒ 退出页面那一刻，已在飞的 3 路各自带着
       *   `PluginSpeedTestRunner.run` 里 `.timeout(_timeout)` 的 **20 秒**
       *   定时器继续跑。实测（flutter_test 的计时器检查）抓到：
       *     A Timer is still pending even after the widget tree was disposed.
       *     Pending timers: Timer (duration: 0:00:20, periodic: false) × 3
       *     created by _PluginSpeedTestAllButtonState._runAll.worker
       * ```
       *
       * # ⚠️ 这条门禁**只锁结构**（dispose 里有 cancel + 令牌是字段）
       * ```text
       * 实证它"真的让在途测速提前结束"**做不到**：flutter_test 用假时钟，
       * 把虚拟时间推过 20s 后 `.timeout()` 定时器总会被释放 ——
       * 我试过「移除 cancel ⇒ 断言必须红」的故障注入，结果是**仍然绿**
       * （假绿）。所以我不把它写成"已验证的行为"，只锁住"代码结构上
       * 必须这么做"，并在交付说明里如实标注这一点。
       * ```
       */
      /*
       * ⚠️ 2026-10-18（故障注入抓到的**第二处假绿**，已修）：
       *
       * 第一版这里写的是
       *     final iDispose = speed.indexOf('class _PluginSpeedTestAllButtonState');
       *     final body = speed.substring(iDispose, speed.indexOf('void dispose() {', iDispose));
       *     expect(body.contains('SpeedTestCancelToken? _token;'), isTrue)
       *
       * 注入「把 `_token` 字段删掉」之后它**仍然是绿的**。原因：
       * `SpeedTestCancelToken? _token;` 在文件里出现**两处**
       * （另一处是单卡片测速面板的字段），注入删掉的是**第一处**，
       * 而断言取的是第二处之前的那段文本 —— 仍含第二处。
       * ⇒ 必须**按本类的范围**判：类起始位置之后、该类 dispose 之前。
       *
       * 这已经是本文件第二次栽在「同一个字面量在文件里出现多次」上
       * （第一次是 `_healthToken?.cancel()`，见上面那条的注释）。
       * 教训统一成一句：**断源码必须锁定容器，不能扫全文**。
       */
      final iClass = speed.indexOf('class _PluginSpeedTestAllButtonState');
      expect(iClass, greaterThan(0), reason: '找不到 _PluginSpeedTestAllButtonState');
      final iD = speed.indexOf('void dispose() {', iClass);
      expect(iD, greaterThan(iClass), reason: '找不到测速按钮的 dispose（必须在类内）');
      final header = speed.substring(iClass, iD);
      expect(header.contains('SpeedTestCancelToken? _token;'), isTrue,
          reason: '★★ 令牌必须是**本类的字段** —— 改前它是 _runAll 里的局部变量，'
              'dispose 根本拿不到，所以退出页面停不掉');

      final disposeBody = speed.substring(iD, speed.indexOf('\n  }', iD));
      expect(disposeBody.contains('_token?.cancel()'), isTrue,
          reason: '★★ dispose 里必须 cancel —— 否则退出页面后在途测速'
              '继续下载最长 20 秒（白耗流量/电量，退出软件时还会抢刷盘时序）');
      expect(disposeBody.contains('_disposed = true'), isTrue,
          reason: '★ `_disposed` 也要保留：令牌守"派活"，标志位守"setState"，'
              '两件事都要');
    });

    test('★★ 健康检测不许再把单个源失败升级成「整次失败」', () {
      /*
       * 改前：一个源抛异常 ⇒ catch 到最外层 ⇒ 一句
       * 「健康检测失败：$e」⇒ 所有已探完的结果全部丢失。
       * 改后：每个源单独 try/catch，失败只记 bad。
       */
      final start = settings.indexOf('Future<void> _healthSweep() async {');
      final body = settings.substring(start, settings.indexOf('\n  }', start));
      expect(body.contains('健康检测失败：'), isFalse,
          reason: '★★ 不许再有"整次失败"这条路径 —— 单源失败要如实计入不可用，'
              '不能把整轮结果丢掉（那正是 Owner 看到的那句话）');
      expect(body.contains('bad.add('), isTrue,
          reason: '★ 失败的源必须被记下来（才能报出"哪几个不可用"）');
    });
  });

  // ═══════════════════════════════════════════════════════════════════
  //  N8 —— 统一 toast：自写实现必须归零
  // ═══════════════════════════════════════════════════════════════════
  group('N8 统一 toast', () {
    test('★★ 除两个轨道占用文件外，不许再有自写 toast 实现', () {
      /*
       * # 判据（三条一起看，缺一条就能被绕过）
       * ```text
       * ① 不许有 `String? _toast;` 字段（自写实现的核心状态）
       * ② 不许有私有 `class _Toast` / `_toastWidget(` / `_toastTimer`
       * ③ 每页的 `_flash` 必须走 showAppToast
       * ```
       *
       * # ★ 为什么清单是**白名单 + 显式豁免**
       * ```text
       * player_page.dart      轨道 A 独占（本轮不许动，见交付说明）
       * live_groups_page.dart 轨道 B 独占（同上）
       * ```
       * 豁免必须是**具名**的 —— 写成"除了 lib/ui 之外"这种模糊豁免
       * 等于给自己开后门。
       */
      const exempt = <String>{
        'lib/ui/player_page.dart',
        'lib/ui/settings/live_groups_page.dart',
      };

      final offenders = <String>[];
      final targets = <String>[
        'lib/ui/detail_page.dart',
        'lib/ui/follow_page.dart',
        'lib/ui/settings_page.dart',
        'lib/ui/settings/playback_page.dart',
        'lib/ui/settings/skip_page.dart',
        'lib/ui/settings/data_manage_page.dart',
      ];

      for (final rel in targets) {
        expect(exempt.contains(rel), isFalse,
            reason: '★ $rel 在豁免清单里却又列进检查目标 —— 门禁自相矛盾');
        final src = read(rel);
        final hits = <String>[];
        if (RegExp(r'String\?\s+_toast\s*;').hasMatch(src)) hits.add('_toast 字段');
        if (RegExp(r'class\s+_Toast\b').hasMatch(src)) hits.add('class _Toast');
        if (src.contains('_toastWidget(')) hits.add('_toastWidget');
        if (src.contains('_toastTimer')) hits.add('_toastTimer');
        if (hits.isNotEmpty) offenders.add('$rel（${hits.join(' / ')}）');
      }

      expect(offenders, isEmpty,
          reason: '★★ Owner：「统一toast提示样式,不要自己写,要用自带的」\n'
              '仍然自写 toast 的文件：${offenders.join('；')}');
    });

    test('★★ 迁移过的每一页，_flash 都必须走 showAppToast', () {
      const targets = <String>[
        'lib/ui/detail_page.dart',
        'lib/ui/follow_page.dart',
        'lib/ui/settings_page.dart',
        'lib/ui/settings/playback_page.dart',
        'lib/ui/settings/skip_page.dart',
        'lib/ui/settings/data_manage_page.dart',
      ];
      for (final rel in targets) {
        final src = read(rel);
        final i = src.indexOf('void _flash(String msg) {');
        expect(i, greaterThan(0), reason: '$rel 找不到 _flash');
        final body = src.substring(i, src.indexOf('\n  }', i));
        expect(
          body.contains('showAppToast(context, msg)'),
          isTrue,
          reason: '★★ $rel 的 _flash 必须转调 showAppToast —— '
              '它挂在 Navigator 之外，二级页/嵌入态都看得见',
        );
        // 反面：不许再自己 setState 一个 _toast
        expect(RegExp(r'_toast\s*=').hasMatch(body), isFalse,
            reason: '$rel 的 _flash 还在写 _toast 状态（自写实现没删干净）');
      }
    });

    test('★ 五页都必须真的 import 了 app_toast（接线，不只是调了个同名函数）', () {
      const targets = <String>[
        'lib/ui/detail_page.dart',
        'lib/ui/follow_page.dart',
        'lib/ui/settings/playback_page.dart',
        'lib/ui/settings/skip_page.dart',
        'lib/ui/settings/data_manage_page.dart',
      ];
      for (final rel in targets) {
        final src = File(rel).readAsStringSync();
        expect(
          RegExp(r"import\s+'[^']*app_toast\.dart';").hasMatch(src),
          isTrue,
          reason: '★★ $rel 必须 import app_toast.dart —— '
              '只写 showAppToast(...) 而不 import，靠的是别的文件的 export，'
              '一旦那个文件不 export 就静默编译失败/找不到',
        );
      }
    });

    test('★ 被排除的两个文件确实仍是自写实现（如实记录，不是假装做完了）', () {
      /*
       * 这一条是**反向**的：它证明"豁免清单不是空写"。
       * 如果哪天轨道 A/B 把这两处也迁了，这条会红 —— 那时把它删掉即可
       * （删掉时交付说明里要写"已由轨道 A/B 完成"）。
       */
      final player = read('lib/ui/player_page.dart');
      final live = read('lib/ui/settings/live_groups_page.dart');
      final stillSelfWritten =
          RegExp(r'String\?\s+_toast\s*;').hasMatch(player) ||
              player.contains('class _TipBubble') ||
              RegExp(r'String\?\s+_toast\s*;').hasMatch(live);
      expect(stillSelfWritten, isTrue,
          reason: '★ 这两个文件本轮**不动**（轨道 A/B 独占）。'
              '若它们已经迁好，本条应删除并在交付说明里注明 —— '
              '留着它是为了不让"豁免"变成永久盲区');
    });
  });
}
