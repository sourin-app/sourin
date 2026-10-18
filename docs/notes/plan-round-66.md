# 第 66 轮：移除 material_ui + 布局优化 + 完整实测

**日期**：2026-10-18
**状态**：**执行中**（本文档实时更新，见下方进度总览）
**来源**：Owner 本轮 7 条指示 + 后续 5 次追加（逐字见 §1 / §4.6 / §4.7）
**前置**：第 65 轮已合并（PR #31 → main `bdf6435`）

---

## 0. 实时进度总览（每次状态变化都更新这里）

**最后更新**：2026-10-18 13:00

### 已完成 ✅

| 编号 | 内容 | 提交 | 验证 |
|---|---|---|---|
| N1 | 弹幕发送框嵌进操作栏，不支持则不显示 | `aedc29c` | task41 13/13 |
| N3 | 取消起播自动绑定，弹幕只能手动绑 | `25cd277` | 3/3 + 故障注入 |
| N11 | 播放页鼠标卡顿（setState 收敛） | `e6458e5` | T1 9800→565µs |
| N2 | 直播分组空组不再兜底成全部 | `68617bc` | 66/66 + 我做的故障注入 |
| N2b | 直播分组全链路门禁（勾选⇒落盘⇒重启） | `6046f62` | 39/39 + 故障注入 |
| M1 | 语义色层 AppSemanticColors（10 角色） | `3a19ab3` | 15 门禁 + 9/9 注入 |
| M1b | LightTokens 搬出 theme_bridge | `da09b4f` | 149 条全绿 |
| M1c | LightTokens 决策笔记 | `bc3316b` | 笔记门禁 tree/format/archived |
| M-guard | arm64「内容区全空白」修复补门禁 | `191cabb` | 4/4 + 故障注入 |
| N10-tool | 暴露 set_prefetch_disabled FFI 命令 | `f154a52` | 真 DLL 实测来回切 |
| I1 | 手动绑定外部源后也聚合插件弹幕 | `4aeb79a` | 7/7 + 2 次注入 |
| F1 | 搜索页内容区居中（2380→1260） | `358da42` | 76/76 连跑两轮 |
| H1 | 播放失败先认 HTTP 状态码 | `1f8674e` | 已提交 |
| M2-1 | 追更页玻璃化（InkWell/进度条→玻璃） | `b0f45d1` | 95 条全绿 + 6/6 注入 |
| M2-2 | 海报卡片角标玻璃化（本体不做，实色图无效） | `722dae9` | 58 条 + 3/3 注入 |
| M-note1 | 玻璃化判据决策笔记（拦下 3 个无效改动） | `7a04992` | 笔记门禁 3/3 |
| N12 | 登录轮询文案按真因分类 | `312bb04` | 13 条 + 6 红注入 |
| N13 | 单例（真机六条判据全过） | `312bb04` | failures=0 |
| N12-b | 续期不变量门禁（抓到自己的假绿） | `da34f1c` | 19 条全绿 |

### 进行中 🔄

| 编号 | 内容 | 谁 | 当前状态 |
|---|---|---|---|
| **D1** | 弹幕面板 4 tab → 3 tab 语义重构 | danmaku | 三页签已改完，正在修受影响的既有测试 |
| **N15** | 插件弹幕发送能力（Owner：插件也归你） | dan-api | 取证中（私库 `sourin-plugins`） |
| N14 | 缓存不要一次性拉完 | live-groups | **取证完成，方案待批** |
| N10 | 拖动转圈（自造场景） | perf-player | 取证中（找走代理的源） |
| M2-3 | 直播页筛选条玻璃化（C 方案） | live-ux | 已定方案，实施中 |
| M2-4 | 详情页玻璃化（第 3 步 OutlinedButton） | settings-ux | 进行中 |
| **P1-L3** | 直播暂停状态不统一（Owner 12:55 截图） | 待派 | 取证中 |
| **P1-L2** | 播放控件一半在视窗外（Owner 12:55 截图） | 待派 | 取证中 |
| **P1-L1** | 筛选条三下拉显示异常（Owner 12:55 截图） | 待派 | 取证中 |
| N14 | 缓存窗口 cache-secs=600（字节上限未动） | live-groups | **已完成 07db0c3** |
| M4 | MaterialApp → WidgetsApp | lead | **已完成 8157a03** |
| N5 | dan-api 异步（盘点结论：已满足） | danmaku | 等 D1 完成后出报告 |

### 待办 ⏳

| 编号 | 内容 | 阻塞原因 |
|---|---|---|
| M2-5 | 首页 3 个 Material 控件 | 挪到最后（视觉收益小） |
| M3 | 删 theme_bridge 胶水 | 等玻璃组件全面替换 |
| M4 | 彻底移除 MaterialApp | 等 ScrollBehavior 替代品 + Navigator 重建 |
| M4-b | 接上 AppThemeScope（现在零实例化） | 归 Lead，M4 阶段做 |
| N10 | 转圈 A/B 对照 | 等找到走 streamproxy 的源 |
| 逐页排查 | 每页查三次自我纠错 | 等 M 批次完成 |

### 关键决策记录（Owner 已拍板）

| 决策 | Owner 原话 | 影响 |
|---|---|---|
| 彻底不用 Material | 「彻底不用 Material 组件，全部自建/玻璃」 | M 批次范围 |
| 弹幕面板语义 | 「插件提供 = 视频源随片自带，默认导入」 | D1 重构 |
| 布局两侧占满 | 「放大之后两侧留白过多，改为两侧占满吧」(2026-10-04) | 不改 tokens |
| 缓存窗口 | 「不要一次性拉完，只缓存播放+5~10分钟」 | N14 |
| N10 自己找 | 「你自己找吧,随机找一个电影试一下」 | 不问 Owner 要片源 |

---

## 1. Owner 逐字指示与本计划对应

| # | Owner 原话 | 本计划怎么落 |
|---|---|---|
| 1 | 「我没给你限制时间,这次必须实现」 | 不设轮次上限；第 65 轮遗留功能项全部纳入，做到真实落地为止 |
| 2 | 「你先启动客户端,我看看」 | ✅ 已启动（PID 34880，08:50:29，窗口「源影」，`app.so` 11.09 MB = 产品不是 spike） |
| 3 | 「打开客户端我看看」 | ✅ 同上，仍在运行 |
| 4 | 「我其实就是把那个 移除 material_ui组件是一件事,因为那个太丑了,所以替换掉应该就能好很多,布局也得优化一下」 | 移除 material_ui **就是**治「丑」的主路径；**并**做布局优化（§6） |
| 5 | 「那就这轮实现吧」（指移除 material_ui） | 本轮**必做**，不再是「前提不成立」 |
| 6 | 「主题设计就放在整体移除 material_ui组件 之后吧」 | 主题重设计**排在本轮之后**；本轮只保证主题体系能承载现有数据 |
| 7 | 「实测是必做的,你在这轮计划中加入吧」 | 新增独立批次 **H：实测**（§7），贯穿全程 |

---

## 2. 我上一轮判断错在哪（必须先认）

第 65 轮我写「移除 material_ui 前提不成立，本轮不做」。**事实部分对，结论错** ——
我把「工作量大」说成了「做不了」。Owner 已明确不限制时间，正确做法是排期做完。

**事实复盘**（实测计数，不是估的）：

```text
material_ui 依赖面      128 / 195 个 lib 文件
Material（widget）      318 处
MaterialApp             180 处
TextButton              154 处
InkWell                 151 处
ColorScheme             107 处
IconButton               91 处
TextField                88 处
Scaffold                 78 处
FilledButton             70 处
OutlinedButton           62 处
Tooltip                  59 处
ThemeData                55 处
ListTile                 41 处
Slider                   34 处
CircularProgressIndicator 30 处
SnackBar                 25 处
Dialog                   15 处
Switch                   13 处
```

---

## 3. ⚠️ 我必须先纠正自己两个错误（都已核实）

### 错误一：我原本打算推荐引入 `forui` —— **这违反仓库既有硬规矩**

`docs/AGENTS.md` §4 明确写着：

> **不再新增 forui 用法（FTheme / FScaffold / FButton…）**
> 取色走 `Theme.of(context).colorScheme` 或 `lib/ui/tokens.dart`

而 `test/provider_layout_test.dart` 有一条门禁专门守着这件事：
「forui 与 Material 的角色名不能混用」（`foreground` 在 `ColorScheme` 上不存在，混用直接编译失败）。

**所以本轮不能引 forui。** 正确路径是：**用已有的 `liquid_glass_widgets` + 自建 token 体系**。
本轮开工前我会把 AGENTS.md 这一条一并更新（因为移除 material_ui 后「取色走 colorScheme」这句本身就失效了），
但那属于**收尾时同步文档**，不是先斩后奏。

### 错误二：我启动客户端时用的是 `flutter build`，没走仓库规定的入口脚本

`docs/AGENTS.md` §2 规定：跑客户端走 `tools/run_client.ps1`，因为该脚本把
**「`app.so` 大小」变成硬闸**（产品 ~11MB / 误编 spike ~4MB）。

我实测了：当前 `app.so` = **11.09 MB**，落在产品区间 ⇒ 这次没编错。
但**流程是错的**，后续所有启动都改用 `tools/run_client.ps1`。

---

## 4. 已核实的技术前提

```text
liquid_glass_widgets 1.7.2   已装且在 pubspec，Material-free
  · GlassScaffold / GlassDialog / GlassTextField / GlassSwitch / GlassSlider /
    GlassListTile / GlassNavigationShell / GlassSearchBar / GlassToast /
    GlassSegmentedControl / GlassPressable

forui 0.27.4                 在 pub 缓存，但**禁用**（§3 错误一）

现有主题资产（1350 + 311 行，**不废弃**）
  · lib/ui/theme/theme_pack.dart      主题包模型 + 序列化
  · lib/ui/theme/theme_language.dart
  · lib/ui/app_theme.dart:226  themeFor(Brightness) → ThemeData   ← 要替换的出口
  · lib/ui/app_theme.dart:245  themeForPack(Brightness, ThemePack)
  · lib/ui/tokens.dart        Sp / Radii / FontSizes（已有，继续用）

AppIcons 161 个常量           第 65 轮已建好并全量接线，**保留**
```

**关键估计依据**：`theme_pack` 那 1661 行**不用废弃**，只需改「出口」——
原来吐出 `ThemeData`，改成吐出自家 `AppColors` + `GlassTheme`。
这比「重写主题系统」省一个数量级。

---

## 4.6 Owner 2026-10-18 11:53 追加的 5 件事（本轮必做）

### N12 · 插件登录报「网络异常」（Owner：这也是 bug）

**Owner 原话**：「我刚刚测试某个视频站的插件无法登陆,提示网络异常 这也是bug」

**已核实的现状**：
```text
lib/core/bili/ 只有 3 个文件：bili_api.dart / bili_bind.dart / bili_auto_update.dart
⇒ 全是「弹幕绑定」相关，**没有登录实现**
⇒ 登录走的是插件侧（D:\WishProject\sourin-plugins-user\*.js 里含 login 的有多个）
```

**要先查清的三层**（不许猜着改）：
```text
① 「网络异常」这句文案是**谁**产生的 —— 宿主 FFI 层？插件返回？还是 HTTP 客户端兜底？
② 真请求打到哪个域名、返回什么状态码/响应体
③ 是「本机网络到不了」还是「请求构造错了」（cookie/referer/UA/签名）
```
★ 注意本机已有一个已知现象：`vercel.app` TCP 443 从本机不可达
（同机 github/baidu 正常）⇒ 如果是同类封锁，要如实报「不是代码问题」。

---

### N13 · 只允许单例（再点图标必须激活已有窗口）

**Owner 原话**：「只允许单例存在,当已启动的时候,再通过图标打开,依旧还是打开已有的,而不是再打开一个新的」

**已核实的现状**：
```text
grep "singleInstance|单例|already running|已有实例" lib/ rust/
⇒ 只命中两处**无关**的注释（shell.dart:2444 说的是"单例桥"、:2881 说"不是全局单例"）
⇒ **单例机制完全不存在**，现在每点一次图标就是一个新进程
```

**实现要点**：
```text
Windows：命名 Mutex（CreateMutexW）+ 找已有窗口（FindWindowW / 自定义窗口类名）
         ⇒ 找到就 ShowWindow(SW_RESTORE) + SetForegroundWindow，然后本进程退出
         ⇒ 这是 Win32 标准做法，不引第三方包
其他平台：本轮只做 Windows（Owner 用的是 Windows）
```
★ 必须先确认「已有实例」的判定方式不会误伤：
```text
· 探针进程 / 交付自检进程（SOURIN_DRAG_SELFTEST 等）**不能**被单例挡住
  ⇒ 那些进程要么带环境变量豁免，要么用不同的 mutex 名
· 崩溃残留：Mutex 随进程退出自动释放，不会留下僵尸锁（这点比锁文件好）
```

---

### N14 · 缓存不要一次性拉完，只留「播放点 + 5~10 分钟」

**Owner 原话**：「缓存提前拉取播放那个缓存,不要一直把所有的都缓存完,
只缓存播放+一个时间段,五分钟或者十分钟,你自己取舍一下看怎么最合理
(不要提前一次性把所有的都拉取完 这是错误的)」

**已核实的现状（这就是根因）**：
```text
lib/core/clip_download.dart:460  mpvCacheProperties() 只下发三个属性：
  demuxer-max-bytes        = cacheLimitBytes（默认 256MB，可配 64~512MB）
  demuxer-max-back-bytes   = 同上
  cache-dir                = <dataDir>/mpv-cache
⇒ **没有 cache-secs** ⇒ mpv 用默认值（约 10 秒**前向**缓存）
⇒ 但 demuxer-max-bytes = 256MB 意味着「只要没超 256MB 就一直往后读」
⇒ 一个 2GB 的片子会被连续读 256MB 才停 —— 正是 Owner 说的「一次性把所有的都拉取完」
```

**取舍（我的决定，需在实现时验证）**：
```text
用 **demuxer-max-bytes 按码率折算**，而不是加 cache-secs：
  理由：cache-secs 控制的是「前向缓存多少秒」，但它**不封顶字节数**；
        高码率（4K 20Mbps）下 10 分钟 = 1.5GB，低码率下 10 分钟 = 75MB
        ⇒ 只按秒数限制，会在高码率上失控、低码率上不够。
  ⇒ 更稳的做法是「两者都要」：
      cache-secs = 600（10 分钟，作为时间语义的上界）
      demuxer-max-bytes = min(用户配置, 码率 × 10min)（作为字节上界）
```

**★ 但这里有一个必须先验证的前提**：
```text
`demuxer-max-back-bytes` 是**回看**缓存（seek 回去时能用）。
Owner 说的「拖动要转圈很久」很可能与它有关：
  回看缓存越大 ⇒ seek 回已看过的地方越快
  但 Owner 又说「不要一次性拉完」⇒ 两者有张力
⇒ 必须实测：把 back-bytes 从 256MB 降到「10 分钟」后，
  seek 回已看过位置的转圈时间会不会变长。
  如果变长，说明 N10 和 N14 是同一个问题的两面。
```
★ **这与 N10 的 A/B 对照可以合并做**（都用 `set_prefetch_disabled` + 改缓存参数）。

---

### N10 · 转圈很久（Owner：你自己找，随机找一个电影试）

**Owner 原话**：「转圈很久的你自己找吧,随机找一个电影试一下」
⇒ **不再问 Owner 要片源，我自己造场景**。

**已备好的工具**（本轮已提交）：
```text
f154a52  暴露 set_prefetch_disabled / prefetch_disabled 两条 FFI 命令
         ⇒ 可在同一进程内交替 ON/OFF，单变量 A/B
         ⇒ 实测通过：false → true → false → false
```
**执行方案**：
```text
① 用本机已装的 32 个插件里任意一个能出片的源，随机取一个电影
② 走完整链路（mpv → 本项目 streamproxy → 上游）
③ 观测：seek 到未缓存位置的 buffering 持续时长、demuxer-cache-time 轨迹
④ A/B：SOURIN_PREFETCH_DISABLE 开/关 两组对照
⑤ 与 N14 联合验证：改 cache 参数前后的转圈时长对比
```

---

### 优先级与并行分配

| 编号 | 内容 | 谁做 | 依赖 |
|---|---|---|---|
| N13 | 单例 | 轨道 J（新） | 无 |
| N12 | 插件登录网络异常 | 轨道 H（现有） | 无 |
| N14 | 缓存窗口 | 轨道 K（新） | 需先实测 back-bytes 影响 |
| N10 | 转圈（自造场景） | Lead 自己 | 与 N14 合并做 |

★ N14 与 N10 **合并由一个人做**，因为它们是同一个缓存机制的两面。

---

## 4.7 弹幕面板重构（Owner 2026-10-18 截图指出 4 条）

### 现状盘点（轨道 D 逐条查证，证据到行号）

| Owner 说 | 真相 | 代码位置 |
|---|---|---|
| ① 某个视频站的弹幕设置怎么没了 | **没删，被降级藏起来了**。第 65 轮从独立 tab 改成「插件提供」tab 里一枚 `TextButton.icon`，文字叫「外部弹幕…」 | `danmaku_settings_dialog.dart:2299-2311` |
| ② 插件提供是什么 | **语义实现错了**。Owner 要的是「视频源插件随片自带每集弹幕 ⇒ 默认直接导入」，实现成了「插件声明 danmaku 能力 ⇒ 用户去搜索/绑定」 | `:752-755` |
| ③ dan-api 只有测试 | **Owner 说得对，是真的**。tab 里只有两个地址框 + 「测试连接」+「清除」，**没有搜索/选中/绑定** | `_selfHostedSection()` `:756-765` |
| ④ 官方兜底不知道是啥 | **内部概念泄漏到 UI**。要 AppId/AppSecret，本构建无内置凭证，用户打开只看到"会失败" | `:771-775` |

### Owner 对第 ② 条的原话（这是语义定义，必须逐字遵守）
> 我说的插件提供意思是,比如某个视频源 它本身视频源每一集都有对应的弹幕数据,
> 那么就默认导入他自身的就行了 懂了吗?

**⇒ 正确的语义分工**：
```text
插件随片自带   = 自动（因为它是视频的一部分，不需要用户操作）
其他所有来源   = 手动（dan-api / 某个视频站弹幕 / 手动搜索）
```
★ 这与 Owner 第 6 条**完全自洽**：「除了插件自身提供弹幕，其它都必须手动绑定」。

### 重构方案（待批）

**4 tab → 3 tab**：

```text
┌──────────┬────────────────────────────────────────────────┐
│ 显示      │ 开关/字号/透明度/速度/显示区域/屏蔽词            │
│          │ （= 现在的「配置」，纯视觉设置，一字不改）        │
├──────────┼────────────────────────────────────────────────┤
│ 弹幕来源  │ ① 本片源自带  —— 默认，自动，插件随片提供        │
│          │ ② 某个视频站  —— 独立可见的一行 + 打开按钮     │
│          │ ③ dan-api    —— 搜索 + 选中 + 绑定（补上缺的）  │
│          │ ④ 本机服务    —— 探测 + 使用                    │
├──────────┼────────────────────────────────────────────────┤
│ 高级      │ 自建 dan-api 地址/Token/测试连接（收起）        │
│          │ 官方开放平台凭证（默认折叠，标题写"通常不需要"） │
└──────────┴────────────────────────────────────────────────┘
```

**每条来源的可见形态**（这是第 ① 条的核心）：
```text
弹幕来源
─────────────────────────────
● 本片源自带    1200 条  [自动]
○ 某个视频站    未绑定  [打开…]    ← 回来了，与 dan-api 平级
○ dan-api        未选择  [搜索…]
○ 本机服务       未运行  [检测]
─────────────────────────────
当前生效：本片源自带（1200 条）
```

### 需要跨轨道协调的一点
```text
「本片源自带 = 自动导入」的**接线**在 player_page.dart（归轨道 A）
面板侧只负责**展示**（来源行、状态、按钮）
⇒ 轨道 D 提供 3 行精确 diff，由 Lead 转交轨道 A 在 N10 收尾时接上
```

---

## 5. 批次 M：移除 material_ui（主体）

### ⚠️ M0：先把「移除 material_ui」这句话的定义钉死（2026-10-18 实测补充）

**这一步不做，M 批次会在错误的目标上空转。** 实测事实：

```text
$ ls ~/AppData/Local/Pub/Cache/hosted/pub.dev/material_ui-1.4.0/lib/
material_ui.dart  src/  shaders/  fix_data/

$ head -20 .../material_ui.dart
library material_ui;
export 'package:flutter/widgets.dart';
export 'src/material.dart'
export 'src/material_button.dart'
...

$ grep -c "^export" .../material_ui.dart
185
```

**⇒ `material_ui` 就是 Flutter 官方 Material 库本身**（Flutter 3.47 把它从 SDK
拆成独立包），它导出 185 个库：`Scaffold` / `AppBar` / `TextField` / `Card` /
`InkWell` / `Theme` / `ColorScheme` / `MaterialApp` …**全部**。

#### 所以「移除 material_ui」有三种完全不同的含义，代价差一个数量级

| 解读 | 内容 | 规模 | 是否可行 |
|---|---|---|---|
| **A. 删掉 pubspec 那一行，改用 `package:flutter/material.dart`** | 只换 import 路径 | 126 个 import 行 | ✅ 机械可行，但**不解决"丑"** |
| **B. 不再用 Material 组件，换成自建/玻璃控件** | `Scaffold`/`AppBar`/`TextField`/`Card`/`InkWell`/`SnackBar`… 全换 | 128/195 个 lib 文件 | ⚠️ 本轮只能做一部分 |
| **C. 不用 Material 的**视觉**（主题体系），但组件仍用** | 换 `ThemeData`/`ColorScheme` → 自建语义色 + 玻璃装饰 | 主题层 + 控件皮肤 | ✅ 这是治"丑"的真实路径 |

#### Owner 的实际诉求是哪种

Owner 原话：
> 我其实就是把那个 移除 material_ui组件是一件事,因为那个太丑了,所以替换掉应该就能好很多

「因为那个太丑了」是**理由**，不是「import 路径难看」。
⇒ **Owner 要的是 C（视觉不再像 Material 默认皮肤），A 是实现手段之一，B 是过度。**

#### 本轮的执行定义（可验证）

```text
✔ 必做（C 为主）：
  · 主题出口 AppColors + AppThemeScope（M1）
  · MaterialApp / Scaffold / AppBar 的外壳替换，让"Material 默认皮肤"消失（M2）
  · 高频可见控件换玻璃/自建皮肤：卡片、按钮、输入框、对话框、Toast（M3）
  · 布局优化（L 批次，§6）

✘ 不做（明确排除）：
  · 追求 `grep -r material_ui lib/` = 0
    因为那要求连 Scaffold/TextField 都自建 ⇒ 工作量数倍，且质量大概率不如官方
  · 把 M4.2「必须 0」当作验收条件 ⇒ **本轮取消这一条**

△ 做一个"程度"门禁替代它：
  · 断：高频可见控件（列表卡/按钮/输入框/对话框）不再直接用 Material 默认皮肤
  · 断：`Theme.of(context).colorScheme` 在 UI 层 = 0（走 AppTheme）
  · 不断：底层 Scaffold/TextField 的存在（那是工具，不是皮肤）
```

**如果 Owner 要的是 A（只换 import）或真的到 B（全自建）**：告诉我，我按那个改。
但我不会在没确认的情况下按 B 硬做 —— 那是把「丑」换成「更丑且更慢」的高风险路线。

---


### M1：主题出口替换（最关键，必须第一）

```text
为什么第一：后面所有控件替换都依赖 Theme.of(context).colorScheme。
           不先改出口，换个控件就得改一次调用，白干两遍。

M1.1  建 lib/ui/theme/app_colors.dart
      · 一个**语义色**类（primary / onSurface / onSurfaceVariant / outline /
        error / surface / surfaceContainer…）
      · ★ 色值**直接取自现有 theme_pack**，不新造色板
      · 上一轮教训：AppPalette 是中性色板、ColorScheme 是语义色板，
        两层不同的东西 —— 所以这次**只做出口替换，不重定义色板**
M1.2  建 AppThemeScope（InheritedWidget）承载 AppColors
M1.3  app_theme.dart 的 themeFor / themeForPack 改为返回 AppColors
M1.4  107 处 Theme.of(context).colorScheme → AppTheme.of(context).colors
      · 机械替换，逐文件做，每 10 个文件跑一次 analyze
M1.5  门禁 theme_scope_test.dart
      · 断：全仓不许再出现 Theme.of(context).colorScheme
      · 断：深浅两套下 colors.primary 非空且不同
      · 故障注入：故意漏一处 ⇒ 必须红
```

### M2：根组件与外壳

```text
M2.1  MaterialApp（180 处）→ 手工组装 App 根
      ⚠️ 最大风险点：MaterialApp 同时承载
         navigator / overlay / theme / localizations / scaffoldMessenger
      · 先做**最小可运行版本**（一个页面 + 一次导航 + 一个 dialog + 一个 toast）
      · 跑通再铺开；不许一次性全改
M2.2  Scaffold（78 处）→ GlassScaffold
M2.3  SnackBar（25 处）→ GlassToast
M2.4  Material（318 处）→ 大部分是「给 InkWell 提供 splash 的壳」，
      删 InkWell 后随之失效；逐处确认，不许盲删
```

### M3：控件替换（按用量降序）

```text
TextButton     154 → GlassButton
InkWell        151 → GestureDetector（无视觉反馈处）/ GlassPressable（需反馈处）
IconButton      91 → GlassIconButton
TextField       88 → GlassTextField
FilledButton    70 → GlassButton.filled
OutlinedButton  62 → GlassButton.outline
Tooltip         59 → 自建 AppTooltip（Glass 无对应）
ListTile        41 → GlassListTile
Slider          34 → GlassSlider
CircularProgressIndicator 30 → 已有 AppLoading（第 65 轮统一了一部分）
Switch          13 → GlassSwitch
Dialog          15 → AppDialogShell → GlassDialog
```

### M4：移除依赖并验证

```text
M4.1  pubspec 删 material_ui
M4.2  grep -r "material_ui" lib/ → 必须 0
M4.3  flutter analyze 全仓 → 0 error
M4.4  全量测试（口径同第 65 轮：排除既有 17 个 libmpv 崩溃文件，并证明零回归）
M4.5  ★ 同步更新 docs/AGENTS.md §4 那两条已失效的规矩
      （「Material 一律 import material_ui」「不再新增 forui」）
```

---

## 6. 批次 L：布局优化（Owner 第 4 条后半）

```text
L1  **先取证**：逐页截图，列问题清单（间距不齐/密度过高/对齐错位/层级不清）
    ★ 不改代码，只出清单 —— 上轮教训：设计类改动不先取证就是瞎改
L2  审计硬编码：grep 未走 Sp / Radii / FontSizes 的地方，统一
L3  逐页调整：首页 / 详情 / 播放器 / 直播 / 设置 / 弹幕面板
L4  每页出**前后对比截图**
```

---

## 7. 批次 H：实测（Owner 第 7 条「实测是必做的」）

```text
H1  **每批构建后真机启动**（用 tools/run_client.ps1，不用裸 flutter build）
H2  逐条功能真跑：本轮 diff 影响到的功能，一条一条实际点
H3  ★ UI 我自己看像素：截图逐张检查，不只看 widget 测试
H4  故障注入：每条新门禁先证明能红，再承认绿
H5  读数归档进 round-66-issues.md
H6  **无干扰纪律**：绝不动鼠标、不抢焦点、不点桌面（用探针 + 截图）
```

---

## 8. 批次 P：第 65 轮遗留功能项（Owner 第 1 条「这次必须实现」）

```text
P1  第 2 条 四站解析器（完全没做）—— 只动 rust/sourin_core/src/providers/，
    与 M 批次（lib/ui/**）不冲突，可真并行
P2  第 8 条 不可播样本集 + 六类归因实测（只做了框架 + 宿主侧一半）
    ⚠️ 这条是 Owner 明确说「这个要修复」的，必须做完
P3  第 10 条 构建后真机自测（根因已找到并修，但没做真机验证）
```

---

## 9. 顺序与依赖

```text
M1 ─→ M2 ─→ M3 ─→ M4
 │                   │
 └───────────────────┴─→ L（布局必须在主题稳定后做，否则改两遍）
                         │
                         └─→ P2/P3（依赖真机，排在 M4 之后）

P1（四站解析器）与 M 并行，文件不冲突
H 贯穿全程，不是最后才做
R 必须最后
```

---

## 10. 需要 Owner 点头的 2 件事

| # | 问题 | 我的建议 |
|---|---|---|
| 1 | 移除 material_ui 后，**没有现成的统一控件框架**了（forui 被禁、Glass 只覆盖一部分）。玻璃控件够不够，要看 L1 取证结果 | 建议**先做 M1+M2 最小验证**（主题出口 + 一个页面跑通），再决定是否需要补自建控件库。若 Glass 覆盖不足，我会把缺口列清单给你，不擅自引第三个包 |
| 2 | 视觉基调是否接受**玻璃 + 实色混排**（浮层用玻璃、正文用实色） | 建议接受。全站玻璃会掉帧且文字可读性差 |

---

## 11. 验收标准

```text
① pubspec 无 material_ui；grep -r "material_ui" lib/ = 0
② flutter analyze 全仓 = 0 error
③ 全量测试通过（排除既有 libmpv 崩溃文件，并证明零回归）
④ 每类替换有门禁 + 故障注入证明能红
⑤ ★ 真机逐屏截图，我自己看过每一张
⑥ 布局优化有前后对比
⑦ P1 四站解析器用真实链接跑通并附读数
⑧ P2 六类归因每类抓到一个真实样本
⑨ 用 tools/run_client.ps1 启动，app.so 大小落在产品区间
```

---

## 12. 风险

```text
R1  MaterialApp 拆解高风险 —— 能编译但运行时白屏。
    对策：最小可运行版本先跑通（一页 + 一导航 + 一 dialog + 一 toast）
R2  318 处 Material widget 多为 splash 壳，删 InkWell 后会有遗漏
    对策：analyze + 真机逐处点击验证
R3  视觉回归 —— 换控件后观感必变，Owner 可能觉得更丑
    对策：每批出截图给 Owner 看，不攒到最后
R4  第 65 轮已记录：17 个文件 libmpv 原生崩溃，本轮不修但要用同样方法证明零回归
R5  P1 四站解析器受 t98 门禁约束：不许出现站名，用中性命名 + 占位符
R6  ★ Glass 控件覆盖不足的风险 —— 见 §10 第 1 条
```

---

## 13. 状态跟踪

| 批次 | 内容 | 状态 |
|---|---|---|
| M1 | 主题出口替换 | 待开工 |
| M2 | 根组件与外壳 | 待开工 |
| M3 | 控件替换 | 待开工 |
| M4 | 移除依赖并验证 | 待开工 |
| L | 布局优化 | 待开工 |
| H | 实测 | 贯穿全程 |
| P1 | 四站解析器 | 待开工 |
| P2 | 不可播样本集 | 待开工 |
| P3 | 第 10 条真机自测 | 待开工 |
| R | 发版 | 待开工 |

---

# 第 66 轮补充：Owner 新增 13 条（2026-10-18 09:08）

> 这 13 条是 Owner 审计划后追加的。每条都**先核实代码现状**再写方案，
> 不核实的推测一律标 ⚠️。

## 核实结果总表

| # | Owner 要求 | 核实结论 | 现状 |
|---|---|---|---|
| 1 | 弹幕发送改底栏输入框，不要悬浮；随开关与能力显示，不支持就不显示 | `DanmakuSendBar` 现在是 `Positioned` 右下角**浮层** | 要改 |
| 2 | 允许引入兜底包 | `glass_kit`/`backdrop` **未装**，Owner 已授权可引 | 可用 |
| 3 | 用 `tools/run_client.ps1` 启动 | Owner 同意 | 已定 |
| 4 | 接受玻璃+实色混排 | Owner 确认 | 已定 |
| 5 | 搜索框移到右侧列表区；切分组列表不变；不能编辑已有 | ① 搜索框在**页头**（`live_page.dart:2653`）② 见下方**真因** ③ 「改名」功能**不存在** | 要改 |
| 6 | 除插件自身外的弹幕都应**手动绑定**，不要自动 | `_autoBindBili()` 在起播时**自动**调 `autoBindBySearch`（`player_page.dart:6349/7732`） | 要改 |
| 7 | 两个站还是不支持发弹幕 | **本地 32 个插件里 0 个声明 `danmaku_send`** ⇒ 宿主置灰是对的，缺的是插件能力 | 需插件侧 |
| 8 | 发构建前先实测完毕 | CI 里「全量测试」**已**在「构建」之前（203→207 行）；Owner 要的是**真机实测** | 加流程 |
| 9 | dan-api 全部异步，不许阻塞启动 | 需逐个调用点核实 | 待查 |
| 10 | 官方兜底发带签名的包；生产不可用就删掉 | 签名靠 `--dart-define=DANDANPLAY_APP_ID/SECRET` 注入，构建时**没传** | 要改 |
| 11 | 点配置提示「无配置项」，编排弹窗出不来 | `settings_page.dart:1602` `_flash('「${e.name}」没有可配置项')` | 要修 |
| 12 | 统一 toast，不要自己写 | `app_toast.dart` **存在但 0 处使用**；`_flash`/自写 **188 处** | 要改 |
| 13 | 健康/测速显示 正在数/总数、按速度排序、可手动排序、完成发 toast、退出页面/退出软件要处理好 | 测速**已有** `测速 $_done/$_total`（`plugin_speedtest.dart:1784`）；健康检测是**一次性批量** `healthSweep()`，**无进度无逐项**，失败只 flash 一句 | 要改 |

---

## 🔴 第 5 条的真因（已在你机器上取到证据）

**你的真实数据目录**（`%APPDATA%\app.sourin.player\ui-prefs.json`）实测：
```text
live_source_groups  =>  {"常看": []}      ← v1 存在，但值是**空列表**
live_channel_groups =>  **键根本不存在**   ← v2 从来没写进去过
```

而筛选函数 `liveGroupAllowsChannel`（`live_page.dart:224`）的第 ③ 条分支是：
```dart
// ③ 两个都没有 / 空组 ⇒ 全部放行（绝不筛成空）
return true;
```

⇒ **空 v1 + 不存在的 v2 ⇒ 走 ③ ⇒ 全部放行 ⇒ 列表显示全部**。
这与你的症状「只加了一个却还是展示全部」**完全吻合**。

**所以问题不是筛选逻辑错，而是「你添加的那个频道没有落盘」。**
写入路径存在（`live_groups_page.dart:183` 的 `setLiveChannelGroups(_groups)`），
但 `setLiveChannelGroups` 传空 Map 时会 `remove(key)`（清键），
所以落盘时 `_groups` 是空的。

**待查**：`_groups` 为什么在保存时是空的（勾选没进 `_groups`？还是管理器页与设置页不同实例？）。
这条要**先复现再修**，不许猜。

**另外**：「不能对已有的编辑」= 改名功能根本不存在（只有「删除分组」），要新增。

---

## 第 7 条的真因（实测）

```text
本地插件目录 32 个 .js
声明 danmaku_send 的：**0 个**
```
⇒ 宿主侧 `_danmakuCanSend` 读到 false ⇒ 置灰 + 显示原因，**行为是正确的**。
要真正支持发送，需要**插件实现 `danmakuSend()`**，属插件侧工作（私库 `sourin-plugins`）。

⚠️ 这条不能只在宿主侧改 —— 宿主改不出插件没有的能力。**方案见下方 N7。**

---

## 新增批次 N（按 Owner 13 条拆）

### N1：弹幕发送改底栏内嵌（第 1 条）

```text
现状：DanmakuSendBar 是 Positioned 浮层（player_page.dart:15289）
目标：移进播放器底栏，与其它按钮同一行
判据：
  · 弹幕总开关开 AND 该源支持 danmaku_send ⇒ 显示输入框 + 发送按钮
  · 任一不满足 ⇒ **整条不显示**（不是置灰 —— Owner 明确说「不支持就不显示」）
  ⚠️ 这与第 65 轮的口径相反（当时是「置灰可见」）⇒ 按 Owner 最新要求改，旧口径作废
门禁：四种组合（开/关 × 支持/不支持）各一条断言 + 故障注入
```

### N2：直播搜索框移位 + 分组修复 + 可编辑（第 5 条）

```text
N2.1  搜索框从页头移到右侧列表区顶部
      ⚠️ 页头是横跨两栏的，移进右栏后宽度变窄 ⇒ 要改布局，不是挪一行
N2.2  **先复现**「添加一个频道后落盘为空」，再修
      判据：真机添加 1 个频道 → 退出 → 重进 → 分组只显示那 1 个
N2.3  分组**改名**功能（当前只有删除）
N2.4  分组内**增删频道**功能（当前只能建组后由直播页勾选）
```

### N3：弹幕改为手动绑定（第 6 条）

```text
现状：起播时 _autoBindBili() 自动调 autoBindBySearch（player_page.dart:6349/7732）
目标：除「插件自身提供的该视频弹幕」外，一律**手动**绑定
判据：
  · 起播**不再**自动搜索绑定
  · 提供明确的「绑定弹幕」入口，用户点了才搜
  · 插件自带弹幕不受影响（那条路是 provider 自己给的）
⚠️ 这会让「起播就有弹幕」的体验变差（多一步），但这是 Owner 明确要求
门禁：起播后断言「没有发起任何绑定搜索」+ 故障注入（把自动调用加回去 ⇒ 必须红）
```

### N4：两个站的弹幕发送（第 7 条）

```text
前提：宿主侧能力齐全（danmaku_send 字段、provider_danmaku_send 调用都在）
缺的是**插件实现**。两条路：
  A. 在私库 sourin-plugins 里给这两个站的插件实现 danmakuSend()
  B. 若站点接口不允许第三方发送 ⇒ 如实告诉 Owner「做不到」，不硬造
⚠️ 必须先实测这两个站的发送接口是否可用（真请求），再决定 A 还是 B
```

### N5：dan-api 全异步（第 9 条）

```text
要查：所有 dan-api 相关调用是否在启动路径上同步等待
  · 内置实例探测（kDanmakuPublicInstances）
  · 弹幕搜索 / 获取
判据：启动到首屏的耗时**不因 dan-api 慢而变长**（附改前后读数）
门禁：把 dan-api 请求人为延时 5s ⇒ 首屏仍应在正常时间内出来
```

### N6：官方兜底签名包 + 生产不可用则删（第 10 条）

```text
现状：签名靠 --dart-define=DANDANPLAY_APP_ID/SECRET 注入，构建时没传
要做：
  ① 构建时注入真实凭证（走 GitHub Secrets，不落仓库）
  ② **先实测**生产环境官方兜底能否真取到弹幕
  ③ 实测不通 ⇒ 按 Owner 要求**删掉**这条兜底（连同 UI 入口）
⚠️ ②是前置：不实测就注入凭证等于白做
```

### N7：可视化编排修好（第 11 条）

```text
现状：settings_page.dart:1602  _flash('「${e.name}」没有可配置项')
      1117 行注释已写明：那里调 SourceComposerDialog 时**没传 initial** ⇒ 编排器空白
要做：
  ① 查 pluginConfigGet 为什么返回空 fields（是插件真没声明，还是解析丢了）
  ② 编排器入口从编辑入口**直达**、带初值、提交即生效
判据：点「配置」⇒ 编排弹窗**真的显示出来**，且带当前源的内容
```

### N8：统一 toast（第 12 条）

```text
现状：app_toast.dart **存在但 0 处使用**；_flash / 自写 188 处
要做：全部改走 AppToast，删掉自写实现
判据：grep 自写 toast = 0；AppToast 调用点 = 原 188 处
⚠️ 这是机械替换，但量大 ⇒ 逐文件改 + 每 20 处跑一次 analyze
```

### N9：健康检测/测速进度与排序（第 13 条）

```text
现状：
  · 测速**已有**进度 `测速 $_done/$_total · $_allConcurrency 路并发`
  · 健康检测是**一次性批量** healthSweep()，**无进度、无逐项**
  · 失败只 flash 一句「健康检测失败：$e」← Owner 看到的
要做：
  ① 健康检测改**逐项**执行，显示「正在执行 N/总数」
  ② 测速同样显示（已有，核对是否真的在跑）
  ③ 一键按速度排序（排序后仍可手动拖拽调整）
  ④ 测速完成发一条 toast
  ⑤ 退出页面 / 退出软件的处理（在途任务要能取消，不许泄漏）
判据：真机跑一次完整测速 + 健康检测，附读数与截图
⚠️ Owner 明确说「这个记得跑一下实测」
```

---

## 更新后的批次顺序

```text
M1 ─→ M2 ─→ M3 ─→ M4        （移除 material_ui，主体）
                        │
N1/N2/N3/N5/N6/N7/N8/N9 可与 M 并行 —— 但**都要避开 lib/ui/player_page.dart
                        和 lib/ui/settings_page.dart**（M 批次会大改这两个）
                        ⇒ 实际顺序：先做完 M1-M4，再集中做 N
N4 需先实测站点接口，可独立提前做（只动私库插件 + rust）
L（布局）在 M4 之后
P（上轮遗留）与 M 并行（只动 rust/providers）
H（实测）贯穿全程
R（发版）最后
```

**冲突规避**：`player_page.dart`（2 万行）和 `settings_page.dart` 是本轮最热的两个文件，
M 批次与 N1/N3/N7/N8/N9 都要动它们 ⇒ **必须串行**，不许并行改同一个文件。

---

## 需要 Owner 确认的 1 件事

**第 1 条的口径与第 65 轮相反**：上轮你定的是「不支持发送 ⇒ 置灰但可见」，
这轮你说「不支持就不显示」。我按**最新要求**做（不显示），
但确认一下：**弹幕总开关关闭时**，也不显示对吧？（我理解是：两个条件任一不满足就不显示）

## 第 7 条要提前说清

宿主侧改不出插件没有的能力。两个站不支持发送的**根因是插件没实现**。
我会先实测这两个站的发送接口通不通：
- 通 ⇒ 在私库实现
- 不通 ⇒ 如实报「做不到」，不硬造一个假入口

---

# 第 66 轮再补充：口径确认 + 拖动卡顿 bug（2026-10-18 09:5x）

## 一、第 1 条口径已确认（按本轮优先）

Owner 2026-10-18 确认：

> 「按照这轮的优先」
> 「弹幕总开关关闭时也不显示，对吧？」→「没问题」

⇒ **定稿口径**：弹幕发送栏**整条显示/不显示**，判据是两个条件**任一**不满足就**完全不显示**：

```text
显示条件（AND）：
  ① 弹幕总开关为开
  ② 当前源声明 danmaku_send = true（插件真的实现了发送）
任一不满足 ⇒ **整条不渲染**（不是置灰、不是禁用、不是显示原因）

⚠️ 第 65 轮的口径「置灰可见 + 显示原因」**作废**。
   连带作废的还有当时为它写的门禁断言（t65 那批「置灰但有原因」的断言要改）。
```

---

## 二、🔴 新 bug：缓冲条已满，拖动进度条仍转圈很久

**Owner 原话**：
> 进度条缓冲条都拉满了,我拖动实践结果还是要转圈圈好长的时间,这也是bug

**截图证据**：进度条下方的缓冲条（浅色部分）**已铺满全宽**，
说明 mpv 的 demuxer 缓存已经吃到了文件尾 —— 数据**就在本地**。
但拖动后仍然出现 `AppLoading` 转圈。

### 已核实的根因链（不是猜）

```text
① 转圈的唯一判据
   player_page.dart:14507
     if (_buffering && !_loading) AppLoading(...)
   而 _buffering 直接来自 media_kit：
   player_page.dart:3949
     _player.stream.buffering.listen((v) => setState(() => _buffering = v));

② _buffering 是 media_kit 对 mpv `cache-buffering-state` 的**布尔化**
   ⇒ 它表达的是「mpv 认为自己在等缓冲」，**不等于**「本地没有数据」

③ 关键：mpv 的 `cache-pause` / `cache-secs` **全仓没有配置**
   实测 grep：lib/ 与 rust/ 里 **0 处** 设置 cache-pause / cache-pause-wait / cache-secs
   ⇒ 用的是 mpv 默认值：
     · cache-pause = yes（默认）：缓冲不足时**主动暂停**播放
     · cache-secs 默认 10s：等缓冲填到 10s 才恢复

④ 于是拖动时的实际行为
   seek ⇒ mpv **丢弃**当前位置之后的重排缓冲，从头重新填
        ⇒ 即便文件已完整下载/已缓存到磁盘，mpv 仍会重新走一遍
           demux → 填 demuxer-cache-time
        ⇒ 期间 cache-buffering-state < 100 ⇒ buffering = true
        ⇒ UI 转圈，直到填够 cache-secs
```

**这就是「缓冲条满却还转圈」的机制**：缓冲条画的是
`demuxer-cache-time`（已缓存到哪），而转圈看的是 `cache-buffering-state`
（此刻是否在等）—— **两个不同的量**。seek 后前者仍然满（数据在），
后者归零（正在重填）⇒ 表现就是「满条 + 转圈」。

### 修复方向（要实测验证，不先写死）

```text
F1. seek 后**不要立刻信** buffering=true
    · 加一个「seek 宽限期」：seek 后 N ms 内的 buffering 变化不驱动转圈
    · 风险：若真的需要缓冲，宽限期会让用户看到「假流畅」然后卡住
    ⇒ 必须实测：宽限期取值要能覆盖本地缓存的 seek 重填时间

F2. 配 mpv 参数减少重填
    · `cache-pause=no`（或 cache-pause-wait 调小）⇒ 不等满就继续
    · 但**会**在慢网络下造成真卡顿 ⇒ 要按「已缓存到磁盘」与否区分
    · `cache-on-disk=yes` 已在用（cache-dir 已配）

F3. 区分「本地已完整」与「网络流」
    · 已完整缓存的片子：seek 应该**秒开**，不该有转圈
    · 网络流：转圈是诚实的
    ⇒ 判据要用「该位置是否已在 demuxer cache 内」而不是全局 buffering

F4. 转圈本身也可能有延迟
    · AppLoading 是 500ms 轮询的 _BufferPoller 之外的另一条链路
    · 要量「从 seek 到转圈消失」的真实毫秒数
```

**验收（必须实测，不许只看代码）**：
```text
① 真机：拖到一个已缓存的位置 ⇒ 记录「转圈出现时长」，目标 < 200ms 或干脆不出现
② 真机：拖到一个**未缓存**的位置（网络流）⇒ 转圈仍应出现（证明没把真卡顿也藏掉）
③ 故障注入：把 F1 的宽限期设成 0 ⇒ 门禁必须红
④ 附改前/改后同一操作的耗时读数
```

⚠️ **不许**用「去掉转圈」来"修复" —— 那会把真实的卡顿也藏起来。
必须做到「本地已缓存 ⇒ 不转圈；真需要等 ⇒ 仍转圈」。

---

## 三、批次 N1 口径更新（覆盖前文）

```text
N1 的判据改为：
  · 弹幕总开关开 AND 源支持发送 ⇒ 底栏内嵌输入框 + 发送按钮
  · 否则 ⇒ **整条不渲染**
  · 连带改：t65 那批「置灰可见 + 原因」的断言全部改写
            旧断言在新行为下必须变红（证明行为真的变了）
```

## 四、新增 N10：拖动卡顿（本 bug）

```text
见上文第二节。归入批次 N，但**优先级最高** ——
这是 Owner 亲自截图报的、影响核心体验的缺陷。

依赖：无（不依赖 material_ui 移除）
⇒ 可以**立即开工**，与 M 批次并行（但都动 player_page.dart ⇒ 必须串行）
```

---

# 第 66 轮再补充（三）：播放页鼠标移动卡顿（Owner 指定「必须死磕」）

**Owner 原话**：
> 还有播放页那个鼠标动一下 出现控件,也很卡顿,这个是必须死磕解决的问题

**优先级**：Owner 指定死磕 ⇒ 与 N10（拖动转圈）同为**最高优先级**，可立即开工。

---

## 一、🔴 先说最重要的发现：现有门禁测不出这个卡顿

我跑了仓库里已有的 `test/t72_jank_test.dart`，读数：
```text
PA|60 次鼠标移动 => PlayerPage 重建 0 次 / 元素重建 0 次（改前：page=60 / all=9960）
PB|180 次 tick   => 位置 setState 3 次, 整页重建 0 次
PC|抽屉关着：10 次整页重建 => onLiveChannels 被调 0 次
00:01 +5: All tests passed!
```

**「0 次重建 + All tests passed」与 Owner 实际感受到的卡顿同时成立。**
原因（已核实）：
```text
该测试只**数 setState 次数**，全文件 grep 不到任何
FrameTiming / buildDuration / SchedulerBinding.addTimingsCallback
⇒ 它证明的是「没有多余的整页重建」，**不证明「不卡」**。
```

⇒ **本轮必须补「帧耗时」门禁**，否则改完还是只能靠嘴说。
这是本条的第一要务，比修代码更优先 —— 没有仪器就不知道有没有修好。

---

## 二、已核实的代码现状

```text
① 指针入口在整页最外层
   player_page.dart:13970  Listener(onPointerSignal:)
   player_page.dart:13972  MouseRegion(cursor:..., onHover: (_) => _showControls())
   ⇒ Windows 鼠标每秒可达数百次事件

② _showControls()（:12041）每次 hover 都会走三件事
   · if (!_controlsVisible && !_anySheetOpen) setState(...)   ← 已有值守卫（task-72 修过）
   · _applyControlsMotion()      （:1192）
   · _armHideTimer()
   · _noteCursorActivity()       （:1009）
   三条都**不触发整页重建**（已逐一核实）⇒ 所以 PA 读数确实是 0

③ 但每次 hover 仍有的开销
   · _applyControlsMotion() 里读 MotionPrefs.duration(context, ...)
     —— 读 InheritedWidget（无障碍「减少动态效果」）
   · _noteCursorActivity() 在**全屏**且指针在内时：
     _resetCursorIdle() + Timer.cancel + 新建 Timer
     ★ 而 _resetCursorIdle() 在 _cursorIdleStale 为真时**会 setState 整页**
   · _armHideTimer() 每次 cancel + 新建 Timer

④ 光标隐藏路径的整页重建
   player_page.dart:1056  _resetCursorIdle() { setState(() => _cursorIdleStale = false); }
   注释自己写着：「本页整棵子树本来就在这个 State 的 setState 里重建」
   ⇒ 光标一翻就重建**整页 884 行 build**（:209 起的 build）

⑤ 动画没有局部化
   _controlsFade 是 Animation<double>（:1176），
   但**没有用 AnimatedBuilder 包住**它消费的子树
   ⇒ 若动画帧靠 setState 驱动，就是每帧整页重建
   ⚠️ 这一条**尚未证实**，是本轮要测的第一个对象
```

---

## 三、修复方向（都要实测，不许先写死）

```text
F1. 【先做】补帧耗时门禁（没有它后面全是猜）
    · 用 SchedulerBinding.instance.addTimingsCallback 采 FrameTiming
    · 指标：hover 期间 buildDuration / rasterDuration 的 P50 / P99 / 最大值
    · 对照：① 静止不动 ② 每秒 60 次 hover
    · ★ 必须能变红：人为在 hover 路径加一次 setState ⇒ P99 必须显著恶化
    · 同时补「真机」读数（widget 测试测不出 GPU/合成层开销）

F2. 把光标态从整页 setState 里摘出来
    · _cursorIdleStale 改成 ValueNotifier<bool>
    · 只用 ValueListenableBuilder 包住**那个 MouseRegion 的 cursor**
    · 判据：光标隐藏/恢复时，整页 build 次数必须为 0

F3. 把控制条淡入淡出局部化
    · 用 AnimatedBuilder 只包住需要改 opacity 的那几层
    · 判据：动画期间整页 build 次数为 0（元素重建只发生在被包的子树）

F4. hover 路径去掉每帧的 InheritedWidget 读
    · MotionPrefs.duration(context) 提到 didChangeDependencies 缓存
    · 判据：hover 期间不再有 context 依赖查询

F5. Timer 抖动
    · _armHideTimer / _noteCursorActivity 每次 hover 都 cancel+新建
    · 改成「记录最后活动时间戳 + 单个周期 Timer 检查」⇒ 避免 Timer 频繁分配
    · 判据：60 次 hover 只产生 1 个 Timer（不是 120 次 cancel/create）

F6. 若真机仍卡 ⇒ 查合成层
    · 视频纹理 + 半透明浮层的混合开销
    · 可能要给浮层加 RepaintBoundary / 减少 opacity 层数
    · ★ 这条只能真机验证，widget 测试测不出
```

---

## 四、验收（Owner 要求「必须死磕」，所以标准要硬）

```text
① 帧耗时门禁落地，且**故障注入能红**（人为加 setState ⇒ P99 恶化）
② 60 次/秒 hover 下：整页 build = 0，元素重建 = 0
③ 光标隐藏/恢复：整页 build = 0
④ 控制条淡入淡出：整页 build = 0
⑤ ★ 真机读数：hover 期间 P99 帧耗时 < 16.7ms（60fps 预算内）
   —— 达不到就继续查，不许改口径
⑥ 附改前/改后同一操作的读数对比
⑦ 副作用检查：控制条仍要能正常显隐、光标仍要能正常隐藏、不能变硬切
```

⚠️ **红线**：不许用「减少动画」「去掉淡入淡出」来换帧率 ——
    那是把功能砍掉冒充优化。用户明确要过动画（「要有动画」）。

---

## 五、与其它批次的关系

```text
N10（拖动转圈）与 N11（本卡顿）都要改 player_page.dart（2 万行）
⇒ **必须串行**，且两者可以合并成一批做（同一文件，避免来回切）

M 批次（移除 material_ui）也改 player_page.dart
⇒ 顺序建议：先做 N10+N11（纯性能，不动 UI 结构）
              再做 M（结构大改，届时性能门禁已存在，可防回归）
```

---

# 第 66 轮再补充（四）：批次 Z —— 逐页三遍排查（Owner 指定，放最后）

**Owner 原话**：
> 你逐个页面一个一个排查 反复查三次 自我纠错,这个放在最后面

**位置**：**所有批次之后**（M / N / L / P / H 全部完成后才开工）。
**理由**：前面的批次都在改代码，改完才谈得上「排查」；否则查完又变，白查。

---

## 一、什么叫「一个一个页面」

**不按文件查，按用户能走到的页面查。** 清单以 `task44_all_subpages_test.dart`
的 `subPages` 为准（该测试是全仓二级页的机械清单，漏了新页面它先红）。

```text
一级（底栏 tab）
  ① 首页 / 推荐
  ② 搜索
  ③ 追更
  ④ 直播
  ⑤ 本地
  ⑥ 设置

二级（设置内）
  按 task44 的 subPages 清单逐项（数据管理 / 播放 / 跳过 / 弹幕 / 直播分组 /
  Emby / 关于 / 更新 …）

全屏页
  · 播放页
  · 详情页
  · 来源导入 / 可视化编排弹窗
  · 各类 dialog / sheet / 浮层
```

## 二、什么叫「反复查三次」

**三次是三个不同视角，不是同一个检查跑三遍。**

```text
第 1 遍：**能看见的**
  · 真机截图，逐页看像素
  · 找：错位 / 溢出 / 截断 / 空白 / 对比度不够 / 文案截一半
  · 判据：我自己看，不靠测试断言

第 2 遍：**能操作的**
  · 每个按钮点一遍、每个开关拨一遍、每个输入框输一遍
  · 找：点了没反应 / 反应错 / 状态不回写 / 报错文案看不懂
  · ★ 三种输入都要试：鼠标悬停 / 触摸 / 方向键焦点（仓库要求）

第 3 遍：**能坏的**
  · 空数据、超长文本、断网、无权限、任务执行中退出页面
  · 找：崩溃 / 白屏 / 永久 loading / 状态泄漏
  · 这一遍最容易出问题，也最少人做
```

## 三、自我纠错（不是「查完就完」）

```text
每页查完必须产出一条结论，三选一：
  ✅ 通过   —— 附截图
  🔧 已修   —— 附改前/改后截图 + 说明
  ⚠️ 遗留   —— 写进 round-66-issues.md，说明为什么不修

★ 关键：第 2 遍 / 第 3 遍发现问题 ⇒ 修完要**回到第 1 遍重看**
  （改代码可能改坏视觉）—— 这才叫「自我纠错」，不是线性走一遍。
```

## 四、验收

```text
① 每个页面都有三遍的结论（不是只写「已查」）
② 所有 🔧 项有改前/改后截图
③ 所有 ⚠️ 项写进 issues 文档且有「为什么不修」的理由
④ 产出 docs/notes/round-66-page-audit.md：一页一行，三列（三遍）结论
⑤ ★ 这一批**不许跳过**，也不许缩成「抽查几页」
```

---

## 五、最终批次顺序（定稿）

```text
第 1 波（并行，互不冲突的文件）
  轨道 A  playback-fix   → player_page.dart 独占：
                           N10 拖动转圈 + N11 鼠标卡顿 + 帧耗时门禁
  轨道 B  live-ux        → live_page.dart / live_groups_page.dart：
                           N2 直播搜索移位 + 分组落盘修复 + 改名增删
  轨道 C  plugin-repo    → settings_page.dart / source_composer_dialog.dart /
                           plugin_speedtest.dart / app_toast.dart：
                           N7 可视化编排 + N9 健康测速 + N8 toast 统一
  轨道 D  danmaku        → lib/core/danmaku.dart 及弹幕组件：
                           N5 dan-api 全异步 + N4 两站发送能力实测

第 2 波（轨道 A 释放 player_page.dart 之后）
  N1 弹幕发送改底栏内嵌 + N3 改手动绑定（都在 player_page.dart）

第 3 波（串行，大工程）
  M1 → M2 → M3 → M4 移除 material_ui

第 4 波
  L 布局优化（主题稳定后）
  P1 四站解析器（rust，可与 M 并行）
  P2 不可播样本集 / P3 第 10 条真机自测

第 5 波
  H 完整实测（贯穿全程，最后汇总）

第 6 波 ★ 最后
  Z 逐页三遍排查 + 自我纠错

第 7 波
  R 自审 → PR → 合并 → 发版
```

---

# 第 66 轮再补充（五）：第 2 波（N1/N3）的代码现状与口径冲突处理

> 这两条都动 `player_page.dart`，归**第 2 波**（等轨道 A 释放该文件后再做）。

## N1：弹幕发送改底栏内嵌 + 不显示

### 现状（已核实）
```text
组件   DanmakuSendBar（player_page.dart:19407）
挂载   player_page.dart:15289  Positioned(right: Sp.x3, bottom: _kPlayerBottomBarHeight + Sp.x2)
       ⇒ 是**浮层**，浮在视频右下角上方
门控   if (_danmakuSendProvider != null && !_isLive && _chromeVisible)
       ⇒ 只判「有真站点 id」「不在直播」「控件可见」
       ⇒ **没有判弹幕总开关**，也没有判源能力就整条不渲染
```

### ★ 与第 65 轮的**口径冲突**（必须显式处理）
`DanmakuSendBar.canSend` 的注释（player_page.dart:19439 起）写着：
```text
⚠️ 为什么不是"干脆不渲染"（改前的做法）：
   Owner 第 9 条：「有些站点是支持发送弹幕的,你在软件实现了,
   但是并没有发送弹幕的入口,这个需要修复。」
   入口消失 ⇒ 用户连"这个能力存在"都不知道
```
**这与 Owner 本轮最新要求相反。** Owner 2026-10-18 确认：
```text
「按照这轮的优先」
「弹幕总开关关闭时也不显示，对吧？」→「没问题」
```

⇒ **处理方式**（不许含糊）：
1. 代码按**最新口径**改：两个条件任一不满足 ⇒ **整条不渲染**
2. `canSend` / `disabledReason` 两个字段若因此不再使用 ⇒ **删掉**，不留死参数
3. 那段注释**改写成新口径**，并注明「第 65 轮口径已作废，原因见 round-66」
4. 第 65 轮为旧口径写的断言全部改写；**新断言在旧行为下必须变红**（证明行为真变了）

### 要做
```text
① 从 Positioned 浮层移进播放器底栏，与其它按钮同一行
② 显示判据（AND）：
    · 弹幕总开关为开
    · 当前源 danmaku_send == true
    · （原有）有真站点 id、非直播、控件可见
   任一不满足 ⇒ 整条不渲染
③ 门禁：四种组合（开关开/关 × 支持/不支持）各一条断言
   + 故障注入（把总开关判断拿掉 ⇒ 必须红）
```

---

## N3：弹幕改手动绑定

### 现状（已核实）
```text
自动绑定   _autoBindBili()（player_page.dart:7732）
           调用点  player_page.dart:6349
             if (_danmakuEnabled && biliBind == null) {
               final ok = await _autoBindBili();
               if (ok) return;
             }
           ⇒ **起播时自动**调 autoBindBySearch
手动绑定   已有：用户可选搜索结果（:7042 / :7108）
           danmaku_info_panel 里 DanmakuPairKind.manual => '手动绑定'
           ⇒ 「手动」这条路**本来就存在**，缺的不是入口
```

### 要做
```text
① 删掉起播时的自动绑定调用（:6349 那一段）
② 插件自身提供的弹幕**不受影响**（那条路是 provider 自己给的，不经过 autoBind）
③ 确认手动绑定入口在起播后**可见且可达**（不能因为删了自动绑定就找不到）
④ 门禁：起播后断言「没有发起任何绑定搜索」
   + 故障注入（把自动调用加回去 ⇒ 必须红）
```

### 副作用（必须如实告知 Owner）
```text
删掉自动绑定后，「起播就有弹幕」会变成「起播没弹幕，要手动绑一次」。
这是 Owner 明确要求的（「所有的弹幕...都应该手动绑定,而不是自动」），
但体验上是**退步**，必须在交付说明里写清，不许当成纯优化汇报。
```

---

# 第 66 轮再补充（六）：N11 的两条实测修正（perf-player 汇报，Lead 已独立复核）

## 修正一：brief 里指定的 FrameTiming 仪器在 widget 测试里是**假仪器**

我在计划里写「用 `SchedulerBinding.addTimingsCallback` 采 FrameTiming」——
**这条写错了，已作废。**

实测（perf-player 做，我复核了 Flutter 源码）：
```text
实验（同一台机）            FrameTiming buildDuration    Stopwatch 围 pump()
轻树 30 帧                  7us（frames=1）              121us
重树 30 帧 setState         3us（frames=1）              9903us p99=26657us  ← 差 80 倍
真实 PlayerPage 60 hover    3us                          p50 45us / p99 188us
```

根因（我核了源码，确认）：
`flutter_test` 的 `AutomatedTestWidgetsFlutterBinding`
在 fake-async 里**直接调** `handleBeginFrame(null)` / `handleDrawFrame()`
（`packages/flutter_test/lib/src/binding.dart:2356-2358`）
⇒ **不经过引擎 frame pipeline** ⇒ 帧耗时数据不来自被测代码的 CPU 工作。
重树读数反而比轻树小 ⇒ 与负荷**无相关性**。

**改用**：`Stopwatch` 围 `tester.pump()` —— pump 的同步段包含建帧 + 构建 +
布局 + 绘制，即该帧在 UI 线程上的全部 Dart 侧工作。判别力已证（80 倍）。
**已知局限**：测不到 GPU raster ⇒ 必须另补真机探针，且交付里要标注「没做的那部分」。

## 修正二：N11 的真实根因比我写的更靠前 —— t72 有**结构性盲区**

```text
t72_jank_test.dart    grep 不到任何 fullscreen 相关代码
player_page.dart:1012 _noteCursorActivity() 第一行就是
                      if (!_fullscreen) return;
```

⇒ **t72 只在窗口模式下 hover，光标那条路径在它里面从不执行；**
   而真机全屏下它每帧都跑。

**这就是「t72 绿着 + All tests passed」与「用户觉得卡」并存的结构性原因**
—— 不是 t72 写错了，是它**只覆盖了一半场景**。

## 改前红基线（perf-player 建立，我独立复现，读数一致）

```text
T1 控制条隐藏后 1 次 hover 叫回  ⇒ pageBuild=1 all=188  帧 8958us   [红]
T2 隐藏光标 / 恢复光标           ⇒ pageBuild=1 all=190 / 188      [红]
T3 光标已隐藏 60× hover          ⇒ pageBuild=1 all=247 p99=880us   [红]
T4 光标已显示 60× hover          ⇒ pageBuild=0 all=0  p99=220us    [绿·阴性对照]
T5 控制条淡出动画                ⇒ opacity 采样到中间帧 0.86/0.78/0.68/0.52/0.32/0.07
                                    pageBuild=0                     [绿·Owner 红线守卫]
T6 隐藏→hover 循环 8 轮          ⇒ pageBuild=8 all=1504 p50=7639us [红]
结果：+3 -4
```

**3 绿 4 红 ⇒ 阴性对照有效**（证明不是「怎么都红」的假门禁），
且 T5 守着 Owner 的红线：**动画没被砍**（采样到 opacity 中间帧）。

## 对交付的新增要求

```text
① N11 修完必须保持 T5 绿（动画仍在动，不是硬切）
② 绿了之后必须**再做一次故障注入**（改回整页 setState ⇒ 门禁要再红），
   证明修完的门禁仍有判别力
③ 必须补一条真机探针，给出「真机全屏 hover 期间 P99 帧耗时」，
   验证 widget 门禁的结论在真机上成立
④ 交付里明确标注「Stopwatch 测不到 GPU raster」这个局限
```

---

# 第 66 轮再补充（七）：健康检测**必然超时**的真缺陷（Lead 复核确认）

## 一、这是一个真实缺陷，不是「测试挡路」

轨道 C 报称 `test/provider_import_test.dart` 的 2 条断言把 `healthSweep()`
钉成唯一正确实现，与 Owner 第 13 条（要显示进度）互斥。
我逐层复核了它给的证据链，**全部成立**，而且比它说的更确凿。

### 根因链（我逐条核过代码）

```text
① 健康探活有三层实现，只有两层是真的
   rust/sourin_core/src/provider.rs:571
     trait 默认实现  async fn health_check(&self) -> bool { true }   ← **恒真**
   rust/sourin_core/src/providers/declarative.rs:688   有真实现（探 categories / list）
   rust/sourin_core/src/providers/http.rs:485          有真实现（重拉 /manifest）
   ⇒ **JS 插件全部落到 trait 默认 ⇒ 恒返回 true**

② 批量巡检是**串行**的，且最坏耗时远超 FFI 兜底
   rust/sourin_core/src/registry.rs:499  health_sweep()
     for p in targets {
       tokio::time::timeout(Duration::from_secs(15), p.health_check())
     }                        ↑ 逐个子串行，不是并发
   最坏耗时 = 源数 × 15s；本机 32 源 ⇒ **480s**
   而 lib/core/ffi.dart:685 的兜底超时是 **120s**
   ⇒ 必然抛「命令 health_sweep 超时（120 秒）」⇒ **结果全丢**

③ 这正是 Owner 看到的「现在都显示测速 健康失败」
```

### 轨道 C 的真机读数（与上述根因吻合）

```text
调 health_sweep：总耗时 5ms，返回 32 条，全部 true
  ⇒ 因为 JS 插件没实现 health_check，全走默认 Ok(true)
  ⇒ 「全部正常」是**恒真假话**，用户点这个按钮等于什么都没测

真实探活（get_categories）：26 可用 / 5 失败，3931ms，最慢 1992ms
```

⇒ **「批量入口又假又必然超时」**，不是测试问题，是功能本身坏了。
Owner 的要求（逐项 + 显示进度）恰好**同时修掉**这两个毛病。

## 二、处置决定

```text
① 授权轨道 C 改 test/provider_import_test.dart 的那 2 条断言，
   但**断言用意不许变**（仍是「不许假接线」+「判据不许写反」），只换载体。
② 改完必须故障注入：把 _probeProviderHealth( 改回 healthSweep() ⇒ 新断言必须红。
③ 反向断言必须在**剥注释后**的文本上判 ——
   否则将来有人写一句 // 不要用 SourinApi.healthSweep() 就会假红。
```

## 三、记录一条流程教训

我在分派时没要求「改到一半也要保持可编译」，结果轨道 A 把
`player_page.dart` 的语法错误中间态留在共享工作树里，
污染了另外三条轨道的测试信号（任何 import 它的测试都 `No tests ran`）。

```text
教训：多轨道共享工作树时，「独占文件」只解决**写冲突**，
     不解决**编译依赖冲突**。
     ⇒ 规矩要补一条：独占文件可以长改，但**每个逻辑单元结束必须能编译**。
     判据：dart analyze <那个文件> = 0 error。
```

---

## 4.8 Owner 2026-10-18 12:55 截图报的三个新问题（本轮必做）

Owner 原话（逐字）：
```text
> 直播页面,右侧搜索框显示很奇怪
> 左侧播放区域,视频控件都有一半在视窗外了
> 进直播详情页,点击暂停,出来还在播放,状态没统一,切换页面之后
> 直播应该暂停播放,而不是继续播放
> 更新到计划中,这些也要解决
```

### P1-L1 · 右侧筛选条的三个下拉显示异常

**截图证据**：`.probe` 对应 Owner 截图——右侧 1248 频道列表上方的筛选条显示为
「全部分组 ▼ | 全部源 ▼ | 全部分类 | 菜」，四个格子挤在一起，
最后一个「管理」按钮被挤成一个字，且整体像"塌"在列表顶部。

**已定位**（`lib/ui/live_page.dart`）：
```text
:3717  class _FilterBar
:3837  Row( children: [ Expanded(_BarDropdown) × 2~3, Tooltip(InkResponse(管理)) ] )
:3846  Expanded(child: _BarDropdown(key: 'live-bar-group',   display: groupDisplay))
:3857  Expanded(child: _BarDropdown(key: 'live-bar-source',  display: sourceDisplay))
:3871  Expanded(child: _BarDropdown(key: 'live-bar-category',display: categoryDisplay))
:3889  Tooltip(InkResponse(SizedBox(width:28,height:28, Icon(size:16))))
```
源码注释记着历史：「三格 + 管理按钮原样排会**溢出 18px**（92 + 79.8 + 92 + 28 = 300 > 282 可用宽）
⇒ 每格用 `Expanded` 平分」。

**⇒ 根因假设**：`Expanded` 平分把三格压到各 ~78px，
而「全部分类」「全部分组」这类五字标签在 78px 里放不下 ⇒ 文字被截断/挤压。
那个 28px 管理按钮在窄容器里也会被压变形。

**要查的**：
```text
① 右侧面板的实际可用宽度是多少？（Owner 窗口 1444 宽，右侧面板约 300px）
② 三格 + 28px 按钮 = 需要多少最小宽度？
③ 是否应该在窄容器下减少格子（比如隐藏"全部分类"）或换行
④ 「菜」是什么？—— 截图里那个字像是「管理」被截断（Icon 是 tune/add，不是文字）
   ★ 必须亲眼确认，不能猜
```

---

### P1-L2 · 左侧播放区的控件一半在视窗外

**截图证据**：播放区左下角有两个圆形按钮（音量/静音 + 另一个），
**只有右半边可见**，左半边被窗口左边缘切掉。

**已定位**：播放区是 `Positioned.fill` 包着的舞台（`:2776` 附近），
控件应该是 `Stack` 里 `Positioned(left: ...)` 的浮层。

**⇒ 根因假设**：控件的 `left` 偏移量是**负数**，或者用了固定的负 margin，
在窗口宽度变化后没有跟随。

**要查的**：
```text
① 那两个按钮的 Positioned/Align 具体参数
② 是否写死了 left: -20 这类负值
③ 是否与 Owner 2026-10-04 那条「两侧占满」（bandFor 恒返回 windowWidth）有关
   —— tokens.dart:719 bandFor 两个分支都返回 windowWidth，sideInsetForWindow 恒 0
   ⇒ 如果控件用 sideInset 算位置，它会是 0，不该是负的
```

---

### P1-L3 · 直播进详情页后暂停，返回仍在播放（状态未统一）

**Owner 原话**：「进直播详情页,点击暂停,出来还在播放,状态没统一,
切换页面之后 直播应该暂停播放,而不是继续播放」

**已定位**（`lib/ui/live_page.dart`）：
```text
:604  bool _pausedByHide = false;
:605  bool _pausedForFullscreen = false;
:752  void _onVisibilityChanged()   ← 可见性变化 ⇒ 暂停/续播
:775  if (!visible) { ... }         ← 不可见时无条件置位 _pausedByHide
```
源码注释记录了这个机制的演化（task-41/42/74），说明它**曾经**是对的。

**⇒ 三个可能的根因（必须逐条排除，不能猜）**：
```text
① `widget.visible` 没有真正随"进详情页"变化
   —— 进详情页是 push 新路由，直播页仍在树上（IndexedStack / 保活）
   ⇒ visible 可能没被置 false
② 详情页里那个「暂停」按钮控制的是**另一个**播放器实例
   —— 如果详情页自己有播放器，暂停它与内嵌播放器无关
③ `_pausedByHide` 被别处覆盖了
   —— 比如切回来时 `else if (_pausedByHide)` 分支错误地 resume
```

**判据（必须先做）**：
```text
在 _onVisibilityChanged 里加临时日志，真机走一遍：
  进详情页 → 返回 → 看 visible 是否翻转过、_pausedByHide 是否置位
★ 不先取证就改代码，会改坏 task-74 那套已经修好的竞态逻辑
```

---

### 优先级与分配

| 编号 | 问题 | 严重度 | 归属 | 状态 |
|---|---|---|---|---|
| **P1-L3** | 直播暂停状态不统一 | **高**（用户明确要求） | 待派 | ⏳ |
| **P1-L2** | 播放控件一半在视窗外 | **高**（视觉破损） | 待派 | ⏳ |
| **P1-L1** | 筛选条显示异常 | 中 | 待派 | ⏳ |

**三条都要求先取证（真机 + 日志），再改代码。**
这三条都属于「看起来是小问题、改错会破坏已修好的复杂逻辑」的类型。

---

## 4.9 Owner 2026-10-18 12:58：直播频道可用性要缓存 + 定时刷新 + 动态回写

Owner 原话（逐字）：
```text
> 然后还有这个直播频道的可用性应该缓存,而不是每次都实时刷新,
> 然后定时刷新+打开如果不能播放,动态标记 定时再刷新掉状态
> + 有些直播不是一直播放的,这个也要注意
> 更新到计划中,也要解决
```

### 现状核实（我已逐行查过，不是猜）

```text
lib/ui/live_availability.dart:128  class LiveAvailabilityProbe
:130   this.ttl = const Duration(minutes: 10)     ← ① 缓存**已有**
:136   final Duration ttl;
:153   if (DateTime.now().difference(t) > ttl) return null;   ← 过期判定已有

lib/ui/live_page.dart:560   final _probe = LiveAvailabilityProbe();
:563   bool _probed = false;
:1537  Future<void> _probeAll({bool force = false})
:1540  结果进 _probe 的 TTL 缓存 —— 10 分钟内重进不再探
```

**⇒ Owner 要求的 ①（缓存）已经做到了。缺的是 ②③④⑤：**

| # | 要求 | 现状 | 缺口 |
|---|---|---|---|
| ① | 可用性要缓存 | ✅ 已有 TTL 10 分钟 | — |
| ② | 定时刷新 | ❌ `grep "Timer\|periodic" live_page.dart` = 零命中 | 只在进页面探一次 |
| ③ | 打开不能播 ⇒ 动态标记 | ❌ 探测与播放是两条独立的路 | 播放失败不回写 |
| ④ | 定时刷新掉过期状态 | ❌ 只有 TTL 缓存过期，没有状态回写 | 标记后不会自动清除 |
| ⑤ | 区分「暂时没开播」与「源坏了」 | ❌ 无此概念 | Owner 特别提醒 |

### ⑤ 是这条的核心难点

Owner 说「有些直播不是一直播放的」——这要求区分**三种状态**：

```text
· 可用          —— 能播
· 暂时没开播    —— 源在线，但当前没有流（电视台休台 / 主播未开播）
· 源不可用      —— 连不上 / 404 / 超时
```

**判据差异必须实测**（不能凭想象分类）：
```text
连不上/404/超时          ⇒ 源不可用
连上了但空播放列表/无流   ⇒ 暂时没开播
```

### 已派给 live-groups，要求先取证

```text
第一步：实测三类失败的**实际错误形态**（带日志），
        + 提出区分方案
第二步：Lead 确认后才实现
```

**理由**：如果判据错了，后面全错。这与 N14 那条教训同源
（「用 8Mbps 测 cache-secs 会得出假结论」——实验条件错了，结论必错）。

### 实现约束（已写进任务书）

```text
· 定时刷新只刷"不可用"的那些，不要全量重探 1248 个
  —— 全量会让界面一直显示"正在检查 1064/1248"
· 不许每个频道 setState（live_page.dart:1545 有这条教训的完整记录：
  "48 个频道 = 48 次重建会卡"，已节流到每 8 个一次）
· 定时器必须有 dispose（否则页面销毁后还在跑）
```

---

## 4.10 32 插件弹幕能力矩阵（dan-api 产出，结论重要）

**方法**：用宿主真实 QuickJS 加载 32 个插件 + `hydrate_capabilities()` + `has_method()`。
32 个全部加载成功 ⇒ 读数是权威的（不是读代码猜）。

### 结果：只有 1 个插件真的自带弹幕数据

| 形态 | 数量 | 有弹幕吗 | 根因 |
|---|---:|---|---|
| CMS 采集站（Apple CMS） | 21 | ❌ **天生没有** | 实测接口 `provide/vod` 返回体**不含任何弹幕字段** |
| 直播（某个直播平台甲/某个直播平台乙/某个直播平台丙/iptv/tvbox） | 5 | ❌ 天生没有 | 直播流形态，插件未实现 |
| 主流视频站（某个主流视频站/另一个主流视频站/某个电视频道源） | 3 | ⚠️ 站点有，插件没实现 | 某个主流视频站 实测 `comment.某个主流视频站.com/279786.xml` → 200 + 40983B |
| 示例（demo） | 1 | ❌ | 占位 |
| **某个动画站** | **1** | ✅ **有（本轮实现）** | — |

### ★ 关键区分：「插件没实现」≠「站点没有」

```text
· 21 个 CMS 站  → 天生没有（接口不返回弹幕字段）⇒ 不是插件偷懒
· 另一个主流视频站        → 代码注释明写「不声明 danmaku：本插件没有弹幕数据源，声明了也是假的」
                  ⇒ 作者主动诚实
· 某个主流视频站     → 站点**客观有数据**，是插件没实现 ⇒ 可以补
```

### 对 Owner「插件提供」语义的影响

Owner 举的例子「某个动画站」= 某个动画站 ⇒ **正好是唯一有弹幕数据的那个**，且已能工作。

**但「默认自动导入」机制在当前 32 个插件里只命中 1 个。**
⇒ 不能对 Owner 说「插件弹幕都通了」，必须如实说清分布。

### 决策

```text
① 给 某个主流视频站 补 danmakuList（**只读**，不做发送）
   理由：站点客观有数据 + 读接口免登录 + cid 已有（:1215 处理多 P）
   约束：capabilities 只加 danmaku，**不加** danmakuSend
② 矩阵写进私库 README（不放 .probe/ —— 那是 gitignore 的临时目录）
```
