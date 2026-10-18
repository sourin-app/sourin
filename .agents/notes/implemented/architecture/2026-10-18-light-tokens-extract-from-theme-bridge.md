# Agent Note: 把 LightTokens 从 theme_bridge 里搬出来 —— 真色值不能埋在胶水文件里

Status: implemented

## Problem

`lib/ui/theme_bridge.dart`（863 行）是「给 Material 组件喂色」的胶水层，
M2/M3 阶段要去 Material 时它整体要被删。但它里面**埋着真色值**：

```text
1-120   头部注释 + pageTransitionsTheme(5平台)   120  胶水
121-158 buildAppTheme                             38  胶水
160-566 _shared() —— 31 个 Material 子主题        407  胶水（主体）
567-622 _buildDark()                              56  胶水 + 4 处真色值
624-709 LightTokens                               86  ★真色值
711-863 _buildLight()                            153  胶水 + 5 处真色值
```

`LightTokens` 被 **12 个 lib 文件 + 7 个测试**真实消费
（`app_theme.dart` 9 处 / `shell.dart` 3 处 / `app_dialog_section.dart` 3 处…）。

于是有一个具体的危险：

```text
「删 theme_bridge」这个动作本身是对的（M2 的目标），
但它会连带删掉 LightTokens ⇒ 19 处消费点直接编译失败。
⇒ 到时候要么放弃删（M2 卡住），要么在删的同时仓促搬 19 处引用（极易出错）。
```

这不是「代码组织不好看」的问题，是**一个已知的未来阻塞**。

## Decision

把 `LightTokens` 整块搬到 `lib/ui/theme/light_tokens.dart`，`theme_bridge.dart`
用 `export` 转发，**零调用点改动**。

三条约束：

```text
① 纯搬迁 —— 不改任何色值、不改任何字段名、不改任何语义
② 保持 `LightTokens` 类名与全部字段名不变（12 个 lib 文件 + 7 个测试不用改）
③ 用 re-export（`export 'light_tokens.dart';`）而不是让调用方改 import
   ⇒ 现有 `import 'theme_bridge.dart'` 的地方全部继续有效
```

搬迁后 `theme_bridge.dart` 里只剩胶水，M2 删它时不会误伤真色值。

## Alternatives considered

### A. 不搬，等 M2 删 theme_bridge 时一起处理

**这是最省事的方案，也是我最初倾向的** —— 反正 M2 要重写整个主题层，
现在搬是「为一个还没到的重构提前做功课」。

放弃理由：**M2 时的时间压力比现在大得多**。删 theme_bridge 那一刻要同时处理
31 个 Material 子主题 + 9 处真色值 + 19 处引用，其中任何一处出错都会表现为
「某个页面颜色不对」这种**不报错的缺陷**（本仓已经踩过：两套 Theme 串台导致
深色背景上写深色字，编译过、跑得起来、analyze 0 error，只有看截图量像素才发现）。
现在搬是 141 行的机械动作；M2 时搬是 19 处引用 + 主题重写同时进行。

### B. 搬，但同时改名成 `AppLightTokens` 统一前缀

**这个方案更「整洁」** —— 新色层叫 `AppSemanticColors`，旧的真色值叫 `LightTokens`，
命名风格不统一。

放弃理由：改名会让 19 处消费点全部要改，**违反约束 ②**，把一个 141 行的机械
搬迁变成 19 个文件的改动。命名统一是好事，但不该在「降低 M2 风险」这件事里夹带做 ——
两件事混在一起，出问题时分不清是哪一步改坏的。

### C. 直接把 LightTokens 的色值合并进 AppSemanticColors

**这是最彻底的方案** —— 一套色层，没有「旧真色值」和「新语义色」两套。

放弃理由：`AppSemanticColors` 是按 Material 的 `ColorScheme` 角色对齐的
（primary / onSurface / surfaceContainer…），而 `LightTokens` 是**按项目自己的
页面语义命名的**（bgBase / card / borderSolid…）。两者**不是同一层抽象**。
硬合并会得到一个既不像 ColorScheme、又不像页面语义的混合体。
⇒ 正确顺序是「先让 Material 的角色有替代（M1，已完成）→ 再让 Material 的组件
有替代（M2/M3）→ 最后才谈两套色值的合并」。顺序反了会同时失去两边的可读性。

## Consequences

**收益**：
```text
· M2 删 theme_bridge 时不再有「连带删掉真色值」的风险
· 真色值（86 行）与胶水（596 行）物理分开，一眼能看出哪个能删
· 零调用点改动 ⇒ 本次搬迁的回归面 = 0（只需验证「没搬错」）
```

**代价**：
```text
· theme_bridge.dart 多了一行 re-export，多一层间接（读代码时要点一下才看到定义）
· 两套色层（LightTokens 与 AppSemanticColors）暂时并存，
  新人会问「我该用哪个」⇒ 已在清单文档里写明「M2 完成前：页面用 LightTokens，
  新代码优先 AppSemanticColors，M2 后统一」
```

**没有解决的**：
```text
· _buildDark() 里的 4 处、_buildLight() 里的 5 处真色值**仍在胶水函数体内**
  （#222222 / #171717 / #FFFFFF×4 等）。它们不是命名常量，是直接写在
  Material 子主题的字段里，搬出来需要先决定「它们属于哪个语义角色」——
  那是 M2 的活，不是本次搬迁能顺手做的。
⇒ 本次只搬了「已经是命名常量」的那部分。
```

## Verification

```text
dart analyze lib/                          ⇒ 0 error
flutter test theme_invariants_test \
             theme_pack_test --concurrency=1
                                           ⇒ 134 条全绿
+ 本轨道新门禁 zz_t66_app_colors           ⇒ 合计 149 条全绿
```

提交：`da09b4f`（3 个文件：`light_tokens.dart` 新增 141 行、
`theme_bridge.dart` 净 -85、清单文档 226 行）

## 附：这次搬迁暴露的流程问题

搬迁过程中，提交被并发夹带过两次（`7adb978` 带走 theme 的文件、
`61ba32f` 标题与内容不符）。根因是**共享工作树的 git 暂存区是共享的**：

```text
· `git add` 与 `git commit` 必须串起来，中间不 yield
· `git commit --allow-empty` **不保证提交是空的** —— 暂存区非空时它照样提交内容
  （61ba32f 就是被这个反直觉行为触发的）
· 路径限定 `git commit -- <路径>` 能挡住「暂存区里别人的文件」，
  但挡不住「别人抢先 commit 了同一批工作树改动」—— 后者无解，只能事后记录
```

详细记录见 `docs/notes/round-66-issues.md` 的 P0-10。
