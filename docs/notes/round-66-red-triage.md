# 第 66 轮全量测试红分类（redtriage）

> 口径：`git rev-parse HEAD` = **`0cad64a`**，工作树 `git status --porcelain` = **空**
> 基线 = 同一提交的纯净 worktree（`/d/tmp/r66-base2` @ `0cad64a`）
> 全量命令：`flutter test test/ --concurrency=1`（两边同参数）

---

## ★★ 最重要的结论先说：B 类（本轮引入）**= 0**

**判据**：
```
main HEAD  = 0cad64a63a2574db78a57873b11ba54e4073d654
base2 HEAD = 0cad64a63a2574db78a57873b11ba54e4073d654
git diff --stat 0cad64a 0cad64a  → 空
git status --porcelain           → 空
```
⇒ **基线树 == 主仓树，逐字节相同**。在「两边同一棵树」的前提下，
`B 类 = 基线绿 + 主仓红` 在逻辑上不可能非空。

⚠️ 这不是"没查出 B 类"，而是**这一轮的全量红与本轮改动无关**——
下面每一条都给了「本轮有没有碰过它」的独立证据（测试文件最后修改时间、`git log` 计数）。

★ 诚实标注一个**过程失误**：我第一次建的基线是 `3db70fb`，跑到一半发现主仓已推进到
`0cad64a`（14 个提交，含 R5/R6 前提修正）。**那份 `3db70fb` 的读数已作废**，
本文所有数字来自重建的 `0cad64a` 基线。若不重建，A/B 差集会混入 14 个提交的噪声。

---

## ① 基线 worktree 的非版本控制文件对齐清单

`git status --ignored --short` 共 **77** 条被忽略项。逐个判断「会不会改变测试行为」后，
只拷了这 5 类（其余是 `.claude/` 笔记、`.probe/`、`android/` 构建产物等，与 `flutter test` 无关）：

| 文件 | 为什么必须对齐 | 校验 |
|---|---|---|
| `libmpv-2.dll`（29.7MB，仓库根） | `dart_test.yaml` 明载：`MediaKit.ensureInitialized()` 加载它时 `flutter_tester.exe` 原生崩溃（c0000005）⇒ 决定「真跑 vs 崩」 | md5 `3a6bd0dc…` 两边一致 |
| `sourin_core.dll`（11.5MB，仓库根） | 核心 FFI 夹具；缺失 ⇒ `核心尚未启动` ⇒ 大量 `[SETTINGS] 加载失败` | md5 `666b2e09…` 一致 |
| `build/windows/x64/libmpv/libmpv-2.dll` | ★ **最容易漏的一个**：测试代码找的是这个路径下的夹具，不是仓库根那个 | md5 `3a6bd0dc…` 一致 |
| `.dart_tool/`（585MB） | 包解析缓存；不一致 ⇒ 依赖解析漂移 | 整目录拷贝 |
| `.flutter-plugins` / `.flutter-plugins-dependencies` / `pubspec.lock` | 插件注册表与锁文件 | 拷贝 |

**★ 这一步的效果可量化**（证明它确实改变了读数）：
```text
第一次基线（未拷 build/.../libmpv 夹具）：~132 skip
对齐后基线（拷了）：                      ~98 skip
```
差 **34** 个用例——它们在前者被 skip、在后者真跑。这正是 `dart_test.yaml` 里
「基线全绿 vs 当前红 = 假回归」那条坑的**量化形态**。

测试文件数也对齐了：`base2: 552  main: 552`（第一次是 547 vs 549，差 2 个未跟踪文件）。

---

## ② 基线读数

```text
22:01 +4726 ~98 -28: Some tests failed.
```
- 通过 **4726**
- skip **98**
- 失败 **28**

---

## ③ 主仓读数

**主仓 HEAD 已推进到与基线同一提交**（`0cad64a`），工作树干净。
主仓前一次全量（`3db70fb` 时代）读数为 `+4702 ~86 -27`，**已作废**（不是同一棵树）。

⇒ 在「同一棵树」口径下，主仓 == 基线：`+4726 ~98 -28`。
`-28` 的逐条分解见 ④。

---

## ④ A / B / C / D 四类清单

| 类 | 定义 | 条数 | 说明 |
|---|---|---|---|
| **A** | 基线红 + 主仓红（存量） | **28** | 见下表，全部为存量 |
| **B** | 基线绿 + 主仓红（本轮引入） | **0** | ★ 两边同一棵树，逻辑上不可能非空 |
| **C** | 基线红 + 主仓绿（本轮修好） | **0** | 同一棵树 |
| **D** | 两边都 skip | **98** | 抽检见 ⑤，其中**捞到 1 条躺在 skip 里的红** |

### A 类逐条（28 条，11 个文件）

按「**单跑是否复现**」再分两层 —— 这决定它是产品缺陷还是环境噪声：

#### A-1 确定性失败（单跑也红，共 22 条 / 7 文件）

| # | 文件 | 条数 | 失败形态（实测原文） | 本轮碰过吗 |
|---|---|---|---|---|
| 1 | `t75_browse_autoload_test.dart` | 9 | `Expected: <20> Actual: <0>` / `<40> vs <0>` / `Expected: <0.0> Actual: <231.08>` ⇒ 自动加载没触发 | 否（最后改 2026-10-11，本轮 0 提交） |
| 2 | `zz_t66_cs1_evidence_manifest_test.dart` | 5 | `★★★ 证据缺失：docs/notes/evidence/round-66-cs1/manifest.json 不存在` | **是**（本轮改过 1 次）⇒ 见下方「★ 唯一嫌疑」 |
| 3 | `t74_follow_title_backfill_test.dart` | 3 | 追更页「历史」tab 标题回填断言 | 否（2026-10-11） |
| 4 | `t36_pill_drag_follow_test.dart` | 2 | `pumpAndSettle timed out` | 否（2026-10-17） |
| 5 | `t80a_skeleton_fade_test.dart` | 2 | `★★ 轮询 61 帧仍未挂载 FadeInSliver —— 探针前提不成立（分支没走到）` | 否（2026-10-11） |
| 6 | `t526_qr_tab_test.dart` | 1 | `Found 0 widgets with text "二维码获取失败，请重试或切换到「其它方式」。"` | 否（2026-10-11） |
| 7 | `t74_perf_synth_test.dart` | 1 | `Expected: a value greater than <0>  Actual: <0>` | 否（2026-10-11） |

★ **唯一嫌疑**：`zz_t66_cs1_evidence_manifest_test.dart` 是本轮**新增**的门禁，
它要求的 `manifest.json` 从未被生成。这**不是**产品缺陷，是**证据文件没产出**：
```
docs/notes/evidence/round-66-cs1/  →  只有 README.md，无 manifest.json、无 PNG
```
修法（不用改代码，跑一条命令即可）：
```powershell
pwsh -NoProfile -File tools/e2e_shots.ps1 -OutDir docs/notes/evidence/round-66-cs1 -ManifestOnly -Criterion "<这一张证明什么>"
```

#### A-2 环境/时序失败（单跑绿，全量红，共 6 条 / 4 文件）

| # | 文件 | 条数 | 全量里的真实原因 | 判据 |
|---|---|---|---|---|
| 8 | `zz_cr_local_select_ui_test.dart` | 6 | `did not complete` ⇒ 原生崩溃 | 单跑 `+N All tests passed` |
| 9 | `task18_entry_test.dart` | 3 | `[SETTINGS] 加载失败: SourinCoreException(unsupported): 核心尚未启动` + 每条耗时 ~4 分钟（`09:27`→`09:31`）⇒ **超时**，不是断言 | 单跑 `+5 All tests passed`，12 秒 |
| 10 | `zz_t53s_settings_live_toggle_test.dart` | 1 | 同上（核心未启动） | 单跑 `+2 All tests passed` |
| 11 | `zz_t66_e2e_shots_survivor_test.dart` | 1 | 同上 | 单跑 `+6 All tests passed` |

全量日志里 `核心尚未启动` 出现 **156 次**——大量测试在核心未启动时会走降级分支并通过，
只有少数几条把它当硬失败。**这是既有测试基建的脆弱点，不是本轮引入。**

---

## ⑤ skip 统计 + 被 skip 的文件 + 抽检

```text
base2: ~98
grep -c "All tests skipped" base2.log  →  0
```
★ 与 `dart_test.yaml` 记载一致：**全量跑时这个计数恒为 0**，
skip 只体现为 `~N` 计数器 ⇒ 一条"确定会红"的过时断言可以躺很久（下面的抽检证实了）。

### skip 抽检（`--run-skipped --tags native-media`，5 个文件）

| 文件 | 结果 | 判定 |
|---|---|---|
| `skip_pair_grouping_test` | `No tests ran` / `No tests match the requested tag selectors` | 该文件**不带** `native-media` 标签 ⇒ 抽检命令对它无效（不是红） |
| `player_panel_wiring_test` | `+5 All tests passed` | ✅ 健康 |
| `pc_arrow_keys_test` | `+17 All tests passed` | ✅ 健康 |
| `live_referer_onwire_test` | `+1 All tests passed` | ✅ 健康 |
| **`player_episode_nav_boundary_test`** | **红 1 条**：`Expected: exactly one matching candidate` / `Actual: Found 0 widgets with text "下一集"` | ★★ **躺着的过时断言** |

### ★★ 抽检捞到的东西（这是本节最有价值的产出）

`player_episode_nav_boundary_test.dart` 用例「①-C 行为层：最后一集点「下一集」不得切集
★★★ 阳性对照：中间某一集点「下一集」**必须**切集」

它断言的 `"下一集"` **文本**在界面上找不到。而本轮 R6 的取证恰好记录了同一件事：
```text
player_page.dart:  showEpisodeNav: !_isLive && _episodes.isNotEmpty
                   hasNext: !_isLive && _nextEpisode != null
```
上一集/下一集按钮的渲染条件已经收紧（直播不画）。若点播路径也改成**图标按钮**
（无 `Text('下一集')`）或只在 hover 时出现，这条断言就会永久红——而它因为
`native-media` 标签**默认被跳过**，所以从来没人看到。

⇒ **建议**：这条要单独确认「按钮是否还在、只是不再有该文本」。若确实改为图标，
断言应改成按 `Key`/语义标签查找，而不是 `find.text('下一集')`。

---

## ⑥ `docs/notes/round-66-e2e-verify.md` 过期判据的行号 + 建议改法

★ **先更正一件事：你让我标的 R5/R6 那两条，已经被别人改过了**（提交 `791e04a`
「docs: 补两条判据设计坑 + 修正 e2e 清单里被推翻的 R5/R6 前提」）。现状：

| 行 | 现状 | 判定 |
|---|---|---|
| **56** | 已改为「R5 直播页内容溢出被裁」+「`Rect.bottom <= clip.Rect.bottom`」+ 实测 `n=4 ⇒ 溢出 15.3px` | ✅ **已正确**，无需再改 |
| **58**（新增 5b） | 已改为「R6 直播页没有假弹幕入口（这条前提曾被推翻）」+ `grep -c danmaku = 0` + 可交互控件数 = 3 | ✅ **已正确** |
| **59** | 「R5 控制条不越界」`Rect.bottom <= 视口高度 - 安全区`，窗口 1280×800 与 1024×640 | ⚠️ **仍偏弱**（见下） |
| **60** | 「R6 直播清晰度/线路分类」要求「**分组标题逐字为实际分类**；同一线路不得同时出现在两个分组」 | ❌ **仍然过期** |

### 第 60 行为什么过期（要改）

```text
「分组标题逐字为实际分类」这个判据，描述的是一个**不存在的 UI**。
实测：lineSwitcher（lib/ui/live_page.dart:3154）是**扁平 Wrap + _LineChip**，
      没有任何分组标题、没有分组容器。
（`live_page.dart` 里确实有"分组"，但那是**频道分组筛选** `_groupFilter`
  —— 用来筛直播频道，不是给播放线路分组。两者被混为一谈了。）
```
**建议改为**：
> **R6 直播清晰度：≥2 个非 DRM 可选档才画下拉，否则不画**
> 判据：① 1 档/0 档/全 DRM ⇒ 清晰度下拉控件数 = **0**；
> ② ≥2 档非 DRM ⇒ 下拉存在且选项数 = 非 DRM 档数；
> ③ 门禁 `zz_t66_r6_live_controls_test.dart` 全绿（含 D1/D2/D3 三档对照）。
> ⚠️ 现状补充：直播 `StreamCandidate.quality` **实测恒为 null** ⇒ 生产常态是**永远不画下拉**，
> 所以「打开线路列表看分组」这条路径**不存在**，不要按它验收。

### 第 59 行为什么仍偏弱（建议加强）

```text
现状判据：「控件条 Rect.bottom <= 视口高度 - 安全区」
问题：R5 的真实缺陷是 **chip 被 ClipRRect 裁**，而不是「控件条越出视口」。
      控件条（_EmbedBar）是 Positioned(bottom:0) 贴底的，它**永远不会**越出视口——
      这条判据在修复前后**都成立** ⇒ 它测不出 R5，属"恒真判据"。
```
**建议改为**：
> 窗口 900×600（Owner 实测断点）：chip 的 `Rect.bottom <= clip.Rect.bottom`
> **且** chip 行数 ≥ 2 时仍成立（单行时修复前也不溢出，测不出缺陷）。
> 已由 `zz_t66_r5_player_no_overlap_test.dart` R5-G 覆盖（9 条线路 = 2 行）。

---

## ⑦ 结论

```text
本轮是否引入红？  →  ★ 否（B 类 = 0）
```
**但请注意这个结论的强度**：它不是"查过了没有"，而是**两边是同一棵树**
（HEAD 相同 + 工作树干净），所以 A/B/C 差集在构造上就为空。

⇒ **要让这份分类真正有判别力，必须在"主仓有未提交改动"的时刻再跑一次。**
当前时点主仓已被提交干净，这一轮的全量红**全部是存量**。

### 我认为你该先修的三条（按影响面）

| 优先级 | 项 | 为什么先修 | 成本 |
|---|---|---|---|
| **1** | `zz_t66_cs1_evidence_manifest_test` 缺 `manifest.json`（5 条红） | 它是**本轮新增的门禁**，红着会长期污染全量读数；而且修法是跑一条命令，不用改代码 | 极低 |
| **2** | `player_episode_nav_boundary_test` 躺着的过时断言（1 条红，被 skip 隐藏） | ★ 它代表**一整类风险**：`native-media` 标签下的断言没人跑，坏了也不知道。这条已确认坏了 | 低（改断言） |
| **3** | `t75_browse_autoload_test` 9 条红 | 单文件红最多（占 22 条确定性红的 41%），且是「自动加载没触发」这种**用户可感**的行为 | 中 |

### 另：一条测试自身的问题（你特别要我留意的）

**`t80a_skeleton_fade_test` 自己说破了**：
```
★★ 浏览页：轮询 61 帧仍未挂载 FadeInSliver —— 探针前提不成立（分支没走到），不是"动画没播"
```
⇒ 探针**自己知道**前提不成立并抛了清晰的错，这是**好设计**（比静默假绿强）。
但它说明这条用例的**夹具与产品分支已经漂开**：浏览页的骨架→空态路径不再经过
`FadeInSliver`。要么产品分支改了（该更新探针），要么探针一直没对准（该重写）。
建议归到 C 类（断言过时）处理，而不是当产品缺陷查。
