# Agent Note: 聚合源给剧集 id 加了前缀却不剥 —— 夸克分享页因此永远播不了

Status: implemented

Independent: 这是 `2026-10-29-share-page-play-resolves-to-direct-link.md` 的**下游断点**。
那篇证明了"分享页 → 直链"这条路本身通（真网拿到直链、CDN 带 Cookie 回 `video/mp4`），
本条修的是**聚合源把这条路掐断**的那一行。

## Problem

Owner 两次报「夸克的还是不能播放」，而真网直连同一 share_id 是成功的：

```text
搜「老舅」→ child=csp-gui-gui 集="网盘分享页" share_id=09350e7add7c
  resolve_share_play → 直链 https://dl-pc-zb.pds.quark.cn/…
  直链 GET 探测：① 裸请求 → 403 XML   ② +UA → 403 XML   ③ +UA+Cookie(含 __puus) → video/mp4
```

⇒ 解析没问题，Cookie 也带对了。问题在**上游传下来的剧集 id**：

```text
`TvboxAggregate::detail()` 把每一集 id 加了 `<child>::` 前缀（791-795 行），
而 `resolve()` 只对 `id.native` 剥了前缀，`req.episode_id` **原样透传**给子站：
   子站收到 `csp-gui-gui::https://pan.quark.cn/s/09350e7add7c`
   ⇒ 它自己的 play() 认不出（前缀挡着）⇒ 原样交回
   ⇒ 分享页兜底 `parse_share_page` 也认不出（要求 host 精确匹配）
   ⇒ 播放器收到带前缀的"URL"⇒ 报"格式解不了 / 不能播放"
```

## Decision

```text
`TvboxAggregate::resolve` 里把 `req.episode_id` 的前缀**对称剥掉**（与 detail 加前缀成对），
其余字段原样：`PlayRequest { episode_id: stripped, ..req.clone() }`。
```

## Alternatives considered

### A. 让 detail 不给剧集 id 加前缀（只给条目 id 加）

**最强理由**：前缀本来就是给"条目"路由用的，剧集 id 由子站自己解释，加前缀是多余的。

**否掉的原因**：剧集 id 必须能唯一定位到子站（否则"同一集在不同子站同 id"会串台），
而 `detail()` 返回的 episodes 是**跨子站平铺**的（一个详情里可能有多个子站的集）。
去掉前缀会让"点第 3 集播到别人家第 3 集"，这是更坏的静默错误。
⇒ 保留前缀，在 resolve 里对称剥 —— 改动面最小，语义仍然唯一。

### B. 在 `CspProvider::resolve` 里"容错地"剥掉任何 `xxx::` 前缀

**最强理由**：一处修，所有走 csp 的路径都受益。

**否掉的原因**：`::` 是聚合层的协议，不该泄漏到 csp 层；而且 csp 的 episode id 本身
就可能含 `::`（分享 URL 里的 `http://` 不含 `::`，但别的源可能）⇒ 在错的层做容错会误伤。
在**加前缀的那一层**剥，是所有方案里唯一"成对"的。

### C. 让播放器把带前缀的串当 URL 用（原样交给 mpv）

**最强理由**：零改动。

**否掉的原因**：mpv 拿到 `csp-gui-gui::https://…` 必然"格式解不了"，
这正是 Owner 反复看到的那句报错。

## Consequences

**收益**

- 聚合源里的分享页线路（4K指南 / 咕咕 / 搜盘 / 魔术那类）**第一次真正能播**。
- 子站仍然能按 `<child>::` 唯一定位剧集 ⇒ 不会串台。

**代价与边界**

- 前缀协议现在有**两个对称点**（detail 加、resolve 剥），任何一侧改了都会静默坏；
  门禁 `resolve_strips_child_prefix_from_episode_id` 就是钉这一对（注入实测真红）。
- 直播/网盘等不支持搜索的 17 家仍会进扇出并返回 Unsupported（不筛：筛不掉，见代码注释）。

## 验证结果（已发生）

```text
真网（本机钥匙串登录态）：
  share_id=09350e7add7c → 直链；GET 带 Cookie ⇒ video/mp4；不带 ⇒ 403 XML
  ⇒ 证明"解析通、Cookie 必需"，剩下就是本条的 id 前缀问题
cargo test --lib tvbox_aggregate --release → 23 passed
  新增 resolve_strips_child_prefix_from_episode_id
故障注入（已实测真红）：把 strip 换成 `req.episode_id.clone()`
  ⇒ left: ["csp-gui-gui::https://pan.quark.cn/s/09350e7add7c"]
    right:["https://pan.quark.cn/s/09350e7add7c"]  ⇒ FAILED
```

## Relations

- 分享页 → 直链（上游）：[../feature/2026-10-29-share-page-play-resolves-to-direct-link.md](../feature/2026-10-29-share-page-play-resolves-to-direct-link.md)
- 搜索扇出并发：[../feature/2026-10-29-aggregate-search-bounded-concurrency.md](../feature/2026-10-29-aggregate-search-bounded-concurrency.md)