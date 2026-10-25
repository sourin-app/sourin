# 插件开发

> 本文原为根 [README.md](../README.md) 的「插件开发」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 插件开发

插件是**一个 JS 文件**，跑在 Rust 侧的 QuickJS 沙箱里。

> **配套仓库**：[sourin-app/sourin-plugins](https://github.com/sourin-app/sourin-plugins) ——
> 作者自用的源、完整的插件 API 契约（`docs/API.md`）与可运行示例（`examples/demo.js`）。
> 本节的契约以**那个仓库的 `docs/API.md`** 为最新准。
> 那个仓库是**公开仓库**（无需任何权限即可访问与克隆）。

## 最小插件

```javascript
/** @id my-source @name 我的源 @version 1.0.0 */

globalThis.plugin = {
  id: 'my-source',
  name: '我的源',
  version: '1.0.0',

  capabilities: {
    vod: true,      // 点播
    search: true,   // 搜索
    live: false,    // 直播
    loginRequired: false,
  },

  // 首页分类（可选）
  categories: [
    { id: '1', name: '电影', pid: null },
    { id: '2', name: '电视剧', pid: null },
  ],

  // 分类列表
  async category({ categoryId, page }) {
    const r = await host.http.get(
      'https://example.com/api?ac=list&t=' + categoryId + '&pg=' + page
    );
    const data = JSON.parse(r);
    return {
      items: data.list.map((it) => ({
        id: String(it.vod_id),
        title: it.vod_name,
        cover: it.vod_pic,
        remark: it.vod_remarks,
      })),
      hasMore: page < 10,
    };
  },

  // 详情
  async detail({ id }) {
    const r = await host.http.get('https://example.com/api?ac=detail&ids=' + id);
    const it = JSON.parse(r).list[0];
    return {
      id: String(it.vod_id),
      title: it.vod_name,
      cover: it.vod_pic,
      description: it.vod_content,
      episodes: it.vod_play_url.split('#').map((seg, i) => {
        const parts = seg.split('$');
        return { id: String(i + 1), title: parts[0], url: parts[1] };
      }),
    };
  },

  // 播放地址
  async play({ id, episodeId }) {
    // 返回候选列表，播放器会挑第一个能播的
    return [
      { url: 'https://example.com/play/' + id + '/' + episodeId + '.m3u8', label: '默认' },
    ];
  },
};
```

关键的一点：头部注释里的 `@id` 是必填的，缺了会被直接拒绝安装
（报错原文：`插件缺少 @id（头部注释里必须有，如 @id srcl）`）。上面的示例能跑，
前提就是第一行那行头注释。

## 可用的 host API

| API | 说明 |
|---|---|
| `host.http.get(url, opts)` | GET，返回**响应体字符串** |
| `host.http.post(url, body, opts)` | POST |
| `host.http.raw(method, url, opts)` | 返回 `{status, body, setCookie}` —— 需要读响应头时用这个。`setCookie` 是数组（Cookie 的 Expires 含逗号，拼成串再切分有歧义）；返回的是 JSON 文本，要自己 `JSON.parse` |
| `host.log.debug/info/warn/error(msg)` | 写进应用日志（四级） |
| `host.store.get/set/remove(k[, v])` | 插件私有存储（落在 `plugins/.data/<id>.json`），值是**字符串** |
| `host.config.get/getBool/getNumber/getString/all()` | 读用户在设置页填的值 |
| `host.util.urlEncode/urlDecode/sleep` | 小工具 |
| `host.base()` | ★ 多域名池：当前该用的域名。见下方「多域名池」一节 |
| `host.extract.regex(text, pattern)` | ★ 按正则提取，返回 `string[]`。见下方「通用提取器」 |
| `host.extract.json(text, path)` | ★ 按路径取 JSON 值，返回 **JSON 文本**或 `'null'` |
| `host.playback.probe(url)` | ★ 探测地址：能不能放 / 什么流 / 有没有 DRM / 跳转过没。见下方「播放地址探测」 |

> `opts` 支持 `headers`（对象）。同名头只保留**第一个**。

> ⚠️ **2026-10-17 更正**：本表原写作 `host.cache.*` —— **宿主从来没有这个 API**
> （`plugins/mod.rs` 里注入的是 `host.store`，全仓搜 `cache` 零注入点）。
> 同时漏了 `config` / `util` / `base`。原表是凭印象写的，没有对照注入代码。

## 安装插件

三个入口，都在 设置 → 内容源：

| 入口 | 用途 |
|---|---|
| **粘贴源码安装** | 直接把上面的 JS 贴进去 |
| **从网址安装** | 填一个 `.js` 的 URL，自动下载 |
| **导入源 → TVBox 配置** | 填 TVBox 的配置**地址或 JSON**，内部解析成源 |

> **TVBox 不需要转换成脚本**。核心层直接解析 TVBox 配置的 `sites` 段，
> 把 `type: 1`（苹果 CMS）的站点建成内容源。所以配置作者更新了配置，
> 你在应用里点「检测更新 → 应用更新」就行，**不用重新转换、不用重装**。

## 弹幕能力（2026-10-16 新增）

插件可以**提供**某一集的弹幕，也可以**发送**弹幕。两者是**独立**的能力位 ——
因为「能取弹幕」的站点远多于「能发弹幕」的站点（取 = 公开读接口，
发 = 要登录 + 签名 + 风控）。

### 能力位

```javascript
capabilities: {
  danmaku: true,      // ① 能提供某集的弹幕列表
  danmakuSend: true,  // ② 能发送弹幕
}
```

两个都**默认 false** —— 老插件不声明，行为与今天完全一致。

> ⚠️ `danmakuSend` 只决定**界面上发送入口出不出现**。
> 「真正能不能发」看插件**有没有实现 `danmakuSend()`** ——
> 只声明不实现会走到「该源不支持发送」这条降级路径（不报错，但发不出去）。

### 取弹幕：`danmakuList(req)`

```javascript
async danmakuList(req) {
  // req = {
  //   provider,      // 源 id（宿主填，一般不用）
  //   mediaId,       // 条目 id      ★ 已剥掉 "provider:" 前缀
  //   episodeId,     // 剧集 id      ★ 已剥掉前缀
  //   title?,        // 作品名    —— 按标题搜索弹幕库时用
  //   episodeTitle?, // 剧集名    —— 同上
  //   duration?,     // 时长秒    —— 裁时间轴时用
  // }
  return {
    items: [
      { cid: 101, p: '1.5,1,16777215,u1', m: '第一条弹幕' },
      { p: '3.0,5,255,u2', m: '这条没给 cid —— 见下方说明' },
    ],
    source: 'my-source:777',  // 可选：这条弹幕从哪来（排错用）
    truncated: false,          // 可选：上游是否被截断
  };
}
```

### wire 格式：**与 dandanplay 协议一致**

`items` 的每一项就是 dandanplay 的 `{cid, p, m}`。**这是本协议的一等公民**，
不是「顺便兼容」—— 因为：

```text
① 宿主渲染层**已经有**这个格式的解析器 ⇒ 插件输出直接喂它，零转换
② 它是**多方交集**：dandanplay 生态、外部视频源弹幕 XML 都落在这个形状上
   （外部视频源的 <d p="时间,模式,字号,颜色,…"> 只是段位不同，一次重排即可）
③ 所以插件接一个**走 dandanplay 协议的上游**几乎是直译，不用发明映射表
```

`p` 串的分段：

```text
"出现时间秒,模式,颜色,用户ID"

  时间   秒，可带小数（如 1.5）
  模式   1 = 滚动（右→左）   4 = 底部固定   5 = 顶部固定
         ⚠️ 其余取值一律按**滚动**处理（不丢弃 —— 历史数据格式很杂）
  颜色   十进制 24 位 RGB（白 = 16777215 = 0xFFFFFF）
  用户ID 可空
```

### ★★★ `cid` 可省略，但**必须知道它的代价**

`cid` 是**可选**的。有些上游（外部视频源弹幕 XML）根本没有这个概念，
硬要求会逼你去**编一个假 id** —— 那比缺它更糟。

但宿主渲染层原来的解析器在 `cid` 缺失时会**整条丢弃、且不抛异常**：
```text
插件明明取到了 100 条 → 用户看到「加载成功但一条都没有」→ 无从排查
```

⇒ 所以**宿主侧已经自动补位**（按下标 + 1）。你**不需要**自己编 cid。

> 如果你确实知道上游的真 cid（如 dandanplay 系），**照实给** ——
> 补位只补空缺，不会覆盖你给的值。真 cid 对去重/去黑名单更有用。

### 发送弹幕：`danmakuSend(req)`

```javascript
async danmakuSend(req) {
  // req = {
  //   provider,
  //   episodeId,   // ★ 已剥前缀
  //   text,        // 正文
  //   time?,       // 出现时间秒（默认 0 = 当前进度）
  //   mode?,       // 1 滚动 / 4 底部 / 5 顶部（默认 1）
  //   color?,      // 十进制 RGB（默认 16777215 白）
  //   progressMs?, // 当前播放进度（毫秒）—— 按进度发的站点用
  // }
  return { ok: true, id: '上游给的弹幕 id' };
}
```

### ★★★ 三条硬纪律（不支持就说不支持）

用**错误前缀**声明失败类型（与其它方法同一套约定）：

```javascript
throw new Error('unsupported: ...')   // 该源不支持弹幕 / 不支持发送
throw new Error('unauthorized: ...')  // 需要登录（下一步是去登录）
throw new Error('network: ...')       // 网络问题
throw new Error('parse: ...')         // 上游改版了
```

```text
① 不支持 ⇒ 必须 throw 'unsupported: <原因>'
   ✗ 不许 return { items: [] }
     因为「这一集真的没人发弹幕」与「我不支持弹幕」是两件完全不同的事。
     空数组会让用户以为前者。

② 发送未实现 ⇒ 必须 throw 'unsupported: <原因>'
   ✗ 绝不许 return { ok: true } 假装成功
     用户会以为发出去了 → 刷新找不到 → 反复发 →
     在真站点上可能**已经触发风控封禁**。
     （宿主也把 { ok: false } 当成失败拒掉，不给「软失败」留口子。）

③ 能发但没登录 ⇒ throw 'unauthorized: ...'（不是 'unsupported:'）
   两者对用户的**下一步动作**完全不同：需要登录 → 去登录；不支持 → 别试了。
```

### 一个完整的取弹幕例子（外部视频源 XML → wire）

```javascript
async danmakuList(req) {
  const xml = await host.http.get(
    `https://comment.example.com/${encodeURIComponent(req.episodeId)}.xml`,
  );
  if (xml.startsWith('__ERR__')) throw new Error('network: ' + xml.slice(7));

  const out = [];
  const re = /<d p="([^"]*)">([\s\S]*?)<\/d>/g;
  let m;
  while ((m = re.exec(xml)) !== null) {
    const seg = m[1].split(',');
    // ★ 上游格式：时间,模式,字号,颜色,时间戳,池,hash,弹幕ID,权重
    //   颜色在下标 3；而 wire 要的是 时间,模式,颜色,用户ID —— 必须重排
    out.push({
      p: [seg[0], seg[1], seg[3] || '16777215', seg[7] || ''].join(','),
      m: m[2],
    });
  }

  if (out.length === 0) {
    // ★ 200 但一条都没有 —— 如实说，不要返回空数组（那是"有但为空"的语义）
    throw new Error('unsupported: 该弹幕池是空的（cid=' + req.episodeId + '）');
  }
  return { items: out, source: 'example:' + req.episodeId };
}
```

> ⚠️ 上面的「颜色在下标 3」是最容易抄错的一处：
> **上游 XML 里颜色是第 4 段，wire 里是第 3 段**。直接透传上游的 `p` 串会得到
> 一串**把字号当颜色**的弹幕（全部显示成奇怪的颜色），而且不报错。

---

### ★ 宿主解析能力：`needsHostResolve` / `siteId` / `streamFlags`（2026-10-17）

有些站点的插件**拿不到**可播地址（要签名 / DRM / 需要浏览器环境），
只能给出**播放页 URL**。这类插件可以声明「请宿主来解」。

```js
async play({ id, episodeId }) {
  return [{
    url: 'https://s1.example/watch/' + episodeId,  // ★ 播放页 URL，不是可播地址
    label: '默认',
    needsHostResolve: true,   // ★ 声明：url 是播放页，请宿主解析
    siteId: 'S1',             // ★ 站点代号（**不是站名**，见下方警告）
    streamFlags: { drm: false, hdr: false },  // 可选：你知道就填，不确定就不填
  }];
}
```

#### 三个字段的语义

| 字段 | 类型 | 默认 | 说明 |
|---|---|---|---|
| `needsHostResolve` | bool | `false` | `true` = `url` 是**播放页 URL**，宿主负责解出真实地址 |
| `siteId` | string? | `null` | 站点**代号**（`S1` / `S2` / …），供宿主选择对应解析器 |
| `streamFlags` | object | 全空 | 这条流**是什么**（不是「请求宿主做什么」），见下 |

`streamFlags` 的子字段：

| 子字段 | 类型 | 含义 |
|---|---|---|
| `drm` | bool | 受 DRM 保护。**宿主一定播不了**，会如实告诉用户 |
| `hdr` | bool | HDR 内容。不影响可播性（宿主会降到 SDR） |
| `codec` | string? | 编码名（`h264` / `hevc` / `av1`）。**不知道就留空，不要猜** |

#### ⚠️⚠️ 三条硬纪律

```text
① 不声明 = 行为与以前**逐字相同**
   三个字段全部有默认值，老插件不传任何东西，宿主行为一点不变。
   实测：rust/sourin_core/tests/zz_t33_host_resolve_contract.rs 有 7 条测试钉住这一点。

② needsHostResolve=true 时，url 必须是**播放页 URL**，不是可播地址
   若你其实拿到了可播地址，就不要声明这个位 —— 声明了反而会让宿主白解一遍。

③ 不许把「宿主还没解出来」说成 DRM
   drm=true 意味着「受版权保护，永远播不了」，宿主会这样告诉用户。
   而「解析失败」是另一回事。混用就是让宿主对用户说假话。
```

#### ⚠️ `siteId` 只能写代号，不能写站名

本仓有机械门禁 `test/t98_no_site_names_test.dart`：
**具体视频网站的名字不许出现在仓库任何可发布文本里**（含 `.js` / `.md`）。

```text
✓ siteId: 'S1'                    ← 代号（可以）
✗ siteId: '<具体站名>'            ← 写真实站名，会被门禁判红
```

> ⚠️ 这里**故意不举例**——举例就要写出站名，而写出来本身就会让门禁变红
> （`test/t98_no_site_names_test.dart` 扫 `.md`）。
> 我写这段时就犯了一次：用真实站名当反面例子 ⇒ t98 立刻判红。
> 规则的正确用法是「只写代号，代号的含义由插件自己定义」。

真实映射关系由**插件自己持有**（插件不进仓库）。

#### 宿主侧的当前状态（诚实说明）

```text
解析能力本身**尚未选型** —— 三条候选路线（自实现签名 / 无头浏览器 / 插件侧解）
都还在评估，见 .probe/t33/REPORT_R2.md §3。

⇒ 现在声明 needsHostResolve: true 的候选会被标为**不可播**，
  用户看到「所有线路都不可播」而不是黑屏。
⇒ **这是有意的诚实当前态**，不是缺陷：宿主不会假装能解却播不出来。
```

---

## ★ 多域名池：`hosts` + `host.base()`（2026-10-17 新增）

> **Owner 口径（逐字）**
> 「多 host 由插件提供，自动轮值由软件本身实现」

⇒ 职责划分是**硬约束**：
```text
插件   负责「有哪些候选域名」      —— 数据
宿主   负责「选哪个、什么时候换」  —— 算法
```
⇒ 宿主侧**一行站点代码都没有**：它不认识任何具体域名，
  只处理「一批字符串 + 当前用哪个 + 失败计数」。

### 插件怎么写

```js
globalThis.plugin = {
  capabilities: { vod: true },

  // ★ 候选域名（有序 = 你给的优先级）
  hosts: [
    'https://a.example.com',
    'https://b.example.com',
  ],

  async list({ categoryId, page }) {
    // ★ 用 host.base() 拿「当前该用哪个」——不要自己写死域名
    const base = host.base()
    return host.http.get(`${base}/api/list?cat=${categoryId}&page=${page}`)
  },
}
```

| 字段 / API | 类型 | 语义 |
|---|---|---|
| `hosts` | `string[]` 可选 | 候选域名，**含协议**，末尾不要带 `/` |
| `host.base()` | `string` | 当前应使用的域名；**未声明 `hosts` 时返回 `''`** |

```text
hosts 省略 / 空数组 ⇒ 不用域名池，行为与今天完全一致（向后兼容）
hosts 只有一项      ⇒ 合法但无用（失败无处可切），宿主会记日志提醒
hosts 含重复项      ⇒ 宿主去重，保留首次出现的顺序
```

### 宿主怎么选（这是宿主的事，但你该知道行为）

```text
① 已锁定的 current（仍健康） ⇒ 继续用，不抖动
② 健康域名里 failures 最少   ⇒ 同失败数时按你给的顺序
③ 失败 3 次 ⇒ 进冷却，换下一个
④ 冷却到期 ⇒ failures **减半**（不是清零）后重新入候选
⑤ 全在冷却 ⇒ 选 failures 最少的（保证总有能用的）
⑥ 任一请求成功 ⇒ 该域名 failures 归零并**锁定**
```

> ⚠️ 为什么冷却后「减半」而不是「清零」：
> 清零会让刚恢复的坏域名**立刻被重选**、马上又失败，来回撞墙。
> 减半保留「它历史上有问题」的记忆，让它排在健康域名之后。

### ⚠️⚠️ 三条硬纪律

**1. `hosts` 只是数据，不是逻辑**
```text
✗ hosts: [...] + if (failed) base = hosts[1]     ← 插件自己在轮值，职责越界
✓ hosts: [...] + 一律用 host.base() 拼 URL
```

**2. ★ 声明了 `hosts` 却不经 `host.base()` ⇒ 整个机制失效**
```text
宿主不知道「这一次请求打的是哪个域名」⇒ 失败无法归因 ⇒ 池子形同虚设。
请求必须用 base 拼出来的 URL，否则失败不会被记到正确的域名头上。
```

**3. 域名必须是真·同构镜像，不能是不同站点**
```text
宿主会在 a 失败后**无缝换到 b**，并假设两者 API 完全一致。
若 a/b 其实是两个不同站点，切换后会给用户返回风马牛不相及的内容 ——
而且不报错，更难查。
```

### ⚠️ 声明 `hosts` 时，请自己处理缓存与域名的绑定

宿主**不会**替你清缓存。`host.store` 的 key 是你自己定的字符串，
宿主只做 `map[key]` 存取，**不参与 key 的构造**。

```js
// ✗ 危险：换域名后拿到的仍是旧服务器的数据（且看起来完全正常）
host.store.set('views', JSON.stringify(list))

// ✓ 把域名并进 key
host.store.set('views@' + host.base(), JSON.stringify(list))
}
```

> 实测依据：仓库里的 `emby.js` 用固定 key `'views'` / `'token'`，
> 不含 serverUrl。它目前不声明 `hosts` 所以还没出问题；
> 一旦加上 `hosts`，换域名后会读到旧服务器的媒体库列表。

### 宿主侧的当前状态（诚实说明）

```text
★ 已实现（rust/sourin_core/src/hostpool.rs + plugins/mod.rs 接线）：
  · 选路算法、失败计数、冷却与减半恢复
  · 失败计数与当前选择**落盘**（<dataDir>/host-pools.json，重启不忘）
  · host.base() 注入
  · 单测覆盖（含确定性、故障注入、真实网络切换）

⚠️ 截至 2026-10-17 **尚未在真实第三方插件上验证过** ——
   因为仓库内的插件（demo.js / emby.js）都还没有声明 hosts。
   端到端只用内联的假插件源码验证过。
   ⇒ 若你是在真实插件上第一个用这个能力的，请把问题反馈回来。
```

---

## ★ 通用提取器：`host.extract`（2026-10-17 新增）

> **为什么是「通用提取」而不是「内置站点解析器」**
>
> 宿主**不认识任何具体站点**，这是硬约束（见 `test/t98_no_site_names_test.dart`）。
> 站点知识（页面结构、接口地址、签名算法）全部由**你的插件**持有。
> 宿主只提供「按规则从文本里取值」这个执行能力 —— 对所有站通用。

### 两个方法

| 方法 | 返回 | 说明 |
|---|---|---|
| `host.extract.regex(text, pattern)` | `string[]` | 所有匹配的第 1 个捕获组；**无捕获组时取整个匹配** |
| `host.extract.json(text, path)` | `string`（JSON 文本）或 `'null'` | 按路径取值 |

### `regex` 的两个关键行为

```js
// ① 有捕获组 ⇒ 取第 1 组（绝大多数场景）
host.extract.regex(html, 'data-vid="([^"]+)"'));
// ⇒ ['abc123']

// ② 无捕获组 ⇒ 取整个匹配
host.extract.regex(html, 'vid=\\w+');
// ⇒ ['vid=abc123', 'vid=def456']

// ③ 没匹配到 ⇒ 空数组（不是错误）
host.extract.regex(html, 'zzz');
// ⇒ []

// ④ ★ 正则语法错误 ⇒ 抛异常（不是返回空数组）
host.extract.regex(html, '(unclosed');
// ⇒ throw: 正则语法错误: ...
```

> ⚠️ 第 ③ 与第 ④ 的**区分很重要**：
> 如果语法错误也返回空数组，你会以为「页面上没有这个字段」，
> 从而去改选择器 —— 但真正的问题是你的正则写错了。

### `json` 的路径语法

```text
a.b.c        对象嵌套
a.b[0]       数组下标
a[0].b[2].c  混用
（空串）      整个文档
```

```js
const body = await host.http.get('https://example.com/api/detail?id=1');

const title = JSON.parse(host.extract.json(body, 'data.title'));
const ep1   = JSON.parse(host.extract.json(body, 'data.episodes[0].url'));
const ep2   = JSON.parse(host.extract.json(body, 'data.episodes[1].url'));

// ⚠️ 返回的是 JSON **文本**，要自己 JSON.parse
//    与 host.config.get 一致：跨 QuickJS 边界传字符串比传对象稳

// 路径不存在 ⇒ 得到 'null'，可以这样兜：
const year = JSON.parse(host.extract.json(body, 'data.year') ?? 'null') ?? 2024;
```

> ⚠️ 「路径不存在」返回 `'null'` 而**不抛异常**：
> 解析页面时「某个字段没有」是常态（页面结构会变），
> 每次都抛异常没法用。只有**路径语法错误**才抛。

### 完整可运行示例

```js
/** @id myplugin @name 我的源 */
globalThis.plugin = {
  capabilities: { vod: true },

  async resolve(id) {
    // ① 抓页面
    const html = await host.http.get(`https://example.com/v/${id}`);

    // ② 从 HTML 里取视频 id
    const ids = host.extract.regex(html, 'data-vid="([^"]+)"');
    if (!ids.length) throw new Error('页面里没找到 data-vid');

    // ③ 用 id 调接口
    const body = await host.http.get(
      `https://example.com/api/play?vid=${ids[0]}`,
    );

    // ④ 从 JSON 取播放地址
    const url = JSON.parse(host.extract.json(body, 'data.playUrl'));
    if (!url) throw new Error('接口没返回 playUrl');

    // ⑤ 交给宿主
    return [{ url, quality: '原画', kind: url.includes('.m3u8') ? 'hls' : 'mp4' }];
  },
};
```

> 这个示例的完整可运行版本（含本地 http server 与真实请求）见
> `rust/sourin_core/tests/t41_extract_e2e.rs`（`cargo test --test t41_extract_e2e`）。

### 宿主侧的当前状态（诚实说明）

```text
★ 已实现：host.extract.regex / host.extract.json
  · 纯函数实现（不碰网络/磁盘），单测 11 条
  · 契约测试 4 条（从 JS 侧真调用，走 QuickJS → Rust 全链路）
  · 端到端 1 条（本地 http server 喂真实响应，插件真的解析出来）
  · 故障注入验证过：把数组下标改错 ⇒ 单测 2 条红 + 端到端红

⚠️ 未做（下一步）：
  · host.playback.probe —— 探测地址能不能放
  · DRM 嗅探 —— 读 #EXT-X-KEY / ContentProtection
  · 错误分类 —— 把播放失败翻译成人类能懂的类别
```

---

## ★ 播放地址探测：`host.playback.probe`（2026-10-17 新增）

> **它回答什么**：这个地址能不能放、是什么流、有没有 DRM、跳转过没有。
>
> **为什么需要**：插件拿到的地址可能被防盗链拦截返回 HTML 错误页、
> 可能是 DASH（本播放器未实现）、可能带 DRM（架构上不可能播）。
> 不先探测就交给播放器 ⇒ 用户看到黑屏，而你查不出原因。

### 调用

```js
const r = JSON.parse(await host.playback.probe(url))
```

### 返回字段

| 字段 | 类型 | 说明 |
|---|---|---|
| `verdict` | string | 结论标签，见下表 |
| `kind` | string | `Hls` / `Dash` / `Mp4` / `AudioOnly` / `WebEmbed`（仅 playable/dash 时有值） |
| `contentType` | string | **原始** Content-Type 响应头（空串 = 响应没带） |
| `statusCode` | number | HTTP 状态码（0 = 请求没发出去） |
| `redirected` | bool | 是否发生过跳转 |
| `finalUrl` | string | 跳转后的**最终**地址（未跳转时等于入参） |
| `message` | string | 给用户看的一句话 |
| `retryable` | bool | 是否值得重试 |

### `verdict` 五种取值 —— **必须能区分**

| verdict | 含义 | retryable | 用户该做什么 |
|---|---|---|---|
| `playable` | 可以尝试播放 | false | 直接播 |
| `dash_unsupported` | DASH 格式，**本播放器未实现** | false | 换源 |
| `drm` | 受 DRM 保护，**架构上不可能播** | false | 换源（换播放器也没用） |
| `not_a_stream` | 地址能访问但**返回的不是媒体流** | false | 检查地址/防盗链 |
| `unreachable` | 网络或 HTTP 失败 | **true** | 可以重试 |

```text
⚠️ 这五种必须互不混淆。
混成一句「播放失败」⇒ 用户不知道该重试、该换源、还是该放弃。
```

### 完整可运行示例

```js
/** @id myplugin @name 我的源 */
globalThis.plugin = {
  capabilities: { vod: true },

  async resolve(id) {
    const url = await getPlayUrl(id);

    const r = JSON.parse(await host.playback.probe(url));

    if (r.verdict === 'playable') {
      return [{ url, quality: '原画', kind: r.kind.toLowerCase() }];
    }
    if (r.verdict === 'unreachable' && r.retryable) {
      // 网络抖动 ⇒ 可以换线路再试
      throw new Error('地址暂时不可达，请稍后重试');
    }
    if (r.verdict === 'drm') {
      // 如实告诉用户，不要假装能放
      throw new Error(r.message);
    }
    // dash_unsupported / not_a_stream ⇒ 换源
    throw new Error(r.message);
  },
};
```

### 它怎么判（宿主内部逻辑，你该知道）

```text
① HTTP 失败（0 或非 2xx/3xx）⇒ unreachable
② 嗅探响应体里的 DRM 标记（**先于**格式判定）
     HLS  #EXT-X-KEY:METHOD=SAMPLE-AES  ⇒ drm
     DASH schemeIdUri = Widevine/PlayReady/ClearKey ⇒ drm
③ 按 Content-Type 判格式（**不看 URL 后缀**）
     认识 ⇒ playable 或 dash_unsupported
     不认识（text/html、application/json…）⇒ not_a_stream
④ Content-Type 缺失 ⇒ 才退回按 URL 猜
```

> ⚠️ **为什么 AES-128 不算 DRM**
>
> `#EXT-X-KEY:METHOD=AES-128` 是普通 HLS 加密，密钥就是一个普通 HTTP 地址，
> libmpv 自己能解（本仓 streamproxy 就在改写这类 playlist）。
> 把它当 DRM 会让一大批**本来能播**的内容被误判为不可播。
> 只有 `SAMPLE-AES`（需要 FairPlay CDM）才算。

> ⚠️ **为什么不看 URL 后缀**
>
> 实测踩过：某个源的 MP4 直链被伪装成 `.mp3` 后缀。
> 按后缀判成 AudioOnly ⇒ 播不了；按「无扩展名当 HLS」⇒ 无限转圈。
> 只有 Content-Type 可信。

### 宿主侧的当前状态（诚实说明）

```text
★ 已实现：host.playback.probe
  · 纯函数判定（可穷举测试）+ 真 HTTP 探测（读真响应头）
  · 单测 + 契约测试 + 本地 TcpListener 端到端（不 mock、不依赖外网）
  · 两个故障注入验证过（忽略响应头 ⇒ 红；Hls/Dash 互换 ⇒ 红）

⚠️ DASH 只能**识别**，不能播放 —— streamproxy 没有 mpd 改写逻辑。
   识别出来如实报 dash_unsupported，绝不映射成 Mp4 糊弄。
```

---

## ★ 写插件时该做与不该做（2026-10-25）

> 这一节的写法借鉴自 WebHome Devkit 的"脚本适合/不适合做什么"。
> 取舍理由见 [PLUGIN-SPEC-PARITY.md](PLUGIN-SPEC-PARITY.md)。

### 该做的

- **一次请求拿一页**。`list()` 应该只发 1 次 HTTP，而不是"先拿列表，再为每一条补封面"
  （一次翻页 = N+1 次网络，用户看到的是转圈）。
- **字段映射写得能看出来**。某个字段拿不到就给 `null`/省略，让 UI 显示"无"；
  不要层层兜底到"总能返回点什么" —— 那样上游改版时你只会看到内容变歪，
  而看不到"哪一处的取法失效了"。
- **失败要能定位**。抛错时说清是哪一步（取分类 / 翻页 / 解析详情），
  包含上游返回的状态码或片段。`throw new Error('detail: HTTP 403')`
  比 `throw new Error('failed')` 有用一百倍。
- **`detail()` 只解析用户要看的那一集**。不要把整季几十集全解析成直链 ——
  用户点开一集却拉了几十个地址，既慢又容易被上游限流。

### 不该做的

- **不要把 Cookie / token / 账号写进插件文件**。插件是纯文本，会跟着备份导出、
  会进用户的云同步目录。需要登录态的源请走宿主的凭据通道，不要硬编码。
- **不要在没有用户动作时批量请求**。插件只在宿主调用时才执行，
  但一次调用里发几十个并发请求同样会被上游风控。
- **不要用"万能解析"掩盖失败**。例如无论什么页面都正则抓第一个 `.m3u8` ——
  它会在绝大多数站点返回**错误但看起来能用**的地址，用户点开黑屏。
  宁可明确报"这个站不支持"，也不要给出一个错的直链。
- **不要依赖固定结构的选择器/下标**。上游改一版 DOM/JSON 就全废，
  而且报错会指向你自己的代码，看起来像你的 bug。

### 失败会怎样（每条 API 的失败语义）

| 场景 | 宿主表现 | 你该做什么 |
| --- | --- | --- |
| 插件抛错 | 该次调用返回错误，卡片标记 `broken` 并显示原因 | 错误消息里写清步骤 |
| 返回结构不符 | 宿主解析失败，同上 | 对照本文开头「最小插件」里的返回结构检查字段名与类型 |
| 超时（默认 10s） | 强制终止，报"插件执行超时" | 减少请求数 / 缩小单次解析量 |
| 声明了能力但没实现 | **静默返回空**（这是最坑的一种） | 不实现就不要在 `@capabilities` 里声明 |
| `health_check` 未实现 | 卡片显示"未检测"，**不等于可用** | 建议实现，否则用户无法判断源是否还活着 |

> ⚠️ 最后两行是真实存在的"看起来没问题"的形态：
> 能力位声明了但方法没写，宿主按空数组处理，UI 显示"暂无内容"而不是报错。
> 排查时要先确认**能力位与实际实现是否一致**。
