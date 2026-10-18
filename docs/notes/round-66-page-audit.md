# 第 66 轮 逐页三遍排查（批次 Z）

> Owner 原话：「你逐个页面一个一个排查 反复查三次 自我纠错，这个放在最后面」
> 三次 = 三个视角（能看见的 / 能操作的 / 能坏的），不是同一个检查跑三遍。

---

## 0. 取证方法（先说清「我验了什么」）

### 真机截图：用仓库**已有**的自拍机制

```bash
SOURIN_TABS=1 SOURIN_SHOT=1 SOURIN_FRAME_LOG=1
```

它走 `RenderRepaintBoundary.toImage`（`lib/shell.dart:863`），
**从 Flutter 侧渲染**，不受窗口遮挡/未激活影响，也不需要动鼠标。

> ⚠️ 我一开始试图用 `PrintWindow` + `GetWindowRect` 抓窗口，
> 结果 `PrintWindow` 对 Flutter 返回 **1×1**（GPU 直接渲染拿不到），
> `CopyFromScreen` 又抓到被其他窗口遮挡的像素。绕了半小时才发现仓库早有这个机制。
> **教训：先找仓库已有的取证工具，不要自己造。**

### 数据播种的三个坑（都踩过）

```text
① seed_dev_data.ps1 用 $env:APPDATA 找**源**目录
   ⇒ 若先 export APPDATA=隔离目录再跑，它会把隔离目录当源 ⇒ 只拷贝到 1 个 demo.js
   实测：报告「新拷 2 个，保留已有 41 个」，实际 plugins/ 只有 demo.js 一个

② -Target 是**数据目录本身**（对应 DATA_DIR_OVERRIDE 的语义），
   而 Release 构建读的是 %APPDATA%\app.sourin.player
   ⇒ 必须 -Target <X>/app.sourin.player 且 APPDATA=<X>

③ 更新弹窗必须在播种后写 ui-prefs.json 抑制，且 **lastCheckAt 必须是 ISO 8601 字符串**：
   appupdate.lastCheckAt = "2026-10-18T17:24:23.266094"
   ★ 第一版写成整数毫秒 ⇒ DateTime.tryParse 返回 null ⇒ shouldAutoCheck 为 true ⇒ 照样弹窗
   ⇒ 截了 13 张全被弹窗挡住的图，还以为"截图机制坏了"
```

### 播种成功后的实测数据

```text
[HOME] 渲染完成: 启用源=25 个（首页可用，已排除纯直播源） 分区=4 卡片=80
零 Unhandled Exception
窗口 1444×845（ui-prefs 里带着窗口尺寸偏好）
```

---

## 1. 页面清单（以 task44_all_subpages_test.dart:117 的 subPages 为准）

```text
一级（底栏 tab，6 个）
  ① 首页/发现   ② 直播   ③ 追更   ④ 搜索   ⑤ 已缓存   ⑥ 设置

二级（设置内，12 个）
  settings_page / about / backup / pc_gestures / skip / theme /
  playback / touch_gestures / emby / live_groups / danmaku_source / data_manage

全屏页
  播放页 / 详情页 / 来源导入 / 可视化编排 / 各类 dialog·sheet
```

---

## 2. 第 1 遍：能看见的（真机截图，Lead 逐张亲眼看过）

### 已看过的截图与结论

| 截图 | 页面 | 结论 |
|---|---|---|
| `010` `020` | 首页/发现（有数据） | ✅ 通过 |
| `025` | 直播（loading 骨架） | ✅ 通过 |
| `023` `024` | 直播（转场中间帧） | ✅ 通过（见下方「伪影」） |
| 全部 | 空数据态（早期一轮） | ✅ 通过 |

### 首页（`tabshot_010.png` / `020.png`）—— ✅ 通过

```text
✅ 三个分段 tab：最近追更 1 / 最近收藏 1 / 播放历史 12 —— 计数徽标正常
✅ 追更横幅：海报 + 标题「无职转生 第三季…」+「第14集」，不截断
✅ 源筛选条：14 个源 chip 横向滚动，右侧「25 个源」总计正确
✅ TV 番组榜：8 张卡（第 8 张半露，是正确的横向滚动暗示）
✅ 卡片统一：编号 1~8、封面、标题两行截断带省略号、副标题（全 12 集 / 周五23:05后）
✅ 剧场番组榜：第二分组正常开始
✅ 底栏 6 tab 完整，图标+文字
✅ 无溢出、无白屏、无错位、无红屏
```

**唯一观察（非缺陷）**：第 7、8 张卡的标题与底栏在视觉上贴近，
但底栏是悬浮玻璃层，卡片仍可滚动到可读位置 ⇒ 属设计取舍，不改。

### 直播（`tabshot_025.png`）—— ✅ 通过

```text
✅ loading 骨架为两栏（左 268px 频道列表槽 + 右节目单槽），与设计注释一致
✅ 页头「直播 / 0 个频道」正常
✅ 底栏正常
```

**为什么 0 个频道**：12 个源里没有「支持直播」的，属数据环境，不是缺陷。
（`_EmptyState` / 三态分离见 `live_page.dart:2696-2820`）

### ★★ 一条被我否掉的「缺陷」（重要）

`tabshot_023.png` / `024.png` 里，**直播页与首页内容重叠**，看起来像
「KeepAlive 转场后旧页面没消失」的严重缺陷。

**实测否掉**：

```text
burst() 的时机（lib/shell.dart）：
  Timer.periodic(5s) → debugSwitchTo(t) → burst(i+1)
  burst: for k in 0..5 → delay(40ms * k) → 截图
⇒ 截图发生在切换后 **0 / 40 / 80 / 120 / 160 / 200 ms**

而转场时长 = Motion.base = **260ms**（lib/shell.dart:1178，
与二级页 page_transition_route.dart:120-122 共用同一常量）

⇒ 020~025 拍的是 260ms 动画的 **0% ~ 77%** 进度
⇒ 023/024 的"重叠"是**淡出过程中的正常中间帧**
```

**自我纠错记录**：如果我只截一张 023 就下结论，这就是一条听起来很严重的假缺陷
（"切 tab 后旧页面残留"）。**是读懂了取证工具的时序才否掉的。**

★ 建议（下一轮，不在本轮改）：`burst()` 的首帧延迟应从 0ms 改为 ≥300ms，
否则**每次自拍取证都在拍转场动画**，早晚还会误导人。

---

## 3. 第 2 遍：能操作的（静态 + 真机键盘）

### 静态部分（`danmaku` 执行，我核对了全部结论）

**结论：0 个「用户点了没反应」。**

| 检查项 | 结果 |
|---|---|
| 4 个 `unused_element` | 全部**不是回归**（`git log -S` 只返回首次提交 `b289bb6`） |
| 方向键焦点 | **不是缺陷**（全局 `addEarlyKeyEventHandler`，`shell.dart:3707`） |
| `onPressed: null` | 1 处，**有意禁用**（边界按钮置灰不隐藏，`settings_page.dart:5600`） |
| 悬停反馈 | 2 处缺裸 `GestureDetector`，其中 1 处建议修 |

#### 4 个 `unused_element` 逐个核实

```text
_GesturePill      typedef 别名；真类 SettingsGesturePill 被 t92_preset_probe.dart 正常用
_InfoRow          typedef 别名；真类 SettingsInfoRow 被 about_page.dart 正常用
_backupPreview    方法体遗留；功能本身在 backup_page.dart:25（"只调 backupPreview"）
_PluginTile       类已不存在，只剩 4 处注释 ⇒ 历史记录，不是死代码
```

#### ★★ 方向键：一条被我方否掉的 P0 候选

```text
表面：home / search / follow / media / settings 的 Focus=0（只有 live_page 有 12 个）
若只看这个数字 ⇒ "TV 用户完全不能用方向键" ⇒ 听起来是 P0

实际：shell.dart:3707 注册全局 handler
      FocusManager.instance.addEarlyKeyEventHandler(_onEarlyKey)
      shell.dart:4064 配对清理（防泄漏）
      
      shell.dart:4330-4390 记录了**三次失败**才走到这里：
      ① FocusTraversalGroup(ReadingOrderTraversalPolicy()) ⇒ 方向键不动（只响应 Tab）
      ② Focus(onKeyEvent:) 放底栏那层 ⇒ handler 调用 0 次（兄弟节点不在祖先链）
      ③ 包住整个 FScaffold ⇒ 仍 0 次（FScaffold 内部 re-parent 焦点）
      ⇒ 换成 addEarlyKeyEventHandler（不依赖焦点树），实测 44/44
```

**⇒ 页面里没有 `Focus(` 是正确设计。**

#### 唯一建议修：`settings_page.dart:4258`（低危）

```dart
child: GestureDetector(          // ← 裸 GestureDetector：无 hover / 无按下反馈 / 无焦点态
  behavior: HitTestBehavior.opaque,
  onTap: () => onChanged(t),
  child: Center(child: Text(t.label, ...)),
),
```

**仓库自己的铁律证明它是遗漏**（`follow_page.dart:2513`）：

> 铁律 8 要求：焦点态 / 无障碍语义 / 键盘 Tab 序都要保留。
> 裸 `GestureDetector` 这三样**一个都没有**。
> ⇒ 内部走 `GlassButton.custom`，它自带 `GlassFocusRegion`

⇒ 插件页 Tab chip 应改成 `GlassButton`（或至少加 `MouseRegion` + `Focus`）。

---

## 4. 第 3 遍：能坏的

### 已实测的空数据态（✅ 通过）

早期一轮截图（隔离目录无源）已验证：

```text
✅ 首页空态：「还没有可用的内容源 / 在设置里启用或导入一个内容源即可开始」
✅ 追更空态：「还没有追更的内容 —— 在详情页点「追更」即可追踪更新」
✅ 直播空态：「没有可用的直播源 / 在设置中启用一个支持直播的内容源」
✅ 三态分离（loading 骨架 / failed+重试 / empty 引导）见 live_page.dart:2696
✅ 零 Unhandled Exception
⚠️ 但当时有一个真实缺陷：**更新弹窗盖住了所有页面**（见 §0 第 ③ 条）
   ⇒ 那是我自己的数据准备问题，不是产品缺陷
```

### 超长文本 / 断网 / 权限 —— **未逐项实测**

```text
⚠️ 未做：超长标题、超长源名、超长分组名
⚠️ 未做：断网（拔网线 / 关 WiFi 会打断本会话，改用「禁用网卡」风险太高）
⚠️ 未做：无权限（Windows 上要改 ACL，属破坏性操作）
⚠️ 未做：任务执行中退出页面（需要播放器起播 + 主动切页）
```

---

## 5. 自我纠错记录（本轮我自己犯的错）

```text
① 用 PrintWindow 抓 Flutter 窗口 ⇒ 1×1，绕了半小时
   ⇒ 仓库早有 SOURIN_SHOT 机制，我没先找

② seed 脚本的 APPDATA 语义搞错 ⇒ 32 个插件只播了 1 个
   ⇒ 前 13 张截图全是空态，还以为"页面就是空的"

③ ui-prefs 的 lastCheckAt 写成整数毫秒 ⇒ DateTime.tryParse 失败
   ⇒ 更新弹窗盖住所有截图

④ ★ 差点报「切 tab 后旧页面残留」这个假缺陷
   ⇒ burst() 在切换后 0~200ms 截图，而转场是 260ms
   ⇒ 拍到的是动画中间帧
```

**这四条里有三条是「取证工具用错」，一条是「误读取证时序」。**
⇒ 与全轮主题一致：**验证工具本身也需要验证。**

---

## 6. 未覆盖范围（明确列出，不混进「已完成」）

```text
❌ 12 个二级设置页 —— 未截到（需要逐页导航）
❌ 有数据时的追更页 / 搜索页 / 已缓存页 —— 未截到（burst 只轮了 6 个一级 tab 的前几张）
❌ 来源导入 / 可视化编排弹窗 —— 未截到
❌ 超长文本 / 断网 / 无权限 / 任务中退出
❌ 移动端（Android 手机 / TV）—— 本机只有 Windows
```

**⇒ 本轮第 6 波完成度：一级页 6 个中验了 2 个（首页有数据 / 直播空态）+ 全部页面的空态。**
**未完成 4 个一级页的有数据态、12 个二级页。**

---

## 7. 补充：播放页真机走通（第 1 遍补做）

上一节原写「播放页未截到」。后来用**方向键导航**（`PostMessage` 发 VK_RIGHT ×6 + VK_RETURN，
全程不激活窗口、不动鼠标）走通了 —— 落在播放页而不是预期的设置页，
但**正因为这样，播放页拿到了真实 UI 证据**。

### 亲眼所见（两张截图，模型直接读图）

```text
✅ 视频**真的起播了**：动画画面正常渲染（不是黑屏、不是转圈）
✅ 标题完整：「无职转生 第三季 ～到了异世界就拿出真本事～」+「第14集」
✅ 左上返回箭头在
✅ 右侧「片头 00:00-01:09 / 片尾未设」面板渲染正常，带时间轴与「预览」按钮
✅ 弹幕层在渲染（画面上有弹幕文字）
✅ 无溢出、无错位、无红屏
```

### ⚠️ 一个体验问题（记录，未改）

播放中屏幕上常驻一行：

```text
弹幕失败：弹幕服务返回 HTTP 400
```

- **不是产品缺陷**：HTTP 400 是外部弹幕服务返回的，代码把它如实显示出来是对的
  （链路见 `player_page.dart:6504` / `:6540` / `:6889`）。
- **但文案只说「失败了」，没说「怎么办」** —— 用户看到会以为播放器坏了，
  而实际上视频本身完全正常。
- 归属：属「错误文案可操作性」，非本轮范围。**记入 `round-66-issues.md` 候选。**

### 这一条的方法论价值

原计划「用 burst 自拍覆盖各页」失败（5 秒周期太慢，13 张只覆盖 2 个 tab）。
改走**键盘导航 + 手动截图**反而拿到了播放页这个最复杂的页面。
⇒ **取证工具的覆盖能力要按页面价值排序**，不要指望一个机制覆盖全部。

