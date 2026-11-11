# Agent Note: TVBox 订阅链接血缘修复 —— base64** 解包 + 存量无主子站验证型认领

Status: implemented

与 [2026-10-31-tvbox-source-update-time.md](../feature/2026-10-31-tvbox-source-update-time.md)
（上一批：盖章/定时更新基建）互补：那批把"有链接的源"的更新链路修通了，
本批处理的是"链接根本没记上"的存量数据 —— 64 条子站 sidecar 里 source_url=None，
`collect_due_links` 永远挑不到链接，基建全在却从不运转。

[Exact parent refresh](2026-11-11-tvbox-origin-refresh-identity.md) preserves
legacy sidecar-only refresh while preventing a row from borrowing a URL-backed
parent's backups or stamps. URL-less local owners remain eligible after saving a
sidecar address. The explicit validated-adoption and wrapper policies here remain.

## Problem

真机聚合源 tvbox_agg 实机显示「从未更新」。取证结论（三条实物证据）：

```text
① tvbox-sources.json 64 条全部只有 siteKey/siteName/api/installedAt 四键
  （无 source_url 键 = 文本导入的磁盘铁证），installedAt 同秒 1793268523
  （2026-10-29 18:08:43，与文件 mtime 吻合）⇒ 整批来自一次"文本分支"导入。
② 链接导入路径自首次提交就有 source_url 赋值，且当时运行版本（7c8b5f7）
  的判据与今天逐字一致 ⇒ 导入代码**从来没丢过字段**，不是导入 bug。
③ 真因在输入形态：https://8815.kstore.vip/tvbox/wmz 返回
  "\n" + "YmFzZTY0**" + base64(JSON)（YmFzZTY0 = base64("base64")）。
  fetch_config_text + parse_loose_json 对此零支持 ⇒ 当时填链接导入会直接
  报「配置不是合法 JSON」⇒ 上一批智能体被迫自行下载解码后**灌文本**导入，
  血缘就此断了。
```

附：logs 里零 TVBox 导入行不构成反证 —— 本 crate 从未初始化 logger，
`log::info` 全部丢弃（state.rs:813 的既往教训），日志文件只由三个直写器写。

## Decision

两件事（都在 `rust/sourin_core/src/tvbox.rs`）：

```text
① unwrap_tvbox_config_text：剥 base64** 混淆包裹。只认明确以
  `base64**` / `YmFzZTY0**` 开头的形态（绝不猜普通 JSON），循环解包、
  上限 3 层（该标记按设计可嵌套；上限防恶意套娃），base64 用
  csp::shared::b64_decode（仓内自带宽容实现，零新依赖）。
  落点 fetch_config_text 单点 ⇒ import / 检测更新 / 定时更新三条
  链接路径自动全覆盖。
② adopt_tvbox_orphans(url)：验证型认领 —— 下载该链接（走①解包）、
  按 diff_sites 同一把尺子配对（①site key 精确 ②归一化 api），
  只动 source_url=None 的条目；命中多少认领多少，unmatched 数量如实
  带出；一条都配不上 ⇒ Err 绝不盲写。认领只补 source_url，
  site_key/site_name/api/installed_at 原样保留，章不动（下一轮订阅
  更新 last≤0 ⇒ 到点 ⇒ 盖真章）。
```

## Alternatives considered

### A. 让 Owner/探针用链接重新导入一次（零新代码路径）

**最强理由**：`import_tvbox_config` 覆盖语义按 id 原地覆盖，还自带 B3
初始章。

**否掉的原因**：id 含名字成分，远端配置一旦改名 ⇒ 新 id ⇒ 新旧并存
（正是任务书里"重复导入不产生双份"要防的事故）；且要重联网探测 64 站。

### B. 逐条 set_tvbox_source 补链接（复用现成 FFI）

**最强理由**：一行新 Rust 代码都不用加。

**否掉的原因**：没有配对验证 —— 调用方无法证明"只给真属于这条链接的
源补"。数据目录里若混着其它文本导入的源，盲补会把别人的血缘写错。

### C. 直接改运行中 App 的 tvbox-sources.json

**最强理由**：sidecar 是 load→改→save 无内存常驻，外部写理论上能活。

**否掉的原因**：App 内存态的 third_party 清单仍是旧的，用户之后任何一次
import/remove/盖章都会把旧态写回覆盖；且绕开了 App 自己的写路径（无锁竞争）。
改为探针走 FFI + 批末顺序（停 App → adopt → 启 App）。

## Consequences

**收益**

- 链接导入/检测/定时更新三条路径从此能消化野外 base64** 形态 —— 正规路径
  走得通，"被迫文本粘贴"的土壤消失。
- 64 条存量子站与 Owner 指定链接重新关联：认领后第一次更新全部盖章，
  聚合卡显示真实「上次更新」。

**代价与边界**

- 真机数据迁移依赖批末顺序（停 App → 探针 adopt → 启 App），探针在
  `lib/t1100_tvbox_adopt_probe.dart`（参数化 dataDir + adopt 一次即退）。
- unwrap 只认两个标记形态（`base64**` / `YmFzZTY0**`）；野外若出现第三种
  混淆（AES 等带回密钥的）仍会报「不是合法 JSON」—— 不猜格式是刻意的，
  猜错比报错更糟。
- 认领不校验名字差异（名字变化留给后续订阅更新的 changed 分支处理）。

## Testing

`mod lineage_adopt`（6 条，全绿）：

```text
unwrap_strips_base64_marker_real_shape   真链接形状（\n+YmFzZTY0**+b64(JSON)）
unwrap_two_layers_ok_but_four_rejected   2 层 OK / 4 层清晰报错
unwrap_passes_plain_config_through_and_bad_b64_errors  普通配置原样放行 / 坏 b64 报错
adopt_then_update_stamps_all_orphans     认领→更新→既有子站全盖章→聚合 max
adopt_rejects_no_pair_and_bad_url        配不上 Err 且不写盘 / 空·非 http url Err
import_via_link_unwraps_base64_and_records_source_url  链接导入解包+血缘落盘+B3 初始章
```

注入证红（已实测真红、已还原）：

```text
① unwrap 改恒等 ⇒ 6/6 FAILED
② 认领配对判据置空 ⇒ adopt_then_update_stamps_all_orphans FAILED（红在 claimed==2）
```

全量回归：`cargo test --lib tvbox --release` → 117 passed / 0 failed / 9 ignored。
