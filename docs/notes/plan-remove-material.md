# 全量去 Material 施工方案（第 64 轮 4/8/9）

**Owner 要求**：「按照全套换掉 material去做」「不接受分阶段，直接全量替换」

---

## 0. 实测起点（2026-10-17，逐条可复现）

```# 真正 import flutter/material 的产品文件：0 个
grep -rln "^import .*package:flutter/material.dart" lib/ | grep -v spike-backup
# → （空）

# import material_ui 的产品文件：124 / 179
grep -rl "package:material_ui/material_ui.dart" lib/ | wc -l
# → 124

# 测试里 MaterialApp：233 个
grep -rl "MaterialApp" test/ | wc -l

# 不同 Icons.* 图标：148
grep -rho "Icons\.[a-zA-Z0-9_]*" lib/ | sort -u | wc -l```

**⇒ 所以「去 Material」不是修几个漏网文件，而是把 `material_ui` 这个包整个摘掉。**

仓库**早已**统一到 `material_ui`（不是 `flutter/material`）。问题不是��套打架，
而是「整个 UI 层建在 Material 之上」。

---

## 1. 工作量（按出现文件数排序，实测）

```67  Theme              ← 最重：换自建 AppTheme
62  Material           ← 换自建 AppSurface（纸面/卡片容器）
57  Icons + 57 Icon    ← 换自建图标体系（148 个不同图标）
49  InkWell            ← 已有 PressFeedback 可替代
37  TextButton         ← 自建 AppTextButton
29  Scaffold           ← 自建 AppScaffold
28  TextField          ← 自建 AppTextField
28  IconButton         ← 自建 AppIconButton
23  ColorScheme        ← 换 AppPalette（已有 12 语义色）
18  CircularProgressIndicator ← ★ 已由 Lead 改成自绘
17  Tooltip / 17 ThemeData
10  SwitchListTile / 9 SnackBar / 8 Slider / 8 Divider
7   LinearProgressIndicator / 7 Dialog / 6 ListTile / 5 Switch
4   PopupMenuButton / 4 AppBar / 2 RefreshIndicator
1   NavigationBar / ElevatedButton / Drawer / Card 各 1```

---

## 2. 已有可复用资产（不重复造）

```lib/ui/app_palette.dart             12 个语义色
lib/ui/tokens.dart                  Sp / FontSizes / Radii
lib/ui/widgets/press_feedback.dart  PressFeedback ← 替代 InkWell
lib/ui/widgets/app_dialog_shell.dart / app_dialog_section.dart  弹窗外壳
lib/ui/widgets/app_menu.dart        AppMenu ← 替代 PopupMenuButton
lib/ui/widgets/app_toast.dart       AppToast ← 替代 SnackBar
lib/ui/widgets/app_loading.dart     ★ 自绘转圈（Lead 刚改）
lib/ui/theme/theme_pack.dart        主题包
lib/ui/theme_bridge.dart            ThemeData 桥接（要拆）```

⚠️ 先例：`forui` 已于 2026-10-10 移除（pubspec.yaml:104）。摘依赖本仓有过先例。

---

## 3. 施工顺序（Owner 不分阶段，但内部必须有依赖顺序）

### A. 建底座 lib/design/

```lib/design/tokens/   颜色/间距/圆角/字号（从 tokens.dart + app_palette.dart 迁）
lib/design/theme/    AppThemeData（取代 ThemeData / ColorScheme / Theme）
lib/design/icons/    AppIcon（148 个图标映射，取代 Icons.*）
lib/design/widgets/  基础控件（按钮/输入/开关/滑块/进度/卡片）```

### B. 图标体系（最大暗礁）

```难点：Icons 类只在 Material 层，8825 个 IconData / 29464 行；本仓用了 148 个。

候选：
  1) 引入 Lucide（material-free），148 个逐个映射
     · 优点：质量高   · 缺点：148 次人工映射 + 视觉可能被 Owner 否
  2) 自绘矢量图标  · 太慢，不可行
  3) 只打包 Material Icons 字体子集 + 自建 20 行 IconData 兼容类
     · 优点：图标 100% 不变，风险最小

⇒ 推荐 3（保留现有视觉），必要处再换 1```

### C. 主题设施替换

```现在：Theme.of(context) / ThemeData / ColorScheme（67+17+23 处）
换：AppTheme.of(context) → AppThemeData（12 语义色 + 间距/圆角/字号）

★ theme_bridge.dart 现在做「AppPalette → ThemeData」，改造后变成
  「AppPalette → AppThemeData」，反而更简单。```

### D. 控件替换

```InkWell(49)      → PressFeedback        [已有]
TextButton(37)   → AppTextButton        [新建]
IconButton(28)   → AppIconButton        [新建]
TextField(28)    → AppTextField         [新建]
Switch(5)+SwitchListTile(10) → AppSwitch / AppSwitchTile
Slider(8)        → AppSlider            [新建]
Divider(8)       → AppDivider           [新建]
Dialog(7)        → AppDialog            [外壳已有]
SnackBar(9)      → AppToast             [已有]
Material(62)     → AppSurface           [新建]
Scaffold(29)     → AppScaffold          [新建]
Tooltip(17)      → AppTooltip           [新建]
PopupMenuButton(4) → AppMenu            [已有]```

### E. 移除 MaterialApp（测试 233 处）

```产品侧：shell.dart 的 MaterialApp（1 处）→ WidgetsApp + 自建壳
测试侧：233 个 MaterialApp → 统一脚手架 AppTestHost

⚠️ 测试侧必须一次换完，否则 material_ui 无法从 pubspec 移除。
   做法：先建 AppTestHost，脚本批量替换，再人工抽查。```

---

## 4. 关键风险

```① 【最大】window_manager 依赖 flutter/material
   · 已查明：7 个文件 import，但只读 Theme.of，不安装 Theme
   · ⇒ 不是渲染阻塞，但会让 flutter/material 留在依赖图
   · ⇒ 门禁判据必须是「lib/ 源码不出现 material import」，
        不能是「依赖图里没有 material」

② 图标视觉漂移：换图标体系会让 148 个图标外观变化 ⇒ 需 Owner 认可

③ 测试 233 处：批量替换易漏，需脚本 + 抽查

④ lib/main.dart.spike-backup 也有 material import —— 是备份文件，
   应从仓库移除或 .gitignore（不属产品）```

---

## 5. 验收门禁（先故障注入证明会红）

```test/material_split_test.dart 新增断言：
  ① lib/ 里不得出现 package:material_ui
  ② lib/ 里不得出现 Icons.（改用 AppIcon）
  ③ lib/ 里不得出现 Theme.of（改用 AppTheme.of）```

⚠️ 按 Owner 纪律：**新门禁必须先故障注入证明会失败**，才承认它是绿的。
