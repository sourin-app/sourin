# Agent Note: 弹幕信息面板 N6 —— 缺省展开、绑定区逐路快照与解绑分派

Status: implemented

Current Miuix fixture targeting is specified by the
[live and binding test contract](../testing/2026-11-11-live-and-binding-miuix-fixtures.md).

## Problem

Owner 2026-10-27：「我说的弹幕来源就是这个（弹幕信息卡片），这里默认展开，然后来源、渠道、绑定的什么来源、哪一个弹幕都要显示出来，并且支持解绑。」三个缺口：

1. 点开「弹幕」徽标先见窄条，要二次点击才见全量卡片（`DanmakuInfoPanel.initiallyExpanded` 缺省 `false`，宿主没传）。
2. 展开卡片只有运行读数（来源/条数/匹配），没有「这一路绑定了哪个番剧/哪一集/哪个 id」的持久事实。
3. 没有解绑入口；解绑必须保留「本片源自带只显示不可解」的旧10 强制常开边界。

## Decision

- **缺省展开**：`DanmakuInfoPanel.initiallyExpanded` 缺省翻为 `true`。展开态右上角 × 收成窄条的能力一字未动；宿主要旧缺省就显式传 `false`。
  - **★ 2026-10-27（Lead 收口）补**：面板缺省翻面**不够**——`player_page.dart` 的宿主挂载点
    （`_DanmakuInfoPanelHost`）**显式传** `initiallyExpanded: true`。理由不是审美：翻缺省如果只改面板，
    "宿主确实要求展开"这件事没写死在调用点上，谁改回窄条都不会有人注意到。两处一起钉，改任一处都红。
- **绑定区数据不新造存储**：新增 core 快照读 `loadDanmakuChannelBinding(provider, id, episodeIndex)`，**现读**既有 `DanmakuBindStore`（`dsh.danmaku.bind.*`）；Bili 路的快照由宿主用既有的 `loadBinding(...)`（`dsh.bili.bind.*`）现取。面板通过 `DanmakuInfoData.bindings`（`DanmakuBindRouteView` 列表）收只读快照，`active`（供弹中）/`note`（无绑定说明）由宿主判定，面板不猜。
- **解绑分派**：dan-api 路清存储走 `clearDanmakuChannelBinding`（薄封装到既有 `clearDanmakuBind`，同一命名空间 `UiPrefs.remove`）；**Bili 路的解绑不进 batch_bind.dart**，由宿主直接调 `bili/bili_bind.dart` 既有的 `clearBinding`。解绑边界纯函数 `danmakuChannelUnbindable`：仅 `danApi`/`bili` 可解，`sourceNative`/`localExternal` 恒不可解。
- **四路枚举三处并存**：core `DanmakuBindChannel`、面板 `DanmakuBindRoute`、设置弹窗 `DanmakuFeedChannel` 语义同序但互不 import（面板零 core 依赖的既有纪律、core 不依赖 UI），改一处要同步其余两处（同 `_aggregateFeedLabel` 的先例）。

### must / may / never

- must：宿主每次 build **现读**绑定存储再递 `bindings` —— 缓存快照会出现「解绑了面板还显示绑着」。
- must：本片源自带永远没有解绑入口（`unbindable=false` 且门禁钉死 `dm-unbind-sourceNative` 不存在）。
- never：batch_bind.dart 不得 import `bili/bili_bind.dart` 或出现 `BiliBinding`（T113c-3 门禁钉死，两个 id 语系隔离）。
- may：`onUnbindRoute` 为 null 时面板不画解绑按钮（不画死按钮）。

## Testing

`test/zz_t1053_danmaku_info_bindings_test.dart`（19 用例）：缺省展开/显式收起、绑定区逐路（番剧/集/cid/库 id 语系区分/供弹中唯一/未绑定与 note 区分）、解绑回调携带路线、解绑后重建快照回未绑定态、core 边界四态、真实 prefs 往返的持久化证据（清后重读为空、重绑后链路仍通、清 A 路不误伤）。注入先红后绿：`.probe/n6-injectA.log`（缺省翻回 false ⇒ 「已载入」找不到，exit 1）、`.probe/n6-injectB.log`（清除改空操作 ⇒ `Expected: null / Actual: DanmakuBindStore`，exit 1）。既有 t139 / zz_t66b 簇 / zz_t66_r3 簇 / zz_t1028_danmaku_search_page / zz_t113b / zz_t113c / zz_t1028_danmaku_regressions / zz_t64 保持全绿（6 处依赖旧缺省的收起态用例显式补 `initiallyExpanded: false`，语义不变）。

### ★★★ 本轮实测抓出的门禁缺口（Lead 补，值得记下来）

```text
上面 14 条用例**全部直接构造 `DanmakuInfoPanel`** —— 它们证明"面板自己没问题"，
但**完全不覆盖宿主挂载点**。实测：把 `player_page.dart` 的
`initiallyExpanded: true` 注入成 `false` ⇒ 本文件**全绿不红**（`.probe/n6-injectC.log`，EXIT=0）。

⇒ 假绿的典型形态：被测对象有两个接入点（面板缺省 + 宿主显式传），
  门禁只钉了其中一个，另一个被改动时**没有任何读数变化**。
```

补的 `N6-host 宿主挂载点接线` 组（5 条，源码锚点级）：① 宿主必须显式传 `initiallyExpanded: true`；
② 解绑回调必须接到 `_unbindDanmakuRoute` 且真有实现、且清的是**既有**存储（`clearDanmakuBind` / `clearBinding`）；
③ 绑定明细必须走 `DanmakuInfoData.bindings`（往 Panel 构造器乱塞会直接 analyze 报错）；
④ 不可解绑那两路在宿主侧也是 `unbindable: false`；⑤ 阴性对照：宿主侧不许残留窄条缺省写法。

补完后**同一个注入**从"假绿"变成 **2 条红**（`.probe/n6-injectC2.log`）；恢复 19 项通过、退出码 0
（`.probe/n6-t1053-final.log`）；相关回归 41 项通过、0 真断言失败（`.probe/n6-host-wiring.log`）。

> 为什么只能是源码锚点：宿主是 `_PlayerPageState`（私有 State），展开态依赖真播放器
> （native-media）与内部 `_danmakuInfoOpen`，普通 widget 测试构造不出"从徽标点进来"那条路径。
> ⇒ 退一档钉**调用点上的事实**，行为级判据由上面的面板用例覆盖，两者互补。

## Alternatives considered

- **宿主挂载点显式传 `initiallyExpanded: true`（计划原文写法）**：最强理由是保持面板缺省中性、语义由宿主定。被否：`player_page.dart` 是 Lead 独占文件，本执行者不许碰，改缺省能让 N6-① 在不接线的情况下立即生效；且本仓只有 player_page 一个宿主，缺省翻面影响面受控。代价：6 处依赖旧缺省的既有用例要显式补参（已做）。
- **把 Bili 路解绑也收进 batch_bind.dart 的统一分派 API**：最强理由是宿主侧调用统一、一个函数管四路。被否：T113c-3 门禁明文禁止 batch_bind.dart 出现 Bili 绑定模块的任何引用（2026-10-15 写错 id 语系导致跨服务请求必失败的教训），统一分派要么破坏该门禁、要么内联手抄 BiliPrefs 键串（违反「键都在 BiliPrefs 造」）。分派留在宿主侧，存储各归各家。
- **给 DanmakuBindStore 增加集名列以补齐 dan-api 路的集名显示**：最强理由是绑定区两路信息对齐好看。被否：改存储形状要迁移存量 JSON、违反「不新造存储」口径；集号从 `episodeIndex` 现算已够用户核对。
- **面板直接 import core 读存储**：最强理由是少一层快照结构。被否：面板文件头明文「纯展示、零网络/存储依赖，才能被单独挂载、单独断言」，那是本面板能被门禁覆盖的前提。

## Consequences

- 收益：Owner 的三个缺口全部落地；绑定区把「运行读数（来源区）」与「持久事实（绑定区）」分开回答，排错时先查绑没绑再看来了多少。
- 代价：新增三个并列枚举（core/面板/设置弹窗），改名或增删渠道时要三处同步 —— 已在枚举注释里互指。
- 代价：缺省展开后，未来任何「面板默认收起」的诉求要走显式参数，不能再依赖缺省。
- 边界：`active`（供弹中）的真值在宿主手里 —— **★ Lead 已接线**：宿主 `player_page.dart`
  的 `_danmakuBindings` 现读两条既有存储拼四路明细，`active` 由 `_infoSource`
  （`service`/`selfHosted` ⇒ dan-api 路；`bili` ⇒ Bili 路；`localDanmaku`/`library` ⇒ 本机外部路）
  与 `source != none`（本片源自带）判定。标错一路比不标更糟（同 N5b 归属纪律）。
  ⚠️ 不能拿面板的 `DanmakuAggregateFeed.label` 当 route 匹配 —— 那是**渠道类别名**
  （插件提供 / 导入源 / 本机服务 / 本地弹幕库），与"四路 route"不是一套坐标。

相关：[danmaku feeds 默认与冲突契约](../../implemented/bug-fix/2026-10-24-danmaku-feeds-defaults-and-conflicts.md)（旧10/11 的四路默认与显式冲突契约，N6 解绑边界建立在其上，未破坏）。
