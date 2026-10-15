# 数据目录

> 本文原为根 [README.md](../README.md) 的「数据目录」一节，2026-10-15 拆分到 `docs/`，正文未改写。
> 文档地图见 [docs/README.md](README.md)；开发硬约束见 [docs/AGENTS.md](AGENTS.md)；
> 提交与评审纪律见 [CONTRIBUTING.md](../CONTRIBUTING.md)。

---

# 数据目录

按平台自动解析（`lib/shell.dart` 的 `_resolveDataDir()`）：

| 平台 | 路径 |
|---|---|
| Windows | `%APPDATA%\app.sourin.player` |
| Android | 应用私有目录（`path_provider` 的 `getApplicationSupportDirectory()`） |
| macOS | `~/Library/Containers/app.sourin.player/Data/app.sourin.player` |
| Linux | `$HOME/app.sourin.player` |

> Windows 上**与原版 Tauri 用同一个目录** —— 这样从原版迁过来的用户，
> 收藏 / 历史 / 进度 / 插件全都还在。

> ⚠️ **macOS 那行按文档推断，未经真机核实**（本机没有 Mac）——
> 依据是 Apple 的 App Sandbox 文档与微软的 Mac Catalyst 文档都写着
> 「沙箱内 `$HOME` 解析为 `~/Library/Containers/<bundle-id>/Data`」。
> 真机跑一次 `echo $HOME` 就能确认；若实测不是这样，**以实测为准**并回来改这一行。
>
> 它之所以长这样，是因为**沙箱会把 `$HOME` 重定向**：
> 桌面端分支用的是 `Platform.environment['APPDATA'] ?? Platform.environment['HOME']`
>（`lib/shell.dart` 的 `_resolveDataDir()`），而 macOS 版**开着 App Sandbox**
>（`macos/Runner/*.entitlements` 的 `com.apple.security.app-sandbox`）⇒
> `$HOME` 不再是 `/Users/<你>`，而是
> `~/Library/Containers/<bundle-id>/Data`。
> 又因为代码会再拼一层 `app.sourin.player`，所以最终落在
> `Data/app.sourin.player`（目录名重复一层是正常的，不是 bug）。
>
> Linux 上同理：那里没有 `APPDATA`，于是取 `HOME` 直接拼 ——
> **不是** XDG 的 `~/.local/share`。

## 数据目录里都有什么

```text
%APPDATA%\app.sourin.player\
├── dsh-media.db                SQLite：收藏 / 历史 / 进度 / 片头片尾 / 追更
├── dsh-media.db-wal            预写日志（正常，别删）
├── ui-prefs.json               界面偏好（见 [CONFIG.md](CONFIG.md)）
├── provider-order.json         源排序
├── disabled-providers.json     停用的源
├── third-party-providers.json  第三方源
├── tvbox-sources.json          TVBox 订阅来源
├── remote-pref.json            手机遥控配置
├── sync-settings.json          WebDAV 配置（不含密码）
├── themes/                     主题包目录（*.json，见 [THEMES.md](THEMES.md)）
│   └── *.json                  自定义配色
├── plugins/                    插件目录
│   ├── *.js                    插件源码
│   └── .data/*.json            插件私有数据（含凭据，注意保护）
├── logs/                       按天滚动的日志
├── mpv-cache/                  播放缓存
├── clip-cache/                 片段下载缓存
└── transcode/                  转码临时文件
```

## 备份与恢复

三种方式，按需求选：

| 方式 | 在哪 | 覆盖范围 |
|---|---|---|
| **应用内导出 / 导入** | 设置 → 备份与恢复 | 收藏 / 历史 / 进度 / 源 / 插件 / 偏好（**合并不覆盖**） |
| **WebDAV 云同步** | 设置 → 云同步 | 同上，多设备 |
| **手动拷目录** | 直接复制整个 `app.sourin.player` | 全部（含缓存） |

> **导入是合并语义，不覆盖**。同一个源 / 同一条收藏已存在时保留**较新**的那份 ——
> 所以「导入旧备份」不会把你现在的进度退回去。
