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
