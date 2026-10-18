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

  笔记树**进仓库**，与代码同批提交。CI 会在 Windows job 上跑
  `.agents/notes-scripts/` 里的三条校验（tree / format / archived），红即不许合。
  本地跑同样三条：

  ```bash
  npx --yes tsx .agents/notes-scripts/verify-agent-note-tree.ts
  npx --yes tsx .agents/notes-scripts/verify-agent-note-format.ts
  npx --yes tsx .agents/notes-scripts/verify-archived-agent-notes.ts
  ```

---

## 8. 当前已知的坑（保持精简，解决即删）

| 现象 | 原因 / 怎么办 |
|---|---|
| 改了 Rust 但行为没变 | 90% 是构建树里的 `.dll` 没换新。删掉包目录里的那个 `.dll` 强制重拷；或直接改 Rust 源让 cargo 真的重编 |
| `flutter test test/` 偶发 `did not complete` | `flutter_tester` 加载 libmpv 原生崩溃（第三方库）。判断「是不是我改坏的」时**先单跑那个文件** |
| Android 上所有命令都超时 | `jniLibs/*/libsourin_core.so` 是**手动拷贝**的产物，改过 `ffi.rs` 要重编三个 target 并重拷 |
| 深色主题「看不见字」但不报错 | 主题角色取值有回归门禁 `test/theme_regression_test.dart`（含 WCAG 对比度断言） |
| 开发版**不弹**更新窗（要验更新流程时） | 有意为之：开发/探针构建跳过启动检查（本地 HEAD 永远比线上新，弹了对开发者是纯噪声）。要验就手动点「设置 → 关于 → 检查更新」 |
| 开发版「忽略此版本」像没记住 | 「忽略」现在会**等到落盘才关窗**（`ignoreVersion` 返回 Future）。若仍旧弹，先看数据目录里 `ui-prefs.json` 的 `appupdate.ignoredVersion` 在不在 |
| **注入/替换脚本静默不生效**（`AssertionError: 0` / 改了没反应） | 四种常见原因，**注入前逐条排除**：<br>① **行尾不同（且 blob 与工作区不一致）** —— `lib/ui/live_page.dart` 是 CRLF、`lib/ui/player_page.dart` 是 LF。用 `\n` 匹配 CRLF 文件会失败，看起来像"注入无效" ⇒ **可能据此得出相反结论**（"门禁有效"）。注入前 `file <路径>`，或统一用 `\r?\n`。<br>★ 更隐蔽的一层（2026-10-18 实测）：`core.autocrlf=true` 会让 **blob 与工作区行尾不同** —— blob 里有 103 行裸 LF 的文件，检出后工作区是纯 CRLF。⇒ 同一处注入，**在 blob 上行为取决于位置、在工作区上行为一致**；而开发者编辑的是工作区，所以**在本地永远看不出来**（CI 上才会红）。<br>② **命中注释** —— 源码里的 JSDoc 引用了同一行代码，裸 `indexOf` 会先命中注释里的那份。⇒ 用「逐行扫描 + 剔除注释行」定位，不要用裸 `indexOf`。<br>③ **锚点已漂** —— 行号/变量名在几小时内会变（本轮实测：`player_page.dart` 的 truncated 使用点从 `:6263` 漂到 `:6322`）。⇒ 注入前重新 `grep`，不要把行号当稳定标识。<br>④ **注入把文件写坏了**（语法错误） —— `'\\r\\n'` 在 Python 里是真实换行，写进代码会把语句截断。现象同样是 `Some tests failed`，但那是**编译失败**，不是"门禁能红" ⇒ 什么都没证明。<br>★ 判据：**注入后先 `dart analyze <被注入的文件>` 必须 0 error，再看测试红不红**；还原后也要 analyze 一次（还原写坏会表现为"测试绿了"，更危险）<br>⑤ **还原忘了做**（注入残留在产品代码里） —— 本轮实例：验证「别处不许 pop」时插了一个 `_injectedBypass()`，忘了还原，`git status` 里 `lib/ui/player_page.dart` 一直是 modified。**这比前四种更糟**：注入代码进了产品，之后所有读数都不可信。<br>★ 判据：每轮注入-还原后立刻核对三条 —— `git status --porcelain <文件>` 必须空 / `sha256sum` 必须等于基线 / `dart analyze` 必须 0 error |
| **验证别人刚改的东西，报红说他没修好** | 先 `git status --porcelain <file>`。你可能跑在了对方**尚未提交的中间状态**上。本轮实例：`t73`/`t57` 在提交前一刻被看到红，差点被误报成"改了没修好" |
| **整文件被 `skip` 的测试里，断言过时永远暴露不出来** | `dart_test.yaml` 里 `native-media` 标签的测试默认跳过。★★ 它比"红"更隐蔽：<br>· 单独跑 ⇒ `+0 ~1: All tests skipped.`，至少有大字提示<br>· **全量跑 ⇒ `grep "All tests skipped"` 计数 = 0**，skip 只体现为 `~N` 计数器 +1（混在几十个 skip 里）<br>⇒ 一条"确定会红"的过时断言可以躺在这里很久。本轮实证：`t118:746` 用 `--run-skipped --plain-name "⑧"` 跑出 `Expected: true Actual: <false>`。<br>⇒ 定期 `--run-skipped` 跑一遍（代价：libmpv 偶发崩溃），或全量跑完统计 `~N` 逐个确认理由仍成立 |
| 修好一条断言后**以为就完了** | 修「假绿」时容易引入**新的假绿**。本轮实例：把 `contains('bool _userWantsPause')` 改成正则（方向对了），但新正则 `bool\??\s+` 里的 `?` 是**可选**的 ⇒ 两态三态都匹配，仍然只是存在性检查。<br>⇒ 修完**重新问"它现在测的是什么"**，而不是"我改完了"；并且**对新断言再做一次故障注入** |
| **工具修好后输出变成一串 `?`** | `.ps1` 的「ASCII 化」会抹掉中文文案。实测 `tools/live_probe_count.ps1` 的 19 处判定文案被替换成 `?`，而**语法 / 退出码 / 逻辑全部正常** ⇒ 工具照跑、照退出 0，但**人读不出结论**，而"让人判断 0 次是好是坏"正是它存在的唯一理由。<br>★ 判据：`grep -c "???" tools/*.ps1` 必须 = 0。<br>⇒ 面向开发者的工具，**输出文案一律用英文**，不要靠 BOM 或控制台代码页（PowerShell 5.1 用 ANSI 936 读无 BOM 的 `.ps1`） |
| **拿 `pumpWidget` 单独渲染某个页面/弹窗**（探针、门禁、降级验证） | ★★★ **先 `ClipDownloader.debugSetDataDir(<临时目录>)` 再渲染。**<br>有些页面在 `initState` 里读数据目录（`data_manage_page` / `backup_page` / `skip_page` 等），而 `ClipDownloader.dataDir()` 默认解析到**用户真实数据目录**（Windows 上是 APPDATA 下的 `app.sourin.player`，见 `clip_download.dart:598-605`）。<br>本轮实测：探针没注入就跑了一次。事后用 mtime（`13:18:49` vs 探针 `17:5x`）证明**本次没写** —— 但**「证明了没写」≠「这个做法可以接受」**：下一次可能是 `_scan` 改成写缓存、可能是另一个页面在 `initState` 里写、可能是别人复制了这份探针代码，运气不一定还在。<br>⇒ 注入点是现成的：`ClipDownloader.debugSetDataDir(path)`（`clip_download.dart:615`，`@visibleForTesting`），用完 `debugSetDataDir(null)` 收尾。<br>★ 覆盖 §3「跑测试必须隔离」：`DATA_DIR_OVERRIDE` 管的是 shell 启动路径，**管不到单独 `pumpWidget` 的页面探针** |
| **`pumpWidget` 后页面一直停在 loading，像是产品缺陷** | 先怀疑**仪器没驱动真实 IO**。`tester.pump()` 只推进 fake clock，**不驱动真实 Future**（文件系统 / 网络）。<br>本轮实例：`data_manage_page._scan()` await 真文件系统 ⇒ 纯 `pump` 永远等不到 ⇒ 判据读到 `loading=1`，差点被报成「打开数据管理页永久转圈」（假 P1）。<br>★ 关键细节：**不能**先 `pumpWidget` 再 `runAsync` 等待 —— Future 已在 fake clock 环境里创建，之后进 `runAsync` 也救不回来。必须把 **`pumpWidget` 本身**放进 `runAsync`：<br>`await t.runAsync(() async { await t.pumpWidget(...); for (...) { await Future.delayed(...); await t.pump(); } });`<br>⇒ 修正后 `loading=0`、`数据目录共占用` 正常出现。<br>★ 判据：凡「页面该完成异步工作却一直 loading」，先问「这个 Future 是在哪种 clock 里创建的」 |
| **用脚本改 Markdown 里的 Windows 路径** | Python 字符串里 `\a` 是 **BEL 控制字符**（`\x07`），`\r` `\n` `\t` 同理。本轮实例：往文档里写「APPDATA 下的 sourin 数据目录」这条路径，经 Python 处理后反斜杠和 `a` 一起消失，留下一个 BEL 字符，而 `grep` 常常匹配不到。<br>★ 更糟的连带事故：修的时候 `raw.find(b'\x07')` 返回 `-1`（其实已被修掉），切片 `raw[:i] + ... + raw[i+1:]` 于是变成 `raw[:-1] + ... + raw[0:]` ⇒ **整个文件被复制成两份**（21581 → 47886 字节）。<br>⇒ 判据与做法：<br>① 改含反斜杠的文本，**不要**手写 Python 字面量；用 `write`/`edit` 工具，或 `chr(92)` 拼。<br>② 脚本改完立刻验控制字符：`python -c "raw=open(p,'rb').read(); print([hex(b) for b in set(raw) if b<32 and b not in (9,10,13)])"` 必须输出 `[]`。<br>③ **任何 `find` 结果先判 `-1`** 再用于切片；`replace` 优先于切片。<br>④ 事故后从 git 恢复：`git checkout -- <file>`，再核 `wc -c` 回到原大小。 |
| **标了「未确定」就交付** | ★★ 「未确定」**可能是偷懒的别名**，而不是诚实。<br>本轮实例：审查报「弹窗内边距 `22` 是否合规」标为未确定，理由是"未与设计规范逐值核对"。实际一条 `grep -rn "abstract final class Sp" lib/` 就查到了 `lib/ui/tokens.dart:43` 的间距体系（`x1=4 x2=8 x3=12 x4=16 x5=20 x6=24 ...`）⇒ `22` **不在体系内**，且全仓仅此一处、无先例。**本来就不该标未确定。**<br>⇒ ★ 判据：**标「未确定」之前先问「我为它试过几条命令了？」**<br>· 试过 2~3 条仍定不了 ⇒ 真未确定，可以标，但**要写清试过什么**（"我查了 A、B、C 都不适用"）<br>· **0 条** ⇒ 那不叫未确定，叫**没查**<br>★ 为什么危险：它和真未确定**长得一模一样**，但真未确定会推动别人去查，假未确定会让责任人以为"已经处理过了"。它把**没做的工作**伪装成**已记录的边界**。 |
| **`analyze` / lint 只挑几个文件跑** | ★★ 覆盖不全的 lint 面会**掩盖真实发现**，而且报告看起来是"完整"的。<br>本轮实例：逐行自审 13 个文件（+1965 行），`analyze` 只跑了 theme / design 层，**漏掉范围内最大的 `lib/core/sourin_api.dart`（+335）** ⇒ 漏掉 **82 处 lint**（39 `dead_code` / 36 `dead_null_aware_expression` / 4 `invalid_null_aware_operator` / 3 `unnecessary_null_comparison`）和 **1 个 P2**：`jmap()` 返回非空 `Map<String,dynamic>`（遇 null 直接抛），但全文件对它写 `?? {}` / `?[` / `== null` ⇒ 那些兜底**永远走不到**。第一轮报告因此"完整但不正确"。<br>⇒ ★ 判据（可机械核对）：<br>`git diff --name-only <base>..HEAD -- <scope> | wc -l` **必须等于** `你实际跑过 analyze 的文件数`<br>数字不等 ⇒ 还没查完，不许下结论。<br>★ 顺序也对：**先全范围铺一遍 analyze，再逐项深入**；不要"挑几个文件跑，边看边决定"。<br>⚠️ 分类时注意：`jmap` 那 37 处里 **34 处是基线既有**、只有 3 处是本轮新增 ⇒ 报之前必须用 `git show <base>:<file>` 取基线做对比，否则会把存量问题算到本轮头上（或反过来漏掉本轮引入的）。 |
