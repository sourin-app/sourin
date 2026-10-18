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
