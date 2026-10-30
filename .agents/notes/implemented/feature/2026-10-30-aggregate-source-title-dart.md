# Agent Note: 播放源显示「TVBox 聚合(<备注>) · <label>」（Dart 半边）

Status: implemented

Independent: Rust 半边（TvboxAggregate::resolve 给 StreamCandidate.label 填
「<子源显示名> · <线路名/分享页文件名>」）归 rust-core（task-4）；本条只管
**展示位**——label 到位前后本条都成立（label 为空时退化为只显示聚合名）。

## Problem

Owner 验收②（现场反馈批次任务2）：播放页顶部与换源列表要能看到
「TVBox 聚合(备注) · 子源名 · 线路」。改前顶栏 pill 只显示站名（"TVBox 聚合"），
「线路/清晰度」抽屉行只显示 `displayName`（裸线路名）——
聚合源下用户既不知道自己给聚合起过什么名，也不知道这条线路来自哪个子源。

## Decision

```text
① 纯函数 aggregateSourceTitle({note, label})（player_page.dart 顶层，@visibleForTesting）：
   · note 空/未配 ⇒ 不画括号（绝不画「TVBox 聚合()」—— 与 TvboxAggregate.note
     "空串不显示"契约同一口径）；
   · label 空 ⇒ 只显示聚合名（流还没解析的瞬间）；
   · 非空 ⇒ 「TVBox 聚合(<note>) · <label>」。
   聚合名硬编码 'TVBox 聚合' 的依据：Rust 侧 manifest name 固定值
   （tvbox_aggregate.rs:453 `name: "TVBox 聚合"`），providerDisplayName 也是它。
② 顶栏：新 getter `_topBarSourceName` —— 非聚合源原样返回 _providerName
   （行为逐字不变）；`_provider == kTvboxAggregateProviderId` 时返回
   aggregateSourceTitle(_aggNote, _current?.label)（label 取**正在播**的那条流，
   候选行的拼接归抽屉）。_TopBar 的 providerName 实参改读它。
   顶栏只回答"现在在看哪条"；它取 _current 而不是 _streams[i]，是语义不是偷懒。
③ 抽屉：_StreamSheet 新增 `String? aggregateNote` 参数（null = 非聚合源，
   行为与改前逐字一致）；非 null 时行标题 = aggregateSourceTitle(note, s.displayName)。
   构造点按 `_provider == kTvboxAggregateProviderId ? _aggNote : null` 传入。
④ 备注加载：_loadProviderName 里当 id == 聚合源时顺带调 SourinApi.tvboxAggregateGet()
   （sync 命令，零网络），失败 catch 归空串（装饰性信息不许拖垮站名加载）；
   代次保护与站名同款（发起时 id 对不上当前 id ⇒ 丢弃）。
   换源会改 _provider ⇒ 备注跟着会话走，不只在 initState 读一次。
⑤ kTvboxAggregateProviderId = 'tvbox_agg'：home_page.dart / settings_page.dart
   已各有同值常量（同样的不跨页面 import 纪律），本文件照先例自带一枚。
⑥ 门禁探针 debugPlayerSetAggregateTitleForProbe({note, current})：
   直灌生产 state（FFI 在 flutter_tester 里加载不了，task-72 同一纪律）。
```

## Alternatives considered

### A. 聚合名用 providerDisplayName(_provider) 动态取

最强理由：Rust 改名时前端零改动。

否掉的原因：显示名加载是异步的，顶栏会出现「先空后跳」；且 Rust 侧该名字是
**写死的常量**（tvbox_aggregate.rs:453），动态取没有真实收益，只多一条时序。
门禁钉住字面量，Rust 真改名时门禁会红（契约变更可发现）。

### B. 只改顶栏，抽屉行保持裸 displayName

否掉的原因：Owner 验收②明确点名"播放页顶部**与换源列表**"两处；
且聚合源下"这条线路来自哪个子源"正是抽屉里最需要的信息
（20 秒样片线路（1.3）也靠 label/备注帮用户识别）。

### C. 备注/ip 另开一个 pill

否掉的原因：顶栏宽度有限（站名 pill 已限 180px），信息密度上去只会互相挤压；
拼进同一枚 pill 与 Owner 指定的文案形状逐字一致。

## Consequences

**收益**
- 聚合源：顶栏与抽屉行都显示「TVBox 聚合(备注) · 子源 · 线路」；配备注后一眼可辨。
- 非聚合源路径**零变化**（行标题、顶栏 pill 都走原分支，门禁 ③ 钉住）。

**代价与边界**
- Rust label 未落地（task-4 完成）前：label 为空 ⇒ 顶栏显示「TVBox 聚合(备注)」、
  抽屉行显示「TVBox 聚合(备注) · <quality/kind 兜底>」——比改前多前缀、不缺信息。
- 备注读取失败（旧 DLL）⇒ 空串 ⇒ 不画括号，行为同"没配备注"。
- 已知仪器坑（如实记录）：flutter_tester 里加载 libmpv 偶发 c0000005
  （player_panel_wiring_test.dart 文件头有完整证据链）——多文件同跑偶现
  "did not complete"，分开跑即绿；本文件与 t72 都依赖夹具，缺夹具 skip 不假红。

## 验证结果（已发生）

```text
门禁：test/t20261030_agg_source_title_test.dart → 5 passed
  ① 纯函数 3 条（空 note 不画括号 / 非空画括号 / label 拼「 · 」与空白 trim）
  ② 真树 tvbox_agg：顶栏 pill = 「TVBox 聚合(我的聚合) · 子站A · 线路1」；
     抽屉当前行同串、候选行（子站B）带前缀；裸 displayName 不许出现
  ③ 真树 cctv：行标题「主线」原样、前缀一个字不添（就算误注入了 note）
  夹具：真 PlayerPage + debugPlayerSetStreamsForProbe /
  debugPlayerSetAggregateTitleForProbe / debugPlayerClearErrorForProbe
回归：test/t72_stream_sheet_test.dart → 11 passed（清晰度徽章/点空白关闭无回归）
flutter analyze lib/ui/player_page.dart → 0 errors（18 条警告全为既有 probe 类）
故障注入（实测真红后恢复复绿）：
  ① _topBarSourceName 退回 _providerName ⇒ 组② 红
  ② _StreamSheet rowTitle 退回 s.displayName ⇒ 「子站B」候选行断言红
真机：等 driver-ops 驱动器就绪后批末统一截图（攒批实测纪律）。
```

## Relations

### ★ 补记（2026-10-30 批末，回归修复后的实现修正）

上面 Decision ② 的 `_topBarSourceName` getter 方案**被批末门禁甄别为回归**并已改：
task-32 的接线契约是逐字断言（调用点必须是 `providerName: _providerName,`，
"只加参数不传 = 永远不显示"，`test/task32_source_name_test.dart` ③ 与
`test/zz_cr_local_session_player_test.dart` F1），getter 方案把它弄断了。

现行实现：删除 getter，调用点恢复逐字接线；聚合复合串改在**写入点**算 ——
新私有方法 `_refreshAggregateTitleInPlace()`（非聚合源 no-op），由三处调用：
`_loadProviderName`（会话/换源，`setState(() => _providerName = n);` 契约行
逐字保留、其后追加一次刷新）与 `_startPlayback`（换线路/换清晰度，label 跟
当前流走）。门禁探针同步改为走该生产刷新方法。两条契约（task-32 接线 +
任务2 聚合前缀）同时成立：task32 ③ 16 passed / F1 13 passed /
t20261030_agg_source_title_test 5 passed。

- Rust 半边（label 本体）：task-4（rust-core，quark_pick_degrade / agg_label）
- 同批选集判据公共化：[../bug-fix/2026-10-30-right-detail-line-filter-and-badge.md](../bug-fix/2026-10-30-right-detail-line-filter-and-badge.md)
