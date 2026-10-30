# Agent Note: 时长形态判据 —— 电影 6 分钟这类「不是完整内容」要被认出来

Status: implemented

Independent: 与 `2026-10-30-sample-line-duration-cache.md`（线路时长缓存 + `<60s` 样片判据）互补：
那条是**绝对**判据（很短就是样片），本条是**形态感知**判据（与内容形态明显不符就是片段）。
两条判据串联使用，都挂在同一个时长缓存读数上。

## Problem

Owner 2026-10-30 现场反馈：「我今天还看了你大部分的都是播放都是6秒，根本就不是完整的视频内容」。

补做全子源真机抽测（43 源 × 124 条，见 `.probe/play-audit-all-sources-2026-10-30.md`）实测到的短时长：

```text
  2s   csp-appyqk  老舅 第1集
  6s   csp-appyqk  老舅除三害-家庭情感 第1集
 79s   csp-gui-gui 老舅除三害（80集）
360s   csp-biliys  流浪地球2            ← 电影只有 6 分钟
```

原判据 `isSuspectedSampleLine` 只卡 `< 60s`：

```dart
bool isSuspectedSampleLine(int? d) => d != null && d > 0 && d < 60;
```

⇒ 2s / 6s 能标出来，但 **79s 和 360s 完全漏掉**。而这恰恰是 Owner 抱怨的主体：
一部电影只有 6 分钟，App 当成"播放成功"，用户看到的就是残缺内容。

## Decision

新增"内容形态感知"判据，与原有样片判据串联：

```text
① inferContentShape(title, episodeCount) → ContentShape{film, episode, shortform}
     · 标题含 DJ/音乐/MV/Live/直播/演唱会/歌曲/演奏/remix ⇒ shortform
     · 有集数（episodeCount>1）或标题含「第N集」/「(N集)」 ⇒ episode
     · 其它 ⇒ film（单条电影）
② implausibleDurationTag(durationSeconds, shape)
     · shortform ⇒ 不判（音乐本来就可以只有几分钟）
     · film 且 < 20min ⇒ 「疑似片段」  ← 电影不可能 6 分钟
     · episode ⇒ **不判**（理由见下"踩坑"）
③ 接入两处：
     _sampleBadgeFor：① 优先判「疑似样片 (m:ss)」；否则 ② 判「疑似片段 (m:ss)」
     pickDefaultPlayable：新增可选注入点 implausibleOf，默认线路同时避开这两类
```

### 剧集档为什么最终不按阈值判（门禁抓到的反例）

第一版把剧集阈值定成 3 分钟，门禁 `t20261030_duration_shape_test` **立刻抓到反例**：

```text
✖ 短剧 90s 但有集数 ⇒ 不判（2 分钟内一集的短剧是合法的，不冤枉）
  Expected: null
  Actual: '疑似片段'
```

短剧平台（`csp-shorthaokan` / `csp-shortweiguan` 这类）60~120 秒一集是合法常态。
纯时长阈值**无法**把"90 秒的短剧"与"79 秒的预告"区分开。
⇒ 剧集档退回只保留 `< 60s`（归 `isSuspectedSampleLine` 标「疑似样片」），
`implausibleDurationTag` 对 episode 形态返回 null。宁可漏标 79s 那类，
也不把合法短剧冤枉成片段 —— 用户在线路抽屉里能看到每条线路的时长，能自己判断。

## Alternatives considered

- **只调大/调小单一阈值**：不管调到多少，短剧与预告在时长上无法区分。否决。
- **按源名/子源类型判**（短剧源不判片段）：源清单会漂，新源接进来就漏；且同名源内容混杂。否决。
- **剧集档用 3 分钟阈值**：门禁实测抓到"90s 短剧被冤枉"的反例。否决（这是本条最关键的决策）。
- **对标题做"预告/花絮"关键词匹配**：标题不可靠（大量源标题不带这类词），
  且属于启发式改写用户可见文案，误伤风险高。否决。
- **只在 UI 标注、不参与默认选线**：那默认线路仍会挑到 6 分钟的电影，等于没解决。否决。
- **`pickDefaultPlayable` 直接改签名强制传 implausibleOf**：会让既有调用点与门禁全红，
  且第三判据不属于"样片"语义。改为**可选注入点**（不传 = 原行为），保持向后兼容。

## Consequences

门禁读数：

```text
flutter test test/t20261030_duration_shape_test.dart     ⇒ 12 passed / 0 failed
flutter test test/t20261030_sample_line_test.dart        ⇒  9 passed / 0 failed
两文件合跑                                                ⇒ 21 passed / 0 failed
flutter analyze lib/ui/player_page.dart                  ⇒ 0 error
```

注入证红（实测，已回滚）：

```text
把 implausibleDurationTag 里的「film && < 20min ⇒ 疑似片段」分支删掉 ⇒
  -2: 「★ 电影 360s（6 分钟）⇒ 疑似片段」红
  -2: 「边界：电影 1199s 判、1200s 不判」红
  test result: Some tests failed
回滚后 ⇒ 12 passed（门禁不是恒绿）
```

同时修掉一个**门禁自身的缺陷**：`sample_line_test` 里有一条断言用逐字多行文本匹配
`pickDefaultPlayable(\n playableCandidates,\n _cachedLineDuration,\n );` ——
我加了第三个参数后它立刻红。这不是"改动破坏了契约"，而是**断言把实现细节钉太死**。
已改成正则找 `= pickDefaultPlayable(` 调用点 + 检查两个必需实参在附近，
既能抓"退回 firstOrNull"这个真回归，又不因加参数而误报。

边界与如实记录：

- ⚠️ **79s 那类"剧集但明显太短"现在不会被自动标注** —— 这是有意的取舍（见上）。
  如果 Owner 认为该标，需要先解决"如何区分短剧与预告"，那需要源侧元数据而不是时长。
- 电影档的 20 分钟阈值同样是启发式：真正的短片电影（<20min）会被误标。
  但相对"电影 6 分钟当正片播"，这个误标的代价小得多。
- 形态推断依赖标题：标题不含集数、`episodeCount` 又为 1 的剧集会被判成 film ⇒ 可能误标。
- 本次只改标注与默认选线，**不改播放行为本身**（该播的还是会播，只是标出来让用户知道）。
