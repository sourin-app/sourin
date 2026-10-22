# Agent Note: 四条件 AND 谓词的门禁 —— 真值表钉不住的格子，只能靠源码契约钉

Status: implemented

covers: 6106c84

> 同域：[门禁必须有能力变红](2026-10-12-gates-must-be-able-to-fail.md)
> —— 本篇是它的一次具体遭遇：**真值表本身在这条谓词上是不能变红的**。
> 同域：[白送祖先的测试围栏](2026-10-18-gate-locked-api-name-not-invariant.md)
> （同一类假绿：测的是一层自己搭出来的树，产品的那行代码从未执行）。

## Problem

底栏「发送弹幕」入口由 `lib/ui/player_page.dart` 里一个四条件 AND 谓词决定：

```dart
danmakuSend: (_danmakuEnabled &&          // ① 弹幕总开关
        _danmakuCanSend &&                // ② 当前源声明 danmaku_send
        _danmakuSendProvider != null &&   // ③ 有真站点 id 可发
        !_isLive)                         // ④ 直播没有「这一集」
    ? DanmakuSendData(provider: …, onSend: …)
    : null,
```

任一条件为假 ⇒ 这枚入口**整条不渲染**。这类「N 个布尔与起来」的判据最容易写成
一句 `expect(find.byType(DanmakuSendButton), findsNothing)`，而那种断言在
「入口永远不出现」的实现下**全绿**。

更要紧的是它在结构上留了一个**不可达格**：

```text
_loadDanmakuSendCapability()，lib/ui/player_page.dart:3383-3392
  id 为空 ⇒ _danmakuCanSend = false; _danmakuSendProvider = null;  // 一起置
之后 canSend 只由 danmakuSendAllowed(list, id) 赋值（:3413）
⇒ (canSend = true, provider = null) 这个状态**没有任何代码路径能产生**
```

故障注入实测（不是推理）：把 `_danmakuSendProvider != null &&` 从句子里删掉，
**8 行真值表全绿、EXIT=0**。也就是说 ③ 这一条用黑盒真值表**永远钉不住** ——
谁删了它，门禁都不会响。

## Decision

三件东西一起做，缺一行都留下一个「删了也不红」的口子。

### 一、pump 真树，读产品建出来的那个值

```text
pump 的是真 `PlayerPage`（不是 `MaterialApp(home: Scaffold(body: PlayerBottomBar(...)))` 这种围栏）
断言读的是 `PlayerPage` **建出来的** `PlayerBottomBar.danmakuSend`，不是「某个控件没找到」
```

★ 为什么必须是真树：谓词写在 `PlayerPage.build` 里，围栏式测试里那段代码
**一个字节都没执行** —— 删掉 `&& _danmakuCanSend` 它照样绿。
（这与本仓那条「白送祖先的围栏」是同一个形状的坑。）

### 二、8 行可达真值表 + 阳性对照

```text
第 1 行 = 四条件全 T ⇒ 入口**必须出现**（阳性对照）
其余 7 行 = 可达的假格
```

★ 阳性对照不是装饰：没有它，「入口永不出现」的实现能让整张表全绿。
它的存在把「测不出问题」与「入口坏了」分开。

### 三、`(canSend=T, provider=F)` 用源码契约钉，并且连 false 分支一起钉

```dart
final code = raw.replaceAll(RegExp(r'/\*[\s\S]*?\*/'), '')   // 先剥注释再判
                      .replaceAll(RegExp(r'//[^\x0A]*'), '');
for (final clause in ['_danmakuEnabled', '_danmakuCanSend',
                      '_danmakuSendProvider != null', '!_isLive']) { … }
expect(seg.contains(': null'), isTrue);                       // false 分支还在
expect(seg.contains('provider: _danmakuSendProvider!'), isTrue); // 用的是同一个字段
```

三条，按重要性排：

```text
① 四条子句逐个在
② `: null` 还在 —— 删掉 false 支会让发送框**永不出现**，比多一个入口更重
③ DanmakuSendData 的 provider 与谓词读的是**同一个字段**（反查「两路来源」）
```

★ 这不是「文字匹配凑数」：真值表够不着这一格，而这一格的真职责是
「万一哪天可达，`_danmakuSendProvider!` 会当场空断言崩，而不是渲染一个坏入口」。
源码契约钉的是**这个结构性保证还在**。

## Alternatives considered

**A. 白送祖先的围栏：`MaterialApp(home: Scaffold(body: PlayerBottomBar(danmakuSend: …)))`。**
最强理由：**不需要真核心 dll、不需要 libmpv、不需要沙盒数据目录**，纯 widget 测试，
毫秒级、任何机器都能跑 —— 对 CI 友好得多（本仓的 native-media 套件一直是最慢最脆的那批）。
否决理由：那样测的是「底栏拿到数据后怎么渲染」，谓词一次都没执行。
删掉任一条件它都全绿 ⇒ 它守的是渲染层，不是这次的判据层。**快，但守错了地方。**

**B. mock 掉 FFI 的 `listProviders()` 直接给定能力位。**
最强理由：不需要起真核心，也就不需要 dll，能把整张真值表降到普通 `flutter test`。
否决理由：「能力位是怎么算出来的」正是本仓反复出问题的地方（N15 的核心缺陷之一
就是能力位撒谎）。mock 之后，真实现的失败态（抛异常 / 空 list / id 空）
全都变成同一个假的 `true`。⇒ 用 mock 测能力位，等于用被测试的东西去测它自己。

**C. 给不可达格造一个真状态（hack 出一个 `canSend=T, provider=null`）。**
最强理由：凑满 16 格看起来更「完整」，而且真值表纯黑盒、不依赖源码文本。
否决理由：那需要往产品里加一条**只有测试能走到的路径**，或者反射改私有字段。
前者污染产品，后者测的不是产品现在的拓扑。⇒ **不可达就是不可达**，
承认它并用契约钉住，比编造一个状态诚实。

**D. 只留源码契约，删掉整张真值表。**
最强理由：源码契约 8 行写完、毫秒级、不需要 dll，而且是唯一能钉住 ③ 的手段。
否决理由：文字包含关系**证明不了行为**。谓词可能被别处覆盖（例如调用点把
`danmakuSend` 算好后传进底栏），源码契约照样绿而入口行为已变。
⇒ 契约钉「结构还在」，真值表钉「行为对」，两者不是替代关系。

## Consequences

- **收益**：这条谓词第一次同时拥有「行为门禁」与「结构门禁」。四个条件里
  三个能被真值表抓住，第 ③ 条由契约抓住，false 分支也被钉住。
- **收益**：三条假红坑写进了文件头注释（不 start 核心 ⇒ 能力位恒 false；
  只 `pump` ⇒ 原生回调在 fake_async 里不派发；让 `_load()` 真解析 ⇒ `bars=0`）。
  这些都是**实测踩出来的**，下一个人不必重走。
- **代价**：本文件默认**跳过**。跑法：
  ```bash
  flutter test test/zz_t66_danmaku_send_predicate_test.dart \
    --run-skipped --tags native-media --concurrency=1
  ```
  缺 `sourin_core.dll` / `libmpv-2.dll` 时**整文件 skip，不是通过**。
  ⇒ 这条门禁在默认套件里**不产生保护**，只有跑 native-media 那一批才生效。
  这是本仓 native-media 长期红/长期 skip 问题的又一处落点。
- **代价**：源码契约在谓词**搬家**时会假红（它在 `player_page.dart` 里按
  `danmakuSend: (` 定位，取后 700 字符）。搬家时改这里，别把它删掉。
- **何时翻案**：
  ```text
  · 若 _loadDanmakuSendCapability 的赋值顺序改了，让 (canSend=T, provider=null) 变得可达
    ⇒ 应在真值表里补上这一行，并把源码契约降级为「false 分支还在」这一条。
  · 若这个谓词搬进一个纯函数（`bool shouldShowDanmakuSend(...)`），
    那么它就不再需要真树与 dll —— 那时应改成普通单元测试的真值表，
    并删掉本文件的 skip 条件。可测性应该推动重构，而不是被现状绑住。
  ```
