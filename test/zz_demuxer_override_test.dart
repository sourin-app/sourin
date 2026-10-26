// ══════════════════════════════════════════════════════════════════════
//  伪装成 `.mp3` 的 MP4 ⇒ 起播前强制 demuxer（Owner 投诉收口）
// ══════════════════════════════════════════════════════════════════════
//
// # 真根因（live-accept 实机取证）
// ```text
// 上游 URL：…/5bC85Y+k5Za15Za1MDF6bS5tcDQ=.mp3
// base64 解出：           尼古喇喇01zm.mp4      ← 真身是 MP4，后缀被伪装成 .mp3
// 现象：代理 206/468ms 正常转发、字节在流，但【首帧永远不出】；起播失败 0 次
// 原因：mpv 按 **URL 后缀**选 demuxer ⇒ .mp3 走音频 demuxer ⇒ 只有音轨
// ```
// ⇒ 用 `kind`（插件按 URL 内容推断出的真类型）去纠正 mpv 的后缀猜测：
//   `kind` 含 mp4 且 URL 以 `.mp3` 结尾 ⇒ `demuxer-lavf-format=mov`。
//
// # 三条判据
// ```text
// ① 纯判据真值表（不改状态）：
//      mp4 + .mp3          ⇒ true
//      mp4 + .mp3?query=1  ⇒ true
//      mp4 + .mp4          ⇒ false
//      mp3 + .mp3          ⇒ false（真 mp3 不能被当 mp4）
//      空 kind + .mp3      ⇒ false
// ② 生产下发路径：伪装条目 ⇒ 探针读到 `mov`
// ③ 不残留：紧接着下发一条**真 mp3** ⇒ 探针读回 null（清空过）
// ```
//
// ⚠️ **本仓 widget 测试必须 `import 'package:material_ui/material_ui.dart';`**
//    （不是 `package:flutter/material.dart`）—— 混用会让 `InkWell` 找不到
//    `Material` 祖先（2026-10-26 实测踩过）。
//
// 跑法：
// ```powershell
// flutter test test/zz_demuxer_override_test.dart \
//   --run-skipped --tags native-media --concurrency=1
// ```
@Tags(['native-media'])
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

import 'package:sourin_spike/core/models.dart';
import 'package:sourin_spike/ui/player_page.dart';

import 't102_playback_failure_banner_test.dart' as fixture;

/// 实机取证的那条 URL（后缀伪装成 .mp3，base64 解出是 `尼古喇喇01zm.mp4`）
const _disguised =
    'https://example.invalid/s/5bC85Y+k5Za15Za1MDF6bS5tcDQ%3D.mp3';

Future<void> _mount(WidgetTester t) async {
  MediaKit.ensureInitialized();
  // ★ 门禁里**不碰 mpv**：mpv 未就绪时 `setProperty` 会永久挂住
  //   （实测踩过：整条用例 `did not complete`，10 分钟超时）。
  //   这条开关同时让 `open` 跳过 ⇒ 整条用例只验"判据 + 下发值记录"这两件事。
  debugPlayerSkipOpenForProbe = true;
  addTearDown(() => debugPlayerSkipOpenForProbe = false);
  await t.binding.setSurfaceSize(const Size(1280, 800));
  addTearDown(() => t.binding.setSurfaceSize(null));
  await t.pumpWidget(MaterialApp(
    home: Scaffold(
      body: PlayerPage(
        provider: 'cycani',
        id: 'show-1',
        title: '次元城',
        episodes: const [
          Episode(id: 'e1', title: '第1集', index: 0),
          Episode(id: 'e2', title: '第2集', index: 1),
        ],
        episodeIndex: 0,
        episodeId: 'e1',
        isTv: false,
        isTouchOnly: false,
      ),
    ),
  ));
  await t.pump();
  await fixture.drain(t);
}

void main() {
  group('① 纯判据（真值表）', () {
    test('kind=mp4 + .mp3 ⇒ 需要覆盖；其它组合都不需要', () {
      // ★ 伪装 case（实机那条）：true
      expect(debugPlayerNeedsDemuxerOverrideForProbe(_disguised, 'mp4'), isTrue,
          reason: '★ 实机那条：kind 是 mp4、后缀 .mp3 ⇒ 必须强制 demuxer');
      expect(
          debugPlayerNeedsDemuxerOverrideForProbe(
              'https://x.invalid/a.mp3?token=1', 'MP4'),
          isTrue,
          reason: '★ 带 query 也必须识别（后缀判断要剥 query）、kind 大小写不敏感');
      // 非伪装 case：全部 false
      expect(debugPlayerNeedsDemuxerOverrideForProbe('https://x.invalid/a.mp4', 'mp4'),
          isFalse,
          reason: '★ 后缀本来就是 .mp4 ⇒ 不设（否则多此一举）');
      expect(debugPlayerNeedsDemuxerOverrideForProbe('https://x.invalid/a.mp3', 'mp3'),
          isFalse,
          reason: '★★ 真 mp3 绝不能被当 mp4 解析');
      expect(debugPlayerNeedsDemuxerOverrideForProbe('https://x.invalid/a.mp3', ''),
          isFalse,
          reason: '★ kind 为空（上游没给）⇒ 不猜，保持 mpv 自己的判断');
    });
  });

  group('② 生产下发路径 + ③ 不残留', () {
    testWidgets('伪装条目 ⇒ mov；紧接着真 mp3 ⇒ 清空（不残留）', (t) async {
      await _mount(t);

      // ② 伪装条目
      expect(await debugPlayerApplyDemuxerForProbe(_disguised, 'mp4'), isTrue);
      expect(debugPlayerDemuxerFormatForProbe(), 'mov',
          reason: '★★ 伪装条目必须下发 `demuxer-lavf-format=mov`（否则只有音轨、首帧不出）');

      // ③ 立刻切到一条**真 mp3**
      expect(
          await debugPlayerApplyDemuxerForProbe('https://x.invalid/real.mp3', 'mp3'),
          isTrue);
      expect(debugPlayerDemuxerFormatForProbe(), isNull,
          reason: '★★★ 切到真 mp3 必须**清空**覆盖值 —— 残留 `mov` 会让这条解析不了'
              '（注入：把清空那支去掉 ⇒ 这里读到 "mov" ⇒ 红）');

      // 再切回伪装条目，仍要能重新设上（不是一次性）
      expect(await debugPlayerApplyDemuxerForProbe(_disguised, 'mp4'), isTrue);
      expect(debugPlayerDemuxerFormatForProbe(), 'mov',
          reason: '★ 清空后还能重新设置（切来切去不能只生效第一次）');
    });
  });
}
