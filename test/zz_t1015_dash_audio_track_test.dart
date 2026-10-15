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
// 实测（FFI 打本仓自带的 libmpv-2.dll，见 zz_t1015b 那条 native 用例）：
//   mpv_set_property_string(ctx, "audio-file", url)   → -8 property not found
//   mpv_command(ctx, ["audio-add", url, "select", …]) → 0 success
// ```
// 而 media_kit 的 `setProperty` **丢掉返回码**
//   （media_kit-1.2.6/…/native/player/real.dart:1239 不检查返回值）
// ⇒ 失败**完全静默**：日志照打「已挂载外挂音轨」、画面正常、就是没声音。
//
// ★ 本文件**不加载** libmpv ⇒ 默认就会跑（不进 native-media 标签）。
//   真实 DLL 那一层在 `zz_t1015b_dash_audio_native_test.dart`。
// ═══════════════════════════════════════════════════════════════════════

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const String _playerPage = 'lib/ui/player_page.dart';

void main() {
  group('① 源码契约：外挂音轨必须走运行期命令', () {
    late String src;

    setUpAll(() {
      src = File(_playerPage).readAsStringSync();
    });

    test('★★ 不得再把音轨挂到 audio-file / audio-files-append 属性上', () {
      /*
       * 这两个名字都是 mpv 的**加载期命令行选项**，不是运行期属性。
       * 用 setProperty 去设它们只会拿到 `-8 property not found`，
       * 而 media_kit 吞掉返回码 ⇒ 静默无声。
       */
      const bad = <String>[
        "setProperty('audio-file'",
        'setProperty("audio-file"',
        "setProperty('audio-files-append'",
        'setProperty("audio-files-append"',
        "setProperty('audio-files'",
        'setProperty("audio-files"',
      ];
      for (final b in bad) {
        expect(
          src.contains(b),
          isFalse,
          reason: '★ 又出现 ' +
              b +
              ' —— 这就是「有画面没声音」的原始缺陷：'
                  'audio-file 是加载期选项、没有运行期属性，设了等于没设。',
        );
      }
    });

    test('★★ 必须用 setAudioTrack(AudioTrack.uri(...)) 挂外挂音轨', () {
      expect(
        src.contains('setAudioTrack('),
        isTrue,
        reason: '必须走 media_kit 的 setAudioTrack —— 它内部发的是运行期命令 audio-add',
      );
      expect(
        src.contains('AudioTrack.uri('),
        isTrue,
        reason: 'AudioTrack.uri(...) 才是「从 URL 加载外挂音轨」的构造',
      );
      // 必须是拿 st.audioUrl 去挂，而不是别的变量（防止挂错东西）
      final i = src.indexOf('setAudioTrack(');
      final seg = src.substring(i, (i + 400) < src.length ? i + 400 : src.length);
      expect(
        seg.contains('st.audioUrl'),
        isTrue,
        reason: '挂的必须是候选流自带的 audioUrl（DASH 分离出来的那条音轨）',
      );
    });

    test('★ 挂载结果要落 AppLog（release 里 debugPrint 不进日志）', () {
      /*
       * 2026-10-15 排查时，整份 sourin-*.log 里**一条 [PLAYER] 都没有** ——
       * 因为这里原来只打 debugPrint，而它不进日志文件。
       * 结果就是：线上完全无法判断音轨到底挂上没有。
       */
      /*
       * ⚠️ 必须找**代码里**那一句，不能只 indexOf('已挂载外挂音轨') ——
       *    本文件/播放页的**注释**里也出现过这个字串，先撞上注释就会假绿。
       *    （这条断言第一版就踩了这个坑：撞到注释 ⇒ 误报。）
       */
      expect(
        src.contains("AppLog.write('PLAY', '已挂载外挂音轨"),
        isTrue,
        reason: '挂载成功要落 AppLog —— 原来只打 debugPrint，线上查不到',
      );
      expect(
        src.contains('AppLog.write(') &&
            src.contains('挂载外挂音轨失败'),
        isTrue,
        reason: '挂载**失败**也必须落 AppLog（这条路径原来完全静默）',
      );
      // 失败分支附近不得只剩 debugPrint
      final f = src.indexOf('挂载外挂音轨失败');
      final seg = src.substring(f > 200 ? f - 200 : 0, f + 40);
      expect(
        seg.contains('AppLog.write('),
        isTrue,
        reason: '失败分支必须写 AppLog，否则用户报「没声音」时日志里什么都没有',
      );
    });
  });


}