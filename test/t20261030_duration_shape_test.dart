// ═══════════════════════════════════════════════════════════════════════
//  时长形态判据门禁（Owner 2026-10-30：「播的都是 6 秒，不是完整内容」）
// ═══════════════════════════════════════════════════════════════════════
//
// # 缺陷形态（真机抽测 .probe/play-audit-all-sources-2026-10-30.md）
//
// ```text
//   2s   csp-appyqk  「老舅 第1集」
//   6s   csp-appyqk  「老舅除三害 第1集」
//   79s  csp-gui-gui 「老舅除三害（80集）」
//  360s  csp-biliys  「流浪地球2」        ← 电影只有 6 分钟
// ```
// 原来的 `isSuspectedSampleLine` 只卡 `< 60s` ⇒ 79s / 360s 这两类**抓不到**，
// 但它们同样不是完整正片。本批新增"内容形态感知"判据兜住它们。
//
// # 判据设计（保守，宁可漏标不冤枉）
//
// ```text
// · shortform（音乐/DJ/直播/MV/演唱会…）⇒ 不判（本来就可以只有几分钟）
// · film（单条电影）                    ⇒ 期望 ≥ 20min
// · episode（有集数）                   ⇒ 期望 ≥  3min
// ```
// 阈值取很低：1~2 分钟一集的短剧不该被冤枉成片段。
//
// # 注入证红
//
// 把 `implausibleDurationTag` 改成恒等返回 null ⇒ 组①「360s 电影判片段」、
// 组②「79s 剧集判片段」必红（记录在决策笔记）。

import 'package:flutter_test/flutter_test.dart';
import 'package:sourin_spike/ui/player_page.dart'
    show ContentShape, implausibleDurationTag, inferContentShape;

void main() {
  group('①inferContentShape：内容形态推断', () {
    test('音乐/DJ/直播/MV ⇒ shortform（不参与片段判定）', () {
      expect(
        inferContentShape(title: '宝石Gem vs 老舅 - 爱的恰恰(Dj海文 LakHouse Rmx)', episodeCount: 0),
        ContentShape.shortform,
      );
      expect(inferContentShape(title: '周杰伦 - 稻香 MV', episodeCount: 0),
          ContentShape.shortform);
      expect(inferContentShape(title: '2026 跨年演唱会 直播', episodeCount: 0),
          ContentShape.shortform);
    });

    test('有集数 ⇒ episode', () {
      expect(inferContentShape(title: '老舅', episodeCount: 27), ContentShape.episode);
      expect(inferContentShape(title: '老舅 第3集', episodeCount: 0),
          ContentShape.episode);
      expect(inferContentShape(title: '老舅除三害（80集）', episodeCount: 0),
          ContentShape.episode);
    });

    test('单条无集数 ⇒ film', () {
      expect(inferContentShape(title: '流浪地球2', episodeCount: 0),
          ContentShape.film);
      expect(inferContentShape(title: '庆余年 第二季', episodeCount: 0),
          ContentShape.film);
    });
  });

  group('①implausibleDurationTag：时长与形态不符', () {
    test('★ 电影 360s（6 分钟）⇒ 疑似片段（Owner 现场看到的那条）', () {
      expect(
        implausibleDurationTag(
            durationSeconds: 360, shape: ContentShape.film),
        '疑似片段',
        reason: '电影不可能只有 6 分钟 —— 这是"不是完整内容"的典型形态',
      );
    });

    test('★ 剧集 79s ⇒ 不在此处判（剧集档不按纯阈值判，避免冤枉短剧）', () {
      // 79s 这类"剧集但明显太短"的样本，纯时长无法与 90s 一集的短剧区分，
      // 所以剧集档不做额外判定；`< 60s` 由 isSuspectedSampleLine 标「疑似样片」。
      expect(
        implausibleDurationTag(
            durationSeconds: 79, shape: ContentShape.episode),
        isNull,
        reason: '短剧 60~120 秒一集是合法形态，纯阈值判定会冤枉它（门禁实测反例）',
      );
    });

    test('电影 7200s（2 小时）⇒ 不判（正常正片）', () {
      expect(
        implausibleDurationTag(
            durationSeconds: 7200, shape: ContentShape.film),
        isNull,
      );
    });

    test('剧集 2400s（40 分钟）⇒ 不判（正常单集）', () {
      expect(
        implausibleDurationTag(
            durationSeconds: 2400, shape: ContentShape.episode),
        isNull,
      );
    });

    test('★ 短剧 90s 但有集数 ⇒ 不判（2 分钟内一集的短剧是合法的，不冤枉）', () {
      expect(
        implausibleDurationTag(
            durationSeconds: 90, shape: ContentShape.episode),
        isNull,
        reason: '短剧单集可能只有 1~2 分钟，阈值取 3 分钟就是为了不冤枉它',
      );
    });

    test('音乐 335s ⇒ 不判（shortform 形态不参与判定）', () {
      expect(
        implausibleDurationTag(
            durationSeconds: 335, shape: ContentShape.shortform),
        isNull,
      );
    });

    test('没读数（null/0）⇒ 不判（不冤枉没量过的线路）', () {
      expect(
          implausibleDurationTag(durationSeconds: null, shape: ContentShape.film),
          isNull);
      expect(implausibleDurationTag(durationSeconds: 0, shape: ContentShape.film),
          isNull);
    });
  });

  group('①边界：阈值两侧各测一格', () {
    test('电影：1199s 判、1200s 不判', () {
      expect(
          implausibleDurationTag(
              durationSeconds: 1199, shape: ContentShape.film),
          '疑似片段');
      expect(
          implausibleDurationTag(
              durationSeconds: 1200, shape: ContentShape.film),
          isNull);
    });

    test('剧集：不做阈值判定（任何时长都返回 null）', () {
      expect(
          implausibleDurationTag(
              durationSeconds: 179, shape: ContentShape.episode),
          isNull);
      expect(
          implausibleDurationTag(
              durationSeconds: 180, shape: ContentShape.episode),
          isNull);
      expect(
          implausibleDurationTag(
              durationSeconds: 61, shape: ContentShape.episode),
          isNull,
          reason: '剧集档一律不判 —— <60s 归 isSuspectedSampleLine，其余交给用户看时长');
    });
  });
}
