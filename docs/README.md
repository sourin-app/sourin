# 文档地图

> 本目录是「源影 · Flutter」的开发文档集。根 [README.md](../README.md) 只保留定位、
> 快速开始与索引；细节全部在这里。
> 建立于 2026-10-15（原 README 拆分而来），正文未改写，只做搬家与索引。

## 我该读哪几篇

| 你是 | 先读 | 再读 |
|---|---|---|
| 第一次上手（人 / agent） | [AGENTS.md](AGENTS.md) | [BUILD.md](BUILD.md) → [ARCHITECTURE.md](ARCHITECTURE.md) |
| 要改代码 | [AGENTS.md](AGENTS.md) 的「硬约束」 | [CONTRIBUTING.md](../CONTRIBUTING.md)（流程与纪律） |
| 要发版 / 排障 | [RUNBOOK.md](RUNBOOK.md) | [BUILD.md](BUILD.md)、[DATA-DIR.md](DATA-DIR.md) |
| 要加内容源 / 主题 | [PLUGINS.md](PLUGINS.md)、[THEMES.md](THEMES.md) | [CONFIG.md](CONFIG.md) |
| 要核对「和原版一样吗」 | [PLAYER-CONTRACT.md](../PLAYER-CONTRACT.md)、[INTERACTION-CONTRACT.md](../INTERACTION-CONTRACT.md) | [MIGRATION-PLAN.md](../MIGRATION-PLAN.md) |

## 全部文档

### 入门与规范

| 文档 | 内容 |
|---|---|
| [AGENTS.md](AGENTS.md) | 开发入口：环境与命令、全仓硬约束、工作流、文档纪律 |
| [../CONTRIBUTING.md](../CONTRIBUTING.md) | **仓库的规矩**：PR 流程、评审纪律、假绿禁令、合并权限、自主推进 |
| [DECISIONS.md](DECISIONS.md) | 决策记录：为什么这么选、排除了什么、**何时该翻案** |

### 构建与运行

| 文档 | 内容 |
|---|---|
| [BUILD.md](BUILD.md) | 前置依赖、编 Rust 核心、编 Flutter、Android 交叉编译、CI 与打包 |
| [RUNBOOK.md](RUNBOOK.md) | 发版、本机跑客户端、排障的非显然步骤 |
| [TESTING.md](TESTING.md) | 跑测试、`native-media` 标签、测试纪律 |
| [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md) | 目录结构 + 规模取数快照 |

### 功能与配置

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 分层、为什么业务逻辑在 Rust、FFI 契约 |
| [CONFIG.md](CONFIG.md) | 界面偏好 `ui-prefs.json`、环境变量、凭证注入 |
| [DATA-DIR.md](DATA-DIR.md) | 数据目录文件清单、备份与恢复 |
| [PLATFORMS.md](PLATFORMS.md) | Windows / macOS / Android / Android TV（同一 APK） |
| [THEMES.md](THEMES.md) | 主题包（JSON 配色，零门槛） |
| [PLUGINS.md](PLUGINS.md) | 插件开发（QuickJS 沙箱、host API、安装） |
| [FAQ.md](FAQ.md) | 常见问题 |

### 验收基准（迁移期）

| 文档 | 内容 |
|---|---|
| [../PLAYER-CONTRACT.md](../PLAYER-CONTRACT.md) | 播放页交互契约（逐条带原版源码行号） |
| [../INTERACTION-CONTRACT.md](../INTERACTION-CONTRACT.md) | 全应用交互契约（验收基准） |
| [../MIGRATION-PLAN.md](../MIGRATION-PLAN.md) | 从 Tauri 版迁移的功能对等计划与规模盘点 |

## 写文档的纪律（2026-10-15 定）

1. **只写代码里读不出来的**：why、约束、陷阱、验收标准、非显然步骤。
   不要复述代码结构 —— 那种内容会随代码腐烂，且读者有 IDE。
2. **每条带日期 + 适用版本或 commit 范围**。没有适用范围的经验不是规范，是传说。
3. **过期即删**，与代码同 PR 更新。发现文档与代码矛盾时，先修文档再改代码。
4. **只对某台机器 / 某个人成立的细节不进仓库**（进本项目的记忆空间）。
   判据：换台机器 clone 下来，这条还成立吗？
5. **不得出现具体视频网站的名字**（仓库硬约束，见
   [CONTRIBUTING.md](../CONTRIBUTING.md) 的「规矩三」，有机械门禁 `test/t98_no_site_names_test.dart`）。
