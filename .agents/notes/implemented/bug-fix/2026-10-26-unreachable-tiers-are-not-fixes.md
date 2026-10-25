# Agent Note: 死档位与"修了但跑不到"（归因档位必须从生产入口可达）

Status: implemented

## Problem

第 05 项（弹幕探活归因）有一组失败档位，逐档核对生产可达性后发现：

```text
dnsInconsistent  恒不可达 —— 入口已保证 looksForged(local)==true ⇒ different 必然走 hijacked
dnsUnverifiable  恒不可达 —— 入口要求 local 非空+伪造，而 doh.isEmpty 已在第 2 步被吃成 hijacked
dnsConsistent    几乎不可达 —— 需"本机落伪造段 且 DoH 返回同一 /24"（=DoH 也被投毒）
emptyResponse    零生产调用点 —— grep "DanmakuProbeReport.empty(" lib/ = 0（只有测试在用工厂）
```

其中 `dnsInconsistent` 是**前一天刚加的修复**：目的是"DNS 不一致但都在正常段 ⇒ 别说劫持、别改 DNS"。
它加了枚举、加了文案、加了测试、测试全绿 —— **但在生产里一次都不会生效**，因为
`forHijackedDns` 的两个入口都先要求 `looksForged(local)` 为真。

这就是本仓最容易被忽略的一类缺陷：**"看着修好、其实永远跑不到"**。
它比没修更危险 —— 代码里有、测试里有、台账里写着"已修"，下一个读代码的人不会再查。

## Decision

**归因档位必须从生产入口可达；不可达的档位不许存在。**

1. **重写四档梯子**（`danmaku_settings_dialog.dart:726-757`）：
   ```dart
   final hasTruth = dohQueried || doh.isNotEmpty;
   final forged   = looksForged(localAddresses);
   final hijacked = forged && (!hasTruth || different);   // 伪造段是地址级物证
   ```
   ⇒ 缺真值：伪造段 ⇒ `dnsHijacked`，否则 ⇒ `dnsUnverifiable`；同 /24 ⇒ `dnsConsistent`；
   跨段不同：伪造 ⇒ `dnsHijacked`，否则 ⇒ `dnsInconsistent`。
   **"报劫持"的唯一条件仍是伪造段** —— 这条不因为放宽入口而动摇（健康网络不会被误诊）。
2. **入口放宽**：`_diagnose` 只要拿到本机地址就问一次权威 DNS（原来只有命中伪造段才问）。
3. **删掉死档**：`emptyResponse` 连同 `DanmakuProbeReport.empty()` 工厂、两处 UI 的"空结果用中性色"分支一起删；
   三处测试改成"该枚举成员必须不存在"的存在性判据（有人加回来就红）。
4. **补跨层优先级注释**：`fromDanmakuException` ①`looksForged` ②`statusCode` ③`fromError` 四层，
   写清每层为什么在前面，并给两个可自答的例子（"劫持 + 500 ⇒ 劫持档"、"正常 DNS + 401 ⇒ serverError"）。

## Alternatives considered

1. **保留死档，只改文案说"生产不可达"**。
   那是把"代码里的假能力"换成"注释里的假能力"，读者仍会以为有四个结论。**否决**。
2. **保留 `emptyResponse` 并给播放器"0 条弹幕"路径接一个真实调用点**。
   需要动 `player_page.dart` 的取弹幕路径，且 core 现在"没有弹幕"是返回空列表而不是异常 ⇒
   要在 UI 层把"空列表"翻译成一个失败档，语义上会把"正常但没内容"变成"探测失败"。**否决**，删档更诚实。
3. **只放宽入口、不改梯子**。
   入口一放宽，`different` 在健康网络里大量出现 ⇒ 若梯子不变，`different` 会落到 `dnsHijacked`
   ⇒ **回到"健康网络报劫持"的老误诊**。所以梯子与入口必须一起改。**否决**分两步走。
4. **把四档合并成两档（劫持 / 其它）**。
   省事，但"一致"与"不一致"对用户是不同的行动建议（改 DNS / 别改 DNS）。**否决**。

## Consequences

- 收益：三个死档有了生产入口；`emptyResponse` 这种"零调用点档位"从枚举里消失；
  跨层优先级第一次被写成一处可读的注释。
- 代价：`_diagnose` 现在**只要拿到本机地址就多问一次 DoH** —— 热路径多一次网络往返。
  缓解：它发生在**已经失败**的路径上（探测失败才诊断），且 DoH 有 15s 预算与三源降级；
  正常成功路径不受影响。
- **欠账（明确，不算完成）**：四档"从生产入口驱动"的 widget 用例与注入未做 ——
  需要三处协同注入口（`dohOverride` + `routeOverride` + 放宽 `_diagnose` 的调用条件，
  否则注入了 `probeOverride` 后 `_diagnose` 根本不会跑）。
  ⇒ 目前四档的**行为**在辅助函数层有断言，但**"入口条件被改回去"这件事没有门禁抓住**。
  这是本决策最大的未闭合点，下一轮必须补。

## Relations

- 同族（互链）：[2026-10-25-identity-must-carry-discriminator.md](2026-10-25-identity-must-carry-discriminator.md)
  —— 那篇立的 `dnsInconsistent` 档就是本篇要救的那个死档：**判据对了，但入口把它挡死了**。
- 同族（互链）：[../../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md](../testing/2026-10-25-rebuild-threshold-must-not-encode-defect.md)
  —— 那篇讲"门禁阈值编码缺陷态"，本篇讲"门禁只调辅助函数 ⇒ 抓不到入口条件"。都是**门禁看得见什么**的问题。

## Testing

- `zz_t1027` **+30**、`zz_t66_r3_dns_hijack` **+22**、`zz_t66_r3_probe_truth` **+32**（三门禁 **+84 / exit 0**）。
- `grep -rn "emptyResponse\|DanmakuProbeReport.empty"` = **0**；`flutter analyze lib/ test/` 0 error。
- 文案两两不同已由脚本抽取核对（12 档 title/remedy 无重复，`none` 为空串）。
- 顺带修掉两处自伤并记录：heredoc 写多行 Dart 字符串时 `\n` 被吞成真换行（`analyze` 报 unterminated）；
  以及"查了没拿到"的旧断言写的是 `dnsHijacked` —— 那正是"把没查到当劫持"的误诊，已按新契约改成 `dnsUnverifiable`。
