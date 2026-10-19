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
