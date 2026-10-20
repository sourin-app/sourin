# Agent Note: 弹幕发送入口的 AND 谓词用「真树真值表 + 源码契约」钉住

Status: implemented

## Problem

`lib/ui/player_page.dart` 里那行决定「底栏发不发送弹幕入口」的判据是一个四条件 AND 谓词
（`_danmakuEnabled && _danmakuCanSend && _danmakuSendProvider != null && !_isLive`），
在本次改动之前**没有任何测试读这个文件**。后果是具体的：

- 删掉其中任一条件，发送入口会在不该出现的场景里常驻（例如直播态、源没声明能力位），
  或者在不该消失时消失，**整套测试仍然是绿的**。
- 现存的 `test/task41_danmaku_send_gate_test.dart` 明确绕开 `PlayerPage`
  （注释记的是真核会原生崩溃），改用 `MaterialApp + Scaffold + PlayerBottomBar` 的围栏。
  那种围栏里谓词一个字节都没执行：把 `&& _danmakuCanSend` 删掉，它照样全绿。
- 谓词第 ③ 条 `_danmakuSendProvider != null` 更麻烦：`_danmakuCanSend` 只由
  `_loadDanmakuSendCapability()` 赋值，而该函数里 id 为空时是 **canSend 与 provider 一起**
  置 false/null 的，之后 canSend 只由 `danmakuSendAllowed(list, id)` 决定。
  于是「canSend 真而 provider 空」这一格**结构上不可达** ⇒ 任何纯行为断言都钉不住它：
  实测把第 ③ 条删掉，八行真值表 **EXIT=0、零行变红**。

## Decision

新建 `test/zz_t66_danmaku_send_predicate_test.dart`，两层：

1. **真树真值表**：`pumpWidget(PlayerPage(...))` 挂真页面，再从它**建出来的**
   `PlayerBottomBar` 实例上读公开字段 `danmakuSend`，并同时数树里 `DanmakuSendInline`
   的个数（两个观测量必须同向）。八行覆盖四条条件的可达组合，**第一行是阳性对照**
   （四条全真 ⇒ 入口必须在）。夹具是复制仓内自带 demo 插件改写能力位（一真一假），
   沙盒起真核心，改写没命中就 throw。四条件不可达的那一格不凑数。
2. **源码契约**：剥注释后断言谓词四条子句齐全、false 分支仍是 `: null`、
   `DanmakuSendData` 用的就是谓词那个字段。它替黑盒表兜住第 ③ 条。

实测：`+9 All tests passed`、`EXIT=0`；注入 A1/A2/A4 各使**唯一一行**变红，
A3（删第 ③ 条）零行红而补契约后的 A3′ 变红。

**边界（必须写清）**：源码契约只防「被删掉」，**不证明行为真值** —— 它保证那条子句
还在原处，不保证它在运行时算得对。行为真值由真值表部分负责。

## Alternatives considered

- **给第 ③ 条塞 skip / reserved 标记放行** —— 论据是「不可达格不必测」。
  否决理由：那等于把不可达格变成静默放过，删掉它也没人知道；
  而它恰恰是防 `_danmakuSendProvider!` 空断言的最后一道，值得一条会红的断言。

- **mock provider 强制造出 provider=null 而 canSend=true** —— 论据是能"补齐"那一格。
  否决理由：该状态在产品里不可能出现，测的是一个不存在的世界；
  断言会随一次内部重构莫名变红/变绿，属于自己发明的约束。

- **只写真值表、不补源码契约** —— 论据是"行为测试比读源码干净"。
  否决理由：实测 A3 注入零行红，缺口就在那里；一条永远不会红的断言等于没有。

- **继续白送祖先的围栏（`Scaffold` + 直接构造 `PlayerBottomBar`）** —— 论据是快、无原生依赖。
  否决理由：它测的是底栏自己的渲染，谓词根本没跑；这正是本次要补的洞。

## Consequences

- **收益**：那条 AND 谓词第一次有了「能被弄红」的门禁；四条件逐条有归属行；
  第 ③ 条这个不可达格有了唯一可行的钉法。
- **代价与已知上限**：
  - 需要真 `sourin_core.dll` + `libmpv-2.dll`，所以标 `native-media`：
    `flutter test <file> --run-skipped --tags native-media --concurrency=1` 才跑得到，
    **默认批次里整文件 skip** —— 平时不拦提交。
  - 只覆盖「入口在不在」（渲染），不覆盖「点了发不发得出去」；
    后者在 `test/task41_danmaku_send_onwire_test.dart`。
  - 真树夹具依赖三条容易假红的细节（详见 `docs/notes/round-66-n15.md` §8）：
    必须真起核心、必须 `runAsync` 让 FFI 回调落地、必须走 `localPath` 生产短路
    绕开 `_load()`，还要 `RemoteBridge.instance.stop()` 收尾，否则报未完成定时器。
- **重访条件**：`_danmakuSendProvider` 与 `_danmakuCanSend` 的赋值点若被拆开
  （不再"一起置"），第 ③ 条变为可达，源码契约应降级/替换为真值表的一行。

相关笔记：[门禁必须能被弄红](2026-10-12-gates-must-be-able-to-fail.md)、
[把「不支持发送」的解释搬到发现点](../bug-fix/2026-10-20-danmaku-send-hint-at-discovery-point.md)。
