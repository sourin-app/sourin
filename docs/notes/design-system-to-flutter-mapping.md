# OpenDesign 设计系统 → 本仓 Flutter 令牌 映射表

> 任务：`task-29`（T-PLAN-B）　作者：`dlg-source`　日期：2026-10-17
> 状态：**规划文档**（本轮不改任何 `lib/` 代码，供 Owner 先看）

---

## 0. 这份文档的读法与一条重要前提

### 0.1 数据来源（全部真读，无一编造）

三份规范来自 OpenDesign MCP 资源：

```text
od://design-systems/neobrutalism/DESIGN.md
od://design-systems/glassmorphism/DESIGN.md
od://design-systems/claymorphism/DESIGN.md
```

本仓令牌来自真读这些文件（行号即下表引用）：

| 文件 | 内容 |
|---|---|
| `lib/ui/tokens.dart` | `Sp`(:43) / `Radii`(:79) / `FontSizes`(:101) / `FontWeights`(:144) / `Motion`(:159) |
| `lib/ui/app_palette.dart` | `AppPalette` 语义色(:29) |
| `lib/ui/theme/theme_pack.dart` | `ThemePack` 四个设计语言维度(:69/:76/:83/:88) |
| `lib/ui/theme/theme_language.dart` | 把维度落到 `ThemeData` |
| `lib/ui/theme_bridge.dart` | 角色补全 + `_defaultRadius`(:65) + `LightTokens`(:620) |
| `lib/ui/app_typeface.dart` | 字族与字号阶梯(:29) |
| `pubspec.yaml` | 字体资产 —— **`:251` 起的 `fonts:` 整块被注释掉** |

### 0.2 ★★ 必须先说的前提：三份规范**没有**设计语言数值

这一点会决定整份表怎么读，**请先看完再下表**。

三份 `DESIGN.md` 的结构是**同一套模板**，一共 9 节。逐节核对后：

```text
§1 Visual Theme & Atmosphere   只有形容词（modern / clean / playful…）
§2 Color                       ★ 有具体色值（7 个角色）
§3 Typography                  ★ 有字号刻度 + 字族名 + 字重列表
                             ⚠️ 但 scale 有三种形态：数列 / 「desktop-first expressive scale」/「mobile-first compact scale」
§4 Spacing & Grid              ★ neobrutalism/claymorphism 有具体数列；glassmorphism 只有「comfortable density mode」
§5 Layout & Composition        纯方法论，无数值
§6 Components                  纯方法论，无数值
§7 Motion & Interaction        ★ 有「150–250ms」一个区间
§8 Voice & Brand               纯文案指导
§9 Anti-patterns               纯禁止项
```

⇒ ★ **三份规范都没有给出任何圆角、边框粗细、阴影 offset、模糊半径的数值。**

这意味着一件很关键的事，它直接影响下面的表：

```text
「neobrutalism 的圆角是 0」不是规范里写的 ——
它是**风格名 + §1 形容词**这二者在本仓已有实现里的对应物。
```

所以本表对「圆角 / 边框 / 阴影 / 模糊」这几行的**原文值一律写「规范未给出」**，
另开一列写「风格推断」，并把推断依据写明。**不与色值/字号混在一列里** ——
那会让人误以为规范里有这些数。

### 0.3 本仓 `ThemePack` 现在能表达的**全部**东西

读 `lib/ui/theme/theme_pack.dart:42-94`，一个 `ThemePack` 只有这些字段：

```text
id / name / brightness / palette / sourcePath / builtin   ← 标识
palette : AppPalette                                       ← 颜色（13 个角色）
radius            : double?      (:69)  ← 圆角
buttonPadding     : EdgeInsets?  (:76)  ← 按钮内边距
borderWidth       : double?      (:83)  ← 描边粗细
dividerThickness  : double?      (:88)  ← 分隔线粗细
```

★ **就这四个设计语言维度，一个不多。**
（`radius` 的默认是 `10`，见 `theme_bridge.dart:65` 的 `_defaultRadius`；
  `borderWidth` / `dividerThickness` 的合法范围是 `[0,6]`，见 `theme_pack.dart:235-242`；
  这四个值由 `theme_language.dart` 的 `ThemeLanguage.apply` 落到 `ThemeData`。）

---

## 1. neobrutalism（新粗野主义）

> 规范原文 §1：`Bold & Expressive` —— *Modern take on brutalism with bold borders, vivid accent colors, and raw, high-contrast layouts on warm surfaces.*

★ 注意 §1 里的 **`bold borders`** 与 **`warm surfaces`** ——
  这是三套里唯一在散文里**点名了边框**的一套，也是它对 `borderWidth` 那行最有分量的依据。

### 1.1 颜色（源自 §2，逐值抄录）

| OpenDesign 角色 | 规范原文值（§2） | 本仓对应字段 | 现状 | 需要的改动 |
|---|---|---|---|---|
| Primary | `#FDC800` | `AppPalette.primary`（`app_palette.dart:58`） | 有该字段 | 无（填值即可） |
| Secondary | `#432DD7` | `AppPalette.secondary`（:64） | 有该字段 | 无 |
| Success | `#16A34A` | ★ **无对应角色** | **缺** | 需新增 `AppPalette.success` |
| Warning | `#D97706` | ★ **无对应角色** | **缺** | 需新增 `AppPalette.warning` |
| Danger | `#DC2626` | `AppPalette.error`（:75） | 有该字段（语义相近） | 无（可直接落 `error`） |
| Surface | `#FBFBF9` | `AppPalette.background`（:52） | 有该字段 | 无 |
| Text | `#1C293C` | `AppPalette.foreground`（:55） | 有该字段 | 无 |
| Neutral | `#FBFBF9` | `AppPalette.muted`（:70） / `card`（:78） | 有该字段（语义待定） | 需确认 `muted` 还是 `card` |

★ 本仓 `AppPalette` 一共 13 个角色（`app_palette.dart:46-81`），
  **没有 `success` / `warning` / `info`** —— 这套规范需要 `success` + `warning`，两个都缺。

### 1.2 排版（源自 §3）

| 规范项 | 规范原文值（§3） | 本仓对应 | 现状 | 需要的改动 |
|---|---|---|---|---|
| Scale | `13/15/17/21/27/35`（6 档） | `FontSizes`（`tokens.dart:101-118`）：`12/14/16/20/28/46`（6 档） | ★ 档数相同、**刻度完全不同** | 见 §1.3 的分析 |
| Families · primary | `Inter` | `AppTypeface`（`app_typeface.dart:39-41`）实际用 `Microsoft YaHei UI`(Windows) / `Noto Sans CJK SC` | ★ **刻意不用 Inter** | 见下方说明 |
| Families · display | `Inter` | 同上（本仓无 display/body 之分） | **缺**「display 与 body 分族」这一能力 | 需新增 `displayFontFamily` |
| Families · mono | `JetBrains Mono` | ★ **无等宽族** | **缺** | 需新增 `monoFontFamily` |
| Weights | `100,200,…,900`（9 档） | `FontWeights`（:144-150）：`regular(w400)` / `semibold(w600)` —— **只有 2 档** | ★ **刻意只有 2 档** | 见下方说明 |

★★ 关于字重：本仓**故意**从 5 档收敛到 2 档，理由写在 `tokens.dart:120-143`：
```text
Windows 主字族 Microsoft YaHei UI（msyh.ttc）只有 400/700 两个真实面
⇒ w500 渲染与 w400 完全相同（15 处死代码）
⇒ w600/w700/w800 三者渲染完全相同
⇒ 而拉丁走 Inter（真可变字重）⇒ 同一行「中文粗、数字细」
   = Owner 报过的「字体大大小小 粗细不一」
```
⇒ ★ **不要为了对齐规范的 9 档字重而把 `FontWeights` 放宽。**
  那不是「表达不了」，是**本机字库表达不了** —— 加了档位也渲染不出区别，
  反而会把已修复的「粗细不一」放回来。这是**必须保留的差异**，不是待办。

★★ 关于字族 `Inter`：同理，`app_typeface.dart:11-22` 逐字解释了为什么**不能**用它 ——
  `Inter` 的 cmap **零中文覆盖**，界面上每个汉字都靠引擎回退，
  于是中文落到 `Microsoft YaHei UI`、拉丁落到 `Inter` ⇒ 又是「粗细不一」。
⇒ 规范的 `Inter` 在本仓**是已知会引发缺陷的选择**，不该照抄。
  若 Owner 要「像规范那样」，正确做法是**内嵌一个覆盖中文的可变字重字族**，
  而不是把 `AppTypeface` 改回 `Inter`。

### 1.3 间距（源自 §4）

| 规范项 | 规范原文值（§4） | 本仓对应 | 现状 | 需要的改动 |
|---|---|---|---|---|
| Spacing scale | `4/8/12/16/24/32`（6 档） | `Sp`（`tokens.dart:43-53`）：`4/8/12/16/20/24/32/40/48/64`（10 档） | ★ **规范是它的子集** | 无（本仓更细） |

★ 这一行是个**好消息**：`4/8/12/16/24/32` 六档在本仓**全部存在**，
  剩余的 `20/40/48/64` 是超集 —— 规范的每一步都能落到本仓的某个 `Sp.xN` 上：
```text
4 → Sp.x1   8 → Sp.x2   12 → Sp.x3   16 → Sp.x4   24 → Sp.x6   32 → Sp.x8
```
⇒ ★ **三套规范里，只有 neobrutalism 与 claymorphism 给了具体间距数列，
  且两者都是 `4/8/12/16/24/32`，本仓零改动即可满足。**

### 1.4 形状 / 边缘 / 阴影（规范**未给出**，按风格推断）

| 维度 | 规范原文值 | 风格推断 | 本仓对应 | 现状 |
|---|---|---|---|---|
| 圆角 | ★ **规范未给出** | 直角（0） | `ThemePack.radius`(:69) | ★ **有该维度**（`builtin.neoBrutal` 已用 0） |
| 边框粗细 | §1 散文 `bold borders`，**无数值** | 粗（≥2.5） | `ThemePack.borderWidth`(:83) | ★ **有该维度**（已用 2.5） |
| 分隔线 | ★ **规范未给出** | 粗（≥3） | `ThemePack.dividerThickness`(:88) | ★ **有该维度**（已用 3） |
| 硬投影（offset，无模糊） | ★ **规范未给出**（§9 反而说 *Do not add decorative effects*） | 新粗野主义的标志性元素 | ★ **无对应字段** | **缺** |
| 按钮内边距 | ★ **规范未给出** | 厚重 | `ThemePack.buttonPadding`(:76) | ★ **有该维度**（已用 18/14） |

★ 顺带一条**规范内部的张力**，值得 Owner 知道：新粗野主义最标志性的视觉是**硬投影**
  （实心偏移、零模糊，像贴纸），但 §9 Anti-patterns 又写着
  *Do not add decorative effects that reduce readability or accessibility*，
  且 §5 写着 *Use whitespace to separate concerns **before adding borders or shadows***。
⇒ 若 Owner 要「最像新粗野主义」，**硬投影是收益最大的新增**；
  但要接受它与 §9 的字面张力（§9 针对的是「损害可读性的装饰」，实心偏移不算）。

### 1.5 动效（源自 §7）

| 规范项 | 规范原文值（§7） | 本仓对应 | 现状 |
|---|---|---|---|
| 过渡时长 | `150–250ms` | `Motion.fast`=150 / `Motion.medium`=180 / `Motion.fade`=200 / `Motion.base`=260（`tokens.dart:160-234`） | ★ `150/180/200` 落区间内；`base`=260 **略超上界 10ms** |

⇒ 属于**可接受偏差**（10ms 肉眼不可辨），不建议为此改 `Motion.base` ——
  它在 18 处使用，改它等于改全局节奏（`tokens.dart:203-205` 已写明这条纪律）。

### 1.6 组件 / 布局 / 文案（§5 §6 §8 §9）

这几节是**方法论**，无数值可映射。逐条对应本仓的既有约束：

| 规范要求（节） | 本仓对应 | 现状 |
|---|---|---|
| §5「一致的内部 padding」 | `Sp` 体系 + `Layout` 系列函数 | 有 |
| §5「标题 → 支撑文案 → 主操作」 | 组件层约定，非令牌 | 有（各处页面） |
| §6 Buttons 用 Primary 色 | `FilledButton` 走 `ColorScheme.primary` | 有 |
| §6 Inputs 强 focus-visible | `theme_language.dart` 的 `_inputBorder` 六态 | 有 |
| §6 Cards 一致的 radii/elevation | `ThemePack.radius` + `cardTheme` | 部分（elevation 无字段） |
| §9 不用 off-palette 色 | `theme_regression_test.dart` 的对比度断言 | 有（且比规范更严） |

---

## 2. glassmorphism（玻璃拟态）

> 规范原文 §1：`Morphism & Effects` —— *Frosted glass effect with translucent layers, subtle blur, and luminous borders for depth and modern elegance.*

★ 这套的 §1 是**三套里对实现描述最具体**的一句：
  `translucent layers`（半透明层）/ `subtle blur`（细模糊）/ `luminous borders`（发亮描边）。
  **但它依旧没给任何数值。**

### 2.1 颜色（源自 §2，逐值抄录）

| OpenDesign 角色 | 规范原文值（§2） | 本仓对应字段 | 现状 | 需要的改动 |
|---|---|---|---|---|
| Primary | `#1856FF` | `AppPalette.primary`(:58) | 有该字段 | 无 |
| Secondary | `#3A344E` | `AppPalette.secondary`(:64) | 有该字段 | 无 |
| Success | `#07CA6B` | ★ **无对应角色** | **缺** | 需新增 `AppPalette.success` |
| Warning | `#E89558` | ★ **无对应角色** | **缺** | 需新增 `AppPalette.warning` |
| Danger | `#EA2143` | `AppPalette.error`(:75) | 有该字段 | 无 |
| Surface | `#FFFFFF` | `AppPalette.background`(:52) / `card`(:78) | 有该字段 | 无 |
| Text | `#141414` | `AppPalette.foreground`(:55) | 有该字段 | 无 |
| Neutral | `#FFFFFF` | `AppPalette.muted`(:70) | 有该字段 | 无 |

⚠️ 本节 §1 的 `Color stance` 比另两套**多一项 `info` 与 `surface/subtle layers`** ——
  本仓 `AppPalette` 同样没有 `info`。

★ 一个必须点出的**语义鸿沟**：
```text
规范的 Surface = #FFFFFF（不透明的纯白）
但「玻璃拟态」的 Surface 在真实现里应当是**半透明层**
⇒ 规范的色值表达不了「translucent layers」，只有 §1 的散文说了
```
⇒ 本仓把 `#FFFFFF` 落到 `background`/`card` 是**字面正确但风格不完整**的落法；
  真正的玻璃感需要下面的新增字段（§2.4）。

### 2.2 排版（源自 §3）

| 规范项 | 规范原文值（§3） | 本仓对应 | 现状 | 需要的改动 |
|---|---|---|---|---|
| Scale | ★ **「mobile-first compact scale」**（纯文字描述，**无数列**） | `FontSizes`(`tokens.dart:101-118`) | ★ **无法逐值映射** | 需 Owner 指定具体数列 |
| Families · primary / display | `Plus Jakarta Sans` | `app_typeface.dart:39-41` | 有意不同（中文覆盖） | 同 §1.2 |
| Families · mono | `JetBrains Mono` | 无 | **缺** | 需新增 `monoFontFamily` |
| Weights | 9 档 | 2 档 | 刻意 | 保留（理由同 §1.2） |

★ 这一行要特别标注：glassmorphism 的字号刻度**不是数列**，
  而是「mobile-first compact scale」这样一句描述。
⇒ 若要让本仓给出「compact 档」，需要**先由 Owner 定出具体数列**，
  否则任何数值都是我编的。**本表拒绝在此处给数**。

### 2.3 间距（源自 §4）

| 规范项 | 规范原文值（§4） | 本仓对应 | 现状 |
|---|---|---|---|
| Spacing scale | ★ **「comfortable density mode」**（纯文字描述，**无数列**） | `Sp`(`tokens.dart:43-53`) | ★ **无法逐值映射** |

⇒ 同 §2.2：需 Owner 指定具体数列，本表不给编造的数值。

### 2.4 形状 / 边缘 / 效果（★ 本套的**重灾区**）

| 维度 | 规范原文值 | 本仓对应 | 现状 |
|---|---|---|---|
| 圆角 | ★ **规范未给出** | `ThemePack.radius`(:69) | ★ **有该维度**（`builtin.glass` 已用 22） |
| 发光描边 `luminous borders` | §1 散文，**无数值** | `ThemePack.borderWidth`(:83) **只表达粗细，不表达「发光」** | **部分缺**（粗细有，光晕无） |
| **模糊半径**（`subtle blur`） | §1 散文，**无数值** | ★ **无对应字段** | ★★ **缺（本套的核心）** |
| **半透明层**（`translucent layers`） | §1 散文，**无 alpha 值** | `AppPalette.*` 可以带 alpha（`Color` 支持），但 **`ThemePack` 无「层不透明度」字段** | **缺** |
| 渐变 | ★ 规范未提及 | ★ **无对应字段** | **缺** |
| 按钮内边距 | ★ 规范未给出 | `ThemePack.buttonPadding`(:76) | ★ **有该维度**（已用 16/12） |

★★★ 这一节是本映射表**最重要**的发现：

```text
glassmorphism 的**风格内核**（磨砂模糊 + 半透明层 + 发光描边）
在本仓的 ThemePack 里**一个字段都没有**。
```

本仓有一个独立的模糊实现 —— `liquid_glass_widgets` 的 `GlassContainer`，
但它**全部是各处硬编码的，没有一处由主题包驱动**。
证据（本仓源码真读；★ 下面是**全部** 7 处构造点）：
```text
① lib/shell.dart:6220           标题栏           ← 硬编码，不读主题包
② lib/shell.dart:7007           底栏药丸条       ← 硬编码，不读主题包
③ lib/ui/widgets/source_bar.dart:215        源条    ← 硬编码
④ lib/ui/widgets/my_shelf.dart:1692         我的-分段 ← 硬编码
⑤ lib/ui/follow_page.dart:1217              追更-分段 ← 硬编码
⑥ lib/ui/settings_page.dart:3455            设置-药丸 ← 硬编码
⑦ lib/ui/settings/theme_page.dart:88        设置-明暗选择 ← 硬编码
theme_pack.dart                 全文 0 处 shadow / 0 处 blur / 0 处 gradient
```

★ 订正：本表初稿我写的是「**只用在标题栏与底栏两处**」，**那是错的** ——
  真读后是 **7 处**。
```text
订正的量级：2 → 7
订正的结论：这 7 处**没有一处**的玻璃参数（quality / shape / 开关）
           是从 ThemePack 读的 —— 它们全部写死在各自的调用点。
⇒ 后果：用户把主题换成「极简留白」或「新粗野主义」，
        这 7 块液态玻璃**照旧存在**，一块都不会少、也不会变。
```
  这比初稿的说法**更严重**：不是「玻璃没接到主题上」，
  而是「玻璃在 7 个地方各写各的，主题系统完全够不着它们」。
  也正因如此，§4 里的 `useGlass` / `blurRadius` 两项不是锦上添花，
  而是**把已存在的 7 处玻璃收编进主题系统**的前提。
⇒ ★ 结论：**「液态玻璃」这套主题包现在只是「一套冷蓝配色 + 大圆角」，
  它的名字叫玻璃，但它驱动不了任何玻璃效果。**
  这一点值得 Owner 知道 —— 它是本表里最有行动价值的一条。

（注：`theme_pack.dart:684-686` 对 `builtin.glass` 的注释**已经诚实说明**了这一点：
  *「本主题**不依赖** `liquid_glass_widgets` 的运行时模糊 …… 真正的玻璃折射由标题栏/底栏那两处 GlassContainer 给」*）

### 2.5 动效（源自 §7）

与 §1.5 相同（三套的 §7 文字完全一致）：`150–250ms` vs 本仓 `150/180/200/260`。
结论同 §1.5 —— `base`=260 略超 10ms，可接受，**不建议改**。

---

## 3. claymorphism（黏土拟态）

> 规范原文 §1：`Morphism & Effects` —— *Soft, rounded 3D-like shapes mimicking malleable clay with playful, puffy elements and colorful surfaces.*

★ 这套的 §1 关键短语：`rounded`（圆） / `3D-like`（立体感） / `puffy`（蓬松）。
  与 glassmorphism 同属 Morphism 类，但**方向相反**：
  玻璃是「薄、透明、锐」，黏土是「厚、实、圆」。**两者都没有给数值。**

### 3.1 颜色（源自 §2，逐值抄录）

| OpenDesign 角色 | 规范原文值（§2） | 本仓对应字段 | 现状 | 需要的改动 |
|---|---|---|---|---|
| Primary | `#3B82F6` | `AppPalette.primary`(:58) | 有该字段 | 无 |
| Secondary | `#FFFFFF` | `AppPalette.secondary`(:64) | ★ 是字段，但语义要注意（见下） | 无 |
| Success | `#16A34A` | ★ **无对应角色** | **缺** | 需新增 `AppPalette.success` |
| Warning | `#D97706` | ★ **无对应角色** | **缺** | 需新增 `AppPalette.warning` |
| Danger | `#DC2626` | `AppPalette.error`(:75) | 有该字段 | 无 |
| Surface | `#FFFFFF` | `AppPalette.background`(:52) / `card`(:78) | 有该字段 | 无 |
| Text | `#1C398E` | `AppPalette.foreground`(:55) | 有该字段 | ★ 注意是**深蓝**不是黑 |
| Neutral | `#FFFFFF` | `AppPalette.muted`(:70) | 有该字段 | 无 |

★★ 两条**必须提请注意**的地方：

```text
① Secondary = #FFFFFF，与 Surface / Neutral **完全同值**
   ⇒ 本仓 secondary 的语义是「比背景亮一档的填充」（app_palette.dart:63）
     若把 #FFFFFF 填进 secondary，在 #FFFFFF 底上**完全不可见**。
   ⇒ 这一项**不能按字面落**，需要引入 derived 规则或请 Owner 裁决。

② Text = #1C398E 是**深蓝**（不是近黑）—— 与另两套的 Text 色调不同。
   本仓 foreground 可直接承接，但要注意与 primary #3B82F6 同色系，
   需重新验 WCAG 对比度（本仓有现成断言可跑）。
```

### 3.2 排版（源自 §3）

| 规范项 | 规范原文值（§3） | 本仓对应 | 现状 |
|---|---|---|---|
| Scale | ★ **「desktop-first expressive scale」**（纯文字描述，**无数列**） | `FontSizes`(`tokens.dart:101-118`) | ★ **无法逐值映射** |
| Families · primary | `Montserrat` | `app_typeface.dart:39-41` | 有意不同（中文覆盖）；**注意 `Montserrat` 同样零中文覆盖** |
| Families · display | `Poppins` | 无 display 分族 | **缺** |
| Families · mono | `JetBrains Mono` | 无等宽族 | **缺** |
| Weights | 9 档 | 2 档 | 刻意保留（理由同 §1.2） |

★ 三套里**唯一给了两套不同字族**（primary=Montserrat / display=Poppins）的就是 claymorphism，
  这正是 §4 汇总里「字体族分 region」那条的动因。

### 3.3 间距（源自 §4）

| 规范项 | 规范原文值（§4） | 本仓对应 | 现状 |
|---|---|---|---|
| Spacing scale | `4/8/12/16/24/32`（6 档） | `Sp`(`tokens.dart:43-53`) | ★ **规范是子集**，同 §1.3 |

⇒ 零改动即可满足（6 档全部存在，映射同 §1.3）。

### 3.4 形状 / 边缘 / 效果（本套的**第二处重灾区**）

| 维度 | 规范原文值 | 本仓对应 | 现状 |
|---|---|---|---|
| 圆角 | ★ **规范未给出** | `ThemePack.radius`(:69) | ★ **有该维度**（黏土应为大圆角，如 24~34；本仓 `Radii.xxl`=34 可用） |
| 描边 | ★ 规范未给出 | `ThemePack.borderWidth`(:83) | 有该维度 |
| **内阴影**（`3D-like` / `puffy` 的关键） | ★ 规范未给出 | ★ **无对应字段** | ★★ **缺（本套核心）** |
| **外阴影** | ★ 规范未给出 | ★ **无对应字段** | **缺** |
| **双向阴影**（黏土质感 = 左上亮 + 右下暗） | ★ 规范未给出 | ★ **无对应字段** | ★★ **缺** |
| 按钮内边距 | ★ 规范未给出 | `ThemePack.buttonPadding`(:76) | 有该维度 |

★★★ 黏土的**全部立体感**来自「一枚元素上两条方向相反的阴影」：
```text
左上 inset 亮色（受光面）  +  右下 inset 暗色（背光面）  ⇒ 看起来像一块被捏过的黏土
```
本仓 `ThemePack` 对这种形态**零表达能力** —— 连一个 `BoxShadow` 字段都没有。
（本仓界面里确实有 6 处 `BoxShadow`，但全部是**各处硬编码**的，见 §4.3。）

### 3.5 动效（源自 §7）

同 §1.5（`150–250ms`）。★ 但黏土的 §1 写了 `playful`，
  而本仓有一条现成的、带**回弹**的曲线可用：`Motion.spring`（`tokens.dart:173`，
  `Cubic(0.34, 1.56, 0.64, 1)`，注释写明是「按钮回弹」）—— 正好对上 `playful`。

---

## 4. ★ 本仓表达不了的维度（汇总 · 后续施工清单）

这一节是本表的**行动清单**。判据：三套规范（含其散文）里提到、
而 `ThemePack`（`theme_pack.dart:42-94`）**没有任何字段能表达**的东西。

### 4.1 建议新增字段（按「能解锁多少套」排序）

| # | 建议字段名 | 类型 | 能解锁 | 依据（规范原文） | 现状证据 |
|---|---|---|---|---|---|
| 1 | `shadow` | `List<BoxShadow>?` | neobrutalism（硬投影）+ claymorphism（立体） | neo §1 `bold borders`/§5 提到 shadows；clay §1 `3D-like`, `puffy` | `theme_pack.dart` 全文 **0 处** shadow |
| 2 | `blurRadius` | `double?` | glassmorphism（核心） | glass §1 `subtle blur`, `Frosted glass effect` | 同上 0 处 blur |
| 3 | `useGlass`（或 `glassQuality`） | `enum?` | glassmorphism（核心） | glass §1 `liquidglass effect`, `glassmorphism` | ★ 玻璃共 **7 处**构造点，**全部硬编码、全部不读 `pack`**（清单见 §2.4） |
| 4 | `surfaceOpacity` | `double?` | glassmorphism | glass §1 `translucent layers` | `ThemePack` 无「层不透明度」字段 |
| 5 | `borderGlow` | `Color?`（或 `shadow` 的专门化） | glassmorphism | glass §1 `luminous borders` | `borderWidth` 只管粗细，不管发光 |
| 6 | `gradient` | `Gradient?` | 三套都可能用 | §2 的 Surface 均为单色，但 §1 的 `colorful surfaces`(clay) 暗示渐变 | 0 处 gradient |
| 7 | `fontScale` | `List<double>?` | claymorphism + glassmorphism | clay §3 `desktop-first expressive scale`；glass §3 `mobile-first compact scale` | `FontSizes` 是**全局常量**，`ThemePack` 无字号字段 |
| 8 | `fontFamily` / `displayFontFamily` | `String?` | 三套（都要换字族） | 三套 §3 的 `Families` 各不相同 | `AppTypeface.forPlatform` 只按 `Brightness` 选（`app_typeface.dart:37-41`），**不看主题包** |
| 9 | `letterSpacing` | `double?` | 三套 | §3 未给，属风格推断 | 本仓有 21 处硬编码 `letterSpacing`/`strokeWidth` |
| 10 | `success` / `warning` / `info`（`AppPalette` 字段） | `Color?` | 三套**全部** | 三套 §2 都给了 `Success` + `Warning`；glass 另给 `info` | `AppPalette` 13 个角色里**没有**这三个 |

### 4.2 不建议新增的（并说明为什么）

| 维度 | 规范提到 | 为什么**不**做 |
|---|---|---|
| 9 档字重 | 三套 §3 都列了 `100…900` | ★ 本机字库（`msyh.ttc`）只有 400/700 两个真实面，加了也渲染不出区别；且会放回已修复的「粗细不一」。**见 `tokens.dart:120-143`** |
| `Inter` / `Montserrat` 等拉丁族 | 三套 §3 的 primary family | ★ 这些族**零中文覆盖**，直接换回会重现「中文粗、数字细」。要换必须内嵌覆盖中文的可变字重字族。**见 `app_typeface.dart:11-22`** |
| 改 `Motion.base` 260→250 | §7 `150–250ms` | 260 只超上界 10ms（肉眼不可辨），而它被 18 处使用，改它等于改全局节奏 |
| 改 `Sp` 刻度 | §4 | ★ 规范的 `4/8/12/16/24/32` 是本仓 10 档的**子集**，无需改动 |

### 4.3 现有「硬编码」清单（新增字段时应收编的对象）

若将来新增 `shadow` / `gradient` 字段，这些**现在绕过令牌系统**的地方应改为消费字段：

```text
BoxShadow      6 处：follow_page.dart:1441 / player_popover.dart:330 / app_toast.dart:270
                     my_shelf.dart:2207 / reorderable_card_grid.dart:974 / source_bar.dart:543
blurRadius     8 处：follow_page.dart:1443(=8) / player_popover.dart:332(=16)
                     app_toast.dart:272(=18) / my_shelf.dart:2209(=8) / live_embedded_player.dart:1932,1944(=6)
LinearGradient 7 处：follow_page.dart:1434 / player_bottom_bar.dart:1188 / player_page.dart:17747
                     live_embedded_player.dart:2172 / my_shelf.dart:2200 …
elevation      5 处：theme_bridge.dart:251(=0) / :268(=0) / :314(=8) / app_menu.dart:116,230(=0)
```

★ 注意 `theme_bridge.dart:314` 的 `elevation: 8` —— 它是**菜单**的立体感来源，
  也是本仓唯一一处主题层带着 elevation 的地方；新增 `shadow` 字段时应一并考虑。

### 4.4 顺带发现的一处**命名不一致**（建议顺手修）

本仓圆角有**两个真源**，值相同但名字不同：

```text
lib/ui/tokens.dart:79          Radii.lg = 22
lib/ui/theme_bridge.dart:65    const _defaultRadius = 10.0;   ← 默认圆角
lib/ui/theme/theme_language.dart  const kDefaultRadius = 10.0; ← 与上面同值
```
`theme_language.dart:53-57` 的注释**自己就写了**「与 `theme_bridge._defaultRadius`
**必须同值** …… theme_bridge 那边应当改成引用本常量，避免两个真源」，
但**至今没做**（因为 `_radius` 还被 `_shape()`/输入框等 10+ 处引用，改动面大）。

⇒ 与本任务的关系：若将来新增「主题包可覆盖圆角」的档位，**这个双真源会立刻变成坑**。
  建议在新增任何圆角相关字段**之前**先合并它。

---

## 5. 三套横向对照（速查）

| 维度 | neobrutalism | glassmorphism | claymorphism | 本仓现状 |
|---|---|---|---|---|
| Primary | `#FDC800` | `#1856FF` | `#3B82F6` | ✅ 字段有 |
| Success/Warning | ✅ 都给了 | ✅ 都给了 + info | ✅ 都给了 | ❌ **无字段** |
| Text | `#1C293C` | `#141414` | `#1C398E` | ✅ 字段有 |
| 字号刻度 | `13/15/17/21/27/35` | 「compact scale」无数列 | 「expressive scale」无数列 | ⚠️ 与规范都不同 |
| 间距刻度 | `4/8/12/16/24/32` | 「comfortable」无数列 | `4/8/12/16/24/32` | ✅ **规范是子集** |
| 字重 | 9 档 | 9 档 | 9 档 | ⚠️ 刻意 2 档（**保留**） |
| 字族 | Inter | Plus Jakarta Sans | Montserrat + Poppins | ⚠️ 中文覆盖考量（**保留**） |
| 圆角 | 未给，推断 0 | 未给，推断大 | 未给，推断很大 | ✅ 字段有 |
| 边框粗细 | 未给（§1 说 bold） | 未给 | 未给 | ✅ 字段有 |
| 分隔线 | 未给 | 未给 | 未给 | ✅ 字段有 |
| 按钮内边距 | 未给 | 未给 | 未给 | ✅ 字段有 |
| **阴影** | 未给（标志性） | 未给 | 未给（**核心**） | ❌ **无字段** |
| **模糊** | — | 未给（**核心**） | — | ❌ **无字段** |
| **透明度层** | — | 未给（**核心**） | — | ❌ **无字段** |
| **发光边框** | — | 未给（**核心**） | — | ❌ 无（只有粗细） |
| 渐变 | — | — | `colorful surfaces` | ❌ **无字段** |
| 动效 | `150–250ms` | `150–250ms` | `150–250ms` | ✅ `150/180/200/260` |

---

## 6. 结论与建议动作（给 Owner）

### 6.1 三句话总结

```text
① 三份规范**只给了颜色、字号刻度、字族、字重、间距**；
   圆角/边框/阴影/模糊 **一个数值都没有** —— 那些是风格名带来的推断，不是规范数据。

② 本仓的四个设计语言维度（radius/borderWidth/dividerThickness/buttonPadding）
   足以覆盖三套的「形状 + 边缘 + 按钮」；间距维度**规范是本仓的子集**，零改动。

③ ★ 真正缺的是「**效果**」那一层：阴影 / 模糊 / 透明度层 / 发光 / 渐变。
   而 glassmorphism 与 claymorphism **两套的风格内核恰好全在这一层**。
```

### 6.2 建议的施工顺序（若 Owner 决定做）

```text
第 1 步  AppPalette 补 success / warning / info            ← 三套都需要，改动最小、收益最确定
第 2 步  ThemePack 补 shadow(List<BoxShadow>)              ← 同时解锁 neo 硬投影 + clay 立体感
第 3 步  ThemePack 补 blurRadius + surfaceOpacity          ← 解锁 glass 的磨砂层
第 4 步  ThemePack 补 fontFamily / fontScale               ← 需先解决「中文覆盖」问题
第 5 步  合并圆角双真源（§4.4），再做任何圆角相关新增      ← 放在动圆角之前
```

★ 第 2、3 步的顺序建议**先 shadow 后 blur**，理由：
```text
shadow 一条字段解锁两套（neo + clay），且本仓已有 6 处硬编码 BoxShadow 可直接收编；
blur 只解锁一套，且它需要先回答「玻璃要不要在测试环境降级」
（本仓已知：GlassContainer 在 flutter_tester 里**不光栅化**）。
```

### 6.3 本轮**没有**做的事（边界声明）

```text
❌ 没有改 lib/ 下任何代码（本任务只出规划）
❌ 没有为「规范未给出」的维度编造任何数值（圆角/阴影/模糊一律标注为推断或缺失）
❌ 没有动 docs/notes/plan-no-material-and-parse.md（那是 dlg-plugin 的）
❌ 没有 commit / push
```

### 6.4 一处**存疑**，需要 Owner 或规范作者确认

本仓已有三套「设计语言」主题（`theme_pack.dart:829-855`）：

```text
builtin.glass      液态玻璃     radius 22 / border 1   / divider 1 / padding 16-12
builtin.neoBrutal  新粗野主义   radius 0  / border 2.5 / divider 3 / padding 18-14
builtin.minimal    极简留白     radius 4  / border 1   / divider 1 / padding 12-10
```

★ 它们与 OpenDesign 三套的**名字对得上**（`glass` / `neoBrutal`），
**但配色完全不同**，因为本仓那三套的色值是按 WCAG 自行调过的：
```text
本仓 builtin.neoBrutal 主色 = _brutalPalette（见 theme_pack.dart，酸黄系）
OpenDesign neobrutalism 主色 = #FDC800
```
⇒ **存疑**：这两者是「同一设计意图的两次独立实现」，还是「应当对齐」？
  本表**不做假设**，如实标出，请 Owner 定。这直接决定第 1 步的 `success`/`warning`
  是「新增字段」还是「重填已有三套的配色」。

---

## 附录 A：引用出处索引

### A.1 OpenDesign 规范（全部来自 MCP 真读）
```text
od://design-systems/neobrutalism/DESIGN.md   §1 §2 §3 §4 §5 §6 §7 §8 §9
od://design-systems/glassmorphism/DESIGN.md  §1 §2 §3 §4 §5 §6 §7 §8 §9
od://design-systems/claymorphism/DESIGN.md   §1 §2 §3 §4 §5 §6 §7 §8 §9
```
（三份结构相同：§2 颜色 / §3 排版 / §4 间距 是有数值的三节，其余为方法论或散文。）

### A.2 本仓文件与行号
```text
lib/ui/tokens.dart:43-53        Sp.x1..x16 = 4/8/12/16/20/24/32/40/48/64
lib/ui/tokens.dart:79-94        Radii xs8/sm12/md16/lg22/xl28/xxl34/full999
lib/ui/tokens.dart:101-118      FontSizes cap12/sm14/base16/lg20/xl28/display46
lib/ui/tokens.dart:144-150      FontWeights regular(w400)/semibold(w600)
lib/ui/tokens.dart:159-234      Motion fast150/base260/slow420/…
lib/ui/tokens.dart:173          Motion.spring = Cubic(0.34,1.56,0.64,1)
lib/ui/app_palette.dart:46-81   AppPalette 13 个角色（barrier/background/foreground/primary/
                                primaryForeground/secondary/secondaryForeground/muted/
                                mutedForeground/error/card/border + brightness）
lib/ui/app_palette.dart:87      AppPalette.dark
lib/ui/app_palette.dart:108     AppPalette.light
lib/ui/theme/theme_pack.dart:42-94   ThemePack 字段全集
lib/ui/theme/theme_pack.dart:69      radius
lib/ui/theme/theme_pack.dart:76      buttonPadding
lib/ui/theme/theme_pack.dart:83      borderWidth
lib/ui/theme/theme_pack.dart:88      dividerThickness
lib/ui/theme/theme_pack.dart:235-242 borderWidth 范围校验 [0,6]
lib/ui/theme/theme_pack.dart:829-855 三套设计语言主题的四个维度取值
lib/ui/theme_bridge.dart:65          _defaultRadius = 10.0
lib/ui/theme_bridge.dart:314         elevation: 8（菜单）
lib/ui/theme_bridge.dart:620-680     LightTokens
lib/ui/app_typeface.dart:37-41       字族只按 Brightness 与 platform 选，不看主题包
lib/ui/app_typeface.dart:11-22       为什么不用 Inter（零中文覆盖）
pubspec.yaml:251                     fonts: 整块被注释（无内嵌字体）
```

### A.3 全局搜索证据（用于「缺什么」的判断）
```text
BoxShadow        6 处硬编码
blurRadius       8 处硬编码
LinearGradient   7 处硬编码
elevation        5 处（theme_bridge 3 + app_menu 2）
theme_pack.dart  0 处 shadow / 0 处 blur / 0 处 gradient / 0 处 fontSize / 0 处 fontFamily
```
