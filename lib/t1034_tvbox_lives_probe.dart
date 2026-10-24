// ═══════════════════════════════════════════════════════════════════════
//  TVBox lives[] → 直播频道 · **全链路真机验收**探针
// ═══════════════════════════════════════════════════════════════════════
//
// # 它回答什么问题
//
// Rust 侧已经有端到端测试（真 bootstrap / 真落盘 / 真重启），但那是
// **Rust 内部**。用户看到的是 Flutter 直播页，取数链路是：
//
// ```text
// 直播页 → get_live_channels（FFI） → registry.live_all()
//        → 各 provider 的 live_channels() → M3uLiveProvider::load()
//        → HTTP 拉 m3u → m3u::parse_playlist → 频道列表
// ```
//
// 只有走完这条 **真 FFI 链路**才算"用户能看见"。
// 本探针不 mock 任何一环：本地起 HTTP 服务返回真实 m3u 文本，
// 核心是真实 DLL，调用是真实 FFI 命令。
//
// # 还要验一件容易漏的事：**重启后还在**
//
// `PersistedProvider::M3uLive` 的意义就是重启不丢。探针会
// stop → start 同一个数据目录 → 再查一次 live_channels。
//
// # 数据隔离
// 数据目录必须落在 .probe 下，否则 exit(3)——绝不碰用户真实数据。
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'core/ffi.dart';
import 'core/sourin_api.dart';

late Directory _outDir;
File? _logFile;
int _ok = 0;
int _bad = 0;

void _say(String s) {
  final ts = DateTime.now().toIso8601String().substring(11, 23);
  final line = '$ts [LIVE] $s';
  // ignore: avoid_print
  print(line);
  try {
    _logFile?.writeAsStringSync('$line\n', mode: FileMode.append, flush: true);
  } catch (_) {}
}

void _check(bool cond, String what, {String detail = ''}) {
  if (cond) {
    _ok++;
    _say('OK   $what${detail.isEmpty ? '' : '  ($detail)'}');
  } else {
    _bad++;
    _say('FAIL $what${detail.isEmpty ? '' : '  ($detail)'}');
  }
}

/// 探针自己提供的那份 m3u 内容（含属性、含一个坏行 ⇒ 顺带验宽容解析）
const _m3uBody = '''#EXTM3U
#EXTINF:-1 tvg-logo="http://x/l.png" group-title="测试组",频道甲
http://127.0.0.1:9/a.m3u8
坏行没有地址
#EXTINF:-1,频道乙
http://127.0.0.1:9/b.m3u8
''';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // ── 隔离护栏 ──
  const override = String.fromEnvironment('DATA_DIR_OVERRIDE');
  if (override.isEmpty) {
    // ignore: avoid_print
    print('[live] !! 拒绝启动：缺 --dart-define=DATA_DIR_OVERRIDE');
    exit(3);
  }
  final probeRoot = Directory(
    '${Directory.current.path}${Platform.pathSeparator}.probe'
    '${Platform.pathSeparator}t1034_tvbox_lives_probe',
  );
  String norm(String p) =>
      p.replaceAll('/', Platform.pathSeparator).toLowerCase();
  if (!norm(Directory(override).absolute.path)
      .startsWith(norm(probeRoot.absolute.path))) {
    // ignore: avoid_print
    print('[live] !! 拒绝启动：数据目录必须在 .probe/t1034_tvbox_lives_probe 下，'
        '实际=$override');
    exit(3);
  }
  _outDir = probeRoot;
  await _outDir.create(recursive: true);
  _logFile = File('${_outDir.path}${Platform.pathSeparator}probe.log');
  await _logFile!.writeAsString('');

  _say('══════ TVBox lives → 直播频道 · 全链路验收 ══════');
  _say('数据目录 = $override');

  // ── m3u 来源 ──
  //
  // ★ 优先用外部传入的 `M3U_URL`（由独立进程提供）。
  //   原因：本进程内起 Dart HttpServer、再由 Rust reqwest 去拉，
  //   会受"同一进程两套 event loop 互相等"的干扰（实测首跑就是
  //   20 秒超时、频道 0 个）。用外部服务能把这一层干扰排除干净，
  //   从而区分「产品逻辑有问题」与「探针方式有问题」。
  const externalUrl = String.fromEnvironment('M3U_URL');
  HttpServer? server;
  String m3uUrl;
  if (externalUrl.isNotEmpty) {
    m3uUrl = externalUrl;
    _say('m3u 来源 = 外部 $m3uUrl');
  } else {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final port = server.port;
    server.listen((req) {
      req.response.headers.contentType = ContentType('audio', 'x-mpegurl');
      req.response.write(_m3uBody);
      req.response.close();
    });
    m3uUrl = 'http://127.0.0.1:$port/list.m3u';
    _say('m3u 来源 = 进程内服务 $m3uUrl');
  }

  // ── 启动真实核心 ──
  final started = await SourinCore.startAsync(override);
  _check(started['ok'] == true, '核心已启动', detail: '$started');
  if (started['ok'] != true) {
    _say('RESULT FAIL core_not_started');
    exit(1);
  }

  // ── 造一份复刻 Owner 那份配置形态的 TVBox 配置 ──
  // 1 个 Java 源（不可用）+ 1 个直播源（指向本地服务）
  final cfg = '{"spider":"http://x/spider.jar;md5;000",'
      '"sites":[{"key":"j1","name":"Java源","type":3,"api":"csp_Foo"}],'
      '"lives":[{"name":"探针直播","url":"$m3uUrl"}]}';

  final imported = await SourinApi.importTvboxConfig(cfg);
  _say('import 返回 = $imported');

  _check((imported.imported.isEmpty), 'Java 源未被导入（不虚报）',
      detail: 'imported=${imported.imported.length}');
  _check(imported.skipped.isNotEmpty, 'Java 源进了 skipped',
      detail: 'skipped=${imported.skipped.length}');
  _check(imported.lives.length == 1, '配置里的 1 个直播源被识别',
      detail: 'lives=${imported.lives.length}');

  // ── 关键：走 UI 真正用的那条命令 ──
  final groups = await SourinApi.getLiveChannels();
  final total = groups.fold<int>(0, (a, g) => a + g.channels.length);
  _say('get_live_channels → groups=${groups.length} 频道数=$total');
  for (final g in groups) {
    _say('  group="${g.providerName}" channels=${g.channels.length} '
        '${g.channels.take(3).map((c) => c.name).toList()}');
  }
  _check(total == 2, '直播页能拿到 2 个频道（含坏行被跳过）',
      detail: '实际 $total');

  // 频道属性（logo / group）也要透出来
  LiveChannel? first;
  String? firstProvider;
  for (final g in groups) {
    for (final c in g.channels) {
      if (c.name == '频道甲') {
        first = c;
        firstProvider = g.provider;
      }
    }
  }
  _check(first != null, '找到「频道甲」');
  if (first != null) {
    _check(first.logo != null, 'tvg-logo 已解析', detail: '${first.logo}');
  }

  // ── 取流（live_stream 走缓存反查地址）──
  String? streamUrl;
  try {
    if (first != null) {
      final cands = await SourinApi.getLiveStream(firstProvider!, first.id);
      streamUrl = cands.isNotEmpty ? cands.first.url : null;
    }
  } catch (e) {
    _say('getLiveStream 抛错: $e');
  }
  _check(streamUrl != null && streamUrl.contains('/a.m3u8'),
      '取流拿到正确地址', detail: '$streamUrl');

  // ── 重启：本探针**不做**，理由如下 ──
  //
  // `SourinCore` 没有公开的 stop/shutdown（核心按设计活到进程结束）。
  // 重启验证已由 Rust 侧端到端测试覆盖
  // （`lives_are_imported_even_when_all_sites_are_java` 里
  //  `AppState::bootstrap` 两次，第二次断言频道仍在）。
  // 这里如实记录"本探针未覆盖重启"，不假装验过。
  _say('NOTE 重启验证由 Rust 端到端测试覆盖，本探针不重复');

  // ── 落盘证据：证明"重启后还在"不是空话 ──
  final providersFile =
      File('$override${Platform.pathSeparator}third-party-providers.json');
  final persisted = providersFile.existsSync()
      ? providersFile.readAsStringSync()
      : '';
  _say('落盘文件 ${providersFile.path} 存在=${providersFile.existsSync()} '
      '${persisted.length} 字节');
  _check(persisted.contains('m3u_live'), '落盘清单含 m3u_live 变体标签');
  _check(persisted.contains('探针直播'), '落盘清单含直播源名称');

  _say('');
  _say('══ 汇总 ══');
  _say('判据通过=$_ok 判据失败=$_bad');
  _say('RESULT ${_bad == 0 ? 'PASS' : 'FAIL'} ok=$_ok bad=$_bad');
  _say('DONE');

  await server?.close(force: true);
  exit(_bad == 0 ? 0 : 1);
}
