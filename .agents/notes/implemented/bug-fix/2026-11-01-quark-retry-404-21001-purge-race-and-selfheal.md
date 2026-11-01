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
- **B · 21001 单次自愈**：`degrade_attempt` 下载遇 21001 ⇒ 落 AppLog
  （`applog::write_file_log`，不是 `log::*`——[本仓 log 门面无 PAN sink](2026-10-30-applog-file-log-writer.md)）
  → `wait_fid_gone`（轮询临时目录清单直到旧 fid 消失，预算
  `SELFHEAL_LISTING_WAIT = 5s`，等的是回收站/索引最终一致性）→ 重新转存**一次**
  （删除已落地 ⇒ 必新建副本 ⇒ 新 fid）→ 再取直链；仍 21001 ⇒ 如实终态。
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

must：purge 等待必须有预算封顶；自愈只做一次（防循环）且仅限分享转存 fid
（裸 fid 的 21001 是用户网盘文件真没了，不走自愈，`play` 直接终态）；
自愈动作必须落 AppLog。

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
- **自愈做多轮重试（轮询到删除落地为止）**：最强理由是能扛最慢的回收站。
  被否（Owner/lead 批复：只做一次）：多轮重试 = 每轮都真打网盘，风控风险
  与 resolve 时长都不可控；5s 预算 + 单次自愈已经把可救的都救了，
  救不了的如实终态比无限打转诚实。
- **把 file/delete 改成同步语义（action_type=1 真删）**：未真跑通且删除语义
  更危险（1 = 真删，删错找不回；2 = 回收站可恢复）。不动。

## Consequences

- 收益：重试不再必现 404(21001)——竞态被两层兜住（A 消根因、B 兜残余）；
  21001 有了人话终态与正确归属（不再误导用户去登录）；跨两天 4+ 次复发的
  同一症状被门禁钉死（判据正负样例 + 接线断言 + 注入证红 + env 门控 live probe）。
- 代价：①每次 resolve 的 purge 最多多等 5s（多数情况删除秒级完成，实际增量
  接近 0；超时走原速 + B 兜底）；②自愈路径最多多一次转存 + 一次下载
  （只在该罕见错误发生时）；③`shareFileGone` 新档让 headline/nextStep/ownerOf
  三处 switch 与 t1057 期望表多一行——将来加档位必须四处同步。
- 验证缺口：live probe 未在写笔记时执行（真分享 pwd_id 被日志脱敏截断拿不到，
  远端 bundle 也取不到）——真机复测时 lead 用 Owner 的分享链接设
  `SOURIN_LIVE_SHARE_URL` 跑 `live_21001_retry_race_probe` 补端到端实证；
  单测/接线/证红已全绿。
- 登录按钮（报障另一半）：现行 `_isAuthError` 判据对 21001 文本判 false
  （Dart 门禁钉死），真机截图的按钮来自旧构建缺 T9 的陈旧 loginKind 清理，
  换新构建复验即可，不在本批修。

相关：[夸克 23018 降级重试](2026-10-30-quark-23018-pick-degrade.md)（本修复建立在
它的候选降级策略上，23018 语义未动）、
[分享页解析直链（含临时转存清理）](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md)
（purge 的出生地，本篇修订其"best-effort 不等待"的时序）、
[applog 文件日志](2026-10-30-applog-file-log-writer.md)（PAN 日志唯一 sink）。
