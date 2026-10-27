@Tags(['needs-network'])
// ═══════════════════════════════════════════════════════════════════════
//  R2-#4 取证探针：**重启后渠道清单是否还在**（N9 的恢复路径）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么要这一条（实机读数暴露的现象）
// ```text
// 实机跑真 exe（隔离目录里已导入 100 站 / 19 个可用渠道）：
//   [HOME] 聚合渠道清单: **0 个**（）
// ⇒ 而**同一条命令**在"刚导入完的那个进程里"返回 19 个（见 r2-n9-glass-seed.log）。
// ⇒ 说明差异在**重启/恢复**这条路径上，不在渠道条视觉上。
// ```
//
// # 本探针要回答的问题（模拟"进程重启"）
// ```text
// 同一个隔离数据目录：
//   ① 进程 A：导入订阅 ⇒ channels() = N
//   ② 进程 B（**新进程**，读同一目录，不重新导入）⇒ channels() = ?
// ⇒ 若 B 得 0 而 A 得 N ⇒ **恢复路径丢了渠道**（真缺陷，要报 Lead）
// ```
// ⚠️ 这里用**同一测试进程内的两次 start**是不够的（registry 是进程级）；
//    必须**真的两个进程** —— 所以本文件用两条用例 + 环境变量分派：
//    一条（PHASE=import）导入，另一条（PHASE=reload）只读。
//    跑法见文件尾的命令。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/home_page.dart';

const String kSubUrl = 'https://8815.kstore.vip/tvbox/wmz';

Future<String> _fetchText(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    final resp = await req.close().timeout(const Duration(seconds: 30));
    final bytes = await resp.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('PHASE=import：导入订阅，报 channels()', () async {
    final dir = Platform.environment['R2N9_PHASE_DIR']?.trim() ?? '';
    if (dir.isEmpty) {
      print('PHASE_SKIP 未设 R2N9_PHASE_DIR');
      return;
    }
    Directory(dir).createSync(recursive: true);
    await SourinCore.startAsync(dir);
    final text = await _fetchText(kSubUrl);
    final r = await SourinApi.importTvboxConfig(text);
    final ch = await fetchAggChannels();
    print('PHASE_IMPORT imported=${r.imported.length} channels=${ch.channels.length}');
    for (final c in ch.channels.take(4)) {
      print('PHASE_IMPORT_CH ${c.id} | ${c.name}');
    }
  }, timeout: const Timeout(Duration(minutes: 8)));

  test('PHASE=reload：**新进程**只读同一目录，报 channels()', () async {
    final dir = Platform.environment['R2N9_PHASE_DIR']?.trim() ?? '';
    if (dir.isEmpty) {
      print('PHASE_SKIP 未设 R2N9_PHASE_DIR');
      return;
    }
    await SourinCore.startAsync(dir);
    final ch = await fetchAggChannels();
    print('PHASE_RELOAD channels=${ch.channels.length}');
    for (final c in ch.channels.take(4)) {
      print('PHASE_RELOAD_CH ${c.id} | ${c.name}');
    }
    // ★ 顺带把"注册表里到底有没有那些子站 + 它们 hidden 不 hidden"打出来
    //   —— 这是定位"恢复后渠道清单空"的关键一步（不是猜）
    final provs = await SourinApi.listProviders();
    print('PHASE_RELOAD_ALL_PROVIDERS=${provs.length}');
    for (final p in provs.take(12)) {
      print('PHASE_RELOAD_PROV ${p.id} hidden=${p.hidden} kind=${p.kind}');
    }
    final raw = await SourinCore.callAsync('list_providers');
    final hiddenCount = (raw is List)
        ? raw.where((e) => e is Map && e['hidden'] == true).length
        : -1;
    print('PHASE_RELOAD_RAW_TOTAL=${(raw is List) ? raw.length : -1} '
        'RAW_HIDDEN=$hiddenCount');
  }, timeout: const Timeout(Duration(minutes: 4)));
}