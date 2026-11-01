# Agent Note: 夸克重试必现 404(21001) —— purge 异步删除与 save 去重的竞态（等终态 + 单次自愈）

Status: implemented

## Problem

Owner 真机报障（2026-11-01，截图 + 日志）：夸克分享线第一次解析报 23018
「download file size limit」（账号非会员单文件下载上限，账号现实，归因正确），
按「重试」后错误变成 `取下载地址返回 HTTP 404 Not Found: {"code":21001,"message":"file not found",…}`，
且错误卡上挂着与登录无关的「登录」按钮（Owner 夸克已登录）。

日志实锤（sourin-2026-11-01.log）：

```text
14:39:13  file/download → 400 code=23018 file size limit[e2d3230f…]
14:39:40  file/download → 404 {"code":21001,"message":"file not found [e2d3230f…]"}
```

同一个 fid 27 秒内从「存在但超限」变成「不存在」。且这不是孤例——
10-31 日志里 csp-qu-pan-so 源同一模式已复发 3 次（11:51:35 / 11:52:22 / 11:53:09，
每次 404 的 fid 都逐字等于上一次 resolve 首候选的 fid），跨两天、跨两源、重试必现。

根因（我们的 bug，不是分享失效）：

```text
resolve_share_play 开头 purge_previous() 把上一次解析转存的临时文件删掉
（[pick-degrade 篇](2026-10-30-quark-23018-pick-degrade.md) 的纪律：
失败尝试也 remember_temp ⇒ 上次 23018 失败的 fid 在账本里）。
但 file/delete 是**异步任务**（action_type=2 移入回收站），旧实现只确认
HTTP 请求成功就走；随后的 sharepage/save 对同名文件**去重**，回吐了
"刚删/正在删"的同一个 fid ⇒ 紧接着 file/download 404(21001)。
重试链本身是全链重走（每次现换 stoken、现转存），没有旧令牌/参数复用。
```

## Decision

修复 = A（消竞态根因）+ B（兜残余）+ 分类终态，三层按序兜住
（[direct-link 篇](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md) 的
purge 时序语义由本篇修订）：

- **A · purge 等删除落地**：`purge_previous` 的 file/delete 响应带 `task_id` 就轮询
  `task?` 到终态（`delete_task_done`：status=2 成功 / 3 失败），总预算
  `PURGE_DELETE_WAIT_BUDGET = 5s`（lead 护栏：不许无限挂住 resolve）；
  响应没有 task_id（同步删除形态）则记一笔视为已生效，**不猜协议**；
  超时/形态认不出 ⇒ warn 后继续走，残余竞态交给 B。
- **B · 21001 自愈（v2，同日真机缺口后升级）**：`degrade_attempt` 下载遇 21001 ⇒
  落 AppLog（`applog::write_file_log`，不是 `log::*`——[本仓 log 门面无 PAN sink](2026-10-30-applog-file-log-writer.md)）
  → **有界自愈循环**（v1 的"单次重转存"被部署版真机否决，见 Alternatives）：
  每次重转存**验证 save 回吐的 fid ≠ 死 fid**，相同（去重回吐）⇒ 升级下一档：
  第 2 次转存 = 同目录等退避（`wait_fid_gone` + 2s）；第 3 次转存 =
  **一次性子目录**（sourin-temp 下 `retry-<ts>-<seq>`，确定性躲开同名目录内去重）；
  预算：重转存 ≤ `SELFHEAL_RESAVE_ATTEMPTS=2` 次、总预算 `SELFHEAL_TOTAL_BUDGET=40s`、
  退避 `SELFHEAL_BACKOFF_BASE×n`（2s→4s）。子目录 fid 也进记账，
  purge 改 **LIFO**（先删文件再删其目录，别只建不清）。
- **21001 终态人话（v2 分两态）**：`play` 的 HTTP 错误分支用 `is_file_not_found_21001`
  （双特征：`21001` + `file not found`，裸 404 / 单特征不误伤）识别。
  穷尽后按末次转存是否被去重回吐分两态：
  **去重卡住**（末次 save 仍回吐死 fid）⇒「临时转存副本被网盘同名去重卡住…
  分享的文件还在，稍后重试通常可恢复，或换一条线路」——**可重试**语义
  （真机缺口：v1 笼统报"文件已不存在"对这一态是假话）；
  **真不存在**（拿到新 fid 仍 21001 / 用户网盘文件没了）⇒「文件已不存在…
  换一条线路」——不可重试。
- **21001 终态人话**：`play` 的 HTTP 错误分支用 `is_file_not_found_21001`
  （双特征：`21001` + `file not found`，裸 404 / 单特征不误伤）识别，
  报「文件已不存在（code=21001 file not found），无法播放，请换一条线路」。
- **Dart 分类第八档 `shareFileGone`**：headline「分享的这个文件已不存在」/
  nextStep「换一条线路试试（右上角的线路列表）。」/ canRetry=false
  （与 23018 同类：文件属性/存在性问题，重试无出路）/ ownerOf ⇒ unknown
  （permission 同款"不冒认"纪律：插件只是如实转述，不冤枉任何一方）。
  classify 规则放在 HTTP 状态归因**之前**——否则 404 会被既有 source 档
  截走并给 canRetry=true。与登录的边界：登录误判只由 msg 含
  login/登录/未授权 触发，"file not found" 不命中（真机实测 Owner 已登录仍复现）。
- **顺手修**：purge 段落的日志从 `log::info/warn` 换成 `applog::write_file_log`
  —— `log` 门面在本 crate 无 [PAN] sink，原 purge 日志实际全被丢弃
  （23018 猎捕二轮实锤过的黑洞类别）。
- **live probe**：`live_21001_retry_race_probe`（env 门控
  `SOURIN_LIVE_21001=1 SOURIN_LIVE_SHARE_URL=<分享链接>`，跟随
  `live_temp_dir` 先例），判据 = 重试错误串里不许再出现 21001。

must：purge 等待必须有预算封顶；自愈**有界**（重转存 ≤2 次、总预算 40s、
退避 2s→4s，防循环）且仅限分享转存 fid（裸 fid 的 21001 是用户网盘文件真没了，
不走自愈，`play` 直接终态）；每次重转存必须验证 **fid ≠ 死 fid**；末次升级换
一次性子目录且目录必须进记账（purge LIFO 清掉，别只建不清）；自愈动作必须落
AppLog；穷尽终态**分两态**（去重卡住=可重试 / 真不存在=不可重试），不许笼统。

## Alternatives considered

- **只改 Dart 分类（把 404 归"文件已不存在"）、不动竞态**：最强理由是零风险、
  纯文案。被否：那只是把"重试必现 404"糊上一层好看的话——**竞态还在**，
  重试永远失败，用户被 canRetry=false 堵死在原地；且 Rust 终态文案必须有人
  生成，Dart 单改反而让错误串里仍是生 JSON。分类是终态表达，不是修复。
- **purge 整体去掉（转存文件常驻、播完才删）**：最强理由是彻底没有删除竞态。
  被否：与 [direct-link 篇](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md)
  定下的清理边界冲突——不 purge 则网盘堆垃圾（Owner 原话：「这些网盘我都还要用，
  都放在根目录我就没办法用了」），且参考实现的 `QuarkTempDelete` 语义就是播完即清。
  若将来做"复用同一转存"（同分享同文件直接跳过 save），再回来重审这一条。
- **自愈 v1 的"单次重转存"（已被部署版真机否决，升级为 v2 有界循环）**：
  v1 假设"等清单消失后重转存必新建副本"——真机实测推翻：夸克 save 的同名
  去重作用域**不止活跃目录清单**（回收站/内容秒传级），wait_fid_gone 通过后
  重转存仍回吐同一个死 fid ⇒ 下载还是 21001，且 v1 终态笼统报"文件已不存在"
  对这一态是假话（分享的文件明明还在）。v2 保留其合理内核（等退避对
  "删除落地慢"有效），升级为"验证 fid ≠ 死 fid + 末次换一次性子目录 +
  两态终态"；多轮**无界**轮询仍然被否（风控风险与 resolve 时长不可控）。
- **把 file/delete 改成同步语义（action_type=1 真删）**：未真跑通且删除语义
  更危险（1 = 真删，删错找不回；2 = 回收站可恢复）。不动。

## Consequences

- 收益：重试不再必现 404(21001)——竞态被三层兜住（A 消根因、B v2 有界自愈
  兜残余、两态终态如实分层）；21001 有了人话终态与正确归属（不再误导用户去
  登录）；跨两天 4+ 次复发的同一症状被门禁钉死（判据正负样例 + 接线断言 +
  注入证红 + 假网盘夹具回放 + env 门控 live probe）。
- 代价：①每次 resolve 的 purge 最多多等 5s（多数情况删除秒级完成，实际增量
  接近 0；超时走原速 + B 兜底）；②自愈路径最多多两次转存 + 两次下载，且
  第 3 档会短暂多一个 retry- 子目录（进记账，下次解析 LIFO 清掉；只在 21001
  罕见路径发生）；③`shareFileGone`/`tempCopyStuck` 两档让 headline/nextStep/
  ownerOf 三处 switch 与 t1057 期望表各多一行——将来加档位必须四处同步。
- 验证缺口（v1 时申报、v2 已补齐的部分）：真分享 pwd_id 被日志脱敏截断拿不到
  ⇒ live probe 仍未执行；但 v2 的假网盘夹具（本地 TCP 回放"save 恒回吐死 fid"
  与"第二次回吐新 fid"全链路）已把竞态与自愈机制端到端钉死；真机复测时 lead
  用 Owner 的分享链接设 `SOURIN_LIVE_SHARE_URL` 跑 `live_21001_retry_race_probe`
  补最后一环。
- 登录按钮（报障另一半）：现行 `_isAuthError` 判据对 21001 文本判 false
  （Dart 门禁钉死），真机截图的按钮来自旧构建缺 T9 的陈旧 loginKind 清理，
  换新构建复验即可，不在本批修。

相关：[夸克 23018 降级重试](2026-10-30-quark-23018-pick-degrade.md)（本修复建立在
它的候选降级策略上，23018 语义未动）、
[分享页解析直链（含临时转存清理）](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md)
（purge 的出生地，本篇修订其"best-effort 不等待"的时序）、
[applog 文件日志](2026-10-30-applog-file-log-writer.md)（PAN 日志唯一 sink）。
