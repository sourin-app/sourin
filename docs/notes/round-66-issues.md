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
**最后更新**：2026-10-18 10:40

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
