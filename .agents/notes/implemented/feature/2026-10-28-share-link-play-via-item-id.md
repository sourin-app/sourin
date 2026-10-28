# Agent Note: 分享链接能播了 —— 分享上下文（shareId / fid / fidToken）必须编进条目 id

Status: implemented

Independent: 与本目录 `2026-10-28-quark-play-needs-puus-from-response-header.md` **同一条链路的下一段**，
但**不是**它的重复：那条接通的是"自己网盘里的文件"（裸 `fid` → `file/download` → 并 `__puus`），
本条接通的是"**别人分享里的文件**"（`sharepage/save` 转存 → 再走那条链）。
那条笔记的"已知边界：分享链接仍然不能播"正是本条要翻的那一页。

## Problem

Owner：「分享链接（夸克/UC 分享页）点开要能真的播」。真机日志（`.probe/live-run4.log`）：

```text
[PLAYER] open: kind=mp4 url=https://pan.quark.cn/s/6c3812f483a6
[PLAY] 起播失败：Failed to recognize file format.        ← "这个格式解不了"
```

根因是**协议断链**，不是播放器：

```text
分享里的文件**不能直接下**（CDN 只认自己网盘里的 fid）⇒ 必须三步：
  ① POST sharepage/token  {pwd_id, passcode}            → data.stoken
  ② POST sharepage/save   {fid_list, fid_token_list, …} → data.task_id
  ③ GET  task?task_id=…   轮询到 status=2               → data.save_as.top_fid
而 ② 需要**三样东西**：shareId / fid / `share_fid_token`。
`share_fid_token` 只出现在**列目录那一次的响应**里，之后拿不到 ⇒ 不编进 id 就等于丢掉。
旧实现 `list()` 给分享条目只发裸 `fid` ⇒ `play()` 拿不到 shareId/token
⇒ 只能把分享页当播放地址吐出去 ⇒ 播放器报"格式解不了"。
```

## Decision

把分享上下文编进**条目 id**，并让 `list` / `play` 共用一对编解码函数：

```text
自己网盘   目录 → `<货架下标>:<fid>`        文件 → `<fid>`
分享货架   目录/文件 → `share:<shareId>:<fid>:<fidToken>`
```

四条具体决定：

1. **编解码各只有一个函数**：`item_id_of`（编）、`parse_share_item` + `list_target`（解）。
   `list` 与 `play` 都调它们 —— 形状改一处就会被门禁抓住，不会"编了新形状、解还在旧形状"。
2. **分享里的目录也走 `share:` 形状**：`list_target` 解出来的 fid 正好是分享内的
   `pdir_fid` ⇒ 点目录能下钻。改前目录与文件同形会让"下钻"与"播放"分不清。
3. **`play` 先转存再取直链**：`share:…` → `share_save()`（三步）→ 拿到**我网盘里的新 fid**
   → 走既有的 `file/download` + `__puus` 合并那条路（复用，不另写一遍）。
4. **夸克也接分享列目录**（此前只有 UC 接通）：两条端点路径逐字相同，host/pr 从
   `PanDriveSpec` 取；body 形状（JSON）的对照实验已在同族 UC 上做过。

## Alternatives considered

### A. 只接 UC，夸克保持"如实未接通"（= 上一轮的决定）

**最强理由**：夸克那一步**没有做过 JSON/表单的真网对照实验**，照抄同族形状严格说是"猜"；
本仓纪律是"没验过就不要假装能用"。上一轮拒掉"分享接通"正是这个理由。

**否掉的原因**：

```text
① Owner 这次的验收要求逐字是「夸克/UC 分享页点开能真的播」—— 只做 UC 等于没做。
② "猜"的判据是"有没有可判定的证据"，不是"在哪一家上测的"：
   端点路径逐字相同、参数串在 spec 里、body 形状在 UC 上有 500/15000 ↔ 200/0 的对照读数。
③ 有一条**更强的反向证据**：15000 已确认**不是**"需要登录"（需登录是 401/31001），
   而是"请求形状不对"；JSON 形状在 UC 上把它变成 200/0。
④ 本轮的真实边界由门禁兜住：夸克**没有真分享样本** ⇒ 失败时如实报接口错误，
   不伪造成功；实网验证按 Owner 的批末统一做（他的指令里明确"不阻塞实现"）。
```

### B. 每次 `play` 时重新列一遍分享页，临时取 `share_fid_token`

**最强理由**：id 不用改形状，`list` 一行不动，向后兼容。

**否掉的原因**：多打一次网络、且**分享页的列表顺序/分页**未必稳定，
要靠"标题 + 大小"去认回用户点的那一个 ⇒ 认错就是播错片。
更糟的是 `list` 与 `play` 会各自持有一份"怎么找条目"的逻辑（两处判据必然漂移）。

### C. 把三要素塞进 JSON 再 base64 进 id

**最强理由**：未来加字段（提取码、目录路径）不用改分隔符协议。

**否掉的原因**：id 会变成不可读的一长串，而 id 会进日志、进收藏、进进度绑定
（`MediaId.native` 是持久化契约）。纯函数 + 门禁已经能挡住改形状，
为"未来可能加字段"提前上编码层是**用排查成本换省事**。

### D. 转存改成"直接下分享地址"

**最强理由**：少三步，快。

**否掉的原因**：不可能成立 —— 分享页 URL 不是媒体流（真机已实测
`Failed to recognize file format`），CDN 只认自己网盘里的 fid。

## Consequences

**收益**

- 分享条目现在有完整上下文：`list` 编、`play` 解，**同一对函数**，形状由门禁钉死。
- 夸克/UC 一份实现：host/pr/UA 全在 `PanDriveSpec`（"数据外置"这条没有被破坏）。
- 分享里的目录可以下钻（此前点目录等于没点）。

**代价与边界**

- `share_save` 的三步**尚未真网跑通**（缺真分享样本）。失败会如实报错
  （"换分享 token 没有 stoken" / "转存没有拿到 task_id" / "转存任务超时…不伪造"）。
- 转存会在用户网盘里**留下文件**（原版同样如此）；本轮不做清理。
- 提取码：`Shelf` 没有这个字段，`share_save` 的 `passcode` 恒空串。
  带码分享要另加数据字段（改数据形状，不在本条范围）。
- 一条旧门禁翻面：`quark_share_stays_not_wired` → `quark_shares_use_the_family_chain`
  （理由见 Alternatives A）；另新增 `other_pans_are_not_dragged_into_the_share_chain`
  守住"别家的分享流程结构不同，不许顺手拉进来"。

## 验证结果（已发生）

```text
cargo test --lib pan_drive --release  → 31 passed / 0 failed
  新增/改写：
    share_item_id_roundtrip                编→解 三要素齐全 + 分享目录能下钻 + 裸 fid 不算分享
    list_target_rejects_unknown_share      货架被改过 ⇒ 可读 Err（不许静默列第 0 个）
    quark_share_urls_use_its_own_host_and_pr  夸克不许借用 UC 的 host/pr
    quark_shares_use_the_family_chain      夸克必须走同族链路
    other_pans_are_not_dragged_into_the_share_chain  其它 7 家不许被拉进来
    share_token_body_is_json_not_form       JSON vs 表单（原 uc_ 版改名，判据不变）
    share_urls_match_the_verified_probe     UC 的实测 URL 逐字不变
故障注入（真红，已实测）：
  ① item_id_of 的分享分支改回 `e.fid.clone()` ⇒ share_item_id_roundtrip FAILED
  ② parse_share_item 的 `splitn(3, ':')` 改 `splitn(2, ':')` ⇒ 同一用例 FAILED
  ③ share_family_wired 只留 `Uc` ⇒ quark_shares_use_the_family_chain FAILED
```

## Relations

- 前情（本条翻它的"已知边界"那一页）：
  [../bug-fix/2026-10-28-quark-play-needs-puus-from-response-header.md](../bug-fix/2026-10-28-quark-play-needs-puus-from-response-header.md)
- 同族（同一批收尾的搜索侧）：
  [../bug-fix/2026-10-28-aggregate-keeps-cross-source-same-title.md](../bug-fix/2026-10-28-aggregate-keeps-cross-source-same-title.md)
