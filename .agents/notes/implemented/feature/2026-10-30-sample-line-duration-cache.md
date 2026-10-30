# Agent Note: 20 秒样片线路 —— 时长缓存 + 标注「疑似样片 (m:ss)」+ 默认跳过

Status: implemented

Independent: 与选集/聚合显示各条互不依赖；只依赖 `StreamCandidate.label`
（task-4 Rust 落地后键更稳；label 缺失时键退 quality，再缺失不记不读 —— 宁缺勿错）。

## Problem

Owner 现场：聚合源里不少线路是「20 秒样片」，起播没多久就停，而且**默认选中**
的第一条经常就是这种线路。判据（Owner 指定）：duration < 60s。

约束：duration **起播后**才有 —— 选默认线路的那一刻（resolve 返回时）手里没有它。

## Decision

```text
方案A（本批采用）：线路时长缓存
  · 键 = lineDurationKey(provider, contentId, label|quality)（纯函数）；
  · 写入点 = duration 广播（_recordLineDuration），落 UiPrefs
    'dsh.player.lineDurations'（JSON，上限 400 条按插入序淘汰）；
  · 读取点 = ① _load 默认选线（pickDefaultPlayable 跳过缓存时长 <60s 的；
    全部疑似 ⇒ 保持原序播第一条，由抽屉统一标注）；
    ② _StreamSheet 行标注 sampleBadgeOf → 「疑似样片 (m:ss)」。
  · 零起播延迟；第一次遇到某条样片线路仍会中招一次，但**只中一次**
    （同剧同线路记一次，跨页面实例、跨重启）。

方案B（备选，本批不启用）：resolve 阶段轻量探测 m3u8 首分片时长
  · 做法：resolve 后对 m3u8 GET 首个分片，用 EXTINF 时长估计整片；
  · 优点：**首次**就能避开样片；缺点：每条线路多一次网络往返 ⇒ 增加起播延迟，
    且分片时长≠整片时长（片头曲/广告会让估计失真，还需白名单化站点行为）。
  · Owner 若要"首次也避开"：在 Rust resolve 侧加（异步批量预取更合适），
    Dart 侧判据（isSuspectedSampleLine）与标注位不变，只换 durationOf 的来源。
```

纯函数：`isSuspectedSampleLine`（0 < d < 60，null/≤0 不冤枉没量过的）、
`formatLineDuration`（m:ss）、`lineDurationKey`、`pickDefaultPlayable` ——
全部 @visibleForTesting，门禁直接钉。

## Alternatives considered

### A. 只标注不跳过（默认仍选第一条）

否掉的原因：Owner 验收①明确"样片线路有标注**且不默认选中**"——标注解决
"知道它是坑"，跳过解决"别掉进去"，两半都点名了。

### B. 把样片线路排到候选列表末尾（改 _streams 顺序）

否掉的原因：候选顺序是 resolve 的产品契约（原版"不按清晰度重排"同一纪律）；
换序会让抽屉行序在"有缓存↔无缓存"之间抖动。只改**默认选中**，列表序不动。

### C. resolve 阶段探测（方案B 直接上）

否掉的原因：给**每条**线路的每次起播加网络往返，换来的只是"第一次也不中招"；
与 Owner"先试缓存方案（不增加起播延迟）"的指定相反。保留为备选并写明回头条件。

### D. 判据放宽到 <120s（有些"样片"是 90s 预告）

否掉的原因：Owner 指定 60s；放宽会让正片较短的单集（如短片/预告合集）被误标。
数据不足时先守 60，抽测矩阵（任务6）若证明 60-120 区间样片成规模，再议。

## Consequences

**收益**
- 默认线路自动避开已知的样片线路；抽屉一眼看出「疑似样片 (0:20)」。
- 非样片路径零变化：没读数的线路既不标注也不跳过（门禁各有一条守着）。

**代价与边界**
- 首次中招一次（缓存冷启动）—— 方案B 的回头条件写在上面。
- 键依赖 label/quality 稳定性：一次性签名 URL 不进键（lineDurationKey 只用
  label→quality）；两者皆空的线路不记不读（空尾巴键）。
- 换剧/换集不换键的前缀（provider:contentId）⇒ 缓存天然按剧隔离。
- 缓存上限 400：超过淘汰最旧 —— 长期看高频剧目自会重新记录。

## 验证结果（已发生）

```text
门禁：test/t20261030_sample_line_test.dart → 9 passed
  ① 纯函数 4 条（59/60/0/null 边界、m:ss 补零、键的 label/quality/空尾巴、
    pickDefaultPlayable 跳样片/不冤枉没读数/全是样片保原序/空列表）
  ② 真树 2 条（灌生产 _lineDurationCache ⇒ 20s 行标「疑似样片 (0:20)」、
    无读数不标注）
  ③ 静态接线 3 条（_load 真调 pickDefaultPlayable、duration 广播真调
    _recordLineDuration、抽屉真传 sampleBadgeOf —— resolve/FFI 在 widget
    测试里不可达，t61 同款剥注释断言）
flutter analyze lib/ui/player_page.dart → 0 errors
故障注入（实测真红后恢复复绿）：
  ① pickDefaultPlayable 恒取第一条 ⇒ 组① pick 用例红
  ② _StreamSheet 删样片标注块 ⇒ 组②「疑似样片 (0:20)」红
  ③ _load 退回 firstOrNull + 删 _recordLineDuration 调用 ⇒ 组③ 两条静态红
真机：等 driver-ops 驱动器就绪后批末统一（用此前 20s 样片线路实测标注与跳过）。
```

## Relations

- 同批判据公共化：[../bug-fix/2026-10-30-right-detail-line-filter-and-badge.md](../bug-fix/2026-10-30-right-detail-line-filter-and-badge.md)
- 同批聚合显示（标注所在行的前缀）：[./2026-10-30-aggregate-source-title-dart.md](./2026-10-30-aggregate-source-title-dart.md)
