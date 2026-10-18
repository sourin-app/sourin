# 第 64 轮：Owner 14 条反馈 —— 计划与实测核对

**日期**：2026-10-17
**状态**：计划（Owner 要求"先更新计划"）
**来源**：Owner 2026-10-17 10:07 逐条反馈 + Lead 实测复核

---

## 0. 这份文档怎么用

### ⚠️ 当前工作区状态（如实声明，2026-10-17 10:17）

```text
这份计划本身是【计划】，尚未按它动工。但工作区里**已经存在**两批未提交改动，
都是本轮计划之前产生的，列在下面避免误解：

Lead 改的（第 6 条 外部站弹幕，已实测+故障注入验证）：
  lib/core/bili/bili_api.dart        +209  （BiliSeason 模型 + seasonInfo + searchSeasonIds）
  lib/core/bili/bili_bind.dart       +113  （autoBindBySearch 兜底 + _autoBindViaSeason）
  test/zz_t64_bili_season_fallback_test.dart（新增，真实网络测试）

Lead 改的（第 3 条 loading 圈，仅 analyze 通过，**尚未真机验证**）：
  lib/ui/widgets/app_loading.dart    +120  （CircularProgressIndicator → 自绘 CustomPainter）

dlg-source 改的（task-31 皮肤层）：
  lib/ui/theme_bridge.dart            +48/-18
  lib/ui/theme/theme_pack.dart        +25/-6
  lib/ui/tokens.dart                  +17/-3

⇒ 若 Owner 要先看计划再动工，上面这些**已经在了**，不会自动回退。
  如需回退请明说，我可以 git checkout 还原（未 commit，随时可退）。
```


每条都是「**Owner 原话 → Lead 实测核实 → 判定 → 方案**」四段。
凡是没实测过的，一律标 ⚠️ 未验证，不许写成事实。

---

## 1. S0多域名适配 —— ⚠️ 已实现，但只做了"双域名硬编码"

**Owner 原话**：「复核一遍」

**实测**：
```text
插件侧（用户机器上）：
  %APPDATA%/app.sourin.player/plugins/s0.js 里只有两个域名：
    https://www.s0.com
    https://www.s0.org
  仓库内 docs/PLUGINS.md 里没有任何"多域名"章节。
```

**判定**：谈不上"多域名适配" —— 只是插件内写了两个备用域名，**没有**：
```text
· 域名失效自动切换（现在靠插件自己 if/else）
· 用户可增删域名
· 域名健康探测
```

**方案**：
```text
① Rust 侧 provider 增加 domain 列表能力（不是插件内硬编码）
② 每个域名独立熔断（失败 N 次降权 / 切换）
③ docs/PLUGINS.md 补「多域名」章节，给插件作者规范
⚠️ 但注意架构纪律：站点是插件提供的，宿主只提供能力 ⇒ 只做 ①② 的能力，不塞站名
```

---

## 2. 播放页右侧显示弹幕来源 + 插件决定能否发送 —— 新需求

**Owner 原话**：「在播放页面右侧显示加载了哪些弹幕,方便排查问题(要优化ui),
但是发送弹幕好像没这个功能,这个也让插件提供,我们提供好这个入口,插件源决定是否能发送」

**实测**：
```text
已有：player_page.dart:1782  String _danmakuSourceLine（但只在弹幕设置面板用）
      :5860  _danmakuSourceLine = "数据源：..."
已有：model.rs:643  Capabilities.danmaku_send: bool
      （注释原文：「真正调不调的判据始终是插件实际有没有实现 danmakuSend()」）
缺：  播放页右侧**没有**常驻的弹幕来源展示
缺：  没有"发送弹幕"的入口（UI 层没有输入框/按钮）
```

**判定**：能力字段已有（`danmaku_send`），但**入口和展示都没有**。

**方案**：
```text
① 播放页右侧加一个「弹幕信息」面板（可折叠）：
   显示 当前弹幕来源 / 条数 / 是否可发送 / 匹配方式（外部站直连 or danmaku-service or 插件）
② 该面板要**优化过 UI**（不是塞一行小字）
③ 发送入口：输入框 + 发送按钮，**仅在 plugin.capabilities.danmaku_send == true 时显示**
④ 插件契约：danmakuSend(episodeId, text, timeMs) -> {ok, id?, error?}
⑤ 宿主只做入口与结果反馈，**能不能发由插件决定**
```

---

## 3. loading 圈：锯齿 + 看不清 —— 确实没修好

**Owner 原话**：「loading圆圈有锯齿,然后那个还是看不清楚,请对比度高一点」

**实测**：`app_loading.dart` 文件头自称已改（描边 2.8、尺寸 30、颜色换掉 Colors.white）。
但 Owner 仍说看不清 ⇒ **上一轮的改法不够**。

**判定**：❌ 未解决。而且新增了一个"锯齿"问题。

**锯齿根因推测（⚠️ 未验证）**：
```text
`CircularProgressIndicator` 用 Material 默认抗锯齿 + 可能被 Transform.scale 缩放，
在非整数倍缩放下会出现锯齿。也可能是 strokeWidth 与 size 不是整数比。
```

**方案**：
```text
① 放弃 CircularProgressIndicator，改**自绘**（CustomPainter + drawArc）
   —— 这一条与第 4/8 条"去 Material"目标一致，顺路做掉
② 对比度：在真实底色上量，目标 ≥ 4.5:1（现在显然没到）
③ 抗锯齿：Paint()..isAntiAlias = true，且不用 Transform.scale
④ 必须**真机截图验证**，不许只看代码
```

---

## 4/8/9. 去 Material —— 全套替换（Owner 明确不分阶段）

**Owner 原话**：
· 「弹幕设置的弹窗还是很丑,这里我说了去掉那个什么 material ,就一起都整理了」
**· 「继续做 按照全套换掉 material去做」**
· 「点击编辑还是老样子的配置,没有可见的可视化编排,这里肯定也要用到modal,一起给换了」

**实测**：
```text
danmaku_settings_dialog.dart:64  import "package:material_ui/material_ui.dart";  ← 仍在
app_dialog_shell.dart          仍含 material_ui 引用
source_composer_dialog.dart   是"三步表单 + JSON 预览"，不是真可视化
                               （文件头原文：可视化编排器 —— 三步表单 + 实时 JSON 预览）

产品代码 import material_ui：85 / 134 个文件
测试 MaterialApp：233 个文件
```

**判定**：❌ 未完成。第 9 条更准确的问题是「**点击编辑走的是老配置表单**，
新做的 `SourceComposerDialog` 没接进编辑入口」。

**方案**（按 Owner 要求：不分阶段，A~E 一次做完）：
```text
A. 建 lib/design/ 纯 widgets 层设计系统（令牌/颜色/排版/图标映射）
B. 自建基础控件：AppIcon(148 个图标映射) / AppButton / AppSwitch / AppSlider / AppField
C. 自建主题设施：AppThemeData / AppColorScheme 取代 Theme / ThemeData / ColorScheme
D. 替换 InkWell(33) / Material(38) → 自绘按压 + 已有 press_feedback.dart
E. 替换 MaterialApp（生产 2 处 + 测试 233 处）→ WidgetsApp + AppTestHost 脚手架

⚠️ 硬阻塞：window_manager 的 7 个文件 import flutter/material
   ⇒ 已查明它只读 Theme.of、不安装 Theme，所以不是渲染阻塞，
     但会让 flutter/material 留在依赖图 ⇒ 门禁判据必须是"lib/ 源码里不出现 material import"，
     不能是"依赖图里没有 material"

⚠️ 图标是最大暗礁：148 个不同 Icons.xxx，而 Icons 类只在 material 层
   ⇒ 必须换图标体系（Lucide / 自绘 / 字体子集）

★ 第 9 条另做：把 SourceComposerDialog 接进"编辑"入口，
  并改成真正的可视化（分区块卡片 + 拖拽排序 + 实时预览），不是三步表单
```

---

## 5. 屏蔽词 —— ✅ 已解决

**Owner 原话**：「可以了」
⇒ 关闭，不再动。

---

## 6. 外部站弹幕 —— 根因已定位，继续修

**Owner 原话**：「继续修」

**实测根因**（Lead 2026-10-17 严格对照实验）：
```text
接口                                   状态
──────────────────────────────────────────
x/web-interface/search/type  (现用的)  412 ✗  无Referer/两个Referer 全 412
x/web-interface/search/all/v2          200 ✓  但 media_bangumi 返回 0 条
pgc/view/web/season?season_id=26801    200 ✓  免登录，直接给 26 集 + 每集 cid
x/web-interface/view?bvid=...          200 ✓
comment.外部站.com/<cid>.xml         200 ✓  弹幕本体
```

**完整因果链**：
```text
① 播一个「没绑定外部站」的作品
② _autoBindBili() → bili_api.dart:493 调 search/type
③ 得到 412 HTML ⇒ 解析失败 ⇒ 匹配失败
④ 降级到 danmaku-service
⑤ 无 AppId/AppSecret（String.fromEnvironment 构建期注入，默认空串）
⑥ ⇒ 403 Missing Authentication Headers  ← 用户看到的那句
```

**方案**：
```text
① bili_api.dart 的搜索层改用 pgc/view/web/season + view?bvid 这条免登录链路
② 保留 search/type 作为可选（限流解除时更快），失败自动降级
③ 加"域名/接口健康探测"，某接口 412 时标记冷却
```

---

## 7. dan-api 换掉弹弹play —— 部分已实现，但配置页看不到

**Owner 原话**：「配置页没看到,既然弹弹play不行,就换成dan-api」

**实测**：
```text
已实现（dlg-plugin 复核 + Lead 验证）：
  lib/core/danmaku.dart:1569  class DanmakuEndpoint（可配置 baseUrl + token）
  lib/core/ui_prefs.dart:248  danmakuEndpointKey = "dsh.danmaku.endpoint"
  lib/core/ui_prefs.dart:266  danmakuTokenKey
  danmaku_settings_dialog.dart:590/593/1134/1172  输入框 + probeOverride 测试按钮
  优先级：显式 > 本机 > danmu_api > 官方（danmaku.dart:1698-1703）

问题：Owner 说「配置页没看到」⇒ 入口藏太深 / 不明显 / 或默认不显示
```

**判定**：能力有，**发现性差**。

**方案**：
```text
① 把 dan-api 配置**提到显眼位置**（设置页一级，不进二级弹窗）
② 默认值改为 dan-api 优先；弹弹play 降级为"兼容旧配置"
③ 配置项：地址 + token（可选）+ 一键连通性测试 + 状态指示（在线/离线/未配置）
④ 首次使用时引导（若未配置且弹弹play 不可用，主动提示"改用 dan-api"）
```

---

## 10. 内置解析能力 + 解码播放（A 和 B 都做）

**Owner 原话**：「按照刚才说的 ab都做,内置解析能力 和 解码播放(这里插件也要更新吧?)」

**(a) 取流/解析层**：
```text
我们自己的代码把目标站的真实播放地址解出来，不经第三方解析站。
（具体是哪些站在本仓**不许写进文档**，见 test/t98_no_site_names_test.dart）
现仓没有：model.rs 里搜不到 parses/decoder 相关结构
```

**(b) 解码层**：
```text
拿到地址后，这些站的流（编码/封装）本仓播放器解不了的，要内置新的解码能力。
⚠️ 具体缺哪几种解码（H.265? AV1? fMP4? DRM?）**未侦察** ⇒ 待核实，不许猜
```

**插件也要更新（Owner 问到点上了）**：
```text
现在的插件契约 play({id, episodeId}) → [{url, label}] 假设插件给的是【可播地址】。
但爱优腾这类站的插件根本拿不到可播地址（要签名/DRM）⇒ 必须扩展契约：
  · 插件返回「播放页 URL + 站点标识」而不是可播地址
  · 宿主负责内置解析（a）与解码（b）
  · capabilities 加：needsHostResolve: bool / needsHostDecode: bool
```

**★ Owner 2026-10-17 确认站点名单**（原话含站名，此处按 t98 门禁改代号）
```text
最终名单 = 四个站（S1 S1系 / S2 S2系 / S3 S3系 / S4 S4系）
⚠️ **站名不得写进仓库** —— test/t98_no_site_names_test.dart 会红。
   代号与真名的对照只存在于 .probe/（gitignore + t98 跳过）。
```

---

## 11. 主题：继续优化 + 更多主题 + 双色主题 + 预览 + 液态玻璃滑动指示器

**Owner 原话**：
· 「主题倒是好多了,优化了不少,接下来我希望继续优化+更多主题」
· 「我希望加上**双色主题**,就是**还是跟随**,但是是**两种规范主题**的,而且都要加上**预览**,这样子方便用户挑选」
· 「我看其他实现液态玻璃下面那个 点下去的时候,那个液态玻璃的选中是可以**跟随左右移动**的,我们也要加上」

**实测现状**：
```text
现有 10 套内置主题：
  builtin.dark / daylight / forest / glass / midnight
  / midnightBlue / minimal / neoBrutal / oled / sakura

已有预览机制（theme_page.dart:21-25 文件头原文）：
  「每张卡片都带一个小预览…预览用的是主题自己的调色板真色，
    所以卡片看起来什么样，切过去就是什么样 —— 不会预览与实物不符」
  ⇒ 预览基建【已有】，新主题直接复用即可

tab 选中态（my_shelf.dart:557）：
  if (t != _tab) setState(() => _tab = t);   ← 瞬间切换，无动画无指示器
  ⇒ 没有"跟随左右移动"的滑块
```

---

### 11-A 双色主题 —— ★ Owner 已确认语义（2026-10-17）

**Owner 选项原话**：「一个主题同时提供浅色版和深色版两个独立风格」

**★ 实测现状（这是本项的真实起点）**：
```text
内置 10 套主题里，**8 套是纯深色，只有 2 套是浅色**：

  浅色（_light）：  builtin.daylight（日间）  + 1 套（:847 那条）
  深色（_dark）：   builtin.midnight / oled / midnightBlue / sakura / forest
                 + :829 / :838 两条

⇒ 也就是说：现在选「樱粉」，系统切浅色后**没有对应的浅色版**，
   只能整站变深或回落。这正是 Owner 说的「双色主题」要补的缺口。
```

**Owner 要的到底是什么（已确认）**：
```text
不是「浅色用主题A、深色用主题B」（我最初的误解），
而是：**每一套主题都要同时有「浅色版」和「深色版」两个独立设计**，
    跟随系统切换时，用的是同一个主题的对应版本。

例：选「樱粉」⇒ 系统浅色时用「樱粉·浅」，系统深色时用「樱粉·深」，
    两者是同一设计语言的两个变体，不是两套无关主题。
```

**这意味着的工作量**：
```text
现有 8 套深色主题，每一套都要【新设计一个浅色版】：
  · 不能简单反色 —— 浅色下要重做全部层级方向（越高越白 vs 越高越亮）
  · 每套浅色版都要过对比度实测（正文/次要/描边/凹陷/浮起）
  · 每套要能被预览卡正确渲染

⇒ 共需新增 8 个浅色变体（有的深色主题可能本就是为深色而设计，
  要给它们合理的浅色对应，而不是生硬反转）。
```

**数据结构改造**：
```text
现在 ThemePack 有单一 `brightness` 字段（:63），一个包只对应一档明暗。
要支持「一套主题两个版本」，需要二选一：

方案 1（推荐）：一个 ThemePack 内嵌 light/dark 两份 AppPalette
  · pack.paletteFor(Brightness) 取值
  · 优点：用户概念上仍是"10 套主题"，逻辑简单
  · 缺点：要改 ThemePack 结构 + 所有读取 palette 的地方

方案 2：主题成对注册，共享 familyId
  · builtin.sakura.light / builtin.sakura.dark，同 familyId="sakura"
  · 优点：改动小，向后兼容好
  · 缺点：偏好里要存 familyId 而不是 pack id

⚠️ 这个选择要等 A~E 去 Material 的结构定型后再定（ThemePack 会一起改）
```

**兼容性**：
```text
· 老用户只存了一个 themeId ⇒ 自动映射到同 family 的明/暗两版
· 只有单版本的第三方导入主题 ⇒ 另一档回落（要给明确提示，不许静默）
```

---

### 11-B 主题预览（每个主题都要能被挑）

**现状**：`theme_page.dart` 已有小预览卡。

**要补的**：
```text
① 双色主题的两个槽位（浅色用/深色用）都要能预览
② 预览要能看出「是哪一类风格」，不只是几个色块
   建议：预览卡模拟一个真实小界面（标题栏 + 一张海报 + 一个胶囊按钮），
        而不是只排几个色圆点
③ 新增主题越多，越需要"按风格分组"或"筛选"
```

---

### 11-C 液态玻璃 tab 滑动指示器 —— ★ 实测：**已经实现了**，问题是手感

**Owner 原话**：「我看其他实现液态玻璃下面那个 点下去的时候,那个液态玻璃的选中是可以跟随 左右移动的,我们也要加上」

**★ Lead 实测结论（2026-10-17）：滑块**早就存在**，不需要"加"，需要"调"**

```text
lib/ui/widgets/my_shelf.dart:2191   AnimatedPositioned(
  duration: Motion.slow,            // 420ms
  curve: Curves.easeOutBack,
  left: current.index * tabWidth,
  width: tabWidth, ...
)

lib/shell.dart:7138                AnimatedPositioned(   ← 底栏同样有
  duration: Duration(milliseconds: 420),
  curve: Curves.easeOutBack,
  left: _pillLeft(current, tabWidth), ...
)
```

⇒ 代码里注释还写着：
   「`easeOutBack` 会**轻微过冲**再回弹，那就是"液态"手感」
   「原版 CSS: transition: transform var(--dur-slow) var(--ease-spring)」

**⚠️ 那 Owner 为什么说"要加上"？我的推断（未验证）：**
```text
① 420ms 太长 —— iOS 分段控件 / 液态玻璃的选中移动通常在 250~300ms。
   420ms 会有明显的"慢半拍"感，不像在跟随手指/点击。
② easeOutBack 的过冲在后半段才显现，快速连点时会被打断，看起来像"没动"。
③ 也可能是某个具体页面的 tab 没走这个组件。
```

**要做的（等 Owner 确认现象后再动手，避免白改）**：
```text
① 时长：420ms → 约 260~280ms（Motion.base 是 260ms）
② 曲线：easeOutBack → 更接近真实液态玻璃的 spring 阻尼
   本仓 tokens.dart:188 已有 `Motion.spring = Cubic(0.34, 1.56, 0.64, 1)`
③ ⚠️ 必须先复现 Owner 看到的现象，再改 —— 不能凭推测调参数
```

**❓ 需要 Owner 确认**：你说的"要加上"，是指
```text
(a) 你根本没看到有滑动（完全没动）→ 那是 bug，要查为什么没生效
(b) 看到有滑动但太慢/不跟手 → 调时长与曲线
(c) 看到的是别的地方（比如播放页/直播页的 tab），不是首页这两个
```

---

### 11-D 继续优化现有 10 套

```text
· 每套逐一量对比度（正文/次要文字/描边/凹陷/浮起）
· 统一圆角阶梯（现在 Radii 是 8/12/16/22/28/34，但默认值是野值 10 → 已由 dlg-source 改 14）
· 深色主题与浅色主题的「抬升方向」要一致（浅色越高越白，深色越高越亮）
```

---

### 11-E 新增主题建议方向

```text
高对比无障碍 / 琥珀暖色 / 青碧 / 石墨灰 / 纸感米色 / 北欧极简
（具体由实现者提，须带：主色/背景/文字三组对比度实测值）
```

---

### ✅ 之前待确认的两点，Owner 已答复（2026-10-17）

```text
① 11-A 双色主题 = 「一个主题同时提供浅色版和深色版两个独立风格」  ✔ 已定
② 11-C 滑动指示器 = 「只要选中块平滑移动，tab 仍靠点击切换」    ✔ 已定
```

---

## 12. 直播页：分类+源挤成一片；自定义分组未实现

**Owner 原话**：「你自己看看实现的合理吗?分类+源 把列表都挤得看不到了,
而且我说的自定义分组也还没实现」

**实测**：
```text
live_page.dart:2618-2635  存在「全部分组」+ 每组的 _FilterChip 横排
   ⇒ 分组多时 Wrap 会占掉好几行，把下面的源列表挤下去  ← Owner 说的现象确认

lib/core/models.dart:1310  class LiveGroup  存在
lib/ui/settings/live_groups_page.dart (8.2KB) 存在 —— 能建组/改组

**★ Owner 2026-10-17 明确回答**：
"自定义分组有了,但是配置的地方没有 a 我选择a,然后布局非常的不合理"
```text
⇒ 分组 CRUD 功能【能用】，问题在两处：
   ① 配置入口不在直播页（要跳 设置 → 直播分组）⇒ Owner 选 (a)：入口提到直播页内
   ② 直播页布局【非常不合理】⇒ 不只是"挤"，是整个排布要重做
```

**方案**（按 Owner 选 a + "布局非常不合理"）：
```text
① 布局重做（Owner 说"非常不合理"，不是小修）：
   · 分类/分组不再横排堆 Wrap（现在组多时占好几行，把源列表挤没）
   · 改为「左侧竖排分类栏 + 右侧源列表」或「顶部单行下拉 + 源列表」
   · 目标：一屏能看到的源数量 ≥ 现在的一倍
   · 必须真机截图验证"一屏看到几个源"

② 建组/改组入口【提到直播页内】（Owner 选 a）
   · 直播页内直接可建组、改名、删组、把源归组
   · 不必再跳 设置 → 直播分组
   · 设置页那个入口保留（不破坏现有习惯），但变成次要入口

③ 分组 chip 与源列表必须是【两个独立区域】，不许互相挤压
```

---

## 13. 追更第14集播第1集 —— ✅ 已解决

**Owner 原话**：「确实修了,我今天试了」
⇒ 关闭。

---

## 14. 三套完全不同的 UI 风格 —— 交给子代理，Owner 亲自审查

**Owner 原话**：「让子代理去跑实现,出来结果就给我,我来审查」

**当前状态**：
```text
dlg-source 在做（task-31），已批准把 theme_bridge.dart 加进范围。
它已量化出"丑"的真正原因（不是审美，是四个可量化缺陷）：
  底栏与页面底色对比度 = 1.000（完全看不见）
  切换条凹槽 1.096 / 源条凹槽 1.047 / 标题栏 1.051
  全屏品牌色 #3B6FE0 只出现 2 个像素
  圆角不成体系（头像16 / 海报16 / 凹槽胶囊 / 底栏胶囊 混着）
```

**要求**：产出后**直接给 Owner 审查**，Lead 不代判。

---

## 附：执行进展（2026-10-17 11:00 快照）

### 已验收通过（Lead 独立复核，非仅采信汇报）

```text
6  外部站弹幕 season 兜底
   ├ 真实网络：season 26801 → 26 集 cid；cid → XML 617100B → 7200 条
   ├ 故障注入：接口路径改错 ⇒ 测试立刻红
   ├ 真机构建：app.so = 11,322,248 B（产品非 spike）
   └ ★ dlg-bili 纠正：真实网络 search/type 其实 200（mobile UA），
       所以 season 是**备用路径**不是主路径。且发现第二条出口漏洞，已修。

31 皮肤层（三层浮起物）
   ├ Lead 自写 PNG 解码器独立测量 CR：
   │   顶部 1.034→1.197 / 源条 1.047→1.244 / 底栏 1.176→1.384（全部 ≥1.15）
   ├ 布局逐像素自证：4 个 bbox 完全一致
   └ ★ 根因是包自带浅色 glassColor 仅 12% alpha；改全局 GlassThemeData 一处管三块

32 播放页弹幕来源面板 + 探针真机验证
   ├ 面板四项事实：来源 / 条数 / 匹配方式 / 失败原因（原文照透）
   ├ 「未查询」不撒谎成 0；season 兜底有橙色「备用链路」标
   ├ 探针不进发布构建有客观判据：3.77MB vs 10.80MB
   └ ★ 自己抓到 cid 显示两遍（单测不会红，只有看图能发现）

33 解析+解码契约（两端打通）
   ├ Rust 三字段 + StreamFlags + serde default&skip
   ├ 条件3 的测试抓住它自己的 bug（Lead 故障注入复现，仅 1 条红）
   ├ Rust 全量 508 passed / 0 failed / 60 ignored
   └ ★ 解析器未实现（无真实样本，不猜）；DRM 架构上不支持，如实提示

34 直播页布局重做
   ├ Lead 独立测行距：before 49.3px → after 36.0px
   ├ Wrap 4 处 → 2 处，新增 _FilterBar 固定 36px
   └ ★ 曾交错 before 图（两张一样），Lead 逐像素发现；已用 T64_SHOT 环境变量修
```

### 进行中

```text
7  dan-api 提到设置一级（dlg-provider 在做，已建 danmaku_source_page.dart）
4/8/9 全量去 Material（Lead 在建设计系统底座）
```

### 去 Material 底座进展（Lead 本人）

```text
已完成：
  lib/design/theme/app_theme_data.dart   AppThemeData 取代 ThemeData/ColorScheme
  lib/design/theme/app_theme.dart        AppTheme.of 取代 Theme.of
  lib/design/icons/app_icons.dart        AppIcons 取代 Icons（158 个逐个同码）
  lib/design/widgets/app_ink_well.dart   AppInkWell 取代 InkWell(49)
  lib/design/widgets/app_text_button.dart AppTextButton 取代 TextButton(37)
  lib/design/widgets/app_icon_button.dart AppIconButton 取代 IconButton(28)
                                            + AppSurface 取代 Material(62)

★ 关键发现（消除了最大风险）：
  Icons 只是 IconData 常量表，而 IconData 类在 flutter/widgets（不属 Material）
  ⇒ 可生成 AppIcons 保留全部图标外观，**视觉零变化**

★ 另一个发现：
  Material 的 62 处用法是两件事，必须分开处理：
    ① 给 InkWell 提供水波层 ⇒ **直接删外壳即可**（AppInkWell 自绘）
    ② 真当有色卡片用   ⇒ 换 AppSurface
  迁移前必须逐处分类，不能一律替换

待做：AppTooltip(17) / AppTextField(28) / AppSwitch(15) / AppSlider(8)
      / AppDivider(8) / AppScaffold(29) / 测试侧 MaterialApp(233)
```

---

## 附：本轮优先级建议

```text
P0（阻塞用户 / Owner 明确要）：
   6 外部站弹幕（已完成，待你验） · 4/8/9 去Material全量 · 3 loading圈

P1（新功能 / 明确缺陷）：
   2 弹幕来源面板+发送入口 · 7 dan-api提到一级 · 12 直播布局重做
   11-C 液态玻璃 tab 滑动指示器

P2（能力建设）：
   11-A 双色主题 · 11-B 主题预览改造 · 11-D 现有主题精修
   10 内置解析+解码（四站 + 插件契约）· 1 多域名池

P3（交给子代理）：
   14 UI 风格（dlg-source 进行中，已授权改 shell.dart / my_shelf.dart）

说明：11-C 我放 P1 是因为它小、可见、Owner 明确点名要；
      11-A 双色主题放 P2 是因为它牵动偏好结构（有兼容成本）。
```

---

## 附：本计划中「未验证」的项（不许当成结论）

```text
⚠️ 第 3 条"锯齿"的确切成因（推测是缩放或描边非整数比，未验证）
⚠️ 第 10 条 (b) 具体缺哪几种解码格式（未侦察）
⚠️ 第 12 条"自定义分组未实现"的确切含义（入口深 or 功能坏，未核实）
~~第 1 条"多域名适配"要做到什么程度~~ ⇒ **Owner 2026-10-17 已确认：就是"对的"**，
   即宿主统一管理域名池 + 自动切换（见 §1 方案 ①②）
```
