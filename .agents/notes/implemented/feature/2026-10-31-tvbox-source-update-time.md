# Agent Note: TVBox 订阅源"上次更新时间"显示 + 定时自动更新

Status: implemented

Applies on 2026-11-12 to the current TVBox subscription schedule row and the existing source-update contract.

Independent: 与 [2026-10-29-restore-auto-disabled-sources.md](../feature/2026-10-29-restore-auto-disabled-sources.md)
（源启用策略）互补——那篇管"哪些源参与"，本篇管"源数据的新鲜度可见 + 自动保新鲜"。
JS 插件源的 task-12 检测更新体系是独立机制，本篇不触碰。

## Problem

Owner（逐字）：「源 里面的没有显示上次更新时间,这个要显示出来,定时更新」。
现状：TVBox 订阅 sidecar（TvboxSourceMeta）无任何更新时间字段；更新纯手动；
JS 插件源卡片有更新时间（task-7）但 TVBox 原生源卡片没有。

## Decision

```text
① 数据模型：TvboxSourceMeta + last_update_at/last_update_ok/last_update_error
   （serde default ⇒ 旧 sidecar 显示"从未更新"，向后兼容）。
② 盖章语义（关键判据）：update_tvbox_source 成功两条路径（应用 + "远端无变化"
   早退）都给同链接全部 in_link 源盖成功章——漏盖未变源会让定时器每轮重复
   下载同一链接；失败统一 log::warn + 失败章带原因；"无链接/无源"不盖章。
③ 并发：update_tvbox_source 拆 inner + 入口 wrapper，进程级 tokio::Mutex
   串行化定时与手动（定时单 task 顺序 await + MissedTickBehavior::Delay
   ⇒ 长更新不堆叠）。
④ 调度：spawn_auto_update 每 60s tick，读 tvbox-update-schedule.json
   （默认开 + 24h，档位 关/6h/12h/24h 白名单），tvbox_update_due 纯函数
   判到点（从未更新=due），collect_due_links 按链接去重；冷启动超期由首轮
   tick（延迟 60s，不拖启动）天然覆盖。
⑤ UI：TVBox 源卡片副行「上次更新：MM-dd HH:mm / 失败(红) / 从未更新」
   （共享纯函数单一口径，设置网格 + 直播列表 + 聚合管理面板三处）；源列表
   顶部定时设置行（开关 + 档位，改动即落盘，失败有可见回音）。
```


The inline TvboxAutoUpdateRow accepts one save at a time. _save synchronously
checks _saving before reading the accepted schedule or invoking the public
asynchronous setter. A second pointer activation before the next frame returns
while that save is pending. The first accepted change owns its persisted result
and selected interval; additional pending activations are not queued. Success or
failure releases the busy state through the existing completion path. A rejected
save keeps the previously confirmed schedule, displays the existing error row,
and permits a subsequent explicit retry.

This UI boundary complements the existing process-level update lock: source
refresh serialization does not serialize the independently rendered schedule
row's configuration writes. The Miuix disabled callbacks take effect on rebuild;
the synchronous guard also covers activations before that rebuild.

## Alternatives considered

- **只给 added/changed 的源盖章（沿用旧行为）**：未变源时间戳不动 ⇒ 定时器
  每轮判定同一链接超期 ⇒ 每 60s 重复下载。否决——这正是"未变也盖章"成为
  关键判据的原因（测试 t5_update_unchanged_stamps_all_in_link_sources 钉死）。
- **定时更新直接删失联源（deleteMissing=true）**：静默删站违反"绝不静默删站"
  纪律。固定 applyNew=true/deleteMissing=false。否决。
- **更新失败静默**：静默失败=缺陷。wrapper 统一 log::warn + 失败章 + UI 红行。
- **schedule set 任意秒数**：互检 P3-1 抓到（直调 FFI 可塞 60s 变成每分钟
  下载）⇒ 收敛为三档白名单，其它值明确拒绝且不改写现有配置。

## Consequences


The schedule-row regression uses the real themed/localized row, two hit-testable
pointer taps in the same mounted State without a pump between them, and held
public asynchronous schedule getter/setter overrides. Its separate control
observes a rejected save, the existing error row and a subsequent actual retry.
The frozen draft is identical in both source arms. This proves the qualified
save boundary only when actual runtime evidence is complete; it is not a frame
rate, startup, source-refresh, native playback or Owner acceptance measurement.

Actual schedule-row evidence on 2026-11-12 uses the identical corrected test
payload in both source arms. Baseline reproduces [43200, 86400] for the primary
assertion expecting [43200]; its rejected-save/retry control passes. Candidate
passes both cases. Counts are baseline 1 failed / 1 passed / 0 skipped and
candidate 2 passed / 0 failed / 0 skipped, with actual CLI exits 1 and 0.
Both jobs finish naturally at zero, remain zero for at least eight seconds,
use no forced cleanup and retain all bound inputs.

Completed pair SHA256 2736346BC23ABC1BDC319B03E3F187291A43B437760F41155365CD8045EEE574
and baseline diagnostic audit SHA256
856E77FFCCC4D8D0130E3A6C42B0BC820203B5083BF5641052DE1FF2DDAA2EC5 bind those
completed logs. The original baseline result and pipeline remain false: the
actual assertion uses print + error isFailure=false + testDone result=error,
which the former reporter oracle rejects. No baseline test is rerun.

Four single-file analyses (the source and regression file in each arm) all
exit zero with natural stable Job0 and unchanged bound inputs. Each arm has
0 ERROR / 19 WARNING / 13 INFO. Complete normalized diagnostic multisets are
equal, duplicate multiplicity is retained, and additions/removals are empty.
Analyzer result SHA256
99BABEFB3E8A81A8BF960357D95493D551F0187B4EF7C179B16AC4BFE83DF06E binds the
four logs. This qualifies the bounded no-new-warning analysis; existing
warnings and infos remain, and no clean-analysis claim is made.

- 门禁：cargo 新增 6 条 t5_ 测试 + t5_schedule_set_whitelist；Dart 16 条
  （zz_t5b_tvbox_last_update_test）；两侧注入证红均实测红→绿。
- 互检（fix-t94-dialog-wiring）七项通过；打回项 P2-1（state.rs 工作区被写成
  CRLF——WriteAllLines 惯犯，已 ReadAllText+WriteAllText 归零，CRLF 1542→0）
  与 P3-1（档位白名单）当场修毕；P2-2（metas 其它写路径收口同锁）记下批。
- 互检抓到的环境插曲：全量 cargo 曾 11 条红，全部是 T1b 在制品 pan_check.rs
  的瞬态，收敛后 1973 passed / 0 failed。

## 边界（如实）

- 定时只覆盖 TVBox 订阅源；JS 插件源的 task-12 体系未纳入（如 Owner 要另开卡）。
- 定时更新固定 applyNew=true/deleteMissing=false——绝不静默删站。
- sidecar 其它写路径（import/set/remove/restore）暂在 UPDATE_LOCK 外，
  与定时循环并发可互覆盖章（低概率自愈），下批收口。


## Current manual refresh scope

[Actual live refresh](../bug-fix/2026-11-11-tvbox-live-actual-refresh.md) adds
independent live preview/outcomes. [Exact parent routing](../bug-fix/2026-11-11-tvbox-origin-refresh-identity.md)
accepts parent IDs without VOD and stamps the resolved owned VOD IDs, including
unchanged IDs, rather than unrelated same-URL parents. The conservative VOD-only
deletion policy remains. [Parent clocks and scheduled ownership](../bug-fix/2026-11-11-tvbox-parent-clock-and-scheduler.md)
add exact parent clocks and zero-VOD enumeration. The actual scheduled branch
rechecks current configuration and clock under the shared update lock; uncovered
legacy sidecars retain their existing path.
