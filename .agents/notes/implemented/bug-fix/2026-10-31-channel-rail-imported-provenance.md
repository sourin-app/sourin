# Agent Note: 渠道条 49 个 chip —— hidden 谓词语义漂移后改用导入 sidecar 当「用户导入」判据

Status: implemented

Independent: 本篇修的是 2026-10-28 那次「渠道条只列用户导入子站」实现（93eda35）
的**前提塌陷**，与同日另一需求（Owner 图1「聚合源…属于二级页面」→ state.rs 给
内置源也置 hidden）在同一谓词上相撞。两条需求各自都对，撞出的回归由
门禁 zz_n9_agg_channel_rail ⑥ 抓到（Expected 1 / Actual 49）。

## Problem

首页横向渠道条把 48 个内置 csp 源全列出来（1 导入 + 48 内置 = 49 chip），
正是 Owner 抱怨的「一次性加载太多」的原样回归。

根因链（ teammate 取证，Lead 复核）：

```text
93eda35（10-28）：channels_of() 用 manifest().hidden 当「用户导入的子站」判据
                  —— 当时成立，因为只有 TVBox 导入子站 hidden。
state.rs:480-494（同日晚些）：48 个内置 csp 源自动注册且也置 hidden: true
                  （Owner 要求聚合源收进二级页，不许平铺在源列表）。
⇒ hidden 的含义从「用户导入的」漂移成「藏进聚合二级页的（含全部内置）」
⇒ 渠道条 = hidden 全集 = 48 内置 + N 导入。
排除 stale-DLL：重出 DLL 哈希不同（7D60EA2E… vs 37255FF3…）行为仍旧 49
                  ⇒ 差异在源码语义，不在产物。
```

## Decision

「用户导入」改用**导入来源 sidecar**（`<data_dir>/tvbox-sources.json`，
导入流程逐站落记录，内置源没有）：

```rust
let imported: HashSet<String> = crate::tvbox::load_tvbox_metas(data_dir).into_keys().collect();
enabled_children(registry, data_dir)
    .into_iter()
    .filter(|p| p.manifest().hidden)          // 保留：第二道闸
    .filter(|p| imported.contains(&p.manifest().id))   // 新增：本篇判据
```

- 与同文件 `command_dedupe_sites` 判「重复子源」用**同一份 provenance**
  ——同一件事在本仓只有一个判据。
- `hidden` 保留作第二道闸：防将来出现「有 meta 却可见」的源混上渠道条。
- 扇出（home/list/search）口径**未动**——那是 Owner 要的原版行为
  （所有启用源扇出），与渠道条是两个概念，分工继续写死在注释里。

## Alternatives considered

- **改测试期望 1 → 49**：那是把回归写成规范。49 chip 正是 Owner 抱怨的形态。否决。
- **给内置源换回 hidden=false**：会推翻 Owner「聚合源收进二级页」的需求，
  源列表重新平铺 98 个。否决。
- **在 manifest 里加第三个布尔字段（imported）**：动数据模型与序列化兼容，
  而导入 provenance 已经存在于 sidecar——再立一份判据就是两处真相。否决。
- **渠道条改列全部启用源**：回到 93eda35 之前的更早形态，与「用户分组概念」
  语义不符（那条横条是用户自己导入的子站的快捷入口）。否决。

## Consequences

- 渠道条只列**用户导入过**的子站；内置 48 类回到聚合二级页，不再上条。
- 两条 Rust 单测（n9_channels_*）的假子站补了 sidecar 种子，断言语义不变。
- 门禁读数（Lead 亲验）：
  `flutter test test/zz_n9_agg_channel_rail_test.dart` ⇒ +23 全绿 RC=0；
  `cargo test --lib --release` ⇒ 1933/0 RC=0；
  DLL 五处一致 554D6A77…。
- 注入证红（teammate）：把 sidecar 判据临时改恒真 ⇒ ⑥ 精确变红
  （Expected 1 / Actual 49），还原后转绿。

## 边界（如实）

- 已导入过子站的真机用户不受影响（sidecar 本来就有记录）；
  从未导入过的用户渠道条为空——这与「渠道条=用户自己的分组」语义一致。
- 真机侧「渠道条 chip 数量回落」的实机验证随批末部署一起看（App 重启后）。
