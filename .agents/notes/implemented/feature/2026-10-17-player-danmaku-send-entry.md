# Agent Note: 播放页弹幕发送入口（按插件 danmakuSend 能力决定显隐）

Status: implemented

## Problem

Owner 第 2 条后半句：「发送入口由插件决定能否发送」。

Lead 逐层核实后发现**整条链路后端有、前端没有**：

```text
Rust 契约 danmaku_send        commands_backup.rs:124     有
模型解析 danmakuSend          models.dart:324            有
Dart API providerDanmakuSend  sourin_api.dart:1688       有
UI 输入框 / 发送按钮           全仓 grep                  0
UI 用 danmakuSend 控显隐       全仓 grep                  0
```

⇒ 不是「实现得不好」，是**用户根本看不到这个功能**。

## Decision

① 入口挂底栏正上方、右下角（与 popover 同一块）。
   底栏已有「选集/换源/设置」一排，再塞输入框会在窄窗口下挤成两行；
   右下角是画面上本来就空的位置，且与底栏同一个 `_chromeVisible` 门控 ——
   看片时不会一直杵着。

② ★★★ 不支持 ⇒ **整条不出现**，不是置灰。
   ```text
   置灰 = 「这里本来有，只是现在不能用」⇒ 暗示用户再努力一下就能用。
   而事实是这个源**没有**这个能力，再怎么努力也没有。
   ⇒ 与仓库既有原则一致：「没有的能力不假装有」
     （同 player_page 里触摸端不画快捷键按钮那段）。
   ```

③ 显隐判据 = `capabilities.danmakuSend`，**不探测插件**。
   契约（docs/PLUGINS.md:136）写明：danmakuSend 只决定入口出不出现；
   真正能不能发看插件有没有实现 `danmakuSend()`。两者**可能不一致**。
   所以不能靠「试着发一次」决定显隐 —— 那会在用户还没输入时就打一次上游。

④ ★ 判据抽成**顶层函数** `danmakuSendAllowed(providers, id)`，供单测直接调用。
   ```text
   第一版把它留成 State 私有 getter，测试只能**自己重写一遍**同样的逻辑。
   然后做故障注入（把判据写死成 true）—— **一条测试都没变红**。
   因为测试测的是自己那份副本，与宿主改没改完全无关 ⇒ 同义反复。
   ⇒ 抽出来，让宿主和测试读**同一份实现**。重跑注入，A/B 双向都按预期变红。
   ```

⑤ 失败必须**分类翻译**且原文透出（unsupported / unauthorized / network）。
   统一成「发送失败」等于把可执行信息扔掉：
   不支持 ⇒ 别再试了；未授权 ⇒ 去登录；网络 ⇒ 检查网络。

Independent: 弹幕发送入口的显隐判据。与「弹幕源入口」独立（取 vs 发）。

## Alternatives considered

**把发送入口放进 DanmakuInfoPanel（右侧那块面板里）**
最强理由：弹幕相关的都在那儿，内聚。
否定原因：那块面板是**信息展示**（来源/条数/匹配），且默认收起；
发弹幕是**高频动作**，藏在一个要点开的面板里等于没做。
而且它只有 `dmInfoVisible` 为真（有弹幕或出错）时才存在 ——
「本集还没人发弹幕」正是用户最想发的时刻，那时面板反而不在。

**置灰 + tooltip 说明「此源不支持发送」**
最强理由：用户能知道「这里有功能，只是不能用」。
否定原因：Owner 原话是「发送入口由插件决定能否发送」——
决定的是**出现与否**，不是可用与否。置灰还会在视觉上制造一个
永远点不亮的东西，长期看是噪声。

**用 FutureBuilder 在 build 里查能力**
否定原因：build 不能 await；改 FutureBuilder 则控制条每次淡入淡出都会重跑查询。
⇒ 与 `_danmakuSourceLine` 同一手法：在写入处一并写，build 只读字段。

## Consequences

**代价**
```text
· 能力查询多一次 listProviders()（走本地注册表，无网络），
  与 _loadProviderName 同一批调用 —— 多一次但可忽略。
· 默认 false（不显示）。这是**安全方向**：
  漏判代价是「该显示没显示」，反方向是「不该显示却显示了」，
  用户打完字点发送才被告知不支持，更坏。
· 直播不显示发送栏（`!_isLive`）—— 直播没有「进度」这个概念，
  发给按进度发的站点会飘到错误时间点。
```

**何时该翻案**
```text
· 若出现「同一集能同时发往多个源」的需求 ⇒ 判据要从「当前源」改成「目标源选择器」。
· 若 Rust 侧 classify_error 修好（见下），UI 那段前缀兜底可以简化 ——
  但**不建议删**：它同时防住了「插件没按契约写前缀」的老插件。
```

## 过程中发现的 Rust 侧缺陷（不在我的写入范围，已报 Lead）

```text
现象：插件抛 'unsupported: 这个源只声明了能力，没真的实现发送'
      ⇒ Dart 收到 kind = 'other'（不是 unsupported）

根因：provider_danmaku_send 走 with_state_async，
      错误在 ffi.rs:2143 被 classify_error(&e) 重新分类；
      而 classify_error（ffi.rs:2188）拿到的是一句**扁平化的 message**，
      ProviderError.kind 已经丢了，它靠**中文关键词**猜：
        「不支持」→ unsupported、「登录/401」→ unauthorized …
      它**不认 unsupported: 这个前缀**。

反证（同一次实验）：把正文改成含「不支持」⇒ kind 立刻变 unsupported。
⇒ 证明分类只看正文关键词，不看前缀。

影响：所有走 with_state_async 的命令，只要插件用的是标准英文前缀
      而正文没带对应中文词，kind 都会退化成 other ——
      前端按 ErrorKind 分支的逻辑（如「去登录」引导）会全部失效。
这与我之前在 map_js_error 里补 parse: 是**同一类缺口，但在更外层**。
```

本地对冲：UI 侧改为「**前缀优先、kind 兜底**」。
上游修好后这段仍然正确，不会反过来变成 bug。