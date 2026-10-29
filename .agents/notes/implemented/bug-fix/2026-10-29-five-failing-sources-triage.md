# Agent Note: 5 家"搜索失败"的源逐家定性 —— 4 家是站点自己说没有，1 家搜索被关

Status: implemented

Independent: 这是 `2026-10-29-restore-auto-disabled-sources.md`（源数 47→89）之后的**质量核查**：
那篇把"参与搜索的源"补到 89，本篇回答"剩下报错的那 46 个里，哪些是真坏、哪些是假红"。
不改任何解析逻辑。

## Problem

Owner 要求「75 个源可用」。迁移后现状（真机，搜「老舅」）：
**89 个参与源 / 50 个有结果 / 46 个报错**。报错里混着三类完全不同的东西：

```text
① 站点真的没有这部剧 —— 却报成"解析坏"（假红，会误导排障与"可用源数"）
② 站点侧搜索确实被关/镜像死了（不可修）
③ 真·解析坏（需要证据才能判定）
```

## Decision（逐家真网定性，全部用**模块自己的解析器**跑真实页）

```text
cid              判定                    真实证据（同一份代码，换词对照）
csp-libvio       OK-无片                 老舅 200/3739字符/0卡片；末 200/11060字符/12卡片(首=末世行者)
csp-hd-moli      OK-无片                 老舅 200/8199字符/0卡片+页内「对不起，没有找到任何关于老舅的记录」；末 27152字符/10卡片
csp-4k-zhinan    OK-无片                 老舅 19063B/0 个 <article>+<body class="search search-no-results">；龙珠 28680B/10条
csp-ting-jinxia  OK-无片                 老舅 3227B/.clist 空+页次1/1；无敌剑域 3795B/1条
csp-wwys         站点侧搜索不可用         搜索页 66B/68B「缺少文件…vod_search.html」；站点搜索按钮=alert('抱歉！搜索功能升级中')
```

⇒ 结论：**这 5 家里一家都不是解析坏**，所以选择器/正则一行未改；只在模块里留下取证注释（日期 + 判据 + 字节数）。
唯一的行为文本改动：`ting_jinxia` 的 Err 文案加上"可能是站点真的没有这个词"，让假红看起来像假红。

## Alternatives considered

### A. 把这 4 家的 `Err` 改成 `Ok(空)`（消掉假红）

**最强理由**：假红会污染"失败子站"清单，也会让 Owner 以为源坏了。

**否掉的原因（本轮）**：`Err` 与"空结果"在 UI 上是两种信号，改了会掩盖"站点改版"这种**将来真会发生**的情况
（到那天就变成静默空列表）。正确做法是先有 `is_zero_result_page()` 这类**显式判据**再改，
那需要逐站写"空结果页特征"，本轮时间不够 ⇒ 记录在案，留给下一批（含每站真实页片段门禁）。

### B. 给 wwys 换镜像 / 让它 `supports_search=false`

**最强理由**：换镜像能救回一个源；关掉能力能少一次注定失败的请求。

**否掉的原因**：真网核对 `wwgz.cn` 只剩 SOA、`vip.wwgz.cn:5200` 两套模板里都没有 `vod_search.html`
（站点自己把搜索写成 `alert('抱歉！搜索功能升级中')`）⇒ 没有可换的镜像。
关能力涉及 manifest 改动与 UI 影响面，属于下一个决定，不在"取证"里顺手做。

### C. 把 libvio 判成"站点死"

**最强理由**：curl/node 直连 `www.libvio.io` 全是 `403/44 B` + `x-cdn-challenge: required`。

**否掉的原因（自己推翻自己）**：那是**缺浏览器头**。补齐 `Referer`/`Sec-Fetch-*`/`Upgrade-Insecure-Requests`
后同一 URL 变 `403/20359 B`，body 里逐字 `var TS=…, SIG=…, DIFF="0000", MODE="auto"` ⇒ 旧 PoW 协议仍有效
（手写 Python 解出 nonce → `302` + `__cdn_verified` → home 40464 字符）。
reqwest 侧本来就带这套头，所以线上一直是活的。⇒ **不要**因为看到 403 就删 PoW 分支。

## Consequences

**收益**

- 46 个报错里，这 5 家有了**可复现的定性**（假红 vs 不可用），后续修源不会白费力气。
- libvio 的 PoW 分支被证明仍然有效（避免后来人"看到 403 就删代码"这种倒退）。
- 新增一条运维提醒：libvio 的失败可能是**间歇性网络/PoW 限流**（同一时刻直测 4 段全绿、1.23s），
  压红的方向是退避重试，不是改正则。

**代价与边界**

- 这 5 家仍会出现在"失败子站"里（见 Alternatives A 的取舍）。
- `wwys` 仍是不可用源，没有替代镜像。

## 验证结果（已发生）

```text
逐家真网（模块自己的解析器跑真实页）：
  csp-libvio / csp-hd-moli / csp-4k-zhinan / csp-ting-jinxia / csp-wwys
  老舅 红、换词 绿（同代码两态对照）—— 证据页快照在 .probe/hf-*.html
各模块测试：csp::libvio 18 passed、csp::hd_moli 12 passed、csp::zhinan 14 passed、
           csp::ting_jinxia 9 passed、csp::wwys 19 passed
整体基线（迁移后）：[EACH] 有结果 50 / 空 2 / 错 46；聚合候选 89、按源分组 49
```

## Relations

- 源数迁移（为什么参与源从 47 变 89）：[../feature/2026-10-29-restore-auto-disabled-sources.md](../feature/2026-10-29-restore-auto-disabled-sources.md)
- 搜索扇出并发与稳定性：[../feature/2026-10-29-aggregate-search-bounded-concurrency.md](../feature/2026-10-29-aggregate-search-bounded-concurrency.md)