# Agent Note: 修一类缺陷时只修了「我看到的那两处」—— 同类的另外八处在同一个文件里

Status: implemented

> 同域：[../testing/2026-10-19-literal-assertion-vs-intent.md](../testing/2026-10-19-literal-assertion-vs-intent.md)
> 那篇讲「断言绑死字面量」；本篇讲「**修复**只覆盖了样本」。
> 两者是同一个母题的两面：把「我观察到的一个实例」当成了「这一类」。
> 也接 [2026-10-18-three-broken-wirings-found-by-self-review.md](../bug-fix/2026-10-18-three-broken-wirings-found-by-self-review.md)
> 的「写了 ≠ 接线了」——本篇是它的镜像：**接线了 ≠ 全接上了**。

## Problem

R3-④ 的缺陷是「弹窗遮罩双击 ⇒ 第 2 击透传到播放区 ⇒ 视频被暂停」。

修法（在接受透传的前提下让落点无害）：

```dart
onTap: (_anySheetOpen || _sheetGuardHold) ? null : _togglePlay,
//       ↑ 面板开着            ↑ 面板刚关掉的 350ms 内
```

`_sheetGuardHold` 由 `_holdSheetGuard()` 维护：面板关闭时置 true，350ms 后自动置回。
⇒ **每一个会关闭全屏面板的地方都必须调它**，否则那条关闭路径上「第 2 击」照样能暂停视频。

第一版只在**两处**加了：

```text
player_page.dart:16172  _danmakuSheetOpen 关闭（OnClose 回调）
player_page.dart:16207  _biliSheetOpen     关闭（OnClose 回调）
```

**为什么只加这两处**：因为用户报的是「**在这个弹窗内**双击会透传」，我当时手上
只有那两个面板的复现路径 —— 我修的是**我观察到的那两个实例**。

### 实际有多少处

```text
$ grep -n "_restoreBarsAfterSheet();" lib/ui/player_page.dart | wc -l
17
```

其中属于「`Positioned.fill` 全屏 scrim 关闭」的：

```text
_danmakuSheetOpen    2 处（:7367 选中弹幕库即关 / :16167 面板 OnClose）
_biliSheetOpen       1 处
_streamSheetOpen     3 处（遮罩 onClose / onPick 选线路即关 / 面板内 close 按钮）
_liveChannelsOpen    3 处（遮罩 onClose / :11036 点选频道即关 / 面板内 close 按钮）
_subtitlePanelOpen   1 处
⇒ 合计 10 处，第一版覆盖 2 处（20%）
```

**漏掉的 8 处里，最要命的是 `_streamSheetOpen` 三处** —— 线路面板是操作最频繁的一个
（换线路、看清晰度，几乎每次都要点遮罩关窗）。也就是说：这个修复在**最常用的场景上
根本不起作用**，而在冷门场景上起作用。这比「完全没修」更难发现，因为：

```text
· 缺陷报告里说的那个场景（弹幕面板）确实修好了 ⇒ 验收会过
· 用户下次撞到的是线路面板 ⇒ 他会以为"上次那个又复发了"
  ⇒ 我们会去查已经修好的那段代码 ⇒ 查不出来
```

### 我自己又是怎么发现的

不是靠用户再报一次。是**换一个判据去数**：

```text
不要问「我修的那两处对不对」，要问「这个修复的**前置条件**在全仓有多少个满足点」。
  前置条件 = "关闭全屏 scrim"
  满足点   = 10 处
  已覆盖   = 2 处
```

## Decision

### ① 补齐全部 10 处

逐处按语义加注释（不是机械粘贴）：遮罩 onClose / 「选中即关」/ 「面板内关闭按钮」
三条路径**都要**，因为三条都能关窗，也就都可能有第 2 击。

其中三条是原来完全没有的路径类型：

```text
· "_pickLiveChannel 里点选频道即关" —— 这条根本不是 onClose 回调
· "_loadDanmakuNamed 里选中弹幕库即关" —— 同上
· "_StreamSheet.onPick 选完线路即关" —— 与遮罩 onClose 是**两个相邻回调**
```

★ 第三条是关键：它与遮罩 onClose 相邻，这个相邻性是下面 ② 的起点。

### ② 门禁用「逐处遍历 + 总数交叉校验」，不用「抽一处」

新建 `test/zz_t66_r3_sheet_guard_coverage_test.dart`：

```text
S1  scrim 清单必须与 _anySheetOpen 的定义一致（防清单漂移）
S2  每个 flag 的**每一处** `setState(() => flag = false);` 之后必须有守卫
S3  守卫调用总数 >= 各 scrim 关闭点数之和（防"漏扫一个 flag"）
S4  自检：剥注释后不许还看得到注释里的示例
```

### ③ 门禁自己先踩了两个坑（都是当场抓到的）

**坑 A：只查第一处。**

```dart
final idx = src.indexOf(marker);   // ← 第一版
```

`_streamSheetOpen = false` 在文件里有 **3 处**，`indexOf` 只命中第一处
⇒ 后面两处永远不被检查 ⇒ 假绿。改成 `while` 遍历全部。

**坑 B：固定 600 字符窗口会被邻居的守卫冒充。**

```dart
final window = src.substring(idx, idx + 600);   // ← 第二版
```

`_StreamSheet` 的 `onPick` 与 `onClose` 是相邻两个回调。删掉 `onPick` 的守卫后，
600 字符窗口**已经包含 `onClose` 的守卫** ⇒ S2 仍然绿。

★ 这次是 **S3 的总数交叉校验抓到的**（少了 1 次调用）。如果没有 S3，
这个假绿会一直躺着 —— 而这正是「两条独立判据」的价值。

改法：窗口上界 = **下一个关闭点之前**。

```dart
final end = nextSite.clamp(idx, src.length);   // nextSite = 下一个 setState(... = false)
```

### ④ 注入验证（这才是判据合法性来源）

```text
注入：删掉 `_StreamSheet.onPick` 里的 `_holdSheetGuard();`
  → dart analyze lib/ui/player_page.dart ⇒ 0 error（注入有效，不是编译失败）
  → 门禁：**+6 -2** —— S2（_streamSheetOpen）与 S3（总数）**都红**
还原 → git status 干净 / analyze 0 error / **+8 All tests passed**
```

★ 关键：注入后是**两条**红，不是一条。这证明「固定窗口」那个假绿确实被 S3 兜住了。

### ⑤ 回归

```text
flutter test test/zz_t66_dialog_no_passthrough_test.dart \
             test/player_click_seek_removed_test.dart \
             test/player_gestures_test.dart --concurrency=1
⇒ +35 All tests passed
```

## Alternatives considered

### ① 「只在弹幕面板修，别的不动」 —— 即第一版

**最强论据**：用户报的就是那个面板；改动面最小；而且另外几个面板是**抽屉/侧栏**，
不是居中的对话框，用户的双击习惯可能不同，未必会真的撞上。

**为什么否决**：**「未必撞上」是猜测，而代码结构是事实。**

```text
`_SheetScrim` 是同一个组件，`onClose` 是同一种回调，遮罩是同样铺满全屏的
`Positioned.fill` ⇒ 双击透传的机理**完全相同**，没有任何一处不同。
★ 判据：若 A 处成立，且 B 处的机制与 A 处**逐项相同**，则 B 处同样成立。
  这里"逐项相同"是可核对的：同一组件、同一回调签名、同一布局方式。
```

★ 而且**线路面板的点击频率高于弹幕面板** —— 漏掉它，等于在高频路径上不生效。

### ② 「在 `_SheetScrim` 组件内部统一调用」—— 一次修好全部

**最强论据**：这是最优雅的做法，一处改动覆盖所有使用者，
甚至不需要知道有几个使用者。也符合 DRY。

**为什么否决**：**`_holdSheetGuard()` 是 `_PlayerPageState` 的方法，
而 `_SheetScrim` 是子组件。** 要做就得往下传一个回调：

```dart
_SheetScrim(onClose: ..., onClosed: _holdSheetGuard)   // 需要新增参数
```

```text
· 那就要改 `_SheetScrim` 的签名 ⇒ 它的**其他使用者**（不在播放页里的）也要跟着改
· 而且"关闭后要做什么"是**调用方的语义**，不是 scrim 的职责 ——
  把一个页面级状态机的钩子塞进通用组件，会让这个组件越来越难复用
· 更实际的一条：10 处里只有 **5 处**是 `_SheetScrim.onClose`；
  另外 5 处是「选中即关」「点选频道即关」**根本不过 scrim**
  ⇒ 即便改组件也只能覆盖一半
```

★ 所以"优雅的抽象"在这里只覆盖 50%，而剩下的 50% 仍然需要逐处处理 ——
**那就不如不要这个半吊子抽象，直接 10 处都写明**。

### ③ 「把守卫做成全局的，不绑定到具体面板」

**最强论据**：彻底消灭"漏一个面板"这类问题 —— 任何面板关闭都自动装守卫，
不需要在 10 个地方记得写。

**为什么否决**：**「任何面板关闭」这个前提本身不成立。**

```text
· 只有**全屏 scrim** 关闭时才需要（第 2 击可能落到播放区）
· 小浮层（_zoomOpen / _hintsOpen）关闭时，第 2 击落到的是别处，
  不需要这个守卫 ⇒ 全局装上就是**给不需要的地方加副作用**
· 更难查的一条：全局钩子会让"这一处到底该不该有守卫"
  从**代码可读的事实**退化成**运行时才知道的行为**
  ⇒ 正是本仓反复吃亏的"看了要 infer"的形态
```

★ 折中：**保留逐处显式调用**，但用 ② 的门禁把「十处必须都有」机械化。

## Consequences

### 最终形态

| 面板 | 关闭点 | 路径类型 |
|---|---|---|
| `_danmakuSheetOpen` | 2 | 选中弹幕库即关 / 面板 OnClose |
| `_biliSheetOpen` | 1 | 面板 OnClose |
| `_streamSheetOpen` | 3 | 遮罩 onClose / 选线路即关 / 面板内按钮 |
| `_liveChannelsOpen` | 3 | 遮罩 onClose / 点选频道即关 / 面板内按钮 |
| `_subtitlePanelOpen` | 1 | 面板 OnClose |
| **合计** | **10** | 守卫调用 11 次（含 1 处 `_holdSheetGuard` 定义外的额外调用） |

### 读数

```text
门禁（正常）：+8 All tests passed
门禁（注入删 onPick 守卫）：+6 -2，S2 + S3 双红
还原：analyze 0 error / git status 空 / +8 绿
回归：+35 绿
```

### 一条可迁移的判据

```text
修一类缺陷之前，先问：**这个修复的前置条件，全仓有多少个满足点？**

做法（成本 10 秒）：
  ① 把前置条件翻译成一个可 grep 的**代码形态**
     （这里是 `Positioned.fill` 的全屏 scrim 关闭 ⇒ `setState(() => _xxxOpen = false)`）
  ② 数它有多少个
  ③ 和我改了几处对比

★ 数字不等 ⇒ 还没修完，别急着说"修好了"。
★ 而且这比"再读一遍我的 diff"有效得多 —— 读 diff 只能确认"我改的对不对"，
  数满足点才能发现"我漏了没有"。
```

### 代价

```text
· 11 处显式调用 + 一份 scrim 清单，是重复
  ⇒ 将来新增全屏面板时，必须同时改 `_scrimFlags` 清单
  ⇒ S1 会抓（清单与 `_anySheetOpen` 不一致就红），但那是**提醒**不是**自动修复**
· 门禁是源码级（读文本），对格式化/重命名敏感
  ⇒ 已在 ② 里用"剥注释 + 遍历 + 总数"三重降低误判，但仍不是语义级
```

### 还没覆盖的

```text
· 只在**播放页**做了这个统计。别的页面（直播页 / 详情页）如果有
  全屏遮罩 + 下层可点击控件，可能有**同类**缺陷 —— 本轮没查
· 没有真机验证「连点两下遮罩关掉线路面板后视频不暂停」这个最终行为
  （只有源码级门禁 + 35 条相关测试）
  ⇒ 这是本轮的已知缺口，批末统一实测时必须补
· `_episodeSheetOpen` / `_settingsOpen` / `_zoomOpen` / `_hintsOpen`
  没有加守卫 —— 判断依据是它们不是"铺满播放区的 scrim"，
  但这个判断**没有逐处核实过**（只核了 `_anySheetOpen` 里有它们）
```

### 何时该翻案

```text
① 若真机验证证明「选中即关」那三条路径根本不会有第 2 击
   （比如选中动作会消耗焦点）⇒ 那三处可以去掉，注释里写明理由
② 若 `_SheetScrim` 将来统一接管"关闭后回调"
   ⇒ 5 处可收敛到组件内，但另外 5 处仍需逐处
③ 若新增第 6 个全屏面板 ⇒ `_scrimFlags` 必须同步；S1 会提醒
④ 若这类"只修样本"的事再发生一次
   ⇒ 应当把「数满足点」写进提交前的自检清单，而不是靠记性
```
