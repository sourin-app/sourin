# 去 Material 化 + 三套设计语言 —— 规划

**状态**：仅规划，**未动代码**。请先裁决再施工。
**依据**：2026-10-17 现场盘点的实测数字（每个数字都附可复现命令）。
**本次修订**：v2 → v3。Owner 2026-10-17 给了**四条修正**，全部落进本文（见 §0）。
v1 → v2 那轮改掉的三处也保留在 §0.1。

---

## 0. 本次修订（v3）：Owner 四条修正

Owner 2026-10-17 的四条原话，**逐字引用**，以及"上一版错在哪"：

| # | Owner 原话（逐字） | 上一版错在哪 | 落在哪一节 |
|---|---|---|---|
| 1 | 「现在的交互不能改,ui改就行了」 | Lead 让 OpenDesign **自己发明布局**（加搜索框、挪底栏、改海报卡片结构）—— 那是**改交互** | §4.6（新增） |
| 2 | 「我们不是要做解析站,要做的只是内置上这个这个播放 解码支持」 | 上一版 §5 整节都在规划**第三方解析站**（`parses[]` + `resolve_play_url`）—— **方向错了，Owner 明确否掉** | §5.1~§5.4（整节重写） |
| 3 | 「用 dan-api 替换弹弹的play的弹幕你也没实现,你只调研了」 | 只停在调研报告，没有实施计划 | §5.5（新增） |
| 4 | 「bilibi我在我的另一台电脑上装还是提示 miss,这个弹幕接口应该不需要登录就能获取的,请纠正」 | 上一版把它当"用户环境问题"，没查根因 | §5.6（新增） |

★ **修正 1 与 2 推翻的是 Lead 上一版的方案**，不是笔误。
两条都在本文里明确写了"上一版为什么错"，以免下次又滑回去。

### 0.1 v1 → v2 那轮改掉的三处（保留）

| # | 上一版原文 | 现在的事实 | 性质 |
|---|---|---|---|
| 1 | §2「open design 不是设计工具，用不上」 | **错的**。它是**已安装**的设计生成器（152 设计系统 + 163 技能），并且已接通 DSH | **结论过时** |
| 2 | §0「forui / shadcn_ui 都依赖 `flutter/material` ⇒ 拒绝」 | 推理**错的**。forui 依赖的是 `material_ui`，源码里 `package:flutter/material` **0 处** | **理由错，需重写** |
| 3 | §3.5-1 `window_manager`「可能无解的硬阻塞」 | 夸大。它只读 `Theme.of`、不安装 Theme ⇒ 不是渲染阻塞 | **保留上一版的自我修正** |

★ 第 1 条是怎么错的（值得记下来，因为它是**同一个错误的第二次**）：
上一版我看到 `/d/DSHHome/profiles/open-design/` 里只有一个
`@open-design/dsh-runtime` 的 tgz，就下了「它不是设计工具」的结论。
那个 tgz **确实是**驱动 DSH 的桥 —— 但它只是 OpenDesign 的一个零件，
**不是 OpenDesign 本身**。我用「零件」的形态否定了「整机」的存在。
⇒ 教训：判断一个工具是什么，要看**它的安装体**，不要看它落到我手里那一片。

---

## 1. 你的四条指令，先说结论

| 你的指令 | 上一版判断 | 现在的判断 | 理由 |
|---|---|---|---|
| ① 第 14 条要用 **open design** 做三套 UI | ⚠️ 做不到 → ✅ 能做了 | ✅ 能做，但**边界要写死** | §2 + §4.6：是**换皮**不是重新设计 |
| ② 第 10 条「内置播放解码支持」 | ❌ 上一版答成了"做解析站" | ✅ **方向已确认：两层都要** | §5.2：取流/解析层 + 解码层，串联、都做、都不经第三方 |
| ③ 用 dan-api 替换弹弹play 弹幕 | ⚠️ 只调研了 | ✅ **已实现**（Lead 说是调研，实测代码里已经在跑） | §5.5：报告 §8 的 5 条**全部已落地** |
| ④ 第 6 条 外部站 弹幕报 miss | ❌ 当成了环境问题 | ✅ **根因已复现，是产品级缺陷** | §5.6：凭证构建期注入、默认空串 ⇒ 人人必 403 |

⚠️ 关于 ③ 我要**纠正 Lead 的一句转述**：task-30 里写「dan-api 只调研了、要升级成实施计划」，
但**代码里已经实现了**（`DanmakuEndpoint` + 5 条改动全在，见 §5.5 的逐条核对）。
⇒ 这条**不是"待实现"，是"已完成、需要文档补上"**。我把实测证据列在 §5.5，
请 Lead 复核我的判断（可能是我看错了，也可能 Lead 看的是旧版本）。

---

## 2. ★ open design 是什么（推翻上一版）

### 2.1 实测到的它

```bash
stat -c '%s' /d/APP/OpenDesign/'Open Design.exe'
# 223003136      ← = 223.0 MB（十进制） = 212.7 MiB（二进制）

du -sh /d/APP/OpenDesign
# 1.3G  /d/APP/OpenDesign

ls /d/APP/OpenDesign/*.exe
# /d/APP/OpenDesign/Open Design.exe          ← 主程序
# /d/APP/OpenDesign/Uninstall Open Design.exe

tasklist | grep -i "open design"
# Open Design.exe  81868 / 45280 / 79528   ← 三个进程，**正在运行中**
```

⚠️ **单位口径提醒**：上一版写的「223MB」**是对的** —— 那是主程序的**十进制**大小
（223,003,136 字节）。我第一次核这份文档时算成 212.7 就以为原文错了，
那是我把 MiB 当成了 MB。**两个数都对，只是单位不同**，这里写清楚免得下次再绕：
```text
Open Design.exe = 223,003,136 字节 = 223.0 MB（十进制，pub.dev/GitHub 惯用）
                                 = 212.7 MiB（二进制，ls -h / du -h 显示的这个）
```

但**安装目录整体是 1.3G**，不是 223MB —— 拆开是
`resources/app` 400M + `resources/open-design` 354M +
`resources/open-design-web-standalone` 180M + `locales` 47M + 主程序 213M。
⇒ 上一版只提了主程序那 223MB，读者会以为整个 OpenDesign 就这么大（低估了约 6 倍）。

### 2.2 它的三个能力（都是实测，不是宣传页）

```text
① 设计系统库   152 套
   复现：list_mcp_resources(server:"open-design") → 数 "od://design-systems/*/DESIGN.md"
   例：agentic / airbnb / airtable / ant / apple / …

② 技能库       163 个
   复现：同一次 list_mcp_resources → 数 "od://skills/*/SKILL.md"
   例：ad-creative / ai-music-album / algorithmic-art / …

③ 生成器       能直接产出可渲染产物（HTML），不是只给规范文本
   见 §4.2
```

### 2.3 它是怎么接进 DSH 的

```text
D:\APP\OpenDesign\resources\open-design-config.json    ← 746 字节，配置
DSH 侧：mcp__open-design__* 工具 + od:// 资源（MCP server 名 = "open-design"）
上一版看到的 @open-design/dsh-runtime tgz **只是这个桥**，不是它本体。
```

### 2.4 结论修正

上一版说「用 open design 做 UI 当前不成立」——**这条作废**。
正确结论：**OpenDesign 是本项目可用的设计生成器**，能出设计系统规范、
也能出可渲染的界面产物。§4 就是用它做的三套风格。

---

## 3. ★ 「完全不用 material」规划

### 3.1 真正的约束（这是「不用 forui / shadcn_ui」的正确理由）

```text
Dart 的 import 是「包级」的：只要 import 了 material_ui，
该 isolate 里就同时存在一套 Material Theme。
⇒ 本仓踩过的「两套 Theme 串台」正是这个机制
   （深底深字、不报错、单测全绿，只有看图才发现）。
```

★ 所以「不引入 forui / shadcn_ui」的理由**不是**「它们依赖 flutter/material」
（那是上一版写错的，见 §0 第 2 条），而是：**它们会把第二套 Theme 体系带进来**。
这与本仓已确立的选型标准第一条「**Material-free by design**」一致 ——
选它们就等于在同一个 isolate 里再装一套设计系统，重演串台。

⚠️ 附带一个**对未来的提醒**：既然 forui 0.27.x 依赖的是 `material_ui`
（实测 `forui-0.27.0/pubspec.yaml` 与 `0.27.4` 都是 `material_ui:^1.0.0`，
`grep -rl 'package:flutter/material.dart'` 两个版本都是 **0** 处），
那「forui 会不会串台」这个问题的答案取决于 **material_ui 与 flutter/material
是不是同一套 InheritedWidget** ——
本仓已实测**不是**（Flutter 3.47 把 Material 拆成了独立包），所以串台风险
来自「两套**不同**的 Theme 实现」，而不是「两套包名」。
⇒ 结论不变（不引入），但**判据要写准**，否则下次会有人拿「forui 用 material_ui」
来论证「可以引入」。

### 3.2 现状数字（全部实测 + 复现命令）

**产品代码边界**：`lib/ui` + `lib/core` + `lib/shell.dart` + `lib/main.dart`
（`lib/` 顶层 47 个 `.dart` 里有 **45 个**是一次性探针/自测（`t*_probe.dart` / `*_probe.dart` /
`delivery_test.dart` 等），只有 `shell.dart` 与 `main.dart` 是产品入口 ⇒ 不计入产品代码）

```bash
ls lib/*.dart | grep -cE '(probe|_test|hello_arm64|drag_selftest)'
# 45
ls lib/*.dart | wc -l
# 47     (45 探针 + shell.dart + main.dart)
```

```bash
PROD=$(find lib/ui lib/core -name '*.dart'; echo lib/shell.dart; echo lib/main.dart)
echo "文件总数 = $(echo "$PROD" | wc -l)"
# 134
echo "import material_ui = $(echo "$PROD" | xargs grep -l '^import .*material_ui' | wc -l)"
# 85
```

| 指标 | 读数 | 复现命令 |
|---|---|---|
| 产品文件总数 | **134** | 上面那段 |
| 产品里 import material_ui | **85** | 上面那段 |
| 测试文件总数 | **400** | `find test -name '*.dart'` 的结果计数 |
| 测试里 `MaterialApp` | **233** | `grep -rl 'MaterialApp' test/ --include=*.dart` 的结果计数 |
| 测试里 `Scaffold` | **151** | `grep -rl 'Scaffold' test/ --include=*.dart` 的结果计数 |
| 测试里 `TextField` | **32** | `grep -rl 'TextField' test/ --include=*.dart` 的结果计数 |
| 测试里 `ThemeData`/`Theme.of` | **45** | `grep -rlE 'ThemeData\\|Theme\\.of' test/ --include=*.dart` 的结果计数 |
| 测试里 `AlertDialog` | **7** | `grep -rl 'AlertDialog' test/ --include=*.dart` 的结果计数 |

⚠️ **与上一版有 3 处漂移**（不是笔误，是这两天别人动过）：

```text
测试文件总数   397 → 400   (+3)
测试 Scaffold  148 → 151   (+3)
测试 TextField  31 →  32   (+1)
```

产品侧那 4 个数（134 / 85 / 233 / 45）**与上一版完全一致**，
说明新增的是**测试**而不是产品代码 —— 与本轮「主题/对话框」改造的体量吻合。

**产品侧 material 符号用量（文件数，降序）**

```bash
for s in Theme Icons Icon Colors Material InkWell TextButton FilledButton ColorScheme \
         IconButton TextField OutlinedButton CircularProgressIndicator Tooltip AlertDialog \
         showDialog ThemeData SwitchListTile Divider SnackBar Slider ScaffoldMessenger \
         Dialog ListTile showModalBottomSheet Switch PopupMenuButton; do
  printf "%s %s\\n" "$(echo "$PROD" | xargs grep -lw "$s" | wc -l)" "$s"
done | sort -rn
```

```text
59 Theme          32 TextButton      15 Tooltip                7 Slider
51 Icons          24 FilledButton    14 AlertDialog            7 ScaffoldMessenger
51 Icon           23 ColorScheme     11 showDialog             6 ListTile
44 Colors         22 TextField       10 ThemeData              6 Dialog
38 Material       22 IconButton      10 SwitchListTile         5 showModalBottomSheet
33 InkWell        16 OutlinedButton   8 Divider                5 Switch
                  16 CircularProg…    7 SnackBar               4 PopupMenuButton
```

**★ 图标：最大暗礁**

```bash
grep -rohE 'Icons\\.[A-Za-z0-9_]+' lib/ --include=*.dart | sort -u | wc -l
# 147

grep -rlE 'class Icons' <flutter-sdk>/packages/flutter/lib/ | wc -l
# 0                          ← flutter/widgets 里根本没有 Icons 类

wc -l  <pub-cache>/material_ui-1.6.0/lib/src/icons.dart
# 29464
grep -cE 'static const IconData' <pub-cache>/material_ui-1.6.0/lib/src/icons.dart
# 8825
```

⚠️ **上一版写「148 个」不准，实测是 147 个**。差的 1 个是**注释**造成的：
`lib/ui/player_page.dart:17596` 有一句「用「切片 + 首个 \`Icons.\` 下标」约束底栏顺序」，
宽松正则 `Icons\\.[A-Za-z0-9_]*` 会把那个光秃秃的 `Icons.` 也数进去（=148）。
⇒ 用上面带 `+` 的严格正则：**147 个不同图标，分布在 51 个文件**。

⇒ 去 Material 必须换一套图标体系（Lucide / 自绘 / 字体子集），**147 个点位**。

### 3.3 已有的自建基础（决定工作量能压多少）

```text
lib/ui/tokens.dart                1011 行 ← 间距/圆角/字号/动效令牌（已从原版 CSS 变量搬来）
lib/ui/app_palette.dart            238 行 ← 语义色
lib/ui/app_theme.dart              253 行 ← 明暗/主题包解析
lib/ui/theme/theme_pack.dart       880 行 ← 主题包（含 borderWidth/dividerThickness/buttonPadding）
lib/ui/theme/theme_language.dart   311 行 ← 把「设计语言」落到 ThemeData
lib/ui/app_scaffold.dart                  ← 已自建外壳（取代 Scaffold，注释写明理由）
lib/ui/widgets/（47 个）                  ← app_dialog_shell / app_menu / app_toast /
                                            app_loading / press_feedback 等已有
```

⇒ **不是从零开始**。外壳、对话框、菜单、toast、loading、按压反馈已经有了。

### 3.4 施工方案（5 阶段，可独立验收）

| 阶段 | 内容 | 规模 | 验收 |
|---|---|---|---|
| **A** | 建 `lib/design/` 纯 widgets 层设计系统：令牌 + 颜色 + 排版 + 图标映射 | 新增，不动存量 | 三套设计语言出图 |
| **B** | 自建基础控件：`AppIcon`（147 图标映射）、`AppButton`、`AppSwitch`、`AppSlider`、`AppField` | 新增 | 可单测 + 出图 |
| **C** | 自建主题设施：`AppThemeData`/`AppColorScheme` 取代 `Theme`/`ThemeData`/`ColorScheme` | 替换 92 处 | 出图对比 |
| **D** | 替换 `InkWell`(33)/`Material`(38)：用自绘按压 + 已有 `press_feedback.dart` | 替换 71 处 | 交互可测 |
| **E** | 替换 `MaterialApp`（生产 2 处 + 测试 233 处）：生产用 `WidgetsApp`，测试写 `AppTestHost` | ★ 最大 | 全量测试绿 |

### 3.5 ⚠️ 必须先说清的三件事

**1. `window_manager` 会引入 flutter/material —— 但 ★ 不是渲染阻塞**

```text
实测：它 pubspec 里没有 material，但 lib/ 里 7 个文件 import package:flutter/material.dart，
      且顶层库 export 了 drag_to_move_area / window_caption_button 等 widget。

★ 它的 material 用途（逐个看过）：
    drag_to_move_area.dart     → Colors Container GestureDetector
    drag_to_resize_area.dart   → Color Colors Container GestureDetector
    window_caption.dart        → Color Colors Container Scaffold Text TextStyle Theme
    window_caption_button.dart → Color Colors Container GestureDetector
    virtual_window_frame.dart  → Colors Theme
    window_manager.dart        → Color
  ⇒ 它们只读 Theme.of(context)，**不安装任何 Theme / MaterialApp**。
```

→ **结论**（保留上一版的自我修正）：
```text
① 我们只用它的非 widget 符号（windowManager / ensureInitialized / WindowOptions /
   setPreventClose …）⇒ 完全不渲染它的 widget ⇒ 那些读 Theme 的路径不会执行
   ⇒ **不构成渲染层的主题串台**。

② 真正的后果只有一个：package:flutter/material.dart 会始终留在依赖图里。
   ⇒ 所以「零 material」门禁不能用「依赖图里没有 material」来判，
     只能用「lib/ 源码里不出现 material import/符号」来判。
   ⇒ 这是**门禁判据的设计问题，不是技术阻塞**。
```

⚠️ 我**没有验证**「去掉我们自己的 material 后，构建与运行是否真的无副作用」——
那是 Phase E 的 PoC 内容。

**2. 测试的 233 处 `MaterialApp` 是大头**（只给 widget 树一个 root）。
可写 `AppTestHost`（内部 `WidgetsApp` + 我们的设计系统）批量替换，
但 233 个文件要逐个改，且**每改一批必须跑绿**，否则无法定位是哪批坏。

**3. Phase E 之前两套主题会短暂共存** ⇒ 门禁 `material_split_test` 必须改成
「存量白名单 + 新增零容忍」，否则中间态无法提交。

### 3.6 验证方式

- 每阶段结束：**真机出图** + 亲眼比对（不是单测绿）
- 最终验收：**三套设计语言各出一套截图**，且能指出三张图哪些像素不同
- 新增门禁必须**故障注入变红**才算数

### 3.7 工期与风险（诚实版）

```text
B + C + D 是机械替换，量大但可预测。
A 是设计工作 —— **已经开始了**（§4，三套由 OpenDesign 生成）。
E 风险最高（233 个测试文件 + window_manager）。
```

不报「X 小时」这种数字 —— 没做过这个规模，报了也是编的。

★ **Owner 已明确：不接受分阶段，A~E 一次做完。**
（上一版建议的“先只做 A+B、看到风格再决定 C~E”**已作废**，不要再按那个排。）
⇒ 施工顺序仍然是 A→B→C→D→E（有依赖关系），但**中途不设交付停点**。

---

## 4. ★ 三套风格**由 OpenDesign 生成**（不是手搓）

⚠️ **先说清一件事，避免误会**：本仓**此前已有一套手工做的三套主题**
（`builtin.glass` / `builtin.neoBrutal` / `builtin.minimal`，
落在 `lib/ui/theme/theme_pack.dart`）。本节讲的是**另一套** ——
由 OpenDesign 生成的三份产物。**两套是并存的两个候选**，不是同一件事的两种说法。
§4.3/§6 会把两者的**取向分歧**摆出来给你选。

### 4.1 三套设计系统的真 token

以下全部来自**真读**资源，不是编的：

```text
read_mcp_resource(server:"open-design", uri:"od://design-systems/<id>/DESIGN.md")
```

| | **neobrutalism** | **glassmorphism** | **claymorphism** |
|---|---|---|---|
| 分类 | Bold & Expressive | Morphism & Effects | Morphism & Effects |
| Primary | `#FDC800` | `#1856FF` | `#3B82F6` |
| Secondary | `#432DD7` | `#3A344E` | `#FFFFFF` |
| Surface | `#FBFBF9` | `#FFFFFF` | `#FFFFFF` |
| Text | `#1C293C` | `#141414` | `#1C398E` |
| Success | `#16A34A` | `#07CA6B` | `#16A34A` |
| Warning | `#D97706` | `#E89558` | `#D97706` |
| Danger | `#DC2626` | `#EA2143` | `#DC2626` |
| 字体族 | primary=`Inter` / display=`Inter` / mono=`JetBrains Mono` | primary=`Plus Jakarta Sans` / display 同 / mono=`JetBrains Mono` | primary=`Montserrat` / display=`Poppins` / mono=`JetBrains Mono` |
| 字号刻度 | `13/15/17/21/27/35` | "mobile-first compact scale"（未给数） | "desktop-first expressive scale"（未给数） |
| 间距刻度 | `4/8/12/16/24/32` | "comfortable density mode"（未给数） | `4/8/12/16/24/32` |
| 视觉关键词 | modern, clean, high-contrast | clean, high-contrast, bold, enterprise, **liquidglass**, glassmorphism | modern, high-contrast, **playful** |

⚠️ **诚实标注**：glassmorphism 与 claymorphism 的 DESIGN.md **没给**字号/间距的**数值**，
只给了措辞（"compact scale" / "comfortable density mode"）。上表如实照抄，
**没有替它们编数字**。

三套共有的纪律（DESIGN.md §9 反模式，逐字）：
```text
- Do not introduce off-palette colors when an existing token can solve the problem.
- Do not flatten hierarchy by using the same type size/weight for all text.
- Do not add decorative effects that reduce readability or accessibility.
- Do not mix unrelated visual metaphors in the same interface.
```

### 4.2 已生成的产物（三套，全部 `succeeded`）

```text
list_projects → 三个项目都跑完了：

ui-v2-ebe6            neobrutalism     succeeded
  └ yuanying-main-desktop-dark.html        34,054 字节

ui-glassmorphism-25a0 glassmorphism     succeeded
  └ yuanying-home-light.html               55,160 字节

ui-claymorphism-5b93  claymorphism      succeeded
  └ （产物目录当前为空）
```

⚠️ `ui-9dab`（"源影 UI 三风格探索"，你启动的那次）状态是 **canceled**，
且产物为空 —— 它是**第一版**，随后被上面三个**按设计系统拆分**的项目取代。
⇒ 建议后续都以拆分后的三个项目为交付对象。

### 4.3 生成产物里的真实 token（从 HTML 里抽出来的 CSS 变量）

设计系统的 DESIGN.md 是**规范**；生成产物里的 CSS 变量是**它落地后的取值**。
两者不完全相同（生成器会按界面需要扩展）。以下是从产物里**实际抽到**的：

**glassmorphism**（`yuanying-home-light.html`）
```text
--bg:#eef6ff          --surface:rgba(255,255,255,.74)   --fg:#102033
--accent:#4f8cff      --accent-on:#ffffff               --muted:#60708a
--border:rgba(255,255,255,.64)                          --border-soft:rgba(255,255,255,.38)
--font-display:Inter, system-ui, sans-serif
--text-xs:12px --text-sm:14px --text-base:16px --text-lg:18px --text-xl:24px
--text-2xl:36px --text-3xl:54px --text-4xl:76px
--space-1:4px … --space-12:48px（4/8/12/16/20/24/32/48）
★ --radius-sm:16px  --radius-md:24px  --radius-lg:36px  --radius-pill:9999px
```
⇒ **大圆角**（sm 就 16px）+ 半透明白面 + 极浅蓝底 —— "玻璃"靠**透明度与光边**实现，
   不是靠深色。这与本仓现有 `builtin.glass`（深色、圆角 22）**方向相反**，
   是个需要你拍板的分歧（见 §6）。

**neobrutalism**（`yuanying-main-desktop-dark.html`）
```text
--bg:#fff4cf          --surface:#fffaf0        --surface-warm:#ffdca8
--fg:#2a1810          --accent:#d24b1f         --accent-on:#ffffff
--border:#d9aa7a      --border-soft:#efd0ab    --muted:#8a6652
--font-display:Arial Black, Impact, sans-serif   ← ★ 重字面
--radius-sm:4px --radius-md:8px --radius-lg:12px   ← ★ 小圆角，不是直角
★ --elev-raised: 6px 6px 0 rgba(42,24,16,.26)      ← 硬投影（无模糊）
--elev-flat:none   --elev-ring:0 0 0 1px var(--border)
--motion-fast:150ms --motion-base:240ms
```
⇒ ★★ 重要发现：OpenDesign 的 neobrutalism **不是直角**，而是 **4/8/12px 小圆角
   + 6px 硬投影（无模糊）**。我们脑子里那个「直角 0 + 2.5px 硬边」是**另一套东西**
   （更接近 flat/poster）。两者都是有效的粗野主义分支，但**必须选定一个**。
   它给的记忆点其实是**硬投影**（`6px 6px 0`，不带 blur），不是直角。

### 4.4 与本仓 `theme_pack` 的对应关系

本仓主题包现在的四个「设计语言」维度**能承接** OpenDesign 的绝大部分 token：

| OpenDesign token | 本仓承载方式 | 缺口 |
|---|---|---|
| Primary / Surface / Text / Danger | `AppPalette.primary / card / foreground / error` | ✅ 直通 |
| `--radius-sm/md/lg` | `ThemePack.radius`（单值） | ⚠️ 只能取**一档**，没有 sm/md/lg 三级 |
| `--border` | `AppPalette.border` | ✅ 直通 |
| 边框粗细 | `ThemePack.borderWidth` | ✅ 已有 |
| `--elev-raised: 6px 6px 0`（硬投影） | **无** | ❌ **缺一个「投影风格」维度** |
| `--space-*` | 本仓 `lib/ui/tokens.dart` 的 `Sp.*` | ⚠️ 本仓已有自己的刻度，不跟随主题包（**建议保持**，理由见下） |
| `--font-display`（Arial Black / Poppins…） | 本仓 `AppTypeface` 按平台固定 | ❌ **缺「字体族」维度** |
| 字号刻度 | `FontSizes.*` | ⚠️ 同上，建议不跟随主题包 |
| `--motion-*` | `tokens.dart` 动效令牌 | ⚠️ 同上 |

⇒ **两个真缺口**：
```text
① 「投影风格」维度（硬投影 vs 无投影 vs 柔和光晕）
   —— 这是 neobrutalism 与 glassmorphism 最大的区别之一，现在表达不出来。
② 「字体族」维度
   —— Arial Black（粗野）vs Plus Jakarta Sans（玻璃）vs Montserrat（黏土）
      是三种完全不同的气质，现在只能靠平台默认字体。
```

⚠️ **间距/字号刻度我建议仍然不开放给主题包**，理由与 `theme_bridge.dart` 的原注释一致：
「字号/间距一放开，主题包就能把全站排版搞乱，那不叫『主题』叫『换皮』」。
但**投影与字体族**属于「视觉语言」而非「排版」，可以考虑开放（等你拍板）。

### 4.5 待办

```text
① claymorphism 项目产物为空 ⇒ 需要重跑（或确认是否要这一套）
② 三套的最终取向要对齐 §6 的两个分歧（玻璃深浅 / 粗野直角还是小圆角）
③ 若采纳「投影风格 + 字体族」两个新维度 ⇒ 属于 §3.4 Phase A 的范围
```

### 4.6 ★★ 修正 1：第 14 条是**换皮**，不是**重新设计**

Owner 原话（逐字）：
```text
现在的交互不能改,ui改就行了
```

#### 上一版错在哪

Lead 上一版给 OpenDesign 的指令是"做三套 UI"，**没有限定边界**，
于是生成器按它自己的设计惯例**发明了布局**。实测产物里能看到：
```text
· 顶部多了一条搜索框（现在没有）
· 底栏位置被挪动
· 海报卡片结构被改了
```
⇒ 这三样**全部是交互/信息结构层面的改动**，不是视觉。Owner 要的不是这个。

#### 边界（必须写死，交给 OpenDesign 的指令里要逐条列出）

```text
【一律不动】
  · 元素位置（谁在左上、谁在右下，一个像素都不挪）
  · 信息结构（页面上有哪些信息、分几组、什么顺序）
  · 控件层级（谁包着谁、哪个是父容器）
  · 交互触发方式（点哪弹什么、长按/双击/方向键怎么响应）
  · 不加新控件（不新增搜索框、不新增按钮、不新增页签）

【只改这些】
  · 配色（背景 / 卡片 / 文字 / 强调色）
  · 圆角与描边（半径、边框粗细、边框色）
  · 阴影层次（有没有投影、硬投影还是柔和投影）
  · 字体（字族 / 字重 / 字号档位）
  · 图标风格（线性 / 填充 / 粗细；**图标的位置和语义不变**）
  · 控件外观（按钮、开关、滑杆、输入框的**皮**）
```

一句话判据：**换完之后，用户闭着眼按原来的位置点，还能点到同一个东西。**

#### 做法：拿真实截图当基准，要求"照着同样的布局"

```text
基准图：.probe/shots/baseline_now.png   （1444×845，Lead 用免打扰方式抓的）
```

给 OpenDesign 的指令必须包含这条约束（否则它一定会自由发挥）：

```text
"以附带的截图为准。**逐像素保持布局不变** —— 所有元素的位置、尺寸、
 层级、信息结构完全照搬截图。你只改视觉皮肤：配色、圆角、描边、
 阴影、字体、图标风格、控件外观。
 不要新增任何控件，不要移动任何元素，不要改变任何交互触发方式。
 交付物必须能与截图逐块对照（同一位置是同一个东西）。"
```

⚠️ **一个诚实的提醒**：上面这句 prompt 是**我拟的**，还没有用它对 OpenDesign 跑过。
   要不要按这个口径重跑三套，请你定（见 §6 第 7 问）。

---

## 5. ★ 第 10 条：不是做解析站，是**内置播放/解码支持**

### 5.1 修正 2：上一版整节方向错了（**Owner 已明确否掉**）

Owner 原话（逐字，两条）：
```text
我们不是要做解析站,要做的只是内置上这个这个播放 解码支持

内置解析能力,解码层也要
```

**上一版错在哪**：上一版把 §5 整节写成了「新增 `parses[]` 解析接口 +
`resolve_play_url`」—— 即**引入第三方解析站**，把播放页 URL 交给它换成真实地址。
Owner 明确否掉了这条路。

#### ★ 为什么上一版会滑到"解析站"上去（记下来，避免再犯）

```text
上一版的推理链是这样的：
  ① 直连取流要签名/登录（S1 35013、S2 -6005）—— 这是**真的**
  ② 所以"直连"这条走不通
  ③ 那就找一条不用签名的路 ⇒ 第三方解析站
  ④ 于是整节都在规划 parses[]（TVBox 生态里现成的字段，看着很顺手）

★ 错在第 ②→③ 那一步：**"直连取流难"被当成了"直连取流不可能"**。
  本仓自己就有反例 —— lib/core/bili/bili_api.dart **直连某视频站官方接口**，
  免登录、零新依赖、已经在跑（见 §5.6.3）。
  也就是说：我在同一个仓库里既写了"直连可行"的先例，又在规划里说"直连不可行"。

⇒ 教训：**不要把"难"写成"不可能"，然后拿它当引入第三方的理由。**
   遇到"要签名"时的正确下一步是查该站**是否另有无签名端点**，
   而不是跳到"找个中间人"。
```

⇒ **v2 版**的 §5.2~§5.5（`parses[]` / `resolve_play_url` / 三条"必须拍板"）**整段作废**
  （注：那四个小节号指的是 **v2 那版**的编号，与本文 v3 的 §5.2~§5.5 不是同一批内容）。

### 5.2 ★ 确认后的方案：**两层都要做，不是二选一**

Owner 的「内置解析能力,解码层也要」把我上一版列的两个歧义点（当时标着"待澄清"）**一次都答了**：

```text
(a) 取流/解析层 —— "内置解析能力"
    我们自己把S3/S1/S2等站的**真实播放地址**解出来，
    **不经任何第三方解析站**。

(b) 解码层 —— "解码层也要"
    地址拿到之后，这些站的流（**编码 / 封装**）本仓播放器解不了的，
    要**内置新的解码能力**。
```

⚠️ 注意这两层是**串联**的，不是备选：
```text
第 10 条 = 让用户能在本客户端里**直接看**这些站的片子
          = (a) 拿到地址   →   (b) 把流解出来播
          ⇒ 任何一层缺了，用户都看不成。所以"都要"。
```

### 5.3 两层各自的工作面（**方向已定，规模未测**）

⚠️ 下面是我按"方向已明确"整理出的**工作面**，**不是**实施方案 ——
每一层的具体做法需要先做侦察（本仓没有任何一层的现成实现）。
**我没有编工作量数字**：上一版就是因为没侦察就写方案，方向错了。

#### (a) 取流/解析层

```text
目标    把各站播放页 → 真实可播地址（m3u8 / mp4 / 分片列表）
约束    ★ 不经第三方解析站（Owner 明确）
现状    本仓没有这一层的实现
已知    直连要签名（S1 35013 / S2 -6005 是上一版记录的读数，**我本轮未复测**）
待侦察  ① 各站是否另有**无签名端点**（bili_api.dart 的先例说明"有可能"）
        ② 签名算法是否可自行实现（有些站是纯算法，不需要账号）
        ③ 各站地址的**时效性/防盗链**（Referer / UA / 过期时间）
```

#### (b) 解码层

```text
目标    本仓播放器解不了这些站的流时，内置补齐解码能力
现状    本仓播放链路：Flutter(UI) → dart:ffi → rust/sourin_core → libmpv
        解码实际由 libmpv 承担 ⇒ 要补的可能是
          ① libmpv 已支持但**我们没开**的能力（开关/参数层）
          ② libmpv 不支持、需要**新增解封装/解码器**的能力
待侦察  ① 目标站点的流到底是什么封装/编码（这是前提，不能猜）
        ② libmpv 当前构建已编入哪些解码器（本仓的 mpv 是自带的还是系统的）
        ③ ①与②的差集 = 真正要补的东西
```

⚠️ **我特意没写"加个 FFmpeg 就能解"这类话** —— 那是推测，不是实测。
   (b) 的第一步是**摸清目标流格式**，不是选方案。

### 5.4 待办（方向已定，接下来是侦察）

```text
① 先定"这些站点"的**具体名单**（Owner 说"这些"，我按上一版理解是S1/S2/S3，
   但**没有确认过**）—— 名单不定，两层的侦察都没法做
② 逐站侦察 (a)：有没有无签名端点 / 签名算法是否可实现
③ 逐站侦察 (b)：流的封装与编码是什么
④ 摸清本仓 libmpv 的解码能力边界（已编入哪些解码器）
⑤ ②③ 有读数之后，才写实施方案（不在本文里写，避免重演"没侦察就写方案"）
```

⚠️ **我没做的事**：没有把 (a)(b) 写成实施步骤 —— 因为**目标站点名单还没确认**，
   而且两层的侦察都还没做。**先侦察、再方案**（这正是上一版的反面教材）。

### 5.5 ★ 修正 3：dan-api 替换弹弹play —— **已经实现了，不是"只调研"**

Owner 原话（逐字）：
```text
用 dan-api 替换弹弹的play的弹幕你也没实现,你只调研了
```

### 5.5.1 先纠正一处事实：报告 §8 的 5 条改动**全部已在代码里**

调研报告在 `.probe/danapi-research/REPORT.md`（334 行，调研人 `dlg-subtitle`，
2026-10-16）。它的 §8 给了 5 条接入建议。我**逐条对照了当前代码**：

| # | 报告 §8 建议 | 代码现状 | 证据 |
|---|---|---|---|
| 1 | `ExternalDanmakuClient` 增加**可配置 baseUrl** | ✅ **已实现** | `DanmakuEndpoint` 类（`danmaku.dart:1569`）；ctor 有 `DanmakuEndpoint? endpoint` 参数（`:1640`） |
| 2 | 探测端点改用 danmu_api 有的端点（它没有 `/api/v2/system/version`） | ✅ **已实现** | `danmaku.dart:2311-2351`：「★ 2026-10-16 修：自建后端没有 versionPath」+ 二级探测退路 |
| 3 | `ui_prefs.dart` 新增 danmu_api 地址偏好 | ✅ **已实现** | `ui_prefs.dart:248` `dsh.danmaku.endpoint` + `:266` `dsh.danmaku.endpoint.token` |
| 4 | 设置对话框加输入框 + 连通性测试 | ✅ **已实现** | `danmaku_settings_dialog.dart:590/593` 两个 controller、`:1134/1172` 两个输入框、`probeOverride` 测试连接 |
| 5 | 选路优先级 danmu_api > 本机 > 官方 | ⚠️ **已实现，但优先级与报告写的不同** | 见下 |

**优先级实测**（`danmaku.dart:1698-1703`）：
```dart
DanmakuEndpoint? get _endpoint {
  final explicit = _endpointExplicit;
  if (explicit != null) return explicit;   // ① 显式传入
  if (_unsignedLocal) return null;         // ② 本机 2080 优先
  return DanmakuConfig.danmakuEndpoint;    // ③ 否则读用户配置的自建后端
}
```
⇒ 实际是 **显式 > 本机 > danmu_api > 官方**，**不是**报告 §8 建议的
   `danmu_api > 本机 > 官方`。代码注释解释了原因：「宿主**已经**探测并决定用本机了，
   别抢它的决定」。
⚠️ **这是一个真实的分歧**，需要你定哪个对（见 §6 第 8 问）。

**测试**：`t3_danmu_api_endpoint_test.dart` + `t3b_selfhosted_panel_test.dart` +
`t27_w5_danmaku_source_test.dart` 三个文件实测 **82 条全绿**，其中一条就是
`★ endpoint 优先级高于 unsignedLocal`。

⇒ **结论**：dan-api 这条路**代码已经通了**。task-30 里说"只调研了"与代码不符 ——
   要么 Lead 看的是旧版本，要么我理解错了范围。**请 Lead 复核**。

### 5.5.2 仍未做的（这是真的缺口）

```text
① 默认后端仍是弹弹play 官方（要凭证）—— 用户必须自己部署 danmu_api 并手填地址，
   产品里没有任何引导。⇒ "开箱即用"这条没做到。
② 三套 UI 里没有一条走 danmu_api 的端到端真机验证记录。
③ 报告 §5 提到的限流（3 次/分钟）在播放器"连切集"场景下会不会撞 429，
   没有实测记录。
```

---

### 5.6 ★★ 修正 4：外部站 弹幕报 `Missing Authentication Headers` 的根因

Owner 原话（逐字）：
```text
bilibi我在我的另一台电脑上装还是提示 miss,这个弹幕接口应该不需要登录就能获取的,请纠正
```

### 5.6.1 **Owner 是对的** —— 这是产品级缺陷，不是他那台电脑的问题

**根因（我复现了）**：
```text
lib/core/danmaku.dart:879-883
  static const String builtinAppId =
      String.fromEnvironment('DANDANPLAY_APP_ID');
  static const String builtinAppSecret =
      String.fromEnvironment('DANDANPLAY_APP_SECRET');
```
`String.fromEnvironment` 是**构建期**常量，默认 **空串**。
官方发布的包**没有** `--dart-define` 注入 ⇒ 凭证为空 ⇒ 签名头为空 ⇒ 必然 403。

**实测复现**（本机，无凭证）：
```bash
curl -s -D - -o /dev/null -m 20 "https://api.dandanplay.net/api/v2/search/episodes?anime=test"
# HTTP/1.1 403
# X-Error-Message: Missing Authentication Headers      ← 与用户看到的一字不差
```
⇒ **任何人**装官方包都会撞这条。Owner 换电脑复现，正是因为它与机器无关。

### 5.6.2 正解：直连 外部站 官方接口（免登录）—— 已实测

```bash
# ① 用 bvid 换 cid（免登录）
curl -s -m 15 -H "User-Agent: Mozilla/5.0" \
  "https://api.外部站.com/x/web-interface/view?bvid=BV1GJ411x7h7"
# {"code":0,"message":"OK",...,"cid":137649199,...}          ✅ 200 免登录

# ② 用 cid 取弹幕 XML（免登录）
curl -s --compressed -m 20 -H "User-Agent: Mozilla/5.0" \
  "https://api.外部站.com/x/v1/dm/list.so?oid=137649199"
# http=200  size=48081  Content-Type: text/xml  Content-Encoding: deflate
# 1200 条 <d p="...">
```

**⚠️ 三处需要更正/补充 Lead 的转述**（我实测出的）：

| Lead 的说法 | 我的实测 | 说明 |
|---|---|---|
| `dm/list.so` → http=200 ✅ | ✅ **对**（连测 5 次全 200，裸请求也 200） | 但**仓内注释说它 412**（见下） |
| `dm/list.so` 是 gzip | ❌ **是 deflate** | `Content-Encoding: deflate`，且是**裸 deflate**（无 zlib 头） |
| `search/type` 返回 HTML（被风控） | ⚠️ **不稳定，不是恒定** | 带 `Referer` 时第 1 次 200 JSON、第 2/3 次 HTML；不带 Referer 三次全 HTML |

### 5.6.3 ★ 重要发现：这条**已经实现了**，而且踩过同一个坑

`lib/core/bili/bili_api.dart`（文件头自己标了 `task-28`）**已经**直连 外部站 官方：

```text
1. /x/web-interface/view?bvid=BV...      → title / aid / pages[]（含 cid）
2. /x/player/pagelist?bvid=BV...         → 分 P 兜底
3. https://comment.外部站.com/<cid>.xml → 弹幕 XML
```

它**记录了 `dm/list.so` 的历史**（2026-10-05，Lead 实测）：
```text
原来的 /x/v1/dm/list.so?oid=<cid> 现在对**所有**请求头组合回 HTTP 412
（3400 字节的 text/html 风控页）。试过七种，全部 412。
⇒ 替代端点 https://comment.外部站.com/<cid>.xml 回 200
```

**今天（2026-10-17）复测：`dm/list.so` 已恢复 200**（连测 5 次 + 裸请求全 200）。
⇒ 两条路**现在都能用**，仓内选的是 `comment.外部站.com/<cid>.xml`。
**建议保持现状** —— 该端点实测稳定、且仓内已写好裸 deflate 解压
（`RawZLibFilter.inflateFilter(raw: true)`），而 `IoDanmakuTransport` **没有**
deflate 分支（`danmaku.dart:574-577` 直接 Utf8Decoder）⇒ 换成 `dm/list.so`
反而要动解压层，**没有收益**。

### 5.6.4 ⚠️ 但用户为什么会看到 miss？—— 根因是**路由**，不是缺实现

这是本节最关键的一点。代码里**有** 外部站 直连，那为什么还会 403？

`player_page.dart:5780-5784` 的路由：
```dart
final biliBind = loadBinding(widget.provider, widget.id);
if (biliBind != null && !biliBind.isEmpty) {
  final cid = biliBind.cidFor(_epIndex);
  if (cid > 0) { await _loadBiliDanmaku(cid); return; }   // ← 直连，免登录
  // 绑了但这一集没 cid ⇒ 走下面的 403 分支
}
```

⇒ **只有"已经绑定了外部视频站"的作品才走直连**。
没绑定的作品（绝大多数）会掉到弹弹play 那条路 ⇒ 没凭证 ⇒
`弹幕失败：Missing Authentication Headers`。

**代码自己承认了这件事**（`bili_bind.dart:535`、`:657` 两处注释）：
```text
⇒ 接着 弹弹play 没凭证 ⇒ 403 ⇒ 「弹幕失败：Missing Authentication Headers」。
```

⇒ **所以真正的修法是**：让「**没绑定**的作品」也能拿到 外部站 弹幕 ——
即把 `bili_api.dart` 的自动搜索/匹配接到主弹幕路径上（现在只在"已绑定"时才用）。
这是**路由层**的改动，不是"再写一个 外部站 客户端"。

⚠️ 我没有写具体改法（要动 `player_page` 的取弹幕分支，属于实施范畴），
   只把**根因**定位到这里。请确认我的定位对不对（见 §6 第 9 问）。

---

### 5.7 修正 3/4 的共同点（值得记下来）

两条都指向同一个**产品级**问题，而不是"用户不会用"：

```text
· 第 6 条：默认后端要凭证，而官方包**从来不带**凭证 ⇒ 默认路径必然失败
· 第 7 条：弹幕走了第三方（弹弹play），而**免登录的直连路径早就写好了**，
          只是没接到默认路径上
```

⇒ 合起来一句话：**"能免登录拿到的东西，被一条需要凭证的默认路径挡住了。"**
   两条修正的落地方式因此高度一致：**把免登录的那条路变成默认路**。

---

## 6. 我需要你回答的（阻塞项）

1. **玻璃的方向选哪个**（§4.3）？
   ```text
   (a) OpenDesign 版：浅色 #eef6ff 底 + 半透明白面 + 大圆角（sm 16 / md 24 / lg 36）
   (b) 本仓现有 builtin.glass：深色 #0B0E14 底 + 圆角 22
   (c) 两者都要（浅色给日间、深色给夜间）
   ```
2. **粗野的方向选哪个**（§4.3）？
   ```text
   (a) OpenDesign 版：4/8/12px 小圆角 + 6px 硬投影（记忆点是"硬投影"）
   (b) 本仓现有 builtin.neoBrutal：直角 0 + 2.5px 硬边（记忆点是"直角"）
   ```
3. **要不要给主题包加「投影风格」与「字体族」两个维度**（§4.4）？
   不加的话，三套风格里最抓眼的两项（硬投影 / Arial Black）表达不出来。
4. **claymorphism 这一套还要不要**（§4.5）？产物是空的。
5. **§5.3「这些站点」的具体名单** —— 两层的侦察都卡在这条上。
   Owner 说的是"这些"，我按上一版理解是S1/S2/S3，但**没有确认过**。
   ⚠️ 名单不定，(a) 取流层的"逐站找无签名端点"和 (b) 解码层的"摸清流格式"
   都没法开工。**这是 §5 目前唯一的阻塞项**（"两层都要"已由 Owner 确认，不再是歧义）。
6. **去 Material 是否接受分阶段** —— ★ **Owner 已答：不接受，A~E 一次做完**
   （见 §3.7）。这条**不再是问题**，留在这里只为标记它已关闭。
7. **三套 UI 要不要按"换皮"口径重跑**（§4.6）？
   上一版产物里多出的搜索框/挪动的底栏**必须去掉**。要不要我按 §4.6 那段 prompt 重跑？
8. **danmu_api 的选路优先级**（§5.5.1）：调研报告建议 `danmu_api > 本机 > 官方`，
   但代码实际是 `本机 > danmu_api > 官方`。**哪个对？**
9. **外部站 弹幕的修法确认**（§5.6.4）：我的定位是"**没绑定**外部视频站的作品
   掉到了弹弹play 那条路（缺凭证 ⇒ 403）"，修法是把 `bili_api` 的自动匹配接到主弹幕路径。
   **这个定位对不对？**

---

## 7. 我没有做的事

- ❌ 没有改任何代码（本条是规划）
- ❌ 没有猜 open design 的含义 —— 这次是**实测**出来的（§2）
- ❌ 没有承诺工期数字
- ⚠️ `window_manager` 的结论**保留了上一版的自我修正**（不是渲染阻塞，是门禁判据问题）；
  但「去掉我们自己的 material 后是否真的无副作用」仍然**没有验证**。
- ⚠️ §4 的 token **全部来自真读**（`read_mcp_resource` / 产物 HTML），
  没有给任何 DESIGN.md 缺失的数字**替它编**（已逐处标注"未给数"）。
- ⚠️ 规划里的**所有**「实测」数字都来自本次命令输出；但**没有跑过**任何一阶段的
  真实迁移 ⇒ 阶段工作量是**估算**，不是实测。
- ⚠️ §5.3 我**没有**写 (a)(b) 两层的实施方案 —— 方向虽已由 Owner 确认（两层都要），
  但**目标站点名单未定 + 两层侦察都没做**。上一版就是"没侦察就写方案"，
  方向错了白写一整节 ⇒ 这次刻意只写"工作面"和"待侦察项"。
- ⚠️ §5.3(a) 里"直连要签名（S1 35013 / S2 -6005）"是**上一版记录的读数**，
  **我本轮没有复测**（没有这两个站的可测 URL）。引用时请当"待复核"看待。
- ⚠️ §5.6 我说「外部站 直连**已经实现**」，但**没有**跑过端到端真机验证
  （没绑定的作品走一遍取弹幕）；结论来自**读代码 + 跑单测**，不是跑产品。
- ⚠️ §4.6 那段给 OpenDesign 的 prompt 是**我拟的**，**没有实际用它生成过**。
- ⚠️ `dm/list.so` 从 412 恢复成 200 只证明**今天**可用；风控端点随时可能再变
  （仓内 2026-10-05 就踩过一次）⇒ 不建议把已稳定的 `comment.外部站.com` 换掉。
