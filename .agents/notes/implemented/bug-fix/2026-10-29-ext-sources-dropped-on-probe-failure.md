# Agent Note: 探测一失败就把整个源连同 ext 丢掉 —— 5 个 App 源因此永远"缺配置"

Status: implemented

Independent: 与 `2026-10-29-restore-auto-disabled-sources.md`（停用名单）不同：
那篇修的是"源被关掉"，本篇修的是"源被**丢弃**"（连配置都没落盘）。
也不改任何站点解析逻辑（`csp/app99.rs` 等一行未动）。

## Problem

「全部」里有 5 个源长期报 `ext 里缺 dataKey / 缺 url / 缺 site`：

```text
csp-app99, csp-app-get, csp-app-rj, csp-hj-zhen-cai, csp-wogg
```

而 o**同样的 id 在原始订阅里明明有 ext**（`.probe/ref-subscription.json`：100 个站点、41 个带 ext）。

## 真读数（先推翻自己的假设）

真片段（逐字抄自订阅）走**真导入**后 4/5 完整落盘、还探到了真分类：

```text
[EXT-DIAG] 导入 "csp-wogg-1c0d2c03"      | "csp_Wogg"     | 分类=8 | 落盘=true
[EXT-DIAG] 导入 "csp-hjzhencai-f466f12d" | "csp_HJZhenCai"| 分类=7 | 落盘=true
[EXT-DIAG] 导入 "csp-apprj-76c56338"     | "csp_AppRJ"    | 分类=5 | 落盘=true
[EXT-DIAG] 导入 "csp-appget-97d9adc9"    | "csp_AppGet"   | 分类=6 | 落盘=true
落盘 csp_Wogg extLen=107 可解析=true（site/url/dataKey 键都在）
```

⇒ **导入链路本身不丢 ext**（`collect_sites` → `csp::ext_text` → `SiteJob.ext` → `to_persist` 全程原样透传）。

真正的丢失点：

```text
tvbox.rs:1919-1927（导入）  Some(Err(reason)) => { skipped.push(..); continue; }
tvbox.rs:2953-2960（检测更新）同一份拷贝 —— 点一次「更新」再丢一次
```

即：**探测（home）失败 ⇒ 整条 `continue`**，带 ext 的 csp 源连配置一起消失；
随后 `state.rs` 的 builtin 空 ext 占位顶替它出场，于是报"缺配置"——**报错指向的键明明是有的**。
用户数据目录里这 5 条从没落过盘，最可能是 10/26 那次导入时这些类还没实现（进 skipped，永不复导）。

## Decision

```text
新增唯一判据 `keep_ext_on_probe_failure(job)`：`csp 类 && ext 非空` ⇒ 探测失败**照样落盘**
（ext 就是它的全部配置）。苹果CMS 不套用（api 死了就是死了，留着只是噪声）。
两条路径（导入 / 检测更新）共用这一个判据，报告行加 `probeFailed` + `extLen`，
且**不许同时进 skipped**（两个列表语义分裂会让"导入成功又被列为跳过"）。
```

真网络结果（同一份二进制、独立数据目录导入真片段后搜「老舅」）：

```text
csp-wogg-1c0d2c03       3 条
csp-hjzhencai-f466f12d  2 条
csp-appget-97d9adc9     7 条
csp-apprj-76c56338      1 条
csp-app99-9ad89e1c      错：登录态不可用（userInfo 未给 user_token）  ← ext 补回来了，但上游要登录
csp-appdrama-* ×3       错：Unsupported（该类自声明不支持搜索）
导出报告：imported=9 skipped=0（修前 4/5，App99/AppDrama 全被丢）
```

## Alternatives considered

### A. 在 `state.rs` 里做"回溯补 ext"（启动时按订阅文件补）

**最强理由**：用户不必手动点「检测更新」。

**否掉的原因**：那要求启动时**再下载/再解析订阅**，把网络依赖塞进冷启动路径，
且"哪份订阅是当前真相"没有可靠来源（用户可能换过订阅）。修在导入/更新这两条**用户意图明确**的路径上更干净。

### B. 探测失败时保留**所有**站点（不区分 csp/苹果CMS）

**最强理由**：规则更简单，一行判断。

**否掉的原因**：苹果CMS 源的 ext 只是 `api` 地址，探测失败（api 死了）留着它只会让"全部"里多一个永远报错的源。
判据按"ext 是否就是它的全部配置"区分，才是最小充分条件。门禁里专门放了**阴性对照**（死接口的苹果CMS 必须仍被丢弃）。

### C. 把 app99 也当"已修"报出去

**最强理由**：数字好看（5/5 全绿）。

**否掉的原因**：`app99` 补回 ext 后仍报「登录态不可用（userInfo 未给 user_token）」——上游匿名登录就拒。
ext 补不回登录态。⇒ 如实标"需登录"，并在交付里说明。

## Consequences

**收益**

- 5 个 App 源不再"配置凭空消失"；其中 4 个**立刻能搜到结果**（3/2/7/1 条，真网）。
- 导入/更新两条路径共用同一判据与同一份报告字段（`probeFailed`/`extLen`），不会再"修一条漏一条"。
- 门禁用**真片段 + 真导入**（离线确定性：ext 指向 `127.0.0.1:1` 闭合端口），并带苹果CMS 阴性对照。

**代价与边界**

- **已有数据目录不会自动回溯**：那 5 条仍是 builtin 空 ext 占位，需要对订阅点一次「检测更新」或重导。
- `app99` 仍不可用（需登录态）；`app-drama` 类自声明不支持搜索。

## 验证结果（已发生）

```text
cargo test --lib tvbox --release → 94 passed / 0 failed / 9 ignored（我自己复跑过）
新增门禁（mod t_ext_import）：
  real_ext_fragment_passes_through_collect_sites   （真片段 · 纯离线 · 值相等）
  probe_failure_still_persists_ext_csp_source      （真导入 + 苹果CMS 阴性对照）
  update_path_also_keeps_ext_on_probe_failure      （真 update 流程）
故障注入（已实测真红）：keep_ext_on_probe_failure → false
  ⇒ probe_failure_still_persists_ext_csp_source FAILED（报告里 imported=[]、两条都进 skipped）
真网：见上面的 3/2/7/1 条与 imported=9 skipped=0
```

## Relations

- 源数口径（谁参与搜索）：[../feature/2026-10-29-restore-auto-disabled-sources.md](../feature/2026-10-29-restore-auto-disabled-sources.md)
- 同批另一类"源坏"的定性：[./2026-10-29-five-failing-sources-triage.md](./2026-10-29-five-failing-sources-triage.md)

The [AppDrama public protocol](../feature/2026-11-11-app-drama-public-protocol.md)
replaces that class's fixed unsupported implementation while preserving this
routing/configuration contract. Real-service playback remains separately verified.
