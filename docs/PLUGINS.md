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
