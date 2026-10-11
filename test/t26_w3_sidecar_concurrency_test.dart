// ZZ-CR-DL · CR-06 · 并发收尾时固定临时文件名撞车回归测试
//
// 缺陷（lib/core/download_queue.dart）：同一个作品目录里的临时文件名是**固定**的
//   final tmp = File('${f.path}.tmp');   // _sourin-cache.json.tmp
//   final tmp = File('${f.path}.tmp');   // _sourin-cover.jpg.tmp
// ⇒ 同一部剧的两集在同一个目录里**同时收尾**时：
//     A: 写 _sourin-cover.jpg.tmp → rename 到 _sourin-cover.jpg（tmp 被搬走了）
//     B: 写 _sourin-cover.jpg.tmp → rename ⇒ ENOENT（tmp 已经不在）
//        ⇒ 重试 5 次（≈440ms）全失败 ⇒ 兜底 readAsBytes 也 ENOENT
//        ⇒ 记「★ 封面原子替换彻底失败」⇒ cacheCoverImage 返回 null
//        ⇒ 旁文件里 coverFile = null ⇒ 已缓存页丢本地封面
//
// ★ 机制订正（比任务书更准，报告里如实写了）：一个任务**内部**封面与旁文件是
//   串行的（先 await cacheCoverImage，再写旁文件），两个 tmp 不可能同时在飞；
//   真正的撞名发生在**跨并发任务**（A、B 同 work 同时收尾）。
//
// ★ 怎么让撞名**必然发生**（否则阳性对照会变成一条假绿的门禁）：
//   ① 三集速度**一样**（不是 c14 那种「快档/慢档」场景）—— 本用例要的正是
//      「三集几乎同时收尾」，速度错开反而撞不上；
//   ② 封面取**7 MiB**（kCoverBytes）：tmp.writeAsBytes(flush: true) 因此要花
//      十几~几十毫秒 ⇒ 「写 tmp → rename」这个窗口被拉宽到肉眼级，三集的窗口
//      必然互相重叠 ⇒ 第一个 rename 把 tmp 搬走，其余两个 rename 全 ENOENT。
//      7 MiB 是有意的上限（cacheCoverImage 里 > 8 MiB 直接放弃）。
//
// 判据：setConcurrency(3) + 同一部剧三集同时收尾，跑 ROUNDS 轮 ——
//   主用例：每轮三集都 done、没有「原子替换彻底失败」、旁文件 coverFile 非 null
//           且那张图真在盘上（字节数对得上）、目录里没有 .tmp 残留；
//   阳性对照：debugDisableFinishSerialization = true ⇒ 至少一轮必须**真撞上**。
//
// 跑法：flutter test test/t26_w3_sidecar_concurrency_test.dart --concurrency=1

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/core/app_log.dart';
import 'package:sourin_spike/core/download_dir.dart';
import 'package:sourin_spike/core/download_queue.dart';
import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/core/ui_prefs.dart';

/// 每片字节数（很小 —— 本用例只关心收尾，不关心吞吐）
const int kSegBytes = 2048;

/// 清单里的分片数
const int kSegCount = 6;

/// ★ 封面 7 MiB：把「写 tmp → rename」的窗口拉到十几~几十毫秒，
///   让并发撞名**必然**发生（> 8 MiB 会被 cacheCoverImage 直接放弃）。
const int kCoverBytes = 7 * 1024 * 1024;
const int kCoverByte = 0x5A;

/// 同一部剧的任务数（= 并发上限 3 ⇒ 三集同时收尾）
const int kEps = 3;

/// 每种形态跑几轮（撞名是概率事件 ⇒ 单轮说明不了问题）
const int kRounds = 3;

/// 拼 m3u8 用的换行
String kNl() => String.fromCharCode(10);

/// 上游：真 HttpServer + 真 m3u8 + 真分片字节 + 真封面图
class Upstream {
  late HttpServer _srv;
  int get port => _srv.port;

  Future<void> start() async {
    _srv = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _srv.listen((req) async {
      final path = req.uri.path;
      if (path == '/master.m3u8') {
        req.response.headers.contentType =
            ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(<String>[
          '#EXTM3U',
          '#EXT-X-STREAM-INF:BANDWIDTH=2000000',
          'media.m3u8',
          '',
        ].join(kNl()));
        await req.response.close();
        return;
      }
      if (path == '/media.m3u8') {
        final b = StringBuffer(<String>[
          '#EXTM3U',
          '#EXT-X-VERSION:3',
          '#EXT-X-TARGETDURATION:4',
          '',
        ].join(kNl()));
        for (var i = 0; i < kSegCount; i++) {
          b.write('#EXTINF:4.0,' + kNl() + 'seg' + i.toString() + '.ts' + kNl());
        }
        b.write('#EXT-X-ENDLIST' + kNl());
        req.response.headers.contentType =
            ContentType.parse('application/vnd.apple.mpegurl');
        req.response.write(b.toString());
        await req.response.close();
        return;
      }
      if (path.startsWith('/seg')) {
        final body = List<int>.filled(kSegBytes, 0x11);
        req.response.headers.contentType = ContentType.binary;
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
        return;
      }
      if (path == '/cover.jpg') {
        final body = List<int>.filled(kCoverBytes, kCoverByte);
        req.response.headers.contentType = ContentType.parse('image/jpeg');
        req.response.headers.contentLength = body.length;
        req.response.add(body);
        await req.response.close();
        return;
      }
      req.response.statusCode = 404;
      await req.response.close();
    }, onError: (Object _) {});
  }

  Future<void> close() => _srv.close(force: true);
}

/// 第 k 集的任务（同一部剧 'OPS16 剧' ⇒ 同一个作品目录）
DownloadTask _task(int k, {String cover = ''}) => DownloadTask(
      id: 'cctv:ops16:ep' + k.toString(),
      title: 'OPS16 剧',
      episodeTitle: '第' + (k + 1).toString() + '集',
      provider: 'cctv',
      mediaId: 'ops16',
      episodeId: 'ep' + k.toString(),
      sourceCode: 'src',
      fileName: '第' + (k + 1).toString().padLeft(2, '0') + '集 OPS16',
      cover: cover,
      description: 'OPS-16 简介',
      year: '2026',
      area: '大陆',
      kind: '剧',
      badges: const <String>['悬疑'],
    );

/// 目录里所有以 .tmp 结尾的残留（**任何**临时名都算 —— 见文件头说明）
List<String> _tmpResidue(String dir) {
  final d = Directory(dir);
  if (!d.existsSync()) return <String>[];
  return d
      .listSync()
      .whereType<File>()
      .map((f) => f.path)
      .where((p) => p.endsWith('.tmp'))
      .toList();
}

/// 一轮的读数
class RoundResult {
  final String dir;
  final bool quiet;
  final int maxRun;
  final List<String> states;
  final int collision;
  final bool sidecarExists;
  final bool coverNull;
  final int coverLen;
  final List<String> residue;
  final List<String> tail;
  RoundResult({
    required this.dir,
    required this.quiet,
    required this.maxRun,
    required this.states,
    required this.collision,
    required this.sidecarExists,
    required this.coverNull,
    required this.coverLen,
    required this.residue,
    required this.tail,
  });

  bool get collided => collision > 0 || coverNull;
}

void main() {
  late Upstream ups;

  setUp(() async {
    DownloadQueue.debugReset();
    DownloadQueue.debugForceRenameFailures = 0;
    DownloadQueue.debugDisableFinishSerialization = false;
    DownloadDir.debugReset();
    UiPrefs.remove(DownloadQueue.kConcurrencyKey);
    AppLog.debugClear();
    ups = Upstream();
    await ups.start();
    DownloadQueue.debugSetResolver((t) async => StreamCandidate(
        url: 'http://127.0.0.1:' + ups.port.toString() + '/master.m3u8'));
  });

  tearDown(() async {
    await ups.close();
    DownloadQueue.debugReset();
    DownloadQueue.debugSetResolver(null);
    DownloadQueue.debugDisableFinishSerialization = false;
    DownloadQueue.debugForceRenameFailures = 0;
    DownloadDir.debugReset();
    UiPrefs.debugResetForTest();
    AppLog.debugClear();
  });

  /// 等队列里再没有 queued/running 的任务（或超时）
  Future<bool> _waitQuiet({int timeoutMs = 90000}) async {
    final dl = DateTime.now().add(Duration(milliseconds: timeoutMs));
    while (DateTime.now().isBefore(dl)) {
      final busy = DownloadQueue.tasks.value.any((t) =>
          t.state == DownloadState.queued || t.state == DownloadState.running);
      if (!busy) return true;
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    return false;
  }

  /// 跑一轮：全新作品目录 + 三集同时入队 + 等收尾干净 + 采读数
  Future<RoundResult> _round(int n) async {
    final sep = Platform.pathSeparator;
    final d = Directory(Directory.systemTemp.absolute.path +
        sep +
        'cr_dl_c06_' +
        DateTime.now().microsecondsSinceEpoch.toString() +
        '_' +
        n.toString())
      ..createSync(recursive: true);
    // ★ 不用 DownloadDir.setConfiguredDir：它内部调 AppLog.write，
    //   而 AppLog.logDir() 会走 ClipDownloader.dataDir() → path_provider
    //   ⇒ 在 flutter_test 里是 MissingPluginException（插件没注册）。
    //   这里直接灌 UiPrefs 的内存数据，效果等价且不碰插件。
    UiPrefs.debugResetForTest(<String, String>{DownloadDir.kDirKey: d.path});
    DownloadDir.debugReset();
    DownloadQueue.debugReset();
    AppLog.debugClear();
    DownloadQueue.setConcurrency(kEps);

    final cover = 'http://127.0.0.1:' + ups.port.toString() + '/cover.jpg';
    for (var k = 0; k < kEps; k++) {
      final ok = DownloadQueue.enqueue(_task(k, cover: cover));
      if (!ok) {
        throw StateError('前置失败：第$k集入队被拒（同 id 且 queued/running）');
      }
    }

    final quiet = await _waitQuiet();
    // 让收尾后的日志/文件状态彻底安定
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final texts = AppLog.lines.map((l) => l.text).toList();
    final collision = texts.where((s) => s.contains('原子替换彻底失败')).length;
    // ★★ 旁文件落在**作品子目录**里，不是下载根：
    //   DownloadDir.forWork('OPS16 剧') ⇒ <root>\OPS16 剧\_sourin-cache.json
    final workDir = d.path + sep + 'OPS16 剧';
    final sidecar = File(workDir + sep + DownloadQueue.kSidecarName);
    var sidecarExists = sidecar.existsSync();
    var coverNull = true;
    var coverLen = -1;
    if (sidecarExists) {
      try {
        final js =
            jsonDecode(sidecar.readAsStringSync()) as Map<String, Object?>;
        final cf = js[DownloadQueue.kSidecarCoverFileKey];
        if (cf is String && cf.trim().isNotEmpty) {
          coverNull = false;
          final cf0 = File(workDir + sep + cf);
          coverLen = cf0.existsSync() ? cf0.lengthSync() : -1;
        }
      } catch (_) {
        // 解析不了 ⇒ 当成「旁文件坏了」，后面按 coverNull 记
      }
    }
    final states = <String>[];
    for (var k = 0; k < kEps; k++) {
      final id = 'cctv:ops16:ep' + k.toString();
      final hit = DownloadQueue.tasks.value.where((x) => x.id == id).toList();
      states.add(hit.isEmpty ? 'missing' : hit.first.state.toString());
    }
    final tail = texts.length > 14
        ? texts.sublist(texts.length - 14)
        : List<String>.from(texts);
    return RoundResult(
      dir: d.path,
      quiet: quiet,
      maxRun: DownloadQueue.debugMaxObservedRunning(),
      states: states,
      collision: collision,
      sidecarExists: sidecarExists,
      coverNull: coverNull,
      coverLen: coverLen,
      residue: _tmpResidue(workDir),
      tail: tail,
    );
  }

  test('★★ CR-06：并发 3 集同时收尾时，封面原子替换不得撞名（旁文件 coverFile 必须非 null）',
      () async {
    final bad = <String>[];
    var maxRunSeen = 0;
    for (var n = 1; n <= kRounds; n++) {
      final r = await _round(n);
      if (r.maxRun > maxRunSeen) maxRunSeen = r.maxRun;
      final where = '第$n轮(dir=${r.dir})';
      if (!r.quiet) {
        bad.add('$where ★ 队列没跑完（仍卡在 queued/running）—— 用例失去意义，不是通过');
      }
      for (var k = 0; k < kEps; k++) {
        if (r.states[k] != 'DownloadState.done') {
          bad.add('$where ★ 第$k集没到 done：${r.states[k]}');
        }
      }
      if (r.collision > 0) {
        bad.add('$where ★★ 出现了「原子替换彻底失败」×${r.collision} ⇒ 固定 tmp 名撞车');
      }
      if (!r.sidecarExists) {
        bad.add('$where ★★ 旁文件压根没写出来');
      } else if (r.coverNull) {
        bad.add('$where ★★ 旁文件 coverFile 为空 ⇒ 已缓存页会丢本地封面（CR-06 的后果）');
      } else if (r.coverLen != kCoverBytes) {
        bad.add('$where ★ 封面字节数 = ${r.coverLen} ≠ $kCoverBytes（可能被另一集踩坏了）');
      }
      if (r.residue.isNotEmpty) {
        bad.add('$where ★ .tmp 残留没清掉：' + r.residue.join(' , '));
      }
      if (bad.isNotEmpty) {
        bad.add('该轮日志尾部：\n' + r.tail.join('\n'));
      }
    }
    // ★ 前提：三集必须**真的**同时在跑，否则「并发收尾」根本凑不出来
    if (maxRunSeen < kEps) {
      bad.add('★ 前置失效：历史最大同时运行数 = $maxRunSeen < $kEps ⇒ 本用例没测到并发');
    }
    expect(bad, isEmpty, reason: bad.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 6)));

  test('★★ 阳性对照：关掉收尾串行化以后，同样的并发必须**真的**撞名（证明上一条不是假绿）',
      () async {
    /*
     * ★★ 这条用例证明的是「上一条有牙齿」：
     *   debugDisableFinishSerialization = true ⇒ _serializeFinish 直接跑 body，
     *   于是固定名 _sourin-cover.jpg.tmp 又会被三集同时用。
     *   7 MiB 的封面把「写 tmp → rename」的窗口拉到十几~几十毫秒 ⇒ 必然重叠。
     *   如果这里**撞不出来**，那上一条的绿说明不了任何事（门禁是假的）。
     */
    DownloadQueue.debugDisableFinishSerialization = true;
    final rounds = <RoundResult>[];
    for (var n = 1; n <= kRounds; n++) {
      rounds.add(await _round(n));
    }
    final collided = rounds.where((r) => r.collided).length;
    final detail = <String>[];
    for (var i = 0; i < rounds.length; i++) {
      final r = rounds[i];
      detail.add('第${i + 1}轮：撞名=${r.collision} coverFile为空=${r.coverNull} '
          '三集状态=${r.states.join('/')} 同时在跑=${r.maxRun} 残留=${r.residue.length}');
    }
    expect(rounds.every((r) => r.quiet), isTrue, reason: '前置：每轮队列都要跑完');
    expect(rounds.every((r) => r.maxRun >= kEps), isTrue,
        reason: '前置：三集必须真的同时在跑，否则撞不出来\n' + detail.join('\n'));
    expect(collided, greaterThan(0),
        reason: '★★ 阳性对照失效：关掉串行化以后 $kRounds 轮竟然一次都没撞上 ⇒ '
            '这条探针根本撞不出 CR-06，上一条的绿是假的。\n' +
            detail.join('\n') +
            '\n最后一轮日志尾部：\n' + rounds.last.tail.join('\n'));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
