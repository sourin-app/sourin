# 开发入口（人 / agent 都先读这篇）

> 2026-10-15 建立。适用范围：本仓库当前形态（Flutter + Rust 双栈，main 走 PR 保护）。
> 定位：**开工前 10 分钟**要读完的东西 —— 环境怎么跑、哪些线不能踩、交付长什么样。
> 流程细则在 [../CONTRIBUTING.md](../CONTRIBUTING.md)，**那是仓库的规矩，不是建议**。

---

## 1. 这个仓库是什么

「源影」是**跨端视频聚合客户端**：把用户自己配置的多个内容源聚合成一个界面，
统一搜索、收藏、追更、播放与下载。

```text
Flutter（lib/，只做 UI） ── dart:ffi 直调（无 IPC） ──► Rust 核心（rust/sourin_core，cdylib）
```

- **产品入口是 `lib/shell.dart`**。`lib/main.dart` 是早期 HEVC 验收 spike，**不是产品**。
  构建漏了 `-t lib/shell.dart` 会编出一个 spike，而**编错了不报错**（判据：`data/app.so` 大小）。
- 平台：Windows（主）/ macOS / Android 手机 / **Android TV（同一个 APK）**。
  任何 UI 改动都要考虑**鼠标悬停 / 触摸 / 方向键焦点**三种输入。
- 具体视频网站由**用户本地的插件**提供，仓库里不出现任何站名（有机械门禁，见 §4）。

细节：[ARCHITECTURE.md](ARCHITECTURE.md)、[PROJECT-STRUCTURE.md](PROJECT-STRUCTURE.md)。

---

## 2. 环境与命令（Windows / Git Bash）

**每条命令各自带 PATH** —— shell 状态不保留，上一行的 `export` 不影响下一行。

```bash
# 依赖版本（Flutter 3.47.5 / Rust 1.85+ / VS2022 / NDK 27.0.12077973）见 BUILD.md
flutter pub get

# Rust 侧
(cd rust/sourin_core && cargo build --release && cargo test)

# Dart 侧：只跑与你改动相关的文件，收尾再跑一次「你区域内的全部文件」
flutter test test/<相关文件>.dart --concurrency=1
flutter analyze lib            # 0 error；不要新增 warning
```

> ⚠️ `--concurrency=1` 必须带：多文件并行混跑会出现 `did not complete` 假红
> （`flutter_tester` 加载 libmpv 时原生崩溃，见 [TESTING.md](TESTING.md) 与 `dart_test.yaml` 顶部）。

### 跑客户端（本机）

```powershell
.\tools\run_client.ps1              # 编 + 跑（Release）
.\tools\run_client.ps1 -Rust        # 先 cargo build --release 再编再跑
.\tools\run_client.ps1 -Dev         # flutter run + 热重载 + 隔离数据目录
.\tools\run_client.ps1 -NoBuild     # 只跑，不编
```

脚本会把「`data/app.so` 大小」变成硬闸，编出 spike 就直接报错退出。
非 `-Dev` 的 Release 启动**会用真实数据目录**（产品正常行为）。

`-Dev` 起来前会调 `tools/seed_dev_data.ps1`，把你**真实数据目录里的内容**
（插件源码、收藏/历史/进度、界面偏好）播一份到隔离目录 —— 否则开发环境是空的，
插件调试、追更、播放进度一条都验不了。播种是**单向的**：

```powershell
.\tools\seed_dev_data.ps1 -Target "$env:TEMP\sourin-dev"            # 手动播一次
.\tools\seed_dev_data.ps1 -Target D:\tmp\dev -Force                # 覆盖式重播
```

⚠️ 两条硬约束（由 `test/zz_t1015_dev_seed_test.dart` 守着）：

```text
· 只读真实目录：跑完源目录必须逐文件哈希不变（脚本里没有任何一行写源目录）
· 凭据一律不带：sync-settings.json / remote-pref.json / plugins/.data/ 都不拷；
  ui-prefs.json 按 key 过滤（分P绑定、测速历史、源级偏好都留在真实目录里）
```

---

## 3. 用户数据安全（违反任何一条都是事故）

```text
· 绝不读写 %APPDATA%\app.sourin.player          ← 用户的真实收藏 / 进度 / 片头片尾 / 凭据
· 绝不在 <用户目录>\Videos\源影 里建 / 改 / 删    ← 用户的真实缓存视频
· 跑测试必须隔离：--dart-define=DATA_DIR_OVERRIDE=<临时目录>，并清掉沙盒 ui-prefs.json
  里的 dsh.download.dir（它只决定从哪读偏好，**不校验**里面的真实下载路径）
· 要真机启动：APPDATA / USERPROFILE 都指到临时目录，加 SOURIN_NO_REMOTE_AUTOSTART=1
· 只结束**你自己启动的 PID**（taskkill //PID <pid> //F），绝不按进程名批量杀
· 不碰 Windows 凭据管理器里的真实凭据；不拷真实数据目录里的 sync-settings.json /
  remote-pref.json / plugins/.data/（含凭据，且会自动同步或占端口）
  ★ 唯一例外是 tools/seed_dev_data.ps1 的**只读**播种：它读真实目录、只往隔离目录写，
    且上面三样**仍然不拷**（ui-prefs.json 也只搬界面偏好，按 key 过滤）
```

· 只读纪律：「看代码」≠ 下载/安装/运行 —— 复核源码只读源码与仓库元数据，禁下载 release
  产物、禁解压、禁运行 exe，不得让被测软件写注册表或用户目录；确需实际运行先要用户授权，
  误装误跑立刻还原并如实汇报
数据目录的完整清单见 [DATA-DIR.md](DATA-DIR.md)。

---


## 3.5 弹窗外壳统一规范

所有弹窗必须走 AppDialogShell（lib/ui/widgets/app_dialog_shell.dart），
不许各写各的 Container + Material + 标题栏。

```text
宽度      默认 560；窄弹窗 460、宽版面 820 需显式传 width 并注释原因
最大高度  绝对值 620，再按视口夹取（maxHeight 可覆盖）
圆角      Radii.rLg
标题栏    title + subtitle + 右侧关闭 IconButton
内容区    SingleChildScrollView，padding fromLTRB(Sp.x6, 0, Sp.x6, Sp.x2)

⚠️ 2026-10-17（CodeRabbit CR）：上面两条**改前写的是**
   「视口高度 * 0.8」与「fromLTRB(Sp.x6, Sp.x3, Sp.x6, Sp.x4)」，
   与 app_dialog_shell.dart 的实际实现不符 —— 那是**实现先改、文档没跟上**：
   ```text
   _kMaxHeight = 620（绝对值）
     原因：「视口 × 0.8」在 800×600 的测试视口下只有 480，比改前的 620 更矮，
           内容被挤、t70 的 3 条 tap 测试红。0.8 那个数是拍的，没依据。
   padding = fromLTRB(x6, 0, x6, x2)
   ```
   ★ 本节的数**一律以外壳代码为准**；改外壳的间距/高度必须同步改这里，
     否则新弹窗会按过期的文档写，重现同一批失败。
底部操作  可选 actions，与内容区分隔、按钮靠右
```

间距一律 Sp.x*、圆角一律 Radii.*、字号一律 FontSizes.*，禁硬编码。
新增控件优先用 material_ui 框架控件，SwitchListTile / ChoiceChip / FilterChip 等，
非必要不手写。

背景：改前 7 个弹窗宽度有 460 / 560 / 620 / 820 四种、高度有 620 / 640 / 740 三种，
全凭各写各的；showAppDialog 只统一动效、不管样式，所以样式必须靠外壳组件收拢。


## 4. 全仓硬约束（写代码前必须知道）

| 约束 | 判据 / 门禁 |
|---|---|
| Material 一律 `import 'package:material_ui/material_ui.dart';` | `lib/` 里**不许出现** `package:flutter/material.dart` 这个字面量（注释里写也算，必须用反引号包住） |
| 不再新增 forui 用法（FTheme / FScaffold / FButton…） | 取色走 `Theme.of(context).colorScheme` 或 `lib/ui/tokens.dart` |
| 间距 / 圆角 / 字号 / 动效走 token | 不许硬编码 `Duration`；弹窗统一走 `showAppDialog`，不用裸 `showDialog` |
| 用户可见文案不许出现开发过程用语 | 「修复」「缺陷」「task-xx」「Owner」「探针」「踩坑」「已知问题」等 |
| **仓库里不许出现任何具体视频网站的名字** | `test/t98_no_site_names_test.dart`（含 git 历史与提交信息） |
| 测试不许为变绿而放宽 / 删断言 / 加 skip | 行为有意改变时改断言**新行为**，且新断言在旧行为下必须变红 |
| 新增公开 API 必须同时给出**调用点** | 否则按死代码处理；例外要在提交信息或注释里写明「为什么现在不接」 |
| 高频状态用 `ValueNotifier` / `ValueListenableBuilder` 局部重建 | 别在每次鼠标移动时 setState 整页；列表虚拟化；大图给 `cacheWidth` |

### ★★★ 两条最容易犯的硬规矩

**① 写了 ≠ 接线了。** 定义常量 / 函数 / 开关**不等于**它被接上。交付前自问：

```text
1. 我改的这条路径**真的会执行到**吗？有没有第二个调用点 / 另一分支 / 另一平台没跟上？
2. 我依赖的既有机制**真的在起作用**吗？有没有被缓存 / 预建 child / static final 提前读走？
3. 我的判据会不会**恒真 / 恒假**？有没有混进每次都变的字段（position / 时间戳 / 随机数）？
```

**② 门禁不许「同一个源比同一个源」。** 门禁必须读**真实结果**（element 树 / 渲染结果 /
落盘数据），不能读喂进去的那个值。**判定方法**：把要防的缺陷**人为还原**，门禁**必须变红**；
还原后仍绿 ⇒ 假绿 ⇒ 必须重写。交付报告里要给出这次「撤销验证」的读数。

> 完整案例与五种假绿形态见 [../CONTRIBUTING.md](../CONTRIBUTING.md) 的「⑥ 两条硬规矩」。

---

## 5. 工作流

```text
① 开分支     git switch -c feat/<短描述>      （docs/ fix/ ci/ chore/ 同理）
② 做完一项   git commit（一个 PR 可以多个 commit；提交信息写「为什么 + 怎么验证的」）
③ 推送 + PR  git push -u origin <branch> → GitHub 上开 PR
④ 自动评审   CI 跑起来；CodeRabbit 几分钟内贴评审（触发条件：App 已装 + 目标 main + 非草稿）
⑤ 完善       逐条判断：真问题就修；误报就回帖说明并 resolve（不许用 ignore / 放宽断言消掉）
⑥ 再评审     推新 commit 后自动复审增量
⑦ 合并       ★ 必须等 Owner 明确说「合并」—— CI 绿了也不许自己合
```

- **`main` 有分支保护**，直推会被服务端拒绝（GH006）。
- **提交粒度：做完一项就推**（攒批会让评审者一次看几千行、二分定位不了）。
- **一条 PR = 一个功能域**（不设行数上限；判据是标题描述的是不是**一件事**）。
- **`git add` 一律显式列路径**，禁止 `git add -A` / `git add .`。
- **提交前清理敏感信息**：本机绝对路径、真实凭证、真实用户名。
  隐私检查要扫**整棵已发布树**（`git grep -n -E '<本机标识>' HEAD -- .`），
  只扫本次 staged diff 证明不了历史干净。
- 子 agent 分工时**写入范围是一等公民**（谁的目录谁改，避免互相踩）。

---

## 6. 交付与汇报

**默认推进到做完为止，不中途问**。只有这四种情况才停下问 Owner：
物理上做不到 / 破坏性且不可逆 / 涉及钱或对外发布 / 两种做法代价相当且无法用实测区分。

因为中途不问，**最后一次汇报必须完整**：

```text
· 做了什么（逐项）
· 每项的判据读数（命令 + 实测输出，不是「应该没问题」）
· 过程中发现并自行处置的问题
· 明确列出「没做的」及原因 —— 不许把没做的混进「已完成」
```

**验证纪律**：编译过 / 单测绿 / SHA256 都**不算**实测。「完整跑实测」= 本轮 diff 影响到的功能**逐条真跑**（实机 / 真请求 / 真数据）。
改动攒完后**统一跑一次**（一次构建 + 部署 + 实机验证），不要每改一处验一次。
工作树里存在在途未提交改动时，「在某个提交上跑测试」实际测的是**工作树** ——
要证明「修复前应当红」的红基线，必须用 `git worktree add` 检出纯净副本再跑。

### ★★★ 收尾必做：真机隔离启动一次

```text
★ 判据：全量 flutter test 全绿 **不足以**说明产品能用。

2026-10-18 实测（第 66 轮）：
  全量 flutter test ⇒ **4131 通过**
  但产品 Release 启动后**第一次弹窗就崩**：
    Null check operator used on a null value
    #0 MaterialLocalizations.of (material_ui/src/material_localizations.dart:718)
    #1 new DialogRoute        (material_ui/src/dialog.dart:1906)
    #5 showAppDialog          (ui/widgets/overlay_motion.dart:324)
  ⇒ 4131 个用例**没有一个**抓到它，因为它只在真机触发。
```

做法（收尾时跑一次，约 3 分钟）：

```bash
flutter build windows --release -t lib/shell.dart   # ★ 别漏 -t
# 隔离数据目录启动（不用真实数据目录）
export APPDATA="<临时目录>/appdata" USERPROFILE="<临时目录>/userprofile"
export SOURIN_NO_REMOTE_AUTOSTART=1
build/windows/x64/runner/Release/sourin_spike.exe &
```

必须确认三件事：

```text
① 日志里**零** `Unhandled Exception`（不是"看起来没崩"，是 grep 计数 = 0）
② 窗口完整渲染（截图留档，界面改动要亲眼看过）
③ 触发一次弹窗（更新窗 / 设置页任一对话框）—— 这是最容易漏的路径
```

⚠️ 清理：exe 会 fork 子进程，`taskkill //PID $!` 杀不掉父 PID。
用「启动前后 PID 差集」精确清理，或 `Get-Process sourin_spike | Stop-Process`。

**报告纪律**：回归报告必须写明覆盖范围，例如
「本报告只覆盖 `flutter test` + `cargo test`，**不含真机启动验证**」——
**先报「我验了什么」，再说「结论是什么」。**

---

## 7. 文档纪律

- 开工第一步：**先找文档**（`README.md` / `docs/` / `CONTRIBUTING.md`；同一仓库本次已确认过就不重复找）。
- **只写代码里读不出来的**：why / 约束 / 陷阱 / 验收标准 / 非显然步骤。
- 每条带**日期 + 适用版本或 commit 范围**；**过期即删**，与代码同 PR 更新。
- **只对本机 / 本人成立的细节不进仓库**（进项目记忆空间）。判据：换台机器 clone 下来还成立吗？
- 与代码矛盾或过期属**实质性不合规** ⇒ 停下来先修文档，再动代码。
- 地图见 [README.md](README.md)（本目录）；发版排障记 [RUNBOOK.md](RUNBOOK.md)。
- **决策全在 Agent Note 树，只有这一处出口**：

  ```text
  .agents/notes/{proposed,implemented,rejected,archived}/{class}/yyyy-mm-dd-主题.md
  ```

  `class` 是封闭集 6 个：`feature` / `bug-fix` / `simplification` / `architecture` /
  `process` / `testing`（`refactor` 不单列）。骨架固定：
  `## Problem` → `## Decision` → `## Alternatives considered` → `## Consequences`
  （「何时该翻案」写在 Consequences 里）。

  **必须写**：改了行为 / 架构 / 跨文件契约 / 流程与工具链 / 测试策略 /
  落盘、网络、配置格式。**免写**：格式化、错别字、改名、不改行为的样式与依赖补丁、
  常规 CRUD。判不准时从严。

  **不建索引**（`INDEX.md` 会被校验脚本直接拒绝）—— 手写索引不会随笔记增删更新，
  失效时是静默的。找笔记按意图直切目录，或全文检索：

  ```bash
  ls .agents/notes/implemented/architecture/
  rg --hidden --glob '!.agents/notes/archived/**' "关键词" .agents/notes/
  ```

### 7.1 笔记是「现行法律」，不是流水账

> 2026-10-20 按上游 `agent-notes` 规范（`write-notes-like-deepseek`）补齐。
> 上面几节只讲了「什么该写」，这一节讲**已有笔记怎么维护** —— 缺了它，
> 笔记树会退化成一份按时间堆积的变更日志。

**① 优先就地同步事实，非必要不新建。**
既有笔记守护的模块演进了、但核心决策没被推翻 ⇒ **直接改那篇的事实**
（路径、类名、默认参数、行号）。在文末追加 `### 2026-xx-xx 更新：…` 是**错的** ——
任何人打开这篇笔记，看到的都该是 HEAD 的绝对事实，而不是一段历史。

**② 时态永保现在时。** 写「系统用 SQLite 做持久化」，不写「系统不再用 JSONL，现在用 SQLite」。
门禁只拒提案式标题，现在时靠这条纪律，不靠词法扫描。

**③ 决定或理由翻转 ⇒ 新开一篇并互链，禁止改写 `## Decision` 成反面。**
事实可以就地改，**决定不能**。否则 git 就成了旧理由的唯一副本，
而读代码的人不会再去看 git log。

**④ 写新笔记前当场审计，禁止推迟。** 按模块名/关键词搜
`proposed` + `implemented` + `rejected`，每篇命中当场分类：
无关 / 部分重叠（互链）/ 完全吸收（吸收后删或归档）/ 过时提案（reject 或删）。
分类结果与新笔记**一起落盘**。

**⑤ 新笔记必须声明与既有笔记的关系**（CI 门禁 `notes-supersession.mjs`）。
三种合法路径，满足其一即可：

```text
· 正文里有指向既有笔记的相对链接      → 表示它接在某个决定之后
· 正文写 `Independent: <理由>`        → 表示确实无关（给理由这个动作会逼你真去查一遍）
· 它本身是 proposed / rejected        → 想法与否定阶段允许孤立
```

**⑥ 取代：部分重叠 vs 完全吸收。**

```text
部分重叠  两篇都留，双方加相对链接；只更新仍成立的事实。禁止归档。
完全吸收  先把旧篇的独有内容（安全边界、否定性保证、失败场景、
          重新引入条件、验证缺口）搬进新篇，再二选一：
            · 删     —— 新篇已吸收全部独有内容，且入站链接改完
            · 归档   —— 旧篇还有独立杠杆时用 archive-agent-note.ts
          归档篇只插 `Archived:` 一行；**指针写在新笔记里，不写进归档篇**。
```

  笔记树**进仓库**，与代码同批提交。CI 会在 Windows job 上跑
  `.agents/notes-scripts/` 里的三条校验（tree / format / archived），红即不许合。
  本地跑同样三条：

  ```bash
  npx --yes tsx .agents/notes-scripts/verify-agent-note-tree.ts
  npx --yes tsx .agents/notes-scripts/verify-agent-note-format.ts
  npx --yes tsx .agents/notes-scripts/verify-archived-agent-notes.ts
  ```

  另有两道 CI 门禁，本地也能跑（`--range` 给提交区间）：

  ```bash
  node .agents/notes-scripts/notes-coverage.mjs    --range HEAD~1..HEAD
  node .agents/notes-scripts/notes-supersession.mjs --range HEAD~1..HEAD
  ```

  **软报告**（不进 CI，退出码恒 0；只在排查锚点/看进度时用）：

  ```bash
  npx --yes tsx .agents/notes-scripts/check-note-anchors.ts   # 源码里 // Note: 锚点体检
  npx --yes tsx .agents/notes-scripts/build-board.ts --init .probe/board.html "源影决策看板"
  ```

  ★ 脚本与模板的权威副本在 `.agents/notes-scripts/`（含 `templates/`）。
  更新方式是整体同步，不要手改单个脚本 —— 三个 verify 脚本的口径必须与笔记同版本，
  否则本地绿、CI 红。

---

## 8. 当前已知的坑 → 见 [PITFALLS.md](PITFALLS.md)

> 2026-10-21 拆出：坑表已长到 46KB，占本文件的 71%，
> 触发 workspace 指令预算截断 —— **末尾条目加载不到**，等于对着空气写。
> 拆出后本文件只留**开工必读**，坑表作为**查询台账**放 [PITFALLS.md](PITFALLS.md)。

台账按「你什么时候需要它」分三组（不按时间排序）：

| 组 | 什么时候看 | 里面是什么 |
|---|---|---|
| **A. 判据设计** | 要写/改任何门禁、报告、检查脚本 | 恒真/恒假、作用域错配、覆盖度静默、判据只到结论不到原因、约束方向不对称、先测报错率、缺X vs 被跳过、给魔数编叙事、门禁不能import被检查项、两判据互相排斥、测量越精密越不问对象、副本必漂移、??兜底注入无效、同统计量相等量的是背景、需不需要做X≠X不存 |
| **B. 取证与验证** | 要声称「修好了 / 没坏 / 不是我的问题」 | 假绿形态、验证别人的改动、skip 区恒红、证据碎片、取证被遮挡、报告里的「可能」、搜索范围假设、改了什么vs看到什么、论证门禁的文档被门禁扫、比对不一致是转换的证据、动真实数据用标志位、审计盲区是别人的产物、更新状态时删掉独有证 |
| **C. 环境与工具链** | 命令行为异常、测试莫名红、脚本静默失效 | 注入无效的 6 种形态、BOM、复制粘贴、环境变量回退链、图标字体缺失、改模板vs已发布副本、日志说选了A≠看到A、找不到先排除不该出 |


> 三组**各有几条**不在本文件复述 —— 数字只有一个出处：`docs/PITFALLS.md` 顶部汇总表，由 `tools/count_pitfalls.py` 从台账本身算出来，CI 每次核对（不一致 ⇒ 红）。★ 本文件曾经手抄过一份（A17/B19/C28），三处都是错数，且没有任何东西在看它。

**三条最常复发的**（背下来比查表快）：

```text
① 写了 ≠ 接线了。定义常量/函数/开关 ≠ 它被接上。
   自问：这条路径真的会执行到吗？我的判据会不会恒真/恒假？
② 门禁不许「同一个源比同一个源」。
   验证方法：把要防的缺陷**人为还原**，门禁**必须变红**。
③ 判据输出必须能区分「查了没问题」与「没查/我坏了」。
   门禁必须打印覆盖度（查了 N/M 处）。只打「✅ 通过」视为未完成。
```

完整案例与五种假绿形态另见 [../CONTRIBUTING.md](../CONTRIBUTING.md) 的「⑥ 两条硬规矩」。

---

## 9. 本文件与 PITFALLS.md 的分工（改之前先读）

```text
AGENTS.md   开工 10 分钟必读：怎么跑、哪些线不能踩、交付长什么样
PITFALLS.md 干活时查：遇到怪现象 / 写门禁前 / 报结论前
```

**为什么拆**：本文件曾把 39 条坑内联在 §8，长到 46KB。
workspace 会把超过预算的指令文件**截断**，而截断发生在**末尾** ——
结果是最新写的几条坑谁也读不到，而作者以为「我写进 AGENTS.md 了」。

⇒ ★ 判据：**任何会被自动加载的指令文件，改完要确认「末尾读得到」。**
  判据不是「我写入成功」，而是「它在我下一次被加载时还在」。

新增坑的规则：

```text
· 加进 PITFALLS.md 对应组的**表头之后**（最新在上）——不要加在表尾
· 解决即删；过期的条目比没有更糟（它会让人按过期结论行事）
· 只写代码里读不出来的：why / 陷阱 / 判据
· 每条带日期
```
