# Agent Note: 网盘转存落到专用目录 sourin-temp —— 不再把用户网盘根目录塞满

Status: implemented

Independent: 与 `2026-10-29-share-page-play-resolves-to-direct-link.md`（同一条取流链路的**目标目录**）不同：
那篇解决"能不能播"，本篇解决"播的时候把文件放到哪儿、怎么清"。
不动解析、不动清理协议（`file/delete` + `action_type:2` 原样保留）。

## Problem

Owner：「如果是网盘播放，都放到一个目录去，不要都放在根目录，这些网盘我都还要用，都放在根目录我就没办法用了」。

原实现 `share_save` 的 `to_pdir_fid` / `pdir_fid` 都写死 `"0"`（= 根目录）⇒
每播一条分享就在**用户网盘根目录**里多一个转存文件，与他自己整理的目录混在一起。

## 真读数（端点先纠错，再取证据）

```text
① 我最初以为的 `POST /1/clouddrive/file/mkdir` → **404 不存在**：
   {"status":404,"error":"Not Found","path":"/1/clouddrive/file/mkdir"}
② 真正的建目录端点（dex 逐字 + 真网可达）：
   POST https://drive-pc.quark.cn/1/clouddrive/file?pr=ucpro&fr=pc
   body {"pdir_fid":"0","file_name":"sourin-temp","dir_path":"","dir_init_lock":false}
   → 无 cookie：401 {"status":401,"code":31001,"message":"require login [guest]"}
   UC 同形：POST https://pc-api.uc.cn/1/clouddrive/file?pr=UCBrowser&fr=pc
   dex 侧：`merge.b.w.m` 常量里就有 `Quarktemp` + 失败字面量 `Quark_temp_folder_error`；
           UC `merge.b.B.m` 对应 `UCtemp` / `UC_temp_folder_error`。
③ 有登录态时（本机真跑）：临时目录建/复用成功
   [PAN-DIR] PanQuark 临时目录 sourin-temp fid=430959ded6c645a6bf9726d0403f5df2
   [PAN-DIR] PanQuark 根目录（含子目录）条目 11 个；其中 sourin-temp = Some(("430959de…", true))
   [PAN-DIR] PanQuark 第二次 ensure ⇒ fid=430959de…（幂等，没有多建）
```

### 中途抓到的**真缺陷**（差点变成"每启动一次多一个目录"）

```text
`list_dir_url` 是 `_fetch_sub_dirs=0`（照参考实现逐字，门禁还钉着它）⇒ **列不出目录条目**。
而 `ensure_temp_dir` 第一步就是"在根目录找同名目录"：
  用 list_dir 找 ⇒ 永远 None ⇒ 每次都新建。
真机第一次跑就是这条断言把我拦住：
  [PAN-DIR] 根目录条目 10 个；其中 sourin-temp = None   ← 刚建完却"看不见"
⇒ 新增 `list_dir_url_with_subdirs`（只把 `_fetch_sub_dirs` 改成 1，其余逐字不动）专供"找目录"；
  列货架/列分享仍走 `_fetch_sub_dirs=0`（门禁逐字断言那条 URL，不许动）。
```

## Decision

```text
· 目录名 `sourin-temp`：**不复用**原版的 `Quarktemp`/`UCtemp`（混用会让"我们没清掉的残留"
  和"原版客户端的"分不清）；也**不加设备后缀**（同账号多机共用一个目录，否则根目录会堆
  sourin-temp-abc / sourin-temp-def）。
· `ensure_temp_dir(cookie)`：进程内缓存 → 用 `list_dir_with_subdirs` 找同名目录 → 找不到才建
  → 建失败返回 Err（由调用方决定退回根目录）；缓存按盘种、实际端点和原 Cookie 的 SHA256 指纹分开，不保存原 Cookie。
· `share_save(..., to_pdir_fid)`：`to_pdir_fid` **和** `pdir_fid` 都用它 —— 不再是 "0"。
· 两个调用点（`play` 的分享分支、`resolve_share_play`）统一走 `save_into_temp_dir`：
  建目录失败 ⇒ `log::warn!` + 退回根目录（**不让播放整体失败**），错误文案追加
  「（临时目录不可用，已退回根目录：<原因>）」。
· 清理：沿用 `file/delete` + `action_type:2`，日志改成「已从 sourin-temp 清理…」。
```

缓存与清理使用精确会话；资源归属冲突使用更宽的盘种 + 实际端点 + fid 域。不同 owner 的同一资源不因 Cookie 轮换或重排变成可接管文件。无法证明账号相同时采取保守拒绝，可能拒绝不同账号恰好同 fid 的情况。owner/generation、盘种 mutation lock、LIFO 和删除失败留账仍有效。

一次转存操作在网络 await 前捕获 Cookie，后续下载、重试和操作内清理沿用该值；独立清理读取当前凭据一次，只处理匹配会话。无法确认会话的旧记录保留。24项本地合成session/operation/rotation回归通过；不据此声明真实云端播放或全局代理深层接线完成。[全局路由](../architecture/2026-11-09-csp-global-routing-retains-engine-recipes.md)是独立边界。

## Alternatives considered

### A. 复用原版的 `Quarktemp` / `UCtemp` 目录

**最强理由**：与原版行为一致，用户看着眼熟。

**否掉的原因**：那是原版客户端的目录，我们既不知道它的清理策略，也不该替它删东西；
混用会让"我们漏删的残留"和"原版自己放的"无法区分，排障时说不清。

### B. 每次播放建一个新目录（`sourin-temp-<时间戳>`）

**最强理由**：天然隔离，永不冲突。

**否掉的原因**：这正是 Owner 抱怨的形态——根目录会被一堆目录塞满。必须"一个账号一个目录 + 用完清理"。

### C. 建目录失败就让播放失败

**最强理由**：语义最"严格"：没有临时目录就不该往用户根目录扔东西。

**否掉的原因**：Owner 的核心诉求是"能播"，根目录只是"别堆"。
为了目录建不出来而让播放失败，是把次要目标凌驾于主目标；⇒ 退回根目录 + 明确告警，用户可在日志里看到原因。

## Consequences

**收益**

- 播放分享页时文件落在 `sourin-temp/`，用户自己的目录不再被污染；清理也在同一目录内。
- 临时目录**建一次、复用**（真机验证：两次 `ensure` 同一个 fid）。
- 端点纠错（`file/mkdir` 不存在 → `POST /clouddrive/file`）与 `_fetch_sub_dirs` 的坑都写进代码注释，
  后来人不会再踩。

**代价与边界**

- UC 分支的真网建目录**未验证**（本机钥匙串里只有夸克；UC 已登录的机器跑
  `SOURIN_LIVE_PAN_DIR=1 cargo test --lib live_temp_dir_created --release -- --ignored --nocapture` 即可补证）。
- 若用户手动删掉 `sourin-temp`，进程内缓存的 fid 会失效 ⇒ 下一次转存会报错并退回根目录（有 warn）。
- 其它网盘（百度/115/阿里/天翼等）**没有转存这一步**，不受影响。

## 验证结果（已发生）

```text
cargo test --lib csp::pan_drive --release → 39 passed / 0 failed（3 ignored = 真网）
门禁（新增）：
  temp_dir_name_is_ours_and_not_root        目录名/非根/不带分隔符，且 ≠ Quarktemp/UCtemp
  mkdir_request_matches_the_reference_dex  两家 URL 逐字 + 断言**不含 file/mkdir** + 请求体四键
  mkdir_fid_is_read_from_data_fid           只认 data.fid，取不到就空串（不编 fid）
  save_body_targets_temp_dir_not_root       to_pdir_fid 与 pdir_fid 都 == 临时 fid、≠ "0"
  temp_dir_or_root_falls_back_and_explains  **退回分支本身**（Err ⇒ ("0", Some(原因))；空 fid 也算失败）
真网（本机夸克登录态，SOURIN_LIVE_PAN_DIR=1）：
  建/复用 fid=430959de…；根目录（含子目录）能看到 sourin-temp=Some((fid,true))；第二次 ensure 同 fid
故障注入（已实测真红）：把 `to_pdir_fid`/`pdir_fid` 改回 `"0"` ⇒ `save_body_targets_temp_dir_not_root` FAILED
```

## Relations

- 取流链路（分享页 → 直链）：[./2026-10-29-share-page-play-resolves-to-direct-link.md](./2026-10-29-share-page-play-resolves-to-direct-link.md)
- 清理协议（原版行为取证）：同篇的 Alternatives C 段