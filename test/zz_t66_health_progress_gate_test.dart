// ═══════════════════════════════════════════════════════════════════════
//  门禁：健康检测进度行在**二级页**上必须跟手（PR #32 / CodeRabbit 线程 5）
// ═══════════════════════════════════════════════════════════════════════
//
// # 被修的缺陷（CodeRabbit 线程 5 的原话大意）
//
// ```text
// `_healthSweep()` 只调宿主 `setState`，而 `_pluginsBlock`（进度行在这里）
// 只由 `_PluginsPage` 渲染 —— 那是 `Navigator.push` 上来的**另一条路由**，
// 不在宿主 State 的子树里 ⇒ 宿主 setState 重建不到它。
// 用户可见读数：二级页上「健康检测 x/y」永远停在 0/N；按停止/跑完后
// 进度行也不消失（`if (_sweeping)` 同样没人重新求值）。
// ```
//
// # 这套门禁守什么（三层，各守一种坏法）
//
// ```text
// ① 行为层：在「宿主 + 另一条 push 路由」的真实路由拓扑下挂真 widget，
//    由 notifier 推进度，断言界面文本**真的从 0/N 长到 3/N、再消失**。
//    ⇒ 守「有没有订阅」。
// ② 反向层：只改宿主计数 + 宿主 setState（**不**推 notifier），
//    断言二级页的文本**一个字都不许变**。
//    ⇒ 守「别再退回宿主 setState 那套」。没有这一条，① 也能被
//      「干脆每次 build 都现读」蒙过去（那在真机上仍然是 0/N）。
// ③ 接线层：真的 `_healthSweep()` / `dispose()` 函数体里必须有那三个
//    进度点与销毁（剥注释后按**函数体**断言，不扫全文）。
//    ⇒ 守「widget 会订阅、但宿主根本不推」这种半截修法。
// ```
//
// ⚠️ ③ 是源码级判据，**只作补充**：它单独立不住（grep 源码是本仓反复
//    抓到的假绿来源）。真正的判据是 ①②。为什么不能把 ①② 直接升级成
//    「挂真 `SettingsPage` + 点开真 `_PluginsPage` + 点真菜单」：
//    `_providers` 来自 `loadAll()`（FFI 核心库），CI/本机没有
//    `sourin_core.dll` 时它是空表 ⇒ `_healthSweep` 直接走
//    「没有已启用的源可检测」提前 return，一行进度都不会出现（真挂也读不到
//    `1/N`）。所以 ①② 用真实 widget + 真实路由拓扑，③ 兜住接线。
//
// # 怎么自证不假绿（故障注入，全部真跑过，读数见任务报告）
//
// ```text
// 注入 A：把 `HealthSweepProgressRow.build` 里的 ValueListenableBuilder
//        换成直接 return（不再订阅）⇒ ① 红（停在 0/26）。
// 注入 B：删掉 `if (!p.sweeping) return const SizedBox.shrink();`
//        ⇒ ① 的「停止后消失」红。
// 注入 C：删掉 `_healthSweep` 里 per-item 那个 `_healthRev.value++`
//        ⇒ ③ 红。
// 注入 D：删掉 dispose 里的 `_healthRev.dispose()`
//        ⇒ ③ 红。
// ```
//
// ⚠️ 纯 widget 测试，不加载 FFI / libmpv / 网络。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

import 'package:sourin_spike/ui/app_theme.dart';
import 'package:sourin_spike/ui/settings_page.dart';
import 'package:sourin_spike/ui/widgets/app_inline_spinner.dart';

// ═══════════════════════════════════════════════════════════════════════
//  ① ② 的夹具：一个「宿主」+ 一条 push 上来的「二级页」
// ═══════════════════════════════════════════════════════════════════════

/// 假的宿主 State —— 逐字复刻 `SettingsPageState` 的那 4 个字段 + 推送点。
///
/// 只做两件事：改计数（`setState`）与推 notifier。**刻意分成两个方法**，
/// 因为缺陷的全部内容就是「只做了前者」。
class _FakeHostState extends State<_FakeHost> {
  bool sweeping = false;
  int done = 0;
  int ok = 0;
  int total = 0;
  int stopCalls = 0;

  final rev = ValueNotifier<int>(0);

  @override
  void dispose() {
    rev.dispose();
    super.dispose();
  }

  /// 只走宿主那一路（进度**不**跟手）—— 缺陷现场
  void mutateWithoutNotify(void Function(_FakeHostState s) f) {
    setState(() => f(this));
  }

  /// 宿主 + 进度通知（修好之后的三处推送点）
  void mutateAndNotify(void Function(_FakeHostState s) f) {
    setState(() => f(this));
    rev.value++;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          const Text('一级页（宿主）'),
          TextButton(
            onPressed: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => Scaffold(
                    body: Center(
                      child: HealthSweepProgressRow(
                        rev: rev,
                        snapshot: () => (
                          sweeping: sweeping,
                          done: done,
                          ok: ok,
                          total: total,
                        ),
                        label: () => '健康检测 $done/$total',
                        okLabel: () => '可用 $ok',
                        onStop: () => stopCalls++,
                      ),
                    ),
                  ),
                ),
              );
            },
            child: const Text('打开二级页'),
          ),
        ],
      ),
    );
  }
}

class _FakeHost extends StatefulWidget {
  const _FakeHost();

  @override
  State<_FakeHost> createState() => _FakeHostState();
}

/// ⚠️ `skipOffstage: false`：push 之后一级页被盖住（Offstage），
/// 默认的 finder 会跳过它 ⇒ 拿不到宿主 State。
/// 这**恰好**也是本缺陷能存在的物理原因：宿主不在可见树里。
_FakeHostState _host(WidgetTester t) => t.state<_FakeHostState>(
  find.byType(_FakeHost, skipOffstage: false),
);

Widget _app() => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.themeFor(Brightness.dark),
  home: const _FakeHost(),
);

/// 挂起来 + 点进二级页（真实 `Navigator.push`，与 `_PluginsPage` 同拓扑）
Future<_FakeHostState> _openSecondRoute(WidgetTester t) async {
  await t.pumpWidget(_app());
  await t.pumpAndSettle();
  expect(find.byType(HealthSweepProgressRow), findsNothing,
      reason: '进二级页之前不该有进度行');
  await t.tap(find.text('打开二级页'));
  await t.pumpAndSettle();
  expect(find.byType(HealthSweepProgressRow), findsOneWidget,
      reason: '二级页上必须有进度行 widget（拓扑没搭起来 ⇒ 后面全是假读数）');
  return _host(t);
}

/// 读界面上那条进度文本（找不到就返回 null，方便直接断言「消失」）
String? _progressText(WidgetTester t) {
  final f = find.textContaining('健康检测 ');
  if (f.evaluate().isEmpty) return null;
  return t.widget<Text>(f.first).data;
}

String? _okText(WidgetTester t) {
  final f = find.textContaining('可用 ');
  if (f.evaluate().isEmpty) return null;
  return t.widget<Text>(f.first).data;
}

// ═══════════════════════════════════════════════════════════════════════
//  ③ 的夹具：读真源码、按**函数体**切块
// ═══════════════════════════════════════════════════════════════════════

String _read(String rel) => File(rel).readAsStringSync();

/// 剥掉 `//` 行注释与 `/* */` 块注释（本仓多处踩过「命中注释」的坑）
String _codeOnly(String src) {
  final out = StringBuffer();
  var i = 0;
  var inLine = false;
  var inBlock = false;
  String? quote;
  while (i < src.length) {
    final c = src[i];
    if (inLine) {
      if (c == '\n') {
        inLine = false;
        out.write(c);
      }
      i++;
      continue;
    }
    if (inBlock) {
      if (c == '*' && i + 1 < src.length && src[i + 1] == '/') {
        inBlock = false;
        i += 2;
        continue;
      }
      if (c == '\n') out.write(c);
      i++;
      continue;
    }
    if (quote != null) {
      out.write(c);
      if (c == r'\' && i + 1 < src.length) {
        out.write(src[i + 1]);
        i += 2;
        continue;
      }
      if (c == quote) quote = null;
      i++;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '/') {
      inLine = true;
      i += 2;
      continue;
    }
    if (c == '/' && i + 1 < src.length && src[i + 1] == '*') {
      inBlock = true;
      i += 2;
      continue;
    }
    if (c == "'" || c == '"') {
      quote = c;
      out.write(c);
      i++;
      continue;
    }
    out.write(c);
    i++;
  }
  return out.toString();
}

/// 从 `from` 起找到 `signature` 之后的第一个 `{`，返回**配对**的整块（含大括号）
String _functionBody(String code, String signature) {
  final i = code.indexOf(signature);
  expect(i, greaterThanOrEqualTo(0), reason: '源码里找不到：$signature');
  final open = code.indexOf('{', i);
  expect(open, greaterThan(0), reason: '$signature 后面没有函数体');
  var level = 0;
  for (var j = open; j < code.length; j++) {
    final c = code[j];
    if (c == '{') level++;
    if (c == '}') {
      level--;
      if (level == 0) return code.substring(i, j + 1);
    }
  }
  fail('$signature 的大括号没有配对 —— 源文件被改坏了');
}

void main() {
  // ═════════════════════════════════════════════════════════════════
  //  ①② 行为层：真 widget + 真路由拓扑
  // ═════════════════════════════════════════════════════════════════

  group('A 二级页上的健康检测进度行必须跟手', () {
    testWidgets('★ 不跑的时候一行都不占（不占位、不加噪声）', (t) async {
      await _openSecondRoute(t);
      expect(_progressText(t), isNull, reason: '没在跑就不许有进度文案');
      expect(find.text('停止'), findsNothing, reason: '没在跑就不许有「停止」');
      expect(find.byType(AppInlineSpinner), findsNothing,
          reason: '没在跑就不许转圈');
    });

    testWidgets('★★★ 开跑后进度行出现，且 1/N → 3/N 逐步长（本门禁的主判据）',
        (t) async {
      final h = await _openSecondRoute(t);

      // ── 开跑：0/N ──
      h.mutateAndNotify((s) {
        s.sweeping = true;
        s.done = 0;
        s.ok = 0;
        s.total = 26;
      });
      await t.pump();
      expect(_progressText(t), '健康检测 0/26',
          reason: '★ 开跑后二级页上必须出现 0/N —— 改前这里恒为 null（行根本不出现）');
      expect(_okText(t), '可用 0', reason: '可用数必须跟着出现');
      expect(find.text('停止'), findsOneWidget, reason: '跑的时候必须能停');
      expect(find.byType(AppInlineSpinner), findsOneWidget,
          reason: '跑的时候要有那个 14px 行内小圈');

      // ── 每个源完成一个：N 必须真的增长 ──
      h.mutateAndNotify((s) => s.done = 1);
      await t.pump();
      expect(_progressText(t), '健康检测 1/26',
          reason: '★ 完成一个必须立刻长到 1/26 —— 改前恒停在 0/26');

      h.mutateAndNotify((s) {
        s.done = 2;
        s.ok = 1;
      });
      await t.pump();
      expect(_progressText(t), '健康检测 2/26', reason: '第二个完成');
      expect(_okText(t), '可用 1', reason: '★ 可用数也是活的（不是只动总数那一半）');

      h.mutateAndNotify((s) {
        s.done = 3;
        s.ok = 2;
      });
      await t.pump();
      expect(_progressText(t), '健康检测 3/26', reason: '第三个完成');
      expect(_okText(t), '可用 2', reason: '可用数继续跟');
    });

    testWidgets('★★ 只推宿主 setState、不推进度通知 ⇒ 二级页一个字都不许变',
        (t) async {
      /*
       * 这条是「别再退回旧那套」的钉子。
       *
       * 改前的实现就是**只有**宿主 setState ⇒ 用户在二级页上看到 0/N 不动。
       * 若将来有人把订阅删掉、改成「反正宿主会 setState」，本文件第一条
       * 用例会红；若有人把订阅删掉但**同时**让宿主每帧重建（假修），
       * 这一条仍然会绿（因为在真机上宿主仍然重建不到另一条路由）——
       * 所以它守的是「订阅」这个机制本身，不是「有没有变化」。
       */
      final h = await _openSecondRoute(t);
      h.mutateAndNotify((s) {
        s.sweeping = true;
        s.total = 26;
      });
      await t.pump();
      expect(_progressText(t), '健康检测 0/26');

      // 只改计数 + 宿主 setState，进度通知一次都不推
      h.mutateWithoutNotify((s) => s.done = 17);
      await t.pump();
      await t.pump();
      expect(_progressText(t), '健康检测 0/26',
          reason: '★ 没推进度通知就不许自己变 —— '
              '变了说明读的是宿主重建，而不是进度通道（真机上宿主重建不到这条路由）');
    });

    testWidgets('★★★ 停止：进度行必须消失（不能停在 N/N 挂着）', (t) async {
      final h = await _openSecondRoute(t);
      h.mutateAndNotify((s) {
        s.sweeping = true;
        s.done = 5;
        s.ok = 4;
        s.total = 26;
      });
      await t.pump();
      expect(_progressText(t), '健康检测 5/26');

      // 「停止」按钮自己也要能按（它调 onStop 而不是内联 setState）
      await t.tap(find.text('停止'));
      await t.pump();
      expect(h.stopCalls, 1, reason: '★ 「停止」必须真的调到宿主的取消（onStop）');

      // 宿主收到取消 ⇒ 循环退出 ⇒ finally 里 sweeping=false + 推进度通知
      h.mutateAndNotify((s) => s.sweeping = false);
      await t.pump();
      expect(_progressText(t), isNull,
          reason: '★★ 停止/结束后进度行必须消失 —— 改前它会一直挂在 5/26');
      expect(find.text('停止'), findsNothing, reason: '「停止」也要跟着消失');
      expect(find.byType(AppInlineSpinner), findsNothing, reason: '小圈也要消失');
    });

    testWidgets('★★ 跑完（正常收尾）与中途取消是同一条收尾路径', (t) async {
      final h = await _openSecondRoute(t);
      h.mutateAndNotify((s) {
        s.sweeping = true;
        s.total = 2;
      });
      await t.pump();
      h.mutateAndNotify((s) {
        s.done = 2;
        s.ok = 2;
      });
      await t.pump();
      expect(_progressText(t), '健康检测 2/2', reason: '跑满');
      h.mutateAndNotify((s) => s.sweeping = false);
      await t.pump();
      expect(_progressText(t), isNull, reason: '跑完也必须消失（同一个 finally）');
    });
  });

  // ═════════════════════════════════════════════════════════════════
  //  ③ 接线层：真 `_healthSweep` / `dispose` 必须有那三个推送点 + 销毁
  // ═════════════════════════════════════════════════════════════════

  group('B 产品侧的接线（宿主必须真的推、真的销毁）', () {
    late String code;

    setUpAll(() {
      code = _codeOnly(_read('lib/ui/settings_page.dart'));
    });

    test('★★ sync：_healthSweep 的「开跑 / 每完成一个」两个推送点都在', () {
      final body = _functionBody(code, 'Future<void> _healthSweep() async {');
      expect(body.split('_healthRev.value++').length - 1, greaterThanOrEqualTo(2),
          reason: '★ `_healthSweep` 里至少要两处 `_healthRev.value++`'
              '（开跑一处、每完成一个一处）—— 少了任何一处，二级页上的'
              '进度行就只出现不推进，或根本不出现');

      /*
       * ★★★ 光数总数是**空转**判据（实测过）：
       *   把「每完成一个」那一次删掉，`start + finally` 两处仍然凑够 2，
       *   这条断言照样绿 —— 但二级页上进度行就只出现、永不推进。
       *   所以必须钉住**位置**：那一次推送要紧跟在 `_healthDone++` 之后。
       */
      final done = body.indexOf('_healthDone++');
      expect(done, greaterThan(0),
          reason: '`_healthSweep` 里必须有 `_healthDone++`（每完成一个计数）');
      final window = body.substring(done, done + 220);
      expect(window.contains('_healthRev.value++'), isTrue,
          reason: '★★★ 「每完成一个」那一次 `_healthRev.value++` 必须紧跟在'
              '`_healthDone++` 之后（220 字窗口内）—— 这是「健康检测 3/26」'
              '能一格一格推进的唯一来源；只留开跑和 finally 两处，'
              '二级页上的进度行就停在 0/N 或直接跳到 N/N');
    });

    test('★★ finally：结束/取消都必须推一次（这是「停止后消失」的唯一保证）', () {
      final body = _functionBody(code, 'Future<void> _healthSweep() async {');
      final fin = body.indexOf('finally {');
      expect(fin, greaterThan(0), reason: '`_healthSweep` 必须有 finally');
      final tail = body.substring(fin);
      expect(tail.contains('_sweeping = false'), isTrue,
          reason: 'finally 里必须复位 _sweeping');
      expect(tail.contains('_healthRev.value++'), isTrue,
          reason: '★★ finally 里必须再推一次进度 —— 这一处同时覆盖'
              '「跑完了」和「用户按了停止」；少了它，进度行会一直挂在 N/N');
    });

    test('★★ dispose：_healthRev 必须被销毁（谁建谁销毁）', () {
      final body = _functionBody(code, 'void dispose() {');
      expect(body.contains('_healthRev.dispose()'), isTrue,
          reason: '★ 不销毁的话，宿主销毁后 finally 里那句 `_healthRev.value++`'
              '会往死 notifier 上写（ValueNotifier 在 dispose 后赋值会抛）');
      expect(body.contains('super.dispose()'), isTrue,
          reason: '基本卫生：super.dispose() 不能丢');
    });

    test('★★ 二级页那块必须把真 notifier 交给进度行（不是传个新 notifier）', () {
      final body = _functionBody(code, 'Widget _pluginsBlock(BuildContext context) {');
      expect(body.contains('HealthSweepProgressRow('), isTrue,
          reason: '★ 进度行必须由 `HealthSweepProgressRow` 渲染'
              '（它是唯一带订阅的那条路径）');
      expect(body.contains('rev: _healthRev'), isTrue,
          reason: '★★ 必须接宿主的 `_healthRev` —— 传新建的 notifier 就永远不推');
      expect(body.contains('label: () => \'健康检测 '), isTrue,
          reason: '文案仍由宿主拼（`zz_t66_track_c_gates_test` 逐字断言了这句）');
    });
  });
}
