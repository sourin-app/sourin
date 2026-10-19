# Agent Note: 兜底文案不能替用户断言没发生的事（R3-③/⑦）

Status: implemented

Independent: 与 [2026-10-19-hijack-verdict-only-wired-to-one-path.md](../bug-fix/2026-10-19-hijack-verdict-only-wired-to-one-path.md)
是**同一个 Owner 反馈（R3-③/⑦「弹幕来源搜不了」）的两个面**：
那篇补的是「取数/搜索」那条被漏接的线（线没接 ⇒ 无处显示真相），
本篇修的是**接上之后说的话本身是假的**（线接上了 ⇒ 显示的却是编的）。
两篇要一起读才完整。

## Problem

Owner 的原始抱怨是「弹幕来源搜不了」。根因查实是 **DNS 被劫持**
（返回伪造段，与 DoH 真值完全不同），TCP 超时只是它的**后果**。

接线补上之后，`r6-live` 复核时又查出一层：

```text
StateError('boom')（探针自己抛的，压根没走到 DNS/TCP）
  ⇒ 落进 fromError 的兜底分支
  ⇒ 报 connectionTimeout
  ⇒ 用户看到「连不上（超时）⇒ 地址解析出来了但连不过去，通常是被墙…」
     ★ 这句话替用户断言了三件**从未发生**的事实：
       没超时 / 地址没解析过 / 不是被墙
```

★ 这是 Owner 第 6 条抱怨的同一个毛病：「不知道是源的问题还是软件本身的问题」。
把未知异常说成超时，等于**把用户推向错误方向**。

## Decision

### 新增 `probeFailed` 档，两处兜底改归它

```dart
DanmakuProbeFailure.probeFailed     // 枚举新增
→ title:  '检测过程本身出错了'
→ remedy: '检测这一步自己出错了，还没走到「能不能连上」那一步。…'
```

★ 判据的核心是**证据对称**：

```text
fromDanmakuException 敢判 dnsHijacked，是因为手里有 resolvedAddress **物证**。
兜底这条**没有任何网络物证** ⇒ 同理不该判任何网络档。
```

这与那句铁律是同一条：「没有地址证据就绝不判劫持」
—— 扩展一步就是「没有网络证据就绝不判超时」。

### 保留 `connectionTimeout` 分类本身

真超时（`TimeoutException` / errno 10060）仍落它，文案一字未改。
只有**兜底**不再落进来。

## Alternatives considered

**A. 兜底继续落 `connectionTimeout`，只把那句文案改中性。**
最强理由：改动面最小（一行文案），且分类表不动。
否决理由：颜色会撒谎 ——
`isLocalNetworkProblem` 为 false ⇒ 落进红色「服务端问题」，
而它既不是网络也不是服务端。**文案与颜色必须同时改**。

**B. 把兜底整体改成 `unknown`，让所有未识别异常共用一档。**
最强理由：语义更诚实（确实就是"不知道"）。
否决理由：`probeFailed` 已经表达了"不知道是什么，但发生在探测这一步"，
再引入 `unknown` 会让它与 `isJustEmpty`（另一种"没有结果"）混淆。
**两个都叫"不知道"的档比一个更难分辨。**

**C. 直接把异常原文透出去，不分类。**
最强理由：最诚实，一个字不加工。
否决理由：用户看到的是 `Bad state: boom` 这种**开发者信息**，
他既不知道该做什么，也不知道这是不是自己的问题。
⇒ 该给的是「这一步自己出错了 + 把这句原文反馈给我们」。

## Consequences

**修好了什么**

```text
· 未知异常不再被说成"网络超时"或"被墙"
· 用户拿到的是可执行的下一步（反馈原文），而不是错误的排查方向
· `connectionTimeout` 的原有语义与文案一字未动
```

**验证**

```text
逐档实测 fromError（读真实落档，不靠"看起来像"）：
  TimeoutException / errno 10060 / 60 ⇒ connectionTimeout  ← 真超时，有据
  errno 11001（主机未知）            ⇒ dnsFailed            ← 有据
  errno 10061（拒绝）                ⇒ connectionRefused    ← 有据
  errno 9999 / 无 osError            ⇒ probeFailed          ← 原先说谎
  StateError / ArgumentError         ⇒ probeFailed          ← 原先说谎

门禁：t3b_selfhosted_panel +19 全绿
注入：把兜底改回 connectionTimeout ⇒ 两条门禁红
断言写成**成对**（该在的在 + 不该在的不在）——
只断"该在的"的话，将来有人改回长句仍会绿。
```

**已知上限（不掩盖）**

```text
· `probeFailed` 没有单独的图标/颜色档，目前落红色。
  它与"服务端真的坏了"同色 —— 自审记为 P2，未修。
  修它要动渲染层的分支，而那正是 R3-①② 刚统一过的外壳。
· `isProbeItselfFailed` 这个新 getter 目前**没有调用点**（P2）：
  它本来是为"接中性色"准备的，但中性色没做 ⇒ 死代码。
  留着是因为删它与做中性色是同一个决定的两半。
```

**何时该翻案**

```text
· 若 Owner 认为"探测自己出错"也该用橙色（区别于红色服务端问题），
  就该做中性色档，并把 `isProbeItselfFailed` 接上 —— 现在留着它就是为了那一天。
· 若将来出现第三种"不是网络但也不是探测崩"的失败（如本地文件读不到），
  应新开一档而不是塞进 `probeFailed`。
```
