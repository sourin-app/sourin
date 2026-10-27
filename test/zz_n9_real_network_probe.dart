@Tags(['needs-network'])
// ═══════════════════════════════════════════════════════════════════════
//  N9 真网读数探针（**实网**，不是替身）
// ═══════════════════════════════════════════════════════════════════════
//
// 目的：把"渠道清单 / 按渠道取数"两条命令的**真返回**打进 stdout，
//       供 `.probe/n9-ui-real-network.log` 存证。
//
// 纪律：
//   · 隔离数据目录（系统临时目录）⇒ 绝不碰开发者真实数据
//   · 只读命令 + 一次真订阅导入
//   · 收尾删沙盒
//
// ══════════════════════════════════════════════════════════════════════
//  ★★★ `needs-network` tag（Lead 2026-10-27 裁定，必加）
// ══════════════════════════════════════════════════════════════════════
//
// # 为什么必须加（不是"可选的美化"）
// ```text
// 本文件**真发外网请求**（订阅 `https://8815.kstore.vip/tvbox/wmz`）:
//   · CI runner / 断网机器 ⇒ 请求打不通 ⇒ SUBFETCH_FAIL ⇒ 用例红
//   · 那个红与**被测代码对错无关**（契约见 dart_test.yaml 的 needs-network 说明）
//   ⇒ 留在默认跑里 ⇒ 全量三栏读数被"外网打不通"的噪声污染 ⇒
//      **③ 真失败会被淹没**（本仓点名的那类缺陷）。
// ```
// ★ 约定与先例：`dart_test.yaml` 的 `needs-network` 档（`skip:` 默认跳过）；
//   先例 `test/zz_t64_e2e_probe_test.dart:1`。
// ⚠️ 这不是新造约定 —— 本仓已有这一档，直接用。
//
// # 怎么复现本次实网读数（**必须显式放行**）
// ```powershell
// flutter test test/zz_n9_real_network_probe.dart `
//   --run-skipped --tags needs-network --concurrency=1
// ```
// ⇒ 输出即 `.probe/n9-ui-real-network.log` 的内容（真订阅 21214 B、
//   `channels=17`、`channel_home` 8 个区块、`<渠道id>::<原区块id>` 前缀）。
// ⚠️ 默认跑（不加 `--run-skipped --tags needs-network`）本文件**整档跳过**，
//    不会再进全量批跑发真请求。
library;

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/ffi.dart';
import 'package:sourin_spike/core/sourin_api.dart';
import 'package:sourin_spike/ui/home_page.dart';

/// Owner 实际订阅（[计划19] §19.1 实测 23668 B / sites 100）
const String kSubUrl = 'https://8815.kstore.vip/tvbox/wmz';

/// 真网络取订阅文本（探针自带的极小 helper）
///
/// ⚠️ 产品里没有"按 URL 直接导入"的命令（只有 `import_tvbox_config` 收**文本**）
///    —— 界面侧走的是"用户贴文本"或"设置页测连通"。探针只是要一份**真配置**，
///    所以自己取一次文本，再喂给**产品那条** `importTvboxConfig`。
Future<String> _fetchText(String url) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final req = await client.getUrl(Uri.parse(url));
    req.headers.set('User-Agent', 'SourinSpike-N9-probe/1.0');
    final resp = await req.close().timeout(const Duration(seconds: 30));
    if (resp.statusCode != 200) {
      throw StateError('HTTP ${resp.statusCode}');
    }
    // ⚠️ 必须用 **utf8** 解码：Windows 上 `SystemEncoding` 是 ANSI 代码页，
    //    按它解出来的是乱码（实测：`配置不是合法 JSON：expected , or }`）
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
  test('N9 实网读数：真订阅导入 ⇒ channels() / channel_home() 真返回', () async {
    final dir = Directory.systemTemp.createTempSync('n9-realnet-');
    print('SANDBOX=${dir.path}');
    await SourinCore.startAsync(dir.path);

    // ── 0) 导入前：渠道清单应为空（且是 ok:true 的空，不是错误）
    final before = await fetchAggChannels();
    print('BEFORE ok=${before.ok} channels=${before.channels.length}');

    // ── 1) 真网络取订阅并导入
    String text;
    try {
      text = await _fetchText(kSubUrl);
    } catch (e) {
      print('SUBFETCH_FAIL=$e');
      _tryCleanup(dir);
      return;
    }
    print('SUB_BYTES=${text.length}');
    final r = await SourinApi.importTvboxConfig(text);
    print('IMPORT total=${r.totalSites} imported=${r.imported.length} '
        'skipped=${r.skipped.length}');
    for (final s in r.skipped.take(8)) {
      print('SKIP name=${s.name} stage=${s.stage} reason=${s.reason}');
    }

    // ── 2) 导入后：渠道清单
    final after = await fetchAggChannels();
    print('AFTER ok=${after.ok} channels=${after.channels.length}');
    print('CHANNELS=${after.channels.map((c) => '${c.id}:${c.name}').take(8).toList()}');

    // ── 3) 按渠道取数（取第一个渠道，真发网络请求）
    if (after.channels.isNotEmpty) {
      final id = after.channels.first.id;
      final t0 = DateTime.now();
      try {
        final home = await fetchAggChannelHome(id);
        final ms = DateTime.now().difference(t0).inMilliseconds;
        print('CHANNEL_HOME id=$id name=${home.channelName} '
            'sections=${home.sections.length} ms=$ms');
        for (final s in home.sections.take(5)) {
          print('  SECTION id=${s.id} title=${s.title} type=${s.source.type} '
              'cat=${s.source.categoryId}');
        }
      } catch (e) {
        print('CHANNEL_HOME_FAIL id=$id err=$e');
      }
    }

    // ── 4) 懒加载不变式：再取一次同渠道（不该重复打网络；这里只证"不抛"）
    if (after.channels.length > 1) {
      final id2 = after.channels[1].id;
      final home2 = await fetchAggChannelHome(id2);
      print('CHANNEL_HOME2 id=$id2 sections=${home2.sections.length}');
    }

    _tryCleanup(dir);
    print('DONE');
  }, timeout: const Timeout(Duration(minutes: 8)));
}

/// 收尾删沙盒（**清理失败不算用例失败**）
///
/// ⚠️ 实测：核心的 SQLite 连接释放有延迟 ⇒ 立刻 `deleteSync` 会
///    `PathAccessException: errno = 32`（另一个程序正在使用此文件）。
///    那是**清理**问题，不是被测对象的问题 —— 但直接抛会把本探针标记成
///    失败，掩盖掉前面那些真读数（本仓点名的"仪器故障伪装成结论"）。
/// ⇒ 重试几次，仍不行就如实打一行（沙盒在系统临时目录，OS 会回收）。
void _tryCleanup(Directory dir) {
  for (var i = 0; i < 5; i++) {
    try {
      if (!dir.existsSync()) return;
      dir.deleteSync(recursive: true);
      print('SANDBOX_CLEANED=${dir.path}');
      return;
    } catch (_) {
      sleep(const Duration(milliseconds: 400));
    }
  }
  print('SANDBOX_CLEANUP_DEFERRED=${dir.path}（临时目录，交给 OS 回收）');
}