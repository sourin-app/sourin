# Agent Note: 直播态不画弹幕控件，守卫落到唯一的请求叶子

Status: implemented

## Problem

全屏播放页的直播态（`PlayerPage(liveChannelId:)`）底栏有一枚弹幕开关。点它的实际后果
（真树 + wire 级读数）：

```text
点前  [ … 弹幕 更多 ]
+1s   [ … 弹幕 !  … 弹幕失败：弹幕服务返回 HTTP 400 ]
+13s  [ … 弹幕 ! ]                       ← toast 没了，停在「开着、零弹幕、一枚看不懂的 !」
```

wire 上唯一一条请求是 `POST …/api/v2/match {"fileName":"<频道名>", "matchMode":"fileNameOnly"}`
—— 把**直播频道名**发去了**番剧按文件名匹配**的接口，服务端当然不认（400）。

两个不能想当然的地方：

1. **不是缺凭证**。`lib/core/danmaku.dart` 那段注释说的 403 是另一条分支；这里是 400，
   即"这个番剧名不存在"。归因写错就会去改凭证流程，改完照样 400。
2. **只拦开关拦不住**。真正发请求的是叶子 `_loadDanmakuNamed()`；它还有四条旁路：
   起播成功后的 `unawaited(_loadDanmaku())`、面板里的 `_setDanmakuEnabled(true)`、
   「重新拉取」、手动搜索。开关只是最显眼的那一条。

结论：入口从来不存在时，画一个点了没用的按钮，比没有更糟 —— 这正是 R6 裁决①
（「直播没有 channel 弹幕数据源 ⇒ 假入口比没有更糟 ⇒ 不渲染」）的同一形态，只是
R6 那次修的是嵌入播放器，这次是**全屏页**。

## 与既有笔记的关系

- [../feature/2026-10-17-player-danmaku-send-entry.md](../feature/2026-10-17-player-danmaku-send-entry.md)
  定的「不支持 ⇒ 整条不出现，不是置灰」是同一个口径，本篇把它从**发送栏**扩到**底栏那两枚**。
- [2026-10-20-danmaku-send-hint-at-discovery-point.md](2026-10-20-danmaku-send-hint-at-discovery-point.md)
  与本篇**改的是同一个 AND 谓词的两侧邻居**：那篇动「为什么不能发」的解释，本篇只动
  「直播这一维」的入口可见性；两篇都不改谓词本身（`_isLive` 那项一直都在）。
- [../feature/2026-10-18-live-availability-three-state-and-persistence.md](../feature/2026-10-18-live-availability-three-state-and-persistence.md)
  的「直播三态」讲的是**菜单可用性**；本篇讲的是**控件要不要存在**，别混用。

## Decision

直播态（`_isLive == true`）不画弹幕相关的两枚控件，并把守卫压到**请求叶子**：

1. `lib/ui/player/player_bottom_bar.dart`：开关（`danmakuToggleKey`）与齿轮
   （`danmakuSettingsKey`）由**同一个** `if (!isLive) ...[` 包住 —— 与「上一集/下一集」
   （`showEpisodeNav`）同一条口径：能力不存在就整块不出现。「更多」仍在 `]` 之外。
2. `lib/ui/player_page.dart` 更多菜单：`MoreMenuGroup('弹幕', …)` 外层 `if (!_isLive)`，
   **整组**不画。只藏里面那一行会留下一个光秃秃的组标题
   （`PlayerMoreMenu.build` 对空 `entries` 不做特判，组标题无条件画）。
3. `_toggleDanmaku()` 第一句 `if (_isLive) return;` —— 不翻 `_danmakuEnabled`、
   不写用户偏好、不 `_flash`。深链/探针/将来复用的入口会绕过控件层，这一层必须有。
4. `_loadDanmakuNamed()` 顶部 `if (_isLive) return;` —— 这是**唯一**发 `/api/v2/match`
   的地方（`_loadDanmaku()` 只是它的薄包装）⇒ 起播、面板开关、重试、手动搜索一并断掉。
5. 不加任何新文案：全屏直播页没有「直播不支持弹幕」的说明位，R6 那句
   `这个来源暂无弹幕` 只属于嵌入播放器（`LiveEmbeddedPlayer.showDanmakuNote`）。
   全屏直播页的观感是**少两枚控件**，不是多一句解释。

非直播（点播）路径**一行未变**：三处守卫的条件为假即落回原文，`if (!isLive) ...[`
对点播恒真。

## 为什么判据是「请求数 = 0」，不是「点了没崩」

`_toggleDanmaku()` 的失败形态本来就不是崩溃 —— 它会 `_flash` 一句然后停在错误态。
所以"点了没有崩"在改前也是绿的。判据只能是**外部可数的事实**：

- A 层（默认套件）：真 `PlayerBottomBar` 渲染树里两枚 key 命中 0、四句文案
  （`开启弹幕` / `关闭弹幕` / `弹幕设置` / `弹幕加载中`）命中 0，而「更多」还在 1 枚；
  再成对跑一次点播（key 命中 1、回调 +1）证明 finder 不是恒假。
- B 层（`--tags native-media`，真 `PlayerPage` + 计数 transport）：直播强推
  `debugPlayerToggleDanmakuForProbe()` 后 `/api/v2/match` 计数 **= 0**；同仪器点播 **≥ 1**。
- C 层（源码契约，明确只是补充）：两条守卫各在自己的第一句、底栏两枚被同一个
  `if (!isLive)` 包住、更多菜单组的字面还在。**C 层只防「被顺手删掉」，不替代行为判据。**

## 分工：C④ 与并行那篇的真值表

同一天另一处动了发送栏那个 AND 谓词
（`_danmakuEnabled && _danmakuCanSend && _danmakuSendProvider != null && !_isLive`）。
本篇的门禁里有一条 C④ 钉它的四项齐全，那条是**读源码字符串**（剥注释后压平再比），
不是真跑：它的职责是"别被顺手删掉一项"，行为正确性由真值表那篇负责。两者互补。

**不构成掩盖**：`_toggleDanmaku()` 与 `_loadDanmakuNamed()` 都不在发送路径上，
发送栏渲不渲染只由谓词本身决定 ⇒ 把 `!_isLive` 从谓词里删掉时，
谓词的真值表会红、本篇的 C④ 也会红（两边同时红，不是被守成绿）。

`_isLive` 目前是**双保险**（谓词里一项 + `_toggleDanmaku` 里 early return）。
重访时注意：任何"从谓词删一项做注入"的验证，都要确认红的是谓词那条断言，
而不是被另一层守卫提前挡掉。

## Alternatives considered

- **渲染但置灰（disabled + tooltip）** —— 论据是「至少让用户知道有这个功能」。
  否决：同仓 `PlayerBottomBar` 的既有口径是 `enabled` 只表示**能力存在、此刻不可用**
  （上一集/下一集在中间某集时都在，到第一集才变灰）；直播是**根本没有这条路**，
  同一文件里「上一集/下一集」对直播就是整块不渲染，原版注释写得很直白
  （「直播没有上一集/下一集概念…两个灰掉的死按钮…很怪」）。两枚都做会一半可见一半不可见。
- **只拦 `_toggleDanmaku()`，不动叶子** —— 论据是"用户点不到就发不出"。
  否决：起播与面板开关会绕过它，`_loadDanmakuNamed` 照样打 `/api/v2/match`，
  用户会看到"从没开过弹幕却在报错"。
- **在 7 个调用点逐处加守卫** —— 论据是"显式"。否决：调用点会继续增长
  （重试/搜索/以后的新面板），漏一个就复发；叶子断了谁调都安全。
- **给直播画一行「直播不支持弹幕」** —— 论据是 R6「不许静默」。否决：全屏页没有
  这个文案位，新造一句就是新文案（要走用户可见文案的规矩），而 R6 那句的精确定位在
  嵌入播放器；且直播页顶部已有「直播」胶囊，用户对"这是直播"没有歧义。

## Consequences

- **收益**：直播态不再出现"开着、零弹幕、一枚看不懂的 `!`"；也不再往番剧匹配接口
  送无用请求（每次点开关一条 400）。点播行为零变化。
- **代价**：直播态用户彻底看不到"弹幕"这件事 —— 这是刻意选择（产品上直播本就没有
  弹幕数据源），不是遗漏。若哪天接入直播弹幕，要删的是三处守卫 + 补链路，不是加回控件。
- **门禁读数**：
  `test/zz_t66_r6b_live_toggle_test.dart` 默认套件 `+6 ~2`（2 skip = B 层 native），
  `--run-skipped --tags native-media` 补跑 `+2`。
- **故障注入（证明有判别力）**：底栏门控改 `|| true` ⇒ `+3 ~2 -3`（A①/A②/C③ 红）；
  开关守卫改空块 ⇒ `+5 ~2 -1` + native `+1 -1`（C①/B① 红）；叶子守卫改空块 ⇒
  `+5 ~2 -1` + native `+1 -1`（C②/B① 红）；谓词删 `_danmakuCanSend` ⇒ `+5 ~2 -1`（C④ 红）。
  每次还原后 `sha256sum` 与基线一致、`dart analyze` 0 error。
- **未覆盖/重访条件**：
  · 真机像素验收尚未跑（探针 `lib/t106_r6b_live_probe.dart` 已就绪，等 build 窗口）；
    在那之前，「直播底栏少两枚图标」的像素级证据只有 `flutter test` 的渲染树读数。
  · 本改动只管「入口」，没做「直播弹幕」本身（没有直播弹幕接口，属产品边界）。
