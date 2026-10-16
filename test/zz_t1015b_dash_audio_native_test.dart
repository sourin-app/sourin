// ═══════════════════════════════════════════════════════════════════════
//  ★ 本文件被标记为 `native-media`（默认不跑）—— 它加载 libmpv-2.dll
//  原因与手动跑法见 `dart_test.yaml` 顶部；证据链见 `.probe/native-media-tests.md`
// ═══════════════════════════════════════════════════════════════════════
//
// ═══════════════════════════════════════════════════════════════════════
//  Owner 2026-10-15：「bibili源没有声音,你看看应该是插件的问题」
// ═══════════════════════════════════════════════════════════════════════
//
// # 实测结论：插件没问题，是**播放页挂音轨那一句**挂了空档
//
// 插件侧实测（拿 Owner 机器上那份 bilibili.js 的原样参数打真接口）：
// ```text
//   playurl code=0、dash.audio 3 条全是正常 AAC（mp4a.40.2/.5）
//   音频地址带 Referer 拉回来 = HTTP 206 + 合法 ftyp 头
// ⇒ 取流、防盗链、audioUrl 声明**全都正常**
// ```
//
// # 真根因：`audio-file` **不是**运行期属性，设了等于没设
// ```text
// mpv 手册 DOCS/man/options.rst：
//   --audio-file=<file>  CLI/config file only alias for --audio-files-append
// 即：加载期命令行选项，**没有**对应的运行期属性。
//
// 实测（FFI 打本仓自带的 libmpv-2.dll，见下方 native 用例）：
//   mpv_set_property_string(ctx, "audio-file", url)   → -8 property not found
//   mpv_command(ctx, ["audio-add", url, "select", …]) → 0 success
// ```
// 而 media_kit 的 `setProperty` **丢掉返回码**
//   （media_kit-1.2.6/…/native/player/real.dart:1239 不检查返回值）
// ⇒ 失败**完全静默**：日志照打「已挂载外挂音轨」、画面正常、就是没声音。
//
// # 本文件怎么防它回来
// ```text
// ① 源码契约：播放页必须走 setAudioTrack(AudioTrack.uri(...))，
//    且**不得**再出现 setProperty('audio-file' / 'audio-files-append')。
// ② 真实 DLL：直接打 libmpv，证明旧写法确实 rc<0、新写法确实把音轨挂上。
// ```
// ①②互相独立：①不加载 DLL（默认就跑），②是 `native-media` 标签。
// ═══════════════════════════════════════════════════════════════════════

@Tags(['native-media'])
library;

import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('② 真实 libmpv：证明旧写法无声、新写法有声', () {
    /*
     * 这一组直接打仓库自带的 libmpv-2.dll，不经过 Flutter、不经过 media_kit。
     * ao=null ⇒ 全程**不碰声卡**；vo=null ⇒ 不出现任何窗口。
     */
    String? mpvDir;
    late Directory tmp;

    setUpAll(() {
      for (final c in <String>[
        r'build\windows\x64\runner\Release',
        r'build\windows\x64\runner\Debug',
        r'build\windows\x64\runner\Profile',
      ]) {
        final d = Directory(c);
        if (!d.existsSync()) continue;
        for (final f in d.listSync()) {
          if (f is File && f.path.toLowerCase().endsWith('libmpv-2.dll')) {
            mpvDir = d.absolute.path;
          }
        }
      }
    });

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('sourin_audio_');
    });

    tearDown(() {
      try {
        tmp.deleteSync(recursive: true);
      } catch (_) {}
    });

    test('★★ 旧写法 rc<0，新写法把 external 音轨挂上', () {
      if (mpvDir == null) {
        markTestSkipped('未找到 libmpv-2.dll —— 需要先构建 Windows 产物');
        return;
      }
      // 真实 AAC 音频流：用 ffmpeg 生成，避免依赖外网
      final audio = File(tmp.path + Platform.pathSeparator + 'a.m4a');
      final ff = Process.runSync('ffmpeg', <String>[
        '-y', '-f', 'lavfi', '-i', 'sine=frequency=440:duration=3',
        '-c:a', 'aac', audio.path,
      ]);
      if (ff.exitCode != 0 || !audio.existsSync()) {
        markTestSkipped('缺少 ffmpeg，无法生成本地音频夹具');
        return;
      }
      /*
       * ⚠️ 还必须有一条**视频**：mpv 在 idle（没载入任何文件）时，
       *    audio-add 会返回 -4 invalid parameter。
       *    真实播放场景里视频早就 loadfile 了，所以这里要还原那个前提。
       *    只出 1 帧、vo=null ⇒ 不占资源、不出现窗口。
       */
      final video = File(tmp.path + Platform.pathSeparator + 'v.mp4');
      final fv = Process.runSync('ffmpeg', <String>[
        '-y', '-f', 'lavfi', '-i', 'color=c=black:s=64x64:d=3',
        '-c:v', 'libx264', '-preset', 'ultrafast', '-pix_fmt', 'yuv420p',
        video.path,
      ]);
      if (fv.exitCode != 0 || !video.existsSync()) {
        markTestSkipped('缺少 ffmpeg/libx264，无法生成本地视频夹具');
        return;
      }

      final lib = DynamicLibrary.open(
        mpvDir! + Platform.pathSeparator + 'libmpv-2.dll',
      );
      final ctx = lib
          .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
              'mpv_create')();
      expect(ctx, isNot(nullptr), reason: 'mpv_create 失败');

      int setOpt(String n, String v) => lib.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
              int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)>(
          'mpv_set_option_string')(ctx, n.toNativeUtf8(), v.toNativeUtf8());
      int setProp(String n, String v) => lib.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>),
              int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>)>(
          'mpv_set_property_string')(ctx, n.toNativeUtf8(), v.toNativeUtf8());
      int cmd(String s) => lib.lookupFunction<
              Int32 Function(Pointer<Void>, Pointer<Utf8>),
              int Function(Pointer<Void>, Pointer<Utf8>)>(
          'mpv_command_string')(ctx, s.toNativeUtf8());

      setOpt('vo', 'null'); // 不出现窗口
      setOpt('ao', 'null'); // ★ 不碰声卡（这条测试绝不出声）
      setOpt('terminal', 'no');
      /*
       * ★★ keep-open=yes 是这条测试的关键前提。
       *    vo=null ⇒ 没有窗口要画 ⇒ mpv 会**尽快**跑完整个文件；
       *    一旦 EOF 就回到 idle，而 idle 状态下 audio-add 返回 -12/-4
       *    （实测：不设它必红，设了才 0）。
       *    真实播放场景里视频还在放，所以这里要保持"文件仍载入"。
       */
      setOpt('keep-open', 'yes');
      expect(
        lib.lookupFunction<Int32 Function(Pointer<Void>), int Function(Pointer<Void>)>(
            'mpv_initialize')(ctx),
        0,
        reason: 'mpv_initialize 失败',
      );

      /*
       * ⚠️ mpv 的命令行解析器把反斜杠当转义符 —— Windows 路径必须换成正斜杠，
       *    否则 loadfile 直接返回 -4 invalid parameter。
       *    （实测踩过：不换就是 -4，换了就 0。）
       */
      final vpath = video.path.replaceAll(r'\', '/');
      final apath = audio.path.replaceAll(r'\', '/');

      // 先把视频轨载入（还原真实播放场景：先 loadfile，再挂音轨）
      expect(
        cmd('loadfile "' + vpath + '" replace'),
        0,
        reason: 'loadfile 视频轨失败',
      );
      // 等 file-loaded 落地（独立线程 ⇒ 轮询而不是死等）
      {
        final sw0 = Stopwatch()..start();
        while (sw0.elapsedMilliseconds < 8000) {
          final p0 = lib.lookupFunction<
              Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
              Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>(
              'mpv_get_property_string')(
              ctx, 'file-loaded'.toNativeUtf8());
          if (p0 != nullptr) {
            final s0 = p0.toDartString();
            lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
                'mpv_free')(p0);
            if (s0 == 'yes') break;
          }
          sleep(const Duration(milliseconds: 100));
        }
      }

      /*
       * ① 旧写法：这正是原代码那一句。
       *    必须是**失败**的 —— 否则说明 mpv 改了语义，这条门禁的前提要重审。
       */
      final rcOld = setProp('audio-file', apath);
      expect(
        rcOld,
        lessThan(0),
        reason: '★ audio-file 竟然成了运行期属性？那这条门禁的前提失效，'
            '必须重新确认 mpv 语义后再改判据（不要直接删断言）',
      );

      /*
       * ② 新写法：media_kit 的 setAudioTrack(AudioTrack.uri) 发的就是这条命令。
       *    必须**成功**，并且音轨真的出现在 track-list 里。
       */
      final rcNew = cmd('audio-add "' + apath + '" select probe-audio auto');
      expect(rcNew, 0, reason: '★ audio-add 必须成功 —— 这是「有没有声音」的分水岭');

      String? prop(String n) {
        final p = lib.lookupFunction<
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>),
            Pointer<Utf8> Function(Pointer<Void>, Pointer<Utf8>)>(
            'mpv_get_property_string')(ctx, n.toNativeUtf8());
        if (p == nullptr) return null;
        final s = p.toDartString();
        lib.lookupFunction<Void Function(Pointer<Utf8>), void Function(Pointer<Utf8>)>(
            'mpv_free')(p);
        return s;
      }

      // 等 mpv 把外挂音轨解出来（独立线程 ⇒ 轮询而不是死等）
      var found = false;
      final sw = Stopwatch()..start();
      while (sw.elapsedMilliseconds < 8000) {
        final n = int.tryParse(prop('track-list/count') ?? '0') ?? 0;
        for (var i = 0; i < n; i++) {
          final k = 'track-list/' + i.toString() + '/';
          if (prop(k + 'type') == 'audio' && prop(k + 'external') == 'yes') {
            found = true;
          }
        }
        if (found) break;
        sleep(const Duration(milliseconds: 100));
      }
      expect(
        found,
        isTrue,
        reason: '★ audio-add 返回成功后，track-list 里必须出现 external 音频轨',
      );
    });
  });
}