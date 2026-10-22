# Agent Note: 语义色层 AppSemanticColors —— 玻璃化的地基，不是又一层主题

Status: implemented

> 同域：[2026-10-18-light-tokens-extract-from-theme-bridge.md](./2026-10-18-light-tokens-extract-from-theme-bridge.md)
> 那篇把**真色值**从胶水里搬出来；本篇在色值之上建立**语义角色**。
> 另一篇：[2026-10-18-glass-components-replace-material.md](./2026-10-18-glass-components-replace-material.md)
> 组件层取色一律走本篇的语义角色。

## Problem

玻璃化的本质是：**同一个控件在不同底色上要取不同的色**。
例如「强调文字」在纯黑背景上是亮青，在浅色玻璃上是深青。

改前这些值散在两处：

```text
lib/ui/theme/app_colors.dart   —— 按用途命名的常量（primaryText / muted…）
lib/design/theme/app_theme_data.dart —— Material 的 ColorScheme 角色
```

问题在于**两者语义重叠但取值不同**，于是同一个视觉意图在不同页面拿到不同色：

```text
· 详情页取 AppColors.primaryText
· 设置页取 Theme.of(context).colorScheme.onSurface
⇒ 两处都自称"正文色"，实测色值不同 ⇒ 用户在跨页时看到色差
```

而 Material 移除之后，`ColorScheme` 这条线会消失 —— 如果什么都不做，
所有取色会瞬间失去依据。

## Decision

建一层**语义色** `AppSemanticColors`（10 个角色），作为唯一取色入口：

```text
lib/design/theme/app_theme_data.dart（3a19ab3）
```

关键是这层的定义方式：

```text
① 角色是**语义**的，不是视觉的
   ✅ primaryText / mutedText / accent / danger / glassBorder …
   ❌ white70 / gray600 / blue300
② 每个角色**按底色给两组值**（深色底 / 浅色底），
   而不是"一个角色一个值 + 各处自己判断底色"
③ 由 ThemeData 的 extension 挂上去，取用一律走
   `AppSemanticColors.of(context)`
```

`da09b4f` 同期把 `LightTokens` 从 `theme_bridge` 搬出来，
理由：它本来就是设计 token，放胶水层里等于把「值」和「转换」混在一起。

## Alternatives considered

- **继续用 Material 的 `ColorScheme` 角色，只改取值** —— 它最强的论据是
  零新增抽象，所有既有 `Theme.of(context).colorScheme.xxx` 调用点都不用动。
  否决理由：本轮的目标就是**移除 Material**。继续依赖它的角色定义，
  等于把地基留在要拆的房子里。而且 `ColorScheme` 的角色集合是 Material 定的
  （`surfaceVariant` / `onSurfaceVariant` 这类），与玻璃化需要的角色对不上。

- **每个页面各自定义颜色常量** —— 它最强的论据是最直接，改哪个页面看哪个页面。
  否决理由：那正是改前的状态，实测已经出现「同一意图两处色值不同」。

- **只做一层 `static const` 常量表，不做 context 扩展** —— 它最强的论据是
  取用最简单（`AppColors.primaryText` 一行），没有 `of(context)` 的样板。
  否决理由：玻璃化必须**按底色给不同值**，而底色只在 `context` 里可知。
  纯常量表无法表达这一点，最终一定会出现「调用点自己 if 判断深浅色」，
  那就退回到改前的散乱状态。

- **保持 LightTokens 留在 theme_bridge** —— 它最强的论据是迁移面小，
  且 theme_bridge 迟早要删，一起删省事。
  否决理由：`LightTokens` 是**设计值**（每个值都标了对应的 CSS 变量名），
  混在「Material → 自建」的转换胶水里，会让"这些值从哪来"变得不可考。

## Consequences

- **收益**：取色从「两处来源、语义重叠」收敛到一处；玻璃化有了按底色取值的依据；
  `ColorScheme` 这条线可以在移除 Material 时整体拔掉而不影响视觉。
- **代价**：新增一层间接（`of(context)`），且 10 个角色的命名一旦定下就会扩散到
  全仓 —— 改名成本高。⇒ 已在代码里给每个角色写了「它到底代表什么」的注释。
- **未完成**：`LightTokens` 的 `divider` / `surface2` 两个成员在 `lib/` 内**零调用**，
  只被迁移比对测试引用。保留的理由是「迁移一致性样本」，已在该文件注释里写明。
- **重访条件**：当 Material 依赖被完全移除后，应回看这 10 个角色是否
  还与实际用点一一对应 —— 没有用点的角色应当删掉，而不是留着当"全集"。
