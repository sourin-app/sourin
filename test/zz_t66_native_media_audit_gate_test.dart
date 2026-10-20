// ═══════════════════════════════════════════════════════════════════════
//  ★ 2026-10-21（round-66）：native-media 抽检门禁
// ═══════════════════════════════════════════════════════════════════════
//
// # 这个门禁守的是什么
//
// `dart_test.yaml` 把 `native-media` 标签设成**默认跳过**（加载 libmpv 会让
// flutter_tester 偶发 native 崩溃 c0000005）。代价是：
//
// ```text
// 全量跑 ⇒ skip 只体现为 `~N` 计数器 +1
//        ⇒ `grep "All tests skipped"` 计数 = 0（什么都看不到）
//        ⇒ 一条**恒红**的断言可以躺在这里很久，没有任何东西会报
// ```
//
// 真实事故（2026-10-21）：`player_episode_nav_boundary_test.dart` 的阳性对照
// 恒红很久，报 `Found 0 widgets with text "下一集"`，没人发现 —— 因为它默认不跑。
//
// # ★★★ 判据设计：测"有没有人定期去看"，不测"里面有没有红"
//
// ```text
// ❌ 「所有 skip 文件必须绿」
//    ⇒ 不可能。它们挂标签**就是因为**加载 libmpv 会崩，
//      真跑本来就可能失败（今天实测 player_panel_wiring 就是 exit=79）。
//
// ❌ 「让它不红」
//    ⇒ 等于删测试。本仓已经因为"删掉难修的测试"记过教训。
//
// ✅ 「每个文件都有一个最近抽检时间，且不超过 N 天」
//    ⇒ 可执行、可判定、不逼人改产品代码。
//    ⇒ 它把「人的纪律」变成「机器能查的东西」。
// ```
//
// 这正是本仓那条纪律的落地：
// 「一个看起来像结果的东西，必须携带『我查了多少』的信息」。
//
// # 数据来源：`docs/notes/native-media-audit.json`
//
// ```json
// {
//   "player_episode_nav_boundary_test.dart": {
//     "lastAudited": "2026-10-21",
//     "result": "+6 ~0 -0",
//     "note": "阳性对照曾恒红（find.text vs tooltip），已修"
//   }
// }
// ```
//
// ⚠️ 键是**相对 `test/` 的文件名**（不是 `test/xxx.dart`），
//    这样改名/移动目录时不必同步改 JSON 里的路径前缀。
//
// # 四条判据（全部作用域无关）
//
// ```text
// a) 扫到的 native-media 文件数 > 0          ← 阳性对照，防扫描器空转
// b) 每个扫到的文件在 JSON 里都有记录         ← 防"漏登记"
// c) lastAudited 距今天 <= kMaxAgeDays       ← 防"登记了但从不更新"
// d) JSON 里的每个文件名都真实存在           ← 防腐化（测试删了但 JSON 还留着）
// ```

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 抽检记录文件（相对仓库根）。
const String kAuditPath = 'docs/notes/native-media-audit.json';

/// 允许的最大"未抽检天数"。
///
/// 30 天的选择理由：比一轮迭代长（不会天天催），
/// 又短到"一个恒红断言躺过一个迭代"会被抓到。
const int kMaxAgeDays = 30;

/// 要扫的标签名。
const String kTag = 'native-media';

/// 从一段 Dart 源码里取出所有 `@Tags([...])` 里的标签名。
///
/// ⚠️ **必须只认真正的 `@Tags(...)`，不能裸 `contains('native-media')`** ——
///    实测：83 个文件提到 `native-media`，但只有 **56** 个真的挂了标签；
///    其余 27 个是**注释里在讨论这个标签**（例如
///    `skip_pair_grouping_test.dart` 明确写着"不能改成 @Tags(native-media)"）。
///    裸 contains 会把它们全算进来 ⇒ 要求 27 个不该登记的文件也登记。
List<String> tagsInSource(String src) {
  final out = <String>[];
  // 覆盖两种写法：`@Tags(['a'])` 与 `@Tags(<String>['a'])`
  final re = RegExp(r'@Tags\s*\(\s*(?:<String>\s*)?\[(.*?)\]\s*\)',
      multiLine: true, dotAll: true);
  for (final m in re.allMatches(src)) {
    final body = m.group(1) ?? '';
    for (final s in RegExp(r"'([^']*)'").allMatches(body)) {
      out.add(s.group(1)!);
    }
  }
  return out;
}

/// 扫描 `test/` 下所有真正挂了 [kTag] 的文件（相对 `test/` 的路径，`/` 分隔）。
List<String> scanTaggedFiles() {
  final dir = Directory('test');
  if (!dir.existsSync()) return <String>[];
  final out = <String>[];
  for (final e in dir.listSync(recursive: true)) {
    if (e is! File || !e.path.toLowerCase().endsWith('.dart')) continue;
    final src = e.readAsStringSync();
    // 先做一次廉价的粗筛，避免对 500+ 文件全跑正则
    if (!src.contains(kTag)) continue;
    if (tagsInSource(src).contains(kTag)) {
      out.add(e.path.replaceAll('\\', '/').replaceFirst(RegExp(r'^test/'), ''));
    }
  }
  out.sort();
  return out;
}

/// 读抽检记录；文件不存在时返回空表（由判据 b 报红，不在这里抛）。
Map<String, dynamic> readAudit() {
  final f = File(kAuditPath);
  if (!f.existsSync()) return <String, dynamic>{};
  final raw = f.readAsStringSync();
  final decoded = jsonDecode(raw);
  if (decoded is! Map) {
    throw StateError('$kAuditPath 的顶层必须是 JSON object，实际是 '
        '${decoded.runtimeType}');
  }
  return Map<String, dynamic>.from(decoded);
}

void main() {
  group('★ native-media 抽检门禁（防"恒红断言躺在 skip 区"）', () {
    test('★★★ a) 阳性对照：扫到的 native-media 文件数 > 0', () {
      final files = scanTaggedFiles();
      /*
       * ★ 这条防的是：扫描器坏了（正则写错 / 目录名变了）⇒ 判据 b/c 全部空转
       *   ⇒ 门禁变成"什么都没查，也没报错"，与"全部通过"长得一样。
       */
      expect(
        files,
        isNotEmpty,
        reason: '★ 阳性对照失败：一个挂 @Tags([\'$kTag\']) 的文件都没扫到。\n'
            '⇒ 扫描器坏了，判据 b/c 全部空转 ⇒ 本门禁是假绿。\n'
            '排查：① test/ 目录还在吗 ② tagsInSource 的正则还能匹配 '
            '@Tags([...]) 吗 ③ 是否有人把标签名改了',
      );

      // 顺带钉一个下限：仓里长期有 50+ 个这样的文件，
      // 掉到个位数说明大批标签被移除或扫描器漏扫。
      expect(
        files.length,
        greaterThan(10),
        reason: '★ 只扫到 ${files.length} 个 —— 与历史规模（50+）差太多，'
            '先确认是标签真被批量移除，还是扫描器漏扫',
      );

      // ignore: avoid_print
      print('[AUDIT] 扫到 ${files.length} 个 @Tags([\'$kTag\']) 文件');
    });

    test('★★★ b) 每个 native-media 文件都必须在抽检记录里登记', () {
      final files = scanTaggedFiles();
      final audit = readAudit();

      final missing = <String>[
        for (final f in files)
          if (!audit.containsKey(f)) f
      ];

      expect(
        missing,
        isEmpty,
        reason: '★★★ 这些文件挂 `$kTag` 标签（默认不跑），但**从未被登记抽检**。\n'
            '⇒ 里面有没有恒红断言，没人知道。\n'
            '⇒ 请在 `$kAuditPath` 里加一条记录，并用\n'
            '   `flutter test test/<文件> --run-skipped --concurrency=1`\n'
            '   跑一次，把**真实读数**填进 `result`（例如 `+6 ~0 -0`）。\n'
            '⚠️ 不许伪造 lastAudited —— 没跑过就不要写。\n'
            '未登记的文件：\n  ${missing.join('\n  ')}',
      );
    });

    test('★★★ c) lastAudited 不得超过 $kMaxAgeDays 天', () {
      final audit = readAudit();
      final now = DateTime.now();
      final bad = <String>[];
      final invalid = <String>[];

      audit.forEach((name, value) {
        if (value is! Map) {
          invalid.add('$name → 记录必须是 object，实际 ${value.runtimeType}');
          return;
        }
        final raw = value['lastAudited'];
        /*
         * ★★★ `lastAudited == null` 有两种完全不同的含义，必须分开判：
         *
         * ```text
         * ① 「从未抽检」      ⇒ 红。这就是本门禁要抓的"没人去看"。
         * ② 「抽检了，但原生崩溃，没拿到读数」
         *                    ⇒ **不该红**。有人真的去看了（跑了 400 秒），
         *                      只是 libmpv 崩了。逼他"改到绿"是不可能的
         *                      （那正是它们挂标签的原因）。
         * ```
         *
         * 区分方式：`audited` 字段。
         * ```text
         * audited: false + lastAudited: null         ⇒ ② 抽检过但崩了
         * audited: false + lastAudited: "2026-10-21" ⇒ ② 且**记录了抽检时间**
         * 缺 audited 且缺 lastAudited                ⇒ ① 从未抽检 ⇒ 红
         * ```
         *
         * ⚠️ 这里**不能**用"lastAudited 必须非空"一刀切 —— 那会逼人给崩溃的
         *    文件编一个日期（造假），或者干脆把测试删掉（更糟）。
         *    本仓反复记过：「判据强度必须与对象边界对齐」。
         */
        final audited = value['audited'];
        final everAudited = audited is bool;

        if (raw == null) {
          if (!everAudited) {
            invalid.add('$name → 缺 lastAudited **且**缺 audited 字段 ⇒ '
                '从未抽检过（判据 c 的核心红线）');
          }
          // 有 audited 字段但 lastAudited 为 null：抽检过、但没拿到读数 ⇒ 合法
          return;
        }
        if (raw is! String) {
          invalid.add('$name → lastAudited 不是字符串：$raw');
          return;
        }
        final dt = DateTime.tryParse(raw);
        if (dt == null) {
          invalid.add('$name → lastAudited 不是合法日期：$raw');
          return;
        }
        final days = now.difference(dt).inDays;
        if (days > kMaxAgeDays) {
          bad.add('$name → lastAudited=$raw，距今 $days 天（上限 $kMaxAgeDays）');
        }
      });

      expect(
        invalid,
        isEmpty,
        reason: '★★★ 这些文件**从未被登记抽检** —— 本门禁的核心红线。\n'
            '⇒ 它们默认不跑，里面有没有恒红断言，没有任何东西会知道。\n'
            '⇒ 处置：真的跑一次\n'
            '   `flutter test test/<文件> --run-skipped --concurrency=1`\n'
            '   然后写 `{"lastAudited": "<今天>", "audited": true/false, '
            '"result": "<真实读数或 null>", "note": "<真实情况>"}`\n'
            '⚠️ 原生崩溃（exit=79 / did not complete）**也算抽检过** ——\n'
            '   写 `"audited": false` 并说明崩溃即可，不要为了变绿而编日期。\n'
            '从未登记的：\n  ${invalid.join('\n  ')}',
      );
      expect(
        bad,
        isEmpty,
        reason: '★★★ 这些文件**超过 $kMaxAgeDays 天没被抽检**了。\n'
            '⇒ 它们默认不跑，里面若出现恒红断言，没有任何东西会报。\n'
            '⇒ 请抽检并更新 `$kAuditPath` 里的 lastAudited + result。\n'
            '⚠️ 只改日期不改 result 是造假 —— 必须真的跑一次。\n'
            '过期的：\n  ${bad.join('\n  ')}',
      );
    });

    test('★★★ d) 抽检记录里的每个文件都必须真实存在（防腐化）', () {
      final files = scanTaggedFiles().toSet();
      final audit = readAudit();

      final stale = <String>[];
      final noLongerTagged = <String>[];

      for (final name in audit.keys) {
        final f = File('test/$name');
        if (!f.existsSync()) {
          stale.add('$name → test/$name 不存在（测试被删/改名了？）');
        } else if (!files.contains(name)) {
          noLongerTagged.add(
              '$name → 文件在，但已不再挂 @Tags([\'$kTag\'])（记录可以删了）');
        }
      }

      expect(
        stale,
        isEmpty,
        reason: '★★★ 抽检记录里有**不存在的文件** —— 记录在腐烂。\n'
            '⇒ 这类条目会永久占位，让"全部已抽检"变成假象。\n'
            '⇒ 请从 `$kAuditPath` 删掉它们。\n'
            '失效条目：\n  ${stale.join('\n  ')}',
      );

      /*
       * ⚠️ 这一条（文件在但已不挂标签）**不判红**，只打印。
       *
       * 理由：它可能是"有人把标签去掉了，测试现在默认跑"——那是**好事**，
       * 不该因为 JSON 没同步而变红。但也不能静默：留一条打印让人知道可以清理。
       * ⇒ 「可判的判红，不可判的打印」。这条边界是本仓反复踩过的。
       */
      if (noLongerTagged.isNotEmpty) {
        // ignore: avoid_print
        print('[AUDIT] 以下记录已失效（文件不再挂标签），可以从 JSON 删掉：\n'
            '  ${noLongerTagged.join('\n  ')}');
      }
    });
  });
}
