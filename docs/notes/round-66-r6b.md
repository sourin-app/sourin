# 第 66 轮 R6-b：全屏播放页直播态的弹幕开关

> 角色：实现 + 自证。只改 `lib/ui/player_page.dart`、`lib/ui/player/player_bottom_bar.dart`，
> 新建 `test/zz_t66_r6b_live_toggle_test.dart`（本文件）。
> 时间：2026-10-20。基线 HEAD = `f273107`。

---

## 结论先行

**直播态那两枚弹幕控件（开关 + 齿轮）整块不渲染；`_toggleDanmaku()` 与唯一的请求叶子
`_loadDanmakuNamed()` 都加了直播守卫 ⇒ 直播间发出去的 `/api/v2/match` 请求数 = 0。**
判据分三层，默认跑的一层 `+6 ~2`、带 `native-media` 的一层 `+2`，四组故障注入各自真红。

---

## 1. 现状核实（我核到的 / 推翻的）

| 事实 | 核实结果 |
| --- | --- |
| 直播态 `_toggleDanmaku()` 无 `_isLive` 守卫 | ✅ 确认（改前方法体第一行是 `final next = !_danmakuEnabled;`） |
| `_danmakuFileName` 的直播分支把频道名当番剧名 | ✅ 确认（=`_liveTitle` 去扩展名） |
| wire 上唯一请求是番剧按文件名匹配 | ✅ 确认：`/api/v2/match` 是 `lib/core/danmaku.dart` 里唯一的匹配调用 |
| 失败根因是「缺凭证 ⇒ 403」 | ❌ **推翻**：实测 400，服务端不认这个"番剧名"；注释那句 403 是另一条分支 |
| 「弹幕 !」是底栏按钮 | ❌ **推翻**：底栏开关只是图标；`弹幕 !` 是顶栏 `_DanmakuInfoChip`（`_danmakuError != null` ⇒ `坏?` 分支） |
| 只有开关这一扇门 | ❌ **推翻**：起播时 `unawaited(_loadDanmaku())` 直接调叶子，**绕开开关**；面板里的 `_setDanmakuEnabled(true)` 也是第二扇门 ⇒ 只拦开关拦不住 |
| `player_page.dart` 那段注释已过期 | ✅ 确认（还写着"常驻 + disabled + 必须看得见原因"的第 3 代口径，代码是第 4 代"整条不渲染"）⇒ 已在本轮更正 |

## 2. 裁决：不渲染（不是渲染但禁用）

两条同仓先例口径一致：

1. **R6 裁决①**（`test/zz_t66_r6_live_controls_test.dart`）：入口从来不存在时**不画控件 + 一句可解释说明**。
2. **底栏自己**（`player_bottom_bar.dart` 的 `if (showEpisodeNav)`）：直播没有上一集/下一集 ⇒
   一对按钮**整块不出现**；而 `enabled:` 只用于"能力在、此刻不可用"（首集时上一集变灰）。
   直播是**根本没有这条路**，灰着只会把"没有"画成"坏了"。

⇒ 沿用「不渲染」。**说明句**仍由播放页原有的那条给出（底栏之外，`LiveEmbeddedPlayer`
在嵌入式播放里画「这个来源暂无弹幕」，本轮未改它，也未新增第二处）。

## 3. 改了什么

**(a) `lib/ui/player/player_bottom_bar.dart`** —— `_actions()` 里把开关 + 齿轮两枚
`_BarAction` 整块包进 `if (!isLive) ...[`，并写清为什么不是 `enabled:`（改前 `@@ -626,55 +626,73 @@`）。

**(b) `lib/ui/player_page.dart`** —— 四处：
1. `_moreMenuGroups()`：直播态整组 `if (!_isLive) MoreMenuGroup('弹幕', [...])` ——
   空组只会画一个孤立标题（`PlayerMoreMenu.build` 对每组无条件画 label），且
   组名字面量保留（两处源码门禁按字面量断言）。
2. `_loadDanmakuNamed()`（**唯一发请求处**）：进门第一行 `if (_isLive) return;` ——
   覆盖起播、设置面板、手动搜索三条绕开开关的路。
3. `_toggleDanmaku()`：第一行 `if (_isLive) return;`（不改开关、不弹 toast、不发请求）。
4. `danmakuSend:` 那段**过期注释**改成第 4 代口径（四项 AND、任一不满足 ⇒ 整条不渲染），
   并把该谓词的覆盖缺口补进门禁 C④。

**非直播路径零变化**：三处守卫的条件为假即落回原文；`if (!isLive) ...[` 对点播恒真。

## 4. 门禁：`test/zz_t66_r6b_live_toggle_test.dart`

三层，**A/C 默认跑**，B 挂 `native-media`（本机 libmpv 崩 flutter_tester，全仓同规）。

| 层 | 断言 | 读数 |
| --- | --- | --- |
| A① | 直播底栏：两枚 key 命中 0、四句文案（开启弹幕/关闭弹幕/弹幕设置/弹幕加载中）命中 0；**阳性对照**「更多」还在 1 枚 | 绿 |
| A② | 成对：点播点得到（回调 +1、key 命中 1）；直播没有那枚可点（回调 0） | 绿 |
| B① | **真 `PlayerPage(liveChannelId:)` + 计数 transport**：点开关（若存在）、强推 `_toggleDanmaku()`、直推叶子 `debugPlayerLoadDanmakuForProbe`，三条路 `/api/v2/match` 计数 **= 0**；开关不被翻成"开"；用户偏好不被写 | 绿 |
| B② | 阳性对照：同一点播页、同一支仪器，`/api/v2/match` 计数 ≥ 1（证明仪器数得到，A/B① 的 0 不是恒真） | 绿 |
| C①—C④ | 源码契约：两条守卫各在自己的第一行、底栏两枚被同一个 `if (!isLive)` 包住、发送栏 AND 谓词四项齐全 | 绿 |

读数：
- `flutter test test/zz_t66_r6b_live_toggle_test.dart --concurrency=1` ⇒ **`+6 ~2`**
  （`~2` = B 层两例按标签默认跳过，**不是失败**）
- `flutter test … --run-skipped --tags native-media --concurrency=1` ⇒ **`+2`**

## 5. 故障注入（证明门禁有判别力）

每处注入后都 `dart analyze` ⇒ **0 error**（注入是有效编译，不是语法炸），做完即还原。

| 注入 | 改坏什么 | 注入后 sha256（前 12 位） | 门禁读数 | 红在哪 |
| --- | --- | --- | --- | --- |
| I1 | 底栏门控 `if (!isLive) ...[` → `if (!isLive \|\| true) ...[` | `e4fc69fb4224` | **`+3 ~2 -3`** | A①、A②、C③ |
| I2 | `_toggleDanmaku` 守卫 `if (_isLive) return;` → `if (_isLive) {}` | `b3ff73b0e20b` | **`+5 ~2 -1`** / native **`+1 -1`** | C① / B①（"开关不许撒谎"：期望 false 实得 true） |
| I3 | 叶子守卫 `if (_isLive) return;` → `if (_isLive) {}` | `fbe5b87d21d2` | **`+5 ~2 -1`** / native **`+1 -1`** | C② / B①（叶子那条路请求数 ≠ 0） |
| I4 | 把 `_danmakuCanSend` 从 AND 谓词里删掉（原覆盖缺口） | `4d261c4e1986` | **`+5 ~2 -1`** | C④ |

还原后：

```
449570bda7804adf971677d0d2d0855eef6587198a87e197d150f8bd19399813  lib/ui/player_page.dart
1eb71cf985c9e26f8f2d7c3532e0bf39568a8a8805ffb4891e0802fd4e28dedc  lib/ui/player/player_bottom_bar.dart
```

`dart analyze lib` ⇒ **0 error**（423 条 info/warning，均为他人文件既有）。

## 6. 回归（逐文件 `--concurrency=1`）

全绿，**零失败**：

```
+6 ~2  zz_t66_r6b_live_toggle_test        +10  zz_t66_r6_live_controls_test
+13    task41_danmaku_send_gate_test      +9   t27_w14_danmaku_bar_form_test
+6     t27_w12_panel_builtin_prefill      +4   t27_w15_danmaku_quick_panel
+8     t27_w13_chrome_ssot                +15  t68_android_adapt_test
+13    zz_cr_local_session_player         +3   zz_cr_play_bottom_bar_test
+5     zz_cr_next_dup_more_menu           +6   zz_t66_n11_bottombar_test
+6     zz_t66_danmaku_startup_gate        +15  zz_t66_danmaku_panel_semantics
+4     zz_t66_danmaku_proxy_a11y          +9   zz_t66_danmaku_glass_test
+8     t98_no_site_names_test             +16  zz_t53_live_fullscreen_switch
```

默认跳过（`~1`，`native-media`）另用 `--run-skipped --tags native-media` 补跑：
`t27_w9_bar_linkage` / `player_episode_nav_boundary` / `t27_w6_live_switch_adopt` /
`zz_cr_dmk_d_badge` / `t103_danmaku_hint_ui` / `t108_danmaku_manual_search` /
`t139_danmaku_info_panel` / `player_panel_wiring`。

## 7. 没做什么

- 没加任何新用户可见文案（直播态是"少两枚控件"，不是"多一句话"）；没动
  `danmaku_settings_dialog.dart` 那句「本片源不支持发送弹幕（只能看）」。
- 没有让直播**支持**弹幕（没有直播弹幕接口，这是产品边界，不是本轮范围）。
- 没动 `_danmakuBadge` / 顶栏 `弹幕 !` 的既有逻辑（直播态现在根本不会有 `_danmakuError`，
  因为它发不出请求）。
- 没跑真机（有人在做像素验收）；所有"真树"读数来自 `flutter test` 里真实
  `pumpWidget(PlayerPage(...))`。

## 8. 真机像素验收（代码就绪，**待 build 窗口**）

探针：`lib/t106_r6b_live_probe.dart`（`dart analyze` ⇒ `No issues found!`）。

挂的是**真** `PlayerPage(liveChannelId:)`（直播）与真 `PlayerPage(id:)`（点播，阳性对照），
跑在真 Windows 窗口 1280×800 里：

| 判据来源 | 怎么取 |
| --- | --- |
| 像素 | 根 `RepaintBoundary.toImage()` ⇒ PNG + 条带逐列墨迹/颜色种数 |
| 渲染树 | 真 `element` 树（按 `PlayerBottomBar.danmakuToggleKey` 等 key 命中） |
| 请求数 | `debugSetDanmakuTransportForTest` 装的计数 transport（只数 `/api/v2/match`） |
| 交互 | 只调产品自己的入口 `debugPlayerToggleDanmakuForProbe()`（=真 `_toggleDanmaku()`） |

**不点系统级输入、不读屏、不 `CopyFromScreen`**；数据目录必须落在
`.probe/round66_r6b` 下（否则 `exit(3)` 拒绝启动，防止写真用户库）。

### 跑法（build 窗口到手后执行，跑前先贴命令）

```bat
flutter build windows --release -t lib/t106_r6b_live_probe.dart ^
  --dart-define=DATA_DIR_OVERRIDE=D:/tmp/r6b/.probe/round66_r6b/dev
build\windows\x64\runner\Release\sourin_spike.exe
```

产物：`D:/tmp/r6b/.probe/round66_r6b/dev/*.png` + `probe.log`。
退出码：`0`=全绿，`1`=有 FAIL，`2`=找不到 `libmpv-2.dll`，`3`=数据目录不合格。

### 判据表（每张图判什么）

| 用例 | 产物 | 机器可读行（`probe.log` 里 `[r6b]` 开头） | 期望 |
| --- | --- | --- | --- |
| A0 | — | `OK   A0  全程无渲染异常（RenderFlex overflow 也走这里）` | 必须出现；出现任何 `FAIL 渲染异常:` ⇒ 整条验收作废 |
| A1 | `a1_live_full.png`、`a1_live_bar.png`、`a4_live_after_toggle.png` | `A1  底栏 action 数=<n>` | 见下 12 条 |
| A1① | `a1_live_full.png` | `A1① 底栏矩形可从真渲染树读到 (x,y WxH)` | 有矩形（= 底栏真的画出来了，不是"整页空"） |
| A1② | `a1_live_bar.png` | `A1② 直播态底栏没有弹幕开关元素 (hits=0)` | `hits=0` |
| A1③ | `a1_live_bar.png` | `A1③ 直播态底栏没有弹幕设置元素 (hits=0)` | `hits=0` |
| A1④ | `a1_live_full.png` | `A1④ 直播态整棵树上没有含「弹幕」的文本` | 无 `(` 详情尾注（有就把命中的文本列出来） |
| A1⑤ | `a1_live_full.png` | `A1⑤ 直播态没有弹幕信息 chip（`弹幕 !` 那枚） (hits=0)` | `hits=0`（=证据里那枚看不懂的 `!` 不会再出现） |
| A1⑥ | `a1_live_bar.png` | `A1⑥ 底栏条带不是空白 (颜色种数>=3)` | `颜色种数>=3` |
| A1⑦ | `a1_live_bar.png` | `A1⑦ 底栏条带确有图标墨迹 (墨迹像素>200)` | `>200`（与 ⑥ 成对：既不是空白、也不是一团） |
| A1⑧ | — | `A1⑧ 直播态走产品开关入口后，番剧匹配接口请求数 = 0 (match=0 all=0)` | `match=0`（**核心判据**） |
| A1⑨ | — | `A1⑨ 直播态开关探针返回值不翻转 (ret=false)` | `ret=false` |
| A1⑩ | — | `A1⑩ 直播态开关状态未改变 (before=false after=false)` | `before==after` |
| A1⑪ | `a1_live_full.png` vs `a4_live_after_toggle.png` | `A1⑪ 点过开关之后，页面上半部没有新增墨迹（无 toast / 无失败徽标） (changedBytes=0)` | `changedBytes=0`（点前后上半部逐字节一致 ⇒ 既没 toast 也没 `弹幕 !`） |
| A1⑫ | — | `A1⑫ 点过开关之后，弹幕传输一条都没发 (calls=0)` | `calls=0` |
| A2 | `a2_vod_full.png`、`a2_vod_bar.png` | `A2  点播底栏 action 数=<n>`、`A2  开关探针返回=<b>` | 见下 5 条；`action 数` 应比 A1 多 **2** |
| A2① | `a2_vod_full.png` | `A2① 点播底栏矩形可读 (WxH)` | 有矩形 |
| A2② | `a2_vod_bar.png` | `A2② 点播态弹幕开关仍在树上（证明 A1 的「不在」不是 finder 恒假） (hits=1)` | `hits=1`（**阴性/阳性成对的关键一条**） |
| A2③ | `a2_vod_bar.png` | `A2③ 点播态弹幕设置仍在树上 (hits=1)` | `hits=1` |
| A2④ | `a2_vod_bar.png` | `A2④ 点播底栏条带确有图标墨迹 (墨迹像素>200)` | `>200` |
| A2⑤ | — | `A2⑤ 点播态开关探针 ⇒ 番剧匹配接口请求数 ≥ 1（仪器数得到请求） (match>=1)` | `match>=1`（证明 A1⑧ 的 0 不是仪器瞎了） |
| A3 | （用 A1/A2 的条带） | `A3  仅点播有墨迹的列: …`、`A3  仅直播有墨迹的列: …` | 见下 2 条 |
| A3① | — | `A3① 除弹幕那两枚外的列，直播与点播一致（没有别的东西消失） (仅直播有墨迹的列=无)` | `=无`（防"顺手把别的按钮也删了"） |
| A3② | — | `A3② 点播一侧多出的墨迹宽度足以构成两枚图标 (列数>=12 右界≈…)` | `列数>=12`（两枚图标实宽，不是 1–2 列的抖动） |

**收尾行**：`[r6b] ---- 结果：OK=<n> FAIL=0`，且 `exit 0`。
`OK` 总数应为 **20**（A0 + A1×12 + A2×5 + A3×2；A1 的 ⑥⑦ 与 A2 的 ④ 只在底栏矩形可读时才计）。

机器上怎么复核（无需看图的硬判据）：`grep -E "FAIL|--- 结果" probe.log` 必须只剩
`---- 结果：OK=20 FAIL=0`。

**人工复核只需看一张图**：`a1_live_bar.png` 与 `a2_vod_bar.png` 并排 —— 前者应比后者
**少两枚图标**（弹幕开关 + 齿轮），其余图标（更多/全屏 …）逐列对齐；`a4_live_after_toggle.png`
的上半部应与 `a1_live_full.png` 肉眼无差（没有 toast 条、没有 `弹幕 !`）。
