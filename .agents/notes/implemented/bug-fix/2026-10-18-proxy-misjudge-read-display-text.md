# Agent Note: 内置代理误判 —— 归因读了展示改写后的文本

Status: implemented

> 同域：本篇讲「判据读了展示改写后的文本」。同批另一条自审发现见
> [2026-10-18-three-broken-wirings-found-by-self-review.md](./2026-10-18-three-broken-wirings-found-by-self-review.md)；
> 同类的「判据读错对象」见
> [2026-10-18-fake-green-cache-label-reads-source.md](../testing/2026-10-18-fake-green-cache-label-reads-source.md)。

## Problem

Owner 真机报「内置代理没起来 / 内置代理取不到这条流 / 重启客户端」，
但**日志证明代理一直是活的**：

```text
sourin-2026-10-18.log（真实数据目录）
  19:03:01  起播 OK    端口 57106
  19:03:06  起播失败  Failed to open http://127.0.0.1:57106/s/18df9acc…/.
  19:03:48  起播 OK    端口 57106   ← 同一个端口
  19:07:25  起播 OK    端口 57106
  19:09:47  起播 OK    端口 57106
```

同一个端口既「没起来」又「起播 OK」，说明报错文案在撒谎，不是代理真挂了。

### 根因：判据被喂了「给用户看的改写版」

```dart
// sourin_api.dart:3854（改前）
final text   = stripHostErrorNoise(hideInternalUrls(raw));
final lower  = text.toLowerCase();
```

`hideInternalUrls` 是**展示函数** —— 它把 `127.0.0.1:57106` 改写成
「内置代理取不到这条流」。拿它的输出当归因输入，就形成自我强化的误判环：

```text
① hideInternalUrls 把内部地址改写成含「内置代理」的文案
② proxyDown 判据里正好有 lower.contains('内置代理')
③ ⇒ 恒命中 ⇒ kind = proxy ⇒ 显示「内置代理没起来」
```

**环路的关键在于：判据读的是自己上一轮的产物。** 一旦第一次误判成立，
后续所有包含该短语的文本都会继续命中，形成稳定复现的假象。

## Decision

**判定与展示彻底分家。**

```dart
final text    = stripHostErrorNoise(raw);   // 归因输入：原文
final display = hideInternalUrls(text);     // 给用户看：净化版
final lower   = text.toLowerCase();         // 用原文

detail: display,   // 9 处 —— 正文仍不许暴露内部地址
```

`must`：归因输入只用**原始错误文本**；任何展示层改写都不能回流进判据。
这不是「顺便规范化一下」——它的失效模式是**自我强化**，改一半等于没改。

**顺带修掉的两处「假话」**：

- `proxyDown` 里原来的 `lower.contains('内置代理')`，在 text 换成原文后
  **这四个字永远不会出现** ⇒ 变成死判据。改成认环回地址本身：
  `lower.contains('failed to open') && (含 127.0.0.1 / localhost / [::1])`。
- 测试里的字面量样本 `'内置代理没起来'` 是**展示产物**，永远不可能作为
  输入出现 —— 等于在测一个不存在的场景。换成真机日志原文。

**门禁同步（行为有意变更，不是放宽）**：

| 测试 | 旧断言 | 新断言 |
|---|---|---|
| `zz_r65_error_text_test` ① | `headline == 内置代理没起来` | `headline 不含「没起来」` + `headline == 这一条流取不到` |

新断言在旧行为下**必红**（旧文案含「没起来」），所以这是收紧而非放宽。

## Alternatives considered

- **把 `hideInternalUrls` 从判据路径里删掉，只保留原文** — 最直接，能让
  误判立刻消失。否掉：展示层仍需要把 `127.0.0.1:57106` 藏起来，正文里
  暴露内部地址是另一个既有缺陷（9 处 `detail:` 都依赖净化后的文本）。
  删掉它等于用一个缺陷换另一个。
- **让 `hideInternalUrls` 改成不产生「内置代理」字样** — 改一个字符串就能
  让环路断开，改动最小。否掉：那是**掩盖**而非修复。判据仍然依赖展示层的
  具体措辞，下次有人调整文案就会重新踩坑，而且没有测试能守住这种隐式耦合。
- **在 `proxyDown` 判据里加「但如果是内部地址改写则跳过」的特判** — 能绕过
  当前症状。否掉：判据需要知道「文本是否被改写过」，这个信息本来就在调用栈里
  明明可以分开，靠特判去猜改写过没有是结构性的错。
- **只修判据不改测试** — 改动面最小。否掉：旧测试断言的是「展示产物等于
  某个字符串」，不修就没有任何东西守住新行为；而且故障注入会假装通过。
- **`detail:` 处也改用原文，统一成一个变量** — 少一个变量更简单。否掉：
  那会把 `127.0.0.1:57106` 直接暴露给用户，是本轮之前就在避免的事。

## Consequences

- **收益**：Owner 真机看到的三处误报消失。代理活着时不再谎报「没起来」。
- **收益**：判定链上少了一处「展示函数回流成判据输入」的隐式耦合 ——
  这类耦合的特点是**改文案会悄悄改变业务判定**，很难在 review 里看出来。
- **收益**：测试样本从「展示产物」换成真机日志原文，之后能真正覆盖
  用户会遇到的输入。
- **代价**：多维护一个 `display` 变量，9 处 `detail:` 要逐个确认用的是它
  而不是 `text`。漏一处就会把内部地址暴露到界面。
- **代价**：`proxyDown` 的判据从「认某个词」变成「认环回地址 + failed to open」，
  语义更准但对文案变体更敏感。重访信号：出现新的代理失败措辞
  （非 `failed to open`）而判据没命中时。
- **已知缺口**：只修了 `sourin_api.dart` 这一条判定链。同类「展示函数被当成
  判据输入」的写法若在别处存在，本次没有排查。

## Verification

```text
dart analyze lib/core/sourin_api.dart     ⇒ 79 issues（与改前一致，无新增 error）
zz_r65_error_text_test                    ⇒ +23 All tests passed
zz_t65_playback_error_text_test           ⇒ +19 All tests passed
```

**故障注入（证明门禁真有判别力）**：
把 `lower` 改回 `display.toLowerCase()`（复现原误判环）

```text
⇒ dart analyze 0 error（注入有效）
⇒ zz_r65 立刻红 3 条：① 代理连不上 / ③ 本地代理地址 / ⑦ 判据顺序
还原 ⇒ +23 全绿
```

注入后能红 3 条、还原后全绿，说明这组断言不是恒绿。
