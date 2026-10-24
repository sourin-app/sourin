# Agent Note: 弹幕设置滚动边界与搜索职责拆分

Status: implemented

## Problem

弹幕设置同时承载来源、请求详情、搜索结果与显示调节，固定区域在小窗口中挤占可用高度。搜索与绑定已有播放器回调和状态，复制请求或绑定状态会形成第二真源。旧诊断绕开当前代理直接解析 DNS 和连接 TCP，并将递归解析差异当作劫持证据，和实际请求路径不一致。

与既有决定的关系（部分重叠）：本篇是 [弹幕面板七项](../feature/2026-10-19-danmaku-panel-seven-items.md) 的延续——那篇确立了面板内七个分区的存在，本篇把其中「请求详情 / 搜索 / 服务端返回」三项按第 12 项拆出到独立搜索页，其余四项留在设置弹窗。那篇保留、不归档。

## Decision

设置面板的状态、页签与内容放入同一有界滚动区域，来源配置移入高级页签。独立 DanmakuSearchPage 接收宿主 DanmakuSettingsState、BiliImportState 与现有回调，只持有关键词、选中集合和预览开关。dan-api 批量预览复用 buildBatchBindPlan，确认后仍交由宿主绑定；过期结果禁止选择与绑定。站点A 保留视频导入和分P回调，不将其编号转换成 dan-api 剧集编号。

设置页删除拆出后无调用的请求、搜索、错误详情私有区块。来源搜索入口只触发 onOpenSearch。诊断调用共享 diagnoseDanmakuEndpoint，保留 mounted 与请求序号守卫；兼容 dohLookup 委托 lookupDanmakuDoh。HTTP 可达不代表协议探活成功，递归解析差异不直接判定劫持。

## Alternatives considered

### 保留设置内搜索与独立页面双入口实现

未采用。重复搜索结果渲染与状态同步容易漂移，且未解决小窗口固定区挤占高度的问题。

### 页面自己请求并维护绑定状态

未采用。播放器已有 onSearch、onPickMatch、onBatchBind 和 站点A 导入链路，页面复制网络与绑定逻辑会形成第二真源。

### 用 dan-api 批量绑定替代 站点A 批量预览

未采用。两种渠道的身份与分集映射不同，当前页面只实现 dan-api 批量预览；站点A 批量预览仍是明确缺口。

## Consequences

设置内容可在小窗口滚动，搜索 UI 与网络及绑定状态分离。宿主必须在同一更新树中实际挂载独立页面，否则页面不可达。播放器接线由 player-fixes 负责，当前记录不代表集成验收完成。默认全来源、用户明确关闭保留与聚合行为仍由原有配置及聚合层负责，本次未修改 core/danmaku.dart。

## Verification

- SDK C:/Users/iuuuuuuuu/flutter/bin/flutter.bat 已验证存在。
- 设置拆分源码契约测试旧实现缺少 onOpenSearch，退出 1；修改后退出 0。测试自身区间定位曾出现 RangeError，修正后通过，该夹具错误不作为产品旧红证据。
- flutter test test/zz_t1028_danmaku_search_page_test.dart test/zz_t1028_danmaku_search_contract_test.dart --reporter compact：退出 0，3 项通过，覆盖双渠道回调、预览确认和过期结果禁用。
- flutter test test/zz_t1028_danmaku_small_window_test.dart --reporter compact：退出 0，420x360 布局构建、切高级与滚动无异常。
- flutter analyze lib/ui/danmaku_search_page.dart lib/ui/widgets/danmaku_settings_dialog.dart：退出 0，No issues found。
- 未运行全量测试，未提交推送发布，未重启客户端。无 profile 或原尺寸截图证据，不宣称卡顿或毛边改善。
- 站点A 批量预览、播放器实际挂载与端到端集成、实网诊断仍待验收；leader 独立验收前 task-6 保持进行中。
