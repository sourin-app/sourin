// ═══════════════════════════════════════════════════════════════════════
//  门禁：界面显示的错误文案必须是一句人话
// ═══════════════════════════════════════════════════════════════════════
//
// # 这条门禁在钉什么
//
// `SourinCoreException.toString()` 带宿主类名：
//
// ```text
// SourinCoreException(other): 口令不正确（或这个备份包已被改动），登录态没有导入
// └──────────┬─────────────┘
//      ①用户看不懂的东西
// ```
//
// `displayMessage` 早就把 ① 剥掉了，但**全仓零调用** —— 界面到处写
// `_err = '$e'`，用户看到的就是带类名的那一整串。
// 「accessor 写对了」不等于「界面用上了」（AGENTS §4 第①条：写了 ≠ 接线了）。
//
// ⇒ 本轮加了唯一入口 `userErrorText()`（`lib/core/ffi.dart`），
//   下面四组判据钉住它「真的被用上」且「真的只说人话」：
//
// ```text
// ① 入口本身：核心异常 ⇒ 只剩插件原文；其它异常 ⇒ 一句通用文案（不泄露类名）
// ② 真核心真异常：起真 sourin_core.dll，让核心自己抛一条，看界面拿到什么
// ③ 源码门禁：lib/ui/** 里不许再出现「异常插值进用户可见串」；日志桶不拦
// ④ 反恒绿：扫描器对合成样本必须 3 红 / 2 绿（否则它可能只是永远返回空）
// ```
//
// # ★ ③ 的范围与债务（必须写在纸面上，不然就是又一条假绿）
//
// 全仓 `'$e'` 这一族共 **102 处 / 23 个文件**。本轮能写的 6 个文件里
// **20 处已收口**（见下面 `_expectedCalls`）；剩下的 **82 处 / 18 个文件**
// 属于别的写入边界，**登记成预算**而不是悄悄放过：
//
// · 某个文件的实测数**超过**预算 ⇒ 红（新写的 `'$e'` 拦住）
// · 某个文件的实测数**低于**预算 ⇒ 也红，并提示把预算改小
//   （否则修好的人会被这条门禁当成没修 —— 预算必须跟着事实走）
//
// ⇒ 「范围够不够」写在文件里、每次跑都打印，是这个门禁能被复核的前提。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
// ★ 审计 B9：缺 dll 的统一处置（Windows ⇒ fail；其它平台 ⇒ 点名 skip）
import 'support/core_gate.dart';

// ─────────────────────────── ③ 的扫描器 ───────────────────────────

/// 这些位置的 `$e` 是**给排障看的**，不是给用户看的 —— 不算违规
const List<String> _logMarks = <String>[
  'debugPrint(',
  'AppLog',
  '_log(',
  'print(',
  '.log(',
  'log.write',
];

/// 一条「把异常原文插进字符串」的现场
class _Site {
  _Site(this.file, this.line, this.text, this.variable);
  final String file;
  final int line;
  final String text;
  final String variable;

  @override
  String toString() => '$file:$line  <\$$variable>  $text';
}

/// 把一行里所有 `'…'` / `"…"` 字面量抠出来（跳过 `//` 注释）
List<String> _literals(String line) {
  final out = <String>[];
  var i = 0;
  while (i < line.length) {
    final c = line[i];
    if (c == '/' && i + 1 < line.length && line[i + 1] == '/') break;
    if (c == "'" || c == '"') {
      final q = c;
      var j = i + 1;
      final buf = StringBuffer();
      while (j < line.length) {
        if (line.codeUnitAt(j) == 0x5C && j + 1 < line.length) {
          buf.write(line.substring(j, j + 2));
          j += 2;
          continue;
        }
        if (line[j] == q) break;
        buf.write(line[j]);
        j += 1;
      }
      out.add(buf.toString());
      i = j + 1;
      continue;
    }
    i += 1;
  }
  return out;
}

/// 扫一份源码：返回**用户可见**桶里把 catch 变量插进字符串的位置
List<_Site> _scanSource(String file, String src) {
  final vars = <String>{
    for (final m in RegExp(r'catch\s*\(\s*(\w+)').allMatches(src))
      if (m.group(1) != '_') m.group(1)!,
  };
  if (vars.isEmpty) return const <_Site>[];
  final pats = <String, RegExp>{
    for (final v in vars)
      v: RegExp(r'\$\{' + v + r'\}|\$' + v + r'(?![A-Za-z0-9_])'),
  };
  final hits = <_Site>[];
  final lines = src.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (_logMarks.any(line.contains)) continue;
    for (final lit in _literals(line)) {
      for (final e in pats.entries) {
        if (e.value.hasMatch(lit)) {
          hits.add(_Site(file, i + 1, lit, e.key));
          break;
        }
      }
    }
  }
  return hits;
}

/// 日志桶里的条数（只用于打印，不参与判红）
int _countLogSites(String src) {
  final vars = <String>{
    for (final m in RegExp(r'catch\s*\(\s*(\w+)').allMatches(src))
      if (m.group(1) != '_') m.group(1)!,
  };
  if (vars.isEmpty) return 0;
  final pats = <String, RegExp>{
    for (final v in vars)
      v: RegExp(r'\$\{' + v + r'\}|\$' + v + r'(?![A-Za-z0-9_])'),
  };
  var n = 0;
  for (final line in src.split('\n')) {
    if (!_logMarks.any(line.contains)) continue;
    for (final lit in _literals(line)) {
      if (pats.values.any((p) => p.hasMatch(lit))) {
        n += 1;
        break;
      }
    }
  }
  return n;
}

/// 本轮收口的 6 个文件 ⇒ 每个文件期望调用 [userErrorText] 的次数
///
/// 「调用次数」不是实现细节的复制：少一次就说明某处又倒回 `'$e'`
/// （那是用户可见的退化），多一次说明有新增的错误位（应当同批更新这里）。
///
/// # ⚠️ 与 [_debt] 的管辖边界（2026-10-20 修，必须读）
/// ```text
/// 同一文件**可以**同时出现在两张表里，表示「本轮动了一部分，整体还有存量」，
/// 例如 lib/ui/player_page.dart：本轮收口 1 处 + 还有 14 处存量。
/// ⇒ 管辖规则（断言 ① 里有对应实现）：
///   · 在 _debt 里       ⇒ 插值条数由 ③ 判（== 预算，精确相等）
///   · 不在 _debt 里     ⇒ 插值条数由 ① 判（必须 == 0）
///   · 两张表都适用的    ⇒ userErrorText 调用数**始终**由 ② 判（== 本表值）
/// ⚠️ 曾经 ① 对**所有**本表文件要求归零，于是 player_page 被
///    ①（==0）与 ③（==14）同时管辖 ⇒ `0 == 14` 无解 ⇒ 门禁永远红。
///    那不是"14 处该不该改"的问题，是**同一实体被两张表下了互斥要求**。
/// ```
const Map<String, int> _expectedCalls = <String, int>{
  'lib/ui/widgets/backup_panel.dart': 4,
  'lib/ui/widgets/provider_login_panel.dart': 3,
  'lib/ui/widgets/proxy_panel.dart': 5,
  'lib/ui/widgets/skip_marker_dialog.dart': 6,
  'lib/ui/player_page.dart': 1,
  'lib/ui/player/player_bottom_bar.dart': 1,
};

/// 本轮**写不动**的文件 ⇒ 现存条数预算（实测值，非估值）
///
/// 每一行的理由：这些文件不在本轮写入边界内，由各自负责的人收口；
/// 预算的作用是「不再变多」，而不是「已经干净」。
///
/// ★ 本表合计 = 82 处 / 18 个文件，与文件头「剩下的 82 处 / 18 个文件」逐字吻合，
///   也与实测 `USERERROR|...|userVisible=82` 吻合 —— 改动本表时三处必须同步。
/// ★ 断言 ⑤「总数 == 本表之和」因此天然包含 [_expectedCalls] 里
///   那些**同时有存量**的文件（它们计入的是存量，不是已收口的那 1 处）。
const Map<String, int> _debt = <String, int>{
  'lib/ui/settings_page.dart': 26,
  'lib/ui/player_page.dart': 14,
  'lib/ui/widgets/sync_panel.dart': 10,
  'lib/ui/settings/playback_page.dart': 9,
  'lib/ui/subtitle/subtitle_panel.dart': 3,
  'lib/ui/widgets/player_settings_sheet.dart': 3,
  'lib/ui/widgets/tvbox_source_panel.dart': 3,
  'lib/ui/detail_page.dart': 2,
  'lib/ui/settings/skip_page.dart': 2,
  'lib/ui/widgets/live_embedded_player.dart': 2,
  'lib/ui/cast/cast_device_sheet.dart': 1,
  'lib/ui/live_page.dart': 1,
  'lib/ui/settings/data_manage_page.dart': 1,
  'lib/ui/settings/live_groups_page.dart': 1,
  'lib/ui/settings/theme_page.dart': 1,
  'lib/ui/theme/theme_pack.dart': 1,
  'lib/ui/widgets/danmaku_settings_dialog.dart': 1,
  'lib/ui/widgets/plugin_edit_dialog.dart': 1,
};

/// 「插值条数」这一维度**由 [_debt] 管辖**的文件 —— 断言 ① 必须对它让位
///
/// ═══════════════════════════════════════════════════════════════════
/// ★★★ 为什么要有这张表（2026-10-20，这张表是"管辖规则"的可检化）
/// ═══════════════════════════════════════════════════════════════════
///
/// # 它防的是一个**逻辑上必然不可满足**的门禁
/// ```text
/// 断言 ①  对 _expectedCalls 里的 f 要求   perFile[f] == 0
/// 断言 ③  对 _debt 里的 f 要求            perFile[f] == 预算(N)
/// 若 f 同时在两表且 N > 0 ⇒ 0 == N ⇒ 无解 ⇒ 门禁**永远红**
/// ```
/// 这不是"可能出错"，是"一定会错"，而且**写代码时就能机械检出**。
///
/// # 为什么让位规则必须写成数据，而不是藏在 `for` 循环里
/// ```text
/// 藏在控制流里（原来那版）：`if (_debt.containsKey(f)) continue;`
///   ⇒ 规则是对的，但**无法被自检**：
///     新加一个交集键时，代码会自动让它让位，而没人知道"这里本该登记一次决定"。
///     也就是说「让位」变成了静默行为 —— 静默的规则等于没有规则。
///
/// 写成数据（本表）：
///   ⇒ 自检可以断言「交集里的每个键都必须在这里登记过」，
///     漏登记 ⇒ 红 ⇒ 逼人明确回答"这个文件的插值条数归谁管"。
/// ```
///
/// # 与断言 ① 的关系（必须保持一致，自检会验）
/// ```text
/// 断言①：for (final f in _expectedCalls.keys) {
///           if (_debtWins.contains(f)) continue;   // ← 让位给 ③
///           expect(perFile[f] ?? 0, 0, ...);
///         }
/// ⇒ 本表**必须**覆盖 `_debt.keys ∩ _expectedCalls.keys` 的全部键。
/// ```
///
/// # 当前为什么只有 player_page
/// ```text
/// 本轮收口 6 个文件里，另外 5 个（backup_panel / provider_login_panel /
/// proxy_panel / skip_marker_dialog / player_bottom_bar）已经**清零**，
/// 不在 _debt 里 ⇒ 它们由断言① 判 == 0，不需要让位。
/// player_page 是唯一「本轮动了 1 处、但整体还有 14 处存量」的过渡文件。
/// ```
/// ⚠️ 将来某个 _debt 文件被收口到 0 时：把它从 [_debt] 删掉，
///    同时从本表删掉 —— 两步都做完，断言① 才会重新接管它（要求 == 0）。
const Set<String> _debtWins = <String>{
  'lib/ui/player_page.dart',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // ─────────────────── ① 唯一入口本身 ───────────────────

  group('① userErrorText 只说人话', () {
    test('核心异常 ⇒ 只剩插件原文（类名与分类都不见了）', () {
      final e = SourinCoreException('插件报错: 该内容需要大会员', 'other');
      final text = userErrorText(e);

      expect(text, '该内容需要大会员');
      // 负面对照：同一异常用老写法会带出类名 —— 证明这条判据有判别力
      expect('$e', contains('SourinCoreException'));
      expect('$e', isNot(text));
    });

    test('核心异常但原文为空 ⇒ 用兜底文案，不留空白弹窗', () {
      final e = SourinCoreException('   ', 'other');
      expect(userErrorText(e, fallback: '这里暂时打不开'), '这里暂时打不开');
    });

    test('非核心异常 ⇒ 兜底文案里不许出现类名或原始串', () {
      final e = StateError('boom-detail');
      final text = userErrorText(e, fallback: '操作没有完成，请稍后重试');

      expect(text, '操作没有完成，请稍后重试');
      expect(text, isNot(contains('StateError')));
      expect(text, isNot(contains('boom-detail')));
      // 负面对照：老写法确实会漏
      expect('$e', contains('Bad state'));
      expect('$e', contains('boom-detail'));
      expect('$e', contains('boom-detail'));
    });

    test('默认兜底文案不为空，且不含技术名词', () {
      final text = userErrorText(const FormatException('x'));
      expect(text.trim(), isNotEmpty);
      for (final bad in const ['Exception', 'Error', 'null']) {
        expect(text, isNot(contains(bad)));
      }
    });
  });

  // ─────────────────── ② 真核心的真异常 ───────────────────

  group('② 真核心抛出来的异常', () {
    var dataDir = '';
    // 测试专用：不移动 DLL，也能执行缺失依赖的完整 setup/skip/teardown 路径。
    const forceMissingDll = bool.fromEnvironment('T66_FORCE_MISSING_DLL');
    final hasNativeCore =
        !forceMissingDll && File('sourin_core.dll').existsSync();

    setUpAll(() async {
      if (!hasNativeCore) {
        return;
      }
      final base = Directory.systemTemp.createTempSync('sourin-t66-errtext-');
      dataDir = '${base.path}${Platform.pathSeparator}data';
      await SourinCore.startAsync(dataDir);
    });

    tearDownAll(() async {
      if (dataDir.isNotEmpty) {
        // 只清引用，不删目录：真核心可能还持有句柄
        dataDir = '';
      }
    });

    test('读一个不存在的备份包 ⇒ 界面拿到的是插件原文，不是宿主类名', () async {
      if (!hasNativeCore) {
        if (forceMissingDll) {
          /*
           * ★ 审计 B9：`T66_FORCE_MISSING_DLL` 是**人肉模拟**缺件
           *   （不移动 DLL 也能走一遍 setup/skip/teardown），不是"这台机器缺件"。
           *   ⇒ 它继续 skip，但 reason 必须说清"这是模拟，不是真缺"，
           *     否则它会被误读成"Windows 上也允许缺 dll"。
           */
          markTestSkipped(
              'T66_FORCE_MISSING_DLL 强制模拟缺件（**不是**真缺 dll）'
              '—— 本次没有校验到：真核心错误原文那条判据');
          return;
        }
        handleMissingCore(
          missing: kCoreDllPaths.join('、'),
          notVerified: '真核心错误原文那条判据（SourinCoreException → 用户文案）',
        );
        return;
      }

      Object? caught;
      try {
        await SourinApi.backupInspect(
          '${Directory.systemTemp.path}${Platform.pathSeparator}'
          'zz-t66-no-such-backup.sourin',
        );
      } catch (e) {
        caught = e;
      }

      expect(caught, isNotNull, reason: '读不存在的文件必须报错，否则这条判据是空的');
      expect(caught, isA<SourinCoreException>(),
          reason: '真核心的错误一律走 SourinCoreException');

      final shown = userErrorText(caught!, fallback: '读取备份文件失败，请稍后重试');
      expect(shown.trim(), isNotEmpty);
      // ★ 用户可见的东西里不许出现宿主内部名
      expect(shown, isNot(contains('SourinCoreException')));
      expect(shown, isNot(contains('Exception')));
      // 负面对照：老写法（`'$caught'`）确实带类名 —— 两条路必须不同
      expect('$caught', contains('SourinCoreException'));
    });
  });

  // ─────────────────── ③ 源码门禁 ───────────────────

  group('③ lib/ui 不许把异常原文倒进用户可见字段', () {
    test('用户可见桶里一处都不许有；收口过的文件必须真的在调用入口', () {
      final dir = Directory('lib/ui');
      expect(dir.existsSync(), isTrue, reason: '工作目录应当是仓库根');

      final files = <File>[
        for (final f in dir.listSync(recursive: true))
          if (f is File && f.path.endsWith('.dart')) f,
      ];
      expect(files.length, greaterThanOrEqualTo(20),
          reason: '扫到的文件太少 ⇒ 判据可能扫空了');

      final hits = <_Site>[];
      var logSites = 0;
      for (final f in files) {
        final src = f.readAsStringSync();
        final rel = f.path.replaceAll(String.fromCharCode(0x5C), '/');
        hits.addAll(_scanSource(rel, src));
        logSites += _countLogSites(src);
      }

      // ── 打印两个数：用户可见 / 仅日志（报告里要引用它们）
      final perFile = <String, int>{};
      for (final h in hits) {
        perFile[h.file] = (perFile[h.file] ?? 0) + 1;
      }
      // ignore: avoid_print
      print('USERERROR|scope=lib/ui/**'
          '|userVisible=${hits.length}|logOnly=$logSites'
          '|files=${files.length}|filesWithDebt=${perFile.length}');

      // ── ① 收口过的文件：0 处
      //
      // ★★★ 2026-10-20 修：本条原来对 `_expectedCalls` 里**所有**文件要求
      //     `perFile == 0`，而 `player_page.dart` 同时也在 `_debt` 里
      //     （预算 14）。于是两条断言对它提出**数学上不可能同时成立**的要求：
      // ```text
      //   ① 要求 perFile['player_page.dart'] == 0
      //   ③ 要求 perFile['player_page.dart'] == 14
      //   ⇒ 0 == 14 ⇒ 该文件必然红；而且把 14 处真改掉后，
      //     ⑤「总数 == _debt 之和」又会因为总数少了 14 而红
      //   ⇒ **无论改不改代码，这个门禁都不可能绿**
      // ```
      //    根因是「一个文件被两张表同时管辖」，而两张表对它的要求不同。
      //
      // # 裁决：一个文件只受一张表管 —— 有存量预算的，归 ③ 管
      // ```text
      // _expectedCalls = 本轮已收口、要求「插值归零」的文件
      // _debt          = 还有存量、只要求「不超过预算」的文件
      // ⇒ 同时在两表里的文件（目前只有 player_page.dart），以 _debt 为准。
      // ```
      //    ⚠️ 这不是"放宽"：`player_page.dart` 的归零要求**转移**给了 ③
      //       （`== 14` 是精确相等，比 `== 0` 的约束更细 —— 它同时禁止
      //        新增和悄悄变干净）。而且 ② 仍然独立守着它的收口成果
      //       （`userErrorText` 调用数必须 == 1）。
      //    ⚠️ 对**不在** `_debt` 里的收口文件（另外 5 个），本条判据一字未改。
      //
      // ★ 让位规则**读数据** `_debtWins`，不在这里现算 `_debt.containsKey`：
      //   藏在控制流里的规则无法被自检（新交集键会自动静默让位）。
      //   登记表见 `_debtWins` 的长注释；一致性由 ④ 组的自检用例守。
      for (final f in _expectedCalls.keys) {
        if (_debtWins.contains(f)) continue; // 插值条数归 _debt 管，见上
        expect(perFile[f] ?? 0, 0,
            reason: '$f 属于本轮收口范围，又出现了异常插值：'
                '${hits.where((h) => h.file == f).join(' / ')}');
      }

      // ── ② 收口过的文件：入口调用次数必须对得上（少一次 = 退回去了）
      for (final e in _expectedCalls.entries) {
        final src = File(e.key).readAsStringSync();
        final n = RegExp(r'userErrorText\(').allMatches(src).length;
        expect(n, e.value, reason: '${e.key} 调用 userErrorText 的次数变了');
      }

      // ── ③ 预算：既不许涨，也不许悄悄降（降了就得把预算改小）
      for (final e in _debt.entries) {
        final actual = perFile[e.key] ?? 0;
        expect(actual, e.value,
            reason: actual > e.value
                ? '${e.key} 新增了把异常原文倒进界面的一处：'
                    '${hits.where((h) => h.file == e.key).join(' / ')}'
                : '${e.key} 比预算干净了（实测 $actual < 预算 ${e.value}）——'
                    '请把 _debt 里这一行改成 $actual');
      }

      // ── ④ 预算表之外的文件一处都不许有
      for (final entry in perFile.entries) {
        expect(_debt.containsKey(entry.key) || _expectedCalls.containsKey(entry.key),
            isTrue,
            reason: '${entry.key} 不在任何名单里：'
                '${hits.where((h) => h.file == entry.key).join(' / ')}');
      }

      // ── ⑤ 总数必须等于「收口 0 + 预算之和」
      expect(hits.length, _debt.values.fold<int>(0, (a, b) => a + b));
    });
  });

  // ─────────────────── ④ 反恒绿 ───────────────────

  group('④ 扫描器自检（防它永远返回空）', () {
    test('合成样本必须 2 红 / 1 日志 / 2 绿', () {
      const sample = '''
void f() {
  try {
    g();
  } catch (e) {
    _err = '\$e';
    _err2 = '加载失败：\${e}';
    debugPrint('[X] 失败: \$e');
    _ok = '加载失败，请稍后重试';
    _ok2 = '共 3 项';
  }
}
''';
      final hits = _scanSource('sample.dart', sample);
      expect(hits.length, 2, reason: '应识别出 2 处用户可见插值，实际：$hits');
      expect(hits.map((h) => h.line).toSet(), <int>{5, 6});
      expect(_countLogSites(sample), 1, reason: '日志桶应记 1 处');
    });

    test('预算表本身不许为空（空表等于没门禁）', () {
      expect(_debt.length, greaterThanOrEqualTo(10));
      expect(_expectedCalls.length, greaterThanOrEqualTo(5));
    });

    /// ★★★ 表交集自检：两张表不许对**同一维度**提互斥要求
    ///
    /// # 这条在防什么（2026-10-20 的真实故障）
    /// ```text
    /// player_page.dart 同时出现在 _expectedCalls（1 处收口）与 _debt（14 处存量）。
    /// 当时断言① 对**所有** _expectedCalls 文件要求 perFile == 0
    /// ⇒ 与断言③ 的 == 14 冲突 ⇒ 0 == 14 ⇒ 门禁**永远红**。
    /// 而"永远红"比"永远绿"更糟：它会让所有人习惯性忽略这条门禁。
    /// ```
    ///
    /// # 判据（三层，缺一不可）
    /// ```text
    /// Ⅰ 交集里的每个键都必须在 _debtWins 里登记过
    ///    ⇒ 否则断言① 会拿"== 0"去判一个有存量的文件 ⇒ 必然红
    ///    ⇒ 且这种红**不会被这条自检以外的东西发现**（要等真跑一次才炸）
    ///
    /// Ⅱ _debtWins 里不许有**不在交集**的键
    ///    ⇒ 否则是一条死规则：它让位了一个根本不冲突的文件，
    ///      读代码的人会以为那个文件"有存量"，而实际没有
    ///
    /// Ⅲ 交集键在 _debt 里的预算必须 > 0
    ///    ⇒ 若预算是 0，说明它其实已经干净 ⇒ 该从 _debt 删掉、从 _debtWins 删掉，
    ///      让断言① 重新接管（== 0）。留着只会让"谁管辖"变得含糊。
    /// ```
    ///
    /// ⚠️ 注意这条自检**不**判"交集存在"—— 交集本身是合法的
    ///    （`player_page` 就是"本轮动了一部分、整体还有存量"的正常过渡态）。
    ///    它判的是「**让位登记**与**数据**是否一致」。
    test('★★ 两张表不许对同一维度提互斥要求（表交集自检）', () {
      final overlap =
          _debt.keys.toSet().intersection(_expectedCalls.keys.toSet());

      // ignore: avoid_print
      print('TABLEOVERLAP|debt=${_debt.length}'
          '|expectedCalls=${_expectedCalls.length}'
          '|overlap=${overlap.length}'
          '|debtWins=${_debtWins.length}'
          '|overlapKeys=$overlap');

      // ── Ⅰ 交集键必须全部登记让位 ──
      for (final f in overlap) {
        expect(_debtWins.contains(f), isTrue,
            reason: '★★★ $f 同时在 _debt 与 _expectedCalls 里，'
                '但没在 _debtWins 登记让位 ⇒ 断言① 会要求它 perFile==0，'
                '而断言③ 要求 perFile==${_debt[f]} ⇒ '
                '0 == ${_debt[f]} 无解 ⇒ 这条门禁将永远红。'
                '修法：把 $f 加进 _debtWins（若确实还有存量），'
                '或把它从 _debt 里删掉（若已清零）。');
      }

      // ── Ⅱ _debtWins 不许有死规则（不在交集里） ──
      for (final f in _debtWins) {
        expect(overlap.contains(f), isTrue,
            reason: '★ _debtWins 里的 $f 并不在 _debt∩_expectedCalls 里 ⇒ '
                '这是一条死规则：它没有让位任何真正冲突的文件。'
                '（它要么不在 _debt 里，要么不在 _expectedCalls 里）'
                '请删掉它，免得读代码的人误以为该文件有存量。');
      }

      // ── Ⅲ 交集键的预算必须 > 0 ──
      for (final f in overlap) {
        final budget = _debt[f]!;
        expect(budget, greaterThan(0),
            reason: '★★ $f 在 _debt 里的预算是 0 ⇒ 它其实已经干净。'
                '把它从 _debt 与 _debtWins 一起删掉，'
                '让断言① 重新接管（要求 perFile == 0）。');
      }
    });
  });
}
