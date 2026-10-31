# Agent Note: 首页液态玻璃选择器统一 —— 单源也显示 + 渠道条药丸收编公共组件

Status: implemented

Independent: 与 [2026-10-29-restore-auto-disabled-sources.md](../feature/2026-10-29-restore-auto-disabled-sources.md)
（聚合源启用策略）相关但正交——那篇管"哪些源参与"，本篇管"源与渠道条长一个样"。

## Problem

Owner（逐字）：「首页就算只有一个源也要显示那个液态选择的，然后 tvbox 聚合源下面
的也要跟那个液态玻璃选择的样式一样，这里样式都不一样，要优化和矫正。」

两处现状：
1. `source_bar.dart` 的 SourceBar 在 `sources.length <= 1` 时整条隐藏
   （原版 SourceBar.vue 行为）——单源用户看不到选择器。
2. 聚合渠道条 `_AggChannelRail` 外层玻璃容器 R2-#4 已统一，但药丸本体是
   框架 `ActionChip`（描边胶囊）——与 SourceBar 的无描边透明高亮药丸不同套视觉。

## Decision

```text
① _SourcePill 抽成公开组件 SourcePill：选中高亮/圆角/字重/焦点环/失效标记/
  emoji 图标规则全部收进一个类；SourceBar 与 _AggChannelRail 都构造它
  ——"改一处两处同变"由结构保证，不是复制参数。
② SourceBar 放开单源隐藏：单源默认选中；点击重选被 _switchSource 同源守卫
  （home_page.dart:2115）短路 ⇒ 零重载，天然无害。
③ 颜色改由 Theme.of(context) 自取（不再透传 ColorScheme）。
```

## Alternatives considered

- **只给 ActionChip 换皮（改 side/elevation 参数）**：样式参数复制一份，
  下次改药丸要记得改两处——迟早漂移。否决。
- **单源继续隐藏、UI 上显示"仅一个源"文字**：Owner 明确要选择器本体。否决。
- **渠道条整条换成 SourceBar**：渠道条数据形状（频道/节目）与源条（源）不同，
  语义不同组件不同；只统一"药丸"这一视觉单元。否决。

## Consequences

- 门禁：新增 test/zz_source_pill_unify_test.dart（单源渲染 widget 断言 +
  去注释后的静态契约：渠道条必须 `SourcePill(` 且不得 `ActionChip(`、公共件
  唯一公开、私有旧件已删——防"注释当实现"）；两条注入证红真实执行
  （加回单源早退 ⇒ 红；渠道条改回 ActionChip ⇒ 红）。
- 4 处既有断言按 Owner 改判翻转（source_bar_test / provider_enabled_test 的
  "单源隐藏"⇒"单源也渲染"，其中 provider_enabled 反而加强）。
- 复核（互检）：fix-t73-search-gate 六项复核全过（公共性/单源行为/翻转正当性/
  门禁有效性含只读等价注入证明/越界/读数核对），无 P1/P2。
- 真机判读：单源配置出玻璃源条且默认选中；渠道条与源条同款。待批末部署后做。

## 边界（如实）

- source_bar.dart 文件头 BOM 被顺带移除（lib/ui 顶层 24 文件本就无 BOM，一致）。
- 单源"点击重选"依赖同源守卫短路——若将来守卫被移除，重选会触发重载
  （zz_source_pill_unify 的单源用例盯着渲染，不盯守卫；守卫有自己的测试）。
