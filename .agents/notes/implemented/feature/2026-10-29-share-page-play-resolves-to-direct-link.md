# Agent Note: 分享页当剧集 —— 补上"解析成直链"那一跳（含临时转存的清理）

Status: implemented

Independent: 与 `2026-10-28-share-link-play-via-item-id.md` 是**同一条用户链路的两端**：
那条解决"**网盘源**里的分享货架条目"（id 里编 share 上下文）；
本条解决"**普通 csp 源把分享页 URL 当剧集交回来**"（4K指南/咕咕/魔术/搜盘 那一类）。
两条共用 `PanDrive` 的取数实现，但入口与 id 协议不同 —— 前者改 id，后者在 provider 层兜底。

## Problem

Owner 现场（真机 + 真登录态）：`冰雪奇缘` · 线路「夸克网盘（分享页）」点开报
**"这个格式解不了 / Failed to recognize file format"**。

原因：`csp-4k-zhinan` 这类源的 `play()` 只能把**分享页 URL** 原样交回
（`https://pan.quark.cn/s/<id>`），播放器拿到的不是媒体流。

补齐后连撞四个真实拦路石（全部真网读数，逐条修）：

```text
① `{"status":402,"code":"41020","message":"转存文件token校验异常"}`
   ⇒ `share_fid_token` 与**换出它的那次 stoken** 是一对；我先用 A 次的 token 配 B 次的 stoken 去 save。
② 转存成功却取不到 fid：真响应是 `status:2` + `save_as.save_as_top_fids:["d540a0a8…"]`（**数组**），
   我先找的是 `save_as.top_fid`（单数）⇒ 30 秒空转后超时。
③ 轮询窗口 9 秒太短（真分享转存要几秒到十几秒）。
④ 最后一步服务端回 `{"status":400,"code":23018,"message":"download file size limit"}`：
   那个分享里只有一个 **64.4GB 的 .iso**，超出夸克给该账号的单文件下载上限
   —— 这是**内容本身的边界**，不是解析错。
```

## Decision

```text
① `csp/pan_share_play.rs`：纯函数 `parse_share_page(url)` 识别
   `pan.quark.cn/s/<id>`、`drive.uc.cn/s/<id>`（含 `?pwd=`），域名**精确匹配**；
② `CspProvider::resolve` 里对每条 play 结果做一次兜底：认出分享页就交给
   `PanDrive::resolve_share_play`，认不出**原样返回**（不许把能播的直链吞掉）；
③ `resolve_share_play`：purge 上一次的临时转存 → 列目录挑文件 → 转存 → 取直链；
④ `share_save` 用 `refresh_fid_token` 返回的 **(stoken, token) 一对**；
⑤ 任务轮询 30 秒，成功态取 `save_as_top_fids[0]`，超时错误里带**最后一次响应**。
```

### 关于"播一次存一次、不复用不删除吗"（Owner 的提问）

```text
dex 实证：参考实现有 `QuarkTempDelete` / `UCTempDelete` + `file/delete`，
请求体 `{"action_type":2,"filelist":["<fid>"],"exclude_fids":[]}`（2 = 移入回收站）。
⇒ 原版是**每次播放转存一份（不复用）、播完删掉**；不是"永久囤"。
我们此前只做了转存、从不清理 ⇒ 用户网盘里会堆。
现在：每次解析前清掉**上一次**的（`purge_previous`），并把这一次的 fid 记进内存表；
不在播放中途删（直链绑 fid，删了会断流）。
```

## Alternatives considered

### A. 把分享页也编进条目 id（与 `2026-10-28-share-link-play-via-item-id.md` 一致的形状）

**最强理由**：一条协议走到底，`list`/`play` 都能解，概念最少。

**否掉的原因**：这些源（`zhinan`/`gui_gui`/`hd_moli`/`pan_sou`…）的 episode id **就是 URL 本身**，
是它们与上游站的契约；改成自造编码要**改十几个源的解析层**，而每个源的 URL 形态还不一样。
在 `CspProvider::resolve` 这一个出口兜底，只改一处、且对所有源同时生效。

### B. 复用已转存的文件（先查我网盘里有没有同名/同 fid）

**最强理由**：省空间、省一次转存、二次播放更快。

**否掉的原因**：原版**不复用**（`Temp` 语义 + 每次播放一份），且复用会带来"同名不同版本"的误判风险
（同一部剧的 1080p/4K 同名不同 fid）。等真出现"用户抱怨重复转存"再谈复用，并要按 fid+size 精确匹配。

### C. 播完立刻删（接播放器结束事件）

**最强理由**：与原版行为最接近，网盘最干净。

**否掉的原因（本轮）**：结束事件在 Dart 播放器层，要在播放器 `dispose`/`stop` 时回调一次 FFI；
本轮的改动面已经横跨 Rust 取流层，再把播放器生命周期接进来风险偏高。
⇒ 现在用"下一次解析前清理"（每个盘最多留 1 份），并把它写成显式边界；
真正"播完即删"留给播放器侧那一跳（已记在 Consequences）。

### D. 对超限文件（23018）自动降级到"转码播放/预览接口"

**最强理由**：64GB ISO 这类内容用户点了就想看。

**否掉的原因**：夸克的预览/转码接口**没有取证**（不在 `r3c-pan-dexstrings.log` 的端点表里），
凭空接一个猜测的端点只会把"明确的超限提示"换成"莫名其妙的失败"。先把真实原因摊给用户。

## Consequences

**收益**

- 「夸克网盘（分享页）」这类线路从"格式解不了"变成**能真的解析出直链**（真网验证到取直链那一步）。
- 分享页识别是纯函数（域名精确匹配），别的盘（百度/115/阿里…）返回 `None`，不会被误当分享页。
- 临时转存有了清理边界：每盘最多留 1 份，且删的是**移入回收站**（可恢复）。
- 三个真 bug（token 配对 / save_as 数组 / 轮询窗口）都有真读数支撑，不是猜。

**代价与边界**

- 临时文件落在**网盘根目录**（原版大概是专用临时目录）；建目录要先取证 `file/mkdir` 参数，本轮没做。
- "播完即删"没做（见 Alternatives C）：现在是"下次解析前清"。
- 超限文件（`23018`）如实报错，不做转码兜底。
- 未登录 ⇒ `NEED_LOGIN:<盘种>|…`（UI 弹二维码），不是"文件不存在"。

## 验证结果（已发生）

```text
真网络（本机钥匙串里的夸克登录态，`cargo test --lib quark_share_live*  -- --ignored --nocapture`）：
  ① 列目录：`分享 6c3812f483a6 根目录 1 条：… .iso dir=false size=64465338368 token_len=32`
  ② 修 token 配对前：`403 / 41020 转存文件token校验异常`（复现两次）
  ③ 修 save_as 解析前：`转存任务 30 秒未完成 … {"status":2,"save_as":{"save_as_top_fids":["d540a0a8…"]}}`
  ④ 修完之后：走到 `file/download`，服务端回 `400 / 23018 download file size limit`（该分享是 64GB ISO）
单元门禁（`cargo test --lib csp::pan_drive --release` → 33 passed）：
  parse_share_page 正反例（含 `quark.cn.evil.com` 必须拒）、passcode 解析、
  `temp_cleanup_matches_the_reference`（URL + body 逐字）、`video_name_detection_is_narrow`
故障注入（已实测真红）：
  把 `file_delete_body` 的 `action_type` 从 2 改成 1 ⇒ `temp_cleanup_matches_the_reference` FAILED
```

## Relations

- 同链路另一端（网盘源货架）：[./2026-10-28-share-link-play-via-item-id.md](./2026-10-28-share-link-play-via-item-id.md)
- 取直链与 `__puus`：
  [../bug-fix/2026-10-28-quark-play-needs-puus-from-response-header.md](../bug-fix/2026-10-28-quark-play-needs-puus-from-response-header.md)