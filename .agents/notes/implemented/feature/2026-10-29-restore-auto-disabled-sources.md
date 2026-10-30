# Agent Note: 「全部」为什么只扇出 47 个源 —— 一次自动化留下的停用名单，用一次性迁移修数据

Status: implemented

Independent: 与 `2026-10-29-aggregate-search-bounded-concurrency.md`（扇出**速度**）不同，
本条解决**扇出范围**（参与搜索的源数）。也不改 R2-B（用户停用不参与）这条纪律。

## Problem

Owner：「75 个源，就是 tvbox 聚合源支持的那个」。

真机逐个源直测（绕过聚合，同一关键词「老舅」）：

```text
注册 98 个源 ⇒ 有结果 50 / 空 2 / 错 46
聚合「全部」实际只扇出 47 个候选 ⇒ 14 个源有结果
```

差的 51 个 id 在 `disabled-providers.json` 里（此处只列**类目**，不逐字列源 id ——
本仓规矩：仓库里不许出现具体视频网站/频道名，见 `test/t98_no_site_names_test.dart`）：
「api 系 5 个、bfzyapi 系 2 个、cj 系 3 个、caiji 系 2 个、直播频道型源 1 个、
数字编号源 2 个、某弹幕站 1 个、ffzy / hongniuzy2 / jszyapi 系 / sdzyapi /
suoniapi 系 / tyyszy 各若干、csp-bili-* ×10、csp-panwebshare-* ×6 …」

这些都是**能搜到「老舅」的站**（其中直播频道型源 54 条、api 系 4 条、某弹幕站 20 条…），
但它们被 `enabled_manifests()` 过滤掉 ⇒ 连搜索都不参与。

## Decision

```text
**修数据，不改规则**：新增 `provider_migration::run_once`，在 bootstrap 的
「应用停用状态」之前跑一次，把 disabled 列表里**本身可搜索**（capabilities.search）
的 id 摘出来（= 恢复启用），不可搜索的（直播/豆瓣/网盘/短视频）原样留在停用列表。
用标记文件 `provider-migration.json` 保证只跑一次 —— 用户之后手动停用的源不会被"复活"。
```

真机效果（同一命令、同一关键词）：

```text
聚合候选子站数 47 → **89**
按源分组：14 个源 → **50 个源有结果**（其余 39 个是 46 个错误里的 Unsupported/站点侧失败）
```

## Alternatives considered

### A. 让聚合忽略停用（`enabled_children` 直接用 `registry.manifests()`）

**最强理由**：一行改动，立即从 14 变成 50，看起来最省事。

**否掉的原因**：我把这条实现出来了，结果**4 个门禁当场变红** —— 它们钉的是纪律 R2-B：
「用户显式停用的源不许被搜出来」（首页关了、搜索还能搜到 = 用户报过的 bug）。
为了数字好看推翻一条用户意图的纪律，是本仓明确禁止的做法。⇒ 撤回，改修数据。

### B. 让用户在 UI 里一个个把 51 个源打开

**最强理由**：完全尊重用户操作，不动任何文件。

**否掉的原因**：这 51 个不是用户关的（是导入/整顿那几轮自动化整批写进去的），
让用户手工点 51 次去修我们自己的账，是把债务转嫁给 Owner。而且他明确要求"你自己操作"。

### C. 直接删掉 `disabled-providers.json`

**最强理由**：最短路径，等于"全部启用"。

**否掉的原因**：会把**用户真的手停过**的源也一起复活（例如他特意关掉的直播源）。
迁移按 `capabilities.search` 精确摘取，且只跑一次，是能区分"自动化产物"与"用户意图"的最小代价方案。

## Consequences

**收益**

- 「全部」的参与源从 47 → **89**（≥ 原版的 75），有结果的源从 14 → **50**。
- R2-B 纪律原样保留（用户手停的仍不参与），并有 `run_once_respects_marker` 门禁证明。
- 迁移是纯函数 + 幂等，可在门禁里穷举三种情形（可搜索摘掉/不可搜索保留/未注册保留）。

**代价与边界**

- 声明 `search: true` 但实际在 `search()` 里才拒绝的源（直播/豆瓣/网盘那 17 家）会被恢复，
  扇出时贡献一条 `Unsupported` 失败记录（探针里可见）。这是"manifest 说谎"的既存问题，
  不在本条范围内修（改它要动各 provider 的能力声明）。
- 迁移只跑一次：以后若再有"自动化批量停用"，需要新增 `restore_searchable_v2` 键（有意为之）。
- 50 ≠ 75：剩下 25 个差额是"源里真的没有这部剧"（`csp-4k-zhinan`/`csp-libvio`/`csp-hd-moli`
  等已被逐家证明是"站点自己说没有"）与"站点侧坏了"（1905 403 / duboku 400 / wwys 模板缺失）。

## 验证结果（已发生）

```text
cargo test --lib provider_migration --release → 3 passed
  plan_restores_only_searchable / plan_keeps_unknown_ids / run_once_respects_marker
cargo test --lib tvbox_aggregate --release → 23 passed（R2-B 的 4 条恢复绿）
真机（live_search_probe，真网）：
  迁移前：候选 47 / 有结果 14
  迁移后：候选 89 / 有结果 50
故障注入：见 plan_restores_only_searchable 的注释（把 `searchable.contains` 改 `true` ⇒ 红）
```

## Relations

- 扇出速度：[../feature/2026-10-29-aggregate-search-bounded-concurrency.md](../feature/2026-10-29-aggregate-search-bounded-concurrency.md)
- 分享页播放（同批另一条线）：[../bug-fix/2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md](../bug-fix/2026-10-29-aggregate-episode-id-prefix-broke-pan-play.md)