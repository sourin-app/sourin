# Agent Note: 弹窗外壳收拢（R4）与缓存徽标的全局订阅（R8）

Status: implemented

Independent: 与本轮其它笔记都不同 —— 那几篇分别讲
[更新说明生成](../process/2026-10-19-release-notes-generated-from-git.md)、
[判据纪律](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)、
[兜底文案](../bug-fix/2026-10-19-probe-failed-never-asserts-unhappened.md)、
[自审揪出的四个缺陷](../bug-fix/2026-10-19-selfaudit-found-four-real-defects.md)。
本篇讲两件**产品结构**的事：弹窗外壳统一与全局事件订阅的解绑，
不涉及任何判据或文案纪律。

## Problem

**R4（Owner：弹窗样式不统一「丑爆了」）**

```text
Owner 原话：弹窗样式不统一「丑爆了」
实测 3 个弹窗**绕过**了统一外壳：
  update_dialog    用 AlertDialog + width 460 写在 content 里
  skip_marker      自写 Dialog + 740 高（规范 620）
  composer         width 860（规范无此档）
⇒ 改前 7 个弹窗宽度有 460/560/620/820 四种、高度三种，全凭各写各的
```

**R8（Owner：已缓存的删除徽标看不清）**

```text
`opacity: _hover ? 1 : 0`，而 MouseRegion 只由**鼠标**驱动
⇒ 触屏 / 遥控 / 键盘用户**永远看不见**那个徽标，
  而它背后挂着「删除整部」
```

★ Lead 的第一版裁决用 `MediaQuery.hoverable` —— **该 API 在 Flutter 3.47 不存在**
（全 SDK `grep` 0 命中）。真信号是 `MouseTracker.mouseIsConnected`。

## Decision

### R4：三个弹窗收拢到 `AppDialogShell`

白拿到的三件事：标题栏（title + subtitle + 右上角关闭）、
圆角/底色/描边取自同一处、三条退出路径（Esc / 点遮罩 / ×）收口。

★ **`_kMaxHeight` 从 `620 * 0.8` 改回 `620`** ——
这看着像微调，其实是**真回归**：

```text
工作树原样（620*0.8 = 496）⇒ +99 -2（t70 两条 tap 红）
改回 620                   ⇒ +101 All tests passed!
注入 480                   ⇒ +99 -2（同两条红 ⇒ 判据有判别力）
```

`0.8` 那个值的文档注释自己写着「**这个数是拍的，没有依据**」，
`docs/AGENTS.md §3.5` 也记着它曾让 t70 三条红。
⇒ 即使某次跑恰好不红，**留着一个已知错误的结论在代码里也是缺陷** ——
  下一个人读到注释会以为 0.8 是有意为之。

skip 弹窗是**唯一**显式传 `maxHeight` 的（740），
理由写进了注释：新外壳加了一条 70px 标题栏，
`620` 会把预览压到 116px（≈206×116，比 Owner 当年嫌小的 277×156 更小）。

### R4 第二步：全仓取号 —— **收拢 11 处 / 豁免 15 处（按处，不按文件）**

> ★ **口径更正（2026-10-20，替我上一版的错报）**：本节此前写「收 7 处、豁免 9 处」，
> 那是**只数了本批新动的**那几个站点。按处（不是按文件）复核后的真数字：
> **收拢 11 处** = `lib/` 里 `AppGlassDialog(` 的构造点（除 `lib/design/` 自身与
> `lib/t105_r4_dialogs_probe.dart` 探针）；**豁免 15 处** = 门禁 `_siteExemptions`
> 的 15 条键，与代码里 15 处裸 `AlertDialog(` / `Dialog(` 构造点 **1:1**。
> ★ **数与处不可互换**（2026-10-20 二次复核，逐个 `grep -rn "AppGlassDialog(" lib` 点的）
> 同一文件里多个站点的（`detail_page` 3、`settings_page` 4、`backup_panel` 3、
> `theme_page` 2、`sync_panel` 3）**一律按处算**。
>
> 两个口径别混：全仓**按处**是收拢 11 处（`grep -rn "AppGlassDialog(" lib` 去掉
> `lib/design/` 自身与探针后的 11 个构造点），**按文件**是 9 个文件；
> 豁免那侧同理 —— 15 条键落在 **8 个文件**里（`settings_page` 4、`backup_panel` 3、
> `sync_panel` 2、`theme_page` 2，其余 4 个文件各 1）。所以「11 处 / 9 文件」「15 处 / 8 文件」
> 都得标清楚，**不许拿「处」和「文件」对账**。（上一版本的「收 7 / 豁免 9」恰好
> 是「7 个站点 / 7 个文件」的巧合，看着像文件数，其实仍是站点数。）

第一步只收了 3 个弹窗（`update_dialog` / `skip_marker` / `composer`），
全仓其余站点仍在各写各的。第二步的判据换成
`test/zz_t66_r4_dialog_consistency_test.dart`：
**每一个绕过外壳的 `AlertDialog` 都必须带站内 `// R4-EXCEPTION:` 注释，
并且在门禁的 `_siteExemptions` 里登记「路径#特征串」，两边对得上才算数。**

判定要么收、要么登记，**不存在「先放着」**——
①-b 是逐处的（不是计数），少登一处就红；④-b 又把「登了但代码里
没有对应的豁免注释」也判红 ⇒ 防止「登记表越写越长、注释早已被删」。

```text
收拢 11 处（原先都是裸 AlertDialog，现全部走 AppGlassDialog）：
  app_tray           退出确认（★三键：直接退出/托盘/取消）→ 自拼按钮行
  cache_page         「删除」             → AppGlassDialogActions，不染红
  detail_page        「下载全部集」        → 同上
  detail_page        「删除这一集」        → 同上
  detail_page        「删除选中的集」      → 同上
  settings_page      通用确认              → 同上
  data_manage_page   「清理」             → 同上
  emby_page          「删除」             → 同上
  skip_page          可自定义确认文案     → 两键走 Actions，否则自拼
  sync_panel         可自定义确认文案     → 同 skip_page
  download_panel     「删除这一集的下载？」→ 同上（本轮补）

豁免 15 处，按**机制**归类（不是按「懒得改」；☆ = 该处叠了两条机制，只数一次）：
  机制② 缺 Material 祖先（8 处，逐条列全，不许只写"代表性的几个"）
                         settings_page:调整内容源顺序(ListTile)
                         settings_page:这一处刻意保留 Material(TextField)
                         backup_panel:设置导出用口令(TextField)
                         backup_panel:这个备份包含登录态(TextField)
                         theme_page:粘贴主题包 JSON ☆(＋④ 宽 460)
                         sync_panel:配置云盘(WebDAV) ☆(＋④ 宽 420)
                         sync_panel:width: 380(passphrase 表单) ☆(＋④)
                         tvbox_source_panel:订阅更新 ☆(＋④ 560×480)
  机制① 缺 width 控制（2 处）
                         settings_page:插件更新(480×460)
                         settings_page:配置「」(420 + 动态字段循环)
  机制③ 内联 TextStyle 定色被外壳覆盖（1 处）
                         download_panel:删除整部剧的下载？(红字警示被冲掉)
  机制④ 缺 padding/backgroundColor（1 处，只此一条）
                         theme_page:主题预览面板(零内边距 + 自带卡片底色)
  机制⑤ 内容区 textAlign 强制居中（1 处）
                         backup_panel:多行左对齐清单(『这个备份文件含登录态』)
  自建外壳（裸 Dialog( + 自绘标题）（1 处）
                         provider_login_panel:登录确认（title 只收 String）
  探针类（1 处）        t104_overlay_exit_probe(验证统一入口本身)

★ **两条同名陷阱（verify-34 曾据此刻度判我"机制写反"，根因是两个标题只差一个字）**：
```text
title: const Text('这个备份包含登录态')  → _ImportPassphraseDialog，含 TextField ⇒ 机制②
title: const Text('这个备份文件含登录态') → showAppDialog 里 StringBuffer 多行清单 ⇒ 机制⑤
```
两者是**两个不同的弹窗**，不是同一处的两种说法。登记表用各自完整原文做键
（前者 `title: const Text('…')`、后者 `builder: (ctx) => AlertDialog`）来区分。
```

★ **`skip_page` / `sync_panel` 的 `cancelLabel == null` 形态是「只有确认键」**，
不是「取消+确认」——照 `AppGlassDialogActions` 硬套会**凭空多出一个取消按钮**、
把返回值语义从 `pop(null)` 变成「必须先点取消」。这类站点自己拼 `Row`，
注释里写明「逐字等价原形态」。

★ **`confirmIsDestructive` 一律照改前的按钮形态判，不按「它是不是删除」判**：
这些站点的确认键改前**全是 `TextButton`**，所以一律 `false`。
「删除/清理/彻底退出」被顺手染红是最容易犯的错——
Owner 抱怨的是**样式不统一**，不是**不够红**。

★★ **本轮改判了一处豁免理由（删掉一条错误结论）**：
`settings_page` 的「调整内容源顺序」原登记为「装 420 只需传 `maxWidth: 468`，
宽度到位就能收」。当时的依据是「点第 2 行『上移』，顺序真的变了」——
**那条依据测错了对象**：那个探针把 `AppGlassDialog` 放在
`MaterialApp(home: Scaffold(body: Center(...)))` 里跑，
**Scaffold 提供了 Material 祖先**，所以 `ListTile` 的 InkWell 活着。
走真实 `showAppDialog` 路由（无 Scaffold）时：

```text
No Material widget found.
ListTile widgets require a Material widget ancestor within the closest LookupBoundary.
找到「上移」数 = 0      ← trailing 里的 IconButton 根本没建出来
```

⇒ 它不是「能不能点」的问题，是**弹窗根本打不开**，
与 `TextField` 那一类缺口同源（`AppGlassDialog` 是零 Material 的纯玻璃卡片）。
**「换了外壳之后还能不能用」必须在真实路由里测**，
在 `Scaffold` 里测等于给被测对象垫了个 Material 宿主 —— 这正是
[判据纪律](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)说的
「测试环境比生产环境多给了一样东西」。

### R8：解绑挂在全局单例上的订阅

```dart
// CachePageState.dispose()
_HoverCapability.disposeListener();
```

★ 为什么必须解绑：listener 挂在 `RendererBinding.mouseTracker` ——
**全局单例**。不解则每次进出「已缓存」页就多一条回调，
而它们引用的是**进程级 static**，不会随 State 消失
⇒ 后果不是内存泄漏，而是**每次鼠标事件都唤醒一串早已无用的回调**。
若将来回调里加了副作用，就会变成"页面已销毁还在响应鼠标"这类难查的 bug。

★ 但**粘滞位的值必须保留**：它是进程级语义
（「这台机器见过鼠标」），不该因为关掉一个页面就忘掉。
⇒ `_ensureListening()` 重新挂时会**再同步读一次**全局状态，所以解绑不丢信息。

## Alternatives considered

**A. R4：保留三个弹窗各自的实现，只统一颜色与圆角常量。**
最强理由：改动面最小，不会碰任何布局。
否决理由：Owner 抱怨的**就是**"各写各的"这件事本身 ——
统一常量之后仍是四份结构，下一个人还会再加第五种。

**A'. R4：保留 `620 * 0.8`，因为实测那批门禁当时不红。**
最强理由：「现在绿就行」，改它有风险。
否决理由：**"某次跑不红"与"它有依据"是两件事**。
而且 Lead 自己那批 `+51` 绿里**不含 t70**（最敏感的那批），
拿它当证据是"用一个没测到的范围支撑结论"。

**B. R8：用 `Device.isDesktop` 判断是否需要悬停显形。**
最强理由：现成的语义（桌面才有鼠标）。
否决理由：**触屏设备也可能是 desktop 目标**（Windows 触屏本），
而遥控器根本不是 desktop。判据应当是**输入设备实际在不在**，
不是**平台是不是桌面**。

**C. R8：不解绑，只在 `debugReset()` 里清。**
最强理由：测试不会串味就行。
否决理由：`debugReset()` 只在测试调；
生产路径每次进出页面都挂一条 ⇒ 这正是要修的东西。

**D. R4 第二步：全部收拢，一处都不豁免。**
最强理由：只要开了豁免口子，登记表就会变成垃圾桶，
下次来的人先登记再说 —— 这正是不统一的老路。
否决理由：那 15 处里有 14 处是**外壳能力缺口**（只有 1 处是真机探针），
硬塞进去的后果不是「丑一点」：
`ListTile`/`TextField` 直接抛 `No Material widget found`（**弹窗打不开**），
或把多行清单/表单**逐行居中**、把内联定色覆盖掉。
那不是「统一」，是**用一个错的样子统一**。
正确顺序是**先补外壳能力**（透明 Material 宿主 / `textAlign` 可控 /
`maxWidth` 放开），补完再收 —— 豁免条目里逐条写着「补齐 X 之后才可收拢」。

**E. R4 第二步：只改代码，不建逐处门禁。**
最强理由：这轮已经把 11 处改完了，静态检查是额外成本；
第一步已有渲染门禁，够用。
否决理由：第一步只收了 3 处，而**第一步之后全仓仍有 15 处**裸 `AlertDialog` /
`Dialog(`（= 现登记表 15 条，1:1）——
正是因为没有「逐处」判据，收完就又开始长。
计数式判据（「≤N 处」）更糟：新增弹窗会把 N 顶上去而静默放宽，
逐处取号才会逼出「要么收、要么说清为什么」。

## Consequences

**R4**

```text
三个弹窗的宽度全在 §3.5 白名单 {460, 560, 820}；
圆角三者逐项相同（22.0）；底色逐项相同（ff36343a）；
只有 skip 传 maxHeight（740），其余吃默认 620。

门禁 `zz_t66_r4_dialog_consistency_test.dart` +8：
  ① 静态：宽度在白名单里
  ② 渲染（读 tester.getRect，不是读源码字符串）
  ③ 故障注入 460→860 ⇒ +6 -2，**静态与渲染两层同时抓到**

回归 35 个受影响测试：9 红**逐条在 HEAD 上复现同读数** ⇒ 零回归
```

**R4 第二步**

```text
门禁 `zz_t66_r4_dialog_consistency_test.dart`（13 条判据）：
  修前 +11 -2 → 修后 +13 -0
  两条红分别是：①-b（代码里有 R4-EXCEPTION 注释但没登记进 _siteExemptions）
                ④-b（登记的键指向的那处**找不到**豁免注释）

★ ④-b 的两条红**不是判据过严，是登记表本身在腐化** —— 它抓到的正是
  「键写了、但那个特征串在文件里已经不存在」：两条键（`backup_panel.dart` 的
  `设置导出用口令`、`provider_login_panel.dart` 的 `maxWidth: 460`）
  在代码改动后已不再是原文子串 ⇒ 登记表看着很全，实际**指不到任何一处**。
  修法是改键去贴合原文（`title: const Text('设置导出用口令')` /
  `constraints: const BoxConstraints(maxWidth: 460)`），**不是放宽判据**。
  这条判据的邻域窗口（±14 行）是 HEAD 上就有的，本轮**没动它**。

★ 本轮对门禁的改动只有四件：补登 1 处新豁免（`backup_panel` 机制⑤）、
  重写 1 条判错的豁免理由（`settings_page` 顺序弹窗，见上）、修 2 条已失效的键、
  把注释里过期的计数口径（16 处 / 22 处）改成**插桩实测的 15 处**（`SCANNED_TOTAL=15`、
  `registry=15`、15 行全 `hit=Y`）。**判据本身没动**，只改注释口径。

故障注入证明它仍有判别力（两次都 sha256 前后一致地还原）：

```text
注入① 把 download_panel 改回裸 `AlertDialog(` ⇒ ①-b 红
注入② 删掉 settings_page 的 R4-EXCEPTION 注释  ⇒ ④-b 红
```

analyze：`flutter analyze lib test/zz_t66_r4_dialog_consistency_test.dart`
  → **0 error**；warning 与基线逐条相同（既有 7 条 unused/duplicate 全在 HEAD 上）。

同族 R4 门禁全绿：glass_dialog +25 / no_passthrough +6 / material_localizations +4。
替身回归：受影响的 12 个测试串行跑全绿（含 download_panel 的
`zz_cr_local_row_trash_hover_test`、settings_page 顺序弹窗的
`zz_cr_ui_19_subset_reorder_test`）。
```

**R4 P1（2026-10-20）：卡片铺满整窗 + 默认宽高与 §3.5 打架**

```text
症状（真机 1280×800）：`AppGlassDialog` 卡片 rect=(0,0,1280,800) 铺满整屏；
同屏 Material `AlertDialog` 却是 508×246。Owner 那句「弹窗样式不统一、
丑爆了」与此同源：**一个应用里两套外壳、两套默认宽高**。

根因：`showDialog` 的 DialogRoute 把 builder 结果挂在 Positioned.fill 上 ⇒
传进来的是**紧约束**（min==max==整窗），而 `ConstrainedBox` 用的是
`enforce(父约束)` ⇒ maxWidth 380 被父约束顶掉。Material 的 `AlertDialog`
自己 build 里有一层 `Align`，我们这层外壳漏了。
—— 不是「宽度调小了」，是**约束层漏了一层**。

修法（A→B，顺序不能反）：
  A 外壳内补 `Padding(Sp.x4) → Align(center) → ConstrainedBox`：
    Align 在紧约束下先占满可用区，再把**松约束**交给 ConstrainedBox
    ⇒ maxWidth/maxHeight 才真正生效；Padding 是视口安全边距。
  B 默认值收敛到 §3.5（**改代码对齐文档**，不是改文档迁就代码）：
    maxWidth 380 → 460（§3.5「窄弹窗」档；确认框不是宽版面）
    maxHeight 420 → 620（§3.5 绝对值；内容区本就是 Flexible + ScrollView，
      抬高上限只是少滚动，不改布局语义）

读数（走真 showAppDialog；探针 .probe/r4g_fullwindow_probe_test.dart）：
  修前 1280×800 ⇒ rect=(0,0,1280,800)，占屏 100%
  A 后          ⇒ w=380 h=141，居中，两侧留白 450
  A+B 后        ⇒ w=460 h=141，居中，两侧留白 410

★ 判据不写死 380：A 阶段只断言「非满屏 + 居中 + 两侧留白 > 0」，
  B 阶段才收紧成「宽 ∈ §3.5 白名单且 == 460」。
  写死 380 会让 B 步必红，写死「跟 maxWidth 联动算」则把默认改回 380 也绿。

门禁新增 / 改判：
  glass_dialog +25 → +28：⑧ 三组（非满屏+居中+留白 / 默认值 ∈ {460,560,820}
    且 == 460 / 三键同排在 460 下不溢出、不换行、不被卡片边缘裁切）
  r4_dialog_consistency ④-c 基准 332 → 412（= 460 − 48 padding），
    并新增一条**不 pump 就能读**的默认值断言（380 直接落在白名单外）。

故障注入（两次都 sha256 前后一致地还原）：
  ① 默认 460/620 改回 380/420 ⇒ glass_dialog +27 -1（白名单断言红）；
     r4 ④-c 红（Expected: contains 380 / Actual: [460,560,820]）
  ② 去掉 Align 那一层 ⇒ glass_dialog +26 -2，⑧ 读到 w=1248 h=768（占满可用区）

回归：18 个受影响测试串行全绿（上轮 17 个 + t12 探针 +15）；
  引用 `AppGlassDialog` 的 8 个测试文件全绿；
  `zz_settings_geometry` 仍 +0 ~3（既有 skip，与本次无关）。
调用点影响（10 处，均未显式传 maxWidth/maxHeight ⇒ 一律吃 460/620）：
  全部是纯文本确认框（部分三键自拼）；宽度上限变大只会**少折行**，
  不可能引入新的水平溢出（改大 max 不会让原本装得下的内容装不下）。

analyze：0 error；lib 与两个门禁文件**零新增 warning**
  （`zz_t66_glass_dialog_test.dart:53 unused_import` 在 HEAD 上就存在）。
```


**R8**

```text
门禁 +5，含泄漏判据：
  首次挂载 listener=1 → 卸载 listener=0 → 三轮反复挂载**不增长**（仍是 0/1）
注入：删掉 disposeListener() ⇒ +4 -1（报出「卸载后仍 listener=1」）

★ 修复顺序踩过的坑：先只做了 R8 的修复，R8 复核时才发现
  `_kLoadTimeout`（本轮新增的 10 秒）在 fake clock 里永远到不了
  ⇒ skip 那批测试停在 loading。同一族的第二个实例。
```

**已知上限（如实记）**

```text
· 遮罩实际变深了一档：改前只有路由 barrier alpha 0.541，
  改后经外壳再加一层 scrim 0.72 ⇒ 合成 0.871。
  与其余走外壳的弹窗一致（既有模式），但这两个弹窗是**本轮新加入**的。
  若观感不可接受，应在外壳的 `motion:false` 时考虑不画 scrim。
· skip 弹窗的标题截断（阈值 24 字符）在 411 宽下仍会换 2~3 行
  —— 注释说"截断防标题栏撑成两行"，这个判据**不成立**（P2，未修）。
· t486 那条「极窄宽度下标签会被省略」的阳性对照是**另外两条**的证明力来源：
  删掉它，手机/桌面那两条会退化成无人验证的 isEmpty。
  已在 `zz_t66_t486_zero_overflow_review_test.dart` 钉住这个依赖。
```

**何时该翻案**

```text
· 若 Owner 认为遮罩变深不可接受 ⇒ 改外壳的 scrim 策略，
  但**不能**退回"各弹窗自己画遮罩"（那就回到 R4 要解决的问题）。
· 若 skip 的标题截断在真实片名（长中文/emoji）下仍撑高，
  应改为按可用宽截断（外壳需要加 `titleMaxLines` 参数），
  而不是调大那个 24 —— 现在调它也解决不了换行。
```

**R4 P0（2026-10-20）：搬到玻璃外壳的确认框，正文对比度塌到 2.01:1**

```text
真机读数（Lead 用 PIL 从 .probe/round66_r4_device/fix1_01_tray_close.png 逐像素量；
卡底 #A1A9BC = 玻璃压浅色页面后的模糊结果）：
  标题「要关闭还是彻底退出？」  #0A0A0A on #A1A9BC = 8.41:1  ✔
  正文（最小化到托盘…）        #737373 on #A1A9BC = 2.01:1  ✘
  正文（彻底退出：结束程序…）   #737373 on #A1A9BC = 2.01:1  ✘
  按钮行                      #171717 on #A1A9BC = 7.59:1  ✔
```

根因不是玻璃本身，是**少了垫层**：R3-① 「弹窗整体看不清」当时的裁决是
「玻璃只管质感，**遮光交给实色垫层**」，但那个垫层只落在
`lib/ui/widgets/app_dialog_shell.dart:301`；`AppGlassDialog` 从来没有 ⇒
R4 第二步把 7 个 `AlertDialog` 搬进来，等于把 R3-① 的缺陷搬了回来。
教训一句：**收拢一个组件之前，要先问它有没有把老问题的修法一起带过来。**

修法：`GlassContainer` 内、`Padding` 之前插一层 `DecoratedBox`
（色 `c.surfaceContainerHigh` + 圆角 `Radii.rLg`）。三个「不用什么」写进了代码注释：

```text
· 不用 ColoredBox —— 直角垫层会从 Radii.lg 圆角外侧露出来
· 不用 Material    —— 会白送 Material 祖先，把机制② 那几处豁免的前提改掉
· 不用 AppDialogShell 玻璃档写死的 #14161B@0.98 —— 那一档用在「视频上的面板」，
  文字已是浅色系；本组件的调用点是浅色页面上的确认框，正文 #737373 压近黑底只剩 ~1.5:1
```

★ **颜色必须与文字同源**：垫层取 `c.surfaceContainerHigh`（`AppSemanticColors`，
与 `c.onSurfaceVariant` 同一来源），**不是** `Theme.of(context).colorScheme`
那一套 —— 两套值并不相同（浅色 `ColorScheme.surfaceContainerHighest = #E4E8F0`，
`lib/ui/theme_bridge.dart:714` 注释自承「硬编码蓝灰，不跟主题包走」；用它算正文只有
**3.86:1**，看着像加固、实际不够）。取同源的 `#FFFFFF` 才是 **4.74:1**。
这条差点变成一条「算着绿、看着坏」的假门禁，是**故障注入 c** 才抓住的。

判据（`test/zz_t66_glass_dialog_test.dart` 第 ⑪ 组，浅/深两档各一条）：

```text
① 结构：GlassContainer 的**直接子层**是 DecoratedBox（改前是 Padding）
② 同源：color == 组件自己 resolve 的 colors.surfaceContainerHigh，
        borderRadius == Radii.rLg
③ 效果：用 WCAG 2.1 公式**现算** contrast(onSurfaceVariant / onSurface, 垫层) ≥ 4.5:1
        （浅 4.74 / 19.80；深 6.94 / 17.18）—— 不写死这些数字，主题改色跟着重算
```

故障注入三连（每次红，每次 sha256 前后一致地还原）：

```text
a) 删掉整层 DecoratedBox      ⇒ ① 红（Expected DecoratedBox / Actual Padding）
b) 垫层色改 Colors.transparent ⇒ ② 红（颜色对不上）        `+0 -2`
c) 垫层色改 Theme.of(...).colorScheme.surfaceContainerHighest
                              ⇒ ② 红                    `+0 -2`
   ★ 最关键的那次：证明判据能抓住「像加固、实际不够」的改法
```

⑪-b 是**只打印不 assert** 的读数表：`ThemePackStore.builtins` 全部 16 套主题包
`contrast(mutedForeground, card)` 实测**最低 5.86:1（卡面 `builtin.glass`）/
4.69:1（页面底 `builtin.sakura.light`）**，全部 ≥ 4.5 —— 但
`AppPalette.light.mutedForeground = #737373` 对**默认**页面底 `#EEF0F6` 只有
4.16:1（内置主题包都没用这个组合）。这是**既有 token 问题**，不在弹窗外壳范围里，
登记在此供裁决；**不为了门禁绿去改别人的主题包色值**。

**R4 圆角（2026-10-20）：两个壳都硬编码 20，§3.5 却写 `Radii.rLg`（=22）**

```text
lib/design/widgets/app_glass_dialog.dart   LiquidRoundedSuperellipse(borderRadius: 20)
lib/ui/widgets/app_dialog_shell.dart:363   LiquidRoundedRectangle(borderRadius: 20)
lib/ui/tokens.dart:98/107                  Radii.lg = 22 / Radii.rLg = all(circular(22))
```
`AppDialogShell` 更隐蔽：同一个壳里有两层圆角 —— 内层 Material 是
`RoundedRectangleBorder(borderRadius: Radii.rLg)`（22），外层玻璃是 `20`。而玻璃档下
内层 Material 的 `color` 已透明、`side` 已 `none`、`clipBehavior` 默认 `Clip.none`
⇒ **真正被看见的一直是 20**，§3.5 的「圆角 Radii.rLg」在玻璃档上名不副实。

修法：两处都改成引 token（`Radii.lg`），不写字面量 —— `§3.5` 的口径是
「圆角一律 `Radii.*`，禁硬编码」，引 token 才能在下一次调 `Radii.lg` 时自动跟上。

判据（第 ⑩ 组，**读 widget 属性、不看像素**）：`GlassContainer.shape.borderRadius`
== `Radii.lg`，两个壳各一条；断言写 `Radii.lg` **不写 22**（写 22 就等于把 token
重新硬编码进测试）。

```text
注入：两处同时改回字面量 `20` ⇒ +0 -2（Expected: <22.0> / Actual: <20.0>）
      还原后 sha256 前后一致
```
