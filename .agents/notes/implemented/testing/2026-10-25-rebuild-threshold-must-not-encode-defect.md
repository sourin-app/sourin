# Agent Note: 重建计数阈值不许按缺陷态标定（顶栏「看得见点不到」的连带）

Status: implemented

## Problem

`zz_t66_n11_bottombar` 的 T4/T5 用**总重建数**当阈值（`all < 200`、`_all <= 2`），
而这两个数是按**缺陷态**量的：当时 `_autoHideNow()` 漏了 `_pushControlsLive()`，
鼠标叫回时广播被守卫早退 ⇒ 顶栏**一次都不重建** ⇒ 8 轮 `all=20`。

于是修复那个缺陷（补 1 行 `_pushControlsLive()`）之后，每次隐藏也会通知，
顶栏子树（≈69 元素）每轮重建一次 ⇒ 8 轮 `all=576` ⇒ **门禁红**。

这不是"修复引入了性能回归"，而是**阈值把缺陷行为编码成了基线**：
门禁测的是"数字小"，不是"整页不重建"。

## Decision

重建计数**按来源四分**，并让**两个方向**都有判据：

```text
_page       e.widget is PlayerPage          —— 整页重建
_topBar     e.widget 的祖先 runtimeType == '_TopBar' —— 顶栏子树
_animation  e.widget is AnimatedBuilder     —— fade 动画自身（每帧本来就会跑）
_other      其余
```

- **T4（8 轮 隐藏→叫回）**：`page == 0`、`other < 40`、**`topBar >= 8`**（每轮至少一次）。
  最后这条是"通知缺失"方向的牙：**广播不发 ⇒ 顶栏该重建没重建 ⇒ 箭头看得见点不到**。
- **T5（静置帧）**：`page == 0`、`topBar == 0`、`other == 0`；`animation` 允许 >0 且不设上限。
- 旧的 `all < 200` / `_all <= 2` **删除**，并在注释里写明：旧阈值按缺陷态（20）标定，
  2026-10-25 修正；`topBar == 0` 与 `page == 0` 是不同层级、缺一不可。

产品侧的修法同样只有一行：`_autoHideNow()` 的 `setState` 之后补 `_pushControlsLive()`
（读新值，故必须在 setState 之后）。机制是**视觉真源与命中真源分裂**：
隐藏走 `setState`（`visible=false` 落地），显示走广播且被
`if (_controlsLive.value == _controlsVisible) return;` 吃掉 ⇒ 顶栏不重建，
而 `_applyControlsMotion()` 仍把 fade 推到 1.0。

同批还修了 `keyM` 缺 `_anySheetOpen` 门控（浮层打开时按 M 会静音后台播放器，
而焦点在页外时被全局门控挡住 ⇒ 同一个键两种语义）。

## Alternatives considered

1. **把阈值从 200 放宽到 800**（最省事）。
   这是"跟着实现改期待值"的标准形态：它保住了红变绿，却把"整页重建"这个真正的
   不变量彻底丢掉 —— 下次有人把通知改成整页 `setState`（实测 `page=8`、
   `other=3648`、p50 48.7ms），800 依然绿。**否决**。
2. **只保留 `topBar >= 8`（去掉 `page == 0`）**。
   那会放过"通知发得太狠"：整页重建也满足 `topBar` 增长。**否决**，两个方向必须分开。
3. **重构成"只重建 IgnorePointer/Opacity 那一小块"**，让重建量回到 20 附近。
   方向正确但代价不成比例：要给顶栏拆出局部 notifier，属独立一轮的工作，
   而当前 544 是"顶栏子树整体重建"（每次隐藏/叫回各一次），在预算内。**本轮不做**，
   若将来要压，这条是入口。
4. **给 `zz_t66_n11` 加白名单豁免**。
   豁免会让"顶栏点不到"这个缺陷重新变成无人看守。**否决**。

## Consequences

- 收益：门禁现在**测量"哪个层级被重建"而不是"总数大小"**，两个方向都可证伪
  （注入 A 广播空操作 ⇒ `topBar=0` 红；注入 B hover 整页 `setState` ⇒ `page=8` 红）；
  顺带把"fade 动画每帧跑 AnimatedBuilder"从"违规"里摘出来，不再需要一个拍出来的上限。
- 代价：`topBar >= 8` 依赖"每轮隐藏→叫回确实发生"这一前提；若将来某个平台不做
  auto-hide，这条会在那个平台上红 —— 那时应加平台门控而不是调阈值。
- 代价：新门禁 `zz_t1024_chrome_autohide_hittest` **不带 `native-media` 标签**
  （否则默认全量会 skip，等于不存在），代价是它会偶发 `did not complete`
  （libmpv 原生崩溃，本仓已知），复跑即可；不许为了躲它把标签加回去。
- 相关：`zz_cr_backbtn_backarrow ②` 只覆盖**错误态**且带 native-media 标签 +
  `_requireLibmpv()` 跳过，所以它替代不了上面这条非错误态门禁 —— 两条都要留着。
- 部分重叠（互链，不归档）：[2026-10-18-bottom-bar-unmount-per-hover.md](../../bug-fix/2026-10-18-bottom-bar-unmount-per-hover.md)
  讲的是"底栏在 hover 时不该卸载"的**行为**约束；本篇讲的是**测量方式**——
  同一个重建量必须按来源拆开，否则阈值会把缺陷态当成基线。两篇并存：前者守行为，本篇守仪器。

## Testing

- `zz_t66_n11_bottombar` **+6 绿**；三组读数：
  正常 `page=0 topBar=544 animation=260 other=12`；
  注入 A（广播空操作）`topBar=0` ⇒ EXIT=1；
  注入 B（hover 整页 setState）`page=8` ⇒ EXIT=1。
- `zz_t1024_chrome_autohide_hittest` **+2**（判据是 `inHitPath`，不是"矩形存在"或"可见"
  —— 后两者在缺陷下都是 true）、`zz_cr_backbtn_backarrow` **+7**、
  `zz_t1024_player_live_keys` **+4**（含 M 浮层门控；注入删门控 ⇒ 红）、
  `t118_control_bars_link` **+16**。
- 全部注入恢复后 `diff -q` 逐字节一致。
