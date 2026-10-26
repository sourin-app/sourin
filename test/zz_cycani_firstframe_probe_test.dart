// ══════════════════════════════════════════════════════════════════════
//  能播吗？—— 真文件 + 真 mpv 的取证（含**环境能力边界**的如实记录）
// ══════════════════════════════════════════════════════════════════════
//
// # 它回答什么
// ```text
// 「MP4 被伪装成 .mp3」⇒ mpv 按后缀选 demuxer ⇒ 只有音轨、无首帧。
// 起播前下发 `demuxer-lavf-format=mov` 是否**真的**生效？
// ```
//
// # 关于真实 URL（如实记录，不伪造）
// ```text
// · `.probe/cycani-play-3862.json` 里那条真签名地址（2026-10-27 生成）此刻 **410 Gone**
//   （curl 实测 code=410 / 7.3s）；
// · Owner 复现现场那条 `…5bC85Y+k5Za15Za1MDF6bS5tcDQ=.mp3` 只在他的日志里。
// ⇒ **未取到可重复的真实签名 URL**。本用例只用夹具：
//   ffmpeg 现造 2 秒 h264+静音 AAC 的 MP4，由本进程 HTTP server 以 `/v/fake.mp3` 提供
//   （后缀伪装成 mp3）。字节/解码器/mpv 都是真的，**只有 URL 是本地合成的**。
// ```
//
// # ★ 环境能力边界（本轮最重要的实测结论）
// ```text
// 这套 headless 测试进程里 **没有视频输出** ⇒ `state.width` / `videoParams` **恒为 null**，
// 连「真 `.mp4` 后缀 + file://」也一样（见 ③ 的对照，故意断言 0）。
// ⇒ **"首帧"在本夹具里不可观测**；能观测的是：
//     ① 属性是否真的进到 mpv（`setProperty` + **回读**）
//     ② 媒体是否真的被解析（`duration` = 样本真实时长 2.02s）
//     ③ `position` 是否前进（排除"卡在 0 的假播放"）
//   「首帧」的硬证据只能在**有窗口的运行时**（产品 exe）里取。
// ```
//
// 跑法：
// ```powershell
// flutter test test/zz_cycani_firstframe_probe_test.dart \
//   --run-skipped --tags native-media --concurrency=1
// ```
@Tags(['native-media'])
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/ui/player_page.dart';

Future<String> _makeSample() async {
  final dir = Directory('.probe/firstframe')..createSync(recursive: true);
  final out = File('${dir.path}/sample.mp4');
  if (out.existsSync() && out.lengthSync() > 2000) {
    // 旧样本可能只有 2 秒（position 一开就到底）⇒ 文件太小就重造
    if (out.lengthSync() > 8000) return out.path;
    out.deleteSync();
  }
  final r = await Process.run('ffmpeg', [
    '-y',
    '-f', 'lavfi', '-i', 'color=c=teal:s=320x240:d=8:r=25',
    '-f', 'lavfi', '-i', 'anullsrc=channel_layout=stereo:sample_rate=44100',
    '-shortest',
    '-c:v', 'libx264', '-pix_fmt', 'yuv420p', '-preset', 'ultrafast',
    '-c:a', 'aac', '-b:a', '32k',
    out.path,
  ]);
  if (r.exitCode != 0 || !out.existsSync() || out.lengthSync() < 2000) {
    throw StateError('ffmpeg 造样本失败：${r.exitCode}');
  }
  return out.path;
}

/// 只服务一个文件的 HTTP server；**路径后缀故意写成 `.mp3`**
Future<(HttpServer, String)> _serveDisguised(String filePath) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  unawaited(() async {
    await for (final req in server) {
      final f = File(filePath);
      final len = f.lengthSync();
      req.response.headers.set('content-type', 'application/octet-stream');
      req.response.headers.set('accept-ranges', 'bytes');
      final range = req.headers.value('range');
      if (range != null) {
        final m = RegExp(r'bytes=(\d+)-(\d*)').firstMatch(range);
        final start = int.tryParse(m?.group(1) ?? '') ?? 0;
        final endRaw = m?.group(2) ?? '';
        final end = endRaw.isEmpty ? len - 1 : int.parse(endRaw);
        final raf = f.openSync()..setPositionSync(start);
        final chunk = raf.readSync(end - start + 1);
        raf.closeSync();
        req.response.statusCode = 206;
        req.response.headers.set('content-range', 'bytes $start-$end/$len');
        req.response.add(chunk);
      } else {
        req.response.add(f.readAsBytesSync());
      }
      await req.response.close();
    }
  }());
  return (server, 'http://127.0.0.1:${server.port}/v/fake.mp3');
}

/// 等视频尺寸 > 0；超时返回 0。**本 headless 环境恒返回 0**（见文件头的能力边界）
Future<int> _videoWidthWithin(Player p, Duration budget) async {
  final deadline = DateTime.now().add(budget);
  while (DateTime.now().isBefore(deadline)) {
    final w = p.state.width ?? p.state.videoParams.w;
    if ((w ?? 0) > 0) return w!;
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return 0;
}

void main() {
  late String file;
  late HttpServer server;
  late String url;

  setUpAll(() async {
    MediaKit.ensureInitialized();
    file = await _makeSample();
  });

  setUp(() async {
    final (s, u) = await _serveDisguised(file);
    server = s;
    url = u;
  });

  tearDown(() async {
    await server.close(force: true);
  });

  test('① 生产判据：伪装 .mp3 + kind=mp4 ⇒ 需要覆盖（kind=mp3 ⇒ 不需要）', () {
    expect(debugPlayerNeedsDemuxerOverrideForProbe(url, 'mp4'), isTrue,
        reason: '★★ 判据必须同意"这条要覆盖"（url=$url）');
    expect(debugPlayerNeedsDemuxerOverrideForProbe(url, 'mp3'), isFalse,
        reason: '★ 反向：kind 说 mp3 就不该覆盖');
  });

  test('② 真 mpv：属性回读为 mov + 媒体真被解析 + position 前进', () async {
    final p = Player();
    addTearDown(p.dispose);

    final need = debugPlayerNeedsDemuxerOverrideForProbe(url, 'mp4');
    expect(need, isTrue, reason: '前置：这条夹具就是"伪装"形态');
    final native = p.platform;
    expect(native, isA<NativePlayer>(),
        reason: '前置：桌面端 platform 必须是 NativePlayer（否则属性下发不生效）');

    // ★ 与生产 `_applyDemuxerOverride()` 同一条属性
    await (native as NativePlayer).setProperty('demuxer-lavf-format', 'mov');
    await native.setProperty('demuxer', 'lavf');
    // 回读证明"真的设进去了"（比"只调用了 API"更强）
    final readBack = await native.getProperty('demuxer-lavf-format');
    // ignore: avoid_print
    print('[PROBE] readBack demuxer-lavf-format=$readBack');
    expect(readBack.toString().contains('mov'), isTrue,
        reason: '★★ 属性必须真的进到 mpv（回读=$readBack）');

    p.open(Media(url)); // ★ 本仓封装的 open 返回 void，不能 await

    /*
     * ⚠️ 不能"先等 20s 再比 position" —— 8 秒的样本会**播到底**（实测 position 停在 7.98s），
     *    于是"前进"判据假红。正确做法：起来后**立刻**取两次采样比。
     * 同时：headless 无视频输出 ⇒ `width` 恒 0（见 ③ 的 .mp4 对照），不只等它。
     */
    await Future<void>.delayed(const Duration(milliseconds: 1500));
    expect(p.state.duration.inMilliseconds, greaterThan(7000),
        reason: '★★ mpv 必须真的解析出这条媒体（样本 8s，实际 ${p.state.duration}）'
            '—— 证明 URL / Range / 容器都通');
    final before = p.state.position;
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    final after = p.state.position;
    // ignore: avoid_print
    print('[PROBE] width=${p.state.width} duration=${p.state.duration} '
        'position=$before→$after');
    // ignore: avoid_print
    print('[PROBE] position $before → $after');
    expect(after, greaterThan(before),
        reason: '★★ position 必须前进（排除"卡在 0 的假播放"）：$before → $after');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('③ 环境限制对照：真 `.mp4` 后缀 + file:// 也拿不到 videoParams', () async {
    final p = Player();
    addTearDown(p.dispose);
    final path = File(file).absolute.path.replaceAll(RegExp(r'[\\/]'), '/');
    p.open(Media('file:///$path')); // ★ open 返回 void
    final w = await _videoWidthWithin(p, const Duration(seconds: 20));
    // ignore: avoid_print
    print('[PROBE-file] width=$w duration=${p.state.duration}');
    /*
     * ★ 故意断言 0：这是"**环境限制**"的硬证据 ——
     *   真 `.mp4` + 本地文件同样没有 `videoParams`
     *   ⇒ 本 headless 进程没有视频输出，`state.width` 不能当"首帧"判据。
     *   若哪天这里有值，说明环境变了 ⇒ 应把 ② 升回 "width>0" 的硬判据。
     */
    expect(w, 0,
        reason: '★ 环境限制：headless 无视频输出 ⇒ 真 .mp4 也拿不到 videoParams'
            '（"首帧"只能留给有窗口的运行时）');
    expect(p.state.duration.inMilliseconds, greaterThan(7000),
        reason: '★ 但解析是好的（duration≈8s）');
  }, timeout: const Timeout(Duration(seconds: 90)));

  test('④ 对照：不下发覆盖时媒体仍被解析（本环境无法区分音/视频）', () async {
    final p = Player();
    addTearDown(p.dispose);
    p.open(Media(url)); // ★ 不下发任何 demuxer 覆盖
    final w = await _videoWidthWithin(p, const Duration(seconds: 6));
    // ignore: avoid_print
    print('[PROBE-no-override] width=$w position=${p.state.position} '
        'duration=${p.state.duration}');
    /*
     * ⚠️ 如实标注（不假装有牙）：
     *   本环境"有覆盖"与"没覆盖"**都是 width=0**（见 ③）⇒
     *   这条对照**不能**证明覆盖有效或无效；它能证明"不覆盖也不会崩、媒体照样解析"。
     *   "覆盖真的生效"的证据在 `zz_demuxer_override_test`
     *   （属性被设/被清 + 注入清空缺失 ⇒ 红），以及**有窗口运行时**的实机首帧。
     */
    expect(w, 0, reason: '★ 环境限制：headless 无视频输出 ⇒ width 恒 0（不是判据）');
    expect(p.state.duration.inMilliseconds, greaterThan(7000),
        reason: '★ 不覆盖时媒体仍应被解析（duration≈8s）——'
            '若这条失败，说明连**解析**都坏了（那才是真回归）');
  }, timeout: const Timeout(Duration(seconds: 60)));
}
