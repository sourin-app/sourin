# Agent Note: 网盘分享链接预检接到线路面板（T1b 接线①）+ appget 静默失败收口

Status: implemented

Independent: 兑现 [2026-10-31-tvbox-pan-check-precheck.md](../feature/2026-10-31-tvbox-pan-check-precheck.md)
（Rust 命令 tvbox_pan_check 已建好，但 Dart 侧**零消费点**——本批 T5 就是
"功能加了、用户一行都看不到"，本篇是同一类风险的收口）。

## Problem

Rust 侧 `tvbox_pan_check`（零凭据预检：ok/locked/bad/uncertain/unsupported）已
提交并带门禁，但全 lib grep 无消费点 ⇒ **用户完全感知不到**。
线路面板原本只有"疑似样片 (m:ss)"一种行级标注，没有死链/需提取码的提示
⇒ 用户必须点进去才知道链接是死的。

## Decision

```text
① SourinApi.panCheck 封装（items 序列化成字符串传，配 debugPanCheckFetcher
   注入口；未知/缺失 state 一律落 uncertain —— 不抛、不猜）。
② isPanShareUrl 纯函数：host **边界匹配**（精确相等或以 . 为后缀），
   不用 contains（evil-quark.example.com 必须不命中）。覆盖网盘族全集，
   "要不要标"由 Rust 的 state 决定，Dart 不猜哪家支持。
③ _armPanPrecheck 收口到 **_streams 的 4 个赋值点**（_load / _reload /
   _adoptLiveChannel / _resolveAndPlay）——漏一处就是"换源后没预检"的漏网。
   fire-and-forget：预检只做标注，**绝不阻塞起播**（1.3 定下的硬约束）。
④ _StreamSheet 加 panStateOf 回调：bad ⇒ 置灰 + summary + 不可点；
   locked ⇒ 徽章「需提取码」但**仍可点**（locked 不等于死，用户有码就能播）；
   uncertain / ok / unsupported ⇒ 不标注。
⑤ 代次 _panCheckGen：换集/换台/换源作废在途结果，防"A 集结果错标到 B 集"。
⑥ appget 类源静默失败：取数出口若 list.isEmpty 或 StreamPreparer.lastDroppedCount>0
   ⇒ 落一行 AppLog（provider + id 前缀 + 空列表标志 + 摘除条数 + 脱敏原因）；
   同类失败同集只记一次（防刷屏）。
```

## Alternatives considered

- **硬接换源弹层**：它渲染的是搜索命中条目（MediaItem 只有 id/title/note，
  **没有 URL**），而预检输入是 URL ⇒ 无处可接，硬凑就是"接线了但没真接"。否决。
- **用预检结果改默认选线**：bad 判定是异步的，起播那一刻拿不到 ⇒ 用未就绪
  数据做决定。否决（只做标注）。
- **把 appget 的摘除判据一起改**（第三方播放页该"标需 parse"还是"摘掉"）：
  在 `stream_prepare.dart`，不在本次归属；且会牵动既有候选语义。立下批项，否。
- **预检失败静默**：静默失败=缺陷。改为"吞掉但留痕"（AppLog）。

## Consequences

- 全量 `flutter test` **5576 / 0 失败**（本批基线曾 `-6`）；analyze errors=0。
- 两组新门禁：接线层 `t20261101_pan_wiring_test` 12/12（全量默认真跑），
  行为层 `t20261101_pan_line_precheck_test` +15（native-media 标签）。
- **证红 21 条全红**，其中 3 条是"把代码**注释掉**（不删）"——本批踩过两次
  的那条缝（contains 匹配注释 ⇒ 注入后竟绿），现已堵死，并留了仪器自检用例。
- 门禁帮我抓出的 3 个真缺陷（都修了）：
  ① `_armPanPrecheck` 把 `++_panCheckGen` 写在早退之后 ⇒ 旧集在途结果照旧落地
     （正是要防的错标）；改为早退前先抬并加单测钉顺序。
  ② 留痕账自伤：clear() 后 add(key) 的返回值把本集第一次调用挡掉 ⇒ 留痕整体失效；
     改为 key 集合语义（key 含 provider+contentId，天然按集分家）。
  ③ `zz_t33 ④` 的窗口（±2000/800 字符）被我在 subtitle 三元里内联的分支挤爆
     （delta=1335>800）；提局部变量解决，且**函数必须放在 _StreamSheet 之后**
     （放前面时窗口落函数周围，delta=11502）。
- 按裁决更新 `zz_t33_drm_ui_verify_test` 两条字面为
  `s.isPlayable && !isPanDead`（**更严**：DRM 与死链同归不可点），
  并**加一条反向断言**禁止退回旧字面——防止"为了让全量变绿而放宽判据"。

## 边界（如实）

- `stream_prepare.dart` 的摘除判据**一字未动**（下批项 N1），并有"不许动"的
  边界用例守着。本批只收静默失败（留痕）。
- `zz_t33 ④` 的窗口仍是**硬编码字符数**——将来有人在 subtitle 附近加分支还可能
  挤爆（本次已踩）。是否改为按行号/结构定位，下批定。
- 未做真机验证（按分工，lead 在批末统一部署后验收）。
