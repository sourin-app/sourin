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
| [../.agents/notes/](../.agents/notes/) | 决策记录：为什么这么选、放弃了什么、什么条件下该翻案（按 class 分目录，不设索引） |

### 构建与运行

| 文档 | 内容 |
|---|---|
| [BUILD.md](BUILD.md) | 前置依赖、编 Rust 核心、编 Flutter、Android 交叉编译、CI 与打包 |
| [RUNBOOK.md](RUNBOOK.md) | 发版、本机跑客户端（含 `-Dev` 数据播种）、排障的非显然步骤 |
| [TESTING.md](TESTING.md) | 跑测试、`native-media` 标签、测试纪律 |
| [PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md) | 目录结构 + 规模取数快照 |

### 功能与配置

| 文档 | 内容 |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | 分层、为什么业务逻辑在 Rust、FFI 契约 |
| [CONFIG.md](CONFIG.md) | 界面偏好 `ui-prefs.json`、环境变量、凭证注入 |
| [DATA-DIR.md](DATA-DIR.md) | 数据目录文件清单、备份与恢复、**开发模式的第二份数据目录** |
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

### 「本轮」的边界定义（2026-10-18 定，强制）

收尾 / 汇总类文档里的「本轮 N 个提交」**必须**用下面的方式计数，并附命令：

**本轮 = `<第一个带轮次标记的提交>^..HEAD`**

```bash
# 第 66 轮实例
git log --oneline 4fda18c^..HEAD | wc -l     # ⇒ 74
```

`4fda18c` = 「docs(round-66): 补第 66 轮计划」= 第一个 round-66 标记。

#### ❌ 不要用这些方式（均有实测偏差）

| 方式 | 问题 | 第 66 轮实测 |
|---|---|---|
| `--since="<本轮首日>"` | 卷进上一轮收尾提交 | 102（多 28） |
| `--since="<前一日>"` | 卷进整轮上一轮 | 98（多 24） |
| 目测 `git log` 输出 | 人眼数不准 | 「20 出头」（差 3.7 倍） |
| 看提交信息前缀推测归属 | 会把别人的提交算到别人账上 | 4 个提交归属错 |
| 「某文件被改了几次」等间接量 | 与提交数不是同一维度 | 263 |

#### ✅ 正确做法

1. `git log --grep="round-NN"` 找**第一个**带该轮标记的提交，记下 sha
2. 用 `<那个提交>^..HEAD` 计数（含该提交本身）
3. **归属核实必须看 `git show <sha> --name-only`**，不看提交信息前缀
4. 文档里写数字时**同时写命令**，让下一个人能复跑

> 为什么定这条：第 66 轮出现过 4 次数字错（20 出头 / 98 / 102 / 263），
> 根因都是**边界没定义**。数字本身不重要，**可复跑的计数口径**才重要。
