// ═══════════════════════════════════════════════════════════════════════
//  R2-#4 实机取证辅助：把一份**真订阅**导入指定隔离数据目录（供随后跑真 exe）
// ═══════════════════════════════════════════════════════════════════════
//
// # 为什么需要它
// ```text
// 实机读数要看到"渠道条真的画出来"，前提是那个隔离目录里**有 TVBox 子站**。
// 而导入走的是 `import_tvbox_config`（产品命令）—— 用真核心跑一遍最忠实
//   （不是手写 json 塞文件：那是**另造一份契约**，字段漂了不会被发现）。
// ```
//
// 用法：
// ```powershell
// $env:R2N9_SEED_DIR = '.probe/r2-n9-glass-real-<TS>/data'
// flutter test test/zz_r2_n9_seed_probe.dart --run-skipped --tags needs-network --concurrency=1
// ```
// ⚠️ 真网络 ⇒ 打 `needs-network`（默认跳过，与 `zz_n9_real_network_probe.dart` 同档）。
@Tags(['needs-network'])
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
    req.headers.set('User-Agent', 'SourinSpike-R2N9-seed/1.0');
    final resp = await req.close().timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) throw StateError('HTTP ${resp.statusCode}');
    final bytes = await resp.fold<List<int>>(
      <int>[],
      (acc, chunk) => acc..addAll(chunk),
    );
    // ⚠️ 必须 utf8（Windows 的 SystemEncoding 是 ANSI ⇒ 会解成乱码）
    return utf8.decode(bytes, allowMalformed: true);
  } finally {
    client.close(force: true);
  }
}

void main() {
  test('把真订阅导入 R2N9_SEED_DIR 指定的隔离数据目录', () async {
    final dir = Platform.environment['R2N9_SEED_DIR']?.trim() ?? '';
    if (dir.isEmpty) {
      print('SEED_SKIP 未设 R2N9_SEED_DIR');
      return;
    }
    Directory(dir).createSync(recursive: true);
    print('SEED_DIR=$dir');
    await SourinCore.startAsync(dir);

    final before = await fetchAggChannels();
    print('SEED_BEFORE channels=${before.channels.length}');

    final text = await _fetchText(kSubUrl);
    print('SEED_SUB_BYTES=${text.length}');
    final r = await SourinApi.importTvboxConfig(text);
    print('SEED_IMPORT total=${r.totalSites} imported=${r.imported.length} '
        'skipped=${r.skipped.length}');

    final after = await fetchAggChannels();
    print('SEED_AFTER channels=${after.channels.length}');
    for (final c in after.channels.take(6)) {
      print('SEED_CHANNEL ${c.id} | ${c.name}');
    }
    // ★ 核心要**正常退出**才能把 sqlite 刷干净：这里不显式关库，
    //   由进程退出收尾（产品里也是这么活的）。
    print('SEED_DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}