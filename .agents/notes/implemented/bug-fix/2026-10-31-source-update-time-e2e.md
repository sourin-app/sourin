# Agent Note: 源"上次更新时间"端到端落地 —— 补归属、聚合下发、修两处漏网

Status: implemented

Applies to current source metadata and the inline subscription panel as of 2026-11-07.

Independent: 接续 [2026-10-31-tvbox-source-update-time.md](../feature/2026-10-31-tvbox-source-update-time.md)
（那一篇加了字段、接了 UI、起了定时器，但真机判读发现**用户一行都看不到**——
本篇是它的端到端收尾）。

[Exact parent refresh](2026-11-11-tvbox-origin-refresh-identity.md) extends the
manual entry to zero-VOD parents and limits stamps to resolved owned VOD IDs.
The aggregate display and link-state/save ownership decisions here remain.

## Problem

真机判读（ui-judge-batch）：设置→源 的 TVBox 卡片**没有**"上次更新"行，
聚合二级页管理面板同样没有。lead 复核根因后比判读更深两层：

L1 —— 聚合源 `tvbox_agg` 是 Rust **内置 provider**（state.rs:421 bootstrap 里
`registry.register(TvboxAggregate::new(..))`），不是 `PersistedProvider::Tvbox`，
故不在 `state.third_party` ⇒ `local_tvbox_sources()` 挑不到 ⇒ `list_tvbox_sources`
的 `sources[]` 里没有这一条 ⇒ Dart 侧 `_tvboxSources['tvbox_agg'] == null`
⇒ `tvboxLastUpdateText(null)` 返回 null ⇒ 整行不画。且**没有任何路径会给它盖章**。
L2 —— sidecar 里 64 条子站**全部 `source_url=None`**（该字段带
`skip_serializing_if`，None 就不落盘；全仓只有"输入是 http 且不是 `{` 开头"时才赋值）
⇒ 这 64 条是**粘贴配置文本**导入的，不是填链接导入的 ⇒ `collect_due_links`
第一道 `m.source_url ... else continue` 就把它们全跳过 ⇒ 定时循环每 60s 醒来
却什么都不做 ⇒ 从不下载 ⇒ 从不盖章。

L3 —— 内嵌管理面板保存或清空链接后，只更新按钮使用的 `_hasLink`，
更新时间行仍读取父组件打开弹窗时传入的 `needsSource`。因此保存成功后仍提示
缺链接，清空后仍显示旧更新时间；这在原生弹窗截图中可直接观察到。

## Decision

```text
① 聚合源真实时间：新增纯函数 tvbox_aggregate_last_update(metas, child_ids)
   —— 取其子站 last_update_at 的 max（问"上次更新"＝最近一次真核对过；
      用 min 会被一条老源把整个聚合拖旧＝误导）；ok = 所有已盖章子站都 ok
      （任一失败即标失败，保证"定时一直失败必须看得见"）；
   list_tvbox_sources 顶层新增 aggregate 字段下发，★不塞进 sources[]
      （塞进去会让聚合卡片多出"检测更新"按钮，点了必然报找不到源）。
② 子站归属：文本导入如实留 None（不编来源）。但**不许静默**——
   缺链接的源文案必须说清"这条是配置文本导入、没有订阅链接 ⇒ 无法定时更新"，
   并指出可去聚合页补充链接（TvboxAggregateLinkDialog）。
③ 链接导入盖初始章：链接导入且确实下载安装成功 ⇒ last_update_at = installed_at
   = now（真实时刻）；文本导入仍不盖（无可核对链接）。
④ P3-2：新增 norm_source_url()（trim 归一），stamp 匹配 / in_link 判定 /
   collect_due_links 去重传值三处统一，且写入时就存 trim 后值。
⑤ P2-2：在最底层加 std::sync::Mutex（save/write/forget 内部持锁）
   ⇒ import / set / remove / restore / update 五条路径一次性覆盖。
⑥ 内嵌管理面板以已成功保存的链接状态覆盖旧 metadata 的 needsSource，
   同步更新时间行、颜色和 Tooltip。输入未保存或保存失败时维持已确认状态。
   保存链接不伪造更新时间，也不把连通检测当作订阅更新成功。
```

## Alternatives considered

- **只把 null 判空改成"从未更新"兜底**：等于永远显示从未更新＝没修（聚合源压根
  没有记录可盖）。否决。
- **聚合口径用 min**：被一条老源拖旧，是误导。否决（用 max）。
- **给文本导入的源编造来源链接**：配置文本里没有来源信息，编就是假。否决。
- **逐个给五条写路径加 tokio 锁**：重复且易漏；底层一把 std 锁全覆盖。否决。

## Consequences

- `t20261107_subscription_link_status_test.dart` 驱动真实保存/清空按钮并读取
  渲染的状态行、颜色与 Tooltip，覆盖保存成功、清空成功、未保存输入、
  保存失败、清空失败及已有更新时间保留；命令用隔离替身。

- 门禁：Rust 6 条（含**真形状 64 条夹具**的 `t5_existing_sub_sites_all_stamped`
  ——断言一次更新后 64 条既有子站一条不落全有章，只有 1~2 条就说明章只盖了
  added/changed）；Dart 25/25；相关 Dart 58/58；cargo 1984/0（基线 1978 + 新增 6）。
- 证红 8 处、逐处单独注入单独恢复：Rust 5（聚合恒 None / stamp 不盖章 / 匹配改回
  原样 / 去写锁 / 导入恒 0）+ Dart 3（去掉 needsSource 分支 / 不解析 aggregate /
  注释掉接线）。
- **过程中抓到自己门禁的洞**：接线门禁原用 `contains`，把代码注释掉照样匹配
  ⇒ 注入后居然绿。已改成"按行 trim 后排除 // 开头再比"⇒ 重跑注入⇒红。
  （同期还修了 3 处"不可能的旧夹具"：凡"已更新过"的源都没给 sourceUrl——
  现实里章是核对链接的产物，没链接的源永远不会有章。）
- **额外发现并修的非任务内缺陷**：Rust 顶层 aggregate 初版没下发 `needsSource`，
  而 Dart 缺省是 true ⇒ 聚合源会被判成"没有订阅链接"⇒ 显示"去补链接"，
  而它的时间来自子站、补不了——把"不适用"说成"配置缺失"。已显式下发 false
  并加双向门禁。
- 口径更正一处（如实）：初版断言磁盘上"不应出现 lastUpdateAt 键"是错的
  （该字段没有 skip_serializing_if），改为断言"值全为 0"，语义等价。

## 边界（如实）

- 文本导入的存量 64 条，需用户在聚合页补链接后，下一次更新才会盖章（路径已存在）。
- 本批未做真机验证（按分工由 lead 在批末统一部署后验收 + 截图取证）。
