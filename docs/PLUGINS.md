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

## 可用的 host API

| API | 说明 |
|---|---|
| `host.http.get(url, opts)` | GET，返回**响应体字符串** |
| `host.http.post(url, body, opts)` | POST |
| `host.http.raw(url, opts)` | 返回 `{status, body, headers}` —— **需要读响应头时用这个** |
| `host.log(msg)` | 写进应用日志 |
| `host.cache.*` | 插件私有缓存（落在 `plugins/.data/`） |

> `opts` 支持 `headers`（对象）。同名头只保留**第一个**。

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

