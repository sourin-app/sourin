# 第 66 轮：Material 移除（轨道 E · M2）—— 6 步实记

> **给下一轮接手的人**：这份文档回答的问题不是「做了什么」，而是
> **「这里为什么长现在这样」**。它同时记录了**做了什么**和**决定不做什么**。
>
> 如果你正准备「把剩下的 Material 也清掉」，**先读第 6 步和混合态总表**。
> 那里有一条结论是「不要再动」，理由有实测数据。
>
> **纪律**（沿用本仓惯例）：
> ```text
> ① 每个判断都要有**读数**或**源码行号**，不许"应该如此"
> ② 判据要**行为断言**，不是"组件在树上"
> ③ 每步都做**故障注入**，证明门禁会红（不做注入 = 不知道门禁有没有用）
> ④ 混合态是**有意的**，不是遗漏；但必须**登记**，否则下一个人会当成遗漏
> ```

**Owner 路线**：彻底不用 Material 组件，全部自建/玻璃（原话：「太丑了」）
**Lead 裁决**：分 6 步走，**不合并**（「混在一起做，出问题时分不清是哪一步改坏的」）
**时间**：2026-10-18
**提交**：`0cc9cbc` → `5f797cf` → `b0e23a0` → `574968a` → `d756d04` → 本轮（Step 6 只出文档与登记）

---

## 一、6 步总表

| 步 | 改什么 | 变成什么 | 提交 | 门禁 |
|---|---|---|---|---|
| 1 | `TextButton` ×10 | `AppTextButton` | `0cc9cbc` | `zz_t66_glass_detail_test.dart`（10 条） |
| 2 | `IconButton` ×2 + `Tooltip` | `AppIconButton` + `AppTooltip` | `5f797cf` | `zz_t66_glass_detail_icon_test.dart`（13 条） |
| 3 | `OutlinedButton` ×4 | `AppOutlinedButton` | `b0e23a0` | `zz_t66_glass_detail_outlined_test.dart`（15 条） |
| 4 | `AlertDialog` ×3 | `AppGlassDialog` | `574968a` | `zz_t66_glass_dialog_test.dart`（25 条） |
| 5 | `SnackBar` ×6 | `showAppToast` | `d756d04` | `zz_t66_glass_toast_test.dart`（10 条） |
| 6 | `Scaffold` ×2 | **不动**（有证据） | 本轮 | `zz_t66_step6_scaffold_kept_test.dart`（6 条） |

外加：`AppSemanticColors` 语义色层（`3a19ab3`）、`LightTokens` 迁出（`da09b4f`）、
`follow_page` 玻璃化（`b0f45d1`）。

---

## 二、逐步：改了什么、为什么

### 第 1 步：`TextButton` ×10 → `AppTextButton`

**为什么**：`TextButton` 是最基础的按钮，全站视觉由它铺开。它自带 Material 的
水波纹 + 状态层 + 默认内边距，与本仓的玻璃风格不一致。

**关键实现点**：
```text
· 链条 AppTextButton → AppInkWell → PressFeedback 全部只 import flutter/widgets.dart
· 文字色不能读 Text.style?.color（那是 null）—— 实际来自外层
  DefaultTextStyle.merge ⇒ 要从 DefaultTextStyle.of(element).style.color 读
```

**踩的坑**：`AppTextButton` 早就写好了却**零调用点**（见第五节复盘）。

### 第 2 步：`IconButton` ×2 → `AppIconButton`

**关键发现（一条注释里的数字是错的）**：
```text
原代码注释写 `constraints: tightFor(28, 28)`，说图标按钮 28×28。
★ 但实测渲染出来是 **48×48** —— Material 用 min tap target 覆盖了 constraints。
⇒ 注释里的 28 **从来没有生效过**。
⇒ 判据（门禁）按实测的 48 写，不按注释的 28 写。
```

**Lead 的判据**：`「注释里写的数值，必须实测验证一次，否则它只是意图」`

### 第 3 步：`OutlinedButton` ×4 → `AppOutlinedButton`

难点是**几何复刻**，要让新组件与 Material 的尺寸逐像素一致。

**踩的坑（3 个）**：
```text
① VisualDensity 数学算错
   compact(-2,-2) 的 baseSizeAdjustment 是 **(-8,-8)**（每档 ×4），不是 (-2,-2)。
   我按 (-2,-2) 算，高度变成 16（应为 32）。

② 垂直内边距无法从 padding 链推导
   Material 报 padding (10,3,10,3)，但总高 32、内容 16 ⇒ 实际每边 8。
   那个 3 还叠了 _InputPadding / Align。
   ⇒ 改成「校准结果」而不是「复算推导」。

③ letterSpacing 泄漏
   DefaultTextStyle.merge 继承了 bodyMedium 的 CJK letterSpacing: 0.25
   ⇒ 宽度 72.5 而 Material 是 72.0。
   ⇒ 修法：显式写 letterSpacing: 0（null 表示"不覆盖"，仍会继承）。
```

**判据必须实现无关（Lead 点出的一条）**：
```text
第一版 sideOf/radiusOf 只读 DecoratedBox ⇒ Material 实现下 Bad state: No element。
⇒ 双路径：先试 DecoratedBox.border，再试 Material.shape as OutlinedBorder。
★ Lead 原话：「否则我只是把「依赖 Material」换成了「依赖自建」，同样绑实现细节」。
```

### 第 4 步：`AlertDialog` ×3 → `AppGlassDialog`

**探查先于实现**（Lead 要求：七项能力逐个报读数，不许"应该支持"）。

| 项 | 结论 | 证据 |
|---|---|---|
| barrier | ✅ 但**默认值相反** | `glass_dialog.dart:267` 默认 `false`；`overlay_motion.dart:312` 默认 `true` |
| 焦点陷阱 | ✅ 路由层提供 | 路由实测 `CupertinoDialogRoute`，`canPop=true` |
| ESC | ✅ 同 barrier 开关 | `cupertino/route.dart:285` 文档逐字 |
| 返回键 | ✅ | `maybePop()` 返回 `true` |
| role=dialog | ✅ **强于 AlertDialog** | `GlassDialog` `scopesRoute=true`；**`AlertDialog` 是 `false`** |
| 动画 | ✅ 可 settle | 逐帧 opacity 0→1；`pumpAndSettle` ✅ |
| 溢出滚动 | ⚠️ 会溢出，**但 AlertDialog 也一样** | 两者 `Scrollable` 都 0、都抛 `RenderFlex overflowed` |

**★ 两个纠正预期的发现**：
```text
① 担心的「换源列表很长」**不是 AlertDialog** —— 三个都是 title + 一两句正文。
   「换源列表」走 AppMenu（showMenu），与本次替换无关。
② barrier 默认值相反 ⇒ 直接换会让用户"点外面关不掉、ESC 失效"
   ⇒ 正是 Lead 明令不许的**功能退化**。
```

**★ 最关键的设计决定：不自带 `show()`**
```text
本仓唯一对话框入口：overlay_motion.dart:311 showAppDialog
它的文件里逐字写着（:282-284）：
  「lib/ 里除本文件与两个真机探针外，不许再出现裸 showDialog(」
  「★ 不许为了"让 showDialog 退场更快"去自建 RawDialogRoute ——
    那会丢掉 _FullWindowDialogWrapper / _DialogPopScope 等 3.47 才有的对话框语义」

而 liquid_glass_widgets 的 GlassDialog.show() 内部调 showCupertinoDialog
⇒ **绕过** showAppDialog ⇒ 丢 task-104 的 animationStyle
⇒ 所以 AppGlassDialog 只做 Widget，弹出交给 showAppDialog。
```

**★ 一处"看起来该复用、实测不能复用"**：
```text
本仓已有 AppDialogShell(glass: true)，参数看着正合适。
但实测 showAppDialog(builder: AppDialogShell(...)) ⇒ 占位 800×600 **全屏**。
根因：它自带铺满全屏的 scrim（:340 GestureDetector + :472 ColoredBox）。
⇒ 全屏面板形态，不是对话框形态：
   ① 盖住 showDialog 自己的 barrier
   ② 它的 onTap 关窗**绕过** barrierDismissible
      实测：传 barrierDismissible:false 后点外面**仍然关了**
```

### 第 5 步：`SnackBar` ×6 → `showAppToast`

**★ 这不是"换个组件"，是可靠性修复**：
```text
ScaffoldMessenger.maybeOf(context)?.showSnackBar(...) 的 `?.` **形同虚设**：
  maybeOf 只保证 messenger **存在**，不保证**能显示**（MaterialApp 自带一个）。
  showSnackBar 内部断言 '_scaffolds.isNotEmpty'。

★ 本仓有真实事故（skip_marker_dialog.dart:1347-1400，2026-10-02）：
  `_toast` 在**赋值之前**抛异常 ⇒ 把 _applyEdge 里 switch 的赋值吞掉
  ⇒「只要「+」被夹到边界，值就卡住不动」
  ⇒ Owner 看到的是「那四个三角根本不能拖动 / 调不动」（t463）
```
**一个 toast 崩掉了一个滑块。**

`showAppToast` 的设计从根上避免它：`AppToaster.maybeOf` 找不到宿主**静默 no-op、不抛异常**。

**★ 一个数据错误（我自己的）**：
```text
先报"5 处"，实际 **6 处**。漏的是 skip_marker_dialog.dart:1437。
原因：第一次 grep 看到 15 处，逐条扫了前几条全是注释（那文件用大量注释记事故），
      就归纳成"全是注释" ⇒ **用抽样归纳代替逐条核实**。
可靠做法：**剥注释后全量扫描**（.probe/scan_snackbar.py）。
```

### 第 6 步：`Scaffold` ×2 → **不动**（本步产出是"不做的理由"）

**★ 先纠正一个事实**：
```text
「Scaffold ×2」在源码层面对，但用途完全不同：
  lib/ui/detail_page.dart:2548  ← 只在 embedded == false 才走
    ★ 生产路径就是 embedded ⇒ 这个 Scaffold **根本不执行**
  lib/ui/media_page.dart:1937   ← 这才是生产路径上真正执行的
⇒ 真机只碰到 1 个。
```

**⑤ 视觉差异：像素实测 0 差异**
```text
400×300、空内容、逐字节对比（.probe/probe_e6_diff_test.dart）：
  Scaffold 外壳 vs 裸 ColoredBox 外壳 ⇒ 不同像素 = **0 / 120000**
  三个采样点 RGB 全等：(0,0) (200,150) (399,299) 都是 10,10,10

⚠️ 带文字时出现 1054/120000 差异 —— 那是**文字抗锯齿**
   （Scaffold 的 DefaultTextStyle 给了不同字体度量），与它自身绘制无关。
   空内容 0 差异是排除该项干扰的决定性证据。
```

**⑥ 依赖面：零连锁**
```text
· Scaffold.of(        全仓 0 处
· ScaffoldMessenger   全仓 0 处（第 5 步正好清空）
· appBar / FAB / drawer / bottomNavigationBar / bottomSheet / persistentFooterButtons
  —— 两处**一个都没用**
· 实际只用了 backgroundColor + body 两个参数
```

**★ 关键判断**：
```text
`Scaffold` **本就已经不含 Material**（实测树下 Material 数 = 0）
⇒ 这根本不是"去掉 Material 视觉组件"的问题
⇒ 为它做改动**不服务于 Owner 的目标**
```

**为什么不换成已有的 `AppScaffold`**：
```text
本仓已有 lib/ui/app_scaffold.dart，它的注释就写着「为什么不直接用 Material 的
Scaffold」—— 说明这个问题以前就被解决过。

实测 AppScaffold 与 Scaffold **像素 0 差异** ⇒ 换过去用户看不出区别 ⇒ 收益 0。

★ 而 AppScaffold **不处理 system padding**（只处理 viewInsets），
  Scaffold 会做 MediaQuery.removePadding。
  现在这两处不受影响 —— 但那是**当下的巧合，不是结构保证**：
  detail_page:2548 外面已包 SafeArea
  media_page:1937 整页是视频+面板，不依赖系统 padding
⇒ 将来有人在 media_page 里加一个需要系统 padding 的东西，
  就会踩到一个**只在换过 Scaffold 后才出现**的 bug。

⇒ 收益 0 + 引入隐患 ⇒ 不改。（Lead 裁决：选 B）
```

---

## 三、混合态总表（唯一权威清单）

> ⚠️ 若有变动，改 `test/zz_t66_step6_scaffold_kept_test.dart`，它是这份表的可执行版本。

| 组件 | 状态 | 步骤 / 理由 |
|---|---|---|
| `TextButton` ×10 | 已自建 | 第 1 步 `AppTextButton` |
| `IconButton` ×2 | 已自建 | 第 2 步 `AppIconButton` |
| `OutlinedButton` ×4 | 已自建 | 第 3 步 `AppOutlinedButton` |
| `AlertDialog` ×3 | 已自建 | 第 4 步 `AppGlassDialog` |
| `SnackBar` ×6 | 已自建 | 第 5 步 `showAppToast` |
| `Scaffold` ×2 | **有意保留** | 第 6 步 —— 结构容器，像素 0 差异，见上 |
| `Text` ×N | 保留 | 文本渲染不是"Material 视觉组件" |
| `InkWell` ×1 | **待评估** | 不在本轮 6 步清单内 |
| `LinearProgressIndicator` ×1 | **待评估** | 不在本轮 6 步清单内 |

**★ `InkWell` / `LinearProgressIndicator` 是下一轮的自然候选**，
本轮没做是因为不在 Lead 给的清单里（分步做的纪律）。

---

## 四、门禁与注入总览

| 步 | 门禁文件 | 条数 | 注入 | 结果 |
|---|---|---|---|---|
| 1 | `zz_t66_glass_detail_test.dart` | 10 | `inject_e_glass_detail.py` | 6/6 红 |
| 2 | `zz_t66_glass_detail_icon_test.dart` | 13 | `inject_e_glass_icon.py` | 7/7 红 |
| 3 | `zz_t66_glass_detail_outlined_test.dart` | 15 | `inject_e_outlined2.py` | 9/9 红 |
| 4 | `zz_t66_glass_dialog_test.dart` | 25 | `inject_e_dialog3.py` | 8/8 红 |
| 5 | `zz_t66_glass_toast_test.dart` | 10 | `inject_e_toast2.py` | 6/6 红 |
| 6 | `zz_t66_step6_scaffold_kept_test.dart` | 6 | （无改动，无需注入） | — |

**注入脚本都在 `.probe/`（gitignored）**。
复跑方法：`python .probe/inject_e_<名字>.py`，
它会在纯净 worktree（`/tmp/e_base`）里逐个注入、跑测试、恢复。

---

## 五、★ 复盘：这一轮我踩的 4 次「测量方法错误」

> **共同模式**：**验证前没证明装置有效**。
> 三次都是"结论看起来合理，但测量手段本身是错的"。

### ① 第 3 步：`Padding` 注入无效
```text
想证明门禁能抓尺寸变化，于是给 _DownloadButton 外面包 Padding(horizontal: 6)。
★ 但按钮在 Row 里会被收缩 ⇒ 宽度**没变** ⇒ 注入本身无效，
  门禁当然是绿的，我却差点以为"门禁漏判"。
⇒ 改成把图标 size 16→24 ⇒ 实测 80×40 vs 72×32 ⇒ 3 条红。
```

### ② 第 4 步：双向验证共用 `pumpWidget` 读到残留
```text
把 ①②③④⑦ 塞进**同一个测试体**、共用 pumpWidget。
⇒ ① 的"点外面应关"读到的是**上一次残留**的 AlertDialog 实例
⇒ 报了一个假的「判据在旧实现下不成立」。
⇒ 改成**一场景一用例**（tester 自己在用例边界重建树）。
```

### ③ 第 5 步：`tap` 目标是空的 `SizedBox.expand()`
```text
t.tap(find.byType(GestureDetector))，而 child 是 SizedBox.expand() —— **空的**。
实测：
  [T3] tapped = 0                    ← tap 根本没触发 onTap
  [T3] 直接调后 Text = [直接调对照]    ← API 本身是好的
⇒ 不查这一步，就会把"toast 没出现"当成 showAppToast 坏了。
⇒ 换成 ColoredBox 后通过。
```

### ④ 第 5 步：用抽样归纳代替逐条核实
```text
第一次 grep skip_marker_dialog.dart 看到 15 处 showSnackBar，
逐条扫了前几条全是注释，就归纳成"全是注释"。
★ 但 :1437 是**真实调用**。
⇒ 可靠做法：**剥注释后全量扫描**，而不是"看了几条就下结论"。
```

### ⑤（附加，第 4 步）误把组件当缺陷，实为探针等太短
```text
第一版探针显示"GlassDialog 完全关不掉"（连 pop 都无效），差点当缺陷上报。
查下来是**我探针等错了**：退出动画要 ~800ms，我只等了 400ms。
逐次 pump：200ms→1, 400ms→1, 600ms→1, **800ms→0**
★ 若按第一版报上去，会否掉一个完全可用的组件。
```

---

## 六、★ 这一轮沉淀的几条硬判据

```text
① 「注释里写的数值，必须实测验证一次，否则它只是意图」
   例：IconButton 注释说 28×28，实测 48×48；注释里的 28 从未生效。

② 「先查已有的 ≠ 一定要用已有的」
   例：AppDialogShell 看着能复用，实测它是全屏面板形态（自带 scrim），
       会破坏 barrier 语义。查完的结论可以是"不能用"。

③ 「能换 ≠ 该换」
   例：Scaffold 换成 AppScaffold 成本几乎为零、像素 0 差异，
       但收益也是 0，且引入 system padding 的潜在隐患 ⇒ 不做。

④ 「看不出区别的组件，先证明它有没有视觉表现，再决定改不改」
   方法：400×300 视口 + **空内容** + 逐字节对比。
   空内容很关键 —— 带文字时文字抗锯齿会造成假差异。

⑤ 「`.?` 不保证能执行」
   maybeOf 只保证对象存在，不保证操作能成功。
   可靠性要求高的地方（比如"提示不能把调用方搞崩"），
   要么自己 try/catch，要么用设计上就不抛的 API。

⑥ 「测试装置本身要验证有效」
   注入无效 / 读到残留 / tap 到空 widget —— 三种形态，同一个错。
```

---

## 七、下一步（给接手的人）

**本轮 Material 移除已完成**：能改的都改了，不该改的有证据。

**自然的下一轮候选**：
```text
· InkWell ×1（detail_page）
· LinearProgressIndicator ×1（detail_page）
· settings_page 的玻璃化（Owner 提过的下一个目标）
· lib/design/widgets/** 的公开组件整理
```

**不要做的事**：
```text
· 不要因为"看到 Scaffold(" 就去改（读第三节的理由）
· 不要把混合态当成遗漏去"修"（它是有意的）
· 不要在没做故障注入的情况下相信门禁是绿的
```

---

## 附：相关文件索引

```text
lib/design/widgets/app_text_button.dart          第 1 步
lib/design/widgets/app_icon_button.dart          第 2 步
lib/design/widgets/app_outlined_button.dart      第 3 步
lib/design/widgets/app_glass_dialog.dart         第 4 步
lib/ui/widgets/app_toast.dart                    第 5 步（showAppToast）
lib/ui/app_scaffold.dart                         第 6 步（评估过，未采用）
lib/design/theme/app_theme.dart                  语义色入口 resolvedOf/themeDataFor
lib/ui/widgets/overlay_motion.dart               showAppDialog —— 全仓唯一对话框入口

test/zz_t66_glass_detail_test.dart               第 1 步门禁
test/zz_t66_glass_detail_icon_test.dart          第 2 步门禁
test/zz_t66_glass_detail_outlined_test.dart      第 3 步门禁
test/zz_t66_glass_dialog_test.dart               第 4 步门禁
test/zz_t66_glass_toast_test.dart                第 5 步门禁
test/zz_t66_step6_scaffold_kept_test.dart        第 6 步登记（权威清单）
```
