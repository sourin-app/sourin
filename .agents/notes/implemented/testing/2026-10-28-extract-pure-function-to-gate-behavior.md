# Agent Note: 判据驱动不了界面时，把判据抽成纯函数，而不是加测试夹具

Status: implemented

## Problem

R2-#5（bili 弹幕按 manual 分流）的判据当时只写在
`player_page.dart` 的 `_loadDanmakuNamed` 里，两个条件拼在一行：

```dart
if (biliBind != null && !biliBind.isEmpty && isManualBinding(provider, id)) { ... }
```

⇒ 门禁只能写成**源码级**（`indexOf`/`contains`，见 `test/t73_bili_wiring_test.dart` 组2）。
源码级判据能证明"代码里有这个条件"，**证明不了**"运行时 `manual=false` 真的不套用"。
独立复核（2026-10-28）把这条点成覆盖缺口。

我先后试了三种夹具想去驱动真 `PlayerPage`，全部失败：

```text
v1 假 HttpClient（debugPlayerReloadDanmakuForProbe(fake:)）
    —— 只换传输层；updateDanmaku 的分页/鉴权/重试仍在跑 ⇒ 挂死
v2 假 BiliApi（新加 debugPlayerSetBiliApiForProbe）+ await 探针
    —— manual=true 那条 3:15 后 "did not complete"
v3 同上 + unawaited + 连续 pump 推时钟
    —— 两条都在 0 秒 "did not complete"
已核：updateDanmaku 在 danmaku() 之前没有 await 其它 I/O；markBiliSynced() 是 void
⇒ 卡点在"这条链等帧/等定时器"与 flutter_test 假时钟的互锁，不是夹具写错。
```

## Decision

**把判据本身抽成纯函数，让行为可以被直接钉住**，而不是继续加夹具去绕时钟：

```dart
// lib/core/bili/bili_bind.dart
int biliCidForAutoApply({
  required BiliBinding? binding,
  required bool manual,
  required int episodeIndex,
}) {
  if (binding == null || binding.isEmpty) return 0;
  if (!manual) return 0;                    // ← 三态的核心
  final cid = binding.cidFor(episodeIndex);
  return cid > 0 ? cid : 0;
}
```

调用点改为经它决策（`player_page.dart`），源码级判据退回它该干的活：
**守调用点没被绕过**（必须走纯函数、必须把 `manual` 当入参传）。

```text
行为级判据：test/zz_r2_5_bili_auto_apply_test.dart（4 条：无绑定 / manual=false /
            manual=true 两集 / 该集无 cid 与越界）
注入：`if (!manual) return 0;` → `if (false)` ⇒ ② 真红（Expected <0> / Actual <4242>）
源码级判据注入：`manual: isManualBinding(...)` → `manual: true` ⇒ t73 ① 红
```

## Alternatives considered

1. **继续加夹具**（换更完整的假 transport / 用 `fakeAsync` 包一层 / 给 Timer 开注入点）。
   最强理由：不动生产代码，纯测试侧解决，风险最小。
   **否决** —— 三次尝试已经证明这条路要动的是"链上所有等待点"，成本远高于抽一个纯函数；
   而且即使成功，那份测试仍然依赖整条 PlayerPage 装配，脆且慢。
2. **给 `_loadDanmakuNamed` 的每个 await 都注入 clock/Timer 工厂**。
   最强理由：能让整条链在测试里可控，还能顺带解决别的等待类测试。
   **否决（本轮）** —— 那是生产侧的仪器化改造，影响面比"抽一个纯函数"大一个数量级，
   为一个判据不值得；将来若有多条链都需要，再单独立项。
3. **接受源码级判据，把缺口写清楚就完事**（我当时的第一版处置）。
   最强理由：诚实、零风险、不碰生产代码。
   **否决** —— 缺口本身是"最高风险改动没有行为证据"，而解法（抽纯函数）只改一处、
   语义完全等价、且有现成门禁护航。能用 10 行解决的缺口不该留。
4. **把判据搬进 `batch_bind.dart`（已有的绑定工具层）**。
   最强理由：那里已经是纯函数聚集地。
   **否决** —— 判据依赖 `BiliBinding` 与 `isManualBinding` 的语义，放 `bili_bind.dart`
   才是同层；跨层搬会让"manual 是什么意思"分散到两个文件。

## Consequences

- 收益：这条判据第一次有了**行为级**证据（三态 + 两个边界），且不依赖任何界面装配；
  不再需要 `native-media` 标签、不依赖 libmpv，跑一次 0.3 秒。
- 收益：判据只有一份实现（纯函数），调用点与测试都指向它 ⇒ 不会出现"两处同构漂移"。
- 代价：`player_page.dart` 少了一段"就地可读"的条件表达式，多了一层函数调用 ——
  阅读时要跳到 `bili_bind.dart` 才知道三态。
  缓解：调用点上方写了三态口径与测试文件名。
- 代价：`lib/core/bili/bili_bind.dart` 是本批之前就存在、且被 t70（76 条）覆盖的文件，
  动它需要额外确认 —— 实测 `t70` 全绿。
- 验证：`zz_r2_5_bili_auto_apply_test` 4 条 + `t73` 19 条 + `t70` 76 条全绿；
  两处注入各真红一次并逐字节还原（`.probe/r2-5-purefn-inject.log`）。

## Relations

- 同族：[./2026-10-28-source-gates-must-window-by-char.md](./2026-10-28-source-gates-must-window-by-char.md)
  —— 那篇讲"源码判据的取景方式错了"；本篇讲"**当源码判据是唯一手段时，先想办法把它变成行为判据**"。
- 上位：[../bug-fix/2026-10-27-bili-autobind-manual-gate.md](../bug-fix/2026-10-27-bili-autobind-manual-gate.md)
  —— 那篇是这条三态语义的由来与用户数据依据。
