# Agent Note: App99 游客握手降级——胖妞/剧圈重回聚合搜索 + 搜索页左栏源切换

Status: implemented

## Problem

Owner 真机对比（2026-11-01）：参考 APK 搜《老舅》是 **69/69 全量站点返回**（左栏标"全部 69/69"，胖妞|蓝光秒播就在源清单里，33 集）；我们的实现搜《老舅》**连胖妞这个源的结果都没有**。胖妞站在配置里（频道 chips 可见），所以不是站不存在。

诊断（复用仓内 live 探针直连 Owner 真实配置，留档 `.probe/pn-diag-*.log`）：

```text
· 注册子源 110 个（Owner 口径"75 个"= 导入的 TVBox 子站），disabled 35
  ⇒ 扇出候选 74 个；扇出无站点数上限、无预算截断（10 路并发 + 单站 8s）。
· 「老舅」聚合返回 501 条 / 覆盖 43 源 —— 排除"没查到这个站"（候选含它）
  与"查到了被丢"（跨源同名合并 2026-10-28 已修）。
· 逐源直诊钉死根因：
  DIAG csp-app99-9ad89e1c（胖妞）SEARCH_ERR
       登录态不可用（userInfo 未给 user_token）
  该站对游客的 POST /app/userInfo 返回 {"code":1,"msg":"user info error"}，
  而握手把 user_token 当硬要求 ⇒ 整站 search 全废 ⇒ 从结果里整体消失。
  同症：剧圈 csp-app99-d380c3d5（同类 App99）。
```

代码级：`app99.rs` 握手第二步 `self.user_info_token(...).await?` 把 Err 传播；它后面写着"token 允许为空…先用空 token 继续让搜索去验证"的兜底是**死代码**——`?` 在它之前就返回了。而 2026-10-26 的真网实证（见文件头）早已证明：home/list/detail/play 四段链路全在**无 token** 下跑通，浏览根本不需要登录态。

## Decision

**① App99 握手对 user_token 降级获取（`app99.rs handshake`）**：userInfo 请求失败（或空 token）⇒ `log::warn` 记原因（含 host，可排障）⇒ **空 token 继续握手**；业务请求若真需要 token 而被站点拒绝 ⇒ 那是该站自己的错误，**如实进扇出 fails**——诚实容错，不猜、不编造"登录态可用"。`require_token` 仍是空值判定器（Err 语义不变），降级只发生在 handshake 层。文件头 ②③ 历史注释与 `require_token_rejects_empty` 的旧口径注释一并判对更新。

**② 搜索页左栏源切换（`search_page.dart`）**：宽窗口（内容带 ≥720px）左侧 224px 玻璃卡＝「全部 N」+ 每源一行（源显示名 + 该源条数），点击 ⇒ 右侧只渲染该源组（`_visibleHits` 纯视图过滤，不发新请求、不改排序）；窄窗口降级为顶部横向 chips；默认「全部」＝行为零变化；换词/清空/新搜索复位选中源；失败源不进左栏（`_SkippedList` 是它们的去处）。数据就是 `_hits`（已按源拆组），左栏只是同一份数据的另一种呈现。

**③ 既有门禁 scoped 化（t73/t75，第 66 轮先例）**：左栏合法改变了三条旧断言的前提，按"换参照系而非放宽求绿"更新——t73 的源名唯一性断言与几何读取限定到**结果滚动区**；t75 A1 的 ListView 禁令限定到结果滚动区**内部**（防吸顶被破坏的语义原样保留）；t75 B1 的"水平居中"不变量参照系从视口改为结果滚动区。

**④ 音海|网盘搜索不特殊分组**（Lead 裁定）：左栏本身就是"每个搜到结果的源一行"，音海有命中自然出现在左栏——与参考的呈现等价；不为单一源做特殊入口。

## Verification

```text
· 夹具单测 handshake_degrades_when_userinfo_rejected：本地真 HTTP 假站复刻
  胖妞形态（systemInit 成功 / userInfo 拒绝 / 搜索给数据）⇒ 握手 Ok + 搜索拿到条目；
  注入证红：降级改回传播 ⇒ 红，错误原文与胖妞现场逐字同款。app99 lib 14/14。
· live（真网 + Owner 真实配置）：
  - CSP_LIVE app99_live：握手 8 分类 + 搜索 19 条 + 详情/取流全链路通（空 token）；
  - live_agg_fanout_coverage 复跑：COVER csp-app99-9ad89e1c（胖妞）+
    COVER csp-app99-d380c3d5（剧圈）双双进覆盖清单（各 3 样本），
    聚合结果 4311 → 4430 条（+119 = 两站贡献）。留档 .probe/pn-verify-coverage.log。
  - Rust lib 全量 2012 passed / 0 failed（复跑）。
· 左栏门禁 test/t20261101_search_source_rail_test.dart 5/5（宽分栏切换+可逆还原、
  零命中无 UI、窄 chips、默认全量、源码门禁）；注入证红：渲染循环改回 `_hits` ⇒ 3 红。
· 搜索既有回归 t73/t75/t80a/zz_t1051 + 新门禁 50/50；analyze errors=0。
```

## Alternatives considered

- **保持 `?` 传播，只在别处兜底（如分类器/扇出层忽略该站）**——它最强的理由是不动握手协议代码、改动面最小。否决：错误发生在握手，搜索根本到不了分类器；在扇出层"忽略失败站"等于把胖妞永久藏起来；且"登录态不可用"是站点对游客的事实，捂掉它就是编数据。
- **硬凑登录态（重试 device 指纹、猜 token 字段）**——否决：无凭据不硬凑，10-26 那篇笔记已确立"覆盖口径精确到验过哪一段"的纪律；参考 APK 的 DEX 语义本身就是"字段 b 为空就空着"，降级才是对齐协议本义。
- **左栏取色走 `AppTheme.of` 语义色**——被现实否掉：它对 `AppThemeScope` 祖先有硬断言，本页既有测试宿主全都不包 ⇒ 命中一出现 21 条测试崩。改用 Material `Theme.of(context).colorScheme`（`surfaceContainerHigh` 与玻璃卡语义色是同一映射，见 AppGlassDialog 注释），页面内部保持自洽。
- **左侧做成悬浮覆盖层（不参与布局，免动旧门禁）**——否决：会遮住结果区海报列，为省两条门禁的更新牺牲真实 UX；门禁按"换参照系"更新才是对的。
- **音海特殊分组/独立入口**——否决（Lead 裁定）：参考也只是把它当左栏一行；等价呈现已达成，为单一源做特判是将来维护的负担。

## Consequences

**收益**：胖妞/剧圈两站重回聚合搜索（+119 条），Owner 可对照参考逐源查看；"浏览不需要登录态"从注释里的推测变成带门禁的行为保证；搜索页获得对标参考的源切换 UX。

**代价与边界**：

```text
· App99 类站点若某业务真需要登录态（点赞/收藏/历史），空 token 仍会被服务端拒
  ——按该站自己的错误如实透出，本修复不伪装成功。
· 三条旧门禁 scoped 化不是放水：无左栏时 scoped 查找与原样逐字节等价；
  有左栏时它们守的"结果区本体"语义反而更精确（t75 A1 仍禁结果区内 ListView）。
· 教训留档：本批一次用 PowerShell Set-Content 改无 BOM 的 UTF-8 测试文件，
  Get-Content 默认按 ANSI 误读 ⇒ 中文全部乱码、换行被吞（违反"禁 WriteAllLines
  同类"纪律）。已用完整已知内容重建。改文件一律走 edit/write 逐处工具。
· 本批历史事故：`handshake` 无条件写 `.probe/app99-known-systeminit.json`，
  假站握手冲掉真实夹具，导致 decrypts_known_systeminit_fixture_to_json 红；
  当时通过保存/恢复与 live 重抓处置。2026-11-04 实现将写出限制为显式 live
  取证且排除 loopback，普通生产握手与离线测试不再改写真实夹具。
```

相关：[App99 加密协议真实响应验收](../feature/2026-10-26-encrypted-protocol-needs-real-response.md)（覆盖口径纪律）、[聚合搜索跨源同名保留](2026-10-28-aggregate-keeps-cross-source-same-title.md)（上一轮"老舅 0 条"的另一根因）、[聚合搜索有界并发](../feature/2026-10-29-aggregate-search-bounded-concurrency.md)（扇出内核，本诊断证实其无站点数截断）。

后续：[具体集媒体解析与真实换线](2026-11-04-selected-episode-parser-and-real-line-switch.md) 修正“返回播放地址”不足以证明真实媒体的覆盖边界；本篇搜索修复不作为胖妞已真实起播的证据。
