# 第 66 轮：问题记录

> **用途**：Owner 2026-10-17 指示「中途如果有问题，就写到一个文档里面，我明天早上会看的，
> 你记录下来不要影响工作的推进，大部分问题，你按照最优解就行了」。
>
> **纪律**：
> ```text
> ① 遇到问题**先按最优解继续推进**，不阻塞；把问题写进来，等 Owner 看。
> ② 只有「物理做不到 / 破坏性且不可逆 / 涉及钱或对外发布 / 两种做法代价相当
>    且无法实测区分」才停下来问 —— 其余一律自主决策并记录。
> ③ 每条都写：发现了什么 / 我的判断 / 我选了哪个方案 / 为什么 /
>    如果 Owner 不同意怎么回退。
> ④ 已解决的问题也留在本文（标 ✅），因为「怎么解决的」同样值得回看。
> ```

**配套计划**：[plan-round-66.md](plan-round-66.md)
**开始时间**：2026-10-18 08:50
**最后更新**：2026-10-18 11:45

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
### 🟡 P0-7：布局的「两侧占满」是否符合 Owner 现在的想法，需要他确认

**发现了什么**（轨道 F 取证时发现，我核实）：
```text
tokens.dart:719
  static double bandFor(double windowWidth) {
    if (legacy || Device.isTv) return windowWidth;
    return windowWidth;      ← ★ 两个分支返回同一个值
  }

tokens.dart:763
  static double sideInsetForWindow(double w) {
    final band = bandFor(w);
    final side = (w - band) / 2;     ⇒ band == w ⇒ side 恒为 0
  }
```

**两层问题**：

#### ① 这个「恒 0」是 Owner 本人要求的，不是疏忽
```text
tokens.dart:656 原文：
★ 2026-10-04（业主原话：「放大之后两侧留白过多，改为两侧占满吧」）：
  bandFor 不再封顶 ⇒ 上式里的 side 恒为 0。
```
⇒ 为了治「右边空」去改它，等于撤销 Owner 上一次的决定。

#### ② 但 A/B 开关**已经失效**了
```text
`legacy || Device.isTv` 返回 windowWidth，默认分支**也**返回 windowWidth。
⇒ `--dart-define=LAYOUT_AB=legacy` 现在不产生任何行为差异，
  两条臂编出来是同一个二进制。
```
注释说「保留是为了将来若要恢复居中只需改 bandFor 一处」，
但 `legacy` 在 `bandFor` 里**已经没有意义**（它在 `isNarrow` / `paddingFor` 里还起作用）。
这是「改动做了一半」的痕迹。

**我的判断**：
```text
· 不改（本轮）：动它会影响 20+ 调用点，且可能撤销 Owner 的决定
· 但必须让 Owner 知道：现在界面是「两侧占满」，
  如果他看到截图觉得「右边空」，那是大屏布局策略的结果，不是某页写错了
```

**如果 Owner 要恢复居中**：改 `bandFor` 一处即可，但那会让 20+ 个调用点的
`sideInsetForWindow` 突然从 0 变成非 0 —— **必须整体重新验一遍所有页面**。

---

### ✅ P0-8：轨道 B 修掉的真缺陷 —— 「空组」被当成「组不存在」

Owner 主投诉：「我切换到我自建的常用分组,下面的列表没变化,我明明只添加了一个却还是展示全部」。

**根因**（`live_page.dart:224` 的 `liveGroupAllowsChannel`）：
```text
改前把两件事混成了一条兜底：
  (a) 组不存在（用户没建过 / 刚删掉）⇒ 放行全部 ✓ 对
  (b) 组存在但没成员（用户明确说"这一组是空的"）⇒ 也放行全部 ✗ 错
```
Owner 真实数据形态（%APPDATA%/app.sourin.player/ui-prefs.json）：
```text
live_source_groups   = {"常看": []}      ← v1 有这个名字，值是空列表
live_channel_groups  = 整份不存在         ← v2 从来没被写过
⇒ 落进 (b) ⇒ return true ⇒ 切到「常看」看到全部 1178 个台
```

**为什么磁盘是那个形态**（轨道 B 查明，重要）：
```text
v2 支持是 2026-10-18 00:40 才进的（b8d886e）
而第 63 轮版本的 _save() 只有 setLiveSourceGroups 一行（老版本只写 v1）
⇒ 这是**遗留数据**，不是当前代码写坏的。
```
★ 这个区分很重要：否则会去"修持久化"，而持久化是好的。

**修法**：把 (a) 和 (b) 分开判 —— 组名在任一表出现过即视为"用户要的这一组"，
成员为空就如实返回 false，由 UI 给出空态文案（而不是偷偷放行全部）。

**故障注入（我亲自做）**：
```text
把 ③ 改回 return true  ⇒ +27 -1，
  「组存在但是空组 ⇒ 一个都不放行」立刻红 ✓
撤销 ⇒ +28 绿，git diff 为空 ✓
```

---

### ✅ P0-9：我给的弹幕任务书里，现状描述是**过时的**

**发现了什么**：我在 task-1/task-9 里写「面板三 tab 仍是配置/某视频站/弹弹play」
「grep 无 aggregate 实现」—— 那是**第 65 轮开工前**的状态。
轨道 D（danmaku）在上一轮（`c836356`）已经全部落地了。

**它没照做，而是去查证后报我**：「三条里两条已经做完了，和你描述的不一样」。
**这是正确的做法** —— 如果它照着我过时的描述去"修"，会重做已完成的活。

**它顺带找出 3 处真正的「写了没接线」**：
```text
① 手动绑定外部源那条路**绕过了聚合**
   _aggregateDanmaku() 只有 2 个调用点（:6580 pinned / :6621 主路径）
   而 _loadBiliDanmaku 成功支 :7938 直接 _danmakuComments = r.comments
   ⇒ 用户手动绑定后，插件那份弹幕**不会并进来**
   ⇒ 这正好是 Owner 第 11 条要的「插件自带 + 导入源合并」在绑定路径上失效
   ★ 而 aedc29c 之后自动绑定已取消 ⇒ **每一次绑定都是手动的** ⇒ 必然踩到
② _biliApplyComments :7980 同样绕过
③ 它上轮的看图台测试没进提交（git add 漏了路径），现在不在树里
```
**教训**：派任务前必须先核对现状，不能照抄上一轮的任务书。

---

### 🔴 P0-6：N10（拖动转圈）本轮**无法取证**——缺的是工具，不是分析

**背景**：Owner 点名「进度条缓冲条都拉满了,我拖动实践结果还是要转圈圈好长的时间,这也是bug」
是「必须死磕」的两条之一。轨道 A（perf-player）做了一整轮，结论是**未修好**。

#### 它查清的部分（我独立复核，成立）
```text
结构性缺口客观存在：
  缓冲条读 _bufferedRange.end（player_page.dart:13883 附近）
  中央转圈读 _buffering        （:14641 if (_buffering && !_loading)）
  ⇒ 两者**没有任何交叉验证**
```
三个怀疑已排除：
```text
怀疑 3 缓冲条谎报 —— 84 次采样，|end-(position+span)| 稳定 250~320ms，
                    阈值 2000ms，一次没超 ⇒ 排除
怀疑 2 _loading 真凶 —— onSeek 不触碰 _loading（:4366/:4922 是唯一写入点）⇒ 排除
怀疑 1 网络流 —— 验了，但对照组不成立（370KB 文件 2 秒传完）⇒ 未验证
```

#### 它漏掉的决定性变量（我查到的）
```text
产品真实播放路径 = mpv → 本项目 Rust streamproxy（并行预取）→ 上游
  player_page.dart:4953  url = http://127.0.0.1:56008/s/...
  player_page.dart:3611  ClipDownloader.mpvCacheProperties(dir)

而它的两次实验（本地 file:// / 自建 200KB/s HTTP）**都绕过了 streamproxy**。
⇒ 「buffering 只持续 0~1ms」这个读数**不能代表产品行为**。
```

#### 我接手后遇到的真障碍（这才是本轮做不完的原因）
想用 streamproxy 自带的开关做单变量 A/B，逐条查下来：
```text
① SOURIN_PREFETCH_DISABLE 存在（streamproxy.rs:365）
   ★ 但判断用 `std::env::var(...).is_ok()` —— 只看变量**存在与否**，不看值
   ⇒ 设成 "0" 也是**关闭**；对照组必须彻底 unset

② 它在 StreamProxy::new() 里**只读一次**，存进 AtomicBool
   （streamproxy.rs:363-367，2026-10-08 改的）
   ⇒ 进程内改环境变量无效，必须重启进程

③ 代码注释自己写了为什么这很糟（streamproxy.rs:1399-1407）：
   「真机 CDN 吞吐每分钟都在变：同一路流、同一个 Range 请求，
     实测单连接能从 112 KB/s 跳到 464 KB/s，4 并发放大在 1.31×~4.23× 之间摆。
     跨进程对照里两个变量同时在变，量不出真实差值 —— 本轮 3 轮交替实测就撞上了这个墙。」
   ⇒ 作者当初就是为了解决这个，才把开关做成**请求级**
   ⇒ 但 2026-10-08 为修「并发测试抢全局变量」，又改回构造时读一次
   ⇒ **A/B 对照能力因此退化回「跨进程」**，而跨进程正是注释里说量不出差值的形态

④ 唯一正确的路子：`StreamProxy::set_prefetch_disabled(&self, bool)` 是 pub 方法
   （streamproxy.rs:371），可运行期切换、无需重启
   ★ 但它**没有暴露成 FFI 命令**（grep commands*.rs 无 prefetch）
   ⇒ Dart 侧调不到 ⇒ 产品进程里切不了
```

#### 还缺的另一半：媒体
```text
仓里只有 audio_only.mkv，370,633 字节。
streamproxy.rs:1250  PREFETCH_MIN_REMAINING = 512 * 1024
⇒ 370KB < 512KB ⇒ **预取根本不会触发**
⇒ 用这个文件做任何 A/B，两组读数必然一样，会得出「预取无影响」的**错误结论**
```

#### 我的判断
```text
这不是「分析不够」的问题，是「取证工具缺失」：
  ① 需要把 set_prefetch_disabled 暴露成 FFI 命令（约 20 行 Rust + 10 行 Dart）
  ② 需要一条 >512KB（最好 >50MB）的真实媒体，且能经 streamproxy 播放
两者都不具备时，任何「验证」都是自造场景。
⇒ 按 Owner 的实测纪律，**宁可如实报「未修好」，也不交假读数**。
```

#### 如果 Owner 要这一条本轮必须有结果，需要二选一
```text
路线 A（推荐）：授权我加一个 FFI 命令 `set_prefetch_disabled`
  · 20 行 Rust + 10 行 Dart，风险低（就是转调已有的 pub 方法）
  · 加完就能在**同一进程内**交替 ON/OFF，正是注释里说的正确形态
  · 但媒体问题仍在 —— 需要一条真实的大文件源

路线 B：Owner 提供具体片源与操作步骤
  · 他报「转圈很久」时用的是哪个源、哪一集、什么网络
  · 有了这个才能复现，否则我一直在一个自己造的场景里空转
```

**当前状态**：`N10 未修好，已定性为「工具缺失导致无法取证」，不是「查不出原因」。**
完整证据见 `.agents/notes/rejected/bug-fix/2026-10-18-buffering-spinner-despite-cached-range.md`（`9c7f8cc`）。

---

### 🟡 P0-1：我把队友的改动一起提交了（`aedc29c` 混入 N11）

**发现了什么**：我提交 N1（弹幕发送栏内嵌）时用了
`git add lib/ui/player_page.dart`，而那个文件里**同时有**轨道 A 的 N11 改动
（`_cursorLive` / `_controlsLive` / `_CursorRegion` 等 12 处局部化）。
核实方式：`git show aedc29c:lib/ui/player_page.dart | grep -c _cursorLive` → **8**。
是轨道 A 自己发现的并主动上报，不是我发现。

**后果**：
```text
· 代码本身没问题（N11 的改动完整地在里面，轨道 A 已确认）
· 但 `aedc29c` 的提交信息只讲了 N1，没提 N11
· ⇒ 将来 `git log` / `git blame` 查到那些行，会看到一个不相干的原因说明
```

**我的判断**：这是**共享工作树 + 整文件 add** 的必然结果，不是偶发失误。

**我选的处理**：**不改写历史**。理由：
```text
① amend 会改写已存在的提交，而 aedc29c 里 N1 是主体，硬拆风险更大
② 补一个空 commit 不解决「信息与内容不符」，只是多加一条噪声
③ 如实记录 + 本文档留痕，是更诚实的做法
```

**如果 Owner 不同意**：`git rebase -i` 可以把 `aedc29c` 拆成两个提交
（N1 / N11 各一个），但那会重写分支历史，且需要重跑全部验证。

**教训（已写进计划）**：
```text
共享工作树里，`git add <文件>` 加的是**整个文件**，不是「我改的那些行」。
⇒ 多轨道并行改同一文件时，提交前必须先 `git diff <文件>` 确认
  这次要提交的内容里没有别人的东西；有的话用 `git add -p` 挑块。
本轮 `player_page.dart` 有 4 条轨道先后动过，是高风险文件。
```

---

### 🟡 P0-2：轨道 A 把「语法错误中间态」留在共享工作树，污染了别人

**发现了什么**：`lib/ui/player_page.dart` 曾有一段时间编译不过
（`14070:18 The named parameter 'builder' is required`），而它被大量测试 import
⇒ 所有 import 它的测试都 `No tests ran`。轨道 C 与轨道 D 都因此误判过。

**根因**：我在分派时只划了「写入范围（防写冲突）」，**没要求「改到一半要能编译」**。
独占文件只解决**写冲突**，不解决**编译依赖冲突** —— 这是我没预料到的。

**我选的处理**：立规矩补上 ——
```text
独占文件可以长改，但**每个逻辑单元结束必须能编译**。
判据：`dart analyze <那个文件>` = 0 error。
```

**双向都发生过**：先是轨道 A 污染别人，后是我改 `player_bottom_bar.dart`
时留了中间态（`DanmakuSendData` / `_danmakuSendRow` / `DanmakuSendInline` 未定义），
把轨道 A 卡住。我自己也犯了同一条 —— 规矩对所有人一致生效才算规矩。

---

### ✅ P0-3：`t139` 引用不存在的类型名，22 个 analyze error 潜伏到 CI

**发现了什么**：CI 静态分析红，22 个 error 全在
`test/t139_danmaku_info_panel_test.dart`（`DanmakuSourceKind` / `DanmakuMatchKind` 不存在）。

**为什么潜伏**：它带 `@Tags(['needs-shot-dir'])`，默认跑会 **skip**。
而 `flutter test` 对 skip 的文件**不编译** ⇒ 编译错误被 skip 掩盖。
`flutter analyze` 会编译，但第 64 轮之后一直没跑过全仓 analyze。

**修法**：类型名对齐当前源码（`DanmakuFeedKind` / `DanmakuPairKind`，枚举值逐一对得上），
共 11 处替换，**没改任何断言**。

**顺带发现的漏洞（未修，记作已知项）**：
```text
`flutter test` 不编译被 skip 的文件 ⇒ 带 tags 的测试可能长期编译不过而无人发现。
本轮靠 CI 的 `flutter analyze` 全仓扫描兜住，但那要求 CI 真的跑。
```

---

### ✅ P0-4：`zz_composer_shot` 这个临时探针没打标签，CI 真去跑它

**发现了什么**：CI 全量测试 3808 通过 / 7 失败，**7 条全在
`test/zz_composer_shot_test.dart`**。该文件首行自己写着「临时：可视化编排器出图（跑完删）」。

**根因**：它是 PR #30 带进来的一次性出图探针，但**没打
`@Tags(['needs-shot-dir'])`** ⇒ CI 真的跑它。而它按**旧 UI** 找控件：
`tap(find.text('下一步'))` → 该按钮已随 UI 重做消失 ⇒ 必红。

**修法**：补标签（不删，因为它是 main 已有的资产，删掉等于替别人做删除决定）。

---

### ✅ P0-5：3 个真网络探针在 CI 里必然失败，新增 `needs-network` 标签

**发现了什么**：macOS CI 3795 通过 / 3 失败，3 条全是 `zz_t64_*_probe_test`。
失败形态一致：`Expected: not null / Actual: <null> / season 兜底必须给出绑定`
—— 即「请求打不通 ⇒ 拿不到绑定」，与代码对错无关（CI runner 出网受限）。

**修法**：按仓库既有 `native-media` / `needs-shot-dir` 的完全相同的写法，
在 `dart_test.yaml` 新增 `needs-network` 标签，给 3 个文件各加
`@Tags(['needs-network'])`。

**双向验证**（两边都要过，否则就是把功能永久关掉）：
```text
默认跑 ⇒ All tests skipped（exit 0）
--run-skipped --tags needs-network ⇒ +1 All tests passed
  （真网络成功取到 7200 条弹幕）
```

---

### 🔴 P1-1：健康检测**必然超时**，且「全部正常」是恒真假话

**发现了什么**（轨道 C 报，我逐层复核确认）：
```text
① provider.rs:571   trait 默认实现  async fn health_check() -> bool { true }
   ⇒ JS 插件全部落到默认 ⇒ 恒返回 true
② registry.rs:499   health_sweep() 是**串行 for 循环**，每源 15s 超时
   ⇒ 32 源最坏 480s
③ ffi.dart:685      FFI 兜底 120s
   ⇒ 必然抛「命令 health_sweep 超时（120 秒）」⇒ **结果全丢**
```

**这正是 Owner 说的「现在都显示测速 健康失败」。**

**真机读数对比**：
```text
批量 health_sweep：32 条全 true、耗时 3ms      ← 什么都没测
逐项探活（改后）：31/31 可用、2205ms          ← 真实读数
```

**我的判断**：不是测试挡路，是**功能本身坏了**（又假又必然超时）。
Owner 的第 13 条要求（逐项 + 显示进度）恰好同时修掉这两个毛病。

**处置**：授权轨道 C 改 `test/provider_import_test.dart` 那 2 条把
`healthSweep()` 钉成唯一实现的断言，但要求：断言用意不变、
改完必须故障注入、反向断言必须在**剥注释后**的文本上判。

---

### 🔴 P1-2：两个站不支持发弹幕 —— **做不到，不是没做**

**发现了什么**（轨道 D 真请求实测）：
```text
站 A：读免登录（comment/1.xml → 200 + 40983 字节，阴性对照成立）
      发送需真实登录态 + 匹配 csrf（-101 账号未登录 / -400 请求错误）
站 B：先证明站点确实有弹幕（在播放页 chunk 里找到 danmaku:15 / 弹幕:17）
      读接口免登录且返真数据（200 + 真弹幕条目）
      发送需 Bearer（401 unauthorized）
      阴性对照：POST /api/foo /api/bar /api/user 全 404
      ⇒ 401 只出现在真实存在的路由 ⇒ 端点为真
```

**根因**：本地 32 个插件里 **0 个**声明 `danmaku_send`。宿主侧置灰是**正确行为**，
缺的是插件能力。**宿主改不出插件没有的能力。**

**我选的处理**：**如实报告做不到，不硬造入口**。
持有用户账号凭据去代发弹幕，既超出范围也不该做。

**如果 Owner 不同意**：需要提供这两个站的账号登录态；或接受
「让用户自己填 Cookie/Token」的设计（但那要额外做凭据存储，且风险由用户承担）。

---

### 🟡 P1-3：`test/t72_jank_test.dart` 绿着，但用户仍然卡 —— 它测错了场景

**发现了什么**（轨道 A 报，我独立复核）：
```text
player_page.dart:1012   _noteCursorActivity() 第一行就是
                         if (!_fullscreen) return;
t72_jank_test.dart       grep 不到任何 fullscreen 相关代码
```
⇒ t72 只在**窗口模式**下 hover，光标那条路径在它里面**从不执行**；
真机全屏下它每帧都跑。

**而且它只数 setState 次数**，全文件没有 `FrameTiming` / `buildDuration` /
`addTimingsCallback` ⇒ 它证明的是「没有多余的整页重建」，**不证明「不卡」**。

**我的判断**：不是 t72 写错了，是它**只覆盖了一半场景**。
⇒ 本轮新门禁 `zz_t66_player_jank_test.dart` 用 Stopwatch 围 `pump()` 测帧耗时，
并覆盖全屏态。

**顺带纠正我自己的错误**：我在计划里指定用 `addTimingsCallback` 采 FrameTiming，
那是**假仪器** —— `flutter_test` 在 fake-async 里直接调
`handleBeginFrame/handleDrawFrame`（`binding.dart:2356-2358`），不经引擎 frame pipeline
⇒ 帧耗时与 CPU 负荷无相关性（实测差 80 倍、重树读数反而更小）。

---

### ⚠️ P2-1：Stopwatch 测不到 GPU raster

widget 门禁的仪器是 `Stopwatch` 围 `tester.pump()` —— 它覆盖建帧 + 构建 + 布局 + 绘制，
即该帧在 UI 线程上的全部 Dart 侧工作，但**测不到 GPU raster**。

⇒ 真机 P99 必须另测（已要求轨道 A 补真机探针）。
**交付时不许把 widget 读数当成真机帧率。**

---

### ⚠️ P2-2：本轮无法真机实测（Lead 例外说明）

Owner 的实测纪律要求「界面改动必须亲眼所见」。本轮 Lead 会自己做这件事，
但各 teammate 只能跑 headless `flutter test`，**他们的「真渲染」读数是 widget 树级的，
不是真窗口截图**。

⇒ 所有 UI 结论最终由 Lead 在 Windows 真机上逐屏确认，teammate 的读数只作为
「逻辑与渲染树层面正确」的证据，不作为「观感正确」的证据。

---

## ⚠️ P0-10：并发提交导致 `61ba32f` 标题与内容不符（共享暂存区）

**发现时间**：2026-10-18 11:25（轨道 E 自查）
**状态**：🟡 已处置，不 rewrite 历史，如实记录
**记录人**：轨道 E（`61ba32f` 在 git 上的作者是本人，但**事故本身不是本轨道的操作失误**）

### 客观事实

```text
61ba32f  docs(theme): 补记 LightTokens 搬迁的决策与验证（内容已随 7adb978 入库）
```

该提交的**标题说 docs(theme)**，但实际带的 5 个文件全是**弹幕/播放器**的：

```text
lib/ui/player_page.dart                           89 +++++++-
lib/ui/widgets/danmaku_info_panel.dart            47 ++++-
test/t73_bili_wiring_test.dart                    81 +++++-
test/zz_t66_danmaku_bili_aggregate_gate_test.dart 266 +++++++++++++++++
test/zz_t66_danmaku_shots_test.dart               211 +++++++++++++
5 files changed, 677 insertions(+), 17 deletions(-)
```

⇒ **标题与内容完全不符。**

### 原因：git 暂存区是全仓共享的，不是按人隔离的

```text
时间线（同一工作树，多条轨道并发）：
  ① 轨道 E 执行 `git add` 自己的 3 个文件 → 进入暂存区
  ② 在"已 add、未 commit"的窗口期内，另一条轨道执行了自己的 `git commit`
     ⇒ git 把**暂存区里的全部内容**一起提交 ⇒ 轨道 E 的文件被卷进 7adb978
  ③ 该提交后来被 reset 修正，轨道 E 的文件一度变成未跟踪
  ④ 轨道 E 试图用 `git commit --allow-empty` 补一条说明性提交
     ⇒ 但此时暂存区里又有**另一条轨道已 staged 的 5 个文件**
     ⇒ 那条"空提交"实际带走了这 5 个文件 = 61ba32f
```

**关键认知**：`--allow-empty` **不保证**提交是空的 —— 只要暂存区非空，
它照样把暂存内容一起提交。这个反直觉行为是本事故的直接触发点。

### 实际影响

```text
· 两条弹幕测试文件当时**并未真正入库**：
    test/zz_t66_danmaku_bili_aggregate_gate_test.dart   266 行  UNTRACKED
    test/zz_t66_danmaku_shots_test.dart                 211 行  UNTRACKED
  ⇒ 磁盘上内容完整，但 `git ls-files` 查不到（未跟踪状态）
· 61ba32f 现在是**悬空提交**（dangling，不在任何分支上，非 HEAD 祖先）
  ⇒ 它没有污染主线历史
· 其余 3 个文件（player_page / danmaku_info_panel / t73_bili_wiring）
  当时被一并提交，reset 后回到"已修改未提交"状态，内容未丢失
```

### 处置

```text
① **不 rewrite 历史**。61ba32f 已悬空、不在任何分支上，
   而 7adb978 里含有**另一条轨道**的 t134_live_source_groups_test.dart，
   amend / rebase 会动到别人的提交 ⇒ 属于破坏性操作，不做。
② 如实记录在本文（本条）。
③ 轨道 E 的搬迁已由 **da09b4f** 正确落定（3 个文件，无夹带）：
     docs/notes/round-66-track-e-theme-inventory.md  226 行
     lib/ui/theme/light_tokens.dart                  141 行
     lib/ui/theme_bridge.dart                        122 行（净 -85）
④ 两条弹幕测试文件目前仍是未跟踪状态，**需要轨道 F 自行 `git add`**。
   ⚠️ 本轨道不代劳 —— 那是别人的写入范围。
```

### 流程改进（建议写进 CONTRIBUTING）

```text
· `git add <路径> && git commit` 必须在**同一条命令**里串起来，
  中间不要插入任何会 yield 的步骤（不要分成两次工具调用 / 两个回合）。
  ★ 本轮最终成功的 da09b4f 就是这么做的：add 与 commit 在同一次 bash 调用里。
· 提交后**立刻** `git show --name-only --format="" HEAD` 核对文件清单。
· 发现夹带别人的文件 ⇒ **报 Lead**，不要自己 reset（reset 也可能撞上
  别人新提交，反而更乱）。
· `git commit --allow-empty` 不是"安全补丁"—— 暂存区非空时它照样提交内容。
· 需要只提交指定文件、绕开共享暂存区时：
    git commit -- <路径1> <路径2>
  这个形式只提交列出的路径，不带走暂存区里的其他内容。
```

---

### ⚠️ P2-3：三个「工具链把中文读错」的坑（`main.cpp` / `.ps1` / 探针）

```text
轨道：C（playback-fix）    日期：2026-10-18
触发场景：本轮做 N13 单例（新增 windows/runner/main.cpp 逻辑）时连续踩到三个
```

#### ① `windows/runner/main.cpp` 必须**纯 ASCII**

```text
现象：写了中文注释后编译炸，报 20+ 条语法错误
      main.cpp(1,1): error C2220: 以下警告被视为错误
      main.cpp(1,1): warning C4819: 该文件包含不能在当前代码页(936)中表示的字符
      main.cpp(50,5): error C2059: 语法错误:"字符串"
      main.cpp(68,1): error C2143: 语法错误: 缺少";"
原因：MSVC 按**代码页 936**（GBK）读源文件，UTF-8 中文被当成非法字节；
      而 Flutter 模板的 vcxproj 把 warning 当 error（C2220）⇒ 直接失败
判据：`python -c "d=open('windows/runner/main.cpp','rb').read(); print(sum(1 for b in d if b>127))"`
      ⇒ 必须是 `0`
```

#### ② `tools/*.ps1` 也必须**纯 ASCII**

```text
现象：PowerShell 解析失败
      Unexpected token '}' in expression or statement.
      The string is missing the terminator: ".
原因：PowerShell 按**系统 ANSI 代码页**读 .ps1（不是 UTF-8）⇒ 中文变乱码，
      乱码里恰好有引号/括号 ⇒ 语法结构被破坏
修法：脚本里的说明一律英文；要写中文就存成 UTF-8 **BOM**（本项目未采用）
```

#### ③ 探针坑：`MainWindowHandle` 对 Flutter 窗口在启动早期**恒为 0**

```text
现象：脚本读出「第 1 个进程 21 秒都没出窗口」⇒ 误判为「我的 Mutex 改动把启动搞坏了」
真相：窗口 **3 秒**就出来了，只是 Process.MainWindowHandle 还是 0
判据：改用 EnumWindows 按 **类名 + 标题** 找（tools/WinLister.cs）
      class = FLUTTER_RUNNER_WIN32_WINDOW
```

**★ 一般教训（比上面三条都重要）**

```text
「用错的探针会造出假故障，比不测更危险」。

本次是**回退到 HEAD 重新构建做对照**才定位的：
  改前 main.cpp → 3 秒可见
  改后 main.cpp → 21 秒"不可见"
如果只重跑一遍、不去做对照，永远分不清是探针错还是代码错。

⇒ 规矩：探针给出反直觉读数时，**先用已知良好的基线做对照**，
   再决定「是代码坏了还是探针坏了」。
```

#### ④ 窗口标题是 **Dart 侧** `MaterialApp(title:)` 覆盖的

```text
main.cpp 里 window.Create(L"sourin_spike", ...) 只是**初始**标题；
Dart 的 MaterialApp(title: '源影') 会把它改掉。
⇒ 任何按标题找窗口的 C++ 代码，必须用**最终**标题（源影），
  否则永远匹配不上（表现为「点了图标没反应」）。
本仓实现：windows/runner/main.cpp 的 kWindowTitle = L"\u6e90\u5f71"
         （用 unicode 转义，同时满足「纯 ASCII」这条）
```

---

### ✅ P2-4：`catch (_)` 把「任何错误」说成「网络异常」

```text
轨道：C（playback-fix）    日期：2026-10-18    状态：已修（312bb04）
Owner 原话：「我刚刚测试某个视频站的插件无法登陆，提示网络异常 这也是bug」
```

**改前**

```dart
// lib/ui/widgets/provider_login_panel.dart
} catch (_) {                      // catch-all，吞掉一切
  _qrPolling = false;
  if (mounted) setState(() => _qrMsg = '网络异常，重试中…');
  return;
}
```

**实测证明那句「网络异常」是猜的**（隔离数据目录 + 真网络）

```text
qr_login_start   ✓ 440ms 真申请成功
qr_login_poll    ✓ 42ms  status=Expired（正常返回，不抛）
连打 3 次         ✓ 59/86/85ms 全 Pending，一次没抛
⇒ 网络一直是好的。
```

**影响**：用户看到「网络异常」会去查网线、换 Wi-Fi、重启路由 —— 全是白费。
这正是 Owner 第 6 条抱怨的同一个毛病：**「不知道是源的问题还是软件本身的问题」**。

**改后**：`QrPollErrorText.of(e)` 三分类（`lib/core/sourin_api.dart`）

```text
network   SocketException / TimeoutException / kind=='network' / 'network:' 前缀
    ⇒ 「网络异常，重试中…」      ← 原文案此时是**对的**，保留
notReady  核心尚未启动 / dll 加载失败 / UnsupportedError / 未绑定
    ⇒ 「核心未就绪，正在重试…」  ← 与网络无关，别让用户查网线
other     其余
    ⇒ 「轮询失败：<原文>」        ← 透传真因
只改文案，**不改控制流**（失败一次仍等下一次 timer）
```

**门禁**（`test/zz_t66_login_poll_text_test.dart` 13 条 + `zz_t66_login_poll_continue_test.dart` 6 条）

```text
核心是**反例组**：注入「核心尚未启动」⇒ 必须**不显示**「网络异常」。
只断言"网络异常时显示网络异常"会假绿 —— 改前的 catch-all 也满足。
撤销验证：of() 开头直接 return '网络异常，重试中…' ⇒ 6 条变红（其中 4 条是反例组）。
```

**★ 这轮抓到的第二个「假绿」（值得所有人看）**

```text
续期门禁第一版用 `indexOf('return;', catchAt)` 取 catch 块。
注入「catch 里加 _stopQrPolling()」后 —— **门禁仍然全绿**。

原因：catch 块**上方**的注释里有字面量 `return`：
      ⚠️ 这里**只改文案，不改控制流**：仍然是「失败一次就等下一次 timer」
⇒ indexOf 命中注释里那个 ⇒ catchBody 只包含注释，注入的代码落在区间外。

修法：先用正则剥掉 `/* */` 与 `//` 再取块。
修完注入 ⇒ 立刻变红。
```

**一般教训**：**扫描源码的门禁，必须先剥注释**，否则注释里的一句话就能让判据失效。

