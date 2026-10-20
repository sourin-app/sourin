# Agent Note: fake clock 里的 `pumpWidget` 会静默吞掉「真实 IO 前置」，让整组断言退化成对空树的断言

Status: implemented

独立于 [three-causes-of-a-red-test](2026-10-19-three-causes-of-a-red-test.md)：
那篇给的是**红的分类法**（漂移 / 仪器失效 / 真缺陷）；
本篇是**第四种形态**——测试**代码本身完全正确**、产品**也完全正确**，
红的原因是**仪器没有驱动真实 IO**，而且它表现为「前置断言失败」，
看上去像产品缺陷。

## Problem

`test/t75_browse_autoload_test.dart` 全量跑 **9 条红**，且第一条的前置断言就红：

```text
Expected: <20>
  Actual: <0>
★ 前置：第 1 页必须真的进来了（实测 0 条）—— 不成立的话下面"没有按钮"就是对空树的断言
```

产品侧 `BrowsePage` 的注入点是对的（`pageLoaderForTest` 走构造参数，
`browse_page.dart:163` 在 `initState` 里、`_init()` 之前就位）。
夹具也对。**但 `_load(1)` 从未被调用。**

### 根因（探针实测，`zz_t75_probe_why_zero.dart`，已删）

```text
pumpWidget 之后 loaderInvoked=0   calls=[]
pump1 之后    loaderInvoked=0   calls=[]
pump2 之后    loaderInvoked=0   calls=[]
pump100ms 后  loaderInvoked=0   calls=[]
runAsync 后   loaderInvoked=1   calls=[1]   debugItemCount=20
              ↑ 同一时刻才打印 `[BROWSE] 取分类失败（不影响列表）`
```

`browse_page.dart:241` 的 `_init()` 第一句是：

```dart
final c = await SourinApi.getCategories(widget.provider);
```

它走 `SourinCore.callAsync`（**真 FFI**）⇒ 返回**真实** `Future`。
而 `tester.pump()` 只推进 **fake clock**，驱动不了真实 IO
⇒ `_init()` 停在那一行 ⇒ 后面那句 `await _load(1)` **永远执行不到**。

★ **最阴险的一层**：这句 `getCategories` 外面包着 `try/catch`（注释写「无分类不影响列表」），
所以它**不会报错**，只会**静默**让 `_init()` 永不继续。
测试看到的现象只有「条目数 = 0」，与「产品没加载」**完全同形**。

## Decision

**把 `pumpWidget` 本身放进 `runAsync`，并轮询到前置条件真的成立。**

```dart
await t.runAsync(() async {
  await t.pumpWidget(...);              // ← 关键：创建 Future 时已在真实时钟里
  for (var i = 0; i < 50; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 10));
    await t.pump();
    if (st.debugItemCount > 0) break;   // 轮询，不用固定帧数
  }
});
```

三条配套决定：

1. **`pumpWidget` 必须在 `runAsync` 内部**，不能先 `pumpWidget` 再 `runAsync` ——
   Future 已在 fake clock 环境里创建，之后进 `runAsync` 也救不回来。
2. **轮询而不是固定 pump 次数**：`getCategories` 的真实 Future 多久返回
   取决于 FFI 失败的快慢。固定次数在快机器上碰巧能过、慢机器上就红 ——
   那种绿不可信（本仓「判据输出必须能区分『查了没问题』与『没查』」那条）。
3. **给 `mount()` 加 `awaitFirstPage` 开关**：D1 竞态 / D2 换分类两条用例的
   语义**就是**「第 1 页还没回来」（loader 故意挂在 `Completer` 上）。
   在 `mount()` 里等它 = 等一个永不完成的 Future。
   这两条传 `false`（只驱动 3 次真实 IO 让 `getCategories` 过去），
   然后**在 `runAsync` 内**完成自己的 `gate[1]`。
   ★ 它们原本的 `gate[1]!.complete(...)` 在 `runAsync` **外**执行，
   而 `gate[1]` 是 `_load(1)` 被调用时**才创建**的 ⇒ 那时还是 null。
   这是第二个独立的坑，只修 `mount()` 会剩 2 条红。

## Alternatives considered

**A. 给 `getCategories` 加测试注入口（`debugSetCategoriesLoader`）**
否决：要在产品里再加一个 `@visibleForTesting` 口子，而 `BrowsePage`
已经有 `pageLoaderForTest` + `debugSetCategories` 两个。
第三个口子只为绕过时钟问题，是**把测试基建缺陷写进产品 API**。
`runAsync` 方案零产品改动。

**B. 改 `_init()` 让 `getCategories` 不阻塞 `_load(1)`（并行化）**
否决：这是**产品行为改动**，而且会让「分类先到 / 列表先到」的时序
变得不确定 —— 现有 C1「内容不满一屏也要能取到第 2 页」依赖当前顺序。
修测试不该动产品语义。

**C. 把断言改成 `expect(st.debugItemCount, 0)` 或删掉前置**
否决：那是把红改成**假绿**。前置断言正是这个文件的精华
（注释原文：「不成立的话下面"没有按钮"就是对空树的断言」）。
它红得对 —— 错的是仪器。

## Consequences

**收益**：9 条红 → 0，且**没有放宽任何断言**（前置断言原样保留，现在真的成立了）。
产品代码**零改动**（`git status --porcelain lib/ui/browse_page.dart` 为空）。

**故障注入（两条，证明断言承重）**：

```text
注入①  注释掉 browse_page.dart:_onScroll 里的 _maybeLoadMore()
        dart analyze → 0 error ；git diff --stat → 2 insertions(+), 1 deletion(-)
        ⇒ +11 -4，红在 B1[阳性对照] / B2 / D1[竞态] / D2 —— 全是依赖自动加载的
注入②  夹具里 pageCount: 5 → 1（14 处，模拟"上游只有一页"）
        dart analyze → 0 error
        ⇒ 红在 B1 / C1 / D1 / D2 —— 与注入①的红集**不同**，说明判据分辨的是语义不是形式
还原    sha256 回 08c94dae… ；git status 空 ；+15 全绿
```

**这个坑会反复出现，判据是**：
```text
凡「页面该完成异步工作却一直 loading / 一直是 0 条」，
先问「这个 Future 是在哪种 clock 里创建的」——
而不是先怀疑产品。
```

### 第二个实例：`t80a_skeleton_fade_test.dart`（2026-10-21，同一根因 + 一个叠加层）

`test/t80a_skeleton_fade_test.dart` 的**浏览页**那两条红：

```text
★★ 浏览页：轮询 61 帧仍未挂载 `FadeInSliver` —— 探针前提不成立（分支没走到），不是"动画没播"
★★ 浏览页/ReduceMotion：同上
⇒ +2 -2
```

**它与 `t75` 是同一个根因，但有两个值得单独记下的差别。**

**差别一：产品侧的注入口早就有，是测试**没用**它。**

```text
t75 是「用了 pageLoaderForTest，但被 getCategories 卡住」；
t80a 是「**根本没用** pageLoaderForTest」⇒ `_load` 走真 FFI。
```

`BrowsePage` 的 `pageLoaderForTest`（`browse_page.dart:76`）文档里**逐字写着**
为什么必须用它（「挂载后再注入就已经晚了」），而 `t80a` 一直传 `const BrowsePage(...)`。
⇒ 判据：**同一页面被两个测试文件测时，后写的那个容易绕过既有注入口。**
发现方式：把 `_load` 的 loader 选择点（`browse_page.dart:264`）读一遍，
看它有几个分支、测试走的是哪一个。

**差别二：原注释描述的路径与代码不符（这才是它长期没被发现的原因）。**

`t80a` 文件头原文写的是：

```text
浏览页：靠 addPostFrameCallback(_init) → await FFI(必抛) → **finally** setState
```

而 `_init()` **没有** try/finally：

```dart
Future<void> _init() async {
  if (!_isRankMode) {
    try { await SourinApi.getCategories(...); } catch (_) { … }  // ← 只有这一处
  }
  await _load(1);                                    // 裸 await
  if (mounted) setState(() => _loading = false);     // 走不到
}
```

⇒ `getCategories` 不返回 ⇒ `_loading` **恒为 true** ⇒ 永远停在骨架分支。
★ 而改前那条「第 1 帧 fadeCount == 0（骨架无包装）」的前置断言**之所以能过，
恰恰是因为这个 bug**——它靠「页面卡在骨架」才成立。
修好夹具后它会读到 1 而假红。⇒ 该断言必须换成
「用**永不完成的 loader** 单独确认骨架分支不包淡入」，不能挂在 `pumpWidget` 之后读。

**修法（与 t75 同款，两处一起）**：

```dart
await t.runAsync(() async {
  await t.pumpWidget(host(BrowsePage(
    provider: 'demo', title: '电影',
    pageLoaderForTest: (p) async => Page<MediaItem>(items: const [], page: 1, pageCount: 1),
  ), kViewport));
  for (var i = 0; i < 12; i++) {
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await t.pump();
  }
});
```

**读数（修前 → 修后）**：

```text
修前  +2 -2
修后  +4 -0     ← 两条浏览页用例都真的挂到了 FadeInSliver 上
阳性对照  t=0 / 45 / 90 / 150ms  opacity = 0.000000 / 0.344143 / 0.629058 / 0.905922
阴性对照（disableAnimations）     全部 1.000000（最小两两间距 = 0）
```

**故障注入（两条，证明夹具修复与断言都承重）**：

```text
注入 P   fade_in_sliver.dart 的 dur 改 Duration.zero（模拟"动画根本没播"）
         dart analyze → 0 error
         ⇒ +2 -2（**两条都红**：搜索页 + 浏览页）⇒ 断言分辨的是"动画播没播"，不是形式
注入 Q   把空态分支那段 runAsync 换回普通 await（模拟未修状态）
         dart analyze → 0 error
         ⇒ +3 -1（红在浏览页阳性对照）⇒ **runAsync 是必需的，不是装饰**
还原     fade_in_sliver.dart 的 git status 空、INJECT 残留 0；+4 全绿
```

★ 注入 Q 的意义：它证明「注入 loader」与「放进 runAsync」是**两个独立必要条件**，
少任何一个都红。这也解释了为什么只补 loader 不够。

**何时该翻案**：同本篇正文末尾那条 —— 若将来 `flutter_test` 能驱动真实 Future，
`runAsync` + 轮询可换成更干净的写法。
届时 `t75` 与 `t80a` 两处要一起换（判据：两处都不再需要 `runAsync` 且注入仍能红）。

**何时该翻案**：若将来 `flutter_test` 提供了「fake clock + 真实 IO 混合」
的标准做法（例如 `tester.pumpAndSettle` 能驱动真实 Future），
`runAsync` + 轮询这套可以换成更干净的写法。
判据：升级 Flutter 后重跑本文件的注入①，若注入①仍能红且不需要 `runAsync`，
就换掉。
