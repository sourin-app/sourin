# 第 65 轮：问题记录

> **用途**：Owner 2026-10-17 指示「中途如果有问题，就写到一个文档里面，我明天早上会看的，
> 你记录下来不要影响工作的推进，大部分问题，你按照最优解就行了」。
>
> **纪律**：
> ```text
> ① 遇到问题**先按最优解继续推进**，不阻塞；把问题写进来，等 Owner 早上看。
> ② 只有「物理做不到 / 破坏性且不可逆 / 涉及钱或对外发布 / 两种做法代价相当且无法实测区分」
>    才停下来问 —— 其余一律自主决策并记录。
> ③ 每条都写：发现了什么 / 我的判断 / 我选了哪个方案 / 为什么 / 如果 Owner 不同意怎么回退。
> ④ 已解决的问题也留在本文（标 ✅），因为「怎么解决的」同样值得回看。
> ```

**配套计划**：[plan-round-65.md](plan-round-65.md)
**开始时间**：2026-10-17 23:45
**最后更新**：2026-10-17 23:45

---

## 状态图例

| 标记 | 含义 |
|---|---|
| 🔴 | 需 Owner 决策（我按最优解先做了，但可能需要改） |
| 🟡 | 已自主决策并推进，记录备查 |
| ✅ | 已解决 |
| ⚠️ | 未验证，仅记录现象 |

---

## 问题清单

（随工作推进追加，最新在上）

---

## 2026-10-17 23:5x —— 批次 A：插件私有仓（已完成，2 条记录）

### ✅ A-1：`D:\WishProject\sourin-plugins` 已被**上游示例仓**占用，本地改用 `sourin-plugins-user`

**发现**：按计划把本地仓建在同级 `D:\WishProject\sourin-plugins` 时，该目录**已存在**
且不是空目录 —— 它是一个已有的 git 仓库，remote 指向
`https://github.com/sourin-app/sourin-plugins.git`，内容是官方「插件写法示例」
（TypeScript 示例 + 构建脚本 + node_modules），与 Owner 的本地插件**毫无关系**。

**判断**：若直接在该目录初始化/推送，会污染甚至覆盖上游示例仓的 git 历史；
而且我们的 `origin` 是 `iuuuuuuuu/sourin-plugins`，与该目录现有 origin 冲突。

**决策**：**不碰**那个目录，本地仓改建在 `D:\WishProject\sourin-plugins-user`。
GitHub 上的仓库名仍是 `sourin-plugins`（在 `iuuuuuuuu` 账号下，与
`sourin-app/sourin-plugins` 是**不同 owner 的两个仓库**，不冲突）。
```text
GitHub 仓库  https://github.com/iuuuuuuuu/sourin-plugins   ← 新建的私库
本地克隆     D:\WishProject\sourin-plugins-user            ← 用这个
被让开的目录 D:\WishProject\sourin-plugins                 ← 上游示例仓，未改动
```

**若 Owner 不同意**：想让本地目录也叫 `sourin-plugins`，需要先把现有那个示例仓
挪走或删掉 —— 那是破坏性操作，我没做。回退成本 = `git clone` 到任意路径，极低。

---

### 🟡 A-2：`.bak-*` 备份实为 **3 个**，计划写的是 4 个

**发现**：`plan-round-65.md` 批次 A 写「含 4 个 `.bak-*`」，实测
`%APPDATA%\app.sourin.player\plugins\` 下只有 **3 个**：
```text
<源名>.js.bak-coverfix-20261001-182800
<源名>.js.bak-dedup-20261012-074706
<源名>.js.bak-prev
```
（`find . -name '*.bak*'` 递归查过，无第 4 个。）

> ⚠️ 这里**不写具体源名**：本文件在仓库内，会被 `t98` 站名门禁扫描。
> 具体文件名见私有仓 `iuuuuuuuu/sourin-plugins` 的实际文件清单。
> 上一版我把三个真实文件名照抄进来，`t98` 立刻变红 —— 已改回中性占位。

**判断**：不是漏拷 —— 源目录本来就只有 3 个。计划里的「4」是估计值写实了。

**决策**：按**实际存在的全部文件**入库，即 32 个 `.js` + 3 个 `.bak-*` = 35 个。
入库后逐文件 sha256 与源目录比对，**35/35 一致**（见下方读数）。

**若 Owner 不同意**：若确有第 4 个备份在别处（比如旧目录 / 回收站），
告诉我路径，补一个 commit 即可。

---

### 批次 A 完成读数（2026-10-17）

```text
仓库 URL    https://github.com/iuuuuuuuu/sourin-plugins
私有状态    isPrivate=true  visibility=PRIVATE
            佐证（绕开 API 限流）：匿名 raw 访问本仓 404、公开仓对照 200
            佐证：匿名 git ls-remote 要求密码，公开仓对照成功

文件数      本地 32 .js + 3 .bak = 35
            远端 32 .js + 3 .bak = 35（git/trees API 从服务端读回）
            远端 blob 合计 38（含 .gitignore / .gitattributes / README.md）
内容一致    38/38 blob SHA 本地 == 服务端
            commit 一致：本地 HEAD == origin/main == 8208ed2

隐私扫描    git grep HEAD（已提交树）：
            iuuuuuuuu 0 命中 / WishProject 0 命中 / C:\Users 0 命中
            扩展：app.sourin.player / APPDATA / sourin-flutter-spike 均 0 命中
            服务端复核：从 GitHub 全新 clone 后 grep，全部 0 命中

排除项      .data/ / *.local.json / sync-settings.json / remote-pref.json
            用真实文件试排除，git check-ignore -v 四项全部命中；
            服务端 tree 列表确认这四类**不在**仓库里
```

**过程中自行处置**：README 初稿里我写了 `C:\Users\...`、`%APPDATA%\...`、
主仓名作为「举例」，被自己的隐私扫描判为命中。按「门禁不许有例外」的原则
改写了措辞（不再出现这些字面量），而不是给扫描加白名单。

---

## 2026-10-17 23:45 —— 开工前

### 🟡 P0-1：工作区此前有大量未提交改动，现已为 0

**发现**：本轮开工前 `git status` 显示 0 项未提交，但上一轮对话里提到过 5 个 commit
已提交。核对后确认工作区干净，无遗留。

**判断**：无问题，正常开工。

**决策**：直接开始。

---

### 🟡 P0-2：`material_ui` 移除的最大障碍是 `Icons`

**发现**：`Icons.*` 用了 **163 处、分布在 63 个文件**，而 `Icons` 类**正是
`material_ui` 包导出的**。移除 `material_ui` 后这 163 处会全部编译失败。

**判断**：这是批次 E 的真正工作量所在，不是「换个包」那么简单。计划里已把它列为
E2（删包前置条件），但需要明确替代方案。

**决策**：用 `forui_lucide`（已在 pub 缓存，Material-free，Lucide 图标集）。
理由：
```text
· Lucide 是通用线性图标集，与 liquid_glass 的极简玻璃风格一致
· 它是纯 Dart 常量类，零运行时依赖，不会重新拖进 Material
· 已在缓存里，不新增下载
```

**风险**：Lucide 的图标命名与 Material Icons 不同，163 处需要逐一映射；
部分 Material 专有图标（如 `Icons.android`）Lucide 可能没有。

**若 Owner 不同意**：可以改用 `material_symbols_icons`（Google 官方图标集，
但可能依赖 Material 主题）；或用 SVG 自建。届时回退成本 = 重做 E2。

---

### 🟡 P0-3：发版 workflow 缺 `--prerelease`，本轮要修

**发现**：`.github/workflows/build.yml:1435` 的 `gh release create` **没有
`--prerelease` 参数**，而 `v1.4.0-rc1` 在 GitHub 上标记为 Pre-release ——
说明上次是手工补的标记。

**判断**：这是流程缺口。预测试版本若不标 Pre-release，会被用户当成正式版下载，
且不会出现在「Latest」之外的语义里。

**决策**：G4 里补上，规则为「tag 含 `-rc` / `-beta` / `-alpha` 时自动加
`--prerelease`」，并加一条校验（发版后从服务端读回 `isPrerelease` 字段核对）。

**若 Owner 不同意**：保持手工标记，但那样每次发 rc 都要记得补。

---

## 2026-10-18 —— 批次 E 推进中

### 🔴 P1-1：E3「移除 MaterialApp」不是换包，是要重写 App 根

**发现**（实测，不是推测）：

```text
全仓真正构造 MaterialApp 的**产品代码只有 1 处**：lib/shell.dart:1930。
其余 27 个文件只是 import 了 material_ui，并没有构造它。

但这个 MaterialApp 承担了 6 项**非它不可**的职责：
  ① navigatorKey: AppTray.navigatorKey   ← 托盘关闭确认弹窗依赖「根 Navigator 永远存在」
  ② scrollBehavior: _SourinScrollBehavior ← 修 arm64 白屏的全局兜底
     该类 extends MaterialScrollBehavior（Material 的东西）
  ③ localizationsDelegates: GlobalMaterialLocalizations.delegates（Material 的）
  ④ supportedLocales: zh_CN / en_US
  ⑤ theme: materialTheme                  ← 见下方说明，这项**本来就要去掉**
  ⑥ builder: 自绘标题栏 + TextScale + 地板色（挂在 Navigator 之外）
```

**判断**：`MaterialApp` 内部就是 `WidgetsApp` 的包装（已核实
`material_ui-1.6.0/lib/src/app.dart:1053`）。理论上可换成 `WidgetsApp`，
但 ③ 的 `GlobalMaterialLocalizations` 与 ② 的 `MaterialScrollBehavior`
都是 Material 的类，换根时必须一并替换。

**决策（按最优解，先做但记录）**：
```text
· 换根目标定为 WidgetsApp（Flutter SDK 自带，非 Material）
· scrollBehavior 改为继承 ScrollBehavior（SDK 的），保留「最外层裁剪降级」那段逻辑
· localizationsDelegates 用 GlobalWidgetsLocalizations + 自定义中文文案
· theme 那一项**直接删掉** —— 它存在的唯一理由就是给 Material 组件兜底，
  组件全换 Glass 之后没有消费者
· builder 原样保留（它本来就在 Navigator 之外，与 Material 无关）
```

**风险（这是本轮最大的一处）**：
```text
arm64 白屏那条结论是 18/18 实测归纳出来的，靠的是「最外层裁剪」规则。
换根会改变从根到内容的 widget 路径 —— 如果新的根引入了新的最外层裁剪，
白屏可能复发。而**我没有 arm64 真机可验**（只有 Windows）。
⇒ 处理：换根后必须用 Windows 实测 + 保留原有注释与判据；
   arm64 无法验证的部分在 PR 描述里**明确标注未验证**，不谎称验过。
```

**若 Owner 不同意换 WidgetsApp**：退路是保留 MaterialApp 但不再 import
其余 Material 组件 —— 那样 `material_ui` 包仍在依赖里，**第 15 条不算完成**。
所以这不是偏好问题，是「要不要真做完」的问题。

---

### 🟡 P1-2：`AppIcons` 早就写好了，但零个文件用它

**发现**：`lib/design/icons/app_icons.dart` 里已经躺了 159 个 `IconData` 常量
（从 material_ui 逐码抄出，引用 MaterialIcons **字体资源**而非组件库），
注释里写着「摘掉 material_ui 后图标照样显示」—— 但 `grep -rl "AppIcons\." lib/`
的结果是**零个文件**。

**判断**：又一处「写了没接线」。上一轮做去 Material 时把图标表建好了，
但替换调用点那一步没做。

**决策**：E2 已补 2 个缺失图标并完成 59 个文件的替换，
`flutter analyze` 与 HEAD 基线逐条一致（396 issues，无新增），视觉零变化。

**这条值得记住**：建了基础设施 ≠ 用上了。判据是「有没有调用点」。

---

### 🔴 P1-3：E3 的真实成本比计划估计的大，我改变了执行顺序

**发现**：继续深挖 `shell.dart:1930` 那处 `MaterialApp` 后，发现
`materialTheme`（`ThemeData`，Material 的类型）不只喂给 `MaterialApp.theme`，
还在 `builder` 里通过 `AppThemeHost(data: materialTheme)` 向下提供
（`shell.dart:2096`）。

**判断**：
```text
「移除 material_ui」不是「把 MaterialApp 换成 WidgetsApp」这一个动作。
它是一条链：
  MaterialApp.theme          → 删除（没有消费者）
  AppThemeHost(materialTheme)→ 这一层喂的是 Material ThemeData，
                               而当前所有页面/控件都在读 Theme.of(context)
                               （实测 Theme 出现 237 次）
  ⇒ 必须先把那 237 处读取迁到 Glass 主题体系，才能删掉 AppThemeHost，
    才能删掉 materialTheme，才能删掉 material_ui 依赖。
```

**决策（按最优解，调整执行顺序）**：

原计划 E3（换根）→ E4（控件）。实际依赖关系相反：
```text
E3' 先做「控件与主题读取迁移」（原 E4 的前半）
    因为 Theme.of(context) 237 处是 materialTheme 的消费者，
    不先迁走，换根时这层没法删
E4' 再做「换根」（原 E3）
    此时 materialTheme 已无消费者，WidgetsApp 的 color 参数随便给
E5  删依赖、跑 analyze
```

**为什么不硬按原顺序**：硬按 E3→E4 的话，换根后 `AppThemeHost` 还得留着喂
Material 主题给尚未迁移的 237 处 `Theme.of` —— 那就变成「换了根但什么都没删」，
自欺欺人。

**风险未变**：arm64 白屏的 18/18 结论依赖「最外层裁剪」规则，换根会改变
从根到内容的 widget 路径。**我没有 arm64 真机**，这部分只能标注未验证。

---

### 🟡 P1-4：这一批的工作量超出「一轮做完」的合理范围

**发现**：E3'（迁移 237 处 `Theme.of` + 149 处 TextButton + 150 处 InkWell +
83 处 TextField + 79 处 Scaffold 等）是一次**全仓 UI 重写**，
不是一次批次内的小任务。

**判断**：如果硬塞进本轮和其余 6 个批次一起交付，质量会崩 ——
本仓已有教训：「攒批 ⇒ 评审者一次看几千行、二分定位不了」。

**决策**：
```text
① 本轮**不追求**「一次性把 material_ui 删掉」。
② 先交付 A/B/C/D/F/G（都是功能与修复，用户直接受益），
   把 E（UI 重写）作为**独立的后续批次**，按页面分批替换、每批可验证。
③ 这条要在最终汇报里**明说**：第 15 条本轮未完成，不是忘了，是刻意排后。
```

**若 Owner 不同意**：我可以硬做，但需要接受「一轮内改 130+ 文件、
无法逐屏验证」的代价 —— 那与本轮「自己亲眼所见」的验收要求直接冲突。

---

### 🔴 P1-5：`AppPalette` 与 `ColorScheme` 的角色语义**不同**，不能直接映射

**发现**（被自己的测试抓到，不是推测）：

我写了 `AppColors` 门面，假设 `AppPalette` 的字段能一一对应
`ColorScheme` 的 10 个角色。写了逐色相等测试后**立刻变红**：

```text
dark  primary:  ColorScheme = #3B6FE0（品牌蓝）  AppPalette = #E5E5E5（中性灰）
light primary:  ColorScheme = #3B6FE0（品牌蓝）  AppPalette = #171717（近黑）
```

根因（读 `theme_bridge.dart` 得到）：
```text
浅色分支：primary: LightTokens.brand   ← #3B6FE0，品牌色
深色分支：primary: c.primary           ← AppPalette 的 primary
⇒ **两条分支的 primary 来源本来就不同**，这是既有实现，不是 bug。
```

**判断**：`AppPalette` 是「中性色板」（黑白灰），`ColorScheme` 是
「语义色板」（含品牌色）。它们是**两层不同的东西**，把后者硬映射到前者
会改变观感 —— 而「观感零变化」是本批次的前提。

**决策（改变方案）**：
```text
① 删除 AppColors 门面与那个测试 —— 假设不成立，留着是隐患。
② 移除 material_ui 的路径改为：**不替换 ColorScheme，而是让
   buildMaterialTheme() 继续存在但不再依赖 material_ui 的 ThemeData**。
   具体做法留到 E 批次真正执行时定（需要先确认 ThemeData 能否
   在不 import material_ui 的情况下构造 —— 它就在 material_ui 里，
   所以答案是**不能**）。
③ ⇒ 结论：**第 15 条（移除 material_ui）在本轮不可完成**，
   因为它需要先自建一套完整主题体系替代 ThemeData/ColorScheme，
   那是比「换控件」大得多的工程。
```

**这是本轮最重要的一个否定结果**。我原本在计划里写「131 个文件、
可在一轮内做完」，实测证明那个估计**过于乐观**：真正的阻塞不是
控件数量，而是 `ThemeData` / `ColorScheme` 本身就在 material_ui 包里，
而全仓 172 处依赖它。

**若 Owner 要求必须做完**：可行路径是自建 `SourinTheme` 数据类
（含 ColorScheme 那 10 个角色的等价物）+ 自建 `Theme.of` 等价物，
然后把 172 处调用点迁过去。工作量约等于重做一次主题系统，
且需要逐屏验证观感 —— 不适合塞进本轮。

---

## 2026-10-18 —— 我自己完成的条目

### ✅ P2-1：第 16 条（主题深浅色）**机制早就实现了**，缺的是门禁

**发现**：`lib/ui/app_theme.dart` 的 `themeFor()` 已经完整实现了 Owner 要的语义：
```text
双档家族 + 跟随系统 ⇒ siblingOf 找对面那一档（自动切换）
单档家族          ⇒ siblingOf 返回 null ⇒ 用原包（不自动切换）
单选黑/白         ⇒ 同样走 siblingOf 挑对应版本
```
注释里甚至写明了这修的是「11-A 补的 8 个浅色版在跟随系统路径上一次都不会被用到」。

**判断**：不需要改代码。但**必须补门禁** —— 这条路径曾经完全失效过，
而当时的测试只断言「能拿到一个主题」（恒真），所以没抓到。

**决策**：新增 5 条断言，钉住「具体是哪一版」而不是「非空」。
故障注入验证：把 `siblingOf` 改成忽略明暗 ⇒ 4 条变红；恢复后 5/5 绿。

---

### ✅ P2-2：第 17 条（进度条拖动卡顿）根因是**自己把播放器打爆了**

**发现**：
```dart
// 改前
onHorizontalDragUpdate: (d) => onSeek(at(d.localPosition.dx)),
```
拖动时**每一个 pointer move** 都直接 seek。一次 2 秒的拖动 ≈ 上百次 seek，
每次都走 mpv seek + 重新解包解码，宿主还会 setState 整条底栏。
⇒ 「卡顿」不是渲染慢。

**决策**：`PlayerProgressSlider` 改为 StatefulWidget，持 `_dragMs`：
拖动中只更新预览（零 I/O），松手才 seek 一次。单击行为不变。
seek 次数从「每次移动」降到「每次拖动 1 次」。

**顺带**：`t27` 里 3 处源码级断言钉的是裸名（`key: thumbKey`），
改成 StatefulWidget 后 State 里访问静态成员必须带类名 ⇒ 断言同步改为全名。
判据强度未降低。

**故障注入**：改回逐帧 seek ⇒ 「一次拖动只 1 次 seek」立刻变红。

---

### 🟡 P2-3：第 18 条（主题预览与内置主题重设计）**未做**

**说明**：这是纯视觉设计工作（Owner 说「主题的预览也很丑,你设计的主题也很丑」）。
本轮我优先保证了功能性条目（错误信息、直播、弹幕、数据管理），
第 18 条需要**设计能力 + 逐版截图比对**，我没有把它塞进这一轮赶工。

**为什么不在本轮硬做**：设计类改动如果我自己看不出「好看」，做出来大概率还是丑。
本轮先交付能客观验证的部分，第 18 条留给有明确设计参照时再做。

---

### 🟡 P2-4：第 12 条（弹窗难看）**部分做**，第 13 条已完成

**第 13 条（删布局骨架）✅ 已完成**：
删除 `side_rail_layout.dart`（214 行）+ `top_bar_layout.dart`（309 行），
`_currentLayout()` 固定返回底栏式，设置页的选择器一并移除。净减 602 行。

**第 12 条（弹窗难看）⚠️ 未做**：
`docs/AGENTS.md` §3.5 已规定「所有弹窗必须走 AppDialogShell」，
但 Owner 仍觉得难看。这说明**规范存在但样式本身不够好**，需要重新设计外壳视觉，
不是「没走规范」。本轮未做，理由同 P2-3（设计类）。

---

## 批次 D（live-ux）：直播页分组/搜索/冷启动

### ✅ 已修（有判据 + 故障注入）

**P0-A：分组模型错误（Owner：「选择直播源，而不是直播源下的具体房间，这是错误的」）**

改前 `live_source_groups` 存的是**源 id 列表** ⇒ 一个分组只能表达「这个源的全部频道」，
而本机一个源有 20~48 个台。新增 `live_channel_groups`（v2，存 `{p,c}` 对），
判据抽成顶层纯函数 `liveGroupAllowsChannel`（v2 优先、v1 兜底、空组不筛空）。
两套键**共存**，老分组不静默失效，回退成本 = 删 v2 键。

⚠️ 为什么必须 (provider, channelId) 成对：`LiveChannel.id` 只在源内唯一，
实测本机两个源都有 id 形如 `1`/`2` 的频道 ⇒ 只存 channelId 会命中别的源。

**P0-B：首次打开显示 0 个（真因不是"没有源"，是异常被吞）**

`loadAll()` 的 `catch` 只 `debugPrint` ⇒ 核心未就绪时 `getLiveChannels()` 抛异常
⇒ `_groups` 空 + `_loading=false` ⇒ 画成「没有可用的直播源」，把用户引向
"去设置里启用源"（那条路对他的处境是错的）。

修法：`LiveLoadPhase{loading,failed,empty,ready}` 三态分开，
failed 给「重试」而不是配置建议；`failed` 优先于 `ready`（陈旧数据要明说）。

**P0-C：第二次仍然慢（真的重复全量拉取）**

`LivePage` 是保活页，但 shell 每次切到本页都调 `loadAll(keepSelection: true)`
⇒ 又一次全量 `get_live_channels`（rust 侧逐个插件跑 JS）。
修法：① `DiskCache` 磁盘快照先上屏（首帧就有列表）② `_inFlight` 重入保护
③ 空结果不覆盖快照、快照里的台不自动起播（可能已下线）。

**P0-D：无频道搜索、无分组入口**

搜索框放页头（跨两栏），判据 `liveChannelMatchesQuery`（大小写不敏感、
同时匹配频道名与源名、**有意不做拼音**）。搜索是四维 AND 的**最后**一道。
分组管理入口已在直播页工具栏（Owner 第 12 条第 ② 半）。

**P1-A：分组编辑 UI 从「选源」改成「选频道」**

按源分块（源名做不可点的小标题），块内每个频道一颗 FilterChip（带对勾）。
"全选某个源"作为快捷方式保留。组内搜索（100+ 台时必需）。
管理器宽度 560 → 820（逐频道勾选需要横向空间）。

⚠️ **保存按钮必须放外壳的 `actions:`**，不能放内容 Column 末尾 ——
内容区是 `SingleChildScrollView`，组一大按钮就被推出滚动区（实测 y=633/1057
超出 600 视口，tap 打空；真实用户则是**滚不到保存**）。

**P1-B：设置页也支持逐频道勾选**

数据源是**磁盘快照**（`DiskCache` 读文件，**零 FFI**）——
老注释说"本页不能读本机源列表（要走 FFI，核心不可用时整页打不开）"，
那条约束仍成立，但结论不必是"只能手输"：直播页已经把快照落盘了。
无快照（第一次装 / 还没进过直播页 / flutter test）⇒ 回落手输源 id。

### ⚠️ 未验（本批最大缺口，必须如实说）

```text
· **没有真机截图**。所有界面结论来自 widget 测试的渲染树，不是像素。
  ⇒ 逐频道勾选在 820px 里的**视觉密度**、100+ 胶囊时的滚动体验，均未实测。
· **没有冷启动计时读数**（Owner 问的"等了好久"到底几秒）。
  结构上不再等全量，但**不许**声称"快了 X%"。
· 磁盘快照的**命中**未在真实数据目录上验过（测试里走的是 DiskCache
  未初始化分支 ⇒ 恒返回 null）。真机是否真命中、命中后是否真的一帧就有，无证据。
· 设置页两条编辑路径（逐频道 / 手输）之间切换时数据是否始终一致，未测。
```

### 事故记录：我误 stash 了队友的改动（已恢复）

核实"全仓 16 条红是否与本次有关"时，我跑了 `git stash` ——
它把**并行批次 B 正在改的 danmaku 文件**一起收走了。已逐文件恢复：

```text
· lib/core/danmaku.dart 的 worktree 版本（3361 行）比 stash 版本（2830 行）**新**
  ⇒ 队友在我 stash 期间又改过 ⇒ 我**没有**覆盖它（只从 stash 取了另外 4 个文件）
· 另外 4 个（danmaku_settings_dialog / 三个 danmaku 测试）已按 stash 恢复
```

**教训**：这个仓库是**多 agent 共享工作树**，`git stash` / `git checkout --` 这类
"全树操作"**永远**会波及别人。以后核实基线只能用 `git worktree add` 建独立树，
或 `git stash push -- <我的文件>` 显式列路径。

---

### ✅ P2-5：第 6 条（错误归类）实现完整，但**全仓零测试**

**发现**：`lib/core/sourin_api.dart` 的 `PlaybackErrorText` 三件事全做了：
```text
stripHostErrorNoise   剥 SourinCoreException(...) / 插件报错: / Exception:
hideInternalUrls      藏 127.0.0.1:<随机端口> 内部代理地址
classify              六类归因 + canRetry / canSwitchSource
```
但 `grep -rln "PlaybackErrorText" test/` **零命中**。
⇒ 有人重构掉它，界面立刻退回「Failed to open 127.0.0.1:xxxxx」，没人会知道。

**决策**：补 19 条门禁。故障注入（让 `hideInternalUrls` 直接返回原文）⇒ 2 条变红。

**我自己写错了两次断言，被实测纠正**（值得记）：
```text
① 我断言「会员限制 ⇒ canSwitchSource=false」，实测 true。
   实现是对的：换源可能有用（另一个源可能不限制），但重试没用
   ⇒ 改钉 canRetry=false。
② 我把「取流失败」当 proxy，实测归 source。
   实现注释里有实测日志：代理活着、上游域名解析失败、502 是上游的。
   归给代理就重复了 Owner 抱怨的那个误判 ⇒ 改钉 source。
```
两条都写进测试注释，避免后人重犯。

---

### 🟡 P2-6：构建被**孤儿进程**锁住（跨 teammate 阻塞，已解）

**发现**：`playback-fix` 报告 `flutter build windows --release` 失败，
`MaterialIcons-Regular.otf` 无法拷贝（Invalid argument / Permission denied）。
它列了两个候选 PID，说「不是我的，按纪律不动别人的进程」。

**我核实的过程**（没有盲杀）：
```text
PID 27976  22:42:38  build/.../Release/sourin_spike.exe
  → 父进程 7964 **已不存在** ⇒ 孤儿进程，已跑 2 小时
  → 确认后 kill，输出 KILLED

PID 964    00:48:31  .probe/t65d-run/sourin_spike.exe
  → 我查的时候**已经不存在**（自己退的）

PID 30180  00:52:04  .probe/t65d-run/sourin_spike.exe
  → live-ux 刚起的探针，不在 build 目录里，**不影响构建** ⇒ 没动
```

**决策**：只杀确认的孤儿。核实方法写在这里，供后用：
「先看父进程是否还在 —— 父进程已退出的 GUI 进程就是孤儿，杀了是清理不是破坏。」

---

### 🟡 P2-7：第 10 条（搜索弹幕被拒）根因是**源站随机风控**，不是代码一直写错

**发现**（playback-fix 实测，我认可）：
```text
search/type    连打三次：200 / 200 / 412   ← 风控随机命中
search/all/v2  连打三次：200 / 200 / 200   ← 稳定
```

**判断**：Owner 说「反反复复搞了多少遍了」——真相是那条路径本身不稳定，
不完全是代码一直写错。已加兜底接口，真网络复测每次回 17~20 条。

**这条要在最终汇报里明说**：不是「终于修对了」，而是「找到了不稳定的那条路
并绕开它」。两者的区别对 Owner 有意义。

---

## 批次 B（弹幕体系）发现的问题

> 记录人：danmaku。写域：`lib/core/danmaku.dart` /
> `lib/ui/widgets/danmaku_settings_dialog.dart` /
> `lib/ui/widgets/danmaku_info_panel.dart` /
> `lib/ui/settings/danmaku_source_page.dart` + `lib/ui/player_page.dart` 的**两处**。

### 🟢 P3-1：内置公共实例**只有 2 个能用**（诚实上限，非缺陷）

Owner 第 4 条要「内置上几个」。实测（`.probe/danmaku_b_builtin_probe.py`）：

```text
候选                           search        comment      结论
danmu-api-delta.vercel.app     200 (1 条)    200 (2102 条)  OK
danmu-api-kappa.vercel.app     200 (1 条)    200 (2049 条)  OK
danmu-api-psi.vercel.app       200 (1 条)    超时/0        FAIL（能搜不能取）
```

**判据**：两条都要过 —— ① `/api/v2/search/anime?keyword=火影` → 200 且 animes 非空；
② `/api/v2/comment/<id>?format=json` → 200 且 comments 非空。

**决策**：只内置那 2 个。psi 那种「能搜不能取」的**刻意不放进表** ——
内置一个半残地址比少内置一个更糟（用户开箱失败会以为软件坏了）。
⇒ 交付时说「2 个」而不是假装「好几个」。

**⚠️ 这条要在最终汇报里明说**：2 个是实测上限，不是偷懒。

---

### 🟡 P2-8：内置实例**会掉数据**（实测到了，用户要知道）

写测试时 `ep10002` 还能取到 2102 条；20 分钟后同一个 id 变 **404**。
（search 仍 200，说明实例本身活着，只是那一集的弹幕源被上游撤了。）

⇒ 结论写进代码注释与 UI 文案：**公共实例是公共服务器，会慢、会临时不可用**，
所以：
1. UI 必须给「测试连接」让用户自己验（已做）；
2. 文案不能承诺"一定好用"（已做：`会慢（冷启动几秒）、也可能临时不可用`）；
3. 探测要认**第三种端点**（见 P2-9）。

---

### 🔴 P1-1：探测内置实例时**假阴性**（已修）

**现象**：`DanmakuLocalService.probe` 只认 `/api/v2/system/version` 与 `/api/config`
两个端点，而内置实例**两个都是 404** ⇒ 明明能取到 2000+ 条弹幕，
面板却写「未运行」。

**这是真缺陷，且与 2026-10-16 修过的 `configPath` 那次是同一个病**
（"服务活着却被判成不可用"）。

**修法**：加第三个探测端点 `/api/v2/search/anime?keyword=a`（返回这个协议**特有**的
`animes` 结构，误判率低），且只在**带 endpoint** 时试（本机 2080 那条路不加，
否则「未运行」提示会慢 3~5 s）。
**判据**：`t65b_danmaku_builtin_endpoint_test.dart` 的「④」组；
故障注入（把这一步删掉）⇒ 该组红 2 条，已实测。

---

### 🔴 P1-2：聚合去重**吃掉真实弹幕**（已修，真数据抓出来的）

**现象**：第一版聚合器只做「跨源去重」（`(时间 0.1s, 正文)` 全局 `Set`）。
用**真实数据**一跑：

```text
同一路给了 9415 条  ⇒  输出只有 9342 条   （少了 73 条）
```

**根因**：真实弹幕里「同一个时间点同一句话被很多人刷」是**常态**
（"哈哈" / "前方高能" / 应援词）。那是**不同人的不同弹幕**，只是内容撞了 ——
全局去重把它们当成重复吃掉了。

**修法**：判据分两段 ——
① 源**内部**一律保留（别人的真实发言，重复也要留）；
② 只在**跨源**时按 `(0.1s, 正文)` 去重（同一批数据被两个源各抓一遍）。
实现上把全局 `Set` 换成 `Map<String,int>`（记「哪一路先给的」），
只有 `owner != 当前路` 才丢。

**修后真读数**（`.probe/danmaku_b_live_aggregate.py`）：
```text
场景 A 两路给同一集：9415 + 9415 = 18830  ⇒  合并 9415 条，去掉 9415 条跨源重复
场景 B 两路各给一集：9415 + 9440 = 18855  ⇒  合并 18854 条，去掉 1 条，时间有序 ✔
```
**判据**：`t65b_danmaku_aggregate_test.dart` 的「③ 同一路内部…必须保留」与
「跨源去重仍然生效」；故障注入（退回全局 `Set`）⇒ 这两条**同时红**，已实测。

⚠️ **这条必须在汇报里点名**：它不是设计洁癖，是**用真数据跑出来的丢数据缺陷**。

---

### 🟡 P2-9：既有测试因「内置实例上线」而必然变红（已按新行为改断言）

内置实例一上线，「没配地址 ⇒ 走官方 / 走本机 2080」这条老断言**必然**变成
「走内置实例」。涉及 4 个文件：

| 文件 | 改前钉什么 | 改后钉什么 | 为什么 |
|---|---|---|---|
| `test/t3_danmu_api_endpoint_test.dart` | 没配 endpoint ⇒ 官方域名 + 签名头 | 同左，但 `setUp` 里 `debugSetPublicInstances(const [])` | 本文件测的是**官方/签名**那条边；内置不关掉就是在测另一条路（假绿） |
| `test/t27_w5_danmaku_source_test.dart` | 没配 ⇒ 本机 2080 | 同左，同上关内置 | 同上（测本机那条边） |
| `test/task35_danmaku_priority_test.dart` | 没配 dan-api ⇒ 仍走 2080 | 同左，同上关内置 | 同上（测优先序） |
| `test/t105_danmaku_appkey_flow_test.dart` | 填了凭证 ⇒ 签名三件套 | 同左，同上关内置 | 内置是**免凭证**的，不关就永远测不到签名头 |

⚠️ **新增的测试注入口**：`DanmakuConfig.debugSetPublicInstances(List?)`
（传 `null` 恢复内置表，传 `const []` 关掉）。**生产代码路径一行都没变**，
只是给了测试一个能明确"关掉内置"的开关 —— 与既有的 `debugSetBuiltin`（内置凭证）
同一条纪律。

**另**：`t3b_selfhosted_panel_test.dart` / `t27_w12_panel_builtin_prefill_test.dart` /
`t73_bili_wiring_test.dart` / `zz_t3_selfhosted_shots_test.dart` 因为**页签改名**
（`弹弹play` → `官方兜底`、外部视频源 → `插件提供`、自建服务区块 → `dan-api`）
改了 tap 目标与文案断言。判据语义**一条都没放宽**（详情见各文件内的注释）。

> ⚠️ 本文件里**不写任何具体视频站名**（t98 门禁对 `.md` 同样生效）。
> 提到"外部视频源的弹幕能力"时一律用中性词，不点名。

---

### 🟡 P2-10：`t73_bili_wiring_test.dart` 的 2600 字符窗口是**脆弱设计**（未修，仅记录）

该测试用 `_page.substring(i0, i0 + 2600)` 截窗口，再断言窗口内有**恰好 2 条**
`status: '外部视频站 · ${r.summary}',`。实测：

```text
HEAD 的 player_page.dart：stripComments 后该串在窗口内 offset 1520，count = 2  ✔
我改后的版本：            同上，offset 1520，count = 2                              ✔
```

**但**：在批量跑（多文件同进程）时该用例**偶发红一次**，单跑与复跑都绿。
判断是 `flutter_tester` 已知的原生崩溃假红（见 `docs/TESTING.md` 顶部），
**不是**我的改动引起的（我用 `git stash` 把 player_page 退到 HEAD 复跑过，
纯净版同样会走进这个窗口）。

**建议（留给人决定）**：把 2600 这个魔数换成「从这个函数开头到下一个函数开头」
的切片（`indexOf('Future<void> _biliApplyComments(', i0)`）。本次不动 ——
那是别人批次的测试文件，且它现在是绿的。

---

### ✅ 批次 B 已完成的判据读数

```bash
flutter analyze lib                      # 0 error
flutter test test/t65b_danmaku_aggregate_test.dart \
             test/t65b_danmaku_builtin_endpoint_test.dart \
             test/task41_danmaku_send_gate_test.dart \
             test/t3b_selfhosted_panel_test.dart \
             test/t139_danmaku_info_panel_test.dart \
             test/t27_w5_danmaku_source_test.dart --concurrency=1
  ⇒ All tests passed!  (84 例)
```

截图（`.probe/shots/`，我逐张看过）：
`t65b_panel_general_dark` / `t65b_panel_danapi_dark` / `t65b_panel_danapi_light` /
`t65b_panel_plugin_dark` / `t65b_panel_official_dark` /
`t65b_info_two_feeds` / `t65b_info_one_failed`。

**看图台抓到并修掉的文案缺陷（2 处）**：
1. 状态条 chip 没数据时渲染成「插件提供 **— 条**」—— 中文里那个"条"吊在破折号后面
   读不通 ⇒ 改成有数才带量词。
2. 「官方兜底」页签里的凭证区块标题仍写着 `凭证 · 弹弹play` ⇒ 改成
   `凭证 · 官方兜底 · 要签名`。**这正是 Owner 第 11 条抱怨的那类残留**
   （页签改了名，区块标题没跟上）。


---

## 2026-10-18 01:00 —— 中途进度（Owner 早上看这里）

### 批次完成情况

| 批次 | 状态 | 一句话 |
|---|---|---|
| A 插件私有仓 | ✅ 完成 | 私库 `sourin-plugins` 已推送，32 js + 3 bak，隐私扫描 0 命中 |
| B 弹幕体系 | ✅ 完成 | 内置 2 实例、入口置灰可见、聚合真数据 18854 条 |
| C 错误信息+播放 | 🔄 收尾中 | 6/7/8/10 四条都已落地，等构建自测 |
| D 直播重构 | ✅ 完成 | 三态+快照+频道分组+搜索，故障注入 7 项全红 |
| E UI 替换 | ⚠️ 部分 | 13/16/17 完成；12/18 未做；15 查明前提不成立 |
| F 数据管理 | ✅ F1 完成 | 数据管理页已上线，7 类分类 + 安全边界门禁 |
| G 交付发版 | ⏳ 待办 | `--prerelease` 缺口已修并故障注入验证 |

### 我自己亲手做并验证的

```text
第 13 条  删两套布局骨架（净减 602 行）        analyze 无新增，t32 16/16
第 16 条  补主题深浅色门禁（机制本已存在）      5/5，故障注入红 4 条
第 17 条  进度条逐帧 seek → 松手才 seek        4/4 + 4/4，故障注入红 1 条
第 7 条   错误文案剥离宿主前缀                  Rust 119/119 + Dart 7/7，双注入红
第 6 条   补错误归类门禁（实现本已存在）        19/19，故障注入红 2 条
第 14 条  数据管理页（新功能）                 6/6，故障注入红 2 条
E2        163 处 Icons → AppIcons              59 文件，analyze 与基线逐条一致
G4        发版 --prerelease 缺口               10 组用例，故障注入红 3 条
t98       三轮站名违规（含我自己的）            全部修复，无白名单
```

### 三个「实现早就有了，但没人验证」的发现

```text
① 第 16 条 主题深浅色：themeFor 的 siblingOf 逻辑完整存在，零门禁
② 第 6 条  错误归类：PlaybackErrorText 完整存在，全仓零测试
③ E2 的 AppIcons：159 个图标常量早就写好，零个文件使用
```
⇒ 这三处都是「写了没接线 / 有实现无门禁」。我补的都是门禁，不是重写实现。
**这个模式值得 Owner 知道**：上一轮做的东西有不少是「做了一半」。

### 一个必须坦白的判断失误

我在计划里把「移除 material_ui」估成「131 个文件、一轮可做完」。
实测证明**前提就不成立**：`ThemeData` / `ColorScheme` 本身就住在 material_ui 包里，
全仓 172 处 `Theme.of(context).colorScheme` 依赖它。
我写的 `AppColors` 门面被自己的逐色测试当场打红（`AppPalette` 是中性色板、
`ColorScheme` 是语义色板，两层不同的东西），已删除该门面和测试。

⇒ 第 15 条本轮**不做**，排为独立后续批次。这不是「没做」，是「查明后发现前提不成立」。

### 队友误操作（已处理，无损失）

`live-ux` 在核实「全仓 16 条红是否与我有关」时跑了 `git stash`，
把批次 B 正在改的 danmaku 文件一起收走了。
已逐文件恢复；实测 `danmaku.dart` 的 worktree 版本比 stash 版本还新
（说明期间又改过），**没有覆盖队友的成果**。
教训：共享工作树里不许用 `git stash` 全树操作，要用 `git stash push -- <路径>`。
