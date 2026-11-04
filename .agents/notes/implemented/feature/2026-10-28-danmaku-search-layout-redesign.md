# Agent Note: 弹幕搜索页版面改版（N4-3 b）—— 把"观感"落成 10 条可测判据

Status: implemented

## Problem

Owner 的原始诉求只有一句：「页面根布局顺便再优化优化（弹幕设置信息架构拆分，也就是这个页面）」。
先按他选的方向 (b) 出了基线截图与 12 条清单（`.probe/n4-3-layout-baseline.md`），其中 3 条已修
（#11 过期态无声、#10 空态无引导、#1 顶栏无剧名）。剩下 8 条是**信息层级与密度**：

```text
#2/#3 输入框无可见边框、搜索按钮通栏占满、二者无分组
#4    提示文案紧贴按钮、同色系，读起来像按钮的副标题
#5    每条结果左侧重复 6 次「绑定当前集」按钮
#6    复选框距条目文字 700+px（勾选要横跨整屏）
#7    「对应本地 不绑定 ▾」看起来像纯文本，可点性弱
#8    分组标题与条目之间无分隔
#9    两侧空白不对称（左缩进 200 / 右空 260）
```

## Decision

八条一起改，并且**每条都配一条可注入变红的判据**（截图只是对照，不是判据）：

```text
#2  输入框 OutlineInputBorder（1px outline + 浅底）；搜索按钮 Align(centerLeft) 按内容宽
#3  输入框与按钮同放进 keyed 分组容器（ValueKey('danmaku-search-group')），组内 12px
#4  提示文案移到输入框**上方**、12px、onSurfaceVariant
#5  单条「绑定当前集」收进条目内 ⋯ 菜单（PopupMenuButton，key 带 match id）；批量入口不动
#6  CheckboxListTile(controlAffinity: leading)，标题左边距 170.5 → 76
#7  「对应本地」下拉套 1px 描边容器、minHeight 32、箭头随可用性变色
#8  分组标题 w600/14 + Divider(height:12)
#9  整页 symmetric(horizontal:16)，条目行 contentPadding horizontal:4
```

两处**结构性**改动，都写清了理由：

```text
① ListView(children:) → SingleChildScrollView + Column(stretch)
   —— 本页内容有界；懒构建会让页面一长就"诊断区/预览区的按钮不在元素树里"，
      `ensureVisible` 无从下手（既有门禁会 find 到 0 个）。全部构建 = 滚得到就构建得出。
② 底部动作区与搜索按钮统一为 _actionSlot(child) = Align(centerLeft, child)
   —— 这条规范原先散在两处，上一轮只改到搜索按钮才留下"底部仍通栏"的残留；
     收成一处后改一处、全页一致，注入也只有一个锚点。
③ 副标题改"满宽浅灰带子"（渠道…在带首、「不绑定 ▾」在带尾）
   —— 取舍见下。
```

## Alternatives considered

1. **把「对应本地」做成行内 chip**（消掉副标题与右侧控件之间 ~500px 空白）。
   最强理由：更紧凑，信息密度最高，也符合"标签就该贴着内容"。
   **否决** —— 实测在 800 宽窗口下 chip 的点击落点 x≈335..407，**正压住条目行的几何中心**（400），
   而"点整行选中"就是靠那条中心线。要么牺牲整行可点，要么把既有 6 份门禁的点击点改成"点勾选框"
   = **放宽判据**。两条都不接受。⇒ 改成纯装饰的满宽带子，中心线仍是"底纹"而不是控件。
2. **保留 `ListView(children:)`，改用 `scrollUntilVisible` 驱动门禁**。
   最强理由：不动结构，改动面最小。
   **否决** —— `scrollUntilVisible` 依赖"目标已在树里"的前提，而懒构建恰恰破坏这个前提；
   它会把"按钮不在树里"变成"滚不到"的假红，比现在更难诊断。
3. **不动底部按钮（只改搜索按钮）**。
   最强理由：#2 的清单条目只点了"搜索按钮通栏"。
   **否决** —— 同页两套按钮规范本身就是这轮要修的"信息层级不一致"；留着等于制造下一个残留。

## Consequences

- 收益：**+41 条门禁**（10 条新判据 + 既有 5 份门禁改形态），10 次注入全部真红；
  每条都能"改坏一处 ⇒ 精确红到那一条"。
- 收益：既有门禁**没有放宽**：diff 只有 +37/-1（`pumpAndSettle` 补齐 + stale 那条从
  "查 TextButton.onPressed==null" 改成"打开 ⋯ 菜单后菜单项 enabled==false 且点了不绑"，
  语义更强）。
- 代价：单条绑定从"一眼可见"变成"要点开菜单"。批量入口与"点整行选中"都还在，
  但**单集绑定多一次点击** —— 这是 Owner 选 (b) 时接受的取舍。
- 代价：`SingleChildScrollView + Column` 会一次性构建整页（本页条目数量级是个位数，
  实测无卡顿；若将来条目数上百需回到懒构建 + 另一种门禁写法）。
- 残留（如实）：窄窗没有像素级证据（runner 窗口固定 1280×720，`SizedBox` 夹不进去）；
  带子底色 `surfaceContainerHighest@0.35` 在浅色主题下可能偏淡；过期态 `⋯` 仍可展开（刻意保留）。

## Relations

- [Live progress and modal workflow](../bug-fix/2026-11-04-player-progress-and-danmaku-modal-workflow.md)
  supersedes the all-scroll form/action layout and `_actionSlot` decision.
  The attribution, cover, stale-result and row-selection guarantees remain.

- 上游：[../testing/2026-10-28-extract-pure-function-to-gate-behavior.md](../testing/2026-10-28-extract-pure-function-to-gate-behavior.md)
  —— 那篇讲"判据拿不到行为就抽纯函数"；本篇是同一思路的界面版：**把观感拆成可测的几何量**。
- 基线：[../../../../.probe/n4-3-layout-baseline.md]（本机开发期文档，`.probe/` 不入库）
