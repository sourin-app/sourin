# Agent Note: 这台 Flutter 版本的 Windows IME 读不出合成串 —— 改由 runner 读、Dart 插

Status: implemented

## Problem

Owner 报「搜索框打不了中文」，而且给了决定性现象：**英文可以、中文不行、打着打着只剩英文**。

取证到最后一层（两处日志同一毫秒对上）：

```text
窗口层（%TEMP%\sourin_ime.log）
  13:05:06.660  child WM_IME_STARTCOMPOSITION
  13:05:06.661  child WM_IME_COMPOSITION lparam=0x800 RESULTSTR
  13:05:06.662  child WM_IME_ENDCOMPOSITION

Dart 层（探针日志）
  13:05:06.660  EDIT field=page-static len=0 cjk=0 composing=none
```

⇒ 合成**到了窗口**、也被引擎转发成一次 value 更新，**但字符串是空的**。

排除法（每一步都有读数）：

```text
· 页面层不拦中文（zz_n4_1_ime_composition_test，注入"只允许 ASCII"真红）
· 窗口层收到了完整合成序列（6 组 START→RESULTSTR→END）
· 焦点/连接都在（英文能进：EDIT len=6 ascii=6）
· 我们自己的 ImmAssociateContextEx 不是元凶：把它整段删掉后**结果一样**
⇒ 结论：这条 Flutter 构建（3.47.5 / engine af7e796）的 Windows IME 路径
  读不出 GCS_RESULTSTR，不是我们抢上下文。
```

## Decision

**runner 自己读合成串，通过 MethodChannel 交给 Dart 插入**（三段）：

```text
① win32_window.cpp：WndProc 收到 WM_IME_COMPOSITION 且带 GCS_RESULTSTR 时，
   用 ImmGetCompositionStringW 读出宽字符串（只处理"提交"，不碰拼音预览），
   交给 sink。SetImeCommitSink 必须定义在**匿名 namespace 之外**
   （放里面 = 内部链接 ⇒ flutter_window.cpp 链接不到，实测 LNK2019）。
② flutter_window.cpp：建 `sourin/ime` 通道，把 UTF-16 → UTF-8（中文是 3 字节分支），
   发 `commit`。
③ lib/core/ime_fallback.dart：收到后**推到下一帧**再插进当前焦点 EditableText
   （同步插会被引擎同毫秒的空更新覆盖 —— 实测两次"框里什么都没有"）。
```

默认**开**（`SOURIN_IME_FALLBACK=0` 可关）。

真机验收（Owner 打中文，探针两个输入区各打两次）：

```text
13:05:06.661  ime-fallback commit chars=2
13:05:06.680  EDIT field=page-static len=4 cjk=4      ← 中文进框了
13:05:09.736  ime-fallback commit chars=2
13:05:09.745  EDIT field=probe len=4 cjk=4
```

## Alternatives considered

1. **继续在引擎侧修**（给 Flutter 提 issue / 换 Flutter 版本 / 打补丁重编 engine）。
   最强理由：治本，所有输入框一次性都好，且没有"双插"风险。
   **否决（本轮）** —— 换版本要重验全仓 369 个 Dart 门禁与实机；重编 engine 需要
   完整工具链（本机每日构建成本极高）。而 runner 兜底只要 100 行、可开关、可回滚。
   这是**能用、可撤销**的修法；治本那条留给"下次升 Flutter"时顺手验证。
2. **用 `WM_IME_CHAR` 收字符**（另一条老 API）。
   最强优势：不需要读 IMM 上下文。
   **否决** —— `WM_IME_CHAR` 只给单字符，拿不到整段提交，而且它和 `WM_CHAR` 混在一起
   无法区分"这是输入法提交的"还是"用户直接按的键"（英文会重复插入）。
3. **在 Dart 侧自己装 `TextInputClient` 转发**。
   最强理由：不碰 C++，纯 Dart。
   **否决** —— `TextInput.setInputControl` 是独占替换，装上会打断真输入
   （上一轮探针调研已确认），而且 Dart 侧本来就收不到串（引擎读不出），
   换谁来收都一样是空。
4. **把插入做成同步**（不加 postFrameCallback）。
   **否决（实测）** —— 同一毫秒引擎写进一个空值，把插入覆盖掉，两次都空。
   这是本轮最贵的一次教训：**"读到了"和"落到了"是两件事**。

## Consequences

- 收益：中文输入在这台机器上**能用了**（两个不同输入区都验过，含 probe 自有 TextField）。
- 收益：链路有三条门禁守着（`zz_n4_1_ime_fallback_insert_test` 4 条行为判据 +
  `zz_n4_1_ime_fallback_wiring_test` 4 条源码链路判据），每条都做过注入。
- 代价：**拼音预览（候选窗期间）仍不显示** —— 只有提交后的字进框。
  这是刻意的：预览要是也由我们接管，会和引擎的（空）预览打架，出现"预览一段、提交又插一段"。
  真要预览得整条接管输入框，风险远大于收益。
- 代价：一次输入会同时经过引擎（空更新）与我们（真插入）两条路 ⇒
  当前实现靠 `composing` 区间判据防双插（引擎若在合成，我们不插）。
  将来 Flutter 修好这条路径，双插风险由这条判据兜住；若判据失效，症状是"打一个词出两遍"。
- 代价：`win32_window.cpp` 多了一个跨 TU 的 C 函数指针（sink），
  生命周期靠 FlutterWindow 里的 static 持有 —— 换窗口实现时要同步。

## Relations

- 前情：[../feature/2026-10-28-danmaku-search-layout-redesign.md](../feature/2026-10-28-danmaku-search-layout-redesign.md)
  —— 那个页面就是这次中文打不进去的地方（N4-3 改版后仍要能输入）。
- 同族：[./2026-10-28-gates-follow-the-implementation-shape.md](./2026-10-28-gates-follow-the-implementation-shape.md)
  —— 都在讲"判据要跟着真实形态走"。
