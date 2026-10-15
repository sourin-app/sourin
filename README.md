<div align="center">

# 源影 · Flutter

**跨端视频聚合客户端 —— Flutter 重写版**

[![构建](https://github.com/sourin-app/sourin/actions/workflows/build.yml/badge.svg)](https://github.com/sourin-app/sourin/actions/workflows/build.yml)
[![许可证](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Flutter](https://img.shields.io/badge/Flutter-3.47.5-02569B.svg)](https://flutter.dev)
[![Rust](https://img.shields.io/badge/Rust-1.85-000000.svg)](https://www.rust-lang.org)

Windows · macOS · Android · Android TV

</div>

---

## 这是什么

「源影」是一个**跨端视频聚合客户端**：把多个内容源（CMS 站点、内置站点、外部视频站、
Emby、公共直播源）聚合成一个界面，统一搜索、收藏、追更、播放与下载。

这个仓库是它的 **Flutter 重写版**，取代了最初的 Tauri + Vue 实现。重写的动机是
**播放内核**：原版跑在 WebView2 上，走 Media Foundation 解码，而 Windows 默认
不注册 HEVC 解码器 MFT（实测 61 个 MFT 里零个 HEVC）—— 用户一遇到 HEVC 就黑屏。
Flutter 版用 **media_kit + libmpv**（自带完整 FFmpeg，完全不碰 Media Foundation），
把这个问题从根上解决。

> **架构要点**：业务逻辑（数据源解析、插件沙箱、流代理、云同步、数据库）全部在
> Rust 里，Flutter 只做 UI —— 两侧通过 **Dart FFI** 直接调用，不经过任何 IPC 层。
> 这让 81% 的原版 Rust 代码被原样复用。

---


## 功能

### 内容聚合

| 能力 | 说明 |
|---|---|
| **多源聚合** | 内置站点 + 第三方插件 + 声明式 JSON 源 + HTTP 进程外源，统一成一个源列表 |
| **跨源搜索** | 一次搜索并发打全部源，**边搜边出**（流式返回，不等最慢的那个） |
| **跨源换源** | 同一部剧在别的源上也能看 —— 按标题相似度排序，带进度迁移 |
| **TVBox 直连** | 直接填 TVBox 配置**地址**或 JSON，内部解析成源，**不需要转换脚本** |
| **Emby / Jellyfin** | 登录、媒体库、直接播放 |
| **外部弹幕** | 从外部站导入弹幕（含分 P 绑定、自动更新） |
| **直播** | 插件提供的频道表、分组、上下键切台 |

### 播放

| 能力 | 说明 |
|---|---|
| **内核** | libmpv（media_kit），硬解 d3d11va / MediaCodec |
| **格式** | HEVC / H.264 / AV1、AC3 / DTS / AAC、ASS / SRT 字幕 |
| **字幕** | 内封轨切换、外挂字幕、ASS 样式（字号/颜色/位置）、Assrt 字幕库 |
| **弹幕** | 外部视频站弹幕、自定义弹幕服务器、速度/透明度/密度/区域可调 |
| **手势** | PC 与触摸两套（双击全屏、长按倍速、左右滑动跳转、上下滑音量/亮度） |
| **控件自动隐藏** | 鼠标停手 3 秒后**顶栏与底栏一起淡出**（同一个动画源），一晃动一起回来 |
| **画中画** | 独立窗口，可从播放页一键切出 |
| **投屏** | DLNA 投到电视（自动改写 m3u8 内嵌地址，电视直接能拉） |
| **遥控** | 手机当遥控器（局域网 HTTP + 二维码配对） |

### 下载

| 能力 | 说明 |
|---|---|
| **整片下载** | 把 HLS 播放列表里的**全部分片**拼成一个文件（不是存清单） |
| **按组存放** | 一部剧一个文件夹，落在 `视频/源影/<剧名>/` |
| **单集 / 全部集** | 详情页头部的「下载」菜单两个动作；全部集走**串行**队列 |
| **片段缓存** | 播放页「下载本集到缓存」，独立目录 + 上限淘汰 |

### 桌面集成

- **托盘图标** —— 单击打开、右键菜单（打开主界面 / 退出）
- **关闭确认** —— 首次点 X 问「最小化到托盘 / 彻底退出 / 取消」，选择被记住
- **自绘标题栏** —— 可拖动、双击最大化、贴边 Aero Snap、窗口阴影
- **窗口几何记忆** —— 下次启动回到上次的位置和大小（自动夹进工作区）
- **云同步** —— WebDAV 备份/恢复，多设备共享收藏与进度

---

## 快速开始

```bash
# 1. 拉代码 + 装依赖
git clone https://github.com/sourin-app/sourin.git
cd sourin && flutter pub get

# 2. 编 Rust 核心（cdylib）
cd rust/sourin_core && cargo build --release && cd ../..

# 3. 把核心放进 Windows 构建目录（CMake 会在构建时再拷进 runner）
Copy-Item rust\sourin_core\target\release\sourin_core.dll windows\

# 4. 编 Flutter —— ★ -t lib/shell.dart 不能漏（lib/main.dart 是早期 spike，不是产品入口）
flutter build windows --release -t lib/shell.dart
```

> ⚠️ **开发调试必须隔离真实用户数据** —— 加
> `--dart-define=DATA_DIR_OVERRIDE=<临时目录>`，否则一次写探针就可能改掉
> `%APPDATA%\app.sourin.player` 里的真实收藏与进度（见 [docs/CONFIG.md](docs/CONFIG.md)）。
>
> 前置依赖版本、Android 交叉编译、CI 与安装包打包，见 [docs/BUILD.md](docs/BUILD.md)。

---

## 文档

全部文档在 **[docs/](docs/README.md)**。开工前先读
**[docs/AGENTS.md](docs/AGENTS.md)**（开发硬约束）与
**[CONTRIBUTING.md](CONTRIBUTING.md)**（提交 / 评审 / 合并纪律）。

| 文档 | 内容 |
|---|---|
| [docs/README.md](docs/README.md) | 文档地图：我该读哪几篇 |
| [docs/AGENTS.md](docs/AGENTS.md) | 开发入口：环境、硬约束、工作流 |
| [docs/BUILD.md](docs/BUILD.md) | 从源码构建（含 CI、开发流程摘要） |
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | 架构与 FFI 契约 |
| [docs/CONFIG.md](docs/CONFIG.md) | 配置说明：界面偏好 / 环境变量 |
| [docs/DATA-DIR.md](docs/DATA-DIR.md) | 数据目录：文件清单、备份与恢复 |
| [docs/PLATFORMS.md](docs/PLATFORMS.md) | Windows / macOS / Android / Android TV |
| [docs/THEMES.md](docs/THEMES.md) | 主题包（JSON 配色） |
| [docs/PLUGINS.md](docs/PLUGINS.md) | 插件开发（QuickJS 沙箱） |
| [docs/TESTING.md](docs/TESTING.md) | 跑测试与门禁纪律 |
| [docs/DECISIONS.md](docs/DECISIONS.md) | 决策记录：为何这么选、何时该翻案 |
| [docs/RUNBOOK.md](docs/RUNBOOK.md) | 发版 / 运维 / 排障的非显然步骤 |
| [docs/FAQ.md](docs/FAQ.md) | 常见问题 |
| [docs/PROJECT-STRUCTURE.md](docs/PROJECT-STRUCTURE.md) | 目录结构与规模快照 |
| [PLAYER-CONTRACT.md](PLAYER-CONTRACT.md) / [INTERACTION-CONTRACT.md](INTERACTION-CONTRACT.md) | 交互契约（验收基准） |
| [MIGRATION-PLAN.md](MIGRATION-PLAN.md) | 从 Tauri 版迁移的功能对等计划 |

> 文档纪律（2026-10-15 定）：只写代码里读不出来的东西（why / 约束 / 陷阱 / 验收标准 /
> 非显然步骤）；每条带**日期 + 适用版本或 commit 范围**；**过期即删**，与代码同 PR 更新。
> 只对本机/本人成立的细节不进仓库（进项目记忆空间）。

---

## 致谢

- [media_kit](https://github.com/media-kit/media-kit) —— 播放内核
- [forui](https://github.com/duobaseio/forui) —— 桌面风格组件库
- [liquid_glass_widgets](https://pub.dev/packages/liquid_glass_widgets) —— 玻璃拟态
- [rquickjs](https://github.com/DelSkayn/rquickjs) —— 插件沙箱

---

## 免责声明

本项目**不提供、不托管、不分发任何影视内容**。它只是一个聚合客户端 ——
所有内容都来自用户自己配置的第三方数据源，播放地址由那些源提供。

请在你所在地区法律法规允许的范围内使用。

---

## 许可证

[MIT](LICENSE)
