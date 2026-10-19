// ═══════════════════════════════════════════════════════════════════════
//  `lib/` 下的**真机探针**不得被接进产品
// ═══════════════════════════════════════════════════════════════════════
//
// # 背景
//
// ```text
// `lib/` 下有 **43 个** `*probe*.dart` —— 它们是「真机取证入口」：
//   各自以 `flutter build windows -t lib/tXXX_probe.dart` 单独编译，
//   在真机上跑一次拿读数（截图 / 像素 / 几何 / 日志）。
//
// ★ 它们**不是产品代码**，但住在 `lib/` 里 ⇒ 会被各种「扫全仓 lib/」的
//   门禁当成产品代码扫到（如 `zz_t66_r4_dialog_consistency_test`）。
//
// ★ 为什么不搬走：很多探针要 import `lib/` 的**私有成员**（`_Foo` 类、
//   内部字段）才能读状态 —— 搬到 `test/` 下就拿不到了。
//   ⇒ 登记豁免，而不是搬家。
// ```
//
// # 本门禁守什么（**唯一**要守的事）
//
// ```text
// 探针可以被单独编译，但**绝不能出现在产品的依赖链上**。
// 判据：从 `lib/shell.dart`（产品入口，AGENTS §1）出发做传递依赖闭包，
//      闭包里**不许**出现任何 `*probe*.dart`。
//
// ★ 为什么这条比「把文件搬走」有价值：
//   搬走只解决"看着乱"；本门禁解决"探针被误接进产品"——
//   那会让 `flutter build` 把调试代码打进发行包，且**没有任何现有门禁会发现**。
// ```
//
// # 实测读数（2026-10-19，写这条门禁时）
//
// ```text
// 从 lib/shell.dart 出发的传递依赖闭包 = 151 个文件
// 其中 *probe*.dart                    = 0
// lib/ 下 probe 文件总数               = 43
// 其中在闭包内                         = 0
// ⇒ 当前是干净的；本门禁是**防回归**。
// ```
//
// # 关于「产物里有没有 probe 符号」
//
// ```text
// 我试过扫 `build/.../data/app.so` 的字符串表，**结论不可信**：
//   阳性对照（产品 UI 文案如 '健康检测'）命中率只有 0%~7%
//   ⇒ Dart AOT 会把大部分字符串内联/压缩，明文搜索不可靠。
// ⇒ 本门禁**不**扫产物，只做源码级依赖闭包 —— 那是确定性的。
//   （产物侧核验需要 `flutter build --analyze-size` 之类，成本远高于收益。）
// ```
//
// ⚠️ 不挂 native-media：纯源码扫描，不加载任何原生库。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 产品入口（AGENTS §1：`lib/main.dart` 是早期 spike，**不是**产品）
const String _kEntry = 'lib/shell.dart';

final RegExp _importRe = RegExp(
  r'''^\s*(?:import|export)\s+['"]([^'"]+)['"]''',
  multiLine: true,
);
final RegExp _partRe = RegExp(
  r'''^\s*part\s+['"]([^'"]+)['"]''',
  multiLine: true,
);

String _norm(String p) => p.replaceAll('\\', '/');

/// 把 import/export 的 uri 解析成仓库内相对路径；外部包返回 null
String? _resolve(String baseDir, String uri) {
  if (uri.startsWith('package:sourin_spike/')) {
    return _norm('lib/${uri.substring('package:sourin_spike/'.length)}');
  }
  if (uri.startsWith('package:') || uri.startsWith('dart:')) return null;
  if (uri.startsWith('http')) return null;
  // 相对路径：手工拼接再规范化（避免依赖 path 包）
  final joined = _norm('$baseDir/$uri');
  final parts = <String>[];
  for (final seg in joined.split('/')) {
    if (seg == '.' || seg.isEmpty) continue;
    if (seg == '..') {
      if (parts.isNotEmpty) parts.removeLast();
      continue;
    }
    parts.add(seg);
  }
  return parts.join('/');
}

/// 某文件的直接依赖（只含仓库内文件）
List<String> _directDeps(String path) {
  final f = File(path);
  if (!f.existsSync()) return const <String>[];
  final src = f.readAsStringSync();
  final base = _norm(f.parent.path);
  final out = <String>[];
  for (final m in _importRe.allMatches(src)) {
    final r = _resolve(base, m.group(1)!);
    if (r != null) out.add(r);
  }
  for (final m in _partRe.allMatches(src)) {
    final r = _resolve(base, m.group(1)!);
    if (r != null) out.add(r);
  }
  return out;
}

bool _isProbe(String path) =>
    _norm(path).split('/').last.toLowerCase().contains('probe');

void main() {
  test('★★★ 产品入口的传递依赖闭包里不许出现 *probe*.dart', () {
    expect(File(_kEntry).existsSync(), isTrue,
        reason: '★ 前提：产品入口 $_kEntry 不存在 ⇒ 本门禁失去意义');

    // BFS 求闭包
    final seen = <String>{};
    final queue = <String>[_norm(_kEntry)];
    final parent = <String, String>{}; // 子 → 从哪个文件引进来（用于报路径）
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      if (seen.contains(cur)) continue;
      if (!File(cur).existsSync()) continue;
      seen.add(cur);
      for (final d in _directDeps(cur)) {
        if (!seen.contains(d)) {
          parent.putIfAbsent(d, () => cur);
          queue.add(d);
        }
      }
    }

    // 闭包内文件数（用于失败时的诊断）
    final probesInClosure = seen.where(_isProbe).toList()..sort();

    expect(
      probesInClosure,
      isEmpty,
      reason: '★★★ 产品的传递依赖里出现了探针文件：\n'
          '${probesInClosure.map((p) => '  $p  ← 由 ${parent[p]} 引入').join('\n')}\n'
          '★ 探针是**真机取证入口**，不是产品代码。它进了依赖链 ⇒ '
          '`flutter build` 会把调试代码打进发行包。\n'
          '★ 修法：把那一行 import 去掉（探针自己单独 `-t` 编译即可）。\n'
          '★ 闭包共 ${seen.length} 个文件。',
    );
  });

  test('★ 阳性对照：闭包里确实有产品文件（否则上面那条是空断言）', () {
    // 若 _resolve / _directDeps 写错了，闭包可能只有 1 个文件
    // ⇒ 上一条会"因为没找到任何 probe"而通过 ⇒ 假绿。
    final seen = <String>{};
    final queue = <String>[_norm(_kEntry)];
    while (queue.isNotEmpty) {
      final cur = queue.removeAt(0);
      if (seen.contains(cur)) continue;
      if (!File(cur).existsSync()) continue;
      seen.add(cur);
      for (final d in _directDeps(cur)) {
        if (!seen.contains(d)) queue.add(d);
      }
    }
    expect(
      seen.length,
      greaterThan(50),
      reason: '★ 闭包只有 ${seen.length} 个文件 ⇒ 解析器坏了（正常应是 100+）。'
          '若这里红，上一条「没有 probe」是**假绿**。',
    );
    expect(
      seen.contains('lib/ui/player_page.dart'),
      isTrue,
      reason: '★ 闭包里应该有 lib/ui/player_page.dart（产品核心页）——'
          '它是最有代表性的传递依赖。缺失说明解析器漏了某类 import。',
    );
  });

  test('★ 全仓 probe 文件数量 —— 变动时提醒复核豁免范围', () {
    final all = <String>[];
    for (final e in Directory('lib').listSync(recursive: true)) {
      if (e is File && e.path.endsWith('.dart') && _isProbe(e.path)) {
        all.add(_norm(e.path));
      }
    }
    // 不设死阈值（探针会增删），只在数量异常时给提示
    expect(all, isNotEmpty,
        reason: '★ 一个 probe 都没有 ⇒ 要么全被搬走了，'
            '要么 `_isProbe` 的匹配规则坏了（当前规则：文件名含 "probe"）');
    // ignore: avoid_print
    print('[探针豁免范围] lib/ 下 *probe*.dart 共 ${all.length} 个');
  });
}
