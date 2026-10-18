# 第 66 轮：移除 material_ui + 布局优化 + 完整实测

**日期**：2026-10-18
**状态**：计划（待 Owner 审）
**来源**：Owner 本轮 7 条指示（逐字见 §1）
**前置**：第 65 轮已合并（PR #31 → main `bdf6435`）

---

## 1. Owner 逐字指示与本计划对应

| # | Owner 原话 | 本计划怎么落 |
|---|---|---|
| 1 | 「我没给你限制时间,这次必须实现」 | 不设轮次上限；第 65 轮遗留功能项全部纳入，做到真实落地为止 |
| 2 | 「你先启动客户端,我看看」 | ✅ 已启动（PID 34880，08:50:29，窗口「源影」，`app.so` 11.09 MB = 产品不是 spike） |
| 3 | 「打开客户端我看看」 | ✅ 同上，仍在运行 |
| 4 | 「我其实就是把那个 移除 material_ui组件是一件事,因为那个太丑了,所以替换掉应该就能好很多,布局也得优化一下」 | 移除 material_ui **就是**治「丑」的主路径；**并**做布局优化（§6） |
| 5 | 「那就这轮实现吧」（指移除 material_ui） | 本轮**必做**，不再是「前提不成立」 |
| 6 | 「主题设计就放在整体移除 material_ui组件 之后吧」 | 主题重设计**排在本轮之后**；本轮只保证主题体系能承载现有数据 |
| 7 | 「实测是必做的,你在这轮计划中加入吧」 | 新增独立批次 **H：实测**（§7），贯穿全程 |

---

## 2. 我上一轮判断错在哪（必须先认）

第 65 轮我写「移除 material_ui 前提不成立，本轮不做」。**事实部分对，结论错** ——
我把「工作量大」说成了「做不了」。Owner 已明确不限制时间，正确做法是排期做完。

**事实复盘**（实测计数，不是估的）：

```text
material_ui 依赖面      128 / 195 个 lib 文件
Material（widget）      318 处
MaterialApp             180 处
TextButton              154 处
InkWell                 151 处
ColorScheme             107 处
IconButton               91 处
TextField                88 处
Scaffold                 78 处
FilledButton             70 处
OutlinedButton           62 处
Tooltip                  59 处
ThemeData                55 处
ListTile                 41 处
Slider                   34 处
CircularProgressIndicator 30 处
SnackBar                 25 处
Dialog                   15 处
Switch                   13 处
```

---

## 3. ⚠️ 我必须先纠正自己两个错误（都已核实）

### 错误一：我原本打算推荐引入 `forui` —— **这违反仓库既有硬规矩**

`docs/AGENTS.md` §4 明确写着：

> **不再新增 forui 用法（FTheme / FScaffold / FButton…）**
> 取色走 `Theme.of(context).colorScheme` 或 `lib/ui/tokens.dart`

而 `test/provider_layout_test.dart` 有一条门禁专门守着这件事：
「forui 与 Material 的角色名不能混用」（`foreground` 在 `ColorScheme` 上不存在，混用直接编译失败）。

**所以本轮不能引 forui。** 正确路径是：**用已有的 `liquid_glass_widgets` + 自建 token 体系**。
本轮开工前我会把 AGENTS.md 这一条一并更新（因为移除 material_ui 后「取色走 colorScheme」这句本身就失效了），
但那属于**收尾时同步文档**，不是先斩后奏。

### 错误二：我启动客户端时用的是 `flutter build`，没走仓库规定的入口脚本

`docs/AGENTS.md` §2 规定：跑客户端走 `tools/run_client.ps1`，因为该脚本把
**「`app.so` 大小」变成硬闸**（产品 ~11MB / 误编 spike ~4MB）。

我实测了：当前 `app.so` = **11.09 MB**，落在产品区间 ⇒ 这次没编错。
但**流程是错的**，后续所有启动都改用 `tools/run_client.ps1`。

---

## 4. 已核实的技术前提

```text
liquid_glass_widgets 1.7.2   已装且在 pubspec，Material-free
  · GlassScaffold / GlassDialog / GlassTextField / GlassSwitch / GlassSlider /
    GlassListTile / GlassNavigationShell / GlassSearchBar / GlassToast /
    GlassSegmentedControl / GlassPressable

forui 0.27.4                 在 pub 缓存，但**禁用**（§3 错误一）

现有主题资产（1350 + 311 行，**不废弃**）
  · lib/ui/theme/theme_pack.dart      主题包模型 + 序列化
  · lib/ui/theme/theme_language.dart
  · lib/ui/app_theme.dart:226  themeFor(Brightness) → ThemeData   ← 要替换的出口
  · lib/ui/app_theme.dart:245  themeForPack(Brightness, ThemePack)
  · lib/ui/tokens.dart        Sp / Radii / FontSizes（已有，继续用）

AppIcons 161 个常量           第 65 轮已建好并全量接线，**保留**
```

**关键估计依据**：`theme_pack` 那 1661 行**不用废弃**，只需改「出口」——
原来吐出 `ThemeData`，改成吐出自家 `AppColors` + `GlassTheme`。
这比「重写主题系统」省一个数量级。

---

## 5. 批次 M：移除 material_ui（主体）

### M1：主题出口替换（最关键，必须第一）

```text
为什么第一：后面所有控件替换都依赖 Theme.of(context).colorScheme。
           不先改出口，换个控件就得改一次调用，白干两遍。

M1.1  建 lib/ui/theme/app_colors.dart
      · 一个**语义色**类（primary / onSurface / onSurfaceVariant / outline /
        error / surface / surfaceContainer…）
      · ★ 色值**直接取自现有 theme_pack**，不新造色板
      · 上一轮教训：AppPalette 是中性色板、ColorScheme 是语义色板，
        两层不同的东西 —— 所以这次**只做出口替换，不重定义色板**
M1.2  建 AppThemeScope（InheritedWidget）承载 AppColors
M1.3  app_theme.dart 的 themeFor / themeForPack 改为返回 AppColors
M1.4  107 处 Theme.of(context).colorScheme → AppTheme.of(context).colors
      · 机械替换，逐文件做，每 10 个文件跑一次 analyze
M1.5  门禁 theme_scope_test.dart
      · 断：全仓不许再出现 Theme.of(context).colorScheme
      · 断：深浅两套下 colors.primary 非空且不同
      · 故障注入：故意漏一处 ⇒ 必须红
```

### M2：根组件与外壳

```text
M2.1  MaterialApp（180 处）→ 手工组装 App 根
      ⚠️ 最大风险点：MaterialApp 同时承载
         navigator / overlay / theme / localizations / scaffoldMessenger
      · 先做**最小可运行版本**（一个页面 + 一次导航 + 一个 dialog + 一个 toast）
      · 跑通再铺开；不许一次性全改
M2.2  Scaffold（78 处）→ GlassScaffold
M2.3  SnackBar（25 处）→ GlassToast
M2.4  Material（318 处）→ 大部分是「给 InkWell 提供 splash 的壳」，
      删 InkWell 后随之失效；逐处确认，不许盲删
```

### M3：控件替换（按用量降序）

```text
TextButton     154 → GlassButton
InkWell        151 → GestureDetector（无视觉反馈处）/ GlassPressable（需反馈处）
IconButton      91 → GlassIconButton
TextField       88 → GlassTextField
FilledButton    70 → GlassButton.filled
OutlinedButton  62 → GlassButton.outline
Tooltip         59 → 自建 AppTooltip（Glass 无对应）
ListTile        41 → GlassListTile
Slider          34 → GlassSlider
CircularProgressIndicator 30 → 已有 AppLoading（第 65 轮统一了一部分）
Switch          13 → GlassSwitch
Dialog          15 → AppDialogShell → GlassDialog
```

### M4：移除依赖并验证

```text
M4.1  pubspec 删 material_ui
M4.2  grep -r "material_ui" lib/ → 必须 0
M4.3  flutter analyze 全仓 → 0 error
M4.4  全量测试（口径同第 65 轮：排除既有 17 个 libmpv 崩溃文件，并证明零回归）
M4.5  ★ 同步更新 docs/AGENTS.md §4 那两条已失效的规矩
      （「Material 一律 import material_ui」「不再新增 forui」）
```

---

## 6. 批次 L：布局优化（Owner 第 4 条后半）

```text
L1  **先取证**：逐页截图，列问题清单（间距不齐/密度过高/对齐错位/层级不清）
    ★ 不改代码，只出清单 —— 上轮教训：设计类改动不先取证就是瞎改
L2  审计硬编码：grep 未走 Sp / Radii / FontSizes 的地方，统一
L3  逐页调整：首页 / 详情 / 播放器 / 直播 / 设置 / 弹幕面板
L4  每页出**前后对比截图**
```

---

## 7. 批次 H：实测（Owner 第 7 条「实测是必做的」）

```text
H1  **每批构建后真机启动**（用 tools/run_client.ps1，不用裸 flutter build）
H2  逐条功能真跑：本轮 diff 影响到的功能，一条一条实际点
H3  ★ UI 我自己看像素：截图逐张检查，不只看 widget 测试
H4  故障注入：每条新门禁先证明能红，再承认绿
H5  读数归档进 round-66-issues.md
H6  **无干扰纪律**：绝不动鼠标、不抢焦点、不点桌面（用探针 + 截图）
```

---

## 8. 批次 P：第 65 轮遗留功能项（Owner 第 1 条「这次必须实现」）

```text
P1  第 2 条 四站解析器（完全没做）—— 只动 rust/sourin_core/src/providers/，
    与 M 批次（lib/ui/**）不冲突，可真并行
P2  第 8 条 不可播样本集 + 六类归因实测（只做了框架 + 宿主侧一半）
    ⚠️ 这条是 Owner 明确说「这个要修复」的，必须做完
P3  第 10 条 构建后真机自测（根因已找到并修，但没做真机验证）
```

---

## 9. 顺序与依赖

```text
M1 ─→ M2 ─→ M3 ─→ M4
 │                   │
 └───────────────────┴─→ L（布局必须在主题稳定后做，否则改两遍）
                         │
                         └─→ P2/P3（依赖真机，排在 M4 之后）

P1（四站解析器）与 M 并行，文件不冲突
H 贯穿全程，不是最后才做
R 必须最后
```

---

## 10. 需要 Owner 点头的 2 件事

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | 移除 material_ui 后，**没有现成的统一控件框架**了（forui 被禁、Glass 只覆盖一部分）。玻璃控件够不够，要看 L1 取证结果 | 建议**先做 M1+M2 最小验证**（主题出口 + 一个页面跑通），再决定是否需要补自建控件库。若 Glass 覆盖不足，我会把缺口列清单给你，不擅自引第三个包 |
| 2 | 视觉基调是否接受**玻璃 + 实色混排**（浮层用玻璃、正文用实色） | 建议接受。全站玻璃会掉帧且文字可读性差 |

---

## 11. 验收标准

```text
① pubspec 无 material_ui；grep -r "material_ui" lib/ = 0
② flutter analyze 全仓 = 0 error
③ 全量测试通过（排除既有 libmpv 崩溃文件，并证明零回归）
④ 每类替换有门禁 + 故障注入证明能红
⑤ ★ 真机逐屏截图，我自己看过每一张
⑥ 布局优化有前后对比
⑦ P1 四站解析器用真实链接跑通并附读数
⑧ P2 六类归因每类抓到一个真实样本
⑨ 用 tools/run_client.ps1 启动，app.so 大小落在产品区间
```

---

## 12. 风险

```text
R1  MaterialApp 拆解高风险 —— 能编译但运行时白屏。
    对策：最小可运行版本先跑通（一页 + 一导航 + 一 dialog + 一 toast）
R2  318 处 Material widget 多为 splash 壳，删 InkWell 后会有遗漏
    对策：analyze + 真机逐处点击验证
R3  视觉回归 —— 换控件后观感必变，Owner 可能觉得更丑
    对策：每批出截图给 Owner 看，不攒到最后
R4  第 65 轮已记录：17 个文件 libmpv 原生崩溃，本轮不修但要用同样方法证明零回归
R5  P1 四站解析器受 t98 门禁约束：不许出现站名，用中性命名 + 占位符
R6  ★ Glass 控件覆盖不足的风险 —— 见 §10 第 1 条
```

---

## 13. 状态跟踪

| 批次 | 内容 | 状态 |
|---|---|---|
| M1 | 主题出口替换 | 待开工 |
| M2 | 根组件与外壳 | 待开工 |
| M3 | 控件替换 | 待开工 |
| M4 | 移除依赖并验证 | 待开工 |
| L | 布局优化 | 待开工 |
| H | 实测 | 贯穿全程 |
| P1 | 四站解析器 | 待开工 |
| P2 | 不可播样本集 | 待开工 |
| P3 | 第 10 条真机自测 | 待开工 |
| R | 发版 | 待开工 |

---

# 第 66 轮补充：Owner 新增 13 条（2026-10-18 09:08）

> 这 13 条是 Owner 审计划后追加的。每条都**先核实代码现状**再写方案，
> 不核实的推测一律标 ⚠️。

## 核实结果总表

| # | Owner 要求 | 核实结论 | 现状 |
|---|---|---|---|
| 1 | 弹幕发送改底栏输入框，不要悬浮；随开关与能力显示，不支持就不显示 | `DanmakuSendBar` 现在是 `Positioned` 右下角**浮层** | 要改 |
| 2 | 允许引入兜底包 | `glass_kit`/`backdrop` **未装**，Owner 已授权可引 | 可用 |
| 3 | 用 `tools/run_client.ps1` 启动 | Owner 同意 | 已定 |
| 4 | 接受玻璃+实色混排 | Owner 确认 | 已定 |
| 5 | 搜索框移到右侧列表区；切分组列表不变；不能编辑已有 | ① 搜索框在**页头**（`live_page.dart:2653`）② 见下方**真因** ③ 「改名」功能**不存在** | 要改 |
| 6 | 除插件自身外的弹幕都应**手动绑定**，不要自动 | `_autoBindBili()` 在起播时**自动**调 `autoBindBySearch`（`player_page.dart:6349/7732`） | 要改 |
| 7 | 两个站还是不支持发弹幕 | **本地 32 个插件里 0 个声明 `danmaku_send`** ⇒ 宿主置灰是对的，缺的是插件能力 | 需插件侧 |
| 8 | 发构建前先实测完毕 | CI 里「全量测试」**已**在「构建」之前（203→207 行）；Owner 要的是**真机实测** | 加流程 |
| 9 | dan-api 全部异步，不许阻塞启动 | 需逐个调用点核实 | 待查 |
| 10 | 官方兜底发带签名的包；生产不可用就删掉 | 签名靠 `--dart-define=DANDANPLAY_APP_ID/SECRET` 注入，构建时**没传** | 要改 |
| 11 | 点配置提示「无配置项」，编排弹窗出不来 | `settings_page.dart:1602` `_flash('「${e.name}」没有可配置项')` | 要修 |
| 12 | 统一 toast，不要自己写 | `app_toast.dart` **存在但 0 处使用**；`_flash`/自写 **188 处** | 要改 |
| 13 | 健康/测速显示 正在数/总数、按速度排序、可手动排序、完成发 toast、退出页面/退出软件要处理好 | 测速**已有** `测速 $_done/$_total`（`plugin_speedtest.dart:1784`）；健康检测是**一次性批量** `healthSweep()`，**无进度无逐项**，失败只 flash 一句 | 要改 |

---

## 🔴 第 5 条的真因（已在你机器上取到证据）

**你的真实数据目录**（`%APPDATA%\app.sourin.player\ui-prefs.json`）实测：
```text
live_source_groups  =>  {"常看": []}      ← v1 存在，但值是**空列表**
live_channel_groups =>  **键根本不存在**   ← v2 从来没写进去过
```

而筛选函数 `liveGroupAllowsChannel`（`live_page.dart:224`）的第 ③ 条分支是：
```dart
// ③ 两个都没有 / 空组 ⇒ 全部放行（绝不筛成空）
return true;
```

⇒ **空 v1 + 不存在的 v2 ⇒ 走 ③ ⇒ 全部放行 ⇒ 列表显示全部**。
这与你的症状「只加了一个却还是展示全部」**完全吻合**。

**所以问题不是筛选逻辑错，而是「你添加的那个频道没有落盘」。**
写入路径存在（`live_groups_page.dart:183` 的 `setLiveChannelGroups(_groups)`），
但 `setLiveChannelGroups` 传空 Map 时会 `remove(key)`（清键），
所以落盘时 `_groups` 是空的。

**待查**：`_groups` 为什么在保存时是空的（勾选没进 `_groups`？还是管理器页与设置页不同实例？）。
这条要**先复现再修**，不许猜。

**另外**：「不能对已有的编辑」= 改名功能根本不存在（只有「删除分组」），要新增。

---

## 第 7 条的真因（实测）

```text
本地插件目录 32 个 .js
声明 danmaku_send 的：**0 个**
```
⇒ 宿主侧 `_danmakuCanSend` 读到 false ⇒ 置灰 + 显示原因，**行为是正确的**。
要真正支持发送，需要**插件实现 `danmakuSend()`**，属插件侧工作（私库 `sourin-plugins`）。

⚠️ 这条不能只在宿主侧改 —— 宿主改不出插件没有的能力。**方案见下方 N7。**

---

## 新增批次 N（按 Owner 13 条拆）

### N1：弹幕发送改底栏内嵌（第 1 条）

```text
现状：DanmakuSendBar 是 Positioned 浮层（player_page.dart:15289）
目标：移进播放器底栏，与其它按钮同一行
判据：
  · 弹幕总开关开 AND 该源支持 danmaku_send ⇒ 显示输入框 + 发送按钮
  · 任一不满足 ⇒ **整条不显示**（不是置灰 —— Owner 明确说「不支持就不显示」）
  ⚠️ 这与第 65 轮的口径相反（当时是「置灰可见」）⇒ 按 Owner 最新要求改，旧口径作废
门禁：四种组合（开/关 × 支持/不支持）各一条断言 + 故障注入
```

### N2：直播搜索框移位 + 分组修复 + 可编辑（第 5 条）

```text
N2.1  搜索框从页头移到右侧列表区顶部
      ⚠️ 页头是横跨两栏的，移进右栏后宽度变窄 ⇒ 要改布局，不是挪一行
N2.2  **先复现**「添加一个频道后落盘为空」，再修
      判据：真机添加 1 个频道 → 退出 → 重进 → 分组只显示那 1 个
N2.3  分组**改名**功能（当前只有删除）
N2.4  分组内**增删频道**功能（当前只能建组后由直播页勾选）
```

### N3：弹幕改为手动绑定（第 6 条）

```text
现状：起播时 _autoBindBili() 自动调 autoBindBySearch（player_page.dart:6349/7732）
目标：除「插件自身提供的该视频弹幕」外，一律**手动**绑定
判据：
  · 起播**不再**自动搜索绑定
  · 提供明确的「绑定弹幕」入口，用户点了才搜
  · 插件自带弹幕不受影响（那条路是 provider 自己给的）
⚠️ 这会让「起播就有弹幕」的体验变差（多一步），但这是 Owner 明确要求
门禁：起播后断言「没有发起任何绑定搜索」+ 故障注入（把自动调用加回去 ⇒ 必须红）
```

### N4：两个站的弹幕发送（第 7 条）

```text
前提：宿主侧能力齐全（danmaku_send 字段、provider_danmaku_send 调用都在）
缺的是**插件实现**。两条路：
  A. 在私库 sourin-plugins 里给这两个站的插件实现 danmakuSend()
  B. 若站点接口不允许第三方发送 ⇒ 如实告诉 Owner「做不到」，不硬造
⚠️ 必须先实测这两个站的发送接口是否可用（真请求），再决定 A 还是 B
```

### N5：dan-api 全异步（第 9 条）

```text
要查：所有 dan-api 相关调用是否在启动路径上同步等待
  · 内置实例探测（kDanmakuPublicInstances）
  · 弹幕搜索 / 获取
判据：启动到首屏的耗时**不因 dan-api 慢而变长**（附改前后读数）
门禁：把 dan-api 请求人为延时 5s ⇒ 首屏仍应在正常时间内出来
```

### N6：官方兜底签名包 + 生产不可用则删（第 10 条）

```text
现状：签名靠 --dart-define=DANDANPLAY_APP_ID/SECRET 注入，构建时没传
要做：
  ① 构建时注入真实凭证（走 GitHub Secrets，不落仓库）
  ② **先实测**生产环境官方兜底能否真取到弹幕
  ③ 实测不通 ⇒ 按 Owner 要求**删掉**这条兜底（连同 UI 入口）
⚠️ ②是前置：不实测就注入凭证等于白做
```

### N7：可视化编排修好（第 11 条）

```text
现状：settings_page.dart:1602  _flash('「${e.name}」没有可配置项')
      1117 行注释已写明：那里调 SourceComposerDialog 时**没传 initial** ⇒ 编排器空白
要做：
  ① 查 pluginConfigGet 为什么返回空 fields（是插件真没声明，还是解析丢了）
  ② 编排器入口从编辑入口**直达**、带初值、提交即生效
判据：点「配置」⇒ 编排弹窗**真的显示出来**，且带当前源的内容
```

### N8：统一 toast（第 12 条）

```text
现状：app_toast.dart **存在但 0 处使用**；_flash / 自写 188 处
要做：全部改走 AppToast，删掉自写实现
判据：grep 自写 toast = 0；AppToast 调用点 = 原 188 处
⚠️ 这是机械替换，但量大 ⇒ 逐文件改 + 每 20 处跑一次 analyze
```

### N9：健康检测/测速进度与排序（第 13 条）

```text
现状：
  · 测速**已有**进度 `测速 $_done/$_total · $_allConcurrency 路并发`
  · 健康检测是**一次性批量** healthSweep()，**无进度、无逐项**
  · 失败只 flash 一句「健康检测失败：$e」← Owner 看到的
要做：
  ① 健康检测改**逐项**执行，显示「正在执行 N/总数」
  ② 测速同样显示（已有，核对是否真的在跑）
  ③ 一键按速度排序（排序后仍可手动拖拽调整）
  ④ 测速完成发一条 toast
  ⑤ 退出页面 / 退出软件的处理（在途任务要能取消，不许泄漏）
判据：真机跑一次完整测速 + 健康检测，附读数与截图
⚠️ Owner 明确说「这个记得跑一下实测」
```

---

## 更新后的批次顺序

```text
M1 ─→ M2 ─→ M3 ─→ M4        （移除 material_ui，主体）
                        │
N1/N2/N3/N5/N6/N7/N8/N9 可与 M 并行 —— 但**都要避开 lib/ui/player_page.dart
                        和 lib/ui/settings_page.dart**（M 批次会大改这两个）
                        ⇒ 实际顺序：先做完 M1-M4，再集中做 N
N4 需先实测站点接口，可独立提前做（只动私库插件 + rust）
L（布局）在 M4 之后
P（上轮遗留）与 M 并行（只动 rust/providers）
H（实测）贯穿全程
R（发版）最后
```

**冲突规避**：`player_page.dart`（2 万行）和 `settings_page.dart` 是本轮最热的两个文件，
M 批次与 N1/N3/N7/N8/N9 都要动它们 ⇒ **必须串行**，不许并行改同一个文件。

---

## 需要 Owner 确认的 1 件事

**第 1 条的口径与第 65 轮相反**：上轮你定的是「不支持发送 ⇒ 置灰但可见」，
这轮你说「不支持就不显示」。我按**最新要求**做（不显示），
但确认一下：**弹幕总开关关闭时**，也不显示对吧？（我理解是：两个条件任一不满足就不显示）

## 第 7 条要提前说清

宿主侧改不出插件没有的能力。两个站不支持发送的**根因是插件没实现**。
我会先实测这两个站的发送接口通不通：
- 通 ⇒ 在私库实现
- 不通 ⇒ 如实报「做不到」，不硬造一个假入口

---

# 第 66 轮再补充：口径确认 + 拖动卡顿 bug（2026-10-18 09:5x）

## 一、第 1 条口径已确认（按本轮优先）

Owner 2026-10-18 确认：

> 「按照这轮的优先」
> 「弹幕总开关关闭时也不显示，对吧？」→「没问题」

⇒ **定稿口径**：弹幕发送栏**整条显示/不显示**，判据是两个条件**任一**不满足就**完全不显示**：

```text
显示条件（AND）：
  ① 弹幕总开关为开
  ② 当前源声明 danmaku_send = true（插件真的实现了发送）
任一不满足 ⇒ **整条不渲染**（不是置灰、不是禁用、不是显示原因）

⚠️ 第 65 轮的口径「置灰可见 + 显示原因」**作废**。
   连带作废的还有当时为它写的门禁断言（t65 那批「置灰但有原因」的断言要改）。
```

---

## 二、🔴 新 bug：缓冲条已满，拖动进度条仍转圈很久

**Owner 原话**：
> 进度条缓冲条都拉满了,我拖动实践结果还是要转圈圈好长的时间,这也是bug

**截图证据**：进度条下方的缓冲条（浅色部分）**已铺满全宽**，
说明 mpv 的 demuxer 缓存已经吃到了文件尾 —— 数据**就在本地**。
但拖动后仍然出现 `AppLoading` 转圈。

### 已核实的根因链（不是猜）

```text
① 转圈的唯一判据
   player_page.dart:14507
     if (_buffering && !_loading) AppLoading(...)
   而 _buffering 直接来自 media_kit：
   player_page.dart:3949
     _player.stream.buffering.listen((v) => setState(() => _buffering = v));

② _buffering 是 media_kit 对 mpv `cache-buffering-state` 的**布尔化**
   ⇒ 它表达的是「mpv 认为自己在等缓冲」，**不等于**「本地没有数据」

③ 关键：mpv 的 `cache-pause` / `cache-secs` **全仓没有配置**
   实测 grep：lib/ 与 rust/ 里 **0 处** 设置 cache-pause / cache-pause-wait / cache-secs
   ⇒ 用的是 mpv 默认值：
     · cache-pause = yes（默认）：缓冲不足时**主动暂停**播放
     · cache-secs 默认 10s：等缓冲填到 10s 才恢复

④ 于是拖动时的实际行为
   seek ⇒ mpv **丢弃**当前位置之后的重排缓冲，从头重新填
        ⇒ 即便文件已完整下载/已缓存到磁盘，mpv 仍会重新走一遍
           demux → 填 demuxer-cache-time
        ⇒ 期间 cache-buffering-state < 100 ⇒ buffering = true
        ⇒ UI 转圈，直到填够 cache-secs
```

**这就是「缓冲条满却还转圈」的机制**：缓冲条画的是
`demuxer-cache-time`（已缓存到哪），而转圈看的是 `cache-buffering-state`
（此刻是否在等）—— **两个不同的量**。seek 后前者仍然满（数据在），
后者归零（正在重填）⇒ 表现就是「满条 + 转圈」。

### 修复方向（要实测验证，不先写死）

```text
F1. seek 后**不要立刻信** buffering=true
    · 加一个「seek 宽限期」：seek 后 N ms 内的 buffering 变化不驱动转圈
    · 风险：若真的需要缓冲，宽限期会让用户看到「假流畅」然后卡住
    ⇒ 必须实测：宽限期取值要能覆盖本地缓存的 seek 重填时间

F2. 配 mpv 参数减少重填
    · `cache-pause=no`（或 cache-pause-wait 调小）⇒ 不等满就继续
    · 但**会**在慢网络下造成真卡顿 ⇒ 要按「已缓存到磁盘」与否区分
    · `cache-on-disk=yes` 已在用（cache-dir 已配）

F3. 区分「本地已完整」与「网络流」
    · 已完整缓存的片子：seek 应该**秒开**，不该有转圈
    · 网络流：转圈是诚实的
    ⇒ 判据要用「该位置是否已在 demuxer cache 内」而不是全局 buffering

F4. 转圈本身也可能有延迟
    · AppLoading 是 500ms 轮询的 _BufferPoller 之外的另一条链路
    · 要量「从 seek 到转圈消失」的真实毫秒数
```

**验收（必须实测，不许只看代码）**：
```text
① 真机：拖到一个已缓存的位置 ⇒ 记录「转圈出现时长」，目标 < 200ms 或干脆不出现
② 真机：拖到一个**未缓存**的位置（网络流）⇒ 转圈仍应出现（证明没把真卡顿也藏掉）
③ 故障注入：把 F1 的宽限期设成 0 ⇒ 门禁必须红
④ 附改前/改后同一操作的耗时读数
```

⚠️ **不许**用「去掉转圈」来"修复" —— 那会把真实的卡顿也藏起来。
必须做到「本地已缓存 ⇒ 不转圈；真需要等 ⇒ 仍转圈」。

---

## 三、批次 N1 口径更新（覆盖前文）

```text
N1 的判据改为：
  · 弹幕总开关开 AND 源支持发送 ⇒ 底栏内嵌输入框 + 发送按钮
  · 否则 ⇒ **整条不渲染**
  · 连带改：t65 那批「置灰可见 + 原因」的断言全部改写
            旧断言在新行为下必须变红（证明行为真的变了）
```

## 四、新增 N10：拖动卡顿（本 bug）

```text
见上文第二节。归入批次 N，但**优先级最高** ——
这是 Owner 亲自截图报的、影响核心体验的缺陷。

依赖：无（不依赖 material_ui 移除）
⇒ 可以**立即开工**，与 M 批次并行（但都动 player_page.dart ⇒ 必须串行）
```

---

# 第 66 轮再补充（三）：播放页鼠标移动卡顿（Owner 指定「必须死磕」）

**Owner 原话**：
> 还有播放页那个鼠标动一下 出现控件,也很卡顿,这个是必须死磕解决的问题

**优先级**：Owner 指定死磕 ⇒ 与 N10（拖动转圈）同为**最高优先级**，可立即开工。

---

## 一、🔴 先说最重要的发现：现有门禁测不出这个卡顿

我跑了仓库里已有的 `test/t72_jank_test.dart`，读数：
```text
PA|60 次鼠标移动 => PlayerPage 重建 0 次 / 元素重建 0 次（改前：page=60 / all=9960）
PB|180 次 tick   => 位置 setState 3 次, 整页重建 0 次
PC|抽屉关着：10 次整页重建 => onLiveChannels 被调 0 次
00:01 +5: All tests passed!
```

**「0 次重建 + All tests passed」与 Owner 实际感受到的卡顿同时成立。**
原因（已核实）：
```text
该测试只**数 setState 次数**，全文件 grep 不到任何
FrameTiming / buildDuration / SchedulerBinding.addTimingsCallback
⇒ 它证明的是「没有多余的整页重建」，**不证明「不卡」**。
```

⇒ **本轮必须补「帧耗时」门禁**，否则改完还是只能靠嘴说。
这是本条的第一要务，比修代码更优先 —— 没有仪器就不知道有没有修好。

---

## 二、已核实的代码现状

```text
① 指针入口在整页最外层
   player_page.dart:13970  Listener(onPointerSignal:)
   player_page.dart:13972  MouseRegion(cursor:..., onHover: (_) => _showControls())
   ⇒ Windows 鼠标每秒可达数百次事件

② _showControls()（:12041）每次 hover 都会走三件事
   · if (!_controlsVisible && !_anySheetOpen) setState(...)   ← 已有值守卫（task-72 修过）
   · _applyControlsMotion()      （:1192）
   · _armHideTimer()
   · _noteCursorActivity()       （:1009）
   三条都**不触发整页重建**（已逐一核实）⇒ 所以 PA 读数确实是 0

③ 但每次 hover 仍有的开销
   · _applyControlsMotion() 里读 MotionPrefs.duration(context, ...)
     —— 读 InheritedWidget（无障碍「减少动态效果」）
   · _noteCursorActivity() 在**全屏**且指针在内时：
     _resetCursorIdle() + Timer.cancel + 新建 Timer
     ★ 而 _resetCursorIdle() 在 _cursorIdleStale 为真时**会 setState 整页**
   · _armHideTimer() 每次 cancel + 新建 Timer

④ 光标隐藏路径的整页重建
   player_page.dart:1056  _resetCursorIdle() { setState(() => _cursorIdleStale = false); }
   注释自己写着：「本页整棵子树本来就在这个 State 的 setState 里重建」
   ⇒ 光标一翻就重建**整页 884 行 build**（:209 起的 build）

⑤ 动画没有局部化
   _controlsFade 是 Animation<double>（:1176），
   但**没有用 AnimatedBuilder 包住**它消费的子树
   ⇒ 若动画帧靠 setState 驱动，就是每帧整页重建
   ⚠️ 这一条**尚未证实**，是本轮要测的第一个对象
```

---

## 三、修复方向（都要实测，不许先写死）

```text
F1. 【先做】补帧耗时门禁（没有它后面全是猜）
    · 用 SchedulerBinding.instance.addTimingsCallback 采 FrameTiming
    · 指标：hover 期间 buildDuration / rasterDuration 的 P50 / P99 / 最大值
    · 对照：① 静止不动 ② 每秒 60 次 hover
    · ★ 必须能变红：人为在 hover 路径加一次 setState ⇒ P99 必须显著恶化
    · 同时补「真机」读数（widget 测试测不出 GPU/合成层开销）

F2. 把光标态从整页 setState 里摘出来
    · _cursorIdleStale 改成 ValueNotifier<bool>
    · 只用 ValueListenableBuilder 包住**那个 MouseRegion 的 cursor**
    · 判据：光标隐藏/恢复时，整页 build 次数必须为 0

F3. 把控制条淡入淡出局部化
    · 用 AnimatedBuilder 只包住需要改 opacity 的那几层
    · 判据：动画期间整页 build 次数为 0（元素重建只发生在被包的子树）

F4. hover 路径去掉每帧的 InheritedWidget 读
    · MotionPrefs.duration(context) 提到 didChangeDependencies 缓存
    · 判据：hover 期间不再有 context 依赖查询

F5. Timer 抖动
    · _armHideTimer / _noteCursorActivity 每次 hover 都 cancel+新建
    · 改成「记录最后活动时间戳 + 单个周期 Timer 检查」⇒ 避免 Timer 频繁分配
    · 判据：60 次 hover 只产生 1 个 Timer（不是 120 次 cancel/create）

F6. 若真机仍卡 ⇒ 查合成层
    · 视频纹理 + 半透明浮层的混合开销
    · 可能要给浮层加 RepaintBoundary / 减少 opacity 层数
    · ★ 这条只能真机验证，widget 测试测不出
```

---

## 四、验收（Owner 要求「必须死磕」，所以标准要硬）

```text
① 帧耗时门禁落地，且**故障注入能红**（人为加 setState ⇒ P99 恶化）
② 60 次/秒 hover 下：整页 build = 0，元素重建 = 0
③ 光标隐藏/恢复：整页 build = 0
④ 控制条淡入淡出：整页 build = 0
⑤ ★ 真机读数：hover 期间 P99 帧耗时 < 16.7ms（60fps 预算内）
   —— 达不到就继续查，不许改口径
⑥ 附改前/改后同一操作的读数对比
⑦ 副作用检查：控制条仍要能正常显隐、光标仍要能正常隐藏、不能变硬切
```

⚠️ **红线**：不许用「减少动画」「去掉淡入淡出」来换帧率 ——
    那是把功能砍掉冒充优化。用户明确要过动画（「要有动画」）。

---

## 五、与其它批次的关系

```text
N10（拖动转圈）与 N11（本卡顿）都要改 player_page.dart（2 万行）
⇒ **必须串行**，且两者可以合并成一批做（同一文件，避免来回切）

M 批次（移除 material_ui）也改 player_page.dart
⇒ 顺序建议：先做 N10+N11（纯性能，不动 UI 结构）
              再做 M（结构大改，届时性能门禁已存在，可防回归）
```

---

# 第 66 轮再补充（四）：批次 Z —— 逐页三遍排查（Owner 指定，放最后）

**Owner 原话**：
> 你逐个页面一个一个排查 反复查三次 自我纠错,这个放在最后面

**位置**：**所有批次之后**（M / N / L / P / H 全部完成后才开工）。
**理由**：前面的批次都在改代码，改完才谈得上「排查」；否则查完又变，白查。

---

## 一、什么叫「一个一个页面」

**不按文件查，按用户能走到的页面查。** 清单以 `task44_all_subpages_test.dart`
的 `subPages` 为准（该测试是全仓二级页的机械清单，漏了新页面它先红）。

```text
一级（底栏 tab）
  ① 首页 / 推荐
  ② 搜索
  ③ 追更
  ④ 直播
  ⑤ 本地
  ⑥ 设置

二级（设置内）
  按 task44 的 subPages 清单逐项（数据管理 / 播放 / 跳过 / 弹幕 / 直播分组 /
  Emby / 关于 / 更新 …）

全屏页
  · 播放页
  · 详情页
  · 来源导入 / 可视化编排弹窗
  · 各类 dialog / sheet / 浮层
```

## 二、什么叫「反复查三次」

**三次是三个不同视角，不是同一个检查跑三遍。**

```text
第 1 遍：**能看见的**
  · 真机截图，逐页看像素
  · 找：错位 / 溢出 / 截断 / 空白 / 对比度不够 / 文案截一半
  · 判据：我自己看，不靠测试断言

第 2 遍：**能操作的**
  · 每个按钮点一遍、每个开关拨一遍、每个输入框输一遍
  · 找：点了没反应 / 反应错 / 状态不回写 / 报错文案看不懂
  · ★ 三种输入都要试：鼠标悬停 / 触摸 / 方向键焦点（仓库要求）

第 3 遍：**能坏的**
  · 空数据、超长文本、断网、无权限、任务执行中退出页面
  · 找：崩溃 / 白屏 / 永久 loading / 状态泄漏
  · 这一遍最容易出问题，也最少人做
```

## 三、自我纠错（不是「查完就完」）

```text
每页查完必须产出一条结论，三选一：
  ✅ 通过   —— 附截图
  🔧 已修   —— 附改前/改后截图 + 说明
  ⚠️ 遗留   —— 写进 round-66-issues.md，说明为什么不修

★ 关键：第 2 遍 / 第 3 遍发现问题 ⇒ 修完要**回到第 1 遍重看**
  （改代码可能改坏视觉）—— 这才叫「自我纠错」，不是线性走一遍。
```

## 四、验收

```text
① 每个页面都有三遍的结论（不是只写「已查」）
② 所有 🔧 项有改前/改后截图
③ 所有 ⚠️ 项写进 issues 文档且有「为什么不修」的理由
④ 产出 docs/notes/round-66-page-audit.md：一页一行，三列（三遍）结论
⑤ ★ 这一批**不许跳过**，也不许缩成「抽查几页」
```

---

## 五、最终批次顺序（定稿）

```text
第 1 波（并行，互不冲突的文件）
  轨道 A  playback-fix   → player_page.dart 独占：
                           N10 拖动转圈 + N11 鼠标卡顿 + 帧耗时门禁
  轨道 B  live-ux        → live_page.dart / live_groups_page.dart：
                           N2 直播搜索移位 + 分组落盘修复 + 改名增删
  轨道 C  plugin-repo    → settings_page.dart / source_composer_dialog.dart /
                           plugin_speedtest.dart / app_toast.dart：
                           N7 可视化编排 + N9 健康测速 + N8 toast 统一
  轨道 D  danmaku        → lib/core/danmaku.dart 及弹幕组件：
                           N5 dan-api 全异步 + N4 两站发送能力实测

第 2 波（轨道 A 释放 player_page.dart 之后）
  N1 弹幕发送改底栏内嵌 + N3 改手动绑定（都在 player_page.dart）

第 3 波（串行，大工程）
  M1 → M2 → M3 → M4 移除 material_ui

第 4 波
  L 布局优化（主题稳定后）
  P1 四站解析器（rust，可与 M 并行）
  P2 不可播样本集 / P3 第 10 条真机自测

第 5 波
  H 完整实测（贯穿全程，最后汇总）

第 6 波 ★ 最后
  Z 逐页三遍排查 + 自我纠错

第 7 波
  R 自审 → PR → 合并 → 发版
```

---

# 第 66 轮再补充（五）：第 2 波（N1/N3）的代码现状与口径冲突处理

> 这两条都动 `player_page.dart`，归**第 2 波**（等轨道 A 释放该文件后再做）。

## N1：弹幕发送改底栏内嵌 + 不显示

### 现状（已核实）
```text
组件   DanmakuSendBar（player_page.dart:19407）
挂载   player_page.dart:15289  Positioned(right: Sp.x3, bottom: _kPlayerBottomBarHeight + Sp.x2)
       ⇒ 是**浮层**，浮在视频右下角上方
门控   if (_danmakuSendProvider != null && !_isLive && _chromeVisible)
       ⇒ 只判「有真站点 id」「不在直播」「控件可见」
       ⇒ **没有判弹幕总开关**，也没有判源能力就整条不渲染
```

### ★ 与第 65 轮的**口径冲突**（必须显式处理）
`DanmakuSendBar.canSend` 的注释（player_page.dart:19439 起）写着：
```text
⚠️ 为什么不是"干脆不渲染"（改前的做法）：
   Owner 第 9 条：「有些站点是支持发送弹幕的,你在软件实现了,
   但是并没有发送弹幕的入口,这个需要修复。」
   入口消失 ⇒ 用户连"这个能力存在"都不知道
```
**这与 Owner 本轮最新要求相反。** Owner 2026-10-18 确认：
```text
「按照这轮的优先」
「弹幕总开关关闭时也不显示，对吧？」→「没问题」
```

⇒ **处理方式**（不许含糊）：
1. 代码按**最新口径**改：两个条件任一不满足 ⇒ **整条不渲染**
2. `canSend` / `disabledReason` 两个字段若因此不再使用 ⇒ **删掉**，不留死参数
3. 那段注释**改写成新口径**，并注明「第 65 轮口径已作废，原因见 round-66」
4. 第 65 轮为旧口径写的断言全部改写；**新断言在旧行为下必须变红**（证明行为真变了）

### 要做
```text
① 从 Positioned 浮层移进播放器底栏，与其它按钮同一行
② 显示判据（AND）：
    · 弹幕总开关为开
    · 当前源 danmaku_send == true
    · （原有）有真站点 id、非直播、控件可见
   任一不满足 ⇒ 整条不渲染
③ 门禁：四种组合（开关开/关 × 支持/不支持）各一条断言
   + 故障注入（把总开关判断拿掉 ⇒ 必须红）
```

---

## N3：弹幕改手动绑定

### 现状（已核实）
```text
自动绑定   _autoBindBili()（player_page.dart:7732）
           调用点  player_page.dart:6349
             if (_danmakuEnabled && biliBind == null) {
               final ok = await _autoBindBili();
               if (ok) return;
             }
           ⇒ **起播时自动**调 autoBindBySearch
手动绑定   已有：用户可选搜索结果（:7042 / :7108）
           danmaku_info_panel 里 DanmakuPairKind.manual => '手动绑定'
           ⇒ 「手动」这条路**本来就存在**，缺的不是入口
```

### 要做
```text
① 删掉起播时的自动绑定调用（:6349 那一段）
② 插件自身提供的弹幕**不受影响**（那条路是 provider 自己给的，不经过 autoBind）
③ 确认手动绑定入口在起播后**可见且可达**（不能因为删了自动绑定就找不到）
④ 门禁：起播后断言「没有发起任何绑定搜索」
   + 故障注入（把自动调用加回去 ⇒ 必须红）
```

### 副作用（必须如实告知 Owner）
```text
删掉自动绑定后，「起播就有弹幕」会变成「起播没弹幕，要手动绑一次」。
这是 Owner 明确要求的（「所有的弹幕...都应该手动绑定,而不是自动」），
但体验上是**退步**，必须在交付说明里写清，不许当成纯优化汇报。
```

---

# 第 66 轮再补充（六）：N11 的两条实测修正（perf-player 汇报，Lead 已独立复核）

## 修正一：brief 里指定的 FrameTiming 仪器在 widget 测试里是**假仪器**

我在计划里写「用 `SchedulerBinding.addTimingsCallback` 采 FrameTiming」——
**这条写错了，已作废。**

实测（perf-player 做，我复核了 Flutter 源码）：
```text
实验（同一台机）            FrameTiming buildDuration    Stopwatch 围 pump()
轻树 30 帧                  7us（frames=1）              121us
重树 30 帧 setState         3us（frames=1）              9903us p99=26657us  ← 差 80 倍
真实 PlayerPage 60 hover    3us                          p50 45us / p99 188us
```

根因（我核了源码，确认）：
`flutter_test` 的 `AutomatedTestWidgetsFlutterBinding`
在 fake-async 里**直接调** `handleBeginFrame(null)` / `handleDrawFrame()`
（`packages/flutter_test/lib/src/binding.dart:2356-2358`）
⇒ **不经过引擎 frame pipeline** ⇒ 帧耗时数据不来自被测代码的 CPU 工作。
重树读数反而比轻树小 ⇒ 与负荷**无相关性**。

**改用**：`Stopwatch` 围 `tester.pump()` —— pump 的同步段包含建帧 + 构建 +
布局 + 绘制，即该帧在 UI 线程上的全部 Dart 侧工作。判别力已证（80 倍）。
**已知局限**：测不到 GPU raster ⇒ 必须另补真机探针，且交付里要标注「没做的那部分」。

## 修正二：N11 的真实根因比我写的更靠前 —— t72 有**结构性盲区**

```text
t72_jank_test.dart    grep 不到任何 fullscreen 相关代码
player_page.dart:1012 _noteCursorActivity() 第一行就是
                      if (!_fullscreen) return;
```

⇒ **t72 只在窗口模式下 hover，光标那条路径在它里面从不执行；**
   而真机全屏下它每帧都跑。

**这就是「t72 绿着 + All tests passed」与「用户觉得卡」并存的结构性原因**
—— 不是 t72 写错了，是它**只覆盖了一半场景**。

## 改前红基线（perf-player 建立，我独立复现，读数一致）

```text
T1 控制条隐藏后 1 次 hover 叫回  ⇒ pageBuild=1 all=188  帧 8958us   [红]
T2 隐藏光标 / 恢复光标           ⇒ pageBuild=1 all=190 / 188      [红]
T3 光标已隐藏 60× hover          ⇒ pageBuild=1 all=247 p99=880us   [红]
T4 光标已显示 60× hover          ⇒ pageBuild=0 all=0  p99=220us    [绿·阴性对照]
T5 控制条淡出动画                ⇒ opacity 采样到中间帧 0.86/0.78/0.68/0.52/0.32/0.07
                                    pageBuild=0                     [绿·Owner 红线守卫]
T6 隐藏→hover 循环 8 轮          ⇒ pageBuild=8 all=1504 p50=7639us [红]
结果：+3 -4
```

**3 绿 4 红 ⇒ 阴性对照有效**（证明不是「怎么都红」的假门禁），
且 T5 守着 Owner 的红线：**动画没被砍**（采样到 opacity 中间帧）。

## 对交付的新增要求

```text
① N11 修完必须保持 T5 绿（动画仍在动，不是硬切）
② 绿了之后必须**再做一次故障注入**（改回整页 setState ⇒ 门禁要再红），
   证明修完的门禁仍有判别力
③ 必须补一条真机探针，给出「真机全屏 hover 期间 P99 帧耗时」，
   验证 widget 门禁的结论在真机上成立
④ 交付里明确标注「Stopwatch 测不到 GPU raster」这个局限
```
