# Agent Note: 剩余 17 处 Material 的「必须留 / 能换」判定

Status: implemented

## Problem

去 Material 任务（Owner 第 4/8 条）走到最后 17 处时，判断标准是「这一层
Material 能不能换成 AppSurface」。判错的代价是双向的：

- **误删**：`ListTile` 家族要求最近祖先 Material 同时是绘制面，删掉后 Flutter
  当场断言 `ListTile background color or ink splashes may be invisible.`，
  测试红一片，用户点复选框时看不到任何反馈。
- **误留**：白留一层 Material，任务永远收不了尾。

难在**静态看子树看不出来**。三种假阴性（实测都撞到）：

```text
① child 是变量         Widget _card({required List<Widget> children})
                       ⇒ 体里看不到 tile，tile 在调用方实参里
② tile 藏在多跳之后    _group → _switchSection → _switchRow → SwitchListTile
                       ⇒ 三跳。我按两跳估过，漏了 danmaku 那处
③ 局部变量中转         final inner = Column(children: [...]);
                       Material(child: inner)
```

## Decision

**17 处逐处给结论，不动代码先给清单**，并把「必须留」的理由写进代码注释。

```text
必须留 Material      9 处
  ① player_page:19369            直接含 ListTile
  ② emby_page:985                SwitchListTile
  ③ emby_page:1284               ListTile
  ④ player_settings_sheet:776    经 _switchRow（静态看是 NONE，假阴性）
  ⑤ settings_kit:299             包 SettingsGestureToggle → SwitchListTile
  ⑥ settings_kit:281             child: inner；31 个调用点里 3 个传 tile
  ⑦ app_dialog_shell:221         child: child；9 个调用点里 1 个传 ChoiceChip
  ⑧ top_bar_layout:215           命令面板含 ListTile
  ⑨ danmaku_settings_dialog:1075 三跳 _group→_switchSection→_switchRow

能换 AppSurface      2 处（已完成）
  ⑩⑪ plugin_speedtest:1391/1547  child 是 ActionChip —— **不是** ListTile 家族

改用 AppInkWell      1 处（已完成）
  ⑰ top_bar_layout:265           齿轮只要点击态，无 tile 消费者

先改别的             4 处
  ⑫⑬ source_composer_dialog:341/437   _card 里包 CheckboxListTile（:482）
  ⑭ reorderable_card_grid:955         给 Overlay 里的 feedback 提供
                                       DefaultTextStyle，AppSurface 不提供
  ⑮ player_page:19572                 归 dlg-bili
  ⑯ shell:4440                        归 Lead
```

**B 类（能换）清零**。剩余全部有硬约束。

## Alternatives considered

- **靠 grep 子树里有没有 ListTile 决定** —— 最强论据是快。否决理由：
  上面三种假阴性全部踩中。最坏的一次是我据此把 danmaku 判成「能换」，
  实际要三跳才看得到 `SwitchListTile`；若无 Lead 用实测纠正，会删掉必需的
  Material 并回滚。**grep 给出的是「NONE」——它不区分「确认没有」和「没看到」**。

- **一律保留所有 Material** —— 最强论据是零风险。否决理由：任务目标就是去掉
  能去的；而且 ⑩⑪ 实测证明 ActionChip 那两处确实可以去掉（+11 全绿，
  ink-splashes 断言 0 次）。一律保留等于放弃判断。

- **直接动手逐个改，改一个跑一次测试** —— 最强论据是每步都有反馈。
  否决理由：17 处 × 每个都要挑对应测试，成本高于先出清单；
  而且「测试绿了」不等于「这处真的该换」（可能那个测试没渲染到这条路径）。
  ⇒ 先清单、再审、最后只改确认能换的。

## Consequences

- **收益**：
  - 剩余 Material 每一处都有据可查，不是「感觉不能删」。
  - 三种假阴性写成注释留在代码里，下次改这类判断的人会先看到。
  - **单一门禁** `test/zz_t66_convergent_tile_gate_test.dart` 能自动抓
    「child 依赖里含 tile 家族」：追三跳、追局部变量、形参则报未判定。
    它带**基线白名单**（9 处已知必须留，每条带理由）+ 腐化检测
    （白名单位置消失也红，避免豁免只增不减）。
    原先两道（v2/v3）已合并 —— v2 的 `ColoredBox` 与透明度判据移植进 v3 后删除，
    避免两套判据漂移。

- **代价与已知上限**：
  - ⑦ 与 ⑫⑬ 是**形参透传**，静态分析判不了 ⇒ 门禁只能报「未判定」，
    结论靠人工追调用点（6: 31 个调用点、7: 9 个调用点）。
  - 判定依赖「当前调用点」。若将来有人给 `SettingsBlock` 新增一个传 tile
    的调用方，⑥ 不会自动变红 —— 门禁的收敛追踪不跟调用方向。
  - ⑭ 的结论依赖「AppSurface 不提供 DefaultTextStyle」这一事实；
    若 AppSurface 将来加上该能力，这条判定要重做。

- **重访条件**：
  - `AppSurface` 增加 `DefaultTextStyle` 或形状/阴影能力 ⇒ 重看 ⑫⑬⑭。
  - 引入不依赖 Material 祖先的列表行控件 ⇒ ①~⑨ 可整体重估。
  - 门禁报「未判定」**涨到 5 处以上** ⇒ 说明形参透传变普遍，那时才值得扩展分析器。
    当前是 2 处（`app_dialog_shell:424`、`source_composer_dialog:437`，都是真形参，
    语义上就是「调用方决定」，静态分析判不了）⇒ **不扩**。
    ⚠️ 阈值原先记的是 3，Lead 2026-10-17 更新为 5；这里只保留最新口径，
       不并列两个数字 —— 两套阈值并存就是两套判据。
  - 白名单某条**消失**时门禁会红提示删除 —— 那时应顺带复核：那处是否真的
    不再需要 Material（换成自绘行是对的；如果只是平移了行号，要更新条目）。

## 教训：两个「看起来在工作」的 bug

这一轮修了两个门禁自身的缺陷。它们的共同特征是：**门禁在跑、有读数、
显示绿，但实际没起作用** —— 比「门禁不工作」危险得多，因为不工作的会被发现。

### ① 判据换载体必须重审每条前提

```text
v2 的 _hasOpaqueBackground 里有一句：
    final cm = RegExp(...).firstMatch(blk);
    if (cm == null) return false;   // ← 没给色 ⇒ 没底色 ⇒ 放过
```

对 `AppSurface` / `DecoratedBox` / `ColoredBox` 这是**正确**的：
它们只有靠 `color:` 才产生底色。

但把它当成通用件搬进 v3（v3 多扫一张 `Material`）就是**漏报**：
`Material(type: MaterialType.transparency, child: SwitchListTile(...))`
**没有 color**，可它仍然是一个 Material 面 —— ListTile 的水波就画在它身上。

实证：移植后 `lib/ui/settings/emby_page.dart:985` 从命中列表里**消失**了。
而该处代码注释自己就写着「必须自己包一层透明 Material，否则 flutter 断言」。

**通用形式**：一条判据往往绑定了「载体是什么」。换载体时前提可能不成立，
必须逐条重审，不能整段照搬。

修法：给 `Material` 单独一条 —— 只要存在就是绘制面，`color` 只决定
它是不透明还是透明，两种都能承接水波。

### ② 行号必须与原文一致

```text
v3 原来用**剥掉注释后**的文本算行号；
而 _strip() 是把注释整个删掉 ⇒ 后面所有行号往前漂。

实测：player_settings_sheet 的 Material 真实在 776 行，
      门禁报 680 / 697 —— 差 96 行。
```

后果：白名单按「文件:行号」记豁免，行号错了就**一条都匹配不上**，
但门禁依旧打印「已知必须留 9 处」并显示绿。

**这条 bug 的通用形态**：
```text
「看起来在工作」比「不工作」更危险 ——
  不工作的门禁会报错，你会去修；
  静默失效的门禁只会让你安心。
```

修法：`_strip()` 把注释替换成**等量换行**而不是删除，
使剥离后行号 == 原文行号。

发现方式：用 `grep -n` 独立核对真实行号，与门禁输出对不上。
⇒ 又一次「用第二个独立手段交叉验证」。

## 附：「假绿」的七种变体（本轮实战记录）

这一整轮遇到的七个「没有报告问题」的形态。它们的共同点：
**「没有报告问题」不等于「没有问题」**。列在这里供后来者对照。

| # | 形态 | 表现 | 为什么会骗人 | 怎么破 |
|---|------|------|------------|--------|
| 1 | **只扫直接子树** | v1 对 `child: 变量` 返回 NONE | 看起来「检查过了」 | 追依赖，不看清单一层 |
| 2 | **分析器自己写错** | 正则漏转义 ⇒ 6 处只报 1 处 | 门禁在跑、不是 0，像正常 | 阳性对照 + 用 grep 独立数一遍 |
| 3 | **追 1 层以为收敛** | danmaku 是三跳，只追 1 层漏掉 | 追到东西了就以为追完了 | 追到**解析不出新符号**为止 |
| 4 | **判据绑定了旧载体** | `color==null⇒false` 对 Material 是漏报 | 判据本身没变，看起来可信 | 换载体时逐条重审前提 |
| 5 | **行号与原文不一致** | 白名单 9 条一条没匹配上，却显示绿 | 门禁在跑、有读数、显示绿 | 用 `grep -n` 核对真实行号 |
| 6 | **白名单只增不减** | 旧的豁免永远留着 | 永远是绿的 | 腐化检测：条目消失也红 |
| 7 | **恒定红** | 11 处必须留永远报红 | 反正红，没人看了 | 基线白名单 + 只对新增报红 |

**1~5 是「假绿」（该红没红），6~7 是「假绿的孪生」（红失效）**。
两者结果一样：门禁失去作用。

### 一个跨所有变体的方法
```text
用**第二个独立手段**交叉验证读数：
  · 门禁报 1 处、grep 数出 6 处 ⇒ 门禁有漏（变体 2）
  · 门禁报 776、grep -n 说 776 ⇒ 行号对（变体 5 已修）
  · 门禁绿 + 故障注入必须红 ⇒ 证明它不是恒真
只信一个工具的读数，就会漏掉「工具自己坏了」这一类。
```
