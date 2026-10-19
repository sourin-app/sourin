# Agent Note: 批末自审揪出的四个真缺陷（两条是本轮自己引入的回归）

Status: implemented

Independent: 与 [../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md](../testing/2026-10-19-criteria-must-distinguish-cause-and-ciphertext.md)
**部分重叠但结论不同**：那篇讲「判据要能分辨原因」这一条纪律，
本篇讲**这套纪律没被遵守时，实际漏掉了哪四个缺陷**。
与 [../bug-fix/2026-10-19-hijack-verdict-only-wired-to-one-path.md](../bug-fix/2026-10-19-hijack-verdict-only-wired-to-one-path.md)
同源：那篇补「取数/搜索」那条被漏接的线，本篇修的是它留下的**格式缺陷**。

## Problem

第 66 轮改动面很大（16 个文件 1176+/238−），批末做了一次逐行自审（`code-selfreview`），
逐文件读完整 diff 而不只是 `--stat`。查出 **4 条 P1**，其中 **2 条是本轮自己引入的行为回归**：

```text
① player_page.dart dispose() 里的异常逃逸          ← 本轮 N10 引入
② danmaku.dart 把 Dart 调试表示给了用户            ← 本轮 R3-③ 引入
③ live_embedded_player.dart 重复 url ⇒ 下拉崩      ← 本轮 R6 引入
④ sourin_api.dart 环回地址净化两次都不彻底         ← 本轮 R2 引入（两次修复）
```

★ 这四条**没有一条**是被 4638 条通过的测试抓到的。

## Decision

### ① `dispose()` 里 `unawaited` 一个会抛的调用

```dart
// 改前
unawaited(SourinApi.endYieldForSeek());
```

`unawaited` 只是"不 await"，**不等于**"异常被吃掉" ——
Future 里的 throw 仍会变成未捕获异常。核心未启动时
`SourinCoreException` 从 dispose 逃逸，咬红两条测试。

**为什么是回归而不是既有缺陷**：同文件 `_beginPrefetchYield`（`:996` / `:5540`）
**有** try/catch，只有 dispose 这处没有 ⇒ 不对称。

改法：`.catchError` + 只写日志。理由：dispose 是在页面销毁时跑的，
此刻抛异常对用户**毫无意义**（页面都没了），只会污染日志与测试。

### ② `_addressOf` 返回 `InternetAddress.toString()`

实测 Dart 的行为（不是凭印象）：

```dart
InternetAddress.tryParse('74.86.17.48')!.toString()
  ⇒ "InternetAddress('74.86.17.48', IPv4)"   ← 调试表示
InternetAddress.tryParse('74.86.17.48')!.address
  ⇒ "74.86.17.48"                             ← 裸 IP
```

这串进 `DanmakuProbeReport.detail`，而 detail 在面板里是**用户可见**的
（monospace 那段）⇒ 用户看到 `InternetAddress(...)` 这种开发者写法。

改法：用 `a.address`。**现成的对照组就在同文件**：`_diagnose`
用的是 `a.address` ⇒ 两处口径本来就该一致。

### ③ 重复 url ⇒ `Duplicate keys found`，下拉打不开

`ValueKey('live-quality-opt-${o.value}')` 在两条档位 url 相同时冲突，
而 `get_live_stream` 在 Rust 侧**不做 url 去重**（`commands.rs:834` 只是转发）。

改法：key 加序号，用 `options.indexed` 让 key 绑**列表位置**而非内容
—— 即使 url 重复也能区分。

### ④ 环回地址净化：修了两次才彻底

```text
改前：RegExp(r'https?://(?:127\.0\.0\.1|localhost|\[::1\]):\d+/s/\S*')
  ⇒ 只认 /s/<id> 一种形态。实测三条泄漏：
     http://127.0.0.1:1/      ⇒ 原样输出
     http://127.0.0.1:9999/api/v2/thing ⇒ 原样输出
     http://localhost:2080/movie/x.mp4  ⇒ 原样输出
  而这与该函数自己写的三条理由（用户看不懂 / 端口失效误导排查 /
  暴露内部实现）**直接冲突**。

第一次改（去掉路径锚定，但保留 CJK 标点排除）：
  ⇒ `)` 后面的正文被吃掉：
     '取流失败(http://…:8080/s/x)后重试'
        ⇒ '取流失败(（内置代理地址）'      ← ')' 与「后重试」全没了
```

★ 最终修法：**字符类只放 URL 真正可能出现的 ASCII 字符**
（`A-Za-z0-9 - . _ ~ % : / ? # [ ] @ & = + ; ,`），
不放的一律终止匹配。

## Alternatives considered

**A. 环回净化改成"只替换 host 部分"，保留路径。**
最强理由：用户看到的路径片段（`/api/v2/match`）对他判断
"是哪个服务出问题"仍有价值。
否决理由：路径里常常**就是** token / 用户标识，而
`_redactUrl`（`danmaku.dart:2223`）已经证明 URL 路径在本仓被视为敏感。
⇒ 整条抹掉是保守但一致的选择。

**B. `probeFailed` 复用 `connectionTimeout` 的图标，只改文案。**
最强理由：不动渲染层，改动面小。
否决理由：`isLocalNetworkProblem` 会把它染成"网络问题"的橙色，
而它恰恰**不是**网络问题 ⇒ 文案与颜色自相矛盾。

**C. `dispose()` 里的异常照旧抛出，只在测试里 mock 掉。**
最强理由：不动生产代码，测试可控。
否决理由：**这会让测试变绿而产品不变** —— 正是本轮反复在治的病。
异常在真实运行里同样会逃逸。

## Consequences

**修好了什么**

```text
① dispose 阶段的异常不再逃逸（实测：相关两条门禁 +4 全绿）
② detail 里只出现裸 IP（门禁：源码级钉 `a.address` + 行为级禁 `InternetAddress(`，
   并有阳性对照防止"因为根本没进 detail"而恒绿）
③ 重复 url 不再让下拉崩
④ 环回地址不再泄漏，也不吃掉正文标点
```

**验证（每条都有故障注入）**

```text
① 退回无 catch ⇒ 两条门禁红
② 注入 a.toString() ⇒ 门禁红；还原 ⇒ 全绿
③ 注入去掉序号 ⇒ 待补（当前只有代码审查，无注入）
④ 注入旧正则 ⇒ 门禁红；ASCII 反例（`)`/`,`/`.`/query/多地址/外部 URL）逐条验
```

★ ④ 的 ASCII 那轮是**两次才做对**：第一次只把 `b<32` 当控制字符的
「恒返回干净」命令去查 U+FFFD，永远查不出来。

**已知上限（不掩盖）**

```text
· ③ 没有注入验证，只做了代码审查与静态推理
  （"重复 url 是否真会发生"取决于插件 JS 返回，本轮未观测到）
· ② 只保证格式；`resolvedAddress` 本身是**新出现在用户面前的信息**，
  将来若要脱敏要一并处理
· ④ 环回地址的正则**仍可能过度匹配**：
  `localhostfoo` / `127.0.0.10` 会被吃进去（host 后没有边界断言）。
  自审记为 P2，未修 —— 修它要加边界断言，且要确认不误伤 IPv6。
```

**何时该翻案**

```text
· 若 ③ 被证实可发生（上游返回重复 url），应补一条注入门禁，
  因为现在的保护是"结构上正确"而不是"被证明有效"。
· 若 ④ 的过度匹配造成真实误伤（用户看到外部地址被抹），
  应加边界断言而不是回退到"只认 /s/<id>"（那会退回原始泄漏）。
```
