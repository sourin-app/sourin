# Agent Note: 过期条目的时间戳从不刷新 —— 新鲜度保护必须按 TTL，不能按「有没有记录」

Status: implemented

- 日期：2026-10-22
- 范围：`lib/ui/live_availability.dart`（`LivePlaybackHealthStore.now` / `LiveAvailabilityProbe` 注入时钟 / `mirrorAvailabilityIntoHealth`）、`test/zz_cr32_a_stale_ttl_test.dart`
- 来源：CodeRabbit PR #32 第 1 条阻塞项

> 部分取代：[2026-10-18-live-availability-three-state-and-persistence.md](../feature/2026-10-18-live-availability-three-state-and-persistence.md)
> —— 那篇定的「三态 + 落盘」结构不动，本篇只改**什么条件才算"已有记录"**：
> 从「有没有记录」改成「记录是否还在 `kLiveHealthTtl` 内」。
> Independent of：[2026-10-19-probe-failed-never-asserts-unhappened.md](../bug-fix/2026-10-19-probe-failed-never-asserts-unhappened.md)
> （那篇管探测失败的自证，本篇管过期条目的刷新时机，不同失效点）。

## Problem

`mirrorAvailabilityIntoHealth` 原判据是「**只要有记录就不写**」：

```dart
if (store.healthOf(provider, channelId) != LivePlaybackHealth.unknown) continue;
```

它把 P0 的目标（「10 分钟内有缓存就一个请求都不发」）**从内部打穿**。完整链条：

```text
首次探测 → 写入所有频道，at = T0 → 落盘
11 分钟后重启 → restore 回 at = T0 ⇒ freshOnly 为空 ⇒ 走延迟分支
                             ⇒ 30s 后全量重探
探完回到这里 → healthOf != unknown 对**所有**频道都成立
             ⇒ 一条都不写
             ⇒ _persistHealth() 把仍是 T0 的旧快照原样写回磁盘
下次启动重复 ⇒ **只有「首次探测后 10 分钟内重启」才命中缓存**
```

关键在于 `at` 的语义是「**最后一次观测到该状态的时刻**」，而两处消费方
（`needsRetry` 的 `retryAfter` 判断、`freshOnly` 的 TTL 判断）要的都是这个语义。
重新观测到同一状态却不更新 `at`，等于把它悄悄改成「第一次观测到的时刻」——
语义被写坏，而且是**无声的**：文件生成了、大小正常、路径正确，只是时间永远不前进。

真实代价不是「多几个请求」：每次冷启动都要等 30s 才出画面，而且**永远不会自愈**。

## Decision

**保护判据换成「已有条目仍新鲜才保护」，过期条目允许被这次探测结论刷新（含 `at`）。**

```dart
final prev = store.entryOf(provider, channelId);
if (prev != null && now.difference(prev.at) < kLiveHealthTtl) {
  continue;                                  // 仍新鲜 ⇒ 真实播放证据优先
}
// 已过期 / 从没有 → 用这次探测结论覆盖，并写下新的 at
```

同时做两件配套事，缺一件这条链就接不上：

1. **`LivePlaybackHealthStore` 暴露 `DateTime get now => _now();`**。
   外部要判断「这条还新不新鲜」时必须读它，不能自己调 `DateTime.now()`：
   `record()` 写 `at` 用的是 store 的**注入时钟**，若比较用真实时钟、写用注入时钟，
   两者会差出一整个测试的时间跨度 —— 门禁看起来在跑，读数却没有意义。
   `mirrorAvailabilityIntoHealth` 里 `final now = store.now;` 提升到循环外，
   保证同一批条目用同一个时刻判断。
2. **`LiveAvailabilityProbe` 接受 `DateTime Function()? now`**（默认 `DateTime.now`），
   内部 `cached()` 的 TTL 比较改成 `_now().difference(t)`。
   产品侧行为不变；测试侧从此能把「会话 2 是 +11min、会话 3 是 +15min」
   喂进同一个时钟轴。

改动只落在 `lib/ui/live_availability.dart` 与新增测试两个文件上，没有引入任何调试开关或临时分支。

## 为什么「按新鲜度」而不是「按来源」

`broken` 来自**真实播放失败**，比「探测说没有可播地址」更硬——这条优先级本身没错，
错的是**用「有没有记录」近似「是不是新鲜证据」**。一条 20 小时前的 `broken`
早就不该压住今天的探测结论；而一条刚写下的 `broken` 必须压住它。
新鲜度是唯一能同时满足这两件事的判据，`kLiveHealthTtl` 就是它已有的口径。

## Alternatives considered

1. **保持 `!= unknown` 保护，只补「顺手把 `at` 刷新一下」**（半修）。
   最强的理由：改动最小，优先级语义一个字不用动，`at` 也确实前进了。
   否定理由：这会让「真实的旧证据」和「刚推出来的新结论」共用一个 `at`——
   吃到了时间戳，却假装自己仍是被保护的那条。下游 `needsRetry` 会因此
   对一个其实没被重新观测过的 `broken` 重新计时，语义比不修更混乱。
2. **彻底拿掉保护，任何条目都被探测结论覆盖**。
   最强的理由：逻辑最简单，`at` 一定前进，P0 的「零请求」目标最稳。
   否定理由：真实播放证据（`broken`/`playable`）会被一次「站点暂时没给地址」的
   探测糊掉，用户看到的状态会在两个真值之间来回跳。
   实测证明这条轴有独立价值：注入「保护整个拿掉」后，
   `★★ 仍新鲜的条目必须继续受保护` 立刻红（`Expected: <0> Actual: <1>`）。
3. **让比较侧继续用 `DateTime.now()`，只把写入侧改成注入时钟**。
   最强的理由：`now` 参数不必外露，`LiveAvailabilityProbe` 的签名保持不变。
   否定理由：就是「两个世界对不上」。本仓已经踩过一次同形态的坑
   （测试用固定 `t0` + 真实时钟 ⇒ 当天绿、第二天红，见下面验证一节），
   同一个注入点写两遍不可能只错一边。

## Consequences

**收益**

- 「10 分钟内有缓存就零请求」从「只有首次探测后 10 分钟内成立」变成**任何时刻都成立**，
  冷启动不再固定等 30s。
- `at` 恢复它注释里承诺的语义，`needsRetry` / `freshOnly` 两个消费方同时受益。
- 时钟注入点让「跨会话重启」这类**只能靠时间推进才复现**的缺陷第一次可被门禁复现。

**代价 / 已知弱点**

- `★★ 新条目（store 里没有）不受新鲜度判据影响，照写` 这条用例对本次修法**分辨力为零**：
  旧代码里 `healthOf == unknown` 照样写，修好后照样写，只有人为构造
  `if (prev == null) continue;` 才会红（注入 D：`+5 -3`）。
  它是有价值的回归护栏，但**不该计入本 PR 的覆盖**。
- `kLiveHealthTtl` 现在同时决定「保护多硬的证据」与「缓存多新算新鲜」两件事。
  它们是同一个数（10 分钟）在两种用法下的巧合，不是同一个设计意图；
  将来若要分开调，需要拆成两个常量。

## Testing

`test/zz_cr32_a_stale_ttl_test.dart`，8 条（任务书写的 9 条与实际不符，实际 8 条）。

开工基线本身就是红的，而且红在**测试自己身上**：用例 `① 三会话闭环` 的
`LiveAvailabilityProbe(fetch: ...)` 没传 `now:` ⇒ `cached()` 用真墙钟（08:15）
去比 `seed()` 灌的固定 `at11`（前一天 12:11）⇒ 差 20h 全判过期 ⇒ `calls=2`
（`Expected: <0> Actual: <2>`）。这是**时间炸弹**：写完当天绿，第二天必红。
修法是补 `now: () => at15`。

四次注入证明 8 条没有一条空转（备份在 `.probe/`，每次 `cp` 还原；
`sha256 = be371c93272cd891ac1f9660cf709dff8e680a4875f79f4a3681510d170a6338` 前后逐字一致，
`git diff --stat` 恒为 `1 file changed, 58 insertions(+), 6 deletions(-)`）：

| 注入 | 改坏点 | 读数 | 打红了谁 |
|---|---|---|---|
| A | 判据改回 `healthOf != unknown ⇒ continue` | `+3 -5` | 固定时钟 / 真实时钟 / 过期 broken→playable / 三会话闭环 / 落盘 t 字段 |
| B | 保护整个拿掉 | `+7 -1` | 仍新鲜的条目必须继续受保护 |
| C | `freshOnly` 的 TTL 判据拿掉 | `+4 -4` | 仪器活性对照 |
| D | `if (prev == null) continue;` | `+5 -3` | 新条目…照写 |

注入 A 的读数与代码注释自述一字不差：三会话闭环 `Expected: <2> Actual: <0>`，
落盘 `t` 字段 `1792555200000`(t0) vs `1792555860000`。
还原后 `flutter test test/zz_cr32_a_stale_ttl_test.dart` → `+8: All tests passed!`，
`dart analyze` 零 issue；`zz_t39_live_availability_test.dart` 15/15 绿，
证明未提交的产品改动没打破既有 probe 缓存/TTL/并发用例。

**没做到**：没有任何用例覆盖「两个消费方（`needsRetry` / `freshOnly`）在 `at` 刷新后
读数如何变化」，只覆盖了 `at` 本身前进。这条链条的上半段仍是靠注释推的。

## 风险

- 「用固定 `t0` + 默认真实时钟」这个写法在测试里还有同类隐患：
  `LiveAvailabilityProbe(` 的构造点要逐个看有没有传 `now:`。
  产品侧（`lib/ui/home_page.dart:889/1019`、`lib/ui/live_page.dart:577`）用默认时钟无妨，
  测试侧一律要传。
- 修法依赖 `kLiveHealthTtl` 与 `freshOnly` 用同一个口径；将来有人只改一处，
  会出现「缓存算新鲜但保护算过期」的错位，且没有任何门禁守这条一致性。
