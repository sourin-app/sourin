# Agent Note: 首页液态玻璃选择器单源显示 —— 补吸附头 extent 闸门（漏改收尾）

Status: implemented

Independent: 接续 [2026-10-31-liquid-glass-selector-unify.md](2026-10-31-liquid-glass-selector-unify.md)
（本篇是它的收尾：那一篇删了 SourceBar 的单源早退，却漏了宿主的第二道闸门，
真机判读才把它抓出来）。

## Problem

Owner 需求（2026-10-31 逐字）：「首页就算只有一个源也要显示那个液态选择的」。
前一篇删掉了 `source_bar.dart` 的 `if (sources.length <= 1) return SizedBox.shrink()`，
单源配置下首页**依然看不到任何玻璃条/药丸**——真机截图（.probe/shots/
batch-20261031/13-home-top.png）显示「我的」分段控件下方直接是 shelf。

### Root cause（两道闸门，只改了一道）

```text
闸门①（已改）source_bar.dart：单源早退 return SizedBox.shrink()
闸门②（漏改）home_page.dart:2791
    static double extentFor(int visibleCount) => visibleCount <= 1 ? 0 : _extent;
    ⇒ 单源时 extent=0 ⇒ SliverPersistentHeader 高度压成 0
      ⇒ SourceBar 即使渲染也完全不可见（widget 查找直接 Found 0 SourceBar）

帮凶：home_page.dart:2573 / :2772-2773 的注释仍写旧语义「源少于 2 个时那条返回
      SizedBox.shrink()」⇒ 改闸门①的人据此以为没有第二道门槛。

## Decision

① extentFor 改判：`visibleCount == 0 ? 0 : _extent`（0 个源才隐藏；1 个源照常占位 60）。
② 四处旧语义注释改判为 Owner 新口径，并在 :2573 写明"这条旧注释就是漏改的帮凶"
   + 双向对齐纪律（删早退必须同时改 extent，只改一半 ⇒ 宿主压成 0）。
③ 门禁钉到**生产那一个对象**：新增 @visibleForTesting `debugStickySourceBar(...)`，
   返回生产 delegate。理由：source_bar_test.dart 里的 `_TestHeader` 是**复刻品**——
   产品把 extentFor 改回 `<=1?0` 时复刻件照样绿，事故正是这么发生的。
④ 新门禁三条腿：静态钉 extentFor 逐字形状 / 生产 delegate 单源 minExtent>0 且==60
   且 build 走 Padding 分支 / 真挂载读 RenderSliverPinnedPersistentHeader.geometry
   （paintExtent>0 且 layoutExtent<=paintExtent，兼作非法几何哨兵）。

## Alternatives considered

- **只删闸门①就交付（前一篇的做法）**：组件侧测试全绿、真机零玻璃条——正是本次事故。否决。
- **给宿主加"单源时给个最小高度"的特例分支**：又多一处判据，且与 extentFor 的语义分叉（将来再改又要动两处）。收敛成 `== 0 ? 0` 一条判据。否决。
- **只在 UI 侧兜底显示占位**：等于永远显示一条没有源可切的条，不是 Owner 要的"显示那个液态选择器"。否决。
- **只加一条 widget 断言**：现有断言钉在复刻品 `_TestHeader` 上没牙；必须钉生产对象。否决。

## Consequences

- 证红两次、方向相反：① 改产品**之前**跑 ⇒ 3/5 红（minExtent=0.0 / Found 0 SourceBar）；
  ② 修完**之后再注入** `<= 1 ? 0` ⇒ 同样 3 条红、读数逐字一致；两次都覆盖
  「漏改前」与「漏改被回滚回来」，随后还原并复核。
- 读数：六个测试文件 +72 全绿（单跑/合跑均 All tests passed），analyze errors=0。
- 未闭环（如实）：只在 widget 测试里量了几何，单源玻璃条的**真机观感**待批末
  部署后出证后截图确认（改前截图是 13-home-top.png）。

## 教训（通用）

**一个"隐藏"行为常常有两道闸门（组件自身 + 宿主布局）。改一半是最危险的假绿：
组件侧测试全绿、真机什么都没有。** 凡是"某条件下不显示"的需求翻转，必须
grep 全部相关 extent/height/visibility 判据，且门禁要钉生产对象而非测试复刻件。
