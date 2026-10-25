# Agent Note: 门禁必须从生产入口驱动（辅助函数层断言不够）

Status: implemented

## Problem

第 05 项的四个 DNS 归因档在修了"判据"之后看起来好了：梯子重写、入口放宽、文案两两不同、测试全绿。
但**没有任何用例从生产入口驱动** —— 四条的断言都是直接调 `hijackReportWithTruth` 这个辅助函数。

后果：**入口条件被改回去，测试依然全绿**。而入口正是上一次缺陷的所在
（`forHijackedDns` 的两个入口都先要求 `looksForged(local)` ⇒ 三个档恒不可达）。
换句话说：修了一次，却没有留下任何能抓住"再改回去"的机制。

同批还有两个同源问题：
- `debugPlayerMarkFirstFrameForProbe` / `debugPlayerClearErrorForProbe` **手写字段复刻生产状态机**
  （生产加字段 ⇒ 探针不跟 ⇒ 门禁测的是复刻件）；
- `zz_t1024_player_banner_order` 的顺序判据读**原始源码（含注释）** ⇒ 注释能造出假红/假绿。

## Decision

**门禁要从用户真正会走的那条路进来；断言要落在用户能看见的东西上。**

1. **三个注入口**（生产恒 null）：`dohOverride`（权威 DNS 查找）、`routeOverride`（`diagnoseDanmakuEndpoint`），
   并放宽 `_diagnose` 的调用条件（`probeOverride == null || routeOverride != null`）。
   新增 `zz_t1027_danmaku_diagnose_entry_test.dart` 四条：填地址 → 切「高级」→ 点「测试连接」→ `_diagnose` → 四档。
2. **断言屏幕文案**而不是枚举值：`域名解析正确` / `与本机解析不一致` / `DNS 可能被劫持` / `没有可比较`；
   每条都配一条反向断言（"这句话**不许**出现"），防"两个档同时上屏"。
3. **注入证明门禁有牙**：把入口条件改回只认 `looksForged` ⇒ `+1 -3`（三条非伪造段红，伪造段那条仍绿 ——
   说明这道门禁精确地守在"非伪造段的三种结论"上）。
4. **探针不许复刻生产**：抽 `_neutralizeErrorState({loading})` 与 `_handleFirstFrame(int w)`，
   生产四处 + 两个探针共用一份；探针里零字段手写、无"逐字复刻"字样。
5. **源码类判据先剥注释**：`zz_t1024_player_banner_order` 的两处 `readAsStringSync` 都过 `_stripComments`。

## Alternatives considered

1. **只给辅助函数加断言，注明"生产入口另有覆盖"**。
   那是把"没有覆盖"写成"有覆盖"，正是本批在别处反复修的形态。**否决**。
2. **给 `_diagnose` 单独开一个 `@visibleForTesting debugDiagnose(ep)` 直通入口**。
   更省事，但它绕过了用户真实的点击路径（"填地址→切页签→点测试连接"这一跳本身也可能断）。
   现在的四条用例走的是真路径，多花的只有三步 `tap`。**否决**（作为将来若真路径太难驱动时的退路保留）。
3. **把探针改成 `debugPlayerMarkFirstFrameForProbe` 内联生产代码**。
   那还是两份实现。**否决**，抽单点才是唯一实现。
4. **给像素门禁自带字体**。
   实测这台机器下载不了字体，且 CJK 覆盖的开源字体 ≥10MB，与本仓"夹具要小而可控"不符。
   改为：edge 用 flutter_test 默认 Ahem（构造上不需要真字体）、contour 缺字体时 **fail** 并列出 12 条候选路径。
   **部分采纳** —— 这是"两害相权"，并留了一条实测反例（Ahem `haloWidth=8.00` vs Arial `1.00`：
   阈值是按 Ahem 标定的，换字体必须重新标定）。

## Consequences

- 收益：四档的"入口被改回去"第一次有了可证伪的证据；两个探针从"复刻件"变成"同一份实现"；
  "缺字体 ⇒ 静默 skip"这条通道被关闭。
- 代价：`_diagnose` 的调用条件多了一个 `||`（`routeOverride != null`）—— 它是测试专用分支，
  生产两个 override 都是 null ⇒ 行为与改前逐字一致。
- 代价：`zz_t1024_player_banner_order` 多了 40 行 `_stripComments`（Dart 里没有现成工具）；
  但它同时消掉了"注释能造假红/假绿"这条。
- 残留：contour 门禁的阈值仍按 Arial Bold 标定；落到 DejaVu/Liberation 的 CI 上第一次要核对矩阵读数
  （判据已归一化，预期仍成立，但**没有那台机器可验**）。

## Relations

- 同族（互链）：[../bug-fix/2026-10-26-unreachable-tiers-are-not-fixes.md](../bug-fix/2026-10-26-unreachable-tiers-are-not-fixes.md)
  —— 那篇记"三个死档"这个缺陷本身；本篇记**为什么上一轮的测试没抓住它**（断言打在辅助函数上）。
- 同族（互链）：[2026-10-25-rebuild-threshold-must-not-encode-defect.md](2026-10-25-rebuild-threshold-must-not-encode-defect.md)
  —— 那篇讲"阈值编码缺陷态"，本篇讲"断言位置绕过入口"，都是"门禁看得见什么"的问题。

## Testing

- 入口四条 **+4**；`zz_t1027` **+30**、`r3_dns_hijack` **+22**、`r3_probe_truth` **+32**（合计 **+88 / exit 0**）。
- 探针抽单点后 10 个既有门禁全绿；两次注入（单点空操作 / 不立首帧）各红，恢复后 `diff -q` 一致。
- 像素门禁：edge **+8**（Ahem）、contour **+2**（Arial）；`flutter analyze lib/ test/` 0 error。
