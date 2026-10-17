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
